import ComposableArchitecture
import SwiftUI
import UIKit

/// The application composition root.
///
/// This feature is intentionally behaviorless until application behavior is introduced. Child
/// features compose beneath this root rather than adding executable-specific state or lifecycle
/// work to the app target.
@Reducer
public struct RootFeature {
  /// The empty state held by the composition root.
  public struct State: Equatable, Sendable {
    public init() {}
  }

  /// The root currently has no user or system actions.
  public enum Action: Sendable {}

  /// Creates an empty composition root.
  public init() {}

  /// Keeps the root reducer behaviorless until a child feature is introduced.
  public var body: some ReducerOf<Self> {
    EmptyReducer()
  }
}

/// The neutral surface displayed while the application has no product behavior.
///
/// The store is retained at this boundary so future application features can be composed beneath
/// ``RootFeature`` without changing the executable's scene wiring.
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
    Color(uiColor: .systemBackground)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .ignoresSafeArea()
  }
}
