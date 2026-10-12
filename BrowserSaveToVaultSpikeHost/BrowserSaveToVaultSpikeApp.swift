//
//  BrowserSaveToVaultSpikeApp.swift
//  MediaVault
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import CryptoKit
import Foundation
import ImageIO
import Observation
import SwiftUI
import UniformTypeIdentifiers
import WebKit

@main
@MainActor
struct BrowserSaveToVaultSpikeApp: App {
    @State
    private var harness = BrowserSaveToVaultHarness()

    var body: some Scene {
        WindowGroup {
            BrowserSaveToVaultView(harness: harness)
        }
    }
}

/// Shows a disposable WebPage and explicit controls for the acquisition experiment.
@MainActor
private struct BrowserSaveToVaultView: View {
    var harness: BrowserSaveToVaultHarness

    var body: some View {
        VStack(spacing: 6) {
            HStack {
                Button("Fixture home") { harness.loadFixtureHome() }
                    .accessibilityIdentifier("fixture-home")
                Button("Open direct still") { harness.openDirectMedia(path: "/resource/direct-image") }
                    .accessibilityIdentifier("open-direct-still")
                Button("Open direct video") { harness.openDirectMedia(path: "/resource/direct-video") }
                    .accessibilityIdentifier("open-direct-video")
            }

            HStack {
                Button("Save current page") { harness.saveCurrentPage() }
                    .accessibilityIdentifier("save-current-page")
                Button("Use persistent") { harness.selectProfile(.persistent) }
                    .accessibilityIdentifier("profile-persistent")
                Button("Use ephemeral") { harness.selectProfile(.ephemeral) }
                    .accessibilityIdentifier("profile-ephemeral")
                Button("Cancel transfer") { harness.cancelActiveTransfer() }
                    .accessibilityIdentifier("cancel-transfer")
                    .disabled(!harness.hasActiveTransfer)
            }

            Text(harness.transferState)
                .font(.caption.monospaced())
                .accessibilityIdentifier("transfer-state")
            Text(harness.pagePath)
                .font(.caption.monospaced())
                .accessibilityIdentifier("current-page-path")

            WebView(harness.page)
                .accessibilityIdentifier("spike-web-page")
        }
        .padding(6)
        .task { harness.startIfNeeded() }
    }
}

private enum SpikeProfile: String {
    case persistent
    case ephemeral
}

/// Connects one user gesture from WebPage to a constrained, app-owned GET transfer.
@MainActor
@Observable
private final class BrowserSaveToVaultHarness {
    private let router: SaveIntentNavigationRouter
    private let reporter: SpikeEventReporter
    private let persistentStore: WKWebsiteDataStore
    private let rootURL: URL
    private let scratchDirectory: URL
    private let receiptDirectory: URL
    private let baseURL: URL
    private var selectedStore: WKWebsiteDataStore
    private var selectedProfile: SpikeProfile = .persistent
    private var profileInstanceID = UUID().uuidString.lowercased()
    private var companionWebView: WKWebView?
    private var activeTransfer: BrowserSaveTransfer?
    private var started = false

    private(set) var page: WebPage
    private(set) var transferState = "starting fixture"

    var hasActiveTransfer: Bool {
        activeTransfer != nil
    }

    var pagePath: String {
        page.url?.path ?? "page: loading"
    }

    init() {
        guard let fallbackURL = URL(string: "http://127.0.0.1:18753/") else {
            preconditionFailure("The fixture base URL must be valid")
        }

        baseURL = ProcessInfo.processInfo.environment["SPIKE_BASE_URL"].flatMap(URL.init(string:)) ?? fallbackURL
        reporter = SpikeEventReporter(baseURL: baseURL)
        persistentStore = WKWebsiteDataStore.default()
        selectedStore = persistentStore
        router = SaveIntentNavigationRouter()

        let supportDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        rootURL = supportDirectory.appendingPathComponent("BrowserSaveToVaultSpike", isDirectory: true)
        scratchDirectory = rootURL.appendingPathComponent("transfer-scratch", isDirectory: true)
        receiptDirectory = rootURL.appendingPathComponent("receipt-staging", isDirectory: true)
        page = WebPage()
        page = makePage(using: selectedStore)
        router.harness = self
        prepareStorage()
    }

