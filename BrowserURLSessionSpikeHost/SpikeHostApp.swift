import Observation
import SwiftUI
import WebKit

@main
@MainActor
struct BrowserURLSessionSpikeHostApp: App {
    @UIApplicationDelegateAdaptor(SpikeAppDelegate.self) private var appDelegate
    @State private var harness = SpikeHarness()

    var body: some Scene {
        WindowGroup {
            SpikeHostView(harness: harness)
        }
    }
}

/// Spike-only application delegate.
///
/// The delegate exists so the experiment can implement the public
/// background-session restoration contract even though the host is a SwiftUI
/// application. It records launch events and hands system background session
/// events to the transfer runtime, which owns reattachment and the completion
/// handler.
@MainActor
final class SpikeAppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        let coordinator = SpikeTransferCoordinator.shared
        coordinator.start()
        Self.launchOptionsSummary = String(launchOptions?.isEmpty == false)
        return true
    }

    /// Whether the system supplied launch options, captured at launch time.
    ///
    /// The launch event is recorded after the optional runtime reset in
    /// SpikeHarness.startIfNeeded() because a reset clears previously
    /// recorded events, including one recorded during this launch.
    static var launchOptionsSummary = "unknown"

    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        SpikeTransferCoordinator.shared.handleBackgroundEvents(
            identifier: identifier,
            completionHandler: completionHandler
        )
    }

    func applicationWillTerminate(_ application: UIApplication) {
        SpikeTransferCoordinator.shared.recordTransportEvent(
            kind: "app-will-terminate",
            caseID: "runtime",
            detail: "Application will terminate callback received.",
            fields: [:]
        )
    }
}

/// One WebKit data store profile under test.
enum SpikeProfile: String, CaseIterable, Sendable {
    /// Persistent-Private behavior, matching the shipping browser's default.
    case persistentPrivate = "persistent-private"
    /// Ephemeral behavior with no on-disk persistence.
    case ephemeral

    var title: String {
        switch self {
        case .persistentPrivate: "Persistent-Private"
        case .ephemeral: "Ephemeral"
        }
    }

    /// The data store assigned to the experimental page for this profile.
    @MainActor
    var dataStore: WKWebsiteDataStore {
        switch self {
        case .persistentPrivate: WKWebsiteDataStore.default()
        case .ephemeral: WKWebsiteDataStore.nonPersistent()
        }
    }
}

/// One experimental WebPage together with the exact data store assigned to it.
@MainActor
final class SpikePageContext {
    let profile: SpikeProfile
    let dataStore: WKWebsiteDataStore
    let page: WebPage
    let decider: SpikeNavigationDecider

    init(profile: SpikeProfile, harness: SpikeHarness) {
        self.profile = profile
        self.dataStore = profile.dataStore
        let decider = SpikeNavigationDecider(profile: profile)
        var configuration = WebPage.Configuration()
        configuration.websiteDataStore = dataStore
        self.page = WebPage(configuration: configuration, navigationDecider: decider)
        self.decider = decider
        page.customUserAgent = SpikeContract.appOwnedUserAgent
        decider.harness = harness
    }
}

/// Experiment orchestrator for one application process.
@MainActor
@Observable
final class SpikeHarness {
    let coordinator: SpikeTransferCoordinator
    private(set) var contexts: [SpikeProfile: SpikePageContext] = [:]
    var activeProfile: SpikeProfile = .persistentPrivate
    var status = "starting"
    var ready = false
    var revision = 0
    private(set) var observedTransferCount = 0
    @ObservationIgnored private var started = false
    @ObservationIgnored private var navigationTasks: [Task<Void, Never>] = []
    @ObservationIgnored private var pendingResponseRequests: [String: URLRequest] = [:]
    @ObservationIgnored private var pendingFormValues: [String: [String: String]] = [:]
    @ObservationIgnored private var evidenceCache: (json: String, revision: Int, at: Date)?
    @ObservationIgnored private var holdCookiePreparation = ProcessInfo.processInfo.arguments.contains("--spike-hold-cookie-read")
    @ObservationIgnored private var cookiePreparationContinuation: CheckedContinuation<Void, Never>?

