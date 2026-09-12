//
//  CalculatorReducerTests+Restoration.swift
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
    @Test("History is capped while retaining the newest completed calculation")
    @MainActor
    func historyIsCapped() async throws {
        let entries = (0 ..< 20).map { index in
            CalculatorHistoryEntry(
                id: UUID(),
                expression: "\(index)",
                result: "\(index)",
                date: Date(timeIntervalSince1970: TimeInterval(index)),
            )
        }
        let newest = try CalculatorHistoryEntry(
            id: #require(UUID(uuidString: "00000000-0000-0000-0000-000000000007")),
            expression: "1+1",
            result: "2",
            date: Date(timeIntervalSince1970: 1_725_000_004),
        )
        var snapshot = CalculatorSnapshot(display: "1", expression: "1", history: entries)
        snapshot.isShowingResult = false
        let store = TestStore(initialState: CalculatorFeature.State(snapshot: snapshot)) {
            CalculatorFeature()
        } withDependencies: {
            $0.calculatorPersistence.load = { nil }
            $0.calculatorPersistence.save = { _ in }
            $0.date.now = newest.date
            $0.uuid = .constant(newest.id)
        }

        await store.send(.button(.add)) {
            $0.expression = "1+"
        }
        await store.send(.button(.digit(1))) {
            $0.display = "1"
            $0.expression = "1+1"
        }
        await store.send(.button(.equals)) {
            $0.display = "2"
            $0.expression = "2"
            $0.isShowingResult = true
            $0.history = [newest] + Array(entries.dropLast())
        }
    }

    @Test("The reducer restores a persisted snapshot during its first task")
    @MainActor
    func restoresPersistedSnapshot() async {
        let snapshot = CalculatorSnapshot(display: "14", expression: "14", memory: "5")
        let store = TestStore(initialState: CalculatorFeature.State()) {
            CalculatorFeature()
        } withDependencies: {
            $0.calculatorPersistence.load = { snapshot }
            $0.calculatorPersistence.save = { _ in }
        }

        await store.send(.task) {
            $0.isLoading = true
        }
        await store.receive(.loaded(.success(snapshot))) {
            $0.display = "14"
            $0.expression = "14"
            $0.memory = "5"
            $0.isLoading = false
        }
    }

    @Test("Retrying a failed initial load retries loading instead of saving")
    @MainActor
    func retriesFailedInitialLoad() async {
        let snapshot = CalculatorSnapshot(display: "14", expression: "14", memory: "5")
        let loadAttempts = LockIsolated(0)
        let store = TestStore(initialState: CalculatorFeature.State()) {
            CalculatorFeature()
        } withDependencies: {
            $0.calculatorPersistence.load = {
                let attempt = loadAttempts.withValue { count in
                    let attempt = count
                    count += 1
                    return attempt
                }
                if attempt == 0 {
                    throw CalculatorPersistenceError.unavailable
                }
                return snapshot
            }
            $0.calculatorPersistence.save = { _ in
                Issue.record("A failed load retry must not save the current state")
            }
        }

        await store.send(.task) {
            $0.isLoading = true
        }
        await store.receive(.loaded(.failure(.unavailable))) {
            $0.isLoading = false
            $0.persistenceError = .unavailable
        }

        await store.send(.task) {
            $0.isLoading = true
        }
        await store.receive(.loaded(.success(snapshot))) {
            $0.display = "14"
            $0.expression = "14"
            $0.memory = "5"
            $0.isLoading = false
            $0.persistenceError = nil
        }
        #expect(loadAttempts.value == 2)
    }

    @Test("A persisted result starts a new calculation after restoration")
    @MainActor
    func persistedResultStartsNewCalculationAfterRestoration() async throws {
        let testUUID = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000005"))
        let database = try PersistenceStore.makeInMemory()
        let persistence = CalculatorPersistenceClient.forDatabase(database)
        let store = TestStore(initialState: CalculatorFeature.State()) {
            CalculatorFeature()
        } withDependencies: {
            $0.calculatorPersistence.load = { nil }
            $0.calculatorPersistence.save = { _ in }
            $0.date.now = Date(timeIntervalSince1970: 1_725_000_003)
            $0.uuid = .constant(testUUID)
        }

        await completeCalculation(on: store, id: testUUID)

        let completedSnapshot = calculatorSnapshot(from: store.state)
        #expect(completedSnapshot.isShowingResult)
        try await persistence.save(completedSnapshot)

        await store.send(.button(.digit(7))) {
            $0.display = "7"
            $0.expression = "7"
            $0.isShowingResult = false
        }

        let restoredSnapshot = try #require(try await persistence.load())
        #expect(restoredSnapshot == completedSnapshot)
        let restoredStore = makeRestoredStore(with: restoredSnapshot)

        await restoredStore.send(.task) {
            $0.isLoading = true
        }
        await restoredStore.receive(.loaded(.success(restoredSnapshot))) {
            $0.display = "5"
            $0.expression = "5"
            $0.history = completedSnapshot.history
            $0.isShowingResult = true
            $0.isLoading = false
        }
        await restoredStore.send(.button(.digit(7))) {
            $0.display = "7"
            $0.expression = "7"
            $0.isShowingResult = false
        }
    }

    private func calculatorSnapshot(from state: CalculatorFeature.State) -> CalculatorSnapshot {
        CalculatorSnapshot(
            display: state.display,
            expression: state.expression,
            memory: state.memory,
            history: state.history,
            isShowingResult: state.isShowingResult,
        )
    }

    private func completeCalculation(on store: TestStoreOf<CalculatorFeature>, id: UUID) async {
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
        await store.send(.button(.equals)) {
            $0.display = "5"
            $0.expression = "5"
            $0.isShowingResult = true
            $0.history = [
                CalculatorHistoryEntry(
                    id: id,
                    expression: "2+3",
                    result: "5",
                    date: Date(timeIntervalSince1970: 1_725_000_003),
                ),
            ]
        }
    }

    @MainActor
    private func makeRestoredStore(with snapshot: CalculatorSnapshot) -> TestStoreOf<CalculatorFeature> {
        TestStore(initialState: CalculatorFeature.State()) {
            CalculatorFeature()
        } withDependencies: {
            $0.calculatorPersistence.load = { snapshot }
            $0.calculatorPersistence.save = { _ in }
        }
    }
}
