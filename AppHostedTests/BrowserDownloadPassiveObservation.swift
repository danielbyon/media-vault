//
//  BrowserDownloadPassiveObservation.swift
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
    var phaseRevision: UInt64 = 0
}

/// Ties callbacks to one qualification root and becomes invalid when that root disconnects.
@MainActor
final class BrowserDownloadQualificationSceneRegistration {
    let rootID: UUID
    private(set) var isConnected = false
    private(set) var isDisconnected = false

    init(rootID: UUID = UUID()) {
        self.rootID = rootID
    }

    fileprivate func connect() -> Bool {
        guard !isConnected, !isDisconnected else {
            return false
        }

        isConnected = true
        return true
    }

    fileprivate func disconnect() {
        isConnected = false
        isDisconnected = true
    }
}

/// Tracks connected roots and reports when their activity changes Library sampling eligibility.
@MainActor
final class BrowserDownloadQualificationSceneActivity {
    private struct RootActivity {
        let registration: BrowserDownloadQualificationSceneRegistration
        var isActive: Bool
    }

    private var activeByRoot: [UUID: RootActivity] = [:]
    private let refreshLibrarySample: @MainActor () -> Void

    init(refreshLibrarySample: @escaping @MainActor () -> Void = {}) {
        self.refreshLibrarySample = refreshLibrarySample
    }

    var isObservationEligible: Bool {
        activeByRoot.values.contains(where: \.isActive)
    }

    func isActive(registration: BrowserDownloadQualificationSceneRegistration) -> Bool? {
        guard let root = activeByRoot[registration.rootID], root.registration === registration else {
            return nil
        }

        return root.isActive
    }

    /// Registers a root once and reports whether it changed aggregate eligibility.
    func register(
        registration: BrowserDownloadQualificationSceneRegistration,
        active: Bool,
    ) -> Bool? {
        if let root = activeByRoot[registration.rootID] {
            return root.registration === registration ? false : nil
        }
        guard registration.connect() else {
            return nil
        }

        let wasEligible = isObservationEligible
        activeByRoot[registration.rootID] = RootActivity(registration: registration, isActive: active)
        return wasEligible != isObservationEligible
    }

    /// Applies phase changes only to the current root connection.
    func setActive(_ active: Bool, registration: BrowserDownloadQualificationSceneRegistration) -> Bool? {
        guard registration.isConnected,
              var root = activeByRoot[registration.rootID],
              root.registration === registration else {
            return nil
        }

        let wasEligible = isObservationEligible
        root.isActive = active
        activeByRoot[registration.rootID] = root
        return wasEligible != isObservationEligible
    }

    /// Disconnects a root and invalidates its token so late callbacks are ignored.
    func disconnect(registration: BrowserDownloadQualificationSceneRegistration) -> Bool {
        let wasEligible = isObservationEligible
        registration.disconnect()
        guard let root = activeByRoot[registration.rootID], root.registration === registration else {
            return false
        }

        activeByRoot.removeValue(forKey: registration.rootID)
        let eligibilityChanged = wasEligible != isObservationEligible
        refreshLibrarySampleIfEligibilityChanged(eligibilityChanged)
        return eligibilityChanged
    }

    /// Applies the Store phase before sampling after an aggregate eligibility change.
    func applyPhaseChange(
        active: Bool,
        registration: BrowserDownloadQualificationSceneRegistration,
        applyApplicationPhase: @MainActor () -> Void,
    ) -> Bool? {
        guard let eligibilityChanged = setActive(active, registration: registration) else {
            return nil
        }

        applyApplicationPhase()
        refreshLibrarySampleIfEligibilityChanged(eligibilityChanged)
        return eligibilityChanged
    }

    /// Refreshes Library sampling when the first root becomes active or the last becomes inactive.
    private func refreshLibrarySampleIfEligibilityChanged(_ eligibilityChanged: Bool?) {
        guard eligibilityChanged == true else {
            return
        }

        refreshLibrarySample()
    }
}

