//
//  CalculatorPresentation.swift
//  MediaVault
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//

/// The user-visible portion of calculator state.
///
/// A composition root can use this value for transient presentation, such as previewing input
/// that is being held outside ``CalculatorFeature.State``. Keeping the projection separate from
/// the durable state prevents presentation-only input from reaching calculator persistence or
/// history.
public struct CalculatorPresentation: Equatable, Sendable {
    /// The value shown in the calculator's main display.
    public let display: String

    /// The expression shown above the calculator's main display.
    public let expression: String

    /// The expression error shown by the calculator, when one exists.
    public let error: CalculatorError?

    /// Creates a calculator presentation value.
    public init(display: String, expression: String, error: CalculatorError?) {
        self.display = display
        self.expression = expression
        self.error = error
    }
}

extension CalculatorFeature.State {
    /// Returns the user-visible presentation represented by this state.
    public var presentation: CalculatorPresentation {
        CalculatorPresentation(display: display, expression: expression, error: error)
    }
}
