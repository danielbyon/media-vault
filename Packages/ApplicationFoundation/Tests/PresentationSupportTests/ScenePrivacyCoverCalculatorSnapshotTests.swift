//
//  ScenePrivacyCoverCalculatorSnapshotTests.swift
//  MediaVault
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import CoreFoundation
import CoreGraphics
import FoundationTestSupport
import SnapshotTesting
import Testing
import UIKit
@testable import PresentationSupport

@MainActor
@Suite("Scene privacy cover calculator snapshots")
struct ScenePrivacyCoverCalculatorSnapshotTests {
    @Test("The production calculator view is stable on a compact phone")
    func compactPhoneSnapshot() {
        assertCalculatorSnapshot(
            config: DeterministicTestSupport.compactPhone,
            testName: "compactPhone",
        )
    }

    @Test("The production calculator view is stable at regular iPad width")
    func regularIPadSnapshot() {
        assertCalculatorSnapshot(
            config: DeterministicTestSupport.regularWidthIPad,
            testName: "regularIPad",
        )
    }

    private func assertCalculatorSnapshot(config: ViewImageConfig, testName: String) {
        let size = config.size ?? .zero
        let calculator = ScenePrivacyCoverCalculatorView(
            frame: CGRect(origin: .zero, size: size),
        )

        assertSnapshot(
            of: calculator,
            as: .image(
                drawHierarchyInKeyWindow: false,
                size: size,
                traits: UITraitCollection(traitsFrom: [
                    config.traits,
                    UITraitCollection(userInterfaceStyle: .light),
                    UITraitCollection(displayScale: 2),
                ]),
            ),
            testName: testName,
        )
    }
}
