//
//  CalculatorDecoyAdapter.swift
//  MediaVault
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import ComposableArchitecture
import DecoySupport
import Foundation

/// Adapts calculator surface input to normalized hidden-entry attempts.
///
/// The adapter owns calculator-specific trigger recognition and reconciliation. It wraps the
/// arithmetic and persistence reducer without exposing calculator input policy to the application
/// host. The host receives attempts through ``Action/delegate(_:)`` and returns correlated
/// completions through ``Action/completion(_:)``.
@preconcurrency
@Reducer
public struct CalculatorDecoyAdapter {
    /// The stable trigger descriptor for long-pressing the equals control.
    public static let longPressEqualsTrigger = DecoyHiddenEntryTriggerDescriptor(
        id: DecoyHiddenEntryTriggerID(rawValue: "calculator.long-press-equals"),
    )

    /// The stable trigger descriptor for entering a credential followed by equals.
    public static let pinEqualsTrigger = DecoyHiddenEntryTriggerDescriptor(
        id: DecoyHiddenEntryTriggerID(rawValue: "calculator.pin-equals"),
    )

    /// The trigger declarations supported by the calculator decoy.
    public static let supportedTriggers: Set<DecoyHiddenEntryTriggerDescriptor> = [
        longPressEqualsTrigger,
        pinEqualsTrigger,
    ]

    /// A configuration that declares calculator triggers but enables none of them.
    public static let defaultTriggerConfiguration = DecoyHiddenEntryTriggerConfiguration(
        declaredTriggers: supportedTriggers,
        enabledTriggerIDs: [],
    )

    /// Maximum number of decimal digits retained during PIN-equals capture.
    public static let maximumPINLength = 12

    /// State for the calculator core, runtime trigger configuration, and transient decoy policy.
    @ObservableState
    public struct State: Equatable, Sendable {
        /// The arithmetic and persistence state managed by ``CalculatorFeature``.
        public var calculator: CalculatorFeature.State

        /// The trigger configuration supplied by the application host.
        public var triggerConfiguration: DecoyHiddenEntryTriggerConfiguration

        /// The mutually exclusive hidden-entry phase and the data owned by that phase.
        var lifecycle: CalculatorDecoyLifecycle

        /// The user-visible calculator presentation, including a captured PIN while it is held.
        public var presentation: CalculatorPresentation {
            switch lifecycle {
            case let .capturing(candidate),
                 let .credentialEvaluationPending(candidate, _):
                CalculatorFeature.projectedPresentation(
                    afterDigits: candidate.digits,
                    from: calculator,
                )
            case .idle,
                 .authenticationRequestPending:
                calculator.presentation
            }
        }

        /// Creates adapter state using the supplied calculator state and trigger configuration.
        ///
        /// - Parameters:
        ///   - calculator: The state owned by the existing calculator reducer.
        ///   - triggerConfiguration: The triggers currently enabled by application policy.
        public init(
            calculator: CalculatorFeature.State = .init(),
            triggerConfiguration: DecoyHiddenEntryTriggerConfiguration =
                CalculatorDecoyAdapter.defaultTriggerConfiguration,
        ) {
            self.calculator = calculator
            self.triggerConfiguration = triggerConfiguration
            lifecycle = .idle
        }
    }

    /// Actions accepted by the adapter and its normalized attempt output.
    public enum Action: Equatable, Sendable {
        /// Delivers input from the calculator surface.
        case input(CalculatorInput)

        /// Updates the trigger configuration supplied by application policy.
        case triggerConfigurationChanged(DecoyHiddenEntryTriggerConfiguration)

        /// Delivers the host's result for a previously emitted attempt.
        case completion(DecoyHiddenEntryCompletion)

        /// Forwards an action to the arithmetic and persistence reducer.
        case calculator(CalculatorFeature.Action)

        /// Emits a normalized attempt for the application host to evaluate.
        case delegate(Delegate)
    }

    /// Events emitted to the application host.
    public enum Delegate: Equatable, Sendable {
        /// A calculator-owned trigger produced a normalized hidden-entry attempt.
        case hiddenEntryAttempt(DecoyHiddenEntryAttempt)
    }

    @Dependency(\.uuid)
    private var uuid

