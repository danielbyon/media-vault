//
//  MediaLibraryImporter+CompletedDownload.swift
//  MediaVault
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Entitlement
import Foundation

extension MediaLibraryImporter {
    /// Resolves only verified canonical resources or unsupported staging retained by this process.
    public func completedDownloadPresentationURL(operationID: UUID, generation: UInt64) async throws -> URL? {
        guard downloadSessionIsCurrent(generation) else {
            return nil
        }

        do {
            let url = try await store.withDurableOperation {
                try await self.presentationURLWhileGated(operationID: operationID, generation: generation)
            }
            return downloadSessionIsCurrent(generation) ? url : nil
        } catch {
            guard downloadSessionIsCurrent(generation) else {
                return nil
            }

            throw error
        }
    }

    private func presentationURLWhileGated(operationID: UUID, generation: UInt64) async throws -> URL? {
        guard downloadSessionIsCurrent(generation) else {
            return nil
        }

        let records = try await store.ingestionJournal.downloadRecords()
        guard downloadSessionIsCurrent(generation),
              let record = records.first(where: { $0.operationID == operationID }) else {
            return nil
        }

        if record.status == "unsupported" {
            guard retainedDownloadIDs.contains(operationID) else {
                return nil
            }

            let url = resources.stagingURL(for: operationID)
            try resources.verifyDownloadIdentity(at: url, record: record)
            return downloadSessionIsCurrent(generation) ? url : nil
        }
        guard record.status == "imported" || record.status == "duplicate",
              let canonicalID = record.canonicalID else {
            return nil
        }

        let assets = try await store.loadAssets()
        guard downloadSessionIsCurrent(generation) else {
            return nil
        }
        guard let asset = assets.first(where: { $0.id == canonicalID }),
              asset.resources.count == 1, let resource = asset.resources.first,
              resource.role == .original else {
            throw MediaLibraryStoreError.corrupt
        }

        let url = try resources.verifiedPresentationURL(for: resource) {
            self.downloadSessionIsCurrent(generation)
        }
        return downloadSessionIsCurrent(generation) ? url : nil
    }

    /// Adopts caller-verified completed bytes without requiring current authentication.
    public func acceptCompletedDownload(_ url: URL, operationID: UUID, originalFilename: String) async throws {
        do {
            try await store.withDurableOperation {
                try await self.acceptDownloadWhileGated(url, operationID: operationID, filename: originalFilename)
            }
        } catch let error as CompletedDownloadAcceptanceError {
            throw error
        } catch {
            throw CompletedDownloadAcceptanceError.ownershipUncertain
        }
    }

    private func acceptDownloadWhileGated(_ url: URL, operationID: UUID, filename: String) async throws {
        let records = try await store.ingestionJournal.downloadRecords()
        if let existing = records.first(where: { $0.operationID == operationID }) {
            try await resumeAcceptedDownload(existing)
            retainedDownloadIDs.insert(operationID)
            return
        }
        guard !filename.isEmpty else {
            throw CompletedDownloadAcceptanceError.unsafeSource
        }

        let identity = try resources.completedDownloadIdentity(at: url, operationID: operationID)
        guard identity.byteCount > 0 else {
            throw CompletedDownloadAcceptanceError.emptyFile
        }
        guard identity.byteCount <= downloadLimits.itemBytes else {
            throw CompletedDownloadAcceptanceError.itemTooLarge
        }

        let storage = try await downloadStorage(records)
        guard storage.operationCount < 8 else {
            throw CompletedDownloadAcceptanceError.stagingCapacityExceeded
        }
        guard identity.byteCount <= downloadLimits.aggregateBytes,
              storage.byteCount <= downloadLimits.aggregateBytes - identity.byteCount else {
            throw CompletedDownloadAcceptanceError.stagingCapacityExceeded
        }

        let available = try availableDownloadBytesForTesting?() ?? resources.availableDownloadBytes()
        guard available >= downloadLimits.freeBytes else {
            throw CompletedDownloadAcceptanceError.insufficientStorage
        }

        try await persistAndAdoptDownload(url, operationID: operationID, filename: filename, identity: identity)
    }

