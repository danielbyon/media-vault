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
        let operationID = try #require(store.state.previewState.operation(for: tabID))
        await store.send(.webKitEvent(.metadata(tabID: tabID, metadata: .init(
            committedURL: url,
            isLoading: true,
            canGoBack: true,
            canGoForward: true,
        ), correlation: .operation(operationID))))
        await store.send(.reloadOrStopTapped)
        await store.finish()

        #expect(commands.value.map(\.route) == [
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

        await store.send(.webKitEvent(.navigationFailed(
            tabID: tabID,
            error: .serverNotFound(failedURL),
            correlation: .untracked,
        )))
        #expect(store.state.tabs[0].content == .error(.serverNotFound(failedURL)))
        await store.send(.backTapped)
        await store.send(.retryTapped)
        await store.send(.webKitEvent(.processTerminated(tabID: tabID)))
        #expect(store.state.tabs[0].content == .terminated(lastCommittedURL: priorURL))
        await store.send(.retryTapped)
        #expect(store.state.tabs[0].content == .terminated(lastCommittedURL: priorURL))
        await store.finish()
        #expect(commands.value.map(\.route) == [
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

    @Test("Back-forward entries and transient previews preserve stale imagery on failure")
    func backForwardAndPreviewEvents() async throws {
        let tabID = BrowserTabID()
        let url = try #require(URL(string: "https://example.com"))
        let priorURL = try #require(URL(string: "https://prior.example"))
        let entry = BrowserBackForwardEntry(title: "Prior", url: priorURL)
        let store = TestStore(initialState: BrowserFeature.State(
            tabs: [.web(id: tabID, url: url)],
            selectedTabID: tabID,
        )) { BrowserFeature() }
        let revision = store.state.previewState.revision(for: tabID)

        await store.send(.webKitEvent(.backForwardEntries(tabID: tabID, direction: .back, entries: [entry]))) {
            $0.backForwardList = .init(tabID: tabID, direction: .back, entries: [entry])
        }
        await store.send(.backForwardListDismissed) { $0.backForwardList = nil }
        let bytes = Data([1, 2, 3])
        await store.send(.webKitEvent(.preview(tabID: tabID, revision: revision, pngData: bytes))) {
            $0.previewState.setData(.init(revision: revision, pngData: bytes), for: tabID)
        }
        await store.send(.webKitEvent(.preview(tabID: tabID, revision: revision, pngData: nil)))
        #expect(store.state.previewState.data(for: tabID)?.pngData == bytes)
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
        #expect(commands.value.map(\.route) == [
            .ensureContext(tabID: tabID),
            .load(tabID: tabID, url: destination),
        ])
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
        state.settings.openLinksInNewTabs = .askEveryTime
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

    @Test("Ask Every Time defers related-tab creation")
    func askEveryTimeDefersRelatedTabCreation() async throws {
        let openerID = BrowserTabID()
        let openerURL = try #require(URL(string: "https://page.example"))
        let destination = try #require(URL(string: "https://linked.example"))
        var state = BrowserFeature.State(
            tabs: [.web(id: openerID, url: openerURL)],
            selectedTabID: openerID,
        )
        state.settings.openLinksInNewTabs = .askEveryTime
        let commands = LockIsolated<[BrowserWebKitCommand]>([])
        let store = TestStore(initialState: state) {
            BrowserFeature()
        } withDependencies: {
            $0.uuid = .incrementing
            $0.browserWebKit.execute = { command in commands.withValue { $0.append(command) } }
        }
        store.exhaustivity = .off(showSkippedAssertions: false)

        await store.send(.openInNewTab(destination, openerID: openerID))
        await store.finish()

        #expect(store.state.tabs.count == 1)
        #expect(store.state.selectedTabID == openerID)
        #expect(commands.value.isEmpty)
    }

    @Test("Ask Every Time preserves the original request through navigation and foreground confirmation")
    func askEveryTimePreservesRequestUntilForegroundConfirmation() async throws {
        let openerID = BrowserTabID()
        let existingRelatedID = BrowserTabID()
        let openerURL = try #require(URL(string: "https://page.example"))
        let existingRelatedURL = try #require(URL(string: "https://existing.example"))
        let navigationURL = try #require(URL(string: "https://navigated.example"))
        let destination = try #require(URL(string: "https://linked.example"))
        var state = BrowserFeature.State(
            tabs: [
                .web(id: openerID, url: openerURL),
                .web(id: existingRelatedID, url: existingRelatedURL, openerID: openerID),
            ],
            selectedTabID: openerID,
        )
        state.settings.openLinksInNewTabs = .askEveryTime
        let commands = LockIsolated<[BrowserWebKitCommand]>([])
        let store = TestStore(initialState: state) {
            BrowserFeature()
        } withDependencies: {
            $0.uuid = .incrementing
            $0.browserWebKit.execute = { command in commands.withValue { $0.append(command) } }
        }
        store.exhaustivity = .off(showSkippedAssertions: false)

        await store.send(.openInNewTab(destination, openerID: openerID)) {
            $0.pendingNewTab = BrowserNewTabRequest(url: destination, openerID: openerID)
        }
        await store.send(.openInNewTab(existingRelatedURL, openerID: openerID))
        await store.send(.webKitEvent(.metadata(
            tabID: openerID,
            metadata: .init(committedURL: openerURL, isLoading: true),
            correlation: .untracked,
        )))
        await store.send(.navigate(navigationURL))
        #expect(store.state.pendingNewTab == BrowserNewTabRequest(url: destination, openerID: openerID))

        await store.send(.newTabDispositionSelected(.foreground))
        await store.finish()

        let newTab = try #require(store.state.tabs.last)
        #expect(newTab.content == .web(requestedURL: destination))
        #expect(newTab.openerID == openerID)
        #expect(store.state.selectedTabID == newTab.id)
        #expect(store.state.pendingNewTab == nil)
        #expect(commands.value.map(\.route) == [
            .ensureContext(tabID: openerID),
            .load(tabID: openerID, url: navigationURL),
            .ensureContext(tabID: newTab.id),
            .load(tabID: newTab.id, url: destination),
        ])
    }

    @Test("Ask Every Time background confirmation preserves the current selection")
    func askEveryTimeBackgroundConfirmationPreservesSelection() async throws {
        let openerID = BrowserTabID()
        let openerURL = try #require(URL(string: "https://page.example"))
        let destination = try #require(URL(string: "https://linked.example"))
        var state = BrowserFeature.State(
            tabs: [.web(id: openerID, url: openerURL)],
            selectedTabID: openerID,
        )
        state.settings.openLinksInNewTabs = .askEveryTime
        let commands = LockIsolated<[BrowserWebKitCommand]>([])
        let store = TestStore(initialState: state) {
            BrowserFeature()
        } withDependencies: {
            $0.uuid = .incrementing
            $0.browserWebKit.execute = { command in commands.withValue { $0.append(command) } }
        }
        store.exhaustivity = .off(showSkippedAssertions: false)

        await store.send(.openInNewTab(destination, openerID: openerID))
        await store.send(.newTabDispositionSelected(.background))
        await store.finish()

        let newTab = try #require(store.state.tabs.last)
        #expect(newTab.content == .web(requestedURL: destination))
        #expect(newTab.openerID == openerID)
        #expect(store.state.selectedTabID == openerID)
        #expect(store.state.pendingNewTab == nil)
        #expect(commands.value.map(\.route) == [
            .ensureContext(tabID: newTab.id),
            .load(tabID: newTab.id, url: destination),
        ])
    }

    @Test("Canceling Ask Every Time preserves tabs, selection, and WebKit command state")
    func askEveryTimeCancellationIsSideEffectFree() async throws {
        let openerID = BrowserTabID()
        let openerURL = try #require(URL(string: "https://page.example"))
        let destination = try #require(URL(string: "https://linked.example"))
        var state = BrowserFeature.State(
            tabs: [.web(id: openerID, url: openerURL)],
            selectedTabID: openerID,
        )
        state.settings.openLinksInNewTabs = .askEveryTime
        let commands = LockIsolated<[BrowserWebKitCommand]>([])
        let store = TestStore(initialState: state) {
            BrowserFeature()
        } withDependencies: {
            $0.browserWebKit.execute = { command in commands.withValue { $0.append(command) } }
        }
        store.exhaustivity = .off(showSkippedAssertions: false)

        await store.send(.openInNewTab(destination, openerID: openerID))
        await store.send(.newTabDispositionDismissed) {
            $0.pendingNewTab = nil
        }
        await store.finish()

        #expect(store.state.tabs.count == 1)
        #expect(store.state.selectedTabID == openerID)
        #expect(store.state.pendingNewTab == nil)
        #expect(commands.value.isEmpty)
    }

    @Test("Fixed Background preference creates a related tab without selecting it")
    func fixedBackgroundPreferencePreservesSelection() async throws {
        let openerID = BrowserTabID()
        let openerURL = try #require(URL(string: "https://page.example"))
        let destination = try #require(URL(string: "https://linked.example"))
        var state = BrowserFeature.State(
            tabs: [.web(id: openerID, url: openerURL)],
            selectedTabID: openerID,
        )
        state.settings.openLinksInNewTabs = .background
        let commands = LockIsolated<[BrowserWebKitCommand]>([])
        let store = TestStore(initialState: state) {
            BrowserFeature()
        } withDependencies: {
            $0.uuid = .incrementing
            $0.browserWebKit.execute = { command in commands.withValue { $0.append(command) } }
        }
        store.exhaustivity = .off(showSkippedAssertions: false)

        await store.send(.openInNewTab(destination, openerID: openerID))
        await store.finish()

        let newTab = try #require(store.state.tabs.last)
        #expect(newTab.content == .web(requestedURL: destination))
        #expect(store.state.selectedTabID == openerID)
        #expect(commands.value.map(\.route) == [
            .ensureContext(tabID: newTab.id),
            .load(tabID: newTab.id, url: destination),
        ])
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
        #expect(commands.value.map(\.route).contains(.ensureContext(tabID: store.state.selectedTabID)))
        #expect(commands.value.map(\.route).contains(.load(tabID: store.state.selectedTabID, url: url)))
    }

    @Test("Ask Every Time defers HTTP link-context new-tab actions until disposition")
    func askEveryTimeLinkContextNewTabDefersUntilDisposition() async throws {
        let openerID = BrowserTabID()
        let openerURL = try #require(URL(string: "https://page.example"))
        let destination = try #require(URL(string: "https://linked.example/path"))
        var state = BrowserFeature.State(
            tabs: [.web(id: openerID, url: openerURL)],
            selectedTabID: openerID,
        )
        state.settings.openLinksInNewTabs = .askEveryTime
        let commands = LockIsolated<[BrowserWebKitCommand]>([])
        let store = TestStore(initialState: state) {
            BrowserFeature()
        } withDependencies: {
            $0.uuid = .incrementing
            $0.browserWebKit.execute = { command in commands.withValue { $0.append(command) } }
        }
        store.exhaustivity = .off(showSkippedAssertions: false)

        await store.send(.webKitEvent(.linkContextAction(
            tabID: openerID,
            action: .openInNewTab,
            url: destination,
        )))
        await store.receive(.openInNewTab(destination, openerID: openerID)) {
            $0.pendingNewTab = BrowserNewTabRequest(url: destination, openerID: openerID)
        }

        #expect(store.state.tabs.count == 1)
        #expect(store.state.selectedTabID == openerID)
        #expect(store.state.pendingNewTab == BrowserNewTabRequest(url: destination, openerID: openerID))
        #expect(commands.value.isEmpty)

        await store.send(.newTabDispositionSelected(.background)) {
            $0.pendingNewTab = nil
        }
        await store.finish()

        let newTab = try #require(store.state.tabs.last)
        #expect(newTab.content == .web(requestedURL: destination))
        #expect(newTab.openerID == openerID)
        #expect(store.state.selectedTabID == openerID)
        #expect(commands.value.map(\.route) == [
            .ensureContext(tabID: newTab.id),
            .load(tabID: newTab.id, url: destination),
        ])
    }
}

