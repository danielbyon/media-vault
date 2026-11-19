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
    private let physicalOperatorArrangementTimeout: TimeInterval = 120
    private let sampleRunID = "ABF518D2-AF57-4890-913B-654CF8F43649"
    private let sampleRegistration = "7F95FA75-B735-458B-A170-C018C70BCD96"

    private enum QualificationError: Error {
        case missingSceneCensus
        case missingObservation
        case waitFailed
        case invalidGeometry
    }

    private enum DiagnosticReadError: Error {
        case unavailable
    }

    private struct SceneCensus: Codable, Equatable {
        let capturedMonotonicSeconds: String
        let distinctSessionIDs: Int
        let rootLayoutObservations: [Observation]
        let connectedWindowScenes: [WindowScene]
        let latestCoordinatorObservations: [Observation]
        var ownerSnapshot: Observation? = nil
        var liveRegisteredRoots: [Observation]? = nil
    }

    private struct ActiveRootTarget {
        let runID: String
        let originalSceneID: String
        let sceneID: String
        let requestedAt: Double
        let initial: SceneCensus

        func registrations(in census: SceneCensus) -> Set<String> {
            Set(census.latestCoordinatorObservations.compactMap { observation in
                guard observation["runID"] == runID, observation["sceneSession"] == sceneID,
                      let registration = observation["registration"], !registration.isEmpty
                else {
                    return nil
                }

                return registration
            })
        }
    }

    private struct LiveRoot {
        let registration: String
        let sceneID: String
        let generation: String
        let revision: UInt64
        let isMounted: Bool
        let safe: Bool

        init?(_ row: Observation, runID: String, scenes: [WindowScene]) {
            guard row["runID"] == runID,
                  let id = row["registration"], UUID(uuidString: id) != nil,
                  let session = row["sceneSession"], !session.isEmpty,
                  let scene = scenes.first(where: { $0.sessionID == session }),
                  row["activation"] == scene.activationRawValue,
                  let ownerGeneration = row["generation"], UInt64(ownerGeneration).map(String.init) == ownerGeneration,
                  let revisionText = row["renderRevision"], let renderRevision = UInt64(revisionText),
                  String(renderRevision) == revisionText,
                  let mounted = row["mounted"].flatMap(Bool.init),
                  let active = row["registrationActive"].flatMap(Bool.init),
                  let confirmed = row["renderConfirmed"].flatMap(Bool.init),
                  let proof = row["rootProof"].flatMap(Bool.init),
                  let barrier = row["nativeBarrier"].flatMap(Bool.init),
                  let cover = row["coverPresent"].flatMap(Bool.init),
                  let visible = row["coverVisible"].flatMap(Bool.init),
                  !visible || cover
            else {
                return nil
            }

            registration = id
            sceneID = session
            generation = ownerGeneration
            revision = renderRevision
            isMounted = mounted
            safe = mounted && active && scene.activation == "foregroundActive" && scene.activationRawValue == "0"
                && confirmed && proof && !barrier && !cover
        }
    }

    /// One connected UIKit window scene as recorded by the qualification host census.
    private struct WindowScene: Codable, Equatable {
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
    private struct SceneWindow: Codable, Equatable {
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

    /// A system-created scene backgrounds the original scene and revokes shared content access.
    /// The completed operation remains retained while unauthorized projections stay empty.
    func testSceneRequestRevokesCompletedDownloadAndKeepsActiveRootUsable() throws {
        let requiresOperatorArrangement = physicalOperatorArrangementEnabled
        let app = try launchFixture(
            passiveSceneCensus: true,
            operatorArrangement: requiresOperatorArrangement,
        )
        defer { app.terminate() }
        let baseline = try freshBaselineCensus(in: app)
        XCTAssertEqual(baseline.connectedWindowScenes.count, 1, "This fixture requires a fresh single hosting scene.")
        let originalScene = try XCTUnwrap(baseline.connectedWindowScenes.first)
        XCTAssertEqual(originalScene.activation, "foregroundActive")
        let proof = try completedDownload(in: app)
        let retainedAllocation = try XCTUnwrap(proof["allocation"].flatMap { UUID(uuidString: $0)?.uuidString })
        let request = try requestSecondScene(in: app, passively: true)
        let runID = try XCTUnwrap(request["runID"])
        let requestedAt = try XCTUnwrap(request["monotonicSeconds"].flatMap { Double($0) })
        let mountedCensus = try awaitMountedForegroundScene(
            in: app,
            originalSceneID: originalScene.sessionID,
            runID: runID,
            requestedAt: requestedAt,
            requiringOriginalBackground: !requiresOperatorArrangement,
        )
        let census: SceneCensus
        if requiresOperatorArrangement {
            attach(mountedCensus, named: "new mounted foreground scene before operator arrangement")
            let mountedScreenshot = XCTAttachment(screenshot: app.screenshot())
            mountedScreenshot.name = "operator arrangement prompt with the new scene mounted"
            mountedScreenshot.lifetime = .keepAlways
            add(mountedScreenshot)
            census = try awaitPhysicalOperatorArrangement(
                in: app,
                originalSceneID: originalScene.sessionID,
                runID: runID,
                after: mountedCensus,
            )
        } else {
            census = mountedCensus
        }
        try assertNewSceneEvidence(census, baselineSessionIDs: [originalScene.sessionID], runID: runID)
        XCTAssertEqual(
            census.connectedWindowScenes.first { $0.sessionID == originalScene.sessionID }?.activation,
            "background",
        )
        let activeScene = try XCTUnwrap(census.connectedWindowScenes.first {
            $0.sessionID != originalScene.sessionID && $0.activation == "foregroundActive"
        })
        let target = ActiveRootTarget(
            runID: runID,
            originalSceneID: originalScene.sessionID,
            sceneID: activeScene.sessionID,
            requestedAt: requestedAt,
            initial: census,
        )
        let activeSceneRegistrations = target.registrations(in: census)
        XCTAssertFalse(
            activeSceneRegistrations.isEmpty,
            "Expected a registered coordinator Root for the active scene.",
        )
        attach(census, named: "actual UIKit scene census before global revocation wait")
        var postRequest: [Observation] = []
        var postRequestStatus: [String: String] = [:]
        var latestCensus: SceneCensus?
        var confirmed: [Observation]?
        var removalObserved = false
        do {
            try wait(app, milestone: "global revocation and safe active-scene Root", enforceDeadline: true) {
                guard let (current, events) = self.postRequestSceneEvidence(
                    runID: runID,
                    requestedAt: requestedAt,
                    readCensus: { self.passiveSceneCensus(in: app) },
                    readLedger: { try? self.observations(app) },
                ) else {
                    return false
                }

                latestCensus = current
                postRequest = events
                removalObserved = removalObserved || self.recordedRemoval(
                    of: retainedAllocation,
                    in: postRequest,
                    runID: runID,
                )
                let denied = self.retainedOwnerIsRevoked(in: current, observations: postRequest, atOrAfter: requestedAt)
                confirmed = self.confirmedRoots(in: current, observations: postRequest, target: target)
                postRequestStatus = [
                    "eventCount": String(postRequest.count),
                    "latestEvent": postRequest.last?["event"] ?? "none",
                    "cleanupRemoved": String(removalObserved),
                    "ownerDenied": String(denied),
                    "activeSceneSafeRoot": String(confirmed != nil),
                ]
                return !removalObserved && denied && confirmed != nil
            }
        } catch {
            if let latestCensus {
                attach(latestCensus, named: "last passive census before safe Root timeout")
            }
            attach(postRequestStatus, named: "global revocation and active-root assertion status")
            attach(postRequest, named: "last observed post-request event set")
            throw error
        }
        let acceptedCensus = try XCTUnwrap(latestCensus)
        XCTAssertEqual(
            acceptedCensus.connectedWindowScenes.first { $0.sessionID == originalScene.sessionID }?.activation,
            "background",
        )
        attach(acceptedCensus, named: "fresh UIKit census paired with the confirmed foreground Root")
        let freshSafeRoots = try XCTUnwrap(confirmed)
        var freshSafeRootAtByRegistration: [String: Double] = [:]
        for freshSafeRoot in freshSafeRoots {
            let registration: String = try XCTUnwrap(freshSafeRoot["registration"])
            let freshSafeRootAt: Double = try XCTUnwrap(
                freshSafeRoot["monotonicSeconds"].flatMap { Double($0) },
            )
            XCTAssertGreaterThanOrEqual(freshSafeRootAt, requestedAt)
            XCTAssertEqual(freshSafeRoot["rootProof"], "true")
            XCTAssertEqual(freshSafeRoot["coverVisible"], "false")
            XCTAssertEqual(freshSafeRoot["nativeBarrier"], "false")
            XCTAssertNil(
                freshSafeRootAtByRegistration.updateValue(freshSafeRootAt, forKey: registration),
                "Expected one latest fresh safe Root per active-scene registration.",
            )
        }
        XCTAssertEqual(Set(freshSafeRootAtByRegistration.keys), activeSceneRegistrations)
        let laterBarrier = postRequest.contains { observation in
            guard observation["runID"] == runID,
                  observation["sceneSession"] == activeScene.sessionID,
                  let registration = observation["registration"],
                  activeSceneRegistrations.contains(registration),
                  let observedAt = observation["monotonicSeconds"].flatMap({ Double($0) }),
                  let freshSafeRootAt = freshSafeRootAtByRegistration[registration]
            else {
                return false
            }

            return observedAt >= freshSafeRootAt
                && (observation["coverVisible"] == "true" || observation["nativeBarrier"] == "true")
        }
        XCTAssertFalse(laterBarrier, "A visible cover or native barrier superseded the active scene's fresh safe Root.")
        attach(postRequest, named: "actual A-background B-active concealment and retained operation")
        try wait(app, milestone: "active B fixture navigation control") {
            self.hittableButton("downloadQualificationOpenFixturePage", in: app) != nil
        }
        try XCTUnwrap(hittableButton("downloadQualificationOpenFixturePage", in: app)).tap()
        try assertFreshNavigation(in: app, expectedRunID: runID)
        try assertReactivation(
            in: app,
            originalSceneID: originalScene.sessionID,
            runID: runID,
            oldOperation: proof["operation"],
            retainedAllocation: retainedAllocation,
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

    func testPassiveSceneCensusSelectsNewestWindowSnapshot() {
        let older = resizeCensus(window: sceneWindow(key: "true", isCover: "false"))
        let newer = SceneCensus(
            capturedMonotonicSeconds: "21.0",
            distinctSessionIDs: older.distinctSessionIDs,
            rootLayoutObservations: older.rootLayoutObservations,
            connectedWindowScenes: older.connectedWindowScenes,
            latestCoordinatorObservations: older.latestCoordinatorObservations,
        )

        XCTAssertEqual(latestPassiveSceneCensus(in: [older, newer]), newer)
    }

    func testPassiveSceneCensusRejectsConflictingSnapshotsAtSameTime() {
        let first = resizeCensus(window: sceneWindow(key: "true", isCover: "false"))
        let conflicting = SceneCensus(
            capturedMonotonicSeconds: first.capturedMonotonicSeconds,
            distinctSessionIDs: first.distinctSessionIDs,
            rootLayoutObservations: first.rootLayoutObservations,
            connectedWindowScenes: first.connectedWindowScenes,
            latestCoordinatorObservations: [],
        )

        XCTAssertNil(latestPassiveSceneCensus(in: [first, conflicting]))
    }

    func testPassiveAccessibilityReadsRefreshCensusWithoutPublishingRootEvents() async throws {
        let app = try launchFixture(passiveSceneCensus: true)
        defer { app.terminate() }
        var baseline: SceneCensus?
        try wait(app, milestone: "initial confirmed Root before passive reads") {
            guard let census = self.passiveSceneCensus(in: app),
                  let latest = census.latestCoordinatorObservations.first,
                  let sceneID = latest["sceneSession"], let runID = latest["runID"],
                  let confirmed = self.liveConfirmedRoots(in: census, sceneID: sceneID, runID: runID, atOrAfter: 0),
                  confirmed.allSatisfy({ callback in
                      census.rootLayoutObservations.contains { layout in
                          layout["runID"] == runID && layout["sceneSession"] == sceneID
                              && layout["registration"] == callback["registration"]
                              && layout["generation"] == callback["generation"]
                              && layout["renderRevision"] == callback["renderRevision"]
                              && self.coordinatorObservationIsSafeRoot(layout)
                      }
                  })
            else {
                return false
            }

            baseline = census
            return true
        }
        let initial = try XCTUnwrap(baseline)
        var previousCapture = try XCTUnwrap(Double(initial.capturedMonotonicSeconds))
        func assertStableRead() throws {
            let events = try observations(app)
            let current = try XCTUnwrap(passiveSceneCensus(in: app))
            let capturedAt = try XCTUnwrap(Double(current.capturedMonotonicSeconds))
            XCTAssertGreaterThan(capturedAt, previousCapture)
            XCTAssertEqual(current.liveRegisteredRoots, initial.liveRegisteredRoots)
            XCTAssertEqual(current.latestCoordinatorObservations, initial.latestCoordinatorObservations)
            XCTAssertEqual(current.rootLayoutObservations, initial.rootLayoutObservations)
            XCTAssertEqual(events.filter { $0["event"] == "rootLayoutConfirmed" }, initial.rootLayoutObservations)
            previousCapture = capturedAt
        }
        for _ in 0 ..< 3 {
            try assertStableRead()
        }
        // Give the host time to commit any SwiftUI work queued by the preceding accessibility reads.
        try await Task.sleep(for: .milliseconds(500))
        try assertStableRead()
    }

    func testHostedRootUpdatePublishesCurrentRevisionWithoutReadFeedback() async throws {
        let app = XCUIApplication(bundleIdentifier: "com.danielbyon.mediavault.browserdownloadqualificationhost")
        app.launchArguments = [
            "--browser-download-production-qualification",
            "--browser-download-hosted-root-read",
            "--browser-download-passive-scene-census",
        ]
        #if targetEnvironment(simulator)
        app.launchArguments.append("--browser-download-simulated-protection-readback")
        #endif
        app.launch()
        defer { app.terminate() }
        let update = app.buttons["downloadQualificationReconcileCurrentRoot"].firstMatch
        var registration: String?
        var runID: String?
        try wait(app, milestone: "hosted foreground Root registration") {
            guard let census = self.passiveSceneCensus(in: app), census.liveRegisteredRoots?.count == 1,
                  let row = census.liveRegisteredRoots?.first, row["mounted"] == "true", row["activation"] == "0",
                  update.isHittable else {
                return false
            }

            runID = row["runID"]
            registration = row["registration"]
            return runID != nil && registration != nil
        }
        let run = try XCTUnwrap(runID)
        let id = try XCTUnwrap(registration)
        func confirmed(_ expectedRevision: UInt64? = nil) -> SceneCensus? {
            guard let census = passiveSceneCensus(in: app), let root = liveRoots(in: census, runID: run)?[id],
                  root.safe, expectedRevision == nil || root.revision == expectedRevision,
                  let callback = census.latestCoordinatorObservations.first, callback["registration"] == id,
                  callback["renderRevision"] == String(root.revision), callback["generation"] == root.generation,
                  coordinatorObservationIsSafeRoot(callback) else {
                return nil
            }

            return census
        }
        update.tap()
        var initial: SceneCensus?
        try wait(app, milestone: "first real hosted Root confirmation") {
            initial = confirmed()
            return initial != nil
        }
        let before = try XCTUnwrap(initial)
        let previous = try XCTUnwrap(liveRoots(in: before, runID: run)?[id])
        let nextRevision = previous.revision + 1

        update.tap()
        let value = try XCTUnwrap(app.staticTexts["downloadQualificationRootUpdateCensus"].firstMatch.value as? String)
        let pending = try JSONDecoder().decode(SceneCensus.self, from: Data(value.utf8))
        let pendingRoot = try XCTUnwrap(liveRoots(in: pending, runID: run)?[id])
        XCTAssertEqual(pendingRoot.revision, nextRevision)
        XCTAssertEqual(pendingRoot.generation, previous.generation)
        XCTAssertFalse(pendingRoot.safe)
        XCTAssertEqual(pending.liveRegisteredRoots?.first?["renderConfirmed"], "false")
        XCTAssertEqual(pending.liveRegisteredRoots?.first?["rootProof"], "false")
        let lastCallback = try XCTUnwrap(pending.latestCoordinatorObservations.first)
        XCTAssertEqual(lastCallback["registration"], id)
        XCTAssertEqual(lastCallback["renderRevision"], String(previous.revision))
        XCTAssertEqual(lastCallback["generation"], previous.generation)
        XCTAssertTrue(coordinatorObservationIsSafeRoot(lastCallback))
        attach(pending, named: "equal-token update before the real layout transaction")

        var completed: SceneCensus?
        try wait(app, milestone: "same hosted revision confirmed by UIKit") {
            completed = confirmed(nextRevision)
            return completed != nil
        }
        let after = try XCTUnwrap(completed)
        XCTAssertGreaterThan(after.rootLayoutObservations.count, pending.rootLayoutObservations.count)
        attach(after, named: "matching hosted revision after the real layout transaction")
        let layoutCount = app.staticTexts["downloadQualificationRootLayoutPasses"].firstMatch
        let layouts = try XCTUnwrap((layoutCount.value as? String).flatMap(Int.init))
        XCTAssertGreaterThan(layouts, 0)
        var capturedAt = try XCTUnwrap(Double(after.capturedMonotonicSeconds))
        func assertStableRead() throws {
            let events = try observations(app)
            let next = try XCTUnwrap(confirmed(nextRevision))
            let nextAt = try XCTUnwrap(Double(next.capturedMonotonicSeconds))
            XCTAssertGreaterThan(nextAt, capturedAt)
            XCTAssertEqual(next.liveRegisteredRoots, after.liveRegisteredRoots)
            XCTAssertEqual(next.rootLayoutObservations, after.rootLayoutObservations)
            XCTAssertEqual(events.filter { $0["event"] == "rootLayoutConfirmed" }, after.rootLayoutObservations)
            XCTAssertEqual((layoutCount.value as? String).flatMap(Int.init), layouts)
            capturedAt = nextAt
        }
        for _ in 0 ..< 3 {
            try assertStableRead()
        }
        try await Task.sleep(for: .milliseconds(500))
        try assertStableRead()
    }

    func testInitialMountedSceneWaitsForCoherentRegistrationsWhileProofIsPending() {
        let callback = passiveRootObservation(["renderRevision": "10"])
        let cached = passiveRootCensus([callback])
        let pending = liveRootObservation(callback, changes: [
            "renderRevision": "11",
            "renderConfirmed": "false",
            "rootProof": "false",
        ])
        var coherent = cached
        coherent.liveRegisteredRoots = [pending]
        var missing = cached
        missing.liveRegisteredRoots = []
        var unmounted = cached
        unmounted.liveRegisteredRoots = [liveRootObservation(callback, changes: ["mounted": "false"])]
        var extra = cached
        extra.liveRegisteredRoots = [pending, liveRootObservation(callback, changes: [
            "registration": "087E818B-1608-4A37-B492-DA45E1AB979F",
        ])]

        func mounted(_ census: SceneCensus, requiringBackground: Bool = true) -> Bool {
            hasCoherentMountedScene(
                census,
                originalSceneID: "OLD",
                runID: sampleRunID,
                requiringOriginalBackground: requiringBackground,
            )
        }
        let captures = [missing, unmounted, extra, coherent]
        XCTAssertEqual(captures.map { mounted($0) }, [false, false, false, true])
        XCTAssertEqual(captures.first { mounted($0) }, coherent)
        let beforeArrangement = passiveRootCensus([callback], foregroundSceneIDs: ["OLD", "NEW"])
        XCTAssertFalse(mounted(beforeArrangement))
        XCTAssertTrue(mounted(beforeArrangement, requiringBackground: false))
    }

    func testReactivationRequiresMatchingLiveRevisionForEveryOriginalSceneRegistration() {
        let other = passiveRootObservation([
            "sceneSession": "OLD",
            "registration": "087E818B-1608-4A37-B492-DA45E1AB979F",
        ])
        let cached = passiveRootObservation(["sceneSession": "OLD", "renderRevision": "10"])
        var census = passiveRootCensus([other, cached], foregroundSceneIDs: ["OLD"])
        func confirmations(_ sample: SceneCensus) -> [Observation]? {
            liveConfirmedRoots(in: sample, sceneID: "OLD", runID: sampleRunID, atOrAfter: 20)
        }

        XCTAssertEqual(confirmations(census), [other, cached])
        census.liveRegisteredRoots = [liveRootObservation(other), liveRootObservation(cached, changes: [
            "renderRevision": "11",
            "renderConfirmed": "false",
            "rootProof": "false",
        ])]
        XCTAssertNil(confirmations(census))
        let confirmed = passiveRootObservation([
            "sceneSession": "OLD",
            "renderRevision": "11",
            "monotonicSeconds": "21.5",
        ])
        census.liveRegisteredRoots = [liveRootObservation(other), liveRootObservation(confirmed)]
        XCTAssertNil(confirmations(census))
        let paired = passiveRootCensus([other, confirmed], foregroundSceneIDs: ["OLD"])
        XCTAssertEqual(confirmations(paired), [other, confirmed])
    }

    func testPassiveRootAcceptsMatchingConfirmationAfterPendingCensus() {
        let target = pendingRootTarget
        let confirmed = passiveRootObservation()
        let fresh = passiveRootCensus([confirmed])
        XCTAssertNil(confirmedRoots(in: target.initial, observations: [confirmed], target: target))
        XCTAssertEqual(confirmedRoots(in: fresh, observations: [confirmed], target: target), [confirmed])
    }

    func testPassiveRootRejectsCachedConfirmationAfterLiveRevisionAdvances() {
        let cached = passiveRootObservation(["renderRevision": "10"])
        var census = passiveRootCensus([cached])
        XCTAssertEqual(confirmedRoots(in: census, observations: [cached], target: pendingRootTarget), [cached])
        census.liveRegisteredRoots = [liveRootObservation(cached, changes: [
            "renderRevision": "11",
            "renderConfirmed": "false",
            "rootProof": "false",
        ])]
        XCTAssertNil(confirmedRoots(in: census, observations: [cached], target: pendingRootTarget))
    }

    func testPassiveRootRejectsUnmatchedOrMalformedLiveRows() {
        let callback = passiveRootObservation()
        let live = liveRootObservation(callback)
        let otherRegistration = "087E818B-1608-4A37-B492-DA45E1AB979F"
        let changes: [Observation] = [
            ["runID": "3B40C2E2-8629-4BA1-BD9C-757AAE7DC86F"],
            ["sceneSession": "OLD"],
            ["registration": otherRegistration],
            ["generation": "4"],
            ["renderRevision": "12"],
            ["renderRevision": "-1"],
            ["mounted": "false"],
            ["registrationActive": "false"],
            ["activation": "2"],
            ["renderConfirmed": "false"],
            ["rootProof": "false"],
            ["nativeBarrier": "true"],
            ["coverPresent": "true"],
            ["coverVisible": "true"],
            ["rootProof": "unknown"],
        ]
        var census = passiveRootCensus([callback])
        let extra = liveRootObservation(callback, changes: ["registration": otherRegistration])
        for rows in [nil, [], [live, live], [live, extra]] as [[Observation]?] {
            census.liveRegisteredRoots = rows
            XCTAssertNil(confirmedRoots(in: census, observations: [callback], target: pendingRootTarget))
        }
        for change in changes {
            census.liveRegisteredRoots = [liveRootObservation(callback, changes: change)]
            XCTAssertNil(confirmedRoots(in: census, observations: [callback], target: pendingRootTarget), "\(change)")
        }
        for key in live.keys {
            census.liveRegisteredRoots = [live.filter { $0.key != key }]
            XCTAssertNil(confirmedRoots(in: census, observations: [callback], target: pendingRootTarget), key)
        }
        let outside = passiveRootObservation(["registration": otherRegistration])
        let single = passiveRootCensus([callback])
        XCTAssertNil(confirmedRoots(in: single, observations: [callback, outside], target: pendingRootTarget))
        let duplicates = passiveRootCensus([callback, callback])
        XCTAssertNil(confirmedRoots(in: duplicates, observations: [callback], target: pendingRootTarget))
    }

    func testPassiveRootRequiresCurrentRetainedDownloadCounts() {
        let owner: Observation = [
            "generation": "3",
            "active": "0",
            "retained": "1",
            "available": "false",
            "presentation": "none",
            "operations": "",
            "cleanupRetry": "false",
            "sampleStartedMonotonicSeconds": "21.5",
            "sampleCompletedMonotonicSeconds": "21.6",
        ]
        let events = [owner.merging(["event": "ownerSnapshot", "monotonicSeconds": "21"]) { _, new in new }]
        var census = passiveRootCensus([passiveRootObservation()])
        census.ownerSnapshot = owner
        XCTAssertTrue(retainedOwnerIsRevoked(in: census, observations: events, atOrAfter: 20))
        for change in [
            ["retained": "0"],
            ["retained": "2"],
            ["active": "1"],
            ["available": "true"],
            ["presentation": "pending"],
            ["operations": "old"],
            ["sampleStartedMonotonicSeconds": "19"],
        ] {
            census.ownerSnapshot = owner.merging(change) { _, new in new }
            XCTAssertFalse(retainedOwnerIsRevoked(in: census, observations: events, atOrAfter: 20), "\(change)")
        }
    }

    func testRetainedAllocationRejectsEveryRecordedRemovalOutcome() {
        for absence in ["true", "false", "unconfirmed"] {
            let events = [[
                "event": "cleanupRemoval",
                "runID": sampleRunID,
                "operation": "retained",
                "absence": absence,
            ]]
            XCTAssertTrue(recordedRemoval(of: "retained", in: events, runID: sampleRunID))
            XCTAssertFalse(recordedRemoval(of: "another", in: events, runID: sampleRunID))
            XCTAssertFalse(recordedRemoval(of: "retained", in: events, runID: "earlier run"))
        }
    }

    func testRetainedAllocationRemovalAtCensusBoundaryPreventsAcceptance() throws {
        let census = passiveRootCensus([passiveRootObservation()], capturedAt: "22")
        let unrelated = [
            "event": "cleanupRemoval",
            "runID": sampleRunID,
            "operation": "other",
            "monotonicSeconds": "21",
        ]
        for (timestamp, rejects) in [("19.9", false), ("20", true), ("21.9", true), ("22", true), ("22.1", true)] {
            let removal = unrelated.merging(["operation": "retained", "monotonicSeconds": timestamp]) { _, new in new }
            var ledger = [unrelated]
            var reads: [String] = []
            let sample = try XCTUnwrap(postRequestSceneEvidence(
                runID: sampleRunID,
                requestedAt: 20,
                readCensus: {
                    reads.append("census")
                    defer { ledger.append(removal) }
                    return census
                },
                readLedger: {
                    reads.append("ledger")
                    return ledger
                },
            ))
            XCTAssertEqual(reads, ["census", "ledger"])
            XCTAssertEqual(sample.census, census)
            XCTAssertEqual(recordedRemoval(of: "retained", in: sample.events, runID: sampleRunID), rejects, timestamp)
        }
    }

    func testPassiveRootRejectsMissingOrMismatchedConfirmation() {
        let target = pendingRootTarget
        let confirmed = passiveRootObservation()
        let fresh = passiveRootCensus([confirmed])
        XCTAssertNil(confirmedRoots(in: fresh, observations: [], target: target))
        for change in [["runID": "OTHER"], ["sceneSession": "OTHER"], ["registration": "OTHER"]] {
            let unrelated = passiveRootObservation(change)
            XCTAssertNil(confirmedRoots(in: passiveRootCensus([unrelated]), observations: [unrelated], target: target))
            XCTAssertNil(confirmedRoots(in: fresh, observations: [unrelated], target: target))
        }
        let pending = passiveRootObservation(["rootProof": "false"])
        XCTAssertNil(confirmedRoots(in: passiveRootCensus([pending]), observations: [pending], target: target))
        XCTAssertNil(confirmedRoots(
            in: passiveRootCensus([confirmed], capturedAt: "19"),
            observations: [confirmed],
            target: target,
        ))
    }

    func testPassiveRootRejectsSupersededOrUnpairedProof() {
        let target = pendingRootTarget
        let confirmed = passiveRootObservation()
        let fresh = passiveRootCensus([confirmed])
        let unsafe = passiveRootObservation(["monotonicSeconds": "21.5", "rootProof": "false"])
        XCTAssertNil(confirmedRoots(in: fresh, observations: [unsafe, confirmed], target: target))
        XCTAssertNil(confirmedRoots(
            in: passiveRootCensus([unsafe, confirmed]),
            observations: [confirmed],
            target: target,
        ))
        let old = passiveRootObservation(["monotonicSeconds": "18"])
        XCTAssertNil(confirmedRoots(in: passiveRootCensus([old]), observations: [old], target: target))
        let newer = passiveRootObservation(["monotonicSeconds": "21.5"])
        XCTAssertNil(confirmedRoots(in: fresh, observations: [newer], target: target))
        let future = passiveRootObservation(["monotonicSeconds": "23"])
        XCTAssertNil(confirmedRoots(in: passiveRootCensus([future]), observations: [future], target: target))
    }

    func testPassiveRootRequiresCoverAndNativeBarrierAbsence() {
        let target = pendingRootTarget
        let confirmed = passiveRootObservation()
        XCTAssertNil(confirmedRoots(
            in: passiveRootCensus([confirmed], cover: true),
            observations: [confirmed],
            target: target,
        ))
        for change in [["coverVisible": "true"], ["nativeBarrier": "true"], ["mounted": "false"], ["generation": "2"]] {
            let blocked = passiveRootObservation(change)
            XCTAssertNil(confirmedRoots(in: passiveRootCensus([blocked]), observations: [blocked], target: target))
        }
    }

    func testPassiveRootRequiresProofBeforeOriginalDeadline() {
        var now = 9.0
        func evaluate(endingAt time: Double) -> Bool {
            withinDeadline(10, now: { now }) {
                now = time
                return true
            }
        }
        XCTAssertTrue(evaluate(endingAt: 9.5))
        XCTAssertFalse(evaluate(endingAt: 10))
        XCTAssertFalse(withinDeadline(10, now: { now }) {
            XCTFail("A passive read began after its deadline.")
            return true
        })
    }

    func testPendingLiveRootCannotQualifyAfterDeadline() {
        let cached = passiveRootObservation()
        var census = passiveRootCensus([cached])
        census.liveRegisteredRoots = [liveRootObservation(
            cached,
            changes: ["rootProof": "false", "renderConfirmed": "false"],
        )]
        let deadline = 10.0
        for time in [8.0, 9.9] {
            XCTAssertFalse(withinDeadline(deadline, now: { time }) {
                confirmedRoots(in: census, observations: [cached], target: pendingRootTarget) != nil
            })
        }
        census.liveRegisteredRoots = [liveRootObservation(cached)]
        XCTAssertFalse(withinDeadline(deadline, now: { deadline }) {
            confirmedRoots(in: census, observations: [cached], target: pendingRootTarget) != nil
        })
    }

    private func passiveRootObservation(_ changes: Observation = [:]) -> Observation {
        [
            "event": "rootLayoutConfirmed",
            "runID": sampleRunID,
            "sceneSession": "NEW",
            "registration": sampleRegistration,
            "monotonicSeconds": "21",
            "generation": "3",
            "renderRevision": "11",
            "mounted": "true",
            "activation": "0",
            "rootProof": "true",
            "coverVisible": "false",
            "nativeBarrier": "false",
        ].merging(changes) { _, changed in changed }
    }

    private func liveRootObservation(_ callback: Observation, changes: Observation = [:]) -> Observation {
        var live = callback.filter { $0.key != "event" && $0.key != "monotonicSeconds" }
        live["registrationActive"] = "true"
        live["renderConfirmed"] = callback["rootProof"]
        live["coverPresent"] = "false"
        return live.merging(changes) { _, changed in changed }
    }

    private func passiveRootCensus(
        _ observations: [Observation],
        capturedAt: String = "22",
        cover: Bool = false,
        foregroundSceneIDs: Set<String> = ["NEW"],
    ) -> SceneCensus {
        let scenes = ["OLD", "NEW"].map { id in
            let active = foregroundSceneIDs.contains(id)
            return WindowScene(
                sessionID: id,
                activation: active ? "foregroundActive" : "background",
                activationRawValue: active ? "0" : "2",
                bounds: "(0, 0, 100, 100)",
                screenBounds: "(0, 0, 100, 100)",
                windows: [sceneWindow(key: "true", isCover: String(active && cover))],
            )
        }
        return SceneCensus(
            capturedMonotonicSeconds: capturedAt,
            distinctSessionIDs: 2,
            rootLayoutObservations: observations,
            connectedWindowScenes: scenes,
            latestCoordinatorObservations: observations,
            ownerSnapshot: ["generation": "3"],
            liveRegisteredRoots: observations.map { liveRootObservation($0) },
        )
    }

    private var pendingRootTarget: ActiveRootTarget {
        ActiveRootTarget(
            runID: sampleRunID,
            originalSceneID: "OLD",
            sceneID: "NEW",
            requestedAt: 17,
            initial: passiveRootCensus(
                [passiveRootObservation(["rootProof": "false", "monotonicSeconds": "19", "renderRevision": "10"])],
                capturedAt: "20",
            ),
        )
    }

    func testLatestFreshSafeRootsRequiresEveryRegistrationAndUsesMonotonicTime() {
        func observation(registration: String, at observedAt: String, safe: Bool) -> Observation {
            [
                "runID": "RUN",
                "sceneSession": "SCENE",
                "registration": registration,
                "monotonicSeconds": observedAt,
                "rootProof": String(safe),
                "coverVisible": String(!safe),
                "nativeBarrier": "false",
            ]
        }

        let safeA = observation(registration: "A", at: "10", safe: true)
        let laterBarrierA = observation(registration: "A", at: "12", safe: false)
        let safeB = observation(registration: "B", at: "11", safe: true)
        XCTAssertNil(latestFreshSafeRoots(
            in: [safeB, laterBarrierA, safeA],
            sceneID: "SCENE",
            registrations: ["A", "B"],
            runID: "RUN",
            atOrAfter: 10,
        ))

        let laterSafeA = observation(registration: "A", at: "13", safe: true)
        XCTAssertEqual(
            try Set(XCTUnwrap(latestFreshSafeRoots(
                in: [safeB, laterBarrierA, safeA, laterSafeA],
                sceneID: "SCENE",
                registrations: ["A", "B"],
                runID: "RUN",
                atOrAfter: 10,
            )).compactMap { $0["registration"] }),
            ["A", "B"],
        )

        let equalTimestampBarrierA = observation(registration: "A", at: "13", safe: false)
        XCTAssertNil(latestFreshSafeRoots(
            in: [safeB, laterSafeA, equalTimestampBarrierA],
            sceneID: "SCENE",
            registrations: ["A", "B"],
            runID: "RUN",
            atOrAfter: 10,
        ))
    }

    func testReactivationOwnerSelectionAllowsSnapshotBetweenActivationAndCensus() throws {
        let earlierActivation: Observation = [
            "event": "UISceneDidActivateNotification",
            "runID": "RUN",
            "sceneSession": "ORIGINAL",
            "activation": "0",
            "monotonicSeconds": "9.5",
        ]
        let finalActivation: Observation = [
            "event": "UISceneDidActivateNotification",
            "runID": "RUN",
            "sceneSession": "ORIGINAL",
            "activation": "0",
            "monotonicSeconds": "10.0",
        ]
        let ownerSnapshot: Observation = [
            "event": "ownerSnapshot",
            "runID": "RUN",
            "generation": "7",
            "available": "true",
            "operations": "",
            "active": "0",
            "retained": "0",
            "monotonicSeconds": "10.1",
        ]
        let census = reactivationCensus(
            capturedAt: "12.0",
            scenes: [("ORIGINAL", "foregroundActive")],
            safeRootGeneration: "7",
            safeRootObservedAt: "11.9",
        )

        let activation = try XCTUnwrap(finalSceneActivation(
            in: [earlierActivation, finalActivation, ownerSnapshot],
            originalSceneID: "ORIGINAL",
            runID: "RUN",
            after: 9.0,
        ))
        let generation = try XCTUnwrap(finalCensusSafeRootGeneration(
            in: census,
            originalSceneID: "ORIGINAL",
            runID: "RUN",
            atOrAfter: 9.0,
        ))
        let owner = try XCTUnwrap(latestOwnerSnapshot(
            in: [earlierActivation, finalActivation, ownerSnapshot],
            runID: "RUN",
            atOrAfter: 10.0,
            atOrBefore: 12.0,
            generation: generation,
        ))

        XCTAssertEqual(activation, finalActivation)
        XCTAssertEqual(owner, ownerSnapshot)
        XCTAssertEqual(generation, "7")
        XCTAssertLessThan(
            try XCTUnwrap(owner["monotonicSeconds"].flatMap(Double.init)),
            try XCTUnwrap(Double(census.capturedMonotonicSeconds)),
        )
        XCTAssertTrue(registeredSceneActivationsAreForegroundActive(
            in: census,
            registeredSessions: ["ORIGINAL"],
        ))
    }

    func testReactivationOwnerSelectionRejectsSnapshotBeforeActivation() {
        let activation: Observation = [
            "event": "UISceneDidActivateNotification",
            "runID": "RUN",
            "sceneSession": "ORIGINAL",
            "activation": "0",
            "monotonicSeconds": "10.0",
        ]
        let ownerSnapshot: Observation = [
            "event": "ownerSnapshot",
            "runID": "RUN",
            "generation": "7",
            "monotonicSeconds": "9.9",
        ]

        XCTAssertNotNil(finalSceneActivation(
            in: [activation, ownerSnapshot],
            originalSceneID: "ORIGINAL",
            runID: "RUN",
            after: 9.0,
        ))
        XCTAssertNil(latestOwnerSnapshot(
            in: [activation, ownerSnapshot],
            runID: "RUN",
            atOrAfter: 10.0,
            atOrBefore: 12.0,
            generation: "7",
        ))
    }

    func testReactivationOwnerSelectionRejectsWrongRun() {
        let ownerSnapshot: Observation = [
            "event": "ownerSnapshot",
            "runID": "OTHER",
            "generation": "7",
            "monotonicSeconds": "10.1",
        ]

        XCTAssertNil(latestOwnerSnapshot(
            in: [ownerSnapshot],
            runID: "RUN",
            atOrAfter: 10.0,
            atOrBefore: 12.0,
            generation: "7",
        ))
    }

    func testReactivationOwnerSelectionRejectsWrongGeneration() {
        let ownerSnapshot: Observation = [
            "event": "ownerSnapshot",
            "runID": "RUN",
            "generation": "6",
            "monotonicSeconds": "10.1",
        ]

        XCTAssertNil(latestOwnerSnapshot(
            in: [ownerSnapshot],
            runID: "RUN",
            atOrAfter: 10.0,
            atOrBefore: 12.0,
            generation: "7",
        ))
    }

    func testFinalCensusGenerationRejectsNewerUnsafeObservation() {
        let olderSafeObservation: Observation = [
            "event": "rootLayoutConfirmed",
            "runID": "RUN",
            "sceneSession": "ORIGINAL",
            "registration": "ORIGINAL-REGISTRATION",
            "generation": "7",
            "monotonicSeconds": "11.0",
            "rootProof": "true",
            "coverVisible": "false",
            "nativeBarrier": "false",
        ]
        var newerUnsafeObservation = olderSafeObservation
        newerUnsafeObservation["generation"] = "8"
        newerUnsafeObservation["monotonicSeconds"] = "11.5"
        newerUnsafeObservation["rootProof"] = "false"
        let census = SceneCensus(
            capturedMonotonicSeconds: "12.0",
            distinctSessionIDs: 1,
            rootLayoutObservations: [olderSafeObservation],
            connectedWindowScenes: [],
            latestCoordinatorObservations: [newerUnsafeObservation, olderSafeObservation],
        )

        XCTAssertNil(finalCensusSafeRootGeneration(
            in: census,
            originalSceneID: "ORIGINAL",
            runID: "RUN",
            atOrAfter: 10.0,
        ))
    }

    func testFinalCensusGenerationRejectsNewerObservationWithoutGeneration() {
        let olderSafeObservation: Observation = [
            "event": "rootLayoutConfirmed",
            "runID": "RUN",
            "sceneSession": "ORIGINAL",
            "registration": "ORIGINAL-REGISTRATION",
            "generation": "7",
            "monotonicSeconds": "11.0",
            "rootProof": "true",
            "coverVisible": "false",
            "nativeBarrier": "false",
        ]
        var newerIncompleteObservation = olderSafeObservation
        newerIncompleteObservation.removeValue(forKey: "generation")
        newerIncompleteObservation["monotonicSeconds"] = "11.5"
        let census = SceneCensus(
            capturedMonotonicSeconds: "12.0",
            distinctSessionIDs: 1,
            rootLayoutObservations: [olderSafeObservation],
            connectedWindowScenes: [],
            latestCoordinatorObservations: [newerIncompleteObservation, olderSafeObservation],
        )

        XCTAssertNil(finalCensusSafeRootGeneration(
            in: census,
            originalSceneID: "ORIGINAL",
            runID: "RUN",
            atOrAfter: 10.0,
        ))
    }

    func testReactivationOwnerSelectionRejectsSnapshotAfterCensus() {
        let activation: Observation = [
            "event": "UISceneDidActivateNotification",
            "runID": "RUN",
            "sceneSession": "ORIGINAL",
            "activation": "0",
            "monotonicSeconds": "10.0",
        ]
        let ownerSnapshot: Observation = [
            "event": "ownerSnapshot",
            "runID": "RUN",
            "generation": "7",
            "monotonicSeconds": "12.1",
        ]

        XCTAssertNotNil(finalSceneActivation(
            in: [activation, ownerSnapshot],
            originalSceneID: "ORIGINAL",
            runID: "RUN",
            after: 9.0,
        ))
        XCTAssertNil(latestOwnerSnapshot(
            in: [activation, ownerSnapshot],
            runID: "RUN",
            atOrAfter: 10.0,
            atOrBefore: 12.0,
            generation: "7",
        ))
    }

    func testReactivationOwnerSelectionAcceptsInclusiveBoundaries() {
        let atActivation: Observation = [
            "event": "ownerSnapshot",
            "runID": "RUN",
            "generation": "7",
            "monotonicSeconds": "10.0",
        ]
        let atCensus: Observation = [
            "event": "ownerSnapshot",
            "runID": "RUN",
            "generation": "7",
            "monotonicSeconds": "12.0",
        ]

        XCTAssertEqual(
            latestOwnerSnapshot(
                in: [atActivation],
                runID: "RUN",
                atOrAfter: 10.0,
                atOrBefore: 12.0,
                generation: "7",
            ),
            atActivation,
        )
        XCTAssertEqual(
            latestOwnerSnapshot(
                in: [atCensus],
                runID: "RUN",
                atOrAfter: 10.0,
                atOrBefore: 12.0,
                generation: "7",
            ),
            atCensus,
        )
    }

    func testReactivationOwnerSelectionRejectsNonFiniteTimestamps() {
        let ownerSnapshot: Observation = [
            "event": "ownerSnapshot",
            "runID": "RUN",
            "generation": "7",
            "monotonicSeconds": "10.1",
        ]
        let infiniteOwnerSnapshot: Observation = [
            "event": "ownerSnapshot",
            "runID": "RUN",
            "generation": "7",
            "monotonicSeconds": "infinity",
        ]
        let notANumberOwnerSnapshot: Observation = [
            "event": "ownerSnapshot",
            "runID": "RUN",
            "generation": "7",
            "monotonicSeconds": "nan",
        ]

        XCTAssertNil(latestOwnerSnapshot(
            in: [infiniteOwnerSnapshot],
            runID: "RUN",
            atOrAfter: 10.0,
            atOrBefore: 12.0,
            generation: "7",
        ))
        XCTAssertNil(latestOwnerSnapshot(
            in: [notANumberOwnerSnapshot],
            runID: "RUN",
            atOrAfter: 10.0,
            atOrBefore: 12.0,
            generation: "7",
        ))
        XCTAssertNil(latestOwnerSnapshot(
            in: [ownerSnapshot],
            runID: "RUN",
            atOrAfter: .infinity,
            atOrBefore: 12.0,
            generation: "7",
        ))
        XCTAssertNil(latestOwnerSnapshot(
            in: [ownerSnapshot],
            runID: "RUN",
            atOrAfter: 10.0,
            atOrBefore: .infinity,
            generation: "7",
        ))
    }

    func testReactivationOwnerSelectionUsesLatestObservationWithinInterval() {
        let beforeActivation: Observation = [
            "event": "ownerSnapshot",
            "runID": "RUN",
            "generation": "7",
            "available": "false",
            "monotonicSeconds": "9.9",
        ]
        let earlierInWindow: Observation = [
            "event": "ownerSnapshot",
            "runID": "RUN",
            "generation": "7",
            "available": "false",
            "monotonicSeconds": "10.5",
        ]
        let firstLatest: Observation = [
            "event": "ownerSnapshot",
            "runID": "RUN",
            "generation": "7",
            "available": "false",
            "monotonicSeconds": "12.0",
        ]
        let secondLatest: Observation = [
            "event": "ownerSnapshot",
            "runID": "RUN",
            "generation": "7",
            "available": "true",
            "monotonicSeconds": "12.0",
        ]
        let afterCensus: Observation = [
            "event": "ownerSnapshot",
            "runID": "RUN",
            "generation": "7",
            "available": "true",
            "monotonicSeconds": "12.1",
        ]

        XCTAssertEqual(
            latestOwnerSnapshot(
                in: [afterCensus, beforeActivation, firstLatest, secondLatest, earlierInWindow],
                runID: "RUN",
                atOrAfter: 10.0,
                atOrBefore: 12.0,
                generation: "7",
            ),
            secondLatest,
        )
    }

    func testReactivationAvailabilityRejectsMismatchWithFinalRegisteredScenes() {
        let census = reactivationCensus(
            capturedAt: "12.0",
            scenes: [
                ("ORIGINAL", "foregroundActive"),
                ("SECOND", "background"),
            ],
            safeRootGeneration: "7",
            safeRootObservedAt: "11.9",
        )
        let ownerSnapshot: Observation = [
            "event": "ownerSnapshot",
            "runID": "RUN",
            "generation": "7",
            "available": "true",
            "monotonicSeconds": "10.1",
        ]
        let expectedAvailability = registeredSceneActivationsAreForegroundActive(
            in: census,
            registeredSessions: ["ORIGINAL", "SECOND"],
        )

        XCTAssertFalse(expectedAvailability)
        XCTAssertNotEqual(ownerSnapshot["available"], String(expectedAvailability))
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

    /// Builds a complete final-census fixture for reactivation selector tests.
    private func reactivationCensus(
        capturedAt: String,
        scenes: [(sessionID: String, activation: String)],
        safeRootGeneration: String,
        safeRootObservedAt: String,
    ) -> SceneCensus {
        let windowScenes = scenes.map { scene in
            WindowScene(
                sessionID: scene.sessionID,
                activation: scene.activation,
                activationRawValue: scene.activation == "foregroundActive" ? "0" : "2",
                bounds: "(0.0, 0.0, 692.0, 494.0)",
                screenBounds: "(0.0, 0.0, 744.0, 1133.0)",
                windows: [sceneWindow(key: "true", isCover: "false")],
            )
        }
        let coordinatorObservations: [Observation] = scenes.map { scene in
            [
                "event": "rootLayoutConfirmed",
                "runID": "RUN",
                "sceneSession": scene.sessionID,
                "registration": scene.sessionID + "-REGISTRATION",
                "generation": safeRootGeneration,
                "monotonicSeconds": safeRootObservedAt,
                "rootProof": String(scene.activation == "foregroundActive"),
                "coverVisible": "false",
                "nativeBarrier": "false",
            ]
        }
        return SceneCensus(
            capturedMonotonicSeconds: capturedAt,
            distinctSessionIDs: Set(windowScenes.map(\.sessionID)).count,
            rootLayoutObservations: coordinatorObservations,
            connectedWindowScenes: windowScenes,
            latestCoordinatorObservations: coordinatorObservations,
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

    /// Returns the last foreground activation in the original scene and run after the request.
    /// UIKit records a did-activate notification for every registered scene, so both scene
    /// identity and the foreground-active activation value are required.
    private func finalSceneActivation(
        in observations: [Observation],
        originalSceneID: String,
        runID: String,
        after requestedAt: Double,
    ) -> Observation? {
        observations.last {
            guard $0["runID"] == runID,
                  $0["event"] == "UISceneDidActivateNotification",
                  $0["sceneSession"] == originalSceneID,
                  $0["activation"] == "0",
                  let observedAt = $0["monotonicSeconds"].flatMap({ Double($0) })
            else {
                return false
            }

            return observedAt.isFinite && observedAt > requestedAt
        }
    }

    /// Returns the owner generation represented by the final census's latest original-scene
    /// coordinator observation. The newest relevant observation is selected before its safety
    /// and generation are evaluated, so a newer unsafe observation cannot be hidden by an
    /// older safe one. Only one safe generation at the latest timestamp is accepted.
    private func finalCensusSafeRootGeneration(
        in census: SceneCensus,
        originalSceneID: String,
        runID: String,
        atOrAfter minimumMonotonicSeconds: Double,
    ) -> String? {
        guard let capturedAt = Double(census.capturedMonotonicSeconds), capturedAt.isFinite else {
            return nil
        }

        let observations = census.latestCoordinatorObservations.compactMap { observation -> (
            Double,
            Observation,
        )? in
            guard observation["runID"] == runID,
                  observation["sceneSession"] == originalSceneID,
                  let observedAt = observation["monotonicSeconds"].flatMap({ Double($0) })
            else {
                return nil
            }
            guard observedAt.isFinite,
                  observedAt >= minimumMonotonicSeconds,
                  observedAt <= capturedAt
            else {
                return nil
            }

            return (observedAt, observation)
        }
        guard let latestObservedAt = observations.map(\.0).max() else {
            return nil
        }

        let latestObservations = observations
            .filter { $0.0 == latestObservedAt }
        guard latestObservations.allSatisfy({ coordinatorObservationIsSafeRoot($0.1) }) else {
            return nil
        }

        let latestGenerations = latestObservations.compactMap { $0.1["generation"].flatMap { $0.isEmpty ? nil : $0 } }
        guard latestGenerations.count == latestObservations.count,
              let generation = latestGenerations.first,
              latestGenerations.allSatisfy({ $0 == generation })
        else {
            return nil
        }

        return generation
    }

    /// Availability is true only when every registered scene represented by the final census is
    /// foreground-active. Missing, duplicate or additional registered scenes cannot establish a
    /// complete availability result.
    private func registeredSceneActivationsAreForegroundActive(
        in census: SceneCensus,
        registeredSessions: Set<String>,
    ) -> Bool {
        let registeredScenes = census.connectedWindowScenes.filter { registeredSessions.contains($0.sessionID) }
        return !registeredSessions.isEmpty
            && registeredScenes.count == registeredSessions.count
            && registeredScenes.allSatisfy { $0.activation == "foregroundActive" }
    }

    /// Returns the newest coordinator observation for each registration at or after a census.
    /// Equal timestamps resolve to unsafe Root evidence, so array order cannot hide a barrier.
    private func latestCoordinatorObservationsByRegistration(
        in observations: [Observation],
        runID: String,
        atOrAfter minimumMonotonicSeconds: Double,
    ) -> [Observation] {
        var latestByRegistration: [String: (observedAt: Double, observation: Observation)] = [:]
        for observation in observations {
            guard observation["runID"] == runID,
                  let registration = observation["registration"], !registration.isEmpty,
                  let observedAt = observation["monotonicSeconds"].flatMap({ Double($0) }),
                  observedAt.isFinite,
                  observedAt >= minimumMonotonicSeconds
            else {
                continue
            }
            guard let latest = latestByRegistration[registration] else {
                latestByRegistration[registration] = (observedAt, observation)
                continue
            }

            let equalTimeRejectsSafeEvidence = observedAt == latest.observedAt
                && !coordinatorObservationIsSafeRoot(observation)
                && coordinatorObservationIsSafeRoot(latest.observation)
            if observedAt > latest.observedAt || equalTimeRejectsSafeEvidence {
                latestByRegistration[registration] = (observedAt, observation)
            }
        }

        return latestByRegistration.keys.sorted().compactMap { latestByRegistration[$0]?.observation }
    }

    /// Returns the latest post-census Root for every registration of a scene only when all are safe.
    private func latestFreshSafeRoots(
        in observations: [Observation],
        sceneID: String,
        registrations: Set<String>,
        runID: String,
        atOrAfter minimumMonotonicSeconds: Double,
    ) -> [Observation]? {
        let matching = latestCoordinatorObservationsByRegistration(
            in: observations,
            runID: runID,
            atOrAfter: minimumMonotonicSeconds,
        ).filter {
            $0["sceneSession"] == sceneID && registrations.contains($0["registration"] ?? "")
        }
        let observedRegistrations = Set(matching.compactMap { $0["registration"] })
        guard !registrations.isEmpty,
              observedRegistrations == registrations,
              matching.allSatisfy(coordinatorObservationIsSafeRoot)
        else {
            return nil
        }

        return matching
    }

    private func coordinatorObservationIsSafeRoot(_ observation: Observation) -> Bool {
        observation["rootProof"] == "true"
            && observation["coverVisible"] == "false"
            && observation["nativeBarrier"] == "false"
    }

    /// Every cached registration must still exist in the live coordinator under the same identity.
    private func liveRoots(in census: SceneCensus, runID: String) -> [String: LiveRoot]? {
        guard UUID(uuidString: runID) != nil, let rows = census.liveRegisteredRoots, !rows.isEmpty,
              rows.count == census.latestCoordinatorObservations.count else {
            return nil
        }

        var roots: [String: LiveRoot] = [:]
        for row in rows {
            guard let root = LiveRoot(row, runID: runID, scenes: census.connectedWindowScenes),
                  roots.updateValue(root, forKey: root.registration) == nil else {
                return nil
            }
        }
        var seen: Set<String> = []
        for row in census.latestCoordinatorObservations {
            guard row["runID"] == runID, let registration = row["registration"],
                  let root = roots[registration], row["sceneSession"] == root.sceneID,
                  seen.insert(registration).inserted else {
                return nil
            }
        }
        return roots
    }

    /// Pairs each foreground registration's latest callback with its live revision and the actual windows.
    /// An equal-token update can invalidate a revision while its last callback still reports a safe Root.
    private func liveConfirmedRoots(
        in census: SceneCensus,
        sceneID: String,
        runID: String,
        atOrAfter minimumTime: Double,
    ) -> [Observation]? {
        let sessions = census.connectedWindowScenes.map(\.sessionID)
        guard Set(sessions).count == sessions.count, sessions.count == census.distinctSessionIDs,
              let scene = census.connectedWindowScenes.first(where: { $0.sessionID == sceneID }),
              scene.activation == "foregroundActive", scene.activationRawValue == "0",
              !scene.windows.isEmpty, scene.windows.allSatisfy({ $0.isCover == "false" }),
              let capturedAt = Double(census.capturedMonotonicSeconds), capturedAt.isFinite,
              let generation = census.ownerSnapshot?["generation"],
              let live = liveRoots(in: census, runID: runID) else {
            return nil
        }

        let registrations = Set(live.values.filter { $0.sceneID == sceneID }.map(\.registration))
        guard let callbacks = latestFreshSafeRoots(
            in: census.latestCoordinatorObservations,
            sceneID: sceneID,
            registrations: registrations,
            runID: runID,
            atOrAfter: minimumTime,
        ), callbacks.allSatisfy({ callback in
            guard let id = callback["registration"], let root = live[id],
                  let observedAt = callback["monotonicSeconds"].flatMap(Double.init) else {
                return false
            }

            return root.safe && root.generation == generation && callback["generation"] == generation
                && callback["renderRevision"] == String(root.revision) && callback["mounted"] == "true"
                && callback["activation"] == scene.activationRawValue && observedAt <= capturedAt
        }) else {
            return nil
        }

        return callbacks
    }

    /// Requires the independent event ledger to agree with the live proof for every pinned registration.
    private func confirmedRoots(
        in census: SceneCensus,
        observations: [Observation],
        target: ActiveRootTarget,
    ) -> [Observation]? {
        let registrations = target.registrations(in: target.initial)
        guard let initialAt = Double(target.initial.capturedMonotonicSeconds), initialAt.isFinite,
              initialAt >= target.requestedAt,
              let capturedAt = Double(census.capturedMonotonicSeconds), capturedAt.isFinite, capturedAt > initialAt,
              let scene = uniqueNewActiveScene(
                  census,
                  baselineSessionIDs: [target.originalSceneID],
                  runID: target.runID,
              ),
              scene.sessionID == target.sceneID,
              census.connectedWindowScenes
              .first(where: { $0.sessionID == target.originalSceneID })?
              .activation == "background",
              target.registrations(in: census) == registrations,
              let roots = liveConfirmedRoots(
                  in: census,
                  sceneID: target.sceneID,
                  runID: target.runID,
                  atOrAfter: target.requestedAt,
              ),
              let initialRoots = liveRoots(in: target.initial, runID: target.runID)
        else {
            return nil
        }

        let latestEvents = latestCoordinatorObservationsByRegistration(
            in: observations,
            runID: target.runID,
            atOrAfter: target.requestedAt,
        )
        let ledgerRegistrations = Set(latestEvents.filter {
            $0["sceneSession"] == target.sceneID && $0["mounted"] == "true"
        }
        .compactMap { $0["registration"] })
        guard ledgerRegistrations == registrations,
              latestFreshSafeRoots(
                  in: latestEvents,
                  sceneID: target.sceneID,
                  registrations: registrations,
                  runID: target.runID,
                  atOrAfter: target.requestedAt,
              ) == roots,
              roots.allSatisfy({ root in
                  guard let registration = root["registration"],
                        let revision = root["renderRevision"].flatMap(UInt64.init),
                        let previousLive = initialRoots[registration], revision >= previousLive.revision,
                        let observedAt = root["monotonicSeconds"].flatMap(Double.init), observedAt <= capturedAt,
                        let initial = target.initial.latestCoordinatorObservations.first(where: {
                            $0["runID"] == target.runID && $0["sceneSession"] == target.sceneID
                                && $0["registration"] == root["registration"]
                        }),
                        let previousAt = initial["monotonicSeconds"].flatMap(Double.init),
                        previousAt.isFinite, previousAt <= initialAt, observedAt >= previousAt
                  else {
                      return false
                  }

                  let alreadyConfirmed = previousLive.safe && previousLive.generation == root["generation"]
                      && previousLive.revision == revision && initial["renderRevision"] == root["renderRevision"]
                      && coordinatorObservationIsSafeRoot(initial)
                  return alreadyConfirmed || observedAt > initialAt
              })
        else {
            return nil
        }

        return roots
    }

    /// Read the ledger after the census so it includes cleanup recorded during the window scan.
    /// A later removal of the retained allocation also disqualifies the sample.
    private func postRequestSceneEvidence(
        runID: String,
        requestedAt: Double,
        readCensus: () -> SceneCensus?,
        readLedger: () -> [Observation]?,
    ) -> (census: SceneCensus, events: [Observation])? {
        guard let census = readCensus(), let ledger = readLedger() else {
            return nil
        }

        let events = ledger.filter {
            $0["runID"] == runID && ($0["monotonicSeconds"].flatMap(Double.init) ?? -1) >= requestedAt
        }
        return (census, events)
    }

    private func recordedRemoval(of allocation: String, in events: [Observation], runID: String) -> Bool {
        events.contains { $0["runID"] == runID && $0["event"] == "cleanupRemoval" && $0["operation"] == allocation }
    }

    private func retainedOwnerIsRevoked(
        in census: SceneCensus,
        observations: [Observation],
        atOrAfter requestedAt: Double,
    ) -> Bool {
        guard let current = census.ownerSnapshot, let generation = current["generation"],
              let latest = observations.last(where: { $0["event"] == "ownerSnapshot" }),
              latest["generation"] == generation,
              let observedAt = latest["monotonicSeconds"].flatMap(Double.init),
              let start = current["sampleStartedMonotonicSeconds"].flatMap(Double.init),
              let end = current["sampleCompletedMonotonicSeconds"].flatMap(Double.init),
              let capturedAt = Double(census.capturedMonotonicSeconds),
              start.isFinite, end.isFinite, capturedAt.isFinite, observedAt.isFinite,
              requestedAt <= observedAt, observedAt <= capturedAt,
              requestedAt <= start, start <= end, end <= capturedAt
        else {
            return false
        }

        let expected = [
            "available": "false",
            "retained": "1",
            "active": "0",
            "operations": "",
            "presentation": "none",
            "cleanupRetry": "false",
        ]
        return expected.allSatisfy { key, value in current[key] == value && latest[key] == value }
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

    private func assertFreshNavigation(in app: XCUIApplication, expectedRunID: String? = nil) throws {
        var requestObservation: Observation?
        try wait(app, milestone: "fixture navigation request evidence") {
            requestObservation = (try? self.observations(app))?.last {
                $0["event"] == "fixtureNavigationRequested" && $0["fixtureRoute"] == "first"
                    && (expectedRunID == nil || $0["runID"] == expectedRunID)
            }
            return requestObservation != nil
        }
        let requested = try XCTUnwrap(requestObservation)
        let runID = try XCTUnwrap(requested["runID"])
        let token = try XCTUnwrap(requested["fixtureRequest"])
        try wait(app, milestone: "fresh B committed metadata and actual ready document") {
            (try? self.observations(app))?.contains {
                $0["runID"] == runID && $0["event"] == "fixtureNavigationCommitted" && $0["fixtureRequest"] == token
                    && $0["metadataMatches"] == "true" && $0["documentMatches"] == "true"
                    && $0["webViewAttached"] == "true" && $0["readyState"] == "complete"
            } == true
        }
    }

    private func assertReactivation(
        in app: XCUIApplication,
        originalSceneID: String,
        runID: String,
        oldOperation: String?,
        retainedAllocation: String,
    ) throws {
        try XCTUnwrap(hittableButton("downloadQualificationReactivateBackgroundScene", in: app)).tap()
        var requestObservation: Observation?
        try wait(app, milestone: "scene reactivation request evidence") {
            requestObservation = (try? self.observations(app))?.last {
                $0["runID"] == runID && $0["event"] == "sceneReactivationRequested"
            }
            return requestObservation != nil
        }
        let requested = try XCTUnwrap(requestObservation)
        XCTAssertEqual(requested["requestedSession"], originalSceneID)
        XCTAssertEqual(requested["priorActivation"], "background")
        let requestedAt = try XCTUnwrap(requested["monotonicSeconds"].flatMap { Double($0) })
        let census = try refreshCensus(
            in: app,
            newerThan: requestedAt,
            milestone: "actual original scene reactivated",
            condition: {
                self.liveConfirmedRoots(in: $0, sceneID: originalSceneID, runID: runID, atOrAfter: requestedAt) != nil
            },
            includingMinimumCapture: true,
            enforceDeadline: true,
        )
        attach(census, named: "actual original session reactivation with safe Root")
        let censusCapturedAt = try XCTUnwrap(Double(census.capturedMonotonicSeconds))
        let finalSafeRootGeneration = try XCTUnwrap(finalCensusSafeRootGeneration(
            in: census,
            originalSceneID: originalSceneID,
            runID: runID,
            atOrAfter: requestedAt,
        ))
        let owner = try XCTUnwrap(census.ownerSnapshot)
        let currentObservations = try observations(app)
        let activation = try XCTUnwrap(finalSceneActivation(
            in: currentObservations,
            originalSceneID: originalSceneID,
            runID: runID,
            after: requestedAt,
        ))
        let activationAt = try XCTUnwrap(activation["monotonicSeconds"].flatMap(Double.init))
        let ownerSampleStartedAt = try XCTUnwrap(owner["sampleStartedMonotonicSeconds"].flatMap(Double.init))
        let ownerSampleCompletedAt = try XCTUnwrap(owner["sampleCompletedMonotonicSeconds"].flatMap(Double.init))
        XCTAssertTrue(censusCapturedAt.isFinite)
        XCTAssertGreaterThan(censusCapturedAt, requestedAt)
        XCTAssertGreaterThanOrEqual(ownerSampleStartedAt, activationAt)
        XCTAssertGreaterThanOrEqual(ownerSampleCompletedAt, ownerSampleStartedAt)
        XCTAssertLessThanOrEqual(ownerSampleCompletedAt, censusCapturedAt)
        XCTAssertEqual(owner["generation"], finalSafeRootGeneration)
        XCTAssertEqual(owner["available"], "false")
        XCTAssertEqual(owner["cleanupRetry"], "false")
        XCTAssertEqual(owner["presentation"], "none")
        XCTAssertEqual(owner["operations"], "")
        XCTAssertEqual(owner["active"], "0")
        XCTAssertEqual(owner["retained"], "1")
        attach(owner, named: "owner authorization sampled with final original-scene census")
        let registeredSessions = Set(census.latestCoordinatorObservations.compactMap { observation -> String? in
            guard observation["runID"] == runID,
                  observation["registration"]?.isEmpty == false
            else {
                return nil
            }

            return observation["sceneSession"]
        })
        XCTAssertFalse(
            registeredSessions.isEmpty,
            "Expected at least one registered hosting session in the final admission census.",
        )
        let censusSessions = Set(census.connectedWindowScenes.map(\.sessionID))
        XCTAssertTrue(
            registeredSessions.isSubset(of: censusSessions),
            "Every registered hosting session must appear in the final connected-scene census.",
        )
        let registeredScenes = census.connectedWindowScenes.filter { registeredSessions.contains($0.sessionID) }
        XCTAssertEqual(
            registeredScenes.count,
            registeredSessions.count,
            "The final census must contain exactly one scene for every registered hosting session.",
        )
        let allRegisteredScenesActive = registeredSceneActivationsAreForegroundActive(
            in: census,
            registeredSessions: registeredSessions,
        )
        XCTAssertEqual(
            owner["available"],
            String(allRegisteredScenesActive),
            "Owner availability must match the registered hosting scene activations: "
                + "\(registeredScenes.map { "\($0.sessionID)=\($0.activation)" }.sorted()).",
        )
        XCTAssertNotEqual(owner["operations"], oldOperation)
        XCTAssertFalse(recordedRemoval(of: retainedAllocation, in: currentObservations, runID: runID))
        XCTAssertFalse(currentObservations.contains {
            $0["runID"] == runID && $0["event"] == "cleanupRemoval" && $0["operation"] == oldOperation
        }, "Privacy transitions must not remove the retained completed operation.")
    }

    private func completedDownload(in app: XCUIApplication) throws -> Observation {
        try wait(app, milestone: "loopback readiness before scene request") {
            app.staticTexts["Loopback ready. Open fixture page, then download attachment PDF."].exists
        }
        try XCTUnwrap(hittableButton("downloadQualificationOpenFixturePage", in: app)).tap()
        try assertFreshNavigation(in: app)
        try XCTUnwrap(hittableButton("downloadQualificationDownloadAttachment", in: app)).tap()
        var proof: Observation?
        var passivePayloads = ""
        do {
            try wait(app, milestone: "originating WebKit completed PDF before scene request") {
                passivePayloads = self.passiveObservationPayloads(in: app).joined(separator: "\n---\n")
                proof = (try? self.observations(app))?.last { $0["event"] == "completedFileProof" }
                return proof != nil
            }
        } catch {
            if !passivePayloads.isEmpty {
                let attachment = XCTAttachment(string: passivePayloads)
                attachment.name = "passive observations at download completion timeout"
                attachment.lifetime = .keepAlways
                add(attachment)
            }

            throw error
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

    private func requestSecondScene(in app: XCUIApplication, passively: Bool = false) throws -> Observation {
        try wait(app, milestone: "second-scene request control") {
            self.hittableButton("downloadQualificationRequestSecondScene", in: app) != nil
        }
        try XCTUnwrap(hittableButton("downloadQualificationRequestSecondScene", in: app)).tap()

        if passively {
            var result: Observation?
            try wait(app, milestone: "passive scene-request event evidence") {
                guard let request = self.passiveSceneRequest(in: app) else {
                    return false
                }

                result = request
                return true
            }
            let request = try XCTUnwrap(result)
            guard request["event"] == "sceneRequested" else {
                XCTFail("Scene request was refused or failed before a request event was captured.")
                throw QualificationError.waitFailed
            }

            return request
        }

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
        try refreshCensus(
            in: app,
            newerThan: requestedAt,
            milestone: "new mounted session after scene request",
            condition: {
                guard let newScene = self.uniqueNewActiveScene(
                    $0,
                    baselineSessionIDs: baselineSessionIDs,
                    runID: runID,
                ) else {
                    return false
                }

                return !requiringActiveSceneSafeRoot
                    || self.activeSceneSafeRoot(in: $0, for: newScene.sessionID, runID: runID) != nil
            },
            includingMinimumCapture: true,
        )
    }

    /// Pins the new scene once its mounted registrations appear in both the live query and callback cache.
    /// Its render revision can still be awaiting layout at this point.
    private func hasCoherentMountedScene(
        _ census: SceneCensus,
        originalSceneID: String,
        runID: String,
        requiringOriginalBackground: Bool,
    ) -> Bool {
        guard let scene = uniqueNewActiveScene(census, baselineSessionIDs: [originalSceneID], runID: runID),
              let original = census.connectedWindowScenes.first(where: { $0.sessionID == originalSceneID }),
              !requiringOriginalBackground || original.activation == "background",
              let capturedAt = Double(census.capturedMonotonicSeconds), capturedAt.isFinite,
              let roots = liveRoots(in: census, runID: runID) else {
            return false
        }

        return census.latestCoordinatorObservations.allSatisfy { callback in
            guard let id = callback["registration"], let live = roots[id],
                  callback["mounted"] == String(live.isMounted),
                  let observedAt = callback["monotonicSeconds"].flatMap(Double.init),
                  observedAt.isFinite, observedAt <= capturedAt else {
                return false
            }

            return live.sceneID != scene.sessionID || live.isMounted
        }
    }

    /// Uses passive accessibility reads so checking the mount does not activate another scene.
    private func awaitMountedForegroundScene(
        in app: XCUIApplication,
        originalSceneID: String,
        runID: String,
        requestedAt: Double,
        requiringOriginalBackground: Bool,
    ) throws -> SceneCensus {
        var result: SceneCensus?
        var lastCensus: SceneCensus?
        do {
            try wait(
                app,
                milestone: "passive new scene mount and foreground activation",
                timeout: 60,
                enforceDeadline: true,
            ) {
                guard let census = self.passiveSceneCensus(in: app) else {
                    return false
                }

                lastCensus = census
                guard let capturedAt = Double(census.capturedMonotonicSeconds), capturedAt >= requestedAt,
                      self.hasCoherentMountedScene(
                          census,
                          originalSceneID: originalSceneID,
                          runID: runID,
                          requiringOriginalBackground: requiringOriginalBackground,
                      )
                else {
                    return false
                }

                result = census
                return true
            }
        } catch {
            if let lastCensus {
                attach(lastCensus, named: "last passive census before new-scene mount timeout")
            }
            throw error
        }

        return try XCTUnwrap(result)
    }

    /// Waits for an operator to move the original scene to background while the new scene
    /// remains foreground active. Each read is passive and newer than the mounted-scene proof.
    private func awaitPhysicalOperatorArrangement(
        in app: XCUIApplication,
        originalSceneID: String,
        runID: String,
        after mountedCensus: SceneCensus,
    ) throws -> SceneCensus {
        var result: SceneCensus?
        var observedCensuses = [mountedCensus]
        let minimumCapture = try XCTUnwrap(Double(mountedCensus.capturedMonotonicSeconds))
        do {
            try wait(
                app,
                milestone: "physical operator scene arrangement (original background, new foreground-active)",
                timeout: physicalOperatorArrangementTimeout,
                enforceDeadline: true,
            ) {
                guard let census = self.passiveSceneCensus(in: app) else {
                    return false
                }

                if observedCensuses.last != census {
                    observedCensuses.append(census)
                }
                guard let capturedAt = Double(census.capturedMonotonicSeconds), capturedAt > minimumCapture,
                      self.hasCoherentMountedScene(
                          census,
                          originalSceneID: originalSceneID,
                          runID: runID,
                          requiringOriginalBackground: true,
                      )
                else {
                    return false
                }

                result = census
                return true
            }
        } catch {
            attach(
                observedCensuses,
                named: "actual UIKit scene activation sequence before operator-arrangement failure",
            )
            throw error
        }

        attach(observedCensuses, named: "actual UIKit scene activation sequence during operator arrangement")
        return try XCTUnwrap(result)
    }

    private func refreshCensus(
        in app: XCUIApplication,
        newerThan minimumCapture: Double,
        milestone: String,
        condition: @escaping @MainActor (SceneCensus) -> Bool,
        includingMinimumCapture: Bool = false,
        enforceDeadline: Bool = false,
    ) throws -> SceneCensus {
        var result: SceneCensus?
        var attempts: [Observation] = []
        do {
            try wait(app, milestone: milestone, enforceDeadline: enforceDeadline) {
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
                      let capturedAt = Double(census.capturedMonotonicSeconds),
                      includingMinimumCapture ? capturedAt >= minimumCapture : capturedAt > minimumCapture,
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

    private var physicalOperatorArrangementEnabled: Bool {
        #if targetEnvironment(simulator)
        false
        #else
        true
        #endif
    }

    private func launchFixture(
        passiveSceneCensus: Bool = false,
        operatorArrangement: Bool = false,
    ) throws -> XCUIApplication {
        let app = XCUIApplication(bundleIdentifier: "com.danielbyon.mediavault.browserdownloadqualificationhost")
        app.launchArguments = [
            "--browser-download-production-qualification",
        ]
        if passiveSceneCensus {
            app.launchArguments.append("--browser-download-passive-scene-census")
        }
        if operatorArrangement {
            app.launchArguments.append("--browser-download-operator-arrangement")
        }
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

    private func passiveSceneCensus(in app: XCUIApplication) -> SceneCensus? {
        let snapshots = app.staticTexts
            .matching(identifier: "downloadQualificationSceneCensus")
            .allElementsBoundByIndex
            .compactMap { $0.value as? String }
            .compactMap { value in
                try? JSONDecoder().decode(SceneCensus.self, from: Data(value.utf8))
            }

        return latestPassiveSceneCensus(in: snapshots)
    }

    private func latestPassiveSceneCensus(in snapshots: [SceneCensus]) -> SceneCensus? {
        let timedSnapshots = snapshots.compactMap { census -> (Double, SceneCensus)? in
            guard let timestamp = Double(census.capturedMonotonicSeconds), timestamp.isFinite else {
                return nil
            }

            return (timestamp, census)
        }
        guard let latestTimestamp = timedSnapshots.map(\.0).max() else {
            return nil
        }

        let latestSnapshots = timedSnapshots.filter { $0.0 == latestTimestamp }.map(\.1)
        guard let first = latestSnapshots.first, latestSnapshots.allSatisfy({ $0 == first }) else {
            return nil
        }

        return first
    }

    private func passiveSceneRequest(in app: XCUIApplication) -> Observation? {
        app.staticTexts
            .matching(identifier: "downloadQualificationSceneRequest")
            .allElementsBoundByIndex
            .compactMap { $0.value as? String }
            .compactMap { value in
                try? JSONDecoder().decode(Observation.self, from: Data(value.utf8))
            }
            .filter { ["sceneRequested", "sceneRequestFailed", "sceneRequestUnsupported"].contains($0["event"] ?? "") }
            .max {
                ($0["monotonicSeconds"].flatMap(Double.init) ?? -1)
                    < ($1["monotonicSeconds"].flatMap(Double.init) ?? -1)
            }
    }

    /// Reads observation JSON from controls in one reachable window.
    ///
    /// Reusing the scope found by the wait avoids a second accessibility query across a scene transition.
    private func observations(_ app: XCUIApplication) throws -> [Observation] {
        if app.launchArguments.contains("--browser-download-passive-scene-census") {
            guard let observations = latestPassiveObservations(in: app) else {
                throw QualificationError.missingObservation
            }

            return observations
        }

        var reachableScope: ControlScope?
        try wait(app, milestone: "qualification observation refresh control") {
            guard let scope = self.hittableScope("downloadQualificationRefreshObservations", in: app) else {
                return false
            }

            reachableScope = scope
            return true
        }
        let scope = try XCTUnwrap(reachableScope)
        scope.button.tap()
        guard let value = scope.window.staticTexts["downloadQualificationObservations"].value as? String else {
            throw QualificationError.missingObservation
        }

        return try JSONDecoder().decode([Observation].self, from: Data(value.utf8))
    }

    private func latestPassiveObservations(in app: XCUIApplication) -> [Observation]? {
        let snapshots = passiveObservationPayloads(in: app)
            .compactMap { value in
                try? JSONDecoder().decode([Observation].self, from: Data(value.utf8))
            }
        let timedSnapshots = snapshots.compactMap { observations -> (Double, [Observation])? in
            guard let timestamp = observations.last?["monotonicSeconds"].flatMap(Double.init), timestamp.isFinite else {
                return nil
            }

            return (timestamp, observations)
        }
        guard let latestTimestamp = timedSnapshots.map(\.0).max() else {
            return nil
        }

        let latestSnapshots = timedSnapshots.filter { $0.0 == latestTimestamp }.map(\.1)
        guard let first = latestSnapshots.first, latestSnapshots.allSatisfy({ $0 == first }) else {
            return nil
        }

        return first
    }

    private func passiveObservationPayloads(in app: XCUIApplication) -> [String] {
        app.staticTexts
            .matching(identifier: "downloadQualificationObservations")
            .allElementsBoundByIndex
            .compactMap { $0.value as? String }
            .reduce(into: [String]()) { values, value in
                if !values.contains(value) {
                    values.append(value)
                }
            }
    }

    /// Returns the latest owner snapshot for the run and generation whose finite timestamp lies
    /// within the inclusive activation-to-census interval. Equal timestamps prefer the later
    /// appended observation so selection remains deterministic.
    private func latestOwnerSnapshot(
        in observations: [Observation],
        runID: String,
        atOrAfter minimumMonotonicSeconds: Double,
        atOrBefore maximumMonotonicSeconds: Double,
        generation: String,
    ) -> Observation? {
        guard minimumMonotonicSeconds.isFinite, maximumMonotonicSeconds.isFinite else {
            return nil
        }

        let candidates = observations.enumerated().compactMap { index, observation -> (Double, Int, Observation)? in
            guard observation["runID"] == runID,
                  observation["event"] == "ownerSnapshot",
                  observation["generation"] == generation,
                  let observedAt = observation["monotonicSeconds"].flatMap({ Double($0) }),
                  observedAt.isFinite,
                  observedAt >= minimumMonotonicSeconds,
                  observedAt <= maximumMonotonicSeconds
            else {
                return nil
            }

            return (observedAt, index, observation)
        }
        return candidates.max { lhs, rhs in
            if lhs.0 == rhs.0 {
                return lhs.1 < rhs.1
            }
            return lhs.0 < rhs.0
        }?.2
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

    private func withinDeadline(
        _ deadline: TimeInterval,
        now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        evaluate: () -> Bool,
    ) -> Bool {
        guard now() < deadline else {
            return false
        }

        return evaluate() && now() < deadline
    }

    private func wait(
        _ app: XCUIApplication,
        milestone: String,
        timeout: TimeInterval = 10,
        enforceDeadline: Bool = false,
        condition: @escaping @MainActor () -> Bool,
    ) throws {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        let predicate = NSPredicate { _, _ in
            MainActor.assumeIsolated {
                enforceDeadline ? self.withinDeadline(deadline, evaluate: condition) : condition()
            }
        }
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: nil)
        let remaining = enforceDeadline ? max(0, deadline - ProcessInfo.processInfo.systemUptime) : timeout
        guard XCTWaiter.wait(for: [expectation], timeout: remaining) == .completed,
              !enforceDeadline || ProcessInfo.processInfo.systemUptime < deadline
        else {
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
