//
//  BrowserDownloadSecurityQualificationUITests.swift
//  MediaVault
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import XCTest
import XCUIAutomation

/// Physical-device security qualification for the standalone Debug download qualification host.
///
/// The app under test is com.danielbyon.mediavault.browserdownloadqualificationhost, launched by
/// the --browser-download-production-qualification argument. That host runs the real production
/// download path (originating WKWebView through WKDownload into the operation-owned scratch
/// store) and exposes redacted observations: opaque operation identifiers, booleans, counts,
/// stages, and error classifications only. This suite never asserts or records request URLs,
/// filenames, or downloaded content.
///
/// These tests exercise behaviors a simulator cannot qualify:
///
/// 1. Abrupt termination and cold relaunch (Slice A). One completed production download leaves a
///    single opaque, UUID-named allocation under the transient scratch root. Terminating the
///    process and relaunching it without reinstalling must remove that leftover during startup
///    cleanup, restore no records or presentation actions, and still complete a fresh download.
///    Removal is only claimed when the relaunched host reported the allocation as still present
///    when startup cleanup inspected the scratch root; an allocation that was already absent, or
///    no usable correlation report at all, ends the run as INCONCLUSIVE cleanup attribution
///    instead of passing.
/// 2. Locked protected data (Slice B). A dedicated sentinel file created with
///    NSFileProtectionComplete must deny fresh reads while the physical device is locked, and
///    become readable again after the operator unlocks it. The sentinel accepts one qualification
///    cycle per process: a preparation that arrives after the first cycle has begun is refused,
///    and another cycle requires relaunching the host.
///
/// Helper drivers intentionally duplicate BrowserDownloadQualificationUITests instead of
/// sharing a base class: the two suites pin different fixture contracts against the same
/// qualification host. That suite accepts the simulator-only simulated protection readback,
/// while this suite always requires the real native .complete path and never launches the host
/// in a readback mode. Keeping the drivers local lets either suite tighten or re-pin its fixture
/// expectations without silently changing what the other suite qualifies.
@MainActor
final class BrowserDownloadSecurityQualificationUITests: XCTestCase {
    private typealias Observation = [String: String]
    private enum FixtureError: Error { case missingObservation, waitFailed }

    // MARK: - Qualification guards

    /// These security qualifications require physical hardware: a simulator cannot reproduce real
    /// protected-data unavailability or establish physical-device provenance for the termination
    /// and relaunch sequence, so simulator runs skip these cases instead of failing them.
    private func requirePhysicalDevice() throws {
        #if targetEnvironment(simulator)
        let isSimulator = true
        #else
        let isSimulator = ProcessInfo.processInfo.environment["SIMULATOR_UDID"] != nil
            || ProcessInfo.processInfo.environment["SIMULATOR_DEVICE_NAME"] != nil
        #endif
        guard !isSimulator else {
            throw XCTSkip("Requires a physical device: simulator cannot qualify these behaviors")
        }
    }

    /// The manual lock test performs a real device lock and unlock cycle, so it runs only when
    /// the operator explicitly opts in; an absent opt-in skips instead of failing. For a
    /// command-line run, pass TEST_RUNNER_BROWSER_DOWNLOAD_LOCK_QUALIFICATION=1 to xcodebuild so
    /// the test runner environment receives BROWSER_DOWNLOAD_LOCK_QUALIFICATION=1.
    private func requireLockQualificationOptIn() throws {
        guard ProcessInfo.processInfo.environment["BROWSER_DOWNLOAD_LOCK_QUALIFICATION"] == "1" else {
            throw XCTSkip(
                "Manual lock qualification requires the BROWSER_DOWNLOAD_LOCK_QUALIFICATION=1 operator opt-in",
            )
        }
    }

    // MARK: - Slice A: abrupt termination and cold relaunch

