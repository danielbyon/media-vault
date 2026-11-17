//
//  BrowserDownloadObservationReceiptTests.swift
//  MediaVault
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//

// swiftformat:options --test-case-name-format preserve

import Foundation
import Testing

extension AppHostedUITests {
    @Suite("Correlated browser observation receipts")
    @MainActor
    struct BrowserDownloadObservationReceiptTests {
        @Test("An inspection stays pending until its fresh snapshot completes")
        func completedInspectionRequiresFreshRead() async {
            let context = BrowserDownloadObservationContext(
                processNonce: UUID(),
                runID: "receipt-test-run",
                authorizationGeneration: 3,
                resourceGeneration: 5,
                ingestionGeneration: 7,
                phase: "authenticated",
            )
            var published: [BrowserDownloadObservationReceipt] = []
            let controller = BrowserDownloadObservationController(
                context: { context },
                publish: { published.append($0) },
            )
            let baseline = controller.receipt
            let inspection = ReceiptInspectionGate()
            let request = Task { @MainActor in
                await controller.refresh { await inspection.read() }
            }
            await inspection.waitUntilStarted()
            #expect(controller.receipt.state == .pending)
            #expect(published.allSatisfy { $0.state != .completed })

            let fresh = BrowserDownloadObservationSnapshot(
                inspection: ["event": "canonicalLibrarySnapshot", "assetCount": "1"],
            )
            inspection.finish(with: fresh)
            let completed = await request.value
            #expect(completed.state == .completed)
            #expect(completed.revision > baseline.revision)
            #expect(completed.request?.sequence == 1)
            #expect(completed.context == context)
            #expect(completed.snapshot == fresh)
            #expect(published.last == completed)
        }

