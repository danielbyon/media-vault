//
//  BrowserWebKitPresentationGuard.swift
//  MediaVault
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import UIKit
import WebKit

/// Provides presentation-state checks for an adapter-owned WebKit boundary.
@MainActor
struct BrowserWebKitPresentationGuard {
    /// Rejects a direct opaque UIKit child that covers the registered WebKit boundary.
    static func hasOpaqueCover(in webView: WKWebView) -> Bool {
        let subviews = webView.subviews

        guard let scrollViewIndex = subviews.firstIndex(where: {
            $0 === webView.scrollView
        }) else {
            return false
        }

        return subviews.dropFirst(scrollViewIndex + 1).contains { subview in
            let subviewFrame = subview.convert(subview.bounds, to: webView)
            guard !subview.isHidden,
                  subview.alpha >= 0.99,
                  subviewFrame.insetBy(dx: -1, dy: -1).contains(webView.bounds)
            else {
                return false
            }

            // WebKit's content view is an out-of-process rendering surface rather than an
            // app-owned colored overlay. Use only public UIKit state here; do not depend on
            // undocumented WebKit class-name prefixes to identify it.
            return subview.isOpaque && (subview.backgroundColor?.cgColor.alpha ?? 0) >= 0.99
        }
    }
}
