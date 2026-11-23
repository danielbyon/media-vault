//
//  BrowserDownloadProductionQualification.swift
//  MediaVault
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Combine
import Foundation
import SwiftUI
#if DEBUG && BROWSER_DOWNLOAD_STANDALONE_QUALIFICATION
import CalculatorFeature
import ComposableArchitecture
import CryptoKit
import Dependencies
import MediaLibrary
import ObjectiveC
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
    static let automaticIngestionArgument = "--browser-download-automatic-ingestion"
    static var automaticIngestionEnabled: Bool {
        ProcessInfo.processInfo.arguments.contains(automaticIngestionArgument)
    }

    static var requiresFreshAuthentication: Bool {
        ProcessInfo.processInfo.arguments.contains("--browser-download-recovery-authentication")
    }

    static var deterministicAuthenticationEnabled: Bool {
        activeDownloadHomeEnabled || delayedHandoffLockEnabled || automaticIngestionEnabled
    }

    static var immediateAutoLockEnabled: Bool {
        activeDownloadHomeEnabled || delayedHandoffLockEnabled
    }

    static let passiveSceneCensusArgument = "--browser-download-passive-scene-census"
    static let activeDownloadHomeArgument = "--browser-download-active-download-home"
    static let delayedHandoffLockArgument = "--browser-download-delayed-handoff-lock"
    static var delayedHandoffLockEnabled: Bool {
        ProcessInfo.processInfo.arguments.contains(delayedHandoffLockArgument)
    }

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
        if ProcessInfo.processInfo.arguments.contains("--browser-download-hosted-root-read") {
            BrowserDownloadHostedRootReadFixture(process: .shared)
        } else {
            BrowserDownloadProductionQualificationRoot(process: .shared)
        }
        #else
        Color.clear
        #endif
    }
}

#if DEBUG && BROWSER_DOWNLOAD_STANDALONE_QUALIFICATION
private struct BrowserDownloadSlowKnownRun {
    let requestID: UUID
    let route: String
    let initialGeneration: UInt64
    let startedAt: TimeInterval
    var policyLockApplied = false
    var capabilityID: String?
    var operationID: String?
    var operationGeneration: UInt64?
    var handoffObserved = false
    var nativeAdmissionObserved = false
    var postLockProgressRecorded = false
    var serverPrefixProcessed = false
    var progressObserved = false
    var readinessRecorded = false
    var releaseRecorded = false
    var responseCompleted = false
    var hiddenCompletionRecorded = false
    var reconciliationRecorded = false
    var connectionClosureRecorded = false
    var failed = false
}

/// Every WindowGroup surface shares this process-owned real Root store and download lifetime.
/// Credential verification is deterministic in active-download and delayed-handoff modes; WebKit and protection remain live.
@Observable
@MainActor
private final class BrowserDownloadProductionQualificationProcess {
    static let shared = BrowserDownloadProductionQualificationProcess()
    let store: StoreOf<RootFeature>
    let library: MediaLibraryClient
    private let libraryIdentity: String
    private let databaseIdentity: String
    let owner: BrowserDownloadOwner
    let adapter: BrowserWebKitAdapter
    let coordinator: BrowserDownloadNativeCoordinator
    let evidence: BrowserDownloadProductionEvidence
    #if DEBUG && BROWSER_DOWNLOAD_STANDALONE_QUALIFICATION
    private let diagnosticRecorder = BrowserDownloadHostDiagnosticRecorder()
    #endif
    let fault: BrowserDownloadQualificationRemovalFault
    let pendingAllocation: BrowserDownloadQualificationPendingAllocation
    let securitySentinel: BrowserDownloadSecuritySentinel
    let simulatedProtectionReadback: Bool
    var status = "Fixture-seeded authentication; qualification controls below."
    /// Listener state is independent of progress and operator-status messages.
    var loopbackReady: Bool {
        server?.ready == true
    }

    var sceneCensusJSON = "{}"
    var sceneRequestJSON = "{}"
    private var slowKnownRun: BrowserDownloadSlowKnownRun?
    private var qualificationProgressObservation: NSKeyValueObservation?
    @ObservationIgnored
    private var phaseRevision: UInt64 = 0
    @ObservationIgnored
    private var activeScene = false
    @ObservationIgnored
    private var storageAvailable = false
    @ObservationIgnored
    private var storageFailure: BrowserDownloadLibraryObservation?
    let usesCompatibilityReadout = !ProcessInfo.processInfo
        .arguments
        .contains(BrowserDownloadObservationContext.launchNonceArgument)
    @ObservationIgnored
    private var reconciledContext: BrowserDownloadObservationContext?
    @ObservationIgnored
    private var acceptedOperation: UUID?
    @ObservationIgnored
    private var libraryTask: Task<Void, Never>?
    @ObservationIgnored
    private var libraryKey: LibraryRead?
    @ObservationIgnored
    private var librarySample: BrowserDownloadLibraryObservation?

    private struct LibraryRead: Equatable {
        let context: BrowserDownloadObservationContext
        let operation: UUID?
        let rows: [BrowserDownloadRecord]
        let contentEmpty: Bool
    }

    private let expectedStagedOperation: UUID? = {
        let args = ProcessInfo.processInfo.arguments
        guard let index = args.firstIndex(of: "--browser-download-expected-staged-operation") else {
            return nil
        }
        guard args.indices.contains(index + 1), let operation = UUID(uuidString: args[index + 1]) else {
            preconditionFailure("Malformed expected staging operation")
        }

        return operation
    }()

    private let observationProcessNonce: UUID = {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: BrowserDownloadObservationContext.launchNonceArgument) else {
            return UUID()
        }
        guard arguments.indices.contains(index + 1), let nonce = UUID(uuidString: arguments[index + 1]) else {
            preconditionFailure("The observation launch nonce is malformed.")
        }

