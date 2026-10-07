//
//  MediaLibraryImportTests.swift
//  MediaVault
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import CoreFoundation
import CryptoKit
import Foundation
import GRDB
import ImageIO
import ObjectiveC
import PersistenceSupport
import Testing
import UniformTypeIdentifiers
@_spi(Testing) @testable import MediaLibrary

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
        #expect(try await environment.importer.loadAssets() == [asset])
        #expect(try await environment.store.ingestionJournal.snapshot().entries.isEmpty)
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
        let stagingURL = environment.resources.stagingURL(for: TestFixtures.resourceID)
        #expect(try Data(contentsOf: stagingURL) == Data(contentsOf: animatedURL))
        #expect(try await environment.store.ingestionJournal.snapshot().entries.first?.state == .failed)
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
        let stagingURL = environment.resources.stagingURL(for: TestFixtures.resourceID)
        #expect(try Data(contentsOf: stagingURL) == Data([0x00, 0x01, 0x02, 0x03]))
        #expect(try await environment.store.ingestionJournal.snapshot().entries.first?.state == .failed)
        #expect(finalResourceURLs(in: environment.resources).isEmpty)
    }

    @Test("A temporary accepted-resource read failure remains resumable")
    func temporaryAcceptedResourceReadFailureIsResumable() async throws {
        let readFailure = FirstAcceptedResourceReadFailure()
        let environment = try makeEnvironment(resourcesFactory: { root in
            try FileMediaResourceRepository(
                rootURL: root,
                protectionOperation: { _ in },
                acceptedResourceReadOperation: { try readFailure.read($0) },
            )
        })
        let entry = MediaIngestionJournalEntry(
            id: TestFixtures.assetID,
            resourceID: TestFixtures.resourceID,
            state: .received,
            sourceFilename: "holiday-photo.png",
            importedAt: TestFixtures.importedAt,
        )
        let stagingURL = environment.resources.stagingURL(for: entry.resourceID)
        try environment.sourceBytes.write(to: stagingURL)
        try environment.resources.protectStaging(for: entry.resourceID)
        try await environment.store.ingestionJournal.accept(entry)
        _ = try await environment.store.ingestionJournal.transition(entry, to: .validating)

        let firstAssets = try await environment.importer.loadAssets()

        #expect(firstAssets.isEmpty)
        #expect(try await environment.store.ingestionJournal.snapshot().entries.first?.state == .validating)
        #expect(try Data(contentsOf: stagingURL) == environment.sourceBytes)

        let resumedAssets = try await environment.importer.loadAssets()

        let asset = try #require(resumedAssets.first)
        let resource = try #require(asset.resources.first)
        #expect(resumedAssets.count == 1)
        #expect(asset.id == entry.id)
        #expect(resource.byteCount == Int64(environment.sourceBytes.count))
        #expect(resource.sha256 == SHA256.hash(data: environment.sourceBytes).hexString)
        #expect(try environment.resources.data(for: resource) == environment.sourceBytes)
        #expect(try await environment.store.loadAssets() == [asset])
        #expect(try await environment.store.ingestionJournal.snapshot().entries.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: stagingURL.path))
    }

    @Test("Overlapping import and load operations serialize durable recovery")
    func serializesOverlappingImportAndLoadOperations() async throws {
        let acceptedResourceRead = SuspendedAcceptedResourceRead()
        let environment = try makeEnvironment(resourcesFactory: { root in
            try FileMediaResourceRepository(
                rootURL: root,
                protectionOperation: { _ in },
                acceptedResourceReadOperation: { url in
                    try await acceptedResourceRead.read(url)
                },
            )
        })
        let importer = environment.importer
        let sourceURL = environment.sourceURL
        let importTask = Task {
            try await importer.importFile(at: sourceURL)
        }

        await acceptedResourceRead.waitForFirstReadSuspension()
        let pendingEntry = try await environment.store.ingestionJournal.snapshot().entries.first
        #expect(pendingEntry?.state == .validating)

        let loadTask = Task {
            try await importer.loadAssets()
        }
        await importer.waitForDurableOperationWaiterForTesting()
        #expect(await acceptedResourceRead.readCount() == 1)

        await acceptedResourceRead.releaseFirstRead()
        let importedAsset = try await importTask.value
        let loadedAssets = try await loadTask.value

        #expect(loadedAssets == [importedAsset])
        #expect(try await environment.store.loadAssets() == [importedAsset])
        #expect(try await environment.store.ingestionJournal.snapshot().entries.isEmpty)
        #expect(await acceptedResourceRead.readCount() == 1)

        let resource = try #require(importedAsset.resources.first)
        #expect(try environment.resources.data(for: resource) == environment.sourceBytes)

        let subsequentAssets = try await importer.loadAssets()
        #expect(subsequentAssets == loadedAssets)
        #expect(try await environment.store.loadAssets().count == 1)
        #expect(try await environment.store.ingestionJournal.snapshot().entries.isEmpty)
    }

    @Test("A failed durable operation releases the importer gate for reconciliation")
    func failedOperationReleasesGateForReconciliation() async throws {
        let readFailure = FirstAcceptedResourceReadFailure()
        let environment = try makeEnvironment(resourcesFactory: { root in
            try FileMediaResourceRepository(
                rootURL: root,
                protectionOperation: { _ in },
                acceptedResourceReadOperation: { try readFailure.read($0) },
            )
        })

        await #expect(throws: MediaImportError.persistenceFailed) {
            try await environment.importer.importFile(at: environment.sourceURL)
        }

        let gateState = await environment.importer.durableOperationGateStateForTesting()
        #expect(!gateState.isActive)
        #expect(gateState.waiterCount == 0)
        #expect(try await environment.store.ingestionJournal.snapshot().entries.first?.state == .validating)
        #expect(
            try Data(contentsOf: environment.resources.stagingURL(for: TestFixtures.resourceID))
                == environment.sourceBytes,
        )

        try await environment.importer.reconcile()

        let assets = try await environment.store.loadAssets()
        let asset = try #require(assets.first)
        let resource = try #require(asset.resources.first)
        #expect(assets.count == 1)
        #expect(try environment.resources.data(for: resource) == environment.sourceBytes)
        #expect(try await environment.store.ingestionJournal.snapshot().entries.isEmpty)
        #expect(try await environment.importer.loadAssets() == assets)
    }

    @Test("Cancelling a queued durable operation does not strand the importer gate")
    func cancellingQueuedOperationDoesNotStrandGate() async throws {
        let acceptedResourceRead = SuspendedAcceptedResourceRead()
        let environment = try makeEnvironment(resourcesFactory: { root in
            try FileMediaResourceRepository(
                rootURL: root,
                protectionOperation: { _ in },
                acceptedResourceReadOperation: { url in
                    try await acceptedResourceRead.read(url)
                },
            )
        })
        let importer = environment.importer
        let sourceURL = environment.sourceURL
        let importTask = Task {
            try await importer.importFile(at: sourceURL)
        }
        await acceptedResourceRead.waitForFirstReadSuspension()

        let cancelledLoadTask = Task {
            try await importer.loadAssets()
        }
        await importer.waitForDurableOperationWaiterForTesting()
        cancelledLoadTask.cancel()
        await #expect(throws: CancellationError.self) {
            try await cancelledLoadTask.value
        }

        let cancelledGateState = await importer.durableOperationGateStateForTesting()
        #expect(cancelledGateState.isActive)
        #expect(cancelledGateState.waiterCount == 0)

        let loadTask = Task {
            try await importer.loadAssets()
        }
        await importer.waitForDurableOperationWaiterForTesting()
        #expect(await importer.durableOperationGateStateForTesting().waiterCount == 1)

        await acceptedResourceRead.releaseFirstRead()
        _ = try await importTask.value
        let assets = try await loadTask.value

        #expect(assets.count == 1)
        #expect(try await environment.store.ingestionJournal.snapshot().entries.isEmpty)
    }

    @Test("Source access failure produces no canonical resource or asset")
    func rejectsSourceAccessFailure() async throws {
        let environment = try makeEnvironment()
        let missingURL = environment.root.appendingPathComponent("missing.png")

        await #expect(throws: MediaImportError.sourceAccessFailed) {
            try await environment.importer.importFile(at: missingURL)
        }

        #expect(try await environment.store.loadAssets().isEmpty)
        #expect(try await environment.store.ingestionJournal.snapshot().entries.isEmpty)
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
            try Data(contentsOf: environment.resources.stagingURL(for: TestFixtures.resourceID)) == environment
                .sourceBytes,
        )
        #expect(try await environment.store.ingestionJournal.snapshot().entries.first?.state == .committing)
        #expect(try Data(contentsOf: preexistingURL) == preexistingBytes)
        #expect(finalResourceURLs(in: environment.resources) == [preexistingURL])
    }

    @Test("A partial source copy is removed before journal acceptance")
    func removesPartialSourceCopyBeforeAcceptance() async throws {
        let environment = try makeEnvironment()
        let ids = IDSequence(ids: [TestFixtures.assetID, TestFixtures.resourceID])
        let partialBytes = Data([0xde, 0xad])
        let importer = MediaLibraryImporter(
            store: environment.store,
            resources: environment.resources,
            source: MediaSourceClient(copyOperation: { _, stagingURL in
                try partialBytes.write(to: stagingURL)
                throw MediaImportError.sourceAccessFailed
            }),
            id: { ids.next() },
            now: { TestFixtures.importedAt },
        )

        await #expect(throws: MediaImportError.sourceAccessFailed) {
            try await importer.importFile(at: environment.sourceURL)
        }

        #expect(
            !FileManager.default.fileExists(
                atPath: environment.resources.stagingURL(for: TestFixtures.resourceID).path,
            ),
        )
        #expect(try await environment.store.ingestionJournal.snapshot().entries.isEmpty)
        #expect(try await environment.store.loadAssets().isEmpty)
    }

    @Test("A staging protection failure removes bytes before journal acceptance")
    func rejectsStagingProtectionFailure() async throws {
        let environment = try makeEnvironment { resourcesRoot in
            let stagingURL = resourcesRoot
                .appendingPathComponent(".staging", isDirectory: true)
                .appendingPathComponent(TestFixtures.resourceID.uuidString.lowercased())
            return try FileMediaResourceRepository(
                rootURL: resourcesRoot,
                protectionOperation: { url in
                    if url == stagingURL {
                        throw MediaImportError.finalizationFailed
                    }
                },
            )
        }

        await #expect(throws: MediaImportError.finalizationFailed) {
            try await environment.importer.importFile(at: environment.sourceURL)
        }

        #expect(
            !FileManager.default.fileExists(
                atPath: environment.resources.stagingURL(for: TestFixtures.resourceID).path,
            ),
        )
        #expect(try await environment.store.ingestionJournal.snapshot().entries.isEmpty)
        #expect(try await environment.store.loadAssets().isEmpty)
    }

    @Test("The legacy finalize operation removes a moved file after protection failure")
    func finalizeRollsBackMovedResourceOnProtectionFailure() throws {
        let environment = try makeEnvironment { resourcesRoot in
            let finalURL = resourcesRoot.appendingPathComponent(TestFixtures.resourceID.uuidString.lowercased())
            return try FileMediaResourceRepository(
                rootURL: resourcesRoot,
                protectionOperation: { url in
                    if url == finalURL {
                        throw MediaImportError.finalizationFailed
                    }
                },
            )
        }
        let stagingURL = environment.resources.stagingURL(for: TestFixtures.resourceID)
        try environment.sourceBytes.write(to: stagingURL)

        #expect(throws: MediaImportError.finalizationFailed) {
            try environment.resources.finalize(stagingURL: stagingURL, resourceID: TestFixtures.resourceID)
        }

        let finalURL = environment.resources.url(for: MediaResource(
            id: TestFixtures.resourceID,
            role: .original,
            relativePath: TestFixtures.resourceID.uuidString.lowercased(),
            sourceFilename: "holiday-photo.png",
            sourceUTI: "public.png",
            byteCount: Int64(environment.sourceBytes.count),
            sha256: SHA256.hash(data: environment.sourceBytes).hexString,
        ))
        #expect(!FileManager.default.fileExists(atPath: finalURL.path))
    }

    @Test("Post-move protection failure preserves the promoted resource for recovery")
    func preservesPostMoveFinalizationFailure() async throws {
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
        let resource = MediaResource(
            id: TestFixtures.resourceID,
            role: .original,
            relativePath: TestFixtures.resourceID.uuidString.lowercased(),
            sourceFilename: "holiday-photo.png",
            sourceUTI: "public.png",
            byteCount: Int64(environment.sourceBytes.count),
            sha256: SHA256.hash(data: environment.sourceBytes).hexString,
        )
        #expect(try environment.resources.data(for: resource) == environment.sourceBytes)
        #expect(try await environment.store.ingestionJournal.snapshot().entries.first?.state == .committing)
    }

    @Test("Canonical commit and journal completion recover atomically after a database failure")
    func databaseFailurePreservesEvidenceAndCanRecover() async throws {
        let environment = try makeEnvironment()
        _ = try await environment.store.loadAssets()
        try await environment.database.write { db in
            try db.execute(
                sql: """
                CREATE TRIGGER fail_media_asset_insert
                BEFORE INSERT ON media_assets
                BEGIN SELECT RAISE(ABORT, 'injected canonical commit failure'); END
                """,
            )
        }

        await #expect(throws: MediaImportError.persistenceFailed) {
            try await environment.importer.importFile(at: environment.sourceURL)
        }

        #expect(try await environment.store.loadAssets().isEmpty)
        #expect(try await environment.store.ingestionJournal.snapshot().entries.first?.state == .committing)
        #expect(try await environment.importer.loadAssets().isEmpty)
        let finalizedResource = MediaResource(
            id: TestFixtures.resourceID,
            role: .original,
            relativePath: TestFixtures.resourceID.uuidString.lowercased(),
            sourceFilename: "holiday-photo.png",
            sourceUTI: "public.png",
            byteCount: Int64(environment.sourceBytes.count),
            sha256: SHA256.hash(data: environment.sourceBytes).hexString,
        )
        #expect(try environment.resources.data(for: finalizedResource) == environment.sourceBytes)

        try await environment.database.write { db in
            try db.execute(sql: "DROP TRIGGER fail_media_asset_insert")
        }
        let recoveredAssets = try await environment.importer.loadAssets()
        #expect(recoveredAssets.count == 1)
        #expect(recoveredAssets.first?.id == TestFixtures.assetID)
        #expect(try await environment.store.ingestionJournal.snapshot().entries.isEmpty)
    }

    @Test("Recovery resumes every active journal boundary idempotently")
    func resumesEveryActiveJournalBoundary() async throws {
        let environment = try makeEnvironment()
        let states: [MediaIngestionState] = [.received, .validating, .duplicateCheck, .ready, .committing]
        let inspection = ImageInspection(
            uti: "public.png",
            byteCount: Int64(environment.sourceBytes.count),
            sha256: SHA256.hash(data: environment.sourceBytes).hexString,
            capturedAt: nil,
        )

        for (index, state) in states.enumerated() {
            let assetID = TestFixtures.recoveryAssetIDs[index]
            let resourceID = TestFixtures.recoveryResourceIDs[index]
            let stagingURL = environment.resources.stagingURL(for: resourceID)
            try environment.sourceBytes.write(to: stagingURL)
            try environment.resources.protectStaging(for: resourceID)

            var entry = MediaIngestionJournalEntry(
                id: assetID,
                resourceID: resourceID,
                state: .received,
                sourceFilename: "recovery-\(index).png",
                importedAt: TestFixtures.importedAt,
            )
            try await environment.store.ingestionJournal.accept(entry)
            guard state != .received else {
                continue
            }

            entry = try await environment.store.ingestionJournal.transition(entry, to: .validating)
            guard state != .validating else {
                continue
            }

            entry = try await environment.store.ingestionJournal.transition(
                entry,
                to: .duplicateCheck,
                inspection: inspection,
            )
            guard state != .duplicateCheck else {
                continue
            }

            entry = try await environment.store.ingestionJournal.transition(entry, to: .ready)
            guard state != .ready else {
                continue
            }

            entry = try await environment.store.ingestionJournal.transition(entry, to: .committing)
            _ = try environment.resources.promoteOrVerify(
                stagingURL: stagingURL,
                resourceID: resourceID,
                byteCount: inspection.byteCount,
                sha256: inspection.sha256,
            )
        }

        let firstLoad = try await environment.importer.loadAssets()
        let secondLoad = try await environment.importer.loadAssets()
        #expect(Set(firstLoad.map(\.id)) == Set(TestFixtures.recoveryAssetIDs.prefix(states.count)))
        #expect(secondLoad == firstLoad)
        #expect(try await environment.store.ingestionJournal.snapshot().entries.isEmpty)
        for resourceID in TestFixtures.recoveryResourceIDs.prefix(states.count) {
            let resourceURL = environment.root
                .appendingPathComponent("resources", isDirectory: true)
                .appendingPathComponent(resourceID.uuidString.lowercased())
            #expect(try Data(contentsOf: resourceURL) == environment.sourceBytes)
        }
    }

    @Test("A pending row can repair existing canonical rows from protected staging")
    func repairsCanonicalRowsBeforeJournalCompletion() async throws {
        let environment = try makeEnvironment()
        let assetID = TestFixtures.recoveryAssetIDs[5]
        let resourceID = TestFixtures.recoveryResourceIDs[5]
        let stagingURL = environment.resources.stagingURL(for: resourceID)
        try environment.sourceBytes.write(to: stagingURL)
        try environment.resources.protectStaging(for: resourceID)
        let inspection = ImageInspection(
            uti: "public.png",
            byteCount: Int64(environment.sourceBytes.count),
            sha256: SHA256.hash(data: environment.sourceBytes).hexString,
            capturedAt: nil,
        )
        var entry = MediaIngestionJournalEntry(
            id: assetID,
            resourceID: resourceID,
            state: .received,
            sourceFilename: "recovered-existing-rows.png",
            importedAt: TestFixtures.importedAt,
        )
        try await environment.store.ingestionJournal.accept(entry)
        entry = try await environment.store.ingestionJournal.transition(entry, to: .validating)
        entry = try await environment.store.ingestionJournal.transition(
            entry,
            to: .duplicateCheck,
            inspection: inspection,
        )
        entry = try await environment.store.ingestionJournal.transition(entry, to: .ready)
        entry = try await environment.store.ingestionJournal.transition(entry, to: .committing)
        let asset = try journalAsset(from: entry)
        try await environment.store.commit(asset)

        let assets = try await environment.importer.loadAssets()

        #expect(assets == [asset])
        #expect(try environment.resources.data(for: #require(asset.resources.first)) == environment.sourceBytes)
        #expect(try await environment.store.ingestionJournal.snapshot().entries.isEmpty)
    }

    @Test("A mismatched canonical row cannot complete a pending journal item")
    func rejectsMismatchedCanonicalRows() async throws {
        let environment = try makeEnvironment()
        let assetID = TestFixtures.recoveryAssetIDs[5]
        let resourceID = TestFixtures.recoveryResourceIDs[5]
        let stagingURL = environment.resources.stagingURL(for: resourceID)
        try environment.sourceBytes.write(to: stagingURL)
        try environment.resources.protectStaging(for: resourceID)
        let inspection = ImageInspection(
            uti: "public.png",
            byteCount: Int64(environment.sourceBytes.count),
            sha256: SHA256.hash(data: environment.sourceBytes).hexString,
            capturedAt: nil,
        )
        var entry = MediaIngestionJournalEntry(
            id: assetID,
            resourceID: resourceID,
            state: .received,
            sourceFilename: "pending.png",
            importedAt: TestFixtures.importedAt,
        )
        try await environment.store.ingestionJournal.accept(entry)
        entry = try await environment.store.ingestionJournal.transition(entry, to: .validating)
        entry = try await environment.store.ingestionJournal.transition(
            entry,
            to: .duplicateCheck,
            inspection: inspection,
        )
        entry = try await environment.store.ingestionJournal.transition(entry, to: .ready)
        entry = try await environment.store.ingestionJournal.transition(entry, to: .committing)
        let expectedAsset = try journalAsset(from: entry)
        let conflictingAsset = MediaAsset(
            id: expectedAsset.id,
            kind: expectedAsset.kind,
            importedAt: expectedAsset.importedAt.addingTimeInterval(1),
            resources: expectedAsset.resources,
            capturedAt: expectedAsset.capturedAt,
        )
        try await environment.store.commit(conflictingAsset)

        #expect(try await environment.importer.loadAssets().isEmpty)
        #expect(try await environment.store.loadAssets() == [conflictingAsset])
        #expect(try await environment.store.ingestionJournal.snapshot().entries.first?.state == .committing)
        #expect(try Data(contentsOf: environment.resources.url(for: #require(expectedAsset.resources.first)))
            == environment.sourceBytes)
    }

    @Test("Pre-journal canonical assets remain visible")
    func loadsPreJournalCanonicalAssets() async throws {
        let environment = try makeEnvironment()
        let resource = MediaResource(
            id: TestFixtures.preJournalResourceID,
            role: .original,
            relativePath: TestFixtures.preJournalResourceID.uuidString.lowercased(),
            sourceFilename: "existing-library-image.png",
            sourceUTI: "public.png",
            byteCount: Int64(environment.sourceBytes.count),
            sha256: SHA256.hash(data: environment.sourceBytes).hexString,
        )
        let asset = MediaAsset(
            id: TestFixtures.preJournalAssetID,
            kind: .stillImage,
            importedAt: TestFixtures.importedAt,
            resources: [resource],
        )
        try environment.sourceBytes.write(to: environment.resources.url(for: resource))
        try await environment.store.commit(asset)

        #expect(try await environment.importer.loadAssets() == [asset])
        #expect(try await environment.store.ingestionJournal.snapshot().entries.isEmpty)
    }

    @Test("Protected staging without its first journal row becomes durable failed evidence")
    func recordsInterruptedJournalAcceptance() async throws {
        let orphanResourceID = requiredUUID("00000000-0000-0000-0000-000000000022")
        let protectionMarkerName = "orphan-protection-\(UUID().uuidString)"
        let protectionMarker = FileManager.default.temporaryDirectory.appendingPathComponent(protectionMarkerName)
        let environment = try makeEnvironment { resourcesRoot in
            let orphanStagingURL = resourcesRoot
                .appendingPathComponent(".staging", isDirectory: true)
                .appendingPathComponent(orphanResourceID.uuidString.lowercased())
            return try FileMediaResourceRepository(
                rootURL: resourcesRoot,
                protectionOperation: { url in
                    if url == orphanStagingURL {
                        try Data([1]).write(to: protectionMarker)
                    }
                },
            )
        }
        let legacyResource = MediaResource(
            id: requiredUUID("00000000-0000-0000-0000-000000000023"),
            role: .original,
            relativePath: "00000000-0000-0000-0000-000000000023",
            sourceFilename: "legacy.png",
            sourceUTI: "public.png",
            byteCount: Int64(environment.sourceBytes.count),
            sha256: SHA256.hash(data: environment.sourceBytes).hexString,
        )
        let legacyAsset = MediaAsset(
            id: orphanResourceID,
            kind: .stillImage,
            importedAt: TestFixtures.importedAt,
            resources: [legacyResource],
        )
        try environment.sourceBytes.write(to: environment.resources.url(for: legacyResource))
        try await environment.store.commit(legacyAsset)

        let stagingURL = environment.resources.stagingURL(for: orphanResourceID)
        try environment.sourceBytes.write(to: stagingURL)

        #expect(try await environment.importer.loadAssets() == [legacyAsset])

        #expect(FileManager.default.fileExists(atPath: protectionMarker.path))
        let firstSnapshot = try await environment.store.ingestionJournal.snapshot()
        let recoveredEntry = try #require(firstSnapshot.entries.first)
        #expect(recoveredEntry.state == .failed)
        #expect(recoveredEntry.resourceID == orphanResourceID)
        #expect(recoveredEntry.id != legacyAsset.id)
        #expect(try Data(contentsOf: stagingURL) == environment.sourceBytes)

        #expect(try await environment.importer.loadAssets() == [legacyAsset])
        let secondSnapshot = try await environment.store.ingestionJournal.snapshot()
        #expect(secondSnapshot.entries == firstSnapshot.entries)
        #expect(try Data(contentsOf: stagingURL) == environment.sourceBytes)
    }

    @Test("Orphan staging stays unaccepted when protection cannot be established")
    func rejectsOrphanWithUnprotectedStaging() async throws {
        let orphanResourceID = requiredUUID("00000000-0000-0000-0000-000000000024")
        let environment = try makeEnvironment { resourcesRoot in
            let orphanStagingURL = resourcesRoot
                .appendingPathComponent(".staging", isDirectory: true)
                .appendingPathComponent(orphanResourceID.uuidString.lowercased())
            return try FileMediaResourceRepository(
                rootURL: resourcesRoot,
                protectionOperation: { url in
                    if url == orphanStagingURL {
                        throw MediaImportError.finalizationFailed
                    }
                },
            )
        }
        let existingResource = MediaResource(
            id: TestFixtures.preJournalResourceID,
            role: .original,
            relativePath: TestFixtures.preJournalResourceID.uuidString.lowercased(),
            sourceFilename: "legacy.png",
            sourceUTI: "public.png",
            byteCount: Int64(environment.sourceBytes.count),
            sha256: SHA256.hash(data: environment.sourceBytes).hexString,
        )
        let existingAsset = MediaAsset(
            id: TestFixtures.preJournalAssetID,
            kind: .stillImage,
            importedAt: TestFixtures.importedAt,
            resources: [existingResource],
        )
        try environment.sourceBytes.write(to: environment.resources.url(for: existingResource))
        try await environment.store.commit(existingAsset)
        let orphanStagingURL = environment.resources.stagingURL(for: orphanResourceID)
        try environment.sourceBytes.write(to: orphanStagingURL)

        #expect(try await environment.importer.loadAssets() == [existingAsset])
        #expect(try await environment.store.ingestionJournal.snapshot().entries.isEmpty)
        #expect(try Data(contentsOf: orphanStagingURL) == environment.sourceBytes)
    }

    @Test("Verification failure blocks only its asset and keeps completion evidence")
    func isolatesCompletedItemVerificationFailure() async throws {
        let environment = try makeEnvironment()
        _ = try await environment.store.loadAssets()
        try await environment.database.write { db in
            try db.execute(
                sql: """
                CREATE TRIGGER hold_ingestion_compaction
                BEFORE DELETE ON media_ingestion_journal
                BEGIN SELECT RAISE(ABORT, 'injected compaction failure'); END
                """,
            )
        }
        let completedAsset = try await environment.importer.importFile(at: environment.sourceURL)
        #expect(try await environment.store.ingestionJournal.snapshot().entries.first?.state == .complete)

        let unrelatedResource = MediaResource(
            id: TestFixtures.preJournalResourceID,
            role: .original,
            relativePath: TestFixtures.preJournalResourceID.uuidString.lowercased(),
            sourceFilename: "unrelated.png",
            sourceUTI: "public.png",
            byteCount: Int64(environment.sourceBytes.count),
            sha256: SHA256.hash(data: environment.sourceBytes).hexString,
        )
        let unrelatedAsset = MediaAsset(
            id: TestFixtures.preJournalAssetID,
            kind: .stillImage,
            importedAt: TestFixtures.importedAt,
            resources: [unrelatedResource],
        )
        try environment.sourceBytes.write(to: environment.resources.url(for: unrelatedResource))
        try await environment.store.commit(unrelatedAsset)

        let completedResource = try #require(completedAsset.resources.first)
        let damagedBytes = Data([0xde, 0xad, 0xbe, 0xef])
        try damagedBytes.write(to: environment.resources.url(for: completedResource))
        let visibleAfterDamage = try await environment.importer.loadAssets()
        #expect(visibleAfterDamage == [unrelatedAsset])
        #expect(try Data(contentsOf: environment.resources.url(for: completedResource)) == damagedBytes)
        #expect(try await environment.store.ingestionJournal.snapshot().entries.first?.state == .complete)

        try await environment.database.write { db in
            try db.execute(sql: "DROP TRIGGER hold_ingestion_compaction")
        }
        try environment.sourceBytes.write(to: environment.resources.url(for: completedResource))
        let visibleAfterRepair = try await environment.importer.loadAssets()
        #expect(Set(visibleAfterRepair.map(\.id)) == Set([completedAsset.id, unrelatedAsset.id]))
        #expect(try await environment.store.ingestionJournal.snapshot().entries.isEmpty)
    }

    @Test("Reconciliation leaves decision, failed, and cancelled entries untouched")
    func leavesTerminalJournalEvidenceUntouched() async throws {
        let environment = try makeEnvironment()
        let decisionID = TestFixtures.recoveryAssetIDs[5]
        let decisionResourceID = TestFixtures.recoveryResourceIDs[5]
        let failedID = TestFixtures.recoveryAssetIDs[6]
        let failedResourceID = TestFixtures.recoveryResourceIDs[6]
        let cancelledID = TestFixtures.recoveryAssetIDs[7]
        let cancelledResourceID = TestFixtures.recoveryResourceIDs[7]
        let decisionStageURL = environment.resources.stagingURL(for: decisionResourceID)
        let failedStageURL = environment.resources.stagingURL(for: failedResourceID)
        let cancelledStageURL = environment.resources.stagingURL(for: cancelledResourceID)
        try environment.sourceBytes.write(to: decisionStageURL)
        try environment.sourceBytes.write(to: failedStageURL)
        try environment.sourceBytes.write(to: cancelledStageURL)
        try environment.resources.protectStaging(for: decisionResourceID)
        try environment.resources.protectStaging(for: failedResourceID)
        try environment.resources.protectStaging(for: cancelledResourceID)

        let receivedDecision = MediaIngestionJournalEntry(
            id: decisionID,
            resourceID: decisionResourceID,
            state: .received,
            sourceFilename: "awaiting-decision.png",
            importedAt: TestFixtures.importedAt,
        )
        try await environment.store.ingestionJournal.accept(receivedDecision)
        let validatingDecision = try await environment.store.ingestionJournal.transition(
            receivedDecision,
            to: .validating,
        )
        let inspection = ImageInspection(
            uti: "public.png",
            byteCount: Int64(environment.sourceBytes.count),
            sha256: SHA256.hash(data: environment.sourceBytes).hexString,
            capturedAt: nil,
        )
        let duplicateDecision = try await environment.store.ingestionJournal.transition(
            validatingDecision,
            to: .duplicateCheck,
            inspection: inspection,
        )
        _ = try await environment.store.ingestionJournal.transition(duplicateDecision, to: .awaitingUserDecision)

        var failedEntry = MediaIngestionJournalEntry(
            id: failedID,
            resourceID: failedResourceID,
            state: .received,
            sourceFilename: "failed.png",
            importedAt: TestFixtures.importedAt,
        )
        try await environment.store.ingestionJournal.accept(failedEntry)
        failedEntry = try await environment.store.ingestionJournal.transition(failedEntry, to: .validating)
        _ = try await environment.store.ingestionJournal.transition(failedEntry, to: .failed)

        let cancelledEntry = MediaIngestionJournalEntry(
            id: cancelledID,
            resourceID: cancelledResourceID,
            state: .received,
            sourceFilename: "cancelled.png",
            importedAt: TestFixtures.importedAt,
        )
        try await environment.store.ingestionJournal.accept(cancelledEntry)
        _ = try await environment.store.ingestionJournal.transition(cancelledEntry, to: .cancelled)

        let before = try await environment.store.ingestionJournal.snapshot().entries
        try await environment.importer.reconcile()
        let after = try await environment.store.ingestionJournal.snapshot().entries

        #expect(after == before)
        #expect(try Data(contentsOf: decisionStageURL) == environment.sourceBytes)
        #expect(try Data(contentsOf: failedStageURL) == environment.sourceBytes)
        #expect(try Data(contentsOf: cancelledStageURL) == environment.sourceBytes)
    }

    @Test("The journal enforces every legal and illegal state transition")
    func validatesJournalTransitions() async throws {
        let environment = try makeEnvironment()
        let journal = environment.store.ingestionJournal
        _ = try await journal.snapshot()
        let inspection = ImageInspection(
            uti: "public.png",
            byteCount: Int64(environment.sourceBytes.count),
            sha256: SHA256.hash(data: environment.sourceBytes).hexString,
            capturedAt: nil,
        )

        var legalTransitions: [(MediaIngestionState, MediaIngestionState)] = [
            (.received, .validating),
            (.validating, .duplicateCheck),
            (.duplicateCheck, .ready),
            (.duplicateCheck, .awaitingUserDecision),
            (.ready, .committing),
        ]
        for activeState: MediaIngestionState in [
            .received,
            .validating,
            .duplicateCheck,
            .ready,
            .committing,
            .awaitingUserDecision,
        ] {
            legalTransitions.append((activeState, .failed))
            legalTransitions.append((activeState, .cancelled))
        }

        for currentState in MediaIngestionState.allCases {
            for nextState in MediaIngestionState.allCases {
                let entry = MediaIngestionJournalEntry(
                    id: UUID(),
                    resourceID: UUID(),
                    state: currentState,
                    sourceFilename: "transition-test.png",
                    importedAt: TestFixtures.importedAt,
                    sourceUTI: inspection.uti,
                    byteCount: inspection.byteCount,
                    sha256: inspection.sha256,
                    capturedAt: inspection.capturedAt,
                )
                try await insertJournalEntry(entry, into: environment.database)

                if legalTransitions.contains(where: { $0.0 == currentState && $0.1 == nextState }) {
                    let updated = try await journal.transition(entry, to: nextState, inspection: inspection)
                    #expect(updated.state == nextState)
                } else {
                    await #expect(throws: MediaLibraryStoreError.corrupt) {
                        try await journal.transition(entry, to: nextState, inspection: inspection)
                    }
                }
            }
        }

        let committingEntry = MediaIngestionJournalEntry(
            id: UUID(),
            resourceID: UUID(),
            state: .committing,
            sourceFilename: "atomic-completion.png",
            importedAt: TestFixtures.importedAt,
            sourceUTI: inspection.uti,
            byteCount: inspection.byteCount,
            sha256: inspection.sha256,
            capturedAt: inspection.capturedAt,
        )
        try await insertJournalEntry(committingEntry, into: environment.database)
        try await environment.store.commit(
            journalAsset(from: committingEntry),
            completingIngestion: committingEntry.id,
        )
        let completed = try #require(
            try await journal.snapshot().entries.first(where: { $0.id == committingEntry.id }),
        )
        #expect(completed.state == .complete)
    }

    @Test("An idempotent inspection transition returns persisted metadata")
    func idempotentInspectionTransitionUsesPersistedMetadata() async throws {
        let environment = try makeEnvironment()
        let resourceID = TestFixtures.recoveryResourceIDs[7]
        let stagingURL = environment.resources.stagingURL(for: resourceID)
        try environment.sourceBytes.write(to: stagingURL)
        try environment.resources.protectStaging(for: resourceID)
        let received = MediaIngestionJournalEntry(
            id: TestFixtures.recoveryAssetIDs[7],
            resourceID: resourceID,
            state: .received,
            sourceFilename: "transition-test.png",
            importedAt: TestFixtures.importedAt,
        )
        try await environment.store.ingestionJournal.accept(received)
        let validating = try await environment.store.ingestionJournal.transition(received, to: .validating)
        let originalInspection = ImageInspection(
            uti: "public.png",
            byteCount: Int64(environment.sourceBytes.count),
            sha256: SHA256.hash(data: environment.sourceBytes).hexString,
            capturedAt: TestFixtures.importedAt,
        )
        let duplicateCheck = try await environment.store.ingestionJournal.transition(
            validating,
            to: .duplicateCheck,
            inspection: originalInspection,
        )
        let conflictingInspection = ImageInspection(
            uti: "public.jpeg",
            byteCount: originalInspection.byteCount + 1,
            sha256: String(repeating: "b", count: 64),
            capturedAt: Date(timeIntervalSince1970: 1_700_000_000),
        )

        let repeated = try await environment.store.ingestionJournal.transition(
            validating,
            to: .duplicateCheck,
            inspection: conflictingInspection,
        )
        let persisted = try #require(
            try await environment.store.ingestionJournal.snapshot().entries.first,
        )

        #expect(repeated == duplicateCheck)
        #expect(persisted == duplicateCheck)
    }

    @Test("One malformed journal row hides only its matching canonical asset")
    func isolatesMalformedJournalRows() async throws {
        let environment = try makeEnvironment()
        let damagedResource = MediaResource(
            id: TestFixtures.recoveryResourceIDs[6],
            role: .original,
            relativePath: TestFixtures.recoveryResourceIDs[6].uuidString.lowercased(),
            sourceFilename: "damaged-journal.png",
            sourceUTI: "public.png",
            byteCount: Int64(environment.sourceBytes.count),
            sha256: SHA256.hash(data: environment.sourceBytes).hexString,
        )
        let damagedAsset = MediaAsset(
            id: TestFixtures.recoveryAssetIDs[6],
            kind: .stillImage,
            importedAt: TestFixtures.importedAt,
            resources: [damagedResource],
        )
        let unrelatedResource = MediaResource(
            id: TestFixtures.recoveryResourceIDs[7],
            role: .original,
            relativePath: TestFixtures.recoveryResourceIDs[7].uuidString.lowercased(),
            sourceFilename: "unrelated-journal.png",
            sourceUTI: "public.png",
            byteCount: Int64(environment.sourceBytes.count),
            sha256: SHA256.hash(data: environment.sourceBytes).hexString,
        )
        let unrelatedAsset = MediaAsset(
            id: TestFixtures.recoveryAssetIDs[7],
            kind: .stillImage,
            importedAt: TestFixtures.importedAt,
            resources: [unrelatedResource],
        )
        try environment.sourceBytes.write(to: environment.resources.url(for: damagedResource))
        try environment.sourceBytes.write(to: environment.resources.url(for: unrelatedResource))
        try await environment.store.commit(damagedAsset)
        try await environment.store.commit(unrelatedAsset)

        let recoveryAssetID = TestFixtures.recoveryAssetIDs[5]
        let recoveryResourceID = TestFixtures.recoveryResourceIDs[5]
        let stagingURL = environment.resources.stagingURL(for: recoveryResourceID)
        try environment.sourceBytes.write(to: stagingURL)
        try environment.resources.protectStaging(for: recoveryResourceID)
        let inspection = ImageInspection(
            uti: "public.png",
            byteCount: Int64(environment.sourceBytes.count),
            sha256: SHA256.hash(data: environment.sourceBytes).hexString,
            capturedAt: nil,
        )
        var recoveryEntry = MediaIngestionJournalEntry(
            id: recoveryAssetID,
            resourceID: recoveryResourceID,
            state: .received,
            sourceFilename: "recoverable-journal.png",
            importedAt: TestFixtures.importedAt,
        )
        try await environment.store.ingestionJournal.accept(recoveryEntry)
        recoveryEntry = try await environment.store.ingestionJournal.transition(recoveryEntry, to: .validating)
        recoveryEntry = try await environment.store.ingestionJournal.transition(
            recoveryEntry,
            to: .duplicateCheck,
            inspection: inspection,
        )
        recoveryEntry = try await environment.store.ingestionJournal.transition(recoveryEntry, to: .ready)
        recoveryEntry = try await environment.store.ingestionJournal.transition(recoveryEntry, to: .committing)
        let recoveredAsset = try journalAsset(from: recoveryEntry)

        let damagedByteCount = Int64(environment.sourceBytes.count)
        let damagedSHA256 = SHA256.hash(data: environment.sourceBytes).hexString
        try await environment.database.write { db in
            try db.execute(
                sql: """
                INSERT INTO media_ingestion_journal (
                  id, resource_id, state, source_filename, imported_at,
                  source_uti, byte_count, sha256, captured_at
                ) VALUES (?, ?, 'complete', '', 'not-a-timestamp', ?, ?, ?, NULL)
                """,
                arguments: [
                    damagedAsset.id.uuidString,
                    damagedResource.id.uuidString,
                    "public.png",
                    damagedByteCount,
                    damagedSHA256,
                ],
            )
        }

        let visibleAssets = try await environment.importer.loadAssets()
        let journal = try await environment.store.ingestionJournal.snapshot()
        #expect(visibleAssets == [recoveredAsset, unrelatedAsset])
        #expect(journal.unreadableAssetIDs == [damagedAsset.id])
        #expect(try environment.resources.data(for: damagedResource) == environment.sourceBytes)
        #expect(try environment.resources.data(for: #require(recoveredAsset.resources.first)) == environment
            .sourceBytes)
    }

    @Test("A non-finite timestamp makes only its journal row unreadable")
    func isolatesNonFiniteJournalTimestamps() async throws {
        let environment = try makeEnvironment()
        let unreadableEntry = MediaIngestionJournalEntry(
            id: TestFixtures.recoveryAssetIDs[4],
            resourceID: TestFixtures.recoveryResourceIDs[4],
            state: .received,
            sourceFilename: "non-finite-timestamp.png",
            importedAt: Date(timeIntervalSince1970: .infinity),
        )
        let unreadableCapturedAtEntry = MediaIngestionJournalEntry(
            id: TestFixtures.recoveryAssetIDs[2],
            resourceID: TestFixtures.recoveryResourceIDs[2],
            state: .received,
            sourceFilename: "non-finite-capture-time.png",
            importedAt: TestFixtures.importedAt,
        )
        let readableEntry = MediaIngestionJournalEntry(
            id: TestFixtures.recoveryAssetIDs[3],
            resourceID: TestFixtures.recoveryResourceIDs[3],
            state: .received,
            sourceFilename: "readable-timestamp.png",
            importedAt: TestFixtures.importedAt,
        )
        try await environment.store.ingestionJournal.accept(unreadableEntry)
        try await environment.store.ingestionJournal.accept(unreadableCapturedAtEntry)
        try await environment.store.ingestionJournal.accept(readableEntry)
        let validatingEntry = try await environment.store.ingestionJournal.transition(
            unreadableCapturedAtEntry,
            to: .validating,
        )
        _ = try await environment.store.ingestionJournal.transition(
            validatingEntry,
            to: .duplicateCheck,
            inspection: ImageInspection(
                uti: "public.png",
                byteCount: Int64(environment.sourceBytes.count),
                sha256: SHA256.hash(data: environment.sourceBytes).hexString,
                capturedAt: Date(timeIntervalSince1970: .infinity),
            ),
        )

        let snapshot = try await environment.store.ingestionJournal.snapshot()

        #expect(snapshot.entries == [readableEntry])
        #expect(snapshot.unreadableAssetIDs == [unreadableEntry.id, unreadableCapturedAtEntry.id])
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

    @Test("Persistent interruption states recover after reopening SQLite and the resource store")
    func recoversPersistentInterruptionStatesAfterReopen() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("media-library-reopen-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let databaseURL = root.appendingPathComponent("library.sqlite")
        let resourcesRoot = root.appendingPathComponent("resources", isDirectory: true)
        let expectedAssets = try await seedPersistentRecoveryScenarios(
            databaseURL: databaseURL,
            resourcesRoot: resourcesRoot,
        )

        let reopenedDatabase = try PersistenceStore.makePersistent(at: databaseURL)
        let reopenedStore = SQLiteMediaLibraryStore(database: reopenedDatabase)
        let reopenedResources = try FileMediaResourceRepository(rootURL: resourcesRoot)
        let importer = makeImporter(store: reopenedStore, resources: reopenedResources)
        let alreadyCommittedAsset = try #require(
            expectedAssets.first(where: { $0.id == TestFixtures.recoveryAssetIDs[2] }),
        )
        #expect(try await reopenedStore.loadAssets() == [alreadyCommittedAsset])

        let firstLoad = try await importer.loadAssets()
        let secondLoad = try await importer.loadAssets()

        #expect(firstLoad.count == 3)
        #expect(Set(firstLoad.map(\.id)) == Set(expectedAssets.map(\.id)))
        #expect(secondLoad == firstLoad)
        for expectedAsset in expectedAssets {
            let recoveredAsset = try #require(firstLoad.first(where: { $0.id == expectedAsset.id }))
            #expect(recoveredAsset == expectedAsset)
            let resource = try #require(recoveredAsset.resources.first)
            #expect(try reopenedResources.data(for: resource) == TestFixtures.pngData)
        }
        #expect(try await reopenedStore.ingestionJournal.snapshot().entries.isEmpty)
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
    let database: any DatabaseWriter
    let store: SQLiteMediaLibraryStore
    let resources: FileMediaResourceRepository
    let importer: MediaLibraryImporter

    init(
        root: URL,
        sourceURL: URL,
        sourceBytes: Data,
        database: any DatabaseWriter,
        store: SQLiteMediaLibraryStore,
        resources: FileMediaResourceRepository,
        importer: MediaLibraryImporter,
    ) {
        self.root = root
        self.sourceURL = sourceURL
        self.sourceBytes = sourceBytes
        self.database = database
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
    static let preJournalAssetID = requiredUUID("00000000-0000-0000-0000-000000000020")
    static let preJournalResourceID = requiredUUID("00000000-0000-0000-0000-000000000021")
    static let recoveryAssetIDs = (0 ... 7).map { requiredUUID(String(
        format: "00000000-0000-0000-0000-%012x",
        0x100 + $0,
    )) }
    static let recoveryResourceIDs = (0 ... 7).map { requiredUUID(String(
        format: "00000000-0000-0000-0000-%012x",
        0x200 + $0,
    )) }
    static let importedAt = Date(timeIntervalSince1970: 1_725_000_000)
    static let pngData = requiredData(
        base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=",
    )
}

private func journalAsset(from entry: MediaIngestionJournalEntry) throws -> MediaAsset {
    guard let sourceUTI = entry.sourceUTI,
          let byteCount = entry.byteCount,
          let sha256 = entry.sha256
    else {
        throw MediaLibraryStoreError.corrupt
    }

    let resource = MediaResource(
        id: entry.resourceID,
        role: .original,
        relativePath: entry.resourceID.uuidString.lowercased(),
        sourceFilename: entry.sourceFilename,
        sourceUTI: sourceUTI,
        byteCount: byteCount,
        sha256: sha256,
    )
    return MediaAsset(
        id: entry.id,
        kind: .stillImage,
        importedAt: entry.importedAt,
        resources: [resource],
        capturedAt: entry.capturedAt,
    )
}

private func insertJournalEntry(
    _ entry: MediaIngestionJournalEntry,
    into database: any DatabaseWriter,
) async throws {
    try await database.write { db in
        try db.execute(
            sql: """
            INSERT INTO media_ingestion_journal (
              id, resource_id, state, source_filename, imported_at,
              source_uti, byte_count, sha256, captured_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            arguments: [
                entry.id.uuidString,
                entry.resourceID.uuidString,
                entry.state.rawValue,
                entry.sourceFilename,
                entry.importedAt.timeIntervalSince1970,
                entry.sourceUTI,
                entry.byteCount,
                entry.sha256,
                entry.capturedAt?.timeIntervalSince1970,
            ],
        )
    }
}

private func seedPersistentRecoveryScenarios(
    databaseURL: URL,
    resourcesRoot: URL,
) async throws -> [MediaAsset] {
    let database = try PersistenceStore.makePersistent(at: databaseURL)
    let store = SQLiteMediaLibraryStore(database: database)
    let resources = try FileMediaResourceRepository(rootURL: resourcesRoot)
    let importer = makeImporter(store: store, resources: resources)
    let inspection = ImageInspection(
        uti: "public.png",
        byteCount: Int64(TestFixtures.pngData.count),
        sha256: SHA256.hash(data: TestFixtures.pngData).hexString,
        capturedAt: nil,
    )

    func makeReadyEntry(index: Int) async throws -> MediaIngestionJournalEntry {
        let assetID = TestFixtures.recoveryAssetIDs[index]
        let resourceID = TestFixtures.recoveryResourceIDs[index]
        let stagingURL = resources.stagingURL(for: resourceID)
        try TestFixtures.pngData.write(to: stagingURL)
        try resources.protectStaging(for: resourceID)
        let received = MediaIngestionJournalEntry(
            id: assetID,
            resourceID: resourceID,
            state: .received,
            sourceFilename: "reopened-\(index).png",
            importedAt: TestFixtures.importedAt,
        )
        try await store.ingestionJournal.accept(received)
        let validating = try await store.ingestionJournal.transition(received, to: .validating)
        let duplicateCheck = try await store.ingestionJournal.transition(
            validating,
            to: .duplicateCheck,
            inspection: inspection,
        )
        return try await store.ingestionJournal.transition(duplicateCheck, to: .ready)
    }

    let protectedStagingEntry = try await makeReadyEntry(index: 0)

    var promotedEntry = try await makeReadyEntry(index: 1)
    promotedEntry = try await store.ingestionJournal.transition(promotedEntry, to: .committing)
    _ = try resources.promoteOrVerify(
        stagingURL: resources.stagingURL(for: promotedEntry.resourceID),
        resourceID: promotedEntry.resourceID,
        byteCount: inspection.byteCount,
        sha256: inspection.sha256,
    )

    var canonicalEntry = try await makeReadyEntry(index: 2)
    canonicalEntry = try await store.ingestionJournal.transition(canonicalEntry, to: .committing)
    _ = try resources.promoteOrVerify(
        stagingURL: resources.stagingURL(for: canonicalEntry.resourceID),
        resourceID: canonicalEntry.resourceID,
        byteCount: inspection.byteCount,
        sha256: inspection.sha256,
    )
    try await store.commit(journalAsset(from: canonicalEntry))

    withExtendedLifetime(importer) {}
    return try [protectedStagingEntry, promotedEntry, canonicalEntry].map { try journalAsset(from: $0) }
}

private func makeEnvironment(
    sourceName: String = "holiday-photo.png",
    sourceBytes: Data = TestFixtures.pngData,
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
    let mediaStore = SQLiteMediaLibraryStore(database: database)
    let resources = try resourcesFactory(root.appendingPathComponent("resources"))
    return ImportEnvironment(
        root: root,
        sourceURL: sourceURL,
        sourceBytes: sourceBytes,
        database: database,
        store: mediaStore,
        resources: resources,
        importer: makeImporter(store: mediaStore, resources: resources),
    )
}

private func makeImporter(
    store: SQLiteMediaLibraryStore,
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

private final class FirstAcceptedResourceReadFailure: @unchecked Sendable {
    private let lock = NSLock()
    private var didFail = false

    func read(_ url: URL) throws -> Data {
        lock.lock()
        let shouldFail = !didFail
        didFail = true
        lock.unlock()

        if shouldFail {
            throw InjectedAcceptedResourceReadFailure.unavailable
        }
        return try Data(contentsOf: url, options: [.mappedIfSafe])
    }
}

private actor SuspendedAcceptedResourceRead {
    private var didSuspendFirstRead = false
    private var firstReadRelease: CheckedContinuation<Void, Never>?
    private var firstReadObservers: [CheckedContinuation<Void, Never>] = []
    private var readCountValue = 0

    func read(_ url: URL) async throws -> Data {
        readCountValue += 1
        if !didSuspendFirstRead {
            didSuspendFirstRead = true
            await withCheckedContinuation { continuation in
                firstReadRelease = continuation
                let observers = firstReadObservers
                firstReadObservers.removeAll(keepingCapacity: true)
                observers.forEach { $0.resume() }
            }
        }

        return try Data(contentsOf: url, options: [.mappedIfSafe])
    }

    func waitForFirstReadSuspension() async {
        guard !didSuspendFirstRead else {
            return
        }

        await withCheckedContinuation { continuation in
            firstReadObservers.append(continuation)
        }
    }

    func releaseFirstRead() {
        firstReadRelease?.resume()
        firstReadRelease = nil
    }

    func readCount() -> Int {
        readCountValue
    }
}

private enum InjectedAcceptedResourceReadFailure: Error {
    case unavailable
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
