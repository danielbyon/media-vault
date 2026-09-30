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

        /// Carries a calculator-rounded result alongside its semantic value and exact Radian provenance.
        private struct ParsedValue {
            let value: Decimal
            let semanticValue: Decimal
            let angleProvenance: AngleProvenance?

            init(value: Decimal, semanticValue: Decimal? = nil, angleProvenance: AngleProvenance? = nil) {
                self.value = value
                self.semanticValue = semanticValue ?? value
                self.angleProvenance = angleProvenance
            }

            static func scalar(_ value: Decimal) -> Self {
                Self(
                    value: value,
                    angleProvenance: AngleProvenance(
                        constant: value,
                        piCoefficient: .exactDecimal(0),
                    ),
                )
            }
        }

        /// Tracks exact `constant + coefficient × π` expressions through Decimal arithmetic.
        ///
        /// The rational form preserves repeating inverse-trigonometric fractions. The Decimal
        /// coefficient covers exact scalar magnitudes beyond Int64, while its exactness flag keeps
        /// a rounded rational approximation from being mistaken for a quadrantal angle.
        private struct AngleProvenance {
            let constant: Decimal
            let piCoefficient: PiCoefficient

            var piCoefficientIsZero: Bool {
                piCoefficient.isZero
            }
        }

        /// Keeps each π coefficient's exact source and Decimal projection in one valid state.
        private enum PiCoefficient {
            case exactRational(CalculatorExactRational, decimal: Decimal)
            case roundedRational(CalculatorExactRational, decimal: Decimal)
            case exactDecimal(Decimal)

            var decimalValue: Decimal {
                switch self {
                case let .exactRational(_, decimal), let .roundedRational(_, decimal): decimal
                case let .exactDecimal(decimal): decimal
                }
            }

            var exactRational: CalculatorExactRational? {
                switch self {
                case let .exactRational(rational, _), let .roundedRational(rational, _): rational
                case .exactDecimal: nil
                }
            }

            var exactDecimalValue: Decimal? {
                switch self {
                case let .exactRational(_, decimal), let .exactDecimal(decimal): decimal
                case .roundedRational: nil
                }
            }

            var isZero: Bool {
                if let exactRational {
                    return exactRational.isZero
                }
                return exactDecimalValue == 0
            }

            static func rational(
                _ rational: CalculatorExactRational,
                decimal: Decimal,
                isExactDecimal: Bool,
            ) -> Self {
                isExactDecimal
                    ? .exactRational(rational, decimal: decimal)
                    : .roundedRational(rational, decimal: decimal)
            }
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
                        semanticValue: unroundedResult(NSDecimalAdd, value.semanticValue, right.semanticValue),
                        angleProvenance: combinedAngleProvenance(
                            value.angleProvenance,
                            right.angleProvenance,
                        ),
                    )
                } else if consume("−") || consume("-") {
                    let right = try parseTerm()
                    value = ParsedValue(
                        value: try rounded(subtracting: value.value, right.value),
                        semanticValue: unroundedResult(NSDecimalSubtract, value.semanticValue, right.semanticValue),
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
                        semanticValue: unroundedResult(NSDecimalMultiply, value.semanticValue, right.semanticValue),
                        angleProvenance: multipliedAngleProvenance(value.angleProvenance, right.angleProvenance),
                    )
                } else if consume("÷") || consume("/") {
                    let right = try parseUnary()
                    value = ParsedValue(
                        value: try rounded(dividing: value.value, right.value),
                        semanticValue: unroundedResult(NSDecimalDivide, value.semanticValue, right.semanticValue),
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
                    semanticValue: negated(operand.semanticValue),
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
            let displayedResult = try rounded(powering: base.value, exponent.value)
            let preservesBaseAngle = exponent.semanticValue == 1
            return ParsedValue(
                value: displayedResult,
                semanticValue: preservesBaseAngle
                    ? base.semanticValue
                    : try semanticPowering(base.semanticValue, exponent.semanticValue),
                angleProvenance: preservesBaseAngle ? base.angleProvenance : nil,
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
                    semanticValue: unroundedResult(NSDecimalDivide, value.semanticValue, 100),
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

                return try apply(function, to: argument)
            }

            if consume("π") {
                let value = try decimal("3.141592653589793238462643383")
                return ParsedValue(
                    value: value,
                    semanticValue: value,
                    angleProvenance: AngleProvenance(
                        constant: 0,
                        piCoefficient: .exactRational(.one, decimal: 1),
                    ),
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
            to argument: ParsedValue,
        ) throws -> ParsedValue {
            switch function {
            case .arcSine,
                 .arcCosine:
                guard argument.value >= -1, argument.value <= 1,
                      argument.semanticValue >= -1, argument.semanticValue <= 1
                else {
                    throw CalculatorError.domainError
                }

            default:
                break
            }

            let value = NSDecimalNumber(decimal: argument.value).doubleValue
            let result: Decimal
            switch function {
            case .sine:
                if let exactResult = try exactQuadrantalResult(for: function, argument: argument) {
                    result = exactResult
                } else {
                    let input = try trigonometricArgument(from: argument.value)
                    result = try decimal(Foundation.sin(radians(from: input)))
                }
            case .cosine:
                if let exactResult = try exactQuadrantalResult(for: function, argument: argument) {
                    result = exactResult
                } else {
                    let input = try trigonometricArgument(from: argument.value)
                    result = try decimal(Foundation.cos(radians(from: input)))
                }
            case .tangent:
                guard try !isTangentPole(for: argument) else {
                    throw CalculatorError.domainError
                }

                let input = try trigonometricArgument(from: argument.semanticValue)
                let angle = radians(from: input)
                result = try decimal(Foundation.tan(angle))
            case .arcSine:
                result = try decimal(angleMode.fromRadians(Foundation.asin(value)))
            case .arcCosine:
                result = try decimal(angleMode.fromRadians(Foundation.acos(value)))
            case .arcTangent:
                result = try decimal(angleMode.fromRadians(Foundation.atan(value)))
            case .naturalLogarithm:
                guard value > 0 else {
                    throw CalculatorError.domainError
                }

                result = try decimal(Foundation.log(value))
            case .commonLogarithm:
                guard value > 0 else {
                    throw CalculatorError.domainError
                }

                result = try decimal(Foundation.log10(value))
            case .squareRoot:
                result = try rounded(squareRootOf: argument.value)
            case .square:
                result = try rounded(multiplying: argument.value, argument.value)
            case .reciprocal:
                result = try rounded(dividing: 1, argument.value)
            }

            let exactInverseResult = try exactInverseTrigonometricResult(
                function,
                argument: argument.semanticValue,
            )
            let semanticValue: Decimal
            if let exactInverseResult {
                semanticValue = exactInverseResult.value
            } else if let functionResult = try semanticFunctionResult(function, argument: argument) {
                semanticValue = functionResult
            } else {
                semanticValue = result
            }

            return ParsedValue(
                value: result,
                semanticValue: semanticValue,
                angleProvenance: exactInverseResult?.angleProvenance,
            )
        }

        /// Computes the function result used by later expression terms without display rounding.
        private func semanticFunctionResult(_ function: Function, argument: ParsedValue) throws -> Decimal? {
            let semanticValue = argument.semanticValue
            switch function {
            case .sine:
                if let exactResult = try exactQuadrantalResult(for: function, argument: argument) {
                    return exactResult
                }
                let input = try trigonometricArgument(from: semanticValue)
                return try semanticDecimal(Foundation.sin(radians(from: input)))
            case .cosine:
                if let exactResult = try exactQuadrantalResult(for: function, argument: argument) {
                    return exactResult
                }
                let input = try trigonometricArgument(from: semanticValue)
                return try semanticDecimal(Foundation.cos(radians(from: input)))
            case .tangent:
                let input = try trigonometricArgument(from: semanticValue)
                return try semanticDecimal(Foundation.tan(radians(from: input)))
            case .arcSine:
                return try semanticDecimal(
                    angleMode.fromRadians(Foundation.asin(NSDecimalNumber(decimal: semanticValue).doubleValue)),
                )
            case .arcCosine:
                return try semanticDecimal(
                    angleMode.fromRadians(Foundation.acos(NSDecimalNumber(decimal: semanticValue).doubleValue)),
                )
            case .arcTangent:
                return try semanticDecimal(
                    angleMode.fromRadians(Foundation.atan(NSDecimalNumber(decimal: semanticValue).doubleValue)),
                )
            case .naturalLogarithm:
                return try semanticDecimal(Foundation.log(NSDecimalNumber(decimal: semanticValue).doubleValue))
            case .commonLogarithm:
                return try semanticDecimal(Foundation.log10(NSDecimalNumber(decimal: semanticValue).doubleValue))
            case .squareRoot:
                return try? semanticSquareRoot(of: semanticValue)
            case .square:
                return try? unrounded(NSDecimalMultiply, semanticValue, semanticValue)
            case .reciprocal:
                return try? unrounded(NSDecimalDivide, 1, semanticValue)
            }
        }

        /// Retains exact π-relative results for inverse-trigonometric values with known forms.
        private func exactInverseTrigonometricResult(
            _ function: Function,
            argument: Decimal,
        ) throws -> (value: Decimal, angleProvenance: AngleProvenance?)? {
            let piCoefficient: CalculatorExactRational
            switch function {
            case .arcSine:
                if argument == 1 {
                    piCoefficient = .half
                } else if argument == -1 {
                    piCoefficient = .negativeHalf
                } else if argument == 0.5 {
                    piCoefficient = .oneSixth
                } else if argument == -0.5 {
                    piCoefficient = .negativeOneSixth
                } else {
                    return nil
                }
            case .arcCosine:
                if argument == -1 {
                    piCoefficient = .one
                } else if argument == 0 {
                    piCoefficient = .half
                } else if argument == 1 {
                    piCoefficient = .zero
                } else if argument == 0.5 {
                    piCoefficient = .oneThird
                } else if argument == -0.5 {
                    piCoefficient = .twoThirds
                } else {
                    return nil
                }
            case .arcTangent:
                if argument == -1 {
                    piCoefficient = .negativeOneQuarter
                } else if argument == 0 {
                    piCoefficient = .zero
                } else if argument == 1 {
                    piCoefficient = .oneQuarter
                } else {
                    return nil
                }
            default:
                return nil
            }

            switch angleMode {
            case .degrees:
                guard let degreeCoefficient = piCoefficient.multiplied(by: .integer(180)) else {
                    throw CalculatorError.overflow
                }
                return (try decimal(from: degreeCoefficient), nil)
            case .radians:
                let (coefficient, isExactDecimal) = try decimalRepresentation(of: piCoefficient)
                let provenance = AngleProvenance(
                    constant: 0,
                    piCoefficient: .rational(
                        piCoefficient,
                        decimal: coefficient,
                        isExactDecimal: isExactDecimal,
                    ),
                )
                let pi = try decimal("3.141592653589793238462643383")
                return (
                    try unrounded(NSDecimalMultiply, pi, coefficient, allowingLossOfPrecision: true),
                    provenance,
                )
            }
        }

        private func decimal(from rational: CalculatorExactRational) throws -> Decimal {
            try unrounded(
                NSDecimalDivide,
                Decimal(rational.numerator),
                Decimal(rational.denominator),
                allowingLossOfPrecision: true,
            )
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

        /// Returns the exact sine or cosine value when the angle is a known quadrant.
        private func exactQuadrantalResult(for function: Function, argument: ParsedValue) throws -> Decimal? {
            let quadrant: Int?
            switch angleMode {
            case .degrees:
                quadrant = try quadrantIndex(forDegreeAngle: argument.semanticValue)
            case .radians:
                guard let provenance = argument.angleProvenance,
                      provenance.constant == 0
                else {
                    return nil
                }
                quadrant = quadrantIndex(forPiCoefficient: provenance)
            }

            guard let quadrant else {
                return nil
            }

            switch function {
            case .sine:
                switch quadrant {
                case 0, 2: return 0
                case 1: return 1
                case 3: return -1
                default: return nil
                }
            case .cosine:
                switch quadrant {
                case 0: return 1
                case 1, 3: return 0
                case 2: return -1
                default: return nil
                }
            default:
                return nil
            }
        }

        /// Finds exact multiples of 90 degrees after reducing the semantic Decimal angle.
        private func quadrantIndex(forDegreeAngle value: Decimal) throws -> Int? {
            var reduced = try reducedDegrees(from: value)
            if reduced < 0 {
                reduced = try unrounded(NSDecimalAdd, reduced, 360)
            }

            if reduced == 0 { return 0 }
            if reduced == 90 { return 1 }
            if reduced == 180 { return 2 }
            if reduced == 270 { return 3 }
            return nil
        }

        /// Computes the quadrant modulo four without converting π coefficients through Double.
        private func quadrantIndex(forPiCoefficient provenance: AngleProvenance) -> Int? {
            if let exactPiCoefficient = provenance.piCoefficient.exactRational {
                return exactPiCoefficient.halfTurnsModuloFour
            }
            guard let exactDecimalValue = provenance.piCoefficient.exactDecimalValue else {
                return nil
            }
            return halfTurnsModuloFour(for: exactDecimalValue)
        }

        /// Determines whether a finite Decimal coefficient is an exact integer or half-integer.
        private func halfTurnsModuloFour(for coefficient: Decimal) -> Int? {
            var coefficient = coefficient
            let text = NSDecimalString(&coefficient, Locale(identifier: "en_US_POSIX"))
            let isNegative = text.first == "-"
            let unsignedText = isNegative ? String(text.dropFirst()) : text
            let components = unsignedText.split(separator: ".", omittingEmptySubsequences: false)
            guard components.count <= 2 else {
                return nil
            }

            var fraction = components.count == 2 ? String(components[1]) : ""
            while fraction.last == "0" {
                fraction.removeLast()
            }
            guard fraction.isEmpty || fraction == "5" else {
                return nil
            }

            var integerParity = 0
            for digit in components.first ?? "0" {
                guard let value = digit.wholeNumberValue else {
                    return nil
                }
                integerParity = (integerParity * 10 + value) % 2
            }

            let magnitude = (integerParity * 2 + (fraction == "5" ? 1 : 0)) % 4
            let signed = isNegative ? -magnitude : magnitude
            return (signed + 4) % 4
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
        private func isTangentPole(for angle: ParsedValue) throws -> Bool {
            switch angleMode {
            case .degrees:
                var reduced = try reducedDegrees(from: angle.semanticValue)
                while reduced >= 180 {
                    reduced = try unrounded(NSDecimalSubtract, reduced, 180)
                }
                while reduced <= -180 {
                    reduced = try unrounded(NSDecimalAdd, reduced, 180)
                }

                let magnitude = reduced < 0 ? -reduced : reduced
                return magnitude == 90
            case .radians:
                guard let provenance = angle.angleProvenance,
                      provenance.constant == 0
                else {
                    return false
                }

                guard let quadrant = quadrantIndex(forPiCoefficient: provenance) else {
                    return false
                }
                return quadrant % 2 == 1
            }
        }

        private func unrounded(_ operation: DecimalOperation, _ lhs: Decimal?, _ rhs: Decimal?) -> Decimal? {
            guard let lhs, let rhs else {
                return nil
            }

            return try? unrounded(operation, lhs, rhs)
        }

        private func unroundedResult(_ operation: DecimalOperation, _ lhs: Decimal, _ rhs: Decimal) -> Decimal? {
            try? unrounded(operation, lhs, rhs)
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
            guard let constant = try? unrounded(operation, lhs.constant, rhs.constant) else {
                return nil
            }

            if let lhsExactPiCoefficient = lhs.piCoefficient.exactRational,
               let rhsExactPiCoefficient = rhs.piCoefficient.exactRational,
               let exactPiCoefficient = lhsExactPiCoefficient.adding(
                   rhsExactPiCoefficient,
                   subtracting: subtracting,
               ) {
                guard let representation = try? decimalRepresentation(of: exactPiCoefficient) else {
                    return nil
                }
                return AngleProvenance(
                    constant: constant,
                    piCoefficient: .rational(
                        exactPiCoefficient,
                        decimal: representation.value,
                        isExactDecimal: representation.isExact,
                    ),
                )
            }

            guard let lhsCoefficient = lhs.piCoefficient.exactDecimalValue,
                  let rhsCoefficient = rhs.piCoefficient.exactDecimalValue,
                  let coefficient = try? unrounded(
                      operation,
                      lhsCoefficient,
                      rhsCoefficient,
                  )
            else {
                return nil
            }

            return AngleProvenance(
                constant: constant,
                piCoefficient: .exactDecimal(coefficient),
            )
        }

        private func multipliedAngleProvenance(
            _ lhs: AngleProvenance?,
            _ rhs: AngleProvenance?,
        ) -> AngleProvenance? {
            guard let lhs, let rhs else {
                return nil
            }

            if lhs.piCoefficientIsZero {
                return scaledAngleProvenance(rhs, by: lhs.constant)
            }
            if rhs.piCoefficientIsZero {
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
                  denominator.piCoefficientIsZero
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
            guard let constant = try? unrounded(operation, provenance.constant, factor) else {
                return nil
            }

            let exactFactor = CalculatorExactRational.decimal(factor)
            let exactPiCoefficient: CalculatorExactRational?
            if let source = provenance.piCoefficient.exactRational, let exactFactor {
                if dividing {
                    exactPiCoefficient = source.divided(by: exactFactor)
                } else {
                    exactPiCoefficient = source.multiplied(by: exactFactor)
                }
            } else {
                exactPiCoefficient = nil
            }

            if let exactPiCoefficient {
                guard let representation = try? decimalRepresentation(of: exactPiCoefficient) else {
                    return nil
                }
                return AngleProvenance(
                    constant: constant,
                    piCoefficient: .rational(
                        exactPiCoefficient,
                        decimal: representation.value,
                        isExactDecimal: representation.isExact,
                    ),
                )
            }

            guard let sourceCoefficient = provenance.piCoefficient.exactDecimalValue,
                  let coefficient = try? unrounded(
                      operation,
                      sourceCoefficient,
                      factor,
                  )
            else {
                return nil
            }

            return AngleProvenance(
                constant: constant,
                piCoefficient: .exactDecimal(coefficient),
            )
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
                  let piCoefficient = negated(provenance.piCoefficient.decimalValue)
            else {
                return nil
            }

            let exactRational = provenance.piCoefficient.exactRational?.negated()
            let coefficientState: PiCoefficient
            if let exactRational {
                coefficientState = .rational(
                    exactRational,
                    decimal: piCoefficient,
                    isExactDecimal: provenance.piCoefficient.exactDecimalValue != nil,
                )
            } else if provenance.piCoefficient.exactDecimalValue != nil {
                coefficientState = .exactDecimal(piCoefficient)
            } else {
                return nil
            }

            return AngleProvenance(
                constant: constant,
                piCoefficient: coefficientState,
            )
        }

        /// Converts an exact rational coefficient to Decimal while recording any finite-precision loss.
        private func decimalRepresentation(
            of rational: CalculatorExactRational,
        ) throws -> (value: Decimal, isExact: Bool) {
            do {
                let value = try unrounded(
                    NSDecimalDivide,
                    Decimal(rational.numerator),
                    Decimal(rational.denominator),
                )
                return (value, true)
            } catch {
                return (try decimal(from: rational), false)
            }
        }

        private func decimal(_ value: Double) throws -> Decimal {
            try checkedDecimal(fromFoundationValue: value, applyingDisplayRounding: true)
        }

        /// Converts a Foundation result to Decimal using a locale-independent round-trip string.
        ///
        /// Decimal's direct Double initializer can produce NaN for finite values near the lower
        /// end of Decimal's exponent range, so parsing the Double's canonical representation keeps
        /// representable scientific results while still rejecting actual range failures.
        private func checkedDecimal(
            fromFoundationValue value: Double,
            applyingDisplayRounding: Bool,
        ) throws -> Decimal {
            guard value.isFinite,
                  let result = Decimal(
                      string: value.description,
                      locale: Locale(identifier: "en_US_POSIX"),
                  ),
                  !result.isNaN,
                  result != 0 || value == 0
            else {
                throw CalculatorError.overflow
            }

            return applyingDisplayRounding ? try rounded(result) : result
        }

        /// Converts a Foundation result to Decimal without applying display rounding.
        private func semanticDecimal(_ value: Double) throws -> Decimal {
            try checkedDecimal(fromFoundationValue: value, applyingDisplayRounding: false)
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

        private func rounded(multiplying lhs: Decimal, _ rhs: Decimal, toScale scale: Int) throws -> Decimal {
            let product = try unrounded(NSDecimalMultiply, lhs, rhs)
            return rounded(product, toScale: scale)
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
            if exponent == 0.5 {
                guard base >= 0 else {
                    throw CalculatorError.domainError
                }
                return try rounded(squareRootOf: base)
            }
            if exponent == -0.5 {
                guard base >= 0 else {
                    throw CalculatorError.domainError
                }
                return try rounded(reciprocalSquareRootOf: base)
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

        /// Computes a negative half power with Decimal square root and a checked reciprocal.
        private func rounded(reciprocalSquareRootOf value: Decimal) throws -> Decimal {
            let normalization = try squareRootNormalization(for: value)
            let (precisionScale, overflow) = 20.subtractingReportingOverflow(
                normalization.scalingFactor.exponent,
            )
            guard !overflow else {
                throw CalculatorError.overflow
            }

            let root = try squareRoot(
                of: value,
                toScale: max(roundingScale, precisionScale),
            )
            return try rounded(dividing: 1, root)
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

        /// Computes the semantic power without applying calculator display rounding.
        private func semanticPowering(_ base: Decimal, _ exponent: Decimal) throws -> Decimal? {
            if exponent == 0.5 {
                guard base >= 0 else {
                    throw CalculatorError.domainError
                }
                return try semanticSquareRoot(of: base)
            }
            if exponent == -0.5 {
                guard base >= 0 else {
                    throw CalculatorError.domainError
                }
                guard base != 0 else {
                    throw CalculatorError.divisionByZero
                }
                let root = try semanticSquareRoot(of: base)
                return try unrounded(NSDecimalDivide, 1, root)
            }

            var integralExponent = exponent
            var exponentToRound = exponent
            NSDecimalRound(&integralExponent, &exponentToRound, 0, .plain)
            if integralExponent == exponent {
                return unroundedIntegralPower(base: base, exponent: exponent)
            }

            guard base >= 0 else {
                throw CalculatorError.domainError
            }
            let result = Foundation.pow(
                NSDecimalNumber(decimal: base).doubleValue,
                NSDecimalNumber(decimal: exponent).doubleValue,
            )
            return try semanticDecimal(result)
        }

        /// Computes a Decimal square root with bounded iteration and rounds only the final result.
        private func rounded(squareRootOf value: Decimal) throws -> Decimal {
            try squareRoot(of: value, toScale: roundingScale)
        }

        /// Retains additional Decimal precision when a square root is composed with another function.
        private func semanticSquareRoot(of value: Decimal) throws -> Decimal {
            try squareRoot(of: value, toScale: max(roundingScale, 20))
        }

        private func squareRoot(of value: Decimal, toScale scale: Int) throws -> Decimal {
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
                let lowerResult = try rounded(multiplying: lower, normalization.scalingFactor, toScale: scale)
                let upperResult = try rounded(multiplying: upper, normalization.scalingFactor, toScale: scale)
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

            let lowerResult = try rounded(multiplying: lower, normalization.scalingFactor, toScale: scale)
            let upperResult = try rounded(multiplying: upper, normalization.scalingFactor, toScale: scale)
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
            rounded(value, toScale: roundingScale)
        }

        private func rounded(_ value: Decimal, toScale scale: Int) -> Decimal {
            var result = value
            var valueToRound = result
            NSDecimalRound(&result, &valueToRound, scale, .plain)
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
