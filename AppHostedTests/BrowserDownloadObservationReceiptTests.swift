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
    @MainActor
    @Suite("Passive browser download qualification")
    struct BrowserDownloadObservationReceiptTests {}
}

extension AppHostedUITests.BrowserDownloadObservationReceiptTests {
    @Test("Completed attachment proof follows one new policy, handoff, and writer in the same context")
    func completedAttachmentRequiresFreshCorrelatedHandoff() {
        let context = BrowserDownloadObservationContext(
            processNonce: UUID(),
            runID: UUID().uuidString,
            authorizationGeneration: 2,
            resourceGeneration: 3,
            ingestionGeneration: 4,
            phase: "authenticated",
        )
        let base: [String: String] = [
            "event": "loopbackReady",
            "runID": context.runID,
            "monotonicSeconds": "0",
        ]
        let requestID = UUID().uuidString
        let operationID = UUID().uuidString
        let capability = UUID().uuidString
        func attachmentEvents(handoffRequestID: String, proofOperationID: String) -> [[String: String]] {
            [
                [
                    "event": "fixtureNavigationRequested",
                    "runID": context.runID,
                    "fixtureRoute": "attachment",
                    "fixtureRequest": requestID,
                    "monotonicSeconds": "1",
                ],
                [
                    "event": "policyDownloadAdmitted",
                    "runID": context.runID,
                    "operation": operationID,
                    "capability": capability,
                    "monotonicSeconds": "1.5",
                ],
                [
                    "event": "nativeDownloadHandoff",
                    "operation": operationID,
                    "runID": context.runID,
                    "fixtureRoute": "attachment",
                    "fixtureRequest": handoffRequestID,
                    "fixtureOrigin": "true",
                    "sameOrigin": "true",
                    "monotonicSeconds": "2",
                ],
                [
                    "event": "transferAdmitted",
                    "runID": context.runID,
                    "capability": capability,
                    "operation": operationID,
                    "monotonicSeconds": "3",
                ],
                [
                    "event": "writerFinished",
                    "runID": context.runID,
                    "operation": operationID,
                    "monotonicSeconds": "4",
                ],
                [
                    "event": "completedFileProof",
                    "runID": context.runID,
                    "operation": proofOperationID,
                    "processNonce": context.processNonce.uuidString,
                    "generation": String(context.authorizationGeneration),
                    "authorizationGeneration": String(context.authorizationGeneration),
                    "resourceGeneration": String(context.resourceGeneration),
                    "ingestionGeneration": String(context.ingestionGeneration),
                    "phase": context.phase,
                    "phaseRevision": String(context.phaseRevision),
                    "ready": "true",
                    "monotonicSeconds": "5",
                ],
            ]
        }

        let baseline = BrowserDownloadPassiveObservation(context: context, events: [base])
        let validEvents = attachmentEvents(handoffRequestID: requestID, proofOperationID: operationID)
        let valid = BrowserDownloadPassiveObservation(context: context, events: [base] + validEvents)
        #expect(valid.completedAttachment(after: baseline) != nil)

        let wrongCapability = validEvents.map { event in
            event["event"] == "transferAdmitted" ? event.merging(["capability": UUID().uuidString]) { $1 } : event
        }
        #expect(BrowserDownloadPassiveObservation(context: context, events: [base] + wrongCapability)
            .completedAttachment(after: baseline) == nil)

        let oldBaseline = BrowserDownloadPassiveObservation(context: context, events: [base] + validEvents)
        #expect(oldBaseline.completedAttachment(after: oldBaseline) == nil)

        let unrelatedRequest = BrowserDownloadPassiveObservation(
            context: context,
            events: [base] + attachmentEvents(handoffRequestID: UUID().uuidString, proofOperationID: operationID),
        )
        #expect(unrelatedRequest.completedAttachment(after: baseline) == nil)

        let unrelatedOperation = BrowserDownloadPassiveObservation(
            context: context,
            events: [base] + attachmentEvents(handoffRequestID: requestID, proofOperationID: UUID().uuidString),
        )
        #expect(unrelatedOperation.completedAttachment(after: baseline) == nil)

