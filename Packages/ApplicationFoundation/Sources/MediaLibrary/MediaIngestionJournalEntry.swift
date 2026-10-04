//
//  MediaIngestionJournalEntry.swift
//  MediaVault
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import SQLiteData

/// The durable record that connects accepted staging bytes to a canonical asset.
///
/// A journal entry is stored in the same SQLite database as Library metadata.
/// Its identifier is the canonical asset identifier, while `resourceID` selects
/// the opaque staging and permanent resource paths.
public struct MediaIngestionJournalEntry: Equatable, Identifiable, Sendable {
    /// The identifier that will be used by the canonical Library asset.
    public let id: UUID

    /// The opaque identifier used for the accepted original resource.
    public let resourceID: UUID

    /// The last durable lifecycle state recorded for this import.
    public let state: MediaIngestionState

    /// The source name retained as descriptive metadata, not as a storage path.
    public let sourceFilename: String

    /// The time the import was accepted into protected app-controlled staging.
    public let importedAt: Date

    /// The media type discovered while validating the accepted original bytes.
    public let sourceUTI: String?

    /// The exact size of the accepted original bytes after validation.
    public let byteCount: Int64?

    /// The SHA-256 digest of the accepted original bytes after validation.
    public let sha256: String?

    /// The capture time embedded in the original, when one is available.
    public let capturedAt: Date?

    init(
        id: UUID,
        resourceID: UUID,
        state: MediaIngestionState,
        sourceFilename: String,
        importedAt: Date,
        sourceUTI: String? = nil,
        byteCount: Int64? = nil,
        sha256: String? = nil,
        capturedAt: Date? = nil,
    ) {
        self.id = id
        self.resourceID = resourceID
        self.state = state
        self.sourceFilename = sourceFilename
        self.importedAt = importedAt
        self.sourceUTI = sourceUTI
        self.byteCount = byteCount
        self.sha256 = sha256
        self.capturedAt = capturedAt
    }

    func advancing(
        to state: MediaIngestionState,
        inspection: ImageInspection? = nil,
    ) -> Self {
        Self(
            id: id,
            resourceID: resourceID,
            state: state,
            sourceFilename: sourceFilename,
            importedAt: importedAt,
            sourceUTI: inspection?.uti ?? sourceUTI,
            byteCount: inspection?.byteCount ?? byteCount,
            sha256: inspection?.sha256 ?? sha256,
            capturedAt: inspection?.capturedAt ?? capturedAt,
        )
    }
}

struct MediaIngestionJournalSnapshot: Sendable {
    /// Journal entries whose persisted fields passed safe decoding.
    let entries: [MediaIngestionJournalEntry]

    /// Asset IDs whose rows could not be decoded and must stay hidden if committed.
    let unreadableAssetIDs: Set<UUID>

    /// Resource IDs present in any row, including rows that could not be decoded.
    let knownResourceIDs: Set<UUID>
}