        @Test("Unchanged and pending readouts never supply a completed sample")
        func baselineAndPendingAreNotCompleted() throws {
            let fixture = ReceiptFixture()
            let baseline = fixture.controller.receipt
            #expect(try baseline.validatedSnapshot(
                after: baseline,
                context: fixture.context,
                deadline: .init(start: 100),
                now: 101,
            ) == nil)
            let pending = fixture.receipt(state: .pending, revision: 0)
            #expect(try pending.validatedSnapshot(
                after: baseline,
                context: fixture.context,
                deadline: .init(start: 100),
                now: 101,
            ) == nil)
        }

        @Test("A fresh completed receipt survives JSON transport")
        func freshCompletionValidates() throws {
            let fixture = ReceiptFixture()
            let baseline = fixture.controller.receipt
            let completed = fixture.receipt()
            let wire = try String(decoding: JSONEncoder().encode(completed), as: UTF8.self)
            let decoded = try BrowserDownloadObservationReceipt.decode(wire)
            let snapshot = try decoded.validatedSnapshot(
                after: baseline,
                context: fixture.context,
                deadline: .init(start: 100),
                now: 109,
            )
            #expect(snapshot?.inspection?["assetCount"] == "2")
            #expect(decoded == completed)
        }

        @Test("Every context fence rejects stale readouts", arguments: ReceiptContextField.allCases)
        func changedContextRejectsReceipt(field: ReceiptContextField) {
            let fixture = ReceiptFixture()
            let baseline = fixture.controller.receipt
            let receipt = fixture.receipt()
            fixture.context = changed(field, in: fixture.context)
            #expect(throws: BrowserDownloadObservationError.stale) {
                try receipt.validatedSnapshot(
                    after: baseline,
                    context: fixture.context,
                    deadline: .init(start: 100),
                    now: 101,
                )
            }
        }

        @Test(
            "A producer revalidates every context fence after its suspended read",
            arguments: ReceiptContextField.allCases,
        )
        func suspendedReadCannotCrossContext(field: ReceiptContextField) async {
            let fixture = ReceiptFixture()
            let gate = ReceiptInspectionGate()
            let task = Task { @MainActor in await fixture.controller.refresh { await gate.read() } }
            await gate.waitUntilStarted()
            fixture.context = changed(field, in: fixture.context)
            gate.finish(with: .init(inspection: ["event": "canonicalLibrarySnapshot", "canonicalIDs": "private"]))
            let terminal = await task.value
            #expect(terminal.state == .invalidated)
            #expect(terminal.snapshot.inspection == nil)
            #expect(!fixture.publications.contains { $0.state == .completed })
        }

        @Test("Observed authentication ABA invalidates a read even when the final context equals its start")
        func authenticationABAInvalidatesRead() async {
            let fixture = ReceiptFixture()
            let original = fixture.context
            let gate = ReceiptInspectionGate()
            let task = Task { @MainActor in await fixture.controller.refresh { await gate.read() } }
            await gate.waitUntilStarted()
            fixture.context = changed(.phase, in: original)
            fixture.controller.contextDidChange()
            fixture.context = original
            fixture.controller.contextDidChange()
            gate.finish(with: .init(inspection: ["event": "canonicalLibrarySnapshot", "canonicalIDs": "old"]))
            let result = await task.value
            #expect(result.state == .invalidated)
            #expect(result.context == original)
            #expect(result.snapshot.inspection == nil)
        }

        @Test("An idle or completed producer rebases before the next request")
        func contextChangesBetweenRequestsRebaseBaseline() async throws {
            let fixture = ReceiptFixture()
            let original = fixture.controller.receipt
            fixture.context = changed(.resource, in: fixture.context)
            let rebased = fixture.controller.receipt
            #expect(rebased.context == fixture.context)
            #expect(rebased.state == .idle)
            #expect(fixture.publications.last == rebased)
            let first = await fixture.controller.refresh { .init() }
            #expect(try first.validatedSnapshot(
                after: rebased,
                context: fixture.context,
                deadline: .init(start: 100),
                now: 101,
            ) != nil)
            fixture.context = changed(.phase, in: fixture.context)
            fixture.controller.contextDidChange()
            let lockedBaseline = fixture.controller.receipt
            #expect(lockedBaseline.context == fixture.context)
            #expect(lockedBaseline.state == .idle)
            #expect(lockedBaseline.request == first.request)
            let next = await fixture.controller.refresh {
                .init(inspection: ["event": "acceptedLibraryStorage", "temporaryCount": "1", "temporaryBytes": "151"])
                    .addingFixtureProofs(expectedStagingBytes: 151)
            }
            #expect(try next.validatedSnapshot(
                after: lockedBaseline,
                context: fixture.context,
                deadline: .init(start: 100),
                now: 101,
            )?
                .inspection?["singleStagedFixture"] == "true")
            #expect(throws: BrowserDownloadObservationError.stale) {
                try next.validatedSnapshot(
                    after: original,
                    context: fixture.context,
                    deadline: .init(start: 100),
                    now: 101,
                )
            }
        }

        @Test("An unchanged context notification does not invalidate active inspection")
        func unchangedContextDoesNotInvalidateRead() async {
            let fixture = ReceiptFixture()
            let gate = ReceiptInspectionGate()
            let task = Task { @MainActor in await fixture.controller.refresh { await gate.read() } }
            await gate.waitUntilStarted()
            fixture.controller.contextDidChange()
            #expect(fixture.controller.receipt.state == .pending)
            gate.finish(with: .init())
            let result = await task.value
            #expect(result.state == .completed)
        }

        @Test("Overlapping requests are busy and cannot adopt the earlier read")
        func busyRequestCannotInheritInspection() async {
            let fixture = ReceiptFixture()
            let gate = ReceiptInspectionGate()
            let first = Task { @MainActor in await fixture.controller.refresh { await gate.read() } }
            await gate.waitUntilStarted()
            var secondReadStarted = false
            let busy = await fixture.controller.refresh {
                secondReadStarted = true
                return .init()
            }
            #expect(busy.state == .busy)
            #expect(busy.request?.sequence == 2)
            #expect(!secondReadStarted)
            gate.finish(with: .init(inspection: ["event": "canonicalLibrarySnapshot", "canonicalIDs": "old"]))
            let firstResult = await first.value
            #expect(firstResult == busy)
            #expect(fixture.controller.receipt == busy)
            #expect(!fixture.publications.contains { $0.state == .completed })
            let next = await fixture.controller.refresh { .init() }
            #expect(next.state == .completed)
            #expect(next.request?.sequence == 3)
        }

        @Test("Inspection errors cannot publish old successful evidence")
        func failedInspectionHasNoOldSnapshot() async {
            let fixture = ReceiptFixture()
            _ = await fixture.controller.refresh { .init(inspection: [
                "event": "canonicalLibrarySnapshot",
                "assetCount": "1",
            ]) }
            let baseline = fixture.controller.receipt
            let failed = await fixture.controller.refresh { throw ReceiptInspectionFailure.unavailable }
            #expect(failed.state == .failed)
            #expect(failed.snapshot.inspection == nil)
            #expect(failed.snapshot.events.isEmpty)
            #expect(throws: BrowserDownloadObservationError.failed) {
                try failed.validatedSnapshot(
                    after: baseline,
                    context: fixture.context,
                    deadline: .init(start: 100),
                    now: 101,
                )
            }
        }

        @Test("Cancellation cannot turn an eventual inspection return into completion")
        func cancelledInteractionCannotComplete() async {
            let fixture = ReceiptFixture()
            let gate = ReceiptInspectionGate()
            let task = Task { @MainActor in await fixture.controller.refresh { await gate.read() } }
            await gate.waitUntilStarted()
            task.cancel()
            gate.finish(with: .init(inspection: ["event": "canonicalLibrarySnapshot", "assetCount": "1"]))
            let result = await task.value
            #expect(result.state == .failed)
            #expect(result.snapshot.inspection == nil)
        }

        @Test("Malformed and missing wire data fail explicitly")
        func malformedAndMissingReceiptsFail() throws {
            for missing in [nil, ""] as [String?] {
                #expect(throws: BrowserDownloadObservationError.missing) {
                    try BrowserDownloadObservationReceipt.decode(missing)
                }
            }
            for malformed in ["{", "[]", "null", "{}"] {
                #expect(throws: BrowserDownloadObservationError.malformed) {
                    try BrowserDownloadObservationReceipt.decode(malformed)
                }
            }
            let fixture = ReceiptFixture()
            let encodedObject = try JSONSerialization.jsonObject(with: JSONEncoder().encode(fixture.receipt()))
            var object = try #require(encodedObject as? [String: Any])
            object["state"] = "unknown"
            let unknown = try String(decoding: JSONSerialization.data(withJSONObject: object), as: UTF8.self)
            #expect(throws: BrowserDownloadObservationError.malformed) {
                try BrowserDownloadObservationReceipt.decode(unknown)
            }
        }

        @Test(
            "Terminal dispositions remain failures",
            arguments: [BrowserDownloadObservationReceipt.State.busy, .failed, .invalidated],
        )
        func terminalDispositionsFail(state: BrowserDownloadObservationReceipt.State) {
            let fixture = ReceiptFixture()
            let receipt = fixture.receipt(state: state, revision: 0)
            let expected: BrowserDownloadObservationError =
                switch state {
                case .busy:
                    .busy
                case .invalidated:
                    .invalidated
                default:
                    .failed
                }
            #expect(throws: expected) {
                try receipt.validatedSnapshot(
                    after: fixture.controller.receipt,
                    context: fixture.context,
                    deadline: .init(start: 100),
                    now: 101,
                )
            }
        }

        @Test("Wrong sequence, repeated request UUID and non-advancing revision cannot complete")
        func historicalIdentityCannotSatisfyNewRequest() throws {
            let fixture = ReceiptFixture()
            let baseline = fixture.receipt()
            let repeatedID = fixture.receipt(sequence: 2, id: baseline.request?.id ?? UUID(), revision: 2)
            let skipped = fixture.receipt(sequence: 3, revision: 2)
            let repeatedSequence = fixture.receipt(sequence: 1, revision: 2)
            let oldRevision = fixture.receipt(sequence: 2, revision: 1)
            for stale in [repeatedID, skipped, repeatedSequence, oldRevision] {
                #expect(throws: BrowserDownloadObservationError.stale) {
                    try stale.validatedSnapshot(
                        after: baseline,
                        context: fixture.context,
                        deadline: .init(start: 100),
                        now: 101,
                    )
                }
            }
            #expect(try baseline.validatedSnapshot(
                after: baseline,
                context: fixture.context,
                deadline: .init(start: 100),
                now: 101,
            ) == nil)
        }

        @Test("Request context must match the envelope and live context")
        func mismatchedRequestContextFails() {
            let fixture = ReceiptFixture()
            let request = BrowserDownloadObservationRequest(
                sequence: 1,
                id: UUID(),
                context: changed(.resource, in: fixture.context),
            )
            let receipt = BrowserDownloadObservationReceipt(
                request: request,
                revision: 1,
                context: fixture.context,
                state: .completed,
            )
            #expect(throws: BrowserDownloadObservationError.stale) {
                try receipt.validatedSnapshot(
                    after: fixture.controller.receipt,
                    context: fixture.context,
                    deadline: .init(start: 100),
                    now: 101,
                )
            }
        }

        @Test("Unsupported schema and sequence overflow fail closed")
        func malformedSchemaAndExhaustedSequenceFail() {
            let fixture = ReceiptFixture()
            let wrongSchema = BrowserDownloadObservationReceipt(
                schemaVersion: 2,
                request: nil,
                revision: 0,
                context: fixture.context,
                state: .idle,
            )
            #expect(throws: BrowserDownloadObservationError.malformed) {
                try wrongSchema.validatedSnapshot(
                    after: fixture.controller.receipt,
                    context: fixture.context,
                    deadline: .init(start: 100),
                    now: 101,
                )
            }
            #expect(throws: BrowserDownloadObservationError.stale) {
                try fixture.receipt().validatedSnapshot(
                    after: fixture.receipt(sequence: .max),
                    context: fixture.context,
                    deadline: .init(start: 100),
                    now: 101,
                )
            }
        }

        @Test("Repeated completed samples consume one absolute deadline")
        func repeatedSamplesShareDeadline() async throws {
            let fixture = ReceiptFixture()
            let deadline = BrowserDownloadObservationDeadline(start: 100)
            var baseline = fixture.controller.receipt
            let first = await fixture.controller.refresh { .init() }
            #expect(try first.validatedSnapshot(
                after: baseline,
                context: fixture.context,
                deadline: deadline,
                now: 104,
            ) != nil)
            baseline = first
            #expect(deadline.remaining(at: 104) == 6)
            let second = await fixture.controller.refresh { .init() }
            #expect(try second.validatedSnapshot(
                after: baseline,
                context: fixture.context,
                deadline: deadline,
                now: 109,
            ) != nil)
            #expect(deadline.remaining(at: 109) == 1)
            #expect(throws: BrowserDownloadObservationError.deadlineExceeded) {
                try second.validatedSnapshot(after: baseline, context: fixture.context, deadline: deadline, now: 110)
            }
            #expect(throws: BrowserDownloadObservationError.deadlineExceeded) {
                try second.validatedSnapshot(after: baseline, context: fixture.context, deadline: deadline, now: 111)
            }
        }

        @Test("Invalid clocks and deadlines have no remaining budget")
        func invalidClockFailsClosed() {
            #expect(BrowserDownloadObservationDeadline(start: 100).remaining(at: 99) == 0)
            #expect(BrowserDownloadObservationDeadline(start: 100).remaining(at: .nan) == 0)
            #expect(BrowserDownloadObservationDeadline(start: .infinity).remaining(at: 100) == 0)
            #expect(BrowserDownloadObservationDeadline(start: 100, duration: -1).remaining(at: 100) == 0)
        }

        @Test("A read that returns after the deadline cannot become client success")
        func suspendedCompletionAfterDeadlineFails() async {
            let fixture = ReceiptFixture()
            let baseline = fixture.controller.receipt
            let deadline = BrowserDownloadObservationDeadline(start: 100)
            let gate = ReceiptInspectionGate()
            let task = Task { @MainActor in await fixture.controller.refresh { await gate.read() } }
            await gate.waitUntilStarted()
            gate.finish(with: .init(inspection: ["event": "canonicalLibrarySnapshot", "assetCount": "1"]))
            let late = await task.value
            #expect(throws: BrowserDownloadObservationError.deadlineExceeded) {
                try late.validatedSnapshot(after: baseline, context: fixture.context, deadline: deadline, now: 111)
            }
        }

        @Test(
            "Producer and consumer redact locked and authentication snapshots",
            arguments: ["locked", "authentication", "loading"],
        )
        func privateProjectionAtBothBoundaries(phase: String) async throws {
            let fixture = ReceiptFixture()
            fixture.context = changed(.phase, in: fixture.context, phase: phase)
            let baseline = fixture.controller.receipt
            let source = BrowserDownloadObservationSnapshot(
                inspection: [
                    "event": "acceptedLibraryStorage",
                    "temporaryCount": "1",
                    "temporaryBytes": "608",
                    "libraryID": "storage-identity",
                    "databaseID": "database-identity",
                    "canonicalIDs": "private",
                    "filename": "private",
                    "credentialInput": "private",
                ],
                events: [
                    ["event": "canonicalLibrarySnapshot", "canonicalIDs": "private"],
                    ["event": "acceptedLibraryStorage", "temporaryCount": "999"],
                    [
                        "event": "writerFinished",
                        "operation": "writer-operation",
                        "allocation": "scratch-allocation",
                        "bytes": "608",
                        "sha256": "fixture-proof",
                        "filename": "private",
                        "path": "private",
                        "assetID": "private",
                    ],
                ],
            )
            let prepared = source.addingFixtureProofs(expectedStagingBytes: 608)
            let produced = await fixture.controller.refresh { prepared }
            #expect(produced.snapshot.inspection?["singleStagedFixture"] == "true")
            #expect(produced.snapshot.inspection?["libraryID"] == "storage-identity")
            #expect(produced.snapshot.events.first?["operation"] == "writer-operation")
            #expect(produced.snapshot.events.first?["sha256"] == nil)
            #expect(!produced.snapshot.events.contains { $0["event"] == "canonicalLibrarySnapshot" })
            let untrusted = fixture.receipt(snapshot: prepared)
            let value = try untrusted.validatedSnapshot(
                after: baseline,
                context: fixture.context,
                deadline: .init(start: 100),
                now: 101,
            )
            let validated = try #require(value)
            #expect(validated == produced.snapshot)
            let encoded = try String(decoding: JSONEncoder().encode(produced), as: UTF8.self)
            #expect(!encoded.contains("private"))
        }

        @Test("Canonical facts are fresh inspection only, never historical readiness")
        func canonicalHistoryCannotSatisfyFreshInspection() async throws {
            let fixture = ReceiptFixture()
            let baseline = fixture.controller.receipt
            let receipt = await fixture.controller.refresh {
                .init(
                    inspection: ["event": "canonicalLibrarySnapshot", "assetCount": "2", "canonicalIDs": "fresh"],
                    events: [
                        ["event": "canonicalLibrarySnapshot", "assetCount": "1", "canonicalIDs": "old"],
                        ["event": "writerFinished", "bytes": "608"],
                    ],
                )
            }
            let value = try receipt.validatedSnapshot(
                after: baseline,
                context: fixture.context,
                deadline: .init(start: 100),
                now: 101,
            )
            let validated = try #require(value)
            #expect(validated.inspection?["canonicalIDs"] == "fresh")
            #expect(validated.events == [["event": "writerFinished", "bytes": "608"]])
            fixture.context = changed(.phase, in: fixture.context)
            fixture.controller.contextDidChange()
            #expect(fixture.publications.last?.state == .idle)
            #expect(fixture.publications.last?.snapshot.inspection == nil)
        }

        @Test("A locked producer never publishes a canonical inspection")
        func lockedCanonicalInspectionIsNotPublished() async {
            let fixture = ReceiptFixture()
            fixture.context = changed(.phase, in: fixture.context)
            let receipt = await fixture.controller.refresh {
                .init(inspection: ["event": "canonicalLibrarySnapshot", "canonicalIDs": "private"])
            }
            #expect(receipt.snapshot.inspection == nil)
        }

        @Test(
            "Content hashes require authentication at producer and consumer boundaries",
            arguments: ["locked", "authenticated"],
        )
        func contentHashesRequireAuthentication(phase: String) async throws {
            let fixture = ReceiptFixture()
            fixture.context = changed(.phase, in: fixture.context, phase: phase)
            let baseline = fixture.controller.receipt
            let hash = "852ba89aa0d708405217efd9cc3d014f4a1cc48ed1895748a1e1d9540f97bd79"
            let source = BrowserDownloadObservationSnapshot(
                inspection: [
                    "event": "acceptedLibraryStorage",
                    "temporaryCount": "1",
                    "temporaryBytes": "608",
                    "sha256": hash,
                ],
                events: [
                    ["event": "completedFileProof", "operation": "opaque-operation", "sha256": hash],
                    ["event": "canonicalLibrarySnapshot", "canonicalIDs": "historical-private"],
                ],
            )
            let prepared = source.addingFixtureProofs(expectedStagingBytes: 608)
            let produced = await fixture.controller.refresh { prepared }
            let untrusted = fixture.receipt(snapshot: prepared)
            let value = try untrusted.validatedSnapshot(
                after: baseline,
                context: fixture.context,
                deadline: .init(start: 100),
                now: 101,
            )
            let validated = try #require(value)
            #expect(produced.snapshot == validated)
            let expectedHash = phase == "authenticated" ? hash : nil
            #expect(validated.inspection?["sha256"] == expectedHash)
            #expect(validated.inspection?["singleStagedFixture"] == "true")
            #expect(validated.events.first?["event"] == "completedFileProof")
            #expect(validated.events.first?["operation"] == "opaque-operation")
            #expect(validated.events.first?["sha256"] == expectedHash)
            #expect(!validated.events.contains { $0["event"] == "canonicalLibrarySnapshot" })
        }
    }
}

