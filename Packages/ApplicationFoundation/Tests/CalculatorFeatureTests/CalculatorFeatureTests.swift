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

    @Test("The smallest Decimal square root rounds without underflow")
    func minimumDecimalSquareRootRoundsToZero() throws {
        let engine = CalculatorEngine()
        let minimumDecimal = "0." + String(repeating: "0", count: 127) + "1"

        #expect(try engine.evaluate("sqrt(\(minimumDecimal))") == "0")
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
        #expect((Decimal(string: floatingPointNearPoleRadians) ?? 0) > Decimal(1_000_000_000_000_000))
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
}
