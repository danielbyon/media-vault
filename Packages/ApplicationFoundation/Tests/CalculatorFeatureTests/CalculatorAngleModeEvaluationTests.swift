//
//  CalculatorAngleModeEvaluationTests.swift
//  MediaVault
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import CalculatorFeature
import ComposableArchitecture
import Foundation
import Testing

@Suite("Calculator angle-aware evaluation")
@MainActor
struct CalculatorAngleModeEvaluationTests {
    private let entryID = UUID(uuidString: "00000000-0000-0000-0000-000000000061")!
    private let fixedDate = Date(timeIntervalSince1970: 1_725_000_000)

    @Test("Equals evaluates a restored Radians expression in Radians")
    func equalsUsesRestoredAngleMode() async throws {
        let store = makeStore(with: try radiansState(expression: "sin(π/2)"))

        await store.send(.button(.equals)) {
            $0.display = "1"
            $0.expression = "1"
            $0.isShowingResult = true
            $0.history = [
                CalculatorHistoryEntry(
                    id: self.entryID,
                    expression: "sin(π/2)",
                    result: "1",
                    date: self.fixedDate,
                ),
            ]
        }
    }

    @Test("Percent evaluates its operand using the restored Radians mode")
    func percentUsesRestoredAngleMode() async throws {
        let store = makeStore(with: try radiansState(expression: "sin(π/2)"))

        await store.send(.button(.percent)) {
            $0.display = "0.01"
            $0.expression = "sin(π/2)%"
        }
    }

    @Test("Memory evaluates its operand using the restored Radians mode")
    func memoryUsesRestoredAngleMode() async throws {
        let store = makeStore(with: try radiansState(expression: "sin(π/2)", display: ")"))

        await store.send(.button(.memoryAdd)) {
            $0.memory = "1"
        }
    }

    @Test("Paste evaluates an expression using the restored Radians mode")
    func pasteUsesRestoredAngleMode() async throws {
        let store = makeStore(with: try radiansState(expression: "", display: "0"))

        await store.send(.pasted("sin(π/2)")) {
            $0.display = "1"
            $0.expression = "sin(π/2)"
            $0.isShowingResult = true
            $0.history = [
                CalculatorHistoryEntry(
                    id: self.entryID,
                    expression: "sin(π/2)",
                    result: "1",
                    date: self.fixedDate,
                ),
            ]
        }
    }

    private func makeStore(with state: CalculatorFeature.State) -> TestStoreOf<CalculatorFeature> {
        TestStore(initialState: state) {
            CalculatorFeature()
        } withDependencies: {
            $0.calculatorPersistence.load = { nil }
            $0.calculatorPersistence.save = { _ in }
            $0.date.now = self.fixedDate
            $0.uuid = .constant(self.entryID)
        }
    }

    private func radiansState(
        expression: String,
        display: String? = nil,
    ) throws -> CalculatorFeature.State {
        let payload: [String: Any] = [
            "display": display ?? expression,
            "expression": expression,
            "memory": NSNull(),
            "history": [],
            "isShowingResult": false,
            "angleMode": "radians",
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        let snapshot = try JSONDecoder().decode(CalculatorSnapshot.self, from: data)
        return CalculatorFeature.State(snapshot: snapshot)
    }
}
