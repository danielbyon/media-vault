//
//  BrowserDownloadOwner.swift
//  MediaVault
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

/// Writer lifetime seam. Production wraps the actual originating WKDownload; tests acknowledge
/// cancellation explicitly rather than pretending a cancellation request already stopped writing.
@MainActor
protocol BrowserDownloadTransfer: AnyObject {
    var identity: AnyObject { get }
    func cancel(completion: @escaping @MainActor () -> Void)
}

/// Main-actor owner of bounded transient transfers, completed bytes, and opaque cleanup recovery.
/// Cancellation retains the writer until terminal acknowledgement. Privacy generation revokes
/// projections synchronously and never permits old operations to join a newly authorized session.
@MainActor
final class BrowserDownloadOwner {
    static let shared = BrowserDownloadOwner(store: BrowserDownloadScratchStore())

    /// Policy-time ownership evidence. A tab replacement or privacy generation change invalidates
    /// this capability even if the session becomes authorized again before WebKit hands off bytes.
    /// The reservation occupies one live-writer slot until handoff or explicit release.
    struct AdmissionToken: Equatable {
        fileprivate let ownerID: UUID
        fileprivate let generation: UInt64
        fileprivate let tabID: BrowserTabID
        fileprivate let tabLifetime: UUID
        fileprivate let reservationID: UUID
    }

    private let ownerID = UUID()
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

    private func clearPresentationForRevocation() {
        if presentation != nil {
            presentationWillRevoke?()
        }
        presentation = nil
    }

    private let store: BrowserDownloadScratchStore
    private var entries: [BrowserDownloadID: Entry] = [:]
    private var order: [BrowserDownloadID] = []
    private var rejected: [ObjectIdentifier: any BrowserDownloadTransfer] = [:]
    private var admissionReservations: Set<UUID> = []
    private var subscribers: [UUID: AsyncStream<BrowserDownloadSnapshot>.Continuation] = [:]
    private var authorization: @MainActor () -> Bool = { false }
    private var authorizationActive = false
    private var startupCleanupPending = true
    private var cleanupFailures: Set<BrowserDownloadID> = []
    private var revision: UInt64 = 1
    private var generation: UInt64 = 0
    private var presentation: BrowserDownloadPresentation?
    private var notice: BrowserDownloadSnapshot.Notice?