/// Persists journal state in the vault database without exposing transitions to callers.
actor SQLiteMediaLibraryIngestionJournal {
    private let database: any DatabaseWriter

    init(database: any DatabaseWriter) {
        self.database = database
    }

    func accept(_ entry: MediaIngestionJournalEntry) async throws {
        guard entry.state == .received,
              entry.sourceUTI == nil,
              entry.byteCount == nil,
              entry.sha256 == nil
        else {
            throw MediaLibraryStoreError.corrupt
        }

        do {
            try await prepareSchema()
            try await database.write { db in
                try db.execute(
                    sql: """
                    INSERT INTO media_ingestion_journal (
                      id, resource_id, state, source_filename, imported_at,
                      source_uti, byte_count, sha256, captured_at
                    ) VALUES (?, ?, ?, ?, ?, NULL, NULL, NULL, NULL)
                    """,
                    arguments: [
                        entry.id.uuidString,
                        entry.resourceID.uuidString,
                        entry.state.rawValue,
                        entry.sourceFilename,
                        entry.importedAt.timeIntervalSince1970,
                    ],
                )
            }
        } catch {
            throw MediaLibraryStoreError.unavailable
        }
    }

    /// Records staging evidence left between protected copy and journal insertion.
    func preserveUnjournaledStaging(assetID: UUID, resourceID: UUID, recordedAt: Date) async throws {
        let entry = MediaIngestionJournalEntry(
            id: assetID,
            resourceID: resourceID,
            state: .failed,
            sourceFilename: resourceID.uuidString.lowercased(),
            importedAt: recordedAt,
        )
        do {
            try await prepareSchema()
            try await database.write { db in
                try db.execute(
                    sql: """
                    INSERT INTO media_ingestion_journal (
                      id, resource_id, state, source_filename, imported_at,
                      source_uti, byte_count, sha256, captured_at
                    ) VALUES (?, ?, ?, ?, ?, NULL, NULL, NULL, NULL)
                    """,
                    arguments: [
                        entry.id.uuidString,
                        entry.resourceID.uuidString,
                        entry.state.rawValue,
                        entry.sourceFilename,
                        entry.importedAt.timeIntervalSince1970,
                    ],
                )
            }
        } catch {
            throw MediaLibraryStoreError.unavailable
        }
    }

    func transition(
        _ entry: MediaIngestionJournalEntry,
        to state: MediaIngestionState,
        inspection: ImageInspection? = nil,
    ) async throws -> MediaIngestionJournalEntry {
        guard Self.canAdvance(from: entry.state, to: state) else {
            throw MediaLibraryStoreError.corrupt
        }

        let updated = entry.advancing(to: state, inspection: inspection)

        do {
            return try await database.write { db -> MediaIngestionJournalEntry in
                let currentState = try #sql(
                    "SELECT state FROM media_ingestion_journal WHERE id = \(bind: entry.id.uuidString)",
                    as: String.self,
                ).fetchOne(db)

                if currentState == state.rawValue {
                    let row = try #sql(
                        """
                        SELECT id, resource_id, state, source_filename, imported_at,
                               source_uti, byte_count, sha256, captured_at
                        FROM media_ingestion_journal
                        WHERE id = \(bind: entry.id.uuidString)
                        """,
                        as: (String, String, String, String, Double, String?, Int64?, String?, Double?).self,
                    ).fetchOne(db)
                    guard let row,
                          let persistedID = UUID(uuidString: row.0),
                          let persistedResourceID = UUID(uuidString: row.1),
                          let persistedState = MediaIngestionState(rawValue: row.2),
                          persistedID == entry.id,
                          persistedState == state,
                          !row.3.isEmpty
                    else {
                        throw MediaLibraryStoreError.corrupt
                    }

                    let hasValidationMetadata = row.5 != nil && row.6 != nil && row.7 != nil
                    let hasPartialValidationMetadata = row.5 != nil || row.6 != nil || row.7 != nil
                    let requiresValidationMetadata = [.duplicateCheck, .ready, .committing, .complete]
                        .contains(persistedState)
                    guard !hasPartialValidationMetadata || hasValidationMetadata,
                          !hasValidationMetadata || (row.6 ?? -1) >= 0,
                          !hasValidationMetadata || row.7?.count == 64,
                          !requiresValidationMetadata || hasValidationMetadata
                    else {
                        throw MediaLibraryStoreError.corrupt
                    }

                    return MediaIngestionJournalEntry(
                        id: persistedID,
                        resourceID: persistedResourceID,
                        state: persistedState,
                        sourceFilename: row.3,
                        importedAt: Date(timeIntervalSince1970: row.4),
                        sourceUTI: row.5,
                        byteCount: row.6,
                        sha256: row.7,
                        capturedAt: row.8.map(Date.init(timeIntervalSince1970:)),
                    )
                }
                guard currentState == entry.state.rawValue else {
                    throw MediaLibraryStoreError.corrupt
                }

                try db.execute(
                    sql: """
                    UPDATE media_ingestion_journal
                    SET state = ?, source_uti = ?, byte_count = ?, sha256 = ?, captured_at = ?
                    WHERE id = ? AND state = ?
                    """,
                    arguments: [
                        state.rawValue,
                        updated.sourceUTI,
                        updated.byteCount,
                        updated.sha256,
                        updated.capturedAt?.timeIntervalSince1970,
                        entry.id.uuidString,
                        entry.state.rawValue,
                    ],
                )
                return updated
            }
        } catch let error as MediaLibraryStoreError {
            throw error
        } catch {
            throw MediaLibraryStoreError.unavailable
        }
    }

    func snapshot() async throws -> MediaIngestionJournalSnapshot {
        do {
            try await prepareSchema()
            let rows = try await database.read { db in
                try #sql(
                    """
                    SELECT id, resource_id, state, source_filename, imported_at,
                           source_uti, byte_count, sha256, captured_at
                    FROM media_ingestion_journal
                    ORDER BY imported_at, id
                    """,
                    as: (String, String, String, String, Double, String?, Int64?, String?, Double?).self,
                ).fetchAll(db)
            }

            var entries: [MediaIngestionJournalEntry] = []
            var unreadableAssetIDs = Set<UUID>()
            var knownResourceIDs = Set<UUID>()
            for row in rows {
                if let resourceID = UUID(uuidString: row.1) {
                    knownResourceIDs.insert(resourceID)
                }
                guard let assetID = UUID(uuidString: row.0),
                      let resourceID = UUID(uuidString: row.1),
                      let state = MediaIngestionState(rawValue: row.2),
                      !row.3.isEmpty
                else {
                    if let assetID = UUID(uuidString: row.0) {
                        unreadableAssetIDs.insert(assetID)
                    }
                    continue
                }

                let hasValidationMetadata = row.5 != nil && row.6 != nil && row.7 != nil
                let hasPartialValidationMetadata = row.5 != nil || row.6 != nil || row.7 != nil
                guard !hasPartialValidationMetadata || hasValidationMetadata,
                      !hasValidationMetadata || (row.6 ?? -1) >= 0,
                      !hasValidationMetadata || (row.7?.count == 64),
                      ![.duplicateCheck, .ready, .committing, .complete].contains(state) || hasValidationMetadata
                else {
                    unreadableAssetIDs.insert(assetID)
                    continue
                }

                entries.append(
                    MediaIngestionJournalEntry(
                        id: assetID,
                        resourceID: resourceID,
                        state: state,
                        sourceFilename: row.3,
                        importedAt: Date(timeIntervalSince1970: row.4),
                        sourceUTI: row.5,
                        byteCount: row.6,
                        sha256: row.7,
                        capturedAt: row.8.map(Date.init(timeIntervalSince1970:)),
                    ),
                )
            }
            return MediaIngestionJournalSnapshot(
                entries: entries,
                unreadableAssetIDs: unreadableAssetIDs,
                knownResourceIDs: knownResourceIDs,
            )
        } catch {
            throw MediaLibraryStoreError.unavailable
        }
    }

    func compactCompleteEntry(for assetID: UUID) async throws {
        do {
            try await database.write { db in
                try db.execute(
                    sql: "DELETE FROM media_ingestion_journal WHERE id = ? AND state = ?",
                    arguments: [assetID.uuidString, MediaIngestionState.complete.rawValue],
                )
            }
        } catch {
            throw MediaLibraryStoreError.unavailable
        }
    }

    func prepareSchema() async throws {
        do {
            try await database.write { db in
                try db.execute(
                    sql: """
                    CREATE TABLE IF NOT EXISTS media_ingestion_journal (
                      id TEXT PRIMARY KEY NOT NULL,
                      resource_id TEXT NOT NULL UNIQUE,
                      state TEXT NOT NULL CHECK (state IN (
                        'received', 'validating', 'duplicateCheck', 'ready', 'committing',
                        'complete', 'awaitingUserDecision', 'failed', 'cancelled'
                      )),
                      source_filename TEXT NOT NULL,
                      imported_at REAL NOT NULL,
                      source_uti TEXT,
                      byte_count INTEGER CHECK (byte_count IS NULL OR byte_count >= 0),
                      sha256 TEXT CHECK (sha256 IS NULL OR length(sha256) = 64),
                      captured_at REAL,
                      CHECK (
                        (source_uti IS NULL AND byte_count IS NULL AND sha256 IS NULL)
                        OR (source_uti IS NOT NULL AND byte_count IS NOT NULL AND sha256 IS NOT NULL)
                      )
                    )
                    """,
                )
            }
        } catch {
            throw MediaLibraryStoreError.unavailable
        }
    }

    private static func canAdvance(from current: MediaIngestionState, to next: MediaIngestionState) -> Bool {
        if next == .failed || next == .cancelled {
            return current != .complete && current != .failed && current != .cancelled
        }
        return switch (current, next) {
        case (.received, .validating),
             (.validating, .duplicateCheck),
             (.duplicateCheck, .ready),
             (.duplicateCheck, .awaitingUserDecision),
             (.ready, .committing):
            true
        default:
            false
        }
    }
}
