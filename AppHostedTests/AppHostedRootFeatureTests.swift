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
import QuartzCore
import QuickLook
import Sharing
import SnapshotTesting
import SwiftUI
import Testing
import UIKit
import UIUtilities
import VaultFeature
@testable import AppFeature
@testable import BrowserFeature

extension AppHostedUITests {
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

extension AppHostedUITests {
    /// Real UIKit windows and RootView rendering; synthetic lifecycle notifications qualify the
    /// synchronous observer boundary, not physical Home/task-switcher timing or two-scene behavior.
    @Suite("Root download privacy (mounted UIKit)")
    @MainActor
    struct RootDownloadPrivacyTests {
        @Test("Mounted Root authentication loss synchronously conceals and revokes a native share")
        func liveAuthenticationRevokesBeforeLayout() async throws {
            try await withDownloadRoot { fixture in
                let file = try fixture.completedPDF()
                try await fixture.present(file.id, .share)
                fixture.store.send(.vault(.retryConfiguration))
                #expect(!fixture.owner.snapshot.isAvailable)
                #expect(fixture.owner.snapshot.records.isEmpty)
                #expect(!FileManager.default.fileExists(atPath: file.url.path))
                let cover = try #require(fixture.coordinator.coverWindow(in: fixture.scene))
                #expect(!cover.isHidden)
                #expect(cover.windowLevel > UIWindow.Level.alert)
                #expect(fixture.owner.admit(RootDownloadWriter(), tabID: .init()) == nil)
                try await fixture
                    .wait("authentication-loss dismissal and safe locked Root") {
                        fixture.coordinator.nativeController == nil && fixture.coverAbsent
                    }
                #expect(fixture.host?.rootRender.confirmed == true)
                #expect(fixture.window.rootViewController?.viewIfLoaded?.window === fixture.window)
            }
        }

        @Test("Full-screen Quick Look retains its scene and inactivity cannot resurrect its source")
        func quickLookDetachedRootRetainsScene() async throws {
            try await withDownloadRoot { fixture in
                let file = try fixture.completedPDF()
                try await fixture.present(file.id, .preview)
                let preview = try #require(fixture.coordinator.nativeController as? QLPreviewController)
                #expect(preview.presentingViewController != nil)
                #expect(fixture.host?.hostingScene === fixture.scene)
                // Full-screen presentation must actually detach the underlying root, rather than
                // replacing a real UIWindowScene with an arbitrary test window.
                #expect(fixture.host?.viewIfLoaded?.window == nil)
                fixture.owner.recheckAuthorization()
                #expect(fixture.owner.snapshot.isAvailable)
                fixture.deactivate()
                #expect(!fixture.owner.snapshot.isAvailable)
                #expect(fixture.coordinator.coverWindow(in: fixture.scene)?.isHidden == false)
                #expect(!FileManager.default.fileExists(atPath: file.url.path))
                fixture.activate()
                try await fixture
                    .wait("reactivation dismissal and safe Root") {
                        fixture.coordinator.nativeController == nil && fixture.coverAbsent
                    }
                #expect(fixture.owner.snapshot.records.isEmpty)
                #expect(!FileManager.default.fileExists(atPath: file.url.path))
                #expect(fixture.owner.snapshot.isAvailable)
            }
        }

        @Test("Cleanup failure permits safe Root recovery and explicit download-only retry")
        func cleanupFailureDoesNotLockRoot() async throws {
            try await withDownloadRoot { fixture in
                let file = try fixture.completedPDF()
                try await fixture.present(file.id, .share)
                fixture.faults.failRemoval = true
                fixture.store.send(.vault(.retryConfiguration))
                #expect(fixture.owner.snapshot.cleanupNeedsRetry)
                #expect(fixture.owner.snapshot.records.isEmpty)
                #expect(fixture.owner.snapshot.presentation == nil)
                #expect(FileManager.default.fileExists(atPath: file.url.path))
                try await fixture
                    .wait("cleanup-failure dismissal and safe locked Root") {
                        fixture.coordinator.nativeController == nil && fixture.coverAbsent
                    }
                #expect(fixture.host?.rootRender.confirmed == true)
                #expect(fixture.store.vault.phase == .locked)
                #expect(fixture.root.view.hitTest(
                    CGPoint(x: fixture.root.view.bounds.midX, y: fixture.root.view.bounds.midY),
                    with: nil,
                ) != nil)
                fixture.store.send(.vault(.beginAuthentication))
                try await fixture.wait("authenticated Root confirmation after cleanup failure") {
                    fixture.host?.rootRender.confirmed == true && fixture.coverAbsent
                }
                #expect(fixture.store.vault.phase == .authenticated)
                #expect(!fixture.owner.snapshot.isAvailable)
                fixture.faults.failRemoval = false
                fixture.owner.execute(.init(snapshot: fixture.owner.snapshot, action: .retryCleanup))
                #expect(!fixture.owner.snapshot.cleanupNeedsRetry)
                #expect(fixture.owner.snapshot.isAvailable)
                #expect(!FileManager.default.fileExists(atPath: file.url.path))
                #expect(fixture.owner.snapshot.records.isEmpty)
            }
        }

