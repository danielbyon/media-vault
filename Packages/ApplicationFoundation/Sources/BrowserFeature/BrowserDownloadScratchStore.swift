//
//  BrowserDownloadScratchStore.swift
//  MediaVault
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Darwin
import Foundation

/// In-memory cleanup ownership. No allocation is persisted as a manifest or receipt.
struct BrowserDownloadAllocation {
    let directory: URL
    let destination: URL
}

/// Owns the dedicated transient scratch root and verifies real filesystem attributes.
@MainActor
final class BrowserDownloadScratchStore {
    enum Failure: Error, Equatable {
        case unsafeFile
        case protectionUnavailable
        case backupExclusionUnavailable
    }

    let root: URL
    private let files: FileManager
    private let verifyProtection: @MainActor (URL) throws -> Void
    private let remove: @MainActor (URL) throws -> Void

    #if DEBUG
    /// Optional, path-free diagnostics for the standalone qualification app. No observer is
    /// installed by production; failures still follow the same revocation and cleanup policy.
    var qualificationDiagnostic: (@MainActor ([String: String]) -> Void)?
    private var qualificationStage = "none"
    private var qualificationResource = "root"

    /// Reports an already-caught error without altering or retrying the failed filesystem work.
    func reportQualificationFailure(_ error: Error, phase: String, allocation: BrowserDownloadAllocation) {
        guard let qualificationDiagnostic else {
            return
        }

        let nativeError = error as NSError
        let resource = qualificationResource == "root"
            ? root
            : qualificationResource == "destination" ? allocation.destination : allocation.directory
        var fields = [
            "operation": UUID(uuidString: allocation.directory.lastPathComponent)?
                .uuidString ?? "unidentifiedAllocation",
            "phase": phase,
            "stage": qualificationStage,
            "resource": qualificationResource,
            "errorDomain": nativeError.domain,
            "errorCode": String(nativeError.code),
            "scratchFailure": (error as? Failure).map { String(describing: $0) } ?? "none",
            "parentMatchesRoot": String(allocation.directory.deletingLastPathComponent().standardizedFileURL == root),
            "destinationParentMatchesOperation": String(
                allocation.destination.deletingLastPathComponent().standardizedFileURL == allocation.directory,
            ),
            "destinationLeafNonempty": String(!allocation.destination.lastPathComponent.isEmpty),
        ]
        do {
            let attributes = try files.attributesOfItem(atPath: resource.path)
            fields["fileType"] = (attributes[.type] as? FileAttributeType)?.rawValue ?? "absent"
            fields["ownerMatchesProcess"] = String(attributes[.ownerAccountID] as? UInt32 == Darwin.getuid())
            fields["protectionAttribute"] = (attributes[.protectionKey] as? FileProtectionType)?.rawValue ?? "absent"
        } catch {
            let inspectionError = error as NSError
            fields["attributeErrorDomain"] = inspectionError.domain
            fields["attributeErrorCode"] = String(inspectionError.code)
        }
        do {
            fields["backupExcluded"] = try String(
                resource.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true,
            )
        } catch {
            let inspectionError = error as NSError
            fields["backupErrorDomain"] = inspectionError.domain
            fields["backupErrorCode"] = String(inspectionError.code)
        }
        qualificationDiagnostic(fields)
    }
    #endif

    private func markQualificationStage(_ stage: String, resource: String? = nil) {
        #if DEBUG
        guard qualificationDiagnostic != nil else {
            return
        }

        qualificationStage = stage
        if let resource {
            qualificationResource = resource
        }
        #endif
    }

