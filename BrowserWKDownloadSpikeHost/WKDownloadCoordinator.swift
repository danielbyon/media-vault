import CryptoKit
import Foundation
import WebKit

/// Owns one hidden WebKit download and all of the objects required by its callbacks.
@MainActor
final class WKDownloadCoordinator: NSObject, WKDownloadDelegate {
    let operationID: String
    let scenarioRunID: String
    let profileID: String
    let profile: SpikeProfile
    let scenarioID: String
    let parentOperationID: String?

    private let context: SpikeProfileContext
    private let harness: SpikeHarness
    private let websiteDataStore: WKWebsiteDataStore
    let websiteDataStoreID: String
    let initialURL: URL
    private let requestEvidence: [String: String]
    private let cancelAfterProgress: Bool
    private let shouldResumeCancellation: Bool
    private let scratchDirectory: URL

    private var companion: WKWebView?
    private var download: WKDownload?
    private var progressObservation: NSKeyValueObservation?
    private var destinationURL: URL?
    private var responseStatusCode: Int?
    private var terminal = false
    private var cancellationRequested = false
    private var cancellationRecorded = false
    private(set) var hasObservedProgress = false
    private var operationInvalidated = false
    private var profileRetirementRequested = false
    private var scenarioTimeoutRequested = false
    private var cancellationCallIssued = false
    private var downloadStartPending = false
    private var didAutoCancel = false
    private var lastProgressBucket = -1
    private var latestResumeData: Data?

    var isReconciled: Bool { terminal }

    var requiresServerTransferObservation: Bool {
        initialURL.path.hasPrefix("/resource/slow-")
    }

    var destinationRelativePath: String {
        destinationURL?.lastPathComponent ?? "unassigned"
    }

    var statusOwner: ScenarioStatusOwner {
        ScenarioStatusOwner(
            scenarioRunID: scenarioRunID,
            operationID: operationID,
            scenarioID: scenarioID,
            profileID: profileID,
            websiteDataStoreID: websiteDataStoreID,
            parentOperationID: parentOperationID
        )
    }

    var identityFields: [String: String] {
        [
            "scenario_run_id": scenarioRunID,
            "website_data_store_id": websiteDataStoreID,
            "parent_operation_id": parentOperationID ?? "none",
            "parent_resume_operation_id": parentOperationID ?? "none",
            "scratch_profile_id": profileID,
            "scratch_operation_id": operationID,
            "destination_relative_path": destinationRelativePath
        ]
    }

