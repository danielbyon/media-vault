import CalculatorFeature
import ComposableArchitecture
import ConcurrencyExtras
import Dependencies
import Foundation
import PersistenceSupport
import Testing

@Suite("Calculator reducer")
struct CalculatorReducerTests {
  @Test("The reducer evaluates an expression and records history")
  @MainActor
  func evaluatesExpressionAndRecordsHistory() async {
    let store = TestStore(initialState: CalculatorFeature.State()) {
      CalculatorFeature()
    } withDependencies: {
      $0.calculatorPersistence.load = { nil }
      $0.calculatorPersistence.save = { _ in }
      $0.date.now = Date(timeIntervalSince1970: 1_725_000_000)
      $0.uuid = .constant(UUID(uuidString: "00000000-0000-0000-0000-000000000002")!)
    }

    await store.send(.button(.digit(2))) {
      $0.display = "2"
      $0.expression = "2"
    }
    await store.send(.button(.add)) {
      $0.expression = "2+"
    }
    await store.send(.button(.digit(3))) {
      $0.display = "3"
      $0.expression = "2+3"
    }
    await store.send(.button(.multiply)) {
      $0.expression = "2+3×"
    }
    await store.send(.button(.digit(4))) {
      $0.display = "4"
      $0.expression = "2+3×4"
    }
    await store.send(.button(.equals)) {
      $0.display = "14"
      $0.expression = "14"
      $0.isShowingResult = true
      $0.history = [
        CalculatorHistoryEntry(
          id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
          expression: "2+3×4",
          result: "14",
          date: Date(timeIntervalSince1970: 1_725_000_000)
        )
      ]
    }

    await store.send(.button(.clearHistory)) {
      $0.history = []
    }
  }

  @Test("The reducer constructs and evaluates nested parenthesized expressions")
  @MainActor
  func constructsAndEvaluatesNestedParenthesizedExpressions() async {
    let store = TestStore(initialState: CalculatorFeature.State()) {
      CalculatorFeature()
    } withDependencies: {
      $0.calculatorPersistence.load = { nil }
      $0.calculatorPersistence.save = { _ in }
      $0.date.now = Date(timeIntervalSince1970: 1_725_000_001)
      $0.uuid = .constant(UUID(uuidString: "00000000-0000-0000-0000-000000000004")!)
    }

    await store.send(.button(.openParenthesis)) {
      $0.display = "("
      $0.expression = "("
    }
    await store.send(.button(.digit(2))) {
      $0.display = "2"
      $0.expression = "(2"
    }
    await store.send(.button(.multiply)) {
      $0.expression = "(2×"
    }
    await store.send(.button(.openParenthesis)) {
      $0.display = "("
      $0.expression = "(2×("
    }
    await store.send(.button(.digit(3))) {
      $0.display = "3"
      $0.expression = "(2×(3"
    }
    await store.send(.button(.add)) {
      $0.expression = "(2×(3+"
    }
    await store.send(.button(.digit(4))) {
      $0.display = "4"
      $0.expression = "(2×(3+4"
    }
    await store.send(.button(.closeParenthesis)) {
      $0.display = ")"
      $0.expression = "(2×(3+4)"
    }
    await store.send(.button(.closeParenthesis)) {
      $0.display = ")"
      $0.expression = "(2×(3+4))"
    }
    await store.send(.button(.equals)) {
      $0.display = "14"
      $0.expression = "14"
      $0.isShowingResult = true
      $0.history = [
        CalculatorHistoryEntry(
          id: UUID(uuidString: "00000000-0000-0000-0000-000000000004")!,
          expression: "(2×(3+4))",
          result: "14",
          date: Date(timeIntervalSince1970: 1_725_000_001)
        )
      ]
    }
  }

  @Test("The reducer reports an unbalanced parenthesis as an invalid expression")
  @MainActor
  func reportsUnbalancedParenthesis() async {
    let store = TestStore(initialState: CalculatorFeature.State()) {
      CalculatorFeature()
    } withDependencies: {
      $0.calculatorPersistence.load = { nil }
      $0.calculatorPersistence.save = { _ in }
    }

    await store.send(.button(.openParenthesis)) {
      $0.display = "("
      $0.expression = "("
    }
    await store.send(.button(.digit(2))) {
      $0.display = "2"
      $0.expression = "(2"
    }
    await store.send(.button(.equals)) {
      $0.error = .invalidExpression
    }
  }

  @Test("The reducer handles decimal, sign, percent, and memory controls")
  @MainActor
  func handlesCoreEditingAndMemoryControls() async {
    let store = TestStore(initialState: CalculatorFeature.State()) {
      CalculatorFeature()
    } withDependencies: {
      $0.calculatorPersistence.load = { nil }
      $0.calculatorPersistence.save = { _ in }
    }

    await store.send(.button(.digit(1))) {
      $0.display = "1"
      $0.expression = "1"
    }
    await store.send(.button(.decimal)) {
      $0.display = "1."
      $0.expression = "1."
    }
    await store.send(.button(.digit(5))) {
      $0.display = "1.5"
      $0.expression = "1.5"
    }
    await store.send(.button(.sign)) {
      $0.display = "-1.5"
      $0.expression = "-1.5"
    }
    await store.send(.button(.percent)) {
      $0.display = "-0.015"
      $0.expression = "-1.5%"
    }
    await store.send(.button(.memoryAdd)) {
      $0.memory = "-0.015"
    }
    await store.send(.button(.clear)) {
      $0.display = "0"
      $0.expression = ""
      $0.isShowingResult = false
    }
    await store.send(.button(.memoryRecall)) {
      $0.display = "-0.015"
      $0.expression = "-0.015"
      $0.isShowingResult = false
    }
    await store.send(.button(.memoryClear)) {
      $0.memory = nil
    }
  }

