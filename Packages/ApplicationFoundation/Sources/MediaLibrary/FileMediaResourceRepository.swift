//
//  FileMediaResourceRepository.swift
//  MediaVault
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Provides the protected app-controlled filesystem boundary for canonical resources.
public struct FileMediaResourceRepository: Sendable {
    private let rootURL: URL
    private let stagingURL: URL
    private let protectionOperation: @Sendable (URL) throws -> Void
    private let acceptedResourceReadOperation: @Sendable (URL) throws -> Data

    /// Creates protected resource and staging directories below the supplied root.
    public init(rootURL: URL) throws {
        try self.init(
            rootURL: rootURL,
            protectionOperation: { url in
                try Self.applyCompleteProtection(to: url, using: FileManager.default)
            },
        )
    }

    /// Creates a repository with injected filesystem operations for deterministic failure tests.
    @preconcurrency
    @_spi(Testing)
    public init(
        rootURL: URL,
        protectionOperation: @escaping @Sendable (URL) throws -> Void,
        acceptedResourceReadOperation: @escaping @Sendable (URL) throws -> Data = { url in
            try Data(contentsOf: url, options: [.mappedIfSafe])
        },
    ) throws {
        let normalizedRootURL = rootURL.standardizedFileURL
        self.rootURL = normalizedRootURL
        stagingURL = normalizedRootURL.appendingPathComponent(".staging", isDirectory: true)
        self.protectionOperation = protectionOperation
        self.acceptedResourceReadOperation = acceptedResourceReadOperation
        let fileManager = FileManager.default

        try fileManager.createDirectory(at: self.rootURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: stagingURL, withIntermediateDirectories: true)
        try protectionOperation(self.rootURL)
        try protectionOperation(stagingURL)
    }

    /// Returns a unique staging path for one import operation.
    public func stagingURL(for identifier: UUID) -> URL {
        stagingURL.appendingPathComponent(identifier.uuidString.lowercased(), isDirectory: false)
    }

