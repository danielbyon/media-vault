//
//  BrowserDownloadTransferWitnessTests.swift
//  MediaVault
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import XCTest

final class BrowserDownloadTransferWitnessTests: XCTestCase {
    private typealias Observation = [String: String]

    func testDelayedHandoffParserRequiresNativeCallbacksAfterLock() throws {
        let events = delayedHandoffEvents()
        XCTAssertNotNil(SlowKnownWitnessContract.delayedHandoffEvidence(events))
        XCTAssertNotNil(SlowKnownWitnessContract.delayedHandoffEvidence(lockedFixtureEvents(events)))
        for name in [
            "nativeDownloadHandoff",
            "transferAdmitted",
            "writerFinished",
            "nativePostLockProgress",
            "hiddenCompletion",
        ] {
            let missing = events.filter { $0["event"] != name }
            XCTAssertNil(SlowKnownWitnessContract.delayedHandoffEvidence(missing), name)
            XCTAssertNil(SlowKnownWitnessContract.delayedHandoffEvidence(lockedFixtureEvents(missing)), name)
        }
        for (event, field, value) in [
            ("nativeDownloadHandoff", "monotonicSeconds", "1.1"),
            ("transferAdmitted", "operation", "55555555-5555-4555-8555-555555555555"),
            ("writerFinished", "capability", "55555555-5555-4555-8555-555555555555"),
            ("nativePostLockProgress", "receivedBytes", "0"),
            ("nativePostLockProgress", "receivedBytes", "not-a-count"),
            ("hiddenCompletion", "activeWriterCount", "1"),
            ("hiddenCompletion", "retainedRecordCount", "0"),
            ("hiddenCompletion", "contentEmpty", "false"),
            ("hiddenCompletion", "authenticated", "true"),
        ] {
            var invalid = events
            let index = try XCTUnwrap(invalid.firstIndex { $0["event"] == event })
            invalid[index][field] = value
            XCTAssertNil(SlowKnownWitnessContract.delayedHandoffEvidence(invalid), "\(event).\(field)")
            XCTAssertNil(
                SlowKnownWitnessContract.delayedHandoffEvidence(lockedFixtureEvents(invalid)),
                "redacted \(event).\(field)",
            )
        }
        var mixed = lockedFixtureEvents(events)
        let progressIndex = try XCTUnwrap(mixed.firstIndex { $0["event"] == "nativePostLockProgress" })
        mixed[progressIndex]["receivedBytes"] = "0"
        XCTAssertNil(
            SlowKnownWitnessContract.delayedHandoffEvidence(mixed),
            "A raw numeric field forbids a proof-only fallback",
        )
    }

    private func delayedHandoffEvents() -> [Observation] {
        let request = "22222222-2222-4222-8222-222222222222"
        let common: Observation = [
            "operation": "33333333-3333-4333-8333-333333333333",
            "connectionID": "44444444-4444-4444-8444-444444444444",
            "capability": "77777777-7777-4777-8777-777777777777",
        ]
        let rows: [(String, String, Observation)] = [
            ("fixtureNavigationRequested", "1.0", ["fixtureRoute": "delayed-handoff"]),
            ("policyDownloadAdmitted", "1.1", [:]),
            ("pendingPolicyLockApplied", "1.2", [
                "generationBefore": "4",
                "generation": "5",
                "authenticated": "false",
                "available": "false",
                "contentEmpty": "true",
            ]),
            (
                "nativeDownloadHandoff",
                "1.3",
                ["fixtureRoute": "delayed-handoff", "sameOrigin": "true", "fixtureOrigin": "true"],
            ),
            ("transferAdmitted", "1.4", [:]),
            ("nativePostLockProgress", "1.45", [
                "receivedBytes": "608",
                "expectedBytes": "608",
                "callbackMonotonicSeconds": "1.44",
                "authenticated": "false",
                "available": "false",
            ]),
            ("writerFinished", "1.5", [:]),
            ("hiddenCompletion", "1.6", [
                "authenticated": "false",
                "available": "false",
                "contentEmpty": "true",
                "activeWriterCount": "0",
                "retainedRecordCount": "1",
            ]),
        ]
        return rows.map { name, time, fields in
            qualificationEvent(name, time: time, fields: common.merging(fields) { _, new in new }, requestID: request)
        }
    }

    func testSlowKnownWitnessAcceptsCorrelatedNativeProgress() {
        XCTAssertNotNil(SlowKnownWitnessContract.witness(from: slowKnownEvents()))
    }

