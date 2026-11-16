//
//  BrowserDownloadBackgroundExecution.swift
//  MediaVault
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import UIKit

/// Requests one finite execution allowance for a contiguous group of admitted downloads.
/// Expiration releases the allowance without cancelling transfers or renewing it indefinitely.
@MainActor
final class BrowserDownloadBackgroundExecution {
    private let begin: @MainActor @Sendable (@escaping @MainActor @Sendable () -> Void) -> UIBackgroundTaskIdentifier
    private let end: @MainActor @Sendable (UIBackgroundTaskIdentifier) -> Void
    private var identifier = UIBackgroundTaskIdentifier.invalid
    private var expired = false
    private var leaseGeneration: UInt64 = 0

    init(
        begin: @escaping @MainActor @Sendable (@escaping @MainActor @Sendable () -> Void)
            -> UIBackgroundTaskIdentifier = {
                UIApplication.shared.beginBackgroundTask(withName: "Browser download completion", expirationHandler: $0)
            },
        end: @escaping @MainActor @Sendable (UIBackgroundTaskIdentifier)
            -> Void = { UIApplication.shared.endBackgroundTask($0) },
    ) {
        self.begin = begin
        self.end = end
    }

    func update(hasWork: Bool) {
        if !hasWork {
            finish()
            expired = false
        } else if identifier == .invalid, !expired {
            leaseGeneration &+= 1
            let generation = leaseGeneration
            identifier = begin { [weak self] in
                guard let self, leaseGeneration == generation else {
                    return
                }

                expired = true
                finish()
            }
            if expired || leaseGeneration != generation {
                finish()
            }
            if identifier == .invalid {
                expired = true
            }
        }
    }

    deinit {
        let finalIdentifier = identifier
        let endAssertion = end
        if finalIdentifier != .invalid {
            Task { @MainActor in endAssertion(finalIdentifier) }
        }
    }

    private func finish() {
        leaseGeneration &+= 1
        guard identifier != .invalid else {
            return
        }

        let finished = identifier
        identifier = .invalid
        end(finished)
    }
}
