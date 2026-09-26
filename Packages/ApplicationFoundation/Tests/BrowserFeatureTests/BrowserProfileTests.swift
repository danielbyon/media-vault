//
//  BrowserProfileTests.swift
//  MediaVault
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import ComposableArchitecture
@preconcurrency import Foundation
import SwiftUI
import Testing
import UIKit
import WebKit
@testable import BrowserFeature

extension BrowserFeature.State {
    /// Creates a logical Browser state whose stored profile has already been configured.
    static func readyForTesting(initialTabID: BrowserTabID = .init()) -> Self {
        var state = Self(initialTabID: initialTabID)
        state.profileLifecycle = .ready
        return state
    }

    /// Creates a tabbed Browser state whose stored profile has already been configured.
    static func readyForTesting(
        tabs: [BrowserTab],
        selectedTabID: BrowserTabID,
        presentation: BrowserPresentation = .browsing,
        focusedField: BrowserFocusedField = .none,
        omniboxDraft: String = "",
    ) -> Self {
        var state = Self(
            tabs: tabs,
            selectedTabID: selectedTabID,
            presentation: presentation,
            focusedField: focusedField,
            omniboxDraft: omniboxDraft,
        )
        state.profileLifecycle = .ready
        return state
    }
}

@Suite("Browser profile transitions")
@MainActor
struct BrowserProfileTests {
    @Test("Startup waits for the stored Ephemeral profile before creating a context")
    func startupConfigurationGatesNavigation() async throws {
        let gate = BrowserProfileConfigurationGate()
        let createdStores = LockIsolated<[WKWebsiteDataStore]>([])
        let adapter = BrowserWebKitAdapter(
            requiresProfileConfiguration: true,
            makeWebView: { frame, configuration in
                createdStores.withValue { $0.append(configuration.websiteDataStore) }
                return WKWebView(frame: frame, configuration: configuration)
            },
        )
        let fixture = BrowserProfileWebKitFixture(adapter: adapter, gate: gate)
        let destination = try #require(URL(string: "https://startup.example"))
        let ephemeralSettings = BrowserSettings(browsingProfile: .ephemeral)
        let store = TestStore(initialState: BrowserFeature.State()) {
            BrowserFeature()
        } withDependencies: {
            $0.uuid = .incrementing
            $0.browserSettings.load = { ephemeralSettings }
            $0.browserLibrary.loadBookmarks = { [] }
            $0.browserLibrary.loadHistory = { [] }
            $0.browserWebKit = BrowserWebKitClient(
                execute: { command in await fixture.execute(command) },
                events: { AsyncStream { $0.finish() } },
            )
        }
        store.exhaustivity = .off
        await store.send(.task)
        #expect(await gate.waitUntilStarted() == .ephemeral)
        let configurationID = try #require(store.state.profileConfigurationRequestID)

        await store.send(.navigate(destination))

        #expect(store.state.pendingWebAction == .navigate(tabID: store.state.selectedTabID, url: destination))
        #expect(store.state.selectedTab?.isStartPage == true)
        #expect(adapter.contextCount == 0)
        #expect(createdStores.value.isEmpty)
        adapter.execute(.ensureContext(tabID: store.state.selectedTabID))
        adapter.execute(.load(
            tabID: store.state.selectedTabID,
            url: destination,
            operationID: BrowserNavigationOperationID(),
        ))
        #expect(adapter.ensureActiveContext(for: store.state.selectedTabID) == nil)
        #expect(adapter.contextCount == 0)
        #expect(createdStores.value.isEmpty)

        await gate.release()
        await store.receive(.loaded(
            settings: ephemeralSettings,
            bookmarks: [],
            history: [],
            profileConfigurationID: configurationID,
        ))
        await store.finish()

        let selectedTabID = store.state.selectedTabID
        let webView = try #require(adapter.webView(for: selectedTabID))
        #expect(webView.configuration.websiteDataStore === createdStores.value.last)
        #expect(webView.configuration.websiteDataStore !== WKWebsiteDataStore.default())
        #expect(store.state.tabs.count == 1)
        #expect(store.state.tabs[0].content == .web(requestedURL: destination))

        adapter.destroyContext(for: selectedTabID)
    }