        @Test("Mounted cleanup cover Retry button removes revoked bytes through its UIKit action")
        func cleanupCoverRetryButton() async throws {
            try await withDownloadRoot { fixture in
                let file = try fixture.completedPDF()
                try await fixture.present(file.id, .share)
                fixture.faults.failRemoval = true
                fixture.store.send(.vault(.retryConfiguration))
                let cover = try #require(fixture.coordinator.coverWindow(in: fixture.scene))
                let view = try #require(cover.rootViewController?.view)
                let retry = try #require(downloadRetryButton(in: view))
                #expect(!retry.isHidden)
                #expect(fixture.owner.snapshot.cleanupNeedsRetry)
                #expect(FileManager.default.fileExists(atPath: file.url.path))
                fixture.faults.failRemoval = false
                retry.sendActions(for: .touchUpInside)
                #expect(!fixture.owner.snapshot.cleanupNeedsRetry)
                #expect(!FileManager.default.fileExists(atPath: file.url.path))
                #expect(fixture.owner.snapshot.records.isEmpty)
                #expect(!fixture.owner.snapshot.isAvailable)
                try await fixture
                    .wait("Retry cleanup dismissal and safe Root") {
                        fixture.coordinator.nativeController == nil && fixture.coverAbsent
                    }
                #expect(fixture.host?.rootRender.confirmed == true)
            }
        }

        @Test("Native privacy cover window shows redacted cleanup retry at large Dynamic Type")
        func cleanupCoverWindowSnapshotLargeType() async throws {
            try await withDownloadRoot { fixture in
                let file = try fixture.completedPDF()
                try await fixture.present(file.id, .share)
                let nativeWindow = try #require(fixture.coordinator.nativeController?.viewIfLoaded?.window)
                fixture.faults.failRemoval = true
                // This fixture's phase action synchronously exercises the actual mounted coordinator.
                // It is representative cover rendering, not real system scene-inactivation evidence.
                fixture.store.send(.vault(.retryConfiguration))
                let cover = try #require(fixture.coordinator.coverWindow(in: fixture.scene))
                let controller = try #require(cover.rootViewController)
                cover.overrideUserInterfaceStyle = .light
                controller.traitOverrides.preferredContentSizeCategory = .accessibilityExtraLarge
                controller.view.setNeedsLayout()
                controller.view.layoutIfNeeded()
                cover.layoutIfNeeded()
                #expect(!cover.isHidden)
                #expect(cover.windowScene === fixture.scene)
                #expect(cover.windowLevel > nativeWindow.windowLevel)
                #expect(cover.frame == fixture.scene.effectiveGeometry.coordinateSpace.bounds)
                #expect(fixture.owner.snapshot.cleanupNeedsRetry)
                let retry = try #require(downloadRetryButton(in: controller.view))
                #expect(retry.window === cover)
                #expect(!retry.isHidden)
                // UIView snapshot strategies reparent their input into a temporary window. A live
                // privacy window must keep its native scene and hierarchy throughout reconciliation.
                // Capture its mounted layer into an immutable image instead; snapshotting that image
                // cannot move or replace the cover, its controller, or the native presentation.
                let image = UIGraphicsImageRenderer(bounds: cover.bounds).image { context in
                    cover.layer.render(in: context.cgContext)
                }
                // Approved destinations use separate references for their actual scene geometry.
                withSnapshotTesting(record: .missing) {
                    assertSnapshot(
                        of: image,
                        as: .image,
                        named: "download-privacy-cover-retry-accessibility3-\(Int(cover.bounds.width))x\(Int(cover.bounds.height))",
                    )
                }
            }
        }

