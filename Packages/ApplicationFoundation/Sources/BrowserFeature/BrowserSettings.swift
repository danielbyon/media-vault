//
//  BrowserSettings.swift
//  MediaVault
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//

/// How explicit Open in New Tab actions determine the new tab's presentation.
public enum BrowserOpenLinkPreference: String, CaseIterable, Equatable, Sendable {
    /// Keep a user-created related tab in the background.
    case background
    /// Focus a user-created related tab immediately.
    case foreground
    /// Ask for the new tab's presentation before creating it.
    case askEveryTime
}

/// Persistent authenticated browser preferences owned by Issue #37.
public struct BrowserSettings: Equatable, Sendable {
    /// Text shown beside the opt-in because autocomplete can transmit text before submission.
    static let providerSuggestionDisclosure =
        "Enabling suggestions may send partial typed text to the selected provider before submission."
    var searchProvider: BrowserSearchProvider
    var providerSuggestionsEnabled: Bool
    var copiedLinkSuggestionsEnabled: Bool
    var openLinksInNewTabs: BrowserOpenLinkPreference

    init(
        searchProvider: BrowserSearchProvider = .duckDuckGo,
        providerSuggestionsEnabled: Bool = false,
        copiedLinkSuggestionsEnabled: Bool = true,
        openLinksInNewTabs: BrowserOpenLinkPreference = .background,
    ) {
        self.searchProvider = searchProvider
        self.providerSuggestionsEnabled = providerSuggestionsEnabled
        self.copiedLinkSuggestionsEnabled = copiedLinkSuggestionsEnabled
        self.openLinksInNewTabs = openLinksInNewTabs
    }
}