/// Keeps storage availability tied to the context that produced the observation.
struct BrowserDownloadStorageObservationState {
    private(set) var context: BrowserDownloadObservationContext?
    private(set) var available = false

    @discardableResult
    mutating func record(
        available: Bool,
        from observedContext: BrowserDownloadObservationContext?,
        current currentContext: BrowserDownloadObservationContext,
    ) -> Bool {
        guard let observedContext, observedContext == currentContext else {
            return false
        }

        context = observedContext
        self.available = available
        return true
    }

    func isAvailable(in currentContext: BrowserDownloadObservationContext) -> Bool {
        available && context == currentContext
    }

    /// Locked staging inspection checks storage directly. Authenticated reads still require current owner evidence.
    func permitsLibraryRead(in currentContext: BrowserDownloadObservationContext) -> Bool {
        currentContext.phase == "locked" || isAvailable(in: currentContext)
    }

    /// Recovery can finish while an inspection is still returning an unavailable result.
    static func shouldRetryAfterRecovery(
        phase: String?,
        inspectionInFlight: Bool,
        outcome: BrowserDownloadLibraryObservation.Outcome?,
    ) -> Bool {
        phase == "locked" && (inspectionInFlight || outcome == .unavailable)
    }
}

struct BrowserDownloadObservationSnapshot: Codable, Equatable, Sendable {
    let events: [[String: String]]

    /// Compute fixture bounds from the retained events before hiding private quantities.
    func addingFixtureProofs() -> Self {
        let records = events.map(Self.removingFixtureProofs)
        return .init(events: records.map { Self.derivingFixtureProofs($0, records: records) })
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
    ) -> [String: String] {
        var result = record
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

        return lifecycleFields.contains(key) || (authenticated && authenticatedFields.contains(key))
    }

    func projected(for context: BrowserDownloadObservationContext) -> Self {
        let authenticated = context.phase == "authenticated"
        return .init(events: events.map { event in event.filter { Self.permits(
            $0.key,
            value: $0.value,
            authenticated: authenticated,
        ) } })
    }

