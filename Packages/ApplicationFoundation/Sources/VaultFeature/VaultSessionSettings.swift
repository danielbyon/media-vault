//
//  VaultSessionSettings.swift
//  MediaVault
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//

/// The selected period of inactivity before an authenticated vault session locks.
public enum VaultAutoLockTimeout: String, CaseIterable, Equatable, Sendable {
    /// Locks as soon as the application leaves the foreground.
    case immediately
    /// Allows a 30-second grace period after the application enters the background.
    case seconds30
    /// Allows a one-minute grace period after the application enters the background.
    case minute1
    /// Allows a five-minute grace period after the application enters the background.
    case minutes5
    /// Allows a 15-minute grace period after the application enters the background.
    case minutes15

    /// The grace period for the selected timeout, or `nil` when locking is immediate.
    public var duration: Duration? {
        switch self {
        case .immediately:
            nil
        case .seconds30:
            .seconds(30)
        case .minute1:
            .seconds(60)
        case .minutes5:
            .seconds(300)
        case .minutes15:
            .seconds(900)
        }
    }

    /// The concise label shown when a user selects an auto-lock timeout.
    public var displayName: String {
        switch self {
        case .immediately:
            "Immediately"
        case .seconds30:
            "30 seconds"
        case .minute1:
            "1 minute"
        case .minutes5:
            "5 minutes"
        case .minutes15:
            "15 minutes"
        }
    }
}

/// The single gesture that immediately locks an authenticated vault session.
public enum VaultEmergencyLockGesture: String, CaseIterable, Equatable, Sendable {
    /// Disables emergency gesture locking.
    case off
    /// Locks when the device is shaken.
    case shake
    /// Locks after four taps from a single finger.
    case quadrupleTap

    /// The concise label shown when a user selects an emergency lock gesture.
    public var displayName: String {
        switch self {
        case .off:
            "Off"
        case .shake:
            "Shake"
        case .quadrupleTap:
            "Single-finger quadruple-tap"
        }
    }
}

/// Persisted preferences that control vault session auto-lock and emergency locking.
public struct VaultSessionSettings: Equatable, Sendable {
    /// The selected inactivity interval before an authenticated session locks.
    public var autoLockTimeout: VaultAutoLockTimeout
    /// The one selected gesture that immediately locks an authenticated session.
    public var emergencyLockGesture: VaultEmergencyLockGesture

    /// Creates session preferences, using immediate auto-lock and no gesture by default.
    public init(
        autoLockTimeout: VaultAutoLockTimeout = .immediately,
        emergencyLockGesture: VaultEmergencyLockGesture = .off,
    ) {
        self.autoLockTimeout = autoLockTimeout
        self.emergencyLockGesture = emergencyLockGesture
    }
}
