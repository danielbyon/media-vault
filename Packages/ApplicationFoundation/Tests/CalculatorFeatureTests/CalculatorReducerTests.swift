//
//  CalculatorReducerTests.swift
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

@Suite("Calculator reducer")
struct CalculatorReducerTests {
    @Test("The reducer evaluates an expression and records history")
    @MainActor
    func evaluatesExpressionAndRecordsHistory() async throws {
        let testUUID = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000002"))
        let store = TestStore(initialState: CalculatorFeature.State()) {
            CalculatorFeature()
        } withDependencies: {
            $0.calculatorPersistence.load = { nil }
            $0.calculatorPersistence.save = { _ in }
            $0.date.now = Date(timeIntervalSince1970: 1_725_000_000)
            $0.uuid = .constant(testUUID)
        }

        await store.send(.button(.digit(2))) {
            $0.display = "2"
            $0.expression = "2"
        }
        await store.send(.button(.add)) {
            $0.expression = "2+"
        }
        await store.send(.button(.digit(3))) {
            $0.display = "3"
            $0.expression = "2+3"
        }
        await store.send(.button(.multiply)) {
            $0.expression = "2+3×"
        }
        await store.send(.button(.digit(4))) {
            $0.display = "4"
            $0.expression = "2+3×4"
        }
        await store.send(.button(.equals)) {
            $0.display = "14"
            $0.expression = "14"
            $0.isShowingResult = true
            $0.history = [
                CalculatorHistoryEntry(
                    id: testUUID,
                    expression: "2+3×4",
                    result: "14",
                    date: Date(timeIntervalSince1970: 1_725_000_000),
                ),
            ]
        }

        await store.send(.button(.clearHistory)) {
            $0.history = []
        }
    }

    @Test("The reducer constructs and evaluates nested parenthesized expressions")
    @MainActor
    func constructsAndEvaluatesNestedParenthesizedExpressions() async throws {
        let testUUID = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000004"))
        let store = TestStore(initialState: CalculatorFeature.State()) {
            CalculatorFeature()
        } withDependencies: {
            $0.calculatorPersistence.load = { nil }
            $0.calculatorPersistence.save = { _ in }
            $0.date.now = Date(timeIntervalSince1970: 1_725_000_001)
            $0.uuid = .constant(testUUID)
        }

        await store.send(.button(.openParenthesis)) {
            $0.display = "("
            $0.expression = "("
        }
        await store.send(.button(.digit(2))) {
            $0.display = "2"
            $0.expression = "(2"
        }
        await store.send(.button(.multiply)) {
            $0.expression = "(2×"
        }
        await store.send(.button(.openParenthesis)) {
            $0.display = "("
            $0.expression = "(2×("
        }
        await store.send(.button(.digit(3))) {
            $0.display = "3"
            $0.expression = "(2×(3"
        }
        await store.send(.button(.add)) {
            $0.expression = "(2×(3+"
        }
        await store.send(.button(.digit(4))) {
            $0.display = "4"
            $0.expression = "(2×(3+4"
        }
        await store.send(.button(.closeParenthesis)) {
            $0.display = ")"
            $0.expression = "(2×(3+4)"
        }
        await store.send(.button(.closeParenthesis)) {
            $0.display = ")"
            $0.expression = "(2×(3+4))"
        }
        await store.send(.button(.equals)) {
            $0.display = "14"
            $0.expression = "14"
            $0.isShowingResult = true
            $0.history = [
                CalculatorHistoryEntry(
                    id: testUUID,
                    expression: "(2×(3+4))",
                    result: "14",
                    date: Date(timeIntervalSince1970: 1_725_000_001),
                ),
            ]
        }
    }

    @Test("The reducer reports an unbalanced parenthesis as an invalid expression")
    @MainActor
    func reportsUnbalancedParenthesis() async {
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
        await store.send(.button(.equals)) {
            $0.error = .invalidExpression
        }
    }

    @Test("The reducer handles decimal, sign, percent, and memory controls")
    @MainActor
    func handlesCoreEditingAndMemoryControls() async {
        let store = TestStore(initialState: CalculatorFeature.State()) {
            CalculatorFeature()
        } withDependencies: {
            $0.calculatorPersistence.load = { nil }
            $0.calculatorPersistence.save = { _ in }
        }

        await store.send(.button(.digit(1))) {
            $0.display = "1"
            $0.expression = "1"
        }
        await store.send(.button(.decimal)) {
            $0.display = "1."
            $0.expression = "1."
        }
        await store.send(.button(.digit(5))) {
            $0.display = "1.5"
            $0.expression = "1.5"
        }
        await store.send(.button(.sign)) {
            $0.display = "-1.5"
            $0.expression = "-1.5"
        }
        await store.send(.button(.percent)) {
            $0.display = "-0.015"
            $0.expression = "-1.5%"
        }
        await store.send(.button(.memoryAdd)) {
            $0.memory = "-0.015"
        }
        await store.send(.button(.clear)) {
            $0.display = "0"
            $0.expression = ""
            $0.isShowingResult = false
        }
        await store.send(.button(.memoryRecall)) {
            $0.display = "-0.015"
            $0.expression = "-0.015"
            $0.isShowingResult = false
        }
        await store.send(.button(.memoryClear)) {
            $0.memory = nil
        }
    }
}