        @Test("Normal share completion requires actual absence before a second share")
        func normalCompletionThenSecondShare() async throws {
            try await withDownloadRoot { fixture in
                let file = try fixture.completedPDF()
                try await fixture.present(file.id, .share)
                let activity = try #require(fixture.coordinator.nativeController as? UIActivityViewController)
                activity.completionWithItemsHandler?(nil, false, nil, nil)
                await Task.yield()
                #expect(fixture.coordinator.nativeController === activity)
                #expect(FileManager.default.fileExists(atPath: file.url.path))
                activity.dismiss(animated: false)
                try await fixture
                    .wait("normal share dismissal confirmed absent") { fixture.coordinator.nativeController == nil }
                #expect(fixture.owner.snapshot.presentation == nil)
                try await fixture.present(file.id, .share)
                #expect(fixture.coordinator.nativeController !== activity)
                #expect(FileManager.default.fileExists(atPath: file.url.path))
            }
        }

        @Test("Old share dismissal reconciles the latest accepted request after confirmed absence")
        func latestRequestAfterOldDismissal() async throws {
            try await withDownloadRoot { fixture in
                let file = try fixture.completedPDF()
                try await fixture.present(file.id, .share)
                let old = try #require(fixture.owner.snapshot.presentation)
                let oldController = try #require(fixture.coordinator.nativeController)
                fixture.owner.execute(.init(
                    snapshot: fixture.owner.snapshot,
                    action: .dismissPresentation(old.requestID),
                ))
                fixture.owner.execute(.init(snapshot: fixture.owner.snapshot, action: .present(file.id, .share)))
                let latest = try #require(fixture.owner.snapshot.presentation)
                #expect(latest.requestID != old.requestID)
                try await fixture.wait("latest share real presentation completion after old absence") {
                    fixture.coordinator.nativePresentationCompleted
                        && fixture.coordinator.nativeController != nil
                        && fixture.coordinator.nativeController !== oldController
                        && fixture.coordinator.nativeController?.presentingViewController != nil
                }
                #expect(oldController.presentingViewController == nil)
                #expect(fixture.owner.snapshot.presentation == latest)
                #expect(FileManager.default.fileExists(atPath: file.url.path))
            }
        }

        @Test("Unavailable mounted presenter clears its accepted request without discarding completed bytes")
        func unavailablePresenterDoesNotStrandRequest() async throws {
            try await withDownloadRoot { fixture in
                let file = try fixture.completedPDF()
                let host = try #require(fixture.host)
                host.view.removeFromSuperview()
                #expect(host.hostingScene === fixture.scene)
                #expect(host.view.window == nil)
                fixture.owner.execute(.init(snapshot: fixture.owner.snapshot, action: .present(file.id, .share)))
                try await fixture
                    .wait("unavailable presenter request rejected") { fixture.owner.snapshot.presentation == nil }
                #expect(fixture.coordinator.nativeController == nil)
                #expect(fixture.owner.snapshot.records.first?.isReady == true)
                #expect(FileManager.default.fileExists(atPath: file.url.path))
            }
        }

        @Test("A covered root resize remains concealed without controller layout callbacks")
        func coverTracksGeometryWithoutLayoutCallbacks() async throws {
            try await withDownloadRoot { fixture in
                let file = try fixture.completedPDF()
                try await fixture.present(file.id, .preview)
                let initialGeneration = fixture.owner.snapshot.generation
                fixture.deactivate()
                try await fixture.wait("revoked preview and request are actually absent before resize") {
                    fixture.coordinator.nativeController == nil && fixture.owner.snapshot.presentation == nil
                }
                let cover = try #require(fixture.coordinator.coverWindow(in: fixture.scene))
                let coverController = try #require(cover.rootViewController as? BrowserDownloadCoverController)
                let host = try #require(fixture.host)
                // Model missed layout notifications without changing UIKit's scene or privacy state:
                // keep the opaque cover mounted, but remove both layout-driven refresh paths.
                coverController.geometryChanged = nil
                host.view.removeFromSuperview()
                host.cancelRenderVerification()
                let originalFrame = fixture.window.frame
                defer { fixture.window.frame = originalFrame }
                let sceneBounds = fixture.scene.effectiveGeometry.coordinateSpace.bounds
                let smallFrame = CGRect(
                    origin: sceneBounds.origin,
                    size: CGSize(width: sceneBounds.width / 2, height: sceneBounds.height / 2),
                )
                fixture.window.frame = smallFrame
                cover.frame = smallFrame
                coverController.view.layoutIfNeeded()
                #expect(cover.frame.contains(fixture.window.frame))
                // This is a real root-window resize, not an OS scene-resize qualification.
                // No controller-layout callback is invoked to refresh the cover after expansion.
                fixture.window.frame = sceneBounds
                try await fixture.wait("cover occludes expanded root without layout notifications") {
                    !cover.isHidden && cover.frame.contains(fixture.window.frame)
                        && coverController.view
                        .convert(coverController.view.bounds, to: fixture.window)
                        .contains(fixture.window.bounds)
                }
                #expect(cover.frame == sceneBounds)
                #expect(cover.rootViewController === coverController)
                #expect(coverController.view.window === cover)
                #expect(coverController.view.backgroundColor == .systemBackground)
                #expect(cover.alpha == 1)
                #expect(coverController.view.alpha == 1)
                #expect(fixture.owner.snapshot.generation > initialGeneration)
                #expect(!fixture.owner.snapshot.isAvailable)
                #expect(fixture.owner.snapshot.records.isEmpty)
                #expect(!FileManager.default.fileExists(atPath: file.url.path))
                fixture.activate()
                #expect(fixture.owner.snapshot.records.isEmpty)
                #expect(!FileManager.default.fileExists(atPath: file.url.path))
            }
        }

