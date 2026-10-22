//
//  BrowserDownloadSecuritySentinelLifecycleTests.swift
//  MediaVault
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import XCTest

/// Pure regression coverage for the qualification-only contracts shared by the standalone
/// download security qualification host and this `BrowserTabOverviewUITests` bundle.
///
/// The cases below exercise lifecycle transitions and cleanup classifications only. They never
/// post protected-data notifications, never drive a device lock, and never claim protected-data
/// qualification; the locked-read denial behavior still requires the qualification host on a
/// physical device.
final class BrowserDownloadSecuritySentinelLifecycleTests: XCTestCase {
    /// A lifecycle that has passed its first successful preparation.
    private func armedLifecycle() -> BrowserDownloadSecuritySentinelLifecycle {
        var lifecycle = BrowserDownloadSecuritySentinelLifecycle()
        XCTAssertEqual(lifecycle.prepare(), .accepted)
        XCTAssertEqual(lifecycle.finishPreparation(evidence: .verified), .armed)
        XCTAssertEqual(lifecycle.state, .armed)
        return lifecycle
    }

    /// A lifecycle that recorded one gated locked read and reached the completed classification.
    private func completedLifecycle() -> BrowserDownloadSecuritySentinelLifecycle {
        var lifecycle = armedLifecycle()
        XCTAssertEqual(lifecycle.observeLockWindow(), .accepted)
        XCTAssertEqual(lifecycle.recordLockedAttempt(), .accepted)
        XCTAssertEqual(lifecycle.beginUnlockRecovery(), .accepted(requiresInconclusiveAttempt: false))
        XCTAssertTrue(lifecycle.finishUnlockRecovery(succeeded: true))
        XCTAssertEqual(lifecycle.state, .terminal(.completed))
        return lifecycle
    }

    func testFirstPrepareIsAcceptedAndDuplicateWhileArmedIsRefused() {
        var lifecycle = armedLifecycle()
        XCTAssertEqual(lifecycle.prepare(), .refusedCycleAlreadyUsed)
        XCTAssertEqual(lifecycle.state, .armed, "A refused preparation must not disturb the begun cycle")
        XCTAssertEqual(lifecycle.prepare(), .refusedCycleAlreadyUsed)
        XCTAssertEqual(lifecycle.state, .armed, "A refused preparation can never re-arm the cycle")
    }

    func testPreparationFailureConsumesTheCycleAndRejectsLaterEvents() {
        var lifecycle = BrowserDownloadSecuritySentinelLifecycle()
        XCTAssertEqual(lifecycle.prepare(), .accepted)
        XCTAssertEqual(
            lifecycle.finishPreparation(evidence: .missingMarker),
            .terminalFailure(.removeMarkerAndRetireResources),
        )
        XCTAssertEqual(lifecycle.state, .terminal(.preparationFailed))
        XCTAssertEqual(lifecycle.prepare(), .refusedCycleAlreadyUsed)
        XCTAssertEqual(lifecycle.observeLockWindow(), .ignored)
        XCTAssertEqual(lifecycle.beginUnlockRecovery(), .ignored)
    }

    func testInconclusiveEndBeforeLockConsumesTheCycleAndRejectsLaterLock() {
        var lifecycle = armedLifecycle()
        XCTAssertEqual(
            lifecycle.recordInconclusiveLockedAttempt(),
            .terminal(.removeMarkerAndRetireResources),
        )
        XCTAssertEqual(lifecycle.state, .terminal(.lockWindowInconclusive))
        XCTAssertEqual(lifecycle.observeLockWindow(), .ignored)
        XCTAssertEqual(lifecycle.beginUnlockRecovery(), .ignored)
        XCTAssertEqual(lifecycle.prepare(), .refusedCycleAlreadyUsed)
    }

