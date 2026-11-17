//
//  BrowserDownloadObservationReceipt.swift
//  MediaVault
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

struct BrowserDownloadObservationContext: Codable, Equatable, Sendable {
    // The host and UI runner share this argument; the unit target compiles it without a launch consumer.
    // swiftlint:disable:next unused_declaration
    static let launchNonceArgument = "--browser-download-observation-process-nonce"

    let processNonce: UUID
    let runID: String
    let authorizationGeneration: UInt64
    let resourceGeneration: UInt64
    let ingestionGeneration: UInt64
    let phase: String
}

struct BrowserDownloadObservationRequest: Codable, Equatable, Sendable {
    let sequence: UInt64
    let id: UUID
    let context: BrowserDownloadObservationContext
}

struct BrowserDownloadObservationSnapshot: Codable, Equatable, Sendable {
    let inspection: [String: String]?
    let events: [[String: String]]

    init(inspection: [String: String]? = nil, events: [[String: String]] = []) {
        self.inspection = inspection
        self.events = events
    }

    /// Derives public fixture facts from raw records without changing the legacy event source.
    func addingFixtureProofs(expectedStagingBytes: Int64) -> Self {
        let cleanEvents = events.map(Self.removingFixtureProofs)
        let cleanInspection = inspection.map(Self.removingFixtureProofs)
        let records = cleanEvents + [cleanInspection].compactMap(\.self)
        return .init(
            inspection: cleanInspection.map {
                Self.derivingFixtureProofs($0, records: records, expectedStagingBytes: expectedStagingBytes)
            },
            events: cleanEvents.map {
                Self.derivingFixtureProofs($0, records: records, expectedStagingBytes: expectedStagingBytes)
            },
        )
    }

    private struct FixtureBounds {
        let expected: Int64
        let prefix: Int64
        let remainder: Int64

        var isValid: Bool {
            expected > prefix && prefix > 0 && remainder == expected - prefix
        }
    }

    private static let fixtureProofFields: Set = [
        "singleStagedFixture",
        "stagingEmpty",
        "progressPositive",
        "oneActiveWriter",
        "noActiveWriters",
        "oneRetainedCompletion",
        "ownerContentEmpty",
        "finiteResponseBoundsValid",
        "nativeProgressBoundsValid",
    ]
    private static let privateQuantityFields: Set = [
        "bytes",
        "temporaryBytes",
        "receivedBytes",
        "expectedBytes",
        "remaining",
        "prefixBytes",
        "remainderBytes",
        "serverExpectedBytes",
        "temporaryCount",
        "rowCount",
        "activeWriterCount",
        "retainedRecordCount",
        "recordCount",
        "active",
        "retained",
        "requestCount",
        "connectionCount",
        "operations",
    ]

    private static func removingFixtureProofs(_ record: [String: String]) -> [String: String] {
        record.filter { !fixtureProofFields.contains($0.key) }
    }

    private static func derivingFixtureProofs(
        _ record: [String: String],
        records: [[String: String]],
        expectedStagingBytes: Int64,
    ) -> [String: String] {
        var result = record
        if ["acceptedLibraryStorage", "libraryStartup"].contains(record["event"] ?? ""),
           let count = nonnegativeInteger(record["temporaryCount"]),
           let bytes = nonnegativeInteger(record["temporaryBytes"]) {
            if expectedStagingBytes > 0 {
                result["singleStagedFixture"] = String(count == 1 && bytes == expectedStagingBytes)
            }
            result["stagingEmpty"] = String(count == 0 && bytes == 0)
        }
        if record["event"] == "ownerSnapshot",
           let operations = record["operations"], let presentation = record["presentation"] {
            result["ownerContentEmpty"] = String(operations.isEmpty && presentation == "none")
        }
        if let received = nonnegativeInteger(record["receivedBytes"]) {
            result["progressPositive"] = String(received > 0)
        }
        if let active = aliasedCount(record, primary: "activeWriterCount", alias: "active") {
            result["oneActiveWriter"] = String(active == 1)
            result["noActiveWriters"] = String(active == 0)
        }
        if let retained = aliasedCount(record, primary: "retainedRecordCount", alias: "retained") {
            result["oneRetainedCompletion"] = String(retained == 1)
        }
        if record["event"] == "finiteResponseCompleted", let bounds = responseBounds(record, records: records) {
            result["finiteResponseBoundsValid"] = String(bounds.isValid)
        }
        if record["event"] == "nativePostLockProgress",
           let response = uniqueRecord("finiteResponseCompleted", matching: record, in: records),
           let bounds = responseBounds(response, records: records),
           let received = nonnegativeInteger(record["receivedBytes"]),
           nonnegativeInteger(record["expectedBytes"]) != nil {
            result["nativeProgressBoundsValid"] = String(bounds.isValid && received > bounds.prefix
                && received <= bounds.expected && record["expectedBytes"] == String(bounds.expected))
        }
        return result
    }

