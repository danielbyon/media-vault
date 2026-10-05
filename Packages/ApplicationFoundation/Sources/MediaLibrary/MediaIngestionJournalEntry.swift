//
//  MediaIngestionJournalEntry.swift
//  MediaVault
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import GRDB
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
                let statement = try db.makeStatement(sql: """
                SELECT id, resource_id, state, source_filename, imported_at,
                       source_uti, byte_count, sha256, captured_at
                FROM media_ingestion_journal
                ORDER BY imported_at, id
                """)
                return try Row.fetchAll(statement).map(DecodedJournalRow.init)
            }

            var entries: [MediaIngestionJournalEntry] = []
            var unreadableAssetIDs = Set<UUID>()
            var knownResourceIDs = Set<UUID>()
            for row in rows {
                if let resourceID = row.resourceID {
                    knownResourceIDs.insert(resourceID)
                }
                guard let assetID = row.assetID else {
                    continue
                }
                guard let entry = row.entry else {
                    unreadableAssetIDs.insert(assetID)
                    continue
                }

                entries.append(entry)
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

    private struct DecodedJournalRow: Sendable {
        let assetID: UUID?
        let resourceID: UUID?
        let entry: MediaIngestionJournalEntry?

        init(_ row: Row) {
            let assetIDValue: DatabaseValue = row[0]
            let resourceIDValue: DatabaseValue = row[1]
            let stateValue: DatabaseValue = row[2]
            let sourceFilenameValue: DatabaseValue = row[3]
            let importedAtValue: DatabaseValue = row[4]
            let sourceUTIValue: DatabaseValue = row[5]
            let byteCountValue: DatabaseValue = row[6]
            let sha256Value: DatabaseValue = row[7]
            let capturedAtValue: DatabaseValue = row[8]

            let assetID = Self.textValue(assetIDValue).flatMap { UUID(uuidString: $0) }
            let resourceID = Self.textValue(resourceIDValue).flatMap { UUID(uuidString: $0) }
            self.assetID = assetID
            self.resourceID = resourceID

            guard let assetID,
                  let resourceID,
                  let stateRawValue = Self.textValue(stateValue),
                  let state = MediaIngestionState(rawValue: stateRawValue),
                  let sourceFilename = Self.textValue(sourceFilenameValue),
                  !sourceFilename.isEmpty,
                  let importedAt = Self.numberValue(importedAtValue),
                  Self.isOptionalText(sourceUTIValue),
                  Self.isOptionalInteger(byteCountValue),
                  Self.isOptionalText(sha256Value),
                  Self.isOptionalNumber(capturedAtValue)
            else {
                entry = nil
                return
            }

            let sourceUTI = Self.textValue(sourceUTIValue)
            let byteCount = Self.integerValue(byteCountValue)
            let sha256 = Self.textValue(sha256Value)
            let capturedAt = Self.numberValue(capturedAtValue)
            let hasValidationMetadata = sourceUTI != nil && byteCount != nil && sha256 != nil
            let hasPartialValidationMetadata = sourceUTI != nil || byteCount != nil || sha256 != nil
            let requiresValidationMetadata =
                switch state {
                case .duplicateCheck,
                     .ready,
                     .committing,
                     .complete:
                    true
                default:
                    false
                }
            guard !hasPartialValidationMetadata || hasValidationMetadata,
                  !hasValidationMetadata || (byteCount ?? -1) >= 0,
                  !hasValidationMetadata || sha256?.count == 64,
                  !requiresValidationMetadata || hasValidationMetadata
            else {
                entry = nil
                return
            }

            entry = MediaIngestionJournalEntry(
                id: assetID,
                resourceID: resourceID,
                state: state,
                sourceFilename: sourceFilename,
                importedAt: Date(timeIntervalSince1970: importedAt),
                sourceUTI: sourceUTI,
                byteCount: byteCount,
                sha256: sha256,
                capturedAt: capturedAt.map(Date.init(timeIntervalSince1970:)),
            )
        }

        private static func textValue(_ value: DatabaseValue) -> String? {
            guard case let .string(string) = value.storage else {
                return nil
            }

            return string
        }

        private static func numberValue(_ value: DatabaseValue) -> Double? {
            switch value.storage {
            case let .double(number) where number.isFinite:
                number
            case let .int64(number):
                Double(number)
            default:
                nil
            }
        }

        private static func integerValue(_ value: DatabaseValue) -> Int64? {
            guard case let .int64(integer) = value.storage else {
                return nil
            }

            return integer
        }

        private static func isOptionalText(_ value: DatabaseValue) -> Bool {
            switch value.storage {
            case .null,
                 .string:
                true
            default:
                false
            }
        }

        private static func isOptionalInteger(_ value: DatabaseValue) -> Bool {
            switch value.storage {
            case .null,
                 .int64:
                true
            default:
                false
            }
        }

        private static func isOptionalNumber(_ value: DatabaseValue) -> Bool {
            switch value.storage {
            case .null,
                 .int64:
                true
            case let .double(number):
                number.isFinite
            default:
                false
            }
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
