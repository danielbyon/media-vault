//
//  BrowserDownloadQualificationUITests.swift
//  MediaVault
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import CoreFoundation
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
    private enum FixtureError: Error { case waitFailed }
    private var passiveReader: BrowserDownloadPassiveReader?

    func testAcceptedPolicyHandoffAfterLockCompletesHiddenUntilFreshAuthentication() throws {
        let app = try launchFixture(passiveSceneCensus: true, delayedHandoffLock: true)
        defer { app.terminate() }
        try tapControl("downloadQualificationStartDelayedHandoff", in: app)
        var completion: Observation?
        try waitForPassiveObservation(
            app,
            milestone: "actual WebKit handoff after accepted-policy Lock and hidden native finish",
            expectedPhase: "locked",
        ) { observation in
            completion = SlowKnownWitnessContract.delayedHandoffEvidence(observation.events)
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

    func testOrdinaryPNGDownloadAutomaticallyCommitsCanonicalAsset() throws {
        let app = try launchFixture(automaticIngestion: true)
        defer { app.terminate() }
        let initial = try librarySnapshot(app, assetCount: 0, rowCount: 0)
        XCTAssertEqual(initial["temporaryCount"], "0")

        let imported = try libraryDownload(
            app,
            control: "downloadQualificationDownloadImage",
            route: "image",
            assetCount: 1,
            rowCount: 1,
        )
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
        try launchQualificationApplication(app)
        let relaunched = try librarySnapshot(app, assetCount: 1, rowCount: 0)
        XCTAssertEqual(relaunched["canonicalIDs"], imported["canonicalIDs"])
        XCTAssertEqual(relaunched["originalBytesMatch"], "true")
    }

    func testRepeatedPNGDownloadSkipsDuplicateAndRetainsCanonicalIdentity() throws {
        let app = try launchFixture(automaticIngestion: true)
        defer { app.terminate() }
        let first = try libraryDownload(
            app,
            control: "downloadQualificationDownloadImage",
            route: "image",
            assetCount: 1,
            rowCount: 1,
        )

        // The same PNG arrives with a PDF MIME type and filename on the second request.
        let duplicate = try libraryDownload(
            app,
            control: "downloadQualificationDownloadMislabelledImage",
            route: "image-as-pdf",
            assetCount: 1,
            rowCount: 2,
        )
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
        let excluded = try libraryDownload(
            app,
            control: "downloadQualificationDownloadMislabelledPDF",
            route: "pdf-as-image",
            assetCount: 0,
            rowCount: 1,
        )
        XCTAssertEqual(excluded["resourceCount"], "0")
        try openDownloads(app)
        XCTAssertTrue(app.buttons["Preview"].exists)
        XCTAssertTrue(app.buttons["Share"].exists)
        try closeDownloads(app)
        app.terminate()
        try launchQualificationApplication(app)
        _ = try librarySnapshot(app, assetCount: 0, rowCount: 0)
        try openDownloadSheet(app)
        let emptyDownloads = app.staticTexts["No Downloads"]
        try wait(app, milestone: "fresh process empty Downloads list") {
            emptyDownloads.exists && emptyDownloads.label == "No Downloads"
        }
        try closeDownloads(app)
        let pdf = try libraryDownload(
            app,
            control: "downloadQualificationDownloadAttachment",
            route: "attachment",
            assetCount: 0,
            rowCount: 1,
        )
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
        let baseline = try waitForPassiveObservation(
            app,
            milestone: "authenticated staging baseline",
            expectedPhase: "authenticated",
        ) { _ in true }
        try tapControl("downloadQualificationDownloadImageUnderLock", in: app)
        let accepted = try waitForPassiveObservation(
            app,
            milestone: "durably accepted PNG under app privacy Lock",
            expectedPhase: "locked",
        ) { sample in
            guard let operation = sample.finishedOperation(after: baseline, route: "image", locked: true),
                  let proof = try sample.library?.completedFields() else {
                return false
            }

            return proof["event"] == "acceptedLibraryStorage" && proof["operation"] == operation
                && proof["singleStagedFixture"] == "true" && proof["authenticated"] == "false" && proof[
                    "contentEmpty",
                ] ==
                "true"
        }
        XCTAssertFalse(app.buttons["Preview"].exists)
        XCTAssertFalse(app.buttons["Share"].exists)
        let hiddenEvents = try observations(app)
        let lockIndex = try XCTUnwrap(hiddenEvents.lastIndex { $0["event"] == "automaticMediaPolicyLocked" })
        let lockedEvents = hiddenEvents.suffix(from: lockIndex)
        XCTAssertTrue(lockedEvents.contains { $0["event"] == "writerFinished" })

        let durable = try XCTUnwrap(accepted.library?.fields)
        XCTAssertTrue(["canonicalIDs", "rowIDs", "assetCount", "temporaryBytes", "sha256"]
            .allSatisfy { durable[$0] == nil })
        let previousOperation = try XCTUnwrap(lockedEvents.last { $0["event"] == "writerFinished" }?["operation"])
        XCTAssertEqual(durable["singleStagedFixture"], "true")
        app.terminate()
        XCTAssertEqual(app.state, .notRunning)
        app.launchArguments += [
            "--browser-download-recovery-authentication",
            "--browser-download-expected-staged-operation",
            previousOperation,
        ]
        try launchQualificationApplication(app)
        let reopened = try lockedStartup(app)
        XCTAssertEqual(reopened["operation"], previousOperation)
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
        // Both reads must match the fixed fixture's exact size and single-operation bound.
        // Content identity is verified after authentication by the original hash assertions.
        XCTAssertEqual(reopened["singleStagedFixture"], "true")
        XCTAssertEqual(reopened["singleStagedFixture"], durable["singleStagedFixture"])
        XCTAssertEqual(reopened["authenticated"], "false")
        XCTAssertEqual(reopened["contentEmpty"], "true")
        XCTAssertTrue(["canonicalIDs", "rowIDs", "assetCount", "temporaryBytes", "sha256"]
            .allSatisfy { reopened[$0] == nil })
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
        let fresh = try libraryDownload(
            app,
            control: "downloadQualificationDownloadImage",
            route: "image",
            assetCount: 1,
            rowCount: 1,
        )
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
        try launchQualificationApplication(app)
        defer { app.terminate() }
        let locked = try lockedStartup(app)
        XCTAssertEqual(locked["authenticated"], "false")
        XCTAssertEqual(locked["stagingEmpty"], "true")
        XCTAssertEqual(locked["contentEmpty"], "true")
        XCTAssertTrue(app.staticTexts["downloadQualificationPassiveObservations"].exists)
        try authenticateLockedFixture(app)
        let authenticated = try librarySnapshot(app, assetCount: 0, rowCount: 0)
        XCTAssertEqual(authenticated["processID"], locked["processID"])
        XCTAssertTrue(app.staticTexts["downloadQualificationPassiveObservations"].exists)
        let events = try observations(app)
        XCTAssertFalse(events.contains { $0["event"] == "nativeDownloadHandoff" })
    }

    private func lockedStartup(_ app: XCUIApplication) throws -> Observation {
        let sample = try waitForPassiveObservation(
            app,
            milestone: "current locked Library startup",
            expectedPhase: "locked",
        ) {
            try $0.library?.completedFields()["event"] == "libraryStartup"
        }
        return try XCTUnwrap(sample.library?.fields)
    }

    private func libraryDownload(
        _ app: XCUIApplication,
        control: String,
        route: String,
        assetCount: Int,
        rowCount: Int,
    ) throws -> Observation {
        let baseline = try waitForPassiveObservation(
            app,
            milestone: "authenticated Library baseline",
            expectedPhase: "authenticated",
        ) { _ in true }
        try tapControl(control, in: app)
        return try librarySnapshot(app, assetCount: assetCount, rowCount: rowCount) { sample, fields in
            guard let operation = sample.finishedOperation(after: baseline, route: route) else {
                return false
            }

            return fields["rowIDs"]?.split(separator: ",").contains(Substring(operation)) == true
        }
    }

    private func librarySnapshot(
        _ app: XCUIApplication,
        assetCount: Int,
        rowCount: Int,
        matching: @escaping (BrowserDownloadPassiveObservation, Observation) -> Bool = { _, _ in true },
    ) throws -> Observation {
        let sample = try waitForPassiveObservation(
            app,
            milestone: "canonical asset and process-row counts",
            expectedPhase: "authenticated",
        ) { sample in
            guard let fields = try sample.library?.completedFields() else {
                return false
            }

            return fields["event"] == "canonicalLibrarySnapshot" && fields["assetCount"] == String(assetCount)
                && fields["rowCount"] == String(rowCount) && fields["settled"] == "true" && matching(sample, fields)
        }
        return try XCTUnwrap(sample.library?.fields)
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

        let events = try observations(normalApp)
        let bridge = try XCTUnwrap(events.last { $0["event"] == "mountedWebKitBridge" })
        XCTAssertEqual(bridge["adapterIdentity"], bridge["commandAdapterIdentity"])
        XCTAssertNotNil(bridge["tabID"])

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

    func testActiveWKDownloadHomeContinuesHiddenAndReconcilesAfterFreshAuthentication() throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Requires a physical device to qualify native WKDownload continuation across Home.")
        #endif

        let app = try launchFixture(passiveSceneCensus: true, activeDownloadHome: true)
        defer { app.terminate() }
        try tapControl("downloadQualificationStartFiniteContinuation", in: app)
        var witness: BrowserDownloadTransferWitness?
        try waitForPassiveObservation(app, milestone: "correlated live finite-response readiness") { sample in
            witness = SlowKnownWitnessContract.witness(from: sample.events)
            return witness != nil || sample.events.contains { $0["event"] == "slowKnownReadinessFailure" }
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
        try waitForPassiveObservation(
            app,
            milestone: "native finish with hidden retained completion",
            expectedPhase: "locked",
        ) { observation in
            SlowKnownWitnessContract.continuationEvidence(from: observation.events, for: selected) != nil
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
        XCTAssertFalse(app.staticTexts["downloadQualificationPassiveObservations"].exists)
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
            app.buttons["Equals"].isHittable
                && !app.buttons["Browser Menu"].exists
        }
        let lost = try observations(app)
        let authRevoked = try postRevocationEvidence(lost, for: second, after: beforeAuthenticationLoss)
        XCTAssertTrue(authRevoked.contains { $0["event"] == "fixtureAuthenticationLost" })
        XCTAssertFalse(authRevoked.contains {
            $0["event"] == "cleanupRemoval" && $0["operation"] == second["allocation"]
        })
        let hidden = try XCTUnwrap(lost.last { $0["event"] == "ownerSnapshot" })
        XCTAssertEqual(hidden["ownerContentEmpty"], "true")
        XCTAssertEqual(hidden["available"], "false")
        XCTAssertEqual(hidden["oneRetainedCompletion"], "true")
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

                let probeLabel = probe.label
                guard probeLabel == "Browser download transfer probe" else {
                    return false
                }

                let probeFrame = probe.frame
                guard !probeFrame.isEmpty else {
                    return false
                }

                let documentFrame = document.frame
                guard !documentFrame.isEmpty else {
                    return false
                }

                let previewFrame = preview.frame
                guard !previewFrame.isEmpty else {
                    return false
                }
                guard probeFrame.intersects(documentFrame) else {
                    return false
                }
                guard probeFrame.intersects(previewFrame) else {
                    return false
                }

                return probeFrame.intersects(app.frame)
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
        try launchQualificationApplication(app)
        XCTAssertTrue(app.staticTexts["downloadQualificationProtectionQualificationMode"].waitForExistence(timeout: 10))
        let modeLabel = app.staticTexts["downloadQualificationProtectionQualificationMode"].label
        #if targetEnvironment(simulator)
        XCTAssertTrue(modeLabel.contains("UNVERIFIED"))
        #else
        XCTAssertTrue(modeLabel.contains("Real native .complete verification required"))
        #endif
        try wait(app, milestone: "fixture server ready") {
            app.staticTexts["downloadQualificationLoopbackReadiness"].value as? String == "ready"
        }
        try tapControl("downloadQualificationOpenFixturePage", in: app)
        try waitForPassiveObservation(app, milestone: "root browser bridge registration") { observation in
            guard let mountedTabID = observation.mountedTabID else {
                return false
            }

            return observation.events.contains {
                $0["event"] == "mountedWebKitBridge"
                    && $0["adapterIdentity"] != nil
                    && $0["adapterIdentity"] == $0["commandAdapterIdentity"]
                    && $0["tabID"] == mountedTabID.uuidString
            }
        }
        return app
    }

    private func download(_ app: XCUIApplication) throws -> Observation {
        try wait(app, milestone: "real loopback readiness") {
            let status = app.staticTexts["downloadQualificationLoopbackReadiness"]
            return status.exists && status.value as? String == "ready"
        }
        let baseline = try waitForPassiveObservation(
            app,
            milestone: "authenticated attachment proof baseline",
            expectedPhase: "authenticated",
        ) { _ in true }
        try tapControl("downloadQualificationDownloadAttachment", in: app)
        var proof: Observation?
        try waitForPassiveObservation(
            app,
            milestone: "actual WebKit completed-file proof",
            expectedPhase: "authenticated",
        ) { observation in
            proof = observation.completedAttachment(after: baseline)
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
        let observation = try waitForPassiveObservation(app, milestone: "fresh qualification observations") { _ in
            true
        }
        return observation.events
    }

    /// A fresh launch token pins passive observations to this app process.
    private func launchQualificationApplication(_ app: XCUIApplication) throws {
        let nonce = UUID()
        let argument = BrowserDownloadObservationContext.launchNonceArgument
        var arguments = app.launchArguments
        while let index = arguments.firstIndex(of: argument) {
            arguments.removeSubrange(index ..< min(index + 2, arguments.count))
        }
        app.launchArguments = arguments + [argument, nonce.uuidString]
        passiveReader = BrowserDownloadPassiveReader(processNonce: nonce)
        app.launch()
    }

    private func readPassiveObservation(_ app: XCUIApplication) throws -> BrowserDownloadPassiveObservation {
        let node = app.staticTexts["downloadQualificationPassiveObservations"]
        guard node.exists else {
            throw BrowserDownloadObservationError.missing
        }

        return try BrowserDownloadPassiveObservation.decode(node.value as? String)
    }

    @discardableResult
    private func waitForPassiveObservation(
        _ app: XCUIApplication,
        milestone: String,
        expectedPhase: String? = nil,
        matching condition: @escaping @MainActor (BrowserDownloadPassiveObservation) throws -> Bool,
    ) throws -> BrowserDownloadPassiveObservation {
        let failures = testRun?.totalFailureCount
        do {
            let reader = try XCTUnwrap(passiveReader)
            return try reader.read(
                now: { ProcessInfo.processInfo.systemUptime },
                interrupted: { self.testRun?.totalFailureCount != failures },
                sample: { try self.readPassiveObservation(app) },
                matching: { sample in
                    guard expectedPhase == nil || expectedPhase == sample.context.phase else {
                        return false
                    }

                    return try condition(sample)
                },
            ) { interval, poll in
                let predicate = NSPredicate { _, _ in MainActor.assumeIsolated { poll() } }
                let expectation = XCTNSPredicateExpectation(predicate: predicate, object: nil)
                switch XCTWaiter.wait(for: [expectation], timeout: interval) {
                case .completed:
                    return .completed
                case .timedOut:
                    return .timedOut
                default:
                    return .interrupted
                }
            }
        } catch {
            capture(app, milestone: "FAILED \(milestone)")
            XCTFail("Passive observation failed: \(milestone): \(error)")
            throw error
        }
    }

    private func tapControl(
        _ identifier: String,
        in app: XCUIApplication,
    ) throws {
        let button = app.buttons[identifier]
        let strip = app.scrollViews["downloadQualificationControls"]
        // Scroll real controls into reach; this is not a synthesized lifecycle notification.
        if !button.isHittable, strip.buttons[identifier].exists {
            for _ in 0 ..< 3 where !button.isHittable {
                strip.swipeRight()
            }
            for _ in 0 ..< 3 where !button.isHittable {
                strip.swipeLeft()
            }
        }
        try tap(button, in: app)
    }

    private func tap(
        _ element: XCUIElement,
        in app: XCUIApplication,
    ) throws {
        try wait(app, milestone: "hittable \(element.identifier)") {
            element.exists && element.isHittable
        }
        element.tap()
    }

    private func wait(
        _ app: XCUIApplication,
        milestone: String,
        condition: @escaping @MainActor () -> Bool,
    ) throws {
        let predicate = NSPredicate { _, _ in MainActor.assumeIsolated { condition() } }
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: nil)
        let result = XCTWaiter.wait(
            for: [expectation],
            timeout: 10,
        )
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
