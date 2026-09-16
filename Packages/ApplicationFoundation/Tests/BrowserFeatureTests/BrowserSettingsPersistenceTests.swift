//
//  BrowserSettingsPersistenceTests.swift
//  MediaVault
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import ComposableArchitecture
@preconcurrency import Foundation
import Testing
@testable import BrowserFeature

@Suite("Browser settings persistence")
struct BrowserSettingsPersistenceTests {
    @Test("An isolated app-storage suite loads Browser defaults when no keys exist")
    func loadsDefaultsFromIsolatedAppStorage() async throws {
        let defaults = try isolatedDefaults()
        let client = liveClient(using: defaults)

        #expect(await client.load() == BrowserSettings())
    }

    @Test("Browser settings save and load form an isolated round trip")
    func savesAndLoadsRoundTrip() async throws {
        let defaults = try isolatedDefaults()
        let client = liveClient(using: defaults)
        let settings = BrowserSettings(
            searchProvider: .bing,
            providerSuggestionsEnabled: true,
            copiedLinkSuggestionsEnabled: false,
            openLinksInNewTabs: .foreground,
        )

        await client.save(settings)

        #expect(await client.load() == settings)
    }

    @Test("Reset removes only Browser-owned namespaced keys")
    func resetPreservesOtherAppStorage() async throws {
        let defaults = try isolatedDefaults()
        defaults.set("keep", forKey: "other.feature.key")
        let client = liveClient(using: defaults)

        await client.save(BrowserSettings(
            searchProvider: .google,
            providerSuggestionsEnabled: true,
            copiedLinkSuggestionsEnabled: false,
            openLinksInNewTabs: .foreground,
        ))
        await client.reset()

        #expect(defaults.object(forKey: "browser.searchProvider") == nil)
        #expect(defaults.object(forKey: "browser.providerSuggestionsEnabled") == nil)
        #expect(defaults.object(forKey: "browser.copiedLinkSuggestionsEnabled") == nil)
        #expect(defaults.object(forKey: "browser.openLinksInNewTabs") == nil)
        #expect(defaults.string(forKey: "other.feature.key") == "keep")
    }

    @Test("Copied-link suggestions default to enabled when their key is absent")
    func copiedLinkDefaultIsTrueWhenAbsent() async throws {
        let defaults = try isolatedDefaults()
        defaults.removeObject(forKey: "browser.copiedLinkSuggestionsEnabled")
        let client = liveClient(using: defaults)

        let settings = await client.load()
        #expect(settings.copiedLinkSuggestionsEnabled)
    }

    @Test("One isolated app-storage suite cannot bleed preferences into another")
    func isolatedSuitesDoNotBleed() async throws {
        let first = try isolatedDefaults()
        let second = try isolatedDefaults()
        let firstClient = liveClient(using: first)
        let secondClient = liveClient(using: second)

        await firstClient.save(BrowserSettings(searchProvider: .google))

        let firstSettings = await firstClient.load()
        let secondSettings = await secondClient.load()
        #expect(firstSettings.searchProvider == .google)
        #expect(secondSettings.searchProvider == .duckDuckGo)
    }

    @Test("The concrete settings storage uses the injected UserDefaults instance")
    func concreteStorageUsesInjectedDefaults() async throws {
        let defaults = try isolatedDefaults()
        let storage = BrowserSettingsStorage(userDefaults: defaults)

        await storage.save(BrowserSettings(searchProvider: .bing))

        let settings = await storage.load()
        #expect(settings.searchProvider == .bing)
    }

    private func isolatedDefaults() throws -> UserDefaults {
        let suiteName = "BrowserSettingsPersistenceTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    private func liveClient(using defaults: UserDefaults) -> BrowserSettingsClient {
        withDependencies {
            $0.defaultAppStorage = defaults
        } operation: {
            BrowserSettingsClient.liveValue
        }
    }
}
