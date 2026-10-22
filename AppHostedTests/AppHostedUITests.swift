//
//  AppHostedUITests.swift
//  MediaVault
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Testing

/// Shared serialized parent suite for the app-hosted test target.
///
/// App-hosted tests mount real UIWindow scenes and drive WebKit contexts owned by
/// BrowserWebKitAdapter.shared. Swift Testing executes tests and suites concurrently by
/// default, so two suites that suspend while waiting for display turns or WebKit callbacks
/// can interleave and observe each other's partially torn-down process-level state.
///
/// Nesting every suite that touches the app-hosted environment beneath this parent and
/// marking the parent .serialized makes Swift Testing run the entire subtree one test at a
/// time: sibling child suites cannot execute concurrently with one another. The trait is
/// inherited by nested suites, so a child does not need to repeat it.
///
/// Add new app-hosted suites as nested types in an extension of this type rather than as
/// top-level suites, so the serialization boundary keeps covering them.
@Suite("App-hosted UI tests", .serialized)
struct AppHostedUITests {}

/// Counts active polling work instead of wall-clock time for app-hosted waits.
///
/// A suspended test host cannot run WebKit callbacks or the waiting task. Predicate
/// work, including layout and observation, is charged in full. Only overrun beyond the
/// intentional poll sleep is discounted, so external suspension cannot consume the
/// active budget while an active stall still reaches a finite deadline.
struct AppHostedActivePollBudget {
    private let pollInterval: Duration
    private(set) var remaining: Duration

    init(timeout: Duration, pollInterval: Duration = .milliseconds(20)) {
        precondition(timeout > .zero)
        precondition(pollInterval > .zero)
        self.pollInterval = pollInterval
        remaining = timeout
    }

    var canPoll: Bool {
        remaining > .zero
    }

    mutating func chargeActiveWork(after duration: Duration) {
        precondition(duration >= .zero)
        charge(duration)
    }

    mutating func chargePollSleep(after duration: Duration) {
        precondition(duration >= .zero)
        charge(min(duration, pollInterval))
    }

    private mutating func charge(_ duration: Duration) {
        let charged = duration
        remaining = charged < remaining ? remaining - charged : .zero
    }
}

/// Polls a main-actor condition while distinguishing active predicate work from
/// intentional sleep. Cancellation is checked around predicate and sleep work, so a
/// canceled test cannot continue polling or report a satisfied condition.
@MainActor
func waitForAppHostedPolling(
    timeout: Duration,
    pollInterval: Duration = .milliseconds(20),
    onBeforeSleep: (@MainActor () -> Void)? = nil,
    pollSleep: (@MainActor (Duration) async throws -> Void)? = nil,
    predicate: @MainActor () -> Bool,
) async throws -> Bool {
    try Task.checkCancellation()
    var budget = AppHostedActivePollBudget(
        timeout: timeout,
        pollInterval: pollInterval,
    )
    let clock = ContinuousClock()
    while budget.canPoll {
        try Task.checkCancellation()

        let observationStartedAt = clock.now
        let satisfied = predicate()
        budget.chargeActiveWork(after: observationStartedAt.duration(to: clock.now))
        try Task.checkCancellation()

        if satisfied {
            return budget.canPoll
        }
        guard budget.canPoll else {
            break
        }

        try Task.checkCancellation()
        onBeforeSleep?()
        try Task.checkCancellation()
        let sleepStartedAt = clock.now
        if let pollSleep {
            try await pollSleep(pollInterval)
        } else {
            try await Task.sleep(for: pollInterval)
        }
        budget.chargePollSleep(after: sleepStartedAt.duration(to: clock.now))
        try Task.checkCancellation()
    }
    try Task.checkCancellation()
    return false
}