    func startIfNeeded() {
        guard !started else {
            return
        }

        started = true
        reporter.record(
            kind: "host-started",
            profileID: profileInstanceID,
            profile: selectedProfile.rawValue,
            operationID: nil,
            fields: [
                "transport": "WKDownload",
                "visible_browser": "WebPage",
                "receipt_protection": "completeUnlessOpen",
            ],
        )
        loadFixtureHome()
    }

    func loadFixtureHome() {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        components?.path = "/"
        if selectedProfile == .ephemeral {
            components?.queryItems = [URLQueryItem(name: "profile", value: "ephemeral")]
        } else {
            components?.queryItems = nil
        }
        guard let url = components?.url else {
            transferState = "fixture URL invalid"
            return
        }

        navigate(to: url)
    }

    func openDirectMedia(path: String) {
        guard let url = URL(string: path, relativeTo: baseURL)?.absoluteURL else {
            return
        }

        navigate(to: url)
    }

    func saveCurrentPage() {
        guard let url = page.url else {
            transferState = "no current page URL"
            return
        }

        startTransfer(
            url: url,
            caseID: url.path == "/resource/direct-video" ? "direct-page-video" : "direct-page-still",
            source: "direct-media-page",
        )
    }

    func selectProfile(_ profile: SpikeProfile) {
        guard profile != selectedProfile else {
            return
        }

        selectedProfile = profile
        selectedStore = profile == .persistent ? persistentStore : WKWebsiteDataStore.nonPersistent()
        profileInstanceID = UUID().uuidString.lowercased()
        page = makePage(using: selectedStore)
        transferState = "profile changed to \(profile.rawValue)"
        reporter.record(
            kind: "profile-selected",
            profileID: profileInstanceID,
            profile: profile.rawValue,
            operationID: nil,
            fields: [
                "store_kind": profile == .persistent ? "default" : "nonpersistent",
                "browser_downloads_cancelled": "false",
            ],
        )
        loadFixtureHome()
    }

    func cancelActiveTransfer() {
        activeTransfer?.cancel()
    }

    fileprivate func handleSaveIntent(_ intentURL: URL) {
        guard let components = URLComponents(url: intentURL, resolvingAgainstBaseURL: false) else {
            reject(caseID: "invalid-intent", reason: "intent-unparseable")
            return
        }

        let values = Dictionary(
            components.queryItems?.map { ($0.name, $0.value ?? "") } ?? [],
            uniquingKeysWith: { first, _ in first },
        )
        let caseID = values["case"] ?? "user-selection"
        guard let target = values["target"],
              let selectedURL = URL(string: target, relativeTo: page.url)?.absoluteURL
        else {
            reject(caseID: caseID, reason: "target-unavailable")
            return
        }
        guard values["method"]?.uppercased() == "GET" else {
            reject(caseID: caseID, reason: "method-not-get")
            return
        }

        startTransfer(url: selectedURL, caseID: caseID, source: "explicit-link")
    }

    private func transferDidStart(_ transfer: BrowserSaveTransfer) {
        activeTransfer = transfer
        transferState = "\(transfer.caseID): downloading"
        reporter.record(
            kind: "transfer-started",
            profileID: profileInstanceID,
            profile: selectedProfile.rawValue,
            operationID: transfer.operationID,
            fields: transfer.initialFields,
        )
    }

    private func transferProgress(_ transfer: BrowserSaveTransfer, fraction: Double) {
        guard activeTransfer === transfer else {
            return
        }

        transferState = "\(transfer.caseID): downloading \(Int(fraction * 100))%"
    }

    private func transferFinished(_ transfer: BrowserSaveTransfer, result: TransferResult) {
        guard activeTransfer === transfer else {
            return
        }

        reporter.record(
            kind: result.kind,
            profileID: transfer.profileID,
            profile: transfer.profile,
            operationID: transfer.operationID,
            fields: result.fields,
        )
        transferState = "\(transfer.caseID): \(result.status)"
        activeTransfer = nil
        companionWebView = nil
    }

    private func makeCompanionWebView() -> (WKWebView, Bool) {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = selectedStore
        let webView = WKWebView(frame: .zero, configuration: configuration)
        let exactStore = ObjectIdentifier(configuration.websiteDataStore) == ObjectIdentifier(selectedStore)
        return (webView, exactStore)
    }

    private var currentProfile: String {
        selectedProfile.rawValue
    }

    private var currentProfileID: String {
        profileInstanceID
    }

    private var currentStore: WKWebsiteDataStore {
        selectedStore
    }

