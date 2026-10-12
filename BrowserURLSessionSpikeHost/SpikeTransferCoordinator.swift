import Foundation

/// Container paths for the disposable Spike 2 experiment.
///
/// Everything lives in the disposable iOS application container. Nothing is
/// written to the shipping media library, the shipping vault, or any shared
/// cookie jar.
enum SpikeRuntimePaths {
    /// Root directory for disposable experiment state.
    static func containerRoot() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("BrowserURLSessionSpike", isDirectory: true)
    }

    /// Directory holding the persisted experiment event log.
    static var evidenceDirectory: URL {
        containerRoot().appendingPathComponent(SpikeContract.appEvidenceDirectoryName, isDirectory: true)
    }

    /// Directory holding downloaded scratch files.
    static var scratchDirectory: URL {
        containerRoot().appendingPathComponent(SpikeContract.scratchDirectoryName, isDirectory: true)
    }

    /// File holding minimal transfer reconciliation metadata.
    static var transferMetadataFile: URL {
        evidenceDirectory.appendingPathComponent("transfers.json")
    }
}

/// The two app-owned sessions the experiment compares.
enum SpikeTransferRole: String, Sendable {
    /// The app-owned background session that hands transfers to the system.
    case background
    /// A foreground session built from the same request, used as a control.
    case foregroundControl = "foreground-control"

    var transportValue: String {
        switch self {
        case .background: SpikeContract.Transport.backgroundURLSession.rawValue
        case .foregroundControl: SpikeContract.Transport.foregroundURLSession.rawValue
        }
    }
}

/// Minimal persisted metadata describing one app-owned transfer.
///
/// The record is what lets a relaunched process associate a system-restored
/// task with the experiment case, scratch destination, and expected payload
/// hash. It never contains cookies, credentials, or signed tokens.
struct SpikeTransferRecord: Codable, Sendable {
    var key: String
    var taskIdentifier: Int
    var role: String
    var caseID: String
    var profile: String
    var correlationIdentifier: String?
    var host: String
    var path: String
    var method: String
    var expectedAsset: String?
    var expectedSHA256: String?
    var startedAt: Double
    var runIdentifier: String?
    var cancelAfterFirstProgress: Bool
    var scratchPath: String?
    var digestSHA256: String?
    var outcome: String?
    var fileMovedAt: Double?
    var digestAt: Double?
    var completionAt: Double?

    static func key(role: SpikeTransferRole, taskIdentifier: Int) -> String {
        "\(role.rawValue)-\(taskIdentifier)"
    }
}

/// File-backed, lock-guarded store for transfer metadata.
final class SpikeTransferMetadataStore: @unchecked Sendable {
    private let lock = NSLock()
    private let fileURL: URL
    private var records: [String: SpikeTransferRecord] = [:]

    init(fileURL: URL) {
        self.fileURL = fileURL
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        load()
    }

    func upsert(_ record: SpikeTransferRecord) {
        lock.lock()
        records[record.key] = record
        persistLocked()
        lock.unlock()
    }

    func remove(key: String) {
        lock.lock()
        records[key] = nil
        persistLocked()
        lock.unlock()
    }

    func record(key: String) -> SpikeTransferRecord? {
        lock.lock()
        defer { lock.unlock() }
        return records[key]
    }

    func all() -> [SpikeTransferRecord] {
        lock.lock()
        defer { lock.unlock() }
        return records.values.sorted { $0.startedAt < $1.startedAt }
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return records.count
    }

    func reset() {
        lock.lock()
        records.removeAll()
        try? FileManager.default.removeItem(at: fileURL)
        lock.unlock()
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([String: SpikeTransferRecord].self, from: data) else { return }
        records = decoded
    }

    private func persistLocked() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(records) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}

/// Redacted app-to-fixture control channel.
///
/// Used only to publish sanitized experiment events to the host-process
/// fixture server and to check fixture health. It uses its own ephemeral
/// session with cookies disabled so it can never touch the page's data store
/// or a shared cookie jar.
final class SpikeFixtureClient: @unchecked Sendable {
    private let session: URLSession
    private let baseURL: URL

