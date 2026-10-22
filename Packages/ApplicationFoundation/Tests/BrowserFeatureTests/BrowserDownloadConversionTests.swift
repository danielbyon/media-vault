//
//  BrowserDownloadConversionTests.swift
//  MediaVault
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import ComposableArchitecture
import Foundation
import ObjectiveC
import Testing
@testable import BrowserFeature

@Suite("Browser download navigation conversion")
@MainActor
struct BrowserDownloadConversionTests {
    @Test("Displayable attachments download while ordinary inline PDFs remain page navigations")
    func attachmentClassificationPreservesInlineDocuments() {
        #expect(BrowserWebKitDownloadPolicy.responseRequiresDownload(
            canShowMIMEType: true,
            contentDisposition: " attachment ; filename=report.pdf",
        ))
        #expect(!BrowserWebKitDownloadPolicy.responseRequiresDownload(
            canShowMIMEType: true,
            contentDisposition: "inline; filename=report.pdf",
        ))
        #expect(!BrowserWebKitDownloadPolicy.responseRequiresDownload(
            canShowMIMEType: true,
            contentDisposition: nil,
        ))
        #expect(BrowserWebKitDownloadPolicy.responseRequiresDownload(
            canShowMIMEType: false,
            contentDisposition: "inline",
        ))
        #expect(!BrowserWebKitDownloadPolicy.responseRequiresDownload(
            canShowMIMEType: true,
            contentDisposition: "attachment-extra",
        ))
    }

    @Test("Conversion settles during command registration without didFinish or duplicate completion")
    func registrationWindowConversionSettlesExactlyOnce() throws {
        let epoch = BrowserWebKitMetadataEpochStore()
        var correlation = BrowserWebKitNavigationCorrelation(metadataEpoch: epoch)
        let acceptedNavigation = correlation.acceptExternalNavigation(nil)
        #expect(acceptedNavigation)
        let committedNavigation = correlation.commit(nil)
        #expect(committedNavigation)
        _ = correlation.finish(nil)
        let operation = BrowserNavigationOperationID()
        correlation.beginNavigation(operationID: operation)
        let capture = correlation.captureDownloadConversion()
        let capturedEpoch = epoch.snapshot()
        #expect(capture.operationID == operation)
        #expect(!correlation.acceptsMetadataObservations)
        let conversionCompletion = correlation.settleDownloadConversion(capture)
        let completion = try #require(conversionCompletion)
        #expect(completion.operationID == operation)
        #expect(correlation.hasCommittedDocument)
        #expect(epoch.snapshot().generation != capturedEpoch.generation)
        #expect(epoch.snapshot().operationID == nil)
        let registeredNavigation = correlation.register(nil, operationID: operation)
        #expect(registeredNavigation)
        #expect(correlation.hasCommittedDocument)
        let conversionCompletion2 = correlation.settleDownloadConversion(capture)
        #expect(conversionCompletion2 == nil)
        let navigationCompletion = correlation.finish(nil)
        #expect(navigationCompletion == nil)
        #expect(!correlation.isCurrent(nil))
        #expect(correlation.acceptsMetadataObservations)
    }

    @Test("A distinct external start supersedes a pending conversion without retiring the new navigation")
    func externalStartBeforeDelayedHandoffOwnsNewGeneration() {
        var correlation = BrowserWebKitNavigationCorrelation()
        // Correlation needs two distinct reference identities, not native navigation instances.
        let first = NSObject()
        let second = NSObject()
        let acceptedNavigation = correlation.acceptExternalNavigation(first)
        #expect(acceptedNavigation)
        let capture = correlation.captureDownloadConversion()
        let acceptedNavigation2 = correlation.acceptExternalNavigation(first)
        #expect(!acceptedNavigation2)
        let acceptedNavigation3 = correlation.acceptExternalNavigation(second)
        #expect(acceptedNavigation3)
        let conversionCompletion = correlation.settleDownloadConversion(capture)
        #expect(conversionCompletion == nil)
        #expect(!correlation.isCurrent(first))
        // Context discards superseded references after rejected delegate callbacks. Converted
        // identities must remain retired even through that bookkeeping path.
        correlation.discardSupersededNavigation(first)
        #expect(correlation.isCurrent(second))
        let acceptedNavigation4 = correlation.acceptExternalNavigation(first)
        #expect(!acceptedNavigation4)
        let committedNavigation = correlation.commit(second)
        #expect(committedNavigation)
        let navigationCompletion = correlation.finish(second)
        #expect(navigationCompletion != nil)
    }

    @Test("Nil registration after policy capture cannot complete a conversion as a history no-op")
    func pendingConversionSuppressesNilRegistrationCompletion() throws {
        var correlation = BrowserWebKitNavigationCorrelation()
        let operation = BrowserNavigationOperationID()
        correlation.beginNavigation(operationID: operation)
        let capture = correlation.captureDownloadConversion()
        let registeredNavigation = correlation.register(nil, operationID: operation)
        #expect(registeredNavigation)
        #expect(!correlation.acceptsMetadataObservations)
        let navigationCompletion = correlation.finish(nil)
        #expect(navigationCompletion == nil)
        let conversionCompletion = correlation.settleDownloadConversion(capture)
        #expect(try #require(conversionCompletion).operationID == operation)
        let conversionCompletion2 = correlation.settleDownloadConversion(capture)
        #expect(conversionCompletion2 == nil)
    }

    @Test("Settlement accepts fresh title and history observations but rejects queued conversion metadata")
    func settlementReopensMetadataUnderFreshEpoch() throws {
        let epoch = BrowserWebKitMetadataEpochStore()
        var correlation = BrowserWebKitNavigationCorrelation(metadataEpoch: epoch)
        let acceptedNavigation = correlation.acceptExternalNavigation(nil)
        #expect(acceptedNavigation)
        let committedNavigation = correlation.commit(nil)
        #expect(committedNavigation)
        _ = correlation.finish(nil)
        let acceptedNavigation2 = correlation.acceptExternalNavigation(nil)
        #expect(acceptedNavigation2)
        let capture = correlation.captureDownloadConversion()
        let oldEpoch = epoch.snapshot()
        #expect(!correlation.acceptsMetadataObservation(oldEpoch))
        let conversionCompletion = correlation.settleDownloadConversion(capture)
        _ = try #require(conversionCompletion)
        #expect(!correlation.acceptsMetadataObservation(oldEpoch))
        #expect(correlation.acceptsMetadataObservation(epoch.snapshot()))
        #expect(epoch.snapshot().operationID == nil)
    }

    @Test("A late handoff cannot consume a newer navigation or its metadata epoch")
    func oldConversionCannotSettleNewerOperation() throws {
        let epoch = BrowserWebKitMetadataEpochStore()
        var correlation = BrowserWebKitNavigationCorrelation(metadataEpoch: epoch)
        let first = BrowserNavigationOperationID()
        let second = BrowserNavigationOperationID()
        correlation.beginNavigation(operationID: first)
        let firstCapture = correlation.captureDownloadConversion()
        correlation.beginNavigation(operationID: second)
        let secondEpoch = epoch.snapshot()
        let conversionCompletion = correlation.settleDownloadConversion(firstCapture)
        #expect(conversionCompletion == nil)
        #expect(correlation.currentOperationID() == second)
        #expect(correlation.generation == secondEpoch.generation)
        #expect(correlation.acceptsMetadataObservations)
        let secondCapture = correlation.captureDownloadConversion()
        let conversionCompletion2 = correlation.settleDownloadConversion(secondCapture)
        #expect(try #require(conversionCompletion2).operationID == second)
        #expect(!correlation.hasCommittedDocument)
    }

    @Test("External conversion restores readiness only when a page was previously committed", arguments: [false, true])
    func externalConversionRestoresPriorReadiness(hadPage: Bool) throws {
        var correlation = BrowserWebKitNavigationCorrelation()
        if hadPage {
            let acceptedNavigation = correlation.acceptExternalNavigation(nil)
            #expect(acceptedNavigation)
            let committedNavigation = correlation.commit(nil)
            #expect(committedNavigation)
            _ = correlation.finish(nil)
        }
        let acceptedNavigation2 = correlation.acceptExternalNavigation(nil)
        #expect(acceptedNavigation2)
        let capture = correlation.captureDownloadConversion()
        let conversionCompletion = correlation.settleDownloadConversion(capture)
        #expect(try #require(conversionCompletion).operationID == nil)
        #expect(correlation.hasCommittedDocument == hadPage)
        let navigationCompletion = correlation.finish(nil)
        #expect(navigationCompletion == nil)
        correlation.processTerminated()
        #expect(!correlation.hasCommittedDocument)
        let conversionCompletion2 = correlation.settleDownloadConversion(capture)
        #expect(conversionCompletion2 == nil)
    }

    @Test("Conversion preserves committed metadata and rejects duplicate, error, metadata, and preview callbacks")
    func reducerConversionPreservesPageAndRevision() async throws {
        let id = BrowserTabID()
        let page = try #require(URL(string: "https://example.test/page"))
        let file = try #require(URL(string: "https://example.test/file.pdf"))
        var tab = BrowserTab.web(id: id, url: page)
        tab.metadata = .init(committedURL: page, title: "Committed page", canGoBack: true, canGoForward: true)
        let store = TestStore(initialState: BrowserFeature.State.readyForTesting(
            tabs: [tab],
            selectedTabID: id,
        )) { BrowserFeature() }
        store.exhaustivity = .off(showSkippedAssertions: false)
        let previousRevision = store.state.previewState.revision(for: id)
        await store.send(.navigate(file))
        let operation = try #require(store.state.previewState.operation(for: id))
        let revision = store.state.previewState.revision(for: id)
        #expect(revision != previousRevision)
        await store.send(.webKitEvent(.metadata(
            tabID: id,
            metadata: .init(committedURL: page, isLoading: true, estimatedProgress: 0.4),
            correlation: .operation(operation),
        )))
        await store.send(.webKitEvent(.navigationConvertedToDownload(tabID: id, correlation: .operation(operation))))
        #expect(store.state.tabs[0] == tab)
        #expect(store.state.previewState.operation(for: id) == nil)
        #expect(store.state.previewState.revision(for: id) == revision)
        let settledState = store.state
        await store.send(.webKitEvent(.navigationConvertedToDownload(tabID: id, correlation: .operation(operation))))
        await store.send(.webKitEvent(.navigationFailed(
            tabID: id,
            error: .connectionFailed(file),
            correlation: .operation(operation),
        )))
        await store.send(.webKitEvent(.metadata(
            tabID: id,
            metadata: .init(committedURL: file),
            correlation: .operation(operation),
        )))
        await store.send(.webKitEvent(.preview(tabID: id, revision: previousRevision, pngData: Data([1]))))
        #expect(store.state == settledState)
        await store.send(.webKitEvent(.preview(tabID: id, revision: revision, pngData: Data([2]))))
        #expect(store.state.previewState.data(for: id)?.pngData == Data([2]))
    }

    @Test("A download restores the confirmed loading commit, including a same-URL reload", arguments: [false, true])
    func conversionAfterLoadingCommitRestoresNewDocument(sameURL: Bool) async throws {
        let id = BrowserTabID()
        let first = try #require(URL(string: "https://example.test/a"))
        let second = try #require(URL(string: "https://example.test/b"))
        let file = try #require(URL(string: "https://example.test/c.pdf"))
        let store = TestStore(initialState: BrowserFeature.State.readyForTesting(
            tabs: [.web(id: id, url: first)],
            selectedTabID: id,
        )) { BrowserFeature() }
        store.exhaustivity = .off(showSkippedAssertions: false)
        let committedURL = sameURL ? first : second
        if sameURL {
            await store.send(.reloadOrStopTapped)
        } else {
            await store.send(.navigate(second))
        }
        let secondOperation = try #require(store.state.previewState.operation(for: id))
        let committed = BrowserTab.Metadata(
            committedURL: committedURL,
            title: "Fresh committed title",
            isLoading: true,
            estimatedProgress: 0.6,
            canGoBack: true,
        )
        let revision = store.state.previewState.revision(for: id)
        await store.send(.webKitEvent(.navigationCommitted(
            tabID: id,
            metadata: committed,
            correlation: .operation(secondOperation),
        )))
        #expect(store.state.previewState.operation(for: id) == secondOperation)
        #expect(store.state.previewState.revision(for: id) == revision)
        await store.send(.navigate(file))
        let fileOperation = try #require(store.state.previewState.operation(for: id))
        await store.send(.webKitEvent(.navigationConvertedToDownload(
            tabID: id,
            correlation: .operation(fileOperation),
        )))
        var expected = committed
        expected.isLoading = false
        expected.estimatedProgress = 0
        #expect(store.state.tabs[0].metadata == expected)
        #expect(store.state.tabs[0].content == .web(requestedURL: committedURL))
        #expect(store.state.previewState.operation(for: id) == nil)
    }

    @Test("Provisional metadata and an older commit cannot replace the conversion recovery owner")
    func onlyMatchingConfirmedCommitAdvancesOrigin() async throws {
        let id = BrowserTabID()
        let page = try #require(URL(string: "https://example.test/page"))
        let provisional = try #require(URL(string: "https://example.test/provisional"))
        let file = try #require(URL(string: "https://example.test/file.pdf"))
        let original = BrowserTab.web(id: id, url: page)
        let store = TestStore(initialState: BrowserFeature.State.readyForTesting(
            tabs: [original],
            selectedTabID: id,
        )) { BrowserFeature() }
        store.exhaustivity = .off(showSkippedAssertions: false)
        await store.send(.navigate(provisional))
        let oldOperation = try #require(store.state.previewState.operation(for: id))
        let metadata = BrowserTab.Metadata(committedURL: provisional, title: "Provisional", isLoading: true)
        await store.send(.webKitEvent(.metadata(
            tabID: id,
            metadata: metadata,
            correlation: .operation(oldOperation),
        )))
        #expect(store.state.previewState.navigationOrigin(for: id) == original)
        await store.send(.navigate(file))
        let operation = try #require(store.state.previewState.operation(for: id))
        let pending = store.state
        await store.send(.webKitEvent(.navigationCommitted(
            tabID: id,
            metadata: metadata,
            correlation: .operation(oldOperation),
        )))
        await store.send(.webKitEvent(.navigationCommitted(
            tabID: id,
            metadata: metadata,
            correlation: .untracked,
        )))
        #expect(store.state == pending)
        await store.send(.webKitEvent(.navigationConvertedToDownload(tabID: id, correlation: .operation(operation))))
        #expect(store.state.tabs[0] == original)
    }

    @Test("Fresh title and same-document history metadata remain usable after conversion")
    func freshMetadataUpdatesRestoredDocument() async throws {
        let id = BrowserTabID()
        let page = try #require(URL(string: "https://example.test/page"))
        let history = try #require(URL(string: "https://example.test/page#section"))
        let store = TestStore(initialState: BrowserFeature.State.readyForTesting(
            tabs: [.web(id: id, url: page)],
            selectedTabID: id,
        )) { BrowserFeature() }
        store.exhaustivity = .off(showSkippedAssertions: false)
        await store.send(.webKitEvent(.navigationStarted(tabID: id)))
        await store.send(.webKitEvent(.navigationConvertedToDownload(tabID: id, correlation: .untracked)))
        await store.send(.webKitEvent(.metadata(
            tabID: id,
            metadata: .init(committedURL: page, title: "Updated title"),
            correlation: .untracked,
        )))
        #expect(store.state.tabs[0].metadata.title == "Updated title")
        await store.send(.webKitEvent(.metadata(
            tabID: id,
            metadata: .init(committedURL: history, title: "History title", canGoBack: true),
            correlation: .untracked,
        )))
        #expect(store.state.tabs[0].metadata.committedURL == history)
        #expect(store.state.tabs[0].metadata.title == "History title")
        #expect(store.state.tabs[0].metadata.canGoBack)
    }

    @Test("Conversion restores native Start Page and cannot finish a newer reducer navigation")
    func reducerConversionRestoresNativeAndProtectsNewerOperation() async throws {
        let id = BrowserTabID()
        let first = try #require(URL(string: "https://example.test/first"))
        let second = try #require(URL(string: "https://example.test/second"))
        let store = TestStore(initialState: BrowserFeature.State.readyForTesting(
            tabs: [.startPage(id: id)],
            selectedTabID: id,
        )) { BrowserFeature() }
        store.exhaustivity = .off(showSkippedAssertions: false)
        await store.send(.navigate(first))
        let firstOperation = try #require(store.state.previewState.operation(for: id))
        await store.send(.navigate(second))
        let secondOperation = try #require(store.state.previewState.operation(for: id))
        let pending = store.state
        await store.send(.webKitEvent(.navigationConvertedToDownload(
            tabID: id,
            correlation: .operation(firstOperation),
        )))
        await store.send(.webKitEvent(.navigationConvertedToDownload(tabID: id, correlation: .untracked)))
        #expect(store.state == pending)
        await store.send(.webKitEvent(.navigationConvertedToDownload(
            tabID: id,
            correlation: .operation(secondOperation),
        )))
        #expect(store.state.tabs[0].isStartPage)
        #expect(store.state.previewState.operation(for: id) == nil)
        #expect(!store.state.tabs[0].metadata.isLoading)
    }

    @Test("External conversion is idempotent and preserves the already committed page")
    func externalReducerConversionPreservesPage() async throws {
        let id = BrowserTabID()
        let url = try #require(URL(string: "https://example.test/page"))
        var tab = BrowserTab.web(id: id, url: url)
        tab.metadata = .init(committedURL: url, title: "Page", canGoBack: true)
        let store = TestStore(initialState: BrowserFeature.State.readyForTesting(
            tabs: [tab],
            selectedTabID: id,
        )) { BrowserFeature() }
        store.exhaustivity = .off(showSkippedAssertions: false)
        await store.send(.webKitEvent(.navigationStarted(tabID: id)))
        let revision = store.state.previewState.revision(for: id)
        await store.send(.webKitEvent(.navigationConvertedToDownload(tabID: id, correlation: .untracked)))
        #expect(store.state.tabs[0] == tab)
        #expect(store.state.previewState.revision(for: id) == revision)
        let settled = store.state
        await store.send(.webKitEvent(.navigationConvertedToDownload(tabID: id, correlation: .untracked)))
        #expect(store.state == settled)
    }
}
