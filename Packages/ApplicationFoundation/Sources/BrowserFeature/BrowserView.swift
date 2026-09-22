//
//  BrowserView.swift
//  MediaVault
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import ComposableArchitecture
import Foundation
import SwiftUI
import UIKit

/// Authenticated native browser presentation.
@MainActor
@preconcurrency
public struct BrowserView: View {
    private let store: StoreOf<BrowserFeature>
    private let reduceMotionOverride: Bool?
    @Environment(\.horizontalSizeClass)
    private var horizontalSizeClass
    @Environment(\.accessibilityReduceMotion)
    private var reduceMotion
    @Environment(\.scenePhase)
    private var scenePhase
    @FocusState
    private var focusedField: BrowserFocusedField?
    @AccessibilityFocusState
    private var accessibilityFocusedTabID: BrowserTabID?
    @State
    private var tabTransitionState = BrowserTabTransitionViewState()
    @State
    private var nativePreviewCaptureController = BrowserNativePreviewCaptureController()
    @State
    private var webKitReadinessCoordinator = BrowserWebKitReadinessCoordinator()
    @StateObject
    private var tabTransitionUIKitCoordinator = BrowserTabTransitionUIKitCoordinator()
    @State
    private var chromeLayoutHeight: CGFloat = 0
    @State
    private var latestLayoutProbeGeometry: BrowserContentViewportGeometry?
    @State
    private var chromeOpacity: Double = 1

    /// Creates browser UI bound to deterministic feature state.
    public init(store: StoreOf<BrowserFeature>) {
        self.init(
            store: store,
            reduceMotionOverride: nil,
            transitionCoordinator: nil,
        )
    }

    /// Creates a deterministic presentation for accessibility snapshot coverage.
    init(store: StoreOf<BrowserFeature>, reduceMotionOverride: Bool) {
        self.init(
            store: store,
            reduceMotionOverride: reduceMotionOverride,
            transitionCoordinator: nil,
        )
    }

    /// Creates a presentation with a caller-owned coordinator for transition-boundary tests.
    init(
        store: StoreOf<BrowserFeature>,
        transitionCoordinator: BrowserTabTransitionUIKitCoordinator,
        readinessCoordinator: BrowserWebKitReadinessCoordinator? = nil,
    ) {
        self.init(
            store: store,
            reduceMotionOverride: nil,
            transitionCoordinator: transitionCoordinator,
            readinessCoordinator: readinessCoordinator,
        )
    }

    private init(
        store: StoreOf<BrowserFeature>,
        reduceMotionOverride: Bool?,
        transitionCoordinator: BrowserTabTransitionUIKitCoordinator?,
        readinessCoordinator: BrowserWebKitReadinessCoordinator? = nil,
    ) {
        self.store = store
        self.reduceMotionOverride = reduceMotionOverride
        _tabTransitionUIKitCoordinator = StateObject(wrappedValue: transitionCoordinator ?? .init())
        _webKitReadinessCoordinator = State(initialValue: readinessCoordinator ?? .init())
        _chromeOpacity = State(initialValue: store.presentation == .browsing ? 1 : 0)
        _tabTransitionState = State(initialValue: .init(overviewVisualMounted: store.presentation == .tabOverview))
    }

