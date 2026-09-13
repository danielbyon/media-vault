//
//  CalculatorFeature+Editing.swift
//  MediaVault
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

extension CalculatorFeature {
    /// Projects digit input through the calculator's ordinary synchronous editing semantics.
    ///
    /// The supplied state is copied before any input is applied. This helper therefore produces a
    /// presentation-only result: it sends no reducer actions, records no history, and schedules no
    /// persistence. The root feature uses it while a hidden credential candidate remains transient.
    public static func projectedPresentation(
        afterDigits digits: String,
        from state: State,
    ) -> CalculatorPresentation {
        var projectedState = state
        let calculator = CalculatorFeature()

        for character in digits {
            guard let asciiValue = character.asciiValue,
                  (48 ... 57).contains(asciiValue)
            else {
                continue
            }

            _ = calculator.apply(.digit(Int(asciiValue - 48)), to: &projectedState)
        }

        return projectedState.presentation
    }

    @discardableResult
    func apply(_ button: CalculatorButton, to state: inout State) -> Bool {
        state.error = nil
        switch button {
        case let .digit(digit):
            return applyDigit(digit, to: &state)
        case .decimal:
            return applyDecimal(to: &state)
        case .add:
            return appendOperator("+", to: &state)
        case .subtract:
            return appendOperator("-", to: &state)
        case .multiply:
            return appendOperator("×", to: &state)
        case .divide:
            return appendOperator("÷", to: &state)
        case .openParenthesis:
            return applyOpenParenthesis(to: &state)
        case .closeParenthesis:
            return applyCloseParenthesis(to: &state)
        case .percent:
            return applyPercent(to: &state)
        case .sign:
            return applySign(to: &state)
        case .equals:
            return applyEquals(to: &state)
        case .clear:
            return applyClear(to: &state)
        case .delete:
            return applyDelete(to: &state)
        case .memoryClear:
            return applyMemoryClear(to: &state)
        case .memoryRecall:
            return applyMemoryRecall(to: &state)
        case .memoryAdd,
             .memorySubtract:
            return applyMemoryOperation(button, to: &state)
        case .copy,
             .paste:
            return false
        case .clearHistory:
            return applyClearHistory(to: &state)
        }
    }

    private func applyDigit(_ digit: Int, to state: inout State) -> Bool {
        guard (0 ... 9).contains(digit) else {
            return false
        }

        prepareForNewInput(&state)
        let token = currentToken(in: state.expression)
        guard token != ")", state.expression.last != "%" else {
            return false
        }

        if token == "0" || token == "-0" {
            let replacement = token == "-0" ? "-\(digit)" : "\(digit)"
            state.expression = replaceCurrentToken(in: state.expression, with: replacement)
        } else {
            state.expression.append("\(digit)")
        }
        state.display = currentToken(in: state.expression)
        return true
    }

    private func applyDecimal(to state: inout State) -> Bool {
        prepareForNewInput(&state)
        let token = currentToken(in: state.expression)
        guard token != ")", state.expression.last != "%", !token.contains(".") else {
            return false
        }

        if token.isEmpty || token == "-" {
            state.expression.append("0.")
        } else {
            state.expression.append(".")
        }
        state.display = currentToken(in: state.expression)
        return true
    }

    private func applyOpenParenthesis(to state: inout State) -> Bool {
        prepareForNewInputIfResultIsBeingShown(&state)
        if state.expression.isEmpty {
            state.expression = "("
            state.display = "("
            return true
        }
        guard let last = state.expression.last,
              operatorCharacters.contains(last) else {
            return false
        }

        state.expression.append("(")
        state.display = "("
        return true
    }

    private func applyCloseParenthesis(to state: inout State) -> Bool {
        guard canCloseParenthesis(in: state.expression) else {
            state.error = .invalidExpression
            return false
        }

        state.expression.append(")")
        state.display = ")"
        return true
    }

    private func applyPercent(to state: inout State) -> Bool {
        if state.expression.isEmpty {
            state.expression = state.display
        }
        guard let last = state.expression.last, !operatorCharacters.contains(last) else {
            state.error = .invalidExpression
            return false
        }

        do {
            state.display = try CalculatorEngine().evaluate(state.expression + "%")
            state.expression.append("%")
            return true
        } catch let error as CalculatorError {
            state.error = error
            return false
        } catch {
            state.error = .invalidExpression
            return false
        }
    }

    private func applySign(to state: inout State) -> Bool {
        if state.isShowingResult {
            state.expression = state.display
            state.isShowingResult = false
        }
        if state.expression.isEmpty {
            state.expression = "-"
            state.display = "-"
            return true
        }
        let token = currentToken(in: state.expression)
        guard token != ")" else {
            return false
        }

        if token.isEmpty {
            state.expression.append("-")
        } else if token.hasPrefix("-") {
            state.expression = replaceCurrentToken(in: state.expression, with: String(token.dropFirst()))
        } else {
            state.expression = replaceCurrentToken(in: state.expression, with: "-" + token)
        }
        state.display = currentToken(in: state.expression)
        if state.display.isEmpty {
            state.display = "0"
        }
        return true
    }

