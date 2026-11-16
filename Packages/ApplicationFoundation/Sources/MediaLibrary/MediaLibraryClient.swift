//
//  MediaLibraryClient.swift
//  MediaVault
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Dependencies
import Entitlement
import Foundation
import PersistenceSupport
import Synchronization

/// Records a fresh-import authorization granted by the session fence.
struct MediaLibraryImportAdmission: Sendable {
    private let generation: UInt64?

    fileprivate init(generation: UInt64?) {
        self.generation = generation
    }

    static let unscoped = Self(generation: nil)

    func matches(_ generation: UInt64?) -> Bool {
        self.generation == generation
    }
}

/// Linearizes resource reads and fresh-import admission with the global vault-lock boundary.
final class MediaLibraryResourceLoadFence: Sendable {
    private struct State {
        var generation: UInt64 = 0
        var downloadAuthorized = false
        var downloadProcessingActive = true
        var downloadGeneration: UInt64 = 0
        var discardedDownloadIDs = Set<UUID>()
    }

    private let generation = Mutex(State())

    var currentGeneration: UInt64 {
        generation.withLock { $0.generation }
    }

    func advance() {
        generation.withLock {
            $0.generation &+= 1
            $0.downloadGeneration &+= 1
            $0.downloadAuthorized = false
        }
    }

    func claimRead(generation requestedGeneration: UInt64) -> Bool {
        generation.withLock { $0.generation == requestedGeneration }
    }

    func isCurrent(_ requestedGeneration: UInt64) -> Bool {
        generation.withLock { $0.generation == requestedGeneration }
    }

    func beginAuthenticatedDownloadSession() -> UInt64 {
        generation.withLock {
            $0.downloadGeneration &+= 1
            $0.downloadAuthorized = true
            return $0.downloadGeneration
        }
    }

    var currentDownloadIngestionGeneration: UInt64 {
        generation.withLock { $0.downloadGeneration }
    }

    @discardableResult
    func setDownloadProcessingActive(_ active: Bool) -> UInt64 {
        generation.withLock {
            if $0.downloadProcessingActive != active {
                $0.downloadProcessingActive = active
                $0.downloadGeneration &+= 1
            }
            return $0.downloadGeneration
        }
    }

    func suspendDownloadIngestion() {
        setDownloadProcessingActive(false)
    }

    func isDownloadSessionCurrent(_ requestedGeneration: UInt64) -> Bool {
        generation
            .withLock {
                $0.downloadAuthorized && $0.downloadProcessingActive && $0.downloadGeneration == requestedGeneration
            }
    }

    /// Revokes only this operation's unclaimed transaction before asynchronous cleanup queues.
    func invalidateDownload(_ operationID: UUID) {
        _ = generation.withLock { $0.discardedDownloadIDs.insert(operationID) }
    }

    /// The operation identifier binds this permission to one final disk transaction.
    func claimDownloadCommit(operationID: UUID, generation requestedGeneration: UInt64) -> DownloadCommitClaim? {
        generation.withLock {
            guard $0.downloadAuthorized, $0.downloadProcessingActive,
                  $0.downloadGeneration == requestedGeneration,
                  !$0.discardedDownloadIDs.contains(operationID) else {
                return nil
            }

            return DownloadCommitClaim(operationID: operationID)
        }
    }

    /// Grants admission atomically with lock generation changes, then releases the mutex before I/O.
    func claimImportAdmission(generation requestedGeneration: UInt64) -> MediaLibraryImportAdmission? {
        generation.withLock { currentGeneration in
            guard currentGeneration.generation == requestedGeneration else {
                return nil
            }

            return MediaLibraryImportAdmission(generation: requestedGeneration)
        }
    }
}

/// The dependency boundary used by the TCA media-library feature.
public struct MediaLibraryClient: Sendable {
    /// Loads all assets committed to the vault store.
    public var loadAssets: @Sendable () async throws -> [MediaAsset]

    /// Recovers accepted work, checks fresh-import admission, and returns after canonical commit.
    public var importFile: @Sendable (URL) async throws -> MediaAsset

    /// Loads exact canonical bytes for rendering a committed resource.
    public var resourceData: @Sendable (MediaResource) async throws -> Data

    private var acceptCompletedDownloadOperation: @Sendable (URL, UUID, String) async throws -> Void = { _, _, _ in
        throw MediaImportError.persistenceFailed
    }

    private var reconcileAcceptedDownloadsOperation: @Sendable (UInt64) async
        -> [UUID: CompletedDownloadOutcome] = { _ in
            [:]
        }

    private var discardAcceptedDownloadOperation: @Sendable (UUID) async throws -> Void = { _ in
        throw MediaImportError.persistenceFailed
    }

    private var acceptedDownloadStorageOperation: @Sendable () async throws -> AcceptedDownloadStorage = {
        throw MediaImportError.persistenceFailed
    }

    private var completedDownloadPresentationURLOperation: @Sendable (UUID, UInt64) async throws -> URL? = { _, _ in
        nil
    }

