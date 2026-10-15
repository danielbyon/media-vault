//
//  Issue42DownloadSeparationFixture.swift
//  MediaVault
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import ComposableArchitecture
import ConcurrencyExtras
import Foundation
import SwiftUI
import Testing
import UIKit
@testable import AppFeature
@testable import BrowserFeature
@testable import MediaLibrary

/// Records every call the application makes through the real import dependency.
///
/// A fixture installs this recorder as the app's media-library dependency so ordinary
/// download work can be proven never to reach the library. Assertions read the ordered
/// transcript of operation names.
final class Issue42DownloadImportRecorder: Sendable {
    private let transcript = LockIsolated<[String]>([])

    /// Ordered names of library operations the application attempted.
    var calls: [String] {
        transcript.value
    }

    /// Import operations the application attempted, in order. Download-separation assertions
    /// read this projection so Library startup work cannot be mistaken for an import.
    var importFileCalls: [String] {
        transcript.value.filter { $0 == "importFile" }
    }

    func record(_ call: String) {
        transcript.withValue { $0.append(call) }
    }
}

/// Runs a real Root composition with isolated app persistence and the shared WebKit adapter.
@MainActor
func withIssue42DownloadSeparationFixture(
    _ body: (Issue42DownloadSeparationFixture) async throws -> Void,
) async throws {
    let fixture = try Issue42DownloadSeparationFixture()
    do {
        try await fixture.prepare()
        try await body(fixture)
    } catch {
        await fixture.remove()
        throw error
    }
    await fixture.remove()
}

/// Owns the Root, real WebKit transfers, and independent persistence stores used by the test.
///
/// The download owner and adapter are fixture instances instead of the process-wide singletons.
/// The shared owner's scratch store demands native file-protection readback, which the simulator
/// cannot provide, so the shared owner can never finish its startup cleanup there. Real WebKit
/// downloads still flow through the production adapter, and the Root download host authorizes
/// the fixture owner through the ordinary scene-registration path.
@MainActor
final class Issue42DownloadSeparationFixture {
    let rootDirectory: URL
    let defaults: UserDefaults
    private let defaultsSuite: String
    let settingsStorage: BrowserSettingsStorage
    let sessionStorage: BrowserOpenTabsSessionStorage
    let settingsGate: BrowserPersistenceRevisionGate
    let sessionGate: BrowserPersistenceRevisionGate
    let settingsWrites = LockIsolated<[String]>([])
    let sessionWrites = LockIsolated<[String]>([])
    let importRecorder = Issue42DownloadImportRecorder()
    let initialSettings: BrowserSettings
    let mediaLibraryClient: MediaLibraryClient
    let browserSettingsClient: BrowserSettingsClient
    let browserSessionClient: BrowserOpenTabsSessionClient
    let webKitClient: BrowserWebKitClient
    let downloadClient: BrowserDownloadClient
    let pdfServer: Issue42LoopbackServer
    let adapter: BrowserWebKitAdapter
    let owner: BrowserDownloadOwner
    let scratch = BrowserDownloadScratchStore(verifyProtection: { url in
        #if !targetEnvironment(simulator)
        try BrowserDownloadScratchStore.verifyNativeProtection(url)
        #endif
    })
    var rootStore: StoreOf<RootFeature>?
    var rootController: UIHostingController<AnyView>?
    var window: UIWindow?
    var coordinator: BrowserDownloadNativeCoordinator?
    var tabID = BrowserTabID()
    var committedURL: URL?
    var fixtureTabIDs: Set<BrowserTabID> = []

