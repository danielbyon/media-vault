//
//  CompletedDownloadTests.swift
//  MediaVault
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import CryptoKit
import Entitlement
import Foundation
import GRDB
import PersistenceSupport
import Synchronization
import Testing
@_spi(Testing) @testable import MediaLibrary

struct CompletedDownloadTests {
    @Test("Browser ingestion begins unauthorized and lock revokes a fresh session")
    func downloadAuthorizationRequiresAuthentication() {
        let fence = MediaLibraryResourceLoadFence()
        #expect(fence.isCurrent(0))
        #expect(!fence.isDownloadSessionCurrent(0))
        let generation = fence.beginAuthenticatedDownloadSession()
        #expect(fence.isDownloadSessionCurrent(generation))
        fence.advance()
        #expect(!fence.isDownloadSessionCurrent(generation))
        #expect(!fence.isDownloadSessionCurrent(fence.currentGeneration))
    }
}

extension CompletedDownloadTests {
    @Test("Inactive suspension survives a delayed authentication callback")
    func delayedAuthenticationCannotResumeInactiveProcessing() {
        let fence = MediaLibraryResourceLoadFence()
        let resourceGeneration = fence.currentGeneration
        fence.suspendDownloadIngestion()
        let authenticated = fence.beginAuthenticatedDownloadSession()
        #expect(!fence.isDownloadSessionCurrent(authenticated))
        let foreground = fence.setDownloadProcessingActive(true)
        #expect(fence.isDownloadSessionCurrent(foreground))
        #expect(foreground != authenticated)
        #expect(fence.currentGeneration == resourceGeneration)
        #expect(fence.setDownloadProcessingActive(true) == foreground)
    }

    @Test("Lock first denies a claim; claim first binds permission to its operation")
    func commitClaimOrderings() throws {
        let fence = MediaLibraryResourceLoadFence()
        let operationID = UUID()
        let generation = fence.beginAuthenticatedDownloadSession()
        let claim = try #require(fence.claimDownloadCommit(operationID: operationID, generation: generation))
        fence.advance()
        #expect(claim.operationID == operationID)
        #expect(fence.claimDownloadCommit(operationID: operationID, generation: generation) == nil)
        let fresh = fence.beginAuthenticatedDownloadSession()
        #expect(fence.claimDownloadCommit(operationID: UUID(), generation: generation) == nil)
        #expect(fence.isDownloadSessionCurrent(fresh))
    }

    @Test("Locked acceptance survives importer restart and legacy recovery leaves it pending")
    func acceptedBytesRequireFreshAuthenticationAfterRestart() async throws {
        let fixture = try DownloadFixture()
        defer { fixture.removeFiles() }
        let operationID = UUID()
        let source = try fixture.source(operationID: operationID, bytes: DownloadFixture.png)
        let importer = fixture.importer()
        try await importer.acceptCompletedDownload(source, operationID: operationID, originalFilename: "picture.png")
        #expect(!FileManager.default.fileExists(atPath: source.path))
        #expect(try await importer.loadAssets().isEmpty)
        try await importer.reconcile()
        #expect(try await fixture.store.loadAssets().isEmpty)
        let restarted = fixture.importer()
        #expect(await restarted.reconcileAcceptedDownloads(generation: 0).isEmpty)
        #expect(try await restarted.acceptedDownloadStorage().byteCount == Int64(DownloadFixture.png.count))
        let generation = fixture.fence.beginAuthenticatedDownloadSession()
        let outcomes = await restarted.reconcileAcceptedDownloads(generation: generation)
        #expect(outcomes[operationID] == nil)
        let asset = try #require(try await fixture.store.loadAssets().first)
        #expect(try fixture.resources.data(for: #require(asset.resources.first)) == DownloadFixture.png)
        #expect(try await restarted.acceptedDownloadStorage().byteCount == 0)
        try await restarted.discardAcceptedDownload(operationID: operationID)
        #expect(try await fixture.store.loadAssets() == [asset])
    }

    @Test("Duplicate skip persists the canonical reference before retry and releases staging")
    func duplicateRetainsCanonicalIdentity() async throws {
        let fixture = try DownloadFixture()
        defer { fixture.removeFiles() }
        let first = UUID()
        let second = UUID()
        let importer = fixture.importer()
        let generation = fixture.fence.beginAuthenticatedDownloadSession()
        try await importer.acceptCompletedDownload(
            fixture.source(operationID: first, bytes: DownloadFixture.png),
            operationID: first,
            originalFilename: "first.png",
        )
        _ = await importer.reconcileAcceptedDownloads(generation: generation)
        try await importer.acceptCompletedDownload(
            fixture.source(operationID: second, bytes: DownloadFixture.png),
            operationID: second,
            originalFilename: "renamed.png",
        )
        let outcomes = await importer.reconcileAcceptedDownloads(generation: generation)
        guard case let .imported(asset, duplicate) = outcomes[second] else {
            Issue.record("Expected duplicate skip")
            return
        }

        #expect(duplicate)
        #expect(asset.id == first)
        #expect(try await fixture.store.logicalAssetCount() == 1)
        let restarted = fixture.importer()
        #expect(await restarted.reconcileAcceptedDownloads(generation: generation).isEmpty)
        #expect(try await fixture.store.loadAssets() == [asset])
        #expect(try await fixture.store.ingestionJournal.downloadRecords().isEmpty)
        #expect(try await restarted.acceptedDownloadStorage().operationCount == 0)
    }

    @Test("Unsupported bytes remain protected temporary ownership and can be discarded")
    func unsupportedNeverEntersLibrary() async throws {
        let fixture = try DownloadFixture()
        defer { fixture.removeFiles() }
        let operationID = UUID()
        let importer = fixture.importer()
        let bytes = Data("not media".utf8)
        try await importer.acceptCompletedDownload(
            fixture.source(operationID: operationID, bytes: bytes),
            operationID: operationID,
            originalFilename: "document.txt",
        )
        let generation = fixture.fence.beginAuthenticatedDownloadSession()
        let outcomes = await importer.reconcileAcceptedDownloads(generation: generation)
        guard case let .unsupported(url) = outcomes[operationID] else {
            Issue.record("Expected protected unsupported bytes")
            return
        }

        #expect(try Data(contentsOf: url) == bytes)
        #expect(try await fixture.store.loadAssets().isEmpty)
        try await importer.discardAcceptedDownload(operationID: operationID)
        #expect(try await importer.acceptedDownloadStorage().byteCount == 0)
    }

    @Test("A terminal caller cannot transfer a symlink or another operation's source")
    func rejectsForeignPathsAndSymlinks() async throws {
        let fixture = try DownloadFixture()
        defer { fixture.removeFiles() }
        let operationID = UUID()
        let source = try fixture.source(operationID: operationID, bytes: DownloadFixture.png)
        let importer = fixture.importer()
        await #expect(throws: CompletedDownloadAcceptanceError.unsafeSource) {
            try await importer.acceptCompletedDownload(source, operationID: UUID(), originalFilename: "picture.png")
        }
        let link = source.deletingLastPathComponent().appendingPathComponent("link.png")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: source)
        await #expect(throws: CompletedDownloadAcceptanceError.unsafeSource) {
            try await importer.acceptCompletedDownload(link, operationID: operationID, originalFilename: "picture.png")
        }
        #expect(try await importer.acceptedDownloadStorage().operationCount == 0)
    }
}

