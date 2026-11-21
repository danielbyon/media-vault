//
//  BrowserDownloadSecuritySentinelLifecycle.swift
//  MediaVault
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//

// Foundation-only contracts shared by the standalone download security qualification host and
// its `BrowserTabOverviewUITests` bundle.
//
// The file is compiled only into those two qualification targets and depends only on the Swift
// standard library. Keeping the contracts free of UIKit and app modules lets the UI test bundle
// exercise the same rules the host runs on a physical device without launching the host, and it
// keeps every rule testable from a plain XCTest case.
//
// The contracts in this file cover:
//
// 1. `BrowserDownloadSecuritySentinelLifecycle` models the states and transitions of the
//    protected-data sentinel, including the once-per-process qualification cycle.
// 2. Terminal cleanup and repeated-preparation presentation keep host-side effects aligned with
//    lifecycle decisions while remaining independently testable.
// 3. `BrowserDownloadCleanupAttribution` classifies whether a cold-relaunch qualification run
//    may claim that startup cleanup removed a previous download allocation.

/// State machine for the single protected-data qualification cycle of one process.
///
/// The standalone qualification host drives this machine:
///
/// - `prepare()` is accepted only while the cycle has not begun. Preparation success arms the
///   cycle; preparation failure consumes it with an immutable terminal classification. Every
///   later `prepare()` returns `refusedCycleAlreadyUsed`, so retry requires a process relaunch.
/// - The lock window opens only from `armed`. Lock and unlock observations that do not fit the
///   current state (duplicate notifications, or any notification after a terminal
///   classification) are ignored so recorded evidence cannot contradict itself.
/// - Unlock recovery leads to an immutable terminal classification. Repeated transitions and
///   repeated preparations return refusals without changing the recorded classification.
struct BrowserDownloadSecuritySentinelLifecycle: Equatable {
    /// Coarse lifecycle state of the process-wide qualification cycle.
    enum State: Equatable {
        /// No preparation has been requested yet.
        case idle
        /// A preparation request was accepted and its probe is about to run.
        case preparing
        /// The marker was verified and the lock window may open.
        case armed
        /// Protected data became unavailable and the sentinel is polling for the gated read.
        case lockWindow
        /// The gated locked read was recorded; the sentinel now waits for unlock.
        case lockedAttempt
        /// Unlock recovery is in flight; the terminal classification is not decided yet.
        case recoveryInProgress
        /// The cycle ended with an immutable classification.
        case terminal(Terminal)
    }

    /// Immutable outcome of a finished cycle.
    enum Terminal: Equatable {
        /// Unlock recovery read the marker, removed it, and verified absence.
        case completed
        /// Unlock recovery could not verify the fresh read and removal.
        case unlockFailed
        /// Preparation failed before the marker and unlocked read could be verified.
        case preparationFailed
        /// The cycle ended without a gated locked read, so denial attribution is INCONCLUSIVE.
        case lockWindowInconclusive
    }

    /// Result of requesting preparation of the single qualification cycle.
    enum PrepareDecision: Equatable {
        /// The caller may run the preparation probe.
        case accepted
        /// The preparation probe failed and consumed the process-wide cycle. The caller must
        /// report a terminal non-armed state and require a relaunch.
        case preparationFailed
        /// The process already began this cycle. The caller must refuse the request and record a
        /// sanitized refusal observation instead of preparing again.
        case refusedCycleAlreadyUsed
    }

    /// Verified evidence required before the sentinel may enter the armed state.
    enum PreparationEvidence: Equatable {
        /// Marker creation, fresh unlocked read, complete protection, backup exclusion, and a
        /// valid background assertion were all established.
        case verified
        /// The marker could not be created or inspected.
        case missingMarker
        /// A fresh unlocked read did not return the marker bytes.
        case missingUnlockedRead
        /// The marker did not report `NSFileProtectionComplete`.
        case missingCompleteProtection
        /// The marker was not excluded from backup.
        case missingBackupExclusion
        /// UIKit did not return a valid background assertion identifier.
        case missingBackgroundAssertion
    }

    /// Sanitized cleanup the sentinel must perform for a consumed terminal cycle.
    enum TerminalCleanupAction: Equatable {
        /// Remove the isolated marker and retire watcher, assertion, and observers.
        case removeMarkerAndRetireResources
    }

    /// Result of completing an accepted preparation probe.
    enum PreparationOutcome: Equatable {
        /// Every prerequisite is verified and the sentinel is armed.
        case armed
        /// Preparation consumed the cycle without arming and requires terminal cleanup.
        case terminalFailure(TerminalCleanupAction)
    }

