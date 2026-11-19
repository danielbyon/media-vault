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
import Combine
import ComposableArchitecture
import CoreFoundation
import CoreGraphics
import CryptoKit
import Dependencies
import Dispatch
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
    let fault: BrowserDownloadQualificationRemovalFault
    let pendingAllocation: BrowserDownloadQualificationPendingAllocation
    let securitySentinel: BrowserDownloadSecuritySentinel
    let simulatedProtectionReadback: Bool
    var status = "Fixture-seeded authentication; qualification controls below."
    /// Listener state is independent of progress and operator-status messages.
    var loopbackReady: Bool {
        server?.ready == true
    }

    var observationsJSON = "[]"
    var sceneCensusJSON = "{}"
    var sceneRequestJSON = "{}"
    private var slowKnownRun: BrowserDownloadSlowKnownRun?
    private var qualificationProgressObservation: NSKeyValueObservation?
    private var libraryInspectionPending = false
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

    var observationReceiptJSON = ""
    private var observationPreparation: BrowserDownloadObservationPreparation?

    var observationPreparationJSON: String {
        let preparation = observationPreparation ?? .init(processNonce: observationProcessNonce)
        guard let data = try? JSONEncoder().encode(preparation) else {
            return ""
        }

        return String(decoding: data, as: UTF8.self)
    }

    @ObservationIgnored
    private var phaseObservation: AnyCancellable?
    @ObservationIgnored
    private var lastAuthenticationGeometry: [String: String] = [:]
    @ObservationIgnored
    private var authenticationGeometryCount = 0
    @ObservationIgnored
    private lazy var observationController = BrowserDownloadObservationController(
        context: { [store, owner, library, evidence, observationProcessNonce] in
            .init(
                processNonce: observationProcessNonce,
                runID: evidence.runID,
                authorizationGeneration: owner.snapshot.generation,
                resourceGeneration: library.currentResourceLoadGeneration,
                ingestionGeneration: library.currentDownloadIngestionGeneration,
                phase: String(describing: store.vault.phase),
            )
        },
        publish: { [weak self] receipt in
            guard let data = try? JSONEncoder().encode(receipt) else {
                return
            }

            self?.observationReceiptJSON = String(decoding: data, as: UTF8.self)
        },
    )

    private var observationContext: BrowserDownloadObservationContext {
        .init(
            processNonce: observationProcessNonce,
            runID: evidence.runID,
            authorizationGeneration: owner.snapshot.generation,
            resourceGeneration: library.currentResourceLoadGeneration,
            ingestionGeneration: library.currentDownloadIngestionGeneration,
            phase: String(describing: store.vault.phase),
        )
    }

    private var lockNextImageHandoff = false
    @ObservationIgnored
    private weak var readoutProbe: BrowserDownloadReadoutAccessibilityProbe.ProbeView?

    var slowKnownDownloadStarted: Bool {
        slowKnownRun != nil
    }

    /// Copy redacted observations only on explicit fixture input, avoiding a Root-layout feedback loop.
    func refreshObservations() {
        refreshSlowKnownReadiness()
        // Keep the legacy array endpoint's immediate-copy behavior for physical consumers.
        observationsJSON = evidence.observationsJSON
        inspectFixtureNavigation()
        Task { @MainActor [weak self] in
            guard let self else {
                return
            }

            _ = await observationController.refresh(inspect: inspectObservationSnapshot)
        }
    }

    private func inspectObservationSnapshot() async throws -> BrowserDownloadObservationSnapshot {
        guard observationContext.phase != "authentication" else {
            throw BrowserDownloadObservationError.invalidated
        }

        let inspection = try await inspectCanonicalLibraryEvidence()
        return BrowserDownloadObservationSnapshot(inspection: inspection, events: evidence.observationEvents)
            .addingFixtureProofs(expectedStagingBytes: Int64(BrowserDownloadLoopbackServer.fixturePNG.count))
    }

    /// Completes a real read before returning its evidence; stale reads never become receipts.
    private func inspectCanonicalLibraryEvidence() async throws -> [String: String]? {
        guard BrowserDownloadProductionQualification.automaticIngestionEnabled else {
            return nil
        }
        guard !libraryInspectionPending else {
            throw BrowserDownloadObservationError.busy
        }

        let context = observationContext

        libraryInspectionPending = true
        defer { libraryInspectionPending = false }
        do {
            if store.vault.phase != .authenticated {
                let storage = try await library.acceptedDownloadStorage()
                guard observationContext == context else {
                    throw BrowserDownloadObservationError.invalidated
                }

                let snapshot = owner.snapshot
                evidence.record("acceptedLibraryStorage", [
                    "temporaryCount": String(storage.operationCount),
                    "temporaryBytes": String(storage.byteCount),
                    "libraryID": libraryIdentity,
                    "databaseID": databaseIdentity,
                    "authenticated": "false",
                    "contentEmpty": String(snapshot.records.isEmpty && snapshot.presentation == nil),
                ])
            } else {
                let generation = library.currentResourceLoadGeneration
                let assets = try await library.loadAssets()
                let storage = try await library.acceptedDownloadStorage()
                var bytesMatch = true
                var hashesMatch = true
                var resourceCount = 0
                for resource in assets.flatMap(\.resources) {
                    guard let data = try await library.resourceDataIfCurrent(resource, generation: generation) else {
                        throw BrowserDownloadObservationError.invalidated
                    }

                    resourceCount += 1
                    bytesMatch = bytesMatch && data == BrowserDownloadLoopbackServer.fixturePNG
                    let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                    hashesMatch = hashesMatch && digest == resource.sha256
                }
                guard observationContext == context else {
                    throw BrowserDownloadObservationError.invalidated
                }

                let rows = owner.snapshot.records
                let settled = rows.allSatisfy {
                    $0.status == .imported || $0.status == .duplicate || $0.status == .unsupported
                }
                evidence.record("canonicalLibrarySnapshot", [
                    "assetCount": String(assets.count),
                    "libraryID": libraryIdentity,
                    "databaseID": databaseIdentity,
                    "canonicalIDs": assets.map(\.id.uuidString).sorted().joined(separator: ","),
                    "resourceCount": String(resourceCount),
                    "rowCount": String(rows.count),
                    "rowIDs": rows.map(\.id.rawValue.uuidString).sorted().joined(separator: ","),
                    "importedRows": String(rows.count { $0.status == .imported }),
                    "duplicateRows": String(rows.count { $0.status == .duplicate }),
                    "temporaryCount": String(storage.operationCount),
                    "temporaryBytes": String(storage.byteCount),
                    "originalBytesMatch": String(bytesMatch),
                    "originalHashMatches": String(hashesMatch),
                    "settled": String(settled),
                ])
            }
            observationsJSON = evidence.observationsJSON
            return evidence.observationEvents.last
        } catch {
            // Legacy readers retain their original failure events and publication behavior.
            if observationContext == context {
                if context.phase == "authenticated" {
                    evidence.record("canonicalLibraryInspectionFailed", [:])
                    observationsJSON = evidence.observationsJSON
                } else {
                    evidence.record("acceptedLibraryStorageUnavailable", [:])
                }
            }
            throw error
        }
    }

    /// Completes pending fixture checks before their results appear in the passive event ledger.
    func refreshPassiveObservations() {
        guard BrowserDownloadProductionQualification.passiveSceneCensusEnabled else {
            return
        }

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

    /// Samples durable ownership before a recovery launch can authenticate or reconcile.
    private func recordLibraryStartup() async {
        guard BrowserDownloadProductionQualification.automaticIngestionEnabled else {
            return
        }

        do {
            let storage = try await library.acceptedDownloadStorage()
            evidence.record("libraryStartup", [
                "libraryID": libraryIdentity,
                "databaseID": databaseIdentity,
                "temporaryCount": String(storage.operationCount),
                "temporaryBytes": String(storage.byteCount),
                "authenticated": String(store.vault.phase == .authenticated),
                "rowCount": String(owner.snapshot.records.count),
                "contentEmpty": String(owner.snapshot.records.isEmpty && owner.snapshot.presentation == nil),
            ])
        } catch {
            evidence.record("libraryStartupInspectionFailed", [:])
        }
        observationsJSON = evidence.observationsJSON
    }

    private init() {
        let recorder = BrowserDownloadProductionEvidence()
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
        let ingestion = BrowserDownloadIngestion(
            accept: { try await isolatedLibrary.acceptCompletedDownload($0, operationID: $1, originalFilename: $2) },
            reconcile: { await isolatedLibrary.reconcileAcceptedDownloads(generation: $0) },
            revoke: { isolatedLibrary.revokeAcceptedDownload(operationID: $0) },
            discard: { try await isolatedLibrary.discardAcceptedDownload(operationID: $0) },
            storage: { try await isolatedLibrary.acceptedDownloadStorage() },
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
        downloadOwner.qualificationTransferObservation = { [weak self] event, fields in
            self?.recordTransferObservation(event, fields: fields)
        }
        webKitAdapter.downloadPolicyDecisionObserver = { [weak self] _ in
            self?.handleDownloadPolicyDecision()
        }
        nativeCoordinator.qualificationObservation = { [weak self] event, fields in
            self?.recordNativeQualification(event, fields: fields)
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

    /// Observe exact phases without changing Root actions, layout or credential behavior.
    private func startAuthenticationDiagnostics() {
        guard phaseObservation == nil else {
            return
        }

        phaseObservation = store.publisher
            .map(\.vault.phase)
            .removeDuplicates()
            .sink { [weak self] phase in
                MainActor.assumeIsolated {
                    guard let self else {
                        return
                    }

                    self.observationController.contextDidChange()
                    guard BrowserDownloadProductionQualification.automaticIngestionEnabled else {
                        return
                    }

                    self.evidence.record("authenticationPhaseObserved", [
                        "phase": String(describing: phase),
                        "processNonce": self.observationProcessNonce.uuidString,
                        "privacyGeneration": String(self.owner.snapshot.generation),
                        "resourceGeneration": String(self.library.currentResourceLoadGeneration),
                        "ingestionGeneration": String(self.library.currentDownloadIngestionGeneration),
                    ])
                }
            }
    }

    func recordReadoutLayout(_ fields: [String: String]) {
        evidence.record("diagnosticReadoutState", fields)
        guard fields["sampleSource"] == "readoutLayout",
              let window = readoutProbe?.window else {
            return
        }

        // Sample after the probe's actual layout turn; do not force a Root layout or read field text.
        DispatchQueue.main.async { [weak self, weak window] in
            guard let self, let window else {
                return
            }

            recordAuthenticationGeometry(in: window)
        }
    }

    private func recordAuthenticationGeometry(in window: UIWindow) {
        guard authenticationGeometryCount < 64 else {
            return
        }

        var queue: [UIView] = [window]
        var visited = 0
        var secureFields: [UITextField] = []
        var primaryCoverVisible = false
        while let view = queue.popLast(), visited < 2_048 {
            visited += 1
            if let field = view as? UITextField, field.isSecureTextEntry {
                secureFields.append(field)
            }
            if view.accessibilityIdentifier == "MediaVault.ScenePrivacyCoverPrimaryContent" {
                primaryCoverVisible = !view.isHidden && view.alpha > 0
            }
            queue.append(contentsOf: view.subviews)
        }
        func isVisible(_ view: UIView) -> Bool {
            var ancestor: UIView? = view
            while let current = ancestor {
                if current.isHidden || current.alpha <= 0.01 {
                    return false
                }
                ancestor = current.superview
            }
            return true
        }
        var visible = 0
        var reachable = 0
        var frames: [String] = []
        for field in secureFields {
            let frame = field.convert(field.bounds, to: window)
            let finite = [frame.minX, frame.minY, frame.width, frame.height].allSatisfy(\.isFinite)
            if finite, !frame.isInfinite, !frame.isEmpty {
                frames.append(String(describing: frame))
                if isVisible(field), frame.intersects(window.bounds) {
                    visible += 1
                    let point = CGPoint(x: frame.midX, y: frame.midY)
                    if let hit = window.hitTest(point, with: nil), hit === field || hit.isDescendant(of: field) {
                        reachable += 1
                    }
                }
            }
        }
        let windows = window.windowScene?.windows ?? []
        let latest = evidence.latestCoordinatorObservations.last ?? [:]
        let state: [String: String] = [
            "phase": String(describing: store.vault.phase),
            "processNonce": observationProcessNonce.uuidString,
            "windowBounds": String(describing: window.bounds),
            "windowKey": String(window.isKeyWindow),
            "windowHidden": String(window.isHidden),
            "secureFieldCount": String(secureFields.count),
            "secureFieldVisibleGeometryCount": String(visible),
            "secureFieldHitTestReachableCount": String(reachable),
            "secureFieldFrames": frames.joined(separator: ";"),
            "traversalTruncated": String(!queue.isEmpty),
            "primaryCoverVisible": String(primaryCoverVisible),
            "coverWindowVisible": String(windows.contains {
                $0.accessibilityIdentifier == "MediaVault.ScenePrivacyCoverWindow" && !$0.isHidden && $0.alpha > 0
            }),
            "visibleElevatedWindowCount": String(windows.count { !$0.isHidden && $0.windowLevel > .normal }),
            "lastCoordinatorNativeBarrier": latest["nativeBarrier"] ?? "unknown",
            "lastCoordinatorCoverVisible": latest["coverVisible"] ?? "unknown",
            "readoutBounds": String(describing: readoutProbe?.bounds),
        ]
        guard state != lastAuthenticationGeometry else {
            return
        }

        lastAuthenticationGeometry = state
        authenticationGeometryCount += 1
        evidence.record("authenticationPostLayoutGeometry", state)
    }

    func registerReadoutProbe(_ probe: BrowserDownloadReadoutAccessibilityProbe.ProbeView) {
        readoutProbe = probe
    }

    private func recordNativeQualification(_ event: String, fields: [String: String]) {
        evidence.record(event, fields)
        if event == "rootLayoutConfirmed" {
            readoutProbe?.sample(
                source: "rootLayoutConfirmed",
                rootPhase: String(describing: store.vault.phase),
            )
        }
        guard BrowserDownloadProductionQualification.automaticIngestionEnabled,
              event == "authenticationChanged" || event == "rootLayoutConfirmed" else {
            return
        }

        evidence.record("diagnosticRootState", [
            "source": event,
            "phase": String(describing: store.vault.phase),
            "privacyGeneration": String(owner.snapshot.generation),
            "ingestionGeneration": String(library.currentDownloadIngestionGeneration),
            "returnPending": String(store.applicationReturnPending),
        ])
    }

    /// Publishes startup metadata only after real foreground delivery and host preparation.
    private func updateObservationPreparation(_ preparation: BrowserDownloadObservationPreparation) {
        var next = preparation
        if next.canPublish {
            let receipt = observationController.receipt
            let context = observationContext
            if receipt.context == context, let data = try? JSONEncoder().encode(receipt) {
                observationReceiptJSON = String(decoding: data, as: UTF8.self)
                _ = next.markPublished(context: context, revision: next.revision)
            }
        }
        observationPreparation = next
    }

    func observeObservationScenePhase(_ phase: String, ingestionBefore: UInt64? = nil) {
        var preparation = observationPreparation ?? .init(processNonce: observationProcessNonce)
        let generation = library.currentDownloadIngestionGeneration
        preparation.observePhase(
            .init(rawValue: phase) ?? .unknown,
            ingestionBefore: ingestionBefore ?? generation,
            ingestionAfter: generation,
        )
        updateObservationPreparation(preparation)
    }

    private func refreshObservationPreparationContext() {
        guard var preparation = observationPreparation,
              let publishedContext = preparation.publishedContext,
              publishedContext != observationContext
        else {
            return
        }

        preparation.contextDidChange()
        updateObservationPreparation(preparation)
    }

    func start() async {
        if observationReceiptJSON.isEmpty,
           let data = try? JSONEncoder().encode(observationController.receipt) {
            observationReceiptJSON = String(decoding: data, as: UTF8.self)
        }
        startAuthenticationDiagnostics()

        guard !started else {
            return
        }

        started = true
        await recordLibraryStartup()
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
                observationController.contextDidChange()
                refreshObservationPreparationContext()
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
            var preparation = observationPreparation ?? .init(processNonce: observationProcessNonce)
            preparation.markStartupComplete()
            updateObservationPreparation(preparation)
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
        observationsJSON = evidence.observationsJSON
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
        observationsJSON = evidence.observationsJSON
    }

    func applyQualificationScenePhase(
        _ phase: String,
        applicationPhase: VaultApplicationScenePhase,
    ) {
        let generationBefore = owner.snapshot.generation
        let ingestionBefore = library.currentDownloadIngestionGeneration
        store.send(.applicationPhaseChanged(applicationPhase))
        observeObservationScenePhase(phase, ingestionBefore: ingestionBefore)
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
        observationsJSON = evidence.observationsJSON
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
              identity.route == run.route, identity.requestID == run.requestID,
              sameOrigin
        else {
            observationsJSON = evidence.observationsJSON
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
        observationsJSON = evidence.observationsJSON
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
                "fixtureBytesMatch": String(bytes == (
                    slowKnownRun?.operationID == id.rawValue.uuidString && slowKnownRun?.route == "finite-continuation"
                        ? BrowserDownloadLoopbackServer.slowPayload
                        : BrowserDownloadLoopbackServer.fixturePDF
                )),
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
                    Button("Refresh observations") { process.refreshObservations() }
                        .accessibilityIdentifier("downloadQualificationRefreshObservations")
                    Text("Sentinel: " + process.securitySentinel.stage)
                        .font(.caption2)
                        .accessibilityIdentifier("downloadQualificationSecuritySentinelStatus")
                        .accessibilityValue(process.securitySentinel.stageSummary)
                }
                ZStack(alignment: .topLeading) {
                    // The receipt must not reserve additional diagnostic inset space.
                    Text("Observation receipt")
                        .font(.caption2)
                        .frame(width: 1, height: 1)
                        .clipped()
                        .allowsHitTesting(false)
                        .accessibilityIdentifier("downloadQualificationObservationReceipt")
                        .accessibilityValue(process.observationReceiptJSON)
                    Text("Observation preparation")
                        .font(.caption2)
                        .frame(width: 1, height: 1)
                        .clipped()
                        .allowsHitTesting(false)
                        .accessibilityIdentifier("downloadQualificationObservationPreparation")
                        .accessibilityValue(process.observationPreparationJSON)
                    evidenceReadout(
                        "Qualification observations",
                        identifier: "downloadQualificationObservations",
                        lastRefresh: process.observationsJSON,
                        read: { process.evidence.observationsJSON },
                    )
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
            .background {
                if BrowserDownloadProductionQualification.automaticIngestionEnabled {
                    BrowserDownloadReadoutAccessibilityProbe(
                        fields: [
                            "phase": String(describing: process.store.vault.phase),
                            "privacyGeneration": String(process.owner.snapshot.generation),
                            "ingestionGeneration": String(process.library.currentDownloadIngestionGeneration),
                            "requestedHidden": String(process.store.vault.phase == .authentication),
                        ],
                        record: { process.recordReadoutLayout($0) },
                        register: { process.registerReadoutProbe($0) },
                    )
                }
            }
            // The production credential form lays out independently of this diagnostic inset.
            // Keep the panel from obscuring or intercepting its genuine secure-field input.
            .opacity(process.store.vault.phase == .authentication ? 0 : 1)
            .allowsHitTesting(process.store.vault.phase != .authentication)
            .accessibilityHidden(process.store.vault.phase == .authentication)
            // Rebuild the DEBUG diagnostic container across credential visibility changes.
            // The credential form and production Root keep their existing identities and concealment.
            .id(BrowserDownloadProductionQualification.automaticIngestionEnabled
                && process.store.vault.phase == .authentication)
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
                process.applyQualificationScenePhase(phase, applicationPhase: applicationPhase)
            } else {
                process.observeObservationScenePhase(phase)
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
            process.evidence.observationsJSON
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

/// Observes the existing diagnostic subtree without adding an accessibility element or changing layout.
@MainActor
private struct BrowserDownloadReadoutAccessibilityProbe: UIViewRepresentable {
    let fields: [String: String]
    let record: @MainActor ([String: String]) -> Void
    let register: @MainActor (ProbeView) -> Void

    func makeUIView(context _: Context) -> ProbeView {
        let view = ProbeView()
        view.isUserInteractionEnabled = false
        view.isAccessibilityElement = false
        return view
    }

    func updateUIView(_ view: ProbeView, context _: Context) {
        view.fields = fields
        view.record = record
        register(view)
        view.sample(source: "viewUpdate")
    }

    final class ProbeView: UIView {
        private let mountID = UUID().uuidString
        private var lastSample: [String: String] = [:]
        var fields: [String: String] = [:]
        var record: @MainActor ([String: String]) -> Void = { _ in }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            sample()
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            sample()
        }

        func sample(source: String = "readoutLayout", rootPhase: String? = nil) {
            var ancestors: [UIView] = []
            var ancestor: UIView? = self
            while let current = ancestor {
                ancestors.append(current)
                ancestor = current.superview
            }
            var state = fields
            state["sampleSource"] = source
            state["sourceRootPhase"] = rootPhase
            state["mountID"] = mountID
            state["mounted"] = String(window != nil)
            state["readoutHasBounds"] = String(bounds.width > 0 && bounds.height > 0)
            state["windowHasBounds"] = String(window.map { $0.bounds.width > 0 && $0.bounds.height > 0 } ?? false)
            state["windowKey"] = String(window?.isKeyWindow == true)
            state["windowHidden"] = String(window?.isHidden == true)
            state["windowAccessibilityHidden"] = String(window?.accessibilityElementsHidden == true)
            state["ancestorCount"] = String(ancestors.count)
            state["hiddenAncestorCount"] = String(ancestors.count { $0.isHidden })
            state["transparentAncestorCount"] = String(ancestors.count { $0.alpha == 0 })
            state["accessibilityHiddenAncestorCount"] = String(ancestors.count { $0.accessibilityElementsHidden })
            guard state != lastSample else {
                return
            }

            lastSample = state
            record(state)
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

    let runID = UUID().uuidString
    private var observations: [[String: String]] = []
    var observationEvents: [[String: String]] {
        observations
    }

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
        object["processID"] = String(ProcessInfo.processInfo.processIdentifier)
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
            // Frequent progress snapshots must not evict this run's admission and Lock witnesses.
            // The UI copy stays bounded; the JSONL file still receives every observation.
            if BrowserDownloadProductionQualification.activeDownloadHomeEnabled
                || BrowserDownloadProductionQualification.delayedHandoffLockEnabled {
                let milestones: Set = [
                    "fixtureNavigationRequested",
                    "policyDownloadAdmitted",
                    "pendingPolicyLockApplied",
                    "nativeDownloadHandoff",
                    "transferAdmitted",
                    "qualificationScenePhaseChanged",
                    "finiteResponseReleaseRequested",
                    "finiteResponseReleaseResult",
                    "finiteResponseCompleted",
                    "nativePostLockProgress",
                    "writerFinished",
                    "writerFailed",
                    "hiddenCompletion",
                    "retainedCompletionReconciled",
                    "nativeCancellationRequested",
                    "writerCancellationAcknowledged",
                    "pendingTransferCancelled",
                    "cleanupRemoval",
                    "cleanupInjectedFailure",
                    "scratchFailure",
                ]
                let routine = observations.firstIndex {
                    let observedEvent = $0["event"] ?? ""
                    return !milestones.contains(observedEvent) && !observedEvent.hasPrefix("slowKnown")
                }
                observations.remove(at: routine ?? 0)
            } else {
                observations.removeFirst(observations.count - 256)
            }
        }
        guard var data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else {
            return
        }

        if event == "diagnosticReadoutState" || event == "diagnosticRootState" {
            // Captured stdout preserves this sanitized trace when the app's AX channel is unavailable.
            print("[BrowserDownloadReadout] " + String(decoding: data, as: UTF8.self))
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