enum ReceiptContextField: CaseIterable, Sendable {
    case process
    case run
    case authorization
    case resource
    case ingestion
    case phase
}

private enum ReceiptInspectionFailure: Error {
    case unavailable
}

private func changed(
    _ field: ReceiptContextField,
    in context: BrowserDownloadObservationContext,
    phase: String = "locked",
) -> BrowserDownloadObservationContext {
    .init(
        processNonce: field == .process ? UUID() : context.processNonce,
        runID: field == .run ? "another-run" : context.runID,
        authorizationGeneration: context.authorizationGeneration + (field == .authorization ? 1 : 0),
        resourceGeneration: context.resourceGeneration + (field == .resource ? 1 : 0),
        ingestionGeneration: context.ingestionGeneration + (field == .ingestion ? 1 : 0),
        phase: field == .phase ? phase : context.phase,
    )
}

@MainActor
private final class ReceiptFixture {
    private let state = ReceiptFixtureState()
    var context: BrowserDownloadObservationContext {
        get { state.context }
        set { state.context = newValue }
    }

    var publications: [BrowserDownloadObservationReceipt] {
        state.publications
    }

    lazy var controller: BrowserDownloadObservationController = {
        let fixtureState = self.state
        return BrowserDownloadObservationController(
            context: { fixtureState.context },
            publish: { fixtureState.publications.append($0) },
        )
    }()

    func receipt(
        state: BrowserDownloadObservationReceipt.State = .completed,
        sequence: UInt64 = 1,
        id: UUID = UUID(),
        revision: UInt64 = 1,
        snapshot: BrowserDownloadObservationSnapshot = .init(inspection: [
            "event": "canonicalLibrarySnapshot",
            "assetCount": "2",
        ]),
    ) -> BrowserDownloadObservationReceipt {
        .init(
            request: .init(sequence: sequence, id: id, context: context),
            revision: revision,
            context: context,
            state: state,
            snapshot: snapshot,
        )
    }
}

@MainActor
private final class ReceiptInspectionGate {
    private var reader: CheckedContinuation<BrowserDownloadObservationSnapshot, Never>?
    private var started: CheckedContinuation<Void, Never>?

    func read() async -> BrowserDownloadObservationSnapshot {
        await withCheckedContinuation { continuation in
            reader = continuation
            started?.resume()
            started = nil
        }
    }

    func waitUntilStarted() async {
        if reader == nil {
            await withCheckedContinuation { started = $0 }
        }
    }

    func finish(with snapshot: BrowserDownloadObservationSnapshot) {
        reader?.resume(returning: snapshot)
        reader = nil
    }
}

@MainActor
private final class ReceiptFixtureState {
    var context = BrowserDownloadObservationContext(
        processNonce: UUID(),
        runID: "receipt-run",
        authorizationGeneration: 1,
        resourceGeneration: 2,
        ingestionGeneration: 3,
        phase: "authenticated",
    )
    var publications: [BrowserDownloadObservationReceipt] = []
}

extension AppHostedUITests.BrowserDownloadObservationReceiptTests {
    @Test("Cached idle baseline cannot make an accepted completion satisfy a later Refresh")
    func cachedIdleCannotReplayAcceptedCompletion() async throws {
        let fixture = ReceiptFixture()
        let cursor = BrowserDownloadObservationCursor()
        try cursor.authorizeProcess(fixture.context.processNonce)
        let idle = fixture.controller.receipt
        try cursor.validateBaseline(idle, context: fixture.context)
        let accepted = await fixture.controller.refresh {
            .init(inspection: ["event": "canonicalLibrarySnapshot", "assetCount": "0"])
        }
        let first = try cursor.validatedSnapshot(
            accepted,
            after: idle,
            context: fixture.context,
            deadline: .init(start: 100),
            now: 101,
        )
        #expect(first?.inspection?["assetCount"] == "0")
        let gate = ReceiptInspectionGate()
        let next = Task { @MainActor in await fixture.controller.refresh { await gate.read() } }
        await gate.waitUntilStarted()
        #expect(fixture.controller.receipt.request?.sequence == 2)
        #expect(fixture.controller.receipt.state == .pending)
        // The old request-only validator accepts A again if AX replays the original idle baseline.
        #expect(try accepted.validatedSnapshot(
            after: idle,
            context: fixture.context,
            deadline: .init(start: 100),
            now: 102,
        ) != nil)
        #expect(throws: BrowserDownloadObservationError.stale) {
            try cursor.validateBaseline(idle, context: fixture.context)
        }
        #expect(throws: BrowserDownloadObservationError.stale) {
            try cursor.validatedSnapshot(
                accepted,
                after: idle,
                context: fixture.context,
                deadline: .init(start: 100),
                now: 102,
            )
        }
        gate.finish(with: .init())
        _ = await next.value
    }

    @Test("A process transition retires the previous nonce and rejects its old initial receipt")
    func retiredProcessCannotReenterCursor() async throws {
        let fixture = ReceiptFixture()
        let cursor = BrowserDownloadObservationCursor()
        try cursor.authorizeProcess(fixture.context.processNonce)
        let oldContext = fixture.context
        let oldIdle = fixture.controller.receipt
        try cursor.validateBaseline(oldIdle, context: oldContext)
        let accepted = await fixture.controller.refresh { .init() }
        #expect(try cursor.validatedSnapshot(
            accepted,
            after: oldIdle,
            context: oldContext,
            deadline: .init(start: 100),
            now: 101,
        ) != nil)
        fixture.context = changed(.run, in: changed(.process, in: oldContext))
        let restarted = BrowserDownloadObservationReceipt(
            request: nil,
            revision: 0,
            context: fixture.context,
            state: .idle,
        )
        try cursor.authorizeProcess(fixture.context.processNonce)
        try cursor.validateBaseline(restarted, context: fixture.context)
        #expect(throws: BrowserDownloadObservationError.stale) {
            try cursor.validateBaseline(oldIdle, context: oldContext)
        }
        #expect(throws: BrowserDownloadObservationError.stale) {
            try cursor.validatedSnapshot(
                accepted,
                after: oldIdle,
                context: oldContext,
                deadline: .init(start: 100),
                now: 102,
            )
        }
    }

    @Test("Context rebasing preserves the accepted position between requests")
    func cursorAcceptsRebasedContextAtSamePosition() async throws {
        let fixture = ReceiptFixture()
        let cursor = BrowserDownloadObservationCursor()
        try cursor.authorizeProcess(fixture.context.processNonce)
        let idle = fixture.controller.receipt
        try cursor.validateBaseline(idle, context: fixture.context)
        let first = await fixture.controller.refresh { .init() }
        #expect(try cursor.validatedSnapshot(
            first,
            after: idle,
            context: fixture.context,
            deadline: .init(start: 100),
            now: 101,
        ) != nil)
        fixture.context = changed(.phase, in: changed(.resource, in: fixture.context))
        let rebased = fixture.controller.receipt
        #expect(rebased.state == .idle)
        #expect(rebased.request == first.request)
        #expect(rebased.revision == first.revision)
        try cursor.validateBaseline(rebased, context: fixture.context)
        let second = await fixture.controller.refresh {
            .init(inspection: ["event": "acceptedLibraryStorage", "temporaryCount": "1", "temporaryBytes": "151"])
                .addingFixtureProofs(expectedStagingBytes: 151)
        }
        let value = try cursor.validatedSnapshot(
            second,
            after: rebased,
            context: fixture.context,
            deadline: .init(start: 100),
            now: 102,
        )
        #expect(value?.inspection?["singleStagedFixture"] == "true")
    }

    @Test("Every completed sample advances the cursor even when the domain is not ready")
    func notReadySamplesStillAdvanceCursor() async throws {
        let fixture = ReceiptFixture()
        let cursor = BrowserDownloadObservationCursor()
        try cursor.authorizeProcess(fixture.context.processNonce)
        let initial = fixture.controller.receipt
        var baseline = initial
        let deadline = BrowserDownloadObservationDeadline(start: 100)
        for count in ["0", "0", "1"] {
            try cursor.validateBaseline(baseline, context: fixture.context)
            let completed = await fixture.controller.refresh {
                .init(inspection: ["event": "canonicalLibrarySnapshot", "assetCount": count])
            }
            let value = try cursor.validatedSnapshot(
                completed,
                after: baseline,
                context: fixture.context,
                deadline: deadline,
                now: 101,
            )
            #expect(value?.inspection?["assetCount"] == count)
            #expect(throws: BrowserDownloadObservationError.stale) {
                try cursor.validateBaseline(initial, context: fixture.context)
            }
            baseline = completed
        }
        #expect(baseline.request?.sequence == 3)
        #expect(baseline.revision == 3)
    }
}