        let changedAuthorization = BrowserDownloadObservationContext(
            processNonce: context.processNonce,
            runID: context.runID,
            authorizationGeneration: context.authorizationGeneration + 1,
            resourceGeneration: context.resourceGeneration,
            ingestionGeneration: context.ingestionGeneration,
            phase: context.phase,
        )
        let staleAuthorization = BrowserDownloadPassiveObservation(
            context: changedAuthorization,
            events: [base] + validEvents,
        )
        #expect(staleAuthorization.completedAttachment(after: baseline) == nil)
    }

    @Test("Completed-file proof survives unrelated event rollover and still requires milestones")
    func completedAttachmentSurvivesIrrelevantPrefixRollover() {
        let context = BrowserDownloadObservationContext(
            processNonce: UUID(),
            runID: UUID().uuidString,
            authorizationGeneration: 2,
            resourceGeneration: 3,
            ingestionGeneration: 4,
            phase: "authenticated",
        )
        let prefixEvents: [[String: String]] = (0 ..< 256).map { index in
            [
                "event": index == 0 ? "loopbackReady" : "testDiagnosticNoise",
                "runID": context.runID,
                "monotonicSeconds": String(index),
            ]
        }
        let baseline = BrowserDownloadPassiveObservation(context: context, events: prefixEvents)
        let requestID = UUID().uuidString
        let operationID = UUID().uuidString
        let capabilityID = UUID().uuidString
        let milestones: [[String: String]] = [
            [
                "event": "fixtureNavigationRequested",
                "runID": context.runID,
                "fixtureRoute": "attachment",
                "fixtureRequest": requestID,
                "monotonicSeconds": "256",
            ],
            [
                "event": "policyDownloadAdmitted",
                "runID": context.runID,
                "operation": operationID,
                "capability": capabilityID,
                "monotonicSeconds": "257",
            ],
            [
                "event": "nativeDownloadHandoff",
                "runID": context.runID,
                "operation": operationID,
                "fixtureRoute": "attachment",
                "fixtureRequest": requestID,
                "fixtureOrigin": "true",
                "sameOrigin": "true",
                "monotonicSeconds": "258",
            ],
            [
                "event": "transferAdmitted",
                "runID": context.runID,
                "operation": operationID,
                "capability": capabilityID,
                "monotonicSeconds": "259",
            ],
            [
                "event": "writerFinished",
                "runID": context.runID,
                "operation": operationID,
                "monotonicSeconds": "260",
            ],
            [
                "event": "completedFileProof",
                "runID": context.runID,
                "operation": operationID,
                "processNonce": context.processNonce.uuidString,
                "generation": String(context.authorizationGeneration),
                "authorizationGeneration": String(context.authorizationGeneration),
                "resourceGeneration": String(context.resourceGeneration),
                "ingestionGeneration": String(context.ingestionGeneration),
                "phaseRevision": String(context.phaseRevision),
                "phase": context.phase,
                "ready": "true",
                "monotonicSeconds": "261",
            ],
        ]
        let retainedPrefix = Array(prefixEvents.dropFirst(milestones.count))
        func rolledObservation(_ evidence: [[String: String]], pad: Bool = false) -> BrowserDownloadPassiveObservation {
            var events = retainedPrefix + evidence
            if pad {
                events.append([
                    "event": "testDiagnosticNoise",
                    "runID": context.runID,
                    "monotonicSeconds": "262",
                ])
            }

            return BrowserDownloadPassiveObservation(
                context: context,
                events: events,
                discardedEventCount: milestones.count,
            )
        }

        let complete = rolledObservation(milestones)
        #expect(complete.events.count == baseline.events.count)
        #expect(complete.discardedEventCount != baseline.discardedEventCount)
        #expect(!complete.truncated)
        #expect(Array(complete.events.prefix(baseline.events.count)) != baseline.events)
        #expect(milestones.map { $0["event"] } == [
            "fixtureNavigationRequested",
            "policyDownloadAdmitted",
            "nativeDownloadHandoff",
            "transferAdmitted",
            "writerFinished",
            "completedFileProof",
        ])
        #expect(milestones[0]["fixtureRequest"] == milestones[2]["fixtureRequest"])
        #expect(milestones[1]["operation"] == milestones[2]["operation"])
        #expect(milestones[1]["operation"] == milestones[3]["operation"])
        #expect(milestones[1]["capability"] == milestones[3]["capability"])
        #expect(milestones[1]["operation"] == milestones[4]["operation"])
        let proof = complete.completedAttachment(after: baseline)
        #expect(proof?["operation"] == operationID)
        #expect(proof?["ready"] == "true")

        let missingPolicy = rolledObservation(milestones.filter { $0["event"] != "policyDownloadAdmitted" }, pad: true)
        #expect(missingPolicy.completedAttachment(after: baseline) == nil)

        let evictedFinish = rolledObservation(milestones.filter { $0["event"] != "writerFinished" }, pad: true)
        #expect(evictedFinish.completedAttachment(after: baseline) == nil)
    }

    @Test("Passive event values scope the current run and redact file proofs while locked")
    func passiveObservationScopesAndRedactsLockedFileProofs() {
        let context = BrowserDownloadObservationContext(
            processNonce: UUID(),
            runID: UUID().uuidString,
            authorizationGeneration: 4,
            resourceGeneration: 5,
            ingestionGeneration: 6,
            phase: "locked",
        )
        let operation = UUID().uuidString
        let proof: [String: String] = [
            "event": "completedFileProof",
            "runID": context.runID,
            "operation": operation,
            "allocation": "private-allocation",
            "bytes": "608",
            "sha256": "private-hash",
        ]
        let finished: [String: String] = [
            "event": "writerFinished",
            "runID": context.runID,
            "operation": operation,
            "authenticated": "false",
        ]
        let hidden: [String: String] = [
            "event": "hiddenCompletion",
            "runID": context.runID,
            "operation": operation,
            "activeWriterCount": "0",
            "retainedRecordCount": "1",
            "authenticated": "false",
            "available": "false",
            "contentEmpty": "true",
        ]
        let previousRun: [String: String] = [
            "event": "writerFinished",
            "runID": UUID().uuidString,
            "operation": UUID().uuidString,
        ]

        let value = BrowserDownloadPassiveObservation(context: context, events: [proof, finished, hidden, previousRun])

        #expect(value.events.map { $0["event"] } == ["writerFinished", "hiddenCompletion"])
        #expect(value.events[0] == finished)
        #expect(value.events[1]["noActiveWriters"] == "true")
        #expect(value.events[1]["oneRetainedCompletion"] == "true")
        #expect(value.events[1]["activeWriterCount"] == nil)
        #expect(value.events[1]["retainedRecordCount"] == nil)
        #expect(value.events[0]["allocation"] == nil)
        #expect(value.events[0]["bytes"] == nil)
        #expect(value.events[0]["sha256"] == nil)
    }

    @Test("Authenticated passive values retain the current completed-file proof")
    func authenticatedPassiveObservationKeepsCompletedFileProof() {
        let context = BrowserDownloadObservationContext(
            processNonce: UUID(),
            runID: UUID().uuidString,
            authorizationGeneration: 4,
            resourceGeneration: 5,
            ingestionGeneration: 6,
            phase: "authenticated",
        )
        let proof: [String: String] = [
            "event": "completedFileProof",
            "runID": context.runID,
            "operation": UUID().uuidString,
            "processNonce": context.processNonce.uuidString,
            "authorizationGeneration": String(context.authorizationGeneration),
            "resourceGeneration": String(context.resourceGeneration),
            "ingestionGeneration": String(context.ingestionGeneration),
            "phase": context.phase,
            "phaseRevision": String(context.phaseRevision),
            "ready": "true",
            "bytes": "608",
            "sha256": "fixture-hash",
        ]

        let value = BrowserDownloadPassiveObservation(context: context, events: [proof])

        #expect(value.events == [proof])
    }

    @Test("Passive event decoding rejects oversized and unscoped histories")
    func passiveDecodingRejectsIncompleteHistory() throws {
        let context = BrowserDownloadObservationContext(
            processNonce: UUID(),
            runID: UUID().uuidString,
            authorizationGeneration: 1,
            resourceGeneration: 1,
            ingestionGeneration: 1,
            phase: "authenticated",
        )
        let event = ["event": "loopbackReady", "runID": context.runID]
        let oversized = BrowserDownloadPassiveObservation(
            context: context,
            events: Array(repeating: event, count: BrowserDownloadPassiveObservation.maximumEventCount + 1),
        )
        let oversizedWire = try String(decoding: JSONEncoder().encode(oversized), as: UTF8.self)
        #expect(throws: BrowserDownloadObservationError.malformed) {
            try BrowserDownloadPassiveObservation.decode(oversizedWire)
        }

        let unscoped = BrowserDownloadPassiveObservation(context: context, events: [[
            "event": "loopbackReady",
            "runID": UUID().uuidString,
        ]])
        let unscopedWire = try String(decoding: JSONEncoder().encode(unscoped), as: UTF8.self)
        #expect(throws: BrowserDownloadObservationError.malformed) {
            try BrowserDownloadPassiveObservation.decode(unscopedWire)
        }
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
            ]]).addingFixtureProofs()
            #expect(aliasOnly.events[0]["oneActiveWriter"] == nil)
            #expect(aliasOnly.events[0]["oneRetainedCompletion"] == nil)
            let primaryOnly = BrowserDownloadObservationSnapshot(events: [[
                "event": event,
                "activeWriterCount": "1",
                "retainedRecordCount": "1",
            ]]).addingFixtureProofs()
            #expect(primaryOnly.events[0]["oneActiveWriter"] == "true")
            #expect(primaryOnly.events[0]["oneRetainedCompletion"] == "true")
            for primary in [nil, "invalid", "2"] as [String?] {
                var record = ["event": event, "active": "0", "retained": "1"]
                record["activeWriterCount"] = primary
                record["retainedRecordCount"] = primary
                let result = BrowserDownloadObservationSnapshot(events: [record])
                    .addingFixtureProofs()
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
                    .addingFixtureProofs()
                #expect(result.events[0]["noActiveWriters"] == nil)
                #expect(result.events[0]["oneRetainedCompletion"] == nil)
            }
        }
    }
}

