//
//  BrowserDownloadSceneEvidenceTests.swift
//  MediaVault
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import CoreFoundation
import CoreGraphics
import Foundation
import XCTest

final class BrowserDownloadSceneEvidenceTests: XCTestCase {
    private typealias Evidence = BrowserDownloadSceneEvidence
    private typealias Observation = Evidence.Observation
    private typealias SceneCensus = Evidence.SceneCensus
    private typealias ActiveRootTarget = Evidence.ActiveRootTarget
    private typealias WindowScene = Evidence.WindowScene
    private typealias SceneWindow = Evidence.SceneWindow

    private let sampleRunID = "ABF518D2-AF57-4890-913B-654CF8F43649"

    private let sampleRegistration = "7F95FA75-B735-458B-A170-C018C70BCD96"

    private enum DiagnosticReadError: Error {
        case unavailable
    }

    func testResizeHandleNormalizesMeasuredRotatedFrame() throws {
        let container = CGRect(x: 0, y: 0, width: 1_133, height: 744)
        let screen = CGRect(x: 0, y: 0, width: 1_133, height: 744)
        let reported = CGRect(x: -20, y: 1_113, width: 40, height: 40)

        let normalized = try XCTUnwrap(
            Evidence.normalizedResizeHandleFrame(reported: reported, container: container, screenBounds: screen),
        )
        XCTAssertEqual(normalized, CGRect(x: 1_113, y: 724, width: 40, height: 40))
        XCTAssertEqual(
            normalized.intersection(container),
            CGRect(x: 1_113, y: 724, width: 20, height: 20),
        )

        let direct = CGRect(x: 1_100, y: 700, width: 40, height: 40)
        XCTAssertEqual(
            Evidence.normalizedResizeHandleFrame(reported: direct, container: container, screenBounds: screen),
            direct,
            "A directly intersecting frame must remain unchanged.",
        )
    }

