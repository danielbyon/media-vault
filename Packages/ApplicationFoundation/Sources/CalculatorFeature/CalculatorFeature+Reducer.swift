//
//  CalculatorFeature+Reducer.swift
//  MediaVault
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import ComposableArchitecture

extension CalculatorFeature {
    func handle(into state: inout State, action: Action) -> Effect<Action> {
        switch action {
        case .task:
            return handleTask(state: &state)
        case let .loaded(result):
            return handleLoaded(result, state: &state)
        case let .button(button):
            return handleButton(button, state: &state)
        case let .pasted(value):
            return handlePasted(value, state: &state)
        case .persistenceFailed:
            state.persistenceError = .unavailable
            return .none
        case .persistenceSucceeded:
            state.persistenceError = nil
            return .none
        }
    }

    private func handleTask(state: inout State) -> Effect<Action> {
        guard !state.isLoading else {
            return .none
        }

        if state.persistenceError != nil {
            return persistenceEffect(for: state)
        }
        state.persistenceError = nil
        state.isLoading = true
        let load = persistence.load
        return .run { send in
            do {
                try await send(.loaded(.success(load())))
            } catch {
                await send(.loaded(.failure(.unavailable)))
            }
        }
    }

    private func handleLoaded(
        _ result: Result<CalculatorSnapshot?, CalculatorPersistenceError>,
        state: inout State,
    ) -> Effect<Action> {
        state.isLoading = false
        switch result {
        case let .success(snapshot):
            state.persistenceError = nil
            guard let snapshot else {
                return .none
            }

            state.display = snapshot.display
            state.expression = snapshot.expression
            state.memory = snapshot.memory
            state.history = snapshot.history
            state.isShowingResult = snapshot.isShowingResult
        case let .failure(error):
            state.persistenceError = error
        }
        return .none
    }

    private func handleButton(_ button: CalculatorButton, state: inout State) -> Effect<Action> {
        guard !state.isLoading else {
            return .none
        }

        switch button {
        case .copy:
            clipboard.copy(state.display)
            return .none
        case .paste:
            let paste = clipboard.paste
            return .run { send in
                await send(.pasted(paste()))
            }
        default:
            guard apply(button, to: &state) else {
                return .none
            }

            return persistenceEffect(for: state)
        }
    }

    private func handlePasted(_ value: String?, state: inout State) -> Effect<Action> {
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .none
        }

        do {
            let result = try CalculatorEngine().evaluate(value)
            state.error = nil
            state.display = result
            state.expression = value
            state.isShowingResult = true
            recordHistory(source: value, result: result, in: &state)
            return persistenceEffect(for: state)
        } catch let error as CalculatorError {
            state.error = error
            return .none
        } catch {
            state.error = .invalidExpression
            return .none
        }
    }
}