  @Test("History remains available until the clear-history action")
  @MainActor
  func historyRequiresExplicitClear() async {
    let entry = CalculatorHistoryEntry(
      id: UUID(uuidString: "00000000-0000-0000-0000-000000000006")!,
      expression: "1+1",
      result: "2",
      date: Date(timeIntervalSince1970: 1_725_000_002)
    )
    let store = TestStore(
      initialState: CalculatorFeature.State(
        snapshot: CalculatorSnapshot(history: [entry])
      )
    ) {
      CalculatorFeature()
    } withDependencies: {
      $0.calculatorPersistence.load = { nil }
      $0.calculatorPersistence.save = { _ in }
    }

    await store.send(.button(.clear))
    #expect(store.state.history == [entry])
    await store.send(.button(.clearHistory)) {
      $0.history = []
    }
  }

  @Test("Editing is blocked while the initial persistence load is in flight")
  @MainActor
  func blocksEditingWhileLoading() async {
    var initialState = CalculatorFeature.State()
    initialState.isLoading = true
    let store = TestStore(initialState: initialState) {
      CalculatorFeature()
    } withDependencies: {
      $0.calculatorPersistence.load = { nil }
      $0.calculatorPersistence.save = { _ in }
    }

    await store.send(.button(.digit(3)))
  }

  @Test("A persistence failure is cleared after a later save succeeds")
  @MainActor
  func persistenceFailureClearsAfterSuccessfulSave() async {
    let failNextSave = LockIsolated(true)
    let store = TestStore(initialState: CalculatorFeature.State()) {
      CalculatorFeature()
    } withDependencies: {
      $0.calculatorPersistence.load = { nil }
      $0.calculatorPersistence.save = { _ in
        if failNextSave.value {
          failNextSave.setValue(false)
          throw CalculatorPersistenceError.unavailable
        }
      }
    }

    await store.send(.button(.digit(1))) {
      $0.display = "1"
      $0.expression = "1"
    }
    await store.receive(.persistenceFailed) {
      $0.persistenceError = .unavailable
    }

    await store.send(.button(.digit(2))) {
      $0.display = "12"
      $0.expression = "12"
    }
    await store.receive(.persistenceSucceeded) {
      $0.persistenceError = nil
    }
  }

  @Test("Sign toggles a completed result and a negative operand")
  @MainActor
  func signTogglesResultsAndNegativeOperands() async {
    let store = TestStore(
      initialState: CalculatorFeature.State(
        snapshot: CalculatorSnapshot(display: "5", expression: "5", isShowingResult: true)
      )
    ) {
      CalculatorFeature()
    } withDependencies: {
      $0.calculatorPersistence.load = { nil }
      $0.calculatorPersistence.save = { _ in }
    }

    await store.send(.button(.sign)) {
      $0.display = "-5"
      $0.expression = "-5"
      $0.isShowingResult = false
    }
    await store.send(.button(.sign)) {
      $0.display = "5"
      $0.expression = "5"
    }

    await store.send(.button(.add)) {
      $0.expression = "5+"
    }
    await store.send(.button(.sign)) {
      $0.display = "-"
      $0.expression = "5+-"
    }
    await store.send(.button(.digit(3))) {
      $0.display = "-3"
      $0.expression = "5+-3"
    }
    await store.send(.button(.sign)) {
      $0.display = "3"
      $0.expression = "5+3"
    }
  }

  @Test("An arithmetic operator preserves a completed result as its left operand")
  @MainActor
  func operatorPreservesCompletedResult() async {
    let store = TestStore(
      initialState: CalculatorFeature.State(
        snapshot: CalculatorSnapshot(display: "5", expression: "5", isShowingResult: true)
      )
    ) {
      CalculatorFeature()
    } withDependencies: {
      $0.calculatorPersistence.load = { nil }
      $0.calculatorPersistence.save = { _ in }
    }

    await store.send(.button(.add)) {
      $0.expression = "5+"
      $0.isShowingResult = false
    }
    await store.send(.button(.digit(2))) {
      $0.display = "2"
      $0.expression = "5+2"
    }
  }

  @Test("A non-minus operator is rejected after an opening parenthesis")
  @MainActor
  func rejectsOperatorAfterOpeningParenthesis() async {
    let store = TestStore(initialState: CalculatorFeature.State()) {
      CalculatorFeature()
    } withDependencies: {
      $0.calculatorPersistence.load = { nil }
      $0.calculatorPersistence.save = { _ in }
    }

    await store.send(.button(.openParenthesis)) {
      $0.display = "("
      $0.expression = "("
    }
    await store.send(.button(.add))
    await store.send(.button(.subtract)) {
      $0.expression = "(-"
    }
  }

