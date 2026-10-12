import Observation
import SwiftUI
import WebKit

@main
@MainActor
struct WebPageDownloadSpikeHostApp: App {
    @State private var harness = SpikeHarness()

    var body: some Scene {
        WindowGroup {
            WebPageDownloadSpikeHostView(harness: harness)
        }
    }
}

/// Disposable iOS 27 host for observing public WebPage navigation behavior.
@MainActor
private struct WebPageDownloadSpikeHostView: View {
    var harness: SpikeHarness

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Text(harness.serverStatus)
                    .font(.caption.monospaced())
                    .accessibilityIdentifier("server-ready")
                Spacer()
                Button("Fixture menu") {
                    harness.loadFixtureMenu()
                }
                .accessibilityIdentifier("reset-to-fixture-menu")
                Button("Stop page") {
                    harness.stopPageLoading(
                        for: "slow-attachment-cancellation",
                        targetPath: "/slow-attachment"
                    )
                }
                .accessibilityIdentifier("stop-page-loading")
            }
            .padding(.horizontal, 10)

            WebView(harness.page)
                .accessibilityIdentifier("spike-webview")
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            ScrollView {
                Text(harness.eventExportJSON)
                    .font(.system(size: 9, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityElement(children: .ignore)
                    .accessibilityIdentifier("event-records-json")
                    .accessibilityLabel("event-records-json")
                    .accessibilityValue(harness.eventExportJSON)
            }
            .frame(height: 150)
            .padding(.horizontal, 10)
        }
        .task {
            await harness.startIfNeeded()
        }
        .onChange(of: harness.page.estimatedProgress) { _, progress in
            harness.recordNavigationProgress(progress)
        }
    }
}

@MainActor
@Observable
private final class SpikeHarness {
    let log: SpikeEventLog
    let page: WebPage
    private let server: LoopbackFixtureServer
    private var homeURL: URL?
    private var started = false
    private var navigationEventsTask: Task<Void, Never>?

    var serverStatus = "Starting loopback fixture server…"

    var eventExportJSON: String {
        log.exportJSON()
    }

    init() {
        let log = SpikeEventLog()
        let decider = SpikeNavigationDecider(log: log)
        self.log = log
        page = WebPage(navigationDecider: decider)
        server = LoopbackFixtureServer { evidence in
            Task { @MainActor in
                log.recordServerEvidence(evidence)
            }
        }
    }

    func startIfNeeded() async {
        guard !started else { return }
        started = true
        do {
            let url = try await server.start()
            homeURL = url
            serverStatus = "READY loopback \(url.host ?? "127.0.0.1"): \(url.port ?? 0)"
            log.append(kind: "server-ready", fixture: "fixture-menu", url: url.absoluteString)
            observeNavigationEvents()
            load(url)
        } catch {
            serverStatus = "SERVER FAILED: \(error.localizedDescription)"
            log.append(kind: "server-start-failed", fixture: "unknown", detail: String(describing: error))
        }
    }

    func loadFixtureMenu() {
        guard let homeURL else { return }
        load(homeURL)
    }

    func stopPageLoading(for fixture: String, targetPath: String) {
        log.append(
            kind: "page-stop-loading-requested",
            fixture: fixture,
            url: page.url?.absoluteString,
            path: targetPath,
            detail: "Called public WebPage.stopLoading() for target-path=\(targetPath); current-page-url=\(page.url?.absoluteString ?? "nil"). This is a page command, not a download-object cancellation callback."
        )
        page.stopLoading()
    }

    func recordNavigationProgress(_ progress: Double) {
        log.append(
            kind: "page-navigation-progress",
            fixture: fixtureName(for: page.url),
            url: page.url?.absoluteString,
            detail: String(format: "WebPage.estimatedProgress=%.3f", progress)
        )
    }

    private func load(_ url: URL) {
        let navigation = page.load(url)
        Task { @MainActor [weak self] in
            do {
                for try await _ in navigation { }
            } catch {
                self?.log.append(
                    kind: "navigation-command-error",
                    fixture: self?.fixtureName(for: url),
                    url: url.absoluteString,
                    detail: String(describing: error)
                )
            }
        }
    }