    @Test("Confirmed switching cancels cleanly, resets the session, and gates immediate navigation")
    func confirmedTransitionGatesNavigationAndPreservesLibrary() async throws {
        let gate = BrowserProfileConfigurationGate()
        let createdStores = LockIsolated<[WKWebsiteDataStore]>([])
        let adapter = BrowserWebKitAdapter(makeWebView: { frame, configuration in
            createdStores.withValue { $0.append(configuration.websiteDataStore) }
            return WKWebView(frame: frame, configuration: configuration)
        })
        adapter.execute(.configureProfile(profile: .ephemeral, retiringTabIDs: []))

        let oldTabID = BrowserTabID(UUID(100))
        _ = adapter.ensureContext(for: oldTabID)
        let adapterOnlyTabID = BrowserTabID(UUID(4))
        _ = adapter.ensureContext(for: adapterOnlyTabID)
        let oldURL = try #require(URL(string: "https://old.example"))
        let destination = try #require(URL(string: "https://new.example"))
        let bookmark = try BrowserBookmark(
            id: UUID(2),
            title: "Saved bookmark",
            url: #require(URL(string: "https://bookmark.example")),
            siblingOrder: 0,
        )
        let historyEntry = try BrowserHistoryEntry(
            id: UUID(3),
            title: "Loaded history",
            url: #require(URL(string: "https://history.example")),
            visitedAt: Date(timeIntervalSince1970: 100),
        )
        let savedSettings = LockIsolated<[BrowserSettings]>([])
        var initialState = BrowserFeature.State(
            tabs: [.web(id: oldTabID, url: oldURL)],
            selectedTabID: oldTabID,
            presentation: .tabOverview,
            focusedField: .chrome,
            omniboxDraft: "unfinished draft",
        )
        initialState.settings = BrowserSettings(
            searchProvider: .google,
            providerSuggestionsEnabled: true,
            copiedLinkSuggestionsEnabled: false,
            openLinksInNewTabs: .foreground,
            browsingProfile: .ephemeral,
        )
        initialState.profileLifecycle = .ready
        initialState.bookmarks = [bookmark]
        initialState.history = [historyEntry]
        initialState.tabOverviewFocusID = oldTabID
        initialState.tabOverviewScrollPosition = oldTabID
        initialState.copiedLink = oldURL
        initialState.library = .init(section: .history)
        initialState.bookmarkEditor = .init(title: "Unsaved", urlDraft: oldURL.absoluteString)
        initialState.findDraft = "temporary find"
        initialState.javaScriptDialogTabID = oldTabID
        initialState.shareURL = oldURL
        initialState.shareTitle = "Old page"
        initialState.destructiveConfirmation = .clearHistory

        let fixture = BrowserProfileWebKitFixture(adapter: adapter, gate: gate)
        let store = TestStore(initialState: initialState) {
            BrowserFeature()
        } withDependencies: {
            $0.uuid = .incrementing
            $0.browserSettings.save = { settings in savedSettings.withValue { $0.append(settings) } }
            $0.browserWebKit = BrowserWebKitClient(
                execute: { command in await fixture.execute(command) },
                events: { AsyncStream { $0.finish() } },
            )
        }
        store.exhaustivity = .off(showSkippedAssertions: false)

        let oldWebsiteDataStore = try #require(adapter.webView(for: oldTabID)).configuration.websiteDataStore
        #expect(adapter.contextCount == 2)
        await store.send(.profileChangeRequested(.ephemeral))
        #expect(store.state.pendingProfileChange == nil)
        await store.send(.profileChangeRequested(.persistentPrivate))
        #expect(store.state.settings.browsingProfile == .ephemeral)
        #expect(savedSettings.value.isEmpty)
        await store.send(.profileChangeCancelled)
        #expect(store.state.pendingProfileChange == nil)
        #expect(store.state.settings.browsingProfile == .ephemeral)
        #expect(savedSettings.value.isEmpty)

        await store.send(.profileChangeRequested(.persistentPrivate))
        await store.send(.profileChangeConfirmed)
        let configurationID = try #require(store.state.profileConfigurationRequestID)
        #expect(store.state.settings.browsingProfile == .persistentPrivate)
        #expect(store.state.tabs.count == 1)
        #expect(store.state.selectedTab?.isStartPage == true)
        #expect(store.state.selectedTabID != oldTabID)
        #expect(store.state.bookmarks == [bookmark])
        #expect(store.state.history == [historyEntry])
        #expect(store.state.tabOverviewFocusID == nil)
        #expect(store.state.tabOverviewScrollPosition == nil)
        #expect(store.state.focusedField == .none)
        #expect(store.state.omniboxDraft.isEmpty)
        #expect(store.state.copiedLink == nil)
        #expect(store.state.library == nil)
        #expect(store.state.bookmarkEditor == nil)
        #expect(store.state.findDraft == nil)
        #expect(store.state.backForwardList == nil)
        #expect(store.state.javaScriptDialogTabID == nil)
        #expect(store.state.shareURL == nil)
        #expect(store.state.shareTitle == nil)
        #expect(store.state.destructiveConfirmation == nil)
        #expect(adapter.hasContext(for: oldTabID))
        #expect(adapter.hasContext(for: adapterOnlyTabID))
        #expect(savedSettings.value.isEmpty)

        #expect(await gate.waitUntilStarted() == .persistentPrivate)
        await store.send(.navigate(destination))
        #expect(store.state.pendingWebAction == .navigate(tabID: store.state.selectedTabID, url: destination))
        #expect(store.state.selectedTab?.isStartPage == true)
        #expect(adapter.hasContext(for: oldTabID))
        #expect(adapter.hasContext(for: adapterOnlyTabID))
        #expect(createdStores.value.count == 2)

        await gate.release()
        await store.receive(.profileConfigurationCompleted(
            profile: .persistentPrivate,
            requestID: configurationID,
        ))
        await store.finish()

        #expect(!adapter.hasContext(for: oldTabID))
        #expect(!adapter.hasContext(for: adapterOnlyTabID))
        #expect(adapter.contextCount == 1)
        #expect(oldWebsiteDataStore !== WKWebsiteDataStore.default())
        let newWebView = try #require(adapter.webView(for: store.state.selectedTabID))
        #expect(newWebView.configuration.websiteDataStore === WKWebsiteDataStore.default())
        #expect(createdStores.value.count == 3)
        #expect(savedSettings.value == [store.state.settings])
        #expect(store.state.bookmarks == [bookmark])
        #expect(store.state.history == [historyEntry])

        adapter.destroyContext(for: store.state.selectedTabID)
    }

