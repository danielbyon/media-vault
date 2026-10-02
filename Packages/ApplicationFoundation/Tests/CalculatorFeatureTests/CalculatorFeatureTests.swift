//
//  CalculatorFeatureTests.swift
//  MediaVault
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import CalculatorFeature
import Foundation
import Testing

@Suite("Calculator behavior")
struct CalculatorFeatureTests {
    @Test("The calculator evaluates operator precedence")
    func evaluatesOperatorPrecedence() throws {
        #expect(try CalculatorEngine().evaluate("2 + 3 × 4") == "14")
    }

    @Test("The calculator evaluates parentheses and percent")
    func evaluatesParenthesesAndPercent() throws {
        #expect(try CalculatorEngine().evaluate("200 × (2 + 8)%") == "20")
    }

    @Test("The calculator uses deterministic rounded decimal results")
    func usesDeterministicRoundedDecimalResults() throws {
        #expect(try CalculatorEngine().evaluate("0.1 + 0.2") == "0.3")
        #expect(try CalculatorEngine().evaluate("2 ÷ 3") == "0.6666666667")
    }

    @Test("The calculator handles unary signs")
    func handlesUnarySigns() throws {
        #expect(try CalculatorEngine().evaluate("-5 + 2") == "-3")
        #expect(try CalculatorEngine().evaluate("5 - -2") == "7")
    }

