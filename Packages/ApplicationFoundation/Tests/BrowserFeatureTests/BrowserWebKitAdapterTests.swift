//
//  BrowserWebKitAdapterTests.swift
//  MediaVault
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import ConcurrencyExtras
import CoreFoundation
import CoreGraphics
import Dependencies
import Foundation
import ObjectiveC
import SwiftUI
import Testing
import UIKit
import WebKit
@testable import BrowserFeature

@Suite("Browser WebKit adapter")
@MainActor
struct BrowserWebKitAdapterTests {
    @Test("WebKit rendering policy rejects layer-only output")
    func webKitRenderingPolicyRejectsLayerOnlyOutput() {
        let view = UIView(frame: CGRect(x: 0, y: 0, width: 40, height: 40))
        view.backgroundColor = .systemBlue
        view.isOpaque = true
        let drawFailure: @MainActor (UIView, CGRect, Bool) -> Bool = { _, _, _ in false }

        let webKitImage = BrowserSurfaceRenderer.image(
            from: view,
            afterScreenUpdates: false,
            opaque: true,
            renderingPolicy: .webKit,
            drawHierarchy: drawFailure,
        )
        let appOwnedImage = BrowserSurfaceRenderer.image(
            from: view,
            afterScreenUpdates: false,
            opaque: true,
            renderingPolicy: .appOwnedTransition,
            drawHierarchy: drawFailure,
        )

        #expect(webKitImage == nil)
        #expect(appOwnedImage != nil)
    }

    @Test("Contexts are keyed by stable tab ID and destroyed independently of selection")
    func contextLifecycle() {
        let adapter = BrowserWebKitAdapter()
        let first = BrowserTabID()
        let second = BrowserTabID()

        let firstView = adapter.ensureContext(for: first)
        #expect(adapter.ensureContext(for: first) === firstView)
        _ = adapter.ensureContext(for: second)
        #expect(adapter.contextCount == 2)

        adapter.destroyContext(for: first)
        #expect(adapter.hasContext(for: first) == false)
        #expect(adapter.hasContext(for: second))
    }

    @Test("Tagged history no-ops complete without a WebKit delegate callback")
    func taggedHistoryNoOpCompletesOperation() async {
        let adapter = BrowserWebKitAdapter()
        let tabID = BrowserTabID()
        _ = adapter.ensureContext(for: tabID)
        let stream = adapter.makeEventStream()
        var events = stream.makeAsyncIterator()
        let operationID = BrowserNavigationOperationID()

        adapter.execute(.goBack(tabID: tabID, operationID: operationID))

        guard case let .metadata(eventTabID, _, .operation(eventOperationID)) = await events.next() else {
            Issue.record("A synchronous history no-op did not complete its tagged operation")
            return
        }

        #expect(eventTabID == tabID)
        #expect(eventOperationID == operationID)
    }

    @Test("An untracked nil provisional navigation emits an external navigation start")
    func untrackedNilProvisionalNavigationEmitsNavigationStarted() async throws {
        let adapter = BrowserWebKitAdapter()
        let tabID = BrowserTabID()
        let webView = adapter.ensureContext(for: tabID)
        let delegate = try #require(webView.navigationDelegate)
        let stream = adapter.makeEventStream()
        var events = stream.makeAsyncIterator()
        defer { adapter.destroyContext(for: tabID) }

        delegate.webView?(webView, didStartProvisionalNavigation: nil)

        #expect(await events.next() == .navigationStarted(tabID: tabID))
    }

    @Test("An unidentified nil navigation completes its full lifecycle")
    func unidentifiedNilNavigationCompletesItsFullLifecycle() async throws {
        let adapter = BrowserWebKitAdapter()
        let tabID = BrowserTabID()
        let webView = adapter.ensureContext(for: tabID)
        let delegate = try #require(webView.navigationDelegate)
        let stream = adapter.makeEventStream()
        var events = stream.makeAsyncIterator()
        defer { adapter.destroyContext(for: tabID) }

        delegate.webView?(webView, didStartProvisionalNavigation: nil)
        #expect(await events.next() == .navigationStarted(tabID: tabID))

        delegate.webView?(webView, didCommit: nil)
        try #require(adapter.hasCommittedDocument(for: tabID))

        delegate.webView?(webView, didFinish: nil)
        guard case let .metadata(eventTabID, _, .untracked) = await events.next() else {
            Issue.record("An unidentified nil navigation did not emit untracked completion metadata")
            return
        }

        #expect(eventTabID == tabID)
        #expect(adapter.hasCommittedDocument(for: tabID))
    }