    /// Completes one real WebKit production download, proves the identical opaque allocation is
    /// still verified immediately before an abrupt foreground termination, cold-relaunches the
    /// app, and requires zero restored records, no stale Preview/Share actions, a safe Root, and a
    /// fresh successful production download.
    ///
    /// Cleanup attribution is classified from the host's `expectedPresent` report through the
    /// shared contract. Only an explicit "true" report, meaning the previous allocation was still
    /// present when startup cleanup inspected the scratch root, lets the run pass together with
    /// the strict removal-ordering assertions. An explicit "false" report (the allocation was
    /// already absent before cleanup ran) and a missing or unrecognized report both keep every
    /// non-restoration assertion in this test and end the run with XCTSkip reporting INCONCLUSIVE
    /// cleanup attribution; the two cases are described separately because they state different
    /// host observations.
    func testColdRelaunchPurgesPreviousCompletedAllocationAndStartsClean() throws {
        try requirePhysicalDevice()
        let app = try launchFixture()
        let first = try download(app)
        let allocation = try XCTUnwrap(first["allocation"])
        let firstRunID = try XCTUnwrap(first["runID"])

        // The identical allocation must still be a verified, authorized completed file
        // immediately before termination: this is the object the relaunched process must purge.
        try tapControl("downloadQualificationCheckPendingAllocation", in: app)
        let preTermination = try observations(app)
        let check = try XCTUnwrap(preTermination.last { $0["event"] == "pendingAllocationPreTerminationCheck" })
        XCTAssertEqual(check["present"], "true")
        XCTAssertEqual(check["verified"], "true")
        XCTAssertEqual(check["operation"], allocation)
        XCTAssertEqual(check["runID"], firstRunID)
        capture(app, milestone: "verified scratch allocation immediately before abrupt termination")

        // Abrupt termination from the foreground; the process itself must reach .notRunning.
        XCTAssertEqual(app.state, .runningForeground)
        app.terminate()
        try waitForNotRunning(app, milestone: "abruptly terminated qualification process")

        // Cold relaunch without reinstall or container clear. Startup purge and its pre-removal
        // observation run during process initialization, before the owner admits any transfer.
        app.launch()
        try awaitHost(app)

        let coldEvents = try observations(app)
        let secondRunID = try XCTUnwrap(coldEvents.first { $0["event"] == "fixtureStarted" }?["runID"])
        XCTAssertNotEqual(secondRunID, firstRunID, "Cold relaunch must be a distinct process")

        let inspection = try XCTUnwrap(
            coldEvents.last { $0["event"] == "scratchStartupPurgeInspection" && $0["runID"] == secondRunID },
            "The host must install its startup-purge observation before scratch cleanup runs",
        )
        XCTAssertEqual(inspection["entryNamesParseUUID"], "true")

        // A concrete persisted operation must equal the allocation verified before termination.
        // Missing or unavailable correlation cannot make that equality assertion, so it is
        // INCONCLUSIVE; all non-restoration and fresh-download checks still run before XCTSkip.
        let startupInspection = BrowserDownloadStartupInspectionClassification(
            expectedOperation: inspection["expectedOperation"],
            expectedPresent: inspection["expectedPresent"],
        )
        var inconclusiveCleanupAttribution: BrowserDownloadCleanupInconclusiveReason?
        switch startupInspection {
        case let .correlated(expectedOperation, cleanupAttribution):
            XCTAssertEqual(
                expectedOperation,
                allocation,
                "The relaunched host must correlate the previous allocation through its own defaults",
            )
            switch cleanupAttribution {
            case .verifiedRemoval:
                XCTAssertGreaterThanOrEqual(Int(inspection["preExistingCount"] ?? "") ?? 0, 1)
                let removal = try XCTUnwrap(
                    coldEvents.last {
                        $0["event"] == "cleanupRemoval" && $0["operation"] == allocation
                            && $0["absence"] == "true" && $0["runID"] == secondRunID
                    },
                    "Post-cleanup absence of the previous allocation was not observed",
                )
                XCTAssertLessThanOrEqual(
                    try XCTUnwrap(Double(inspection["monotonicSeconds"] ?? "")),
                    try XCTUnwrap(Double(removal["monotonicSeconds"] ?? "")),
                    "The pre-removal inspection must precede the recorded absence",
                )
                capture(app, milestone: "previous allocation present before removal, absent after")
            case let .inconclusive(reason):
                inconclusiveCleanupAttribution = reason
            }
        case let .inconclusive(reason):
            // The host did not provide a usable persisted-operation correlation. The prior
            // allocation may or may not have existed when startup cleanup ran: non-restoration is
            // still successful, but this run cannot attribute removal to startup cleanup.
            inconclusiveCleanupAttribution = reason
        }

        if let reason = inconclusiveCleanupAttribution {
            let note = XCTAttachment(string: """
            Cleanup attribution INCONCLUSIVE: \(reason.qualificationDescription).
            Non-restoration behavior below is still qualified, but this run cannot claim that
            startup cleanup removed the allocation.
            """)
            note.name = "Cleanup attribution INCONCLUSIVE"
            note.lifetime = .keepAlways
            add(note)
        }

        // A freshly launched process must restore nothing and present no stale download actions.
        let snapshot = try XCTUnwrap(coldEvents.last { $0["event"] == "ownerSnapshot" && $0["runID"] == secondRunID })
        XCTAssertEqual(snapshot["operations"], "")
        XCTAssertEqual(snapshot["presentation"], "none")
        XCTAssertEqual(snapshot["available"], "true")
        XCTAssertEqual(snapshot["cleanupRetry"], "false")
        XCTAssertEqual(snapshot["retained"], "0")
        XCTAssertTrue(app.buttons["Browser Menu"].isHittable)
        try openDownloadsWithoutCompletedActions(app)
        capture(app, milestone: "cold relaunch with zero restored records and safe Root")

        // The freshly relaunched process must still complete a full production download.
        try openFixturePage(app)
        let second = try download(app)
        XCTAssertNotEqual(second["operation"], first["operation"])
        XCTAssertEqual(second["allocation"], second["operation"])
        capture(app, milestone: "fresh production download after cold relaunch")

        // Every non-restoration and fresh-download assertion above ran before this final
        // decision, so a defect in restored records, stale UI, Root safety, or the fresh download
        // still fails the run. Only the cleanup attribution itself is reported INCONCLUSIVE.
        if let reason = inconclusiveCleanupAttribution {
            throw XCTSkip(
                "INCONCLUSIVE: startup cleanup removal of the previous allocation cannot be claimed "
                    + "because " + reason.qualificationDescription + ".",
            )
        }
    }