    /// Resolves an existing protected resource without making a presentation copy.
    public func completedDownloadPresentationURL(operationID: UUID, generation: UInt64) async throws -> URL? {
        guard resourceLoadFence.isDownloadSessionCurrent(generation) else {
            return nil
        }

        do {
            let url = try await completedDownloadPresentationURLOperation(operationID, generation)
            return resourceLoadFence.isDownloadSessionCurrent(generation) ? url : nil
        } catch {
            guard resourceLoadFence.isDownloadSessionCurrent(generation) else {
                return nil
            }

            throw error
        }
    }

    /// Accepts caller-verified terminal bytes without requiring a presentation session.
    /// The caller must prove native success, stopped writing, and verified completed bytes.
    public func acceptCompletedDownload(_ url: URL, operationID: UUID, originalFilename: String) async throws {
        try await acceptCompletedDownloadOperation(url, operationID, originalFilename)
    }

    /// Returns private outcomes only while the supplied authenticated generation remains current.
    public func reconcileAcceptedDownloads(generation: UInt64) async -> [UUID: CompletedDownloadOutcome] {
        await reconcileAcceptedDownloadsOperation(generation)
    }

    /// Revokes this operation's unclaimed commit permission without changing canonical read access.
    public func revokeAcceptedDownload(operationID: UUID) {
        resourceLoadFence.invalidateDownload(operationID)
    }

    /// Discards accepted temporary bytes; a committed canonical asset is never removed.
    public func discardAcceptedDownload(operationID: UUID) async throws {
        revokeAcceptedDownload(operationID: operationID)
        try await discardAcceptedDownloadOperation(operationID)
    }

    /// Recovers interrupted ownership before native scratch purge and reports retained capacity.
    /// A failed handoff throws; the caller must preserve native scratch until recovery succeeds.
    public func acceptedDownloadStorage() async throws -> AcceptedDownloadStorage {
        try await acceptedDownloadStorageOperation()
    }

    /// The generation used to fence browser ingestion and private download presentation.
    public var currentDownloadIngestionGeneration: UInt64 {
        resourceLoadFence.currentDownloadIngestionGeneration
    }

    /// Changes foreground eligibility without granting authentication or reviving stale work.
    @discardableResult
    public func setDownloadProcessingActive(_ active: Bool) -> UInt64 {
        resourceLoadFence.setDownloadProcessingActive(active)
    }

    /// Pauses browser processing across inactivity without invalidating ordinary Library reads.
    public func suspendDownloadIngestion() {
        resourceLoadFence.suspendDownloadIngestion()
    }

    /// Grants browser processing after successful authentication; Lock revokes it synchronously.
    public func beginAuthenticatedDownloadSession() -> UInt64 {
        resourceLoadFence.beginAuthenticatedDownloadSession()
    }

    private let resourceDataSynchronously: (@Sendable (MediaResource) throws -> Data)?
    private let resourceLoadFence: MediaLibraryResourceLoadFence
    private let importFileForSession: (@Sendable (URL, UInt64) async throws -> MediaAsset)?

    /// The generation captured by resource-load effects before they start.
    public var currentResourceLoadGeneration: UInt64 {
        resourceLoadFence.currentGeneration
    }

    /// Creates an explicit media-library dependency.
    public init(
        loadAssets: @escaping @Sendable () async throws -> [MediaAsset],
        importFile: @escaping @Sendable (URL) async throws -> MediaAsset,
        resourceData: @escaping @Sendable (MediaResource) async throws -> Data,
        resourceDataSynchronously: (@Sendable (MediaResource) throws -> Data)? = nil,
    ) {
        let newResourceLoadFence = MediaLibraryResourceLoadFence()
        self.init(
            loadAssets: loadAssets,
            importFile: importFile,
            resourceData: resourceData,
            resourceDataSynchronously: resourceDataSynchronously,
            resourceLoadFence: newResourceLoadFence,
            importFileForSession: nil,
        )
    }

    fileprivate init(
        loadAssets: @escaping @Sendable () async throws -> [MediaAsset],
        importFile: @escaping @Sendable (URL) async throws -> MediaAsset,
        resourceData: @escaping @Sendable (MediaResource) async throws -> Data,
        resourceDataSynchronously: (@Sendable (MediaResource) throws -> Data)?,
        resourceLoadFence: MediaLibraryResourceLoadFence,
        importFileForSession: (@Sendable (URL, UInt64) async throws -> MediaAsset)?,
    ) {
        self.loadAssets = loadAssets
        self.importFile = importFile
        self.resourceData = resourceData
        self.resourceDataSynchronously = resourceDataSynchronously
        self.resourceLoadFence = resourceLoadFence
        self.importFileForSession = importFileForSession
    }

    /// Advances the resource-read generation at the synchronous global-lock boundary.
    public func advanceResourceLoadGeneration() {
        resourceLoadFence.advance()
    }

    /// Runs an import only while its starting session remains current.
    ///
    /// The live importer checks again after serialized recovery and entitlement lookup, before it
    /// stages a new file.
    public func importFileIfCurrent(_ url: URL, generation: UInt64) async throws -> MediaAsset {
        guard resourceLoadFence.isCurrent(generation) else {
            throw CancellationError()
        }
        guard let sessionAwareImport = importFileForSession else {
            return try await importFile(url)
        }

        return try await sessionAwareImport(url, generation)
    }

