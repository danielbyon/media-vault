//
//  BrowserDownloadRootAdapterTests.swift
//  MediaVault
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import CalculatorFeature
import ComposableArchitecture
import CoreFoundation
import CoreGraphics
import Dependencies
import Foundation
import Sharing
import SwiftUI
import Testing
import UIKit
import VaultFeature
import WebKit
@testable import AppFeature
@testable import BrowserFeature

extension AppHostedUITests {
    /// The command adapter and the Root-mounted browser must own the same native WebKit surface.
    @MainActor
    @Suite(.serialized)
    struct BrowserDownloadRootAdapterTests {
        @Test("Removing a qualification Root leaves another adapter's mounted view attached")
        func removingRootKeepsOtherAdapterAttached() async throws {
            let survivor = try RootAdapterFixture()
            defer { survivor.remove() }
            try await survivor.server.start()
            try await survivor.wait("surviving Root profile configuration") {
                survivor.store.vault.shell.browser.canCreateWebKitContext
            }
            let survivorURL = try survivor.server.url("first")
            survivor.navigate(survivorURL)
            try await survivor.wait("surviving document commit") {
                survivor.documentIsReady(at: survivorURL)
            }
            let survivorTab = try #require(survivor.store.vault.shell.browser.selectedTab)
            let survivorView = try #require(survivor.adapter.webView(for: survivorTab.id))
            do {
                let removed = try RootAdapterFixture()
                defer { removed.remove() }
                try await removed.server.start()
                try await removed.wait("second Root profile configuration") {
                    removed.store.vault.shell.browser.canCreateWebKitContext
                }
                let removedURL = try removed.server.url("first")
                removed.navigate(removedURL)
                try await removed.wait("second document commit") {
                    removed.documentIsReady(at: removedURL)
                }
                let removedTab = try #require(removed.store.vault.shell.browser.selectedTab)
                let removedView = try #require(removed.adapter.webView(for: removedTab.id))
                #expect(removedView !== survivorView)
                #expect(removedView.window === removed.window)
            }
            #expect(survivor.adapter.webView(for: survivorTab.id) === survivorView)
            #expect(survivorView.window === survivor.window)
            #expect(survivorView.isDescendant(of: survivor.root.view))
            #expect(survivorView.bounds.width > 0 && survivorView.bounds.height > 0)
            let ready = try await survivorView.evaluateJavaScript("document.readyState") as? String
            #expect(ready == "complete")
        }

        @Test("Root bridge observations retain a wrong adapter for the fixture tab")
        func scopedObserverDetectsWrongAdapter() async throws {
            let fixture = try RootAdapterFixture(useSeparateHostingAdapter: true)
            defer { fixture.remove() }
            try await fixture.server.start()
            try await fixture.wait("profile configuration for wrong-adapter control") {
                fixture.store.vault.shell.browser.canCreateWebKitContext
            }
            try fixture.navigate(fixture.server.url("first"))
            try await fixture.wait("fixture-tab bridge with a separate hosting adapter") {
                !fixture.bridges.isEmpty
            }
            let actual = try #require(fixture.bridges.last?["adapterIdentity"])
            #expect(actual == String(describing: ObjectIdentifier(fixture.hostingAdapter)))
            #expect(actual != String(describing: ObjectIdentifier(fixture.adapter)))
            #expect(fixture.bridges.allSatisfy {
                $0["tabID"] == fixture.store.vault.shell.browser.selectedTabID.rawValue.uuidString
            })
        }
    }
}

/// Owns a real Root store and its isolated command/event adapter. It never manually attaches WKView.
@MainActor
private final class RootAdapterFixture {
    let server: BrowserDownloadLoopbackServer
    let adapter: BrowserWebKitAdapter
    let hostingAdapter: BrowserWebKitAdapter
    let store: StoreOf<RootFeature>
    let root: UIHostingController<AnyView>
    let window: UIWindow
    private let scratchRoot: URL
    private let observations: RootAdapterObservations
    private var requestedURL: URL?
    private let priorObserver: (@MainActor (String, [String: String]) -> Void)?
    var bridges: [[String: String]] = []
    var registeredSurfaces: [[String: String]] = []

