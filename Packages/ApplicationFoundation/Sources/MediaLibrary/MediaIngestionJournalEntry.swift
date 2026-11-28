//
//  MediaIngestionJournalEntry.swift
//  MediaVault
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import GRDB
import SQLiteData
import StructuredQueries
import StructuredQueriesCore

func hasValidJournalOutcome(
    state: MediaIngestionState,
    duplicateDecision: MediaDuplicateDecision?,
    quotaAdmission: MediaQuotaAdmission?,
) -> Bool {
    switch duplicateDecision {
    case .pending:
        return state == .awaitingUserDecision && quotaAdmission == .pending
    case .skipped:
        return state == .cancelled && quotaAdmission == .pending
    case .overridden:
        switch state {
        case .duplicateCheck:
            return quotaAdmission == .pending
        case .ready,
             .committing,
             .complete:
            return quotaAdmission == .admitted
        case .failed:
            return quotaAdmission != nil
        case .received,
             .validating,
             .awaitingUserDecision,
             .cancelled:
            return false
        }
    case nil:
        guard state != .awaitingUserDecision else {
            return false
        }

        switch quotaAdmission {
        case .pending:
            return [.received, .validating, .duplicateCheck, .failed, .cancelled].contains(state)
        case .admitted:
            return [.ready, .committing, .complete, .failed].contains(state)
        case .denied:
            return state == .failed
        case nil:
            return true
        }
    }
}

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

    /// The duplicate choice recorded for this import, if it matched existing content.
    let duplicateDecision: MediaDuplicateDecision?

    /// The quota result recorded after duplicate comparison.
    let quotaAdmission: MediaQuotaAdmission?

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
        duplicateDecision: MediaDuplicateDecision? = nil,
        quotaAdmission: MediaQuotaAdmission? = .pending,
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
        self.duplicateDecision = duplicateDecision
        self.quotaAdmission = quotaAdmission
    }

    func advancing(
        to state: MediaIngestionState,
        inspection: ImageInspection? = nil,
        duplicateDecision: MediaDuplicateDecision? = nil,
        quotaAdmission: MediaQuotaAdmission? = nil,
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
            duplicateDecision: duplicateDecision ?? self.duplicateDecision,
            quotaAdmission: quotaAdmission ?? self.quotaAdmission,
        )
    }
}

struct MediaIngestionJournalSnapshot: Sendable {
    /// Journal entries whose persisted fields passed safe decoding.
    let entries: [MediaIngestionJournalEntry]

    /// Asset IDs whose rows could not be decoded and must stay hidden if committed.
    let unreadableAssetIDs: Set<UUID>

    /// Whether any row lacks a usable asset identifier and cannot be reconciled by ID.
    let hasUnidentifiedAssetRows: Bool

    /// Resource IDs present in any row, including rows that could not be decoded.
    let knownResourceIDs: Set<UUID>
}

