//
//  Application.swift
//  MediaVault
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import AppFeature
import ComposableArchitecture
import SwiftUI

/// The executable bootstrap that owns the application's single root store and scene.
@main
@MainActor
struct Application: SwiftUI.App {
    private let store: StoreOf<RootFeature>

    /// Creates the one root store used by the application scene.
    init() {
        store = RootComposition.makeStore()
    }

    /// Provides the application's single window group.
    var body: some Scene {
        WindowGroup {
            RootView(store: store)
        }
    }
}
