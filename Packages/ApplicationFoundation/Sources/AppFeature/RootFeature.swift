import CalculatorFeature
import ComposableArchitecture
import SwiftUI
import UIKit

/// The application composition root.
///
/// The application composition root. Feature-specific state and behavior compose beneath this
/// root rather than being placed in the executable target.
@Reducer
public struct RootFeature {
  /// The state owned by the application composition root.
  @ObservableState
  public struct State: Equatable, Sendable {
    public var calculator: CalculatorFeature.State

    public init(calculator: CalculatorFeature.State = .init()) {
      self.calculator = calculator
    }
  }

  /// Actions forwarded to the root's child features.
  public enum Action: Equatable, Sendable {
    case calculator(CalculatorFeature.Action)
  }

  /// Creates the application composition root.
  public init() {}

  public var body: some ReducerOf<Self> {
    Scope(state: \.calculator, action: \.calculator) {
      CalculatorFeature()
    }
  }
}

/// The calculator surface hosted by the application's single root store.
@MainActor
public struct RootView: View {
  private let store: StoreOf<RootFeature>

  /// Creates the root view from the application's single root store.
  ///
  /// - Parameter store: The store that owns the root composition.
  public init(store: StoreOf<RootFeature>) {
    self.store = store
  }

  public var body: some View {
    CalculatorView(store: store.scope(state: \.calculator, action: \.calculator))
  }
}