    init(baseURL: URL = SpikeContract.baseURL(host: SpikeContract.primaryHost)) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.timeoutIntervalForRequest = 10
        self.session = URLSession(configuration: configuration)
        self.baseURL = baseURL
    }

    /// Fixture health probe.
    func health() async -> Bool {
        var request = URLRequest(url: baseURL.appendingPathComponent(SpikeContract.Path.health))
        request.httpMethod = "GET"
        guard let (_, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse else { return false }
        return http.statusCode == 200
    }

    /// Publish sanitized experiment events to the fixture server.
    func postAppEvents(_ events: [SpikeEvent]) async -> Bool {
        guard !events.isEmpty else { return true }
        var request = URLRequest(url: baseURL.appendingPathComponent(SpikeContract.Path.appEvent))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(SpikeContract.Transport.foregroundURLSession.rawValue, forHTTPHeaderField: SpikeContract.transportHeader)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let body = try? encoder.encode(events) else { return false }
        request.httpBody = body
        guard let (_, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse else { return false }
        return http.statusCode == 204 || http.statusCode == 200
    }
}

/// Runtime for app-owned transfers in the Spike 2 experiment.
///
/// The coordinator owns one background session with the stable experimental
/// identifier and one foreground control session built from the same
/// request-construction rules. It is deliberately the only place in the
/// experiment host that touches URLSession.
@MainActor
final class SpikeTransferCoordinator: NSObject {
    /// Process-wide runtime, reachable from the app delegate before any scene
    /// exists so that background session events are never missed.
    static let shared = SpikeTransferCoordinator()

    let log: SpikeEvidenceLog
    let scratch: SpikeScratchStore
    let metadata: SpikeTransferMetadataStore
    let client: SpikeFixtureClient

    /// Called after every recorded event so the host view can refresh.
    var onEventRecorded: (() -> Void)?

    private(set) var backgroundSession: URLSession?
    private(set) var foregroundSession: URLSession?

    private var activeRecords: [String: SpikeTransferRecord] = [:]
    private var lastReportedProgress: [String: Int] = [:]
    private var digestTasks: [String: Task<Void, Never>] = [:]
    private var resetPendingCompletionKeys: Set<String> = []
    private var observedCompletionKeys: Set<String> = []
    private var resetInProgress = false
    private var resetBlocked = false
    private(set) var runIdentifier: String
    private var backgroundCompletionHandler: (() -> Void)?
    private var backgroundCompletionRunIdentifier: String?
    private var backgroundCompletionDeliveryIdentifier: String?
    private var backgroundCompletionDeliveryToken: UUID?
    private var backgroundCompletionFallback: Timer?
private var backgroundEventsDidFinishDelivery = false
private var backgroundEventsFinishWasRecorded = false
private var backgroundCompletionFinalizationTask: Task<Void, Never>?
    private var uploadTask: Task<Void, Never>?
    private var uploadTaskIdentifier: UUID?
    private var uploadRequestedAgain = false

    private override init() {
        let log = SpikeEvidenceLog(directoryURL: SpikeRuntimePaths.evidenceDirectory)
        self.log = log
        self.scratch = SpikeScratchStore(rootURL: SpikeRuntimePaths.scratchDirectory)
        let metadata = SpikeTransferMetadataStore(fileURL: SpikeRuntimePaths.transferMetadataFile)
        self.metadata = metadata
        self.runIdentifier = metadata.all().first?.runIdentifier ?? UUID().uuidString
        self.client = SpikeFixtureClient()
        super.init()
    }

    // MARK: - Session lifecycle

    /// Create the experiment sessions. Safe to call repeatedly; the background
    /// session is created at most once per process because a second session
    /// with the same identifier is invalid.
    func start() {
        guard backgroundSession == nil else { return }

        let backgroundConfiguration = URLSessionConfiguration.background(
            withIdentifier: SpikeContract.backgroundSessionIdentifier
        )
        applyManagedCookiePolicy(to: backgroundConfiguration)
        backgroundConfiguration.isDiscretionary = false
        backgroundConfiguration.sessionSendsLaunchEvents = true
        backgroundConfiguration.waitsForConnectivity = false
        backgroundConfiguration.timeoutIntervalForRequest = 30
        backgroundConfiguration.timeoutIntervalForResource = 3_600
        let background = URLSession(configuration: backgroundConfiguration, delegate: self, delegateQueue: .main)
        backgroundSession = background

        let foregroundConfiguration = URLSessionConfiguration.ephemeral
        applyManagedCookiePolicy(to: foregroundConfiguration)
        foregroundConfiguration.timeoutIntervalForRequest = 30
        foregroundConfiguration.timeoutIntervalForResource = 3_600
        let foreground = URLSession(configuration: foregroundConfiguration, delegate: self, delegateQueue: .main)
        foregroundSession = foreground

        recordTransportEvent(
            kind: "session-created",
            caseID: "runtime",
            detail: "Created app-owned background and foreground sessions with app-managed cookies.",
            fields: [
                "instance": log.instanceIdentifier,
                "identifier": SpikeContract.backgroundSessionIdentifier,
                "cookieStorage": "nil",
                "httpShouldSetCookies": "false",
                "discretionary": "false",
            ]
        )

        background.getAllTasks { [weak self] tasks in
            Task { @MainActor in
                self?.reconcile(restoredTasks: tasks, role: .background)
            }
        }
        foreground.getAllTasks { [weak self] tasks in
            Task { @MainActor in
                self?.reconcile(restoredTasks: tasks, role: .foregroundControl)
            }
        }
    }

    /// Central cookie policy for app-owned sessions.
    ///
    /// URLSession's default cookie storage is the shared HTTPCookieStorage,
    /// which would silently make transfers depend on a global jar that the
    /// page never assigned. The experiment disables that path and attaches
    /// cookies explicitly from the page's own WKWebsiteDataStore.
    private func applyManagedCookiePolicy(to configuration: URLSessionConfiguration) {
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
    }

    /// System-restored tasks delivered after a relaunch.
    private func reconcile(restoredTasks: [URLSessionTask], role: SpikeTransferRole) {
        guard !resetInProgress && !resetBlocked else { return }
        let persisted = metadata.all()
        for task in restoredTasks {
            let key = SpikeTransferRecord.key(role: role, taskIdentifier: task.taskIdentifier)
            activeRecords[key] = activeRecords[key] ?? persisted.first { $0.key == key }
            let record = activeRecords[key]
            recordTransportEvent(
                kind: "task-restored",
                caseID: record?.caseID ?? "unknown",
                detail: "Background session restored a task owned by the transfer daemon.",
                fields: [
                    "role": role.rawValue,
                    "taskIdentifier": String(task.taskIdentifier),
                    "state": taskStateName(task.state),
                    "metadata": record == nil ? "missing" : "matched",
                    "path": record?.path ?? "unknown",
                    "profile": record?.profile ?? "unknown",
                    "transferCorrelationID": record?.correlationIdentifier ?? "none",
                    "runIdentifier": record?.runIdentifier ?? runIdentifier,
                ]
            )
            if task.state == .suspended {
                task.resume()
            }
        }

        let restoredKeys = Set(restoredTasks.map { SpikeTransferRecord.key(role: role, taskIdentifier: $0.taskIdentifier) })
        let orphaned = persisted.filter { $0.role == role.rawValue && !restoredKeys.contains($0.key) }
        for record in orphaned {
            recordTransportEvent(
                kind: "task-not-restored",
                caseID: record.caseID,
                detail: "Persisted transfer metadata had no matching system task after relaunch.",
                fields: [
                    "role": role.rawValue,
                    "path": record.path,
                    "profile": record.profile,
                    "taskIdentifier": String(record.taskIdentifier),
                    "transferCorrelationID": record.correlationIdentifier ?? "none",
                ]
            )
            recoverMovedFileIfNeeded(record)
        }
    }

    private func recoverMovedFileIfNeeded(_ record: SpikeTransferRecord) {
        guard record.fileMovedAt != nil,
              let scratchPath = record.scratchPath
        else {
            return
        }
        let fileURL = scratch.destinationURL(
            role: record.role,
            profile: record.profile,
            taskIdentifier: record.taskIdentifier,
        )
        guard fileURL.lastPathComponent == scratchPath,
              FileManager.default.fileExists(atPath: fileURL.path)
        else {
            return
        }

        var recoveredRecord = record
        recoveredRecord.outcome = recoveredRecord.outcome ?? "terminal-callback-unobserved"
        activeRecords[record.key] = recoveredRecord
        metadata.upsert(recoveredRecord)
        recordTransportEvent(
            kind: "orphaned-download-file-recovery-started",
            caseID: record.caseID,
            detail: "A moved scratch file was rehashed after its system task was no longer present.",
            fields: [
                "role": record.role,
                "taskIdentifier": String(record.taskIdentifier),
                "transferCorrelationID": record.correlationIdentifier ?? "none",
                "scratchPath": scratchPath,
                "recoveredAfterTaskMissing": "true",
            ]
        )
        guard recoveredRecord.digestSHA256 == nil else {
            finalizeIfReady(key: record.key)
            return
        }
        guard digestTasks[record.key] == nil else { return }

        let expectedHash = record.expectedSHA256
        digestTasks[record.key] = Task { [weak self] in
            let digest = await Task.detached(priority: .utility) {
                (try? SpikeScratchStore.digestFile(at: fileURL)) ?? "unreadable"
            }.value
            guard let self,
                  var updated = self.activeRecords[record.key],
                  updated.scratchPath == scratchPath
            else {
                return
            }
            self.digestTasks[record.key] = nil
            updated.digestSHA256 = digest
            updated.digestAt = Date().timeIntervalSince1970
            self.activeRecords[record.key] = updated
            self.metadata.upsert(updated)
            self.recordTransportEvent(
                kind: "transfer-hash",
                caseID: record.caseID,
                detail: "Computed SHA-256 for a moved file recovered after its system task disappeared.",
                fields: [
                    "role": record.role,
                    "taskIdentifier": String(record.taskIdentifier),
                    "digestSHA256": digest,
                    "expectedSHA256": expectedHash ?? "none",
                    "byteIdentical": expectedHash.map { String($0 == digest) } ?? "unknown",
                    "digestAt": String(updated.digestAt ?? 0),
                    "transferCorrelationID": record.correlationIdentifier ?? "none",
                    "recoveredAfterTaskMissing": "true",
                ]
            )
            self.finalizeIfReady(key: record.key)
        }
    }

    private func taskStateName(_ state: URLSessionTask.State) -> String {
        switch state {
        case .running: "running"
        case .suspended: "suspended"
        case .canceling: "canceling"
        case .completed: "completed"
        @unknown default: "unknown"
        }
    }

    /// System hands the app a completion handler when it is relaunched for
    /// background session events. The handler must be called only after all
    /// delegate events have been delivered.
    func handleBackgroundEvents(
        identifier: String,
        deliveryIdentifier: String? = nil,
        completionHandler: @escaping () -> Void
    ) {
        start()
        var receivedFields = [
            "identifier": identifier,
            "matches": String(identifier == SpikeContract.backgroundSessionIdentifier),
        ]
        if let deliveryIdentifier {
            receivedFields["deliveryIdentifier"] = deliveryIdentifier
        }
        recordTransportEvent(
            kind: "background-events-received",
            caseID: "runtime",
            detail: "System requested background URLSession event delivery.",
            fields: receivedFields
        )
        backgroundCompletionHandler = completionHandler
        backgroundCompletionRunIdentifier = runIdentifier
        backgroundCompletionDeliveryIdentifier = deliveryIdentifier
        backgroundCompletionDeliveryToken = UUID()
        backgroundEventsDidFinishDelivery = false
        backgroundEventsFinishWasRecorded = false
        backgroundCompletionFallback?.invalidate()
        backgroundCompletionFallback = Timer.scheduledTimer(withTimeInterval: 25, repeats: false) { [weak self] _ in
            Task { @MainActor in
                var timeoutFields = [
                    "deliveryState": "incomplete",
                    "handlerRetained": String(self?.backgroundCompletionHandler != nil),
                    "runIdentifier": self?.backgroundCompletionRunIdentifier ?? self?.runIdentifier ?? "unknown",
                ]
                if let deliveryIdentifier = self?.backgroundCompletionDeliveryIdentifier {
                    timeoutFields["deliveryIdentifier"] = deliveryIdentifier
                }
                self?.recordTransportEvent(
                    kind: "background-events-timeout",
                    caseID: "runtime",
                    detail: "Background URLSession event delivery remains unresolved; the system completion handler is still pending.",
                    fields: timeoutFields
                )
            }
        }
    }

    /// Complete system background event delivery on the main thread.
    func finishBackgroundEvents() {
        backgroundEventsDidFinishDelivery = true
        finalizeBackgroundEventsIfSettled()
    }

    private func finalizeBackgroundEventsIfSettled() {
        let unsettledBackgroundTransfers = activeRecords.values.filter {
            $0.role == SpikeTransferRole.background.rawValue
        }.count
        guard backgroundEventsDidFinishDelivery,
              digestTasks.isEmpty,
              unsettledBackgroundTransfers == 0
        else {
            return
        }
        if !backgroundEventsFinishWasRecorded {
            backgroundEventsFinishWasRecorded = true
            recordTransportEvent(
                kind: "background-events-finished",
                caseID: "runtime",
                detail: "Background delegate events, file hashing, and transfer cleanup settled.",
                fields: [
                    "hadHandler": String(backgroundCompletionHandler != nil),
                    "completionSource": "urlSessionDidFinishEvents",
                    "runIdentifier": backgroundCompletionRunIdentifier ?? runIdentifier,
                    "deliveryIdentifier": backgroundCompletionDeliveryIdentifier ?? "none",
                    "pendingDigests": String(digestTasks.count),
                    "unsettledBackgroundTransfers": String(unsettledBackgroundTransfers),
                ]
            )
        }
        guard backgroundCompletionHandler != nil else {
            backgroundEventsDidFinishDelivery = false
            return
        }
        guard backgroundCompletionFinalizationTask == nil,
              let finishingDeliveryToken = backgroundCompletionDeliveryToken
        else {
            return
        }

        backgroundCompletionFinalizationTask = Task { [weak self] in
            guard let self else { return }
            await self.waitForPendingUploads()
            guard self.backgroundEventsDidFinishDelivery,
                  self.backgroundCompletionDeliveryToken == finishingDeliveryToken,
                  let handler = self.backgroundCompletionHandler
            else {
                self.backgroundCompletionFinalizationTask = nil
                self.finalizeBackgroundEventsIfSettled()
                return
            }
            self.backgroundCompletionFallback?.invalidate()
            self.backgroundCompletionFallback = nil
            self.backgroundCompletionHandler = nil
            self.backgroundCompletionRunIdentifier = nil
            self.backgroundCompletionDeliveryIdentifier = nil
            self.backgroundCompletionDeliveryToken = nil
            self.backgroundCompletionFinalizationTask = nil
            self.backgroundEventsDidFinishDelivery = false
            self.backgroundEventsFinishWasRecorded = false
            handler()
        }
    }

    private func waitForPendingUploads() async {
        while let pendingUpload = uploadTask {
            await pendingUpload.value
        }
        await uploadPendingEvents()
    }

    // MARK: - Transfers

    /// Start one app-owned transfer for an observed browser request.
    func enqueue(
        request: URLRequest,
        caseID: String,
        profile: String,
        role: SpikeTransferRole,
        expectedAsset: SpikeFixtureAsset?,
        cancelAfterFirstProgress: Bool,
        runIdentifier requestedRunIdentifier: String? = nil
    ) {
        start()
        let requestedRunIdentifier = requestedRunIdentifier ?? runIdentifier
        guard !resetInProgress, !resetBlocked, requestedRunIdentifier == runIdentifier else { return }
        guard let session = role == .background ? backgroundSession : foregroundSession else { return }
        guard let url = request.url else { return }
        // The transport attribution header must describe the session that
        // actually performs the transfer, not the role of the request's
        // originating code path. The builder stamps the background value, so
        // the foreground control has to be re-stamped here.
        var request = request
        request.setValue(role.transportValue, forHTTPHeaderField: SpikeContract.transportHeader)
        let correlationIdentifier = UUID().uuidString
        request.setValue(correlationIdentifier, forHTTPHeaderField: SpikeContract.transferCorrelationHeader)
        let task = session.downloadTask(with: request)
        let record = SpikeTransferRecord(
            key: SpikeTransferRecord.key(role: role, taskIdentifier: task.taskIdentifier),
            taskIdentifier: task.taskIdentifier,
            role: role.rawValue,
            caseID: caseID,
            profile: profile,
            correlationIdentifier: correlationIdentifier,
            host: url.host ?? "unknown",
            path: url.path,
            method: request.httpMethod ?? "GET",
            expectedAsset: expectedAsset?.rawValue,
            expectedSHA256: expectedAsset.map { SpikeHash.digest($0.payload) },
            startedAt: Date().timeIntervalSince1970,
            runIdentifier: requestedRunIdentifier,
            cancelAfterFirstProgress: cancelAfterFirstProgress,
            scratchPath: nil,
            digestSHA256: nil,
            outcome: nil,
            fileMovedAt: nil,
            digestAt: nil,
            completionAt: nil
        )
        activeRecords[record.key] = record
        metadata.upsert(record)
        recordTransportEvent(
            kind: "transfer-started",
            caseID: caseID,
            detail: "App-owned session started a download for an intercepted browser request.",
            fields: [
                "role": role.rawValue,
                "taskIdentifier": String(task.taskIdentifier),
                "host": record.host,
                "path": record.path,
                "method": record.method,
                "profile": profile,
                "transferCorrelationID": correlationIdentifier,
                "runIdentifier": requestedRunIdentifier,
                "expectedAsset": record.expectedAsset ?? "none",
                "expectedSHA256": record.expectedSHA256.map { String($0.prefix(16)) } ?? "none",
                "queryKeys": SpikeRedaction.queryKeys(url),
            ]
        )
        task.resume()
    }

    /// Cancel every transfer for a case, used by the cancellation fixture.
    func cancel(caseID: String) {
        let keys = activeRecords.filter { $0.value.caseID == caseID }.map(\.key)
        for key in keys {
            guard let record = activeRecords[key] else { continue }
            let session = record.role == SpikeTransferRole.background.rawValue ? backgroundSession : foregroundSession
            session?.getAllTasks { tasks in
                for task in tasks where task.taskIdentifier == record.taskIdentifier {
                    task.cancel()
                }
            }
        }
        recordTransportEvent(
            kind: "transfer-cancel-requested",
            caseID: caseID,
            detail: "Experiment cancelled in-flight app-owned transfers for this case.",
            fields: ["cancelled": String(keys.count)]
        )
    }

    /// Number of transfers this process currently tracks as active.
    var activeTransferCount: Int {
        activeRecords.count
    }

    /// Reset disposable runtime state between experiment runs.
    func reset(timeout: TimeInterval = 40) async -> Bool {
        guard !resetInProgress else { return false }
        resetInProgress = true
        start()

        let initialTasks = await allSessionTasks()
        let expectedCompletionKeys = Set(initialTasks.map { task, role in
            SpikeTransferRecord.key(role: role, taskIdentifier: task.taskIdentifier)
        }).union(activeRecords.keys)
        resetPendingCompletionKeys = expectedCompletionKeys.subtracting(observedCompletionKeys)
        for (task, _) in initialTasks {
            task.cancel()
        }

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let outstandingTasks = await allSessionTasks()
            if outstandingTasks.isEmpty, resetPendingCompletionKeys.isEmpty, digestTasks.isEmpty,
               backgroundCompletionHandler == nil {
                break
            }
            try? await Task.sleep(for: .milliseconds(100))
        }

        let remainingTasks = await allSessionTasks()
        guard remainingTasks.isEmpty, resetPendingCompletionKeys.isEmpty, digestTasks.isEmpty,
              backgroundCompletionHandler == nil else {
            resetInProgress = false
            resetBlocked = true
            recordTransportEvent(
                kind: "runtime-reset-incomplete",
                caseID: "runtime",
                detail: "Reset timed out before URLSession callbacks and digest work were reconciled; existing metadata and scratch were preserved.",
                fields: [
                    "remainingSessionTasks": String(remainingTasks.count),
                    "pendingTerminalCallbacks": String(resetPendingCompletionKeys.count),
                    "pendingDigests": String(digestTasks.count),
                    "backgroundEventHandlerPending": String(backgroundCompletionHandler != nil),
                ]
            )
            return false
        }

        let cancelledRecordCount = activeRecords.count
        activeRecords.removeAll()
        lastReportedProgress.removeAll()
        metadata.reset()
        scratch.reset()
        uploadTask?.cancel()
        uploadTask = nil
        uploadTaskIdentifier = nil
        uploadRequestedAgain = false
        observedCompletionKeys.removeAll()
        resetPendingCompletionKeys.removeAll()
        log.reset()
        runIdentifier = UUID().uuidString
        resetBlocked = false
        resetInProgress = false
        recordTransportEvent(
            kind: "runtime-reset-completed",
            caseID: "runtime",
            detail: "Cancelled and reconciled URLSession tasks before clearing experimental metadata and scratch files.",
            fields: [
                "cancelledRecordCount": String(cancelledRecordCount),
                "activeRecordCount": String(activeRecords.count),
                "persistedUnfinishedMetadataCount": String(metadata.count),
                "scratchFileCount": String(scratch.fileCount),
            ]
        )
        return true
    }

    // MARK: - Evidence

    /// Record one sanitized event and publish it to the fixture server.
    func recordTransportEvent(kind: String, caseID: String, detail: String, fields: [String: String]) {
        var attributedFields = fields
        attributedFields["processInstance"] = fields["processInstance"] ?? log.instanceIdentifier
        attributedFields["runIdentifier"] = fields["runIdentifier"] ?? runIdentifier
        log.append(kind: kind, caseID: caseID, detail: detail, fields: attributedFields)
        onEventRecorded?()
        scheduleUpload()
    }

    private func scheduleUpload() {
        guard uploadTask == nil else {
            uploadRequestedAgain = true
            return
        }
        let taskIdentifier = UUID()
        uploadTaskIdentifier = taskIdentifier
        uploadTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard let self else { return }
            guard !Task.isCancelled else {
                if self.uploadTaskIdentifier == taskIdentifier {
                    self.uploadTask = nil
                    self.uploadTaskIdentifier = nil
                    self.uploadRequestedAgain = false
                }
                return
            }
            guard self.uploadTaskIdentifier == taskIdentifier else { return }
            await self.uploadPendingEvents()
            guard self.uploadTaskIdentifier == taskIdentifier else { return }
            let scheduleAgain = self.uploadRequestedAgain
            self.uploadRequestedAgain = false
            self.uploadTask = nil
            self.uploadTaskIdentifier = nil
            if scheduleAgain {
                self.scheduleUpload()
            }
        }
    }

    private func uploadPendingEvents() async {
        let uploadingRunIdentifier = runIdentifier
        let pending = log.pendingUploads()
        guard !pending.isEmpty else { return }
        if await client.postAppEvents(pending) {
            guard uploadingRunIdentifier == runIdentifier else { return }
            log.markUploaded(pending.count)
        }
    }

    private func allSessionTasks() async -> [(URLSessionTask, SpikeTransferRole)] {
        var result: [(URLSessionTask, SpikeTransferRole)] = []
        if let backgroundSession {
            let tasks: [URLSessionTask] = await withCheckedContinuation { continuation in
                backgroundSession.getAllTasks { continuation.resume(returning: $0) }
            }
            result.append(contentsOf: tasks.map { ($0, .background) })
        }
        if let foregroundSession {
            let tasks: [URLSessionTask] = await withCheckedContinuation { continuation in
                foregroundSession.getAllTasks { continuation.resume(returning: $0) }
            }
            result.append(contentsOf: tasks.map { ($0, .foregroundControl) })
        }
        return result
    }

    // MARK: - Download handling

    private func handleDownloadFinished(session: URLSession, task: URLSessionDownloadTask, location: URL) {
        let role: SpikeTransferRole = session === backgroundSession ? .background : .foregroundControl
        let key = SpikeTransferRecord.key(role: role, taskIdentifier: task.taskIdentifier)
        guard var record = activeRecords[key] ?? metadata.record(key: key) else { return }
        guard record.runIdentifier == nil || record.runIdentifier == runIdentifier else { return }
        let destination = scratch.destinationURL(
            role: record.role,
            profile: record.profile,
            taskIdentifier: task.taskIdentifier
        )
        let moveOutcome: String
        do {
            try scratch.moveSystemFile(at: location, to: destination)
            moveOutcome = "moved"
        } catch {
            moveOutcome = "move-failed"
        }
        record.fileMovedAt = Date().timeIntervalSince1970
        if moveOutcome == "moved" {
            record.scratchPath = destination.lastPathComponent
        } else {
            record.outcome = "move-failed"
        }
        activeRecords[key] = record
        metadata.upsert(record)

        recordTransportEvent(
            kind: "transfer-file-moved",
            caseID: record.caseID,
            detail: "System temporary download moved into disposable app-owned scratch before the delegate returned.",
            fields: [
                "role": role.rawValue,
                "taskIdentifier": String(task.taskIdentifier),
                "moveOutcome": moveOutcome,
                "file": destination.lastPathComponent,
                "fileMovedAt": String(record.fileMovedAt ?? 0),
                "transferCorrelationID": record.correlationIdentifier ?? "none",
                "runIdentifier": record.runIdentifier ?? runIdentifier,
            ]
        )

        guard moveOutcome == "moved" else {
            finalizeIfReady(key: key)
            return
        }

        let expected = record.expectedSHA256
        let caseID = record.caseID
        let recordRunIdentifier = record.runIdentifier ?? runIdentifier
        digestTasks[key] = Task { [weak self] in
            if ProcessInfo.processInfo.arguments.contains(SpikeContract.delayTransferDigestArgument) {
                try? await Task.sleep(for: .seconds(15))
            }
            let digest = await Task.detached(priority: .utility) {
                (try? SpikeScratchStore.digestFile(at: destination)) ?? "unreadable"
            }.value
            guard let self else { return }
            self.digestTasks[key] = nil
            guard var updated = self.activeRecords[key],
                  (updated.runIdentifier ?? self.runIdentifier) == recordRunIdentifier,
                  self.runIdentifier == recordRunIdentifier else { return }
            updated.digestSHA256 = digest
            updated.digestAt = Date().timeIntervalSince1970
            self.activeRecords[key] = updated
            self.metadata.upsert(updated)
            self.recordTransportEvent(
                kind: "transfer-hash",
                caseID: caseID,
                detail: "Computed SHA-256 of the downloaded scratch file.",
                fields: [
                    "role": role.rawValue,
                    "taskIdentifier": String(task.taskIdentifier),
                    "digestSHA256": digest,
                    "expectedSHA256": expected ?? "none",
                    "byteIdentical": expected.map { String($0 == digest) } ?? "unknown",
                    "digestAt": String(updated.digestAt ?? 0),
                    "runIdentifier": recordRunIdentifier,
                    "transferCorrelationID": updated.correlationIdentifier ?? "none",
                ]
            )
            self.finalizeIfReady(key: key)
        }
    }

    private func handleCompletion(session: URLSession, task: URLSessionTask, error: Error?) {
        let role: SpikeTransferRole = session === backgroundSession ? .background : .foregroundControl
        let key = SpikeTransferRecord.key(role: role, taskIdentifier: task.taskIdentifier)
        observedCompletionKeys.insert(key)
        resetPendingCompletionKeys.remove(key)
        guard var record = activeRecords[key] ?? metadata.record(key: key) else { return }
        guard record.runIdentifier == nil || record.runIdentifier == runIdentifier else { return }
        let nsError = error.map { $0 as NSError }
        let cancelled = nsError?.code == NSURLErrorCancelled && nsError?.domain == NSURLErrorDomain
        if record.outcome != "move-failed" {
            record.outcome = cancelled ? "cancelled" : (error == nil ? "completed" : "failed")
        }
        record.completionAt = Date().timeIntervalSince1970
        activeRecords[key] = record
        metadata.upsert(record)
        recordTransportEvent(
            kind: "transfer-completed",
            caseID: record.caseID,
            detail: cancelled
                ? "App-owned transfer was cancelled."
                : (error == nil ? "App-owned transfer completed." : "App-owned transfer failed."),
            fields: [
                "role": role.rawValue,
                "taskIdentifier": String(task.taskIdentifier),
                "outcome": record.outcome ?? "unknown",
                "errorDomain": nsError?.domain ?? "none",
                "errorCode": nsError.map { String($0.code) } ?? "none",
                "bytesReceived": String(task.countOfBytesReceived),
                "expectedBytes": String(task.countOfBytesExpectedToReceive),
                "digestSHA256": record.digestSHA256 ?? "none",
                "expectedSHA256": record.expectedSHA256 ?? "none",
                "completionAt": String(record.completionAt ?? 0),
                "runIdentifier": record.runIdentifier ?? runIdentifier,
                "transferCorrelationID": record.correlationIdentifier ?? "none",
            ]
        )
        finalizeIfReady(key: key)
    }

    private func finalizeIfReady(key: String) {
        defer { finalizeBackgroundEventsIfSettled() }
        guard let record = activeRecords[key], let outcome = record.outcome else { return }
        if outcome == "completed" && (record.scratchPath == nil || record.digestSHA256 == nil) {
            return
        }
        activeRecords[key] = nil
        lastReportedProgress[key] = nil
        metadata.remove(key: key)
        recordTransportEvent(
            kind: "transfer-settled",
            caseID: record.caseID,
            detail: "Transfer terminal delivery, file handling, digest work, and unfinished metadata cleanup reached a stable state.",
            fields: [
                "role": record.role,
                "taskIdentifier": String(record.taskIdentifier),
                "outcome": outcome,
                "digestSHA256": record.digestSHA256 ?? "none",
                "expectedSHA256": record.expectedSHA256 ?? "none",
                "completionAt": String(record.completionAt ?? 0),
                "fileMovedAt": String(record.fileMovedAt ?? 0),
                "digestAt": String(record.digestAt ?? 0),
                "activeRecordCount": String(activeRecords.count),
                "persistedUnfinishedMetadataCount": String(metadata.count),
                "runIdentifier": record.runIdentifier ?? runIdentifier,
                "transferCorrelationID": record.correlationIdentifier ?? "none",
            ]
        )
    }
}

