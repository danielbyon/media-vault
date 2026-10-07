//
//  BrowserOpenTabsReducerTests.swift
//  MediaVault
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import ComposableArchitecture
import ConcurrencyExtras
import Dependencies
import Foundation
import Testing
@testable import BrowserFeature

@Suite("Browser open-tabs reducer lifecycle")
@MainActor
struct BrowserOpenTabsReducerTests {
    private enum RecordedSessionOperation: Equatable {
        case save(UInt64, BrowserOpenTabsSession)
        case purge(UInt64)
        case advance(UInt64)
    }

    @Test("Profile readiness alone never reads the logical tab session")
    func profileReadinessDoesNotRestoreTabs() async throws {
        let settings = BrowserSettings()
        let loadCount = LockIsolated(0)
        let store = TestStore(initialState: BrowserFeature.State()) {
            BrowserFeature()
        } withDependencies: {
            $0.uuid = .incrementing
            $0.browserSettings.load = { settings }
            $0.browserLibrary.loadBookmarks = { [] }
            $0.browserLibrary.loadHistory = { [] }
            $0.browserWebKit = BrowserWebKitClient(
                execute: { _ in },
                events: { AsyncStream { $0.finish() } },
            )
            $0.browserOpenTabsSession.load = {
                loadCount.withValue { $0 += 1 }
                return .missing
            }
        }
        store.exhaustivity = .off

        await store.send(.profileInitializationRequested)
        let profileRequestID = try #require(store.state.profileConfigurationRequestID)
        await store.receive(.loaded(
            settings: settings,
            bookmarks: [],
            history: [],
            profileConfigurationID: profileRequestID,
        ))
        await store.finish()

        #expect(store.state.profileLifecycle == .ready)
        #expect(store.state.openTabsEntryLifecycle == .notEntered)
        #expect(store.state.tabs.count == 1)
        #expect(loadCount.value == 0)
    }

    @Test("Browser restoration request identity uses the injected UUID dependency")
    func restorationRequestUsesInjectedUUID() async {
        let requestID = UUID(9_494)
        let sessionLoad = AsyncStream<BrowserOpenTabsSessionLoadOutcome>.makeStream()
        var initialState = BrowserFeature.State()
        initialState.profileLifecycle = .ready
        let store = TestStore(initialState: initialState) {
            BrowserFeature()
        } withDependencies: {
            $0.uuid = .constant(requestID)
            $0.browserOpenTabsSession.load = {
                for await outcome in sessionLoad.stream {
                    return outcome
                }
                return .failed
            }
        }
        store.exhaustivity = .off(showSkippedAssertions: false)

        await store.send(.browserEntered)
        #expect(store.state.openTabsEntryLifecycle == .restoring(requestID: requestID, revision: 0))
        sessionLoad.continuation.yield(.missing)
        await store.receive(.openTabsSessionLoaded(requestID: requestID, revision: 0, data: nil))
        await store.finish()
        #expect(store.state.openTabsEntryLifecycle == .completed)
    }

    @Test("A confirmed missing session seeds the current logical Browser workspace")
    func missingSessionSeedsCurrentWorkspace() async throws {
        let selectedURL = try #require(URL(string: "https://current.example/selected"))
        let firstID = BrowserTabID()
        let selectedID = BrowserTabID()
        let initialTabs = [
            BrowserTab.startPage(id: firstID),
            BrowserTab.web(id: selectedID, url: selectedURL),
        ]
        let savedSessions = LockIsolated<[BrowserOpenTabsSession]>([])
        let store = TestStore(initialState: BrowserFeature.State.readyForTesting(
            tabs: initialTabs,
            selectedTabID: selectedID,
        )) {
            BrowserFeature()
        } withDependencies: {
            $0.uuid = .incrementing
            $0.browserOpenTabsSession.load = { .missing }
            $0.browserOpenTabsSession.save = { session, _ in
                savedSessions.withValue { $0.append(session) }
            }
        }
        store.exhaustivity = .off

        await store.send(.browserEntered)
        let (requestID, revision) = try #require(restorationRequest(in: store.state))
        await store.receive(.openTabsSessionLoaded(requestID: requestID, revision: revision, data: nil))
        await store.finish()

        #expect(store.state.tabs == initialTabs)
        #expect(store.state.selectedTabID == selectedID)
        #expect(savedSessions.value == [BrowserOpenTabsSession.project(from: initialTabs, selectedTabID: selectedID)])
    }

