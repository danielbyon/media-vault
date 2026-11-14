//
//  BrowserDownloadQualificationUITests.swift
//  MediaVault
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import CoreGraphics
import Foundation
import XCTest
import XCUIAutomation

/// Single-scene, externally driven production-path qualification. Simulator readback is explicitly
/// simulated; these tests do not qualify native file protection, an AirDrop receiver, task-switcher
/// pixels, simultaneous application scenes, or system window resizing.
@MainActor
final class BrowserDownloadQualificationUITests: XCTestCase {
    private typealias Observation = [String: String]
    private enum FixtureError: Error { case missingObservation, waitFailed }

    /// Keeps only opaque identities and elapsed time from a live partial-transfer checkpoint.
    private struct SlowKnownWitness {
        let runID: String
        let requestID: String
        let operationID: String
        let connectionID: String
        let generation: String
        let elapsedMilliseconds: Int

        var diagnosticFields: Observation {
            [
                "runID": runID,
                "fixtureRequest": requestID,
                "operation": operationID,
                "connectionID": connectionID,
                "generation": generation,
                "elapsedMilliseconds": String(elapsedMilliseconds),
            ]
        }
    }

    private enum SlowKnownWitnessContract {
        static func witness(from events: [Observation]) -> SlowKnownWitness? {
            guard events.count <= 256 else {
                return nil
            }

            let navigations = events.filter {
                $0["event"] == "fixtureNavigationRequested" && $0["fixtureRoute"] == "slow-known"
            }
            guard navigations.count == 1, let navigation = navigations.first,
                  let runID = navigation["runID"], let requestID = navigation["fixtureRequest"]
            else {
                return nil
            }

            let runEvents = events.filter { $0["runID"] == runID }

            let serverEvents = runEvents.filter {
                $0["event"] == "slowKnownServerPrefixProcessed" && $0["fixtureRequest"] == requestID
            }
            let handoffs = runEvents.filter {
                $0["event"] == "nativeDownloadHandoff" && $0["fixtureRequest"] == requestID
            }
            let progressEvents = runEvents.filter {
                $0["event"] == "slowKnownProgress" && $0["fixtureRequest"] == requestID
            }
            let readinessEvents = runEvents.filter {
                $0["event"] == "slowKnownReadiness" && $0["fixtureRequest"] == requestID
            }
            guard serverEvents.count == 1, handoffs.count == 1,
                  progressEvents.count == 1, readinessEvents.count == 1,
                  let server = serverEvents.first, let handoff = handoffs.first,
                  let progress = progressEvents.first, let readiness = readinessEvents.first,
                  let operationID = progress["operation"],
                  let generation = readiness["generation"],
                  let connectionID = server["connectionID"],
                  let expected = Int(server["expectedBytes"] ?? ""),
                  let prefix = Int(server["prefixBytes"] ?? ""),
                  let received = Int(progress["receivedBytes"] ?? ""),
                  let elapsed = Int(readiness["elapsedMilliseconds"] ?? "")
            else {
                return nil
            }

            let times = [navigation, server, handoff, progress, readiness]
                .compactMap { $0["monotonicSeconds"].flatMap(Double.init) }
            let failed = runEvents.contains {
                $0["event"] == "slowKnownReadinessFailure"
                    && $0["fixtureRequest"] == requestID
            }
            let earlyTerminalOrCleanup = runEvents.contains { event in
                guard event["runID"] == runID,
                      let eventTime = event["monotonicSeconds"].flatMap(Double.init),
                      let readyTime = readiness["monotonicSeconds"].flatMap(Double.init)
                else {
                    return false
                }

                if event["event"] == "slowKnownWriterTerminalAcknowledged" {
                    return event["fixtureRequest"] == requestID && eventTime <= readyTime
                }
                return event["event"] == "cleanupRemoval"
                    && event["operation"] == operationID && eventTime <= readyTime
            }
            let cleanupFailed = runEvents.contains {
                ($0["event"] == "scratchFailure" || $0["event"] == "cleanupInjectedFailure")
                    && $0["operation"] == operationID
            }

            guard server["runID"] == runID, handoff["runID"] == runID,
                  progress["runID"] == runID, readiness["runID"] == runID,
                  UUID(uuidString: requestID) != nil,
                  UUID(uuidString: operationID) != nil,
                  UUID(uuidString: connectionID) != nil,
                  server["route"] == "slow-known", server["requestParsed"] == "true",
                  server["requestCount"] == "1", server["connectionCount"] == "1",
                  server["sendStackState"] == "stackPrefixProcessed",
                  server["responseComplete"] == "false", server["connectionClosed"] == "false",
                  prefix > 0, prefix < expected,
                  handoff["fixtureRoute"] == "slow-known", handoff["fixtureOrigin"] == "true",
                  handoff["sameOrigin"] == "true",
                  readiness["connectionID"] == connectionID,
                  progress["expectedBytes"] == String(expected),
                  readiness["serverExpectedBytes"] == String(expected),
                  readiness["expectedBytes"] == String(expected),
                  received > 0, received < expected,
                  progress["receivedBytes"] == readiness["receivedBytes"],
                  progress["operationGeneration"] == generation,
                  progress["generation"] == generation,
                  readiness["operationGeneration"] == generation,
                  readiness["initialGeneration"] == generation,
                  progress["activeWriterCount"] == "1", progress["recordCount"] == "1",
                  readiness["activeWriterCount"] == "1", readiness["recordCount"] == "1",
                  progress["authorizationValid"] == "true", readiness["authorizationValid"] == "true",
                  progress["available"] == "true", readiness["available"] == "true",
                  progress["isReady"] == "false", readiness["isReady"] == "false",
                  progress["presentation"] == "none", readiness["presentation"] == "none",
                  progress["privacyCleanupPending"] == "false",
                  readiness["privacyCleanupPending"] == "false",
                  readiness["responseComplete"] == "false", readiness["connectionClosed"] == "false",
                  readiness["operation"] == operationID,
                  times.count == 5, times[0] < times[1], times[0] < times[2], times[1] < times[4],
                  times[2] < times[3], times[3] < times[4],
                  elapsed > 0, elapsed <= 10_000,
                  !failed, !earlyTerminalOrCleanup, !cleanupFailed
            else {
                return nil
            }

            return SlowKnownWitness(
                runID: runID,
                requestID: requestID,
                operationID: operationID,
                connectionID: connectionID,
                generation: generation,
                elapsedMilliseconds: elapsed,
            )
        }