    @Test("Ephemeral reset waits for confirmation and cancellation leaves settings intact")
    func resetIsAtomicWhileEphemeral() async throws {
        let gate = BrowserProfileConfigurationGate()
        let adapter = BrowserWebKitAdapter()
        adapter.execute(.configureProfile(profile: .ephemeral, retiringTabIDs: []))
        let oldTabID = BrowserTabID(UUID(11))
        _ = adapter.ensureContext(for: oldTabID)

        let resetCount = LockIsolated(0)
        var initialState = try BrowserFeature.State(
            tabs: [.web(
                id: oldTabID,
                url: #require(URL(string: "https://ephemeral.example")),
            )],
            selectedTabID: oldTabID,
        )
        initialState.settings = BrowserSettings(
            searchProvider: .google,
            providerSuggestionsEnabled: true,
            copiedLinkSuggestionsEnabled: false,
            openLinksInNewTabs: .foreground,
            browsingProfile: .ephemeral,
        )
        initialState.profileLifecycle = .ready
        let bookmark = try BrowserBookmark(
            id: UUID(12),
            title: "Saved bookmark",
            url: #require(URL(string: "https://bookmark.example")),
            siblingOrder: 0,
        )
        let historyEntry = try BrowserHistoryEntry(
            id: UUID(13),
            title: "Loaded history",
            url: #require(URL(string: "https://history.example")),
            visitedAt: Date(timeIntervalSince1970: 100),
        )
        initialState.bookmarks = [bookmark]
        initialState.history = [historyEntry]
        let originalSettings = initialState.settings
        let fixture = BrowserProfileWebKitFixture(adapter: adapter, gate: gate)
        let store = TestStore(initialState: initialState) {
            BrowserFeature()
        } withDependencies: {
            $0.uuid = .incrementing
            $0.browserSettings.reset = { resetCount.withValue { $0 += 1 } }
            $0.browserWebKit = BrowserWebKitClient(
                execute: { command in await fixture.execute(command) },
                events: { AsyncStream { $0.finish() } },
            )
        }
        store.exhaustivity = .off

        await store.send(.resetSettings)
        #expect(store.state.settings == originalSettings)
        #expect(store.state.pendingProfileChange == .resetSettings)
        #expect(resetCount.value == 0)
        await store.send(.profileChangeCancelled)
        #expect(store.state.settings == originalSettings)
        #expect(store.state.pendingProfileChange == nil)
        #expect(resetCount.value == 0)

        await store.send(.resetSettings)
        await store.send(.profileChangeConfirmed)
        let configurationID = try #require(store.state.profileConfigurationRequestID)
        #expect(store.state.settings == BrowserSettings())
        #expect(store.state.tabs.count == 1)
        #expect(store.state.selectedTab?.isStartPage == true)
        #expect(resetCount.value == 0)
        #expect(adapter.hasContext(for: oldTabID))

        #expect(await gate.waitUntilStarted() == .persistentPrivate)
        await gate.release()
        await store.receive(.profileConfigurationCompleted(
            profile: .persistentPrivate,
            requestID: configurationID,
        ))
        await store.finish()

        #expect(!adapter.hasContext(for: oldTabID))
        #expect(adapter.contextCount == 0)
        #expect(resetCount.value == 1)
        #expect(store.state.bookmarks == [bookmark])
        #expect(store.state.history == [historyEntry])
    }