    @Test("An unidentified nil navigation failure is processed as untracked")
    func unidentifiedNilNavigationFailureClearsLifecycle() async throws {
        let adapter = BrowserWebKitAdapter()
        let tabID = BrowserTabID()
        let webView = adapter.ensureContext(for: tabID)
        let delegate = try #require(webView.navigationDelegate)
        let stream = adapter.makeEventStream()
        var events = stream.makeAsyncIterator()
        let failingURL = try #require(URL(string: "https://example.com/failure"))
        let error = NSError(
            domain: NSURLErrorDomain,
            code: NSURLErrorCannotConnectToHost,
            userInfo: [NSURLErrorFailingURLErrorKey: failingURL],
        )
        defer { adapter.destroyContext(for: tabID) }

        delegate.webView?(webView, didStartProvisionalNavigation: nil)
        #expect(await events.next() == .navigationStarted(tabID: tabID))

        delegate.webView?(webView, didFailProvisionalNavigation: nil, withError: error)
        delegate.webView?(webView, didStartProvisionalNavigation: nil)
        guard case let .navigationFailed(
            eventTabID,
            .connectionFailed(eventURL),
            .untracked,
        ) = await events.next() else {
            Issue.record("An unidentified nil navigation failure was not emitted as untracked")
            return
        }

        #expect(eventTabID == tabID)
        #expect(eventURL == failingURL)
        #expect(adapter.hasCommittedDocument(for: tabID) == false)

        #expect(await events.next() == .navigationStarted(tabID: tabID))
    }

    @Test("Failed unidentified nil navigation invalidates queued metadata")
    func failedUnidentifiedNilNavigationInvalidatesQueuedMetadata() async throws {
        let adapter = BrowserWebKitAdapter()
        let tabID = BrowserTabID()
        let webView = adapter.ensureContext(for: tabID)
        let delegate = try #require(webView.navigationDelegate)
        let stream = adapter.makeEventStream()
        var events = stream.makeAsyncIterator()
        let failingURL = try #require(URL(string: "https://example.com/failure"))
        let error = NSError(
            domain: NSURLErrorDomain,
            code: NSURLErrorCannotConnectToHost,
            userInfo: [NSURLErrorFailingURLErrorKey: failingURL],
        )
        defer { adapter.destroyContext(for: tabID) }

        delegate.webView?(webView, didStartProvisionalNavigation: nil)
        #expect(await events.next() == .navigationStarted(tabID: tabID))

        let metadataTask = try #require(adapter.scheduleMetadataEmissionForTesting(for: tabID))
        delegate.webView?(webView, didFailProvisionalNavigation: nil, withError: error)

        guard case .navigationFailed(_, _, .untracked) = await events.next() else {
            Issue.record("An unidentified nil navigation failure was not emitted as untracked")
            return
        }

        #expect(await metadataTask.value == false)

        // The invalidation must not poison later observations: a fresh observation still emits
        // with the current untracked correlation.
        let freshMetadataTask = try #require(adapter.scheduleMetadataEmissionForTesting(for: tabID))
        #expect(await freshMetadataTask.value == true)

        guard case let .metadata(freshTabID, _, .untracked) = await events.next() else {
            Issue.record("A fresh observation after the invalidation did not emit metadata")
            return
        }

        #expect(freshTabID == tabID)
    }

    @Test("A queued observation cannot be attributed to a later navigation's operation")
    func queuedObservationDoesNotInheritLaterNavigationOperation() async throws {
        let adapter = BrowserWebKitAdapter()
        let tabID = BrowserTabID()
        _ = adapter.ensureContext(for: tabID)
        let firstOperationID = BrowserNavigationOperationID()
        let secondOperationID = BrowserNavigationOperationID()
        let firstURL = try #require(URL(string: "about:blank"))
        let secondURL = try #require(URL(string: "about:blank#superseding"))
        defer { adapter.destroyContext(for: tabID) }

        // The first tagged load registers its navigation synchronously, so the queued epoch
        // belongs to the first operation. The second tagged load supersedes that correlation
        // before the queued emission runs, and the emission must be discarded instead of
        // inheriting the later navigation's operation.
        adapter.execute(.load(tabID: tabID, url: firstURL, operationID: firstOperationID))
        let queuedEmission = try #require(adapter.scheduleMetadataEmissionForTesting(for: tabID))
        adapter.execute(.load(tabID: tabID, url: secondURL, operationID: secondOperationID))

        #expect(await queuedEmission.value == false)
    }

    @Test("A WebKit property observation emits metadata for its tab through the main actor")
    func webKitPropertyObservationEmitsMetadata() async {
        let adapter = BrowserWebKitAdapter()
        let tabID = BrowserTabID()
        let stream = adapter.makeEventStream()
        var events = stream.makeAsyncIterator()
        defer { adapter.destroyContext(for: tabID) }

        // Registering a context delivers the initial `isLoading` observation synchronously. The
        // nonisolated handler must cross onto the main actor, and the emission must reach the
        // stream the reducer consumes.
        _ = adapter.ensureContext(for: tabID)

        guard case let .metadata(eventTabID, metadata, .untracked) = await events.next() else {
            Issue.record("The initial WebKit observation did not emit metadata")
            return
        }

        #expect(eventTabID == tabID)
        #expect(metadata.isLoading == false)
    }

