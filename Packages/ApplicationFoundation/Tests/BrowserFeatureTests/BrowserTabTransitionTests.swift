//
//  BrowserTabTransitionTests.swift
//  MediaVault
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
import UIKit
@testable import BrowserFeature

@Suite("Browser tab preview transitions", .serialized)
@MainActor
struct BrowserTabTransitionTests {
    @Test("Transition surface roles distinguish exact page and preview boundaries")
    func transitionSurfaceRolesAreTabScoped() {
        let tabID = BrowserTabID()
        #expect(BrowserTabTransitionSurfaceRole.content(tabID) != .card(tabID))
        #expect(BrowserTabTransitionSurfaceRole.content(tabID) == .content(tabID))
    }

    @Test("Destination layout notifications stay separate from surface lifecycle changes")
    func destinationLayoutNotificationDoesNotPublishSurfaceChange() {
        let registry = BrowserTabTransitionSurfaceRegistry()
        var surfaceChangeCount = 0
        var destinationLayoutChangeCount = 0
        registry.onChange = { surfaceChangeCount += 1 }
        registry.onDestinationLayoutChange = { destinationLayoutChangeCount += 1 }

        registry.notifyLayoutChanged()

        #expect(surfaceChangeCount == 0)
        #expect(destinationLayoutChangeCount == 1)
    }

    @Test("Preview revisions are equality tokens rather than ordered sequence numbers")
    func previewRevisionsUseOpaqueEquality() {
        let first = BrowserTabPreviewRevision()
        let second = BrowserTabPreviewRevision()
        let copy = first

        #expect(first == copy)
        #expect(first != second)
    }

    @Test("Viewport geometry preserves the measured layout bounds")
    func viewportGeometryPreservesMeasuredLayoutBounds() {
        let compact = BrowserContentViewportGeometry(size: CGSize(width: 390, height: 706))
        let regular = BrowserContentViewportGeometry(size: CGSize(width: 1_194, height: 790))

        #expect(compact.aspectRatio < 1)
        #expect(regular.aspectRatio > 1)
        #expect(compact != regular)
    }

    @Test("The registered content boundary reports its actual aspect ratio")
    func registeredBoundaryAspectRatioIsAuthoritative() {
        let tabID = BrowserTabID()
        let registry = BrowserTabTransitionSurfaceRegistry()
        let content = UIView(frame: CGRect(x: 0, y: 0, width: 200, height: 400))

        registry.register(content, for: .content(tabID))

        #expect(registry.aspectRatio(for: .content(tabID)) == 0.5)
    }

    @Test("Live boundary registration preserves identity and display-turn readiness")
    func liveBoundaryRegistrationPreservesReadiness() {
        let harness = BrowserTabTransitionUIKitHarness(
            contentFrame: CGRect(x: 20, y: 70, width: 200, height: 400),
            cardFrame: CGRect(x: 60, y: 320, width: 100, height: 200),
            registerContentInitially: false,
        )

        harness.registry.register(
            harness.content,
            for: .content(harness.tabID),
            representation: .live,
            isReady: false,
        )
        #expect(harness.registry.view(for: .content(harness.tabID)) === harness.content)
        #expect(harness.registry.representation(for: .content(harness.tabID)) == .live)
        #expect(harness.registry.isReady(for: .content(harness.tabID)) == false)

        harness.registry.markReady(harness.content, for: .content(harness.tabID))
        #expect(harness.registry.isReady(for: .content(harness.tabID)))

        harness.registry.register(
            harness.content,
            for: .content(harness.tabID),
            representation: .live,
            isReady: false,
        )
        #expect(harness.registry.isReady(for: .content(harness.tabID)))
        harness.window.isHidden = true
    }

