//
//  BrowserDownloadMultiSceneUITests.swift
//  MediaVault
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import CoreFoundation
import CoreGraphics
import Foundation
import XCTest
import XCUIAutomation

/// Confirms that the qualification host creates a new UIKit window-scene session.
/// Separate cases require real scene transitions, completed-source cleanup and system geometry changes.
@MainActor
final class BrowserDownloadMultiSceneUITests: XCTestCase {
    private typealias Observation = [String: String]

    private enum QualificationError: Error {
        case missingSceneCensus
        case missingObservation
        case waitFailed
        case invalidGeometry
    }

    private struct SceneCensus: Codable {
        let capturedMonotonicSeconds: String
        let distinctSessionIDs: Int
        let ownerGeneration: String
        let rootLayoutObservations: [Observation]
        let connectedWindowScenes: [WindowScene]
        let latestCoordinatorObservations: [Observation]
    }

    private struct WindowScene: Codable {
        let sessionID: String
        let activation: String
        let activationRawValue: String
        let bounds: String
    }

    private struct ControlScope {
        let window: XCUIElement
        let button: XCUIElement
    }

    func testRequestCreatesNewMountedWindowGroupScene() throws {
        let app = try launchFixture()
        defer { app.terminate() }

        let baseline = try freshBaselineCensus(in: app)
        let baselineSessionIDs = Set(baseline.connectedWindowScenes.map(\.sessionID))
        XCTAssertFalse(baselineSessionIDs.isEmpty, "The pre-request census must contain an actual connected scene.")
        attach(baseline, named: "pre-request connected-window-scene census")

        let request = try requestSecondScene(in: app)
        attach(request, named: "actual second-scene request event")
        let runID = try XCTUnwrap(request["runID"])
        let requestedAt = try XCTUnwrap(request["monotonicSeconds"].flatMap { Double($0) })
        let census = try freshCensusWithNewMountedScene(
            in: app,
            baselineSessionIDs: baselineSessionIDs,
            runID: runID,
            requestedAt: requestedAt,
        )

        try assertNewSceneEvidence(census, baselineSessionIDs: baselineSessionIDs, runID: runID)
        try assertRequestSucceeded(in: app, runID: runID)
        attach(census, named: "post-request connected-window-scene census")
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "actual system window arrangement after second-scene creation"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        for (name, tree) in [
            ("qualification app system-window controls", app.debugDescription),
            (
                "SpringBoard system-window controls",
                XCUIApplication(bundleIdentifier: "com.apple.springboard").debugDescription,
            ),
        ] {
            let attachment = XCTAttachment(string: tree)
            attachment.name = name
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }

    /// A real system-created scene backgrounds the original scene; shared downloads must revoke.
    func testSceneRequestRevokesCompletedDownloadAndKeepsActiveRootUsable() throws {
        let app = try launchFixture()
        defer { app.terminate() }
        let baseline = try freshBaselineCensus(in: app)
        XCTAssertEqual(baseline.connectedWindowScenes.count, 1, "This fixture requires a fresh single hosting scene.")
        let originalScene = try XCTUnwrap(baseline.connectedWindowScenes.first)
        XCTAssertEqual(originalScene.activation, "foregroundActive")
        let proof = try completedDownload(in: app)
        let request = try requestSecondScene(in: app)
        let runID = try XCTUnwrap(request["runID"])
        let requestedAt = try XCTUnwrap(request["monotonicSeconds"].flatMap { Double($0) })
        let census = try freshCensusWithNewMountedScene(
            in: app,
            baselineSessionIDs: [originalScene.sessionID],
            runID: runID,
            requestedAt: requestedAt,
        )
        try assertNewSceneEvidence(census, baselineSessionIDs: [originalScene.sessionID], runID: runID)
        XCTAssertEqual(
            census.connectedWindowScenes.first { $0.sessionID == originalScene.sessionID }?.activation,
            "background",
        )
        let activeScene = try XCTUnwrap(census.connectedWindowScenes.first {
            $0.sessionID != originalScene.sessionID && $0.activation == "foregroundActive"
        })
        var postRequest: [Observation] = []
        try wait(app, milestone: "global revocation and safe active-scene Root") {
            guard let events = try? self.observations(app) else {
                return false
            }

            postRequest = events.filter {
                $0["runID"] == runID && ($0["monotonicSeconds"].flatMap { Double($0) } ?? -1) > requestedAt
            }
            let removed = postRequest.contains {
                $0["event"] == "cleanupRemoval" && $0["operation"] == proof["allocation"] && $0["absence"] == "true"
            }
            let denied = postRequest.last { $0["event"] == "ownerSnapshot" }.map {
                $0["available"] == "false" && $0["operations"] == "" && $0["active"] == "0" && $0["retained"] == "0"
            } ?? false
            let safeRoot = postRequest.contains {
                $0["sceneSession"] == activeScene.sessionID && $0["rootProof"] == "true"
                    && $0["coverVisible"] == "false" && $0["nativeBarrier"] == "false"
            }
            return removed && denied && safeRoot
        }
        attach(postRequest, named: "actual A-background B-active revocation and source absence")
        try wait(app, milestone: "active B fixture navigation control") {
            self.hittableButton("downloadQualificationOpenFixturePage", in: app) != nil
        }
        try XCTUnwrap(hittableButton("downloadQualificationOpenFixturePage", in: app)).tap()
        try assertFreshNavigation(in: app, runID: runID)
        try assertReactivation(
            in: app,
            originalSceneID: originalScene.sessionID,
            runID: runID,
            oldOperation: proof["operation"],
        )
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "safe active Root after global download revocation"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    /// Uses SpringBoard's actual window resize handle; no UIKit frame is assigned by the fixture.
    func testSystemResizeChangesActualSceneGeometry() throws {
        let app = try launchFixture()
        defer { app.terminate() }
        let baseline = try freshBaselineCensus(in: app)
        let request = try requestSecondScene(in: app)
        let runID = try XCTUnwrap(request["runID"])
        let requestedAt = try XCTUnwrap(request["monotonicSeconds"].flatMap { Double($0) })
        let before = try freshCensusWithNewMountedScene(
            in: app,
            baselineSessionIDs: Set(baseline.connectedWindowScenes.map(\.sessionID)),
            runID: runID,
            requestedAt: requestedAt,
        )
        let active = try XCTUnwrap(before.connectedWindowScenes.first { $0.activation == "foregroundActive" })
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let cardID = "card:com.danielbyon.mediavault.browserdownloadqualificationhost:sceneID:"
            + "com.danielbyon.mediavault.browserdownloadqualificationhost-" + active.sessionID
        // The exact scene-card identifier exceeds XCUI's shorthand string-query limit.
        let card = springboard.otherElements.matching(NSPredicate(format: "identifier == %@", cardID)).element
        let grabber = card.otherElements["resize-grabber"]
        try wait(app, milestone: "actual active-scene system resize handle") { grabber.exists && grabber.isHittable }
        let grabberFrame = grabber.frame
        let applicationFrame = app.frame
        let visible = grabberFrame.intersection(applicationFrame)
        let frames = [grabberFrame, applicationFrame, visible]
        guard frames.allSatisfy({ frame in
            !frame.isNull && !frame.isEmpty
                && [frame.minX, frame.minY, frame.width, frame.height].allSatisfy(\.isFinite)
        }) else {
            attach(
                ["grabber": String(describing: grabberFrame), "application": String(describing: applicationFrame)],
                named: "invalid system resize geometry; no gesture performed",
            )
            XCTFail("Resize geometry must have a finite, nonempty visible intersection.")
            throw QualificationError.invalidGeometry
        }

        attach(before, named: "actual scene geometry before system resize")
        try XCTUnwrap(hittableButton("downloadQualificationMarkResizeGesture", in: app)).tap()
        let marker = try XCTUnwrap(try observations(app)
            .last { $0["event"] == "resizeGestureWillBegin" && $0["runID"] == runID })
        guard marker["sceneSession"] == active.sessionID else {
            XCTFail("The gesture marker must identify the actual active scene.")
            throw QualificationError.invalidGeometry
        }

        let gestureStart = try XCTUnwrap(marker["monotonicSeconds"].flatMap { Double($0) })
        attach(marker, named: "same-clock actual resize gesture boundary")
        attach([
            "grabber": String(describing: grabberFrame),
            "application": String(describing: applicationFrame),
            "visible": String(describing: visible),
        ], named: "captured system gesture frames")
        let start = grabber.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(
            dx: visible.midX - grabberFrame.minX,
            dy: visible.midY - grabberFrame.minY,
        ))
        let destination = start.withOffset(CGVector(dx: -applicationFrame.width / 4, dy: -applicationFrame.height / 4))
        start.press(forDuration: 0.2, thenDragTo: destination)
        let after = try refreshCensus(
            in: app,
            newerThan: gestureStart,
            milestone: "real resized scene and safe Root layout",
        ) {
            guard let scene = $0.connectedWindowScenes.first(where: { $0.sessionID == active.sessionID }),
                  scene.activation == "foregroundActive", scene.bounds != active.bounds
            else {
                return false
            }

            let generation = $0.ownerGeneration
            return $0.rootLayoutObservations.contains {
                $0["event"] == "rootLayoutConfirmed" && $0["runID"] == runID && $0["sceneSession"] == scene.sessionID
                    && $0["generation"] == generation && $0["sceneBounds"] == scene.bounds
                    && ($0["monotonicSeconds"].flatMap { Double($0) } ?? -1) > gestureStart
                    && $0["rootProof"] == "true" && $0["nativeBarrier"] == "false" && $0["coverVisible"] == "false"
            }
        }
        attach(after, named: "actual resized scene geometry and production Root layout")
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "actual system-resized qualification window"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    private func assertFreshNavigation(in app: XCUIApplication, runID: String) throws {
        let requested = try XCTUnwrap(try observations(app).last {
            $0["runID"] == runID && $0["event"] == "fixtureNavigationRequested" && $0["fixtureRoute"] == "first"
        })
        let token = try XCTUnwrap(requested["fixtureRequest"])
        try wait(app, milestone: "fresh B committed metadata and actual ready document") {
            (try? self.observations(app))?.contains {
                $0["runID"] == runID && $0["event"] == "fixtureNavigationCommitted" && $0["fixtureRequest"] == token
                    && $0["metadataMatches"] == "true" && $0["documentMatches"] == "true" && $0["readyState"] == "complete"
            } == true
        }
    }

    private func assertReactivation(
        in app: XCUIApplication,
        originalSceneID: String,
        runID: String,
        oldOperation: String?,
    ) throws {
        try XCTUnwrap(hittableButton("downloadQualificationReactivateBackgroundScene", in: app)).tap()
        let requested = try XCTUnwrap(try observations(app).last {
            $0["runID"] == runID && $0["event"] == "sceneReactivationRequested"
        })
        XCTAssertEqual(requested["requestedSession"], originalSceneID)
        XCTAssertEqual(requested["priorActivation"], "background")
        let requestedAt = try XCTUnwrap(requested["monotonicSeconds"].flatMap { Double($0) })
        let census = try refreshCensus(
            in: app,
            newerThan: requestedAt,
            milestone: "actual original scene reactivated",
        ) {
            $0.connectedWindowScenes.contains { $0.sessionID == originalSceneID && $0.activation == "foregroundActive" }
                && $0.latestCoordinatorObservations.contains {
                    $0["runID"] == runID && $0["sceneSession"] == originalSceneID && $0["rootProof"] == "true"
                        && $0["coverVisible"] == "false" && $0["nativeBarrier"] == "false"
                        && ($0["monotonicSeconds"].flatMap { Double($0) } ?? -1) > requestedAt
                }
        }
        attach(census, named: "actual original session reactivation with safe Root")
        let events = try observations(app)
        XCTAssertFalse(events.contains { $0["runID"] == runID && $0["event"] == "sceneReactivationFailed" })
        let owner = try XCTUnwrap(events.last { $0["runID"] == runID && $0["event"] == "ownerSnapshot" })
        XCTAssertGreaterThan(try XCTUnwrap(owner["monotonicSeconds"].flatMap { Double($0) }), requestedAt)
        XCTAssertEqual(owner["operations"], "")
        XCTAssertEqual(owner["active"], "0")
        XCTAssertEqual(owner["retained"], "0")
        XCTAssertEqual(owner["available"], "false", "The other background registration still denies admission.")
        XCTAssertNotEqual(owner["operations"], oldOperation)
    }

    private func completedDownload(in app: XCUIApplication) throws -> Observation {
        try wait(app, milestone: "loopback readiness before scene request") {
            app.staticTexts["Loopback ready. Open fixture page, then download attachment PDF."].exists
        }
        try XCTUnwrap(hittableButton("downloadQualificationDownloadAttachment", in: app)).tap()
        var proof: Observation?
        try wait(app, milestone: "originating WebKit completed PDF before scene request") {
            proof = (try? self.observations(app))?.last { $0["event"] == "completedFileProof" }
            return proof != nil
        }
        let completed = try XCTUnwrap(proof)
        XCTAssertEqual(completed["bytes"], "16777827")
        XCTAssertEqual(completed["sha256"], "8816500369189a8354a2fa88a75f9550efeae8a45b447525d862eb45ddbe02df")
        XCTAssertEqual(completed["backupExcluded"], "true")
        XCTAssertEqual(completed["nativeProtection"], "UNVERIFIED")
        XCTAssertEqual(completed["protectionMode"], "simulatedReadback")
        attach(completed, named: "completed file before actual system scene request")
        return completed
    }

    private func freshBaselineCensus(in app: XCUIApplication) throws -> SceneCensus {
        try wait(app, milestone: "initial UIKit scene census") { self.sceneCensus(app) != nil }
        let initial = try XCTUnwrap(sceneCensus(app))
        let initialCapture = try XCTUnwrap(Double(initial.capturedMonotonicSeconds))
        return try refreshCensus(in: app, newerThan: initialCapture, milestone: "fresh pre-request scene census") {
            !$0.connectedWindowScenes.isEmpty
        }
    }

    private func requestSecondScene(in app: XCUIApplication) throws -> Observation {
        try wait(app, milestone: "second-scene request control") {
            self.hittableButton("downloadQualificationRequestSecondScene", in: app) != nil
        }
        try XCTUnwrap(hittableButton("downloadQualificationRequestSecondScene", in: app)).tap()

        let events = try observations(app)
        XCTAssertTrue(events.contains { $0["event"] == "sceneRequested" })
        XCTAssertFalse(events.contains {
            $0["event"] == "sceneRequestUnsupported" || $0["event"] == "sceneRequestFailed"
        })
        return try XCTUnwrap(events.last { $0["event"] == "sceneRequested" })
    }

    private func freshCensusWithNewMountedScene(
        in app: XCUIApplication,
        baselineSessionIDs: Set<String>,
        runID: String,
        requestedAt: Double,
    ) throws -> SceneCensus {
        try refreshCensus(in: app, newerThan: requestedAt, milestone: "new mounted session after scene request") {
            self.hasNewMountedScene($0, baselineSessionIDs: baselineSessionIDs, runID: runID)
        }
    }

    private func refreshCensus(
        in app: XCUIApplication,
        newerThan minimumCapture: Double,
        milestone: String,
        condition: @escaping @MainActor (SceneCensus) -> Bool,
    ) throws -> SceneCensus {
        var result: SceneCensus?
        var attempts: [Observation] = []
        do {
            try wait(app, milestone: milestone) {
                guard let scope = self.hittableScope("downloadQualificationRefreshSceneCensus", in: app) else {
                    return false
                }

                scope.button.tap()
                let raw = scope.window.staticTexts["downloadQualificationSceneCensus"].value as? String
                attempts.append([
                    "windowFrame": String(describing: scope.window.frame),
                    "buttonFrame": String(describing: scope.button.frame),
                    "buttonHittable": String(scope.button.isHittable),
                    "census": raw ?? "missingValue",
                ])
                guard let raw, let census = try? JSONDecoder().decode(SceneCensus.self, from: Data(raw.utf8)),
                      let capturedAt = Double(census.capturedMonotonicSeconds), capturedAt > minimumCapture,
                      condition(census)
                else {
                    return false
                }

                result = census
                return true
            }
        } catch {
            attach(attempts, named: "all failed census captures with paired refresh window: " + milestone)
            throw error
        }

        return try XCTUnwrap(result)
    }

    private func assertNewSceneEvidence(
        _ census: SceneCensus,
        baselineSessionIDs: Set<String>,
        runID: String,
    ) throws {
        let sessionIDs = census.connectedWindowScenes.map(\.sessionID)
        let distinctSessionIDs = Set(sessionIDs)
        XCTAssertEqual(census.distinctSessionIDs, distinctSessionIDs.count)
        XCTAssertEqual(sessionIDs.count, distinctSessionIDs.count, "The current census must not duplicate session IDs.")
        XCTAssertGreaterThanOrEqual(distinctSessionIDs.count, 2)

        let newSessionIDs = distinctSessionIDs.subtracting(baselineSessionIDs)
        XCTAssertFalse(newSessionIDs.isEmpty, "The request must create a session absent from the pre-request census.")
        let validActivationStates = ["foregroundActive", "foregroundInactive", "background", "unattached"]
        for scene in census.connectedWindowScenes {
            XCTAssertTrue(validActivationStates.contains(scene.activation))
            XCTAssertNotNil(Int(scene.activationRawValue))
        }
        XCTAssertTrue(census.connectedWindowScenes.contains { $0.activation == "foregroundActive" })

        for sessionID in newSessionIDs {
            let registration = try XCTUnwrap(census.latestCoordinatorObservations.last {
                $0["runID"] == runID
                    && $0["registration"]?.isEmpty == false
                    && $0["sceneSession"] == sessionID
                    && $0["mounted"] == "true"
            }, "Missing same-run mounted coordinator registration for new scene \(sessionID)")
            XCTAssertNotNil(registration["generation"].flatMap { UInt64($0) })
            XCTAssertNotNil(registration["nativeLifecycle"])
            XCTAssertNotNil(registration["nativeBarrier"])
        }
    }

    private func hasNewMountedScene(
        _ census: SceneCensus,
        baselineSessionIDs: Set<String>,
        runID: String,
    ) -> Bool {
        let sessionIDs = census.connectedWindowScenes.map(\.sessionID)
        let distinctSessionIDs = Set(sessionIDs)
        guard distinctSessionIDs.count >= 2,
              sessionIDs.count == distinctSessionIDs.count,
              distinctSessionIDs.count == census.distinctSessionIDs
        else {
            return false
        }

        let newSessionIDs = distinctSessionIDs.subtracting(baselineSessionIDs)
        return !newSessionIDs.isEmpty && newSessionIDs.allSatisfy { sessionID in
            census.latestCoordinatorObservations.contains {
                $0["runID"] == runID
                    && $0["registration"]?.isEmpty == false
                    && $0["sceneSession"] == sessionID
                    && $0["mounted"] == "true"
            }
        }
    }

    private func assertRequestSucceeded(in app: XCUIApplication, runID: String) throws {
        let events = try observations(app)
        XCTAssertTrue(events.contains { $0["runID"] == runID && $0["event"] == "sceneRequested" })
        XCTAssertFalse(events.contains {
            $0["runID"] == runID
                && ($0["event"] == "sceneRequestUnsupported" || $0["event"] == "sceneRequestFailed")
        })
    }

    private func launchFixture() throws -> XCUIApplication {
        let app = XCUIApplication(bundleIdentifier: "com.danielbyon.mediavault.browserdownloadqualificationhost")
        app.launchArguments = [
            "--browser-download-production-qualification",
            "--browser-download-simulated-protection-readback",
        ]
        app.launch()
        XCTAssertTrue(app.staticTexts["downloadQualificationProtectionQualificationMode"].firstMatch.waitForExistence(timeout: 10))
        try wait(app, milestone: "initial scene browser bridge registration") {
            guard let scope = self.hittableScope("downloadQualificationRefreshSceneCensus", in: app) else {
                return false
            }

            scope.button.tap()
            guard let value = scope.window.staticTexts["downloadQualificationSceneCensus"].value as? String,
                  let census = try? JSONDecoder().decode(SceneCensus.self, from: Data(value.utf8))
            else {
                return false
            }

            let connectedSessions = Set(census.connectedWindowScenes.map(\.sessionID))
            return census.latestCoordinatorObservations.contains {
                $0["registration"]?.isEmpty == false && $0["mounted"] == "true"
                    && $0["sceneSession"].map(connectedSessions.contains) == true
            }
        }
        XCTAssertTrue(app.staticTexts["downloadQualificationSceneCensus"].firstMatch.waitForExistence(timeout: 10))
        return app
    }

    private func sceneCensus(_ app: XCUIApplication) -> SceneCensus? {
        guard let scope = hittableScope("downloadQualificationRefreshSceneCensus", in: app),
              let value = scope.window.staticTexts["downloadQualificationSceneCensus"].value as? String
        else {
            return nil
        }

        return try? JSONDecoder().decode(SceneCensus.self, from: Data(value.utf8))
    }

    private func observations(_ app: XCUIApplication) throws -> [Observation] {
        try wait(app, milestone: "qualification observation refresh control") {
            self.hittableScope("downloadQualificationRefreshObservations", in: app) != nil
        }
        let scope = try XCTUnwrap(hittableScope("downloadQualificationRefreshObservations", in: app))
        scope.button.tap()
        guard let value = scope.window.staticTexts["downloadQualificationObservations"].value as? String else {
            throw QualificationError.missingObservation
        }

        return try JSONDecoder().decode([Observation].self, from: Data(value.utf8))
    }

    /// A refresh and its value must belong to the same reachable window, even with duplicate IDs.
    private func hittableScope(_ identifier: String, in app: XCUIApplication) -> ControlScope? {
        for window in app.windows.allElementsBoundByIndex where window.exists && window.isHittable {
            if let button = window.buttons.matching(identifier: identifier).allElementsBoundByIndex.first(where: {
                $0.exists && $0.isEnabled && $0.isHittable
            }) {
                return ControlScope(window: window, button: button)
            }
        }
        return nil
    }

    private func hittableButton(_ identifier: String, in app: XCUIApplication) -> XCUIElement? {
        hittableScope(identifier, in: app)?.button
    }

    private func attachControlDiagnostics(_ app: XCUIApplication) {
        let identifiers = [
            "downloadQualificationRequestSecondScene",
            "downloadQualificationRefreshSceneCensus",
            "downloadQualificationRefreshObservations",
        ]
        let controls = identifiers.flatMap { identifier in
            app.buttons.matching(identifier: identifier).allElementsBoundByIndex.map {
                "\(identifier): exists=\($0.exists) hittable=\($0.isHittable) frame=\($0.frame)"
            }
        }
        .joined(separator: "\n")
        let attachment = XCTAttachment(string: controls + "\n" + app.debugDescription)
        attachment.name = "all matching qualification controls and application accessibility tree"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func attach(_ value: some Encodable, named name: String) {
        guard let data = try? JSONEncoder().encode(value),
              let text = String(data: data, encoding: .utf8)
        else {
            XCTFail("Unable to encode the qualified scene census attachment.")
            return
        }

        let attachment = XCTAttachment(string: text)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func wait(
        _ app: XCUIApplication,
        milestone: String,
        condition: @escaping @MainActor () -> Bool,
    ) throws {
        let predicate = NSPredicate { _, _ in MainActor.assumeIsolated { condition() } }
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: nil)
        guard XCTWaiter.wait(for: [expectation], timeout: 10) == .completed else {
            let attachment = XCTAttachment(screenshot: app.screenshot())
            attachment.name = "failed qualification: \(milestone)"
            attachment.lifetime = .keepAlways
            add(attachment)
            attachControlDiagnostics(app)
            XCTFail("Timed out: \(milestone)")
            throw QualificationError.waitFailed
        }
    }
}