private final class DownloadFixture: @unchecked Sendable {
    static let png = Data([
        137,
        80,
        78,
        71,
        13,
        10,
        26,
        10,
        0,
        0,
        0,
        13,
        73,
        72,
        68,
        82,
        0,
        0,
        0,
        1,
        0,
        0,
        0,
        1,
        8,
        4,
        0,
        0,
        0,
        181,
        28,
        12,
        2,
        0,
        0,
        0,
        11,
        73,
        68,
        65,
        84,
        120,
        218,
        99,
        100,
        248,
        15,
        0,
        1,
        5,
        1,
        1,
        39,
        24,
        227,
        102,
        0,
        0,
        0,
        0,
        73,
        69,
        78,
        68,
        174,
        66,
        96,
        130,
    ])
    let root: URL
    let store: SQLiteMediaLibraryStore
    let resources: FileMediaResourceRepository
    let fence = MediaLibraryResourceLoadFence()
    private var sourceDirectories: [URL] = []

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        resources = try FileMediaResourceRepository(
            rootURL: root,
            protectionOperation: { _ in },
            completedDownloadRootURL: root.appendingPathComponent("NativeDownloads", isDirectory: true),
        )
        store = try SQLiteMediaLibraryStore(database: PersistenceStore.makeInMemory())
    }

    func importer() -> MediaLibraryImporter {
        MediaLibraryImporter(
            store: store,
            resources: resources,
            sessionAdmission: { _ in nil },
            downloadSessionIsCurrent: { [fence] in fence.isDownloadSessionCurrent($0) },
            downloadCommitClaim: { [fence] in fence.claimDownloadCommit(operationID: $0, generation: $1) },
        )
    }

    func source(operationID: UUID, bytes: Data) throws -> URL {
        let directory = resources.completedDownloadRootURL.appendingPathComponent(operationID.uuidString)
        sourceDirectories.append(directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let source = directory.appendingPathComponent("native.bin")
        try bytes.write(to: source)
        return source
    }

    func removeFiles() {
        try? FileManager.default.removeItem(at: root)
        for directory in sourceDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
    }
}

extension CompletedDownloadTests {
    @Test("Lock before the final claim defers an actual canonical transaction")
    func lockBeforeCommitClaimDefers() async throws {
        let fixture = try DownloadFixture()
        defer { fixture.removeFiles() }
        let importer = fixture.importer()
        let barrier = DownloadCommitBarrier()
        await importer.setDownloadCommitHooksForTesting(before: { await barrier.pause() })
        let operationID = UUID()
        try await importer.acceptCompletedDownload(
            fixture.source(operationID: operationID, bytes: DownloadFixture.png),
            operationID: operationID,
            originalFilename: "picture.png",
        )
        let generation = fixture.fence.beginAuthenticatedDownloadSession()
        let task = Task { await importer.reconcileAcceptedDownloads(generation: generation) }
        await barrier.waitUntilPaused()
        fixture.fence.advance()
        _ = fixture.fence.beginAuthenticatedDownloadSession()
        await barrier.resume()
        #expect(await task.value.isEmpty)
        #expect(try await fixture.store.loadAssets().isEmpty)
        #expect(try await importer.acceptedDownloadStorage().operationCount == 1)
    }

    @Test("A claimed transaction finishes after Lock without returning stale presentation")
    func lockAfterCommitClaimAllowsOnlyClaimedTransaction() async throws {
        let fixture = try DownloadFixture()
        defer { fixture.removeFiles() }
        let importer = fixture.importer()
        let barrier = DownloadCommitBarrier()
        await importer.setDownloadCommitHooksForTesting(after: { await barrier.pause() })
        let operationID = UUID()
        try await importer.acceptCompletedDownload(
            fixture.source(operationID: operationID, bytes: DownloadFixture.png),
            operationID: operationID,
            originalFilename: "picture.png",
        )
        let generation = fixture.fence.beginAuthenticatedDownloadSession()
        let task = Task { await importer.reconcileAcceptedDownloads(generation: generation) }
        await barrier.waitUntilPaused()
        fixture.fence.advance()
        _ = fixture.fence.beginAuthenticatedDownloadSession()
        await barrier.resume()
        #expect(await task.value.isEmpty)
        #expect(try await fixture.store.logicalAssetCount() == 1)
        #expect(try await importer.acceptedDownloadStorage().operationCount == 0)
    }

    @Test("Shared acceptance enforces eight retained operations independently of browser reservations")
    func sharedOperationCapacity() async throws {
        let fixture = try DownloadFixture()
        defer { fixture.removeFiles() }
        let importer = fixture.importer()
        for _ in 0 ..< 8 {
            let id = UUID()
            try await importer.acceptCompletedDownload(
                fixture.source(operationID: id, bytes: Data([1])),
                operationID: id,
                originalFilename: "pending",
            )
        }
        let ninth = UUID()
        await #expect(throws: CompletedDownloadAcceptanceError.stagingCapacityExceeded) {
            try await importer.acceptCompletedDownload(
                fixture.source(operationID: ninth, bytes: Data([1])),
                operationID: ninth,
                originalFilename: "pending",
            )
        }
        #expect(try await importer.acceptedDownloadStorage() == AcceptedDownloadStorage(
            operationCount: 8,
            byteCount: 8,
        ))
    }

    @Test("Unsupported temporary bytes have no retention lease after importer restart")
    func unsupportedCleanupAfterRestart() async throws {
        let fixture = try DownloadFixture()
        defer { fixture.removeFiles() }
        let importer = fixture.importer()
        let id = UUID()
        try await importer.acceptCompletedDownload(
            fixture.source(operationID: id, bytes: Data([1, 2])),
            operationID: id,
            originalFilename: "document",
        )
        let generation = fixture.fence.beginAuthenticatedDownloadSession()
        _ = await importer.reconcileAcceptedDownloads(generation: generation)
        let restarted = fixture.importer()
        _ = await restarted.reconcileAcceptedDownloads(generation: generation)
        #expect(try await restarted.acceptedDownloadStorage().operationCount == 0)
        #expect(try await fixture.store.loadAssets().isEmpty)
    }
}

private actor DownloadCommitBarrier {
    private var paused = false
    private var observer: CheckedContinuation<Void, Never>?
    private var continuation: CheckedContinuation<Void, Never>?

    func pause() async {
        paused = true
        observer?.resume()
        observer = nil
        await withCheckedContinuation { continuation = $0 }
    }

    func waitUntilPaused() async {
        if !paused {
            await withCheckedContinuation { observer = $0 }
        }
    }

    func resume() {
        continuation?.resume()
        continuation = nil
    }
}

extension CompletedDownloadTests {
    @Test("Canonical and unsupported presentation URLs require a fresh processing generation")
    func presentationURLsRespectProcessingAuthorization() async throws {
        let fixture = try DownloadFixture()
        defer { fixture.removeFiles() }
        let importer = fixture.importer()
        let imageID = UUID()
        let unsupportedID = UUID()
        try await importer.acceptCompletedDownload(
            fixture.source(operationID: imageID, bytes: DownloadFixture.png),
            operationID: imageID,
            originalFilename: "picture.png",
        )
        try await importer.acceptCompletedDownload(
            fixture.source(operationID: unsupportedID, bytes: Data([1])),
            operationID: unsupportedID,
            originalFilename: "document.pdf",
        )
        #expect(try await importer.completedDownloadPresentationURL(operationID: imageID, generation: 0) == nil)
        let generation = fixture.fence.beginAuthenticatedDownloadSession()
        #expect(try await importer
            .completedDownloadPresentationURL(operationID: imageID, generation: generation) == nil)
        _ = await importer.reconcileAcceptedDownloads(generation: generation)
        let imageURL = try #require(try await importer.completedDownloadPresentationURL(
            operationID: imageID,
            generation: generation,
        ))
        let unsupportedURL = try #require(try await importer.completedDownloadPresentationURL(
            operationID: unsupportedID,
            generation: generation,
        ))
        #expect(try Data(contentsOf: imageURL) == DownloadFixture.png)
        #expect(unsupportedURL == fixture.resources.stagingURL(for: unsupportedID))
        fixture.fence.suspendDownloadIngestion()
        #expect(try await importer
            .completedDownloadPresentationURL(operationID: imageID, generation: generation) == nil)
        let fresh = fixture.fence.setDownloadProcessingActive(true)
        #expect(try await importer
            .completedDownloadPresentationURL(operationID: imageID, generation: fresh) == imageURL)
        try await importer.discardAcceptedDownload(operationID: unsupportedID)
        #expect(try await importer
            .completedDownloadPresentationURL(operationID: unsupportedID, generation: fresh) == nil)
        let restarted = fixture.importer()
        #expect(try await restarted
            .completedDownloadPresentationURL(operationID: unsupportedID, generation: fresh) == nil)
    }
}