    init() {
        self.coordinator = SpikeTransferCoordinator.shared
        self.coordinator.onEventRecorded = { [weak self] in
            self?.revision &+= 1
        }
    }

    /// The page for the active profile.
    var activePage: WebPage {
        pageContext(for: activeProfile).page
    }

    /// JSON export of the app-side event log, refreshed at most once per second.
    var evidenceJSON: String {
        let current = revision
        if let evidenceCache, evidenceCache.revision == current, Date().timeIntervalSince(evidenceCache.at) < 1.0 {
            return evidenceCache.json
        }
        let json = coordinator.log.exportJSON()
        evidenceCache = (json, current, Date())
        return json
    }

    /// Transfer bookkeeping for the UI control.
    var transferSummary: String {
        _ = revision
        return "transfers observed: \(observedTransferCount) active: \(coordinator.activeTransferCount)"
    }

    /// The page context for one profile, created on first use.
    func pageContext(for profile: SpikeProfile) -> SpikePageContext {
        if let existing = contexts[profile] { return existing }
        let created = SpikePageContext(profile: profile, harness: self)
        contexts[profile] = created
        observeNavigations(of: created)
        return created
    }

    /// Perform one-time startup work.
    func startIfNeeded() async {
        guard !started else { return }
        started = true
        if ProcessInfo.processInfo.arguments.contains(SpikeContract.resetLaunchArgument) {
            await resetRuntimeState()
        }
        // Recorded after the reset so the launch evidence of this process is
        // never discarded along with the previous run's state.
        coordinator.recordTransportEvent(
            kind: "app-launched",
            caseID: "runtime",
            detail: "Disposable experiment host finished launching.",
            fields: [
                "instance": coordinator.log.instanceIdentifier,
                "launchArguments": ProcessInfo.processInfo.arguments.joined(separator: " "),
                "hasLaunchOptions": SpikeAppDelegate.launchOptionsSummary,
                "recordedAfterReset": String(
                    ProcessInfo.processInfo.arguments.contains(SpikeContract.resetLaunchArgument)
                ),
            ]
        )
        coordinator.start()
        status = "probing fixture server"
        let healthy = await coordinator.client.health()
        ready = healthy
        status = healthy
            ? "READY fixture \(SpikeContract.baseURLString(host: SpikeContract.primaryHost))"
            : "FIXTURE SERVER UNREACHABLE at \(SpikeContract.baseURLString(host: SpikeContract.primaryHost))"
        coordinator.recordTransportEvent(
            kind: "fixture-health",
            caseID: "runtime",
            detail: "Checked host-process fixture server health before driving the experiment.",
            fields: ["healthy": String(healthy), "base": SpikeContract.baseURLString(host: SpikeContract.primaryHost)]
        )
        if healthy {
            loadMenu()
        }
    }

    /// Load the fixture menu in the active profile's page.
    func loadMenu() {
        load(SpikeContract.url(path: SpikeContract.Path.menu), in: activeProfile)
    }

    /// Ask the app-owned runtime to restart its disposable state.
    func resetRuntimeState() async {
        guard await coordinator.reset() else {
            status = "reset incomplete; active URLSession work was preserved"
            return
        }
        cookiePreparationContinuation?.resume()
        cookiePreparationContinuation = nil
        for profile in SpikeProfile.allCases {
            let store = pageContext(for: profile).dataStore
            let cookies = await store.httpCookieStore.allCookies()
            for cookie in cookies {
                await store.httpCookieStore.deleteCookie(cookie)
            }
            await store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
        }
        pendingResponseRequests.removeAll()
        pendingFormValues.removeAll()
        observedTransferCount = 0
        status = "reset complete"
    }

    /// Switch the active profile and load its fixture menu.
    func selectProfile(_ profile: SpikeProfile) {
        activeProfile = profile
        coordinator.recordTransportEvent(
            kind: "profile-selected",
            caseID: "runtime",
            detail: "UI tests selected the store profile under test.",
            fields: ["profile": profile.rawValue]
        )
        cookiePreparationContinuation?.resume()
        cookiePreparationContinuation = nil
        loadMenu()
    }