    /// Result of attempting to record an INCONCLUSIVE locked read.
    enum InconclusiveAttemptDecision: Equatable {
        /// A pre-lock or lock-window attempt consumed the cycle and requires terminal cleanup.
        case terminal(TerminalCleanupAction)
        /// Unlock recovery already owns cleanup and must continue to its terminal result.
        case recoveryContinues
        /// The lifecycle rejected a duplicate or late event; the caller must do nothing.
        case ignored
    }

    /// Result of a protected-data-unavailable notification.
    enum LockWindowDecision: Equatable {
        /// The lock window opened; the caller may start polling for the gated read.
        case accepted
        /// The notification does not fit the current state and must not alter evidence.
        case ignored
    }

    /// Result of recording a gated locked-read attempt.
    enum LockedAttemptDecision: Equatable {
        /// The attempt was recorded; the cycle now waits for unlock.
        case accepted
        /// The attempt cannot be recorded in the current state.
        case ignored
    }

    /// Result of a protected-data-available notification.
    enum UnlockRecoveryDecision: Equatable {
        /// Recovery should run. `requiresInconclusiveAttempt` is true when no locked-read
        /// attempt was recorded yet, so the caller must first record an INCONCLUSIVE locked
        /// attempt; such a run cannot claim a gated denial.
        case accepted(requiresInconclusiveAttempt: Bool)
        /// The notification does not fit the current state (duplicate or terminal) and must be
        /// ignored.
        case ignored
    }

    /// Current lifecycle state; transitions are the only way to change it.
    private(set) var state: State = .idle

    /// True once a locked-read attempt, real or INCONCLUSIVE, has been recorded for this cycle.
    private(set) var lockedAttemptObserved = false

    /// Requests preparation of the process-wide cycle.
    mutating func prepare() -> PrepareDecision {
        switch state {
        case .idle:
            state = .preparing
            return .accepted
        case .preparing,
             .armed,
             .lockWindow,
             .lockedAttempt,
             .recoveryInProgress,
             .terminal:
            return .refusedCycleAlreadyUsed
        }
    }

    /// Records the outcome of an accepted preparation probe.
    @discardableResult
    mutating func finishPreparation(evidence: PreparationEvidence) -> PreparationOutcome {
        guard state == .preparing else {
            return .terminalFailure(.removeMarkerAndRetireResources)
        }
        guard evidence == .verified else {
            state = .terminal(.preparationFailed)
            return .terminalFailure(.removeMarkerAndRetireResources)
        }

        state = .armed
        return .armed
    }

    /// Requests the lock window after protected data became unavailable.
    mutating func observeLockWindow() -> LockWindowDecision {
        guard state == .armed else {
            return .ignored
        }

        state = .lockWindow
        return .accepted
    }

    /// Records the gated locked read performed while protected data was unavailable.
    mutating func recordLockedAttempt() -> LockedAttemptDecision {
        guard state == .lockWindow, !lockedAttemptObserved else {
            return .ignored
        }

        lockedAttemptObserved = true
        state = .lockedAttempt
        return .accepted
    }

    /// Records an INCONCLUSIVE locked attempt after a lock window ended without a gated read.
    ///
    /// The returned decision says whether the transition consumed the cycle and requires terminal
    /// cleanup, belongs to recovery already in progress, or was ignored. A cycle stores the
    /// INCONCLUSIVE attempt at most once, and terminal cycles accept no further records. An
    /// attempt recorded while armed or in the lock window consumes the cycle immediately; one
    /// recorded during unlock recovery leaves recovery in flight so marker cleanup can still
    /// reach its terminal result.
    mutating func recordInconclusiveLockedAttempt() -> InconclusiveAttemptDecision {
        guard !lockedAttemptObserved else {
            return .ignored
        }

        switch state {
        case .armed,
             .lockWindow:
            lockedAttemptObserved = true
            state = .terminal(.lockWindowInconclusive)
            return .terminal(.removeMarkerAndRetireResources)
        case .recoveryInProgress:
            lockedAttemptObserved = true
            return .recoveryContinues
        case .idle,
             .preparing,
             .lockedAttempt,
             .terminal:
            return .ignored
        }
    }

    /// Starts the single post-unlock recovery.
    mutating func beginUnlockRecovery() -> UnlockRecoveryDecision {
        switch state {
        case .armed,
             .lockWindow,
             .lockedAttempt:
            let requiresInconclusiveAttempt = !lockedAttemptObserved
            state = .recoveryInProgress
            return .accepted(requiresInconclusiveAttempt: requiresInconclusiveAttempt)
        case .idle,
             .preparing,
             .recoveryInProgress,
             .terminal:
            return .ignored
        }
    }