extension AppHostedUITests.BrowserDownloadObservationReceiptTests {
    @Test("Finite response and native progress proofs preserve exact correlated byte bounds")
    func finiteFixtureBoundsDeriveFromRawCorrelatedRecords() {
        let raw = finiteProofFixture()
        let prepared = raw.addingFixtureProofs()
        #expect(prepared.events[1]["finiteResponseBoundsValid"] == "true")
        #expect(prepared.events[2]["nativeProgressBoundsValid"] == "true")
        #expect(prepared.events[2]["progressPositive"] == "true")
        #expect(raw.events[1]["finiteResponseBoundsValid"] == nil)
        let locked = prepared.projected(for: ReaderFixture(phase: "locked").context)
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
            .addingFixtureProofs()
        #expect(prepared.events[1]["finiteResponseBoundsValid"] != "true")
        #expect(prepared.events[2]["nativeProgressBoundsValid"] != "true")
        records = finiteProofFixture().events
        records[2][key] = "another-identity"
        #expect(BrowserDownloadObservationSnapshot(events: records)
            .addingFixtureProofs()
            .events[2]["nativeProgressBoundsValid"] != "true")
    }

    @Test("Duplicate readiness or response records cannot establish native progress bounds")
    func finiteFixtureProofRejectsDuplicateMatches() {
        let records = finiteProofFixture().events
        let duplicateReadiness = BrowserDownloadObservationSnapshot(events: records + [records[0]])
            .addingFixtureProofs()
        #expect(duplicateReadiness.events[1]["finiteResponseBoundsValid"] != "true")
        #expect(duplicateReadiness.events[2]["nativeProgressBoundsValid"] != "true")
        let duplicateResponse = BrowserDownloadObservationSnapshot(events: records + [records[1]])
            .addingFixtureProofs()
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
                .addingFixtureProofs()
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

@MainActor
private final class ReaderFixture {
    let context: BrowserDownloadObservationContext
    let reader: BrowserDownloadPassiveReader
    var time: TimeInterval = 100
    var interrupted = false

    init(phase: String = "authenticated") {
        context = .init(
            processNonce: UUID(),
            runID: UUID().uuidString,
            authorizationGeneration: 2,
            resourceGeneration: 3,
            ingestionGeneration: 4,
            phase: phase,
            phaseRevision: 1,
        )
        reader = .init(processNonce: context.processNonce)
    }

    func sample(_ event: String = "loopbackReady") -> BrowserDownloadPassiveObservation {
        .init(context: context, events: [["runID": context.runID, "event": event]])
    }

    func read(
        sample: @escaping () throws -> BrowserDownloadPassiveObservation,
        matching: @escaping (BrowserDownloadPassiveObservation) throws
            -> Bool = { $0.events.last?["event"] == "loopbackReady" },
        wait: (TimeInterval, @escaping @MainActor () -> Bool) -> BrowserDownloadPassiveReader.WaitResult = { _, _ in
            Issue.record("An immediately resolved observation entered the waiter")
            return .interrupted
        },
    ) throws -> BrowserDownloadPassiveObservation {
        try reader.read(
            now: { self.time },
            interrupted: { self.interrupted },
            sample: sample,
            matching: matching,
            wait: wait,
        )
    }
}

extension AppHostedUITests.BrowserDownloadObservationReceiptTests {
    @Test
    func passiveReaderAcceptsAvailableMilestoneBeforeWaiting() throws {
        let fixture = ReaderFixture()
        let ready = fixture.sample()
        let result = try fixture.read(sample: { ready })
        #expect(result == ready)
    }

    @Test
    func passiveReaderPollsUntilMilestoneAppears() throws {
        let fixture = ReaderFixture()
        var calls = 0
        let result = try fixture.read(sample: {
            calls += 1
            if calls == 1 {
                throw BrowserDownloadObservationError.missing
            }
            return calls == 2 ? fixture.sample("ownerSnapshot") : fixture.sample()
        }, wait: { interval, poll in
            #expect(interval == 10)
            #expect(!poll())
            fixture.time = 109
            #expect(poll())
            return .completed
        })
        #expect(calls == 3)
        #expect(result == fixture.sample())
    }

    @Test
    func passiveReaderRejectsUnchangedMilestone() {
        let fixture = ReaderFixture()
        let previous = fixture.sample()
        #expect(throws: BrowserDownloadObservationError.deadlineExceeded) {
            try fixture.read(
                sample: { previous },
                matching: { $0.completedAttachment(after: previous) != nil },
                wait: { _, poll in
                    #expect(!poll())
                    return .timedOut
                },
            )
        }
    }

    @Test
    func passiveReaderRejectsWrongProcessRunAndContext() throws {
        let fixture = ReaderFixture()
        let current = fixture.context
        _ = try fixture.read(sample: { fixture.sample() })
        func reject(_ context: BrowserDownloadObservationContext) {
            #expect(throws: BrowserDownloadObservationError.stale) {
                try fixture.read(sample: { .init(context: context, events: []) })
            }
        }
        reject(ReaderFixture().context)
        reject(.init(
            processNonce: current.processNonce,
            runID: UUID().uuidString,
            authorizationGeneration: 2,
            resourceGeneration: 3,
            ingestionGeneration: 4,
            phase: "authenticated",
            phaseRevision: 1,
        ))
        for generations in [(1, 3, 4), (2, 2, 4), (2, 3, 3)] {
            reject(.init(
                processNonce: current.processNonce,
                runID: current.runID,
                authorizationGeneration: UInt64(generations.0),
                resourceGeneration: UInt64(generations.1),
                ingestionGeneration: UInt64(generations.2),
                phase: "authenticated",
                phaseRevision: 1,
            ))
        }
        var newer = current
        newer.phaseRevision += 2
        try fixture.reader.validate(.init(context: newer, events: []))
        reject(current)
    }

    @Test
    func passiveReaderPreservesInvalidatedMalformedAndMissing() {
        let fixture = ReaderFixture()
        for (outcome, error) in [
            (BrowserDownloadLibraryObservation.Outcome.invalidated, BrowserDownloadObservationError.invalidated),
            (.failed, .failed),
            (.unavailable, .unavailable),
        ] {
            let library = BrowserDownloadLibraryObservation(context: fixture.context, outcome: outcome, fields: [:])
            #expect(throws: error) {
                try fixture.read(
                    sample: { .init(context: fixture.context, events: [], library: library) },
                    matching: { try $0.library?.completedFields() != nil },
                )
            }
        }
        #expect(throws: BrowserDownloadObservationError.malformed) {
            try fixture.read(sample: { try .decode("malformed") })
        }
        #expect(throws: BrowserDownloadObservationError.missing) {
            try fixture.read(sample: { try .decode(nil) }, wait: { _, poll in
                #expect(!poll())
                return .timedOut
            })
        }
    }

    @Test
    func passiveReaderRejectsMilestoneAtAndAfterDeadline() {
        for time in [110.0, 111.0] {
            let fixture = ReaderFixture()
            #expect(throws: BrowserDownloadObservationError.deadlineExceeded) {
                try fixture.read(sample: { fixture.time = time
                    return fixture.sample()
                })
            }
        }
    }

    @Test
    func passiveReaderChecksDeadlineAfterWaiterCompletes() {
        let fixture = ReaderFixture()
        var ready = false
        #expect(throws: BrowserDownloadObservationError.deadlineExceeded) {
            try fixture.read(sample: { fixture.sample(ready ? "loopbackReady" : "ownerSnapshot") }, wait: { _, poll in
                ready = true
                #expect(poll())
                fixture.time = 110
                return .completed
            })
        }
    }

    @Test
    func passiveReaderPreservesInterruption() {
        let fixture = ReaderFixture()
        #expect(throws: BrowserDownloadObservationError.interrupted) {
            try fixture.read(sample: { fixture.sample("ownerSnapshot") }, wait: { _, _ in .interrupted })
        }
        #expect(throws: BrowserDownloadObservationError.interrupted) {
            try fixture.read(sample: { fixture.interrupted = true
                return fixture.sample()
            })
        }
    }

    @Test
    func passiveReaderMapsPendingTimeoutToOriginalDeadline() {
        let fixture = ReaderFixture()
        #expect(throws: BrowserDownloadObservationError.deadlineExceeded) {
            try fixture.read(sample: {
                fixture.time = 104
                return fixture.sample("ownerSnapshot")
            }, wait: { budget, _ in
                #expect(budget == 6)
                return .timedOut
            })
        }
    }

    @Test
    func lockedStorageRejectsCanonicalQuantitiesAndForeignContexts() throws {
        let locked = ReaderFixture(phase: "locked")
        let fields = [
            "event": "libraryStartup",
            "libraryID": UUID().uuidString,
            "databaseID": String(repeating: "a", count: 64),
            "processID": "1",
            "runID": locked.context.runID,
            "authenticated": "false",
            "contentEmpty": "true",
            "singleStagedFixture": "false",
            "stagingEmpty": "true",
        ]
        func sample(_ extra: [String: String]) -> BrowserDownloadLibraryObservation {
            .init(context: locked.context, outcome: .complete, fields: fields.merging(extra) { _, new in new })
        }
        try sample([:]).validate(for: locked.context)
        for extra in [
            ["assetCount": "0"],
            ["temporaryBytes": "151"],
            ["operation": UUID().uuidString],
            ["event": "canonicalLibrarySnapshot"],
            ["singleStagedFixture": "true"],
            ["contentEmpty": "missing"],
        ] {
            #expect(throws: BrowserDownloadObservationError.malformed) {
                try sample(extra).validate(for: locked.context)
            }
        }
        #expect(throws: BrowserDownloadObservationError.stale) {
            try sample([:]).validate(for: ReaderFixture().context)
        }
    }

    @Test
    func stagingAndCanonicalMilestonesRequireOneNewFinishedOperation() {
        let context = ReaderFixture().context
        let request = UUID().uuidString
        let operation = UUID().uuidString
        let capability = UUID().uuidString
        let initial = ["event": "loopbackReady", "runID": context.runID, "monotonicSeconds": "1"]
        let baseline = BrowserDownloadPassiveObservation(context: context, events: [initial])
        let locked = BrowserDownloadObservationContext(
            processNonce: context.processNonce,
            runID: context.runID,
            authorizationGeneration: context.authorizationGeneration + 1,
            resourceGeneration: context.resourceGeneration + 1,
            ingestionGeneration: context.ingestionGeneration + 1,
            phase: "locked",
            phaseRevision: context.phaseRevision + 1,
        )
        func observed(
            underLock: Bool,
            wrongRequest: Bool = false,
            wrongWriter: Bool = false,
            missingLock: Bool = false,
        ) -> BrowserDownloadPassiveObservation {
            var events: [[String: String]] = [initial]
            func append(_ event: String, _ fields: [String: String] = [:]) {
                events.append(fields.merging([
                    "event": event,
                    "runID": context.runID,
                    "monotonicSeconds": String(events.count + 1),
                ]) { _, new in new })
            }
            append("fixtureNavigationRequested", ["fixtureRoute": "image", "fixtureRequest": request])
            append("policyDownloadAdmitted", ["operation": operation, "capability": capability])
            if underLock, !missingLock {
                append("automaticMediaPolicyLocked")
            }
            var handoff = [
                "fixtureRoute": "image",
                "fixtureRequest": wrongRequest ? UUID().uuidString : request,
                "sameOrigin": "true",
                "fixtureOrigin": "true",
            ]
            if !underLock {
                handoff["operation"] = operation
            }
            append("nativeDownloadHandoff", handoff)
            append("transferAdmitted", ["operation": operation, "capability": capability])
            append("writerFinished", ["operation": wrongWriter ? UUID().uuidString : operation])
            return .init(context: underLock ? locked : context, events: events)
        }
        for underLock in [false, true] {
            let sample = observed(underLock: underLock)
            #expect(sample.finishedOperation(after: baseline, route: "image", locked: underLock) == operation)
            #expect(sample.finishedOperation(after: sample, route: "image", locked: underLock) == nil)
            #expect(observed(underLock: underLock, wrongRequest: true).finishedOperation(
                after: baseline,
                route: "image",
                locked: underLock,
            ) == nil)
            #expect(observed(underLock: underLock, wrongWriter: true).finishedOperation(
                after: baseline,
                route: "image",
                locked: underLock,
            ) == nil)
        }
        #expect(observed(underLock: true, missingLock: true).finishedOperation(
            after: baseline,
            route: "image",
            locked: true,
        ) == nil)
    }

    @Test
    func lockedStagingRequiresExactBytesCountAndOperation() {
        let expected = UUID()
        func matches(_ operation: UUID?, _ verified: Bool, _ same: Bool?, _ count: Int, _ bytes: Int64) -> Bool {
            BrowserDownloadLibraryObservation.matchesStagedFixture(
                operation: operation,
                verified: verified,
                matchesOperation: same,
                count: count,
                bytes: bytes,
                expectedBytes: 151,
            )
        }
        #expect(matches(expected, true, true, 1, 151))
        #expect(!matches(nil, true, true, 1, 151))
        #expect(!matches(expected, false, true, 1, 151))
        #expect(!matches(expected, true, false, 1, 151))
        #expect(!matches(expected, true, nil, 1, 151))
        #expect(!matches(expected, true, true, 2, 151))
        #expect(!matches(expected, true, true, 1, 150))
        #expect(!matches(expected, true, true, 0, 0))
    }
}

