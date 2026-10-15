//
//  AppHostedTestHostRootView.swift
//  MediaVault
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import SwiftUI

/// Inert root view for the package-free unit-test host application.
///
/// The host intentionally presents no product interface: the UIKit and
/// SwiftUI surfaces under test create their own windows inside the host's
/// process. The standalone qualification host target compiles
/// `Issue42QualificationRootView.swift` instead of this file, and both files
/// declare an `AppHostedTestHostRootView` type. Exactly one variant is a
/// member of each application target, so the shared AppHostedTestHost scene
/// body resolves against the variant owned by the target being built.
struct AppHostedTestHostRootView: View {
    var body: some View {
        Color.clear
    }
}