extension CompletedDownloadTests {
    @Test("Storage limits admit exact boundaries and reject one byte above or below")
    func storageAdmissionBoundaries() async throws {
        #expect(AcceptedDownloadLimits.production.itemBytes == 536_870_912)
        #expect(AcceptedDownloadLimits.production.aggregateBytes == 2_147_483_648)
        #expect(AcceptedDownloadLimits.production.freeBytes == 536_870_912)
        let fixture = try DownloadFixture()
        defer { fixture.removeFiles() }
        let importer = fixture.importer()
        let limits = AcceptedDownloadLimits(itemBytes: 4, aggregateBytes: 8, freeBytes: 2)
        await importer.setDownloadStorageForTesting(limits: limits, availableBytes: { 2 })
        for _ in 0 ..< 2 {
            let id = UUID()
            try await importer.acceptCompletedDownload(
                fixture.source(operationID: id, bytes: Data(repeating: 1, count: 4)),
                operationID: id,
                originalFilename: "boundary",
            )
        }
        #expect(try await importer.acceptedDownloadStorage().byteCount == 8)
        let overflow = UUID()
        await #expect(throws: CompletedDownloadAcceptanceError.stagingCapacityExceeded) {
            try await importer.acceptCompletedDownload(
                fixture.source(operationID: overflow, bytes: Data([1])),
                operationID: overflow,
                originalFilename: "overflow",
            )
        }
        let oversized = UUID()
        await #expect(throws: CompletedDownloadAcceptanceError.itemTooLarge) {
            try await importer.acceptCompletedDownload(
                fixture.source(operationID: oversized, bytes: Data(repeating: 1, count: 5)),
                operationID: oversized,
                originalFilename: "oversized",
            )
        }
        await importer.setDownloadStorageForTesting(
            limits: AcceptedDownloadLimits(itemBytes: 4, aggregateBytes: 16, freeBytes: 2),
            availableBytes: { 1 },
        )
        let lowSpace = UUID()
        await #expect(throws: CompletedDownloadAcceptanceError.insufficientStorage) {
            try await importer.acceptCompletedDownload(
                fixture.source(operationID: lowSpace, bytes: Data([1])),
                operationID: lowSpace,
                originalFilename: "low-space",
            )
        }
        #expect(try await importer.acceptedDownloadStorage().byteCount == 8)
    }

    @Test("Duplicate cleanup failures retain capacity and retry without another canonical asset")
    func duplicateCleanupFailureRetries() async throws {
        let fixture = try DownloadFixture()
        defer { fixture.removeFiles() }
        let importer = fixture.importer()
        let generation = fixture.fence.beginAuthenticatedDownloadSession()
        let first = UUID()
        try await importer.acceptCompletedDownload(
            fixture.source(operationID: first, bytes: DownloadFixture.png),
            operationID: first,
            originalFilename: "first.png",
        )
        _ = await importer.reconcileAcceptedDownloads(generation: generation)
        let duplicate = UUID()
        try await importer.acceptCompletedDownload(
            fixture.source(operationID: duplicate, bytes: DownloadFixture.png),
            operationID: duplicate,
            originalFilename: "duplicate.png",
        )
        await importer.setDownloadHandoffHooksForTesting(beforeCleanup: { throw DownloadTestFailure.interrupted })
        let outcomes = await importer.reconcileAcceptedDownloads(generation: generation)
        guard case let .imported(asset, skipped) = outcomes[duplicate] else {
            Issue.record("Expected persisted duplicate despite cleanup failure")
            return
        }

        #expect(skipped)
        #expect(asset.id == first)
        #expect(try await importer.acceptedDownloadStorage().byteCount == Int64(DownloadFixture.png.count))
        #expect(try await fixture.store.logicalAssetCount() == 1)
        await importer.setDownloadHandoffHooksForTesting()
        _ = await importer.reconcileAcceptedDownloads(generation: generation)
        #expect(try await importer.acceptedDownloadStorage().byteCount == 0)
        #expect(try await fixture.store.logicalAssetCount() == 1)
    }
}

private enum DownloadTestFailure: Error {
    case interrupted
}

extension CompletedDownloadTests {
    @Test("Accepted media reopens from a closed SQLite connection and starts unauthorized")
    func acceptedBytesSurviveSQLiteCloseAndReopen() async throws {
        let fixture = try DownloadFixture()
        defer { fixture.removeFiles() }
        let first = try DiskDownloadSession(root: fixture.root, resources: fixture.resources)
        let operationID = UUID()
        try await first.importer.acceptCompletedDownload(
            fixture.source(operationID: operationID, bytes: DownloadFixture.png),
            operationID: operationID,
            originalFilename: "picture.png",
        )
        try first.database.close()
        let reopened = try DiskDownloadSession(root: fixture.root, resources: fixture.resources)
        defer { try? reopened.database.close() }
        #expect(await reopened.importer.reconcileAcceptedDownloads(generation: 0).isEmpty)
        #expect(try await reopened.importer.loadAssets().isEmpty)
        let generation = reopened.fence.beginAuthenticatedDownloadSession()
        let outcomes = await reopened.importer.reconcileAcceptedDownloads(generation: generation)
        #expect(outcomes.isEmpty)
        let asset = try #require(try await reopened.store.loadAssets().first)
        #expect(asset.id == operationID)
        #expect(try await reopened.store.ingestionJournal.downloadRecords().isEmpty)
        #expect(try fixture.resources.data(for: #require(asset.resources.first)) == DownloadFixture.png)
        #expect(try await reopened.importer.acceptedDownloadStorage().byteCount == 0)
    }

