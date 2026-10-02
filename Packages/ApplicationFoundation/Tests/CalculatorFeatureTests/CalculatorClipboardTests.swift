//
//  CalculatorClipboardTests.swift
//  MediaVault
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import CalculatorFeature
import ComposableArchitecture
import ConcurrencyExtras
import Foundation
import Testing

@Suite("Calculator clipboard behavior")
struct CalculatorClipboardTests {
    @Test("Copy uses the current display and paste uses normal calculator parsing")
    @MainActor
    func copyAndPasteAreInjected() async throws {
        let copied = LockIsolated<String?>(nil)
        let testUUID = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000008"))
        let store = TestStore(initialState: CalculatorFeature.State()) {
            CalculatorFeature()
        } withDependencies: {
            $0.calculatorPersistence.load = { nil }
            $0.calculatorPersistence.save = { _ in }
            $0.calculatorClipboard.copy = { copied.setValue($0) }
            $0.calculatorClipboard.paste = { "9×2" }
            $0.date.now = Date(timeIntervalSince1970: 1_725_000_005)
            $0.uuid = .constant(testUUID)
        }

        await store.send(.button(.digit(7))) {
            $0.display = "7"
            $0.expression = "7"
        }
        await store.send(.button(.copy))
        #expect(copied.value == "7")

        await store.send(.button(.paste))
        await store.receive(.pasted("9×2")) {
            $0.display = "18"
            $0.expression = "9×2"
            $0.isShowingResult = true
            $0.history = [
                CalculatorHistoryEntry(
                    id: testUUID,
                    expression: "9×2",
                    result: "18",
                    date: Date(timeIntervalSince1970: 1_725_000_005),
                ),
            ]
        }
    }

    @Test("Malformed pasted input is rejected without replacing the current value")
    @MainActor
    func malformedPasteFailsSafely() async {
        let store = TestStore(
            initialState: CalculatorFeature.State(
                snapshot: CalculatorSnapshot(display: "7", expression: "7"),
            ),
        ) {
            CalculatorFeature()
        } withDependencies: {
            $0.calculatorPersistence.load = { nil }
            $0.calculatorPersistence.save = { _ in }
            $0.calculatorClipboard.paste = { "not a calculation" }
        }

        await store.send(.button(.paste))
        await store.receive(.pasted("not a calculation")) {
            $0.error = .invalidExpression
        }
    }

    @Test("An operator after a pasted result continues from the displayed value")
    @MainActor
    func operatorAfterPastedResultContinuesFromTheDisplayedValue() async throws {
        let testUUID = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000009"))
        let timestamp = Date(timeIntervalSince1970: 1_725_000_006)
        let store = TestStore(initialState: CalculatorFeature.State()) {
            CalculatorFeature()
        } withDependencies: {
            $0.calculatorPersistence.load = { nil }
            $0.calculatorPersistence.save = { _ in }
            $0.calculatorClipboard.paste = { "2+3" }
            $0.date.now = timestamp
            $0.uuid = .constant(testUUID)
        }

        await store.send(.button(.paste))
        await store.receive(.pasted("2+3")) {
            $0.display = "5"
            $0.expression = "2+3"
            $0.isShowingResult = true
            $0.history = [
                CalculatorHistoryEntry(
                    id: testUUID,
                    expression: "2+3",
                    result: "5",
                    date: timestamp,
                ),
            ]
        }
        // The pasted source stops describing the edited expression once its result is shown.
        await store.send(.button(.power)) {
            $0.expression = "5^"
            $0.isShowingResult = false
        }
        await store.send(.button(.digit(2))) {
            $0.display = "2"
            $0.expression = "5^2"
        }
        await store.send(.button(.equals)) {
            $0.display = "25"
            $0.expression = "25"
            $0.isShowingResult = true
            $0.history.insert(
                CalculatorHistoryEntry(
                    id: testUUID,
                    expression: "5^2",
                    result: "25",
                    date: timestamp,
                ),
                at: 0,
            )
        }
    }
}
