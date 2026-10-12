//
//  ReceiptStore.swift
//  MediaVault
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import CryptoKit
import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Opaque correlation keys allocated before an explicit download starts.
struct ReceiptIdentity: Codable, Equatable, Sendable {
    let transferID: UUID
    let assetID: UUID
    let resourceID: UUID
}

/// The only durable metadata needed to recover a completed receipt.
struct ReceiptManifest: Codable, Equatable, Sendable {
    let identity: ReceiptIdentity
    let byteCount: Int64
    let sha256: String
}

/// Counts recoverable publications separately from files left before publication.
struct ReceiptRecoveryInventory: Equatable, Sendable {
    let acceptedCount: Int
    let unacceptedArtifactCount: Int
    let invalidMetadataCount: Int
}

/// Deterministic process-interruption boundaries; these do not model sudden power loss.
enum ReceiptCheckpoint: CaseIterable, Sendable {
    case beforeProtectedCreate
    case afterProtectedCreate
    case afterFileSync
    case afterFileRename
    case afterManifestSync
    case afterPublication
}

struct InjectedInterruption: Error, Sendable {
    init() {}
}

enum ReceiptStoreError: Error, Sendable {
    case cannotCreateProtectedFile
    case invalidTransfer
    case duplicateIdentity
    case protectionMismatch
    case backupExclusionMismatch
    case synchronizationFailed
}

/// Requests that disposable receipt staging and acquisition evidence stay out of ordinary backups.
/// The operating system decides whether a backup honors this resource value.
func requestBackupExclusion(at url: URL) throws {
    var values = URLResourceValues()
    values.isExcludedFromBackup = true
    var mutableURL = url
    try mutableURL.setResourceValues(values)
    try verifyBackupExclusion(at: url)
}

/// Checks that a file still carries its exclusion request after a rename.
func verifyBackupExclusion(at url: URL) throws {
    guard try url.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true else {
        throw ReceiptStoreError.backupExclusionMismatch
    }
}

/// Owns a separate background receipt area; it never opens the authenticated vault database.
///
/// Acceptance occurs only after the protected receipt file and manifest are
/// synchronized and the manifest is atomically renamed into its published path.
/// A metadata scan is safe before unlock because it never reads receipt bytes.
struct ReceiptStore: Sendable {
    let rootURL: URL
    let receiptDirectoryURL: URL
    let metadataDirectoryURL: URL

