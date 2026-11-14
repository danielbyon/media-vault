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
    static let passiveSceneCensusArgument = "--browser-download-passive-scene-census"
    static let activeDownloadHomeArgument = "--browser-download-active-download-home"
    static let operatorArrangementArgument = "--browser-download-operator-arrangement"
    static var passiveSceneCensusEnabled: Bool {
        ProcessInfo.processInfo.arguments.contains(passiveSceneCensusArgument)
    }

    static var operatorArrangementRequired: Bool {
        ProcessInfo.processInfo.arguments.contains(operatorArrangementArgument)
    }

    /// Enables real scene-phase forwarding and Immediate Auto-Lock for this qualification only.
    static var activeDownloadHomeEnabled: Bool {
        ProcessInfo.processInfo.arguments.contains(activeDownloadHomeArgument)
    }

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
private struct BrowserDownloadSlowKnownRun {
    let requestID: UUID
    let initialGeneration: UInt64
    let startedAt: TimeInterval
    var operationID: String?
    var operationGeneration: UInt64?
    var handoffObserved = false
    var serverPrefixProcessed = false
    var progressObserved = false
    var readinessRecorded = false
    var terminalAcknowledged = false
    var connectionClosureRecorded = false
    var failed = false
}

/// Every WindowGroup surface shares this process-owned real Root store and download lifetime.
/// Credential verification and session settings are deterministic only in active-download mode; WebKit and protection remain live.
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
    let pendingAllocation: BrowserDownloadQualificationPendingAllocation
    let securitySentinel: BrowserDownloadSecuritySentinel
    let simulatedProtectionReadback: Bool
    var status = "Fixture-seeded authentication; qualification controls below."
    var observationsJSON = "[]"
    var sceneCensusJSON = "{}"
    var sceneRequestJSON = "{}"
    private var slowKnownRun: BrowserDownloadSlowKnownRun?

    var slowKnownDownloadStarted: Bool {
        slowKnownRun != nil
    }

    /// Copy redacted observations only on explicit fixture input, avoiding a Root-layout feedback loop.
    func refreshObservations() {
        refreshSlowKnownReadiness()
        observationsJSON = evidence.observationsJSON
        inspectFixtureNavigation()
    }

    /// Publishes the redacted event copy when passive scene sampling is enabled.
    func refreshPassiveObservations() {
        guard BrowserDownloadProductionQualification.passiveSceneCensusEnabled else {
            return
        }

        refreshSlowKnownReadiness()
        observationsJSON = evidence.observationsJSON
        inspectFixtureNavigation()
    }

    /// Captures current UIKit window scenes separately from the latest coordinator callbacks.
    func refreshSceneCensus() {
        // Bracket the synchronous owner read so the test can place it relative to scene activation.
        let ownerSampleStartedAt = evidence.currentMonotonicSeconds
        let ownerSnapshot = owner.snapshot
        let ownerSampleCompletedAt = evidence.currentMonotonicSeconds
        let capturedMonotonicSeconds = evidence.currentMonotonicSeconds
        let connectedWindowScenes = UIApplication.shared
            .connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .map(sceneGeometry)
            .sorted { ($0["sessionID"] as? String ?? "") < ($1["sessionID"] as? String ?? "") }
        let distinctSessionIDs = Set(connectedWindowScenes.compactMap { $0["sessionID"] as? String }).count
        let census: [String: Any] = [
            "capturedMonotonicSeconds": capturedMonotonicSeconds,
            "distinctSessionIDs": distinctSessionIDs,
            "ownerGeneration": String(ownerSnapshot.generation),
            "ownerSnapshot": [
                "generation": String(ownerSnapshot.generation),
                "available": String(ownerSnapshot.isAvailable),
                "cleanupRetry": String(ownerSnapshot.cleanupNeedsRetry),
                "retained": String(owner.retainedCount),
                "active": String(owner.activeCount),
                "presentation": ownerSnapshot.presentation.map(\.requestID.uuidString) ?? "none",
                "operations": ownerSnapshot.records.map(\.id.rawValue.uuidString).joined(separator: ","),
                "sampleStartedMonotonicSeconds": ownerSampleStartedAt,
                "sampleCompletedMonotonicSeconds": ownerSampleCompletedAt,
            ],
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
        refreshPassiveObservations()
    }

    /// Samples actual native geometry without loading views, assigning frames or granting admission.
    private func sceneGeometry(_ scene: UIWindowScene) -> [String: Any] {
        let coverWindow = coordinator.coverWindow(in: scene)
        return [
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
                    "isCover": String(window === coverWindow),
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
        guard !scenes.isEmpty else {
            evidence.record("resizeGestureUnavailable", [:])
            return
        }

        for scene in scenes {
            let sceneSession = scene.session.persistentIdentifier
            let mounted = evidence.latestCoordinatorObservations.last {
                $0["sceneSession"] == sceneSession && $0["mounted"] == "true"
            }
            evidence.record("resizeGestureWillBegin", [
                "sceneSession": sceneSession,
                "registration": mounted?["registration"] ?? "unavailable",
                "generation": mounted?["generation"] ?? "unavailable",
            ])
        }
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
        let pendingAllocationState = BrowserDownloadQualificationPendingAllocation()
        pendingAllocation = pendingAllocationState
        let securitySentinelState = BrowserDownloadSecuritySentinel(record: recorder.record)
        securitySentinel = securitySentinelState
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
            if let recordKind = fields["recordKind"] {
                var inspection = fields
                inspection["recordKind"] = nil
                recorder.record(recordKind, inspection)
                return
            }

            var diagnostic = fields
            diagnostic["remainingFaultCount"] = String(removalFault.remainingFailures)
            recorder.record("scratchFailure", diagnostic)
        }
        scratch.qualificationExpectedPriorOperation = pendingAllocationState.priorOperationID
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
        let activeDownloadHome = BrowserDownloadProductionQualification.activeDownloadHomeEnabled
        if activeDownloadHome {
            vault.sessionSettings.autoLockTimeout = .immediately
        }
        vault.shell.selectedTab = .browser
        let defaults = UserDefaults(suiteName: "BrowserDownloadQualification-\(UUID().uuidString)") ?? UserDefaults()
        store = withDependencies {
            $0.defaultAppStorage = defaults
            $0.calculatorPersistence.load = { nil }
            $0.calculatorPersistence.save = { _ in }
            if activeDownloadHome {
                $0.vaultCredential = .testValue
                $0.vaultCredential.verify = { _ in .succeeded }
                $0.vaultSessionSettings.load = { .init(autoLockTimeout: .immediately) }
                $0.vaultSessionSettings.save = { _ in }
            }
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
                invalidateAuthorization: {
                    MainActor.assumeIsolated {
                        downloadOwner.invalidateAuthorization()
                        return downloadOwner.snapshot
                    }
                },
                execute: { await downloadOwner.execute($0) },
                events: { await downloadOwner.subscribe() },
            )
        } operation: {
            RootComposition.makeStore(vault: vault)
        }
        nativeCoordinator.qualificationObservation = { event, fields in recorder.record(event, fields) }
        webKitAdapter.downloadHandoffObserver = { [weak self, weak webKitAdapter] download, tabID in
            guard let self, let webKitAdapter else {
                return
            }

            recordNativeHandoff(download, tabID: tabID, adapter: webKitAdapter)
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
                refreshSlowKnownReadiness(snapshot: snapshot)
                for record in snapshot.records where record.isReady && !inspected.contains(record.id) {
                    inspected.insert(record.id)
                    inspect(record.id)
                }
                refreshPassiveObservations()
            }
        }
        do {
            let loopback = try BrowserDownloadLoopbackServer()
            server = loopback
            loopback.qualificationEvidenceDidChange = { [weak self] in
                self?.refreshSlowKnownReadiness()
            }
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
        refreshPassiveObservations()
    }

    /// Starts one bounded, real navigation through the mounted production WebView.
    func startSlowKnownDownload() {
        guard slowKnownRun == nil, let server,
              let url = try? server.url("slow-known")
        else {
            return
        }

        let requestID = UUID()
        slowKnownRun = BrowserDownloadSlowKnownRun(
            requestID: requestID,
            initialGeneration: owner.snapshot.generation,
            startedAt: ProcessInfo.processInfo.systemUptime,
        )
        let requestURL = url.appending(queryItems: [
            URLQueryItem(name: "qualificationRequest", value: requestID.uuidString),
        ])
        evidence.record("fixtureNavigationRequested", [
            "fixtureRoute": "slow-known",
            "fixtureRequest": requestID.uuidString,
        ])
        store.send(.vault(.shell(.browser(.navigate(requestURL)))))
        status = "Slow-known WKDownload started; waiting for the live readiness witness."
        refreshSlowKnownReadiness()
        refreshPassiveObservations()
    }

    func applyQualificationScenePhase(
        _ phase: String,
        applicationPhase: VaultApplicationScenePhase,
    ) {
        let generationBefore = owner.snapshot.generation
        store.send(.applicationPhaseChanged(applicationPhase))
        let snapshot = owner.snapshot
        guard let run = slowKnownRun else {
            return
        }

        evidence.record("qualificationScenePhaseChanged", [
            "fixtureRequest": run.requestID.uuidString,
            "operation": run.operationID ?? "none",
            "phase": phase,
            "applicationState": applicationStateLabel,
            "generationBefore": String(generationBefore),
            "generation": String(snapshot.generation),
            "authorizationRevokedSynchronously": String(
                phase == "background" && snapshot.generation != generationBefore,
            ),
            "activeWriterCount": String(owner.activeCount),
        ])
        observationsJSON = evidence.observationsJSON
    }

    private var applicationStateLabel: String {
        switch UIApplication.shared.applicationState {
        case .active:
            return "active"
        case .inactive:
            return "inactive"
        case .background:
            return "background"
        @unknown default:
            return "unknown"
        }
    }

    private var isVaultAuthenticated: Bool {
        if case .authenticated = store.vault.phase {
            return true
        }
        return false
    }

    private func recordNativeHandoff(
        _ download: WKDownload,
        tabID: BrowserTabID,
        adapter: BrowserWebKitAdapter,
    ) {
        let identity = download.originalRequest?.url.flatMap { server?.fixtureRequestIdentity(for: $0) }
        let sameOrigin = download.webView === adapter.webView(for: tabID)
        var fields = [
            "tab": String(describing: tabID),
            "sameOrigin": String(sameOrigin),
            "fixtureOrigin": String(identity != nil),
        ]
        if let identity {
            fields["fixtureRoute"] = identity.route
            fields["fixtureRequest"] = identity.requestID.uuidString
        }
        evidence.record("nativeDownloadHandoff", fields)

        guard var run = slowKnownRun, let identity,
              identity.route == "slow-known", identity.requestID == run.requestID,
              sameOrigin
        else {
            observationsJSON = evidence.observationsJSON
            return
        }

        run.handoffObserved = true
        slowKnownRun = run
        refreshSlowKnownReadiness()
    }

    private func refreshSlowKnownReadiness(snapshot: BrowserDownloadSnapshot? = nil) {
        guard var run = slowKnownRun, let server else {
            return
        }

        let current = snapshot ?? owner.snapshot
        let requestID = run.requestID.uuidString
        let serverEvidence = server.slowKnownEvidence(for: run.requestID)
        recordSlowKnownServerPrefix(&run, requestID: requestID, evidence: serverEvidence)
        associateSlowKnownOperation(&run, snapshot: current)

        if !run.readinessRecorded, let operationID = run.operationID {
            let record = current.records.first { $0.id.rawValue.uuidString == operationID }
            recordSlowKnownStateFailure(&run, requestID: requestID, snapshot: current, record: record)
            recordSlowKnownProgress(&run, requestID: requestID, snapshot: current, record: record)
            recordSlowKnownReadiness(
                &run,
                requestID: requestID,
                snapshot: current,
                record: record,
                serverEvidence: serverEvidence,
            )
        }

        if run.readinessRecorded, !run.terminalAcknowledged,
           owner.activeCount == 0, owner.retainedCount == 0,
           !owner.privacyCleanupPending, !current.cleanupNeedsRetry {
            evidence.record("slowKnownWriterTerminalAcknowledged", [
                "fixtureRequest": requestID,
                "operation": run.operationID ?? "unavailable",
                "connectionID": serverEvidence["connectionID"] ?? "unavailable",
                "generation": String(current.generation),
                "activeWriterCount": "0",
                "retainedRecordCount": "0",
                "cleanupPending": "false",
            ])
            run.terminalAcknowledged = true
        }

        if !run.connectionClosureRecorded, let operationID = run.operationID,
           serverEvidence["closed"] == "true",
           let closedAtUptime = serverEvidence["closedAtUptime"].flatMap(Double.init),
           let deadlineElapsed = serverEvidence["deadlineElapsedMilliseconds"] {
            evidence.record("slowKnownConnectionClosed", [
                "fixtureRequest": requestID,
                "operation": operationID,
                "connectionID": serverEvidence["connectionID"] ?? "unavailable",
                "connectionClosed": "true",
                "closeReason": serverEvidence["closeReason"] ?? "unavailable",
                "responseComplete": serverEvidence["responseComplete"] ?? "unavailable",
                "deadlineElapsedMilliseconds": deadlineElapsed,
                "connectionClosedMonotonicSeconds": evidence.monotonicSeconds(forUptime: closedAtUptime),
            ])
            run.connectionClosureRecorded = true
        }

        slowKnownRun = run
        observationsJSON = evidence.observationsJSON
    }

    private func recordSlowKnownServerPrefix(
        _ run: inout BrowserDownloadSlowKnownRun,
        requestID: String,
        evidence serverEvidence: [String: String],
    ) {
        let requestCount = Int(serverEvidence["requestCount"] ?? "0") ?? 0
        let connectionCount = Int(serverEvidence["connectionCount"] ?? "0") ?? 0
        if requestCount > 1 || connectionCount > 1 {
            recordSlowKnownFailure(
                requestCount > 1 ? "duplicateRequest" : "multipleConnections",
                requestID: requestID,
                run: &run,
            )
        }

        guard !run.serverPrefixProcessed,
              requestCount == 1, connectionCount == 1,
              serverEvidence["route"] == "slow-known",
              serverEvidence["requestParsed"] == "true",
              serverEvidence["sendStackState"] == "stackPrefixProcessed",
              let connectionID = serverEvidence["connectionID"],
              let expectedBytes = serverEvidence["expectedBytes"],
              let prefixBytes = serverEvidence["prefixBytes"]
        else {
            return
        }

        evidence.record("slowKnownServerPrefixProcessed", [
            "fixtureRequest": requestID,
            "route": "slow-known",
            "requestParsed": "true",
            "requestCount": "1",
            "connectionCount": "1",
            "connectionID": connectionID,
            "expectedBytes": expectedBytes,
            "prefixBytes": prefixBytes,
            "sendStackState": "stackPrefixProcessed",
            "responseComplete": serverEvidence["responseComplete"] ?? "unknown",
            "connectionClosed": serverEvidence["closed"] ?? "unknown",
        ])
        run.serverPrefixProcessed = true
    }

    private func associateSlowKnownOperation(
        _ run: inout BrowserDownloadSlowKnownRun,
        snapshot: BrowserDownloadSnapshot,
    ) {
        guard run.handoffObserved, run.operationID == nil,
              snapshot.generation == run.initialGeneration,
              snapshot.records.count == 1, owner.activeCount == 1,
              let record = snapshot.records.first
        else {
            return
        }

        run.operationID = record.id.rawValue.uuidString
        run.operationGeneration = snapshot.generation
    }

    private func recordSlowKnownStateFailure(
        _ run: inout BrowserDownloadSlowKnownRun,
        requestID: String,
        snapshot: BrowserDownloadSnapshot,
        record: BrowserDownloadRecord?,
    ) {
        if snapshot.generation != run.initialGeneration {
            recordSlowKnownFailure("generationChanged", requestID: requestID, run: &run)
        } else if snapshot.cleanupNeedsRetry || owner.privacyCleanupPending {
            recordSlowKnownFailure("cleanupPending", requestID: requestID, run: &run)
        } else if !snapshot.isAvailable || !isVaultAuthenticated {
            recordSlowKnownFailure("authorizationUnavailable", requestID: requestID, run: &run)
        } else if snapshot.presentation != nil {
            recordSlowKnownFailure("presentationAppeared", requestID: requestID, run: &run)
        } else if owner.activeCount != 1 || snapshot.records.count != 1 {
            recordSlowKnownFailure("writerNotSoleActiveRecord", requestID: requestID, run: &run)
        } else if record?.isReady == true {
            recordSlowKnownFailure("writerCompletedBeforeReadiness", requestID: requestID, run: &run)
        } else if record == nil {
            recordSlowKnownFailure("writerTerminatedBeforeReadiness", requestID: requestID, run: &run)
        }
    }

    private func recordSlowKnownProgress(
        _ run: inout BrowserDownloadSlowKnownRun,
        requestID: String,
        snapshot: BrowserDownloadSnapshot,
        record: BrowserDownloadRecord?,
    ) {
        guard !run.progressObserved, let operationID = run.operationID,
              let record, let expectedBytes = record.expectedBytes,
              record.receivedBytes > 0
        else {
            return
        }

        let authorizationValid = snapshot.isAvailable && isVaultAuthenticated
        evidence.record("slowKnownProgress", [
            "fixtureRequest": requestID,
            "operation": operationID,
            "generation": String(snapshot.generation),
            "operationGeneration": String(run.operationGeneration ?? snapshot.generation),
            "expectedBytes": String(expectedBytes),
            "receivedBytes": String(record.receivedBytes),
            "activeWriterCount": String(owner.activeCount),
            "recordCount": String(snapshot.records.count),
            "available": String(snapshot.isAvailable),
            "authorizationValid": String(authorizationValid),
            "isReady": String(record.isReady),
            "presentation": snapshot.presentation?.requestID.uuidString ?? "none",
            "privacyCleanupPending": String(owner.privacyCleanupPending),
        ])
        run.progressObserved = true
    }

    private func recordSlowKnownReadiness(
        _ run: inout BrowserDownloadSlowKnownRun,
        requestID: String,
        snapshot: BrowserDownloadSnapshot,
        record: BrowserDownloadRecord?,
        serverEvidence: [String: String],
    ) {
        guard !run.failed, run.handoffObserved, run.serverPrefixProcessed,
              run.progressObserved, let operationID = run.operationID,
              let record, let expectedBytes = record.expectedBytes,
              let serverExpectedBytes = serverEvidence["expectedBytes"],
              String(expectedBytes) == serverExpectedBytes,
              slowKnownOwnerIsActive(run, snapshot: snapshot, record: record, expectedBytes: expectedBytes),
              slowKnownServerIsPartial(serverEvidence)
        else {
            return
        }

        evidence.record("slowKnownReadiness", [
            "fixtureRequest": requestID,
            "operation": operationID,
            "operationGeneration": String(run.operationGeneration ?? snapshot.generation),
            "initialGeneration": String(run.initialGeneration),
            "generation": String(snapshot.generation),
            "expectedBytes": String(expectedBytes),
            "serverExpectedBytes": serverExpectedBytes,
            "receivedBytes": String(record.receivedBytes),
            "activeWriterCount": String(owner.activeCount),
            "recordCount": String(snapshot.records.count),
            "available": String(snapshot.isAvailable),
            "authorizationValid": "true",
            "isReady": "false",
            "presentation": "none",
            "privacyCleanupPending": "false",
            "connectionID": serverEvidence["connectionID"] ?? "unavailable",
            "responseComplete": "false",
            "connectionClosed": "false",
            "elapsedMilliseconds": String(Int((ProcessInfo.processInfo.systemUptime - run.startedAt) * 1_000)),
        ])
        run.readinessRecorded = true
    }

    private func slowKnownOwnerIsActive(
        _ run: BrowserDownloadSlowKnownRun,
        snapshot: BrowserDownloadSnapshot,
        record: BrowserDownloadRecord,
        expectedBytes: Int64,
    ) -> Bool {
        snapshot.generation == run.initialGeneration
            && run.operationGeneration == snapshot.generation
            && snapshot.records.count == 1 && owner.activeCount == 1
            && snapshot.isAvailable && isVaultAuthenticated
            && snapshot.presentation == nil && !snapshot.cleanupNeedsRetry
            && !owner.privacyCleanupPending
            && record.receivedBytes > 0 && record.receivedBytes < expectedBytes
            && !record.isReady
    }

    private func slowKnownServerIsPartial(_ serverEvidence: [String: String]) -> Bool {
        serverEvidence["requestCount"] == "1"
            && serverEvidence["connectionCount"] == "1"
            && serverEvidence["responseComplete"] == "false"
            && serverEvidence["closed"] == "false"
    }

    private func recordSlowKnownFailure(
        _ reason: String,
        requestID: String,
        run: inout BrowserDownloadSlowKnownRun,
    ) {
        guard !run.failed else {
            return
        }

        evidence.record("slowKnownReadinessFailure", [
            "fixtureRequest": requestID,
            "reason": reason,
        ])
        run.failed = true
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
            refreshSceneRequestEvidence()
            return
        }

        // Record the issued request before UIKit can deliver its asynchronous completion error.
        // A request is not proof: only the census shows which scenes UIKit actually registered.
        let request = UISceneSessionActivationRequest(role: .windowApplication)
        evidence.record("sceneRequested", [:])
        refreshSceneRequestEvidence()
        refreshPassiveObservations()
        UIApplication.shared.activateSceneSession(for: request) { [weak self] error in
            MainActor.assumeIsolated {
                self?.evidence.record("sceneRequestFailed", ["code": String((error as NSError).code)])
                self?.refreshSceneRequestEvidence()
                self?.refreshPassiveObservations()
            }
        }
        if BrowserDownloadProductionQualification.operatorArrangementRequired {
            status = "Scene requested. Arrange the original window fully in the background; keep this new window active."
        }
    }

    private func refreshSceneRequestEvidence() {
        sceneRequestJSON = evidence.latestSceneRequestJSON() ?? "{}"
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
            refreshPassiveObservations()
            return
        }

        let targetID = target.session.persistentIdentifier
        evidence.record("sceneReactivationRequested", [
            "requestedSession": targetID,
            "priorActivation": activationLabel(target.activationState),
            "invokingSession": invoking.session.persistentIdentifier,
        ])
        refreshPassiveObservations()
        let request = UISceneSessionActivationRequest(session: target.session, userActivity: nil, options: nil)
        UIApplication.shared.activateSceneSession(for: request) { [weak self] error in
            MainActor.assumeIsolated {
                self?.evidence.record("sceneReactivationFailed", [
                    "requestedSession": targetID,
                    "code": String((error as NSError).code),
                ])
                self?.refreshPassiveObservations()
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
            pendingAllocation.record(operation: id, directory: url.deletingLastPathComponent())
        } catch {
            evidence.record("completedFileInspectionFailed", ["operation": id.rawValue.uuidString])
        }
    }

    /// Pre-termination proof that this process's own completed allocation still exists. Reports
    /// the opaque identifier plus existence booleans only; a missing identifier or a failed
    /// verification records a negative check instead of fabricating evidence.
    func checkPendingAllocation() {
        let id = pendingAllocation.latestOperationID
        let directory = pendingAllocation.latestDirectory
        guard let id, let directory else {
            evidence.record("pendingAllocationPreTerminationCheck", [
                "operation": "unavailable",
                "present": "false",
                "verified": "false",
            ])
            return
        }

        let verified = (try? owner.qualificationCompletedFile(id)) != nil
        let present = (try? FileManager.default.attributesOfItem(atPath: directory.path)) != nil
        evidence.record("pendingAllocationPreTerminationCheck", [
            "operation": id.rawValue.uuidString,
            "present": String(present),
            "verified": String(verified),
        ])
    }

    /// Prepares the protected-data sentinel, arms the lock observers and the bounded background
    /// assertion, then leaves the device lock itself to the operator.
    ///
    /// The sentinel accepts one qualification cycle per process. A preparation request that
    /// arrives after that cycle has begun is refused, and the refusal is surfaced here as a status
    /// message that names the required action, relaunching the host, instead of silently arming
    /// nothing.
    func prepareSecuritySentinel() {
        switch securitySentinel.prepare() {
        case .accepted:
            status = "Sentinel armed: lock the device, wait about 20 seconds, then unlock and return to this app."
        case .preparationFailed:
            status = "Sentinel preparation failed: no qualification cycle is armed; relaunch the host before retrying."
        case .refusedCycleAlreadyUsed:
            status = "Sentinel preparation refused: this process already used its one qualification "
                + "cycle; relaunch the host before preparing again."
        }
    }
}

