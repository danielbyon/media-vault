//
//  BrowserDownloadProductionQualification.swift
//  MediaVault
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import SwiftUI
#if DEBUG && BROWSER_DOWNLOAD_STANDALONE_QUALIFICATION
import CalculatorFeature
import ComposableArchitecture
import CryptoKit
import Dependencies
import Observation
import Sharing
import UIKit
import UIUtilities
import VaultFeature
import WebKit
@testable import AppFeature
@testable import BrowserFeature
#endif

/// Opt-in production-path fixture, compiled only into the separate Debug qualification app.
@MainActor
enum BrowserDownloadProductionQualification {
    static let argument = "--browser-download-production-qualification"
    #if DEBUG && BROWSER_DOWNLOAD_STANDALONE_QUALIFICATION && targetEnvironment(simulator)
    /// Explicit simulator fixture opt-in. Physical builds never compile the injected verifier.
    static let simulatedProtectionArgument = "--browser-download-simulated-protection-readback"
    #endif

    @ViewBuilder
    static var root: some View {
        #if DEBUG && BROWSER_DOWNLOAD_STANDALONE_QUALIFICATION
        BrowserDownloadProductionQualificationRoot(process: .shared)
        #else
        Color.clear
        #endif
    }
}

#if DEBUG && BROWSER_DOWNLOAD_STANDALONE_QUALIFICATION
/// Every WindowGroup surface shares this process-owned real Root store and download lifetime.
/// Only unrelated persistence and credentials are deterministic; WebKit and protection remain live.
@Observable
@MainActor
private final class BrowserDownloadProductionQualificationProcess {
    static let shared = BrowserDownloadProductionQualificationProcess()
    let store: StoreOf<RootFeature>
    let owner: BrowserDownloadOwner
    let adapter: BrowserWebKitAdapter
    let coordinator: BrowserDownloadNativeCoordinator
    let evidence: BrowserDownloadProductionEvidence
    let fault: BrowserDownloadQualificationRemovalFault
    let simulatedProtectionReadback: Bool
    var status = "Fixture-seeded authentication; qualification controls below."
    var observationsJSON = "[]"
    var sceneCensusJSON = "{}"

    /// Copy redacted observations only on explicit fixture input, avoiding a Root-layout feedback loop.
    func refreshObservations() {
        observationsJSON = evidence.observationsJSON
        inspectFixtureNavigation()
    }

    /// Captures current UIKit window scenes separately from the latest coordinator callbacks.
    func refreshSceneCensus() {
        let connectedWindowScenes = UIApplication.shared
            .connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .map(sceneGeometry)
            .sorted { ($0["sessionID"] as? String ?? "") < ($1["sessionID"] as? String ?? "") }
        let distinctSessionIDs = Set(connectedWindowScenes.compactMap { $0["sessionID"] as? String }).count
        let census: [String: Any] = [
            "capturedMonotonicSeconds": evidence.currentMonotonicSeconds,
            "distinctSessionIDs": distinctSessionIDs,
            "ownerGeneration": String(owner.snapshot.generation),
            "rootLayoutObservations": evidence.rootLayoutObservations,
            "connectedWindowScenes": connectedWindowScenes,
            "latestCoordinatorObservations": evidence.latestCoordinatorObservations,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: census, options: [.sortedKeys]) else {
            sceneCensusJSON = "{}"
            return
        }

        sceneCensusJSON = String(decoding: data, as: UTF8.self)
        evidence.record("sceneCensusCaptured", ["census": sceneCensusJSON])
    }

    /// Samples actual native geometry without loading views, assigning frames or granting admission.
    private func sceneGeometry(_ scene: UIWindowScene) -> [String: Any] {
        [
            "sessionID": scene.session.persistentIdentifier,
            "activation": activationLabel(scene.activationState),
            "activationRawValue": String(scene.activationState.rawValue),
            "bounds": String(describing: scene.effectiveGeometry.coordinateSpace.bounds),
            "screenBounds": String(describing: scene.screen.bounds),
            "screenScale": String(describing: scene.screen.scale),
            "minimumSize": scene.sizeRestrictions.map { String(describing: $0.minimumSize) } ?? "unavailable",
            "maximumSize": scene.sizeRestrictions.map { String(describing: $0.maximumSize) } ?? "unavailable",
            "windows": scene.windows.map { window in
                [
                    "frame": String(describing: window.frame),
                    "bounds": String(describing: window.bounds),
                    "hidden": String(window.isHidden),
                    "alpha": String(describing: window.alpha),
                    "key": String(window.isKeyWindow),
                    "rootViewBounds": window.rootViewController?
                        .viewIfLoaded
                        .map { String(describing: $0.bounds) } ?? "unloaded",
                ]
            },
        ]
    }

