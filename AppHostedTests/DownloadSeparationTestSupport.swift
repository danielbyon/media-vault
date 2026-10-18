//
//  DownloadSeparationTestSupport.swift
//  MediaVault
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import ComposableArchitecture
import ConcurrencyExtras
import CoreFoundation
import CoreGraphics
import Foundation
import MediaLibrary
import Testing
import UIKit
import VaultFeature
import WebKit
@testable import AppFeature
@testable import BrowserFeature

func makeBrowserDownloadInitialSettings() -> BrowserSettings {
    var settings = BrowserSettings()
    settings.browsingProfile = .ephemeral
    settings.preserveOpenTabs = true
    return settings
}

struct DownloadSeparationTestSupport {
    let webKit: BrowserWebKitClient
    let downloads: BrowserDownloadClient

    /// Owner readiness and reducer projection settlement arrive through separate
    /// asynchronous streams. Completion is observable only after both milestones.
    static func downloadCompletionIsSettled(
        hasReadyRecord: Bool,
        previewOperation: BrowserNavigationOperationID?,
    ) -> Bool {
        hasReadyRecord && previewOperation == nil
    }
}

/// Wraps the real isolated settings storage with a revision-aware observation client.
@MainActor
func makeBrowserDownloadSettingsClient(
    storage: BrowserSettingsStorage,
    gate: BrowserPersistenceRevisionGate,
    writes: LockIsolated<[String]>,
) -> BrowserSettingsClient {
    BrowserSettingsClient(
        load: {
            await storage.load()
        },
        save: { value in
            writes.withValue { $0.append("save") }
            await storage.save(value)
        },
        reset: {
            writes.withValue { $0.append("reset") }
            await storage.reset()
        },
        reserveRevision: { gate.reserve(after: $0) },
        saveRevisioned: { value, revision in
            writes.withValue { $0.append("saveRevisioned:\(revision)") }
            await storage.save(value, revision: revision)
        },
    )
}

/// Wraps the real isolated session storage so tab writes stay observable per revision.
@MainActor
func makeBrowserDownloadSessionClient(
    storage: BrowserOpenTabsSessionStorage,
    gate: BrowserPersistenceRevisionGate,
    writes: LockIsolated<[String]>,
) -> BrowserOpenTabsSessionClient {
    BrowserOpenTabsSessionClient(
        load: { await storage.load() },
        save: { value, revision in
            writes.withValue { $0.append("save:\(revision)") }
            await storage.save(value, revision: revision)
        },
        purge: { revision in
            writes.withValue { $0.append("purge:\(revision)") }
            await storage.purge(revision: revision)
        },
        advance: { revision in
            writes.withValue { $0.append("advance:\(revision)") }
            await storage.advance(revision: revision)
        },
        reserveRevision: { gate.reserve(after: $0) },
    )
}

@MainActor
func makeBrowserDownloadWebKitClients(
    adapter: BrowserWebKitAdapter,
    owner: BrowserDownloadOwner,
) -> DownloadSeparationTestSupport {
    DownloadSeparationTestSupport(
        webKit: BrowserWebKitClient(
            execute: { await adapter.execute($0) },
            events: { await adapter.makeEventStream() },
        ),
        downloads: BrowserDownloadClient(
            execute: { await owner.execute($0) },
            events: { await owner.subscribe() },
        ),
    )
}

