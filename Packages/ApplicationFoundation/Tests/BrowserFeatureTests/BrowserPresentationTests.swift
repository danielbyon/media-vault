//
//  BrowserPresentationTests.swift
//  MediaVault
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import ComposableArchitecture
import Foundation
import Testing
@testable import BrowserFeature

@Suite("Browser Library and settings presentation")
@MainActor
struct BrowserPresentationTests {
    @Test("Each Library invocation owns fresh transient section state and blocks overview")
    func libraryPresentationLifetime() async {
        let referenceDate = Date(timeIntervalSince1970: 1_700_000_000)
        let store = TestStore(initialState: BrowserFeature.State(initialTabID: BrowserTabID())) {
            BrowserFeature()
        } withDependencies: {
            $0.date.now = referenceDate
        }
        await store.send(.libraryPresented(.history)) {
            $0.library = .init(section: .history, referenceDate: referenceDate)
        }
        await store.send(.librarySearchChanged(.history, "private")) {
            $0.library?.historySearch = "private"
        }
        await store.send(.showTabOverviewTapped)
        #expect(store.state.presentation == .browsing)
        await store.send(.libraryDismissed) { $0.library = nil }
        await store.send(.libraryPresented(.bookmarks)) {
            $0.library = .init(section: .bookmarks, referenceDate: referenceDate)
        }
        #expect(store.state.library?.historySearch.isEmpty == true)
    }

    @Test("Bookmarks and History keep independent scroll anchors during one modal")
    func libraryScrollAnchors() async {
        let bookmarkID = UUID()
        let historyID = UUID()
        let referenceDate = Date(timeIntervalSince1970: 1_700_000_000)
        let store = TestStore(initialState: BrowserFeature.State(initialTabID: BrowserTabID())) {
            BrowserFeature()
        } withDependencies: {
            $0.date.now = referenceDate
        }

        await store.send(.libraryPresented(.bookmarks)) {
            $0.library = .init(section: .bookmarks, referenceDate: referenceDate)
        }
        await store.send(.libraryScrollChanged(.bookmarks, bookmarkID)) {
            $0.library?.bookmarkScrollPosition = bookmarkID
        }
        await store.send(.librarySearchChanged(.bookmarks, "bookmark")) {
            $0.library?.bookmarkSearch = "bookmark"
        }
        await store.send(.libraryPresented(.history)) {
            $0.library?.section = .history
        }
        await store.send(.libraryScrollChanged(.history, historyID)) {
            $0.library?.historyScrollPosition = historyID
        }
        await store.send(.librarySearchChanged(.history, "history")) {
            $0.library?.historySearch = "history"
        }
        await store.send(.libraryPresented(.bookmarks)) {
            $0.library?.section = .bookmarks
        }
        #expect(store.state.library?.bookmarkScrollPosition == bookmarkID)
        #expect(store.state.library?.historyScrollPosition == historyID)
        #expect(store.state.library?.bookmarkSearch == "bookmark")
        #expect(store.state.library?.historySearch == "history")

        await store.send(.libraryDismissed) { $0.library = nil }
        await store.send(.libraryPresented(.history)) {
            $0.library = .init(section: .history, referenceDate: referenceDate)
        }
        #expect(store.state.library?.bookmarkScrollPosition == nil)
        #expect(store.state.library?.historyScrollPosition == nil)
        #expect(store.state.library?.bookmarkSearch.isEmpty == true)
        #expect(store.state.library?.historySearch.isEmpty == true)
    }

    @Test("View Bookmark opens Bookmarks and reveals the exact stable identity")
    func viewBookmark() async {
        let id = UUID()
        let referenceDate = Date(timeIntervalSince1970: 1_700_000_000)
        let store = TestStore(initialState: BrowserFeature.State(initialTabID: BrowserTabID())) {
            BrowserFeature()
        } withDependencies: {
            $0.date.now = referenceDate
        }
        await store.send(.viewBookmark(id)) {
            $0.library = .init(
                section: .bookmarks,
                bookmarkScrollPosition: id,
                revealedBookmarkID: id,
                referenceDate: referenceDate,
            )
        }
    }

    @Test("Both Clear History entry points use one confirmed injectable operation")
    func clearHistoryRouting() async {
        let calls = LockIsolated(0)
        let store = TestStore(initialState: BrowserFeature.State(initialTabID: BrowserTabID())) {
            BrowserFeature()
        } withDependencies: {
            $0.browserLibrary.clearHistory = { calls.withValue { $0 += 1 } }
        }
        store.exhaustivity = .off(showSkippedAssertions: false)

        await store.send(.clearHistoryTapped(source: .library))
        #expect(calls.value == 0)
        await store.send(.destructiveActionConfirmed)
        await store.finish()
        #expect(calls.value == 1)

        await store.send(.clearHistoryTapped(source: .settings))
        await store.send(.destructiveActionConfirmed)
        await store.finish()
        #expect(calls.value == 2)
    }

    @Test("Delete All Bookmarks confirmation carries the available count")
    func deleteAllBookmarksConfirmation() async throws {
        var state = BrowserFeature.State(initialTabID: BrowserTabID())
        state.bookmarks = try [BrowserBookmark(
            id: UUID(),
            title: "One",
            url: #require(URL(string: "https://one.example")),
            siblingOrder: 0,
        )]
        let store = TestStore(initialState: state) { BrowserFeature() }
        await store.send(.deleteAllBookmarksTapped) {
            $0.destructiveConfirmation = .deleteAllBookmarks(count: 1)
        }
    }