    /// Creates an adapter using the current calculator and UUID dependencies.
    public init() {}

    /// Builds the embedded calculator reducer and applies calculator-owned decoy policy.
    public var body: some ReducerOf<Self> {
        Scope(state: \.calculator, action: \.calculator) {
            CalculatorFeature()
        }
        Reduce { state, action in
            handleAdapterAction(into: &state, action: action)
        }
    }

    private func handleAdapterAction(into state: inout State, action: Action) -> Effect<Action> {
        switch action {
        case let .input(input):
            return reduce(input: input, state: &state)
        case let .triggerConfigurationChanged(configuration):
            state.triggerConfiguration = configuration
            guard case let .capturing(candidate) = state.lifecycle,
                  !configuration.isEnabled(Self.pinEqualsTrigger.id)
            else {
                return .none
            }

            state.lifecycle = .idle
            return reconcile(candidate.digits)
        case let .completion(completion):
            return complete(completion, state: &state)
        case .calculator,
             .delegate:
            return .none
        }
    }

    private func reduce(input: CalculatorInput, state: inout State) -> Effect<Action> {
        switch state.lifecycle {
        case .idle:
            reduceIdle(input, state: &state)
        case let .capturing(candidate):
            reduceCapture(input, candidate: candidate, state: &state)
        case let .credentialEvaluationPending(candidate, _):
            reduceCredentialPending(input, candidate: candidate, state: &state)
        case .authenticationRequestPending:
            reduceAuthenticationPending(input, state: &state)
        }
    }

    private func reduceIdle(_ input: CalculatorInput, state: inout State) -> Effect<Action> {
        switch input {
        case .retryPersistence:
            return .send(.calculator(.task))
        case .longPressEquals:
            return requestAuthentication(state: &state, reconciling: nil)
        case let .button(.digit(digit))
            where shouldBeginCapture(digit, state: state):
            state.lifecycle = .capturing(CalculatorDecoyCandidateBuffer(digits: "\(digit)"))
            return .none
        case let .button(button):
            return .send(.calculator(.button(button)))
        }
    }

    private func reduceCapture(
        _ input: CalculatorInput,
        candidate: CalculatorDecoyCandidateBuffer,
        state: inout State,
    ) -> Effect<Action> {
        switch input {
        case .retryPersistence:
            state.lifecycle = .idle
            return reconcile(candidate.digits, followedBy: .task)
        case .longPressEquals:
            return requestAuthentication(state: &state, reconciling: candidate)
        case .button(.equals):
            guard state.triggerConfiguration.isEnabled(Self.pinEqualsTrigger.id) else {
                state.lifecycle = .idle
                return reconcile(candidate.digits, followedBy: .button(.equals))
            }

            let attemptID = DecoyHiddenEntryAttempt.ID(uuid())
            state.lifecycle = .credentialEvaluationPending(
                candidate: candidate,
                attemptID: attemptID,
            )
            let attempt = DecoyHiddenEntryAttempt(
                id: attemptID,
                triggerID: Self.pinEqualsTrigger.id,
                intent: .credentialCandidate(DecoyHiddenEntryCredentialCandidate(candidate.digits)),
            )
            return .send(.delegate(.hiddenEntryAttempt(attempt)))
        case let .button(.digit(digit)) where (0 ... 9).contains(digit):
            guard candidate.digitCount < Self.maximumPINLength else {
                state.lifecycle = .idle
                return reconcile(candidate.digits + "\(digit)")
            }

            state.lifecycle = .capturing(candidate.appending(digit))
            return .none
        case let .button(button):
            state.lifecycle = .idle
            return reconcile(candidate.digits, followedBy: .button(button))
        }
    }

    private func reduceCredentialPending(
        _ input: CalculatorInput,
        candidate: CalculatorDecoyCandidateBuffer,
        state: inout State,
    ) -> Effect<Action> {
        guard case .longPressEquals = input,
              state.triggerConfiguration.isEnabled(Self.longPressEqualsTrigger.id)
        else {
            // Ordinary input and persistence retry remain frozen until this attempt completes.
            return .none
        }

        return requestAuthentication(state: &state, reconciling: candidate)
    }

