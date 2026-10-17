//
//  BrowserViewSnapshotTests.swift
//  MediaVault
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import ComposableArchitecture
import Dependencies
import Foundation
import FoundationTestSupport
import SnapshotTesting
import SwiftUI
import Testing
@testable import BrowserFeature

@Suite("Browser view snapshots", .serialized)
@MainActor
struct BrowserViewSnapshotTests {
    @Test("Fresh Start Page has no explanatory empty-state copy")
    func freshStartPage() {
        snapshot(
            .readyForTesting(initialTabID: BrowserTabID(UUID(1))),
            named: "fresh-start-page-compact-phone",
            config: DeterministicTestSupport.compactPhone,
        )
    }

    @Test("Start Page preserves bookmark tile order and fallbacks")
    func bookmarkStartPage() throws {
        var state = BrowserFeature.State.readyForTesting(initialTabID: BrowserTabID(UUID(1)))
        let favicon = try #require(Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="))
        state.bookmarks = try [
            .init(
                id: UUID(2),
                title: "Second in store",
                url: #require(URL(string: "https://second.example")),
                siblingOrder: 20,
                faviconData: favicon,
            ),
            .init(
                id: UUID(3),
                title: "First by sibling number",
                url: #require(URL(string: "https://first.example")),
                siblingOrder: 1,
            ),
        ]
        snapshot(state, named: "bookmark-order-large-phone", config: DeterministicTestSupport.largePhone)
    }

    @Test("Loaded chrome remains usable at compact and regular widths")
    func loadedChromeAcrossSizeClasses() throws {
        let url = try #require(URL(string: "http://example.com/private"))
        var tab = BrowserTab.web(id: BrowserTabID(UUID(1)), url: url)
        tab.metadata = .init(
            committedURL: url,
            title: "Example",
            canGoBack: true,
        )
        let state = BrowserFeature.State.readyForTesting(tabs: [tab], selectedTabID: tab.id)

        snapshot(
            state,
            named: "loaded-chrome-compact-phone",
            config: DeterministicTestSupport.compactPhone,
        )
        snapshot(
            state,
            named: "loaded-chrome-regular-ipad",
            config: DeterministicTestSupport.regularWidthIPad,
        )
    }

    @Test("Loading progress is deterministic")
    func loading() throws {
        let url = try #require(URL(string: "https://example.com"))
        var tab = BrowserTab.web(id: BrowserTabID(UUID(1)), url: url)
        tab.metadata = .init(
            committedURL: url,
            title: "Loading",
            isLoading: true,
            estimatedProgress: 0.42,
        )
        snapshot(
            .readyForTesting(tabs: [tab], selectedTabID: tab.id),
            named: "loading-large-phone",
            config: DeterministicTestSupport.largePhone,
        )
    }

    @Test("Navigation failure remains local with usable chrome")
    func error() throws {
        let url = try #require(URL(string: "https://offline.example"))
        let tab = BrowserTab(id: BrowserTabID(UUID(1)), content: .error(.noInternet(url)))
        snapshot(
            .readyForTesting(tabs: [tab], selectedTabID: tab.id),
            named: "error-compact-phone",
            config: DeterministicTestSupport.compactPhone,
        )
    }

    @Test("Mixed Tab Overview marks the active card without color alone")
    func overview() throws {
        let url = try #require(URL(string: "https://example.com"))
        var loading = BrowserTab.web(id: BrowserTabID(UUID(4)), url: url)
        loading.metadata = .init(
            committedURL: url,
            title: "Loading",
            isLoading: true,
            estimatedProgress: 0.5,
        )
        let state = BrowserFeature.State.readyForTesting(
            tabs: [
                .startPage(id: BrowserTabID(UUID(1))),
                .web(id: BrowserTabID(UUID(2)), url: url),
                .init(id: BrowserTabID(UUID(3)), content: .error(.serverNotFound(url))),
                loading,
                .init(id: BrowserTabID(UUID(5)), content: .terminated(lastCommittedURL: url)),
            ],
            selectedTabID: BrowserTabID(UUID(2)),
            presentation: .tabOverview,
        )
        snapshot(state, named: "tab-overview-compact-phone", config: DeterministicTestSupport.compactPhone)
        snapshot(state, named: "tab-overview-large-phone", config: DeterministicTestSupport.largePhone)
        snapshot(state, named: "tab-overview-regular-ipad", config: DeterministicTestSupport.regularWidthIPad)
    }

