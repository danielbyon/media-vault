//
// CalculatorKeyboardInputTests.swift
// MediaVault
//
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Testing
@testable import CalculatorFeature

@Suite("Calculator hardware keyboard input")
struct CalculatorKeyboardInputTests {
    @Test("Direct key presses map to the matching calculator button")
    func mapsDirectCalculatorKeys() {
        let cases: [(String, CalculatorButton)] = [
            ("0", .digit(0)), ("1", .digit(1)), ("2", .digit(2)), ("3", .digit(3)),
            ("4", .digit(4)), ("5", .digit(5)), ("6", .digit(6)), ("7", .digit(7)),
            ("8", .digit(8)), ("9", .digit(9)), (".", .decimal), ("+", .add),
            ("-", .subtract), ("*", .multiply), ("/", .divide), ("%", .percent),
            ("(", .openParenthesis), (")", .closeParenthesis), ("=", .equals),
            ("\r", .equals), ("\n", .equals),
        ]

        for (characters, expected) in cases {
            #expect(CalculatorHardwareKeyMapper.button(for: characters) == expected)
        }
    }

    @Test("Delete and Escape map to delete and clear actions")
    func mapsEditingAndClearKeys() {
        #expect(CalculatorHardwareKeyMapper.button(for: "", isDelete: true) == .delete)
        #expect(CalculatorHardwareKeyMapper.button(for: "", isEscape: true) == .clear)
        #expect(CalculatorHardwareKeyMapper.button(for: "x") == nil)
    }
}
