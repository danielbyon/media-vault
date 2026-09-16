//
//  BrowserSettings.swift
//  MediaVault
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//

/// Whether explicit Open in New Tab activates the new tab.
public enum BrowserOpenLinkPreference: String, CaseIterable, Equatable, Sendable {
    /// Keep a user-created related tab in the background.
    case background
    /// Focus a user-created related tab immediately.
    case foreground
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
