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

    @Test("The WebKit bridge forwards pull-to-refresh without retaining reducer state")
    func pullToRefreshBridge() {
        var refreshCount = 0
        let bridge = BrowserWebView(tabID: BrowserTabID()) {
            refreshCount += 1
        }

        bridge.makeCoordinator().refresh()

        #expect(refreshCount == 1)
    }

    @Test("The WebKit bridge receives the adopting presentation's interactive policy")
    func webKitBridgeReceivesInteractivePolicy() {
        let tabID = BrowserTabID()
        let adapter = BrowserWebKitAdapter.shared
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
