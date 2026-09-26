//
//  VaultFeature.swift
//  MediaVault
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import ComposableArchitecture
import DecoySupport
import Dependencies

/// The visible lifecycle of the vault boundary.
public enum VaultFeaturePhase: Equatable, Sendable {
    /// The initial Keychain configuration lookup is in flight.
    case loading

    /// No credential has been configured yet.
    case unconfigured

    /// Credential storage could not provide a trustworthy configuration.
    ///
    /// This state is distinct from ``unconfigured`` so an unavailable or malformed record cannot
    /// be mistaken for a first-run vault and opened into setup.
    case unavailable

    /// The first credential is being created.
    case setup

    /// A credential exists and the vault is locked.
    case locked

    /// A configured credential is being entered for normal authentication.
    case authentication

    /// The vault is authenticated and its navigation shell is available.
    case authenticated
}

/// Errors that can be shown by setup and normal authentication surfaces.
public enum VaultFeatureError: Error, Equatable, Sendable {
    /// The entered credential does not meet the selected credential contract.
    case invalidCredential

    /// The confirmation value does not exactly match the first value.
    case mismatchedCredentials

    /// The entered credential did not verify.
    case incorrectCredential

    /// Credential storage could not complete the requested operation.
    case unavailable

    /// A credential was configured elsewhere before this setup completed.
    case alreadyConfigured
}

/// The application-owned vault setup and authentication feature.
///
/// This reducer coordinates the credential boundary and authenticated navigation state. Raw input
/// is transient feature state only; persistence and derivation remain behind VaultCredentialClient.
@Reducer
public struct VaultFeature {
    /// State used by setup, authentication, and the authenticated shell.
    @ObservableState
    public struct State: Equatable, Sendable {
        /// The current vault lifecycle phase.
        public var phase: VaultFeaturePhase

        /// The configured credential kind, when a record exists.
        public var configuredKind: VaultCredentialKind?

        /// Whether configured PIN-equals entry is enabled.
        public var usesHiddenEntry: Bool

        /// The credential kind selected during setup.
        public var setupKind: VaultCredentialKind

        /// The transient value in the currently visible credential field.
        public var credentialInput: String

        /// The transient setup confirmation value.
        public var confirmationInput: String

        /// The most recent user-facing setup/authentication error.
        public var error: VaultFeatureError?

        /// Whether a credential operation is in flight.
        public var isWorking: Bool

        /// The decoy attempt whose hidden candidate is currently being evaluated.
        public var pendingHiddenVerificationID: DecoyHiddenEntryAttempt.ID?

        /// The authenticated navigation shell state.
        public var shell: VaultShellFeature.State

        /// Creates vault state for a lifecycle phase.
        public init(
            phase: VaultFeaturePhase = .loading,
            configuredKind: VaultCredentialKind? = nil,
            usesHiddenEntry: Bool = false,
        ) {
            self.phase = phase
            self.configuredKind = configuredKind
            self.usesHiddenEntry = configuredKind == .pin && usesHiddenEntry
            setupKind = .pin
            credentialInput = ""
            confirmationInput = ""
            error = nil
            isWorking = false
            pendingHiddenVerificationID = nil
            shell = .init()
        }

        /// Whether the configured credential can participate in hidden decoy entry.
        public var canUseHiddenEntry: Bool {
            phase == .locked && configuredKind == .pin && usesHiddenEntry
        }
    }

    /// User and lifecycle actions handled by the vault feature.
    public enum Action: Equatable, Sendable {
        /// Starts the initial configuration lookup.
        case task

        /// Retries a configuration lookup after storage was unavailable.
        case retryConfiguration

        /// Delivers the configuration lookup result.
        case configurationLoaded(Result<VaultCredentialConfiguration?, VaultCredentialError>)

        /// Opens first-run setup.
        case beginSetup

        /// Selects the setup credential kind.
        case setupKindSelected(VaultCredentialKind)

        /// Updates the transient setup credential value.
        case setupCredentialChanged(String)

        /// Updates the transient setup confirmation value.
        case setupConfirmationChanged(String)

        /// Enables or disables optional PIN-equals entry during PIN setup.
        case pinEqualsChanged(Bool)

        /// Submits first-run setup.
        case submitSetup

        /// Delivers the setup operation result.
        case setupCompleted(Result<VaultCredentialConfiguration, VaultCredentialError>)

        /// Opens normal authentication for a configured vault.
        case beginAuthentication

        /// Updates the transient normal authentication value.
        case authenticationCredentialChanged(String)

        /// Submits normal authentication.
        case submitAuthentication

        /// Delivers the normal authentication result.
        case authenticationCompleted(VaultCredentialVerificationResult)

        /// Verifies a transient decoy candidate without exposing its plaintext to host policy.
        case verifyHidden(
            attemptID: DecoyHiddenEntryAttempt.ID,
            candidate: DecoyHiddenEntryCredentialCandidate,
        )

