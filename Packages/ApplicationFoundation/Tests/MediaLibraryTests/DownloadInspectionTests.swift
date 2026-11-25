//
//  DownloadInspectionTests.swift
//  MediaVault
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//

#if DEBUG
import CryptoKit
import Foundation
import GRDB
import os
import Testing
@testable import MediaLibrary

struct DownloadInspectionTests {
    enum Schema: CaseIterable {
        case blank
        case journalOnly
        case canonicalAndBaseJournal
        case initialized
    }

    @Test("Only a fully initialized empty schema proves zero; inspection never prepares it", arguments: Schema.allCases)
    func readsExistingSchema(schema: Schema) async throws {
        let fixture = try DownloadFixture()
        defer { fixture.removeFiles() }
        let journal = fixture.store.ingestionJournal
        switch schema {
        case .blank:
            break
        case .journalOnly:
            try await journal.prepareSchema()
        case .canonicalAndBaseJournal:
            _ = try await fixture.store.loadAssets()
        case .initialized:
            _ = try await fixture.store.loadAssets()
            try await journal.prepareDownloadSchema()
        }
        let client = fixture.inspectionClient()
        _ = client.beginAuthenticatedDownloadSession()
        let before = try await Self.schemaSnapshot(fixture.database)
        let statements = try await Self.traceStatements(fixture.database)
        if schema == .initialized {
            let staging = try #require(try await client.staging())
            #expect(staging.storage == AcceptedDownloadStorage(operationCount: 0, byteCount: 0))
            #expect(!staging.hasSingleVerifiedStagedDownload)
            #expect(staging.matchesOperation == nil)
            let canonical = try #require(try await client.canonical())
            #expect(canonical.assetIDs.isEmpty && canonical.resourceCount == 0)
        } else {
            await #expect(throws: MediaLibraryStoreError.unavailable) { try await client.staging() }
            await #expect(throws: MediaLibraryStoreError.unavailable) { try await client.canonical() }
        }
        #expect(try await Self.schemaSnapshot(fixture.database) == before)
        let sql = statements.withLock { $0 }
        #expect(sql.contains { $0.hasPrefix("SELECT") })
        #expect(Self.writeStatements(in: sql).isEmpty)
    }