    @Test("Preview capture uses the current viewport and projects success or failure as Sendable data")
    func previewCaptureProjectsViewportAndFailure() async throws {
        let image = try #require(UIImage(systemName: "globe"))
        let usedCurrentViewport = LockIsolated(false)
        let successAdapter = BrowserWebKitAdapter(snapshotter: { _, configuration, completion in
            usedCurrentViewport.setValue(configuration == nil)
            completion(image, nil)
        })
        let successID = BrowserTabID()
        let successRevision = BrowserTabPreviewRevision()
        _ = successAdapter.ensureContext(for: successID)
        let successStream = successAdapter.makeEventStream()
        var successEvents = successStream.makeAsyncIterator()
        successAdapter.execute(.capturePreview(tabID: successID, revision: successRevision))

        guard let successEvent = await successEvents.next() else {
            Issue.record("The successful snapshot did not produce a preview event")
            return
        }
        guard case let .preview(tabID, revision, pngData) = successEvent else {
            Issue.record("The successful snapshot produced the wrong event")
            return
        }

        #expect(tabID == successID)
        #expect(revision == successRevision)
        #expect(pngData?.isEmpty == false)
        #expect(usedCurrentViewport.value)

        let failureAdapter = BrowserWebKitAdapter(snapshotter: { _, _, completion in
            completion(nil, NSError(domain: "BrowserWebKitAdapterTests", code: 1))
        })
        let failureID = BrowserTabID()
        let failureRevision = BrowserTabPreviewRevision()
        _ = failureAdapter.ensureContext(for: failureID)
        let failureStream = failureAdapter.makeEventStream()
        var failureEvents = failureStream.makeAsyncIterator()
        failureAdapter.execute(.capturePreview(tabID: failureID, revision: failureRevision))

        #expect(await failureEvents.next() == .preview(
            tabID: failureID,
            revision: failureRevision,
            pngData: nil,
        ))
    }

    @Test("Reused native preview hosts follow the current transition role")
    func reusedNativePreviewHostRebindsTransitionRole() {
        let firstID = BrowserTabID(UUID(9_101))
        let secondID = BrowserTabID(UUID(9_102))
        let registry = BrowserTabTransitionSurfaceRegistry()
        let controller = BrowserNativePreviewCaptureController { view, bounds, afterScreenUpdates in
            view.drawHierarchy(in: bounds, afterScreenUpdates: afterScreenUpdates)
        }
        let host = BrowserNativePreviewCaptureHostController(
            content: Color.red,
            controller: controller,
            transitionRegistry: registry,
            transitionRole: .content(firstID),
        )
        _ = host.view
        defer { host.detachSurface() }

        #expect(registry.view(for: .content(firstID)) === host.view)

        host.update(
            content: Color.blue,
            transitionRegistry: registry,
            transitionRole: .content(secondID),
        )

        #expect(registry.view(for: .content(firstID)) == nil)
        #expect(registry.view(for: .content(secondID)) === host.view)
    }

    @Test("A destroyed context cannot emit a delayed script-close event")
    func destroyedContextIgnoresDelayedClose() async {
        let adapter = BrowserWebKitAdapter()
        let tabID = BrowserTabID()
        let webView = adapter.ensureContext(for: tabID)
        let delegate = webView.uiDelegate
        let stream = adapter.makeEventStream()
        adapter.destroyContext(for: tabID)

        let nextEvent = Task { @MainActor in
            var events = stream.makeAsyncIterator()
            return await events.next()
        }
        delegate?.webViewDidClose?(webView)
        try? await Task.sleep(for: .milliseconds(10))
        nextEvent.cancel()

        #expect(await nextEvent.value == nil)
    }

    @Test("Public WebKit configuration enables native gestures and preserves media boundaries")
    func publicConfiguration() {
        let webView = BrowserWebKitAdapter().ensureContext(for: BrowserTabID())
        #expect(webView.allowsBackForwardNavigationGestures)
        #expect(webView.configuration.allowsPictureInPictureMediaPlayback == false)
        #expect(webView.configuration.allowsAirPlayForMediaPlayback == false)
    }

    @Test("All Ephemeral tabs share a fresh store and profile changes tear down every owned context")
    func profileStoresShareAndRotateAcrossSessions() {
        let adapter = BrowserWebKitAdapter()
        let persistentID = BrowserTabID()
        let persistent = adapter.ensureContext(for: persistentID)

        #expect(persistent.configuration.websiteDataStore === WKWebsiteDataStore.default())

        adapter.execute(.configureProfile(profile: .ephemeral, retiringTabIDs: [persistentID]))
        #expect(adapter.contextCount == 0)
        #expect(adapter.hasContext(for: persistentID) == false)

        let firstEphemeralID = BrowserTabID()
        let secondEphemeralID = BrowserTabID()
        let firstEphemeral = adapter.ensureContext(for: firstEphemeralID)
        let secondEphemeral = adapter.ensureContext(for: secondEphemeralID)
        let firstSessionStore = firstEphemeral.configuration.websiteDataStore

        #expect(firstSessionStore === secondEphemeral.configuration.websiteDataStore)
        #expect(firstSessionStore !== WKWebsiteDataStore.default())

        adapter.execute(.configureProfile(
            profile: .persistentPrivate,
            retiringTabIDs: [firstEphemeralID, secondEphemeralID],
        ))
        #expect(adapter.contextCount == 0)
        let secondPersistentID = BrowserTabID()
        let secondPersistent = adapter.ensureContext(for: secondPersistentID)
        #expect(secondPersistent.configuration.websiteDataStore === WKWebsiteDataStore.default())

        adapter.execute(.configureProfile(profile: .ephemeral, retiringTabIDs: [secondPersistentID]))
        let nextSessionID = BrowserTabID()
        let nextSession = adapter.ensureContext(for: nextSessionID)
        #expect(nextSession.configuration.websiteDataStore !== firstSessionStore)

        adapter.destroyContext(for: firstEphemeralID)
        adapter.destroyContext(for: secondEphemeralID)
        adapter.destroyContext(for: persistentID)
        adapter.destroyContext(for: secondPersistentID)
        adapter.destroyContext(for: nextSessionID)
    }

    @Test("Delayed commands cannot recreate a tab retired by a profile boundary")
    func delayedCommandsCannotRecreateRetiredContexts() throws {
        let createdWebViewCount = LockIsolated(0)
        let adapter = BrowserWebKitAdapter(makeWebView: { frame, configuration in
            createdWebViewCount.withValue { $0 += 1 }
            return WKWebView(frame: frame, configuration: configuration)
        })
        let tabID = BrowserTabID()
        let destination = try #require(URL(string: "https://retired.example"))
        _ = adapter.ensureContext(for: tabID)

        adapter.execute(.configureProfile(profile: .ephemeral, retiringTabIDs: [tabID]))
        adapter.execute(.ensureContext(tabID: tabID))
        adapter.execute(.load(tabID: tabID, url: destination, operationID: .init()))

        #expect(adapter.contextCount == 0)
        #expect(adapter.hasContext(for: tabID) == false)
        #expect(adapter.ensureActiveContext(for: tabID) == nil)
        #expect(createdWebViewCount.value == 1)
    }

    @Test("Site-created popup contexts use the current Ephemeral store")
    func popupUsesActiveProfileStore() {
        let popupID = BrowserTabID()
        let adapter = BrowserWebKitAdapter(makeTabID: { popupID })
        adapter.execute(.configureProfile(profile: .ephemeral, retiringTabIDs: []))
        let openerID = BrowserTabID()
        let opener = adapter.ensureContext(for: openerID)
        let popup = adapter.makePopup(
            openerID: openerID,
            configuration: .init(),
            url: URL(string: "https://popup.example"),
        )

        #expect(popup.configuration.websiteDataStore === opener.configuration.websiteDataStore)
        adapter.destroyContext(for: popupID)
        adapter.destroyContext(for: openerID)
    }

    @Test("The WebKit bridge forwards pull-to-refresh without retaining reducer state")
    func pullToRefreshBridge() {
        var refreshCount = 0
        let bridge = BrowserWebView(tabID: BrowserTabID()) {
            refreshCount += 1
        }

        bridge.makeCoordinator().refresh()

        #expect(refreshCount == 1)
    }

    @Test("A custom BrowserWebView adapter owns the default readiness coordinator")
    func customBrowserWebViewAdapterOwnsDefaultReadinessCoordinator() {
        let tabID = BrowserTabID()
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 320, height: 640))
        let adapter = BrowserWebKitAdapter(makeWebView: { _, _ in webView })
        let registry = BrowserTabTransitionSurfaceRegistry()
        let readinessContext = BrowserWebKitReadinessContext()
        _ = adapter.ensureContext(for: tabID)
        let bridge = BrowserWebView(
            tabID: tabID,
            onRefresh: {},
            transitionRegistry: registry,
            adapter: adapter,
            readinessContext: readinessContext,
        )
        let coordinator = bridge.makeCoordinator()

        #expect(
            coordinator.resolveReadinessContext(
                readinessContext,
                for: webView,
                tabID: tabID,
            ) == readinessContext,
        )

        adapter.destroyContext(for: tabID)
    }

    @Test("Readiness contexts distinguish successive reducer navigation lifecycles")
    func readinessContextsDistinguishSuccessiveNavigationLifecycles() {
        let firstOperationID = BrowserNavigationOperationID()
        let secondOperationID = BrowserNavigationOperationID()
        let firstContext = BrowserWebKitReadinessContext(
            navigationOperationID: firstOperationID,
        )
        let secondContext = BrowserWebKitReadinessContext(
            navigationOperationID: secondOperationID,
        )

        #expect(firstContext != secondContext)
    }

    @Test("The error-surface refresh bridge forwards pull-to-refresh")
    func errorSurfaceRefreshBridge() {
        var action: BrowserFeature.Action?
        let bridge = BrowserErrorRefreshBridge {
            action = .pullToRefresh
        }

        bridge.refresh()

        #expect(action == .pullToRefresh)
    }

    @Test("UIKit and SwiftUI scroll lifecycle values map to explicit Browser adapter states")
    func refreshLifecycleAdaptersMapFrameworkStates() {
        #expect(BrowserRefreshWebKitPanState(gestureRecognizerState: .possible) == .possible)
        #expect(BrowserRefreshWebKitPanState(gestureRecognizerState: .began) == .began)
        #expect(BrowserRefreshWebKitPanState(gestureRecognizerState: .changed) == .changed)
        #expect(BrowserRefreshWebKitPanState(gestureRecognizerState: .ended) == .ended)
        #expect(BrowserRefreshWebKitPanState(gestureRecognizerState: .cancelled) == .cancelled)
        #expect(BrowserRefreshWebKitPanState(gestureRecognizerState: .failed) == .failed)
        #expect(BrowserRefreshNativeScrollPhase(scrollPhase: .tracking) == .tracking)
        #expect(BrowserRefreshNativeScrollPhase(scrollPhase: .interacting) == .interacting)
        #expect(BrowserRefreshNativeScrollPhase(scrollPhase: .decelerating) == .decelerating)
        #expect(BrowserRefreshNativeScrollPhase(scrollPhase: .idle) == .idle)
        #expect(BrowserRefreshNativeScrollPhase(scrollPhase: .animating) == .animating)
    }

    @Test("Suppressed WebKit refreshes still end the control without dispatching")
    func suppressedWebKitRefreshEndsControlWithoutDispatch() throws {
        let tabID = BrowserTabID()
        let arbitrator = BrowserRefreshGestureArbitrator()
        let keyboardPresence = BrowserSoftwareKeyboardPresence()
        keyboardPresence.receive(.willShow)
        var refreshCount = 0
        let bridge = BrowserWebView(
            tabID: tabID,
            onRefresh: { refreshCount += 1 },
            transitionRegistry: BrowserTabTransitionSurfaceRegistry(),
            refreshGestureArbitrator: arbitrator,
            softwareKeyboardPresence: keyboardPresence,
        )
        let coordinator = bridge.makeCoordinator()
        coordinator.updateRefreshSurface(
            tabID: tabID,
            arbitrator: arbitrator,
            keyboardPresence: keyboardPresence,
            isInteractiveDismissalEnabled: true,
        )
        let surfaceID = try #require(coordinator.refreshSurfaceID)
        arbitrator.receiveWebKitPanState(.began, on: surfaceID, input: .init(
            isInteractiveDismissalEnabled: true,
            isSoftwareKeyboardPresent: keyboardPresence.isPresent,
        ))
        keyboardPresence.receive(.didHide)
        arbitrator.receiveWebKitPanState(.ended, on: surfaceID, input: .init(
            isInteractiveDismissalEnabled: true,
            isSoftwareKeyboardPresent: keyboardPresence.isPresent,
        ))

        let refreshControl = UIRefreshControl()
        coordinator.bindRefreshControl(refreshControl)
        refreshControl.beginRefreshing()
        coordinator.refreshControlValueChanged(refreshControl)

        #expect(refreshCount == 0)
        #expect(refreshControl.isRefreshing == false)
    }

    @Test("The native refresh bridge retains suppression through idle and consumes each pull once")
    func nativeRefreshBridgeConsumesSuppressedAndEligibleGesturesOnce() {
        let arbitrator = BrowserRefreshGestureArbitrator()
        let surfaceID = BrowserRefreshSurfaceID()
        arbitrator.mount(surfaceID)
        let keyboardPresence = BrowserSoftwareKeyboardPresence()
        keyboardPresence.receive(.willShow)
        var refreshCount = 0
        let bridge = BrowserErrorRefreshBridge(
            onRefresh: { refreshCount += 1 },
            refreshGestureArbitrator: arbitrator,
            surfaceID: surfaceID,
            keyboardInput: {
                .init(isInteractiveDismissalEnabled: true, isSoftwareKeyboardPresent: keyboardPresence.isPresent)
            },
        )

        bridge.receiveNativeScrollPhase(.tracking)
        keyboardPresence.receive(.willHide)
        keyboardPresence.receive(.didHide)
        bridge.receiveNativeScrollPhase(.interacting)
        bridge.receiveNativeScrollPhase(.idle)
        bridge.refresh()
        bridge.refresh()
        #expect(refreshCount == 0)

        bridge.receiveNativeScrollPhase(.interacting)
        bridge.receiveNativeScrollPhase(.idle)
        bridge.refresh()
        bridge.refresh()
        #expect(refreshCount == 1)
    }

    @Test("Native programmatic animation cancels active touch and preserves completed pull")
    func nativeAnimatingPreservesOnlyCompletedRefreshDecisions() {
        let arbitrator = BrowserRefreshGestureArbitrator()
        let surfaceID = BrowserRefreshSurfaceID()
        arbitrator.mount(surfaceID)
        var refreshCount = 0
        let bridge = BrowserErrorRefreshBridge(
            onRefresh: { refreshCount += 1 },
            refreshGestureArbitrator: arbitrator,
            surfaceID: surfaceID,
            keyboardInput: { .init(isInteractiveDismissalEnabled: true, isSoftwareKeyboardPresent: false) },
        )

        bridge.receiveNativeScrollPhase(.animating)
        bridge.refresh()
        #expect(refreshCount == 0)

        bridge.receiveNativeScrollPhase(.tracking)
        bridge.receiveNativeScrollPhase(.interacting)
        bridge.receiveNativeScrollPhase(.animating)
        bridge.refresh()
        #expect(refreshCount == 0)

        bridge.receiveNativeScrollPhase(.tracking)
        bridge.receiveNativeScrollPhase(.interacting)
        bridge.receiveNativeScrollPhase(.decelerating)
        bridge.receiveNativeScrollPhase(.animating)
        bridge.refresh()
        bridge.refresh()
        #expect(refreshCount == 1)
    }

    @Test("A will-show keyboard signal suppresses a drag before did-show")
    func keyboardWillShowParticipatesBeforeDidShow() {
        var keyboard = BrowserSoftwareKeyboardPresenceState()
        keyboard.receive(.willShow)
        #expect(keyboard.isPresent)

        var arbitration = BrowserRefreshGestureArbitration()
        let surface = BrowserRefreshSurfaceID()
        arbitration.mount(surface)
        arbitration.receiveWebKitPanState(
            .began,
            on: surface,
            input: .init(isInteractiveDismissalEnabled: true, isSoftwareKeyboardPresent: keyboard.isPresent),
        )
        keyboard.receive(.didShow)
        arbitration.receiveWebKitPanState(.ended, on: surface, input: .init(
            isInteractiveDismissalEnabled: true,
            isSoftwareKeyboardPresent: keyboard.isPresent,
        ))

        let shouldDispatch = arbitration.consumeRefresh(on: surface)
        #expect(shouldDispatch == false)
    }

    @Test("Keyboard and focus changes during a drag do not change its latched decision")
    func keyboardDismissalDecisionIsLatchedForWebKitGesture() {
        var keyboard = BrowserSoftwareKeyboardPresenceState()
        keyboard.receive(.willShow)

        var arbitration = BrowserRefreshGestureArbitration()
        let surface = BrowserRefreshSurfaceID()
        arbitration.mount(surface)
        arbitration.receiveWebKitPanState(
            .began,
            on: surface,
            input: .init(isInteractiveDismissalEnabled: true, isSoftwareKeyboardPresent: keyboard.isPresent),
        )

        keyboard.receive(.willHide)
        #expect(keyboard.isPresent)
        keyboard.receive(.didHide)
        #expect(keyboard.isPresent == false)
        arbitration.receiveWebKitPanState(.changed, on: surface, input: .init(
            isInteractiveDismissalEnabled: true,
            isSoftwareKeyboardPresent: keyboard.isPresent,
        ))
        arbitration.receiveWebKitPanState(.ended, on: surface, input: .init(
            isInteractiveDismissalEnabled: true,
            isSoftwareKeyboardPresent: keyboard.isPresent,
        ))

        let shouldDispatch = arbitration.consumeRefresh(on: surface)
        #expect(shouldDispatch == false)
    }

    @Test("Focus without a participating software keyboard leaves refresh eligible")
    func focusWithoutSoftwareKeyboardKeepsRefreshEligible() {
        var arbitration = BrowserRefreshGestureArbitration()
        let surface = BrowserRefreshSurfaceID()
        arbitration.mount(surface)
        arbitration.receiveWebKitPanState(.began, on: surface, input: .init(
            isInteractiveDismissalEnabled: true,
            isSoftwareKeyboardPresent: false,
        ))
        arbitration.receiveWebKitPanState(.ended, on: surface, input: .init(
            isInteractiveDismissalEnabled: true,
            isSoftwareKeyboardPresent: false,
        ))

        let shouldDispatch = arbitration.consumeRefresh(on: surface)
        let duplicateShouldDispatch = arbitration.consumeRefresh(on: surface)
        #expect(shouldDispatch)
        #expect(duplicateShouldDispatch == false)
    }

    @Test("Cancelled and failed WebKit pans reset before the next gesture")
    func cancelledAndFailedWebKitPansResetArbitration() {
        for terminalState in [BrowserRefreshWebKitPanState.cancelled, .failed] {
            var arbitration = BrowserRefreshGestureArbitration()
            let surface = BrowserRefreshSurfaceID()
            arbitration.mount(surface)
            arbitration.receiveWebKitPanState(.began, on: surface, input: .init(
                isInteractiveDismissalEnabled: true,
                isSoftwareKeyboardPresent: true,
            ))
            arbitration.receiveWebKitPanState(terminalState, on: surface, input: .init(
                isInteractiveDismissalEnabled: true,
                isSoftwareKeyboardPresent: true,
            ))
            arbitration.receiveWebKitPanState(.began, on: surface, input: .init(
                isInteractiveDismissalEnabled: true,
                isSoftwareKeyboardPresent: false,
            ))
            arbitration.receiveWebKitPanState(.ended, on: surface, input: .init(
                isInteractiveDismissalEnabled: true,
                isSoftwareKeyboardPresent: false,
            ))

            let shouldDispatch = arbitration.consumeRefresh(on: surface)
            #expect(shouldDispatch)
        }
    }

    @Test("A native tracking phase that returns directly to idle resets the gesture")
    func nativeTrackingToIdleResetsArbitration() {
        var arbitration = BrowserRefreshGestureArbitration()
        let surface = BrowserRefreshSurfaceID()
        arbitration.mount(surface)
        arbitration.receiveNativeScrollPhase(.tracking, on: surface, input: .init(
            isInteractiveDismissalEnabled: true,
            isSoftwareKeyboardPresent: true,
        ))
        arbitration.receiveNativeScrollPhase(.idle, on: surface, input: .init(
            isInteractiveDismissalEnabled: true,
            isSoftwareKeyboardPresent: false,
        ))

        let trackingOnlyShouldDispatch = arbitration.consumeRefresh(on: surface)
        #expect(trackingOnlyShouldDispatch == false)
        arbitration.receiveNativeScrollPhase(.interacting, on: surface, input: .init(
            isInteractiveDismissalEnabled: true,
            isSoftwareKeyboardPresent: false,
        ))
        arbitration.receiveNativeScrollPhase(.idle, on: surface, input: .init(
            isInteractiveDismissalEnabled: true,
            isSoftwareKeyboardPresent: false,
        ))

        let laterGestureShouldDispatch = arbitration.consumeRefresh(on: surface)
        #expect(laterGestureShouldDispatch)
    }

    @Test("Native tracking through interaction preserves a suppressed outcome until refresh")
    func nativeTrackingInteractionIdleRetainsSuppressedOutcome() {
        var arbitration = BrowserRefreshGestureArbitration()
        let surface = BrowserRefreshSurfaceID()
        arbitration.mount(surface)
        arbitration.receiveNativeScrollPhase(.tracking, on: surface, input: .init(
            isInteractiveDismissalEnabled: true,
            isSoftwareKeyboardPresent: true,
        ))
        arbitration.receiveNativeScrollPhase(.interacting, on: surface, input: .init(
            isInteractiveDismissalEnabled: true,
            isSoftwareKeyboardPresent: false,
        ))
        arbitration.receiveNativeScrollPhase(.idle, on: surface, input: .init(
            isInteractiveDismissalEnabled: true,
            isSoftwareKeyboardPresent: false,
        ))

        let shouldDispatch = arbitration.consumeRefresh(on: surface)
        let duplicateShouldDispatch = arbitration.consumeRefresh(on: surface)
        #expect(shouldDispatch == false)
        #expect(duplicateShouldDispatch == false)
    }

    @Test("A later independent native gesture dispatches one eligible refresh")
    func subsequentNativeGestureConsumesEligibleOutcomeOnce() {
        var arbitration = BrowserRefreshGestureArbitration()
        let surface = BrowserRefreshSurfaceID()
        arbitration.mount(surface)
        arbitration.receiveNativeScrollPhase(.tracking, on: surface, input: .init(
            isInteractiveDismissalEnabled: true,
            isSoftwareKeyboardPresent: true,
        ))
        arbitration.receiveNativeScrollPhase(.interacting, on: surface, input: .init(
            isInteractiveDismissalEnabled: true,
            isSoftwareKeyboardPresent: false,
        ))
        arbitration.receiveNativeScrollPhase(.idle, on: surface, input: .init(
            isInteractiveDismissalEnabled: true,
            isSoftwareKeyboardPresent: false,
        ))
        let firstGestureShouldDispatch = arbitration.consumeRefresh(on: surface)
        #expect(firstGestureShouldDispatch == false)

        arbitration.receiveNativeScrollPhase(.interacting, on: surface, input: .init(
            isInteractiveDismissalEnabled: true,
            isSoftwareKeyboardPresent: false,
        ))
        arbitration.receiveNativeScrollPhase(.decelerating, on: surface, input: .init(
            isInteractiveDismissalEnabled: true,
            isSoftwareKeyboardPresent: false,
        ))

        let shouldDispatch = arbitration.consumeRefresh(on: surface)
        let duplicateShouldDispatch = arbitration.consumeRefresh(on: surface)
        #expect(shouldDispatch)
        #expect(duplicateShouldDispatch == false)
    }

    @Test("Native interaction starts a gesture when tracking was not emitted")
    func nativeInteractingStartsWithoutTracking() {
        var arbitration = BrowserRefreshGestureArbitration()
        let surface = BrowserRefreshSurfaceID()
        arbitration.mount(surface)
        arbitration.receiveNativeScrollPhase(.interacting, on: surface, input: .init(
            isInteractiveDismissalEnabled: true,
            isSoftwareKeyboardPresent: false,
        ))
        arbitration.receiveNativeScrollPhase(.idle, on: surface, input: .init(
            isInteractiveDismissalEnabled: true,
            isSoftwareKeyboardPresent: false,
        ))

        let shouldDispatch = arbitration.consumeRefresh(on: surface)
        #expect(shouldDispatch)
    }

    @Test("Replacing a refresh surface invalidates its unconsumed outcome")
    func replacingRefreshSurfaceInvalidatesPreviousOutcome() {
        var arbitration = BrowserRefreshGestureArbitration()
        let outgoingSurface = BrowserRefreshSurfaceID()
        let incomingSurface = BrowserRefreshSurfaceID()
        arbitration.mount(outgoingSurface)
        arbitration.receiveWebKitPanState(.began, on: outgoingSurface, input: .init(
            isInteractiveDismissalEnabled: true,
            isSoftwareKeyboardPresent: true,
        ))
        arbitration.receiveWebKitPanState(.ended, on: outgoingSurface, input: .init(
            isInteractiveDismissalEnabled: true,
            isSoftwareKeyboardPresent: true,
        ))

        arbitration.mount(incomingSurface)
        arbitration.unmount(outgoingSurface)

        let staleSurfaceShouldDispatch = arbitration.consumeRefresh(on: outgoingSurface)
        let incomingSurfaceShouldDispatch = arbitration.consumeRefresh(on: incomingSurface)
        #expect(staleSurfaceShouldDispatch == false)
        #expect(incomingSurfaceShouldDispatch == false)
        arbitration.receiveWebKitPanState(.began, on: incomingSurface, input: .init(
            isInteractiveDismissalEnabled: true,
            isSoftwareKeyboardPresent: false,
        ))
        arbitration.receiveWebKitPanState(.ended, on: incomingSurface, input: .init(
            isInteractiveDismissalEnabled: true,
            isSoftwareKeyboardPresent: false,
        ))

        let shouldDispatch = arbitration.consumeRefresh(on: incomingSurface)
        let duplicateShouldDispatch = arbitration.consumeRefresh(on: incomingSurface)
        #expect(shouldDispatch)
        #expect(duplicateShouldDispatch == false)
    }

    @Test("Internal cancellation is not mapped to app-owned error UI")
    func cancellationMapping() throws {
        #expect(try BrowserWebKitAdapter.navigationError(
            NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled),
            failingURL: #require(URL(string: "https://example.com")),
        ) == nil)
    }

    @Test("Site-created tabs emit stable creation order while only the first requests foreground")
    func popupOrderingAndFocus() async throws {
        let openerID = BrowserTabID()
        let firstID = BrowserTabID()
        let secondID = BrowserTabID()
        var tabIDs = [firstID, secondID].makeIterator()
        let adapter = BrowserWebKitAdapter {
            guard let id = tabIDs.next() else {
                preconditionFailure("The popup fixture provides exactly two IDs")
            }

            return id
        }
        let firstURL = try #require(URL(string: "https://first.example"))
        let secondURL = try #require(URL(string: "https://second.example"))
        let stream = adapter.makeEventStream()
        var events = stream.makeAsyncIterator()

        _ = adapter.makePopup(openerID: openerID, configuration: .init(), url: firstURL)
        _ = adapter.makePopup(openerID: openerID, configuration: .init(), url: secondURL)

        #expect(await events.next() == .siteCreatedTab(
            openerID: openerID,
            tabID: firstID,
            url: firstURL,
            foreground: true,
        ))
        #expect(await events.next() == .siteCreatedTab(
            openerID: openerID,
            tabID: secondID,
            url: secondURL,
            foreground: false,
        ))
        adapter.destroyContext(for: firstID)
        adapter.destroyContext(for: secondID)
    }

    @Test("Adapter-scoped back-forward tokens distinguish repeated URLs")
    func repeatedBackForwardURLsKeepIdentity() throws {
        let first = NSObject()
        let second = NSObject()
        let registry = BrowserBackForwardTokenRegistry<NSObject>()
        let tokens = registry.rebuild([first, second])
        let duplicateURL = try #require(URL(string: "https://example.com/repeated"))
        let entries = tokens.map { BrowserBackForwardEntry(token: $0, title: nil, url: duplicateURL) }

        #expect(entries[0].url == entries[1].url)
        #expect(entries[0].token != entries[1].token)
        #expect(registry.resolve(entries[0].token) === first)
        #expect(registry.resolve(entries[1].token) === second)
    }

    @Test("Public link context menu preserves native non-link menus")
    func linkContextMenuAvailability() throws {
        let linkURL = try #require(URL(string: "https://example.com/linked"))

        #expect(BrowserWebKitLinkContextMenu.actions(for: linkURL) == [
            .open,
            .openInNewTab,
            .copyLink,
            .shareLink,
        ])
        #expect(BrowserWebKitLinkContextMenu.actions(for: nil).isEmpty)
    }

    @Test("WebKit current-item projection updates same-document URL without accepting a provisional URL")
    func sameDocumentURLProjection() throws {
        let originalURL = try #require(URL(string: "https://example.com/article"))
        let sameDocumentURL = try #require(URL(string: "https://example.com/article#comments"))
        var projection = BrowserWebKitCommittedURLProjection(committedURL: originalURL)

        // A provisional webView.url change has no current history item and must not replace A.
        projection.update(authoritativeCurrentItemURL: nil)
        #expect(projection.committedURL == originalURL)
        projection.update(authoritativeCurrentItemURL: originalURL)
        #expect(projection.committedURL == originalURL)
        projection.update(authoritativeCurrentItemURL: sameDocumentURL)
        #expect(projection.committedURL == sameDocumentURL)
    }

    @Test("JavaScript dialog presentation models keep alert acknowledgement-only semantics")
    func javaScriptDialogPresentationSemantics() {
        #expect(BrowserJavaScriptDialogPresentation.alert.actions == [.ok])
        #expect(BrowserJavaScriptDialogPresentation.confirm.actions == [.cancel, .ok])
        #expect(BrowserJavaScriptDialogPresentation.prompt.includesTextField)
        #expect(BrowserJavaScriptDialogPresentation.prompt.actions == [.cancel, .ok])
    }
}