    /// Lists UUID-named staging files that have no matching journal record.
    func stagedResourceIDs() -> [UUID] {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: stagingURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles],
        ) else {
            return []
        }

        return urls.compactMap { url in
            guard let identifier = UUID(uuidString: url.lastPathComponent),
                  let values = try? url.resourceValues(forKeys: [.isRegularFileKey]),
                  values.isRegularFile == true
            else {
                return nil
            }

            return identifier
        }
        .sorted { $0.uuidString < $1.uuidString }
    }

    /// Applies complete Data Protection to one copied staging resource before validation.
    public func protectStaging(for identifier: UUID) throws {
        let fileManager = FileManager.default
        let url = stagingURL(for: identifier)
        do {
            guard fileManager.fileExists(atPath: url.path) else {
                throw MediaImportError.finalizationFailed
            }

            try protectionOperation(url)
        } catch let error as MediaImportError {
            throw error
        } catch {
            throw MediaImportError.finalizationFailed
        }
    }

    /// Promotes protected staging bytes or verifies an already promoted resource.
    ///
    /// An existing final path is reusable only when its size and digest match the
    /// journal. Failed verification leaves both paths untouched for reconciliation.
    func promoteOrVerify(
        stagingURL: URL,
        resourceID: UUID,
        byteCount: Int64,
        sha256: String,
    ) throws -> String {
        let relativePath = resourceID.uuidString.lowercased()
        let finalURL = rootURL.appendingPathComponent(relativePath, isDirectory: false)
        let expectedStagingURL = self.stagingURL(for: resourceID)
        let fileManager = FileManager.default

        guard stagingURL.standardizedFileURL == expectedStagingURL,
              byteCount >= 0,
              sha256.count == 64
        else {
            throw MediaImportError.finalizationFailed
        }

        do {
            if fileManager.fileExists(atPath: finalURL.path) {
                try verify(finalURL, byteCount: byteCount, sha256: sha256)
                try protectionOperation(finalURL)
                return relativePath
            }

            guard fileManager.fileExists(atPath: expectedStagingURL.path) else {
                throw MediaImportError.finalizationFailed
            }

            try verify(expectedStagingURL, byteCount: byteCount, sha256: sha256)
            try protectionOperation(expectedStagingURL)
            try fileManager.moveItem(at: expectedStagingURL, to: finalURL)
            try protectionOperation(finalURL)
            try verify(finalURL, byteCount: byteCount, sha256: sha256)
            return relativePath
        } catch let error as MediaImportError {
            throw error
        } catch {
            throw MediaImportError.finalizationFailed
        }
    }

    /// Moves a staged resource to its opaque final path and returns the database-relative path.
    ///
    /// If protecting the moved file fails, the repository attempts to remove that new final file.
    public func finalize(stagingURL: URL, resourceID: UUID) throws -> String {
        let relativePath = resourceID.uuidString.lowercased()
        let finalURL = rootURL.appendingPathComponent(relativePath, isDirectory: false)
        let fileManager = FileManager.default
        var didMove = false
        defer {
            if didMove {
                removeFinalizedResourceIfPresent(for: resourceID)
            }
        }

        do {
            guard stagingURL.standardizedFileURL == self.stagingURL(for: resourceID),
                  fileManager.fileExists(atPath: stagingURL.path),
                  !fileManager.fileExists(atPath: finalURL.path)
            else {
                throw MediaImportError.finalizationFailed
            }

            try protectionOperation(stagingURL)
            try fileManager.moveItem(at: stagingURL, to: finalURL)
            didMove = true
            try protectionOperation(finalURL)
            didMove = false
            return relativePath
        } catch let error as MediaImportError {
            throw error
        } catch {
            throw MediaImportError.finalizationFailed
        }
    }

    /// Returns the final URL for a resource's opaque relative path.
    public func url(for resource: MediaResource) -> URL {
        rootURL.appendingPathComponent(resource.relativePath, isDirectory: false)
    }

    /// Reads accepted bytes before image decoding classifies their contents.
    func readAcceptedResource(at url: URL) throws -> Data {
        try acceptedResourceReadOperation(url)
    }

    /// Loads canonical bytes after validating that the database path remains relative and opaque.
    public func data(for resource: MediaResource) throws -> Data {
        guard resource.relativePath == resource.id.uuidString.lowercased(),
              !resource.relativePath.contains("/"),
              !resource.relativePath.contains("\\"),
              resource.byteCount >= 0,
              resource.sha256.count == 64
        else {
            throw MediaLibraryStoreError.corrupt
        }

        do {
            let data = try Data(contentsOf: url(for: resource), options: [.mappedIfSafe])
            guard Int64(data.count) == resource.byteCount,
                  SHA256.hash(data: data).hexString == resource.sha256
            else {
                throw MediaLibraryStoreError.corrupt
            }

            return data
        } catch let error as MediaLibraryStoreError {
            throw error
        } catch {
            throw MediaLibraryStoreError.unavailable
        }
    }

    /// Removes an unfinalized staging file when cleanup is certain.
    public func removeStagingIfPresent(at url: URL) {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: url.path) else {
            return
        }

        try? fileManager.removeItem(at: url)
    }

    /// Removes a finalized resource when its metadata commit did not complete.
    public func removeFinalizedResourceIfPresent(for resourceID: UUID) {
        let fileManager = FileManager.default
        let url = rootURL.appendingPathComponent(resourceID.uuidString.lowercased(), isDirectory: false)
        guard fileManager.fileExists(atPath: url.path) else {
            return
        }

        try? fileManager.removeItem(at: url)
    }

    private static func applyCompleteProtection(to url: URL, using fileManager: FileManager) throws {
        try fileManager.setAttributes(
            [.protectionKey: FileProtectionType.complete],
            ofItemAtPath: url.path,
        )
    }

    private func verify(_ url: URL, byteCount: Int64, sha256: String) throws {
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        guard Int64(data.count) == byteCount,
              SHA256.hash(data: data).hexString == sha256
        else {
            throw MediaImportError.finalizationFailed
        }
    }
}