        @Test("Stale body token and geometry refresh cannot release a mounted Root cover")
        func staleRootTokenCannotUncover() async throws {
            try await withDownloadRoot { fixture in
                _ = try fixture.completedPDF()
                let stale = try #require(fixture.host?.rootRender.token)
                fixture.store.send(.vault(.retryConfiguration))
                fixture.host?.rootUpdated(stale)
                #expect(fixture.host?.rootRender.token == nil)
                #expect(fixture.host?.rootRender.confirmed == false)
                let cover = try #require(fixture.coordinator.coverWindow(in: fixture.scene))
                cover.frame = CGRect(x: 0, y: 0, width: 1, height: 1)
                cover.rootViewController?.view.setNeedsLayout()
                cover.rootViewController?.view.layoutIfNeeded()
                #expect(cover.frame == fixture.scene.effectiveGeometry.coordinateSpace.bounds)
                #expect(!cover.isHidden)
                #expect(fixture.host?.rootRender.confirmed == false)
                // Resize an actual registered root window, then drive its UIKit layout callback.
                // This is window-layout coverage, not proof of resizable iPad scene geometry.
                let originalFrame = fixture.window.frame
                fixture.window.frame = CGRect(
                    origin: originalFrame.origin,
                    size: CGSize(width: originalFrame.width / 2, height: originalFrame.height / 2),
                )
                cover.frame = CGRect(x: 0, y: 0, width: 1, height: 1)
                fixture.host?.view.setNeedsLayout()
                fixture.host?.view.layoutIfNeeded()
                #expect(cover.frame == fixture.scene.effectiveGeometry.coordinateSpace.bounds)
                #expect(!cover.isHidden)
                #expect(fixture.host?.rootRender.confirmed == false)
                fixture.window.frame = originalFrame
                try await fixture.wait("fresh Root token and layout confirmation") {
                    fixture.coverAbsent && fixture.host?.rootRender.confirmed == true
                }
                #expect(fixture.host?.rootRender.token != stale)
            }
        }

        @Test("Dismantling the mounted download host ends its observation and coverage admission")
        func dismantlingMountedDownloadHostEndsObservation() async throws {
            try await withDownloadRoot { fixture in
                let host = try #require(fixture.host)
                #expect(host.nativeCoordinator === fixture.coordinator)
                #expect(fixture.coordinator.coverWindow(in: fixture.scene) == nil)

                // The production factory installed a real authentication observation; dismantling
                // must cancel it and drop the stored closure instead of leaving live work behind.
                var authenticationObservationCancelled = false
                host.cancelAuthenticationObservation = { authenticationObservationCancelled = true }

                BrowserDownloadHost.dismantleUIViewController(host, coordinator: ())

                #expect(authenticationObservationCancelled)
                #expect(host.cancelAuthenticationObservation == nil)
                // `hostingScene` is the retained scene the presenter was admitted in, not view
                // attachment: viewDidLayoutSubviews refreshes cover geometry from it and a detached
                // unresolved presentation keeps its scene cover, so dismantling does not clear it.
                #expect(host.hostingScene === fixture.scene)
                // The scene keeps no cover for an unregistered host.
                #expect(fixture.coordinator.coverWindow(in: fixture.scene) == nil)
            }
        }
    }
}