    @Test("Fallback representations remain specific to each logical tab content")
    func fallbackRepresentationsAreContentSpecific() throws {
        let url = try #require(URL(string: "https://example.com"))

        #expect(
            BrowserTabPreviewRepresentation.fallback(for: .startPage(id: BrowserTabID()))
                == .placeholder(.startPage),
        )
        #expect(
            BrowserTabPreviewRepresentation.fallback(for: .web(id: BrowserTabID(), url: url))
                == .placeholder(.web),
        )
        #expect(
            BrowserTabPreviewRepresentation.fallback(
                for: .init(id: BrowserTabID(), content: .error(.serverNotFound(url))),
            ) == .placeholder(.error),
        )
        #expect(
            BrowserTabPreviewRepresentation.fallback(
                for: .init(id: BrowserTabID(), content: .terminated(lastCommittedURL: url)),
            ) == .placeholder(.terminated),
        )
    }

    @Test("Preview transitions resolve card and viewport corner endpoints")
    func transitionCornerEndpoints() {
        let entering = BrowserTabTransitionPresentation(direction: .toOverview)
        #expect(entering.sourceCornerRadius == BrowserTabTransitionPresentation.viewportCornerRadius)
        #expect(entering.destinationCornerRadius == BrowserTabTransitionPresentation.cardCornerRadius)

        let leaving = BrowserTabTransitionPresentation(direction: .toBrowsing)
        #expect(leaving.sourceCornerRadius == BrowserTabTransitionPresentation.cardCornerRadius)
        #expect(leaving.destinationCornerRadius == BrowserTabTransitionPresentation.viewportCornerRadius)
    }

    @Test("UIKit coordinator clones before state change, parks the same clone, and resizes it")
    func uikitCoordinatorUsesOneCloneThroughParkAndResize() async {
        var executions: [BrowserTabTransitionExecution] = []
        var animator: UIViewPropertyAnimator?
        let harness = BrowserTabTransitionUIKitHarness(
            contentFrame: CGRect(x: 20, y: 70, width: 200, height: 400),
            cardFrame: CGRect(x: 60, y: 320, width: 100, height: 200),
            diagnostics: .init(
                onExecution: { executions.append($0) },
                onAnimatorCreated: { animator = $0 },
            ),
        )
        var sawSynchronousClone = false
        var enteredOverview = false
        let tabID = harness.tabID

        harness.coordinator.begin(
            token: 1,
            direction: .toOverview,
            tabID: tabID,
            reduceMotion: false,
            onPresentationChange: {
                sawSynchronousClone = harness.overlay.subviews.count == 1
                harness.registerCard()
            },
            onCompletion: { enteredOverview = true },
        )

        #expect(sawSynchronousClone)
        let clone = harness.overlay.subviews.first
        await harness.waitForAnimation()

        #expect(enteredOverview)
        #expect(executions.contains(.geometry))
        #expect(abs((animator?.duration ?? 0) - 0.22) < 0.001)
        #expect(clone?.superview === harness.card)
        #expect(clone?.frame == harness.card.bounds)

        harness.card.frame = CGRect(x: 40, y: 300, width: 150, height: 300)
        harness.rootViewController.view.layoutIfNeeded()
        harness.registerCard()
        await harness.waitForLayout()

        #expect(clone?.superview === harness.card)
        #expect(clone?.frame == harness.card.bounds)

        var sawSameCloneOnReverse = false
        var sawDestinationReveal = false
        var exitedOverview = false
        harness.coordinator.begin(
            token: 2,
            direction: .toBrowsing,
            tabID: tabID,
            reduceMotion: false,
            onPresentationChange: {
                sawSameCloneOnReverse = harness.overlay.subviews.first === clone
                harness.registerContent()
            },
            onCompletion: { exitedOverview = true },
            onDestinationVisible: {
                sawDestinationReveal = clone?.superview === harness.overlay
            },
        )

        #expect(sawSameCloneOnReverse)
        await harness.waitForAnimation()
        #expect(exitedOverview)
        #expect(sawDestinationReveal)
        #expect(clone?.superview == nil)
    }

    @Test("A live content boundary transforms in place without an overlay clone")
    func uikitCoordinatorTransformsLiveContentInPlace() async throws {
        var animator: UIViewPropertyAnimator?
        let harness = BrowserTabTransitionUIKitHarness(
            contentFrame: CGRect(x: 20, y: 70, width: 200, height: 400),
            cardFrame: CGRect(x: 60, y: 320, width: 100, height: 200),
            contentRepresentation: .live,
            diagnostics: .init(onAnimatorCreated: { animator = $0 }),
        )
        var completed = false

        harness.coordinator.begin(
            token: 1,
            direction: .toOverview,
            tabID: harness.tabID,
            reduceMotion: false,
            onPresentationChange: { harness.registerCard() },
            onCompletion: { completed = true },
        )

        #expect(harness.overlay.subviews.isEmpty)
        let transitionAnimator = try #require(animator)
        #expect(abs(transitionAnimator.duration - 0.22) < 0.001)
        transitionAnimator.pauseAnimation()
        transitionAnimator.fractionComplete = 0.5
        await harness.waitForLayout()

        #expect(harness.content.superview === harness.rootViewController.view)
        #expect(harness.content.window != nil)
        #expect(harness.content.transform != .identity)

        transitionAnimator.stopAnimation(false)
        transitionAnimator.finishAnimation(at: .end)
        await harness.waitForLayout()

        #expect(completed)
        #expect(harness.content.superview === harness.rootViewController.view)
        #expect(harness.content.transform == .identity)
        harness.window.isHidden = true
    }

    @Test("Unavailable destination presentation aborts without revealing a blank surface")
    func uikitCoordinatorAbortsWhenDestinationPresentationUnavailable() {
        var completed = false
        var revertedToOverview = false
        var events: [BrowserTabTransitionEvent] = []
        let harness = BrowserTabTransitionUIKitHarness(
            contentFrame: CGRect(x: 20, y: 70, width: 200, height: 400),
            cardFrame: CGRect(x: 60, y: 320, width: 100, height: 200),
            registerContentInitially: false,
            diagnostics: .init(onEvent: { events.append($0) }),
        )

        harness.coordinator.begin(
            token: 1,
            direction: .toBrowsing,
            tabID: harness.tabID,
            reduceMotion: false,
            onPresentationChange: {
                harness.registry.register(
                    harness.content,
                    for: .content(harness.tabID),
                    isReady: false,
                )
            },
            onCompletion: { completed = true },
            onPresentationUnavailable: { revertedToOverview = true },
        )

        #expect(harness.coordinator.isActive)
        #expect(harness.overlay.subviews.count == 1)

        harness.registry.report(.targetPresentationUnavailable(harness.tabID))

        #expect(events.contains(.targetPresentationUnavailable(harness.tabID)))
        #expect(completed)
        #expect(revertedToOverview)
        #expect(harness.coordinator.isActive == false)
        #expect(harness.overlay.subviews.isEmpty)
        #expect(events.contains(.geometryAnimatorCreated(harness.tabID)) == false)
        #expect(events.contains(.destinationRevealed(harness.tabID)) == false)
        harness.window.isHidden = true
    }

    @Test("Destination presentation failure is scoped to the active transition tab")
    func destinationPresentationFailureOnlyAbortsTheActiveTabTransition() {
        var completed = false
        let unrelatedTabID = BrowserTabID()
        let harness = BrowserTabTransitionUIKitHarness(
            contentFrame: CGRect(x: 20, y: 70, width: 200, height: 400),
            cardFrame: CGRect(x: 60, y: 320, width: 100, height: 200),
            registerContentInitially: false,
        )

        harness.coordinator.begin(
            token: 1,
            direction: .toBrowsing,
            tabID: harness.tabID,
            reduceMotion: false,
            onPresentationChange: {
                harness.registry.register(
                    harness.content,
                    for: .content(harness.tabID),
                    isReady: false,
                )
            },
            onCompletion: { completed = true },
        )

        harness.registry.report(.targetPresentationUnavailable(unrelatedTabID))

        #expect(harness.coordinator.isActive)
        #expect(completed == false)

        harness.registry.report(.targetPresentationUnavailable(harness.tabID))

        #expect(harness.coordinator.isActive == false)
        #expect(completed)
        harness.window.isHidden = true
    }

    @Test("The real property animator keeps one clone between endpoints mid-transition")
    func uikitCoordinatorKeepsCloneInOverlayAtMidAnimation() async throws {
        var animator: UIViewPropertyAnimator?
        let harness = BrowserTabTransitionUIKitHarness(
            contentFrame: CGRect(x: 20, y: 70, width: 200, height: 400),
            cardFrame: CGRect(x: 60, y: 320, width: 100, height: 200),
            diagnostics: .init(onAnimatorCreated: { animator = $0 }),
        )
        var completed = false

        harness.coordinator.begin(
            token: 1,
            direction: .toOverview,
            tabID: harness.tabID,
            reduceMotion: false,
            onPresentationChange: { harness.registerCard() },
            onCompletion: { completed = true },
        )
        let clone = try #require(harness.overlay.subviews.first)
        let sourceCenter = CGPoint(x: harness.content.frame.midX, y: harness.content.frame.midY)
        let destinationCenter = CGPoint(x: harness.card.frame.midX, y: harness.card.frame.midY)
        let transitionAnimator = try #require(animator)

        transitionAnimator.pauseAnimation()
        transitionAnimator.fractionComplete = 0.5
        await harness.waitForLayout()

        let presentation = try #require(clone.layer.presentation())
        let displayedCenter = presentation.position
        let displayedTransform = presentation.affineTransform()
        let displayedScale = sqrt(
            displayedTransform.a * displayedTransform.a
                + displayedTransform.c * displayedTransform.c,
        )

        #expect(clone.superview === harness.overlay)
        #expect(displayedCenter.y > min(sourceCenter.y, destinationCenter.y))
        #expect(displayedCenter.y < max(sourceCenter.y, destinationCenter.y))
        #expect(displayedScale > 0.5)
        #expect(displayedScale < 1)
        #expect(completed == false)

        transitionAnimator.stopAnimation(false)
        transitionAnimator.finishAnimation(at: .end)
        await harness.waitForAnimation()
        harness.window.isHidden = true
    }

    @Test("UIKit coordinator waits for a late destination and rejects material aspect mismatch")
    func uikitCoordinatorWaitsAndFallsBackForMismatchedAspect() async {
        var lateExecutions: [BrowserTabTransitionExecution] = []
        let lateHarness = BrowserTabTransitionUIKitHarness(
            contentFrame: CGRect(x: 20, y: 70, width: 200, height: 400),
            cardFrame: CGRect(x: 60, y: 320, width: 100, height: 200),
            registerCardInitially: false,
            diagnostics: .init(onExecution: { lateExecutions.append($0) }),
        )
        var lateCompletion = false
        lateHarness.coordinator.begin(
            token: 1,
            direction: .toOverview,
            tabID: lateHarness.tabID,
            reduceMotion: false,
            onPresentationChange: {},
            onCompletion: { lateCompletion = true },
        )
        #expect(lateHarness.overlay.subviews.count == 1)
        await lateHarness.waitForLayout()
        lateHarness.registerCard()
        await lateHarness.waitForAnimation()

        #expect(lateCompletion)
        #expect(lateExecutions.contains(.missingDestination))
        #expect(lateHarness.card.subviews.count == 1)
        lateHarness.window.isHidden = true

        var mismatchExecutions: [BrowserTabTransitionExecution] = []
        let mismatchHarness = BrowserTabTransitionUIKitHarness(
            contentFrame: CGRect(x: 20, y: 70, width: 200, height: 400),
            cardFrame: CGRect(x: 60, y: 320, width: 200, height: 100),
            diagnostics: .init(onExecution: { mismatchExecutions.append($0) }),
        )
        var mismatchCompletion = false
        mismatchHarness.coordinator.begin(
            token: 1,
            direction: .toOverview,
            tabID: mismatchHarness.tabID,
            reduceMotion: false,
            onPresentationChange: {
                mismatchHarness.registerCard()
            },
            onCompletion: { mismatchCompletion = true },
        )
        await mismatchHarness.waitForAnimation()

        #expect(mismatchCompletion)
        #expect(mismatchExecutions.contains(.aspectMismatch))
        #expect(mismatchHarness.overlay.subviews.isEmpty)
        #expect(mismatchHarness.card.subviews.isEmpty)
        mismatchHarness.window.isHidden = true
    }

    @Test("A frozen browsing aspect mismatch reveals the destination through the opacity handoff")
    func frozenBrowsingAspectMismatchUsesOpacityHandoff() async {
        var executions: [BrowserTabTransitionExecution] = []
        var completed = false
        var revealed = false
        var completionCount = 0
        var frozenAspectAtReveal: CGFloat?
        let harness = BrowserTabTransitionUIKitHarness(
            contentFrame: CGRect(x: 20, y: 70, width: 200, height: 400),
            cardFrame: CGRect(x: 60, y: 320, width: 200, height: 100),
            diagnostics: .init(onExecution: { executions.append($0) }),
        )

        harness.coordinator.begin(
            token: 1,
            direction: .toBrowsing,
            tabID: harness.tabID,
            reduceMotion: false,
            onPresentationChange: {},
            onCompletion: {
                completed = true
                completionCount += 1
            },
            onDestinationVisible: {
                revealed = true
                frozenAspectAtReveal = harness.overlay.subviews.first.map { $0.frame.width / $0.frame.height }
            },
        )
        await harness.waitForAnimation()

        let sourceAspect = harness.card.bounds.width / harness.card.bounds.height
        let destinationAspect = harness.content.bounds.width / harness.content.bounds.height
        #expect(executions == [.aspectMismatch])
        #expect(executions.contains(.geometry) == false)
        #expect(revealed)
        #expect(completed)
        #expect(completionCount == 1)
        #expect(abs((frozenAspectAtReveal ?? 0) - sourceAspect) < 0.01)
        #expect(abs((frozenAspectAtReveal ?? 0) - destinationAspect) > 0.1)
        #expect(harness.coordinator.presentationOutcome.destinationWasRevealed)
        #expect(harness.coordinator.isActive == false)
        #expect(harness.overlay.subviews.isEmpty)
        harness.window.isHidden = true
    }

    @Test("A frozen browsing aspect mismatch does not restart after destination registration changes")
    func frozenBrowsingAspectMismatchLatchesDestinationIdentity() async {
        var executions: [BrowserTabTransitionExecution] = []
        var animators: [UIViewPropertyAnimator] = []
        var revealCount = 0
        var completionCount = 0
        let harness = BrowserTabTransitionUIKitHarness(
            contentFrame: CGRect(x: 20, y: 70, width: 200, height: 400),
            cardFrame: CGRect(x: 60, y: 320, width: 200, height: 100),
            diagnostics: .init(
                onExecution: { executions.append($0) },
                onAnimatorCreated: { animators.append($0) },
            ),
        )

        harness.coordinator.begin(
            token: 1,
            direction: .toBrowsing,
            tabID: harness.tabID,
            reduceMotion: false,
            onPresentationChange: {},
            onCompletion: { completionCount += 1 },
            onDestinationVisible: {
                revealCount += 1
                harness.registerContent()
            },
        )
        await harness.waitForAnimation()

        #expect(executions == [.aspectMismatch])
        #expect(animators.count == 1)
        #expect(revealCount == 1)
        #expect(completionCount == 1)
        #expect(harness.coordinator.isActive == false)
        harness.window.isHidden = true
    }

    @Test("A live aspect mismatch restores the page and ends the transition")
    func liveAspectMismatchRestoresPageAndEndsTransition() async {
        var executions: [BrowserTabTransitionExecution] = []
        let harness = BrowserTabTransitionUIKitHarness(
            contentFrame: CGRect(x: 20, y: 70, width: 200, height: 400),
            cardFrame: CGRect(x: 60, y: 320, width: 200, height: 100),
            contentRepresentation: .live,
            diagnostics: .init(onExecution: { executions.append($0) }),
        )
        var completed = false

        harness.coordinator.begin(
            token: 1,
            direction: .toOverview,
            tabID: harness.tabID,
            reduceMotion: false,
            onPresentationChange: { harness.registerCard() },
            onCompletion: { completed = true },
        )
        await harness.waitForLayout()

        #expect(completed)
        #expect(harness.coordinator.isActive == false)
        #expect(executions == [.aspectMismatch])
        #expect(harness.content.superview === harness.rootViewController.view)
        #expect(harness.content.transform == .identity)
        harness.window.isHidden = true
    }

    @Test("Reduce Motion live overview render failure aborts back to browsing")
    func reduceMotionLiveOverviewRenderFailureAbortsToBrowsing() async {
        var executions: [BrowserTabTransitionExecution] = []
        var presentation = BrowserPresentation.browsing
        var completed = false
        var aborted = false
        var revealed = false
        let harness = BrowserTabTransitionUIKitHarness(
            contentFrame: CGRect(x: 20, y: 70, width: 200, height: 400),
            cardFrame: CGRect(x: 60, y: 320, width: 100, height: 200),
            contentRepresentation: .live,
            diagnostics: .init(onExecution: { executions.append($0) }),
            renderedSurfaceFactory: { _ in nil },
        )

        harness.coordinator.begin(
            token: 1,
            direction: .toOverview,
            tabID: harness.tabID,
            reduceMotion: true,
            onPresentationChange: {
                presentation = .tabOverview
                harness.registerCard()
            },
            onCompletion: { completed = true },
            onPresentationUnavailable: {
                presentation = .browsing
                aborted = true
            },
            onDestinationVisible: { revealed = true },
        )
        await harness.waitForAnimation()

        #expect(executions == [.reduceMotion])
        #expect(revealed == false)
        #expect(aborted)
        #expect(completed)
        #expect(presentation == .browsing)
        #expect(harness.coordinator.isActive == false)
        #expect(harness.card.subviews.isEmpty)
        #expect(harness.content.superview === harness.rootViewController.view)
        #expect(harness.content.transform == .identity)
        harness.window.isHidden = true
    }

    @Test("A live surface failure restores the page and ends the transition")
    func liveSurfaceFailureRestoresPageAndEndsTransition() async {
        let harness = BrowserTabTransitionUIKitHarness(
            contentFrame: CGRect(x: 20, y: 70, width: 200, height: 400),
            cardFrame: CGRect(x: 60, y: 320, width: 100, height: 200),
            contentRepresentation: .live,
        )
        var completed = false

        harness.coordinator.begin(
            token: 1,
            direction: .toOverview,
            tabID: harness.tabID,
            reduceMotion: false,
            onPresentationChange: {
                harness.content.removeFromSuperview()
                harness.registerCard()
            },
            onCompletion: { completed = true },
        )
        await harness.waitForLayout()

        #expect(completed)
        #expect(harness.coordinator.isActive == false)
        #expect(harness.content.superview == nil)
        harness.window.isHidden = true
    }

    @Test("A missing destination aborts after the bounded handoff window")
    func uikitCoordinatorAbortsWhenDestinationNeverMounts() async {
        var executions: [BrowserTabTransitionExecution] = []
        let harness = BrowserTabTransitionUIKitHarness(
            contentFrame: CGRect(x: 20, y: 70, width: 200, height: 400),
            cardFrame: CGRect(x: 60, y: 320, width: 100, height: 200),
            registerCardInitially: false,
            diagnostics: .init(onExecution: { executions.append($0) }),
        )
        var completed = false
        var aborted = false

        harness.coordinator.begin(
            token: 1,
            direction: .toOverview,
            tabID: harness.tabID,
            reduceMotion: false,
            destinationReadiness: .init(mountedSurfaceWaitPolicy: .retryUntilUsable),
            onPresentationChange: {},
            onCompletion: { completed = true },
            onPresentationUnavailable: { aborted = true },
        )
        for _ in 0 ..< 10 {
            await harness.waitForDisplayTurns(1)
            harness.registry.register(
                harness.card,
                for: .card(harness.tabID),
                isReady: false,
            )
        }

        #expect(completed)
        #expect(aborted)
        #expect(harness.coordinator.isActive == false)
        #expect(executions.contains(.missingDestination))
        #expect(harness.overlay.subviews.isEmpty)
        harness.window.isHidden = true
    }

    @Test("A mounted overview card that never becomes ready falls back within the bounded wait")
    func uikitCoordinatorAbortsWhenOverviewCardNeverBecomesReady() async {
        var executions: [BrowserTabTransitionExecution] = []
        let harness = BrowserTabTransitionUIKitHarness(
            contentFrame: CGRect(x: 20, y: 70, width: 200, height: 400),
            cardFrame: CGRect(x: 60, y: 320, width: 100, height: 200),
            diagnostics: .init(onExecution: { executions.append($0) }),
        )
        _ = harness.registry.setReadiness(
            .pending,
            view: harness.card,
            for: .card(harness.tabID),
        )
        var completed = false
        var aborted = false

        harness.coordinator.begin(
            token: 1,
            direction: .toOverview,
            tabID: harness.tabID,
            reduceMotion: false,
            destinationReadiness: .init(mountedSurfaceWaitPolicy: .retryUntilUsable),
            onPresentationChange: {},
            onCompletion: { completed = true },
            onPresentationUnavailable: { aborted = true },
        )
        await harness.waitForDisplayTurns(10)

        #expect(completed)
        #expect(aborted)
        #expect(harness.coordinator.isActive == false)
        #expect(executions.contains(.missingDestination))
        #expect(harness.overlay.subviews.isEmpty)
        #expect(harness.content.transform == .identity)
        harness.window.isHidden = true
    }

    @Test("A logical overview target receives one bounded readiness window")
    func uikitCoordinatorBoundsWaitAfterOverviewTargetRequest() async {
        var executions: [BrowserTabTransitionExecution] = []
        let harness = BrowserTabTransitionUIKitHarness(
            contentFrame: CGRect(x: 20, y: 70, width: 200, height: 400),
            cardFrame: CGRect(x: 60, y: 320, width: 100, height: 200),
            diagnostics: .init(onExecution: { executions.append($0) }),
        )
        _ = harness.registry.setReadiness(
            .pending,
            view: harness.card,
            for: .card(harness.tabID),
        )
        var targetRequests = 0
        var aborted = false
        let persistedAnchor = BrowserTabID()
        let scrollPosition = BrowserTabOverviewScrollPosition(persistedPosition: persistedAnchor)
        scrollPosition.updateFullyVisibleTargetIDs([persistedAnchor])

        harness.coordinator.begin(
            token: 1,
            direction: .toOverview,
            tabID: harness.tabID,
            reduceMotion: false,
            destinationReadiness: .init(
                displayTurnBudget: 32,
                mountedSurfaceWaitPolicy: .retryUntilUsable,
                prepareDestination: {
                    targetRequests += 1
                    let result = scrollPosition.prepareTransitionTarget(
                        harness.tabID,
                        transitionToken: 1,
                    )
                    return result != .awaitingReadiness
                },
            ),
            onPresentationChange: {},
            onCompletion: {},
            onPresentationUnavailable: { aborted = true },
            onTransitionInvalidated: { token, _ in
                scrollPosition.invalidateTransitionRequest(for: token)
            },
        )
        await harness.waitForDisplayTurns(10)

        #expect(targetRequests == 1)
        #expect(harness.coordinator.isActive)
        #expect(!aborted)
        #expect(scrollPosition.transitionDrivenPosition == harness.tabID)

        await harness.waitForDisplayTurns(40)

        #expect(!harness.coordinator.isActive)
        #expect(aborted)
        #expect(scrollPosition.transitionDrivenPosition == nil)
        #expect(scrollPosition.commit() == nil)
        #expect(scrollPosition.persistedPosition == persistedAnchor)
        #expect(executions.contains(.missingDestination))
        #expect(harness.overlay.subviews.isEmpty)
        #expect(harness.content.transform == .identity)
        harness.window.isHidden = true
    }

    @Test("A destination that becomes ready before the bounded wait animates from real geometry")
    func uikitCoordinatorBeginsWhenOverviewCardBecomesReady() async {
        var executions: [BrowserTabTransitionExecution] = []
        var animator: UIViewPropertyAnimator?
        let harness = BrowserTabTransitionUIKitHarness(
            contentFrame: CGRect(x: 20, y: 70, width: 200, height: 400),
            cardFrame: CGRect(x: 60, y: 320, width: 100, height: 200),
            diagnostics: .init(
                onExecution: { executions.append($0) },
                onAnimatorCreated: { animator = $0 },
            ),
        )
        _ = harness.registry.setReadiness(
            .pending,
            view: harness.card,
            for: .card(harness.tabID),
        )
        var completed = false

        harness.coordinator.begin(
            token: 1,
            direction: .toOverview,
            tabID: harness.tabID,
            reduceMotion: false,
            destinationReadiness: .init(
                displayTurnBudget: 8,
                mountedSurfaceWaitPolicy: .retryUntilUsable,
            ),
            onPresentationChange: {},
            onCompletion: { completed = true },
        )
        await harness.waitForDisplayTurns(2)
        #expect(harness.coordinator.isActive)
        #expect(animator == nil)
        #expect(!executions.contains(.geometry))

        harness.registerCard()
        await harness.waitForLayout()

        #expect(executions.contains(.geometry))
        #expect(animator != nil)
        animator?.stopAnimation(false)
        animator?.finishAnimation(at: .end)
        await harness.waitForDisplayTurns(1)

        #expect(completed)
        #expect(harness.coordinator.isActive == false)
        #expect(harness.overlay.subviews.isEmpty)
        harness.window.isHidden = true
    }

    @Test("A missing source changes presentation without hiding the live surface")
    func uikitCoordinatorDoesNotStartACloneWhenSourceIsMissing() {
        var executions: [BrowserTabTransitionExecution] = []
        let harness = BrowserTabTransitionUIKitHarness(
            contentFrame: CGRect(x: 20, y: 70, width: 200, height: 400),
            cardFrame: CGRect(x: 60, y: 320, width: 100, height: 200),
            registerContentInitially: false,
            diagnostics: .init(onExecution: { executions.append($0) }),
        )
        var presentationChanged = false
        var completed = false

        harness.coordinator.begin(
            token: 1,
            direction: .toOverview,
            tabID: harness.tabID,
            reduceMotion: false,
            onPresentationChange: { presentationChanged = true },
            onCompletion: { completed = true },
        )

        #expect(presentationChanged)
        #expect(completed)
        #expect(executions == [.missingSource])
        #expect(harness.overlay.subviews.isEmpty)
        harness.window.isHidden = true
    }

    @Test("A missing browsing destination aborts safely instead of retaining a fallback")
    func uikitCoordinatorAbortsWhenBrowsingDestinationNeverMounts() async {
        var executions: [BrowserTabTransitionExecution] = []
        var events: [String] = []
        let harness = BrowserTabTransitionUIKitHarness(
            contentFrame: CGRect(x: 20, y: 70, width: 200, height: 400),
            cardFrame: CGRect(x: 60, y: 320, width: 100, height: 200),
            registerContentInitially: false,
            diagnostics: .init(onExecution: { executions.append($0) }),
        )
        var completed = false

        harness.coordinator.begin(
            token: 1,
            direction: .toBrowsing,
            tabID: harness.tabID,
            reduceMotion: false,
            onPresentationChange: { events.append("presentation") },
            onCompletion: {
                events.append("completion")
                completed = true
            },
            onPresentationUnavailable: { events.append("abort") },
            onDestinationVisible: { events.append("reveal") },
        )
        await harness.waitForDisplayTurns(10)

        #expect(executions.contains(.missingDestination))
        #expect(completed)
        #expect(events == ["presentation", "completion", "abort"])
        #expect(harness.coordinator.isActive == false)
        #expect(harness.overlay.subviews.isEmpty)
        harness.window.isHidden = true
    }

    @Test("Reduce Motion keeps the exact parked clone for overview and fades it only on exit")
    func reduceMotionPreservesExactOverviewClone() async {
        let harness = BrowserTabTransitionUIKitHarness(
            contentFrame: CGRect(x: 20, y: 70, width: 200, height: 400),
            cardFrame: CGRect(x: 60, y: 320, width: 100, height: 200),
        )
        var enteredOverview = false
        harness.coordinator.begin(
            token: 1,
            direction: .toOverview,
            tabID: harness.tabID,
            reduceMotion: true,
            onPresentationChange: {
                harness.registerCard()
            },
            onCompletion: { enteredOverview = true },
        )
        await harness.waitForAnimation()

        #expect(enteredOverview)
        #expect(harness.card.subviews.count == 1)
        let clone = harness.card.subviews[0]
        #expect(clone.alpha == 1)

        var exitedOverview = false
        var sawCloneBeforeFade = false
        harness.coordinator.begin(
            token: 2,
            direction: .toBrowsing,
            tabID: harness.tabID,
            reduceMotion: true,
            onPresentationChange: {
                sawCloneBeforeFade = harness.overlay.subviews.first === clone
                harness.registerContent()
            },
            onCompletion: { exitedOverview = true },
        )
        #expect(sawCloneBeforeFade)
        await harness.waitForAnimation()

        #expect(exitedOverview)
        #expect(clone.superview == nil)
        harness.window.isHidden = true
    }

    @Test("Reduce Motion parks a live page clone before revealing overview")
    func reduceMotionParksLivePageBeforeOverviewReveal() async {
        let harness = BrowserTabTransitionUIKitHarness(
            contentFrame: CGRect(x: 20, y: 70, width: 200, height: 400),
            cardFrame: CGRect(x: 60, y: 320, width: 100, height: 200),
            contentRepresentation: .live,
        )
        var sawParkedCloneAtReveal = false

        harness.coordinator.begin(
            token: 1,
            direction: .toOverview,
            tabID: harness.tabID,
            reduceMotion: true,
            onPresentationChange: {
                harness.registerCard()
            },
            onCompletion: {},
            onDestinationVisible: {
                sawParkedCloneAtReveal = harness.card.subviews.count == 1
            },
        )
        await harness.waitForAnimation()

        #expect(sawParkedCloneAtReveal)
        #expect(harness.card.subviews.count == 1)
        #expect(harness.content.transform == .identity)
        harness.window.isHidden = true
    }

    @Test("A stale UIKit completion cannot finish a retargeted presentation")
    func staleUIKitCompletionIsIgnoredAfterRetarget() async {
        let harness = BrowserTabTransitionUIKitHarness(
            contentFrame: CGRect(x: 20, y: 70, width: 200, height: 400),
            cardFrame: CGRect(x: 60, y: 320, width: 100, height: 200),
        )
        let persistedAnchor = BrowserTabID()
        let scrollPosition = BrowserTabOverviewScrollPosition(persistedPosition: persistedAnchor)
        scrollPosition.updateFullyVisibleTargetIDs([persistedAnchor])
        let staleBindingRevision = scrollPosition.scrollBindingRevision
        #expect(
            scrollPosition.requestTransitionTarget(
                harness.tabID,
                transitionToken: 1,
            ) == .requested,
        )
        var staleCompletion = false
        var currentCompletion = false
        harness.coordinator.begin(
            token: 1,
            direction: .toOverview,
            tabID: harness.tabID,
            reduceMotion: false,
            onPresentationChange: {
                harness.registerCard()
            },
            onCompletion: { staleCompletion = true },
            onTransitionInvalidated: { token, _ in
                scrollPosition.invalidateTransitionRequest(for: token)
            },
        )
        await harness.waitForLayout()
        let clone = harness.overlay.subviews.first
        #expect(clone != nil)
        guard let clone else {
            harness.window.isHidden = true
            return
        }

        let displayedCenter = clone.layer.presentation()?.position ?? clone.center

        harness.coordinator.begin(
            token: 2,
            direction: .toBrowsing,
            tabID: harness.tabID,
            reduceMotion: false,
            onPresentationChange: {
                harness.registerContent()
            },
            onCompletion: { currentCompletion = true },
            onTransitionInvalidated: { token, _ in
                scrollPosition.invalidateTransitionRequest(for: token)
            },
        )
        #expect(scrollPosition.transitionDrivenPosition == nil)
        #expect(scrollPosition.commit() == nil)
        #expect(scrollPosition.persistedPosition == persistedAnchor)
        #expect(!scrollPosition.updateLivePosition(
            harness.tabID,
            bindingRevision: staleBindingRevision,
        ))
        let retargetCenter = clone.layer.presentation()?.position ?? clone.center
        #expect(abs(retargetCenter.x - displayedCenter.x) < 8)
        #expect(abs(retargetCenter.y - displayedCenter.y) < 8)
        await harness.waitForAnimation()

        #expect(staleCompletion == false)
        #expect(currentCompletion)
        harness.window.isHidden = true
    }
}