    private static func nonnegativeInteger(_ value: String?) -> Int64? {
        guard let value, !value.isEmpty, value.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }) else {
            return nil
        }

        return Int64(value)
    }

    private static func aliasedCount(_ record: [String: String], primary: String, alias: String) -> Int64? {
        if let raw = record[primary] {
            guard let value = nonnegativeInteger(raw) else {
                return nil
            }

            if let other = record[alias], nonnegativeInteger(other) != value {
                return nil
            }
            return value
        }
        guard record["event"] == "ownerSnapshot" else {
            return nil
        }

        return nonnegativeInteger(record[alias])
    }

    private static func responseBounds(_ response: [String: String], records: [[String: String]]) -> FixtureBounds? {
        guard let expected = nonnegativeInteger(response["expectedBytes"]),
              let prefix = nonnegativeInteger(response["prefixBytes"]),
              let remainder = nonnegativeInteger(response["remainderBytes"]),
              let readiness = uniqueRecord("slowKnownReadiness", matching: response, in: records),
              response["expectedBytes"] == readiness["expectedBytes"] else {
            return nil
        }

        return .init(expected: expected, prefix: prefix, remainder: remainder)
    }

    private static func uniqueRecord(
        _ name: String,
        matching record: [String: String],
        in records: [[String: String]],
    ) -> [String: String]? {
        let keys = ["runID", "fixtureRequest", "operation", "connectionID"]
        guard keys.allSatisfy({ record[$0]?.isEmpty == false }) else {
            return nil
        }

        var match: [String: String]?
        for candidate in records where candidate["event"] == name && keys.allSatisfy({ candidate[$0] == record[$0] }) {
            guard match == nil else {
                return nil
            }

            match = candidate
        }
        return match
    }

    private static func permits(_ key: String, value: String, authenticated: Bool) -> Bool {
        if fixtureProofFields.contains(key) {
            return value == "true" || value == "false"
        }
        guard authenticated || !privateQuantityFields.contains(key) else {
            return false
        }
        guard authenticated || key != "presentation" || value == "none" else {
            return false
        }

        return lifecycleFields.contains(key) || (authenticated && canonicalFields.contains(key))
    }

    /// Canonical facts belong to this inspection, never to historical evidence.
    func projected(for context: BrowserDownloadObservationContext) -> Self {
        let authenticated = context.phase == "authenticated"
        let inspectionEvents = [
            "canonicalLibrarySnapshot",
            "acceptedLibraryStorage",
            "acceptedLibraryStorageUnavailable",
            "canonicalLibraryInspectionFailed",
        ]
        let history = events.filter { !inspectionEvents.contains($0["event"] ?? "") }.map {
            $0.filter {
                Self.permits($0.key, value: $0.value, authenticated: authenticated)
            }
        }
        let record = inspection.flatMap { record -> [String: String]? in
            guard authenticated || ["acceptedLibraryStorage", "libraryStartup", "ownerSnapshot"]
                .contains(record["event"] ?? "") else {
                return nil
            }

            return record.filter {
                Self.permits($0.key, value: $0.value, authenticated: authenticated)
            }
        }
        return .init(inspection: record, events: history)
    }

    private static let canonicalFields: Set = [
        "sha256",
        "assetCount",
        "canonicalIDs",
        "resourceCount",
        "rowIDs",
        "importedRows",
        "duplicateRows",
        "originalBytesMatch",
        "originalHashMatches",
        "settled",
    ]

    /// Storage identity and writer proofs are distinct from canonical media identity.
    private static let lifecycleFields: Set = [
        "event",
        "processID",
        "runID",
        "wallTime",
        "monotonicSeconds",
        "generation",
        "phase",
        "authorizationGeneration",
        "resourceGeneration",
        "ingestionGeneration",
        "privacyGeneration",
        "operation",
        "allocation",
        "request",
        "revision",
        "libraryID",
        "databaseID",
        "authenticated",
        "contentEmpty",
        "temporaryCount",
        "temporaryBytes",
        "rowCount",
        "bytes",
        "fixtureBytesMatch",
        "backupExcluded",
        "nativeProtection",
        "protectionMode",
        "completeObserved",
        "protectionAttribute",
        "verified",
        "present",
        "absence",
        "available",
        "cleanupRetry",
        "retained",
        "active",
        "operations",
        "presentation",
        "registration",
        "sceneSession",
        "activation",
        "mounted",
        "coverVisible",
        "coverFrame",
        "sceneBounds",
        "nativeBarrier",
        "nativeLifecycle",
        "rootProof",
        "adapterIdentity",
        "commandAdapterIdentity",
        "tabID",
        "mountID",
        "sameOrigin",
        "source",
        "sourceRootPhase",
        "returnPending",
        "requestedHidden",
        "readoutHasBounds",
        "windowHasBounds",
        "windowHidden",
        "windowKey",
        "windowAccessibilityHidden",
        "hiddenAncestorCount",
        "transparentAncestorCount",
        "accessibilityHiddenAncestorCount",
        "ancestorCount",
        "sampleSource",
        "ownerGeneration",
        "operationGeneration",
        "activeWriterCount",
        "retainedRecordCount",
        "receivedBytes",
        "expectedBytes",
        "remaining",
        "released",
        "closeReason",
        "requestCount",
        "responseComplete",
        "connectionClosed",
        "documentMatches",
        "metadataMatches",
        "ready",
        "isReady",
        "requestParsed",
        "readyState",
        "callbackMonotonicSeconds",
        "connectionClosedMonotonicSeconds",
        "releaseMonotonicSeconds",
        "authorizationRevokedSynchronously",
        "authorizationValid",
        "privacyCleanupPending",
        "recordCount",
        "generationBefore",
        "initialGeneration",
        "fixtureOrigin",
        "fixtureRequest",
        "fixtureRoute",
        "capability",
        "connectionCount",
        "connectionID",
        "elapsedMilliseconds",
        "prefixBytes",
        "remainderBytes",
        "route",
        "sendStackState",
        "serverExpectedBytes",
    ]
}

