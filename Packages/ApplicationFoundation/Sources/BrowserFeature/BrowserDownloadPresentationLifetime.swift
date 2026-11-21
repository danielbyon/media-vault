//
//  BrowserDownloadPresentationLifetime.swift
//  MediaVault
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//

/// Native admission and dismissal are separate from completed-file retention. The coordinator
/// supplies UIKit's observed presence; a timeout or reactivation is never proof of absence.
struct BrowserDownloadPresentationLifetime {
    enum AdmissionDecision: Equatable {
        case waitForAbsence
        case rejectUnavailablePresenter
        case present
    }

    /// An accepted new request waits behind old native lifetime; unavailable presenters are
    /// rejected only after the old controller is confirmed absent, so no replacement is attempted.
    func admissionDecision(presenterAvailable: Bool) -> AdmissionDecision {
        if admitted {
            return .waitForAbsence
        }
        return presenterAvailable ? .present : .rejectUnavailablePresenter
    }

    private(set) var admitted = false
    private(set) var completed = false
    private(set) var revoked = false
    private(set) var dismissalPending = false
    private(set) var dismissalRequested = false

    mutating func begin() -> Bool {
        guard !admitted else {
            return false
        }

        admitted = true
        return true
    }

    mutating func revoke() {
        guard admitted else {
            return
        }

        revoked = true
        dismissalPending = true
    }

    mutating func complete() {
        guard admitted else {
            return
        }

        completed = true
    }

    mutating func activityEnded() {
        guard admitted else {
            return
        }

        dismissalPending = true
    }

    mutating func requestDismissal(isPresented: Bool) -> Bool {
        guard admitted, isPresented, !dismissalRequested else {
            return false
        }

        dismissalPending = true
        dismissalRequested = true
        return true
    }

    /// Late completion remains revoked until both completion and actual UIKit absence are observed.
    mutating func confirmAbsence(isAbsent: Bool) -> Bool {
        guard admitted, completed, isAbsent else {
            return false
        }

        self = Self()
        return true
    }
}