    /// Records the recovery outcome and moves the cycle to its immutable terminal state.
    ///
    /// Returns false when the cycle is not in recovery, for example when a duplicate
    /// protected-data-available delivery asks for a second recovery; the terminal
    /// classification then remains unchanged.
    @discardableResult
    mutating func finishUnlockRecovery(succeeded: Bool) -> Bool {
        guard state == .recoveryInProgress else {
            return false
        }

        state = .terminal(succeeded ? .completed : .unlockFailed)
        return true
    }
}

/// Sanitized result of deleting the sentinel's isolated marker directory.
///
/// The result deliberately carries no path, file contents, or underlying error description.
enum BrowserDownloadSecuritySentinelMarkerRemovalResult: Equatable {
    /// The marker directory is verifiably absent after cleanup.
    case removed
    /// The marker directory could not be removed or remains present.
    case failed
}

/// Executes terminal marker cleanup while guaranteeing that process resources are retired.
///
/// Resource retirement runs after either removal result. The caller can therefore report a
/// truthful marker-cleanup failure without leaving a watcher, background assertion, or observer
/// alive in a consumed process cycle.
enum BrowserDownloadSecuritySentinelTerminalCleanup {
    /// Sanitized outcome used by the host to select terminal status and evidence.
    enum Result: Equatable {
        /// Marker removal succeeded and resource retirement ran.
        case completed
        /// Marker removal failed, but resource retirement still ran.
        case markerRemovalFailed
    }

    static func perform(
        removeMarker: () -> BrowserDownloadSecuritySentinelMarkerRemovalResult,
        retireResources: () -> Void,
    ) -> Result {
        let markerRemoval = removeMarker()
        retireResources()
        return markerRemoval == .removed ? .completed : .markerRemovalFailed
    }
}

/// Sanitized presentation detail for a repeated preparation request.
///
/// A refusal is separate from the primary lifecycle stage. This lets the host report the refused
/// request without replacing an armed or terminal stage that explains the cycle's actual state.
struct BrowserDownloadSecuritySentinelPreparationRefusal: Equatable {
    /// Lifecycle stage that remains visible after the refusal.
    let preservedStage: String

    init?(
        decision: BrowserDownloadSecuritySentinelLifecycle.PrepareDecision,
        currentStage: String,
    ) {
        guard decision == .refusedCycleAlreadyUsed else {
            return nil
        }

        preservedStage = currentStage
    }

    init(preservedStage: String) {
        self.preservedStage = preservedStage
    }
}

// The canonical analyzer corpus builds the host target, which compiles this shared file but never
// references the cleanup classification below; only the BrowserTabOverviewUITests bundle does, so
// the host copy's declarations read as unreferenced. The suppression stays scoped to this contract.
// swiftlint:disable unused_declaration
/// Classifies observations polled during the physical locked-data qualification window.
///
/// Terminal marker-cleanup failure takes precedence over recovery because the run must fail with
/// its sanitized evidence instead of waiting for the operator deadline and reporting an unrelated
/// INCONCLUSIVE result.
enum BrowserDownloadLockedQualificationObservationOutcome: Equatable {
    /// Sanitized fields emitted by a terminal marker-cleanup failure.
    struct TerminalCleanupFailureEvidence: Equatable {
        let stage: String?
        let markerRemoved: String?
        let relaunchRequired: String?
    }

    /// Sanitized fields proving that execution stopped before a locked fresh read.
    struct NoAttemptEvidence: Equatable {
        let freshOpenAttempted: String?
        let reason: String?
    }

    /// The observation surface could not be read or decoded.
    case observationSurfaceUnreadable
    /// A decoded observation surface contains no terminal evidence yet.
    case waiting
    /// Unlock recovery is available for the physical qualification assertions.
    case recovered([String: String])
    /// The host recorded that no locked fresh read ran, so denial remains INCONCLUSIVE.
    case inconclusiveNoAttempt(NoAttemptEvidence)
    /// Terminal cleanup failed and the qualification must fail immediately.
    case terminalCleanupFailed(TerminalCleanupFailureEvidence)