    @Test("Settings initializes the stored profile before accepting preference mutations")
    func preferenceMutationWaitsForStoredProfile() async throws {
        let gate = BrowserProfileConfigurationGate()
        let adapter = BrowserWebKitAdapter(requiresProfileConfiguration: true)
        let fixture = BrowserProfileWebKitFixture(adapter: adapter, gate: gate)
        let persistedSettings = BrowserSettings(browsingProfile: .ephemeral)
        let savedSettings = LockIsolated<[BrowserSettings]>([])
        let store = TestStore(initialState: BrowserFeature.State()) {
            BrowserFeature()
        } withDependencies: {
            $0.uuid = .incrementing
            $0.browserSettings.load = { persistedSettings }
            $0.browserSettings.save = { settings in savedSettings.withValue { $0.append(settings) } }
            $0.browserLibrary.loadBookmarks = { [] }
            $0.browserLibrary.loadHistory = { [] }
            $0.browserWebKit = BrowserWebKitClient(
                execute: { command in await fixture.execute(command) },
                events: { AsyncStream { $0.finish() } },
            )
        }
        store.exhaustivity = .off

        await store.send(.settingsPresented)
        #expect(await gate.waitUntilStarted() == .ephemeral)
        #expect(!store.state.canCreateWebKitContext)

        await store.send(.task)
        #expect(await gate.requestedProfiles() == [.ephemeral])

        await store.send(.searchProviderChanged(.google))

        #expect(store.state.settings.searchProvider == .duckDuckGo)
        #expect(savedSettings.value.isEmpty)
        let configurationID = try #require(store.state.profileConfigurationRequestID)
        await gate.release()
        await store.receive(.loaded(
            settings: persistedSettings,
            bookmarks: [],
            history: [],
            profileConfigurationID: configurationID,
        ))
        await store.finish()

        #expect(store.state.canCreateWebKitContext)
        #expect(store.state.settings.browsingProfile == .ephemeral)
        await store.send(.searchProviderChanged(.google))
        await store.finish()
        #expect(savedSettings.value.count == 1)
        #expect(savedSettings.value.allSatisfy { $0.browsingProfile == .ephemeral })
    }

