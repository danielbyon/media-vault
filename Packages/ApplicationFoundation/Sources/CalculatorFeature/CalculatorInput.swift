//
//  CalculatorInput.swift
//  MediaVault
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//

/// A calculator surface input before it is dispatched to the calculator reducer.
///
/// The input seam lets the composition root add interaction policy without coupling the calculator
/// to that policy's domain. Touch and direct hardware-key actions share ``button(_:)``; the equals
/// long-press event remains separate so it cannot also become an equals action.
public enum CalculatorInput: Equatable, Sendable {
    /// A persistence retry request that can still cancel an active input policy.
    case retryPersistence

    /// A normal calculator button interaction.
    case button(CalculatorButton)

    /// A long press of the equals control.
    case longPressEquals
}

enum CalculatorHardwareKeyMapper {
    /// Maps a direct hardware key press to the calculator action used by touch controls.
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

        if characters.count == 1,
           let character = characters.first,
           let asciiValue = character.asciiValue,
           (48 ... 57).contains(asciiValue) {
            return .digit(Int(asciiValue - 48))
        }

        switch characters {
        case ".": return .decimal
        case "+": return .add
        case "-": return .subtract
        case "*": return .multiply
        case "/": return .divide
        case "%": return .percent
        case "(": return .openParenthesis
        case ")": return .closeParenthesis
        case "=", "\r", "\n": return .equals
        default: return nil
        }
    }
}
