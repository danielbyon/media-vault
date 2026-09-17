//
//  BrowserTabTests.swift
//  MediaVault
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import ComposableArchitecture
import Foundation
import Testing
@testable import BrowserFeature

@Suite("Browser tab behavior")
@MainActor
struct BrowserTabTests {
    private let first = BrowserTabID(UUID(9))
    private let second = BrowserTabID(UUID(1))
    private let third = BrowserTabID(UUID(2))

    @Test("Construction, New Tab, and close-last always settle with a Start Page")
    func neverSettlesAtZeroTabs() async {
        var state = BrowserFeature.State(initialTabID: first)
        state.settings.copiedLinkSuggestionsEnabled = false
        let store = TestStore(initialState: state) {
            BrowserFeature()
        } withDependencies: {
            $0.uuid = .incrementing
        }

        #expect(store.state.tabs == [.startPage(id: first)])
        await store.send(.closeTab(first)) {
            $0.tabs = [.startPage(id: BrowserTabID(UUID(0)))]
            $0.selectedTabID = BrowserTabID(UUID(0))
            $0.focusedField = .none
        }
        await store.send(.newTabTapped) {
            $0.tabs.append(.startPage(id: BrowserTabID(UUID(1))))
            $0.selectedTabID = BrowserTabID(UUID(1))
            $0.focusedField = .startPage
        }
    }

    @Test("Closing an active tab selects its left neighbor and preserves stable order")
    func activeNeighborSelection() async throws {
        let state = try BrowserFeature.State(
            tabs: [
                .startPage(id: first),
                .web(id: second, url: #require(URL(string: "https://two.example"))),
                .web(id: third, url: #require(URL(string: "https://three.example"))),
            ],
            selectedTabID: second,
        )
        let store = TestStore(initialState: state) { BrowserFeature() }

        await store.send(.closeTab(second)) {
            $0.tabs.remove(at: 1)
            $0.selectedTabID = first
        }
    }

    @Test("Start Page navigation consumes the same tab and remains outside WebKit history")
    func startPageRootNavigation() async throws {
        let destination = try #require(URL(string: "https://example.com"))
        let commands = LockIsolated<[BrowserWebKitCommand]>([])
        let store = TestStore(initialState: BrowserFeature.State(initialTabID: first)) {
            BrowserFeature()
        } withDependencies: {
            $0.browserWebKit.execute = { command in
                commands.withValue { $0.append(command) }
            }
        }

        await store.send(.omniboxFocused) {
            $0.focusedField = .startPage
        }
        await store.receive(.clipboardChecked(nil))
        await store.send(.omniboxChanged("example.com")) {
            $0.omniboxDraft = "example.com"
            $0.hasUnsubmittedOmniboxDraft = true
            $0.suggestions = BrowserSuggestions.complete(
                draft: "example.com",
                provider: .duckDuckGo,
                bookmarks: [],
                history: [],
                providerValues: [],
            )
        }
        await store.send(.omniboxSubmitted) {
            $0.tabs[0] = .web(id: first, url: destination)
            $0.focusedField = .none
            $0.omniboxDraft = ""
            $0.hasUnsubmittedOmniboxDraft = false
            $0.suggestions = []
        }
        await store.finish()
        #expect(try commands.value == [
            .ensureContext(tabID: first),
            .load(tabID: first, url: destination),
        ])
        #expect(store.state.tabs[0].canGoBack == false)
    }

    @Test("Omnibox focus distinguishes the Start Page from web chrome")
    func omniboxFocusRoutesByActiveTab() async throws {
        let url = try #require(URL(string: "https://example.com/private"))

        let startPageStore = TestStore(initialState: BrowserFeature.State(initialTabID: first)) {
            BrowserFeature()
        }
        await startPageStore.send(.omniboxFocused) {
            $0.focusedField = .startPage
        }
        await startPageStore.receive(.clipboardChecked(nil))

        var webTab = BrowserTab.web(id: first, url: url)
        webTab.metadata.committedURL = url
        let webStore = TestStore(initialState: BrowserFeature.State(
            tabs: [webTab],
            selectedTabID: first,
        )) {
            BrowserFeature()
        }
        await webStore.send(.omniboxFocused) {
            $0.focusedField = .chrome
            $0.omniboxDraft = url.absoluteString
            $0.suggestions = BrowserSuggestions.complete(
                draft: url.absoluteString,
                provider: .duckDuckGo,
                bookmarks: [],
                history: [],
                providerValues: [],
            )
        }
    }