    @Test("Mounted Browser Settings loads preferences before becoming usable")
    func mountedSettingsInitializesStoredProfile() async {
        let gate = BrowserProfileConfigurationGate()
        let adapter = BrowserWebKitAdapter(requiresProfileConfiguration: true)
        let fixture = BrowserProfileWebKitFixture(adapter: adapter, gate: gate)
        let persistedSettings = BrowserSettings(browsingProfile: .ephemeral)
        let store = Store(initialState: BrowserFeature.State()) {
            BrowserFeature()
        } withDependencies: {
            $0.uuid = .incrementing
            $0.browserSettings.load = { persistedSettings }
            $0.browserLibrary.loadBookmarks = { [] }
            $0.browserLibrary.loadHistory = { [] }
            $0.browserWebKit = BrowserWebKitClient(
                execute: { command in await fixture.execute(command) },
                events: { AsyncStream { $0.finish() } },
            )
        }
        let readiness = BrowserSettingsReadinessObserver()
        let controller = UIHostingController(
            rootView: BrowserSettingsReadinessProbe(store: store, readiness: readiness),
        )
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = controller
        window.makeKeyAndVisible()
        controller.view.frame = window.bounds
        controller.view.layoutIfNeeded()
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }

        #expect(await gate.waitUntilStarted() == .ephemeral)
        #expect(store.withState { !$0.canCreateWebKitContext })

        await gate.release()
        await readiness.waitUntilReady()

