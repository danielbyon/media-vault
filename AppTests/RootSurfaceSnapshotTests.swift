import AppFeature
import CalculatorFeature
import ComposableArchitecture
import Dependencies
import FoundationTestSupport
import SnapshotTesting
import SwiftUI
import Testing

@MainActor
@Suite("Root surface snapshots")
struct RootSurfaceSnapshotTests {
  @Test("The empty calculator state has a stable structural snapshot")
  func rootStateSnapshot() {
    assertSnapshot(of: RootFeature.State(), as: .dump)
  }

  @Test("The root surface is stable on a compact iPhone")
  func compactPhoneSnapshot() {
    assertSnapshot(
      of: rootView(),
      as: .image(layout: .device(config: DeterministicTestSupport.compactPhone))
    )
  }

  @Test("The root surface is stable on a large iPhone")
  func largePhoneSnapshot() {
    assertSnapshot(
      of: rootView(),
      as: .image(layout: .device(config: DeterministicTestSupport.largePhone))
    )
  }

  @Test("The root surface is stable at regular iPad width")
  func regularWidthIPadSnapshot() {
    assertSnapshot(
      of: rootView(),
      as: .image(layout: .device(config: DeterministicTestSupport.regularWidthIPad))
    )
  }

  private func rootView() -> some View {
    let store = withDependencies {
      $0.calculatorPersistence.load = { nil }
      $0.calculatorPersistence.save = { _ in }
    } operation: {
      Store(initialState: RootFeature.State()) {
        RootFeature()
      }
    }

    return RootView(store: store)
      .environment(\.colorScheme, .light)
  }
}

extension RootFeature.State: @retroactive AnySnapshotStringConvertible {
  public static var renderChildren: Bool { false }

  public var snapshotDescription: String {
    "RootFeature.State(calculator: (display: \(calculator.display.debugDescription), expression: \(calculator.expression.debugDescription), memory: \(String(describing: calculator.memory)), historyCount: \(calculator.history.count), error: \(String(describing: calculator.error)), persistenceError: \(String(describing: calculator.persistenceError)), isLoading: \(calculator.isLoading), isShowingResult: \(calculator.isShowingResult)))"
  }
}
