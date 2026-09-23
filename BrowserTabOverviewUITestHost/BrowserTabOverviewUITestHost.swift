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
    @State
    private var committedPositionCount = 0
    @State
    private var programmaticRestoreSettled: Bool
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
        _programmaticRestoreSettled = State(initialValue: !startsAtLastTab)
    }

    var body: some View {
        VStack(spacing: 0) {
            Text("\(savedAnchorDescription)|commits-\(committedPositionCount)")
                .font(.caption)
                .accessibilityIdentifier("browser.tab-overview.saved-anchor")

            Text(programmaticRestoreSettled ? "settled" : "scrolling")
                .accessibilityIdentifier("browser.tab-overview.programmatic-restore-state")

            BrowserTabOverviewView(
                store: store,
                transitionRegistry: transitionRegistry,
                previewAspectRatio: 4.0 / 3.0,
                reduceMotionEnabled: true,
                accessibilityFocusedTabID: $accessibilityFocusedTabID,
                onCommitScrollPosition: commitScrollPosition,
                onExitOverview: handleOverviewExit,
                scrollPosition: scrollPosition,
            )
        }
        .onChange(of: store.state.tabOverviewScrollPosition) { _, _ in
            BrowserView.synchronizeTabOverviewScrollPosition(store: store, adapter: scrollPosition)
        }
        .onChange(of: scrollPosition.scrollPhase) { _, phase in
            updateProgrammaticRestoreSettlement(for: phase)
        }
        .onChange(of: scrollPosition.isPersistedTargetFullyVisible) { _, _ in
            updateProgrammaticRestoreSettlement(for: scrollPosition.scrollPhase)
        }
        .onChange(of: scrollPosition.persistedPosition) { _, _ in
            updateProgrammaticRestoreSettlement(for: scrollPosition.scrollPhase)
        }
        .onChange(of: store.state.tabs.map(\.id)) { _, _ in
            if ProcessInfo.processInfo.arguments.contains("--reconcile-close-last-tab") {
                programmaticRestoreSettled = false
            }
            BrowserView.synchronizeTabOverviewScrollPosition(store: store, adapter: scrollPosition)
            updateProgrammaticRestoreSettlement(for: scrollPosition.scrollPhase)
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

    private func updateProgrammaticRestoreSettlement(for phase: ScrollPhase) {
        guard !programmaticRestoreSettled else {
            return
        }
        guard phase == .idle, scrollPosition.isPersistedTargetFullyVisible else {
            return
        }

        // Some programmatic restorations remain idle; the production target-visibility callback
        // confirms that the reducer-owned card actually reached the viewport.
        programmaticRestoreSettled = true
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
        guard case let .closeTab(tabID) = action else {
            return
        }

        store.send(.closeTab(tabID))
        BrowserView.synchronizeTabOverviewScrollPosition(store: store, adapter: scrollPosition)
    }

}