        #expect(store.withState { $0.canCreateWebKitContext })
        #expect(store.withState { $0.settings.browsingProfile == .ephemeral })
    }

    @Test("A repeated Browser task cannot supersede a blocked profile transition")
    func repeatedTaskCannotSupersedeProfileTransition() async throws {
        let gate = BrowserProfileConfigurationGate()
        let adapter = BrowserWebKitAdapter()
        adapter.execute(.configureProfile(profile: .ephemeral, retiringTabIDs: []))
        let fixture = BrowserProfileWebKitFixture(
            adapter: adapter,
            gate: gate,
        )
        let ephemeralSettings = BrowserSettings(browsingProfile: .ephemeral)
        let savedSettings = LockIsolated<[BrowserSettings]>([])
        var initialState = BrowserFeature.State()
        initialState.settings = ephemeralSettings
        initialState.profileLifecycle = .ready
        let store = TestStore(initialState: initialState) {
            BrowserFeature()
        } withDependencies: {
            $0.uuid = .incrementing
            $0.browserSettings.load = { ephemeralSettings }
            $0.browserSettings.save = { settings in savedSettings.withValue { $0.append(settings) } }
            $0.browserWebKit = BrowserWebKitClient(
                execute: { command in await fixture.execute(command) },
                events: { AsyncStream { $0.finish() } },
            )
        }
        store.exhaustivity = .off(showSkippedAssertions: false)
        await store.send(.profileChangeRequested(.persistentPrivate))
        await store.send(.profileChangeConfirmed)
        let transitionID = try #require(store.state.profileConfigurationRequestID)
        #expect(await gate.waitUntilStarted() == .persistentPrivate)

        await store.send(.task)
        #expect(store.state.profileConfigurationRequestID == transitionID)

        await gate.release()
        await store.receive(.profileConfigurationCompleted(
            profile: .persistentPrivate,
            requestID: transitionID,
        ))
        await store.finish()

        #expect(store.state.settings.browsingProfile == .persistentPrivate)
        #expect(await gate.requestedProfiles() == [.persistentPrivate])
        #expect(savedSettings.value == [store.state.settings])

        let replacementContext = adapter.ensureContext(for: store.state.selectedTabID)
        #expect(replacementContext.configuration.websiteDataStore === WKWebsiteDataStore.default())
        adapter.destroyContext(for: store.state.selectedTabID)
    }

    @Test("Navigation before the first Browser task waits for profile configuration")
    func navigationBeforeInitialTaskIsDeferred() async throws {
        let gate = BrowserProfileConfigurationGate()
        let executedCommands = LockIsolated<[BrowserWebKitCommand]>([])
        let persistedSettings = BrowserSettings(browsingProfile: .ephemeral)
        let destination = try #require(URL(string: "https://before-task.example"))
        let store = TestStore(initialState: BrowserFeature.State()) {
            BrowserFeature()
        } withDependencies: {
            $0.uuid = .incrementing
            $0.browserSettings.load = { persistedSettings }
            $0.browserLibrary.loadBookmarks = { [] }
            $0.browserLibrary.loadHistory = { [] }
            $0.browserWebKit = BrowserWebKitClient(
                execute: { command in
                    executedCommands.withValue { $0.append(command) }
                    if case let .configureProfile(profile, _) = command {
                        await gate.pause(profile)
                    }
                },
                events: { AsyncStream { $0.finish() } },
            )
        }
        store.exhaustivity = .off
        let targetTabID = store.state.selectedTabID

        await store.send(.navigate(destination))
        await store.finish()

        #expect(store.state.pendingWebAction == .navigate(tabID: targetTabID, url: destination))
        #expect(store.state.tabs.first?.isStartPage == true)
        #expect(executedCommands.value.isEmpty)

        await store.send(.task)
        let configurationID = try #require(store.state.profileConfigurationRequestID)
        #expect(await gate.waitUntilStarted() == .ephemeral)
        #expect(executedCommands.value == [
            .configureProfile(profile: .ephemeral, retiringTabIDs: []),
        ])

        await gate.release()
        await store.receive(.loaded(
            settings: persistedSettings,
            bookmarks: [],
            history: [],
            profileConfigurationID: configurationID,
        ))
        await store.finish()

        #expect(executedCommands.value.first == .configureProfile(profile: .ephemeral, retiringTabIDs: []))
        #expect(executedCommands.value.contains(.ensureContext(tabID: targetTabID)))
        let loads = executedCommands.value.compactMap { command -> (BrowserTabID, URL)? in
            guard case let .load(tabID: tabID, url: url, operationID: _) = command else {
                return nil
            }

            return (tabID, url)
        }
        #expect(loads.count == 1)
        #expect(loads.first?.0 == targetTabID)
        #expect(loads.first?.1 == destination)
    }

    @Test("Deferred navigation resumes on its original tab after selection changes")
    func deferredNavigationKeepsOriginalTab() async throws {
        let gate = BrowserProfileConfigurationGate()
        let executedCommands = LockIsolated<[BrowserWebKitCommand]>([])
        let persistedSettings = BrowserSettings(browsingProfile: .ephemeral)
        let destination = try #require(URL(string: "https://tab-a.example"))
        let initialState = BrowserFeature.State(initialTabID: BrowserTabID(UUID(20)))
        let originalTabID = initialState.selectedTabID
        let store = TestStore(initialState: initialState) {
            BrowserFeature()
        } withDependencies: {
            $0.uuid = .incrementing
            $0.browserSettings.load = { persistedSettings }
            $0.browserLibrary.loadBookmarks = { [] }
            $0.browserLibrary.loadHistory = { [] }
            $0.browserWebKit = BrowserWebKitClient(
                execute: { command in
                    executedCommands.withValue { $0.append(command) }
                    if case let .configureProfile(profile, _) = command {
                        await gate.pause(profile)
                    }
                },
                events: { AsyncStream { $0.finish() } },
            )
        }
        store.exhaustivity = .off

        await store.send(.task)
        let configurationID = try #require(store.state.profileConfigurationRequestID)
        #expect(await gate.waitUntilStarted() == .ephemeral)
        await store.send(.navigate(destination))
        #expect(store.state.pendingWebAction == .navigate(tabID: originalTabID, url: destination))
        await store.send(.newTabTapped)
        let selectedTabID = store.state.selectedTabID
        #expect(selectedTabID != originalTabID)
        #expect(store.state.tabs.last?.isStartPage == true)
        let backgroundDraft = "draft for tab B"
        await store.send(.omniboxChanged(backgroundDraft))
        #expect(store.state.focusedField == .startPage)

        await gate.release()
        await store.receive(.loaded(
            settings: persistedSettings,
            bookmarks: [],
            history: [],
            profileConfigurationID: configurationID,
        ))
        await store.finish()

        #expect(store.state.selectedTabID == selectedTabID)
        #expect(store.state.tabs.first(where: { $0.id == originalTabID })?.content == .web(requestedURL: destination))
        #expect(store.state.tabs.first(where: { $0.id == selectedTabID })?.isStartPage == true)
        #expect(store.state.omniboxDraft == backgroundDraft)
        #expect(store.state.focusedField == .startPage)
        let loads = executedCommands.value.compactMap { command -> (BrowserTabID, URL)? in
            guard case let .load(tabID: tabID, url: url, operationID: _) = command else {
                return nil
            }

            return (tabID, url)
        }
        #expect(loads.count == 1)
        #expect(loads.first?.0 == originalTabID)
        #expect(loads.first?.1 == destination)
    }
}

