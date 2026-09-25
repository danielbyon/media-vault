//
//  DecoyHiddenEntryAttempt.swift
//  MediaVault
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

/// A stable identifier for a hidden-entry trigger declared by a decoy.
public struct DecoyHiddenEntryTriggerID: Hashable, Sendable {
    /// The decoy-defined value used to identify the trigger across attempts.
    public let rawValue: String

    /// Creates a trigger identifier from a stable, decoy-defined value.
    ///
    /// - Parameter rawValue: A stable identifier that does not encode a host-specific policy.
    public init(rawValue: String) {
        self.rawValue = rawValue
    }
}

/// A trigger declaration visible to the application host without gesture or control details.
public struct DecoyHiddenEntryTriggerDescriptor: Hashable, Identifiable, Sendable {
    /// The stable identity shared by trigger declarations, configuration, and attempts.
    public let id: DecoyHiddenEntryTriggerID

    /// Creates a declaration for one decoy-owned hidden-entry trigger.
    ///
    /// - Parameter id: The trigger's stable identity.
    public init(id: DecoyHiddenEntryTriggerID) {
        self.id = id
    }
}

/// The current set of supported and enabled hidden-entry triggers for a decoy.
public struct DecoyHiddenEntryTriggerConfiguration: Equatable, Sendable {
    /// The trigger declarations supported by the decoy.
    public let declaredTriggers: Set<DecoyHiddenEntryTriggerDescriptor>

    /// The trigger identities enabled by current application policy.
    public let enabledTriggerIDs: Set<DecoyHiddenEntryTriggerID>

    /// Creates a trigger configuration snapshot for the decoy and its host.
    ///
    /// - Parameters:
    ///   - declaredTriggers: Triggers the decoy currently supports.
    ///   - enabledTriggerIDs: Supported trigger identities currently enabled by policy.
    public init(
        declaredTriggers: Set<DecoyHiddenEntryTriggerDescriptor>,
        enabledTriggerIDs: Set<DecoyHiddenEntryTriggerID>,
    ) {
        self.declaredTriggers = declaredTriggers
        self.enabledTriggerIDs = enabledTriggerIDs
    }

    /// Returns whether a trigger is both declared by the decoy and currently enabled.
    ///
    /// Hosts should evaluate attempts against their current configuration instead of trusting an
    /// event based on a configuration snapshot the decoy may have received earlier.
    public func isEnabled(_ triggerID: DecoyHiddenEntryTriggerID) -> Bool {
        declaredTriggers.contains { $0.id == triggerID } && enabledTriggerIDs.contains(triggerID)
    }
}

/// A transient credential candidate that avoids accidental textual and dump exposure.
///
/// The candidate is not `Codable` or `RawRepresentable` and has no public raw-value accessor.
/// Callers can use the scoped access operation when a credential boundary must evaluate it. This
/// type does not provide secure-memory storage or zeroization.
public struct DecoyHiddenEntryCredentialCandidate:
    Equatable,
    Sendable,
    CustomStringConvertible,
    CustomDebugStringConvertible,
    CustomReflectable {
    private let value: String

    /// Creates a transient candidate from the supplied plaintext.
    ///
    /// - Parameter value: The candidate to retain temporarily for hidden-entry evaluation.
    public init(_ value: String) {
        self.value = value
    }

    /// Exposes candidate plaintext only to a scoped evaluation callback.
    ///
    /// The callback can return only an accepted, rejected, or unavailable result, so its operation
    /// result cannot carry the plaintext. Callers must still treat the callback's `String` as
    /// transient and avoid retaining, logging, serializing, or persisting it.
    ///
    /// - Parameter operation: Evaluates the plaintext and returns a normalized result.
    /// - Returns: The accepted, rejected, or unavailable evaluation result.
    @preconcurrency
    public func evaluate(
        _ operation: @Sendable (String) async -> Result<Bool, DecoyHiddenEntryError>,
    ) async -> Result<Bool, DecoyHiddenEntryError> {
        await operation(value)
    }

    /// A redacted representation for ordinary string interpolation and descriptions.
    public var description: String {
        "DecoyHiddenEntryCredentialCandidate([REDACTED])"
    }

    /// A redacted representation for debug output.
    public var debugDescription: String {
        description
    }

    /// A mirror containing only a redacted placeholder for reflection and custom dumps.
    public var customMirror: Mirror {
        Mirror(self, children: ["value": "[REDACTED]"], displayStyle: .struct)
    }
}

/// The normalized intent carried by a decoy-owned hidden-entry attempt.
public enum DecoyHiddenEntryIntent: Equatable, Sendable {
    /// Requests the application's normal authentication or setup flow.
    case authenticationRequest

    /// Submits a transient candidate for evaluation by the application host.
    case credentialCandidate(DecoyHiddenEntryCredentialCandidate)
}

/// A UUID-backed identity supplied by the decoy that owns an attempt's lifecycle.
public struct DecoyHiddenEntryAttemptID: Hashable, Sendable {
    private let value: UUID

    /// Creates an attempt identity from a UUID supplied by the owning decoy.
    ///
    /// DecoySupport does not generate attempt identities. A caller can provide deterministic UUIDs
    /// in tests and keep attempt creation aligned with its own lifecycle.
    ///
    /// - Parameter value: The caller-owned UUID for one attempt.
    public init(_ value: UUID) {
        self.value = value
    }
}

/// A normalized hidden-entry attempt emitted by a decoy after it recognizes a trigger.
public struct DecoyHiddenEntryAttempt: Equatable, Identifiable, Sendable {
    /// The stable identity of this attempt.
    public typealias ID = DecoyHiddenEntryAttemptID

    /// The stable identity used to correlate a completion with this attempt.
    public let id: ID

    /// The declared trigger that produced this attempt.
    public let triggerID: DecoyHiddenEntryTriggerID

    /// The normalized request presented to the application host.
    public let intent: DecoyHiddenEntryIntent

    /// Creates an attempt using an identity supplied by its owning decoy.
    ///
    /// - Parameters:
    ///   - id: Stable identity created and owned by the decoy.
    ///   - triggerID: The declared trigger recognized by the decoy.
    ///   - intent: The normalized authentication request or credential candidate.
    public init(
        id: ID,
        triggerID: DecoyHiddenEntryTriggerID,
        intent: DecoyHiddenEntryIntent,
    ) {
        self.id = id
        self.triggerID = triggerID
        self.intent = intent
    }
}

/// A normalized evaluation failure that does not reveal host-specific authentication details.
public enum DecoyHiddenEntryError: Error, Equatable, Sendable {
    /// The host could not complete evaluation of the attempt.
    case evaluationFailed
}

/// An informational result paired with the attempt identity it completes.
public struct DecoyHiddenEntryCompletion: Equatable, Sendable {
    /// The identity of the attempt that produced this completion.
    public let attemptID: DecoyHiddenEntryAttempt.ID

    /// Whether evaluation accepted the attempt, rejected it, or could not complete.
    public let result: Result<Bool, DecoyHiddenEntryError>

    /// Creates a completion without prescribing how the decoy uses its result.
    ///
    /// - Parameters:
    ///   - attemptID: The identity supplied with the original attempt.
    ///   - result: `success(true)` for accepted, `success(false)` for rejected, or failure when
    ///     evaluation could not complete.
    public init(
        attemptID: DecoyHiddenEntryAttempt.ID,
        result: Result<Bool, DecoyHiddenEntryError>,
    ) {
        self.attemptID = attemptID
        self.result = result
    }
}