    @Test("Start Page command reuses without focus while explicit New Tab always appends and focuses")
    func startPageReuse() async throws {
        let web = try BrowserTab.web(id: first, url: #require(URL(string: "https://one.example")))
        let start = BrowserTab.startPage(id: second)
        var state = BrowserFeature.State(
            tabs: [web, start],
            selectedTabID: first,
        )
        state.settings.copiedLinkSuggestionsEnabled = false
        let store = TestStore(initialState: state) { BrowserFeature() } withDependencies: {
            $0.uuid = .incrementing
        }

        await store.send(.showStartPageTapped) {
            $0.selectedTabID = second
            $0.focusedField = .none
        }
        await store.send(.newTabTapped) {
            $0.tabs.append(.startPage(id: BrowserTabID(UUID(0))))
            $0.selectedTabID = BrowserTabID(UUID(0))
            $0.focusedField = .startPage
        }
    }

    @Test("Explicit Start Page creates and focuses one when none exists")
    func explicitStartPageCreation() async throws {
        let url = try #require(URL(string: "https://example.com"))
        var state = BrowserFeature.State(initialTabID: first)
        state.tabs = [.web(id: first, url: url)]
        state.settings.copiedLinkSuggestionsEnabled = false
        let store = TestStore(initialState: state) { BrowserFeature() } withDependencies: {
            $0.uuid = .incrementing
        }

        await store.send(.showStartPageTapped) {
            $0.tabs.append(.startPage(id: BrowserTabID(UUID(0))))
            $0.selectedTabID = BrowserTabID(UUID(0))
            $0.focusedField = .startPage
        }
    }

    @Test("Related and site-created tabs are contiguous, stable, and only the first foreground event focuses")
    func relatedTabOrderingAndFocus() async throws {
        let opener = first
        let unrelated = second
        let popupOne = third
        let popupTwo = BrowserTabID(UUID(3))
        let openerURL = try #require(URL(string: "https://opener.example"))
        let popupOneURL = try #require(URL(string: "https://popup-one.example"))
        let popupTwoURL = try #require(URL(string: "https://popup-two.example"))
        let store = TestStore(initialState: BrowserFeature.State(
            tabs: [
                .web(id: opener, url: openerURL),
                .startPage(id: unrelated),
            ],
            selectedTabID: opener,
        )) { BrowserFeature() }

        try await store.send(.webKitEvent(.siteCreatedTab(
            openerID: opener,
            tabID: popupOne,
            url: popupOneURL,
            foreground: true,
        ))) {
            $0.tabs.insert(.scriptCreatedWeb(
                id: popupOne,
                openerID: opener,
                url: popupOneURL,
            ), at: 1)
            $0.selectedTabID = popupOne
        }
        try await store.send(.webKitEvent(.siteCreatedTab(
            openerID: opener,
            tabID: popupTwo,
            url: popupTwoURL,
            foreground: false,
        ))) {
            $0.tabs.insert(.scriptCreatedWeb(
                id: popupTwo,
                openerID: opener,
                url: popupTwoURL,
            ), at: 2)
        }
        #expect(store.state.tabs.map(\.id) == [opener, popupOne, popupTwo, unrelated])
        #expect(store.state.selectedTabID == popupOne)
    }

    @Test("Selecting a Start Page card exits overview without summoning the keyboard")
    func overviewStartPageSelectionDoesNotFocus() async throws {
        let pageURL = try #require(URL(string: "https://one.example"))
        let store = TestStore(initialState: BrowserFeature.State(
            tabs: [
                .web(id: first, url: pageURL),
                .startPage(id: second),
            ],
            selectedTabID: first,
            presentation: .tabOverview,
        )) { BrowserFeature() }

        await store.send(.tabCardSelected(second)) {
            $0.selectedTabID = second
            $0.presentation = .browsing
            $0.focusedField = .none
        }
    }

    @Test("Closing the selected overview card focuses the surviving selected card")
    func closingSelectedOverviewCardMovesFocusToSelection() async throws {
        let firstURL = try #require(URL(string: "https://one.example"))
        let secondURL = try #require(URL(string: "https://two.example"))
        let thirdURL = try #require(URL(string: "https://three.example"))
        var state = BrowserFeature.State(
            tabs: [
                .web(id: first, url: firstURL),
                .web(id: second, url: secondURL),
                .web(id: third, url: thirdURL),
            ],
            selectedTabID: first,
            presentation: .tabOverview,
        )
        state.tabOverviewFocusID = first
        let store = TestStore(initialState: state) { BrowserFeature() }

        await store.send(.closeTab(first)) {
            $0.tabs.removeFirst()
            $0.selectedTabID = second
            $0.tabOverviewFocusID = second
        }
    }

    @Test("Closing a focused background overview card focuses its nearest left survivor")
    func closingFocusedBackgroundCardMovesFocusToNearestSurvivor() async throws {
        let firstURL = try #require(URL(string: "https://one.example"))
        let secondURL = try #require(URL(string: "https://two.example"))
        let fourthURL = try #require(URL(string: "https://four.example"))
        var state = BrowserFeature.State(
            tabs: [
                .web(id: first, url: firstURL),
                .web(id: second, url: secondURL),
                .startPage(id: third),
                .web(id: BrowserTabID(UUID(3)), url: fourthURL),
            ],
            selectedTabID: first,
            presentation: .tabOverview,
        )
        state.tabOverviewFocusID = third
        let store = TestStore(initialState: state) { BrowserFeature() }

        await store.send(.closeTab(third)) {
            $0.tabs.remove(at: 2)
            $0.tabOverviewFocusID = second
        }
    }

    @Test("Closing an unrelated background overview card preserves the surviving accessibility focus")
    func closingUnrelatedBackgroundCardPreservesFocus() async throws {
        let firstURL = try #require(URL(string: "https://one.example"))
        let secondURL = try #require(URL(string: "https://two.example"))
        let thirdURL = try #require(URL(string: "https://three.example"))
        var state = BrowserFeature.State(
            tabs: [
                .web(id: first, url: firstURL),
                .web(id: second, url: secondURL),
                .web(id: third, url: thirdURL),
            ],
            selectedTabID: first,
            presentation: .tabOverview,
        )
        state.tabOverviewFocusID = second
        let store = TestStore(initialState: state) { BrowserFeature() }

        await store.send(.closeTab(third)) {
            $0.tabs.remove(at: 2)
            $0.tabOverviewFocusID = second
        }
    }

    @Test("Closing the final overview card focuses the newly created Start Page")
    func closingFinalOverviewCardFocusesFreshStartPage() async throws {
        let url = try #require(URL(string: "https://one.example"))
        var state = BrowserFeature.State(
            tabs: [.web(id: first, url: url)],
            selectedTabID: first,
            presentation: .tabOverview,
        )
        state.tabOverviewFocusID = first
        let store = TestStore(initialState: state) { BrowserFeature() } withDependencies: {
            $0.uuid = .incrementing
        }

        await store.send(.closeTab(first)) {
            $0.tabs = [.startPage(id: BrowserTabID(UUID(0)))]
            $0.selectedTabID = BrowserTabID(UUID(0))
            $0.tabOverviewFocusID = BrowserTabID(UUID(0))
        }
    }
}

extension UUID {
    fileprivate init(_ value: UInt8) {
        self.init(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, value))
    }
}
