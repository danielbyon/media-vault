//
//  RootSurfaceSnapshotTests.swift
//  MediaVault
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import AppFeature
import ComposableArchitecture
import Dependencies
import FoundationTestSupport
import SnapshotTesting
import SwiftUI
import Testing
import VaultFeature

@MainActor
@Suite("Root surface snapshots")
struct RootSurfaceSnapshotTests {
    @Test("The root state has a stable structural snapshot")
    func rootStateSnapshot() {
        let store = makeRootStore()
        assertSnapshot(of: store.state, as: .dump)
    }

    @Test("The root surface is stable on a compact iPhone")
    func compactPhoneSnapshot() {
        assertSnapshot(
            of: rootView(),
            as: .image(layout: .device(config: DeterministicTestSupport.compactPhone)),
        )
    }

    @Test("The root surface is stable on a large iPhone")
    func largePhoneSnapshot() {
        assertSnapshot(
            of: rootView(),
            as: .image(layout: .device(config: DeterministicTestSupport.largePhone)),
        )
    }

    @Test("The root surface is stable at regular iPad width")
    func regularWidthIPadSnapshot() {
        assertSnapshot(
            of: rootView(),
            as: .image(layout: .device(config: DeterministicTestSupport.regularWidthIPad)),
        )
    }

    private func rootView() -> some View {
        let store = makeRootStore()

        return RootView(store: store)
            .environment(\.colorScheme, .light)
    }

    private func makeRootStore() -> StoreOf<RootFeature> {
        withDependencies {
            $0.calculatorPersistence.load = { nil }
            $0.calculatorPersistence.save = { _ in }
            $0.vaultCredential.loadConfiguration = { nil }
        } operation: {
            RootComposition.makeStore()
        }
    }
}

extension RootFeature.State: @retroactive AnySnapshotStringConvertible {
    /// Prevents snapshot rendering from recursively expanding child values.
    public static var renderChildren: Bool {
        false
    }

    /// Returns the stable structural representation used by the root-state snapshot.
    public var snapshotDescription: String {
        "RootFeature.State(vaultPhase: \(String(describing: vault.phase)), "
            + "pendingHiddenAttempt: \(pendingHiddenAttemptID != nil))"
    }
}