    init(
        operationID: String,
        scenarioRunID: String,
        scenarioID: String,
        context: SpikeProfileContext,
        harness: SpikeHarness,
        initialURL: URL,
        requestEvidence: [String: String],
        websiteDataStore: WKWebsiteDataStore? = nil,
        websiteDataStoreID: String? = nil,
        parentOperationID: String? = nil,
        cancelAfterProgress: Bool = false,
        shouldResumeCancellation: Bool = false
    ) throws {
        self.operationID = operationID
        self.scenarioRunID = scenarioRunID
        self.profileID = context.profileID
        self.profile = context.profile
        self.scenarioID = scenarioID
        self.context = context
        self.harness = harness
        self.websiteDataStore = websiteDataStore ?? context.websiteDataStore
        self.websiteDataStoreID = websiteDataStoreID ?? context.websiteDataStoreID
        self.initialURL = initialURL
        self.requestEvidence = requestEvidence
        self.parentOperationID = parentOperationID
        self.cancelAfterProgress = cancelAfterProgress
        self.shouldResumeCancellation = shouldResumeCancellation

        let directory = FileManager.default.temporaryDirectory
            .appending(path: "BrowserWKDownloadSpike", directoryHint: .isDirectory)
            .appending(path: context.profileID, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        self.scratchDirectory = directory
        super.init()

        let webViewConfiguration = WKWebViewConfiguration()
        webViewConfiguration.websiteDataStore = self.websiteDataStore
        let webView = WKWebView(frame: .zero, configuration: webViewConfiguration)
        self.companion = webView
        let sharedStore = webView.configuration.websiteDataStore === context.websiteDataStore
        record(
            kind: "companion-created",
            profileID: profileID,
            profile: profile.rawValue,
            operationID: operationID,
            fields: [
                "scenario": scenarioID,
                "page_store_id": context.websiteDataStoreID,
                "companion_store_id": self.websiteDataStoreID,
                "website_data_store_id": self.websiteDataStoreID,
                "exact_store_instance": String(sharedStore),
                "companion_attached_to_window": "false",
                "initial_origin": Self.safeOrigin(initialURL)
            ]
        )
        record(
            kind: "request-captured",
            profileID: profileID,
            profile: profile.rawValue,
            operationID: operationID,
            fields: requestEvidence.merging(["scenario": scenarioID]) { current, _ in current }
        )
    }

    /// Starts a new download from the WebPage's unchanged observed request.
    func start(request: URLRequest) {
        let lookupURL = request.url ?? initialURL
        let store = websiteDataStore
        downloadStartPending = true
        Task { @MainActor [weak self] in
            let cookies = await store.httpCookieStore.cookies(for: lookupURL)
            guard let self else { return }
            self.downloadStartPending = false
            self.record(
                kind: "companion-cookie-lookup",
                profileID: self.profileID,
                profile: self.profile.rawValue,
                operationID: self.operationID,
                fields: [
                    "store_id": self.websiteDataStoreID,
                    "store_is_originating_page_store": String(store === self.context.websiteDataStore),
                    "cookie_names": cookies.map(\.name).sorted().joined(separator: ","),
                    "http_only_cookie_names": cookies.filter(\.isHTTPOnly).map(\.name).sorted().joined(separator: ","),
                    "secure_cookie_names": cookies.filter(\.isSecure).map(\.name).sorted().joined(separator: ","),
                    "cookie_values_recorded": "false"
                ]
            )
            guard !self.terminal else { return }
            guard !self.operationInvalidated else {
                self.handleCancellation(resumeData: nil, source: "invalidated-before-download-start")
                return
            }
            guard let companion = self.companion else {
                self.finishWithoutDownload(reason: "companion-unavailable")
                return
            }
            self.downloadStartPending = true
            companion.startDownload(using: request) { [weak self] download in
                guard let self else { return }
                self.downloadStartPending = false
                self.download = download
                download.delegate = self
                self.observeProgress(of: download)
                self.record(
                    kind: "download-started",
                    profileID: self.profileID,
                    profile: self.profile.rawValue,
                    operationID: self.operationID,
                    fields: [
                        "scenario": self.scenarioID,
                        "delegate_assigned_in_start_completion": "true",
                        "progress_interface": "WKDownload.progress",
                        "parent_operation_id": self.parentOperationID ?? "none"
                    ]
                )
                self.issueCancellationIfPossible()
            }
        }
    }

    /// Resumes only when WebKit supplied nonempty resume data.
    func resume(from resumeData: Data) {
        guard !resumeData.isEmpty,
              let companion
        else {
            finishWithoutDownload(reason: "resume-data-unavailable")
            return
        }
        downloadStartPending = true
        companion.resumeDownload(fromResumeData: resumeData) { [weak self] download in
            guard let self else { return }
            self.downloadStartPending = false
            self.download = download
            download.delegate = self
            self.observeProgress(of: download)
            self.record(
                kind: "download-resumed",
                profileID: self.profileID,
                profile: self.profile.rawValue,
                operationID: self.operationID,
                fields: [
                    "scenario": self.scenarioID,
                    "delegate_assigned_in_resume_completion": "true",
                    "resume_data_length": String(resumeData.count),
                    "parent_operation_id": self.parentOperationID ?? "none"
                ]
            )
            self.issueCancellationIfPossible()
        }
    }

    /// Cancels the retained WebKit download and records any resume data separately.
    func cancel() {
        requestCancellation(reason: "explicit-cancel")
    }

    func beginProfileRetirement() {
        profileRetirementRequested = true
        requestCancellation(reason: "ephemeral-profile-retirement")
    }

    func cancelForScenarioTimeout() {
        scenarioTimeoutRequested = true
        requestCancellation(reason: "scenario-timeout")
    }

    private func requestCancellation(reason: String) {
        guard !terminal else { return }
        operationInvalidated = true
        if !cancellationRequested {
            cancellationRequested = true
            record(
                kind: "download-cancellation-requested",
                fields: ["reason": reason, "receipt_publication_invalidated": "true"]
            )
        }
        issueCancellationIfPossible()
    }

    private func issueCancellationIfPossible() {
        guard cancellationRequested, !terminal else { return }
        guard let download else {
            if !downloadStartPending {
                handleCancellation(resumeData: nil, source: "no-download-object")
            }
            return
        }
        guard !cancellationCallIssued else { return }
        cancellationCallIssued = true
        download.cancel { [weak self] resumeData in
            Task { @MainActor in
                self?.handleCancellation(resumeData: resumeData, source: "cancel-completion")
            }
        }
    }

    func download(
        _ download: WKDownload,
        decideDestinationUsing response: URLResponse,
        suggestedFilename: String
    ) async -> URL? {
        guard !operationInvalidated, !terminal else {
            record(
                kind: "download-destination-rejected",
                fields: ["reason": "operation-invalidated-before-destination"]
            )
            return nil
        }
        let url = scratchDirectory.appending(path: "\(operationID).partial")
        guard !FileManager.default.fileExists(atPath: url.path),
              FileManager.default.fileExists(atPath: scratchDirectory.path)
        else {
            record(
                kind: "download-destination-rejected",
                profileID: profileID,
                profile: profile.rawValue,
                operationID: operationID,
                fields: ["reason": "destination-not-unique-or-parent-missing"]
            )
            return nil
        }
        destinationURL = url
        responseStatusCode = (response as? HTTPURLResponse)?.statusCode
        record(
            kind: "download-destination-selected",
            profileID: profileID,
            profile: profile.rawValue,
            operationID: operationID,
            fields: [
                "scratch_profile_id": profileID,
                "scratch_operation_id": operationID,
                "destination_exists_before_start": "false",
                "parent_exists": "true",
                "suggested_filename_used": "false",
                "response_mime_type": response.mimeType ?? "unknown",
                "response_status": responseStatusCode.map(String.init) ?? "unknown"
            ]
        )
        return url
    }

    func download(
        _ download: WKDownload,
        decidedPolicyForHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest
    ) async -> WKDownload.RedirectPolicy {
        guard let sourceURL = response.url,
              let destinationURL = request.url
        else {
            record(
                kind: "redirect-decision",
                profileID: profileID,
                profile: profile.rawValue,
                operationID: operationID,
                fields: ["allowed": "false", "reason": "missing-url"]
            )
            return .cancel
        }

        let allowed = WKDownloadOriginPolicy.allowsRedirect(
            from: sourceURL,
            to: destinationURL,
            initial: initialURL
        )
        let reason = WKDownloadOriginPolicy.denialReason(
            from: sourceURL,
            to: destinationURL,
            initial: initialURL
        )
        record(
            kind: "redirect-decision",
            profileID: profileID,
            profile: profile.rawValue,
            operationID: operationID,
            fields: [
                "allowed": String(allowed),
                "reason": reason,
                "source_origin": Self.safeOrigin(sourceURL),
                "destination_origin": Self.safeOrigin(destinationURL),
                "initial_origin": Self.safeOrigin(initialURL),
                "source_request_semantics": "WebKit redirect request",
                "credential_safety_inferred_from_callback": "false"
            ]
        )
        return allowed ? .allow : .cancel
    }

    func download(
        _ download: WKDownload,
        respondTo challenge: URLAuthenticationChallenge
    ) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        let host = challenge.protectionSpace.host.lowercased()
        let method = challenge.protectionSpace.authenticationMethod
        if method == NSURLAuthenticationMethodServerTrust,
           Self.isFixtureHost(host),
           let trust = challenge.protectionSpace.serverTrust
        {
            record(
                kind: "authentication-challenge",
                profileID: profileID,
                profile: profile.rawValue,
                operationID: operationID,
                fields: ["origin": Self.safeChallengeOrigin(challenge), "method": "local-fixture-server-trust", "identity": "loopback-fixture"]
            )
            return (.useCredential, URLCredential(trust: trust))
        }

        if method == NSURLAuthenticationMethodHTTPBasic,
           Self.isFixtureHost(host),
           scenarioID == "basic-auth"
        {
            let user = "spike-basic-user"
            let pass = UUID().uuidString
            let identity = Self.shortHash(user)
            record(
                kind: "authentication-challenge",
                profileID: profileID,
                profile: profile.rawValue,
                operationID: operationID,
                fields: ["origin": Self.safeChallengeOrigin(challenge), "method": "http-basic", "identity_sha256_prefix": identity]
            )
            return (.useCredential, URLCredential(user: user, password: pass, persistence: .forSession))
        }

        record(
            kind: "authentication-challenge",
            profileID: profileID,
            profile: profile.rawValue,
            operationID: operationID,
            fields: ["origin": Self.safeChallengeOrigin(challenge), "method": method, "disposition": "cancel"]
        )
        return (.cancelAuthenticationChallenge, nil)
    }