    @Test("Tab Overview cards keep bounded geometry at large Dynamic Type")
    func overviewLargeContentSize() throws {
        let url = try #require(URL(string: "https://example.com"))
        let tabs: [BrowserTab] = [
            .startPage(id: BrowserTabID(UUID(1))),
            .web(id: BrowserTabID(UUID(2)), url: url),
            .init(id: BrowserTabID(UUID(3)), content: .error(.serverNotFound(url))),
            .init(id: BrowserTabID(UUID(4)), content: .terminated(lastCommittedURL: url)),
        ]
        let state = BrowserFeature.State.readyForTesting(
            tabs: tabs,
            selectedTabID: tabs[0].id,
            presentation: .tabOverview,
        )
        let store = makeBrowserViewStore(initialState: state)
        assertSnapshot(
            of: BrowserView(store: store)
                .environment(\.colorScheme, .light)
                .environment(\.dynamicTypeSize, .accessibility3),
            as: .image(layout: .device(config: DeterministicTestSupport.compactPhone)),
            named: "tab-overview-large-content-size-compact-phone",
        )
    }

    @Test("Reduced Motion presents the browser endpoint without geometry zoom")
    func reducedMotion() throws {
        let url = try #require(URL(string: "https://example.com"))
        let tab = BrowserTab.web(id: BrowserTabID(UUID(1)), url: url)
        let store = makeBrowserViewStore(
            initialState: .readyForTesting(tabs: [tab], selectedTabID: tab.id),
        )
        assertSnapshot(
            of: BrowserView(store: store, reduceMotionOverride: true)
                .environment(\.colorScheme, .light),
            as: .image(layout: .device(config: DeterministicTestSupport.compactPhone)),
            named: "reduced-motion-compact-phone",
        )
    }

    @Test("Bookmark editor covers add, validation, and existing-bookmark states")
    func bookmarkEditors() {
        let states: [(String, BrowserBookmarkEditor)] = [
            ("bookmark-editor-add", .init(title: "Example", urlDraft: "https://example.com")),
            ("bookmark-editor-validation", .init(
                title: "Example",
                urlDraft: "javascript:alert(1)",
                validationMessage: "Enter a valid HTTP or HTTPS address.",
            )),
            ("bookmark-editor-existing", .init(
                bookmarkID: UUID(2),
                title: "Saved Example",
                urlDraft: "https://example.com/saved",
            )),
        ]
        for (name, editor) in states {
            var state = BrowserFeature.State.readyForTesting(initialTabID: BrowserTabID(UUID(1)))
            state.bookmarkEditor = editor
            let store = Store(initialState: state) { BrowserFeature() }
            presentationSnapshot(
                BrowserBookmarkEditorView(store: store),
                named: name,
                config: DeterministicTestSupport.compactPhone,
            )
        }
    }

    @Test("Browser Library snapshots true-empty, populated, and local search states")
    func browserLibrary() throws {
        let referenceDate = DeterministicTestSupport.referenceDate
        let bookmarkURL = try #require(URL(string: "https://bookmarks.example/private"))
        let historyURL = try #require(URL(string: "https://history.example/visited"))

        var emptyState = BrowserFeature.State.readyForTesting(initialTabID: BrowserTabID(UUID(1)))
        emptyState.library = .init(section: .bookmarks, referenceDate: referenceDate)
        librarySnapshot(emptyState, named: "library-bookmarks-empty-regular-ipad")

        emptyState.library = .init(section: .history, referenceDate: referenceDate)
        librarySnapshot(emptyState, named: "library-history-empty-regular-ipad")

        var state = BrowserFeature.State.readyForTesting(initialTabID: BrowserTabID(UUID(1)))
        state.bookmarks = [BrowserBookmark(
            id: UUID(2),
            title: "Saved Bookmark",
            url: bookmarkURL,
            siblingOrder: 0,
        )]
        state.history = [BrowserHistoryEntry(
            id: UUID(3),
            title: "Visited Page",
            url: historyURL,
            visitedAt: referenceDate.addingTimeInterval(-600),
        )]
        state.library = .init(section: .bookmarks, referenceDate: referenceDate)
        librarySnapshot(state, named: "library-bookmarks-regular-ipad")

        state.library = .init(section: .history, referenceDate: referenceDate)
        librarySnapshot(state, named: "library-history-regular-ipad")

        state.library = .init(
            section: .bookmarks,
            bookmarkSearch: "no local match",
            referenceDate: referenceDate,
        )
        librarySnapshot(state, named: "library-bookmarks-empty-search-regular-ipad")

        state.library = .init(
            section: .history,
            historySearch: "no local match",
            referenceDate: referenceDate,
        )
        librarySnapshot(state, named: "library-history-empty-search-regular-ipad")
    }