extension BrowserDownloadPersistenceFixture {
    /// Waits for an authenticated Root to restore, then commits a real WebKit page.
    func prepare() async throws {
        try await pdfServer.start()
        await settingsStorage.save(initialSettings)
        adapter.execute(.configureProfile(profile: .ephemeral, retiringTabIDs: []))
        mountRoot()

        try await wait("active authenticated Root and completed Browser startup") {
            guard let store = self.rootStore,
                  let window = self.window else {
                return false
            }

            let browser = store.vault.shell.browser
            return window.windowScene?.activationState == .foregroundActive
                && self.owner.snapshot.isAvailable
                && store.vault.phase == .authenticated
                && store.vault.shell.selectedTab == .browser
                && browser.profileLifecycle == .ready
                && browser.openTabsEntryLifecycle == .completed
        }

        // Browser is selected, so an unselected Library view need not receive its appearance
        // task. Dispatch that same real reducer action before taking the persistence baseline.
        let initialReadinessDeadline = Date().addingTimeInterval(10)
        let libraryStore = try #require(rootStore)
        libraryStore.send(.vault(.shell(.library(.task))))
        do {
            try await waitForInitialReadiness("explicit Library startup", deadline: initialReadinessDeadline) {
                self.importRecorder.calls.contains("loadAssets")
                    && self.rootStore?.vault.shell.library.isLoading == false
                    && self.rootStore?.vault.shell.library.error == nil
                    && self.rootStore?.vault.shell.library.assets.isEmpty == true
            }
        } catch {
            reportInitialReadiness(stage: "library", expectedURL: nil)
            throw error
        }

        let url = try pdfServer.url("committed")
        committedURL = url
        navigate(to: url)
        do {
            try await waitForInitialReadiness("initial page commit", deadline: initialReadinessDeadline) {
                guard let store = self.rootStore,
                      let metadata = store.vault.shell.browser.selectedTab?.metadata,
                      let rootView = self.rootController?.viewIfLoaded,
                      let window = self.window,
                      let webView = self.adapter.webView(for: self.tabID) else {
                    return false
                }

                return metadata.committedURL == url
                    && metadata.title == "Browser download committed"
                    && !metadata.isLoading
                    && webView.url == url
                    && !webView.isLoading
                    && webView.window === window
                    && webView.bounds.width > 0
                    && webView.bounds.height > 0
                    && Self.contains(view: webView, in: rootView)
                    && self.adapter.hasCommittedDocument(for: self.tabID)
            }
        } catch {
            reportInitialReadiness(stage: "document", expectedURL: url)
            throw error
        }
    }

