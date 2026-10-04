//
//  CalculatorAdaptiveLayoutTests.swift
//  MediaVault
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import SwiftUI
import Testing
@testable import CalculatorFeature

@Suite("Calculator adaptive layout")
struct CalculatorAdaptiveLayoutTests {
    @Test("Compact and unspecified size classes keep the vertical presentation")
    func compactAndUnspecifiedSizeClassesKeepVerticalPresentation() {
        #expect(
            !CalculatorAdaptiveLayout.usesSideBySideLayout(
                horizontalSizeClass: .compact,
                dynamicTypeSize: .large,
                availableWidth: 900,
            ),
        )
        #expect(
            !CalculatorAdaptiveLayout.usesSideBySideLayout(
                horizontalSizeClass: nil,
                dynamicTypeSize: .large,
                availableWidth: 900,
            ),
        )
    }

    @Test("Regular width uses side-by-side content when it fits")
    func regularWidthUsesSideBySideContentWhenItFits() {
        #expect(
            CalculatorAdaptiveLayout.usesSideBySideLayout(
                horizontalSizeClass: .regular,
                dynamicTypeSize: .large,
                availableWidth: 608,
            ),
        )
    }

    @Test("Narrow geometry and accessibility text sizes use the vertical fallback")
    func regularWidthFallsBackWhenSpaceOrTextSizeRequiresIt() {
        #expect(
            !CalculatorAdaptiveLayout.usesSideBySideLayout(
                horizontalSizeClass: .regular,
                dynamicTypeSize: .large,
                availableWidth: 607,
            ),
        )
        #expect(
            !CalculatorAdaptiveLayout.usesSideBySideLayout(
                horizontalSizeClass: .regular,
                dynamicTypeSize: .accessibility1,
                availableWidth: 900,
            ),
        )
    }
}