    /// Renders the selected browser endpoint or the app-owned tab overview.
    public var body: some View {
        ZStack {
            selectedContentWithChrome

            if tabTransitionState.overviewVisualMounted || store.presentation == .tabOverview {
                tabOverviewVisual
            }

            BrowserTabTransitionOverlay(coordinator: tabTransitionUIKitCoordinator)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .zIndex(20)
            chromeTransitionLayer
        }
        .modifier(BrowserPresentationKeyboardDismissalModifier(
            isEnabled: store.presentation == .browsing,
            focus: $focusedField,
        ))
        .background {
            BrowserContentViewportProbe(
                chromeHeight: chromeReservedHeight,
                chromeAtTop: horizontalSizeClass == .regular,
            )
        }
        .background(Color(uiColor: .systemBackground))
        .onChange(of: store.focusedField, initial: true) { _, value in
            focusedField = value == BrowserFocusedField.none ? nil : value
        }
        .onChange(of: focusedField) { _, value in
            guard let value else {
                guard store.focusedField != .none else {
                    return
                }

                store.send(.omniboxFocusLost)
                return
            }
            guard store.focusedField != value else {
                return
            }

            store.send(.omniboxFocused)
        }
        .onChange(of: store.presentation, initial: true) { _, value in
            if value == .tabOverview {
                tabTransitionState.overviewVisualMounted = true
            } else if !tabTransitionUIKitCoordinator.isActive
                || tabTransitionUIKitCoordinator.direction != .toBrowsing {
                tabTransitionState.overviewVisualMounted = false
            }
            if tabTransitionUIKitCoordinator.isActive,
               let tabTransitionDirection = tabTransitionUIKitCoordinator.direction {
                let expectedPresentation: BrowserPresentation = tabTransitionDirection == .toOverview
                    ? .tabOverview
                    : .browsing
                if value != expectedPresentation {
                    cancelTabTransition()
                }
            }
            withAnimation(.easeOut(duration: 0.15)) {
                chromeOpacity = value == .browsing ? 1 : 0
            }
            accessibilityFocusedTabID = value == .tabOverview
                ? (store.tabOverviewFocusID ?? store.selectedTabID)
                : nil
        }
        .onChange(of: store.selectedTabID) { _, value in
            if store.presentation == .tabOverview {
                accessibilityFocusedTabID = store.tabOverviewFocusID ?? value
            }
        }
        .onChange(of: store.tabOverviewFocusID) { _, value in
            if store.presentation == .tabOverview {
                accessibilityFocusedTabID = value ?? store.selectedTabID
            }
        }
        .onChange(of: store.tabs.map(\.id)) { _, _ in
            if let parkedCardID = tabTransitionUIKitCoordinator.parkedSurface?.cardID,
               !store.tabs.contains(where: { $0.id == parkedCardID }) {
                tabTransitionUIKitCoordinator.clearParkedSurface(for: parkedCardID)
            }
            if store.presentation == .tabOverview {
                accessibilityFocusedTabID = store.tabOverviewFocusID ?? store.selectedTabID
            }
            if let tabTransitionTabID = tabTransitionUIKitCoordinator.tabID,
               !store.tabs.contains(where: { $0.id == tabTransitionTabID }) {
                cancelTabTransition()
            }
        }
        .onChange(of: accessibilityFocusedTabID) { _, value in
            guard store.presentation == .tabOverview,
                  value != store.tabOverviewFocusID
            else {
                return
            }

            store.send(.tabOverviewFocusChanged(value))
        }
        .onChange(of: scenePhase) { _, value in
            if value != .active {
                cancelTabTransition()
            }
        }
        .onPreferenceChange(BrowserContentViewportPreferenceKey.self) { value in
            latestLayoutProbeGeometry = value
        }
        .onPreferenceChange(BrowserChromeHeightPreferenceKey.self) { height in
            chromeLayoutHeight = height
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)) { _ in
            cancelTabTransition()
            store.send(.previewCacheEvicted)
        }
        .task { await store.send(.task).finish() }
        .onDisappear { cancelTabTransition() }
        .sheet(isPresented: libraryPresentationBinding) { BrowserLibraryView(store: store) }
        .sheet(isPresented: bookmarkEditorPresentationBinding) {
            BrowserBookmarkEditorView(store: store)
        }
        .sheet(isPresented: sharePresentationBinding) {
            if let url = store.shareURL {
                BrowserShareSheet(url: url)
            }
        }
        .safeAreaInset(edge: .top) {
            if store.findDraft != nil {
                BrowserFindBar(store: store)
            }
        }
        .confirmationDialog(destructiveTitle, isPresented: Binding(
            get: { store.destructiveConfirmation != nil },
            set: { isPresented in
                if !isPresented {
                    store.send(.destructiveConfirmationDismissed)
                }
            },
        ), titleVisibility: .visible) {
            Button("Confirm", role: .destructive) { store.send(.destructiveActionConfirmed) }
        }
        .confirmationDialog(backForwardTitle, isPresented: Binding(
            get: { store.backForwardList != nil },
            set: {
                if !$0 {
                    store.send(.backForwardListDismissed)
                }
            },
        ), titleVisibility: .visible) {
            ForEach(store.backForwardList?.entries ?? []) { entry in
                Button(entry.title ?? entry.url.host ?? entry.url.absoluteString) {
                    store.send(.backForwardEntrySelected(entry.token))
                }
            }
        }
        .confirmationDialog(newTabDispositionTitle, isPresented: Binding(
            get: { store.pendingNewTab != nil },
            set: { isPresented in
                if !isPresented {
                    store.send(.newTabDispositionDismissed)
                }
            },
        ), titleVisibility: .visible) {
            Button("In Foreground") {
                store.send(.newTabDispositionSelected(.foreground))
            }
            Button("In Background") {
                store.send(.newTabDispositionSelected(.background))
            }
            Button("Cancel", role: .cancel) {
                store.send(.newTabDispositionDismissed)
            }
        }
    }
}