    private static let authenticatedFields: Set = [
        "webViewIdentity",
        "webViewAttached",
        "direction",
        "contentPresent",
        "contentAttached",
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
        "processNonce",
        "processID",
        "runID",
        "wallTime",
        "monotonicSeconds",
        "generation",
        "phase",
        "phaseRevision",
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

/// Only the current launch and privacy context can publish a Library result.
struct BrowserDownloadLibraryObservation: Codable, Equatable, Sendable {
    enum Outcome: String, Codable {
        case complete
        case unavailable
        case invalidated
        case failed
    }

    let context: BrowserDownloadObservationContext
    let outcome: Outcome
    let fields: [String: String]

    static func matchesStagedFixture(
        operation: UUID?,
        verified: Bool,
        matchesOperation: Bool?,
        count: Int,
        bytes: Int64,
        expectedBytes: Int64,
    ) -> Bool {
        operation != nil && verified && matchesOperation == true && count == 1 && expectedBytes > 0 && bytes ==
            expectedBytes
    }

    func completedFields() throws -> [String: String] {
        switch outcome {
        case .complete:
            return fields
        case .unavailable:
            throw BrowserDownloadObservationError.unavailable
        case .invalidated:
            throw BrowserDownloadObservationError.invalidated
        case .failed:
            throw BrowserDownloadObservationError.failed
        }
    }

    func validate(for expected: BrowserDownloadObservationContext) throws {
        guard context == expected else {
            throw BrowserDownloadObservationError.stale
        }
        guard outcome == .complete else {
            guard fields.isEmpty else {
                throw BrowserDownloadObservationError.malformed
            }

            return
        }

        let identity: Set = ["event", "runID", "processID", "databaseID", "libraryID", "authenticated"]
        var required: Set<String>
        switch (context.phase, fields["event"]) {
        case ("locked", "libraryStartup"),
             ("locked", "acceptedLibraryStorage"):
            required = identity.union(["singleStagedFixture", "stagingEmpty", "contentEmpty"])
            guard ["singleStagedFixture", "stagingEmpty", "contentEmpty"].allSatisfy({ Bool(fields[$0] ?? "") != nil })
            else {
                throw BrowserDownloadObservationError.malformed
            }

            if fields["singleStagedFixture"] == "true" {
                guard UUID(uuidString: fields["operation"] ?? "") != nil, fields["stagingEmpty"] == "false" else {
                    throw BrowserDownloadObservationError.malformed
                }

                required.insert("operation")
            }
            guard fields["authenticated"] == "false" else {
                throw BrowserDownloadObservationError.malformed
            }

        case ("authenticated", "canonicalLibrarySnapshot"):
            required = identity.union([
                "assetCount",
                "canonicalIDs",
                "resourceCount",
                "rowCount",
                "rowIDs",
                "importedRows",
                "duplicateRows",
                "temporaryCount",
                "temporaryBytes",
                "originalBytesMatch",
                "originalHashMatches",
                "settled",
            ])
            guard fields["authenticated"] == "true" else {
                throw BrowserDownloadObservationError.malformed
            }

        default:
            throw BrowserDownloadObservationError.malformed
        }
        guard Set(fields.keys) == required, fields["runID"] == context.runID,
              Int32(fields["processID"] ?? "") != nil, UUID(uuidString: fields["libraryID"] ?? "") != nil,
              fields["databaseID"]?.utf8.count == 64, fields["databaseID"]?.allSatisfy(\.isHexDigit) == true else {
            throw BrowserDownloadObservationError.malformed
        }
    }
}

/// A bounded event view carries the context needed to reject stale accessibility samples.
struct BrowserDownloadPassiveObservation: Codable, Equatable, Sendable {
    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case context
        case events
        case library
        case mountedTabID
        case discardedEventCount
        case truncated
        case hasUnscopedEvents
    }

    static let maximumEventCount = 256
    private static let lockedInspectionEvents: Set = [
        "libraryStartup",
        "canonicalLibrarySnapshot",
        "acceptedLibraryStorage",
        "acceptedLibraryStorageUnavailable",
        "canonicalLibraryInspectionFailed",
        "completedFileProof",
        "completedFileInspectionFailed",
    ]

    let schemaVersion: Int
    let context: BrowserDownloadObservationContext
    let events: [[String: String]]
    let library: BrowserDownloadLibraryObservation?
    let mountedTabID: UUID?
    let discardedEventCount: Int
    let truncated: Bool
    let hasUnscopedEvents: Bool

    init(
        context: BrowserDownloadObservationContext,
        events: [[String: String]],
        mountedTabID: UUID? = nil,
        discardedEventCount: Int = 0,
        library: BrowserDownloadLibraryObservation? = nil,
    ) {
        schemaVersion = 2
        self.library = library
        self.mountedTabID = context.phase == "authenticated" ? mountedTabID : nil
        self.discardedEventCount = discardedEventCount
        self.context = context
        let scopedEvents = events.filter { $0["runID"] == context.runID }
        hasUnscopedEvents = scopedEvents.count != events.count
        let visibleEvents = context.phase == "authenticated"
            ? scopedEvents
            : scopedEvents.filter { !Self.lockedInspectionEvents.contains($0["event"] ?? "") }
        let projection = BrowserDownloadObservationSnapshot(events: visibleEvents)
            .addingFixtureProofs()
            .projected(for: context)
        truncated = projection.events.count > Self.maximumEventCount
        self.events = Array(projection.events.prefix(Self.maximumEventCount))
    }

    /// An attachment must keep the same policy reservation through handoff, writer finish, and file inspection.
    func completedAttachment(after baseline: Self) -> [String: String]? {
        guard context == baseline.context, context.phase == "authenticated",
              events.count >= baseline.events.count
        else {
            return nil
        }
        guard let operation = finishedOperation(after: baseline, route: "attachment") else {
            return nil
        }
        guard let boundary = baseline.events.last?["monotonicSeconds"].flatMap(Double.init),
              boundary.isFinite else {
            return nil
        }

        let fresh = events.filter {
            ($0["monotonicSeconds"].flatMap(Double.init) ?? -.infinity) > boundary
        }
        let proofs = fresh.filter { $0["event"] == "completedFileProof" }
        guard proofs.count == 1, let proof = proofs.first, proof["operation"] == operation,
              proof["ready"] == "true", proof["processNonce"] == context.processNonce.uuidString,
              proof["generation"] == String(context.authorizationGeneration),
              proof["authorizationGeneration"] == String(context.authorizationGeneration),
              proof["resourceGeneration"] == String(context.resourceGeneration),
              proof["ingestionGeneration"] == String(context.ingestionGeneration),
              proof["phaseRevision"] == String(context.phaseRevision), proof["phase"] == context.phase,
              let finished = fresh.first(where: { $0["event"] == "writerFinished" }),
              let finishedTime = finished["monotonicSeconds"].flatMap(Double.init),
              let proofTime = proof["monotonicSeconds"].flatMap(Double.init), proofTime.isFinite,
              proofTime > finishedTime else {
            return nil
        }

        return proof
    }

    /// Summarizes a rejected attachment proof without exposing identifiers or file metadata.
    /// Link a fresh fixture request to one policy, native handoff and completed writer.
    func finishedOperation(after baseline: Self, route: String, locked: Bool = false) -> String? {
        guard context.runID == baseline.context.runID, context.processNonce == baseline.context.processNonce,
              !truncated, !hasUnscopedEvents,
              let boundary = baseline.events.last?["monotonicSeconds"].flatMap(Double.init), boundary.isFinite,
              baseline.context.phase == "authenticated" else {
            return nil
        }

        if locked {
            guard context.phase == "locked", context.phaseRevision > baseline.context.phaseRevision,
                  context.authorizationGeneration > baseline.context.authorizationGeneration else {
                return nil
            }
        } else if context != baseline.context {
            return nil
        }
        let fresh = events.filter { ($0["monotonicSeconds"].flatMap(Double.init) ?? -.infinity) > boundary }
        func one(_ name: String) -> [String: String]? {
            let matches = fresh.filter { $0["event"] == name }
            return matches.count == 1 ? matches.first : nil
        }
        guard let navigation = one("fixtureNavigationRequested"), navigation["fixtureRoute"] == route,
              let request = navigation["fixtureRequest"], UUID(uuidString: request) != nil,
              let policy = one("policyDownloadAdmitted"),
              let operation = policy["operation"], UUID(uuidString: operation) != nil,
              let capability = policy["capability"], UUID(uuidString: capability) != nil,
              let handoff = one("nativeDownloadHandoff"), handoff["fixtureRoute"] == route,
              handoff["fixtureRequest"] == request, handoff["sameOrigin"] == "true", handoff["fixtureOrigin"] == "true",
              let admitted = one("transferAdmitted"), admitted["operation"] == operation,
              admitted["capability"] == capability,
              let finish = one("writerFinished"), finish["operation"] == operation else {
            return nil
        }

        if !locked, handoff["operation"] != operation {
            return nil
        }
        var ordered = [navigation, policy]
        if locked {
            guard let lock = one("automaticMediaPolicyLocked") else {
                return nil
            }

            ordered.append(lock)
        }
        ordered += [handoff, admitted, finish]
        let times = ordered.compactMap { $0["monotonicSeconds"].flatMap(Double.init) }
        guard times.count == ordered.count, times.allSatisfy(\.isFinite),
              zip(times, times.dropFirst()).allSatisfy({ $0.0 < $0.1 }) else {
            return nil
        }

        return operation
    }

    static func decode(_ value: String?) throws -> Self {
        guard let value, !value.isEmpty else {
            throw BrowserDownloadObservationError.missing
        }

        do {
            let data = Data(value.utf8)
            let observation = try JSONDecoder().decode(Self.self, from: data)
            try observation.validate()
            return observation
        } catch let error as BrowserDownloadObservationError {
            throw error
        } catch {
            throw BrowserDownloadObservationError.malformed
        }
    }

    func validate() throws {
        try library?.validate(for: context)
        let phases: Set = [
            "loading",
            "unconfigured",
            "unavailable",
            "setup",
            "locked",
            "authentication",
            "authenticated",
        ]
        guard schemaVersion == 2,
              UUID(uuidString: context.runID) != nil,
              phases.contains(context.phase), discardedEventCount >= 0,
              context.phase == "authenticated" || mountedTabID == nil,
              events.count <= Self.maximumEventCount,
              !truncated,
              !hasUnscopedEvents,
              events.allSatisfy({ $0["runID"] == context.runID && $0["event"]?.isEmpty == false })
        else {
            throw BrowserDownloadObservationError.malformed
        }
    }
}

enum BrowserDownloadObservationError: Error, Equatable, Sendable {
    case missing
    case malformed
    case stale
    case unavailable
    case failed
    case invalidated
    case interrupted
    case deadlineExceeded
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

/// One UI launch owns one reader. Only verified samples advance its context.
@MainActor
final class BrowserDownloadPassiveReader {
    enum WaitResult { case completed, timedOut, interrupted }

