//
//  BrowserLibraryView.swift
//  MediaVault
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import ComposableArchitecture
import Foundation
import SwiftUI

@MainActor
@preconcurrency
struct BrowserLibraryView: View {
    let store: StoreOf<BrowserFeature>
    var body: some View {
        NavigationStack {
            VStack {
                Picker("Section", selection: Binding(
                    get: { store.library?.section ?? .bookmarks },
                    set: { store.send(.libraryPresented($0)) },
                )) {
                    Text("Bookmarks").tag(BrowserLibrarySection.bookmarks)
                    Text("History").tag(BrowserLibrarySection.history)
                }
                .pickerStyle(.segmented)
                .padding()
                if store.library?.section == .history {
                    historyList
                } else {
                    bookmarkList
                }
            }
            .navigationTitle("Browser Library")
            .toolbar { Button("Done") { store.send(.libraryDismissed) } }
        }
    }

    private var bookmarkList: some View {
        ScrollViewReader { proxy in
            List(BrowserLibrarySearch.bookmarks(store.bookmarks, query: store.library?.bookmarkSearch ?? "")) { item in
                Button { store.send(.navigate(item.url)) } label: { row(item.title, item.url.host) }
                    .id(item.id)
                    .swipeActions {
                        Button("Delete", role: .destructive) { store.send(.deleteBookmark(item.id)) }
                    }
                    .contextMenu {
                        Button("Open in New Tab") {
                            store.send(.openInNewTab(item.url, openerID: store.selectedTabID))
                        }
                        Button("Edit Bookmark") { store.send(.editBookmarkTapped(item.id)) }
                        Button("Delete Bookmark", role: .destructive) { store.send(.deleteBookmark(item.id)) }
                    }
            }
            .onAppear {
                if let bookmarkID = store.library?.revealedBookmarkID {
                    proxy.scrollTo(bookmarkID, anchor: .center)
                    store.send(.bookmarkRevealConsumed)
                }
            }
            .scrollPosition(id: Binding(
                get: { store.library?.bookmarkScrollPosition },
                set: { position in
                    guard let position else {
                        return
                    }

                    store.send(.libraryScrollChanged(.bookmarks, position))
                },
            ))
            .searchable(text: Binding(
                get: { store.library?.bookmarkSearch ?? "" },
                set: { store.send(.librarySearchChanged(.bookmarks, $0)) },
            ))
        }
    }

    private var historyList: some View {
        List {
            ForEach(historyGroups) { group in
                Section(group.title) {
                    ForEach(group.entries) { item in
                        Button { store.send(.navigate(item.url)) } label: {
                            row(item.title, BrowserHistoryGrouping.metadata(for: item, group: group))
                        }
                        .id(item.id)
                        .swipeActions {
                            Button("Delete", role: .destructive) { store.send(.deleteHistoryEntry(item.id)) }
                        }
                        .contextMenu {
                            Button("Open in New Tab") {
                                store.send(.openInNewTab(item.url, openerID: store.selectedTabID))
                            }
                            Button("Delete History Entry", role: .destructive) {
                                store.send(.deleteHistoryEntry(item.id))
                            }
                        }
                    }
                }
            }
            Button("Clear History", role: .destructive) { store.send(.clearHistoryTapped(source: .library)) }
        }
        .scrollPosition(id: Binding(
            get: { store.library?.historyScrollPosition },
            set: { position in
                guard let position else {
                    return
                }

                store.send(.libraryScrollChanged(.history, position))
            },
        ))
        .searchable(text: Binding(
            get: { store.library?.historySearch ?? "" },
            set: { store.send(.librarySearchChanged(.history, $0)) },
        ))
    }

    private var historyGroups: [BrowserHistoryGroup] {
        BrowserHistoryGrouping.groups(
            BrowserLibrarySearch.history(store.history, query: store.library?.historySearch ?? ""),
            referenceDate: store.library?.referenceDate ?? Date(timeIntervalSinceReferenceDate: 0),
            calendar: .autoupdatingCurrent,
        )
    }

    private func row(_ title: String, _ host: String?) -> some View {
        VStack(alignment: .leading) { Text(title).lineLimit(1)
            Text(host ?? "").font(.caption).foregroundStyle(.secondary)
        }
    }
}

@MainActor
@preconcurrency
struct BrowserBookmarkEditorView: View {
    let store: StoreOf<BrowserFeature>

    var body: some View {
        NavigationStack {
            Form {
                TextField("Title", text: Binding(
                    get: { store.bookmarkEditor?.title ?? "" },
                    set: { store.send(.bookmarkEditorChanged(title: $0, url: store.bookmarkEditor?.urlDraft ?? "")) },
                ))
                TextField("Address", text: Binding(
                    get: { store.bookmarkEditor?.urlDraft ?? "" },
                    set: { store.send(.bookmarkEditorChanged(title: store.bookmarkEditor?.title ?? "", url: $0)) },
                ))
                .textInputAutocapitalization(.never)
                .keyboardType(.URL)
                if let message = store.bookmarkEditor?.validationMessage {
                    Text(message).foregroundStyle(.red)
                }
            }
            .navigationTitle(store.bookmarkEditor?.bookmarkID == nil ? "Add Bookmark" : "Edit Bookmark")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { store.send(.bookmarkEditorCancelled) }
                }
                ToolbarItem(placement: .confirmationAction) { Button("Save") { store.send(.bookmarkEditorSaved) } }
            }
        }
    }
}
