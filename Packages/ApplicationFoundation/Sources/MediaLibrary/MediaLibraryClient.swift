//
//  MediaLibraryClient.swift
//  MediaVault
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Dependencies
import Foundation
import PersistenceSupport

/// The dependency boundary used by the TCA media-library feature.
public struct MediaLibraryClient: Sendable {
    /// Loads all assets committed to the vault store.
    public var loadAssets: @Sendable () async throws -> [MediaAsset]

    /// Imports one source URL and returns it only after canonical commit.
    public var importFile: @Sendable (URL) async throws -> MediaAsset

    /// Loads exact canonical bytes for rendering a committed resource.
    public var resourceData: @Sendable (MediaResource) async throws -> Data

    /// Creates an explicit media-library dependency.
    @preconcurrency
    public init(
        loadAssets: @escaping @Sendable () async throws -> [MediaAsset],
        importFile: @escaping @Sendable (URL) async throws -> MediaAsset,
        resourceData: @escaping @Sendable (MediaResource) async throws -> Data,
    ) {
        self.loadAssets = loadAssets
        self.importFile = importFile
        self.resourceData = resourceData
    }
}

extension MediaLibraryClient: DependencyKey {
    /// The production media-library dependency.
    public static let liveValue = makeLive()

    /// The deterministic dependency used when tests do not override the client.
    public static let testValue = Self(
        loadAssets: { [] },
        importFile: { _ in throw MediaLibraryStoreError.unavailable },
        resourceData: { _ in throw MediaLibraryStoreError.unavailable },
    )

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
            let importer = MediaLibraryImporter(store: store, resources: resources)

            return Self(
                loadAssets: { try await store.loadAssets() },
                importFile: { try await importer.importFile(at: $0) },
                resourceData: { try resources.data(for: $0) },
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