struct BrowserDownloadObservationReceipt: Codable, Equatable, Sendable {
    enum State: String, Codable, Sendable {
        case idle
        case pending
        case completed
        case busy
        case failed
        case invalidated
    }

    let schemaVersion: Int
    let request: BrowserDownloadObservationRequest?
    let revision: UInt64
    let context: BrowserDownloadObservationContext
    let state: State
    let snapshot: BrowserDownloadObservationSnapshot

    init(
        schemaVersion: Int,
        request: BrowserDownloadObservationRequest?,
        revision: UInt64,
        context: BrowserDownloadObservationContext,
        state: State,
        snapshot: BrowserDownloadObservationSnapshot = .init(),
    ) {
        self.schemaVersion = schemaVersion
        self.request = request
        self.revision = revision
        self.context = context
        self.state = state
        self.snapshot = snapshot
    }

    init(
        request: BrowserDownloadObservationRequest?,
        revision: UInt64,
        context: BrowserDownloadObservationContext,
        state: State,
        snapshot: BrowserDownloadObservationSnapshot = .init(),
    ) {
        self.init(
            schemaVersion: 1,
            request: request,
            revision: revision,
            context: context,
            state: state,
            snapshot: snapshot,
        )
    }

    static func decode(_ value: String?) throws -> Self {
        guard let value, !value.isEmpty else {
            throw BrowserDownloadObservationError.missing
        }

        do {
            return try JSONDecoder().decode(Self.self, from: Data(value.utf8))
        } catch {
            throw BrowserDownloadObservationError.malformed
        }
    }

    /// An unchanged baseline or the next pending request supplies no completed evidence.
    func validatedSnapshot(
        after baseline: Self,
        context: BrowserDownloadObservationContext,
        deadline: BrowserDownloadObservationDeadline,
        now: TimeInterval,
    ) throws -> BrowserDownloadObservationSnapshot? {
        try validatedSnapshotRecordingFailure(
            after: baseline,
            context: context,
            deadline: deadline,
            now: now,
            recordFailure: nil,
        )
    }