extension AppHostedUITests.BrowserDownloadObservationReceiptTests {
    @Test("Unknown future baselines cannot advance or retire the cursor")
    func cursorRejectsUnexplainedBaselinePositions() async throws {
        let fixture = ReceiptFixture()
        let cursor = BrowserDownloadObservationCursor()
        try cursor.authorizeProcess(fixture.context.processNonce)
        let initial = fixture.controller.receipt
        let original = fixture.context
        try cursor.validateBaseline(initial, context: original)
        let first = await fixture.controller.refresh { .init() }
        #expect(try cursor.validatedSnapshot(
            first,
            after: initial,
            context: original,
            deadline: .init(start: 100),
            now: 101,
        ) != nil)
        for future in [fixture.receipt(sequence: 2, revision: 2), fixture.receipt(sequence: 1, revision: 0)] {
            #expect(throws: BrowserDownloadObservationError.stale) {
                try cursor.validateBaseline(future, context: original)
            }
        }
        fixture.context = changed(.process, in: original)
        #expect(throws: BrowserDownloadObservationError.stale) {
            try cursor.validateBaseline(fixture.receipt(), context: fixture.context)
        }
        try cursor.validateBaseline(first, context: original)
        let unknown = BrowserDownloadObservationCursor()
        try unknown.authorizeProcess(original.processNonce)
        #expect(throws: BrowserDownloadObservationError.stale) {
            try unknown.validateBaseline(first, context: original)
        }
    }

    @Test("Pending, failed and late reads do not advance an accepted wire position")
    func unsuccessfulReadsDoNotAdvanceCursor() throws {
        let fixture = ReceiptFixture()
        let cursor = BrowserDownloadObservationCursor()
        try cursor.authorizeProcess(fixture.context.processNonce)
        let initial = fixture.controller.receipt
        let deadline = BrowserDownloadObservationDeadline(start: 100)
        try cursor.validateBaseline(initial, context: fixture.context)
        #expect(try cursor.validatedSnapshot(
            fixture.receipt(state: .pending, revision: 0),
            after: initial,
            context: fixture.context,
            deadline: deadline,
            now: 101,
        ) == nil)
        try cursor.validateBaseline(initial, context: fixture.context)
        #expect(throws: BrowserDownloadObservationError.failed) {
            try cursor.validatedSnapshot(
                fixture.receipt(state: .failed, revision: 0),
                after: initial,
                context: fixture.context,
                deadline: deadline,
                now: 101,
            )
        }
        #expect(throws: BrowserDownloadObservationError.deadlineExceeded) {
            try cursor.validatedSnapshot(
                fixture.receipt(),
                after: initial,
                context: fixture.context,
                deadline: deadline,
                now: 110,
            )
        }
        try cursor.validateBaseline(initial, context: fixture.context)
    }
}

extension AppHostedUITests.BrowserDownloadObservationReceiptTests {
    @Test("Only an explicitly authorized launch can bind its initial or completed receipt")
    func unapprovedProcessCannotSupplyReceiptHistory() async throws {
        let fixture = ReceiptFixture()
        let cursor = BrowserDownloadObservationCursor()
        let initial = fixture.controller.receipt
        #expect(throws: BrowserDownloadObservationError.stale) {
            try cursor.validateBaseline(initial, context: fixture.context)
        }
        let accepted = await fixture.controller.refresh { .init() }
        #expect(throws: BrowserDownloadObservationError.stale) {
            try cursor.validatedSnapshot(
                accepted,
                after: initial,
                context: fixture.context,
                deadline: .init(start: 100),
                now: 101,
            )
        }
        let authorized = BrowserDownloadObservationCursor()
        try authorized.authorizeProcess(fixture.context.processNonce)
        try authorized.validateBaseline(initial, context: fixture.context)
        #expect(try authorized.validatedSnapshot(
            accepted,
            after: initial,
            context: fixture.context,
            deadline: .init(start: 100),
            now: 101,
        ) != nil)
        let unrelated = ReceiptFixture()
        let unrelatedInitial = unrelated.controller.receipt
        let cachedCompletion = await unrelated.controller.refresh {
            .init(inspection: ["event": "canonicalLibrarySnapshot", "assetCount": "999"])
        }
        #expect(throws: BrowserDownloadObservationError.stale) {
            try authorized.validateBaseline(unrelatedInitial, context: unrelated.context)
        }
        #expect(throws: BrowserDownloadObservationError.stale) {
            try authorized.validatedSnapshot(
                cachedCompletion,
                after: unrelatedInitial,
                context: unrelated.context,
                deadline: .init(start: 100),
                now: 102,
            )
        }
        try authorized.validateBaseline(accepted, context: fixture.context)
    }

    @Test("Explicit launch authorization rejects old cached receipts before observing the new process")
    func newLaunchImmediatelyRetiresOldReceipts() async throws {
        let old = ReceiptFixture()
        let cursor = BrowserDownloadObservationCursor()
        try cursor.authorizeProcess(old.context.processNonce)
        let oldInitial = old.controller.receipt
        try cursor.validateBaseline(oldInitial, context: old.context)
        let oldCompleted = await old.controller.refresh { .init() }
        #expect(try cursor.validatedSnapshot(
            oldCompleted,
            after: oldInitial,
            context: old.context,
            deadline: .init(start: 100),
            now: 101,
        ) != nil)
        let launched = ReceiptFixture()
        try cursor.authorizeProcess(launched.context.processNonce)
        #expect(throws: BrowserDownloadObservationError.stale) {
            try cursor.validateBaseline(oldCompleted, context: old.context)
        }
        #expect(throws: BrowserDownloadObservationError.stale) {
            try cursor.validateBaseline(oldInitial, context: old.context)
        }
        #expect(throws: BrowserDownloadObservationError.stale) {
            try cursor.validatedSnapshot(
                oldCompleted,
                after: oldCompleted,
                context: old.context,
                deadline: .init(start: 100),
                now: 102,
            )
        }
        #expect(throws: BrowserDownloadObservationError.stale) {
            try cursor.authorizeProcess(old.context.processNonce)
        }
        let initial = launched.controller.receipt
        try cursor.validateBaseline(initial, context: launched.context)
        let completed = await launched.controller.refresh { .init() }
        #expect(try cursor.validatedSnapshot(
            completed,
            after: initial,
            context: launched.context,
            deadline: .init(start: 100),
            now: 103,
        ) != nil)
    }

    @Test("Repeated authorization of the current nonce cannot reset its accepted position")
    func repeatedAuthorizationPreservesPosition() async throws {
        let fixture = ReceiptFixture()
        let cursor = BrowserDownloadObservationCursor()
        try cursor.authorizeProcess(fixture.context.processNonce)
        let initial = fixture.controller.receipt
        try cursor.validateBaseline(initial, context: fixture.context)
        let completed = await fixture.controller.refresh { .init() }
        #expect(try cursor.validatedSnapshot(
            completed,
            after: initial,
            context: fixture.context,
            deadline: .init(start: 100),
            now: 101,
        ) != nil)
        try cursor.authorizeProcess(fixture.context.processNonce)
        #expect(throws: BrowserDownloadObservationError.stale) {
            try cursor.validateBaseline(initial, context: fixture.context)
        }
        try cursor.validateBaseline(completed, context: fixture.context)
    }
}

