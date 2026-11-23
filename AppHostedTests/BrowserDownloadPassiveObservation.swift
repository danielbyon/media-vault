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

/// A host diagnostic record contains only the status fields needed to explain a Library read.
struct BrowserDownloadHostDiagnosticRecord: Codable, Equatable, Sendable {
    enum Event: String, Codable, Sendable {
        case libraryReadEligibilityChanged
        case libraryReadScheduled
        case libraryReadCancelled
        case libraryReadOutcome
        case contextInvalidated
        case scenePhaseChanged
    }

    enum RootPhase: String, Codable, Sendable {
        case authentication
        case locked
        case authenticated
        case other
    }

    enum ScenePhase: String, Codable, Sendable {
        case active
        case inactive
        case background
        case other
    }

    enum Outcome: String, Codable, Sendable {
        case complete
        case unavailable
        case invalidated
        case failed
        case ineligible
    }

    enum ReadStatus: String, Codable, Sendable {
        case scheduled
        case cancelled
        case complete
        case unavailable
        case invalidated
        case failed
        case ineligible
    }

    let ordinal: UInt32
    let event: Event
    let sceneLabel: String?
    let activeScene: Bool?
    let storageAvailable: Bool?
    let rootPhase: RootPhase?
    let rootEligible: Bool?
    let readEligible: Bool?
    let scenePhase: ScenePhase?
    let outcome: Outcome?
    let readSequence: UInt32?
    let contextMatches: Bool?

    init(
        ordinal: UInt32,
        event: Event,
        sceneLabel: String?,
        activeScene: Bool? = nil,
        storageAvailable: Bool? = nil,
        rootPhase: RootPhase? = nil,
        rootEligible: Bool? = nil,
        readEligible: Bool? = nil,
        scenePhase: ScenePhase? = nil,
        outcome: Outcome? = nil,
        readSequence: UInt32? = nil,
        contextMatches: Bool? = nil,
    ) {
        self.ordinal = ordinal
        self.event = event
        self.sceneLabel = sceneLabel
        self.activeScene = activeScene
        self.storageAvailable = storageAvailable
        self.rootPhase = rootPhase
        self.rootEligible = rootEligible
        self.readEligible = readEligible
        self.scenePhase = scenePhase
        self.outcome = outcome
        self.readSequence = readSequence
        self.contextMatches = contextMatches
    }
}

/// A separate, bounded channel for status-only diagnostics from the standalone host.
/// Scene labels are process-local aliases; records contain no Library fields or session IDs.
struct BrowserDownloadHostDiagnostics: Codable, Equatable, Sendable {
    static let maximumRecordCount = 64
    static let maximumEncodedByteCount = 8_192

    struct CurrentRead: Codable, Equatable, Sendable {
        let sequence: UInt32
        let sceneLabel: String?
        let status: BrowserDownloadHostDiagnosticRecord.ReadStatus
        let contextMatches: Bool?
    }

    private enum CodingKeys: String, CodingKey {
        case truncated
        case records
        case currentRead
    }

    private(set) var truncated: Bool
    private(set) var records: [BrowserDownloadHostDiagnosticRecord]
    private(set) var currentRead: CurrentRead?

    init(
        records: [BrowserDownloadHostDiagnosticRecord] = [],
        truncated: Bool = false,
        currentRead: CurrentRead? = nil,
    ) {
        self.truncated = truncated || records.count > Self.maximumRecordCount
        self.records = Array(records.suffix(Self.maximumRecordCount))
        self.currentRead = currentRead
        enforceBounds()
    }

    mutating func append(_ record: BrowserDownloadHostDiagnosticRecord) {
        records.append(record)
        enforceBounds()
    }

    mutating func updateCurrentRead(_ currentRead: CurrentRead) {
        self.currentRead = currentRead
        enforceBounds()
    }

    func validate() throws {
        let validSceneLabels = records.allSatisfy { Self.isValidSceneLabel($0.sceneLabel) }
        guard records.count <= Self.maximumRecordCount, validSceneLabels,
              Self.isValidSceneLabel(currentRead?.sceneLabel),
              Self.encodedByteCount(of: self) <= Self.maximumEncodedByteCount else {
            throw BrowserDownloadObservationError.malformed
        }
    }

    private mutating func enforceBounds() {
        var discardedRecords = false
        while records.count > Self.maximumRecordCount
            || Self.encodedByteCount(of: self) > Self.maximumEncodedByteCount {
            guard !records.isEmpty else {
                break
            }

            records.removeFirst()
            discardedRecords = true
        }
        if discardedRecords {
            truncated = true
        }
    }

    private static func encodedByteCount(of diagnostics: Self) -> Int {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(diagnostics) else {
            return .max
        }

        return data.count
    }

    private static func isValidSceneLabel(_ label: String?) -> Bool {
        guard let label else {
            return true
        }

        let prefix = "scene-"
        let suffix = label.dropFirst(prefix.count)
        return label.hasPrefix(prefix) && !suffix.isEmpty && suffix.count <= 10
            && suffix.unicodeScalars.allSatisfy { (48 ... 57).contains($0.value) }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let incoming = try container.decode([BrowserDownloadHostDiagnosticRecord].self, forKey: .records)
        currentRead = try container.decodeIfPresent(CurrentRead.self, forKey: .currentRead)
        truncated = try container.decode(Bool.self, forKey: .truncated) || incoming.count > Self.maximumRecordCount
        records = Array(incoming.suffix(Self.maximumRecordCount))
        enforceBounds()
    }
}

/// Keeps standalone-host diagnostics out of the production observation ledger.
@MainActor
final class BrowserDownloadHostDiagnosticRecorder {
    struct ReadTicket: Equatable {
        fileprivate let ordinal: UInt32
        fileprivate let sceneLabel: String?
    }

    private struct Eligibility: Equatable {
        let activeScene: Bool
        let storageAvailable: Bool
        let rootPhase: BrowserDownloadHostDiagnosticRecord.RootPhase
        let rootEligible: Bool
        let readEligible: Bool
    }

    private enum EligibilityScope: Hashable {
        case process
        case scene(String)
    }

    private(set) var snapshot = BrowserDownloadHostDiagnostics()
    private var nextOrdinal: UInt32 = 1
    private var nextSceneNumber: UInt32 = 1
    private var nextReadTicket: UInt32 = 1
    private var activeRead: ReadTicket?
    private var lastEligibilityByScope: [EligibilityScope: Eligibility] = [:]

    func makeSceneLabel() -> String {
        defer { nextSceneNumber &+= 1 }
        return "scene-\(nextSceneNumber)"
    }

    func recordEligibility(
        sceneLabel: String?,
        activeScene: Bool,
        storageAvailable: Bool,
        rootPhase: BrowserDownloadHostDiagnosticRecord.RootPhase,
        readEligible: Bool,
    ) {
        let eligibility = Eligibility(
            activeScene: activeScene,
            storageAvailable: storageAvailable,
            rootPhase: rootPhase,
            rootEligible: rootPhase == .locked || rootPhase == .authenticated,
            readEligible: readEligible,
        )
        let scope: EligibilityScope =
            if let sceneLabel {
                .scene(sceneLabel)
            } else {
                .process
            }
        guard eligibility != lastEligibilityByScope[scope] else {
            return
        }

        lastEligibilityByScope[scope] = eligibility
        append(
            .libraryReadEligibilityChanged,
            sceneLabel: sceneLabel,
            activeScene: activeScene,
            storageAvailable: storageAvailable,
            rootPhase: rootPhase,
            rootEligible: eligibility.rootEligible,
            readEligible: readEligible,
        )
    }

    func recordScenePhase(_ phase: BrowserDownloadHostDiagnosticRecord.ScenePhase, sceneLabel: String) {
        append(.scenePhaseChanged, sceneLabel: sceneLabel, scenePhase: phase)
    }

    func recordRead(
        _ event: BrowserDownloadHostDiagnosticRecord.Event,
        sceneLabel: String?,
        outcome: BrowserDownloadHostDiagnosticRecord.Outcome? = nil,
    ) {
        switch event {
        case .libraryReadScheduled:
            _ = scheduleLibraryRead(sceneLabel: sceneLabel)
        case .libraryReadCancelled:
            cancelActiveLibraryRead()
        case .contextInvalidated:
            if let activeRead {
                recordContextInvalidated(for: activeRead)
            } else {
                append(event, sceneLabel: sceneLabel, outcome: outcome)
            }
        case .libraryReadOutcome:
            if let activeRead {
                recordReadOutcome(outcome, for: activeRead)
            } else {
                append(event, sceneLabel: sceneLabel, outcome: outcome)
            }
        default:
            append(event, sceneLabel: sceneLabel, outcome: outcome)
        }
    }

