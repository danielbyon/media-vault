//
//  RootFeatureTests.swift
//  MediaVault
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import CalculatorFeature
import ComposableArchitecture
import ConcurrencyExtras
import DecoySupport
import Foundation
import SwiftUI
import Testing
import UIKit
import VaultFeature
@testable import AppFeature

@Suite("Root feature decoy host")
struct RootFeatureTests {
    @Test("Trigger configuration filters declared roles through current vault policy")
    @MainActor
    func triggerConfigurationTracksVaultPolicy() async {
        let cases: [(VaultFeature.State, Set<String>)] = [
            (.init(phase: .unconfigured), ["test.authentication"]),
            (
                .init(phase: .locked, configuredKind: .pin, usesHiddenEntry: true),
                ["test.authentication", "test.credential"],
            ),
            (.init(phase: .locked, configuredKind: .pin), ["test.authentication"]),
            (.init(phase: .locked, configuredKind: .password), ["test.authentication"]),
            (.init(phase: .loading), []),
            (.init(phase: .unavailable), []),
            (.init(phase: .setup), []),
            (.init(phase: .authentication), []),
            (.init(phase: .authenticated), []),
        ]

        for (vault, enabledIDs) in cases {
            let decoy = makeRootTestDecoy()
            let store = makeRootStore(vault: vault, decoy: decoy)
            await store.send(.task)
            await store.receive(.vault(.task))
            if vault.phase == .loading {
                await store.receive(.vault(.configurationLoaded(.success(nil))))
                #expect(decoy.probe.configurations.contains {
                    $0.enabledTriggerIDs.isEmpty
                })
            }
            await store.finish()