    func validatedSnapshotRecordingFailure(
        after baseline: Self,
        context: BrowserDownloadObservationContext,
        deadline: BrowserDownloadObservationDeadline,
        now: TimeInterval,
        recordFailure: ((
            BrowserDownloadObservationFailureEvidence.Comparison,
            BrowserDownloadObservationFailureEvidence.ContextField?,
        ) -> Void)?,
    ) throws -> BrowserDownloadObservationSnapshot? {
        typealias Evidence = BrowserDownloadObservationFailureEvidence
        guard deadline.remaining(at: now) > 0 else {
            recordFailure?(.deadline, nil)
            throw BrowserDownloadObservationError.deadlineExceeded
        }
        guard schemaVersion == 1, baseline.schemaVersion == 1, !context.runID.isEmpty else {
            let comparison: Evidence.Comparison = schemaVersion != 1
                ? .receiptSchema
                : (baseline.schemaVersion != 1 ? .baselineSchema : .contextRunIDEmpty)
            recordFailure?(comparison, nil)
            throw BrowserDownloadObservationError.malformed
        }
        guard self.context == context, baseline.context == context else {
            let fromReceipt = self.context != context
            recordFailure?(
                fromReceipt ? .receiptContext : .baselineContext,
                Evidence.firstContextDifference(fromReceipt ? self.context : baseline.context, context),
            )
            throw BrowserDownloadObservationError.stale
        }

        if self == baseline {
            return nil
        }
        let previous = baseline.request?.sequence ?? 0
        guard previous < .max, let request, request.sequence == previous + 1,
              request.id != baseline.request?.id, request.context == context else {
            let comparison = requestFailureComparison(after: baseline)
            let field = comparison == .requestContext
                ? request.flatMap { Evidence.firstContextDifference($0.context, context) }
                : nil
            recordFailure?(comparison, field)
            throw BrowserDownloadObservationError.stale
        }

        switch state {
        case .pending:
            guard revision == baseline.revision else {
                recordFailure?(.pendingRevision, nil)
                throw BrowserDownloadObservationError.stale
            }

            return nil
        case .completed:
            guard revision > baseline.revision else {
                recordFailure?(.completedRevision, nil)
                throw BrowserDownloadObservationError.stale
            }

            return snapshot.projected(for: context)
        case .busy:
            recordFailure?(.receiptBusy, nil)
            throw BrowserDownloadObservationError.busy
        case .failed:
            recordFailure?(.receiptFailed, nil)
            throw BrowserDownloadObservationError.failed
        case .invalidated:
            recordFailure?(.receiptInvalidated, nil)
            throw BrowserDownloadObservationError.invalidated
        case .idle:
            recordFailure?(.receiptIdle, nil)
            throw BrowserDownloadObservationError.notCompleted
        }
    }

    private func requestFailureComparison(after baseline: Self) -> BrowserDownloadObservationFailureEvidence
        .Comparison {
        let previous = baseline.request?.sequence ?? 0
        if previous == .max {
            return .sequenceExhausted
        }
        if request == nil {
            return .missingRequest
        }
        if request?.sequence != previous + 1 {
            return .requestSequence
        }
        if request?.id == baseline.request?.id {
            return .reusedRequestID
        }
        return .requestContext
    }
}

enum BrowserDownloadObservationError: Error, Equatable, Sendable {
    case missing
    case malformed
    case stale
    case busy
    case failed
    case invalidated
    case interrupted
    case deadlineExceeded
    case notCompleted
}

struct BrowserDownloadObservationDeadline: Sendable {
    private let start: TimeInterval
    private let end: TimeInterval

    init(start: TimeInterval, duration: TimeInterval = 10) {
        self.start = start
        end = start + duration
    }

    func remaining(at now: TimeInterval) -> TimeInterval {
        guard start.isFinite, end.isFinite, now.isFinite, now >= start else {
            return 0
        }

        return max(0, end - now)
    }
}

@MainActor
final class BrowserDownloadObservationController {
    private let context: @MainActor () -> BrowserDownloadObservationContext
    private let publish: @MainActor (BrowserDownloadObservationReceipt) -> Void
    private var stored: BrowserDownloadObservationReceipt
    private var sequence: UInt64 = 0
    private var revision: UInt64 = 0
    private var epoch: UInt64 = 0
    private var active: BrowserDownloadObservationRequest?

