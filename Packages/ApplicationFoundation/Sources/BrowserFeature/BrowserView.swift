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

/// Transient view state for the card currently receiving a direct-manipulation gesture.
private struct BrowserTabCardDrag: Equatable {
    let tabID: BrowserTabID
    let axis: BrowserTabSwipe.Axis
    let horizontalTranslation: CGFloat
}

private struct BrowserChromeHeightPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct BrowserContentViewportPreferenceKey: PreferenceKey {
    static let defaultValue = BrowserContentViewportGeometry(size: CGSize(width: 390, height: 844))

    static func reduce(
        value: inout BrowserContentViewportGeometry,
        nextValue: () -> BrowserContentViewportGeometry,
    ) {
        value = nextValue()
    }
}

@MainActor
@preconcurrency
private struct BrowserPresentationKeyboardDismissalModifier: ViewModifier {
    let isEnabled: Bool
    let focus: FocusState<BrowserFocusedField?>.Binding

    func body(content: Content) -> some View {
        if isEnabled {
            content
                .scrollDismissesKeyboard(.interactively)
                .background {
                    BrowserPresentationTapObserver(focus: focus)
                }
        } else {
            content
        }
    }
}

/// Installs one non-cancelling outside-tap observer on the hosting view for the whole browsing
/// presentation. SwiftUI's generic keyboard-dismissal modifier mounts its UIKit observer beside a
/// complex safe-area presentation, so this Browser-owned observer deliberately resolves the
/// hosting view as its gesture owner and covers both page content and chrome.
@MainActor
@preconcurrency
private struct BrowserPresentationTapObserver: UIViewRepresentable {
    let focus: FocusState<BrowserFocusedField?>.Binding

    func makeCoordinator() -> BrowserPresentationTapCoordinator {
        BrowserPresentationTapCoordinator(
            isFocused: { focus.wrappedValue != nil },
            dismiss: { focus.wrappedValue = nil },
        )
    }

    func makeUIView(context: Context) -> BrowserPresentationTapAnchorView {
        let view = BrowserPresentationTapAnchorView()
        view.onHierarchyChange = { [weak coordinator = context.coordinator, weak view] in
            coordinator?.mount(on: view.flatMap(Self.hostingView(containing:)))
        }
        return view
    }

    func updateUIView(_ uiView: BrowserPresentationTapAnchorView, context: Context) {
        context.coordinator.mount(on: Self.hostingView(containing: uiView))
    }

    static func dismantleUIView(
        _: BrowserPresentationTapAnchorView,
        coordinator: BrowserPresentationTapCoordinator,
    ) {
        coordinator.unmount()
    }

    private static func hostingView(containing view: UIView) -> UIView? {
        if let rootView = view.window?.rootViewController?.view {
            return rootView
        }

        var rootView = view
        while let superview = rootView.superview {
            rootView = superview
        }
        return rootView === view ? nil : rootView
    }
}

@MainActor
@preconcurrency
private final class BrowserPresentationTapAnchorView: UIView {
    var onHierarchyChange: (() -> Void)?

    override func didMoveToSuperview() {
        super.didMoveToSuperview()
        onHierarchyChange?()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        onHierarchyChange?()
    }
}

/// Coordinates the single Browser-wide tap recognizer while leaving the tapped control's own
/// interaction intact.
@MainActor
@preconcurrency
private final class BrowserPresentationTapCoordinator: NSObject, UIGestureRecognizerDelegate {
    private let isFocused: () -> Bool
    private let dismiss: () -> Void
    private weak var hostView: UIView?
    private var tapRecognizer: UITapGestureRecognizer?

    init(isFocused: @escaping () -> Bool, dismiss: @escaping () -> Void) {
        self.isFocused = isFocused
        self.dismiss = dismiss
    }