            let configuration = decoy.probe.configurations.last
            #expect(configuration?.declaredTriggers == decoy.definition.declaredTriggers)
            if vault.phase == .loading {
                #expect(Set(configuration?.enabledTriggerIDs.map(\.rawValue) ?? []) == ["test.authentication"])
            } else {
                #expect(Set(configuration?.enabledTriggerIDs.map(\.rawValue) ?? []) == enabledIDs)
            }
            #expect(decoy.probe.sessionFactoryCount == 1)
        }
    }

    @Test("The Browser surface is mounted only after authentication and Browser entry")
    @MainActor
    func browserSurfaceRespectsTheVaultCompositionBoundary() async throws {
        let suiteName = "RootFeatureTests.BrowserBoundary.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defaults.set(false, forKey: "browser.preserveOpenTabs")
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let gatedPhases = [
            VaultFeature.State(phase: .loading),
            VaultFeature.State(phase: .unconfigured),
            VaultFeature.State(phase: .locked, configuredKind: .password),
            VaultFeature.State(phase: .setup),
            VaultFeature.State(phase: .authentication, configuredKind: .password),
        ]
        for vault in gatedPhases {
            let store = compositionStore(vault: vault, defaults: defaults)
            let (controller, window) = mountRootView(store)
            await settle(controller)

            #expect(!hasBrowserOmnibox(in: controller.view))

            window.isHidden = true
            window.rootViewController = nil
        }

        var authenticatedShell = VaultFeature.State(phase: .authenticated)
        authenticatedShell.shell.selectedTab = .collections
        let beforeBrowserEntry = compositionStore(vault: authenticatedShell, defaults: defaults)
        let (shellController, shellWindow) = mountRootView(beforeBrowserEntry)
        await settle(shellController)
        #expect(!hasBrowserOmnibox(in: shellController.view))
        shellWindow.isHidden = true
        shellWindow.rootViewController = nil

        authenticatedShell.shell.selectedTab = .browser
        let browserEntry = compositionStore(vault: authenticatedShell, defaults: defaults)
        let (browserController, browserWindow) = mountRootView(browserEntry)
        await settle(browserController)
        #expect(hasBrowserOmnibox(in: browserController.view))
        browserWindow.isHidden = true
        browserWindow.rootViewController = nil
    }

    @Test("A declared alternate-decoy authentication request opens setup and is accepted immediately")
    @MainActor
    func alternateDecoyAuthenticationRequestStartsSetup() async {
        let decoy = makeRootTestDecoy()
        let store = makeRootStore(
            vault: VaultFeature.State(phase: .unconfigured),
            decoy: decoy,
        )
        let attempt = DecoyHiddenEntryAttempt(
            id: .init(UUID()),
            triggerID: decoy.authenticationTrigger.id,
            intent: .authenticationRequest,
        )

        await store.send(.decoyAttempt(attempt))
        await store.receive(.vault(.beginSetup))
        await store.finish()

        #expect(store.state.vault.phase == .setup)
        #expect(decoy.probe.completions == [
            DecoyHiddenEntryCompletion(attemptID: attempt.id, result: .success(true)),
        ])
        #expect(decoy.probe.sessionFactoryCount == 1)
    }

    @Test("A declared alternate-decoy authentication request opens normal authentication")
    @MainActor
    func alternateDecoyAuthenticationRequestStartsAuthentication() async {
        let decoy = makeRootTestDecoy()
        let store = makeRootStore(
            vault: VaultFeature.State(phase: .locked, configuredKind: .password),
            decoy: decoy,
        )
        let attempt = DecoyHiddenEntryAttempt(
            id: .init(UUID()),
            triggerID: decoy.authenticationTrigger.id,
            intent: .authenticationRequest,
        )

        await store.send(.decoyAttempt(attempt))
        await store.receive(.vault(.beginAuthentication))
        await store.finish()

        #expect(store.state.vault.phase == .authentication)
        #expect(decoy.probe.completions == [
            DecoyHiddenEntryCompletion(attemptID: attempt.id, result: .success(true)),
        ])
    }

    @Test("A test decoy submits through its session context and receives a correlated completion")
    @MainActor
    func alternateDecoyUsesThePublicSessionContext() async {
        let decoy = makeRootTestDecoy()
        let (completionStream, completionContinuation) = AsyncStream.makeStream(
            of: DecoyHiddenEntryCompletion.self,
        )
        decoy.probe.observeCompletions { completion in
            completionContinuation.yield(completion)
        }
        let evaluatedCandidate = LockIsolated<String?>(nil)
        let store = withDependencies {
            $0.vaultCredential.verify = { candidate in
                evaluatedCandidate.withValue { $0 = candidate }
                return .succeeded
            }
        } operation: {
            RootComposition.makeStore(
                definition: decoy.definition,
                vault: VaultFeature.State(
                    phase: .locked,
                    configuredKind: .pin,
                    usesHiddenEntry: true,
                ),
            )
        }
        let attempt = DecoyHiddenEntryAttempt(
            id: .init(UUID()),
            triggerID: decoy.credentialTrigger.id,
            intent: .credentialCandidate(.init("1234")),
        )
        var completions = completionStream.makeAsyncIterator()

        await decoy.probe.submit(attempt)
        let completion = await completions.next()

        #expect(completion?.attemptID == attempt.id)
        #expect(completion?.result == .success(true))
        #expect(evaluatedCandidate.value == "1234")
        #expect(store.state.vault.phase == .authenticated)
        #expect(decoy.probe.sessionFactoryCount == 2)
    }

    @Test("An undeclared trigger and an intent-kind mismatch are rejected")
    @MainActor
    func undeclaredAndMismatchedAttemptsAreRejected() async {
        let decoy = makeRootTestDecoy()
        let verificationCalls = LockIsolated(0)
        let store = makeRootStore(
            vault: VaultFeature.State(
                phase: .locked,
                configuredKind: .pin,
                usesHiddenEntry: true,
            ),
            decoy: decoy,
            verify: { _ in
                verificationCalls.withValue { $0 += 1 }
                return .succeeded
            },
        )
        let undeclaredID = DecoyHiddenEntryTriggerID(rawValue: "test.undeclared")
        let mismatched = DecoyHiddenEntryAttempt(
            id: .init(UUID()),
            triggerID: decoy.authenticationTrigger.id,
            intent: .credentialCandidate(.init("1234")),
        )
        let undeclared = DecoyHiddenEntryAttempt(
            id: .init(UUID()),
            triggerID: undeclaredID,
            intent: .authenticationRequest,
        )

        await store.send(.decoyAttempt(mismatched))
        await store.send(.decoyAttempt(undeclared))
        await store.finish()

        #expect(store.state.vault.phase == .locked)
        #expect(verificationCalls.value == 0)
        #expect(decoy.probe.completions.map(\.result) == [.success(false), .success(false)])
    }

    @Test("A disabled credential trigger is rejected even when declared")
    @MainActor
    func disabledCredentialTriggerIsRejected() async {
        let decoy = makeRootTestDecoy()
        let store = makeRootStore(
            vault: VaultFeature.State(phase: .locked, configuredKind: .password),
            decoy: decoy,
            verify: { _ in .succeeded },
        )
        let attempt = DecoyHiddenEntryAttempt(
            id: .init(UUID()),
            triggerID: decoy.credentialTrigger.id,
            intent: .credentialCandidate(.init("1234")),
        )

        await store.send(.decoyAttempt(attempt))
        await store.finish()

        #expect(store.state.vault.phase == .locked)
        #expect(store.state.vault.pendingHiddenVerificationID == nil)
        #expect(decoy.probe.completions == [
            DecoyHiddenEntryCompletion(attemptID: attempt.id, result: .success(false)),
        ])
    }

    @Test("An accepted candidate is evaluated inside the credential boundary")
    @MainActor
    func acceptedCredentialCandidateAuthenticates() async {
        let decoy = makeRootTestDecoy()
        let evaluatedCandidate = LockIsolated<String?>(nil)
        let store = makeRootStore(
            vault: VaultFeature.State(
                phase: .locked,
                configuredKind: .pin,
                usesHiddenEntry: true,
            ),
            decoy: decoy,
            verify: { value in
                evaluatedCandidate.withValue { $0 = value }
                return .succeeded
            },
        )
        let attempt = DecoyHiddenEntryAttempt(
            id: .init(UUID()),
            triggerID: decoy.credentialTrigger.id,
            intent: .credentialCandidate(.init("1234")),
        )

        await store.send(.decoyAttempt(attempt))
        await store.receive(.vault(.verifyHidden(attemptID: attempt.id, candidate: .init("1234"))))
        await store.receive(.vault(.hiddenVerificationCompleted(attempt.id, .success(true))))
        await store.finish()

        #expect(store.state.vault.phase == .authenticated)
        #expect(store.state.pendingHiddenAttemptID == nil)
        #expect(evaluatedCandidate.value == "1234")
        #expect(decoy.probe.completions == [
            DecoyHiddenEntryCompletion(attemptID: attempt.id, result: .success(true)),
        ])
    }

    @Test("An incorrect credential candidate remains locked and reports rejection")
    @MainActor
    func incorrectCredentialCandidateIsRejected() async {
        await assertCredentialResult(.incorrect, expectedCompletion: .success(false))
    }

    @Test("An unavailable credential evaluation remains locked and reports failure")
    @MainActor
    func unavailableCredentialCandidateReportsFailure() async {
        await assertCredentialResult(.unavailable, expectedCompletion: .failure(.evaluationFailed))
    }

    @Test("Authentication supersession completes both attempts and ignores a stale candidate result")
    @MainActor
    func authenticationRequestSupersedesPendingCandidate() async {
        let (stream, continuation) = AsyncStream.makeStream(of: VaultCredentialVerificationResult.self)
        let decoy = makeRootTestDecoy()
        let store = makeRootStore(
            vault: VaultFeature.State(
                phase: .locked,
                configuredKind: .pin,
                usesHiddenEntry: true,
            ),
            decoy: decoy,
            verify: { _ in
                for await result in stream {
                    return result
                }
                return .unavailable
            },
        )
        let candidateAttempt = DecoyHiddenEntryAttempt(
            id: .init(UUID()),
            triggerID: decoy.credentialTrigger.id,
            intent: .credentialCandidate(.init("1234")),
        )
        let authenticationAttempt = DecoyHiddenEntryAttempt(
            id: .init(UUID()),
            triggerID: decoy.authenticationTrigger.id,
            intent: .authenticationRequest,
        )

        await store.send(.decoyAttempt(candidateAttempt))
        await store.receive(
            .vault(.verifyHidden(attemptID: candidateAttempt.id, candidate: .init("1234"))),
        )
        await store.send(.decoyAttempt(authenticationAttempt))
        await store.receive(.vault(.beginAuthentication))
        continuation.yield(.succeeded)
        continuation.finish()
        await store.finish()

        let expectedCompletions = [
            DecoyHiddenEntryCompletion(
                attemptID: candidateAttempt.id,
                result: .failure(.evaluationFailed),
            ),
            DecoyHiddenEntryCompletion(
                attemptID: authenticationAttempt.id,
                result: .success(true),
            ),
        ]
        #expect(store.state.vault.phase == .authentication)
        #expect(store.state.vault.pendingHiddenVerificationID == nil)
        #expect(store.state.pendingHiddenAttemptID == nil)
        #expect(decoy.probe.completions == expectedCompletions)

        await store.send(.vault(.hiddenVerificationCompleted(candidateAttempt.id, .success(true))))
        await store.finish()

        #expect(store.state.vault.phase == .authentication)
        #expect(store.state.vault.pendingHiddenVerificationID == nil)
        #expect(store.state.pendingHiddenAttemptID == nil)
        #expect(decoy.probe.completions == expectedCompletions)
    }

    @MainActor
    private func assertCredentialResult(
        _ verification: VaultCredentialVerificationResult,
        expectedCompletion: Result<Bool, DecoyHiddenEntryError>,
    ) async {
        let decoy = makeRootTestDecoy()
        let store = makeRootStore(
            vault: VaultFeature.State(
                phase: .locked,
                configuredKind: .pin,
                usesHiddenEntry: true,
            ),
            decoy: decoy,
            verify: { _ in verification },
        )
        let attempt = DecoyHiddenEntryAttempt(
            id: .init(UUID()),
            triggerID: decoy.credentialTrigger.id,
            intent: .credentialCandidate(.init("1234")),
        )

        await store.send(.decoyAttempt(attempt))
        await store.receive(.vault(.verifyHidden(attemptID: attempt.id, candidate: .init("1234"))))
        let normalizedResult: Result<Bool, DecoyHiddenEntryError> =
            switch verification {
            case .succeeded:
                .success(true)
            case .incorrect:
                .success(false)
            case .unavailable:
                .failure(.evaluationFailed)
            }
        await store.receive(.vault(.hiddenVerificationCompleted(attempt.id, normalizedResult)))
        await store.finish()

        #expect(store.state.vault.phase == .locked)
        #expect(store.state.pendingHiddenAttemptID == nil)
        #expect(decoy.probe.completions == [
            DecoyHiddenEntryCompletion(attemptID: attempt.id, result: expectedCompletion),
        ])
    }

    @MainActor
    private func compositionStore(
        vault: VaultFeature.State,
        defaults: UserDefaults,
    ) -> StoreOf<RootFeature> {
        withDependencies {
            $0.defaultAppStorage = defaults
            $0.uuid = .incrementing
            $0.vaultCredential.loadConfiguration = { nil }
            $0.calculatorPersistence.load = { nil }
            $0.calculatorPersistence.save = { _ in }
        } operation: {
            RootComposition.makeStore(vault: vault)
        }
    }

    @MainActor
    private func mountRootView(_ store: StoreOf<RootFeature>) -> (UIHostingController<RootView>, UIWindow) {
        let controller = UIHostingController(rootView: RootView(store: store))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = controller
        window.makeKeyAndVisible()
        controller.view.frame = window.bounds
        controller.view.layoutIfNeeded()
        return (controller, window)
    }

    @MainActor
    private func settle(_ controller: UIViewController) async {
        for _ in 0 ..< 8 {
            await Task.yield()
            controller.view.layoutIfNeeded()
        }
    }

    @MainActor
    private func hasBrowserOmnibox(in root: UIView) -> Bool {
        allViews(in: root)
            .compactMap { $0 as? UITextField }
            .contains { $0.placeholder == "Search or enter website" }
    }

    @MainActor
    private func allViews(in root: UIView) -> [UIView] {
        root.subviews.flatMap { [$0] + allViews(in: $0) }
    }
}
