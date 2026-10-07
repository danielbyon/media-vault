//
//  AppHostedBrowserProfileTests.swift
//  MediaVault
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import ComposableArchitecture
import ConcurrencyExtras
import CoreFoundation
import CoreGraphics
import Dependencies
import Foundation
import SwiftUI
import Testing
import UIKit
@testable import BrowserFeature

@Suite("Browser profile transitions (window hosted)")
@MainActor
struct AppHostedBrowserProfileTests {
    @Test("Settings initialization survives dismissal and reopening")
    func settingsInitializationSurvivesDismissalAndReopening() async {
        let gate = BrowserProfileConfigurationGate()
        let adapter = BrowserWebKitAdapter(requiresProfileConfiguration: true)
        let fixture = BrowserProfileWebKitFixture(adapter: adapter, gate: gate)
        let persistedSettings = BrowserSettings(browsingProfile: .ephemeral)
        let sessionLoadCount = LockIsolated(0)
        let store = Store(initialState: BrowserFeature.State()) {
            BrowserFeature()
        } withDependencies: {
            $0.uuid = .incrementing
            $0.browserSettings.load = { persistedSettings }
            $0.browserLibrary.loadBookmarks = { [] }
            $0.browserLibrary.loadHistory = { [] }
            $0.browserOpenTabsSession.load = {
                sessionLoadCount.withValue { $0 += 1 }
                return .missing
            }
            $0.browserWebKit = BrowserWebKitClient(
                execute: { command in await fixture.execute(command) },
                events: { AsyncStream { $0.finish() } },
            )
        }
        let firstPresentation = BrowserLifecycleReadinessObserver()
        let firstController = UIHostingController(
            rootView: BrowserSettingsReadinessProbe(store: store, readiness: firstPresentation),
        )
        let window = UIKitTestSupport.makeWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = firstController
        window.makeKeyAndVisible()
        firstController.view.frame = window.bounds
        firstController.view.layoutIfNeeded()
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }

        #expect(await gate.waitUntilStarted() == .ephemeral)
        #expect(!store.state.canCreateWebKitContext)
        #expect(await gate.requestedProfiles() == [.ephemeral])

        window.isHidden = true
        window.rootViewController = nil
        #expect(await firstPresentation.waitUntilDismissed(timeout: .seconds(1)))

        let reopenedPresentation = BrowserLifecycleReadinessObserver()
        let reopenedController = UIHostingController(
            rootView: BrowserSettingsReadinessProbe(store: store, readiness: reopenedPresentation),
        )
        window.rootViewController = reopenedController
        window.isHidden = false
        window.makeKeyAndVisible()
        reopenedController.view.frame = window.bounds
        reopenedController.view.layoutIfNeeded()
        #expect(await gate.requestedProfiles() == [.ephemeral])

        await gate.release()
        #expect(await reopenedPresentation.waitUntilReady(timeout: .seconds(1)))

        #expect(store.state.canCreateWebKitContext)
        #expect(store.state.settings.browsingProfile == .ephemeral)
        #expect(sessionLoadCount.value == 0)
    }

    @Test("Mounting authenticated Browser restores the selected tab and leaves background tabs lazy")
    func browserMountRestoresSelectedTabAfterEntry() async throws {
        let backgroundURL = try #require(URL(string: "https://background.example"))
        let selectedURL = try #require(URL(string: "https://selected.example"))
        let session = BrowserOpenTabsSession(
            selectedPosition: 1,
            entries: [
                .init(position: 0, kind: .web(backgroundURL)),
                .init(position: 1, kind: .web(selectedURL)),
            ],
        )
        let data = try session.encoded()
        let loadCount = LockIsolated(0)
        let commands = LockIsolated<[BrowserWebKitCommand]>([])
        let store = withDependencies {
            $0.uuid = .incrementing
            $0.browserOpenTabsSession.load = {
                loadCount.withValue { $0 += 1 }
                return .loaded(data)
            }
            $0.browserWebKit = BrowserWebKitClient(
                execute: { command in commands.withValue { $0.append(command) } },
                events: { AsyncStream { $0.finish() } },
            )
        } operation: {
            Store(initialState: BrowserFeature.State.readyForTesting()) {
                BrowserFeature()
            }
        }
        let readiness = BrowserLifecycleReadinessObserver()
        let controller = UIHostingController(
            rootView: BrowserEntryReadinessProbe(store: store, readiness: readiness),
        )
        let window = UIKitTestSupport.makeWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = controller
        window.makeKeyAndVisible()
        controller.view.frame = window.bounds
        controller.view.layoutIfNeeded()
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }

        #expect(await readiness.waitUntilReady(timeout: .seconds(3)))

        let state = store.state
        #expect(loadCount.value == 1)
        #expect(state.openTabsEntryLifecycle == .completed)
        #expect(state.tabs.count == 2)
        #expect(state.selectedTabID == state.tabs[1].id)
        #expect(state.lazyRestoredWebTabURLs[state.tabs[0].id] == backgroundURL)
        #expect(await waitForLoadCommand(selectedURL, in: commands))
        let loadedURLs = commands.value.compactMap { command -> URL? in
            if case let .load(_, url, _) = command {
                return url
            }
            return nil
        }
        #expect(loadedURLs == [selectedURL])
    }
}