        return nonce
    }()

    @ObservationIgnored
    private var phaseObservation: AnyCancellable?

    private var observationContext: BrowserDownloadObservationContext {
        .init(
            processNonce: observationProcessNonce,
            runID: evidence.runID,
            authorizationGeneration: owner.snapshot.generation,
            resourceGeneration: library.currentResourceLoadGeneration,
            ingestionGeneration: library.currentDownloadIngestionGeneration,
            phase: String(describing: store.vault.phase),
            phaseRevision: phaseRevision,
        )
    }

    /// Builds a bounded accessibility value from the in-memory event ledger.
    var passiveObservationJSON: String? {
        guard store.vault.phase != .authentication else {
            return nil
        }

        let context = observationContext
        let mountedTab = store.vault.shell.browser.selectedTab.flatMap { tab -> UUID? in
            guard context.phase == "authenticated",
                  adapter.webView(for: tab.id)?.window?.windowScene?.activationState == .foregroundActive
            else {
                return nil
            }

            return tab.id.rawValue
        }
        let sample = BrowserDownloadPassiveObservation(
            context: context,
            events: evidence.observationEvents,
            mountedTabID: mountedTab,
            discardedEventCount: evidence.discardedEventCount,
            library: currentLibrarySample,
        )
        #if DEBUG && BROWSER_DOWNLOAD_STANDALONE_QUALIFICATION
        let readout = BrowserDownloadObservationReadout(
            observation: sample,
            hostDiagnostics: diagnosticRecorder.snapshot,
        )
        let data = try? JSONEncoder().encode(readout)
        #else
        let data = try? JSONEncoder().encode(sample)
        #endif
        guard let data else {
            return nil
        }

        return String(decoding: data, as: UTF8.self)
    }

    private var lockNextImageHandoff = false
    var slowKnownDownloadStarted: Bool {
        slowKnownRun != nil
    }

    /// Completes pending fixture checks before their results appear in the passive event ledger.
    func refreshPassiveObservations() {
        refreshSlowKnownReadiness()
        inspectFixtureNavigation()
    }

    func refreshSceneCensus() {
        let census = currentSceneCensusJSON()
        if !BrowserDownloadProductionQualification.passiveSceneCensusEnabled {
            sceneCensusJSON = census
        }
        guard census != "{}" else {
            return
        }

        evidence.record("sceneCensusCaptured", ["census": census])
        refreshPassiveObservations()
    }

    /// Reads the UIKit windows, owner and latest callbacks in one turn of the main actor.
    /// Accessibility can call this getter repeatedly without publishing a new Root layout.
    func currentSceneCensusJSON() -> String {
        // Bracket the synchronous owner read so the test can place it relative to scene activation.
        let ownerSampleStartedAt = evidence.currentMonotonicSeconds
        let ownerSnapshot = owner.snapshot
        let retainedCount = owner.retainedCount
        let activeCount = owner.activeCount
        let ownerSampleCompletedAt = evidence.currentMonotonicSeconds
        let connectedWindowScenes = UIApplication.shared
            .connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .map(sceneGeometry)
            .sorted { ($0["sessionID"] as? String ?? "") < ($1["sessionID"] as? String ?? "") }
        let distinctSessionIDs = Set(connectedWindowScenes.compactMap { $0["sessionID"] as? String }).count
        let liveRoots = coordinator.qualificationRootSnapshots().map { fields in
            var row = fields
            row["runID"] = evidence.runID
            return row
        }
        let census: [String: Any] = [
            "capturedMonotonicSeconds": evidence.currentMonotonicSeconds,
            "distinctSessionIDs": distinctSessionIDs,
            "ownerGeneration": String(ownerSnapshot.generation),
            "ownerSnapshot": [
                "generation": String(ownerSnapshot.generation),
                "available": String(ownerSnapshot.isAvailable),
                "cleanupRetry": String(ownerSnapshot.cleanupNeedsRetry),
                "retained": String(retainedCount),
                "active": String(activeCount),
                "presentation": ownerSnapshot.presentation.map(\.requestID.uuidString) ?? "none",
                "operations": ownerSnapshot.records.map(\.id.rawValue.uuidString).joined(separator: ","),
                "sampleStartedMonotonicSeconds": ownerSampleStartedAt,
                "sampleCompletedMonotonicSeconds": ownerSampleCompletedAt,
            ],
            "rootLayoutObservations": evidence.rootLayoutObservations,
            "connectedWindowScenes": connectedWindowScenes,
            "latestCoordinatorObservations": evidence.latestCoordinatorObservations,
            "liveRegisteredRoots": liveRoots,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: census, options: [.sortedKeys]) else {
            return "{}"
        }

        return String(decoding: data, as: UTF8.self)
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
    private var queuedFixtureNavigationInspection: (tabID: BrowserTabID, metadata: BrowserTab.Metadata)?
    private var navigationObservation: Task<Void, Never>?
    private var server: BrowserDownloadLoopbackServer?
    private var started = false
    private var observation: Task<Void, Never>?
    private var inspected: Set<BrowserDownloadID> = []

    /// Relaunches reuse only an explicitly supplied opaque fixture identity.
    /// Legacy qualification launches receive a separate protected library root each time.
    private static func isolatedLibraryRoot() throws -> URL {
        let arguments = ProcessInfo.processInfo.arguments
        let identity: UUID =
            if let index = arguments.firstIndex(of: "--browser-download-library"),
            arguments.indices.contains(index + 1),
            let requestedIdentity = UUID(uuidString: arguments[index + 1]) {
                requestedIdentity
            } else {
                UUID()
            }
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true,
        )
        return support
            .appendingPathComponent("BrowserDownloadQualificationLibraries", isDirectory: true)
            .appendingPathComponent(identity.uuidString, isDirectory: true)
    }

    /// The database identifier hashes filesystem identity; paths and file contents stay private.
    private static func makeIsolatedLibrary() -> (client: MediaLibraryClient, id: String, databaseID: String) {
        do {
            let root = try isolatedLibraryRoot()
            let client = try MediaLibraryClient.live(at: root)
            let attributes = try FileManager.default.attributesOfItem(
                atPath: root.appendingPathComponent("library.sqlite").path,
            )
            guard let device = attributes[.systemNumber] as? UInt64,
                  let inode = attributes[.systemFileNumber] as? UInt64 else {
                fatalError("The isolated qualification database identity is unavailable.")
            }

            let identity = Data("\(device):\(inode)".utf8)
            let databaseID = SHA256.hash(data: identity).map { String(format: "%02x", $0) }.joined()
            if !BrowserDownloadProductionQualification.requiresFreshAuthentication {
                _ = client.beginAuthenticatedDownloadSession()
            }
            client.setDownloadProcessingActive(true)
            return (client, root.lastPathComponent, databaseID)
        } catch {
            fatalError("The isolated qualification Library could not be opened.")
        }
    }

    private var recordsPhysicalLibraryEvidence: Bool {
        #if os(iOS) && !targetEnvironment(simulator) && !targetEnvironment(macCatalyst)
        usesCompatibilityReadout
        #else
        false
        #endif
    }

    var compatibilityObservationsJSON: String? {
        guard store.vault.phase != .authentication else {
            return nil
        }

        return evidence.observationsJSON(authenticated: store.vault.phase == .authenticated)
    }

    private var currentLibrarySample: BrowserDownloadLibraryObservation? {
        guard activeScene else {
            return nil
        }

        if let storageFailure, storageFailure.context == observationContext {
            return storageFailure
        }
        return libraryKey == currentLibraryRead ? librarySample : nil
    }

    private var currentLibraryRead: LibraryRead? {
        guard BrowserDownloadProductionQualification.automaticIngestionEnabled, activeScene,
              storageAvailable else {
            return nil
        }

        let context = observationContext
        let snapshot = owner.snapshot
        switch store.vault.phase {
        case .locked:
            break
        case .authenticated:
            guard reconciledContext == context, snapshot.isAvailable, snapshot.records.allSatisfy({
                $0.status == .imported || $0.status == .duplicate || $0.status == .unsupported
            }) else {
                return nil
            }

        default:
            return nil
        }
        return .init(
            context: context,
            operation: acceptedOperation ?? expectedStagedOperation,
            rows: snapshot.records,
            contentEmpty: snapshot.records.isEmpty && snapshot.presentation == nil,
        )
    }

    private func didReadStorage(in context: BrowserDownloadObservationContext?, available: Bool) {
        if available {
            storageAvailable = true
            storageFailure = nil
        } else if let context, context == observationContext {
            storageAvailable = false
            storageFailure = .init(context: context, outcome: .unavailable, fields: [:])
        }
        #if DEBUG && BROWSER_DOWNLOAD_STANDALONE_QUALIFICATION
        recordDiagnosticEligibility()
        #endif
        updateLibrarySample()
    }

    private func didReconcile(_ context: BrowserDownloadObservationContext?, generation: UInt64) {
        guard let context, context == observationContext, context.ingestionGeneration == generation else {
            return
        }

        reconciledContext = context
        #if DEBUG && BROWSER_DOWNLOAD_STANDALONE_QUALIFICATION
        recordDiagnosticEligibility()
        #endif
        updateLibrarySample()
    }

    #if DEBUG && BROWSER_DOWNLOAD_STANDALONE_QUALIFICATION
    /// Inspect after normal product storage work. Reading the accessibility value never starts work.
    private var diagnosticRootPhase: BrowserDownloadHostDiagnosticRecord.RootPhase {
        switch store.vault.phase {
        case .authentication:
            .authentication
        case .locked:
            .locked
        case .authenticated:
            .authenticated
        default:
            .other
        }
    }

    func makeDiagnosticSceneLabel() -> String {
        diagnosticRecorder.makeSceneLabel()
    }

    private func recordDiagnosticEligibility(sceneLabel: String? = nil) {
        diagnosticRecorder.recordEligibility(
            sceneLabel: sceneLabel,
            activeScene: activeScene,
            storageAvailable: storageAvailable,
            rootPhase: diagnosticRootPhase,
            readEligible: currentLibraryRead != nil,
        )
    }
    #endif

    private func updateLibrarySample(sceneLabel: String? = nil) {
        let key = currentLibraryRead
        #if DEBUG && BROWSER_DOWNLOAD_STANDALONE_QUALIFICATION
        let readSceneLabel = sceneLabel
        recordDiagnosticEligibility(sceneLabel: sceneLabel)
        #endif
        guard libraryKey != key else {
            return
        }

        if libraryTask != nil {
            #if DEBUG && BROWSER_DOWNLOAD_STANDALONE_QUALIFICATION
            let contextMatches = libraryKey.map { $0.context == observationContext }
            diagnosticRecorder.cancelActiveLibraryRead(contextMatches: contextMatches)
            #endif
        }
        libraryTask?.cancel()
        libraryTask = nil
        libraryKey = key
        librarySample = nil
        guard let key else {
            return
        }

        #if DEBUG && BROWSER_DOWNLOAD_STANDALONE_QUALIFICATION
        let readTicket = diagnosticRecorder.scheduleLibraryRead(sceneLabel: readSceneLabel)
        #endif
        libraryTask = Task { [weak self] in
            guard let self else {
                return
            }

            let outcome: BrowserDownloadLibraryObservation.Outcome
            var fields: [String: String] = [:]
            do {
                if let values = try await inspectLibrary(key) {
                    outcome = .complete
                    fields = values
                } else {
                    outcome = .invalidated
                }
            } catch MediaLibraryStoreError.unavailable {
                outcome = .unavailable
            } catch is CancellationError {
                outcome = .invalidated
            } catch {
                outcome = .failed
            }
            guard !Task.isCancelled, libraryKey == key, currentLibraryRead == key else {
                #if DEBUG && BROWSER_DOWNLOAD_STANDALONE_QUALIFICATION
                let contextMatches = key.context == observationContext
                diagnosticRecorder.recordContextInvalidated(for: readTicket, contextMatches: contextMatches)
                diagnosticRecorder.recordReadOutcome(
                    .invalidated,
                    for: readTicket,
                    contextMatches: contextMatches,
                )
                #endif
                if libraryKey == key {
                    libraryTask = nil
                }
                return
            }

            #if DEBUG && BROWSER_DOWNLOAD_STANDALONE_QUALIFICATION
            let diagnosticOutcome: BrowserDownloadHostDiagnosticRecord.Outcome =
                switch outcome {
                case .complete:
                    .complete
                case .unavailable:
                    .unavailable
                case .invalidated:
                    .invalidated
                case .failed:
                    .failed
                }
            #if DEBUG && BROWSER_DOWNLOAD_STANDALONE_QUALIFICATION
            diagnosticRecorder.recordReadOutcome(
                diagnosticOutcome,
                for: readTicket,
                contextMatches: key.context == observationContext,
            )
            #endif
            #endif
            let sample = BrowserDownloadLibraryObservation(context: key.context, outcome: outcome, fields: fields)
            evidence.recordLibrary(
                sample,
                current: observationContext,
                physicalCompatibility: recordsPhysicalLibraryEvidence,
            )
            librarySample = sample
            libraryTask = nil
        }
    }

    private func inspectLibrary(_ key: LibraryRead) async throws -> [String: String]? {
        var fields = [
            "libraryID": libraryIdentity,
            "databaseID": databaseIdentity,
            "runID": key.context.runID,
            "processID": String(ProcessInfo.processInfo.processIdentifier),
            "authenticated": String(key.context.phase == "authenticated"),
        ]
        if key.context.phase == "authenticated" {
            guard let canonical = try await library.inspectCanonicalDownloads(
                matching: BrowserDownloadLoopbackServer.fixturePNG,
                resourceGeneration: key.context.resourceGeneration,
                ingestionGeneration: key.context.ingestionGeneration,
            ) else {
                return nil
            }

            fields.merge([
                "event": "canonicalLibrarySnapshot",
                "assetCount": String(canonical.assetIDs.count),
                "canonicalIDs": canonical.assetIDs.map(\.uuidString).sorted().joined(separator: ","),
                "resourceCount": String(canonical.resourceCount),
                "rowCount": String(key.rows.count),
                "rowIDs": key.rows.map(\.id.rawValue.uuidString).sorted().joined(separator: ","),
                "importedRows": String(key.rows.count { $0.status == .imported }),
                "duplicateRows": String(key.rows.count { $0.status == .duplicate }),
                "temporaryCount": String(canonical.storage.operationCount),
                "temporaryBytes": String(canonical.storage.byteCount),
                "originalBytesMatch": String(canonical.originalBytesMatch),
                "originalHashMatches": String(canonical.originalHashMatches),
                "settled": "true",
            ]) { _, value in value }
            return fields
        }
        guard let staging = try await library.inspectDownloadStaging(
            operationID: key.operation,
            resourceGeneration: key.context.resourceGeneration,
            ingestionGeneration: key.context.ingestionGeneration,
        ) else {
            return nil
        }

        fields["event"] = acceptedOperation == nil ? "libraryStartup" : "acceptedLibraryStorage"
        fields["contentEmpty"] = String(key.contentEmpty)
        fields["stagingEmpty"] = String(staging.storage.operationCount == 0 && staging.storage.byteCount == 0)
        let matches = BrowserDownloadLibraryObservation.matchesStagedFixture(
            operation: key.operation,
            verified: staging.hasSingleVerifiedStagedDownload,
            matchesOperation: staging.matchesOperation,
            count: staging.storage.operationCount,
            bytes: staging.storage.byteCount,
            expectedBytes: Int64(BrowserDownloadLoopbackServer.fixturePNG.count),
        )
        fields["singleStagedFixture"] = String(matches)
        if matches {
            fields["operation"] = key.operation?.uuidString
        }
        return fields
    }

    private init() {
        let recorder = BrowserDownloadProductionEvidence(preservesTransferMilestones:
            BrowserDownloadProductionQualification.activeDownloadHomeEnabled || BrowserDownloadProductionQualification
                .delayedHandoffLockEnabled)
        evidence = recorder
        let fixtureLibrary = Self.makeIsolatedLibrary()
        let isolatedLibrary = fixtureLibrary.client
        library = isolatedLibrary
        libraryIdentity = fixtureLibrary.id
        databaseIdentity = fixtureLibrary.databaseID
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
        weak var process: BrowserDownloadProductionQualificationProcess?
        let ingestion = BrowserDownloadIngestion(
            accept: { url, operation, filename in
                try await isolatedLibrary.acceptCompletedDownload(
                    url,
                    operationID: operation,
                    originalFilename: filename,
                )
                process?.acceptedOperation = operation
                process?.updateLibrarySample()
            },
            reconcile: { generation in
                let context = process?.observationContext
                let outcomes = await isolatedLibrary.reconcileAcceptedDownloads(generation: generation)
                process?.didReconcile(context, generation: generation)
                return outcomes
            },
            revoke: { isolatedLibrary.revokeAcceptedDownload(operationID: $0) },
            discard: { try await isolatedLibrary.discardAcceptedDownload(operationID: $0) },
            storage: {
                let context = process?.observationContext
                var available = false
                defer { process?.didReadStorage(in: context, available: available) }
                let usage = try await isolatedLibrary.acceptedDownloadStorage()
                available = true
                return usage
            },
            generation: { isolatedLibrary.currentDownloadIngestionGeneration },
            presentationURL: { operationID, generation in
                do {
                    let url = try await isolatedLibrary.completedDownloadPresentationURL(
                        operationID: operationID,
                        generation: generation,
                    )
                    recorder.record("ingestionPresentationResolved", [
                        "operation": operationID.uuidString,
                        "generation": String(generation),
                        "urlPresent": String(url != nil),
                    ])
                    return url
                } catch {
                    recorder.record("ingestionPresentationResolutionFailed", [
                        "operation": operationID.uuidString,
                        "generation": String(generation),
                    ])
                    throw error
                }
            },
        )
        #if targetEnvironment(simulator)
        let downloadOwner = BrowserDownloadOwner(
            store: scratch,
            protectedDataAvailable: { simulateReadback || UIApplication.shared.isProtectedDataAvailable },
            ingestion: BrowserDownloadProductionQualification.automaticIngestionEnabled ? ingestion : nil,
        )
        #else
        let downloadOwner = BrowserDownloadOwner(
            store: scratch,
            ingestion: BrowserDownloadProductionQualification.automaticIngestionEnabled ? ingestion : nil,
        )
        #endif
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
        var vault = VaultFeature.State(
            phase: BrowserDownloadProductionQualification.requiresFreshAuthentication ? .locked : .authenticated,
            configuredKind: .pin,
        )
        let activeDownloadHome = BrowserDownloadProductionQualification.activeDownloadHomeEnabled
        if activeDownloadHome {
            vault.sessionSettings.autoLockTimeout = .immediately
        }
        vault.shell.selectedTab = .browser
        let defaults = UserDefaults(suiteName: "BrowserDownloadQualification-\(UUID().uuidString)") ?? UserDefaults()
        store = withDependencies {
            $0.defaultAppStorage = defaults
            $0.mediaLibrary = isolatedLibrary
            $0.calculatorPersistence.load = { nil }
            $0.calculatorPersistence.save = { _ in }
            if BrowserDownloadProductionQualification.deterministicAuthenticationEnabled {
                $0.vaultCredential = .testValue
                $0.vaultCredential.verify = { _ in .succeeded }
                if BrowserDownloadProductionQualification.immediateAutoLockEnabled {
                    $0.vaultSessionSettings.load = { .init(autoLockTimeout: .immediately) }
                    $0.vaultSessionSettings.save = { _ in }
                }
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
        process = self
        observeAuthenticationPhase()
        downloadOwner.qualificationTransferObservation = { [weak self] event, fields in
            self?.recordTransferObservation(event, fields: fields)
        }
        webKitAdapter.downloadPolicyDecisionObserver = { [weak self] _ in
            self?.handleDownloadPolicyDecision()
        }
        nativeCoordinator.qualificationObservation = { [weak self] event, fields in
            self?.evidence.record(event, fields)
        }
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

    /// A return to the same phase still retires evidence from the preceding credential session.
    private func observeAuthenticationPhase() {
        phaseObservation = store.publisher.map(\.vault.phase).removeDuplicates().dropFirst().sink { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else {
                    return
                }

                self.phaseRevision += 1
                #if DEBUG && BROWSER_DOWNLOAD_STANDALONE_QUALIFICATION
                self.recordDiagnosticEligibility()
                #endif
                Task { @MainActor [weak self] in self?.updateLibrarySample() }
            }
        }
    }

    func start() async {
        guard !started else {
            return
        }

        started = true
        if BrowserDownloadProductionQualification.passiveSceneCensusEnabled {
            navigationObservation = Task { @MainActor [weak self] in
                guard let self else {
                    return
                }

                for await event in adapter.makeEventStream() {
                    guard case let .metadata(tabID, metadata, _) = event,
                          !metadata.isLoading,
                          pendingFixtureNavigation?.url == metadata.committedURL
                    else {
                        continue
                    }

                    inspectFixtureNavigation(tabID: tabID, metadata: metadata)
                }
            }
        }

        observation = Task { @MainActor [weak self] in
            guard let self else {
                return
            }

            for await snapshot in owner.subscribe() {
                updateLibrarySample()
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
                for record in snapshot.records where !BrowserDownloadProductionQualification.automaticIngestionEnabled
                    && record.isReady && !inspected.contains(record.id) {
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

    func downloadImageUnderLock() {
        lockNextImageHandoff = true
        navigate("image")
    }

    func navigate(_ route: String) {
        guard let server, let baseURL = try? server.url(route) else {
            return
        }

        let requestID = UUID().uuidString
        let url = ["first", "attachment", "image", "image-as-pdf", "pdf-as-image"].contains(route)
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
    func startSlowKnownDownload(finite: Bool = false) {
        startQualificationDownload(route: finite ? "finite-continuation" : "slow-known")
    }

    func startDelayedHandoffDownload() {
        guard BrowserDownloadProductionQualification.delayedHandoffLockEnabled else {
            return
        }

        startQualificationDownload(route: "delayed-handoff")
    }

    private func startQualificationDownload(route: String) {
        guard slowKnownRun == nil, let server,
              let url = try? server.url(route)
        else {
            return
        }

        let requestID = UUID()
        slowKnownRun = BrowserDownloadSlowKnownRun(
            requestID: requestID,
            route: route,
            initialGeneration: owner.snapshot.generation,
            startedAt: ProcessInfo.processInfo.systemUptime,
        )
        let requestURL = url.appending(queryItems: [
            URLQueryItem(name: "qualificationRequest", value: requestID.uuidString),
        ])
        evidence.record("fixtureNavigationRequested", [
            "fixtureRoute": route,
            "fixtureRequest": requestID.uuidString,
        ])
        store.send(.vault(.shell(.browser(.navigate(requestURL)))))
        status = "Slow-known WKDownload started; waiting for the live readiness witness."
        refreshSlowKnownReadiness()
        refreshPassiveObservations()
    }

    /// Locks through Root while WebKit still holds the accepted policy callback on its stack.
    private func handleDownloadPolicyDecision() {
        guard lockNextImageHandoff else {
            lockAtAcceptedPolicyBoundary()
            return
        }

        lockNextImageHandoff = false
        store.send(.vault(.lock))
        evidence.record("automaticMediaPolicyLocked", [:])
    }

    private func lockAtAcceptedPolicyBoundary() {
        guard BrowserDownloadProductionQualification.delayedHandoffLockEnabled,
              var run = slowKnownRun, run.route == "delayed-handoff", !run.policyLockApplied,
              let capability = run.capabilityID else {
            return
        }

        run.policyLockApplied = true
        slowKnownRun = run
        let before = owner.snapshot.generation
        store.send(.vault(.lock))
        let snapshot = owner.snapshot
        evidence.record("pendingPolicyLockApplied", [
            "fixtureRequest": run.requestID.uuidString,
            "operation": run.operationID ?? "unavailable",
            "capability": capability,
            "connectionID": server?
                .slowKnownEvidence(for: run.requestID, route: run.route)["connectionID"] ?? "unavailable",
            "generationBefore": String(before),
            "generation": String(snapshot.generation),
            "authenticated": String(isVaultAuthenticated),
            "available": String(snapshot.isAvailable),
            "contentEmpty": String(snapshot.records.isEmpty && snapshot.presentation == nil),
        ])
    }

    func applyQualificationScenePhase(
        _ phase: String,
        applicationPhase: VaultApplicationScenePhase,
        sceneLabel: String,
    ) {
        let generationBefore = owner.snapshot.generation
        store.send(.applicationPhaseChanged(applicationPhase))
        activeScene = phase == "active"
        #if DEBUG && BROWSER_DOWNLOAD_STANDALONE_QUALIFICATION
        diagnosticRecorder.recordScenePhase(
            BrowserDownloadHostDiagnosticRecord.ScenePhase(rawValue: phase) ?? .other,
            sceneLabel: sceneLabel,
        )
        recordDiagnosticEligibility(sceneLabel: sceneLabel)
        #endif
        updateLibrarySample(sceneLabel: sceneLabel)
        let snapshot = owner.snapshot
        guard let run = slowKnownRun else {
            return
        }

        evidence.record("qualificationScenePhaseChanged", [
            "fixtureRequest": run.requestID.uuidString,
            "operation": run.operationID ?? "none",
            "capability": run.capabilityID ?? "unavailable",
            "connectionID": server?
                .slowKnownEvidence(for: run.requestID, route: run.route)["connectionID"] ?? "unavailable",
            "phase": phase,
            "applicationState": applicationStateLabel,
            "generationBefore": String(generationBefore),
            "generation": String(snapshot.generation),
            "authorizationRevokedSynchronously": String(
                phase == "background" && snapshot.generation != generationBefore,
            ),
            "activeWriterCount": String(owner.activeCount),
            "retainedRecordCount": String(owner.retainedCount),
            "contentEmpty": String(snapshot.records.isEmpty && snapshot.presentation == nil),
            "available": String(snapshot.isAvailable),
            "authenticated": String(isVaultAuthenticated),
        ])
        // Root's real background action must have locked and concealed content before release.
        if phase == "background", run.route == "finite-continuation", run.readinessRecorded,
           !run.releaseRecorded, !isVaultAuthenticated, !snapshot.isAvailable,
           snapshot.records.isEmpty, snapshot.presentation == nil,
           let connection = server?.slowKnownEvidence(for: run.requestID, route: run.route)["connectionID"],
           let connectionID = UUID(uuidString: connection) {
            slowKnownRun?.releaseRecorded = true
            evidence.record("finiteResponseReleaseRequested", [
                "fixtureRequest": run.requestID.uuidString,
                "operation": run.operationID ?? "unavailable",
                "capability": run.capabilityID ?? "unavailable",
                "connectionID": connection,
            ])
            let released = server?.releaseFiniteResponse(requestID: run.requestID, connectionID: connectionID) == true
            evidence.record("finiteResponseReleaseResult", [
                "fixtureRequest": run.requestID.uuidString,
                "released": String(released),
            ])
        }
    }

    /// Owner events describe actual policy admission and native delegate callbacks.
    private func recordTransferObservation(_ event: String, fields: [String: String]) {
        var fields = fields
        if var run = slowKnownRun {
            if event == "policyDownloadAdmitted", run.capabilityID == nil {
                run.capabilityID = fields["capability"]
                run.operationID = fields["operation"]
            }
            if event == "transferAdmitted", fields["capability"] == run.capabilityID {
                run.operationID = fields["operation"]
                run.nativeAdmissionObserved = true
                run.operationGeneration = owner.snapshot.generation
            }
            if fields["operation"] == run.operationID || fields["capability"] == run.capabilityID {
                fields["fixtureRequest"] = run.requestID.uuidString
                fields["capability"] = run.capabilityID
                fields["connectionID"] = server?.slowKnownEvidence(for: run.requestID, route: run.route)["connectionID"]
            }
            slowKnownRun = run
        }
        evidence.record(event, fields)
        if event == "writerFinished", fields["operation"] == slowKnownRun?.operationID {
            Task { @MainActor [weak self] in
                // Sample after the native callback has updated the retained entry.
                await Task.yield()
                guard let self, var run = slowKnownRun, !run.hiddenCompletionRecorded else {
                    return
                }

                let snapshot = owner.snapshot
                evidence.record("hiddenCompletion", [
                    "fixtureRequest": run.requestID.uuidString,
                    "operation": run.operationID ?? "unavailable",
                    "capability": run.capabilityID ?? "unavailable",
                    "connectionID": server?
                        .slowKnownEvidence(for: run.requestID, route: run.route)["connectionID"] ?? "unavailable",
                    "contentEmpty": String(snapshot.records.isEmpty && snapshot.presentation == nil),
                    "available": String(snapshot.isAvailable),
                    "authenticated": String(isVaultAuthenticated),
                    "activeWriterCount": String(owner.activeCount),
                    "retainedRecordCount": String(owner.retainedCount),
                ])
                run.hiddenCompletionRecorded = true
                slowKnownRun = run
                refreshSlowKnownReadiness()
            }
        }
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
        if sameOrigin, identity != nil {
            // WebKit hands off the writer before the owner consumes its policy reservation.
            let pending = owner.snapshot.records.filter { $0.tabID == tabID && !$0.isReady }
            if pending.count == 1 {
                fields["operation"] = pending.first?.id.rawValue.uuidString
            }
        }
        evidence.record("nativeDownloadHandoff", fields)

        guard var run = slowKnownRun, let identity,
              identity.route == run.route, identity.requestID == run.requestID,
              sameOrigin
        else {
            return
        }

        run.handoffObserved = true
        slowKnownRun = run
        qualificationProgressObservation = download.progress.observe(\.completedUnitCount, options: [
            .initial,
            .new,
        ]) { [weak self] progress, _ in
            let received = progress.completedUnitCount
            let expected = progress.totalUnitCount
            let callbackUptime = ProcessInfo.processInfo.systemUptime
            Task { @MainActor [weak self] in
                self?.recordPostLockNativeProgress(received: received, expected: expected, uptime: callbackUptime)
            }
        }
        refreshSlowKnownReadiness()
    }

    /// Observes the original WKDownload's Progress even while content snapshots are hidden.
    private func recordPostLockNativeProgress(received: Int64, expected: Int64, uptime: TimeInterval) {
        guard var run = slowKnownRun, run.nativeAdmissionObserved, !run.postLockProgressRecorded,
              (run.releaseRecorded && received > 262_144) || (run.policyLockApplied && received > 0),
              !isVaultAuthenticated, !owner.snapshot.isAvailable else {
            return
        }

        run.postLockProgressRecorded = true
        slowKnownRun = run
        evidence.record("nativePostLockProgress", [
            "fixtureRequest": run.requestID.uuidString,
            "operation": run.operationID ?? "unavailable",
            "capability": run.capabilityID ?? "unavailable",
            "connectionID": server?
                .slowKnownEvidence(for: run.requestID, route: run.route)["connectionID"] ?? "unavailable",
            "receivedBytes": String(received),
            "expectedBytes": String(expected),
            "callbackMonotonicSeconds": evidence.monotonicSeconds(forUptime: uptime),
            "authenticated": "false",
            "available": "false",
        ])
    }

    private func refreshSlowKnownReadiness(snapshot: BrowserDownloadSnapshot? = nil) {
        guard var run = slowKnownRun, let server else {
            return
        }

        let current = snapshot ?? owner.snapshot
        let requestID = run.requestID.uuidString
        let serverEvidence = server.slowKnownEvidence(for: run.requestID, route: run.route)
        if run.route != "delayed-handoff" {
            recordSlowKnownServerPrefix(&run, requestID: requestID, evidence: serverEvidence)
        }

        if run.route != "delayed-handoff", run.nativeAdmissionObserved, !run.readinessRecorded,
           let operationID = run.operationID {
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

        if run.releaseRecorded, !run.responseCompleted,
           serverEvidence["responseComplete"] == "true" {
            evidence.record("finiteResponseCompleted", [
                "fixtureRequest": requestID,
                "operation": run.operationID ?? "unavailable",
                "capability": run.capabilityID ?? "unavailable",
                "connectionID": serverEvidence["connectionID"] ?? "unavailable",
                "expectedBytes": serverEvidence["expectedBytes"] ?? "unknown",
                "prefixBytes": serverEvidence["prefixBytes"] ?? "unknown",
                "remainderBytes": serverEvidence["remainderBytes"] ?? "unknown",
                "sendStackState": serverEvidence["sendStackState"] ?? "unknown",
                "releaseMonotonicSeconds": serverEvidence["releaseUptime"]
                    .flatMap(Double.init)
                    .map { evidence.monotonicSeconds(forUptime: $0) } ?? "unavailable",
            ])
            run.responseCompleted = true
        }
        if run.hiddenCompletionRecorded, !run.reconciliationRecorded,
           current.isAvailable, isVaultAuthenticated,
           let record = current.records.first(where: { $0.id.rawValue.uuidString == run.operationID }),
           record.isReady {
            evidence.record("retainedCompletionReconciled", [
                "fixtureRequest": requestID,
                "operation": record.id.rawValue.uuidString,
                "capability": run.capabilityID ?? "unavailable",
                "connectionID": serverEvidence["connectionID"] ?? "unavailable",
                "generation": String(current.generation),
                "available": "true",
                "authenticated": "true",
                "isReady": "true",
            ])
            run.reconciliationRecorded = true
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
              serverEvidence["route"] == run.route,
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
            "route": run.route,
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
        guard !run.failed, run.handoffObserved, run.nativeAdmissionObserved, run.serverPrefixProcessed,
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
        guard let tab = store.vault.shell.browser.selectedTab else {
            return
        }

        inspectFixtureNavigation(tabID: tab.id, metadata: tab.metadata)
    }

    /// Checks the document after the WebKit adapter emits matching committed metadata.
    private func inspectFixtureNavigation(tabID: BrowserTabID, metadata: BrowserTab.Metadata) {
        guard let pending = pendingFixtureNavigation,
              metadata.committedURL == pending.url,
              let tab = store.vault.shell.browser.selectedTab,
              tab.id == tabID,
              let view = adapter.webView(for: tabID)
        else {
            return
        }
        guard !navigationInspectionIsPending else {
            queuedFixtureNavigationInspection = (tabID, metadata)
            return
        }

        navigationInspectionIsPending = true
        view.evaluateJavaScript("[document.readyState, location.href]") { [weak self, weak view] result, _ in
            guard let self else {
                return
            }

            navigationInspectionIsPending = false
            let queuedInspection = queuedFixtureNavigationInspection
            queuedFixtureNavigationInspection = nil
            if let queuedInspection {
                inspectFixtureNavigation(tabID: queuedInspection.tabID, metadata: queuedInspection.metadata)
                return
            }

            guard pendingFixtureNavigation?.id == pending.id,
                  store.vault.shell.browser.selectedTab?.id == tab.id,
                  store.vault.shell.browser.selectedTab?.metadata.committedURL == pending.url,
                  let view, adapter.webView(for: tab.id) === view,
                  metadata.committedURL == pending.url,
                  view.url == pending.url,
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
        let operationID = id.rawValue.uuidString
        let context = observationContext
        do {
            guard isVaultAuthenticated else {
                throw BrowserDownloadObservationError.invalidated
            }

            let url = try owner.inspectCompletedFile(id)
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            let values = try url.resourceValues(forKeys: [.isExcludedFromBackupKey])
            let bytes = try Data(contentsOf: url)
            let actualProtection = attributes[.protectionKey] as? FileProtectionType
            guard observationContext == context else {
                throw BrowserDownloadObservationError.invalidated
            }

            evidence.record("completedFileProof", [
                "processNonce": context.processNonce.uuidString,
                "authorizationGeneration": String(context.authorizationGeneration),
                "resourceGeneration": String(context.resourceGeneration),
                "ingestionGeneration": String(context.ingestionGeneration),
                "phase": context.phase,
                "phaseRevision": String(context.phaseRevision),
                "ready": "true",
                "operation": operationID,
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
                "fixtureBytesMatch": String(bytes == (
                    slowKnownRun?.operationID == id.rawValue.uuidString && slowKnownRun?.route == "finite-continuation"
                        ? BrowserDownloadLoopbackServer.slowPayload
                        : BrowserDownloadLoopbackServer.fixturePDF
                )),
            ])
            pendingAllocation.record(operation: id, directory: url.deletingLastPathComponent())
        } catch {
            evidence.record("completedFileInspectionFailed", ["operation": operationID])
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

        let verified = isVaultAuthenticated && (try? owner.inspectCompletedFile(id)) != nil
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
    @State
    private var diagnosticSceneLabel: String

    init(process: BrowserDownloadProductionQualificationProcess) {
        self.process = process
        _browserHostingContext = State(initialValue: BrowserQualificationWebKitHostingContext(
            adapter: process.adapter,
        ))
        _diagnosticSceneLabel = State(initialValue: process.makeDiagnosticSceneLabel())
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
                Text(process.loopbackReady ? "Loopback listener ready" : "Loopback listener unavailable")
                    .font(.caption2)
                    .accessibilityIdentifier("downloadQualificationLoopbackReadiness")
                    .accessibilityValue(process.loopbackReady ? "ready" : "unavailable")
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
                        if BrowserDownloadProductionQualification.automaticIngestionEnabled {
                            Button("Download PNG") { process.navigate("image") }
                                .accessibilityIdentifier("downloadQualificationDownloadImage")
                            Button("Download PNG with PDF metadata") { process.navigate("image-as-pdf") }
                                .accessibilityIdentifier("downloadQualificationDownloadMislabelledImage")
                            Button("Download PNG under Lock") { process.downloadImageUnderLock() }
                                .accessibilityIdentifier("downloadQualificationDownloadImageUnderLock")
                            Button("Download PDF with PNG metadata") { process.navigate("pdf-as-image") }
                                .accessibilityIdentifier("downloadQualificationDownloadMislabelledPDF")
                        }
                        Button("Start slow-known download") { process.startSlowKnownDownload() }
                            .accessibilityIdentifier("downloadQualificationStartSlowKnown")
                            .disabled(process.slowKnownDownloadStarted)
                        Button("Start finite continuation") { process.startSlowKnownDownload(finite: true) }
                            .accessibilityIdentifier("downloadQualificationStartFiniteContinuation")
                            .disabled(process.slowKnownDownloadStarted)
                        if BrowserDownloadProductionQualification.delayedHandoffLockEnabled {
                            Button("Start delayed handoff") { process.startDelayedHandoffDownload() }
                                .accessibilityIdentifier("downloadQualificationStartDelayedHandoff")
                                .disabled(process.slowKnownDownloadStarted)
                        }
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
                    if process.usesCompatibilityReadout {
                        Button("Refresh observations") { process.refreshPassiveObservations() }
                            .accessibilityIdentifier("downloadQualificationRefreshObservations")
                    }
                    Text("Sentinel: " + process.securitySentinel.stage)
                        .font(.caption2)
                        .accessibilityIdentifier("downloadQualificationSecuritySentinelStatus")
                        .accessibilityValue(process.securitySentinel.stageSummary)
                }
                if process.usesCompatibilityReadout {
                    BrowserDownloadPassiveEvidenceLabel(
                        title: "Qualification observations",
                        identifier: "downloadQualificationObservations",
                    ) {
                        process.compatibilityObservationsJSON
                    }
                    .fixedSize()
                }
                evidenceReadout(
                    "Connected window-scene census",
                    identifier: "downloadQualificationSceneCensus",
                    lastRefresh: process.sceneCensusJSON,
                    read: process.currentSceneCensusJSON,
                )
                Text("Latest scene-request event")
                    .font(.caption2)
                    .accessibilityIdentifier("downloadQualificationSceneRequest")
                    .accessibilityValue(process.sceneRequestJSON)
            }
            .padding(8)
            .background(.regularMaterial)
            // The production credential form lays out independently of this diagnostic inset.
            // Keep the panel from obscuring or intercepting its genuine secure-field input.
            .opacity(process.store.vault.phase == .authentication ? 0 : 1)
            .allowsHitTesting(process.store.vault.phase != .authentication)
            .accessibilityHidden(process.store.vault.phase == .authentication)
        }
        .overlay(alignment: .topLeading) {
            if process.store.vault.phase != .authentication {
                BrowserDownloadPassiveEvidenceLabel(
                    title: "Passive qualification event history",
                    identifier: "downloadQualificationPassiveObservations",
                    read: { process.passiveObservationJSON },
                )
                .frame(width: 1, height: 1)
                .clipped()
                .allowsHitTesting(false)
            }
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
            if BrowserDownloadProductionQualification.activeDownloadHomeEnabled
                || BrowserDownloadProductionQualification.automaticIngestionEnabled {
                process.applyQualificationScenePhase(
                    phase,
                    applicationPhase: applicationPhase,
                    sceneLabel: diagnosticSceneLabel,
                )
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

    @ViewBuilder
    private func evidenceReadout(
        _ title: String,
        identifier: String,
        lastRefresh: @autoclosure () -> String,
        read: @escaping @MainActor () -> String,
    ) -> some View {
        if BrowserDownloadProductionQualification.passiveSceneCensusEnabled {
            BrowserDownloadPassiveEvidenceLabel(title: title, identifier: identifier) {
                process.store.vault.phase == .authentication ? nil : read()
            }
            .fixedSize()
        } else {
            Text(verbatim: title)
                .font(.caption2)
                .accessibilityIdentifier(identifier)
                .accessibilityValue(lastRefresh())
        }
    }
}

/// UIKit asks for the value when taking an accessibility snapshot. Reading it leaves SwiftUI
/// observation untouched, so polling the label does not schedule another Root render.
@MainActor
private struct BrowserDownloadPassiveEvidenceLabel: UIViewRepresentable {
    let title: String
    let identifier: String
    let read: @MainActor () -> String?

    func makeUIView(context _: Context) -> Label {
        makeLabel()
    }

    func makeLabel() -> Label {
        let label = Label()
        label.text = title
        label.font = .preferredFont(forTextStyle: .caption2)
        label.adjustsFontForContentSizeCategory = true
        label.isAccessibilityElement = true
        label.accessibilityTraits = .staticText
        label.accessibilityIdentifier = identifier
        label.read = read
        return label
    }

    func updateUIView(_ label: Label, context _: Context) {
        label.read = read
    }

    final class Label: UILabel {
        var read: (@MainActor () -> String?)?

        override var accessibilityValue: String? {
            get { read?() }
            set { super.accessibilityValue = newValue }
        }
    }
}

/// Hosts a real registered controller so the test can sample an equal-token update before
/// the main actor yields to its scheduled layout verification.
@MainActor
private struct BrowserDownloadHostedRootReadFixture: UIViewControllerRepresentable {
    let process: BrowserDownloadProductionQualificationProcess

    func makeUIViewController(context _: Context) -> BrowserDownloadHostController {
        let host = BrowserDownloadHostController()
        host.nativeCoordinator = process.coordinator
        host.authentication = { process.store.vault.phase == .authenticated }
        host.currentRenderToken = {
            .init(
                surfaceID: "hostedRoot",
                authenticated: process.store.vault.phase == .authenticated,
                privacyGeneration: process.owner.snapshot.generation,
            )
        }
        let root = LayoutView()
        host.view = root
        func label(_ title: String, _ identifier: String, _ read: @escaping @MainActor () -> String?) -> UILabel {
            BrowserDownloadPassiveEvidenceLabel(title: title, identifier: identifier) {
                process.store.vault.phase == .authenticated ? read() : nil
            }.makeLabel()
        }
        let census = label("Scene census", "downloadQualificationSceneCensus", process.currentSceneCensusJSON)
        let events = label("Coordinator events", "downloadQualificationObservations") {
            process.compatibilityObservationsJSON
        }
        let pending = label("Census at update", "downloadQualificationRootUpdateCensus") { [weak root] in
            root?.censusAtUpdate
        }
        let layouts = label("Host layout passes", "downloadQualificationRootLayoutPasses") { [weak root] in
            root.map { String($0.layoutPasses) }
        }
        let update = UIButton(type: .system, primaryAction: UIAction(title: "Reconcile current Root") {
            [weak host, weak root, weak census] _ in
            guard let host, host.authentication() else {
                return
            }

            host.rootUpdated(host.currentRenderToken())
            root?.censusAtUpdate = census?.accessibilityValue
        })
        update.accessibilityIdentifier = "downloadQualificationReconcileCurrentRoot"
        let stack = UIStackView(arrangedSubviews: [census, events, pending, layouts, update])
        stack.axis = .vertical
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: root.centerYAnchor),
        ])
        return host
    }

    func updateUIViewController(_: BrowserDownloadHostController, context _: Context) {}

    static func dismantleUIViewController(_ host: BrowserDownloadHostController, coordinator: ()) {
        BrowserDownloadHost.dismantleUIViewController(host, coordinator: coordinator)
    }

    private final class LayoutView: UIView {
        var censusAtUpdate: String?
        private(set) var layoutPasses = 0

        override func layoutSubviews() {
            super.layoutSubviews()
            layoutPasses += 1
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
#endif