@MainActor
private func withDownloadRoot(_ body: (MountedDownloadRoot) async throws -> Void) async throws {
    let fixture = try MountedDownloadRoot()
    do {
        try await fixture.waitReady()
        try await body(fixture)
    } catch {
        await fixture.remove()
        throw error
    }
    await fixture.remove()
}

/// A controlled lifecycle reducer drives phase changes while the actual RootView supplies live
/// Store.publisher observation and immutable body tokens. This does not test credential policy.
/// Only simulator protection readback is injected; ownership, backup exclusion and UIKit are real.
@MainActor
private final class MountedDownloadRoot {
    final class Faults {
        var failRemoval = false
    }

    let faults: Faults
    let scratchRoot: URL
    let owner: BrowserDownloadOwner
    let coordinator: BrowserDownloadNativeCoordinator
    let store: StoreOf<RootFeature>
    let root: UIHostingController<RootView>
    let window: UIWindow
    private(set) var host: BrowserDownloadHostController?
    private var nativeCallbacks: [String] = []

    let scene: UIWindowScene

    var coverAbsent: Bool {
        coordinator.coverWindow(in: scene) == nil
    }

    init() throws {
        scratchRoot = FileManager.default.temporaryDirectory.appendingPathComponent(
            "issue42-root-ui-\(UUID().uuidString)",
            isDirectory: true,
        )
        let removalFaults = Faults()
        faults = removalFaults
        let scratch = BrowserDownloadScratchStore(
            root: scratchRoot,
            verifyProtection: { url in
                #if !targetEnvironment(simulator)
                try BrowserDownloadScratchStore.verifyNativeProtection(url)
                #endif
            },
            remove: { url in
                if removalFaults.failRemoval {
                    throw CocoaError(.fileWriteNoPermission)
                }
                try FileManager.default.removeItem(at: url)
            },
        )
        let fixtureOwner = BrowserDownloadOwner(store: scratch)
        owner = fixtureOwner
        let fixtureCoordinator = BrowserDownloadNativeCoordinator(owner: fixtureOwner)
        coordinator = fixtureCoordinator
        // The retained Calculator decoy creates its own store during root composition. Capture
        // deterministic persistence there, before its actual view later runs the loading task.
        let initial = withDependencies {
            $0.calculatorPersistence.load = { nil }
            $0.calculatorPersistence.save = { _ in }
        } operation: {
            RootComposition.makeStore(vault: .init(phase: .authenticated)).state
        }
        store = Store(initialState: initial) {
            Reduce<RootFeature.State, RootFeature.Action> { state, action in
                switch action {
                case .vault(.retryConfiguration):
                    state.vault.phase = .locked
                case .vault(.beginAuthentication):
                    state.vault.phase = .authenticated
                default:
                    break
                }
                return .none
            }
        }
        let downloads = BrowserDownloadClient(
            execute: { await fixtureOwner.execute($0) },
            events: { await fixtureOwner.subscribe() },
        )
        root = DownloadRootAppearanceController(rootView: RootView(
            store: store,
            downloads: downloads,
            privacyGeneration: { fixtureOwner.snapshot.generation },
            downloadHost: { $0.using(coordinator: fixtureCoordinator) },
        ))
        window = UIKitTestSupport.makeWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        scene = try #require(window.windowScene)
        window.rootViewController = root
        window.makeKeyAndVisible()
        root.view.frame = window.bounds
        root.view.layoutIfNeeded()
        fixtureCoordinator.qualificationObservation = { [weak self] event, _ in
            guard let self else {
                return
            }

            nativeCallbacks.append(event)
            if nativeCallbacks.count > 64 {
                nativeCallbacks.removeFirst()
            }
        }
    }

    func waitReady() async throws {
        try await wait("active scene, registered Root and confirmed initial layout") {
            self.scene.activationState == .foregroundActive
                && self.downloadHosts(in: self.root).first?.hostingScene === self.scene
                && self.owner.snapshot.isAvailable
                && self.downloadHosts(in: self.root).first?.rootRender.confirmed == true
        }
        host = downloadHosts(in: root).first
    }

    func completedPDF() throws -> (id: BrowserDownloadID, url: URL) {
        let id = try #require(owner.admit(RootDownloadWriter(), tabID: .init()))
        let url = try #require(owner.destination(for: id, suggestedName: "root-fixture.pdf"))
        try Issue42LoopbackServer.fixturePDF.write(to: url)
        owner.finished(id)
        #expect(owner.snapshot.records.first?.isReady == true)
        return (id, url)
    }

