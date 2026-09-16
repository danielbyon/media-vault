//
//  BrowserWebKitAdapterTests.swift
//  MediaVault
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
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