    func mount(on hostView: UIView?) {
        guard let hostView else {
            unmount()
            return
        }
        guard self.hostView !== hostView else {
            return
        }

        unmount()
        let recognizer = UITapGestureRecognizer(target: self, action: #selector(handleTapGesture(_:)))
        recognizer.cancelsTouchesInView = false
        recognizer.delaysTouchesBegan = false
        recognizer.delaysTouchesEnded = false
        recognizer.delegate = self
        hostView.addGestureRecognizer(recognizer)
        self.hostView = hostView
        tapRecognizer = recognizer
    }

    func unmount() {
        if let tapRecognizer, let hostView {
            hostView.removeGestureRecognizer(tapRecognizer)
        }
        tapRecognizer = nil
        hostView = nil
    }

    @objc
    private func handleTapGesture(_ recognizer: UITapGestureRecognizer) {
        guard recognizer.state == .ended, isFocused() else {
            return
        }

        dismiss()
    }

    func gestureRecognizer(_: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        guard let hostView else {
            return false
        }

        var current = touch.view
        while let view = current {
            if view is UITextField || view is UITextView || view is UISearchBar {
                return false
            }
            if view === hostView {
                return true
            }
            current = view.superview
        }
        return false
    }

    func gestureRecognizer(
        _: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith _: UIGestureRecognizer,
    ) -> Bool {
        true
    }
}

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
    private var tabCardDrag: BrowserTabCardDrag?
    @State
    private var isTabTransitionActive = false
    @State
    private var tabTransitionToken = 0
    @State
    private var tabTransitionTabID: BrowserTabID?
    @State
    private var tabTransitionDirection: BrowserTabTransitionDirection?
    @State
    private var nativePreviewCaptureController = BrowserNativePreviewCaptureController()
    @State
    private var tabTransitionUIKitCoordinator = BrowserTabTransitionUIKitCoordinator()
    @State
    private var chromeLayoutHeight: CGFloat = 0
    @State
    private var contentViewportGeometry = BrowserContentViewportPreferenceKey.defaultValue
    @State
    private var chromeOpacity: Double = 1

    /// Creates browser UI bound to deterministic feature state.
    public init(store: StoreOf<BrowserFeature>) {
        self.store = store
        reduceMotionOverride = nil
        _chromeOpacity = State(initialValue: store.presentation == .browsing ? 1 : 0)
    }

    /// Creates a deterministic presentation for accessibility snapshot coverage.
    init(store: StoreOf<BrowserFeature>, reduceMotionOverride: Bool) {
        self.store = store
        self.reduceMotionOverride = reduceMotionOverride
        _chromeOpacity = State(initialValue: store.presentation == .browsing ? 1 : 0)
    }

