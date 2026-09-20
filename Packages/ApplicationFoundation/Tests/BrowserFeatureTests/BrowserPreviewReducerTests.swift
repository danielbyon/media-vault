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
        let entry = BrowserTabPreviewCacheEntry(revision: staleRevision, pngData: staleBytes)

        let representation = BrowserTabPreviewRepresentation.cachedOrFallback(
            for: tab,
            revision: currentRevision,
            entry: entry,
        )

        #expect(representation == .placeholder(.web))
        #expect(entry.revision == staleRevision)
        #expect(entry.pngData == staleBytes)
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
        state.previewState.setData(.init(
            revision: state.previewState.revision(for: tabID),
            pngData: stale,
        ), for: tabID)
        let revision = state.previewState.revision(for: tabID)
        let store = TestStore(initialState: state) { BrowserFeature() }

        await store.send(.nativePreviewCaptured(tabID: tabID, revision: revision, pngData: fresh)) {
            $0.previewState.setData(.init(revision: revision, pngData: fresh), for: tabID)
        }
        await store.send(.nativePreviewCaptured(tabID: tabID, revision: revision, pngData: nil))
        #expect(store.state.previewState.data(for: tabID)?.pngData == fresh)
    }

    @Test("Preview results for closed or unknown tabs cannot recreate cache entries")
    func previewResultsRequireLiveTab() async throws {
        let tabID = BrowserTabID()
        let url = try #require(URL(string: "https://example.com"))
        var state = BrowserFeature.State(
            tabs: [.web(id: tabID, url: url)],
            selectedTabID: tabID,
        )
        state.previewState.setData(.init(
            revision: state.previewState.revision(for: tabID),
            pngData: Data([1, 2, 3]),
        ), for: tabID)
        let store = TestStore(initialState: state) { BrowserFeature() } withDependencies: {
            $0.uuid = .incrementing
        }
        store.exhaustivity = .off(showSkippedAssertions: false)
        let revision = store.state.previewState.revision(for: tabID)

        await store.send(.closeTab(tabID))
        #expect(store.state.previewState.data(for: tabID) == nil)
        await store.send(.webKitEvent(.preview(
            tabID: tabID,
            revision: revision,
            pngData: Data([7]),
        )))
        #expect(store.state.previewState.data(for: tabID) == nil)
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
        state.previewState.setData(
            .init(revision: state.previewState.revision(for: firstID), pngData: Data([1])),
            for: firstID,
        )
        state.previewState.setData(
            .init(revision: state.previewState.revision(for: secondID), pngData: Data([2])),
            for: secondID,
        )
        let store = TestStore(initialState: state) { BrowserFeature() }

        await store.send(.previewCacheEvicted) {
            $0.previewState.clearData()
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
        for tabID in closedIDs {
            state.previewState.setData(.init(
                revision: state.previewState.revision(for: tabID),
                pngData: Data([1]),
            ), for: tabID)
        }
        let store = TestStore(initialState: state) { BrowserFeature() } withDependencies: {
            $0.browserWebKit.execute = { _ in }
            $0.uuid = .incrementing
        }
        store.exhaustivity = .off(showSkippedAssertions: false)

        await store.send(.closeAllConfirmed)
        #expect(closedIDs.allSatisfy { store.state.previewState.data(for: $0) == nil })

        for tabID in closedIDs {
            await store.send(.webKitEvent(.preview(
                tabID: tabID,
                revision: state.previewState.revision(for: tabID),
                pngData: Data([9]),
            )))
        }
        #expect(closedIDs.allSatisfy { store.state.previewState.data(for: $0) == nil })
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
        state.previewState.setData(
            .init(revision: state.previewState.revision(for: survivorID), pngData: Data([1])),
            for: survivorID,
        )
        state.previewState.setData(.init(
            revision: state.previewState.revision(for: closedFirstID),
            pngData: Data([2]),
        ), for: closedFirstID)
        state.previewState.setData(.init(
            revision: state.previewState.revision(for: closedSecondID),
            pngData: Data([3]),
        ), for: closedSecondID)
        let store = TestStore(initialState: state) { BrowserFeature() } withDependencies: {
            $0.browserWebKit.execute = { _ in }
        }
        store.exhaustivity = .off(showSkippedAssertions: false)

        await store.send(.closeOtherTabsConfirmed(survivorID))
        #expect(store.state.previewState.data(for: survivorID)?.pngData == Data([1]))
        #expect(store.state.previewState.data(for: closedFirstID) == nil)
        #expect(store.state.previewState.data(for: closedSecondID) == nil)

        await store.send(.webKitEvent(.preview(
            tabID: closedFirstID,
            revision: state.previewState.revision(for: closedFirstID),
            pngData: Data([8]),
        )))
        await store.send(.webKitEvent(.preview(
            tabID: closedSecondID,
            revision: state.previewState.revision(for: closedSecondID),
            pngData: Data([9]),
        )))
        #expect(store.state.previewState.data(for: survivorID)?.pngData == Data([1]))
        #expect(store.state.previewState.data(for: closedFirstID) == nil)
        #expect(store.state.previewState.data(for: closedSecondID) == nil)
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
        let webRevision = initialState.previewState.revision(for: webID)
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
        let oldRevision = state.previewState.revision(for: tabID)
        let store = TestStore(initialState: state) { BrowserFeature() }
        store.exhaustivity = .off(showSkippedAssertions: false)

        await store.send(.navigate(secondURL))
        await store.send(.webKitEvent(.preview(
            tabID: tabID,
            revision: oldRevision,
            pngData: Data([9]),
        )))

        #expect(store.state.previewState.data(for: tabID) == nil)
        #expect(store.state.previewState.revision(for: tabID) != oldRevision)
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
        let operationID = try #require(store.state.previewState.operation(for: tabID))
        let explicitRevision = store.state.previewState.revision(for: tabID)
        await store.send(.webKitEvent(.metadata(
            tabID: tabID,
            metadata: .init(committedURL: secondURL),
            correlation: .operation(operationID),
        )))

        #expect(store.state.previewState.revision(for: tabID) == explicitRevision)
    }

    @Test("A correlated commit keeps its operation until loading finishes")
    func correlatedCommitDoesNotDiscardPendingOperation() async throws {
        let tabID = BrowserTabID()
        let firstURL = try #require(URL(string: "https://first.example"))
        let secondURL = try #require(URL(string: "https://second.example"))
        var tab = BrowserTab.web(id: tabID, url: firstURL)
        tab.metadata.committedURL = firstURL
        let store = TestStore(
            initialState: BrowserFeature.State(
                tabs: [tab],
                selectedTabID: tabID,
            ),
        ) { BrowserFeature() }
        store.exhaustivity = .off(showSkippedAssertions: false)

        await store.send(.navigate(secondURL))
        let operationID = try #require(store.state.previewState.operation(for: tabID))

        await store.send(.webKitEvent(.metadata(
            tabID: tabID,
            metadata: .init(committedURL: secondURL, isLoading: true),
            correlation: .operation(operationID),
        )))

        #expect(store.state.previewState.operation(for: tabID) == operationID)

        await store.send(.webKitEvent(.metadata(
            tabID: tabID,
            metadata: .init(committedURL: secondURL),
            correlation: .operation(operationID),
        )))

        #expect(store.state.previewState.operation(for: tabID) == nil)
    }

    @Test("A tagged no-op metadata event consumes its preview invalidation")
    func taggedNoOpMetadataCompletesOperation() async throws {
        let tabID = BrowserTabID()
        let url = try #require(URL(string: "https://example.com"))
        let tab = BrowserTab.web(id: tabID, url: url)
        let store = TestStore(
            initialState: BrowserFeature.State(
                tabs: [tab],
                selectedTabID: tabID,
            ),
        ) { BrowserFeature() }
        store.exhaustivity = .off(showSkippedAssertions: false)

        await store.send(.reloadOrStopTapped)
        let operationID = try #require(store.state.previewState.operation(for: tabID))

        await store.send(.webKitEvent(.metadata(
            tabID: tabID,
            metadata: .init(),
            correlation: .operation(operationID),
        )))

        #expect(store.state.previewState.operation(for: tabID) == nil)
    }

    @Test("Overlapping navigation metadata consumes only its matching invalidation")
    func overlappingNavigationMetadataPreservesNewerInvalidation() async throws {
        let tabID = BrowserTabID()
        let firstURL = try #require(URL(string: "https://first.example"))
        let secondURL = try #require(URL(string: "https://second.example"))
        let thirdURL = try #require(URL(string: "https://third.example"))
        var tab = BrowserTab.web(id: tabID, url: firstURL)
        tab.metadata.committedURL = firstURL
        let store = TestStore(
            initialState: BrowserFeature.State(
                tabs: [tab],
                selectedTabID: tabID,
            ),
        ) { BrowserFeature() } withDependencies: {
            $0.browserWebKit.execute = { _ in }
        }
        store.exhaustivity = .off(showSkippedAssertions: false)

        await store.send(.navigate(secondURL))
        let firstOperationID = try #require(store.state.previewState.operation(for: tabID))
        await store.send(.navigate(thirdURL))
        let secondOperationID = try #require(store.state.previewState.operation(for: tabID))
        let currentRevision = store.state.previewState.revision(for: tabID)

        await store.send(.webKitEvent(.metadata(
            tabID: tabID,
            metadata: .init(committedURL: secondURL),
            correlation: .operation(firstOperationID),
        )))

        #expect(store.state.previewState.operation(for: tabID) == secondOperationID)
        #expect(store.state.previewState.revision(for: tabID) == currentRevision)

        await store.send(.webKitEvent(.metadata(
            tabID: tabID,
            metadata: .init(committedURL: thirdURL),
            correlation: .operation(secondOperationID),
        )))

        #expect(store.state.previewState.operation(for: tabID) == nil)
        #expect(store.state.tabs.first?.metadata.committedURL == thirdURL)
        #expect(store.state.previewState.revision(for: tabID) == currentRevision)
    }

    @Test("Operation identities consume out-of-order WebKit metadata exactly once")
    func operationIdentityPreservesOutOfOrderInvalidation() async throws {
        let tabID = BrowserTabID()
        let firstURL = try #require(URL(string: "https://first.example"))
        let secondURL = try #require(URL(string: "https://second.example"))
        let thirdURL = try #require(URL(string: "https://third.example"))
        var tab = BrowserTab.web(id: tabID, url: firstURL)
        tab.metadata.committedURL = firstURL
        let store = TestStore(
            initialState: BrowserFeature.State(
                tabs: [tab],
                selectedTabID: tabID,
            ),
        ) { BrowserFeature() } withDependencies: {
            $0.browserWebKit.execute = { _ in }
        }
        store.exhaustivity = .off(showSkippedAssertions: false)

        await store.send(.navigate(secondURL))
        let firstOperationID = try #require(store.state.previewState.operation(for: tabID))
        await store.send(.navigate(thirdURL))
        let secondOperationID = try #require(store.state.previewState.operation(for: tabID))

        await store.send(.webKitEvent(.metadata(
            tabID: tabID,
            metadata: .init(committedURL: thirdURL),
            correlation: .operation(secondOperationID),
        )))
        #expect(store.state.previewState.operation(for: tabID) == nil)

        await store.send(.webKitEvent(.metadata(
            tabID: tabID,
            metadata: .init(committedURL: secondURL),
            correlation: .operation(firstOperationID),
        )))
        #expect(store.state.previewState.operation(for: tabID) == nil)
        #expect(store.state.tabs[0].metadata.committedURL == thirdURL)
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
        let reloadOperationID = try #require(store.state.previewState.operation(for: tabID))
        let revisionAfterReload = store.state.previewState.revision(for: tabID)
        await store.send(.webKitEvent(.metadata(
            tabID: tabID,
            metadata: .init(committedURL: firstURL),
            correlation: .operation(reloadOperationID),
        )))
        await store.send(.webKitEvent(.metadata(
            tabID: tabID,
            metadata: .init(committedURL: secondURL),
            correlation: .untracked,
        )))

        #expect(store.state.previewState.revision(for: tabID) != revisionAfterReload)
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
        let refreshOperationID = try #require(store.state.previewState.operation(for: tabID))
        let revisionAfterRefresh = store.state.previewState.revision(for: tabID)
        await store.send(.webKitEvent(.metadata(
            tabID: tabID,
            metadata: .init(committedURL: firstURL),
            correlation: .operation(refreshOperationID),
        )))
        await store.send(.webKitEvent(.metadata(
            tabID: tabID,
            metadata: .init(committedURL: secondURL),
            correlation: .untracked,
        )))

        #expect(store.state.previewState.revision(for: tabID) != revisionAfterRefresh)
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
        state.previewState.setData(.init(
            revision: state.previewState.revision(for: tabID),
            pngData: Data([1]),
        ), for: tabID)
        let oldRevision = state.previewState.revision(for: tabID)
        let store = TestStore(initialState: state) { BrowserFeature() }
        store.exhaustivity = .off(showSkippedAssertions: false)

        await store.send(.webKitEvent(.metadata(
            tabID: tabID,
            metadata: .init(committedURL: secondURL),
            correlation: .untracked,
        )))

        #expect(store.state.previewState.data(for: tabID) == nil)
        #expect(store.state.previewState.revision(for: tabID) != oldRevision)
    }
}