    init(useSeparateHostingAdapter: Bool = false) throws {
        server = try BrowserDownloadLoopbackServer()
        scratchRoot = FileManager.default.temporaryDirectory.appendingPathComponent(
            "browser-download-root-adapter-\(UUID().uuidString)",
            isDirectory: true,
        )
        let downloadOwner = BrowserDownloadOwner(store: BrowserDownloadScratchStore(root: scratchRoot))
        let commandAdapter = BrowserWebKitAdapter(requiresProfileConfiguration: true, downloadOwner: downloadOwner)
        adapter = commandAdapter
        hostingAdapter = useSeparateHostingAdapter
            ? BrowserWebKitAdapter(requiresProfileConfiguration: true, downloadOwner: downloadOwner)
            : commandAdapter
        let recorder = RootAdapterObservations()
        observations = recorder
        commandAdapter.nativeNavigationFailureObserver = { [weak recorder] domain, code in
            recorder?.nativeErrors.append("\(domain):\(code)")
        }
        let coordinator = BrowserDownloadNativeCoordinator(owner: downloadOwner)
        var vault = VaultFeature.State(phase: .authenticated, configuredKind: .pin)
        vault.shell.selectedTab = .browser
        let defaults = try #require(UserDefaults(suiteName: "BrowserDownloadRootAdapter-\(UUID().uuidString)"))
        store = withDependencies {
            $0.uuid = .incrementing
            $0.defaultAppStorage = defaults
            $0.calculatorPersistence.load = { nil }
            $0.calculatorPersistence.save = { _ in }
            $0.vaultCredential = .testValue
            $0.browserSettings.load = {
                var settings = BrowserSettings()
                settings.preserveOpenTabs = false
                return settings
            }
            $0.browserSettings.save = { _ in }
            $0.browserSettings.reset = {}
            $0.browserSettings.reserveRevision = { $0 }
            $0.browserSettings.resetRevisioned = { _ in }
            $0.browserSettings.saveRevisioned = { _, _ in }
            $0.browserLibrary = .testValue
            $0.browserOpenTabsSession.load = { .missing }
            $0.browserOpenTabsSession.save = { _, _ in }
            $0.browserOpenTabsSession.purge = { _ in }
            $0.browserOpenTabsSession.advance = { _ in }
            $0.browserOpenTabsSession.reserveRevision = { $0 }
            $0.browserClipboard.readHTTPURL = { nil }
            $0.browserWebKit = .init(
                execute: { await recorder.execute($0, adapter: commandAdapter) },
                events: { await recorder.stream(commandAdapter) },
            )
            $0.browserDownloads = .init(
                execute: { await downloadOwner.execute($0) },
                events: { await downloadOwner.subscribe() },
            )
        } operation: {
            RootComposition.makeStore(vault: vault)
        }
        root = UIHostingController(rootView: AnyView(RootView(
            store: store,
            downloads: .init(execute: { await downloadOwner.execute($0) }, events: { await downloadOwner.subscribe() }),
            privacyGeneration: { downloadOwner.snapshot.generation },
            downloadHost: { $0.using(coordinator: coordinator) },
        ).environment(\.qualificationBrowserHostingContext, BrowserQualificationWebKitHostingContext(
            adapter: hostingAdapter,
        ))))
        window = UIKitTestSupport.makeWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        priorObserver = BrowserTabTransitionDiagnostics.qualificationObserver
        BrowserTabTransitionDiagnostics.qualificationObserver = { [weak self] event, fields in
            // Filter by ownership, never by the expected adapter: a wrong adapter for this tab
            // must remain observable so the identity regression cannot become a false green.
            guard let self,
                  fields["tabID"] == store.vault.shell.browser.selectedTabID.rawValue.uuidString
            else {
                return
            }

            if event == "mountedWebKitBridge" {
                bridges.append(fields)
            }
            if event == "mountedWebKitSurface" {
                registeredSurfaces.append(fields)
            }
        }
        window.rootViewController = root
        window.makeKeyAndVisible()
        root.view.layoutIfNeeded()
    }

    /// Drives the same reducer command while retaining only the fixture destination for comparisons.
    func navigate(_ url: URL) {
        requestedURL = url
        store.send(.vault(.shell(.browser(.navigate(url)))))
    }

    /// A committed URL alone precedes document completion and native attachment.
    func documentIsReady(at url: URL) -> Bool {
        guard let tab = store.vault.shell.browser.selectedTab,
              let view = adapter.webView(for: tab.id)
        else {
            return false
        }

        return tab.metadata.committedURL == url && !tab.metadata.isLoading
            && !view.isLoading && view.window === window
            && adapter.hasCommittedDocument(for: tab.id)
    }

    /// Captures distinct transport, native and reducer milestones without logging URLs or content.
    private func failureWitness() -> String {
        let browser = store.vault.shell.browser
        let tab = browser.selectedTab
        let view = tab.flatMap { adapter.webView(for: $0.id) }
        let operation = tab.flatMap { browser.previewState.operation(for: $0.id) }
        let fields: [String: String] = [
            "subscribed": String(observations.subscribed),
            "loads": observations.loadEvidence(expectedURL: requestedURL),
            "events": observations.eventEvidence(expectedURL: requestedURL),
            "nativeErrors": observations.nativeErrors.joined(separator: ","),
            "serverReady": String(server.ready),
            "serverStopped": String(server.stopped),
            "acceptedConnections": String(server.acceptedCount),
            "requestCount": String(server.requests.count),
            "connectionEvidence": connectionEvidence(),
            "requestRoutes": server.requests
                .map { $0.path.split(separator: "/").last.map(String.init) ?? "none" }
                .joined(separator: ","),
            "profileReady": String(adapter.profileIsConfigured),
            "selectedTab": tab?.id.rawValue.uuidString ?? "none",
            "pendingOperation": String(describing: operation),
            "pendingWebAction": String(browser.pendingWebAction != nil),
            "reducerURLMatches": String(requestedURL != nil && tab?.metadata.committedURL == requestedURL),
            "reducerTitleMatches": String(tab?.metadata.title == "Browser download first"),
            "reducerLoading": String(describing: tab?.metadata.isLoading),
            "nativeCommitted": String(tab.map { adapter.hasCommittedDocument(for: $0.id) } ?? false),
            "nativeURLMatches": String(requestedURL != nil && view?.url == requestedURL),
            "nativeLoading": String(describing: view?.isLoading),
            "nativeDelegateAttached": String(view?.navigationDelegate != nil),
            "nativeUIDelegateAttached": String(view?.uiDelegate != nil),
            "nativeOwnWindow": String(view != nil && view?.window === window),
            "nativeBounds": String(describing: view?.bounds),
            "rootOwnWindow": String(root.view.window === window),
            "sceneState": String(describing: window.windowScene?.activationState.rawValue),
            "bridgeCount": String(bridges.count),
            "registeredSurfaceCount": String(registeredSurfaces.count),
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8)
        else {
            return "witness serialization failed"
        }

        return text
    }

