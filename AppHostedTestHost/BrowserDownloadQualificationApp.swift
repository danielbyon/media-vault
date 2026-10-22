//
//  BrowserDownloadQualificationApp.swift
//  MediaVault
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import SwiftUI

/// Entry point for the standalone Issue #42 qualification application.
///
/// The application presents the routing root view declared in
/// `BrowserDownloadQualificationRootView.swift`, which selects one qualification
/// surface from the launch arguments passed by the UI-test drivers. It is a
/// separate entry point from the unit-test host in `AppHostedTestHost.swift`
/// so that each application target compiles exactly one entry point and one
/// root view implementation.
@main
struct BrowserDownloadQualificationApp: App {
    var body: some Scene {
        WindowGroup {
            BrowserDownloadQualificationRootView()
        }
    }
}