    func downloadDidFinish(_ download: WKDownload) {
        guard !terminal else { return }
        progressObservation?.invalidate()
        progressObservation = nil
        if operationInvalidated || cancellationRequested {
            try? destinationURL.map { try FileManager.default.removeItem(at: $0) }
            handleCancellation(resumeData: nil, source: "finish-callback-after-invalidation")
            return
        }
        if let responseStatusCode, !(200..<300).contains(responseStatusCode) {
            failWithoutError(reason: "http-status-\(responseStatusCode)")
            return
        }
        guard let partialURL = destinationURL,
              FileManager.default.fileExists(atPath: partialURL.path),
              let attributes = try? FileManager.default.attributesOfItem(atPath: partialURL.path),
              let byteCount = attributes[.size] as? NSNumber,
              let data = try? Data(contentsOf: partialURL)
        else {
            failWithoutError(reason: "finish-callback-without-complete-file")
            return
        }

        let hash = Self.sha256(data)
        let verified = partialURL.deletingPathExtension().appendingPathExtension("verified")
        do {
            try FileManager.default.moveItem(at: partialURL, to: verified)
            destinationURL = verified
            terminal = true
            record(
                kind: "download-complete",
                profileID: profileID,
                profile: profile.rawValue,
                operationID: operationID,
                fields: [
                    "file_exists": "true",
                    "byte_count": byteCount.stringValue,
                    "sha256": hash,
                    "verified_receipt_published": "true",
                    "scratch_profile_id": profileID,
                    "scratch_operation_id": operationID,
                    "parent_operation_id": parentOperationID ?? "none"
                ]
            )
            harness.coordinatorDidFinish(self, status: "complete")
        } catch {
            try? FileManager.default.removeItem(at: partialURL)
            failWithoutError(reason: "could-not-publish-verified-receipt")
        }
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        guard !terminal else { return }
        let nsError = error as NSError
        record(
            kind: "download-failure",
            profileID: profileID,
            profile: profile.rawValue,
            operationID: operationID,
            fields: [
                "error_domain": nsError.domain,
                "error_code": String(nsError.code),
                "cancel_requested": String(cancellationRequested),
                "resume_data_callback_present": String(resumeData != nil),
                "resume_data_length": String(resumeData?.count ?? 0)
            ]
        )
        if cancellationRequested {
            handleCancellation(resumeData: resumeData, source: "failure-delegate")
        } else {
            finishFailedDownload(reason: "webkit-download-failed")
            if let resumeData {
                recordResumeData(resumeData, source: "failure-delegate")
            } else {
                recordNoResumeData(source: "failure-delegate")
            }
        }
    }