    /// Record a scene phase transition so lifecycle evidence is attributable.
    func recordScenePhase(_ phase: ScenePhase) {
        coordinator.recordTransportEvent(
            kind: "scene-phase",
            caseID: "lifecycle",
            detail: "Application scene phase changed.",
            fields: ["phase": String(describing: phase)]
        )
    }

    /// Exercise timeout handling with a test-supplied completion closure.
    func beginBackgroundEventTimeoutProbe() {
        let arguments = ProcessInfo.processInfo.arguments
        guard arguments.contains(SpikeContract.backgroundEventsProbeArgument) else { return }
        let coordinator = self.coordinator
        guard let deliveryArgument = arguments.first(where: {
            $0.hasPrefix(SpikeContract.backgroundEventDeliveryIdentifierArgumentPrefix)
        }) else {
            coordinator.recordTransportEvent(
                kind: "background-events-probe-invalid",
                caseID: "background-events-probe",
                detail: "The synthetic background event probe is missing its delivery correlation identifier.",
                fields: [:]
            )
            return
        }
        let deliveryIdentifier = String(
            deliveryArgument.dropFirst(SpikeContract.backgroundEventDeliveryIdentifierArgumentPrefix.count)
        )
        guard !deliveryIdentifier.isEmpty else { return }
        coordinator.handleBackgroundEvents(
            identifier: SpikeContract.backgroundSessionIdentifier,
            deliveryIdentifier: deliveryIdentifier
        ) { [weak coordinator] in
            coordinator?.recordTransportEvent(
                kind: "background-events-probe-handler-called",
                caseID: "background-events-probe",
                detail: "The test-supplied background event completion closure was invoked.",
                fields: ["deliveryIdentifier": deliveryIdentifier]
            )
        }
    }

    /// Record the observed navigation action exactly as WebKit reported it.
    func recordObservedAction(request: URLRequest, action: WebPage.NavigationAction, caseID: String) {
        let url = request.url
        let headers = request.allHTTPHeaderFields ?? [:]
        let referer = headers.first { $0.key.caseInsensitiveCompare("Referer") == .orderedSame }?.value
        let origin = headers.first { $0.key.caseInsensitiveCompare("Origin") == .orderedSame }?.value
        let userAgent = headers.first { $0.key.caseInsensitiveCompare("User-Agent") == .orderedSame }?.value
        let cookie = headers.first { $0.key.caseInsensitiveCompare("Cookie") == .orderedSame }?.value
        var fields: [String: String] = [
            "mode": "browser-observed",
            "method": request.httpMethod ?? "GET",
            "host": url?.host ?? "unknown",
            "path": url?.path ?? "unknown",
            "scheme": url?.scheme ?? "unknown",
            "queryKeys": url.map(SpikeRedaction.queryKeys) ?? "none",
            "headerNames": headers.keys.sorted().joined(separator: ","),
            "hasCookieHeader": String(cookie != nil),
            "cookieHeaderSHA256": cookie.map { SpikeHash.prefix($0) } ?? "none",
            "hasAuthorizationHeader": String(headers.keys.contains { $0.caseInsensitiveCompare("Authorization") == .orderedSame }),
            "refererHostPath": referer.map(SpikeRedaction.hostPath) ?? "none",
            "originValue": origin ?? "absent",
            "userAgentValue": userAgent ?? "absent",
            "bodyByteCount": String(request.httpBody?.count ?? 0),
            "bodySHA256": request.httpBody.map { String(SpikeHash.digest($0).prefix(16)) } ?? "none",
            "hasBodyStream": String(request.httpBodyStream != nil),
            "shouldPerformDownload": String(action.shouldPerformDownload),
            "navigationType": String(describing: action.navigationType),
            "isContentRuleListRedirect": String(action.isContentRuleListRedirect),
            "targetIsMainFrame": String(action.target?.isMainFrame == true),
            "sourceIsMainFrame": String(action.source.isMainFrame),
        ]
        if let target = action.target, target.request.url?.path != url?.path {
            fields["targetFramePath"] = target.request.url?.path ?? "unknown"
        }
        coordinator.recordTransportEvent(
            kind: "navigation-action-observed",
            caseID: caseID,
            detail: "WebKit reported a navigation action with its public request snapshot.",
            fields: fields
        )
    }