private func waitForLoadCommand(
    _ expectedURL: URL,
    in commands: LockIsolated<[BrowserWebKitCommand]>,
) async -> Bool {
    for _ in 0 ..< 200 {
        if commands.value.contains(where: { command in
            guard case let .load(_, url, _) = command else {
                return false
            }

            return url == expectedURL
        }) {
            return true
        }

        try? await Task.sleep(for: .milliseconds(10))
    }

    return commands.value.contains(where: { command in
        guard case let .load(_, url, _) = command else {
            return false
        }

        return url == expectedURL
    })
}

@MainActor
private final class BrowserLifecycleReadinessObserver {
    private var isReady = false
    private var isDismissed = false
    private var readinessContinuation: CheckedContinuation<Bool, Never>?
    private var dismissalContinuation: CheckedContinuation<Bool, Never>?
    private var readinessTimeout: Task<Void, Never>?
    private var dismissalTimeout: Task<Void, Never>?

    func waitUntilReady(timeout: Duration) async -> Bool {
        guard !isReady else {
            return true
        }

        return await withCheckedContinuation { continuation in
            readinessContinuation = continuation
            readinessTimeout = Task { @MainActor [weak self] in
                do {
                    try await Task.sleep(for: timeout)
                } catch {
                    return
                }

                self?.finishReadinessWait(result: false)
            }
        }
    }

    func waitUntilDismissed(timeout: Duration) async -> Bool {
        guard !isDismissed else {
            return true
        }

        return await withCheckedContinuation { continuation in
            dismissalContinuation = continuation
            dismissalTimeout = Task { @MainActor [weak self] in
                do {
                    try await Task.sleep(for: timeout)
                } catch {
                    return
                }

                self?.finishDismissalWait(result: false)
            }
        }
    }

    func markReady() {
        isReady = true
        finishReadinessWait(result: true)
    }

    func markDismissed() {
        isDismissed = true
        finishDismissalWait(result: true)
    }

    private func finishReadinessWait(result: Bool) {
        readinessTimeout?.cancel()
        readinessTimeout = nil
        readinessContinuation?.resume(returning: result)
        readinessContinuation = nil
    }

    private func finishDismissalWait(result: Bool) {
        dismissalTimeout?.cancel()
        dismissalTimeout = nil
        dismissalContinuation?.resume(returning: result)
        dismissalContinuation = nil
    }
}

@MainActor
private struct BrowserSettingsReadinessProbe: View {
    let store: StoreOf<BrowserFeature>
    let readiness: BrowserLifecycleReadinessObserver

    var body: some View {
        NavigationStack {
            BrowserSettingsView(store: store)
        }
        .onChange(of: store.canCreateWebKitContext) { _, isReady in
            if isReady {
                readiness.markReady()
            }
        }
        .onDisappear {
            readiness.markDismissed()
        }
    }
}

@MainActor
private struct BrowserEntryReadinessProbe: View {
    let store: StoreOf<BrowserFeature>
    let readiness: BrowserLifecycleReadinessObserver

    var body: some View {
        BrowserView(store: store)
            .onChange(of: store.openTabsEntryLifecycle) { _, lifecycle in
                if lifecycle == .completed {
                    readiness.markReady()
                }
            }
    }
}
