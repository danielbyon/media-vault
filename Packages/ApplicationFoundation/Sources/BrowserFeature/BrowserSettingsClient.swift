//
//  BrowserSettingsClient.swift
//  MediaVault
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import CoreFoundation
import Dependencies
import Foundation
import Sharing

/// Namespaced persistence dependency for authenticated Browser preferences.
struct BrowserSettingsClient: Sendable {
    var load: @Sendable () async -> BrowserSettings
    var save: @Sendable (BrowserSettings) async -> Void
    var reset: @Sendable () async -> Void
    var reserveRevision: @Sendable (UInt64) -> UInt64
    var saveRevisioned: (@Sendable (BrowserSettings, UInt64) async -> Void)?
    var resetRevisioned: (@Sendable (UInt64) async -> Void)?

    init(
        load: @escaping @Sendable () async -> BrowserSettings,
        save: @escaping @Sendable (BrowserSettings) async -> Void,
        reset: @escaping @Sendable () async -> Void,
        reserveRevision: @escaping @Sendable (UInt64) -> UInt64 = { $0 == .max ? .max : $0 + 1 },
        saveRevisioned: (@Sendable (BrowserSettings, UInt64) async -> Void)? = nil,
        resetRevisioned: (@Sendable (UInt64) async -> Void)? = nil,
    ) {
        self.load = load
        self.save = save
        self.reset = reset
        self.reserveRevision = reserveRevision
        self.saveRevisioned = saveRevisioned
        self.resetRevisioned = resetRevisioned
    }
}

extension BrowserSettingsClient: DependencyKey {
    /// Builds a client from the app-storage dependency active at the point of resolution.
    static var liveValue: Self {
        @Dependency(\.defaultAppStorage)
        var defaultAppStorage
        let storage = BrowserSettingsStorage(
            userDefaults: defaultAppStorage,
            revisionGate: .settingsShared,
        )
        return Self(
            load: { await storage.load() },
            save: { await storage.save($0) },
            reset: { await storage.reset() },
            reserveRevision: { BrowserPersistenceRevisionGate.settingsShared.reserve(after: $0) },
            saveRevisioned: { settings, revision in await storage.save(settings, revision: revision) },
            resetRevisioned: { revision in await storage.reset(revision: revision) },
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
    private let revisionGate: BrowserPersistenceRevisionGate
    private var newestRevision: UInt64 = 0

    /// Creates storage that reads and writes only through the supplied UserDefaults instance.
    init(
        userDefaults: UserDefaults,
        revisionGate: BrowserPersistenceRevisionGate = .settingsShared,
    ) {
        self.userDefaults = userDefaults
        self.revisionGate = revisionGate
    }

    /// Loads Browser preferences, applying the documented defaults for absent or invalid values.
    func load() -> BrowserSettings {
        let storedPreserveOpenTabsValue = userDefaults.object(forKey: BrowserSettingsStorageKeys.preserveOpenTabs)
        let preserveOpenTabs = storedPreserveOpenTabsValue.flatMap { value -> Bool? in
            guard CFGetTypeID(value as CFTypeRef) == CFBooleanGetTypeID() else {
                return nil
            }

            return value as? Bool
        } ?? true
        return BrowserSettings(
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
            preserveOpenTabs: preserveOpenTabs,
            openLinksInNewTabs: userDefaults.string(forKey: BrowserSettingsStorageKeys.openLinksInNewTabs)
                .flatMap(BrowserOpenLinkPreference.init(rawValue:)) ?? .background,
            browsingProfile: userDefaults.string(forKey: BrowserSettingsStorageKeys.browsingProfile)
                .flatMap(BrowserBrowsingProfile.init(rawValue:)) ?? .persistentPrivate,
        )
    }

    /// Persists every Browser-owned preference without touching other application keys.
    func save(_ settings: BrowserSettings) {
        save(settings, revision: revisionGate.reserve(after: newestRevision))
    }

    /// Persists settings only if no newer reducer-issued revision has already arrived.
    func save(_ settings: BrowserSettings, revision: UInt64) {
        revisionGate.perform(revision: revision) {
            guard revision >= newestRevision else {
                return
            }

            newestRevision = revision
            write(settings)
        }
    }

    private func write(_ settings: BrowserSettings) {
        userDefaults.set(settings.searchProvider.rawValue, forKey: BrowserSettingsStorageKeys.searchProvider)
        userDefaults.set(
            settings.providerSuggestionsEnabled,
            forKey: BrowserSettingsStorageKeys.providerSuggestionsEnabled,
        )
        userDefaults.set(
            settings.copiedLinkSuggestionsEnabled,
            forKey: BrowserSettingsStorageKeys.copiedLinkSuggestionsEnabled,
        )
        userDefaults.set(settings.preserveOpenTabs, forKey: BrowserSettingsStorageKeys.preserveOpenTabs)
        userDefaults.set(settings.openLinksInNewTabs.rawValue, forKey: BrowserSettingsStorageKeys.openLinksInNewTabs)
        userDefaults.set(settings.browsingProfile.rawValue, forKey: BrowserSettingsStorageKeys.browsingProfile)
    }

    /// Removes only the namespaced Browser preference keys.
    func reset() {
        reset(revision: revisionGate.reserve(after: newestRevision))
    }

    /// Removes only Browser preferences when the revision is not stale.
    func reset(revision: UInt64) {
        revisionGate.perform(revision: revision) {
            guard revision >= newestRevision else {
                return
            }

            newestRevision = revision
            BrowserSettingsStorageKeys.all.forEach(userDefaults.removeObject(forKey:))
        }
    }
}

private enum BrowserSettingsStorageKeys {
    static let searchProvider = "browser.searchProvider"
    static let providerSuggestionsEnabled = "browser.providerSuggestionsEnabled"
    static let copiedLinkSuggestionsEnabled = "browser.copiedLinkSuggestionsEnabled"
    static let preserveOpenTabs = "browser.preserveOpenTabs"
    static let openLinksInNewTabs = "browser.openLinksInNewTabs"
    static let browsingProfile = "browser.browsingProfile"

    static let all = [
        searchProvider,
        providerSuggestionsEnabled,
        copiedLinkSuggestionsEnabled,
        preserveOpenTabs,
        openLinksInNewTabs,
        browsingProfile,
    ]
}