    /// Marks the fixture's pre-gesture boundary on the same clock as real coordinator callbacks.
    func markResizeGesture() {
        let scenes = UIApplication.shared
            .connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .filter { $0.activationState == .foregroundActive }
        guard scenes.count == 1, let active = scenes.first else {
            evidence.record("resizeGestureUnavailable", [:])
            return
        }

        evidence.record("resizeGestureWillBegin", [
            "sceneSession": active.session.persistentIdentifier,
            "generation": String(owner.snapshot.generation),
        ])
    }

    /// Stable evidence labels come from actual UIKit enum cases, not its debug description.
    private func activationLabel(_ state: UIScene.ActivationState) -> String {
        switch state {
        case .foregroundActive:
            "foregroundActive"
        case .foregroundInactive:
            "foregroundInactive"
        case .background:
            "background"
        case .unattached:
            "unattached"
        @unknown default:
            "unknown"
        }
    }

    var protectionLabel: String {
        simulatedProtectionReadback
            ? "Simulated protection readback — native .complete UNVERIFIED"
            : "Real native .complete verification required (fail closed)"
    }

    private var pendingFixtureNavigation: (id: String, url: URL)?
    private var navigationInspectionIsPending = false
    private var server: BrowserDownloadLoopbackServer?
    private var started = false
    private var observation: Task<Void, Never>?
    private var inspected: Set<BrowserDownloadID> = []