extension AppHostedUITests.BrowserDownloadObservationReceiptTests {
    @Test("Baseline evidence identifies the exact accepted-position mismatch without changing the cursor")
    func baselineFailureRecordsExactPositionOperand() async throws {
        let fixture = ReceiptFixture()
        let cursor = BrowserDownloadObservationCursor()
        try cursor.authorizeProcess(fixture.context.processNonce)
        let initial = fixture.controller.receipt
        let first = await fixture.controller.refresh { .init() }
        _ = try cursor.validatedSnapshot(
            first,
            after: initial,
            context: fixture.context,
            deadline: .init(start: 100),
            now: 101,
        )
        let requestID = try #require(first.request?.id)
        let future = fixture.receipt(sequence: 2, id: requestID, revision: first.revision)
        #expect(throws: BrowserDownloadObservationError.stale) {
            try cursor.validateBaseline(future, context: fixture.context)
        }
        let evidence = try #require(cursor.lastFailure)
        #expect(evidence.stage == .baseline)
        #expect(evidence.comparison == .acceptedPosition)
        #expect(evidence.positionField == .sequence)
        #expect(evidence.authorizedProcessNonce == fixture.context.processNonce)
        #expect(evidence.acceptedPosition?.sequence == 1)
        #expect(evidence.baseline?.request?.sequence == 2)
        #expect(evidence.observedReceipt == nil)
        cursor.clearFailureEvidence()
        #expect(cursor.lastFailure == nil)
        try cursor.validateBaseline(first, context: fixture.context)
        #expect(cursor.lastFailure == nil)
        #expect(throws: BrowserDownloadObservationError.stale) {
            try cursor.validateBaseline(initial, context: fixture.context)
        }
    }

    @Test("Post-tap evidence distinguishes receipt context from the observed baseline")
    func receiptFailureRecordsExactContextOperand() throws {
        let fixture = ReceiptFixture()
        let cursor = BrowserDownloadObservationCursor()
        try cursor.authorizeProcess(fixture.context.processNonce)
        let initial = fixture.controller.receipt
        try cursor.validateBaseline(initial, context: fixture.context)
        let request = BrowserDownloadObservationRequest(sequence: 1, id: UUID(), context: fixture.context)
        let changedContext = changed(.authorization, in: fixture.context)
        let receipt = BrowserDownloadObservationReceipt(
            request: request,
            revision: 1,
            context: changedContext,
            state: .completed,
        )
        #expect(throws: BrowserDownloadObservationError.stale) {
            try cursor.validatedSnapshot(
                receipt,
                after: initial,
                context: fixture.context,
                deadline: .init(start: 100),
                now: 101,
            )
        }
        let evidence = try #require(cursor.lastFailure)
        #expect(evidence.stage == .completion)
        #expect(evidence.comparison == .receiptContext)
        #expect(evidence.contextField == .authorizationGeneration)
        #expect(evidence.baseline?.context.authorizationGeneration == 1)
        #expect(evidence.observedReceipt?.context.authorizationGeneration == 2)
        #expect(evidence.observedReceipt?.request?.context.authorizationGeneration == 1)
        try cursor.validateBaseline(initial, context: fixture.context)
        #expect(cursor.lastFailure == evidence)
    }

    @Test("A post-tap baseline rejection retains the current receipt's metadata")
    func completionBaselineFailureKeepsBothOperands() async throws {
        let fixture = ReceiptFixture()
        let cursor = BrowserDownloadObservationCursor()
        try cursor.authorizeProcess(fixture.context.processNonce)
        let initial = fixture.controller.receipt
        let accepted = await fixture.controller.refresh { .init() }
        _ = try cursor.validatedSnapshot(
            accepted,
            after: initial,
            context: fixture.context,
            deadline: .init(start: 100),
            now: 101,
        )
        let next = fixture.receipt(sequence: 2, revision: 2)
        #expect(throws: BrowserDownloadObservationError.stale) {
            try cursor.validatedSnapshot(
                next,
                after: initial,
                context: fixture.context,
                deadline: .init(start: 100),
                now: 102,
            )
        }
        let evidence = try #require(cursor.lastFailure)
        #expect(evidence.stage == .completionBaseline)
        #expect(evidence.comparison == .acceptedPosition)
        #expect(evidence.acceptedPosition?.sequence == 1)
        #expect(evidence.baseline?.request == nil)
        #expect(evidence.observedReceipt?.request?.sequence == 2)
        try cursor.validateBaseline(accepted, context: fixture.context)
    }

    @Test("Failure encoding excludes payload and sanitizes arbitrary run and phase strings")
    func failureEvidenceIsMetadataOnly() throws {
        let fixture = ReceiptFixture()
        let marker = "private-payload-sentinel"
        fixture.context = .init(
            processNonce: UUID(),
            runID: marker + "/run",
            authorizationGeneration: 1,
            resourceGeneration: 2,
            ingestionGeneration: 3,
            phase: marker + "/phase",
        )
        let cursor = BrowserDownloadObservationCursor()
        try cursor.authorizeProcess(fixture.context.processNonce)
        let initial = fixture.controller.receipt
        // Existing acceptance permits this nonempty run and phase; diagnostics must not tighten it.
        try cursor.validateBaseline(initial, context: fixture.context)
        let source = BrowserDownloadObservationSnapshot(
            inspection: ["filename": marker, "url": marker, "credentialInput": marker],
            events: [["event": marker, "path": marker, "sha256": marker]],
        )
        let wrongSequence = fixture.receipt(sequence: 2, snapshot: source)
        #expect(throws: BrowserDownloadObservationError.stale) {
            try cursor.validatedSnapshot(
                wrongSequence,
                after: initial,
                context: fixture.context,
                deadline: .init(start: 100),
                now: 101,
            )
        }
        let evidence = try #require(cursor.lastFailure)
        #expect(evidence.comparison == .requestSequence)
        #expect(evidence.context?.runID == "invalid")
        #expect(evidence.context?.phase == "invalid")
        #expect(evidence.baseline?.context.runID == "invalid")
        #expect(evidence.observedReceipt?.request?.context.phase == "invalid")
        let data = try JSONEncoder().encode(evidence)
        let text = try #require(String(data: data, encoding: .utf8))
        #expect(!text.contains(marker))
        #expect(!text.contains("snapshot"))
        #expect(!text.contains("events"))
        #expect(!text.contains("filename"))
        #expect(!text.contains("credentialInput"))
        #expect(try JSONDecoder().decode(BrowserDownloadObservationFailureEvidence.self, from: data) == evidence)
    }

    @Test(
        "Diagnostics preserve the original terminal cause",
        arguments: [BrowserDownloadObservationReceipt.State.busy, .failed, .invalidated, .idle],
    )
    func diagnosticTerminalCauseIsUnchanged(state: BrowserDownloadObservationReceipt.State) throws {
        let fixture = ReceiptFixture()
        let cursor = BrowserDownloadObservationCursor()
        try cursor.authorizeProcess(fixture.context.processNonce)
        let initial = fixture.controller.receipt
        let cause: BrowserDownloadObservationError =
            switch state {
            case .busy:
                .busy
            case .failed:
                .failed
            case .invalidated:
                .invalidated
            default:
                .notCompleted
            }
        #expect(throws: cause) {
            try cursor.validatedSnapshot(
                fixture.receipt(state: state, revision: 0),
                after: initial,
                context: fixture.context,
                deadline: .init(start: 100),
                now: 101,
            )
        }
        let evidence = try #require(cursor.lastFailure)
        #expect(evidence.stage == .completion)
        #expect(evidence.observedReceipt?.state == state)
        try cursor.validateBaseline(initial, context: fixture.context)
    }
}

extension AppHostedUITests.BrowserDownloadObservationReceiptTests {
    @Test(
        "Unauthenticated producer and consumer snapshots expose proofs rather than quantities",
        arguments: ["locked", "authentication", "loading"],
    )
    func unauthenticatedQuantitiesAreRemovedAtBothBoundaries(phase: String) async throws {
        let fixture = ReceiptFixture()
        fixture.context = changed(.phase, in: fixture.context, phase: phase)
        let baseline = fixture.controller.receipt
        let keys = [
            "bytes",
            "temporaryBytes",
            "receivedBytes",
            "expectedBytes",
            "remaining",
            "prefixBytes",
            "remainderBytes",
            "serverExpectedBytes",
            "temporaryCount",
            "rowCount",
            "activeWriterCount",
            "retainedRecordCount",
            "recordCount",
            "active",
            "retained",
            "requestCount",
            "connectionCount",
            "operations",
            "presentation",
        ]
        var record = Dictionary(uniqueKeysWithValues: keys.map { ($0, "1") })
        record["event"] = "libraryStartup"
        record["temporaryBytes"] = "151"
        record["libraryID"] = "opaque-library"
        record["operation"] = "opaque-operation"
        record["presentation"] = UUID().uuidString
        let raw = BrowserDownloadObservationSnapshot(inspection: record, events: [record])
        let prepared = raw.addingFixtureProofs(expectedStagingBytes: 151)
        let produced = await fixture.controller.refresh { prepared }
        let value = try fixture.receipt(snapshot: prepared).validatedSnapshot(
            after: baseline,
            context: fixture.context,
            deadline: .init(start: 100),
            now: 101,
        )
        let validated = try #require(value)
        #expect(produced.snapshot == validated)
        for key in keys {
            #expect(validated.inspection?[key] == nil)
            #expect(validated.events.first?[key] == nil)
        }
        #expect(validated.inspection?["singleStagedFixture"] == "true")
        #expect(validated.inspection?["progressPositive"] == "true")
        #expect(validated.inspection?["oneActiveWriter"] == "true")
        #expect(validated.inspection?["oneRetainedCompletion"] == "true")
        #expect(validated.inspection?["libraryID"] == "opaque-library")
        #expect(validated.events.first?["operation"] == "opaque-operation")
        #expect(raw.inspection == record)
    }

    @Test("Authenticated projection retains quantitative fields and source snapshots are immutable")
    func authenticatedFixtureQuantitiesRemainExact() {
        let fixture = ReceiptFixture()
        let record = [
            "event": "libraryStartup",
            "temporaryCount": "1",
            "temporaryBytes": "151",
            "rowCount": "0",
            "receivedBytes": "8",
            "expectedBytes": "16",
            "active": "1",
            "operations": "opaque-list",
            "presentation": "opaque-request",
        ]
        let raw = BrowserDownloadObservationSnapshot(inspection: record, events: [record])
        #expect(raw.projected(for: fixture.context) == raw)
        let prepared = raw.addingFixtureProofs(expectedStagingBytes: 151)
        for (key, value) in record {
            #expect(prepared.inspection?[key] == value)
        }
        #expect(raw.inspection == record)
        #expect(raw.events == [record])
        #expect(prepared.inspection?["singleStagedFixture"] == "true")
        #expect(prepared.inspection?["stagingEmpty"] == "false")
    }

    @Test("Forged or malformed proofs cannot survive derivation or projection")
    func forgedFixtureProofsAreCleared() {
        let proofKeys = [
            "singleStagedFixture",
            "stagingEmpty",
            "progressPositive",
            "oneActiveWriter",
            "noActiveWriters",
            "oneRetainedCompletion",
            "finiteResponseBoundsValid",
            "nativeProgressBoundsValid",
        ]
        var forged = Dictionary(uniqueKeysWithValues: proofKeys.map { ($0, "true") })
        forged["event"] = "libraryStartup"
        let cleared = BrowserDownloadObservationSnapshot(inspection: forged, events: [forged])
            .addingFixtureProofs(expectedStagingBytes: 151)
        for key in proofKeys {
            #expect(cleared.inspection?[key] == nil)
            #expect(cleared.events.first?[key] == nil)
        }
        let fixture = ReceiptFixture()
        fixture.context = changed(.phase, in: fixture.context)
        for value in ["TRUE", "1", "false ", "private-proof-value"] {
            forged["singleStagedFixture"] = value
            let projected = BrowserDownloadObservationSnapshot(inspection: forged).projected(for: fixture.context)
            #expect(projected.inspection?["singleStagedFixture"] == nil)
        }
    }

    @Test(
        "Invalid and absent numbers cannot derive quantitative proofs",
        arguments: ["", "-1", "+1", " 1", "1.5", "bad", "9223372036854775808"],
    )
    func invalidFixtureNumbersHaveNoProof(value: String) {
        let record = [
            "event": "libraryStartup",
            "temporaryCount": value,
            "temporaryBytes": "151",
            "receivedBytes": value,
            "activeWriterCount": value,
            "retainedRecordCount": value,
        ]
        let projected = BrowserDownloadObservationSnapshot(inspection: record)
            .addingFixtureProofs(expectedStagingBytes: 151)
        for key in [
            "singleStagedFixture",
            "stagingEmpty",
            "progressPositive",
            "oneActiveWriter",
            "noActiveWriters",
            "oneRetainedCompletion",
        ] {
            #expect(projected.inspection?[key] == nil)
        }
    }