    private func connectionEvidence() -> String {
        guard let data = try? JSONSerialization.data(
            withJSONObject: server.connectionEvidence,
            options: [.sortedKeys],
        ), let text = String(data: data, encoding: .utf8) else {
            return "transport evidence serialization failed"
        }

        return text
    }

    func wait(_ milestone: String, until predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(10)
        while !predicate(), Date() < deadline {
            root.view.layoutIfNeeded()
            await Task.yield()
        }
        let passed = predicate()
        let witness = passed ? "" : failureWitness()
        if !passed {
            print("ROOT_ADAPTER_FAILURE_WITNESS " + milestone + " " + witness)
        }
        try #require(passed, Comment(rawValue: "Timed out: " + milestone + " " + witness))
    }

    func remove() {
        window.isHidden = true
        window.rootViewController = nil
        BrowserTabTransitionDiagnostics.qualificationObserver = priorObserver
        for tab in store.vault.shell.browser.tabs {
            adapter.destroyContext(for: tab.id)
            if hostingAdapter !== adapter {
                hostingAdapter.destroyContext(for: tab.id)
            }
        }
        adapter.nativeNavigationFailureObserver = nil
        server.stop()
        // This fixture starts navigation only, never a download or native writer.
        try? FileManager.default.removeItem(at: scratchRoot)
    }
}

/// Pass-through recording at the dependency boundary; every command and event still reaches its
/// original consumer. Bounded retained evidence excludes destination URLs and page content.
@MainActor
private final class RootAdapterObservations {
    private var commands: [BrowserWebKitCommand] = []
    private var events: [BrowserWebKitEvent] = []
    private(set) var subscribed = false
    var nativeErrors: [String] = []

    func execute(_ command: BrowserWebKitCommand, adapter: BrowserWebKitAdapter) {
        if commands.count < 64 {
            commands.append(command)
        }
        adapter.execute(command)
    }

    func stream(_ adapter: BrowserWebKitAdapter) -> AsyncStream<BrowserWebKitEvent> {
        let upstream = adapter.makeEventStream()
        subscribed = true
        return AsyncStream { continuation in
            let pump = Task { @MainActor in
                for await event in upstream {
                    if self.events.count < 128 {
                        self.events.append(event)
                    }
                    continuation.yield(event)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in pump.cancel() }
        }
    }

    func loadEvidence(expectedURL: URL?) -> String {
        commands.compactMap { command in
            guard case let .load(tabID, url, operationID) = command else {
                return nil
            }

            return "tab=\(tabID.rawValue.uuidString) op=\(operationID) expectedURL=\(url == expectedURL)"
        }
        .joined(separator: ";")
    }

    func eventEvidence(expectedURL: URL?) -> String {
        events.map { event in
            switch event {
            case let .navigationCommitted(tabID, metadata, correlation):
                metadataEvidence(
                    "commit",
                    tabID: tabID,
                    metadata: metadata,
                    correlation: correlation,
                    expectedURL: expectedURL,
                )
            case let .metadata(tabID, metadata, correlation):
                metadataEvidence(
                    "metadata",
                    tabID: tabID,
                    metadata: metadata,
                    correlation: correlation,
                    expectedURL: expectedURL,
                )
            case let .navigationFailed(tabID, _, correlation):
                "failure tab=\(tabID.rawValue.uuidString) correlation=\(correlation)"
            case let .processTerminated(tabID):
                "terminated tab=\(tabID.rawValue.uuidString)"
            default:
                "other"
            }
        }
        .joined(separator: ";")
    }

    private func metadataEvidence(
        _ kind: String,
        tabID: BrowserTabID,
        metadata: BrowserTab.Metadata,
        correlation: BrowserWebKitEventCorrelation,
        expectedURL: URL?,
    ) -> String {
        "\(kind) tab=\(tabID.rawValue.uuidString) correlation=\(correlation) "
            + "expectedURL=\(metadata.committedURL == expectedURL) "
            + "expectedTitle=\(metadata.title == "Browser download first") loading=\(metadata.isLoading)"
    }
}
