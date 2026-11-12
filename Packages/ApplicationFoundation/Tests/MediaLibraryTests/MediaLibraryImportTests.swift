//
//  MediaLibraryImportTests.swift
//  MediaVault
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import CoreFoundation
import CryptoKit
import Entitlement
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

    @Test("A rejected animated image does not block a later valid import")
    func animatedImageRejectionDoesNotBlockLaterImport() async throws {
        let environment = try makeEnvironment()
        let failedAssetID = requiredUUID("00000000-0000-0000-0000-000000000100")
        let failedResourceID = requiredUUID("00000000-0000-0000-0000-000000000101")
        let validAssetID = requiredUUID("00000000-0000-0000-0000-000000000102")
        let validResourceID = requiredUUID("00000000-0000-0000-0000-000000000103")
        let importer = makeImporter(
            store: environment.store,
            resources: environment.resources,
            identifiers: [failedAssetID, failedResourceID, validAssetID, validResourceID],
        )
        let animatedURL = environment.root.appendingPathComponent("rejected.gif")
        try makeAnimatedGIF(at: animatedURL, using: environment.sourceBytes)

        await #expect(throws: MediaImportError.unsupportedMedia) {
            try await importer.importFile(at: animatedURL)
        }

        let failedEntry = try #require(try await environment.store.ingestionJournal.snapshot().entries.first)
        #expect(failedEntry.id == failedAssetID)
        #expect(failedEntry.resourceID == failedResourceID)
        #expect(failedEntry.state == .failed)
        #expect(try await environment.store.loadAssets().isEmpty)
        #expect(try Data(contentsOf: environment.resources.stagingURL(for: failedResourceID)) ==
            Data(contentsOf: animatedURL))

        let validAsset = try? await importer.importFile(at: environment.sourceURL)

        #expect(validAsset?.id == validAssetID)
        #expect(try await environment.store.loadAssets().map(\.id) == [validAssetID])
        #expect(try await environment.store.logicalAssetCount() == 1)
        #expect(try await environment.store.ingestionJournal.snapshot().entries == [failedEntry])
        #expect(try Data(contentsOf: environment.resources.stagingURL(for: failedResourceID)) ==
            Data(contentsOf: animatedURL))
    }

    @Test("Unrenderable bytes do not block a later valid import")
    func unrenderableImageRejectionDoesNotBlockLaterImport() async throws {
        let environment = try makeEnvironment()
        let failedAssetID = requiredUUID("00000000-0000-0000-0000-000000000110")
        let failedResourceID = requiredUUID("00000000-0000-0000-0000-000000000111")
        let validAssetID = requiredUUID("00000000-0000-0000-0000-000000000112")
        let validResourceID = requiredUUID("00000000-0000-0000-0000-000000000113")
        let importer = makeImporter(
            store: environment.store,
            resources: environment.resources,
            identifiers: [failedAssetID, failedResourceID, validAssetID, validResourceID],
        )
        let invalidURL = environment.root.appendingPathComponent("rejected.png")
        let invalidBytes = Data([0x00, 0x01, 0x02, 0x03])
        try invalidBytes.write(to: invalidURL)

        await #expect(throws: MediaImportError.unrenderableMedia) {
            try await importer.importFile(at: invalidURL)
        }

        let failedEntry = try #require(try await environment.store.ingestionJournal.snapshot().entries.first)
        #expect(failedEntry.id == failedAssetID)
        #expect(failedEntry.resourceID == failedResourceID)
        #expect(failedEntry.state == .failed)
        #expect(try await environment.store.loadAssets().isEmpty)
        #expect(try Data(contentsOf: environment.resources.stagingURL(for: failedResourceID)) == invalidBytes)

        let validAsset = try? await importer.importFile(at: environment.sourceURL)

        #expect(validAsset?.id == validAssetID)
        #expect(try await environment.store.loadAssets().map(\.id) == [validAssetID])
        #expect(try await environment.store.logicalAssetCount() == 1)
        #expect(try await environment.store.ingestionJournal.snapshot().entries == [failedEntry])
        #expect(try Data(contentsOf: environment.resources.stagingURL(for: failedResourceID)) == invalidBytes)
    }

    @Test("A separate importer can continue after a failed journal entry")
    func separateImporterContinuesAfterFailedJournalEntry() async throws {
        let environment = try makeEnvironment()
        let failedAssetID = requiredUUID("00000000-0000-0000-0000-000000000120")
        let failedResourceID = requiredUUID("00000000-0000-0000-0000-000000000121")
        let validAssetID = requiredUUID("00000000-0000-0000-0000-000000000122")
        let validResourceID = requiredUUID("00000000-0000-0000-0000-000000000123")
        let rejectedURL = environment.root.appendingPathComponent("rejected.png")
        let rejectedBytes = Data([0x10, 0x20, 0x30, 0x40])
        try rejectedBytes.write(to: rejectedURL)
        let firstImporter = makeImporter(
            store: environment.store,
            resources: environment.resources,
            identifiers: [failedAssetID, failedResourceID],
        )

        await #expect(throws: MediaImportError.unrenderableMedia) {
            try await firstImporter.importFile(at: rejectedURL)
        }

        let failedEntry = try #require(try await environment.store.ingestionJournal.snapshot().entries.first)
        #expect(failedEntry.state == .failed)
        #expect(try Data(contentsOf: environment.resources.stagingURL(for: failedResourceID)) == rejectedBytes)
        let nextImporter = makeImporter(
            store: environment.store,
            resources: environment.resources,
            identifiers: [validAssetID, validResourceID],
        )

        let validAsset = try? await nextImporter.importFile(at: environment.sourceURL)

        #expect(validAsset?.id == validAssetID)
        #expect(try await environment.store.loadAssets().map(\.id) == [validAssetID])
        #expect(try await environment.store.ingestionJournal.snapshot().entries == [failedEntry])
        #expect(try Data(contentsOf: environment.resources.stagingURL(for: failedResourceID)) == rejectedBytes)
    }

    @Test("A rejected interrupted validation does not block admission after reopen")
    func rejectedInterruptedValidationDoesNotBlockFreshImportAfterReopen() async throws {
        let root = FileManager.default
            .temporaryDirectory
            .appendingPathComponent("interrupted-validation-library-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let databaseURL = root.appendingPathComponent("library.sqlite")
        let resourceRoot = root.appendingPathComponent("resources", isDirectory: true)
        let rejectedAssetID = requiredUUID("00000000-0000-0000-0000-000000000130")
        let rejectedResourceID = requiredUUID("00000000-0000-0000-0000-000000000131")
        let importedAssetID = requiredUUID("00000000-0000-0000-0000-000000000132")
        let importedResourceID = requiredUUID("00000000-0000-0000-0000-000000000133")
        let rejectedBytes = Data([0x00, 0x01, 0x02, 0x03])
        let freshSourceURL = root.appendingPathComponent("fresh.png")
        try TestFixtures.pngData.write(to: freshSourceURL)

        func persistInterruptedValidation() async throws -> MediaIngestionJournalEntry {
            let database = try PersistenceStore.makePersistent(at: databaseURL)
            let store = SQLiteMediaLibraryStore(database: database)
            let resources = try FileMediaResourceRepository(rootURL: resourceRoot)
            let stagingURL = resources.stagingURL(for: rejectedResourceID)
            try rejectedBytes.write(to: stagingURL)
            try resources.protectStaging(for: rejectedResourceID)

            let acceptedEntry = MediaIngestionJournalEntry(
                id: rejectedAssetID,
                resourceID: rejectedResourceID,
                state: .received,
                sourceFilename: "interrupted.png",
                importedAt: TestFixtures.importedAt,
            )
            try await store.ingestionJournal.accept(acceptedEntry)
            return try await store.ingestionJournal.transition(acceptedEntry, to: .validating)
        }

        let interruptedEntry = try await persistInterruptedValidation()
        #expect(interruptedEntry.state == .validating)

        let reopenedDatabase = try PersistenceStore.makePersistent(at: databaseURL)
        let reopenedStore = SQLiteMediaLibraryStore(database: reopenedDatabase)
        let reopenedResources = try FileMediaResourceRepository(rootURL: resourceRoot)
        let importer = makeImporter(
            store: reopenedStore,
            resources: reopenedResources,
            identifiers: [importedAssetID, importedResourceID],
        )

        let beforeRecovery = try #require(
            try await reopenedStore.ingestionJournal.snapshot().entries.first(where: { $0.id == rejectedAssetID }),
        )
        #expect(beforeRecovery.state == .validating)
        #expect(try Data(contentsOf: reopenedResources.stagingURL(for: rejectedResourceID)) == rejectedBytes)

        let importedAsset = try? await importer.importFile(at: freshSourceURL)

        #expect(
            importedAsset?.id == importedAssetID,
            "A durably failed interrupted import must not block a fresh valid import",
        )
        let recoveredEntry = try #require(
            try await reopenedStore.ingestionJournal.snapshot().entries.first(where: { $0.id == rejectedAssetID }),
        )
        #expect(recoveredEntry.state == .failed)
        #expect(try await reopenedStore.loadAssets().map(\.id) == [importedAssetID])
        #expect(try await reopenedStore.logicalAssetCount() == 1)
        #expect(try Data(contentsOf: reopenedResources.stagingURL(for: rejectedResourceID)) == rejectedBytes)

        let verifiedDatabase = try PersistenceStore.makePersistent(at: databaseURL)
        let verifiedStore = SQLiteMediaLibraryStore(database: verifiedDatabase)
        let verifiedResources = try FileMediaResourceRepository(rootURL: resourceRoot)
        let persistedEntry = try #require(
            try await verifiedStore.ingestionJournal.snapshot().entries.first(where: { $0.id == rejectedAssetID }),
        )
        #expect(persistedEntry.state == .failed)
        let persistedAssets = try await verifiedStore.loadAssets()
        #expect(persistedAssets.map(\.id) == [importedAssetID])
        let importedResource = try #require(persistedAssets.first?.resources.first)
        #expect(try verifiedResources.data(for: importedResource) == TestFixtures.pngData)
        #expect(try Data(contentsOf: verifiedResources.stagingURL(for: rejectedResourceID)) == rejectedBytes)
    }

    @Test("An unverified failed transition keeps interrupted work blocking admission")
    func unverifiedFailedTransitionKeepsAdmissionBlocked() async throws {
        let environment = try makeEnvironment()
        let rejectedAssetID = requiredUUID("00000000-0000-0000-0000-000000000134")
        let rejectedResourceID = requiredUUID("00000000-0000-0000-0000-000000000135")
        let rejectedBytes = Data([0x10, 0x20, 0x30, 0x40])
        let stagingURL = environment.resources.stagingURL(for: rejectedResourceID)
        try rejectedBytes.write(to: stagingURL)
        try environment.resources.protectStaging(for: rejectedResourceID)

        let acceptedEntry = MediaIngestionJournalEntry(
            id: rejectedAssetID,
            resourceID: rejectedResourceID,
            state: .received,
            sourceFilename: "unverified-failure.png",
            importedAt: TestFixtures.importedAt,
        )
        try await environment.store.ingestionJournal.accept(acceptedEntry)
        let validatingEntry = try await environment.store.ingestionJournal.transition(acceptedEntry, to: .validating)
        #expect(validatingEntry.state == .validating)
        try await environment.database.write { db in
            try db.execute(
                sql: """
                CREATE TRIGGER prevent_failed_journal_transition
                BEFORE UPDATE OF state ON media_ingestion_journal
                WHEN NEW.state = 'failed'
                BEGIN
                    SELECT RAISE(ABORT, 'failed transition intentionally blocked');
                END
                """,
            )
        }

        await #expect(throws: MediaImportError.persistenceFailed) {
            try await environment.importer.importFile(at: environment.sourceURL)
        }
        let remainingEntry = try #require(
            try await environment.store.ingestionJournal.snapshot().entries.first(where: { $0.id == rejectedAssetID }),
        )
        #expect(remainingEntry.state == .validating)
        #expect(try await environment.store.loadAssets().isEmpty)
        #expect(try await environment.store.logicalAssetCount() == 0)
        #expect(try Data(contentsOf: stagingURL) == rejectedBytes)
    }

    @Test("Failed and cancelled journal rows remain preserved without blocking admission")
    func terminalJournalRowsDoNotBlockFreshImport() async throws {
        let environment = try makeEnvironment()
        let failedID = TestFixtures.recoveryAssetIDs[6]
        let failedResourceID = TestFixtures.recoveryResourceIDs[6]
        let cancelledID = TestFixtures.recoveryAssetIDs[7]
        let cancelledResourceID = TestFixtures.recoveryResourceIDs[7]
        let failedBytes = Data([0x51, 0x52])
        let cancelledBytes = Data([0x61, 0x62])
        try failedBytes.write(to: environment.resources.stagingURL(for: failedResourceID))
        try cancelledBytes.write(to: environment.resources.stagingURL(for: cancelledResourceID))
        try environment.resources.protectStaging(for: failedResourceID)
        try environment.resources.protectStaging(for: cancelledResourceID)
        let failedReceived = MediaIngestionJournalEntry(
            id: failedID,
            resourceID: failedResourceID,
            state: .received,
            sourceFilename: "failed.png",
            importedAt: TestFixtures.importedAt,
        )
        try await environment.store.ingestionJournal.accept(failedReceived)
        let failedValidating = try await environment.store.ingestionJournal.transition(failedReceived, to: .validating)
        let failedEntry = try await environment.store.ingestionJournal.transition(failedValidating, to: .failed)
        let cancelledReceived = MediaIngestionJournalEntry(
            id: cancelledID,
            resourceID: cancelledResourceID,
            state: .received,
            sourceFilename: "cancelled.png",
            importedAt: TestFixtures.importedAt,
        )
        try await environment.store.ingestionJournal.accept(cancelledReceived)
        let cancelledEntry = try await environment.store.ingestionJournal.transition(cancelledReceived, to: .cancelled)

        let validAsset = try? await environment.importer.importFile(at: environment.sourceURL)

        #expect(validAsset?.id == TestFixtures.assetID)
        #expect(try await environment.store.loadAssets().map(\.id) == [TestFixtures.assetID])
        #expect(try await environment.store.ingestionJournal.snapshot().entries == [failedEntry, cancelledEntry])
        #expect(try Data(contentsOf: environment.resources.stagingURL(for: failedResourceID)) == failedBytes)
        #expect(try Data(contentsOf: environment.resources.stagingURL(for: cancelledResourceID)) == cancelledBytes)
    }

    @Test("Unreadable journal evidence blocks admission without losing its resource")
    func unreadableJournalEvidenceRemainsBlockingAndPreserved() async throws {
        let environment = try makeEnvironment()
        _ = try await environment.store.ingestionJournal.snapshot()
        let damagedAssetID = TestFixtures.recoveryAssetIDs[4]
        let damagedResourceID = TestFixtures.recoveryResourceIDs[4]
        let damagedBytes = Data([0x81, 0x82, 0x83])
        let stagingURL = environment.resources.stagingURL(for: damagedResourceID)
        try damagedBytes.write(to: stagingURL)
        try environment.resources.protectStaging(for: damagedResourceID)
        try await environment.database.write { db in
            try db.execute(
                sql: """
                INSERT INTO media_ingestion_journal (
                  id, resource_id, state, source_filename, imported_at,
                  source_uti, byte_count, sha256, captured_at
                ) VALUES (?, ?, 'received', 'damaged.png', 'not-a-timestamp', NULL, NULL, NULL, NULL)
                """,
                arguments: [damagedAssetID.uuidString, damagedResourceID.uuidString],
            )
        }

        await #expect(throws: MediaImportError.persistenceFailed) {
            try await environment.importer.importFile(at: environment.sourceURL)
        }

        let snapshot = try await environment.store.ingestionJournal.snapshot()
        #expect(snapshot.entries.isEmpty)
        #expect(snapshot.unreadableAssetIDs == [damagedAssetID])
        #expect(snapshot.knownResourceIDs == [damagedResourceID])
        #expect(try await environment.store.logicalAssetCount() == 0)
        #expect(try Data(contentsOf: stagingURL) == damagedBytes)
        #expect(environment.resources.stagedResourceIDs() == [damagedResourceID])
    }

    @Test("A journal row without an asset UUID blocks admission but leaves reads available")
    func journalRowWithoutAssetUUIDBlocksAdmissionButLeavesReadsAvailable() async throws {
        let environment = try makeEnvironment()
        _ = try await environment.store.ingestionJournal.snapshot()
        let damagedResourceID = requiredUUID("00000000-0000-0000-0000-000000000181")
        let damagedBytes = Data([0x91, 0x92, 0x93])
        let stagingURL = environment.resources.stagingURL(for: damagedResourceID)
        try damagedBytes.write(to: stagingURL)
        try environment.resources.protectStaging(for: damagedResourceID)
        try await environment.database.write { db in
            try db.execute(
                sql: """
                INSERT INTO media_ingestion_journal (
                  id, resource_id, state, source_filename, imported_at,
                  source_uti, byte_count, sha256, captured_at
                ) VALUES ('not-an-asset-uuid', ?, 'received', 'unidentified.png', 1725000000, NULL, NULL, NULL, NULL)
                """,
                arguments: [damagedResourceID.uuidString],
            )
        }

        let snapshot = try await environment.store.ingestionJournal.snapshot()
        #expect(snapshot.entries.isEmpty)
        #expect(snapshot.unreadableAssetIDs.isEmpty)
        #expect(snapshot.hasUnidentifiedAssetRows)
        #expect(snapshot.knownResourceIDs == [damagedResourceID])

        await #expect(throws: MediaImportError.persistenceFailed) {
            try await environment.importer.importFile(at: environment.sourceURL)
        }
        #expect(try await environment.importer.loadAssets().isEmpty)

        let rowCount = try await environment.database.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM media_ingestion_journal") ?? 0
        }
        #expect(rowCount == 1)
        #expect(try await environment.store.logicalAssetCount() == 0)
        #expect(try Data(contentsOf: stagingURL) == damagedBytes)
        #expect(environment.resources.stagedResourceIDs().contains(damagedResourceID))
    }

    @Test("Unidentified journal evidence preserves committed reads and blocks admission after reopen")
    func unidentifiedJournalRowPreservesCommittedReadsAndBlocksAdmissionAfterReopen() async throws {
        let root = FileManager.default
            .temporaryDirectory
            .appendingPathComponent("unidentified-journal-library-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let databaseURL = root.appendingPathComponent("library.sqlite")
        let resourceRoot = root.appendingPathComponent("resources", isDirectory: true)
        let committedSourceURL = root.appendingPathComponent("committed.png")
        try TestFixtures.pngData.write(to: committedSourceURL)

        let database = try PersistenceStore.makePersistent(at: databaseURL)
        let store = SQLiteMediaLibraryStore(database: database)
        let resources = try FileMediaResourceRepository(rootURL: resourceRoot)
        let committedAssetID = requiredUUID("00000000-0000-0000-0000-000000000190")
        let committedResourceID = requiredUUID("00000000-0000-0000-0000-000000000191")
        let importer = makeImporter(
            store: store,
            resources: resources,
            identifiers: [committedAssetID, committedResourceID],
        )
        let committedAsset = try await importer.importFile(at: committedSourceURL)
        let committedResource = try #require(committedAsset.resources.first)

        let unidentifiedResourceID = requiredUUID("00000000-0000-0000-0000-000000000192")
        let protectedBytes = Data("unidentified-journal-staging".utf8)
        let stagingURL = resources.stagingURL(for: unidentifiedResourceID)
        try protectedBytes.write(to: stagingURL)
        try resources.protectStaging(for: unidentifiedResourceID)
        try await database.write { db in
            try db.execute(
                sql: """
                INSERT INTO media_ingestion_journal (
                  id, resource_id, state, source_filename, imported_at,
                  source_uti, byte_count, sha256, captured_at
                ) VALUES ('not-an-asset-uuid', ?, 'received', 'unidentified.png', ?, NULL, NULL, NULL, NULL)
                """,
                arguments: [
                    unidentifiedResourceID.uuidString,
                    TestFixtures.importedAt.timeIntervalSince1970,
                ],
            )
        }

        let beforeReopen = try await store.ingestionJournal.snapshot()
        #expect(beforeReopen.entries.isEmpty)
        #expect(beforeReopen.unreadableAssetIDs.isEmpty)
        #expect(beforeReopen.hasUnidentifiedAssetRows)
        #expect(beforeReopen.knownResourceIDs == [unidentifiedResourceID])

        let loadedAssets = try await importer.loadAssets()
        #expect(loadedAssets == [committedAsset])
        #expect(try resources.data(for: committedResource) == TestFixtures.pngData)

        let rejectedSourceURL = root.appendingPathComponent("rejected.png")
        try TestFixtures.pngData.write(to: rejectedSourceURL)
        await #expect(throws: MediaImportError.persistenceFailed) {
            try await importer.importFile(at: rejectedSourceURL)
        }

        let reopenedDatabase = try PersistenceStore.makePersistent(at: databaseURL)
        let reopenedStore = SQLiteMediaLibraryStore(database: reopenedDatabase)
        let reopenedResources = try FileMediaResourceRepository(rootURL: resourceRoot)
        let reopenedImporter = makeImporter(
            store: reopenedStore,
            resources: reopenedResources,
            identifiers: [
                requiredUUID("00000000-0000-0000-0000-000000000193"),
                requiredUUID("00000000-0000-0000-0000-000000000194"),
            ],
        )

        #expect(try await reopenedImporter.loadAssets() == [committedAsset])
        #expect(try reopenedResources.data(for: committedResource) == TestFixtures.pngData)
        await #expect(throws: MediaImportError.persistenceFailed) {
            try await reopenedImporter.importFile(at: rejectedSourceURL)
        }

        let afterReopen = try await reopenedStore.ingestionJournal.snapshot()
        #expect(afterReopen.entries.isEmpty)
        #expect(afterReopen.unreadableAssetIDs.isEmpty)
        #expect(afterReopen.hasUnidentifiedAssetRows)
        #expect(afterReopen.knownResourceIDs == [unidentifiedResourceID])
        let preservedRow = try await reopenedDatabase.read { db in
            try String.fetchOne(
                db,
                sql: """
                SELECT id || '|' || resource_id || '|' || state || '|' || source_filename || '|'
                  || CAST(imported_at AS TEXT) || '|' || COALESCE(source_uti, '<null>') || '|'
                  || COALESCE(CAST(byte_count AS TEXT), '<null>') || '|' || COALESCE(sha256, '<null>') || '|'
                  || COALESCE(CAST(captured_at AS TEXT), '<null>')
                FROM media_ingestion_journal
                """,
            )
        }
        let expectedRow = [
            "not-an-asset-uuid",
            unidentifiedResourceID.uuidString,
            "received",
            "unidentified.png",
            String(TestFixtures.importedAt.timeIntervalSince1970),
            "<null>",
            "<null>",
            "<null>",
            "<null>",
        ].joined(separator: "|")
        #expect(
            preservedRow == expectedRow,
            "Preserved row \(String(reflecting: preservedRow)) did not match \(expectedRow)",
        )
        #expect(try await reopenedStore.loadAssets() == [committedAsset])
        #expect(try await reopenedStore.logicalAssetCount() == 1)
        #expect(try Data(contentsOf: stagingURL) == protectedBytes)
        #expect(reopenedResources.stagedResourceIDs() == [unidentifiedResourceID])
    }

    @Test("An awaiting decision remains untouched when a fresh import is attempted")
    func awaitingDecisionRemainsUntouchedDuringAdmission() async throws {
        let environment = try makeEnvironment()
        let entry = MediaIngestionJournalEntry(
            id: TestFixtures.recoveryAssetIDs[5],
            resourceID: TestFixtures.recoveryResourceIDs[5],
            state: .received,
            sourceFilename: "awaiting-decision.png",
            importedAt: TestFixtures.importedAt,
        )
        try environment.sourceBytes.write(to: environment.resources.stagingURL(for: entry.resourceID))
        try environment.resources.protectStaging(for: entry.resourceID)
        try await environment.store.ingestionJournal.accept(entry)
        let validating = try await environment.store.ingestionJournal.transition(entry, to: .validating)
        let inspection = ImageInspection(
            uti: "public.png",
            byteCount: Int64(environment.sourceBytes.count),
            sha256: SHA256.hash(data: environment.sourceBytes).hexString,
            capturedAt: nil,
        )
        let duplicateCheck = try await environment.store.ingestionJournal.transition(
            validating,
            to: .duplicateCheck,
            inspection: inspection,
        )
        let awaitingDecision = try await environment.store.ingestionJournal.transition(
            duplicateCheck,
            to: .awaitingUserDecision,
        )

        await #expect(throws: MediaImportError.persistenceFailed) {
            try await environment.importer.importFile(at: environment.sourceURL)
        }

        #expect(try await environment.store.ingestionJournal.snapshot().entries == [awaitingDecision])
        #expect(try await environment.store.loadAssets().isEmpty)
        #expect(try Data(contentsOf: environment.resources.stagingURL(for: entry.resourceID)) == environment
            .sourceBytes)
    }

    @Test("A failed journal row stays preserved and does not block admission after reopen")
    func failedJournalRowDoesNotBlockAdmissionAfterPersistentReopen() async throws {
        let root = FileManager.default
            .temporaryDirectory
            .appendingPathComponent("persistent-media-library-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let databaseURL = root.appendingPathComponent("library.sqlite")
        let resourceRoot = root.appendingPathComponent("resources", isDirectory: true)
        let invalidURL = root.appendingPathComponent("rejected.png")
        let invalidBytes = Data([0x71, 0x72, 0x73])
        try invalidBytes.write(to: invalidURL)
        let failedAssetID = requiredUUID("00000000-0000-0000-0000-000000000130")
        let failedResourceID = requiredUUID("00000000-0000-0000-0000-000000000131")

        let failedEntry = try await persistRejectedImport(
            databaseURL: databaseURL,
            resourceRoot: resourceRoot,
            rejectedURL: invalidURL,
            assetID: failedAssetID,
            resourceID: failedResourceID,
        )

        #expect(failedEntry.state == .failed)
        #expect(try Data(contentsOf: FileMediaResourceRepository(rootURL: resourceRoot)
                .stagingURL(for: failedResourceID)) == invalidBytes)
        let reopenedDatabase = try PersistenceStore.makePersistent(at: databaseURL)
        let reopenedStore = SQLiteMediaLibraryStore(database: reopenedDatabase)
        let reopenedResources = try FileMediaResourceRepository(rootURL: resourceRoot)
        let validAssetID = requiredUUID("00000000-0000-0000-0000-000000000132")
        let importer = makeImporter(
            store: reopenedStore,
            resources: reopenedResources,
            identifiers: [validAssetID, requiredUUID("00000000-0000-0000-0000-000000000133")],
        )
        let validSourceURL = root.appendingPathComponent("valid.png")
        try TestFixtures.pngData.write(to: validSourceURL)

        let validAsset = try? await importer.importFile(at: validSourceURL)

        #expect(validAsset?.id == validAssetID)
        #expect(try await reopenedStore.loadAssets().map(\.id) == [validAssetID])
        #expect(try await reopenedStore.ingestionJournal.snapshot().entries == [failedEntry])
        #expect(try Data(contentsOf: reopenedResources.stagingURL(for: failedResourceID)) == invalidBytes)
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

    @Test("Importers sharing a store serialize admission at the Free limit")
    func sharedStoreSerializesAdmissionAcrossImporters() async throws {
        let acceptedResourceRead = SuspendedAcceptedResourceRead()
        let environment = try makeEnvironment(
            entitlement: makeEntitlement { .notEntitled },
            resourcesFactory: { root in
                try FileMediaResourceRepository(
                    rootURL: root,
                    protectionOperation: { _ in },
                    acceptedResourceReadOperation: { url in
                        try await acceptedResourceRead.read(url)
                    },
                )
            },
        )
        try await seedQuotaAssets(
            count: MediaLibraryQuota.freeLogicalAssetLimit - 1,
            into: environment.store,
        )

        let firstImporter = makeImporter(
            store: environment.store,
            resources: environment.resources,
        )
        let rejectedAssetID = TestFixtures.recoveryAssetIDs[0]
        let rejectedResourceID = TestFixtures.recoveryResourceIDs[0]
        let rejectedSourceCopy = SourceCopyCounter()
        let rejectedImporter = makeImporter(
            store: environment.store,
            resources: environment.resources,
            entitlement: makeEntitlement { .notEntitled },
            source: MediaSourceClient(copyOperation: { sourceURL, stagingURL in
                try rejectedSourceCopy.copy(from: sourceURL, to: stagingURL)
            }),
            identifiers: [rejectedAssetID, rejectedResourceID],
        )

        let sourceURL = environment.sourceURL
        let firstImport = Task {
            try await firstImporter.importFile(at: sourceURL)
        }
        await acceptedResourceRead.waitForFirstReadSuspension()

        let rejectedImport = Task {
            try await rejectedImporter.importFile(at: sourceURL)
        }
        await rejectedImporter.waitForDurableOperationWaiterForTesting()
        let gatedState = await rejectedImporter.durableOperationGateStateForTesting()
        #expect(gatedState.isActive)
        #expect(gatedState.waiterCount == 1)

        await acceptedResourceRead.releaseFirstRead()
        let importedAsset = try await firstImport.value
        await #expect(throws: MediaImportError.assetLimitReached) {
            try await rejectedImport.value
        }

        let journalEntries = try await environment.store.ingestionJournal.snapshot().entries
        #expect(await rejectedSourceCopy.count() == 0)
        #expect(try await environment.store.logicalAssetCount() == MediaLibraryQuota.freeLogicalAssetLimit)
        #expect(!journalEntries.contains { $0.id == rejectedAssetID })
        #expect(journalEntries.isEmpty)
        #expect(
            !FileManager.default.fileExists(
                atPath: environment.resources.stagingURL(for: rejectedResourceID).path,
            ),
        )
        #expect(importedAsset.id == TestFixtures.assetID)
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

    @Test("An import below the free limit does not read entitlement")
    func belowFreeLimitSkipsEntitlement() async throws {
        let environment = try makeEnvironment(
            entitlement: makeEntitlement { throw EntitlementError.verificationFailed },
        )
        try await seedQuotaAssets(count: MediaLibraryQuota.freeLogicalAssetLimit - 1, into: environment.store)

        _ = try await environment.importer.importFile(at: environment.sourceURL)

        #expect(try await environment.store.logicalAssetCount() == MediaLibraryQuota.freeLogicalAssetLimit)
    }

    @Test("A verified Pro entitlement admits an import at the free limit")
    func entitledImportAllowedAtFreeLimit() async throws {
        let entitlementProbe = EntitlementStateProbe(state: .entitled)
        let environment = try makeEnvironment(
            entitlement: makeEntitlement { await entitlementProbe.currentState() },
        )
        try await seedQuotaAssets(count: MediaLibraryQuota.freeLogicalAssetLimit, into: environment.store)

        _ = try await environment.importer.importFile(at: environment.sourceURL)

        #expect(try await environment.store.logicalAssetCount() == MediaLibraryQuota.freeLogicalAssetLimit + 1)
        #expect(await entitlementProbe.readCount() == 1)
    }

    @Test("A verified non-entitlement denies import at the free limit before staging")
    func notEntitledImportDeniedAtFreeLimit() async throws {
        try await expectQuotaDenial(for: .notEntitled)
    }

    @Test("A revoked entitlement denies import at the free limit before staging")
    func revokedImportDeniedAtFreeLimit() async throws {
        try await expectQuotaDenial(for: .revoked)
    }

    @Test("A canceled entitlement lookup cannot stage a new import")
    func canceledAdmissionDoesNotStageNewImport() async throws {
        let entitlementLookup = EntitlementStateSuspension()
        let environment = try makeEnvironment(
            entitlement: makeEntitlement { await entitlementLookup.read() },
        )
        try await seedQuotaAssets(count: MediaLibraryQuota.freeLogicalAssetLimit, into: environment.store)

        let importTask = Task {
            try await environment.importer.importFile(at: environment.sourceURL)
        }
        await entitlementLookup.waitUntilRequested()
        importTask.cancel()
        await entitlementLookup.resume(with: .entitled)

        await #expect(throws: CancellationError.self) {
            try await importTask.value
        }

        #expect(try await environment.store.logicalAssetCount() == MediaLibraryQuota.freeLogicalAssetLimit)
        #expect(try await environment.store.ingestionJournal.snapshot().entries.isEmpty)
        #expect(
            !FileManager.default.fileExists(
                atPath: environment.resources.stagingURL(for: TestFixtures.resourceID).path,
            ),
        )
    }

    @Test("A lock during entitlement verification cannot admit a fresh import")
    func lockDuringEntitlementVerificationPreventsNewImportAdmission() async throws {
        let entitlementLookup = EntitlementStateSuspension()
        let entitlement = makeEntitlement { await entitlementLookup.read() }
        let environment = try makeEnvironment(entitlement: entitlement)
        try await seedQuotaAssets(count: MediaLibraryQuota.freeLogicalAssetLimit, into: environment.store)
        let fence = MediaLibraryResourceLoadFence()
        let importer = makeImporter(
            store: environment.store,
            resources: environment.resources,
            entitlement: entitlement,
            sessionIsCurrent: { fence.isCurrent($0) },
            sessionAdmission: { fence.claimImportAdmission(generation: $0) },
        )

        let importTask = Task {
            try await importer.importFile(at: environment.sourceURL, sessionGeneration: 0)
        }
        await entitlementLookup.waitUntilRequested()
        fence.advance()
        await entitlementLookup.resume(with: .entitled)

        await #expect(throws: CancellationError.self) {
            try await importTask.value
        }

        #expect(try await environment.store.logicalAssetCount() == MediaLibraryQuota.freeLogicalAssetLimit)
        #expect(try await environment.store.ingestionJournal.snapshot().entries.isEmpty)
        #expect(
            !FileManager.default.fileExists(
                atPath: environment.resources.stagingURL(for: TestFixtures.resourceID).path,
            ),
        )
    }

    @Test("A lock before journal acceptance rejects the new import")
    func lockBeforeJournalAcceptanceRejectsFreshImport() async throws {
        let acceptanceSuspension = JournalAcceptanceSuspension()
        let environment = try makeEnvironment()
        let fence = MediaLibraryResourceLoadFence()
        let importer = makeImporter(
            store: environment.store,
            resources: environment.resources,
            identifiers: [
                requiredUUID("00000000-0000-0000-0000-000001000140"),
                requiredUUID("00000000-0000-0000-0000-000001000141"),
            ],
            sessionIsCurrent: { fence.isCurrent($0) },
            sessionAdmission: { fence.claimImportAdmission(generation: $0) },
        )
        await importer.setBeforeJournalAcceptanceForTesting {
            await acceptanceSuspension.suspend()
        }

        let importTask = Task {
            try await importer.importFile(at: environment.sourceURL, sessionGeneration: 0)
        }
        await acceptanceSuspension.waitUntilSuspended()
        fence.advance()
        await acceptanceSuspension.resume()

        await #expect(throws: CancellationError.self) {
            try await importTask.value
        }

        #expect(try await environment.store.loadAssets().isEmpty)
        #expect(try await environment.store.ingestionJournal.snapshot().entries.isEmpty)
        #expect(environment.resources.stagedResourceIDs().isEmpty)
        #expect(finalResourceURLs(in: environment.resources).isEmpty)
    }

    @Test("A lock after the session check but before journal acceptance rejects the import")
    func lockBetweenSessionCheckAndJournalAcceptanceRejectsFreshImport() async throws {
        let acceptanceSuspension = JournalAcceptanceSuspension()
        let environment = try makeEnvironment()
        let fence = MediaLibraryResourceLoadFence()
        let importer = makeImporter(
            store: environment.store,
            resources: environment.resources,
            sessionIsCurrent: { fence.isCurrent($0) },
            sessionAdmission: { fence.claimImportAdmission(generation: $0) },
        )
        await importer.setBeforeJournalAcceptanceForTesting {
            await acceptanceSuspension.suspend()
        }

        let importTask = Task {
            try await importer.importFile(at: environment.sourceURL, sessionGeneration: 0)
        }
        await acceptanceSuspension.waitUntilSuspended()
        fence.advance()
        await acceptanceSuspension.resume()

        await #expect(throws: CancellationError.self) {
            try await importTask.value
        }

        #expect(try await environment.store.ingestionJournal.snapshot().entries.isEmpty)
        #expect(environment.resources.stagedResourceIDs().isEmpty)
        #expect(finalResourceURLs(in: environment.resources).isEmpty)
    }

    @Test("Lock during a suspended journal write cancels an unaccepted import")
    func lockDuringSuspendedJournalWriteCancelsUnacceptedImport() async throws {
        let acceptanceSuspension = JournalAcceptanceSuspension()
        let environment = try makeEnvironment()
        let fence = MediaLibraryResourceLoadFence()
        let attemptedAssetID = requiredUUID("00000000-0000-0000-0000-000001000160")
        let attemptedResourceID = requiredUUID("00000000-0000-0000-0000-000001000161")
        let freshAssetID = requiredUUID("00000000-0000-0000-0000-000001000162")
        let freshResourceID = requiredUUID("00000000-0000-0000-0000-000001000163")
        let importer = makeImporter(
            store: environment.store,
            resources: environment.resources,
            identifiers: [attemptedAssetID, attemptedResourceID, freshAssetID, freshResourceID],
            sessionIsCurrent: { fence.isCurrent($0) },
            sessionAdmission: { fence.claimImportAdmission(generation: $0) },
        )
        await environment.store.ingestionJournal.setBeforeAcceptanceWriteForTesting {
            await acceptanceSuspension.suspend()
        }

        let importTask = Task {
            try await importer.importFile(at: environment.sourceURL, sessionGeneration: 0)
        }
        await acceptanceSuspension.waitUntilSuspended()
        fence.advance()
        importTask.cancel()
        await acceptanceSuspension.resume()

        await #expect(throws: CancellationError.self) {
            try await importTask.value
        }

        #expect(try await environment.store.ingestionJournal.snapshot().entries.isEmpty)
        #expect(environment.resources.stagedResourceIDs().isEmpty)
        #expect(finalResourceURLs(in: environment.resources).isEmpty)
        #expect(
            !FileManager.default.fileExists(
                atPath: environment.resources.stagingURL(for: attemptedResourceID).path,
            ),
        )

        let freshAsset = try await importer.importFile(at: environment.sourceURL, sessionGeneration: 1)

        #expect(freshAsset.id == freshAssetID)
        #expect(try await environment.store.logicalAssetCount() == 1)
        #expect(try await environment.store.loadAssets().map(\.id) == [freshAssetID])
        #expect(try await environment.store.ingestionJournal.snapshot().entries.isEmpty)
        #expect(environment.resources.stagedResourceIDs().isEmpty)
        #expect(try Data(contentsOf: environment.resources.url(for: #require(freshAsset.resources.first))) ==
            environment.sourceBytes)
    }

    @Test("A durable acceptance suspended across lock is recovered after authentication")
    func durableAcceptanceSuspendedAcrossLockRecoversBeforeFreshImport() async throws {
        let acceptanceSuspension = JournalAcceptanceSuspension()
        let environment = try makeEnvironment()
        let fence = MediaLibraryResourceLoadFence()
        let acceptedAssetID = requiredUUID("00000000-0000-0000-0000-000001000150")
        let acceptedResourceID = requiredUUID("00000000-0000-0000-0000-000001000151")
        let freshAssetID = requiredUUID("00000000-0000-0000-0000-000001000152")
        let freshResourceID = requiredUUID("00000000-0000-0000-0000-000001000153")
        let importer = makeImporter(
            store: environment.store,
            resources: environment.resources,
            identifiers: [acceptedAssetID, acceptedResourceID, freshAssetID, freshResourceID],
            sessionIsCurrent: { fence.isCurrent($0) },
            sessionAdmission: { fence.claimImportAdmission(generation: $0) },
        )
        await importer.setJournalAcceptanceForTesting { operation in
            try await operation()
            await acceptanceSuspension.suspend()
        }

        let importTask = Task {
            try await importer.importFile(at: environment.sourceURL, sessionGeneration: 0)
        }
        await acceptanceSuspension.waitUntilSuspended()
        let acceptedEntry = try #require(try await environment.store.ingestionJournal.snapshot().entries.first)
        #expect(acceptedEntry.id == acceptedAssetID)
        #expect(acceptedEntry.resourceID == acceptedResourceID)
        #expect(acceptedEntry.state == .received)
        #expect(try await environment.store.loadAssets().isEmpty)
        #expect(try Data(contentsOf: environment.resources.stagingURL(for: acceptedResourceID)) == environment
            .sourceBytes)

        fence.advance()
        await acceptanceSuspension.resume()

        await #expect(throws: CancellationError.self) {
            try await importTask.value
        }

        #expect(try await environment.store.loadAssets().isEmpty)
        #expect(try await environment.store.ingestionJournal.snapshot().entries == [acceptedEntry])
        #expect(try Data(contentsOf: environment.resources.stagingURL(for: acceptedResourceID)) == environment
            .sourceBytes)

        let freshAsset = try await importer.importFile(at: environment.sourceURL, sessionGeneration: 1)

        #expect(freshAsset.id == freshAssetID)
        #expect(try await environment.store.logicalAssetCount() == 2)
        #expect(try await Set(environment.store.loadAssets().map(\.id)) == Set([acceptedAssetID, freshAssetID]))
        #expect(try await environment.store.ingestionJournal.snapshot().entries.isEmpty)
        #expect(environment.resources.stagedResourceIDs().isEmpty)
        #expect(try Data(contentsOf: environment.resources.url(for: #require(freshAsset.resources.first))) ==
            environment.sourceBytes)
    }

    @Test("Entitlement lookup failure remains distinct from store failure")
    func entitlementFailureBlocksBeforeStaging() async throws {
        let environment = try makeEnvironment(
            entitlement: makeEntitlement { throw EntitlementError.verificationFailed },
        )
        try await seedQuotaAssets(count: MediaLibraryQuota.freeLogicalAssetLimit, into: environment.store)
        let importer = makeImporter(
            store: environment.store,
            resources: environment.resources,
            entitlement: makeEntitlement { throw EntitlementError.verificationFailed },
            source: MediaSourceClient(copyOperation: { _, _ in throw InjectedUnexpectedSourceCopy() }),
        )

        await #expect(throws: MediaImportError.entitlementUnavailable) {
            try await importer.importFile(at: environment.sourceURL)
        }

        #expect(
            !FileManager.default.fileExists(
                atPath: environment.resources.stagingURL(for: TestFixtures.resourceID).path,
            ),
        )
        #expect(try await environment.store.ingestionJournal.snapshot().entries.isEmpty)
    }

    @Test("Database count failure blocks before staging without becoming an entitlement failure")
    func databaseFailureBlocksBeforeStaging() async throws {
        let entitlementProbe = EntitlementStateProbe(state: .notEntitled)
        let entitlement = makeEntitlement { await entitlementProbe.currentState() }
        let environment = try makeEnvironment(
            entitlement: entitlement,
            logicalAssetCountOperation: {
                throw MediaLibraryStoreError.unavailable
            },
        )
        #expect(try await environment.store.loadAssets().isEmpty)
        let importer = makeImporter(
            store: environment.store,
            resources: environment.resources,
            entitlement: entitlement,
            source: MediaSourceClient(copyOperation: { _, _ in throw InjectedUnexpectedSourceCopy() }),
        )

        await #expect(throws: MediaImportError.libraryUnavailable) {
            try await importer.importFile(at: environment.sourceURL)
        }

        #expect(
            !FileManager.default.fileExists(
                atPath: environment.resources.stagingURL(for: TestFixtures.resourceID).path,
            ),
        )
        #expect(try await environment.store.ingestionJournal.snapshot().entries.isEmpty)
        #expect(await entitlementProbe.readCount() == 0)
    }

    @Test("Revocation does not block recovery of an accepted import")
    func acceptedImportRecoversAfterRevocation() async throws {
        let readFailure = FirstAcceptedResourceReadFailure()
        let entitlementProbe = EntitlementStateProbe(state: .entitled)
        let environment = try makeEnvironment(
            entitlement: makeEntitlement { await entitlementProbe.currentState() },
            resourcesFactory: { root in
                try FileMediaResourceRepository(
                    rootURL: root,
                    protectionOperation: { _ in },
                    acceptedResourceReadOperation: { try readFailure.read($0) },
                )
            },
        )
        try await seedQuotaAssets(count: MediaLibraryQuota.freeLogicalAssetLimit, into: environment.store)

        await #expect(throws: MediaImportError.persistenceFailed) {
            try await environment.importer.importFile(at: environment.sourceURL)
        }
        #expect(try await environment.store.ingestionJournal.snapshot().entries.first?.state == .validating)

        await entitlementProbe.setState(.revoked)
        try await environment.importer.reconcile()

        #expect(try await environment.store.logicalAssetCount() == MediaLibraryQuota.freeLogicalAssetLimit + 1)
        #expect(try await environment.store.ingestionJournal.snapshot().entries.isEmpty)
        #expect(await entitlementProbe.readCount() == 1)
    }

    @Test("Admission recovers accepted work before checking the Free limit")
    func admissionRecoversAcceptedWorkBeforeFreeLimitCheck() async throws {
        let entitlementProbe = EntitlementStateProbe(state: .notEntitled)
        let environment = try makeEnvironment(
            entitlement: makeEntitlement { await entitlementProbe.currentState() },
        )
        try await seedQuotaAssets(
            count: MediaLibraryQuota.freeLogicalAssetLimit - 1,
            into: environment.store,
        )
        let acceptedEntry = try await seedAcceptedImport(index: 0, in: environment)
        let sourceCopyCounter = SourceCopyCounter()
        let importer = makeImporter(
            store: environment.store,
            resources: environment.resources,
            entitlement: makeEntitlement { await entitlementProbe.currentState() },
            source: MediaSourceClient(copyOperation: { sourceURL, stagingURL in
                try sourceCopyCounter.copy(from: sourceURL, to: stagingURL)
            }),
        )

        await #expect(throws: MediaImportError.assetLimitReached) {
            try await importer.importFile(at: environment.sourceURL)
        }

        let assets = try await environment.store.loadAssets()
        #expect(assets.count == MediaLibraryQuota.freeLogicalAssetLimit)
        #expect(assets.contains { $0.id == acceptedEntry.id })
        #expect(try await environment.store.ingestionJournal.snapshot().entries.isEmpty)
        #expect(await entitlementProbe.readCount() == 1)
        #expect(sourceCopyCounter.count() == 0)
        #expect(
            !FileManager.default.fileExists(
                atPath: environment.resources.stagingURL(for: TestFixtures.resourceID).path,
            ),
        )
    }

    @Test("A failed accepted-work recovery defers Free admission before staging")
    func failedAcceptedWorkRecoveryDefersFreeAdmission() async throws {
        let readFailure = FirstAcceptedResourceReadFailure()
        let entitlementProbe = EntitlementStateProbe(state: .notEntitled)
        let environment = try makeEnvironment(
            entitlement: makeEntitlement { await entitlementProbe.currentState() },
            resourcesFactory: { root in
                try FileMediaResourceRepository(
                    rootURL: root,
                    protectionOperation: { _ in },
                    acceptedResourceReadOperation: { try readFailure.read($0) },
                )
            },
        )
        try await seedQuotaAssets(
            count: MediaLibraryQuota.freeLogicalAssetLimit - 1,
            into: environment.store,
        )
        let acceptedEntry = try await seedAcceptedImport(index: 1, in: environment)
        let validatingEntry = try await environment.store.ingestionJournal.transition(
            acceptedEntry,
            to: .validating,
        )
        let sourceCopyCounter = SourceCopyCounter()
        let importer = makeImporter(
            store: environment.store,
            resources: environment.resources,
            entitlement: makeEntitlement { await entitlementProbe.currentState() },
            source: MediaSourceClient(copyOperation: { sourceURL, stagingURL in
                try sourceCopyCounter.copy(from: sourceURL, to: stagingURL)
            }),
        )

        await #expect(throws: MediaImportError.persistenceFailed) {
            try await importer.importFile(at: environment.sourceURL)
        }

        #expect(try await environment.store.logicalAssetCount() == MediaLibraryQuota.freeLogicalAssetLimit - 1)
        #expect(try await environment.store.ingestionJournal.snapshot().entries.map(\.id) == [validatingEntry.id])
        #expect(await entitlementProbe.readCount() == 0)
        #expect(sourceCopyCounter.count() == 0)
        #expect(
            !FileManager.default.fileExists(
                atPath: environment.resources.stagingURL(for: TestFixtures.resourceID).path,
            ),
        )
    }

    @Test("51 committed assets remain visible after Pro is revoked and later imports are denied")
    func existingAssetsRemainVisibleAfterRevocation() async throws {
        let entitlementProbe = EntitlementStateProbe(state: .entitled)
        let environment = try makeEnvironment(
            entitlement: makeEntitlement { await entitlementProbe.currentState() },
        )
        try await seedQuotaAssets(count: 50, into: environment.store)

        let importedAsset = try await environment.importer.importFile(at: environment.sourceURL)
        #expect(try await environment.store.logicalAssetCount() == 51)

        await entitlementProbe.setState(.revoked)
        let visibleAssets = try await environment.importer.loadAssets()

        #expect(visibleAssets.count == 51)
        #expect(visibleAssets.contains { $0.id == importedAsset.id })
        #expect(try await environment.store.logicalAssetCount() == 51)

        let denyingImporter = makeImporter(
            store: environment.store,
            resources: environment.resources,
            entitlement: makeEntitlement { await entitlementProbe.currentState() },
            source: MediaSourceClient(copyOperation: { _, _ in throw InjectedUnexpectedSourceCopy() }),
        )
        await #expect(throws: MediaImportError.assetLimitReached) {
            try await denyingImporter.importFile(at: environment.sourceURL)
        }
        #expect(await entitlementProbe.readCount() == 2)
        #expect(try await environment.store.ingestionJournal.snapshot().entries.isEmpty)
    }

    private func expectQuotaDenial(for state: ProEntitlementState) async throws {
        let entitlementProbe = EntitlementStateProbe(state: state)
        let environment = try makeEnvironment(
            entitlement: makeEntitlement { await entitlementProbe.currentState() },
        )
        try await seedQuotaAssets(count: MediaLibraryQuota.freeLogicalAssetLimit, into: environment.store)
        let importer = makeImporter(
            store: environment.store,
            resources: environment.resources,
            entitlement: makeEntitlement { await entitlementProbe.currentState() },
            source: MediaSourceClient(copyOperation: { _, _ in throw InjectedUnexpectedSourceCopy() }),
        )

        await #expect(throws: MediaImportError.assetLimitReached) {
            try await importer.importFile(at: environment.sourceURL)
        }

        #expect(await entitlementProbe.readCount() == 1)
        #expect(
            !FileManager.default.fileExists(
                atPath: environment.resources.stagingURL(for: TestFixtures.resourceID).path,
            ),
        )
        #expect(try await environment.store.ingestionJournal.snapshot().entries.isEmpty)
    }

    private func seedAcceptedImport(
        index: Int,
        in environment: ImportEnvironment,
    ) async throws -> MediaIngestionJournalEntry {
        let entry = MediaIngestionJournalEntry(
            id: TestFixtures.recoveryAssetIDs[index],
            resourceID: TestFixtures.recoveryResourceIDs[index],
            state: .received,
            sourceFilename: "accepted-\(index).png",
            importedAt: TestFixtures.importedAt,
        )
        try TestFixtures.pngData.write(
            to: environment.resources.stagingURL(for: entry.resourceID),
        )
        try environment.resources.protectStaging(for: entry.resourceID)
        try await environment.store.ingestionJournal.accept(entry)
        return entry
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
    entitlement: EntitlementClient = .testValue,
    resourcesFactory: (URL) throws -> FileMediaResourceRepository = {
        try FileMediaResourceRepository(rootURL: $0)
    },
    logicalAssetCountOperation: (@Sendable () async throws -> Int)? = nil,
) throws -> ImportEnvironment {
    let fileManager = FileManager.default
    let root = fileManager.temporaryDirectory
        .appendingPathComponent("media-library-\(UUID().uuidString)", isDirectory: true)
    try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
    let sourceURL = root.appendingPathComponent(sourceName)
    try sourceBytes.write(to: sourceURL)
    let database = try PersistenceStore.makeInMemory()
    let mediaStore =
        if let logicalAssetCountOperation {
            SQLiteMediaLibraryStore(
                database: database,
                logicalAssetCountOverride: logicalAssetCountOperation,
            )
        } else {
            SQLiteMediaLibraryStore(database: database)
        }
    let resources = try resourcesFactory(root.appendingPathComponent("resources"))
    return ImportEnvironment(
        root: root,
        sourceURL: sourceURL,
        sourceBytes: sourceBytes,
        database: database,
        store: mediaStore,
        resources: resources,
        importer: makeImporter(store: mediaStore, resources: resources, entitlement: entitlement),
    )
}