    @Test("Count aliases must agree and zero facts are derived explicitly")
    func fixtureCountAliasesAgree() {
        let zero = [
            "event": "libraryStartup",
            "temporaryCount": "0",
            "temporaryBytes": "0",
            "receivedBytes": "0",
            "activeWriterCount": "0",
            "active": "0",
            "retainedRecordCount": "0",
            "retained": "0",
        ]
        let empty = BrowserDownloadObservationSnapshot(inspection: zero).addingFixtureProofs(expectedStagingBytes: 151)
        #expect(empty.inspection?["stagingEmpty"] == "true")
        #expect(empty.inspection?["singleStagedFixture"] == "false")
        #expect(empty.inspection?["progressPositive"] == "false")
        #expect(empty.inspection?["noActiveWriters"] == "true")
        #expect(empty.inspection?["oneActiveWriter"] == "false")
        #expect(empty.inspection?["oneRetainedCompletion"] == "false")
        let conflicting = [
            "event": "ownerSnapshot",
            "activeWriterCount": "1",
            "active": "0",
            "retainedRecordCount": "1",
            "retained": "2",
        ]
        let invalid = BrowserDownloadObservationSnapshot(inspection: conflicting)
            .addingFixtureProofs(expectedStagingBytes: 151)
        #expect(invalid.inspection?["oneActiveWriter"] == nil)
        #expect(invalid.inspection?["noActiveWriters"] == nil)
        #expect(invalid.inspection?["oneRetainedCompletion"] == nil)
        let alias = BrowserDownloadObservationSnapshot(inspection: [
            "event": "ownerSnapshot",
            "active": "1",
            "retained": "1",
        ])
        .addingFixtureProofs(expectedStagingBytes: 151)
        #expect(alias.inspection?["oneActiveWriter"] == "true")
        #expect(alias.inspection?["oneRetainedCompletion"] == "true")
    }

    @Test("Finite response and native progress proofs preserve exact correlated byte bounds")
    func finiteFixtureBoundsDeriveFromRawCorrelatedRecords() {
        let raw = finiteProofFixture()
        let prepared = raw.addingFixtureProofs(expectedStagingBytes: 151)
        #expect(prepared.events[1]["finiteResponseBoundsValid"] == "true")
        #expect(prepared.events[2]["nativeProgressBoundsValid"] == "true")
        #expect(prepared.events[2]["progressPositive"] == "true")
        #expect(raw.events[1]["finiteResponseBoundsValid"] == nil)
        let fixture = ReceiptFixture()
        fixture.context = changed(.phase, in: fixture.context)
        let locked = prepared.projected(for: fixture.context)
        #expect(locked.events[1]["finiteResponseBoundsValid"] == "true")
        #expect(locked.events[2]["nativeProgressBoundsValid"] == "true")
        #expect(locked.events[2]["receivedBytes"] == nil)
        #expect(locked.events[1]["prefixBytes"] == nil)
    }

    @Test(
        "Correlated fixture proofs cannot join different identities",
        arguments: ["runID", "fixtureRequest", "operation", "connectionID"],
    )
    func finiteFixtureProofRejectsWrongCorrelation(key: String) {
        var records = finiteProofFixture().events
        records[0][key] = "another-identity"
        let prepared = BrowserDownloadObservationSnapshot(events: records)
            .addingFixtureProofs(expectedStagingBytes: 151)
        #expect(prepared.events[1]["finiteResponseBoundsValid"] != "true")
        #expect(prepared.events[2]["nativeProgressBoundsValid"] != "true")
        records = finiteProofFixture().events
        records[2][key] = "another-identity"
        #expect(BrowserDownloadObservationSnapshot(events: records)
            .addingFixtureProofs(expectedStagingBytes: 151)
            .events[2]["nativeProgressBoundsValid"] != "true")
    }

    @Test("Duplicate readiness or response records cannot establish native progress bounds")
    func finiteFixtureProofRejectsDuplicateMatches() {
        let records = finiteProofFixture().events
        let duplicateReadiness = BrowserDownloadObservationSnapshot(events: records + [records[0]])
            .addingFixtureProofs(expectedStagingBytes: 151)
        #expect(duplicateReadiness.events[1]["finiteResponseBoundsValid"] != "true")
        #expect(duplicateReadiness.events[2]["nativeProgressBoundsValid"] != "true")
        let duplicateResponse = BrowserDownloadObservationSnapshot(events: records + [records[1]])
            .addingFixtureProofs(expectedStagingBytes: 151)
        #expect(duplicateResponse.events[2]["nativeProgressBoundsValid"] != "true")
    }

    @Test("Wrong response math, expected strings and native progress bounds cannot pass")
    func finiteFixtureProofRejectsWrongBytes() {
        for (index, key, value) in [
            (1, "remainderBytes", "11"),
            (1, "prefixBytes", "0"),
            (1, "expectedBytes", "17"),
            (0, "expectedBytes", "016"),
            (2, "receivedBytes", "4"),
            (2, "receivedBytes", "17"),
            (2, "expectedBytes", "016"),
            (2, "expectedBytes", "17"),
        ] {
            var records = finiteProofFixture().events
            records[index][key] = value
            let prepared = BrowserDownloadObservationSnapshot(events: records)
                .addingFixtureProofs(expectedStagingBytes: 151)
            #expect(prepared.events[2]["nativeProgressBoundsValid"] != "true")
            if index != 2 {
                #expect(prepared.events[1]["finiteResponseBoundsValid"] != "true")
            }
        }
    }
}

private func finiteProofFixture() -> BrowserDownloadObservationSnapshot {
    let identity = ["runID": "run", "fixtureRequest": "request", "operation": "operation", "connectionID": "connection"]
    let readiness = identity.merging(["event": "slowKnownReadiness", "expectedBytes": "16"]) { _, new in new }
    let response = identity.merging([
        "event": "finiteResponseCompleted",
        "expectedBytes": "16",
        "prefixBytes": "4",
        "remainderBytes": "12",
    ]) { _, new in new }
    let progress = identity.merging([
        "event": "nativePostLockProgress",
        "expectedBytes": "16",
        "receivedBytes": "8",
    ]) { _, new in new }
    return .init(events: [readiness, response, progress])
}

extension AppHostedUITests.BrowserDownloadObservationReceiptTests {
    @Test("Startup and active scene must both settle before publication", arguments: [true, false])
    func preparationRequiresStartupActiveAndPublication(startupFirst: Bool) throws {
        let fixture = ReceiptFixture()
        var preparation = BrowserDownloadObservationPreparation(processNonce: fixture.context.processNonce)
        #expect(!preparation.canPublish)
        #expect(!preparation.isReady)
        if startupFirst {
            preparation.markStartupComplete()
            #expect(!preparation.canPublish)
            preparation.observePhase(.active, ingestionBefore: 1, ingestionAfter: 2)
        } else {
            preparation.observePhase(.active, ingestionBefore: 1, ingestionAfter: 2)
            #expect(!preparation.canPublish)
            preparation.markStartupComplete()
        }
        #expect(preparation.startupComplete)
        #expect(preparation.phase == .active)
        #expect(preparation.revision == 2)
        #expect(preparation.ingestionBeforePhase == 1)
        #expect(preparation.ingestionAfterPhase == 2)
        #expect(preparation.canPublish)
        #expect(!preparation.isReady)
        let publicationAccepted1 = preparation.markPublished(context: fixture.context, revision: preparation.revision)
        #expect(publicationAccepted1)
        #expect(preparation.isReady)
        #expect(preparation.publishedContext == fixture.context)
        let encoded = try JSONEncoder().encode(preparation)
        #expect(try JSONDecoder().decode(BrowserDownloadObservationPreparation.self, from: encoded) == preparation)
    }

    @Test("Phase changes invalidate publication and stale or wrong-nonce publications cannot restore readiness")
    func preparationRejectsStalePublication() {
        let fixture = ReceiptFixture()
        var preparation = BrowserDownloadObservationPreparation(processNonce: fixture.context.processNonce)
        preparation.markStartupComplete()
        preparation.observePhase(.active, ingestionBefore: 1, ingestionAfter: 2)
        let previous = preparation.revision
        let publicationAccepted2 = preparation.markPublished(context: fixture.context, revision: previous)
        #expect(publicationAccepted2)
        for phase in [BrowserDownloadObservationPreparation.Phase.inactive, .background, .unknown] {
            preparation.observePhase(phase, ingestionBefore: 2, ingestionAfter: 3)
            #expect(!preparation.canPublish)
            #expect(!preparation.isReady)
            #expect(preparation.publishedContext == nil)
            #expect(preparation.publishedRevision == nil)
            let publicationAccepted3 = preparation.markPublished(
                context: fixture.context,
                revision: preparation.revision,
            )
            #expect(!publicationAccepted3)
        }
        preparation.observePhase(.active, ingestionBefore: 3, ingestionAfter: 4)
        let publicationAccepted4 = preparation.markPublished(context: fixture.context, revision: previous)
        #expect(!publicationAccepted4)
        let publicationAccepted5 = preparation.markPublished(
            context: changed(.process, in: fixture.context),
            revision: preparation.revision,
        )
        #expect(!publicationAccepted5)
        #expect(!preparation.isReady)
        let publicationAccepted6 = preparation.markPublished(context: fixture.context, revision: preparation.revision)
        #expect(publicationAccepted6)
        preparation.markStartupComplete()
        #expect(!preparation.isReady)
    }