    @Test("An interrupted adoption stays on its original side of the rename", arguments: [false, true])
    func unfinishedAdoptionIsUnavailable(afterRename: Bool) async throws {
        let fixture = try DownloadFixture()
        defer { fixture.removeFiles() }
        let importer = fixture.importer()
        await importer.setDownloadStorageForTesting(availableBytes: { .max })
        if afterRename {
            await importer.setDownloadHandoffHooksForTesting(afterRename: { throw MediaLibraryStoreError.unavailable })
        } else {
            await importer.setDownloadHandoffHooksForTesting(afterIntent: { throw MediaLibraryStoreError.unavailable })
        }

        let id = UUID()
        let source = try fixture.source(operationID: id, bytes: DownloadFixture.png)
        let stage = fixture.resources.stagingURL(for: id)
        let client = fixture.inspectionClient(importer)
        await #expect(throws: CompletedDownloadAcceptanceError.ownershipUncertain) {
            try await client.acceptCompletedDownload(source, operationID: id, originalFilename: "image.png")
        }
        let ownedPath = afterRename ? stage : source
        let inode = try Self.fileNumber(ownedPath)
        let database = fixture.database
        let rows = try await Self.ownershipRows(database)
        let statements = try await Self.traceStatements(database)
        await #expect(throws: MediaLibraryStoreError.unavailable) { try await client.staging(id) }
        _ = client.beginAuthenticatedDownloadSession()
        await #expect(throws: MediaLibraryStoreError.unavailable) { try await client.canonical() }
        #expect(FileManager.default.fileExists(atPath: source.path) == !afterRename)
        #expect(FileManager.default.fileExists(atPath: stage.path) == afterRename)
        #expect(try Self.fileNumber(ownedPath) == inode)
        #expect(try await Self.ownershipRows(database) == rows)
        #expect(Self.writeStatements(in: statements.withLock { $0 }).isEmpty)
    }

    @Test("A same-size staging orphan counts against capacity and cannot prove accepted ownership")
    func orphanCannotProveStaging() async throws {
        let fixture = try DownloadFixture()
        defer { fixture.removeFiles() }
        _ = try await fixture.store.loadAssets()
        try await fixture.store.ingestionJournal.prepareDownloadSchema()
        let id = UUID()
        let bytes = DownloadFixture.png
        try bytes.write(to: fixture.resources.stagingURL(for: id))
        let client = fixture.inspectionClient()
        let sample = try #require(try await client.staging(id))
        #expect(sample.storage == AcceptedDownloadStorage(operationCount: 1, byteCount: Int64(bytes.count)))
        #expect(!sample.hasSingleVerifiedStagedDownload)
        #expect(sample.matchesOperation == false)
        #expect(try await client.canonical() == nil)
    }

    @Test("Staging proof binds the operation and inode; authenticated inspection leaves an eligible import pending")
    func acceptedStageRemainsPending() async throws {
        let fixture = try DownloadFixture()
        defer { fixture.removeFiles() }
        let importer = fixture.importer()
        await importer.setDownloadStorageForTesting(availableBytes: { .max })
        let client = fixture.inspectionClient(importer)
        let id = UUID()
        try await client.acceptCompletedDownload(
            fixture.source(operationID: id, bytes: DownloadFixture.png),
            operationID: id,
            originalFilename: "image.png",
        )
        let stage = fixture.resources.stagingURL(for: id)
        let inode = try Self.fileNumber(stage)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: stage.path)
        let attributes = try Self.stageAttributes(stage)
        let database = fixture.database
        let rows = try await Self.ownershipRows(database)
        let statements = try await Self.traceStatements(database)
        let locked = try #require(try await client.staging(id))
        #expect(locked.hasSingleVerifiedStagedDownload && locked.matchesOperation == true)
        #expect(try await client.staging(UUID())?.matchesOperation == false)
        #expect(try await client.staging()?.matchesOperation == nil)
        #expect(try await client.canonical() == nil)
        let lockedResourceReads = statements.withLock { $0.filter { $0.contains("FROM MEDIA_RESOURCES") } }
        #expect(!lockedResourceReads.isEmpty)
        #expect(lockedResourceReads.allSatisfy { !$0.contains("SHA256") && !$0.contains("SOURCE_FILENAME") })

        _ = client.beginAuthenticatedDownloadSession()
        let sample = try #require(try await client.canonical())
        #expect(sample.assetIDs.isEmpty && sample.resourceCount == 0)
        #expect(sample.storage == locked.storage)
        #expect(try await Self.ownershipRows(database) == rows)
        #expect(try Self.fileNumber(stage) == inode)
        #expect(try Self.stageAttributes(stage) == attributes)
        #expect(Self.writeStatements(in: statements.withLock { $0 }).isEmpty)

        // Keep the old inode alive while replacing its directory entry with equal-length bytes.
        let displaced = fixture.root.appendingPathComponent("displaced-stage")
        try FileManager.default.moveItem(at: stage, to: displaced)
        try DownloadFixture.png.write(to: stage)
        await #expect(throws: MediaLibraryStoreError.corrupt) { try await client.staging(id) }
        #expect(try Self.fileNumber(displaced) == inode)
        #expect(try await Self.ownershipRows(database) == rows)
    }

    @Test("Malformed ownership values fail inspection and remain available for diagnosis")
    func malformedOwnershipRemainsUntouched() async throws {
        let fixture = try DownloadFixture()
        defer { fixture.removeFiles() }
        let importer = fixture.importer()
        await importer.setDownloadStorageForTesting(availableBytes: { .max })
        let client = fixture.inspectionClient(importer)
        let id = UUID()
        try await client.acceptCompletedDownload(
            fixture.source(operationID: id, bytes: DownloadFixture.png),
            operationID: id,
            originalFilename: "image.png",
        )
        let database = fixture.database
        try await database.write { db in
            try db.execute(
                sql: "UPDATE media_ingestion_journal SET download_bytes = 'invalid' WHERE id = ?",
                arguments: [id.uuidString],
            )
        }
        let rows = try await Self.ownershipRows(database)
        await #expect(throws: MediaLibraryStoreError.corrupt) { try await client.staging(id) }
        _ = client.beginAuthenticatedDownloadSession()
        await #expect(throws: MediaLibraryStoreError.corrupt) { try await client.canonical() }
        #expect(try await Self.ownershipRows(database) == rows)
    }

    @Test("Canonical proof checks exact bytes and digest through the same owned descriptor")
    func canonicalOriginalAndDuplicate() async throws {
        let fixture = try DownloadFixture()
        defer { fixture.removeFiles() }
        let importer = fixture.importer()
        await importer.setDownloadStorageForTesting(availableBytes: { .max })
        let client = fixture.inspectionClient(importer)
        let generation = client.beginAuthenticatedDownloadSession()
        let firstID = UUID()
        for id in [firstID, UUID()] {
            try await client.acceptCompletedDownload(
                fixture.source(operationID: id, bytes: DownloadFixture.png),
                operationID: id,
                originalFilename: "image.png",
            )
            _ = await client.reconcileAcceptedDownloads(generation: generation)
        }
        let sample = try #require(try await client.canonical())
        #expect(sample.assetIDs == [firstID] && sample.resourceCount == 1)
        #expect(sample.storage == AcceptedDownloadStorage(operationCount: 0, byteCount: 0))
        #expect(sample.originalBytesMatch && sample.originalHashMatches)
        let other = Data(repeating: 0, count: DownloadFixture.png.count)
        let mismatch = try #require(try await client.canonical(matching: other))
        #expect(!mismatch.originalBytesMatch && mismatch.originalHashMatches)

        let url = fixture.resources.rootURL.appendingPathComponent(firstID.uuidString.lowercased())
        try other.write(to: url)
        let corrupt = try #require(try await client.canonical())
        #expect(!corrupt.originalBytesMatch && !corrupt.originalHashMatches)
        #expect(try Data(contentsOf: url) == other)

        let displaced = fixture.root.appendingPathComponent("displaced-original")
        try FileManager.default.moveItem(at: url, to: displaced)
        try FileManager.default.createSymbolicLink(at: url, withDestinationURL: displaced)
        await #expect(throws: MediaLibraryStoreError.unavailable) { try await client.canonical() }
        client.advanceResourceLoadGeneration()
        let locked = try #require(try await client.staging())
        #expect(locked.storage.operationCount == 0)
        #expect(try await client.canonical() == nil)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: url.path) == displaced.path)
    }

    @Test("A queued proof expires across Lock and fresh authentication", arguments: [false, true])
    func oldContextExpiresWhileQueued(canonical: Bool) async throws {
        let fixture = try DownloadFixture()
        defer { fixture.removeFiles() }
        _ = try await fixture.store.loadAssets()
        try await fixture.store.ingestionJournal.prepareDownloadSchema()
        let client = fixture.inspectionClient()
        let ingestion = client.beginAuthenticatedDownloadSession()
        let resource = client.currentResourceLoadGeneration
        let barrier = DownloadCommitBarrier()
        let holder = Task { try await fixture.store.withDurableOperation { await barrier.pause() } }
        await barrier.waitUntilPaused()
        let pending = Task {
            if canonical {
                return try await client.inspectCanonicalDownloads(
                    matching: DownloadFixture.png,
                    resourceGeneration: resource,
                    ingestionGeneration: ingestion,
                ) != nil
            }
            return try await client.inspectDownloadStaging(
                operationID: nil,
                resourceGeneration: resource,
                ingestionGeneration: ingestion,
            ) != nil
        }
        await fixture.store.waitForDurableOperationWaiterForTesting()
        client.advanceResourceLoadGeneration()
        _ = client.beginAuthenticatedDownloadSession()
        await barrier.resume()
        try await holder.value
        #expect(try await !pending.value)
        #expect(try await client.canonical() != nil)
        #expect(try await client.staging() != nil)
        client.suspendDownloadIngestion()
        #expect(try await client.canonical() == nil)
    }

    @Test("The database queue rechecks a stale context before its first Library SELECT")
    func staleContextAtDatabaseEntryReadsNoRows() async throws {
        let fixture = try DownloadFixture()
        defer { fixture.removeFiles() }
        let statements = try await Self.traceStatements(fixture.database)
        await #expect(throws: CancellationError.self) {
            try await fixture.store.downloadInspectionRows(includingAssets: true, isCurrent: { false })
        }
        #expect(statements.withLock { !$0.contains { $0.contains("FROM MEDIA_") } })
    }

    @Test("Cancelling a proof queued at the durable gate propagates cancellation")
    func cancellationRemainsObservable() async throws {
        let fixture = try DownloadFixture()
        defer { fixture.removeFiles() }
        let client = fixture.inspectionClient()
        let barrier = DownloadCommitBarrier()
        let holder = Task { try await fixture.store.withDurableOperation { await barrier.pause() } }
        await barrier.waitUntilPaused()
        let pending = Task { try await client.staging() }
        await fixture.store.waitForDurableOperationWaiterForTesting()
        pending.cancel()
        await barrier.resume()
        try await holder.value
        await #expect(throws: CancellationError.self) { try await pending.value }
    }

    @Test("The descriptor reader checks the fence between chunks")
    func invalidationStopsDescriptorRead() throws {
        let fixture = try DownloadFixture()
        defer { fixture.removeFiles() }
        let id = UUID()
        let path = id.uuidString.lowercased()
        let data = Data(repeating: 7, count: 2 * 64 * 1_024)
        try data.write(to: fixture.resources.rootURL.appendingPathComponent(path))
        let resource = MediaResource(
            id: id,
            role: .original,
            relativePath: path,
            sourceFilename: "original.bin",
            sourceUTI: "public.data",
            byteCount: Int64(data.count),
            sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
        )
        let generation = fixture.fence.beginAuthenticatedDownloadSession()
        var reads = 0
        #expect(throws: CancellationError.self) {
            try fixture.resources.readCanonicalResource(
                resource,
                isCurrent: { fixture.fence.isDownloadSessionCurrent(generation) },
            ) { _ in
                reads += 1
                fixture.fence.advance()
            }
        }
        #expect(reads == 1)
    }
}

