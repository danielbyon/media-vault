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

    @Test("Preview revisions are equality tokens rather than ordered sequence numbers")
    func previewRevisionsUseOpaqueEquality() {
        let first = BrowserTabPreviewRevision()
        let second = BrowserTabPreviewRevision()
        let copy = first

        #expect(first == copy)
        #expect(first != second)
    }

    @Test("Compact and regular layout probes follow their current viewport geometry")
    func viewportGeometryRecomputesForCompactAndRegularLayouts() {
        let compact = BrowserContentViewportGeometry.measure(
            containerSize: CGSize(width: 390, height: 844),
            safeAreaTop: 0,
            safeAreaLeading: 0,
            safeAreaBottom: 34,
            safeAreaTrailing: 0,
            chromeHeight: 104,
            chromeAtTop: false,
        )
        let regular = BrowserContentViewportGeometry.measure(
            containerSize: CGSize(width: 1_194, height: 834),
            safeAreaTop: 24,
            safeAreaLeading: 0,
            safeAreaBottom: 20,
            safeAreaTrailing: 0,
            chromeHeight: 52,
            chromeAtTop: true,
        )

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
        let harness = BrowserTabTransitionUIKitHarness(
            contentFrame: CGRect(x: 20, y: 70, width: 200, height: 400),
            cardFrame: CGRect(x: 60, y: 320, width: 100, height: 200),
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
        #expect(clone?.superview === harness.card)
        #expect(clone?.frame == harness.card.bounds)

        harness.card.frame = CGRect(x: 40, y: 300, width: 150, height: 300)
        harness.rootViewController.view.layoutIfNeeded()
        harness.registerCard()
        await harness.waitForLayout()

        #expect(clone?.superview === harness.card)
        #expect(clone?.frame == harness.card.bounds)

        var sawSameCloneOnReverse = false
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
        )

        #expect(sawSameCloneOnReverse)
        await harness.waitForAnimation()
        #expect(exitedOverview)
        #expect(clone?.superview == nil)
    }

    @Test("UIKit coordinator waits for a late destination and rejects material aspect mismatch")
    func uikitCoordinatorWaitsAndFallsBackForMismatchedAspect() async {
        let lateHarness = BrowserTabTransitionUIKitHarness(
            contentFrame: CGRect(x: 20, y: 70, width: 200, height: 400),
            cardFrame: CGRect(x: 60, y: 320, width: 100, height: 200),
            registerCardInitially: false,
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
        #expect(lateHarness.card.subviews.count == 1)
        lateHarness.window.isHidden = true

        let mismatchHarness = BrowserTabTransitionUIKitHarness(
            contentFrame: CGRect(x: 20, y: 70, width: 200, height: 400),
            cardFrame: CGRect(x: 60, y: 320, width: 200, height: 100),
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
        #expect(mismatchHarness.overlay.subviews.isEmpty)
        #expect(mismatchHarness.card.subviews.isEmpty)
        mismatchHarness.window.isHidden = true
    }

    @Test("A missing destination uses the bounded fallback handoff")
    func uikitCoordinatorFallsBackWhenDestinationNeverMounts() async {
        let harness = BrowserTabTransitionUIKitHarness(
            contentFrame: CGRect(x: 20, y: 70, width: 200, height: 400),
            cardFrame: CGRect(x: 60, y: 320, width: 100, height: 200),
            registerCardInitially: false,
        )
        var completed = false

        harness.coordinator.begin(
            token: 1,
            direction: .toOverview,
            tabID: harness.tabID,
            reduceMotion: false,
            onPresentationChange: {},
            onCompletion: { completed = true },
        )
        await harness.waitForAnimation()

        #expect(completed)
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

    @Test("A stale UIKit completion cannot finish a retargeted presentation")
    func staleUIKitCompletionIsIgnoredAfterRetarget() async {
        let harness = BrowserTabTransitionUIKitHarness(
            contentFrame: CGRect(x: 20, y: 70, width: 200, height: 400),
            cardFrame: CGRect(x: 60, y: 320, width: 100, height: 200),
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
        )
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

    init(contentFrame: CGRect, cardFrame: CGRect, registerCardInitially: Bool = true) {
        window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 640))
        rootViewController = UIViewController()
        overlay = BrowserTabTransitionOverlayView(frame: CGRect(x: 0, y: 0, width: 320, height: 640))
        registry = BrowserTabTransitionSurfaceRegistry()
        coordinator = BrowserTabTransitionUIKitCoordinator(registry: registry)
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
        registry.register(content, for: .content(tabID))
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
        await Task.yield()
        rootViewController.view.layoutIfNeeded()
        flushUIKitRendering()
        await Task.yield()
    }

    func waitForAnimation() async {
        try? await Task.sleep(for: .milliseconds(500))
        rootViewController.view.layoutIfNeeded()
        flushUIKitRendering()
    }

    private func flushUIKitRendering() {
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
    }
}
