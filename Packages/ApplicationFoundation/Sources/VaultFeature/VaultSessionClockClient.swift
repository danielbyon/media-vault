//
//  VaultSessionClockClient.swift
//  MediaVault
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Dependencies
import DependenciesMacros

/// Supplies the monotonic instants used to evaluate an in-process auto-lock grace period.
@DependencyClient
public struct VaultSessionClockClient: Sendable {
    /// Returns the current continuous-clock instant, or `nil` when time cannot be established.
    public var now: @Sendable () -> ContinuousClock.Instant? = { nil }
}

extension VaultSessionClockClient: DependencyKey {
    /// Reads instants from the system clock that continues through device sleep.
    public static var liveValue: Self {
        Self(now: { ContinuousClock().now })
    }

    /// Requires tests to supply a deterministic clock.
    public static var testValue: Self {
        Self()
    }
}

extension DependencyValues {
    /// The monotonic clock used by vault session lifecycle reducers.
    public var vaultSessionClock: VaultSessionClockClient {
        get { self[VaultSessionClockClient.self] }
        set { self[VaultSessionClockClient.self] = newValue }
    }
}
