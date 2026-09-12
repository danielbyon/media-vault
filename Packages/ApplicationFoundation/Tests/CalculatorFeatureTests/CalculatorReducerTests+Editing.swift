//
//  CalculatorReducerTests+Editing.swift
//  MediaVault
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import CalculatorFeature
import ComposableArchitecture
import ConcurrencyExtras
import Dependencies
import Foundation
import PersistenceSupport
import Testing

extension CalculatorReducerTests {
    @Test("Sign toggles a completed result and a negative operand")
    @MainActor
    func signTogglesResultsAndNegativeOperands() async {
        let store = TestStore(
            initialState: CalculatorFeature.State(
                snapshot: CalculatorSnapshot(display: "5", expression: "5", isShowingResult: true),
            ),
        ) {
            CalculatorFeature()
        } withDependencies: {
            $0.calculatorPersistence.load = { nil }
            $0.calculatorPersistence.save = { _ in }
        }

        await store.send(.button(.sign)) {
            $0.display = "-5"
            $0.expression = "-5"
            $0.isShowingResult = false
        }
        await store.send(.button(.sign)) {
            $0.display = "5"
            $0.expression = "5"
        }

        await store.send(.button(.add)) {
            $0.expression = "5+"
        }
        await store.send(.button(.sign)) {
            $0.display = "-"
            $0.expression = "5+-"
        }
        await store.send(.button(.digit(3))) {
            $0.display = "-3"
            $0.expression = "5+-3"
        }
        await store.send(.button(.sign)) {
            $0.display = "3"
            $0.expression = "5+3"
        }
    }

    @Test("Toggling the sign twice on a fresh calculator restores zero")
    @MainActor
    func signTwiceRestoresFreshState() async {
        let store = TestStore(initialState: CalculatorFeature.State()) {
            CalculatorFeature()
        } withDependencies: {
            $0.calculatorPersistence.load = { nil }
            $0.calculatorPersistence.save = { _ in }
        }

        await store.send(.button(.sign)) {
            $0.display = "-"
            $0.expression = "-"
        }
        await store.send(.button(.sign)) {
            $0.display = "0"
            $0.expression = ""
        }
    }

    @Test("An arithmetic operator preserves a completed result as its left operand")
    @MainActor
    func operatorPreservesCompletedResult() async {
        let store = TestStore(
            initialState: CalculatorFeature.State(
                snapshot: CalculatorSnapshot(display: "5", expression: "5", isShowingResult: true),
            ),
        ) {
            CalculatorFeature()
        } withDependencies: {
            $0.calculatorPersistence.load = { nil }
            $0.calculatorPersistence.save = { _ in }
        }

        await store.send(.button(.add)) {
            $0.expression = "5+"
            $0.isShowingResult = false
        }
        await store.send(.button(.digit(2))) {
            $0.display = "2"
            $0.expression = "5+2"
        }
    }

    @Test("Repeated equals does not duplicate a completed history entry")
    @MainActor
    func repeatedEqualsDoesNotDuplicateHistory() async throws {
        let entry = try CalculatorHistoryEntry(
            id: #require(UUID(uuidString: "00000000-0000-0000-0000-000000000009")),
            expression: "2+3",
            result: "5",
            date: Date(timeIntervalSince1970: 1_725_000_006),
        )
        let store = TestStore(
            initialState: CalculatorFeature.State(snapshot: CalculatorSnapshot(display: "2+3", expression: "2+3")),
        ) {
            CalculatorFeature()
        } withDependencies: {
            $0.calculatorPersistence.load = { nil }
            $0.calculatorPersistence.save = { _ in }
            $0.date.now = entry.date
            $0.uuid = .constant(entry.id)
        }

        await store.send(.button(.equals)) {
            $0.display = "5"
            $0.expression = "5"
            $0.isShowingResult = true
            $0.history = [entry]
        }
        await store.send(.button(.equals))
        #expect(store.state.history == [entry])
    }

    @Test("A non-minus operator is rejected after an opening parenthesis")
    @MainActor
    func rejectsOperatorAfterOpeningParenthesis() async {
        let store = TestStore(initialState: CalculatorFeature.State()) {
            CalculatorFeature()
        } withDependencies: {
            $0.calculatorPersistence.load = { nil }
            $0.calculatorPersistence.save = { _ in }
        }

        await store.send(.button(.openParenthesis)) {
            $0.display = "("
            $0.expression = "("
        }
        await store.send(.button(.add))
        await store.send(.button(.subtract)) {
            $0.expression = "(-"
        }
    }

    @Test("Memory operations evaluate a closed parenthesized expression")
    @MainActor
    func memoryUsesClosedExpressionValue() async {
        let store = TestStore(initialState: CalculatorFeature.State()) {
            CalculatorFeature()
        } withDependencies: {
            $0.calculatorPersistence.load = { nil }
            $0.calculatorPersistence.save = { _ in }
        }

        await store.send(.button(.openParenthesis)) {
            $0.display = "("
            $0.expression = "("
        }
        await store.send(.button(.digit(2))) {
            $0.display = "2"
            $0.expression = "(2"
        }
        await store.send(.button(.add)) {
            $0.expression = "(2+"
        }
        await store.send(.button(.digit(3))) {
            $0.display = "3"
            $0.expression = "(2+3"
        }
        await store.send(.button(.closeParenthesis)) {
            $0.display = ")"
            $0.expression = "(2+3)"
        }
        await store.send(.button(.memoryAdd)) {
            $0.memory = "5"
        }
        await store.send(.button(.memorySubtract)) {
            $0.memory = "0"
        }
    }
}
