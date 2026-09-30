//
//  CalculatorEngine.swift
//  MediaVault
//
//  SPDX-License-Identifier: GPL-3.0-or-later
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

        private typealias DecimalOperation = (
            UnsafeMutablePointer<Decimal>,
            UnsafePointer<Decimal>,
            UnsafePointer<Decimal>,
            Decimal.RoundingMode,
        ) -> Decimal.CalculationError

        /// Keeps normal calculator results separate from values used only for domain classification.
        private struct ParsedValue {
            let value: Decimal
            let unroundedValue: Decimal?
            let angleProvenance: AngleProvenance?

            static func scalar(_ value: Decimal) -> Self {
                Self(
                    value: value,
                    unroundedValue: value,
                    angleProvenance: AngleProvenance(constant: value, piCoefficient: 0),
                )
            }
        }

        /// Tracks source expressions as `constant + coefficient × π` for exact Radian pole checks.
        private struct AngleProvenance {
            let constant: Decimal
            let piCoefficient: Decimal
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

            return value.value
        }

        private mutating func parseExpression() throws -> ParsedValue {
            var value = try parseTerm()

            while true {
                skipWhitespace()
                if consume("+") {
                    let right = try parseTerm()
                    value = ParsedValue(
                        value: try rounded(adding: value.value, right.value),
                        unroundedValue: unrounded(NSDecimalAdd, value.unroundedValue, right.unroundedValue),
                        angleProvenance: combinedAngleProvenance(
                            value.angleProvenance,
                            right.angleProvenance,
                        ),
                    )
                } else if consume("−") || consume("-") {
                    let right = try parseTerm()
                    value = ParsedValue(
                        value: try rounded(subtracting: value.value, right.value),
                        unroundedValue: unrounded(NSDecimalSubtract, value.unroundedValue, right.unroundedValue),
                        angleProvenance: combinedAngleProvenance(
                            value.angleProvenance,
                            right.angleProvenance,
                            subtracting: true,
                        ),
                    )
                } else {
                    return value
                }
            }
        }

        private mutating func parseTerm() throws -> ParsedValue {
            var value = try parseUnary()

            while true {
                skipWhitespace()
                if consume("×") || consume("*") {
                    let right = try parseUnary()
                    value = ParsedValue(
                        value: try rounded(multiplying: value.value, right.value),
                        unroundedValue: unrounded(NSDecimalMultiply, value.unroundedValue, right.unroundedValue),
                        angleProvenance: multipliedAngleProvenance(value.angleProvenance, right.angleProvenance),
                    )
                } else if consume("÷") || consume("/") {
                    let right = try parseUnary()
                    value = ParsedValue(
                        value: try rounded(dividing: value.value, right.value),
                        unroundedValue: unrounded(NSDecimalDivide, value.unroundedValue, right.unroundedValue),
                        angleProvenance: dividedAngleProvenance(value.angleProvenance, right.angleProvenance),
                    )
                } else {
                    return value
                }
            }
        }

        /// Unary signs apply after exponentiation, while the exponent may itself be signed.
        private mutating func parseUnary() throws -> ParsedValue {
            skipWhitespace()
            if consume("+") {
                return try parseUnary()
            }
            if consume("−") || consume("-") {
                let operand = try parseUnary()
                return ParsedValue(
                    value: try negateExactly(operand.value),
                    unroundedValue: negated(operand.unroundedValue),
                    angleProvenance: negated(operand.angleProvenance),
                )
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
        private mutating func parsePower() throws -> ParsedValue {
            let base = try parsePostfix()
            skipWhitespace()
            guard consume("^") else {
                return base
            }

            let exponent = try parseUnary()
            return ParsedValue(
                value: try rounded(powering: base.value, exponent.value),
                unroundedValue: unroundedIntegralPower(
                    base: base.unroundedValue,
                    exponent: exponent.unroundedValue,
                ),
                angleProvenance: nil,
            )
        }

        private mutating func parsePostfix() throws -> ParsedValue {
            var value = try parsePrimary()
            while true {
                skipWhitespace()
                guard consume("%") else {
                    return value
                }

                value = ParsedValue(
                    value: try rounded(dividing: value.value, 100),
                    unroundedValue: unrounded(NSDecimalDivide, value.unroundedValue, 100),
                    angleProvenance: scaledAngleProvenance(value.angleProvenance, by: 100, dividing: true),
                )
            }
        }

        private mutating func parsePrimary() throws -> ParsedValue {
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

                let value = try apply(
                    function,
                    to: argument.value,
                    unroundedValue: argument.unroundedValue,
                    angleProvenance: argument.angleProvenance,
                )
                return ParsedValue(
                    value: value,
                    unroundedValue: unroundedFunctionResult(function, argument: argument.unroundedValue),
                    angleProvenance: nil,
                )
            }

            if consume("π") {
                let value = try decimal("3.141592653589793238462643383")
                return ParsedValue(
                    value: value,
                    unroundedValue: value,
                    angleProvenance: AngleProvenance(constant: 0, piCoefficient: 1),
                )
            }
            if consume("e") {
                return .scalar(try decimal("2.718281828459045235360287471"))
            }
            return .scalar(try parseNumber())
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

        private mutating func apply(
            _ function: Function,
            to argument: Decimal,
            unroundedValue: Decimal?,
            angleProvenance: AngleProvenance?,
        ) throws -> Decimal {
            switch function {
            case .arcSine,
                 .arcCosine:
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
                guard try !isTangentPole(
                    unroundedValue: unroundedValue,
                    angleProvenance: angleProvenance,
                ) else {
                    throw CalculatorError.domainError
                }

                let input = try trigonometricArgument(from: argument)
                let angle = radians(from: input)
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
                return try rounded(squareRootOf: argument)
            case .square:
                return try rounded(multiplying: argument, argument)
            case .reciprocal:
                return try rounded(dividing: 1, argument)
            }
        }

        private func unroundedFunctionResult(_ function: Function, argument: Decimal?) -> Decimal? {
            guard let argument else {
                return nil
            }

            switch function {
            case .square:
                return try? unrounded(NSDecimalMultiply, argument, argument)
            case .reciprocal:
                return try? unrounded(NSDecimalDivide, 1, argument)
            default:
                return nil
            }
        }

        private func radians(from value: Double) -> Double {
            angleMode == .degrees ? value * .pi / 180 : value
        }

        /// Reduces degree inputs before Double conversion so large angles retain their phase.
        private func trigonometricArgument(from value: Decimal) throws -> Double {
            let reduced: Decimal =
                switch angleMode {
                case .degrees:
                    try reducedDegrees(from: value)
                case .radians:
                    try reducedRadians(from: value)
                }
            return NSDecimalNumber(decimal: reduced).doubleValue
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

        /// Reduces an angle modulo two pi while keeping its Decimal remainder small.
        ///
        /// Processing the integer digits one at a time avoids multiplying a very large
        /// quotient by the period, which could erase the low-order phase at Decimal precision.
        /// This control arithmetic intentionally does not use the calculator display scale.
        private func reducedRadians(from value: Decimal) throws -> Decimal {
            let period = try decimal("3.141592653589793238462643383") * 2
            return try reducedRadians(from: value, modulo: period)
        }

        /// Reduces an angle with Decimal arithmetic and does not apply display rounding.
        private func reducedRadians(from value: Decimal, modulo period: Decimal) throws -> Decimal {
            var decimalValue = value
            let text = NSDecimalString(&decimalValue, Locale(identifier: "en_US_POSIX"))
            let isNegative = text.first == "-"
            let unsignedText = isNegative ? String(text.dropFirst()) : text
            let components = unsignedText.split(separator: ".", omittingEmptySubsequences: false)
            guard components.count <= 2 else {
                throw CalculatorError.overflow
            }

            var remainder: Decimal = 0
            for character in components.first ?? "0" {
                guard let digit = character.wholeNumberValue else {
                    throw CalculatorError.overflow
                }

                remainder = remainder * 10 + Decimal(digit)
                while remainder >= period {
                    remainder -= period
                }
            }

            let fraction = components.count == 2 ? String(components[1]) : ""
            if !fraction.isEmpty {
                remainder += try decimal("0." + fraction)
                if remainder >= period {
                    remainder -= period
                }
            }

            return isNegative ? -remainder : remainder
        }

        /// Detects exact tangent poles while keeping nearby Decimal angles finite.
        ///
        /// The parser rounds arithmetic at the calculator's display scale, so this also recognizes
        /// the rounded π/2 value produced by `tan(π/2)` and its periodic equivalents.
        private func isTangentPole(
            unroundedValue: Decimal?,
            angleProvenance: AngleProvenance?,
        ) throws -> Bool {
            switch angleMode {
            case .degrees:
                guard let angle = unroundedValue else {
                    return false
                }

                var reduced = try reducedDegrees(from: angle)
                while reduced >= 180 {
                    reduced = try unrounded(NSDecimalSubtract, reduced, 180)
                }
                while reduced <= -180 {
                    reduced = try unrounded(NSDecimalAdd, reduced, 180)
                }

                let magnitude = reduced < 0 ? -reduced : reduced
                return magnitude == 90
            case .radians:
                guard let angleProvenance,
                      angleProvenance.constant == 0,
                      let doubledCoefficient = try? unrounded(
                          NSDecimalMultiply,
                          angleProvenance.piCoefficient,
                          2,
                      )
                else {
                    return false
                }

                return isOddInteger(doubledCoefficient)
            }
        }

        /// Returns true only when a Decimal is exactly an odd integer.
        private func isOddInteger(_ value: Decimal) -> Bool {
            var integralValue = Decimal()
            var valueToRound = value
            NSDecimalRound(&integralValue, &valueToRound, 0, .plain)
            guard integralValue == value,
                  let half = try? unrounded(NSDecimalDivide, value, 2)
            else {
                return false
            }

            var roundedHalf = Decimal()
            var halfToRound = half
            NSDecimalRound(&roundedHalf, &halfToRound, 0, .plain)
            return roundedHalf != half
        }

        private func unrounded(_ operation: DecimalOperation, _ lhs: Decimal?, _ rhs: Decimal?) -> Decimal? {
            guard let lhs, let rhs else {
                return nil
            }

            return try? unrounded(operation, lhs, rhs)
        }

        private func combinedAngleProvenance(
            _ lhs: AngleProvenance?,
            _ rhs: AngleProvenance?,
            subtracting: Bool = false,
        ) -> AngleProvenance? {
            guard let lhs, let rhs else {
                return nil
            }

            let operation: DecimalOperation
            if subtracting {
                operation = NSDecimalSubtract
            } else {
                operation = NSDecimalAdd
            }
            guard let constant = try? unrounded(operation, lhs.constant, rhs.constant),
                  let piCoefficient = try? unrounded(operation, lhs.piCoefficient, rhs.piCoefficient)
            else {
                return nil
            }

            return AngleProvenance(constant: constant, piCoefficient: piCoefficient)
        }

        private func multipliedAngleProvenance(
            _ lhs: AngleProvenance?,
            _ rhs: AngleProvenance?,
        ) -> AngleProvenance? {
            guard let lhs, let rhs else {
                return nil
            }

            if lhs.piCoefficient == 0 {
                return scaledAngleProvenance(rhs, by: lhs.constant)
            }
            if rhs.piCoefficient == 0 {
                return scaledAngleProvenance(lhs, by: rhs.constant)
            }

            return nil
        }

        private func dividedAngleProvenance(
            _ numerator: AngleProvenance?,
            _ denominator: AngleProvenance?,
        ) -> AngleProvenance? {
            guard let numerator,
                  let denominator,
                  denominator.piCoefficient == 0
            else {
                return nil
            }

            return scaledAngleProvenance(numerator, by: denominator.constant, dividing: true)
        }

        private func scaledAngleProvenance(
            _ provenance: AngleProvenance?,
            by factor: Decimal,
            dividing: Bool = false,
        ) -> AngleProvenance? {
            guard let provenance else {
                return nil
            }

            let operation: DecimalOperation
            if dividing {
                operation = NSDecimalDivide
            } else {
                operation = NSDecimalMultiply
            }
            guard let constant = try? unrounded(operation, provenance.constant, factor),
                  let piCoefficient = try? unrounded(operation, provenance.piCoefficient, factor)
            else {
                return nil
            }

            return AngleProvenance(constant: constant, piCoefficient: piCoefficient)
        }

        private func negated(_ value: Decimal?) -> Decimal? {
            guard let value else {
                return nil
            }

            return try? unrounded(NSDecimalSubtract, 0, value)
        }

        private func negated(_ provenance: AngleProvenance?) -> AngleProvenance? {
            guard let provenance,
                  let constant = negated(provenance.constant),
                  let piCoefficient = negated(provenance.piCoefficient)
            else {
                return nil
            }

            return AngleProvenance(constant: constant, piCoefficient: piCoefficient)
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
            try rounded(unrounded(integralPower: base, exponent: exponent))
        }

        private func unrounded(integralPower base: Decimal, exponent: Decimal) throws -> Decimal {
            var remaining = exponent
            var factor = base
            if remaining < 0 {
                factor = try unrounded(NSDecimalDivide, 1, factor)
                remaining = -remaining
            }
            var result: Decimal = 1

            while remaining > 0 {
                // Exponent bookkeeping must stay independent of the configured result scale.
                let half = remaining / 2
                var integralHalf = Decimal()
                var halfToRound = half
                NSDecimalRound(&integralHalf, &halfToRound, 0, .down)

                let remainder = remaining - integralHalf * 2
                if remainder != 0 {
                    result = try unrounded(NSDecimalMultiply, result, factor)
                }

                remaining = integralHalf
                if remaining > 0 {
                    factor = try unrounded(NSDecimalMultiply, factor, factor)
                }
            }

            return result
        }

        private func unroundedIntegralPower(base: Decimal?, exponent: Decimal?) -> Decimal? {
            guard let base, let exponent else {
                return nil
            }

            var integralExponent = exponent
            var exponentToRound = exponent
            NSDecimalRound(&integralExponent, &exponentToRound, 0, .plain)
            guard integralExponent == exponent else {
                return nil
            }

            return try? unrounded(integralPower: base, exponent: integralExponent)
        }

        /// Computes a Decimal square root with bounded iteration and rounds only the final result.
        private func rounded(squareRootOf value: Decimal) throws -> Decimal {
            guard value >= 0 else {
                throw CalculatorError.domainError
            }
            guard value != 0 else {
                return 0
            }

            let normalization = try squareRootNormalization(for: value)

            var lower: Decimal = 0
            var upper: Decimal = 10

            // Accept a result only when every value in the remaining root bracket rounds alike.
            for _ in 0 ..< 256 {
                let lowerResult = try rounded(multiplying: lower, normalization.scalingFactor)
                let upperResult = try rounded(multiplying: upper, normalization.scalingFactor)
                if lowerResult == upperResult {
                    return lowerResult
                }

                let midpointSum = try unrounded(
                    NSDecimalAdd,
                    lower,
                    upper,
                    allowingLossOfPrecision: true,
                )
                let midpoint = try unrounded(
                    NSDecimalDivide,
                    midpointSum,
                    2,
                    allowingLossOfPrecision: true,
                )
                guard midpoint > lower, midpoint < upper else {
                    return try roundedRootAtPrecisionLimit(
                        between: lowerResult,
                        and: upperResult,
                        scalingFactor: normalization.scalingFactor,
                        normalizedValue: normalization.value,
                    )
                }

                switch try compareSquare(of: midpoint, with: normalization.value) {
                case .orderedAscending,
                     .orderedSame:
                    lower = midpoint
                case .orderedDescending:
                    upper = midpoint
                }
            }

            let lowerResult = try rounded(multiplying: lower, normalization.scalingFactor)
            let upperResult = try rounded(multiplying: upper, normalization.scalingFactor)
            guard lowerResult == upperResult else {
                return try roundedRootAtPrecisionLimit(
                    between: lowerResult,
                    and: upperResult,
                    scalingFactor: normalization.scalingFactor,
                    normalizedValue: normalization.value,
                )
            }

            return lowerResult
        }

        /// Compares a bounded Decimal square exactly without rounding its product to 38 digits.
        private func compareSquare(of candidate: Decimal, with value: Decimal) throws -> ComparisonResult {
            let (candidateDigits, candidateScale) = try decimalDigitsAndScale(candidate)
            return try compareSquare(of: candidateDigits, scale: candidateScale, with: value)
        }

        /// Resolves adjacent rounded results with an exact squared-midpoint comparison.
        ///
        /// At Decimal's precision limit, the root can remain between two adjacent output
        /// values. Comparing the exact square of their midpoint with the normalized input proves
        /// which result is nearest without treating a rounded Decimal product as exact.
        private func roundedRootAtPrecisionLimit(
            between lowerResult: Decimal,
            and upperResult: Decimal,
            scalingFactor: Decimal,
            normalizedValue: Decimal,
        ) throws -> Decimal {
            let (lowerDigits, lowerScale) = try decimalDigitsAndScale(lowerResult)
            let (upperDigits, upperScale) = try decimalDigitsAndScale(upperResult)
            let commonScale = max(lowerScale, upperScale)
            let lower = lowerDigits + Array(repeating: 0, count: commonScale - lowerScale)
            let upper = upperDigits + Array(repeating: 0, count: commonScale - upperScale)

            guard incrementingDecimalDigits(lower) == upper else {
                throw CalculatorError.overflow
            }

            let midpointDigits = multiplyDecimalDigits(
                addingDecimalDigits(lower, upper),
                by: 5,
            )
            let midpointScale = commonScale + 1 + scalingFactor.exponent
            guard midpointScale >= 0 else {
                throw CalculatorError.overflow
            }

            let midpointComparison = try compareSquare(
                of: midpointDigits,
                scale: midpointScale,
                with: normalizedValue,
            )
            return midpointComparison == .orderedDescending ? lowerResult : upperResult
        }

        private func compareSquare(
            of candidateDigits: [Int],
            scale candidateScale: Int,
            with value: Decimal,
        ) throws -> ComparisonResult {
            let (valueDigits, valueScale) = try decimalDigitsAndScale(value)
            let squaredDigits = multiplyDecimalDigits(candidateDigits)
            return compareDecimalDigits(
                squaredDigits,
                scale: candidateScale * 2,
                with: valueDigits,
                scale: valueScale,
            )
        }

        /// Adds two nonnegative base-ten integer coefficients stored most-significant digit first.
        private func addingDecimalDigits(_ lhs: [Int], _ rhs: [Int]) -> [Int] {
            var result: [Int] = []
            var carry = 0
            var lhsIndex = lhs.count - 1
            var rhsIndex = rhs.count - 1
            for _ in 0 ..< max(lhs.count, rhs.count) {
                let left = lhsIndex >= 0 ? lhs[lhsIndex] : 0
                let right = rhsIndex >= 0 ? rhs[rhsIndex] : 0
                let sum = left + right + carry
                result.append(sum % 10)
                carry = sum / 10
                lhsIndex -= 1
                rhsIndex -= 1
            }
            if carry > 0 {
                result.append(carry)
            }
            return result.reversed()
        }

        /// Multiplies a base-ten integer coefficient by a small positive integer.
        private func multiplyDecimalDigits(_ digits: [Int], by multiplier: Int) -> [Int] {
            var result: [Int] = []
            var carry = 0
            for digit in digits.reversed() {
                let product = digit * multiplier + carry
                result.append(product % 10)
                carry = product / 10
            }
            while carry > 0 {
                result.append(carry % 10)
                carry /= 10
            }
            return result.reversed()
        }

        /// Increments a base-ten integer coefficient while preserving its digit order.
        private func incrementingDecimalDigits(_ digits: [Int]) -> [Int] {
            var result = digits
            for index in result.indices.reversed() {
                if result[index] < 9 {
                    result[index] += 1
                    return result
                }
                result[index] = 0
            }
            return [1] + result
        }

        /// Converts a positive normalized Decimal into an exact base-ten coefficient and scale.
        private func decimalDigitsAndScale(_ value: Decimal) throws -> (digits: [Int], scale: Int) {
            var decimalValue = value
            let text = NSDecimalString(&decimalValue, Locale(identifier: "en_US_POSIX"))
            let components = text.split(separator: ".", omittingEmptySubsequences: false)
            guard components.count <= 2, !text.hasPrefix("-") else {
                throw CalculatorError.overflow
            }

            let integerDigits = String(components[0])
            let fractionalDigits = components.count == 2 ? String(components[1]) : ""
            let coefficient = integerDigits + fractionalDigits
            guard !coefficient.isEmpty, coefficient.allSatisfy(\.isNumber) else {
                throw CalculatorError.overflow
            }

            var digits = coefficient.compactMap(\.wholeNumberValue)
            while digits.count > 1, digits.first == 0 {
                digits.removeFirst()
            }
            var scale = fractionalDigits.count
            while scale > 0, digits.last == 0 {
                digits.removeLast()
                scale -= 1
            }
            guard digits.count <= 39 else {
                throw CalculatorError.overflow
            }

            return (digits, scale)
        }

        /// Multiplies two bounded base-ten coefficient digit arrays.
        private func multiplyDecimalDigits(_ digits: [Int]) -> [Int] {
            var product = Array(repeating: 0, count: digits.count * 2)
            for leftIndex in digits.indices {
                for rightIndex in digits.indices {
                    product[leftIndex + rightIndex + 1] += digits[leftIndex] * digits[rightIndex]
                }
            }

            for index in stride(from: product.count - 1, through: 1, by: -1) {
                product[index - 1] += product[index] / 10
                product[index] %= 10
            }

            while product.count > 1, product.first == 0 {
                product.removeFirst()
            }
            return product
        }

        /// Compares exact decimal coefficients after aligning their fractional scales.
        private func compareDecimalDigits(
            _ lhsDigits: [Int],
            scale lhsScale: Int,
            with rhsDigits: [Int],
            scale rhsScale: Int,
        ) -> ComparisonResult {
            let commonScale = max(lhsScale, rhsScale)
            var lhs = lhsDigits + Array(repeating: 0, count: commonScale - lhsScale)
            var rhs = rhsDigits + Array(repeating: 0, count: commonScale - rhsScale)

            while lhs.count > 1, lhs.first == 0 {
                lhs.removeFirst()
            }
            while rhs.count > 1, rhs.first == 0 {
                rhs.removeFirst()
            }

            if lhs.count != rhs.count {
                return lhs.count < rhs.count ? .orderedAscending : .orderedDescending
            }
            for (leftDigit, rightDigit) in zip(lhs, rhs) where leftDigit != rightDigit {
                return leftDigit < rightDigit ? .orderedAscending : .orderedDescending
            }
            return .orderedSame
        }

        /// Scales a positive Decimal so its square root lies between one and ten.
        private func squareRootNormalization(for value: Decimal) throws -> (value: Decimal, scalingFactor: Decimal) {
            let significand = NSDecimalNumber(decimal: value.significand).stringValue
            let digitCount = significand.filter(\.isNumber).count
            guard digitCount > 0 else {
                throw CalculatorError.overflow
            }

            let (coefficientOrder, coefficientOverflow) = digitCount.addingReportingOverflow(value.exponent)
            guard !coefficientOverflow else {
                throw CalculatorError.overflow
            }

            let (decimalOrder, decimalOrderOverflow) = coefficientOrder.subtractingReportingOverflow(1)
            guard !decimalOrderOverflow else {
                throw CalculatorError.overflow
            }

            let (halfOrder, halfOrderOverflow) = decimalOrder.addingReportingOverflow(1)
            guard !halfOrderOverflow else {
                throw CalculatorError.overflow
            }

            let estimateExponent = halfOrder >= 0 ? halfOrder / 2 + halfOrder % 2 : halfOrder / 2
            let (scaleExponent, scaleExponentOverflow) = estimateExponent.subtractingReportingOverflow(1)
            let (squaredScaleExponent, squaredScaleExponentOverflow) = scaleExponent.multipliedReportingOverflow(by: 2)
            guard !scaleExponentOverflow, !squaredScaleExponentOverflow else {
                throw CalculatorError.overflow
            }

            let scalingFactor = try decimal("1e\(scaleExponent)")
            let squaredScalingFactor = try decimal("1e\(squaredScaleExponent)")
            let normalizedValue = try unrounded(NSDecimalDivide, value, squaredScalingFactor)
            return (normalizedValue, scalingFactor)
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
            try rounded(unrounded(operation, lhs, rhs))
        }

        /// Performs checked Decimal arithmetic without applying calculator display rounding.
        /// - Parameter allowingLossOfPrecision: Accepts Decimal's representable approximation for iterative convergence.
        private func unrounded(
            _ operation: (
                UnsafeMutablePointer<Decimal>,
                UnsafePointer<Decimal>,
                UnsafePointer<Decimal>,
                Decimal.RoundingMode,
            ) -> Decimal.CalculationError,
            _ lhs: Decimal,
            _ rhs: Decimal,
            allowingLossOfPrecision: Bool = false,
        ) throws -> Decimal {
            var result = Decimal()
            var left = lhs
            var right = rhs
            let error = operation(&result, &left, &right, .plain)
            guard error == .noError || (allowingLossOfPrecision && error == .lossOfPrecision) else {
                throw CalculatorError.overflow
            }

            return result
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
