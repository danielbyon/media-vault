//
//  CalculatorAdaptiveLayout.swift
//  MediaVault
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import SwiftUI

/// Selects the calculator layout that fits the available width and text size.
enum CalculatorAdaptiveLayout {
    private static let minimumCalculatorColumnWidth: CGFloat = 320
    private static let minimumSupportingColumnWidth: CGFloat = 240
    private static let columnSpacing: CGFloat = 16
    private static let horizontalPadding: CGFloat = 32

    static func usesSideBySideLayout(
        horizontalSizeClass: UserInterfaceSizeClass?,
        dynamicTypeSize: DynamicTypeSize,
        availableWidth: CGFloat,
    ) -> Bool {
        horizontalSizeClass == .regular
            && !dynamicTypeSize.isAccessibilitySize
            && availableWidth >= minimumCalculatorColumnWidth
            + minimumSupportingColumnWidth
            + columnSpacing
            + horizontalPadding
    }
}

/// Maps supported hardware keys to the calculator's existing touch actions.
enum CalculatorHardwareKeyMapper {
    static func button(
        for characters: String,
        isDelete: Bool = false,
        isEscape: Bool = false,
    ) -> CalculatorButton? {
        if isDelete {
            return .delete
        }
        if isEscape {
            return .clear
        }

        return switch characters {
        case "0":
            .digit(0)
        case "1":
            .digit(1)
        case "2":
            .digit(2)
        case "3":
            .digit(3)
        case "4":
            .digit(4)
        case "5":
            .digit(5)
        case "6":
            .digit(6)
        case "7":
            .digit(7)
        case "8":
            .digit(8)
        case "9":
            .digit(9)
        case ".":
            .decimal
        case "+":
            .add
        case "-":
            .subtract
        case "*":
            .multiply
        case "/":
            .divide
        case "%":
            .percent
        case "(":
            .openParenthesis
        case ")":
            .closeParenthesis
        case "=",
             "\r",
             "\n":
            .equals
        default:
            nil
        }
    }

    /// Leaves Return and Space available to activate a focused non-keypad control.
    static func shouldDeferNativeActivation(
        for characters: String,
        focusedControlIsNonKeypad: Bool,
    ) -> Bool {
        focusedControlIsNonKeypad && [" ", "\r", "\n"].contains(characters)
    }
}