    func testSlowKnownWitnessRejectsMissingHandoffOrProgress() {
        let events = slowKnownEvents()
        XCTAssertNil(SlowKnownWitnessContract.witness(from: events.filter { $0["event"] != "nativeDownloadHandoff" }))
        XCTAssertNil(SlowKnownWitnessContract.witness(from: events.filter { $0["event"] != "slowKnownProgress" }))
        XCTAssertNil(SlowKnownWitnessContract.witness(from: events.filter { $0["event"] != "transferAdmitted" }))
        var pendingOnly = events
        pendingOnly[3]["receivedBytes"] = "0"
        pendingOnly[4]["receivedBytes"] = "0"
        XCTAssertNil(SlowKnownWitnessContract.witness(from: pendingOnly))
    }

    func testSlowKnownWitnessRejectsStaleRunOrUnrelatedOperation() {
        var staleRun = slowKnownEvents()
        staleRun[3]["runID"] = UUID().uuidString
        XCTAssertNil(SlowKnownWitnessContract.witness(from: staleRun))

        var unrelatedOperation = slowKnownEvents()
        unrelatedOperation[3]["operation"] = UUID().uuidString
        XCTAssertNil(SlowKnownWitnessContract.witness(from: unrelatedOperation))
    }

    func testSlowKnownWitnessRejectsServerEvidenceAfterReadiness() {
        var events = slowKnownEvents()
        events[1]["monotonicSeconds"] = "1.6"
        XCTAssertNil(SlowKnownWitnessContract.witness(from: events))
    }

    func testSlowKnownWitnessRejectsEarlyTerminalAndCleanupFailure() throws {
        var terminal = slowKnownEvents()
        let terminalRequestID = try XCTUnwrap(terminal[0]["fixtureRequest"])
        let terminalEvent = qualificationEvent(
            "writerFinished",
            time: "1.45",
            fields: ["operation": "33333333-3333-4333-8333-333333333333"],
            requestID: terminalRequestID,
        )
        terminal.insert(terminalEvent, at: 4)
        XCTAssertNil(SlowKnownWitnessContract.witness(from: terminal))

        var cleanup = slowKnownEvents()
        let failedOperationID = try XCTUnwrap(cleanup[3]["operation"])
        let cleanupRequestID = cleanup[0]["fixtureRequest"]
        let cleanupEvent = qualificationEvent(
            "cleanupInjectedFailure",
            time: "1.45",
            fields: ["operation": failedOperationID],
            requestID: cleanupRequestID,
        )
        cleanup.append(cleanupEvent)
        XCTAssertNil(SlowKnownWitnessContract.witness(from: cleanup))
    }

    func testSlowKnownWitnessRejectsPrematureCleanupWithoutFixtureRequest() throws {
        var events = slowKnownEvents()
        let runID = try XCTUnwrap(events[0]["runID"])
        let operationID = try XCTUnwrap(events[3]["operation"])
        events.append(qualificationEvent(
            "cleanupRemoval",
            time: "1.45",
            fields: ["operation": operationID, "absence": "true"],
            runID: runID,
        ))

        XCTAssertNil(SlowKnownWitnessContract.witness(from: events))
    }

    func testSlowKnownWitnessIgnoresPrematureCleanupForAnotherOperation() throws {
        var events = slowKnownEvents()
        let runID = try XCTUnwrap(events[0]["runID"])
        events.append(qualificationEvent(
            "cleanupRemoval",
            time: "1.45",
            fields: ["operation": "55555555-5555-4555-8555-555555555555", "absence": "true"],
            runID: runID,
        ))

        XCTAssertNotNil(SlowKnownWitnessContract.witness(from: events))
    }

    func testSlowKnownWitnessIgnoresPrematureCleanupFromAnotherRun() {
        var events = slowKnownEvents()
        events.append(qualificationEvent(
            "cleanupRemoval",
            time: "1.45",
            fields: [
                "operation": "33333333-3333-4333-8333-333333333333",
                "absence": "true",
            ],
            runID: "66666666-6666-4666-8666-666666666666",
        ))

        XCTAssertNotNil(SlowKnownWitnessContract.witness(from: events))
    }

    private func lockedFixtureEvents(_ events: [Observation]) -> [Observation] {
        BrowserDownloadObservationSnapshot(events: events)
            .addingFixtureProofs()
            .projected(for: .init(
                processNonce: UUID(),
                runID: "11111111-1111-4111-8111-111111111111",
                authorizationGeneration: 5,
                resourceGeneration: 0,
                ingestionGeneration: 0,
                phase: "locked",
            ))
            .events
    }