    var receipt: BrowserDownloadObservationReceipt {
        contextDidChange()
        return stored
    }

    init(
        context: @escaping @MainActor () -> BrowserDownloadObservationContext,
        publish: @escaping @MainActor (BrowserDownloadObservationReceipt) -> Void,
    ) {
        self.context = context
        self.publish = publish
        stored = .init(request: nil, revision: 0, context: context(), state: .idle)
    }

    func refresh(
        inspect: @MainActor () async throws -> BrowserDownloadObservationSnapshot,
    ) async -> BrowserDownloadObservationReceipt {
        contextDidChange()
        guard sequence < .max, revision < .max else {
            emit(request: nil, state: .failed)
            return stored
        }

        sequence += 1
        let request = BrowserDownloadObservationRequest(sequence: sequence, id: UUID(), context: context())
        guard active == nil else {
            emit(request: request, state: .busy)
            return stored
        }

        active = request
        let admittedEpoch = epoch
        emit(request: request, state: .pending)
        var snapshot: BrowserDownloadObservationSnapshot?
        do {
            snapshot = try await inspect()
        } catch {}
        contextDidChange()
        active = nil
        guard stored.request == request else {
            return stored
        }
        guard admittedEpoch == epoch, request.context == context() else {
            emit(request: request, state: .invalidated)
            return stored
        }
        guard let snapshot, !Task.isCancelled else {
            emit(request: request, state: .failed)
            return stored
        }

        revision += 1
        emit(request: request, state: .completed, snapshot: snapshot)
        return receipt
    }

    /// Call on every context transition so an ABA change also invalidates suspended work.
    func contextDidChange() {
        guard stored.context != context() else {
            return
        }

        epoch &+= 1
        emit(request: stored.request, state: active == nil ? .idle : .invalidated)
    }

    private func emit(
        request: BrowserDownloadObservationRequest?,
        state: BrowserDownloadObservationReceipt.State,
        snapshot: BrowserDownloadObservationSnapshot = .init(),
    ) {
        let current = context()
        stored = .init(
            request: request,
            revision: revision,
            context: current,
            state: state,
            snapshot: snapshot.projected(for: current),
        )
        publish(stored)
    }
}

struct BrowserDownloadObservationPreparation: Codable, Equatable, Sendable {
    enum Phase: String, Codable, Sendable { case active, inactive, background, unknown }
    let processNonce: UUID
    private(set) var startupComplete = false
    private(set) var phase = Phase.unknown
    private(set) var revision: UInt64 = 0
    private(set) var publishedContext: BrowserDownloadObservationContext?
    private(set) var publishedRevision: UInt64?
    private(set) var ingestionBeforePhase: UInt64?
    private(set) var ingestionAfterPhase: UInt64?

    init(processNonce: UUID) {
        self.processNonce = processNonce
    }

    var canPublish: Bool {
        startupComplete && phase == .active
    }

    var isReady: Bool {
        canPublish && publishedRevision == revision && publishedContext != nil
    }

    mutating func markStartupComplete() {
        startupComplete = true
        invalidatePublication()
    }

    mutating func contextDidChange() {
        invalidatePublication()
    }

    mutating func observePhase(_ phase: Phase, ingestionBefore: UInt64, ingestionAfter: UInt64) {
        self.phase = phase
        ingestionBeforePhase = ingestionBefore
        ingestionAfterPhase = ingestionAfter
        invalidatePublication()
    }

    mutating func markPublished(context: BrowserDownloadObservationContext, revision: UInt64) -> Bool {
        guard revision == self.revision, canPublish, context.processNonce == processNonce else {
            return false
        }

        publishedContext = context
        publishedRevision = revision
        return true
    }

    private mutating func invalidatePublication() {
        revision &+= 1
        publishedContext = nil
        publishedRevision = nil
    }
}

/// Keeps only accepted wire positions; a stale AX baseline cannot reopen an old request.
@MainActor
final class BrowserDownloadObservationCursor {
    typealias Receipt = BrowserDownloadObservationReceipt
    typealias Context = BrowserDownloadObservationContext
    typealias Deadline = BrowserDownloadObservationDeadline
    typealias Snapshot = BrowserDownloadObservationSnapshot
    typealias Evidence = BrowserDownloadObservationFailureEvidence

    private struct Position: Equatable {
        let processNonce: UUID
        let runID: String
        let requestID: UUID?
        let sequence: UInt64
        let revision: UInt64

