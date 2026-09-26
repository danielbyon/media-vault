//
//  BrowserSettings.swift
//  MediaVault
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//

/// Selects the global website-data lifetime used by every Browser tab and popup.
public enum BrowserBrowsingProfile: String, CaseIterable, Equatable, Sendable {
    /// Uses the app-owned persistent WebKit store without sharing it with Safari.
    case persistentPrivate
    /// Uses one isolated, nonpersistent WebKit store for the current Browser session.
    case ephemeral

    /// User-facing name shown in authenticated Browser settings.
    public var displayName: String {
        switch self {
        case .persistentPrivate:
            "Persistent-Private"
        case .ephemeral:
            "Ephemeral"
        }
    }
}

/// How explicit Open in New Tab actions determine the new tab's presentation.
public enum BrowserOpenLinkPreference: String, CaseIterable, Equatable, Sendable {
    /// Keep a user-created related tab in the background.
    case background
    /// Focus a user-created related tab immediately.
    case foreground
    /// Ask for the new tab's presentation before creating it.
    case askEveryTime
}

/// Persistent authenticated Browser preferences for search, tabs, and website-data lifetime.
public struct BrowserSettings: Equatable, Sendable {
    /// Text shown beside the opt-in because autocomplete can transmit text before submission.
    static let providerSuggestionDisclosure =
        "Enabling suggestions may send partial typed text to the selected provider before submission."
    var searchProvider: BrowserSearchProvider
    var providerSuggestionsEnabled: Bool
    var copiedLinkSuggestionsEnabled: Bool
    var openLinksInNewTabs: BrowserOpenLinkPreference
    var browsingProfile: BrowserBrowsingProfile

    init(
        searchProvider: BrowserSearchProvider = .duckDuckGo,
        providerSuggestionsEnabled: Bool = false,
        copiedLinkSuggestionsEnabled: Bool = true,
        openLinksInNewTabs: BrowserOpenLinkPreference = .background,
        browsingProfile: BrowserBrowsingProfile = .persistentPrivate,
    ) {
        self.searchProvider = searchProvider
        self.providerSuggestionsEnabled = providerSuggestionsEnabled
        self.copiedLinkSuggestionsEnabled = copiedLinkSuggestionsEnabled
        self.openLinksInNewTabs = openLinksInNewTabs
        self.browsingProfile = browsingProfile
    }
}
