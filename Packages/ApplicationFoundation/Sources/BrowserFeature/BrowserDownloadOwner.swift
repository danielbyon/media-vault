//
//  BrowserDownloadOwner.swift
//  MediaVault
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import MediaLibrary
import ObjectiveC
import UIKit
import UniformTypeIdentifiers

/// Writer lifetime seam. Production wraps the actual originating WKDownload; tests acknowledge
/// cancellation explicitly rather than pretending a cancellation request already stopped writing.
@MainActor
protocol BrowserDownloadTransfer: AnyObject {
    var identity: AnyObject { get }
    func cancel(completion: @escaping @MainActor () -> Void)
}

/// Owns native transfers, durable ingestion handoffs, and lightweight session download rows.
/// Cancellation retains the writer until terminal acknowledgement. Privacy generation revokes
/// content projections synchronously; continuing operations require a fresh grant before access.
@MainActor
final class BrowserDownloadOwner {
    static let shared = BrowserDownloadOwner(store: BrowserDownloadScratchStore(), ingestion: .live)

    /// Single-use transfer authority granted by an authenticated download policy decision.
    /// Privacy generation changes revoke content access without invalidating this capability.
    struct AdmissionToken: Equatable {
        fileprivate let ownerID: UUID
        fileprivate let generation: UInt64
        fileprivate let tabID: BrowserTabID
        fileprivate let tabLifetime: UUID
        fileprivate let profileLifetime: UUID
        fileprivate let originIdentity: ObjectIdentifier?
        fileprivate let reservationID: UUID
        fileprivate let operationID: BrowserDownloadID
        fileprivate let admittedRevision: UInt64
    }

    private let ownerID = UUID()
    private var profileLifetime = UUID()
    private var tabLifetimes: [BrowserTabID: UUID] = [:]

    @MainActor
    private final class Entry {
        let id: BrowserDownloadID
        let tabID: BrowserTabID
        let generation: UInt64
        let admittedRevision: UInt64
        weak var transferIdentity: AnyObject?
        var transfer: (any BrowserDownloadTransfer)?
        var allocation: BrowserDownloadAllocation?
        var writerStopped = false
        var revoked = false
        var cancellationRequested = false
        var isReady = false
        var receivedBytes: Int64 = 0
        var expectedBytes: Int64?
        var filename: String?
        var durablyAccepted = false
        var imported = false
        var status: BrowserDownloadRecord.Status = .downloading
        var acceptance: Task<Void, Never>?
        var discardRequested = false
        var completionVerified = false
        #if DEBUG
        var fileIdentityAtCompletion: BrowserDownloadScratchStore.OwnershipFileIdentity?
        #endif
        var acceptanceUncertain = false
        var acceptanceRejected = false
        var presentationFilename: String?

        init(
            id: BrowserDownloadID,
            tabID: BrowserTabID,
            generation: UInt64,
            revision: UInt64,
            transfer: any BrowserDownloadTransfer,
        ) {
            self.id = id
            self.tabID = tabID
            self.generation = generation
            admittedRevision = revision
            transferIdentity = transfer.identity
            self.transfer = transfer
        }
    }

    /// Native concealment runs synchronously before a presented source is revoked or deleted.
    var presentationWillRevoke: (@MainActor () -> Void)?

    #if DEBUG
    /// Optional path-free transfer evidence for the standalone qualification host.
    var qualificationTransferObservation: (@MainActor (String, [String: String]) -> Void)?

    /// Traces decisions for the HTTP fixture even if a callback reaches a detached tab context.
    var policyHandoffObservation: (@MainActor (String, UUID?, BrowserNavigationOperationID?) -> Void)?
    #endif

    private func recordTransfer(_ event: String, _ fields: [String: String]) {
        #if DEBUG
        qualificationTransferObservation?(event, fields)
        #endif
    }

    private func clearPresentationForRevocation() {
        if presentation != nil {
            presentationWillRevoke?()
        }
        presentation = nil
        cleanupPresentationExport(publishChanges: false)
    }

    private let store: BrowserDownloadScratchStore
    private let protectedDataAvailable: @MainActor () -> Bool
    private let backgroundExecution: BrowserDownloadBackgroundExecution
    private let ingestion: BrowserDownloadIngestion?
    private let availableBytes: @MainActor () -> Int64?
    private let copyPresentationFile: @MainActor (URL, URL) async throws -> Void
    private final class PresentationExport {
        let id: BrowserDownloadID
        let request: BrowserDownloadPresentation
        let allocation: BrowserDownloadAllocation
        let processingGeneration: UInt64
        var copying = true
        var handedToNative = false
        var absenceConfirmed = false
        var cleanupFailed = false

        init(
            id: BrowserDownloadID,
            request: BrowserDownloadPresentation,
            allocation: BrowserDownloadAllocation,
            processingGeneration: UInt64,
        ) {
            self.id = id
            self.request = request
            self.allocation = allocation
            self.processingGeneration = processingGeneration
        }
    }

    private var presentationExport: PresentationExport?
    private var reservations = BrowserDownloadReservations()
    private var acceptedStorage: AcceptedDownloadStorage?
    private var storageRevision: UInt64 = 0
    private var discarding: Set<BrowserDownloadID> = []
    private var protectedDataObserver: NSObjectProtocol?
    private var entries: [BrowserDownloadID: Entry] = [:]
    private var order: [BrowserDownloadID] = []
    private var rejected: [ObjectIdentifier: any BrowserDownloadTransfer] = [:]
    private var rejectedReservations: [ObjectIdentifier: UUID] = [:]
    private struct PendingAdmission {
        let token: AdmissionToken
        // Retains the exact original WebView while its policy-to-native handoff is pending.
        let origin: AnyObject?
        var cancelled = false
    }