    func present(_ id: BrowserDownloadID, _ kind: BrowserDownloadPresentation.Kind) async throws {
        owner.execute(.init(snapshot: owner.snapshot, action: .present(id, kind)))
        try await wait("\(kind) real UIKit presentation completion") {
            self.coordinator.nativePresentationCompleted
                && self.coordinator.nativeController?.presentingViewController != nil
                && self.coordinator.nativeController?.viewIfLoaded?.window != nil
                && self.coordinator.nativeController?.isBeingPresented == false
        }
    }

    func deactivate() {
        NotificationCenter.default.post(name: UIScene.willDeactivateNotification, object: scene)
    }

    func activate() {
        NotificationCenter.default.post(name: UIScene.didActivateNotification, object: scene)
    }

    /// A deadline failure preserves all privacy assertions; it is never treated as successful UIKit
    /// completion. Scene attachment and modal absence are observed rather than assumed after a yield.
    func wait(_ milestone: String, _ predicate: @MainActor () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5.0)
        while !predicate(), Date() < deadline {
            root.view.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(predicate(), "\(milestone): \(diagnostics)")
    }

    private var diagnostics: String {
        let mountedHost = host ?? downloadHosts(in: root).first
        let cover = coordinator.coverWindow(in: scene)
        return coordinator.presentationDiagnostics
            + " nativeCallbacks=\(nativeCallbacks)"
            + " rootAppearance=\((root as? DownloadRootAppearanceController)?.appearanceCallbacks ?? [])"
            + " rootAttached=\(root.viewIfLoaded?.window === window)"
            + " rootModal=\(root.presentedViewController != nil)"
            + " hostAttached=\(mountedHost?.viewIfLoaded?.window != nil)"
            + " rootConfirmed=\(mountedHost?.rootRender.confirmed == true)"
            + " rootToken=\(mountedHost?.rootRender.token != nil)"
            + " rootRevision=\(mountedHost?.rootRender.revision ?? 0)"
            + " rootTokenMatches=\(mountedHost != nil && mountedHost?.rootRender.token == mountedHost?.currentRenderToken())"
            + " scene=\(scene.activationState.rawValue) retainedScene=\(mountedHost?.hostingScene === scene)"
            + " cover=\(cover != nil) coverVisible=\(cover?.isHidden == false)"
            + " available=\(owner.snapshot.isAvailable) retry=\(owner.snapshot.cleanupNeedsRetry)"
            + " generation=\(owner.snapshot.generation) request=\(owner.snapshot.presentation != nil)"
    }

    func remove() async {
        faults.failRemoval = false
        owner.invalidateAuthorization()
        coordinator.nativeController?.dismiss(animated: false)
        for _ in 0 ..< 100 where coordinator.nativeController != nil {
            coordinator.confirmAbsence()
            try? await Task.sleep(for: .milliseconds(20))
        }
        if coordinator.nativeController != nil {
            print("ROOT_DOWNLOAD_TEARDOWN_ABSENCE_UNCONFIRMED " + diagnostics)
        }
        window.isHidden = true
        window.rootViewController = nil
        try? FileManager.default.removeItem(at: scratchRoot)
    }

    private func downloadHosts(in controller: UIViewController) -> [BrowserDownloadHostController] {
        controller.children.flatMap { child in
            (child as? BrowserDownloadHostController).map { [$0] } ?? downloadHosts(in: child)
        }
    }
}

/// Records real hosting-controller appearance callbacks without replacing UIKit modal delegates.
@MainActor
private final class DownloadRootAppearanceController: UIHostingController<RootView> {
    private(set) var appearanceCallbacks: [String] = []

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        record("willAppear")
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        record("didAppear")
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        record("willDisappear")
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        record("didDisappear")
    }

    private func record(_ callback: String) {
        appearanceCallbacks.append(callback)
        if appearanceCallbacks.count > 16 {
            appearanceCallbacks.removeFirst()
        }
    }
}

@MainActor
private final class RootDownloadWriter: BrowserDownloadTransfer {
    var identity: AnyObject {
        self
    }

    func cancel(completion: @MainActor () -> Void) {
        completion()
    }
}

/// Finds the real native recovery control; tests dispatch its UIControl action rather than calling
/// the owner cleanup command directly. This is UIKit interaction, not a physical touch claim.
@MainActor
private func downloadRetryButton(in view: UIView) -> UIButton? {
    if let button = view as? UIButton, button.title(for: .normal) == "Retry Download Cleanup" {
        return button
    }
    return view.subviews.lazy.compactMap { downloadRetryButton(in: $0) }.first
}
