//
//  VaultFeatureTests.swift
//  MediaVault
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import ComposableArchitecture
import ConcurrencyExtras
import DecoySupport
import Dependencies
import Foundation
import MediaLibrary
import Sharing
import Testing
import WebKit
@testable import BrowserFeature
@testable import VaultFeature

@Suite("Vault feature")
struct VaultFeatureTests {
    @Test("Rapid settings changes retain the latest preferences when deferred effects run in reverse order")
    @MainActor
    func rapidSessionSettingsChangesRetainLatestPreferences() async throws {
        let suiteName = "VaultFeatureTests.SessionSettings.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let firstSettings = VaultSessionSettings(
            autoLockTimeout: .minutes15,
            emergencyLockGesture: .shake,
        )
        let latestSettings = VaultSessionSettings(
            autoLockTimeout: .seconds30,
            emergencyLockGesture: .quadrupleTap,
        )
        var state = VaultFeature.State(phase: .authenticated)

        let client = withDependencies {
            $0.defaultAppStorage = defaults
        } operation: {
            VaultSessionSettingsClient.liveValue
        }
        let effects = withDependencies {
            $0.vaultSessionSettings = client
        } operation: {
            let reducer = VaultFeature()
            let firstEffect = reducer.reduce(into: &state, action: .sessionSettingsChanged(firstSettings))
            #expect(state.sessionSettings == firstSettings)

            let latestEffect = reducer.reduce(into: &state, action: .sessionSettingsChanged(latestSettings))
            #expect(state.sessionSettings == latestSettings)
            return [firstEffect, latestEffect]
        }

        // Delay effects until both actions have reduced, then run the newer effect first.
        let effectStore = TestStore(initialState: 0) {
            Reduce<Int, VaultFeature.Action> { _, _ in
                .concatenate(effects.reversed())
            }
        }
        await effectStore.send(.sessionSettingsChanged(latestSettings))
        await effectStore.finish()