    private init() {
        let recorder = BrowserDownloadProductionEvidence()
        evidence = recorder
        let removalFault = BrowserDownloadQualificationRemovalFault()
        fault = removalFault
        #if targetEnvironment(simulator)
        let simulateReadback = ProcessInfo.processInfo.arguments.contains(
            BrowserDownloadProductionQualification.simulatedProtectionArgument,
        )
        #else
        let simulateReadback = false
        #endif
        simulatedProtectionReadback = simulateReadback
        let remove: @MainActor (URL) throws -> Void = { url in
            guard !removalFault.consumeFailure() else {
                recorder.record(
                    "cleanupInjectedFailure",
                    ["operation": UUID(uuidString: url.lastPathComponent)?.uuidString ?? "unidentifiedAllocation"],
                )
                throw CocoaError(.fileWriteNoPermission)
            }

            try FileManager.default.removeItem(at: url)
            do {
                _ = try FileManager.default.attributesOfItem(atPath: url.path)
                recorder.record(
                    "cleanupRemoval",
                    [
                        "operation": UUID(uuidString: url.lastPathComponent)?.uuidString ?? "unidentifiedAllocation",
                        "absence": "false",
                    ],
                )
            } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
                recorder.record(
                    "cleanupRemoval",
                    [
                        "operation": UUID(uuidString: url.lastPathComponent)?.uuidString ?? "unidentifiedAllocation",
                        "absence": "true",
                    ],
                )
            } catch {
                recorder.record(
                    "cleanupRemoval",
                    [
                        "operation": UUID(uuidString: url.lastPathComponent)?.uuidString ?? "unidentifiedAllocation",
                        "absence": "unconfirmed",
                    ],
                )
            }
        }
        let scratch: BrowserDownloadScratchStore
        #if targetEnvironment(simulator)
        if simulateReadback {
            // Only native protection readback is unsupported in this simulator fixture. All
            // ownership, regular-file, size, backup and terminal-writer checks stay unchanged.
            scratch = BrowserDownloadScratchStore(verifyProtection: { _ in }, remove: remove)
        } else {
            scratch = BrowserDownloadScratchStore(remove: remove)
        }
        #else
        scratch = BrowserDownloadScratchStore(remove: remove)
        #endif
        scratch.qualificationDiagnostic = { fields in
            var diagnostic = fields
            diagnostic["remainingFaultCount"] = String(removalFault.remainingFailures)
            recorder.record("scratchFailure", diagnostic)
        }
        let downloadOwner = BrowserDownloadOwner(store: scratch)
        owner = downloadOwner
        let webKitAdapter = BrowserWebKitAdapter(requiresProfileConfiguration: true, downloadOwner: downloadOwner)
        adapter = webKitAdapter
        BrowserTabTransitionDiagnostics.qualificationObserver = { event, fields in
            var diagnostic = fields
            diagnostic["downloadPrivacyGeneration"] = String(downloadOwner.snapshot.generation)
            diagnostic["commandAdapterIdentity"] = String(describing: ObjectIdentifier(webKitAdapter))
            recorder.record(event, diagnostic)
        }
        let nativeCoordinator = BrowserDownloadNativeCoordinator(owner: downloadOwner)
        coordinator = nativeCoordinator
        var vault = VaultFeature.State(phase: .authenticated, configuredKind: .pin)
        vault.shell.selectedTab = .browser
        let defaults = UserDefaults(suiteName: "BrowserDownloadQualification-\(UUID().uuidString)") ?? UserDefaults()
        store = withDependencies {
            $0.defaultAppStorage = defaults
            $0.calculatorPersistence.load = { nil }
            $0.calculatorPersistence.save = { _ in }
            $0.vaultCredential = .testValue
            $0.browserSettings.load = {
                var settings = BrowserSettings()
                settings.preserveOpenTabs = false
                return settings
            }
            $0.browserSettings.save = { _ in }
            $0.browserSettings.reset = {}
            $0.browserSettings.reserveRevision = { $0 }
            $0.browserSettings.resetRevisioned = { _ in }
            $0.browserSettings.saveRevisioned = { _, _ in }
            $0.browserLibrary = .testValue
            $0.browserOpenTabsSession.load = { .missing }
            $0.browserOpenTabsSession.save = { _, _ in }
            $0.browserOpenTabsSession.purge = { _ in }
            $0.browserOpenTabsSession.advance = { _ in }
            $0.browserOpenTabsSession.reserveRevision = { $0 }
            $0.browserClipboard.readHTTPURL = { nil }
            $0.browserWebKit = BrowserWebKitClient(
                execute: { await webKitAdapter.execute($0) },
                events: { await webKitAdapter.makeEventStream() },
            )
            $0.browserDownloads = BrowserDownloadClient(
                execute: { await downloadOwner.execute($0) },
                events: { await downloadOwner.subscribe() },
            )
        } operation: {
            RootComposition.makeStore(vault: vault)
        }
        nativeCoordinator.qualificationObservation = { event, fields in recorder.record(event, fields) }
        webKitAdapter.downloadHandoffObserver = { [weak webKitAdapter] download, tabID in
            recorder.record("nativeDownloadHandoff", [
                "tab": String(describing: tabID),
                "sameOrigin": String(download.webView === webKitAdapter?.webView(for: tabID)),
            ])
        }
        recorder.record("fixtureStarted", [
            "authentication": "seeded",
            "protectionMode": simulateReadback ? "simulatedReadback" : "nativeCompleteRequired",
            "nativeProtection": "UNVERIFIED",
        ])
    }

    func start() async {
        guard !started else {
            return
        }

        started = true
        observation = Task { @MainActor [weak self] in
            guard let self else {
                return
            }

            for await snapshot in owner.subscribe() {
                evidence.record("ownerSnapshot", [
                    "revision": String(snapshot.revision),
                    "generation": String(snapshot.generation),
                    "available": String(snapshot.isAvailable),
                    "cleanupRetry": String(snapshot.cleanupNeedsRetry),
                    "retained": String(owner.retainedCount),
                    "active": String(owner.activeCount),
                    "presentation": snapshot.presentation.map(\.requestID.uuidString) ?? "none",
                    "operations": snapshot.records.map(\.id.rawValue.uuidString).joined(separator: ","),
                ])
                for record in snapshot.records where record.isReady && !inspected.contains(record.id) {
                    inspected.insert(record.id)
                    inspect(record.id)
                }
            }
        }
        do {
            let loopback = try BrowserDownloadLoopbackServer()
            server = loopback
            try await loopback.start()
            status = "Loopback ready. Open fixture page, then download attachment PDF."
            evidence.record("loopbackReady", [:])
        } catch {
            status = "Loopback failed; qualification unavailable."
            evidence.record("loopbackFailure", [:])
        }
    }

    func navigate(_ route: String) {
        guard let server, let baseURL = try? server.url(route) else {
            return
        }

        let requestID = UUID().uuidString
        let url = route == "first"
            ? baseURL.appending(queryItems: [URLQueryItem(name: "qualificationRequest", value: requestID)])
            : baseURL
        if route == "first" {
            pendingFixtureNavigation = (requestID, url)
        }
        store.send(.vault(.shell(.browser(.navigate(url)))))
        evidence.record("fixtureNavigationRequested", ["fixtureRoute": route, "fixtureRequest": requestID])
    }

    /// Checks the selected production tab and its actual document, without replaying a request.
    private func inspectFixtureNavigation() {
        guard !navigationInspectionIsPending, let pending = pendingFixtureNavigation,
              let tab = store.vault.shell.browser.selectedTab,
              tab.metadata.committedURL == pending.url,
              let view = adapter.webView(for: tab.id)
        else {
            return
        }

        navigationInspectionIsPending = true
        view.evaluateJavaScript("[document.readyState, location.href]") { [weak self, weak view] result, _ in
            guard let self else {
                return
            }

            navigationInspectionIsPending = false
            guard pendingFixtureNavigation?.id == pending.id,
                  store.vault.shell.browser.selectedTab?.id == tab.id,
                  store.vault.shell.browser.selectedTab?.metadata.committedURL == pending.url,
                  let view, adapter.webView(for: tab.id) === view,
                  let document = result as? [String], document.count == 2,
                  document[0] == "complete", document[1] == pending.url.absoluteString
            else {
                return
            }

            evidence.record("fixtureNavigationCommitted", [
                "fixtureRequest": pending.id,
                "metadataMatches": "true",
                "documentMatches": "true",
                "readyState": document[0],
                "webViewIdentity": String(describing: ObjectIdentifier(view)),
                "webViewAttached": String(view.window != nil),
            ])
            pendingFixtureNavigation = nil
            observationsJSON = evidence.observationsJSON
        }
    }

    func loseAuthentication() {
        // Fixture delivery goes through the production reducer, not direct state mutation.
        store.send(.vault(.configurationLoaded(.success(nil))))
        evidence.record("fixtureAuthenticationLost", ["phase": String(describing: store.vault.phase)])
        status = "Authentication removed through Root. Relaunch for a new seeded session."
    }

    func requestSecondScene() {
        guard UIApplication.shared.supportsMultipleScenes else {
            status = "Multiple application scenes are unsupported here."
            evidence.record("sceneRequestUnsupported", [:])
            return
        }

        // A request is not proof: log only scenes actually registered by the production bridge.
        let request = UISceneSessionActivationRequest(role: .windowApplication)
        UIApplication.shared.activateSceneSession(for: request) { [weak self] error in
            MainActor.assumeIsolated {
                self?.evidence.record("sceneRequestFailed", ["code": String((error as NSError).code)])
            }
        }
        evidence.record("sceneRequested", [:])
    }

    /// Requests the one known background qualification session; UIKit callbacks prove the result.
    func reactivateBackgroundScene() {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let active = scenes.filter { $0.activationState == .foregroundActive }
        let registered = Set(evidence.latestCoordinatorObservations.compactMap { $0["sceneSession"] })
        let background = scenes.filter {
            $0.activationState == .background && $0.session.role == .windowApplication
                && registered.contains($0.session.persistentIdentifier)
        }
        guard active.count == 1, background.count == 1,
              let invoking = active.first, let target = background.first,
              invoking.session.persistentIdentifier != target.session.persistentIdentifier
        else {
            evidence.record("sceneReactivationUnavailable", ["backgroundCandidates": String(background.count)])
            return
        }

        let targetID = target.session.persistentIdentifier
        evidence.record("sceneReactivationRequested", [
            "requestedSession": targetID,
            "priorActivation": activationLabel(target.activationState),
            "invokingSession": invoking.session.persistentIdentifier,
        ])
        let request = UISceneSessionActivationRequest(session: target.session, userActivity: nil, options: nil)
        UIApplication.shared.activateSceneSession(for: request) { [weak self] error in
            MainActor.assumeIsolated {
                self?.evidence.record("sceneReactivationFailed", [
                    "requestedSession": targetID,
                    "code": String((error as NSError).code),
                ])
            }
        }
    }

    private func inspect(_ id: BrowserDownloadID) {
        do {
            let url = try owner.qualificationCompletedFile(id)
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            let values = try url.resourceValues(forKeys: [.isExcludedFromBackupKey])
            let bytes = try Data(contentsOf: url)
            let actualProtection = attributes[.protectionKey] as? FileProtectionType
            evidence.record("completedFileProof", [
                "operation": id.rawValue.uuidString,
                "allocation": url.deletingLastPathComponent().lastPathComponent,
                "generation": String(owner.snapshot.generation),
                "bytes": String(bytes.count),
                "sha256": SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined(),
                "completeObserved": String(actualProtection == .complete),
                "protectionAttribute": actualProtection?.rawValue ?? "absent",
                "protectionMode": simulatedProtectionReadback ? "simulatedReadback" : "nativeCompleteRequired",
                "nativeProtection": simulatedProtectionReadback
                    ? "UNVERIFIED"
                    : (actualProtection == .complete ? "verified" : "notConfirmed"),
                "backupExcluded": String(values.isExcludedFromBackup == true),
                "fixtureBytesMatch": String(bytes == BrowserDownloadLoopbackServer.fixturePDF),
            ])
        } catch {
            evidence.record("completedFileInspectionFailed", ["operation": id.rawValue.uuidString])
        }
    }
}