extension SpikeTransferCoordinator: URLSessionDownloadDelegate {
    nonisolated func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        MainActor.assumeIsolated {
            let role: SpikeTransferRole = session === backgroundSession ? .background : .foregroundControl
            let key = SpikeTransferRecord.key(role: role, taskIdentifier: downloadTask.taskIdentifier)
            guard let record = activeRecords[key] else { return }
            if record.cancelAfterFirstProgress {
                downloadTask.cancel()
                return
            }
            let last = lastReportedProgress[key] ?? 0
            guard Int(totalBytesWritten) - last >= 1_048_576 || last == 0 else { return }
            lastReportedProgress[key] = Int(totalBytesWritten)
            recordTransportEvent(
                kind: "transfer-progress",
                caseID: record.caseID,
                detail: "Background-safe delegate progress callback.",
                fields: [
                    "role": role.rawValue,
                    "taskIdentifier": String(downloadTask.taskIdentifier),
                    "totalBytesWritten": String(totalBytesWritten),
                    "totalBytesExpectedToWrite": String(totalBytesExpectedToWrite),
                    "delta": String(bytesWritten),
                ]
            )
        }
    }

    nonisolated func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        MainActor.assumeIsolated {
            handleDownloadFinished(session: session, task: downloadTask, location: location)
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        MainActor.assumeIsolated {
            handleCompletion(session: session, task: task, error: error)
        }
    }

    nonisolated func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        MainActor.assumeIsolated {
            let method = challenge.protectionSpace.authenticationMethod
            let role: SpikeTransferRole = session === backgroundSession ? .background : .foregroundControl
            let fixtureHost = challenge.protectionSpace.host == SpikeContract.primaryHost
                || challenge.protectionSpace.host == SpikeContract.secondaryHost
            recordTransportEvent(
                kind: "auth-challenge",
                caseID: "authentication",
                detail: "App-owned session received an authentication challenge.",
                fields: [
                    "role": role.rawValue,
                    "taskIdentifier": String(task.taskIdentifier),
                    "method": method,
                    "host": challenge.protectionSpace.host,
                    "hasProposedCredential": String(challenge.proposedCredential != nil),
                    "previousFailureCount": String(challenge.previousFailureCount),
                ]
            )
            if method == NSURLAuthenticationMethodHTTPBasic, fixtureHost {
                completionHandler(
                    .useCredential,
                    URLCredential(
                        user: SpikeContract.syntheticUserName,
                        password: SpikeContract.syntheticPassword,
                        persistence: .none
                    )
                )
            } else {
                completionHandler(.performDefaultHandling, nil)
            }
        }
    }

    nonisolated func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        MainActor.assumeIsolated {
            let role: SpikeTransferRole = session === backgroundSession ? .background : .foregroundControl
            recordTransportEvent(
                kind: "redirect-decision-available",
                caseID: "redirect-session-surface",
                detail: "A per-hop redirect callback was available on this session type.",
                fields: [
                    "role": role.rawValue,
                    "status": String(response.statusCode),
                    "fromHost": response.url?.host ?? "unknown",
                    "fromPath": response.url?.path ?? "unknown",
                    "toHost": request.url?.host ?? "unknown",
                    "toPath": request.url?.path ?? "unknown",
                    "authorizationHeaderPresent": String(request.value(forHTTPHeaderField: "Authorization") != nil),
                    "cookieHeaderPresent": String(request.value(forHTTPHeaderField: "Cookie") != nil),
                ]
            )
            completionHandler(request)
        }
    }

    nonisolated func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        MainActor.assumeIsolated {
            finishBackgroundEvents()
        }
    }

    nonisolated func urlSession(_ session: URLSession, didBecomeInvalidWithError error: Error?) {
        MainActor.assumeIsolated {
            recordTransportEvent(
                kind: "session-invalidated",
                caseID: "runtime",
                detail: "A session was invalidated.",
                fields: [
                    "background": String(session === backgroundSession),
                    "errorCode": error.map { String(($0 as NSError).code) } ?? "none",
                ]
            )
        }
    }
}
