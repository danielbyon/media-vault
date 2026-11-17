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
        let route: String
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
                $0["event"] == "fixtureNavigationRequested"
                    && ["slow-known", "finite-continuation"].contains($0["fixtureRoute"] ?? "")
            }
            guard navigations.count == 1, let navigation = navigations.first,
                  let runID = navigation["runID"], let requestID = navigation["fixtureRequest"],
                  let route = navigation["fixtureRoute"]
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

            let admissions = runEvents.filter {
                $0["event"] == "transferAdmitted" && $0["fixtureRequest"] == requestID
            }
            let policies = runEvents.filter {
                $0["event"] == "policyDownloadAdmitted" && $0["fixtureRequest"] == requestID
            }
            guard admissions.count == 1, let admission = admissions.first,
                  policies.count == 1, let policy = policies.first,
                  let capability = policy["capability"], UUID(uuidString: capability) != nil,
                  policy["operation"] == operationID, admission["operation"] == operationID,
                  admission["capability"] == capability, admission["connectionID"] == connectionID,
                  let policyTime = policy["monotonicSeconds"].flatMap(Double.init),
                  let admissionTime = admission["monotonicSeconds"].flatMap(Double.init),
                  policyTime.isFinite, admissionTime.isFinite
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

                if ["writerFinished", "writerFailed", "nativeCancellationRequested", "pendingTransferCancelled"]
                    .contains(event["event"] ?? "") {
                    return event["operation"] == operationID && eventTime <= readyTime
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
                  server["route"] == route, server["requestParsed"] == "true",
                  server["requestCount"] == "1", server["connectionCount"] == "1",
                  server["sendStackState"] == "stackPrefixProcessed",
                  server["responseComplete"] == "false", server["connectionClosed"] == "false",
                  prefix > 0, prefix < expected,
                  handoff["fixtureRoute"] == route, handoff["fixtureOrigin"] == "true",
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
                  times.count == 5, times.allSatisfy(\.isFinite),
                  times[0] < policyTime, policyTime < times[2], times[2] < admissionTime, admissionTime < times[3],
                  times[0] < times[1], times[0] < times[2], times[1] < times[4],
                  times[2] < times[3], times[3] < times[4],
                  elapsed > 0, elapsed <= 10_000,
                  !failed, !earlyTerminalOrCleanup, !cleanupFailed
            else {
                return nil
            }

            return SlowKnownWitness(
                runID: runID,
                route: route,
                requestID: requestID,
                operationID: operationID,
                connectionID: connectionID,
                generation: generation,
                elapsedMilliseconds: elapsed,
            )
        }

        /// A released response and a native finish are independent witnesses. Both are required.
        static func continuationEvidence(
            from events: [Observation],
            for witness: SlowKnownWitness,
        ) -> Observation? {
            guard events.count <= 256, witness.route == "finite-continuation" else {
                return nil
            }

            let run = events.filter { $0["runID"] == witness.runID }
            func selected(_ name: String) -> Observation? {
                let matches = run.filter {
                    $0["event"] == name && $0["fixtureRequest"] == witness.requestID
                        && $0["operation"] == witness.operationID
                        && $0["connectionID"] == witness.connectionID
                        && (name != "qualificationScenePhaseChanged" || $0["phase"] == "background")
                }
                return matches.count == 1 ? matches.first : nil
            }
            guard let admission = selected("transferAdmitted"),
                  let capability = admission["capability"], UUID(uuidString: capability) != nil,
                  let policy = run.first(where: {
                      $0["event"] == "policyDownloadAdmitted" && $0["capability"] == capability
                          && $0["fixtureRequest"] == witness.requestID
                  }),
                  let handoff = run.first(where: {
                      $0["event"] == "nativeDownloadHandoff" && $0["fixtureRequest"] == witness.requestID
                  }),
                  let readiness = selected("slowKnownReadiness"),
                  let background = selected("qualificationScenePhaseChanged"),
                  let release = selected("finiteResponseReleaseRequested"),
                  let response = selected("finiteResponseCompleted"),
                  let finish = selected("writerFinished"),
                  let progress = selected("nativePostLockProgress"),
                  let hidden = selected("hiddenCompletion")
            else {
                return nil
            }

            let milestones = [policy, admission, handoff, readiness, background, release, response, finish, hidden]
            let times = milestones.compactMap { $0["monotonicSeconds"].flatMap(Double.init) }
            guard times.count == milestones.count, times.allSatisfy(\.isFinite),
                  times[0] < times[2], times[2] < times[1], times[1] < times[3],
                  times[3] < times[4], times[4] < times[5], times[5] < times[6],
                  times[5] < times[7], times[7] < times[8],
                  background["phase"] == "background", background["authorizationRevokedSynchronously"] == "true",
                  background["contentEmpty"] == "true", background["available"] == "false",
                  background["authenticated"] == "false", background["activeWriterCount"] == "1",
                  background["retainedRecordCount"] == "1",
                  let generationBefore = UInt64(background["generationBefore"] ?? ""),
                  let generation = UInt64(background["generation"] ?? ""),
                  let initial = UInt64(witness.generation), generationBefore >= initial,
                  generation > generationBefore,
                  response["sendStackState"] == "stackProcessed",
                  let expected = Int(response["expectedBytes"] ?? ""),
                  let prefix = Int(response["prefixBytes"] ?? ""),
                  let remainder = Int(response["remainderBytes"] ?? ""),
                  let releaseTime = response["releaseMonotonicSeconds"].flatMap(Double.init),
                  releaseTime.isFinite, times[5] <= releaseTime, releaseTime <= times[6],
                  expected > prefix, prefix > 0, remainder == expected - prefix,
                  let received = Int(progress["receivedBytes"] ?? ""), received > prefix, received <= expected,
                  progress["expectedBytes"] == String(expected), progress["authenticated"] == "false",
                  progress["available"] == "false", progress["capability"] == capability,
                  let callbackTime = progress["callbackMonotonicSeconds"].flatMap(Double.init),
                  callbackTime.isFinite, callbackTime > releaseTime,
                  response["expectedBytes"] == readiness["expectedBytes"],
                  [release, response, finish, hidden].allSatisfy({ $0["capability"] == capability }),
                  hidden["contentEmpty"] == "true", hidden["available"] == "false",
                  hidden["authenticated"] == "false", hidden["activeWriterCount"] == "0",
                  hidden["retainedRecordCount"] == "1",
                  !run.contains(where: {
                      [
                          "nativeCancellationRequested",
                          "writerCancellationAcknowledged",
                          "writerFailed",
                          "cleanupRemoval",
                      ]
                      .contains($0["event"] ?? "") && $0["operation"] == witness.operationID
                  })
            else {
                return nil
            }

            return hidden
        }
    }

    /// Policy admission alone cannot satisfy this contract: native handoff and finish must follow Lock.
    private func delayedHandoffEvidence(_ events: [Observation]) -> Observation? {
        guard events.count <= 256 else {
            return nil
        }

        let navigations = events.filter {
            $0["event"] == "fixtureNavigationRequested" && $0["fixtureRoute"] == "delayed-handoff"
        }
        guard navigations.count == 1, let navigation = navigations.first,
              let runID = navigation["runID"], let request = navigation["fixtureRequest"] else {
            return nil
        }

        let run = events.filter { $0["runID"] == runID && $0["fixtureRequest"] == request }
        func one(_ event: String) -> Observation? {
            let matches = run.filter { $0["event"] == event }
            return matches.count == 1 ? matches.first : nil
        }
        guard let policy = one("policyDownloadAdmitted"), let locked = one("pendingPolicyLockApplied"),
              let handoff = one("nativeDownloadHandoff"), let admitted = one("transferAdmitted"),
              let finished = one("writerFinished"), let hidden = one("hiddenCompletion"),
              let progress = one("nativePostLockProgress"),
              let operation = admitted["operation"], UUID(uuidString: operation) != nil,
              let capability = policy["capability"], UUID(uuidString: capability) != nil,
              let connection = admitted["connectionID"], UUID(uuidString: connection) != nil
        else {
            return nil
        }

        let milestones = [navigation, policy, locked, handoff, admitted, finished, hidden]
        let times = milestones.compactMap { $0["monotonicSeconds"].flatMap(Double.init) }
        guard times.count == milestones.count, times.allSatisfy(\.isFinite),
              zip(times, times.dropFirst()).allSatisfy({ pair in pair.0 < pair.1 }),
              locked["authenticated"] == "false", locked["available"] == "false", locked["contentEmpty"] == "true",
              let before = UInt64(locked["generationBefore"] ?? ""),
              let after = UInt64(locked["generation"] ?? ""), after > before,
              handoff["sameOrigin"] == "true", handoff["fixtureOrigin"] == "true",
              handoff["fixtureRoute"] == "delayed-handoff",
              [policy, locked, admitted, finished, hidden].allSatisfy({
                  $0["operation"] == operation && $0["capability"] == capability && $0["connectionID"] == connection
              }),
              progress["operation"] == operation, progress["capability"] == capability,
              progress["connectionID"] == connection, progress["authenticated"] == "false",
              progress["available"] == "false",
              let received = Int(progress["receivedBytes"] ?? ""), received > 0,
              let progressTime = progress["callbackMonotonicSeconds"].flatMap(Double.init),
              progressTime.isFinite, progressTime > times[2],
              hidden["authenticated"] == "false", hidden["available"] == "false", hidden["contentEmpty"] == "true",
              hidden["activeWriterCount"] == "0", hidden["retainedRecordCount"] == "1",
              !events.contains(where: {
                  $0["runID"] == runID && $0["operation"] == operation
                      && ["nativeCancellationRequested", "pendingTransferCancelled", "writerFailed", "cleanupRemoval"]
                      .contains($0["event"] ?? "")
              })
        else {
            return nil
        }

        return hidden
    }

    func testAcceptedPolicyHandoffAfterLockCompletesHiddenUntilFreshAuthentication() throws {
        let app = try launchFixture(passiveSceneCensus: true, delayedHandoffLock: true)
        defer { app.terminate() }
        try tapControl("downloadQualificationStartDelayedHandoff", in: app)
        var completion: Observation?
        try wait(app, milestone: "actual WebKit handoff after accepted-policy Lock and hidden native finish") {
            guard let events = try? self.observations(app) else {
                return false
            }

            completion = self.delayedHandoffEvidence(events)
            return completion != nil
        }
        let hidden = try XCTUnwrap(completion)
        XCTAssertFalse(app.buttons["Preview"].exists)
        XCTAssertFalse(app.buttons["Share"].exists)
        try authenticateLockedFixture(app)
        try openDownloads(app)
        try closeDownloads(app)
        let events = try observations(app)
        let retained = try XCTUnwrap(events.last {
            $0["event"] == "retainedCompletionReconciled" && $0["operation"] == hidden["operation"]
                && $0["fixtureRequest"] == hidden["fixtureRequest"] && $0["connectionID"] == hidden["connectionID"]
        })
        XCTAssertEqual(retained["authenticated"], "true")
        XCTAssertEqual(retained["available"], "true")
        XCTAssertGreaterThan(
            try XCTUnwrap(Double(retained["monotonicSeconds"] ?? "")),
            try XCTUnwrap(Double(hidden["monotonicSeconds"] ?? "")),
        )
        let file = try XCTUnwrap(events.last {
            $0["event"] == "completedFileProof" && $0["operation"] == hidden["operation"]
        })
        XCTAssertEqual(file["bytes"], "608")
        XCTAssertEqual(file["fixtureBytesMatch"], "true")
        XCTAssertEqual(file["backupExcluded"], "true")
        #if targetEnvironment(simulator)
        XCTAssertEqual(file["nativeProtection"], "UNVERIFIED")
        #else
        XCTAssertEqual(file["nativeProtection"], "verified")
        #endif
        try tapControl("downloadQualificationOpenFixturePage", in: app)
        let fresh = try download(app)
        XCTAssertNotEqual(fresh["operation"], hidden["operation"])
    }

    func testDelayedHandoffParserRequiresNativeCallbacksAfterLock() throws {
        let events = delayedHandoffEvents()
        XCTAssertNotNil(delayedHandoffEvidence(events))
        for name in [
            "nativeDownloadHandoff",
            "transferAdmitted",
            "writerFinished",
            "nativePostLockProgress",
            "hiddenCompletion",
        ] {
            XCTAssertNil(delayedHandoffEvidence(events.filter { $0["event"] != name }), name)
        }
        for (event, field, value) in [
            ("nativeDownloadHandoff", "monotonicSeconds", "1.1"),
            ("transferAdmitted", "operation", "55555555-5555-4555-8555-555555555555"),
            ("writerFinished", "capability", "55555555-5555-4555-8555-555555555555"),
            ("hiddenCompletion", "contentEmpty", "false"),
            ("hiddenCompletion", "authenticated", "true"),
        ] {
            var invalid = events
            let index = try XCTUnwrap(invalid.firstIndex { $0["event"] == event })
            invalid[index][field] = value
            XCTAssertNil(delayedHandoffEvidence(invalid), "\(event).\(field)")
        }
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

    func testOrdinaryPNGDownloadAutomaticallyCommitsCanonicalAsset() throws {
        let app = try launchFixture(automaticIngestion: true)
        defer { app.terminate() }
        let initial = try librarySnapshot(app, assetCount: 0, rowCount: 0)
        XCTAssertEqual(initial["temporaryCount"], "0")

        try tapControl("downloadQualificationDownloadImage", in: app)
        let imported = try librarySnapshot(app, assetCount: 1, rowCount: 1)
        XCTAssertEqual(imported["temporaryCount"], "0")
        XCTAssertEqual(imported["originalBytesMatch"], "true")
        XCTAssertEqual(imported["originalHashMatches"], "true")
        XCTAssertEqual(imported["importedRows"], "1")
        XCTAssertEqual(imported["resourceCount"], "1")
        XCTAssertEqual(imported["temporaryBytes"], "0")
        let operation = try XCTUnwrap(imported["rowIDs"])
        XCTAssertTrue(try observations(app).contains {
            $0["event"] == "writerFinished" && $0["operation"] == operation
        })
        XCTAssertNotNil(try UUID(uuidString: XCTUnwrap(imported["canonicalIDs"])))
        XCTAssertTrue(try observations(app).contains { $0["event"] == "nativeDownloadHandoff" })

        app.terminate()
        app.launch()
        let relaunched = try librarySnapshot(app, assetCount: 1, rowCount: 0)
        XCTAssertEqual(relaunched["canonicalIDs"], imported["canonicalIDs"])
        XCTAssertEqual(relaunched["originalBytesMatch"], "true")
    }

    func testRepeatedPNGDownloadSkipsDuplicateAndRetainsCanonicalIdentity() throws {
        let app = try launchFixture(automaticIngestion: true)
        defer { app.terminate() }
        try tapControl("downloadQualificationDownloadImage", in: app)
        let first = try librarySnapshot(app, assetCount: 1, rowCount: 1)

        // The same PNG arrives with a PDF MIME type and filename on the second request.
        try tapControl("downloadQualificationDownloadMislabelledImage", in: app)
        let duplicate = try librarySnapshot(app, assetCount: 1, rowCount: 2)
        XCTAssertEqual(duplicate["canonicalIDs"], first["canonicalIDs"])
        XCTAssertEqual(duplicate["duplicateRows"], "1")
        XCTAssertEqual(duplicate["temporaryCount"], "0")
        let operations = try XCTUnwrap(duplicate["rowIDs"]).split(separator: ",")
        XCTAssertEqual(Set(operations).count, 2)
        XCTAssertTrue(try operations.contains(Substring(XCTUnwrap(first["rowIDs"]))))
        XCTAssertEqual(duplicate["originalBytesMatch"], "true")
    }

    func testPDFDownloadRemainsOutsideLibraryAndKeepsNativePresentation() throws {
        let app = try launchFixture(automaticIngestion: true)
        defer { app.terminate() }
        try tapControl("downloadQualificationDownloadMislabelledPDF", in: app)
        let excluded = try librarySnapshot(app, assetCount: 0, rowCount: 1)
        XCTAssertEqual(excluded["resourceCount"], "0")
        app.terminate()
        app.launch()
        _ = try librarySnapshot(app, assetCount: 0, rowCount: 0)
        try tapControl("downloadQualificationDownloadAttachment", in: app)
        let pdf = try librarySnapshot(app, assetCount: 0, rowCount: 1)
        XCTAssertEqual(pdf["resourceCount"], "0")
        try openDownloads(app)
        XCTAssertTrue(app.buttons["Preview"].exists)
        XCTAssertTrue(app.buttons["Share"].exists)
        try tap(app.buttons["Preview"], in: app)
        XCTAssertTrue(app.descendants(matching: .any)["QLPreviewControllerView"].waitForExistence(timeout: 10))
        try tap(app.buttons["QLOverlayDoneButtonAccessibilityIdentifier"], in: app)
        try tap(app.buttons["Share"], in: app)
        try wait(app, milestone: "native PDF share sheet") {
            self.nativeShareSurfaceIsPresent(app)
        }
        XCTAssertFalse(nativeShareSurfaceIsAbsent(app))
    }

    func testAcceptedPNGWhileLockedReconcilesAfterAuthenticatedRelaunch() throws {
        let app = try launchFixture(automaticIngestion: true)
        defer { app.terminate() }
        try tapControl("downloadQualificationDownloadImageUnderLock", in: app)
        var accepted: Observation?
        try wait(app, milestone: "durably accepted PNG under app privacy Lock") {
            guard let events = try? self.observations(app) else {
                return false
            }

            accepted = events.last {
                $0["event"] == "acceptedLibraryStorage"
                    && $0["temporaryCount"] == "1"
                    && $0["authenticated"] == "false"
                    && $0["contentEmpty"] == "true"
            }
            return accepted != nil && events.contains { $0["event"] == "writerFinished" }
        }
        XCTAssertFalse(app.buttons["Preview"].exists)
        XCTAssertFalse(app.buttons["Share"].exists)
        let hiddenEvents = try observations(app)
        let lockIndex = try XCTUnwrap(hiddenEvents.lastIndex { $0["event"] == "automaticMediaPolicyLocked" })
        let lockedEvents = hiddenEvents.suffix(from: lockIndex)
        XCTAssertTrue(lockedEvents.contains { $0["event"] == "writerFinished" })
        XCTAssertFalse(lockedEvents.contains { $0["event"] == "canonicalLibrarySnapshot" })

        let durable = try XCTUnwrap(accepted)
        let previousOperation = try XCTUnwrap(lockedEvents.last { $0["event"] == "writerFinished" }?["operation"])
        XCTAssertGreaterThan(try XCTUnwrap(try Int64(XCTUnwrap(durable["temporaryBytes"]))), 0)
        app.terminate()
        XCTAssertEqual(app.state, .notRunning)
        app.launchArguments.append("--browser-download-recovery-authentication")
        app.launch()
        var startup: Observation?
        try wait(app, milestone: "new locked process reopens accepted protected Library") {
            guard let events = try? self.observations(app) else {
                return false
            }

            startup = events.last { $0["event"] == "libraryStartup" }
            return startup != nil
        }
        let reopened = try XCTUnwrap(startup)
        let oldProcessID = try XCTUnwrap(durable["processID"])
        let newProcessID = try XCTUnwrap(reopened["processID"])
        XCTAssertNotEqual(newProcessID, oldProcessID)
        XCTAssertNotEqual(try XCTUnwrap(reopened["runID"]), try XCTUnwrap(durable["runID"]))
        let libraryID = try XCTUnwrap(durable["libraryID"])
        let databaseID = try XCTUnwrap(durable["databaseID"])
        XCTAssertNotNil(UUID(uuidString: libraryID))
        XCTAssertEqual(databaseID.count, 64)
        XCTAssertEqual(reopened["libraryID"], libraryID)
        XCTAssertEqual(reopened["databaseID"], databaseID)
        XCTAssertEqual(reopened["temporaryCount"], "1")
        XCTAssertEqual(reopened["temporaryBytes"], durable["temporaryBytes"])
        XCTAssertEqual(reopened["authenticated"], "false")
        XCTAssertEqual(reopened["rowCount"], "0")
        XCTAssertEqual(reopened["contentEmpty"], "true")
        XCTAssertFalse(try observations(app).contains { $0["event"] == "canonicalLibrarySnapshot" })
        XCTAssertFalse(app.buttons["Preview"].exists)
        XCTAssertFalse(app.buttons["Share"].exists)

        try authenticateLockedFixture(app)
        XCTAssertEqual(app.state, .runningForeground)
        let recovered = try librarySnapshot(app, assetCount: 1, rowCount: 0)
        XCTAssertEqual(recovered["processID"], newProcessID)
        XCTAssertEqual(recovered["databaseID"], reopened["databaseID"])
        XCTAssertEqual(recovered["originalBytesMatch"], "true")
        XCTAssertEqual(recovered["originalHashMatches"], "true")
        XCTAssertEqual(recovered["temporaryCount"], "0")
        XCTAssertEqual(recovered["temporaryBytes"], "0")

        try wait(app, milestone: "relaunched fixture listener ready") {
            app.staticTexts["downloadQualificationLoopbackReadiness"].value as? String == "ready"
        }
        try tapControl("downloadQualificationDownloadImage", in: app)
        let fresh = try librarySnapshot(app, assetCount: 1, rowCount: 1)
        XCTAssertEqual(fresh["canonicalIDs"], recovered["canonicalIDs"])
        XCTAssertEqual(fresh["duplicateRows"], "1")
        XCTAssertEqual(fresh["temporaryCount"], "0")
        let freshOperation = try XCTUnwrap(fresh["rowIDs"])
        XCTAssertNotEqual(freshOperation, previousOperation)
        XCTAssertTrue(try observations(app).contains {
            $0["event"] == "writerFinished" && $0["operation"] == freshOperation
        })
    }

    func testColdLockedAuthenticationKeepsDiagnosticReadoutAccessible() throws {
        let app = XCUIApplication(bundleIdentifier: "com.danielbyon.mediavault.browserdownloadqualificationhost")
        app.launchArguments = [
            "--browser-download-production-qualification",
            "--browser-download-automatic-ingestion",
            "--browser-download-recovery-authentication",
            "--browser-download-library",
            UUID().uuidString,
        ]
        #if targetEnvironment(simulator)
        app.launchArguments.append("--browser-download-simulated-protection-readback")
        #endif
        app.launch()
        defer { app.terminate() }
        var startup: Observation?
        try wait(app, milestone: "cold locked startup without downloads") {
            guard let events = try? self.observations(app) else {
                return false
            }

            startup = events.last { $0["event"] == "libraryStartup" }
            return startup != nil
        }
        let locked = try XCTUnwrap(startup)
        XCTAssertEqual(locked["authenticated"], "false")
        XCTAssertEqual(locked["temporaryCount"], "0")
        XCTAssertEqual(locked["rowCount"], "0")
        let lockedReadout = try XCTUnwrap(try observations(app).last {
            $0["event"] == "diagnosticReadoutState" && $0["phase"] == "locked" && $0["mounted"] == "true"
        })
        try authenticateLockedFixture(app)
        let authenticated = try librarySnapshot(app, assetCount: 0, rowCount: 0)
        XCTAssertEqual(authenticated["processID"], locked["processID"])
        let events = try observations(app)
        let readout = try XCTUnwrap(events.last {
            $0["event"] == "diagnosticReadoutState"
                && $0["sampleSource"] == "rootLayoutConfirmed"
                && $0["sourceRootPhase"] == "authenticated"
                && $0["phase"] == "authenticated"
                && $0["mounted"] == "true"
        })
        XCTAssertNotEqual(readout["mountID"], lockedReadout["mountID"])
        XCTAssertEqual(readout["requestedHidden"], "false")
        XCTAssertEqual(readout["windowAccessibilityHidden"], "false")
        XCTAssertEqual(readout["accessibilityHiddenAncestorCount"], "0")
        XCTAssertEqual(readout["transparentAncestorCount"], "0")
        XCTAssertFalse(events.contains { $0["event"] == "nativeDownloadHandoff" })
    }

    private func librarySnapshot(
        _ app: XCUIApplication,
        assetCount: Int,
        rowCount: Int,
    ) throws -> Observation {
        var snapshot: Observation?
        try wait(app, milestone: "canonical asset and process-row counts") {
            guard let events = try? self.observations(app) else {
                return false
            }

            snapshot = events.last {
                $0["event"] == "canonicalLibrarySnapshot"
                    && $0["assetCount"] == String(assetCount)
                    && $0["rowCount"] == String(rowCount)
                    && $0["settled"] == "true"
            }
            return snapshot != nil
        }
        return try XCTUnwrap(snapshot)
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

    func testContinuationAcceptsFiniteResponseAndNativeFinish() throws {
        let events = continuationEvents()
        let witness = try XCTUnwrap(SlowKnownWitnessContract.witness(from: events))
        XCTAssertNotNil(SlowKnownWitnessContract.continuationEvidence(from: events, for: witness))
        // UIKit may revoke content before SwiftUI delivers the later background action.
        var alreadyRevoked = events
        let backgroundIndex = try XCTUnwrap(alreadyRevoked
            .firstIndex { $0["event"] == "qualificationScenePhaseChanged" })
        let initial = try XCTUnwrap(UInt64(witness.generation))
        alreadyRevoked[backgroundIndex]["generationBefore"] = String(initial + 1)
        alreadyRevoked[backgroundIndex]["generation"] = String(initial + 2)
        XCTAssertNotNil(SlowKnownWitnessContract.continuationEvidence(from: alreadyRevoked, for: witness))
        alreadyRevoked[backgroundIndex]["generation"] = String(initial + 1)
        XCTAssertNil(SlowKnownWitnessContract.continuationEvidence(from: alreadyRevoked, for: witness))
        alreadyRevoked[backgroundIndex]["generationBefore"] = String(initial - 1)
        alreadyRevoked[backgroundIndex]["generation"] = String(initial)
        XCTAssertNil(SlowKnownWitnessContract.continuationEvidence(from: alreadyRevoked, for: witness))
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
            ("finiteResponseReleaseRequested", "monotonicSeconds", "1.9"),
            ("finiteResponseCompleted", "releaseMonotonicSeconds", "1.9"),
            ("writerFinished", "monotonicSeconds", "nan"),
            ("nativePostLockProgress", "receivedBytes", "262144"),
            ("nativePostLockProgress", "callbackMonotonicSeconds", "1.9"),
            ("hiddenCompletion", "contentEmpty", "false"),
            ("hiddenCompletion", "available", "true"),
            ("hiddenCompletion", "authenticated", "true"),
            ("hiddenCompletion", "retainedRecordCount", "0"),
        ]
        for (name, key, value) in mutations {
            var events = continuationEvents()
            let index = try XCTUnwrap(events.firstIndex { $0["event"] == name })
            events[index][key] = value
            let witness = try XCTUnwrap(SlowKnownWitnessContract.witness(from: events))
            XCTAssertNil(SlowKnownWitnessContract.continuationEvidence(from: events, for: witness), "\(name).\(key)")
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

    func testSlowKnownDownloadControlIsAccessibleOnMountedBrowser() throws {
        let app = try launchFixture()
        defer { app.terminate() }

        let control = app.buttons["downloadQualificationStartSlowKnown"]
        XCTAssertTrue(control.waitForExistence(timeout: 5))
        XCTAssertTrue(control.isHittable)
    }

    func testActiveWKDownloadHomeContinuesHiddenAndReconcilesAfterFreshAuthentication() throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Requires a physical device to qualify native WKDownload continuation across Home.")
        #endif

        let app = try launchFixture(passiveSceneCensus: true, activeDownloadHome: true)
        defer { app.terminate() }
        try tapControl("downloadQualificationStartFiniteContinuation", in: app)
        var witness: SlowKnownWitness?
        try wait(app, milestone: "correlated live finite-response readiness") {
            guard let value = app.staticTexts["downloadQualificationObservations"].value as? String,
                  let events = try? JSONDecoder().decode([Observation].self, from: Data(value.utf8))
            else {
                return false
            }

            witness = SlowKnownWitnessContract.witness(from: events)
            return witness != nil || events.contains { $0["event"] == "slowKnownReadinessFailure" }
        }
        let selected = try XCTUnwrap(witness, "Missing native partial-transfer witness")
        XCUIDevice.shared.press(.home)
        try wait(app, milestone: "background or termination classification") {
            app.state == .runningBackground || app.state == .notRunning
        }
        guard app.state != .notRunning else {
            throw XCTSkip("INCONCLUSIVE: process terminated before continuation could be observed.")
        }

        app.activate()
        try wait(app, milestone: "native finish with hidden retained completion") {
            guard let events = try? self.observations(app) else {
                return false
            }

            return SlowKnownWitnessContract.continuationEvidence(from: events, for: selected) != nil
        }
        XCTAssertFalse(app.buttons["Preview"].exists)
        XCTAssertFalse(app.buttons["Share"].exists)
        try authenticateLockedFixture(app)
        try openDownloads(app)
        try closeDownloads(app)
        let reconciled = try observations(app)
        let reconciliation = try XCTUnwrap(reconciled.last {
            $0["event"] == "retainedCompletionReconciled" && $0["operation"] == selected.operationID
                && $0["fixtureRequest"] == selected.requestID && $0["connectionID"] == selected.connectionID
        })
        let retainedFile = try XCTUnwrap(reconciled.last {
            $0["event"] == "completedFileProof" && $0["operation"] == selected.operationID
        })
        XCTAssertEqual(retainedFile["fixtureBytesMatch"], "true")
        XCTAssertEqual(retainedFile["backupExcluded"], "true")
        XCTAssertEqual(retainedFile["nativeProtection"], "verified")
        XCTAssertEqual(reconciliation["authenticated"], "true")
        XCTAssertEqual(reconciliation["available"], "true")
        XCTAssertGreaterThan(
            try XCTUnwrap(UInt64(reconciliation["generation"] ?? "")),
            try XCTUnwrap(UInt64(selected.generation)),
        )
        let hidden = try XCTUnwrap(reconciled.last { $0["event"] == "hiddenCompletion" })
        XCTAssertGreaterThan(
            try XCTUnwrap(Double(reconciliation["monotonicSeconds"] ?? "")),
            try XCTUnwrap(Double(hidden["monotonicSeconds"] ?? "")),
        )
        try tapControl("downloadQualificationOpenFixturePage", in: app)
        let fresh = try download(app)
        XCTAssertNotEqual(selected.operationID, fresh["operation"])
        let finalEvents = try observations(app)
        let snapshot = try XCTUnwrap(finalEvents.last { $0["event"] == "ownerSnapshot" })
        XCTAssertTrue(try XCTUnwrap(snapshot["operations"]).contains(selected.operationID))
        XCTAssertTrue(try XCTUnwrap(snapshot["operations"]).contains(try XCTUnwrap(fresh["operation"])))
    }

    private func authenticateLockedFixture(_ app: XCUIApplication) throws {
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
        XCTAssertFalse(authRevoked.contains {
            $0["event"] == "cleanupRemoval" && $0["operation"] == second["allocation"]
        })
        let hidden = try XCTUnwrap(lost.last { $0["event"] == "ownerSnapshot" })
        XCTAssertEqual(hidden["operations"], "")
        XCTAssertEqual(hidden["available"], "false")
        XCTAssertEqual(hidden["retained"], "1")
        XCTAssertFalse(app.buttons["Preview"].exists)
        XCTAssertFalse(app.buttons["Share"].exists)
        capture(app, milestone: "real Root authentication loss, safe surface and no old actions")
    }

    func testNativeShareOracleRejectsLockedCalculatorCopy() throws {
        let app = try launchFixture(automaticIngestion: true)
        defer { app.terminate() }
        try tap(app.buttons["Lock"], in: app)
        try wait(app, milestone: "public locked calculator without native Share") {
            app.buttons["Equals"].exists && !app.buttons["Browser Menu"].exists
        }
        XCTAssertTrue(app.buttons["Copy"].exists)
        XCTAssertFalse(nativeShareSurfaceIsPresent(app))
        XCTAssertTrue(nativeShareSurfaceIsAbsent(app))
        capture(app, milestone: "calculator Copy is not native Share")
    }

    func testNativeWaitResultsPreserveMilestoneAndCause() {
        let completed = XCTestExpectation(description: "fulfilled native expectation")
        completed.fulfill()
        let completedResult = XCTWaiter.wait(for: [completed], timeout: 1)
        XCTAssertEqual(completedResult, .completed)
        XCTAssertNil(waitFailureMessage(completedResult, milestone: "completed milestone"))

        let pending = XCTestExpectation(description: "unfulfilled native expectation")
        let timedOutResult = XCTWaiter.wait(for: [pending], timeout: 0.01)
        XCTAssertEqual(timedOutResult, .timedOut)
        XCTAssertEqual(
            waitFailureMessage(timedOutResult, milestone: "deadline milestone"),
            "Timed out: deadline milestone",
        )

        // Use XCTest's actual enclosing-wait cancellation, rather than manufacturing a result.
        var armed = false
        var entered = false
        var interruptedResult: XCTWaiter.Result?
        let predicate = NSPredicate { _, _ in
            MainActor.assumeIsolated {
                if armed, !entered {
                    entered = true
                    let nested = XCTestExpectation(description: "nested native expectation")
                    interruptedResult = XCTWaiter.wait(for: [nested], timeout: 10)
                }
                return false
            }
        }
        let enclosing = XCTNSPredicateExpectation(predicate: predicate, object: nil)
        armed = true
        let enclosingResult = XCTWaiter.wait(for: [enclosing], timeout: 2)
        XCTAssertTrue(entered)
        XCTAssertEqual(enclosingResult, .timedOut)
        XCTAssertEqual(interruptedResult, .interrupted)
        if let interruptedResult {
            XCTAssertEqual(
                waitFailureMessage(interruptedResult, milestone: "original nested milestone"),
                "Interrupted by an enclosing waiter: original nested milestone",
            )
        }
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
                self.nativeShareSurfaceIsPresent(app)
            }
            XCTAssertFalse(nativeShareSurfaceIsAbsent(app))
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
            return self.nativeShareSurfaceIsAbsent(app)
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
        XCTAssertFalse(revoked.contains {
            $0["event"] == "cleanupRemoval" && $0["operation"] == first["allocation"]
        })
        try openDownloads(app)
        try closeDownloads(app)
        let current = try observations(app)
        let retained = try XCTUnwrap(current.last { $0["event"] == "ownerSnapshot" })
        XCTAssertEqual(retained["available"], "true")
        XCTAssertTrue(try XCTUnwrap(retained["operations"]).contains(try XCTUnwrap(first["operation"])))
        try tapControl("downloadQualificationCheckPendingAllocation", in: app)
        let retainedEvents = try observations(app)
        let file = try XCTUnwrap(retainedEvents.last {
            $0["event"] == "pendingAllocationPreTerminationCheck" && $0["operation"] == first["operation"]
        })
        XCTAssertEqual(file["verified"], "true")
        XCTAssertEqual(file["present"], "true")
        XCTAssertFalse(app.descendants(matching: .any)["QLPreviewControllerView"].exists)
        XCTAssertFalse(app.buttons["QLOverlayDoneButtonAccessibilityIdentifier"].exists)
        XCTAssertTrue(app.buttons["Browser Menu"].isHittable)
        capture(app, milestone: "\(action) revoked, safe Root recovered")
        let second = try download(app)
        XCTAssertNotEqual(first["operation"], second["operation"])
        let fresh = try observations(app)
        let snapshot = try XCTUnwrap(fresh.last { $0["event"] == "ownerSnapshot" })
        XCTAssertTrue(try XCTUnwrap(snapshot["operations"]).contains(try XCTUnwrap(first["operation"])))
        XCTAssertTrue(try XCTUnwrap(snapshot["operations"]).contains(try XCTUnwrap(second["operation"])))
        capture(app, milestone: "retained completion and distinct fresh operation")
    }

    private func launchFixture(
        passiveSceneCensus: Bool = false,
        activeDownloadHome: Bool = false,
        delayedHandoffLock: Bool = false,
        automaticIngestion: Bool = false,
    ) throws -> XCUIApplication {
        let app = XCUIApplication(bundleIdentifier: "com.danielbyon.mediavault.browserdownloadqualificationhost")
        app.launchArguments = ["--browser-download-production-qualification"]
        if automaticIngestion {
            app.launchArguments += [
                "--browser-download-automatic-ingestion",
                "--browser-download-library",
                UUID().uuidString,
            ]
        }
        if passiveSceneCensus {
            app.launchArguments.append("--browser-download-passive-scene-census")
        }
        if activeDownloadHome {
            app.launchArguments.append("--browser-download-active-download-home")
        }
        if delayedHandoffLock {
            app.launchArguments.append("--browser-download-delayed-handoff-lock")
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
            let status = app.staticTexts["downloadQualificationLoopbackReadiness"]
            return status.exists && status.value as? String == "ready"
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

    /// Requires the pinned runtime native Share container and a populated typed action.
    private func nativeShareSurfaceIsPresent(_ app: XCUIApplication) -> Bool {
        let activity = app.descendants(matching: .any).matching(identifier: "ActivityListView").firstMatch
        let copy = activity.cells.matching(identifier: "Copy").firstMatch
        return activity.exists && copy.exists
    }

    /// An empty or still-populating Share container is not evidence of dismissal.
    private func nativeShareSurfaceIsAbsent(_ app: XCUIApplication) -> Bool {
        !app.descendants(matching: .any).matching(identifier: "ActivityListView").firstMatch.exists
            && !app.descendants(matching: .any).matching(identifier: "ShareSheet.RemoteContainerView").firstMatch.exists
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
        let result = XCTWaiter.wait(for: [expectation], timeout: 10)
        if let failure = waitFailureMessage(result, milestone: milestone) {
            capture(app, milestone: "FAILED \(milestone)")
            XCTFail(failure)
            throw FixtureError.waitFailed
        }
    }

    private func waitFailureMessage(_ result: XCTWaiter.Result, milestone: String) -> String? {
        switch result {
        case .completed:
            nil
        case .timedOut:
            "Timed out: \(milestone)"
        case .interrupted:
            "Interrupted by an enclosing waiter: \(milestone)"
        default:
            "Wait failed (result \(result.rawValue)): \(milestone)"
        }
    }

    private func capture(_ app: XCUIApplication, milestone: String) {
        let state = app.state
        let frame = state == .runningForeground ? app.frame : CGRect.null
        let coordinates = [frame.origin.x, frame.origin.y, frame.size.width, frame.size.height]
        let hasUsableFrame = !frame.isInfinite && coordinates.allSatisfy(\.isFinite)
            && frame.width > 0 && frame.height > 0
        // XCTest can lose the application frame while the process remains alive. Preserve the
        // original failure and accessibility evidence without requesting an unavailable screenshot.
        if state == .runningForeground, hasUsableFrame {
            let image = XCTAttachment(screenshot: app.screenshot())
            image.name = milestone
            image.lifetime = .keepAlways
            add(image)
        } else {
            let reason = state == .runningForeground
                ? "XCTest reported an empty, infinite, or non-finite application frame."
                : "Application was not running in the foreground."
            let diagnostic = XCTAttachment(string: "\(reason)\nApplication state: \(state.rawValue)\nFrame: \(frame)")
            diagnostic.name = "\(milestone) screenshot unavailable"
            diagnostic.lifetime = .keepAlways
            add(diagnostic)
        }
        let tree = XCTAttachment(string: app.debugDescription)
        tree.name = "\(milestone) accessibility tree"
        tree.lifetime = .keepAlways
        add(tree)
    }
}
