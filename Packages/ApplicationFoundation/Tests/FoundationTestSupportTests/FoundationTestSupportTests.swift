import Clocks
import CustomDump
import Dependencies
import Foundation
import FoundationTestSupport
import Testing

private actor CompletionRecorder {
  private(set) var didComplete = false

  func markComplete() {
    self.didComplete = true
  }
}

@Suite("Foundation test support")
struct FoundationTestSupportTests {
  @Test("Deterministic values are stable")
  func deterministicValuesAreStable() {
    expectNoDifference(
      DeterministicTestSupport.referenceDate,
      Date(timeIntervalSince1970: 1_725_000_000)
    )
    expectNoDifference(
      DeterministicTestSupport.referenceUUID,
      UUID(uuidString: "00000000-0000-0000-0000-000000000001")
    )
    expectNoDifference(
      DeterministicTestSupport.referenceFixture,
      DeterministicFixture(
        date: DeterministicTestSupport.referenceDate,
        uuid: DeterministicTestSupport.referenceUUID
      )
    )
  }

  @Test("Dependency overrides are deterministic")
  func dependencyOverridesAreDeterministic() async throws {
    try await DeterministicTestSupport.withDeterministicDependencies {
      await Task.yield()
      @Dependency(\.date.now) var now
      @Dependency(\.uuid) var uuid
      try #require(now == DeterministicTestSupport.referenceDate)
      try #require(uuid() == DeterministicTestSupport.referenceUUID)
    }
  }

  @Test("An isolated controllable clock holds work until advanced")
  @MainActor
  func controllableClockHoldsWorkUntilAdvanced() async throws {
    try await DeterministicTestSupport.withControllableClock { clock in
      let recorder = CompletionRecorder()
      let work = Task {
        @Dependency(\.continuousClock) var clock
        try await clock.sleep(for: .seconds(1))
        await recorder.markComplete()
      }

      await #expect(throws: SuspensionError.self) {
        try await clock.checkSuspension()
      }
      let completedBeforeAdvance = await recorder.didComplete
      #expect(completedBeforeAdvance == false)

      await clock.advance(by: .seconds(1))
      try await work.value
      let completedAfterAdvance = await recorder.didComplete
      #expect(completedAfterAdvance)
    }
  }
}
