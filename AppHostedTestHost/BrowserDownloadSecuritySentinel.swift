//
//  BrowserDownloadSecuritySentinel.swift
//  MediaVault
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//

#if DEBUG && BROWSER_DOWNLOAD_STANDALONE_QUALIFICATION

import Foundation
import ObjectiveC
import Observation
import UIKit

/// Debug-only protected-data probe for the physical download security qualification host.
///
/// The component owns one small, non-sensitive marker file at an isolated location inside the
/// app's Application Support directory. Marker and directory are created with native .complete
/// file protection and excluded from backup. Simulators cannot reproduce protected data
/// behavior, so this component qualifies it on a real device:
///
/// 1. Preparation verifies the actual .complete attribute, proves one fresh unlocked read,
///    registers the real protectedDataWillBecomeUnavailable and protectedDataDidBecomeAvailable
///    observers, and arms a bounded background task so the process can attempt a read while the
///    device is locked.
/// 2. Every locked read is a brand-new open, and happens only when
///    UIApplication.isProtectedDataAvailable is false immediately beforehand, so a successful
///    read can never be mistaken for a locked-storage leak.
/// 3. After the operator unlocks the device the component repeats a fresh read, removes the
///    marker, and verifies absence.
///
/// Recorded observations carry stage names, booleans, counts, and error classifications only -
/// never a path, filename, marker contents, or other file data. A lock that suspends the process
/// before any attempt, and an unlock that arrives before the gated read, are reported as
/// INCONCLUSIVE instead of a denial.
///
/// The process-wide rules the component applies are modelled by
/// `BrowserDownloadSecuritySentinelLifecycle`, a Foundation-only contract shared with the
/// `BrowserTabOverviewUITests` bundle. The contract states that exactly one qualification cycle
/// can begin per process: once a preparation has armed the cycle, every later preparation is
/// refused until the process relaunches, and a terminal classification is immutable. Because the
/// contract is a plain value, XCTest cases cover those rules without protected-data
/// notifications or a device lock.
///
/// The lock/unlock transition itself has no simulator or unit-test seam: it depends on real
/// device lock state, real protected-data notifications, and real file protection, so its
/// regression coverage is the physical-device qualification test. A single unlock can deliver
/// the protected-data-available notification more than once; only the first delivery performs
/// the terminal recovery, which retires the watcher, the background assertion, and the
/// observers, and later duplicate deliveries are ignored.
@Observable
@MainActor
final class BrowserDownloadSecuritySentinel {
    /// Marker contents are fixed, non-sensitive bytes and are never exported.
    private static let marker = Data("browser-download-security-sentinel".utf8)
    private static let directoryName = "BrowserDownloadSecuritySentinel"
    private static let fileName = "sentinel-marker"
    /// Longest wall-clock window the component polls for protected data to become unavailable
    /// after the lock notification; the system may suspend the process sooner.
    private static let lockedWindow: TimeInterval = 20
    private static let availabilityPollInterval: TimeInterval = 0.25

    private let record: @MainActor (String, [String: String]) -> Void
    /// Shared authority for the process-wide qualification cycle: it decides whether a
    /// preparation is accepted, whether an observation still belongs to the cycle, and when the
    /// cycle holds its immutable terminal classification.
    private var lifecycle = BrowserDownloadSecuritySentinelLifecycle()
    private var lockWindowWatcher: Task<Void, Never>?
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var observers: [NSObjectProtocol] = []
    /// Coarse progress label rendered by the host so the operator can follow the sequence.
    private(set) var stage = "idle"

    /// Operator-facing summary of the current stage.
    ///
    /// The host renders this as the sentinel status accessibility value. Once any qualification
    /// cycle has begun in this process the summary states that another cycle requires a relaunch,
    /// so the one-cycle-per-process rule stays visible to the operator and to UI inspection.
    var stageSummary: String {
        switch lifecycle.state {
        case .idle,
             .preparing:
            stage
        case .armed,
             .lockWindow,
             .lockedAttempt,
             .recoveryInProgress,
             .terminal:
            stage + "; one qualification cycle per process - relaunch the host for another cycle."
        }
    }