    fileprivate var scratchRoot: URL {
        scratchDirectory
    }

    fileprivate var receiptRoot: URL {
        receiptDirectory
    }

    private var eventReporter: SpikeEventReporter {
        reporter
    }

    private func startTransfer(url: URL, caseID: String, source: String) {
        guard activeTransfer == nil else {
            reject(caseID: caseID, reason: "transfer-already-active")
            return
        }
        guard caseID.range(of: "^[a-z0-9-]{1,48}$", options: .regularExpression) != nil else {
            reject(caseID: "invalid-case", reason: "case-id-invalid")
            return
        }
        guard let origin = HTTPOrigin(url: url),
              origin.scheme == "https" || (origin.scheme == "http" && origin.isLoopback)
        else {
            reject(caseID: caseID, reason: "http-origin-required")
            return
        }
        guard url.user == nil, url.password == nil else {
            reject(caseID: caseID, reason: "userinfo-rejected")
            return
        }

        do {
            try FileManager.default.createDirectory(at: scratchDirectory, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: receiptDirectory, withIntermediateDirectories: true)
        } catch {
            reject(caseID: caseID, reason: "staging-unavailable")
            return
        }

        let operationID = UUID().uuidString.lowercased()
        let (webView, exactStore) = makeCompanionWebView()
        companionWebView = webView
        let transfer = BrowserSaveTransfer(
            operationID: operationID,
            caseID: caseID,
            source: source,
            initialURL: url,
            exactStoreMatch: exactStore,
            profile: currentProfile,
            profileID: currentProfileID,
            scratchRoot: scratchRoot,
            receiptRoot: receiptRoot,
            reporter: eventReporter,
            progress: { [weak self] fraction, transfer in self?.transferProgress(transfer, fraction: fraction) },
            completion: { [weak self] transfer, result in self?.transferFinished(transfer, result: result) },
        )
        transferDidStart(transfer)

        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 45)
        request.httpMethod = "GET"
        request.httpBody = nil
        request.setValue(nil, forHTTPHeaderField: "Cookie")
        request.setValue(nil, forHTTPHeaderField: "Authorization")
        webView.startDownload(using: request) { [weak transfer] download in
            transfer?.attach(download)
        }
    }

    private func reject(caseID: String, reason: String) {
        transferState = "\(caseID): rejected \(reason)"
        reporter.record(
            kind: "acquisition-rejected",
            profileID: profileInstanceID,
            profile: selectedProfile.rawValue,
            operationID: UUID().uuidString.lowercased(),
            fields: ["case_id": caseID, "reason": reason, "app_owned_request_started": "false"],
        )
    }

    private func navigate(to url: URL) {
        transferState = "page navigation allowed"
        _ = page.load(URLRequest(url: url))
    }

    private func makePage(using store: WKWebsiteDataStore) -> WebPage {
        var configuration = WebPage.Configuration()
        configuration.websiteDataStore = store
        return WebPage(configuration: configuration, navigationDecider: router)
    }

    private func prepareStorage() {
        do {
            try FileManager.default.createDirectory(at: scratchDirectory, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: receiptDirectory, withIntermediateDirectories: true)
            try FileManager.default.setAttributes(
                [.protectionKey: FileProtectionType.completeUnlessOpen],
                ofItemAtPath: receiptDirectory.path,
            )
            let attributes = try FileManager.default.attributesOfItem(atPath: receiptDirectory.path)
            reporter.record(
                kind: "receipt-directory-protection-observed",
                profileID: profileInstanceID,
                profile: selectedProfile.rawValue,
                operationID: nil,
                fields: ["requested": "completeUnlessOpen", "actual": protectionValue(attributes[.protectionKey])],
            )
        } catch {
            transferState = "receipt staging preparation failed"
            reporter.record(
                kind: "receipt-directory-protection-failed",
                profileID: profileInstanceID,
                profile: selectedProfile.rawValue,
                operationID: nil,
                fields: ["requested": "completeUnlessOpen", "error_domain": (error as NSError).domain],
            )
        }
    }
}

/// Intercepts only the fixture's explicit custom-scheme Save links.
@MainActor
private final class SaveIntentNavigationRouter: WebPage.NavigationDeciding {
    weak var harness: BrowserSaveToVaultHarness?