extension BrowserView {
    private var libraryPresentationBinding: Binding<Bool> {
        Binding(
            get: { store.library != nil },
            set: { isPresented in
                if !isPresented {
                    store.send(.libraryDismissed)
                }
            },
        )
    }

    private var bookmarkEditorPresentationBinding: Binding<Bool> {
        Binding(
            get: { store.bookmarkEditor != nil },
            set: { isPresented in
                if !isPresented {
                    store.send(.bookmarkEditorCancelled)
                }
            },
        )
    }

    private var sharePresentationBinding: Binding<Bool> {
        Binding(
            get: { store.shareURL != nil },
            set: { isPresented in
                if !isPresented {
                    store.send(.shareDismissed)
                }
            },
        )
    }

    private var reduceMotionEnabled: Bool {
        reduceMotionOverride ?? reduceMotion
    }

    private var selectedContentWithChrome: some View {
        Group {
            if horizontalSizeClass == .regular {
                selectedContentPresentation
                    .safeAreaBar(edge: .top, spacing: 0) { chromeLayoutPlaceholder }
            } else {
                selectedContentPresentation
                    .safeAreaBar(edge: .bottom, spacing: 0) { chromeLayoutPlaceholder }
            }
        }
        .zIndex(
            tabTransitionUIKitCoordinator.ownsVisibleSurface
                && tabTransitionUIKitCoordinator.direction == .toOverview ? 2 : 0,
        )
        .allowsHitTesting(store.presentation == .browsing && !tabTransitionUIKitCoordinator.isActive)
        .accessibilityHidden(
            store.presentation != .browsing || tabTransitionUIKitCoordinator.isActive,
        )
    }

    private var chromeLayoutPlaceholder: some View {
        Color.clear
            .frame(height: chromeReservedHeight)
            .accessibilityHidden(true)
    }

    private var chromeTransitionLayer: some View {
        Color.clear
            .safeAreaBar(
                edge: horizontalSizeClass == .regular ? .top : .bottom,
                spacing: 0,
            ) {
                BrowserChromeView(
                    store: store,
                    focusedField: $focusedField,
                    isTransitionActive: tabTransitionUIKitCoordinator.isActive,
                    onRequestTabOverview: requestTabOverview,
                )
                .background {
                    GeometryReader { proxy in
                        Color.clear.preference(
                            key: BrowserChromeHeightPreferenceKey.self,
                            value: proxy.size.height,
                        )
                    }
                }
                .opacity(chromeOpacity)
                .allowsHitTesting(
                    store.presentation == .browsing && !tabTransitionUIKitCoordinator.isActive,
                )
                .accessibilityHidden(
                    store.presentation != .browsing || tabTransitionUIKitCoordinator.isActive,
                )
            }
    }

    private var chromeReservedHeight: CGFloat {
        guard chromeLayoutHeight > 0 else {
            if horizontalSizeClass == .regular || store.selectedTab?.isStartPage == true {
                return 52
            }
            return 104
        }

        return chromeLayoutHeight
    }

    private var selectedContentPresentation: some View {
        selectedContent
    }