  @Test("History is capped while retaining the newest completed calculation")
  @MainActor
  func historyIsCapped() async {
    let entries = (0..<20).map { index in
      CalculatorHistoryEntry(
        id: UUID(),
        expression: "(index)",
        result: "(index)",
        date: Date(timeIntervalSince1970: TimeInterval(index))
      )
    }
    let newest = CalculatorHistoryEntry(
      id: UUID(uuidString: "00000000-0000-0000-0000-000000000007")!,
      expression: "1+1",
      result: "2",
      date: Date(timeIntervalSince1970: 1_725_000_004)
    )
    var snapshot = CalculatorSnapshot(display: "1", expression: "1", history: entries)
    snapshot.isShowingResult = false
    let store = TestStore(initialState: CalculatorFeature.State(snapshot: snapshot)) {
      CalculatorFeature()
    } withDependencies: {
      $0.calculatorPersistence.load = { nil }
      $0.calculatorPersistence.save = { _ in }
      $0.date.now = newest.date
      $0.uuid = .constant(newest.id)
    }

    await store.send(.button(.add)) {
      $0.expression = "1+"
    }
    await store.send(.button(.digit(1))) {
      $0.display = "1"
      $0.expression = "1+1"
    }
    await store.send(.button(.equals)) {
      $0.display = "2"
      $0.expression = "2"
      $0.isShowingResult = true
      $0.history = [newest] + Array(entries.dropLast())
    }
  }

  @Test("The reducer restores a persisted snapshot during its first task")
  @MainActor
  func restoresPersistedSnapshot() async {
    let snapshot = CalculatorSnapshot(display: "14", expression: "14", memory: "5")
    let store = TestStore(initialState: CalculatorFeature.State()) {
      CalculatorFeature()
    } withDependencies: {
      $0.calculatorPersistence.load = { snapshot }
      $0.calculatorPersistence.save = { _ in }
    }

    await store.send(.task) {
      $0.isLoading = true
    }
    await store.receive(.loaded(.success(snapshot))) {
      $0.display = "14"
      $0.expression = "14"
      $0.memory = "5"
      $0.isLoading = false
    }
  }

  @Test("A persisted result starts a new calculation after restoration")
  @MainActor
  func persistedResultStartsNewCalculationAfterRestoration() async throws {
    let database = try PersistenceStore.makeInMemory()
    let persistence = CalculatorPersistenceClient.forDatabase(database)
    let store = TestStore(initialState: CalculatorFeature.State()) {
      CalculatorFeature()
    } withDependencies: {
      $0.calculatorPersistence.load = { nil }
      $0.calculatorPersistence.save = { _ in }
      $0.date.now = Date(timeIntervalSince1970: 1_725_000_003)
      $0.uuid = .constant(UUID(uuidString: "00000000-0000-0000-0000-000000000005")!)
    }

    await store.send(.button(.digit(2))) {
      $0.display = "2"
      $0.expression = "2"
    }
    await store.send(.button(.add)) {
      $0.expression = "2+"
    }
    await store.send(.button(.digit(3))) {
      $0.display = "3"
      $0.expression = "2+3"
    }
    await store.send(.button(.equals)) {
      $0.display = "5"
      $0.expression = "5"
      $0.isShowingResult = true
      $0.history = [
        CalculatorHistoryEntry(
          id: UUID(uuidString: "00000000-0000-0000-0000-000000000005")!,
          expression: "2+3",
          result: "5",
          date: Date(timeIntervalSince1970: 1_725_000_003)
        )
      ]
    }

    let completedSnapshot = CalculatorSnapshot(
      display: store.state.display,
      expression: store.state.expression,
      memory: store.state.memory,
      history: store.state.history,
      isShowingResult: store.state.isShowingResult
    )
    #expect(completedSnapshot.isShowingResult)
    try await persistence.save(completedSnapshot)

    await store.send(.button(.digit(7))) {
      $0.display = "7"
      $0.expression = "7"
      $0.isShowingResult = false
    }

    let restoredSnapshot = try #require(try await persistence.load())
    #expect(restoredSnapshot == completedSnapshot)
    let restoredStore = TestStore(initialState: CalculatorFeature.State()) {
      CalculatorFeature()
    } withDependencies: {
      $0.calculatorPersistence.load = { restoredSnapshot }
      $0.calculatorPersistence.save = { _ in }
    }

    await restoredStore.send(.task) {
      $0.isLoading = true
    }
    await restoredStore.receive(.loaded(.success(restoredSnapshot))) {
      $0.display = "5"
      $0.expression = "5"
      $0.history = completedSnapshot.history
      $0.isShowingResult = true
      $0.isLoading = false
    }
    await restoredStore.send(.button(.digit(7))) {
      $0.display = "7"
      $0.expression = "7"
      $0.isShowingResult = false
    }
  }
}