extension DownloadFixture {
    fileprivate func inspectionClient(_ importer: MediaLibraryImporter? = nil) -> MediaLibraryClient {
        MediaLibraryClient.connected(
            importer: importer ?? self.importer(),
            resources: resources,
            resourceLoadFence: fence,
        )
    }
}

extension MediaLibraryClient {
    fileprivate func staging(_ id: UUID? = nil) async throws -> DownloadStagingEvidence? {
        try await inspectDownloadStaging(
            operationID: id,
            resourceGeneration: currentResourceLoadGeneration,
            ingestionGeneration: currentDownloadIngestionGeneration,
        )
    }

    fileprivate func canonical(matching bytes: Data = DownloadFixture.png) async throws -> CanonicalDownloadEvidence? {
        try await inspectCanonicalDownloads(
            matching: bytes,
            resourceGeneration: currentResourceLoadGeneration,
            ingestionGeneration: currentDownloadIngestionGeneration,
        )
    }
}

extension DownloadInspectionTests {
    fileprivate struct StageAttributes: Equatable {
        let permissions: Int?
        let protection: FileProtectionType?
        let excludedFromBackup: Bool?
    }

    fileprivate static func stageAttributes(_ url: URL) throws -> StageAttributes {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let uncached = URL(fileURLWithPath: url.path)
        return try StageAttributes(
            permissions: attributes[.posixPermissions] as? Int,
            protection: attributes[.protectionKey] as? FileProtectionType,
            excludedFromBackup: uncached.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup,
        )
    }