    private func observeNavigationEvents() {
        navigationEventsTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                for try await event in page.navigations {
                    log.append(
                        kind: "navigation-event",
                        fixture: fixtureName(for: page.url),
                        url: page.url?.absoluteString,
                        navigationEvent: String(describing: event)
                    )
                }
            } catch {
                log.append(
                    kind: "navigation-stream-error",
                    fixture: fixtureName(for: page.url),
                    url: page.url?.absoluteString,
                    detail: String(describing: error)
                )
            }
        }
    }

    private func fixtureName(for url: URL?) -> String {
        guard let url else { return "unknown" }
        if url.scheme == "blob" { return "blob-download" }
        switch url.path {
        case "/": return "fixture-menu"
        case "/normal": return "normal-html-navigation"
        case "/download-attribute": return "download-attribute"
        case "/attachment": return url.query?.contains("source=redirect") == true
            ? "redirect-to-attachment"
            : "content-disposition-attachment"
        case "/non-displayable": return "non-displayable-mime"
        case "/redirect": return "redirect-to-attachment"
        case "/cookie-attachment": return "cookie-authenticated-attachment"
        case "/truncated-attachment": return "truncated-attachment-failure"
        case "/slow-attachment": return "slow-attachment-cancellation"
        default: return "unknown"
        }
    }
}

@MainActor
private final class SpikeNavigationDecider: WebPage.NavigationDeciding {
    private let log: SpikeEventLog

    init(log: SpikeEventLog) {
        self.log = log
    }

    func decidePolicy(
        for action: WebPage.NavigationAction,
        preferences: inout WebPage.NavigationPreferences
    ) async -> WKNavigationActionPolicy {
        let request = action.request
        let shouldDownload = action.shouldPerformDownload
        let decision: WKNavigationActionPolicy = shouldDownload ? .download : .allow
        log.append(
            kind: "action-policy",
            fixture: fixtureName(for: request.url),
            url: request.url?.absoluteString,
            method: request.httpMethod,
            cookie: request.value(forHTTPHeaderField: "Cookie"),
            shouldPerformDownload: shouldDownload,
            navigationType: String(describing: action.navigationType),
            decision: decisionName(decision),
            detail: "isContentRuleListRedirect=\(action.isContentRuleListRedirect)"
        )
        return decision
    }

    func decidePolicy(for response: WebPage.NavigationResponse) async -> WKNavigationResponsePolicy {
        let urlResponse = response.response
        let httpResponse = urlResponse as? HTTPURLResponse
        let status = httpResponse?.statusCode
        let disposition = header("Content-Disposition", from: httpResponse)
        let location = header("Location", from: httpResponse)
        let mimeType = urlResponse.mimeType
        let isRedirect = status.map { (300..<400).contains($0) } ?? false
        let isAttachment = disposition?.localizedLowercase.contains("attachment") == true
        let shouldDownload = !isRedirect && (isAttachment || !response.canShowMimeType)
        let decision: WKNavigationResponsePolicy = shouldDownload ? .download : .allow

        log.append(
            kind: "response-policy",
            fixture: fixtureName(for: urlResponse.url),
            url: urlResponse.url?.absoluteString,
            canShowMIMEType: response.canShowMimeType,
            mimeType: mimeType,
            status: status,
            contentDisposition: disposition,
            location: location,
            decision: decisionName(decision),
            detail: "redirect=\(isRedirect);attachmentHeader=\(isAttachment);mimeCapability=\(response.canShowMimeType)"
        )
        return decision
    }

    private func header(_ name: String, from response: HTTPURLResponse?) -> String? {
        response?.allHeaderFields.first { key, _ in
            String(describing: key).caseInsensitiveCompare(name) == .orderedSame
        }.map { String(describing: $0.value) }
    }

    private func decisionName(_ policy: WKNavigationActionPolicy) -> String {
        switch policy {
        case .allow: "allow"
        case .cancel: "cancel"
        case .download: "download"
        @unknown default: "unknown"
        }
    }

    private func decisionName(_ policy: WKNavigationResponsePolicy) -> String {
        switch policy {
        case .allow: "allow"
        case .cancel: "cancel"
        case .download: "download"
        @unknown default: "unknown"
        }
    }