@MainActor
private struct BrowserDownloadProductionQualificationRoot: View {
    let process: BrowserDownloadProductionQualificationProcess
    @State
    private var browserHostingContext: BrowserQualificationWebKitHostingContext

    init(process: BrowserDownloadProductionQualificationProcess) {
        self.process = process
        _browserHostingContext = State(initialValue: BrowserQualificationWebKitHostingContext(
            adapter: process.adapter,
        ))
    }

    var body: some View {
        RootView(
            store: process.store,
            downloads: BrowserDownloadClient(
                execute: { await process.owner.execute($0) },
                events: { await process.owner.subscribe() },
            ),
            privacyGeneration: { process.owner.snapshot.generation },
            downloadHost: { $0.using(coordinator: process.coordinator) },
        )
        .environment(\.qualificationBrowserHostingContext, browserHostingContext)
        .safeAreaInset(edge: .top) {
            VStack(alignment: .leading) {
                Text("Production qualification — fixture-seeded auth").font(.caption)
                Text(process.status).font(.caption)
                Text(process.protectionLabel)
                    .font(.caption)
                    .accessibilityIdentifier("downloadQualificationProtectionQualificationMode")
                ScrollView(.horizontal) {
                    HStack {
                        Button("Open fixture page") { process.navigate("first") }
                            .accessibilityIdentifier("downloadQualificationOpenFixturePage")
                        Button("Download attachment PDF") { process.navigate("attachment") }
                            .accessibilityIdentifier("downloadQualificationDownloadAttachment")
                        Button("Remove authentication") { process.loseAuthentication() }
                            .accessibilityIdentifier("downloadQualificationRemoveAuthentication")
                        Button("Arm one removal failure") {
                            process.fault.arm()
                            process.evidence.record("removalFaultArmed", ["remaining": "1"])
                        }
                        .accessibilityIdentifier("downloadQualificationArmRemovalFailure")
                    }
                }
                .accessibilityIdentifier("downloadQualificationControls")
                // Scene and observation controls remain reachable in narrow system-managed windows.
                VStack(alignment: .leading) {
                    Button("Request second scene") { process.requestSecondScene() }
                        .accessibilityIdentifier("downloadQualificationRequestSecondScene")
                    Button("Reactivate background qualification scene") { process.reactivateBackgroundScene() }
                        .accessibilityIdentifier("downloadQualificationReactivateBackgroundScene")
                    Button("Mark system resize gesture") { process.markResizeGesture() }
                        .accessibilityIdentifier("downloadQualificationMarkResizeGesture")
                    Button("Refresh scene census") { process.refreshSceneCensus() }
                        .accessibilityIdentifier("downloadQualificationRefreshSceneCensus")
                    Button("Refresh observations") { process.refreshObservations() }
                        .accessibilityIdentifier("downloadQualificationRefreshObservations")
                }
                Text("Qualification observations")
                    .font(.caption2)
                    .accessibilityIdentifier("downloadQualificationObservations")
                    .accessibilityValue(process.observationsJSON)
                Text("Connected window-scene census")
                    .font(.caption2)
                    .accessibilityIdentifier("downloadQualificationSceneCensus")
                    .accessibilityValue(process.sceneCensusJSON)
            }
            .padding(8)
            .background(.regularMaterial)
        }
        .task { await process.start() }
        .onAppear { process.refreshSceneCensus() }
    }
}