    init(rootURL: URL) throws {
        self.rootURL = rootURL.standardizedFileURL
        receiptDirectoryURL = self.rootURL.appendingPathComponent("bytes", isDirectory: true)
        metadataDirectoryURL = self.rootURL.appendingPathComponent("metadata", isDirectory: true)
        let manager = FileManager.default
        try manager.createDirectory(at: self.rootURL, withIntermediateDirectories: true)
        try manager.createDirectory(at: receiptDirectoryURL, withIntermediateDirectories: true)
        try manager.createDirectory(at: metadataDirectoryURL, withIntermediateDirectories: true)
        try requestBackupExclusion(at: self.rootURL)
        #if os(iOS)
        try manager.setAttributes(
            [.protectionKey: FileProtectionType.completeUnlessOpen],
            ofItemAtPath: receiptDirectoryURL.path,
        )
        try manager.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: metadataDirectoryURL.path,
        )
        try verifyProtection(at: receiptDirectoryURL, expected: .completeUnlessOpen)
        try verifyProtection(at: metadataDirectoryURL, expected: .completeUntilFirstUserAuthentication)
        #endif
    }

    /// Creates an empty child without explicit protection to observe directory inheritance.
    /// Simulator APIs may report no attribute, which is recorded as unverified.
    func probeProtectionInheritance() throws -> String {
        let manager = FileManager.default
        let probeURL = receiptDirectoryURL.appendingPathComponent(UUID().uuidString.lowercased() + ".probe")
        guard manager.createFile(atPath: probeURL.path, contents: nil) else {
            throw ReceiptStoreError.cannotCreateProtectedFile
        }

        defer { try? manager.removeItem(at: probeURL) }
        #if os(iOS)
        let attribute = try manager.attributesOfItem(atPath: probeURL.path)[.protectionKey]
        guard let attribute else {
            return "unverified-nil"
        }

        let raw = (attribute as? FileProtectionType)?.rawValue ?? (attribute as? String)
        guard raw == FileProtectionType.completeUnlessOpen.rawValue else {
            throw ReceiptStoreError.protectionMismatch
        }

        return raw ?? "unrecognized"
        #else
        return "unverified-non-ios"
        #endif
    }

    /// Preserves a completed URLSession temporary download before the delegate returns.
    /// The source file is read once; a closed receipt may not be reopenable while locked.
    func publish(
        from sourceURL: URL,
        identity: ReceiptIdentity,
        expectedByteCount: Int64,
        checkpoint: (ReceiptCheckpoint) throws -> Void = { _ in },
    ) throws -> ReceiptManifest {
        guard expectedByteCount > 0 else {
            throw ReceiptStoreError.invalidTransfer
        }

        let manager = FileManager.default
        let name = identity.resourceID.uuidString.lowercased()
        let provisional = receiptDirectoryURL.appendingPathComponent(name + ".partial")
        let receiptURL = receiptDirectoryURL.appendingPathComponent(name + ".receipt")
        let provisionalManifest = metadataDirectoryURL.appendingPathComponent(name + ".manifest.partial")
        let manifestURL = metadataDirectoryURL.appendingPathComponent(name + ".manifest")
        guard !manager.fileExists(atPath: provisional.path),
              !manager.fileExists(atPath: receiptURL.path),
              !manager.fileExists(atPath: provisionalManifest.path),
              !manager.fileExists(atPath: manifestURL.path)
        else {
            throw ReceiptStoreError.duplicateIdentity
        }

        try checkpoint(.beforeProtectedCreate)

        // The exclusive creation descriptor remains open while protection is
        // established and all bytes are written. A closed completeUnlessOpen
        // file cannot be reopened while the device is locked.
        let output = try openProtectedProvisional(at: provisional)
        var preserveInterruptionArtifacts = false
        var metadataPublished = false
        defer {
            try? output.close()
            if !preserveInterruptionArtifacts, !metadataPublished {
                try? manager.removeItem(at: provisional)
                try? manager.removeItem(at: receiptURL)
                try? manager.removeItem(at: provisionalManifest)
                try? manager.removeItem(at: manifestURL)
            }
        }
        do {
            try checkpoint(.afterProtectedCreate)
            return try finishPublication(
                from: sourceURL,
                identity: identity,
                expectedByteCount: expectedByteCount,
                output: output,
                provisional: provisional,
                receiptURL: receiptURL,
                provisionalManifest: provisionalManifest,
                manifestURL: manifestURL,
                checkpoint: checkpoint,
                metadataPublished: &metadataPublished,
            )
        } catch {
            preserveInterruptionArtifacts = error is InjectedInterruption
            throw error
        }
    }

    /// Opens an exclusively created receipt and verifies protection before any private byte is written.
    func openProtectedProvisional(at url: URL) throws -> FileHandle {
        let descriptor = open(url.path, O_WRONLY | O_CREAT | O_EXCL, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else {
            if errno == EEXIST {
                throw ReceiptStoreError.duplicateIdentity
            }
            throw ReceiptStoreError.cannotCreateProtectedFile
        }

        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        do {
            try requestBackupExclusion(at: url)
            #if os(iOS)
            try FileManager.default.setAttributes(
                [.protectionKey: FileProtectionType.completeUnlessOpen],
                ofItemAtPath: url.path,
            )
            try verifyProtection(at: url, expected: .completeUnlessOpen)
            #endif
            return handle
        } catch {
            try? handle.close()
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }

    private func finishPublication(
        from sourceURL: URL,
        identity: ReceiptIdentity,
        expectedByteCount: Int64,
        output: FileHandle,
        provisional: URL,
        receiptURL: URL,
        provisionalManifest: URL,
        manifestURL: URL,
        checkpoint: (ReceiptCheckpoint) throws -> Void,
        metadataPublished: inout Bool,
    ) throws -> ReceiptManifest {
        let manager = FileManager.default
        let input = try FileHandle(forReadingFrom: sourceURL)
        var hasher = SHA256()
        var count: Int64 = 0
        defer { try? input.close() }
        while let chunk = try input.read(upToCount: 64 * 1_024), !chunk.isEmpty {
            count += Int64(chunk.count)
            guard count <= expectedByteCount else {
                throw ReceiptStoreError.invalidTransfer
            }

            hasher.update(data: chunk)
            try output.write(contentsOf: chunk)
        }
        guard count == expectedByteCount else {
            throw ReceiptStoreError.invalidTransfer
        }

        try output.synchronize()
        try output.close()
        try checkpoint(.afterFileSync)
        try manager.moveItem(at: provisional, to: receiptURL)
        #if os(iOS)
        try verifyProtection(at: receiptURL, expected: .completeUnlessOpen)
        #endif
        try verifyBackupExclusion(at: receiptURL)
        try syncDirectory(at: receiptDirectoryURL)
        try checkpoint(.afterFileRename)

        let manifest = ReceiptManifest(
            identity: identity,
            byteCount: count,
            sha256: hasher.finalize().map { String(format: "%02x", $0) }.joined(),
        )
        let encoded = try JSONEncoder().encode(manifest)
        var metadataAttributes: [FileAttributeKey: Any] = [:]
        #if os(iOS)
        metadataAttributes[.protectionKey] = FileProtectionType.completeUntilFirstUserAuthentication
        #endif
        guard manager.createFile(atPath: provisionalManifest.path, contents: nil, attributes: metadataAttributes) else {
            throw ReceiptStoreError.cannotCreateProtectedFile
        }

        try requestBackupExclusion(at: provisionalManifest)

        #if os(iOS)
        try verifyProtection(at: provisionalManifest, expected: .completeUntilFirstUserAuthentication)
        #endif
        let metadataHandle = try FileHandle(forWritingTo: provisionalManifest)
        try metadataHandle.write(contentsOf: encoded)
        try metadataHandle.synchronize()
        try metadataHandle.close()
        try checkpoint(.afterManifestSync)
        try manager.moveItem(at: provisionalManifest, to: manifestURL)
        #if os(iOS)
        try verifyProtection(at: manifestURL, expected: .completeUntilFirstUserAuthentication)
        #endif
        try verifyBackupExclusion(at: manifestURL)
        metadataPublished = true
        try syncDirectory(at: metadataDirectoryURL)
        try checkpoint(.afterPublication)
        return manifest
    }

    /// Lists published identities without reopening a protected receipt file.
    func discoverMetadata() throws -> [ReceiptManifest] {
        let manager = FileManager.default
        let urls = try manager.contentsOfDirectory(at: metadataDirectoryURL, includingPropertiesForKeys: nil)
        return urls.filter { $0.pathExtension == "manifest" }
            .compactMap { url in
                guard let manifest = try? JSONDecoder().decode(ReceiptManifest.self, from: Data(contentsOf: url)),
                      manifest.byteCount > 0,
                      manifest.sha256.count == 64,
                      url.deletingPathExtension().lastPathComponent == manifest.identity
                      .resourceID
                      .uuidString
                      .lowercased(),
                      manager.fileExists(atPath: receiptURL(for: manifest).path)
                else {
                    return nil
                }

                return manifest
            }
            .sorted { $0.identity.transferID.uuidString < $1.identity.transferID.uuidString }
    }

    /// Verifies exact bytes only after the explicit test unlock gate.
    func verifyAfterUnlock(_ manifest: ReceiptManifest) throws -> Bool {
        let url = receiptURL(for: manifest)
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        var count: Int64 = 0
        while let chunk = try handle.read(upToCount: 64 * 1_024), !chunk.isEmpty {
            count += Int64(chunk.count)
            hasher.update(data: chunk)
        }
        let hash = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return count == manifest.byteCount && hash == manifest.sha256
    }

    func receiptURL(for manifest: ReceiptManifest) -> URL {
        receiptDirectoryURL.appendingPathComponent(manifest.identity.resourceID.uuidString.lowercased() + ".receipt")
    }

    /// Classifies uncommitted files without reading any protected receipt bytes.
    func inspectRecovery() throws -> ReceiptRecoveryInventory {
        let manager = FileManager.default
        let receipts = try manager.contentsOfDirectory(at: receiptDirectoryURL, includingPropertiesForKeys: nil)
        let metadata = try manager.contentsOfDirectory(at: metadataDirectoryURL, includingPropertiesForKeys: nil)
        let accepted = try discoverMetadata()
        let acceptedIDs = Set(accepted.map { $0.identity.resourceID.uuidString.lowercased() })
        let invalidMetadata = metadata.filter {
            $0.pathExtension == "manifest" && !acceptedIDs.contains($0.deletingPathExtension().lastPathComponent)
        }
        let provisional = (receipts + metadata).filter { $0.pathExtension == "partial" }
        let orphanedReceipts = receipts.filter {
            $0.pathExtension == "receipt" && !acceptedIDs.contains($0.deletingPathExtension().lastPathComponent)
        }
        return ReceiptRecoveryInventory(
            acceptedCount: accepted.count,
            unacceptedArtifactCount: provisional.count + orphanedReceipts.count + invalidMetadata.count,
            invalidMetadataCount: invalidMetadata.count,
        )
    }

    /// Clears only provisional files and receipts for which no manifest exists.
    /// Invalid published metadata is retained for inspection rather than risking
    /// deletion of bytes that an earlier process may have reported as accepted.
    func reconcileUnacceptedArtifacts() throws {
        let manager = FileManager.default
        let receipts = try manager.contentsOfDirectory(at: receiptDirectoryURL, includingPropertiesForKeys: nil)
        let metadata = try manager.contentsOfDirectory(at: metadataDirectoryURL, includingPropertiesForKeys: nil)
        let provisional = (receipts + metadata).filter { $0.pathExtension == "partial" }
        let orphanedReceipts = receipts.filter { url in
            guard url.pathExtension == "receipt" else {
                return false
            }

            let manifest = metadataDirectoryURL
                .appendingPathComponent(url.deletingPathExtension().lastPathComponent + ".manifest")
            return !manager.fileExists(atPath: manifest.path)
        }
        for url in provisional + orphanedReceipts {
            try manager.removeItem(at: url)
        }
        if !provisional.isEmpty || !orphanedReceipts.isEmpty {
            try syncDirectory(at: receiptDirectoryURL)
            try syncDirectory(at: metadataDirectoryURL)
        }
    }

    /// Returns requested-versus-reported protection evidence without reading bytes.
    /// A simulator's missing attribute is reported as unverified.
    func protectionEvidence(for manifest: ReceiptManifest) -> [String: String] {
        #if os(iOS)
        func reportedProtection(at url: URL) -> String {
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
                  let protection = attributes[.protectionKey] else {
                return "unverified-nil"
            }

            return (protection as? FileProtectionType)?.rawValue ?? (protection as? String) ?? "unrecognized"
        }
        return [
            "receiptDirectoryProtection": reportedProtection(at: receiptDirectoryURL),
            "receiptFileProtection": reportedProtection(at: receiptURL(for: manifest)),
            "metadataDirectoryProtection": reportedProtection(at: metadataDirectoryURL),
        ]
        #else
        return [
            "receiptDirectoryProtection": "unverified-non-ios",
            "receiptFileProtection": "unverified-non-ios",
            "metadataDirectoryProtection": "unverified-non-ios",
        ]
        #endif
    }

    /// Removes only incomplete publication artifacts after independent restart.
    func removeAbandonedProvisionalFiles() throws -> Int {
        let manager = FileManager.default
        let receiptURLs = try manager.contentsOfDirectory(at: receiptDirectoryURL, includingPropertiesForKeys: nil)
        let metadataURLs = try manager.contentsOfDirectory(at: metadataDirectoryURL, includingPropertiesForKeys: nil)
        let abandoned = (receiptURLs + metadataURLs).filter { $0.pathExtension == "partial" }
        for url in abandoned {
            try manager.removeItem(at: url)
        }
        if !abandoned.isEmpty {
            try syncDirectory(at: receiptDirectoryURL)
            try syncDirectory(at: metadataDirectoryURL)
        }
        return abandoned.count
    }

    private func syncDirectory(at url: URL) throws {
        #if canImport(Darwin)
        let descriptor = open(url.path, O_RDONLY)
        guard descriptor >= 0 else {
            throw ReceiptStoreError.synchronizationFailed
        }

        defer { _ = close(descriptor) }
        guard fsync(descriptor) == 0 else {
            throw ReceiptStoreError.synchronizationFailed
        }

        #endif
    }
}

#if os(iOS)
private func verifyProtection(at url: URL, expected: FileProtectionType) throws {
    let value = try FileManager.default.attributesOfItem(atPath: url.path)[.protectionKey]
    guard let value else {
        #if targetEnvironment(simulator)
        // The simulator does not expose hardware protection; this is never
        // evidence of effective Data Protection on a physical device.
        return
        #else
        throw ReceiptStoreError.protectionMismatch
        #endif
    }

    let actual = (value as? FileProtectionType)?.rawValue ?? (value as? String)
    guard actual == expected.rawValue else {
        throw ReceiptStoreError.protectionMismatch
    }
}
#endif