    func decidePolicy(
        for action: WebPage.NavigationAction,
        preferences _: inout WebPage.NavigationPreferences,
    ) async -> WKNavigationActionPolicy {
        guard let url = action.request.url,
              url.scheme?.lowercased() == "vault-save"
        else {
            return .allow
        }

        harness?.handleSaveIntent(url)
        return .cancel
    }

    func decidePolicy(for _: WebPage.NavigationResponse) async -> WKNavigationResponsePolicy {
        .allow
    }
}

/// Owns a single WKDownload and enforces its redirect, receipt, and cancellation rules.
@MainActor
private final class BrowserSaveTransfer: NSObject, WKDownloadDelegate {
    let operationID: String
    let caseID: String
    let source: String
    let initialURL: URL
    let exactStoreMatch: Bool
    let profile: String
    let profileID: String
    let scratchURL: URL
    let receiptRoot: URL
    let reporter: SpikeEventReporter

    private let progress: (Double, BrowserSaveTransfer) -> Void
    private let completion: (BrowserSaveTransfer, TransferResult) -> Void
    private var download: WKDownload?
    private var progressObservation: NSKeyValueObservation?
    private var destinationURL: URL?
    private var finalResponseURL: URL?
    private var receiptCreatedURL: URL?
    private var responseStatus: Int?
    private var responseMIME = "unknown"
    private var cancellationRequested = false
    private var terminal = false

    var initialFields: [String: String] {
        [
            "case_id": caseID,
            "selection_source": source,
            "method": "GET",
            "origin": HTTPOrigin(url: initialURL)?.description ?? "non-http-origin",
            "request_body_present": "false",
            "manual_cookie_added": "false",
            "manual_authorization_added": "false",
            "exact_website_data_store_match": String(exactStoreMatch),
        ]
    }

    init(
        operationID: String,
        caseID: String,
        source: String,
        initialURL: URL,
        exactStoreMatch: Bool,
        profile: String,
        profileID: String,
        scratchRoot: URL,
        receiptRoot: URL,
        reporter: SpikeEventReporter,
        progress: @escaping (Double, BrowserSaveTransfer) -> Void,
        completion: @escaping (BrowserSaveTransfer, TransferResult) -> Void,
    ) {
        self.operationID = operationID
        self.caseID = caseID
        self.source = source
        self.initialURL = initialURL
        self.exactStoreMatch = exactStoreMatch
        self.profile = profile
        self.profileID = profileID
        scratchURL = scratchRoot.appendingPathComponent("\(operationID).partial")
        self.receiptRoot = receiptRoot
        self.reporter = reporter
        self.progress = progress
        self.completion = completion
        super.init()
    }

    func attach(_ download: WKDownload) {
        guard !terminal else {
            download.cancel { _ in }
            return
        }

        self.download = download
        download.delegate = self
        progressObservation = download.progress.observe(\.fractionCompleted, options: [
            .initial,
            .new,
        ]) { [weak self] observed, _ in
            let fraction = observed.fractionCompleted
            Task { @MainActor [weak self] in
                guard let self, !self.terminal else {
                    return
                }

                progress(fraction, self)
            }
        }
        reporter.record(
            kind: "download-object-created",
            profileID: profileID,
            profile: profile,
            operationID: operationID,
            fields: ["delegate_assigned": "true", "progress_api": "WKDownload.progress"],
        )
    }

    func cancel() {
        guard !terminal, !cancellationRequested else {
            return
        }

        cancellationRequested = true
        reporter.record(
            kind: "cancellation-requested",
            profileID: profileID,
            profile: profile,
            operationID: operationID,
            fields: ["receipt_publication_invalidated": "true"],
        )
        guard let download else {
            finish(status: "cancelled", kind: "transfer-cancelled", fields: ["download_created": "false"])
            return
        }

        download.cancel { [weak self] resumeData in
            Task { @MainActor [weak self] in
                guard let self else {
                    return
                }

                finish(
                    status: "cancelled",
                    kind: "transfer-cancelled",
                    fields: [
                        "resume_data_available": String((resumeData?.isEmpty == false)),
                        "resume_data_contents_recorded": "false",
                        "receipt_published": "false",
                    ],
                )
            }
        }
    }

    func failBeforeStart(reason: String) {
        finish(
            status: "failed \(reason)",
            kind: "transfer-failed",
            fields: ["reason": reason, "receipt_published": "false"],
        )
    }

