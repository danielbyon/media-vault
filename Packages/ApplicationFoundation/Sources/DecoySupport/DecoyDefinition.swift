//
//  DecoyDefinition.swift
//  MediaVault
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import SwiftUI

/// The host-to-decoy context supplied when a registered decoy session is created.
///
/// The context provides the current trigger configuration and one narrow route for normalized
/// hidden-entry attempts. It does not expose vault state or authentication implementation details.
public struct DecoySessionContext: Sendable {
    /// The trigger declarations and enablement currently supplied by application policy.
    public let triggerConfiguration: DecoyHiddenEntryTriggerConfiguration

    @preconcurrency
    private let attemptSink: @MainActor @Sendable (DecoyHiddenEntryAttempt) -> Void

    /// Creates a context for one active decoy session.
    ///
    /// - Parameters:
    ///   - triggerConfiguration: The active definition's declared triggers and their current
    ///     enablement.
    ///   - attemptSink: The application host's receiver for normalized attempts.
    @preconcurrency
    public init(
        triggerConfiguration: DecoyHiddenEntryTriggerConfiguration,
        attemptSink: @escaping @MainActor @Sendable (DecoyHiddenEntryAttempt) -> Void,
    ) {
        self.triggerConfiguration = triggerConfiguration
        self.attemptSink = attemptSink
    }

    /// Sends a normalized hidden-entry attempt to the application host.
    ///
    /// - Parameter attempt: The decoy-owned attempt to evaluate.
    public func submitAttempt(_ attempt: DecoyHiddenEntryAttempt) async {
        await attemptSink(attempt)
    }
}

/// A type-erased active decoy session owned by the application composition lifetime.
///
/// A session owns its feature state and root view. The host can update only hidden-entry trigger
/// configuration and deliver correlated hidden-entry completions.
@MainActor
@preconcurrency
public final class AnyDecoySession {
    /// The root surface rendered while this decoy is active.
    public let rootView: AnyView

    private let updateConfiguration: (DecoyHiddenEntryTriggerConfiguration) -> Void
    private let deliverCompletionHandler: (DecoyHiddenEntryCompletion) -> Void

    /// Erases a decoy-specific root view and its two host-command operations.
    ///
    /// - Parameters:
    ///   - rootView: The decoy-owned root surface.
    ///   - updateTriggerConfiguration: Applies current host policy to the session.
    ///   - deliverCompletion: Delivers a normalized result to the owning decoy.
    @preconcurrency
    public init(
        rootView: some View,
        updateTriggerConfiguration: @escaping (DecoyHiddenEntryTriggerConfiguration) -> Void,
        deliverCompletion: @escaping (DecoyHiddenEntryCompletion) -> Void,
    ) {
        self.rootView = AnyView(rootView)
        updateConfiguration = updateTriggerConfiguration
        deliverCompletionHandler = deliverCompletion
    }

    /// Applies the latest trigger declarations and enablement from the host.
    public func updateTriggerConfiguration(
        _ configuration: DecoyHiddenEntryTriggerConfiguration,
    ) {
        updateConfiguration(configuration)
    }

    /// Delivers a result correlated to one attempt emitted by this session.
    public func deliver(_ completion: DecoyHiddenEntryCompletion) {
        deliverCompletionHandler(completion)
    }
}

/// A build-time registration for one decoy implementation.
///
/// Definitions contain stable metadata and a factory. They do not load code dynamically and do not
/// define host policy for their declared triggers.
public struct DecoyDefinition: Identifiable, Sendable {
    /// The stable build-time identity of the decoy.
    public let id: String

    /// The human-readable name used by application-owned registration surfaces.
    public let displayName: String

    /// The hidden-entry triggers implemented by this decoy.
    public let declaredTriggers: Set<DecoyHiddenEntryTriggerDescriptor>

    private let sessionFactory: @MainActor @Sendable (DecoySessionContext) -> AnyDecoySession

    /// Creates a build-time registration and its session factory.
    ///
    /// - Parameters:
    ///   - id: A stable identifier for this decoy registration.
    ///   - displayName: A human-readable name for the decoy.
    ///   - declaredTriggers: The triggers this decoy recognizes.
    ///   - makeSession: Creates the long-lived session for the supplied host context.
    @preconcurrency
    public init(
        id: String,
        displayName: String,
        declaredTriggers: Set<DecoyHiddenEntryTriggerDescriptor>,
        makeSession: @escaping @MainActor @Sendable (DecoySessionContext) -> AnyDecoySession,
    ) {
        self.id = id
        self.displayName = displayName
        self.declaredTriggers = declaredTriggers
        sessionFactory = makeSession
    }

    /// Creates one session for the application's active composition lifetime.
    ///
    /// - Parameter context: The host configuration and normalized-attempt sink for the session.
    /// - Returns: The type-erased decoy session.
    @MainActor
    @preconcurrency
    public func makeSession(_ context: DecoySessionContext) -> AnyDecoySession {
        sessionFactory(context)
    }
}
