//
//  RootFeatureTests.swift
//  MediaVault
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import AppFeature
import CalculatorFeature
import ComposableArchitecture
import Dependencies
import Foundation
import FoundationTestSupport
import Testing
import VaultFeature

@Suite("Root feature")
struct RootFeatureTests {
    @Test("A long press on equals opens setup without evaluating the calculator")
    @MainActor
    func longPressEqualsStartsSetupWithoutCalculatorMutation() async {
        let store = makeRootStore(vault: VaultFeature.State(phase: .unconfigured))

        await store.send(.calculatorInput(.longPressEquals))
        await store.receive(.vault(.beginSetup)) {
            $0.vault.phase = .setup
        }
        #expect(store.state.calculator == CalculatorFeature.State())
    }

    @Test("A normal equals remains an ordinary calculator action while unconfigured")
    @MainActor
    func normalEqualsRemainsCalculatorActionWhenUnconfigured() async {
        let calculator = CalculatorFeature.State(
            snapshot: CalculatorSnapshot(
                display: "4",
                expression: "3+4",
                isShowingResult: false,
            ),
        )
        let store = makeRootStore(
            vault: VaultFeature.State(phase: .unconfigured),
            calculator: calculator,
        )

        await store.send(.calculatorInput(.button(.equals)))
        await store.receive(.calculator(.button(.equals))) {
            $0.calculator.display = "7"
            $0.calculator.expression = "7"
            $0.calculator.isShowingResult = true
            $0.calculator.history = [
                CalculatorHistoryEntry(
                    id: DeterministicTestSupport.referenceUUID,
                    expression: "3+4",
                    result: "7",
                    date: DeterministicTestSupport.referenceDate,
                ),
            ]
        }

        #expect(store.state.vault.phase == .unconfigured)
    }

    @Test("An unavailable credential state never opens setup")
    @MainActor
    func unavailableCredentialStateDoesNotStartSetup() async {
        let store = makeRootStore(vault: VaultFeature.State(phase: .unavailable))

        await store.send(.calculatorInput(.longPressEquals))

        #expect(store.state.vault.phase == .unavailable)
        #expect(store.state.calculator == CalculatorFeature.State())
    }

    @Test("A configured password uses authentication instead of PIN-equals capture")
    @MainActor
    func passwordLongPressStartsAuthentication() async {
        let calculator = CalculatorFeature.State(
            snapshot: CalculatorSnapshot(display: "5", expression: "5", isShowingResult: true),
        )
        let store = makeRootStore(
            vault: VaultFeature.State(
                phase: .locked,
                configuredKind: .password,
                usesHiddenEntry: false,
            ),
            calculator: calculator,
        )

        await store.send(.calculatorInput(.longPressEquals))
        await store.receive(.vault(.beginAuthentication)) {
            $0.vault.phase = .authentication
        }
        #expect(store.state.calculator == calculator)
    }

    @Test("A configured PIN long press starts authentication instead of capture")
    @MainActor
    func pinLongPressStartsAuthentication() async throws {
        let entry = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000013"))
        let calculator = CalculatorFeature.State(
            snapshot: CalculatorSnapshot(
                display: "7",
                expression: "3+4",
                memory: "9",
                history: [
                    CalculatorHistoryEntry(
                        id: entry,
                        expression: "2+5",
                        result: "7",
                        date: DeterministicTestSupport.referenceDate,
                    ),
                ],
                isShowingResult: false,
            ),
        )
        let store = makeRootStore(
            vault: VaultFeature.State(
                phase: .locked,
                configuredKind: .pin,
                usesHiddenEntry: true,
            ),
            calculator: calculator,
        )

        await store.send(.calculatorInput(.longPressEquals))
        await store.receive(.vault(.beginAuthentication)) {
            $0.vault.phase = .authentication
        }

        #expect(store.state.hiddenEntry == nil)
        #expect(store.state.calculator == calculator)
    }
}
