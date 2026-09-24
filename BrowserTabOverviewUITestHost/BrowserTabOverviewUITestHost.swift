//
//  BrowserTabOverviewUITestHost.swift
//  MediaVault
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import ComposableArchitecture
import SwiftUI
@testable import BrowserFeature

@main
struct BrowserTabOverviewUITestHostApp: App {
    var body: some Scene {
        WindowGroup {
            BrowserTabOverviewUITestHostView()
                .environment(\.horizontalSizeClass, .compact)
        }
    }
}

/// Hosts the production overview with deterministic tabs and a reducer-backed scroll anchor.
@MainActor
private struct BrowserTabOverviewUITestHostView: View {
    private let store: StoreOf<BrowserFeature>
    private let transitionRegistry: BrowserTabTransitionSurfaceRegistry
    @StateObject
    private var scrollPosition: BrowserTabOverviewScrollPosition
    @StateObject
    private var scrollVisibility = BrowserTabOverviewScrollVisibility()
    @State
    private var committedPositionCount = 0
    @AccessibilityFocusState
    private var accessibilityFocusedTabID: BrowserTabID?

    init() {
        let tabs = (0 ..< 40).map { _ in BrowserTab.startPage(id: BrowserTabID()) }
        let arguments = ProcessInfo.processInfo.arguments
        let startsAtLastTab = arguments.contains("--restore-last-tab")
            || arguments.contains("--reconcile-close-last-tab")
        let initialAnchor = startsAtLastTab ? tabs[tabs.count - 1].id : tabs[0].id
        var initialState = BrowserFeature.State(
            tabs: tabs,
            selectedTabID: initialAnchor,
            presentation: .tabOverview,
        )
        initialState.tabOverviewScrollPosition = initialAnchor

        store = Store(initialState: initialState) {
            BrowserFeature()
        }
        transitionRegistry = BrowserTabTransitionSurfaceRegistry()
        let scrollPosition = BrowserTabOverviewScrollPosition()
        scrollPosition.restore(with: initialAnchor, liveTabIDs: Set(tabs.map(\.id)))
        _scrollPosition = StateObject(wrappedValue: scrollPosition)
    }

    var body: some View {
        VStack(spacing: 0) {
            Text("\(savedAnchorDescription)|commits-\(committedPositionCount)")
                .font(.caption)
                .accessibilityIdentifier("browser.tab-overview.saved-anchor")

            BrowserTabOverviewRestoreSettlementLabel(observation: scrollPosition.scrollObservation)

            BrowserTabOverviewView(
                store: store,
                transitionRegistry: transitionRegistry,
                previewAspectRatio: 4.0 / 3.0,
                reduceMotionEnabled: true,
                accessibilityFocusedTabID: $accessibilityFocusedTabID,
                onCommitScrollPosition: commitScrollPosition,
                onExitOverview: handleOverviewExit,
                scrollPosition: scrollPosition,
                scrollVisibility: scrollVisibility,
            )
        }
        .onChange(of: store.state.tabOverviewScrollPosition) { _, _ in
            BrowserView.synchronizeTabOverviewScrollPosition(store: store, adapter: scrollPosition)
        }
        .onChange(of: store.state.tabs.map(\.id)) { _, _ in
            BrowserView.synchronizeTabOverviewScrollPosition(store: store, adapter: scrollPosition)
        }
    }

    private var savedAnchorDescription: String {
        guard let savedAnchor = store.state.tabOverviewScrollPosition,
              let index = store.state.tabs.firstIndex(where: { $0.id == savedAnchor })
        else {
            return "anchor-missing"
        }

        return "anchor-\(index)"
    }

    /// Mirrors BrowserView's parent callback after the overview reports a stable scroll position.
    private func commitScrollPosition(_ position: BrowserTabID?) {
        guard BrowserView.commitTabOverviewScrollPosition(
            position,
            store: store,
            adapter: scrollPosition,
        ) else {
            return
        }

        committedPositionCount += 1
    }

    private func handleOverviewExit(
        _ position: BrowserTabID?,
        _ action: BrowserTabOverviewExitAction,
    ) {
        commitScrollPosition(position)
        if case let .closeTab(tabID) = action {
            store.send(.closeTab(tabID))
        }

        BrowserView.synchronizeTabOverviewScrollPosition(store: store, adapter: scrollPosition)
    }

}

/// Exposes the production scroll-state snapshot to UI-test synchronization.
@MainActor
private struct BrowserTabOverviewRestoreSettlementLabel: View {
    @ObservedObject
    var observation: BrowserTabOverviewScrollObservation

    var body: some View {
        Text(observation.state.isSettled ? "settled" : "scrolling")
            .accessibilityIdentifier("browser.tab-overview.programmatic-restore-state")
    }
}
