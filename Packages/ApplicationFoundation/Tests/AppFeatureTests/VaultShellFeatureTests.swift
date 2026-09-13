//
//  VaultShellFeatureTests.swift
//  MediaVault
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import ComposableArchitecture
import Testing
@testable import VaultFeature

@Suite("Vault shell")
struct VaultShellFeatureTests {
    @Test("Top-level destinations and navigation-presented settings are independently controllable")
    @MainActor
    func navigationStateTracksTabsAndSettings() async {
        let store = TestStore(initialState: VaultShellFeature.State()) {
            VaultShellFeature()
        }

        await store.send(.tabSelected(.collections)) {
            $0.selectedTab = .collections
        }
        await store.send(.tabSelected(.browser)) {
            $0.selectedTab = .browser
        }
        await store.send(.settingsTapped) {
            $0.settingsPresented = true
        }
        await store.send(.settingsDismissed) {
            $0.settingsPresented = false
        }
    }
}