    /// Record a navigation response policy observation.
    func recordObservedResponse(_ response: WebPage.NavigationResponse, caseID: String, decision: String) {
        let urlResponse = response.response
        let http = urlResponse as? HTTPURLResponse
        let headers = http?.allHeaderFields ?? [:]
        let disposition = headers.first { String(describing: $0.key).caseInsensitiveCompare("Content-Disposition") == .orderedSame }
            .map { String(describing: $0.value) }
        coordinator.recordTransportEvent(
            kind: "navigation-response-observed",
            caseID: caseID,
            detail: "WebKit reported a navigation response.",
            fields: [
                "host": urlResponse.url?.host ?? "unknown",
                "path": urlResponse.url?.path ?? "unknown",
                "mimeType": urlResponse.mimeType ?? "unknown",
                "status": http.map { String($0.statusCode) } ?? "none",
                "canShowMimeType": String(response.canShowMimeType),
                "contentDisposition": disposition ?? "absent",
                "decision": decision,
            ]
        )
    }

    /// Record an authentication challenge handled by the browser.
    func recordBrowserChallenge(_ challenge: URLAuthenticationChallenge, decision: String) {
        coordinator.recordTransportEvent(
            kind: "browser-auth-challenge",
            caseID: "authentication",
            detail: "WebKit asked the navigation decider for an authentication challenge disposition.",
            fields: [
                "method": challenge.protectionSpace.authenticationMethod,
                "host": challenge.protectionSpace.host,
                "previousFailureCount": String(challenge.previousFailureCount),
                "hasProposedCredential": String(challenge.proposedCredential != nil),
                "decision": decision,
            ]
        )
    }

    /// Record a form submission observation delivered by the iOS 27 hook.
    func recordFormSubmission(_ formInfo: WebPage.FormInfo, profile: SpikeProfile) {
        let caseID = SpikeInterceptionPolicy.caseID(for: formInfo.submissionURL, mode: "form")
        pendingFormValues[requestKey(formInfo.submissionURL, profile: profile)] = formInfo.formValues
        let valueDigests = formInfo.formValues
            .map { "\($0.key)=\(SpikeHash.prefix($0.value))" }
            .sorted()
            .joined(separator: ",")
        coordinator.recordTransportEvent(
            kind: "form-submission-observed",
            caseID: caseID,
            detail: "iOS 27 willSubmit hook reported a form submission before the action policy ran.",
            fields: [
                "host": formInfo.submissionURL.host ?? "unknown",
                "profile": profile.rawValue,
                "path": formInfo.submissionURL.path,
                "httpMethod": formInfo.httpMethod,
                "parameterNames": formInfo.formValues.keys.sorted().joined(separator: ","),
                "valueSHA256Prefixes": valueDigests,
                "parameterCount": String(formInfo.formValues.count),
                "targetIsMainFrame": String(formInfo.targetFrame.isMainFrame),
            ]
        )
    }

    /// Remember an allowed action request so the response policy can transfer it.
    func rememberResponseTriggeredRequest(_ request: URLRequest, caseID: String, profile: SpikeProfile) {
        guard let url = request.url else { return }
        pendingResponseRequests[requestKey(url, profile: profile)] = request
        coordinator.recordTransportEvent(
            kind: "response-triggered-allowed",
            caseID: caseID,
            detail: "Action was allowed so the response can reveal whether it is an attachment.",
            fields: ["path": url.path, "host": url.host ?? "unknown", "profile": profile.rawValue]
        )
    }

    /// The remembered request for a response-triggered transfer.
    func pendingResponseRequest(for url: URL?, profile: SpikeProfile) -> URLRequest? {
        guard let url else { return nil }
        return pendingResponseRequests[requestKey(url, profile: profile)]
    }

