import ComposableArchitecture
import Dependencies
import Foundation

/// The issue #3 calculator reducer.
///
/// The reducer owns calculator editing, evaluation, memory, history, clipboard actions, and the
/// calculator-only persistence boundary. Numeric parsing is delegated to ``CalculatorEngine`` so
/// the feature interface can grow without making the current Decimal implementation permanent.
@Reducer
public struct CalculatorFeature {
  /// The calculator state rendered by ``CalculatorView``.
  @ObservableState
  public struct State: Equatable, Sendable {
    public var display: String
    public var expression: String
    public var memory: String?
    public var history: [CalculatorHistoryEntry]
    public var error: CalculatorError?
    public var persistenceError: CalculatorPersistenceError?
    public var isLoading: Bool
    public var isShowingResult: Bool

    /// Creates the initial calculator state or restores a previously saved snapshot.
    public init(snapshot: CalculatorSnapshot? = nil) {
      self.display = snapshot?.display ?? "0"
      self.expression = snapshot?.expression ?? ""
      self.memory = snapshot?.memory
      self.history = snapshot?.history ?? []
      self.error = nil
      self.persistenceError = nil
      self.isLoading = false
      self.isShowingResult = snapshot?.isShowingResult ?? false
    }

    fileprivate var snapshot: CalculatorSnapshot {
      CalculatorSnapshot(
        display: display,
        expression: expression,
        memory: memory,
        history: history,
        isShowingResult: isShowingResult
      )
    }
  }

  /// User and lifecycle actions handled by the calculator reducer.
  public enum Action: Equatable, Sendable {
    case task
    case loaded(Result<CalculatorSnapshot?, CalculatorPersistenceError>)
    case button(CalculatorButton)
    case pasted(String?)
    case persistenceSucceeded
    case persistenceFailed
  }

  private static let maximumHistoryCount = 20

  private enum CancelID: Hashable {
    case save
  }

  @Dependency(\.calculatorClipboard) private var clipboard
  @Dependency(\.calculatorPersistence) private var persistence
  @Dependency(\.date.now) private var now
  @Dependency(\.uuid) private var uuid

  public init() {}