    @Test("Authenticated Browser settings show privacy disclosure and new-tab choices")
    func settings() {
        var state = BrowserFeature.State.readyForTesting(initialTabID: BrowserTabID(UUID(1)))
        state.profileLifecycle = .ready
        let store = Store(initialState: state) { BrowserFeature() }
        presentationSnapshot(
            NavigationStack { BrowserSettingsView(store: store) },
            named: "settings-browser-large-phone",
            config: DeterministicTestSupport.largePhone,
        )

        var confirmationState = state
        confirmationState.pendingProfileChange = .profile(.ephemeral)
        let confirmationStore = Store(initialState: confirmationState) { BrowserFeature() }
        presentationSnapshot(
            NavigationStack { BrowserSettingsView(store: confirmationStore) },
            named: "settings-browser-ephemeral-confirmation-large-phone",
            config: DeterministicTestSupport.largePhone,
        )

        var resetConfirmationState = state
        resetConfirmationState.settings.browsingProfile = .ephemeral
        resetConfirmationState.pendingProfileChange = .resetSettings
        let resetConfirmationStore = Store(initialState: resetConfirmationState) { BrowserFeature() }
        presentationSnapshot(
            NavigationStack { BrowserSettingsView(store: resetConfirmationStore) },
            named: "settings-browser-ephemeral-reset-confirmation-large-phone",
            config: DeterministicTestSupport.largePhone,
        )

        var askState = state
        askState.settings.openLinksInNewTabs = .askEveryTime
        let askStore = Store(initialState: askState) { BrowserFeature() }
        presentationSnapshot(
            NavigationStack { BrowserSettingsView(store: askStore) },
            named: "settings-browser-ask-every-time-large-phone",
            config: DeterministicTestSupport.largePhone,
        )
    }

    @Test("Downloads show determinate progress and completed actions on phone and regular iPad")
    func downloadProgressAndCompletedRows() {
        let projection = downloadProjection(records: [
            downloadRecord(filename: nil, received: 4_194_304, expected: 16_777_827, ready: false),
            downloadRecord(filename: "fixture.pdf", received: 16_777_827, expected: 16_777_827, ready: true),
        ])
        let store = downloadSnapshotStore(projection)
        downloadSnapshot(
            BrowserDownloadsView(store: store),
            named: "downloads-progress-completed-compact-phone",
            config: DeterministicTestSupport.compactPhone,
        )
        downloadSnapshot(
            BrowserDownloadsView(store: store),
            named: "downloads-progress-completed-regular-ipad",
            config: DeterministicTestSupport.regularWidthIPad,
        )
    }

    @Test("Completed download actions fit a narrow iPad column at accessibility size")
    func downloadCompletedActionsLargeType() {
        let store = downloadSnapshotStore(downloadProjection(records: [
            downloadRecord(filename: "fixture.pdf", received: 16_777_827, expected: 16_777_827, ready: true),
        ]))
        downloadSnapshot(
            BrowserDownloadsView(store: store).environment(\.dynamicTypeSize, .accessibility3),
            named: "downloads-completed-actions-accessibility3-narrow-ipad",
            config: DeterministicTestSupport.narrowWidthIPad,
        )
    }

    @Test("Transfer failure and download-only cleanup recovery remain readable at accessibility size")
    func downloadFailureAndCleanupRetryLargeType() {
        for retry in [false, true] {
            var projection = downloadProjection(records: [])
            projection.isAvailable = false
            projection.cleanupNeedsRetry = retry
            projection.notice = retry ? .cleanupRequired : .transferFailed
            let store = downloadSnapshotStore(projection)
            downloadSnapshot(
                BrowserDownloadsView(store: store).environment(\.dynamicTypeSize, .accessibility3),
                named: retry
                    ? "downloads-cleanup-retry-accessibility3-phone"
                    : "downloads-failure-accessibility3-phone",
                config: DeterministicTestSupport.compactPhone,
            )
        }
    }

