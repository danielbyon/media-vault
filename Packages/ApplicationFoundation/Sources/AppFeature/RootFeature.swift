//
//  RootFeature.swift
//  MediaVault
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import CalculatorFeature
import ComposableArchitecture
import SwiftUI
import VaultFeature

/// The application composition root.
///
/// The root keeps calculator state independent from vault state. It is also the only layer that
/// interprets the calculator's generic input seam as an optional hidden-entry interaction.
@Reducer
public struct RootFeature {
    /// Transient state for a candidate captured before it reaches the calculator reducer.
    @ObservableState
    public struct HiddenEntryState: Equatable, Sendable {
        /// The ASCII digits captured since the hidden entry gesture began.
        public var candidate: String

        /// Whether verification is in flight for the captured candidate.
        public var isVerifying: Bool

        /// Creates transient hidden-entry state.
        public init(candidate: String = "", isVerifying: Bool = false) {
            self.candidate = candidate
            self.isVerifying = isVerifying
        }
    }

    /// The state owned by the application composition root.
    @ObservableState
    public struct State: Equatable, Sendable {
        /// The calculator feature state rendered by the root view.
        public var calculator: CalculatorFeature.State

        /// The vault lifecycle and authenticated shell state.
        public var vault: VaultFeature.State

        /// The transient hidden-entry candidate, when capture is active.
        public var hiddenEntry: HiddenEntryState?

        /// Creates root state with calculator and vault state.
        public init(
            calculator: CalculatorFeature.State = .init(),
            vault: VaultFeature.State = .init(),
        ) {
            self.calculator = calculator
            self.vault = vault
            hiddenEntry = nil
        }
    }

    /// Actions handled by the root and forwarded to child features.
    public enum Action: Equatable, Sendable {
        /// Starts root-owned lifecycle work.
        case task

        /// Forwards an already-dispatched calculator reducer action.
        case calculator(CalculatorFeature.Action)

        /// Receives a calculator surface input before reducer dispatch.
        case calculatorInput(CalculatorInput)

        /// Forwards vault lifecycle and shell actions.
        case vault(VaultFeature.Action)
    }

    /// Creates the application composition root.
    public init() {}

    /// Composes calculator, vault, and root-owned input policy.
    public var body: some ReducerOf<Self> {
        Scope(state: \.calculator, action: \.calculator) {
            CalculatorFeature()
        }
        Scope(state: \.vault, action: \.vault) {
            VaultFeature()
        }
        Reduce { state, action in
            switch action {
            case .task:
                .merge(
                    .send(.calculator(.task)),
                    .send(.vault(.task)),
                )
            case let .calculatorInput(input):
                handle(input, state: &state)
            case let .vault(.hiddenVerificationCompleted(result)):
                handleHiddenVerification(result, state: &state)
            case .calculator,
                 .vault:
                .none
            }
        }
    }

    private func handle(
        _ input: CalculatorInput,
        state: inout State,
    ) -> Effect<Action> {
        switch input {
        case .retryPersistence:
            guard let hiddenEntry = state.hiddenEntry else {
                return state.vault.phase == .unavailable
                    ? .send(.vault(.retryConfiguration))
                    : .send(.calculator(.task))
            }
            guard !hiddenEntry.isVerifying else {
                return .none
            }

            state.hiddenEntry = nil
            return replay(
                candidate: hiddenEntry.candidate,
                followedBy: .calculator(.task),
            )
        case .longPressEquals:
            return handleLongPress(state: &state)
        case let .button(button):
            return handleButton(button, state: &state)
        }
    }

    private func handleLongPress(state: inout State) -> Effect<Action> {
        let candidate = state.hiddenEntry?.candidate
        state.hiddenEntry = nil
        switch state.vault.phase {
        case .unconfigured:
            guard let candidate else {
                return .send(.vault(.beginSetup))
            }

            return replay(candidate: candidate, followedBy: .vault(.beginSetup))
        case .locked:
            guard let candidate else {
                return .send(.vault(.beginAuthentication))
            }

            return replay(candidate: candidate, followedBy: .vault(.beginAuthentication))
        case .loading,
             .unavailable,
             .setup,
             .authentication,
             .authenticated:
            return .none
        }
    }