/// Persists journal state in the vault database without exposing transitions to callers.
actor SQLiteMediaLibraryIngestionJournal {
    private let database: any DatabaseWriter
    private var beforeAcceptanceWriteForTesting: @Sendable () async -> Void = {}

    init(database: any DatabaseWriter) {
        self.database = database
    }

    func setBeforeAcceptanceWriteForTesting(_ operation: @escaping @Sendable () async -> Void) {
        beforeAcceptanceWriteForTesting = operation
    }

    func accept(_ entry: MediaIngestionJournalEntry) async throws {
        try await persistAcceptedEntry(entry)
    }

    func accept(
        _ entry: MediaIngestionJournalEntry,
        admittedBy admission: MediaLibraryImportAdmission,
        sessionGeneration: UInt64?,
    ) async throws {
        guard admission.matches(sessionGeneration) else {
            throw MediaLibraryStoreError.corrupt
        }

        try await persistAcceptedEntry(entry)
    }

    private func persistAcceptedEntry(_ entry: MediaIngestionJournalEntry) async throws {
        guard entry.state == .received,
              entry.sourceUTI == nil,
              entry.byteCount == nil,
              entry.sha256 == nil,
              entry.duplicateDecision == nil,
              entry.quotaAdmission == .pending
        else {
            throw MediaLibraryStoreError.corrupt
        }

        do {
            try await prepareSchema()
            await beforeAcceptanceWriteForTesting()
            try await database.write { db in
                try db.execute(
                    sql: """
                    INSERT INTO media_ingestion_journal (
                      id, resource_id, state, source_filename, imported_at,
                      source_uti, byte_count, sha256, captured_at,
                      duplicate_decision, quota_admission
                    ) VALUES (?, ?, ?, ?, ?, NULL, NULL, NULL, NULL, NULL, ?)
                    """,
                    arguments: [
                        entry.id.uuidString,
                        entry.resourceID.uuidString,
                        entry.state.rawValue,
                        entry.sourceFilename,
                        entry.importedAt.timeIntervalSince1970,
                        MediaQuotaAdmission.pending.rawValue,
                    ],
                )
            }
        } catch is CancellationError {
            throw CancellationError()
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
                      source_uti, byte_count, sha256, captured_at,
                      duplicate_decision, quota_admission
                    ) VALUES (?, ?, ?, ?, ?, NULL, NULL, NULL, NULL, NULL, ?)
                    """,
                    arguments: [
                        entry.id.uuidString,
                        entry.resourceID.uuidString,
                        entry.state.rawValue,
                        entry.sourceFilename,
                        entry.importedAt.timeIntervalSince1970,
                        MediaQuotaAdmission.pending.rawValue,
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
        duplicateDecision: MediaDuplicateDecision? = nil,
        quotaAdmission: MediaQuotaAdmission? = nil,
    ) async throws -> MediaIngestionJournalEntry {
        guard Self.canAdvance(from: entry.state, to: state) else {
            throw MediaLibraryStoreError.corrupt
        }

        let updated = entry.advancing(
            to: state,
            inspection: inspection,
            duplicateDecision: duplicateDecision,
            quotaAdmission: quotaAdmission,
        )
        guard hasValidJournalOutcome(
            state: updated.state,
            duplicateDecision: updated.duplicateDecision,
            quotaAdmission: updated.quotaAdmission,
        ) else {
            throw MediaLibraryStoreError.corrupt
        }

        do {
            return try await database.write { db -> MediaIngestionJournalEntry in
                let row = try #sql(
                    """
                    SELECT id, resource_id, state, source_filename, imported_at,
                           source_uti, byte_count, sha256, captured_at,
                           duplicate_decision, quota_admission
                    FROM media_ingestion_journal
                    WHERE id = \(bind: entry.id.uuidString)
                    """,
                    as: (String, String, String, String, Double, String?, Int64?, String?, Double?, String?, String?)
                        .self,
                ).fetchOne(db)
                guard let row,
                      let persistedID = UUID(uuidString: row.0),
                      let persistedResourceID = UUID(uuidString: row.1),
                      let persistedState = MediaIngestionState(rawValue: row.2),
                      row.9 == nil || row.9.flatMap(MediaDuplicateDecision.init(rawValue:)) != nil,
                      row.10 == nil || row.10.flatMap(MediaQuotaAdmission.init(rawValue:)) != nil
                else {
                    throw MediaLibraryStoreError.corrupt
                }

                let persisted = MediaIngestionJournalEntry(
                    id: persistedID,
                    resourceID: persistedResourceID,
                    state: persistedState,
                    sourceFilename: row.3,
                    importedAt: Date(timeIntervalSince1970: row.4),
                    sourceUTI: row.5,
                    byteCount: row.6,
                    sha256: row.7,
                    capturedAt: row.8.map(Date.init(timeIntervalSince1970:)),
                    duplicateDecision: row.9.flatMap(MediaDuplicateDecision.init(rawValue:)),
                    quotaAdmission: row.10.flatMap(MediaQuotaAdmission.init(rawValue:)),
                )
                let hasValidationMetadata = row.5 != nil && row.6 != nil && row.7 != nil
                let hasPartialValidationMetadata = row.5 != nil || row.6 != nil || row.7 != nil
                let requiresValidationMetadata = [.duplicateCheck, .ready, .committing, .complete]
                    .contains(persistedState)
                guard !row.3.isEmpty,
                      !hasPartialValidationMetadata || hasValidationMetadata,
                      !hasValidationMetadata || (row.6 ?? -1) >= 0,
                      !hasValidationMetadata || row.7?.count == 64,
                      !requiresValidationMetadata || hasValidationMetadata,
                      hasValidJournalOutcome(
                          state: persisted.state,
                          duplicateDecision: persisted.duplicateDecision,
                          quotaAdmission: persisted.quotaAdmission,
                      )
                else {
                    throw MediaLibraryStoreError.corrupt
                }

                let sameJournalIdentity = persisted.id == entry.id
                    && persisted.resourceID == entry.resourceID
                    && persisted.sourceFilename == entry.sourceFilename
                    && persisted.importedAt == entry.importedAt
                if persisted.state == updated.state,
                   persisted.duplicateDecision == updated.duplicateDecision,
                   persisted.quotaAdmission == updated.quotaAdmission,
                   sameJournalIdentity {
                    return persisted
                }
                guard persisted == entry else {
                    throw MediaLibraryStoreError.corrupt
                }

                try db.execute(
                    sql: """
                    UPDATE media_ingestion_journal
                    SET state = ?, source_uti = ?, byte_count = ?, sha256 = ?, captured_at = ?,
                        duplicate_decision = ?, quota_admission = ?
                    WHERE id = ? AND state = ?
                      AND duplicate_decision IS ? AND quota_admission IS ?
                    """,
                    arguments: [
                        state.rawValue,
                        updated.sourceUTI,
                        updated.byteCount,
                        updated.sha256,
                        updated.capturedAt?.timeIntervalSince1970,
                        updated.duplicateDecision?.rawValue,
                        updated.quotaAdmission?.rawValue,
                        entry.id.uuidString,
                        entry.state.rawValue,
                        entry.duplicateDecision?.rawValue,
                        entry.quotaAdmission?.rawValue,
                    ],
                )
                guard db.changesCount == 1 else {
                    throw MediaLibraryStoreError.corrupt
                }

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
                       source_uti, byte_count, sha256, captured_at,
                       duplicate_decision, quota_admission
                FROM media_ingestion_journal
                ORDER BY imported_at, id
                """)
                return try Row.fetchAll(statement).map(DecodedJournalRow.init)
            }

            var entries: [MediaIngestionJournalEntry] = []
            var unreadableAssetIDs = Set<UUID>()
            var hasUnidentifiedAssetRows = false
            var knownResourceIDs = Set<UUID>()
            for row in rows {
                if let resourceID = row.resourceID {
                    knownResourceIDs.insert(resourceID)
                }
                guard let assetID = row.assetID else {
                    hasUnidentifiedAssetRows = true
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
                hasUnidentifiedAssetRows: hasUnidentifiedAssetRows,
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
            let duplicateDecisionValue: DatabaseValue = row[9]
            let quotaAdmissionValue: DatabaseValue = row[10]

            let decodedAssetID = Self.textValue(assetIDValue).flatMap { UUID(uuidString: $0) }
            let decodedResourceID = Self.textValue(resourceIDValue).flatMap { UUID(uuidString: $0) }
            assetID = decodedAssetID
            resourceID = decodedResourceID

            guard let decodedAssetID,
                  let decodedResourceID,
                  let stateRawValue = Self.textValue(stateValue),
                  let state = MediaIngestionState(rawValue: stateRawValue),
                  let sourceFilename = Self.textValue(sourceFilenameValue),
                  !sourceFilename.isEmpty,
                  let importedAt = Self.numberValue(importedAtValue),
                  Self.isOptionalText(sourceUTIValue),
                  Self.isOptionalInteger(byteCountValue),
                  Self.isOptionalText(sha256Value),
                  Self.isOptionalNumber(capturedAtValue),
                  Self.isOptionalText(duplicateDecisionValue),
                  Self.isOptionalText(quotaAdmissionValue)
            else {
                entry = nil
                return
            }

            let sourceUTI = Self.textValue(sourceUTIValue)
            let byteCount = Self.integerValue(byteCountValue)
            let sha256 = Self.textValue(sha256Value)
            let capturedAt = Self.numberValue(capturedAtValue)
            let duplicateDecisionRawValue = Self.textValue(duplicateDecisionValue)
            let quotaAdmissionRawValue = Self.textValue(quotaAdmissionValue)
            let duplicateDecision = duplicateDecisionRawValue.flatMap(MediaDuplicateDecision.init(rawValue:))
            let quotaAdmission = quotaAdmissionRawValue.flatMap(MediaQuotaAdmission.init(rawValue:))
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
                  !requiresValidationMetadata || hasValidationMetadata,
                  duplicateDecisionRawValue == nil || duplicateDecision != nil,
                  quotaAdmissionRawValue == nil || quotaAdmission != nil,
                  hasValidJournalOutcome(
                      state: state,
                      duplicateDecision: duplicateDecision,
                      quotaAdmission: quotaAdmission,
                  )
            else {
                entry = nil
                return
            }

            entry = MediaIngestionJournalEntry(
                id: decodedAssetID,
                resourceID: decodedResourceID,
                state: state,
                sourceFilename: sourceFilename,
                importedAt: Date(timeIntervalSince1970: importedAt),
                sourceUTI: sourceUTI,
                byteCount: byteCount,
                sha256: sha256,
                capturedAt: capturedAt.map(Date.init(timeIntervalSince1970:)),
                duplicateDecision: duplicateDecision,
                quotaAdmission: quotaAdmission,
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
                      duplicate_decision TEXT CHECK (
                        duplicate_decision IS NULL OR duplicate_decision IN ('pending', 'skipped', 'overridden')
                      ),
                      quota_admission TEXT CHECK (
                        quota_admission IS NULL OR quota_admission IN ('pending', 'admitted', 'denied')
                      ),
                      CHECK (
                        (source_uti IS NULL AND byte_count IS NULL AND sha256 IS NULL)
                        OR (source_uti IS NOT NULL AND byte_count IS NOT NULL AND sha256 IS NOT NULL)
                      )
                    )
                    """,
                )

                let columns = try Set(db.columns(in: "media_ingestion_journal").map(\.name))
                if !columns.contains("duplicate_decision") {
                    try db.execute(
                        sql: """
                        ALTER TABLE media_ingestion_journal
                        ADD COLUMN duplicate_decision TEXT CHECK (
                          duplicate_decision IS NULL OR duplicate_decision IN ('pending', 'skipped', 'overridden')
                        )
                        """,
                    )
                }
                if !columns.contains("quota_admission") {
                    try db.execute(
                        sql: """
                        ALTER TABLE media_ingestion_journal
                        ADD COLUMN quota_admission TEXT CHECK (
                          quota_admission IS NULL OR quota_admission IN ('pending', 'admitted', 'denied')
                        )
                        """,
                    )
                }
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
             (.awaitingUserDecision, .duplicateCheck),
             (.ready, .committing):
            true
        default:
            false
        }
    }
}
