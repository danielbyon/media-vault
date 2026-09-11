import Dependencies
import PersistenceSupport
import SQLiteData
import Testing

@Suite("Persistence support")
struct PersistenceSupportTests {
  @Test("The in-memory database opens isolated queues")
  func inMemoryDatabaseOpensIsolatedQueues() throws {
    let firstDatabase = try PersistenceStore.makeInMemory()
    let secondDatabase = try PersistenceStore.makeInMemory()
    let firstQueue = try #require(firstDatabase as? DatabaseQueue)
    let secondQueue = try #require(secondDatabase as? DatabaseQueue)

    #expect(firstQueue.path == ":memory:")
    #expect(secondQueue.path == ":memory:")
  }

  @Test("The in-memory database can be injected through SQLiteData")
  func inMemoryDatabaseCanBeInjected() throws {
    let database = try PersistenceStore.makeInMemory()
    try withDependencies {
      $0.defaultDatabase = database
    } operation: {
      @Dependency(\.defaultDatabase) var injectedDatabase
      let queue = try #require(injectedDatabase as? DatabaseQueue)

      #expect(queue.path == ":memory:")
    }
  }
}