extension AppHostedUITests.BrowserDownloadObservationReceiptTests {
    @Test
    func physicalLibraryExportMatchesAXAndIsCompleteBeforeReturn() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let recorder = BrowserDownloadProductionEvidence(preservesTransferMilestones: false, url: url)
        let run = recorder.runID
        let process = UUID()
        let locked = BrowserDownloadObservationContext(
            processNonce: process,
            runID: run,
            authorizationGeneration: 2,
            resourceGeneration: 3,
            ingestionGeneration: 4,
            phase: "locked",
            phaseRevision: 1,
        )
        let authenticated = BrowserDownloadObservationContext(
            processNonce: process,
            runID: run,
            authorizationGeneration: 3,
            resourceGeneration: 4,
            ingestionGeneration: 5,
            phase: "authenticated",
            phaseRevision: 2,
        )
        let identity = [
            "libraryID": UUID().uuidString,
            "databaseID": String(repeating: "a", count: 64),
            "processID": String(ProcessInfo.processInfo.processIdentifier),
            "runID": run,
        ]
        let operation = UUID().uuidString
        let startup = identity.merging([
            "event": "libraryStartup",
            "authenticated": "false",
            "singleStagedFixture": "false",
            "stagingEmpty": "true",
            "contentEmpty": "true",
        ]) { _, next in next }
        let accepted = startup.merging([
            "event": "acceptedLibraryStorage",
            "singleStagedFixture": "true",
            "stagingEmpty": "false",
            "operation": operation,
        ]) { _, next in next }
        let canonical = identity.merging([
            "event": "canonicalLibrarySnapshot",
            "authenticated": "true",
            "canonicalIDs": UUID().uuidString,
            "assetCount": "1",
            "resourceCount": "1",
            "rowCount": "1",
            "rowIDs": operation,
            "importedRows": "1",
            "duplicateRows": "0",
            "temporaryCount": "0",
            "temporaryBytes": "0",
            "originalBytesMatch": "true",
            "originalHashMatches": "true",
            "settled": "true",
        ]) { _, next in next }
        func ax(authenticated: Bool) throws -> [[String: String]] {
            try JSONDecoder().decode(
                [[String: String]].self,
                from: Data(recorder.observationsJSON(authenticated: authenticated).utf8),
            )
        }
        let records = [startup, accepted, canonical]
        for (index, fields) in records.enumerated() {
            let context = index < 2 ? locked : authenticated
            let sample = BrowserDownloadLibraryObservation(context: context, outcome: .complete, fields: fields)
            recorder.recordLibrary(sample, current: context, physicalCompatibility: true)
            recorder.recordLibrary(sample, current: context, physicalCompatibility: true)

            // Reopen the export before recording the next milestone, just as an operator can after termination.
            let bytes = try Data(contentsOf: url)
            #expect(bytes.last == 0x0a)
            let disk = try bytes.split(separator: 0x0a).map { try JSONDecoder().decode(
                [String: String].self,
                from: Data($0),
            ) }
            let visible = try ax(authenticated: index == 2)
            #expect(disk == visible)
            #expect(disk.count == index + 1)
            for (row, expected) in zip(disk, records) {
                #expect(row.filter { $0.key != "wallTime" && $0.key != "monotonicSeconds" } == expected)
                #expect(row["monotonicSeconds"].flatMap(Double.init)?.isFinite == true)
                #expect(row["wallTime"]?.isEmpty == false)
            }
        }

