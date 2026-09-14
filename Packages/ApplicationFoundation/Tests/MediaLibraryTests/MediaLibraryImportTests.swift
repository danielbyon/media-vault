//
//  MediaLibraryImportTests.swift
//  MediaVault
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import CryptoKit
import Foundation
import ImageIO
@_spi(Testing) import MediaLibrary
import PersistenceSupport
import Testing
import UniformTypeIdentifiers

@Suite("Media library import")
struct MediaLibraryImportTests {
    @Test("A supported still import preserves bytes, hash, relationship, and reload")
    func importsOneStillImage() async throws {
        let environment = try makeEnvironment()

        let asset = try await environment.importer.importFile(at: environment.sourceURL)

        #expect(asset.kind == .stillImage)
        #expect(asset.resources.count == 1)
        let resource = try #require(asset.resources.first)
        #expect(resource.sourceFilename == "holiday-photo.png")
        #expect(resource.sourceUTI == "public.png")
        #expect(resource.byteCount == Int64(environment.sourceBytes.count))
        #expect(resource.sha256 == SHA256.hash(data: environment.sourceBytes).hexString)
        #expect(resource.relativePath == resource.id.uuidString.lowercased())
        #expect(!resource.relativePath.contains("holiday-photo"))

        let finalURL = environment.resources.url(for: resource)
        #expect(try Data(contentsOf: finalURL) == environment.sourceBytes)
        #expect(try environment.resources.data(for: resource) == environment.sourceBytes)
        #expect(try await environment.store.loadAssets() == [asset])
        let attributes = try FileManager.default.attributesOfItem(atPath: finalURL.path)
        let protection = attributes[.protectionKey] as? FileProtectionType
        #if targetEnvironment(simulator)
        #expect(protection == nil || protection == .complete)
        #else
        #expect(protection == .complete)
        #endif
        #expect(
            !FileManager.default.fileExists(
                atPath: environment.resources.stagingURL(for: resource.id).path,
            ),
        )
    }

    @Test("Animated multi-frame images are rejected before canonical commit")
    func rejectsAnimatedImage() async throws {
        let environment = try makeEnvironment()
        let animatedURL = environment.root.appendingPathComponent("animated.gif")
        try makeAnimatedGIF(at: animatedURL, using: environment.sourceBytes)

        await #expect(throws: MediaImportError.unsupportedMedia) {
            try await environment.importer.importFile(at: animatedURL)
        }

        #expect(try await environment.store.loadAssets().isEmpty)
        #expect(
            !FileManager.default.fileExists(
                atPath: environment.resources.stagingURL(for: TestFixtures.resourceID).path,
            ),
        )
        #expect(finalResourceURLs(in: environment.resources).isEmpty)
    }

    @Test("Invalid bytes are rejected as unrenderable without a Library row")
    func rejectsUnrenderableImage() async throws {
        let environment = try makeEnvironment()
        let invalidURL = environment.root.appendingPathComponent("broken.png")
        try Data([0x00, 0x01, 0x02, 0x03]).write(to: invalidURL)

        await #expect(throws: MediaImportError.unrenderableMedia) {
            try await environment.importer.importFile(at: invalidURL)
        }

        #expect(try await environment.store.loadAssets().isEmpty)
        #expect(finalResourceURLs(in: environment.resources).isEmpty)
    }

    @Test("Source access failure produces no canonical resource or asset")
    func rejectsSourceAccessFailure() async throws {
        let environment = try makeEnvironment()
        let missingURL = environment.root.appendingPathComponent("missing.png")

        await #expect(throws: MediaImportError.sourceAccessFailed) {
            try await environment.importer.importFile(at: missingURL)
        }

        #expect(try await environment.store.loadAssets().isEmpty)
        #expect(finalResourceURLs(in: environment.resources).isEmpty)
    }

    @Test("Resource finalization failure preserves the pre-existing final resource")
    func rejectsResourceFinalizationFailure() async throws {
        let environment = try makeEnvironment()
        let preexistingBytes = Data([0xde, 0xad, 0xbe, 0xef])
        let preexistingResource = MediaResource(
            id: TestFixtures.resourceID,
            role: .original,
            relativePath: TestFixtures.resourceID.uuidString.lowercased(),
            sourceFilename: "existing.png",
            sourceUTI: "public.png",
            byteCount: Int64(preexistingBytes.count),
            sha256: SHA256.hash(data: preexistingBytes).hexString,
        )
        let preexistingURL = environment.resources.url(for: preexistingResource)
        try preexistingBytes.write(to: preexistingURL)

        await #expect(throws: MediaImportError.finalizationFailed) {
            try await environment.importer.importFile(at: environment.sourceURL)
        }

        #expect(try await environment.store.loadAssets().isEmpty)
        #expect(
            !FileManager.default.fileExists(
                atPath: environment.resources.stagingURL(for: TestFixtures.resourceID).path,
            ),
        )
        #expect(try Data(contentsOf: preexistingURL) == preexistingBytes)
        #expect(finalResourceURLs(in: environment.resources) == [preexistingURL])
    }

    @Test("Post-move finalization failure removes the newly moved resource")
    func rejectsPostMoveFinalizationFailure() async throws {
        let environment = try makeEnvironment { resourcesRoot in
            let finalURL = resourcesRoot.appendingPathComponent(
                TestFixtures.resourceID.uuidString.lowercased(),
                isDirectory: false,
            )
            return try FileMediaResourceRepository(
                rootURL: resourcesRoot,
                protectionOperation: { url in
                    if url == finalURL {
                        #expect(FileManager.default.fileExists(atPath: url.path))
                        throw MediaImportError.finalizationFailed
                    }
                },
            )
        }

        await #expect(throws: MediaImportError.finalizationFailed) {
            try await environment.importer.importFile(at: environment.sourceURL)
        }

        #expect(try await environment.store.loadAssets().isEmpty)
        #expect(
            !FileManager.default.fileExists(
                atPath: environment.resources.stagingURL(for: TestFixtures.resourceID).path,
            ),
        )
        #expect(finalResourceURLs(in: environment.resources).isEmpty)
    }

    @Test("Database commit failure never exposes a visible partial asset")
    func databaseFailureLeavesResourceUnreferenced() async throws {
        let environment = try makeEnvironment(store: FailingMediaLibraryStore())

        await #expect(throws: MediaImportError.persistenceFailed) {
            try await environment.importer.importFile(at: environment.sourceURL)
        }

        #expect(try await environment.store.loadAssets().isEmpty)
        #expect(
            !FileManager.default.fileExists(
                atPath: environment.resources.stagingURL(for: TestFixtures.resourceID).path,
            ),
        )
        let finalizedResource = MediaResource(
            id: TestFixtures.resourceID,
            role: .original,
            relativePath: TestFixtures.resourceID.uuidString.lowercased(),
            sourceFilename: "holiday-photo.png",
            sourceUTI: "public.png",
            byteCount: Int64(environment.sourceBytes.count),
            sha256: SHA256.hash(data: environment.sourceBytes).hexString,
        )
        #expect(
            !FileManager.default.fileExists(
                atPath: environment.resources.url(for: finalizedResource).path,
            ),
        )
        #expect(finalResourceURLs(in: environment.resources).isEmpty)
    }

    @Test("A persistent store reloads the committed asset and exact resource bytes")
    func reloadsPersistentAsset() async throws {
        let environment = try makeEnvironment()
        let databaseURL = environment.root.appendingPathComponent("library.sqlite")
        let asset: MediaAsset = try await {
            let database = try PersistenceStore.makePersistent(at: databaseURL)
            let store = SQLiteMediaLibraryStore(database: database)
            let resources = try FileMediaResourceRepository(
                rootURL: environment.root.appendingPathComponent("resources"),
            )
            let importer = makeImporter(store: store, resources: resources)
            return try await importer.importFile(at: environment.sourceURL)
        }()

        let reopenedDatabase = try PersistenceStore.makePersistent(at: databaseURL)
        let reopenedStore = SQLiteMediaLibraryStore(database: reopenedDatabase)
        let reopenedResources = try FileMediaResourceRepository(
            rootURL: environment.root.appendingPathComponent("resources"),
        )
        let loadedAssets = try await reopenedStore.loadAssets()
        let resource = try #require(asset.resources.first)

        #expect(loadedAssets == [asset])
        #expect(try reopenedResources.data(for: resource) == environment.sourceBytes)
    }

    @Test("The resource boundary rejects semantic paths")
    func rejectsNonOpaqueResourcePath() throws {
        let environment = try makeEnvironment()
        let resource = MediaResource(
            id: TestFixtures.resourceID,
            role: .original,
            relativePath: "holiday-photo.png",
            sourceFilename: "holiday-photo.png",
            sourceUTI: "public.png",
            byteCount: 0,
            sha256: String(repeating: "0", count: 64),
        )

        #expect(throws: MediaLibraryStoreError.corrupt) {
            try environment.resources.data(for: resource)
        }
    }
}