    private func reduceAuthenticationPending(
        _ input: CalculatorInput,
        state: inout State,
    ) -> Effect<Action> {
        switch input {
        case .retryPersistence:
            .send(.calculator(.task))
        case .longPressEquals:
            requestAuthentication(state: &state, reconciling: nil)
        case let .button(button):
            // An authentication request has no calculator candidate to replay or suppress.
            .send(.calculator(.button(button)))
        }
    }

    private func complete(
        _ completion: DecoyHiddenEntryCompletion,
        state: inout State,
    ) -> Effect<Action> {
        switch state.lifecycle {
        case let .credentialEvaluationPending(candidate, attemptID):
            guard completion.attemptID == attemptID else {
                return .none
            }

            state.lifecycle = .idle
            switch completion.result {
            case .success(true):
                return .none
            case .success(false),
                 .failure:
                return reconcile(candidate.digits, followedBy: .button(.equals))
            }
        case let .authenticationRequestPending(attemptID):
            guard completion.attemptID == attemptID else {
                return .none
            }

            state.lifecycle = .idle
            return .none
        case .idle,
             .capturing:
            return .none
        }
    }

    private func requestAuthentication(
        state: inout State,
        reconciling candidate: CalculatorDecoyCandidateBuffer?,
    ) -> Effect<Action> {
        guard state.triggerConfiguration.isEnabled(Self.longPressEqualsTrigger.id) else {
            guard let candidate else {
                return .none
            }

            state.lifecycle = .idle
            return reconcile(candidate.digits)
        }

        let attemptID = DecoyHiddenEntryAttempt.ID(uuid())
        state.lifecycle = .authenticationRequestPending(attemptID: attemptID)
        let attempt = DecoyHiddenEntryAttempt(
            id: attemptID,
            triggerID: Self.longPressEqualsTrigger.id,
            intent: .authenticationRequest,
        )
        let emitAttempt = Effect<Action>.send(.delegate(.hiddenEntryAttempt(attempt)))
        guard let candidate else {
            return emitAttempt
        }

        return .concatenate(reconcile(candidate.digits), emitAttempt)
    }

    private func shouldBeginCapture(_ digit: Int, state: State) -> Bool {
        (0 ... 9).contains(digit)
            && !state.calculator.isLoading
            && state.triggerConfiguration.isEnabled(Self.pinEqualsTrigger.id)
    }

    /// Applies buffered digits and an optional following action through the calculator reducer.
    private func reconcile(
        _ digits: String,
        followedBy action: CalculatorFeature.Action? = nil,
    ) -> Effect<Action> {
        var actions = digits.compactMap { character -> Action? in
            guard let asciiValue = character.asciiValue,
                  (48 ... 57).contains(asciiValue)
            else {
                return nil
            }

            return .calculator(.button(.digit(Int(asciiValue - 48))))
        }
        if let action {
            actions.append(.calculator(action))
        }
        guard let first = actions.first else {
            return .none
        }

        return actions.dropFirst().reduce(.send(first)) { effect, action in
            .concatenate(effect, .send(action))
        }
    }
}

/// A redacted buffer for digits held during calculator-owned PIN-equals entry.
struct CalculatorDecoyCandidateBuffer:
    Equatable,
    Sendable,
    CustomStringConvertible,
    CustomDebugStringConvertible,
    CustomReflectable {
    fileprivate let digits: String

    init(digits: String) {
        self.digits = digits
    }

    var digitCount: Int {
        digits.utf8.count
    }

    func appending(_ digit: Int) -> Self {
        Self(digits: digits + "\(digit)")
    }

    var description: String {
        "CalculatorDecoyCandidateBuffer([REDACTED])"
    }

    var debugDescription: String {
        description
    }

    var customMirror: Mirror {
        Mirror(self, children: ["digits": "[REDACTED]"], displayStyle: .struct)
    }
}

/// The adapter lifecycle keeps each candidate and attempt identity in one valid phase.
enum CalculatorDecoyLifecycle: Equatable, Sendable {
    case idle
    case capturing(CalculatorDecoyCandidateBuffer)
    case credentialEvaluationPending(
        candidate: CalculatorDecoyCandidateBuffer,
        attemptID: DecoyHiddenEntryAttempt.ID,
    )
    case authenticationRequestPending(attemptID: DecoyHiddenEntryAttempt.ID)
}
