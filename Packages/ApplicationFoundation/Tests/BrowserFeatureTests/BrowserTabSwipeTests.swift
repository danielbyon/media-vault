//
//  BrowserTabSwipeTests.swift
//  MediaVault
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import CoreGraphics
import Testing
@testable import BrowserFeature

@Suite("Browser tab swipe decisions")
struct BrowserTabSwipeTests {
    @Test("Horizontal axis requires width to strictly dominate height")
    func horizontalAxisRequiresStrictDominance() {
        #expect(BrowserTabSwipe.axis(for: .init(width: 81, height: 80)) == .horizontal)
        #expect(BrowserTabSwipe.axis(for: .init(width: -81, height: 80)) == .horizontal)
        #expect(BrowserTabSwipe.axis(for: .init(width: 80, height: 80)) == .vertical)
        #expect(BrowserTabSwipe.axis(for: .init(width: 79, height: 80)) == .vertical)
        #expect(BrowserTabSwipe.axis(for: .init(width: 0, height: 100)) == .vertical)
    }

    @Test("Horizontal release dismisses only beyond the strict 80-point threshold")
    func horizontalReleaseUsesStrictThreshold() {
        #expect(BrowserTabSwipe.outcome(for: .init(width: 81, height: 0), axis: .horizontal) == .dismiss)
        #expect(BrowserTabSwipe.outcome(for: .init(width: -81, height: 0), axis: .horizontal) == .dismiss)
        #expect(BrowserTabSwipe.outcome(for: .init(width: 80, height: 0), axis: .horizontal) == .cancel)
        #expect(BrowserTabSwipe.outcome(for: .init(width: -80, height: 0), axis: .horizontal) == .cancel)
        #expect(BrowserTabSwipe.outcome(for: .init(width: 79, height: 0), axis: .horizontal) == .cancel)
    }

    @Test("Locked horizontal axis does not switch when the final translation becomes vertical-dominant")
    func lockedHorizontalAxisDoesNotSwitch() {
        #expect(BrowserTabSwipe.outcome(for: .init(width: 81, height: 120), axis: .horizontal) == .dismiss)
        #expect(BrowserTabSwipe.outcome(for: .init(width: 80, height: 120), axis: .horizontal) == .cancel)
    }

    @Test("Vertical-dominant release has no dismissal outcome")
    func verticalReleaseDoesNotDismiss() {
        #expect(BrowserTabSwipe.outcome(for: .init(width: 0, height: 81), axis: .vertical) == nil)
        #expect(BrowserTabSwipe.outcome(for: .init(width: 81, height: 0), axis: .vertical) == nil)
        #expect(BrowserTabSwipe.outcome(for: .init(width: 80, height: 81), axis: .vertical) == nil)
        #expect(BrowserTabSwipe.outcome(for: .init(width: -80, height: 81), axis: .vertical) == nil)
    }
}
