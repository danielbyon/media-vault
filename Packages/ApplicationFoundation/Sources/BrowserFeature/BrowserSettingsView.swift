//
//  BrowserSettingsView.swift
//  MediaVault
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import ComposableArchitecture
import SwiftUI

/// Authenticated Browser preferences and the profile confirmation boundary.
@MainActor
@preconcurrency
public struct BrowserSettingsView: View {
    let store: StoreOf<BrowserFeature>
    /// Creates authenticated Browser settings bound to the browser feature.
    public init(store: StoreOf<BrowserFeature>) {
        self.store = store
    }

    /// Renders search, tab, website-data profile, and Browser reset preferences.
    public var body: some View {
        Form {
            profileSection
            searchSection
            tabsSection
            browserDataSection
        }
        .navigationTitle("Browser")
        .disabled(!store.canCreateWebKitContext)
        .task {
            await store.send(.settingsPresented).finish()
        }
        .confirmationDialog(
            confirmationTitle,
            isPresented: Binding(
                get: { store.pendingProfileChange != nil },
                set: { isPresented in
                    if !isPresented {
                        store.send(.profileChangeCancelled)
                    }
                },
            ),
            titleVisibility: .visible,
        ) {
            Button(confirmationActionTitle, role: isResetConfirmation ? .destructive : nil) {
                store.send(.profileChangeConfirmed)
            }
            Button("Cancel", role: .cancel) {
                store.send(.profileChangeCancelled)
            }
        } message: {
            Text(confirmationMessage)
        }
    }

    private var profileSection: some View {
        Section("Privacy") {
            Picker("Browsing Profile", selection: Binding(
                get: { store.settings.browsingProfile },
                set: { store.send(.profileChangeRequested($0)) },
            )) {
                ForEach(BrowserBrowsingProfile.allCases, id: \.self) { profile in
                    Text(profile.displayName).tag(profile)
                }
            }
            .disabled(!store.canCreateWebKitContext)
            Text(
                "Persistent-Private keeps website data between visits. Ephemeral session data is discarded when you switch profiles.",
            )
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
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
                Text("Ask Every Time").tag(BrowserOpenLinkPreference.askEveryTime)
            }
        }
    }

    private var browserDataSection: some View {
        Section("Browser Data") {
            Button("Clear History", role: .destructive) { store.send(.clearHistoryTapped(source: .settings)) }
            Button("Delete All Bookmarks", role: .destructive) { store.send(.deleteAllBookmarksTapped) }
            Button("Reset Browser Settings") { store.send(.resetSettings) }
                .disabled(!store.canCreateWebKitContext)
        }
    }

    private var confirmationTitle: String {
        isResetConfirmation ? "Reset Browser Settings?" : "Change Browsing Profile?"
    }

    private var confirmationActionTitle: String {
        if isResetConfirmation {
            "Reset and Switch"
        } else if case let .profile(profile) = store.pendingProfileChange {
            "Switch to \(profile.displayName)"
        } else {
            "Continue"
        }
    }

    private var confirmationMessage: String {
        if isResetConfirmation {
            "This resets all Browser preferences and switches to Persistent-Private. Loaded History and bookmarks remain available."
        } else {
            "Changing profiles closes all open tabs and starts a new session. "
                + "Persistent-Private website data remains saved. Ephemeral session data is discarded when you leave."
        }
    }

    private var isResetConfirmation: Bool {
        store.pendingProfileChange == .resetSettings
    }
}
