//
//  VaultFeatureViewSnapshotTests.swift
//  MediaVault
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import AppFeature
import CalculatorFeature
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

    @Test("A captured hidden candidate keeps the calculator surface at regular iPad width")
    func hiddenCaptureRegularWidthIPad() {
        var state = RootFeature.State(
            calculator: .init(),
            vault: VaultFeature.State(
                phase: .locked,
                configuredKind: .pin,
                usesHiddenEntry: true,
            ),
        )
        state.hiddenEntry = .init(candidate: "1234")
        assertSnapshot(
            of: rootView(state: state),
            as: .image(layout: .device(config: DeterministicTestSupport.regularWidthIPad)),
        )
    }

    @Test("A failed hidden candidate is rendered as ordinary calculator state")
    func failedHiddenCandidateRegularWidthIPad() {
        let calculator = CalculatorFeature.State(
            snapshot: CalculatorSnapshot(
                display: "1234",
                expression: "1234",
                history: [
                    CalculatorHistoryEntry(
                        id: DeterministicTestSupport.referenceUUID,
                        expression: "1234",
                        result: "1234",
                        date: DeterministicTestSupport.referenceDate,
                    ),
                ],
                isShowingResult: true,
            ),
        )
        assertSnapshot(
            of: rootView(
                state: RootFeature.State(
                    calculator: calculator,
                    vault: VaultFeature.State(
                        phase: .locked,
                        configuredKind: .pin,
                        usesHiddenEntry: true,
                    ),
                ),
            ),
            as: .image(layout: .device(config: DeterministicTestSupport.regularWidthIPad)),
        )
    }

    @Test("The authenticated shell exposes its initial library destination")
    func authenticatedShellRegularWidthIPad() {
        assertSnapshot(
            of: rootView(
                state: RootFeature.State(
                    vault: VaultFeature.State(
                        phase: .authenticated,
                        configuredKind: .pin,
                        usesHiddenEntry: true,
                    ),
                ),
            ),
            as: .image(layout: .device(config: DeterministicTestSupport.regularWidthIPad)),
        )
    }

    @Test("The authenticated shell fits a compact phone")
    func authenticatedShellCompactPhone() {
        assertSnapshot(
            of: rootView(state: authenticatedShellState()),
            as: .image(layout: .device(config: DeterministicTestSupport.compactPhone)),
        )
    }

    @Test("The authenticated shell renders its collections destination")
    func authenticatedShellCollectionsRegularWidthIPad() {
        assertSnapshot(
            of: rootView(state: authenticatedShellState(selectedTab: .collections)),
            as: .image(layout: .device(config: DeterministicTestSupport.regularWidthIPad)),
        )
    }

    @Test("The authenticated shell renders its browser destination")
    func authenticatedShellBrowserRegularWidthIPad() {
        assertSnapshot(
            of: rootView(state: authenticatedShellState(selectedTab: .browser)),
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

    private func authenticatedShellState(selectedTab: VaultShellTab = .library) -> RootFeature.State {
        var state = RootFeature.State(
            vault: VaultFeature.State(
                phase: .authenticated,
                configuredKind: .pin,
                usesHiddenEntry: true,
            ),
        )
        state.vault.shell.selectedTab = selectedTab
        return state
    }

    private func rootView(state: RootFeature.State) -> some View {
        let store = withDependencies {
            $0.calculatorPersistence.load = { nil }
            $0.calculatorPersistence.save = { _ in }
        } operation: {
            Store(initialState: state) {
                RootFeature()
            }
        }
        return RootView(store: store)
            .environment(\.colorScheme, .light)
    }
}
