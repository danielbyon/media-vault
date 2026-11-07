//
//  ScenePrivacyCoverPolicyTests.swift
//  MediaVault
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Testing
@testable import PresentationSupport

@Suite("Scene privacy cover policy")
struct ScenePrivacyCoverPolicyTests {
    @Test("An active scene follows caller coverage updates")
    func activeSceneFollowsCallerCoverageUpdates() {
        var policy = ScenePrivacyCoverPolicy(isCoveredByCaller: true, isSceneActive: true)

        #expect(policy.shouldShowCover)

        policy.update(isCoveredByCaller: false)

        #expect(!policy.shouldShowCover)
    }

    @Test("A validated update after activation reveals the scene")
    func validatedUpdateAfterActivationRevealsScene() {
        var policy = ScenePrivacyCoverPolicy(isCoveredByCaller: false, isSceneActive: true)

        policy.sceneWillDeactivate()
        #expect(policy.shouldShowCover)

        policy.update(isCoveredByCaller: true)
        policy.sceneDidActivate()
        #expect(policy.shouldShowCover)

        policy.update(isCoveredByCaller: false)

        #expect(!policy.shouldShowCover)
    }

    @Test("Coverage reported before deactivation acknowledges the transition")
    func coverageBeforeDeactivationAcknowledgesTransition() {
        var policy = ScenePrivacyCoverPolicy(isCoveredByCaller: false, isSceneActive: true)

        policy.update(isCoveredByCaller: true)
        policy.sceneWillDeactivate()
        policy.sceneDidActivate()

        #expect(policy.shouldShowCover)

        policy.update(isCoveredByCaller: false)

        #expect(!policy.shouldShowCover)
    }

    @Test("A stale uncovered update cannot reveal without coverage acknowledgement")
    func staleUncoveredUpdateNeedsCoverageAcknowledgement() {
        var policy = ScenePrivacyCoverPolicy(isCoveredByCaller: false, isSceneActive: true)

        policy.sceneWillDeactivate()
        policy.update(isCoveredByCaller: false)
        policy.sceneDidActivate()

        #expect(policy.shouldShowCover)

        policy.update(isCoveredByCaller: true)
        #expect(policy.shouldShowCover)

        policy.update(isCoveredByCaller: false)

        #expect(!policy.shouldShowCover)
    }

    @Test("A validated update before activation reveals only after activation")
    func validatedUpdateBeforeActivationWaitsForActivation() {
        var policy = ScenePrivacyCoverPolicy(isCoveredByCaller: false, isSceneActive: true)

        policy.sceneWillDeactivate()
        policy.update(isCoveredByCaller: true)
        policy.update(isCoveredByCaller: false)

        #expect(policy.shouldShowCover)

        policy.sceneDidActivate()

        #expect(!policy.shouldShowCover)
    }

    @Test("An initially inactive covered scene waits for activation after validation")
    func initiallyInactiveSceneWaitsForActivation() {
        var policy = ScenePrivacyCoverPolicy(isCoveredByCaller: true, isSceneActive: false)

        #expect(policy.shouldShowCover)

        policy.update(isCoveredByCaller: false)

        #expect(policy.shouldShowCover)

        policy.sceneDidActivate()

        #expect(!policy.shouldShowCover)
    }
}