@MainActor
private struct BrowserDownloadProductionQualificationRoot: View {
    let process: BrowserDownloadProductionQualificationProcess
    @Environment(\.scenePhase)
    private var scenePhase
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
                invalidateAuthorization: {
                    MainActor.assumeIsolated {
                        process.owner.invalidateAuthorization()
                        return process.owner.snapshot
                    }
                },
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
                if BrowserDownloadProductionQualification.operatorArrangementRequired {
                    Text(
                        "Operator: minimize the original window to the Stage Manager shelf without closing it. "
                            + "Keep this new window active; the test continues automatically within 120 seconds.",
                    )
                    .font(.caption)
                    .accessibilityIdentifier("downloadQualificationOperatorArrangementInstruction")
                }
                Text(process.protectionLabel)
                    .font(.caption)
                    .accessibilityIdentifier("downloadQualificationProtectionQualificationMode")
                ScrollView(.horizontal) {
                    HStack {
                        Button("Open fixture page") { process.navigate("first") }
                            .accessibilityIdentifier("downloadQualificationOpenFixturePage")
                        Button("Download attachment PDF") { process.navigate("attachment") }
                            .accessibilityIdentifier("downloadQualificationDownloadAttachment")
                        Button("Start slow-known download") { process.startSlowKnownDownload() }
                            .accessibilityIdentifier("downloadQualificationStartSlowKnown")
                            .disabled(process.slowKnownDownloadStarted)
                        Button("Remove authentication") { process.loseAuthentication() }
                            .accessibilityIdentifier("downloadQualificationRemoveAuthentication")
                        Button("Arm one removal failure") {
                            process.fault.arm()
                            process.evidence.record("removalFaultArmed", ["remaining": "1"])
                        }
                        .accessibilityIdentifier("downloadQualificationArmRemovalFailure")
                        Button("Check pending allocation") { process.checkPendingAllocation() }
                            .accessibilityIdentifier("downloadQualificationCheckPendingAllocation")
                        Button("Prepare security sentinel") { process.prepareSecuritySentinel() }
                            .accessibilityIdentifier("downloadQualificationPrepareSecuritySentinel")
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
                    Text("Sentinel: " + process.securitySentinel.stage)
                        .font(.caption2)
                        .accessibilityIdentifier("downloadQualificationSecuritySentinelStatus")
                        .accessibilityValue(process.securitySentinel.stageSummary)
                }
                Text("Qualification observations")
                    .font(.caption2)
                    .accessibilityIdentifier("downloadQualificationObservations")
                    .accessibilityValue(process.observationsJSON)
                Text("Connected window-scene census")
                    .font(.caption2)
                    .accessibilityIdentifier("downloadQualificationSceneCensus")
                    .accessibilityValue(process.sceneCensusJSON)
                Text("Latest scene-request event")
                    .font(.caption2)
                    .accessibilityIdentifier("downloadQualificationSceneRequest")
                    .accessibilityValue(process.sceneRequestJSON)
            }
            .padding(8)
            .background(.regularMaterial)
        }
        .task { await process.start() }
        .onAppear { process.refreshSceneCensus() }
        .onChange(of: scenePhase, initial: true) { _, newPhase in
            let phase: String
            let applicationPhase: VaultApplicationScenePhase
            switch newPhase {
            case .active:
                phase = "active"
                applicationPhase = .active
            case .inactive:
                phase = "inactive"
                applicationPhase = .inactive
            case .background:
                phase = "background"
                applicationPhase = .background
            @unknown default:
                phase = "unknown"
                applicationPhase = .unknown
            }
            if BrowserDownloadProductionQualification.activeDownloadHomeEnabled {
                process.applyQualificationScenePhase(phase, applicationPhase: applicationPhase)
            }

            guard BrowserDownloadProductionQualification.passiveSceneCensusEnabled else {
                return
            }

            Task { @MainActor in
                await Task.yield()
                process.refreshSceneCensus()
            }
        }
        // Recheck the fixture document after WebKit finishes loading the selected tab.
        .onChange(of: process.store.vault.shell.browser.selectedTab?.metadata.isLoading) { _, isLoading in
            guard isLoading == false else {
                return
            }

            process.refreshPassiveObservations()
        }
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

