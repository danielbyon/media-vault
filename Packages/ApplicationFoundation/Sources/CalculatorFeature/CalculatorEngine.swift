//
// CalculatorEngine.swift
// MediaVault
//
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

/// Evaluates calculator expressions with deterministic decimal rounding.
public struct CalculatorEngine: Sendable {
    private let roundingScale: Int

    /// Creates an evaluator that rounds arithmetic results to a stable display scale.
    ///
    /// - Parameter roundingScale: The number of fractional decimal places retained after each
    ///   operation and before the result is displayed.
    public init(roundingScale: Int = 10) {
        self.roundingScale = max(0, roundingScale)
    }

    /// Evaluates an expression using the selected angle mode for trigonometric functions.
    ///
    /// - Parameters:
    ///   - expression: The calculator expression to evaluate.
    ///   - angleMode: The angle unit used by direct and inverse trigonometric functions.
    /// - Returns: A stable decimal string suitable for the calculator display.
    public func evaluate(
        _ expression: String,
        angleMode: CalculatorAngleMode = .degrees,
    ) throws -> String {
        var parser = Parser(
            expression: expression,
            roundingScale: roundingScale,
            angleMode: angleMode,
        )
        return try format(parser.parse())
    }

    private func format(_ value: Decimal) -> String {
        var rounded = value
        var valueToRound = rounded
        NSDecimalRound(&rounded, &valueToRound, roundingScale, .plain)
        if rounded == 0 {
            rounded = 0
        }
        return rounded.description
    }

    private struct Parser {
        private enum Function: String, CaseIterable {
            case sine = "sin"
            case cosine = "cos"
            case tangent = "tan"
            case arcSine = "asin"
            case arcCosine = "acos"
            case arcTangent = "atan"
            case naturalLogarithm = "ln"
            case commonLogarithm = "log10"
            case squareRoot = "sqrt"
            case square
            case reciprocal
        }

        private let characters: [Character]
        private var index = 0
        private let roundingScale: Int
        private let angleMode: CalculatorAngleMode

        init(expression: String, roundingScale: Int, angleMode: CalculatorAngleMode) {
            characters = Array(expression)
            self.roundingScale = roundingScale
            self.angleMode = angleMode
        }

        mutating func parse() throws -> Decimal {
            skipWhitespace()
            guard !isAtEnd else {
                throw CalculatorError.invalidExpression
            }

            let value = try parseExpression()
            skipWhitespace()
            guard isAtEnd else {
                throw CalculatorError.invalidExpression
            }
            return value
        }

        private mutating func parseExpression() throws -> Decimal {
            var value = try parseTerm()

            while true {
                skipWhitespace()
                if consume("+") {
                    value = try rounded(adding: value, parseTerm())
                } else if consume("−") || consume("-") {
                    value = try rounded(subtracting: value, parseTerm())
                } else {
                    return value
                }
            }
        }

        private mutating func parseTerm() throws -> Decimal {
            var value = try parseUnary()

            while true {
                skipWhitespace()
                if consume("×") || consume("*") {
                    value = try rounded(multiplying: value, parseUnary())
                } else if consume("÷") || consume("/") {
                    value = try rounded(dividing: value, parseUnary())
                } else {
                    return value
                }
            }
        }

        /// Unary signs apply after exponentiation, while the exponent may itself be signed.
        private mutating func parseUnary() throws -> Decimal {
            skipWhitespace()
            if consume("+") {
                return try parseUnary()
            }
            if consume("−") || consume("-") {
                return try negateExactly(parseUnary())
            }
            return try parsePower()
        }

        private func negateExactly(_ value: Decimal) throws -> Decimal {
            var zero: Decimal = 0
            var value = value
            var result = Decimal()
            let error = NSDecimalSubtract(&result, &zero, &value, .plain)
            guard error == .noError else {
                throw CalculatorError.overflow
            }
            return result
        }

        /// Parses exponentiation recursively on its right side so chained powers associate right.
        private mutating func parsePower() throws -> Decimal {
            let base = try parsePostfix()
            skipWhitespace()
            guard consume("^") else {
                return base
            }
            return try rounded(powering: base, parseUnary())
        }

        private mutating func parsePostfix() throws -> Decimal {
            var value = try parsePrimary()
            while true {
                skipWhitespace()
                guard consume("%") else {
                    return value
                }
                value = try rounded(dividing: value, 100)
            }
        }

