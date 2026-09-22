//
//  BrowserViewInteractionTests.swift
//  MediaVault
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import ComposableArchitecture
import Foundation
import SwiftUI
import Testing
import UIKit
import WebKit
@testable import BrowserFeature

@Suite("Browser view interaction boundaries", .serialized)
@MainActor
struct BrowserViewInteractionTests {
    @Test("Browsing a web tab mounts one interactive omnibox owner")
    func browsingWebTabMountsOneOmnibox() throws {
        let url = try #require(URL(string: "https://example.com"))
        let tab = BrowserTab.web(id: BrowserTabID(UUID(1)), url: url)
        let store = Store(initialState: BrowserFeature.State(tabs: [tab], selectedTabID: tab.id)) {
            BrowserFeature()
        }
        let hostingController = UIHostingController(rootView: BrowserView(store: store))
        let window = mount(hostingController, size: CGSize(width: 390, height: 844))

        #expect(descendants(of: hostingController.view, matching: UITextField.self).count == 1)

        window.isHidden = true
        window.rootViewController = nil
    }

    @Test("Browsing dismissal scope contains the page surface and Browser chrome")
    func browsingDismissalScopeContainsPageAndChrome() throws {
        let url = try #require(URL(string: "https://example.com"))
        let tab = BrowserTab.web(id: BrowserTabID(UUID(1)), url: url)
        let store = Store(initialState: BrowserFeature.State(tabs: [tab], selectedTabID: tab.id)) {
            BrowserFeature()
        }
        let hostingController = UIHostingController(rootView: BrowserView(store: store))
        let window = mount(hostingController, size: CGSize(width: 390, height: 844))

        let pageSurface = try #require(allViews(in: hostingController.view).compactMap { $0 as? WKWebView }.first)
        let chromeControl = try #require(allViews(in: hostingController.view).compactMap { $0 as? UIButton }.first)
        let dismissalRecognizer = try #require(
            browserDismissalRecognizers(in: hostingController.view).first,
        )

        #expect(browserDismissalRecognizers(in: hostingController.view).count == 1)
        #expect(dismissalRecognizer.view === hostingController.view)
        #expect(dismissalRecognizer.delaysTouchesBegan == false)
        #expect(dismissalRecognizer.delaysTouchesEnded == false)
        #expect(pageSurface.scrollView.keyboardDismissMode == .interactive)
        #expect(hostingController.view.bounds.contains(center(of: pageSurface, in: hostingController.view)))
        #expect(hostingController.view.bounds.contains(center(of: chromeControl, in: hostingController.view)))

