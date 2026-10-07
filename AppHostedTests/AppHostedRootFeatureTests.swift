//
//  AppHostedRootFeatureTests.swift
//  MediaVault
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import CalculatorFeature
import ComposableArchitecture
import ConcurrencyExtras
import CoreFoundation
import CoreGraphics
import Dependencies
import Foundation
import Sharing
import SwiftUI
import Testing
import UIKit
import VaultFeature
@testable import AppFeature
@testable import BrowserFeature

@Suite("Root feature window mount (app hosted)")
@MainActor
struct AppHostedRootFeatureTests {
    @Test("The Browser surface is mounted only after authentication and Browser entry")
    @MainActor
    func browserSurfaceRespectsTheVaultCompositionBoundary() async throws {
        let suiteName = "RootFeatureTests.BrowserBoundary.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defaults.set(true, forKey: "browser.preserveOpenTabs")
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let savedURL = try #require(URL(string: "https://restored-after-authentication.example"))
        let savedData = try BrowserOpenTabsSession(
            selectedPosition: 0,
            entries: [.init(position: 0, kind: .web(savedURL))],
        ).encoded()
        let loadCount = LockIsolated(0)
        let webKitCommands = LockIsolated<[BrowserWebKitCommand]>([])
        let sessionLoad: @Sendable ()
            async -> BrowserOpenTabsSessionLoadOutcome = {
                loadCount.withValue { $0 += 1 }
                return .loaded(savedData)
            }
        let webKitExecute: @Sendable (BrowserWebKitCommand) -> Void = { command in
            webKitCommands.withValue { $0.append(command) }
        }

        let gatedPhases = [
            VaultFeature.State(phase: .loading),
            VaultFeature.State(phase: .unconfigured),
            VaultFeature.State(phase: .locked, configuredKind: .password),
            VaultFeature.State(phase: .setup),
            VaultFeature.State(phase: .authentication, configuredKind: .password),
        ]
        for vault in gatedPhases {
            let store = compositionStore(
                vault: vault,
                defaults: defaults,
                sessionLoad: sessionLoad,
                webKitExecute: webKitExecute,
            )
            let (controller, window) = mountRootView(store)
            await settle(controller)

            #expect(!hasBrowserOmnibox(in: controller.view))
            #expect(loadCount.value == 0)
            #expect(navigatedURLs(in: webKitCommands.value).isEmpty)

            window.isHidden = true
            window.rootViewController = nil
        }

        var authenticatedShell = VaultFeature.State(phase: .authenticated)
        authenticatedShell.shell.selectedTab = .collections
        let beforeBrowserEntry = compositionStore(
            vault: authenticatedShell,
            defaults: defaults,
            sessionLoad: sessionLoad,
            webKitExecute: webKitExecute,
        )
        let (shellController, shellWindow) = mountRootView(beforeBrowserEntry)
        await settle(shellController)
        #expect(!hasBrowserOmnibox(in: shellController.view))
        #expect(loadCount.value == 0)
        #expect(navigatedURLs(in: webKitCommands.value).isEmpty)
        shellWindow.isHidden = true
        shellWindow.rootViewController = nil

        authenticatedShell.shell.selectedTab = .browser
        let browserEntry = compositionStore(
            vault: authenticatedShell,
            defaults: defaults,
            sessionLoad: sessionLoad,
            webKitExecute: webKitExecute,
        )
        let (browserController, browserWindow) = mountRootView(browserEntry)
        await settleUntilBrowserEntryCompletes(browserEntry, browserController)
        #expect(hasBrowserOmnibox(in: browserController.view))
        #expect(browserEntry.state.vault.shell.browser.profileLifecycle == .ready)
        #expect(browserEntry.state.vault.shell.browser.openTabsEntryLifecycle == .completed)
        #expect(loadCount.value == 1)
        browserWindow.isHidden = true
        browserWindow.rootViewController = nil
    }
}

@MainActor
private func compositionStore(
    vault: VaultFeature.State,
    defaults: UserDefaults,
    sessionLoad: @escaping @Sendable () async -> BrowserOpenTabsSessionLoadOutcome = { .missing },
    webKitExecute: @escaping @Sendable (BrowserWebKitCommand) -> Void = { _ in },
) -> StoreOf<RootFeature> {
    withDependencies {
        $0.defaultAppStorage = defaults
        $0.uuid = .incrementing
        $0.vaultCredential.loadConfiguration = { nil }
        $0.calculatorPersistence.load = { nil }
        $0.calculatorPersistence.save = { _ in }
        $0.browserOpenTabsSession.load = sessionLoad
        $0.browserSettings.load = { .init() }
        $0.browserLibrary.loadBookmarks = { [] }
        $0.browserLibrary.loadHistory = { [] }
        $0.browserClipboard.readHTTPURL = { nil }
        $0.browserWebKit = BrowserWebKitClient(
            execute: { command in webKitExecute(command) },
            events: { AsyncStream { $0.finish() } },
        )
    } operation: {
        RootComposition.makeStore(vault: vault)
    }
}

@MainActor
private func mountRootView(_ store: StoreOf<RootFeature>) -> (UIHostingController<RootView>, UIWindow) {
    let controller = UIHostingController(rootView: RootView(store: store))
    let window = UIKitTestSupport.makeWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
    window.rootViewController = controller
    window.makeKeyAndVisible()
    controller.view.frame = window.bounds
    controller.view.layoutIfNeeded()
    return (controller, window)
}

@MainActor
private func settle(_ controller: UIViewController) async {
    for _ in 0 ..< 8 {
        await Task.yield()
        controller.view.layoutIfNeeded()
    }
}

@MainActor
private func settleUntilBrowserEntryCompletes(
    _ store: StoreOf<RootFeature>,
    _ controller: UIViewController,
) async {
    for _ in 0 ..< 100 {
        await Task.yield()
        controller.view.layoutIfNeeded()
        if store.state.vault.shell.browser.openTabsEntryLifecycle == .completed {
            return
        }
        try? await Task.sleep(for: .milliseconds(10))
    }
}

@MainActor
private func hasBrowserOmnibox(in root: UIView) -> Bool {
    allViews(in: root)
        .compactMap { $0 as? UITextField }
        .contains { $0.placeholder == "Search or enter website" }
}

@MainActor
private func allViews(in root: UIView) -> [UIView] {
    root.subviews.flatMap { [$0] + allViews(in: $0) }
}

private func navigatedURLs(in commands: [BrowserWebKitCommand]) -> [URL] {
    commands.compactMap { command in
        if case let .load(_, url, _) = command {
            return url
        }
        return nil
    }
}
