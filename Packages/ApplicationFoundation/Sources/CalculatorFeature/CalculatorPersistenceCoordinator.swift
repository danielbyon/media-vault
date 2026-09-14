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

    struct SaveRequest: Sendable {
        let revision: Int
        let outcome: AsyncStream<SaveOutcome>
    }

    private enum RetryOperation: Equatable, Sendable {
        case load
        case save
    }

    private struct PendingRequest {
        let revision: Int
        let snapshot: CalculatorSnapshot
        let save: @Sendable (CalculatorSnapshot) async throws -> Void
        let continuation: AsyncStream<SaveOutcome>.Continuation
    }

    private let lock = NSLock()
    private var nextRevision = 0
    private var latestRevision = 0
    private var pendingRequest: PendingRequest?
    private var worker: Task<Void, Never>?
    private var retryOperation: RetryOperation?

    /// Reserves a revision for a non-persistence operation such as loading.
    ///
    /// A save uses ``enqueue(_:save:)`` instead so revision advancement and save admission happen
    /// atomically.
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
        save: @escaping @Sendable (CalculatorSnapshot) async throws -> Void,
    ) -> SaveRequest {
        let outcome = AsyncStream<SaveOutcome>.makeStream()
        let (revision, supersededContinuation): (
            Int,
            AsyncStream<SaveOutcome>.Continuation?,
        ) = lock.withLock {
            nextRevision += 1
            let revision = nextRevision
            latestRevision = revision
            let request = PendingRequest(
                revision: revision,
                snapshot: snapshot,
                save: save,
                continuation: outcome.continuation,
            )
            let supersededContinuation = pendingRequest?.continuation
            pendingRequest = request
            if worker == nil {
                worker = Task { [self] in
                    await run()
                }
            }
            return (revision, supersededContinuation)
        }
        supersededContinuation?.yield(.superseded)
        supersededContinuation?.finish()
        return SaveRequest(revision: revision, outcome: outcome.stream)
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
                finish(.superseded, for: request)
                continue
            }

            do {
                try await request.save(request.snapshot)
                finish(isLatest(request.revision) ? .succeeded : .superseded, for: request)
            } catch {
                finish(isLatest(request.revision) ? .failed : .superseded, for: request)
            }
        }
    }

    private func finish(_ outcome: SaveOutcome, for request: PendingRequest) {
        request.continuation.yield(outcome)
        request.continuation.finish()
    }

    private func isLatest(_ revision: Int) -> Bool {
        lock.withLock { revision == latestRevision }
    }
}