  public var body: some ReducerOf<Self> {
    Reduce { state, action in
      switch action {
      case .task:
        guard !state.isLoading else { return .none }
        state.persistenceError = nil
        state.isLoading = true
        let load = persistence.load
        return .run { send in
          do {
            await send(.loaded(.success(try await load())))
          } catch {
            await send(.loaded(.failure(.unavailable)))
          }
        }

      case let .loaded(result):
        state.isLoading = false
        switch result {
        case let .success(snapshot):
          state.persistenceError = nil
          guard let snapshot else { return .none }
          state.display = snapshot.display
          state.expression = snapshot.expression
          state.memory = snapshot.memory
          state.history = snapshot.history
          state.isShowingResult = snapshot.isShowingResult
        case let .failure(error):
          state.persistenceError = error
        }
        return .none

      case let .button(button):
        guard !state.isLoading else { return .none }
        switch button {
        case .copy:
          clipboard.copy(state.display)
          return .none
        case .paste:
          let paste = clipboard.paste
          return .run { send in
            await send(.pasted(paste()))
          }
        default:
          guard apply(button, to: &state) else { return .none }
          return persistenceEffect(for: state)
        }

      case let .pasted(value):
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
          return .none
        }
        do {
          let result = try CalculatorEngine().evaluate(value)
          state.error = nil
          state.display = result
          state.expression = value
          state.isShowingResult = true
          return persistenceEffect(for: state)
        } catch let error as CalculatorError {
          state.error = error
          return .none
        } catch {
          state.error = .invalidExpression
          return .none
        }

      case .persistenceFailed:
        state.persistenceError = .unavailable
        return .none

      case .persistenceSucceeded:
        state.persistenceError = nil
        return .none
      }
    }
  }

  /// Persists the latest snapshot, superseding any save still in flight for a prior edit.
  ///
  /// Every edit starts its own asynchronous save, so a slow, older save could otherwise finish
  /// after a newer one and overwrite it with stale state. Cancelling the previous save under a
  /// shared ID before it reaches the store keeps only the most recent snapshot's write in effect.
  private func persistenceEffect(for state: State) -> Effect<Action> {
    let snapshot = state.snapshot
    let save = persistence.save
    let shouldClearPersistenceError = state.persistenceError != nil
    return .run { send in
      try Task.checkCancellation()
      do {
        try await save(snapshot)
      } catch is CancellationError {
        return
      } catch {
        await send(.persistenceFailed)
        return
      }
      try Task.checkCancellation()
      if shouldClearPersistenceError {
        await send(.persistenceSucceeded)
      }
    }
    .cancellable(id: CancelID.save, cancelInFlight: true)
  }

  @discardableResult
  private func apply(_ button: CalculatorButton, to state: inout State) -> Bool {
    state.error = nil

    switch button {
    case let .digit(digit):
      guard (0...9).contains(digit) else { return false }
      prepareForNewInput(&state)
      let token = currentToken(in: state.expression)
      guard token != ")" else { return false }
      if token == "0" {
        state.expression = replaceCurrentToken(in: state.expression, with: "\(digit)")
      } else {
        state.expression.append("\(digit)")
      }
      state.display = currentToken(in: state.expression)
      return true

    case .decimal:
      prepareForNewInput(&state)
      let token = currentToken(in: state.expression)
      guard token != ")", !token.contains(".") else { return false }
      if token.isEmpty || token == "-" {
        state.expression.append("0.")
      } else {
        state.expression.append(".")
      }
      state.display = currentToken(in: state.expression)
      return true

    case .add:
      return appendOperator("+", to: &state)
    case .subtract:
      return appendOperator("-", to: &state)
    case .multiply:
      return appendOperator("×", to: &state)
    case .divide:
      return appendOperator("÷", to: &state)

    case .openParenthesis:
      prepareForNewInputIfResultIsBeingShown(&state)
      if state.expression.isEmpty {
        state.expression = "("
        state.display = "("
        return true
      }
      guard let last = state.expression.last,
            operatorCharacters.contains(last) else { return false }
      state.expression.append("(")
      state.display = "("
      return true

    case .closeParenthesis:
      guard canCloseParenthesis(in: state.expression) else {
        state.error = .invalidExpression
        return false
      }
      state.expression.append(")")
      state.display = ")"
      return true

    case .percent:
      if state.expression.isEmpty {
        state.expression = state.display
      }
      guard let last = state.expression.last, !operatorCharacters.contains(last) else {
        state.error = .invalidExpression
        return false
      }
      do {
        state.display = try CalculatorEngine().evaluate(state.expression + "%")
        state.expression.append("%")
        return true
      } catch let error as CalculatorError {
        state.error = error
        return false
      } catch {
        state.error = .invalidExpression
        return false
      }

    case .sign:
      if state.isShowingResult {
        state.expression = state.display
        state.isShowingResult = false
      }
      if state.expression.isEmpty {
        state.expression = "-"
        state.display = "-"
        return true
      }
      let token = currentToken(in: state.expression)
      guard token != ")" else { return false }
      if token.isEmpty {
        state.expression.append("-")
      } else if token.hasPrefix("-") {
        state.expression = replaceCurrentToken(in: state.expression, with: String(token.dropFirst()))
      } else {
        state.expression = replaceCurrentToken(in: state.expression, with: "-" + token)
      }
      state.display = currentToken(in: state.expression)
      return true

    case .equals:
      let source = state.expression.isEmpty ? state.display : state.expression
      guard !source.isEmpty else { return false }
      do {
        let result = try CalculatorEngine().evaluate(source)
        state.history.insert(
          CalculatorHistoryEntry(id: uuid(), expression: source, result: result, date: now),
          at: 0
        )
        if state.history.count > Self.maximumHistoryCount {
          state.history.removeLast(state.history.count - Self.maximumHistoryCount)
        }
        state.display = result
        state.expression = result
        state.isShowingResult = true
        return true
      } catch let error as CalculatorError {
        state.error = error
        return false
      } catch {
        state.error = .invalidExpression
        return false
      }

    case .clear:
      state.display = "0"
      state.expression = ""
      state.error = nil
      state.isShowingResult = false
      return true

    case .delete:
      guard !state.isShowingResult else {
        state.display = "0"
        state.expression = ""
        state.isShowingResult = false
        return true
      }
      guard !state.expression.isEmpty else { return false }
      state.expression.removeLast()
      state.display = currentToken(in: state.expression)
      if state.display.isEmpty {
        state.display = lastOperand(in: state.expression) ?? "0"
      }
      return true

    case .memoryClear:
      guard state.memory != nil else { return false }
      state.memory = nil
      return true

    case .memoryRecall:
      guard let memory = state.memory else { return false }
      state.display = memory
      state.expression = memory
      state.isShowingResult = false
      return true

    case .memoryAdd, .memorySubtract:
      let memory = state.memory ?? "0"
      let operation = button == .memoryAdd ? "+" : "-"
      do {
        state.memory = try CalculatorEngine().evaluate("\(memory)\(operation)\(state.display)")
        return true
      } catch let error as CalculatorError {
        state.error = error
        return false
      } catch {
        state.error = .invalidExpression
        return false
      }

    case .copy, .paste:
      return false

    case .clearHistory:
      guard !state.history.isEmpty else { return false }
      state.history.removeAll()
      return true
    }
  }

  private func prepareForNewInput(_ state: inout State) {
    prepareForNewInputIfResultIsBeingShown(&state)
    if state.display == "-" && state.expression == "-" {
      return
    }
  }

  private func prepareForNewInputIfResultIsBeingShown(_ state: inout State) {
    guard state.isShowingResult else { return }
    state.display = "0"
    state.expression = ""
    state.isShowingResult = false
  }

  private func appendOperator(_ symbol: Character, to state: inout State) -> Bool {
    if state.expression.isEmpty {
      state.expression = state.display
    }
    guard !state.expression.isEmpty else { return false }
    if state.isShowingResult {
      state.isShowingResult = false
    }
    if state.expression.last == "(" {
      guard symbol == "-" else { return false }
    }

    if let last = state.expression.last, operatorCharacters.contains(last) {
      if symbol == "-" {
        state.expression.append(symbol)
      } else {
        state.expression.removeLast()
        state.expression.append(symbol)
      }
    } else {
      state.expression.append(symbol)
    }
    return true
  }

  private func canCloseParenthesis(in expression: String) -> Bool {
    var balance = 0
    for character in expression {
      if character == "(" {
        balance += 1
      } else if character == ")" {
        balance -= 1
        if balance < 0 { return false }
      }
    }

    guard balance > 0, let last = expression.last else { return false }
    guard !operatorCharacters.contains(last), last != "(" else { return false }
    return last.isNumber || last == ")" || last == "%"
  }

  private func currentToken(in expression: String) -> String {
    if expression.last == ")" {
      return ")"
    }
    guard let index = expression.lastIndex(where: { operatorCharacters.contains($0) }) else {
      return expression
    }
    if expression[index] == "-" {
      let isUnary = index == expression.startIndex
        || operatorCharacters.contains(expression[expression.index(before: index)])
      if isUnary {
        return String(expression[index...])
      }
    }
    return String(expression[expression.index(after: index)...])
  }

  private func lastOperand(in expression: String) -> String? {
    let tokens = expression.split(whereSeparator: { operatorCharacters.contains($0) })
    return tokens.last.map(String.init)
  }

  private func replaceCurrentToken(in expression: String, with token: String) -> String {
    guard let index = expression.lastIndex(where: { operatorCharacters.contains($0) }) else {
      return token
    }
    if expression[index] == "-" {
      let isUnary = index == expression.startIndex
        || operatorCharacters.contains(expression[expression.index(before: index)])
      if isUnary {
        return String(expression[..<index]) + token
      }
    }
    let end = expression.index(after: index)
    return String(expression[..<end]) + token
  }

  private var operatorCharacters: Set<Character> {
    ["+", "−", "-", "×", "÷", "*", "/", "("]
  }
}
