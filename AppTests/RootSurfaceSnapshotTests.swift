import AppFeature
import FoundationTestSupport
import SnapshotTesting
import SwiftUI
import Testing

@MainActor
@Suite("Root surface snapshots")
struct RootSurfaceSnapshotTests {
  @Test("The empty root state has a stable structural snapshot")
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
    RootView(
      store: .init(initialState: RootFeature.State()) {
        RootFeature()
      }
    )
    .environment(\.colorScheme, .light)
  }
}