        private mutating func parsePrimary() throws -> Decimal {
            skipWhitespace()

            if consume("(") {
                let value = try parseExpression()
                skipWhitespace()
                guard consume(")") else {
                    throw CalculatorError.invalidExpression
                }
                return value
            }

            for function in Function.allCases where consume(function.rawValue) {
                skipWhitespace()
                guard consume("(") else {
                    throw CalculatorError.invalidExpression
                }
                let argument = try parseExpression()
                skipWhitespace()
                guard consume(")") else {
                    throw CalculatorError.invalidExpression
                }
                return try apply(function, to: argument)
            }

            if consume("π") {
                return try decimal("3.141592653589793238462643383")
            }
            if consume("e") {
                return try decimal("2.718281828459045235360287471")
            }
            return try parseNumber()
        }

        private mutating func parseNumber() throws -> Decimal {
            skipWhitespace()
            let start = index
            var decimalSeparatorSeen = false

            while !isAtEnd {
                let character = characters[index]
                if character.isNumber {
                    index += 1
                } else if character == ".", !decimalSeparatorSeen {
                    decimalSeparatorSeen = true
                    index += 1
                } else {
                    break
                }
            }

            guard index > start else {
                throw CalculatorError.invalidExpression
            }

            let literal = String(characters[start ..< index])
            guard let number = Decimal(string: literal, locale: Locale(identifier: "en_US_POSIX")) else {
                throw CalculatorError.invalidExpression
            }
            return number
        }

        private mutating func apply(_ function: Function, to argument: Decimal) throws -> Decimal {
            switch function {
            case .arcSine, .arcCosine:
                guard argument >= -1, argument <= 1 else {
                    throw CalculatorError.domainError
                }
            default:
                break
            }

            let value = NSDecimalNumber(decimal: argument).doubleValue
            switch function {
            case .sine:
                let input = try trigonometricArgument(from: argument)
                return try decimal(Foundation.sin(radians(from: input)))
            case .cosine:
                let input = try trigonometricArgument(from: argument)
                return try decimal(Foundation.cos(radians(from: input)))
            case .tangent:
                let input = try trigonometricArgument(from: argument)
                let angle = radians(from: input)
                guard !isTangentPole(input) else {
                    throw CalculatorError.domainError
                }
                return try decimal(Foundation.tan(angle))
            case .arcSine:
                return try decimal(angleMode.fromRadians(Foundation.asin(value)))
            case .arcCosine:
                return try decimal(angleMode.fromRadians(Foundation.acos(value)))
            case .arcTangent:
                return try decimal(angleMode.fromRadians(Foundation.atan(value)))
            case .naturalLogarithm:
                guard value > 0 else {
                    throw CalculatorError.domainError
                }
                return try decimal(Foundation.log(value))
            case .commonLogarithm:
                guard value > 0 else {
                    throw CalculatorError.domainError
                }
                return try decimal(Foundation.log10(value))
            case .squareRoot:
                guard value >= 0 else {
                    throw CalculatorError.domainError
                }
                return try decimal(Foundation.sqrt(value))
            case .square:
                return try rounded(multiplying: argument, argument)
            case .reciprocal:
                return try rounded(dividing: 1, argument)
            }
        }

        private func radians(from value: Double) -> Double {
            angleMode == .degrees ? value * .pi / 180 : value
        }

        /// Reduces degree inputs before Double conversion so large angles retain their phase.
        private func trigonometricArgument(from value: Decimal) throws -> Double {
            guard angleMode == .degrees else {
                return NSDecimalNumber(decimal: value).doubleValue
            }

            return NSDecimalNumber(decimal: try reducedDegrees(from: value)).doubleValue
        }

        /// Reduces whole-degree digits modulo 360 while preserving the fractional digits.
        private func reducedDegrees(from value: Decimal) throws -> Decimal {
            var value = value
            let text = NSDecimalString(&value, Locale(identifier: "en_US_POSIX"))
            let isNegative = text.first == "-"
            let unsignedText = isNegative ? String(text.dropFirst()) : text
            let components = unsignedText.split(separator: ".", omittingEmptySubsequences: false)
            guard components.count <= 2 else {
                throw CalculatorError.overflow
            }

            var integerRemainder = 0
            for digit in components.first ?? "0" {
                guard let value = digit.wholeNumberValue else {
                    throw CalculatorError.overflow
                }
                integerRemainder = (integerRemainder * 10 + value) % 360
            }

            let fraction = components.count == 2 ? String(components[1]) : ""
            let sign = isNegative ? "-" : ""
            let reducedText = sign + String(integerRemainder)
                + (fraction.isEmpty ? "" : "." + fraction)
            guard let reduced = Decimal(string: reducedText, locale: Locale(identifier: "en_US_POSIX")) else {
                throw CalculatorError.overflow
            }
            return reduced
        }

        /// Uses a 1e-9-unit angular tolerance to account for Double rounding near a pole.
        private func isTangentPole(_ value: Double) -> Bool {
            let reduced: Double
            let pole: Double
            switch angleMode {
            case .degrees:
                reduced = value.truncatingRemainder(dividingBy: 180)
                pole = 90
            case .radians:
                reduced = value.truncatingRemainder(dividingBy: .pi)
                pole = .pi / 2
            }
            return abs(abs(reduced) - pole) <= 1e-9
        }