    private var admissionReservations: [UUID: PendingAdmission] = [:]
    private var subscribers: [UUID: AsyncStream<BrowserDownloadSnapshot>.Continuation] = [:]
    private var authorization: @MainActor () -> Bool = { false }
    private var authorizationActive = false
    private var startupCleanupPending = true
    private var startupOwnershipRecovered = false
    private var cleanupFailures: Set<BrowserDownloadID> = []
    private var revision: UInt64 = 1
    private var generation: UInt64 = 0
    private var presentation: BrowserDownloadPresentation?
    private var notice: BrowserDownloadSnapshot.Notice?

    init(
        store: BrowserDownloadScratchStore,
        protectedDataAvailable: @escaping @MainActor () -> Bool = { UIApplication.shared.isProtectedDataAvailable },
        backgroundExecution: BrowserDownloadBackgroundExecution = .init(),
        ingestion: BrowserDownloadIngestion? = nil,
        availableBytes: (@MainActor () -> Int64?)? = nil,
        copyPresentationFile: @escaping @MainActor (URL, URL) async throws -> Void = { source, destination in
            try await Task.detached(priority: .utility) {
                try FileManager.default.copyItem(at: source, to: destination)
            }.value
        },
    ) {
        self.store = store
        self.protectedDataAvailable = protectedDataAvailable
        self.backgroundExecution = backgroundExecution
        self.ingestion = ingestion
        self.copyPresentationFile = copyPresentationFile
        self.availableBytes = availableBytes ?? {
            (try? FileManager.default.attributesOfFileSystem(forPath: store.root.path)[.systemFreeSize]) as? Int64
        }
        if ingestion == nil {
            acceptedStorage = .init(operationCount: 0, byteCount: 0)
            startupOwnershipRecovered = true
        }
        retryCleanup()
        protectedDataObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.protectedDataDidBecomeAvailableNotification,
            object: nil,
            queue: .main,
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.protectedDataBecameAvailable() }
        }
    }

    var activeCount: Int {
        entries.values.count(where: { !$0.writerStopped })
    }

    private var liveWriterCount: Int {
        activeCount + rejected.count + admissionReservations.count
    }

    var retainedCount: Int {
        entries.count
    }

    private var temporaryCount: Int {
        entries.values.count(where: { !$0.durablyAccepted && !$0.imported })
            + admissionReservations.count + (acceptedStorage?.operationCount ?? 8)
            + (presentationExport == nil ? 0 : 1)
    }

    private func reserveStorage(for id: BrowserDownloadID) -> Bool {
        guard !entries.values.contains(where: \.acceptanceUncertain),
              let acceptedStorage, temporaryCount < 8,
              reservations.reserve(
                  id.rawValue,
                  availableBytes: availableBytes(),
                  acceptedPendingBytes: acceptedStorage.byteCount,
              ) else {
            notice = .retainedRecordLimitReached
            publish()
            return false
        }

        return true
    }

    /// Revoked writers remain cleanup ownership until their terminal acknowledgement arrives.
    var privacyCleanupPending: Bool {
        startupCleanupPending || !cleanupFailures.isEmpty || entries.values.contains { $0.revoked }
            || presentationExport.map { $0.cleanupFailed || presentation != $0.request } == true
    }

    func presentationUnavailable(_ request: BrowserDownloadPresentation, discard: Bool) {
        guard presentation == request else {
            return
        }

        presentation = nil
        notice = discard ? .transferFailed : .previewUnavailable
        if discard {
            revoke(request.downloadID)
        } else {
            publish()
        }
        presentationDidEnd(request)
    }

    private var cleanupNeedsRetry: Bool {
        startupCleanupPending || !cleanupFailures.isEmpty || presentationExport?.cleanupFailed == true
    }

    var snapshot: BrowserDownloadSnapshot {
        var value = BrowserDownloadSnapshot()
        value.revision = revision
        value.generation = generation
        value.cleanupNeedsRetry = cleanupNeedsRetry
        value.isAvailable = authorizationActive && authorization() && !value.cleanupNeedsRetry
        value.notice = value.cleanupNeedsRetry ? .cleanupRequired : notice
        value.presentation = value.isAvailable ? presentation : nil
        value.records = order.compactMap { id in
            guard value.isAvailable, let entry = entries[id], !entry.revoked else {
                return nil
            }

            return BrowserDownloadRecord(
                id: id,
                tabID: entry.tabID,
                filename: entry.completionVerified ? entry.filename : nil,
                receivedBytes: entry.receivedBytes,
                expectedBytes: entry.expectedBytes,
                isReady: entry.isReady,
                status: entry.status,
            )
        }
        if value.isAvailable {
            for pending in admissionReservations.values where !pending.cancelled {
                value.records.append(BrowserDownloadRecord(
                    id: pending.token.operationID,
                    tabID: pending.token.tabID,
                    filename: nil,
                    receivedBytes: 0,
                    expectedBytes: nil,
                    isReady: false,
                ))
            }
            func admissionRevision(_ id: BrowserDownloadID) -> UInt64 {
                entries[id]?.admittedRevision
                    ?? admissionReservations.values.first { $0.token.operationID == id }?.token.admittedRevision
                    ?? 0
            }
            value.records.sort { admissionRevision($0.id) < admissionRevision($1.id) }
        }
        return value
    }

    /// Registers the subscription and initial reconciliation atomically in one main-actor turn.
    func subscribe() -> AsyncStream<BrowserDownloadSnapshot> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            subscribers[id] = continuation
            continuation.yield(snapshot)
            continuation.onTermination = { @Sendable [weak self] _ in
                Task { @MainActor in self?.subscribers.removeValue(forKey: id) }
            }
        }
    }

    func installAuthorization(_ predicate: @escaping @MainActor () -> Bool) {
        authorization = predicate
        recheckAuthorization()
    }

    /// The live predicate is evaluated at admission and presentation, not merely when SwiftUI renders.
    func recheckAuthorization() {
        guard authorization() else {
            if authorizationActive {
                invalidateAuthorization()
            }
            return
        }

        authorizationActive = true
        if notice == .unauthorized {
            notice = nil
        }
        retryCleanup()
        verifyPendingCompletions()
        Task { [weak self] in
            await self?.refreshIngestionStorage()
            await self?.reconcileIngestion()
        }
        publish()
    }

    func invalidateAuthorization() {
        authorizationActive = false
        generation &+= 1
        clearPresentationForRevocation()
        notice = .unauthorized
        // Existing policy capabilities and writers retain transfer authority, never content access.
        publish()
    }

    /// Duplicate native callbacks cannot replace a retained writer's delegate or observations.
    func owns(_ identity: AnyObject) -> Bool {
        entries.values.contains { $0.transferIdentity === identity }
            || rejected[ObjectIdentifier(identity)] != nil
    }

    /// Captures only live authorization, independently of navigation correlation and capacity.
    /// Reserves a live-writer slot before WebKit turns a navigation into a native download. An
    /// unauthorized or over-capacity policy is denied before WebKit creates a writer.
    func captureAdmissionToken(
        for tabID: BrowserTabID,
        originatingWebView: AnyObject? = nil,
    ) -> AdmissionToken? {
        recheckAuthorization()
        guard authorizationActive, authorization() else {
            notice = .unauthorized
            publish()
            return nil
        }
        guard liveWriterCount < 4 else {
            notice = .activeTransferLimitReached
            publish()
            return nil
        }
        guard !snapshot.cleanupNeedsRetry else {
            notice = .cleanupRequired
            publish()
            return nil
        }
        guard temporaryCount < 8 else {
            notice = .retainedRecordLimitReached
            publish()
            return nil
        }

        let lifetime = tabLifetimes[tabID] ?? UUID()
        tabLifetimes[tabID] = lifetime
        let reservationID = UUID()
        let operationID = BrowserDownloadID()
        guard reserveStorage(for: operationID) else {
            return nil
        }

        let token = AdmissionToken(
            ownerID: ownerID,
            generation: generation,
            tabID: tabID,
            tabLifetime: lifetime,
            profileLifetime: profileLifetime,
            originIdentity: originatingWebView.map(ObjectIdentifier.init),
            reservationID: reservationID,
            operationID: operationID,
            admittedRevision: revision,
        )
        admissionReservations[reservationID] = PendingAdmission(token: token, origin: originatingWebView)
        recordTransfer("policyDownloadAdmitted", [
            "capability": reservationID.uuidString,
            "operation": token.operationID.rawValue.uuidString,
        ])
        publish()
        return token
    }

    /// Releases a policy-time slot when WebKit abandons its conversion before handing off a writer.
    func releaseAdmissionReservation(_ token: AdmissionToken?) {
        guard let token, token.ownerID == ownerID else {
            return
        }

        if admissionReservations[token.reservationID]?.token == token {
            admissionReservations.removeValue(forKey: token.reservationID)
            reservations.release(token.operationID.rawValue)
            publish()
        }
    }

    /// Consumes only the exact policy capability; current content authorization is independent.
    /// A native writer arriving after Lock remains admitted to its original tab/profile lifetime.
    func admit(
        _ transfer: any BrowserDownloadTransfer,
        tabID: BrowserTabID,
        using token: AdmissionToken?,
        originatingWebView: AnyObject? = nil,
    ) -> BrowserDownloadID? {
        if let existing = entries.values.first(where: { $0.transferIdentity === transfer.identity }) {
            return existing.id
        }
        guard let token,
              token.ownerID == ownerID,
              admissionReservations[token.reservationID]?.token == token,
              token.tabID == tabID, tabLifetimes[tabID] == token.tabLifetime,
              token.profileLifetime == profileLifetime,
              token.originIdentity == originatingWebView.map(ObjectIdentifier.init)
        else {
            reject(transfer, notice: nil)
            return nil
        }

        let pending = admissionReservations.removeValue(forKey: token.reservationID)
        guard pending?.cancelled == false else {
            rejectedReservations[ObjectIdentifier(transfer.identity)] = token.operationID.rawValue
            reject(transfer, notice: nil, operationID: token.operationID, reason: "pendingCancellation")
            return nil
        }

        return register(
            transfer,
            tabID: tabID,
            capabilityID: token.reservationID,
            operationID: token.operationID,
            admittedRevision: token.admittedRevision,
        )
    }

    /// Admission occurs only after the adapter proves originating surface identity. Excess writers
    /// are cancelled without allocating scratch and without changing navigation settlement.
    func admit(_ transfer: any BrowserDownloadTransfer, tabID: BrowserTabID) -> BrowserDownloadID? {
        let identity = ObjectIdentifier(transfer.identity)
        if let existing = entries.values
            .first(where: { $0.transferIdentity === transfer.identity }) {
            return existing.id
        }
        guard rejected[identity] == nil else {
            return nil
        }

        recheckAuthorization()
        guard authorizationActive, authorization() else {
            reject(transfer, notice: .unauthorized)
            return nil
        }
        guard !snapshot.cleanupNeedsRetry else {
            reject(transfer, notice: .cleanupRequired)
            return nil
        }
        guard liveWriterCount < 4 else {
            reject(transfer, notice: .activeTransferLimitReached)
            return nil
        }
        guard temporaryCount < 8 else {
            reject(transfer, notice: .retainedRecordLimitReached)
            return nil
        }

        let id = BrowserDownloadID()
        guard reserveStorage(for: id) else {
            reject(transfer, notice: .retainedRecordLimitReached)
            return nil
        }

        return register(transfer, tabID: tabID, operationID: id)
    }

    private func register(
        _ transfer: any BrowserDownloadTransfer,
        tabID: BrowserTabID,
        capabilityID: UUID? = nil,
        operationID: BrowserDownloadID? = nil,
        admittedRevision: UInt64? = nil,
    ) -> BrowserDownloadID {
        let id = operationID ?? BrowserDownloadID()
        entries[id] = Entry(
            id: id,
            tabID: tabID,
            generation: generation,
            revision: admittedRevision ?? revision,
            transfer: transfer,
        )
        order.append(id)
        recordTransfer("transferAdmitted", [
            "operation": id.rawValue.uuidString,
            "capability": capabilityID?.uuidString ?? "unavailable",
        ])
        notice = nil
        publish()
        return id
    }

    /// Retains a rejected native writer until cancellation acknowledges termination; no resume data
    /// or destination is retained. Duplicate handoffs cannot cancel an already-owned transfer.
    func reject(
        _ transfer: any BrowserDownloadTransfer,
        notice: BrowserDownloadSnapshot.Notice?,
        operationID: BrowserDownloadID? = nil,
        reason: String = "rejectedPolicyOrOrigin",
    ) {
        let identity = ObjectIdentifier(transfer.identity)
        guard !entries.values.contains(where: { $0.transferIdentity === transfer.identity }),
              rejected[identity] == nil
        else {
            return
        }

        rejected[identity] = transfer
        if let notice {
            self.notice = notice
        }
        publish()
        recordTransfer("nativeCancellationRequested", [
            "operation": operationID?.rawValue.uuidString ?? "none",
            "reason": reason,
        ])
        transfer.cancel { [weak self, weak transfer] in
            if let transfer {
                self?.rejectedTerminated(transfer.identity)
            }
        }
    }

    /// A terminal delegate callback also proves a rejected writer stopped, even if its cancel
    /// completion arrives later. Identity comparison prevents removing unrelated ownership.
    func rejectedTerminated(_ identity: AnyObject) {
        let key = ObjectIdentifier(identity)
        guard rejected[key]?.identity === identity else {
            return
        }

        rejected.removeValue(forKey: key)
        if let reservation = rejectedReservations.removeValue(forKey: key) {
            reservations.release(reservation)
        }
        publish()
    }

    /// Supplies only an uncreated leaf in a verified protected operation directory.
    func destination(for id: BrowserDownloadID, suggestedName: String, expectedLength: Int64? = nil) -> URL? {
        guard let active = entries[id], !active.revoked else {
            return nil
        }
        guard let entry = entries[id], entry.allocation == nil, !entry.writerStopped else {
            return nil
        }

        if let expectedLength, expectedLength > BrowserDownloadReservations.itemLimit {
            notice = .transferFailed
            revoke(id)
            return nil
        }

        let allocation = store.allocation(id: id, suggestedName: suggestedName)
        entry.allocation = allocation
        entry.filename = allocation.destination.lastPathComponent
        do {
            try store.prepare(allocation)
            #if DEBUG
            policyHandoffObservation?("destination.prepared", nil, nil)
            #endif
            return allocation.destination
        } catch {
            #if DEBUG
            store.reportQualificationFailure(error, phase: "preparation", allocation: allocation)
            #endif
            notice = .transferFailed
            revoke(id)
            return nil
        }
    }

    /// Progress is monotonic and never advertises partial bytes as presentable content.
    func progress(id: BrowserDownloadID, completed: Int64, total: Int64?) {
        guard let entry = entries[id], !entry.writerStopped else {
            return
        }

        let received = max(entry.receivedBytes, max(0, completed))
        let expected = total.flatMap { $0 > 0 ? max($0, received) : nil }
        guard received != entry.receivedBytes || expected != entry.expectedBytes else {
            return
        }

        entry.receivedBytes = received
        entry.expectedBytes = expected
        let withinReservation = reservations.observe(id.rawValue, receivedBytes: received)
        guard !entry.revoked else {
            return
        }

        if !withinReservation
            || (expected ?? 0) > BrowserDownloadReservations.itemLimit {
            notice = .transferFailed
            revoke(id)
            return
        }
        publish()
    }

    /// didFinish proves the writer stopped, but publication additionally requires actual file checks.
    func finished(_ id: BrowserDownloadID) {
        guard let entry = entries[id], !entry.writerStopped else {
            return
        }

        entry.writerStopped = true
        entry.transfer = nil
        recordTransfer("writerFinished", ["operation": id.rawValue.uuidString])
        guard !entry.revoked, entry.allocation != nil else {
            revoke(id)
            return
        }

        verifyCompletion(id)
        publish()
    }

    /// File protection may prevent verification while locked. Such completions stay inaccessible.
    private func verifyCompletion(_ id: BrowserDownloadID) {
        guard let entry = entries[id], entry.writerStopped, !entry.revoked || entry.acceptanceUncertain,
              !entry.isReady, !entry.durablyAccepted, !entry.acceptanceRejected, entry.acceptance == nil,
              let allocation = entry.allocation,
              protectedDataAvailable() else {
            return
        }

        if entry.completionVerified {
            acceptVerifiedCompletion(entry)
            return
        }

        do {
            #if DEBUG
            var allocation = allocation
            allocation.recordVerifiedIdentity = { entry.fileIdentityAtCompletion = $0 }
            #endif
            entry.receivedBytes = try store.verifyCompleted(allocation)
            guard entry.receivedBytes <= BrowserDownloadReservations.itemLimit else {
                notice = .transferFailed
                revoke(id)
                return
            }

            reservations.completed(id.rawValue, byteCount: entry.receivedBytes)
            entry.completionVerified = true
            entry.isReady = ingestion == nil
            if ingestion != nil {
                entry.status = .pendingImport
                acceptVerifiedCompletion(entry)
            }
            publish()
        } catch {
            guard protectedDataAvailable() else {
                return
            }

            #if DEBUG
            store.reportQualificationFailure(error, phase: "completion", allocation: allocation)
            #endif
            notice = .transferFailed
            revoke(id)
        }
    }

    private func verifyPendingCompletions() {
        for id in Array(entries.keys) {
            verifyCompletion(id)
        }
    }

    /// Protected-data availability permits terminal file verification and adoption, never validation.
    func protectedDataBecameAvailable() {
        retryCleanup()
        verifyPendingCompletions()
        Task { [weak self] in
            await self?.refreshIngestionStorage()
            await self?.reconcileIngestion()
        }
    }

    /// A stale storage result cannot replace usage changed by a concurrent handoff or discard.
    func refreshIngestionStorage() async {
        guard let ingestion, protectedDataAvailable(),
              !entries.values.contains(where: { $0.acceptance != nil || $0.acceptanceUncertain }),
              discarding.isEmpty else {
            return
        }

        let expectedRevision = storageRevision
        do {
            let usage = try await ingestion.storage()
            guard storageRevision == expectedRevision, protectedDataAvailable(),
                  usage.operationCount >= 0, usage.byteCount >= 0,
                  !entries.values.contains(where: { $0.acceptance != nil }), discarding.isEmpty else {
                return
            }

            acceptedStorage = usage
            // Shared storage recovery finishes interrupted journal handoffs before scratch
            // ownership is known. Only the remaining unowned native files may be purged.
            startupOwnershipRecovered = true
            if startupCleanupPending {
                retryCleanup()
            }
        } catch {
            if storageRevision == expectedRevision {
                acceptedStorage = nil
            }
        }
        publish()
    }

    private func acceptVerifiedCompletion(_ entry: Entry) {
        guard let ingestion, let allocation = entry.allocation, entry.acceptance == nil,
              !entry.durablyAccepted, !entry.revoked || entry.acceptanceUncertain,
              protectedDataAvailable() else {
            return
        }

        storageRevision &+= 1
        entry.acceptance = Task { [weak self, weak entry] in
            guard let self, let entry else {
                return
            }

            do {
                try await ingestion.accept(allocation.destination, entry.id.rawValue, entry.filename ?? "download")
                entry.durablyAccepted = true
                // An accepted operation keeps its session row across tab/profile changes.
                entry.revoked = entry.discardRequested
                entry.acceptanceUncertain = false
                entry.acceptance = nil
                reservations.release(entry.id.rawValue)
                storageRevision &+= 1
                if let usage = acceptedStorage {
                    acceptedStorage = .init(
                        operationCount: usage.operationCount + 1,
                        byteCount: usage.byteCount + entry.receivedBytes,
                    )
                }
                do {
                    try store.cleanup(allocation)
                    entry.allocation = nil
                } catch {
                    cleanupFailures.insert(entry.id)
                }
                if entry.discardRequested {
                    cleanupFailures.insert(entry.id)
                    discardAccepted(entry)
                }
            } catch {
                acceptanceFailed(entry, error: error)
            }
            publish()
            Task { [weak self] in
                await self?.refreshIngestionStorage()
                await self?.reconcileIngestion()
            }
        }
    }

    private func acceptanceFailed(_ entry: Entry, error: Error) {
        entry.acceptance = nil
        notice = .transferFailed
        if let rejection = error as? CompletedDownloadAcceptanceError, rejection.isDefiniteRejection {
            entry.acceptanceRejected = true
            entry.acceptanceUncertain = false
            entry.status = .failed
            // The source remains an ordinary verified browser file, charged until cleanup.
            if entry.revoked {
                cleanupStopped(entry.id)
            }
        } else {
            // A journal intent or move may already exist. Retain both bytes and reservation
            // until an idempotent retry establishes shared ownership.
            entry.acceptanceUncertain = true
            acceptedStorage = nil
        }
    }

    /// Reconciliation uses the existing authenticated session; browser work never grants one.
    func reconcileIngestion() async {
        for entry in Array(entries.values) {
            await entry.acceptance?.value
        }
        guard let ingestion, authorizationActive, authorization(), protectedDataAvailable() else {
            return
        }

        let expectedGeneration = generation
        let processingGeneration = ingestion.generation()
        let outcomes = await ingestion.reconcile(processingGeneration)
        guard authorizationActive, authorization(), generation == expectedGeneration,
              ingestion.generation() == processingGeneration else {
            return
        }

        for (operationID, outcome) in outcomes {
            guard let entry = entries.values.first(where: { $0.id.rawValue == operationID }),
                  entry.durablyAccepted, !entry.revoked else {
                continue
            }

            switch outcome {
            case .pending:
                entry.status = .pendingImport
                entry.isReady = false
            case let .imported(asset, duplicate):
                entry.imported = true
                entry.status = duplicate ? .duplicate : .imported
                entry.isReady = true
                if let resource = asset.resources.first,
                   let suffix = UTType(resource.sourceUTI)?.preferredFilenameExtension {
                    let stem = URL(fileURLWithPath: entry.filename ?? "download")
                        .deletingPathExtension()
                        .lastPathComponent
                        .prefix(64)
                    entry.presentationFilename = "\(stem).\(suffix)"
                }
            case .unsupported:
                entry.status = .unsupported
                entry.isReady = true
            case .failed:
                entry.status = .failed
                entry.isReady = false
            }
        }
        await refreshIngestionStorage()
        publish()
    }

    private func discardAccepted(_ entry: Entry) {
        guard let ingestion, !entry.imported, authorizationActive, authorization(),
              protectedDataAvailable(), discarding.insert(entry.id).inserted else {
            return
        }

        let expectedGeneration = generation
        let processingGeneration = ingestion.generation()
        storageRevision &+= 1
        Task { [weak self, weak entry] in
            guard let self, let entry else {
                return
            }

            defer { discarding.remove(entry.id) }
            guard authorizationActive, authorization(), generation == expectedGeneration,
                  ingestion.generation() == processingGeneration else {
                return
            }

            do {
                try await ingestion.discard(entry.id.rawValue)
                discarding.remove(entry.id)
                cleanupStopped(entry.id)
                storageRevision &+= 1
                discarding.remove(entry.id)
                await refreshIngestionStorage()
            } catch {
                cleanupFailures.insert(entry.id)
                notice = .cleanupRequired
            }
            publish()
        }
    }

    private func requestExplicitDiscard(_ entry: Entry) {
        entry.discardRequested = true
        guard !entry.imported,
              entry.durablyAccepted || entry.acceptance != nil || entry.acceptanceUncertain else {
            return
        }

        ingestion?.revoke(entry.id.rawValue)
    }

    /// Failure and cancellation acknowledgement are terminal even when delivered more than once.
    func failed(_ id: BrowserDownloadID, error: Error? = nil) {
        var fields = ["operation": id.rawValue.uuidString]
        if let error {
            let native = error as NSError
            fields["errorDomain"] = native.domain
            fields["errorCode"] = String(native.code)
        }
        stopWriter(id, event: "writerFailed", fields: fields)
    }

    private func cancellationAcknowledged(_ id: BrowserDownloadID) {
        stopWriter(id, event: "writerCancellationAcknowledged", fields: ["operation": id.rawValue.uuidString])
    }

    private func stopWriter(_ id: BrowserDownloadID, event: String, fields: [String: String]) {
        guard let entry = entries[id], !entry.writerStopped else {
            return
        }

        entry.writerStopped = true
        entry.transfer = nil
        recordTransfer(event, fields)
        notice = entry.revoked ? notice : .transferFailed
        revoke(id)
    }

    func revokeTab(_ tabID: BrowserTabID) {
        tabLifetimes.removeValue(forKey: tabID)
        for pending in admissionReservations.values where pending.token.tabID == tabID {
            reservations.release(pending.token.operationID.rawValue)
        }
        admissionReservations = admissionReservations.filter { $0.value.token.tabID != tabID }
        let affected = entries.values.filter { $0.tabID == tabID }
        if affected.contains(where: { $0.durablyAccepted || $0.acceptance != nil || $0.acceptanceUncertain }) {
            generation &+= 1
            clearPresentationForRevocation()
        }
        for entry in affected where !entry.durablyAccepted {
            revoke(entry.id)
        }
        publish()
    }

    /// Profile changes revoke unaccepted transfers and grants while retaining accepted session rows.
    func revokeAll() {
        profileLifetime = UUID()
        for pending in admissionReservations.values {
            reservations.release(pending.token.operationID.rawValue)
        }
        admissionReservations.removeAll()
        tabLifetimes.removeAll()
        generation &+= 1
        clearPresentationForRevocation()
        for entry in entries.values where !entry.durablyAccepted {
            entry.revoked = true
        }
        publish()
        for id in entries.values.filter({ !$0.durablyAccepted }).map(\.id) {
            revoke(id)
        }
    }

    func execute(_ command: BrowserDownloadCommand) {
        guard command.generation == generation, command.revision <= revision else {
            return
        }

        if case .retryCleanup = command.action {
            retryCleanup()
            return
        }
        guard authorizationActive, authorization() else {
            return
        }

        switch command.action {
        case let .cancel(id),
             let .discard(id):
            if let pendingID = admissionReservations.first(where: {
                $0.value.token.operationID == id && command.revision >= $0.value.token.admittedRevision
            })?.key {
                admissionReservations[pendingID]?.cancelled = true
                recordTransfer("pendingTransferCancelled", ["operation": id.rawValue.uuidString])
                publish()
                return
            }
            guard let entry = entries[id], command.revision >= entry.admittedRevision else {
                return
            }

            if case .cancel = command.action,
               entry.durablyAccepted || entry.acceptance != nil || entry.acceptanceUncertain {
                return
            }
            if case .discard = command.action {
                requestExplicitDiscard(entry)
            }
            if entry.durablyAccepted, !entry.imported {
                entry.revoked = true
                cleanupFailures.insert(id)
                clearPresentationForRevocation()
                discardAccepted(entry)
                publish()
                return
            }
            revoke(id)
        case .retryCleanup:
            retryCleanup()
        case let .present(id, kind):
            guard presentation == nil, let entry = currentEntry(id), entry.isReady else {
                return
            }

            presentation = .init(requestID: UUID(), downloadID: id, generation: generation, kind: kind)
            publish()
        case let .dismissPresentation(requestID):
            guard presentation?.requestID == requestID else {
                return
            }

            presentation = nil
            cleanupPresentationExport(publishChanges: false)
            publish()
        }
    }

    /// A later native coordinator resolves an exact request synchronously. Paths stay outside state.
    func presentationURL(for request: BrowserDownloadPresentation) -> URL? {
        guard presentation == request, request.generation == generation,
              let entry = currentEntry(request.downloadID), entry.isReady, let allocation = entry.allocation
        else {
            return nil
        }

        do {
            _ = try store.verifyCompleted(allocation)
            return allocation.destination
        } catch {
            revoke(entry.id)
            return nil
        }
    }

    /// Durable resources are copied only for a currently authorized native presentation.
    /// The protected, correctly named export leaves shared ownership unchanged.
    func resolvePresentationURL(for request: BrowserDownloadPresentation) async -> URL? {
        guard let entry = presentationEntry(request) else {
            return nil
        }
        guard entry.durablyAccepted else {
            return presentationURL(for: request)
        }
        guard let ingestion else {
            return nil
        }

        if let lease = presentationExport {
            guard lease.request == request, !lease.copying, !lease.absenceConfirmed,
                  lease.processingGeneration == ingestion.generation() else {
                return nil
            }

            return lease.allocation.destination
        }
        let processingGeneration = ingestion.generation()
        guard let source = try? await ingestion.presentationURL(entry.id.rawValue, processingGeneration),
              presentationEntry(request) === entry, ingestion.generation() == processingGeneration,
              presentationExport == nil else {
            return nil
        }

        return await createPresentationExport(
            from: source,
            entry: entry,
            request: request,
            processingGeneration: processingGeneration,
        )
    }

    private func presentationEntry(_ request: BrowserDownloadPresentation) -> Entry? {
        guard presentation == request, request.generation == generation,
              let entry = currentEntry(request.downloadID), entry.isReady,
              protectedDataAvailable() else {
            return nil
        }

        return entry
    }

    private func reservePresentationExport(_ entry: Entry) -> BrowserDownloadID? {
        guard let acceptedStorage, temporaryCount < 8 else {
            return nil
        }

        let id = BrowserDownloadID()
        guard reservations.reserve(
            id.rawValue,
            availableBytes: availableBytes(),
            acceptedPendingBytes: acceptedStorage.byteCount,
            requestedBytes: entry.receivedBytes,
        ) else {
            notice = .retainedRecordLimitReached
            publish()
            return nil
        }

        return id
    }

    private func createPresentationExport(
        from source: URL,
        entry: Entry,
        request: BrowserDownloadPresentation,
        processingGeneration: UInt64,
    ) async -> URL? {
        guard let id = reservePresentationExport(entry) else {
            return nil
        }

        let allocation = store.allocation(
            id: id,
            suggestedName: entry.presentationFilename ?? entry.filename ?? "download",
        )
        let lease = PresentationExport(
            id: id,
            request: request,
            allocation: allocation,
            processingGeneration: processingGeneration,
        )
        presentationExport = lease
        publish()
        do {
            try store.prepare(allocation)
            try await copyPresentationFile(source, allocation.destination)
            lease.copying = false
            let byteCount = try store.verifyCompleted(allocation)
            let withinLimit = reservations.observe(id.rawValue, receivedBytes: byteCount)
            guard withinLimit, byteCount == entry.receivedBytes else {
                throw BrowserDownloadScratchStore.Failure.unsafeFile
            }

            reservations.completed(id.rawValue, byteCount: byteCount)
            guard presentationEntry(request) === entry, !lease.absenceConfirmed,
                  ingestion?.generation() == processingGeneration else {
                presentationDidEnd(request)
                return nil
            }

            publish()
            return allocation.destination
        } catch {
            lease.copying = false
            notice = .previewUnavailable
            presentationDidEnd(request)
            return nil
        }
    }

    func presentationIsWaitingForExport(_ request: BrowserDownloadPresentation) -> Bool {
        presentationExport.map { $0.request != request } == true
    }

    /// Acquires one resolved export in the same actor turn as native presentation.
    /// Resolution alone does not require retaining a revoked export until native absence.
    func presentationWillBegin(_ request: BrowserDownloadPresentation) -> Bool {
        guard let entry = presentationEntry(request) else {
            return false
        }
        guard entry.durablyAccepted else {
            return true
        }
        guard let lease = presentationExport, lease.request == request,
              !lease.copying, !lease.absenceConfirmed, !lease.handedToNative,
              lease.processingGeneration == ingestion?.generation() else {
            return false
        }

        lease.handedToNative = true
        return true
    }

    /// Called after native absence is confirmed, or when no native controller acquired the URL.
    /// A revoked request can release only its own export; it cannot restore presentation access.
    func presentationDidEnd(_ request: BrowserDownloadPresentation) {
        if presentation == request {
            presentation = nil
        }
        guard let lease = presentationExport, lease.request == request else {
            publish()
            return
        }

        lease.absenceConfirmed = true
        cleanupPresentationExport()
    }

    private func cleanupPresentationExport(publishChanges: Bool = true) {
        guard let lease = presentationExport, !lease.copying,
              lease.absenceConfirmed || (!lease.handedToNative && presentation != lease.request) else {
            return
        }

        do {
            try store.cleanup(lease.allocation)
            reservations.release(lease.id.rawValue)
            presentationExport = nil
        } catch {
            lease.cleanupFailed = true
            notice = .cleanupRequired
        }
        if publishChanges {
            publish()
        }
    }

    #if DEBUG
    enum CompletedFileInspectionError: Error, Equatable {
        case unauthorized
        case unavailable
    }

    /// Checks a finished download under the current grant. A failed check leaves the entry,
    /// its presentation, and the file's existing attributes intact.
    func inspectCompletedFile(_ id: BrowserDownloadID) throws -> URL {
        guard authorizationActive, authorization() else {
            throw CompletedFileInspectionError.unauthorized
        }
        guard protectedDataAvailable(), !cleanupNeedsRetry, let entry = entries[id],
              !entry.revoked, entry.isReady, entry.writerStopped,
              let allocation = entry.allocation, let identity = entry.fileIdentityAtCompletion else {
            throw CompletedFileInspectionError.unavailable
        }

        try store.inspectCompleted(allocation, expectedBytes: entry.receivedBytes, verifiedIdentity: identity)
        return allocation.destination
    }

    /// The qualification host receives `unsafeFile` for an ineligible entry.
    /// Filesystem errors retain their original type.
    func qualificationCompletedFile(_ id: BrowserDownloadID) throws -> URL {
        do {
            return try inspectCompletedFile(id)
        } catch is CompletedFileInspectionError {
            throw BrowserDownloadScratchStore.Failure.unsafeFile
        }
    }
    #endif

    /// Retries only stopped writers' cleanup. Active cancellation ownership remains in place.
    func retryCleanup() {
        if startupCleanupPending {
            guard ingestion == nil || protectedDataAvailable() else {
                notice = .cleanupRequired
                publish()
                return
            }
            guard startupOwnershipRecovered else {
                notice = .cleanupRequired
                publish()
                Task { [weak self] in await self?.refreshIngestionStorage() }
                return
            }

            do {
                try store.purgePreviousProcess()
                startupCleanupPending = false
            } catch {
                notice = .cleanupRequired
            }
        }
        cleanupPresentationExport()
        for id in Array(cleanupFailures) {
            if let entry = entries[id], entry.durablyAccepted, entry.discardRequested, !entry.imported {
                discardAccepted(entry)
            } else {
                cleanupStopped(id)
            }
        }
        if !startupCleanupPending, cleanupFailures.isEmpty, presentationExport?.cleanupFailed != true,
           notice == .cleanupRequired {
            notice = nil
        }
        publish()
    }

    private func currentEntry(_ id: BrowserDownloadID) -> Entry? {
        guard authorizationActive, authorization() else {
            if authorizationActive {
                invalidateAuthorization()
            }
            return nil
        }
        guard !snapshot.cleanupNeedsRetry, let entry = entries[id], !entry.revoked
        else {
            return nil
        }

        return entry
    }

    private func revoke(_ id: BrowserDownloadID) {
        guard let entry = entries[id] else {
            return
        }

        entry.revoked = true
        entry.isReady = false
        if presentation?.downloadID == id {
            clearPresentationForRevocation()
        }
        publish()
        if entry.acceptance != nil || entry.acceptanceUncertain {
            return
        }
        if entry.writerStopped {
            cleanupStopped(id)
        } else if !entry.cancellationRequested, let transfer = entry.transfer {
            entry.cancellationRequested = true
            recordTransfer("nativeCancellationRequested", [
                "operation": id.rawValue.uuidString,
                "reason": "explicitTerminalBoundary",
            ])
            transfer.cancel { [weak self] in self?.cancellationAcknowledged(id) }
        }
    }

    private func cleanupStopped(_ id: BrowserDownloadID) {
        guard let entry = entries[id], entry.writerStopped,
              entry.revoked || entry.durablyAccepted,
              entry.acceptance == nil, !entry.acceptanceUncertain,
              !discarding.contains(id) else {
            return
        }

        do {
            if let allocation = entry.allocation {
                try store.cleanup(allocation)
                entry.allocation = nil
            }
            if entry.revoked {
                reservations.release(id.rawValue)
                entries.removeValue(forKey: id)
                order.removeAll { $0 == id }
            }
            cleanupFailures.remove(id)
        } catch {
            #if DEBUG
            if let allocation = entry.allocation {
                store.reportQualificationFailure(error, phase: "cleanup", allocation: allocation)
            }
            #endif
            cleanupFailures.insert(id)
            notice = .cleanupRequired
        }
        publish()
    }

    private func publish() {
        // Native completion can precede the durable handoff's acknowledgement.
        backgroundExecution.update(hasWork: liveWriterCount > 0 || presentationExport?.copying == true
            || entries.values.contains(where: { $0.acceptance != nil }))
        revision &+= 1
        let value = snapshot
        for continuation in subscribers.values {
            continuation.yield(value)
        }
    }
}
