//
//  MediaLibrarySnapshotTests.swift
//  MediaVault
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import ComposableArchitecture
import Dependencies
import Foundation
import FoundationTestSupport
import ObjectiveC
import PersistenceSupport
import SnapshotTesting
import SnapshotTestingCustomDump
import SwiftUI
import Testing
@testable import MediaLibrary

@MainActor
@Suite("Media library snapshots")
struct MediaLibrarySnapshotTests {
    @Test("Source-file normalization has a stable structural snapshot")
    func sourceNormalization() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("media-library-normalization-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let sourceURL = root.appendingPathComponent("holiday-photo.png")
        try SnapshotFixtures.imageData.write(to: sourceURL)
        let store = try SQLiteMediaLibraryStore(database: PersistenceStore.makeInMemory())
        let resources = try FileMediaResourceRepository(
            rootURL: root.appendingPathComponent("resources"),
        )
        let ids = SnapshotIDSequence(ids: [SnapshotFixtures.assetID, SnapshotFixtures.resourceID])
        let importer = MediaLibraryImporter(
            store: store,
            resources: resources,
            source: .localFile,
            id: { ids.next() },
            now: { SnapshotFixtures.importedAt },
        )
        let asset = try await importer.importFile(at: sourceURL)

        assertSnapshot(
            of: asset,
            as: .customDump,
        )
    }

    @Test("The persisted domain mapping has a stable structural snapshot")
    func persistedDomainMapping() async throws {
        let database = try PersistenceStore.makeInMemory()
        let store = SQLiteMediaLibraryStore(database: database)
        try await store.commit(SnapshotFixtures.asset)
        let assets = try await store.loadAssets()

        assertSnapshot(
            of: assets,
            as: .customDump,
        )
    }

    @Test("The ingestion journal mapping has a stable structural snapshot")
    func persistedIngestionJournalMapping() async throws {
        let database = try PersistenceStore.makeInMemory()
        let store = SQLiteMediaLibraryStore(database: database)
        let received = MediaIngestionJournalEntry(
            id: requiredUUID("00000000-0000-0000-0000-000000000040"),
            resourceID: requiredUUID("00000000-0000-0000-0000-000000000041"),
            state: .received,
            sourceFilename: "holiday-photo.png",
            importedAt: Date(timeIntervalSince1970: 1_725_000_000),
        )
        try await store.ingestionJournal.accept(received)
        let validating = try await store.ingestionJournal.transition(received, to: .validating)
        let inspection = ImageInspection(
            uti: "public.png",
            byteCount: 68,
            sha256: String(repeating: "a", count: 64),
            capturedAt: Date(timeIntervalSince1970: 1_724_999_000),
        )
        let duplicateCheck = try await store.ingestionJournal.transition(
            validating,
            to: .duplicateCheck,
            inspection: inspection,
        )
        let ready = try await store.ingestionJournal.transition(duplicateCheck, to: .ready)
        let persisted = try #require(try await store.ingestionJournal.snapshot().entries.first)

        assertSnapshot(
            of: persisted,
            as: .customDump,
        )
        #expect(persisted == ready)
    }

    @Test("The empty Library state fits a compact phone")
    func emptyLibraryCompactPhone() {
        assertSnapshot(
            of: view(state: .init()),
            as: .image(layout: .device(config: DeterministicTestSupport.compactPhone)),
        )
    }

    @Test("A committed still fits a regular-width iPad")
    func committedStillRegularWidthIPad() {
        var state = MediaLibraryFeature.State(assets: [SnapshotFixtures.asset])
        state.resourceData[SnapshotFixtures.resourceID] = SnapshotFixtures.imageData

        assertSnapshot(
            of: view(state: state),
            as: .image(layout: .device(config: DeterministicTestSupport.regularWidthIPad)),
        )
    }

    @Test("An unsupported import error is readable on a compact phone")
    func unsupportedImportCompactPhone() {
        var state = MediaLibraryFeature.State()
        state.error = .unsupportedMedia

        assertSnapshot(
            of: view(state: state),
            as: .image(layout: .device(config: DeterministicTestSupport.compactPhone)),
        )
    }

    private func view(state: MediaLibraryFeature.State) -> some View {
        let store = withDependencies {
            $0.mediaLibrary.loadAssets = { [] }
        } operation: {
            Store(initialState: state) {
                MediaLibraryFeature()
            }
        }
        return MediaLibraryView(store: store, loadsOnAppear: false)
            .environment(\.colorScheme, .light)
    }
}

private enum SnapshotFixtures {
    static let assetID = requiredUUID("00000000-0000-0000-0000-000000000030")
    static let resourceID = requiredUUID("00000000-0000-0000-0000-000000000031")
    static let importedAt = Date(timeIntervalSince1970: 1_725_000_000)
    static let imageData = requiredData(
        base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=",
    )
    static let resource = MediaResource(
        id: resourceID,
        role: .original,
        relativePath: resourceID.uuidString.lowercased(),
        sourceFilename: "holiday-photo.png",
        sourceUTI: "public.png",
        byteCount: Int64(imageData.count),
        sha256: "1111111111111111111111111111111111111111111111111111111111111111",
    )
    static let asset = MediaAsset(
        id: assetID,
        kind: .stillImage,
        importedAt: Date(timeIntervalSince1970: 1_725_000_000),
        resources: [resource],
        capturedAt: Date(timeIntervalSince1970: 1_724_999_000),
    )
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

private final class SnapshotIDSequence: @unchecked Sendable {
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
