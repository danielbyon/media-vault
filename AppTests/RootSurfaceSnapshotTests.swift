//
//  RootSurfaceSnapshotTests.swift
//  MediaVault
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import AppFeature
import CalculatorFeature
import ComposableArchitecture
import Dependencies
import FoundationTestSupport
import SnapshotTesting
import SwiftUI
import Testing
import VaultFeature

@MainActor
@Suite("Root surface snapshots", .snapshots(record: .never))
struct RootSurfaceSnapshotTests {
    @Test("The root state has a stable structural snapshot")
    func rootStateSnapshot() {
        let store = makeRootStore()
        assertSnapshot(of: store.state, as: .dump)
    }

    @Test("The root surface is stable on a compact iPhone")
    func compactPhoneSnapshot() throws {
        let scale = try NativeSnapshotScale.current(capture: #function, target: "AppTests")
        let configuration = scale.configuration(DeterministicTestSupport.compactPhone)
        assertSnapshot(
            of: rootView(horizontalSizeClass: .compact),
            as: .image(layout: .device(config: configuration), traits: configuration.traits),
            named: scale.referenceName(nil),
        )
    }

    @Test("The root surface is stable on a large iPhone")
    func largePhoneSnapshot() throws {
        let scale = try NativeSnapshotScale.current(capture: #function, target: "AppTests")
        let configuration = scale.configuration(DeterministicTestSupport.largePhone)
        assertSnapshot(
            of: rootView(horizontalSizeClass: .compact),
            as: .image(layout: .device(config: configuration), traits: configuration.traits),
            named: scale.referenceName(nil),
        )
    }

    @Test("The root surface is stable at regular iPad width")
    func regularWidthIPadSnapshot() throws {
        let scale = try NativeSnapshotScale.current(capture: #function, target: "AppTests")
        let configuration = scale.configuration(DeterministicTestSupport.regularWidthIPad)
        assertSnapshot(
            of: rootView(horizontalSizeClass: .regular),
            as: .image(layout: .device(config: configuration), traits: configuration.traits),
            named: scale.referenceName(nil),
        )
    }

    private func rootView(horizontalSizeClass: UserInterfaceSizeClass) -> some View {
        let store = makeRootStore()

        return RootView(store: store)
            .environment(\.scenePhase, .active)
            .environment(\.colorScheme, .light)
            .environment(\.horizontalSizeClass, horizontalSizeClass)
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