    /// Record a page-bound blob download that cannot become an HTTP transfer.
    func recordBlobAction(_ request: URLRequest, caseID: String, shouldPerformDownload: Bool) {
        coordinator.recordTransportEvent(
            kind: "blob-action-observed",
            caseID: caseID,
            detail: "Page generated a blob: resource; it has no HTTP(S) URL for an app-owned session transfer.",
            fields: [
                "scheme": request.url?.scheme ?? "unknown",
                "shouldPerformDownload": String(shouldPerformDownload),
                "transferable": "false",
            ]
        )
    }

    /// Record an intercepted POST with only sanitized body information.
    func recordPostProbe(_ request: URLRequest, caseID: String, formValues: [String: String]?) {
        let bodyFields = formValues ?? [:]
        var fields: [String: String] = [
            "method": request.httpMethod ?? "GET",
            "host": request.url?.host ?? "unknown",
            "path": request.url?.path ?? "unknown",
            "queryKeys": request.url.map(SpikeRedaction.queryKeys) ?? "none",
            "bodyByteCount": String(request.httpBody?.count ?? 0),
            "hasBodyStream": String(request.httpBodyStream != nil),
            "formValuesAvailable": String(!bodyFields.isEmpty),
        ]
        if let body = request.httpBody, !body.isEmpty {
            fields["bodySHA256"] = SpikeHash.prefix(body)
            fields["bodySource"] = "intercepted-action-body"
        }
        if !bodyFields.isEmpty {
            let encoded = SpikeRequestBuilder.formEncodedBody(bodyFields)
            fields["reconstructedBodyByteCount"] = String(encoded.count)
            fields["reconstructedBodySHA256"] = SpikeHash.prefix(String(decoding: encoded, as: UTF8.self))
        }
        coordinator.recordTransportEvent(
            kind: "post-probe",
            caseID: caseID,
            detail: "Intercepted a form POST before WebKit sent it; recorded method and body availability.",
            fields: fields
        )
    }

    /// Transfer a replayed POST exactly once, using the most faithful body the
    /// experiment could observe: the iOS 27 form hook when it fires, otherwise
    /// the encoded body WebKit already attached to the intercepted request.
    func replayPost(
        request: URLRequest,
        caseID: String,
        body: Data,
        bodySource: String,
        profile: SpikeProfile
    ) async {
        guard let url = request.url else { return }
        let runIdentifier = coordinator.runIdentifier
        var replayed = URLRequest(url: url)
        replayed.httpMethod = "POST"
        replayed.setValue(
            request.value(forHTTPHeaderField: "Content-Type") ?? "application/x-www-form-urlencoded",
            forHTTPHeaderField: "Content-Type"
        )
        replayed.httpBody = body
        replayed.setValue(SpikeContract.Transport.backgroundURLSession.rawValue, forHTTPHeaderField: SpikeContract.transportHeader)
        observedTransferCount += 1
        coordinator.recordTransportEvent(
            kind: "post-replay-started",
            caseID: caseID,
            detail: "Replayed the intercepted form POST once through the app-owned background session.",
            fields: [
                "host": url.host ?? "unknown",
                "path": url.path,
                "bodySource": bodySource,
                "replayedBodyByteCount": String(body.count),
                "replayedBodySHA256": SpikeHash.prefix(body),
            ]
        )
        coordinator.enqueue(
            request: replayed,
            caseID: caseID,
            profile: profile.rawValue,
            role: .background,
            expectedAsset: nil,
            cancelAfterFirstProgress: false,
            runIdentifier: runIdentifier
        )
    }

