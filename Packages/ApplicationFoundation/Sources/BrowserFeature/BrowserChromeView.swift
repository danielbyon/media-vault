//
//  BrowserChromeView.swift
//  MediaVault
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import ComposableArchitecture
import SwiftUI
import UIKit

/// Shared omnibox presentation used by the Start Page and browser chrome.
@MainActor
@preconcurrency
struct BrowserOmniboxView: View {
    let store: StoreOf<BrowserFeature>
    @FocusState.Binding
    private var focusedField: BrowserFocusedField?
    let large: Bool

    init(
        store: StoreOf<BrowserFeature>,
        focusedField: FocusState<BrowserFocusedField?>.Binding,
        large: Bool,
    ) {
        self.store = store
        _focusedField = focusedField
        self.large = large
    }

    var body: some View {
        VStack(spacing: 0) {
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
            .padding(large ? 16 : 10)
            .background(.quaternary.opacity(0.8), in: RoundedRectangle(cornerRadius: large ? 18 : 12))
            if store.focusedField != .none, !store.suggestions.isEmpty {
                suggestionRows(limit: large ? 6 : 4)
            }
        }
    }

    private func suggestionRows(limit: Int) -> some View {
        ForEach(store.suggestions.prefix(limit)) { suggestion in
            Button { selectSuggestion(suggestion) } label: {
                VStack(alignment: .leading) {
                    Text(suggestion.title).lineLimit(1)
                    if let subtitle = suggestion.subtitle {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 7)
            }
            .buttonStyle(.plain)
        }
    }

    private func selectSuggestion(_ value: BrowserSuggestion) {
        switch value.kind {
        case let .bookmark(id):
            if let item = store.bookmarks.first(where: { $0.id == id }) {
                store.send(.navigate(item.url))
            }
        case let .history(id):
            if let item = store.history.first(where: { $0.id == id }) {
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
}

/// Native Start Page content, kept separate from browser lifecycle and transition orchestration.
@MainActor
@preconcurrency
struct BrowserStartPageView: View {
    let store: StoreOf<BrowserFeature>
    @FocusState.Binding
    private var focusedField: BrowserFocusedField?

    init(
        store: StoreOf<BrowserFeature>,
        focusedField: FocusState<BrowserFocusedField?>.Binding,
    ) {
        self.store = store
        _focusedField = focusedField
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 28) {
                Text("Start Page")
                    .font(.largeTitle.bold())
                    .frame(maxWidth: .infinity, alignment: .leading)
                BrowserOmniboxView(store: store, focusedField: $focusedField, large: true)
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
                                Button { store.send(.navigate(bookmark.url)) } label: {
                                    bookmarkTile(bookmark)
                                }
                                .buttonStyle(.plain)
                                .contextMenu {
                                    Button("Open") { store.send(.navigate(bookmark.url)) }
                                    Button("Open in New Tab") {
                                        store.send(.openInNewTab(bookmark.url, openerID: store.selectedTabID))
                                    }
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
                    Image(uiImage: image)
                        .resizable()
                        .accessibilityHidden(true)
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
}

/// Browser navigation chrome isolated from the page and transition lifecycle.
@MainActor
@preconcurrency
struct BrowserChromeView: View {
    let store: StoreOf<BrowserFeature>
    @FocusState.Binding
    private var focusedField: BrowserFocusedField?
    let isTransitionActive: Bool
    let onRequestTabOverview: () -> Void

    @Environment(\.horizontalSizeClass)
    private var horizontalSizeClass

    init(
        store: StoreOf<BrowserFeature>,
        focusedField: FocusState<BrowserFocusedField?>.Binding,
        isTransitionActive: Bool,
        onRequestTabOverview: @escaping () -> Void,
    ) {
        self.store = store
        _focusedField = focusedField
        self.isTransitionActive = isTransitionActive
        self.onRequestTabOverview = onRequestTabOverview
    }

    var body: some View {
        VStack(spacing: 0) {
            if let tab = store.selectedTab, tab.metadata.isLoading {
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
        .buttonStyle(.plain)
        .allowsHitTesting(store.presentation == .browsing && !isTransitionActive)
        .accessibilityHidden(store.presentation != .browsing || isTransitionActive)
    }

    private var stackedCompactChrome: some View {
        VStack(spacing: 0) {
            BrowserOmniboxView(store: store, focusedField: $focusedField, large: false)
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

            if includesOmnibox, store.selectedTab?.isStartPage != true {
                BrowserOmniboxView(store: store, focusedField: $focusedField, large: false)
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

            Button { onRequestTabOverview() } label: {
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
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var overflowMenu: some View {
        Button("Settings", systemImage: "gearshape") { store.send(.settingsTapped) }
        Button("New Tab", systemImage: "plus") { store.send(.newTabTapped) }
        if store.selectedTab?.isStartPage != true {
            Button("Start Page", systemImage: "house") { store.send(.showStartPageTapped) }
        }
        Button("History", systemImage: "clock") { store.send(.libraryPresented(.history)) }
        if hasPageActions {
            if let bookmarkID = BrowserTabPresentation.bookmarkID(
                for: store.selectedTab,
                bookmarks: store.bookmarks,
            ) {
                Button("View Bookmark", systemImage: "bookmark.fill") {
                    store.send(.viewBookmark(bookmarkID))
                }
            } else {
                Button("Add Bookmark", systemImage: "bookmark") { store.send(.addBookmarkTapped) }
            }
            Button("Copy URL", systemImage: "doc.on.doc") { store.send(.copyURL(store.selectedTabID)) }
            Button("Find on Page", systemImage: "doc.text.magnifyingglass") { store.send(.findPresented) }
            if let tab = store.selectedTab, let url = tab.metadata.committedURL {
                ShareLink(item: url, subject: Text(BrowserTabPresentation.title(for: tab))) {
                    Label("Share", systemImage: "square.and.arrow.up")
                }
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

    private var hasPageActions: Bool {
        guard case .web = store.selectedTab?.content,
              let url = store.selectedTab?.metadata.committedURL
        else {
            return false
        }

        return BrowserNavigation.isHTTPURL(url)
    }
}

/// Find-on-page controls kept outside the browser root view's lifecycle concerns.
@MainActor
@preconcurrency
struct BrowserFindBar: View {
    let store: StoreOf<BrowserFeature>

    var body: some View {
        HStack {
            TextField(
                "Find on Page",
                text: Binding(
                    get: { store.findDraft ?? "" },
                    set: { store.send(.findChanged($0)) },
                ),
            )
            .textFieldStyle(.roundedBorder)
            Button("Done") { store.send(.findDismissed) }
        }
        .padding(10)
        .background(.bar)
    }
}
