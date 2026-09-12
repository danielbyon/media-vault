//
//  CalculatorPersistenceClient.swift
//  MediaVault
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Dependencies
import DependenciesMacros
import Foundation
import PersistenceSupport
import SQLiteData
import UIKit

/// The system clipboard seam used by the calculator.
///
/// Keeping UIKit behind this dependency lets reducer tests control copy and paste values without
/// depending on the simulator's pasteboard or testing UIKit itself.
@DependencyClient
public struct CalculatorClipboardClient: Sendable {
    /// Copies a display value to the system clipboard.
    public var copy: @Sendable (String) -> Void = { _ in }

    /// Reads the current system clipboard value.
    public var paste: @Sendable () -> String? = { nil }
}

extension CalculatorClipboardClient: DependencyKey {
    /// The live clipboard implementation backed by UIKit.
    public static var liveValue: Self {
        Self(
            copy: { UIPasteboard.general.string = $0 },
            paste: { UIPasteboard.general.string },
        )
    }

    /// The inert clipboard implementation used by tests unless overridden.
    public static var testValue: Self {
        Self()
    }
}

extension DependencyValues {
    /// The calculator's injected clipboard adapter.
    public var calculatorClipboard: CalculatorClipboardClient {
        get { self[CalculatorClipboardClient.self] }
        set { self[CalculatorClipboardClient.self] = newValue }
    }
}

/// The calculator persistence seam.
///
/// The reducer depends on this small async interface rather than on SQLiteData directly. The
/// live implementation stores one calculator snapshot in its own SQLite database, while tests can
/// provide an in-memory closure pair.
@DependencyClient
public struct CalculatorPersistenceClient: Sendable {
    /// Loads the saved calculator snapshot, when one exists.
    public var load: @Sendable () async throws -> CalculatorSnapshot? = { nil }

    /// Saves the supplied calculator snapshot.
    public var save: @Sendable (CalculatorSnapshot) async throws -> Void = { _ in }

    /// Creates a persistence client backed by the supplied isolated database.
    ///
    /// This factory is intended for deterministic tests and previews. The database connection is
    /// owned by the caller, while the calculator still creates and uses only its own table.
    public static func forDatabase(_ database: any DatabaseWriter) -> Self {
        let storage = CalculatorDatabase(database: database)
        return Self(
            load: { try await storage.load() },
            save: { snapshot in try await storage.save(snapshot) },
        )
    }
}

extension CalculatorPersistenceClient: DependencyKey {
    /// The live persistence implementation backed by the calculator database.
    public static var liveValue: Self {
        let database = CalculatorDatabase.live()
        return Self(
            load: { try await database.load() },
            save: { snapshot in try await database.save(snapshot) },
        )
    }

    /// The inert persistence implementation used by tests unless overridden.
    public static var testValue: Self {
        Self()
    }
}

extension DependencyValues {
    /// The calculator's durable, feature-local persistence adapter.
    public var calculatorPersistence: CalculatorPersistenceClient {
        get { self[CalculatorPersistenceClient.self] }
        set { self[CalculatorPersistenceClient.self] = newValue }
    }
}

/// Errors reported when the calculator's durable store cannot be read or written.
public enum CalculatorPersistenceError: Error, Equatable, Sendable {
    /// The calculator database could not be opened or used.
    case unavailable
}

/// Owns the calculator-only database connection and its single snapshot row.
private actor CalculatorDatabase {
    private static let tableName = "calculator_state"
    private let database: (any DatabaseWriter)?

    fileprivate init(database: (any DatabaseWriter)?) {
        self.database = database
    }

    static func live() -> CalculatorDatabase {
        do {
            let directory = try FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true,
            )
            let calculatorDirectory = directory.appendingPathComponent("Calculator", isDirectory: true)
            try FileManager.default.createDirectory(
                at: calculatorDirectory,
                withIntermediateDirectories: true,
            )
            let persistentDatabase = try PersistenceStore.makePersistent(
                at: calculatorDirectory.appendingPathComponent("calculator.sqlite"),
            )
            return CalculatorDatabase(database: persistentDatabase)
        } catch {
            return CalculatorDatabase(database: nil)
        }
    }

    func load() throws -> CalculatorSnapshot? {
        guard let database else {
            throw CalculatorPersistenceError.unavailable
        }

        try prepareSchema(in: database)
        let payload: String? = try database.read { db in
            try #sql("SELECT payload FROM calculator_state WHERE id = 1", as: String.self)
                .fetchOne(db)
        }
        guard let payload else {
            return nil
        }
        guard let data = Data(base64Encoded: payload),
              let snapshot = try? JSONDecoder().decode(CalculatorSnapshot.self, from: data)
        else {
            throw CalculatorPersistenceError.unavailable
        }

        return snapshot
    }

    func save(_ snapshot: CalculatorSnapshot) throws {
        guard let database else {
            throw CalculatorPersistenceError.unavailable
        }

        try prepareSchema(in: database)
        let data = try JSONEncoder().encode(snapshot)
        try database.write { db in
            try db.execute(
                sql: """
                INSERT INTO \(Self.tableName) (id, payload) VALUES (1, ?)
                ON CONFLICT(id) DO UPDATE SET payload = excluded.payload
                """,
                arguments: [data.base64EncodedString()],
            )
        }
    }

    private func prepareSchema(in database: any DatabaseWriter) throws {
        try database.write { db in
            try db.execute(
                sql: """
                CREATE TABLE IF NOT EXISTS calculator_state (
                  id INTEGER PRIMARY KEY CHECK (id = 1),
                  payload TEXT NOT NULL
                )
                """,
            )
        }
    }
}