    /// Library startup and document readiness consume one shared ten-second budget. Polling and
    /// the final assertion match the fixture's ordinary wait; neither stage starts a new deadline.
    private func waitForInitialReadiness(
        _ description: String,
        deadline: Date,
        until predicate: @MainActor () -> Bool,
    ) async throws {
        while !predicate(), Date() < deadline {
            rootController?.viewIfLoaded?.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(predicate(), "Timed out waiting for \(description)")
    }

    /// Separates setup clauses without recording URLs, asset data, error descriptions or content.
    /// Document comparisons are included only when that stage has an expected fixture URL.
    private func reportInitialReadiness(stage: String, expectedURL: URL?) {
        let store = rootStore
        var fields: [String: String] = [
            "stage": stage,
            "rootStorePresent": String(store != nil),
            "libraryLoadObserved": String(!importRecorder.calls.isEmpty),
            "libraryNotLoading": String(store?.vault.shell.library.isLoading == false),
            "libraryAssetCount": String(store?.vault.shell.library.assets.count ?? -1),
        ]
        if let expectedURL {
            let metadata = store?.vault.shell.browser.selectedTab?.metadata
            let view = adapter.webView(for: tabID)
            let rootView = rootController?.viewIfLoaded
            let descendant: Bool =
                if let view, let rootView {
                    Self.contains(view: view, in: rootView)
                } else {
                    false
                }
            fields.merge([
                "selectedTabPresent": String(metadata != nil),
                "rootViewPresent": String(rootView != nil),
                "windowPresent": String(window != nil),
                "nativeViewPresent": String(view != nil),
                "reducerURLMatches": String(metadata?.committedURL == expectedURL),
                "titleMatches": String(metadata?.title == "Browser download committed"),
                "reducerNotLoading": String(metadata?.isLoading == false),
                "nativeURLMatches": String(view?.url == expectedURL),
                "nativeNotLoading": String(view?.isLoading == false),
                "nativeOwnWindow": String(view != nil && window != nil && view?.window === window),
                "nativeWidth": String(Double(view?.bounds.width ?? 0)),
                "nativeHeight": String(Double(view?.bounds.height ?? 0)),
                "nativeDescendant": String(descendant),
                "nativeCommitted": String(adapter.hasCommittedDocument(for: tabID)),
            ]) { _, new in new }
        }
        if let data = try? JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys]),
           let text = String(data: data, encoding: .utf8) {
            print("SEPARATION_INITIAL_READINESS " + text)
        }
    }

    /// Captures durable baselines after Root startup and the initial committed page.
    func checkpoint() async throws -> PersistenceCheckpoint {
        try await PersistenceCheckpoint(
            settings: settingsStorage.load(),
            defaultsDomain: DefaultsDomainSnapshot(
                domain: defaults.persistentDomain(forName: ownedDefaultsDomainName) ?? [:],
            ),
            settingsWrites: settingsWrites.withValue { $0 },
            sessionWrites: sessionWrites.withValue { $0 },
            sessionData: try? Data(contentsOf: sessionStorage.fileURL),
            sessionOutcome: sessionStorage.load(),
            importFileCalls: importRecorder.importFileCalls,
        )
    }

    /// Navigates through the real reducer and verifies the bytes written by the originating WKWebView.
    func completeDownload(url: URL, bytes: Data, filename: String) async throws -> BrowserDownloadID {
        let oldIDs = owner.snapshot.records.map(\.id)
        navigate(to: url)
        let clock = ContinuousClock()
        var observedReady = false
        var operationAtReady: BrowserNavigationOperationID?
        var operationObservedAt: ContinuousClock.Instant?
        do {
            try await wait("completed \(filename) attachment and preview projection settlement") {
                let hasReadyRecord = self.owner.snapshot.records.contains {
                    !oldIDs.contains($0.id) && $0.isReady
                }
                if hasReadyRecord, !observedReady {
                    observedReady = true
                    operationAtReady = self.previewOperation
                    operationObservedAt = clock.now
                    print(
                        "SEPARATION_PREVIEW_OPERATION_BOUNDARY state="
                            + (operationAtReady.map { "pending:\(String(describing: $0))" } ?? "clear"),
                    )
                }
                return DownloadSeparationTestSupport.downloadCompletionIsSettled(
                    hasReadyRecord: hasReadyRecord,
                    previewOperation: self.previewOperation,
                )
            }
        } catch {
            print(
                "SEPARATION_PREVIEW_OPERATION_TIMEOUT state="
                    + (previewOperation.map { "pending:\(String(describing: $0))" } ?? "clear"),
            )
            throw error
        }
        if let operationAtReady, let operationObservedAt {
            print(
                "SEPARATION_PREVIEW_OPERATION_CLEARED initial=\(String(describing: operationAtReady)) "
                    + "elapsed=\(operationObservedAt.duration(to: clock.now))",
            )
        }

        let record = try #require(owner.snapshot.records.first { !oldIDs.contains($0.id) && $0.isReady })
        #expect(record.filename == filename)
        #expect(record.receivedBytes == Int64(bytes.count))
        let file = scratch.allocation(id: record.id, suggestedName: filename).destination
        #expect(try Data(contentsOf: file) == bytes)
        assertCommittedPagePreserved()
        return record.id
    }

    private var previewOperation: BrowserNavigationOperationID? {
        rootStore?.vault.shell.browser.previewState.operation(for: tabID)
    }

    /// Discards a completed native download and waits for source and reducer cleanup.
    func discard(_ id: BrowserDownloadID, filename: String) async throws {
        let directory = scratch.allocation(id: id, suggestedName: filename).directory
        owner.execute(.init(snapshot: owner.snapshot, action: .discard(id)))
        try await wait("completed download discard and projection cleanup") {
            self.owner.snapshot.records.isEmpty
                && self.owner.retainedCount == 0
                && !FileManager.default.fileExists(atPath: directory.path)
                && self.rootStore?.vault.shell.browser.downloads.records.isEmpty == true
        }
    }

    /// Cancels a real transfer while the server holds its remainder behind the existing network barrier.
    func cancelSlowDownload() async throws {
        try navigate(to: pdfServer.url("slow-known"))
        try await wait("real WebKit progress before cancellation") {
            self.pdfServer.slowPrefixSent && (self.owner.snapshot.records.first?.receivedBytes ?? 0) > 0
        }
        let partial = try #require(owner.snapshot.records.first)
        #expect(!partial.isReady)
        owner.execute(.init(snapshot: owner.snapshot, action: .cancel(partial.id)))
        try await wait("writer acknowledgement and idempotent cancellation cleanup") {
            self.owner.snapshot.records.isEmpty
                && self.owner.activeCount == 0
                && self.owner.retainedCount == 0
                && !self.owner.privacyCleanupPending
                && self.scratchEntries().isEmpty
        }
    }

    /// Remounts Root in-process after downloads are removed and verifies native StartPage restoration.
    /// The native start page does not require an attached WKWebView; this is not a cold process launch.
    func reconstructRoot() async throws {
        let previousTabID = tabID
        unmountRoot()
        adapter.destroyContext(for: previousTabID)
        fixtureTabIDs.remove(previousTabID)
        tabID = BrowserTabID()
        mountRoot()
        try await wait("new Root finishes restoration without an ephemeral web tab") {
            guard let store = self.rootStore,
                  let window = self.window else {
                return false
            }

            let browser = store.vault.shell.browser
            return window.windowScene?.activationState == .foregroundActive
                && store.vault.phase == .authenticated
                && store.vault.shell.selectedTab == .browser
                && browser.profileLifecycle == .ready
                && browser.openTabsEntryLifecycle == .completed
                && browser.tabs.count == 1
                && browser.selectedTab?.content == .startPage
        }

        let store = try #require(rootStore)
        #expect(store.vault.shell.browser.settings.browsingProfile == .ephemeral)
        #expect(store.vault.shell.browser.downloads.records.isEmpty)
        #expect(owner.snapshot.records.isEmpty)
        #expect(owner.activeCount == 0)
        #expect(owner.retainedCount == 0)
        #expect(scratchEntries().isEmpty)
        #expect(sessionStorage.directoryURL
            == rootDirectory.appendingPathComponent("Browser/OpenTabsSession", isDirectory: true))
        try await assertEmptyLibrary()
    }

    /// Checks all owned stores and both ordinary and revisioned clients after each download transition.
    func assertUnchanged(_ baseline: PersistenceCheckpoint) async throws {
        #expect(await settingsStorage.load() == baseline.settings)
        let defaultsDomain = DefaultsDomainSnapshot(
            domain: defaults.persistentDomain(forName: ownedDefaultsDomainName) ?? [:],
        )
        let defaultsDifference = defaultsDomain.difference(from: baseline.defaultsDomain)
        #expect(
            defaultsDifference.isEmpty,
            "Owned defaults domain changed during download transitions: \(defaultsDifference.summary)",
        )
        #expect(settingsWrites.withValue { $0 } == baseline.settingsWrites)
        #expect(sessionWrites.withValue { $0 } == baseline.sessionWrites)
        #expect((try? Data(contentsOf: sessionStorage.fileURL)) == baseline.sessionData)
        #expect(await sessionStorage.load() == baseline.sessionOutcome)
        #expect(importRecorder.importFileCalls == baseline.importFileCalls)
        try await assertEmptyLibrary()
    }

    private func assertCommittedPagePreserved() {
        guard let store = rootStore,
              let committedURL,
              let metadata = store.vault.shell.browser.selectedTab?.metadata
        else {
            Issue.record("The committed Root Browser tab disappeared during a download.")
            return
        }

        #expect(metadata.committedURL == committedURL)
        #expect(metadata.title == "Browser download committed")
        #expect(!metadata.isLoading)
        #expect(adapter.hasCommittedDocument(for: tabID))
        #expect(store.vault.shell.browser.previewState.operation(for: tabID) == nil)
    }

    private func assertEmptyLibrary() async throws {
        #expect(rootStore?.vault.shell.library.assets.isEmpty == true)
    }

    private static func contains(view target: UIView, in root: UIView) -> Bool {
        root === target || root.subviews.contains { contains(view: target, in: $0) }
    }

    func scratchEntries() -> [URL] {
        guard FileManager.default.fileExists(atPath: scratch.root.path) else {
            return []
        }

        return (try? FileManager.default.contentsOfDirectory(at: scratch.root, includingPropertiesForKeys: nil)) ?? []
    }

    private func navigate(to url: URL) {
        rootStore?.send(.vault(.shell(.browser(.navigate(url)))))
    }
}
