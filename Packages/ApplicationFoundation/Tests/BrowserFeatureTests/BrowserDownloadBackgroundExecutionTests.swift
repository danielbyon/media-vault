//
//  BrowserDownloadBackgroundExecutionTests.swift
//  MediaVault
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Testing
import UIKit
@testable import BrowserFeature

@Suite("Finite download background execution")
@MainActor
struct BrowserDownloadBackgroundExecutionTests {
    @MainActor
    private final class Control {
        var begins = 0
        var ended: [Int] = []
        var expiration: (@MainActor @Sendable () -> Void)?
    }

    @Test
    func expirationEndsOnceWithoutRenewingUnfinishedWork() {
        let control = Control()
        let execution = BrowserDownloadBackgroundExecution(begin: { expiration in
            control.begins += 1
            control.expiration = expiration
            return UIBackgroundTaskIdentifier(rawValue: control.begins)
        }, end: { control.ended.append($0.rawValue) })
        execution.update(hasWork: true)
        execution.update(hasWork: true)
        #expect(control.begins == 1)
        let oldExpiration = control.expiration
        control.expiration?()
        control.expiration?()
        execution.update(hasWork: true)
        #expect(control.begins == 1)
        #expect(control.ended == [1])
        execution.update(hasWork: false)
        #expect(control.ended == [1])
        execution.update(hasWork: true)
        oldExpiration?()
        #expect(control.ended == [1])
        execution.update(hasWork: false)
        #expect(control.begins == 2)
        #expect(control.ended == [1, 2])
    }

    @Test
    func unavailableAssertionDoesNotLoopOrEndInvalidIdentity() {
        let control = Control()
        let execution = BrowserDownloadBackgroundExecution(begin: { _ in
            control.begins += 1
            return .invalid
        }, end: { control.ended.append($0.rawValue) })
        execution.update(hasWork: true)
        execution.update(hasWork: true)
        execution.update(hasWork: false)
        #expect(control.begins == 1)
        #expect(control.ended.isEmpty)
    }

    @Test
    func expirationDuringAcquisitionStillBalancesReturnedAssertion() {
        let control = Control()
        let execution = BrowserDownloadBackgroundExecution(begin: { expiration in
            control.begins += 1
            expiration()
            return UIBackgroundTaskIdentifier(rawValue: 7)
        }, end: { control.ended.append($0.rawValue) })
        execution.update(hasWork: true)
        execution.update(hasWork: true)
        execution.update(hasWork: false)
        #expect(control.begins == 1)
        #expect(control.ended == [7])
    }
}