    func scheduleLibraryRead(sceneLabel: String?) -> ReadTicket {
        let ticket = ReadTicket(ordinal: nextReadTicket, sceneLabel: sceneLabel)
        nextReadTicket &+= 1
        activeRead = ticket
        snapshot.updateCurrentRead(.init(
            sequence: ticket.ordinal,
            sceneLabel: ticket.sceneLabel,
            status: .scheduled,
            contextMatches: nil,
        ))
        append(.libraryReadScheduled, sceneLabel: ticket.sceneLabel, readSequence: ticket.ordinal)
        return ticket
    }

    func cancelActiveLibraryRead(contextMatches: Bool? = nil) {
        guard let activeRead else {
            return
        }

        self.activeRead = nil
        snapshot.updateCurrentRead(.init(
            sequence: activeRead.ordinal,
            sceneLabel: activeRead.sceneLabel,
            status: .cancelled,
            contextMatches: contextMatches,
        ))
        append(
            .libraryReadCancelled,
            sceneLabel: activeRead.sceneLabel,
            readSequence: activeRead.ordinal,
            contextMatches: contextMatches,
        )
    }

    func recordContextInvalidated(for ticket: ReadTicket, contextMatches: Bool? = nil) {
        append(
            .contextInvalidated,
            sceneLabel: ticket.sceneLabel,
            outcome: .invalidated,
            readSequence: ticket.ordinal,
            contextMatches: contextMatches,
        )
        if activeRead == ticket {
            snapshot.updateCurrentRead(.init(
                sequence: ticket.ordinal,
                sceneLabel: ticket.sceneLabel,
                status: .invalidated,
                contextMatches: contextMatches,
            ))
        }
    }

    func recordReadOutcome(
        _ outcome: BrowserDownloadHostDiagnosticRecord.Outcome?,
        for ticket: ReadTicket,
        contextMatches: Bool? = nil,
    ) {
        append(
            .libraryReadOutcome,
            sceneLabel: ticket.sceneLabel,
            outcome: outcome,
            readSequence: ticket.ordinal,
            contextMatches: contextMatches,
        )
        if activeRead == ticket {
            snapshot.updateCurrentRead(.init(
                sequence: ticket.ordinal,
                sceneLabel: ticket.sceneLabel,
                status: readStatus(for: outcome),
                contextMatches: contextMatches,
            ))
            activeRead = nil
        }
    }

    private func readStatus(for outcome: BrowserDownloadHostDiagnosticRecord.Outcome?)
        -> BrowserDownloadHostDiagnosticRecord.ReadStatus {
        switch outcome {
        case .complete:
            .complete
        case .unavailable:
            .unavailable
        case .invalidated:
            .invalidated
        case .failed:
            .failed
        case .ineligible:
            .ineligible
        case nil:
            .failed
        }
    }