    /// Renders the selected browser endpoint or the app-owned tab overview.
    public var body: some View {
        ZStack {
            if store.presentation == .tabOverview {
                tabOverview
            } else {
                selectedContentWithChrome
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
            GeometryReader { proxy in
                Color.clear.preference(
                    key: BrowserContentViewportPreferenceKey.self,
                    value: BrowserContentViewportGeometry.measure(
                        containerSize: proxy.size,
                        safeAreaTop: proxy.safeAreaInsets.top,
                        safeAreaLeading: proxy.safeAreaInsets.leading,
                        safeAreaBottom: proxy.safeAreaInsets.bottom,
                        safeAreaTrailing: proxy.safeAreaInsets.trailing,
                        chromeHeight: chromeReservedHeight,
                        chromeAtTop: horizontalSizeClass == .regular,
                    ),
                )
            }
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
            if value != .tabOverview {
                tabCardDrag = nil
            }
            if isTabTransitionActive, let tabTransitionDirection {
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
            if store.presentation == .tabOverview {
                accessibilityFocusedTabID = store.tabOverviewFocusID ?? store.selectedTabID
            }
            if let tabTransitionTabID,
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
            contentViewportGeometry = value
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
                findBar
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
                    .opacity(liveContentOpacity)
                    .safeAreaBar(edge: .top, spacing: 0) { chromeLayoutPlaceholder }
            } else {
                selectedContentPresentation
                    .opacity(liveContentOpacity)
                    .safeAreaBar(edge: .bottom, spacing: 0) { chromeLayoutPlaceholder }
            }
        }
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
                chrome
                    .background {
                        GeometryReader { proxy in
                            Color.clear.preference(
                                key: BrowserChromeHeightPreferenceKey.self,
                                value: proxy.size.height,
                            )
                        }
                    }
                    .opacity(chromeOpacity)
                    .allowsHitTesting(store.presentation == .browsing && !isTabTransitionActive)
                    .accessibilityHidden(store.presentation != .browsing || isTabTransitionActive)
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
                nativeSurface(startPage)
            case .web:
                BrowserWebView(
                    tabID: tab.id,
                    onRefresh: { store.send(.pullToRefresh) },
                    transitionRegistry: tabTransitionUIKitCoordinator.surfaceRegistry,
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
        max(
            0.1,
            tabTransitionUIKitCoordinator.surfaceRegistry.aspectRatio(
                for: .content(store.selectedTabID),
            ) ?? contentViewportGeometry.aspectRatio,
        )
    }

    private var liveContentOpacity: Double {
        tabTransitionDirection == .toBrowsing && isTabTransitionActive ? 0 : 1
    }

    private var startPage: some View {
        ScrollView {
            VStack(spacing: 28) {
                Text("Start Page").font(.largeTitle.bold()).frame(maxWidth: .infinity, alignment: .leading)
                omnibox(large: true)
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Text("Bookmarks").font(.title2.bold())
                        Spacer()
                        Button("All Bookmarks") { store.send(.libraryPresented(.bookmarks)) }
                    }
                    if store.bookmarks.isEmpty {
                        ContentUnavailableView("No Bookmarks", systemImage: "bookmark")
                            .frame(maxWidth: .infinity)
                    } else {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 132), spacing: 12)], spacing: 12) {
                            ForEach(BrowserSuggestions.startPageBookmarks(store.bookmarks)) { bookmark in
                                Button { store.send(.navigate(bookmark.url)) } label: { bookmarkTile(bookmark) }
                                    .buttonStyle(.plain)
                                    .contextMenu {
                                        Button("Open") { store.send(.navigate(bookmark.url)) }
                                        Button("Open in New Tab") { store.send(.openInNewTab(
                                            bookmark.url,
                                            openerID: store.selectedTabID,
                                        )) }
                                        Button("Edit Bookmark") { store.send(.editBookmarkTapped(bookmark.id)) }
                                        Button("Delete Bookmark", role: .destructive) {
                                            store.send(.deleteBookmark(bookmark.id))
                                        }
                                    }
                            }
                        }
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: 900)
            .frame(maxWidth: .infinity)
        }
    }

    private func bookmarkTile(_ bookmark: BrowserBookmark) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Group {
                if let data = bookmark.faviconData,
                   let image = UIImage(data: data) {
                    Image(uiImage: image).resizable().accessibilityHidden(true)
                } else {
                    Text(String((bookmark.url.host ?? bookmark.title).prefix(1)).uppercased())
                        .font(.title.bold())
                        .foregroundStyle(.white)
                }
            }
            .frame(width: 44, height: 44)
            .background(Color.accentColor.gradient, in: RoundedRectangle(cornerRadius: 11))
            Text(bookmark.title).font(.headline).lineLimit(1)
            Text(bookmark.url.host ?? bookmark.url.absoluteString)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, minHeight: 118, alignment: .leading)
        .padding(14)
        .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 18))
    }

    private var chrome: some View {
        VStack(spacing: 0) {
            if let tab = store.selectedTab,
               tab.metadata.isLoading {
                ProgressView(value: tab.metadata.estimatedProgress)
                    .progressViewStyle(.linear)
            }
            if horizontalSizeClass == .compact,
               store.selectedTab?.isStartPage != true {
                ViewThatFits(in: .horizontal) {
                    chromeRow(includesOmnibox: true)
                    stackedCompactChrome
                }
            } else {
                chromeRow(includesOmnibox: true)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var stackedCompactChrome: some View {
        VStack(spacing: 0) {
            omnibox(large: false)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 8)
                .padding(.top, 4)
            chromeRow(includesOmnibox: false)
        }
    }

    private func chromeRow(includesOmnibox: Bool) -> some View {
        HStack(spacing: 6) {
            Button { store.send(.backTapped) } label: {
                Image(systemName: "chevron.backward")
                    .accessibilityHidden(true)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Back")
            .disabled(store.selectedTab?.metadata.canGoBack != true)
            .onLongPressGesture { store.send(.backHistoryRequested) }

            Button { store.send(.forwardTapped) } label: {
                Image(systemName: "chevron.forward")
                    .accessibilityHidden(true)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Forward")
            .disabled(store.selectedTab?.metadata.canGoForward != true)
            .onLongPressGesture { store.send(.forwardHistoryRequested) }

            if includesOmnibox,
               store.selectedTab?.isStartPage != true {
                omnibox(large: false)
                    .frame(minWidth: 120, maxWidth: .infinity)
                    .layoutPriority(1)
            }

            Button { store.send(.reloadOrStopTapped) } label: {
                Image(systemName: store.selectedTab?.metadata.isLoading == true ? "xmark" : "arrow.clockwise")
                    .accessibilityHidden(true)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel(store.selectedTab?.metadata.isLoading == true ? "Stop" : "Reload")
            .disabled(store.selectedTab?.isStartPage == true)

            Button { requestTabOverview() } label: {
                Text(store.tabCountLabel)
                    .font(.caption.bold())
                    .frame(width: 28, height: 28)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke())
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Show Tabs, \(store.tabCountLabel) tabs")

            Menu { overflowMenu } label: {
                Image(systemName: "ellipsis.circle")
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Browser Menu")
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity)
    }

    private func omnibox(large: Bool) -> some View {
        VStack(spacing: 0) {
            omniboxField(large: large)
                .padding(large ? 16 : 10)
                .background(.quaternary.opacity(0.8), in: RoundedRectangle(cornerRadius: large
                        ? 18
                        : 12))
            if store.focusedField != .none, !store.suggestions.isEmpty {
                suggestionRows(limit: large ? 6 : 4)
            }
        }
    }

    private func omniboxField(large: Bool) -> some View {
        HStack(spacing: 6) {
            if !large, let url = store.selectedTab?.metadata.committedURL {
                Image(systemName: url.scheme?.lowercased() == "https"
                    ? "lock.fill"
                    : "exclamationmark.triangle.fill")
                    .foregroundStyle(url.scheme?.lowercased() == "https" ? Color.secondary : Color.orange)
                    .accessibilityLabel(url.scheme?.lowercased() == "https" ? "Secure connection" : "Not Secure")
            }
            TextField("Search or enter website", text: Binding(
                get: {
                    if large || focusedField == .chrome || store.focusedField == .chrome {
                        return store.omniboxDraft
                    }
                    return store.selectedTab?.metadata.committedURL?.host ?? store.omniboxDraft
                },
                set: { store.send(.omniboxChanged($0)) },
            ))
            .textInputAutocapitalization(.never)
            .keyboardType(.webSearch)
            .submitLabel(.go)
            .focused($focusedField, equals: large ? .startPage : .chrome)
            .onSubmit { store.send(.omniboxSubmitted) }
        }
    }

    private func suggestionRows(limit: Int) -> some View {
        ForEach(store.suggestions.prefix(limit)) { suggestion in
            Button { selectSuggestion(suggestion) } label: {
                VStack(alignment: .leading) {
                    Text(suggestion.title).lineLimit(1)
                    if let subtitle = suggestion.subtitle {
                        Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 7)
            }.buttonStyle(.plain)
        }
    }

    @ViewBuilder
    private var overflowMenu: some View {
        Button("Settings", systemImage: "gearshape") { store.send(.settingsTapped) }
        Button("New Tab", systemImage: "plus") { store.send(.newTabTapped) }
        if store.selectedTab?
            .isStartPage != true {
            Button("Start Page", systemImage: "house") { store.send(.showStartPageTapped) }
        }
        Button("History", systemImage: "clock") { store.send(.libraryPresented(.history)) }
        if hasPageActions {
            if let bookmarkID = bookmarkID(for: store.selectedTab) {
                Button("View Bookmark", systemImage: "bookmark.fill") { store.send(.viewBookmark(bookmarkID)) }
            } else {
                Button("Add Bookmark", systemImage: "bookmark") { store.send(.addBookmarkTapped) }
            }
            Button("Copy URL", systemImage: "doc.on.doc") { store.send(.copyURL(store.selectedTabID)) }
            Button("Find on Page", systemImage: "doc.text.magnifyingglass") { store.send(.findPresented) }
            if let tab = store.selectedTab,
               let url = tab.metadata.committedURL {
                ShareLink(item: url, subject: Text(tabTitle(tab))) { Label(
                    "Share",
                    systemImage: "square.and.arrow.up",
                ) }
            }
        }
        Button("Close Tab", systemImage: "xmark") { store.send(.closeTab(store.selectedTabID)) }
            .keyboardShortcut("w", modifiers: .command)
        if store.tabs.count > 1 {
            Button("Close All Tabs", systemImage: "xmark.square", role: .destructive) {
                store.send(.closeAllTapped)
            }
        }
    }

    private var tabOverview: some View {
        VStack(spacing: 16) {
            HStack { Text("Tabs").font(.largeTitle.bold())
                Spacer()
                Button("New Tab", systemImage: "plus") {
                    cancelTabTransition()
                    store.send(.newTabTapped)
                }
            }
            ScrollView {
                LazyVGrid(columns: tabOverviewColumns, spacing: 18) {
                    ForEach(store.tabs) { tab in
                        tabCard(tab)
                    }
                }
            }
        }.padding(20)
    }

    private var tabOverviewColumns: [GridItem] {
        if horizontalSizeClass == .compact {
            return [
                GridItem(.flexible(), spacing: 18),
                GridItem(.flexible(), spacing: 18),
            ]
        }

        return [GridItem(.adaptive(minimum: 220), spacing: 18)]
    }

    private func tabCard(_ tab: BrowserTab) -> some View {
        let button = Button { selectTabCard(tab) } label: { tabCardContent(tab) }
            .buttonStyle(.plain)
        return button
            .offset(x: tabCardDrag?.tabID == tab.id ? tabCardDrag?.horizontalTranslation ?? 0 : 0)
            .accessibilityFocused($accessibilityFocusedTabID, equals: tab.id)
            .accessibilityValue(tab.id == store.selectedTabID ? "Selected" : "")
            .accessibilityAction(named: "Close Tab") { store.send(.closeTab(tab.id)) }
            .simultaneousGesture(
                DragGesture(minimumDistance: 24)
                    .onChanged { gesture in
                        updateTabCardDrag(tabID: tab.id, translation: gesture.translation)
                    }
                    .onEnded { gesture in
                        finishTabCardDrag(tabID: tab.id, translation: gesture.translation)
                    },
            )
            .contextMenu { tabCardMenu(tab) }
    }

    private func updateTabCardDrag(tabID: BrowserTabID, translation: CGSize) {
        if let tabCardDrag, tabCardDrag.tabID == tabID {
            guard tabCardDrag.axis == .horizontal else {
                return
            }

            self.tabCardDrag = .init(
                tabID: tabID,
                axis: .horizontal,
                horizontalTranslation: translation.width,
            )
            return
        }

        let axis = BrowserTabSwipe.axis(for: translation)
        tabCardDrag = .init(
            tabID: tabID,
            axis: axis,
            horizontalTranslation: axis == .horizontal ? translation.width : 0,
        )
    }

    private func finishTabCardDrag(tabID: BrowserTabID, translation: CGSize) {
        guard let tabCardDrag, tabCardDrag.tabID == tabID else {
            return
        }
        guard let outcome = BrowserTabSwipe.outcome(for: translation, axis: tabCardDrag.axis) else {
            self.tabCardDrag = nil
            return
        }

        switch outcome {
        case .cancel:
            withAnimation(tabCardSettleAnimation) {
                self.tabCardDrag = nil
            }
        case .dismiss:
            self.tabCardDrag = nil
            store.send(.closeTab(tabID))
        }
    }

    private var tabCardSettleAnimation: Animation {
        reduceMotionEnabled ? .easeOut(duration: 0.15) : .spring(response: 0.42)
    }

    private func tabCardContent(_ tab: BrowserTab) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            BrowserTabTransitionSurfaceHost(
                role: .card(tab.id),
                registry: tabTransitionUIKitCoordinator.surfaceRegistry,
            ) {
                tabPreviewSurface(tab)
            }
            .aspectRatio(tabPreviewAspectRatio, contentMode: .fit)
            HStack(spacing: 6) {
                if tab.id == store.selectedTabID {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 18, weight: .semibold))
                        .frame(width: 28, height: 44)
                        .accessibilityLabel("Selected")
                }
                Text(tabTitle(tab))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .minimumScaleFactor(0.5)
                    .allowsTightening(true)
                    .layoutPriority(1)
                Spacer()
                Button { store.send(.closeTab(tab.id)) } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 18, weight: .semibold))
                        .frame(width: 44, height: 44)
                        .accessibilityHidden(true)
                }
                .accessibilityLabel("Close \(tabTitle(tab))")
            }
            .frame(height: 44, alignment: .center)
            .clipped()
        }
        .padding(10)
        .frame(maxWidth: .infinity)
        .background(.background, in: RoundedRectangle(cornerRadius: 18))
        .shadow(radius: 3)
    }

    private func tabPreviewSurface(_ tab: BrowserTab) -> some View {
        tabPreviewSurface(
            representation: visiblePreviewRepresentation(for: tab),
            fallback: BrowserTabPreviewRepresentation.fallback(for: tab),
        )
    }

    private func visiblePreviewRepresentation(for tab: BrowserTab) -> BrowserTabPreviewRepresentation {
        .cachedOrFallback(
            for: tab,
            revision: store.previewRevisions[tab.id] ?? .init(),
            cache: store.tabPreviewData,
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
                let revision = store.previewRevisions[tab.id] ?? BrowserTabPreviewRevision()
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
        tabTransitionToken += 1
        let token = tabTransitionToken
        isTabTransitionActive = true
        tabTransitionDirection = direction
        tabTransitionTabID = tabID
        tabTransitionUIKitCoordinator.begin(
            token: token,
            direction: direction,
            tabID: tabID,
            reduceMotion: reduceMotionEnabled,
            onPresentationChange: action,
            onCompletion: {
                isTabTransitionActive = false
                tabTransitionDirection = nil
                tabTransitionTabID = nil
            },
        )
    }

    private func cancelTabTransition() {
        tabTransitionUIKitCoordinator.cancel()
        isTabTransitionActive = false
        tabTransitionDirection = nil
        tabTransitionTabID = nil
    }

    private func tabPreviewSurface(
        representation: BrowserTabPreviewRepresentation,
        fallback: BrowserTabPreviewRepresentation,
    ) -> some View {
        ZStack {
            RoundedRectangle(
                cornerRadius: BrowserTabTransitionPresentation.cardCornerRadius,
                style: .continuous,
            )
            .fill(.quaternary)
            switch representation {
            case let .snapshot(data):
                if let image = UIImage(data: data) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .clipped()
                } else {
                    placeholderPreview(fallback)
                }
            case let .placeholder(placeholder):
                placeholderPreview(.placeholder(placeholder))
            }
        }
        .clipShape(RoundedRectangle(
            cornerRadius: BrowserTabTransitionPresentation.cardCornerRadius,
            style: .continuous,
        ))
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func placeholderPreview(_ representation: BrowserTabPreviewRepresentation) -> some View {
        if case let .placeholder(placeholder) = representation {
            VStack(spacing: 8) {
                Image(systemName: placeholder.systemImage)
                    .font(.largeTitle)
                Text(placeholder.label)
                    .font(.caption.weight(.medium))
            }
            .foregroundStyle(placeholder.tint)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private func tabCardMenu(_ tab: BrowserTab) -> some View {
        Button("Open Tab") { selectTabCard(tab) }
        if case .web = tab.content, let url = tab.metadata.committedURL {
            if let bookmarkID = bookmarkID(for: tab) {
                Button("View Bookmark") { store.send(.viewBookmark(bookmarkID)) }
            } else {
                Button("Add Bookmark") { store.send(.addBookmarkForTab(tab.id)) }
            }
            Button("Copy URL") { store.send(.copyURL(tab.id)) }
            ShareLink(item: url, subject: Text(tabTitle(tab))) { Text("Share Page") }
        }
        Button("Close Tab", role: .destructive) { store.send(.closeTab(tab.id)) }
        if store.tabs.count > 1 {
            Button("Close Other Tabs", role: .destructive) { store.send(.closeOtherTabsTapped(tab.id)) }
        }
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

    private func selectSuggestion(_ value: BrowserSuggestion) {
        switch value.kind {
        case let .bookmark(id):
            if let item = store.bookmarks
                .first(where: { $0.id == id }) {
                store.send(.navigate(item.url))
            }
        case let .history(id):
            if let item = store.history
                .first(where: { $0.id == id }) {
                store.send(.navigate(item.url))
            }
        case let .copiedLink(url):
            store.send(.navigate(url))
        case let .provider(query),
             let .search(_, query):
            store.send(.omniboxChanged(query))
            store.send(.omniboxSubmitted)
        }
    }

    private var findBar: some View {
        HStack {
            TextField("Find on Page", text: Binding(
                get: { store.findDraft ?? "" },
                set: { store.send(.findChanged($0)) },
            ))
            .textFieldStyle(.roundedBorder)
            Button("Done") { store.send(.findDismissed) }
        }
        .padding(10)
        .background(.bar)
    }

    private var hasPageActions: Bool {
        guard case .web = store.selectedTab?.content,
              let url = store.selectedTab?.metadata.committedURL
        else {
            return false
        }

        return BrowserNavigation.isHTTPURL(url)
    }

    private func bookmarkID(for tab: BrowserTab?) -> UUID? {
        guard case .web = tab?.content, let url = tab?.metadata.committedURL else {
            return nil
        }

        return store.bookmarks.first(where: { $0.url == url })?.id
    }

    private func tabTitle(_ tab: BrowserTab) -> String {
        tab.isStartPage
            ? "Start Page"
            : (tab.metadata.title ?? tab.metadata.committedURL?.host ?? "Web Page")
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
    fileprivate var systemImage: String {
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

    fileprivate var label: String {
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

    fileprivate var tint: Color {
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