    private func resumeAcceptedDownload(_ record: CompletedDownloadRecord) async throws {
        do {
            if record.status == "adopting" {
                try resources.finishDownloadHandoff(record)
                try await store.ingestionJournal.updateDownload(record.operationID, status: "pending")
            }
        } catch { throw CompletedDownloadAcceptanceError.ownershipUncertain }
    }

    private func persistAndAdoptDownload(
        _ url: URL,
        operationID: UUID,
        filename: String,
        identity: DownloadFileIdentity,
    ) async throws {
        do {
            // The intent is written before rename so either path can be recovered without guessing.
            try await store.ingestionJournal.beginDownloadHandoff(
                operationID: operationID,
                sourceURL: url,
                filename: filename,
                byteCount: identity.byteCount,
                device: identity.device,
                inode: identity.inode,
                acceptedAt: now(),
            )
            try afterDownloadIntentForTesting()
            let record = CompletedDownloadRecord(
                operationID: operationID,
                sourcePath: url.path,
                byteCount: identity.byteCount,
                device: identity.device,
                inode: identity.inode,
                status: "adopting",
                canonicalID: nil,
            )
            try resources.finishDownloadHandoff(record)
            try afterDownloadRenameForTesting()
            try await store.ingestionJournal.updateDownload(operationID, status: "pending")
            retainedDownloadIDs.insert(operationID)
        } catch { throw CompletedDownloadAcceptanceError.ownershipUncertain }
    }

    /// Recovers interrupted ownership and inventories shared temporary capacity without validating media.
    public func acceptedDownloadStorage() async throws -> AcceptedDownloadStorage {
        try await store.withDurableOperation {
            let records = try await self.store.ingestionJournal.downloadRecords()
            try await self.recoverDownloadOwnership(records)
            return try await self.downloadStorage(records)
        }
    }

    /// Completes filesystem ownership before the native scratch owner may purge its old root.
    /// This operation does not validate media, decide quota, or grant presentation access.
    private func recoverDownloadOwnership(_ records: [CompletedDownloadRecord]) async throws {
        for record in records where record.status == "adopting" {
            try resources.finishDownloadHandoff(record)
            try await store.ingestionJournal.updateDownload(record.operationID, status: "pending")
        }
    }

    /// Counts shared temporary ownership without decoding media or renewing legacy admission.
    /// Existing over-budget work is grandfathered; only fresh browser acceptance uses the limits.
    private func downloadStorage(_ records: [CompletedDownloadRecord]) async throws -> AcceptedDownloadStorage {
        let snapshot = try await store.ingestionJournal.snapshot()
        guard !snapshot.hasUnidentifiedAssetRows, snapshot.unreadableAssetIDs.isEmpty else {
            throw MediaLibraryStoreError.corrupt
        }

        let assets = try await store.loadAssets()
        return try downloadStorage(records, entries: snapshot.entries, canonicalPaths: Self.canonicalPaths(for: assets))
    }

    static func canonicalPaths(for assets: [MediaAsset]) throws -> Set<String> {
        let canonicalResources = assets.flatMap(\.resources)
        guard canonicalResources.allSatisfy({ $0.relativePath == $0.id.uuidString.lowercased() }) else {
            throw MediaLibraryStoreError.corrupt
        }

        return Set(canonicalResources.map(\.relativePath))
    }