        private func decimal(_ value: Double) throws -> Decimal {
            guard value.isFinite else {
                throw CalculatorError.overflow
            }
            let result = Decimal(value)
            guard !result.isNaN else {
                throw CalculatorError.overflow
            }
            return try rounded(result)
        }

        private func decimal(_ literal: String) throws -> Decimal {
            guard let value = Decimal(string: literal, locale: Locale(identifier: "en_US_POSIX")) else {
                throw CalculatorError.overflow
            }
            return value
        }

        private func rounded(adding lhs: Decimal, _ rhs: Decimal) throws -> Decimal {
            try rounded(NSDecimalAdd, lhs, rhs)
        }

        private func rounded(subtracting lhs: Decimal, _ rhs: Decimal) throws -> Decimal {
            try rounded(NSDecimalSubtract, lhs, rhs)
        }

        private func rounded(multiplying lhs: Decimal, _ rhs: Decimal) throws -> Decimal {
            try rounded(NSDecimalMultiply, lhs, rhs)
        }

        private func rounded(dividing lhs: Decimal, _ rhs: Decimal) throws -> Decimal {
            guard rhs != 0 else {
                throw CalculatorError.divisionByZero
            }
            return try rounded(NSDecimalDivide, lhs, rhs)
        }

    private func rounded(powering base: Decimal, _ exponent: Decimal) throws -> Decimal {
        if base == 0, exponent == 0 {
            throw CalculatorError.domainError
            }
            if base == 0, exponent < 0 {
                throw CalculatorError.divisionByZero
            }
        var integralExponent = exponent
        var exponentToRound = exponent
        NSDecimalRound(&integralExponent, &exponentToRound, 0, .plain)
        guard integralExponent == exponent else {
            guard base >= 0 else {
                throw CalculatorError.domainError
            }

            let result = Foundation.pow(
                NSDecimalNumber(decimal: base).doubleValue,
                NSDecimalNumber(decimal: exponent).doubleValue,
            )
            return try decimal(result)
        }

        return try rounded(integralPower: base, exponent: integralExponent)
    }

    private func rounded(integralPower base: Decimal, exponent: Decimal) throws -> Decimal {
        let exponentIsNegative = exponent < 0
        var remaining = exponentIsNegative ? -exponent : exponent
        var factor = base
        var result: Decimal = 1

        while remaining > 0 {
            // Exponent bookkeeping must stay independent of the configured result scale.
            let half = remaining / 2
            var integralHalf = Decimal()
            var halfToRound = half
            NSDecimalRound(&integralHalf, &halfToRound, 0, .down)

            let remainder = remaining - integralHalf * 2
            if remainder != 0 {
                result = try rounded(multiplying: result, factor)
            }

            remaining = integralHalf
            if remaining > 0 {
                factor = try rounded(multiplying: factor, factor)
            }
        }

        if exponentIsNegative {
            return try rounded(dividing: 1, result)
        }
        return try rounded(result)
    }

        private func rounded(_ value: Decimal) throws -> Decimal {
            var result = value
            var valueToRound = result
            NSDecimalRound(&result, &valueToRound, roundingScale, .plain)
            return result
        }

        private func rounded(
            _ operation: (
                UnsafeMutablePointer<Decimal>,
                UnsafePointer<Decimal>,
                UnsafePointer<Decimal>,
                Decimal.RoundingMode,
            ) -> Decimal.CalculationError,
            _ lhs: Decimal,
            _ rhs: Decimal,
        ) throws -> Decimal {
            var result = Decimal()
            var left = lhs
            var right = rhs
            let error = operation(&result, &left, &right, .plain)
            guard error == .noError else {
                throw CalculatorError.overflow
            }
            return try rounded(result)
        }

        private mutating func consume(_ token: String) -> Bool {
            let tokenCharacters = Array(token)
            guard characters.count - index >= tokenCharacters.count,
                  Array(characters[index ..< index + tokenCharacters.count]) == tokenCharacters
            else {
                return false
            }
            index += tokenCharacters.count
            return true
        }

        private mutating func skipWhitespace() {
            while !isAtEnd, characters[index].isWhitespace {
                index += 1
            }
        }

        private var isAtEnd: Bool {
            index == characters.count
        }
    }
}

/// Errors produced when calculator input cannot be evaluated.
public enum CalculatorError: Error, Equatable, Sendable {
    /// The input does not form a complete calculator expression.
    case invalidExpression

    /// The expression attempted to divide by zero.
    case divisionByZero

    /// The expression is outside the mathematical domain of an operation.
    case domainError

    /// A decimal operation exceeded the evaluator's supported precision.
    case overflow
}
