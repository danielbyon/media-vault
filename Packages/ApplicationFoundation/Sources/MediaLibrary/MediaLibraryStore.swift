//
//  MediaLibraryStore.swift
//  MediaVault
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import SQLiteData

/// The persistence seam used by media import and Library presentation.
public protocol MediaLibraryStore: Sendable {
    /// Loads committed assets and their resources in import order.
    func loadAssets() async throws -> [MediaAsset]

    /// Commits one asset and all of its resource metadata atomically.
    func commit(_ asset: MediaAsset) async throws
}

/// A SQLiteData-backed canonical media store.
public actor SQLiteMediaLibraryStore: MediaLibraryStore {
    private let database: any DatabaseWriter

    /// Creates a store backed by the caller-owned SQLiteData connection.
    ///
    /// - Parameter database: The SQLiteData writer used for this media domain.
    public init(database: any DatabaseWriter) {
        self.database = database
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

    /// Commits an asset and its resources in one SQLite transaction.
    public func commit(_ asset: MediaAsset) async throws {
        guard !asset.resources.isEmpty else {
            throw MediaLibraryStoreError.unavailable
        }

        do {
            try await prepareSchema()
            try await database.write { db in
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
        } catch {
            throw MediaLibraryStoreError.unavailable
        }
    }

    private func prepareSchema() async throws {
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
}