    /// Applies the same capacity rules to journal and canonical rows captured by the caller.
    nonisolated func downloadStorage(
        _ records: [CompletedDownloadRecord],
        entries: [MediaIngestionJournalEntry],
        canonicalPaths: Set<String>,
    ) throws -> AcceptedDownloadStorage {
        let inventory = try resources.temporaryResourceInventory(excluding: canonicalPaths)
        var bytesByOperation: [String: Int64] = [:]
        for item in inventory {
            let sum = (bytesByOperation[item.operationKey] ?? 0).addingReportingOverflow(item.byteCount)
            guard !sum.overflow else {
                throw MediaLibraryStoreError.corrupt
            }

            bytesByOperation[item.operationKey] = sum.partialValue
        }
        let browserIDs = Set(records.map(\.operationID))
        for entry in entries where !browserIDs.contains(entry.id) {
            switch entry.state {
            case .received,
                 .validating,
                 .duplicateCheck,
                 .ready,
                 .committing,
                 .awaitingUserDecision:
                // Missing legacy bytes still retain an unresolved temporary-operation slot.
                let key = entry.resourceID.uuidString.lowercased()
                if !canonicalPaths.contains(key) {
                    bytesByOperation[key] = bytesByOperation[key] ?? 0
                }
            case .complete,
                 .failed,
                 .cancelled:
                break
            }
        }
        for record in records where ["adopting", "pending", "unsupported"].contains(record.status) {
            let key = record.operationID.uuidString.lowercased()
            // An adopting source remains outside the resource root until its rename completes.
            // Its durable reservation is charged without double-counting an already moved file.
            if !canonicalPaths.contains(key) {
                bytesByOperation[key] = max(bytesByOperation[key] ?? 0, record.byteCount)
            }
        }
        var bytes: Int64 = 0
        for count in bytesByOperation.values {
            let sum = bytes.addingReportingOverflow(count)
            guard !sum.overflow else {
                throw MediaLibraryStoreError.corrupt
            }

            bytes = sum.partialValue
        }
        return AcceptedDownloadStorage(operationCount: bytesByOperation.count, byteCount: bytes)
    }

    /// Reconciles browser-owned work only while authentication and foreground eligibility remain current.
    public func reconcileAcceptedDownloads(generation: UInt64) async -> [UUID: CompletedDownloadOutcome] {
        guard downloadSessionIsCurrent(generation) else {
            return [:]
        }

        do {
            return try await store.withDurableOperation {
                await self.reconcileDownloadsWhileGated(generation: generation)
            }
        } catch { return [:] }
    }

    private func reconcileDownloadsWhileGated(generation: UInt64) async -> [UUID: CompletedDownloadOutcome] {
        guard downloadSessionIsCurrent(generation),
              let records = try? await store.ingestionJournal.downloadRecords() else {
            return [:]
        }

        var outcomes: [UUID: CompletedDownloadOutcome] = [:]
        for record in records {
            guard downloadSessionIsCurrent(generation) else {
                return [:]
            }

            do {
                outcomes[record.operationID] = try await reconcileDownload(record, generation: generation)
            } catch is CancellationError {
                guard downloadSessionIsCurrent(generation), !Task.isCancelled else {
                    return [:]
                }

                outcomes[record.operationID] = .pending
            } catch let error as MediaImportError {
                outcomes[record.operationID] = .failed(error)
            } catch {
                outcomes[record.operationID] = .failed(.persistenceFailed)
            }
        }
        return downloadSessionIsCurrent(generation) ? outcomes : [:]
    }

    private func requireDownloadSession(_ generation: UInt64) throws {
        guard downloadSessionIsCurrent(generation) else {
            throw CancellationError()
        }
    }

    private func reconcileDownload(
        _ record: CompletedDownloadRecord,
        generation: UInt64,
    ) async throws -> CompletedDownloadOutcome? {
        let operationID = record.operationID
        let stage = resources.stagingURL(for: operationID)
        if record.status == "discarded" {
            try await store.ingestionJournal.compactDiscardedDownload(operationID)
            return nil
        }
        if record.status == "discarding" {
            try cleanupDownloadTemporaryBytes(record)
            try await store.ingestionJournal.updateDownload(operationID, status: "discarded")
            try await store.ingestionJournal.compactDiscardedDownload(operationID)
            return nil
        }
        if record.status == "imported" || record.status == "duplicate" {
            let assets = try await store.loadAssets()
            try requireDownloadSession(generation)
            guard let asset = assets.first(where: { $0.id == record.canonicalID }) else {
                throw MediaLibraryStoreError.corrupt
            }

            return try await terminalDownloadOutcome(record, asset: asset, generation: generation)
        }
        if record.status == "adopting" {
            try resources.finishDownloadHandoff(record)
            try await store.ingestionJournal.updateDownload(operationID, status: "pending")
            try requireDownloadSession(generation)
        }
        if record.status == "unsupported" {
            try resources.verifyDownloadIdentity(at: stage, record: record)
            return try await retainOrDiscardUnsupported(record)
        }
        return try await resumeDownloadEntry(record, generation: generation)
    }