/// Opaque completed-allocation correlation for the physical cold-relaunch qualification. Only a
/// UUID is persisted, in this host's own defaults suite, so a relaunched process can recognize the
/// previous process's allocation without ever storing a URL, filename, or content.
@Observable
@MainActor
private final class BrowserDownloadQualificationPendingAllocation {
    private static let suiteName = "BrowserDownloadQualificationPendingAllocation"
    private static let key = "pendingOperation"

    /// Opaque operation persisted by a previous process; read before any new admission.
    let priorOperationID: UUID?
    /// Identifier completed by this process; the matching directory stays in memory only.
    private(set) var latestOperationID: BrowserDownloadID?
    private(set) var latestDirectory: URL?

    private let defaults = UserDefaults(suiteName: BrowserDownloadQualificationPendingAllocation.suiteName)

    init() {
        priorOperationID = defaults?
            .string(forKey: BrowserDownloadQualificationPendingAllocation.key)
            .flatMap(UUID.init(uuidString:))
    }

    /// Persists the opaque identifier only, so abrupt termination cannot lose the correlation.
    func record(operation id: BrowserDownloadID, directory: URL) {
        latestOperationID = id
        latestDirectory = directory
        defaults?.set(id.rawValue.uuidString, forKey: BrowserDownloadQualificationPendingAllocation.key)
        defaults?.synchronize()
    }
}

/// Redacted append-only evidence; no request URLs, credentials, filenames or downloaded content.
/// Export Documents/browser-download-production-events.jsonl from the standalone app's data container.
@MainActor
private final class BrowserDownloadProductionEvidence {
    private let origin = ProcessInfo.processInfo.systemUptime

    /// Current timestamp on the same monotonic clock used by qualification events.
    var currentMonotonicSeconds: String {
        monotonicSeconds(forUptime: ProcessInfo.processInfo.systemUptime)
    }

    /// Converts a server uptime sample onto the event recorder's monotonic timeline.
    func monotonicSeconds(forUptime uptime: TimeInterval) -> String {
        String(uptime - origin)
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

    /// Returns the latest request outcome, allowing physical qualification to read it without
    /// tapping a control that could change which app window is foreground.
    func latestSceneRequestJSON() -> String? {
        let requestEvents: Set = ["sceneRequested", "sceneRequestFailed", "sceneRequestUnsupported"]
        guard let observation = observations.last(where: { requestEvents.contains($0["event"] ?? "") }),
              let data = try? JSONSerialization.data(withJSONObject: observation, options: [.sortedKeys])
        else {
            return nil
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