    func testContinuationAcceptsFiniteResponseAndNativeFinish() throws {
        let events = continuationEvents()
        let witness = try XCTUnwrap(SlowKnownWitnessContract.witness(from: events))
        XCTAssertNotNil(SlowKnownWitnessContract.continuationEvidence(from: events, for: witness))
        XCTAssertNotNil(SlowKnownWitnessContract.continuationEvidence(from: lockedFixtureEvents(events), for: witness))
        // UIKit may revoke content before SwiftUI delivers the later background action.
        var alreadyRevoked = events
        let backgroundIndex = try XCTUnwrap(alreadyRevoked
            .firstIndex { $0["event"] == "qualificationScenePhaseChanged" })
        let initial = try XCTUnwrap(UInt64(witness.generation))
        alreadyRevoked[backgroundIndex]["generationBefore"] = String(initial + 1)
        alreadyRevoked[backgroundIndex]["generation"] = String(initial + 2)
        XCTAssertNotNil(SlowKnownWitnessContract.continuationEvidence(from: alreadyRevoked, for: witness))
        XCTAssertNotNil(SlowKnownWitnessContract.continuationEvidence(
            from: lockedFixtureEvents(alreadyRevoked),
            for: witness,
        ))
        alreadyRevoked[backgroundIndex]["generation"] = String(initial + 1)
        XCTAssertNil(SlowKnownWitnessContract.continuationEvidence(from: alreadyRevoked, for: witness))
        XCTAssertNil(SlowKnownWitnessContract.continuationEvidence(
            from: lockedFixtureEvents(alreadyRevoked),
            for: witness,
        ))
        alreadyRevoked[backgroundIndex]["generationBefore"] = String(initial - 1)
        alreadyRevoked[backgroundIndex]["generation"] = String(initial)
        XCTAssertNil(SlowKnownWitnessContract.continuationEvidence(from: alreadyRevoked, for: witness))
        XCTAssertNil(SlowKnownWitnessContract.continuationEvidence(
            from: lockedFixtureEvents(alreadyRevoked),
            for: witness,
        ))
    }

    func testContinuationRejectsMissingNativeOrTransportWitness() {
        for name in [
            "policyDownloadAdmitted",
            "transferAdmitted",
            "writerFinished",
            "nativePostLockProgress",
            "finiteResponseCompleted",
            "hiddenCompletion",
        ] {
            let events = continuationEvents().filter { $0["event"] != name }
            if let witness = SlowKnownWitnessContract.witness(from: events) {
                XCTAssertNil(SlowKnownWitnessContract.continuationEvidence(from: events, for: witness), name)
                XCTAssertNil(SlowKnownWitnessContract.continuationEvidence(
                    from: lockedFixtureEvents(events),
                    for: witness,
                ), name)
            } else {
                XCTAssertTrue(["policyDownloadAdmitted", "transferAdmitted"].contains(name))
            }
        }
    }

    func testContinuationRejectsCancellationFailureAndPrematureCleanup() throws {
        for name in [
            "nativeCancellationRequested",
            "writerCancellationAcknowledged",
            "writerFailed",
            "cleanupRemoval",
        ] {
            var events = continuationEvents()
            events.append(qualificationEvent(name, time: "2.4", fields: [
                "operation": "33333333-3333-4333-8333-333333333333",
            ]))
            let witness = try XCTUnwrap(SlowKnownWitnessContract.witness(from: events))
            XCTAssertNil(SlowKnownWitnessContract.continuationEvidence(from: events, for: witness), name)
            XCTAssertNil(SlowKnownWitnessContract.continuationEvidence(
                from: lockedFixtureEvents(events),
                for: witness,
            ), name)
        }
    }