    private func resumeDownloadEntry(
        _ record: CompletedDownloadRecord,
        generation: UInt64,
    ) async throws -> CompletedDownloadOutcome? {
        let operationID = record.operationID
        let snapshot = try await store.ingestionJournal.snapshot()
        try requireDownloadSession(generation)
        guard var entry = snapshot.entries.first(where: { $0.id == operationID }) else {
            throw MediaLibraryStoreError.corrupt
        }

        if entry.state == .complete {
            let assets = try await store.loadAssets()
            try requireDownloadSession(generation)
            guard let asset = assets.first(where: { $0.id == operationID })
            else {
                throw MediaLibraryStoreError.corrupt
            }

            try await store.ingestionJournal.updateDownload(operationID, status: "imported", canonicalID: asset.id)
            return try await terminalDownloadOutcome(
                terminalRecord(record, status: "imported", canonicalID: asset.id),
                asset: asset,
                generation: generation,
            )
        }
        if entry.state == .received {
            entry = try await store.ingestionJournal.transition(entry, to: .validating)
            try requireDownloadSession(generation)
        }
        if entry.state == .validating {
            guard let inspection = try await validateDownload(record, generation: generation) else {
                return try await retainOrDiscardUnsupported(record)
            }

            entry = try await store.ingestionJournal.transition(entry, to: .duplicateCheck, inspection: inspection)
            try requireDownloadSession(generation)
        }
        return try await commitDownload(entry, record: record, generation: generation)
    }

    private func validateDownload(
        _ record: CompletedDownloadRecord,
        generation: UInt64,
    ) async throws -> ImageInspection? {
        let stage = resources.stagingURL(for: record.operationID)
        try resources.verifyDownloadIdentity(at: stage, record: record)
        let inspection: ImageInspection
        do { inspection = try await inspectStillImage(at: stage) }
        catch let error as MediaImportError where error == .unsupportedMedia || error == .unrenderableMedia {
            try requireDownloadSession(generation)
            try await store.ingestionJournal.updateDownload(record.operationID, status: "unsupported")
            return nil
        }
        try requireDownloadSession(generation)
        return inspection
    }

    private func commitDownload(
        _ initialEntry: MediaIngestionJournalEntry,
        record: CompletedDownloadRecord,
        generation: UInt64,
    ) async throws -> CompletedDownloadOutcome? {
        var entry = initialEntry
        let operationID = record.operationID
        let stage = resources.stagingURL(for: operationID)
        guard [MediaIngestionState.duplicateCheck, .ready, .committing].contains(entry.state) else {
            throw MediaLibraryStoreError.corrupt
        }

        let committedAssets = try await store.loadAssets()
        try requireDownloadSession(generation)
        let candidate = try makeAsset(from: entry)
        if !committedAssets.contains(where: { $0.id == operationID }),
           let duplicate = committedAssets.first(where: { Self.haveIdenticalOriginalResources($0, candidate) }) {
            try await claimDownloadTransaction(operationID, generation: generation)
            try await store.ingestionJournal.completeDuplicate(operationID, canonicalID: duplicate.id, download: true)
            return try await terminalDownloadOutcome(
                terminalRecord(record, status: "duplicate", canonicalID: duplicate.id),
                asset: duplicate,
                generation: generation,
            )
        }
        if !committedAssets.contains(where: { $0.id == operationID }) {
            try await requireAdmissionForCompletedDownload(
                operationID: operationID,
                committedAssets: committedAssets,
                generation: generation,
            )
            try requireDownloadSession(generation)
        }
        if entry.state == .duplicateCheck {
            // Only quota-approved browser work may reserve a ready slot across interruption.
            entry = try await store.ingestionJournal.transition(entry, to: .ready)
            try requireDownloadSession(generation)
        }
        try await claimDownloadTransaction(operationID, generation: generation)
        // Claim and Lock share a mutex. Once claimed, only this transaction may finish after Lock.
        if entry.state == .ready {
            entry = try await store.ingestionJournal.transition(entry, to: .committing)
        }
        let asset = try makeAsset(from: entry)
        guard let resource = asset.resources.first else {
            throw MediaLibraryStoreError.corrupt
        }

        _ = try resources.promoteOrVerify(
            stagingURL: stage,
            resourceID: entry.resourceID,
            byteCount: resource.byteCount,
            sha256: resource.sha256,
        )
        try await store.commit(asset, completingIngestion: entry.id)
        try await store.ingestionJournal.updateDownload(operationID, status: "imported", canonicalID: asset.id)
        // Lock may win after the final claim; canonical commit is already authorized, presentation is not.
        guard downloadSessionIsCurrent(generation) else {
            return nil
        }

        return try await terminalDownloadOutcome(
            terminalRecord(record, status: "imported", canonicalID: asset.id),
            asset: asset,
            generation: generation,
        )
    }

