//
//  BrowserDownloadPersistenceFixture+RootHosting.swift
//  MediaVault
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import CalculatorFeature
import ComposableArchitecture
import CoreFoundation
import CoreGraphics
import Dependencies
import MediaLibrary
import SwiftUI
import UIKit
@testable import AppFeature
@testable import BrowserFeature
@testable import VaultFeature

@MainActor
extension BrowserDownloadPersistenceFixture {
    func mountRoot() {
        let store = makeRootStore()
        rootStore = store
        let nativeCoordinator = BrowserDownloadNativeCoordinator(owner: owner)
        coordinator = nativeCoordinator
        // The mounted browser must host the fixture adapter. Without this context the UI falls
        // back to the shared adapter while navigation runs through the fixture, leaving the
        // real transfer view detached from the window hierarchy.
        let controller = UIHostingController(rootView: AnyView(RootView(
            store: store,
            downloads: downloadClient,
            privacyGeneration: { [owner] in owner.snapshot.generation },
            downloadHost: { $0.using(coordinator: nativeCoordinator) },
        ).environment(\.qualificationBrowserHostingContext, BrowserQualificationWebKitHostingContext(
            adapter: adapter,
        ))))
        let window = UIKitTestSupport.makeWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        rootController = controller
        self.window = window
        window.rootViewController = controller
        window.makeKeyAndVisible()
        controller.view.frame = window.bounds
        controller.view.layoutIfNeeded()
    }

    func makeRootStore() -> StoreOf<RootFeature> {
        fixtureTabIDs.insert(tabID)
        var browser = BrowserFeature.State(initialTabID: tabID)
        browser.profileLifecycle = .ready
        browser.settings = initialSettings
        var vault = VaultFeature.State(phase: .authenticated)
        vault.shell = VaultShellFeature.State(selectedTab: .browser, browser: browser)

        let webKitClient = webKitClient
        let downloadClient = downloadClient
        let browserSettingsClient = browserSettingsClient
        let browserSessionClient = browserSessionClient
        let mediaLibraryClient = mediaLibraryClient
        return withDependencies {
            $0.uuid = .incrementing
            $0.browserWebKit = webKitClient
            $0.browserDownloads = downloadClient
            $0.browserSettings = browserSettingsClient
            $0.browserOpenTabsSession = browserSessionClient
            $0.mediaLibrary = mediaLibraryClient
            $0.calculatorPersistence.load = { nil }
            $0.calculatorPersistence.save = { _ in }
        } operation: {
            RootComposition.makeStore(vault: vault)
        }
    }

    func unmountRoot() {
        rootController?.view.removeFromSuperview()
        window?.isHidden = true
        window?.rootViewController = nil
        coordinator?.nativeController?.dismiss(animated: false)
        rootController = nil
        rootStore = nil
        coordinator = nil
        window = nil
    }
}
