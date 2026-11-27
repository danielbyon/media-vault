//
//  MediaLibraryClientTests.swift
//  MediaVault
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
@_spi(Testing) @testable import MediaLibrary

@Suite("Media library client session fence")
struct MediaLibraryClientTests {
    @Test("Current session imports use the session-aware operation")
    func currentSessionImportUsesSessionAwareOperation() async throws {
        let probe = MediaLibraryClientCallProbe()
        let sourceURL = URL(fileURLWithPath: "/tmp/duplicate.png")
        let request = MediaDuplicateDecisionRequest(
            id: UUID(),
            sourceFilename: "duplicate.png",
            importedAt: Date(timeIntervalSince1970: 1_725_000_000),
        )
        let client = makeMediaLibraryClient(
            importFileOutcomeForSession: { url, generation in
                await probe.record(.importOutcome(url, generation))
                return .duplicatePending(request)
            },
            resolveDuplicateDecisionForSession: { id, choice, generation in
                await probe.record(.resolveDuplicateDecision(id, choice, generation))
                return .skipped
            },
        )

        let outcome = try await client.importFileOutcomeIfCurrent(sourceURL, generation: 0)

        #expect(outcome == .duplicatePending(request))
        #expect(await probe.calls() == [.importOutcome(sourceURL, 0)])
    }

    @Test("A stale session cannot start an import")
    func staleSessionCannotStartImport() async {
        let probe = MediaLibraryClientCallProbe()
        let sourceURL = URL(fileURLWithPath: "/tmp/duplicate.png")
        let client = makeMediaLibraryClient(
            importFileOutcomeForSession: { url, generation in
                await probe.record(.importOutcome(url, generation))
                throw MediaImportError.persistenceFailed
            },
            resolveDuplicateDecisionForSession: { id, choice, generation in
                await probe.record(.resolveDuplicateDecision(id, choice, generation))
                return .skipped
            },
        )

        client.advanceResourceLoadGeneration()

        await #expect(throws: CancellationError.self) {
            try await client.importFileOutcomeIfCurrent(sourceURL, generation: 0)
        }
        #expect(await probe.calls().isEmpty)
    }

    @Test("Current session decisions use the session-aware operation")
    func currentSessionDecisionUsesSessionAwareOperation() async throws {
        let probe = MediaLibraryClientCallProbe()
        let decisionID = UUID()
        let client = makeMediaLibraryClient(
            importFileOutcomeForSession: { _, _ in
                throw MediaImportError.persistenceFailed
            },
            resolveDuplicateDecisionForSession: { id, choice, generation in
                await probe.record(.resolveDuplicateDecision(id, choice, generation))
                return .skipped
            },
        )

        let result = try await client.resolveDuplicateDecisionIfCurrent(
            decisionID,
            choice: .skip,
            generation: 0,
        )

        #expect(result == .skipped)
        #expect(await probe.calls() == [.resolveDuplicateDecision(decisionID, .skip, 0)])
    }

    @Test("A stale session cannot resolve a duplicate decision")
    func staleSessionCannotResolveDuplicateDecision() async {
        let probe = MediaLibraryClientCallProbe()
        let decisionID = UUID()
        let client = makeMediaLibraryClient(
            importFileOutcomeForSession: { _, _ in
                throw MediaImportError.persistenceFailed
            },
            resolveDuplicateDecisionForSession: { id, choice, generation in
                await probe.record(.resolveDuplicateDecision(id, choice, generation))
                return .skipped
            },
        )

        client.advanceResourceLoadGeneration()

        await #expect(throws: CancellationError.self) {
            try await client.resolveDuplicateDecisionIfCurrent(
                decisionID,
                choice: .skip,
                generation: 0,
            )
        }
        #expect(await probe.calls().isEmpty)
    }
}

private func makeMediaLibraryClient(
    resourceLoadFence: MediaLibraryResourceLoadFence = MediaLibraryResourceLoadFence(),
    importFileOutcomeForSession: @escaping @Sendable (URL, UInt64) async throws -> MediaImportOutcome,
    resolveDuplicateDecisionForSession: @escaping @Sendable (
        UUID,
        MediaDuplicateDecisionChoice,
        UInt64,
    ) async throws -> MediaDuplicateResolutionResult,
) -> MediaLibraryClient {
    MediaLibraryClient(
        loadAssets: { [] },
        loadLibrarySnapshot: { MediaLibrarySnapshot(assets: []) },
        importFile: { _ in throw MediaImportError.persistenceFailed },
        importFileOutcome: { _ in throw MediaImportError.persistenceFailed },
        resolveDuplicateDecision: { _, _ in throw MediaImportError.persistenceFailed },
        resourceData: { _ in Data() },
        resourceDataSynchronously: nil,
        resourceLoadFence: resourceLoadFence,
        importFileOutcomeForSession: importFileOutcomeForSession,
        resolveDuplicateDecisionForSession: resolveDuplicateDecisionForSession,
    )
}

private actor MediaLibraryClientCallProbe {
    enum Call: Equatable, Sendable {
        case importOutcome(URL, UInt64)
        case resolveDuplicateDecision(UUID, MediaDuplicateDecisionChoice, UInt64)
    }

    private var recordedCalls: [Call] = []

    func record(_ call: Call) {
        recordedCalls.append(call)
    }

    func calls() -> [Call] {
        recordedCalls
    }
}