    // MARK: - Slice B: locked protected data

    /// Prepares the protected-data sentinel, waits for the operator to lock and unlock the
    /// physical device, and then requires, in order: a real protected-data-unavailable trigger
    /// while the device was locked; denial of a fresh sentinel open attributable to file
    /// protection at that moment; and a fresh successful read after unlock with the sentinel
    /// removed and verified absent. A decoded no-attempt observation caused by suspension or
    /// operator-window expiry is INCONCLUSIVE, while an unreadable or undecodable observation
    /// surface at the terminal deadline is a test failure.
    func testProtectedDataSentinelDeniesFreshReadsWhileLockedAndRecoversAfterUnlock() throws {
        try requirePhysicalDevice()
        try requireLockQualificationOptIn()
        let app = try launchFixture()
        try tapControl("downloadQualificationPrepareSecuritySentinel", in: app)
        let preparedEvents = try observations(app)
        let prepared = try XCTUnwrap(preparedEvents.last { $0["event"] == "securitySentinelPrepared" })
        XCTAssertEqual(prepared["probePrepared"], "true")
        XCTAssertEqual(prepared["protectionAttribute"], "complete")
        XCTAssertEqual(prepared["backupExcluded"], "true")
        XCTAssertEqual(prepared["unlockedReadSucceeded"], "true")
        XCTAssertEqual(prepared["observersRegistered"], "true")
        XCTAssertEqual(prepared["backgroundAssertionArmed"], "true")
        capture(app, milestone: "security sentinel prepared with observers and assertion armed")
        // Fail fast before the operator window: a sentinel that did not arm every field cannot
        // qualify the locked read, so the run ends here instead of waiting for a manual lock.
        let expectedPreparedFields = [
            "probePrepared": "true",
            "protectionAttribute": "complete",
            "backupExcluded": "true",
            "unlockedReadSucceeded": "true",
            "observersRegistered": "true",
            "backgroundAssertionArmed": "true",
        ]
        let unpreparedFields = expectedPreparedFields
            .filter { prepared[$0.key] != $0.value }
            .keys
            .sorted()
        guard unpreparedFields.isEmpty else {
            throw XCTSkip("Sentinel did not arm cleanly: " + unpreparedFields.joined(separator: ","))
        }

        // Operator lock window: the test runner can be suspended while the device is locked, so
        // the loop polls a non-failing probe that returns nil instead of recording a failure while
        // the host surface is unreachable. The driver never activates or launches the host inside
        // this window: the system denies foreground requests while the device is actually locked,
        // and XCTest records such a denial as a hard failure that would end the run before the
        // operator unlocks. Restoring the host to the foreground after unlock is the operator's
        // step in the documented procedure; once the host is reachable the probe resumes. The
        // loop ends on recovery, terminal cleanup failure, decoded no-attempt evidence, or the
        // bounded deadline. A decoded no-attempt remains INCONCLUSIVE, while an unreadable or
        // undecodable surface at the terminal deadline is a test-harness failure.
        var terminalOutcome = BrowserDownloadLockedQualificationObservationOutcome(observations: [])
        let deadline = Date().addingTimeInterval(1_800)
        while Date() < deadline, terminalOutcome == .waiting {
            if let latest = probeObservations(app) {
                terminalOutcome = BrowserDownloadLockedQualificationObservationOutcome(observations: latest)
            }
            if terminalOutcome == .waiting {
                Thread.sleep(forTimeInterval: 5)
            }
        }
        if terminalOutcome == .waiting {
            terminalOutcome = BrowserDownloadLockedQualificationObservationOutcome(
                observations: probeObservations(app),
            )
        }

        let recovery: Observation
        switch terminalOutcome {
        case .observationSurfaceUnreadable:
            let note = XCTAttachment(string: """
            Locked-protected-data test harness could not read or decode the observation surface
            at the terminal deadline. No qualification result can be classified from this run.
            """)
            note.name = "locked protected data observation harness failure"
            note.lifetime = .keepAlways
            add(note)
            XCTFail("Observation surface remained unreadable or undecodable at the terminal deadline")
            return
        case let .recovered(observation):
            recovery = observation
        case let .inconclusiveNoAttempt(evidence):
            let note = XCTAttachment(string: """
            Locked-protected-data INCONCLUSIVE: \(evidence.reason ?? "unknownReason").
            freshOpenAttempted=\(evidence.freshOpenAttempted ?? "missing")
            The host recorded that execution stopped before a locked fresh read.
            """)
            note.name = "locked protected data INCONCLUSIVE"
            note.lifetime = .keepAlways
            add(note)
            throw XCTSkip("INCONCLUSIVE: no locked fresh-read attempt was recorded")
        case let .terminalCleanupFailed(evidence):
            let note = XCTAttachment(string: """
            Locked-protected-data qualification failed because terminal marker cleanup failed.
            stage=\(evidence.stage ?? "missing")
            markerRemoved=\(evidence.markerRemoved ?? "missing")
            relaunchRequired=\(evidence.relaunchRequired ?? "missing")
            """)
            note.name = "locked protected data terminal cleanup failure"
            note.lifetime = .keepAlways
            add(note)
            XCTFail("Terminal sentinel cleanup failed; relaunch is required")
            return
        case .waiting:
            let note = XCTAttachment(string: """
            Locked-protected-data INCONCLUSIVE: no unlock recovery observation appeared within the
            operator window, so the locked denial cannot be qualified in this run.
            """)
            note.name = "locked protected data INCONCLUSIVE"
            note.lifetime = .keepAlways
            add(note)
            throw XCTSkip("INCONCLUSIVE: operator lock window did not complete")
        }

        capture(app, milestone: "unlocked recovery observed")
        XCTAssertEqual(recovery["protectedDataAvailable"], "true")
        XCTAssertEqual(recovery["freshAccessSucceeded"], "true")
        XCTAssertEqual(recovery["sentinelRemoved"], "true")
        XCTAssertEqual(recovery["sentinelAbsent"], "true")

        let latestEvents = try observations(app)
        guard let attempt = latestEvents.last(where: { $0["event"] == "securitySentinelLockedAttempt" }) else {
            let note = XCTAttachment(string: """
            Locked-protected-data INCONCLUSIVE: the host reported unlock recovery without a
            locked fresh-read attempt observation, so this run cannot attribute a denial to file
            protection.
            """)
            note.name = "locked protected data INCONCLUSIVE"
            note.lifetime = .keepAlways
            add(note)
            throw XCTSkip("INCONCLUSIVE: no locked fresh-read attempt was recorded")
        }

        if attempt["freshOpenAttempted"] != "true" {
            let note = XCTAttachment(string: """
            Locked-protected-data INCONCLUSIVE: \(attempt["inconclusiveReason"] ?? "unknownReason").
            The host never performed a fresh sentinel read while protected data was unavailable,
            so this run cannot attribute a denial to file protection.
            """)
            note.name = "locked protected data INCONCLUSIVE"
            note.lifetime = .keepAlways
            add(note)
            throw XCTSkip("INCONCLUSIVE: no locked fresh-read attempt was recorded")
        }
        XCTAssertEqual(
            attempt["protectedDataUnavailable"],
            "true",
            "Every locked fresh read must require isProtectedDataAvailable == false first",
        )
        XCTAssertEqual(attempt["denied"], "true", "A completed locked fresh read must be denied")
        XCTAssertEqual(attempt["denialClass"], "fileProtection")
    }

