//
//  CalculatorDecoySessionFeature.swift
//  MediaVault
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import ComposableArchitecture
import DecoySupport
import SwiftUI

extension CalculatorDecoyAdapter {
    /// The calculator's build-time registration for the application host.
    @MainActor
    public static let definition = DecoyDefinition(
        id: "calculator",
        displayName: "Calculator",
        declaredTriggers: supportedTriggers,
        makeSession: makeCalculatorSession,
    )
}

@MainActor
private func makeCalculatorSession(context: DecoySessionContext) -> AnyDecoySession {
    let store = Store(initialState: CalculatorDecoySessionFeature.State()) {
        CalculatorDecoySessionFeature(context: context)
    }
    store.send(.task)

    return AnyDecoySession(
        rootView: CalculatorDecoySessionView(store: store),
        updateTriggerConfiguration: { configuration in
            store.send(.adapter(.triggerConfigurationChanged(configuration)))
        },
        deliverCompletion: { completion in
            store.send(.adapter(.completion(completion)))
        },
    )
}

@Reducer
private struct CalculatorDecoySessionFeature {
    @ObservableState
    struct State: Equatable, Sendable {
        var adapter = CalculatorDecoyAdapter.State()
    }

    enum Action: Equatable, Sendable {
        case task
        case adapter(CalculatorDecoyAdapter.Action)
    }

    let context: DecoySessionContext

    var body: some ReducerOf<Self> {
        Scope(state: \.adapter, action: \.adapter) {
            CalculatorDecoyAdapter()
        }
        Reduce { _, action in
            switch action {
            case .task:
                .send(.adapter(.input(.retryPersistence)))
            case let .adapter(.delegate(.hiddenEntryAttempt(attempt))):
                .run { _ in
                    await context.submitAttempt(attempt)
                }
            case .adapter:
                .none
            }
        }
    }
}

@MainActor
private struct CalculatorDecoySessionView: View {
    let store: StoreOf<CalculatorDecoySessionFeature>

    var body: some View {
        CalculatorView(
            store: store.scope(state: \.adapter.calculator, action: \.adapter.calculator),
            presentationOverride: store.adapter.presentation,
            inputHandler: { input in
                store.send(.adapter(.input(input)))
            },
            loadsPersistenceOnAppear: false,
        )
    }
}
