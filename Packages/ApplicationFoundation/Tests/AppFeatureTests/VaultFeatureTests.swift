//
//  VaultFeatureTests.swift
//  MediaVault
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import ComposableArchitecture
import ConcurrencyExtras
import Dependencies
import Foundation
import Testing
@testable import VaultFeature

@Suite("Vault feature")
struct VaultFeatureTests {
    @Test("PIN setup stores a configured PIN with explicit hidden-entry opt-in")
    @MainActor
    func pinSetupStoresConfiguredCredential() async {
        let store = TestStore(initialState: VaultFeature.State(phase: .unconfigured)) {
            VaultFeature()
        } withDependencies: {
            $0.vaultCredential.configure = { kind, credential, usesHiddenEntry in
                #expect(kind == .pin)
                #expect(credential == "1234")
                #expect(usesHiddenEntry)
                return VaultCredentialConfiguration(kind: .pin, usesHiddenEntry: true)
            }
        }

        await store.send(.beginSetup) {
            $0.phase = .setup
        }
        await store.send(.setupCredentialChanged("1234")) {
            $0.credentialInput = "1234"
        }
        await store.send(.setupConfirmationChanged("1234")) {
            $0.confirmationInput = "1234"
        }
        await store.send(.pinEqualsChanged(true)) {
            $0.usesHiddenEntry = true
        }
        await store.send(.submitSetup) {
            $0.isWorking = true
        }
        await store.receive(.setupCompleted(.success(.init(kind: .pin, usesHiddenEntry: true)))) {
            $0.phase = .authenticated
            $0.configuredKind = .pin
            $0.usesHiddenEntry = true
            $0.credentialInput = ""
            $0.confirmationInput = ""
            $0.isWorking = false
        }
    }

    @Test("PIN setup rejects non-ASCII and out-of-range values without calling storage")
    @MainActor
    func pinSetupRejectsValuesOutsideCalculatorAlphabet() async {
        let configureCalls = LockIsolated(0)
        let store = TestStore(initialState: VaultFeature.State(phase: .unconfigured)) {
            VaultFeature()
        } withDependencies: {
            $0.vaultCredential.configure = { _, _, _ in
                configureCalls.withValue { $0 += 1 }
                return .init(kind: .pin, usesHiddenEntry: false)
            }
        }

        await store.send(.beginSetup) {
            $0.phase = .setup
        }
        await store.send(.setupCredentialChanged("１２３４")) {
            $0.credentialInput = "１２３４"
        }
        await store.send(.setupConfirmationChanged("１２３４")) {
            $0.confirmationInput = "１２３４"
        }
        await store.send(.submitSetup) {
            $0.error = .invalidCredential
        }

        await store.send(.setupCredentialChanged("123")) {
            $0.credentialInput = "123"
            $0.error = nil
        }
        await store.send(.setupConfirmationChanged("123")) {
            $0.confirmationInput = "123"
        }
        await store.send(.submitSetup) {
            $0.error = .invalidCredential
        }

        let tooManyDigits = String(repeating: "1", count: 13)
        await store.send(.setupCredentialChanged(tooManyDigits)) {
            $0.credentialInput = tooManyDigits
            $0.error = nil
        }
        await store.send(.setupConfirmationChanged(tooManyDigits)) {
            $0.confirmationInput = tooManyDigits
        }
        await store.send(.submitSetup) {
            $0.error = .invalidCredential
        }
        #expect(configureCalls.value == 0)
    }

    @Test("Credential lookup failure remains unavailable instead of opening setup")
    @MainActor
    func unavailableConfigurationDoesNotBecomeSetup() async {
        let store = TestStore(initialState: VaultFeature.State()) {
            VaultFeature()
        } withDependencies: {
            $0.vaultCredential.loadConfiguration = {
                throw VaultCredentialError.unavailable
            }
        }

        await store.send(.task) {
            $0.isWorking = true
        }
        await store.receive(.configurationLoaded(.failure(.unavailable))) {
            $0.phase = .unavailable
            $0.error = .unavailable
            $0.isWorking = false
        }
    }

