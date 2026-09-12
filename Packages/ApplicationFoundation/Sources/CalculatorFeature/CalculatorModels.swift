import Foundation

/// The calculator's durable, feature-local state.
///
/// The snapshot contains only calculator concerns. It is intentionally not shared with vault
/// persistence so clearing or migrating vault data cannot silently erase calculator history.
public struct CalculatorSnapshot: Codable, Equatable, Sendable {
  public var display: String
  public var expression: String
  public var memory: String?
  public var history: [CalculatorHistoryEntry]
  public var isShowingResult: Bool

  public init(
    display: String = "0",
    expression: String = "",
    memory: String? = nil,
    history: [CalculatorHistoryEntry] = [],
    isShowingResult: Bool = false
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

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.display = try container.decode(String.self, forKey: .display)
    self.expression = try container.decode(String.self, forKey: .expression)
    self.memory = try container.decodeIfPresent(String.self, forKey: .memory)
    self.history = try container.decode([CalculatorHistoryEntry].self, forKey: .history)
    self.isShowingResult = try container.decodeIfPresent(Bool.self, forKey: .isShowingResult) ?? false
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(display, forKey: .display)
    try container.encode(expression, forKey: .expression)
    try container.encodeIfPresent(memory, forKey: .memory)
    try container.encode(history, forKey: .history)
    try container.encode(isShowingResult, forKey: .isShowingResult)
  }
}

/// A completed calculation retained in the calculator's local history.
public struct CalculatorHistoryEntry: Codable, Equatable, Identifiable, Sendable {
  public let id: UUID
  public let expression: String
  public let result: String
  public let date: Date

  public init(id: UUID, expression: String, result: String, date: Date) {
    self.id = id
    self.expression = expression
    self.result = result
    self.date = date
  }
}

/// The core calculator actions exposed to the view layer.
public enum CalculatorButton: Equatable, Hashable, Sendable {
  case digit(Int)
  case add
  case subtract
  case multiply
  case divide
  case openParenthesis
  case closeParenthesis
  case decimal
  case percent
  case sign
  case equals
  case clear
  case delete
  case memoryClear
  case memoryRecall
  case memoryAdd
  case memorySubtract
  case copy
  case paste
  case clearHistory
}