    /// Start an app-owned transfer for one observed browser request.
    func beginTransfer(
        from observed: URLRequest,
        caseID: String,
        attachCredentials: Bool,
        profile: SpikeProfile
    ) async {
        guard let url = observed.url else { return }
        let runIdentifier = coordinator.runIdentifier
        let store = pageContext(for: profile).dataStore
        if holdCookiePreparation {
            holdCookiePreparation = false
            await withCheckedContinuation { continuation in
                cookiePreparationContinuation = continuation
                coordinator.recordTransportEvent(
                    kind: "cookie-preparation-paused",
                    caseID: caseID,
                    detail: "Deterministic test gate paused cookie lookup before it accessed the originating page data store.",
                    fields: ["profile": profile.rawValue, "runIdentifier": runIdentifier]
                )
            }
        }
        guard coordinator.runIdentifier == runIdentifier else { return }
        let cookies: [HTTPCookie]
        if url.path == SpikeContract.Path.scopeProbeTransfer {
            _ = await SpikeCookieBridge.injectOutOfScopeMarkers(in: store, url: url)
            cookies = await SpikeCookieBridge.allCookies(in: store)
        } else {
            cookies = await SpikeCookieBridge.cookies(in: store, for: url)
        }
        guard coordinator.runIdentifier == runIdentifier else { return }
        let scoped = SpikeCookieBridge.scope(cookies, for: url)
        coordinator.recordTransportEvent(
            kind: "cookie-bridge",
            caseID: caseID,
            detail: "Applied URL-scoped cookie selection from the page's exact data store.",
            fields: [
                "profile": profile.rawValue,
                "runIdentifier": runIdentifier,
                "path": url.path,
                "host": url.host ?? "unknown",
                "cookieCount": String(cookies.count),
                "observedNames": SpikeCookieBridge.names(cookies),
                "included": String(scoped.included.count),
                "includedNames": SpikeCookieBridge.names(scoped.included),
                "decisions": scoped.decisions.map { "\($0.name):\($0.included ? "in" : "out"):\($0.reason)" }.sorted().joined(separator: ","),
            ]
        )
        let request = SpikeRequestBuilder.transferRequest(
            from: observed,
            cookies: scoped.included,
            attachCredentials: attachCredentials,
            omitUserAgent: url.path == SpikeContract.Path.userAgentTransferDefault
        )
        observedTransferCount += 1
        coordinator.recordTransportEvent(
            kind: "transfer-request-built",
            caseID: caseID,
            detail: "Built the app-owned transfer request from the observed navigation request.",
            fields: [
                "host": url.host ?? "unknown",
                "path": url.path,
                "method": request.httpMethod ?? "GET",
                "attachCredentials": String(attachCredentials),
                "cookieHeaderPresent": String(request.value(forHTTPHeaderField: "Cookie") != nil),
                "authorizationHeaderPresent": String(request.value(forHTTPHeaderField: "Authorization") != nil),
                "userAgentPresent": String(request.value(forHTTPHeaderField: "User-Agent") != nil),
                "refererPresent": String(request.value(forHTTPHeaderField: "Referer") != nil),
                "headerNames": (request.allHTTPHeaderFields ?? [:]).keys.sorted().joined(separator: ","),
            ]
        )
        coordinator.enqueue(
            request: request,
            caseID: caseID,
            profile: profile.rawValue,
            role: .background,
            expectedAsset: SpikeRequestBuilder.expectedAsset(for: url),
            cancelAfterFirstProgress: caseID.contains("failure-cancel"),
            runIdentifier: runIdentifier
        )
        if SpikeRequestBuilder.foregroundControlPaths.contains(url.path) {
            coordinator.enqueue(
                request: request,
                caseID: "\(caseID)-foreground-control",
                profile: profile.rawValue,
                role: .foregroundControl,
                expectedAsset: SpikeRequestBuilder.expectedAsset(for: url),
                cancelAfterFirstProgress: false,
                runIdentifier: runIdentifier
            )
        }
    }

    // MARK: - Private

    private func load(_ url: URL, in profile: SpikeProfile) {
        let page = pageContext(for: profile).page
        let navigation = page.load(url)
        Task { @MainActor [weak self] in
            do {
                for try await event in navigation {
                    self?.coordinator.recordTransportEvent(
                        kind: "navigation-command-event",
                        caseID: SpikeInterceptionPolicy.caseID(for: url, mode: "load"),
                        detail: "Page load command emitted a navigation event.",
                        fields: ["event": String(describing: event), "path": url.path]
                    )
                }
            } catch {
                let nsError = error as NSError
                self?.coordinator.recordTransportEvent(
                    kind: "navigation-command-failed",
                    caseID: SpikeInterceptionPolicy.caseID(for: url, mode: "load"),
                    detail: "Page load command failed.",
                    fields: ["path": url.path, "errorDomain": nsError.domain, "errorCode": String(nsError.code)]
                )
            }
        }
    }

