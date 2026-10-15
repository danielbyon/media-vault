//
//  Issue42ProductionQualificationUITests.swift
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
final class Issue42ProductionQualificationUITests: XCTestCase {
    private typealias Observation = [String: String]
    private enum FixtureError: Error { case missingObservation, waitFailed }

    func testQuickLookHomeRevokesAndFreshDownloadRecovers() throws {
        try qualifyHomeInterruption(action: "Preview")
    }

    func testShareHomeRevokesAndFreshDownloadRecovers() throws {
        try qualifyHomeInterruption(action: "Share")
    }

    func testActiveDiscardFailureRetryAndAuthenticationLoss() throws {
        let app = try launchFixture()
        defer { app.terminate() }
        let first = try download(app)
        try tapControl("issue42ArmRemovalFailure", in: app)
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
        try tapControl("issue42OpenFixturePage", in: app)
        let second = try download(app)
        XCTAssertNotEqual(first["operation"], second["operation"])
        let beforeAuthenticationLoss = Date()
        try tapControl("issue42RemoveAuthentication", in: app)
        try wait(app, milestone: "safe unauthenticated Root usable") {
            app.buttons["issue42RefreshObservations"].isHittable
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
            let probe = document.staticTexts["Issue 42 transfer probe"]
            // A presented Quick Look shell can precede PDF rendering. Require the document's
            // actual semantic text and visible geometry within the native container before Home.
            try wait(app, milestone: "rendered native PDF probe text") {
                guard preview.exists, document.exists, probe.exists,
                      app.buttons["QLOverlayDoneButtonAccessibilityIdentifier"].exists
                else {
                    return false
                }

                return probe.label == "Issue 42 transfer probe" && !probe.frame.isEmpty
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
        capture(XCUIApplication(bundleIdentifier: "com.apple.springboard"), milestone: "real system Home")
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

    private func launchFixture() throws -> XCUIApplication {
        let app = XCUIApplication(bundleIdentifier: "com.danielbyon.mediavault.issue42qualificationhost")
        app.launchArguments = ["--issue42-production-download-qualification"]
        #if targetEnvironment(simulator)
        app.launchArguments.append("--issue42-simulated-protection-readback")
        #endif
        app.launch()
        XCTAssertTrue(app.staticTexts["issue42ProtectionQualificationMode"].waitForExistence(timeout: 10))
        let modeLabel = app.staticTexts["issue42ProtectionQualificationMode"].label
        #if targetEnvironment(simulator)
        XCTAssertTrue(modeLabel.contains("UNVERIFIED"))
        #else
        XCTAssertTrue(modeLabel.contains("Real native .complete verification required"))
        #endif
        try wait(app, milestone: "fixture server ready") {
            app.staticTexts["Loopback ready. Open fixture page, then download attachment PDF."].exists
        }
        try tapControl("issue42OpenFixturePage", in: app)
        try wait(app, milestone: "root browser bridge registration") {
            let refresh = app.buttons["issue42RefreshObservations"]
            guard refresh.exists, refresh.isHittable else {
                return false
            }

            refresh.tap()
            guard let value = app.staticTexts["issue42QualificationObservations"].value as? String,
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
        try tapControl("issue42DownloadAttachment", in: app)
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
        XCTAssertEqual(result["bytes"], "16777827")
        XCTAssertEqual(result["sha256"], "8816500369189a8354a2fa88a75f9550efeae8a45b447525d862eb45ddbe02df")
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
        try tapControl("issue42RefreshObservations", in: app)
        let node = app.staticTexts["issue42QualificationObservations"]
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
        let strip = app.scrollViews["issue42QualificationControls"]
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