    func testPreparationRequiresEveryVerifiedArmingPrerequisite() {
        let incompleteEvidence: [BrowserDownloadSecuritySentinelLifecycle.PreparationEvidence] = [
            .missingMarker,
            .missingUnlockedRead,
            .missingCompleteProtection,
            .missingBackupExclusion,
            .missingBackgroundAssertion,
        ]

        for evidence in incompleteEvidence {
            var lifecycle = BrowserDownloadSecuritySentinelLifecycle()
            XCTAssertEqual(lifecycle.prepare(), .accepted)
            XCTAssertEqual(
                lifecycle.finishPreparation(evidence: evidence),
                .terminalFailure(.removeMarkerAndRetireResources),
            )
            XCTAssertEqual(lifecycle.state, .terminal(.preparationFailed))
            XCTAssertEqual(lifecycle.observeLockWindow(), .ignored)
        }

        var verified = BrowserDownloadSecuritySentinelLifecycle()
        XCTAssertEqual(verified.prepare(), .accepted)
        XCTAssertEqual(verified.finishPreparation(evidence: .verified), .armed)
        XCTAssertEqual(verified.state, .armed)
    }

    func testLockWindowOpensOnceAndDuplicateObservationsAreIgnored() {
        var lifecycle = armedLifecycle()
        XCTAssertEqual(lifecycle.observeLockWindow(), .accepted)
        XCTAssertEqual(lifecycle.state, .lockWindow)
        XCTAssertEqual(lifecycle.observeLockWindow(), .ignored)
        XCTAssertEqual(lifecycle.state, .lockWindow)
        XCTAssertEqual(lifecycle.recordLockedAttempt(), .accepted)
        XCTAssertEqual(lifecycle.state, .lockedAttempt)
        XCTAssertEqual(lifecycle.observeLockWindow(), .ignored)
        XCTAssertEqual(lifecycle.state, .lockedAttempt)
    }

    func testTerminalStateRefusesPrepareAndIgnoresLateLockAndUnlockTransitions() {
        var lifecycle = completedLifecycle()
        XCTAssertEqual(lifecycle.prepare(), .refusedCycleAlreadyUsed)
        XCTAssertEqual(lifecycle.observeLockWindow(), .ignored)
        XCTAssertEqual(lifecycle.recordLockedAttempt(), .ignored)
        XCTAssertEqual(lifecycle.beginUnlockRecovery(), .ignored)
        XCTAssertFalse(lifecycle.finishUnlockRecovery(succeeded: false))
        XCTAssertEqual(lifecycle.state, .terminal(.completed))
    }

    func testTerminalClassificationIsImmutableForBothOutcomes() {
        var completed = completedLifecycle()
        XCTAssertFalse(completed.finishUnlockRecovery(succeeded: false))
        XCTAssertEqual(completed.state, .terminal(.completed))

        var failed = armedLifecycle()
        XCTAssertEqual(failed.beginUnlockRecovery(), .accepted(requiresInconclusiveAttempt: true))
        XCTAssertTrue(failed.finishUnlockRecovery(succeeded: false))
        XCTAssertEqual(failed.state, .terminal(.unlockFailed))
        XCTAssertEqual(failed.beginUnlockRecovery(), .ignored)
        XCTAssertFalse(failed.finishUnlockRecovery(succeeded: true))
        XCTAssertEqual(failed.state, .terminal(.unlockFailed))
    }

    func testUnlockWithoutAGatedReadRequiresInconclusiveAttemptRecord() {
        var armed = armedLifecycle()
        XCTAssertEqual(armed.beginUnlockRecovery(), .accepted(requiresInconclusiveAttempt: true))
        XCTAssertTrue(armed.finishUnlockRecovery(succeeded: true))
        XCTAssertEqual(armed.state, .terminal(.completed))

        var window = armedLifecycle()
        XCTAssertEqual(window.observeLockWindow(), .accepted)
        XCTAssertEqual(window.beginUnlockRecovery(), .accepted(requiresInconclusiveAttempt: true))
    }

    func testInconclusiveLockedAttemptIsRecordedAtMostOncePerCycle() {
        var lifecycle = armedLifecycle()
        XCTAssertEqual(
            lifecycle.recordInconclusiveLockedAttempt(),
            .terminal(.removeMarkerAndRetireResources),
        )
        XCTAssertEqual(lifecycle.recordInconclusiveLockedAttempt(), .ignored)
        XCTAssertEqual(lifecycle.state, .terminal(.lockWindowInconclusive))
        XCTAssertEqual(lifecycle.beginUnlockRecovery(), .ignored)
        XCTAssertEqual(
            lifecycle.recordInconclusiveLockedAttempt(),
            .ignored,
            "A terminal INCONCLUSIVE cycle must not append a second attempt record",
        )
        XCTAssertFalse(lifecycle.finishUnlockRecovery(succeeded: true))
        XCTAssertEqual(
            lifecycle.recordInconclusiveLockedAttempt(),
            .ignored,
            "A terminal cycle accepts no new attempt evidence",
        )
    }