        init(_ receipt: Receipt) {
            processNonce = receipt.context.processNonce
            runID = receipt.context.runID
            requestID = receipt.request?.id
            sequence = receipt.request?.sequence ?? 0
            revision = receipt.revision
        }

        func firstDifference(from other: Self) -> Evidence.PositionField? {
            if processNonce != other.processNonce {
                return .processNonce
            }
            if runID != other.runID {
                return .runID
            }
            if requestID != other.requestID {
                return .requestID
            }
            if sequence != other.sequence {
                return .sequence
            }
            if revision != other.revision {
                return .revision
            }
            return nil
        }
    }

    private struct FailureScope {
        let stage: Evidence.Stage
        let baseline: Evidence.Receipt?
        let observedReceipt: Evidence.Receipt?
        let context: Evidence.Context?
        let nonce: UUID?
        let remainingBudget: TimeInterval?

        init(
            stage: Evidence.Stage,
            baseline: Receipt? = nil,
            receipt: Receipt? = nil,
            context: Context? = nil,
            nonce: UUID? = nil,
            remainingBudget: TimeInterval? = nil,
        ) {
            self.stage = stage
            self.baseline = baseline.map(Evidence.Receipt.init)
            observedReceipt = receipt.map(Evidence.Receipt.init)
            self.context = context.map(Evidence.Context.init)
            self.nonce = nonce ?? context?.processNonce
            self.remainingBudget = remainingBudget
        }
    }

    private struct FailureTag {
        let comparison: Evidence.Comparison
        let contextField: Evidence.ContextField?
        let positionField: Evidence.PositionField?

        init(
            _ comparison: Evidence.Comparison,
            contextField: Evidence.ContextField? = nil,
            positionField: Evidence.PositionField? = nil,
        ) {
            self.comparison = comparison
            self.contextField = contextField
            self.positionField = positionField
        }
    }

    private(set) var lastFailure: Evidence?
    private var position: Position?
    private var expectedProcessNonce: UUID?
    private var retiredProcessNonces: Set<UUID> = []

    init() {}

    var requiresInitialBaseline: Bool {
        position == nil
    }

    func validatePreparation(
        _ preparation: BrowserDownloadObservationPreparation,
        baseline: Receipt? = nil,
    ) throws -> Bool {
        let scope = FailureScope(
            stage: .preparation,
            baseline: baseline,
            context: preparation.publishedContext,
            nonce: preparation.processNonce,
        )
        guard expectedProcessNonce == preparation.processNonce,
              !retiredProcessNonces.contains(preparation.processNonce)
        else {
            recordFailure(FailureTag(.unauthorizedProcess), in: scope)
            throw BrowserDownloadObservationError.stale
        }

        if let published = preparation.publishedContext, published.processNonce != preparation.processNonce {
            recordFailure(FailureTag(.preparationContext, contextField: .processNonce), in: scope)
            throw BrowserDownloadObservationError.stale
        }
        guard preparation.isReady else {
            return false
        }

        if let baseline, let published = preparation.publishedContext, published != baseline.context {
            recordFailure(
                FailureTag(
                    .preparationContext,
                    contextField: Evidence.firstContextDifference(published, baseline.context),
                ),
                in: scope,
            )
            throw BrowserDownloadObservationError.stale
        }
        return true
    }

    /// Bind the driver's nonce before a real launch; a receipt cannot authorize its own process.
    func authorizeProcess(_ nonce: UUID) throws {
        guard !retiredProcessNonces.contains(nonce) else {
            recordFailure(.init(.retiredAuthorization), in: .init(stage: .authorization, nonce: nonce))
            throw BrowserDownloadObservationError.stale
        }
        guard expectedProcessNonce != nonce else {
            return
        }

        if let previous = expectedProcessNonce {
            retiredProcessNonces.insert(previous)
        }
        expectedProcessNonce = nonce
        position = nil
    }

    /// Clears diagnostic evidence only; accepted positions and retired processes remain unchanged.
    func clearFailureEvidence() {
        lastFailure = nil
    }

    func validateBaseline(_ baseline: Receipt, context: Context) throws {
        try validateBaseline(baseline, context: context, stage: .baseline, observedReceipt: nil)
    }

