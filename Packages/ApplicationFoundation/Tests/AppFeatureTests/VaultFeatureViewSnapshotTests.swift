//
//  VaultFeatureViewSnapshotTests.swift
//  MediaVault
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import AppFeature
import ComposableArchitecture
import Dependencies
import FoundationTestSupport
import SnapshotTesting
import SwiftUI
import Testing
import VaultFeature

@MainActor
@Suite("Vault feature view snapshots")
struct VaultFeatureViewSnapshotTests {
    @Test("Setup fits the compact phone configuration")
    func setupCompactPhone() {
        assertSnapshot(
            of: credentialView(state: VaultFeature.State(phase: .setup)),
            as: .image(layout: .device(config: DeterministicTestSupport.compactPhone)),
        )
    }

    @Test("Password authentication fits the large phone configuration")
    func authenticationLargePhone() {
        assertSnapshot(
            of: credentialView(
                state: VaultFeature.State(
                    phase: .authentication,
                    configuredKind: .password,
                ),
            ),
            as: .image(layout: .device(config: DeterministicTestSupport.largePhone)),
        )
    }

    @Test("The authenticated shell exposes its initial library destination")
    func authenticatedShellRegularWidthIPad() {
        assertSnapshot(
            of: rootView(
                vault: VaultFeature.State(
                    phase: .authenticated,
                    configuredKind: .pin,
                    usesHiddenEntry: true,
                ),
            ),
            as: .image(layout: .device(config: DeterministicTestSupport.regularWidthIPad)),
        )
    }

    @Test("The authenticated shell fits a compact phone")
    func authenticatedShellCompactPhone() {
        assertSnapshot(
            of: rootView(vault: authenticatedShellState()),
            as: .image(layout: .device(config: DeterministicTestSupport.compactPhone)),
        )
    }

    @Test("The authenticated shell renders its collections destination")
    func authenticatedShellCollectionsRegularWidthIPad() {
        assertSnapshot(
            of: rootView(vault: authenticatedShellState(selectedTab: .collections)),
            as: .image(layout: .device(config: DeterministicTestSupport.regularWidthIPad)),
        )
    }

    @Test("The authenticated shell renders its browser destination")
    func authenticatedShellBrowserRegularWidthIPad() {
        assertSnapshot(
            of: rootView(vault: authenticatedShellState(selectedTab: .browser)),
            as: .image(layout: .device(config: DeterministicTestSupport.regularWidthIPad)),
        )
    }

    private func credentialView(state: VaultFeature.State) -> some View {
        let store = Store(initialState: state) {
            VaultFeature()
        }
        return VaultCredentialView(store: store)
            .environment(\.colorScheme, .light)
    }

    private func authenticatedShellState(selectedTab: VaultShellTab = .library) -> VaultFeature.State {
        var state = VaultFeature.State(
            phase: .authenticated,
            configuredKind: .pin,
            usesHiddenEntry: true,
        )
        state.shell.selectedTab = selectedTab
        return state
    }

    private func rootView(vault: VaultFeature.State) -> some View {
        let store = withDependencies {
            $0.calculatorPersistence.load = { nil }
            $0.calculatorPersistence.save = { _ in }
        } operation: {
            RootComposition.makeStore(vault: vault)
        }
        return RootView(store: store)
            .environment(\.colorScheme, .light)
    }
}