        /// Delivers a correlated hidden candidate result without returning the candidate.
        case hiddenVerificationCompleted(
            DecoyHiddenEntryAttempt.ID,
            Result<Bool, DecoyHiddenEntryError>,
        )

        /// Forwards navigation actions after authentication.
        case shell(VaultShellFeature.Action)
    }

    @Dependency(\.vaultCredential)
    var credential

    /// Creates the vault feature.
    public init() {}

    /// Composes credential lifecycle and authenticated navigation behavior.
    public var body: some ReducerOf<Self> {
        Scope(state: \.shell, action: \.shell) {
            VaultShellFeature()
        }
        Reduce { state, action in
            handle(into: &state, action: action)
        }
    }
}

extension VaultFeature {
    private func handle(into state: inout State, action: Action) -> Effect<Action> {
        switch action {
        case .task,
             .retryConfiguration,
             .configurationLoaded:
            handleLoading(into: &state, action: action)
        case .beginSetup,
             .setupKindSelected,
             .setupCredentialChanged,
             .setupConfirmationChanged,
             .pinEqualsChanged,
             .submitSetup,
             .setupCompleted:
            handleSetup(into: &state, action: action)
        case .beginAuthentication,
             .authenticationCredentialChanged,
             .submitAuthentication,
             .authenticationCompleted:
            handleAuthentication(into: &state, action: action)
        case .verifyHidden,
             .hiddenVerificationCompleted:
            handleHiddenVerification(into: &state, action: action)
        case .shell:
            .none
        }
    }

    private func handleLoading(into state: inout State, action: Action) -> Effect<Action> {
        switch action {
        case .task:
            guard state.phase == .loading, !state.isWorking else {
                return .none
            }

        case .retryConfiguration:
            guard state.phase == .unavailable, !state.isWorking else {
                return .none
            }

            state.phase = .loading
            state.error = nil
        case let .configurationLoaded(result):
            state.isWorking = false
            switch result {
            case let .success(configuration):
                guard let configuration else {
                    state.phase = .unconfigured
                    state.configuredKind = nil
                    state.usesHiddenEntry = false
                    state.error = nil
                    return .none
                }

                apply(configuration, to: &state)
                state.phase = .locked
                state.error = nil
            case let .failure(error):
                state.phase = .unavailable
                state.error = map(error)
            }
            return .none
        default:
            return .none
        }

        state.isWorking = true
        let loadConfiguration = credential.loadConfiguration
        return .run { send in
            do {
                let configuration = try await loadConfiguration()
                await send(.configurationLoaded(.success(configuration)))
            } catch let error as VaultCredentialError {
                await send(.configurationLoaded(.failure(error)))
            } catch {
                await send(.configurationLoaded(.failure(.unavailable)))
            }
        }
    }

    private func handleSetup(into state: inout State, action: Action) -> Effect<Action> {
        switch action {
        case .beginSetup:
            guard state.phase == .unconfigured else {
                return .none
            }

            state.phase = .setup
            state.setupKind = .pin
            state.credentialInput = ""
            state.confirmationInput = ""
            state.usesHiddenEntry = false
            state.error = nil
        case let .setupKindSelected(kind):
            guard state.phase == .setup else {
                return .none
            }

            state.setupKind = kind
            if kind == .password {
                state.usesHiddenEntry = false
            }
            state.credentialInput = ""
            state.confirmationInput = ""
            state.error = nil
        case let .setupCredentialChanged(value):
            guard state.phase == .setup else {
                return .none
            }

            state.credentialInput = value
            state.error = nil
        case let .setupConfirmationChanged(value):
            guard state.phase == .setup else {
                return .none
            }

            state.confirmationInput = value
            state.error = nil
        case let .pinEqualsChanged(enabled):
            guard state.phase == .setup, state.setupKind == .pin else {
                return .none
            }

            state.usesHiddenEntry = enabled
        case .submitSetup:
            return submitSetup(state: &state)
        case let .setupCompleted(result):
            return completeSetup(result, state: &state)
        default:
            return .none
        }
        return .none
    }

    private func completeSetup(
        _ result: Result<VaultCredentialConfiguration, VaultCredentialError>,
        state: inout State,
    ) -> Effect<Action> {
        state.isWorking = false
        switch result {
        case let .success(configuration):
            apply(configuration, to: &state)
            state.phase = .authenticated
            state.credentialInput = ""
            state.confirmationInput = ""
            state.error = nil
        case let .failure(error):
            if error == .alreadyConfigured {
                state.phase = .loading
                state.credentialInput = ""
                state.confirmationInput = ""
                state.error = nil
                return .send(.task)
            }
            state.error = map(error)
        }
        return .none
    }

