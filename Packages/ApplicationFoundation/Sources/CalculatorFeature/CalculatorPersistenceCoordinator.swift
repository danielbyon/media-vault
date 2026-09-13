//
//  CalculatorPersistenceCoordinator.swift
//  MediaVault
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

/// Serializes calculator saves and keeps only the newest pending snapshot.
///
/// Reducer effects are allowed to run concurrently, while the calculator store represents a
/// single logical document. This coordinator prevents an older asynchronous save from completing
/// after a newer save and overwriting the latest state. A pending request that has not started is
/// superseded without touching the persistence boundary.
final class CalculatorPersistenceCoordinator: @unchecked Sendable {
    enum SaveOutcome: Sendable {
        case superseded
        case succeeded
        case failed
    }

    private enum RetryOperation: Equatable, Sendable {
        case load
        case save
    }

    private struct PendingRequest {
        let revision: Int
        let snapshot: CalculatorSnapshot
        let save: @Sendable (CalculatorSnapshot) async throws -> Void
        let continuation: CheckedContinuation<SaveOutcome, Never>
    }

    private let lock = NSLock()
    private var nextRevision = 0
    private var latestRevision = 0
    private var pendingRequest: PendingRequest?
    private var worker: Task<Void, Never>?
    private var retryOperation: RetryOperation?

    /// Reserves a revision before an asynchronous persistence effect starts.
    ///
    /// Reserving synchronously lets the reducer invalidate an older outcome as soon as a newer
    /// edit or load retry is reduced, even if the new effect has not started executing yet.
    @discardableResult
    func reserveRevision() -> Int {
        lock.withLock {
            nextRevision += 1
            latestRevision = nextRevision
            return nextRevision
        }
    }

    func enqueue(
        _ snapshot: CalculatorSnapshot,
        revision: Int,
        save: @escaping @Sendable (CalculatorSnapshot) async throws -> Void,
    ) async -> SaveOutcome {
        await withCheckedContinuation { continuation in
            let supersededContinuation: CheckedContinuation<SaveOutcome, Never>? = lock.withLock {
                guard revision == latestRevision else {
                    return continuation
                }

                let request = PendingRequest(
                    revision: revision,
                    snapshot: snapshot,
                    save: save,
                    continuation: continuation,
                )
                let supersededContinuation = pendingRequest?.continuation
                pendingRequest = request
                if worker == nil {
                    worker = Task { [self] in
                        await run()
                    }
                }
                return supersededContinuation
            }
            supersededContinuation?.resume(returning: .superseded)
        }
    }

    func isCurrent(_ revision: Int) -> Bool {
        lock.withLock { revision == latestRevision }
    }

    func markLoadFailure() {
        lock.withLock {
            retryOperation = .load
        }
    }

    func markSaveFailure() {
        lock.withLock {
            retryOperation = .save
        }
    }

    func clearRetryOperation() {
        lock.withLock {
            retryOperation = nil
        }
    }

    var shouldRetryLoad: Bool {
        lock.withLock { retryOperation == .load }
    }

    private func run() async {
        while true {
            let request: PendingRequest? = lock.withLock {
                guard let request = pendingRequest else {
                    worker = nil
                    return nil
                }

                pendingRequest = nil
                return request
            }
            guard let request else {
                return
            }
            guard isLatest(request.revision) else {
                request.continuation.resume(returning: .superseded)
                continue
            }

            do {
                try await request.save(request.snapshot)
                request.continuation.resume(
                    returning: isLatest(request.revision) ? .succeeded : .superseded,
                )
            } catch {
                request.continuation.resume(
                    returning: isLatest(request.revision) ? .failed : .superseded,
                )
            }
        }
    }

    private func isLatest(_ revision: Int) -> Bool {
        lock.withLock { revision == latestRevision }
    }
}