        let reloadedSettings = withDependencies {
            $0.defaultAppStorage = defaults
        } operation: {
            VaultSessionSettingsClient.liveValue.load()
        }
        #expect(reloadedSettings.autoLockTimeout == .seconds30)
        #expect(reloadedSettings.emergencyLockGesture == .quadrupleTap)
    }

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
            $0.sessionGeneration = 1
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
            $0.setupRequestGeneration = 1
        }
        await store.receive(.setupCompleted(
            sessionGeneration: 1,
            requestGeneration: 1,
            result: .success(.init(kind: .pin, usesHiddenEntry: true)),
        )) {
            $0.phase = .authenticated
            $0.configuredKind = .pin
            $0.usesHiddenEntry = true
            $0.credentialInput = ""
            $0.confirmationInput = ""
            $0.isWorking = false
            $0.shell.isSessionLocked = false
            $0.shell.library.isSessionLocked = false
            $0.shell.browser.isSessionLocked = false
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
            $0.sessionGeneration = 1
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
            $0.sessionSettingsLoaded = true
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
            $0.sessionGeneration = 1
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
            $0.setupRequestGeneration = 1
        }
        await store.receive(.setupCompleted(
            sessionGeneration: 1,
            requestGeneration: 1,
            result: .success(.init(kind: .password, usesHiddenEntry: false)),
        )) {
            $0.phase = .authenticated
            $0.configuredKind = .password
            $0.usesHiddenEntry = false
            $0.credentialInput = ""
            $0.confirmationInput = ""
            $0.isWorking = false
            $0.shell.isSessionLocked = false
            $0.shell.library.isSessionLocked = false
            $0.shell.browser.isSessionLocked = false
        }
    }

    @Test("Authentication succeeds without exposing verifier material")
    @MainActor
    func authenticationSuccessEntersShell() async {
        let savedSettings = LockIsolated<[BrowserSettings]>([])
        var initialState = VaultFeature.State(
            phase: .locked,
            configuredKind: .password,
            usesHiddenEntry: false,
        )
        initialState.shell.browser.profileLifecycle = .ready
        let store = TestStore(initialState: initialState) {
            VaultFeature()
        } withDependencies: {
            $0.vaultCredential.verify = { credential in
                #expect(credential == "пароль")
                return .succeeded
            }
            $0.browserSettings.saveRevisioned = { settings, _ in
                savedSettings.withValue { $0.append(settings) }
            }
        }

        await store.send(.beginAuthentication) {
            $0.phase = .authentication
            $0.sessionGeneration = 1
        }
        await store.send(.authenticationCredentialChanged("пароль")) {
            $0.credentialInput = "пароль"
        }
        await store.send(.submitAuthentication) {
            $0.isWorking = true
            $0.authenticationRequestGeneration = 1
        }
        await store.receive(.authenticationCompleted(
            sessionGeneration: 1,
            requestGeneration: 1,
            result: .succeeded,
        )) {
            $0.phase = .authenticated
            $0.credentialInput = ""
            $0.isWorking = false
            $0.shell.isSessionLocked = false
            $0.shell.library.isSessionLocked = false
            $0.shell.browser.isSessionLocked = false
        }

        await store.send(.shell(.browser(.copiedLinkSuggestionsChanged(true)))) {
            $0.shell.browser.settings.copiedLinkSuggestionsEnabled = true
            $0.shell.browser.settingsRevision = 1
        }
        await store.finish()

        #expect(savedSettings.value == [store.state.shell.browser.settings])
    }

    @Test("A stale authentication completion cannot unlock a locked vault")
    @MainActor
    func authenticationCompletionAfterLockIsIgnored() async {
        let store = TestStore(
            initialState: VaultFeature.State(phase: .authenticated, configuredKind: .password),
        ) {
            VaultFeature()
        }
        store.exhaustivity = .off(showSkippedAssertions: false)
        await store.send(.lock)
        await store.send(.authenticationCompleted(
            sessionGeneration: 0,
            requestGeneration: 1,
            result: .succeeded,
        ))

        #expect(store.state.phase == .locked)
    }

    @Test("Global lock synchronously fences Browser actions before its lock effect")
    @MainActor
    func globalLockSynchronouslyFencesBrowserActions() async throws {
        let tabID = BrowserTabID(UUID(84_001))
        let destination = try #require(URL(string: "https://locked.example"))
        var initialState = VaultFeature.State(phase: .authenticated)
        var browserState = BrowserFeature.State(initialTabID: tabID)
        browserState.profileLifecycle = .ready
        browserState.settings.copiedLinkSuggestionsEnabled = false
        browserState.omniboxDraft = "synthetic private draft"
        browserState.focusedField = .chrome
        var preLockDownloads = BrowserDownloadSnapshot()
        preLockDownloads.revision = 10
        preLockDownloads.generation = 1
        preLockDownloads.isAvailable = true
        preLockDownloads.records = [
            BrowserDownloadRecord(
                id: BrowserDownloadID(),
                tabID: tabID,
                filename: "private-document.pdf",
                receivedBytes: 8,
                expectedBytes: 8,
                isReady: true,
            ),
        ]
        browserState.downloads = preLockDownloads
        browserState.downloadsArePresented = true
        initialState.shell.browser = browserState

        let savedSettings = LockIsolated<[BrowserSettings]>([])
        let executedCommands = LockIsolated<[BrowserWebKitCommand]>([])
        let downloadInvalidationCount = LockIsolated(0)
        let revokedDownloadSnapshot = {
            var snapshot = BrowserDownloadSnapshot()
            snapshot.revision = 11
            snapshot.generation = 2
            snapshot.notice = .unauthorized
            return snapshot
        }()
        let fence = BrowserWebKitProfileConfigurationFence()
        let deferredLockEffect = withDependencies {
            $0.uuid = .incrementing
            $0.browserDownloads.invalidateAuthorization = {
                downloadInvalidationCount.withValue { $0 += 1 }
                return revokedDownloadSnapshot
            }
            $0.browserProfileConfigurationFence = BrowserProfileConfigurationFenceClient(
                advance: { fence.advance(to: $0) },
            )
        } operation: {
            VaultFeature().reduce(into: &initialState, action: .lock)
        }

        #expect(downloadInvalidationCount.value == 1)
        #expect(initialState.phase == .locked)
        #expect(initialState.shell.isSessionLocked)
        #expect(initialState.shell.library.isSessionLocked)
        #expect(initialState.shell.browser.isSessionLocked)
        #expect(initialState.shell.browser.downloads == revokedDownloadSnapshot)
        #expect(!initialState.shell.browser.downloadsArePresented)

        let store = TestStore(initialState: initialState) {
            VaultFeature()
        } withDependencies: {
            $0.uuid = .incrementing
            $0.vaultCredential.verify = { _ in .succeeded }
            $0.browserSettings.saveRevisioned = { settings, _ in
                savedSettings.withValue { $0.append(settings) }
            }
            $0.browserWebKit = BrowserWebKitClient(
                execute: { command in executedCommands.withValue { $0.append(command) } },
                events: { AsyncStream { $0.finish() } },
            )
            $0.browserProfileConfigurationFence = BrowserProfileConfigurationFenceClient(
                advance: { fence.advance(to: $0) },
            )
        }

        await store.send(.shell(.browser(.copiedLinkSuggestionsChanged(true))))
        await store.send(.shell(.browser(.profileChangeRequested(.ephemeral))))
        await store.send(.shell(.browser(.profileChangeConfirmed)))
        await store.send(.shell(.browser(.navigate(destination))))
        await store.finish()

        #expect(!store.state.shell.browser.settings.copiedLinkSuggestionsEnabled)
        #expect(store.state.shell.browser.pendingProfileChange == nil)
        #expect(store.state.shell.browser.settings.browsingProfile == .persistentPrivate)
        #expect(store.state.shell.browser.selectedTab?.isStartPage == true)
        #expect(store.state.shell.browser.pendingWebAction == nil)
        #expect(store.state.shell.browser.omniboxDraft == "synthetic private draft")
        #expect(store.state.shell.browser.focusedField == .chrome)
        #expect(savedSettings.value.isEmpty)
        #expect(executedCommands.value.isEmpty)

        await store.send(.shell(.browser(.sessionLocked))) {
            $0.shell.browser.focusedField = .none
            $0.shell.browser.omniboxDraft = ""
            $0.shell.browser.profileConfigurationGeneration = 1
        }
        await store.finish()

        #expect(store.state.shell.browser.isSessionLocked)
        #expect(store.state.shell.browser.omniboxDraft.isEmpty)
        #expect(store.state.shell.browser.focusedField == .none)
        #expect(savedSettings.value.isEmpty)
        withExtendedLifetime(deferredLockEffect) {}
        let invalidatedGenerations = executedCommands.value.compactMap { command -> UInt64? in
            guard case let .invalidateProfileConfiguration(generation) = command else {
                return nil
            }

            return generation
        }
        #expect(invalidatedGenerations == [1])

        await store.send(.lock)
        await store.finish()
        #expect(invalidatedGenerations.count == 1)
        #expect(executedCommands.value.compactMap { command -> UInt64? in
            guard case let .invalidateProfileConfiguration(generation) = command else {
                return nil
            }

            return generation
        } == [1])

        await store.send(.beginAuthentication) {
            $0.phase = .authentication
            $0.sessionGeneration = 2
        }
        await store.send(.authenticationCredentialChanged("test credential")) {
            $0.credentialInput = "test credential"
        }
        await store.send(.submitAuthentication) {
            $0.isWorking = true
            $0.authenticationRequestGeneration = 2
        }
        await store.receive(.authenticationCompleted(
            sessionGeneration: 2,
            requestGeneration: 2,
            result: .succeeded,
        )) {
            $0.phase = .authenticated
            $0.isWorking = false
            $0.credentialInput = ""
            $0.shell.isSessionLocked = false
            $0.shell.library.isSessionLocked = false
            $0.shell.browser.isSessionLocked = false
        }

        var delayedPreLockSnapshot = BrowserDownloadSnapshot()
        delayedPreLockSnapshot.revision = 12
        delayedPreLockSnapshot.generation = 1
        delayedPreLockSnapshot.isAvailable = true
        delayedPreLockSnapshot.records = [
            BrowserDownloadRecord(
                id: BrowserDownloadID(),
                tabID: tabID,
                filename: "private-document.pdf",
                receivedBytes: 8,
                expectedBytes: 8,
                isReady: true,
            ),
        ]
        await store.send(.shell(.browser(.downloadsChanged(delayedPreLockSnapshot))))

        #expect(store.state.phase == .authenticated)
        #expect(!store.state.shell.browser.isSessionLocked)
        #expect(store.state.shell.browser.downloads == revokedDownloadSnapshot)
        #expect(!store.state.shell.browser.downloadsArePresented)
    }

    @Test("Global vault lock fences pending profile configuration before child cleanup", .timeLimit(.minutes(1)))
    @MainActor
    func globalLockFencesPendingBrowserProfileTransition() async throws {
        let tabID = BrowserTabID(UUID(84))
        var initialState = VaultFeature.State(phase: .authenticated)
        initialState.shell.browser = BrowserFeature.State(initialTabID: tabID)
        initialState.shell.browser.profileLifecycle = .ready
        initialState.shell.browser.omniboxDraft = "synthetic private query"
        initialState.shell.browser.focusedField = .chrome

        let fence = BrowserWebKitProfileConfigurationFence()
        let adapter = BrowserWebKitAdapter(profileConfigurationFence: fence)
        _ = adapter.ensureContext(for: tabID)
        #expect(adapter.hasContext(for: tabID))
        let originalWebView = try #require(adapter.webView(for: tabID))
        let originalDataStore = originalWebView.configuration.websiteDataStore
        #expect(originalDataStore === WKWebsiteDataStore.default())

        let executedCommands = LockIsolated<[BrowserWebKitCommand]>([])
        let (started, startedContinuation) = AsyncStream.makeStream(of: Void.self)
        let (release, releaseContinuation) = AsyncStream.makeStream(of: Void.self)
        let (invalidationCompleted, invalidationContinuation) = AsyncStream.makeStream(of: Void.self)

        var startedIterator = started.makeAsyncIterator()
        var invalidationIterator = invalidationCompleted.makeAsyncIterator()

        let browserWebKit = BrowserWebKitClient(
            execute: { command in
                executedCommands.withValue { $0.append(command) }
                if case let .configureProfileForGeneration(_, _, generation) = command,
                   generation == 1 {
                    startedContinuation.yield(())
                    for await _ in release {
                        break
                    }
                }
                await adapter.execute(command)
                if command == .invalidateProfileConfiguration(generation: 2) {
                    invalidationContinuation.yield(())
                }
            },
            events: { AsyncStream { $0.finish() } },
            advanceProfileConfigurationGeneration: { fence.advance(to: $0) },
        )
        let transitionStore = TestStore(initialState: initialState) {
            VaultFeature()
        } withDependencies: {
            $0.uuid = .incrementing
            $0.browserWebKit = browserWebKit
            $0.browserProfileConfigurationFence = BrowserProfileConfigurationFenceClient(
                advance: { fence.advance(to: $0) },
            )
            $0.vaultCredential.verify = { _ in .succeeded }
            $0.browserSettings.load = { BrowserSettings(browsingProfile: .ephemeral) }
            $0.browserLibrary.loadBookmarks = { [] }
            $0.browserLibrary.loadHistory = { [] }
        }
        transitionStore.exhaustivity = .off(showSkippedAssertions: false)

        await transitionStore.send(.shell(.browser(.profileChangeRequested(.ephemeral))))
        await transitionStore.send(.shell(.browser(.profileChangeConfirmed)))
        let transitionStarted: Void? = await startedIterator.next()
        #expect(transitionStarted != nil)
        #expect(executedCommands.value.contains(.configureProfileForGeneration(
            profile: .ephemeral,
            retiringTabIDs: [tabID],
            generation: 1,
        )))

        await transitionStore.send(.lock)

        #expect(transitionStore.state.phase == .locked)
        #expect(transitionStore.state.shell.browser.isSessionLocked)
        let profileTransitionIsStillPending =
            if case .transitioning = transitionStore.state.shell.browser.profileLifecycle {
                true
            } else {
                false
            }
        #expect(profileTransitionIsStillPending)
        #expect(transitionStore.state.shell.browser.profileConfigurationGeneration == 2)

        await adapter.execute(.configureProfileForGeneration(
            profile: .ephemeral,
            retiringTabIDs: [tabID],
            generation: 1,
        ))
        #expect(adapter.hasContext(for: tabID))
        #expect(adapter.webView(for: tabID) === originalWebView)
        #expect(originalWebView.configuration.websiteDataStore === originalDataStore)

        await transitionStore.receive(.shell(.browser(.sessionLocked)))
        #expect(transitionStore.state.shell.browser.profileLifecycle == .notStarted)
        #expect(transitionStore.state.shell.browser.profileConfigurationGeneration == 2)
        #expect(transitionStore.state.shell.browser.omniboxDraft.isEmpty)
        #expect(transitionStore.state.shell.browser.focusedField == .none)

        releaseContinuation.yield(())
        releaseContinuation.finish()
        await transitionStore.finish()

        #expect(adapter.hasContext(for: tabID))
        #expect(adapter.webView(for: tabID) === originalWebView)
        #expect(originalWebView.configuration.websiteDataStore === originalDataStore)

        #expect(transitionStore.state.shell.browser.profileLifecycle == .notStarted)
        #expect(transitionStore.state.shell.browser.profileConfigurationGeneration == 2)
        #expect(transitionStore.state.shell.browser.omniboxDraft.isEmpty)
        #expect(transitionStore.state.shell.browser.focusedField == .none)
        let invalidationDidComplete: Void? = await invalidationIterator.next()
        #expect(invalidationDidComplete != nil)
        let invalidatedGenerations = executedCommands.value.compactMap { command -> UInt64? in
            guard case let .invalidateProfileConfiguration(generation) = command else {
                return nil
            }

            return generation
        }
        #expect(invalidatedGenerations == [2])

        await transitionStore.send(.lock)
        await transitionStore.finish()
        let invalidatedGenerationsAfterRepeatedLock = executedCommands.value.compactMap { command -> UInt64? in
            guard case let .invalidateProfileConfiguration(generation) = command else {
                return nil
            }

            return generation
        }
        #expect(invalidatedGenerationsAfterRepeatedLock == [2])

        await transitionStore.send(.beginAuthentication)
        await transitionStore.send(.authenticationCredentialChanged("synthetic credential"))
        await transitionStore.send(.submitAuthentication)
        let authenticationSessionGeneration = transitionStore.state.sessionGeneration
        let authenticationRequestGeneration = transitionStore.state.authenticationRequestGeneration
        await transitionStore.receive(.authenticationCompleted(
            sessionGeneration: authenticationSessionGeneration,
            requestGeneration: authenticationRequestGeneration,
            result: .succeeded,
        ))

        #expect(transitionStore.state.phase == .authenticated)
        #expect(!transitionStore.state.shell.browser.isSessionLocked)

        await transitionStore.send(.shell(.browser(.profileInitializationRequested)))
        let profileRequestID = try #require(transitionStore.state.shell.browser.profileConfigurationRequestID)
        await transitionStore.receive(.shell(.browser(.loaded(
            settings: BrowserSettings(browsingProfile: .ephemeral),
            bookmarks: [],
            history: [],
            profileConfigurationID: profileRequestID,
        ))))

        #expect(transitionStore.state.phase == .authenticated)
        #expect(transitionStore.state.shell.browser.profileLifecycle == .ready)
        #expect(transitionStore.state.shell.browser.profileConfigurationGeneration == 3)
        #expect(executedCommands.value.contains(.invalidateProfileConfiguration(generation: 2)))
        #expect(executedCommands.value.contains(.configureProfileForGeneration(
            profile: .ephemeral,
            retiringTabIDs: [],
            generation: 3,
        )))
        #expect(!adapter.hasContext(for: tabID))
        let reauthenticatedTabID = BrowserTabID(UUID(85))
        let reauthenticatedWebView = adapter.ensureContext(for: reauthenticatedTabID)
        #expect(reauthenticatedWebView.configuration.websiteDataStore !== WKWebsiteDataStore.default())
        adapter.destroyContext(for: reauthenticatedTabID)

        startedContinuation.finish()
        invalidationContinuation.finish()
    }

    @Test("A locked vault rejects retained authenticated shell actions")
    @MainActor
    func lockedVaultRejectsSettingsPresentation() async {
        let store = TestStore(
            initialState: VaultFeature.State(phase: .locked),
        ) {
            VaultFeature()
        }

        await store.send(.shell(.settingsTapped))

        #expect(store.state.phase == .locked)
        #expect(!store.state.shell.settingsPresented)
    }

    @Test("A durable Library import completion remains effective after global lock")
    @MainActor
    func lockedVaultAcceptsDurableImportCompletion() async {
        var initialState = VaultFeature.State(phase: .authenticated)
        initialState.shell.library.isImporting = true
        initialState.shell.library.resourceData[UUID(90_003)] = Data([0x42])
        let store = TestStore(initialState: initialState) { VaultFeature() }
        store.exhaustivity = .off(showSkippedAssertions: false)

        await store.send(.lock)
        await store.send(.shell(.library(.importCompleted(.failure(.persistenceFailed)))))

        #expect(store.state.phase == .locked)
        #expect(!store.state.shell.library.isImporting)
        #expect(store.state.shell.library.resourceData.isEmpty)
    }

    @Test("Library completions after lock skip private reads and preserve durable ingestion")
    @MainActor
    func libraryCompletionsAfterLockDeferPrivateResourceReads() async {
        let existingResource = MediaResource(
            id: UUID(),
            role: .original,
            relativePath: "existing/original.jpg",
            sourceFilename: "existing.jpg",
            sourceUTI: "public.jpeg",
            byteCount: 1,
            sha256: String(repeating: "a", count: 64),
        )
        let existingAsset = MediaAsset(
            id: UUID(),
            kind: .stillImage,
            importedAt: Date(timeIntervalSince1970: 1),
            resources: [existingResource],
        )
        let importedResource = MediaResource(
            id: UUID(),
            role: .original,
            relativePath: "imported/original.jpg",
            sourceFilename: "imported.jpg",
            sourceUTI: "public.jpeg",
            byteCount: 1,
            sha256: String(repeating: "b", count: 64),
        )
        let importedAsset = MediaAsset(
            id: UUID(),
            kind: .stillImage,
            importedAt: Date(timeIntervalSince1970: 2),
            resources: [importedResource],
        )
        let (loadedAssets, loadedAssetsContinuation) = AsyncStream.makeStream(of: [MediaAsset].self)
        let (loadStarted, loadStartedContinuation) = AsyncStream.makeStream(of: Void.self)
        let (importedAssetResult, importedAssetContinuation) = AsyncStream.makeStream(of: MediaAsset.self)
        let (importStarted, importStartedContinuation) = AsyncStream.makeStream(of: Void.self)
        var loadStartedIterator = loadStarted.makeAsyncIterator()
        var importStartedIterator = importStarted.makeAsyncIterator()
        let resourceReads = LockIsolated<[UUID]>([])

        let store = TestStore(initialState: VaultFeature.State(phase: .authenticated)) {
            VaultFeature()
        } withDependencies: {
            $0.mediaLibrary = MediaLibraryClient(
                loadAssets: {
                    loadStartedContinuation.yield(())
                    for await assets in loadedAssets {
                        return assets
                    }
                    return []
                },
                importFile: { _ in
                    importStartedContinuation.yield(())
                    for await asset in importedAssetResult {
                        return asset
                    }
                    throw MediaImportError.persistenceFailed
                },
                resourceData: { resource in
                    resourceReads.withValue { $0.append(resource.id) }
                    return Data([0x42])
                },
            )
        }
        store.exhaustivity = .off(showSkippedAssertions: false)

        await store.send(.shell(.library(.task)))
        let loadDidStart: Void? = await loadStartedIterator.next()
        #expect(loadDidStart != nil)
        await store.send(.shell(.library(.importTapped)))
        await store.send(.shell(.library(.fileSelected(URL(fileURLWithPath: "/provider/imported.jpg")))))
        let importDidStart: Void? = await importStartedIterator.next()
        #expect(importDidStart != nil)

        await store.send(.lock)
        await store.receive(.shell(.browser(.sessionLocked)))
        loadedAssetsContinuation.yield([existingAsset])
        await store.receive(.shell(.library(.assetsLoadCompleted(
            generation: 0,
            result: .success([existingAsset]),
        ))))
        #expect(store.state.shell.library.resourceData.isEmpty)
        #expect(resourceReads.value.isEmpty)

        importedAssetContinuation.yield(importedAsset)
        await store.receive(.shell(.library(.importCompleted(.success(importedAsset)))))
        await store.finish()

        #expect(store.state.phase == .locked)
        #expect(store.state.shell.library.isSessionLocked)
        #expect(!store.state.shell.library.isImporting)
        #expect(!store.state.shell.library.isPickerPresented)
        #expect(store.state.shell.library.assets == [existingAsset, importedAsset])
        #expect(store.state.shell.library.resourceData.isEmpty)
        #expect(resourceReads.value.isEmpty)

        loadedAssetsContinuation.finish()
        loadStartedContinuation.finish()
        importedAssetContinuation.finish()
        importStartedContinuation.finish()
    }

    @Test("Global lock cancels a pending Library resource read")
    @MainActor
    func globalLockCancelsPendingLibraryResourceRead() async {
        let resource = MediaResource(
            id: UUID(),
            role: .original,
            relativePath: "pending/original.jpg",
            sourceFilename: "pending.jpg",
            sourceUTI: "public.jpeg",
            byteCount: 1,
            sha256: String(repeating: "c", count: 64),
        )
        let asset = MediaAsset(
            id: UUID(),
            kind: .stillImage,
            importedAt: Date(timeIntervalSince1970: 3),
            resources: [resource],
        )
        let (started, startedContinuation) = AsyncStream.makeStream(of: UUID.self)
        let (release, releaseContinuation) = AsyncStream.makeStream(of: Void.self)
        var startedIterator = started.makeAsyncIterator()
        let resourceReads = LockIsolated<[UUID]>([])
        let cancellationObserved = LockIsolated(false)

        let store = TestStore(initialState: VaultFeature.State(phase: .authenticated)) {
            VaultFeature()
        } withDependencies: {
            $0.mediaLibrary.resourceData = { resource in
                startedContinuation.yield(resource.id)
                for await _ in release {
                    break
                }
                guard !Task.isCancelled else {
                    cancellationObserved.withValue { $0 = true }
                    return Data([0x42])
                }

                resourceReads.withValue { $0.append(resource.id) }
                return Data([0x42])
            }
        }
        store.exhaustivity = .off(showSkippedAssertions: false)

        await store.send(.shell(.library(.assetsLoadCompleted(
            generation: 0,
            result: .success([asset]),
        ))))
        let startedResourceID = await startedIterator.next()
        #expect(startedResourceID == resource.id)

        await store.send(.lock)
        await store.receive(.shell(.browser(.sessionLocked)))
        releaseContinuation.yield(())
        await store.finish()

        #expect(store.state.shell.library.isSessionLocked)
        #expect(store.state.shell.library.resourceData.isEmpty)
        #expect(resourceReads.value.isEmpty)
        #expect(cancellationObserved.value)

        startedContinuation.finish()
        releaseContinuation.finish()
    }

    @Test("A queued Library read never reaches its dependency after global lock")
    @MainActor
    func globalLockFencesQueuedLibraryReadBeforeDependencyStart() async {
        let resource = MediaResource(
            id: UUID(),
            role: .original,
            relativePath: "queued/original.jpg",
            sourceFilename: "queued.jpg",
            sourceUTI: "public.jpeg",
            byteCount: 1,
            sha256: String(repeating: "d", count: 64),
        )
        let asset = MediaAsset(
            id: UUID(),
            kind: .stillImage,
            importedAt: Date(timeIntervalSince1970: 4),
            resources: [resource],
        )
        let resourceCalls = LockIsolated(0)
        let mediaLibrary = MediaLibraryClient(
            loadAssets: { [asset] },
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

        let store = TestStore(initialState: VaultFeature.State(
            phase: .authenticated,
            configuredKind: .password,
        )) {
            VaultFeature()
        } withDependencies: {
            $0.mediaLibrary = mediaLibrary
            $0.vaultCredential.verify = { _ in .succeeded }
        }
        store.exhaustivity = .off(showSkippedAssertions: false)

        await store.send(.lock)
        readGateContinuation.yield(())
        readGateContinuation.finish()
        await queuedRead.value

        #expect(mediaLibrary.currentResourceLoadGeneration == 1)
        #expect(resourceCalls.value == 0)

        await store.send(.beginAuthentication) {
            $0.phase = .authentication
            $0.sessionGeneration = 2
        }
        await store.send(.authenticationCredentialChanged("password")) {
            $0.credentialInput = "password"
        }
        await store.send(.submitAuthentication) {
            $0.isWorking = true
            $0.authenticationRequestGeneration = 2
        }
        await store.receive(.authenticationCompleted(
            sessionGeneration: 2,
            requestGeneration: 2,
            result: .succeeded,
        )) {
            $0.phase = .authenticated
            $0.credentialInput = ""
            $0.isWorking = false
            $0.shell.isSessionLocked = false
            $0.shell.library.isSessionLocked = false
            $0.shell.browser.isSessionLocked = false
        }

        await store.send(.shell(.library(.resourceLoadCompleted(
            resourceID: resource.id,
            generation: 0,
            result: .success(Data([0x24])),
        ))))
        await store.send(.shell(.library(.resourceLoadCompleted(
            resourceID: resource.id,
            generation: 0,
            result: .failure(.unavailable),
        ))))
        #expect(store.state.shell.library.resourceData.isEmpty)
        #expect(store.state.shell.library.error == nil)

        await store.send(.shell(.library(.task))) {
            $0.shell.library.isLoading = true
        }
        await store.receive(.shell(.library(.assetsLoadCompleted(
            generation: 1,
            result: .success([asset]),
        )))) {
            $0.shell.library.isLoading = false
            $0.shell.library.assets = [asset]
        }
        await store.receive(.shell(.library(.resourceLoadCompleted(
            resourceID: resource.id,
            generation: 1,
            result: .success(Data([0x42])),
        )))) {
            $0.shell.library.resourceData[resource.id] = Data([0x42])
        }

        #expect(mediaLibrary.currentResourceLoadGeneration == 1)
        #expect(resourceCalls.value == 1)
        #expect(store.state.shell.library.resourceData[resource.id] == Data([0x42]))

        await store.send(.lock)
        await store.receive(.shell(.browser(.sessionLocked)))
        #expect(mediaLibrary.currentResourceLoadGeneration == 2)
        #expect(store.state.shell.library.resourceData.isEmpty)
        await store.send(.lock)
        #expect(mediaLibrary.currentResourceLoadGeneration == 2)
        await store.finish()
    }

    @Test("A pre-lock Library load cannot replace the post-unlock snapshot")
    @MainActor
    func staleLibraryLoadCannotOverwriteFreshSnapshotAfterUnlock() async {
        let staleAsset = MediaAsset(
            id: UUID(),
            kind: .stillImage,
            importedAt: Date(timeIntervalSince1970: 5),
            resources: [],
        )
        let freshAsset = MediaAsset(
            id: UUID(),
            kind: .stillImage,
            importedAt: Date(timeIntervalSince1970: 6),
            resources: [],
        )
        let (loadStarted, loadStartedContinuation) = AsyncStream.makeStream(of: Int.self)
        let (staleLoadResults, staleLoadContinuation) =
            AsyncStream.makeStream(of: Result<[MediaAsset], MediaLibraryStoreError>.self)
        let (freshLoadResults, freshLoadContinuation) =
            AsyncStream.makeStream(of: Result<[MediaAsset], MediaLibraryStoreError>.self)
        var loadStartedIterator = loadStarted.makeAsyncIterator()
        let loadCallIndex = LockIsolated(0)
        let mediaLibrary = MediaLibraryClient(
            loadAssets: {
                let requestIndex = loadCallIndex.withValue { currentIndex in
                    defer { currentIndex += 1 }
                    return currentIndex
                }
                loadStartedContinuation.yield(requestIndex)
                let responses = requestIndex == 0 ? staleLoadResults : freshLoadResults
                for await result in responses {
                    return try result.get()
                }
                throw MediaLibraryStoreError.unavailable
            },
            importFile: { _ in throw MediaImportError.persistenceFailed },
            resourceData: { _ in Data([0x42]) },
        )
        let store = TestStore(initialState: VaultFeature.State(
            phase: .authenticated,
            configuredKind: .password,
        )) {
            VaultFeature()
        } withDependencies: {
            $0.mediaLibrary = mediaLibrary
            $0.vaultCredential.verify = { _ in .succeeded }
        }
        store.exhaustivity = .off(showSkippedAssertions: false)

        await store.send(.shell(.library(.task))) {
            $0.shell.library.isLoading = true
        }
        #expect(await loadStartedIterator.next() == 0)

        await store.send(.lock)
        await store.receive(.shell(.browser(.sessionLocked)))
        #expect(mediaLibrary.currentResourceLoadGeneration == 1)

        await store.send(.beginAuthentication) {
            $0.phase = .authentication
            $0.sessionGeneration = 2
        }
        await store.send(.authenticationCredentialChanged("password")) {
            $0.credentialInput = "password"
        }
        await store.send(.submitAuthentication) {
            $0.isWorking = true
            $0.authenticationRequestGeneration = 2
        }
        await store.receive(.authenticationCompleted(
            sessionGeneration: 2,
            requestGeneration: 2,
            result: .succeeded,
        )) {
            $0.phase = .authenticated
            $0.credentialInput = ""
            $0.isWorking = false
            $0.shell.isSessionLocked = false
            $0.shell.library.isSessionLocked = false
            $0.shell.browser.isSessionLocked = false
        }

        await store.send(.shell(.library(.task))) {
            $0.shell.library.isLoading = true
        }
        #expect(await loadStartedIterator.next() == 1)
        freshLoadContinuation.yield(.success([freshAsset]))
        await store.receive(.shell(.library(.assetsLoadCompleted(
            generation: 1,
            result: .success([freshAsset]),
        )))) {
            $0.shell.library.isLoading = false
            $0.shell.library.assets = [freshAsset]
        }

        staleLoadContinuation.yield(.success([staleAsset]))
        await store.receive(.shell(.library(.assetsLoadCompleted(
            generation: 0,
            result: .success([staleAsset]),
        ))))
        await store.send(.shell(.library(.assetsLoadCompleted(
            generation: 0,
            result: .failure(.unavailable),
        ))))

        #expect(store.state.shell.library.assets == [freshAsset])
        #expect(store.state.shell.library.error == nil)
        #expect(!store.state.shell.library.isLoading)
        await store.finish()

        loadStartedContinuation.finish()
        staleLoadContinuation.finish()
        freshLoadContinuation.finish()
    }

    @Test("An admitted Library read does not delay the lock boundary", .timeLimit(.minutes(1)))
    @MainActor
    func admittedLibraryReadDoesNotBlockLockGenerationAdvance() async {
        let resource = MediaResource(
            id: UUID(),
            role: .original,
            relativePath: "in-flight/original.jpg",
            sourceFilename: "in-flight.jpg",
            sourceUTI: "public.jpeg",
            byteCount: 1,
            sha256: String(repeating: "f", count: 64),
        )
        let resourceCalls = LockIsolated(0)
        let (readerStarted, readerStartedContinuation) = AsyncStream.makeStream(of: Void.self)
        let (readRelease, readReleaseContinuation) = AsyncStream.makeStream(of: Void.self)
        var readerStartedIterator = readerStarted.makeAsyncIterator()
        let mediaLibrary = MediaLibraryClient(
            loadAssets: { [] },
            importFile: { _ in throw MediaImportError.persistenceFailed },
            resourceData: { _ in
                resourceCalls.withValue { $0 += 1 }
                readerStartedContinuation.yield(())
                for await _ in readRelease {
                    break
                }
                return Data([0x42])
            },
        )
        let store = TestStore(initialState: VaultFeature.State(phase: .authenticated)) {
            VaultFeature()
        } withDependencies: {
            $0.mediaLibrary = mediaLibrary
        }
        store.exhaustivity = .off(showSkippedAssertions: false)
        let readGeneration = mediaLibrary.currentResourceLoadGeneration
        let read = Task.detached {
            try? await mediaLibrary.resourceDataIfCurrent(resource, generation: readGeneration)
        }
        #expect(await readerStartedIterator.next() != nil)

        await store.send(.lock)
        await store.receive(.shell(.browser(.sessionLocked)))
        #expect(store.state.phase == .locked)
        #expect(mediaLibrary.currentResourceLoadGeneration == 1)
        #expect(resourceCalls.value == 1)

        let staleRead = try? await mediaLibrary.resourceDataIfCurrent(
            resource,
            generation: readGeneration,
        )
        #expect(staleRead == nil)
        #expect(resourceCalls.value == 1)

        readReleaseContinuation.yield(())
        readReleaseContinuation.finish()
        let inFlightRead = await read.value
        #expect(inFlightRead == nil)
        #expect(resourceCalls.value == 1)
        await store.finish()
        readerStartedContinuation.finish()
    }

    @Test("Normal authentication cancels a pending hidden verification")
    @MainActor
    func normalAuthenticationCancelsPendingHiddenVerification() async {
        let (stream, continuation) = AsyncStream.makeStream(of: VaultCredentialVerificationResult.self)
        let attemptID = DecoyHiddenEntryAttempt.ID(UUID())
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

        await store.send(.verifyHidden(attemptID: attemptID, candidate: .init("1234"))) {
            $0.isWorking = true
            $0.pendingHiddenVerificationID = attemptID
            $0.hiddenVerificationRequestGeneration = 1
        }
        await store.send(.beginAuthentication) {
            $0.phase = .authentication
            $0.isWorking = false
            $0.pendingHiddenVerificationID = nil
            $0.sessionGeneration = 1
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
            $0.setupRequestGeneration = 1
        }
        await store.receive(.setupCompleted(
            sessionGeneration: 0,
            requestGeneration: 1,
            result: .failure(.alreadyConfigured),
        )) {
            $0.phase = .loading
            $0.error = nil
            $0.credentialInput = ""
            $0.confirmationInput = ""
            $0.isWorking = false
        }
        await store.receive(.task) {
            $0.isWorking = true
            $0.sessionSettingsLoaded = true
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
        let pendingID = DecoyHiddenEntryAttempt.ID(UUID())
        let staleID = DecoyHiddenEntryAttempt.ID(UUID())
        var initialState = VaultFeature.State(
            phase: .locked,
            configuredKind: .pin,
            usesHiddenEntry: true,
        )
        initialState.isWorking = true
        initialState.pendingHiddenVerificationID = pendingID
        initialState.hiddenVerificationRequestGeneration = 1
        let store = TestStore(
            initialState: initialState,
        ) {
            VaultFeature()
        }
        await store.send(.hiddenVerificationCompleted(
            sessionGeneration: 0,
            requestGeneration: 1,
            attemptID: staleID,
            result: .success(true),
        ))
        #expect(store.state.phase == .locked)
        #expect(store.state.isWorking)
        #expect(store.state.pendingHiddenVerificationID == pendingID)
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

@Suite("Vault availability")
struct VaultAvailabilityTests {
    @Test("An unavailable configuration can be retried without entering setup")
    @MainActor
    func unavailableConfigurationCanBeRetried() async {
        let configuration = VaultCredentialConfiguration(kind: .pin, usesHiddenEntry: true)
        let loadCalls = LockIsolated(0)
        let store = TestStore(initialState: VaultFeature.State(phase: .unavailable)) {
            VaultFeature()
        } withDependencies: {
            $0.vaultCredential.loadConfiguration = {
                loadCalls.withValue { $0 += 1 }
                return configuration
            }
        }

        await store.send(.retryConfiguration) {
            $0.phase = .loading
            $0.error = nil
            $0.isWorking = true
        }
        await store.receive(.configurationLoaded(.success(configuration))) {
            $0.phase = .locked
            $0.configuredKind = .pin
            $0.usesHiddenEntry = true
            $0.isWorking = false
        }
        #expect(loadCalls.value == 1)
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

    @Test("A failed verification persists and expires a retry throttle")
    func failedVerificationPersistsRetryThrottle() async throws {
        let storage = TestCredentialStorage()
        let initialDate = Date(timeIntervalSince1970: 1_800_000_000)
        let clock = LockIsolated(initialDate)
        let adapter = VaultCredentialLiveAdapter(
            storage: storage,
            randomBytes: { count in Data(repeating: 0xa5, count: count) },
            now: { clock.value },
        ).client

        _ = try await adapter.configure(.pin, "1234", false)
        let initialResult = await adapter.verify("0000")
        #expect(initialResult == .incorrect)

        let persisted = try #require(await storage.data)
        let persistedRetryAfter = try #require(
            JSONDecoder().decode(PersistedCredentialCooldown.self, from: persisted).retryAfter,
        )
        #expect(abs(persistedRetryAfter.timeIntervalSince(initialDate.addingTimeInterval(1))) < 0.001)

        let reloadedClient = VaultCredentialLiveAdapter(
            storage: storage,
            randomBytes: { count in Data(repeating: 0xa5, count: count) },
            now: { clock.value },
        ).client
        let activeCooldownResult = await reloadedClient.verify("1111")
        #expect(activeCooldownResult == .unavailable)

        clock.withValue { $0 = persistedRetryAfter.addingTimeInterval(0.001) }
        let resumedResult = await reloadedClient.verify("1234")
        #expect(resumedResult == .succeeded)

        let clearedRecord = try #require(await storage.data)
        let clearedRetryAfter = try JSONDecoder()
            .decode(
                PersistedCredentialCooldown.self,
                from: clearedRecord,
            )
            .retryAfter
        #expect(clearedRetryAfter == nil)
    }

    @Test("A failed derivation starts the full retry cooldown after verification completes")
    func failedDerivationStartsRetryCooldownAfterVerificationCompletes() async throws {
        let storage = TestCredentialStorage()
        let startDate = Date(timeIntervalSince1970: 1_800_000_000)
        let clock = LockIsolated(startDate)
        let advancesClockAfterInitialRead = LockIsolated(false)
        let adapter = VaultCredentialLiveAdapter(
            storage: storage,
            randomBytes: { count in Data(repeating: 0xa5, count: count) },
            now: {
                let sampledDate = clock.value
                // Model slow derivation by advancing independent time after the attempt's initial sample.
                let shouldAdvanceClock = advancesClockAfterInitialRead.withValue { hasAdvanced in
                    guard !hasAdvanced else {
                        return false
                    }

                    hasAdvanced = true
                    return true
                }
                if shouldAdvanceClock {
                    clock.withValue { $0 = sampledDate.addingTimeInterval(2) }
                }
                return sampledDate
            },
        ).client

        _ = try await adapter.configure(.pin, "1234", false)
        let initialResult = await adapter.verify("0000")
        #expect(initialResult == .incorrect)

        let persisted = try #require(await storage.data)
        let persistedRetryAfter = try #require(
            JSONDecoder().decode(PersistedCredentialCooldown.self, from: persisted).retryAfter,
        )
        let expectedDeadline = startDate.addingTimeInterval(3)
        #expect(abs(persistedRetryAfter.timeIntervalSince(expectedDeadline)) < 0.001)
        #expect(persistedRetryAfter > clock.value)

        let reloadedClient = VaultCredentialLiveAdapter(
            storage: storage,
            randomBytes: { count in Data(repeating: 0xa5, count: count) },
            now: { clock.value },
        ).client
        let reconstructedResult = await reloadedClient.verify("1111")
        #expect(reconstructedResult == .unavailable)
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

private struct PersistedCredentialCooldown: Decodable {
    let retryAfter: Date?
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