    @ViewBuilder
    private var selectedContent: some View {
        if let tab = store.selectedTab {
            switch tab.content {
            case .startPage:
                nativeSurface(BrowserStartPageView(store: store, focusedField: $focusedField))
            case .web:
                BrowserWebView(
                    tabID: tab.id,
                    onRefresh: { store.send(.pullToRefresh) },
                    transitionRegistry: tabTransitionUIKitCoordinator.surfaceRegistry,
                    readinessContext: webKitReadinessContext(for: tab),
                    readinessCoordinator: webKitReadinessCoordinator,
                )
                .accessibilityLabel("Web page")
            case let .error(error):
                nativeSurface(errorView(error, terminated: false))
            case .terminated:
                nativeSurface(errorView(
                    .pageCouldNotLoad(tab.metadata.committedURL ?? URL(filePath: "/terminated-web-content")),
                    terminated: true,
                ))
            }
        }
    }

    private func nativeSurface(_ content: some View) -> some View {
        BrowserNativePreviewCapture(
            content: content,
            controller: nativePreviewCaptureController,
            transitionRegistry: tabTransitionUIKitCoordinator.surfaceRegistry,
            transitionRole: .content(store.selectedTabID),
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var tabPreviewAspectRatio: CGFloat {
        tabTransitionState.latchedGeometry?.aspectRatio
            ?? latestLayoutProbeGeometry?.aspectRatio
            ?? (4.0 / 3.0)
    }

    private var tabOverviewVisual: some View {
        ZStack {
            Color(uiColor: .systemBackground)
                .ignoresSafeArea()
            BrowserTabOverviewView(
                store: store,
                transitionRegistry: tabTransitionUIKitCoordinator.surfaceRegistry,
                previewAspectRatio: tabPreviewAspectRatio,
                reduceMotionEnabled: reduceMotionEnabled,
                accessibilityFocusedTabID: $accessibilityFocusedTabID,
                onNewTab: {
                    cancelTabTransition()
                    store.send(.newTabTapped)
                },
                onSelectTab: selectTabCard,
            )
        }
        .zIndex(1)
        .allowsHitTesting(
            store.presentation == .tabOverview && !tabTransitionUIKitCoordinator.isActive,
        )
        .accessibilityHidden(
            store.presentation != .tabOverview || tabTransitionUIKitCoordinator.isActive,
        )
    }

    /// Supplies lifecycle state for the current reducer transition.
    private func webKitReadinessContext(for tab: BrowserTab) -> BrowserWebKitReadinessContext {
        let navigationOperationID = store.previewState.operation(for: tab.id)
        return webKitReadinessCoordinator.context(
            navigationOperationID: navigationOperationID,
        )
    }

    private func selectTabCard(_ tab: BrowserTab) {
        performTabTransition(
            direction: .toBrowsing,
            tabID: tab.id,
        ) {
            store.send(.tabCardSelected(tab.id))
        }
    }

    private func requestTabOverview() {
        guard let tab = store.selectedTab,
              store.presentation == .browsing
        else {
            return
        }

        let nativeCapture: Data? =
            if case .web = tab.content {
                nil
            } else {
                nativePreviewCaptureController.capture()
            }
        performTabTransition(
            direction: .toOverview,
            tabID: tab.id,
        ) {
            store.send(.showTabOverviewTapped)
            if let nativeCapture {
                let revision = store.previewState.revision(for: tab.id)
                store.send(.nativePreviewCaptured(
                    tabID: tab.id,
                    revision: revision,
                    pngData: nativeCapture,
                ))
            }
        }
    }

    private func performTabTransition(
        direction: BrowserTabTransitionDirection,
        tabID: BrowserTabID,
        action: @escaping () -> Void,
    ) {
        BrowserTabTransitionPresentationCoordinator.begin(
            coordinator: tabTransitionUIKitCoordinator,
            selectedTabID: store.selectedTabID,
            bindings: tabTransitionPresentationBindings,
            direction: direction,
            tabID: tabID,
            reduceMotion: reduceMotionEnabled,
            onPresentationChange: action,
            onPresentationUnavailable: {
                switch direction {
                case .toBrowsing:
                    store.send(.showTabOverviewTapped)
                case .toOverview:
                    store.send(.tabCardSelected(tabID))
                }
            },
        )
    }

    private func cancelTabTransition() {
        webKitReadinessCoordinator.invalidate()
        BrowserTabTransitionPresentationCoordinator.cancel(
            coordinator: tabTransitionUIKitCoordinator,
            isOverviewPresented: store.presentation == .tabOverview,
            bindings: tabTransitionPresentationBindings,
        )
    }

    private var tabTransitionPresentationBindings: BrowserTabTransitionPresentationBindings {
        .init(state: $tabTransitionState)
    }

    private func errorView(_ error: BrowserNavigationError, terminated: Bool) -> some View {
        BrowserErrorSurface(
            title: terminated ? "Page Needs Reload" : errorTitle(error),
            description: terminated
                ? "The web content process ended. Reload when you are ready."
                : "The page could not be reached.",
            actionTitle: terminated ? "Reload" : "Try Again",
            allowsRefresh: !terminated,
            onRefresh: { store.send(.pullToRefresh) },
            onRetry: { store.send(.retryTapped) },
        )
    }

    private func errorTitle(_ error: BrowserNavigationError) -> String {
        switch error { case .noInternet:
            "No Internet Connection"
        case .serverNotFound:
            "Server Not Found"
        case .connectionFailed:
            "Connection Failed"
        case .pageCouldNotLoad:
            "Page Couldn’t Load" }
    }

    private var destructiveTitle: String {
        switch store.destructiveConfirmation {
        case .some(.clearHistory):
            "Clear all browser history?"
        case let .some(.deleteAllBookmarks(count)):
            "Delete all \(count.map(String.init) ?? "") bookmarks?"
        case let .some(.closeAllTabs(count)):
            "Close all \(count) tabs?"
        case let .some(.closeOtherTabs(_, count)):
            "Close \(count) other tabs?"
        case nil:
            "Confirm destructive action"
        }
    }

    private var backForwardTitle: String {
        store.backForwardList?.direction == .back ? "Back History" : "Forward History"
    }

    private var newTabDispositionTitle: String {
        "Open Link in New Tab"
    }
}

extension BrowserTabPreviewPlaceholder {
    var systemImage: String {
        switch self {
        case .startPage:
            "sparkles"
        case .web:
            "globe"
        case .error:
            "wifi.exclamationmark"
        case .terminated:
            "xmark.octagon"
        }
    }

    var label: String {
        switch self {
        case .startPage:
            "Start Page"
        case .web:
            "Web Page"
        case .error:
            "Page Error"
        case .terminated:
            "Page Ended"
        }
    }

    var tint: Color {
        switch self {
        case .startPage:
            .accentColor
        case .web:
            .secondary
        case .error:
            .orange
        case .terminated:
            .purple
        }
    }
}

/// Bridges the native refresh interaction on the app-owned error surface to a Sendable-free view action.
@MainActor
final class BrowserErrorRefreshBridge {
    private let onRefresh: () -> Void

    init(onRefresh: @escaping () -> Void) {
        self.onRefresh = onRefresh
    }

    func refresh() {
        onRefresh()
    }
}

/// Gives recoverable browser errors a real pull-to-refresh interaction while keeping retry state in the reducer.
@MainActor
private struct BrowserErrorSurface: View {
    private let title: String
    private let description: String
    private let actionTitle: String
    private let allowsRefresh: Bool
    private let bridge: BrowserErrorRefreshBridge
    private let onRetry: () -> Void

    init(
        title: String,
        description: String,
        actionTitle: String,
        allowsRefresh: Bool,
        onRefresh: @escaping () -> Void,
        onRetry: @escaping () -> Void,
    ) {
        self.title = title
        self.description = description
        self.actionTitle = actionTitle
        self.allowsRefresh = allowsRefresh
        bridge = BrowserErrorRefreshBridge(onRefresh: onRefresh)
        self.onRetry = onRetry
    }

    var body: some View {
        if allowsRefresh {
            content.refreshable {
                bridge.refresh()
            }
        } else {
            content
        }
    }

    private var content: some View {
        ScrollView {
            ContentUnavailableView {
                Label(title, systemImage: "wifi.exclamationmark")
            } description: {
                Text(description)
            } actions: {
                Button(actionTitle, action: onRetry)
                    .buttonStyle(.borderedProminent)
            }
            .frame(maxWidth: .infinity)
            .frame(minHeight: 320)
        }
    }
}

/// Presents the system share sheet for a link selected from WebKit's public context menu.
@MainActor
@preconcurrency
private struct BrowserShareSheet: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context _: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }

    func updateUIViewController(_: UIActivityViewController, context _: Context) {}
}