/// Copies a document-provider URL while any security-scoped access is valid.
public struct MediaSourceClient: Sendable {
    private let copyOperation: @Sendable (URL, URL) throws -> Void

    /// Creates a source client from a caller-owned copy operation.
    @preconcurrency
    public init(copyOperation: @escaping @Sendable (URL, URL) throws -> Void) {
        self.copyOperation = copyOperation
    }

    /// Copies a source URL into the supplied staging URL.
    public func copyToStaging(from sourceURL: URL, to stagingURL: URL) throws {
        try copyOperation(sourceURL, stagingURL)
    }

    /// The production adapter for Files/document-provider URLs.
    public static let live = Self { sourceURL, stagingURL in
        let hasSecurityScopedAccess = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if hasSecurityScopedAccess {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }

        let fileManager = FileManager.default
        guard fileManager.isReadableFile(atPath: sourceURL.path),
              let values = try? sourceURL.resourceValues(forKeys: [.isDirectoryKey]),
              values.isDirectory != true
        else {
            throw MediaImportError.sourceAccessFailed
        }

        do {
            try fileManager.copyItem(at: sourceURL, to: stagingURL)
        } catch {
            throw MediaImportError.sourceAccessFailed
        }
    }

    /// A test adapter for local temporary files that uses the same byte-copy operation.
    public static let localFile = Self { sourceURL, stagingURL in
        do {
            try FileManager.default.copyItem(at: sourceURL, to: stagingURL)
        } catch {
            throw MediaImportError.sourceAccessFailed
        }
    }
}

