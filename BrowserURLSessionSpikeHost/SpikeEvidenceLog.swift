import Foundation

/// One structured experiment event.
///
/// Events carry only sanitized values: names, presence flags, hashes, counts,
/// and identifiers. Raw cookie values, authorization values, and signed tokens
/// are never stored in an event.
struct SpikeEvent: Codable, Sendable {
    var timestamp: Double
    var kind: String
    var caseID: String
    var detail: String
    var fields: [String: String]
}

/// Append-only, thread-safe experiment log persisted in the disposable app
/// container so that evidence survives process termination and relaunch.
final class SpikeEvidenceLog: @unchecked Sendable {
    private let lock = NSLock()
    private let fileURL: URL
    private let directoryURL: URL
    private var events: [SpikeEvent] = []
    private var uploadedCount = 0

    /// Identifier of the current process instance, used to show that a
    /// relaunch produced a new process.
    let instanceIdentifier: String

    init(directoryURL: URL) {
        self.directoryURL = directoryURL
        self.fileURL = directoryURL.appendingPathComponent("events.jsonl")
        self.instanceIdentifier = UUID().uuidString
        try? FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        loadPersistedEvents()
    }

    /// Record one event in memory and on disk.
    func append(kind: String, caseID: String, detail: String, fields: [String: String] = [:]) {
        let event = SpikeEvent(
            timestamp: Date().timeIntervalSince1970,
            kind: kind,
            caseID: caseID,
            detail: detail,
            fields: fields
        )
        lock.lock()
        events.append(event)
        lock.unlock()
        appendLine(event)
    }

    /// All recorded events, including events persisted by earlier launches.
    func snapshot() -> [SpikeEvent] {
        lock.lock()
        defer { lock.unlock() }
        return events
    }

    /// Delete all evidence and start a fresh experiment run.
    func reset() {
        lock.lock()
        events.removeAll()
        uploadedCount = 0
        lock.unlock()
        try? FileManager.default.removeItem(at: fileURL)
    }

    /// JSON export used by the UI tests through an accessibility value.
    func exportJSON() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let export = SpikeEvidenceExport(
            schemaVersion: 1,
            instanceIdentifier: instanceIdentifier,
            events: snapshot()
        )
        guard let data = try? encoder.encode(export) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    /// Events that have not been uploaded to the fixture server yet.
    func pendingUploads() -> [SpikeEvent] {
        lock.lock()
        defer { lock.unlock() }
        guard uploadedCount < events.count else { return [] }
        return Array(events[uploadedCount...])
    }

    /// Mark the first `count` pending events as uploaded.
    func markUploaded(_ count: Int) {
        lock.lock()
        uploadedCount = min(uploadedCount + count, events.count)
        lock.unlock()
    }

    private func appendLine(_ event: SpikeEvent) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(event) else { return }
        var line = data
        line.append(0x0A)
        if let handle = try? FileHandle(forWritingTo: fileURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: line)
        } else {
            try? line.write(to: fileURL, options: .atomic)
        }
    }

    private func loadPersistedEvents() {
        guard let data = try? Data(contentsOf: fileURL),
              let text = String(data: data, encoding: .utf8) else { return }
        let decoder = JSONDecoder()
        var restored: [SpikeEvent] = []
        for line in text.split(separator: "\n") {
            guard let event = try? decoder.decode(SpikeEvent.self, from: Data(line.utf8)) else { continue }
            restored.append(event)
        }
        lock.lock()
        events = restored
        lock.unlock()
    }
}

/// Codable envelope for the JSON accessibility export.
private struct SpikeEvidenceExport: Codable {
    let schemaVersion: Int
    let instanceIdentifier: String
    let events: [SpikeEvent]
}
