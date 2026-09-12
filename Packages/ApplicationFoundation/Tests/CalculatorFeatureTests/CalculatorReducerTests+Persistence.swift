//
//  CalculatorReducerTests+Persistence.swift
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
    @Test("History remains available until the clear-history action")
    @MainActor
    func historyRequiresExplicitClear() async throws {
        let entry = try CalculatorHistoryEntry(
            id: #require(UUID(uuidString: "00000000-0000-0000-0000-000000000006")),
            expression: "1+1",
            result: "2",
            date: Date(timeIntervalSince1970: 1_725_000_002),
        )
        let store = TestStore(
            initialState: CalculatorFeature.State(
                snapshot: CalculatorSnapshot(history: [entry]),
            ),
        ) {
            CalculatorFeature()
        } withDependencies: {
            $0.calculatorPersistence.load = { nil }
            $0.calculatorPersistence.save = { _ in }
        }

        await store.send(.button(.clear))
        #expect(store.state.history == [entry])
        await store.send(.button(.clearHistory)) {
            $0.history = []
        }
    }

    @Test("Editing is blocked while the initial persistence load is in flight")
    @MainActor
    func blocksEditingWhileLoading() async {
        var initialState = CalculatorFeature.State()
        initialState.isLoading = true
        let store = TestStore(initialState: initialState) {
            CalculatorFeature()
        } withDependencies: {
            $0.calculatorPersistence.load = { nil }
            $0.calculatorPersistence.save = { _ in }
        }

        await store.send(.button(.digit(3)))
    }

    @Test("A persistence retry preserves dirty state and clears after a later save succeeds")
    @MainActor
    func persistenceFailureClearsAfterSuccessfulSave() async {
        let failNextSave = LockIsolated(true)
        let store = TestStore(initialState: CalculatorFeature.State()) {
            CalculatorFeature()
        } withDependencies: {
            $0.calculatorPersistence.load = {
                CalculatorSnapshot(display: "0", expression: "")
            }
            $0.calculatorPersistence.save = { _ in
                if failNextSave.value {
                    failNextSave.setValue(false)
                    throw CalculatorPersistenceError.unavailable
                }
            }
        }

        await store.send(.button(.digit(1))) {
            $0.display = "1"
            $0.expression = "1"
        }
        await store.receive(.persistenceFailed) {
            $0.persistenceError = .unavailable
        }

        await store.send(.task)
        await store.receive(.persistenceSucceeded) {
            $0.persistenceError = nil
        }

        await store.send(.button(.digit(2))) {
            $0.display = "12"
            $0.expression = "12"
        }
    }

    @Test("Rapid edits persist the newest pending calculator snapshot")
    @MainActor
    func rapidEditsPersistNewestSnapshot() async {
        let firstSaveStarted = AsyncStream<Void>.makeStream()
        let releaseFirstSave = AsyncStream<Void>.makeStream()
        let completedSaves = AsyncStream<CalculatorSnapshot>.makeStream()
        let saveCount = LockIsolated(0)
        var firstSaveIterator = firstSaveStarted.stream.makeAsyncIterator()
        var completedSaveIterator = completedSaves.stream.makeAsyncIterator()

        let store = TestStore(initialState: CalculatorFeature.State()) {
            CalculatorFeature()
        } withDependencies: {
            $0.calculatorPersistence.load = { nil }
            $0.calculatorPersistence.save = { snapshot in
                let call = saveCount.withValue { count in
                    let call = count
                    count += 1
                    return call
                }
                if call == 0 {
                    firstSaveStarted.continuation.yield(())
                    var releaseIterator = releaseFirstSave.stream.makeAsyncIterator()
                    _ = await releaseIterator.next()
                }
                completedSaves.continuation.yield(snapshot)
            }
        }

        await store.send(.button(.digit(1))) {
            $0.display = "1"
            $0.expression = "1"
        }
        _ = await firstSaveIterator.next()

        await store.send(.button(.digit(2))) {
            $0.display = "12"
            $0.expression = "12"
        }
        releaseFirstSave.continuation.yield(())

        _ = await completedSaveIterator.next()
        let newest = await completedSaveIterator.next()
        #expect(newest?.display == "12")
        #expect(newest?.expression == "12")
        await store.finish()
    }
}