    @Test("An interrupted handoff reopens from either side of its exclusive rename", arguments: [false, true])
    func interruptedHandoffReopens(afterRename: Bool) async throws {
        let fixture = try DownloadFixture()
        defer { fixture.removeFiles() }
        let first = try DiskDownloadSession(root: fixture.root, resources: fixture.resources)
        let operationID = UUID()
        let source = try fixture.source(operationID: operationID, bytes: DownloadFixture.png)
        if afterRename {
            await first.importer
                .setDownloadHandoffHooksForTesting(afterRename: { throw DownloadTestFailure.interrupted })
        } else {
            await first.importer
                .setDownloadHandoffHooksForTesting(afterIntent: { throw DownloadTestFailure.interrupted })
        }
        await #expect(throws: CompletedDownloadAcceptanceError.ownershipUncertain) {
            try await first.importer.acceptCompletedDownload(
                source,
                operationID: operationID,
                originalFilename: "picture.png",
            )
        }
        #expect(FileManager.default.fileExists(atPath: source.path) == !afterRename)
        #expect(FileManager.default
            .fileExists(atPath: fixture.resources.stagingURL(for: operationID).path) == afterRename)
        try first.database.close()
        let reopened = try DiskDownloadSession(root: fixture.root, resources: fixture.resources)
        defer { try? reopened.database.close() }
        // Startup ownership recovery must finish before the native owner purges scratch.
        #expect(try await reopened.importer.acceptedDownloadStorage().operationCount == 1)
        #expect(!FileManager.default.fileExists(atPath: source.path))
        #expect(try await reopened.store.loadAssets().isEmpty)
        let generation = reopened.fence.beginAuthenticatedDownloadSession()
        let outcomes = await reopened.importer.reconcileAcceptedDownloads(generation: generation)
        #expect(outcomes.isEmpty)
        let asset = try #require(try await reopened.store.loadAssets().first)
        #expect(asset.id == operationID)
        #expect(try await reopened.store.logicalAssetCount() == 1)
        #expect(!FileManager.default.fileExists(atPath: source.path))
        #expect(try await reopened.importer.acceptedDownloadStorage().byteCount == 0)
    }

    @Test("A duplicate at quota reuses its canonical asset without an entitlement lookup")
    func duplicateBeforeQuotaAfterSQLiteReopen() async throws {
        let fixture = try DownloadFixture()
        defer { fixture.removeFiles() }
        let first = try DiskDownloadSession(root: fixture.root, resources: fixture.resources)
        let originalID = UUID()
        try await first.importer.acceptCompletedDownload(
            fixture.source(operationID: originalID, bytes: DownloadFixture.png),
            operationID: originalID,
            originalFilename: "first.png",
        )
        _ = await first.importer.reconcileAcceptedDownloads(generation: first.fence.beginAuthenticatedDownloadSession())
        try first.database.close()
        let full = try DiskDownloadSession(root: fixture.root, resources: fixture.resources, logicalCount: 50)
        defer { try? full.database.close() }
        let duplicateID = UUID()
        try await full.importer.acceptCompletedDownload(
            fixture.source(operationID: duplicateID, bytes: DownloadFixture.png),
            operationID: duplicateID,
            originalFilename: "renamed.png",
        )
        let outcomes = await full.importer
            .reconcileAcceptedDownloads(generation: full.fence.beginAuthenticatedDownloadSession())
        guard case let .imported(asset, duplicate) = outcomes[duplicateID] else {
            Issue.record("Expected duplicate skip before quota/entitlement admission")
            return
        }

        #expect(duplicate)
        #expect(asset.id == originalID)
        #expect(try await full.store.loadAssets().count == 1)
        #expect(try await full.importer.acceptedDownloadStorage().byteCount == 0)
    }
}

private struct DiskDownloadSession {
    let database: any DatabaseWriter
    let store: SQLiteMediaLibraryStore
    let fence: MediaLibraryResourceLoadFence
    let importer: MediaLibraryImporter

    init(root: URL, resources: FileMediaResourceRepository, logicalCount: Int? = nil) throws {
        let libraryDatabase = try PersistenceStore.makePersistent(at: root.appendingPathComponent("library.sqlite"))
        database = libraryDatabase
        let libraryStore =
            if let logicalCount {
                SQLiteMediaLibraryStore(database: libraryDatabase, logicalAssetCountOverride: { logicalCount })
            } else {
                SQLiteMediaLibraryStore(database: libraryDatabase)
            }
        store = libraryStore
        let sessionFence = MediaLibraryResourceLoadFence()
        fence = sessionFence
        var entitlement = EntitlementClient.testValue
        entitlement.currentState = { throw DownloadTestFailure.interrupted }
        importer = MediaLibraryImporter(
            store: libraryStore,
            resources: resources,
            entitlement: entitlement,
            sessionAdmission: { _ in nil },
            downloadSessionIsCurrent: { sessionFence.isDownloadSessionCurrent($0) },
            downloadCommitClaim: { sessionFence.claimDownloadCommit(operationID: $0, generation: $1) },
        )
    }
}

extension CompletedDownloadTests {
    @Test("A queued presentation resolution returns no URL after Lock wins its store gate")
    func presentationQueuedAcrossLockReturnsNil() async throws {
        let fixture = try DownloadFixture()
        defer { fixture.removeFiles() }
        let importer = fixture.importer()
        let barrier = DownloadCommitBarrier()
        await importer.setDownloadCommitHooksForTesting(after: { await barrier.pause() })
        let operationID = UUID()
        try await importer.acceptCompletedDownload(
            fixture.source(operationID: operationID, bytes: DownloadFixture.png),
            operationID: operationID,
            originalFilename: "picture.png",
        )
        let generation = fixture.fence.beginAuthenticatedDownloadSession()
        let reconciliation = Task { await importer.reconcileAcceptedDownloads(generation: generation) }
        await barrier.waitUntilPaused()
        let presentation = Task {
            try await importer.completedDownloadPresentationURL(operationID: operationID, generation: generation)
        }
        await fixture.store.waitForDurableOperationWaiterForTesting()
        fixture.fence.advance()
        await barrier.resume()
        _ = await reconciliation.value
        #expect(try await presentation.value == nil)
    }

    @Test("Canonical presentation rejects changed bytes even when the file size is unchanged")
    func presentationVerifiesCanonicalDigest() async throws {
        let fixture = try DownloadFixture()
        defer { fixture.removeFiles() }
        let importer = fixture.importer()
        let operationID = UUID()
        try await importer.acceptCompletedDownload(
            fixture.source(operationID: operationID, bytes: DownloadFixture.png),
            operationID: operationID,
            originalFilename: "picture.png",
        )
        let generation = fixture.fence.beginAuthenticatedDownloadSession()
        _ = await importer.reconcileAcceptedDownloads(generation: generation)
        let url = try #require(try await importer.completedDownloadPresentationURL(
            operationID: operationID,
            generation: generation,
        ))
        try Data(repeating: 0, count: DownloadFixture.png.count).write(to: url)
        await #expect(throws: MediaLibraryStoreError.corrupt) {
            try await importer.completedDownloadPresentationURL(operationID: operationID, generation: generation)
        }
    }
}

extension CompletedDownloadTests {
    @Test("Missing bytes after handoff intent stay unresolved across SQLite reopen")
    func interruptedIntentWithMissingBytesRemainsVisibleFailure() async throws {
        let fixture = try DownloadFixture()
        defer { fixture.removeFiles() }
        let first = try DiskDownloadSession(root: fixture.root, resources: fixture.resources)
        let operationID = UUID()
        let source = try fixture.source(operationID: operationID, bytes: DownloadFixture.png)
        await first.importer.setDownloadHandoffHooksForTesting(afterIntent: { throw DownloadTestFailure.interrupted })
        await #expect(throws: CompletedDownloadAcceptanceError.ownershipUncertain) {
            try await first.importer.acceptCompletedDownload(
                source,
                operationID: operationID,
                originalFilename: "picture.png",
            )
        }
        try FileManager.default.removeItem(at: source)
        try first.database.close()
        let reopened = try DiskDownloadSession(root: fixture.root, resources: fixture.resources)
        defer { try? reopened.database.close() }
        let outcomes = await reopened.importer
            .reconcileAcceptedDownloads(generation: reopened.fence.beginAuthenticatedDownloadSession())
        #expect(outcomes[operationID] == .failed(.persistenceFailed))
        await #expect(throws: CompletedDownloadAcceptanceError.unsafeSource) {
            try await reopened.importer.acceptedDownloadStorage()
        }
        #expect(try await reopened.store.ingestionJournal.downloadRecords().count == 1)
        #expect(try await reopened.store.loadAssets().isEmpty)
    }
}

