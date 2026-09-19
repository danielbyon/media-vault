//
//  BrowserPreviewReducerTests.swift
//  MediaVault
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import ComposableArchitecture
import Foundation
import Testing
@testable import BrowserFeature

@Suite("Browser preview reducer behavior")
@MainActor
struct BrowserPreviewReducerTests {
    @Test("A preview cache entry from an older revision is never rendered")
    func stalePreviewBytesAreRejectedWithoutEviction() throws {
        let tabID = BrowserTabID()
        let url = try #require(URL(string: "https://example.com"))
        let tab = BrowserTab.web(id: tabID, url: url)
        let staleRevision = BrowserTabPreviewRevision()
        let currentRevision = BrowserTabPreviewRevision()
        let staleBytes = Data([1, 2, 3])
        let cache: [BrowserTabID: BrowserTabPreviewCacheEntry] = [
            tabID: .init(revision: staleRevision, pngData: staleBytes),
        ]

        let representation = BrowserTabPreviewRepresentation.cachedOrFallback(
            for: tab,
            revision: currentRevision,
            cache: cache,
        )

        #expect(representation == .placeholder(.web))
        #expect(cache[tabID]?.revision == staleRevision)
        #expect(cache[tabID]?.pngData == staleBytes)
    }

    @Test("Native preview results replace live-tab cache and failed results preserve stale data")
    func nativePreviewResultsPreserveStaleDataOnFailure() async throws {
        let tabID = BrowserTabID()
        let url = try #require(URL(string: "https://example.com"))
        let stale = Data([1, 2, 3])
        let fresh = Data([4, 5, 6])
        var state = BrowserFeature.State(
            tabs: [.web(id: tabID, url: url)],
            selectedTabID: tabID,
        )
        state.tabPreviewData[tabID] = .init(
            revision: state.previewRevision(for: tabID),
            pngData: stale,
        )
        let revision = state.previewRevision(for: tabID)
        let store = TestStore(initialState: state) { BrowserFeature() }

        await store.send(.nativePreviewCaptured(tabID: tabID, revision: revision, pngData: fresh)) {
            $0.tabPreviewData[tabID] = .init(revision: revision, pngData: fresh)
        }
        await store.send(.nativePreviewCaptured(tabID: tabID, revision: revision, pngData: nil))
        #expect(store.state.tabPreviewData[tabID]?.pngData == fresh)
    }

    @Test("Preview results for closed or unknown tabs cannot recreate cache entries")
    func previewResultsRequireLiveTab() async throws {
        let tabID = BrowserTabID()
        let url = try #require(URL(string: "https://example.com"))
        var state = BrowserFeature.State(
            tabs: [.web(id: tabID, url: url)],
            selectedTabID: tabID,
        )
        state.tabPreviewData[tabID] = .init(
            revision: state.previewRevision(for: tabID),
            pngData: Data([1, 2, 3]),
        )
        let store = TestStore(initialState: state) { BrowserFeature() } withDependencies: {
            $0.uuid = .incrementing
        }
        store.exhaustivity = .off(showSkippedAssertions: false)
        let revision = store.state.previewRevision(for: tabID)

        await store.send(.closeTab(tabID))
        #expect(store.state.tabPreviewData[tabID] == nil)
        await store.send(.webKitEvent(.preview(
            tabID: tabID,
            revision: revision,
            pngData: Data([7]),
        )))
        #expect(store.state.tabPreviewData[tabID] == nil)
    }

    @Test("Memory pressure evicts previews without changing authoritative tabs")
    func memoryPressureEvictsOnlyPreviews() async throws {
        let firstID = BrowserTabID()
        let secondID = BrowserTabID()
        let url = try #require(URL(string: "https://example.com"))
        var state = BrowserFeature.State(
            tabs: [.web(id: firstID, url: url), .startPage(id: secondID)],
            selectedTabID: firstID,
        )
        state.tabPreviewData = [
            firstID: .init(revision: state.previewRevision(for: firstID), pngData: Data([1])),
            secondID: .init(revision: state.previewRevision(for: secondID), pngData: Data([2])),
        ]
        let store = TestStore(initialState: state) { BrowserFeature() }

        await store.send(.previewCacheEvicted) {
            $0.tabPreviewData = [:]
        }
        #expect(store.state.tabs.map(\.id) == [firstID, secondID])
        #expect(store.state.selectedTabID == firstID)
    }