    func testInconclusiveAttemptCanBeRecordedAfterRecoveryStarts() {
        var lifecycle = armedLifecycle()
        XCTAssertEqual(lifecycle.beginUnlockRecovery(), .accepted(requiresInconclusiveAttempt: true))
        XCTAssertEqual(lifecycle.recordInconclusiveLockedAttempt(), .recoveryContinues)
        XCTAssertEqual(lifecycle.recordInconclusiveLockedAttempt(), .ignored)
        XCTAssertTrue(lifecycle.finishUnlockRecovery(succeeded: true))
        XCTAssertEqual(lifecycle.state, .terminal(.completed))
    }

    func testQueuedExpirationAfterLockedAttemptPreservesUnlockRecovery() {
        var lifecycle = armedLifecycle()
        XCTAssertEqual(lifecycle.observeLockWindow(), .accepted)
        XCTAssertEqual(lifecycle.recordLockedAttempt(), .accepted)

        XCTAssertEqual(lifecycle.recordInconclusiveLockedAttempt(), .ignored)
        XCTAssertEqual(lifecycle.state, .lockedAttempt)
        XCTAssertEqual(lifecycle.beginUnlockRecovery(), .accepted(requiresInconclusiveAttempt: false))
        XCTAssertTrue(lifecycle.finishUnlockRecovery(succeeded: true))
        XCTAssertEqual(lifecycle.state, .terminal(.completed))
    }

    func testTerminalCleanupReportsSuccessfulMarkerRemovalAndRetiresResources() {
        var removalCount = 0
        var retirementCount = 0

        let result = BrowserDownloadSecuritySentinelTerminalCleanup.perform(
            removeMarker: {
                removalCount += 1
                return .removed
            },
            retireResources: {
                retirementCount += 1
            },
        )

        XCTAssertEqual(result, .completed)
        XCTAssertEqual(removalCount, 1)
        XCTAssertEqual(retirementCount, 1)
    }

    func testTerminalCleanupReportsMarkerRemovalFailureAndStillRetiresResources() {
        var removalCount = 0
        var retirementCount = 0

        let result = BrowserDownloadSecuritySentinelTerminalCleanup.perform(
            removeMarker: {
                removalCount += 1
                return .failed
            },
            retireResources: {
                retirementCount += 1
            },
        )

        XCTAssertEqual(result, .markerRemovalFailed)
        XCTAssertEqual(removalCount, 1)
        XCTAssertEqual(retirementCount, 1)
    }

    func testPrepareRefusalPresentationPreservesArmedAndTerminalStages() {
        for stage in ["armed", "terminalCleanupFailedRelaunchRequired"] {
            XCTAssertEqual(
                BrowserDownloadSecuritySentinelPreparationRefusal(
                    decision: .refusedCycleAlreadyUsed,
                    currentStage: stage,
                ),
                BrowserDownloadSecuritySentinelPreparationRefusal(preservedStage: stage),
            )
        }
        XCTAssertNil(
            BrowserDownloadSecuritySentinelPreparationRefusal(
                decision: .accepted,
                currentStage: "idle",
            ),
        )
    }

    func testLockedQualificationObservationDetectsCleanupFailureBeforeRecovery() {
        let recovery = [
            "event": "securitySentinelUnlockedRecovery",
            "sentinelRemoved": "false",
        ]
        let cleanupFailure = [
            "event": "securitySentinelTerminalCleanupFailed",
            "stage": "terminalCleanupFailed",
            "markerRemoved": "false",
            "relaunchRequired": "true",
            "path": "/must-not-propagate",
        ]
        let noAttempt = [
            "event": "securitySentinelLockedAttempt",
            "freshOpenAttempted": "false",
            "inconclusiveReason": "suspendedBeforeDenialAttempt",
        ]

        XCTAssertEqual(
            BrowserDownloadLockedQualificationObservationOutcome(
                observations: [recovery, noAttempt, cleanupFailure],
            ),
            .terminalCleanupFailed(
                .init(
                    stage: "terminalCleanupFailed",
                    markerRemoved: "false",
                    relaunchRequired: "true",
                ),
            ),
        )
    }

