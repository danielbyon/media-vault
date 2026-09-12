//
//  DeterministicTestSupport.swift
//  MediaVault
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Clocks
import ConcurrencyExtras
import Dependencies
import Foundation
import SnapshotTesting

/// A generic fixture containing the deterministic foundation values shared by tests.
public struct DeterministicFixture: Equatable, Sendable {
    /// The deterministic instant used by the fixture.
    public let date: Date

    /// The deterministic identifier used by the fixture.
    public let uuid: UUID

    /// Creates a deterministic foundation fixture.
    ///
    /// - Parameters:
    ///   - date: The instant test code should observe.
    ///   - uuid: The identifier test code should observe.
    public init(date: Date, uuid: UUID) {
        self.date = date
        self.uuid = uuid
    }
}

/// Shared deterministic values and setup used by application tests.
///
/// These values are intentionally generic. They provide stable test inputs without introducing
/// product or future-domain fixtures into the foundation package.
public enum DeterministicTestSupport {
    /// The clock type supplied to a single deterministic test operation.
    public typealias ControllableClock = TestClock<Duration>

    /// A stable instant for tests that read the current date.
    public static let referenceDate = Date(timeIntervalSince1970: 1_725_000_000)

    /// A stable identifier for tests that generate UUIDs.
    public static let referenceUUID = makeReferenceUUID()

    /// The standard generic fixture for foundation-level tests.
    public static let referenceFixture = DeterministicFixture(
        date: referenceDate,
        uuid: referenceUUID,
    )

    /// Runs synchronous work with the standard date and UUID dependencies overridden.
    ///
    /// - Parameter operation: Work that should observe the deterministic dependency values.
    /// - Returns: The value returned by `operation`.
    public static func withDeterministicDependencies<Value>(
        _ operation: () throws -> Value,
    ) rethrows -> Value {
        try withDependencies(
            applyReferenceValues,
            operation: operation,
        )
    }

    /// Runs asynchronous work with deterministic dependencies and the main serial executor.
    ///
    /// The serial executor is scoped to the operation and is provided only as test infrastructure;
    /// application production code must not use it as a scheduling policy.
    ///
    /// - Parameter operation: Work that should observe the deterministic dependency values.
    @preconcurrency
    @MainActor
    public static func withDeterministicDependencies(
        _ operation: @isolated(any) () async throws -> Void,
    ) async rethrows {
        try await withMainSerialExecutor {
            try await withDependencies(
                applyReferenceValues,
                operation: operation,
            )
        }
    }

    /// Runs asynchronous work with a fresh, dependency-injected controllable clock.
    ///
    /// The clock is created for this operation and is never shared between tests. Work that reads
    /// `\.continuousClock` remains suspended until the operation advances the supplied clock.
    ///
    /// - Parameter operation: Work that should use the isolated controllable clock.
    @preconcurrency
    @MainActor
    public static func withControllableClock(
        _ operation: @isolated(any) (ControllableClock) async throws -> Void,
    ) async rethrows {
        let clock = ControllableClock()
        try await withMainSerialExecutor {
            try await withDependencies {
                $0.continuousClock = clock
            } operation: {
                try await operation(clock)
            }
        }
    }

    private static func applyReferenceValues(_ values: inout DependencyValues) {
        values.date.now = referenceFixture.date
        values.uuid = .constant(referenceFixture.uuid)
    }

    private static func makeReferenceUUID() -> UUID {
        guard let uuid = UUID(uuidString: "00000000-0000-0000-0000-000000000001") else {
            preconditionFailure("The deterministic reference UUID must be valid.")
        }

        return uuid
    }

    /// The compact iPhone configuration used by the root surface snapshots.
    public static let compactPhone = ViewImageConfig.iPhoneSe(.portrait)

    /// The large iPhone configuration used by the root surface snapshots.
    public static let largePhone = ViewImageConfig.iPhone13ProMax(.portrait)

    /// The representative regular-width iPad configuration used by the root surface snapshots.
    public static let regularWidthIPad = ViewImageConfig.iPadPro11(.portrait)
}