    func testContinuationRejectsWrongCorrelationEarlyReleaseAndVisibleCompletion() throws {
        let mutations: [(String, String, String)] = [
            ("writerFinished", "operation", "55555555-5555-4555-8555-555555555555"),
            ("writerFinished", "runID", "55555555-5555-4555-8555-555555555555"),
            ("writerFinished", "fixtureRequest", "55555555-5555-4555-8555-555555555555"),
            ("writerFinished", "capability", "55555555-5555-4555-8555-555555555555"),
            ("finiteResponseCompleted", "connectionID", "55555555-5555-4555-8555-555555555555"),
            ("finiteResponseCompleted", "remainderBytes", "1"),
            ("finiteResponseCompleted", "prefixBytes", "-1"),
            ("finiteResponseCompleted", "expectedBytes", "16777217"),
            ("finiteResponseReleaseRequested", "monotonicSeconds", "1.9"),
            ("finiteResponseCompleted", "releaseMonotonicSeconds", "1.9"),
            ("writerFinished", "monotonicSeconds", "nan"),
            ("nativePostLockProgress", "receivedBytes", "262144"),
            ("nativePostLockProgress", "receivedBytes", "16777217"),
            ("nativePostLockProgress", "expectedBytes", "1"),
            ("nativePostLockProgress", "receivedBytes", "not-a-count"),
            ("nativePostLockProgress", "callbackMonotonicSeconds", "1.9"),
            ("hiddenCompletion", "contentEmpty", "false"),
            ("hiddenCompletion", "available", "true"),
            ("hiddenCompletion", "authenticated", "true"),
            ("hiddenCompletion", "retainedRecordCount", "0"),
            ("hiddenCompletion", "activeWriterCount", "1"),
            ("qualificationScenePhaseChanged", "activeWriterCount", "0"),
            ("qualificationScenePhaseChanged", "retainedRecordCount", "0"),
        ]
        for (name, key, value) in mutations {
            var events = continuationEvents()
            let index = try XCTUnwrap(events.firstIndex { $0["event"] == name })
            events[index][key] = value
            let witness = try XCTUnwrap(SlowKnownWitnessContract.witness(from: events))
            XCTAssertNil(SlowKnownWitnessContract.continuationEvidence(from: events, for: witness), "\(name).\(key)")
            XCTAssertNil(SlowKnownWitnessContract.continuationEvidence(
                from: lockedFixtureEvents(events),
                for: witness,
            ), "redacted \(name).\(key)")
        }
        let events = continuationEvents()
        let witness = try XCTUnwrap(SlowKnownWitnessContract.witness(from: events))
        var mixed = lockedFixtureEvents(events)
        let progressIndex = try XCTUnwrap(mixed.firstIndex { $0["event"] == "nativePostLockProgress" })
        mixed[progressIndex]["receivedBytes"] = "0"
        XCTAssertNil(SlowKnownWitnessContract.continuationEvidence(from: mixed, for: witness))
        for name in ["slowKnownReadiness", "finiteResponseCompleted"] {
            var duplicate = events
            try duplicate.append(XCTUnwrap(events.first { $0["event"] == name }))
            XCTAssertNil(SlowKnownWitnessContract.continuationEvidence(from: duplicate, for: witness))
            XCTAssertNil(SlowKnownWitnessContract.continuationEvidence(
                from: lockedFixtureEvents(duplicate),
                for: witness,
            ))
        }
    }

    private func slowKnownEvents() -> [Observation] {
        let runID = "11111111-1111-4111-8111-111111111111"
        let requestID = "22222222-2222-4222-8222-222222222222"
        let operationID = "33333333-3333-4333-8333-333333333333"
        let connectionID = "44444444-4444-4444-8444-444444444444"
        let expectedBytes = "16777216"
        let prefixBytes = "262144"

        return [
            qualificationEvent("fixtureNavigationRequested", time: "1.0", fields: [
                "fixtureRoute": "slow-known",
            ], requestID: requestID, runID: runID),
            qualificationEvent("slowKnownServerPrefixProcessed", time: "1.2", fields: [
                "route": "slow-known",
                "requestParsed": "true",
                "requestCount": "1",
                "connectionCount": "1",
                "connectionID": connectionID,
                "expectedBytes": expectedBytes,
                "prefixBytes": prefixBytes,
                "sendStackState": "stackPrefixProcessed",
                "responseComplete": "false",
                "connectionClosed": "false",
            ], requestID: requestID, runID: runID),
            qualificationEvent("nativeDownloadHandoff", time: "1.3", fields: [
                "fixtureRoute": "slow-known",
                "fixtureOrigin": "true",
                "sameOrigin": "true",
            ], requestID: requestID, runID: runID),
            qualificationEvent("slowKnownProgress", time: "1.4", fields: [
                "operation": operationID,
                "generation": "4",
                "operationGeneration": "4",
                "expectedBytes": expectedBytes,
                "receivedBytes": prefixBytes,
                "activeWriterCount": "1",
                "recordCount": "1",
                "available": "true",
                "authorizationValid": "true",
                "isReady": "false",
                "presentation": "none",
                "privacyCleanupPending": "false",
            ], requestID: requestID, runID: runID),
            qualificationEvent("slowKnownReadiness", time: "1.5", fields: [
                "operation": operationID,
                "operationGeneration": "4",
                "initialGeneration": "4",
                "generation": "4",
                "expectedBytes": expectedBytes,
                "serverExpectedBytes": expectedBytes,
                "receivedBytes": prefixBytes,
                "activeWriterCount": "1",
                "recordCount": "1",
                "available": "true",
                "authorizationValid": "true",
                "isReady": "false",
                "presentation": "none",
                "privacyCleanupPending": "false",
                "connectionID": connectionID,
                "responseComplete": "false",
                "connectionClosed": "false",
                "elapsedMilliseconds": "500",
            ], requestID: requestID, runID: runID),
            qualificationEvent("policyDownloadAdmitted", time: "1.21", fields: [
                "operation": operationID,
                "capability": "77777777-7777-4777-8777-777777777777",
                "connectionID": connectionID,
            ], requestID: requestID, runID: runID),
            qualificationEvent("transferAdmitted", time: "1.35", fields: [
                "operation": operationID,
                "capability": "77777777-7777-4777-8777-777777777777",
                "connectionID": connectionID,
            ], requestID: requestID, runID: runID),
        ]
    }

