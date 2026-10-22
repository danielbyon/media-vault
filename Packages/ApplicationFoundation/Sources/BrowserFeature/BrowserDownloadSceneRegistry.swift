//
//  BrowserDownloadSceneRegistry.swift
//  MediaVault
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

/// Shared-browser admission requires every hosting window to be active. A transition in one
/// window can revoke downloads owned by another; activation never restores revoked operations.
@MainActor
final class BrowserDownloadSceneRegistry {
    private var registrations: [UUID: Bool] = [:]
    private let authenticated: @MainActor () -> Bool

    init(authenticated: @escaping @MainActor () -> Bool) {
        self.authenticated = authenticated
    }

    var isAuthorized: Bool {
        authenticated() && !registrations.isEmpty && registrations.values.allSatisfy(\.self)
    }

    func register(_ id: UUID, active: Bool) {
        registrations[id] = active
    }

    /// Returns false for duplicate delivery so native dismissal and generation revocation occur once.
    @discardableResult
    func setActive(_ active: Bool, for id: UUID) -> Bool {
        guard let previous = registrations[id], previous != active else {
            return false
        }

        registrations[id] = active
        return true
    }

    func unregister(_ id: UUID) {
        registrations.removeValue(forKey: id)
    }
}
