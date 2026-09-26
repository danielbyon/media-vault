//
//  BrowserWebKitAdapterTests.swift
//  MediaVault
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import ConcurrencyExtras
import Foundation
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
        let delegate = try #require(webView.navigationDelegate as? WKNavigationDelegate)
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
        let delegate = try #require(webView.navigationDelegate as? WKNavigationDelegate)
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
        let delegate = try #require(webView.navigationDelegate as? WKNavigationDelegate)
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
        let delegate = try #require(webView.navigationDelegate as? WKNavigationDelegate)
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

        guard case let .navigationFailed(_, _, .untracked) = await events.next() else {
            Issue.record("An unidentified nil navigation failure was not emitted as untracked")
            return
        }

        #expect(await metadataTask.value == false)
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

    @Test("Native preview capture honors draw failure and detachment")
    func nativePreviewCaptureHonorsFailureAndDetachment() {
        var requestedAfterScreenUpdates = false
        let controller = BrowserNativePreviewCaptureController { view, _, afterScreenUpdates in
            requestedAfterScreenUpdates = afterScreenUpdates
            guard let context = UIGraphicsGetCurrentContext() else {
                return false
            }

            view.layer.render(in: context)
            return true
        }
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 120, height: 80))
        let rootViewController = UIViewController()
        window.rootViewController = rootViewController
        let surface = UIView(frame: rootViewController.view.bounds)
        surface.backgroundColor = .systemBackground
        rootViewController.view.addSubview(surface)
        window.makeKeyAndVisible()
        rootViewController.view.frame = window.bounds
        surface.frame = rootViewController.view.bounds
        rootViewController.view.layoutIfNeeded()
        flushUIKitRendering()
        controller.attach(surface: surface)

        #expect(controller.capture()?.isEmpty == false)
        #expect(requestedAfterScreenUpdates)

        let failingController = BrowserNativePreviewCaptureController { _, _, _ in false }
        failingController.attach(surface: surface)
        #expect(failingController.capture() == nil)

        controller.detach(surface: surface)
        #expect(controller.capture() == nil)
        window.isHidden = true
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

    @Test("Mounted native preview capture includes only the represented surface")
    func mountedNativePreviewCaptureUsesRepresentedSurface() throws {
        let renderLayer: @MainActor (UIView, CGRect, Bool) -> Bool = { view, _, _ in
            guard let context = UIGraphicsGetCurrentContext() else {
                return false
            }

            view.layer.render(in: context)
            return true
        }
        let startController = BrowserNativePreviewCaptureController(drawHierarchy: renderLayer)
        let errorController = BrowserNativePreviewCaptureController(drawHierarchy: renderLayer)
        let terminatedController = BrowserNativePreviewCaptureController(drawHierarchy: renderLayer)
        let rootView = AnyView(
            VStack(spacing: 0) {
                Color.blue.frame(height: 40)
                BrowserNativePreviewCapture(
                    content: Color.red.overlay {
                        Text("Start Page")
                            .foregroundStyle(.white)
                    },
                    controller: startController,
                )
                .frame(width: 160, height: 100)
                BrowserNativePreviewCapture(
                    content: Color.orange.overlay {
                        Text("Page Error")
                            .foregroundStyle(.white)
                    },
                    controller: errorController,
                )
                .frame(width: 160, height: 100)
                BrowserNativePreviewCapture(
                    content: Color.purple.overlay {
                        Text("Page Ended")
                            .foregroundStyle(.white)
                    },
                    controller: terminatedController,
                )
                .frame(width: 160, height: 100)
            }
            .frame(width: 160, height: 340),
        )
        let hostingController = UIHostingController(rootView: rootView)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 160, height: 340))
        window.rootViewController = hostingController
        window.makeKeyAndVisible()
        hostingController.view.frame = window.bounds
        hostingController.view.layoutIfNeeded()
        flushUIKitRendering()

        let startImageData = try #require(
            startController.capture(),
            "The mounted Start Page surface did not produce a capture",
        )
        let errorImageData = try #require(
            errorController.capture(),
            "The mounted error surface did not produce a capture",
        )
        let terminatedImageData = try #require(
            terminatedController.capture(),
            "The mounted terminated surface did not produce a capture",
        )
        let startImage = try #require(UIImage(data: startImageData))
        let errorImage = try #require(UIImage(data: errorImageData))
        let terminatedImage = try #require(UIImage(data: terminatedImageData))

        let expectedPixelSize = CGSize(
            width: 160 * window.screen.scale,
            height: 100 * window.screen.scale,
        )
        #expect(startImage.size == expectedPixelSize)
        #expect(errorImage.size == expectedPixelSize)
        #expect(terminatedImage.size == expectedPixelSize)
        let startPixel = try #require(rgbaPixel(in: startImage))
        let errorPixel = try #require(rgbaPixel(in: errorImage))
        let terminatedPixel = try #require(rgbaPixel(in: terminatedImage))

        #expect(startPixel.red > 180)
        #expect(startPixel.green < 80)
        #expect(startPixel.blue < 80)
        #expect(errorPixel.red > 180)
        #expect(errorPixel.green > 80)
        #expect(errorPixel.blue < 80)
        #expect(terminatedPixel.red > 80)
        #expect(terminatedPixel.green < 80)
        #expect(terminatedPixel.blue > 80)

        hostingController.rootView = AnyView(EmptyView())
        hostingController.view.layoutIfNeeded()
        #expect(startController.capture() == nil)
        #expect(errorController.capture() == nil)
        #expect(terminatedController.capture() == nil)
        window.isHidden = true
    }

    private func flushUIKitRendering() {
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
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
        let createdStores = LockIsolated<[WKWebsiteDataStore]>([])
        let adapter = BrowserWebKitAdapter(makeWebView: { frame, configuration in
            createdStores.withValue { $0.append(configuration.websiteDataStore) }
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
        #expect(createdStores.value.count == 1)
    }

    @Test("Site-created popup contexts use the current Ephemeral store")
    func popupUsesActiveProfileStore() throws {
        let popupID = BrowserTabID()
        let adapter = BrowserWebKitAdapter(makeTabID: { popupID })
        adapter.execute(.configureProfile(profile: .ephemeral, retiringTabIDs: []))
        let openerID = BrowserTabID()
        let opener = adapter.ensureContext(for: openerID)
        let popup = try adapter.makePopup(
            openerID: openerID,
            configuration: .init(),
            url: #require(URL(string: "https://popup.example")),
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

    @Test("A mounted refresh control rebinds to the current coordinator after remount")
    func mountedRefreshControlRebindsAfterDismantle() {
        let tabID = BrowserTabID()
        let webView = WKWebView(frame: .zero)
        let adapter = BrowserWebKitAdapter(makeWebView: { _, _ in webView })
        let registry = BrowserTabTransitionSurfaceRegistry()
        var outgoingRefreshCount = 0
        var updatedRefreshCount = 0
        var currentRefreshCount = 0
        var callbackObservedIdleControl: [Bool] = []
        let firstBridge = BrowserWebView(
            tabID: tabID,
            onRefresh: { outgoingRefreshCount += 1 },
            transitionRegistry: registry,
            adapter: adapter,
        )
        let hostingController = UIHostingController(rootView: AnyView(firstBridge))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 640))
        window.rootViewController = hostingController
        window.makeKeyAndVisible()
        hostingController.view.frame = window.bounds
        hostingController.view.layoutIfNeeded()
        defer {
            hostingController.rootView = AnyView(EmptyView())
            hostingController.view.setNeedsLayout()
            hostingController.view.layoutIfNeeded()
            adapter.destroyContext(for: tabID)
            window.isHidden = true
            window.rootViewController = nil
        }

        guard let refreshControl = webView.scrollView.refreshControl else {
            #expect(Bool(false), "The mounted WebKit scroll view should own a refresh control")
            return
        }

        let originalContentInset = webView.scrollView.contentInset
        #expect(adapter.webView(for: tabID) === webView)
        #expect(webView.superview != nil)
        #expect(refreshControl.allTargets.count == 1)

        let updatedBridge = BrowserWebView(
            tabID: tabID,
            onRefresh: { updatedRefreshCount += 1 },
            transitionRegistry: registry,
            adapter: adapter,
        )
        hostingController.rootView = AnyView(updatedBridge)
        hostingController.view.setNeedsLayout()
        hostingController.view.layoutIfNeeded()
        #expect(webView.scrollView.refreshControl === refreshControl)
        #expect(refreshControl.allTargets.count == 1)

        refreshControl.beginRefreshing()
        #expect(refreshControl.isRefreshing)
        #expect(deliverValueChanged(to: refreshControl) == 1)
        #expect(outgoingRefreshCount == 0)
        #expect(updatedRefreshCount == 1)
        #expect(refreshControl.isRefreshing == false)
        #expect(webView.scrollView.contentInset == originalContentInset)

        refreshControl.beginRefreshing()
        #expect(refreshControl.isRefreshing)
        hostingController.rootView = AnyView(EmptyView())
        hostingController.view.setNeedsLayout()
        hostingController.view.layoutIfNeeded()
        #expect(adapter.webView(for: tabID) === webView)
        #expect(webView.superview == nil)
        #expect(webView.scrollView.refreshControl === refreshControl)
        #expect(refreshControl.isRefreshing == false)
        #expect(refreshControl.allTargets.isEmpty)

        let remountedBridge = BrowserWebView(
            tabID: tabID,
            onRefresh: {
                currentRefreshCount += 1
                callbackObservedIdleControl.append(refreshControl.isRefreshing == false)
            },
            transitionRegistry: registry,
            adapter: adapter,
        )
        hostingController.rootView = AnyView(remountedBridge)
        hostingController.view.setNeedsLayout()
        hostingController.view.layoutIfNeeded()
        #expect(adapter.webView(for: tabID) === webView)
        #expect(webView.superview != nil)
        #expect(webView.scrollView.refreshControl === refreshControl)
        #expect(refreshControl.allTargets.count == 1)

        for expectedRefreshCount in 1 ... 2 {
            refreshControl.beginRefreshing()
            #expect(refreshControl.isRefreshing)
            #expect(deliverValueChanged(to: refreshControl) == 1)

            #expect(outgoingRefreshCount == 0)
            #expect(currentRefreshCount == expectedRefreshCount)
            #expect(refreshControl.isRefreshing == false)
            #expect(webView.scrollView.contentInset == originalContentInset)
        }
        #expect(callbackObservedIdleControl == [true, true])
    }

    @Test("A late coordinator dismantle preserves its successor's active refresh")
    func lateCoordinatorDismantlePreservesSuccessorRefresh() {
        let tabID = BrowserTabID()
        let webView = WKWebView(frame: .zero)
        let adapter = BrowserWebKitAdapter(makeWebView: { _, _ in webView })
        let registry = BrowserTabTransitionSurfaceRegistry()
        var outgoingRefreshCount = 0
        var successorRefreshCount = 0
        let outgoingBridge = BrowserWebView(
            tabID: tabID,
            onRefresh: { outgoingRefreshCount += 1 },
            transitionRegistry: registry,
            adapter: adapter,
        )
        let successorBridge = BrowserWebView(
            tabID: tabID,
            onRefresh: { successorRefreshCount += 1 },
            transitionRegistry: registry,
            adapter: adapter,
        )
        let parentController = UIViewController()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 640))
        let outgoingHostingController = UIHostingController(rootView: AnyView(outgoingBridge))
        let successorHostingController = UIHostingController(rootView: AnyView(successorBridge))
        window.rootViewController = parentController
        window.makeKeyAndVisible()
        parentController.view.frame = window.bounds
        parentController.addChild(outgoingHostingController)
        parentController.view.addSubview(outgoingHostingController.view)
        outgoingHostingController.view.frame = parentController.view.bounds
        outgoingHostingController.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        outgoingHostingController.didMove(toParent: parentController)
        parentController.view.layoutIfNeeded()
        defer {
            successorHostingController.rootView = AnyView(EmptyView())
            successorHostingController.view.setNeedsLayout()
            successorHostingController.view.layoutIfNeeded()
            outgoingHostingController.rootView = AnyView(EmptyView())
            outgoingHostingController.view.setNeedsLayout()
            outgoingHostingController.view.layoutIfNeeded()
            adapter.destroyContext(for: tabID)
            window.isHidden = true
            window.rootViewController = nil
        }

        guard let refreshControl = webView.scrollView.refreshControl else {
            #expect(Bool(false), "The mounted WebKit scroll view should own a refresh control")
            return
        }

        #expect(adapter.webView(for: tabID) === webView)
        #expect(webView.isDescendant(of: outgoingHostingController.view))
        #expect(refreshControl.allTargets.count == 1)

        parentController.addChild(successorHostingController)
        parentController.view.addSubview(successorHostingController.view)
        successorHostingController.view.frame = parentController.view.bounds
        successorHostingController.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        successorHostingController.didMove(toParent: parentController)
        parentController.view.layoutIfNeeded()

        #expect(adapter.webView(for: tabID) === webView)
        #expect(webView.isDescendant(of: successorHostingController.view))
        #expect(webView.isDescendant(of: outgoingHostingController.view) == false)
        #expect(webView.scrollView.refreshControl === refreshControl)
        #expect(refreshControl.allTargets.count == 1)

        refreshControl.beginRefreshing()
        #expect(refreshControl.isRefreshing)

        outgoingHostingController.rootView = AnyView(EmptyView())
        outgoingHostingController.view.setNeedsLayout()
        outgoingHostingController.view.layoutIfNeeded()

        #expect(refreshControl.isRefreshing)
        #expect(refreshControl.allTargets.count == 1)
        #expect(deliverValueChanged(to: refreshControl) == 1)
        #expect(outgoingRefreshCount == 0)
        #expect(successorRefreshCount == 1)
        #expect(refreshControl.isRefreshing == false)
    }

    @Test("Changing Browser tabs ends and unbinds the outgoing refresh control")
    func changingBrowserTabsCleansUpRefreshControl() {
        let firstTabID = BrowserTabID()
        let secondTabID = BrowserTabID()
        let firstWebView = WKWebView(frame: .zero)
        let secondWebView = WKWebView(frame: .zero)
        let webViews = [firstWebView, secondWebView]
        var nextWebViewIndex = 0
        let adapter = BrowserWebKitAdapter(makeWebView: { _, _ in
            defer { nextWebViewIndex += 1 }
            return webViews[nextWebViewIndex]
        })
        let registry = BrowserTabTransitionSurfaceRegistry()
        let firstBridge = BrowserWebView(
            tabID: firstTabID,
            onRefresh: {},
            transitionRegistry: registry,
            adapter: adapter,
        )
        let hostingController = UIHostingController(rootView: AnyView(firstBridge))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 640))
        window.rootViewController = hostingController
        window.makeKeyAndVisible()
        hostingController.view.frame = window.bounds
        hostingController.view.layoutIfNeeded()
        defer {
            hostingController.rootView = AnyView(EmptyView())
            hostingController.view.setNeedsLayout()
            hostingController.view.layoutIfNeeded()
            adapter.destroyContext(for: firstTabID)
            adapter.destroyContext(for: secondTabID)
            window.isHidden = true
            window.rootViewController = nil
        }

        guard let outgoingRefreshControl = firstWebView.scrollView.refreshControl else {
            #expect(Bool(false), "The outgoing WebKit scroll view should own a refresh control")
            return
        }

        let originalContentInset = firstWebView.scrollView.contentInset
        outgoingRefreshControl.beginRefreshing()
        #expect(outgoingRefreshControl.isRefreshing)

        let secondBridge = BrowserWebView(
            tabID: secondTabID,
            onRefresh: {},
            transitionRegistry: registry,
            adapter: adapter,
        )
        hostingController.rootView = AnyView(secondBridge)
        hostingController.view.setNeedsLayout()
        hostingController.view.layoutIfNeeded()

        #expect(adapter.webView(for: firstTabID) === firstWebView)
        #expect(firstWebView.superview == nil)
        #expect(outgoingRefreshControl.isRefreshing == false)
        #expect(outgoingRefreshControl.allTargets.isEmpty)
        #expect(firstWebView.scrollView.contentInset == originalContentInset)
        #expect(adapter.webView(for: secondTabID) === secondWebView)
        #expect(secondWebView.superview != nil)
        #expect(secondWebView.scrollView.refreshControl?.allTargets.count == 1)
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

    @Test("Updated BrowserWebView values keep the coordinator-owned adapter surface attached")
    func updatedBrowserWebViewUsesCoordinatorAdapter() {
        let tabID = BrowserTabID()
        let firstWebView = WKWebView(frame: .zero)
        let secondWebView = WKWebView(frame: .zero)
        let firstAdapter = BrowserWebKitAdapter(makeWebView: { _, _ in firstWebView })
        let secondAdapter = BrowserWebKitAdapter(makeWebView: { _, _ in secondWebView })
        let registry = BrowserTabTransitionSurfaceRegistry()
        let firstBridge = BrowserWebView(
            tabID: tabID,
            onRefresh: {},
            transitionRegistry: registry,
            adapter: firstAdapter,
        )
        let secondBridge = BrowserWebView(
            tabID: tabID,
            onRefresh: {},
            transitionRegistry: registry,
            adapter: secondAdapter,
        )
        let hostingController = UIHostingController(rootView: AnyView(firstBridge))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 640))
        window.rootViewController = hostingController
        window.makeKeyAndVisible()
        hostingController.view.frame = window.bounds
        hostingController.view.layoutIfNeeded()
        defer {
            hostingController.rootView = AnyView(EmptyView())
            hostingController.view.layoutIfNeeded()
            firstAdapter.destroyContext(for: tabID)
            secondAdapter.destroyContext(for: tabID)
            window.isHidden = true
            window.rootViewController = nil
        }

        hostingController.rootView = AnyView(secondBridge)
        hostingController.view.setNeedsLayout()
        hostingController.view.layoutIfNeeded()

        #expect(firstAdapter.webView(for: tabID) === firstWebView)
        #expect(firstWebView.superview != nil)
        #expect(registry.view(for: .content(tabID)) === firstWebView)
        #expect(secondAdapter.webView(for: tabID) == nil)
        #expect(secondWebView.superview == nil)
    }

    @Test("The WebKit bridge receives the adopting presentation's interactive policy")
    func webKitBridgeReceivesInteractivePolicy() {
        let tabID = BrowserTabID()
        let adapter = BrowserWebKitAdapter.shared
        adapter.execute(.configureProfile(profile: .persistentPrivate, retiringTabIDs: []))
        let controller = UIHostingController(
            rootView: BrowserWebView(tabID: tabID, onRefresh: {})
                .scrollDismissesKeyboard(.interactively),
        )
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 640))
        window.rootViewController = controller
        window.makeKeyAndVisible()
        controller.view.frame = window.bounds
        controller.view.layoutIfNeeded()

        let webView = adapter.ensureContext(for: tabID)
        #expect(webView.scrollView.keyboardDismissMode == .interactive)

        adapter.destroyContext(for: tabID)
        window.isHidden = true
        window.rootViewController = nil
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

    @Test("Keyboard notification presence is injectable and scoped by local frame")
    func keyboardNotificationObserverUsesInjectedCenterAndWindowFrame() {
        let fixture = KeyboardPresenceObserverTestFixture()
        let presence = fixture.presence
        let notificationCenter = fixture.notificationCenter
        let window = fixture.window
        fixture.installAnchor()
        defer { fixture.tearDown() }

        let localKeyboardFrame = window.convert(
            CGRect(x: 0, y: 400, width: 320, height: 240),
            to: window.screen.coordinateSpace,
        )
        let remoteKeyboardFrame = localKeyboardFrame.offsetBy(dx: window.screen.bounds.width, dy: 0)
        func postKeyboardNotification(
            _ name: Notification.Name,
            isLocal: Bool,
            beginFrame: CGRect? = nil,
            endFrame: CGRect,
        ) {
            var userInfo: [AnyHashable: Any] = [
                UIResponder.keyboardIsLocalUserInfoKey: NSNumber(value: isLocal),
                UIResponder.keyboardFrameEndUserInfoKey: endFrame,
            ]
            if let beginFrame {
                userInfo[UIResponder.keyboardFrameBeginUserInfoKey] = beginFrame
            }
            notificationCenter.post(name: name, object: nil, userInfo: userInfo)
        }

        postKeyboardNotification(
            UIResponder.keyboardWillShowNotification,
            isLocal: false,
            endFrame: localKeyboardFrame,
        )
        #expect(presence.isPresent == false)

        postKeyboardNotification(
            UIResponder.keyboardWillShowNotification,
            isLocal: true,
            endFrame: remoteKeyboardFrame,
        )
        #expect(presence.isPresent == false)

        postKeyboardNotification(
            UIResponder.keyboardWillShowNotification,
            isLocal: true,
            endFrame: localKeyboardFrame,
        )
        #expect(presence.isPresent)

        postKeyboardNotification(
            UIResponder.keyboardDidShowNotification,
            isLocal: true,
            endFrame: localKeyboardFrame,
        )
        #expect(presence.isPresent)

        postKeyboardNotification(
            UIResponder.keyboardWillChangeFrameNotification,
            isLocal: true,
            beginFrame: localKeyboardFrame,
            endFrame: remoteKeyboardFrame,
        )
        #expect(presence.isPresent)

        postKeyboardNotification(
            UIResponder.keyboardDidChangeFrameNotification,
            isLocal: true,
            beginFrame: localKeyboardFrame,
            endFrame: remoteKeyboardFrame,
        )
        #expect(presence.isPresent == false)

        let repositionedKeyboardFrame = window.convert(
            CGRect(x: 24, y: 365, width: 272, height: 255),
            to: window.screen.coordinateSpace,
        )
        postKeyboardNotification(
            UIResponder.keyboardWillChangeFrameNotification,
            isLocal: true,
            beginFrame: remoteKeyboardFrame,
            endFrame: repositionedKeyboardFrame,
        )
        #expect(presence.isPresent)

        postKeyboardNotification(
            UIResponder.keyboardDidChangeFrameNotification,
            isLocal: true,
            beginFrame: remoteKeyboardFrame,
            endFrame: repositionedKeyboardFrame,
        )
        #expect(presence.isPresent)

        let movedKeyboardFrame = window.convert(
            CGRect(x: 8, y: 350, width: 290, height: 260),
            to: window.screen.coordinateSpace,
        )
        postKeyboardNotification(
            UIResponder.keyboardWillChangeFrameNotification,
            isLocal: true,
            beginFrame: repositionedKeyboardFrame,
            endFrame: movedKeyboardFrame,
        )
        postKeyboardNotification(
            UIResponder.keyboardDidChangeFrameNotification,
            isLocal: true,
            beginFrame: repositionedKeyboardFrame,
            endFrame: movedKeyboardFrame,
        )
        #expect(presence.isPresent)

        postKeyboardNotification(
            UIResponder.keyboardWillHideNotification,
            isLocal: true,
            beginFrame: movedKeyboardFrame,
            endFrame: .zero,
        )
        #expect(presence.isPresent)

        postKeyboardNotification(
            UIResponder.keyboardDidHideNotification,
            isLocal: true,
            beginFrame: movedKeyboardFrame,
            endFrame: .zero,
        )
        #expect(presence.isPresent == false)
    }

    @Test("Keyboard will-show is reconciled when the Browser anchor enters its window")
    func keyboardObserverReplaysWillShowAfterAnchorEntersWindow() {
        let fixture = KeyboardPresenceObserverTestFixture()
        defer { fixture.tearDown() }

        let keyboardFrame = fixture.screenFrame(
            CGRect(x: 0, y: 400, width: 320, height: 240),
        )
        fixture.postKeyboardNotification(
            UIResponder.keyboardWillShowNotification,
            endFrame: keyboardFrame,
            object: fixture.window.screen,
        )
        #expect(!fixture.presence.isPresent)

        fixture.installAnchor()
        #expect(fixture.presence.isPresent)
    }

    @Test("Keyboard did-show is reconciled when the Browser anchor enters its window")
    func keyboardObserverReplaysDidShowAfterAnchorEntersWindow() {
        let fixture = KeyboardPresenceObserverTestFixture()
        defer { fixture.tearDown() }

        let keyboardFrame = fixture.screenFrame(
            CGRect(x: 0, y: 400, width: 320, height: 240),
        )
        fixture.postKeyboardNotification(
            UIResponder.keyboardDidShowNotification,
            endFrame: keyboardFrame,
            object: fixture.window.screen,
        )
        #expect(!fixture.presence.isPresent)

        fixture.installAnchor()
        #expect(fixture.presence.isPresent)
    }

    @Test("Keyboard did-show establishes presence without an observed will-show")
    func keyboardDidShowEstablishesPresenceWithoutWillShow() {
        let fixture = KeyboardPresenceObserverTestFixture()
        defer { fixture.tearDown() }
        fixture.installAnchor()

        let keyboardFrame = fixture.screenFrame(
            CGRect(x: 0, y: 400, width: 320, height: 240),
        )
        fixture.postKeyboardNotification(
            UIResponder.keyboardDidShowNotification,
            endFrame: keyboardFrame,
            object: fixture.window.screen,
        )

        #expect(fixture.presence.isPresent)
    }

    @Test("Off-window keyboard did-show does not establish Browser presence")
    func keyboardDidShowOutsideBrowserWindowDoesNotEstablishPresence() {
        let fixture = KeyboardPresenceObserverTestFixture()
        defer { fixture.tearDown() }
        fixture.installAnchor()

        let keyboardFrame = fixture.screenFrame(
            CGRect(x: fixture.window.screen.bounds.width, y: 400, width: 320, height: 240),
        )
        fixture.postKeyboardNotification(
            UIResponder.keyboardDidShowNotification,
            endFrame: keyboardFrame,
            object: fixture.window.screen,
        )

        #expect(!fixture.presence.isPresent)
    }

    @Test("Pre-window frame changes reconcile their final Browser-window intersection")
    func keyboardObserverReconcilesPreWindowFrameChanges() {
        let changingFixture = KeyboardPresenceObserverTestFixture()
        defer { changingFixture.tearDown() }

        let inWindowFrame = changingFixture.screenFrame(
            CGRect(x: 0, y: 400, width: 320, height: 240),
        )
        let outsideFrame = inWindowFrame.offsetBy(dx: changingFixture.window.screen.bounds.width, dy: 0)
        changingFixture.postKeyboardNotification(
            UIResponder.keyboardWillShowNotification,
            endFrame: inWindowFrame,
        )
        changingFixture.postKeyboardNotification(
            UIResponder.keyboardWillChangeFrameNotification,
            beginFrame: inWindowFrame,
            endFrame: outsideFrame,
        )
        changingFixture.installAnchor()
        #expect(changingFixture.presence.isPresent)

        changingFixture.postKeyboardNotification(
            UIResponder.keyboardDidChangeFrameNotification,
            beginFrame: inWindowFrame,
            endFrame: outsideFrame,
        )
        #expect(!changingFixture.presence.isPresent)

        let completedFixture = KeyboardPresenceObserverTestFixture()
        defer { completedFixture.tearDown() }
        let completedInWindowFrame = completedFixture.screenFrame(
            CGRect(x: 0, y: 400, width: 320, height: 240),
        )
        let completedOutsideFrame = completedInWindowFrame.offsetBy(
            dx: completedFixture.window.screen.bounds.width,
            dy: 0,
        )
        completedFixture.postKeyboardNotification(
            UIResponder.keyboardWillShowNotification,
            endFrame: completedInWindowFrame,
        )
        completedFixture.postKeyboardNotification(
            UIResponder.keyboardWillChangeFrameNotification,
            beginFrame: completedInWindowFrame,
            endFrame: completedOutsideFrame,
        )
        completedFixture.postKeyboardNotification(
            UIResponder.keyboardDidChangeFrameNotification,
            beginFrame: completedInWindowFrame,
            endFrame: completedOutsideFrame,
        )
        completedFixture.installAnchor()
        #expect(!completedFixture.presence.isPresent)

        let offscreenFixture = KeyboardPresenceObserverTestFixture()
        defer { offscreenFixture.tearDown() }
        let offscreenFrame = offscreenFixture.screenFrame(
            CGRect(x: offscreenFixture.window.screen.bounds.width, y: 400, width: 320, height: 240),
        )
        offscreenFixture.postKeyboardNotification(
            UIResponder.keyboardWillShowNotification,
            endFrame: offscreenFrame,
        )
        offscreenFixture.installAnchor()
        #expect(!offscreenFixture.presence.isPresent)
    }

    @Test("Keyboard observer clears stale state on teardown and window replacement")
    func keyboardObserverClearsStateOnTeardownAndWindowReplacement() {
        let fixture = KeyboardPresenceObserverTestFixture()
        defer { fixture.tearDown() }

        let keyboardFrame = fixture.screenFrame(
            CGRect(x: 0, y: 400, width: 320, height: 240),
        )
        fixture.postKeyboardNotification(
            UIResponder.keyboardWillShowNotification,
            endFrame: keyboardFrame,
        )
        fixture.coordinator.stopObserving()
        fixture.coordinator.attach(fixture.anchor)
        fixture.installAnchor()
        #expect(!fixture.presence.isPresent)

        fixture.postKeyboardNotification(
            UIResponder.keyboardWillShowNotification,
            endFrame: keyboardFrame,
        )
        #expect(fixture.presence.isPresent)
        fixture.anchor.removeFromSuperview()
        #expect(!fixture.presence.isPresent)

        let replacementWindow = UIWindow(frame: fixture.window.bounds)
        let replacementController = UIViewController()
        replacementWindow.rootViewController = replacementController
        replacementWindow.makeKeyAndVisible()
        replacementController.view.frame = replacementWindow.bounds
        replacementController.view.addSubview(fixture.anchor)
        #expect(!fixture.presence.isPresent)

        fixture.anchor.removeFromSuperview()
        replacementWindow.isHidden = true
        replacementWindow.rootViewController = nil
    }

    @Test("A reconciled off-window keyboard frame makes the next Browser pull eligible")
    func refreshEligibilityUsesReconciledKeyboardPresence() {
        let fixture = KeyboardPresenceObserverTestFixture()
        defer { fixture.tearDown() }
        fixture.installAnchor()

        let inWindowFrame = fixture.screenFrame(
            CGRect(x: 0, y: 400, width: 320, height: 240),
        )
        let outsideFrame = inWindowFrame.offsetBy(dx: fixture.window.screen.bounds.width, dy: 0)
        fixture.postKeyboardNotification(
            UIResponder.keyboardWillShowNotification,
            endFrame: inWindowFrame,
        )
        fixture.postKeyboardNotification(
            UIResponder.keyboardWillChangeFrameNotification,
            beginFrame: inWindowFrame,
            endFrame: outsideFrame,
        )
        #expect(fixture.presence.isPresent)
        fixture.postKeyboardNotification(
            UIResponder.keyboardDidChangeFrameNotification,
            beginFrame: inWindowFrame,
            endFrame: outsideFrame,
        )
        #expect(!fixture.presence.isPresent)

        let arbitrator = BrowserRefreshGestureArbitrator()
        let surfaceID = BrowserRefreshSurfaceID()
        arbitrator.mount(surfaceID)
        let input = BrowserRefreshGestureInput(
            isInteractiveDismissalEnabled: true,
            isSoftwareKeyboardPresent: fixture.presence.isPresent,
        )
        arbitrator.receiveWebKitPanState(.began, on: surfaceID, input: input)
        arbitrator.receiveWebKitPanState(.ended, on: surfaceID, input: input)
        #expect(arbitrator.consumeRefresh(on: surfaceID))
        #expect(!arbitrator.consumeRefresh(on: surfaceID))
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

    @Test("Mounted WebKit keeps native scrolling and gates refresh dispatch per gesture")
    func mountedWebKitRefreshArbitrationPreservesScrollAndControlLifecycle() throws {
        let tabID = BrowserTabID()
        let webView = WKWebView(frame: .zero)
        let panGestureRecognizer = webView.scrollView.panGestureRecognizer
        let originalPanDelegate = panGestureRecognizer.delegate
        let adapter = BrowserWebKitAdapter(makeWebView: { _, _ in webView })
        let arbitrator = BrowserRefreshGestureArbitrator()
        let keyboardPresence = BrowserSoftwareKeyboardPresence()
        let transitionRegistry = BrowserTabTransitionSurfaceRegistry()
        var refreshCount = 0
        let bridge = BrowserWebView(
            tabID: tabID,
            onRefresh: { refreshCount += 1 },
            transitionRegistry: transitionRegistry,
            adapter: adapter,
            refreshGestureArbitrator: arbitrator,
            softwareKeyboardPresence: keyboardPresence,
        )
        let hostingController = UIHostingController(
            rootView: AnyView(bridge.scrollDismissesKeyboard(.interactively)),
        )
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 640))
        window.rootViewController = hostingController
        window.makeKeyAndVisible()
        hostingController.view.frame = window.bounds
        hostingController.view.layoutIfNeeded()
        defer {
            hostingController.rootView = AnyView(EmptyView())
            hostingController.view.setNeedsLayout()
            hostingController.view.layoutIfNeeded()
            adapter.destroyContext(for: tabID)
            window.isHidden = true
            window.rootViewController = nil
        }

        let mountedWebView = try #require(adapter.webView(for: tabID))
        let refreshControl = try #require(mountedWebView.scrollView.refreshControl)
        let coordinator = try #require(
            refreshControl.allTargets.compactMap { $0.base as? BrowserWebView.Coordinator }.first,
        )
        #expect(mountedWebView.scrollView.panGestureRecognizer === panGestureRecognizer)
        #expect(mountedWebView.scrollView.keyboardDismissMode == .interactive)
        #expect(mountedWebView.scrollView.isScrollEnabled)
        #expect(refreshControl.allTargets.count == 1)
        #expect(panGestureRecognizer.delegate === originalPanDelegate)

        keyboardPresence.receive(.willShow)
        coordinator.receivePanGestureState(.began)
        keyboardPresence.receive(.didHide)
        coordinator.receivePanGestureState(.ended)
        refreshControl.beginRefreshing()
        #expect(deliverValueChanged(to: refreshControl) == 1)
        #expect(refreshCount == 0)
        #expect(refreshControl.isRefreshing == false)

        coordinator.receivePanGestureState(.began)
        coordinator.receivePanGestureState(.ended)
        refreshControl.beginRefreshing()
        #expect(deliverValueChanged(to: refreshControl) == 1)
        #expect(refreshCount == 1)
        #expect(refreshControl.isRefreshing == false)

        refreshControl.beginRefreshing()
        #expect(deliverValueChanged(to: refreshControl) == 1)
        #expect(refreshCount == 1)
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

