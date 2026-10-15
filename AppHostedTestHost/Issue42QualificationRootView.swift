//
//  Issue42QualificationRootView.swift
//  MediaVault
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import SwiftUI

#if DEBUG && ISSUE42_STANDALONE_QUALIFICATION

import Foundation

/// Routing root view presented by the standalone qualification application.
///
/// The view selects one of the Issue #42 qualification surfaces from the
/// launch arguments passed by the UI-test drivers. It is the root view of the
/// qualification entry point in `Issue42QualificationApp.swift`; the
/// package-free unit-test host presents the inert
/// `AppHostedTestHostRootView.swift` instead.
///
/// Keeping the qualification references in this target-exclusive file leaves
/// them visible to the compiler-backed SwiftLint analyzer, which resolves
/// each file against a single application target's compiler invocation.
struct Issue42QualificationRootView: View {
    var body: some View {
        if ProcessInfo.processInfo.arguments.contains(Issue42ProductionQualification.argument) {
            Issue42ProductionQualification.root
        } else if ProcessInfo.processInfo.arguments.contains(Issue42BrowserNoticeQualification.argument) {
            Issue42BrowserNoticeQualification.root
        } else {
            Color.clear
        }
    }
}

#else

/// Inert fallback for qualification-host configurations without the
/// standalone qualification conditions.
struct Issue42QualificationRootView: View {
    var body: some View {
        Color.clear
    }
}

#endif
