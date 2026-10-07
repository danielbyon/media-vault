//
//  AppHostedTestHost.swift
//  MediaVault
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import SwiftUI

/// Host application for the `AppHostedTests` unit-test bundle.
///
/// Tests that exercise UIKit and SwiftUI surfaces needing a real window run inside this
/// application's process because a `UIWindow` can only be created from a
/// `UIWindowScene`, and a scene only exists in an application. The host intentionally
/// presents no product interface; it exists to own the scene the tests attach their
/// windows to.
@main
struct AppHostedTestHost: App {
    var body: some Scene {
        WindowGroup {
            Color.clear
        }
    }
}