    private func fixtureName(for url: URL?) -> String {
        guard let url else { return "unknown" }
        if url.scheme == "blob" { return "blob-download" }
        switch url.path {
        case "/": return "fixture-menu"
        case "/normal": return "normal-html-navigation"
        case "/download-attribute": return "download-attribute"
        case "/attachment": return url.query?.contains("source=redirect") == true
            ? "redirect-to-attachment"
            : "content-disposition-attachment"
        case "/non-displayable": return "non-displayable-mime"
        case "/redirect": return "redirect-to-attachment"
        case "/cookie-attachment": return "cookie-authenticated-attachment"
        case "/truncated-attachment": return "truncated-attachment-failure"
        case "/slow-attachment": return "slow-attachment-cancellation"
        default: return "unknown"
        }
    }
}

@MainActor
@Observable
private final class SpikeEventLog {
    private(set) var events: [SpikeEvent] = []

    func append(
        kind: String,
        fixture: String?,
        url: String? = nil,
        path: String? = nil,
        method: String? = nil,
        cookie: String? = nil,
        shouldPerformDownload: Bool? = nil,
        navigationType: String? = nil,
        canShowMIMEType: Bool? = nil,
        mimeType: String? = nil,
        status: Int? = nil,
        contentDisposition: String? = nil,
        location: String? = nil,
        decision: String? = nil,
        navigationEvent: String? = nil,
        transferOutcome: String? = nil,
        detail: String? = nil
    ) {
        events.append(
            SpikeEvent(
                index: events.count + 1,
                timestamp: ISO8601DateFormatter().string(from: Date()),
                kind: kind,
                fixture: fixture ?? "unknown",
                url: url,
                path: path,
                method: method,
                shouldPerformDownload: shouldPerformDownload,
                navigationType: navigationType,
                canShowMIMEType: canShowMIMEType,
                mimeType: mimeType,
                status: status,
                contentDisposition: contentDisposition,
                cookie: cookie,
                location: location,
                decision: decision,
                navigationEvent: navigationEvent,
                transferOutcome: transferOutcome,
                detail: detail
            )
        )
    }

    func recordServerEvidence(_ evidence: ServerEvidence) {
        events.append(
            SpikeEvent(
                index: events.count + 1,
                timestamp: ISO8601DateFormatter().string(from: Date()),
                kind: evidence.kind,
                fixture: evidence.fixture,
                url: "http://127.0.0.1\(evidence.path)",
                path: evidence.path,
                method: evidence.method,
                shouldPerformDownload: nil,
                navigationType: nil,
                canShowMIMEType: nil,
                mimeType: evidence.contentType,
                status: evidence.status,
                contentDisposition: evidence.contentDisposition,
                cookie: evidence.cookie,
                location: evidence.location,
                decision: nil,
                navigationEvent: nil,
                transferOutcome: evidence.transferOutcome,
                detail: evidence.detail
            )
        )
    }

    func exportJSON() -> String {
        let export = SpikeEventExport(
            schemaVersion: 1,
            sdkAPIInventory: [
                "WebPage.NavigationAction exposes shouldPerformDownload; NavigationResponse exposes URLResponse and canShowMimeType.",
                "WebPage.NavigationDeciding exposes action and response policy callbacks; WebPage.navigations emits navigation events; estimatedProgress and stopLoading are page-level APIs.",
                "The iOS 27 WebPage interface has no download-object handoff, destination, file URL, download progress, completion, failure, cancellation, or resume-data API.",
                "The public SwiftUI WebView initializer accepts WebPage or URL and exposes no WKWebView download delegate or didBecomeDownload callback.",
                "Separate public WKWebView/WKDownload APIs provide download handoff and lifecycle delegates, but this WebPage/WebView surface does not expose that bridge.",
            ],
            events: events
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(export) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }
}

private struct SpikeEvent: Codable, Identifiable {
    let index: Int
    let timestamp: String
    let kind: String
    let fixture: String
    let url: String?
    let path: String?
    let method: String?
    let shouldPerformDownload: Bool?
    let navigationType: String?
    let canShowMIMEType: Bool?
    let mimeType: String?
    let status: Int?
    let contentDisposition: String?
    let cookie: String?
    let location: String?
    let decision: String?
    let navigationEvent: String?
    let transferOutcome: String?
    let detail: String?

    var id: Int { index }
}

private struct SpikeEventExport: Encodable {
    let schemaVersion: Int
    let sdkAPIInventory: [String]
    let events: [SpikeEvent]
}