/// Removal-only injection; preparation and completed-file protection always remain native.
@Observable
@MainActor
private final class BrowserDownloadQualificationRemovalFault {
    private(set) var remainingFailures = 0

    func arm() {
        remainingFailures = 1
    }

    /// A consumed fault cannot strand a covered surface behind an inaccessible fixture toggle.
    func consumeFailure() -> Bool {
        guard remainingFailures > 0 else {
            return false
        }

        remainingFailures -= 1
        return true
    }
}

/// Redacted append-only evidence; no request URLs, credentials, filenames or downloaded content.
/// Export Documents/browser-download-production-events.jsonl from the standalone app's data container.
@MainActor
private final class BrowserDownloadProductionEvidence {
    private let origin = ProcessInfo.processInfo.systemUptime

    /// Current timestamp on the same monotonic clock used by qualification events.
    var currentMonotonicSeconds: String {
        String(ProcessInfo.processInfo.systemUptime - origin)
    }

    private let runID = UUID().uuidString
    private var observations: [[String: String]] = []
    private var latestByRegistration: [String: [String: String]] = [:]

    /// Latest callback per mounted Root registration; unregister events remove stale entries.
    var latestCoordinatorObservations: [[String: String]] {
        latestByRegistration.keys.sorted().compactMap { latestByRegistration[$0] }
    }

