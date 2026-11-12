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
    @Environment(\.scenePhase)
    private var scenePhase

    /// Creates the one root store used by the application scene.
    init() {
        store = RootComposition.makeStore()
    }

    /// Provides the application's single window group.
    var body: some Scene {
        WindowGroup {
            RootView(store: store)
        }
        .onChange(of: scenePhase, initial: true) { _, phase in
            store.send(.applicationPhaseChanged(applicationPhase(for: phase)))
        }
    }

    private func applicationPhase(for phase: ScenePhase) -> VaultApplicationScenePhase {
        switch phase {
        case .active:
            .active
        case .inactive:
            .inactive
        case .background:
            .background
        @unknown default:
            .unknown
        }
    }
}
