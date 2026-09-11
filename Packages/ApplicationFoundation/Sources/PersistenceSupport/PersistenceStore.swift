import SQLiteData

/// Creates isolated SQLiteData connections for deterministic tests.
///
/// This module establishes only the integration seam. It intentionally does not define application
/// tables, migrations, a durable path, or a production database name; those semantics belong to
/// the modules that own persistence.
public enum PersistenceStore {
  /// Creates a new in-memory database with no application schema.
  ///
  /// - Returns: An isolated writable SQLiteData connection.
  public static func makeInMemory() throws -> any DatabaseWriter {
    try DatabaseQueue()
  }
}
