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
    private let generation = Mutex<UInt64>(0)

    var currentGeneration: UInt64 {
        generation.withLock { $0 }
    }

    func advance() {
        generation.withLock { $0 &+= 1 }
    }

    func claimRead(generation requestedGeneration: UInt64) -> Bool {
        generation.withLock { $0 == requestedGeneration }
    }

    func isCurrent(_ requestedGeneration: UInt64) -> Bool {
        generation.withLock { $0 == requestedGeneration }
    }

    /// Grants admission atomically with lock generation changes, then releases the mutex before I/O.
    func claimImportAdmission(generation requestedGeneration: UInt64) -> MediaLibraryImportAdmission? {
        generation.withLock { currentGeneration in
            guard currentGeneration == requestedGeneration else {
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
            let libraryRoot = appSupport.appendingPathComponent("PrivateLibrary", isDirectory: true)
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
            )

            return Self(
                loadAssets: { try await importer.loadAssets() },
                importFile: { try await importer.importFile(at: $0) },
                resourceData: { try resources.data(for: $0) },
                resourceDataSynchronously: { try resources.data(for: $0) },
                resourceLoadFence: resourceLoadFence,
                importFileForSession: { url, generation in
                    try await importer.importFile(at: url, sessionGeneration: generation)
                },
            )
        } catch {
            return unavailableValue
        }
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