    @Test("Password setup accepts an exact whitespace-only value")
    @MainActor
    func passwordSetupAcceptsWhitespaceWithoutNormalization() async {
        let store = TestStore(initialState: VaultFeature.State(phase: .unconfigured)) {
            VaultFeature()
        } withDependencies: {
            $0.vaultCredential.configure = { kind, credential, usesHiddenEntry in
                #expect(kind == .password)
                #expect(credential == " \n")
                #expect(!usesHiddenEntry)
                return .init(kind: .password, usesHiddenEntry: false)
            }
        }

        await store.send(.beginSetup) {
            $0.phase = .setup
        }
        await store.send(.setupKindSelected(.password)) {
            $0.setupKind = .password
            $0.usesHiddenEntry = false
        }
        await store.send(.setupCredentialChanged(" \n")) {
            $0.credentialInput = " \n"
        }
        await store.send(.setupConfirmationChanged(" \n")) {
            $0.confirmationInput = " \n"
        }
        await store.send(.submitSetup) {
            $0.isWorking = true
        }
        await store.receive(.setupCompleted(.success(.init(kind: .password, usesHiddenEntry: false)))) {
            $0.phase = .authenticated
            $0.configuredKind = .password
            $0.usesHiddenEntry = false
            $0.credentialInput = ""
            $0.confirmationInput = ""
            $0.isWorking = false
        }
    }

    @Test("Authentication succeeds without exposing verifier material")
    @MainActor
    func authenticationSuccessEntersShell() async {
        let store = TestStore(
            initialState: VaultFeature.State(
                phase: .locked,
                configuredKind: .password,
                usesHiddenEntry: false,
            ),
        ) {
            VaultFeature()
        } withDependencies: {
            $0.vaultCredential.verify = { credential in
                #expect(credential == "пароль")
                return .succeeded
            }
        }

        await store.send(.beginAuthentication) {
            $0.phase = .authentication
        }
        await store.send(.authenticationCredentialChanged("пароль")) {
            $0.credentialInput = "пароль"
        }
        await store.send(.submitAuthentication) {
            $0.isWorking = true
        }
        await store.receive(.authenticationCompleted(.succeeded)) {
            $0.phase = .authenticated
            $0.credentialInput = ""
            $0.isWorking = false
        }
    }

    @Test("Normal authentication cancels a pending hidden verification")
    @MainActor
    func normalAuthenticationCancelsPendingHiddenVerification() async {
        let (stream, continuation) = AsyncStream.makeStream(of: VaultCredentialVerificationResult.self)
        let store = TestStore(
            initialState: VaultFeature.State(
                phase: .locked,
                configuredKind: .pin,
                usesHiddenEntry: true,
            ),
        ) {
            VaultFeature()
        } withDependencies: {
            $0.vaultCredential.verify = { _ in
                for await result in stream {
                    return result
                }
                return .unavailable
            }
        }

        await store.send(.verifyHidden("1234")) {
            $0.isWorking = true
        }
        await store.send(.beginAuthentication) {
            $0.phase = .authentication
            $0.isWorking = false
        }

        continuation.yield(.succeeded)
        continuation.finish()
        await Task.yield()

        #expect(store.state.phase == .authentication)
        #expect(!store.state.isWorking)
        await store.finish()
    }

    @Test("A setup race reloads the existing configuration and locks the vault")
    @MainActor
    func setupRaceReloadsExistingConfiguration() async {
        let configuration = VaultCredentialConfiguration(kind: .pin, usesHiddenEntry: true)
        let store = TestStore(initialState: VaultFeature.State(phase: .setup)) {
            VaultFeature()
        } withDependencies: {
            $0.vaultCredential.configure = { _, _, _ in
                throw VaultCredentialError.alreadyConfigured
            }
            $0.vaultCredential.loadConfiguration = {
                configuration
            }
        }

        await store.send(.setupCredentialChanged("1234")) {
            $0.credentialInput = "1234"
        }
        await store.send(.setupConfirmationChanged("1234")) {
            $0.confirmationInput = "1234"
        }
        await store.send(.submitSetup) {
            $0.isWorking = true
        }
        await store.receive(.setupCompleted(.failure(.alreadyConfigured))) {
            $0.phase = .loading
            $0.error = nil
            $0.isWorking = false
        }
        await store.receive(.task) {
            $0.isWorking = true
        }
        await store.receive(.configurationLoaded(.success(configuration))) {
            $0.phase = .locked
            $0.configuredKind = .pin
            $0.usesHiddenEntry = true
            $0.isWorking = false
        }
    }

    @Test("A stale hidden completion cannot unlock normal authentication")
    @MainActor
    func staleHiddenCompletionCannotUnlockNormalAuthentication() async {
        let store = TestStore(
            initialState: VaultFeature.State(
                phase: .authentication,
                configuredKind: .pin,
                usesHiddenEntry: true,
            ),
        ) {
            VaultFeature()
        }

        await store.send(.hiddenVerificationCompleted(.succeeded))
        #expect(store.state.phase == .authentication)
    }

