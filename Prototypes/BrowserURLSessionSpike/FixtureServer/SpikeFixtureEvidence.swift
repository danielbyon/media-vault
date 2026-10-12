import CryptoKit
import Foundation

/// One server timestamp for bytes sent in a response chunk.
struct SpikeSendSample: Encodable, Sendable {
    var timestamp: Double
    var cumulativeBytes: Int
}

/// A lifecycle boundary timestamped by the host-process fixture server.
struct SpikeLifecycleMarker: Encodable, Sendable {
    var timestamp: Double
    var label: String
    var fields: [String: String]
}

/// One redacted fixture request observation.
///
/// Raw header values, cookie values, authorization values, signed tokens, and
/// request bodies are never stored. Only names, presence flags, hashes,
/// non-secret fixture values, and sanitized identifiers reach the artifact.
struct SpikeRecordedRequest: Encodable, Sendable {
    var sequence: Int
    var timestamp: Double
    var method: String
    var path: String
    var transferCorrelationID: String?
    var queryKeys: [String]
    var querySHA256: String?
    var host: String
    var transport: String
    var headerNames: [String]
    var hasCookieHeader: Bool
    var cookieSHA256: String?
    var cookieMarkers: [String]
    var hasSyntheticAuthCookie: Bool
    var hasAuthorizationHeader: Bool
    var authorizationSHA256: String?
    var authorizationAccepted: Bool?
    var refererHostPath: String?
    var originValue: String?
    var userAgentValue: String?
    var bodyByteCount: Int
    var bodySHA256: String?
    var assetID: String?
    var responsePayloadSHA256: String?
    /// HTTP status returned for this request by the fixture server.
    var responseStatusCode: Int
    var declaredByteCount: Int
    var sentByteCount: Int
    var completed: Bool
    var responseCompletedAt: Double?
    var sendSamples: [SpikeSendSample]
    var clientClosedEarly: Bool
    var throttleMilliseconds: Int?
    var tokenLabel: String?
    var tokenConsumedByThisRequest: Bool?
    var note: String?
}

/// One structured event reported by the experiment app.
struct SpikeAppEvent: Codable, Sendable {
    var timestamp: Double
    var kind: String
    var caseID: String
    var detail: String
    var fields: [String: String]
}

/// Ledger entry for a single-use signed fixture token.
struct SpikeTokenRecord: Encodable, Sendable {
    var label: String
    var issuedAt: Double
    var consumed: Bool
    var consumedByTransport: String?
    var consumedAt: Double?
}

/// The complete evidence artifact written to disk.
struct SpikeEvidenceDocument: Encodable, Sendable {
    var schemaVersion: Int
    var runIdentifier: String
    var serverStartedAt: Double
    var exportedAt: Double
    var primaryHost: String
    var secondaryHost: String
    var port: Int
    var requests: [SpikeRecordedRequest]
    var lifecycleMarkers: [SpikeLifecycleMarker]
    var appEvents: [SpikeAppEvent]
    var tokenLedger: [SpikeTokenRecord]
    var notes: [String]
    var requestCountsByPath: [String: Int]
}

