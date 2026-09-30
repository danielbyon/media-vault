//
//  CalculatorExactRational.swift
//  MediaVault
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

/// Represents bounded exact fractions used to preserve symbolic multiples of pi.
struct CalculatorExactRational: Equatable {
    let numerator: Int64
    let denominator: Int64

    private init(uncheckedNumerator numerator: Int64, denominator: Int64) {
        self.numerator = numerator
        self.denominator = denominator
    }

    static let zero = Self(uncheckedNumerator: 0, denominator: 1)
    static let one = Self(uncheckedNumerator: 1, denominator: 1)
    static let half = Self(uncheckedNumerator: 1, denominator: 2)
    static let negativeHalf = Self(uncheckedNumerator: -1, denominator: 2)
    static let oneSixth = Self(uncheckedNumerator: 1, denominator: 6)
    static let negativeOneSixth = Self(uncheckedNumerator: -1, denominator: 6)
    static let oneThird = Self(uncheckedNumerator: 1, denominator: 3)
    static let twoThirds = Self(uncheckedNumerator: 2, denominator: 3)
    static let oneQuarter = Self(uncheckedNumerator: 1, denominator: 4)
    static let negativeOneQuarter = Self(uncheckedNumerator: -1, denominator: 4)

    var isZero: Bool {
        numerator == 0
    }

    var isOddInteger: Bool {
        denominator == 1 && numerator % 2 != 0
    }

    static func integer(_ value: Int64) -> Self {
        Self(uncheckedNumerator: value, denominator: 1)
    }

    /// Converts a finite Decimal scalar to an exact fraction when its digits fit Int64.
    static func decimal(_ value: Decimal) -> Self? {
        var value = value
        let text = NSDecimalString(&value, Locale(identifier: "en_US_POSIX"))
        let isNegative = text.first == "-"
        let unsignedText = isNegative ? String(text.dropFirst()) : text
        let components = unsignedText.split(separator: ".", omittingEmptySubsequences: false)
        guard components.count <= 2,
              components.allSatisfy({ $0.allSatisfy(\.isNumber) })
        else {
            return nil
        }

        let integerDigits = components.first.map(String.init) ?? "0"
        var fractionDigits = components.count == 2 ? String(components[1]) : ""
        while fractionDigits.last == "0" {
            fractionDigits.removeLast()
        }
        guard fractionDigits.count <= 18 else {
            return nil
        }

        let digits = (integerDigits + fractionDigits).drop(while: { $0 == "0" })
        guard !digits.isEmpty else {
            return .zero
        }
        guard let magnitude = Int64(digits) else {
            return nil
        }

        var denominator: Int64 = 1
        for _ in fractionDigits {
            let product = denominator.multipliedReportingOverflow(by: 10)
            guard !product.overflow else {
                return nil
            }
            denominator = product.partialValue
        }

        let signedMagnitude = magnitude.multipliedReportingOverflow(by: isNegative ? -1 : 1)
        guard !signedMagnitude.overflow else {
            return nil
        }
        return normalized(numerator: signedMagnitude.partialValue, denominator: denominator)
    }

    func adding(_ other: Self, subtracting: Bool = false) -> Self? {
        let commonDivisor = Self.greatestCommonDivisor(
            UInt64(denominator),
            UInt64(other.denominator),
        )
        guard let divisor = Int64(exactly: commonDivisor) else {
            return nil
        }

        let leftFactor = other.denominator / divisor
        let rightFactor = denominator / divisor
        let leftNumerator = numerator.multipliedReportingOverflow(by: leftFactor)
        let rightNumerator = other.numerator.multipliedReportingOverflow(by: rightFactor)
        guard !leftNumerator.overflow, !rightNumerator.overflow else {
            return nil
        }

        let combined = subtracting
            ? leftNumerator.partialValue.subtractingReportingOverflow(rightNumerator.partialValue)
            : leftNumerator.partialValue.addingReportingOverflow(rightNumerator.partialValue)
        let combinedDenominator = denominator.multipliedReportingOverflow(by: leftFactor)
        guard !combined.overflow, !combinedDenominator.overflow else {
            return nil
        }

        return Self.normalized(
            numerator: combined.partialValue,
            denominator: combinedDenominator.partialValue,
        )
    }

    func multiplied(by other: Self) -> Self? {
        let leftCancellation = Self.greatestCommonDivisor(numerator.magnitude, UInt64(other.denominator))
        let rightCancellation = Self.greatestCommonDivisor(other.numerator.magnitude, UInt64(denominator))
        guard let leftDivisor = Int64(exactly: leftCancellation),
              let rightDivisor = Int64(exactly: rightCancellation)
        else {
            return nil
        }

        let leftNumerator = numerator / leftDivisor
        let rightNumerator = other.numerator / rightDivisor
        let leftDenominator = denominator / rightDivisor
        let rightDenominator = other.denominator / leftDivisor
        let productNumerator = leftNumerator.multipliedReportingOverflow(by: rightNumerator)
        let productDenominator = leftDenominator.multipliedReportingOverflow(by: rightDenominator)
        guard !productNumerator.overflow, !productDenominator.overflow else {
            return nil
        }

        return Self.normalized(
            numerator: productNumerator.partialValue,
            denominator: productDenominator.partialValue,
        )
    }

    func divided(by other: Self) -> Self? {
        guard !other.isZero,
              other.numerator.magnitude <= UInt64(Int64.max)
        else {
            return nil
        }

        let signedNumerator = other.numerator < 0 ? -other.denominator : other.denominator
        guard let reciprocal = Self.normalized(
            numerator: signedNumerator,
            denominator: Int64(other.numerator.magnitude),
        )
        else {
            return nil
        }

        return multiplied(by: reciprocal)
    }

    func negated() -> Self? {
        let result = numerator.multipliedReportingOverflow(by: -1)
        guard !result.overflow else {
            return nil
        }
        return Self(uncheckedNumerator: result.partialValue, denominator: denominator)
    }

    private static func normalized(numerator: Int64, denominator: Int64) -> Self? {
        guard denominator != 0 else {
            return nil
        }

        var numerator = numerator
        var denominator = denominator
        if denominator < 0 {
            let positiveNumerator = numerator.multipliedReportingOverflow(by: -1)
            let positiveDenominator = denominator.multipliedReportingOverflow(by: -1)
            guard !positiveNumerator.overflow, !positiveDenominator.overflow else {
                return nil
            }
            numerator = positiveNumerator.partialValue
            denominator = positiveDenominator.partialValue
        }

        let divisor = greatestCommonDivisor(numerator.magnitude, UInt64(denominator))
        guard let divisor = Int64(exactly: divisor), divisor != 0 else {
            return nil
        }

        return Self(
            uncheckedNumerator: numerator / divisor,
            denominator: denominator / divisor,
        )
    }

    private static func greatestCommonDivisor(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
        var left = lhs
        var right = rhs
        while right != 0 {
            (left, right) = (right, left % right)
        }
        return left
    }
}