        static func cancellationEvidence(
            from events: [Observation],
            for witness: SlowKnownWitness,
        ) -> Observation? {
            let runEvents = events.filter { $0["runID"] == witness.runID }
            let backgroundEvents = runEvents.filter {
                $0["event"] == "qualificationScenePhaseChanged"
                    && $0["fixtureRequest"] == witness.requestID
                    && $0["operation"] == witness.operationID
                    && $0["phase"] == "background"
            }
            let closeEvents = runEvents.filter {
                $0["event"] == "slowKnownConnectionClosed"
                    && $0["fixtureRequest"] == witness.requestID
                    && $0["operation"] == witness.operationID
                    && $0["connectionID"] == witness.connectionID
            }
            let writerEvents = runEvents.filter {
                $0["event"] == "slowKnownWriterTerminalAcknowledged"
                    && $0["fixtureRequest"] == witness.requestID
                    && $0["operation"] == witness.operationID
                    && $0["connectionID"] == witness.connectionID
            }
            let cleanupEvents = runEvents.filter {
                $0["event"] == "cleanupRemoval" && $0["operation"] == witness.operationID
            }

            guard backgroundEvents.count == 1, let background = backgroundEvents.first,
                  closeEvents.count == 1, let close = closeEvents.first,
                  writerEvents.count == 1, let writer = writerEvents.first,
                  cleanupEvents.count == 1, let cleanup = cleanupEvents.first,
                  let backgroundTime = background["monotonicSeconds"].flatMap(Double.init),
                  let closeTime = close["connectionClosedMonotonicSeconds"].flatMap(Double.init),
                  let closeEventTime = close["monotonicSeconds"].flatMap(Double.init),
                  let cleanupTime = cleanup["monotonicSeconds"].flatMap(Double.init),
                  let writerTime = writer["monotonicSeconds"].flatMap(Double.init),
                  let generationBefore = UInt64(background["generationBefore"] ?? ""),
                  let generationAfter = UInt64(background["generation"] ?? ""),
                  let deadlineElapsed = Int(close["deadlineElapsedMilliseconds"] ?? "")
            else {
                return nil
            }

            let acceptedCloseReasons: Set = [
                "peerClosedDuringResponse",
                "peerReceiveFailedDuringResponse",
            ]
            guard background["authorizationRevokedSynchronously"] == "true",
                  background["generationBefore"] == witness.generation,
                  generationAfter > generationBefore,
                  close["connectionClosed"] == "true",
                  close["responseComplete"] == "false",
                  acceptedCloseReasons.contains(close["closeReason"] ?? ""),
                  deadlineElapsed >= 0, deadlineElapsed < 15_000,
                  backgroundTime < closeTime, closeTime <= closeEventTime,
                  backgroundTime < cleanupTime, cleanup["absence"] == "true",
                  backgroundTime < writerTime,
                  writer["activeWriterCount"] == "0",
                  writer["retainedRecordCount"] == "0",
                  writer["cleanupPending"] == "false"
            else {
                return nil
            }

            return close
        }
    }

    func testQuickLookHomeRevokesAndFreshDownloadRecovers() throws {
        try qualifyHomeInterruption(action: "Preview")
    }

    func testShareHomeRevokesAndFreshDownloadRecovers() throws {
        try qualifyHomeInterruption(action: "Share")
    }

    func testNormalQualificationModeReturnsToAuthenticatedBrowserAfterHome() throws {
        let normalApp = try launchFixture()
        defer {
            if normalApp.state != .notRunning {
                normalApp.terminate()
            }
        }

        XCUIDevice.shared.press(.home)
        try wait(normalApp, milestone: "normal qualification host backgrounded") {
            normalApp.state == .runningBackground
        }
        normalApp.activate()
        try wait(normalApp, milestone: "normal qualification Root returned without locking") {
            normalApp.state == .runningForeground && normalApp.buttons["Browser Menu"].isHittable
        }
        XCTAssertFalse(normalApp.secureTextFields["PIN"].exists)
        normalApp.terminate()
    }

