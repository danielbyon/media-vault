//
//  NativeSnapshotScaleTests.swift
//  MediaVault
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import CoreFoundation
import FoundationTestSupport
import SnapshotTesting
import Testing
import UIKit

@MainActor
@Suite("Native snapshot scale")
struct NativeSnapshotScaleTests {
    @Test("Native scales keep separate reference identities", arguments: [CGFloat(2), CGFloat(3)])
    func referenceIdentities(_ native: CGFloat) throws {
        let scale = try NativeSnapshotScale.resolve(nativeScale: native, environment: [:])
        #expect(scale.referenceName(nil) == (native == 2 ? nil : "3x"))
        #expect(scale.referenceName("calculator") == (native == 2 ? "calculator" : "calculator-3x"))
    }

    @Test("Unsupported native scales fail instead of choosing a reference", arguments: [CGFloat(0), 1, 2.5, 4])
    func unsupportedScale(_ native: CGFloat) {
        #expect(throws: (any Error).self) {
            try NativeSnapshotScale.resolve(nativeScale: native, environment: [:])
        }
    }

    @Test("Qualification requires an exact expected scale", arguments: ["", "bogus", "2.0", " 3", "4"])
    func invalidExpectedScale(_ expected: String) {
        #expect(throws: (any Error).self) {
            try NativeSnapshotScale.resolve(nativeScale: 3, environment: [
                "NATIVE_SNAPSHOT_QUALIFICATION": "1",
                "NATIVE_SNAPSHOT_EXPECTED_SCALE": expected,
            ])
        }
    }

    @Test("Missing and mismatched qualification values fail")
    func qualificationFailures() {
        for environment in [
            ["NATIVE_SNAPSHOT_QUALIFICATION": "1"],
            ["NATIVE_SNAPSHOT_QUALIFICATION": "0"],
            ["NATIVE_SNAPSHOT_EXPECTED_SCALE": "2"],
        ] {
            #expect(throws: (any Error).self) {
                try NativeSnapshotScale.resolve(nativeScale: 3, environment: environment)
            }
        }
    }

    @Test("Direct runs and valid qualification both use actual native scale")
    func nativeScaleSelection() throws {
        for environment in [[:], ["NATIVE_SNAPSHOT_QUALIFICATION": "1", "NATIVE_SNAPSHOT_EXPECTED_SCALE": "3"]] {
            let scale = try NativeSnapshotScale.resolve(nativeScale: 3, environment: environment)
            #expect(scale.value == 3)
        }
    }

    @Test("Scale override preserves fixture geometry and other traits")
    func preservesFixture() throws {
        let original = DeterministicTestSupport.regularWidthIPad
        let scale = try NativeSnapshotScale.resolve(nativeScale: 3, environment: [:])
        let config = scale.configuration(original)
        #expect(config.size == original.size)
        #expect(config.safeArea == original.safeArea)
        #expect(config.traits.displayScale == 3)
        #expect(config.traits.horizontalSizeClass == original.traits.horizontalSizeClass)
        #expect(config.traits.verticalSizeClass == original.traits.verticalSizeClass)
        #expect(config.traits.userInterfaceIdiom == original.traits.userInterfaceIdiom)
        #expect(config.traits.preferredContentSizeCategory == original.traits.preferredContentSizeCategory)
        #expect(config.traits.layoutDirection == original.traits.layoutDirection)
    }
}