    init() throws {
        rootDirectory = FileManager.default
            .temporaryDirectory
            .appendingPathComponent("Issue42DownloadSeparation-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootDirectory, withIntermediateDirectories: true)

        defaultsSuite = "Issue42DownloadSeparation.\(UUID().uuidString)"
        guard let suite = UserDefaults(suiteName: defaultsSuite) else {
            throw FixtureError.defaultsUnavailable
        }

        defaults = suite
        suite.removePersistentDomain(forName: defaultsSuite)

        settingsGate = BrowserPersistenceRevisionGate()
        // The settings actor owns a separate handle to the same isolated defaults domain.
        // The fixture's observation handle remains on the main actor.
        guard let settingsDefaults = UserDefaults(suiteName: defaultsSuite) else {
            throw FixtureError.defaultsUnavailable
        }

        settingsStorage = BrowserSettingsStorage(userDefaults: settingsDefaults, revisionGate: settingsGate)
        sessionGate = BrowserPersistenceRevisionGate()
        sessionStorage = BrowserOpenTabsSessionStorage(
            directoryURL: rootDirectory.appendingPathComponent("Browser/OpenTabsSession", isDirectory: true),
            legacyDirectoryURL: rootDirectory.appendingPathComponent("Browser/Legacy", isDirectory: true),
            revisionGate: sessionGate,
        )

        pdfServer = try Issue42LoopbackServer()

        let fixtureOwner = BrowserDownloadOwner(store: scratch)
        owner = fixtureOwner
        adapter = BrowserWebKitAdapter(requiresProfileConfiguration: true, downloadOwner: fixtureOwner)

        mediaLibraryClient = makeIssue42RecordingMediaLibraryClient(recorder: importRecorder)

        browserSettingsClient = makeIssue42BrowserSettingsClient(
            storage: settingsStorage,
            gate: settingsGate,
            writes: settingsWrites,
        )
        browserSessionClient = makeIssue42BrowserSessionClient(
            storage: sessionStorage,
            gate: sessionGate,
            writes: sessionWrites,
        )

        let browserClients = makeIssue42BrowserWebKitClients(adapter: adapter, owner: owner)
        webKitClient = browserClients.webKit
        downloadClient = browserClients.downloads

        initialSettings = makeIssue42InitialSettings()
    }

    func remove() async {
        owner.invalidateAuthorization()
        unmountRoot()
        destroyFixtureAdapterContexts()
        pdfServer.stop()
        let drained = await waitForOwnedWorkToDrain()
        #expect(
            drained,
            "Fixture teardown waits for shared WebKit writer acknowledgements and scratch cleanup before returning.",
        )
        defaults.removePersistentDomain(forName: defaultsSuite)
        if drained {
            try? FileManager.default.removeItem(at: rootDirectory)
        }
    }

    private func destroyFixtureAdapterContexts() {
        for fixtureTabID in fixtureTabIDs {
            adapter.destroyContext(for: fixtureTabID)
        }
        fixtureTabIDs.removeAll()
    }

    private func waitForOwnedWorkToDrain() async -> Bool {
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            let isDrained = owner.activeCount == 0
                && owner.retainedCount == 0
                && !owner.privacyCleanupPending
                && scratchEntries().isEmpty
            if isDrained {
                return true
            }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return owner.activeCount == 0
            && owner.retainedCount == 0
            && !owner.privacyCleanupPending
            && scratchEntries().isEmpty
    }

    func wait(_ description: String, until predicate: @MainActor () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(10)
        while !predicate(), Date() < deadline {
            rootController?.viewIfLoaded?.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(predicate(), "Timed out waiting for \(description)")
    }

    private enum FixtureError: Error {
        case defaultsUnavailable
    }
}

/// Values captured after startup so setup writes cannot be misattributed to a download.
struct PersistenceCheckpoint: Equatable {
    let settings: BrowserSettings
    let defaults: Data
    let settingsWrites: [String]
    let sessionWrites: [String]
    let sessionData: Data?
    let sessionOutcome: BrowserOpenTabsSessionLoadOutcome
    let importFileCalls: [String]
}

/// Replaces the app's import dependency with a recorder that performs no library work.
///
/// Reads answer with empty results so Library startup reaches its ordinary loaded state.
/// Imports and resource reads record their own name and then fail like an unavailable
/// library, so a caller expecting a successful import cannot silently pass. Recording only
/// the call name keeps the transcript free of source paths and media content.
@MainActor
func makeIssue42RecordingMediaLibraryClient(recorder: Issue42DownloadImportRecorder) -> MediaLibraryClient {
    MediaLibraryClient(
        loadAssets: {
            recorder.record("loadAssets")
            return []
        },
        importFile: { _ in
            recorder.record("importFile")
            throw MediaImportError.persistenceFailed
        },
        resourceData: { _ in
            recorder.record("resourceData")
            throw MediaLibraryStoreError.unavailable
        },
    )
}
