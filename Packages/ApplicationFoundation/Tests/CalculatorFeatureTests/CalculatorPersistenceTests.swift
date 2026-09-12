import CalculatorFeature
import Foundation
import PersistenceSupport
import Testing

@Suite("Calculator persistence")
struct CalculatorPersistenceTests {
  @Test("History survives a fresh feature state and remains isolated per database")
  func historySurvivesRelaunchAndIsIsolated() async throws {
    let firstDatabase = try PersistenceStore.makeInMemory()
    let secondDatabase = try PersistenceStore.makeInMemory()
    let firstClient = CalculatorPersistenceClient.forDatabase(firstDatabase)
    let secondClient = CalculatorPersistenceClient.forDatabase(secondDatabase)
    let snapshot = CalculatorSnapshot(
      display: "14",
      expression: "14",
      history: [
        CalculatorHistoryEntry(
          id: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!,
          expression: "2+3×4",
          result: "14",
          date: Date(timeIntervalSince1970: 1_725_000_000)
        )
      ]
    )

    try await firstClient.save(snapshot)

    #expect(try await firstClient.load() == snapshot)
    #expect(try await secondClient.load() == nil)
    #expect(CalculatorFeature.State(snapshot: try await firstClient.load()).history == snapshot.history)
  }
}