    @Test("Preparation gating cannot bind or advance a cursor")
    func preparationDoesNotChangeCursorPosition() throws {
        let fixture = ReceiptFixture()
        let cursor = BrowserDownloadObservationCursor()
        try cursor.authorizeProcess(fixture.context.processNonce)
        var preparation = BrowserDownloadObservationPreparation(processNonce: fixture.context.processNonce)
        #expect(cursor.requiresInitialBaseline)
        #expect(try !cursor.validatePreparation(preparation))
        #expect(cursor.requiresInitialBaseline)
        preparation.markStartupComplete()
        preparation.observePhase(.active, ingestionBefore: 1, ingestionAfter: 2)
        let publicationAccepted7 = preparation.markPublished(context: fixture.context, revision: preparation.revision)
        #expect(publicationAccepted7)
        #expect(try cursor.validatePreparation(preparation))
        #expect(cursor.requiresInitialBaseline)
        try cursor.validateBaseline(fixture.controller.receipt, context: fixture.context)
        #expect(!cursor.requiresInitialBaseline)
        cursor.clearFailureEvidence()
        #expect(!cursor.requiresInitialBaseline)
        try cursor.authorizeProcess(UUID())
        #expect(cursor.requiresInitialBaseline)
        #expect(throws: BrowserDownloadObservationError.stale) {
            try cursor.validatePreparation(preparation)
        }
        #expect(cursor.lastFailure?.stage == .preparation)
    }

    @Test("Unknown or retired preparation nonces fail before pending readiness")
    func preparationRequiresAuthorizedProcess() throws {
        let fixture = ReceiptFixture()
        let cursor = BrowserDownloadObservationCursor()
        let preparation = BrowserDownloadObservationPreparation(processNonce: fixture.context.processNonce)
        #expect(throws: BrowserDownloadObservationError.stale) { try cursor.validatePreparation(preparation) }
        try cursor.authorizeProcess(fixture.context.processNonce)
        let wrong = BrowserDownloadObservationPreparation(processNonce: UUID())
        #expect(throws: BrowserDownloadObservationError.stale) { try cursor.validatePreparation(wrong) }
        try cursor.authorizeProcess(UUID())
        #expect(throws: BrowserDownloadObservationError.stale) { try cursor.validatePreparation(preparation) }
        #expect(cursor.lastFailure?.processWasRetired == true)
        #expect(cursor.requiresInitialBaseline)
    }

    @Test("Fresh post-active idle context rejects cached initial idle then admits the first real read")
    func preparationFencesInitialIngestionGeneration() async throws {
        let fixture = ReceiptFixture()
        fixture.context = .init(
            processNonce: fixture.context.processNonce,
            runID: fixture.context.runID,
            authorizationGeneration: 1,
            resourceGeneration: 0,
            ingestionGeneration: 1,
            phase: "locked",
        )
        let cursor = BrowserDownloadObservationCursor()
        try cursor.authorizeProcess(fixture.context.processNonce)
        let cached = fixture.controller.receipt
        var preparation = BrowserDownloadObservationPreparation(processNonce: fixture.context.processNonce)
        preparation.observePhase(.active, ingestionBefore: 1, ingestionAfter: 2)
        fixture.context = changed(.ingestion, in: fixture.context)
        preparation.markStartupComplete()
        let fresh = fixture.controller.receipt
        #expect(fresh.state == .idle)
        #expect(fresh.context.ingestionGeneration == 2)
        let publicationAccepted8 = preparation.markPublished(context: fresh.context, revision: preparation.revision)
        #expect(publicationAccepted8)
        #expect(throws: BrowserDownloadObservationError.stale) {
            try cursor.validatePreparation(preparation, baseline: cached)
        }
        #expect(cursor.lastFailure?.comparison == .preparationContext)
        #expect(cursor.lastFailure?.contextField == .ingestionGeneration)
        #expect(cursor.lastFailure?.baseline?.context.ingestionGeneration == 1)
        #expect(cursor.lastFailure?.context?.ingestionGeneration == 2)
        #expect(cursor.requiresInitialBaseline)
        #expect(try cursor.validatePreparation(preparation, baseline: fresh))
        #expect(cursor.requiresInitialBaseline)
        try cursor.validateBaseline(fresh, context: fresh.context)
        let completed = await fixture.controller.refresh { .init() }
        #expect(try cursor.validatedSnapshot(
            completed,
            after: fresh,
            context: fresh.context,
            deadline: .init(start: 100),
            now: 101,
        ) != nil)
        #expect(!cursor.requiresInitialBaseline)
    }

    @Test("Preparation readiness cannot waive post-request context changes or ABA", arguments: [true, false])
    func preparationDoesNotRelaxExistingContextFences(aba: Bool) async throws {
        let fixture = ReceiptFixture()
        let original = fixture.context
        let cursor = BrowserDownloadObservationCursor()
        try cursor.authorizeProcess(original.processNonce)
        var preparation = BrowserDownloadObservationPreparation(processNonce: original.processNonce)
        preparation.markStartupComplete()
        preparation.observePhase(.active, ingestionBefore: 1, ingestionAfter: 2)
        let publicationAccepted9 = preparation.markPublished(context: original, revision: preparation.revision)
        #expect(publicationAccepted9)
        let baseline = fixture.controller.receipt
        #expect(try cursor.validatePreparation(preparation, baseline: baseline))
        try cursor.validateBaseline(baseline, context: original)
        let gate = ReceiptInspectionGate()
        let task = Task { @MainActor in await fixture.controller.refresh { await gate.read() } }
        await gate.waitUntilStarted()
        fixture.context = changed(.ingestion, in: original)
        fixture.controller.contextDidChange()
        if aba {
            fixture.context = original
            fixture.controller.contextDidChange()
        }
        gate.finish(with: .init())
        let terminal = await task.value
        let expected: BrowserDownloadObservationError = aba ? .invalidated : .stale
        #expect(throws: expected) {
            try cursor.validatedSnapshot(
                terminal,
                after: baseline,
                context: original,
                deadline: .init(start: 100),
                now: 101,
            )
        }
        #expect(!cursor.requiresInitialBaseline)
    }
}

extension AppHostedUITests.BrowserDownloadObservationReceiptTests {
    @Test("Native lifecycle proofs require primary count fields, with consistent aliases")
    func nativeLifecycleProofsRequirePrimaryCounts() {
        for event in ["hiddenCompletion", "qualificationScenePhaseChanged"] {
            let aliasOnly = BrowserDownloadObservationSnapshot(events: [[
                "event": event,
                "active": "1",
                "retained": "1",
            ]]).addingFixtureProofs(expectedStagingBytes: 151)
            #expect(aliasOnly.events[0]["oneActiveWriter"] == nil)
            #expect(aliasOnly.events[0]["oneRetainedCompletion"] == nil)
            let primaryOnly = BrowserDownloadObservationSnapshot(events: [[
                "event": event,
                "activeWriterCount": "1",
                "retainedRecordCount": "1",
            ]]).addingFixtureProofs(expectedStagingBytes: 151)
            #expect(primaryOnly.events[0]["oneActiveWriter"] == "true")
            #expect(primaryOnly.events[0]["oneRetainedCompletion"] == "true")
            for primary in [nil, "invalid", "2"] as [String?] {
                var record = ["event": event, "active": "0", "retained": "1"]
                record["activeWriterCount"] = primary
                record["retainedRecordCount"] = primary
                let result = BrowserDownloadObservationSnapshot(events: [record])
                    .addingFixtureProofs(expectedStagingBytes: 151)
                #expect(result.events[0]["noActiveWriters"] != "true")
                #expect(result.events[0]["oneRetainedCompletion"] != "true")
                if primary == nil || primary == "invalid" {
                    #expect(result.events[0]["noActiveWriters"] == nil)
                    #expect(result.events[0]["oneRetainedCompletion"] == nil)
                }
            }
            for alias in ["invalid", "2"] {
                let record = [
                    "event": event,
                    "activeWriterCount": "0",
                    "active": alias,
                    "retainedRecordCount": "1",
                    "retained": alias,
                ]
                let result = BrowserDownloadObservationSnapshot(events: [record])
                    .addingFixtureProofs(expectedStagingBytes: 151)
                #expect(result.events[0]["noActiveWriters"] == nil)
                #expect(result.events[0]["oneRetainedCompletion"] == nil)
            }
        }
    }

    @Test("Owner snapshot content and retained proofs follow the actual authentication-loss schema")
    func ownerSnapshotContentProofRequiresExplicitEmptyContent() {
        let fixture = ReceiptFixture()
        fixture.context = changed(.phase, in: fixture.context)
        let raw = [
            "event": "ownerSnapshot",
            "operations": "",
            "presentation": "none",
            "active": "0",
            "retained": "1",
            "available": "false",
        ]
        let original = BrowserDownloadObservationSnapshot(inspection: raw, events: [raw])
        let prepared = original.addingFixtureProofs(expectedStagingBytes: 151)
        let projected = prepared.projected(for: fixture.context)
        #expect(projected.inspection?["ownerContentEmpty"] == "true")
        #expect(projected.events[0]["ownerContentEmpty"] == "true")
        #expect(projected.inspection?["oneRetainedCompletion"] == "true")
        #expect(projected.inspection?["available"] == "false")
        #expect(projected.inspection?["operations"] == nil)
        #expect(projected.inspection?["retained"] == nil)
        #expect(original.inspection == raw)
        #expect(original.events == [raw])
        for key in ["operations", "presentation"] {
            for value in [nil, "not-empty"] as [String?] {
                var record = raw
                record[key] = value
                record["ownerContentEmpty"] = "true"
                let result = BrowserDownloadObservationSnapshot(inspection: record)
                    .addingFixtureProofs(expectedStagingBytes: 151)
                    .projected(for: fixture.context)
                #expect(result.inspection?["ownerContentEmpty"] != "true")
            }
        }
        for value in [nil, "0", "2", "invalid"] as [String?] {
            var record = raw
            record["retained"] = value
            let result = BrowserDownloadObservationSnapshot(inspection: record)
                .addingFixtureProofs(expectedStagingBytes: 151)
            #expect(result.inspection?["oneRetainedCompletion"] != "true")
        }
        let forged = BrowserDownloadObservationSnapshot(inspection: [
            "event": "ownerSnapshot",
            "ownerContentEmpty": "true",
        ])
        .projected(for: fixture.context)
        #expect(forged.inspection?["ownerContentEmpty"] == "true")
    }
}