    private func observeProgress(of download: WKDownload) {
        progressObservation = download.progress.observe(\.fractionCompleted, options: [.initial, .new]) { [weak self] progress, _ in
            let fraction = progress.fractionCompleted
            let completed = progress.completedUnitCount
            let total = progress.totalUnitCount
            Task { @MainActor in
                self?.recordProgress(fraction: fraction, completed: completed, total: total)
            }
        }
    }

    private func recordProgress(fraction: Double, completed: Int64, total: Int64) {
        guard !terminal else { return }
        if fraction > 0 || completed > 0 {
            hasObservedProgress = true
        }
        let bucket = max(0, min(100, Int(fraction * 100)))
        guard bucket != lastProgressBucket else { return }
        lastProgressBucket = bucket
        record(
            kind: "download-progress",
            profileID: profileID,
            profile: profile.rawValue,
            operationID: operationID,
            fields: [
                "fraction_completed": String(fraction),
                "completed_unit_count": String(completed),
                "total_unit_count": String(total),
                "source": "WKDownload.progress"
            ]
        )
        if cancelAfterProgress, fraction > 0, !didAutoCancel {
            didAutoCancel = true
            cancel()
        }
    }

    private func handleCancellation(resumeData: Data?, source: String) {
        guard !cancellationRecorded else { return }
        cancellationRecorded = true
        cancellationRequested = true
        record(
            kind: "download-cancellation",
            profileID: profileID,
            profile: profile.rawValue,
            operationID: operationID,
            fields: ["source": source, "requested": "true"]
        )
        if let resumeData {
            recordResumeData(resumeData, source: source)
            latestResumeData = resumeData.isEmpty ? nil : resumeData
        } else {
            recordNoResumeData(source: source)
            latestResumeData = nil
        }
        try? destinationURL.map { try FileManager.default.removeItem(at: $0) }
        terminal = true
        progressObservation?.invalidate()
        progressObservation = nil
        record(
            kind: "download-cancellation-reconciled",
            fields: [
                "source": source,
                "resume_data_available": String(latestResumeData != nil),
                "incomplete_receipt_published": "false",
                "operation_invalidated": String(operationInvalidated)
            ]
        )

        if shouldResumeCancellation,
           !profileRetirementRequested,
           !scenarioTimeoutRequested,
           let latestResumeData
        {
            harness.startResume(
                data: latestResumeData,
                context: context,
                scenarioRunID: scenarioRunID,
                scenarioID: scenarioID,
                initialURL: initialURL,
                requestEvidence: requestEvidence,
                parentOperationID: operationID
            )
            harness.coordinatorDidFinish(self, status: "cancelled-resuming")
        } else {
            let finalStatus = shouldResumeCancellation && latestResumeData == nil
                ? "blocked-resume-data-unavailable"
                : "cancelled"
            harness.coordinatorDidFinish(
                self,
                status: finalStatus
            )
        }
    }