    fileprivate static func fileNumber(_ url: URL) throws -> UInt64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return try #require(attributes[.systemFileNumber] as? UInt64)
    }

    fileprivate static func schemaSnapshot(_ database: any DatabaseWriter) async throws -> [String] {
        try await database.read { db in
            try String.fetchAll(db, sql: "SELECT sql FROM sqlite_schema WHERE sql IS NOT NULL ORDER BY name")
        }
    }

    fileprivate static func ownershipRows(_ database: any DatabaseWriter) async throws -> [String] {
        try await database.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM media_ingestion_journal ORDER BY id").map(\.description)
        }
    }

    fileprivate static func traceStatements(_ database: any DatabaseWriter) async throws
        -> OSAllocatedUnfairLock<[String]> {
        let statements = OSAllocatedUnfairLock(initialState: [String]())
        try await database.writeWithoutTransaction { db in
            db.trace { event in
                if case let .statement(statement) = event {
                    let sql = statement.sql.uppercased()
                    statements.withLock { $0.append(sql) }
                }
            }
        }
        return statements
    }

    fileprivate static func writeStatements(in statements: [String]) -> [String] {
        let writes = [
            "INSERT",
            "UPDATE",
            "DELETE",
            "CREATE",
            "ALTER",
            "DROP",
            "REPLACE",
            "BEGIN IMMEDIATE",
            "BEGIN EXCLUSIVE",
        ]
        return statements.filter { sql in writes.contains { sql.hasPrefix($0) } }
    }
}
#endif
