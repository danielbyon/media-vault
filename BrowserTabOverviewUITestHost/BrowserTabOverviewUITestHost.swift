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
    @AccessibilityFocusState
    private var accessibilityFocusedTabID: BrowserTabID?

    init() {
        let tabs = (0 ..< 40).map { _ in BrowserTab.startPage(id: BrowserTabID()) }
        let initialAnchor = tabs[0].id
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
        _scrollPosition = StateObject(
            wrappedValue: BrowserTabOverviewScrollPosition(persistedPosition: initialAnchor),
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            Text("\(savedAnchorDescription)|commits-\(committedPositionCount)")
                .font(.caption)
                .accessibilityIdentifier("browser.tab-overview.saved-anchor")

            BrowserTabOverviewView(
                store: store,
                transitionRegistry: transitionRegistry,
                previewAspectRatio: 4.0 / 3.0,
                reduceMotionEnabled: true,
                accessibilityFocusedTabID: $accessibilityFocusedTabID,
                onCommitScrollPosition: commitScrollPosition,
                onExitOverview: { _, _ in },
                scrollPosition: scrollPosition,
            )
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

}