    @Test("Close all clears every preview and ignores late results for closed tabs")
    func closeAllClearsPreviewsAndRejectsLateResults() async throws {
        let firstID = BrowserTabID()
        let secondID = BrowserTabID()
        let thirdID = BrowserTabID()
        let url = try #require(URL(string: "https://example.com"))
        let closedIDs = [firstID, secondID, thirdID]
        var state = BrowserFeature.State(
            tabs: [
                .web(id: firstID, url: url),
                .web(id: secondID, url: url),
                .init(id: thirdID, content: .error(.serverNotFound(url))),
            ],
            selectedTabID: firstID,
        )
        state.tabPreviewData = Dictionary(uniqueKeysWithValues: closedIDs.map {
            ($0, BrowserTabPreviewCacheEntry(
                revision: state.previewRevision(for: $0),
                pngData: Data([1]),
            ))
        })
        let store = TestStore(initialState: state) { BrowserFeature() } withDependencies: {
            $0.browserWebKit.execute = { _ in }
            $0.uuid = .incrementing
        }
        store.exhaustivity = .off(showSkippedAssertions: false)

        await store.send(.closeAllConfirmed)
        #expect(store.state.tabPreviewData.isEmpty)

        for tabID in closedIDs {
            await store.send(.webKitEvent(.preview(
                tabID: tabID,
                revision: state.previewRevision(for: tabID),
                pngData: Data([9]),
            )))
        }
        #expect(store.state.tabPreviewData.isEmpty)
    }

