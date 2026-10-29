//
//  MediaLibraryStore.swift
//  MediaVault
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import GRDB
import SQLiteData
import StructuredQueries
import StructuredQueriesCore

/// The persistence seam used by media import and Library presentation.
public protocol MediaLibraryStore: Sendable {
    /// Loads committed assets and their resources in import order.
    func loadAssets() async throws -> [MediaAsset]

    /// Counts committed logical assets in the canonical Library.
    ///
    /// Each row in `media_assets` contributes one to the count. Additional
    /// resources and byte size within an asset do not change the result.
    func logicalAssetCount() async throws -> Int

    /// Commits one asset and all of its resource metadata atomically.
    func commit(_ asset: MediaAsset) async throws
}

/// A SQLiteData-backed canonical media store.
public actor SQLiteMediaLibraryStore: MediaLibraryStore {
    private let database: any DatabaseWriter
    private let logicalAssetCountOverride: (@Sendable () async throws -> Int)?
    nonisolated let ingestionJournal: SQLiteMediaLibraryIngestionJournal
    private var hasActiveDurableOperation = false
    private var durableOperationWaiters: [DurableOperationWaiter] = []
    private var durableOperationWaiterObservers: [CheckedContinuation<Void, Never>] = []

    private struct DurableOperationWaiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, Error>
    }

    /// Creates a store backed by the caller-owned SQLiteData connection.
    ///
    /// - Parameter database: The SQLiteData writer used for this media domain.
    public init(database: any DatabaseWriter) {
        self.database = database
        logicalAssetCountOverride = nil
        ingestionJournal = SQLiteMediaLibraryIngestionJournal(database: database)
    }

    /// Creates a store with a deterministic logical-count operation for failure tests.
    init(
        database: any DatabaseWriter,
        logicalAssetCountOverride: @escaping @Sendable () async throws -> Int,
    ) {
        self.database = database
        self.logicalAssetCountOverride = logicalAssetCountOverride
        ingestionJournal = SQLiteMediaLibraryIngestionJournal(database: database)
    }

    /// Loads all committed assets and reconstructs their resource relationship.
    public func loadAssets() async throws -> [MediaAsset] {
        do {
            try await prepareSchema()
            let assetRows = try await loadAssetRows()
            let resourceRows = try await loadResourceRows()
            let resourcesByAsset = try makeResourcesByAsset(from: resourceRows)
            return try makeAssets(from: assetRows, resourcesByAsset: resourcesByAsset)
        } catch let error as MediaLibraryStoreError {
            throw error
        } catch {
            throw MediaLibraryStoreError.unavailable
        }
    }

    /// Counts committed logical assets after preparing a new database schema.
    ///
    /// Schema preparation makes an empty database report zero while keeping
    /// database and schema failures visible to import admission.
    public func logicalAssetCount() async throws -> Int {
        if let logicalAssetCountOverride {
            do {
                return try await logicalAssetCountOverride()
            } catch let error as MediaLibraryStoreError {
                throw error
            } catch {
                throw MediaLibraryStoreError.unavailable
            }
        }

        do {
            try await prepareSchema()
            return try await database.read { db in
                guard let count = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM media_assets") else {
                    throw MediaLibraryStoreError.unavailable
                }

                return count
            }
        } catch let error as MediaLibraryStoreError {
            throw error
        } catch {
            throw MediaLibraryStoreError.unavailable
        }
    }

    /// Runs one import or recovery operation while excluding other store users.
    ///
    /// Each ``MediaLibraryImporter`` can create its own actor, but importers that
    /// share this store must also share admission and recovery ordering. The
    /// gate remains held across every await in `operation`, including admission,
    /// staging, journal acceptance, reconciliation, and canonical commit.
    func withDurableOperation<T: Sendable>(
        _ operation: @Sendable () async throws -> T,
    ) async throws -> T {
        try await acquireDurableOperation()
        do {
            try Task.checkCancellation()
            let result = try await operation()
            releaseDurableOperation()
            return result
        } catch {
            releaseDurableOperation()
            throw error
        }
    }

    /// Waits until another durable operation is queued for this store.
    func waitForDurableOperationWaiterForTesting() async {
        guard durableOperationWaiters.isEmpty else {
            return
        }

        await withCheckedContinuation { continuation in
            durableOperationWaiterObservers.append(continuation)
        }
    }

    /// Returns the shared gate state for deterministic ordering tests.
    func durableOperationGateStateForTesting() -> (isActive: Bool, waiterCount: Int) {
        (hasActiveDurableOperation, durableOperationWaiters.count)
    }

    private func loadAssetRows() async throws -> [(String, String, Double, Double?)] {
        try await database.read { db in
            try #sql(
                """
                SELECT id, kind, imported_at, captured_at
                FROM media_assets
                ORDER BY imported_at, id
                """,
                as: (String, String, Double, Double?).self,
            ).fetchAll(db)
        }
    }

    private func loadResourceRows() async throws -> [(String, String, String, String, String, String, Int64, String)] {
        try await database.read { db in
            try #sql(
                """
                SELECT id, asset_id, role, relative_path, source_filename, source_uti, byte_count, sha256
                FROM media_resources
                ORDER BY asset_id, id
                """,
                as: (String, String, String, String, String, String, Int64, String).self,
            ).fetchAll(db)
        }
    }

    private func makeResourcesByAsset(
        from rows: [(String, String, String, String, String, String, Int64, String)],
    ) throws -> [String: [MediaResource]] {
        var resourcesByAsset: [String: [MediaResource]] = [:]
        for row in rows {
            guard let resourceID = UUID(uuidString: row.0),
                  let role = MediaResourceRole(rawValue: row.2)
            else {
                throw MediaLibraryStoreError.corrupt
            }

            let resource = MediaResource(
                id: resourceID,
                role: role,
                relativePath: row.3,
                sourceFilename: row.4,
                sourceUTI: row.5,
                byteCount: row.6,
                sha256: row.7,
            )
            resourcesByAsset[row.1, default: []].append(resource)
        }
        return resourcesByAsset
    }

    private func makeAssets(
        from rows: [(String, String, Double, Double?)],
        resourcesByAsset: [String: [MediaResource]],
    ) throws -> [MediaAsset] {
        try rows.map { row in
            guard let assetID = UUID(uuidString: row.0),
                  let kind = MediaAssetKind(rawValue: row.1)
            else {
                throw MediaLibraryStoreError.corrupt
            }

            let resources = resourcesByAsset[row.0] ?? []
            guard !resources.isEmpty else {
                throw MediaLibraryStoreError.corrupt
            }

            return MediaAsset(
                id: assetID,
                kind: kind,
                importedAt: Date(timeIntervalSince1970: row.2),
                resources: resources,
                capturedAt: row.3.map(Date.init(timeIntervalSince1970:)),
            )
        }
    }

    private func acquireDurableOperation() async throws {
        try Task.checkCancellation()
        guard hasActiveDurableOperation else {
            hasActiveDurableOperation = true
            return
        }

        let waiterID = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                durableOperationWaiters.append(
                    DurableOperationWaiter(id: waiterID, continuation: continuation),
                )
                let observers = durableOperationWaiterObservers
                durableOperationWaiterObservers.removeAll(keepingCapacity: true)
                observers.forEach { $0.resume() }
            }
        } onCancel: {
            Task {
                await self.cancelDurableOperationWaiter(waiterID)
            }
        }
    }

    private func cancelDurableOperationWaiter(_ waiterID: UUID) {
        guard let index = durableOperationWaiters.firstIndex(where: { $0.id == waiterID }) else {
            return
        }

        let waiter = durableOperationWaiters.remove(at: index)
        waiter.continuation.resume(throwing: CancellationError())
    }

    private func releaseDurableOperation() {
        guard !durableOperationWaiters.isEmpty else {
            hasActiveDurableOperation = false
            return
        }

        let next = durableOperationWaiters.removeFirst()
        next.continuation.resume()
    }

    /// Commits an asset and its resources in one SQLite transaction.
    public func commit(_ asset: MediaAsset) async throws {
        guard !asset.resources.isEmpty else {
            throw MediaLibraryStoreError.unavailable
        }

        do {
            try await prepareSchema()
            try await database.write { db in
                try Self.insertCanonicalRows(for: asset, in: db)
            }
        } catch {
            throw MediaLibraryStoreError.unavailable
        }
    }

    /// Commits canonical rows and marks their journal entry complete atomically.
    func commit(_ asset: MediaAsset, completingIngestion assetID: UUID) async throws {
        guard !asset.resources.isEmpty, asset.id == assetID else {
            throw MediaLibraryStoreError.corrupt
        }

        do {
            try await prepareSchema()
            try await database.write { db in
                let storedAsset = try #sql(
                    "SELECT kind, imported_at, captured_at FROM media_assets WHERE id = \(bind: asset.id.uuidString)",
                    as: (String, Double, Double?).self,
                ).fetchOne(db)

                if let storedAsset {
                    guard storedAsset.0 == asset.kind.rawValue,
                          storedAsset.1 == asset.importedAt.timeIntervalSince1970,
                          storedAsset.2 == asset.capturedAt?.timeIntervalSince1970
                    else {
                        throw MediaLibraryStoreError.corrupt
                    }

                    let storedResources = try #sql(
                        """
                        SELECT id, asset_id, role, relative_path, source_filename, source_uti, byte_count, sha256
                        FROM media_resources WHERE asset_id = \(bind: asset.id.uuidString) ORDER BY id
                        """,
                        as: (String, String, String, String, String, String, Int64, String).self,
                    ).fetchAll(db)
                    let expectedResources = asset.resources.sorted { $0.id.uuidString < $1.id.uuidString }
                    guard storedResources.count == expectedResources.count,
                          zip(storedResources, expectedResources).allSatisfy({ stored, expected in
                              stored.0 == expected.id.uuidString
                                  && stored.1 == asset.id.uuidString
                                  && stored.2 == expected.role.rawValue
                                  && stored.3 == expected.relativePath
                                  && stored.4 == expected.sourceFilename
                                  && stored.5 == expected.sourceUTI
                                  && stored.6 == expected.byteCount
                                  && stored.7 == expected.sha256
                          })
                    else {
                        throw MediaLibraryStoreError.corrupt
                    }
                } else {
                    try Self.insertCanonicalRows(for: asset, in: db)
                }

                let journalState = try #sql(
                    "SELECT state FROM media_ingestion_journal WHERE id = \(bind: assetID.uuidString)",
                    as: String.self,
                ).fetchOne(db)
                guard journalState == MediaIngestionState.committing.rawValue
                    || journalState == MediaIngestionState.complete.rawValue
                else {
                    throw MediaLibraryStoreError.corrupt
                }

                try db.execute(
                    sql: "UPDATE media_ingestion_journal SET state = ? WHERE id = ?",
                    arguments: [MediaIngestionState.complete.rawValue, assetID.uuidString],
                )
            }
        } catch let error as MediaLibraryStoreError {
            throw error
        } catch {
            throw MediaLibraryStoreError.unavailable
        }
    }

    private func prepareSchema() async throws {
        try await ingestionJournal.prepareSchema()
        try await database.write { db in
            try db.execute(sql: "PRAGMA foreign_keys = ON")
            try db.execute(
                sql: """
                CREATE TABLE IF NOT EXISTS media_assets (
                  id TEXT PRIMARY KEY NOT NULL,
                  kind TEXT NOT NULL,
                  imported_at REAL NOT NULL,
                  captured_at REAL
                )
                """,
            )
            try db.execute(
                sql: """
                CREATE TABLE IF NOT EXISTS media_resources (
                  id TEXT PRIMARY KEY NOT NULL,
                  asset_id TEXT NOT NULL REFERENCES media_assets(id) ON DELETE CASCADE,
                  role TEXT NOT NULL,
                  relative_path TEXT NOT NULL UNIQUE,
                  source_filename TEXT NOT NULL,
                  source_uti TEXT NOT NULL,
                  byte_count INTEGER NOT NULL CHECK (byte_count >= 0),
                  sha256 TEXT NOT NULL CHECK (length(sha256) = 64)
                )
                """,
            )
            try db.execute(
                sql: "CREATE INDEX IF NOT EXISTS media_resources_asset_id ON media_resources(asset_id)",
            )
        }
    }

    private static func insertCanonicalRows(for asset: MediaAsset, in db: Database) throws {
        try db.execute(
            sql: """
            INSERT INTO media_assets (id, kind, imported_at, captured_at)
            VALUES (?, ?, ?, ?)
            """,
            arguments: [
                asset.id.uuidString,
                asset.kind.rawValue,
                asset.importedAt.timeIntervalSince1970,
                asset.capturedAt?.timeIntervalSince1970,
            ],
        )

        for resource in asset.resources {
            try db.execute(
                sql: """
                INSERT INTO media_resources (
                  id, asset_id, role, relative_path, source_filename, source_uti, byte_count, sha256
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: [
                    resource.id.uuidString,
                    asset.id.uuidString,
                    resource.role.rawValue,
                    resource.relativePath,
                    resource.sourceFilename,
                    resource.sourceUTI,
                    resource.byteCount,
                    resource.sha256,
                ],
            )
        }
    }
}
