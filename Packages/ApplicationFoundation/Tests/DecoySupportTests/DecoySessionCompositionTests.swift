//
//  DecoySessionCompositionTests.swift
//  MediaVault
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import DecoySupport
import SwiftUI
import Testing

@Suite("Decoy session composition")
@MainActor
struct DecoySessionCompositionTests {
    @Test("A definition creates a session with a narrow attempt and host-command seam")
    func definitionCreatesSessionAndDeliversHostCommands() async throws {
        let trigger = DecoyHiddenEntryTriggerDescriptor(
            id: DecoyHiddenEntryTriggerID(rawValue: "test.authentication"),
            intentKind: .authenticationRequest,
        )
        let configuration = DecoyHiddenEntryTriggerConfiguration(
            declaredTriggers: [trigger],
            enabledTriggerIDs: [trigger.id],
        )
        let attemptID = try DecoyHiddenEntryAttempt.ID(
            #require(UUID(uuidString: "00000000-0000-0000-0000-0000000000a1")),
        )
        let attempt = DecoyHiddenEntryAttempt(
            id: attemptID,
            triggerID: trigger.id,
            intent: .authenticationRequest,
        )
        let completion = DecoyHiddenEntryCompletion(
            attemptID: attemptID,
            result: .success(true),
        )
        let probe = DecoySessionProbe()
        let session = AnyDecoySession(
            rootView: EmptyView(),
            updateTriggerConfiguration: { probe.configurations.append($0) },
            deliverCompletion: { probe.completions.append($0) },
        )
        var factoryConfiguration: DecoyHiddenEntryTriggerConfiguration?
        let definition = DecoyDefinition(
            id: "test-decoy",
            displayName: "Test Decoy",
            declaredTriggers: [trigger],
        ) { context in
            factoryConfiguration = context.triggerConfiguration
            return session
        }
        let context = DecoySessionContext(
            triggerConfiguration: configuration,
            attemptSink: { probe.attempts.append($0) },
        )

        let createdSession = definition.makeSession(context)
        await context.submitAttempt(attempt)
        createdSession.updateTriggerConfiguration(configuration)
        createdSession.deliver(completion)

        #expect(createdSession === session)
        #expect(definition.id == "test-decoy")
        #expect(definition.displayName == "Test Decoy")
        #expect(definition.declaredTriggers == [trigger])
        #expect(factoryConfiguration == configuration)
        #expect(probe.attempts == [attempt])
        #expect(probe.configurations == [configuration])
        #expect(probe.completions == [completion])
    }
}

@MainActor
private final class DecoySessionProbe {
    var attempts: [DecoyHiddenEntryAttempt] = []
    var configurations: [DecoyHiddenEntryTriggerConfiguration] = []
    var completions: [DecoyHiddenEntryCompletion] = []
}