    init(store: BrowserDownloadScratchStore) {
        self.store = store
        retryCleanup()
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

    /// Revoked writers remain cleanup ownership until their terminal acknowledgement arrives.
    var privacyCleanupPending: Bool {
        startupCleanupPending || !cleanupFailures.isEmpty || entries.values.contains { $0.revoked }
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
    }

    var snapshot: BrowserDownloadSnapshot {
        var value = BrowserDownloadSnapshot()
        value.revision = revision
        value.generation = generation
        value.cleanupNeedsRetry = startupCleanupPending || !cleanupFailures.isEmpty
        value.isAvailable = authorizationActive && authorization() && !value.cleanupNeedsRetry
        value.notice = value.cleanupNeedsRetry ? .cleanupRequired : notice
        value.presentation = presentation
        value.records = order.compactMap { id in
            guard let entry = entries[id], !entry.revoked else {
                return nil
            }

            return BrowserDownloadRecord(
                id: id,
                tabID: entry.tabID,
                filename: entry.isReady ? entry.allocation?.destination.lastPathComponent : nil,
                receivedBytes: entry.receivedBytes,
                expectedBytes: entry.expectedBytes,
                isReady: entry.isReady,
            )
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
        publish()
    }

    func invalidateAuthorization() {
        tabLifetimes.removeAll()
        authorizationActive = false
        generation &+= 1
        clearPresentationForRevocation()
        notice = .unauthorized
        // Publish concealment before cancellation can call back synchronously.
        for entry in entries.values {
            entry.revoked = true
        }
        publish()
        for id in Array(entries.keys) {
            revoke(id)
        }
    }

    /// Duplicate native callbacks cannot replace a retained writer's delegate or observations.
    func owns(_ identity: AnyObject) -> Bool {
        entries.values.contains { $0.transferIdentity === identity }
            || rejected[ObjectIdentifier(identity)] != nil
    }

    /// Captures only live authorization, independently of navigation correlation and capacity.
    /// Reserves a live-writer slot before WebKit turns a navigation into a native download. An
    /// unauthorized or over-capacity policy is denied before WebKit creates a writer.
    func captureAdmissionToken(for tabID: BrowserTabID) -> AdmissionToken? {
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

        let lifetime = tabLifetimes[tabID] ?? UUID()
        tabLifetimes[tabID] = lifetime
        let reservationID = UUID()
        admissionReservations.insert(reservationID)
        return AdmissionToken(
            ownerID: ownerID,
            generation: generation,
            tabID: tabID,
            tabLifetime: lifetime,
            reservationID: reservationID,
        )
    }

    /// Releases a policy-time slot when WebKit abandons its conversion before handing off a writer.
    func releaseAdmissionReservation(_ token: AdmissionToken?) {
        guard let token, token.ownerID == ownerID else {
            return
        }

        admissionReservations.remove(token.reservationID)
    }

    /// Handoffs must belong to this owner, tab lifetime and unchanged policy-time privacy generation.
    /// Rejected writers remain owned until terminal cancellation acknowledgement, without scratch.
    func admit(
        _ transfer: any BrowserDownloadTransfer,
        tabID: BrowserTabID,
        using token: AdmissionToken?,
    ) -> BrowserDownloadID? {
        let reservationHeld: Bool =
            if let token, token.ownerID == ownerID {
                admissionReservations.remove(token.reservationID) != nil
            } else {
                false
            }
        if let existing = entries.values.first(where: { $0.transferIdentity === transfer.identity }) {
            return existing.id
        }
        let isStaleGenerationHandoff = token.map {
            $0.ownerID == ownerID && $0.generation != generation
        } ?? false
        guard let token, reservationHeld, token.ownerID == ownerID,
              token.generation == generation,
              token.tabID == tabID, tabLifetimes[tabID] == token.tabLifetime,
              authorizationActive, authorization()
        else {
            reject(transfer, notice: isStaleGenerationHandoff ? nil : .unauthorized)
            return nil
        }

        return admit(transfer, tabID: tabID)
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
        guard retainedCount < 8 else {
            reject(transfer, notice: .retainedRecordLimitReached)
            return nil
        }

        let id = BrowserDownloadID()
        entries[id] = Entry(id: id, tabID: tabID, generation: generation, revision: revision, transfer: transfer)
        order.append(id)
        notice = nil
        publish()
        return id
    }

    /// Retains a rejected native writer until cancellation acknowledges termination; no resume data
    /// or destination is retained. Duplicate handoffs cannot cancel an already-owned transfer.
    func reject(_ transfer: any BrowserDownloadTransfer, notice: BrowserDownloadSnapshot.Notice?) {
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
    }

    /// Supplies only an uncreated leaf in a verified protected operation directory.
    func destination(for id: BrowserDownloadID, suggestedName: String) -> URL? {
        guard currentEntry(id) != nil else {
            return nil
        }
        guard let entry = entries[id], entry.allocation == nil, !entry.writerStopped else {
            return nil
        }

        let allocation = store.allocation(id: id, suggestedName: suggestedName)
        entry.allocation = allocation
        do {
            try store.prepare(allocation)
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
        guard let entry = currentEntry(id), !entry.writerStopped else {
            return
        }

        let received = max(entry.receivedBytes, max(0, completed))
        let expected = total.flatMap { $0 > 0 ? max($0, received) : nil }
        guard received != entry.receivedBytes || expected != entry.expectedBytes else {
            return
        }

        entry.receivedBytes = received
        entry.expectedBytes = expected
        publish()
    }

    /// didFinish proves the writer stopped, but publication additionally requires actual file checks.
    func finished(_ id: BrowserDownloadID) {
        guard let entry = entries[id], !entry.writerStopped else {
            return
        }

        entry.writerStopped = true
        entry.transfer = nil
        guard !entry.revoked, entry.generation == generation, authorizationActive, authorization(),
              let allocation = entry.allocation
        else {
            revoke(id)
            return
        }

        do {
            entry.receivedBytes = try store.verifyCompleted(allocation)
            entry.isReady = true
            publish()
        } catch {
            #if DEBUG
            store.reportQualificationFailure(error, phase: "completion", allocation: allocation)
            #endif
            notice = .transferFailed
            revoke(id)
        }
    }

    /// Failure and cancellation acknowledgement are terminal even when delivered more than once.
    func failed(_ id: BrowserDownloadID) {
        guard let entry = entries[id], !entry.writerStopped else {
            return
        }

        entry.writerStopped = true
        entry.transfer = nil
        notice = entry.revoked ? notice : .transferFailed
        revoke(id)
    }

    func revokeTab(_ tabID: BrowserTabID) {
        tabLifetimes.removeValue(forKey: tabID)
        for id in entries.values.filter({ $0.tabID == tabID }).map(\.id) {
            revoke(id)
        }
    }

    /// Profile changes revoke every retained operation, including ones from tabs with no live view.
    func revokeAll() {
        tabLifetimes.removeAll()
        generation &+= 1
        clearPresentationForRevocation()
        for entry in entries.values {
            entry.revoked = true
        }
        publish()
        for id in Array(entries.keys) {
            revoke(id)
        }
    }

    func execute(_ command: BrowserDownloadCommand) {
        guard command.generation == generation, command.revision <= revision else {
            return
        }

        switch command.action {
        case let .cancel(id),
             let .discard(id):
            guard let entry = entries[id], command.revision >= entry.admittedRevision else {
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

    #if DEBUG
    // The standalone qualification target calls this method; the canonical analyzer corpus
    // builds the package and inert hosted target, so it cannot see that cross-target reference.
    // swiftlint:disable unused_declaration
    /// Qualification-only inspection of an already completed, currently authorized allocation.
    /// Uses the same live authorization, generation, cleanup and native-file checks as presentation.
    /// The URL never enters reducer state; inspection does not acquire a presentation or retain bytes.
    func qualificationCompletedFile(_ id: BrowserDownloadID) throws -> URL {
        guard let entry = currentEntry(id), entry.isReady, entry.writerStopped,
              let allocation = entry.allocation
        else {
            throw BrowserDownloadScratchStore.Failure.unsafeFile
        }

        do {
            _ = try store.verifyCompleted(allocation)
            return allocation.destination
        } catch {
            revoke(entry.id)
            throw error
        }
    }
    // swiftlint:enable unused_declaration
    #endif

    /// Retries only stopped writers' cleanup. Active cancellation ownership remains in place.
    func retryCleanup() {
        if startupCleanupPending {
            do {
                try store.purgePreviousProcess()
                startupCleanupPending = false
            } catch {
                notice = .cleanupRequired
            }
        }
        for id in Array(cleanupFailures) {
            cleanupStopped(id)
        }
        if !startupCleanupPending, cleanupFailures.isEmpty, notice == .cleanupRequired {
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
        guard !snapshot.cleanupNeedsRetry, let entry = entries[id], !entry.revoked,
              entry.generation == generation
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
        if entry.writerStopped {
            cleanupStopped(id)
        } else if !entry.cancellationRequested, let transfer = entry.transfer {
            entry.cancellationRequested = true
            transfer.cancel { [weak self] in self?.failed(id) }
        }
    }

    private func cleanupStopped(_ id: BrowserDownloadID) {
        guard let entry = entries[id], entry.writerStopped, entry.revoked else {
            return
        }

        do {
            if let allocation = entry.allocation {
                try store.cleanup(allocation)
            }
            entries.removeValue(forKey: id)
            order.removeAll { $0 == id }
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
        revision &+= 1
        let value = snapshot
        for continuation in subscribers.values {
            continuation.yield(value)
        }
    }
}