    func download(
        _: WKDownload,
        decideDestinationUsing response: URLResponse,
        suggestedFilename _: String,
    ) async -> URL? {
        guard !terminal, !cancellationRequested else {
            return nil
        }

        let status = (response as? HTTPURLResponse)?.statusCode
        guard let status, (200 ..< 300).contains(status) else {
            finish(
                status: "rejected HTTP \(status.map(String.init) ?? "unknown")",
                kind: "http-response-rejected",
                fields: [
                    "response_status": status.map(String.init) ?? "unknown",
                    "final_origin": HTTPOrigin(url: response.url ?? initialURL)?.description ?? "non-http-origin",
                    "receipt_published": "false",
                ],
            )
            return nil
        }
        guard !FileManager.default.fileExists(atPath: scratchURL.path) else {
            finish(status: "failed scratch collision", kind: "transfer-failed", fields: ["reason": "scratch-collision"])
            return nil
        }

        responseStatus = status
        responseMIME = response.mimeType?.lowercased() ?? "unknown"
        destinationURL = scratchURL
        finalResponseURL = response.url
        reporter.record(
            kind: "transfer-destination-selected",
            profileID: profileID,
            profile: profile,
            operationID: operationID,
            fields: [
                "response_status": String(status),
                "response_mime_type": responseMIME,
                "final_origin": HTTPOrigin(url: response.url ?? initialURL)?.description ?? "non-http-origin",
                "suggested_filename_used": "false",
                "destination": "app-transfer-scratch",
            ],
        )
        return scratchURL
    }

    func download(
        _: WKDownload,
        decidedPolicyForHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
    ) async -> WKDownload.RedirectPolicy {
        guard let sourceURL = response.url,
              let redirectURL = request.url,
              let sourceOrigin = HTTPOrigin(url: sourceURL),
              let destinationOrigin = HTTPOrigin(url: redirectURL),
              let initialOrigin = HTTPOrigin(url: initialURL)
        else {
            recordRedirect(allowed: false, reason: "non-http-origin", source: response.url, destination: request.url)
            return .cancel
        }

        let downgrade = sourceOrigin.scheme == "https" && destinationOrigin.scheme == "http"
        let sameOrigin = sourceOrigin == destinationOrigin && destinationOrigin == initialOrigin
        let allowed = !downgrade && sameOrigin
        let reason = downgrade ? "https-downgrade" : (sameOrigin ? "same-origin" : "cross-origin")
        recordRedirect(allowed: allowed, reason: reason, source: sourceURL, destination: redirectURL)
        return allowed ? .allow : .cancel
    }

    func downloadDidFinish(_: WKDownload) {
        guard !terminal else {
            return
        }
        guard !cancellationRequested,
              let destinationURL,
              let responseStatus,
              (200 ..< 300).contains(responseStatus)
        else {
            finish(status: "cancelled", kind: "transfer-cancelled", fields: ["receipt_published": "false"])
            return
        }

        do {
            let data = try Data(contentsOf: destinationURL, options: [.mappedIfSafe])
            let digest = Self.sha256(data)
            reporter.record(
                kind: "transfer-bytes-completed",
                profileID: profileID,
                profile: profile,
                operationID: operationID,
                fields: [
                    "case_id": caseID,
                    "response_status": String(responseStatus),
                    "response_mime_type": responseMIME,
                    "byte_count": String(data.count),
                    "sha256": digest,
                    "final_origin": finalResponseURL.flatMap(HTTPOrigin.init(url:))?.description ?? "non-http-origin",
                ],
            )
            let mediaKind = try Self.validate(data: data, mimeType: responseMIME)
            reporter.record(
                kind: "transfer-completed",
                profileID: profileID,
                profile: profile,
                operationID: operationID,
                fields: [
                    "case_id": caseID,
                    "response_status": String(responseStatus),
                    "response_mime_type": responseMIME,
                    "classified_kind": mediaKind.rawValue,
                    "byte_count": String(data.count),
                    "sha256": digest,
                    "final_origin": finalResponseURL.flatMap(HTTPOrigin.init(url:))?.description ?? "non-http-origin",
                    "transfer_scratch_protection": "not-a-receipt",
                ],
            )

            let receiptURL = receiptRoot.appendingPathComponent("\(caseID).receipt")
            guard !FileManager.default.fileExists(atPath: receiptURL.path) else {
                throw TransferError.receiptAlreadyExists
            }

            try FileManager.default.moveItem(at: destinationURL, to: receiptURL)
            receiptCreatedURL = receiptURL
            try FileManager.default.setAttributes(
                [.protectionKey: FileProtectionType.completeUnlessOpen],
                ofItemAtPath: receiptURL.path,
            )
            let attributes = try FileManager.default.attributesOfItem(atPath: receiptURL.path)
            let observedProtection = protectionValue(attributes[.protectionKey])
            let stagedData = try Data(contentsOf: receiptURL, options: [.mappedIfSafe])
            guard stagedData == data else {
                throw TransferError.receiptBytesChanged
            }

            reporter.record(
                kind: "receipt-accepted",
                profileID: profileID,
                profile: profile,
                operationID: operationID,
                fields: [
                    "case_id": caseID,
                    "relative_path": "receipt-staging/\(caseID).receipt",
                    "protection_requested": "completeUnlessOpen",
                    "protection_actual": observedProtection,
                    "byte_count": String(stagedData.count),
                    "sha256": Self.sha256(stagedData),
                    "transfer_to_receipt_bytes_identical": "true",
                    "canonical_library_committed": "false",
                ],
            )
            finish(
                status: "receipt accepted; journal handoff test-only",
                kind: "receipt-result",
                fields: ["receipt_published": "true"],
            )
        } catch {
            try? FileManager.default.removeItem(at: destinationURL)
            if let receiptCreatedURL {
                try? FileManager.default.removeItem(at: receiptCreatedURL)
                self.receiptCreatedURL = nil
            }
            finish(
                status: "rejected \(error is TransferError ? "unsupported content" : "receipt staging failed")",
                kind: "receipt-rejected",
                fields: [
                    "case_id": caseID,
                    "reason": error is TransferError ? "content-or-duplicate" : "staging-or-protection",
                    "receipt_published": "false",
                ],
            )
        }
    }

