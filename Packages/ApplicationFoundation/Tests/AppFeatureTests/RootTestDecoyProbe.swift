//
//  RootTestDecoyProbe.swift
//  MediaVault
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import AppFeature
import ComposableArchitecture
import DecoySupport
import Dependencies
import Foundation
import SwiftUI
import VaultFeature

@MainActor
final class RootTestDecoyProbe {
    private(set) var attempts: [DecoyHiddenEntryAttempt] = []
    private(set) var configurations: [DecoyHiddenEntryTriggerConfiguration] = []
    private(set) var completions: [DecoyHiddenEntryCompletion] = []
    private(set) var sessionFactoryCount = 0
    private var context: DecoySessionContext?
    private var completionObserver: (@MainActor (DecoyHiddenEntryCompletion) -> Void)?

    func sessionCreated(context: DecoySessionContext) {
        sessionFactoryCount += 1
        self.context = context
    }

    func observeCompletions(_ observer: @escaping @MainActor (DecoyHiddenEntryCompletion) -> Void) {
        completionObserver = observer
    }

    func submit(_ attempt: DecoyHiddenEntryAttempt) async {
        guard let context else {
            return
        }

        await context.submitAttempt(attempt)
    }

    func receive(_ attempt: DecoyHiddenEntryAttempt) {
        attempts.append(attempt)
    }

    func update(_ configuration: DecoyHiddenEntryTriggerConfiguration) {
        configurations.append(configuration)
    }

    func complete(_ completion: DecoyHiddenEntryCompletion) {
        completions.append(completion)
        completionObserver?(completion)
    }
}

@MainActor
struct RootTestDecoyFixture {
    let definition: DecoyDefinition
    let session: AnyDecoySession
    let probe: RootTestDecoyProbe
    let authenticationTrigger: DecoyHiddenEntryTriggerDescriptor
    let credentialTrigger: DecoyHiddenEntryTriggerDescriptor
}

@MainActor
func makeRootTestDecoy() -> RootTestDecoyFixture {
    let authenticationTrigger = DecoyHiddenEntryTriggerDescriptor(
        id: DecoyHiddenEntryTriggerID(rawValue: "test.authentication"),
        intentKind: .authenticationRequest,
    )
    let credentialTrigger = DecoyHiddenEntryTriggerDescriptor(
        id: DecoyHiddenEntryTriggerID(rawValue: "test.credential"),
        intentKind: .credentialCandidate,
    )
    let declaredTriggers: Set<DecoyHiddenEntryTriggerDescriptor> = [
        authenticationTrigger,
        credentialTrigger,
    ]
    let probe = RootTestDecoyProbe()
    let initialConfiguration = DecoyHiddenEntryTriggerConfiguration(
        declaredTriggers: declaredTriggers,
        enabledTriggerIDs: [],
    )
    let context = DecoySessionContext(
        triggerConfiguration: initialConfiguration,
        attemptSink: { probe.receive($0) },
    )
    let definition = DecoyDefinition(
        id: "test-decoy",
        displayName: "Test Decoy",
        declaredTriggers: declaredTriggers,
    ) { context in
        probe.sessionCreated(context: context)
        return AnyDecoySession(
            rootView: EmptyView(),
            updateTriggerConfiguration: { probe.update($0) },
            deliverCompletion: { probe.complete($0) },
        )
    }
    let session = definition.makeSession(context)
    return RootTestDecoyFixture(
        definition: definition,
        session: session,
        probe: probe,
        authenticationTrigger: authenticationTrigger,
        credentialTrigger: credentialTrigger,
    )
}

@MainActor
func makeRootStore(
    vault: VaultFeature.State,
    decoy: RootTestDecoyFixture? = nil,
    verify: @escaping @Sendable (String) async -> VaultCredentialVerificationResult = { _ in .unavailable },
    loadConfiguration: @escaping @Sendable () async throws -> VaultCredentialConfiguration? = { nil },
) -> TestStoreOf<RootFeature> {
    let fixture = decoy ?? makeRootTestDecoy()
    let store = TestStore(
        initialState: RootFeature.State(decoySession: fixture.session, vault: vault),
    ) {
        RootFeature(definition: fixture.definition)
    } withDependencies: {
        $0.vaultCredential.verify = verify
        $0.vaultCredential.loadConfiguration = loadConfiguration
    }
    store.exhaustivity = .off(showSkippedAssertions: false)
    return store
}