    init(record: @escaping @MainActor (String, [String: String]) -> Void) {
        self.record = record
    }

    /// Creates and verifies the marker, proves one unlocked read, registers the protected-data
    /// observers, and arms the bounded background assertion for the next manual lock.
    ///
    /// The shared lifecycle contract decides whether this process may begin a cycle at all. A
    /// preparation that arrives after the process has already armed, is running, or has finished
    /// its single qualification cycle is refused before any file is created, any observer is
    /// registered, or any background assertion is armed; the refusal is recorded as a sanitized
    /// observation so the host can report that a relaunch is required.
    @discardableResult
    func prepare() -> BrowserDownloadSecuritySentinelLifecycle.PrepareDecision {
        let decision = lifecycle.prepare()
        if let refusal = BrowserDownloadSecuritySentinelPreparationRefusal(
            decision: decision,
            currentStage: stage,
        ) {
            record("securitySentinelPrepareRefused", [
                "stage": "prepareRefused",
                "lifecycleStage": refusal.preservedStage,
                "reason": "cycleAlreadyUsed",
                "relaunchRequired": "true",
            ])
            return decision
        }

        stage = "preparing"
        var fields = ["stage": stage]
        do {
            let file = try createMarkerIfNeeded()
            fields["probePrepared"] = "true"
            fields["protectionAttribute"] = try protectionDescription(of: file)
            fields["backupExcluded"] = try String(isExcludedFromBackup(file))
            fields["unlockedReadSucceeded"] = try String(readMarkerFreshly(from: file))
        } catch {
            fields["probePrepared"] = "false"
            fields["prepareErrorClass"] = Self.classify(error)
        }
        let prerequisitesVerified = fields["probePrepared"] == "true"
            && fields["unlockedReadSucceeded"] == "true"
            && fields["protectionAttribute"] == "complete"
            && fields["backupExcluded"] == "true"
        if prerequisitesVerified {
            registerProtectedDataObservers()
            armBackgroundAssertion()
        }
        fields["protectedDataAvailableAtPrepare"] = String(UIApplication.shared.isProtectedDataAvailable)
        fields["observersRegistered"] = String(!observers.isEmpty)
        fields["backgroundAssertionArmed"] = String(backgroundTask != .invalid)
        let preparationEvidence: BrowserDownloadSecuritySentinelLifecycle
            .PreparationEvidence =
                if fields["probePrepared"] != "true" {
                    .missingMarker
                } else if fields["unlockedReadSucceeded"] != "true" {
                    .missingUnlockedRead
                } else if fields["protectionAttribute"] != "complete" {
                    .missingCompleteProtection
                } else if fields["backupExcluded"] != "true" {
                    .missingBackupExclusion
                } else if backgroundTask == .invalid {
                    .missingBackgroundAssertion
                } else {
                    .verified
                }
        let preparationOutcome = lifecycle.finishPreparation(evidence: preparationEvidence)
        let armed = preparationOutcome == .armed
        stage = armed ? "armed" : "preparationFailedRelaunchRequired"
        fields["stage"] = stage
        record("securitySentinelPrepared", fields)
        if case let .terminalFailure(action) = preparationOutcome {
            performTerminalCleanup(action)
        }
        return armed ? .accepted : .preparationFailed
    }

