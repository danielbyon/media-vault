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

    @Test("Browser-originated Settings requests present authenticated settings")
    @MainActor
    func browserSettingsRequestPresentsAuthenticatedSettings() async {
        let store = TestStore(initialState: VaultShellFeature.State(selectedTab: .browser)) {
            VaultShellFeature()
        }

        await store.send(.browser(.settingsTapped)) {
            $0.settingsPresented = true
        }
    }

    @Test("Leaving Browser deactivates its transient presentation state")
    @MainActor
    func leavingBrowserDeactivatesTransientPresentation() async {
        let store = TestStore(initialState: VaultShellFeature.State(selectedTab: .browser)) {
            VaultShellFeature()
        }

        await store.send(.tabSelected(.library)) {
            $0.selectedTab = .library
        }
        await store.receive(.browser(.topLevelDeselected))
    }
}