private func persistRejectedImport(
    databaseURL: URL,
    resourceRoot: URL,
    rejectedURL: URL,
    assetID: UUID,
    resourceID: UUID,
) async throws -> MediaIngestionJournalEntry {
    let database = try PersistenceStore.makePersistent(at: databaseURL)
    let store = SQLiteMediaLibraryStore(database: database)
    let resources = try FileMediaResourceRepository(rootURL: resourceRoot)
    let importer = makeImporter(
        store: store,
        resources: resources,
        identifiers: [assetID, resourceID],
    )

    await #expect(throws: MediaImportError.unrenderableMedia) {
        try await importer.importFile(at: rejectedURL)
    }

    return try #require(await store.ingestionJournal.snapshot().entries.first)
}

private func makeImporter(
    store: SQLiteMediaLibraryStore,
    resources: FileMediaResourceRepository,
    entitlement: EntitlementClient = .testValue,
    source: MediaSourceClient = .localFile,
    identifiers: [UUID] = [TestFixtures.assetID, TestFixtures.resourceID],
    sessionIsCurrent: @escaping @Sendable (UInt64) -> Bool = { _ in true },
    sessionAdmission: @escaping @Sendable (UInt64) -> MediaLibraryImportAdmission? = { _ in nil },
) -> MediaLibraryImporter {
    let ids = IDSequence(ids: identifiers)
    return MediaLibraryImporter(
        store: store,
        resources: resources,
        source: source,
        entitlement: entitlement,
        id: { ids.next() },
        now: { TestFixtures.importedAt },
        sessionIsCurrent: sessionIsCurrent,
        sessionAdmission: sessionAdmission,
    )
}

