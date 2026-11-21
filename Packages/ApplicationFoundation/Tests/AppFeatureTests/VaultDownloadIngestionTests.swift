//
//  VaultDownloadIngestionTests.swift
//  MediaVault
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import ComposableArchitecture
import MediaLibrary
import Testing
@testable import AppFeature
@testable import VaultFeature

@Suite("Vault ingestion authorization")
struct VaultDownloadIngestionTests {
    @Test("Foreground return restores processing eligibility before credentials succeed")
    @MainActor
    func foregroundBeforeAuthenticationRestoresEligibility() async {
        let library = MediaLibraryClient.testValue
        library.suspendDownloadIngestion()
        let suspendedGeneration = library.currentDownloadIngestionGeneration
        let fixture = makeRootTestDecoy()
        var vault = VaultFeature.State(phase: .authentication, configuredKind: .pin)
        vault.isWorking = true
        let store = TestStore(initialState: RootFeature.State(decoySession: fixture.session, vault: vault)) {
            RootFeature(definition: fixture.definition)
        } withDependencies: {
            $0.mediaLibrary = library
        }
        store.exhaustivity = .off(showSkippedAssertions: false)

        await store.send(.applicationPhaseChanged(.active))
        #expect(store.state.vault.phase == .authentication)
        #expect(library.currentDownloadIngestionGeneration != suspendedGeneration)

        await store.send(.vault(.authenticationCompleted(
            sessionGeneration: vault.sessionGeneration,
            requestGeneration: vault.authenticationRequestGeneration,
            result: .succeeded,
        )))
        #expect(store.state.vault.phase == .authenticated)
        await store.finish()
    }

    @Test("Successful authentication grants a new ingestion generation without mounting Library")
    @MainActor
    func authenticationStartsIngestionSession() async {
        let library = MediaLibraryClient.testValue
        var state = VaultFeature.State(phase: .authentication, configuredKind: .pin)
        state.isWorking = true
        let store = TestStore(initialState: state) { VaultFeature() } withDependencies: {
            $0.mediaLibrary = library
        }
        store.exhaustivity = .off(showSkippedAssertions: false)
        let before = library.currentDownloadIngestionGeneration

        await store.send(.authenticationCompleted(
            sessionGeneration: state.sessionGeneration,
            requestGeneration: state.authenticationRequestGeneration,
            result: .succeeded,
        ))

        #expect(store.state.phase == .authenticated)
        #expect(library.currentDownloadIngestionGeneration != before)
        #expect(!store.state.shell.library.isSessionLocked)
        await store.finish()
    }

    @Test("Inactive and background phases fence ingestion without expiring the session", arguments: [false, true])
    @MainActor
    func privacyTransitionSuspendsIngestion(background: Bool) async {
        let library = MediaLibraryClient.testValue
        let originalGeneration = library.beginAuthenticatedDownloadSession()
        let fixture = makeRootTestDecoy()
        var vault = VaultFeature.State(phase: .authenticated, configuredKind: .pin)
        vault.sessionSettings.autoLockTimeout = .seconds30
        let instant = ContinuousClock().now
        let store = TestStore(initialState: RootFeature.State(decoySession: fixture.session, vault: vault)) {
            RootFeature(definition: fixture.definition)
        } withDependencies: {
            $0.mediaLibrary = library
            $0.vaultSessionClock.now = { instant }
        }
        store.exhaustivity = .off(showSkippedAssertions: false)

        await store.send(.applicationPhaseChanged(background ? .background : .inactive))
        let suspendedGeneration = library.currentDownloadIngestionGeneration
        #expect(suspendedGeneration != originalGeneration)
        #expect(store.state.vault.phase == .authenticated)

        await store.send(.applicationPhaseChanged(.active))
        #expect(library.currentDownloadIngestionGeneration != suspendedGeneration)
        #expect(store.state.vault.phase == .authenticated)
        await store.finish()
    }
}
