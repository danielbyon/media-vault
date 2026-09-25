//
//  DecoySupportContractTests.swift
//  MediaVault
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import CustomDump
import DecoySupport
import Foundation
import Testing

@Suite("Decoy hidden-entry contract")
struct DecoySupportContractTests {
    private let authenticationTrigger = DecoyHiddenEntryTriggerDescriptor(
        id: DecoyHiddenEntryTriggerID(rawValue: "authentication"),
    )
    private let candidateTrigger = DecoyHiddenEntryTriggerDescriptor(
        id: DecoyHiddenEntryTriggerID(rawValue: "candidate"),
    )

    @Test("Runtime trigger configuration permits only declared enabled triggers")
    func triggerConfigurationChecksCurrentSupportAndEnablement() {
        let configuration = DecoyHiddenEntryTriggerConfiguration(
            declaredTriggers: [authenticationTrigger, candidateTrigger],
            enabledTriggerIDs: [authenticationTrigger.id],
        )

        #expect(configuration.isEnabled(authenticationTrigger.id))
        #expect(!configuration.isEnabled(candidateTrigger.id))
        #expect(!configuration.isEnabled(DecoyHiddenEntryTriggerID(rawValue: "unknown")))
    }

    @Test("Attempts retain caller-supplied identity and normalized intent")
    func attemptsUseCallerSuppliedIdentity() throws {
        let uuid = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000090"))
        let id = DecoyHiddenEntryAttempt.ID(uuid)
        let authentication = DecoyHiddenEntryAttempt(
            id: id,
            triggerID: authenticationTrigger.id,
            intent: .authenticationRequest,
        )
        let candidate = DecoyHiddenEntryAttempt(
            id: id,
            triggerID: candidateTrigger.id,
            intent: .credentialCandidate(.init("2468")),
        )

        #expect(authentication.id == id)
        #expect(authentication.triggerID == authenticationTrigger.id)
        #expect(isAuthenticationRequest(authentication.intent))
        #expect(candidate.id == id)
        #expect(candidate.triggerID == candidateTrigger.id)
        #expect(isCredentialCandidate(candidate.intent))
    }

    @Test("Credential candidate plaintext is scoped and redacted from representations")
    func credentialCandidateDoesNotEscapeThroughRepresentations() async {
        let secret = "2468-credential-candidate"
        let candidate = DecoyHiddenEntryCredentialCandidate(secret)
        let matchedInsideScope = await candidate.withValue { $0 == secret }
        let mirror = Mirror(reflecting: candidate)
        let customDumpRepresentation = String(customDumping: candidate)
        var standardDump = ""
        dump(candidate, to: &standardDump)
        let representations = [
            String(describing: candidate),
            String(reflecting: candidate),
            String(reflecting: mirror),
            standardDump,
            customDumpRepresentation,
        ]

        #expect(matchedInsideScope)
        #expect(mirror.children.map { String(describing: $0.value) } == ["[REDACTED]"])
        #expect(customDumpRepresentation.contains("[REDACTED]"))
        #expect(representations.allSatisfy { !$0.contains(secret) })
        #expect(!isEncodable(candidate))
        #expect(!isDecodable(candidate))
        #expect(!isRawRepresentable(candidate))
    }