private final class ImportEnvironment {
    let root: URL
    let sourceURL: URL
    let sourceBytes: Data
    let store: any MediaLibraryStore
    let resources: FileMediaResourceRepository
    let importer: MediaLibraryImporter

    init(
        root: URL,
        sourceURL: URL,
        sourceBytes: Data,
        store: any MediaLibraryStore,
        resources: FileMediaResourceRepository,
        importer: MediaLibraryImporter,
    ) {
        self.root = root
        self.sourceURL = sourceURL
        self.sourceBytes = sourceBytes
        self.store = store
        self.resources = resources
        self.importer = importer
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }
}

private enum TestFixtures {
    static let assetID = requiredUUID("00000000-0000-0000-0000-000000000010")
    static let resourceID = requiredUUID("00000000-0000-0000-0000-000000000011")
    static let importedAt = Date(timeIntervalSince1970: 1_725_000_000)
    static let pngData = requiredData(
        base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=",
    )
}

private func makeEnvironment(
    sourceName: String = "holiday-photo.png",
    sourceBytes: Data = TestFixtures.pngData,
    store: (any MediaLibraryStore)? = nil,
    resourcesFactory: (URL) throws -> FileMediaResourceRepository = {
        try FileMediaResourceRepository(rootURL: $0)
    },
) throws -> ImportEnvironment {
    let fileManager = FileManager.default
    let root = fileManager.temporaryDirectory
        .appendingPathComponent("media-library-\(UUID().uuidString)", isDirectory: true)
    try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
    let sourceURL = root.appendingPathComponent(sourceName)
    try sourceBytes.write(to: sourceURL)
    let database = try PersistenceStore.makeInMemory()
    let mediaStore = store ?? SQLiteMediaLibraryStore(database: database)
    let resources = try resourcesFactory(root.appendingPathComponent("resources"))
    return ImportEnvironment(
        root: root,
        sourceURL: sourceURL,
        sourceBytes: sourceBytes,
        store: mediaStore,
        resources: resources,
        importer: makeImporter(store: mediaStore, resources: resources),
    )
}

