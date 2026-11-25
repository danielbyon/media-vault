//
//  SQLiteMediaLibraryIngestionJournal+CompletedDownload.swift
//  MediaVault
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import GRDB

extension SQLiteMediaLibraryIngestionJournal {
    /// Adds download ownership to the existing journal. Each ALTER is guarded inside one write.
    /// Older ingestion rows retain NULL ownership and keep their original recovery contract.
    func prepareDownloadSchema() async throws {
        try await prepareSchema()
        try await database.write { db in
            let columns = try Set(Row.fetchAll(db, sql: "PRAGMA table_info(media_ingestion_journal)")
                .compactMap { $0["name"] as String? })
            let additions = [
                ("download_source_path", "TEXT"),
                ("download_bytes", "INTEGER"),
                ("download_device", "INTEGER"),
                ("download_inode", "INTEGER"),
                ("download_status", "TEXT"),
                ("canonical_asset_id", "TEXT"),
            ]
            for (name, type) in additions where !columns.contains(name) {
                try db.execute(sql: "ALTER TABLE media_ingestion_journal ADD COLUMN \(name) \(type)")
            }
        }
    }

    func downloadRecords() async throws -> [CompletedDownloadRecord] {
        try await prepareDownloadSchema()
        return try await database.read(Self.readDownloadRecords)
    }

    static func readDownloadRecords(_ db: Database) throws -> [CompletedDownloadRecord] {
        try downloadRows(db).map(decodeDownload)
    }

    #if DEBUG
    /// SQLite permits values of another storage class in older tables. Evidence rejects coerced ownership fields.
    static func inspectionDownloadRecords(_ db: Database) throws -> [CompletedDownloadRecord] {
        try downloadRows(db).map { row in
            let path: DatabaseValue = row["download_source_path"]
            let bytes: DatabaseValue = row["download_bytes"]
            let device: DatabaseValue = row["download_device"]
            let inode: DatabaseValue = row["download_inode"]
            let status: DatabaseValue = row["download_status"]
            let canonicalID: DatabaseValue = row["canonical_asset_id"]
            guard case let .string(source) = path.storage, !source.isEmpty,
                  case .int64 = bytes.storage, case .int64 = device.storage,
                  case .int64 = inode.storage, case .string = status.storage else {
                throw MediaLibraryStoreError.corrupt
            }

            switch canonicalID.storage {
            case .null,
                 .string:
                return try decodeDownload(row)
            default:
                throw MediaLibraryStoreError.corrupt
            }
        }
    }
    #endif

    private static func downloadRows(_ db: Database) throws -> [Row] {
        try Row.fetchAll(db, sql: """
        SELECT id, download_source_path, download_bytes, download_device, download_inode,
               download_status, canonical_asset_id
        FROM media_ingestion_journal
            WHERE download_source_path IS NOT NULL OR download_bytes IS NOT NULL
               OR download_device IS NOT NULL OR download_inode IS NOT NULL
               OR download_status IS NOT NULL OR canonical_asset_id IS NOT NULL
            ORDER BY imported_at, id
        """)
    }

    private static func decodeDownload(_ row: Row) throws -> CompletedDownloadRecord {
        guard let idString: String = row["id"], let id = UUID(uuidString: idString),
              let path: String = row["download_source_path"],
              let bytes: Int64 = row["download_bytes"], bytes >= 0,
              let device: Int64 = row["download_device"],
              let inode: Int64 = row["download_inode"],
              let status: String = row["download_status"],
              ["adopting", "pending", "imported", "duplicate", "unsupported", "discarding", "discarded"]
              .contains(status)
        else {
            throw MediaLibraryStoreError.corrupt
        }

        let canonical: String? = row["canonical_asset_id"]
        let canonicalID = canonical.flatMap(UUID.init(uuidString:))
        guard canonical == nil || canonicalID != nil else {
            throw MediaLibraryStoreError.corrupt
        }

        return CompletedDownloadRecord(
            operationID: id,
            sourcePath: path,
            byteCount: bytes,
            device: device,
            inode: inode,
            status: status,
            canonicalID: canonicalID,
        )
    }

    /// Persists terminal caller evidence and filesystem identity before ownership moves.
    func beginDownloadHandoff(
        operationID: UUID,
        sourceURL: URL,
        filename: String,
        byteCount: Int64,
        device: Int64,
        inode: Int64,
        acceptedAt: Date,
    ) async throws {
        try await prepareDownloadSchema()
        try await database.write { db in
            try db.execute(sql: """
            INSERT INTO media_ingestion_journal
              (id, resource_id, state, source_filename, imported_at,
               download_source_path, download_bytes, download_device, download_inode, download_status)
            VALUES (?, ?, 'received', ?, ?, ?, ?, ?, ?, 'adopting')
            """, arguments: [
                operationID.uuidString,
                operationID.uuidString,
                filename,
                acceptedAt.timeIntervalSince1970,
                sourceURL.path,
                byteCount,
                device,
                inode,
            ])
        }
    }

    /// A skipped duplicate is a completed ingestion with an existing canonical owner.
    func completeDuplicate(_ operationID: UUID, canonicalID: UUID, download: Bool) async throws {
        try await prepareDownloadSchema()
        try await database.write { db in
            try db.execute(sql: """
            UPDATE media_ingestion_journal
            SET state = 'complete', canonical_asset_id = ?,
                download_status = CASE WHEN ? THEN 'duplicate' ELSE download_status END
            WHERE id = ? AND state IN ('duplicateCheck', 'ready', 'committing')
            """, arguments: [canonicalID.uuidString, download, operationID.uuidString])
            guard db.changesCount == 1 else {
                throw MediaLibraryStoreError.corrupt
            }
        }
    }

    func compactDiscardedDownload(_ operationID: UUID) async throws {
        try await database.write { db in
            try db.execute(
                sql: "DELETE FROM media_ingestion_journal WHERE id = ? AND download_status = 'discarded'",
                arguments: [operationID.uuidString],
            )
        }
    }

    /// Keeps the canonical reference durable before duplicate staging cleanup starts.
    func updateDownload(_ operationID: UUID, status: String, canonicalID: UUID? = nil) async throws {
        try await database.write { db in
            try db.execute(sql: """
            UPDATE media_ingestion_journal SET download_status = ?, canonical_asset_id = ? WHERE id = ?
            """, arguments: [status, canonicalID?.uuidString, operationID.uuidString])
        }
    }
}