    private func append(
        _ event: BrowserDownloadHostDiagnosticRecord.Event,
        sceneLabel: String? = nil,
        activeScene: Bool? = nil,
        storageAvailable: Bool? = nil,
        rootPhase: BrowserDownloadHostDiagnosticRecord.RootPhase? = nil,
        rootEligible: Bool? = nil,
        readEligible: Bool? = nil,
        scenePhase: BrowserDownloadHostDiagnosticRecord.ScenePhase? = nil,
        outcome: BrowserDownloadHostDiagnosticRecord.Outcome? = nil,
        readSequence: UInt32? = nil,
        contextMatches: Bool? = nil,
    ) {
        snapshot.append(.init(
            ordinal: nextOrdinal,
            event: event,
            sceneLabel: sceneLabel,
            activeScene: activeScene,
            storageAvailable: storageAvailable,
            rootPhase: rootPhase,
            rootEligible: rootEligible,
            readEligible: readEligible,
            scenePhase: scenePhase,
            outcome: outcome,
            readSequence: readSequence,
            contextMatches: contextMatches,
        ))
        nextOrdinal &+= 1
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
    var hostDiagnostics: BrowserDownloadHostDiagnostics? = nil
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
        hostDiagnostics: BrowserDownloadHostDiagnostics? = nil,
    ) {
        schemaVersion = 2
        self.library = library
        self.hostDiagnostics = hostDiagnostics
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
            let root = try JSONSerialization.jsonObject(with: data)
            let rootObject = root as? [String: Any]
            let hasReadoutEnvelope = rootObject?.keys.contains("observation") == true
                || rootObject?.keys.contains("hostDiagnostics") == true
            if hasReadoutEnvelope {
                let readout = try JSONDecoder().decode(BrowserDownloadObservationReadout.self, from: data)
                var observation = readout.observation
                observation.hostDiagnostics = readout.hostDiagnostics
                try observation.validate()
                return observation
            }

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
        try hostDiagnostics?.validate()
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

/// Keeps standalone host diagnostics beside the passive observation payload.
struct BrowserDownloadObservationReadout: Codable, Sendable {
    let observation: BrowserDownloadPassiveObservation
    let hostDiagnostics: BrowserDownloadHostDiagnostics?
}

/// Summarizes a timed-out qualification wait without attaching the passive event ledger.
struct BrowserDownloadWaitFailureDiagnostics: Codable, Equatable, Sendable {
    struct ExcludedTerminalEventCounts: Codable, Equatable, Sendable {
        let cancellations: UInt8
        let failures: UInt8
    }

    enum Wait: String, Codable, Sendable {
        case lockedPNG
        case delayedHandoff
        case coldStartup
    }

    enum ReadOutcome: String, Codable, Sendable {
        case sampleAvailable
        case sampleReadMissing
        case sampleUnvalidated
        case sampleUnavailable
    }

    enum ErrorClass: String, Codable, Sendable {
        case missing
        case malformed
        case stale
        case unavailable
        case failed
        case invalidated
        case interrupted
        case deadlineExceeded

        init(_ error: BrowserDownloadObservationError) {
            switch error {
            case .missing:
                self = .missing
            case .malformed:
                self = .malformed
            case .stale:
                self = .stale
            case .unavailable:
                self = .unavailable
            case .failed:
                self = .failed
            case .invalidated:
                self = .invalidated
            case .interrupted:
                self = .interrupted
            case .deadlineExceeded:
                self = .deadlineExceeded
            }
        }
    }

    enum ValidationStatus: String, Codable, Sendable {
        case notAttempted
        case pending
        case validated
        case failed
    }

    struct HostDiagnosticsStatus: Codable, Equatable, Sendable {
        let available: Bool
        let sourcePollSequence: UInt64?
        let ageInPolls: UInt64?
        let stale: Bool?

        static let unavailable = Self(
            available: false,
            sourcePollSequence: nil,
            ageInPolls: nil,
            stale: nil,
        )
    }

    enum Milestone: String, Codable, Sendable {
        case navigation
        case policyAdmission
        case lock
        case nativeHandoff
        case transferAdmission
        case writerFinish
        case postLockProgress
        case hiddenCompletion
        case transferCompletion
    }

    struct ContextStatus: Codable, Equatable, Sendable {
        let launchMatchesExpected: Bool?
        let runMatchesBaseline: Bool?
        let phaseMatchesExpected: Bool?
        let phaseRevisionMatchesBaseline: Bool?
        let phaseRevisionAdvanced: Bool?
        let authorizationGenerationMatchesBaseline: Bool?
        let authorizationGenerationAdvanced: Bool?
        let resourceGenerationMatchesBaseline: Bool?
        let ingestionGenerationMatchesBaseline: Bool?
        let baselineEventPrefixStable: Bool?
    }

    struct MilestoneStatus: Codable, Equatable, Sendable {
        let milestone: Milestone
        let present: Bool
        let unique: Bool
        let timestampValid: Bool?
        let orderedAfterPrevious: Bool?
        let correlationValid: Bool?
        let predicateValid: Bool?
    }

    struct LibraryStatus: Codable, Equatable, Sendable {
        let present: Bool
        let outcome: BrowserDownloadLibraryObservation.Outcome?
        let sampleValid: Bool?
        let contextMatches: Bool?
        let expectedEventMatches: Bool?
        let stagingProofMatches: Bool?

        static var absent: Self {
            .init(
                present: false,
                outcome: nil,
                sampleValid: nil,
                contextMatches: nil,
                expectedEventMatches: nil,
                stagingProofMatches: nil,
            )
        }
    }

    enum Reason: String, Codable, Hashable, Sendable {
        case sampleUnavailable
        case rootPhaseMismatch
        case contextMismatch
        case generationMismatch
        case missingMilestone
        case conflictingMilestones
        case milestoneOrderMismatch
        case librarySampleMissing
        case libraryNonComplete
        case libraryInvalidated
        case contextInvalidated
        case acceptedStorageEventMismatch
        case stagingProofMismatch
        case correlationWitnessMissing
        case baselineEventPrefixMismatch
        case librarySampleInvalid
        case navigationMissing
        case navigationPredicateMismatch
        case policyAdmissionMissing
        case policyAdmissionPredicateMismatch
        case lockMissing
        case lockPredicateMismatch
        case handoffPredicateMismatch
        case transferAdmissionMissing
        case transferAdmissionPredicateMismatch
        case writerFinishMissing
        case writerFinishPredicateMismatch
        case nativeHandoffMissing
        case postLockProgressMissing
        case progressPredicateMismatch
        case progressOrderMismatch
        case progressOrderUnverifiable
        case conflictingProgress
        case conflictingTimestamps
        case invalidTimestamp
        case hiddenCompletionMissing
        case hiddenCompletionPredicateMismatch
        case transferCompletionMissing
        case correlationMismatch
        case transferIncomplete
        case cancellationObserved
        case failureObserved
        case libraryStartupMismatch
        case hostDiagnosticsUnavailable
        case waitConditionUnmet
        case deadlineExpiredAfterMatch
    }

    private struct EventGroup {
        let milestone: Milestone
        let records: [[String: String]]
        let correlationValid: Bool?
        let predicateValid: Bool?
    }

    private struct DelayedHandoffEvents {
        let navigation: [[String: String]]
        let requestID: String?
        let operation: String?
        let policy: [[String: String]]
        let lock: [[String: String]]
        let handoff: [[String: String]]
        let admission: [[String: String]]
        let finish: [[String: String]]
        let hidden: [[String: String]]
        let progress: [[String: String]]
        let cancellations: [[String: String]]
        let failures: [[String: String]]
        let excludedCancellations: UInt8
        let excludedFailures: UInt8
    }

    let wait: Wait
    var errorClass: ErrorClass?
    let readOutcome: ReadOutcome
    let matcherMatched: Bool?
    let reasons: [Reason]
    let contextStatus: ContextStatus?
    let milestones: [MilestoneStatus]
    let libraryStatus: LibraryStatus
    let hostDiagnostics: BrowserDownloadHostDiagnostics?
    let pollSequence: UInt64?
    let validationStatus: ValidationStatus?
    let validationErrorClass: ErrorClass?
    let pollFinalErrorClass: ErrorClass?
    let hostDiagnosticsStatus: HostDiagnosticsStatus
    var excludedTerminalEvents: ExcludedTerminalEventCounts? = nil

    static let maximumAttachmentByteCount = BrowserDownloadHostDiagnostics.maximumEncodedByteCount + 2_048
    private static let maximumExcludedTerminalEventCount = 64

    static func shouldAttach(for error: BrowserDownloadObservationError) -> Bool {
        switch error {
        case .missing,
             .malformed,
             .stale,
             .unavailable,
             .failed,
             .invalidated,
             .interrupted,
             .deadlineExceeded:
            true
        }
    }

    static func attachmentData(
        for failure: BrowserDownloadObservationError?,
        diagnostic: Self,
    ) -> Data? {
        guard let failure, shouldAttach(for: failure) else {
            return nil
        }

        let failureClass = ErrorClass(failure)
        var attached = diagnostic
        attached.errorClass = failureClass
        guard attached.pollFinalErrorClass == nil || attached.pollFinalErrorClass == ErrorClass(failure) else {
            return fallbackAttachmentData(for: failureClass, status: .correlationMismatch)
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(attached) else {
            return fallbackAttachmentData(for: failureClass, status: .encodingFailed)
        }
        guard data.count <= maximumAttachmentByteCount else {
            return fallbackAttachmentData(for: failureClass, status: .payloadOverLimit)
        }

        return data
    }

    private enum FallbackStatus: String {
        case correlationMismatch
        case payloadOverLimit
        case encodingFailed
    }

    private static func fallbackAttachmentData(for errorClass: ErrorClass, status: FallbackStatus) -> Data? {
        let data = Data(
            #"{"diagnosticStatus":"\#(status.rawValue)","errorClass":"\#(errorClass.rawValue)"}"#.utf8,
        )
        guard data.count <= maximumAttachmentByteCount else {
            return nil
        }

        return data
    }

    static func summarize(
        wait: Wait,
        sample: BrowserDownloadPassiveObservation?,
        baseline: BrowserDownloadPassiveObservation?,
        sampleReadMissing: Bool,
        matcherMatched: Bool?,
        expectedPhase: String? = nil,
        sampleReadSucceeded: Bool = false,
        observedContext: BrowserDownloadObservationContext? = nil,
        expectedProcessNonce: UUID? = nil,
        pollSequence: UInt64? = nil,
        validationStatus: ValidationStatus? = nil,
        validationErrorClass: ErrorClass? = nil,
        pollFinalErrorClass: ErrorClass? = nil,
        hostDiagnosticsOverride: BrowserDownloadHostDiagnostics? = nil,
        hostDiagnosticsStatusOverride: HostDiagnosticsStatus? = nil,
    ) -> Self {
        var reasonList: [Reason] = []
        let sampleAvailable = sample != nil && !sampleReadMissing
        let context = sample?.context ?? observedContext
        let readStatus: ReadOutcome =
            if sampleReadMissing {
                .sampleReadMissing
            } else if sampleAvailable {
                .sampleAvailable
            } else if sampleReadSucceeded {
                .sampleUnvalidated
            } else {
                .sampleUnavailable
            }
        if !sampleAvailable {
            append(.sampleUnavailable, to: &reasonList)
        }
        let attachedHostDiagnostics = hostDiagnosticsOverride ?? (sampleAvailable ? sample?.hostDiagnostics : nil)
        if attachedHostDiagnostics == nil {
            append(.hostDiagnosticsUnavailable, to: &reasonList)
        }

        if let sampleValue = sample {
            if let expectedPhase, sampleValue.context.phase != expectedPhase {
                append(wait == .coldStartup ? .rootPhaseMismatch : .contextMismatch, to: &reasonList)
            }
            switch wait {
            case .lockedPNG:
                lockedPNGReasons(sampleValue, baseline: baseline, reasons: &reasonList)
            case .delayedHandoff:
                delayedHandoffReasons(sampleValue, reasons: &reasonList)
            case .coldStartup:
                coldStartupReasons(sampleValue, reasons: &reasonList)
            }
        }

        if matcherMatched == true {
            append(.deadlineExpiredAfterMatch, to: &reasonList)
        }
        if reasonList.isEmpty {
            append(.waitConditionUnmet, to: &reasonList)
        }
        let contextComparison = makeContextStatus(
            context: context,
            sample: sample,
            baseline: baseline,
            expectedPhase: expectedPhase,
            expectedProcessNonce: expectedProcessNonce,
        )
        let milestoneStatus = sample.map { sampleValue in
            milestoneStatuses(for: wait, sample: sampleValue, baseline: baseline)
        } ?? []
        let expectedOperation = sample.flatMap { sampleValue in
            wait == .lockedPNG ? lockedOperation(sampleValue, baseline: baseline) : nil
        }
        let libraryComparison = sample.map { sampleValue in
            libraryStatus(for: wait, sample: sampleValue, expectedOperation: expectedOperation)
        } ?? .absent
        var terminalEventCounts: ExcludedTerminalEventCounts?
        if wait == .delayedHandoff, let sampleValue = sample {
            let delayedEventSnapshot = delayedEvents(sampleValue)
            terminalEventCounts = ExcludedTerminalEventCounts(
                cancellations: delayedEventSnapshot.excludedCancellations,
                failures: delayedEventSnapshot.excludedFailures,
            )
        }
        return Self(
            wait: wait,
            errorClass: nil,
            readOutcome: readStatus,
            matcherMatched: matcherMatched,
            reasons: reasonList,
            contextStatus: contextComparison,
            milestones: milestoneStatus,
            libraryStatus: libraryComparison,
            hostDiagnostics: attachedHostDiagnostics,
            pollSequence: pollSequence,
            validationStatus: validationStatus,
            validationErrorClass: validationErrorClass,
            pollFinalErrorClass: pollFinalErrorClass,
            hostDiagnosticsStatus: hostDiagnosticsStatusOverride ?? (attachedHostDiagnostics == nil
                ? .unavailable
                : .init(available: true, sourcePollSequence: nil, ageInPolls: nil, stale: nil)),
            excludedTerminalEvents: terminalEventCounts,
        )
    }

    static func summarize(
        wait: Wait,
        poll: BrowserDownloadObservationPollSnapshot,
        baseline: BrowserDownloadPassiveObservation?,
        expectedPhase: String? = nil,
        expectedProcessNonce: UUID? = nil,
    ) -> Self {
        let validatedSample = poll.validationStatus == .validated ? poll.sample : nil
        let hostAge = poll.hostDiagnosticsSourceSequence.map { sourceSequence in
            poll.sequence >= sourceSequence ? poll.sequence - sourceSequence : UInt64.max
        }
        let hostStatus = HostDiagnosticsStatus(
            available: poll.hostDiagnostics != nil,
            sourcePollSequence: poll.hostDiagnosticsSourceSequence,
            ageInPolls: hostAge,
            stale: poll.hostDiagnosticsSourceSequence.map { $0 != poll.sequence },
        )
        return summarize(
            wait: wait,
            sample: validatedSample,
            baseline: baseline,
            sampleReadMissing: poll.readOutcome == .sampleReadMissing,
            matcherMatched: poll.matcherMatched,
            expectedPhase: expectedPhase,
            sampleReadSucceeded: poll.readOutcome == .sampleAvailable || poll.readOutcome == .sampleUnvalidated,
            observedContext: poll.observedContext,
            expectedProcessNonce: expectedProcessNonce,
            pollSequence: poll.sequence,
            validationStatus: poll.validationStatus,
            validationErrorClass: poll.validationErrorClass,
            pollFinalErrorClass: poll.finalErrorClass,
            hostDiagnosticsOverride: poll.hostDiagnostics,
            hostDiagnosticsStatusOverride: hostStatus,
        )
    }

    private static func makeContextStatus(
        context: BrowserDownloadObservationContext?,
        sample: BrowserDownloadPassiveObservation?,
        baseline: BrowserDownloadPassiveObservation?,
        expectedPhase: String?,
        expectedProcessNonce: UUID?,
    ) -> ContextStatus? {
        guard let context else {
            return nil
        }

        let baselineContext = baseline?.context
        let expectedNonce = expectedProcessNonce ?? baselineContext?.processNonce
        let eventPrefixStable: Bool? =
            if let sample, let baseline {
                sample.events.count >= baseline.events.count
                    && Array(sample.events.prefix(baseline.events.count)) == baseline.events
            } else {
                nil
            }
        return ContextStatus(
            launchMatchesExpected: expectedNonce.map { context.processNonce == $0 },
            runMatchesBaseline: baselineContext.map { context.runID == $0.runID },
            phaseMatchesExpected: expectedPhase.map { context.phase == $0 },
            phaseRevisionMatchesBaseline: baselineContext.map { context.phaseRevision == $0.phaseRevision },
            phaseRevisionAdvanced: baselineContext.map { context.phaseRevision > $0.phaseRevision },
            authorizationGenerationMatchesBaseline: baselineContext.map {
                context.authorizationGeneration == $0.authorizationGeneration
            },
            authorizationGenerationAdvanced: baselineContext.map {
                context.authorizationGeneration > $0.authorizationGeneration
            },
            resourceGenerationMatchesBaseline: baselineContext.map {
                context.resourceGeneration == $0.resourceGeneration
            },
            ingestionGenerationMatchesBaseline: baselineContext.map {
                context.ingestionGeneration == $0.ingestionGeneration
            },
            baselineEventPrefixStable: eventPrefixStable,
        )
    }

    private static func milestoneStatuses(
        for wait: Wait,
        sample: BrowserDownloadPassiveObservation,
        baseline: BrowserDownloadPassiveObservation?,
    ) -> [MilestoneStatus] {
        switch wait {
        case .lockedPNG:
            lockedMilestoneStatuses(sample, baseline: baseline)
        case .delayedHandoff:
            delayedMilestoneStatuses(sample)
        case .coldStartup:
            []
        }
    }

    private static func makeMilestoneStatuses(_ groups: [EventGroup]) -> [MilestoneStatus] {
        var previousTime: Double?
        return groups.map { group in
            let present = !group.records.isEmpty
            let timestampValid = present
                ? group.records.allSatisfy { record in
                    timestamp(record) != nil
                        && (group.milestone != .postLockProgress
                            || record["callbackMonotonicSeconds"].flatMap(Double.init)?.isFinite == true)
                }
                : nil
            let currentTime = group.records.count == 1 ? group.records.first.flatMap(timestamp) : nil
            let ordered: Bool? =
                if group.milestone == .transferCompletion {
                    nil
                } else if let currentTime, let previousTime {
                    currentTime > previousTime
                } else {
                    nil
                }
            if group.milestone != .transferCompletion, let currentTime {
                previousTime = currentTime
            }
            return MilestoneStatus(
                milestone: group.milestone,
                present: present,
                unique: group.records.count == 1,
                timestampValid: timestampValid,
                orderedAfterPrevious: ordered,
                correlationValid: group.correlationValid,
                predicateValid: group.predicateValid,
            )
        }
    }

    private static func lockedMilestoneStatuses(
        _ sample: BrowserDownloadPassiveObservation,
        baseline: BrowserDownloadPassiveObservation?,
    ) -> [MilestoneStatus] {
        makeMilestoneStatuses(lockedGroups(sample, baseline: baseline))
    }

    private static func lockedGroups(
        _ sample: BrowserDownloadPassiveObservation,
        baseline: BrowserDownloadPassiveObservation?,
    ) -> [EventGroup] {
        let rawBoundary = baseline?.events.last?["monotonicSeconds"].flatMap(Double.init)
        let boundary = rawBoundary?.isFinite == true ? rawBoundary : nil
        let fresh = sample.events.filter { event in
            guard let time = timestamp(event) else {
                return true
            }

            return boundary.map { time > $0 } ?? true
        }
        let navigation = fresh.filter {
            $0["event"] == "fixtureNavigationRequested" && $0["fixtureRoute"] == "image"
        }
        let policy = named("policyDownloadAdmitted", in: fresh)
        let lock = named("automaticMediaPolicyLocked", in: fresh)
        let handoff = named("nativeDownloadHandoff", in: fresh)
        let admission = named("transferAdmitted", in: fresh)
        let finish = named("writerFinished", in: fresh)
        let request = navigation.count == 1 ? navigation.first?["fixtureRequest"] : nil
        let operation = policy.count == 1 ? policy.first?["operation"] : nil
        let capability = policy.count == 1 ? policy.first?["capability"] : nil
        let finishOperation = finish.count == 1 ? finish.first?["operation"] : nil
        let navValid = navigation.count == 1 && request.flatMap(UUID.init(uuidString:)) != nil
        let policyValid = policy.count == 1 && policy.first?["fixtureRequest"] == request
            && operation.flatMap(UUID.init(uuidString:)) != nil
            && capability.flatMap(UUID.init(uuidString:)) != nil
        let lockValid = lock.count == 1
            ? optionalCorrelation(lock.first, request: request, operation: operation, capability: capability)
            : nil
        let handoffValid = handoff.count == 1 && handoff.first?["fixtureRoute"] == "image"
            && handoff.first?["fixtureRequest"] == request
            && handoff.first?["sameOrigin"] == "true" && handoff.first?["fixtureOrigin"] == "true"
        let admissionValid = admission.count == 1 && admission.first?["fixtureRequest"] == request
            && admission.first?["operation"] == operation && admission.first?["capability"] == capability
        let finishValid = finish.count == 1 && finishOperation == operation
        return [
            .init(milestone: .navigation, records: navigation, correlationValid: navValid, predicateValid: navValid),
            .init(
                milestone: .policyAdmission,
                records: policy,
                correlationValid: policyValid,
                predicateValid: policyValid,
            ),
            .init(milestone: .lock, records: lock, correlationValid: lockValid, predicateValid: nil),
            .init(
                milestone: .nativeHandoff,
                records: handoff,
                correlationValid: handoffValid,
                predicateValid: handoffValid,
            ),
            .init(
                milestone: .transferAdmission,
                records: admission,
                correlationValid: admissionValid,
                predicateValid: admissionValid,
            ),
            .init(
                milestone: .writerFinish,
                records: finish,
                correlationValid: finishValid,
                predicateValid: finishValid,
            ),
        ]
    }

    private static func lockedCorrelation(_ groups: [EventGroup]) -> Bool {
        guard let navigation = uniqueRecord(groupRecords(groups, .navigation)),
              let policy = uniqueRecord(groupRecords(groups, .policyAdmission)),
              let handoff = uniqueRecord(groupRecords(groups, .nativeHandoff)),
              let admission = uniqueRecord(groupRecords(groups, .transferAdmission)),
              let finish = uniqueRecord(groupRecords(groups, .writerFinish)) else {
            return false
        }

        let request = navigation["fixtureRequest"]
        let operation = policy["operation"]
        let capability = policy["capability"]
        return navigation["fixtureRoute"] == "image"
            && request.flatMap(UUID.init(uuidString:)) != nil
            && policy["fixtureRequest"] == request
            && operation.flatMap(UUID.init(uuidString:)) != nil
            && capability.flatMap(UUID.init(uuidString:)) != nil
            && handoff["fixtureRoute"] == "image"
            && handoff["fixtureRequest"] == request
            && handoff["sameOrigin"] == "true"
            && handoff["fixtureOrigin"] == "true"
            && admission["fixtureRequest"] == request
            && admission["operation"] == operation
            && admission["capability"] == capability
            && finish["operation"] == operation
    }

    private static func lockedOperation(
        _ sample: BrowserDownloadPassiveObservation,
        baseline: BrowserDownloadPassiveObservation?,
    ) -> String? {
        let groups = lockedGroups(sample, baseline: baseline)
        guard lockedCorrelation(groups) else {
            return nil
        }

        return uniqueRecord(groupRecords(groups, .writerFinish))?["operation"]
    }

    private static func delayedEvents(_ sample: BrowserDownloadPassiveObservation) -> DelayedHandoffEvents {
        let runEvents = sample.events.filter { $0["runID"] == sample.context.runID }
        let navigation = runEvents.filter {
            $0["event"] == "fixtureNavigationRequested" && $0["fixtureRoute"] == "delayed-handoff"
        }
        let requestID = navigation.count == 1 ? navigation.first?["fixtureRequest"] : nil
        let requestIsValid = requestID.flatMap(UUID.init(uuidString:)) != nil
        let requestScoped = requestIsValid
            ? runEvents.filter { $0["fixtureRequest"] == requestID }
            : []
        let policy = named("policyDownloadAdmitted", in: requestScoped)
        let admission = named("transferAdmitted", in: requestScoped)
        let operationCandidate = admission.count == 1 ? admission.first?["operation"] : policy.first?["operation"]
        let operation = operationCandidate.flatMap(UUID.init(uuidString:)) == nil ? nil : operationCandidate
        let scoped = runEvents.filter { event in
            guard requestIsValid || operation != nil else {
                return false
            }

            let requestMatches = requestID.map { event["fixtureRequest"] == $0 } ?? false
            let operationMatches = operation.map { event["operation"] == $0 } ?? false
            guard requestMatches || operationMatches else {
                return false
            }

            if let eventRequest = event["fixtureRequest"], let requestID, eventRequest != requestID {
                return false
            }
            if let eventOperation = event["operation"], let operation, eventOperation != operation {
                return false
            }
            return true
        }
        let cancellationNames = [
            "nativeCancellationRequested",
            "pendingTransferCancelled",
            "writerCancellationAcknowledged",
        ]
        let failureNames = ["writerFailed", "transferFailed", "cleanupRemoval"]
        let scopedCancellations = scoped.filter { cancellationNames.contains($0["event"] ?? "") }
        let scopedFailures = scoped.filter { failureNames.contains($0["event"] ?? "") }
        let excludedCancellations = runEvents.filter {
            cancellationNames.contains($0["event"] ?? "") && !scoped.contains($0)
        }
        let excludedFailures = runEvents.filter {
            failureNames.contains($0["event"] ?? "") && !scoped.contains($0)
        }
        return DelayedHandoffEvents(
            navigation: navigation,
            requestID: requestID,
            operation: operation,
            policy: named("policyDownloadAdmitted", in: scoped),
            lock: named("pendingPolicyLockApplied", in: scoped),
            handoff: named("nativeDownloadHandoff", in: scoped),
            admission: named("transferAdmitted", in: scoped),
            finish: named("writerFinished", in: scoped),
            hidden: named("hiddenCompletion", in: scoped),
            progress: named("nativePostLockProgress", in: scoped),
            cancellations: scopedCancellations,
            failures: scopedFailures,
            excludedCancellations: UInt8(min(excludedCancellations.count, Self.maximumExcludedTerminalEventCount)),
            excludedFailures: UInt8(min(excludedFailures.count, Self.maximumExcludedTerminalEventCount)),
        )
    }

    private static func delayedMilestoneStatuses(_ sample: BrowserDownloadPassiveObservation) -> [MilestoneStatus] {
        let evidence = delayedEvents(sample)
        let request = evidence.requestID
        let operation = evidence.operation
        let policy = evidence.policy.first
        let lock = evidence.lock.first
        let handoff = evidence.handoff.first
        let admission = evidence.admission.first
        let finish = evidence.finish.first
        let hidden = evidence.hidden.first
        let progress = evidence.progress.first
        let capability = policy?["capability"]
        let connection = admission?["connectionID"]
        let navigationValid = evidence.navigation.count == 1
            ? request.flatMap(UUID.init(uuidString:)) != nil
                && evidence.navigation.first?["fixtureRoute"] == "delayed-handoff"
            : nil
        let policyValid = identityValid(
            policy,
            request: request,
            operation: operation,
            capability: capability,
            connection: connection,
        )
        let lockValid = identityValid(
            lock,
            request: request,
            operation: operation,
            capability: capability,
            connection: connection,
        )
        .map { $0 && lockPredicateValid(lock) }
        let handoffValid = handoff.map {
            $0["fixtureRequest"] == request && handoffPredicateValid($0)
        }
        let admissionValid = identityValid(
            admission,
            request: request,
            operation: operation,
            capability: capability,
            connection: connection,
        )
        let finishValid = identityValid(
            finish,
            request: request,
            operation: operation,
            capability: capability,
            connection: connection,
        )
        let progressValid = identityValid(
            progress,
            request: request,
            operation: operation,
            capability: capability,
            connection: connection,
        )
        .map { $0 && progressPredicateValid(progress) }
        let hiddenValid = identityValid(
            hidden,
            request: request,
            operation: operation,
            capability: capability,
            connection: connection,
        )
        .map { $0 && hiddenPredicateValid(hidden) }
        let transferComplete = delayedTransferCompletionValid(progress, hidden)
        let groups = [
            EventGroup(
                milestone: .navigation,
                records: evidence.navigation,
                correlationValid: navigationValid,
                predicateValid: navigationValid,
            ),
            EventGroup(
                milestone: .policyAdmission,
                records: evidence.policy,
                correlationValid: policyValid,
                predicateValid: policyValid,
            ),
            EventGroup(
                milestone: .lock,
                records: evidence.lock,
                correlationValid: lockValid,
                predicateValid: lock.map { lockPredicateValid($0) },
            ),
            EventGroup(
                milestone: .nativeHandoff,
                records: evidence.handoff,
                correlationValid: handoffValid,
                predicateValid: handoff.map { handoffPredicateValid($0) },
            ),
            EventGroup(
                milestone: .transferAdmission,
                records: evidence.admission,
                correlationValid: admissionValid,
                predicateValid: admissionValid,
            ),
            EventGroup(
                milestone: .postLockProgress,
                records: evidence.progress,
                correlationValid: progressValid,
                predicateValid: progress.map { progressPredicateValid($0) },
            ),
            EventGroup(
                milestone: .writerFinish,
                records: evidence.finish,
                correlationValid: finishValid,
                predicateValid: finishValid,
            ),
            EventGroup(
                milestone: .hiddenCompletion,
                records: evidence.hidden,
                correlationValid: hiddenValid,
                predicateValid: hidden.map { hiddenPredicateValid($0) },
            ),
            EventGroup(
                milestone: .transferCompletion,
                records: evidence.hidden,
                correlationValid: hiddenValid,
                predicateValid: transferComplete,
            ),
        ]
        return makeMilestoneStatuses(groups)
    }

    private static func libraryStatus(
        for wait: Wait,
        sample: BrowserDownloadPassiveObservation,
        expectedOperation: String?,
    ) -> LibraryStatus {
        guard let library = sample.library else {
            return .absent
        }

        let expectedEvent: String? =
            switch wait {
            case .lockedPNG:
                "acceptedLibraryStorage"
            case .coldStartup:
                "libraryStartup"
            case .delayedHandoff:
                nil
            }
        let sampleValid = (try? library.validate(for: sample.context)) != nil
        let stagingProofMatches: Bool? =
            if wait == .lockedPNG {
                library.fields["singleStagedFixture"] == "true"
                    && library.fields["stagingEmpty"] == "false"
                    && library.fields["authenticated"] == "false"
                    && library.fields["contentEmpty"] == "true"
                    && (expectedOperation == nil || library.fields["operation"] == expectedOperation)
            } else {
                nil
            }
        return LibraryStatus(
            present: true,
            outcome: library.outcome,
            sampleValid: sampleValid,
            contextMatches: library.context == sample.context,
            expectedEventMatches: expectedEvent.map { library.fields["event"] == $0 },
            stagingProofMatches: stagingProofMatches,
        )
    }

    private static func timestamp(_ event: [String: String]) -> Double? {
        guard let value = event["monotonicSeconds"].flatMap(Double.init), value.isFinite else {
            return nil
        }

        return value
    }

    private static func only(_ groups: [EventGroup], _ milestone: Milestone) -> [String: String]? {
        let records = groupRecords(groups, milestone)
        return records.count == 1 ? records.first : nil
    }

    private static func groupRecords(_ groups: [EventGroup], _ milestone: Milestone) -> [[String: String]] {
        groups.first { $0.milestone == milestone }?.records ?? []
    }

    private static func uniqueRecord(_ records: [[String: String]]) -> [String: String]? {
        records.count == 1 ? records.first : nil
    }

    private static func hasConflictingTimestamps(_ records: [[String: String]]) -> Bool {
        let values = records.compactMap(timestamp)
        return values.count > 1 && Set(values).count > 1
    }

    private static func appendMilestoneReasons(_ statuses: [MilestoneStatus], to reasons: inout [Reason]) {
        for status in statuses {
            if !status.present {
                append(.missingMilestone, to: &reasons)
            } else if !status.unique {
                append(.conflictingMilestones, to: &reasons)
            }
            if status.timestampValid == false {
                append(.invalidTimestamp, to: &reasons)
            }
            if status.orderedAfterPrevious == false {
                append(.milestoneOrderMismatch, to: &reasons)
            }
        }
    }

    private static func optionalCorrelation(
        _ event: [String: String]?,
        request: String?,
        operation: String?,
        capability: String?,
    ) -> Bool? {
        guard let event,
              event["fixtureRequest"] != nil || event["operation"] != nil || event["capability"] != nil else {
            return nil
        }

        return (event["fixtureRequest"] == nil || event["fixtureRequest"] == request)
            && (event["operation"] == nil || event["operation"] == operation)
            && (event["capability"] == nil || event["capability"] == capability)
    }

    private static func identityValid(
        _ event: [String: String]?,
        request: String?,
        operation: String?,
        capability: String?,
        connection: String?,
    ) -> Bool? {
        guard let event else {
            return nil
        }

        return event["fixtureRequest"] == request
            && event["operation"] == operation
            && event["capability"] == capability
            && event["connectionID"] == connection
            && request.flatMap(UUID.init(uuidString:)) != nil
            && operation.flatMap(UUID.init(uuidString:)) != nil
            && capability.flatMap(UUID.init(uuidString:)) != nil
            && connection.flatMap(UUID.init(uuidString:)) != nil
    }

    private static func lockPredicateValid(_ event: [String: String]?) -> Bool {
        guard let event,
              let before = UInt64(event["generationBefore"] ?? ""),
              let after = UInt64(event["generation"] ?? "") else {
            return false
        }

        return event["authenticated"] == "false" && event["available"] == "false"
            && event["contentEmpty"] == "true" && after > before
    }

    private static func handoffPredicateValid(_ event: [String: String]?) -> Bool {
        event?["fixtureRoute"] == "delayed-handoff" && event?["sameOrigin"] == "true"
            && event?["fixtureOrigin"] == "true"
    }

    private static func progressPredicateValid(_ event: [String: String]?) -> Bool {
        guard let event, event["authenticated"] == "false", event["available"] == "false" else {
            return false
        }

        if event["receivedBytes"] != nil || event["expectedBytes"] != nil {
            guard let received = Int(event["receivedBytes"] ?? ""),
                  let expected = Int(event["expectedBytes"] ?? "") else {
                return false
            }

            return received > 0 && received <= expected
        }
        return event["progressPositive"] == "true"
    }

    private static func hiddenPredicateValid(_ event: [String: String]?) -> Bool {
        guard let event else {
            return false
        }

        return event["authenticated"] == "false" && event["available"] == "false"
            && event["contentEmpty"] == "true"
    }

    private static func delayedTransferCompletionValid(
        _ progress: [String: String]?,
        _ hidden: [String: String]?,
    ) -> Bool {
        guard let progress, let hidden else {
            return false
        }

        if progress["receivedBytes"] != nil || progress["expectedBytes"] != nil {
            guard let received = Int(progress["receivedBytes"] ?? "") else {
                return false
            }

            return received > 0 && hidden["activeWriterCount"] == "0"
                && hidden["retainedRecordCount"] == "1"
        }
        return progress["progressPositive"] == "true" && hidden["noActiveWriters"] == "true"
            && hidden["oneRetainedCompletion"] == "true"
    }

    private static func lockedPNGReasons(
        _ sample: BrowserDownloadPassiveObservation,
        baseline: BrowserDownloadPassiveObservation?,
        reasons: inout [Reason],
    ) {
        guard let baseline else {
            append(.contextMismatch, to: &reasons)
            append(.missingMilestone, to: &reasons)
            append(.correlationWitnessMissing, to: &reasons)
            libraryProofReasons(sample, operation: nil, reasons: &reasons)
            return
        }

        if sample.context.processNonce != baseline.context.processNonce
            || sample.context.runID != baseline.context.runID {
            append(.contextMismatch, to: &reasons)
        }
        if sample.context.phase != "locked" {
            append(.contextMismatch, to: &reasons)
        }
        if sample.context.phaseRevision <= baseline.context.phaseRevision
            || sample.context.authorizationGeneration <= baseline.context.authorizationGeneration {
            append(.generationMismatch, to: &reasons)
        }

        let boundary = baseline.events.last?["monotonicSeconds"].flatMap(Double.init)
        if boundary?.isFinite != true {
            append(.contextMismatch, to: &reasons)
            append(.invalidTimestamp, to: &reasons)
        }
        let prefixStable = sample.events.count >= baseline.events.count
            && Array(sample.events.prefix(baseline.events.count)) == baseline.events
        if !prefixStable {
            append(.baselineEventPrefixMismatch, to: &reasons)
        }

        let groups = lockedGroups(sample, baseline: baseline)
        let statuses = makeMilestoneStatuses(groups)
        appendMilestoneReasons(statuses, to: &reasons)
        if groups.contains(where: { hasConflictingTimestamps($0.records) }) {
            append(.conflictingTimestamps, to: &reasons)
        }
        let correlated = lockedCorrelation(groups)
        if !correlated {
            append(.correlationMismatch, to: &reasons)
            append(.correlationWitnessMissing, to: &reasons)
        }
        let operation = correlated ? only(groups, .writerFinish)?["operation"] : nil
        libraryProofReasons(sample, operation: operation, reasons: &reasons)
    }

    private static func libraryProofReasons(
        _ sample: BrowserDownloadPassiveObservation,
        operation: String?,
        reasons: inout [Reason],
    ) {
        guard let library = sample.library else {
            append(.librarySampleMissing, to: &reasons)
            return
        }

        if library.context != sample.context {
            append(.contextMismatch, to: &reasons)
        }
        if (try? library.validate(for: sample.context)) == nil {
            append(.librarySampleInvalid, to: &reasons)
        }
        guard library.outcome == .complete else {
            append(.libraryNonComplete, to: &reasons)
            if library.outcome == .invalidated {
                append(.libraryInvalidated, to: &reasons)
            }
            return
        }

        if library.fields["event"] != "acceptedLibraryStorage" {
            append(.acceptedStorageEventMismatch, to: &reasons)
        }
        if library.fields["singleStagedFixture"] != "true"
            || library.fields["stagingEmpty"] != "false"
            || library.fields["authenticated"] != "false"
            || library.fields["contentEmpty"] != "true"
            || (operation != nil && library.fields["operation"] != operation) {
            append(.stagingProofMismatch, to: &reasons)
        }
    }

    private static func delayedHandoffReasons(
        _ sample: BrowserDownloadPassiveObservation,
        reasons: inout [Reason],
    ) {
        let evidence = delayedEvents(sample)
        let statuses = delayedMilestoneStatuses(sample)
        appendDelayedMissingReasons(evidence, to: &reasons)
        appendDelayedMilestoneReasons(statuses, to: &reasons)
        appendDelayedProgressMultiplicityReasons(evidence, to: &reasons)
        appendDelayedTimestampConflictReasons(evidence, to: &reasons)
        appendDelayedCorrelationReasons(evidence, to: &reasons)
        appendDelayedProgressOrderReasons(evidence, to: &reasons)
        appendDelayedPredicateReasons(evidence, statuses: statuses, to: &reasons)
        appendDelayedTerminalReasons(evidence, to: &reasons)
    }

    private static func appendDelayedMissingReasons(
        _ evidence: DelayedHandoffEvents,
        to reasons: inout [Reason],
    ) {
        let missing: [(Bool, Reason)] = [
            (evidence.navigation.isEmpty, .navigationMissing),
            (evidence.policy.isEmpty, .policyAdmissionMissing),
            (evidence.lock.isEmpty, .lockMissing),
            (evidence.handoff.isEmpty, .nativeHandoffMissing),
            (evidence.admission.isEmpty, .transferAdmissionMissing),
            (evidence.finish.isEmpty, .writerFinishMissing),
            (evidence.progress.isEmpty, .postLockProgressMissing),
            (evidence.hidden.isEmpty, .hiddenCompletionMissing),
        ]
        for (isMissing, reason) in missing where isMissing {
            append(reason, to: &reasons)
        }

        let transferComplete = delayedTransferCompletionValid(evidence.progress.first, evidence.hidden.first)
        if evidence.hidden.isEmpty || !transferComplete {
            append(.transferCompletionMissing, to: &reasons)
        }
        if missing.contains(where: \.0) || !transferComplete {
            append(.transferIncomplete, to: &reasons)
        }
    }

    private static func appendDelayedMilestoneReasons(
        _ statuses: [MilestoneStatus],
        to reasons: inout [Reason],
    ) {
        for status in statuses {
            if !status.unique, status.present {
                append(.conflictingMilestones, to: &reasons)
            }
            if status.timestampValid == false {
                append(.invalidTimestamp, to: &reasons)
            }
            if status.orderedAfterPrevious == false {
                append(.milestoneOrderMismatch, to: &reasons)
            }
            if status.correlationValid == false {
                append(.correlationMismatch, to: &reasons)
            }
        }
    }

    private static func appendDelayedProgressMultiplicityReasons(
        _ evidence: DelayedHandoffEvents,
        to reasons: inout [Reason],
    ) {
        if evidence.progress.count > 1 {
            append(.conflictingProgress, to: &reasons)
        }
    }

    private static func appendDelayedTimestampConflictReasons(
        _ evidence: DelayedHandoffEvents,
        to reasons: inout [Reason],
    ) {
        let groups = [
            evidence.navigation,
            evidence.policy,
            evidence.lock,
            evidence.handoff,
            evidence.admission,
            evidence.finish,
            evidence.hidden,
            evidence.progress,
        ]
        if groups.contains(where: { hasConflictingTimestamps($0) }) {
            append(.conflictingTimestamps, to: &reasons)
        }
    }

    private static func appendDelayedCorrelationReasons(
        _ evidence: DelayedHandoffEvents,
        to reasons: inout [Reason],
    ) {
        if evidence.navigation.count != 1 || evidence.requestID == nil || evidence.operation == nil {
            append(.correlationWitnessMissing, to: &reasons)
        }
    }

    private static func appendDelayedProgressOrderReasons(
        _ evidence: DelayedHandoffEvents,
        to reasons: inout [Reason],
    ) {
        guard !evidence.progress.isEmpty else {
            return
        }
        guard let progress = uniqueRecord(evidence.progress),
              timestamp(progress) != nil,
              let callbackTime = progress["callbackMonotonicSeconds"].flatMap(Double.init),
              callbackTime.isFinite,
              let lock = uniqueRecord(evidence.lock),
              let lockTime = timestamp(lock) else {
            append(.progressOrderUnverifiable, to: &reasons)
            return
        }

        if callbackTime <= lockTime {
            append(.progressOrderMismatch, to: &reasons)
            append(.milestoneOrderMismatch, to: &reasons)
        }
    }

    private static func appendDelayedPredicateReasons(
        _ evidence: DelayedHandoffEvents,
        statuses: [MilestoneStatus],
        to reasons: inout [Reason],
    ) {
        appendDelayedDirectPredicateReasons(evidence, to: &reasons)
        appendDelayedMilestonePredicateReasons(statuses, to: &reasons)
    }

    private static func appendDelayedDirectPredicateReasons(
        _ evidence: DelayedHandoffEvents,
        to reasons: inout [Reason],
    ) {
        if let lock = evidence.lock.first, !lockPredicateValid(lock) {
            append(.lockPredicateMismatch, to: &reasons)
        }
        if let handoff = evidence.handoff.first, !handoffPredicateValid(handoff) {
            append(.handoffPredicateMismatch, to: &reasons)
        }
        if let progress = evidence.progress.first, !progressPredicateValid(progress) {
            append(.progressPredicateMismatch, to: &reasons)
        }
        if let hidden = evidence.hidden.first, !hiddenPredicateValid(hidden) {
            append(.hiddenCompletionPredicateMismatch, to: &reasons)
        }
        if let navigation = evidence.navigation.first, navigation["fixtureRoute"] != "delayed-handoff" {
            append(.navigationPredicateMismatch, to: &reasons)
        }
    }

    private static func appendDelayedMilestonePredicateReasons(
        _ statuses: [MilestoneStatus],
        to reasons: inout [Reason],
    ) {
        if statuses.first(where: { $0.milestone == .policyAdmission })?.predicateValid == false {
            append(.policyAdmissionPredicateMismatch, to: &reasons)
        }
        if statuses.first(where: { $0.milestone == .transferAdmission })?.predicateValid == false {
            append(.transferAdmissionPredicateMismatch, to: &reasons)
        }
        if statuses.first(where: { $0.milestone == .writerFinish })?.predicateValid == false {
            append(.writerFinishPredicateMismatch, to: &reasons)
        }
    }

    private static func appendDelayedTerminalReasons(
        _ evidence: DelayedHandoffEvents,
        to reasons: inout [Reason],
    ) {
        if !evidence.cancellations.isEmpty {
            append(.cancellationObserved, to: &reasons)
        }
        if !evidence.failures.isEmpty {
            append(.failureObserved, to: &reasons)
        }
    }

    private static func coldStartupReasons(
        _ sample: BrowserDownloadPassiveObservation,
        reasons: inout [Reason],
    ) {
        if sample.context.phase != "locked" {
            append(.rootPhaseMismatch, to: &reasons)
        }
        if let rootPhase = sample.hostDiagnostics?.records.reversed().compactMap(\.rootPhase).first,
           rootPhase != .locked {
            append(.rootPhaseMismatch, to: &reasons)
        }
        if sample.hostDiagnostics?.records.contains(where: { $0.event == .contextInvalidated }) == true {
            append(.contextInvalidated, to: &reasons)
        }
        guard let library = sample.library else {
            append(.librarySampleMissing, to: &reasons)
            return
        }

        if library.context != sample.context {
            append(.contextMismatch, to: &reasons)
            append(.contextInvalidated, to: &reasons)
        }
        if (try? library.validate(for: sample.context)) == nil {
            append(.librarySampleInvalid, to: &reasons)
        }
        guard library.outcome == .complete else {
            append(.libraryNonComplete, to: &reasons)
            if library.outcome == .invalidated {
                append(.libraryInvalidated, to: &reasons)
                append(.contextInvalidated, to: &reasons)
            }
            return
        }

        if library.fields["event"] != "libraryStartup" {
            append(.libraryStartupMismatch, to: &reasons)
        }
    }

    private static func named(_ name: String, in events: [[String: String]]) -> [[String: String]] {
        events.filter { $0["event"] == name }
    }

    private static func append(_ reason: Reason, to reasons: inout [Reason]) {
        if !reasons.contains(reason) {
            reasons.append(reason)
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
struct BrowserDownloadObservationPollSnapshot: Sendable {
    let sequence: UInt64
    let readOutcome: BrowserDownloadWaitFailureDiagnostics.ReadOutcome
    let sample: BrowserDownloadPassiveObservation?
    let observedContext: BrowserDownloadObservationContext?
    let validationStatus: BrowserDownloadWaitFailureDiagnostics.ValidationStatus
    let validationErrorClass: BrowserDownloadWaitFailureDiagnostics.ErrorClass?
    let matcherMatched: Bool?
    let finalErrorClass: BrowserDownloadWaitFailureDiagnostics.ErrorClass?
    let hostDiagnostics: BrowserDownloadHostDiagnostics?
    let hostDiagnosticsSourceSequence: UInt64?
}

@MainActor
final class BrowserDownloadPassiveReader {
    enum WaitResult { case completed, timedOut, interrupted }

    private let processNonce: UUID
    private var previous: BrowserDownloadObservationContext?
    private var pollSequence: UInt64 = 0
    private var lastKnownHostDiagnostics: BrowserDownloadHostDiagnostics?
    private var lastHostDiagnosticsPollSequence: UInt64?
    private(set) var lastPollDiagnosticSnapshot: BrowserDownloadObservationPollSnapshot?

    private final class PollState {
        var result: Result<BrowserDownloadPassiveObservation, Error>?
        var pending = BrowserDownloadObservationError.deadlineExceeded
    }

    var lastSample: BrowserDownloadPassiveObservation? {
        guard lastPollDiagnosticSnapshot?.validationStatus == .validated else {
            return nil
        }

        return lastPollDiagnosticSnapshot?.sample
    }

    var lastReadContext: BrowserDownloadObservationContext? {
        lastPollDiagnosticSnapshot?.observedContext
    }

    var lastMatcherOutcome: Bool? {
        lastPollDiagnosticSnapshot?.matcherMatched
    }

    var lastSampleReadMissing: Bool {
        lastPollDiagnosticSnapshot?.readOutcome == .sampleReadMissing
    }

    var lastSampleReadSucceeded: Bool {
        guard let readOutcome = lastPollDiagnosticSnapshot?.readOutcome else {
            return false
        }

        return readOutcome == .sampleAvailable || readOutcome == .sampleUnvalidated
    }

    // This shared source is compiled by multiple targets; BrowserTabOverviewUITests consumes this getter.
    // swiftlint:disable:next unused_declaration
    var expectedProcessNonce: UUID {
        processNonce
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

    private func startPoll() -> UInt64 {
        if pollSequence < .max {
            pollSequence += 1
        }
        let sequence = pollSequence
        capturePoll(
            sequence: sequence,
            readOutcome: .sampleUnavailable,
            sample: nil,
            context: nil,
            validationStatus: .notAttempted,
            validationErrorClass: nil,
            matcherMatched: nil,
            finalErrorClass: nil,
        )
        return sequence
    }

    private func capturePoll(
        sequence: UInt64,
        readOutcome: BrowserDownloadWaitFailureDiagnostics.ReadOutcome,
        sample: BrowserDownloadPassiveObservation?,
        context: BrowserDownloadObservationContext?,
        validationStatus: BrowserDownloadWaitFailureDiagnostics.ValidationStatus,
        validationErrorClass: BrowserDownloadWaitFailureDiagnostics.ErrorClass?,
        matcherMatched: Bool?,
        finalErrorClass: BrowserDownloadWaitFailureDiagnostics.ErrorClass?,
    ) {
        if validationStatus == .validated, let diagnostics = sample?.hostDiagnostics {
            lastKnownHostDiagnostics = diagnostics
            lastHostDiagnosticsPollSequence = sequence
        }
        lastPollDiagnosticSnapshot = .init(
            sequence: sequence,
            readOutcome: readOutcome,
            sample: sample,
            observedContext: context,
            validationStatus: validationStatus,
            validationErrorClass: validationErrorClass,
            matcherMatched: matcherMatched,
            finalErrorClass: finalErrorClass,
            hostDiagnostics: lastKnownHostDiagnostics,
            hostDiagnosticsSourceSequence: lastHostDiagnosticsPollSequence,
        )
    }

    private func recordFinalError(_ error: Error, fallback: BrowserDownloadWaitFailureDiagnostics.ErrorClass? = nil) {
        guard let snapshot = lastPollDiagnosticSnapshot else {
            return
        }

        let errorClass = (error as? BrowserDownloadObservationError)
            .map(BrowserDownloadWaitFailureDiagnostics.ErrorClass.init) ?? fallback
        lastPollDiagnosticSnapshot = .init(
            sequence: snapshot.sequence,
            readOutcome: snapshot.readOutcome,
            sample: snapshot.sample,
            observedContext: snapshot.observedContext,
            validationStatus: snapshot.validationStatus,
            validationErrorClass: snapshot.validationErrorClass,
            matcherMatched: snapshot.matcherMatched,
            finalErrorClass: errorClass,
            hostDiagnostics: snapshot.hostDiagnostics,
            hostDiagnosticsSourceSequence: snapshot.hostDiagnosticsSourceSequence,
        )
    }

    private func readAndMatch(
        sequence: UInt64,
        sample: () throws -> BrowserDownloadPassiveObservation,
        matching: (BrowserDownloadPassiveObservation) throws -> Bool,
        checkBudget: () throws -> Void,
    ) throws -> (sample: BrowserDownloadPassiveObservation, matched: Bool) {
        try checkBudget()
        let sampleValue: BrowserDownloadPassiveObservation
        do {
            sampleValue = try sample()
        } catch let error as BrowserDownloadObservationError {
            capturePoll(
                sequence: sequence,
                readOutcome: error == .missing ? .sampleReadMissing : .sampleUnavailable,
                sample: nil,
                context: nil,
                validationStatus: .notAttempted,
                validationErrorClass: nil,
                matcherMatched: nil,
                finalErrorClass: BrowserDownloadWaitFailureDiagnostics.ErrorClass(error),
            )
            throw error
        } catch {
            capturePoll(
                sequence: sequence,
                readOutcome: .sampleUnavailable,
                sample: nil,
                context: nil,
                validationStatus: .notAttempted,
                validationErrorClass: nil,
                matcherMatched: nil,
                finalErrorClass: .failed,
            )
            throw error
        }
        capturePoll(
            sequence: sequence,
            readOutcome: .sampleUnvalidated,
            sample: sampleValue,
            context: sampleValue.context,
            validationStatus: .pending,
            validationErrorClass: nil,
            matcherMatched: nil,
            finalErrorClass: nil,
        )
        try checkBudget()
        do {
            try validate(sampleValue)
        } catch let error as BrowserDownloadObservationError {
            capturePoll(
                sequence: sequence,
                readOutcome: .sampleUnvalidated,
                sample: sampleValue,
                context: sampleValue.context,
                validationStatus: .failed,
                validationErrorClass: BrowserDownloadWaitFailureDiagnostics.ErrorClass(error),
                matcherMatched: nil,
                finalErrorClass: BrowserDownloadWaitFailureDiagnostics.ErrorClass(error),
            )
            throw error
        } catch {
            capturePoll(
                sequence: sequence,
                readOutcome: .sampleUnvalidated,
                sample: sampleValue,
                context: sampleValue.context,
                validationStatus: .failed,
                validationErrorClass: .failed,
                matcherMatched: nil,
                finalErrorClass: .failed,
            )
            throw error
        }
        capturePoll(
            sequence: sequence,
            readOutcome: .sampleAvailable,
            sample: sampleValue,
            context: sampleValue.context,
            validationStatus: .validated,
            validationErrorClass: nil,
            matcherMatched: nil,
            finalErrorClass: nil,
        )
        let matched = try matching(sampleValue)
        capturePoll(
            sequence: sequence,
            readOutcome: .sampleAvailable,
            sample: sampleValue,
            context: sampleValue.context,
            validationStatus: .validated,
            validationErrorClass: nil,
            matcherMatched: matched,
            finalErrorClass: nil,
        )
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
        let sequence = startPoll()
        do {
            let evaluation = try readAndMatch(
                sequence: sequence,
                sample: sample,
                matching: matching,
                checkBudget: checkBudget,
            )
            state.pending = .deadlineExceeded
            if evaluation.matched {
                state.result = .success(evaluation.sample)
            }
        } catch let error as BrowserDownloadObservationError {
            recordFinalError(error)
            if error == .missing {
                state.pending = .missing
            } else {
                state.result = .failure(error)
            }
        } catch {
            recordFinalError(error, fallback: .failed)
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
            recordFinalError(BrowserDownloadObservationError.interrupted)
            throw BrowserDownloadObservationError.interrupted
        case .timedOut:
            if case let .failure(error) = state.result {
                throw error
            }
            if interrupted() {
                recordFinalError(BrowserDownloadObservationError.interrupted)
                throw BrowserDownloadObservationError.interrupted
            }
            recordFinalError(state.pending)
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
        lastPollDiagnosticSnapshot = nil

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
                recordFinalError(state.pending)
                throw state.pending
            }

            try resolveWaitResult(wait(remaining, poll), state: state, interrupted: interrupted)
        }
        guard let result = state.result else {
            recordFinalError(state.pending)
            throw state.pending
        }

        let value = try result.get()
        do {
            try checkBudget()
        } catch {
            recordFinalError(error, fallback: .deadlineExceeded)
            throw error
        }
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
