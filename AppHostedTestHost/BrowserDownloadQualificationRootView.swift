//
//  BrowserDownloadQualificationRootView.swift
//  MediaVault
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import SwiftUI

#if DEBUG && BROWSER_DOWNLOAD_STANDALONE_QUALIFICATION

import Foundation

/// Routing root view presented by the standalone qualification application.
///
/// The view selects one of the Issue #42 qualification surfaces from the
/// launch arguments passed by the UI-test drivers. It is the root view of the
/// qualification entry point in `BrowserDownloadQualificationApp.swift`; the
/// package-free unit-test host presents the inert
/// `AppHostedTestHostRootView.swift` instead.
///
/// Keeping the qualification references in this target-exclusive file leaves
/// them visible to the compiler-backed SwiftLint analyzer, which resolves
/// each file against a single application target's compiler invocation.
struct BrowserDownloadQualificationRootView: View {
    var body: some View {
        if ProcessInfo.processInfo.arguments.contains(BrowserDownloadProductionQualification.argument) {
            BrowserDownloadProductionQualification.root
        } else if ProcessInfo.processInfo.arguments.contains(BrowserDownloadNoticeQualification.argument) {
            BrowserDownloadNoticeQualification.root
        } else {
            Color.clear
        }
    }
}

#else

/// Inert fallback for qualification-host configurations without the
/// standalone qualification conditions.
struct BrowserDownloadQualificationRootView: View {
    var body: some View {
        Color.clear
    }
}

#endif