private func makeImporter(
    store: any MediaLibraryStore,
    resources: FileMediaResourceRepository,
) -> MediaLibraryImporter {
    let ids = IDSequence(ids: [TestFixtures.assetID, TestFixtures.resourceID])
    return MediaLibraryImporter(
        store: store,
        resources: resources,
        source: .localFile,
        id: { ids.next() },
        now: { TestFixtures.importedAt },
    )
}

private func makeAnimatedGIF(at url: URL, using bytes: Data) throws {
    let source = try #require(CGImageSourceCreateWithData(bytes as CFData, nil))
    let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
    let destination = try #require(
        CGImageDestinationCreateWithURL(
            url as CFURL,
            UTType.gif.identifier as CFString,
            2,
            nil,
        ),
    )
    CGImageDestinationAddImage(destination, image, nil)
    CGImageDestinationAddImage(destination, image, nil)
    #expect(CGImageDestinationFinalize(destination))
}

private func finalResourceURLs(in resources: FileMediaResourceRepository) -> [URL] {
    let root = resources.url(
        for: MediaResource(
            id: TestFixtures.resourceID,
            role: .original,
            relativePath: TestFixtures.resourceID.uuidString.lowercased(),
            sourceFilename: "",
            sourceUTI: "",
            byteCount: 0,
            sha256: String(repeating: "0", count: 64),
        ),
    )
    .deletingLastPathComponent()
    return (try? FileManager.default.contentsOfDirectory(
        at: root,
        includingPropertiesForKeys: nil,
    ))?.filter { $0.lastPathComponent != ".staging" } ?? []
}

private final class IDSequence: @unchecked Sendable {
    private let lock = NSLock()
    private var ids: [UUID]

    init(ids: [UUID]) {
        self.ids = ids
    }

    func next() -> UUID {
        lock.lock()
        defer { lock.unlock() }
        return ids.removeFirst()
    }
}

private actor FailingMediaLibraryStore: MediaLibraryStore {
    func loadAssets() async throws -> [MediaAsset] {
        []
    }

    func commit(_: MediaAsset) async throws {
        throw MediaLibraryStoreError.unavailable
    }
}

private func requiredUUID(_ string: String) -> UUID {
    guard let uuid = UUID(uuidString: string) else {
        preconditionFailure("Invalid deterministic UUID: \(string)")
    }

    return uuid
}

private func requiredData(base64Encoded string: String) -> Data {
    guard let data = Data(base64Encoded: string) else {
        preconditionFailure("Invalid deterministic base64 fixture")
    }

    return data
}

extension SHA256.Digest {
    fileprivate var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