extension CompletedDownloadTests {
    @Test("A fresh SQLite session removes terminal download history after canonical verification")
    func terminalDownloadHistoryDoesNotSurviveFreshSessionReconciliation() async throws {
        let fixture = try DownloadFixture()
        defer { fixture.removeFiles() }
        let first = try DiskDownloadSession(root: fixture.root, resources: fixture.resources)
        let original = UUID()
        let duplicate = UUID()
        let generation = first.fence.beginAuthenticatedDownloadSession()
        for id in [original, duplicate] {
            try await first.importer.acceptCompletedDownload(
                fixture.source(operationID: id, bytes: DownloadFixture.png),
                operationID: id,
                originalFilename: "private-name.png",
            )
            _ = await first.importer.reconcileAcceptedDownloads(generation: generation)
        }
        #expect(try await first.store.ingestionJournal.downloadRecords().count == 2)
        try first.database.close()
        let fresh = try DiskDownloadSession(root: fixture.root, resources: fixture.resources)
        defer { try? fresh.database.close() }
        let freshGeneration = fresh.fence.beginAuthenticatedDownloadSession()
        #expect(await fresh.importer.reconcileAcceptedDownloads(generation: freshGeneration).isEmpty)
        #expect(try await fresh.store.ingestionJournal.downloadRecords().isEmpty)
        #expect(try await fresh.store.loadAssets().map(\.id) == [original])
        #expect(try await fresh.importer.completedDownloadPresentationURL(
            operationID: original,
            generation: freshGeneration,
        ) == nil)
        #expect(try await fresh.importer.completedDownloadPresentationURL(
            operationID: duplicate,
            generation: freshGeneration,
        ) == nil)
    }

    @Test("Terminal metadata is retained when canonical verification fails after reopen")
    func corruptCanonicalPreventsTerminalCompaction() async throws {
        let fixture = try DownloadFixture()
        defer { fixture.removeFiles() }
        let first = try DiskDownloadSession(root: fixture.root, resources: fixture.resources)
        let operationID = UUID()
        try await first.importer.acceptCompletedDownload(
            fixture.source(operationID: operationID, bytes: DownloadFixture.png),
            operationID: operationID,
            originalFilename: "picture.png",
        )
        let generation = first.fence.beginAuthenticatedDownloadSession()
        _ = await first.importer.reconcileAcceptedDownloads(generation: generation)
        let url = try #require(try await first.importer.completedDownloadPresentationURL(
            operationID: operationID,
            generation: generation,
        ))
        try Data(repeating: 0, count: DownloadFixture.png.count).write(to: url)
        try first.database.close()
        let fresh = try DiskDownloadSession(root: fixture.root, resources: fixture.resources)
        defer { try? fresh.database.close() }
        let outcomes = await fresh.importer
            .reconcileAcceptedDownloads(generation: fresh.fence.beginAuthenticatedDownloadSession())
        #expect(outcomes[operationID] == .failed(.persistenceFailed))
        #expect(try await fresh.store.ingestionJournal.downloadRecords().count == 1)
    }
}

extension CompletedDownloadTests {
    @Test("Legacy accepted bytes consume shared staging budget without being validated or discarded")
    func legacyAcceptedBytesAreGrandfatheredIntoSharedBudget() async throws {
        let fixture = try DownloadFixture()
        defer { fixture.removeFiles() }
        let legacyID = UUID()
        let resourceID = UUID()
        let bytes = Data(repeating: 7, count: 9)
        let stage = fixture.resources.stagingURL(for: resourceID)
        try bytes.write(to: stage)
        try await fixture.store.ingestionJournal.accept(MediaIngestionJournalEntry(
            id: legacyID,
            resourceID: resourceID,
            state: .received,
            sourceFilename: "legacy.png",
            importedAt: Date(timeIntervalSince1970: 0),
        ))
        let importer = fixture.importer()
        await importer.setDownloadStorageForTesting(
            limits: AcceptedDownloadLimits(itemBytes: 16, aggregateBytes: 8, freeBytes: 0),
            availableBytes: { 100 },
        )
        #expect(try await importer.acceptedDownloadStorage() == AcceptedDownloadStorage(
            operationCount: 1,
            byteCount: 9,
        ))
        let browserID = UUID()
        await #expect(throws: CompletedDownloadAcceptanceError.stagingCapacityExceeded) {
            try await importer.acceptCompletedDownload(
                fixture.source(operationID: browserID, bytes: Data([1])),
                operationID: browserID,
                originalFilename: "new.png",
            )
        }
        #expect(try Data(contentsOf: stage) == bytes)
        #expect(try await fixture.store.ingestionJournal.snapshot().entries.first?.state == .received)
        #expect(try await fixture.store.loadAssets().isEmpty)
    }

    @Test("Legacy excess operations are grandfathered while new browser acceptance is rejected")
    func legacyOperationsConsumeSharedOperationCapacity() async throws {
        let fixture = try DownloadFixture()
        defer { fixture.removeFiles() }
        for index in 0 ..< 9 {
            let resourceID = UUID()
            try Data([UInt8(index)]).write(to: fixture.resources.stagingURL(for: resourceID))
            try await fixture.store.ingestionJournal.accept(MediaIngestionJournalEntry(
                id: UUID(),
                resourceID: resourceID,
                state: .received,
                sourceFilename: "legacy.png",
                importedAt: Date(timeIntervalSince1970: Double(index)),
            ))
        }
        let importer = fixture.importer()
        #expect(try await importer.acceptedDownloadStorage() == AcceptedDownloadStorage(
            operationCount: 9,
            byteCount: 9,
        ))
        let browserID = UUID()
        await #expect(throws: CompletedDownloadAcceptanceError.stagingCapacityExceeded) {
            try await importer.acceptCompletedDownload(
                fixture.source(operationID: browserID, bytes: Data([1])),
                operationID: browserID,
                originalFilename: "new.png",
            )
        }
        #expect(try await fixture.store.ingestionJournal.snapshot().entries.count == 9)
        #expect(try await importer.acceptedDownloadStorage().operationCount == 9)
    }

    @Test("Orphans and promoted uncommitted resources count once per file and operation")
    func sharedInventoryIncludesOrphansAndPromotedResources() async throws {
        let fixture = try DownloadFixture()
        defer { fixture.removeFiles() }
        let resourceID = UUID()
        try Data([1, 2]).write(to: fixture.resources.stagingURL(for: resourceID))
        try Data([3, 4, 5])
            .write(to: fixture.resources.rootURL.appendingPathComponent(resourceID.uuidString.lowercased()))
        let orphan = fixture.resources
            .stagingURL(for: UUID())
            .deletingLastPathComponent()
            .appendingPathComponent("orphan.tmp")
        try Data([6]).write(to: orphan)
        try await fixture.store.ingestionJournal.accept(MediaIngestionJournalEntry(
            id: UUID(),
            resourceID: resourceID,
            state: .received,
            sourceFilename: "legacy.png",
            importedAt: Date(timeIntervalSince1970: 0),
        ))
        let importer = fixture.importer()
        #expect(try await importer.acceptedDownloadStorage() == AcceptedDownloadStorage(
            operationCount: 2,
            byteCount: 6,
        ))
        #expect(try Data(contentsOf: orphan) == Data([6]))
        #expect(try await fixture.store.ingestionJournal.snapshot().entries.first?.state == .received)
    }
}

