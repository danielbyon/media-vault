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

    @Test("A physical press without a recognized drag activates only once")
    func physicalPressActivatesOnce() {
        let tabID = BrowserTabID()
        var interaction = BrowserTabCardInteraction()

        interaction.beginPhysicalPress(for: tabID)

        let firstActivation = interaction.consumeSelection(for: tabID)
        let duplicateActivation = interaction.consumeSelection(for: tabID)
        #expect(firstActivation)
        #expect(!duplicateActivation)
    }

    @Test("A duplicate press-began callback cannot reactivate a consumed selection")
    func duplicatePressBeganCannotReactivateConsumedSelection() {
        let tabID = BrowserTabID()
        var interaction = BrowserTabCardInteraction()

        interaction.beginPhysicalPress(for: tabID)
        let firstActivation = interaction.consumeSelection(for: tabID)

        interaction.beginPhysicalPress(for: tabID)
        let duplicateActivation = interaction.consumeSelection(for: tabID)

        interaction.endPhysicalPress(for: tabID)
        interaction.beginPhysicalPress(for: tabID)
        let activationAfterNewPress = interaction.consumeSelection(for: tabID)

        #expect(firstActivation)
        #expect(!duplicateActivation)
        #expect(activationAfterNewPress)
    }

    @Test("Independent accessibility activations do not rearm an active physical press")
    func accessibilityActivationsRemainIndependent() {
        let tabID = BrowserTabID()
        var physicalInteraction = BrowserTabCardInteraction()

        physicalInteraction.beginPhysicalPress(for: tabID)
        let physicalActivation = physicalInteraction.consumeSelection(for: tabID)
        let firstAccessibilityActivation =
            BrowserTabCardInteraction.consumeAccessibilitySelection(for: tabID)
        let secondAccessibilityActivation =
            BrowserTabCardInteraction.consumeAccessibilitySelection(for: tabID)

        physicalInteraction.beginPhysicalPress(for: tabID)
        let repeatedPhysicalActivation = physicalInteraction.consumeSelection(for: tabID)

        #expect(physicalActivation)
        #expect(firstAccessibilityActivation)
        #expect(secondAccessibilityActivation)
        #expect(!repeatedPhysicalActivation)
    }

    @Test("Button release keeps a true tap eligible until its activation runs")
    func releasedPhysicalPressActivatesOnce() {
        let tabID = BrowserTabID()
        var interaction = BrowserTabCardInteraction()
        interaction.beginPhysicalPress(for: tabID)
        interaction.endPhysicalPress(for: tabID)

        let firstActivation = interaction.consumeSelection(for: tabID)
        let duplicateActivation = interaction.consumeSelection(for: tabID)
        #expect(firstActivation)
        #expect(!duplicateActivation)
    }

    @Test("Recognized horizontal swipes at 79 or 80 points cancel without activating")
    func cancelledHorizontalSwipeNeverActivates() {
        for width: CGFloat in [79, -79, 80, -80] {
            let tabID = BrowserTabID()
            var interaction = BrowserTabCardInteraction()
            interaction.beginPhysicalPress(for: tabID)
            interaction.updateDrag(for: tabID, translation: .init(width: width, height: 0))

            #expect(interaction.swipeOutcome(for: tabID, translation: .init(width: width, height: 0)) == .cancel)

            interaction.finishDrag(for: tabID)
            interaction.endPhysicalPress(for: tabID)

            #expect(interaction.drag == nil)
            let selectedAfterCancellation = interaction.consumeSelection(for: tabID)
            #expect(!selectedAfterCancellation)
        }
    }

    @Test("Recognized horizontal swipes at 81 points close without activating")
    func dismissedHorizontalSwipeNeverActivates() {
        for width: CGFloat in [81, -81] {
            let tabID = BrowserTabID()
            var interaction = BrowserTabCardInteraction()
            interaction.beginPhysicalPress(for: tabID)
            interaction.updateDrag(for: tabID, translation: .init(width: width, height: 0))

            #expect(interaction.swipeOutcome(for: tabID, translation: .init(width: width, height: 0)) == .dismiss)

            interaction.finishDrag(for: tabID)
            interaction.endPhysicalPress(for: tabID)

            #expect(interaction.drag == nil)
            let selectedAfterDismissal = interaction.consumeSelection(for: tabID)
            #expect(!selectedAfterDismissal)
        }
    }

    @Test("A canceled swipe does not suppress the next independent press")
    func cancelledSwipeAllowsNextPhysicalPress() {
        let tabID = BrowserTabID()
        var interaction = BrowserTabCardInteraction()
        interaction.beginPhysicalPress(for: tabID)
        interaction.updateDrag(for: tabID, translation: .init(width: 80, height: 0))
        interaction.finishDrag(for: tabID)
        interaction.endPhysicalPress(for: tabID)

        let selectedAfterCancellation = interaction.consumeSelection(for: tabID)
        #expect(!selectedAfterCancellation)

        interaction.beginPhysicalPress(for: tabID)

        let selectedAfterNewPress = interaction.consumeSelection(for: tabID)
        #expect(selectedAfterNewPress)
    }

    @Test("A late Button press callback cannot reclassify a recognized swipe")
    func latePhysicalPressCallbackKeepsDragIneligible() {
        let tabID = BrowserTabID()
        var interaction = BrowserTabCardInteraction()
        interaction.updateDrag(for: tabID, translation: .init(width: 80, height: 0))

        interaction.beginPhysicalPress(for: tabID)
        #expect(interaction.drag?.axis == .horizontal)
        #expect(interaction.swipeOutcome(for: tabID, translation: .init(width: 80, height: 0)) == .cancel)

        interaction.finishDrag(for: tabID)
        interaction.endPhysicalPress(for: tabID)
        let selectedAfterRelease = interaction.consumeSelection(for: tabID)
        #expect(!selectedAfterRelease)

        interaction.beginPhysicalPress(for: tabID)
        let selectedAfterNextPress = interaction.consumeSelection(for: tabID)
        #expect(selectedAfterNextPress)
    }

    @Test("A vertical-dominant drag remains non-dismissive and cannot activate the card")
    func verticalDragDoesNotActivateOrDismiss() {
        let tabID = BrowserTabID()
        var interaction = BrowserTabCardInteraction()
        interaction.beginPhysicalPress(for: tabID)
        interaction.updateDrag(for: tabID, translation: .init(width: 80, height: 81))

        #expect(interaction.drag?.axis == .vertical)
        #expect(interaction.drag?.horizontalTranslation == 0)
        #expect(interaction.swipeOutcome(for: tabID, translation: .init(width: 80, height: 81)) == nil)

        interaction.finishDrag(for: tabID)
        interaction.endPhysicalPress(for: tabID)

        #expect(interaction.drag == nil)
        let selectedAfterVerticalDrag = interaction.consumeSelection(for: tabID)
        #expect(!selectedAfterVerticalDrag)
    }
}