    @Test("Credential-bearing attempts support synthesized equality")
    func credentialBearingAttemptsAreEquatable() throws {
        let uuid = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000097"))
        let id = DecoyHiddenEntryAttempt.ID(uuid)
        let triggerID = candidateTrigger.id
        let secret = "2468-credential-candidate"
        let candidate = DecoyHiddenEntryCredentialCandidate(secret)
        let equivalentCandidate = DecoyHiddenEntryCredentialCandidate(secret)
        let intent = DecoyHiddenEntryIntent.credentialCandidate(candidate)
        let equivalentIntent = DecoyHiddenEntryIntent.credentialCandidate(equivalentCandidate)
        let attempt = DecoyHiddenEntryAttempt(
            id: id,
            triggerID: triggerID,
            intent: intent,
        )
        let equivalentAttempt = DecoyHiddenEntryAttempt(
            id: id,
            triggerID: triggerID,
            intent: equivalentIntent,
        )
        let differentCandidate = DecoyHiddenEntryCredentialCandidate("different-candidate")

        #expect(candidate == equivalentCandidate)
        #expect(intent == equivalentIntent)
        #expect(attempt == equivalentAttempt)
        #expect(attempt != DecoyHiddenEntryAttempt(
            id: id,
            triggerID: triggerID,
            intent: .credentialCandidate(differentCandidate),
        ))
    }

    @Test("Credential-bearing attempts redact candidate plaintext from representations")
    func credentialBearingAttemptDoesNotExposePlaintextInRepresentations() throws {
        let secret = "2468-attempt-secret"
        let uuid = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000098"))
        let attempt = DecoyHiddenEntryAttempt(
            id: DecoyHiddenEntryAttempt.ID(uuid),
            triggerID: candidateTrigger.id,
            intent: .credentialCandidate(.init(secret)),
        )
        var standardDump = ""
        dump(attempt, to: &standardDump)

        let customDumpRepresentation = String(customDumping: attempt)
        let representations = [
            String(describing: attempt),
            String(reflecting: attempt),
            reflectedRepresentation(of: attempt),
            standardDump,
            customDumpRepresentation,
        ]

        #expect(customDumpRepresentation.contains("[REDACTED]"))
        #expect(representations.allSatisfy { !$0.contains(secret) })
    }

    @Test("Completion carries attempt identity with accepted, rejected, or failed evaluation")
    func completionPreservesNormalizedResultSemantics() throws {
        let uuid = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000091"))
        let id = DecoyHiddenEntryAttempt.ID(uuid)

        let accepted = DecoyHiddenEntryCompletion(attemptID: id, result: .success(true))
        let rejected = DecoyHiddenEntryCompletion(attemptID: id, result: .success(false))
        let failed = DecoyHiddenEntryCompletion(
            attemptID: id,
            result: .failure(.evaluationFailed),
        )

        #expect(accepted.attemptID == id)
        #expect(accepted.result == .success(true))
        #expect(rejected.result == .success(false))
        #expect(failed.result == .failure(.evaluationFailed))
    }

    @Test("A test-local fake host checks enabled triggers and returns neutral results")
    func fakeHostExercisesContractWithoutVaultFeature() async throws {
        let configuration = DecoyHiddenEntryTriggerConfiguration(
            declaredTriggers: [authenticationTrigger, candidateTrigger],
            enabledTriggerIDs: [authenticationTrigger.id, candidateTrigger.id],
        )
        let host = FakeDecoyHost(configuration: configuration)
        let uuid = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000092"))
        let id = DecoyHiddenEntryAttempt.ID(uuid)
        let acceptedAttempt = DecoyHiddenEntryAttempt(
            id: id,
            triggerID: candidateTrigger.id,
            intent: .credentialCandidate(.init("2468")),
        )
        let rejectedUUID = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000093"))
        let rejectedAttempt = DecoyHiddenEntryAttempt(
            id: DecoyHiddenEntryAttempt.ID(rejectedUUID),
            triggerID: candidateTrigger.id,
            intent: .credentialCandidate(.init("incorrect")),
        )
        let authenticationUUID = try #require(
            UUID(uuidString: "00000000-0000-0000-0000-000000000096"),
        )
        let authenticationAttempt = DecoyHiddenEntryAttempt(
            id: DecoyHiddenEntryAttempt.ID(authenticationUUID),
            triggerID: authenticationTrigger.id,
            intent: .authenticationRequest,
        )

        let accepted = try #require(await host.evaluate(acceptedAttempt))
        let rejected = try #require(await host.evaluate(rejectedAttempt))
        let authentication = try #require(await host.evaluate(authenticationAttempt))

        #expect(accepted.result == .success(true))
        #expect(rejected.result == .success(false))
        #expect(authentication.result == .success(true))
        #expect(await host.evaluate(.init(
            id: id,
            triggerID: DecoyHiddenEntryTriggerID(rawValue: "unknown"),
            intent: .authenticationRequest,
        )) == nil)
    }

    @Test("A test-local decoy ignores a superseded completion without undoing ordinary input")
    func staleCompletionIsIgnoredByOwningDecoy() throws {
        let firstUUID = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000094"))
        let currentUUID = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000095"))
        let firstID = DecoyHiddenEntryAttempt.ID(firstUUID)
        let currentID = DecoyHiddenEntryAttempt.ID(currentUUID)
        let staleCompletion = DecoyHiddenEntryCompletion(
            attemptID: firstID,
            result: .success(true),
        )
        let currentCompletion = DecoyHiddenEntryCompletion(
            attemptID: currentID,
            result: .success(false),
        )
        var decoy = FakeDecoy(currentAttemptID: currentID)

        decoy.processOrdinaryInput()
        decoy.receive(staleCompletion)

        #expect(decoy.ordinaryInputCount == 1)
        #expect(decoy.lastResult == nil)

        decoy.receive(currentCompletion)

        #expect(decoy.ordinaryInputCount == 1)
        #expect(decoy.lastResult == .success(false))
    }
}

private struct FakeDecoyHost {
    let configuration: DecoyHiddenEntryTriggerConfiguration

    func evaluate(
        _ attempt: DecoyHiddenEntryAttempt,
    ) async -> DecoyHiddenEntryCompletion? {
        guard configuration.isEnabled(attempt.triggerID) else {
            return nil
        }

        let result: Result<Bool, DecoyHiddenEntryError>
        switch attempt.intent {
        case .authenticationRequest:
            result = .success(true)
        case let .credentialCandidate(candidate):
            let isAccepted = await candidate.withValue { $0 == "2468" }
            result = .success(isAccepted)
        }

        return DecoyHiddenEntryCompletion(attemptID: attempt.id, result: result)
    }
}

private struct FakeDecoy {
    var currentAttemptID: DecoyHiddenEntryAttempt.ID
    private(set) var ordinaryInputCount = 0
    private(set) var lastResult: Result<Bool, DecoyHiddenEntryError>?

    mutating func processOrdinaryInput() {
        ordinaryInputCount += 1
    }

    mutating func receive(_ completion: DecoyHiddenEntryCompletion) {
        guard completion.attemptID == currentAttemptID else {
            return
        }

        lastResult = completion.result
    }
}

private func isEncodable(_ value: Any) -> Bool {
    value is any Encodable
}

private func isDecodable(_ value: Any) -> Bool {
    value is any Decodable
}

private func isRawRepresentable(_ value: Any) -> Bool {
    value is any RawRepresentable
}

private func isAuthenticationRequest(_ intent: DecoyHiddenEntryIntent) -> Bool {
    guard case .authenticationRequest = intent else {
        return false
    }

    return true
}

private func isCredentialCandidate(_ intent: DecoyHiddenEntryIntent) -> Bool {
    guard case .credentialCandidate = intent else {
        return false
    }

    return true
}

private func reflectedRepresentation(of value: Any) -> String {
    let mirror = Mirror(reflecting: value)
    let children = mirror.children.map { child in
        "\(child.label ?? "_"): \(reflectedRepresentation(of: child.value))"
    }

    return ([String(describing: value)] + children).joined(separator: "\n")
}
