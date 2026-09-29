//
// CalculatorAdaptiveLayoutTests.swift
// MediaVault
//
// SPDX-License-Identifier: GPL-3.0-or-later
//

import SwiftUI
import Testing
@testable import CalculatorFeature

@Suite("Calculator adaptive keypad layout")
struct CalculatorAdaptiveLayoutTests {
    @Test("Compact and unspecified size classes keep the basic keypad")
    func compactAndUnspecifiedSizeClassesKeepBasicKeypad() {
        #expect(CalculatorAdaptiveLayout.keypadSelection(forHorizontalSizeClass: .compact) == .basic)
        #expect(CalculatorAdaptiveLayout.keypadSelection(forHorizontalSizeClass: nil) == .basic)
    }

    @Test("Regular size classes select the scientific keypad")
    func regularSizeClassSelectsScientificKeypad() {
        #expect(CalculatorAdaptiveLayout.keypadSelection(forHorizontalSizeClass: .regular) == .scientific)
    }

    @Test("Every scientific control exposes an accessibility label")
    func scientificControlsHaveAccessibilityLabels() {
        #expect(ScientificKey.all.count == 15)
        #expect(ScientificKey.all.allSatisfy { !$0.accessibilityLabel.isEmpty })
        #expect(ScientificKey.all.contains { $0.button == .toggleAngleMode })
    }
}
