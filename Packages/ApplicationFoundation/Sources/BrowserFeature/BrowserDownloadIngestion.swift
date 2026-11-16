//
//  BrowserDownloadIngestion.swift
//  MediaVault
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import MediaLibrary

/// Transfers verified terminal files into shared durable ingestion without granting authentication.
/// Tests inject this boundary to exercise browser ownership without opening the Library database.
@MainActor
struct BrowserDownloadIngestion {
    var accept: @MainActor (URL, UUID, String) async throws -> Void
    var reconcile: @MainActor (UInt64) async -> [UUID: CompletedDownloadOutcome]
    /// Revokes one pending operation before asynchronous cleanup can wait behind reconciliation.
    var revoke: @MainActor (UUID) -> Void
    var discard: @MainActor (UUID) async throws -> Void
    var storage: @MainActor () async throws -> AcceptedDownloadStorage
    var generation: @MainActor () -> UInt64
    var presentationURL: @MainActor (UUID, UInt64) async throws -> URL?

    static var live: Self {
        let library = MediaLibraryClient.liveValue
        return Self(
            accept: { try await library.acceptCompletedDownload($0, operationID: $1, originalFilename: $2) },
            reconcile: { await library.reconcileAcceptedDownloads(generation: $0) },
            revoke: { library.revokeAcceptedDownload(operationID: $0) },
            discard: { try await library.discardAcceptedDownload(operationID: $0) },
            storage: { try await library.acceptedDownloadStorage() },
            generation: { library.currentDownloadIngestionGeneration },
            presentationURL: {
                try await library.completedDownloadPresentationURL(operationID: $0, generation: $1)
            },
        )
    }
}
