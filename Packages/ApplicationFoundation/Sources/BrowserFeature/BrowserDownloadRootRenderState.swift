//
//  BrowserDownloadRootRenderState.swift
//  MediaVault
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//

/// Immutable identity captured when the root body selects its surface. Privacy generation prevents
/// an authentication round trip from authorizing a previously evaluated surface with the same name.
public struct BrowserDownloadRootRenderToken: Equatable, Sendable {
    /// Stable identity of the selected credential, decoy, or authenticated surface.
    public let surfaceID: String
    /// Authentication value at body evaluation, rather than at later UIKit reconciliation.
    public let authenticated: Bool
    /// Download privacy generation at body evaluation.
    public let privacyGeneration: UInt64

    /// Creates a token from the immutable values used to evaluate one root body.
    public init(surfaceID: String, authenticated: Bool, privacyGeneration: UInt64) {
        self.surfaceID = surfaceID
        self.authenticated = authenticated
        self.privacyGeneration = privacyGeneration
    }
}

/// Cover release needs a matching root layout transaction, with native modals absent and
/// live authentication matching the reconciled surface. A SwiftUI update alone is not proof.
struct BrowserDownloadRootRenderState {
    private(set) var revision: UInt64 = 0
    private(set) var token: BrowserDownloadRootRenderToken?
    private(set) var confirmed = false

    @discardableResult
    mutating func update(token: BrowserDownloadRootRenderToken, liveToken: BrowserDownloadRootRenderToken) -> Bool {
        invalidate()
        guard token == liveToken else {
            self.token = nil
            return false
        }

        self.token = token
        return true
    }

    mutating func invalidate() {
        revision &+= 1
        confirmed = false
    }

    mutating func confirm(
        revision: UInt64,
        token: BrowserDownloadRootRenderToken,
        liveToken: BrowserDownloadRootRenderToken,
        rootAttached: Bool,
        modalsAbsent: Bool,
        layoutCommitted: Bool,
    ) {
        guard revision == self.revision, self.token == token, token == liveToken,
              rootAttached, modalsAbsent, layoutCommitted else {
            return
        }

        confirmed = true
    }

    /// Cleanup failure denies downloads through their owner, not navigation or credential entry.
    func canReleaseCover(sceneActive: Bool, nativeAdmissionHeld: Bool) -> Bool {
        sceneActive && confirmed && !nativeAdmissionHeld
    }
}