private enum BrowserCommandRoute: Equatable {
    case ensureContext(tabID: BrowserTabID)
    case destroyContext(tabID: BrowserTabID)
    case load(tabID: BrowserTabID, url: URL)
    case goBack(tabID: BrowserTabID)
    case goForward(tabID: BrowserTabID)
    case reload(tabID: BrowserTabID)
    case stop(tabID: BrowserTabID)
    case showBackForwardList(tabID: BrowserTabID, direction: BrowserNavigationDirection)
    case find(tabID: BrowserTabID, query: String)
    case goToBackForwardEntry(tabID: BrowserTabID, token: BrowserBackForwardEntry.Token)
    case capturePreview(tabID: BrowserTabID, revision: BrowserTabPreviewRevision)
    case dismissJavaScriptDialog(tabID: BrowserTabID)
}

extension BrowserWebKitCommand {
    fileprivate var route: BrowserCommandRoute {
        switch self {
        case let .ensureContext(tabID):
            .ensureContext(tabID: tabID)
        case let .destroyContext(tabID):
            .destroyContext(tabID: tabID)
        case let .load(tabID, url, _):
            .load(tabID: tabID, url: url)
        case let .goBack(tabID, _):
            .goBack(tabID: tabID)
        case let .goForward(tabID, _):
            .goForward(tabID: tabID)
        case let .reload(tabID, _):
            .reload(tabID: tabID)
        case let .stop(tabID):
            .stop(tabID: tabID)
        case let .showBackForwardList(tabID, direction):
            .showBackForwardList(tabID: tabID, direction: direction)
        case let .find(tabID, query):
            .find(tabID: tabID, query: query)
        case let .goToBackForwardEntry(tabID, token, _):
            .goToBackForwardEntry(tabID: tabID, token: token)
        case let .capturePreview(tabID, revision):
            .capturePreview(tabID: tabID, revision: revision)
        case let .dismissJavaScriptDialog(tabID):
            .dismissJavaScriptDialog(tabID: tabID)
        }
    }
}
