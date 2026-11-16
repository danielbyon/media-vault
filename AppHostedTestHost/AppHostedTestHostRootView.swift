//
//  AppHostedTestHostRootView.swift
//  MediaVault
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import SwiftUI

/// Inert root view for the package-free unit-test host application.
///
/// UIKit and SwiftUI tests create their own windows inside this process, so this root
/// presents no product interface. The separate browser-download qualification target uses
/// `BrowserDownloadQualificationApp` and `BrowserDownloadQualificationRootView`.
struct AppHostedTestHostRootView: View {
    var body: some View {
        Color.clear
    }
}
