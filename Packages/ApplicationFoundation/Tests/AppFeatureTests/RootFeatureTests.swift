//
//  RootFeatureTests.swift
//  MediaVault
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import BrowserFeature
import ComposableArchitecture
import ConcurrencyExtras
import CoreFoundation
import DecoySupport
import Dependencies
import Foundation
import MediaLibrary
import Testing
@testable import AppFeature
@testable import VaultFeature

@Suite("Root feature decoy host")
struct RootFeatureTests {
    @Test("Browser top inset requires an authenticated Browser surface")
    func browserTopInsetRequiresAuthenticatedBrowserSurface() {
        let cases: [(VaultFeaturePhase, VaultShellTab, CGFloat)] = [
            (.authenticated, .browser, 24),
            (.authenticated, .library, 0),
            (.locked, .browser, 0),
            (.locked, .library, 0),
        ]

        for (vaultPhase, selectedTab, expectedInset) in cases {
            #expect(
                RootSurfaceLayout.browserTopInset(
                    vaultPhase: vaultPhase,
                    selectedTab: selectedTab,
                ) == expectedInset,
            )
        }
    }

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
        await store.receive(.vault(.hiddenVerificationCompleted(
            sessionGeneration: 0,
            requestGeneration: 1,
            attemptID: attempt.id,
            result: .success(true),
        )))
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

        await store.send(.vault(.hiddenVerificationCompleted(
            sessionGeneration: 0,
            requestGeneration: 1,
            attemptID: candidateAttempt.id,
            result: .success(true),
        )))
        await store.finish()

        #expect(store.state.vault.phase == .authentication)
        #expect(store.state.vault.pendingHiddenVerificationID == nil)
        #expect(store.state.pendingHiddenAttemptID == nil)
        #expect(decoy.probe.completions == expectedCompletions)
    }

    @Test("A background return cancels a pending hidden verification", .timeLimit(.minutes(1)))
    @MainActor
    func backgroundReturnCancelsPendingHiddenVerification() async {
        let verificationStarted = PendingVerificationStart()
        let pendingVerification = PendingVerificationResponse()
        let verificationCancellationObserved = LockIsolated<Bool?>(nil)
        let decoy = makeRootTestDecoy()
        let attempt = DecoyHiddenEntryAttempt(
            id: .init(UUID()),
            triggerID: decoy.credentialTrigger.id,
            intent: .credentialCandidate(.init("1234")),
        )
        let store = makeRootStore(
            vault: VaultFeature.State(
                phase: .locked,
                configuredKind: .pin,
                usesHiddenEntry: true,
            ),
            decoy: decoy,
            verify: { _ in
                let result = await pendingVerification.suspend {
                    verificationStarted.resumeOnce(started: true)
                }
                verificationCancellationObserved.withValue { $0 = Task.isCancelled }
                return result
            },
        )
        defer {
            verificationStarted.resumeOnce(started: false)
            pendingVerification.resumeOnce(with: .unavailable)
        }

        await store.send(.decoyAttempt(attempt))
        await store.receive(
            .vault(.verifyHidden(attemptID: attempt.id, candidate: .init("1234"))),
        )
        let didStartVerification = await withTaskCancellationHandler(
            operation: {
                await verificationStarted.wait()
            },
            onCancel: {
                verificationStarted.resumeOnce(started: false)
                pendingVerification.resumeOnce(with: .unavailable)
            },
        )
        #expect(didStartVerification)
        #expect(store.state.vault.phase == .locked)
        #expect(store.state.vault.isWorking)
        #expect(store.state.vault.pendingHiddenVerificationID == attempt.id)

        await store.send(.applicationPhaseChanged(.background))

        #expect(store.state.applicationReturnPending)
        #expect(store.state.vault.phase == .locked)
        #expect(store.state.vault.isWorking)
        #expect(store.state.vault.pendingHiddenVerificationID == attempt.id)

        await store.send(.applicationPhaseChanged(.active))

        #expect(!store.state.applicationReturnPending)
        #expect(store.state.vault.phase == .locked)
        #expect(!store.state.vault.isWorking)
        #expect(store.state.vault.pendingHiddenVerificationID == nil)
        #expect(store.state.pendingHiddenAttemptID == nil)
        #expect(store.state.vault.shell.isSessionLocked)

        pendingVerification.resumeOnce(with: .succeeded)
        await store.finish()

        #expect(verificationCancellationObserved.value == true)
        #expect(store.state.vault.phase == .locked)
        #expect(store.state.vault.pendingHiddenVerificationID == nil)
        #expect(store.state.pendingHiddenAttemptID == nil)
        #expect(store.state.vault.shell.isSessionLocked)
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
        await store.receive(.vault(.hiddenVerificationCompleted(
            sessionGeneration: 0,
            requestGeneration: 1,
            attemptID: attempt.id,
            result: normalizedResult,
        )))
        await store.finish()

        #expect(store.state.vault.phase == .locked)
        #expect(store.state.pendingHiddenAttemptID == nil)
        #expect(decoy.probe.completions == [
            DecoyHiddenEntryCompletion(attemptID: attempt.id, result: expectedCompletion),
        ])
    }

    @Test("Inactive application phases do not start background auto-lock grace")
    @MainActor
    func inactivePhaseDoesNotStartAutoLockGrace() async {
        let clock = ContinuousClock()
        let backgroundStart = clock.now
        let currentTime = LockIsolated<ContinuousClock.Instant?>(backgroundStart)
        var vault = VaultFeature.State(phase: .authenticated)
        vault.sessionSettings.autoLockTimeout = .seconds30
        let store = makeRootStore(vault: vault, now: { currentTime.value })

        await store.send(.applicationPhaseChanged(.inactive))
        currentTime.withValue { $0 = backgroundStart.advanced(by: .seconds(90)) }
        await store.send(.applicationPhaseChanged(.background)) {
            $0.applicationReturnPending = true
            $0.autoLockBackgroundStartedAt = backgroundStart.advanced(by: .seconds(90))
            $0.autoLockTimeoutAtBackground = .seconds(30)
        }
        currentTime.withValue { $0 = backgroundStart.advanced(by: .seconds(119)) }
        await store.send(.applicationPhaseChanged(.active))

        #expect(store.state.vault.phase == .authenticated)
        await store.finish()
    }

    @Test("An unknown application phase keeps unconfigured setup reachable")
    @MainActor
    func unknownApplicationPhaseKeepsSetupReachable() async {
        let store = makeRootStore(vault: VaultFeature.State(phase: .unconfigured))

        await store.send(.applicationPhaseChanged(.unknown)) {
            $0.applicationReturnPending = true
        }
        #expect(store.state.vault.phase == .unconfigured)
        #expect(store.state.applicationReturnPending)

        await store.send(.applicationPhaseChanged(.active)) {
            $0.applicationReturnPending = false
        }
        #expect(store.state.vault.phase == .unconfigured)

        await store.send(.vault(.beginSetup)) {
            $0.vault.phase = .setup
            $0.vault.sessionGeneration = 1
            $0.vault.setupKind = .pin
            $0.vault.credentialInput = ""
            $0.vault.confirmationInput = ""
            $0.vault.usesHiddenEntry = false
            $0.vault.error = nil
        }
        await store.finish()
    }

    @Test("An unknown application phase still locks a configured vault")
    @MainActor
    func unknownApplicationPhaseLocksConfiguredVault() async {
        let store = makeRootStore(
            vault: VaultFeature.State(phase: .authenticated, configuredKind: .password),
        )

        await store.send(.applicationPhaseChanged(.unknown))
        await store.receive(.vault(.shell(.browser(.sessionLocked))))
        #expect(store.state.vault.phase == .locked)
        #expect(store.state.applicationReturnPending)

        await store.send(.applicationPhaseChanged(.active)) {
            $0.applicationReturnPending = false
        }
        #expect(store.state.vault.phase == .locked)
        await store.finish()
    }

    @Test("Local scene activation cannot evaluate application background grace")
    @MainActor
    func localSceneActivationDoesNotEvaluateBackgroundGrace() async {
        let clock = ContinuousClock()
        let backgroundStart = clock.now
        let currentTime = LockIsolated<ContinuousClock.Instant?>(backgroundStart)
        var vault = VaultFeature.State(phase: .authenticated)
        vault.sessionSettings.autoLockTimeout = .seconds30
        let store = makeRootStore(vault: vault, now: { currentTime.value })

        await store.send(.applicationPhaseChanged(.background)) {
            $0.applicationReturnPending = true
            $0.autoLockBackgroundStartedAt = backgroundStart
            $0.autoLockTimeoutAtBackground = .seconds(30)
        }
        currentTime.withValue { $0 = backgroundStart.advanced(by: .seconds(30)) }
        await store.send(.sceneBecameActive)

        #expect(store.state.vault.phase == .authenticated)
        #expect(store.state.autoLockBackgroundStartedAt == backgroundStart)
        #expect(store.state.applicationReturnPending)
        await store.finish()
    }

    @Test("Immediate background auto-lock commits before content can be revealed")
    @MainActor
    func immediateAutoLockCommitsBeforeReveal() async {
        var vault = VaultFeature.State(phase: .authenticated)
        vault.sessionSettings.autoLockTimeout = .immediately
        let advancedGenerations = LockIsolated<[UInt64]>([])
        let store = withDependencies {
            $0.browserProfileConfigurationFence = BrowserProfileConfigurationFenceClient(
                advance: { generation in
                    advancedGenerations.withValue { $0.append(generation) }
                },
            )
        } operation: {
            makeRootStore(vault: vault)
        }

        await store.send(.applicationPhaseChanged(.background)) {
            $0.applicationReturnPending = true
            _ = $0.vault.commitGlobalLock(
                advanceResourceLoadGeneration: {},
                advanceBrowserProfileConfigurationGeneration: { _ in },
                invalidateBrowserDownloadAuthorization: { BrowserDownloadSnapshot() },
            )
        }
        #expect(advancedGenerations.value == [1])
        await store.finish()
    }

    @Test("Unavailable monotonic time fails closed")
    @MainActor
    func unavailableMonotonicTimeLocksTheVault() async {
        let store = makeRootStore(
            vault: VaultFeature.State(phase: .authenticated),
            now: { nil },
        )

        await store.send(.applicationPhaseChanged(.background)) {
            $0.applicationReturnPending = true
            _ = $0.vault.commitGlobalLock(
                advanceResourceLoadGeneration: {},
                advanceBrowserProfileConfigurationGeneration: { _ in },
                invalidateBrowserDownloadAuthorization: { BrowserDownloadSnapshot() },
            )
        }

        #expect(store.state.vault.phase == .locked)
        await store.finish()
    }

    @Test("A monotonic clock that moves backward fails closed on return")
    @MainActor
    func backwardMonotonicClockLocksTheVault() async {
        let clock = ContinuousClock()
        let backgroundStart = clock.now
        let currentTime = LockIsolated<ContinuousClock.Instant?>(backgroundStart)
        var vault = VaultFeature.State(phase: .authenticated)
        vault.sessionSettings.autoLockTimeout = .minutes15
        let store = makeRootStore(vault: vault, now: { currentTime.value })

        await store.send(.applicationPhaseChanged(.background)) {
            $0.applicationReturnPending = true
            $0.autoLockBackgroundStartedAt = backgroundStart
            $0.autoLockTimeoutAtBackground = VaultAutoLockTimeout.minutes15.duration
        }
        currentTime.withValue { $0 = backgroundStart.advanced(by: .seconds(-1)) }
        await store.send(.applicationPhaseChanged(.active)) {
            $0.autoLockBackgroundStartedAt = nil
            $0.autoLockTimeoutAtBackground = nil
            $0.applicationReturnPending = false
            _ = $0.vault.commitGlobalLock(
                advanceResourceLoadGeneration: {},
                advanceBrowserProfileConfigurationGeneration: { _ in },
                invalidateBrowserDownloadAuthorization: { BrowserDownloadSnapshot() },
            )
        }

        #expect(store.state.vault.phase == .locked)
        await store.finish()
    }

    @Test("An authenticated return without a recorded grace start fails closed")
    @MainActor
    func authenticatedReturnWithoutGraceStartLocksTheVault() async {
        let store = makeRootStore(
            vault: VaultFeature.State(phase: .authenticated),
            applicationReturnPending: true,
        )

        await store.send(.applicationPhaseChanged(.active)) {
            $0.applicationReturnPending = false
            _ = $0.vault.commitGlobalLock(
                advanceResourceLoadGeneration: {},
                advanceBrowserProfileConfigurationGeneration: { _ in },
                invalidateBrowserDownloadAuthorization: { BrowserDownloadSnapshot() },
            )
        }

        #expect(store.state.vault.phase == .locked)
        await store.finish()
    }

    @Test("A pending authentication cannot cross an unvalidated background return")
    @MainActor
    func pendingAuthenticationCannotCrossBackgroundReturn() async {
        var vault = VaultFeature.State(phase: .authentication, configuredKind: .password)
        vault.isWorking = true
        vault.authenticationRequestGeneration = 1
        let store = makeRootStore(
            vault: vault,
            applicationReturnPending: true,
        )

        await store.send(.applicationPhaseChanged(.active)) {
            $0.applicationReturnPending = false
            _ = $0.vault.commitGlobalLock(
                advanceResourceLoadGeneration: {},
                advanceBrowserProfileConfigurationGeneration: { _ in },
                invalidateBrowserDownloadAuthorization: { BrowserDownloadSnapshot() },
            )
        }

        #expect(store.state.vault.phase == .locked)
        #expect(!store.state.vault.isWorking)
        await store.finish()
    }

    @Test("Auto-lock commits at or after each selected grace boundary")
    @MainActor
    func autoLockCommitsAtOrAfterSelectedGraceBoundary() async {
        let timeouts: [(VaultAutoLockTimeout, Duration)] = [
            (.seconds30, .seconds(30)),
            (.minute1, .seconds(60)),
            (.minutes5, .seconds(300)),
            (.minutes15, .seconds(900)),
        ]

        for (timeout, duration) in timeouts {
            for (elapsed, shouldLock) in [
                (duration - .milliseconds(1), false),
                (duration, true),
                (duration + .milliseconds(1), true),
            ] {
                let clock = ContinuousClock()
                let backgroundStart = clock.now
                let currentTime = LockIsolated<ContinuousClock.Instant?>(backgroundStart)
                var vault = VaultFeature.State(phase: .authenticated)
                vault.sessionSettings.autoLockTimeout = timeout
                let store = makeRootStore(vault: vault, now: { currentTime.value })

                await store.send(.applicationPhaseChanged(.background)) {
                    $0.applicationReturnPending = true
                    $0.autoLockBackgroundStartedAt = backgroundStart
                    $0.autoLockTimeoutAtBackground = duration
                }
                currentTime.withValue { $0 = backgroundStart.advanced(by: elapsed) }
                await store.send(.applicationPhaseChanged(.active)) {
                    $0.autoLockBackgroundStartedAt = nil
                    $0.autoLockTimeoutAtBackground = nil
                    $0.applicationReturnPending = false
                    if shouldLock {
                        _ = $0.vault.commitGlobalLock(
                            advanceResourceLoadGeneration: {},
                            advanceBrowserProfileConfigurationGeneration: { _ in },
                            invalidateBrowserDownloadAuthorization: { BrowserDownloadSnapshot() },
                        )
                    }
                }

                if shouldLock {
                    #expect(store.state.vault.phase == .locked)
                } else {
                    #expect(store.state.vault.phase == .authenticated)
                }
                await store.finish()
            }
        }

        var immediateVault = VaultFeature.State(phase: .authenticated)
        immediateVault.sessionSettings.autoLockTimeout = .immediately
        let store = makeRootStore(vault: immediateVault)
        await store.send(.applicationPhaseChanged(.background)) {
            $0.applicationReturnPending = true
            _ = $0.vault.commitGlobalLock(
                advanceResourceLoadGeneration: {},
                advanceBrowserProfileConfigurationGeneration: { _ in },
                invalidateBrowserDownloadAuthorization: { BrowserDownloadSnapshot() },
            )
        }
        #expect(store.state.vault.phase == .locked)
        await store.finish()
    }

    @Test("Application auto-lock fences a queued Library read before dependency start")
    @MainActor
    func automaticLockFencesQueuedLibraryReadBeforeDependencyStart() async {
        let resource = MediaResource(
            id: UUID(),
            role: .original,
            relativePath: "queued/original.jpg",
            sourceFilename: "queued.jpg",
            sourceUTI: "public.jpeg",
            byteCount: 1,
            sha256: String(repeating: "e", count: 64),
        )
        let resourceCalls = LockIsolated(0)
        let mediaLibrary = MediaLibraryClient(
            loadAssets: { [] },
            importFile: { _ in throw MediaImportError.persistenceFailed },
            resourceData: { _ in
                resourceCalls.withValue { $0 += 1 }
                return Data([0x42])
            },
            resourceDataSynchronously: { _ in
                resourceCalls.withValue { $0 += 1 }
                return Data([0x42])
            },
        )
        let readGeneration = mediaLibrary.currentResourceLoadGeneration
        let (readGate, readGateContinuation) = AsyncStream.makeStream(of: Void.self)
        let queuedRead = Task {
            for await _ in readGate {
                break
            }
            _ = try? await mediaLibrary.resourceDataIfCurrent(
                resource,
                generation: readGeneration,
            )
        }
        var vault = VaultFeature.State(phase: .authenticated)
        vault.sessionSettings.autoLockTimeout = .immediately
        let store = makeRootStore(vault: vault, mediaLibrary: mediaLibrary)

        await store.send(.applicationPhaseChanged(.background))
        await store.receive(.vault(.shell(.browser(.sessionLocked))))
        readGateContinuation.yield(())
        readGateContinuation.finish()
        await queuedRead.value
        await store.finish()

        #expect(store.state.vault.phase == .locked)
        #expect(mediaLibrary.currentResourceLoadGeneration == 1)
        #expect(resourceCalls.value == 0)
    }

    @Test("A settings change cannot extend an existing background grace period")
    @MainActor
    func settingsChangeCannotExtendBackgroundGrace() async {
        let clock = ContinuousClock()
        let backgroundStart = clock.now
        let currentTime = LockIsolated<ContinuousClock.Instant?>(backgroundStart)
        var vault = VaultFeature.State(phase: .authenticated)
        vault.sessionSettings.autoLockTimeout = .seconds30
        let store = makeRootStore(vault: vault, now: { currentTime.value })

        await store.send(.applicationPhaseChanged(.background)) {
            $0.applicationReturnPending = true
            $0.autoLockBackgroundStartedAt = backgroundStart
            $0.autoLockTimeoutAtBackground = .seconds(30)
        }
        currentTime.withValue { $0 = backgroundStart.advanced(by: .seconds(20)) }
        await store.send(
            .vault(.sessionSettingsChanged(
                .init(autoLockTimeout: .minutes15, emergencyLockGesture: .off),
            )),
        )
        currentTime.withValue { $0 = backgroundStart.advanced(by: .seconds(30)) }
        await store.send(.applicationPhaseChanged(.active)) {
            $0.autoLockBackgroundStartedAt = nil
            $0.autoLockTimeoutAtBackground = nil
            $0.applicationReturnPending = false
            _ = $0.vault.commitGlobalLock(
                advanceResourceLoadGeneration: {},
                advanceBrowserProfileConfigurationGeneration: { _ in },
                invalidateBrowserDownloadAuthorization: { BrowserDownloadSnapshot() },
            )
        }

        #expect(store.state.vault.phase == .locked)
        await store.finish()
    }

    @Test("Repeated background and intervening inactive notifications preserve the original grace period")
    @MainActor
    func repeatedBackgroundAndInactiveNotificationsPreserveOriginalGracePeriod() async {
        let clock = ContinuousClock()
        let backgroundStart = clock.now
        let currentTime = LockIsolated<ContinuousClock.Instant?>(backgroundStart)
        var vault = VaultFeature.State(phase: .authenticated)
        vault.sessionSettings.autoLockTimeout = .seconds30
        let store = makeRootStore(vault: vault, now: { currentTime.value })

        await store.send(.applicationPhaseChanged(.background)) {
            $0.applicationReturnPending = true
            $0.autoLockBackgroundStartedAt = backgroundStart
            $0.autoLockTimeoutAtBackground = .seconds(30)
        }
        currentTime.withValue { $0 = backgroundStart.advanced(by: .seconds(10)) }
        await store.send(.applicationPhaseChanged(.inactive))
        await store.send(.applicationPhaseChanged(.background))

        #expect(store.state.applicationReturnPending)
        #expect(store.state.autoLockBackgroundStartedAt == backgroundStart)
        #expect(store.state.autoLockTimeoutAtBackground == .seconds(30))

        currentTime.withValue { $0 = backgroundStart.advanced(by: .seconds(30)) }
        await store.send(.applicationPhaseChanged(.active)) {
            $0.autoLockBackgroundStartedAt = nil
            $0.autoLockTimeoutAtBackground = nil
            $0.applicationReturnPending = false
            _ = $0.vault.commitGlobalLock(
                advanceResourceLoadGeneration: {},
                advanceBrowserProfileConfigurationGeneration: { _ in },
                invalidateBrowserDownloadAuthorization: { BrowserDownloadSnapshot() },
            )
        }

        #expect(store.state.vault.phase == .locked)
        await store.finish()
    }

    @Test("Emergency locking requires the selected gesture in a foreground scene")
    @MainActor
    func emergencyLockGestureRequiresSelectionAndForeground() async {
        var vault = VaultFeature.State(phase: .authenticated)
        vault.sessionSettings.emergencyLockGesture = .off
        let mediaLibrary = MediaLibraryClient(
            loadAssets: { [] },
            importFile: { _ in throw MediaImportError.persistenceFailed },
            resourceData: { _ in Data() },
        )
        let store = makeRootStore(vault: vault, mediaLibrary: mediaLibrary)

        await store.send(.emergencyLockGestureRecognized(gesture: .off, isForeground: true))
        #expect(store.state.vault.phase == .authenticated)

        await store.send(.vault(.sessionSettingsChanged(
            .init(autoLockTimeout: .immediately, emergencyLockGesture: .shake),
        )))
        await store.send(.emergencyLockGestureRecognized(gesture: .quadrupleTap, isForeground: true))
        await store.send(.emergencyLockGestureRecognized(gesture: .shake, isForeground: false))
        #expect(store.state.vault.phase == .authenticated)

        await store.send(.emergencyLockGestureRecognized(gesture: .shake, isForeground: true)) {
            _ = $0.vault.commitGlobalLock(
                advanceResourceLoadGeneration: {},
                advanceBrowserProfileConfigurationGeneration: { _ in },
                invalidateBrowserDownloadAuthorization: { BrowserDownloadSnapshot() },
            )
        }
        #expect(store.state.vault.phase == .locked)
        #expect(mediaLibrary.currentResourceLoadGeneration == 1)
        await store.finish()
    }

    @Test("Ordinary, Settings, emergency, and lifecycle locks revoke downloads in the reducer turn")
    @MainActor
    func globalLockRoutesRevokeBrowserDownloadsSynchronously() async {
        let invalidations = LockIsolated(0)
        let invalidateDownloads: @Sendable () -> BrowserDownloadSnapshot = {
            invalidations.withValue { $0 += 1 }
            return BrowserDownloadSnapshot()
        }

        let ordinaryLock = makeRootStore(
            vault: VaultFeature.State(phase: .authenticated),
            browserDownloadAuthorizationInvalidation: invalidateDownloads,
        )
        await ordinaryLock.send(.vault(.lock))
        #expect(invalidations.value == 1)
        await ordinaryLock.finish()

        var settingsVault = VaultFeature.State(phase: .authenticated)
        settingsVault.shell.settingsPresented = true
        let settingsLock = makeRootStore(
            vault: settingsVault,
            browserDownloadAuthorizationInvalidation: invalidateDownloads,
        )
        await settingsLock.send(.vault(.lock))
        #expect(invalidations.value == 2)
        #expect(!settingsLock.state.vault.shell.settingsPresented)
        await settingsLock.finish()

        var emergencyVault = VaultFeature.State(phase: .authenticated)
        emergencyVault.sessionSettings.emergencyLockGesture = .shake
        let emergencyLock = makeRootStore(
            vault: emergencyVault,
            browserDownloadAuthorizationInvalidation: invalidateDownloads,
        )
        await emergencyLock.send(.emergencyLockGestureRecognized(gesture: .shake, isForeground: true))
        #expect(invalidations.value == 3)
        await emergencyLock.finish()

        var expiringVault = VaultFeature.State(phase: .authenticated)
        expiringVault.sessionSettings.autoLockTimeout = .immediately
        let lifecycleExpiry = makeRootStore(
            vault: expiringVault,
            browserDownloadAuthorizationInvalidation: invalidateDownloads,
        )
        await lifecycleExpiry.send(.applicationPhaseChanged(.background))
        #expect(invalidations.value == 4)
        await lifecycleExpiry.finish()
    }

    @Test("Late emergency gesture callbacks respect current policy and vault phase")
    @MainActor
    func lateEmergencyGestureCallbacksRespectCurrentState() {
        func makeStore(vault: VaultFeature.State) -> StoreOf<RootFeature> {
            let decoy = makeRootTestDecoy()
            return Store(
                initialState: RootFeature.State(decoySession: decoy.session, vault: vault),
            ) {
                RootFeature(definition: decoy.definition)
            }
        }

        var disabledVault = VaultFeature.State(phase: .authenticated)
        disabledVault.sessionSettings.emergencyLockGesture = .off
        let disabledStore = makeStore(vault: disabledVault)
        let disabledRootView = RootView(store: disabledStore)
        let disabledObserver = EmergencyLockGestureObserver(
            gesture: .shake,
            isForeground: true,
            onRecognized: { gesture, isForeground in
                disabledRootView.routeEmergencyLockGesture(gesture, isForeground: isForeground)
            },
        )
        disabledObserver.onRecognized(.shake, true)
        #expect(disabledStore.vault.phase == .authenticated)

        var backgroundVault = VaultFeature.State(phase: .authenticated)
        backgroundVault.sessionSettings.emergencyLockGesture = .shake
        let backgroundStore = makeStore(vault: backgroundVault)
        let backgroundRootView = RootView(store: backgroundStore)
        let backgroundObserver = EmergencyLockGestureObserver(
            gesture: .shake,
            isForeground: false,
            onRecognized: { gesture, isForeground in
                backgroundRootView.routeEmergencyLockGesture(gesture, isForeground: isForeground)
            },
        )
        backgroundObserver.onRecognized(.shake, false)
        #expect(backgroundStore.vault.phase == .authenticated)

        var authenticatingVault = VaultFeature.State(phase: .authentication)
        authenticatingVault.sessionSettings.emergencyLockGesture = .shake
        let authenticatingStore = makeStore(vault: authenticatingVault)
        let authenticatingRootView = RootView(store: authenticatingStore)
        let staleObserver = EmergencyLockGestureObserver(
            gesture: .shake,
            isForeground: true,
            onRecognized: { gesture, isForeground in
                authenticatingRootView.routeEmergencyLockGesture(gesture, isForeground: isForeground)
            },
        )
        staleObserver.onRecognized(.shake, true)
        #expect(authenticatingStore.vault.phase == .authentication)

        var configuredVault = VaultFeature.State(phase: .authenticated)
        configuredVault.sessionSettings.emergencyLockGesture = .shake
        let configuredStore = makeStore(vault: configuredVault)
        let configuredRootView = RootView(store: configuredStore)
        let configuredObserver = EmergencyLockGestureObserver(
            gesture: .shake,
            isForeground: true,
            onRecognized: { gesture, isForeground in
                configuredRootView.routeEmergencyLockGesture(gesture, isForeground: isForeground)
            },
        )
        configuredObserver.onRecognized(.shake, true)
        #expect(configuredStore.vault.phase == .locked)
    }
}

