//
//  CalculatorPresentationTests.swift
//  MediaVault
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import CalculatorFeature
import ComposableArchitecture
import ConcurrencyExtras
import Dependencies
import Testing

@Suite("Calculator presentation projection")
struct CalculatorPresentationTests {
    @Test("Projection matches ordinary digit input from an empty calculator")
    @MainActor
    func matchesEmptyCalculator() async {
        await expectProjectionMatchesOrdinaryInput(from: CalculatorFeature.State())
    }

    @Test("Projection matches ordinary digit input after an expression")
    @MainActor
    func matchesNonEmptyExpression() async {
        var state = CalculatorFeature.State()
        state.display = "4"
        state.expression = "3+4"

        await expectProjectionMatchesOrdinaryInput(from: state)
    }

    @Test("Projection matches ordinary digit input after a completed result")
    @MainActor
    func matchesCompletedResult() async {
        var state = CalculatorFeature.State()
        state.display = "7"
        state.expression = "7"
        state.isShowingResult = true

        await expectProjectionMatchesOrdinaryInput(from: state)
    }

    @Test("Projection matches ordinary digit input that clears an expression error")
    @MainActor
    func matchesErrorState() async {
        var state = CalculatorFeature.State()
        state.display = "1"
        state.expression = "1+"
        state.error = .invalidExpression

        await expectProjectionMatchesOrdinaryInput(from: state)
    }

    @MainActor
    private func expectProjectionMatchesOrdinaryInput(
        from initialState: CalculatorFeature.State,
    ) async {
        let originalState = initialState
        let saveCount = LockIsolated(0)
        let projected = withDependencies {
            $0.calculatorPersistence.save = { _ in
                saveCount.withValue { $0 += 1 }
            }
        } operation: {
            CalculatorFeature.projectedPresentation(
                afterDigits: Self.candidate,
                from: initialState,
            )
        }
        let ordinary = await ordinaryPresentation(from: initialState)

        #expect(projected == ordinary)
        #expect(initialState == originalState)
        #expect(saveCount.value == 0)
    }

    @MainActor
    private func ordinaryPresentation(
        from initialState: CalculatorFeature.State,
    ) async -> CalculatorPresentation {
        let store = TestStore(initialState: initialState) {
            CalculatorFeature()
        } withDependencies: {
            $0.calculatorPersistence.load = { nil }
            $0.calculatorPersistence.save = { _ in }
        }
        store.exhaustivity = .off

        for character in Self.candidate {
            guard let asciiValue = character.asciiValue else {
                continue
            }

            await store.send(.button(.digit(Int(asciiValue - 48))))
        }
        await store.finish()

        return store.state.presentation
    }

    private static let candidate = "1234"
}