extension CompletedDownloadTests {
    @Test("Canonical final bytes are excluded while their retained staging copy still counts")
    func canonicalExclusionDoesNotHideTemporaryCopies() async throws {
        let fixture = try DownloadFixture()
        defer { fixture.removeFiles() }
        let resourceID = UUID()
        let stage = fixture.resources.stagingURL(for: resourceID)
        try Data([1, 2]).write(to: stage)
        try Data([3, 4, 5])
            .write(to: fixture.resources.rootURL.appendingPathComponent(resourceID.uuidString.lowercased()))
        let importer = fixture.importer()
        #expect(try await importer.acceptedDownloadStorage() == AcceptedDownloadStorage(
            operationCount: 1,
            byteCount: 5,
        ))
        try await fixture.store.commit(MediaAsset(
            id: UUID(),
            kind: .stillImage,
            importedAt: Date(timeIntervalSince1970: 0),
            resources: [MediaResource(
                id: resourceID,
                role: .original,
                relativePath: resourceID.uuidString.lowercased(),
                sourceFilename: "canonical.png",
                sourceUTI: "public.png",
                byteCount: 3,
                sha256: String(repeating: "a", count: 64),
            )],
        ))
        #expect(try await importer.acceptedDownloadStorage() == AcceptedDownloadStorage(
            operationCount: 1,
            byteCount: 2,
        ))
        #expect(try Data(contentsOf: stage) == Data([1, 2]))
    }
}

extension CompletedDownloadTests {
    @Test("A Library refresh drains quota-deferred downloads after Pro changes in the same session")
    func libraryRefreshReconcilesAfterEntitlementResolution() async throws {
        let fixture = try DownloadFixture()
        defer { fixture.removeFiles() }
        let entitlementState = Mutex<ProEntitlementState>(.notEntitled)
        var entitlement = EntitlementClient.testValue
        entitlement.currentState = { entitlementState.withLock { $0 } }
        let quotaStore = try SQLiteMediaLibraryStore(
            database: PersistenceStore.makeInMemory(),
            logicalAssetCountOverride: { 50 },
        )
        let fence = fixture.fence
        let importer = MediaLibraryImporter(
            store: quotaStore,
            resources: fixture.resources,
            entitlement: entitlement,
            sessionAdmission: { _ in nil },
            downloadSessionIsCurrent: { fence.isDownloadSessionCurrent($0) },
            downloadCommitClaim: { fence.claimDownloadCommit(operationID: $0, generation: $1) },
        )
        let client = MediaLibraryClient.connected(
            importer: importer,
            resources: fixture.resources,
            resourceLoadFence: fence,
        )
        let generation = client.beginAuthenticatedDownloadSession()
        let operationID = UUID()
        try await client.acceptCompletedDownload(
            fixture.source(operationID: operationID, bytes: DownloadFixture.png),
            operationID: operationID,
            originalFilename: "picture.png",
        )
        #expect(try await client.loadAssets().isEmpty)
        #expect(try await client.acceptedDownloadStorage().operationCount == 1)
        entitlementState.withLock { $0 = .entitled }
        let assets = try await client.loadAssets()
        #expect(assets.map(\.id) == [operationID])
        #expect(client.currentDownloadIngestionGeneration == generation)
        #expect(try await client.acceptedDownloadStorage().operationCount == 0)
    }
}

extension CompletedDownloadTests {
    @Test("Discard during entitlement lookup invalidates the operation before its commit claim")
    func discardBeforeClaimPreventsCanonicalCommit() async throws {
        let fixture = try DownloadFixture()
        defer { fixture.removeFiles() }
        let barrier = DownloadCommitBarrier()
        var entitlement = EntitlementClient.testValue
        entitlement.currentState = {
            await barrier.pause()
            return .entitled
        }
        let quotaStore = try SQLiteMediaLibraryStore(
            database: PersistenceStore.makeInMemory(),
            logicalAssetCountOverride: { 50 },
        )
        let fence = fixture.fence
        let importer = MediaLibraryImporter(
            store: quotaStore,
            resources: fixture.resources,
            entitlement: entitlement,
            sessionAdmission: { _ in nil },
            downloadSessionIsCurrent: { fence.isDownloadSessionCurrent($0) },
            downloadCommitClaim: { fence.claimDownloadCommit(operationID: $0, generation: $1) },
            downloadDiscardRequest: { fence.invalidateDownload($0) },
        )
        let client = MediaLibraryClient.connected(
            importer: importer,
            resources: fixture.resources,
            resourceLoadFence: fence,
        )
        let operationID = UUID()
        let generation = client.beginAuthenticatedDownloadSession()
        try await client.acceptCompletedDownload(
            fixture.source(operationID: operationID, bytes: DownloadFixture.png),
            operationID: operationID,
            originalFilename: "picture.png",
        )
        let reconciliation = Task { await client.reconcileAcceptedDownloads(generation: generation) }
        await barrier.waitUntilPaused()
        client.revokeAcceptedDownload(operationID: operationID)
        let discard = Task { try await client.discardAcceptedDownload(operationID: operationID) }
        await quotaStore.waitForDurableOperationWaiterForTesting()
        await barrier.resume()
        _ = await reconciliation.value
        try await discard.value
        #expect(try await quotaStore.loadAssets().isEmpty)
        #expect(try await client.acceptedDownloadStorage().operationCount == 0)
        #expect(fence.isDownloadSessionCurrent(generation))
        #expect(fence.claimDownloadCommit(operationID: UUID(), generation: generation) != nil)
    }

    @Test("Discard after a commit claim preserves the canonical asset and authenticated read access")
    func discardAfterClaimPreservesCanonicalAsset() async throws {
        let fixture = try DownloadFixture()
        defer { fixture.removeFiles() }
        let importer = fixture.importer()
        let client = MediaLibraryClient.connected(
            importer: importer,
            resources: fixture.resources,
            resourceLoadFence: fixture.fence,
        )
        let barrier = DownloadCommitBarrier()
        await importer.setDownloadCommitHooksForTesting(after: { await barrier.pause() })
        let operationID = UUID()
        let generation = client.beginAuthenticatedDownloadSession()
        try await client.acceptCompletedDownload(
            fixture.source(operationID: operationID, bytes: DownloadFixture.png),
            operationID: operationID,
            originalFilename: "picture.png",
        )
        let reconciliation = Task { await client.reconcileAcceptedDownloads(generation: generation) }
        await barrier.waitUntilPaused()
        let discard = Task { try await client.discardAcceptedDownload(operationID: operationID) }
        await fixture.store.waitForDurableOperationWaiterForTesting()
        await barrier.resume()
        _ = await reconciliation.value
        try await discard.value
        #expect(try await fixture.store.loadAssets().map(\.id) == [operationID])
        #expect(try await client.acceptedDownloadStorage().operationCount == 0)
        let canonicalURL = try #require(try await client.completedDownloadPresentationURL(
            operationID: operationID,
            generation: generation,
        ))
        #expect(try Data(contentsOf: canonicalURL) == DownloadFixture.png)
    }
}

extension CompletedDownloadTests {
    @Test("Interrupted explicit discard reopens as cleanup ownership and never imports")
    func interruptedDiscardReopensForCleanup() async throws {
        let fixture = try DownloadFixture()
        defer { fixture.removeFiles() }
        let first = try DiskDownloadSession(root: fixture.root, resources: fixture.resources)
        let operationID = UUID()
        try await first.importer.acceptCompletedDownload(
            fixture.source(operationID: operationID, bytes: DownloadFixture.png),
            operationID: operationID,
            originalFilename: "picture.png",
        )
        await first.importer.setDownloadHandoffHooksForTesting(beforeCleanup: { throw DownloadTestFailure.interrupted })
        await #expect(throws: DownloadTestFailure.self) {
            try await first.importer.discardAcceptedDownload(operationID: operationID)
        }
        try first.database.close()
        let fresh = try DiskDownloadSession(root: fixture.root, resources: fixture.resources)
        defer { try? fresh.database.close() }
        #expect(try await fresh.importer.acceptedDownloadStorage().operationCount == 1)
        _ = await fresh.importer.reconcileAcceptedDownloads(generation: fresh.fence.beginAuthenticatedDownloadSession())
        #expect(try await fresh.importer.acceptedDownloadStorage().operationCount == 0)
        #expect(try await fresh.store.loadAssets().isEmpty)
        #expect(try await fresh.store.ingestionJournal.downloadRecords().isEmpty)
    }
}