    /// Starts a resource read only when its captured session generation is still current.
    ///
    /// Live file reads claim permission synchronously before starting I/O. A read authorized
    /// before lock may finish afterward, but its result is discarded when its generation is stale.
    public func resourceDataIfCurrent(
        _ resource: MediaResource,
        generation: UInt64,
    ) async throws -> Data? {
        if let resourceDataSynchronously {
            guard resourceLoadFence.claimRead(generation: generation) else {
                return nil
            }

            let data = try resourceDataSynchronously(resource)
            return resourceLoadFence.isCurrent(generation) ? data : nil
        }

        guard resourceLoadFence.claimRead(generation: generation) else {
            return nil
        }

        let data = try await resourceData(resource)
        return resourceLoadFence.isCurrent(generation) ? data : nil
    }
}

extension MediaLibraryClient: DependencyKey {
    /// The production media-library dependency.
    public static let liveValue = makeLive()

    /// The deterministic dependency used when tests do not override the client.
    public static var testValue: Self {
        Self(
            loadAssets: { [] },
            importFile: { _ in throw MediaLibraryStoreError.unavailable },
            resourceData: { _ in throw MediaLibraryStoreError.unavailable },
        )
    }

    private static func makeLive() -> Self {
        do {
            let appSupport = try FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true,
            )
            return try live(at: appSupport.appendingPathComponent("PrivateLibrary", isDirectory: true))
        } catch {
            return unavailableValue
        }
    }

    /// Creates an isolated live Library with the same database and protection policy as production.
    public static func live(at libraryRoot: URL) throws -> Self {
        try FileManager.default.createDirectory(at: libraryRoot, withIntermediateDirectories: true)
        try FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.complete],
            ofItemAtPath: libraryRoot.path,
        )

        let databaseURL = libraryRoot.appendingPathComponent("library.sqlite")
        let database = try PersistenceStore.makePersistent(at: databaseURL)
        try FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.complete],
            ofItemAtPath: databaseURL.path,
        )
        let store = SQLiteMediaLibraryStore(database: database)
        let resources = try FileMediaResourceRepository(
            rootURL: libraryRoot.appendingPathComponent("resources", isDirectory: true),
        )
        let resourceLoadFence = MediaLibraryResourceLoadFence()
        let importer = MediaLibraryImporter(
            store: store,
            resources: resources,
            entitlement: .liveValue,
            sessionIsCurrent: { resourceLoadFence.isCurrent($0) },
            sessionAdmission: { resourceLoadFence.claimImportAdmission(generation: $0) },
            downloadSessionIsCurrent: { resourceLoadFence.isDownloadSessionCurrent($0) },
            downloadCommitClaim: { resourceLoadFence.claimDownloadCommit(operationID: $0, generation: $1) },
            downloadDiscardRequest: { resourceLoadFence.invalidateDownload($0) },
        )

        return connected(importer: importer, resources: resources, resourceLoadFence: resourceLoadFence)
    }

    /// Connects the live client operations to the same importer, resources, and synchronous fence.
    static func connected(
        importer: MediaLibraryImporter,
        resources: FileMediaResourceRepository,
        resourceLoadFence: MediaLibraryResourceLoadFence,
    ) -> Self {
        var client = Self(
            loadAssets: {
                _ = await importer.reconcileAcceptedDownloads(
                    generation: resourceLoadFence.currentDownloadIngestionGeneration,
                )
                return try await importer.loadAssets()
            },
            importFile: { try await importer.importFile(at: $0) },
            resourceData: { try resources.data(for: $0) },
            resourceDataSynchronously: { try resources.data(for: $0) },
            resourceLoadFence: resourceLoadFence,
            importFileForSession: { url, generation in
                try await importer.importFile(at: url, sessionGeneration: generation)
            },
        )
        client.acceptCompletedDownloadOperation = { url, operationID, filename in
            try await importer.acceptCompletedDownload(url, operationID: operationID, originalFilename: filename)
        }
        client.reconcileAcceptedDownloadsOperation = { generation in
            await importer.reconcileAcceptedDownloads(generation: generation)
        }
        client.discardAcceptedDownloadOperation = { operationID in
            try await importer.discardAcceptedDownload(operationID: operationID)
        }
        client.acceptedDownloadStorageOperation = { try await importer.acceptedDownloadStorage() }
        client.completedDownloadPresentationURLOperation = { operationID, generation in
            try await importer.completedDownloadPresentationURL(operationID: operationID, generation: generation)
        }
        return client
    }

    private static var unavailableValue: Self {
        Self(
            loadAssets: { throw MediaLibraryStoreError.unavailable },
            importFile: { _ in throw MediaImportError.persistenceFailed },
            resourceData: { _ in throw MediaLibraryStoreError.unavailable },
        )
    }
}

extension DependencyValues {
    /// The canonical media-library store and import dependency.
    public var mediaLibrary: MediaLibraryClient {
        get { self[MediaLibraryClient.self] }
        set { self[MediaLibraryClient.self] = newValue }
    }
}