/// Thread-safe evidence sink shared by every fixture connection.
///
/// The server persists only sanitized observations: header name inventories,
/// presence flags, SHA-256 prefixes, non-secret fixture values, and sanitized
/// identifiers. Raw secrets are held only long enough to compute a hash or a
/// presence flag and are then discarded.
final class SpikeEvidenceRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private let runIdentifier: String
    private let startedAt = Date().timeIntervalSince1970
    private let redactionTerms: [String]
    private var requests: [SpikeRecordedRequest] = []
    private var lifecycleMarkers: [SpikeLifecycleMarker] = []
    private var appEvents: [SpikeAppEvent] = []
    private var tokenLedger: [SpikeTokenRecord] = []
    private var notes: [String] = []
    private var sequenceCounter = 0
    private var exportURL: URL?

    init(runIdentifier: String, redactionTerms: [String]) {
        self.runIdentifier = runIdentifier
        self.redactionTerms = redactionTerms
    }

    /// Directory and file used for periodic evidence export.
    func attachExportURL(_ url: URL) {
        lock.lock()
        exportURL = url
        lock.unlock()
    }

    /// Next stable request sequence number.
    func nextSequence() -> Int {
        lock.lock()
        defer { lock.unlock() }
        sequenceCounter += 1
        return sequenceCounter
    }

    /// Store one redacted request observation and refresh the artifact.
    func record(_ request: SpikeRecordedRequest) {
        lock.lock()
        requests.append(request)
        lock.unlock()
        persist()
    }

    /// Record one test-runner boundary using the fixture server's own clock.
    func recordLifecycleMarker(label: String, fields: [String: String]) {
        lock.lock()
        lifecycleMarkers.append(
            SpikeLifecycleMarker(timestamp: Date().timeIntervalSince1970, label: sanitize(label), fields: fields.mapValues(sanitize))
        )
        lock.unlock()
        persist()
    }

    /// Record a response chunk after the host process has sent it.
    func recordSendProgress(sequence: Int, sentByteCount: Int) {
        lock.lock()
        if let index = requests.firstIndex(where: { $0.sequence == sequence }) {
            requests[index].sendSamples.append(
                SpikeSendSample(timestamp: Date().timeIntervalSince1970, cumulativeBytes: sentByteCount)
            )
        }
        lock.unlock()
        persist()
    }

    /// Attach the observed send outcome for an already recorded request.
    func recordSendOutcome(sequence: Int, sentByteCount: Int, completed: Bool, clientClosedEarly: Bool) {
        lock.lock()
        if let index = requests.firstIndex(where: { $0.sequence == sequence }) {
            requests[index].sentByteCount = sentByteCount
            requests[index].completed = completed
            requests[index].responseCompletedAt = completed ? Date().timeIntervalSince1970 : nil
            requests[index].clientClosedEarly = clientClosedEarly
        }
        lock.unlock()
        persist()
    }

    /// Store one app-reported event after removing any secret literal.
    func appendAppEvent(_ event: SpikeAppEvent) {
        var sanitized = event
        sanitized.detail = sanitize(event.detail)
        sanitized.fields = event.fields.mapValues(sanitize)
        lock.lock()
        appEvents.append(sanitized)
        lock.unlock()
        persist()
    }

    /// Add a server-side note such as a lifecycle boundary observation.
    func appendNote(_ note: String) {
        lock.lock()
        notes.append(sanitize(note))
        lock.unlock()
        persist()
    }

    /// Register a newly minted signed fixture token under a sanitized label.
    func registerToken(label: String) {
        lock.lock()
        tokenLedger.append(
            SpikeTokenRecord(
                label: label,
                issuedAt: Date().timeIntervalSince1970,
                consumed: false,
                consumedByTransport: nil,
                consumedAt: nil
            )
        )
        lock.unlock()
        persist()
    }

    /// Mark a signed fixture token as consumed by one transport.
    func consumeToken(label: String, transport: String) {
        lock.lock()
        if let index = tokenLedger.firstIndex(where: { $0.label == label }) {
            tokenLedger[index].consumed = true
            tokenLedger[index].consumedByTransport = transport
            tokenLedger[index].consumedAt = Date().timeIntervalSince1970
        }
        lock.unlock()
        persist()
    }

    /// Number of requests observed so far, used for reset assertions.
    func requestCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return requests.count
    }

    /// Whether a signed fixture token label was already consumed.
    func isTokenConsumed(label: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return tokenLedger.first { $0.label == label }?.consumed ?? false
    }

    /// Requests observed for one exact path.
    func requestCountsByPath() -> [String: Int] {
        lock.lock()
        defer { lock.unlock() }
        var counts: [String: Int] = [:]
        for request in requests {
            counts[request.path, default: 0] += 1
        }
        return counts
    }

    /// Remove every observation so a new run or device starts clean.
    func reset() {
        lock.lock()
        requests.removeAll()
        lifecycleMarkers.removeAll()
        appEvents.removeAll()
        tokenLedger.removeAll()
        notes.removeAll()
        sequenceCounter = 0
        lock.unlock()
        persist()
    }

    /// Serialize the current artifact.
    func exportJSON() -> Data {
        lock.lock()
        let document = SpikeEvidenceDocument(
            schemaVersion: 1,
            runIdentifier: runIdentifier,
            serverStartedAt: startedAt,
            exportedAt: Date().timeIntervalSince1970,
            primaryHost: SpikeContract.primaryHost,
            secondaryHost: SpikeContract.secondaryHost,
            port: Int(SpikeContract.port),
            requests: requests,
            lifecycleMarkers: lifecycleMarkers,
            appEvents: appEvents,
            tokenLedger: tokenLedger,
            notes: notes,
            requestCountsByPath: requestCountsByPathLocked()
        )
        lock.unlock()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return (try? encoder.encode(document)) ?? Data("{}".utf8)
    }

    /// Write the artifact to the configured export path.
    func persist() {
        lock.lock()
        let target = exportURL
        lock.unlock()
        guard let target else { return }
        let data = exportJSON()
        try? FileManager.default.createDirectory(
            at: target.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: target, options: .atomic)
    }

    private func requestCountsByPathLocked() -> [String: Int] {
        var counts: [String: Int] = [:]
        for request in requests {
            counts[request.path, default: 0] += 1
        }
        return counts
    }

    /// Replace any known secret literal with a redaction marker.
    private func sanitize(_ value: String) -> String {
        var result = value
        for term in redactionTerms where !term.isEmpty {
            result = result.replacingOccurrences(of: term, with: "[redacted]")
        }
        return result
    }
}

/// Hashing helpers shared by the fixture server.
enum SpikeEvidenceHash {
    /// Short SHA-256 prefix used for observable-but-non-secret comparisons.
    static func prefix(_ data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined().prefix(16).description
    }

    /// Short SHA-256 prefix of a string value.
    static func prefix(_ value: String) -> String {
        prefix(Data(value.utf8))
    }

    /// Full SHA-256 digest of deterministic fixture payload bytes.
    static func full(_ data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