    func testActiveDownloadQualificationModeAutoLocksAfterRealHomeTransition() throws {
        let activeApp = try launchFixture(activeDownloadHome: true)
        defer {
            if activeApp.state != .notRunning {
                activeApp.terminate()
            }
        }

        XCUIDevice.shared.press(.home)
        try wait(activeApp, milestone: "active-download qualification host backgrounded") {
            activeApp.state == .runningBackground
        }
        activeApp.activate()
        let unlockTrigger = activeApp.buttons["Equals"]
        try wait(activeApp, milestone: "active-download qualification Root locked") {
            activeApp.state == .runningForeground && unlockTrigger.exists && unlockTrigger.isHittable
        }
        unlockTrigger.press(forDuration: 1)

        let credentialField = activeApp.secureTextFields["PIN"]
        try wait(activeApp, milestone: "active-download qualification credential form") {
            credentialField.exists && credentialField.isHittable
        }
        XCTAssertFalse(activeApp.buttons["Browser Menu"].exists)
    }

    func testSlowKnownWitnessAcceptsCorrelatedNativeProgress() {
        XCTAssertNotNil(SlowKnownWitnessContract.witness(from: slowKnownEvents()))
    }

    func testSlowKnownWitnessRejectsMissingHandoffOrProgress() {
        let events = slowKnownEvents()
        XCTAssertNil(SlowKnownWitnessContract.witness(from: events.filter { $0["event"] != "nativeDownloadHandoff" }))
        XCTAssertNil(SlowKnownWitnessContract.witness(from: events.filter { $0["event"] != "slowKnownProgress" }))
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
            "slowKnownWriterTerminalAcknowledged",
            time: "1.45",
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

    func testSlowKnownCancellationAcceptsPeerClosedDuringResponse() throws {
        let events = slowKnownCancellationEvents(closeReason: "peerClosedDuringResponse")
        let witness = try XCTUnwrap(SlowKnownWitnessContract.witness(from: events))

        XCTAssertNotNil(SlowKnownWitnessContract.cancellationEvidence(from: events, for: witness))
    }

    func testSlowKnownCancellationAcceptsPeerReceiveFailureDuringResponse() throws {
        let events = slowKnownCancellationEvents(closeReason: "peerReceiveFailedDuringResponse")
        let witness = try XCTUnwrap(SlowKnownWitnessContract.witness(from: events))

        XCTAssertNotNil(SlowKnownWitnessContract.cancellationEvidence(from: events, for: witness))
    }

    func testSlowKnownCancellationRejectsDeadlineDrivenTermination() throws {
        let deadlineReason = slowKnownCancellationEvents(
            closeReason: "existingDeadline",
            deadlineElapsedMilliseconds: "14999",
        )
        let witness = try XCTUnwrap(SlowKnownWitnessContract.witness(from: deadlineReason))
        XCTAssertNil(SlowKnownWitnessContract.cancellationEvidence(from: deadlineReason, for: witness))

        let expired = slowKnownCancellationEvents(deadlineElapsedMilliseconds: "15000")
        let expiredWitness = try XCTUnwrap(SlowKnownWitnessContract.witness(from: expired))
        XCTAssertNil(SlowKnownWitnessContract.cancellationEvidence(from: expired, for: expiredWitness))
    }

    func testSlowKnownCancellationIgnoresAnUnrelatedConnection() throws {
        var events = slowKnownCancellationEvents()
        events.append(qualificationEvent(
            "slowKnownConnectionClosed",
            time: "2.05",
            fields: [
                "operation": "33333333-3333-4333-8333-333333333333",
                "connectionID": "55555555-5555-4555-8555-555555555555",
                "connectionClosed": "true",
                "closeReason": "existingDeadline",
                "responseComplete": "false",
                "deadlineElapsedMilliseconds": "15000",
                "connectionClosedMonotonicSeconds": "2.05",
            ],
            requestID: "22222222-2222-4222-8222-222222222222",
        ))
        let witness = try XCTUnwrap(SlowKnownWitnessContract.witness(from: events))

        XCTAssertNotNil(SlowKnownWitnessContract.cancellationEvidence(from: events, for: witness))

        events.removeAll {
            $0["event"] == "slowKnownConnectionClosed"
                && $0["connectionID"] == "44444444-4444-4444-8444-444444444444"
        }
        let unrelatedOnlyWitness = try XCTUnwrap(SlowKnownWitnessContract.witness(from: events))
        XCTAssertNil(SlowKnownWitnessContract.cancellationEvidence(from: events, for: unrelatedOnlyWitness))
    }

    func testSlowKnownCancellationRejectsAConnectionIdentityMismatch() throws {
        let events = slowKnownCancellationEvents(
            connectionID: "55555555-5555-4555-8555-555555555555",
        )
        let witness = try XCTUnwrap(SlowKnownWitnessContract.witness(from: events))

        XCTAssertNil(SlowKnownWitnessContract.cancellationEvidence(from: events, for: witness))
    }

    func testSlowKnownCancellationRejectsInconsistentMonotonicCloseTimestamps() throws {
        var events = slowKnownCancellationEvents(connectionClosedAt: "2.1")
        if let index = events.firstIndex(where: { $0["event"] == "slowKnownConnectionClosed" }) {
            events[index]["monotonicSeconds"] = "2.05"
        }
        let witness = try XCTUnwrap(SlowKnownWitnessContract.witness(from: events))

        XCTAssertNil(SlowKnownWitnessContract.cancellationEvidence(from: events, for: witness))
    }

    func testSlowKnownCancellationRejectsClosureCleanupOrWriterAckBeforeBackground() throws {
        let closeBeforeBackground = slowKnownCancellationEvents(connectionClosedAt: "1.9")
        let closeWitness = try XCTUnwrap(SlowKnownWitnessContract.witness(from: closeBeforeBackground))
        XCTAssertNil(SlowKnownWitnessContract.cancellationEvidence(from: closeBeforeBackground, for: closeWitness))

        let cleanupBeforeBackground = slowKnownCancellationEvents(cleanupAt: "1.9")
        let cleanupWitness = try XCTUnwrap(SlowKnownWitnessContract.witness(from: cleanupBeforeBackground))
        XCTAssertNil(SlowKnownWitnessContract.cancellationEvidence(from: cleanupBeforeBackground, for: cleanupWitness))

        let writerAckBeforeBackground = slowKnownCancellationEvents(writerTerminalAt: "1.9")
        let writerWitness = try XCTUnwrap(SlowKnownWitnessContract.witness(from: writerAckBeforeBackground))
        XCTAssertNil(SlowKnownWitnessContract.cancellationEvidence(from: writerAckBeforeBackground, for: writerWitness))
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

    private func slowKnownCancellationEvents(
        closeReason: String = "peerClosedDuringResponse",
        connectionID: String = "44444444-4444-4444-8444-444444444444",
        connectionClosedAt: String = "2.1",
        deadlineElapsedMilliseconds: String = "1200",
        cleanupAt: String = "2.2",
        writerTerminalAt: String = "2.3",
    ) -> [Observation] {
        var events = slowKnownEvents()
        let runID = "11111111-1111-4111-8111-111111111111"
        let requestID = "22222222-2222-4222-8222-222222222222"
        let operationID = "33333333-3333-4333-8333-333333333333"
        let selectedConnectionID = "44444444-4444-4444-8444-444444444444"
        events.append(qualificationEvent("qualificationScenePhaseChanged", time: "2.0", fields: [
            "fixtureRequest": requestID,
            "operation": operationID,
            "phase": "background",
            "generationBefore": "4",
            "generation": "5",
            "authorizationRevokedSynchronously": "true",
        ], requestID: requestID, runID: runID))
        events.append(qualificationEvent("slowKnownConnectionClosed", time: connectionClosedAt, fields: [
            "operation": operationID,
            "connectionID": connectionID,
            "connectionClosed": "true",
            "closeReason": closeReason,
            "responseComplete": "false",
            "deadlineElapsedMilliseconds": deadlineElapsedMilliseconds,
            "connectionClosedMonotonicSeconds": connectionClosedAt,
        ], requestID: requestID, runID: runID))
        events.append(qualificationEvent("cleanupRemoval", time: cleanupAt, fields: [
            "operation": operationID,
            "absence": "true",
        ], runID: runID))
        events.append(qualificationEvent("slowKnownWriterTerminalAcknowledged", time: writerTerminalAt, fields: [
            "operation": operationID,
            "connectionID": selectedConnectionID,
            "activeWriterCount": "0",
            "retainedRecordCount": "0",
            "cleanupPending": "false",
        ], requestID: requestID, runID: runID))
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

    func testSlowKnownDownloadControlIsAccessibleOnMountedBrowser() throws {
        let app = try launchFixture()
        defer { app.terminate() }

        let control = app.buttons["downloadQualificationStartSlowKnown"]
        XCTAssertTrue(control.waitForExistence(timeout: 5))
        XCTAssertTrue(control.isHittable)
    }

    func testActiveWKDownloadHomeRevokesAndFreshDownloadRecovers() throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Requires a physical device to qualify the active-download Home transition.")
        #endif

        let app = try launchFixture(passiveSceneCensus: true, activeDownloadHome: true)
        defer { app.terminate() }

        try tapControl("downloadQualificationStartSlowKnown", in: app)
        let observationNode = app.staticTexts["downloadQualificationObservations"]
        var witness: SlowKnownWitness?
        var readinessFailure: String?
        try wait(app, milestone: "correlated live slow-known readiness") {
            guard let value = observationNode.value as? String,
                  let events = try? JSONDecoder().decode([Observation].self, from: Data(value.utf8))
            else {
                return false
            }

            witness = SlowKnownWitnessContract.witness(from: events)
            readinessFailure = events.last {
                $0["event"] == "slowKnownReadinessFailure"
            }?["reason"]
            return witness != nil || readinessFailure != nil
        }
        guard let witness else {
            XCTFail("Slow-known readiness failed: \(readinessFailure ?? "unclassified")")
            throw FixtureError.waitFailed
        }

        let beforeHome = Date()
        XCUIDevice.shared.press(.home)
        let classification = XCTAttachment(string: "Process state after Home: \(app.state)")
        classification.name = "active WKDownload background process classification"
        classification.lifetime = .keepAlways
        add(classification)
        try wait(app, milestone: "background or termination classification") {
            app.state == .runningBackground || app.state == .notRunning
        }
        guard app.state != .notRunning else {
            throw XCTSkip("INCONCLUSIVE: the host terminated before active-download revocation could be observed.")
        }

        XCTAssertEqual(app.state, .runningBackground)

        app.activate()
        try wait(app, milestone: "active-download host returned to foreground") {
            app.state == .runningForeground && app.windows.firstMatch.exists && app.windows.firstMatch.isHittable
        }
        let observed = try observations(app)
        let cancellation = try XCTUnwrap(
            SlowKnownWitnessContract.cancellationEvidence(from: observed, for: witness),
            "The selected connection must close because of background revocation before its fixture deadline.",
        )
        XCTAssertEqual(cancellation["connectionID"], witness.connectionID)
        let revoked = try postRevocationEvidence(observed, for: witness.diagnosticFields, after: beforeHome)
        let backgroundPhase = try XCTUnwrap(revoked.first {
            $0["event"] == "qualificationScenePhaseChanged"
                && $0["fixtureRequest"] == witness.requestID && $0["phase"] == "background"
        })
        let serverPrefix = try XCTUnwrap(observed.first {
            $0["event"] == "slowKnownServerPrefixProcessed"
                && $0["fixtureRequest"] == witness.requestID
        })
        let prefixTime = try XCTUnwrap(serverPrefix["monotonicSeconds"].flatMap(Double.init))
        let backgroundTime = try XCTUnwrap(backgroundPhase["monotonicSeconds"].flatMap(Double.init))
        XCTAssertGreaterThan(backgroundTime, prefixTime)
        XCTAssertLessThan(backgroundTime - prefixTime, 14)
        let generationBeforeBackground = try XCTUnwrap(backgroundPhase["generationBefore"])
        let generationAfterBackground = try XCTUnwrap(UInt64(backgroundPhase["generation"] ?? ""))
        let readinessGeneration = try XCTUnwrap(UInt64(witness.generation))
        XCTAssertEqual(generationBeforeBackground, witness.generation)
        XCTAssertGreaterThan(generationAfterBackground, readinessGeneration)
        XCTAssertEqual(backgroundPhase["authorizationRevokedSynchronously"], "true")
        XCTAssertFalse(revoked.contains {
            $0["event"] == "slowKnownReadinessFailure" && $0["fixtureRequest"] == witness.requestID
        })
        XCTAssertTrue(revoked.contains {
            $0["event"] == "qualificationScenePhaseChanged"
                && $0["fixtureRequest"] == witness.requestID && $0["phase"] == "background"
        })
        XCTAssertTrue(revoked.contains {
            $0["event"] == "qualificationScenePhaseChanged"
                && $0["fixtureRequest"] == witness.requestID && $0["phase"] == "active"
        })
        XCTAssertTrue(revoked.contains {
            $0["event"] == "slowKnownWriterTerminalAcknowledged"
                && $0["fixtureRequest"] == witness.requestID
                && $0["operation"] == witness.operationID
                && $0["activeWriterCount"] == "0"
                && $0["retainedRecordCount"] == "0"
                && $0["cleanupPending"] == "false"
        })
        XCTAssertTrue(revoked.contains {
            $0["event"] == "cleanupRemoval"
                && $0["operation"] == witness.operationID && $0["absence"] == "true"
        }, "Missing cleanup evidence proving the revoked allocation is absent")
        XCTAssertFalse(app.buttons["Preview"].exists)
        XCTAssertFalse(app.buttons["Share"].exists)

        let unlockTrigger = app.buttons["Equals"]
        try wait(app, milestone: "locked Root calculator authentication trigger") {
            unlockTrigger.exists && unlockTrigger.isHittable
        }
        unlockTrigger.press(forDuration: 1)
        let credentialField = app.secureTextFields["PIN"]
        try wait(app, milestone: "fixture authentication form") {
            credentialField.exists && credentialField.isHittable
        }
        credentialField.tap()
        credentialField.typeText("1234")
        let unlock = app.buttons["Unlock"]
        try wait(app, milestone: "fixture credential submission") {
            unlock.exists && unlock.isHittable
        }
        unlock.tap()
        try wait(app, milestone: "authenticated Root Browser available") {
            app.buttons["Browser Menu"].isHittable
        }
        XCTAssertTrue(app.buttons["Browser Menu"].isHittable)

        try openDownloadSheet(app)
        try wait(app, milestone: "revoked operation absent from Downloads") {
            app.staticTexts["No Downloads"].exists
                && !app.buttons["Preview"].exists && !app.buttons["Share"].exists
        }
        try closeDownloads(app)
        XCTAssertTrue(app.buttons["Browser Menu"].isHittable)

        try tapControl("downloadQualificationOpenFixturePage", in: app)
        let fresh = try download(app)
        XCTAssertNotEqual(witness.operationID, fresh["operation"])
        let finalEvents = try observations(app)
        let snapshot = try XCTUnwrap(finalEvents.last { $0["event"] == "ownerSnapshot" })
        XCTAssertFalse(try XCTUnwrap(snapshot["operations"]).contains(witness.operationID))
        XCTAssertTrue(try XCTUnwrap(snapshot["operations"]).contains(try XCTUnwrap(fresh["operation"])))
    }

    func testActiveDiscardFailureRetryAndAuthenticationLoss() throws {
        let app = try launchFixture()
        defer { app.terminate() }
        let first = try download(app)
        try tapControl("downloadQualificationArmRemovalFailure", in: app)
        try openDownloads(app)
        try tap(app.buttons["Discard"], in: app)
        // The production reducer closes Downloads on retryable cleanup failure. Qualify that
        // transition before reopening the real sheet; completed-file actions no longer exist.
        try wait(app, milestone: "cleanup failure returns to usable Browser") {
            app.buttons["Browser Menu"].isHittable && !app.navigationBars["Downloads"].exists
                && app.staticTexts["browserDownloadNotice"].exists
                && app.staticTexts["browserDownloadNotice"].label
                == "Downloads are unavailable until temporary-file cleanup succeeds."
        }
        try openDownloadSheet(app)
        let retry = app.buttons["Retry Download Cleanup"]
        try wait(app, milestone: "rendered cleanup retry") { retry.exists && retry.isHittable }
        capture(app, milestone: "active discard cleanup failure and actual Retry")
        retry.tap()
        try wait(app, milestone: "completed cleanup empty Downloads") {
            !retry.exists && app.staticTexts["No Downloads"].exists
        }
        try closeDownloads(app)
        let recovered = try observations(app)
        XCTAssertTrue(recovered.contains { $0["event"] == "cleanupInjectedFailure" })
        assertRemoved(first, in: recovered)
        XCTAssertTrue(recovered.contains { $0["event"] == "ownerSnapshot" && $0["cleanupRetry"] == "false" })
        XCTAssertTrue(app.buttons["Browser Menu"].isHittable)
        try tapControl("downloadQualificationOpenFixturePage", in: app)
        let second = try download(app)
        XCTAssertNotEqual(first["operation"], second["operation"])
        let beforeAuthenticationLoss = Date()
        try tapControl("downloadQualificationRemoveAuthentication", in: app)
        try wait(app, milestone: "safe unauthenticated Root usable") {
            app.buttons["downloadQualificationRefreshObservations"].isHittable
                && !app.buttons["Browser Menu"].exists
        }
        let lost = try observations(app)
        let authRevoked = try postRevocationEvidence(lost, for: second, after: beforeAuthenticationLoss)
        XCTAssertTrue(authRevoked.contains { $0["event"] == "fixtureAuthenticationLost" })
        assertRemoved(second, in: authRevoked)
        XCTAssertFalse(app.buttons["Preview"].exists)
        XCTAssertFalse(app.buttons["Share"].exists)
        capture(app, milestone: "real Root authentication loss, safe surface and no old actions")
    }

    private func qualifyHomeInterruption(action: String) throws {
        let app = try launchFixture()
        defer { app.terminate() }
        let first = try download(app)
        try openDownloads(app)
        try tap(app.buttons[action], in: app)
        if action == "Preview" {
            let preview = app.descendants(matching: .any)["QLPreviewControllerView"]
            let document = preview.descendants(matching: .any)["QLPDFViewControllerViewAccessibilityIdentifier"]
            let probe = document.staticTexts["Browser download transfer probe"]
            // A presented Quick Look shell can precede PDF rendering. Require the document's
            // actual semantic text and visible geometry within the native container before Home.
            try wait(app, milestone: "rendered native PDF probe text") {
                guard preview.exists, document.exists, probe.exists,
                      app.buttons["QLOverlayDoneButtonAccessibilityIdentifier"].exists
                else {
                    return false
                }

                return probe.label == "Browser download transfer probe" && !probe.frame.isEmpty
                    && !document.frame.isEmpty && !preview.frame.isEmpty
                    && probe.frame.intersects(document.frame) && probe.frame.intersects(preview.frame)
                    && probe.frame.intersects(app.frame)
            }
            let pixels = XCTAttachment(screenshot: document.screenshot())
            pixels.name = "rendered native PDF before Home"
            pixels.lifetime = .keepAlways
            add(pixels)
            let geometry =
                XCTAttachment(string: "preview=\(preview.frame); PDF=\(document.frame); probe=\(probe.frame)")
            geometry.name = "native PDF rendered-content geometry"
            geometry.lifetime = .keepAlways
            add(geometry)
        } else {
            try wait(app, milestone: "native activity sheet") {
                app.descendants(matching: .any)["Copy"].exists || app.descendants(matching: .any)["AirDrop"].exists
            }
        }
        capture(app, milestone: "actual native \(action) before Home")
        let beforeHome = Date()
        XCUIDevice.shared.press(.home)
        app.activate()
        try wait(app, milestone: "reactivated application window") {
            app.state == .runningForeground && app.windows.firstMatch.exists && app.windows.firstMatch.isHittable
        }
        // No test dismissal of a native controller is allowed to manufacture successful revocation.
        // If a retained Downloads sheet requires closing, absence must already predate that tap.
        try wait(app, milestone: "native \(action) disappears without a Done tap") {
            if action == "Preview" {
                return !app.descendants(matching: .any)["QLPreviewControllerView"].exists
                    && !app.buttons["QLOverlayDoneButtonAccessibilityIdentifier"].exists
            }
            return !app.descendants(matching: .any)["Copy"].exists
                && !app.descendants(matching: .any)["AirDrop"].exists
        }
        let beforeClosingSheet = Date()
        try closeDownloads(app)
        let observed = try observations(app)
        let revoked = try postRevocationEvidence(observed, for: first, after: beforeHome)
        let absence = try XCTUnwrap(revoked.last { $0["event"] == "nativeAbsenceConfirmed" })
        let absenceTime = try observationDate(absence)
        XCTAssertLessThanOrEqual(absenceTime, beforeClosingSheet)
        XCTAssertTrue(observed.contains {
            $0["event"] == "nativePresentationCompleted" && $0["operation"] == first["operation"]
                && $0["runID"] == first["runID"]
        })
        XCTAssertTrue(revoked.contains { $0["event"] == "privacyRevoked" })
        let covered = try XCTUnwrap(revoked.last { $0["coverVisible"] == "true" })
        XCTAssertEqual(covered["coverFrame"], covered["sceneBounds"].map { "Optional(\($0))" })
        XCTAssertNotNil(covered["sceneSession"])
        assertRemoved(first, in: revoked)
        XCTAssertFalse(app.descendants(matching: .any)["QLPreviewControllerView"].exists)
        XCTAssertFalse(app.buttons["QLOverlayDoneButtonAccessibilityIdentifier"].exists)
        XCTAssertTrue(app.buttons["Browser Menu"].isHittable)
        capture(app, milestone: "\(action) revoked, safe Root recovered")
        let second = try download(app)
        XCTAssertNotEqual(first["operation"], second["operation"])
        let fresh = try observations(app)
        let snapshot = try XCTUnwrap(fresh.last { $0["event"] == "ownerSnapshot" })
        XCTAssertFalse(try XCTUnwrap(snapshot["operations"]).contains(try XCTUnwrap(first["operation"])))
        XCTAssertTrue(try XCTUnwrap(snapshot["operations"]).contains(try XCTUnwrap(second["operation"])))
        capture(app, milestone: "fresh operation, no revoked source resurrection")
    }

    private func launchFixture(
        passiveSceneCensus: Bool = false,
        activeDownloadHome: Bool = false,
    ) throws -> XCUIApplication {
        let app = XCUIApplication(bundleIdentifier: "com.danielbyon.mediavault.browserdownloadqualificationhost")
        app.launchArguments = ["--browser-download-production-qualification"]
        if passiveSceneCensus {
            app.launchArguments.append("--browser-download-passive-scene-census")
        }
        if activeDownloadHome {
            app.launchArguments.append("--browser-download-active-download-home")
        }
        #if targetEnvironment(simulator)
        app.launchArguments.append("--browser-download-simulated-protection-readback")
        #endif
        app.launch()
        XCTAssertTrue(app.staticTexts["downloadQualificationProtectionQualificationMode"].waitForExistence(timeout: 10))
        let modeLabel = app.staticTexts["downloadQualificationProtectionQualificationMode"].label
        #if targetEnvironment(simulator)
        XCTAssertTrue(modeLabel.contains("UNVERIFIED"))
        #else
        XCTAssertTrue(modeLabel.contains("Real native .complete verification required"))
        #endif
        try wait(app, milestone: "fixture server ready") {
            app.staticTexts["Loopback ready. Open fixture page, then download attachment PDF."].exists
        }
        try tapControl("downloadQualificationOpenFixturePage", in: app)
        try wait(app, milestone: "root browser bridge registration") {
            let refresh = app.buttons["downloadQualificationRefreshObservations"]
            guard refresh.exists, refresh.isHittable else {
                return false
            }

            refresh.tap()
            guard let value = app.staticTexts["downloadQualificationObservations"].value as? String,
                  let events = try? JSONDecoder().decode([Observation].self, from: Data(value.utf8))
            else {
                return false
            }

            return events.contains {
                $0["event"] == "mountedWebKitBridge"
                    && $0["adapterIdentity"] == $0["commandAdapterIdentity"]
                    && $0["tabID"]?.isEmpty == false
            }
        }
        return app
    }

    private func download(_ app: XCUIApplication) throws -> Observation {
        try wait(app, milestone: "real loopback readiness") {
            app.staticTexts["Loopback ready. Open fixture page, then download attachment PDF."].exists
        }
        let earlier = try observations(app).filter { $0["event"] == "completedFileProof" }
        try tapControl("downloadQualificationDownloadAttachment", in: app)
        var proof: Observation?
        try wait(app, milestone: "actual WebKit completed-file proof") {
            guard let events = try? self.observations(app) else {
                return false
            }

            proof = events.last { event in
                event["event"] == "completedFileProof"
                    && !earlier.contains { $0["operation"] == event["operation"] }
            }
            return proof != nil
        }
        let result = try XCTUnwrap(proof)
        // The attachment route serves BrowserDownloadLoopbackServer.fixturePDF (608 bytes).
        // The UI-test bundle cannot import that AppHostedTests unit-test target symbol, so the
        // current fixture identity is pinned here; fixtureBytesMatch below verifies the served
        // bytes byte-for-byte against the fixture.
        XCTAssertEqual(result["bytes"], "608")
        XCTAssertEqual(result["sha256"], "852ba89aa0d708405217efd9cc3d014f4a1cc48ed1895748a1e1d9540f97bd79")
        XCTAssertEqual(result["backupExcluded"], "true")
        XCTAssertEqual(result["fixtureBytesMatch"], "true")
        #if targetEnvironment(simulator)
        XCTAssertEqual(result["nativeProtection"], "UNVERIFIED")
        XCTAssertEqual(result["protectionMode"], "simulatedReadback")
        #else
        XCTAssertEqual(result["nativeProtection"], "verified")
        XCTAssertEqual(result["protectionMode"], "nativeCompleteRequired")
        #endif
        XCTAssertTrue(try observations(app).contains {
            $0["event"] == "nativeDownloadHandoff" && $0["sameOrigin"] == "true"
        })
        return result
    }

    /// Recovery must describe this run's invalidation of this completed operation, not a historical
    /// successful layout. The latest native/root observation must confirm the revoked generation.
    private func postRevocationEvidence(
        _ observations: [Observation],
        for proof: Observation,
        after boundary: Date,
    ) throws -> [Observation] {
        let runID = try XCTUnwrap(proof["runID"])
        let events = try observations.filter { observation in
            try observation["runID"] == runID && observationDate(observation) >= boundary
        }
        let revocation = try XCTUnwrap(events.last { $0["event"] == "privacyRevoked" })
        let generation = try XCTUnwrap(revocation["generation"])
        XCTAssertGreaterThan(
            try XCTUnwrap(UInt64(generation)),
            try XCTUnwrap(try UInt64(XCTUnwrap(proof["generation"]))),
        )
        let currentRoot = try XCTUnwrap(events.last { $0["rootProof"] != nil })
        XCTAssertEqual(currentRoot["generation"], generation)
        XCTAssertGreaterThanOrEqual(try observationDate(currentRoot), try observationDate(revocation))
        XCTAssertEqual(currentRoot["rootProof"], "true")
        XCTAssertEqual(currentRoot["nativeBarrier"], "false")
        XCTAssertEqual(currentRoot["coverVisible"], "false")
        return events
    }

    private func observationDate(_ observation: Observation) throws -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return try XCTUnwrap(try formatter.date(from: XCTUnwrap(observation["wallTime"])))
    }

    private func assertRemoved(_ proof: Observation, in events: [Observation]) {
        XCTAssertTrue(events.contains {
            $0["event"] == "cleanupRemoval" && $0["operation"] == proof["allocation"]
                && $0["runID"] == proof["runID"] && $0["absence"] == "true"
        }, "Missing actual removal/verified absence for this completed allocation")
    }

    private func openDownloadSheet(_ app: XCUIApplication) throws {
        try tap(app.buttons["Browser Menu"], in: app)
        try tap(app.buttons["Downloads"], in: app)
        try wait(app, milestone: "production Downloads sheet") { app.navigationBars["Downloads"].exists }
    }

    private func openDownloads(_ app: XCUIApplication) throws {
        try openDownloadSheet(app)
        try wait(app, milestone: "completed production actions") {
            app.buttons["Preview"].exists && app.buttons["Preview"].isEnabled
        }
    }

    private func closeDownloads(_ app: XCUIApplication) throws {
        if app.buttons["Done"].exists {
            try tap(app.buttons["Done"], in: app)
        }
        try wait(app, milestone: "safe Browser surface") { app.buttons["Browser Menu"].isHittable }
    }

    private func observations(_ app: XCUIApplication) throws -> [Observation] {
        try tapControl("downloadQualificationRefreshObservations", in: app)
        let node = app.staticTexts["downloadQualificationObservations"]
        guard let value = node.value as? String else {
            throw FixtureError.missingObservation
        }

        let attachment = XCTAttachment(string: value)
        attachment.name = "actual qualification observations"
        attachment.lifetime = .keepAlways
        add(attachment)
        return try JSONDecoder().decode([Observation].self, from: Data(value.utf8))
    }

    private func tapControl(_ identifier: String, in app: XCUIApplication) throws {
        let button = app.buttons[identifier]
        let strip = app.scrollViews["downloadQualificationControls"]
        // Scroll real controls into reach; this is not a synthesized lifecycle notification.
        if !button.isHittable {
            for _ in 0 ..< 3 where !button.isHittable {
                strip.swipeRight()
            }
            for _ in 0 ..< 3 where !button.isHittable {
                strip.swipeLeft()
            }
        }
        try tap(button, in: app)
    }

    private func tap(_ element: XCUIElement, in app: XCUIApplication) throws {
        try wait(app, milestone: "hittable \(element.identifier)") { element.exists && element.isHittable }
        element.tap()
    }

    private func wait(_ app: XCUIApplication, milestone: String, condition: @escaping @MainActor () -> Bool) throws {
        let predicate = NSPredicate { _, _ in MainActor.assumeIsolated { condition() } }
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: nil)
        guard XCTWaiter.wait(for: [expectation], timeout: 10) == .completed else {
            capture(app, milestone: "FAILED \(milestone)")
            XCTFail("Timed out: \(milestone)")
            throw FixtureError.waitFailed
        }
    }

    private func capture(_ app: XCUIApplication, milestone: String) {
        let image = XCTAttachment(screenshot: app.screenshot())
        image.name = milestone
        image.lifetime = .keepAlways
        add(image)
        let tree = XCTAttachment(string: app.debugDescription)
        tree.name = "\(milestone) accessibility tree"
        tree.lifetime = .keepAlways
        add(tree)
    }
}