    private func observeNavigations(of pageContext: SpikePageContext) {
        let task = Task { @MainActor [weak self] in
            do {
                for try await event in pageContext.page.navigations {
                    self?.coordinator.recordTransportEvent(
                        kind: "navigation-event",
                        caseID: "runtime",
                        detail: "Page emitted a navigation event.",
                        fields: [
                            "profile": pageContext.profile.rawValue,
                            "event": String(describing: event),
                            "path": pageContext.page.url?.path ?? "none",
                        ]
                    )
                }
            } catch {
                let nsError = error as NSError
                self?.coordinator.recordTransportEvent(
                    kind: "navigation-stream-ended",
                    caseID: "runtime",
                    detail: "Navigation event stream ended.",
                    fields: ["profile": pageContext.profile.rawValue, "errorDomain": nsError.domain, "errorCode": String(nsError.code)]
                )
            }
        }
        navigationTasks.append(task)
    }

    func formValues(for url: URL, profile: SpikeProfile) -> [String: String]? {
        pendingFormValues[requestKey(url, profile: profile)]
    }

    private func requestKey(_ url: URL, profile: SpikeProfile) -> String {
        "\(profile.rawValue)|\(url.absoluteString)"
    }

    /// Record that a response-triggered transfer had no remembered request.
    func recordMissingResponseRequest(url: URL?, caseID: String) {
        coordinator.recordTransportEvent(
            kind: "response-triggered-missing-request",
            caseID: caseID,
            detail: "Response policy wanted to transfer but no allowed action request was remembered.",
            fields: ["path": url?.path ?? "unknown"]
        )
    }
}

/// Navigation policy for one experimental page.
@MainActor
final class SpikeNavigationDecider: WebPage.NavigationDeciding {
    let profile: SpikeProfile
    weak var harness: SpikeHarness?

    init(profile: SpikeProfile) {
        self.profile = profile
    }

    func decidePolicy(
        for action: WebPage.NavigationAction,
        preferences: inout WebPage.NavigationPreferences
    ) async -> WKNavigationActionPolicy {
        let request = action.request
        let url = request.url
        let transfer = url.map { SpikeInterceptionPolicy.actionDecision(for: $0) } ?? .browser
        let caseID = url.map { SpikeInterceptionPolicy.caseID(for: $0, mode: "transfer") } ?? "unknown-transfer"
        harness?.recordObservedAction(request: request, action: action, caseID: caseID)

        if url?.scheme == "blob" {
            harness?.recordBlobAction(request, caseID: "blob", shouldPerformDownload: action.shouldPerformDownload)
            return .cancel
        }

        switch transfer {
        case .browser:
            return action.shouldPerformDownload ? .download : .allow
        case .transfer(let attachCredentials):
            await harness?.beginTransfer(
                from: request,
                caseID: caseID,
                attachCredentials: attachCredentials,
                profile: profile
            )
            return .cancel
        case .postProbe:
            let formValues = url.flatMap { harness?.formValues(for: $0, profile: profile) }
            harness?.recordPostProbe(request, caseID: caseID, formValues: formValues)
            // Replay once only when a complete body is observable. A body that
            // exists purely as a stream is never replayed because reading it
            // would consume data the experiment cannot verify afterwards.
            if let formValues, !formValues.isEmpty {
                await harness?.replayPost(
                    request: request,
                    caseID: caseID,
                    body: SpikeRequestBuilder.formEncodedBody(formValues),
                    bodySource: "willSubmit-form-values",
                    profile: profile
                )
            } else if let body = request.httpBody, !body.isEmpty {
                await harness?.replayPost(
                    request: request,
                    caseID: caseID,
                    body: body,
                    bodySource: "intercepted-action-body",
                    profile: profile
                )
            }
            return .cancel
        case .responseTriggeredTransfer:
            harness?.rememberResponseTriggeredRequest(request, caseID: caseID, profile: profile)
            return .allow
        }
    }

