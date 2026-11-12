//
//  VaultEmergencyLockGestureTests.swift
//  MediaVault
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Testing
@testable import VaultFeature

@Suite("Emergency shake recognition")
struct VaultEmergencyLockGestureTests {
    @Test("A shake must exceed the finite acceleration threshold")
    func shakeMustExceedAccelerationThreshold() {
        var classifier = EmergencyLockShakeClassifier()

        let rejectsNonFiniteMagnitude = classifier.recognizes(magnitude: .nan, atUptime: 1)
        let rejectsLowMagnitude = classifier.recognizes(magnitude: 2.49, atUptime: 1)
        let acceptsThresholdMagnitude = classifier.recognizes(magnitude: 2.5, atUptime: 1)

        #expect(!rejectsNonFiniteMagnitude)
        #expect(!rejectsLowMagnitude)
        #expect(acceptsThresholdMagnitude)
    }

    @Test("Repeated samples from one shake are rate limited")
    func repeatedSamplesAreRateLimited() {
        var classifier = EmergencyLockShakeClassifier()

        let firstSampleRecognizes = classifier.recognizes(magnitude: 3, atUptime: 1)
        let repeatWithinCooldownIsIgnored = classifier.recognizes(magnitude: 3, atUptime: 1.9)
        let sampleAfterCooldownRecognizes = classifier.recognizes(magnitude: 3, atUptime: 2)

        #expect(firstSampleRecognizes)
        #expect(!repeatWithinCooldownIsIgnored)
        #expect(sampleAfterCooldownRecognizes)
    }
}