extension AppHostedUITests.BrowserDownloadObservationReceiptTests {
    @Test(
        "Actual storage and startup schema preserves its existing content boolean at both boundaries",
        arguments: ["true", "false", "missing"],
    )
    func legacyStorageContentSurvivesProofPreparation(value: String) async throws {
        let fixture = ReceiptFixture()
        fixture.context = changed(.phase, in: fixture.context)
        let baseline = fixture.controller.receipt
        let records = ["acceptedLibraryStorage", "libraryStartup"].map { event in
            var record = [
                "event": event,
                "temporaryCount": "1",
                "temporaryBytes": "151",
                "authenticated": "false",
                "libraryID": "opaque-library",
                "databaseID": "opaque-database",
            ]
            if value != "missing" {
                record["contentEmpty"] = value
            }
            return record
        }
        let raw = BrowserDownloadObservationSnapshot(inspection: records[0], events: records)
        let prepared = raw.addingFixtureProofs(expectedStagingBytes: 151)
        let produced = await fixture.controller.refresh { prepared }
        let validated = try produced.validatedSnapshot(
            after: baseline,
            context: fixture.context,
            deadline: .init(start: 100),
            now: 101,
        )
        let observed = try #require(validated)
        let expected = value == "missing" ? nil : value
        #expect(prepared.inspection?["contentEmpty"] == expected)
        #expect(observed.inspection?["contentEmpty"] == expected)
        for record in observed.events {
            #expect(record["contentEmpty"] == expected)
        }
        #expect(raw.inspection == records[0])
        #expect(raw.events == records)
    }

    @Test("Owner-only content proof cannot use forged facts or expose operation lists")
    func ownerContentProofRequiresRawOwnerEvidence() {
        let fixture = ReceiptFixture()
        fixture.context = changed(.phase, in: fixture.context)
        let records: [[String: String]] = [
            ["event": "ownerSnapshot", "ownerContentEmpty": "true"],
            [
                "event": "ownerSnapshot",
                "operations": "opaque-operation",
                "presentation": "none",
                "ownerContentEmpty": "true",
            ],
            ["event": "ownerSnapshot", "operations": "", "ownerContentEmpty": "true"],
            ["event": "ownerSnapshot", "presentation": "none", "ownerContentEmpty": "true"],
        ]
        for record in records {
            let result = BrowserDownloadObservationSnapshot(inspection: record, events: [record])
                .addingFixtureProofs(expectedStagingBytes: 151)
                .projected(for: fixture.context)
            #expect(result.inspection?["ownerContentEmpty"] != "true")
            #expect(result.inspection?["operations"] == nil)
            #expect(result.events[0]["operations"] == nil)
        }
    }
}

extension AppHostedUITests.BrowserDownloadObservationReceiptTests {
    @Test("A real context notification invalidates publication while preserving startup and scene state")
    func contextNotificationRequiresFreshPublication() async throws {
        let fixture = ReceiptFixture()
        let oldContext = fixture.context
        var preparation = BrowserDownloadObservationPreparation(processNonce: oldContext.processNonce)
        preparation.markStartupComplete()
        preparation.observePhase(.active, ingestionBefore: 1, ingestionAfter: 2)
        let published = preparation.markPublished(context: oldContext, revision: preparation.revision)
        #expect(published)
        let previousRevision = preparation.revision
        let cursor = BrowserDownloadObservationCursor()
        try cursor.authorizeProcess(oldContext.processNonce)
        fixture.context = changed(.authorization, in: oldContext)
        fixture.controller.contextDidChange()
        preparation.contextDidChange()
        #expect(preparation.revision == previousRevision + 1)
        #expect(preparation.startupComplete)
        #expect(preparation.phase == .active)
        #expect(preparation.ingestionBeforePhase == 1)
        #expect(preparation.ingestionAfterPhase == 2)
        #expect(preparation.canPublish)
        #expect(!preparation.isReady)
        #expect(preparation.publishedContext == nil)
        #expect(preparation.publishedRevision == nil)
        #expect(try !cursor.validatePreparation(preparation))
        #expect(cursor.requiresInitialBaseline)
        let oldPublication = preparation.markPublished(context: oldContext, revision: previousRevision)
        #expect(!oldPublication)
        let baseline = fixture.controller.receipt
        let freshPublication = preparation.markPublished(context: baseline.context, revision: preparation.revision)
        #expect(freshPublication)
        #expect(try cursor.validatePreparation(preparation, baseline: baseline))
        #expect(cursor.requiresInitialBaseline)
        try cursor.validateBaseline(baseline, context: fixture.context)
        let completed = await fixture.controller.refresh { .init() }
        let snapshot = try cursor.validatedSnapshot(
            completed,
            after: baseline,
            context: fixture.context,
            deadline: .init(start: 100),
            now: 101,
        )
        #expect(snapshot != nil)
    }

    @Test("Fresh preparation rejects an old authorization baseline")
    func freshPreparationRejectsOldAuthorizationBaseline() throws {
        let fixture = ReceiptFixture()
        let old = fixture.controller.receipt
        var preparation = BrowserDownloadObservationPreparation(processNonce: fixture.context.processNonce)
        preparation.markStartupComplete()
        preparation.observePhase(.active, ingestionBefore: 2, ingestionAfter: 2)
        _ = preparation.markPublished(context: old.context, revision: preparation.revision)
        fixture.context = changed(.authorization, in: fixture.context)
        preparation.contextDidChange()
        _ = preparation.markPublished(context: fixture.controller.receipt.context, revision: preparation.revision)
        let cursor = BrowserDownloadObservationCursor()
        try cursor.authorizeProcess(fixture.context.processNonce)
        #expect(throws: BrowserDownloadObservationError.stale) {
            try cursor.validatePreparation(preparation, baseline: old)
        }
        #expect(cursor.lastFailure?.comparison == .preparationContext)
        #expect(cursor.lastFailure?.contextField == .authorizationGeneration)
        #expect(cursor.requiresInitialBaseline)
    }

    @Test("An old preparation cannot authorize the current authorization baseline")
    func oldPreparationRejectsCurrentAuthorizationBaseline() throws {
        let fixture = ReceiptFixture()
        var preparation = BrowserDownloadObservationPreparation(processNonce: fixture.context.processNonce)
        preparation.markStartupComplete()
        preparation.observePhase(.active, ingestionBefore: 2, ingestionAfter: 2)
        _ = preparation.markPublished(context: fixture.context, revision: preparation.revision)
        let old = preparation
        fixture.context = changed(.authorization, in: fixture.context)
        preparation.contextDidChange()
        let cursor = BrowserDownloadObservationCursor()
        try cursor.authorizeProcess(fixture.context.processNonce)
        #expect(throws: BrowserDownloadObservationError.stale) {
            try cursor.validatePreparation(old, baseline: fixture.controller.receipt)
        }
        #expect(cursor.lastFailure?.contextField == .authorizationGeneration)
        #expect(cursor.requiresInitialBaseline)
    }

    @Test("Context notification and republication cannot reset an accepted cursor")
    func contextNotificationCannotResetAcceptedCursor() async throws {
        let fixture = ReceiptFixture()
        let original = fixture.controller.receipt
        let cursor = BrowserDownloadObservationCursor()
        try cursor.authorizeProcess(fixture.context.processNonce)
        try cursor.validateBaseline(original, context: fixture.context)
        let completed = await fixture.controller.refresh { .init() }
        _ = try cursor.validatedSnapshot(
            completed,
            after: original,
            context: fixture.context,
            deadline: .init(start: 100),
            now: 101,
        )
        var preparation = BrowserDownloadObservationPreparation(processNonce: fixture.context.processNonce)
        preparation.markStartupComplete()
        preparation.observePhase(.active, ingestionBefore: 2, ingestionAfter: 2)
        _ = preparation.markPublished(context: fixture.context, revision: preparation.revision)
        fixture.context = changed(.authorization, in: fixture.context)
        preparation.contextDidChange()
        #expect(try !cursor.validatePreparation(preparation))
        #expect(!cursor.requiresInitialBaseline)
        let baseline = fixture.controller.receipt
        _ = preparation.markPublished(context: baseline.context, revision: preparation.revision)
        #expect(try cursor.validatePreparation(preparation, baseline: baseline))
        try cursor.validateBaseline(baseline, context: fixture.context)
        #expect(throws: BrowserDownloadObservationError.stale) {
            try cursor.validateBaseline(original, context: original.context)
        }
        #expect(cursor.lastFailure?.comparison == .acceptedPosition)
        #expect(!cursor.requiresInitialBaseline)
    }

    @Test(
        "Context republication cannot admit a suspended read after authorization change or ABA",
        arguments: [false, true],
    )
    func postAdmissionContextChangeStillRejects(aba: Bool) async throws {
        let fixture = ReceiptFixture()
        let original = fixture.context
        let baseline = fixture.controller.receipt
        let cursor = BrowserDownloadObservationCursor()
        try cursor.authorizeProcess(original.processNonce)
        try cursor.validateBaseline(baseline, context: original)
        var preparation = BrowserDownloadObservationPreparation(processNonce: original.processNonce)
        preparation.markStartupComplete()
        preparation.observePhase(.active, ingestionBefore: 2, ingestionAfter: 2)
        _ = preparation.markPublished(context: original, revision: preparation.revision)
        let gate = ReceiptInspectionGate()
        let task = Task { @MainActor in await fixture.controller.refresh { await gate.read() } }
        await gate.waitUntilStarted()
        fixture.context = changed(.authorization, in: original)
        fixture.controller.contextDidChange()
        preparation.contextDidChange()
        _ = preparation.markPublished(context: fixture.context, revision: preparation.revision)
        if aba {
            fixture.context = original
            fixture.controller.contextDidChange()
            preparation.contextDidChange()
            _ = preparation.markPublished(context: original, revision: preparation.revision)
        }
        gate.finish(with: .init())
        let terminal = await task.value
        let expected: BrowserDownloadObservationError = aba ? .invalidated : .stale
        #expect(throws: expected) {
            try cursor.validatedSnapshot(
                terminal,
                after: baseline,
                context: original,
                deadline: .init(start: 100),
                now: 101,
            )
        }
        #expect(!cursor.requiresInitialBaseline)
    }
}
