//
//  CalculatorEngine.swift
//  MediaVault
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

/// Evaluates calculator expressions.
public struct CalculatorEngine: Sendable {
    private let roundingScale: Int

    /// Creates an evaluator with deterministic decimal rounding.
    ///
    /// The result is rounded after each arithmetic operation and again before it is displayed. The
    /// scale is intentionally an implementation parameter rather than part of the calculator's
    /// public state so a later scientific mode can add richer numeric behavior without changing the
    /// feature's reducer or persistence interfaces.
    public init(roundingScale: Int = 10) {
        self.roundingScale = max(0, roundingScale)
    }

    /// Evaluates core calculator syntax and returns its stable display representation.
    public func evaluate(_ expression: String) throws -> String {
        var parser = Parser(expression: expression, roundingScale: roundingScale)
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
        private let characters: [Character]
        private var index = 0
        private let roundingScale: Int

        init(expression: String, roundingScale: Int) {
            characters = Array(expression)
            self.roundingScale = roundingScale
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
            var value = try parsePostfix()

            while true {
                skipWhitespace()
                if consume("×") || consume("*") {
                    value = try rounded(multiplying: value, parsePostfix())
                } else if consume("÷") || consume("/") {
                    value = try rounded(dividing: value, parsePostfix())
                } else {
                    return value
                }
            }
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

            if consume("+") {
                return try parsePrimary()
            }
            if consume("−") || consume("-") {
                return try rounded(subtracting: 0, parsePrimary())
            }
            if consume("(") {
                let value = try parseExpression()
                skipWhitespace()
                guard consume(")") else {
                    throw CalculatorError.invalidExpression
                }

                return value
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

        private mutating func skipWhitespace() {
            while !isAtEnd, characters[index].isWhitespace {
                index += 1
            }
        }

        private mutating func consume(_ character: Character) -> Bool {
            guard !isAtEnd, characters[index] == character else {
                return false
            }

            index += 1
            return true
        }

        private var isAtEnd: Bool {
            index == characters.count
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

            var resultToRound = result
            NSDecimalRound(&result, &resultToRound, roundingScale, .plain)
            return result
        }
    }
}

/// Errors produced by the issue #3 calculator evaluator.
public enum CalculatorError: Error, Equatable, Sendable {
    /// The input does not form a complete calculator expression.
    case invalidExpression

    /// The expression attempted to divide by zero.
    case divisionByZero

    /// A decimal operation exceeded the supported precision.
    case overflow
}