    private let processNonce: UUID
    private var previous: BrowserDownloadObservationContext?

    private final class PollState {
        var result: Result<BrowserDownloadPassiveObservation, Error>?
        var pending = BrowserDownloadObservationError.deadlineExceeded
    }

    init(processNonce: UUID) {
        self.processNonce = processNonce
    }

    func validate(_ sample: BrowserDownloadPassiveObservation) throws {
        try sample.validate()
        let context = sample.context
        guard context.processNonce == processNonce, context.phase != "authentication" else {
            throw BrowserDownloadObservationError.stale
        }

        if let previous {
            guard context.runID == previous.runID,
                  context.authorizationGeneration >= previous.authorizationGeneration,
                  context.resourceGeneration >= previous.resourceGeneration,
                  context.ingestionGeneration >= previous.ingestionGeneration,
                  context.phaseRevision >= previous.phaseRevision,
                  context.phase == previous.phase || context.phaseRevision > previous.phaseRevision else {
                throw BrowserDownloadObservationError.stale
            }
        }
        previous = context
    }

    private func readAndMatch(
        sample: () throws -> BrowserDownloadPassiveObservation,
        matching: (BrowserDownloadPassiveObservation) throws -> Bool,
        checkBudget: () throws -> Void,
    ) throws -> (sample: BrowserDownloadPassiveObservation, matched: Bool) {
        try checkBudget()
        let sampleValue = try sample()
        try checkBudget()
        try validate(sampleValue)
        let matched = try matching(sampleValue)
        return (sampleValue, matched)
    }