extension CompletedDownloadTests {
    @Test("Authentication changes never clear an operation-specific discard revocation")
    func discardRevocationSurvivesReauthentication() {
        let fence = MediaLibraryResourceLoadFence()
        let operationID = UUID()
        fence.invalidateDownload(operationID)
        let first = fence.beginAuthenticatedDownloadSession()
        #expect(fence.claimDownloadCommit(operationID: operationID, generation: first) == nil)
        fence.advance()
        let fresh = fence.beginAuthenticatedDownloadSession()
        #expect(fence.claimDownloadCommit(operationID: operationID, generation: fresh) == nil)
        #expect(fence.claimDownloadCommit(operationID: UUID(), generation: fresh) != nil)
    }
}

extension CompletedDownloadTests {
    @Test("The live client rejects an empty completion definitively without taking ownership")
    func emptyCompletionIsDefiniteRejectionAtLiveBoundary() async throws {
        let fixture = try DownloadFixture()
        defer { fixture.removeFiles() }
        let client = try MediaLibraryClient.live(at: fixture.root.appendingPathComponent("LiveLibrary"))
        let operationID = UUID()
        let sourceDirectory = FileManager.default
            .temporaryDirectory
            .appendingPathComponent("BrowserDownloads", isDirectory: true)
            .appendingPathComponent(operationID.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sourceDirectory) }
        let source = sourceDirectory.appendingPathComponent("empty.bin")
        try Data().write(to: source)
        await #expect(throws: CompletedDownloadAcceptanceError.emptyFile) {
            try await client.acceptCompletedDownload(source, operationID: operationID, originalFilename: "empty.bin")
        }
        #expect(CompletedDownloadAcceptanceError.emptyFile.isDefiniteRejection)
        #expect(try await client.acceptedDownloadStorage() == AcceptedDownloadStorage(operationCount: 0, byteCount: 0))
        #expect(FileManager.default.fileExists(atPath: source.path))
    }

    @Test("The same unsafe-source error after intent is ownership-uncertain and preserves bytes")
    func postIntentFailureNeverMasqueradesAsDefiniteRejection() async throws {
        let fixture = try DownloadFixture()
        defer { fixture.removeFiles() }
        let importer = fixture.importer()
        let client = MediaLibraryClient.connected(
            importer: importer,
            resources: fixture.resources,
            resourceLoadFence: fixture.fence,
        )
        let operationID = UUID()
        let source = try fixture.source(operationID: operationID, bytes: DownloadFixture.png)
        await importer
            .setDownloadHandoffHooksForTesting(afterIntent: { throw CompletedDownloadAcceptanceError.unsafeSource })
        await #expect(throws: CompletedDownloadAcceptanceError.ownershipUncertain) {
            try await client.acceptCompletedDownload(source, operationID: operationID, originalFilename: "picture.png")
        }
        #expect(!CompletedDownloadAcceptanceError.ownershipUncertain.isDefiniteRejection)
        #expect(FileManager.default.fileExists(atPath: source.path))
        #expect(try await client.acceptedDownloadStorage().operationCount == 1)
        #expect(try Data(contentsOf: fixture.resources.stagingURL(for: operationID)) == DownloadFixture.png)
        #expect(try await fixture.store.loadAssets().isEmpty)
    }
}

extension CompletedDownloadTests {
    @Test(
        "Admitted legacy work reserves the last free slot while browser duplicates still skip",
        arguments: [false, true],
    )
    func browserAdmissionPreservesLegacyPendingSlot(duplicate: Bool) async throws {
        let fixture = try DownloadFixture()
        defer { fixture.removeFiles() }
        var canonicalAssets: [MediaAsset] = []
        for index in 0 ..< 49 {
            let resourceID = UUID()
            let bytes = DownloadFixture.png + Data([UInt8(index)])
            let stage = fixture.resources.stagingURL(for: resourceID)
            try bytes.write(to: stage)
            try fixture.resources.protectStaging(for: resourceID)
            let path = try fixture.resources.finalize(stagingURL: stage, resourceID: resourceID)
            let asset = MediaAsset(
                id: UUID(),
                kind: .stillImage,
                importedAt: Date(timeIntervalSince1970: Double(index)),
                resources: [MediaResource(
                    id: resourceID,
                    role: .original,
                    relativePath: path,
                    sourceFilename: "canonical.png",
                    sourceUTI: "public.png",
                    byteCount: Int64(bytes.count),
                    sha256: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined(),
                )],
            )
            try await fixture.store.commit(asset)
            canonicalAssets.append(asset)
        }
        let legacyID = UUID()
        let legacyResourceID = UUID()
        try DownloadFixture.png.write(to: fixture.resources.stagingURL(for: legacyResourceID))
        try fixture.resources.protectStaging(for: legacyResourceID)
        try await fixture.store.ingestionJournal.accept(MediaIngestionJournalEntry(
            id: legacyID,
            resourceID: legacyResourceID,
            state: .received,
            sourceFilename: "legacy.png",
            importedAt: Date(timeIntervalSince1970: 100),
        ))
        let importer = fixture.importer()
        let client = MediaLibraryClient.connected(
            importer: importer,
            resources: fixture.resources,
            resourceLoadFence: fixture.fence,
        )
        let generation = client.beginAuthenticatedDownloadSession()
        let browserID = UUID()
        let browserBytes = DownloadFixture.png + Data([duplicate ? 0 : 255])
        try await client.acceptCompletedDownload(
            fixture.source(operationID: browserID, bytes: browserBytes),
            operationID: browserID,
            originalFilename: "browser.png",
        )
        let outcomes = await client.reconcileAcceptedDownloads(generation: generation)
        if duplicate {
            #expect(try outcomes[browserID] == .imported(#require(canonicalAssets.first), duplicate: true))
        } else {
            #expect(outcomes[browserID] == .failed(.assetLimitReached))
        }
        #expect(try await fixture.store.logicalAssetCount() == 49)
        #expect(try await fixture.store
            .ingestionJournal
            .snapshot()
            .entries
            .first(where: { $0.id == legacyID })?
            .state == .received)
        let refreshed = try await client.loadAssets()
        #expect(refreshed.count == 50)
        #expect(refreshed.contains(where: { $0.id == legacyID }))
        #expect(!refreshed.contains(where: { $0.id == browserID }))
        #expect(client.currentDownloadIngestionGeneration == generation)
        #expect(try await client.acceptedDownloadStorage().operationCount == (duplicate ? 0 : 1))
        if !duplicate {
            #expect(try Data(contentsOf: fixture.resources.stagingURL(for: browserID)) == browserBytes)
        }
    }

    @Test("Lock during the browser quota count prevents a stale entitlement lookup")
    func browserQuotaCountRechecksGenerationBeforeEntitlement() async throws {
        let fixture = try DownloadFixture()
        defer { fixture.removeFiles() }
        let barrier = DownloadCommitBarrier()
        let entitlementReads = Mutex(0)
        var entitlement = EntitlementClient.testValue
        entitlement.currentState = {
            entitlementReads.withLock { $0 += 1 }
            return .entitled
        }
        let quotaStore = try SQLiteMediaLibraryStore(
            database: PersistenceStore.makeInMemory(),
            logicalAssetCountOverride: {
                await barrier.pause()
                return 50
            },
        )
        let fence = fixture.fence
        let importer = MediaLibraryImporter(
            store: quotaStore,
            resources: fixture.resources,
            entitlement: entitlement,
            sessionAdmission: { _ in nil },
            downloadSessionIsCurrent: { fence.isDownloadSessionCurrent($0) },
            downloadCommitClaim: { fence.claimDownloadCommit(operationID: $0, generation: $1) },
        )
        let client = MediaLibraryClient.connected(
            importer: importer,
            resources: fixture.resources,
            resourceLoadFence: fence,
        )
        let generation = client.beginAuthenticatedDownloadSession()
        let operationID = UUID()
        try await client.acceptCompletedDownload(
            fixture.source(operationID: operationID, bytes: DownloadFixture.png),
            operationID: operationID,
            originalFilename: "picture.png",
        )
        let reconciliation = Task { await client.reconcileAcceptedDownloads(generation: generation) }
        await barrier.waitUntilPaused()
        client.advanceResourceLoadGeneration()
        _ = client.beginAuthenticatedDownloadSession()
        await barrier.resume()
        #expect(await reconciliation.value.isEmpty)
        #expect(entitlementReads.withLock { $0 } == 0)
        #expect(try await quotaStore.loadAssets().isEmpty)
        #expect(try await client.acceptedDownloadStorage().operationCount == 1)
    }
}

