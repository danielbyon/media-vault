//
//  RootFeature.swift
//  MediaVault
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import ComposableArchitecture
import DecoySupport
import SwiftUI
import VaultFeature

/// The application composition root for a registered decoy and the vault lifecycle.
@Reducer
public struct RootFeature {
    /// State owned by the application composition root.
    @ObservableState
    public struct State: Equatable, Sendable {
        /// The vault lifecycle and authenticated shell state.
        public var vault: VaultFeature.State

        /// The attempt currently waiting for hidden-credential evaluation.
        public var pendingHiddenAttemptID: DecoyHiddenEntryAttempt.ID?

        /// The long-lived decoy surface associated with this root store.
        @ObservationStateIgnored
        public var decoySession: AnyDecoySession

        /// Creates root state for one already-composed decoy session.
        public init(
            decoySession: AnyDecoySession,
            vault: VaultFeature.State = .init(),
        ) {
            self.vault = vault
            self.decoySession = decoySession
            pendingHiddenAttemptID = nil
        }

        /// Compares lifecycle and attempt state while ignoring the retained UI session reference.
        public static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.vault == rhs.vault
                && lhs.pendingHiddenAttemptID == rhs.pendingHiddenAttemptID
        }
    }

    /// Actions handled by the root and forwarded to child features.
    public enum Action: Equatable, Sendable {
        /// Starts root-owned lifecycle work.
        case task

        /// Receives a normalized attempt emitted by the active decoy session.
        case decoyAttempt(DecoyHiddenEntryAttempt)

        /// Forwards vault lifecycle and shell actions.
        case vault(VaultFeature.Action)
    }

    private let definition: DecoyDefinition

    /// Creates the generic host for one statically registered decoy.
    ///
    /// - Parameter definition: The active decoy's declared triggers and session factory.
    public init(definition: DecoyDefinition) {
        self.definition = definition
    }

    /// Composes vault lifecycle handling with generic decoy-attempt policy.
    public var body: some ReducerOf<Self> {
        Scope(state: \.vault, action: \.vault) {
            VaultFeature()
        }
        Reduce { state, action in
            switch action {
            case .task:
                .merge(
                    updateTriggerConfiguration(state: state),
                    .send(.vault(.task)),
                )
            case let .decoyAttempt(attempt):
                handle(attempt, state: &state)
            case let .vault(vaultAction):
                handleVaultAction(vaultAction, state: &state)
            }
        }
    }

    private func handle(
        _ attempt: DecoyHiddenEntryAttempt,
        state: inout State,
    ) -> Effect<Action> {
        let declarations = definition.declaredTriggers.filter { $0.id == attempt.triggerID }
        guard declarations.count == 1,
              let descriptor = declarations.first,
              descriptor.intentKind == attempt.intent.kind
        else {
            return deliver(attemptID: attempt.id, result: .success(false), to: state.decoySession)
        }

        let configuration = triggerConfiguration(for: state.vault)
        guard configuration.isEnabled(attempt.triggerID) else {
            return deliver(attemptID: attempt.id, result: .success(false), to: state.decoySession)
        }

        switch attempt.intent {
        case .authenticationRequest:
            let nextPhase: VaultFeature.Action
            switch state.vault.phase {
            case .unconfigured:
                nextPhase = .beginSetup
            case .locked:
                nextPhase = .beginAuthentication
            case .loading,
                 .unavailable,
                 .setup,
                 .authentication,
                 .authenticated:
                return deliver(attemptID: attempt.id, result: .success(false), to: state.decoySession)
            }

            let supersededAttemptID = state.pendingHiddenAttemptID
            state.pendingHiddenAttemptID = nil
            if let supersededAttemptID {
                return .concatenate(
                    .send(.vault(nextPhase)),
                    deliver(
                        attemptID: supersededAttemptID,
                        result: .failure(.evaluationFailed),
                        to: state.decoySession,
                    ),
                    deliver(attemptID: attempt.id, result: .success(true), to: state.decoySession),
                )
            }

            return .concatenate(
                .send(.vault(nextPhase)),
                deliver(attemptID: attempt.id, result: .success(true), to: state.decoySession),
            )
        case let .credentialCandidate(candidate):
            guard state.vault.canUseHiddenEntry,
                  !state.vault.isWorking,
                  state.pendingHiddenAttemptID == nil
            else {
                return deliver(attemptID: attempt.id, result: .success(false), to: state.decoySession)
            }

            state.pendingHiddenAttemptID = attempt.id
            return .send(.vault(.verifyHidden(attemptID: attempt.id, candidate: candidate)))
        }
    }

    private func handleVaultAction(
        _ action: VaultFeature.Action,
        state: inout State,
    ) -> Effect<Action> {
        var completion: DecoyHiddenEntryCompletion?
        switch action {
        case let .hiddenVerificationCompleted(attemptID, result):
            guard state.pendingHiddenAttemptID == attemptID else {
                return .none
            }

            state.pendingHiddenAttemptID = nil
            completion = DecoyHiddenEntryCompletion(attemptID: attemptID, result: result)
        case .beginAuthentication,
             .beginSetup:
            if let attemptID = state.pendingHiddenAttemptID {
                state.pendingHiddenAttemptID = nil
                completion = DecoyHiddenEntryCompletion(
                    attemptID: attemptID,
                    result: .failure(.evaluationFailed),
                )
            }
        default:
            break
        }

        let update = updateTriggerConfiguration(state: state)
        guard let completion else {
            return update
        }

        return .merge(update, deliver(completion, to: state.decoySession))
    }

    private func triggerConfiguration(
        for vault: VaultFeature.State,
    ) -> DecoyHiddenEntryTriggerConfiguration {
        let authenticationEntryIsValid = vault.phase == .unconfigured || vault.phase == .locked
        let enabledTriggerIDs = Set(definition.declaredTriggers.compactMap { descriptor in
            switch descriptor.intentKind {
            case .authenticationRequest:
                authenticationEntryIsValid ? descriptor.id : nil
            case .credentialCandidate:
                vault.canUseHiddenEntry ? descriptor.id : nil
            }
        })
        return DecoyHiddenEntryTriggerConfiguration(
            declaredTriggers: definition.declaredTriggers,
            enabledTriggerIDs: enabledTriggerIDs,
        )
    }

    private func updateTriggerConfiguration(state: State) -> Effect<Action> {
        let session = state.decoySession
        let configuration = triggerConfiguration(for: state.vault)
        return .run { _ in
            await session.updateTriggerConfiguration(configuration)
        }
    }

    private func deliver(
        attemptID: DecoyHiddenEntryAttempt.ID,
        result: Result<Bool, DecoyHiddenEntryError>,
        to session: AnyDecoySession,
    ) -> Effect<Action> {
        deliver(.init(attemptID: attemptID, result: result), to: session)
    }

    private func deliver(
        _ completion: DecoyHiddenEntryCompletion,
        to session: AnyDecoySession,
    ) -> Effect<Action> {
        .run { _ in
            await session.deliver(completion)
        }
    }
}