    private func checkBudget(
        deadline: BrowserDownloadObservationDeadline,
        now: () -> TimeInterval,
        interrupted: () -> Bool,
    ) throws {
        guard !interrupted() else {
            throw BrowserDownloadObservationError.interrupted
        }
        guard deadline.remaining(at: now()) > 0 else {
            throw BrowserDownloadObservationError.deadlineExceeded
        }
    }

    private func poll(
        state: PollState,
        sample: () throws -> BrowserDownloadPassiveObservation,
        matching: (BrowserDownloadPassiveObservation) throws -> Bool,
        checkBudget: () throws -> Void,
    ) -> Bool {
        if state.result != nil {
            return true
        }
        do {
            let evaluation = try readAndMatch(
                sample: sample,
                matching: matching,
                checkBudget: checkBudget,
            )
            state.pending = .deadlineExceeded
            if evaluation.matched {
                state.result = .success(evaluation.sample)
            }
        } catch let error as BrowserDownloadObservationError {
            if error == .missing {
                state.pending = .missing
            } else {
                state.result = .failure(error)
            }
        } catch {
            state.result = .failure(error)
        }
        return state.result != nil
    }

    private func resolveWaitResult(
        _ waitResult: WaitResult,
        state: PollState,
        interrupted: () -> Bool,
    ) throws {
        switch waitResult {
        case .interrupted:
            throw BrowserDownloadObservationError.interrupted
        case .timedOut:
            if case let .failure(error) = state.result {
                throw error
            }
            if interrupted() {
                throw BrowserDownloadObservationError.interrupted
            }
            throw state.pending
        case .completed:
            break
        }
    }

