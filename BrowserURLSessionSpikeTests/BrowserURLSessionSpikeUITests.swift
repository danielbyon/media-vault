import CryptoKit
import Foundation
import XCTest

/// Spike 2 runtime matrix.
///
/// Every test drives real rendered-page controls in the disposable host app,
/// then verifies what the separate host-process fixture server actually
/// observed. Requests made by WebKit are distinguishable from requests made by
/// the app-owned URLSession through the shared transport header, so a
/// successful download is never reported as an original WebKit transfer.
@MainActor
final class BrowserURLSessionSpikeUITests: XCTestCase {
    private var app: XCUIApplication!
    private let fixture = FixtureEvidenceClient()

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    // MARK: - Fixture case lookup

    private func fixtureCase(_ id: String) -> SpikeFixtureCase {
        guard let value = SpikeFixtureCase.all.first(where: { $0.id == id }) else {
            fatalError("unknown fixture case identifier: \(id)")
        }
        return value
    }

    // MARK: - App lifecycle helpers

    private func launchApp(reset: Bool = true, additionalArguments: [String] = []) {
        let application = XCUIApplication()
        application.launchArguments = (reset ? [SpikeContract.resetLaunchArgument] : []) + additionalArguments
        application.launch()
        app = application
    }

    private func waitForReady(timeout: TimeInterval = 40) async {
        XCTAssertTrue(
            app.staticTexts[SpikeControlIdentifier.ready].waitForExistence(timeout: timeout),
            "ready control did not appear"
        )
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if app.staticTexts[SpikeControlIdentifier.ready].label == "READY" {
                return
            }
            try? await Task.sleep(for: .milliseconds(300))
        }
        XCTFail("fixture server never became ready; status: \(app.staticTexts[SpikeControlIdentifier.statusLabel].label)")
    }

    /// Wait for the app launch event produced by the process started in this test.
    private func waitForAppLaunch(after previousInstance: String?) async throws -> FixtureEvidence.AppEvent {
        let evidence = try await waitForEvidence(timeout: 50, description: "current app process launch recorded") {
            $0.appEvent(kind: "app-launched", matching: {
                $0.fields["processInstance"] != previousInstance
            }) != nil
        }
        return try XCTUnwrap(evidence.appEvent(kind: "app-launched", matching: {
            $0.fields["processInstance"] != previousInstance
        }))
    }

    private func latestProcessInstance() async throws -> String? {
        try await fixture.fetchEvidence()?.appEvent(kind: "app-launched")?.fields["processInstance"]
    }

    private func waitForFixtureMenu(timeout: TimeInterval = 25) {
        XCTAssertTrue(
            app.staticTexts[SpikeAnchor.fixtureMenuReady].waitForExistence(timeout: timeout),
            "fixture menu page did not finish loading"
        )
    }

    private func openMenu() {
        app.buttons[SpikeControlIdentifier.menuButton].tap()
        waitForFixtureMenu()
    }

    /// Fixture flow page reached by each rendered flow link.
    private static let flowPaths: [String: String] = [
        "open login flow": SpikeContract.Path.login,
        "open vault flow": SpikeContract.Path.vaultGuard,
        "open cookie scope flow": SpikeContract.Path.scopeSetup,
        "open referer flow": SpikeContract.Path.refererGuard,
        "open origin flow": SpikeContract.Path.originGuard,
        "open user agent flow": SpikeContract.Path.userAgentGuard,
        "open post flow": SpikeContract.Path.postForm,
        "open signed url flow": SpikeContract.Path.signedMint,
        "open blob flow": SpikeContract.Path.blobGuard,
        "open authentication flow": SpikeContract.Path.authGuard,
        "open lifecycle flow": SpikeContract.Path.lifecycleGuard,
        "back to primary fixture menu": SpikeContract.Path.menu,
    ]

    /// Open a fixture flow page and confirm the host-process server served it.
    ///
    /// A tap on a scrolled WebKit link can silently miss its target, so the
    /// tap is repeated while no new request for the flow page has been seen.
    private func openFlow(
        _ label: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        guard let path = Self.flowPaths[label] else {
            XCTFail("unknown fixture flow: \(label)", file: file, line: line)
            return
        }
        let baseline = await latestRequestSequence()
        for _ in 1...3 {
            tapPageControl(label, file: file, line: line)
            let served = try? await waitForEvidence(
                timeout: 20,
                description: "\(label) served from \(path)"
            ) { evidence in
                evidence.requests.contains {
                    $0.path == path
                        && $0.transport == "webkit"
                        && $0.sequence > baseline
                        && $0.completed == true
                }
            }
            if served != nil { return }
        }
        XCTFail("flow page \(path) was never served after tapping \(label)", file: file, line: line)
    }

    /// Highest request sequence number the fixture server has recorded.
    private func latestRequestSequence() async -> Int {
        guard let evidence = try? await fixture.fetchEvidence() else { return 0 }
        return evidence.requests.map(\.sequence).max() ?? 0
    }

    private func selectProfile(_ identifier: String) {
        app.buttons[identifier].tap()
        waitForFixtureMenu()
    }

    /// Tap a rendered-page control (link or button) by its accessible label.
    private func tapPageControl(
        _ label: String,
        timeout: TimeInterval = 25,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let link = app.links[label]
        if link.waitForExistence(timeout: timeout) {
            link.tap()
            return
        }
        let button = app.buttons[label]
        if button.waitForExistence(timeout: 10) {
            button.tap()
            return
        }
        let text = app.staticTexts[label]
        if text.waitForExistence(timeout: 5) {
            text.tap()
            return
        }
        XCTFail("rendered-page control not found: \(label)", file: file, line: line)
    }

    // MARK: - Evidence helpers

    private func waitForEvidence(
        timeout: TimeInterval = 60,
        description: String,
        predicate: (FixtureEvidence) -> Bool
    ) async throws -> FixtureEvidence {
        let deadline = Date().addingTimeInterval(timeout)
        var lastEvidence: FixtureEvidence?
        while Date() < deadline {
            if let evidence = try await fixture.fetchEvidence() {
                lastEvidence = evidence
                if predicate(evidence) {
                    return evidence
                }
            }
            try? await Task.sleep(for: .milliseconds(400))
        }
        throw SpikeTestFailure.timeout(
            "timed out waiting for fixture evidence: \(description); recent request paths: \(lastEvidence?.requests.map(\.path).suffix(8).description ?? "none")"
        )
    }

    /// Wait until a path has a transfer from the app-owned session.
    @discardableResult
    private func waitForTransfer(
        path: String,
        transport: String = SpikeContract.Transport.backgroundURLSession.rawValue,
        transferCorrelationID: String? = nil,
        afterSequence: Int? = nil,
        completed: Bool = true,
        timeout: TimeInterval = 60
    ) async throws -> FixtureEvidence {
        try await waitForEvidence(timeout: timeout, description: "\(path) over \(transport) completed=\(completed)") { evidence in
            evidence.requests.contains { request in
                request.path == path
                    && request.transport == transport
                    && request.completed == completed
                    && (transferCorrelationID == nil || request.transferCorrelationID == transferCorrelationID)
                    && (afterSequence.map { request.sequence > $0 } ?? true)
            }
        }
    }

    /// Wait for a transfer task created after the supplied correlation snapshot.
    private func waitForTransferStart(
        path: String,
        role: String = "background",
        excluding previousCorrelations: Set<String>,
        processInstance: String? = nil,
        runIdentifier: String? = nil,
        timeout: TimeInterval = 60
    ) async throws -> FixtureEvidence.AppEvent {
        let evidence = try await waitForEvidence(timeout: timeout, description: "new \(role) task for \(path)") {
            $0.appEvents(kind: "transfer-started").contains { event in
                event.fields["path"] == path
                    && event.fields["role"] == role
                    && event.fields["transferCorrelationID"].map { !previousCorrelations.contains($0) } == true
                    && (processInstance == nil || event.fields["processInstance"] == processInstance)
                    && (runIdentifier == nil || event.fields["runIdentifier"] == runIdentifier)
            }
        }
        return try XCTUnwrap(evidence.appEvent(kind: "transfer-started", matching: { event in
            event.fields["path"] == path
                && event.fields["role"] == role
                && event.fields["transferCorrelationID"].map { !previousCorrelations.contains($0) } == true
                && (processInstance == nil || event.fields["processInstance"] == processInstance)
                && (runIdentifier == nil || event.fields["runIdentifier"] == runIdentifier)
        }))
    }

    private func transferCorrelations(in evidence: FixtureEvidence) -> Set<String> {
        Set(evidence.appEvents(kind: "transfer-started").compactMap { $0.fields["transferCorrelationID"] })
    }

    /// Wait until the app reported a scratch-file hash for a fixture asset.
    private func waitForHashEvent(
        asset: SpikeFixtureAsset,
        transferCorrelationID: String? = nil,
        timeout: TimeInterval = 60
    ) async throws -> FixtureEvidence {
        let expected = SpikePayload.sha256Hex(asset.payload)
        return try await waitForEvidence(timeout: timeout, description: "app hash event for \(asset.rawValue)") { evidence in
            evidence.appEvents.contains {
                $0.kind == "transfer-hash"
                    && $0.fields["expectedSHA256"] == expected
                    && (transferCorrelationID == nil || $0.fields["transferCorrelationID"] == transferCorrelationID)
            }
        }
    }

    /// Verify server-observed bytes, app-owned scratch bytes, and the
    /// deterministic fixture payload all agree.
    private func assertByteIdentical(
        path: String,
        asset: SpikeFixtureAsset,
        segment: String,
        evidence: FixtureEvidence,
        transferCorrelationID: String? = nil,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let expected = SpikePayload.sha256Hex(asset.payload)
        // The scratch digest is computed after the download finishes, so wait
        // for this transfer's own hash event instead of assuming that it has
        // already reached the host-process server.
        let evidence = (try? await waitForEvidence(
            timeout: 30,
            description: "app scratch hash event for \(asset.rawValue) from \(path)"
        ) { candidate in
            candidate.appEvents.contains {
                $0.kind == "transfer-hash"
                    && $0.fields["expectedSHA256"] == expected
                    && (transferCorrelationID == nil
                        ? $0.caseID == self.transferCaseID(for: path)
                        : $0.fields["transferCorrelationID"] == transferCorrelationID)
            }
        }) ?? evidence
        let recorded = evidence.requests.last {
            $0.path == path
                && $0.transport == SpikeContract.Transport.backgroundURLSession.rawValue
                && (transferCorrelationID == nil || $0.transferCorrelationID == transferCorrelationID)
        }
        XCTAssertEqual(recorded?.responsePayloadSHA256, expected, "server-observed payload hash mismatch for \(path)", file: file, line: line)
        XCTAssertEqual(recorded?.sentByteCount, asset.byteCount, "server-observed byte count mismatch for \(path)", file: file, line: line)

        let hashEvent = evidence.appEvents.last {
            $0.kind == "transfer-hash"
                && $0.fields["expectedSHA256"] == expected
                && (transferCorrelationID == nil
                    ? $0.caseID == transferCaseID(for: path)
                    : $0.fields["transferCorrelationID"] == transferCorrelationID)
        }
        XCTAssertNotNil(hashEvent, "no app scratch hash event for \(asset.rawValue)", file: file, line: line)
        XCTAssertEqual(hashEvent?.fields["digestSHA256"], expected, "scratch file digest mismatch for \(path)", file: file, line: line)
        XCTAssertEqual(hashEvent?.fields["byteIdentical"], "true", "scratch file was not byte-identical for \(path)", file: file, line: line)

        postVerdict(
            segment,
            status: "PASS",
            detail: "server payload SHA-256 = scratch SHA-256 = expected \(asset.rawValue) payload SHA-256"
        )
    }

    /// Case identifier the host app derives for one app-owned transfer path.
    private func transferCaseID(for path: String) -> String {
        let trimmed = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return trimmed.replacingOccurrences(of: "/", with: "-") + "-transfer"
    }

    /// Post one sanitized per-case verdict fragment to the fixture server.
    private func postVerdict(_ caseID: String, status: String, detail: String) {
        fixture.postVerdict(caseID: caseID, status: status, detail: detail)
    }

    private func screenshotAttachment(name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func jsonAttachment(name: String, json: String) {
        let attachment = XCTAttachment(string: json)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

/// Failure surfaced by the matrix when a bounded wait expires.
enum SpikeTestFailure: Error, CustomStringConvertible {
    case timeout(String)

    var description: String {
        switch self {
        case .timeout(let message): "timeout: \(message)"
        }
    }
}

/// Deterministic payload hashing shared with the fixture contract generator.
enum SpikePayload {
    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Fixture evidence model

struct FixtureEvidence: Decodable {
    struct Request: Decodable {
        let sequence: Int
        let timestamp: Double
        let method: String
        let path: String
        let transferCorrelationID: String?
        let queryKeys: [String]
        let host: String
        let transport: String
        let headerNames: [String]
        let hasCookieHeader: Bool
        let cookieMarkers: [String]
        let hasSyntheticAuthCookie: Bool
        let hasAuthorizationHeader: Bool
        let authorizationAccepted: Bool?
        let refererHostPath: String?
        let originValue: String?
        let userAgentValue: String?
        let bodyByteCount: Int
        let bodySHA256: String?
        let assetID: String?
        let responsePayloadSHA256: String?
        let responseStatusCode: Int?
        let declaredByteCount: Int
        let sentByteCount: Int
        let completed: Bool
        let responseCompletedAt: Double?
        let sendSamples: [SendSample]
        let clientClosedEarly: Bool
        let throttleMilliseconds: Int?
        let tokenLabel: String?
        let tokenConsumedByThisRequest: Bool?
        let note: String?
    }

    struct SendSample: Decodable {
        let timestamp: Double
        let cumulativeBytes: Int
    }

    struct LifecycleMarker: Decodable {
        let timestamp: Double
        let label: String
        let fields: [String: String]
    }

    struct AppEvent: Decodable {
        let timestamp: Double
        let kind: String
        let caseID: String
        let detail: String
        let fields: [String: String]
    }

    struct TokenRecord: Decodable {
        let label: String
        let consumed: Bool
        let consumedByTransport: String?
    }

    let schemaVersion: Int
    let runIdentifier: String
    let requests: [Request]
    let lifecycleMarkers: [LifecycleMarker]
    let appEvents: [AppEvent]
    let tokenLedger: [TokenRecord]
    let notes: [String]

    func requests(path: String, transport: String? = nil) -> [Request] {
        requests.filter { $0.path == path && (transport == nil || $0.transport == transport) }
    }

    func request(path: String, transport: String? = nil) -> Request? {
        requests(path: path, transport: transport).last
    }

    func appEvents(kind: String, caseID: String? = nil) -> [AppEvent] {
        appEvents.filter { $0.kind == kind && (caseID == nil || $0.caseID == caseID) }
    }

    func appEvent(kind: String, matching: (AppEvent) -> Bool) -> AppEvent? {
        appEvents.last { $0.kind == kind && matching($0) }
    }

    /// Most recent app event of a kind, regardless of the remaining fields.
    func appEvent(kind: String) -> AppEvent? {
        appEvent(kind: kind, matching: { _ in true })
    }

    func lifecycleMarker(label: String, taskIdentifier: String? = nil) -> LifecycleMarker? {
        lifecycleMarkers.last { marker in
            marker.label == label
                && (taskIdentifier == nil || marker.fields["taskIdentifier"] == taskIdentifier)
        }
    }
}

/// Minimal HTTP client for the host-process fixture server.
struct FixtureEvidenceClient {
    private let baseURL = URL(string: SpikeContract.baseURLString(host: SpikeContract.primaryHost))!

    private let session: URLSession

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        session = URLSession(configuration: configuration)
    }

    /// Clear fixture state before a case runs.
    func reset() async throws {
        var request = URLRequest(url: baseURL.appendingPathComponent(SpikeContract.Path.reset))
        request.httpMethod = "POST"
        _ = try await session.data(for: request)
    }

    /// Fetch the sanitized evidence document.
    func fetchEvidence() async throws -> FixtureEvidence? {
        var request = URLRequest(url: baseURL.appendingPathComponent(SpikeContract.Path.evidence))
        request.httpMethod = "GET"
        guard let (data, response) = try? await session.data(for: request) else { return nil }
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return try? JSONDecoder().decode(FixtureEvidence.self, from: data)
    }

    /// Fetch the raw sanitized evidence document text, for redaction checks.
    func fetchRawEvidence() async throws -> String? {
        var request = URLRequest(url: baseURL.appendingPathComponent(SpikeContract.Path.evidence))
        request.httpMethod = "GET"
        guard let (data, response) = try? await session.data(for: request) else { return nil }
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Post one sanitized app event.
    @discardableResult
    func postAppEvent(kind: String, caseID: String, detail: String, fields: [String: String] = [:]) -> Bool {
        var request = URLRequest(url: baseURL.appendingPathComponent(SpikeContract.Path.appEvent))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let payload: [String: Any] = [
            "timestamp": Date().timeIntervalSince1970,
            "kind": kind,
            "caseID": caseID,
            "detail": detail,
            "fields": fields,
        ]
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else { return false }
        request.httpBody = body
        var result = false
        let semaphore = DispatchSemaphore(value: 0)
        session.dataTask(with: request) { _, response, _ in
            result = (response as? HTTPURLResponse)?.statusCode == 204
            semaphore.signal()
        }.resume()
        _ = semaphore.wait(timeout: .now() + 10)
        return result
    }

    /// Post one per-case verdict fragment.
    func postVerdict(caseID: String, status: String, detail: String) {
        _ = postAppEvent(kind: "verdict", caseID: caseID, detail: status, fields: ["detail": detail])
    }

    /// Ask the independent host fixture server to timestamp a lifecycle boundary.
    func markLifecycle(
        _ label: String,
        taskIdentifier: String? = nil,
        processInstance: String? = nil
    ) async -> Bool {
        guard var components = URLComponents(
            url: baseURL.appendingPathComponent(SpikeContract.Path.lifecycleMarker),
            resolvingAgainstBaseURL: false
        ) else { return false }
        var queryItems = [URLQueryItem(name: "label", value: label)]
        if let taskIdentifier { queryItems.append(URLQueryItem(name: "taskIdentifier", value: taskIdentifier)) }
        if let processInstance { queryItems.append(URLQueryItem(name: "processInstance", value: processInstance)) }
        components.queryItems = queryItems
        guard let url = components.url else { return false }
        let request = URLRequest(url: url)
        guard let (_, response) = try? await session.data(for: request) else { return false }
        return (response as? HTTPURLResponse)?.statusCode == 204
    }
}

// MARK: - Spike 2 matrix

extension BrowserURLSessionSpikeUITests {
    /// Tap a case's transfer link from a freshly loaded fixture menu.
    private func tapTransfer(_ id: String) {
        openMenu()
        guard let label = fixtureCase(id).transferLabel else {
            XCTFail("fixture case has no transfer control: \(id)")
            return
        }
        tapPageControl(label)
    }

    /// Tap a case's browser control link from a freshly loaded fixture menu.
    private func tapControl(_ id: String) {
        openMenu()
        guard let label = fixtureCase(id).controlLabel else {
            XCTFail("fixture case has no control: \(id)")
            return
        }
        tapPageControl(label)
    }

    // MARK: 1 - direct resources and redirects

    func test01DirectResourcesAndRedirects() async throws {
        try await fixture.reset()
        launchApp()
        await waitForReady()
        waitForFixtureMenu()

        // Still image: browser control versus app-owned transfer.
        var controlBaseline = await latestRequestSequence()
        tapControl("direct-still")
        var evidence = try await waitForEvidence(description: "control still served") {
            $0.requests(path: SpikeContract.Path.stillControl, transport: "webkit").contains {
                $0.sequence > controlBaseline && $0.completed
            }
        }
        var requestBaseline = await latestRequestSequence()
        var priorCorrelations = transferCorrelations(in: evidence)
        tapTransfer("direct-still")
        let stillStart = try await waitForTransferStart(
            path: SpikeContract.Path.stillTransfer,
            excluding: priorCorrelations
        )
        let stillCorrelation = try XCTUnwrap(stillStart.fields["transferCorrelationID"])
        evidence = try await waitForTransfer(
            path: SpikeContract.Path.stillTransfer,
            transferCorrelationID: stillCorrelation,
            afterSequence: requestBaseline
        )
        evidence = try await waitForHashEvent(asset: .stillImage, transferCorrelationID: stillCorrelation)
        // The foreground control is a second, independent transfer, so it can
        // finish after the background one; wait for its own evidence.
        let foregroundStillStart = try await waitForTransferStart(
            path: SpikeContract.Path.stillTransfer,
            role: "foreground-control",
            excluding: priorCorrelations
        )
        let foregroundStillCorrelation = try XCTUnwrap(foregroundStillStart.fields["transferCorrelationID"])
        evidence = try await waitForTransfer(
            path: SpikeContract.Path.stillTransfer,
            transport: SpikeContract.Transport.foregroundURLSession.rawValue,
            transferCorrelationID: foregroundStillCorrelation,
            afterSequence: requestBaseline
        )
        XCTAssertEqual(
            evidence.request(path: SpikeContract.Path.stillControl, transport: "webkit")?.responsePayloadSHA256,
            evidence.request(path: SpikeContract.Path.stillTransfer)?.responsePayloadSHA256,
            "control and transfer payload hashes differ for the still image"
        )
        await assertByteIdentical(
            path: SpikeContract.Path.stillTransfer,
            asset: .stillImage,
            segment: "direct-still",
            evidence: evidence,
            transferCorrelationID: stillCorrelation
        )
        XCTAssertNotNil(
            evidence.request(path: SpikeContract.Path.stillTransfer, transport: SpikeContract.Transport.foregroundURLSession.rawValue),
            "foreground session control request missing for the still image"
        )

        // Video resource.
        controlBaseline = await latestRequestSequence()
        tapControl("direct-clip")
        evidence = try await waitForEvidence(description: "control clip served") {
            $0.requests(path: SpikeContract.Path.clipControl, transport: "webkit").contains {
                $0.sequence > controlBaseline && $0.completed
            }
        }
        requestBaseline = await latestRequestSequence()
        priorCorrelations = transferCorrelations(in: evidence)
        tapTransfer("direct-clip")
        let clipStart = try await waitForTransferStart(
            path: SpikeContract.Path.clipTransfer,
            excluding: priorCorrelations
        )
        let clipCorrelation = try XCTUnwrap(clipStart.fields["transferCorrelationID"])
        evidence = try await waitForTransfer(
            path: SpikeContract.Path.clipTransfer,
            transferCorrelationID: clipCorrelation,
            afterSequence: requestBaseline
        )
        evidence = try await waitForHashEvent(asset: .clipVideo, transferCorrelationID: clipCorrelation)
        await assertByteIdentical(
            path: SpikeContract.Path.clipTransfer,
            asset: .clipVideo,
            segment: "direct-clip",
            evidence: evidence,
            transferCorrelationID: clipCorrelation
        )

        // Single redirect: the app-owned session must follow it itself and keep
        // the experiment's transport header on every hop.
        controlBaseline = await latestRequestSequence()
        tapControl("redirect-single")
        _ = try await waitForEvidence(description: "control single redirect") {
            $0.requests(path: SpikeContract.Path.redirectControlSingle, transport: "webkit").contains {
                $0.sequence > controlBaseline
            } && $0.requests(path: SpikeContract.Path.stillControl, transport: "webkit").contains {
                $0.sequence > controlBaseline && $0.completed
            }
        }
        requestBaseline = await latestRequestSequence()
        evidence = try await waitForEvidence(description: "single redirect control evidence") {
            $0.requests(path: SpikeContract.Path.redirectControlSingle, transport: "webkit").contains {
                $0.sequence > controlBaseline
            }
        }
        priorCorrelations = transferCorrelations(in: evidence)
        tapTransfer("redirect-single")
        let singleRedirectStart = try await waitForTransferStart(
            path: SpikeContract.Path.redirectTransferSingle,
            excluding: priorCorrelations
        )
        let singleRedirectCorrelation = try XCTUnwrap(singleRedirectStart.fields["transferCorrelationID"])
        evidence = try await waitForTransfer(
            path: SpikeContract.Path.stillTransfer,
            transferCorrelationID: singleRedirectCorrelation,
            afterSequence: requestBaseline
        )
        evidence = try await waitForHashEvent(asset: .stillImage, transferCorrelationID: singleRedirectCorrelation)
        let singleRedirectHop = evidence.requests.first {
            $0.path == SpikeContract.Path.redirectTransferSingle
                && $0.sequence > requestBaseline
                && $0.transferCorrelationID == singleRedirectCorrelation
        }
        XCTAssertEqual(singleRedirectHop?.transport, SpikeContract.Transport.backgroundURLSession.rawValue)
        await assertByteIdentical(
            path: SpikeContract.Path.stillTransfer,
            asset: .stillImage,
            segment: "redirect-single",
            evidence: evidence,
            transferCorrelationID: singleRedirectCorrelation
        )

        // Redirect chain: three hops, all owned by the app-owned session.
        controlBaseline = await latestRequestSequence()
        tapControl("redirect-chain")
        _ = try await waitForEvidence(description: "control redirect chain") {
            $0.requests(path: SpikeContract.Path.redirectControlChain, transport: "webkit").contains {
                $0.sequence > controlBaseline
            } && $0.requests(path: SpikeContract.Path.redirectChainControlSecond, transport: "webkit").contains {
                $0.sequence > controlBaseline
            } && $0.requests(path: SpikeContract.Path.clipControl, transport: "webkit").contains {
                $0.sequence > controlBaseline && $0.completed
            }
        }
        requestBaseline = await latestRequestSequence()
        evidence = try await waitForEvidence(description: "redirect chain control evidence") {
            $0.requests(path: SpikeContract.Path.clipControl, transport: "webkit").contains {
                $0.sequence > controlBaseline && $0.completed
            }
        }
        priorCorrelations = transferCorrelations(in: evidence)
        tapTransfer("redirect-chain")
        let chainStart = try await waitForTransferStart(
            path: SpikeContract.Path.redirectTransferChain,
            excluding: priorCorrelations
        )
        let chainCorrelation = try XCTUnwrap(chainStart.fields["transferCorrelationID"])
        evidence = try await waitForTransfer(
            path: SpikeContract.Path.clipTransfer,
            transferCorrelationID: chainCorrelation,
            afterSequence: requestBaseline
        )
        evidence = try await waitForHashEvent(asset: .clipVideo, transferCorrelationID: chainCorrelation)
        let chainHops = [
            SpikeContract.Path.redirectTransferChain,
            SpikeContract.Path.redirectChainTransferSecond,
            SpikeContract.Path.clipTransfer,
        ]
        for hop in chainHops {
            let request = evidence.requests.first {
                $0.path == hop
                    && $0.sequence > requestBaseline
                    && $0.transferCorrelationID == chainCorrelation
            }
            XCTAssertEqual(
                request?.transport,
                SpikeContract.Transport.backgroundURLSession.rawValue,
                "redirect hop was not performed by the app-owned session: \(hop)"
            )
            XCTAssertNotNil(request, "redirect hop missing from the current task: \(hop)")
        }
        XCTAssertEqual(evidence.requests.first { $0.path == SpikeContract.Path.redirectTransferChain && $0.transferCorrelationID == chainCorrelation }?.responseStatusCode, 302)
        XCTAssertEqual(evidence.requests.first { $0.path == SpikeContract.Path.redirectChainTransferSecond && $0.transferCorrelationID == chainCorrelation }?.responseStatusCode, 302)
        XCTAssertEqual(evidence.requests.first { $0.path == SpikeContract.Path.clipTransfer && $0.transferCorrelationID == chainCorrelation }?.responseStatusCode, 200)
        await assertByteIdentical(
            path: SpikeContract.Path.clipTransfer,
            asset: .clipVideo,
            segment: "redirect-chain",
            evidence: evidence,
            transferCorrelationID: chainCorrelation
        )
        screenshotAttachment(name: "01-direct-resources")
    }

    // MARK: 2 - response-triggered attachment

    func test02AttachmentResponseTriggeredTransfer() async throws {
        launchApp()
        await waitForReady()
        waitForFixtureMenu()

        // Browser control: WebKit performs its own download; no app API can
        // observe its completion, which is recorded, not claimed.
        tapControl("attachment")
        var evidence = try await waitForEvidence(description: "webkit attachment served and observed") {
            $0.request(path: SpikeContract.Path.attachmentControl, transport: "webkit")?.completed == true
                && $0.appEvent(kind: "navigation-action-observed") {
                    $0.fields["path"] == SpikeContract.Path.attachmentControl
                } != nil
        }
        let attachmentAction = evidence.appEvent(kind: "navigation-action-observed") {
            $0.fields["path"] == SpikeContract.Path.attachmentControl
        }
        XCTAssertEqual(attachmentAction?.fields["shouldPerformDownload"], "false")
        XCTAssertNil(
            evidence.appEvent(kind: "navigation-response-observed") {
                $0.fields["path"] == SpikeContract.Path.attachmentControl
            },
            "WebKit must not consult the response policy when it performs an attachment download itself"
        )
        postVerdict("attachment-control", status: "PARTIAL", detail: "WebKit performed the attachment download itself: the app observed the action and the served bytes but was never asked for a response policy and has no download completion API")

        // Response-triggered transfer: the action is allowed so the response can
        // reveal the attachment, then the response policy cancels and the
        // app-owned session transfers once.
        tapTransfer("attachment")
        evidence = try await waitForTransfer(path: SpikeContract.Path.attachmentTransfer, timeout: 90)
        evidence = try await waitForHashEvent(asset: .largeAttachment, timeout: 90)
        let initial = evidence.requests(path: SpikeContract.Path.attachmentTransfer, transport: "webkit")
        XCTAssertGreaterThanOrEqual(initial.count, 1, "expected at least one unavoidable WebKit request")
        XCTAssertEqual(initial.first?.clientClosedEarly, true, "the first WebKit request was not cancelled before the body finished")
        XCTAssertEqual(initial.first?.completed, false)
        XCTAssertLessThan(initial.first?.sentByteCount ?? .max, initial.first?.declaredByteCount ?? 0)
        let transfer = evidence.request(path: SpikeContract.Path.attachmentTransfer)
        XCTAssertEqual(transfer?.transport, SpikeContract.Transport.backgroundURLSession.rawValue)
        XCTAssertEqual(transfer?.completed, true)
        XCTAssertEqual(
            evidence.requests(path: SpikeContract.Path.attachmentTransfer, transport: SpikeContract.Transport.backgroundURLSession.rawValue).count,
            1,
            "the app-owned session must transfer the attachment exactly once"
        )
        await assertByteIdentical(path: SpikeContract.Path.attachmentTransfer, asset: .largeAttachment, segment: "attachment-response-triggered", evidence: evidence)
        screenshotAttachment(name: "02-attachment")
    }

    // MARK: 3 - session cookies, scope, and origin isolation

    func test03SessionCookiesScopeAndIsolation() async throws {
        launchApp()
        await waitForReady()
        waitForFixtureMenu()

        // Browser login through the rendered form; the cookie lands in the
        // page's exact data store.
        try await openFlow("open login flow")
        tapPageControl(SpikeAnchor.loginSubmitButton)
        var evidence = try await waitForEvidence(description: "login cookie issued") {
            $0.appEvents.contains { $0.kind == "navigation-event" }
        }
        tapPageControl(SpikeAnchor.loginControlLink)
        evidence = try await waitForEvidence(description: "vault control served") {
            $0.request(path: SpikeContract.Path.vaultControl, transport: "webkit")?.completed == true
        }
        XCTAssertEqual(evidence.request(path: SpikeContract.Path.vaultControl, transport: "webkit")?.hasSyntheticAuthCookie, true)

        openMenu()
        try await openFlow("open vault flow")
        tapPageControl(SpikeAnchor.loginTransferLink)
        evidence = try await waitForTransfer(path: SpikeContract.Path.vaultTransfer)
        evidence = try await waitForHashEvent(asset: .stillImage)
        let vaultTransfer = evidence.request(path: SpikeContract.Path.vaultTransfer)
        XCTAssertEqual(vaultTransfer?.hasSyntheticAuthCookie, true, "app-owned transfer did not carry the browser session cookie")
        XCTAssertEqual(vaultTransfer?.hasAuthorizationHeader, false)
        await assertByteIdentical(path: SpikeContract.Path.vaultTransfer, asset: .stillImage, segment: "vault-cookie-transfer", evidence: evidence)

        // Cookie scope markers: path, expiry, secure, and other-host markers
        // must never reach the transfer.
        openMenu()
        try await openFlow("open cookie scope flow")
        tapPageControl(SpikeAnchor.scopeOtherHostLink)
        try await openFlow("back to primary fixture menu")
        waitForFixtureMenu()
        try await openFlow("open cookie scope flow")
        tapPageControl(SpikeAnchor.scopeProbeTransferLink)
        evidence = try await waitForEvidence(description: "scope probe transfer") {
            $0.request(path: SpikeContract.Path.scopeProbeTransfer)?.completed == true
                && $0.appEvent(kind: "cookie-bridge") { $0.fields["path"] == SpikeContract.Path.scopeProbeTransfer } != nil
        }
        let scopeProbe = evidence.request(path: SpikeContract.Path.scopeProbeTransfer)
        XCTAssertEqual(scopeProbe?.cookieMarkers ?? [], [], "out-of-scope marker cookies reached the transport")
        let bridgeEvent = evidence.appEvent(kind: "cookie-bridge") { $0.fields["path"] == SpikeContract.Path.scopeProbeTransfer }
        XCTAssertNotNil(bridgeEvent, "cookie bridge did not record a scope decision")
        XCTAssertTrue(
            bridgeEvent?.fields["observedNames"]?.contains("spike-scope-secure") == true,
            "the secure marker must be present in the originating store before scope filtering",
        )
        XCTAssertTrue(
            bridgeEvent?.fields["decisions"]?.contains("spike-scope-secure:out:secure-requires-https") == true,
            "the secure marker must be rejected by the bridge for the HTTP transfer URL",
        )
        XCTAssertEqual(bridgeEvent?.fields["includedNames"]?.contains("spike-scope-path"), false)
        XCTAssertEqual(bridgeEvent?.fields["includedNames"]?.contains("spike-scope-secure"), false)
        postVerdict("cookie-scope", status: "PASS", detail: "URL-scoped bridge excluded path/expired/secure/other-host markers from the transfer")

        // Credentials across redirects: same origin, then cross origin.
        openMenu()
        tapPageControl("transfer same-origin credentials")
        evidence = try await waitForEvidence(description: "same-origin credential redirect") {
            $0.request(path: SpikeContract.Path.credentialTerminal, transport: SpikeContract.Transport.backgroundURLSession.rawValue) != nil
        }
        let sameOriginInitial = evidence.requests(path: SpikeContract.Path.credentialTransferSameOrigin).last
        let sameOriginTerminal = evidence.request(path: SpikeContract.Path.credentialTerminal)
        XCTAssertEqual(sameOriginInitial?.hasAuthorizationHeader, true)
        XCTAssertEqual(sameOriginInitial?.hasSyntheticAuthCookie, true)
        XCTAssertEqual(sameOriginTerminal?.host.hasPrefix(SpikeContract.primaryHost), true)
        postVerdict(
            "credential-same-origin",
            status: "PASS",
            detail: "same-origin redirect terminal authorization=\(sameOriginTerminal?.hasAuthorizationHeader == true) cookie=\(sameOriginTerminal?.hasSyntheticAuthCookie == true)"
        )

        openMenu()
        tapPageControl("transfer cross-origin credentials")
        evidence = try await waitForEvidence(description: "cross-origin credential redirect") {
            $0.requests(path: SpikeContract.Path.credentialTerminal, transport: SpikeContract.Transport.backgroundURLSession.rawValue).contains { $0.host.hasPrefix(SpikeContract.secondaryHost) }
        }
        let crossInitial = evidence.requests(path: SpikeContract.Path.credentialTransferCrossOrigin).last
        let crossTerminal = evidence.requests(path: SpikeContract.Path.credentialTerminal, transport: SpikeContract.Transport.backgroundURLSession.rawValue)
            .last { $0.host.hasPrefix(SpikeContract.secondaryHost) }
        XCTAssertEqual(crossInitial?.hasAuthorizationHeader, true)
        XCTAssertEqual(crossInitial?.hasSyntheticAuthCookie, true)
        XCTAssertEqual(crossTerminal?.host.hasPrefix(SpikeContract.secondaryHost), true)
        let leaked = crossTerminal?.hasAuthorizationHeader == true || crossTerminal?.hasSyntheticAuthCookie == true
        postVerdict(
            "credential-cross-origin",
            status: leaked ? "FAIL" : "PASS",
            detail: leaked
                ? "URLSession forwarded credentials to the cross-origin redirect target; this transfer class is unsafe"
                : "URLSession did not forward credentials across the origin change (authorization=\(crossTerminal?.hasAuthorizationHeader == true) cookie=\(crossTerminal?.hasSyntheticAuthCookie == true))"
        )

        // Store isolation: the ephemeral page must not see the persistent
        // profile's session cookie.
        selectProfile(SpikeControlIdentifier.profileEphemeralButton)
        try await openFlow("open vault flow")
        tapPageControl(SpikeAnchor.loginControlLink)
        evidence = try await waitForEvidence(description: "ephemeral vault control denied") {
            $0.request(path: SpikeContract.Path.vaultControl, transport: "webkit")?.note == "session-cookie-missing"
        }
        openMenu()
        try await openFlow("open vault flow")
        tapPageControl(SpikeAnchor.loginTransferLink)
        evidence = try await waitForEvidence(description: "ephemeral vault transfer denied") {
            ($0.request(path: SpikeContract.Path.vaultTransfer)?.note == "session-cookie-missing")
        }
        XCTAssertEqual(evidence.request(path: SpikeContract.Path.vaultTransfer)?.hasSyntheticAuthCookie, false)
        postVerdict("store-isolation", status: "PASS", detail: "ephemeral profile had no access to the persistent profile's session cookie")

        selectProfile(SpikeControlIdentifier.profilePersistentButton)
        try await openFlow("open vault flow")
        tapPageControl(SpikeAnchor.loginControlLink)
        _ = try await waitForEvidence(description: "persistent vault control still authenticated") {
            $0.request(path: SpikeContract.Path.vaultControl, transport: "webkit")?.note == nil
        }
        screenshotAttachment(name: "03-cookies-scope-isolation")
    }

    // MARK: 4 - request header fidelity

    func test04RequestHeaderFidelity() async throws {
        launchApp()
        await waitForReady()
        waitForFixtureMenu()

        // Referer: observable in the navigation request and reconstructible.
        try await openFlow("open referer flow")
        tapPageControl(SpikeAnchor.refererTransferLink)
        var evidence = try await waitForTransfer(path: SpikeContract.Path.refererTransfer)
        let refererTransfer = evidence.request(path: SpikeContract.Path.refererTransfer)
        XCTAssertEqual(refererTransfer?.refererHostPath?.hasSuffix(SpikeContract.Path.refererGuard), true, "Referer was not reconstructed")
        await assertByteIdentical(path: SpikeContract.Path.refererTransfer, asset: .stillImage, segment: "referer", evidence: evidence)

        openMenu()
        try await openFlow("open referer flow")
        tapPageControl(SpikeAnchor.refererControlLink)
        evidence = try await waitForEvidence(description: "referer control") {
            $0.request(path: SpikeContract.Path.refererControl, transport: "webkit")?.completed == true
        }
        XCTAssertEqual(evidence.request(path: SpikeContract.Path.refererControl, transport: "webkit")?.refererHostPath?.hasSuffix(SpikeContract.Path.refererGuard), true)

        // Origin: not sent by top-level navigations, so neither could the
        // experiment invent it. Both sides must record the same absence.
        openMenu()
        try await openFlow("open origin flow")
        tapPageControl(SpikeAnchor.originTransferLink)
        evidence = try await waitForEvidence(description: "origin guard denied") {
            $0.request(path: SpikeContract.Path.originTransfer)?.note == "origin-missing-or-mismatched"
                && $0.appEvent(kind: "navigation-action-observed") {
                    $0.fields["path"] == SpikeContract.Path.originTransfer
                } != nil
        }
        XCTAssertNil(
            evidence.request(path: SpikeContract.Path.originTransfer)?.originValue,
            "the reconstructed request must not invent an Origin header"
        )
        XCTAssertEqual(
            evidence.appEvent(kind: "navigation-action-observed") {
                $0.fields["path"] == SpikeContract.Path.originTransfer
            }?.fields["originValue"],
            "absent"
        )
        postVerdict("origin", status: "UNVERIFIED", detail: "Origin is not observable for top-level navigations; the experiment refused to invent it")

        // User agent: copied from the observed request for owned fidelity, and
        // deliberately omitted for the default control.
        openMenu()
        try await openFlow("open user agent flow")
        tapPageControl(SpikeAnchor.userAgentTransferOwnedLink)
        evidence = try await waitForEvidence(description: "owned user agent transfer") {
            $0.request(path: SpikeContract.Path.userAgentTransferOwned)?.completed == true
        }
        XCTAssertEqual(evidence.request(path: SpikeContract.Path.userAgentTransferOwned)?.userAgentValue, SpikeContract.appOwnedUserAgent)
        postVerdict("user-agent-owned", status: "PASS", detail: "app-owned transfer reproduced the observed user agent exactly")

        openMenu()
        try await openFlow("open user agent flow")
        tapPageControl(SpikeAnchor.userAgentTransferDefaultLink)
        evidence = try await waitForEvidence(description: "default user agent transfer") {
            $0.request(path: SpikeContract.Path.userAgentTransferDefault)?.completed == true
        }
        let defaultUserAgent = evidence.request(path: SpikeContract.Path.userAgentTransferDefault)?.userAgentValue
        XCTAssertNotNil(defaultUserAgent)
        XCTAssertNotEqual(defaultUserAgent, SpikeContract.appOwnedUserAgent, "URLSession did not use its own default user agent")
        postVerdict("user-agent-default", status: "PASS", detail: "omitting the observed user agent produced the session default, so fidelity requires copying it")

        openMenu()
        try await openFlow("open user agent flow")
        tapPageControl(SpikeAnchor.userAgentControlLink)
        evidence = try await waitForEvidence(description: "browser user agent") {
            $0.request(path: SpikeContract.Path.userAgentControl, transport: "webkit")?.completed == true
        }
        XCTAssertEqual(evidence.request(path: SpikeContract.Path.userAgentControl, transport: "webkit")?.userAgentValue, SpikeContract.appOwnedUserAgent)
        screenshotAttachment(name: "04-header-fidelity")
    }

    // MARK: 5 - POST probe

    func test05PostProbeAndReplay() async throws {
        launchApp()
        await waitForReady()
        waitForFixtureMenu()

        try await openFlow("open post flow")
        tapPageControl(SpikeAnchor.postControlButton)
        var evidence = try await waitForEvidence(description: "browser post recorded") {
            $0.request(path: SpikeContract.Path.postControl, transport: "webkit")?.bodyByteCount ?? 0 > 0
        }
        let controlPost = evidence.request(path: SpikeContract.Path.postControl, transport: "webkit")
        XCTAssertEqual(controlPost?.method, "POST")
        XCTAssertGreaterThan(controlPost?.bodyByteCount ?? 0, 0)

        // The control submission replaced the form with its result page.
        openMenu()
        try await openFlow("open post flow")
        tapPageControl(SpikeAnchor.postTransferButton)
        evidence = try await waitForEvidence(description: "post probe recorded") {
            $0.appEvents.contains { $0.kind == "post-probe" && $0.fields["path"] == SpikeContract.Path.postTransfer }
        }
        let probe = evidence.appEvent(kind: "post-probe") { $0.fields["path"] == SpikeContract.Path.postTransfer }
        XCTAssertEqual(probe?.fields["method"], "POST")

        let formValuesAvailable = probe?.fields["formValuesAvailable"] == "true"
        let observedBodyBytes = Int(probe?.fields["bodyByteCount"] ?? "") ?? 0
        let bodyChannel = formValuesAvailable
            ? "willSubmit form values"
            : (observedBodyBytes > 0 ? "the encoded body on the intercepted request" : "no channel")
        XCTAssertTrue(
            formValuesAvailable || observedBodyBytes > 0,
            "the intercepted POST exposed no replayable body (values=\(formValuesAvailable) bytes=\(observedBodyBytes) stream=\(probe?.fields["hasBodyStream"] ?? "unknown"))"
        )
        if formValuesAvailable || observedBodyBytes > 0 {
            evidence = try await waitForEvidence(description: "single replayed post") {
                $0.requests(path: SpikeContract.Path.postTransfer, transport: SpikeContract.Transport.backgroundURLSession.rawValue).count == 1
                    && $0.requests(path: SpikeContract.Path.postTransfer, transport: SpikeContract.Transport.backgroundURLSession.rawValue).first?.completed == true
                    && $0.appEvent(kind: "post-replay-started") != nil
            }
            let replayed = evidence.requests(path: SpikeContract.Path.postTransfer, transport: SpikeContract.Transport.backgroundURLSession.rawValue)
            XCTAssertEqual(replayed.count, 1, "the intercepted POST must be replayed exactly once")
            XCTAssertEqual(replayed.first?.method, "POST")
            XCTAssertGreaterThan(replayed.first?.bodyByteCount ?? 0, 0)
            let expectedReplayBody = Data(
                "note=space+%26+amp%3Dplus+%2B+snowman+%E2%98%83".utf8,
            )
            let expectedReplayBodySHA256Prefix = String(
                SpikePayload.sha256Hex(expectedReplayBody).prefix(16),
            )
            XCTAssertEqual(
                replayed.first?.bodySHA256,
                expectedReplayBodySHA256Prefix,
                "the redacted body hash must match the percent-encoded form values",
            )
            XCTAssertNotNil(evidence.appEvent(kind: "post-replay-started"))
            if let observedHash = probe?.fields["bodySHA256"] {
                XCTAssertEqual(
                    replayed.first?.bodySHA256,
                    observedHash,
                    "the replayed POST body must match the body WebKit attached to the intercepted request"
                )
            }
            postVerdict("post-replay", status: "PASS", detail: "the POST body was observable through \(bodyChannel); one controlled replay through the background session carried the same \(replayed.first?.bodyByteCount ?? 0) bytes")
        } else {
            XCTAssertTrue(evidence.requests(path: SpikeContract.Path.postTransfer).isEmpty, "a POST without an observable body must never be reissued")
            postVerdict("post-replay", status: "FAIL", detail: "the POST body was not observable, so the request could not be replayed faithfully")
        }
        screenshotAttachment(name: "05-post")
    }

    // MARK: 6 - single-use signed URLs

    func test06SignedURLs() async throws {
        launchApp()
        await waitForReady()
        waitForFixtureMenu()

        // Pre-request interception: the token is never sent by WebKit.
        try await openFlow("open signed url flow")
        tapPageControl(SpikeAnchor.signedPreRequestLink)
        var evidence = try await waitForTransfer(path: SpikeContract.Path.signedPreRequest)
        evidence = try await waitForHashEvent(asset: .signedResource)
        let preRequest = evidence.requests(path: SpikeContract.Path.signedPreRequest, transport: SpikeContract.Transport.backgroundURLSession.rawValue).last
        XCTAssertNotNil(preRequest?.tokenLabel)
        XCTAssertEqual(preRequest?.tokenConsumedByThisRequest, true)
        XCTAssertEqual(preRequest?.queryKeys, ["token"])
        XCTAssertEqual(evidence.requests(path: SpikeContract.Path.signedPreRequest, transport: "webkit").count, 0, "WebKit must never send a pre-request intercepted token")
        let preRequestLabel = preRequest?.tokenLabel
        XCTAssertEqual(evidence.tokenLedger.last { $0.label == preRequestLabel }?.consumedByTransport, SpikeContract.Transport.backgroundURLSession.rawValue)
        await assertByteIdentical(path: SpikeContract.Path.signedPreRequest, asset: .signedResource, segment: "signed-pre-request", evidence: evidence)

        // Response-triggered one-time URL: the unavoidable WebKit request
        // consumes the token, so the app-owned replay can only fail.
        openMenu()
        try await openFlow("open signed url flow")
        tapPageControl(SpikeAnchor.signedResponseTriggeredLink)
        evidence = try await waitForEvidence(description: "response-triggered signed replay classified") {
            $0.requests(path: SpikeContract.Path.signedResponseTriggered, transport: "webkit").contains { $0.tokenConsumedByThisRequest == true }
                && $0.requests(path: SpikeContract.Path.signedResponseTriggered, transport: SpikeContract.Transport.backgroundURLSession.rawValue).contains { $0.note == "token-already-consumed" }
        }
        let initialSigned = evidence.requests(path: SpikeContract.Path.signedResponseTriggered, transport: "webkit").first { $0.tokenConsumedByThisRequest == true }
        let replayedSigned = evidence.requests(path: SpikeContract.Path.signedResponseTriggered, transport: SpikeContract.Transport.backgroundURLSession.rawValue).last { $0.note == "token-already-consumed" }
        XCTAssertEqual(initialSigned?.tokenConsumedByThisRequest, true)
        XCTAssertEqual(replayedSigned?.tokenConsumedByThisRequest, false)
        let consumedLabel = initialSigned?.tokenLabel
        XCTAssertEqual(evidence.tokenLedger.last { $0.label == consumedLabel }?.consumedByTransport, "webkit")
        postVerdict(
            "signed-response-triggered",
            status: "FAIL",
            detail: "a single-use URL discovered only at response time is consumed by the unavoidable WebKit request; the app-owned replay received token-already-consumed"
        )
        screenshotAttachment(name: "06-signed")
    }

    // MARK: 7 - HTTP authentication challenge

    func test07AuthenticationChallenge() async throws {
        launchApp()
        await waitForReady()
        waitForFixtureMenu()

        try await openFlow("open authentication flow")
        tapPageControl(SpikeAnchor.authControlLink)
        var evidence = try await waitForEvidence(description: "browser authentication retry") {
            $0.requests(path: SpikeContract.Path.authControl, transport: "webkit").contains { $0.authorizationAccepted == true }
                && $0.appEvent(kind: "browser-auth-challenge") { $0.fields["decision"] == "use-credential" } != nil
        }
        let browserUnauthorized = evidence.requests(path: SpikeContract.Path.authControl, transport: "webkit").first { $0.hasAuthorizationHeader == false }
        let browserAuthorized = evidence.requests(path: SpikeContract.Path.authControl, transport: "webkit").last { $0.authorizationAccepted == true }
        XCTAssertNotNil(browserUnauthorized)
        XCTAssertEqual(browserAuthorized?.hasAuthorizationHeader, true)
        XCTAssertNotNil(evidence.appEvent(kind: "browser-auth-challenge") { $0.fields["decision"] == "use-credential" })
        postVerdict("auth-browser", status: "PASS", detail: "WebKit surfaced the 401 to NavigationDeciding and accepted the supplied credential")

        openMenu()
        try await openFlow("open authentication flow")
        tapPageControl(SpikeAnchor.authTransferLink)
        evidence = try await waitForEvidence(timeout: 90, description: "app-owned authentication retry") {
            $0.requests(path: SpikeContract.Path.authTransfer, transport: SpikeContract.Transport.backgroundURLSession.rawValue).contains { $0.authorizationAccepted == true }
                && $0.appEvent(kind: "auth-challenge") { $0.fields["method"] == "NSURLAuthenticationMethodHTTPBasic" } != nil
        }
        let transferChallenge = evidence.appEvent(kind: "auth-challenge") { $0.fields["method"] == "NSURLAuthenticationMethodHTTPBasic" }
        XCTAssertNotNil(transferChallenge, "app-owned session never reported the HTTP basic challenge")
        XCTAssertEqual(transferChallenge?.fields["role"], "background")
        let transferAuthorized = evidence.requests(path: SpikeContract.Path.authTransfer, transport: SpikeContract.Transport.backgroundURLSession.rawValue).last { $0.authorizationAccepted == true }
        XCTAssertEqual(transferAuthorized?.hasAuthorizationHeader, true)
        postVerdict("auth-background", status: "PASS", detail: "background URLSession task-level challenge was delivered in the foreground and satisfied with the synthetic credential")
        screenshotAttachment(name: "07-authentication")
    }

    // MARK: 8 - failure and cancellation

    func test08FailureAndCancellation() async throws {
        launchApp()
        await waitForReady()
        waitForFixtureMenu()

        tapTransfer("failure-close")
        // The system retries an idempotent GET whose connection was closed
        // mid-body, so a terminal outcome is not guaranteed inside the test
        // window. Record whichever behavior actually occurs.
        var truncationEvidence: FixtureEvidence?
        do {
            truncationEvidence = try await waitForEvidence(
                timeout: 45,
                description: "truncated transfer reached a terminal outcome"
            ) {
                $0.appEvent(kind: "transfer-completed") { $0.caseID == "transfer-failure-close-transfer" } != nil
            }
        } catch {
            truncationEvidence = try? await fixture.fetchEvidence()
        }
        let closeAttempts = (truncationEvidence?.requests(path: SpikeContract.Path.failureClose) ?? []).filter {
            $0.transport == SpikeContract.Transport.backgroundURLSession.rawValue
        }
        XCTAssertGreaterThanOrEqual(closeAttempts.count, 1, "the truncated transfer was never attempted")
        XCTAssertEqual(closeAttempts.last?.completed, false)
        XCTAssertLessThan(closeAttempts.last?.sentByteCount ?? .max, closeAttempts.last?.declaredByteCount ?? 0)
        let terminalFailure = truncationEvidence?.appEvent(kind: "transfer-completed") {
            $0.caseID == "transfer-failure-close-transfer"
        }
        if terminalFailure?.fields["outcome"] == "failed" {
            postVerdict("failure-close", status: "PASS", detail: "server-side truncation surfaced a failed app-owned transfer with partial bytes after \(closeAttempts.count) attempt(s)")
        } else {
            postVerdict("failure-close", status: "PARTIAL", detail: "a truncated response produced \(closeAttempts.count) attempts with growing backoff and no terminal outcome inside the observation window; the platform retried the idempotent GET instead of surfacing a failure")
        }

        tapTransfer("failure-cancel")
        var evidence = try await waitForEvidence(timeout: 90, description: "cancelled transfer recorded") {
            $0.appEvent(kind: "transfer-completed") { $0.fields["outcome"] == "cancelled" } != nil
                && $0.requests(path: SpikeContract.Path.failureCancel).last?.clientClosedEarly == true
        }
        let cancelled = evidence.requests(path: SpikeContract.Path.failureCancel).last
        XCTAssertEqual(cancelled?.clientClosedEarly, true)
        XCTAssertLessThan(cancelled?.sentByteCount ?? .max, cancelled?.declaredByteCount ?? 0)
        postVerdict("failure-cancel", status: "PASS", detail: "task cancellation stopped the in-flight response and the server observed the early close")
        screenshotAttachment(name: "08-failures")
    }

    // MARK: 9 - page-bound blob resource

    func test09BlobLimitation() async throws {
        launchApp()
        await waitForReady()
        waitForFixtureMenu()

        try await openFlow("open blob flow")
        tapPageControl(SpikeAnchor.blobTriggerButton)
        let evidence = try await waitForEvidence(description: "blob action recorded") {
            $0.appEvents.contains { $0.kind == "blob-action-observed" }
        }
        let blobEvent = evidence.appEvent(kind: "blob-action-observed")
        XCTAssertEqual(blobEvent?.fields["scheme"], "blob")
        XCTAssertEqual(blobEvent?.fields["transferable"], "false")
        XCTAssertTrue(evidence.requests(path: "/blob").isEmpty)
        XCTAssertNil(evidence.appEvent(kind: "transfer-started") { $0.caseID.contains("blob") })
        postVerdict("blob", status: "FAIL", detail: "page-bound blob: resources have no HTTP(S) URL and were deliberately not transferred")
        screenshotAttachment(name: "09-blob")
    }

    // MARK: 10 - backgrounding and suspension

    func test10LifecycleBackgroundSuspension() async throws {
        let previousInstance = try await latestProcessInstance()
        launchApp()
        await waitForReady()
        waitForFixtureMenu()
        let launch = try await waitForAppLaunch(after: previousInstance)
        let processInstance = try XCTUnwrap(launch.fields["processInstance"])
        let runIdentifier = try XCTUnwrap(launch.fields["runIdentifier"])

        try await openFlow("open lifecycle flow")
        tapPageControl(SpikeAnchor.lifecycleTransferLink)
        var evidence = try await waitForEvidence(description: "lifecycle transfer started") {
            guard let transfer = $0.appEvent(kind: "transfer-started", matching: {
                $0.fields["path"] == SpikeContract.Path.lifecycleTransfer
                    && $0.fields["processInstance"] == processInstance
                    && $0.fields["runIdentifier"] == runIdentifier
            }), let correlation = transfer.fields["transferCorrelationID"] else { return false }
            return $0.appEvents.contains {
                $0.kind == "transfer-progress"
                    && $0.fields["taskIdentifier"] == transfer.fields["taskIdentifier"]
                    && $0.fields["processInstance"] == processInstance
                    && $0.fields["runIdentifier"] == runIdentifier
            } && $0.requests.contains { $0.transferCorrelationID == correlation }
        }
        let transfer = try XCTUnwrap(evidence.appEvent(kind: "transfer-started", matching: {
            $0.fields["path"] == SpikeContract.Path.lifecycleTransfer
                && $0.fields["processInstance"] == processInstance
                && $0.fields["runIdentifier"] == runIdentifier
        }))
        let taskIdentifier = try XCTUnwrap(transfer.fields["taskIdentifier"])
        let correlation = try XCTUnwrap(transfer.fields["transferCorrelationID"])
        XCUIDevice.shared.press(.home)
        let backgroundMarkerAccepted = await fixture.markLifecycle(
            "background-window-start",
            taskIdentifier: taskIdentifier,
            processInstance: transfer.fields["processInstance"]
        )
        XCTAssertTrue(backgroundMarkerAccepted, "fixture server did not timestamp backgrounding")

        let backgroundDeadline = Date().addingTimeInterval(50)
        while Date() < backgroundDeadline {
            if let updated = try await fixture.fetchEvidence() { evidence = updated }
            if evidence.requests.first(where: { $0.transferCorrelationID == correlation })?.completed == true {
                break
            }
            try? await Task.sleep(for: .seconds(1))
        }

        app.activate()
        let foregroundMarkerAccepted = await fixture.markLifecycle(
            "foreground-reactivation",
            taskIdentifier: taskIdentifier,
            processInstance: transfer.fields["processInstance"]
        )
        XCTAssertTrue(foregroundMarkerAccepted, "fixture server did not timestamp foreground reactivation")
        await waitForReady()
        evidence = try await waitForEvidence(timeout: 120, description: "lifecycle transfer terminal evidence") {
            $0.appEvents.contains {
                $0.kind == "transfer-settled"
                    && $0.fields["taskIdentifier"] == taskIdentifier
                    && $0.fields["processInstance"] == processInstance
                    && $0.fields["runIdentifier"] == runIdentifier
            }
        }

        let request = try XCTUnwrap(evidence.requests.first { $0.transferCorrelationID == correlation })
        let backgroundAt = evidence.lifecycleMarker(label: "background-window-start", taskIdentifier: taskIdentifier)?.timestamp
        let foregroundMarkerAt = evidence.lifecycleMarker(label: "foreground-reactivation", taskIdentifier: taskIdentifier)?.timestamp
        let serverForegroundAt = foregroundMarkerAt
        let backgroundSamples = request.sendSamples.filter {
            guard let backgroundAt, let serverForegroundAt else { return false }
            return $0.timestamp >= backgroundAt && $0.timestamp < serverForegroundAt
        }
        let bytesBeforeBackground = request.sendSamples.last {
            guard let backgroundAt else { return false }
            return $0.timestamp < backgroundAt
        }?.cumulativeBytes ?? 0
        let bytesAtForeground = backgroundSamples.last?.cumulativeBytes ?? bytesBeforeBackground
        let bytesSentWhileBackgrounded = max(0, bytesAtForeground - bytesBeforeBackground)
        let serverCompletedAt = request.responseCompletedAt
        let serverCompletionPhase: String
        if let serverCompletedAt, let backgroundAt, let serverForegroundAt,
           serverCompletedAt >= backgroundAt, serverCompletedAt < serverForegroundAt {
            serverCompletionPhase = "background"
        } else if let serverCompletedAt, let serverForegroundAt, serverCompletedAt >= serverForegroundAt {
            serverCompletionPhase = "after-foreground-reactivation"
        } else {
            serverCompletionPhase = "not-demonstrated"
        }
        let terminalEvent = evidence.appEvent(kind: "transfer-completed", matching: {
            $0.fields["taskIdentifier"] == taskIdentifier
                && $0.fields["processInstance"] == processInstance
                && $0.fields["runIdentifier"] == runIdentifier
        })
        let hashEvent = evidence.appEvent(kind: "transfer-hash", matching: {
            $0.fields["taskIdentifier"] == taskIdentifier
                && $0.fields["transferCorrelationID"] == correlation
                && $0.fields["processInstance"] == processInstance
                && $0.fields["runIdentifier"] == runIdentifier
        })
        let appBackgroundAt = evidence.appEvents.first {
            $0.kind == "scene-phase" && $0.fields["phase"] == "background"
                && $0.fields["processInstance"] == processInstance
                && $0.fields["runIdentifier"] == runIdentifier
        }?.timestamp
        let appForegroundAt = evidence.appEvents.last {
            $0.kind == "scene-phase" && $0.fields["phase"] == "active"
                && $0.fields["processInstance"] == processInstance
                && $0.fields["runIdentifier"] == runIdentifier
        }?.timestamp
        let terminalPhase: String
        if let timestamp = terminalEvent?.timestamp, let appBackgroundAt, let appForegroundAt,
           timestamp >= appBackgroundAt, timestamp < appForegroundAt {
            terminalPhase = "background"
        } else if let timestamp = terminalEvent?.timestamp, let appForegroundAt, timestamp >= appForegroundAt {
            terminalPhase = "after-foreground-reactivation"
        } else {
            terminalPhase = "not-demonstrated"
        }
        let hashPhase: String
        if let timestamp = hashEvent?.timestamp, let appBackgroundAt, let appForegroundAt,
           timestamp >= appBackgroundAt, timestamp < appForegroundAt {
            hashPhase = "background"
        } else if let timestamp = hashEvent?.timestamp, let appForegroundAt, timestamp >= appForegroundAt {
            hashPhase = "after-foreground-reactivation"
        } else {
            hashPhase = "not-demonstrated"
        }

        XCTAssertEqual(request.transport, SpikeContract.Transport.backgroundURLSession.rawValue)
        XCTAssertTrue(request.completed, "fixture server did not finish the throttled response within the bounded background wait")
        XCTAssertEqual(request.sentByteCount, SpikeFixtureAsset.largeClip.byteCount)
        XCTAssertEqual(hashEvent?.fields["byteIdentical"], "true")
        let backgroundCompletionDemonstrated = serverCompletionPhase == "background"
            && terminalPhase == "background" && hashPhase == "background"
        postVerdict(
            "lifecycle-background",
            status: backgroundCompletionDemonstrated ? "PASS" : "PARTIAL",
            detail: "server bytes during background=\(bytesSentWhileBackgrounded); server response completion=\(serverCompletionPhase); URLSession terminal callback=\(terminalPhase); hash verification=\(hashPhase); SHA-256 byte match=\(hashEvent?.fields["byteIdentical"] ?? "not observed")"
        )
        screenshotAttachment(name: "10-lifecycle-background")
    }

    // MARK: 11 - test-initiated termination and explicit relaunch

    func test11LifecycleTerminationAndRelaunch() async throws {
        let previousInstance = try await latestProcessInstance()
        launchApp()
        await waitForReady()
        waitForFixtureMenu()
        let launch = try await waitForAppLaunch(after: previousInstance)
        let firstInstance = try XCTUnwrap(launch.fields["processInstance"])
        let runIdentifier = try XCTUnwrap(launch.fields["runIdentifier"])

        var evidence = try await waitForEvidence(description: "launch event recorded") {
            $0.appEvents.contains {
                $0.kind == "app-launched"
                    && $0.fields["processInstance"] == firstInstance
                    && $0.fields["runIdentifier"] == runIdentifier
            }
        }

        try await openFlow("open lifecycle flow")
        tapPageControl(SpikeAnchor.lifecycleTransferLink)
        evidence = try await waitForEvidence(description: "lifecycle transfer is in flight") {
            guard let transfer = $0.appEvent(kind: "transfer-started", matching: {
                $0.fields["path"] == SpikeContract.Path.lifecycleTransfer
                    && $0.fields["processInstance"] == firstInstance
                    && $0.fields["runIdentifier"] == runIdentifier
            }), let taskIdentifier = transfer.fields["taskIdentifier"],
               let correlation = transfer.fields["transferCorrelationID"],
               let request = $0.requests.first(where: { $0.transferCorrelationID == correlation }) else { return false }
            return $0.appEvents.contains {
                $0.kind == "transfer-progress" && $0.fields["taskIdentifier"] == taskIdentifier
            } && !request.completed && request.sentByteCount < request.declaredByteCount
        }
        let transfer = try XCTUnwrap(evidence.appEvent(kind: "transfer-started", matching: {
            $0.fields["path"] == SpikeContract.Path.lifecycleTransfer
                && $0.fields["processInstance"] == firstInstance
                && $0.fields["runIdentifier"] == runIdentifier
        }))
        let taskIdentifier = try XCTUnwrap(transfer.fields["taskIdentifier"])
        let correlation = try XCTUnwrap(transfer.fields["transferCorrelationID"])
        let fixtureRequest = try XCTUnwrap(evidence.requests.first { $0.transferCorrelationID == correlation })
        XCTAssertFalse(fixtureRequest.completed, "the fixture response must still be in flight at termination")
        XCTAssertLessThan(fixtureRequest.sentByteCount, fixtureRequest.declaredByteCount)

        app.terminate()
        let priorProcessInstances = Set(
            evidence.appEvents(kind: "app-launched").compactMap { $0.fields["processInstance"] },
        )
        let terminationMarkerAccepted = await fixture.markLifecycle(
            "process-terminated",
            taskIdentifier: taskIdentifier,
            processInstance: firstInstance
        )
        XCTAssertTrue(terminationMarkerAccepted)
        try? await Task.sleep(for: .seconds(2))
        let relaunchMarkerAccepted = await fixture.markLifecycle(
            "process-relaunch",
            taskIdentifier: taskIdentifier,
            processInstance: firstInstance
        )
        XCTAssertTrue(relaunchMarkerAccepted)
        app.launchArguments = []
        app.launch()
        await waitForReady()
        let secondLaunchEvidence = try await waitForEvidence(timeout: 45, description: "new process instance") {
            $0.appEvents.contains { event in
                guard event.kind == "app-launched",
                      let processInstance = event.fields["processInstance"]
                else {
                    return false
                }
                return !priorProcessInstances.contains(processInstance)
            }
        }
        let secondLaunch = try XCTUnwrap(secondLaunchEvidence.appEvents.last {
            guard $0.kind == "app-launched",
                  let processInstance = $0.fields["processInstance"]
            else {
                return false
            }
            return !priorProcessInstances.contains(processInstance)
        })
        let secondInstance = try XCTUnwrap(secondLaunch.fields["processInstance"])
        let relaunchObserved = await fixture.markLifecycle(
            "process-relaunch-observed",
            taskIdentifier: taskIdentifier,
            processInstance: secondInstance
        )
        XCTAssertTrue(relaunchObserved)

        evidence = try await waitForEvidence(timeout: 150, description: "same task restored, moved, and hashed after relaunch") {
            let restored = $0.appEvent(kind: "task-restored", matching: {
                $0.fields["taskIdentifier"] == taskIdentifier
                    && $0.fields["processInstance"] == secondInstance
                    && $0.fields["transferCorrelationID"] == correlation
            })
            let moved = $0.appEvent(kind: "transfer-file-moved", matching: {
                $0.fields["taskIdentifier"] == taskIdentifier
                    && $0.fields["processInstance"] == secondInstance
                    && $0.fields["transferCorrelationID"] == correlation
            })
            let hash = $0.appEvent(kind: "transfer-hash", matching: {
                $0.fields["taskIdentifier"] == taskIdentifier
                    && $0.fields["transferCorrelationID"] == correlation
                    && $0.fields["processInstance"] == secondInstance
            })
            return restored != nil && moved != nil && hash != nil
        }
        let terminationMarker = try XCTUnwrap(evidence.lifecycleMarker(label: "process-terminated", taskIdentifier: taskIdentifier))
        let relaunchMarker = try XCTUnwrap(evidence.lifecycleMarker(label: "process-relaunch", taskIdentifier: taskIdentifier))
        let observedMarker = try XCTUnwrap(evidence.lifecycleMarker(label: "process-relaunch-observed", taskIdentifier: taskIdentifier))
        XCTAssertLessThan(terminationMarker.timestamp, relaunchMarker.timestamp)
        XCTAssertLessThan(relaunchMarker.timestamp, observedMarker.timestamp)
        XCTAssertEqual(observedMarker.fields["processInstance"], secondInstance)
        XCTAssertNotEqual(secondInstance, firstInstance, "relaunch must produce a new process instance")
        let restored = try XCTUnwrap(evidence.appEvent(kind: "task-restored", matching: {
            $0.fields["taskIdentifier"] == taskIdentifier
                && $0.fields["transferCorrelationID"] == correlation
                && $0.fields["processInstance"] == secondInstance
        }))
        let moved = try XCTUnwrap(evidence.appEvent(kind: "transfer-file-moved", matching: {
            $0.fields["taskIdentifier"] == taskIdentifier
                && $0.fields["transferCorrelationID"] == correlation
                && $0.fields["processInstance"] == secondInstance
        }))
        let hash = try XCTUnwrap(evidence.appEvent(kind: "transfer-hash", matching: {
            $0.fields["taskIdentifier"] == taskIdentifier
                && $0.fields["transferCorrelationID"] == correlation
                && $0.fields["processInstance"] == secondInstance
        }))
        let terminal = try XCTUnwrap(evidence.appEvent(kind: "transfer-completed", matching: {
            $0.fields["taskIdentifier"] == taskIdentifier
                && $0.fields["transferCorrelationID"] == correlation
                && $0.fields["processInstance"] == secondInstance
        }))
        let request = try XCTUnwrap(evidence.requests.first { $0.transferCorrelationID == correlation })
        XCTAssertLessThanOrEqual(restored.timestamp, moved.timestamp)
        XCTAssertLessThanOrEqual(moved.timestamp, terminal.timestamp)
        XCTAssertLessThanOrEqual(terminal.timestamp, hash.timestamp)
        XCTAssertEqual(hash.fields["expectedSHA256"], SpikePayload.sha256Hex(SpikeFixtureAsset.largeClip.payload))
        XCTAssertEqual(hash.fields["byteIdentical"], "true")
        XCTAssertEqual(request.completed, true)
        XCTAssertEqual(request.responsePayloadSHA256, SpikePayload.sha256Hex(SpikeFixtureAsset.largeClip.payload))
        XCTAssertEqual(request.transferCorrelationID, correlation)
        XCTAssertGreaterThan(request.responseCompletedAt ?? 0, observedMarker.timestamp)
        XCTAssertLessThan(request.timestamp, terminationMarker.timestamp)
        XCTAssertEqual(request.transferCorrelationID, correlation)
        let hashAfterRelaunch = hash.fields["processInstance"] == secondInstance && hash.timestamp > secondLaunch.timestamp
        XCTAssertTrue(hashAfterRelaunch, "a hash from before process termination cannot satisfy relaunch verification")
        postVerdict("lifecycle-termination", status: "PARTIAL", detail: "the test harness terminated and relaunched task \(taskIdentifier); this does not represent system termination")
        postVerdict(
            "lifecycle-relaunch",
            status: "PARTIAL",
            detail: "task \(taskIdentifier), server correlation \(correlation), file move, and matching SHA-256 were observed after process \(secondInstance) launched; system relaunch remains unverified"
        )
        postVerdict("lifecycle-system-relaunch", status: "UNVERIFIED", detail: "no system-initiated relaunch was exercised")
        postVerdict("lifecycle-force-quit", status: "UNVERIFIED", detail: "user force-quit behavior was not exercised")
        screenshotAttachment(name: "11-lifecycle-relaunch")
    }

    func test12RelaunchRecoversMovedFileBeforeDigest() async throws {
        let previousInstance = try await latestProcessInstance()
        launchApp(additionalArguments: [SpikeContract.delayTransferDigestArgument])
        await waitForReady()
        waitForFixtureMenu()
        let launch = try await waitForAppLaunch(after: previousInstance)
        let firstInstance = try XCTUnwrap(launch.fields["processInstance"])
        let runIdentifier = try XCTUnwrap(launch.fields["runIdentifier"])
        let beforeTransfer = try await waitForEvidence(description: "recovery test process evidence") { evidence in
            evidence.appEvent(kind: "app-launched", matching: {
                $0.fields["processInstance"] == firstInstance
                    && $0.fields["runIdentifier"] == runIdentifier
            }) != nil
        }
        let priorCorrelations = transferCorrelations(in: beforeTransfer)

        tapTransfer("direct-still")
        let started = try await waitForTransferStart(
            path: SpikeContract.Path.stillTransfer,
            excluding: priorCorrelations,
            processInstance: firstInstance,
            runIdentifier: runIdentifier,
        )
        let correlation = try XCTUnwrap(started.fields["transferCorrelationID"])
        let taskIdentifier = try XCTUnwrap(started.fields["taskIdentifier"])
        let movedEvidence = try await waitForEvidence(timeout: 30, description: "download file moved before digest") { evidence in
            evidence.appEvent(kind: "transfer-file-moved", matching: {
                $0.fields["taskIdentifier"] == taskIdentifier
                    && $0.fields["processInstance"] == firstInstance
                    && $0.fields["transferCorrelationID"] == correlation
            }) != nil
        }
        XCTAssertNil(movedEvidence.appEvent(kind: "transfer-hash", matching: {
            $0.fields["transferCorrelationID"] == correlation
        }))
        let foregroundControlMoved = try await waitForEvidence(
            timeout: 15,
            description: "foreground control file moved before digest"
        ) { evidence in
            evidence.appEvent(kind: "transfer-file-moved", matching: {
                $0.fields["role"] == "foreground-control"
                    && $0.fields["taskIdentifier"] == taskIdentifier
                    && $0.fields["processInstance"] == firstInstance
                    && $0.fields["runIdentifier"] == runIdentifier
            }) != nil
        }
        let foregroundControlCorrelation = try XCTUnwrap(
            foregroundControlMoved.appEvent(kind: "transfer-file-moved", matching: {
                $0.fields["role"] == "foreground-control"
                    && $0.fields["taskIdentifier"] == taskIdentifier
                    && $0.fields["processInstance"] == firstInstance
                    && $0.fields["runIdentifier"] == runIdentifier
            })?.fields["transferCorrelationID"]
        )

        app.terminate()
        launchApp(reset: false)
        await waitForReady()
        let recoveredLaunch = try await waitForAppLaunch(after: firstInstance)
        let recoveredProcess = try XCTUnwrap(recoveredLaunch.fields["processInstance"])
        let recoveredEvidence = try await waitForEvidence(timeout: 15, description: "orphaned file rehashed after relaunch") { evidence in
            let hash = evidence.appEvent(kind: "transfer-hash", matching: {
                $0.fields["transferCorrelationID"] == correlation
                    && $0.fields["recoveredAfterTaskMissing"] == "true"
                    && $0.fields["processInstance"] == recoveredProcess
            })
            let settled = evidence.appEvent(kind: "transfer-settled", matching: {
                $0.fields["transferCorrelationID"] == correlation
                    && ["completed", "terminal-callback-unobserved"].contains($0.fields["outcome"] ?? "")
                    && $0.fields["processInstance"] == recoveredProcess
            })
            let controlHash = evidence.appEvent(kind: "transfer-hash", matching: {
                $0.fields["transferCorrelationID"] == foregroundControlCorrelation
                    && $0.fields["recoveredAfterTaskMissing"] == "true"
                    && $0.fields["processInstance"] == recoveredProcess
            })
            let controlSettled = evidence.appEvent(kind: "transfer-settled", matching: {
                $0.fields["transferCorrelationID"] == foregroundControlCorrelation
                    && ["completed", "terminal-callback-unobserved"].contains($0.fields["outcome"] ?? "")
                    && $0.fields["processInstance"] == recoveredProcess
            })
            let metadataCleared = evidence.appEvents(kind: "transfer-settled").contains {
                $0.fields["processInstance"] == recoveredProcess
                    && $0.fields["activeRecordCount"] == "0"
                    && $0.fields["persistedUnfinishedMetadataCount"] == "0"
            }
            return hash != nil && settled != nil
                && controlHash != nil && controlSettled != nil && metadataCleared
        }
        let recoveredHash = try XCTUnwrap(recoveredEvidence.appEvent(kind: "transfer-hash", matching: {
            $0.fields["transferCorrelationID"] == correlation
                && $0.fields["recoveredAfterTaskMissing"] == "true"
                && $0.fields["processInstance"] == recoveredProcess
        }))
        let recoveredSettled = try XCTUnwrap(recoveredEvidence.appEvent(kind: "transfer-settled", matching: {
            $0.fields["transferCorrelationID"] == correlation
                && ["completed", "terminal-callback-unobserved"].contains($0.fields["outcome"] ?? "")
                && $0.fields["processInstance"] == recoveredProcess
        }))
        let recoveredControlHash = try XCTUnwrap(recoveredEvidence.appEvent(kind: "transfer-hash", matching: {
            $0.fields["transferCorrelationID"] == foregroundControlCorrelation
                && $0.fields["recoveredAfterTaskMissing"] == "true"
                && $0.fields["processInstance"] == recoveredProcess
        }))
        let recoveredControlSettled = try XCTUnwrap(recoveredEvidence.appEvent(kind: "transfer-settled", matching: {
            $0.fields["transferCorrelationID"] == foregroundControlCorrelation
                && ["completed", "terminal-callback-unobserved"].contains($0.fields["outcome"] ?? "")
                && $0.fields["processInstance"] == recoveredProcess
        }))
        XCTAssertEqual(recoveredHash.fields["expectedSHA256"], SpikePayload.sha256Hex(SpikeFixtureAsset.stillImage.payload))
        XCTAssertEqual(recoveredHash.fields["byteIdentical"], "true")
        XCTAssertEqual(recoveredControlHash.fields["expectedSHA256"], SpikePayload.sha256Hex(SpikeFixtureAsset.stillImage.payload))
        XCTAssertEqual(recoveredControlHash.fields["byteIdentical"], "true")
        XCTAssertTrue(["completed", "terminal-callback-unobserved"].contains(recoveredSettled.fields["outcome"] ?? ""))
        XCTAssertTrue(["completed", "terminal-callback-unobserved"].contains(recoveredControlSettled.fields["outcome"] ?? ""))
        XCTAssertTrue(recoveredEvidence.appEvents(kind: "transfer-settled").contains {
            $0.fields["processInstance"] == recoveredProcess
                && $0.fields["activeRecordCount"] == "0"
                && $0.fields["persistedUnfinishedMetadataCount"] == "0"
        })
    }

    // MARK: 15 - reset cancels retries and isolates runtime generations

    func test15ResetCancelsRetryingTaskBeforeClearingRunState() async throws {
        let previousInstance = try await latestProcessInstance()
        launchApp()
        await waitForReady()
        waitForFixtureMenu()
        let launch = try await waitForAppLaunch(after: previousInstance)
        let processInstance = try XCTUnwrap(launch.fields["processInstance"])
        let oldRunIdentifier = try XCTUnwrap(launch.fields["runIdentifier"])

        tapTransfer("failure-close")
        let inFlight = try await waitForEvidence(timeout: 45, description: "truncated response retry in flight") {
            guard let transfer = $0.appEvent(kind: "transfer-started", matching: {
                $0.fields["path"] == SpikeContract.Path.failureClose
                    && $0.fields["processInstance"] == processInstance
                    && $0.fields["runIdentifier"] == oldRunIdentifier
            }), let correlation = transfer.fields["transferCorrelationID"],
               let request = $0.requests.first(where: { $0.transferCorrelationID == correlation }) else { return false }
            return request.sentByteCount > 0 && !request.completed
        }
        let oldTransfer = try XCTUnwrap(inFlight.appEvent(kind: "transfer-started", matching: {
            $0.fields["path"] == SpikeContract.Path.failureClose
                && $0.fields["processInstance"] == processInstance
                && $0.fields["runIdentifier"] == oldRunIdentifier
        }))
        let resetButton = app.buttons[SpikeControlIdentifier.resetButton]
        XCTAssertTrue(resetButton.waitForExistence(timeout: 10))
        resetButton.tap()

        let reset = try await waitForEvidence(timeout: 50, description: "URLSession cancellation reconciled before reset") {
            $0.appEvent(kind: "runtime-reset-completed", matching: {
                $0.fields["runIdentifier"] != oldRunIdentifier
                    && $0.fields["processInstance"] == processInstance
            }) != nil
        }
        let resetEvent = try XCTUnwrap(reset.appEvent(kind: "runtime-reset-completed", matching: {
            $0.fields["runIdentifier"] != oldRunIdentifier
                && $0.fields["processInstance"] == processInstance
        }))
        XCTAssertEqual(resetEvent.fields["activeRecordCount"], "0")
        XCTAssertEqual(resetEvent.fields["persistedUnfinishedMetadataCount"], "0")
        XCTAssertEqual(resetEvent.fields["scratchFileCount"], "0")
        XCTAssertEqual(resetEvent.fields["processInstance"], oldTransfer.fields["processInstance"])

        let correlation = try XCTUnwrap(oldTransfer.fields["transferCorrelationID"])
        let attemptsAtReset = reset.requests(path: SpikeContract.Path.failureClose).filter {
            $0.transferCorrelationID == correlation
        }.count
        try? await Task.sleep(for: .seconds(4))
        guard let afterObservation = try await fixture.fetchEvidence() else {
            throw SpikeTestFailure.timeout("fixture evidence was unavailable after reset observation")
        }
        XCTAssertEqual(
            afterObservation.requests(path: SpikeContract.Path.failureClose).filter {
                $0.transferCorrelationID == correlation
            }.count,
            attemptsAtReset,
            "a prior-run truncated response retried after reset had declared completion"
        )
        XCTAssertFalse(afterObservation.appEvents.contains {
            $0.kind == "transfer-started" && $0.fields["runIdentifier"] == resetEvent.fields["runIdentifier"]
                && $0.fields["path"] == SpikeContract.Path.failureClose
        })
        XCTAssertFalse(afterObservation.appEvents.contains {
            $0.fields["taskIdentifier"] == oldTransfer.fields["taskIdentifier"]
                && $0.fields["runIdentifier"] == resetEvent.fields["runIdentifier"]
        }, "a prior-run task callback was attributed to the new runtime generation")
        postVerdict(
            "reset-cancels-prior-run",
            status: "PASS",
            detail: "reset cancelled the in-flight truncated task, waited for its callback, cleared scratch and unfinished metadata, and kept its retries out of the new run"
        )
    }

    // MARK: 16 - incomplete background event delivery stays pending

    func test16BackgroundEventTimeoutDoesNotReleaseHandler() async throws {
        let deliveryIdentifier = UUID().uuidString
        launchApp(additionalArguments: [
            SpikeContract.backgroundEventsProbeArgument,
            "\(SpikeContract.backgroundEventDeliveryIdentifierArgumentPrefix)\(deliveryIdentifier)",
        ])
        await waitForReady()
        waitForFixtureMenu()

        let probe = app.buttons[SpikeControlIdentifier.backgroundEventsProbeButton]
        XCTAssertTrue(probe.waitForExistence(timeout: 10))
        probe.tap()
        let evidence = try await waitForEvidence(timeout: 40, description: "background event delivery timeout recorded") {
            $0.appEvent(kind: "background-events-timeout", matching: {
                $0.caseID == "runtime"
                    && $0.fields["deliveryIdentifier"] == deliveryIdentifier
                    && $0.fields["deliveryState"] == "incomplete"
            })?.fields["handlerRetained"] == "true"
        }
        guard let timeout = evidence.appEvent(kind: "background-events-timeout", matching: {
            $0.caseID == "runtime" && $0.fields["deliveryIdentifier"] == deliveryIdentifier
        }) else {
            XCTFail("The test-supplied delivery did not record a correlated timeout")
            return
        }
        XCTAssertEqual(timeout.fields["deliveryState"], "incomplete")
        XCTAssertEqual(timeout.fields["handlerRetained"], "true")
        let received = evidence.appEvent(kind: "background-events-received", matching: {
            $0.fields["deliveryIdentifier"] == deliveryIdentifier
        })
        XCTAssertEqual(received?.fields["matches"], "true")
        XCTAssertLessThanOrEqual(received?.timestamp ?? .infinity, timeout.timestamp)

        let finished = evidence.appEvent(kind: "background-events-finished", matching: {
            $0.fields["deliveryIdentifier"] == deliveryIdentifier
        })
        let handlerCall = evidence.appEvent(kind: "background-events-probe-handler-called", matching: {
            $0.fields["deliveryIdentifier"] == deliveryIdentifier
        })
        if let finished {
            XCTAssertEqual(finished.fields["completionSource"], "urlSessionDidFinishEvents")
            XCTAssertEqual(finished.fields["hadHandler"], "true")
            XCTAssertGreaterThan(finished.timestamp, timeout.timestamp)
            XCTAssertNotNil(handlerCall)
            if let handlerCall {
                XCTAssertGreaterThanOrEqual(handlerCall.timestamp, finished.timestamp)
            }
        } else {
            XCTAssertNil(handlerCall, "The probe callback cannot run before URLSession reports all events delivered")
        }
        postVerdict(
            "background-event-timeout",
            status: "PASS",
            detail: finished == nil
                ? "the timed-out delivery remained incomplete with its handler retained; the probe does not simulate an operating-system event cycle"
                : "the timed-out delivery stayed pending until urlSessionDidFinishEvents; the probe does not simulate an operating-system event cycle"
        )
    }

    // MARK: 99 - matrix summary and redaction

    func test99MatrixSummaryAndRedaction() async throws {
        launchApp(reset: false)
        await waitForReady()
        waitForFixtureMenu()

        guard let evidence = try await fixture.fetchEvidence() else {
            throw SpikeTestFailure.timeout("fixture evidence document was not reachable for the summary")
        }
        // Verdict fragments.
        let verdicts = evidence.appEvents(kind: "verdict").map { event in
            ["case": event.caseID, "status": event.detail, "detail": event.fields["detail"] ?? ""]
        }
        let summary: [String: Any] = [
            "verdicts": verdicts,
            "requestCount": evidence.requests.count,
            "webkitRequests": evidence.requests.filter { $0.transport == "webkit" }.count,
            "backgroundRequests": evidence.requests.filter { $0.transport == SpikeContract.Transport.backgroundURLSession.rawValue }.count,
            "foregroundControlRequests": evidence.requests.filter { $0.transport == SpikeContract.Transport.foregroundURLSession.rawValue }.count,
            "tokenLedger": evidence.tokenLedger.map { ["label": $0.label, "consumed": $0.consumed, "transport": $0.consumedByTransport ?? "none"] },
        ]
        if let data = try? JSONSerialization.data(withJSONObject: summary, options: [.sortedKeys]),
           let json = String(data: data, encoding: .utf8) {
            jsonAttachment(name: "99-matrix-summary", json: json)
        }

        // Redaction: persisted artifacts must not contain secret values.
        let rawEvidence = try await fixture.fetchRawEvidence() ?? ""
        let exportElement = app.descendants(matching: .any)
            .matching(identifier: SpikeControlIdentifier.evidenceJSON)
            .firstMatch
        XCTAssertTrue(
            exportElement.waitForExistence(timeout: 15),
            "the app export element was not exposed to the accessibility hierarchy"
        )
        let appExport = (exportElement.value as? String) ?? ""
        for (name, artifact) in [("fixture-evidence", rawEvidence), ("app-export", appExport)] {
            XCTAssertFalse(artifact.contains(SpikeContract.syntheticPassword), "\(name) persisted the synthetic password")
            XCTAssertFalse(artifact.contains(SpikeContract.syntheticAuthCookieValue), "\(name) persisted the synthetic cookie value")
            XCTAssertFalse(artifact.contains("token="), "\(name) persisted a signed token query value")
            XCTAssertFalse(artifact.contains("spike-user:spike-pass-2-synthetic"), "\(name) persisted the credential pair")
        }
        XCTAssertFalse(rawEvidence.isEmpty, "fixture evidence was empty")
        XCTAssertTrue(appExport.contains("app-launched"), "app export did not include evidence from the current process")
        postVerdict("redaction", status: "PASS", detail: "persisted fixture evidence and the app export contained no synthetic password, cookie value, credential pair, or signed token value")
        postVerdict("matrix-summary", status: "PASS", detail: "\(verdicts.count) verdict fragments, \(evidence.requests.count) recorded requests")
        screenshotAttachment(name: "99-summary")
    }

    // MARK: 13 - transfer terminal cleanup

    func test13SuccessfulTransferLeavesNoActiveOrPersistedMetadata() async throws {
        let previousInstance = try await latestProcessInstance()
        launchApp()
        await waitForReady()
        waitForFixtureMenu()
        let launch = try await waitForAppLaunch(after: previousInstance)
        let processInstance = try XCTUnwrap(launch.fields["processInstance"])
        let runIdentifier = try XCTUnwrap(launch.fields["runIdentifier"])

        let beforeTransfer = try await waitForEvidence(description: "launched process evidence") {
            $0.appEvent(kind: "app-launched", matching: {
                $0.fields["processInstance"] == processInstance
                    && $0.fields["runIdentifier"] == runIdentifier
            }) != nil
        }
        let priorCorrelations = transferCorrelations(in: beforeTransfer)
        tapTransfer("direct-still")
        let started = try await waitForTransferStart(
            path: SpikeContract.Path.stillTransfer,
            excluding: priorCorrelations,
            processInstance: processInstance,
            runIdentifier: runIdentifier
        )
        let correlation = try XCTUnwrap(started.fields["transferCorrelationID"])
        let taskIdentifier = try XCTUnwrap(started.fields["taskIdentifier"])
        let expectedHash = SpikePayload.sha256Hex(SpikeFixtureAsset.stillImage.payload)
        let evidence = try await waitForEvidence(timeout: 60, description: "hashed transfer metadata cleanup") {
            let identityMatches: (FixtureEvidence.AppEvent) -> Bool = { event in
                event.fields["taskIdentifier"] == taskIdentifier
                    && event.fields["processInstance"] == processInstance
                    && event.fields["runIdentifier"] == runIdentifier
                    && event.fields["role"] == "background"
                    && event.fields["transferCorrelationID"] == correlation
            }
            let hashMatches = $0.appEvents(kind: "transfer-hash").contains { event in
                identityMatches(event)
                    && event.fields["expectedSHA256"] == expectedHash
                    && event.fields["byteIdentical"] == "true"
            }
            let terminalMatches = $0.appEvents(kind: "transfer-completed").contains { event in
                identityMatches(event) && event.fields["outcome"] == "completed"
            }
            let settledMatches = $0.appEvents(kind: "transfer-settled").contains { event in
                identityMatches(event) && event.fields["outcome"] == "completed"
            }
            let controlSettled = $0.appEvents(kind: "transfer-settled").contains { event in
                event.fields["role"] == "foreground-control"
                    && event.fields["processInstance"] == processInstance
                    && event.fields["runIdentifier"] == runIdentifier
                    && event.fields["outcome"] == "completed"
            }
            let metadataCleared = $0.appEvents(kind: "transfer-settled").contains { event in
                event.fields["processInstance"] == processInstance
                    && event.fields["activeRecordCount"] == "0"
                    && event.fields["persistedUnfinishedMetadataCount"] == "0"
            }
            return hashMatches && terminalMatches && settledMatches && controlSettled && metadataCleared
        }

        let identityMatches: (FixtureEvidence.AppEvent) -> Bool = { event in
            event.fields["taskIdentifier"] == taskIdentifier
                && event.fields["processInstance"] == processInstance
                && event.fields["runIdentifier"] == runIdentifier
                && event.fields["role"] == "background"
                && event.fields["transferCorrelationID"] == correlation
        }
        let hash = try XCTUnwrap(evidence.appEvent(kind: "transfer-hash", matching: {
            identityMatches($0)
                && $0.fields["expectedSHA256"] == expectedHash
                && $0.fields["byteIdentical"] == "true"
        }))
        let settled = try XCTUnwrap(evidence.appEvent(kind: "transfer-settled", matching: {
            identityMatches($0) && $0.fields["outcome"] == "completed"
        }))
        let terminal = try XCTUnwrap(evidence.appEvent(kind: "transfer-completed", matching: {
            identityMatches($0) && $0.fields["outcome"] == "completed"
        }))
        XCTAssertLessThanOrEqual(hash.timestamp, settled.timestamp)
        XCTAssertLessThanOrEqual(terminal.timestamp, settled.timestamp)
        XCTAssertEqual(terminal.fields["outcome"], "completed")
        XCTAssertEqual(started.fields["transferCorrelationID"], correlation)
        XCTAssertEqual(terminal.fields["transferCorrelationID"], correlation)
        XCTAssertEqual(settled.fields["transferCorrelationID"], correlation)
        XCTAssertEqual(settled.fields["outcome"], "completed")
        XCTAssertEqual(settled.fields["digestSHA256"], expectedHash)
        XCTAssertEqual(settled.fields["activeRecordCount"], "0")
        XCTAssertEqual(settled.fields["persistedUnfinishedMetadataCount"], "0")
        XCTAssertTrue(evidence.appEvents(kind: "transfer-settled").contains {
            $0.fields["processInstance"] == processInstance
                && $0.fields["activeRecordCount"] == "0"
                && $0.fields["persistedUnfinishedMetadataCount"] == "0"
        })
        postVerdict(
            "transfer-completion-cleanup",
            status: "PASS",
            detail: "task \(taskIdentifier) reconciled its terminal callback and SHA-256 before active and persisted metadata were cleared"
        )
    }

    // MARK: 14 - profile captured before asynchronous cookie lookup

    func test14TransferPreparationRemainsBoundToOriginatingProfile() async throws {
        let previousInstance = try await latestProcessInstance()
        launchApp(additionalArguments: ["--spike-hold-cookie-read"])
        await waitForReady()
        waitForFixtureMenu()
        let launch = try await waitForAppLaunch(after: previousInstance)
        let processInstance = try XCTUnwrap(launch.fields["processInstance"])
        let runIdentifier = try XCTUnwrap(launch.fields["runIdentifier"])

        let baseline = await latestRequestSequence()
        try await openFlow("open login flow")
        tapPageControl(SpikeAnchor.loginSubmitButton)
        _ = try await waitForEvidence(description: "persistent profile login") {
            $0.appEvents.contains { $0.kind == "navigation-event" }
        }
        tapPageControl(SpikeAnchor.loginControlLink)
        _ = try await waitForEvidence(description: "persistent profile cookie stored") {
            guard let request = $0.request(path: SpikeContract.Path.vaultControl, transport: "webkit") else { return false }
            return request.sequence > baseline && request.completed && request.hasSyntheticAuthCookie
        }

        openMenu()
        try await openFlow("open vault flow")
        tapPageControl(SpikeAnchor.loginTransferLink)
        let held = try await waitForEvidence(timeout: 20, description: "cookie lookup paused for profile-switch test") {
            $0.appEvent(kind: "cookie-preparation-paused", matching: {
                $0.fields["profile"] == "persistent-private"
                    && $0.fields["processInstance"] == processInstance
                    && $0.fields["runIdentifier"] == runIdentifier
            }) != nil
        }
        let pausedEvent = try XCTUnwrap(held.appEvent(kind: "cookie-preparation-paused", matching: {
            $0.fields["processInstance"] == processInstance && $0.fields["runIdentifier"] == runIdentifier
        }))
        let pausedAt = pausedEvent.timestamp

        selectProfile(SpikeControlIdentifier.profileEphemeralButton)
        let evidence = try await waitForEvidence(timeout: 45, description: "originating profile transfer after profile switch") {
            guard let selected = $0.appEvent(kind: "profile-selected", matching: {
                $0.fields["profile"] == "ephemeral"
                    && $0.fields["processInstance"] == processInstance
                    && $0.fields["runIdentifier"] == runIdentifier
            }), selected.timestamp > pausedAt else { return false }
            guard let bridge = $0.appEvent(kind: "cookie-bridge", matching: {
                $0.fields["profile"] == "persistent-private"
                    && $0.fields["processInstance"] == processInstance
                    && $0.fields["runIdentifier"] == runIdentifier
            }) else { return false }
            return bridge.timestamp > selected.timestamp
                && $0.appEvent(kind: "transfer-started", matching: {
                    $0.fields["path"] == SpikeContract.Path.vaultTransfer
                        && $0.fields["profile"] == "persistent-private"
                        && $0.fields["processInstance"] == processInstance
                        && $0.fields["runIdentifier"] == runIdentifier
                }) != nil
                && $0.request(path: SpikeContract.Path.vaultTransfer, transport: "urlsession-background")?.responseStatusCode == 200
        }

        let selected = try XCTUnwrap(evidence.appEvent(kind: "profile-selected", matching: {
            $0.fields["profile"] == "ephemeral" && $0.fields["processInstance"] == processInstance
        }))
        let bridge = try XCTUnwrap(evidence.appEvent(kind: "cookie-bridge", matching: {
            $0.fields["profile"] == "persistent-private" && $0.fields["processInstance"] == processInstance
        }))
        let transferred = try XCTUnwrap(evidence.request(path: SpikeContract.Path.vaultTransfer, transport: "urlsession-background"))
        let transferStarted = try XCTUnwrap(evidence.appEvent(kind: "transfer-started", matching: {
            $0.fields["path"] == SpikeContract.Path.vaultTransfer
                && $0.fields["processInstance"] == processInstance
                && $0.fields["runIdentifier"] == runIdentifier
        }))
        XCTAssertGreaterThan(selected.timestamp, pausedAt)
        XCTAssertGreaterThan(bridge.timestamp, selected.timestamp)
        XCTAssertEqual(bridge.fields["profile"], "persistent-private")
        XCTAssertEqual(transferStarted.fields["profile"], "persistent-private")
        XCTAssertEqual(transferStarted.fields["runIdentifier"], bridge.fields["runIdentifier"])
        XCTAssertEqual(transferred.hasSyntheticAuthCookie, true)
        XCTAssertEqual(transferred.responseStatusCode, 200)
        postVerdict(
            "profile-capture-during-preparation",
            status: "PASS",
            detail: "a held transfer stayed bound to Persistent-Private after selection changed to Ephemeral"
        )
    }
}
