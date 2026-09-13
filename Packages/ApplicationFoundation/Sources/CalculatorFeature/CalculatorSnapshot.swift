//
//  CalculatorSnapshot.swift
//  MediaVault
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

/// The calculator's durable, feature-local state.
///
/// The snapshot contains only calculator concerns. It is intentionally not shared with vault
/// persistence so clearing or migrating vault data cannot silently erase calculator history.
public struct CalculatorSnapshot: Codable, Equatable, Sendable {
    /// The value currently shown on the calculator display.
    public var display: String

    /// The expression currently being edited or the last completed result.
    public var expression: String

    /// The calculator's stored memory value, when one exists.
    public var memory: String?

    /// The completed calculations retained by the calculator.
    public var history: [CalculatorHistoryEntry]

    /// Whether the current display represents a completed calculation.
    public var isShowingResult = false

    /// Creates a calculator snapshot.
    ///
    /// - Parameters:
    ///   - display: The value currently shown on the calculator display.
    ///   - expression: The expression currently being edited or the last completed result.
    ///   - memory: The calculator's stored memory value, when one exists.
    ///   - history: The completed calculations retained by the calculator.
    ///   - isShowingResult: Whether the current display represents a completed calculation.
    public init(
        display: String = "0",
        expression: String = "",
        memory: String? = nil,
        history: [CalculatorHistoryEntry] = [],
        isShowingResult: Bool = false,
    ) {
        self.display = display
        self.expression = expression
        self.memory = memory
        self.history = history
        self.isShowingResult = isShowingResult
    }

    private enum CodingKeys: String, CodingKey {
        case display
        case expression
        case memory
        case history
        case isShowingResult
    }
}

/// A completed calculation retained in the calculator's local history.
public struct CalculatorHistoryEntry: Codable, Equatable, Identifiable, Sendable {
    /// The stable identifier for this history entry.
    public let id: UUID

    /// The expression that produced the result.
    public let expression: String

    /// The displayed result of the completed expression.
    public let result: String

    /// The instant at which the calculation was completed.
    public let date: Date

    /// Creates a completed calculator history entry.
    ///
    /// - Parameters:
    ///   - id: The stable identifier for the entry.
    ///   - expression: The expression that produced the result.
    ///   - result: The displayed result of the expression.
    ///   - date: The instant at which the calculation was completed.
    public init(id: UUID, expression: String, result: String, date: Date) {
        self.id = id
        self.expression = expression
        self.result = result
        self.date = date
    }
}

/// The core calculator actions exposed to the view layer.
public enum CalculatorButton: Equatable, Hashable, Sendable {
    /// Enters a decimal digit.
    case digit(Int)

    /// Appends addition.
    case add

    /// Appends subtraction.
    case subtract

    /// Appends multiplication.
    case multiply

    /// Appends division.
    case divide

    /// Opens a parenthesized expression.
    case openParenthesis

    /// Closes a parenthesized expression.
    case closeParenthesis

    /// Enters a decimal separator.
    case decimal

    /// Converts the current operand to a percentage.
    case percent

    /// Toggles the sign of the current operand.
    case sign

    /// Evaluates the current expression.
    case equals

    /// Clears the current expression and display.
    case clear

    /// Deletes the last entered character.
    case delete

    /// Clears calculator memory.
    case memoryClear

    /// Recalls calculator memory into the current expression.
    case memoryRecall

    /// Adds the current value to calculator memory.
    case memoryAdd

    /// Subtracts the current value from calculator memory.
    case memorySubtract

    /// Copies the current display value.
    case copy

    /// Pastes a value into the calculator.
    case paste

    /// Removes all retained history entries.
    case clearHistory
}