private func makeEntitlement(
    currentState: @escaping @Sendable () async throws -> ProEntitlementState,
) -> EntitlementClient {
    EntitlementClient(
        currentState: currentState,
        purchase: { .failed(.storeFailure) },
        restore: { .failed(.storeFailure) },
    )
}

private actor JournalAcceptanceSuspension {
    private var releaseContinuation: CheckedContinuation<Void, Never>?
    private var suspensionWaiters: [CheckedContinuation<Void, Never>] = []
    private var isSuspended = false
    private var isReleased = false

    func suspend() async {
        isSuspended = true
        let waiters = suspensionWaiters
        suspensionWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }

        guard !isReleased else {
            return
        }

        await withCheckedContinuation { continuation in
            releaseContinuation = continuation
        }
    }

    func waitUntilSuspended() async {
        guard !isSuspended else {
            return
        }

        await withCheckedContinuation { continuation in
            suspensionWaiters.append(continuation)
        }
    }

    func resume() {
        isReleased = true
        guard let releaseContinuation else {
            return
        }

        self.releaseContinuation = nil
        releaseContinuation.resume()
    }
}

private actor EntitlementStateSuspension {
    private var readContinuation: CheckedContinuation<ProEntitlementState, Never>?
    private var requestContinuations: [CheckedContinuation<Void, Never>] = []
    private var requested = false
    private var resumedState: ProEntitlementState?

    func read() async -> ProEntitlementState {
        requested = true
        let waiters = requestContinuations
        requestContinuations.removeAll()
        for waiter in waiters {
            waiter.resume()
        }

        if let resumedState {
            return resumedState
        }

        return await withCheckedContinuation { continuation in
            readContinuation = continuation
        }
    }

    func waitUntilRequested() async {
        guard !requested else {
            return
        }

        await withCheckedContinuation { continuation in
            requestContinuations.append(continuation)
        }
    }

    func resume(with state: ProEntitlementState) {
        guard let readContinuation else {
            resumedState = state
            return
        }

        self.readContinuation = nil
        readContinuation.resume(returning: state)
    }
}