    func decidePolicy(for response: WebPage.NavigationResponse) async -> WKNavigationResponsePolicy {
        let url = response.response.url
        let decision = url.map { SpikeInterceptionPolicy.responseDecision(for: $0) } ?? .allow
        let caseID = url.map { SpikeInterceptionPolicy.caseID(for: $0, mode: "transfer") } ?? "unknown-transfer"
        harness?.recordObservedResponse(response, caseID: caseID, decision: String(describing: decision))

        switch decision {
        case .allow:
            return .allow
        case .webKitDownload:
            return .download
        case .cancelAndTransfer:
            if let pending = harness?.pendingResponseRequest(for: url, profile: profile) {
                await harness?.beginTransfer(
                    from: pending,
                    caseID: caseID,
                    attachCredentials: false,
                    profile: profile
                )
            } else {
                harness?.recordMissingResponseRequest(url: url, caseID: caseID)
            }
            return .cancel
        }
    }

    func decideAuthenticationChallengeDisposition(
        for challenge: URLAuthenticationChallenge
    ) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        let method = challenge.protectionSpace.authenticationMethod
        let fixtureHost = challenge.protectionSpace.host == SpikeContract.primaryHost
            || challenge.protectionSpace.host == SpikeContract.secondaryHost
        let useCredential = method == NSURLAuthenticationMethodHTTPBasic && fixtureHost
        harness?.recordBrowserChallenge(challenge, decision: useCredential ? "use-credential" : "default")
        if useCredential {
            return (
                .useCredential,
                URLCredential(
                    user: SpikeContract.syntheticUserName,
                    password: SpikeContract.syntheticPassword,
                    persistence: .none
                )
            )
        }
        return (.performDefaultHandling, nil)
    }

    func willSubmit(formInfo: WebPage.FormInfo) async {
        harness?.recordFormSubmission(formInfo, profile: profile)
    }
}

/// Host view with the experiment's native controls.
private struct SpikeHostView: View {
    var harness: SpikeHarness
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                Text(harness.status)
                    .font(.caption2.monospaced())
                    .accessibilityIdentifier(SpikeControlIdentifier.statusLabel)
                Spacer()
                Text(harness.ready ? "READY" : "WAITING")
                    .font(.caption2.monospaced())
                    .accessibilityIdentifier(SpikeControlIdentifier.ready)
            }
            HStack(spacing: 8) {
                ForEach(SpikeProfile.allCases, id: \.rawValue) { profile in
                    Button(profile.title) {
                        harness.selectProfile(profile)
                    }
                    .accessibilityIdentifier(
                        profile == .persistentPrivate
                            ? SpikeControlIdentifier.profilePersistentButton
                            : SpikeControlIdentifier.profileEphemeralButton
                    )
                }
                Button("Fixture menu") {
                    harness.loadMenu()
                }
                .accessibilityIdentifier(SpikeControlIdentifier.menuButton)
                Button("Reset") {
                    Task { await harness.resetRuntimeState() }
                }
                .accessibilityIdentifier(SpikeControlIdentifier.resetButton)
                if ProcessInfo.processInfo.arguments.contains("--spike-background-events-probe") {
                    Button("Probe background event timeout") {
                        harness.beginBackgroundEventTimeoutProbe()
                    }
                    .accessibilityIdentifier(SpikeControlIdentifier.backgroundEventsProbeButton)
                }
                Spacer()
                Text(harness.transferSummary)
                    .font(.caption2.monospaced())
                    .accessibilityIdentifier(SpikeControlIdentifier.transferCountLabel)
            }
            WebView(harness.activePage)
                .accessibilityIdentifier("spike-webview")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            ScrollView {
                Text("evidence json")
                    .font(.system(size: 8, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityElement(children: .ignore)
                    .accessibilityIdentifier(SpikeControlIdentifier.evidenceJSON)
                    .accessibilityLabel(SpikeControlIdentifier.evidenceJSON)
                    .accessibilityValue(harness.evidenceJSON)
            }
            .frame(height: 40)
        }
        .padding(.horizontal, 8)
        .task {
            await harness.startIfNeeded()
        }
        .onChange(of: scenePhase) { _, phase in
            harness.recordScenePhase(phase)
        }
    }
}