    /// Reserves admitted pending slots without validating legacy bytes or changing their admission.
    private func requireAdmissionForCompletedDownload(
        operationID: UUID,
        committedAssets: [MediaAsset],
        generation: UInt64,
    ) async throws {
        let snapshot = try await store.ingestionJournal.snapshot()
        try requireDownloadSession(generation)
        guard !snapshot.hasUnidentifiedAssetRows, snapshot.unreadableAssetIDs.isEmpty else {
            throw MediaImportError.persistenceFailed
        }

        let records = try await store.ingestionJournal.downloadRecords()
        try requireDownloadSession(generation)
        let reservations = Self.pendingCanonicalSlotCount(
            snapshot: snapshot,
            records: records,
            committedAssetIDs: Set(committedAssets.map(\.id)),
            excluding: operationID,
        )
        let committedCount: Int
        do { committedCount = try await store.logicalAssetCount() }
        catch {
            try requireDownloadSession(generation)
            throw MediaImportError.libraryUnavailable
        }
        try requireDownloadSession(generation)
        let effectiveCount = committedCount.addingReportingOverflow(reservations)
        guard committedCount >= 0, !effectiveCount.overflow else {
            throw MediaImportError.libraryUnavailable
        }
        guard MediaLibraryQuota.requiresEntitlementLookup(forCommittedAssetCount: effectiveCount.partialValue)
        else {
            return
        }

        let entitlementState: ProEntitlementState
        do { entitlementState = try await entitlement.currentState() }
        catch is CancellationError { throw CancellationError() }
        catch {
            try requireDownloadSession(generation)
            throw MediaImportError.entitlementUnavailable
        }
        try requireDownloadSession(generation)
        guard MediaLibraryQuota.admitsNewImport(
            committedAssetCount: effectiveCount.partialValue,
            entitlementState: entitlementState,
        ) else {
            throw MediaImportError.assetLimitReached
        }
    }

    private static func pendingCanonicalSlotCount(
        snapshot: MediaIngestionJournalSnapshot,
        records: [CompletedDownloadRecord],
        committedAssetIDs: Set<UUID>,
        excluding operationID: UUID,
    ) -> Int {
        let browserRecords = Dictionary(uniqueKeysWithValues: records.map { ($0.operationID, $0) })
        let admittedLegacyStates: [MediaIngestionState] = [.received, .validating, .duplicateCheck, .ready, .committing]
        let admittedBrowserStates: [MediaIngestionState] = [.ready, .committing]
        return snapshot.entries.count(where: { entry in
            guard entry.id != operationID, !committedAssetIDs.contains(entry.id) else {
                return false
            }

            if let browserRecord = browserRecords[entry.id] {
                return browserRecord.status == "pending" && admittedBrowserStates.contains(entry.state)
            }
            return admittedLegacyStates.contains(entry.state)
        })
    }

    private func terminalRecord(
        _ record: CompletedDownloadRecord,
        status: String,
        canonicalID: UUID,
    ) -> CompletedDownloadRecord {
        CompletedDownloadRecord(
            operationID: record.operationID,
            sourcePath: record.sourcePath,
            byteCount: record.byteCount,
            device: record.device,
            inode: record.inode,
            status: status,
            canonicalID: canonicalID,
        )
    }