    private func handleButton(
        _ button: CalculatorButton,
        state: inout State,
    ) -> Effect<Action> {
        if let hiddenEntry = state.hiddenEntry {
            guard !hiddenEntry.isVerifying else {
                return .none
            }

            switch button {
            case let .digit(digit):
                guard (0 ... 9).contains(digit) else {
                    state.hiddenEntry = nil
                    return replay(
                        candidate: hiddenEntry.candidate,
                        followedBy: .calculator(.button(button)),
                    )
                }
                guard hiddenEntry.candidate.utf8.count < 12 else {
                    state.hiddenEntry = nil
                    return replay(candidate: hiddenEntry.candidate + "\(digit)")
                }

                state.hiddenEntry?.candidate.append("\(digit)")
                return .none
            case .equals:
                state.hiddenEntry?.isVerifying = true
                return .send(.vault(.verifyHidden(hiddenEntry.candidate)))
            default:
                state.hiddenEntry = nil
                return replay(
                    candidate: hiddenEntry.candidate,
                    followedBy: .calculator(.button(button)),
                )
            }
        }

        if case let .digit(digit) = button,
           (0 ... 9).contains(digit),
           !state.calculator.isLoading,
           state.vault.canUseHiddenEntry {
            state.hiddenEntry = .init(candidate: "\(digit)")
            return .none
        }

        return .send(.calculator(.button(button)))
    }

    private func handleHiddenVerification(
        _ result: VaultCredentialVerificationResult,
        state: inout State,
    ) -> Effect<Action> {
        guard let hiddenEntry = state.hiddenEntry, hiddenEntry.isVerifying else {
            return .none
        }

        state.hiddenEntry = nil
        switch result {
        case .succeeded:
            return .none
        case .incorrect,
             .unavailable:
            // Both non-success outcomes intentionally replay the complete candidate and equals
            // action. The calculator is the decoy surface, so this preserves the ordinary-input
            // contract even when credential storage cannot distinguish a wrong candidate.
            return replay(
                candidate: hiddenEntry.candidate,
                followedBy: .calculator(.button(.equals)),
            )
        }
    }

    private func replay(
        candidate: String,
        followedBy action: Action? = nil,
    ) -> Effect<Action> {
        var actions = candidate.compactMap { character -> Action? in
            guard let asciiValue = character.asciiValue, (48 ... 57).contains(asciiValue) else {
                return nil
            }

            return .calculator(.button(.digit(Int(asciiValue - 48))))
        }
        if let action {
            actions.append(action)
        }

        return actions.dropFirst().reduce(
            actions.first.map(Effect.send) ?? .none,
        ) { effect, action in
            .concatenate(effect, .send(action))
        }
    }
}

/// The surface selected by the application's lifecycle state.
@MainActor
@preconcurrency
public struct RootView: View {
    private let store: StoreOf<RootFeature>

    /// Creates the root view from the application's single root store.
    ///
    /// - Parameter store: The store that owns the root composition.
    public init(store: StoreOf<RootFeature>) {
        self.store = store
    }

    /// Renders the calculator decoy, credential surface, or authenticated shell.
    public var body: some View {
        ZStack {
            surface
        }
        .task {
            await store.send(.task).finish()
        }
    }

    @ViewBuilder
    private var surface: some View {
        switch store.vault.phase {
        case .setup,
             .authentication:
            VaultCredentialView(store: store.scope(state: \.vault, action: \.vault))
        case .authenticated:
            VaultShellView(store: store.scope(state: \.vault.shell, action: \.vault.shell))
        case .unavailable:
            calculatorSurface
                .safeAreaInset(edge: .bottom) {
                    vaultUnavailablePanel
                }
        case .loading,
             .unconfigured,
             .locked:
            calculatorSurface
        }
    }

    private var calculatorSurface: some View {
        CalculatorView(
            store: store.scope(state: \.calculator, action: \.calculator),
            presentationOverride: store.hiddenEntry.map { hiddenEntry in
                CalculatorFeature.projectedPresentation(
                    afterDigits: hiddenEntry.candidate,
                    from: store.calculator,
                )
            },
            inputHandler: { input in
                store.send(.calculatorInput(input))
            },
            loadsPersistenceOnAppear: false,
        )
    }

    private var vaultUnavailablePanel: some View {
        VStack(spacing: 8) {
            Text("Vault unavailable")
                .font(.headline)
                .foregroundStyle(.red)
            Text("Credential storage could not be read. Try again when it is available.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Retry vault configuration", systemImage: "arrow.clockwise") {
                store.send(.calculatorInput(.retryPersistence))
            }
            .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(.thinMaterial)
    }
}