    @Test("A failed session read completes entry without overwriting until a logical mutation")
    func failedSessionReadDoesNotBlockEntryOrOverwrite() async throws {
        let currentURL = try #require(URL(string: "https://current.example"))
        let selectedID = BrowserTabID()
        let initialTabs = [BrowserTab.web(id: selectedID, url: currentURL)]
        let savedSessions = LockIsolated<[BrowserOpenTabsSession]>([])
        let commands = LockIsolated<[BrowserWebKitCommand]>([])
        let store = TestStore(initialState: BrowserFeature.State.readyForTesting(
            tabs: initialTabs,
            selectedTabID: selectedID,
        )) {
            BrowserFeature()
        } withDependencies: {
            $0.uuid = .incrementing
            $0.browserOpenTabsSession.load = { .failed }
            $0.browserOpenTabsSession.save = { session, _ in
                savedSessions.withValue { $0.append(session) }
            }
            $0.browserClipboard.readHTTPURL = { nil }
            $0.browserWebKit = BrowserWebKitClient(
                execute: { command in commands.withValue { $0.append(command) } },
                events: { AsyncStream { $0.finish() } },
            )
        }
        store.exhaustivity = .off

        await store.send(.browserEntered)
        let (requestID, revision) = try #require(restorationRequest(in: store.state))
        await store.receive(.openTabsSessionLoadFailed(requestID: requestID, revision: revision))
        await store.finish()

        #expect(store.state.openTabsEntryLifecycle == .completed)
        #expect(store.state.tabs == initialTabs)
        #expect(savedSessions.value.isEmpty)
        #expect(commands.value.isEmpty)

        await store.send(.newTabTapped)
        await store.finish()

        #expect(store.state.tabs.count == 2)
        #expect(savedSessions.value.count == 1)
        #expect(savedSessions.value.first?.entries == [
            .init(position: 0, kind: .web(currentURL)),
            .init(position: 1, kind: .startPage),
        ])
    }

    @Test("An omnibox edit supersedes a pending restoration response")
    func omniboxEditWinsOverDelayedRestoration() async throws {
        let restoredURL = try #require(URL(string: "https://saved.example"))
        let data = try BrowserOpenTabsSession(
            selectedPosition: 0,
            entries: [.init(position: 0, kind: .web(restoredURL))],
        ).encoded()
        let load = AsyncStream<BrowserOpenTabsSessionLoadOutcome>.makeStream()
        let commands = LockIsolated<[BrowserWebKitCommand]>([])
        let savedSessions = LockIsolated<[BrowserOpenTabsSession]>([])
        var initialState = BrowserFeature.State.readyForTesting()
        initialState.settings.copiedLinkSuggestionsEnabled = false
        let initialTabs = initialState.tabs
        let initialSelectedTabID = initialState.selectedTabID
        let store = TestStore(initialState: initialState) {
            BrowserFeature()
        } withDependencies: {
            $0.uuid = .incrementing
            $0.browserOpenTabsSession.load = {
                for await outcome in load.stream {
                    return outcome
                }
                return .failed
            }
            $0.browserOpenTabsSession.save = { session, _ in
                savedSessions.withValue { $0.append(session) }
            }
            $0.browserClipboard.readHTTPURL = { nil }
            $0.browserWebKit = BrowserWebKitClient(
                execute: { command in commands.withValue { $0.append(command) } },
                events: { AsyncStream { $0.finish() } },
            )
        }
        store.exhaustivity = .off

        await store.send(.browserEntered)
        let (requestID, revision) = try #require(restorationRequest(in: store.state))
        await store.send(.omniboxFocused)
        #expect(store.state.focusedField == .startPage)
        await store.send(.omniboxChanged("unsubmitted draft"))

        #expect(store.state.omniboxDraft == "unsubmitted draft")
        #expect(store.state.hasUnsubmittedOmniboxDraft)
        #expect(store.state.openTabsEntryLifecycle == .completed)

        load.continuation.yield(.loaded(data))
        load.continuation.finish()
        await store.receive(.openTabsSessionLoaded(requestID: requestID, revision: revision, data: data))
        await store.finish()

        #expect(store.state.tabs == initialTabs)
        #expect(store.state.selectedTabID == initialSelectedTabID)
        #expect(store.state.omniboxDraft == "unsubmitted draft")
        #expect(store.state.focusedField == .startPage)
        #expect(store.state.hasUnsubmittedOmniboxDraft)
        #expect(savedSessions.value.isEmpty)
        #expect(commands.value.isEmpty)
    }

    @Test("Closing the sole Start Page supersedes pending restoration and persists its replacement")
    func closingSoleStartPageSupersedesPendingRestoration() async throws {
        let restoredURL = try #require(URL(string: "https://saved.example"))
        let data = try BrowserOpenTabsSession(
            selectedPosition: 0,
            entries: [.init(position: 0, kind: .web(restoredURL))],
        ).encoded()
        let load = AsyncStream<BrowserOpenTabsSessionLoadOutcome>.makeStream()
        let savedSessions = LockIsolated<[BrowserOpenTabsSession]>([])
        let initialState = BrowserFeature.State.readyForTesting()
        let originalTabID = initialState.selectedTabID
        let store = TestStore(initialState: initialState) {
            BrowserFeature()
        } withDependencies: {
            $0.uuid = .incrementing
            $0.browserOpenTabsSession.load = {
                for await outcome in load.stream {
                    return outcome
                }
                return .failed
            }
            $0.browserOpenTabsSession.save = { session, _ in
                savedSessions.withValue { $0.append(session) }
            }
            $0.browserClipboard.readHTTPURL = { nil }
        }
        store.exhaustivity = .off

        await store.send(.browserEntered)
        let (requestID, revision) = try #require(restorationRequest(in: store.state))

        await store.send(.closeTab(originalTabID))

        let replacementTabID = store.state.selectedTabID
        let expectedSession = BrowserOpenTabsSession.project(
            from: store.state.tabs,
            selectedTabID: replacementTabID,
        )
        #expect(replacementTabID != originalTabID)
        #expect(expectedSession.entries == [.init(position: 0, kind: .startPage)])
        #expect(store.state.openTabsEntryLifecycle == .completed)
        #expect(savedSessions.value == [expectedSession])

        load.continuation.yield(.loaded(data))
        load.continuation.finish()
        await store.receive(.openTabsSessionLoaded(requestID: requestID, revision: revision, data: data))
        await store.finish()

        #expect(store.state.tabs == [.startPage(id: replacementTabID)])
        #expect(store.state.selectedTabID == replacementTabID)
        #expect(savedSessions.value == [expectedSession])
    }

    @Test("Close All supersedes pending restoration when the projection is already one Start Page")
    func closeAllStartPageSupersedesPendingRestoration() async throws {
        let restoredURL = try #require(URL(string: "https://saved.example"))
        let data = try BrowserOpenTabsSession(
            selectedPosition: 0,
            entries: [.init(position: 0, kind: .web(restoredURL))],
        ).encoded()
        let load = AsyncStream<BrowserOpenTabsSessionLoadOutcome>.makeStream()
        let savedSessions = LockIsolated<[BrowserOpenTabsSession]>([])
        let initialState = BrowserFeature.State.readyForTesting()
        let originalTabID = initialState.selectedTabID
        let store = TestStore(initialState: initialState) {
            BrowserFeature()
        } withDependencies: {
            $0.uuid = .incrementing
            $0.browserOpenTabsSession.load = {
                for await outcome in load.stream {
                    return outcome
                }
                return .failed
            }
            $0.browserOpenTabsSession.save = { session, _ in
                savedSessions.withValue { $0.append(session) }
            }
            $0.browserClipboard.readHTTPURL = { nil }
        }
        store.exhaustivity = .off

        await store.send(.browserEntered)
        let (requestID, revision) = try #require(restorationRequest(in: store.state))

        await store.send(.closeAllConfirmed)

        let replacementTabID = store.state.selectedTabID
        let expectedSession = BrowserOpenTabsSession.project(
            from: store.state.tabs,
            selectedTabID: replacementTabID,
        )
        #expect(replacementTabID != originalTabID)
        #expect(expectedSession.entries == [.init(position: 0, kind: .startPage)])
        #expect(store.state.openTabsEntryLifecycle == .completed)
        #expect(savedSessions.value == [expectedSession])

        load.continuation.yield(.loaded(data))
        load.continuation.finish()
        await store.receive(.openTabsSessionLoaded(requestID: requestID, revision: revision, data: data))
        await store.finish()

        #expect(store.state.tabs == [.startPage(id: replacementTabID)])
        #expect(store.state.selectedTabID == replacementTabID)
        #expect(savedSessions.value == [expectedSession])
    }

    @Test("A close that changes the session projection saves once while restoration is pending")
    func closeWithChangedProjectionSavesOnceDuringRestoration() async throws {
        let savedURL = try #require(URL(string: "https://saved.example"))
        let data = try BrowserOpenTabsSession(
            selectedPosition: 1,
            entries: [
                .init(position: 0, kind: .startPage),
                .init(position: 1, kind: .web(savedURL)),
            ],
        ).encoded()
        let load = AsyncStream<BrowserOpenTabsSessionLoadOutcome>.makeStream()
        let operations = LockIsolated<[RecordedSessionOperation]>([])
        let startPageID = BrowserTabID()
        let webTabID = BrowserTabID()
        let initialState = BrowserFeature.State.readyForTesting(
            tabs: [.startPage(id: startPageID), .web(id: webTabID, url: savedURL)],
            selectedTabID: webTabID,
        )
        let store = TestStore(initialState: initialState) {
            BrowserFeature()
        } withDependencies: {
            $0.uuid = .incrementing
            $0.browserOpenTabsSession.load = {
                for await outcome in load.stream {
                    return outcome
                }
                return .failed
            }
            $0.browserOpenTabsSession.save = { session, revision in
                operations.withValue { $0.append(.save(revision, session)) }
            }
            $0.browserClipboard.readHTTPURL = { nil }
        }
        store.exhaustivity = .off

        await store.send(.browserEntered)
        let (requestID, revision) = try #require(restorationRequest(in: store.state))
        await store.send(.closeTab(webTabID))

        let expectedSession = BrowserOpenTabsSession.project(
            from: store.state.tabs,
            selectedTabID: store.state.selectedTabID,
        )
        #expect(store.state.tabs == [.startPage(id: startPageID)])
        #expect(store.state.openTabsEntryLifecycle == .completed)
        #expect(operations.value.count == 1)
        if let operation = operations.value.first,
           case let .save(_, savedSession) = operation {
            #expect(savedSession == expectedSession)
        } else {
            Issue.record("The close should produce one session save.")
        }

        load.continuation.yield(.loaded(data))
        load.continuation.finish()
        await store.receive(.openTabsSessionLoaded(requestID: requestID, revision: revision, data: data))
        await store.finish()

        #expect(store.state.tabs == [.startPage(id: startPageID)])
        #expect(operations.value.count == 1)
    }

    @Test("Browser entry before profile readiness defers restoration until settings are ready")
    func entryBeforeReadinessRestoresAfterProfileLoad() async throws {
        let savedURL = try #require(URL(string: "https://restored.example/page"))
        let savedSession = BrowserOpenTabsSession(
            selectedPosition: 1,
            entries: [
                .init(position: 0, kind: .startPage),
                .init(position: 1, kind: .web(savedURL)),
            ],
        )
        let data = try savedSession.encoded()
        let loadCount = LockIsolated(0)
        let commands = LockIsolated<[BrowserWebKitCommand]>([])
        let initialTabID = BrowserTabID()
        let store = TestStore(initialState: BrowserFeature.State(initialTabID: initialTabID)) {
            BrowserFeature()
        } withDependencies: {
            $0.uuid = .incrementing
            $0.browserSettings.load = { .init() }
            $0.browserLibrary.loadBookmarks = { [] }
            $0.browserLibrary.loadHistory = { [] }
            $0.browserWebKit = BrowserWebKitClient(
                execute: { command in commands.withValue { $0.append(command) } },
                events: { AsyncStream { $0.finish() } },
            )
            $0.browserOpenTabsSession.load = {
                loadCount.withValue { $0 += 1 }
                return .loaded(data)
            }
        }
        store.exhaustivity = .off

        await store.send(.browserEntered)
        #expect(store.state.openTabsEntryLifecycle == .waitingForProfile)
        #expect(loadCount.value == 0)

        await store.send(.profileInitializationRequested)
        let profileRequestID = try #require(store.state.profileConfigurationRequestID)
        await store.receive(.loaded(
            settings: .init(),
            bookmarks: [],
            history: [],
            profileConfigurationID: profileRequestID,
        ))
        let (restoreRequestID, revision) = try #require(restorationRequest(in: store.state))
        await store.receive(.openTabsSessionLoaded(
            requestID: restoreRequestID,
            revision: revision,
            data: data,
        ))
        await store.finish()

        #expect(loadCount.value == 1)
        #expect(store.state.openTabsEntryLifecycle == .completed)
        #expect(store.state.tabs.map(\.isStartPage) == [true, false])
        #expect(store.state.selectedTab?.content == .web(requestedURL: savedURL))
        #expect(store.state.selectedTabID != initialTabID)
        #expect(commands.value.contains {
            if case let .load(_, url, _) = $0 {
                url == savedURL
            } else {
                false
            }
        })

        await store.send(.browserEntered)
        await store.finish()
        #expect(loadCount.value == 1)
    }

    @Test("An unusable saved envelope falls back to one fresh Start Page")
    func unusableSavedSessionFallsBackToOneFreshStartPage() async throws {
        let data = Data(
            #"{"version":1,"selectedPosition":0,"entries":[{"position":0,"kind":"future"},{"position":1,"kind":"web","url":"file:///private/page"}]}"#
                .utf8,
        )
        let initialTabID = BrowserTabID()
        let savedSessions = LockIsolated<[BrowserOpenTabsSession]>([])
        let commands = LockIsolated<[BrowserWebKitCommand]>([])
        let store = TestStore(initialState: BrowserFeature.State.readyForTesting(initialTabID: initialTabID)) {
            BrowserFeature()
        } withDependencies: {
            $0.uuid = .incrementing
            $0.browserOpenTabsSession.load = { .loaded(data) }
            $0.browserOpenTabsSession.save = { session, _ in
                savedSessions.withValue { $0.append(session) }
            }
            $0.browserWebKit = BrowserWebKitClient(
                execute: { command in commands.withValue { $0.append(command) } },
                events: { AsyncStream { $0.finish() } },
            )
        }
        store.exhaustivity = .off

        await store.send(.browserEntered)
        let (requestID, revision) = try #require(restorationRequest(in: store.state))
        await store.receive(.openTabsSessionLoaded(requestID: requestID, revision: revision, data: data))
        await store.finish()

        #expect(store.state.tabs.count == 1)
        #expect(store.state.tabs[0].isStartPage)
        #expect(store.state.tabs[0].id != initialTabID)
        #expect(store.state.selectedTabID == store.state.tabs[0].id)
        #expect(savedSessions.value.last?.entries == [.init(position: 0, kind: .startPage)])
        #expect(commands.value.isEmpty)
    }

    @Test("Browser entry preserves an unsupported session until a supported logical mutation")
    func unsupportedSessionVersionIsPreservedUntilLogicalMutation() async throws {
        let futureData = Data(
            "{\"version\":\(BrowserOpenTabsSession.currentVersion + 1),\"futureWorkspace\":true}".utf8,
        )
        let durableData = LockIsolated<Data?>(futureData)
        let savedSessions = LockIsolated<[BrowserOpenTabsSession]>([])
        var initialState = BrowserFeature.State.readyForTesting()
        initialState.settings.copiedLinkSuggestionsEnabled = false
        let initialTabs = initialState.tabs
        let initialSelectedTabID = initialState.selectedTabID
        let store = TestStore(initialState: initialState) {
            BrowserFeature()
        } withDependencies: {
            $0.uuid = .incrementing
            $0.browserOpenTabsSession.load = {
                .loaded(durableData.value ?? futureData)
            }
            $0.browserOpenTabsSession.save = { session, _ in
                savedSessions.withValue { $0.append(session) }
                if let encoded = try? session.encoded() {
                    durableData.withValue { $0 = encoded }
                }
            }
            $0.browserClipboard.readHTTPURL = { nil }
        }
        store.exhaustivity = .off

        await store.send(.browserEntered)
        let (requestID, revision) = try #require(restorationRequest(in: store.state))
        await store.receive(.openTabsSessionLoaded(
            requestID: requestID,
            revision: revision,
            data: futureData,
        ))
        await store.finish()

        #expect(store.state.openTabsEntryLifecycle == .completed)
        #expect(store.state.tabs == initialTabs)
        #expect(store.state.selectedTabID == initialSelectedTabID)
        #expect(savedSessions.value.isEmpty)
        #expect(durableData.value == futureData)

        await store.send(.newTabTapped)
        await store.finish()

        #expect(savedSessions.value.count == 1)
        #expect(savedSessions.value == [BrowserOpenTabsSession.project(
            from: store.state.tabs,
            selectedTabID: store.state.selectedTabID,
        )])
        let savedData = try #require(durableData.value)
        let savedEnvelope = try #require(JSONSerialization.jsonObject(with: savedData) as? [String: Any])
        #expect(savedEnvelope["version"] as? Int == BrowserOpenTabsSession.currentVersion)
    }

    @Test("Restored Start Pages stay native and background web tabs load once when selected")
    func restoredBackgroundTabsLoadOnceOnFirstSelection() async throws {
        let backgroundURL = try #require(URL(string: "https://background.example"))
        let selectedURL = try #require(URL(string: "https://selected.example"))
        let session = BrowserOpenTabsSession(
            selectedPosition: 1,
            entries: [
                .init(position: 0, kind: .web(backgroundURL)),
                .init(position: 1, kind: .startPage),
                .init(position: 2, kind: .web(selectedURL)),
            ],
        )
        let data = try session.encoded()
        let commands = LockIsolated<[BrowserWebKitCommand]>([])
        let saves = LockIsolated<[BrowserOpenTabsSession]>([])
        let store = TestStore(initialState: BrowserFeature.State.readyForTesting()) {
            BrowserFeature()
        } withDependencies: {
            $0.uuid = .incrementing
            $0.browserWebKit = BrowserWebKitClient(
                execute: { command in commands.withValue { $0.append(command) } },
                events: { AsyncStream { $0.finish() } },
            )
            $0.browserOpenTabsSession.load = { .loaded(data) }
            $0.browserOpenTabsSession.save = { session, _ in saves.withValue { $0.append(session) } }
        }
        store.exhaustivity = .off

        await store.send(.browserEntered)
        let (restoreRequestID, revision) = try #require(restorationRequest(in: store.state))
        await store.receive(.openTabsSessionLoaded(
            requestID: restoreRequestID,
            revision: revision,
            data: data,
        ))
        await store.finish()

        #expect(store.state.tabs.count == 3)
        try #require(store.state.tabs.count == 3)

        #expect(store.state.tabs[1].isStartPage)
        #expect(store.state.selectedTabID == store.state.tabs[1].id)
        #expect(commands.value.isEmpty)
        #expect(store.state.lazyRestoredWebTabURLs[store.state.tabs[0].id] == backgroundURL)
        #expect(store.state.lazyRestoredWebTabURLs[store.state.tabs[2].id] == selectedURL)

        let backgroundID = store.state.tabs[0].id
        await store.send(.selectTab(backgroundID))
        await store.finish()
        await store.send(.selectTab(backgroundID))
        await store.finish()

        let loadedURLs = commands.value.compactMap { command -> URL? in
            if case let .load(_, url, _) = command {
                return url
            }
            return nil
        }
        #expect(loadedURLs == [backgroundURL])
        #expect(store.state.lazyRestoredWebTabURLs[backgroundID] == nil)
        #expect(saves.value.last?.selectedPosition == 0)
    }

    @Test("Turning preservation off purges; turning it on snapshots the live pre-entry session")
    func preservationTogglePurgesAndSnapshotsCurrentSession() async throws {
        let url = try #require(URL(string: "https://live.example"))
        let startID = BrowserTabID()
        let webID = BrowserTabID()
        var state = BrowserFeature.State.readyForTesting(
            tabs: [.startPage(id: startID), .web(id: webID, url: url)],
            selectedTabID: webID,
        )
        state.settings.preserveOpenTabs = true
        let operations = LockIsolated<[RecordedSessionOperation]>([])
        let loadCount = LockIsolated(0)
        let store = TestStore(initialState: state) {
            BrowserFeature()
        } withDependencies: {
            $0.browserSettings.save = { _ in }
            $0.browserOpenTabsSession.load = {
                loadCount.withValue { $0 += 1 }
                return .missing
            }
            $0.browserOpenTabsSession.save = { session, revision in
                operations.withValue { $0.append(.save(revision, session)) }
            }
            $0.browserOpenTabsSession.purge = { revision in
                operations.withValue { $0.append(.purge(revision)) }
            }
        }
        store.exhaustivity = .off

        await store.send(.preserveOpenTabsChanged(false))
        await store.finish()
        await store.send(.preserveOpenTabsChanged(true))
        await store.finish()

        #expect(operations.value.contains(.purge(1)))
        #expect(operations.value.contains { operation in
            guard case let .save(revision, session) = operation else {
                return false
            }

            return revision == 2
                && session.entries == [
                    .init(position: 0, kind: .startPage),
                    .init(position: 1, kind: .web(url)),
                ]
                && session.selectedPosition == 1
        })
        #expect(store.state.openTabsEntryLifecycle == .completed)
        #expect(loadCount.value == 0)
    }

    @Test("Reset before entry preserves an enabled saved session, while an Off reset snapshots fresh tabs")
    func resetPreservesOrStartsSessionAccordingToPreviousPreference() async throws {
        let url = try #require(URL(string: "https://reset.example"))
        let id = BrowserTabID()
        let operations = LockIsolated<[RecordedSessionOperation]>([])
        let store = TestStore(initialState: BrowserFeature.State.readyForTesting(
            tabs: [.web(id: id, url: url)],
            selectedTabID: id,
        )) {
            BrowserFeature()
        } withDependencies: {
            $0.browserSettings.reset = {}
            $0.browserOpenTabsSession.save = { session, revision in
                operations.withValue { $0.append(.save(revision, session)) }
            }
            $0.browserOpenTabsSession.advance = { revision in
                operations.withValue { $0.append(.advance(revision)) }
            }
        }
        store.exhaustivity = .off

        await store.send(.resetSettings)
        await store.finish()

        #expect(operations.value == [.advance(1)])
        #expect(store.state.openTabsEntryLifecycle == .notEntered)

        var offState = BrowserFeature.State.readyForTesting(initialTabID: BrowserTabID())
        offState.settings.preserveOpenTabs = false
        let offOperations = LockIsolated<[RecordedSessionOperation]>([])
        let offStore = TestStore(initialState: offState) {
            BrowserFeature()
        } withDependencies: {
            $0.browserSettings.reset = {}
            $0.browserOpenTabsSession.save = { session, revision in
                offOperations.withValue { $0.append(.save(revision, session)) }
            }
        }
        offStore.exhaustivity = .off

        await offStore.send(.resetSettings)
        await offStore.finish()

        #expect(offOperations.value.count == 1)
        #expect(offOperations.value.first.map { operation in
            guard case let .save(_, session) = operation else {
                return false
            }

            return session.entries == [.init(position: 0, kind: .startPage)]
        } == true)
        #expect(offStore.state.settings.preserveOpenTabs)
    }

    @Test("Ephemeral startup purges stale session data without attempting restoration")
    func ephemeralStartupInvalidatesSavedSession() async throws {
        let operations = LockIsolated<[RecordedSessionOperation]>([])
        let loadCount = LockIsolated(0)
        let settings = BrowserSettings(browsingProfile: .ephemeral)
        let store = TestStore(initialState: BrowserFeature.State()) {
            BrowserFeature()
        } withDependencies: {
            $0.uuid = .incrementing
            $0.browserSettings.load = { settings }
            $0.browserLibrary.loadBookmarks = { [] }
            $0.browserLibrary.loadHistory = { [] }
            $0.browserWebKit = BrowserWebKitClient(
                execute: { _ in },
                events: { AsyncStream { $0.finish() } },
            )
            $0.browserOpenTabsSession.load = {
                loadCount.withValue { $0 += 1 }
                return .missing
            }
            $0.browserOpenTabsSession.purge = { revision in
                operations.withValue { $0.append(.purge(revision)) }
            }
        }
        store.exhaustivity = .off

        await store.send(.profileInitializationRequested)
        let profileRequestID = try #require(store.state.profileConfigurationRequestID)
        await store.receive(.loaded(
            settings: settings,
            bookmarks: [],
            history: [],
            profileConfigurationID: profileRequestID,
        ))
        await store.finish()

        #expect(store.state.settings.browsingProfile == .ephemeral)
        #expect(operations.value.count == 1)
        #expect(loadCount.value == 0)
        #expect(store.state.openTabsEntryLifecycle == .notEntered)
    }

    @Test("Confirmed profile switches purge the old session and preserve a fresh return session")
    func profileSwitchesNeverResurrectEphemeralTabs() async throws {
        let privateURL = try #require(URL(string: "https://private.example"))
        let startID = BrowserTabID()
        let webID = BrowserTabID()
        let operations = LockIsolated<[RecordedSessionOperation]>([])
        let store = TestStore(initialState: BrowserFeature.State.readyForTesting(
            tabs: [.startPage(id: startID), .web(id: webID, url: privateURL)],
            selectedTabID: webID,
        )) {
            BrowserFeature()
        } withDependencies: {
            $0.uuid = .incrementing
            $0.browserSettings.save = { _ in }
            $0.browserSettings.reset = {}
            $0.browserOpenTabsSession.purge = { revision in
                operations.withValue { $0.append(.purge(revision)) }
            }
            $0.browserOpenTabsSession.save = { session, revision in
                operations.withValue { $0.append(.save(revision, session)) }
            }
        }
        store.exhaustivity = .off

        await store.send(.profileChangeRequested(.ephemeral))
        await store.send(.profileChangeConfirmed)
        await store.finish()
        #expect(store.state.settings.browsingProfile == .ephemeral)
        #expect(store.state.tabs.count == 1)
        #expect(operations.value.contains {
            if case .purge = $0 {
                true
            } else {
                false
            }
        })
        #expect(!operations.value.contains { operation in
            guard case let .save(_, session) = operation else {
                return false
            }

            return session.entries.contains(.init(position: 0, kind: .web(privateURL)))
        })

        await store.send(.profileChangeRequested(.persistentPrivate))
        await store.send(.profileChangeConfirmed)
        await store.finish()

        #expect(store.state.settings.browsingProfile == .persistentPrivate)
        #expect(operations.value.contains { operation in
            guard case let .save(_, session) = operation else {
                return false
            }

            return session.entries == [.init(position: 0, kind: .startPage)]
        })
    }

    @Test("Resetting from Ephemeral purges stale tabs and saves the fresh Persistent-Private session")
    func ephemeralResetPreservesFreshPersistentPrivateSession() async throws {
        let operations = LockIsolated<[RecordedSessionOperation]>([])
        var state = BrowserFeature.State.readyForTesting()
        state.settings.browsingProfile = .ephemeral
        state.pendingProfileChange = .resetSettings
        let store = TestStore(initialState: state) {
            BrowserFeature()
        } withDependencies: {
            $0.uuid = .incrementing
            $0.browserSettings.reset = {}
            $0.browserOpenTabsSession.purge = { revision in
                operations.withValue { $0.append(.purge(revision)) }
            }
            $0.browserOpenTabsSession.save = { session, revision in
                operations.withValue { $0.append(.save(revision, session)) }
            }
            $0.browserWebKit = BrowserWebKitClient(
                execute: { _ in },
                events: { AsyncStream { $0.finish() } },
            )
        }
        store.exhaustivity = .off

        await store.send(.profileChangeConfirmed)
        let requestID = try #require(store.state.profileConfigurationRequestID)
        await store.receive(.profileConfigurationCompleted(profile: .persistentPrivate, requestID: requestID))
        await store.finish()

        #expect(store.state.settings.browsingProfile == .persistentPrivate)
        #expect(operations.value.contains(.purge(1)))
        #expect(operations.value.contains(.save(
            2,
            BrowserOpenTabsSession(
                selectedPosition: 0,
                entries: [.init(position: 0, kind: .startPage)],
            ),
        )))
    }

    @Test("A reconstructed BrowserFeature restores the latest saved logical workspace")
    func reconstructedFeatureRestoresLatestPersistedWorkspace() async throws {
        let originalIDs = [BrowserTabID(), BrowserTabID()]
        let persistedData = LockIsolated<Data?>(nil)
        let originalStore = TestStore(initialState: BrowserFeature.State.readyForTesting(
            tabs: originalIDs.map { .startPage(id: $0) },
            selectedTabID: originalIDs[0],
        )) {
            BrowserFeature()
        } withDependencies: {
            $0.uuid = .incrementing
            $0.browserWebKit = BrowserWebKitClient(
                execute: { _ in },
                events: { AsyncStream { $0.finish() } },
            )
            $0.browserOpenTabsSession.load = { .missing }
            $0.browserOpenTabsSession.save = { session, _ in
                persistedData.withValue { $0 = try? session.encoded() }
            }
        }
        originalStore.exhaustivity = .off

        await originalStore.send(.browserEntered)
        let (initialRestoreID, initialRevision) = try #require(restorationRequest(in: originalStore.state))
        await originalStore.receive(.openTabsSessionLoaded(
            requestID: initialRestoreID,
            revision: initialRevision,
            data: nil,
        ))
        await originalStore.finish()
        await originalStore.send(.selectTab(originalIDs[1]))
        await originalStore.finish()

        let savedData = try #require(persistedData.value)
        let savedSession = try #require(decodedSession(savedData))
        #expect(savedSession.entries == [
            .init(position: 0, kind: .startPage),
            .init(position: 1, kind: .startPage),
        ])
        #expect(savedSession.selectedPosition == 1)

        let reconstructedStore = TestStore(
            initialState: BrowserFeature.State.readyForTesting(initialTabID: BrowserTabID()),
        ) {
            BrowserFeature()
        } withDependencies: {
            $0.uuid = .incrementing
            $0.browserWebKit = BrowserWebKitClient(
                execute: { _ in },
                events: { AsyncStream { $0.finish() } },
            )
            $0.browserOpenTabsSession.load = { .loaded(savedData) }
        }
        reconstructedStore.exhaustivity = .off

        await reconstructedStore.send(.browserEntered)
        let (reconstructionID, reconstructionRevision) = try #require(restorationRequest(in: reconstructedStore.state))
        await reconstructedStore.receive(.openTabsSessionLoaded(
            requestID: reconstructionID,
            revision: reconstructionRevision,
            data: savedData,
        ))
        await reconstructedStore.finish()

        #expect(reconstructedStore.state.tabs.count == 2)
        try #require(reconstructedStore.state.tabs.count == 2)
        let firstTabIsStartPage = reconstructedStore.state.tabs[0].isStartPage
        let secondTabIsStartPage = reconstructedStore.state.tabs[1].isStartPage
        #expect(firstTabIsStartPage && secondTabIsStartPage)
        #expect(reconstructedStore.state.selectedTabID == reconstructedStore.state.tabs[1].id)
        #expect(reconstructedStore.state.tabs.allSatisfy { !originalIDs.contains($0.id) })
    }

    @Test("Clear History does not purge or rewrite the logical tab session")
    func clearHistoryIsIndependentFromOpenTabsSession() async throws {
        let url = try #require(URL(string: "https://history-independent.example"))
        let id = BrowserTabID()
        let operations = LockIsolated<[RecordedSessionOperation]>([])
        let clearCount = LockIsolated(0)
        let store = TestStore(initialState: BrowserFeature.State.readyForTesting(
            tabs: [.web(id: id, url: url)],
            selectedTabID: id,
        )) {
            BrowserFeature()
        } withDependencies: {
            $0.browserLibrary.clearHistory = { clearCount.withValue { $0 += 1 } }
            $0.browserOpenTabsSession.save = { session, revision in
                operations.withValue { $0.append(.save(revision, session)) }
            }
            $0.browserOpenTabsSession.purge = { revision in
                operations.withValue { $0.append(.purge(revision)) }
            }
        }
        store.exhaustivity = .off

        await store.send(.clearHistoryTapped(source: .settings))
        await store.send(.destructiveActionConfirmed)
        await store.finish()

        #expect(clearCount.value == 1)
        #expect(store.state.tabs == [.web(id: id, url: url)])
        #expect(operations.value.isEmpty)
    }

    private func decodedSession(_ data: Data) -> BrowserOpenTabsSession? {
        guard case let .decoded(session) = BrowserOpenTabsSession.decode(data) else {
            return nil
        }

        return session
    }

    private func restorationRequest(in state: BrowserFeature.State) -> (UUID, UInt64)? {
        guard case let .restoring(requestID, revision) = state.openTabsEntryLifecycle else {
            return nil
        }

        return (requestID, revision)
    }
}