private func seedQuotaAssets(
    count: Int,
    into store: SQLiteMediaLibraryStore,
) async throws {
    for index in 0 ..< count {
        let assetID = requiredUUID(
            String(format: "00000000-0000-0000-0003-%012x", index + 1),
        )
        let resourceID = requiredUUID(
            String(format: "00000000-0000-0000-0004-%012x", index + 1),
        )
        try await store.commit(
            MediaAsset(
                id: assetID,
                kind: .stillImage,
                importedAt: TestFixtures.importedAt.addingTimeInterval(TimeInterval(index)),
                resources: [
                    MediaResource(
                        id: resourceID,
                        role: .original,
                        relativePath: resourceID.uuidString.lowercased(),
                        sourceFilename: "seed-\(index).png",
                        sourceUTI: "public.png",
                        byteCount: 0,
                        sha256: String(repeating: "0", count: 64),
                    ),
                ],
            ),
        )
    }
}

private actor EntitlementStateProbe {
    private var state: ProEntitlementState
    private var reads = 0

    init(state: ProEntitlementState) {
        self.state = state
    }

    func currentState() -> ProEntitlementState {
        reads += 1
        return state
    }

    func setState(_ newState: ProEntitlementState) {
        state = newState
    }

    func readCount() -> Int {
        reads
    }
}

private struct InjectedUnexpectedSourceCopy: Error {}

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

private final class SourceCopyCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var copyCount = 0

    func copy(from sourceURL: URL, to stagingURL: URL) throws {
        lock.lock()
        copyCount += 1
        lock.unlock()
        try FileManager.default.copyItem(at: sourceURL, to: stagingURL)
    }

    func count() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return copyCount
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