/// Imports one source file into the canonical media model and protected resource store.
public actor MediaLibraryImporter {
    private let store: SQLiteMediaLibraryStore
    private let resources: FileMediaResourceRepository
    private let source: MediaSourceClient
    private let id: @Sendable () -> UUID
    private let now: @Sendable () -> Date

    /// Creates an importer with explicit storage and source-access seams.
    @preconcurrency
    public init(
        store: SQLiteMediaLibraryStore,
        resources: FileMediaResourceRepository,
        source: MediaSourceClient = .live,
        id: @escaping @Sendable () -> UUID = UUID.init,
        now: @escaping @Sendable () -> Date = Date.init,
    ) {
        self.store = store
        self.resources = resources
        self.source = source
        self.id = id
        self.now = now
    }

    /// Copies, validates, and durably commits one ordinary still image.
    public func importFile(at sourceURL: URL) async throws -> MediaAsset {
        let assetID = id()
        let resourceID = id()
        let stagingFileURL = resources.stagingURL(for: resourceID)

        do {
            try source.copyToStaging(from: sourceURL, to: stagingFileURL)
        } catch let error as MediaImportError {
            resources.removeStagingIfPresent(at: stagingFileURL)
            throw error
        } catch {
            resources.removeStagingIfPresent(at: stagingFileURL)
            throw MediaImportError.sourceAccessFailed
        }
        do {
            try resources.protectStaging(for: resourceID)
        } catch {
            resources.removeStagingIfPresent(at: stagingFileURL)
            throw error
        }

        let entry = MediaIngestionJournalEntry(
            id: assetID,
            resourceID: resourceID,
            state: .received,
            sourceFilename: sourceURL.lastPathComponent,
            importedAt: now(),
        )

        do {
            try await store.ingestionJournal.accept(entry)
        } catch {
            throw MediaImportError.persistenceFailed
        }

        do {
            return try await resume(entry)
        } catch let error as MediaImportError {
            throw error
        } catch {
            throw MediaImportError.persistenceFailed
        }
    }

    /// Reconciles durable imports before returning canonical Library assets.
    public func loadAssets() async throws -> [MediaAsset] {
        let existingAssets = try await store.loadAssets()
        let blockedIDs = await reconcile(using: existingAssets)
        return try await store.loadAssets().filter { !blockedIDs.contains($0.id) }
    }

    /// Resumes eligible imports without exposing journal transitions to clients.
    public func reconcile() async throws {
        let existingAssets = try await store.loadAssets()
        _ = await reconcile(using: existingAssets)
    }

    private func reconcile(using existingAssets: [MediaAsset]) async -> Set<UUID> {
        let snapshot: MediaIngestionJournalSnapshot
        do {
            snapshot = try await store.ingestionJournal.snapshot()
        } catch {
            // A journal read failure cannot invalidate already committed canonical rows.
            return []
        }

        var blockedIDs = snapshot.unreadableAssetIDs
        let existingIDs = Set(existingAssets.map(\.id))
        var occupiedAssetIDs = existingIDs
        occupiedAssetIDs.formUnion(snapshot.entries.map(\.id))
        occupiedAssetIDs.formUnion(snapshot.unreadableAssetIDs)
        for resourceID in resources.stagedResourceIDs() where !snapshot.knownResourceIDs.contains(resourceID) {
            var orphanAssetID = UUID()
            while occupiedAssetIDs.contains(orphanAssetID) {
                orphanAssetID = UUID()
            }
            occupiedAssetIDs.insert(orphanAssetID)
            do {
                try resources.protectStaging(for: resourceID)
            } catch {
                continue
            }
            try? await store.ingestionJournal.preserveUnjournaledStaging(
                assetID: orphanAssetID,
                resourceID: resourceID,
                recordedAt: now(),
            )
        }
        for entry in snapshot.entries {
            do {
                _ = try await resume(entry)
            } catch {
                blockedIDs.insert(entry.id)
            }
        }
        return blockedIDs
    }

    private func resume(_ initialEntry: MediaIngestionJournalEntry) async throws -> MediaAsset {
        var entry = initialEntry

        while true {
            switch entry.state {
            case .received:
                entry = try await store.ingestionJournal.transition(entry, to: .validating)
            case .validating:
                let stageURL = resources.stagingURL(for: entry.resourceID)
                let finalURL = resources.url(for: resource(for: entry))
                let inspection: ImageInspection
                do {
                    if FileManager.default.fileExists(atPath: stageURL.path) {
                        inspection = try inspectStillImage(at: stageURL)
                    } else if FileManager.default.fileExists(atPath: finalURL.path) {
                        inspection = try inspectStillImage(at: finalURL)
                    } else {
                        throw AcceptedResourceReadError()
                    }
                } catch let error as MediaImportError {
                    try? await store.ingestionJournal.transition(entry, to: .failed)
                    throw error
                }
                entry = try await store.ingestionJournal.transition(
                    entry,
                    to: .duplicateCheck,
                    inspection: inspection,
                )
            case .duplicateCheck:
                entry = try await store.ingestionJournal.transition(entry, to: .ready)
            case .ready:
                entry = try await store.ingestionJournal.transition(entry, to: .committing)
            case .committing:
                let asset = try makeAsset(from: entry)
                _ = try resources.promoteOrVerify(
                    stagingURL: resources.stagingURL(for: entry.resourceID),
                    resourceID: entry.resourceID,
                    byteCount: requiredByteCount(in: entry),
                    sha256: requiredSHA256(in: entry),
                )
                try await store.commit(asset, completingIngestion: entry.id)
                entry = entry.advancing(to: .complete)
            case .complete:
                let asset = try makeAsset(from: entry)
                _ = try resources.promoteOrVerify(
                    stagingURL: resources.stagingURL(for: entry.resourceID),
                    resourceID: entry.resourceID,
                    byteCount: requiredByteCount(in: entry),
                    sha256: requiredSHA256(in: entry),
                )
                let storedAssets = try await store.loadAssets()
                if let storedAsset = storedAssets.first(where: { $0.id == entry.id }) {
                    guard storedAsset == asset else {
                        throw MediaLibraryStoreError.corrupt
                    }
                } else {
                    try await store.commit(asset, completingIngestion: entry.id)
                }
                guard let resource = asset.resources.first else {
                    throw MediaLibraryStoreError.corrupt
                }

                _ = try resources.data(for: resource)
                do {
                    try await store.ingestionJournal.compactCompleteEntry(for: entry.id)
                } catch {
                    // Verified canonical state remains visible if compaction can be retried later.
                }
                return asset
            case .awaitingUserDecision,
                 .failed,
                 .cancelled:
                throw MediaLibraryStoreError.corrupt
            }
        }
    }

    private func makeAsset(from entry: MediaIngestionJournalEntry) throws -> MediaAsset {
        let resource = resource(for: entry)
        guard resource.byteCount >= 0, resource.sha256.count == 64,
              let sourceUTI = entry.sourceUTI, !sourceUTI.isEmpty
        else {
            throw MediaLibraryStoreError.corrupt
        }

        return MediaAsset(
            id: entry.id,
            kind: .stillImage,
            importedAt: entry.importedAt,
            resources: [
                MediaResource(
                    id: resource.id,
                    role: resource.role,
                    relativePath: resource.relativePath,
                    sourceFilename: resource.sourceFilename,
                    sourceUTI: sourceUTI,
                    byteCount: resource.byteCount,
                    sha256: resource.sha256,
                ),
            ],
            capturedAt: entry.capturedAt,
        )
    }

    private func resource(for entry: MediaIngestionJournalEntry) -> MediaResource {
        MediaResource(
            id: entry.resourceID,
            role: .original,
            relativePath: entry.resourceID.uuidString.lowercased(),
            sourceFilename: entry.sourceFilename,
            sourceUTI: entry.sourceUTI ?? "",
            byteCount: entry.byteCount ?? -1,
            sha256: entry.sha256 ?? "",
        )
    }

    private func requiredByteCount(in entry: MediaIngestionJournalEntry) throws -> Int64 {
        guard let byteCount = entry.byteCount, byteCount >= 0 else {
            throw MediaLibraryStoreError.corrupt
        }

        return byteCount
    }

    private func requiredSHA256(in entry: MediaIngestionJournalEntry) throws -> String {
        guard let sha256 = entry.sha256, sha256.count == 64 else {
            throw MediaLibraryStoreError.corrupt
        }

        return sha256
    }

    private func inspectStillImage(at url: URL) throws -> ImageInspection {
        let bytes: Data
        do {
            bytes = try resources.readAcceptedResource(at: url)
        } catch {
            throw AcceptedResourceReadError()
        }

        guard let imageSource = CGImageSourceCreateWithData(bytes as CFData, nil) else {
            throw MediaImportError.unrenderableMedia
        }

        let count = CGImageSourceGetCount(imageSource)
        guard count > 0 else {
            throw MediaImportError.unrenderableMedia
        }
        guard count == 1 else {
            throw MediaImportError.unsupportedMedia
        }
        guard let image = CGImageSourceCreateImageAtIndex(imageSource, 0, nil), image.width > 0, image.height > 0 else {
            throw MediaImportError.unrenderableMedia
        }
        guard let sourceType = CGImageSourceGetType(imageSource) else {
            throw MediaImportError.unrenderableMedia
        }

        let sourceTypeString = sourceType as String
        guard let type = UTType(sourceTypeString),
              type.conforms(to: .image),
              !type.conforms(to: .rawImage),
              type != .livePhoto
        else {
            throw MediaImportError.unsupportedMedia
        }

        let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [String: Any]
        return ImageInspection(
            uti: sourceTypeString,
            byteCount: Int64(bytes.count),
            sha256: SHA256.hash(data: bytes).hexString,
            capturedAt: captureDate(from: properties),
        )
    }

    private func captureDate(from properties: [String: Any]?) -> Date? {
        let exifKey = kCGImagePropertyExifDictionary as String
        let dateKey = kCGImagePropertyExifDateTimeOriginal as String
        let value = properties?[exifKey] as? [String: Any]
        guard let dateString = value?[dateKey] as? String else {
            return nil
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return formatter.date(from: dateString)
    }
}

/// Keeps accepted work resumable when its bytes cannot currently be read.
private struct AcceptedResourceReadError: Error, Sendable {}

struct ImageInspection: Sendable {
    let uti: String
    let byteCount: Int64
    let sha256: String
    let capturedAt: Date?
}

extension SHA256.Digest {
    fileprivate var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
