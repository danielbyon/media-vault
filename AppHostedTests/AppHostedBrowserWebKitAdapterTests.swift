//
//  AppHostedBrowserWebKitAdapterTests.swift
//  MediaVault
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import CoreFoundation
import CoreGraphics
import Foundation
import ObjectiveC
import QuartzCore
import SwiftUI
import Testing
import UIKit
import UIUtilities
import WebKit
@testable import BrowserFeature

@Suite("Browser WebKit adapter (window hosted)")
@MainActor
struct AppHostedBrowserWebKitAdapterTests {
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
        let window = UIKitTestSupport.makeWindow(frame: CGRect(x: 0, y: 0, width: 120, height: 80))
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
        let window = UIKitTestSupport.makeWindow(frame: CGRect(x: 0, y: 0, width: 160, height: 340))
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
        let window = UIKitTestSupport.makeWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 640))
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
        let window = UIKitTestSupport.makeWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 640))
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
        let window = UIKitTestSupport.makeWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 640))
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
        let window = UIKitTestSupport.makeWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 640))
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
            endFrame: CGRect,
            beginFrame: CGRect? = nil,
        ) {
            var userInfo: [AnyHashable: Any] = [
                UIResponder.keyboardIsLocalUserInfoKey: isLocal,
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
            endFrame: remoteKeyboardFrame,
            beginFrame: localKeyboardFrame,
        )
        #expect(presence.isPresent)

        postKeyboardNotification(
            UIResponder.keyboardDidChangeFrameNotification,
            isLocal: true,
            endFrame: remoteKeyboardFrame,
            beginFrame: localKeyboardFrame,
        )
        #expect(presence.isPresent == false)

        let repositionedKeyboardFrame = window.convert(
            CGRect(x: 24, y: 365, width: 272, height: 255),
            to: window.screen.coordinateSpace,
        )
        postKeyboardNotification(
            UIResponder.keyboardWillChangeFrameNotification,
            isLocal: true,
            endFrame: repositionedKeyboardFrame,
            beginFrame: remoteKeyboardFrame,
        )
        #expect(presence.isPresent)

        postKeyboardNotification(
            UIResponder.keyboardDidChangeFrameNotification,
            isLocal: true,
            endFrame: repositionedKeyboardFrame,
            beginFrame: remoteKeyboardFrame,
        )
        #expect(presence.isPresent)

        let movedKeyboardFrame = window.convert(
            CGRect(x: 8, y: 350, width: 290, height: 260),
            to: window.screen.coordinateSpace,
        )
        postKeyboardNotification(
            UIResponder.keyboardWillChangeFrameNotification,
            isLocal: true,
            endFrame: movedKeyboardFrame,
            beginFrame: repositionedKeyboardFrame,
        )
        postKeyboardNotification(
            UIResponder.keyboardDidChangeFrameNotification,
            isLocal: true,
            endFrame: movedKeyboardFrame,
            beginFrame: repositionedKeyboardFrame,
        )
        #expect(presence.isPresent)

        postKeyboardNotification(
            UIResponder.keyboardWillHideNotification,
            isLocal: true,
            endFrame: .zero,
            beginFrame: movedKeyboardFrame,
        )
        #expect(presence.isPresent)

        postKeyboardNotification(
            UIResponder.keyboardDidHideNotification,
            isLocal: true,
            endFrame: .zero,
            beginFrame: movedKeyboardFrame,
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
            endFrame: outsideFrame,
            beginFrame: inWindowFrame,
        )
        changingFixture.installAnchor()
        #expect(changingFixture.presence.isPresent)

        changingFixture.postKeyboardNotification(
            UIResponder.keyboardDidChangeFrameNotification,
            endFrame: outsideFrame,
            beginFrame: inWindowFrame,
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
            endFrame: completedOutsideFrame,
            beginFrame: completedInWindowFrame,
        )
        completedFixture.postKeyboardNotification(
            UIResponder.keyboardDidChangeFrameNotification,
            endFrame: completedOutsideFrame,
            beginFrame: completedInWindowFrame,
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

        let replacementWindow = UIKitTestSupport.makeWindow(frame: fixture.window.bounds)
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
            endFrame: outsideFrame,
            beginFrame: inWindowFrame,
        )
        #expect(fixture.presence.isPresent)
        fixture.postKeyboardNotification(
            UIResponder.keyboardDidChangeFrameNotification,
            endFrame: outsideFrame,
            beginFrame: inWindowFrame,
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
        let window = UIKitTestSupport.makeWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 640))
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

    @Test("The WebKit bridge receives the adopting presentation's interactive policy")
    func webKitBridgeReceivesInteractivePolicy() {
        let tabID = BrowserTabID()
        let adapter = BrowserWebKitAdapter.shared
        adapter.execute(.configureProfile(profile: .persistentPrivate, retiringTabIDs: []))
        let controller = UIHostingController(
            rootView: BrowserWebView(tabID: tabID, onRefresh: {})
                .scrollDismissesKeyboard(.interactively),
        )
        let window = UIKitTestSupport.makeWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 640))
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
        let testNotificationCenter = NotificationCenter()
        let testPresence = BrowserSoftwareKeyboardPresence()
        let testCoordinator = BrowserSoftwareKeyboardPresenceObserver.Coordinator(
            presence: testPresence,
            notificationCenter: testNotificationCenter,
        )
        let testWindow = UIKitTestSupport.makeWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 640))
        let testHostingController = UIViewController()
        let testAnchor = KeyboardPresenceObserverAnchorView()

        notificationCenter = testNotificationCenter
        presence = testPresence
        coordinator = testCoordinator
        window = testWindow
        hostingController = testHostingController
        anchor = testAnchor

        testWindow.rootViewController = testHostingController
        testWindow.makeKeyAndVisible()
        testHostingController.view.frame = testWindow.bounds
        testAnchor.backgroundColor = .clear
        testAnchor.isUserInteractionEnabled = false
        testAnchor.onWindowChange = { [weak testCoordinator, weak testAnchor] in
            guard let testCoordinator, let testAnchor else {
                return
            }

            testCoordinator.attach(testAnchor)
        }
        testCoordinator.attach(testAnchor)
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
        endFrame: CGRect,
        isLocal: Bool = true,
        beginFrame: CGRect? = nil,
        object: Any? = nil,
    ) {
        var userInfo: [AnyHashable: Any] = [
            UIResponder.keyboardIsLocalUserInfoKey: isLocal,
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