        let exported = try Data(contentsOf: url)
        #expect(try ax(authenticated: false).compactMap { $0["event"] } == ["libraryStartup", "acceptedLibraryStorage"])
        #expect(try ax(authenticated: true).compactMap { $0["event"] } == records.compactMap { $0["event"] })
        #expect(recorder.observationEvents.isEmpty)
        #expect(try Data(contentsOf: url) == exported)
        Attachment.record(String(decoding: exported, as: UTF8.self), named: "operator-library-milestones.jsonl")
    }

    @Test
    func libraryExportRejectsPassiveStaleFailedAndUnredactedSamples() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let recorder = BrowserDownloadProductionEvidence(preservesTransferMilestones: false, url: url)
        let context = BrowserDownloadObservationContext(
            processNonce: UUID(),
            runID: recorder.runID,
            authorizationGeneration: 2,
            resourceGeneration: 3,
            ingestionGeneration: 4,
            phase: "locked",
            phaseRevision: 1,
        )
        let fields = [
            "event": "libraryStartup",
            "libraryID": UUID().uuidString,
            "databaseID": String(repeating: "a", count: 64),
            "processID": String(ProcessInfo.processInfo.processIdentifier),
            "runID": recorder.runID,
            "authenticated": "false",
            "singleStagedFixture": "false",
            "stagingEmpty": "true",
            "contentEmpty": "true",
        ]
        let valid = BrowserDownloadLibraryObservation(context: context, outcome: .complete, fields: fields)
        recorder.recordLibrary(valid, current: context, physicalCompatibility: false)
        var newer = context
        newer.phaseRevision += 1
        recorder.recordLibrary(valid, current: newer, physicalCompatibility: true)
        for state in [BrowserDownloadLibraryObservation.Outcome.unavailable, .invalidated, .failed] {
            recorder.recordLibrary(
                .init(context: context, outcome: state, fields: [:]),
                current: context,
                physicalCompatibility: true,
            )
        }
        for extra in [["temporaryBytes": "151"], ["canonicalIDs": UUID().uuidString], ["processID": "-1"]] {
            recorder.recordLibrary(
                .init(context: context, outcome: .complete, fields: fields.merging(extra) { _, next in next }),
                current: context,
                physicalCompatibility: true,
            )
        }
        #expect(recorder.observationsJSON(authenticated: true) == "[]")
        #expect(!FileManager.default.fileExists(atPath: url.path))

        let unavailable = BrowserDownloadProductionEvidence(
            preservesTransferMilestones: false,
            url: url.appendingPathComponent("unavailable.jsonl"),
        )
        let otherContext = BrowserDownloadObservationContext(
            processNonce: context.processNonce,
            runID: unavailable.runID,
            authorizationGeneration: 2,
            resourceGeneration: 3,
            ingestionGeneration: 4,
            phase: "locked",
            phaseRevision: 1,
        )
        let undeliverable = BrowserDownloadLibraryObservation(
            context: otherContext,
            outcome: .complete,
            fields: fields
                .merging(["runID": unavailable.runID]) { _, next in
                    next
                },
        )
        unavailable.recordLibrary(undeliverable, current: otherContext, physicalCompatibility: true)
        #expect(unavailable.observationsJSON(authenticated: false) == "[]")
    }
}