    /// The default verifier requires native `.complete` protection. Tests may explicitly inject
    /// only that verifier on unsupported simulators; file identity, size, and backup checks remain real.
    init(
        root: URL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "BrowserDownloads",
            isDirectory: true,
        ),
        files: FileManager = .default,
        verifyProtection: @escaping @MainActor (URL) throws -> Void = BrowserDownloadScratchStore
            .verifyNativeProtection,
        remove: (@MainActor (URL) throws -> Void)? = nil,
    ) {
        self.root = root.standardizedFileURL
        self.files = files
        self.verifyProtection = verifyProtection
        self.remove = remove ?? { try files.removeItem(at: $0) }
    }

    /// Purges only this dedicated root before the first admission of a process.
    func purgePreviousProcess() throws {
        try prepareDirectory(root)
        for item in try files.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) {
            try removeConfirmed(item)
        }
    }

    /// Allocates ownership before filesystem work, so a partially created directory stays recoverable.
    func allocation(id: BrowserDownloadID, suggestedName: String) -> BrowserDownloadAllocation {
        let directory = root.appendingPathComponent(id.rawValue.uuidString, isDirectory: true)
        return .init(directory: directory, destination: directory.appendingPathComponent(Self.leafName(suggestedName)))
    }

    /// Prepares protected parents, never creating the file WebKit is about to write.
    func prepare(_ allocation: BrowserDownloadAllocation) throws {
        markQualificationStage("ownership", resource: "operation")
        try validateOwnership(allocation)
        markQualificationStage("rootPreparation", resource: "root")
        try prepareDirectory(root)
        markQualificationStage("operationPreparation", resource: "operation")
        try prepareDirectory(allocation.directory)
        markQualificationStage("destinationAbsence", resource: "destination")
        do {
            _ = try files.attributesOfItem(atPath: allocation.destination.path)
            throw Failure.unsafeFile
        } catch let error as CocoaError where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile {
            // WebKit requires a nonexistent destination inside an existing writable directory.
        }
    }

    /// Verifies the actual completed regular file, reapplies required attributes, then checks again.
    /// A symlink, foreign owner, invalid size, or unavailable protection never becomes presentable.
    func verifyCompleted(_ allocation: BrowserDownloadAllocation) throws -> Int64 {
        markQualificationStage("completedOwnership", resource: "operation")
        try validateOwnership(allocation)
        markQualificationStage("completedRootAttributes", resource: "root")
        try verifyDirectory(root)
        markQualificationStage("completedOperationAttributes", resource: "operation")
        try verifyDirectory(allocation.directory)
        markQualificationStage("completedFileAttributes", resource: "destination")
        let attributes = try files.attributesOfItem(atPath: allocation.destination.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              attributes[.ownerAccountID] as? UInt32 == Darwin.getuid(),
              let size = attributes[.size] as? Int64, size >= 0
        else {
            throw Failure.unsafeFile
        }

        markQualificationStage("completedProtection", resource: "destination")
        try protect(allocation.destination)
        let verified = try files.attributesOfItem(atPath: allocation.destination.path)
        guard verified[.type] as? FileAttributeType == .typeRegular,
              verified[.ownerAccountID] as? UInt32 == Darwin.getuid(),
              verified[.size] as? Int64 == size
        else {
            throw Failure.unsafeFile
        }

        return size
    }

    /// Removes owned bytes only after the caller has established that WebKit stopped writing.
    func cleanup(_ allocation: BrowserDownloadAllocation) throws {
        markQualificationStage("cleanupOwnership", resource: "operation")
        try validateOwnership(allocation)
        markQualificationStage("removal", resource: "operation")
        try removeConfirmed(allocation.directory)
    }

    private func removeConfirmed(_ url: URL) throws {
        do {
            try remove(url)
        } catch let error as CocoaError where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile {
            // A successful removal or an explicit missing-item error is cleanup evidence.
        }
    }

    private func validateOwnership(_ allocation: BrowserDownloadAllocation) throws {
        guard allocation.directory.deletingLastPathComponent().standardizedFileURL == root,
              allocation.destination.deletingLastPathComponent().standardizedFileURL == allocation.directory,
              !allocation.destination.lastPathComponent.isEmpty
        else {
            throw Failure.unsafeFile
        }
    }

    private func prepareDirectory(_ url: URL) throws {
        markQualificationStage("directoryCreation")
        try files.createDirectory(
            at: url,
            withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.complete],
        )
        try verifyDirectory(url)
        try protect(url)
    }

    private func verifyDirectory(_ url: URL) throws {
        markQualificationStage("directoryAttributes")
        let attributes = try files.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeDirectory,
              attributes[.ownerAccountID] as? UInt32 == Darwin.getuid()
        else {
            throw Failure.unsafeFile
        }
    }

    private func protect(_ url: URL) throws {
        markQualificationStage("protectionWrite")
        try files.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: url.path)
        var resourceURL = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        markQualificationStage("backupWrite")
        try resourceURL.setResourceValues(values)
        markQualificationStage("protectionReadback")
        try verifyProtection(url)
        markQualificationStage("backupReadback")
        guard try url.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true else {
            throw Failure.backupExclusionUnavailable
        }
    }

    static func verifyNativeProtection(_ url: URL) throws {
        guard try FileManager.default
            .attributesOfItem(atPath: url.path)[.protectionKey] as? FileProtectionType == .complete else {
            throw Failure.protectionUnavailable
        }
    }

    /// Converts untrusted suggestions into bounded ASCII leaves without traversal or control bytes.
    static func leafName(_ suggestion: String) -> String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_. ")
        let sanitized = suggestion.unicodeScalars.map { allowed.contains($0) ? String($0) : "_" }.joined()
        let leaf = String(sanitized.prefix(96)).trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        return leaf.isEmpty ? "download" : leaf
    }
}