    @Test("A password configuration cannot enable PIN-equals entry")
    @MainActor
    func passwordConfigurationCannotUseHiddenEntry() async {
        let store = TestStore(initialState: VaultFeature.State(phase: .loading)) {
            VaultFeature()
        }

        await store.send(
            .configurationLoaded(.success(.init(kind: .password, usesHiddenEntry: true))),
        ) {
            $0.phase = .locked
            $0.configuredKind = .password
            $0.usesHiddenEntry = false
        }
        #expect(!store.state.canUseHiddenEntry)
    }
}

@Suite("Vault credential persistence")
struct VaultCredentialPersistenceTests {
    @Test("An empty verification candidate is incorrect without reading storage")
    func emptyVerificationCandidateIsIncorrectWithoutReadingStorage() async {
        let storage = TestCredentialStorage()
        let client = VaultCredentialLiveAdapter(
            storage: storage,
            randomBytes: { count in Data(repeating: 0xa5, count: count) },
        ).client

        #expect(await client.verify("") == .incorrect)
        #expect(await storage.loadCount == 0)
    }

    @Test("A failed verification persists a retry throttle")
    func failedVerificationPersistsRetryThrottle() async throws {
        let storage = TestCredentialStorage()
        let client = VaultCredentialLiveAdapter(
            storage: storage,
            randomBytes: { count in Data(repeating: 0xa5, count: count) },
        ).client

        _ = try await client.configure(.pin, "1234", false)
        #expect(await client.verify("0000") == .incorrect)

        let reloadedClient = VaultCredentialLiveAdapter(
            storage: storage,
            randomBytes: { count in Data(repeating: 0xa5, count: count) },
        ).client
        #expect(await reloadedClient.verify("1111") == .unavailable)

        let persisted = try #require(await storage.data)
        let record = try #require(JSONSerialization.jsonObject(with: persisted) as? [String: Any])
        #expect(record["retryAfter"] != nil)
    }

    @Test("Password validation rejects only an empty string")
    func passwordValidationRejectsOnlyEmptyString() async throws {
        let storage = TestCredentialStorage()
        let client = VaultCredentialLiveAdapter(
            storage: storage,
            randomBytes: { count in Data(repeating: 0xa5, count: count) },
        ).client

        let configuration = try await client.configure(.password, " \n", true)
        #expect(configuration == .init(kind: .password, usesHiddenEntry: false))
        #expect(await client.verify(" \n") == .succeeded)
        await #expect(throws: VaultCredentialError.invalidCredential) {
            try await client.configure(.password, "", false)
        }
    }

    @Test("The live adapter stores verifier material without the raw credential")
    func rawCredentialIsAbsentFromStoredRecord() async throws {
        let storage = TestCredentialStorage()
        let adapter = VaultCredentialLiveAdapter(
            storage: storage,
            randomBytes: { count in Data(repeating: 0xa5, count: count) },
        )
        let client = adapter.client
        let secret = "a unique password 文字"

        let configuration = try await client.configure(.password, secret, false)
        let persisted = try #require(await storage.data)
        let record = try #require(JSONSerialization.jsonObject(with: persisted) as? [String: Any])
        let salt = try #require(record["salt"] as? String)
        let verifier = try #require(record["verifier"] as? String)

        #expect(configuration == .init(kind: .password, usesHiddenEntry: false))
        #expect(record["formatVersion"] as? Int == 1)
        #expect(record["algorithm"] as? String == "PBKDF2-HMAC-SHA256")
        #expect(record["kind"] as? String == "password")
        #expect(record["usesHiddenEntry"] as? Bool == false)
        #expect(record["workFactor"] as? Int == 600_000)
        #expect(Data(base64Encoded: salt)?.count == 16)
        #expect(Data(base64Encoded: verifier)?.count == 32)
        #expect(!containsSubsequence(Array(persisted), Array(secret.utf8)))
        #expect(try await client.loadConfiguration() == configuration)
        #expect(await client.verify(secret) == .succeeded)
        #expect(await client.verify("different") == .incorrect)
    }
}

private actor TestCredentialStorage: VaultCredentialStorage {
    var data: Data?
    private(set) var loadCount = 0

    func load() async throws -> Data? {
        loadCount += 1
        return data
    }

    func add(_ data: Data) async throws {
        self.data = data
    }

    func update(_ data: Data) async throws {
        self.data = data
    }
}

private func containsSubsequence(_ haystack: [UInt8], _ needle: [UInt8]) -> Bool {
    guard !needle.isEmpty, needle.count <= haystack.count else {
        return false
    }

    return haystack.indices.contains(where: { index in
        guard index + needle.count <= haystack.count else {
            return false
        }

        return Array(haystack[index ..< index + needle.count]) == needle
    })
}
