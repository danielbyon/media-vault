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

    private enum DiagnosticReadError: Error {
        case unavailable
    }

    private struct SceneCensus: Codable {
        let capturedMonotonicSeconds: String
        let distinctSessionIDs: Int
        let rootLayoutObservations: [Observation]
        let connectedWindowScenes: [WindowScene]
        let latestCoordinatorObservations: [Observation]
    }

    /// One connected UIKit window scene as recorded by the qualification host census.
    private struct WindowScene: Codable {
        let sessionID: String
        let activation: String
        let activationRawValue: String
        let bounds: String
        let screenBounds: String
        let windows: [SceneWindow]
    }

    /// Geometry of one UIWindow attached to a connected scene, exactly as the host recorded it.
    /// `hidden` and `alpha` describe on-screen visibility, and `rootViewBounds` is the loaded
    /// root view's bounds, or the host's `"unloaded"` placeholder before the view is loaded.
    private struct SceneWindow: Codable {
        let frame: String
        let bounds: String
        let hidden: String
        let alpha: String
        let key: String
        let isCover: String
        let rootViewBounds: String
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

    func testResizeHandleNormalizesMeasuredRotatedFrame() throws {
        let container = CGRect(x: 0, y: 0, width: 1_133, height: 744)
        let screen = CGRect(x: 0, y: 0, width: 1_133, height: 744)
        let reported = CGRect(x: -20, y: 1_113, width: 40, height: 40)

        let normalized = try XCTUnwrap(
            normalizedResizeHandleFrame(reported: reported, container: container, screenBounds: screen),
        )
        XCTAssertEqual(normalized, CGRect(x: 1_113, y: 724, width: 40, height: 40))
        XCTAssertEqual(
            normalized.intersection(container),
            CGRect(x: 1_113, y: 724, width: 20, height: 20),
        )

        let direct = CGRect(x: 1_100, y: 700, width: 40, height: 40)
        XCTAssertEqual(
            normalizedResizeHandleFrame(reported: direct, container: container, screenBounds: screen),
            direct,
            "A directly intersecting frame must remain unchanged.",
        )
    }

    func testResizeHandleRejectsUnrelatedOffscreenFrame() {
        let container = CGRect(x: 0, y: 0, width: 1_133, height: 744)
        let unrelated = CGRect(x: 500, y: 1_000, width: 40, height: 40)

        XCTAssertNil(normalizedResizeHandleFrame(
            reported: unrelated,
            container: container,
            screenBounds: container,
        ))
    }

    func testResizeHandleUsesScreenSpaceOriginWithOffsetCard() {
        let application = CGRect(x: 0, y: 0, width: 577, height: 494)
        let screen = CGRect(x: 0, y: 0, width: 1_133, height: 744)
        let card = CGRect(x: 278, y: 127, width: 577, height: 494)
        let grabber = CGRect(x: 835, y: 601, width: 40, height: 40)

        XCTAssertNil(normalizedResizeHandleFrame(
            reported: grabber,
            container: application,
            screenBounds: screen,
        ))
        XCTAssertEqual(
            normalizedResizeHandleFrame(reported: grabber, container: card, screenBounds: screen),
            grabber,
        )
        let visible = grabber.intersection(card)
        XCTAssertEqual(visible, CGRect(x: 835, y: 601, width: 20, height: 20))
        XCTAssertEqual(CGPoint(x: visible.midX, y: visible.midY), CGPoint(x: 845, y: 611))

        let rotated = CGRect(x: 103, y: 835, width: 40, height: 40)
        XCTAssertEqual(
            normalizedResizeHandleFrame(reported: rotated, container: card, screenBounds: screen),
            CGRect(x: 835, y: 601, width: 40, height: 40),
        )
        XCTAssertNil(normalizedResizeHandleFrame(
            reported: CGRect(x: -20, y: 557, width: 40, height: 40),
            container: card,
            screenBounds: screen,
        ))
    }

    func testResizeGestureDeltaMovesOutwardPerAvailableAxis() throws {
        let card = CGRect(x: 379, y: 127, width: 375, height: 494)
        let screen = CGRect(x: 0, y: 0, width: 1_133, height: 744)
        let start = CGPoint(x: 744, y: 611)

        let delta = try XCTUnwrap(
            resizeGestureDelta(from: start, container: card, screenBounds: screen),
        )

        XCTAssertEqual(delta.dx, 93.75, accuracy: 0.0001)
        XCTAssertEqual(delta.dy, -123.5, accuracy: 0.0001)
    }

    func testResizeGestureDeltaShrinksFullScreenCardOnBothAxes() throws {
        let screen = CGRect(x: 0, y: 0, width: 1_133, height: 744)
        let start = CGPoint(x: 1_120, y: 720)

        let delta = try XCTUnwrap(
            resizeGestureDelta(from: start, container: screen, screenBounds: screen),
        )

        XCTAssertLessThan(delta.dx, 0)
        XCTAssertLessThan(delta.dy, 0)
    }

    func testResizeWindowSelectionAllowsVisibleNonKeyedAuxiliaryWindow() {
        let scene = WindowScene(
            sessionID: "SCENE",
            activation: "foregroundActive",
            activationRawValue: "0",
            bounds: "(0.0, 0.0, 577.0, 494.0)",
            screenBounds: "(0.0, 0.0, 1133.0, 744.0)",
            windows: [
                sceneWindow(key: "true", isCover: "false"),
                sceneWindow(key: "false", isCover: "false"),
            ],
        )

        XCTAssertEqual(selectedVisibleKeyedSceneWindow(in: scene)?.key, "true")
    }

    func testResizeWindowSelectionRejectsVisibleCover() {
        let scene = WindowScene(
            sessionID: "SCENE",
            activation: "foregroundActive",
            activationRawValue: "0",
            bounds: "(0.0, 0.0, 577.0, 494.0)",
            screenBounds: "(0.0, 0.0, 1133.0, 744.0)",
            windows: [
                sceneWindow(key: "false", isCover: "true"),
                sceneWindow(key: "true", isCover: "false"),
            ],
        )

        XCTAssertNil(selectedVisibleKeyedSceneWindow(in: scene))
    }

    func testResizeWindowSelectionRejectsZeroOrMultipleVisibleKeyedWindows() {
        let noKeyed = WindowScene(
            sessionID: "SCENE",
            activation: "foregroundActive",
            activationRawValue: "0",
            bounds: "(0.0, 0.0, 577.0, 494.0)",
            screenBounds: "(0.0, 0.0, 1133.0, 744.0)",
            windows: [
                sceneWindow(key: "true", isCover: "false", hidden: "true"),
                sceneWindow(key: "false", isCover: "false"),
            ],
        )
        XCTAssertNil(selectedVisibleKeyedSceneWindow(in: noKeyed))

        let multipleKeyed = WindowScene(
            sessionID: "SCENE",
            activation: "foregroundActive",
            activationRawValue: "0",
            bounds: "(0.0, 0.0, 577.0, 494.0)",
            screenBounds: "(0.0, 0.0, 1133.0, 744.0)",
            windows: [
                sceneWindow(key: "true", isCover: "false"),
                sceneWindow(key: "true", isCover: "false"),
            ],
        )
        XCTAssertNil(selectedVisibleKeyedSceneWindow(in: multipleKeyed))
    }

    func testResizeSceneRequiresUniqueNewActiveSession() {
        let baseline: Set = ["OLD"]
        let old = WindowScene(
            sessionID: "OLD",
            activation: "foregroundActive",
            activationRawValue: "0",
            bounds: "(0.0, 0.0, 1_133.0, 744.0)",
            screenBounds: "(0.0, 0.0, 1133.0, 744.0)",
            windows: [sceneWindow(key: "true", isCover: "false")],
        )
        let new = WindowScene(
            sessionID: "NEW",
            activation: "foregroundActive",
            activationRawValue: "0",
            bounds: "(0.0, 0.0, 577.0, 494.0)",
            screenBounds: "(0.0, 0.0, 1133.0, 744.0)",
            windows: [sceneWindow(key: "true", isCover: "false")],
        )
        let mountedNew: Observation = [
            "runID": "RUN",
            "registration": "NEW-REGISTRATION",
            "sceneSession": "NEW",
            "mounted": "true",
        ]

        XCTAssertEqual(
            uniqueNewActiveScene(
                census([old, new], observations: [mountedNew]),
                baselineSessionIDs: baseline,
                runID: "RUN",
            )?.sessionID,
            "NEW",
        )

        let secondNew = WindowScene(
            sessionID: "NEW-2",
            activation: "background",
            activationRawValue: "2",
            bounds: "(0.0, 0.0, 577.0, 494.0)",
            screenBounds: "(0.0, 0.0, 1133.0, 744.0)",
            windows: [sceneWindow(key: "true", isCover: "false")],
        )
        XCTAssertNil(uniqueNewActiveScene(
            census([old, new, secondNew], observations: [mountedNew]),
            baselineSessionIDs: baseline,
            runID: "RUN",
        ))

        let duplicateNew = WindowScene(
            sessionID: "NEW",
            activation: "foregroundActive",
            activationRawValue: "0",
            bounds: "(0.0, 0.0, 577.0, 494.0)",
            screenBounds: "(0.0, 0.0, 1133.0, 744.0)",
            windows: [sceneWindow(key: "true", isCover: "false")],
        )
        XCTAssertNil(uniqueNewActiveScene(
            census([old, new, duplicateNew], observations: [mountedNew]),
            baselineSessionIDs: baseline,
            runID: "RUN",
        ))

        let newBackground = WindowScene(
            sessionID: "NEW",
            activation: "background",
            activationRawValue: "2",
            bounds: "(0.0, 0.0, 577.0, 494.0)",
            screenBounds: "(0.0, 0.0, 1133.0, 744.0)",
            windows: [sceneWindow(key: "true", isCover: "false")],
        )
        XCTAssertNil(uniqueNewActiveScene(
            census([old, newBackground], observations: [mountedNew]),
            baselineSessionIDs: baseline,
            runID: "RUN",
        ))
    }

    func testResizeTimeoutDiagnosticsReadOptionalValuesIndependently() {
        var attempted: [String] = []
        let unavailable = diagnosticValue {
            attempted.append("grabberFrame")
            throw DiagnosticReadError.unavailable
        }
        let available = diagnosticValue {
            attempted.append("cardExists")
            return "true"
        }

        XCTAssertEqual(unavailable, "unavailable")
        XCTAssertEqual(available, "true")
        XCTAssertEqual(attempted, ["grabberFrame", "cardExists"])
    }

    func testResizeGestureMarkerSelectsExactNewSceneRegistrationAndRun() {
        let observations: [Observation] = [
            [
                "event": "resizeGestureWillBegin",
                "runID": "RUN",
                "sceneSession": "OLD",
                "registration": "OLD-REGISTRATION",
            ],
            [
                "event": "resizeGestureWillBegin",
                "runID": "RUN",
                "sceneSession": "NEW",
                "registration": "NEW-REGISTRATION",
            ],
            [
                "event": "resizeGestureWillBegin",
                "runID": "WRONG-RUN",
                "sceneSession": "NEW",
                "registration": "NEW-REGISTRATION",
            ],
        ]

        XCTAssertEqual(
            resizeGestureMarker(
                in: observations,
                sceneID: "NEW",
                registration: "NEW-REGISTRATION",
                runID: "RUN",
            )?["runID"],
            "RUN",
        )
        XCTAssertNil(resizeGestureMarker(
            in: observations,
            sceneID: "NEW",
            registration: "NEW-REGISTRATION",
            runID: "MISSING-RUN",
        ))
    }

    func testResizeWindowWitnessAcceptsMarkerOnlyLatestObservation() {
        let matching = sceneWindow(key: "true", isCover: "false")
        let marker: Observation = [
            "event": "resizeGestureWillBegin",
            "sceneSession": "SCENE",
            "runID": "RUN",
        ]

        XCTAssertNil(
            resizedSceneWitnessFailure(
                resizeCensus(window: matching, latestObservation: marker),
                activeSceneID: "SCENE",
                baselineBounds: "(0.0, 0.0, 1133.0, 744.0)",
            ),
        )
    }

    func testResizeWindowWitnessRejectsCoverInCurrentCensus() {
        let matching = sceneWindow(key: "true", isCover: "false")
        let baselineBounds = "(0.0, 0.0, 1133.0, 744.0)"
        let expectedFailure = "the scene does not have exactly one visible keyed non-cover window"

        XCTAssertEqual(
            resizedSceneWitnessFailure(
                resizeCensus(
                    window: matching,
                    auxiliaryWindow: sceneWindow(key: "false", isCover: "true"),
                ),
                activeSceneID: "SCENE",
                baselineBounds: baselineBounds,
            ),
            expectedFailure,
        )
        XCTAssertEqual(
            resizedSceneWitnessFailure(
                resizeCensus(window: sceneWindow(key: "true", isCover: "true")),
                activeSceneID: "SCENE",
                baselineBounds: baselineBounds,
            ),
            expectedFailure,
        )
    }

    func testResizeWindowWitnessPreservesSelectedWindowGeometryAndPrivacy() {
        let matching = sceneWindow(key: "true", isCover: "false")
        XCTAssertNil(
            resizedSceneWitnessFailure(
                resizeCensus(window: matching),
                activeSceneID: "SCENE",
                baselineBounds: "(0.0, 0.0, 1133.0, 744.0)",
            ),
        )

        let frameMismatch = sceneWindow(
            key: "true",
            isCover: "false",
            frame: "(0.0, 0.0, 500.0, 494.0)",
        )
        XCTAssertEqual(
            resizedSceneWitnessFailure(
                resizeCensus(window: frameMismatch),
                activeSceneID: "SCENE",
                baselineBounds: "(0.0, 0.0, 1133.0, 744.0)",
            ),
            "the attached window frame does not match the resized scene bounds",
        )

        let boundsMismatch = sceneWindow(
            key: "true",
            isCover: "false",
            bounds: "(0.0, 0.0, 500.0, 494.0)",
        )
        XCTAssertEqual(
            resizedSceneWitnessFailure(
                resizeCensus(window: boundsMismatch),
                activeSceneID: "SCENE",
                baselineBounds: "(0.0, 0.0, 1133.0, 744.0)",
            ),
            "the attached window bounds do not match the resized scene bounds",
        )

        let rootMismatch = sceneWindow(
            key: "true",
            isCover: "false",
            rootViewBounds: "(0.0, 0.0, 500.0, 494.0)",
        )
        XCTAssertEqual(
            resizedSceneWitnessFailure(
                resizeCensus(window: rootMismatch),
                activeSceneID: "SCENE",
                baselineBounds: "(0.0, 0.0, 1133.0, 744.0)",
            ),
            "the loaded root view bounds do not match the resized scene bounds",
        )
    }

    /// Uses SpringBoard's actual window resize handle; no UIKit frame is assigned by the fixture.
    func testSystemResizeChangesActualSceneGeometry() throws {
        let app = try launchFixture()
        defer { app.terminate() }
        let baseline = try freshBaselineCensus(in: app)
        let request = try requestSecondScene(in: app)
        let runID = try XCTUnwrap(request["runID"])
        let requestedAt = try XCTUnwrap(request["monotonicSeconds"].flatMap { Double($0) })
        let baselineSessionIDs = Set(baseline.connectedWindowScenes.map(\.sessionID))
        let before = try freshCensusWithNewMountedScene(
            in: app,
            baselineSessionIDs: baselineSessionIDs,
            runID: runID,
            requestedAt: requestedAt,
            requiringActiveSceneSafeRoot: true,
        )
        // Historical pre-gesture evidence: the census wait above requires the host's safe Root
        // layout confirmation for the active scene, so the gesture cannot begin before it exists.
        // A real system resize does not change the SwiftUI render token that governs those
        // confirmations, so the host emits no second confirmation for the new bounds; the
        // post-gesture witness below verifies the resize from scene and window geometry instead.
        let active = try XCTUnwrap(
            uniqueNewActiveScene(before, baselineSessionIDs: baselineSessionIDs, runID: runID),
            "The resize precondition requires exactly one active, mounted scene created by the request.",
        )
        let (_, preResizeRoot) = try XCTUnwrap(
            activeSceneSafeRoot(in: before, for: active.sessionID, runID: runID),
            "The new scene must have a confirmed safe Root layout before the resize gesture.",
        )
        attach(preResizeRoot, named: "historical pre-resize Root layout confirmation")
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let cardID = "card:com.danielbyon.mediavault.browserdownloadqualificationhost:sceneID:"
            + "com.danielbyon.mediavault.browserdownloadqualificationhost-" + active.sessionID
        // The exact scene-card identifier exceeds XCUI's shorthand string-query limit.
        let card = springboard.otherElements.matching(NSPredicate(format: "identifier == %@", cardID)).element
        let grabber = card.otherElements["resize-grabber"]
        do {
            try wait(app, milestone: "actual active-scene system resize handle") {
                grabber.exists && grabber.isHittable
            }
        } catch {
            if let census = sceneCensus(app) {
                attach(census, named: "resize handle timeout active-scene census")
            } else {
                attach(
                    ["available": "false"],
                    named: "resize handle timeout active-scene census unavailable",
                )
            }
            attach(
                ["description": diagnosticValue { app.debugDescription }],
                named: "resize handle timeout application accessibility evidence",
            )
            attach(
                ["description": diagnosticValue { springboard.debugDescription }],
                named: "resize handle timeout SpringBoard accessibility evidence",
            )
            attach(
                [
                    "cardExists": diagnosticValue { String(card.exists) },
                    "cardHittable": diagnosticValue { String(card.isHittable) },
                    "grabberExists": diagnosticValue { String(grabber.exists) },
                    "grabberHittable": diagnosticValue { String(grabber.isHittable) },
                    "grabberFrame": diagnosticValue { String(describing: grabber.frame) },
                ],
                named: "resize handle timeout accessibility evidence",
            )
            throw error
        }
        let reportedGrabberFrame = grabber.frame
        let cardFrame = card.frame
        let applicationFrame = app.frame
        guard let screenBounds = parsedRect(active.screenBounds) else {
            attach(
                ["screenBounds": active.screenBounds, "sceneBounds": active.bounds],
                named: "unparseable screen coordinates; no gesture performed",
            )
            XCTFail("The active scene's screen bounds must be parseable.")
            throw QualificationError.invalidGeometry
        }
        guard let grabberFrame = normalizedResizeHandleFrame(
            reported: reportedGrabberFrame,
            container: cardFrame,
            screenBounds: screenBounds,
        ) else {
            attach(
                [
                    "reportedGrabber": String(describing: reportedGrabberFrame),
                    "cardContainer": String(describing: cardFrame),
                    "application": String(describing: applicationFrame),
                ],
                named: "invalid system resize geometry; no gesture performed",
            )
            XCTFail("Resize geometry must have a finite, nonempty visible intersection.")
            throw QualificationError.invalidGeometry
        }

        let visible = grabberFrame.intersection(cardFrame)
        let frames = [grabberFrame, cardFrame, visible]
        guard frames.allSatisfy({ frame in
            !frame.isNull && !frame.isEmpty
                && [frame.minX, frame.minY, frame.width, frame.height].allSatisfy(\.isFinite)
        }) else {
            attach(
                [
                    "reportedGrabber": String(describing: reportedGrabberFrame),
                    "normalizedGrabber": String(describing: grabberFrame),
                    "cardContainer": String(describing: cardFrame),
                    "application": String(describing: applicationFrame),
                ],
                named: "invalid system resize geometry; no gesture performed",
            )
            XCTFail("Resize geometry must have a finite, nonempty visible intersection.")
            throw QualificationError.invalidGeometry
        }

        attach(before, named: "actual scene geometry before system resize")
        try XCTUnwrap(hittableButton("downloadQualificationMarkResizeGesture", in: app)).tap()
        let registration = try XCTUnwrap(preResizeRoot["registration"])
        try wait(app, milestone: "resize boundary for unique active new scene") {
            self.resizeGestureMarker(
                in: (try? self.observations(app)) ?? [],
                sceneID: active.sessionID,
                registration: registration,
                runID: runID,
            ) != nil
        }
        let currentObservations = try observations(app)
        let marker = try XCTUnwrap(resizeGestureMarker(
            in: currentObservations,
            sceneID: active.sessionID,
            registration: registration,
            runID: runID,
        ))
        guard marker["sceneSession"] == active.sessionID else {
            XCTFail("The gesture marker must identify the actual active scene.")
            throw QualificationError.invalidGeometry
        }

        let gestureStart = try XCTUnwrap(marker["monotonicSeconds"].flatMap { Double($0) })
        attach(marker, named: "same-clock actual resize gesture boundary")
        attach([
            "reportedGrabber": String(describing: reportedGrabberFrame),
            "normalizedGrabber": String(describing: grabberFrame),
            "cardContainer": String(describing: cardFrame),
            "application": String(describing: applicationFrame),
            "visible": String(describing: visible),
        ], named: "captured system gesture frames")
        let start = card.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(
            dx: visible.midX - cardFrame.minX,
            dy: visible.midY - cardFrame.minY,
        ))
        let delta = try XCTUnwrap(
            resizeGestureDelta(
                from: CGPoint(x: visible.midX, y: visible.midY),
                container: cardFrame,
                screenBounds: screenBounds,
            ),
        )
        let destination = start.withOffset(delta)
        start.press(forDuration: 0.2, thenDragTo: destination)
        var witnessFailure: String?
        let after: SceneCensus
        do {
            after = try refreshCensus(
                in: app,
                newerThan: gestureStart,
                milestone: "real resized scene geometry and usable qualification controls",
            ) {
                witnessFailure = self.resizedSceneWitnessFailure(
                    $0,
                    activeSceneID: active.sessionID,
                    baselineBounds: active.bounds,
                )
                return witnessFailure == nil
            }
        } catch {
            attach(
                witnessFailure ?? "no census evaluated the resize witness",
                named: "last failure from the post-resize geometry witness",
            )
            throw error
        }
        attach(after, named: "actual resized scene geometry and window witness")
        try wait(app, milestone: "post-resize qualification controls remain usable") {
            self.hittableButton("downloadQualificationRefreshObservations", in: app) != nil
                && self.hittableButton("downloadQualificationMarkResizeGesture", in: app) != nil
        }
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "actual system-resized qualification window"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    /// Resolves SpringBoard's physical resize-handle frame into the supplied window
    /// container's coordinate space. Some physical devices expose an otherwise hittable handle
    /// in rotated axes. Directly visible frames remain untouched; rotated frames are
    /// accepted only when their transformed center lands on the container's
    /// bottom-right corner. The rotation uses the physical screen origin because
    /// SpringBoard reports both frames in screen coordinates. Invalid or unrelated
    /// offscreen frames remain rejected.
    private func normalizedResizeHandleFrame(
        reported: CGRect,
        container: CGRect,
        screenBounds: CGRect,
    ) -> CGRect? {
        guard isFiniteResizeFrame(reported), isFiniteResizeFrame(container) else {
            return nil
        }

        let direct = reported.intersection(container)
        if !direct.isNull, !direct.isEmpty {
            return reported
        }
        guard isFiniteResizeFrame(screenBounds), screenBounds.width > screenBounds.height else {
            return nil
        }

        let transformed = CGRect(
            x: screenBounds.minX + reported.minY,
            y: screenBounds.maxY - reported.maxX,
            width: reported.height,
            height: reported.width,
        )
        let cornerDistance = hypot(
            transformed.midX - container.maxX,
            transformed.midY - container.maxY,
        )
        let transformedVisible = transformed.intersection(container)
        guard cornerDistance <= 1,
              !transformedVisible.isNull,
              !transformedVisible.isEmpty
        else {
            return nil
        }

        return transformed
    }

    /// Chooses each resize axis independently so the drag can move outward when the window has
    /// room and inward when it does not. The returned delta is rejected when its destination would
    /// leave the screen, or would leave the card on an axis that shrinks the window.
    private func resizeGestureDelta(
        from start: CGPoint,
        container: CGRect,
        screenBounds: CGRect,
    ) -> CGVector? {
        guard [start.x, start.y].allSatisfy(\.isFinite),
              isFiniteResizeFrame(container),
              isFiniteResizeFrame(screenBounds)
        else {
            return nil
        }

        let quarterWidth = container.width / 4
        let quarterHeight = container.height / 4
        let dx = screenBounds.maxX - container.maxX >= quarterWidth ? quarterWidth : -quarterWidth
        let dy = screenBounds.maxY - container.maxY >= quarterHeight ? quarterHeight : -quarterHeight
        let destination = CGPoint(x: start.x + dx, y: start.y + dy)

        guard destination.x >= screenBounds.minX,
              destination.x <= screenBounds.maxX,
              destination.y >= screenBounds.minY,
              destination.y <= screenBounds.maxY,
              dx >= 0 || (destination.x >= container.minX && destination.x <= container.maxX),
              dy >= 0 || (destination.y >= container.minY && destination.y <= container.maxY)
        else {
            return nil
        }

        return CGVector(dx: dx, dy: dy)
    }

    private func isFiniteResizeFrame(_ frame: CGRect) -> Bool {
        !frame.isNull && !frame.isEmpty
            && [frame.minX, frame.minY, frame.width, frame.height].allSatisfy(\.isFinite)
    }

    /// Parses the host's `String(describing:)` rectangle format, for example
    /// `"(0.0, 0.0, 523.0, 813.0)"`. Returns `nil` for any other input, including the host's
    /// `"unloaded"` placeholder for a window root view that has never been loaded.
    private func parsedRect(_ description: String) -> CGRect? {
        let stripped = description.trimmingCharacters(in: CharacterSet(charactersIn: "() "))
        let parts = stripped.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 4,
              let x = Double(parts[0]), let y = Double(parts[1]),
              let width = Double(parts[2]), let height = Double(parts[3]),
              [x, y, width, height].allSatisfy(\.isFinite)
        else {
            return nil
        }

        return CGRect(x: x, y: y, width: width, height: height)
    }

    /// Compares rectangles parsed from host descriptions. Both sides round-trip through the same
    /// decimal string format, so a difference beyond a sub-point epsilon is a real change.
    private func rectsMatch(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        abs(lhs.origin.x - rhs.origin.x) < 0.001
            && abs(lhs.origin.y - rhs.origin.y) < 0.001
            && abs(lhs.size.width - rhs.size.width) < 0.001
            && abs(lhs.size.height - rhs.size.height) < 0.001
    }

    private func sceneWindow(
        key: String,
        isCover: String,
        hidden: String = "false",
        alpha: String = "1.0",
        frame: String = "(0.0, 0.0, 577.0, 494.0)",
        bounds: String = "(0.0, 0.0, 577.0, 494.0)",
        rootViewBounds: String = "(0.0, 0.0, 577.0, 494.0)",
    ) -> SceneWindow {
        SceneWindow(
            frame: frame,
            bounds: bounds,
            hidden: hidden,
            alpha: alpha,
            key: key,
            isCover: isCover,
            rootViewBounds: rootViewBounds,
        )
    }

    private func resizeCensus(
        window: SceneWindow,
        auxiliaryWindow: SceneWindow? = nil,
        latestObservation: Observation? = nil,
    ) -> SceneCensus {
        let bounds = "(0.0, 0.0, 577.0, 494.0)"
        let scene = WindowScene(
            sessionID: "SCENE",
            activation: "foregroundActive",
            activationRawValue: "0",
            bounds: bounds,
            screenBounds: "(0.0, 0.0, 1133.0, 744.0)",
            windows: [
                auxiliaryWindow ?? sceneWindow(key: "false", isCover: "false"),
                window,
            ],
        )
        let defaultObservation: Observation = [
            "sceneSession": "SCENE",
            "runID": "RUN",
            "coverVisible": "false",
        ]
        return SceneCensus(
            capturedMonotonicSeconds: "20.0",
            distinctSessionIDs: 1,
            rootLayoutObservations: [],
            connectedWindowScenes: [scene],
            latestCoordinatorObservations: [latestObservation ?? defaultObservation],
        )
    }

    /// Selects the one visible keyed content window while allowing a visible non-keyed
    /// auxiliary window. A visible coordinator-owned cover invalidates the scene.
    private func selectedVisibleKeyedSceneWindow(in scene: WindowScene) -> SceneWindow? {
        let visibleWindows = scene.windows.filter { window in
            window.hidden == "false" && (Double(window.alpha) ?? 0) > 0
        }
        guard !visibleWindows.contains(where: { $0.isCover == "true" }) else {
            return nil
        }

        let keyedWindows = visibleWindows.filter { $0.key == "true" }
        return keyedWindows.count == 1 ? keyedWindows.first : nil
    }

    /// Returns the unique scene created by the request when it is foreground-active and
    /// has a same-run mounted coordinator registration. Pre-existing scenes may remain
    /// foreground-active on platforms that host multiple active windows.
    private func uniqueNewActiveScene(
        _ census: SceneCensus,
        baselineSessionIDs: Set<String>,
        runID: String,
    ) -> WindowScene? {
        let sessionIDs = census.connectedWindowScenes.map(\.sessionID)
        let distinctSessionIDs = Set(sessionIDs)
        guard distinctSessionIDs.count >= 2,
              sessionIDs.count == distinctSessionIDs.count,
              distinctSessionIDs.count == census.distinctSessionIDs
        else {
            return nil
        }

        let newSessionIDs = distinctSessionIDs.subtracting(baselineSessionIDs)
        guard newSessionIDs.count == 1, let newSessionID = newSessionIDs.first else {
            return nil
        }

        let newScenes = census.connectedWindowScenes.filter { newSessionIDs.contains($0.sessionID) }
        guard newScenes.count == 1,
              newScenes[0].activation == "foregroundActive",
              census.latestCoordinatorObservations.contains(where: {
                  $0["runID"] == runID
                      && $0["registration"]?.isEmpty == false
                      && $0["sceneSession"] == newSessionID
                      && $0["mounted"] == "true"
              })
        else {
            return nil
        }

        return newScenes[0]
    }

    private func diagnosticValue(_ read: () throws -> String) -> String {
        (try? read()) ?? "unavailable"
    }

    /// Returns the most recent gesture-boundary event for the exact run, scene, and
    /// mounted Root registration. Keeping all three identities prevents an older active
    /// window from satisfying the selected new scene's boundary wait.
    private func resizeGestureMarker(
        in observations: [Observation],
        sceneID: String,
        registration: String,
        runID: String,
    ) -> Observation? {
        observations.last {
            $0["event"] == "resizeGestureWillBegin"
                && $0["runID"] == runID
                && $0["sceneSession"] == sceneID
                && $0["registration"] == registration
        }
    }

    private func census(_ scenes: [WindowScene], observations: [Observation]) -> SceneCensus {
        SceneCensus(
            capturedMonotonicSeconds: "20.0",
            distinctSessionIDs: Set(scenes.map(\.sessionID)).count,
            rootLayoutObservations: [],
            connectedWindowScenes: scenes,
            latestCoordinatorObservations: observations,
        )
    }

    /// The foreground-active scene from the census together with its most recent safe Root layout
    /// confirmation in this run, or `nil` while either is missing. A confirmation counts as safe
    /// baseline evidence only when the host recorded `rootProof` as `"true"` with no visible
    /// privacy cover and no native barrier for the same scene and run.
    private func activeSceneSafeRoot(
        in census: SceneCensus,
        for sessionID: String,
        runID: String,
    ) -> (scene: WindowScene, confirmation: Observation)? {
        guard let scene = census.connectedWindowScenes.first(where: {
            $0.sessionID == sessionID && $0.activation == "foregroundActive"
        }) else {
            return nil
        }
        guard let confirmation = census.rootLayoutObservations.last(where: {
            $0["event"] == "rootLayoutConfirmed" && $0["runID"] == runID
                && $0["sceneSession"] == scene.sessionID && $0["rootProof"] == "true"
                && $0["coverVisible"] == "false" && $0["nativeBarrier"] == "false"
        }) else {
            return nil
        }

        return (scene, confirmation)
    }

    /// `nil` when a census captured after the resize gesture shows the active scene session still
    /// foreground-active with new bounds and exactly one visible attached window whose frame,
    /// bounds, and loaded root view bounds match the new scene bounds. The window selector also
    /// rejects every visible window identified as a privacy cover. This is the retry predicate for
    /// `refreshCensus`, so the caller keeps the last returned reason as its timeout diagnosis. A
    /// real system resize does not change the SwiftUI render token that governs
    /// `rootLayoutConfirmed`, so this witness uses current scene-window cover evidence instead of a
    /// new coordinator observation.
    private func resizedSceneWitnessFailure(
        _ census: SceneCensus,
        activeSceneID: String,
        baselineBounds: String,
    ) -> String? {
        guard let baseline = parsedRect(baselineBounds) else {
            return "the pre-gesture baseline bounds are not parseable"
        }
        guard let scene = census.connectedWindowScenes.first(where: { $0.sessionID == activeSceneID }) else {
            return "the active scene session \(activeSceneID) is no longer connected"
        }
        guard scene.activation == "foregroundActive" else {
            return "the active scene session is no longer foreground-active"
        }
        guard let resizedBounds = parsedRect(scene.bounds) else {
            return "the resized scene bounds are not parseable"
        }
        guard !rectsMatch(resizedBounds, baseline) else {
            return "the scene bounds still match the pre-gesture baseline"
        }
        guard let window = selectedVisibleKeyedSceneWindow(in: scene) else {
            return "the scene does not have exactly one visible keyed non-cover window"
        }
        guard let windowFrame = parsedRect(window.frame), rectsMatch(windowFrame, resizedBounds) else {
            return "the attached window frame does not match the resized scene bounds"
        }
        guard let windowBounds = parsedRect(window.bounds), rectsMatch(windowBounds, resizedBounds) else {
            return "the attached window bounds do not match the resized scene bounds"
        }
        guard let rootViewBounds = parsedRect(window.rootViewBounds), rectsMatch(rootViewBounds, resizedBounds) else {
            return "the loaded root view bounds do not match the resized scene bounds"
        }

        return nil
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
        // The attachment route serves BrowserDownloadLoopbackServer.fixturePDF (608 bytes).
        // The UI-test bundle cannot import that AppHostedTests unit-test target symbol, so the
        // current fixture identity is pinned here; fixtureBytesMatch proves the host compared
        // the served bytes byte-for-byte against the fixture.
        XCTAssertEqual(completed["bytes"], "608")
        XCTAssertEqual(completed["sha256"], "852ba89aa0d708405217efd9cc3d014f4a1cc48ed1895748a1e1d9540f97bd79")
        XCTAssertEqual(completed["fixtureBytesMatch"], "true")
        XCTAssertEqual(completed["backupExcluded"], "true")
        #if targetEnvironment(simulator)
        XCTAssertEqual(completed["nativeProtection"], "UNVERIFIED")
        XCTAssertEqual(completed["protectionMode"], "simulatedReadback")
        #else
        XCTAssertEqual(completed["nativeProtection"], "verified")
        XCTAssertEqual(completed["protectionMode"], "nativeCompleteRequired")
        #endif
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

    /// Waits for a census captured after the scene request that shows the new mounted session
    /// and, when `requiringActiveSceneSafeRoot` is set, also that the census already carries the
    /// safe Root layout confirmation for its foreground-active scene.
    private func freshCensusWithNewMountedScene(
        in app: XCUIApplication,
        baselineSessionIDs: Set<String>,
        runID: String,
        requestedAt: Double,
        requiringActiveSceneSafeRoot: Bool = false,
    ) throws -> SceneCensus {
        try refreshCensus(in: app, newerThan: requestedAt, milestone: "new mounted session after scene request") {
            guard let newScene = self.uniqueNewActiveScene(
                $0,
                baselineSessionIDs: baselineSessionIDs,
                runID: runID,
            ) else {
                return false
            }

            return !requiringActiveSceneSafeRoot
                || self.activeSceneSafeRoot(in: $0, for: newScene.sessionID, runID: runID) != nil
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
        ]
        #if targetEnvironment(simulator)
        app.launchArguments.append("--browser-download-simulated-protection-readback")
        #endif
        app.launch()
        XCTAssertTrue(app.staticTexts["downloadQualificationProtectionQualificationMode"]
            .firstMatch
            .waitForExistence(timeout: 10))
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
