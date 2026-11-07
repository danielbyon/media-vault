//
//  VaultShellFeatureTests.swift
//  MediaVault
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import BrowserFeature
import ComposableArchitecture
import MediaLibrary
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

    @Test("A locked shell rejects private navigation and settings actions")
    @MainActor
    func lockedShellRejectsNavigationAndSettings() async {
        var state = VaultShellFeature.State(isSessionLocked: true)
        state.library.isSessionLocked = true
        state.browser.isSessionLocked = true
        let store = TestStore(initialState: state) {
            VaultShellFeature()
        }

        await store.send(.tabSelected(.browser))
        await store.send(.settingsTapped)
        await store.send(.browser(.settingsTapped))

        #expect(store.state.isSessionLocked)
        #expect(store.state.selectedTab == .library)
        #expect(!store.state.settingsPresented)
    }
}