    func read(
        now: @escaping () -> TimeInterval,
        interrupted: @escaping () -> Bool,
        sample: @escaping () throws -> BrowserDownloadPassiveObservation,
        matching: @escaping (BrowserDownloadPassiveObservation) throws -> Bool,
        wait: (TimeInterval, @escaping @MainActor () -> Bool) -> WaitResult,
    ) throws -> BrowserDownloadPassiveObservation {
        let deadline = BrowserDownloadObservationDeadline(start: now())
        let state = PollState()
        let checkBudget = { [self] in
            try self.checkBudget(deadline: deadline, now: now, interrupted: interrupted)
        }
        let poll: @MainActor () -> Bool = { [self] in
            self.poll(
                state: state,
                sample: sample,
                matching: matching,
                checkBudget: checkBudget,
            )
        }
        if !poll() {
            let remaining = deadline.remaining(at: now())
            guard remaining > 0 else {
                throw state.pending
            }

            try resolveWaitResult(wait(remaining, poll), state: state, interrupted: interrupted)
        }
        guard let result = state.result else {
            throw state.pending
        }

        let value = try result.get()
        try checkBudget()
        return value
    }
}

/// Redacted append-only evidence; no request URLs, credentials, filenames or downloaded content.
/// Export Documents/browser-download-production-events.jsonl from the standalone app's data container.
@MainActor
final class BrowserDownloadProductionEvidence {
    private static let libraryEvents: Set = ["libraryStartup", "acceptedLibraryStorage", "canonicalLibrarySnapshot"]
    private var lastCompatibilityAttempt: BrowserDownloadLibraryObservation?
    private let preservesTransferMilestones: Bool
    private let url: URL

    init(
        preservesTransferMilestones: Bool,
        url: URL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("browser-download-production-events.jsonl"),
    ) {
        self.preservesTransferMilestones = preservesTransferMilestones
        self.url = url
    }

    private let origin = ProcessInfo.processInfo.systemUptime
    private let timestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    /// Current timestamp on the same monotonic clock used by qualification events.
    var currentMonotonicSeconds: String {
        monotonicSeconds(forUptime: ProcessInfo.processInfo.systemUptime)
    }

    /// Converts a server uptime sample onto the event recorder's monotonic timeline.
    func monotonicSeconds(forUptime uptime: TimeInterval) -> String {
        String(uptime - origin)
    }

    let runID = UUID().uuidString
    private var observations: [[String: String]] = []
    private(set) var discardedEventCount = 0
    // swiftlint:disable unused_declaration
    var observationEvents: [[String: String]] {
        guard lastCompatibilityAttempt != nil else {
            return observations
        }

        return observations.filter { !Self.libraryEvents.contains($0["event"] ?? "") }
    }

    // swiftlint:enable unused_declaration

    private var latestByRegistration: [String: [String: String]] = [:]

    /// Latest callback per mounted Root registration; unregister events remove stale entries.
    var latestCoordinatorObservations: [[String: String]] { // swiftlint:disable:this unused_declaration
        latestByRegistration.keys.sorted().compactMap { latestByRegistration[$0] }
    }

    /// Actual layout-confirmation callbacks, kept distinct from a later geometry census capture.
    var rootLayoutObservations: [[String: String]] { // swiftlint:disable:this unused_declaration
        observations.filter { $0["event"] == "rootLayoutConfirmed" }
    }

    /// Bounded XCUI copy of the same real observations written to the complete JSONL document.
    func observationsJSON(authenticated: Bool) -> String {
        let visible = authenticated ? observations : observations.filter { $0["event"] != "canonicalLibrarySnapshot" }
        guard let data = try? JSONSerialization.data(withJSONObject: visible, options: [.sortedKeys]) else {
            return "[]"
        }

        return String(decoding: data, as: UTF8.self)
    }