@MainActor
private final class BrowserTabTransitionUIKitHarness {
    let tabID = BrowserTabID()
    let window: UIWindow
    let rootViewController: UIViewController
    let overlay: BrowserTabTransitionOverlayView
    let registry: BrowserTabTransitionSurfaceRegistry
    let coordinator: BrowserTabTransitionUIKitCoordinator
    let content: UIView
    let card: UIView

    init(
        contentFrame: CGRect,
        cardFrame: CGRect,
        registerCardInitially: Bool = true,
        registerContentInitially: Bool = true,
        contentRepresentation: BrowserTabTransitionSurfaceRegistry.Representation = .frozen,
        diagnostics: BrowserTabTransitionDiagnostics = .init(),
        renderedSurfaceFactory: ((UIView) -> UIView?)? = nil,
    ) {
        window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 640))
        rootViewController = UIViewController()
        overlay = BrowserTabTransitionOverlayView(frame: CGRect(x: 0, y: 0, width: 320, height: 640))
        registry = BrowserTabTransitionSurfaceRegistry()
        coordinator = BrowserTabTransitionUIKitCoordinator(
            registry: registry,
            diagnostics: diagnostics,
            renderedSurfaceFactory: renderedSurfaceFactory,
        )
        content = UIView(frame: contentFrame)
        card = UIView(frame: cardFrame)

        rootViewController.view = UIView(frame: window.bounds)
        window.rootViewController = rootViewController
        window.isHidden = false
        rootViewController.view.addSubview(content)
        rootViewController.view.addSubview(card)
        rootViewController.view.addSubview(overlay)
        content.backgroundColor = .systemBlue
        card.backgroundColor = .systemGreen
        rootViewController.view.layoutIfNeeded()
        flushUIKitRendering()
        coordinator.attach(overlay: overlay)
        if registerContentInitially {
            registry.register(
                content,
                for: .content(tabID),
                representation: contentRepresentation,
            )
        }
        if registerCardInitially {
            registry.register(card, for: .card(tabID))
        }
    }

    func registerContent() {
        registry.register(content, for: .content(tabID))
    }

    func registerCard() {
        registry.register(card, for: .card(tabID))
    }

    func waitForLayout() async {
        rootViewController.view.layoutIfNeeded()
        await waitForDisplayTurn()
        rootViewController.view.layoutIfNeeded()
    }

    func waitForAnimation() async {
        await waitForDisplayTurns(30)
    }

    func waitForDisplayTurns(_ count: Int) async {
        for _ in 0 ..< count {
            rootViewController.view.layoutIfNeeded()
            await waitForDisplayTurn()
        }
        rootViewController.view.layoutIfNeeded()
    }

    private func flushUIKitRendering() {
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
    }

    private func waitForDisplayTurn() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let target = BrowserTabTransitionDisplayTurnTarget {
                continuation.resume()
            }
            let displayLink = CADisplayLink(
                target: target,
                selector: #selector(BrowserTabTransitionDisplayTurnTarget.tick),
            )
            displayLink.add(to: .main, forMode: .common)
        }
    }
}

@MainActor
private final class BrowserTabTransitionDisplayTurnTarget: NSObject {
    private let onTick: () -> Void

    init(onTick: @escaping () -> Void) {
        self.onTick = onTick
    }

    @objc
    func tick(_ displayLink: CADisplayLink) {
        displayLink.invalidate()
        onTick()
    }
}
