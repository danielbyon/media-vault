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
    /// Opaque operation identifier that a qualification launch expects to survive from its
    /// previous process. The startup purge reports whether this exact allocation directory
    /// existed immediately before removal; the value carries no URL, filename, or content.
    /// Production never sets it.
    var qualificationExpectedPriorOperation: UUID?
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
            "operationIdentifierPresent": String(
                UUID(uuidString: allocation.directory.lastPathComponent) != nil,
            ),
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
        if qualificationStage == "ownership" {
            fields.merge(
                Self.ownershipDiagnosticFields(
                    parent: allocation.directory.deletingLastPathComponent(),
                    root: root,
                    operationDirectory: allocation.directory,
                ),
            ) { _, diagnosticValue in diagnosticValue }
        }
        qualificationDiagnostic(fields)
    }

    /// Captures URL representation and filesystem facts for an ownership rejection.
    /// The values contain comparisons and classifications only; this check never creates paths.
    private static func ownershipDiagnosticFields(
        parent: URL,
        root: URL,
        operationDirectory: URL,
    ) -> [String: String] {
        let standardizedParent = parent.standardizedFileURL
        let standardizedRoot = root.standardizedFileURL
        let parentFacts = ownershipFilesystemFacts(at: standardizedParent)
        let rootFacts = ownershipFilesystemFacts(at: standardizedRoot)
        let operationFacts = ownershipFilesystemFacts(at: operationDirectory)
        let filesystemIdentity: String =
            if let parentIdentity = parentFacts.identity,
            let rootIdentity = rootFacts.identity {
                parentIdentity == rootIdentity ? "same" : "different"
            } else {
                "unavailable"
            }
        let parentComponents = standardizedParent.pathComponents
        let rootComponents = standardizedRoot.pathComponents

        return [
            "parentIsFileURL": String(parent.isFileURL),
            "rootIsFileURL": String(root.isFileURL),
            "parentHasDirectoryPath": String(parent.hasDirectoryPath),
            "rootHasDirectoryPath": String(root.hasDirectoryPath),
            "parentHasBaseURL": String(parent.baseURL != nil),
            "rootHasBaseURL": String(root.baseURL != nil),
            "parentIsAbsolute": String(parent.baseURL == nil),
            "rootIsAbsolute": String(root.baseURL == nil),
            "parentStandardizedPathMatchesRoot": String(standardizedParent.path == standardizedRoot.path),
            "parentStandardizedURLMatchesRoot": String(standardizedParent == standardizedRoot),
            "parentLogicalComponentsMatchRoot": String(parentComponents == rootComponents),
            "parentWithinAuthorizedRoot": String(isWithinRoot(parentComponents, rootComponents)),
            "parentExists": String(parentFacts.exists),
            "parentType": parentFacts.type,
            "parentIsDirectory": String(parentFacts.type == "directory"),
            "parentIsSymbolicLink": parentFacts.isSymbolicLink,
            "rootExists": String(rootFacts.exists),
            "rootType": rootFacts.type,
            "rootIsDirectory": String(rootFacts.type == "directory"),
            "rootIsSymbolicLink": rootFacts.isSymbolicLink,
            "operationDirectoryExists": String(operationFacts.exists),
            "operationDirectoryType": operationFacts.type,
            "operationDirectoryIsDirectory": String(operationFacts.type == "directory"),
            "operationDirectoryIsSymbolicLink": operationFacts.isSymbolicLink,
            "parentRootFilesystemIdentity": filesystemIdentity,
            "operationDirectoryFilesystemIdentity": operationFacts.identity == nil ? "unavailable" : "available",
        ]
    }

    private static func ownershipFilesystemFacts(at url: URL) -> OwnershipFilesystemFacts {
        guard url.isFileURL else {
            return .unavailable
        }

        var metadata = stat()
        guard url.path.withCString({ lstat($0, &metadata) }) == 0 else {
            return .unavailable
        }

        let type =
            switch metadata.st_mode & S_IFMT {
            case S_IFDIR:
                "directory"
            case S_IFREG:
                "regularFile"
            case S_IFLNK:
                "symbolicLink"
            default:
                "other"
            }
        return OwnershipFilesystemFacts(
            exists: true,
            type: type,
            isSymbolicLink: String(type == "symbolicLink"),
            identity: OwnershipFileIdentity(device: UInt64(metadata.st_dev), inode: UInt64(metadata.st_ino)),
        )
    }

    private static func isWithinRoot(_ pathComponents: [String], _ rootComponents: [String]) -> Bool {
        pathComponents.count >= rootComponents.count
            && pathComponents.prefix(rootComponents.count).elementsEqual(rootComponents)
    }

    private struct OwnershipFilesystemFacts {
        static let unavailable = Self(
            exists: false,
            type: "unavailable",
            isSymbolicLink: "unavailable",
            identity: nil,
        )

        let exists: Bool
        let type: String
        let isSymbolicLink: String
        let identity: OwnershipFileIdentity?
    }

    private struct OwnershipFileIdentity: Equatable {
        let device: UInt64
        let inode: UInt64
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
        #if DEBUG
        if let qualificationDiagnostic {
            let entryNames = try files.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
                .map(\.lastPathComponent)
            qualificationDiagnostic(Self.purgeInspectionFields(
                entryNames: entryNames,
                expectedOperation: qualificationExpectedPriorOperation,
            ))
        }
        #endif
        for item in try files.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) {
            try removeConfirmed(item)
        }
    }

    #if DEBUG
    /// Pure projection for the pre-removal startup purge inspection.
    ///
    /// Carries only the inspection stage, the number of entries found, whether every entry
    /// name parses as a UUID directory, and — when the qualification host persisted one — the
    /// opaque operation identifier that must be matched. No path, filename leaf, or content
    /// value is emitted. An empty enumeration vacuously parses as UUID names; the count
    /// disambiguates that case for readers.
    static func purgeInspectionFields(entryNames: [String], expectedOperation: UUID?) -> [String: String] {
        var fields = [
            "recordKind": "scratchStartupPurgeInspection",
            "phase": "startupPurge",
            "stage": "startupPurgeInspection",
            "resource": "root",
            "preExistingCount": String(entryNames.count),
            "entryNamesParseUUID": String(entryNames.allSatisfy { UUID(uuidString: $0) != nil }),
        ]
        fields["expectedOperation"] = expectedOperation?.uuidString ?? "unavailable"
        if let expectedOperation {
            fields["expectedPresent"] = String(entryNames.contains { UUID(uuidString: $0) == expectedOperation })
        }
        return fields
    }
    #endif

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