private final class PendingVerificationResponse: @unchecked Sendable {
    private enum State {
        case awaitingContinuation
        case suspended(CheckedContinuation<VaultCredentialVerificationResult, Never>)
        case completed(VaultCredentialVerificationResult)
    }

    private let state = LockIsolated<State>(.awaitingContinuation)

    func suspend(onStart: @Sendable () -> Void) async -> VaultCredentialVerificationResult {
        await withCheckedContinuation { continuation in
            let immediateResult = state.withValue { state -> VaultCredentialVerificationResult? in
                switch state {
                case .awaitingContinuation:
                    state = .suspended(continuation)
                    onStart()
                    return nil
                case let .completed(result):
                    return result
                case .suspended:
                    return .unavailable
                }
            }
            if let immediateResult {
                continuation.resume(returning: immediateResult)
            }
        }
    }

    func resumeOnce(with result: VaultCredentialVerificationResult) {
        let continuation = state.withValue { state -> CheckedContinuation<VaultCredentialVerificationResult, Never>? in
            switch state {
            case .awaitingContinuation:
                state = .completed(result)
                return nil
            case let .suspended(continuation):
                state = .completed(result)
                return continuation
            case .completed:
                return nil
            }
        }
        continuation?.resume(returning: result)
    }
}

private final class PendingVerificationStart: @unchecked Sendable {
    private enum State {
        case awaitingContinuation
        case suspended(CheckedContinuation<Bool, Never>)
        case completed(Bool)
    }

    private let state = LockIsolated<State>(.awaitingContinuation)

    func wait() async -> Bool {
        await withCheckedContinuation { continuation in
            let immediateResult = state.withValue { state -> Bool? in
                switch state {
                case .awaitingContinuation:
                    state = .suspended(continuation)
                    return nil
                case let .completed(started):
                    return started
                case .suspended:
                    return false
                }
            }
            if let immediateResult {
                continuation.resume(returning: immediateResult)
            }
        }
    }

    func resumeOnce(started: Bool) {
        let continuation = state.withValue { state -> CheckedContinuation<Bool, Never>? in
            switch state {
            case .awaitingContinuation:
                state = .completed(started)
                return nil
            case let .suspended(continuation):
                state = .completed(started)
                return continuation
            case .completed:
                return nil
            }
        }
        continuation?.resume(returning: started)
    }
}