extension CompletedDownloadTests {
    @Test("Quota-denied browser work does not mutually reserve a slot released by failed legacy validation")
    func invalidLegacyDoesNotLeaveBrowserReservationsDeadlocked() async throws {
        let fixture = try DownloadFixture()
        defer { fixture.removeFiles() }
        for index in 0 ..< 49 {
            let resourceID = UUID()
            let bytes = DownloadFixture.png + Data([UInt8(index)])
            let stage = fixture.resources.stagingURL(for: resourceID)
            try bytes.write(to: stage)
            try fixture.resources.protectStaging(for: resourceID)
            let path = try fixture.resources.finalize(stagingURL: stage, resourceID: resourceID)
            try await fixture.store.commit(MediaAsset(
                id: UUID(),
                kind: .stillImage,
                importedAt: Date(timeIntervalSince1970: Double(index)),
                resources: [MediaResource(
                    id: resourceID,
                    role: .original,
                    relativePath: path,
                    sourceFilename: "canonical.png",
                    sourceUTI: "public.png",
                    byteCount: Int64(bytes.count),
                    sha256: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined(),
                )],
            ))
        }
        let legacyID = UUID()
        let legacyResourceID = UUID()
        let invalidBytes = Data("not an image".utf8)
        try invalidBytes.write(to: fixture.resources.stagingURL(for: legacyResourceID))
        try fixture.resources.protectStaging(for: legacyResourceID)
        try await fixture.store.ingestionJournal.accept(MediaIngestionJournalEntry(
            id: legacyID,
            resourceID: legacyResourceID,
            state: .received,
            sourceFilename: "legacy.png",
            importedAt: Date(timeIntervalSince1970: 100),
        ))
        let importer = fixture.importer()
        let client = MediaLibraryClient.connected(
            importer: importer,
            resources: fixture.resources,
            resourceLoadFence: fixture.fence,
        )
        let generation = client.beginAuthenticatedDownloadSession()
        let browserIDs = [UUID(), UUID()]
        for (index, operationID) in browserIDs.enumerated() {
            try await client.acceptCompletedDownload(
                fixture.source(operationID: operationID, bytes: DownloadFixture.png + Data([UInt8(254 + index)])),
                operationID: operationID,
                originalFilename: "browser.png",
            )
        }
        let denied = await client.reconcileAcceptedDownloads(generation: generation)
        #expect(browserIDs.allSatisfy { denied[$0] == .failed(.assetLimitReached) })
        #expect(try await fixture.store.logicalAssetCount() == 49)
        #expect(try await client.loadAssets().count == 49)
        #expect(try await fixture.store
            .ingestionJournal
            .snapshot()
            .entries
            .first(where: { $0.id == legacyID })?
            .state == .failed)
        let refreshed = try await client.loadAssets()
        #expect(refreshed.count == 50)
        #expect(refreshed.count(where: { browserIDs.contains($0.id) }) == 1)
        let finalOutcomes = await client.reconcileAcceptedDownloads(generation: generation)
        #expect(browserIDs.count(where: { finalOutcomes[$0] == .failed(.assetLimitReached) }) == 1)
        #expect(try await fixture.store.logicalAssetCount() == 50)
        #expect(try Data(contentsOf: fixture.resources.stagingURL(for: legacyResourceID)) == invalidBytes)
        #expect(client.currentDownloadIngestionGeneration == generation)
    }

    @Test("A partial browser ownership group stays blocked across SQLite reopen and legacy recovery")
    func nullDownloadStatusCannotBecomeLegacyRecovery() async throws {
        let fixture = try DownloadFixture()
        defer { fixture.removeFiles() }
        let first = try DiskDownloadSession(root: fixture.root, resources: fixture.resources)
        let operationID = UUID()
        try await first.importer.acceptCompletedDownload(
            fixture.source(operationID: operationID, bytes: DownloadFixture.png),
            operationID: operationID,
            originalFilename: "picture.png",
        )
        try await first.database.write { db in
            try db.execute(
                sql: "UPDATE media_ingestion_journal SET download_status = NULL WHERE id = ?",
                arguments: [operationID.uuidString],
            )
        }
        try first.database.close()
        let fresh = try DiskDownloadSession(root: fixture.root, resources: fixture.resources)
        defer { try? fresh.database.close() }
        await #expect(throws: MediaLibraryStoreError.corrupt) {
            try await fresh.importer.acceptedDownloadStorage()
        }
        #expect(try await fresh.importer.loadAssets().isEmpty)
        try await fresh.importer.reconcile()
        #expect(try await fresh.store.loadAssets().isEmpty)
        #expect(await fresh.importer
            .reconcileAcceptedDownloads(generation: fresh.fence.beginAuthenticatedDownloadSession())
            .isEmpty)
        #expect(try await fresh.store.loadAssets().isEmpty)
        #expect(try await fresh.store.ingestionJournal.snapshot().entries.first?.state == .received)
        #expect(try Data(contentsOf: fixture.resources.stagingURL(for: operationID)) == DownloadFixture.png)
    }

    @Test("Migrated legacy rows with all-null download ownership still recover without browser admission")
    func allNullDownloadOwnershipPreservesLegacyRecovery() async throws {
        let fixture = try DownloadFixture()
        defer { fixture.removeFiles() }
        let first = try DiskDownloadSession(root: fixture.root, resources: fixture.resources)
        let assetID = UUID()
        let resourceID = UUID()
        try DownloadFixture.png.write(to: fixture.resources.stagingURL(for: resourceID))
        try fixture.resources.protectStaging(for: resourceID)
        try await first.store.ingestionJournal.accept(MediaIngestionJournalEntry(
            id: assetID,
            resourceID: resourceID,
            state: .received,
            sourceFilename: "legacy.png",
            importedAt: Date(timeIntervalSince1970: 0),
        ))
        try first.database.close()
        let fresh = try DiskDownloadSession(root: fixture.root, resources: fixture.resources)
        defer { try? fresh.database.close() }
        #expect(try await fresh.store.ingestionJournal.downloadRecords().isEmpty)
        let assets = try await fresh.importer.loadAssets()
        #expect(assets.map(\.id) == [assetID])
        let resource = try #require(assets.first?.resources.first)
        #expect(try fixture.resources.data(for: resource) == DownloadFixture.png)
        try await fresh.importer.reconcile()
        #expect(try await fresh.store.logicalAssetCount() == 1)
    }
}
