//
//  AppHostedTestHost.swift
//  MediaVault
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import SwiftUI

/// Host application for the package-free unit-test bundle.
///
/// Tests exercise UIKit and SwiftUI surfaces that need a real window inside
/// an application process, because a UIWindow can only be created from a
/// UIWindowScene and a scene only exists inside an application. The host
/// intentionally presents no product interface of its own: the scene body
/// delegates to `AppHostedTestHostRootView`, which always presents an inert
/// `Color.clear` scene.
///
/// The standalone Issue #42 qualification application is a separate target
/// with its own entry point in `BrowserDownloadQualificationApp.swift`, so neither
/// application target compiles the other's entry point.
@main
struct AppHostedTestHost: App {
    var body: some Scene {
        WindowGroup {
            AppHostedTestHostRootView()
        }
    }
}