/// Routes a value-changed event to a control's registered actions in package tests.
///
/// Swift package test bundles have no `UIApplication` to dispatch `UIControl.sendActions`, so
/// the event is delivered directly to the targets registered for `.valueChanged`.
@MainActor
private final class KeyboardPresenceObserverAnchorView: UIView {
    var onWindowChange: (() -> Void)?

    override func didMoveToWindow() {
        super.didMoveToWindow()
        onWindowChange?()
    }
}

@MainActor
private final class KeyboardPresenceObserverTestFixture {
    let notificationCenter: NotificationCenter
    let presence: BrowserSoftwareKeyboardPresence
    let coordinator: BrowserSoftwareKeyboardPresenceObserver.Coordinator
    let window: UIWindow
    let hostingController: UIViewController
    let anchor: KeyboardPresenceObserverAnchorView

    init() {
        let notificationCenter = NotificationCenter()
        let presence = BrowserSoftwareKeyboardPresence()
        let coordinator = BrowserSoftwareKeyboardPresenceObserver.Coordinator(
            presence: presence,
            notificationCenter: notificationCenter,
        )
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 640))
        let hostingController = UIViewController()
        let anchor = KeyboardPresenceObserverAnchorView()

        self.notificationCenter = notificationCenter
        self.presence = presence
        self.coordinator = coordinator
        self.window = window
        self.hostingController = hostingController
        self.anchor = anchor

        window.rootViewController = hostingController
        window.makeKeyAndVisible()
        hostingController.view.frame = window.bounds
        anchor.backgroundColor = .clear
        anchor.isUserInteractionEnabled = false
        anchor.onWindowChange = { [weak coordinator, weak anchor] in
            guard let coordinator, let anchor else {
                return
            }

            coordinator.attach(anchor)
        }
        coordinator.attach(anchor)
    }

    func installAnchor() {
        hostingController.view.addSubview(anchor)
        hostingController.view.layoutIfNeeded()
    }

    func screenFrame(_ frameInWindow: CGRect) -> CGRect {
        window.convert(frameInWindow, to: window.screen.coordinateSpace)
    }

    func postKeyboardNotification(
        _ name: Notification.Name,
        isLocal: Bool = true,
        beginFrame: CGRect? = nil,
        endFrame: CGRect,
        object: Any? = nil,
    ) {
        var userInfo: [AnyHashable: Any] = [
            UIResponder.keyboardIsLocalUserInfoKey: NSNumber(value: isLocal),
            UIResponder.keyboardFrameEndUserInfoKey: endFrame,
        ]
        if let beginFrame {
            userInfo[UIResponder.keyboardFrameBeginUserInfoKey] = beginFrame
        }
        notificationCenter.post(name: name, object: object, userInfo: userInfo)
    }

    func tearDown() {
        anchor.removeFromSuperview()
        coordinator.stopObserving()
        window.isHidden = true
        window.rootViewController = nil
    }
}