    // MARK: - Qualification fixtures and drivers

    /// Launches the standalone qualification host and drives it to the mounted fixture page.
    private func launchFixture() throws -> XCUIApplication {
        let app = XCUIApplication(bundleIdentifier: "com.danielbyon.mediavault.browserdownloadqualificationhost")
        app.launchArguments = ["--browser-download-production-qualification"]
        app.launch()
        try awaitHost(app)
        try openFixturePage(app)
        return app
    }

    /// Waits for the qualification host's readiness surface after any cold launch.
    private func awaitHost(_ app: XCUIApplication) throws {
        XCTAssertTrue(app.staticTexts["downloadQualificationProtectionQualificationMode"].waitForExistence(timeout: 10))
        let modeLabel = app.staticTexts["downloadQualificationProtectionQualificationMode"].label
        XCTAssertTrue(modeLabel.contains("Real native .complete verification required"))
        try wait(app, milestone: "fixture server ready") {
            app.staticTexts["Loopback ready. Open fixture page, then download attachment PDF."].exists
        }
    }

    /// Opens the fixture page and requires real bridge registration before downloads are driven.
    private func openFixturePage(_ app: XCUIApplication) throws {
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
    }

    /// Opens the production Downloads sheet and requires the empty, action-free restored state.
    private func openDownloadsWithoutCompletedActions(_ app: XCUIApplication) throws {
        try tap(app.buttons["Browser Menu"], in: app)
        try tap(app.buttons["Downloads"], in: app)
        try wait(app, milestone: "empty restored Downloads sheet") {
            app.navigationBars["Downloads"].exists && app.staticTexts["No Downloads"].exists
                && !app.buttons["Preview"].exists && !app.buttons["Share"].exists
        }
        capture(app, milestone: "cold relaunch Downloads sheet without restored actions")
        try tap(app.buttons["Done"], in: app)
        try wait(app, milestone: "safe Browser surface") { app.buttons["Browser Menu"].isHittable }
    }

