//
//  RootSurfaceSnapshotTests.swift
//  MediaVault
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import AppFeature
import CalculatorFeature
import ComposableArchitecture
import CoreFoundation
import Dependencies
import FoundationTestSupport
import SnapshotTesting
import SwiftUI
import Testing
import UIKit
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
        rootSurfaceSnapshot(
            horizontalSizeClass: .compact,
            config: DeterministicTestSupport.compactPhone,
            testName: #function,
        )
    }

    @Test("The root surface is stable on a large iPhone")
    func largePhoneSnapshot() {
        rootSurfaceSnapshot(
            horizontalSizeClass: .compact,
            config: DeterministicTestSupport.largePhone,
            testName: #function,
        )
    }

    @Test("The root surface is stable at regular iPad width")
    func regularWidthIPadSnapshot() {
        rootSurfaceSnapshot(
            horizontalSizeClass: .regular,
            config: DeterministicTestSupport.regularWidthIPad,
            testName: #function,
        )
    }

    private func rootSurfaceSnapshot(
        horizontalSizeClass: UserInterfaceSizeClass,
        config: ViewImageConfig,
        testName: String,
    ) {
        let displayScale = UITraitCollection.current.displayScale
        let referenceTestName = displayScale == 3
            ? testName
            : String(testName.dropLast(2)) + "\(Int(displayScale))x()"
        assertSnapshot(
            of: rootView(horizontalSizeClass: horizontalSizeClass),
            as: .image(
                layout: .device(config: config),
                traits: .init(displayScale: displayScale),
            ),
            testName: referenceTestName,
        )
    }

    private func rootView(horizontalSizeClass: UserInterfaceSizeClass) -> some View {
        let store = makeRootStore()

        return RootView(store: store)
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
