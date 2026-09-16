//
//  BrowserBehaviorTests.swift
//  MediaVault
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import ComposableArchitecture
import Foundation
import Testing
@testable import BrowserFeature

@Suite("Browser command and event behavior")
@MainActor
struct BrowserBehaviorTests {
    @Test("Back, Forward, Reload, Stop, pull-to-refresh, and long-press history route stable commands")
    func navigationCommands() async throws {
        let tabID = BrowserTabID()
        let url = try #require(URL(string: "https://example.com"))
        var tab = BrowserTab.web(id: tabID, url: url)
        tab.metadata = .init(committedURL: url, canGoBack: true, canGoForward: true)
        let commands = LockIsolated<[BrowserWebKitCommand]>([])
        let store = TestStore(initialState: BrowserFeature.State(tabs: [tab], selectedTabID: tabID)) {
            BrowserFeature()
        } withDependencies: {
            $0.browserWebKit.execute = { command in commands.withValue { $0.append(command) } }
        }
        store.exhaustivity = .off(showSkippedAssertions: false)

        await store.send(.backTapped)
        await store.send(.forwardTapped)
        await store.send(.reloadOrStopTapped)
        await store.send(.pullToRefresh)
        await store.send(.backHistoryRequested)
        await store.send(.forwardHistoryRequested)
        await store.send(.webKitEvent(.metadata(tabID: tabID, .init(
            committedURL: url,
            isLoading: true,
            canGoBack: true,
            canGoForward: true,
        ))))
        await store.send(.reloadOrStopTapped)
        await store.finish()

        #expect(commands.value == [
            .goBack(tabID: tabID),
            .goForward(tabID: tabID),
            .reload(tabID: tabID),
            .reload(tabID: tabID),
            .showBackForwardList(tabID: tabID, direction: .back),
            .showBackForwardList(tabID: tabID, direction: .forward),
            .stop(tabID: tabID),
        ])
        #expect(store.state.tabs[0].content == .web(requestedURL: url))
    }

    @Test("Navigation failure, Back recovery, Retry, and process termination preserve logical identity")
    func errorsAndTermination() async throws {
        let tabID = BrowserTabID()
        let priorURL = try #require(URL(string: "https://prior.example"))
        let failedURL = try #require(URL(string: "https://failed.example"))
        var tab = BrowserTab.web(id: tabID, url: priorURL)
        tab.metadata = .init(committedURL: priorURL, canGoBack: true)
        let commands = LockIsolated<[BrowserWebKitCommand]>([])
        let store = TestStore(initialState: BrowserFeature.State(tabs: [tab], selectedTabID: tabID)) {
            BrowserFeature()
        } withDependencies: {
            $0.browserWebKit.execute = { command in commands.withValue { $0.append(command) } }
        }
        store.exhaustivity = .off(showSkippedAssertions: false)

        await store.send(.webKitEvent(.navigationFailed(tabID: tabID, .serverNotFound(failedURL))))
        #expect(store.state.tabs[0].content == .error(.serverNotFound(failedURL)))
        await store.send(.backTapped)
        await store.send(.retryTapped)
        await store.send(.webKitEvent(.processTerminated(tabID: tabID)))
        #expect(store.state.tabs[0].content == .terminated(lastCommittedURL: priorURL))
        await store.send(.retryTapped)
        #expect(store.state.tabs[0].content == .terminated(lastCommittedURL: priorURL))
        await store.finish()
        #expect(commands.value == [
            .goBack(tabID: tabID),
            .load(tabID: tabID, url: failedURL),
            .reload(tabID: tabID),
        ])
    }

    @Test("Tab switch clears Find and resolves a dialog belonging to the prior tab")
    func tabSwitchDismissesScopedPageUI() async throws {
        let firstID = BrowserTabID()
        let secondID = BrowserTabID()
        let url = try #require(URL(string: "https://example.com"))
        var state = BrowserFeature.State(
            tabs: [.web(id: firstID, url: url), .web(id: secondID, url: url)],
            selectedTabID: firstID,
        )
        state.findDraft = "needle"
        state.javaScriptDialogTabID = firstID
        let commands = LockIsolated<[BrowserWebKitCommand]>([])
        let store = TestStore(initialState: state) { BrowserFeature() } withDependencies: {
            $0.browserWebKit.execute = { command in commands.withValue { $0.append(command) } }
        }
        store.exhaustivity = .off(showSkippedAssertions: false)

        await store.send(.selectTab(secondID))
        await store.finish()
        #expect(store.state.selectedTabID == secondID)
        #expect(store.state.findDraft == nil)
        #expect(store.state.javaScriptDialogTabID == nil)
        #expect(Set(commands.value.map(String.init(describing:))) == Set([
            String(describing: BrowserWebKitCommand.find(tabID: firstID, query: "")),
            String(describing: BrowserWebKitCommand.dismissJavaScriptDialog(tabID: firstID)),
        ]))
    }

    @Test("Back-forward entries and transient previews project only stable values")
    func backForwardAndPreviewEvents() async throws {
        let tabID = BrowserTabID()
        let url = try #require(URL(string: "https://example.com"))
        let priorURL = try #require(URL(string: "https://prior.example"))
        let entry = BrowserBackForwardEntry(title: "Prior", url: priorURL)
        let store = TestStore(initialState: BrowserFeature.State(
            tabs: [.web(id: tabID, url: url)],
            selectedTabID: tabID,
        )) { BrowserFeature() }

        await store.send(.webKitEvent(.backForwardEntries(tabID: tabID, direction: .back, entries: [entry]))) {
            $0.backForwardList = .init(tabID: tabID, direction: .back, entries: [entry])
        }
        await store.send(.backForwardListDismissed) { $0.backForwardList = nil }
        let bytes = Data([1, 2, 3])
        await store.send(.webKitEvent(.preview(tabID: tabID, pngData: bytes))) {
            $0.tabPreviewData[tabID] = bytes
        }
        await store.send(.webKitEvent(.preview(tabID: tabID, pngData: nil))) {
            $0.tabPreviewData[tabID] = nil
        }
    }

    @Test("Targeted background-tab bookmark and copy actions do not activate the tab")
    func targetedTabActions() async throws {
        let firstID = BrowserTabID()
        let secondID = BrowserTabID()
        let firstURL = try #require(URL(string: "https://first.example"))
        let secondURL = try #require(URL(string: "https://second.example"))
        var first = BrowserTab.web(id: firstID, url: firstURL)
        first.metadata = .init(committedURL: firstURL, title: "First")
        var second = BrowserTab.web(id: secondID, url: secondURL)
        second.metadata = .init(committedURL: secondURL, title: "Second")
        let copied = LockIsolated<URL?>(nil)
        let store = TestStore(initialState: BrowserFeature.State(
            tabs: [first, second],
            selectedTabID: firstID,
            presentation: .tabOverview,
        )) { BrowserFeature() } withDependencies: {
            $0.browserClipboard.writeURL = { url in copied.setValue(url) }
        }
        store.exhaustivity = .off(showSkippedAssertions: false)

        await store.send(.addBookmarkForTab(secondID))
        #expect(store.state.bookmarkEditor?.urlDraft == secondURL.absoluteString)
        #expect(store.state.selectedTabID == firstID)
        await store.send(.bookmarkEditorCancelled)
        await store.send(.copyURL(secondID))
        await store.finish()
        #expect(copied.value == secondURL)
        #expect(store.state.selectedTabID == firstID)
    }

    @Test("Library row selection dismisses the modal and navigates the active tab")
    func librarySelection() async throws {
        let tabID = BrowserTabID()
        let destination = try #require(URL(string: "https://destination.example"))
        var state = BrowserFeature.State(initialTabID: tabID)
        state.library = .init(section: .bookmarks)
        let commands = LockIsolated<[BrowserWebKitCommand]>([])
        let store = TestStore(initialState: state) { BrowserFeature() } withDependencies: {
            $0.browserWebKit.execute = { command in commands.withValue { $0.append(command) } }
        }
        store.exhaustivity = .off(showSkippedAssertions: false)

        await store.send(.navigate(destination))
        await store.finish()
        #expect(store.state.library == nil)
        #expect(store.state.tabs[0].content == .web(requestedURL: destination))
        #expect(commands.value == [.ensureContext(tabID: tabID), .load(tabID: tabID, url: destination)])
    }

    @Test("External omnibox navigation uses the full URL seam and does not touch WebKit")
    func externalOmniboxNavigation() async throws {
        let tabID = BrowserTabID()
        let externalURL = try #require(URL(string: "mailto:person@example.com"))
        let opened = LockIsolated<[URL]>([])
        let commands = LockIsolated<[BrowserWebKitCommand]>([])
        let store = TestStore(initialState: BrowserFeature.State(initialTabID: tabID)) {
            BrowserFeature()
        } withDependencies: {
            $0.browserExternalNavigation.open = { url in opened.withValue { $0.append(url) } }
            $0.browserWebKit.execute = { command in commands.withValue { $0.append(command) } }
        }
        store.exhaustivity = .off(showSkippedAssertions: false)

        await store.send(.omniboxChanged("mailto:person@example.com"))
        await store.send(.omniboxSubmitted)
        await store.finish()

        #expect(opened.value == [externalURL])
        #expect(commands.value.isEmpty)
        #expect(store.state.tabs.count == 1)
    }

    @Test("External link-context actions use the full URL seam without touching WebKit")
    func externalLinkContextActions() async throws {
        let tabID = BrowserTabID()
        let pageURL = try #require(URL(string: "https://page.example"))
        let externalURL = try #require(URL(string: "mailto:person@example.com?subject=Browser"))
        let opened = LockIsolated<[URL]>([])
        let commands = LockIsolated<[BrowserWebKitCommand]>([])
        var state = BrowserFeature.State(initialTabID: tabID)
        state.tabs[0] = .web(id: tabID, url: pageURL)
        let store = TestStore(initialState: state) {
            BrowserFeature()
        } withDependencies: {
            $0.browserExternalNavigation.open = { url in opened.withValue { $0.append(url) } }
            $0.browserWebKit.execute = { command in commands.withValue { $0.append(command) } }
        }
        store.exhaustivity = .off(showSkippedAssertions: false)

        await store.send(.webKitEvent(.linkContextAction(tabID: tabID, action: .open, url: externalURL)))
        await store.send(.webKitEvent(.linkContextAction(
            tabID: tabID,
            action: .openInNewTab,
            url: externalURL,
        )))
        await store.finish()

        #expect(opened.value == [externalURL, externalURL])
        #expect(commands.value.isEmpty)
        #expect(store.state.tabs.count == 1)
    }

    @Test("Web-link context actions route open, new-tab, copy, and share behavior")
    func webLinkContextActions() async throws {
        let tabID = BrowserTabID()
        let url = try #require(URL(string: "https://linked.example/path"))
        let copied = LockIsolated<[URL]>([])
        let commands = LockIsolated<[BrowserWebKitCommand]>([])
        let pageURL = try #require(URL(string: "https://page.example"))
        var state = BrowserFeature.State(initialTabID: tabID)
        state.tabs[0] = .web(id: tabID, url: pageURL)
        state.settings.openLinksInNewTabs = .foreground
        let store = TestStore(initialState: state) {
            BrowserFeature()
        } withDependencies: {
            $0.uuid = .incrementing
            $0.browserClipboard.writeURL = { value in copied.withValue { $0.append(value) } }
            $0.browserWebKit.execute = { command in commands.withValue { $0.append(command) } }
        }
        store.exhaustivity = .off(showSkippedAssertions: false)

        await store.send(.webKitEvent(.linkContextAction(tabID: tabID, action: .open, url: url)))
        await store.send(.webKitEvent(.linkContextAction(tabID: tabID, action: .openInNewTab, url: url)))
        await store.send(.webKitEvent(.linkContextAction(tabID: tabID, action: .copyLink, url: url)))
        await store.send(.webKitEvent(.linkContextAction(tabID: tabID, action: .shareLink, url: url))) {
            $0.shareURL = url
            $0.shareTitle = url.host
        }
        await store.finish()

        #expect(copied.value == [url])
        #expect(store.state.tabs.count == 2)
        #expect(store.state.selectedTabID != tabID)
        #expect(commands.value.contains(.ensureContext(tabID: store.state.selectedTabID)))
        #expect(commands.value.contains(.load(tabID: store.state.selectedTabID, url: url)))
    }
}
