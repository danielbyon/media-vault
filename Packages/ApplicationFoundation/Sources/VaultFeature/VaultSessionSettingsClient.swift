//
//  VaultSessionSettingsClient.swift
//  MediaVault
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Dependencies
import Foundation
import Sharing

/// Injectable synchronous access to persisted vault session preferences.
public struct VaultSessionSettingsClient: Sendable {
    /// Loads the current preferences, applying safe defaults to missing or invalid values.
    public var load: @Sendable () -> VaultSessionSettings
    /// Persists the selected auto-lock timeout and emergency gesture.
    public var save: @Sendable (VaultSessionSettings) -> Void

    /// Creates a client from synchronous load and save operations.
    public init(
        load: @escaping @Sendable () -> VaultSessionSettings,
        save: @escaping @Sendable (VaultSessionSettings) -> Void,
    ) {
        self.load = load
        self.save = save
    }
}

extension VaultSessionSettingsClient: DependencyKey {
    /// Creates a client backed by the app-storage dependency active at resolution time.
    public static var liveValue: Self {
        @Dependency(\.defaultAppStorage)
        var defaultAppStorage
        let storage = VaultSessionSettingsStorage(userDefaults: defaultAppStorage)
        return Self(
            load: { storage.load() },
            save: { storage.save($0) },
        )
    }

    /// Deterministic default client used unless a test supplies an override.
    public static let testValue = Self(load: { .init() }, save: { _ in })
}

extension DependencyValues {
    /// Reducer-facing persistence dependency for authenticated vault session preferences.
    public var vaultSessionSettings: VaultSessionSettingsClient {
        get { self[VaultSessionSettingsClient.self] }
        set { self[VaultSessionSettingsClient.self] = newValue }
    }
}

/// Concrete storage that reads and writes only the two vault session preference keys.
/// `UserDefaults` synchronizes its own operations, so the immutable reference can be shared safely.
struct VaultSessionSettingsStorage: @unchecked Sendable {
    private let userDefaults: UserDefaults

    /// Creates settings storage backed by the supplied defaults suite.
    init(userDefaults: UserDefaults) {
        self.userDefaults = userDefaults
    }

    /// Loads supported values and uses immediate auto-lock and no gesture for invalid values.
    func load() -> VaultSessionSettings {
        let autoLockTimeout = (userDefaults.object(forKey: VaultSessionSettingsStorageKeys.autoLockTimeout) as? String)
            .flatMap(VaultAutoLockTimeout.init(rawValue:)) ?? .immediately
        let emergencyLockGesture = (
            userDefaults.object(forKey: VaultSessionSettingsStorageKeys.emergencyLockGesture) as? String,
        )
        .flatMap(VaultEmergencyLockGesture.init(rawValue:)) ?? .off

        return VaultSessionSettings(
            autoLockTimeout: autoLockTimeout,
            emergencyLockGesture: emergencyLockGesture,
        )
    }

    /// Saves both Vault-owned preferences without modifying unrelated defaults keys.
    func save(_ settings: VaultSessionSettings) {
        userDefaults.set(
            settings.autoLockTimeout.rawValue,
            forKey: VaultSessionSettingsStorageKeys.autoLockTimeout,
        )
        userDefaults.set(
            settings.emergencyLockGesture.rawValue,
            forKey: VaultSessionSettingsStorageKeys.emergencyLockGesture,
        )
    }
}

/// Stable keys keep session preferences separate from other app settings.
private enum VaultSessionSettingsStorageKeys {
    static let autoLockTimeout = "vault.session.autoLockTimeout"
    static let emergencyLockGesture = "vault.session.emergencyLockGesture"
}
