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
    private typealias Evidence = BrowserDownloadSceneEvidence
    private typealias Observation = Evidence.Observation
    private typealias SceneCensus = Evidence.SceneCensus
    private typealias ActiveRootTarget = Evidence.ActiveRootTarget

    private let physicalOperatorArrangementTimeout: TimeInterval = 120

    private enum QualificationError: Error {
        case missingSceneCensus
        case missingObservation
        case waitFailed
        case invalidGeometry
    }

    private struct ControlScope {
        let window: XCUIElement
        let button: XCUIElement
    }

    func testRequestCreatesNewMountedWindowGroupScene() throws {
        let app = try launchFixture(passiveSceneCensus: !physicalOperatorArrangementEnabled)
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
        let request = try requestSecondScene(in: app)
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
                guard let (current, events) = Evidence.postRequestSceneEvidence(
                    runID: runID,
                    requestedAt: requestedAt,
                    readCensus: { self.passiveSceneCensus(in: app) },
                    readLedger: { try? self.observations(app) },
                ) else {
                    return false
                }

                latestCensus = current
                postRequest = events
                removalObserved = removalObserved || Evidence.recordedRemoval(
                    of: retainedAllocation,
                    in: postRequest,
                    runID: runID,
                )
                let denied = Evidence.retainedOwnerIsRevoked(
                    in: current,
                    observations: postRequest,
                    atOrAfter: requestedAt,
                )
                confirmed = Evidence.confirmedRoots(in: current, observations: postRequest, target: target)
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

    func testPassiveAccessibilityReadsRefreshCensusWithoutPublishingRootEvents() async throws {
        let app = try launchFixture(passiveSceneCensus: true)
        defer { app.terminate() }
        var baseline: SceneCensus?
        try wait(app, milestone: "initial confirmed Root before passive reads") {
            guard let census = self.passiveSceneCensus(in: app),
                  let latest = census.latestCoordinatorObservations.first,
                  let sceneID = latest["sceneSession"], let runID = latest["runID"],
                  let confirmed = Evidence.liveConfirmedRoots(in: census, sceneID: sceneID, runID: runID, atOrAfter: 0),
                  confirmed.allSatisfy({ callback in
                      census.rootLayoutObservations.contains { layout in
                          layout["runID"] == runID && layout["sceneSession"] == sceneID
                              && layout["registration"] == callback["registration"]
                              && layout["generation"] == callback["generation"]
                              && layout["renderRevision"] == callback["renderRevision"]
                              && Evidence.coordinatorObservationIsSafeRoot(layout)
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
            guard let census = passiveSceneCensus(in: app), let root = Evidence.liveRoots(in: census, runID: run)?[id],
                  root.safe, expectedRevision == nil || root.revision == expectedRevision,
                  let callback = census.latestCoordinatorObservations.first, callback["registration"] == id,
                  callback["renderRevision"] == String(root.revision), callback["generation"] == root.generation,
                  Evidence.coordinatorObservationIsSafeRoot(callback) else {
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
        let previous = try XCTUnwrap(Evidence.liveRoots(in: before, runID: run)?[id])
        let nextRevision = previous.revision + 1

        update.tap()
        let value = try XCTUnwrap(app.staticTexts["downloadQualificationRootUpdateCensus"].firstMatch.value as? String)
        let pending = try JSONDecoder().decode(SceneCensus.self, from: Data(value.utf8))
        let pendingRoot = try XCTUnwrap(Evidence.liveRoots(in: pending, runID: run)?[id])
        XCTAssertEqual(pendingRoot.revision, nextRevision)
        XCTAssertEqual(pendingRoot.generation, previous.generation)
        XCTAssertFalse(pendingRoot.safe)
        XCTAssertEqual(pending.liveRegisteredRoots?.first?["renderConfirmed"], "false")
        XCTAssertEqual(pending.liveRegisteredRoots?.first?["rootProof"], "false")
        let lastCallback = try XCTUnwrap(pending.latestCoordinatorObservations.first)
        XCTAssertEqual(lastCallback["registration"], id)
        XCTAssertEqual(lastCallback["renderRevision"], String(previous.revision))
        XCTAssertEqual(lastCallback["generation"], previous.generation)
        XCTAssertTrue(Evidence.coordinatorObservationIsSafeRoot(lastCallback))
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
            Evidence.uniqueNewActiveScene(before, baselineSessionIDs: baselineSessionIDs, runID: runID),
            "The resize precondition requires exactly one active, mounted scene created by the request.",
        )
        let (_, preResizeRoot) = try XCTUnwrap(
            Evidence.activeSceneSafeRoot(in: before, for: active.sessionID, runID: runID),
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
                ["description": Evidence.diagnosticValue { app.debugDescription }],
                named: "resize handle timeout application accessibility evidence",
            )
            attach(
                ["description": Evidence.diagnosticValue { springboard.debugDescription }],
                named: "resize handle timeout SpringBoard accessibility evidence",
            )
            attach(
                [
                    "cardExists": Evidence.diagnosticValue { String(card.exists) },
                    "cardHittable": Evidence.diagnosticValue { String(card.isHittable) },
                    "grabberExists": Evidence.diagnosticValue { String(grabber.exists) },
                    "grabberHittable": Evidence.diagnosticValue { String(grabber.isHittable) },
                    "grabberFrame": Evidence.diagnosticValue { String(describing: grabber.frame) },
                ],
                named: "resize handle timeout accessibility evidence",
            )
            throw error
        }
        let reportedGrabberFrame = grabber.frame
        let cardFrame = card.frame
        let applicationFrame = app.frame
        guard let screenBounds = Evidence.parsedRect(active.screenBounds) else {
            attach(
                ["screenBounds": active.screenBounds, "sceneBounds": active.bounds],
                named: "unparseable screen coordinates; no gesture performed",
            )
            XCTFail("The active scene's screen bounds must be parseable.")
            throw QualificationError.invalidGeometry
        }
        guard let grabberFrame = Evidence.normalizedResizeHandleFrame(
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
            Evidence.resizeGestureMarker(
                in: (try? self.observations(app)) ?? [],
                sceneID: active.sessionID,
                registration: registration,
                runID: runID,
            ) != nil
        }
        let currentObservations = try observations(app)
        let marker = try XCTUnwrap(Evidence.resizeGestureMarker(
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
            Evidence.resizeGestureDelta(
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
                witnessFailure = Evidence.resizedSceneWitnessFailure(
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
                Evidence
                    .liveConfirmedRoots(in: $0, sceneID: originalSceneID, runID: runID, atOrAfter: requestedAt) != nil
            },
            includingMinimumCapture: true,
            enforceDeadline: true,
        )
        attach(census, named: "actual original session reactivation with safe Root")
        let censusCapturedAt = try XCTUnwrap(Double(census.capturedMonotonicSeconds))
        let finalSafeRootGeneration = try XCTUnwrap(Evidence.finalCensusSafeRootGeneration(
            in: census,
            originalSceneID: originalSceneID,
            runID: runID,
            atOrAfter: requestedAt,
        ))
        let owner = try XCTUnwrap(census.ownerSnapshot)
        let currentObservations = try observations(app)
        let activation = try XCTUnwrap(Evidence.finalSceneActivation(
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
        let allRegisteredScenesActive = Evidence.registeredSceneActivationsAreForegroundActive(
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
        XCTAssertFalse(Evidence.recordedRemoval(of: retainedAllocation, in: currentObservations, runID: runID))
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

    private func requestSecondScene(in app: XCUIApplication) throws -> Observation {
        try wait(app, milestone: "second-scene request control") {
            self.hittableButton("downloadQualificationRequestSecondScene", in: app) != nil
        }
        try XCTUnwrap(hittableButton("downloadQualificationRequestSecondScene", in: app)).tap()

        if app.launchArguments.contains("--browser-download-passive-scene-census") {
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
                guard let newScene = Evidence.uniqueNewActiveScene(
                    $0,
                    baselineSessionIDs: baselineSessionIDs,
                    runID: runID,
                ) else {
                    return false
                }

                return !requiringActiveSceneSafeRoot
                    || Evidence.activeSceneSafeRoot(in: $0, for: newScene.sessionID, runID: runID) != nil
            },
            includingMinimumCapture: true,
        )
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
                      Evidence.hasCoherentMountedScene(
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
                      Evidence.hasCoherentMountedScene(
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
        let passive = usesPassiveCensus(in: app)
        var latest: SceneCensus?
        var attempts: [Observation] = []
        do {
            try wait(app, milestone: milestone, enforceDeadline: enforceDeadline) {
                latest = passive
                    ? self.passiveSceneCensus(in: app)
                    : self.captureOperatorCensus(in: app, attempts: &attempts)
                guard let census = latest, let capturedAt = Double(census.capturedMonotonicSeconds),
                      capturedAt.isFinite,
                      includingMinimumCapture ? capturedAt >= minimumCapture : capturedAt > minimumCapture
                else {
                    return false
                }

                return condition(census)
            }
        } catch {
            if passive {
                if let latest {
                    attach(latest, named: "last observed census: " + milestone)
                }
            } else {
                attach(attempts, named: "all failed census captures paired with refresh window: " + milestone)
            }
            throw error
        }
        return try XCTUnwrap(latest)
    }

    private func captureOperatorCensus(in app: XCUIApplication, attempts: inout [Observation]) -> SceneCensus? {
        guard let scope = hittableScope("downloadQualificationRefreshSceneCensus", in: app) else {
            return nil
        }

        scope.button.tap()
        let raw = scope.window.staticTexts["downloadQualificationSceneCensus"].value as? String
        attempts.append([
            "windowFrame": String(describing: scope.window.frame),
            "buttonFrame": String(describing: scope.button.frame),
            "buttonHittable": String(scope.button.isHittable),
            "census": raw ?? "missingValue",
        ])
        return raw.flatMap { try? JSONDecoder().decode(SceneCensus.self, from: Data($0.utf8)) }
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
            guard let census = self.sceneCensus(app, captureForOperator: true) else {
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

    /// Operator-assisted runs use the capture button to preserve a durable census with the gesture.
    private func usesPassiveCensus(in app: XCUIApplication) -> Bool {
        app.launchArguments.contains("--browser-download-passive-scene-census")
            && !app.launchArguments.contains("--browser-download-operator-arrangement")
    }

    private func sceneCensus(_ app: XCUIApplication, captureForOperator: Bool = false) -> SceneCensus? {
        if usesPassiveCensus(in: app) {
            return passiveSceneCensus(in: app)
        }
        guard let scope = hittableScope("downloadQualificationRefreshSceneCensus", in: app) else {
            return nil
        }

        if captureForOperator {
            scope.button.tap()
        }
        guard let value = scope.window.staticTexts["downloadQualificationSceneCensus"].value as? String else {
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

        return Evidence.latestPassiveSceneCensus(in: snapshots)
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
        timeout: TimeInterval = 10,
        enforceDeadline: Bool = false,
        condition: @escaping @MainActor () -> Bool,
    ) throws {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        let predicate = NSPredicate { _, _ in
            MainActor.assumeIsolated {
                enforceDeadline ? Evidence.withinDeadline(deadline, evaluate: condition) : condition()
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
