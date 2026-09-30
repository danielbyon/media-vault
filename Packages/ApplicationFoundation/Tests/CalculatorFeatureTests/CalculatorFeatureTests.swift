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
            try engine.evaluate("tan(1.5707963267948966192313216915)", angleMode: .radians)
        }
        #expect(throws: CalculatorError.domainError) {
            try engine.evaluate("tan(3×π/2)", angleMode: .radians)
        }

        let nearPoleDegrees = try engine.evaluate("tan(89.9999999995)", angleMode: .degrees)
        let nearPoleRadians = try engine.evaluate("tan(1.57079632675)", angleMode: .radians)
        let floatingPointNearPoleRadians = try engine.evaluate("tan(1.5707963267948967)", angleMode: .radians)
        let beyondPoleDegrees = try engine.evaluate("tan(90.0000000001)", angleMode: .degrees)
        let beyondPoleMagnitude = (Decimal(string: beyondPoleDegrees) ?? 0).magnitude
        #expect((Decimal(string: nearPoleDegrees) ?? 0) > Decimal(100_000_000_000))
        #expect((Decimal(string: nearPoleRadians) ?? 0) > Decimal(10_000_000_000))
        #expect((Decimal(string: floatingPointNearPoleRadians) ?? 0) > Decimal(1_000_000_000_000_000))
        #expect(beyondPoleMagnitude > Decimal(100_000_000_000))
    }
}