    func testResizeHandleRejectsUnrelatedOffscreenFrame() {
        let container = CGRect(x: 0, y: 0, width: 1_133, height: 744)
        let unrelated = CGRect(x: 500, y: 1_000, width: 40, height: 40)

        XCTAssertNil(Evidence.normalizedResizeHandleFrame(
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

        XCTAssertNil(Evidence.normalizedResizeHandleFrame(
            reported: grabber,
            container: application,
            screenBounds: screen,
        ))
        XCTAssertEqual(
            Evidence.normalizedResizeHandleFrame(reported: grabber, container: card, screenBounds: screen),
            grabber,
        )
        let visible = grabber.intersection(card)
        XCTAssertEqual(visible, CGRect(x: 835, y: 601, width: 20, height: 20))
        XCTAssertEqual(CGPoint(x: visible.midX, y: visible.midY), CGPoint(x: 845, y: 611))

        let rotated = CGRect(x: 103, y: 835, width: 40, height: 40)
        XCTAssertEqual(
            Evidence.normalizedResizeHandleFrame(reported: rotated, container: card, screenBounds: screen),
            CGRect(x: 835, y: 601, width: 40, height: 40),
        )
        XCTAssertNil(Evidence.normalizedResizeHandleFrame(
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
            Evidence.resizeGestureDelta(from: start, container: card, screenBounds: screen),
        )

        XCTAssertEqual(delta.dx, 93.75, accuracy: 0.0001)
        XCTAssertEqual(delta.dy, -123.5, accuracy: 0.0001)
    }

    func testResizeGestureDeltaShrinksFullScreenCardOnBothAxes() throws {
        let screen = CGRect(x: 0, y: 0, width: 1_133, height: 744)
        let start = CGPoint(x: 1_120, y: 720)

        let delta = try XCTUnwrap(
            Evidence.resizeGestureDelta(from: start, container: screen, screenBounds: screen),
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

        XCTAssertEqual(Evidence.selectedVisibleKeyedSceneWindow(in: scene)?.key, "true")
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

        XCTAssertNil(Evidence.selectedVisibleKeyedSceneWindow(in: scene))
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
        XCTAssertNil(Evidence.selectedVisibleKeyedSceneWindow(in: noKeyed))

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
        XCTAssertNil(Evidence.selectedVisibleKeyedSceneWindow(in: multipleKeyed))
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
            Evidence.uniqueNewActiveScene(
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
        XCTAssertNil(Evidence.uniqueNewActiveScene(
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
        XCTAssertNil(Evidence.uniqueNewActiveScene(
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
        XCTAssertNil(Evidence.uniqueNewActiveScene(
            census([old, newBackground], observations: [mountedNew]),
            baselineSessionIDs: baseline,
            runID: "RUN",
        ))
    }

    func testResizeTimeoutDiagnosticsReadOptionalValuesIndependently() {
        var attempted: [String] = []
        let unavailable = Evidence.diagnosticValue {
            attempted.append("grabberFrame")
            throw DiagnosticReadError.unavailable
        }
        let available = Evidence.diagnosticValue {
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

        XCTAssertEqual(Evidence.latestPassiveSceneCensus(in: [older, newer]), newer)
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

        XCTAssertNil(Evidence.latestPassiveSceneCensus(in: [first, conflicting]))
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
            Evidence.hasCoherentMountedScene(
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
            Evidence.liveConfirmedRoots(in: sample, sceneID: "OLD", runID: sampleRunID, atOrAfter: 20)
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
        XCTAssertNil(Evidence.confirmedRoots(in: target.initial, observations: [confirmed], target: target))
        XCTAssertEqual(Evidence.confirmedRoots(in: fresh, observations: [confirmed], target: target), [confirmed])
    }

    func testPassiveRootRejectsCachedConfirmationAfterLiveRevisionAdvances() {
        let cached = passiveRootObservation(["renderRevision": "10"])
        var census = passiveRootCensus([cached])
        XCTAssertEqual(Evidence.confirmedRoots(in: census, observations: [cached], target: pendingRootTarget), [cached])
        census.liveRegisteredRoots = [liveRootObservation(cached, changes: [
            "renderRevision": "11",
            "renderConfirmed": "false",
            "rootProof": "false",
        ])]
        XCTAssertNil(Evidence.confirmedRoots(in: census, observations: [cached], target: pendingRootTarget))
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
            XCTAssertNil(Evidence.confirmedRoots(in: census, observations: [callback], target: pendingRootTarget))
        }
        for change in changes {
            census.liveRegisteredRoots = [liveRootObservation(callback, changes: change)]
            XCTAssertNil(
                Evidence.confirmedRoots(in: census, observations: [callback], target: pendingRootTarget),
                "\(change)",
            )
        }
        for key in live.keys {
            census.liveRegisteredRoots = [live.filter { $0.key != key }]
            XCTAssertNil(Evidence.confirmedRoots(in: census, observations: [callback], target: pendingRootTarget), key)
        }
        let outside = passiveRootObservation(["registration": otherRegistration])
        let single = passiveRootCensus([callback])
        XCTAssertNil(Evidence.confirmedRoots(in: single, observations: [callback, outside], target: pendingRootTarget))
        let duplicates = passiveRootCensus([callback, callback])
        XCTAssertNil(Evidence.confirmedRoots(in: duplicates, observations: [callback], target: pendingRootTarget))
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
        XCTAssertTrue(Evidence.retainedOwnerIsRevoked(in: census, observations: events, atOrAfter: 20))
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
            XCTAssertFalse(
                Evidence.retainedOwnerIsRevoked(in: census, observations: events, atOrAfter: 20),
                "\(change)",
            )
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
            XCTAssertTrue(Evidence.recordedRemoval(of: "retained", in: events, runID: sampleRunID))
            XCTAssertFalse(Evidence.recordedRemoval(of: "another", in: events, runID: sampleRunID))
            XCTAssertFalse(Evidence.recordedRemoval(of: "retained", in: events, runID: "earlier run"))
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
            let sample = try XCTUnwrap(Evidence.postRequestSceneEvidence(
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
            XCTAssertEqual(
                Evidence.recordedRemoval(of: "retained", in: sample.events, runID: sampleRunID),
                rejects,
                timestamp,
            )
        }
    }

    func testPassiveRootRejectsMissingOrMismatchedConfirmation() {
        let target = pendingRootTarget
        let confirmed = passiveRootObservation()
        let fresh = passiveRootCensus([confirmed])
        XCTAssertNil(Evidence.confirmedRoots(in: fresh, observations: [], target: target))
        for change in [["runID": "OTHER"], ["sceneSession": "OTHER"], ["registration": "OTHER"]] {
            let unrelated = passiveRootObservation(change)
            XCTAssertNil(Evidence.confirmedRoots(
                in: passiveRootCensus([unrelated]),
                observations: [unrelated],
                target: target,
            ))
            XCTAssertNil(Evidence.confirmedRoots(in: fresh, observations: [unrelated], target: target))
        }
        let pending = passiveRootObservation(["rootProof": "false"])
        XCTAssertNil(Evidence.confirmedRoots(in: passiveRootCensus([pending]), observations: [pending], target: target))
        XCTAssertNil(Evidence.confirmedRoots(
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
        XCTAssertNil(Evidence.confirmedRoots(in: fresh, observations: [unsafe, confirmed], target: target))
        XCTAssertNil(Evidence.confirmedRoots(
            in: passiveRootCensus([unsafe, confirmed]),
            observations: [confirmed],
            target: target,
        ))
        let old = passiveRootObservation(["monotonicSeconds": "18"])
        XCTAssertNil(Evidence.confirmedRoots(in: passiveRootCensus([old]), observations: [old], target: target))
        let newer = passiveRootObservation(["monotonicSeconds": "21.5"])
        XCTAssertNil(Evidence.confirmedRoots(in: fresh, observations: [newer], target: target))
        let future = passiveRootObservation(["monotonicSeconds": "23"])
        XCTAssertNil(Evidence.confirmedRoots(in: passiveRootCensus([future]), observations: [future], target: target))
    }

    func testPassiveRootRequiresCoverAndNativeBarrierAbsence() {
        let target = pendingRootTarget
        let confirmed = passiveRootObservation()
        XCTAssertNil(Evidence.confirmedRoots(
            in: passiveRootCensus([confirmed], cover: true),
            observations: [confirmed],
            target: target,
        ))
        for change in [["coverVisible": "true"], ["nativeBarrier": "true"], ["mounted": "false"], ["generation": "2"]] {
            let blocked = passiveRootObservation(change)
            XCTAssertNil(Evidence.confirmedRoots(
                in: passiveRootCensus([blocked]),
                observations: [blocked],
                target: target,
            ))
        }
    }

    func testPassiveRootRequiresProofBeforeOriginalDeadline() {
        var now = 9.0
        func evaluate(endingAt time: Double) -> Bool {
            Evidence.withinDeadline(10, now: { now }) {
                now = time
                return true
            }
        }
        XCTAssertTrue(evaluate(endingAt: 9.5))
        XCTAssertFalse(evaluate(endingAt: 10))
        XCTAssertFalse(Evidence.withinDeadline(10, now: { now }) {
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
            XCTAssertFalse(Evidence.withinDeadline(deadline, now: { time }) {
                Evidence.confirmedRoots(in: census, observations: [cached], target: pendingRootTarget) != nil
            })
        }
        census.liveRegisteredRoots = [liveRootObservation(cached)]
        XCTAssertFalse(Evidence.withinDeadline(deadline, now: { deadline }) {
            Evidence.confirmedRoots(in: census, observations: [cached], target: pendingRootTarget) != nil
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
        XCTAssertNil(Evidence.latestFreshSafeRoots(
            in: [safeB, laterBarrierA, safeA],
            sceneID: "SCENE",
            registrations: ["A", "B"],
            runID: "RUN",
            atOrAfter: 10,
        ))

        let laterSafeA = observation(registration: "A", at: "13", safe: true)
        XCTAssertEqual(
            try Set(XCTUnwrap(Evidence.latestFreshSafeRoots(
                in: [safeB, laterBarrierA, safeA, laterSafeA],
                sceneID: "SCENE",
                registrations: ["A", "B"],
                runID: "RUN",
                atOrAfter: 10,
            )).compactMap { $0["registration"] }),
            ["A", "B"],
        )

        let equalTimestampBarrierA = observation(registration: "A", at: "13", safe: false)
        XCTAssertNil(Evidence.latestFreshSafeRoots(
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

        let activation = try XCTUnwrap(Evidence.finalSceneActivation(
            in: [earlierActivation, finalActivation, ownerSnapshot],
            originalSceneID: "ORIGINAL",
            runID: "RUN",
            after: 9.0,
        ))
        let generation = try XCTUnwrap(Evidence.finalCensusSafeRootGeneration(
            in: census,
            originalSceneID: "ORIGINAL",
            runID: "RUN",
            atOrAfter: 9.0,
        ))
        let owner = try XCTUnwrap(Evidence.latestOwnerSnapshot(
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
        XCTAssertTrue(Evidence.registeredSceneActivationsAreForegroundActive(
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

        XCTAssertNotNil(Evidence.finalSceneActivation(
            in: [activation, ownerSnapshot],
            originalSceneID: "ORIGINAL",
            runID: "RUN",
            after: 9.0,
        ))
        XCTAssertNil(Evidence.latestOwnerSnapshot(
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

        XCTAssertNil(Evidence.latestOwnerSnapshot(
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

        XCTAssertNil(Evidence.latestOwnerSnapshot(
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

        XCTAssertNil(Evidence.finalCensusSafeRootGeneration(
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

        XCTAssertNil(Evidence.finalCensusSafeRootGeneration(
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

        XCTAssertNotNil(Evidence.finalSceneActivation(
            in: [activation, ownerSnapshot],
            originalSceneID: "ORIGINAL",
            runID: "RUN",
            after: 9.0,
        ))
        XCTAssertNil(Evidence.latestOwnerSnapshot(
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
            Evidence.latestOwnerSnapshot(
                in: [atActivation],
                runID: "RUN",
                atOrAfter: 10.0,
                atOrBefore: 12.0,
                generation: "7",
            ),
            atActivation,
        )
        XCTAssertEqual(
            Evidence.latestOwnerSnapshot(
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

        XCTAssertNil(Evidence.latestOwnerSnapshot(
            in: [infiniteOwnerSnapshot],
            runID: "RUN",
            atOrAfter: 10.0,
            atOrBefore: 12.0,
            generation: "7",
        ))
        XCTAssertNil(Evidence.latestOwnerSnapshot(
            in: [notANumberOwnerSnapshot],
            runID: "RUN",
            atOrAfter: 10.0,
            atOrBefore: 12.0,
            generation: "7",
        ))
        XCTAssertNil(Evidence.latestOwnerSnapshot(
            in: [ownerSnapshot],
            runID: "RUN",
            atOrAfter: .infinity,
            atOrBefore: 12.0,
            generation: "7",
        ))
        XCTAssertNil(Evidence.latestOwnerSnapshot(
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
            Evidence.latestOwnerSnapshot(
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
        let expectedAvailability = Evidence.registeredSceneActivationsAreForegroundActive(
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
            Evidence.resizeGestureMarker(
                in: observations,
                sceneID: "NEW",
                registration: "NEW-REGISTRATION",
                runID: "RUN",
            )?["runID"],
            "RUN",
        )
        XCTAssertNil(Evidence.resizeGestureMarker(
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
            Evidence.resizedSceneWitnessFailure(
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
            Evidence.resizedSceneWitnessFailure(
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
            Evidence.resizedSceneWitnessFailure(
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
            Evidence.resizedSceneWitnessFailure(
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
            Evidence.resizedSceneWitnessFailure(
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
            Evidence.resizedSceneWitnessFailure(
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
            Evidence.resizedSceneWitnessFailure(
                resizeCensus(window: rootMismatch),
                activeSceneID: "SCENE",
                baselineBounds: "(0.0, 0.0, 1133.0, 744.0)",
            ),
            "the loaded root view bounds do not match the resized scene bounds",
        )
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
}

@MainActor
final class BrowserDownloadQualificationHostStateTests: XCTestCase {
    private let processNonce = UUID()

    func testActiveRootKeepsObservationEligibleWithInactiveRoot() {
        let activity = BrowserDownloadQualificationSceneActivity()
        let activeRoot = BrowserDownloadQualificationSceneRegistration()
        let inactiveRoot = BrowserDownloadQualificationSceneRegistration()

        XCTAssertEqual(activity.register(registration: activeRoot, active: true), true)
        XCTAssertEqual(activity.register(registration: inactiveRoot, active: false), false)

        XCTAssertTrue(activity.isObservationEligible)
        XCTAssertEqual(activity.isActive(registration: activeRoot), true)
        XCTAssertEqual(activity.isActive(registration: inactiveRoot), false)
    }

    func testDeactivatingOneRootPreservesAnotherActiveRoot() {
        let activity = BrowserDownloadQualificationSceneActivity()
        let firstRoot = BrowserDownloadQualificationSceneRegistration()
        let secondRoot = BrowserDownloadQualificationSceneRegistration()

        XCTAssertEqual(activity.register(registration: firstRoot, active: true), true)
        XCTAssertEqual(activity.register(registration: secondRoot, active: true), false)

        XCTAssertEqual(activity.setActive(false, registration: firstRoot), false)

        XCTAssertFalse(activity.isActive(registration: firstRoot) ?? true)
        XCTAssertEqual(activity.isActive(registration: secondRoot), true)
        XCTAssertTrue(activity.isObservationEligible)
    }

    func testAllInactiveRootsDisableObservationEligibility() {
        let activity = BrowserDownloadQualificationSceneActivity()
        let activeRoot = BrowserDownloadQualificationSceneRegistration()
        let inactiveRoot = BrowserDownloadQualificationSceneRegistration()

        XCTAssertEqual(activity.register(registration: activeRoot, active: true), true)
        XCTAssertEqual(activity.register(registration: inactiveRoot, active: false), false)
        XCTAssertEqual(activity.setActive(false, registration: activeRoot), true)

        XCTAssertFalse(activity.isObservationEligible)
    }

    func testRemovingActiveRootDisablesEligibilityAndRemovesItsState() {
        let activity = BrowserDownloadQualificationSceneActivity()
        let activeRoot = BrowserDownloadQualificationSceneRegistration()
        let inactiveRoot = BrowserDownloadQualificationSceneRegistration()

        XCTAssertEqual(activity.register(registration: activeRoot, active: true), true)
        XCTAssertEqual(activity.register(registration: inactiveRoot, active: false), false)
        XCTAssertEqual(activity.disconnect(registration: activeRoot), true)

        XCTAssertFalse(activity.isObservationEligible)
        XCTAssertNil(activity.isActive(registration: activeRoot))
    }

    func testRotatedUnregisteredRootCallbackDoesNotPreemptRegistration() {
        var events: [String] = []
        let activity = BrowserDownloadQualificationSceneActivity { events.append("library") }
        let originalRegistration = BrowserDownloadQualificationSceneRegistration()
        let rotatedRegistration = BrowserDownloadQualificationSceneRegistration()

        XCTAssertNotEqual(originalRegistration.rootID, rotatedRegistration.rootID)
        XCTAssertEqual(activity.register(registration: originalRegistration, active: true), true)
        XCTAssertTrue(activity.disconnect(registration: originalRegistration))
        XCTAssertEqual(events, ["library"])

        XCTAssertNil(activity.setActive(true, registration: rotatedRegistration))
        XCTAssertNil(
            activity.applyPhaseChange(
                active: true,
                registration: rotatedRegistration,
                applyApplicationPhase: { events.append("phase:rotated-root") },
            ),
        )
        XCTAssertEqual(events, ["library"])
        XCTAssertNil(activity.isActive(registration: rotatedRegistration))
        XCTAssertFalse(activity.isObservationEligible)
        XCTAssertNil(activity.register(registration: originalRegistration, active: true))
        XCTAssertNil(activity.setActive(false, registration: originalRegistration))

        XCTAssertEqual(activity.register(registration: rotatedRegistration, active: true), true)
        XCTAssertTrue(activity.isObservationEligible)
    }

    func testPhaseCallbackBeforeAppearanceCannotOverrideCurrentRegisteredPhase() {
        let activity = BrowserDownloadQualificationSceneActivity()
        let registration = BrowserDownloadQualificationSceneRegistration()

        XCTAssertNil(activity.setActive(true, registration: registration))
        XCTAssertEqual(activity.register(registration: registration, active: false), false)
        XCTAssertEqual(activity.isActive(registration: registration), false)
        XCTAssertFalse(activity.isObservationEligible)

        XCTAssertEqual(activity.setActive(true, registration: registration), true)
        XCTAssertEqual(activity.isActive(registration: registration), true)
        XCTAssertTrue(activity.isObservationEligible)
    }

    func testDisconnectedRootCannotRegisterOrChangeActivityAgain() {
        let activity = BrowserDownloadQualificationSceneActivity()
        let disconnectedRoot = BrowserDownloadQualificationSceneRegistration()
        let currentRoot = BrowserDownloadQualificationSceneRegistration()

        XCTAssertEqual(activity.register(registration: disconnectedRoot, active: true), true)
        XCTAssertTrue(activity.disconnect(registration: disconnectedRoot))
        XCTAssertNil(activity.register(registration: disconnectedRoot, active: true))
        XCTAssertNil(activity.setActive(true, registration: disconnectedRoot))

        XCTAssertEqual(activity.register(registration: currentRoot, active: true), true)
        XCTAssertNil(activity.setActive(false, registration: disconnectedRoot))
        XCTAssertEqual(activity.isActive(registration: currentRoot), true)
        XCTAssertTrue(activity.isObservationEligible)
    }

    func testObservationEligibilityChangesOnlyAtFirstAndLastActiveRoot() {
        let activity = BrowserDownloadQualificationSceneActivity()
        let firstRoot = BrowserDownloadQualificationSceneRegistration()
        let secondRoot = BrowserDownloadQualificationSceneRegistration()

        XCTAssertFalse(activity.isObservationEligible)
        XCTAssertEqual(activity.register(registration: firstRoot, active: false), false)
        XCTAssertEqual(activity.setActive(true, registration: firstRoot), true)
        XCTAssertEqual(activity.register(registration: secondRoot, active: true), false)
        XCTAssertEqual(activity.setActive(false, registration: firstRoot), false)
        XCTAssertEqual(activity.setActive(false, registration: secondRoot), true)
        XCTAssertFalse(activity.isObservationEligible)
    }

    func testFirstAndLastActiveRootTransitionsRefreshLibrarySampling() {
        var events: [String] = []
        let activity = BrowserDownloadQualificationSceneActivity { events.append("library") }
        let firstRoot = BrowserDownloadQualificationSceneRegistration()
        let secondRoot = BrowserDownloadQualificationSceneRegistration()

        XCTAssertNotEqual(firstRoot.rootID, secondRoot.rootID)
        XCTAssertEqual(activity.register(registration: firstRoot, active: false), false)
        XCTAssertTrue(events.isEmpty)

        XCTAssertEqual(
            activity.applyPhaseChange(
                active: true,
                registration: firstRoot,
                applyApplicationPhase: { events.append("phase:first-active") },
            ),
            true,
        )
        XCTAssertEqual(events, ["phase:first-active", "library"])

        XCTAssertEqual(activity.register(registration: secondRoot, active: true), false)
        XCTAssertEqual(events, ["phase:first-active", "library"])

        XCTAssertEqual(
            activity.applyPhaseChange(
                active: false,
                registration: firstRoot,
                applyApplicationPhase: { events.append("phase:one-root-remains") },
            ),
            false,
        )
        XCTAssertEqual(
            events,
            ["phase:first-active", "library", "phase:one-root-remains"],
        )

        XCTAssertEqual(
            activity.applyPhaseChange(
                active: false,
                registration: secondRoot,
                applyApplicationPhase: { events.append("phase:last-active") },
            ),
            true,
        )
        XCTAssertEqual(
            events,
            [
                "phase:first-active",
                "library",
                "phase:one-root-remains",
                "phase:last-active",
                "library",
            ],
        )
    }

    func testDisconnectingLastActiveRootInvalidatesLibrarySampling() {
        var events: [String] = []
        let activity = BrowserDownloadQualificationSceneActivity { events.append("library") }
        let registration = BrowserDownloadQualificationSceneRegistration()

        XCTAssertEqual(activity.register(registration: registration, active: false), false)
        XCTAssertEqual(
            activity.applyPhaseChange(
                active: true,
                registration: registration,
                applyApplicationPhase: { events.append("phase:root-active") },
            ),
            true,
        )
        XCTAssertEqual(events, ["phase:root-active", "library"])

        XCTAssertTrue(activity.disconnect(registration: registration))
        XCTAssertEqual(events, ["phase:root-active", "library", "library"])
        XCTAssertFalse(activity.isObservationEligible)
        XCTAssertNil(activity.setActive(true, registration: registration))
        XCTAssertEqual(events, ["phase:root-active", "library", "library"])
    }

    func testStaleStorageSuccessCannotEnableReadsForCurrentContext() {
        var storage = BrowserDownloadStorageObservationState()
        let earlierContext = observationContext(phaseRevision: 1)
        let currentContext = observationContext(phaseRevision: 2)

        XCTAssertTrue(storage.record(available: true, from: earlierContext, current: earlierContext))
        XCTAssertFalse(storage.isAvailable(in: currentContext))
        XCTAssertFalse(storage.record(available: true, from: earlierContext, current: currentContext))

        XCTAssertFalse(storage.isAvailable(in: currentContext))
        XCTAssertTrue(storage.isAvailable(in: earlierContext))
    }

    func testLockedLibraryReadCanStartAfterStaleStorageSuccess() {
        var storage = BrowserDownloadStorageObservationState()
        let capturedContext = observationContext(phaseRevision: 0, authorizationGeneration: 1)
        let currentContext = observationContext(phaseRevision: 0, authorizationGeneration: 2)
        let activity = BrowserDownloadQualificationSceneActivity()
        let root = BrowserDownloadQualificationSceneRegistration()
        _ = activity.register(registration: root, active: false)

        XCTAssertFalse(storage.record(available: true, from: capturedContext, current: currentContext))
        XCTAssertFalse(storage.isAvailable(in: currentContext))
        XCTAssertEqual(activity.setActive(true, registration: root), true)
        XCTAssertTrue(activity.isObservationEligible)
        XCTAssertTrue(storage.permitsLibraryRead(in: currentContext))
    }

    func testRecoveryAllowsSameKeyLockedReadAfterUnavailableOutcome() {
        XCTAssertTrue(
            BrowserDownloadStorageObservationState.shouldRetryAfterRecovery(
                phase: "locked",
                inspectionInFlight: false,
                outcome: .unavailable,
            ),
        )
        XCTAssertFalse(
            BrowserDownloadStorageObservationState.shouldRetryAfterRecovery(
                phase: "locked",
                inspectionInFlight: false,
                outcome: .complete,
            ),
        )
    }

    func testRecoveryAllowsSameKeyLockedReadWhenPriorInspectionIsInFlight() {
        XCTAssertTrue(
            BrowserDownloadStorageObservationState.shouldRetryAfterRecovery(
                phase: "locked",
                inspectionInFlight: true,
                outcome: nil,
            ),
        )
        XCTAssertFalse(
            BrowserDownloadStorageObservationState.shouldRetryAfterRecovery(
                phase: "authenticated",
                inspectionInFlight: true,
                outcome: nil,
            ),
        )
    }

    func testAuthenticatedLibraryReadRequiresCurrentStorageSuccess() {
        var storage = BrowserDownloadStorageObservationState()
        let earlier = observationContext(phaseRevision: 0, phase: "authenticated")
        let current = observationContext(phaseRevision: 0, authorizationGeneration: 2, phase: "authenticated")

        XCTAssertFalse(storage.permitsLibraryRead(in: current))
        XCTAssertFalse(storage.record(available: true, from: earlier, current: current))
        XCTAssertFalse(storage.permitsLibraryRead(in: current))
        XCTAssertTrue(storage.record(available: true, from: current, current: current))
        XCTAssertTrue(storage.permitsLibraryRead(in: current))
    }

    func testStaleStorageFailureCannotInvalidateNewerSuccess() {
        var storage = BrowserDownloadStorageObservationState()
        let earlierContext = observationContext(phaseRevision: 1)
        let currentContext = observationContext(phaseRevision: 2)

        XCTAssertTrue(storage.record(available: true, from: currentContext, current: currentContext))
        XCTAssertFalse(storage.record(available: false, from: earlierContext, current: currentContext))

        XCTAssertTrue(storage.isAvailable(in: currentContext))
    }

    func testContextChangeDoesNotInheritPriorStorageAvailability() {
        var storage = BrowserDownloadStorageObservationState()
        let originalContext = observationContext(phaseRevision: 1)
        let changedContext = observationContext(phaseRevision: 2)

        XCTAssertTrue(storage.record(available: true, from: originalContext, current: originalContext))

        XCTAssertFalse(storage.isAvailable(in: changedContext))
    }

    func testCurrentContextStorageSuccessEnablesReads() {
        var storage = BrowserDownloadStorageObservationState()
        let context = observationContext(phaseRevision: 1)

        XCTAssertTrue(storage.record(available: true, from: context, current: context))

        XCTAssertTrue(storage.isAvailable(in: context))
    }

    func testCurrentContextStorageFailureDisablesReads() {
        var storage = BrowserDownloadStorageObservationState()
        let context = observationContext(phaseRevision: 1)

        XCTAssertTrue(storage.record(available: true, from: context, current: context))
        XCTAssertTrue(storage.record(available: false, from: context, current: context))

        XCTAssertFalse(storage.isAvailable(in: context))
    }

    private func observationContext(
        phaseRevision: UInt64,
        authorizationGeneration: UInt64 = 1,
        phase: String = "locked",
    ) -> BrowserDownloadObservationContext {
        BrowserDownloadObservationContext(
            processNonce: processNonce,
            runID: "qualification-host-state-test",
            authorizationGeneration: authorizationGeneration,
            resourceGeneration: 2,
            ingestionGeneration: 3,
            phase: phase,
            phaseRevision: phaseRevision,
        )
    }
}
