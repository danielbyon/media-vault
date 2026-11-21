//
//  DownloadInspection.swift
//  MediaVault
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//

#if DEBUG
import Foundation

/// Temporary storage totals and the result of checking the staged file's journal identity.
public struct DownloadStagingEvidence: Equatable, Sendable {
    /// Capacity charged to all temporary operations, including orphans and legacy imports.
    public let storage: AcceptedDownloadStorage
    /// True when the sole charged operation owns a pending journal record and its original staged inode.
    public let hasSingleVerifiedStagedDownload: Bool
    /// Set when the caller supplied an operation ID to match against the single staged download.
    public let matchesOperation: Bool?
}

/// Facts about committed originals read during one authenticated Library inspection.
public struct CanonicalDownloadEvidence: Equatable, Sendable {
    /// Committed asset identifiers in import order.
    public let assetIDs: [UUID]
    /// Number of canonical resource files examined.
    public let resourceCount: Int
    /// Temporary ownership still charged at the time of inspection.
    public let storage: AcceptedDownloadStorage
    /// True when every examined original equals the supplied bytes.
    public let originalBytesMatch: Bool
    /// True when every examined original has the SHA-256 digest recorded at import.
    public let originalHashMatches: Bool
}

struct DownloadInspectionRows: Sendable {
    let assets: [MediaAsset]
    let canonicalPaths: Set<String>
    let entries: [MediaIngestionJournalEntry]
    let downloads: [CompletedDownloadRecord]
}

extension MediaLibraryClient {
    /// Counts temporary ownership and verifies an adopted stage using filesystem metadata.
    /// A generation change invalidates the result, including while the query waits for the store.
    public func inspectDownloadStaging(
        operationID: UUID?,
        resourceGeneration: UInt64,
        ingestionGeneration: UInt64,
    ) async throws -> DownloadStagingEvidence? {
        guard let downloadInspection else {
            throw MediaLibraryStoreError.unavailable
        }

        return try await downloadInspection.read(
            resourceGeneration: resourceGeneration,
            ingestionGeneration: ingestionGeneration,
            requiresAuthentication: false,
        ) { rows, storage, _ in
            var verifiedID: UUID?
            let pending = rows.downloads.filter { $0.status == "pending" }
            if storage.operationCount == 1, pending.count == 1, let record = pending.first,
               record.byteCount > 0, storage.byteCount == record.byteCount {
                let resources = downloadInspection.importer.resources
                try resources.checkStagedDownloadIdentity(
                    at: resources.stagingURL(for: record.operationID),
                    record: record,
                )
                verifiedID = record.operationID
            }
            return DownloadStagingEvidence(
                storage: storage,
                hasSingleVerifiedStagedDownload: verifiedID != nil,
                matchesOperation: operationID.map { $0 == verifiedID },
            )
        }
    }

    /// Compares every committed original to the supplied bytes and its stored SHA-256 digest.
    /// Returns nil if authentication, foreground eligibility, or either generation changes.
    public func inspectCanonicalDownloads(
        matching expectedBytes: Data,
        resourceGeneration: UInt64,
        ingestionGeneration: UInt64,
    ) async throws -> CanonicalDownloadEvidence? {
        guard let downloadInspection else {
            throw MediaLibraryStoreError.unavailable
        }

        return try await downloadInspection.read(
            resourceGeneration: resourceGeneration,
            ingestionGeneration: ingestionGeneration,
            requiresAuthentication: true,
        ) { rows, storage, isCurrent in
            let originals = rows.assets.flatMap(\.resources)
            var bytesMatch = true
            var hashesMatch = true
            for resource in originals {
                guard isCurrent() else {
                    throw CancellationError()
                }

                var remaining = expectedBytes[...]
                let digest = try downloadInspection.importer.resources.readCanonicalResource(
                    resource,
                    isCurrent: isCurrent,
                ) { chunk in
                    if !remaining.prefix(chunk.count).elementsEqual(chunk) {
                        bytesMatch = false
                    }
                    remaining = remaining.dropFirst(chunk.count)
                }
                bytesMatch = bytesMatch && remaining.isEmpty
                hashesMatch = hashesMatch && digest == resource.sha256
            }
            return CanonicalDownloadEvidence(
                assetIDs: rows.assets.map(\.id),
                resourceCount: originals.count,
                storage: storage,
                originalBytesMatch: bytesMatch,
                originalHashMatches: hashesMatch,
            )
        }
    }
}

struct DownloadInspection: Sendable {
    let importer: MediaLibraryImporter
    let fence: MediaLibraryResourceLoadFence

    /// Holds the shared durable-operation gate from the database snapshot through the last file read.
    func read<Value: Sendable>(
        resourceGeneration: UInt64,
        ingestionGeneration: UInt64,
        requiresAuthentication: Bool,
        inspect: @Sendable (DownloadInspectionRows, AcceptedDownloadStorage, @Sendable () -> Bool) throws -> Value,
    ) async throws -> Value? {
        @Sendable
        func isCurrent() -> Bool {
            !Task.isCancelled && fence.permitsInspection(
                resource: resourceGeneration,
                ingestion: ingestionGeneration,
                requiresAuthentication: requiresAuthentication,
            )
        }

        do {
            guard isCurrent() else {
                throw CancellationError()
            }

            let value = try await importer.store.withDurableOperation {
                guard isCurrent() else {
                    throw CancellationError()
                }

                let rows = try await importer.store.downloadInspectionRows(
                    includingAssets: requiresAuthentication,
                    isCurrent: isCurrent,
                )
                guard isCurrent() else {
                    throw CancellationError()
                }

                let storage = try importer.downloadStorage(
                    rows.downloads,
                    entries: rows.entries,
                    canonicalPaths: rows.canonicalPaths,
                )
                guard isCurrent() else {
                    throw CancellationError()
                }

                return try inspect(rows, storage, isCurrent)
            }
            try Task.checkCancellation()
            return isCurrent() ? value : nil
        } catch {
            try Task.checkCancellation()
            guard isCurrent() else {
                return nil
            }

            throw error
        }
    }
}
#endif