    private func applyEquals(to state: inout State) -> Bool {
        guard !state.isShowingResult else {
            return false
        }

        let source = state.expression.isEmpty ? state.display : state.expression
        guard !source.isEmpty else {
            return false
        }

        do {
            let result = try CalculatorEngine().evaluate(source)
            recordHistory(source: source, result: result, in: &state)
            state.display = result
            state.expression = result
            state.isShowingResult = true
            return true
        } catch let error as CalculatorError {
            state.error = error
            return false
        } catch {
            state.error = .invalidExpression
            return false
        }
    }

    private func applyClear(to state: inout State) -> Bool {
        state.display = "0"
        state.expression = ""
        state.error = nil
        state.isShowingResult = false
        return true
    }

    private func applyDelete(to state: inout State) -> Bool {
        guard !state.isShowingResult else {
            state.display = "0"
            state.expression = ""
            state.isShowingResult = false
            return true
        }
        guard !state.expression.isEmpty else {
            return false
        }

        state.expression.removeLast()
        state.display = currentToken(in: state.expression)
        if state.display.isEmpty {
            state.display = lastOperand(in: state.expression) ?? "0"
        }
        return true
    }

    private func applyMemoryClear(to state: inout State) -> Bool {
        guard state.memory != nil else {
            return false
        }

        state.memory = nil
        return true
    }

    private func applyMemoryRecall(to state: inout State) -> Bool {
        guard let memory = state.memory else {
            return false
        }

        state.display = memory
        state.expression = memory
        state.isShowingResult = false
        return true
    }

    private func applyMemoryOperation(_ button: CalculatorButton, to state: inout State) -> Bool {
        let memory = state.memory ?? "0"
        let operation = button == .memoryAdd ? "+" : "-"
        do {
            let operand = state.display == ")"
                ? try CalculatorEngine().evaluate(state.expression)
                : state.display
            state.memory = try CalculatorEngine().evaluate("\(memory)\(operation)\(operand)")
            return true
        } catch let error as CalculatorError {
            state.error = error
            return false
        } catch {
            state.error = .invalidExpression
            return false
        }
    }

    private func applyClearHistory(to state: inout State) -> Bool {
        guard !state.history.isEmpty else {
            return false
        }

        state.history.removeAll()
        return true
    }

    private func prepareForNewInput(_ state: inout State) {
        prepareForNewInputIfResultIsBeingShown(&state)
        if state.display == "-", state.expression == "-" {
            return
        }
    }

    private func prepareForNewInputIfResultIsBeingShown(_ state: inout State) {
        guard state.isShowingResult else {
            return
        }

        state.display = "0"
        state.expression = ""
        state.isShowingResult = false
    }

    private func appendOperator(_ symbol: Character, to state: inout State) -> Bool {
        if state.expression.isEmpty {
            state.expression = state.display
        }
        guard !state.expression.isEmpty else {
            return false
        }

        if state.isShowingResult {
            state.isShowingResult = false
        }
        if state.expression.last == "(" {
            guard symbol == "-" else {
                return false
            }
        }

        if let last = state.expression.last, operatorCharacters.contains(last) {
            if last == "-", isTrailingUnaryMinus(in: state.expression) {
                return false
            }
            if symbol == "-" {
                state.expression.append(symbol)
            } else {
                state.expression.removeLast()
                state.expression.append(symbol)
            }
        } else {
            state.expression.append(symbol)
        }
        return true
    }

    private func isTrailingUnaryMinus(in expression: String) -> Bool {
        guard expression.last == "-" else {
            return false
        }

        let index = expression.index(before: expression.endIndex)
        return isUnaryMinus(at: index, in: expression)
    }

    private func isUnaryMinus(at index: String.Index, in expression: String) -> Bool {
        guard expression[index] == "-" else {
            return false
        }

        return index == expression.startIndex
            || operatorCharacters.contains(expression[expression.index(before: index)])
    }

    private func canCloseParenthesis(in expression: String) -> Bool {
        var balance = 0
        for character in expression {
            if character == "(" {
                balance += 1
            } else if character == ")" {
                balance -= 1
                if balance < 0 {
                    return false
                }
            }
        }

        guard balance > 0, let last = expression.last else {
            return false
        }
        guard !operatorCharacters.contains(last), last != "(" else {
            return false
        }

        return last.isNumber || last == ")" || last == "%"
    }

    private func currentToken(in expression: String) -> String {
        if expression.last == ")" {
            return ")"
        }
        guard let index = expression.lastIndex(where: { operatorCharacters.contains($0) }) else {
            return expression
        }

        if isUnaryMinus(at: index, in: expression) {
            return String(expression[index...])
        }
        return String(expression[expression.index(after: index)...])
    }

    private func lastOperand(in expression: String) -> String? {
        let tokens = expression.split(whereSeparator: { operatorCharacters.contains($0) })
        return tokens.last.map(String.init)
    }

    private func replaceCurrentToken(in expression: String, with token: String) -> String {
        guard let index = expression.lastIndex(where: { operatorCharacters.contains($0) }) else {
            return token
        }

        if isUnaryMinus(at: index, in: expression) {
            return String(expression[..<index]) + token
        }
        let end = expression.index(after: index)
        return String(expression[..<end]) + token
    }

    private var operatorCharacters: Set<Character> {
        ["+", "−", "-", "×", "÷", "*", "/", "("]
    }
}