    /// Actual layout-confirmation callbacks, kept distinct from a later geometry census capture.
    var rootLayoutObservations: [[String: String]] {
        observations.filter { $0["event"] == "rootLayoutConfirmed" }
    }

    /// Bounded XCUI copy of the same real observations written to the complete JSONL document.
    var observationsJSON: String {
        guard let data = try? JSONSerialization.data(withJSONObject: observations, options: [.sortedKeys]) else {
            return "[]"
        }

        return String(decoding: data, as: UTF8.self)
    }

    private let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("browser-download-production-events.jsonl")

    func record(_ event: String, _ fields: [String: String]) {
        var object = fields
        object["event"] = event
        object["runID"] = runID
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        object["wallTime"] = formatter.string(from: Date())
        object["monotonicSeconds"] = currentMonotonicSeconds
        if let registration = fields["registration"] {
            if event == "rootUnregistered" {
                latestByRegistration.removeValue(forKey: registration)
            } else {
                latestByRegistration[registration] = object
            }
        }
        observations.append(object)
        if observations.count > 256 {
            observations.removeFirst(observations.count - 256)
        }
        guard var data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else {
            return
        }

        data.append(0x0a)
        do {
            if !FileManager.default.fileExists(atPath: url.path) {
                try data.write(to: url, options: [.atomic])
            } else {
                let handle = try FileHandle(forWritingTo: url)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
            }
        } catch {
            // Evidence failure cannot authorize downloads or change their privacy lifetime.
        }
    }
}
#endif