    @Test("The calculator reports normal expression errors")
    func reportsNormalExpressionErrors() {
        #expect(throws: CalculatorError.divisionByZero) {
            try CalculatorEngine().evaluate("1 ÷ 0")
        }
        #expect(throws: CalculatorError.invalidExpression) {
            try CalculatorEngine().evaluate("1 +")
        }
    }

    @Test("The calculator evaluates scientific functions and constants")
    func evaluatesScientificFunctionsAndConstants() throws {
        let engine = CalculatorEngine()

        #expect(try engine.evaluate("sin(30)") == "0.5")
        #expect(try engine.evaluate("cos(60)") == "0.5")
        #expect(try engine.evaluate("tan(45)") == "1")
        #expect(try engine.evaluate("asin(0.5)") == "30")
        #expect(try engine.evaluate("acos(0.5)") == "60")
        #expect(try engine.evaluate("atan(1)") == "45")
        #expect(try engine.evaluate("ln(e)") == "1")
        #expect(try engine.evaluate("log10(100)") == "2")
        #expect(try engine.evaluate("sqrt(9)") == "3")
        #expect(try engine.evaluate("square(3)") == "9")
        #expect(try engine.evaluate("reciprocal(4)") == "0.25")
        #expect(try engine.evaluate("π") == "3.1415926536")
        #expect(try engine.evaluate("e") == "2.7182818285")
        #expect(try engine.evaluate("2 + sin(30) × square(3)") == "6.5")
    }

    @Test("Power is right-associative and binds more tightly than unary signs")
    func evaluatesScientificPowerPrecedence() throws {
        let engine = CalculatorEngine()

        #expect(try engine.evaluate("2^3^2") == "512")
        #expect(try engine.evaluate("-2^2") == "-4")
        #expect(try engine.evaluate("2^-2") == "0.25")
        #expect(try engine.evaluate("(-2)^3") == "-8")
        #expect(try engine.evaluate("(-2)^-2") == "0.25")
        #expect(try engine.evaluate("4^0.5") == "2")
    }

    @Test("Half powers use Decimal square-root evaluation")
    func halfPowersPreserveDecimalSquareRootPrecision() throws {
        let engine = CalculatorEngine()
        let largeSquare = "81129638414606699710187514626049"
        let largeRoot = try engine.evaluate("sqrt(\(largeSquare))")
        let largeHalfPower = try engine.evaluate("\(largeSquare)^0.5")

        #expect(largeRoot == "9007199254740993")
        #expect(largeHalfPower == largeRoot)
        #expect(try engine.evaluate("2^0.5") == engine.evaluate("sqrt(2)"))
        #expect(try engine.evaluate("4^-0.5") == "0.5")
        #expect(try engine.evaluate("0^0.5") == "0")
        #expect(throws: CalculatorError.divisionByZero) {
            try engine.evaluate("0^-0.5")
        }
        #expect(try engine.evaluate("16^0.25") == "2")
        #expect(throws: CalculatorError.domainError) {
            try engine.evaluate("(-2)^-0.5")
        }
    }

    @Test("Fractional powers retain semantic precision in enclosing functions")
    func fractionalPowersRetainSemanticPrecision() throws {
        let engine = CalculatorEngine()
        let power = try engine.evaluate("tan(8099.9999999928^0.5)", angleMode: .degrees)
        let squareRoot = try engine.evaluate("tan(sqrt(8099.9999999928))", angleMode: .degrees)
        let negativeHalfPower = try engine.evaluate("tan(8099.9999999928^-0.5)", angleMode: .degrees)
        let reciprocalSquareRoot = try engine.evaluate("tan(reciprocal(sqrt(8099.9999999928)))", angleMode: .degrees)

        #expect(Decimal(string: power) != nil)
        #expect(power == squareRoot)
        #expect(negativeHalfPower == reciprocalSquareRoot)
        #expect(try engine.evaluate("16^0.25") == "2")
        #expect(try engine.evaluate("tan(16^0.25)") == engine.evaluate("tan(2)"))
    }

    @Test("Identity powers preserve angle provenance while other powers discard it")
    func identityPowersPreserveAngleProvenance() throws {
        #expect(throws: CalculatorError.domainError) {
            try CalculatorEngine().evaluate("tan((π/2)^1)", angleMode: .radians)
        }
        #expect(try CalculatorEngine(roundingScale: 20).evaluate("sin((π)^1)", angleMode: .radians) == "0")
        #expect(Decimal(string: try CalculatorEngine().evaluate("tan((π/2)^2)", angleMode: .radians)) != nil)
    }

    @Test("Integral power control does not use the display rounding scale")
    func integralPowerControlIgnoresDisplayRoundingScale() throws {
        #expect(try CalculatorEngine(roundingScale: 0).evaluate("2^2") == "4")
    }

    @Test("Negative integral powers invert before exponentiation")
    func negativeIntegralPowersPreserveIntermediatePrecision() throws {
        #expect(try CalculatorEngine().evaluate("0.00000000001^-1") == "100000000000")
        #expect(try CalculatorEngine(roundingScale: 0).evaluate("0.00000000001^-1") == "100000000000")
        #expect(try CalculatorEngine().evaluate("10^-98") == "0")
        #expect(try CalculatorEngine().evaluate("10^-128") == "0")
        #expect(try CalculatorEngine().evaluate("3^-2") == "0.1111111111")
        #expect(try CalculatorEngine(roundingScale: 4).evaluate("3^-2") == "0.1111")
    }

    @Test("Integral powers preserve Decimal precision")
    func integralPowersPreserveDecimalPrecision() throws {
        #expect(try CalculatorEngine().evaluate("123456789^2") == "15241578750190521")
    }

    @Test("Powers evaluate from semantic operands and round only the result")
    func powersEvaluateFromSemanticOperands() throws {
        let engine = CalculatorEngine()

        // Rounding an operand before the power changes the operation: a root displayed as
        // 1.4142135624 squares to a value that no longer shows as 2, and a base whose display
        // collapses to zero raises a division-by-zero error instead of the reciprocal.
        #expect(try engine.evaluate("sqrt(2)^2") == "2")
        #expect(try CalculatorEngine(roundingScale: 20).evaluate("sqrt(2)^2") == "2")
        #expect(try engine.evaluate("reciprocal(3)^-1") == "3")
        #expect(try CalculatorEngine(roundingScale: 0).evaluate("reciprocal(3)^-1") == "3")

        // A scientific function supplies the exponent's semantic value as well as a base's.
        #expect(try CalculatorEngine(roundingScale: 0).evaluate("10^log10(3)") == "3")
        #expect(try engine.evaluate("10^log10(3)") == "3")
        #expect(try engine.evaluate("2^sqrt(4)") == "4")
        #expect(try engine.evaluate("3^reciprocal(2)") == "1.7320508076")

        // Every special power semantic survives the single evaluation.
        #expect(try engine.evaluate("2^3^2") == "512")
        #expect(try engine.evaluate("-2^2") == "-4")
        #expect(try engine.evaluate("2^-2") == "0.25")
        #expect(try engine.evaluate("4^0.5") == "2")
        #expect(try engine.evaluate("4^-0.5") == "0.5")
        #expect(try engine.evaluate("16^0.25") == "2")
        #expect(try engine.evaluate("0.00000000001^-1") == "100000000000")
        #expect(try engine.evaluate("10^-98") == "0")
        #expect(throws: CalculatorError.domainError) {
            try engine.evaluate("0^0")
        }
        #expect(throws: CalculatorError.divisionByZero) {
            try engine.evaluate("0^-1")
        }
        #expect(throws: CalculatorError.domainError) {
            try engine.evaluate("(-2)^0.5")
        }
    }


    @Test("Binary arithmetic composes scientific operands from their semantic values")
    func binaryArithmeticUsesSemanticScientificOperands() throws {
        let engine = CalculatorEngine()
        let preciseEngine = CalculatorEngine(roundingScale: 20)
        let smallOperand = "reciprocal(100000000000)"

        #expect(try engine.evaluate("1/\(smallOperand)") == "100000000000")
        #expect(try engine.evaluate("100000000000×\(smallOperand)") == "1")
        #expect(try engine.evaluate("\(smallOperand)×100000000000") == "1")

        #expect(try preciseEngine.evaluate("1+\(smallOperand)") == "1.00000000001")
        #expect(try preciseEngine.evaluate("\(smallOperand)+1") == "1.00000000001")
        #expect(try preciseEngine.evaluate("1-\(smallOperand)") == "0.99999999999")
        #expect(try preciseEngine.evaluate("\(smallOperand)-1") == "-0.99999999999")
        #expect(try preciseEngine.evaluate("8/square(2)") == "2")
        #expect(try preciseEngine.evaluate("square(2)/8") == "0.5")
        #expect(try preciseEngine.evaluate("\(smallOperand)/1") == "0.00000000001")
    }

    @Test("Fractional powers retain small base and exponent deltas")
    func fractionalPowersPreserveNearOneDecimalDeltas() throws {
        let engine = CalculatorEngine(roundingScale: 20)

        #expect(try engine.evaluate("1.0000000000000001^0.25") == "1.000000000000000025")
        #expect(try engine.evaluate("1.0000000000000001^1.5") == "1.00000000000000015")
        #expect(try engine.evaluate("2^1.0000000000000001") == "2.00000000000000013863")
        #expect(try engine.evaluate("16^0.25") == "2")
    }

    @Test("Square roots preserve Decimal precision and display rounding")
    func squareRootsPreserveDecimalPrecisionAndDisplayRounding() throws {
        let engine = CalculatorEngine()

        #expect(try engine.evaluate("sqrt(81129638414606699710187514626049)") == "9007199254740993")
        #expect(try engine.evaluate("sqrt(9)") == "3")
        #expect(try engine.evaluate("sqrt(2)") == "1.4142135624")
        let halfwayRoundedRoot = try engine.evaluate("sqrt(1.5241578751425088890025)")
        #expect(halfwayRoundedRoot == "1.2345678901")
        #expect(try engine.evaluate("sqrt(0)") == "0")
    }

    @Test("Large nonsquare roots converge to the configured display precision")
    func largeNonsquareRootsConvergeToDisplayPrecision() throws {
        let engine = CalculatorEngine()

        #expect(try engine.evaluate("sqrt(999999999999999999999999999999)") == "1000000000000000")
        #expect(try engine.evaluate("sqrt(1000000000000000000000000099999)") == "1000000000000000")
        #expect(try engine.evaluate("sqrt(1000000000000000000000000100001)") == "1000000000000000.0000000001")
    }

    @Test("Large square roots do not trust rounded square equality")
    func largeSquareRootsUseBracketedDisplayPrecision() throws {
        #expect(
            try CalculatorEngine().evaluate(
                "sqrt(4000000000000000000000000000000000000000000000000000000000000000)",
            ) == "63245553203367586639977870888654.370674",
        )
    }

    @Test("Exact digit-comparison midpoints return high-magnitude square roots")
    func exactHighMagnitudeSquareRootsReturnTheirMidpoints() throws {
        let engine = CalculatorEngine()
        let powerOfTenSquare = "9" + String(repeating: "0", count: 56)

        #expect(try engine.evaluate("sqrt(\(powerOfTenSquare))") == "30000000000000000000000000000")
        #expect(
            try engine.evaluate("sqrt(99999999999999999980000000000000000001)")
                == "9999999999999999999",
        )
    }

    @Test("Near-one logarithms preserve Decimal deltas for display and composition")
    func nearOneLogarithmsPreserveDecimalDeltas() throws {
        let preciseEngine = CalculatorEngine(roundingScale: 20)

        #expect(try preciseEngine.evaluate("ln(1.0000000000000001)") == "0.0000000000000001")
        #expect(try preciseEngine.evaluate("log10(1.0000000000000001)") == "0.00000000000000004343")
        #expect(try preciseEngine.evaluate("ln(0.9999999999999999)") == "-0.0000000000000001")
        #expect(try preciseEngine.evaluate("log10(0.9999999999999999)") == "-0.00000000000000004343")
        // The double-precision path is exact to the calculator's display precision at the default scale.
        let defaultEngine = CalculatorEngine()
        #expect(try defaultEngine.evaluate("ln(e)") == "1")
        #expect(try preciseEngine.evaluate("log10(100)") == "2")

        let tinyPositive = "0." + String(repeating: "0", count: 109) + "1"
        #expect(Decimal(string: try preciseEngine.evaluate("ln(\(tinyPositive))")) != nil)
        #expect(try preciseEngine.evaluate("log10(\(tinyPositive))") == "-110")

        let composedEngine = CalculatorEngine(roundingScale: 10)
        let composed = try composedEngine.evaluate(
            "tan(ln(1.0000000000000001)×10000000000000000)",
            angleMode: .radians,
        )
        #expect(composed == (try composedEngine.evaluate("tan(1)", angleMode: .radians)))

        #expect(throws: CalculatorError.domainError) {
            try preciseEngine.evaluate("ln(0)")
        }
        #expect(throws: CalculatorError.domainError) {
            try preciseEngine.evaluate("log10(-1)")
        }
    }

    @Test("The smallest Decimal square root rounds without underflow")
    func minimumDecimalSquareRootRoundsToZero() throws {
        let engine = CalculatorEngine()
        let minimumDecimal = "0." + String(repeating: "0", count: 127) + "1"

        #expect(try engine.evaluate("sqrt(\(minimumDecimal))") == "0")
    }

    @Test("The exact Euler constant keeps the natural logarithm identity")
    func naturalLogarithmRecognizesTheExactEulerConstant() throws {
        let engine = CalculatorEngine()

        #expect(try engine.evaluate("ln(e)") == "1")
        #expect(try CalculatorEngine(roundingScale: 16).evaluate("ln(e)") == "1")
        #expect(try CalculatorEngine(roundingScale: 30).evaluate("ln(e)") == "1")
        #expect(try engine.evaluate("ln(1)") == "0")

        // The identity composes, so an exact ninety degrees is a tangent pole and an exact
        // quarter turn keeps its quadrantal sine and cosine.
        #expect(throws: CalculatorError.domainError) {
            try engine.evaluate("tan(ln(e)×90)", angleMode: .degrees)
        }
        #expect(throws: CalculatorError.domainError) {
            try engine.evaluate("tan(ln(e)×π/2)", angleMode: .radians)
        }
        #expect(try CalculatorEngine(roundingScale: 20).evaluate("sin(ln(e)×π/2)", angleMode: .radians) == "1")
        #expect(try CalculatorEngine(roundingScale: 20).evaluate("cos(ln(e)×π)", angleMode: .radians) == "-1")

        // Decimal values that only approximate the constant keep the ordinary logarithm path.
        #expect(try CalculatorEngine(roundingScale: 16).evaluate("ln(2.718281828459045)") == "0.9999999999999998")
        #expect(
            try CalculatorEngine(roundingScale: 30)
                .evaluate("ln(2.7182818284590452353602874713526625)") == "0.9999999999999998",
        )
    }

    @Test("Exactly representable reciprocals keep their scalar provenance")
    func exactlyRepresentableReciprocalsKeepScalarProvenance() throws {
        let engine = CalculatorEngine()

        #expect(try engine.evaluate("reciprocal(2)") == "0.5")
        #expect(try engine.evaluate("reciprocal(4)") == "0.25")
        #expect(try engine.evaluate("reciprocal(8)") == "0.125")
        #expect(try engine.evaluate("reciprocal(-4)") == "-0.25")

        // An exact reciprocal completes a quarter turn before the tangent is taken, so every one
        // of these expressions is a pole rather than a large finite quotient.
        for expression in [
            "tan(π×reciprocal(2))",
            "tan(π×(reciprocal(4)×2))",
            "tan(π×(reciprocal(8)×4))",
            "tan(π×reciprocal(2)×2+π/2)",
        ] {
            #expect(throws: CalculatorError.domainError) {
                try engine.evaluate(expression, angleMode: .radians)
            }
        }

        // The exact quotient also feeds the closed-form angle table and ordinary arithmetic.
        let preciseEngine = CalculatorEngine(roundingScale: 20)
        #expect(try preciseEngine.evaluate("tan(π×reciprocal(4))", angleMode: .radians) == "1")
        #expect(try preciseEngine.evaluate("sin(π×reciprocal(2))", angleMode: .radians) == "1")
        #expect(try engine.evaluate("π×reciprocal(2)×2") == "3.1415926536")

        // A quotient Decimal can only approximate is not exact, so the same shape stays finite.
        #expect(Decimal(string: try engine.evaluate("tan(π×(reciprocal(3)×1.5))", angleMode: .radians)) != nil)
        #expect(throws: CalculatorError.divisionByZero) {
            try engine.evaluate("reciprocal(0)")
        }
    }

    @Test("Inverse functions and trigonometry use the selected angle mode")
    func evaluatesScientificFunctionsInBothAngleModes() throws {
        let engine = CalculatorEngine()

        #expect(try engine.evaluate("sin(90)", angleMode: .degrees) == "1")
        #expect(try engine.evaluate("sin(3600000000000090)", angleMode: .degrees) == "1")
        #expect(try engine.evaluate("sin(π/2)", angleMode: .radians) == "1")
        #expect(try engine.evaluate("asin(1)", angleMode: .degrees) == "90")
        #expect(try engine.evaluate("asin(1)", angleMode: .radians) == "1.5707963268")
    }

    @Test("Exact quadrantal sine and cosine results remain exact at high display precision")
    func quadrantalTrigonometryReturnsExactResults() throws {
        let engine = CalculatorEngine(roundingScale: 20)
        let cases = [
            ("sin(0)", "0"),
            ("sin(π/2)", "1"),
            ("sin(π)", "0"),
            ("sin(3×π/2)", "-1"),
            ("cos(0)", "1"),
            ("cos(π/2)", "0"),
            ("cos(π)", "-1"),
            ("cos(3×π/2)", "0"),
            ("sin(-π/2)", "-1"),
            ("cos(-π/2)", "0"),
        ]

        for (expression, expected) in cases {
            #expect(try engine.evaluate(expression, angleMode: .radians) == expected)
        }

        let degreeCases = [
            ("sin(0)", "0"),
            ("sin(90)", "1"),
            ("sin(180)", "0"),
            ("sin(270)", "-1"),
            ("cos(0)", "1"),
            ("cos(90)", "0"),
            ("cos(180)", "-1"),
            ("cos(270)", "0"),
        ]
        for (expression, expected) in degreeCases {
            #expect(try engine.evaluate(expression, angleMode: .degrees) == expected)
        }
        #expect(try engine.evaluate("sin(3.14159265358979323846)", angleMode: .radians) != "0")
        #expect(try engine.evaluate("cos(1.57079632679489661923)", angleMode: .radians) != "0")
    }

    @Test("Common exact angles return closed-form values at high display precision")
    func commonExactAnglesReturnClosedFormValues() throws {
        let engine = CalculatorEngine(roundingScale: 20)

        // Degree angles are classified from the semantic Decimal angle reduced modulo a whole
        // turn, so every quadrant and periodic equivalent shares the same closed form.
        let degreeCases = [
            ("sin(30)", "0.5"),
            ("cos(60)", "0.5"),
            ("tan(45)", "1"),
            ("sin(-30)", "-0.5"),
            ("cos(-60)", "0.5"),
            ("tan(-45)", "-1"),
            ("sin(150)", "0.5"),
            ("cos(120)", "-0.5"),
            ("tan(135)", "-1"),
            ("sin(210)", "-0.5"),
            ("cos(240)", "-0.5"),
            ("tan(225)", "1"),
            ("sin(330)", "-0.5"),
            ("cos(300)", "0.5"),
            ("tan(315)", "-1"),
            ("sin(390)", "0.5"),
            ("cos(420)", "0.5"),
            ("sin(450)", "1"),
            ("cos(-90)", "0"),
            ("sin(360)", "0"),
            ("cos(720)", "1"),
        ]
        for (expression, expected) in degreeCases {
            #expect(try engine.evaluate(expression, angleMode: .degrees) == expected)
        }

        // √2 / 2, √3 / 2, and √3 come from the Decimal square root rather than from an angle
        // converted through Double.
        let degreeClosedForms = [
            ("sin(45)", "0.7071067811865475244"),
            ("cos(45)", "0.7071067811865475244"),
            ("sin(60)", "0.86602540378443864676"),
            ("cos(30)", "0.86602540378443864676"),
            ("sin(120)", "0.86602540378443864676"),
            ("cos(150)", "-0.86602540378443864676"),
            ("tan(30)", "0.57735026918962576451"),
            ("tan(60)", "1.73205080756887729353"),
        ]
        for (expression, expected) in degreeClosedForms {
            #expect(try engine.evaluate(expression, angleMode: .degrees) == expected)
        }

        // The same closed forms follow from symbolic π radians, including periodic and negative
        // equivalents of the reference angles.
        let radianCases = [
            ("sin(π/6)", "0.5"),
            ("cos(π/3)", "0.5"),
            ("tan(π/4)", "1"),
            ("sin(-π/6)", "-0.5"),
            ("cos(-π/3)", "0.5"),
            ("tan(-π/4)", "-1"),
            ("sin(13×π/6)", "0.5"),
            ("cos(7×π/3)", "0.5"),
            ("sin(7×π/6)", "-0.5"),
            ("sin(11×π/6)", "-0.5"),
            ("cos(5×π/3)", "0.5"),
            ("tan(5×π/4)", "1"),
            ("sin(π/4)", "0.7071067811865475244"),
            ("cos(π/4)", "0.7071067811865475244"),
            ("sin(π/3)", "0.86602540378443864676"),
            ("cos(π/6)", "0.86602540378443864676"),
            ("tan(π/3)", "1.73205080756887729353"),
            ("tan(π/6)", "0.57735026918962576451"),
        ]
        for (expression, expected) in radianCases {
            #expect(try engine.evaluate(expression, angleMode: .radians) == expected)
        }

        // The closed forms hold at any display scale the engine supports.
        let wideEngine = CalculatorEngine(roundingScale: 30)
        #expect(try wideEngine.evaluate("sin(45)", angleMode: .degrees) == "0.707106781186547524400844362105")
        #expect(try wideEngine.evaluate("sin(60)", angleMode: .degrees) == "0.866025403784438646763723170753")
        #expect(try wideEngine.evaluate("cos(π/4)", angleMode: .radians) == "0.707106781186547524400844362105")
        #expect(try wideEngine.evaluate("tan(π/6)", angleMode: .radians) == "0.577350269189625764509148780502")
    }

    @Test("Exact angle results compose as scalars while approximations stay ordinary")
    func exactAngleResultsComposeAsScalars() throws {
        let engine = CalculatorEngine(roundingScale: 20)

        // A trigonometric result is a scalar: the input angle's π coefficient describes the
        // angle, not the result, so multiplying the result by π reaches the pole described by
        // the scalar instead of the original angle's coefficient.
        #expect(throws: CalculatorError.domainError) {
            try engine.evaluate("tan(sin(π/6)×π)", angleMode: .radians)
        }
        #expect(throws: CalculatorError.domainError) {
            try engine.evaluate("tan(cos(π/3)×π)", angleMode: .radians)
        }
        #expect(try engine.evaluate("sin(π/6)×6", angleMode: .radians) == "3")
        #expect(try engine.evaluate("sin(π/6)+sin(π/6)", angleMode: .radians) == "1")

        // Degree classification reads the semantic angle, so an angle that only rounds to a
        // common angle keeps the ordinary trigonometric path.
        #expect(try engine.evaluate("sin(30.0000000001)", angleMode: .degrees) == "0.5000000000015113")
        #expect(try engine.evaluate("sin(29.9999999999999999)", angleMode: .degrees) == "0.49999999999999994")

        // Tangent poles are read from the same reduced semantic angle, so a pole stays a domain
        // error however many digits its exact spelling carries.
        #expect(throws: CalculatorError.domainError) {
            try engine.evaluate("tan(90.00000000000000000000000000000000000000)", angleMode: .degrees)
        }
        #expect(throws: CalculatorError.domainError) {
            try engine.evaluate("tan(-270.0000000000)", angleMode: .degrees)
        }
        #expect(
            Decimal(
                string: try engine.evaluate("tan(89.99999999999999999999999999999999999999)", angleMode: .degrees),
            ) != nil,
        )

        // Angles outside the supported families keep the ordinary trigonometric path.
        #expect(try engine.evaluate("sin(15)", angleMode: .degrees) == "0.25881904510252074")
        #expect(try engine.evaluate("sin(105)", angleMode: .degrees) == "0.9659258262890683")
        #expect(try engine.evaluate("tan(75)", angleMode: .degrees) == "3.7320508075688776")
        #expect(try engine.evaluate("sin(π/12)", angleMode: .radians) == "0.2588190451025208")

        // A decimal approximation of a symbolic angle never acquires exactness: the symbolic form
        // lands on an exact result, while the same value typed out stays an approximate angle.
        #expect(try engine.evaluate("tan(π/6×6)", angleMode: .radians) == "0")
        #expect(try engine.evaluate("tan(0.52359877559829887308×6)", angleMode: .radians) != "0")
        #expect(try engine.evaluate("tan(π/4×4)", angleMode: .radians) == "0")
        #expect(try engine.evaluate("tan(0.78539816339744830962×4)", angleMode: .radians) != "0")
        #expect(try engine.evaluate("cos(1.04719755119659774615)", angleMode: .radians) == "0.4999999999999999")
        #expect(try engine.evaluate("tan(0.78539816339744830962)", angleMode: .radians) == "0.9999999999999999")
    }

    @Test("Large Decimal multiples retain exact pi-turn classification")
    func largePiCoefficientsPreserveQuadrantalProvenance() throws {
        let engine = CalculatorEngine()
        let largeInteger = "9223372036854775808"

        #expect(throws: CalculatorError.domainError) {
            try engine.evaluate("tan(π×\(largeInteger)+π/2)", angleMode: .radians)
        }
        #expect(throws: CalculatorError.domainError) {
            try engine.evaluate("tan(π×-\(largeInteger)-π/2)", angleMode: .radians)
        }
        #expect(try engine.evaluate("sin(π×\(largeInteger))", angleMode: .radians) == "0")
        #expect(try engine.evaluate("cos(π×\(largeInteger)+π/2)", angleMode: .radians) == "0")
        #expect(Decimal(string: try engine.evaluate("tan(π×\(largeInteger)+π/4)", angleMode: .radians)) != nil)
    }

    @Test("Direct Radians trigonometry reduces large angles before Double conversion")

    func directRadiansTrigonometryReducesLargeAngles() throws {
        let engine = CalculatorEngine()

        #expect(try engine.evaluate("sin(1000000000000000×π+π/2)", angleMode: .radians) == "1")
        #expect(try engine.evaluate("cos(1000000000000001×π)", angleMode: .radians) == "-1")
        #expect(try engine.evaluate("sin(π/2)", angleMode: .radians) == "1")
    }

    @Test("Scientific functions report invalid mathematical domains")
    func scientificDomainErrorsAreExplicit() {
        let engine = CalculatorEngine()

        #expect(throws: CalculatorError.domainError) { try engine.evaluate("sqrt(-1)") }
        #expect(throws: CalculatorError.domainError) { try engine.evaluate("ln(0)") }
        #expect(throws: CalculatorError.domainError) { try engine.evaluate("asin(2)") }
        #expect(throws: CalculatorError.domainError) { try engine.evaluate("asin(1.00000000000000001)") }
        #expect(throws: CalculatorError.domainError) { try engine.evaluate("acos(-1.00000000000000001)") }
        #expect(throws: CalculatorError.domainError) { try engine.evaluate("0^0") }
        #expect(throws: CalculatorError.domainError) { try engine.evaluate("(-2)^0.5") }
        #expect(throws: CalculatorError.divisionByZero) { try engine.evaluate("0^-1") }
        #expect(throws: CalculatorError.overflow) { try engine.evaluate("10^1000") }
    }

    @Test("Tangent poles are detected deterministically in both angle modes")
    func tangentPolesUseCalculatorRepresentableAngles() throws {
        let engine = CalculatorEngine()

        #expect(throws: CalculatorError.domainError) {
            try engine.evaluate("tan(90)", angleMode: .degrees)
        }
        #expect(throws: CalculatorError.domainError) {
            try engine.evaluate("tan(π/2)", angleMode: .radians)
        }
        #expect(throws: CalculatorError.domainError) {
            try engine.evaluate("tan(3×π/2)", angleMode: .radians)
        }
        #expect(throws: CalculatorError.domainError) {
            try engine.evaluate("tan(-π/2)", angleMode: .radians)
        }
        #expect(throws: CalculatorError.domainError) {
            try engine.evaluate("tan(-3×π/2)", angleMode: .radians)
        }

        let nearPoleDegrees = try engine.evaluate("tan(89.9999999995)", angleMode: .degrees)
        let nearPoleRadians = try engine.evaluate("tan(1.57079632675)", angleMode: .radians)
        let floatingPointNearPoleRadians = try engine.evaluate("tan(1.5707963267948967)", angleMode: .radians)
        let decimalPiHalfApproximation = try engine.evaluate(
            "tan(1.5707963267948966192313216915)",
            angleMode: .radians,
        )
        let roundedPiHalfApproximation = try engine.evaluate("tan(1.5707963268)", angleMode: .radians)
        let beyondPoleDegrees = try engine.evaluate("tan(90.0000000001)", angleMode: .degrees)
        let beyondPoleMagnitude = (Decimal(string: beyondPoleDegrees) ?? 0).magnitude
        #expect((Decimal(string: nearPoleDegrees) ?? 0) > Decimal(100_000_000_000))
        #expect((Decimal(string: nearPoleRadians) ?? 0) > Decimal(10_000_000_000))
        let floatingPointNearPole = try #require(Decimal(string: floatingPointNearPoleRadians))
        let floatingPointNearPoleMagnitude = floatingPointNearPole < 0 ? -floatingPointNearPole : floatingPointNearPole
        #expect(floatingPointNearPoleMagnitude > Decimal(1_000_000_000_000_000))
        #expect(Decimal(string: decimalPiHalfApproximation) != nil)
        #expect(Decimal(string: roundedPiHalfApproximation) != nil)
        #expect(beyondPoleMagnitude > Decimal(100_000_000_000))
    }

    @Test("Degree tangent poles use the unrounded angle expression")
    func degreeTangentPoleClassificationIgnoresDisplayRoundingScale() throws {
        let engine = CalculatorEngine(roundingScale: 0)
        let roundedNearPole = try engine.evaluate("tan(89.9+0)", angleMode: .degrees)
        let roundedScientificResult = try engine.evaluate("tan(square(9.5))", angleMode: .degrees)

        #expect(Decimal(string: roundedNearPole) != nil)
        #expect(Decimal(string: roundedScientificResult) != nil)
        #expect(throws: CalculatorError.domainError) {
            try engine.evaluate("tan(90)", angleMode: .degrees)
        }
    }

    @Test("Radian tangent pole classification ignores display rounding scale")
    func radianTangentPoleClassificationIgnoresDisplayRoundingScale() throws {
        let zeroScaleEngine = CalculatorEngine(roundingScale: 0)
        let oneScaleEngine = CalculatorEngine(roundingScale: 1)

        let zeroScaleOrdinaryAngle = try zeroScaleEngine.evaluate("tan(2)", angleMode: .radians)
        let oneScaleOrdinaryAngle = try oneScaleEngine.evaluate("tan(1.6)", angleMode: .radians)

        #expect(Decimal(string: zeroScaleOrdinaryAngle) != nil)
        #expect(Decimal(string: oneScaleOrdinaryAngle) != nil)
        #expect(throws: CalculatorError.domainError) {
            try zeroScaleEngine.evaluate("tan(π/2)", angleMode: .radians)
        }
        #expect(throws: CalculatorError.domainError) {
            try oneScaleEngine.evaluate("tan(π/2)", angleMode: .radians)
        }
    }

    @Test("Tangent evaluates the same semantic degree angle used for pole classification")
    func tangentEvaluationUsesSemanticDegreeAngle() throws {
        let engine = CalculatorEngine()
        let direct = try engine.evaluate("tan(89.99999999996)", angleMode: .degrees)
        let composed = try engine.evaluate("tan(89.99999999996+0)", angleMode: .degrees)

        #expect(composed == direct)
    }


    @Test("Large arctangents retain their small asymptotic angle for tangent")
    func largeArctangentsPreserveTangentMagnitude() throws {
        let engine = CalculatorEngine()
        let relativeTolerance = try #require(Decimal(string: "0.00000000000001"))

        func approximatelyMatches(_ actual: Decimal, _ expected: Decimal) -> Bool {
            let difference = actual >= expected ? actual - expected : expected - actual
            let magnitude = expected < 0 ? -expected : expected
            return difference <= magnitude * relativeTolerance
        }

        let positiveDegree = try #require(Decimal(string: try engine.evaluate(
            "tan(atan(10000000000000000))",
            angleMode: .degrees,
        )))
        let negativeDegree = try #require(Decimal(string: try engine.evaluate(
            "tan(atan(-10000000000000000))",
            angleMode: .degrees,
        )))
        let positiveRadians = try #require(Decimal(string: try engine.evaluate(
            "tan(atan(100000000000000000000))",
            angleMode: .radians,
        )))
        let negativeRadians = try #require(Decimal(string: try engine.evaluate(
            "tan(atan(-100000000000000000000))",
            angleMode: .radians,
        )))

        #expect(approximatelyMatches(positiveDegree, 10_000_000_000_000_000))
        #expect(approximatelyMatches(negativeDegree, -10_000_000_000_000_000))
        let expectedRadians = Decimal(string: "100000000000000000000")!
        #expect(approximatelyMatches(positiveRadians, expectedRadians))
        #expect(approximatelyMatches(negativeRadians, -expectedRadians))

        // These angles are too close to the pole for Decimal to keep the delta beside 90 or π/2.
        // The parsed arctangent must carry that nonzero residual into tangent evaluation.
        let extremeArgument = "1" + String(repeating: "0", count: 100)
        let extremeExpected = try #require(Decimal(string: extremeArgument))
        for mode in [CalculatorAngleMode.degrees, .radians] {
            let positive = try #require(Decimal(string: engine.evaluate(
                "tan(atan(\(extremeArgument)))",
                angleMode: mode,
            )))
            let negative = try #require(Decimal(string: engine.evaluate(
                "tan(atan(-\(extremeArgument)))",
                angleMode: mode,
            )))
            let positiveAfterZero = try #require(Decimal(string: engine.evaluate(
                "tan(atan(\(extremeArgument)) + 0)",
                angleMode: mode,
            )))
            let negativeAfterZero = try #require(Decimal(string: engine.evaluate(
                "tan(atan(-\(extremeArgument)) + 0)",
                angleMode: mode,
            )))
            let positiveAfterSubtractingZero = try #require(Decimal(string: engine.evaluate(
                "tan(atan(\(extremeArgument)) − 0)",
                angleMode: mode,
            )))
            let positiveAfterMultiplyingByOne = try #require(Decimal(string: engine.evaluate(
                "tan(atan(\(extremeArgument)) × 1)",
                angleMode: mode,
            )))
            let positiveAfterDividingByOne = try #require(Decimal(string: engine.evaluate(
                "tan(atan(\(extremeArgument)) ÷ 1)",
                angleMode: mode,
            )))
            let negatedBySubtraction = try #require(Decimal(string: engine.evaluate(
                "tan(0 − atan(\(extremeArgument)))",
                angleMode: mode,
            )))
            #expect(approximatelyMatches(positive, extremeExpected))
            #expect(approximatelyMatches(negative, -extremeExpected))
            #expect(approximatelyMatches(positiveAfterZero, extremeExpected))
            #expect(approximatelyMatches(negativeAfterZero, -extremeExpected))
            #expect(approximatelyMatches(positiveAfterSubtractingZero, extremeExpected))
            #expect(approximatelyMatches(positiveAfterMultiplyingByOne, extremeExpected))
            #expect(approximatelyMatches(positiveAfterDividingByOne, extremeExpected))
            #expect(approximatelyMatches(negatedBySubtraction, -extremeExpected))
        }

        #expect(try engine.evaluate("atan(1)", angleMode: .degrees) == "45")
        #expect(try engine.evaluate("atan(-1)", angleMode: .degrees) == "-45")
        #expect(try engine.evaluate("tan(atan(2))") == "2")
        #expect(throws: CalculatorError.domainError) {
            try engine.evaluate("tan(atan(1)×2)", angleMode: .radians)
        }
    }


    @Test("Exact inverse half-angles preserve tangent pole provenance")
    func exactInverseHalfAnglesPreserveTangentPoleProvenance() throws {
        let engine = CalculatorEngine()
        let inverseResults = [
            ("asin(0.5)", "30", "0.5235987756"),
            ("asin(-0.5)", "-30", "-0.5235987756"),
            ("acos(0.5)", "60", "1.0471975512"),
            ("acos(-0.5)", "120", "2.0943951024"),
        ]
        let poleExpressions = [
            "tan(asin(0.5)×3)",
            "tan(asin(-0.5)×3)",
            "tan(-asin(0.5)×3)",
            "tan(acos(0.5)×1.5)",
            "tan(acos(-0.5)×0.75)",
        ]

        for (expression, degrees, radians) in inverseResults {
            #expect(try engine.evaluate(expression, angleMode: .degrees) == degrees)
            #expect(try engine.evaluate(expression, angleMode: .radians) == radians)
        }

        for expression in poleExpressions {
            #expect(throws: CalculatorError.domainError) {
                try engine.evaluate(expression, angleMode: .degrees)
            }
            #expect(throws: CalculatorError.domainError) {
                try engine.evaluate(expression, angleMode: .radians)
            }
        }

        for angleMode in [CalculatorAngleMode.degrees, .radians] {
            let nearby = try engine.evaluate("tan(asin(0.5000001)×3)", angleMode: angleMode)
            #expect(Decimal(string: nearby) != nil)
        }

        let largeNegativeScalar = try engine.evaluate("π×-9223372036854775808", angleMode: .radians)
        #expect(Decimal(string: largeNegativeScalar) != nil)
    }

    @Test("Finite tiny scientific results round to zero without overflow")
    func tinyScientificResultsConvertToDecimalBeforeDisplayRounding() throws {
        let engine = CalculatorEngine()
        let tiny = "0." + String(repeating: "0", count: 109) + "1"
        let minimumDecimal = "0." + String(repeating: "0", count: 127) + "1"

        #expect(try engine.evaluate("sin(\(tiny))", angleMode: .radians) == "0")
        #expect(try engine.evaluate("sin(-\(tiny))", angleMode: .radians) == "0")
        #expect(try engine.evaluate("sin(30)", angleMode: .degrees) == "0.5")
        #expect(throws: CalculatorError.overflow) {
            try engine.evaluate("10^1000.5")
        }
        #expect(throws: CalculatorError.overflow) {
            try engine.evaluate("\(minimumDecimal)^2.1")
        }
    }

    @Test("Inverse trigonometric results preserve exact tangent pole semantics")
    func inverseTrigonometricResultsPreserveTangentPoleSemantics() throws {
        let engine = CalculatorEngine()

        for expression in ["tan(asin(1))", "tan(acos(0))", "tan(atan(1)×2)"] {
            #expect(throws: CalculatorError.domainError) {
                try engine.evaluate(expression, angleMode: .degrees)
            }
            #expect(throws: CalculatorError.domainError) {
                try engine.evaluate(expression, angleMode: .radians)
            }
        }

        let nearPoleDegrees = try engine.evaluate("tan(asin(0.9999999999))", angleMode: .degrees)
        let nearPoleRadians = try engine.evaluate("tan(asin(0.9999999999))", angleMode: .radians)
        #expect(Decimal(string: nearPoleDegrees) != nil)
        #expect(Decimal(string: nearPoleRadians) != nil)
    }

    @Test("Inverse trigonometric semantic results ignore display rounding before tangent")
    func inverseTrigonometricSemanticResultsIgnoreDisplayRounding() throws {
        let engine = CalculatorEngine(roundingScale: 0)
        #expect(try engine.evaluate("tan(asin(0.999))", angleMode: .degrees) == "22")
        #expect(try engine.evaluate("tan(asin(0.999))", angleMode: .radians) == "22")
    }

    @Test("Inverse trigonometric endpoints preserve the Decimal operand distance")
    func inverseTrigonometricEndpointsPreserveDecimalDistance() throws {
        let engine = CalculatorEngine()
        let precise = CalculatorEngine(roundingScale: 20)
        let nearPositiveOne = "0.99999999999999999"
        let nearNegativeOne = "-0.99999999999999999"
        let highPrecisionTolerance = Decimal(string: "0.000000000001")!
        func isHighPrecisionClose(_ actual: Decimal, to expected: Decimal) -> Bool {
            let difference = actual >= expected ? actual - expected : expected - actual
            return difference < highPrecisionTolerance
        }

        // Both operands convert to the `Double` endpoint itself, so a direct conversion would
        // report a quarter turn and lose the distance that keeps the angle off the pole.
        #expect(try engine.evaluate("asin(\(nearPositiveOne))", angleMode: .degrees) == "89.9999997438")
        #expect(try engine.evaluate("asin(\(nearPositiveOne))", angleMode: .radians) == "1.5707963223")
        let preciseAsinDegrees = try #require(Decimal(string: precise.evaluate(
            "asin(\(nearPositiveOne))",
            angleMode: .degrees,
        )))
        let preciseAsinRadians = try #require(Decimal(string: precise.evaluate(
            "asin(\(nearPositiveOne))",
            angleMode: .radians,
        )))
        #expect(isHighPrecisionClose(preciseAsinDegrees, to: Decimal(string: "89.99999974376549")!))
        #expect(isHighPrecisionClose(preciseAsinRadians, to: Decimal(string: "1.5707963223227606")!))
        #expect(try engine.evaluate("asin(\(nearNegativeOne))", angleMode: .degrees) == "-89.9999997438")
        #expect(try engine.evaluate("asin(\(nearNegativeOne))", angleMode: .radians) == "-1.5707963223")
        #expect(try engine.evaluate("acos(\(nearPositiveOne))", angleMode: .degrees) == "0.0000002562")
        #expect(try engine.evaluate("acos(\(nearPositiveOne))", angleMode: .radians) == "0.0000000045")
        #expect(try engine.evaluate("acos(\(nearNegativeOne))", angleMode: .degrees) == "179.9999997438")
        #expect(try engine.evaluate("acos(\(nearNegativeOne))", angleMode: .radians) == "3.1415926491")

        let arcSineDegrees = try #require(
            Decimal(string: engine.evaluate("asin(\(nearPositiveOne))", angleMode: .degrees)),
        )
        let arcCosineDegrees = try #require(
            Decimal(string: engine.evaluate("acos(\(nearPositiveOne))", angleMode: .degrees)),
        )
        let negativeArcCosineDegrees = try #require(
            Decimal(string: engine.evaluate("acos(\(nearNegativeOne))", angleMode: .degrees)),
        )
        #expect(arcSineDegrees < 90)
        #expect(arcCosineDegrees > 0)
        #expect(negativeArcCosineDegrees < 180)

        // The recovered angle is finite and its tangent tracks the Decimal endpoint ratio.
        let expectedTangent = Decimal(string: "223606797.749978967963866")!
        let tangentTolerance = Decimal(string: "0.01")!
        func isClose(_ actual: Decimal, to expected: Decimal) -> Bool {
            let difference = actual >= expected ? actual - expected : expected - actual
            return difference < tangentTolerance
        }
        let positiveDegreeTangent = try #require(Decimal(string: engine.evaluate(
            "tan(asin(\(nearPositiveOne)))",
            angleMode: .degrees,
        )))
        let positiveRadianTangent = try #require(Decimal(string: engine.evaluate(
            "tan(asin(\(nearPositiveOne)))",
            angleMode: .radians,
        )))
        let negativeDegreeTangent = try #require(Decimal(string: engine.evaluate(
            "tan(asin(\(nearNegativeOne)))",
            angleMode: .degrees,
        )))
        #expect(isClose(positiveDegreeTangent, to: expectedTangent))
        #expect(isClose(positiveRadianTangent, to: expectedTangent))
        #expect(isClose(negativeDegreeTangent, to: -expectedTangent))

        // Exact endpoint results and operands away from the endpoints keep their established values.
        #expect(try precise.evaluate("asin(1)", angleMode: .degrees) == "90")
        #expect(try precise.evaluate("acos(-1)", angleMode: .degrees) == "180")
        #expect(try precise.evaluate("asin(0.4999999999)", angleMode: .degrees) == "29.999999993384055")
        #expect(try precise.evaluate("asin(0.4999999999)", angleMode: .radians) == "0.5235987754828288")
        #expect(try precise.evaluate("asin(0.3)", angleMode: .degrees) == "17.45760312372209")

        // Domain checking still happens against the Decimal operand.
        for expression in ["asin(1.00000000000000000001)", "acos(-1.00000000000000000001)"] {
            #expect(throws: CalculatorError.domainError) {
                try engine.evaluate(expression, angleMode: .degrees)
            }
        }
    }

    @Test("Radian reduction keeps enough phase precision for large numeric arguments")
    func radianReductionKeepsPhasePrecisionForLargeArguments() throws {
        let engine = CalculatorEngine()
        let largeAngle = "100000000000000000000"

        #expect(try engine.evaluate("sin(\(largeAngle))", angleMode: .radians) == "-0.6452512853")
        #expect(try engine.evaluate("cos(\(largeAngle))", angleMode: .radians) == "0.7639704044")
        #expect(try engine.evaluate("tan(\(largeAngle))", angleMode: .radians) == "-0.844602463")
        #expect(try engine.evaluate("sin(\(largeAngle))", angleMode: .degrees) == "-0.984807753")
    }

    @Test("Radian arguments beyond the guaranteed reduction range report overflow")
    func radianArgumentsBeyondTheGuaranteedRangeReportOverflow() {
        let engine = CalculatorEngine()
        let beyondRange = "1000000000000000000000000000000"

        #expect(throws: CalculatorError.overflow) {
            try engine.evaluate("sin(\(beyondRange))", angleMode: .radians)
        }
        #expect(throws: CalculatorError.overflow) {
            try engine.evaluate("cos(\(beyondRange))", angleMode: .radians)
        }
    }

    @Test("Exact inverse trigonometric results drive the displayed value at high precision")
    func exactInverseTrigonometryDrivesTheDisplayedValue() throws {
        let engine = CalculatorEngine(roundingScale: 20)

        let degreeCases = [
            ("asin(0.5)", "30"),
            ("asin(-0.5)", "-30"),
            ("asin(1)", "90"),
            ("asin(-1)", "-90"),
            ("acos(0.5)", "60"),
            ("acos(-0.5)", "120"),
            ("acos(0)", "90"),
            ("acos(1)", "0"),
            ("acos(-1)", "180"),
            ("atan(1)", "45"),
            ("atan(-1)", "-45"),
            ("atan(0)", "0"),
        ]
        for (expression, expected) in degreeCases {
            #expect(try engine.evaluate(expression, angleMode: .degrees) == expected)
        }

        let radianCases = [
            ("asin(0.5)", "0.52359877559829887308"),
            ("asin(-0.5)", "-0.52359877559829887308"),
            ("asin(1)", "1.57079632679489661923"),
            ("asin(-1)", "-1.57079632679489661923"),
            ("acos(0.5)", "1.04719755119659774615"),
            ("acos(-0.5)", "2.09439510239319549231"),
            ("acos(0)", "1.57079632679489661923"),
            ("acos(1)", "0"),
            ("acos(-1)", "3.14159265358979323846"),
            ("atan(1)", "0.78539816339744830962"),
            ("atan(-1)", "-0.78539816339744830962"),
            ("atan(0)", "0"),
        ]
        for (expression, expected) in radianCases {
            #expect(try engine.evaluate(expression, angleMode: .radians) == expected)
        }

        // Inputs outside the exact table keep the ordinary double-precision result.
        #expect(try engine.evaluate("asin(0.4999999999)", angleMode: .degrees) == "29.999999993384055")
        #expect(try engine.evaluate("asin(0.4999999999)", angleMode: .radians) == "0.5235987754828288")
    }

    @Test("Scientific functions compose from the semantic operand")
    func scientificFunctionsComposeFromSemanticOperands() throws {
        let engine = CalculatorEngine()

        #expect(try engine.evaluate("square(sqrt(2))") == "2")
        #expect(try engine.evaluate("reciprocal(reciprocal(3))") == "3")
        #expect(try engine.evaluate("reciprocal(square(0.000001))") == "1000000000000")
        #expect(try engine.evaluate("sqrt(square(7))") == "7")
        #expect(try engine.evaluate("log10(square(10))") == "2")
        #expect(try engine.evaluate("sin(asin(0.5))", angleMode: .degrees) == "0.5")
        #expect(try engine.evaluate("asin(sin(30))", angleMode: .degrees) == "30")
        #expect(try engine.evaluate("tan(atan(1))", angleMode: .degrees) == "1")
    }

    @Test("Exact scalar scientific results keep the symbolic angle they compose with")
    func exactScalarScientificResultsKeepSymbolicAngles() throws {
        let engine = CalculatorEngine()
        let exactZeroAdditions = [
            "tan(π/2+sin(0))",
            "tan(π/2+cos(π/2))",
            "tan(π/2+asin(0))",
            "tan(π/2+atan(0))",
            "tan(π/2+acos(1))",
            "tan(π/2+sqrt(0))",
            "tan(π/2+square(0))",
            "tan(π/2+ln(1))",
            "tan(π/2+log10(1))",
        ]

        for expression in exactZeroAdditions {
            #expect(throws: CalculatorError.domainError) {
                try engine.evaluate(expression, angleMode: .radians)
            }
        }

        // A function result that only rounds toward zero is not exact, so the pole stays finite.
        let symbolicNearPole = try #require(Decimal(string: engine.evaluate(
            "tan(π/2+sin(0.0000000001))",
            angleMode: .radians,
        )))
        let symbolicNearPoleError = symbolicNearPole + 10_000_000_000
        #expect(symbolicNearPoleError > -1 && symbolicNearPoleError < 1)

        // Degree mode keeps the exactness in the semantic angle rather than in provenance.
        #expect(throws: CalculatorError.domainError) {
            try engine.evaluate("tan(90+sin(0))", angleMode: .degrees)
        }
    }


    @Test("Exact nonzero squares and roots preserve scalar provenance")
    func exactSquaresAndRootsPreserveScalarProvenance() throws {
        let engine = CalculatorEngine(roundingScale: 20)

        #expect(throws: CalculatorError.domainError) {
            try engine.evaluate("tan(π×square(1)/2)", angleMode: .radians)
        }
        #expect(throws: CalculatorError.domainError) {
            try engine.evaluate("tan(π×sqrt(1)/2)", angleMode: .radians)
        }
        #expect(try engine.evaluate("sin(π×square(1))", angleMode: .radians) == "0")
        #expect(try engine.evaluate("square(3)") == "9")
        #expect(try engine.evaluate("sqrt(9)") == "3")

        // Approximate roots and squares that lose Decimal precision must not become exact scalars.
        let irrationalRootComposition = try? engine.evaluate("tan(π×sqrt(2)/(sqrt(2)×2))", angleMode: .radians)
        let roundedSquareComposition = try? engine.evaluate(
            "tan(π×square(123456789012345678901234567890)/(square(123456789012345678901234567890)×2))",
            angleMode: .radians,
        )
        #expect(irrationalRootComposition != nil, "An approximate sqrt(2) must not create exact pole provenance")
        #expect(roundedSquareComposition != nil, "A rounded square must not create exact pole provenance")
    }

    @Test("The e constant carries the full Decimal precision of the engine")
    func eulerConstantCarriesFullDecimalPrecision() throws {
        let preciseEngine = CalculatorEngine(roundingScale: 30)

        #expect(try preciseEngine.evaluate("e") == "2.718281828459045235360287471353")
        #expect(try preciseEngine.evaluate("e", angleMode: .radians) == "2.718281828459045235360287471353")
        #expect(try CalculatorEngine().evaluate("e") == "2.7182818285")
        #expect(try CalculatorEngine().evaluate("ln(e)") == "1")
    }

    @Test("Symbolic pi angles reduce from provenance before materializing")
    func symbolicPiAnglesReduceFromProvenance() throws {
        let engine = CalculatorEngine()
        let largeCoefficient = "100000000000000000000"

        #expect(try engine.evaluate("tan(π×\(largeCoefficient)+π/4)", angleMode: .radians) == "1")
        #expect(try engine.evaluate("tan(π×\(largeCoefficient)-π/4)", angleMode: .radians) == "-1")
        #expect(try engine.evaluate("sin(π×\(largeCoefficient)+π/2)", angleMode: .radians) == "1")
        #expect(try engine.evaluate("sin(π×\(largeCoefficient)+π/6)", angleMode: .radians) == "0.5")
        #expect(try engine.evaluate("cos(π×\(largeCoefficient))", angleMode: .radians) == "1")
        #expect(try engine.evaluate("cos(π×\(largeCoefficient)+π)", angleMode: .radians) == "-1")
        #expect(try engine.evaluate("sin(π×\(largeCoefficient)+π)", angleMode: .radians) == "0")
        #expect(try engine.evaluate("sin(-π×\(largeCoefficient)+π/2)", angleMode: .radians) == "1")
        #expect(try engine.evaluate("cos(-π×\(largeCoefficient))", angleMode: .radians) == "1")

        // Nonquadrantal phases keep the phase of the small-angle form of the same expression.
        #expect(
            try engine.evaluate("tan(π×\(largeCoefficient)+π/3)", angleMode: .radians)
                == (try engine.evaluate("tan(π/3)", angleMode: .radians)),
        )
        #expect(
            try engine.evaluate("tan(-π×\(largeCoefficient)+π/3)", angleMode: .radians)
                == (try engine.evaluate("tan(π/3)", angleMode: .radians)),
        )
        #expect(
            try engine.evaluate("sin(π×\(largeCoefficient)+π/3)", angleMode: .radians)
                == (try engine.evaluate("sin(π/3)", angleMode: .radians)),
        )

        // An exact numeric constant keeps its own phase next to a large symbolic coefficient.
        #expect(
            try engine.evaluate("tan(π×\(largeCoefficient)+5)", angleMode: .radians)
                == (try engine.evaluate("tan(5)", angleMode: .radians)),
        )
    }

    @Test("Precision-limit square roots reason about Decimal ULP spacing")
    func precisionLimitSquareRootsReasonAboutDecimalULPSpacing() throws {
        let engine = CalculatorEngine()
        let zeros = String(repeating: "0", count: 77)

        #expect(try engine.evaluate("sqrt(1\(zeros))") == "316227766016837933199889354443271853372")
        #expect(try engine.evaluate("sqrt(10^77)") == "316227766016837933199889354443271853372")
        #expect(try engine.evaluate("sqrt(2\(zeros))") == "447213595499957939281834733746255247090")
        #expect(try engine.evaluate("sqrt(3\(zeros))") == "547722557505166113456969782800802133950")
    }

    @Test("Negative half powers share the normalization-aware root")
    func negativeHalfPowersShareTheNormalizationAwareRoot() throws {
        let engine = CalculatorEngine()
        let tinyBase = "0." + String(repeating: "0", count: 41) + "1"

        #expect(try engine.evaluate("\(tinyBase)^-0.5") == "1000000000000000000000")
        #expect(try engine.evaluate("2×\(tinyBase)^-0.5") == "2000000000000000000000")
        #expect(try engine.evaluate("4^-0.5") == "0.5")
        #expect(throws: CalculatorError.divisionByZero) {
            try engine.evaluate("0^-0.5")
        }
        #expect(throws: CalculatorError.domainError) {
            try engine.evaluate("(-4)^-0.5")
        }
    }
}