    private func qualificationEvent(
        _ name: String,
        time: String,
        fields: Observation = [:],
        requestID: String? = nil,
        runID: String = "11111111-1111-4111-8111-111111111111",
    ) -> Observation {
        var event = fields
        event["event"] = name
        event["runID"] = runID
        event["monotonicSeconds"] = time
        if let requestID {
            event["fixtureRequest"] = requestID
        }
        return event
    }

    private func continuationEvents() -> [Observation] {
        let request = "22222222-2222-4222-8222-222222222222"
        let operation = "33333333-3333-4333-8333-333333333333"
        let connection = "44444444-4444-4444-8444-444444444444"
        let capability = "77777777-7777-4777-8777-777777777777"
        var events = slowKnownEvents().map { event in
            var event = event
            if event["fixtureRoute"] == "slow-known" {
                event["fixtureRoute"] = "finite-continuation"
            }
            if event["route"] == "slow-known" {
                event["route"] = "finite-continuation"
            }
            return event
        }
        func append(_ name: String, _ time: String, _ extra: Observation = [:]) {
            var fields = extra
            fields["operation"] = operation
            fields["connectionID"] = connection
            fields["capability"] = capability
            events.append(qualificationEvent(name, time: time, fields: fields, requestID: request))
        }
        append("qualificationScenePhaseChanged", "2.0", [
            "phase": "background",
            "generationBefore": "4",
            "generation": "5",
            "authorizationRevokedSynchronously": "true",
            "contentEmpty": "true",
            "available": "false",
            "authenticated": "false",
            "activeWriterCount": "1",
            "retainedRecordCount": "1",
        ])
        append("finiteResponseReleaseRequested", "2.1")
        append("finiteResponseCompleted", "2.2", [
            "sendStackState": "stackProcessed",
            "expectedBytes": "16777216",
            "prefixBytes": "262144",
            "remainderBytes": "16515072",
            "releaseMonotonicSeconds": "2.11",
        ])
        append("nativePostLockProgress", "2.25", [
            "receivedBytes": "16777216",
            "expectedBytes": "16777216",
            "callbackMonotonicSeconds": "2.24",
            "authenticated": "false",
            "available": "false",
        ])
        append("writerFinished", "2.3")
        append("hiddenCompletion", "2.4", [
            "contentEmpty": "true",
            "available": "false",
            "authenticated": "false",
            "activeWriterCount": "0",
            "retainedRecordCount": "1",
        ])
        return events
    }

    func testSlowKnownWitnessDiagnosticsAreRedactedAndBounded() throws {
        let events = slowKnownEvents()
        let witness = try XCTUnwrap(SlowKnownWitnessContract.witness(from: events))
        XCTAssertEqual(Set(witness.diagnosticFields.keys), [
            "runID",
            "fixtureRequest",
            "operation",
            "connectionID",
            "generation",
            "elapsedMilliseconds",
        ])
        let diagnostic = String(describing: witness.diagnosticFields).lowercased()
        XCTAssertFalse(diagnostic.contains("http://"))
        XCTAssertFalse(diagnostic.contains("/private/"))
        XCTAssertFalse(diagnostic.contains("filename"))
        XCTAssertFalse(diagnostic.contains("content"))

        XCTAssertNil(SlowKnownWitnessContract.witness(from: events + Array(repeating: events[0], count: 256)))
    }
}
