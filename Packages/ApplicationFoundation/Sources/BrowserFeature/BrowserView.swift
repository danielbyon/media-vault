//
//  BrowserView.swift
//  MediaVault
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import ComposableArchitecture
import Foundation
import PresentationSupport
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
    @FocusState
    private var focusedField: BrowserFocusedField?
    @AccessibilityFocusState
    private var accessibilityFocusedTabID: BrowserTabID?
    @Namespace
    private var tabTransition

    /// Creates browser UI bound to deterministic feature state.
    public init(store: StoreOf<BrowserFeature>) {
        self.store = store
        reduceMotionOverride = nil
    }

    /// Creates a deterministic presentation for accessibility snapshot coverage.
    init(store: StoreOf<BrowserFeature>, reduceMotionOverride: Bool) {
        self.store = store
        self.reduceMotionOverride = reduceMotionOverride
    }

    /// Renders the selected browser endpoint or the app-owned tab overview.
    public var body: some View {
        Group {
            if store.presentation == .tabOverview {
                tabOverview
            } else {
                selectedContentWithChrome
                    .keyboardDismissal(focus: $focusedField)
            }
        }
        .background(Color(uiColor: .systemBackground))
        .animation(
            reduceMotionEnabled ? .easeOut(duration: 0.15) : .spring(response: 0.42),
            value: store.presentation,
        )
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
        }
        .onChange(of: accessibilityFocusedTabID) { _, value in
            guard store.presentation == .tabOverview,
                  value != store.tabOverviewFocusID
            else {
                return
            }

            store.send(.tabOverviewFocusChanged(value))
        }
        .task { await store.send(.task).finish() }
        .sheet(isPresented: Binding(
            get: { store.library != nil },
            set: {
                if !$0 {
                    store.send(.libraryDismissed)
                }
            },
        )) { BrowserLibraryView(store: store) }
        .sheet(isPresented: Binding(
            get: { store.bookmarkEditor != nil },
            set: {
                if !$0 {
                    store.send(.bookmarkEditorCancelled)
                }
            },
        )) { BrowserBookmarkEditorView(store: store) }
        .sheet(isPresented: Binding(
            get: { store.shareURL != nil },
            set: {
                if !$0 {
                    store.send(.shareDismissed)
                }
            },
        )) {
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
    }
}

extension BrowserView {
    private var reduceMotionEnabled: Bool {
        reduceMotionOverride ?? reduceMotion
    }

    @ViewBuilder
    private var selectedContentWithChrome: some View {
        if horizontalSizeClass == .regular {
            selectedContentPresentation
                .safeAreaBar(edge: .top, spacing: 0) {
                    chrome
                }
        } else {
            selectedContentPresentation
                .safeAreaBar(edge: .bottom, spacing: 0) {
                    chrome
                }
        }
    }

    @ViewBuilder
    private var selectedContentPresentation: some View {
        if reduceMotionEnabled {
            selectedContent.transition(.opacity)
        } else {
            selectedContent.matchedGeometryEffect(id: store.selectedTabID, in: tabTransition)
        }
    }

    @ViewBuilder
    private var selectedContent: some View {
        if let tab = store.selectedTab {
            switch tab.content {
            case .startPage:
                startPage
            case .web:
                BrowserWebView(tabID: tab.id) { store.send(.pullToRefresh) }
                    .accessibilityLabel("Web page")
            case let .error(error):
                errorView(error, terminated: false)
            case .terminated:
                errorView(
                    .pageCouldNotLoad(tab.metadata.committedURL ?? URL(filePath: "/terminated-web-content")),
                    terminated: true,
                )
            }
        }
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

            Button { store.send(.showTabOverviewTapped) } label: {
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
                Button("New Tab", systemImage: "plus") { store.send(.newTabTapped) }
            }
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 18)], spacing: 18) {
                    ForEach(store.tabs) { tab in
                        tabCard(tab)
                    }
                }
            }
        }.padding(20)
    }

    private func tabCard(_ tab: BrowserTab) -> some View {
        let button = Button { store.send(.tabCardSelected(tab.id)) } label: { tabCardContent(tab) }
            .buttonStyle(.plain)
        return Group {
            if reduceMotionEnabled {
                button
            } else {
                button.matchedGeometryEffect(id: tab.id, in: tabTransition)
            }
        }
        .accessibilityFocused($accessibilityFocusedTabID, equals: tab.id)
        .accessibilityValue(tab.id == store.selectedTabID ? "Selected" : "")
        .accessibilityAction(named: "Close Tab") { store.send(.closeTab(tab.id)) }
        .simultaneousGesture(DragGesture(minimumDistance: 24).onEnded { gesture in
            if abs(gesture.translation.width) > 80 || abs(gesture.translation.height) > 80 {
                store.send(.closeTab(tab.id))
            }
        })
        .contextMenu { tabCardMenu(tab) }
    }

    private func tabCardContent(_ tab: BrowserTab) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 14).fill(.quaternary)
                tabPreview(tab)
                if tab.metadata.isLoading {
                    ProgressView()
                }
            }.aspectRatio(4 / 3, contentMode: .fit)
            HStack {
                if tab.id == store.selectedTabID {
                    Image(systemName: "checkmark.circle.fill").accessibilityLabel("Selected")
                }
                Text(tabTitle(tab)).lineLimit(1).truncationMode(.tail)
                Spacer()
                Button { store.send(.closeTab(tab.id)) } label: {
                    Image(systemName: "xmark.circle.fill").accessibilityHidden(true)
                }
                .accessibilityLabel("Close \(tabTitle(tab))")
            }
        }
        .padding(10)
        .background(.background, in: RoundedRectangle(cornerRadius: 18))
        .shadow(radius: 3)
    }

    @ViewBuilder
    private func tabPreview(_ tab: BrowserTab) -> some View {
        if let data = store.tabPreviewData[tab.id], let image = UIImage(data: data) {
            Image(uiImage: image).resizable().scaledToFill().clipped().accessibilityHidden(true)
        } else {
            Image(systemName: tab.isStartPage ? "sparkles" : "globe")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
        }
    }

    @ViewBuilder
    private func tabCardMenu(_ tab: BrowserTab) -> some View {
        Button("Open Tab") { store.send(.tabCardSelected(tab.id)) }
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