    private func validateBaseline(
        _ baseline: Receipt,
        context: Context,
        stage: Evidence.Stage,
        observedReceipt: Receipt?,
    ) throws {
        let scope = FailureScope(stage: stage, baseline: baseline, receipt: observedReceipt, context: context)
        guard baseline.schemaVersion == 1, !context.runID.isEmpty else {
            recordFailure(.init(baseline.schemaVersion != 1 ? .baselineSchema : .contextRunIDEmpty), in: scope)
            throw BrowserDownloadObservationError.malformed
        }
        guard baseline.context == context, context.processNonce == expectedProcessNonce,
              !retiredProcessNonces.contains(context.processNonce),
              baseline.state == .idle || baseline.state == .completed else {
            let tag = baselineFailureTag(baseline, context: context)
            recordFailure(tag, in: scope)
            throw BrowserDownloadObservationError.stale
        }

        if baseline.state == .completed {
            guard baseline.request?.context == context else {
                let tag = FailureTag(
                    baseline.request == nil ? .missingRequest : .baselineRequestContext,
                    contextField: baseline.request.flatMap { Evidence.firstContextDifference(
                        $0.context,
                        context,
                    ) },
                )
                recordFailure(tag, in: scope)
                throw BrowserDownloadObservationError.stale
            }
        } else if let request = baseline.request {
            guard request.context.processNonce == context.processNonce, request.context.runID == context.runID else {
                recordFailure(.init(
                    .baselineRequestContext,
                    contextField:
                    request.context.processNonce != context.processNonce ? .processNonce : .runID,
                ), in: scope)
                throw BrowserDownloadObservationError.stale
            }
        }
        let candidate = Position(baseline)
        if let accepted = position {
            guard accepted == candidate else {
                recordFailure(
                    .init(.acceptedPosition, positionField: accepted.firstDifference(from: candidate)),
                    in: scope,
                )
                throw BrowserDownloadObservationError.stale
            }

            return
        }
        guard baseline.state == .idle, baseline.request == nil, baseline.revision == 0 else {
            let comparison: Evidence.Comparison = baseline.state != .idle
                ? .initialState
                : (baseline.request != nil ? .initialRequest : .initialRevision)
            recordFailure(.init(comparison), in: scope)
            throw BrowserDownloadObservationError.stale
        }

        position = candidate
    }

    private func baselineFailureTag(_ baseline: Receipt, context: Context) -> FailureTag {
        if baseline.context != context {
            return .init(.baselineContext, contextField: Evidence.firstContextDifference(baseline.context, context))
        }
        if context.processNonce != expectedProcessNonce {
            return .init(.unauthorizedProcess)
        }
        if retiredProcessNonces.contains(context.processNonce) {
            return .init(.retiredProcess)
        }
        return .init(.baselineState)
    }

    /// Every completed read advances position, before the caller evaluates domain readiness.
    func validatedSnapshot(
        _ receipt: Receipt,
        after baseline: Receipt,
        context: Context,
        deadline: Deadline,
        now: TimeInterval,
    ) throws -> Snapshot? {
        try validateBaseline(baseline, context: context, stage: .completionBaseline, observedReceipt: receipt)
        var tag: FailureTag?
        let snapshot: Snapshot?
        do {
            snapshot = try receipt.validatedSnapshotRecordingFailure(
                after: baseline,
                context: context,
                deadline: deadline,
                now: now,
                recordFailure: { comparison, field in tag = .init(comparison, contextField: field) },
            )
        } catch {
            if let tag {
                recordFailure(tag, in: .init(
                    stage: .completion,
                    baseline: baseline,
                    receipt: receipt,
                    context: context,
                    remainingBudget: deadline.remaining(at: now),
                ))
            }
            throw error
        }
        if snapshot != nil {
            position = Position(receipt)
        }
        return snapshot
    }

    private func recordFailure(_ tag: FailureTag, in scope: FailureScope) {
        lastFailure = Evidence(
            stage: scope.stage,
            comparison: tag.comparison,
            contextField: tag.contextField,
            positionField: tag.positionField,
            authorizedProcessNonce: expectedProcessNonce,
            acceptedPosition: position.map {
                .init(
                    processNonce: $0.processNonce,
                    runID: Evidence.safeRunID($0.runID),
                    requestID: $0.requestID,
                    sequence: $0.sequence,
                    revision: $0.revision,
                )
            },
            baseline: scope.baseline,
            observedReceipt: scope.observedReceipt,
            context: scope.context,
            observedProcessNonce: scope.nonce,
            processWasRetired: scope.nonce.map { retiredProcessNonces.contains($0) } ?? false,
            remainingBudget: scope.remainingBudget,
        )
    }
}