        window.isHidden = true
        window.rootViewController = nil
    }

    @Test("Start Page native host receives interactive keyboard dismissal")
    func startPageNativeHostReceivesInteractiveDismissal() throws {
        let store = Store(initialState: BrowserFeature.State(initialTabID: BrowserTabID(UUID(1)))) {
            BrowserFeature()
        }
        let hostingController = UIHostingController(rootView: BrowserView(store: store))
        let window = mount(hostingController, size: CGSize(width: 390, height: 844))
        let textField = try #require(descendants(of: hostingController.view, matching: UITextField.self).first)

        #expect(
            descendants(of: hostingController.view, matching: UIScrollView.self)
                .contains(where: { $0.keyboardDismissMode == .interactive }),
        )
        #expect(
            browserDismissalRecognizers(in: hostingController.view).count == 1,
        )
        #expect(hostingController.view.bounds.contains(center(of: textField, in: hostingController.view)))

        window.isHidden = true
        window.rootViewController = nil
    }

    @Test("WebKit presentation readiness requires two stable display turns")
    func webKitPresentationReadinessRequiresTwoStableDisplayTurns() async throws {
        let tabID = BrowserTabID(UUID(9_008))
        let registry = BrowserTabTransitionSurfaceRegistry()
        var readinessEvents: [BrowserTabTransitionEvent] = []
        registry.onEvent = { readinessEvents.append($0) }
        let rootViewController = UIViewController()
        let window = mount(rootViewController, size: CGSize(width: 390, height: 700))
        let webView = WKWebView(frame: rootViewController.view.bounds)
        let adapter = BrowserWebKitAdapter(makeWebView: { _, _ in webView })
        let readinessCoordinator = BrowserWebKitReadinessCoordinator(adapter: adapter)
        let coordinator = BrowserWebView.Coordinator(
            onRefresh: {},
            transitionRegistry: registry,
            readinessCoordinator: readinessCoordinator,
            adapter: adapter,
        )
        _ = adapter.ensureContext(for: tabID)
        rootViewController.view.addSubview(webView)
        rootViewController.view.layoutIfNeeded()
        defer {
            coordinator.invalidateReadinessProbe()
            adapter.destroyContext(for: tabID)
            window.isHidden = true
            window.rootViewController = nil
        }

        webView.loadHTMLString(
            webKitTestDocument(
                text: "Stable presentation",
                background: "#d94a5a",
                includeVisibleText: false,
            ),
            baseURL: nil,
        )
        try await waitForWebKitDocument(in: webView, expectedText: "Stable presentation")
        registry.register(
            webView,
            for: .content(tabID),
            representation: .live,
            isReady: false,
        )

        coordinator.scheduleReadinessProbe(
            for: webView,
            tabID: tabID,
            readinessContext: .init(),
        )
        await waitForDisplayTurn()
        #expect(registry.isReady(for: .content(tabID)) == false)
        #expect(!readinessEvents.contains(.targetPresentationReady(tabID)))

        await waitForDisplayTurn()
        #expect(registry.isReady(for: .content(tabID)))
        #expect(readinessEvents.count(where: { $0 == .targetPresentationReady(tabID) }) == 1)
        #expect(!readinessEvents.contains(.targetPresentationUnavailable(tabID)))
    }

    @Test("Presentation readiness resets its stable-turn barrier when an opaque cover appears")
    func presentationReadinessResetsAfterOpaqueCover() async throws {
        let tabID = BrowserTabID(UUID(9_009))
        let registry = BrowserTabTransitionSurfaceRegistry()
        var readinessEvents: [BrowserTabTransitionEvent] = []
        registry.onEvent = { readinessEvents.append($0) }
        let rootViewController = UIViewController()
        let window = mount(rootViewController, size: CGSize(width: 390, height: 700))
        let webView = WKWebView(frame: rootViewController.view.bounds)
        let adapter = BrowserWebKitAdapter(makeWebView: { _, _ in webView })
        let readinessCoordinator = BrowserWebKitReadinessCoordinator(adapter: adapter)
        let coordinator = BrowserWebView.Coordinator(
            onRefresh: {},
            transitionRegistry: registry,
            readinessCoordinator: readinessCoordinator,
            adapter: adapter,
        )
        _ = adapter.ensureContext(for: tabID)
        rootViewController.view.addSubview(webView)
        rootViewController.view.layoutIfNeeded()
        defer {
            coordinator.invalidateReadinessProbe()
            adapter.destroyContext(for: tabID)
            window.isHidden = true
            window.rootViewController = nil
        }

        webView.loadHTMLString(
            webKitTestDocument(
                text: "Covered presentation",
                background: "#d94a5a",
                includeVisibleText: false,
            ),
            baseURL: nil,
        )
        try await waitForWebKitDocument(in: webView, expectedText: "Covered presentation")
        registry.register(
            webView,
            for: .content(tabID),
            representation: .live,
            isReady: false,
        )
        coordinator.scheduleReadinessProbe(
            for: webView,
            tabID: tabID,
            readinessContext: .init(),
        )

        await waitForDisplayTurn()
        #expect(registry.isReady(for: .content(tabID)) == false)

        let behindCover = UIView(frame: webView.bounds)
        behindCover.backgroundColor = .systemBlue
        behindCover.isOpaque = true
        behindCover.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        webView.insertSubview(
            behindCover,
            belowSubview: webView.scrollView,
        )
        webView.layoutIfNeeded()
        #expect(BrowserWebKitPresentationGuard.hasOpaqueCover(in: webView) == false)
        behindCover.removeFromSuperview()

        let partialCover = UIView(frame: CGRect(x: 0, y: 0, width: 80, height: 80))
        partialCover.backgroundColor = .systemBlue
        partialCover.isOpaque = true
        webView.addSubview(partialCover)
        #expect(BrowserWebKitPresentationGuard.hasOpaqueCover(in: webView) == false)
        partialCover.removeFromSuperview()

        let cover = UIView(frame: webView.bounds)
        cover.backgroundColor = .systemBlue
        cover.isOpaque = true
        cover.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        webView.addSubview(cover)
        webView.layoutIfNeeded()
        #expect(BrowserWebKitPresentationGuard.hasOpaqueCover(in: webView))

        await waitForDisplayTurn()
        #expect(registry.isReady(for: .content(tabID)) == false)
        #expect(readinessEvents.count(where: { $0 == .targetPresentationBlocked(tabID) }) == 1)

        cover.removeFromSuperview()
        await waitForDisplayTurn()
        #expect(registry.isReady(for: .content(tabID)) == false)
        await waitForDisplayTurn()

        #expect(registry.isReady(for: .content(tabID)))
        #expect(readinessEvents.count(where: { $0 == .targetPresentationReady(tabID) }) == 1)
    }

    @Test("A fresh-commit requirement prevents a previously committed document from becoming ready")
    func freshCommitRequirementBlocksPreviouslyCommittedDocument() async throws {
        let tabID = BrowserTabID(UUID(9_010))
        let registry = BrowserTabTransitionSurfaceRegistry()
        var readinessEvents: [BrowserTabTransitionEvent] = []
        registry.onEvent = { readinessEvents.append($0) }
        let rootViewController = UIViewController()
        let window = mount(rootViewController, size: CGSize(width: 390, height: 700))
        let webView = WKWebView(frame: rootViewController.view.bounds)
        let adapter = BrowserWebKitAdapter(makeWebView: { _, _ in webView })
        let readinessCoordinator = BrowserWebKitReadinessCoordinator(adapter: adapter)
        let coordinator = BrowserWebView.Coordinator(
            onRefresh: {},
            transitionRegistry: registry,
            readinessCoordinator: readinessCoordinator,
            adapter: adapter,
        )
        _ = adapter.ensureContext(for: tabID)
        rootViewController.view.addSubview(webView)
        rootViewController.view.layoutIfNeeded()
        defer {
            coordinator.invalidateReadinessProbe()
            adapter.destroyContext(for: tabID)
            window.isHidden = true
            window.rootViewController = nil
        }

        webView.loadHTMLString(
            webKitTestDocument(
                text: "Fresh commit",
                background: "#d94a5a",
                includeVisibleText: false,
            ),
            baseURL: nil,
        )
        try await waitForWebKitDocument(in: webView, expectedText: "Fresh commit")
        registry.register(
            webView,
            for: .content(tabID),
            representation: .live,
            isReady: false,
        )
        coordinator.scheduleReadinessProbe(
            for: webView,
            tabID: tabID,
            readinessContext: .init(navigationOperationID: .init()),
        )

        for _ in 0 ..< 3 {
            await waitForDisplayTurn()
        }
        #expect(registry.isReady(for: .content(tabID)) == false)
        #expect(!readinessEvents.contains(.targetPresentationReady(tabID)))

        coordinator.scheduleReadinessProbe(
            for: webView,
            tabID: tabID,
            readinessContext: .init(),
        )
        await waitForDisplayTurn()
        #expect(registry.isReady(for: .content(tabID)) == false)
        await waitForDisplayTurn()

        #expect(registry.isReady(for: .content(tabID)))
        #expect(readinessEvents.count(where: { $0 == .targetPresentationReady(tabID) }) == 1)
    }

    @Test("A WebView with the wrong adapter identity becomes unavailable")
    func wrongAdapterIdentityBecomesUnavailable() async {
        let tabID = BrowserTabID(UUID(9_011))
        let rootViewController = UIViewController()
        let window = mount(rootViewController, size: CGSize(width: 390, height: 700))
        let ownedWebView = WKWebView(frame: rootViewController.view.bounds)
        let foreignWebView = WKWebView(frame: rootViewController.view.bounds)
        let adapter = BrowserWebKitAdapter(makeWebView: { _, _ in ownedWebView })
        let readinessCoordinator = BrowserWebKitReadinessCoordinator(adapter: adapter)
        var results: [BrowserWebKitReadinessResult] = []
        _ = adapter.ensureContext(for: tabID)
        rootViewController.view.addSubview(foreignWebView)
        rootViewController.view.layoutIfNeeded()
        defer {
            readinessCoordinator.invalidate()
            adapter.destroyContext(for: tabID)
            window.isHidden = true
            window.rootViewController = nil
        }

        readinessCoordinator.schedule(
            for: foreignWebView,
            tabID: tabID,
            readinessContext: .init(),
            onResult: { results.append($0) },
            onPresentationBlocked: {},
        )
        for _ in 0 ..< 200 where results.isEmpty {
            await waitForDisplayTurn()
        }

        #expect(results.count == 1)
        if case .unavailable? = results.first {
            // Expected terminal result.
        } else {
            Issue.record("A foreign WebView must not become presentation-ready")
        }
    }

    @Test("An invalid WebKit destination becomes unavailable once")
    func invalidWebKitDestinationBecomesUnavailableOnce() async {
        let tabID = BrowserTabID(UUID(9_012))
        let rootViewController = UIViewController()
        let window = mount(rootViewController, size: CGSize(width: 390, height: 700))
        let webView = WKWebView(frame: rootViewController.view.bounds)
        let adapter = BrowserWebKitAdapter(makeWebView: { _, _ in webView })
        let readinessCoordinator = BrowserWebKitReadinessCoordinator(adapter: adapter)
        var results: [BrowserWebKitReadinessResult] = []
        _ = adapter.ensureContext(for: tabID)
        rootViewController.view.addSubview(webView)
        rootViewController.view.layoutIfNeeded()
        defer {
            readinessCoordinator.invalidate()
            adapter.destroyContext(for: tabID)
            window.isHidden = true
            window.rootViewController = nil
        }

        readinessCoordinator.schedule(
            for: webView,
            tabID: tabID,
            readinessContext: .init(),
            onResult: { results.append($0) },
            onPresentationBlocked: {},
        )
        for _ in 0 ..< 200 where results.isEmpty {
            await waitForDisplayTurn()
        }

        #expect(results.count == 1)
        if case .unavailable? = results.first {
            // Expected terminal result.
        } else {
            Issue.record("An uncommitted WebView must not become presentation-ready")
        }
    }

    @Test("Canceling presentation readiness invalidates a pending probe and permits rescheduling")
    func cancelingPresentationReadinessPermitsRescheduling() async throws {
        let tabID = BrowserTabID(UUID(9_013))
        let rootViewController = UIViewController()
        let window = mount(rootViewController, size: CGSize(width: 390, height: 700))
        let webView = WKWebView(frame: rootViewController.view.bounds)
        let adapter = BrowserWebKitAdapter(makeWebView: { _, _ in webView })
        let readinessCoordinator = BrowserWebKitReadinessCoordinator(adapter: adapter)
        var results: [BrowserWebKitReadinessResult] = []
        _ = adapter.ensureContext(for: tabID)
        rootViewController.view.addSubview(webView)
        rootViewController.view.layoutIfNeeded()
        defer {
            readinessCoordinator.invalidate()
            adapter.destroyContext(for: tabID)
            window.isHidden = true
            window.rootViewController = nil
        }

        webView.loadHTMLString(
            webKitTestDocument(
                text: "Reschedulable presentation",
                background: "#d94a5a",
                includeVisibleText: false,
            ),
            baseURL: nil,
        )
        try await waitForWebKitDocument(in: webView, expectedText: "Reschedulable presentation")
        readinessCoordinator.schedule(
            for: webView,
            tabID: tabID,
            readinessContext: .init(navigationOperationID: .init()),
            onResult: { results.append($0) },
            onPresentationBlocked: {},
        )
        readinessCoordinator.invalidate()
        for _ in 0 ..< 30 {
            await waitForDisplayTurn()
        }
        #expect(results.isEmpty)

        readinessCoordinator.schedule(
            for: webView,
            tabID: tabID,
            readinessContext: .init(),
            onResult: { results.append($0) },
            onPresentationBlocked: {},
        )
        for _ in 0 ..< 30 where results.isEmpty {
            await waitForDisplayTurn()
        }

        #expect(results.count == 1)
        if case .ready? = results.first {
            // Expected terminal result.
        } else {
            Issue.record("The rescheduled committed WebView must become presentation-ready")
        }
    }

    @Test("Loaded WebKit transitions use the actual page surface and preserve its pixels")
    func loadedWebKitTransitionUsesActualPageSurface() async throws {
        let url = try #require(URL(string: "https://example.com"))
        let tab = BrowserTab.web(id: BrowserTabID(UUID(9_001)), url: url)
        var initialState = BrowserFeature.State(tabs: [tab], selectedTabID: tab.id)
        let previewData = try solidPreviewData(red: 217, green: 74, blue: 90)
        initialState.previewState.setData(.init(
            revision: initialState.previewState.revision(for: tab.id),
            pngData: previewData,
        ), for: tab.id)
        let store = Store(initialState: initialState) {
            BrowserFeature()
        }
        var animator: UIViewPropertyAnimator?
        var executions: [BrowserTabTransitionExecution] = []
        var readinessEvents: [BrowserTabTransitionEvent] = []
        let coordinator = BrowserTabTransitionUIKitCoordinator(
            diagnostics: .init(
                onExecution: { executions.append($0) },
                onAnimatorCreated: { animator = $0 },
                onEvent: { readinessEvents.append($0) },
            ),
        )
        let hostingController = UIHostingController(
            rootView: BrowserView(
                store: store,
                transitionCoordinator: coordinator,
            ),
        )
        let window = mount(hostingController, size: CGSize(width: 390, height: 700))
        let webView = try #require(allViews(in: hostingController.view).compactMap { $0 as? WKWebView }.first)
        var attachmentEvents: [BrowserWebKitAttachmentEvent] = []
        BrowserWebKitAdapter.shared.attachmentObserver = { event in
            switch event {
            case let .attached(id) where id == tab.id,
                 let .detached(id) where id == tab.id:
                attachmentEvents.append(event)
            default:
                break
            }
        }
        defer {
            BrowserWebKitAdapter.shared.attachmentObserver = nil
            BrowserWebKitAdapter.shared.destroyContext(for: tab.id)
            window.isHidden = true
            window.rootViewController = nil
        }
        webView.loadHTMLString(
            webKitTestDocument(
                text: "WebKit pixel proof",
                background: "#d94a5a",
                includeVisibleText: false,
            ),
            baseURL: nil,
        )
        try await waitForWebKitDocument(in: webView, expectedText: "WebKit pixel proof")

        hostingController.view.layoutIfNeeded()
        #expect(webView.window != nil)
        #expect(webView.bounds.width > 0)
        #expect(webView.bounds.height > 0)
        #expect(webView.isLoading == false)
        let expectedPagePixel = RenderedPixel(red: 217, green: 74, blue: 90)
        let sourcePixel = await waitForRenderedPixel(
            in: webView,
            expected: expectedPagePixel,
            maximumDisplayTurns: 120,
        ) { CGPoint(x: webView.bounds.midX, y: webView.bounds.midY) }
        #expect(sourcePixel?.approximatelyMatches(expectedPagePixel) == true)
        #expect(BrowserWebKitPresentationGuard.hasOpaqueCover(in: webView) == false)

        for _ in 0 ..< 120 where !coordinator.surfaceRegistry.isReady(for: .content(tab.id)) {
            await waitForDisplayTurn()
            hostingController.view.layoutIfNeeded()
        }
        let registeredSurface = try #require(
            coordinator.surfaceRegistry.view(for: .content(tab.id)),
        )
        #expect(registeredSurface === webView)
        #expect(coordinator.surfaceRegistry.representation(for: .content(tab.id)) == .live)
        #expect(
            coordinator.surfaceRegistry.isReady(for: .content(tab.id)),
            "readiness events: \(readinessEvents)",
        )
        #expect(
            try await webKitValue(
                "getComputedStyle(document.body).backgroundColor",
                in: webView,
            ) == "rgb(217, 74, 90)",
        )
        coordinator.begin(
            token: 1,
            direction: .toOverview,
            tabID: tab.id,
            reduceMotion: false,
            onPresentationChange: {
                store.send(.showTabOverviewTapped)
                hostingController.view.layoutIfNeeded()
            },
            onCompletion: {},
        )
        for _ in 0 ..< 30 where animator == nil {
            await waitForDisplayTurn()
            hostingController.view.layoutIfNeeded()
        }
        _ = try #require(coordinator.surfaceRegistry.view(for: .card(tab.id)))
        let transitionAnimator = try #require(animator)
        let overlay = try #require(
            allViews(in: hostingController.view).compactMap { $0 as? BrowserTabTransitionOverlayView }.first,
        )
        #expect(store.state.presentation == .tabOverview)
        #expect(executions.contains(.geometry))
        #expect(overlay.subviews.isEmpty)
        transitionAnimator.pauseAnimation()
        transitionAnimator.fractionComplete = 0.5
        await waitForDisplayTurn()
        let midpointPixel = await waitForRenderedPixel(
            in: webView,
            expected: expectedPagePixel,
        ) { CGPoint(x: webView.bounds.midX, y: webView.bounds.midY) }
        #expect(midpointPixel?.approximatelyMatches(expectedPagePixel) == true)
        let midpointTransform = webView.layer.presentation()?.affineTransform() ?? webView.transform
        let midpointScale = sqrt(
            midpointTransform.a * midpointTransform.a
                + midpointTransform.c * midpointTransform.c,
        )
        #expect(midpointScale > 0.1)
        #expect(midpointScale < 1)

        #expect(webView.window != nil)
        #expect(attachmentEvents.isEmpty)
        transitionAnimator.stopAnimation(false)
        transitionAnimator.finishAnimation(at: .end)
        for _ in 0 ..< 10 where coordinator.isActive {
            await waitForDisplayTurn()
        }

        #expect(coordinator.isActive == false)
        #expect(webView.window != nil)
        #expect(webView.transform == .identity)
        #expect(attachmentEvents.isEmpty)
        let cardView = try #require(coordinator.surfaceRegistry.view(for: .card(tab.id)))
        let cardPixel = await waitForRenderedPixel(
            in: cardView,
            expected: expectedPagePixel,
        ) { CGPoint(x: cardView.bounds.midX, y: cardView.bounds.midY) }
        #expect(cardPixel?.approximatelyMatches(expectedPagePixel) == true)

        animator = nil
        coordinator.begin(
            token: 2,
            direction: .toBrowsing,
            tabID: tab.id,
            reduceMotion: false,
            destinationRequiresReadiness: false,
            onPresentationChange: {
                store.send(.tabCardSelected(tab.id))
                hostingController.view.layoutIfNeeded()
            },
            onCompletion: {},
        )
        for _ in 0 ..< 30 where animator == nil {
            await waitForDisplayTurn()
            hostingController.view.layoutIfNeeded()
        }
        let reverseAnimator = try #require(animator)
        #expect(store.state.presentation == .browsing)
        #expect(webView.window != nil)
        #expect(coordinator.surfaceRegistry.view(for: .content(tab.id)) === webView)
        #expect(attachmentEvents.isEmpty)
        reverseAnimator.stopAnimation(false)
        reverseAnimator.finishAnimation(at: .end)
        for _ in 0 ..< 10 where coordinator.isActive {
            await waitForDisplayTurn()
        }

        #expect(coordinator.isActive == false)
        #expect(webView.window != nil)
        #expect(webView.transform == .identity)
        #expect(attachmentEvents.isEmpty)
    }

    @Test("Switching two loaded WebKit tabs survives twenty display-turn cycles")
    func switchingLoadedWebKitTabsSurvivesTwentyCycles() async throws {
        let firstID = BrowserTabID(UUID(9_002))
        let secondID = BrowserTabID(UUID(9_003))
        let first = try BrowserTab.web(
            id: firstID,
            url: #require(URL(string: "https://first.example")),
        )
        let second = try BrowserTab.web(
            id: secondID,
            url: #require(URL(string: "https://second.example")),
        )
        var initialState = BrowserFeature.State(
            tabs: [first, second],
            selectedTabID: firstID,
        )
        let firstPreviewData = try solidPreviewData(red: 217, green: 74, blue: 90)
        let secondPreviewData = try solidPreviewData(red: 59, green: 130, blue: 246)
        initialState.previewState.setData(.init(
            revision: initialState.previewState.revision(for: firstID),
            pngData: firstPreviewData,
        ), for: firstID)
        initialState.previewState.setData(.init(
            revision: initialState.previewState.revision(for: secondID),
            pngData: secondPreviewData,
        ), for: secondID)
        let store = Store(initialState: initialState) {
            BrowserFeature()
        }
        let adapter = BrowserWebKitAdapter.shared
        let firstWebView = adapter.ensureContext(for: firstID)
        let secondWebView = adapter.ensureContext(for: secondID)
        var animator: UIViewPropertyAnimator?
        var executions: [BrowserTabTransitionExecution] = []
        var transitionEvents: [BrowserTabTransitionEvent] = []
        let coordinator = BrowserTabTransitionUIKitCoordinator(
            diagnostics: .init(
                onExecution: { executions.append($0) },
                onAnimatorCreated: { animator = $0 },
                onEvent: { transitionEvents.append($0) },
            ),
        )
        let hostingController = UIHostingController(
            rootView: BrowserView(
                store: store,
                transitionCoordinator: coordinator,
            ),
        )
        let window = mount(hostingController, size: CGSize(width: 390, height: 700))
        #expect(
            allViews(in: hostingController.view).compactMap { $0 as? WKWebView }.contains { $0 === firstWebView },
        )
        let transitionOverlay = try #require(
            allViews(in: hostingController.view).compactMap { $0 as? BrowserTabTransitionOverlayView }.first,
        )
        var attachmentEvents: [BrowserWebKitAttachmentEvent] = []
        adapter.attachmentObserver = { event in
            switch event {
            case let .attached(id) where id == firstID || id == secondID,
                 let .detached(id) where id == firstID || id == secondID:
                attachmentEvents.append(event)
            default:
                break
            }
        }
        defer {
            adapter.attachmentObserver = nil
            adapter.destroyContext(for: firstID)
            adapter.destroyContext(for: secondID)
            window.isHidden = true
            window.rootViewController = nil
        }

        firstWebView.loadHTMLString(
            webKitTestDocument(
                text: "First WebKit page",
                background: "#d94a5a",
                includeVisibleText: false,
            ),
            baseURL: nil,
        )
        secondWebView.loadHTMLString(
            webKitTestDocument(
                text: "Second WebKit page",
                background: "#3b82f6",
                includeVisibleText: false,
            ),
            baseURL: nil,
        )
        try await waitForWebKitDocument(in: firstWebView, expectedText: "First WebKit page")
        try await waitForWebKitDocument(in: secondWebView, expectedText: "Second WebKit page")
        hostingController.view.layoutIfNeeded()

        var currentID = firstID
        let expectedPagePixels = [
            firstID: RenderedPixel(red: 217, green: 74, blue: 90),
            secondID: RenderedPixel(red: 59, green: 130, blue: 246),
        ]
        for cycle in 0 ..< 20 {
            let nextID = currentID == firstID ? secondID : firstID
            let currentWebView = currentID == firstID ? firstWebView : secondWebView
            let nextWebView = nextID == firstID ? firstWebView : secondWebView
            animator = nil

            coordinator.begin(
                token: cycle * 2 + 1,
                direction: .toOverview,
                tabID: currentID,
                reduceMotion: false,
                onPresentationChange: {
                    store.send(.showTabOverviewTapped)
                    hostingController.view.layoutIfNeeded()
                },
                onCompletion: {},
            )
            for _ in 0 ..< 60 where animator == nil {
                await waitForDisplayTurn()
                hostingController.view.layoutIfNeeded()
            }
            let overviewAnimator = try #require(animator)
            overviewAnimator.stopAnimation(false)
            overviewAnimator.finishAnimation(at: .end)
            for _ in 0 ..< 30 where coordinator.isActive {
                await waitForDisplayTurn()
            }
            #expect(store.state.presentation == .tabOverview)
            #expect(currentWebView.window != nil)
            for _ in 0 ..< 60 where coordinator.surfaceRegistry.frame(
                for: .card(nextID),
                in: transitionOverlay,
            ) == nil {
                await waitForDisplayTurn()
                hostingController.view.layoutIfNeeded()
            }
            #expect(
                coordinator.surfaceRegistry.frame(
                    for: .card(nextID),
                    in: transitionOverlay,
                ) != nil,
            )

            let expectedPagePixel = try #require(expectedPagePixels[nextID])

            animator = nil
            transitionEvents.removeAll()
            let blackSurface = UIView(frame: nextWebView.bounds)
            blackSurface.backgroundColor = .black
            blackSurface.isOpaque = true
            blackSurface.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            nextWebView.addSubview(blackSurface)
            #expect(
                BrowserWebKitPresentationGuard.hasOpaqueCover(in: nextWebView),
                "the intentionally mounted black surface must be recognized as a covering surface",
            )
            coordinator.begin(
                token: cycle * 2 + 2,
                direction: .toBrowsing,
                tabID: nextID,
                reduceMotion: false,
                destinationRequiresReadiness: true,
                onPresentationChange: {
                    store.send(.tabCardSelected(nextID))
                    hostingController.view.layoutIfNeeded()
                },
                onCompletion: {},
            )
            for _ in 0 ..< 30 {
                await waitForDisplayTurn()
                hostingController.view.layoutIfNeeded()
                #expect(animator == nil)
                #expect(
                    !transitionEvents.contains(.geometryAnimatorCreated(nextID)),
                )
                #expect(
                    !transitionEvents.contains(.destinationRevealed(nextID)),
                )
            }
            #expect(nextWebView.isLoading == false)
            let blankPixel = renderedPixel(
                in: nextWebView,
                at: CGPoint(x: nextWebView.bounds.midX, y: nextWebView.bounds.midY),
            )
            #expect(blankPixel?.approximatelyMatches(.init(red: 0, green: 0, blue: 0)) == true)
            #expect(coordinator.surfaceRegistry.isReady(for: .content(nextID)) == false)

            blackSurface.removeFromSuperview()
            for _ in 0 ..< 90 where animator == nil {
                await waitForDisplayTurn()
                hostingController.view.layoutIfNeeded()
            }
            let browsingAnimator = try #require(
                animator,
                "executions: \(executions), events: \(transitionEvents)",
            )
            let attachedIndex = try #require(
                transitionEvents.firstIndex(of: .targetAttached(nextID)),
            )
            let invalidIndex = try #require(
                transitionEvents.firstIndex(of: .targetPresentationBlocked(nextID)),
            )
            let readyIndex = try #require(
                transitionEvents.firstIndex(of: .targetPresentationReady(nextID)),
            )
            let geometryIndex = try #require(
                transitionEvents.firstIndex(of: .geometryAnimatorCreated(nextID)),
                "executions: \(executions), events: \(transitionEvents)",
            )
            #expect(attachedIndex < invalidIndex)
            #expect(invalidIndex < readyIndex)
            #expect(readyIndex <= geometryIndex)
            #expect(coordinator.surfaceRegistry.view(for: .content(nextID)) === nextWebView)
            #expect(coordinator.surfaceRegistry.isReady(for: .content(nextID)))
            #expect(nextWebView.window != nil)
            #expect(currentWebView.window == nil)
            #expect(attachmentEvents.contains(.detached(currentID)))
            #expect(attachmentEvents.contains(.attached(nextID)))

            browsingAnimator.pauseAnimation()
            browsingAnimator.fractionComplete = 1
            let destinationPixel = renderedPixel(
                in: nextWebView,
                at: CGPoint(x: nextWebView.bounds.midX, y: nextWebView.bounds.midY),
            )
            #expect(
                destinationPixel?.approximatelyMatches(expectedPagePixel) == true,
                "cycle \(cycle), destination=\(String(describing: destinationPixel)), expected=\(expectedPagePixel)",
            )
            #expect(!transitionEvents.contains(.destinationRevealed(nextID)))
            #expect(!transitionEvents.contains(.cloneRemoved(nextID)))

            browsingAnimator.stopAnimation(false)
            browsingAnimator.finishAnimation(at: .end)
            for _ in 0 ..< 30 where coordinator.isActive {
                await waitForDisplayTurn()
            }
            #expect(store.state.presentation == .browsing)
            #expect(coordinator.isActive == false)
            #expect(nextWebView.window != nil)
            let revealIndex = try #require(
                transitionEvents.firstIndex(of: .destinationRevealed(nextID)),
            )
            let cloneRemovalIndex = try #require(
                transitionEvents.firstIndex(of: .cloneRemoved(nextID)),
            )
            #expect(geometryIndex < revealIndex)
            #expect(revealIndex <= cloneRemovalIndex)
            let overlays = allViews(in: hostingController.view)
                .compactMap { $0 as? BrowserTabTransitionOverlayView }
            let overlaysAreEmpty = overlays.allSatisfy(\.subviews.isEmpty)
            #expect(overlaysAreEmpty)
            attachmentEvents.removeAll()
            currentID = nextID
        }
    }

    @Test("Real compact layout drives the normal geometry handoff in both directions")
    func realLayoutTabOverviewUsesMountedContentRatio() throws {
        let tab = BrowserTab.startPage(id: BrowserTabID(UUID(1)))
        let store = Store(initialState: BrowserFeature.State(tabs: [tab], selectedTabID: tab.id)) {
            BrowserFeature()
        }
        var executions: [BrowserTabTransitionExecution] = []
        var animators: [UIViewPropertyAnimator] = []
        let coordinator = BrowserTabTransitionUIKitCoordinator(
            diagnostics: .init(
                onExecution: { executions.append($0) },
                onAnimatorCreated: { animators.append($0) },
            ),
        )
        let hostingController = UIHostingController(
            rootView: BrowserView(store: store, transitionCoordinator: coordinator),
        )
        let window = mount(hostingController, size: CGSize(width: 390, height: 700))
        let rootView = try #require(hostingController.view)

        let contentSurface = try #require(coordinator.surfaceRegistry.view(for: .content(tab.id)))
        let contentFrame = contentSurface.convert(contentSurface.bounds, to: rootView)
        let contentAspectRatio = contentFrame.width / contentFrame.height
        #expect(abs(contentAspectRatio - (390.0 / 844.0)) > 0.08)

        var enteredOverview = false
        coordinator.begin(
            token: 1,
            direction: .toOverview,
            tabID: tab.id,
            reduceMotion: false,
            onPresentationChange: {
                store.send(.showTabOverviewTapped)
                hostingController.view.layoutIfNeeded()
            },
            onCompletion: { enteredOverview = true },
        )
        for _ in 0 ..< 20 where cardSurfaceControllers(in: hostingController).isEmpty {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        }
        rootView.layoutIfNeeded()

        let cardSurface = try #require(
            allViewControllers(in: hostingController)
                .first { String(describing: type(of: $0)).contains("BrowserTabTransitionSurfaceHostController") },
        )
        let cardFrame = try #require(cardSurface.view).convert(cardSurface.view.bounds, to: rootView)
        let cardAspectRatio = cardFrame.width / cardFrame.height
        #expect(abs(cardAspectRatio - contentAspectRatio) < 0.01)
        for _ in 0 ..< 20 where !executions.contains(.geometry) {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        }
        #expect(executions.contains(.geometry))

        animators.first?.stopAnimation(false)
        animators.first?.finishAnimation(at: .end)
        for _ in 0 ..< 20 where !enteredOverview {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        }
        #expect(enteredOverview)
        var exitedBrowsing = false
        coordinator.begin(
            token: 2,
            direction: .toBrowsing,
            tabID: tab.id,
            reduceMotion: false,
            onPresentationChange: {
                store.send(.tabCardSelected(tab.id))
                hostingController.view.layoutIfNeeded()
            },
            onCompletion: { exitedBrowsing = true },
        )
        for _ in 0 ..< 20 where animators.count < 2 {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        }
        animators.last?.stopAnimation(false)
        animators.last?.finishAnimation(at: .end)
        for _ in 0 ..< 20 where !exitedBrowsing {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        }
        #expect(store.state.presentation == .browsing)
        #expect(exitedBrowsing)
        #expect(executions.count(where: { $0 == .geometry }) >= 2)
        #expect(animators.count >= 2)

        window.isHidden = true
        window.rootViewController = nil
    }

    @Test("Mounted Tab Overview restores its logical anchor across transitions and layouts")
    func mountedTabOverviewRestoresLogicalAnchorAcrossTransitionsAndLayouts() async throws {
        let tabIDs = try (0 ..< 24).map { index in
            let uuid = try #require(
                UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", 10_000 + index)),
            )
            return BrowserTabID(uuid)
        }
        let store = Store(
            initialState: BrowserFeature.State(
                tabs: tabIDs.map { .startPage(id: $0) },
                selectedTabID: tabIDs[0],
                presentation: .tabOverview,
            ),
        ) {
            BrowserFeature()
        }
        let compactController = UIHostingController(
            rootView: BrowserView(store: store)
                .environment(\.horizontalSizeClass, .compact),
        )
        let compactWindow = mount(compactController, size: CGSize(width: 390, height: 844))
        defer {
            compactWindow.isHidden = true
            compactWindow.rootViewController = nil
        }

        let compactScrollView = try #require(
            await waitForTabOverviewScrollView(in: compactController),
        )
        let compactMaximumOffset = compactScrollView.contentSize.height - compactScrollView.bounds.height
        #expect(compactMaximumOffset > 0)
        let compactAnchor = tabIDs[20]
        store.send(.tabOverviewScrollChanged(compactAnchor))

        for _ in 0 ..< 60 where compactScrollView.contentOffset.y <= 0 {
            compactController.view.layoutIfNeeded()
            await waitForDisplayTurn()
        }
        #expect(store.state.tabOverviewScrollPosition == compactAnchor)
        #expect(compactScrollView.contentOffset.y > 0)

        store.send(.tabCardSelected(compactAnchor))
        compactController.view.layoutIfNeeded()
        #expect(store.state.presentation == .browsing)
        store.send(.showTabOverviewTapped)

        let restoredCompactScrollView = try #require(
            await waitForTabOverviewScrollView(in: compactController),
        )
        for _ in 0 ..< 60 where restoredCompactScrollView.contentOffset.y <= 0 {
            compactController.view.layoutIfNeeded()
            await waitForDisplayTurn()
        }
        #expect(store.state.tabOverviewScrollPosition == compactAnchor)
        #expect(restoredCompactScrollView.contentOffset.y > 0)

        compactWindow.isHidden = true
        compactWindow.rootViewController = nil
        let regularController = UIHostingController(
            rootView: BrowserView(store: store)
                .environment(\.horizontalSizeClass, .regular),
        )
        let regularWindow = mount(regularController, size: CGSize(width: 1_194, height: 834))
        defer {
            regularWindow.isHidden = true
            regularWindow.rootViewController = nil
        }

        let regularScrollView = try #require(
            await waitForTabOverviewScrollView(in: regularController),
        )
        #expect(regularScrollView.contentSize.height > regularScrollView.bounds.height)
        #expect(store.state.tabOverviewScrollPosition == compactAnchor)

        store.send(.tabCardSelected(compactAnchor))
        regularController.view.layoutIfNeeded()
        #expect(store.state.presentation == .browsing)
        store.send(.showTabOverviewTapped)

        let restoredRegularScrollView = try #require(
            await waitForTabOverviewScrollView(in: regularController),
        )
        for _ in 0 ..< 60 where restoredRegularScrollView.contentOffset.y <= 0 {
            regularController.view.layoutIfNeeded()
            await waitForDisplayTurn()
        }
        #expect(store.state.tabOverviewScrollPosition == compactAnchor)
        #expect(restoredRegularScrollView.contentOffset.y > 0)

        store.send(.closeTab(compactAnchor))
        #expect(!store.state.tabs.contains(where: { $0.id == compactAnchor }))
        #expect(
            store.state.tabOverviewScrollPosition.map { anchor in
                store.state.tabs.contains(where: { $0.id == anchor })
            } ?? true,
        )
    }

    @Test("Settled Tab Overview cards follow the resizable layout probe")
    func settledOverviewResizesEveryCardFromTheCurrentProbe() {
        let firstTab = BrowserTab.startPage(id: BrowserTabID(UUID(1)))
        let secondTab = BrowserTab.startPage(id: BrowserTabID(UUID(2)))
        let store = Store(
            initialState: BrowserFeature.State(
                tabs: [firstTab, secondTab],
                selectedTabID: firstTab.id,
                presentation: .tabOverview,
            ),
        ) {
            BrowserFeature()
        }
        let hostingController = UIHostingController(rootView: BrowserView(store: store))
        let window = mount(hostingController, size: CGSize(width: 390, height: 700))

        for _ in 0 ..< 20 where cardSurfaceControllers(in: hostingController).count < 2 {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        }
        let compactRatios = cardSurfaceControllers(in: hostingController).map(aspectRatio)
        #expect(compactRatios.count == 2)
        guard compactRatios.count == 2 else {
            window.isHidden = true
            window.rootViewController = nil
            return
        }

        #expect(abs(compactRatios[0] - compactRatios[1]) < 0.01)

        window.frame = CGRect(x: 0, y: 0, width: 1_194, height: 834)
        hostingController.view.frame = window.bounds
        hostingController.view.setNeedsLayout()
        hostingController.view.layoutIfNeeded()
        for _ in 0 ..< 20 {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
            let resizedRatios = cardSurfaceControllers(in: hostingController).map(aspectRatio)
            if let resizedRatio = resizedRatios.first,
               abs(resizedRatio - compactRatios[0]) > 0.08 {
                break
            }
        }

        let resizedRatios = cardSurfaceControllers(in: hostingController).map(aspectRatio)
        #expect(resizedRatios.count == 2)
        guard resizedRatios.count == 2 else {
            window.isHidden = true
            window.rootViewController = nil
            return
        }

        #expect(abs(resizedRatios[0] - resizedRatios[1]) < 0.01)
        #expect(abs(resizedRatios[0] - compactRatios[0]) > 0.08)

        window.isHidden = true
        window.rootViewController = nil
    }

    private func mount(_ controller: UIViewController, size: CGSize) -> UIWindow {
        let window = UIWindow(frame: CGRect(origin: .zero, size: size))
        window.rootViewController = controller
        window.makeKeyAndVisible()
        controller.view.frame = window.bounds
        controller.view.layoutIfNeeded()
        return window
    }

    private func waitForTabOverviewScrollView(in controller: UIViewController) async -> UIScrollView? {
        for _ in 0 ..< 60 {
            controller.view.layoutIfNeeded()
            // A Tab Overview card's stable close control is unique to the card grid. Walking from
            // that semantic descendant reaches the exact scroll container without guessing among
            // unrelated scroll views in the mounted Browser hierarchy.
            let cardScrollView = allViews(in: controller.view)
                .filter { $0.accessibilityLabel?.hasPrefix("Close ") == true }
                .compactMap { view -> UIScrollView? in
                    var currentAncestor = view.superview
                    while let ancestor = currentAncestor {
                        if let scrollView = ancestor as? UIScrollView {
                            return scrollView
                        }
                        currentAncestor = ancestor.superview
                    }
                    return nil
                }
                .first
            if let cardScrollView {
                return cardScrollView
            }

            let overflowingScrollViews = allViews(in: controller.view)
                .compactMap { $0 as? UIScrollView }
                .filter { $0.bounds.height > 0 && $0.contentSize.height > $0.bounds.height + 1 }
            guard overflowingScrollViews.count == 1,
                  let overflowingScrollView = overflowingScrollViews.first
            else {
                await waitForDisplayTurn()
                continue
            }

            return overflowingScrollView
        }
        return nil
    }

    private func descendants<ViewType: UIView>(
        of view: UIView,
        matching _: ViewType.Type,
    ) -> [ViewType] {
        view.subviews.flatMap { subview in
            let matches = subview as? ViewType
            return (matches.map { [$0] } ?? []) + descendants(of: subview, matching: ViewType.self)
        }
    }

    private func browserDismissalRecognizers(in view: UIView) -> [UITapGestureRecognizer] {
        allViews(in: view)
            .flatMap { $0.gestureRecognizers ?? [] }
            .compactMap { $0 as? UITapGestureRecognizer }
            .filter { recognizer in
                !recognizer.cancelsTouchesInView
                    && String(describing: recognizer.delegate.map { type(of: $0) }).contains(
                        "BrowserPresentationTapCoordinator",
                    )
            }
    }

    private func allViews(in view: UIView) -> [UIView] {
        [view] + view.subviews.flatMap(allViews)
    }

    private func allViewControllers(in controller: UIViewController) -> [UIViewController] {
        [controller] + controller.children.flatMap(allViewControllers)
    }

    private func cardSurfaceControllers(in hostingController: UIViewController) -> [UIViewController] {
        allViewControllers(in: hostingController)
            .filter { String(describing: type(of: $0)).contains("BrowserTabTransitionSurfaceHostController") }
    }

    private func aspectRatio(_ controller: UIViewController) -> CGFloat {
        controller.view.bounds.width / controller.view.bounds.height
    }

    private func center(of view: UIView, in target: UIView) -> CGPoint {
        view.convert(
            CGPoint(x: view.bounds.midX, y: view.bounds.midY),
            to: target,
        )
    }

    private func webKitValue(_ script: String, in webView: WKWebView) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            webView.evaluateJavaScript(script) { value, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let stringValue = value as? String {
                    continuation.resume(returning: stringValue)
                } else {
                    continuation.resume(throwing: CocoaError(.coderValueNotFound))
                }
            }
        }
    }

    private func waitForRenderedPixel(
        in view: UIView,
        expected: RenderedPixel,
        maximumDisplayTurns: Int = 30,
        at point: () -> CGPoint,
    ) async -> RenderedPixel? {
        var pixel: RenderedPixel?
        for _ in 0 ..< maximumDisplayTurns {
            pixel = renderedPixel(in: view, at: point())
            if pixel?.approximatelyMatches(expected) == true {
                return pixel
            }
            await waitForDisplayTurn()
        }
        return pixel
    }

    private func renderedPixel(in view: UIView, at point: CGPoint) -> RenderedPixel? {
        guard view.bounds.width > 0,
              view.bounds.height > 0,
              view.bounds.contains(point)
        else {
            return nil
        }

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        var didRender = false
        let image = UIGraphicsImageRenderer(size: view.bounds.size, format: format).image { context in
            view.layer.render(in: context.cgContext)
            didRender = true
        }
        guard didRender,
              let imageReference = image.cgImage
        else {
            return nil
        }

        let width = imageReference.width
        let height = imageReference.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(
            data: &bytes,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue,
        ) else {
            return nil
        }

        context.draw(imageReference, in: CGRect(x: 0, y: 0, width: width, height: height))
        let x = min(max(Int(point.x.rounded()), 0), width - 1)
        let y = min(max(Int(point.y.rounded()), 0), height - 1)
        let offset = ((height - 1 - y) * width + x) * 4
        return RenderedPixel(
            red: bytes[offset],
            green: bytes[offset + 1],
            blue: bytes[offset + 2],
            alpha: bytes[offset + 3],
        )
    }

    private func webKitTestDocument(
        text: String,
        background: String,
        includeVisibleText: Bool = true,
    ) -> String {
        let bodyContent = includeVisibleText
            ? "<p>\(text)</p>"
            : "<p style=\"display: none\">\(text)</p>"
        return """
        <!doctype html>
        <html>
        <head>
            <meta name="viewport" content="width=device-width, initial-scale=1">
            <style>
                html, body { margin: 0; width: 100%; height: 100%; background: \(background); }
                body { color: white; font: 24px -apple-system; }
                p { position: absolute; left: 16px; bottom: 16px; }
            </style>
        </head>
        <body>\(bodyContent)</body>
        </html>
        """
    }

    private func solidPreviewData(red: UInt8, green: UInt8, blue: UInt8) throws -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let image = UIGraphicsImageRenderer(size: CGSize(width: 64, height: 64), format: format)
            .image { context in
                UIColor(
                    red: CGFloat(red) / 255,
                    green: CGFloat(green) / 255,
                    blue: CGFloat(blue) / 255,
                    alpha: 1,
                ).setFill()
                context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
            }
        return try #require(image.pngData())
    }

    private func waitForWebKitDocument(in webView: WKWebView, expectedText: String) async throws {
        for _ in 0 ..< 240 {
            if let state = try? await webKitValue("document.readyState", in: webView),
               state == "complete",
               let bodyText = try? await webKitValue(
                   "String(document.body?.textContent ?? '')",
                   in: webView,
               ),
               bodyText.trimmingCharacters(in: .whitespacesAndNewlines) == expectedText {
                await waitForDisplayTurn()
                return
            }

            await waitForDisplayTurn()
        }

        throw CocoaError(.coderValueNotFound)
    }

    private func waitForDisplayTurn() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let target = DisplayLinkTarget {
                continuation.resume()
            }
            let displayLink = CADisplayLink(target: target, selector: #selector(DisplayLinkTarget.tick))
            displayLink.add(to: .main, forMode: .common)
        }
    }
}

private struct RenderedPixel: Equatable {
    let red: UInt8
    let green: UInt8
    let blue: UInt8
    let alpha: UInt8

    init(red: UInt8, green: UInt8, blue: UInt8, alpha: UInt8 = 255) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    func approximatelyMatches(_ expected: RenderedPixel, tolerance: UInt8 = 8) -> Bool {
        abs(Int(red) - Int(expected.red)) <= Int(tolerance)
            && abs(Int(green) - Int(expected.green)) <= Int(tolerance)
            && abs(Int(blue) - Int(expected.blue)) <= Int(tolerance)
            && alpha >= 240
    }
}

@MainActor
private final class DisplayLinkTarget: NSObject {
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