private actor BrowserProfileConfigurationGate {
    private var startedProfile: BrowserBrowsingProfile?
    private var startContinuation: CheckedContinuation<BrowserBrowsingProfile, Never>?
    private var releaseContinuation: CheckedContinuation<Void, Never>?
    private var releasedBeforeSuspension = false
    private var shouldPauseNextConfiguration = true
    private var requestedProfileConfigurations: [BrowserBrowsingProfile] = []

    func pause(_ profile: BrowserBrowsingProfile) async {
        requestedProfileConfigurations.append(profile)
        guard shouldPauseNextConfiguration else {
            return
        }

        shouldPauseNextConfiguration = false

        if let startContinuation {
            self.startContinuation = nil
            startContinuation.resume(returning: profile)
        } else {
            startedProfile = profile
        }

        await withCheckedContinuation { continuation in
            if releasedBeforeSuspension {
                releasedBeforeSuspension = false
                continuation.resume()
            } else {
                releaseContinuation = continuation
            }
        }
    }

    func requestedProfiles() -> [BrowserBrowsingProfile] {
        requestedProfileConfigurations
    }

    func waitUntilStarted() async -> BrowserBrowsingProfile {
        if let startedProfile {
            self.startedProfile = nil
            return startedProfile
        }

        return await withCheckedContinuation { continuation in
            startContinuation = continuation
        }
    }

    func release() {
        if let releaseContinuation {
            self.releaseContinuation = nil
            releaseContinuation.resume()
        } else {
            releasedBeforeSuspension = true
        }
    }
}

@MainActor
private final class BrowserSettingsReadinessObserver {
    private var isReady = false
    private var continuation: CheckedContinuation<Void, Never>?

    func waitUntilReady() async {
        guard !isReady else {
            return
        }

        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func markReady() {
        isReady = true
        continuation?.resume()
        continuation = nil
    }
}

@MainActor
private struct BrowserSettingsReadinessProbe: View {
    let store: StoreOf<BrowserFeature>
    let readiness: BrowserSettingsReadinessObserver

    var body: some View {
        NavigationStack {
            BrowserSettingsView(store: store)
        }
        .onChange(of: store.canCreateWebKitContext) { _, isReady in
            if isReady {
                readiness.markReady()
            }
        }
    }
}

@MainActor
private final class BrowserProfileWebKitFixture {
    private let adapter: BrowserWebKitAdapter
    private let gate: BrowserProfileConfigurationGate

    init(adapter: BrowserWebKitAdapter, gate: BrowserProfileConfigurationGate) {
        self.adapter = adapter
        self.gate = gate
    }

    func execute(_ command: BrowserWebKitCommand) async {
        if case let .configureProfile(profile, _) = command {
            await gate.pause(profile)
            adapter.execute(command)
        } else if case .load = command {
            // Keep the test at the context-creation boundary without issuing a network request.
        } else {
            adapter.execute(command)
        }
    }
}