    /// Returns the latest request outcome, allowing physical qualification to read it without
    /// tapping a control that could change which app window is foreground.
    func latestSceneRequestJSON() -> String? { // swiftlint:disable:this unused_declaration
        let requestEvents: Set = ["sceneRequested", "sceneRequestFailed", "sceneRequestUnsupported"]
        guard let observation = observations.last(where: { requestEvents.contains($0["event"] ?? "") }),
              let data = try? JSONSerialization.data(withJSONObject: observation, options: [.sortedKeys])
        else {
            return nil
        }

        return String(decoding: data, as: UTF8.self)
    }

    // swiftlint:disable unused_declaration
    /// Publish a storage milestone only after its validated record has reached the operator export.
    func recordLibrary(
        _ sample: BrowserDownloadLibraryObservation,
        current: BrowserDownloadObservationContext,
        physicalCompatibility: Bool,
    ) {
        guard physicalCompatibility, sample.outcome == .complete, sample != lastCompatibilityAttempt,
              sample.context.runID == runID,
              sample.fields["processID"] == String(ProcessInfo.processInfo.processIdentifier),
              (try? sample.validate(for: current)) != nil, let event = sample.fields["event"] else {
            return
        }

        // A failing flush may already have written the line. Replaying this publication could duplicate it.
        lastCompatibilityAttempt = sample
        record(event, sample.fields, synchronize: true)
    }

    // swiftlint:enable unused_declaration

    func record(_ event: String, _ fields: [String: String]) { // swiftlint:disable:this unused_declaration
        record(event, fields, synchronize: false)
    }

    private func record(_ event: String, _ fields: [String: String], synchronize: Bool) {
        var object = fields
        object["event"] = event
        object["runID"] = runID
        object["processID"] = String(ProcessInfo.processInfo.processIdentifier)
        object["wallTime"] = timestampFormatter.string(from: Date())
        object["monotonicSeconds"] = currentMonotonicSeconds
        let written = append(object, synchronize: synchronize)
        guard written || !synchronize else {
            return
        }

        if let registration = fields["registration"] {
            if event == "rootUnregistered" {
                latestByRegistration.removeValue(forKey: registration)
            } else {
                latestByRegistration[registration] = object
            }
        }
        observations.append(object)
        if observations.count > 256 {
            discardedEventCount += 1
            // Frequent progress snapshots must not evict this run's admission and Lock witnesses.
            // The UI copy stays bounded; the JSONL file still receives every observation.
            if preservesTransferMilestones {
                let milestones: Set = [
                    "fixtureNavigationRequested",
                    "policyDownloadAdmitted",
                    "pendingPolicyLockApplied",
                    "nativeDownloadHandoff",
                    "transferAdmitted",
                    "qualificationScenePhaseChanged",
                    "finiteResponseReleaseRequested",
                    "finiteResponseReleaseResult",
                    "finiteResponseCompleted",
                    "nativePostLockProgress",
                    "writerFinished",
                    "writerFailed",
                    "hiddenCompletion",
                    "retainedCompletionReconciled",
                    "nativeCancellationRequested",
                    "writerCancellationAcknowledged",
                    "pendingTransferCancelled",
                    "cleanupRemoval",
                    "cleanupInjectedFailure",
                    "scratchFailure",
                ]
                let routine = observations.firstIndex {
                    let observedEvent = $0["event"] ?? ""
                    return !milestones.contains(observedEvent) && !observedEvent.hasPrefix("slowKnown")
                }
                observations.remove(at: routine ?? 0)
            } else {
                observations.removeFirst(observations.count - 256)
            }
        }
    }

    private func append(_ object: [String: String], synchronize: Bool) -> Bool {
        do {
            var data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            data.append(0x0a)
            let existing = FileManager.default.fileExists(atPath: url.path)
            if !existing {
                try data.write(to: url, options: [.atomic])
                if !synchronize {
                    return true
                }
            }
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            if existing {
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
            }
            if synchronize {
                try handle.synchronize()
            }
            return true
        } catch {
            return false
        }
    }
}