    @Test("Settings defaults and provider privacy disclosure are explicit")
    func settingsDefaults() {
        let settings = BrowserSettings()
        #expect(settings.searchProvider == .duckDuckGo)
        #expect(settings.providerSuggestionsEnabled == false)
        #expect(settings.copiedLinkSuggestionsEnabled)
        #expect(settings.openLinksInNewTabs == .background)
        #expect(BrowserSettings.providerSuggestionDisclosure.contains("partial typed text"))
        #expect(BrowserSettings.providerSuggestionDisclosure.contains("before submission"))
    }

    @Test("Bookmark editor validates addresses and duplicate URLs update stable identity in place")
    func bookmarkEditorValidationAndDuplicate() async throws {
        let id = UUID()
        let expectedURL = try #require(URL(string: "https://example.com"))
        var state = BrowserFeature.State(initialTabID: BrowserTabID())
        state.bookmarks = [.init(
            id: id,
            title: "Old",
            url: expectedURL,
            siblingOrder: 7,
        )]
        let saves = LockIsolated<[BrowserBookmark]>([])
        let store = TestStore(initialState: state) { BrowserFeature() } withDependencies: {
            $0.browserLibrary.saveBookmark = { bookmark in
                saves.withValue { values in values.append(bookmark) }
            }
        }

        await store.send(.editBookmarkTapped(id)) {
            $0.bookmarkEditor = BrowserBookmarkEditor(bookmarkID: id, title: "Old", urlDraft: "https://example.com")
        }
        await store.send(.bookmarkEditorChanged(title: "Revised", url: "javascript:alert(1)")) {
            $0.bookmarkEditor?.title = "Revised"
            $0.bookmarkEditor?.urlDraft = "javascript:alert(1)"
        }
        await store.send(.bookmarkEditorSaved) {
            $0.bookmarkEditor?.validationMessage = "Enter a valid HTTP or HTTPS address."
        }
        await store.send(.bookmarkEditorChanged(title: "Revised", url: "example.com")) {
            $0.bookmarkEditor?.urlDraft = "example.com"
            $0.bookmarkEditor?.validationMessage = nil
        }
        await store.send(.bookmarkEditorSaved) {
            $0.bookmarks[0] = BrowserBookmark(id: id, title: "Revised", url: expectedURL, siblingOrder: 7)
            $0.bookmarkEditor = nil
        }
        await store.finish()
        #expect(saves.value.map(\.id) == [id])
    }

    @Test("Find on Page sends only stable identity and text through the adapter client")
    func findOnPageRouting() async throws {
        let tabID = BrowserTabID()
        let url = try #require(URL(string: "https://example.com"))
        let commands = LockIsolated<[BrowserWebKitCommand]>([])
        let store = TestStore(initialState: BrowserFeature.State(
            tabs: [.web(id: tabID, url: url)],
            selectedTabID: tabID,
        )) { BrowserFeature() } withDependencies: {
            $0.browserWebKit.execute = { command in
                commands.withValue { values in values.append(command) }
            }
        }

        await store.send(.findPresented) { $0.findDraft = "" }
        await store.send(.findChanged("needle")) { $0.findDraft = "needle" }
        await store.send(.findDismissed) { $0.findDraft = nil }
        await store.finish()
        #expect(commands.value == [.find(tabID: tabID, query: "needle"), .find(tabID: tabID, query: "")])
    }

    @Test("Tab bulk actions confirm only for multiple meaningful web tabs")
    func tabBulkConfirmation() async throws {
        let first = BrowserTabID()
        let second = BrowserTabID()
        let third = BrowserTabID()
        let secondURL = try #require(URL(string: "https://two.example"))
        let thirdURL = try #require(URL(string: "https://three.example"))
        let store = TestStore(initialState: BrowserFeature.State(
            tabs: [
                .startPage(id: first),
                .web(id: second, url: secondURL),
                .web(id: third, url: thirdURL),
            ],
            selectedTabID: first,
        )) { BrowserFeature() }
        await store.send(.closeOtherTabsTapped(first)) {
            $0.destructiveConfirmation = .closeOtherTabs(keeping: first, count: 2)
        }
        await store.send(.destructiveActionConfirmed) {
            $0.destructiveConfirmation = nil
        }
        await store.receive(.closeOtherTabsConfirmed(first)) {
            $0.tabs = [.startPage(id: first)]
        }
    }

    @Test("Bulk tab cleanup skips confirmation when at most one meaningful web tab closes")
    func tabBulkNoConfirmation() async throws {
        let first = BrowserTabID()
        let second = BrowserTabID()
        let secondURL = try #require(URL(string: "https://two.example"))
        let store = TestStore(initialState: BrowserFeature.State(
            tabs: [.startPage(id: first), .web(id: second, url: secondURL)],
            selectedTabID: first,
        )) { BrowserFeature() }
        await store.send(.closeOtherTabsTapped(first))
        await store.receive(.closeOtherTabsConfirmed(first)) {
            $0.tabs = [.startPage(id: first)]
        }
    }
}
