//
//  BrowserSettingsView.swift
//  MediaVault
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import ComposableArchitecture
import SwiftUI

/// Authenticated Settings → Browser preferences and Issue #39 destructive seams.
@MainActor
@preconcurrency
public struct BrowserSettingsView: View {
    let store: StoreOf<BrowserFeature>
    /// Creates authenticated Browser settings bound to the browser feature.
    public init(store: StoreOf<BrowserFeature>) {
        self.store = store
    }

    /// Renders persistent Issue #37 preferences and Issue #39 destructive seams.
    public var body: some View {
        Form {
            searchSection
            tabsSection
            browserDataSection
        }.navigationTitle("Browser")
    }

    private var searchSection: some View {
        Section("Search") {
            Picker("Search Provider", selection: Binding(
                get: { store.settings.searchProvider },
                set: { store.send(.searchProviderChanged($0)) },
            )) {
                ForEach(BrowserSearchProvider.allCases, id: \.self) { Text($0.displayName).tag($0) }
            }
            Toggle("Search Provider Suggestions", isOn: Binding(
                get: { store.settings.providerSuggestionsEnabled },
                set: { store.send(.providerSuggestionsChanged($0)) },
            ))
            Text(BrowserSettings.providerSuggestionDisclosure).font(.footnote).foregroundStyle(.secondary)
        }
    }

    private var tabsSection: some View {
        Section("Tabs") {
            Toggle("Copied-Link Suggestions", isOn: Binding(
                get: { store.settings.copiedLinkSuggestionsEnabled },
                set: { store.send(.copiedLinkSuggestionsChanged($0)) },
            ))
            Picker("Open Links in New Tabs", selection: Binding(
                get: { store.settings.openLinksInNewTabs },
                set: { store.send(.openLinkPreferenceChanged($0)) },
            )) {
                Text("In Background").tag(BrowserOpenLinkPreference.background)
                Text("In Foreground").tag(BrowserOpenLinkPreference.foreground)
            }
        }
    }

    private var browserDataSection: some View {
        Section("Browser Data") {
            Button("Clear History", role: .destructive) { store.send(.clearHistoryTapped(source: .settings)) }
            Button("Delete All Bookmarks", role: .destructive) { store.send(.deleteAllBookmarksTapped) }
            Button("Reset Browser Settings") { store.send(.resetSettings) }
        }
    }
}