    /// Registers the real protected-data observers; repeated registration is a no-op.
    private func registerProtectedDataObservers() {
        guard observers.isEmpty else {
            return
        }

        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: UIApplication.protectedDataWillBecomeUnavailableNotification,
            object: nil,
            queue: .main,
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.beginLockWindow()
            }
        })
        observers.append(center.addObserver(
            forName: UIApplication.protectedDataDidBecomeAvailableNotification,
            object: nil,
            queue: .main,
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.handleUnlock()
            }
        })
    }

    /// Starts the bounded locked window: waits for protected data to actually become unavailable,
    /// then attempts exactly one fresh read and classifies its outcome.
    ///
    /// The lifecycle accepts a lock window only for an armed cycle. A duplicate or late
    /// protected-data-unavailable delivery is ignored and records nothing, so one cycle cannot
    /// open two windows or emit a contradictory observation.
    private func beginLockWindow() {
        guard lifecycle.observeLockWindow() == .accepted else {
            return
        }
        guard lockWindowWatcher == nil else {
            return
        }

        stage = "lockWindow"
        record("securitySentinelLockObserved", [
            "stage": stage,
            "protectedDataAvailable": String(UIApplication.shared.isProtectedDataAvailable),
        ])
        if backgroundTask == .invalid {
            armBackgroundAssertion()
        }
        lockWindowWatcher = Task { [weak self] in
            let deadline = Date().addingTimeInterval(Self.lockedWindow)
            while !Task.isCancelled, Date() < deadline {
                guard let self else {
                    return
                }

                if !UIApplication.shared.isProtectedDataAvailable {
                    attemptLockedRead()
                    return
                }
                try? await Task.sleep(nanoseconds: UInt64(Self.availabilityPollInterval * 1_000_000_000))
            }
            guard !Task.isCancelled else {
                return
            }

            self?.finishLockWindowInconclusively(reason: "availabilityNeverFalseBeforeWindowEnd")
        }
    }

    /// Performs the single locked fresh read. The availability gate is re-checked immediately
    /// before the open; a read that succeeds here would be a genuine locked-storage leak.
    private func attemptLockedRead() {
        lockWindowWatcher = nil
        guard !UIApplication.shared.isProtectedDataAvailable else {
            finishLockWindowInconclusively(reason: "availabilityNotFalseAtAttempt")
            return
        }
        guard lifecycle.recordLockedAttempt() == .accepted else {
            // The cycle already recorded its single locked attempt, or it has finished: a
            // duplicate delivery must not open the marker, record, or clean up again.
            return
        }

        var fields = [
            "stage": "lockedAttempt",
            "protectedDataUnavailable": "true",
            "freshOpenAttempted": "true",
        ]
        do {
            let bytes = try Data(contentsOf: Self.fileURL())
            fields["denied"] = "false"
            fields["denialClass"] = bytes == Self.marker ? "none" : "contentMismatch"
            stage = "lockedReadUnexpected"
        } catch {
            fields["denied"] = "true"
            fields["denialClass"] = Self.classify(error)
            stage = "lockedReadDenied"
        }
        record("securitySentinelLockedAttempt", fields)
        endBackgroundAssertion()
    }

    /// Records that the process never performed a gated locked read, which cannot qualify denial
    /// attribution; the qualification test turns this into an INCONCLUSIVE result. The contract
    /// accepts at most one attempt record per cycle and none once the cycle is terminal, so a
    /// duplicate notification, an expired background assertion, or any late event after the
    /// terminal recovery records nothing. A decision that consumes the cycle retires all
    /// resources. An ignored expiration preserves the existing watcher, assertion, and observers
    /// because a previously accepted locked attempt still needs the unlock notification to run
    /// recovery.
    private func finishLockWindowInconclusively(reason: String) {
        let decision = lifecycle.recordInconclusiveLockedAttempt()
        guard decision != .ignored else {
            return
        }

        if decision == .recoveryContinues || decision == .terminal(.removeMarkerAndRetireResources) {
            stage = "lockWindowInconclusive"
            record("securitySentinelLockedAttempt", [
                "stage": "lockedAttempt",
                "protectedDataUnavailable": "unknown",
                "freshOpenAttempted": "false",
                "denied": "unknown",
                "denialClass": "inconclusive",
                "inconclusiveReason": reason,
            ])
        }
        lockWindowWatcher?.cancel()
        lockWindowWatcher = nil
        endBackgroundAssertion()
        if case let .terminal(action) = decision {
            performTerminalCleanup(action)
        }
    }

    /// Applies the sanitized cleanup action attached to a consumed terminal transition. Marker
    /// removal and resource retirement are both idempotent, so duplicate cleanup requests cannot
    /// re-arm the lifecycle or emit additional evidence.
    private func performTerminalCleanup(
        _ action: BrowserDownloadSecuritySentinelLifecycle.TerminalCleanupAction,
    ) {
        switch action {
        case .removeMarkerAndRetireResources:
            let result = BrowserDownloadSecuritySentinelTerminalCleanup.perform(
                removeMarker: removeMarker,
                retireResources: retireFinishedCycle,
            )
            if result == .markerRemovalFailed {
                recordTerminalMarkerCleanupFailure()
            }
        }
    }

    /// Runs on the real protected-data-available notification: repeats a fresh read, removes the
    /// marker, verifies absence, and reports the recovery fields the qualification test asserts.
    /// The contract accepts one recovery per cycle, so only the first delivery recovers; later
    /// duplicate deliveries, or any event that arrives after the cycle reached its terminal
    /// classification, return immediately so they cannot read again, alter cleanup state, or
    /// append a contradictory recovery observation for the qualification test.
    private func handleUnlock() {
        guard case let .accepted(requiresInconclusiveAttempt) = lifecycle.beginUnlockRecovery() else {
            return
        }

        // The operator can unlock before any gated locked read, either inside the lock window or
        // while suspension hid the lock notification entirely. Record the missing attempt as
        // INCONCLUSIVE before cancelling the watcher so the qualification test can report it,
        // then recover and clean up as usual.
        if requiresInconclusiveAttempt {
            finishLockWindowInconclusively(
                reason: lockWindowWatcher == nil ? "unlockedWithoutLockObservation" : "unlockedBeforeGatedRead",
            )
        }
        lockWindowWatcher?.cancel()
        lockWindowWatcher = nil
        var fields = [
            "stage": "unlockedRecovery",
            "protectedDataAvailable": String(UIApplication.shared.isProtectedDataAvailable),
        ]
        do {
            let bytes = try Data(contentsOf: Self.fileURL())
            fields["freshAccessSucceeded"] = String(bytes == Self.marker)
        } catch {
            fields["freshAccessSucceeded"] = "false"
            fields["accessErrorClass"] = Self.classify(error)
        }
        let markerRemoval = removeMarker()
        fields["sentinelRemoved"] = String(markerRemoval == .removed)
        fields["sentinelAbsent"] = String(!FileManager.default.fileExists(atPath: Self.rootURL().path))
        let recovered = fields["freshAccessSucceeded"] == "true" && fields["sentinelRemoved"] == "true"
        stage =
            if recovered {
                "completed"
            } else if markerRemoval == .failed {
                "terminalCleanupFailedRelaunchRequired"
            } else {
                "unlockFailed"
            }
        fields["stage"] = stage
        record("securitySentinelUnlockedRecovery", fields)
        lifecycle.finishUnlockRecovery(succeeded: recovered)
        retireFinishedCycle()
        if markerRemoval == .failed {
            recordTerminalMarkerCleanupFailure()
        }
    }

    /// Releases every resource the finished cycle still owns: the lock watcher, the bounded
    /// background assertion, and the protected-data observers. The terminal classification in the
    /// lifecycle is immutable, so this runs once per cycle and repeated deliveries remain no-ops;
    /// nothing here resets the lifecycle to allow another cycle in the same process.
    private func retireFinishedCycle() {
        lockWindowWatcher?.cancel()
        lockWindowWatcher = nil
        endBackgroundAssertion()
        removeProtectedDataObservers()
    }

    /// Unregisters the protected-data observers once the cycle can no longer receive meaningful
    /// notifications. Repeated calls are no-ops.
    private func removeProtectedDataObservers() {
        guard !observers.isEmpty else {
            return
        }

        let center = NotificationCenter.default
        for observer in observers {
            center.removeObserver(observer)
        }
        observers.removeAll()
    }

    /// Removes the isolated marker directory and returns a sanitized, path-free result.
    private func removeMarker() -> BrowserDownloadSecuritySentinelMarkerRemovalResult {
        let root = Self.rootURL()
        do {
            if FileManager.default.fileExists(atPath: root.path) {
                try FileManager.default.removeItem(at: root)
            }
        } catch {
            return .failed
        }
        return FileManager.default.fileExists(atPath: root.path) ? .failed : .removed
    }

    /// Records a terminal cleanup failure without exposing the marker location or file data.
    private func recordTerminalMarkerCleanupFailure() {
        stage = "terminalCleanupFailedRelaunchRequired"
        record("securitySentinelTerminalCleanupFailed", [
            "stage": "terminalCleanupFailed",
            "markerRemoved": "false",
            "relaunchRequired": "true",
        ])
    }

    /// Starts the bounded background assertion when none is active. On expiration the sentinel
    /// records an INCONCLUSIVE locked attempt when none was performed yet. A pre-lock expiration
    /// consumes the cycle and retires every resource. An expiration callback queued after a
    /// locked attempt is ignored and preserves observers so unlock recovery can still run.
    private func armBackgroundAssertion() {
        guard backgroundTask == .invalid else {
            return
        }

        backgroundTask = UIApplication.shared.beginBackgroundTask(
            withName: "BrowserDownloadSecuritySentinel",
        ) { [weak self] in
            Task { @MainActor in
                self?.finishLockWindowInconclusively(reason: "suspendedBeforeDenialAttempt")
            }
        }
    }

    /// Ends the background assertion if one is active; the process never holds it while idle.
    private func endBackgroundAssertion() {
        guard backgroundTask != .invalid else {
            return
        }

        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }

    /// Isolated location for the marker directory inside the app's Application Support folder.
    private static func rootURL() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(directoryName, isDirectory: true)
    }

    private static func fileURL() -> URL {
        rootURL().appendingPathComponent(fileName, isDirectory: false)
    }

    /// Creates the protected directory and marker the first time, re-applies .complete to both,
    /// and excludes both from backup; the marker is left in place for the lock window.
    private func createMarkerIfNeeded() throws -> URL {
        let files = FileManager.default
        let root = Self.rootURL()
        if !files.fileExists(atPath: root.path) {
            try files.createDirectory(
                at: root,
                withIntermediateDirectories: true,
                attributes: [.protectionKey: FileProtectionType.complete],
            )
        }
        try files.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: root.path)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableRoot = root
        try mutableRoot.setResourceValues(values)
        let file = Self.fileURL()
        if !files.fileExists(atPath: file.path) {
            try Self.marker.write(to: file, options: [.completeFileProtection, .atomic])
        }
        var mutableFile = file
        try mutableFile.setResourceValues(values)
        try files.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: file.path)
        return file
    }

    /// Reports the actual protection attribute using the vocabulary the qualification test
    /// asserts: "complete", "absent", or the raw attribute value for any unexpected mode.
    private func protectionDescription(of url: URL) throws -> String {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let protection = attributes[.protectionKey] as? FileProtectionType else {
            return "absent"
        }

        return protection == .complete ? "complete" : protection.rawValue
    }

    private func isExcludedFromBackup(_ url: URL) throws -> Bool {
        try url.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true
    }

    /// Opens the marker with a brand-new descriptor and compares contents without exposing them.
    private func readMarkerFreshly(from url: URL) throws -> Bool {
        let bytes = try Data(contentsOf: url)
        return bytes == Self.marker
    }

    /// Maps an error to a redacted classification. fileProtection covers the native denial a
    /// .complete file produces while protected data is unavailable.
    private static func classify(_ error: Error) -> String {
        let native = error as NSError
        let protectedCodes: Set<Int32> = [EPERM, EACCES]
        if native.domain == NSPOSIXErrorDomain, protectedCodes.contains(Int32(native.code)) {
            return "fileProtection"
        }
        if native.domain == NSCocoaErrorDomain,
           native.code == CocoaError.fileReadNoPermission.rawValue
           || native.code == CocoaError.fileWriteNoPermission.rawValue {
            return "fileProtection"
        }
        if let underlying = native.userInfo[NSUnderlyingErrorKey] as? NSError,
           underlying.domain == NSPOSIXErrorDomain,
           protectedCodes.contains(Int32(underlying.code)) {
            return "fileProtection"
        }
        if native.domain == NSCocoaErrorDomain,
           native.code == CocoaError.fileReadNoSuchFile.rawValue
           || native.code == CocoaError.fileNoSuchFile.rawValue {
            return "fileMissing"
        }
        return "unclassified"
    }
}

#endif
