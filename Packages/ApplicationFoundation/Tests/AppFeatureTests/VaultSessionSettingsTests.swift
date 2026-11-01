//
//  VaultSessionSettingsTests.swift
//  MediaVault
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Dependencies
import Foundation
import Sharing
import Testing
@testable import VaultFeature

@Suite("Vault session settings persistence")
struct VaultSessionSettingsTests {
    @Test("Missing preferences load the immediate and off defaults")
    func missingPreferencesLoadSafeDefaults() throws {
        let defaults = try isolatedDefaults()
        let client = liveClient(using: defaults)

        #expect(client.load() == VaultSessionSettings())
        #expect(client.load().autoLockTimeout == .immediately)
        #expect(client.load().emergencyLockGesture == .off)
        #expect(client.load().autoLockTimeout.displayName == "Immediately")
        #expect(client.load().emergencyLockGesture.displayName == "Off")
    }

    @Test("Choice labels and persisted raw values remain stable")
    func optionLabelsAndPersistedValuesAreStable() {
        let timeouts: [(VaultAutoLockTimeout, String, String)] = [
            (.immediately, "immediately", "Immediately"),
            (.seconds30, "seconds30", "30 seconds"),
            (.minute1, "minute1", "1 minute"),
            (.minutes5, "minutes5", "5 minutes"),
            (.minutes15, "minutes15", "15 minutes"),
        ]

        for (timeout, rawValue, displayName) in timeouts {
            #expect(timeout.rawValue == rawValue)
            #expect(timeout.displayName == displayName)
        }

        let gestures: [(VaultEmergencyLockGesture, String, String)] = [
            (.off, "off", "Off"),
            (.shake, "shake", "Shake"),
            (.quadrupleTap, "quadrupleTap", "Single-finger quadruple-tap"),
        ]

        for (gesture, rawValue, displayName) in gestures {
            #expect(gesture.rawValue == rawValue)
            #expect(gesture.displayName == displayName)
        }
    }

    @Test("Every supported timeout and gesture round-trips through namespaced storage")
    func supportedValuesRoundTrip() throws {
        let defaults = try isolatedDefaults()
        let client = liveClient(using: defaults)

        for timeout in VaultAutoLockTimeout.allCases {
            for gesture in VaultEmergencyLockGesture.allCases {
                let settings = VaultSessionSettings(
                    autoLockTimeout: timeout,
                    emergencyLockGesture: gesture,
                )

                client.save(settings)

                #expect(defaults.string(forKey: "vault.session.autoLockTimeout") == timeout.rawValue)
                #expect(defaults.string(forKey: "vault.session.emergencyLockGesture") == gesture.rawValue)
                #expect(client.load() == settings)
            }
        }
    }

    @Test("Immediate auto-lock has no grace duration and other choices have their specified durations")
    func timeoutDurationsMatchChoices() {
        #expect(VaultAutoLockTimeout.allCases == [.immediately, .seconds30, .minute1, .minutes5, .minutes15])
        #expect(VaultEmergencyLockGesture.allCases == [.off, .shake, .quadrupleTap])

        let durations: [(VaultAutoLockTimeout, Duration?)] = [
            (.immediately, nil),
            (.seconds30, .seconds(30)),
            (.minute1, .seconds(60)),
            (.minutes5, .seconds(300)),
            (.minutes15, .seconds(900)),
        ]

        for (timeout, duration) in durations {
            #expect(timeout.duration == duration)
        }
    }

    @Test("Unsupported and malformed persisted values fall back independently")
    func invalidPreferencesUseSafeDefaults() throws {
        let defaults = try isolatedDefaults()
        let storage = VaultSessionSettingsStorage(userDefaults: defaults)

        defaults.set("future-timeout", forKey: "vault.session.autoLockTimeout")
        defaults.set("future-gesture", forKey: "vault.session.emergencyLockGesture")
        #expect(storage.load() == VaultSessionSettings())

        defaults.set("minutes5", forKey: "vault.session.autoLockTimeout")
        defaults.set(17, forKey: "vault.session.emergencyLockGesture")
        #expect(storage.load() == VaultSessionSettings(autoLockTimeout: .minutes5))

        defaults.set(false, forKey: "vault.session.autoLockTimeout")
        defaults.set("quadrupleTap", forKey: "vault.session.emergencyLockGesture")
        #expect(storage.load() == VaultSessionSettings(emergencyLockGesture: .quadrupleTap))
    }

    @Test("Saving Vault preferences leaves unrelated app-storage keys unchanged")
    func saveIsNamespaced() throws {
        let defaults = try isolatedDefaults()
        let client = liveClient(using: defaults)
        defaults.set("keep", forKey: "other.feature.key")

        client.save(VaultSessionSettings(autoLockTimeout: .minute1, emergencyLockGesture: .shake))

        #expect(defaults.string(forKey: "other.feature.key") == "keep")
        #expect(defaults.object(forKey: "browser.browsingProfile") == nil)
        #expect(defaults.string(forKey: "vault.session.autoLockTimeout") == "minute1")
        #expect(defaults.string(forKey: "vault.session.emergencyLockGesture") == "shake")
    }

    private func isolatedDefaults() throws -> UserDefaults {
        let suiteName = "VaultSessionSettingsTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    private func liveClient(using defaults: UserDefaults) -> VaultSessionSettingsClient {
        withDependencies {
            $0.defaultAppStorage = defaults
        } operation: {
            VaultSessionSettingsClient.liveValue
        }
    }
}
