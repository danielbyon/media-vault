//
//  CalculatorEngine.swift
//  MediaVault
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

/// The calculator's π at the full precision `Foundation.Decimal` can carry.
///
/// `Decimal` keeps at most 38 significant digits, so a longer literal would be rounded away.
/// The π constant, exact π-relative semantic values and Radian range reduction all read this
/// single representation, which keeps those calculations from drifting apart.
private let calculatorPiDigits = "3.1415926535897932384626433832795028842"

/// The calculator's e at the full precision `Foundation.Decimal` can carry.
///
/// Like `calculatorPiDigits` this is the single representation the e token reads, so the
/// constant keeps every digit a high-precision display can show.
private let calculatorEulerDigits = "2.718281828459045235360287471352662498"

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
            /// Decimal coefficient that Decimal arithmetic could only approximate.
            ///
            /// The value still drives periodic reduction, but it must never decide an exact
            /// classification such as a quadrant or a tangent pole.
            case roundedDecimal(Decimal)

            var decimalValue: Decimal {
                switch self {
                case let .exactRational(_, decimal), let .roundedRational(_, decimal): decimal
                case let .exactDecimal(decimal), let .roundedDecimal(decimal): decimal
                }
            }

            var exactRational: CalculatorExactRational? {
                switch self {
                case let .exactRational(rational, _), let .roundedRational(rational, _): rational
                case .exactDecimal, .roundedDecimal: nil
                }
            }

            var exactDecimalValue: Decimal? {
                switch self {
                case let .exactRational(_, decimal), let .exactDecimal(decimal): decimal
                case .roundedRational, .roundedDecimal: nil
                }
            }

            /// The Decimal coefficient together with whether it is known exactly.
            var decimalCoefficient: (value: Decimal, isExact: Bool) {
                switch self {
                case let .exactRational(_, decimal), let .exactDecimal(decimal): (decimal, true)
                case let .roundedRational(_, decimal), let .roundedDecimal(decimal): (decimal, false)
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

        /// A scientific-function result the engine proves exactly, with the provenance it carries.
        ///
        /// Provenance is recorded even when the value is a plain scalar, because later terms
        /// combine it: adding the exact zero of `sin(0)` to a symbolic angle has to leave the
        /// angle symbolic, or a tangent pole would stop being recognizable.
        private struct ExactFunctionResult {
            let value: Decimal
            let angleProvenance: AngleProvenance?
        }

        /// An angle the engine can place on the unit circle exactly.
        ///
        /// Twelfths of π carry both closed-form families in one representation: an even number of
        /// twelfths is a multiple of π/6, and a number divisible by three is a multiple of π/4.
        /// The remaining twelfths, such as π/12 and 5π/12, have no closed form this calculator
        /// supports and classify as references the value table does not cover.
        private struct ExactUnitCircleAngle {
            /// The angle in twelfths of π, normalized to 0 ..< 24.
            let twelfths: Int
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
        ///
        /// The power itself is evaluated from the operands' semantic values, and only its result
        /// is rounded for display. Rounding an operand first, such as a base whose display
        /// collapses to zero, must not change which operation is performed.
        private mutating func parsePower() throws -> ParsedValue {
            let base = try parsePostfix()
            skipWhitespace()
            guard consume("^") else {
                return base
            }

            let exponent = try parseUnary()
            let mathematicalResult = try power(base.semanticValue, exponent.semanticValue)
            let preservesBaseAngle = exponent.semanticValue == 1
            return ParsedValue(
                value: try rounded(mathematicalResult),
                semanticValue: preservesBaseAngle ? base.semanticValue : mathematicalResult,
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
                let value = try piValue()
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
                return .scalar(try eulerValue())
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
            let operand = argument.semanticValue
            switch function {
            case .arcSine,
                 .arcCosine:
                guard operand >= -1, operand <= 1 else {
                    throw CalculatorError.domainError
                }
            case .naturalLogarithm,
                 .commonLogarithm:
                guard operand > 0 else {
                    throw CalculatorError.domainError
                }
            default:
                break
            }

            // Each scientific function produces one mathematical value from the semantic operand;
            // only the value handed to the display is rounded. Nested functions therefore compose
            // from the exact operand instead of the digits that happen to be visible.
            let exactResult = try exactInverseTrigonometricResult(function, argument: operand)
                ?? exactScalarResult(for: function, operand: operand)
                ?? exactTrigonometricResult(for: function, argument: argument)

            let mathematicalValue: Decimal
            if let exactResult {
                mathematicalValue = exactResult.value
            } else {
                mathematicalValue = try computedValue(for: function, operand: operand, argument: argument)
            }

            return ParsedValue(
                value: try rounded(mathematicalValue),
                semanticValue: mathematicalValue,
                angleProvenance: exactResult?.angleProvenance,
            )
        }

        /// Computes the mathematical value of a scientific function at a semantic operand.
        ///
        /// The result is not display-rounded, so composition through `ParsedValue.semanticValue`
        /// keeps as much precision as the underlying calculation provides.
        private func computedValue(
            for function: Function,
            operand: Decimal,
            argument: ParsedValue,
        ) throws -> Decimal {
            let operandValue = NSDecimalNumber(decimal: operand).doubleValue
            switch function {
            case .sine:
                return try semanticDecimal(
                    Foundation.sin(radians(from: try trigonometricArgument(for: argument))),
                )
            case .cosine:
                return try semanticDecimal(
                    Foundation.cos(radians(from: try trigonometricArgument(for: argument))),
                )
            case .tangent:
                guard try !isTangentPole(for: argument) else {
                    throw CalculatorError.domainError
                }

                return try semanticDecimal(
                    Foundation.tan(radians(from: try trigonometricArgument(for: argument))),
                )
            case .arcSine:
                return try inverseTrigonometricAngle(of: operand, measuringCosine: false)
            case .arcCosine:
                return try inverseTrigonometricAngle(of: operand, measuringCosine: true)
            case .arcTangent:
                return try semanticDecimal(angleMode.fromRadians(Foundation.atan(operandValue)))
            case .naturalLogarithm:
                return try logarithm(of: operand, isCommon: false)
            case .commonLogarithm:
                return try logarithm(of: operand, isCommon: true)
            case .squareRoot:
                return try semanticSquareRoot(of: operand)
            case .square:
                return try unrounded(NSDecimalMultiply, operand, operand, allowingLossOfPrecision: true)
            case .reciprocal:
                guard operand != 0 else {
                    throw CalculatorError.divisionByZero
                }

                return try unrounded(NSDecimalDivide, 1, operand, allowingLossOfPrecision: true)
            }
        }

        /// Computes an inverse-trigonometric angle in the configured angle mode.
        ///
        /// The operand stays a `Decimal` until its distance to the endpoints has been preserved.
        /// A value such as `0.99999999999999999` converts to the same `Double` as `1`, which
        /// would report a quarter turn exactly and hide that the tangent of that angle is a large
        /// finite number. Both the displayed and the semantic result come from this single
        /// evaluation, so they cannot disagree about which angle was computed.
        private func inverseTrigonometricAngle(
            of operand: Decimal,
            measuringCosine: Bool,
        ) throws -> Decimal {
            let radians = try requiresEndpointStableEvaluation(of: operand)
                ? stableInverseTrigonometricRadians(of: operand, measuringCosine: measuringCosine)
                : directInverseTrigonometricRadians(of: operand, measuringCosine: measuringCosine)
            return try semanticDecimal(angleMode.fromRadians(radians))
        }

        /// Evaluates `asin`/`acos` through Foundation for operands that convert without loss.
        private func directInverseTrigonometricRadians(
            of operand: Decimal,
            measuringCosine: Bool,
        ) -> Double {
            let operandValue = NSDecimalNumber(decimal: operand).doubleValue
            return measuringCosine ? Foundation.acos(operandValue) : Foundation.asin(operandValue)
        }

        /// Reports whether converting the operand to `Double` would erase part of its endpoint distance.
        ///
        /// A `Double` resolves values around one no more finely than one unit in the last place
        /// (about 2.2e-16), so an operand closer to ±1 than that reaches the trigonometry as the
        /// endpoint itself. The Decimal distance from the endpoint is compared against the
        /// distance the converted value reports, using the same material-loss rule as the
        /// near-one logarithm path: a loss of more than one part in 10^8 of the distance counts.
        private func requiresEndpointStableEvaluation(of operand: Decimal) throws -> Bool {
            let endpointDistance = try unrounded(
                NSDecimalSubtract,
                1,
                abs(operand),
                allowingLossOfPrecision: true,
            )
            let endpointDistanceValue = NSDecimalNumber(decimal: endpointDistance).doubleValue
            let convertedDistance = 1 - abs(NSDecimalNumber(decimal: operand).doubleValue)
            return abs(convertedDistance - endpointDistanceValue) > endpointDistanceValue * 1e-8
        }

        /// Evaluates `asin`/`acos` from the Decimal distance to the unit circle.
        ///
        /// `(1 - x)(1 + x)` is `1 - x²` formed without subtracting nearly equal numbers, and
        /// its square root is the remaining leg of the right triangle whose other leg is the
        /// operand. `atan2` therefore recovers the angle from both legs instead of from an
        /// operand that has already collapsed onto the endpoint.
        private func stableInverseTrigonometricRadians(
            of operand: Decimal,
            measuringCosine: Bool,
        ) throws -> Double {
            let complement = try unrounded(
                NSDecimalMultiply,
                try unrounded(NSDecimalSubtract, 1, operand, allowingLossOfPrecision: true),
                try unrounded(NSDecimalAdd, 1, operand, allowingLossOfPrecision: true),
                allowingLossOfPrecision: true,
            )
            let complementRoot = try squareRoot(of: complement, toScale: max(roundingScale, 20))
            let complementValue = NSDecimalNumber(decimal: complementRoot).doubleValue
            let operandValue = NSDecimalNumber(decimal: operand).doubleValue
            return measuringCosine
                ? Foundation.atan2(complementValue, operandValue)
                : Foundation.atan2(operandValue, complementValue)
        }

        /// Computes the function result used by later expression terms without display rounding.
        /// Retains exact π-relative results for inverse-trigonometric values with known forms.
        private func exactInverseTrigonometricResult(
            _ function: Function,
            argument: Decimal,
        ) throws -> ExactFunctionResult? {
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
                return ExactFunctionResult(
                    value: try decimal(from: degreeCoefficient),
                    angleProvenance: nil,
                )
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
                let pi = try piValue()
                return ExactFunctionResult(
                    value: try unrounded(
                        NSDecimalMultiply,
                        pi,
                        coefficient,
                        allowingLossOfPrecision: true,
                    ),
                    angleProvenance: provenance,
                )
            }
        }

        /// Returns the exact result for functions whose value the engine can prove directly.
        ///
        /// Only operands that make the value exact are recognized — never a floating-point result
        /// that merely rounded to a convenient number — so a tiny non-zero input keeps its
        /// approximate result and cannot pick up symbolic provenance.
        private func exactScalarResult(for function: Function, operand: Decimal) -> ExactFunctionResult? {
            let value: Decimal
            switch function {
            case .sine, .tangent, .arcSine, .arcTangent, .squareRoot, .square:
                guard operand == 0 else {
                    return nil
                }
                value = 0
            case .cosine:
                guard operand == 0 else {
                    return nil
                }
                value = 1
            case .arcCosine, .naturalLogarithm, .commonLogarithm:
                guard operand == 1 else {
                    return nil
                }
                value = 0
            case .reciprocal:
                guard operand == 1 else {
                    return nil
                }
                value = 1
            }

            return ExactFunctionResult(
                value: value,
                angleProvenance: exactScalarProvenance(for: value),
            )
        }

        /// Describes an exactly known scalar result as an angle contribution.
        ///
        /// Radian angles are the only ones that read provenance: a Degree angle already carries
        /// its exactness in the semantic value, so Degree mode records nothing here.
        private func exactScalarProvenance(for value: Decimal) -> AngleProvenance? {
            guard angleMode == .radians else {
                return nil
            }

            return AngleProvenance(
                constant: value,
                piCoefficient: .exactRational(.zero, decimal: 0),
            )
        }

        /// Converts an exact rational coefficient to Decimal.
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

        /// Reduces an angle before Double conversion so large angles retain their phase.
        ///
        /// A symbolic Radian angle is reduced from its provenance rather than from the
        /// materialized angle: the provenance still knows the exact π multiple, while the
        /// materialized `Decimal` has already lost the low-order phase of a large coefficient.
        private func trigonometricArgument(for argument: ParsedValue) throws -> Double {
            let reduced: Decimal =
                switch angleMode {
                case .degrees:
                    try reducedDegrees(from: argument.semanticValue)
                case .radians:
                    if let provenance = argument.angleProvenance {
                        try reducedSymbolicRadians(from: provenance)
                    } else {
                        try reducedRadians(from: argument.semanticValue)
                    }
                }
            return NSDecimalNumber(decimal: reduced).doubleValue
        }

        /// Reduces a symbolic Radian angle from its exact parts.
        ///
        /// The angle is `constant + coefficient × π`. The coefficient is reduced modulo a whole
        /// turn and the constant modulo two π, so neither the multiplied-out π nor a large
        /// constant ever has to be materialized before the phase is known.
        private func reducedSymbolicRadians(from provenance: AngleProvenance) throws -> Decimal {
            let reducedConstant = try reducedRadians(from: provenance.constant)
            let reducedCoefficient = try reducedPiCoefficient(provenance.piCoefficient)
            let coefficientAngle = try unrounded(
                NSDecimalMultiply,
                try piValue(),
                reducedCoefficient,
                allowingLossOfPrecision: true,
            )

            return try unrounded(
                NSDecimalAdd,
                reducedConstant,
                coefficientAngle,
                allowingLossOfPrecision: true,
            )
        }

        /// Reduces a π coefficient modulo one whole turn, keeping any exact fraction intact.
        private func reducedPiCoefficient(_ coefficient: PiCoefficient) throws -> Decimal {
            if let rational = coefficient.exactRational {
                let wholeTurns = rational.numerator / rational.denominator
                let remainder = rational.numerator % rational.denominator
                let fractional = try unrounded(
                    NSDecimalDivide,
                    Decimal(remainder),
                    Decimal(rational.denominator),
                    allowingLossOfPrecision: true,
                )

                return try unrounded(
                    NSDecimalAdd,
                    Decimal(wholeTurns % 2),
                    fractional,
                    allowingLossOfPrecision: true,
                )
            }

            let decimalValue = coefficient.decimalValue
            try requireSufficientPhasePrecision(for: decimalValue, modulo: 2)
            return try reducedRadians(from: decimalValue, modulo: 2)
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
            let period = try piValue() * 2
            try requireSufficientPhasePrecision(for: value, modulo: period)
            return try reducedRadians(from: value, modulo: period)
        }

        /// The calculator's π value.
        private func piValue() throws -> Decimal {
            try decimal(calculatorPiDigits)
        }

        /// The calculator's e value.
        private func eulerValue() throws -> Decimal {
            try decimal(calculatorEulerDigits)
        }

        /// Rejects Radian arguments whose phase cannot be reduced to the requested display scale.
        ///
        /// `Decimal` carries 38 significant digits, so reducing an argument of magnitude `m`
        /// leaves a phase uncertainty of roughly `m × 10⁻³⁷`. Reduction is only trusted while
        /// that uncertainty stays three orders of magnitude below the first digit the calculator
        /// displays away from zero; larger arguments report overflow instead of a numerically
        /// unreliable result. Arguments shorter than one full period need no reduction at all.
        private func requireSufficientPhasePrecision(for value: Decimal, modulo period: Decimal) throws {
            let limit = try decimal("1e\(34 - max(roundingScale, 0))")
            guard value.magnitude < period || value.magnitude < limit else {
                throw CalculatorError.overflow
            }
        }

        /// Returns the exact sine, cosine, or tangent of an angle the engine can place on the
        /// unit circle exactly.
        ///
        /// Classification never compares a floating-point value against a known angle: Degree
        /// angles come from the semantic Decimal angle reduced modulo a whole turn, and Radian
        /// angles come from exact π-relative provenance, so the symbolic π/6 qualifies while a
        /// decimal approximation of it keeps the ordinary Foundation path.
        private func exactTrigonometricResult(
            for function: Function,
            argument: ParsedValue,
        ) throws -> ExactFunctionResult? {
            guard let angle = try exactUnitCircleAngle(for: argument),
                  let value = try exactTrigonometricValue(of: function, at: angle)
            else {
                return nil
            }

            // The value is a plain scalar: the input angle's π coefficient describes the angle,
            // not the result, so only the scalar provenance composes into later terms.
            return ExactFunctionResult(
                value: value,
                angleProvenance: exactScalarProvenance(for: value),
            )
        }

        /// Classifies the angle of an exact source expression as a whole number of twelfths of π.
        ///
        /// Returns nil whenever the engine cannot prove the angle's exact position, which keeps
        /// approximate inputs on the ordinary trigonometric path.
        private func exactUnitCircleAngle(for argument: ParsedValue) throws -> ExactUnitCircleAngle? {
            switch angleMode {
            case .degrees:
                return try unitCircleAngle(forDegreeAngle: argument.semanticValue)
            case .radians:
                guard let provenance = argument.angleProvenance,
                      provenance.constant == 0
                else {
                    return nil
                }

                return unitCircleAngle(forPiCoefficient: provenance.piCoefficient)
            }
        }

        /// Classifies an exact Degree angle, ignoring angles that no closed-form family covers.
        ///
        /// Fifteen degrees is one twelfth of π, so only an exact multiple of fifteen degrees can
        /// belong to a closed-form family. The angle is read from its decimal digits, which keeps
        /// the classification independent of how many digits the angle carries and of every
        /// bounded integer or fraction representation.
        private func unitCircleAngle(forDegreeAngle value: Decimal) throws -> ExactUnitCircleAngle? {
            var reduced = try reducedDegrees(from: value)
            let text = NSDecimalString(&reduced, Locale(identifier: "en_US_POSIX"))
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
            guard fraction.isEmpty else {
                return nil
            }

            var degrees = 0
            for digit in components.first ?? "0" {
                guard let value = digit.wholeNumberValue else {
                    return nil
                }

                degrees = (degrees * 10 + value) % 360
            }
            guard degrees.isMultiple(of: 15) else {
                return nil
            }

            let twelfths = degrees / 15
            return ExactUnitCircleAngle(twelfths: isNegative ? (24 - twelfths) % 24 : twelfths)
        }

        /// Classifies an exact π coefficient, ignoring coefficients Decimal only approximates.
        private func unitCircleAngle(
            forPiCoefficient coefficient: PiCoefficient,
        ) -> ExactUnitCircleAngle? {
            if let rational = coefficient.exactRational {
                return unitCircleAngle(forPiCoefficient: rational)
            }

            guard let decimalValue = coefficient.exactDecimalValue else {
                return nil
            }

            return unitCircleAngle(forPiCoefficient: decimalValue)
        }

        /// Classifies an exact rational π coefficient as a whole number of twelfths of π.
        ///
        /// Twelve twelfths make one π, so the coefficient classifies only when it is exactly twelve
        /// times a whole number of twelfths. The exact multiplication cancels and bounds the
        /// fraction, so a coefficient whose product cannot be represented keeps the ordinary path.
        private func unitCircleAngle(
            forPiCoefficient coefficient: CalculatorExactRational,
        ) -> ExactUnitCircleAngle? {
            guard let scaled = coefficient.multiplied(by: .integer(12)),
                  scaled.denominator == 1
            else {
                return nil
            }

            return ExactUnitCircleAngle(twelfths: Int((scaled.numerator % 24 + 24) % 24))
        }

        /// Classifies an exact Decimal π coefficient, including magnitudes beyond `Int64`.
        ///
        /// Twelve times such a coefficient is a whole number only when its fraction is one of the
        /// quarter steps, so the low-order digits decide the fraction while the integer parity
        /// decides the remaining half turn. Neither step materializes the coefficient as an
        /// integer, which keeps coefficients wider than `Int64` classifiable.
        private func unitCircleAngle(forPiCoefficient coefficient: Decimal) -> ExactUnitCircleAngle? {
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

            let fractionTwelfths: Int
            switch fraction {
            case "":
                fractionTwelfths = 0
            case "25":
                fractionTwelfths = 3
            case "5":
                fractionTwelfths = 6
            case "75":
                fractionTwelfths = 9
            default:
                return nil
            }

            var integerParity = 0
            for digit in components.first ?? "0" {
                guard let value = digit.wholeNumberValue else {
                    return nil
                }

                integerParity = (integerParity * 10 + value) % 2
            }

            let twelfths = (integerParity * 12 + fractionTwelfths) % 24
            return ExactUnitCircleAngle(twelfths: isNegative ? (24 - twelfths) % 24 : twelfths)
        }

        /// Derives the exact value of a trigonometric function at a classified angle.
        ///
        /// Every reference angle is √radical / 2: zero degrees is √0 / 2, thirty degrees is √1 / 2,
        /// forty-five degrees is √2 / 2, sixty degrees is √3 / 2, and ninety degrees is √4 / 2. One
        /// Decimal square root therefore covers both closed-form families without passing a known
        /// angle through `Double`. A reference outside that table, such as π/12 or 5π/12,
        /// has no closed form this calculator supports.
        private func exactTrigonometricValue(
            of function: Function,
            at angle: ExactUnitCircleAngle,
        ) throws -> Decimal? {
            let quadrant = angle.twelfths / 6
            let remainder = angle.twelfths % 6
            let reference = quadrant.isMultiple(of: 2) ? remainder : 6 - remainder

            let radical: Int
            switch reference {
            case 0:
                radical = 0
            case 2:
                radical = 1
            case 3:
                radical = 2
            case 4:
                radical = 3
            case 6:
                radical = 4
            default:
                return nil
            }

            let sine = try halfRadical(radical, sign: quadrant < 2 ? 1 : -1)
            let cosine = try halfRadical(4 - radical, sign: quadrant == 1 || quadrant == 2 ? -1 : 1)

            switch function {
            case .sine:
                return sine
            case .cosine:
                return cosine
            case .tangent:
                guard cosine != 0 else {
                    // An exact pole belongs to the domain-error path rather than to a value.
                    throw CalculatorError.domainError
                }

                return try unrounded(NSDecimalDivide, sine, cosine, allowingLossOfPrecision: true)
            default:
                return nil
            }
        }

        /// Computes the signed half of a small square root at the precision `Decimal` carries.
        ///
        /// Every reference radical is below four, so its root is below two and thirty-seven
        /// fractional digits already hold all thirty-eight significant digits `Decimal`
        /// supports. A wider scale cannot add precision to the closed form; the value is
        /// rounded to the configured display scale after this calculation.
        private func halfRadical(_ radical: Int, sign: Int) throws -> Decimal {
            let root = try squareRoot(of: Decimal(radical), toScale: 37)
            let half = try unrounded(NSDecimalDivide, root, 2, allowingLossOfPrecision: true)
            return sign < 0 ? try negateExactly(half) : half
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
        /// The parser rounds arithmetic at the calculator's display scale, so the classification
        /// reads the semantic angle rather than the displayed digits: a symbolic π/2 keeps its
        /// exact provenance, while a decimal approximation of the same magnitude stays an ordinary
        /// finite angle. A tangent pole is an odd quarter turn, which is six of the twenty-four
        /// twelfths of π that a full turn contains.
        private func isTangentPole(for angle: ParsedValue) throws -> Bool {
            guard let classification = try exactUnitCircleAngle(for: angle) else {
                return false
            }

            return classification.twelfths % 12 == 6
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

        /// Combines two Decimals without display rounding, recording whether Decimal was exact.
        ///
        /// Phase reduction needs a coefficient even when `Decimal` can only approximate the sum,
        /// while exact quadrant and tangent-pole classification has to stay limited to sums the
        /// engine knows exactly.
        private func approximated(
            _ operation: DecimalOperation,
            _ lhs: Decimal,
            _ rhs: Decimal,
        ) -> (value: Decimal, isExact: Bool)? {
            do {
                return (try unrounded(operation, lhs, rhs), true)
            } catch {
                guard let value = try? unrounded(operation, lhs, rhs, allowingLossOfPrecision: true) else {
                    return nil
                }
                return (value, false)
            }
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
            guard let constant = try? unrounded(
                operation,
                lhs.constant,
                rhs.constant,
                allowingLossOfPrecision: true,
            ) else {
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

            let lhsCoefficient = lhs.piCoefficient.decimalCoefficient
            let rhsCoefficient = rhs.piCoefficient.decimalCoefficient
            guard let coefficient = approximated(
                operation,
                lhsCoefficient.value,
                rhsCoefficient.value,
            ) else {
                return nil
            }

            return AngleProvenance(
                constant: constant,
                piCoefficient: coefficient.isExact && lhsCoefficient.isExact && rhsCoefficient.isExact
                    ? .exactDecimal(coefficient.value)
                    : .roundedDecimal(coefficient.value),
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
            guard let constant = try? unrounded(
                operation,
                provenance.constant,
                factor,
                allowingLossOfPrecision: true,
            ) else {
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

            let sourceCoefficient = provenance.piCoefficient.decimalCoefficient
            guard let coefficient = approximated(
                operation,
                sourceCoefficient.value,
                factor,
            ) else {
                return nil
            }

            return AngleProvenance(
                constant: constant,
                piCoefficient: coefficient.isExact && sourceCoefficient.isExact
                    ? .exactDecimal(coefficient.value)
                    : .roundedDecimal(coefficient.value),
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
            } else if case .exactDecimal = provenance.piCoefficient {
                coefficientState = .exactDecimal(piCoefficient)
            } else if case .roundedDecimal = provenance.piCoefficient {
                coefficientState = .roundedDecimal(piCoefficient)
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

        /// Converts a Foundation result to Decimal using a locale-independent round-trip string.
        ///
        /// Decimal's direct Double initializer can produce NaN for finite values near the lower
        /// end of Decimal's exponent range, so parsing the Double's canonical representation keeps
        /// representable scientific results while still rejecting actual range failures. The
        /// caller applies display rounding to whatever it derives from the converted value.
        private func checkedDecimal(fromFoundationValue value: Double) throws -> Decimal {
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

            return result
        }

        /// Converts a Foundation result to Decimal without applying display rounding.
        private func semanticDecimal(_ value: Double) throws -> Decimal {
            try checkedDecimal(fromFoundationValue: value)
        }

        /// Computes a logarithm from a semantic `Decimal` argument without collapsing deltas near one.
        ///
        /// A `Double` resolves values around one no more finely than one unit in the last place
        /// (about 2.2e-16), so converting an argument such as `1.0000000000000001` directly would
        /// discard the delta that carries the whole result. The delta is therefore subtracted while
        /// the value is still a `Decimal` and converted on its own whenever the direct conversion
        /// cannot carry it, which lets `log1p` keep the low-order digits that the calculator
        /// displays. Ordinary arguments keep the direct Foundation path.
        private func logarithm(of argument: Decimal, isCommon: Bool) throws -> Decimal {
            let delta = try unrounded(NSDecimalSubtract, argument, 1, allowingLossOfPrecision: true)
            let deltaValue = NSDecimalNumber(decimal: delta).doubleValue
            let directValue = NSDecimalNumber(decimal: argument).doubleValue

            // A loss of more than one part in 10^8 of the delta counts as material; below that the
            // direct conversion still carries the delta accurately enough for the display scale.
            let reconstructionLoss = abs((directValue - 1) - deltaValue)
            if reconstructionLoss > abs(deltaValue) * 1e-8 {
                let natural = Foundation.log1p(deltaValue)

                return try semanticDecimal(isCommon ? natural / Foundation.log(10) : natural)
            }

            return try semanticDecimal(isCommon ? Foundation.log10(directValue) : Foundation.log(directValue))
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

        /// Computes the reciprocal of a square root with normalization-aware precision.
        ///
        /// The root needs enough digits for its reciprocal to stay meaningful: a value such as
        /// 10⁻⁴² has a root of 10⁻²¹, which a fixed scale would round to zero before the
        /// division. The returned reciprocal is unrounded, so the displayed half-power path and
        /// the semantic path that composes with later terms share one calculation.
        private func reciprocalSquareRoot(of value: Decimal) throws -> Decimal {
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
            return try unrounded(NSDecimalDivide, 1, root)
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

        /// Raises `base` to `exponent` without applying display rounding.
        ///
        /// Both the displayed digit string and the semantic value of a parsed power come from
        /// this one evaluation, so they cannot be computed from different operands. Exponentiation
        /// control values and intermediate products stay independent of the configured display
        /// scale; the caller rounds only the completed result.
        private func power(_ base: Decimal, _ exponent: Decimal) throws -> Decimal {
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
                return try semanticSquareRoot(of: base)
            }
            if exponent == -0.5 {
                guard base >= 0 else {
                    throw CalculatorError.domainError
                }
                return try reciprocalSquareRoot(of: base)
            }

            var integralExponent = exponent
            var exponentToRound = exponent
            NSDecimalRound(&integralExponent, &exponentToRound, 0, .plain)
            if integralExponent == exponent {
                return try unrounded(integralPower: base, exponent: integralExponent)
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
                case .orderedSame:
                    // The exact digit comparison proves the midpoint squares to the normalized
                    // value, so the midpoint is the root itself rather than a bracket endpoint.
                    return try rounded(multiplying: midpoint, normalization.scalingFactor, toScale: scale)
                case .orderedAscending:
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

        /// Resolves the final root bracket with exact squared-midpoint comparisons.
        ///
        /// The bracket can end wider than one representable step. A root with more integer digits
        /// than the coefficient can hold is adjacent to its neighbour at a step larger than one,
        /// and a root that still fits the coefficient can land several steps short. Bisecting on
        /// exact squares narrows the bracket to adjacent candidates, and one more comparison
        /// decides between them, so a rounded Decimal product is never treated as exact.
        private func roundedRootAtPrecisionLimit(
            between lowerResult: Decimal,
            and upperResult: Decimal,
            scalingFactor: Decimal,
            normalizedValue: Decimal,
        ) throws -> Decimal {
            let (lowerDigits, lowerScale) = try decimalDigitsAndScale(lowerResult)
            let (upperDigits, upperScale) = try decimalDigitsAndScale(upperResult)
            let commonScale = max(lowerScale, upperScale)
            var lower = lowerDigits + Array(repeating: 0, count: commonScale - lowerScale)
            var upper = upperDigits + Array(repeating: 0, count: commonScale - upperScale)

            // Every coefficient inside the bracket is representable at this scale, so bisecting
            // it converges on the two representable neighbours that enclose the root.
            let normalizedScale = commonScale + scalingFactor.exponent
            for _ in 0 ..< 256 {
                guard incrementingDecimalDigits(lower) != upper else {
                    break
                }

                let midpoint = halvingDecimalDigits(addingDecimalDigits(lower, upper))
                guard midpoint != lower, midpoint != upper else {
                    break
                }

                let comparison = try compareSquare(
                    of: midpoint,
                    scale: normalizedScale,
                    with: normalizedValue,
                )
                if comparison == .orderedDescending {
                    upper = midpoint
                } else {
                    lower = midpoint
                }
            }

            guard incrementingDecimalDigits(lower) == upper else {
                throw CalculatorError.overflow
            }

            let midpointDigits = multiplyDecimalDigits(
                addingDecimalDigits(lower, upper),
                by: 5,
            )

            let midpointComparison = try compareSquare(
                of: midpointDigits,
                scale: normalizedScale + 1,
                with: normalizedValue,
            )
            let nearest = midpointComparison == .orderedDescending ? lower : upper
            return try decimal(fromDigits: nearest, scale: commonScale)
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

        /// Halves a base-ten coefficient, discarding any remainder.
        private func halvingDecimalDigits(_ digits: [Int]) -> [Int] {
            var result: [Int] = []
            var carry = 0
            for digit in digits {
                let current = carry * 10 + digit
                let quotient = current / 2
                carry = current % 2
                if !result.isEmpty || quotient != 0 {
                    result.append(quotient)
                }
            }

            return result.isEmpty ? [0] : result
        }

        /// Rebuilds a Decimal from exact coefficient digits and the scale dividing them.
        private func decimal(fromDigits digits: [Int], scale: Int) throws -> Decimal {
            let coefficient = digits.map(String.init).joined()
            return try decimal(coefficient + "e" + String(-scale))
        }

        /// Converts a positive Decimal into an exact base-ten coefficient and scale.
        ///
        /// The value is `digits × 10⁻ˢᶜᵃˡᵉ`. Trailing zeros move out of the coefficient into the
        /// scale, so the representation is minimal and the scale turns negative for a whole
        /// number that ends in zeros. Callers rely on that: a root with more integer digits than
        /// the coefficient can hold is still adjacent to its neighbour, at a step larger than one,
        /// and only the trimmed coefficient shows it.
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
            while digits.count > 1, digits.last == 0 {
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
            // Display arithmetic only has to survive until the result is rounded to the display
            // scale, so a `Decimal` that keeps 38 significant digits of a longer exact result is
            // an approximation the calculator accepts. Only magnitude errors are overflow.
            try rounded(unrounded(operation, lhs, rhs, allowingLossOfPrecision: true))
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
