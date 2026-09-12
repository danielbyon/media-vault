//
//  CalculatorFeature.swift
//  MediaVault
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import ComposableArchitecture
import Dependencies
import Foundation

/// The issue #3 calculator reducer.
///
/// The reducer owns calculator editing, evaluation, memory, history, clipboard actions, and the
/// calculator-only persistence boundary. Numeric parsing is delegated to ``CalculatorEngine`` so
/// the feature interface can grow without making the current Decimal implementation permanent.
@Reducer
public struct CalculatorFeature {
    /// The calculator state rendered by ``CalculatorView``.
    @ObservableState
    public struct State: Equatable, Sendable {
        /// The value currently shown on the calculator display.
        public var display: String

        /// The expression currently being edited or the last completed result.
        public var expression: String

        /// The calculator's stored memory value, when one exists.
        public var memory: String?

        /// The completed calculations retained by the calculator.
        public var history: [CalculatorHistoryEntry]

        /// The current expression error, when the last action failed.
        public var error: CalculatorError?

        /// The persistence error reported by the last load or save operation.
        public var persistenceError: CalculatorPersistenceError?

        /// Whether the initial persistence load is in flight.
        public var isLoading: Bool

        /// Whether the current display represents a completed calculation.
        public var isShowingResult: Bool

        /// Creates the initial calculator state or restores a previously saved snapshot.
        ///
        /// - Parameter snapshot: An optional persisted snapshot to restore.
        public init(snapshot: CalculatorSnapshot? = nil) {
            display = snapshot?.display ?? "0"
            expression = snapshot?.expression ?? ""
            memory = snapshot?.memory
            history = snapshot?.history ?? []
            error = nil
            persistenceError = nil
            isLoading = false
            isShowingResult = snapshot?.isShowingResult ?? false
        }

        var snapshot: CalculatorSnapshot {
            CalculatorSnapshot(
                display: display,
                expression: expression,
                memory: memory,
                history: history,
                isShowingResult: isShowingResult,
            )
        }
    }

    /// User and lifecycle actions handled by the calculator reducer.
    public enum Action: Equatable, Sendable {
        /// Starts or retries the initial persistence load.
        case task

        /// Delivers the result of the initial persistence load.
        case loaded(Result<CalculatorSnapshot?, CalculatorPersistenceError>)

        /// Applies a calculator button action.
        case button(CalculatorButton)

        /// Delivers a value read from the clipboard.
        case pasted(String?)

        /// Reports that the latest persistence save succeeded.
        case persistenceSucceeded

        /// Reports that the latest persistence save failed.
        case persistenceFailed
    }

    static let maximumHistoryCount = 20

    let persistenceCoordinator: CalculatorPersistenceCoordinator
    @Dependency(\.calculatorClipboard)
    var clipboard
    @Dependency(\.calculatorPersistence)
    var persistence
    @Dependency(\.date.now)
    var now
    @Dependency(\.uuid)
    var uuid

    /// Creates a calculator reducer with its persistence coordinator.
    public init() {
        persistenceCoordinator = CalculatorPersistenceCoordinator()
    }

    /// Handles lifecycle, input, evaluation, and persistence actions.
    public var body: some ReducerOf<Self> {
        Reduce { state, action in
            handle(into: &state, action: action)
        }
    }

    /// Persists the latest snapshot, superseding any save still in flight for a prior edit.
    ///
    /// Every edit starts its own asynchronous save, so a slow, older save could otherwise finish
    /// after a newer one and overwrite it with stale state. The coordinator serializes writes even
    /// when the persistence implementation does not honor task cancellation, and keeps only the
    /// newest pending snapshot while suppressing superseded outcomes.
    func persistenceEffect(for state: State) -> Effect<Action> {
        let snapshot = state.snapshot
        let save = persistence.save
        let shouldClearPersistenceError = state.persistenceError != nil
        let coordinator = persistenceCoordinator
        return .run { send in
            switch await coordinator.enqueue(snapshot, save: save) {
            case .succeeded:
                if shouldClearPersistenceError {
                    await send(.persistenceSucceeded)
                }
            case .failed:
                await send(.persistenceFailed)
            case .superseded:
                break
            }
        }
    }

    func recordHistory(source: String, result: String, in state: inout State) {
        state.history.insert(
            CalculatorHistoryEntry(id: uuid(), expression: source, result: result, date: now),
            at: 0,
        )
        if state.history.count > Self.maximumHistoryCount {
            state.history.removeLast(state.history.count - Self.maximumHistoryCount)
        }
    }
}
