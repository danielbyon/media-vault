//
//  BrowserTabTests.swift
//  MediaVault
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Clocks
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
        store.exhaustivity = .off(showSkippedAssertions: false)

        #expect(store.state.tabs == [.startPage(id: first)])
        await store.send(.closeTab(first))
        #expect(store.state.tabs == [.startPage(id: BrowserTabID(UUID(0)))])
        #expect(store.state.selectedTabID == BrowserTabID(UUID(0)))
        #expect(store.state.focusedField == .none)
        await store.send(.newTabTapped)
        #expect(store.state.tabs.map(\.id) == [BrowserTabID(UUID(0)), BrowserTabID(UUID(1))])
        #expect(store.state.selectedTabID == BrowserTabID(UUID(1)))
        #expect(store.state.focusedField == .startPage)
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
            $0.previewState.removeTab(second)
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
        let initialRevision = store.state.previewState.revision(for: first)
        store.exhaustivity = .off(showSkippedAssertions: false)
        await store.send(.omniboxSubmitted)
        #expect(store.state.tabs[0] == .web(id: first, url: destination))
        #expect(store.state.focusedField == .none)
        #expect(store.state.omniboxDraft.isEmpty)
        #expect(store.state.hasUnsubmittedOmniboxDraft == false)
        #expect(store.state.suggestions.isEmpty)
        #expect(store.state.previewState.revision(for: first) != initialRevision)
        #expect(store.state.previewState.operation(for: first) != nil)
        let operationID = try #require(store.state.previewState.operation(for: first))
        await store.finish()
        #expect(try commands.value == [
            .ensureContext(tabID: first),
            .load(tabID: first, url: destination, operationID: operationID),
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
        store.exhaustivity = .off(showSkippedAssertions: false)
        await store.send(.newTabTapped)
        #expect(store.state.tabs.map(\.id) == [first, second, BrowserTabID(UUID(0))])
        #expect(store.state.selectedTabID == BrowserTabID(UUID(0)))
        #expect(store.state.focusedField == .startPage)
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

        store.exhaustivity = .off(showSkippedAssertions: false)
        await store.send(.showStartPageTapped)
        #expect(store.state.tabs.map(\.id) == [first, BrowserTabID(UUID(0))])
        #expect(store.state.selectedTabID == BrowserTabID(UUID(0)))
        #expect(store.state.focusedField == .startPage)
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
        var state = BrowserFeature.State(
            tabs: [
                .web(id: opener, url: openerURL),
                .startPage(id: unrelated),
            ],
            selectedTabID: opener,
        )
        state.settings.openLinksInNewTabs = .askEveryTime
        let store = TestStore(initialState: state) { BrowserFeature() }

        store.exhaustivity = .off(showSkippedAssertions: false)
        try await store.send(.webKitEvent(.siteCreatedTab(
            openerID: opener,
            tabID: popupOne,
            url: popupOneURL,
            foreground: true,
        )))
        try await store.send(.webKitEvent(.siteCreatedTab(
            openerID: opener,
            tabID: popupTwo,
            url: popupTwoURL,
            foreground: false,
        )))
        #expect(store.state.tabs.map(\.id) == [opener, popupOne, popupTwo, unrelated])
        #expect(store.state.selectedTabID == popupOne)
        #expect(store.state.pendingNewTab == nil)
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
            $0.previewState.removeTab(first)
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
            $0.previewState.removeTab(third)
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
            $0.previewState.removeTab(third)
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

        store.exhaustivity = .off(showSkippedAssertions: false)
        await store.send(.closeTab(first))
        #expect(store.state.tabs == [.startPage(id: BrowserTabID(UUID(0)))])
        #expect(store.state.selectedTabID == BrowserTabID(UUID(0)))
        #expect(store.state.tabOverviewFocusID == BrowserTabID(UUID(0)))
    }

    @Test("Fresh Browser state starts without a Tab Overview scroll anchor")
    func freshStateStartsWithoutTabOverviewScrollAnchor() {
        #expect(BrowserFeature.State(initialTabID: first).tabOverviewScrollPosition == nil)
        #expect(
            BrowserFeature.State(
                tabs: [.startPage(id: first), .startPage(id: second)],
                selectedTabID: first,
            )
            .tabOverviewScrollPosition == nil,
        )
    }

    @Test("Tab Overview scroll commits are accepted only before overview exit")
    func tabOverviewScrollCommitsAreLimitedToOverview() async {
        let store = TestStore(initialState: BrowserFeature.State(
            tabs: [.startPage(id: first), .startPage(id: second)],
            selectedTabID: first,
            presentation: .tabOverview,
        )) {
            BrowserFeature()
        }

        await store.send(.tabOverviewScrollChanged(second)) {
            $0.tabOverviewScrollPosition = second
        }
        await store.send(.tabOverviewScrollChanged(second))
        await store.send(.tabOverviewScrollChanged(BrowserTabID(UUID(3))))
        #expect(store.state.tabOverviewScrollPosition == second)

        await store.send(.tabCardSelected(second)) {
            $0.selectedTabID = second
            $0.presentation = .browsing
            $0.tabOverviewFocusID = nil
        }
        await store.send(.tabOverviewScrollChanged(first))
        #expect(store.state.tabOverviewScrollPosition == second)
    }

    @Test("Live Tab Overview scroll identity stays local until commit and follows reconciliation")
    func tabOverviewScrollAdapterCommitsOnlyStableIdentity() async {
        var initialState = BrowserFeature.State(
            tabs: [
                .startPage(id: first),
                .startPage(id: second),
                .startPage(id: third),
            ],
            selectedTabID: first,
            presentation: .tabOverview,
        )
        initialState.tabOverviewScrollPosition = first
        let store = TestStore(initialState: initialState) {
            BrowserFeature()
        }
        let adapter = BrowserTabOverviewScrollPosition(persistedPosition: first)

        #expect(!adapter.updateLivePosition(nil))
        adapter.updateScrollPhase(.interacting)
        #expect(adapter.updateLivePosition(second))
        #expect(adapter.livePosition == second)
        #expect(adapter.persistedPosition == first)
        #expect(store.state.tabOverviewScrollPosition == first)

        #expect(adapter.commit() == second)
        #expect(adapter.persistedPosition == first)
        #expect(adapter.updateLivePosition(third))
        await store.send(.tabOverviewScrollChanged(second)) {
            $0.tabOverviewScrollPosition = second
        }
        #expect(adapter.synchronize(
            with: store.state.tabOverviewScrollPosition,
            liveTabIDs: Set(store.state.tabs.map(\.id)),
        ))
        #expect(adapter.persistedPosition == second)
        #expect(adapter.livePosition == third)
        #expect(adapter.commit() == third)

        let allTabIDs: Set<BrowserTabID> = [first, second, third]
        #expect(adapter.synchronize(with: third, liveTabIDs: allTabIDs))
        #expect(adapter.livePosition == third)
        #expect(adapter.persistedPosition == third)
        #expect(!adapter.synchronize(with: third, liveTabIDs: allTabIDs))
        #expect(!adapter.updateLivePosition(nil))
    }

    @Test("A removed live overview target falls back to the reducer-owned anchor")
    func tabOverviewScrollAdapterDropsRemovedLiveTargets() {
        let adapter = BrowserTabOverviewScrollPosition(persistedPosition: first)

        adapter.updateScrollPhase(.interacting)
        #expect(adapter.updateLivePosition(third))
        #expect(adapter.commit() == third)
        #expect(adapter.persistedPosition == first)
        #expect(!adapter.synchronize(with: first, liveTabIDs: [first, second]))
        #expect(adapter.livePosition == first)
        #expect(adapter.persistedPosition == first)
        #expect(adapter.commit() == nil)
    }

    @Test("A delayed live target remains local after the scroll phase settles")
    func tabOverviewScrollAdapterAcceptsDelayedTargetsAfterSettling() {
        let adapter = BrowserTabOverviewScrollPosition(persistedPosition: first)

        adapter.updateScrollPhase(.interacting)
        #expect(adapter.updateLivePosition(second))
        adapter.updateScrollPhase(.idle)
        #expect(!adapter.updateLivePosition(second))
        #expect(adapter.updateLivePosition(third))
        #expect(adapter.livePosition == third)
        #expect(adapter.commit() == third)

        let fourth = BrowserTabID()
        #expect(!adapter.synchronize(with: first, liveTabIDs: [first, second, third, fourth]))
        #expect(!adapter.updateLivePosition(third))
        #expect(adapter.livePosition == third)
    }

    @Test("Animating overview targets are accepted and become the reducer restoration anchor")
    func tabOverviewScrollAdapterCommitsAnimatingTargets() async {
        let initialState = BrowserFeature.State(
            tabs: [
                .startPage(id: first),
                .startPage(id: second),
                .startPage(id: third),
            ],
            selectedTabID: first,
            presentation: .tabOverview,
        )
        let store = TestStore(initialState: initialState) {
            BrowserFeature()
        }
        let adapter = BrowserTabOverviewScrollPosition(persistedPosition: first)

        adapter.updateScrollPhase(.animating)
        #expect(adapter.updateLivePosition(second))
        #expect(adapter.commit() == second)
        await store.send(.tabOverviewScrollChanged(second)) {
            $0.tabOverviewScrollPosition = second
        }
        #expect(adapter.synchronize(
            with: store.state.tabOverviewScrollPosition,
            liveTabIDs: Set(store.state.tabs.map(\.id)),
        ))
        #expect(adapter.persistedPosition == second)
    }

    @Test("Reducer synchronization during interaction preserves subsequent live targets")
    func tabOverviewScrollAdapterKeepsActivePhaseDuringSynchronization() {
        let adapter = BrowserTabOverviewScrollPosition(persistedPosition: first)

        adapter.updateScrollPhase(.interacting)
        #expect(adapter.updateLivePosition(second))
        #expect(adapter.synchronize(with: second, liveTabIDs: [second, third]))
        #expect(adapter.updateLivePosition(third))
        #expect(adapter.livePosition == third)
        #expect(adapter.commit() == third)
    }

    @Test("Scroll adapter exposes the observed phase for deterministic restoration settlement")
    func tabOverviewScrollAdapterExposesObservedPhase() {
        let adapter = BrowserTabOverviewScrollPosition()

        #expect(adapter.scrollPhase == .idle)
        adapter.updateScrollPhase(.animating)
        #expect(adapter.scrollPhase == .animating)
        adapter.updateScrollPhase(.idle)
        #expect(adapter.scrollPhase == .idle)
    }

    @Test("Scroll adapter exposes full target visibility and resets it on restoration")
    func tabOverviewScrollAdapterTracksPersistedTargetVisibility() {
        let adapter = BrowserTabOverviewScrollPosition(persistedPosition: first)

        #expect(!adapter.isPersistedTargetFullyVisible)
        adapter.updatePersistedTargetVisibility(true)
        #expect(adapter.isPersistedTargetFullyVisible)

        #expect(adapter.synchronize(with: second, liveTabIDs: [first, second]))
        #expect(!adapter.isPersistedTargetFullyVisible)
        adapter.updatePersistedTargetVisibility(true)
        #expect(adapter.isPersistedTargetFullyVisible)

        adapter.restore(with: first, liveTabIDs: [first, second])
        #expect(!adapter.isPersistedTargetFullyVisible)
    }

    @Test("Reducer-owned restoration and reconciliation targets ignore exact binding echoes")
    func tabOverviewScrollAdapterIgnoresReducerTargetEchoes() {
        let adapter = BrowserTabOverviewScrollPosition(persistedPosition: first)
        let liveTabIDs: Set<BrowserTabID> = [first, second, third]

        adapter.restore(with: second, liveTabIDs: liveTabIDs)
        #expect(!adapter.updateLivePosition(second))
        #expect(adapter.livePosition == second)
        #expect(adapter.synchronize(with: third, liveTabIDs: liveTabIDs))
        #expect(!adapter.updateLivePosition(third))
        #expect(adapter.livePosition == third)
        #expect(adapter.commit() == nil)
    }

    @Test("A new animating target remains eligible after restoration echo handling")
    func tabOverviewScrollAdapterAcceptsNewTargetAfterRestorationEcho() {
        let adapter = BrowserTabOverviewScrollPosition(persistedPosition: first)

        adapter.restore(with: second, liveTabIDs: [first, second, third])
        #expect(!adapter.updateLivePosition(second))
        adapter.updateScrollPhase(.animating)
        #expect(adapter.updateLivePosition(third))
        #expect(adapter.commit() == third)
    }

    @Test("A quiet-window fallback commits only the latest local target")
    func tabOverviewScrollAdapterCoalescesStableFallbacks() async {
        let clock = TestClock()
        let adapter = BrowserTabOverviewScrollPosition(persistedPosition: first) { duration in
            try await clock.sleep(for: duration)
        }
        var committedPositions: [BrowserTabID] = []

        #expect(adapter.updateLivePosition(second))
        adapter.scheduleStableFallback(after: .milliseconds(100)) {
            if let position = adapter.commit() {
                committedPositions.append(position)
            }
        }
        await Task.yield()
        await clock.advance(by: .milliseconds(50))
        #expect(adapter.updateLivePosition(third))
        adapter.scheduleStableFallback(after: .milliseconds(100)) {
            if let position = adapter.commit() {
                committedPositions.append(position)
            }
        }
        await Task.yield()

        await clock.advance(by: .milliseconds(60))
        #expect(committedPositions.isEmpty)
        await clock.advance(by: .milliseconds(40))
        #expect(committedPositions == [third])
    }

    @Test("An explicit stable commit cancels its pending fallback")
    func tabOverviewScrollAdapterCancelsFallbackAfterCommit() async {
        let clock = TestClock()
        let adapter = BrowserTabOverviewScrollPosition(persistedPosition: first) { duration in
            try await clock.sleep(for: duration)
        }
        var fallbackWasCalled = false

        #expect(adapter.updateLivePosition(second))
        adapter.scheduleStableFallback(after: .milliseconds(100)) {
            fallbackWasCalled = true
        }
        await Task.yield()
        #expect(adapter.commit() == second)
        await clock.advance(by: .seconds(1))
        #expect(!fallbackWasCalled)
    }

    @Test("Tab Overview scroll anchor survives repeated browsing transitions")
    func tabOverviewScrollAnchorSurvivesRepeatedBrowsingTransitions() async {
        let store = TestStore(initialState: BrowserFeature.State(
            tabs: [
                .startPage(id: first),
                .startPage(id: second),
                .startPage(id: third),
            ],
            selectedTabID: first,
            presentation: .tabOverview,
        )) {
            BrowserFeature()
        }
        store.exhaustivity = .off(showSkippedAssertions: false)

        await store.send(.tabOverviewScrollChanged(third))
        await store.send(.tabCardSelected(second))
        await store.send(.showTabOverviewTapped)
        await store.send(.tabCardSelected(first))
        await store.send(.showTabOverviewTapped)

        #expect(store.state.tabOverviewScrollPosition == third)
        #expect(store.state.tabOverviewFocusID == first)
    }

    @Test("Removing the anchored card chooses the nearest surviving logical tab")
    func removingAnchoredCardChoosesNearestSurvivingLogicalTab() async throws {
        let fourth = BrowserTabID(UUID(3))
        var state = try BrowserFeature.State(
            tabs: [
                .web(id: first, url: #require(URL(string: "https://one.example"))),
                .web(id: second, url: #require(URL(string: "https://two.example"))),
                .web(id: third, url: #require(URL(string: "https://three.example"))),
                .web(id: fourth, url: #require(URL(string: "https://four.example"))),
            ],
            selectedTabID: first,
            presentation: .tabOverview,
        )
        state.tabOverviewFocusID = first
        state.tabOverviewScrollPosition = third
        let store = TestStore(initialState: state) {
            BrowserFeature()
        }

        await store.send(.closeTab(third)) {
            $0.tabs.remove(at: 2)
            $0.previewState.removeTab(third)
            $0.tabOverviewScrollPosition = second
        }

        #expect(store.state.tabOverviewScrollPosition == second)
        #expect(store.state.tabOverviewFocusID == first)
        #expect(store.state.tabs.contains(where: { $0.id == store.state.tabOverviewScrollPosition }))
    }

    @Test("A live scroll anchor survives unrelated tab removal")
    func liveScrollAnchorSurvivesUnrelatedTabRemoval() async throws {
        var state = try BrowserFeature.State(
            tabs: [
                .web(id: first, url: #require(URL(string: "https://one.example"))),
                .web(id: second, url: #require(URL(string: "https://two.example"))),
                .web(id: third, url: #require(URL(string: "https://three.example"))),
            ],
            selectedTabID: first,
            presentation: .browsing,
        )
        state.tabOverviewScrollPosition = second
        let store = TestStore(initialState: state) {
            BrowserFeature()
        }

        await store.send(.closeTab(first)) {
            $0.tabs.removeFirst()
            $0.selectedTabID = second
            $0.previewState.removeTab(first)
        }

        #expect(store.state.tabOverviewScrollPosition == second)
        #expect(store.state.tabOverviewFocusID == nil)
    }

    @Test("Bulk tab mutations preserve live anchors and reconcile removed anchors")
    func bulkTabMutationsPreserveAndReconcileScrollAnchors() async throws {
        let fourth = BrowserTabID(UUID(3))
        let tabs = try [
            BrowserTab.web(id: first, url: #require(URL(string: "https://one.example"))),
            BrowserTab.web(id: second, url: #require(URL(string: "https://two.example"))),
            BrowserTab.web(id: third, url: #require(URL(string: "https://three.example"))),
            BrowserTab.web(id: fourth, url: #require(URL(string: "https://four.example"))),
        ]
        var state = BrowserFeature.State(
            tabs: tabs,
            selectedTabID: first,
            presentation: .browsing,
        )
        state.tabOverviewScrollPosition = third
        let store = TestStore(initialState: state) {
            BrowserFeature()
        } withDependencies: {
            $0.uuid = .incrementing
        }
        store.exhaustivity = .off(showSkippedAssertions: false)

        await store.send(.closeOtherTabsConfirmed(third))
        #expect(store.state.tabs.map(\.id) == [third])
        #expect(store.state.tabOverviewScrollPosition == third)

        var replacementState = BrowserFeature.State(
            tabs: tabs,
            selectedTabID: first,
            presentation: .browsing,
        )
        replacementState.tabOverviewScrollPosition = second
        let replacementStore = TestStore(initialState: replacementState) {
            BrowserFeature()
        } withDependencies: {
            $0.uuid = .incrementing
        }
        replacementStore.exhaustivity = .off(showSkippedAssertions: false)

        await replacementStore.send(.closeAllConfirmed)
        let replacementID = try #require(replacementStore.state.tabs.first?.id)
        #expect(replacementStore.state.tabs.count == 1)
        #expect(replacementStore.state.tabOverviewScrollPosition == replacementID)
        #expect(
            replacementStore.state.tabs.contains {
                $0.id == replacementStore.state.tabOverviewScrollPosition
            },
        )
    }
}

extension UUID {
    fileprivate init(_ value: UInt8) {
        self.init(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, value))
    }
}