    func download(_: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        guard !terminal else {
            return
        }

        if cancellationRequested {
            finish(
                status: "cancelled",
                kind: "transfer-cancelled",
                fields: [
                    "resume_data_available": String(resumeData?.isEmpty == false),
                    "resume_data_contents_recorded": "false",
                    "receipt_published": "false",
                ],
            )
        } else {
            finish(
                status: "failed transfer",
                kind: "transfer-failed",
                fields: [
                    "error_domain": (error as NSError).domain,
                    "error_code": String((error as NSError).code),
                    "resume_data_available": String(resumeData?.isEmpty == false),
                    "receipt_published": "false",
                ],
            )
        }
    }

    func download(
        _: WKDownload,
        respondTo challenge: URLAuthenticationChallenge,
        completionHandler: (URLSession.AuthChallengeDisposition, URLCredential?) -> Void,
    ) {
        let space = challenge.protectionSpace
        if space.authenticationMethod == NSURLAuthenticationMethodServerTrust,
           space.host == "127.0.0.1",
           space.port == 18_754,
           let trust = space.serverTrust {
            reporter.record(
                kind: "fixture-tls-trust-override",
                profileID: profileID,
                profile: profile,
                operationID: operationID,
                fields: ["host": "127.0.0.1", "port": "18754", "scope": "loopback fixture only"],
            )
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }

    private func recordRedirect(allowed: Bool, reason: String, source: URL?, destination: URL?) {
        reporter.record(
            kind: "redirect-decision",
            profileID: profileID,
            profile: profile,
            operationID: operationID,
            fields: [
                "allowed": String(allowed),
                "reason": reason,
                "source_origin": source.flatMap(HTTPOrigin.init(url:))?.description ?? "non-http-origin",
                "destination_origin": destination.flatMap(HTTPOrigin.init(url:))?.description ?? "non-http-origin",
                "credential_safety_inferred_from_delegate": "false",
            ],
        )
    }

    private func finish(status: String, kind: String, fields: [String: String]) {
        guard !terminal else {
            return
        }

        terminal = true
        progressObservation?.invalidate()
        progressObservation = nil
        if let destinationURL, FileManager.default.fileExists(atPath: destinationURL.path) {
            try? FileManager.default.removeItem(at: destinationURL)
        }
        completion(self, TransferResult(status: status, kind: kind, fields: fields))
    }

    private static func validate(data: Data, mimeType: String) throws -> MediaReceiptKind {
        if mimeType == "image/jpeg" || mimeType == "image/png" || mimeType == "image/heic" {
            guard let imageSource = CGImageSourceCreateWithData(data as CFData, nil),
                  CGImageSourceGetCount(imageSource) == 1,
                  let typeIdentifier = CGImageSourceGetType(imageSource) as String?,
                  UTType(typeIdentifier)?.conforms(to: .image) == true
            else {
                throw TransferError.unsupportedMediaBytes
            }

            return .stillImage
        }
        if mimeType == "video/mp4" {
            guard hasValidMP4BoxStructure(data) else {
                throw TransferError.unsupportedMediaBytes
            }
            return .video
        }
        throw TransferError.unsupportedMediaType
    }

    /// Requires consistent top-level ISO BMFF boxes for the file type, movie metadata, and media data.
    private static func hasValidMP4BoxStructure(_ data: Data) -> Bool {
        var offset = 0
        var boxIndex = 0
        var containsFileType = false
        var containsMovie = false
        var containsMediaData = false

        while offset < data.count {
            let remaining = data.count - offset
            guard remaining >= 8 else { return false }
            let size32 = data[offset ..< offset + 4].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
            guard let type = String(data: data[offset + 4 ..< offset + 8], encoding: .ascii) else {
                return false
            }

            var headerSize = 8
            let boxSize: UInt64
            if size32 == 1 {
                guard remaining >= 16 else { return false }
                headerSize = 16
                boxSize = data[offset + 8 ..< offset + 16].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
            } else if size32 == 0 {
                boxSize = UInt64(remaining)
            } else {
                boxSize = size32
            }

            guard boxSize >= UInt64(headerSize), boxSize <= UInt64(remaining) else { return false }
            if boxIndex == 0, type != "ftyp" { return false }
            switch type {
            case "ftyp":
                guard !containsFileType, boxSize >= UInt64(headerSize + 8) else { return false }
                containsFileType = true
            case "moov":
                guard !containsMovie, boxSize > UInt64(headerSize) else { return false }
                containsMovie = true
            case "mdat":
                guard boxSize > UInt64(headerSize) else { return false }
                containsMediaData = true
            default:
                break
            }

            offset += Int(boxSize)
            boxIndex += 1
        }

        return offset == data.count && containsFileType && containsMovie && containsMediaData
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

private enum MediaReceiptKind: String {
    case stillImage = "still-image"
    case video
}

private enum TransferError: Error {
    case unsupportedMediaType
    case unsupportedMediaBytes
    case receiptAlreadyExists
    case receiptBytesChanged
}

private struct TransferResult {
    let status: String
    let kind: String
    let fields: [String: String]
}

/// Reduces every URL used in event records to its scheme, host, and effective port.
private struct HTTPOrigin: Equatable {
    let scheme: String
    let host: String
    let port: Int

    init?(url: URL) {
        guard let normalizedScheme = url.scheme?.lowercased(),
              normalizedScheme == "http" || normalizedScheme == "https",
              let normalizedHost = url.host?.lowercased(),
              !normalizedHost.isEmpty
        else {
            return nil
        }

        scheme = normalizedScheme
        host = normalizedHost
        port = url.port ?? (normalizedScheme == "https" ? 443 : 80)
    }

    var isLoopback: Bool {
        host == "127.0.0.1" || host == "localhost"
    }

    var description: String {
        "\(scheme)://\(host):\(port)"
    }
}

/// Posts sanitized app events to the independent loopback fixture server.
@MainActor
private final class SpikeEventReporter {
    private let endpoint: URL
    private let session: URLSession

    init(baseURL: URL) {
        endpoint = baseURL.appending(path: "/__spike/event")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.httpShouldSetCookies = false
        session = URLSession(configuration: configuration)
    }

    func record(kind: String, profileID: String, profile: String, operationID: String?, fields: [String: String]) {
        var event: [String: Any] = [
            "kind": kind,
            "timestamp": Date().timeIntervalSince1970,
            "profile_id": profileID,
            "profile": profile,
            "fields": fields,
        ]
        if let operationID {
            event["operation_id"] = operationID
        }
        guard let body = try? JSONSerialization.data(withJSONObject: event) else {
            return
        }

        var request = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 5)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        session.dataTask(with: request).resume()
    }
}

private func protectionValue(_ value: Any?) -> String {
    guard let value else {
        return "unreported"
    }

    if let protection = value as? FileProtectionType {
        return protection == .completeUnlessOpen ? "completeUnlessOpen" : String(describing: protection)
    }
    return String(describing: value)
}
