import CalculatorFeature
import ComposableArchitecture
import ConcurrencyExtras
import Foundation
import Testing

@Suite("Calculator clipboard behavior")
struct CalculatorClipboardTests {
  @Test("Copy uses the current display and paste uses normal calculator parsing")
  @MainActor
  func copyAndPasteAreInjected() async {
    let copied = LockIsolated<String?>(nil)
    let store = TestStore(initialState: CalculatorFeature.State()) {
      CalculatorFeature()
    } withDependencies: {
      $0.calculatorPersistence.load = { nil }
      $0.calculatorPersistence.save = { _ in }
      $0.calculatorClipboard.copy = { copied.setValue($0) }
      $0.calculatorClipboard.paste = { "9×2" }
      $0.date.now = Date(timeIntervalSince1970: 1_725_000_005)
      $0.uuid = .constant(UUID(uuidString: "00000000-0000-0000-0000-000000000008")!)
    }

    await store.send(.button(.digit(7))) {
      $0.display = "7"
      $0.expression = "7"
    }
    await store.send(.button(.copy))
    #expect(copied.value == "7")

    await store.send(.button(.paste))
    await store.receive(.pasted("9×2")) {
      $0.display = "18"
      $0.expression = "9×2"
      $0.isShowingResult = true
      $0.history = [
        CalculatorHistoryEntry(
          id: UUID(uuidString: "00000000-0000-0000-0000-000000000008")!,
          expression: "9×2",
          result: "18",
          date: Date(timeIntervalSince1970: 1_725_000_005)
        )
      ]
    }
  }

  @Test("Malformed pasted input is rejected without replacing the current value")
  @MainActor
  func malformedPasteFailsSafely() async {
    let store = TestStore(
      initialState: CalculatorFeature.State(
        snapshot: CalculatorSnapshot(display: "7", expression: "7")
      )
    ) {
      CalculatorFeature()
    } withDependencies: {
      $0.calculatorPersistence.load = { nil }
      $0.calculatorPersistence.save = { _ in }
      $0.calculatorClipboard.paste = { "not a calculation" }
    }

    await store.send(.button(.paste))
    await store.receive(.pasted("not a calculation")) {
      $0.error = .invalidExpression
    }
  }
}