    private func handleAuthentication(into state: inout State, action: Action) -> Effect<Action> {
        switch action {
        case .beginAuthentication:
            guard state.phase == .locked else {
                return .none
            }

            state.phase = .authentication
            state.isWorking = false
            state.pendingHiddenVerificationID = nil
            state.credentialInput = ""
            state.confirmationInput = ""
            state.error = nil
            return .cancel(id: VaultEffectID.hiddenVerification)
        case let .authenticationCredentialChanged(value):
            guard state.phase == .authentication else {
                return .none
            }

            state.credentialInput = value
            state.error = nil
        case .submitAuthentication:
            guard state.phase == .authentication, !state.isWorking else {
                return .none
            }

            state.isWorking = true
            let verify = credential.verify
            let candidate = state.credentialInput
            return .run { send in
                let result = await verify(candidate)
                await send(.authenticationCompleted(result))
            }
        case let .authenticationCompleted(result):
            completeAuthentication(result, state: &state)
        default:
            return .none
        }
        return .none
    }

    private func completeAuthentication(
        _ result: VaultCredentialVerificationResult,
        state: inout State,
    ) {
        state.isWorking = false
        switch result {
        case .succeeded:
            state.phase = .authenticated
            state.credentialInput = ""
            state.error = nil
        case .incorrect:
            state.phase = .authentication
            state.error = .incorrectCredential
        case .unavailable:
            state.phase = .authentication
            state.error = .unavailable
        }
    }

    private func handleHiddenVerification(into state: inout State, action: Action) -> Effect<Action> {
        switch action {
        case let .verifyHidden(attemptID, candidate):
            guard state.phase == .locked,
                  state.configuredKind == .pin,
                  state.usesHiddenEntry,
                  !state.isWorking,
                  state.pendingHiddenVerificationID == nil
            else {
                return .none
            }

            state.isWorking = true
            state.pendingHiddenVerificationID = attemptID
            let verify = credential.verify
            return .run { send in
                guard !Task.isCancelled else {
                    return
                }

                let result = await candidate.evaluate { value in
                    switch await verify(value) {
                    case .succeeded:
                        .success(true)
                    case .incorrect:
                        .success(false)
                    case .unavailable:
                        .failure(.evaluationFailed)
                    }
                }
                guard !Task.isCancelled else {
                    return
                }

                await send(.hiddenVerificationCompleted(attemptID, result))
            }
            .cancellable(id: VaultEffectID.hiddenVerification, cancelInFlight: true)
        case let .hiddenVerificationCompleted(attemptID, result):
            guard state.phase == .locked,
                  state.isWorking,
                  state.pendingHiddenVerificationID == attemptID
            else {
                return .none
            }

            state.pendingHiddenVerificationID = nil
            switch result {
            case .success(true):
                completeHiddenVerification(.succeeded, state: &state)
            case .success(false):
                completeHiddenVerification(.incorrect, state: &state)
            case .failure:
                completeHiddenVerification(.unavailable, state: &state)
            }
        default:
            return .none
        }
        return .none
    }

    private func completeHiddenVerification(
        _ result: VaultCredentialVerificationResult,
        state: inout State,
    ) {
        state.isWorking = false
        guard result == .succeeded else {
            state.phase = .locked
            return
        }

        state.phase = .authenticated
        state.credentialInput = ""
        state.error = nil
    }

    private func submitSetup(state: inout State) -> Effect<Action> {
        guard state.phase == .setup, !state.isWorking else {
            return .none
        }
        guard VaultCredentialValidation.isValid(
            kind: state.setupKind,
            credential: state.credentialInput,
            usesHiddenEntry: state.usesHiddenEntry,
        ), state.credentialInput == state.confirmationInput else {
            state.error = state.credentialInput == state.confirmationInput
                ? .invalidCredential
                : .mismatchedCredentials
            return .none
        }

        state.isWorking = true
        let configure = credential.configure
        let kind = state.setupKind
        let credentialInput = state.credentialInput
        let usesHiddenEntry = state.usesHiddenEntry
        return .run { send in
            do {
                try await send(.setupCompleted(.success(configure(
                    kind,
                    credentialInput,
                    usesHiddenEntry,
                ))))
            } catch let error as VaultCredentialError {
                await send(.setupCompleted(.failure(error)))
            } catch {
                await send(.setupCompleted(.failure(.unavailable)))
            }
        }
    }

    private func apply(
        _ configuration: VaultCredentialConfiguration,
        to state: inout State,
    ) {
        state.configuredKind = configuration.kind
        state.usesHiddenEntry = configuration.kind == .pin && configuration.usesHiddenEntry
    }

    private func map(_ error: VaultCredentialError) -> VaultFeatureError {
        switch error {
        case .unavailable:
            .unavailable
        case .alreadyConfigured:
            .alreadyConfigured
        case .invalidCredential:
            .invalidCredential
        }
    }
}

private enum VaultEffectID: Hashable {
    case hiddenVerification
}