    @Test("Close other tabs preserves only the survivor preview and rejects closed results")
    func closeOtherTabsPreservesSurvivorPreview() async throws {
        let survivorID = BrowserTabID()
        let closedFirstID = BrowserTabID()
        let closedSecondID = BrowserTabID()
        let url = try #require(URL(string: "https://example.com"))
        var state = BrowserFeature.State(
            tabs: [
                .web(id: survivorID, url: url),
                .web(id: closedFirstID, url: url),
                .web(id: closedSecondID, url: url),
            ],
            selectedTabID: survivorID,
        )
        state.tabPreviewData = [
            survivorID: .init(revision: state.previewRevision(for: survivorID), pngData: Data([1])),
            closedFirstID: .init(
                revision: state.previewRevision(for: closedFirstID),
                pngData: Data([2]),
            ),
            closedSecondID: .init(
                revision: state.previewRevision(for: closedSecondID),
                pngData: Data([3]),
            ),
        ]
        let store = TestStore(initialState: state) { BrowserFeature() } withDependencies: {
            $0.browserWebKit.execute = { _ in }
        }
        store.exhaustivity = .off(showSkippedAssertions: false)

        await store.send(.closeOtherTabsConfirmed(survivorID))
        #expect(store.state.tabPreviewData == [
            survivorID: .init(
                revision: store.state.previewRevision(for: survivorID),
                pngData: Data([1]),
            ),
        ])

        await store.send(.webKitEvent(.preview(
            tabID: closedFirstID,
            revision: state.previewRevision(for: closedFirstID),
            pngData: Data([8]),
        )))
        await store.send(.webKitEvent(.preview(
            tabID: closedSecondID,
            revision: state.previewRevision(for: closedSecondID),
            pngData: Data([9]),
        )))
        #expect(store.state.tabPreviewData == [
            survivorID: .init(
                revision: store.state.previewRevision(for: survivorID),
                pngData: Data([1]),
            ),
        ])
    }

    @Test("Overview entry is immediate and refreshes only web previews")
    func overviewEntryRequestsWebPreviewsWithoutWaiting() async throws {
        let startID = BrowserTabID()
        let webID = BrowserTabID()
        let errorID = BrowserTabID()
        let terminatedID = BrowserTabID()
        let url = try #require(URL(string: "https://example.com"))
        let commands = LockIsolated<[BrowserWebKitCommand]>([])
        let initialState = BrowserFeature.State(
            tabs: [
                .startPage(id: startID),
                .web(id: webID, url: url),
                .init(id: errorID, content: .error(.serverNotFound(url))),
                .init(id: terminatedID, content: .terminated(lastCommittedURL: url)),
            ],
            selectedTabID: startID,
        )
        let webRevision = initialState.previewRevision(for: webID)
        let store = TestStore(initialState: initialState) { BrowserFeature() } withDependencies: {
            $0.browserWebKit.execute = { command in
                commands.withValue { $0.append(command) }
            }
        }
        store.exhaustivity = .off(showSkippedAssertions: false)

        await store.send(.showTabOverviewTapped)
        #expect(store.state.presentation == .tabOverview)
        #expect(store.state.tabOverviewFocusID == startID)
        await store.finish()

        #expect(commands.value == [.capturePreview(tabID: webID, revision: webRevision)])
    }

    @Test("A late preview from an invalidated document cannot repopulate the cache")
    func latePreviewFromOldRevisionIsIgnored() async throws {
        let tabID = BrowserTabID()
        let firstURL = try #require(URL(string: "https://first.example"))
        let secondURL = try #require(URL(string: "https://second.example"))
        let state = BrowserFeature.State(
            tabs: [.web(id: tabID, url: firstURL)],
            selectedTabID: tabID,
        )
        let oldRevision = state.previewRevision(for: tabID)
        let store = TestStore(initialState: state) { BrowserFeature() }
        store.exhaustivity = .off(showSkippedAssertions: false)

        await store.send(.navigate(secondURL))
        await store.send(.webKitEvent(.preview(
            tabID: tabID,
            revision: oldRevision,
            pngData: Data([9]),
        )))

        #expect(store.state.tabPreviewData[tabID] == nil)
        #expect(store.state.previewRevision(for: tabID) != oldRevision)
    }

    @Test("An explicit navigation and its committed metadata share one invalidation")
    func explicitNavigationDoesNotDoubleInvalidateOnCommit() async throws {
        let tabID = BrowserTabID()
        let firstURL = try #require(URL(string: "https://first.example"))
        let secondURL = try #require(URL(string: "https://second.example"))
        let state = BrowserFeature.State(
            tabs: [.web(id: tabID, url: firstURL)],
            selectedTabID: tabID,
        )
        let store = TestStore(initialState: state) { BrowserFeature() }
        store.exhaustivity = .off(showSkippedAssertions: false)

        await store.send(.navigate(secondURL))
        let explicitRevision = store.state.previewRevision(for: tabID)
        await store.send(.webKitEvent(.metadata(
            tabID: tabID,
            .init(committedURL: secondURL),
        )))

        #expect(store.state.previewRevision(for: tabID) == explicitRevision)
    }

    @Test("A reload expectation is consumed by same-URL metadata before a later navigation")
    func reloadExpectationCannotSuppressLaterNavigation() async throws {
        let tabID = BrowserTabID()
        let firstURL = try #require(URL(string: "https://first.example"))
        let secondURL = try #require(URL(string: "https://second.example"))
        var tab = BrowserTab.web(id: tabID, url: firstURL)
        tab.metadata.committedURL = firstURL
        let state = BrowserFeature.State(
            tabs: [tab],
            selectedTabID: tabID,
        )
        let store = TestStore(initialState: state) { BrowserFeature() } withDependencies: {
            $0.browserWebKit.execute = { _ in }
        }
        store.exhaustivity = .off(showSkippedAssertions: false)

        await store.send(.reloadOrStopTapped)
        let revisionAfterReload = store.state.previewRevision(for: tabID)
        await store.send(.webKitEvent(.metadata(
            tabID: tabID,
            .init(committedURL: firstURL),
        )))
        await store.send(.webKitEvent(.metadata(
            tabID: tabID,
            .init(committedURL: secondURL),
        )))

        #expect(store.state.previewRevision(for: tabID) != revisionAfterReload)
    }

    @Test("A pull-to-refresh expectation cannot suppress a later navigation")
    func pullToRefreshExpectationCannotSuppressLaterNavigation() async throws {
        let tabID = BrowserTabID()
        let firstURL = try #require(URL(string: "https://first.example"))
        let secondURL = try #require(URL(string: "https://second.example"))
        var tab = BrowserTab.web(id: tabID, url: firstURL)
        tab.metadata.committedURL = firstURL
        let state = BrowserFeature.State(
            tabs: [tab],
            selectedTabID: tabID,
        )
        let store = TestStore(initialState: state) { BrowserFeature() } withDependencies: {
            $0.browserWebKit.execute = { _ in }
        }
        store.exhaustivity = .off(showSkippedAssertions: false)

        await store.send(.pullToRefresh)
        let revisionAfterRefresh = store.state.previewRevision(for: tabID)
        await store.send(.webKitEvent(.metadata(
            tabID: tabID,
            .init(committedURL: firstURL),
        )))
        await store.send(.webKitEvent(.metadata(
            tabID: tabID,
            .init(committedURL: secondURL),
        )))

        #expect(store.state.previewRevision(for: tabID) != revisionAfterRefresh)
    }

    @Test("An unexpected committed document change invalidates the current preview")
    func unexpectedCommittedDocumentChangeInvalidatesPreview() async throws {
        let tabID = BrowserTabID()
        let firstURL = try #require(URL(string: "https://first.example"))
        let secondURL = try #require(URL(string: "https://second.example"))
        var state = BrowserFeature.State(
            tabs: [.web(id: tabID, url: firstURL)],
            selectedTabID: tabID,
        )
        state.tabs[0].metadata.committedURL = firstURL
        state.tabPreviewData[tabID] = .init(
            revision: state.previewRevision(for: tabID),
            pngData: Data([1]),
        )
        let oldRevision = state.previewRevision(for: tabID)
        let store = TestStore(initialState: state) { BrowserFeature() }
        store.exhaustivity = .off(showSkippedAssertions: false)

        await store.send(.webKitEvent(.metadata(
            tabID: tabID,
            .init(committedURL: secondURL),
        )))

        #expect(store.state.tabPreviewData[tabID] == nil)
        #expect(store.state.previewRevision(for: tabID) != oldRevision)
    }
}