    private func recordResumeData(_ data: Data, source: String) {
        record(
            kind: "resume-data-observed",
            profileID: profileID,
            profile: profile.rawValue,
            operationID: operationID,
            fields: [
                "available": String(!data.isEmpty),
                "length": String(data.count),
                "source": source,
                "resume_data_contents_recorded": "false"
            ]
        )
    }

    private func recordNoResumeData(source: String) {
        record(
            kind: "resume-data-observed",
            profileID: profileID,
            profile: profile.rawValue,
            operationID: operationID,
            fields: ["available": "false", "length": "0", "source": source, "resume_data_contents_recorded": "false"]
        )
    }

    private func finishFailedDownload(reason: String) {
        guard !terminal else { return }
        terminal = true
        progressObservation?.invalidate()
        if let destinationURL {
            try? FileManager.default.removeItem(at: destinationURL)
        }
        record(
            kind: "download-failed-final",
            profileID: profileID,
            profile: profile.rawValue,
            operationID: operationID,
            fields: ["reason": reason, "incomplete_receipt_published": "false"]
        )
        harness.coordinatorDidFinish(self, status: "failed-\(reason)")
    }

    private func failWithoutError(reason: String) {
        finishFailedDownload(reason: reason)
    }

    private func finishWithoutDownload(reason: String) {
        guard !terminal else { return }
        terminal = true
        record(
            kind: "download-not-started",
            profileID: profileID,
            profile: profile.rawValue,
            operationID: operationID,
            fields: ["reason": reason]
        )
        harness.coordinatorDidFinish(self, status: "blocked-\(reason)")
    }

    func recordServerTransferObservation(_ observation: SpikeFixtureTransferObservation) {
        record(
            kind: "download-server-transfer-observed",
            fields: [
                "server_timestamp": String(observation.timestamp),
                "server_path": observation.path,
                "bytes_sent": String(observation.bytesSent),
                "expected_bytes": String(observation.expectedBytes),
                "body_complete": String(observation.bodyComplete),
                "server_is_independent_fixture": "true"
            ]
        )
    }

    private func record(
        kind: String,
        profileID _: String? = nil,
        profile _: String? = nil,
        operationID _: String? = nil,
        fields: [String: String]
    ) {
        var attributedFields = fields
        for (key, value) in identityFields {
            attributedFields[key] = value
        }
        harness.record(
            kind: kind,
            profileID: profileID,
            profile: profile.rawValue,
            operationID: operationID,
            fields: attributedFields
        )
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func safeOrigin(_ url: URL) -> String {
        SpikeRequestEvidence.safeOrigin(url.absoluteString) ?? "non-http-origin"
    }

    private static func safeChallengeOrigin(_ challenge: URLAuthenticationChallenge) -> String {
        let scheme = challenge.protectionSpace.protocol?.lowercased() ?? "https"
        let host = challenge.protectionSpace.host.lowercased()
        let port = challenge.protectionSpace.port
        return "\(scheme)://\(host):\(port)"
    }

    private static func isFixtureHost(_ host: String) -> Bool {
        host == "127.0.0.1" || host == "localhost"
    }

    private static func shortHash(_ value: String) -> String {
        String(sha256(Data(value.utf8)).prefix(12))
    }
}