    @Test("Closed Downloads keeps the redacted browser notice visible with Reduce Motion")
    func closedDownloadNoticeReducedMotion() {
        var projection = downloadProjection(records: [])
        projection.notice = .activeTransferLimitReached
        let store = downloadSnapshotStore(projection)
        #expect(!store.downloadsArePresented)
        downloadSnapshot(
            BrowserView(store: store, reduceMotionOverride: true),
            named: "downloads-closed-notice-reduced-motion-phone",
            config: DeterministicTestSupport.compactPhone,
        )
    }

    /// Recording is restricted to these new download references. Missing PNGs are written and
    /// reported as failures by SnapshotTesting; existing images are compared, never overwritten.
    private func downloadSnapshot(_ content: some View, named name: String, config: ViewImageConfig) {
        withSnapshotTesting(record: .missing) {
            presentationSnapshot(content, named: name, config: config)
        }
    }

    /// Projection fixtures freeze all visible values. Opaque download identities are created once
    /// per record and never rendered; the production type intentionally exposes no fixed-ID initializer.
    /// Indeterminate spinner animation is excluded from PNGs; its semantics need the separate UI gate.
    private func downloadRecord(
        filename: String?,
        received: Int64,
        expected: Int64?,
        ready: Bool,
    ) -> BrowserDownloadRecord {
        .init(
            id: BrowserDownloadID(),
            tabID: BrowserTabID(UUID(1)),
            filename: filename,
            receivedBytes: received,
            expectedBytes: expected,
            isReady: ready,
        )
    }

    private func downloadProjection(records: [BrowserDownloadRecord]) -> BrowserDownloadSnapshot {
        var projection = BrowserDownloadSnapshot()
        projection.revision = 42
        projection.generation = 7
        projection.isAvailable = true
        projection.records = records
        return projection
    }

    /// The real Browser reducer receives an immutable projection with no live download subscription.
    /// This keeps image rendering independent of process-wide scene authorization and task scheduling.
    private func downloadSnapshotStore(_ projection: BrowserDownloadSnapshot) -> StoreOf<BrowserFeature> {
        var state = BrowserFeature.State.readyForTesting(initialTabID: BrowserTabID(UUID(1)))
        state.downloads = projection
        state.downloadsArePresented = false
        return withDependencies {
            $0.browserDownloads = BrowserDownloadClient(
                execute: { _ in },
                events: { AsyncStream { $0.finish() } },
            )
        } operation: {
            makeBrowserViewStore(initialState: state)
        }
    }

    private func snapshot(_ state: BrowserFeature.State, named name: String, config: ViewImageConfig) {
        let store = makeBrowserViewStore(initialState: state)
        assertSnapshot(
            of: BrowserView(store: store).environment(\.colorScheme, .light),
            as: .image(layout: .device(config: config)),
            named: name,
        )
    }

    private func librarySnapshot(_ state: BrowserFeature.State, named name: String) {
        let store = Store(initialState: state) { BrowserFeature() }
        presentationSnapshot(
            BrowserLibraryView(store: store)
                .environment(\.calendar, DeterministicTestSupport.referenceCalendar)
                .environment(\.locale, DeterministicTestSupport.referenceLocale)
                .environment(\.timeZone, DeterministicTestSupport.referenceTimeZone),
            named: name,
            config: DeterministicTestSupport.regularWidthIPad,
        )
    }

    private func presentationSnapshot(
        _ content: some View,
        named name: String,
        config: ViewImageConfig,
    ) {
        assertSnapshot(
            of: content.environment(\.colorScheme, .light),
            as: .image(layout: .device(config: config)),
            named: name,
        )
    }

    private func makeBrowserViewStore(initialState: BrowserFeature.State) -> StoreOf<BrowserFeature> {
        var initialState = initialState
        initialState.settings.preserveOpenTabs = false
        return withDependencies {
            $0.uuid = .incrementing
        } operation: {
            Store(initialState: initialState) { BrowserFeature() }
        }
    }
}

extension UUID {
    fileprivate init(_ value: UInt8) {
        self.init(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, value))
    }
}