/// Creates the active decoy session and root store once for the application lifetime.
@MainActor
@preconcurrency
public enum RootComposition {
    /// Composes the root around the shipping decoy's statically registered definition.
    ///
    /// - Parameter vault: The initial vault state, primarily supplied by deterministic tests.
    /// - Returns: A root store whose decoy session remains stable across view updates.
    public static func makeStore(vault: VaultFeature.State = .init()) -> StoreOf<RootFeature> {
        makeStore(definition: ShippingDecoyRegistry.defaultDefinition, vault: vault)
    }

    static func makeStore(
        definition: DecoyDefinition,
        vault: VaultFeature.State,
    ) -> StoreOf<RootFeature> {
        let relay = DecoyAttemptRelay()
        let initialConfiguration = DecoyHiddenEntryTriggerConfiguration(
            declaredTriggers: definition.declaredTriggers,
            enabledTriggerIDs: [],
        )
        let context = DecoySessionContext(
            triggerConfiguration: initialConfiguration,
            attemptSink: { relay.submit($0) },
        )
        let session = definition.makeSession(context)
        let store = Store(
            initialState: RootFeature.State(decoySession: session, vault: vault),
        ) {
            RootFeature(definition: definition)
        }
        relay.store = store
        return store
    }
}

@MainActor
private final class DecoyAttemptRelay {
    weak var store: StoreOf<RootFeature>?

    func submit(_ attempt: DecoyHiddenEntryAttempt) {
        store?.send(.decoyAttempt(attempt))
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

    /// Renders the decoy session, credential surface, or authenticated shell.
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
            decoySurface
                .safeAreaInset(edge: .bottom) {
                    vaultUnavailablePanel
                }
        case .loading,
             .unconfigured,
             .locked:
            decoySurface
        }
    }

    private var decoySurface: some View {
        store.decoySession.rootView
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
                store.send(.vault(.retryConfiguration))
            }
            .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(.thinMaterial)
    }
}