    /// Drives one real production download and returns its completed-file proof.
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
        // current fixture identity is pinned here; fixtureBytesMatch verifies the served bytes
        // byte-for-byte against the fixture.
        XCTAssertEqual(result["bytes"], "608")
        XCTAssertEqual(result["sha256"], "852ba89aa0d708405217efd9cc3d014f4a1cc48ed1895748a1e1d9540f97bd79")
        XCTAssertEqual(result["backupExcluded"], "true")
        XCTAssertEqual(result["fixtureBytesMatch"], "true")
        XCTAssertEqual(result["nativeProtection"], "verified")
        XCTAssertEqual(result["protectionMode"], "nativeCompleteRequired")
        XCTAssertTrue(try observations(app).contains {
            $0["event"] == "nativeDownloadHandoff" && $0["sameOrigin"] == "true"
        })
        return result
    }

    private func observations(_ app: XCUIApplication) throws -> [Observation] {
        try tapControl("downloadQualificationRefreshObservations", in: app)
        let node = app.staticTexts["downloadQualificationObservations"]
        guard let value = node.value as? String else {
            throw FixtureError.missingObservation
        }

        let attachment = XCTAttachment(string: value)
        attachment.name = "actual security qualification observations"
        attachment.lifetime = .keepAlways
        add(attachment)
        return try JSONDecoder().decode([Observation].self, from: Data(value.utf8))
    }

    /// Non-failing observation probe for the operator lock window. Locking the device can cost
    /// the runner its accessibility snapshot at any moment, so this probe returns nil instead of
    /// recording a failure while the host surface is unreachable. The caller retries until its
    /// bounded deadline, where a still-unreadable or undecodable surface is a harness failure.
    private func probeObservations(_ app: XCUIApplication) -> [Observation]? {
        let refresh = app.buttons["downloadQualificationRefreshObservations"]
        guard refresh.waitForExistence(timeout: 2), refresh.exists, refresh.isHittable else {
            return nil
        }

        refresh.tap()
        let node = app.staticTexts["downloadQualificationObservations"]
        guard node.exists, let value = node.value as? String,
              let events = try? JSONDecoder().decode([Observation].self, from: Data(value.utf8))
        else {
            return nil
        }

        let attachment = XCTAttachment(string: value)
        attachment.name = "actual security qualification observations"
        attachment.lifetime = .keepAlways
        add(attachment)
        return events
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

    /// Boundedly requires the app's own process state to reach .notRunning after termination.
    private func waitForNotRunning(_ app: XCUIApplication, milestone: String) throws {
        let predicate = NSPredicate { _, _ in MainActor.assumeIsolated { app.state == .notRunning } }
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: nil)
        guard XCTWaiter.wait(for: [expectation], timeout: 15) == .completed else {
            capture(app, milestone: "FAILED \(milestone)")
            XCTFail("Timed out: \(milestone)")
            throw FixtureError.waitFailed
        }
    }

    private func wait(
        _ app: XCUIApplication,
        milestone: String,
        timeout: TimeInterval = 10,
        condition: @escaping @MainActor () -> Bool,
    ) throws {
        let predicate = NSPredicate { _, _ in MainActor.assumeIsolated { condition() } }
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: nil)
        guard XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed else {
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