    func testLockedQualificationObservationClassifiesUnreadableSurface() {
        XCTAssertEqual(
            BrowserDownloadLockedQualificationObservationOutcome(observations: nil),
            .observationSurfaceUnreadable,
        )
    }

    func testLockedQualificationObservationClassifiesDecodedNoAttemptEvidence() {
        let noAttempt = [
            "event": "securitySentinelLockedAttempt",
            "freshOpenAttempted": "false",
            "inconclusiveReason": "suspendedBeforeDenialAttempt",
        ]
        XCTAssertEqual(
            BrowserDownloadLockedQualificationObservationOutcome(observations: [noAttempt]),
            .inconclusiveNoAttempt(
                .init(
                    freshOpenAttempted: "false",
                    reason: "suspendedBeforeDenialAttempt",
                ),
            ),
        )
    }

    func testLockedQualificationObservationDistinguishesDecodedWaitingFromRecovery() {
        XCTAssertEqual(
            BrowserDownloadLockedQualificationObservationOutcome(observations: []),
            .waiting,
        )

        let recovery = [
            "event": "securitySentinelUnlockedRecovery",
            "sentinelRemoved": "true",
        ]
        XCTAssertEqual(
            BrowserDownloadLockedQualificationObservationOutcome(observations: [recovery]),
            .recovered(recovery),
        )
    }
}

/// Pure regression coverage for the cold-relaunch cleanup attribution classifier.
final class BrowserDownloadCleanupAttributionTests: XCTestCase {
    func testUnavailableOrMissingOperationClassifiesMissingCorrelation() {
        for expectedOperation in [nil, "unavailable"] as [String?] {
            XCTAssertEqual(
                BrowserDownloadStartupInspectionClassification(
                    expectedOperation: expectedOperation,
                    expectedPresent: nil,
                ),
                .inconclusive(.expectedOperationUnavailable),
            )
        }
    }

    func testConcreteOperationRemainsCorrelatedForMandatoryEqualityAssertion() {
        XCTAssertEqual(
            BrowserDownloadStartupInspectionClassification(
                expectedOperation: "different-operation",
                expectedPresent: "true",
            ),
            .correlated(
                expectedOperation: "different-operation",
                cleanupAttribution: .verifiedRemoval,
            ),
            "A concrete mismatch must reach the UI test's same-allocation assertion, not skip",
        )
    }

    func testExpectedPresentTrueClassifiesVerifiedRemoval() {
        XCTAssertEqual(BrowserDownloadCleanupAttribution(expectedPresent: "true"), .verifiedRemoval)
    }

    func testExpectedPresentFalseIsInconclusiveAndCannotClaimVerifiedRemoval() {
        let attribution = BrowserDownloadCleanupAttribution(expectedPresent: "false")
        XCTAssertEqual(attribution, .inconclusive(.expectedPresentFalse))
        XCTAssertNotEqual(attribution, .verifiedRemoval)
    }

    func testMissingExpectedPresentIsInconclusiveAndNotDescribedAsFalse() {
        let attribution = BrowserDownloadCleanupAttribution(expectedPresent: nil)
        XCTAssertEqual(attribution, .inconclusive(.expectedPresentMissing))
        XCTAssertNotEqual(attribution, .verifiedRemoval)
        let description = BrowserDownloadCleanupInconclusiveReason.expectedPresentMissing.qualificationDescription
        XCTAssertFalse(
            description.contains("false"),
            "Missing presence evidence must not use the expectedPresent=false wording",
        )
        XCTAssertFalse(
            description.contains("operation correlation"),
            "Concrete expectedOperation is classified separately from missing expectedPresent",
        )
        XCTAssertTrue(description.contains("whether the correlated allocation was present"))
    }

    func testExplicitFalseDescriptionNamesTheReportedValue() {
        let description = BrowserDownloadCleanupInconclusiveReason.expectedPresentFalse.qualificationDescription
        XCTAssertTrue(description.contains("expectedPresent=false"))
    }

    func testUnrecognizedExpectedPresentValuesAreInconclusiveLikeMissing() {
        for value in ["TRUE", "true ", " true", "1", "", "yes"] {
            XCTAssertEqual(
                BrowserDownloadCleanupAttribution(expectedPresent: value),
                .inconclusive(.expectedPresentMissing),
                "Value \(value.debugDescription) must not be treated as an implicit truthy report",
            )
        }
    }
}