    init(observations: [[String: String]]?) {
        guard let observations else {
            self = .observationSurfaceUnreadable
            return
        }

        if let failure = observations.last(where: {
            $0["event"] == "securitySentinelTerminalCleanupFailed"
        }) {
            self = .terminalCleanupFailed(.init(
                stage: failure["stage"],
                markerRemoved: failure["markerRemoved"],
                relaunchRequired: failure["relaunchRequired"],
            ))
        } else if let recovery = observations.last(where: {
            $0["event"] == "securitySentinelUnlockedRecovery"
        }) {
            self = .recovered(recovery)
        } else if let noAttempt = observations.last(where: {
            $0["event"] == "securitySentinelLockedAttempt"
                && $0["freshOpenAttempted"] != "true"
        }) {
            self = .inconclusiveNoAttempt(.init(
                freshOpenAttempted: noAttempt["freshOpenAttempted"],
                reason: noAttempt["inconclusiveReason"],
            ))
        } else {
            self = .waiting
        }
    }
}

/// Classification of whether a cold-relaunch qualification run may claim that startup cleanup
/// removed the previous download allocation.
///
/// The relaunched qualification host reports whether it found a persisted correlation for the
/// previous allocation and whether the allocation was still present when the startup purge
/// inspected the scratch root (`expectedPresent`). That raw report is a string in the recorded
/// observations, and only an exact `"true"` supports the cleanup claim. An explicit `"false"`
/// (the allocation was already gone before the purge ran) and a missing or unrecognized value
/// both leave removal attribution undetermined. They stay distinct so a run that reported no
/// correlation is never described as if the host had reported `expectedPresent=false`.
enum BrowserDownloadCleanupAttribution: Equatable {
    /// The host reported a present, correlated allocation: startup cleanup removal can be
    /// claimed and the qualification run keeps its strict removal assertions.
    case verifiedRemoval
    /// The run cannot claim that startup cleanup removed the allocation.
    case inconclusive(BrowserDownloadCleanupInconclusiveReason)

    /// Classifies the raw `expectedPresent` observation value.
    ///
    /// Only the exact string `"true"` is accepted. Values such as `"TRUE"`, `"true "`, "1", or
    /// an empty string are not implicit truthy reports; they classify as missing or unrecognized
    /// presence evidence even when operation correlation is available.
    init(expectedPresent: String?) {
        switch expectedPresent {
        case "true":
            self = .verifiedRemoval
        case "false":
            self = .inconclusive(.expectedPresentFalse)
        default:
            self = .inconclusive(.expectedPresentMissing)
        }
    }
}

/// Classifies whether a startup-purge observation has a concrete operation correlation before a
/// physical qualification test performs its mandatory same-allocation assertion.
enum BrowserDownloadStartupInspectionClassification: Equatable {
    /// The observation names a concrete operation. The caller must require exact equality with
    /// the allocation verified before termination, then evaluate cleanup attribution.
    case correlated(expectedOperation: String, cleanupAttribution: BrowserDownloadCleanupAttribution)
    /// The observation omitted a usable operation correlation, so removal attribution cannot be
    /// proved. The qualification test still runs every non-restoration and fresh-download check
    /// before reporting INCONCLUSIVE.
    case inconclusive(BrowserDownloadCleanupInconclusiveReason)

    /// Classifies the two correlation fields emitted by startup inspection.
    init(expectedOperation: String?, expectedPresent: String?) {
        guard let expectedOperation, !expectedOperation.isEmpty, expectedOperation != "unavailable" else {
            self = .inconclusive(.expectedOperationUnavailable)
            return
        }

        self = .correlated(
            expectedOperation: expectedOperation,
            cleanupAttribution: BrowserDownloadCleanupAttribution(expectedPresent: expectedPresent),
        )
    }
}

/// Why a cold-relaunch qualification run cannot attribute removal of the previous allocation to
/// startup cleanup. The cases stay distinct so test attachments and skip messages describe what
/// the host actually reported.
enum BrowserDownloadCleanupInconclusiveReason: Equatable {
    /// The host did not recover a usable persisted operation identifier for the prior allocation.
    case expectedOperationUnavailable
    /// The host explicitly reported that the correlated allocation was already absent before
    /// the purge ran.
    case expectedPresentFalse
    /// The host reported no recognized presence evidence for the correlated allocation: the
    /// value was missing, empty, or not an exact `"true"`/`"false"` string.
    case expectedPresentMissing

    /// Human-readable explanation used in INCONCLUSIVE attachments and skip messages. The
    /// missing case must never reuse the wording of the explicit `false` case.
    var qualificationDescription: String {
        switch self {
        case .expectedOperationUnavailable:
            "the relaunched host reported no usable persisted allocation operation correlation"
        case .expectedPresentFalse:
            "the relaunched host reported the previous allocation as already absent "
                + "before startup cleanup ran (expectedPresent=false)"
        case .expectedPresentMissing:
            "the relaunched host did not report whether the correlated allocation was present "
                + "before startup cleanup, so removal cannot be attributed to startup cleanup"
        }
    }
}

// swiftlint:enable unused_declaration