/// Sanitized scalar operands from a rejecting guard. Receipt payloads are never retained here.
struct BrowserDownloadObservationFailureEvidence: Codable, Equatable, Sendable {
    enum Stage: String, Codable, Sendable { case baseline, completionBaseline, completion, authorization, preparation }
    enum Comparison: String, Codable, Sendable {
        case deadline
        case receiptSchema
        case baselineSchema
        case contextRunIDEmpty
        case receiptContext
        case baselineContext
        case sequenceExhausted
        case missingRequest
        case requestSequence
        case reusedRequestID
        case requestContext
        case pendingRevision
        case completedRevision
        case receiptBusy
        case receiptFailed
        case receiptInvalidated
        case receiptIdle
        case unauthorizedProcess
        case retiredProcess
        case baselineState
        case baselineRequestContext
        case acceptedPosition
        case initialState
        case initialRequest
        case initialRevision
        case retiredAuthorization
        case preparationContext
    }

    enum ContextField: String, Codable, Sendable {
        case processNonce
        case runID
        case authorizationGeneration
        case resourceGeneration
        case ingestionGeneration
        case phase
    }

    enum PositionField: String, Codable, Sendable { case processNonce, runID, requestID, sequence, revision }
    struct Context: Codable, Equatable, Sendable {
        let processNonce: UUID
        let runID: String
        let authorizationGeneration: UInt64
        let resourceGeneration: UInt64
        let ingestionGeneration: UInt64
        let phase: String

        init(_ value: BrowserDownloadObservationContext) {
            processNonce = value.processNonce
            runID = BrowserDownloadObservationFailureEvidence.safeRunID(value.runID)
            authorizationGeneration = value.authorizationGeneration
            resourceGeneration = value.resourceGeneration
            ingestionGeneration = value.ingestionGeneration
            phase = ["loading", "unconfigured", "unavailable", "setup", "locked", "authentication", "authenticated"]
                .contains(value.phase) ? value.phase : "invalid"
        }
    }

    struct Request: Codable, Equatable, Sendable {
        let id: UUID
        let sequence: UInt64
        let context: Context

        init(_ value: BrowserDownloadObservationRequest) {
            id = value.id
            sequence = value.sequence
            context = .init(value.context)
        }
    }

    struct Receipt: Codable, Equatable, Sendable {
        let schemaVersion: Int
        let request: Request?
        let revision: UInt64
        let context: Context
        let state: BrowserDownloadObservationReceipt.State

        init(_ value: BrowserDownloadObservationReceipt) {
            schemaVersion = value.schemaVersion
            request = value.request.map(Request.init)
            revision = value.revision
            context = .init(value.context)
            state = value.state
        }
    }

    struct Position: Codable, Equatable, Sendable {
        let processNonce: UUID
        let runID: String
        let requestID: UUID?
        let sequence: UInt64
        let revision: UInt64
    }

    let stage: Stage
    let comparison: Comparison
    let contextField: ContextField?
    let positionField: PositionField?
    let authorizedProcessNonce: UUID?
    let acceptedPosition: Position?
    let baseline: Receipt?
    let observedReceipt: Receipt?
    let context: Context?
    let observedProcessNonce: UUID?
    let processWasRetired: Bool
    let remainingBudget: TimeInterval?

    static func safeRunID(_ value: String) -> String {
        UUID(uuidString: value)?.uuidString ?? "invalid"
    }

    static func firstContextDifference(
        _ lhs: BrowserDownloadObservationContext,
        _ rhs: BrowserDownloadObservationContext,
    ) -> ContextField? {
        if lhs.processNonce != rhs.processNonce {
            return .processNonce
        }
        if lhs.runID != rhs.runID {
            return .runID
        }
        if lhs.authorizationGeneration != rhs.authorizationGeneration {
            return .authorizationGeneration
        }
        if lhs.resourceGeneration != rhs.resourceGeneration {
            return .resourceGeneration
        }
        if lhs.ingestionGeneration != rhs.ingestionGeneration {
            return .ingestionGeneration
        }
        if lhs.phase != rhs.phase {
            return .phase
        }
        return nil
    }
}
