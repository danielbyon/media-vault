//
//  BrowserSettingsClient.swift
//  MediaVault
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import ComposableArchitecture
@preconcurrency import Foundation

/// Namespaced persistence dependency for authenticated Browser preferences.
struct BrowserSettingsClient: Sendable {
    var load: @Sendable () async -> BrowserSettings
    var save: @Sendable (BrowserSettings) async -> Void
    var reset: @Sendable () async -> Void
}

extension BrowserSettingsClient: DependencyKey {
    /// Builds a client from the app-storage dependency active at the point of resolution.
    static var liveValue: Self {
        @Dependency(\.defaultAppStorage)
        var defaultAppStorage
        let storage = BrowserSettingsStorage(userDefaults: defaultAppStorage)
        return Self(
            load: { await storage.load() },
            save: { await storage.save($0) },
            reset: { await storage.reset() },
        )
    }

    /// Deterministic no-op client used unless a test overrides it.
    static let testValue = Self(load: { .init() }, save: { _ in }, reset: {})
}

extension DependencyValues {
    /// Reducer-facing Browser preference persistence dependency.
    var browserSettings: BrowserSettingsClient {
        get { self[BrowserSettingsClient.self] }
        set { self[BrowserSettingsClient.self] = newValue }
    }
}

/// Concrete namespaced Browser settings storage backed by an injected UserDefaults instance.
actor BrowserSettingsStorage {
    private let userDefaults: UserDefaults

    /// Creates storage that reads and writes only through the supplied UserDefaults instance.
    init(userDefaults: UserDefaults) {
        self.userDefaults = userDefaults
    }

    /// Loads Browser preferences, applying the documented defaults for absent or invalid values.
    func load() -> BrowserSettings {
        BrowserSettings(
            searchProvider: userDefaults.string(forKey: BrowserSettingsStorageKeys.searchProvider)
                .flatMap(BrowserSearchProvider.init(rawValue:)) ?? .duckDuckGo,
            providerSuggestionsEnabled: userDefaults.bool(
                forKey: BrowserSettingsStorageKeys.providerSuggestionsEnabled,
            ),
            copiedLinkSuggestionsEnabled: userDefaults.object(
                forKey: BrowserSettingsStorageKeys.copiedLinkSuggestionsEnabled,
            ) != nil
                ? userDefaults.bool(forKey: BrowserSettingsStorageKeys.copiedLinkSuggestionsEnabled)
                : true,
            openLinksInNewTabs: userDefaults.string(forKey: BrowserSettingsStorageKeys.openLinksInNewTabs)
                .flatMap(BrowserOpenLinkPreference.init(rawValue:)) ?? .background,
            browsingProfile: userDefaults.string(forKey: BrowserSettingsStorageKeys.browsingProfile)
                .flatMap(BrowserBrowsingProfile.init(rawValue:)) ?? .persistentPrivate,
        )
    }

    /// Persists every Browser-owned preference without touching other application keys.
    func save(_ settings: BrowserSettings) {
        userDefaults.set(settings.searchProvider.rawValue, forKey: BrowserSettingsStorageKeys.searchProvider)
        userDefaults.set(
            settings.providerSuggestionsEnabled,
            forKey: BrowserSettingsStorageKeys.providerSuggestionsEnabled,
        )
        userDefaults.set(
            settings.copiedLinkSuggestionsEnabled,
            forKey: BrowserSettingsStorageKeys.copiedLinkSuggestionsEnabled,
        )
        userDefaults.set(settings.openLinksInNewTabs.rawValue, forKey: BrowserSettingsStorageKeys.openLinksInNewTabs)
        userDefaults.set(settings.browsingProfile.rawValue, forKey: BrowserSettingsStorageKeys.browsingProfile)
    }

    /// Removes only the namespaced Browser preference keys.
    func reset() {
        BrowserSettingsStorageKeys.all.forEach(userDefaults.removeObject(forKey:))
    }
}

private enum BrowserSettingsStorageKeys {
    static let searchProvider = "browser.searchProvider"
    static let providerSuggestionsEnabled = "browser.providerSuggestionsEnabled"
    static let copiedLinkSuggestionsEnabled = "browser.copiedLinkSuggestionsEnabled"
    static let openLinksInNewTabs = "browser.openLinksInNewTabs"
    static let browsingProfile = "browser.browsingProfile"

    static let all = [
        searchProvider,
        providerSuggestionsEnabled,
        copiedLinkSuggestionsEnabled,
        openLinksInNewTabs,
        browsingProfile,
    ]
}
