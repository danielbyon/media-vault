//
// CalculatorScientificEditingTests.swift
// MediaVault
//
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
@testable import CalculatorFeature

@Suite("Calculator scientific editing")
struct CalculatorScientificEditingTests {
    @Test("A scientific function starts when the expression awaits an operand")
    func functionStartsAtOperandPosition() {
        var state = state(expression: "2+")

        #expect(CalculatorFeature().apply(.sine, to: &state))
        #expect(state.expression == "2+sin(")
        #expect(state.display == "sin(")
    }

    @Test("A scientific function wraps the current operand")
    func functionWrapsCurrentOperand() {
        var state = state(expression: "2+30")

        #expect(CalculatorFeature().apply(.sine, to: &state))
        #expect(state.expression == "2+sin(30)")
        #expect(state.display == "sin(30)")
    }

    @Test("A scientific function wraps a completed result")
    func functionWrapsCompletedResult() {
        var state = state(expression: "30", display: "30", isShowingResult: true)

        #expect(CalculatorFeature().apply(.squareRoot, to: &state))
        #expect(state.expression == "sqrt(30)")
        #expect(state.display == "sqrt(30)")
        #expect(!state.isShowingResult)
    }

    @Test("Functions can nest while an argument is still required")
    func functionsNestAtOperandPosition() {
        var state = state(expression: "sin(")

        #expect(CalculatorFeature().apply(.cosine, to: &state))
        #expect(state.expression == "sin(cos(")
    }

    @Test("Constants enter only at an operand position")
    func constantsRespectExplicitMultiplication() {
        var waitingState = state(expression: "2+")
        #expect(CalculatorFeature().apply(.pi, to: &waitingState))
        #expect(waitingState.expression == "2+π")

        var activeOperandState = state(expression: "2")
        #expect(!CalculatorFeature().apply(.pi, to: &activeOperandState))
        #expect(activeOperandState.expression == "2")

        var resultState = state(expression: "2", display: "2", isShowingResult: true)
        #expect(CalculatorFeature().apply(.e, to: &resultState))
        #expect(resultState.expression == "e")
        #expect(!resultState.isShowingResult)
    }

    @Test("Constants complete scientific-function and parenthesized operands")
    func constantsCompleteFunctionAndParenthesizedOperands() {
        var sineState = state(expression: "")
        #expect(CalculatorFeature().apply(.sine, to: &sineState))
        #expect(CalculatorFeature().apply(.pi, to: &sineState))
        #expect(CalculatorFeature().apply(.closeParenthesis, to: &sineState))
        #expect(sineState.expression == "sin(π)")

        var squareRootState = state(expression: "")
        #expect(CalculatorFeature().apply(.squareRoot, to: &squareRootState))
        #expect(CalculatorFeature().apply(.e, to: &squareRootState))
        #expect(CalculatorFeature().apply(.closeParenthesis, to: &squareRootState))
        #expect(squareRootState.expression == "sqrt(e)")

        var negativeConstantState = state(expression: "")
        #expect(CalculatorFeature().apply(.openParenthesis, to: &negativeConstantState))
        #expect(CalculatorFeature().apply(.sign, to: &negativeConstantState))
        #expect(CalculatorFeature().apply(.pi, to: &negativeConstantState))
        #expect(CalculatorFeature().apply(.closeParenthesis, to: &negativeConstantState))
        #expect(negativeConstantState.expression == "(-π)")
    }

    @Test("Digits and decimals cannot be appended to constants")
    func constantsRejectAdjacentDigitsAndDecimals() {
        for expression in ["π", "e", "sin(π", "sqrt(e"] {
            var state = state(expression: expression)

            #expect(!CalculatorFeature().apply(.digit(2), to: &state))
            #expect(state.expression == expression)
            #expect(!CalculatorFeature().apply(.decimal, to: &state))
            #expect(state.expression == expression)
        }
    }

    @Test("Explicit operators and scientific functions compose with constants")
    func constantsComposeWithOperatorsAndFunctions() {
        var piState = state(expression: "π")
        #expect(CalculatorFeature().apply(.add, to: &piState))
        #expect(CalculatorFeature().apply(.digit(2), to: &piState))
        #expect(piState.expression == "π+2")
        #expect(CalculatorFeature().apply(.sine, to: &piState))
        #expect(piState.expression == "π+sin(2)")

        var eState = state(expression: "e")
        #expect(CalculatorFeature().apply(.multiply, to: &eState))
        #expect(CalculatorFeature().apply(.digit(3), to: &eState))
        #expect(eState.expression == "e×3")

        var wrappedConstant = state(expression: "e")
        #expect(CalculatorFeature().apply(.squareRoot, to: &wrappedConstant))
        #expect(wrappedConstant.expression == "sqrt(e)")
    }

    @Test("Percent and sign operations preserve explicit constant expressions")
    func constantsComposeWithPercentAndSign() {
        var state = state(expression: "π")

        #expect(CalculatorFeature().apply(.sign, to: &state))
        #expect(state.expression == "-π")
        #expect(CalculatorFeature().apply(.sign, to: &state))
        #expect(state.expression == "π")
        #expect(CalculatorFeature().apply(.percent, to: &state))
        #expect(state.expression == "π%")
        #expect(CalculatorFeature().apply(.add, to: &state))
        #expect(state.expression == "π%+")
    }

    @Test("The angle mode control switches between Degrees and Radians")
    func angleModeControlTogglesPersistedMode() {
        var state = state(expression: "")

        #expect(CalculatorFeature().apply(.toggleAngleMode, to: &state))
        #expect(state.angleMode == .radians)
        #expect(CalculatorFeature().apply(.toggleAngleMode, to: &state))
        #expect(state.angleMode == .degrees)
    }

    private func state(
        expression: String,
        display: String? = nil,
        isShowingResult: Bool = false,
    ) -> CalculatorFeature.State {
        CalculatorFeature.State(
            snapshot: CalculatorSnapshot(
                display: display ?? expression,
                expression: expression,
                isShowingResult: isShowingResult,
            ),
        )
    }
}
