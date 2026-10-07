//
//  UIKitTestSupport.swift
//  MediaVault
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import CoreFoundation
import UIKit

/// Shared UIKit fixtures for app-hosted tests that mount view controllers in a window.
///
/// UIKit only exposes scene-bound window creation on iOS 26 and later: `UIWindow()`
/// and `UIWindow(frame:)` are deprecated, and `UIWindow(windowScene:)` requires a
/// `UIWindowScene`. There is no public API for creating a `UIWindowScene`, and SwiftPM
/// test bundles run inside `xctest.tool`, which has no scene at all. Tests that need a
/// real window therefore run in an application-hosted test bundle and use this fixture
/// to attach their windows to the host application's scene.
@MainActor
enum UIKitTestSupport {
    /// Creates a window backed by the host application's first connected window scene.
    ///
    /// - Parameter frame: The frame assigned to the test window.
    /// - Returns: A window that is attached to the host scene but not yet visible; call
    ///   `makeKeyAndVisible()` when the test needs a visible, key window.
    /// - Precondition: The calling process has a connected `UIWindowScene`. Fails the
    ///   test run with an explanatory message when it does not, which is the case for
    ///   SwiftPM test bundles that run without an application host.
    static func makeWindow(frame: CGRect) -> UIWindow {
        guard let windowScene = UIApplication.shared
            .connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first
        else {
            preconditionFailure(
                "UIKitTestSupport.makeWindow requires an application-hosted test process "
                    + "with a connected UIWindowScene.",
            )
        }

        let window = UIWindow(windowScene: windowScene)
        window.frame = frame
        return window
    }
}