    private func terminalDownloadOutcome(
        _ record: CompletedDownloadRecord,
        asset: MediaAsset,
        generation: UInt64,
    ) async throws -> CompletedDownloadOutcome? {
        try requireDownloadSession(generation)
        guard asset.resources.count == 1, let resource = asset.resources.first,
              resource.role == .original else {
            throw MediaLibraryStoreError.corrupt
        }

        _ = try resources.verifiedPresentationURL(for: resource) { self.downloadSessionIsCurrent(generation) }
        try requireDownloadSession(generation)
        do { try cleanupDownloadTemporaryBytes(record) }
        catch {
            // Failed cleanup keeps durable ownership and capacity charged for the next attempt.
            return retainedDownloadIDs.contains(record.operationID)
                ? .imported(asset, duplicate: record.status == "duplicate")
                : .failed(.persistenceFailed)
        }
        if !retainedDownloadIDs.contains(record.operationID) {
            try await store.ingestionJournal.compactCompleteEntry(for: record.operationID)
            try requireDownloadSession(generation)
            return nil
        }
        return .imported(asset, duplicate: record.status == "duplicate")
    }

    private func claimDownloadTransaction(_ operationID: UUID, generation: UInt64) async throws {
        await beforeDownloadCommitClaimForTesting()
        guard let claim = downloadCommitClaim(operationID, generation), claim.operationID == operationID else {
            throw CancellationError()
        }

        await afterDownloadCommitClaimForTesting()
    }

    private func retainOrDiscardUnsupported(_ record: CompletedDownloadRecord) async throws
        -> CompletedDownloadOutcome {
        if retainedDownloadIDs.contains(record.operationID) {
            return .unsupported(resources.stagingURL(for: record.operationID))
        }
        try await store.ingestionJournal.updateDownload(record.operationID, status: "discarding")
        try cleanupDownloadTemporaryBytes(record)
        try await store.ingestionJournal.updateDownload(record.operationID, status: "discarded")
        try await store.ingestionJournal.compactDiscardedDownload(record.operationID)
        return .pending
    }

    private func cleanupDownloadTemporaryBytes(_ record: CompletedDownloadRecord) throws {
        try beforeDownloadCleanupForTesting()
        try resources.removeAcceptedDownloadStaging(record.operationID)
        // A duplicate can have reached promotion before a prior process stopped.
        if record.canonicalID != record.operationID {
            try resources.removeUncommittedDownloadFinal(record.operationID)
        }
    }

    /// Compares the complete resource multiset, retaining semantic roles and multiplicity.
    static func haveIdenticalOriginalResources(_ lhs: MediaAsset, _ rhs: MediaAsset) -> Bool {
        func keys(_ asset: MediaAsset) -> [String] {
            asset.resources.map { "\($0.role.rawValue):\($0.sha256)" }.sorted()
        }
        return !lhs.resources.isEmpty && keys(lhs) == keys(rhs)
    }

    /// Removes temporary ownership while preserving any committed canonical asset.
    public func discardAcceptedDownload(operationID: UUID) async throws {
        downloadDiscardRequest(operationID)
        try await store.withDurableOperation {
            try await self.discardDownloadWhileGated(operationID)
        }
    }

    private func discardDownloadWhileGated(_ operationID: UUID) async throws {
        guard let record = try await store.ingestionJournal
            .downloadRecords()
            .first(where: { $0.operationID == operationID })
        else {
            return
        }

        if record.status == "imported" || record.status == "duplicate" || record.status == "discarded" {
            try cleanupDownloadTemporaryBytes(record)
            if record.status == "discarded" {
                try await store.ingestionJournal.compactDiscardedDownload(operationID)
            }
            return
        }
        let snapshot = try await store.ingestionJournal.snapshot()
        // A commit may have completed before its outcome write. Never remove its canonical resource.
        let entry = snapshot.entries.first(where: { $0.id == operationID })
        if entry?.state == .complete {
            return
        }
        // Persist cleanup intent first so a stop between these writes remains recoverable.
        try await store.ingestionJournal.updateDownload(operationID, status: "discarding")
        if let entry, entry.state != .failed, entry.state != .cancelled {
            _ = try await store.ingestionJournal.transition(entry, to: .cancelled)
        }
        if record.status == "adopting",
           FileManager.default.fileExists(atPath: record.sourcePath) {
            try resources.finishDownloadHandoff(record)
        }
        try cleanupDownloadTemporaryBytes(record)
        try await store.ingestionJournal.updateDownload(operationID, status: "discarded")
        try await store.ingestionJournal.compactDiscardedDownload(operationID)
        retainedDownloadIDs.remove(operationID)
    }
}