@MainActor
private func deliverValueChanged(to control: UIControl) -> Int {
    let action = #selector(BrowserWebView.Coordinator.refreshControlValueChanged(_:))
    var deliveredActionCount = 0
    for target in control.allTargets {
        guard let targetObject = target.base as? NSObject,
              targetObject.responds(to: action),
              control.actions(forTarget: targetObject, forControlEvent: .valueChanged)?
              .contains(NSStringFromSelector(action)) == true
        else {
            continue
        }

        targetObject.perform(action, with: control)
        deliveredActionCount += 1
    }

    return deliveredActionCount
}

private struct RGBAPixel {
    let red: UInt8
    let green: UInt8
    let blue: UInt8
    let alpha: UInt8
}

private func rgbaPixel(in image: UIImage) -> RGBAPixel? {
    guard let source = image.cgImage else {
        return nil
    }

    var values = [UInt8](repeating: 0, count: 4)
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
    let drawn = values.withUnsafeMutableBytes { buffer in
        guard let baseAddress = buffer.baseAddress,
              let context = CGContext(
                  data: baseAddress,
                  width: 1,
                  height: 1,
                  bitsPerComponent: 8,
                  bytesPerRow: 4,
                  space: colorSpace,
                  bitmapInfo: bitmapInfo,
              )
        else {
            return false
        }

        context.draw(source, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return true
    }
    guard drawn else {
        return nil
    }

    return RGBAPixel(red: values[0], green: values[1], blue: values[2], alpha: values[3])
}
