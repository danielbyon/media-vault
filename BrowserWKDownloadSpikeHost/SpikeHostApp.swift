import Observation
import SwiftUI
import WebKit

@main
@MainActor
struct BrowserWKDownloadSpikeHostApp: App {
    @State private var harness = SpikeHarness()

    var body: some Scene {
        WindowGroup {
            SpikeHostView(harness: harness)
        }
    }
}

/// Presents one visible WebPage, explicit experiment controls, and run status.
@MainActor
private struct SpikeHostView: View {
    @Environment(\.scenePhase) private var scenePhase
    let harness: SpikeHarness

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Text(harness.state)
                    .font(.caption.monospaced())
                    .accessibilityIdentifier("spike-state")
                Spacer()
                Text(harness.activeProfile.title)
                    .font(.caption)
                    .accessibilityIdentifier("active-profile")
                Button("Cancel latest") {
                    harness.cancelLatest()
                }
                .accessibilityIdentifier("cancel-latest")
                Button("Retire Ephemeral") {
                    harness.retireEphemeralStore()
                }
                .accessibilityIdentifier("destroy-ephemeral-store")
            }
            .padding(.horizontal, 10)

            if harness.regressionControlsEnabled {
                Button("Replay previous terminal outcome") {
                    harness.replayPreviousTerminalOutcome()
                }
                .accessibilityIdentifier("replay-previous-terminal-outcome")
            }

            WebView(harness.activePage)
                .accessibilityIdentifier("spike-webpage")
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            ScrollView {
                Grid(horizontalSpacing: 8, verticalSpacing: 8) {
                    ForEach(0..<((SpikeScenario.all.count + 1) / 2), id: \.self) { row in
                        GridRow {
                            ForEach(0..<2, id: \.self) { column in
                                let index = row * 2 + column
                                if index < SpikeScenario.all.count {
                                    let scenario = SpikeScenario.all[index]
                                    Button(scenario.title) {
                                        harness.runScenario(scenario.id)
                                    }
                                    .frame(maxWidth: .infinity, minHeight: 34)
                                    .accessibilityIdentifier("scenario.\(scenario.id)")
                                } else {
                                    Color.clear.frame(maxWidth: .infinity, minHeight: 34)
                                }
                            }
                        }
                    }
                }
            }
            .frame(height: 148)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("scenario-list")
            .disabled(harness.isScenarioRunning)
            .padding(.horizontal, 10)

            Text(harness.scenarioStatus)
                .font(.caption.monospaced())
                .lineLimit(2)
                .accessibilityIdentifier("scenario-status")
                .padding(.horizontal, 10)
        }
        .task {
            await harness.startIfNeeded()
        }
        .onChange(of: scenePhase) { _, phase in
            harness.recordScenePhase(phase)
        }
    }
}

/// A WebKit profile with a public WebPage and its exact website data store.
@MainActor
final class SpikeProfileContext {
    let profile: SpikeProfile
    let profileID: String
    let websiteDataStore: WKWebsiteDataStore
    let websiteDataStoreID: String
    let page: WebPage
    let decider: SpikeNavigationDecider

    init(profile: SpikeProfile, harness: SpikeHarness) {
        self.profile = profile
        self.profileID = UUID().uuidString
        self.websiteDataStoreID = UUID().uuidString
        self.websiteDataStore = profile == .persistentPrivate
            ? WKWebsiteDataStore.default()
            : WKWebsiteDataStore.nonPersistent()
        let decider = SpikeNavigationDecider()
        var configuration = WebPage.Configuration()
        configuration.websiteDataStore = websiteDataStore
        self.page = WebPage(configuration: configuration, navigationDecider: decider)
        self.decider = decider
        decider.context = self
        decider.harness = harness
    }
}

/// Owns the selected WebPage, profile stores, coordinators, and experiment events.
@MainActor
@Observable
final class SpikeHarness {
    private(set) var state = "STARTING"
    private(set) var scenarioStatus = "idle"
    private(set) var isScenarioRunning = false
    var activeProfile: SpikeProfile = .persistentPrivate

    @ObservationIgnored private let baseURL: URL
    @ObservationIgnored private let secureBaseURL: URL
    @ObservationIgnored private let fixtureClient: SpikeFixtureClient
    @ObservationIgnored private var contexts: [SpikeProfile: SpikeProfileContext] = [:]
    @ObservationIgnored private var coordinators: [String: WKDownloadCoordinator] = [:]
    @ObservationIgnored private var latestOperationID: String?
    @ObservationIgnored private var runID = UUID().uuidString
    @ObservationIgnored private var scenarioStatusOwner: ScenarioStatusOwner?
    @ObservationIgnored private var terminalStatuses: [String: String] = [:]
    @ObservationIgnored private var previousTerminalOutcome: ScenarioTerminalSnapshot?
    @ObservationIgnored private var ephemeralRetirementInProgress = false

    var regressionControlsEnabled: Bool {
        ProcessInfo.processInfo.arguments.contains("--enable-spike-regression-controls")
    }

    init() {
        let environment = ProcessInfo.processInfo.environment["SPIKE_BASE_URL"]
        let baseURL = environment.flatMap(URL.init(string:)) ?? URL(string: "http://127.0.0.1:18753")!
        self.baseURL = baseURL
        self.secureBaseURL = URL(string: "https://127.0.0.1:18754")!
        self.fixtureClient = SpikeFixtureClient(baseURL: baseURL)
    }

    var activePage: WebPage {
        context(for: activeProfile).page
    }

    /// Checks the external fixture and loads the visible fixture menu.
    func startIfNeeded() async {
        guard state == "STARTING" else { return }
        record(
            kind: "app-launched",
            profileID: "process",
            profile: "process",
            operationID: runID,
            fields: [
                "process_id": String(ProcessInfo.processInfo.processIdentifier),
                "run_id": runID,
                "launch_arguments": ProcessInfo.processInfo.arguments.joined(separator: " "),
                "launch_options": "unavailable-to-SwiftUI-host"
            ]
        )
        guard await fixtureClient.health() else {
            state = "FIXTURE SERVER UNREACHABLE"
            record(
                kind: "fixture-health",
                profileID: "process",
                profile: "process",
                operationID: runID,
                fields: ["healthy": "false"]
            )
            return
        }
        let context = context(for: activeProfile)
        await loadMenu(in: context)
        state = "READY \(baseURL.host ?? "fixture")"
        record(
            kind: "fixture-health",
            profileID: context.profileID,
            profile: context.profile.rawValue,
            operationID: runID,
            fields: ["healthy": "true", "base_origin": SpikeRequestEvidence.safeOrigin(baseURL.absoluteString) ?? "unknown"]
        )
    }

    /// Starts the native experiment selected by one visible control.
    func runScenario(_ scenarioID: String) {
        guard !isScenarioRunning, !ephemeralRetirementInProgress else { return }
        let context = context(for: profile(for: scenarioID))
        let owner = ScenarioStatusOwner(
            scenarioRunID: UUID().uuidString,
            operationID: UUID().uuidString,
            scenarioID: scenarioID,
            profileID: context.profileID,
            websiteDataStoreID: context.websiteDataStoreID,
            parentOperationID: nil
        )
        scenarioStatusOwner = owner
        isScenarioRunning = true
        scenarioStatus = "\(scenarioID): running"
        Task { @MainActor in
            await performScenario(owner, context: context)
        }
    }

    /// Retires only the Ephemeral session after all of its active downloads reconcile.
    func retireEphemeralStore() {
        guard !ephemeralRetirementInProgress else { return }
        let context = context(for: .ephemeral)
        let owner = ScenarioStatusOwner(
            scenarioRunID: UUID().uuidString,
            operationID: UUID().uuidString,
            scenarioID: "ephemeral-destroy",
            profileID: context.profileID,
            websiteDataStoreID: context.websiteDataStoreID,
            parentOperationID: nil
        )
        scenarioStatusOwner = owner
        scenarioStatus = "ephemeral-destroy: running"
        isScenarioRunning = true
        Task { @MainActor in
            await destroyEphemeralStore(owner: owner, context: context)
        }
    }

    /// Replays an immutable prior terminal identity to exercise the stale-callback guard.
    func replayPreviousTerminalOutcome() {
        guard regressionControlsEnabled,
              let previousTerminalOutcome,
              let current = scenarioStatusOwner
        else { return }
        applyScenarioTerminalOutcome(
            previousTerminalOutcome,
            status: "failed-replayed-old-terminal",
            source: "regression-replay",
            currentOwner: current
        )
    }

    /// Cancels the most recently retained active WKDownload.
    func cancelLatest() {
        guard let latestOperationID,
              let coordinator = coordinators[latestOperationID]
        else { return }
        coordinator.cancel()
    }

    func recordScenePhase(_ phase: ScenePhase) {
        record(
            kind: "scene-phase",
            profileID: "process",
            profile: "process",
            operationID: runID,
            fields: ["phase": String(describing: phase)]
        )
    }

    func record(
        kind: String,
        profileID: String,
        profile: String,
        operationID: String,
        fields: [String: String]
    ) {
        let event = SpikeEvent(
            kind: kind,
            timestamp: Date().timeIntervalSince1970,
            profileID: profileID,
            profile: profile,
            operationID: operationID,
            fields: fields
        )
        Task { await fixtureClient.post(event) }
    }

    func beginDownload(
        request: URLRequest,
        intent: SpikeScenarioIntent,
        context: SpikeProfileContext
    ) {
        guard isScenarioRunning, scenarioStatusOwner == intent.statusOwner else {
            record(
                kind: "stale-download-intent-rejected",
                profileID: intent.profileID,
                profile: context.profile.rawValue,
                operationID: intent.operationID,
                fields: intent.statusOwner.identityFields,
            )
            return
        }

        let selectedStore: WKWebsiteDataStore
        let selectedStoreID: String
        if intent.useSeparateStore {
            selectedStore = WKWebsiteDataStore.nonPersistent()
            selectedStoreID = "separate-control-\(UUID().uuidString)"
        } else {
            selectedStore = context.websiteDataStore
            selectedStoreID = context.websiteDataStoreID
        }

        guard let url = request.url else {
            completeScenario(identity: intent.statusOwner, status: "failed-missing-request-url", source: "missing-request-url")
            return
        }
        let evidence = SpikeRequestEvidence.fields(for: request)
        do {
            let coordinator = try WKDownloadCoordinator(
                operationID: intent.operationID,
                scenarioRunID: intent.scenarioRunID,
                scenarioID: intent.scenarioID,
                context: context,
                harness: self,
                initialURL: url,
                requestEvidence: evidence,
                websiteDataStore: selectedStore,
                websiteDataStoreID: selectedStoreID,
                cancelAfterProgress: intent.cancelAfterProgress,
                shouldResumeCancellation: intent.shouldResumeCancellation
            )
            coordinators[intent.operationID] = coordinator
            latestOperationID = intent.operationID
            coordinator.start(request: request)
        } catch {
            record(
                kind: "download-coordinator-creation-failed",
                profileID: context.profileID,
                profile: context.profile.rawValue,
                operationID: intent.operationID,
                fields: ["error_type": String(describing: type(of: error))]
            )
            completeScenario(identity: intent.statusOwner, status: "failed-scratch-unavailable", source: "coordinator-creation-failed")
        }
    }

    func startResume(
        data: Data,
        context: SpikeProfileContext,
        scenarioRunID: String,
        scenarioID: String,
        initialURL: URL,
        requestEvidence: [String: String],
        parentOperationID: String
    ) {
        guard !data.isEmpty else {
            if let owner = scenarioStatusOwner, owner.scenarioRunID == scenarioRunID {
                completeScenario(identity: owner, status: "blocked-resume-data-unavailable", source: "resume-data-unavailable")
            }
            return
        }
        let operationID = UUID().uuidString
        let childOwner = ScenarioStatusOwner(
            scenarioRunID: scenarioRunID,
            operationID: operationID,
            scenarioID: scenarioID,
            profileID: context.profileID,
            websiteDataStoreID: context.websiteDataStoreID,
            parentOperationID: parentOperationID
        )
        do {
            let coordinator = try WKDownloadCoordinator(
                operationID: operationID,
                scenarioRunID: scenarioRunID,
                scenarioID: scenarioID,
                context: context,
                harness: self,
                initialURL: initialURL,
                requestEvidence: requestEvidence,
                websiteDataStore: context.websiteDataStore,
                websiteDataStoreID: context.websiteDataStoreID,
                parentOperationID: parentOperationID
            )
            coordinators[operationID] = coordinator
            latestOperationID = operationID
            if scenarioStatusOwner?.scenarioRunID == scenarioRunID,
               scenarioStatusOwner?.operationID == parentOperationID
            {
                scenarioStatusOwner = childOwner
                scenarioStatus = "\(scenarioID): resuming"
            }
            coordinator.resume(from: data)
        } catch {
            record(
                kind: "download-resume-setup-failed",
                profileID: context.profileID,
                profile: context.profile.rawValue,
                operationID: operationID,
                fields: ["error_type": String(describing: type(of: error)), "parent_operation_id": parentOperationID]
            )
            if scenarioStatusOwner?.scenarioRunID == scenarioRunID,
               scenarioStatusOwner?.operationID == parentOperationID
            {
                scenarioStatus = "\(scenarioID): failed-resume-setup"
                isScenarioRunning = false
            }
        }
    }

    func coordinatorDidFinish(_ coordinator: WKDownloadCoordinator, status: String) {
        terminalStatuses[coordinator.operationID] = status
        let wasRegistered = coordinators[coordinator.operationID] === coordinator
        if wasRegistered {
            coordinators[coordinator.operationID] = nil
        }
        var reconciliationFields = coordinator.identityFields
        reconciliationFields.merge([
            "terminal_status": status,
            "terminal_handling_reconciled": "true",
            "active_registry_entry_removed": String(wasRegistered)
        ]) { _, new in new }
        record(
            kind: "download-operation-reconciled",
            profileID: coordinator.profileID,
            profile: coordinator.profile.rawValue,
            operationID: coordinator.operationID,
            fields: reconciliationFields
        )
        guard let owner = scenarioStatusOwner,
              owner.scenarioRunID == coordinator.scenarioRunID,
              owner.operationID == coordinator.operationID
        else {
            recordStaleTerminal(
                coordinator.statusOwner,
                status: status,
                source: "download-callback",
                destinationRelativePath: coordinator.destinationRelativePath
            )
            return
        }
        guard status != "cancelled-resuming" else { return }
        scenarioStatus = "\(coordinator.scenarioID): \(status)"
        isScenarioRunning = false
    }

    func visibleResponseObserved(
        intent: SpikeScenarioIntent,
        context: SpikeProfileContext,
        response: URLResponse?,
        responsePolicy: String
    ) {
        record(
            kind: "visible-webpage-control-response-observed",
            profileID: context.profileID,
            profile: context.profile.rawValue,
            operationID: intent.operationID,
            fields: intent.statusOwner.identityFields.merging([
                "scenario": intent.scenarioID,
                "response_mime_type": response?.mimeType ?? "unknown",
                "webpage_response_policy": responsePolicy,
                "webpage_file_lifecycle_available": "false"
            ]) { current, _ in current }
        )
        completeScenario(
            identity: intent.statusOwner,
            status: "complete-visible-control",
            source: "visible-page-response"
        )
    }

    func blobActionUnavailable(intent: SpikeScenarioIntent, context: SpikeProfileContext) {
        record(
            kind: "blob-action-page-bound",
            profileID: context.profileID,
            profile: context.profile.rawValue,
            operationID: intent.operationID,
            fields: intent.statusOwner.identityFields.merging([
                "scheme": "blob",
                "companion_request_started": "false",
                "reason": "blob-URL-is-bound-to-originating-page-context"
            ]) { current, _ in current }
        )
        completeScenario(
            identity: intent.statusOwner,
            status: "blocked-page-bound-blob",
            source: "blob-action"
        )
    }

    private func performScenario(_ owner: ScenarioStatusOwner, context: SpikeProfileContext) async {
        let scenarioID = owner.scenarioID
        guard let spec = SpikeScenario.all.first(where: { $0.id == scenarioID }) else {
            completeScenario(identity: owner, status: "failed-unknown-scenario", source: "unknown-scenario")
            return
        }
        guard context.profileID == owner.profileID,
              context.websiteDataStoreID == owner.websiteDataStoreID
        else {
            completeScenario(identity: owner, status: "failed-profile-identity-changed", source: "profile-capture")
            return
        }
        if scenarioID == "ephemeral-destroy" {
            await destroyEphemeralStore(owner: owner, context: context)
            return
        }

        activeProfile = context.profile
        record(
            kind: "scenario-selected",
            profileID: owner.profileID,
            profile: context.profile.rawValue,
            operationID: owner.operationID,
            fields: owner.identityFields.merging([
                "scenario": scenarioID,
                "selection": "explicit-native-experiment-control"
            ]) { current, _ in current }
        )

        await loadMenu(in: context)
        guard scenarioStatusOwner == owner else { return }
        await recordCookieMetadata(
            for: context,
            url: baseURL,
            scenarioRunID: owner.scenarioRunID,
            operationID: owner.operationID,
            purpose: "before-request"
        )

        if scenarioID == "secure-cookie" || scenarioID == "visible-secure-cookie" {
            await load(URLRequest(url: secureBaseURL.appending(path: "/secure/seed")), in: context)
            guard scenarioStatusOwner == owner else { return }
            await recordCookieMetadata(
                for: context,
                url: secureBaseURL,
                scenarioRunID: owner.scenarioRunID,
                operationID: owner.operationID,
                purpose: "after-controlled-https-cookie-seed"
            )
        }

        let intent = SpikeScenarioIntent(
            scenarioID: scenarioID,
            operationID: owner.operationID,
            scenarioRunID: owner.scenarioRunID,
            profileID: owner.profileID,
            websiteDataStoreID: owner.websiteDataStoreID,
            parentOperationID: owner.parentOperationID,
            anchorID: spec.anchorID,
            expectedPath: spec.expectedPath,
            mode: spec.mode,
            useSeparateStore: scenarioID == "separate-store",
            cancelAfterProgress: scenarioID == "cancel-resume",
            shouldResumeCancellation: scenarioID == "cancel-resume"
        )
        context.decider.arm(intent)
        do {
            let script: String
            if scenarioID == "post" {
                script = "document.getElementById('post-form').requestSubmit();"
            } else {
                script = "document.getElementById('\(spec.anchorID)').click();"
            }
            _ = try await context.page.callJavaScript(script)
        } catch {
            record(
                kind: "scenario-trigger-failed",
                profileID: owner.profileID,
                profile: context.profile.rawValue,
                operationID: owner.operationID,
                fields: owner.identityFields.merging([
                    "scenario": scenarioID,
                    "error_type": String(describing: type(of: error))
                ]) { current, _ in current }
            )
            completeScenario(identity: owner, status: "failed-trigger", source: "webpage-trigger")
            return
        }

        if scenarioID == "profile-switch" {
            activeProfile = .ephemeral
            let replacement = self.context(for: .ephemeral)
            record(
                kind: "active-profile-switched-during-download",
                profileID: owner.profileID,
                profile: context.profile.rawValue,
                operationID: owner.operationID,
                fields: owner.identityFields.merging([
                    "active_profile_after_switch": replacement.profile.rawValue,
                    "active_profile_id_after_switch": replacement.profileID,
                    "active_store_id_after_switch": replacement.websiteDataStoreID,
                    "underlying_session_destroyed": "false"
                ]) { current, _ in current }
            )
        }

        if scenarioID == "ephemeral-active-teardown" || scenarioID == "persistent-survivor-teardown" {
            completeScenario(identity: owner, status: "started", source: "concurrent-teardown-probe", releaseControl: true)
            return
        }
        if scenarioID == "background-transfer" || scenarioID == "termination-transfer" {
            completeScenario(identity: owner, status: "started", source: "lifecycle-transfer-started")
            return
        }
        if scenarioID == "late-callback-probe" {
            let coordinator = coordinators[owner.operationID]
            let progressObserved = await waitForDownloadProgress(coordinator, timeout: 6)
            if progressObserved {
                try? await Task.sleep(for: .milliseconds(500))
            }
            await settleScenarioTimeout(owner: owner, timeout: 4.0)
            return
        }

        if scenarioID == "blob" {
            try? await Task.sleep(for: .seconds(2))
            if scenarioStatusOwner == owner, isScenarioRunning, scenarioStatus == "blob: running" {
                blobActionUnavailable(intent: intent, context: context)
            }
            return
        }

        let deadline = Date().addingTimeInterval(32)
        while Date() < deadline,
              scenarioStatusOwner?.scenarioRunID == owner.scenarioRunID,
              isScenarioRunning
        {
            try? await Task.sleep(for: .milliseconds(100))
        }
        if let currentOwner = scenarioStatusOwner,
           currentOwner.scenarioRunID == owner.scenarioRunID,
           isScenarioRunning
        {
            await settleScenarioTimeout(owner: currentOwner, timeout: 4.0)
        }
    }

    private func settleScenarioTimeout(owner: ScenarioStatusOwner, timeout: TimeInterval) async {
        guard scenarioStatusOwner == owner else { return }
        let coordinator = coordinators[owner.operationID]
        coordinator?.cancelForScenarioTimeout()
        let deadline = Date().addingTimeInterval(timeout)
        while let coordinator, !coordinator.isReconciled, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }

        var transferObservation: SpikeFixtureTransferObservation?
        if let coordinator, coordinator.requiresServerTransferObservation {
            transferObservation = await waitForTransferObservation(
                path: coordinator.initialURL.path,
                deadline: deadline
            )
            if let transferObservation {
                coordinator.recordServerTransferObservation(transferObservation)
            }
        }

        let reconciled = coordinator?.isReconciled == true
        let serverReconciled = coordinator?.requiresServerTransferObservation != true || transferObservation != nil
        let settled = reconciled && serverReconciled
        let status = settled ? "blocked-timeout-cancelled" : "incomplete-timeout-unreconciled"
        record(
            kind: "scenario-timeout",
            profileID: owner.profileID,
            profile: profile(for: owner.scenarioID).rawValue,
            operationID: owner.operationID,
            fields: owner.identityFields.merging([
                "cancellation_requested": String(coordinator != nil),
                "terminal_callback_reconciled": String(reconciled),
                "terminal_status": terminalStatuses[owner.operationID] ?? "unobserved",
                "server_transfer_observed": String(serverReconciled),
                "transfer_body_complete": transferObservation.map { String($0.bodyComplete) } ?? "unobserved",
                "status": status
            ]) { current, _ in current }
        )
        guard scenarioStatusOwner == owner else { return }
        scenarioStatus = "\(owner.scenarioID): \(status)"
        isScenarioRunning = false
        scenarioStatusOwner = nil
        if settled {
            previousTerminalOutcome = ScenarioTerminalSnapshot(
                owner: owner,
                destinationRelativePath: coordinator?.destinationRelativePath ?? "unassigned"
            )
        }
    }

    private func waitForTransferObservation(
        path: String,
        deadline: Date
    ) async -> SpikeFixtureTransferObservation? {
        while Date() < deadline {
            if let observation = await fixtureClient.transferObservation(path: path) {
                return observation
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return nil
    }

    private func waitForDownloadProgress(
        _ coordinator: WKDownloadCoordinator?,
        timeout: TimeInterval
    ) async -> Bool {
        guard let coordinator else { return false }
        let deadline = Date().addingTimeInterval(timeout)
        while !coordinator.hasObservedProgress, !coordinator.isReconciled, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
        return coordinator.hasObservedProgress
    }

    private func completeScenario(
        identity: ScenarioStatusOwner,
        status: String,
        source: String,
        releaseControl: Bool = false
    ) {
        guard scenarioStatusOwner == identity else {
            recordStaleTerminal(identity, status: status, source: source, destinationRelativePath: "unassigned")
            return
        }
        scenarioStatus = "\(identity.scenarioID): \(status)"
        isScenarioRunning = false
        if releaseControl {
            scenarioStatusOwner = nil
        }
    }

    private func applyScenarioTerminalOutcome(
        _ snapshot: ScenarioTerminalSnapshot,
        status: String,
        source: String,
        currentOwner: ScenarioStatusOwner
    ) {
        guard currentOwner == snapshot.owner else {
            recordStaleTerminal(
                snapshot.owner,
                status: status,
                source: source,
                destinationRelativePath: snapshot.destinationRelativePath,
                currentOwner: currentOwner
            )
            return
        }
        scenarioStatus = "\(snapshot.owner.scenarioID): \(status)"
        isScenarioRunning = false
    }

    private func recordStaleTerminal(
        _ identity: ScenarioStatusOwner,
        status: String,
        source: String,
        destinationRelativePath: String,
        currentOwner: ScenarioStatusOwner? = nil
    ) {
        let current = currentOwner ?? scenarioStatusOwner
        let before = scenarioStatus
        var fields = identity.identityFields
        fields.merge([
            "source": source,
            "outcome_status": status,
            "outcome_scenario_run_id": identity.scenarioRunID,
            "outcome_operation_id": identity.operationID,
            "current_scenario_run_id": current?.scenarioRunID ?? "none",
            "current_status_operation_id": current?.operationID ?? "none",
            "scenario_status_before": before,
            "scenario_status_after": scenarioStatus,
            "destination_relative_path": destinationRelativePath,
            "status_mutated": "false"
        ]) { _, new in new }
        record(
            kind: "stale-scenario-terminal-ignored",
            profileID: identity.profileID,
            profile: profile(for: identity.scenarioID).rawValue,
            operationID: identity.operationID,
            fields: fields
        )
    }

    private func destroyEphemeralStore(owner: ScenarioStatusOwner, context oldContext: SpikeProfileContext) async {
        guard !ephemeralRetirementInProgress else { return }
        guard contexts[.ephemeral] === oldContext,
              owner.profileID == oldContext.profileID,
              owner.websiteDataStoreID == oldContext.websiteDataStoreID
        else {
            completeScenario(identity: owner, status: "incomplete-profile-identity-changed", source: "ephemeral-teardown")
            return
        }

        ephemeralRetirementInProgress = true
        defer { ephemeralRetirementInProgress = false }
        let retiringCoordinators = coordinators.values.filter { $0.profileID == oldContext.profileID }
        let unrelatedOperationIDs = coordinators.values
            .filter { $0.profileID != oldContext.profileID }
            .map(\.operationID)
            .sorted()
        record(
            kind: "ephemeral-store-retirement-started",
            profileID: oldContext.profileID,
            profile: oldContext.profile.rawValue,
            operationID: owner.operationID,
            fields: owner.identityFields.merging([
                "active_retiring_operation_ids": retiringCoordinators.map(\.operationID).sorted().joined(separator: ","),
                "unrelated_operation_ids_preserved": unrelatedOperationIDs.joined(separator: ","),
                "active_registry_count": String(retiringCoordinators.count)
            ]) { current, _ in current }
        )

        for coordinator in retiringCoordinators {
            coordinator.beginProfileRetirement()
        }

        let deadline = Date().addingTimeInterval(8)
        while retiringCoordinators.contains(where: { !$0.isReconciled }), Date() < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }

        var unresolvedOperationIDs = retiringCoordinators
            .filter { !$0.isReconciled }
            .map(\.operationID)
        for coordinator in retiringCoordinators where coordinator.isReconciled && coordinator.requiresServerTransferObservation {
            if Date() >= deadline {
                unresolvedOperationIDs.append(coordinator.operationID)
                continue
            }
            guard let observation = await waitForTransferObservation(path: coordinator.initialURL.path, deadline: deadline) else {
                unresolvedOperationIDs.append(coordinator.operationID)
                continue
            }
            coordinator.recordServerTransferObservation(observation)
        }

        if !unresolvedOperationIDs.isEmpty {
            let unresolved = Array(Set(unresolvedOperationIDs)).sorted()
            record(
                kind: "ephemeral-store-teardown-incomplete",
                profileID: oldContext.profileID,
                profile: oldContext.profile.rawValue,
                operationID: owner.operationID,
                fields: owner.identityFields.merging([
                    "outstanding_operation_ids": unresolved.joined(separator: ","),
                    "retiring_context_retained": "true",
                    "replacement_store_created": "false",
                    "teardown_reconciled": "false"
                ]) { current, _ in current }
            )
            completeScenario(identity: owner, status: "incomplete-teardown-unreconciled", source: "ephemeral-teardown")
            return
        }

        let oldCookies = await oldContext.websiteDataStore.httpCookieStore.cookies(for: baseURL)
        await oldContext.websiteDataStore.removeData(
            ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(),
            modifiedSince: .distantPast
        )
        guard contexts[.ephemeral] === oldContext else {
            record(
                kind: "ephemeral-store-teardown-incomplete",
                profileID: oldContext.profileID,
                profile: oldContext.profile.rawValue,
                operationID: owner.operationID,
                fields: owner.identityFields.merging([
                    "outstanding_operation_ids": "none",
                    "retiring_context_retained": "true",
                    "replacement_store_created": "false",
                    "teardown_reconciled": "false",
                    "reason": "profile-context-changed-during-data-removal"
                ]) { current, _ in current }
            )
            completeScenario(identity: owner, status: "incomplete-profile-context-changed", source: "ephemeral-teardown")
            return
        }

        contexts[.ephemeral] = nil
        let replacement = context(for: .ephemeral)
        let replacementCookies = await replacement.websiteDataStore.httpCookieStore.cookies(for: baseURL)
        activeProfile = .ephemeral
        record(
            kind: "ephemeral-store-destroyed",
            profileID: oldContext.profileID,
            profile: SpikeProfile.ephemeral.rawValue,
            operationID: owner.operationID,
            fields: owner.identityFields.merging([
                "old_store_id": oldContext.websiteDataStoreID,
                "replacement_store_id": replacement.websiteDataStoreID,
                "retired_profile_id": oldContext.profileID,
                "profile_identity_changed": String(oldContext.profileID != replacement.profileID),
                "old_cookie_names": oldCookies.map(\.name).sorted().joined(separator: ","),
                "replacement_cookie_count": String(replacementCookies.count),
                "retired_operation_ids": retiringCoordinators.map(\.operationID).sorted().joined(separator: ","),
                "unrelated_operation_ids_preserved": unrelatedOperationIDs.joined(separator: ","),
                "cookie_values_recorded": "false",
                "teardown_reconciled": "true",
                "retiring_context_retained_through_reconciliation": "true"
            ]) { current, _ in current }
        )
        completeScenario(identity: owner, status: "complete", source: "ephemeral-teardown")
    }

    private func profile(for scenarioID: String) -> SpikeProfile {
        switch scenarioID {
        case "ephemeral-cookie", "ephemeral-active-teardown", "ephemeral-destroy": .ephemeral
        default: .persistentPrivate
        }
    }

    private func loadMenu(in context: SpikeProfileContext) async {
        await load(URLRequest(url: baseURL.appending(path: "/")), in: context)
    }

    private func load(_ request: URLRequest, in context: SpikeProfileContext) async {
        let navigation = context.page.load(request)
        do {
            for try await _ in navigation { }
        } catch {
            record(
                kind: "visible-page-navigation-error",
                profileID: context.profileID,
                profile: context.profile.rawValue,
                operationID: UUID().uuidString,
                fields: ["error_type": String(describing: type(of: error))]
            )
        }
    }

    private func recordCookieMetadata(
        for context: SpikeProfileContext,
        url: URL,
        scenarioRunID: String,
        operationID: String,
        purpose: String
    ) async {
        let store = context.websiteDataStore
        let storeID = context.websiteDataStoreID
        let profileID = context.profileID
        let profile = context.profile
        let cookies = await store.httpCookieStore.cookies(for: url)
        record(
            kind: "cookie-lookup",
            profileID: profileID,
            profile: profile.rawValue,
            operationID: operationID,
            fields: [
                "purpose": purpose,
                "store_id": storeID,
                "website_data_store_id": storeID,
                "scenario_run_id": scenarioRunID,
                "scratch_profile_id": profileID,
                "scratch_operation_id": operationID,
                "store_is_originating_page_store": String(store === context.websiteDataStore),
                "cookie_names": cookies.map(\.name).sorted().joined(separator: ","),
                "http_only_cookie_names": cookies.filter(\.isHTTPOnly).map(\.name).sorted().joined(separator: ","),
                "secure_cookie_names": cookies.filter(\.isSecure).map(\.name).sorted().joined(separator: ","),
                "cookie_values_recorded": "false"
            ]
        )
    }

    private func context(for profile: SpikeProfile) -> SpikeProfileContext {
        if let context = contexts[profile] { return context }
        let context = SpikeProfileContext(profile: profile, harness: self)
        contexts[profile] = context
        return context
    }

}

enum SpikeProfile: String, CaseIterable {
    case persistentPrivate = "persistent-private"
    case ephemeral

    var title: String {
        switch self {
        case .persistentPrivate: "Persistent-Private"
        case .ephemeral: "Ephemeral"
        }
    }
}

enum SpikeIntentMode {
    case visible
    case preRequest
    case responseTriggered
}

struct ScenarioStatusOwner: Equatable {
    let scenarioRunID: String
    let operationID: String
    let scenarioID: String
    let profileID: String
    let websiteDataStoreID: String
    let parentOperationID: String?

    var identityFields: [String: String] {
        [
            "scenario_run_id": scenarioRunID,
            "website_data_store_id": websiteDataStoreID,
            "parent_operation_id": parentOperationID ?? "none",
            "parent_resume_operation_id": parentOperationID ?? "none",
            "scratch_profile_id": profileID,
            "scratch_operation_id": operationID,
            "destination_relative_path": "unassigned"
        ]
    }
}

struct ScenarioTerminalSnapshot {
    let owner: ScenarioStatusOwner
    let destinationRelativePath: String
}

struct SpikeScenarioIntent {
    let scenarioID: String
    let operationID: String
    let scenarioRunID: String
    let profileID: String
    let websiteDataStoreID: String
    let parentOperationID: String?
    let anchorID: String
    let expectedPath: String
    let mode: SpikeIntentMode
    let useSeparateStore: Bool
    let cancelAfterProgress: Bool
    let shouldResumeCancellation: Bool

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
}

struct SpikeScenario {
    let id: String
    let title: String
    let anchorID: String
    let expectedPath: String
    let mode: SpikeIntentMode

    static let all: [SpikeScenario] = [
        .init(id: "ordinary", title: "Ordinary navigation", anchorID: "ordinary-link", expectedPath: "/normal", mode: .visible),
        .init(id: "visible-control", title: "Visible attachment control", anchorID: "visible-control-link", expectedPath: "/control/attachment", mode: .visible),
        .init(id: "visible-image", title: "Visible still image control", anchorID: "visible-image-link", expectedPath: "/control/direct-image", mode: .visible),
        .init(id: "direct-image", title: "Companion still image", anchorID: "direct-image-link", expectedPath: "/resource/direct-image", mode: .preRequest),
        .init(id: "visible-video", title: "Visible video control", anchorID: "visible-video-link", expectedPath: "/control/direct-video", mode: .visible),
        .init(id: "direct-video", title: "Companion direct video", anchorID: "direct-video-link", expectedPath: "/resource/direct-video", mode: .preRequest),
        .init(id: "visible-basic", title: "Visible Basic authentication", anchorID: "basic-link", expectedPath: "/basic/resource", mode: .visible),
        .init(id: "attachment", title: "Companion attachment", anchorID: "attachment-link", expectedPath: "/resource/attachment", mode: .preRequest),
        .init(id: "same-origin", title: "Same-origin redirect", anchorID: "same-origin-link", expectedPath: "/redirect/same-origin", mode: .preRequest),
        .init(id: "cross-origin", title: "Cross-origin redirect", anchorID: "cross-origin-link", expectedPath: "/redirect/cross-origin", mode: .preRequest),
        .init(id: "https-downgrade", title: "HTTPS downgrade", anchorID: "downgrade-link", expectedPath: "/redirect/https-downgrade", mode: .preRequest),
        .init(id: "post", title: "Contained POST", anchorID: "post-form", expectedPath: "/post", mode: .preRequest),
        .init(id: "signed-pre-request", title: "Signed before request", anchorID: "signed-pre-link", expectedPath: "/signed/pre-request", mode: .preRequest),
        .init(id: "signed-response", title: "Signed response replay", anchorID: "signed-response-link", expectedPath: "/signed/response-triggered", mode: .responseTriggered),
        .init(id: "http-cookie", title: "HttpOnly cookie", anchorID: "cookie-link", expectedPath: "/cookie/resource", mode: .preRequest),
        .init(id: "separate-store", title: "Separate-store negative", anchorID: "cookie-link", expectedPath: "/cookie/resource", mode: .preRequest),
        .init(id: "basic-auth", title: "Basic authentication", anchorID: "basic-link", expectedPath: "/basic/resource", mode: .preRequest),
        .init(id: "secure-cookie", title: "Secure cookie over HTTPS", anchorID: "secure-resource-link", expectedPath: "/secure/resource", mode: .preRequest),
        .init(id: "visible-secure-cookie", title: "Visible Secure cookie control", anchorID: "secure-resource-link", expectedPath: "/secure/resource", mode: .visible),
        .init(id: "secure-cookie-http-negative", title: "Secure cookie HTTP negative", anchorID: "secure-http-negative-link", expectedPath: "/secure/resource", mode: .preRequest),
        .init(id: "blob", title: "Page-bound blob", anchorID: "blob-link", expectedPath: "blob:", mode: .preRequest),
        .init(id: "cancel-resume", title: "Cancel and resume", anchorID: "cancel-link", expectedPath: "/resource/slow-cancel", mode: .preRequest),
        .init(id: "profile-switch", title: "Switch profile in flight", anchorID: "profile-link", expectedPath: "/resource/slow-profile", mode: .preRequest),
        .init(id: "ephemeral-cookie", title: "Ephemeral cookie", anchorID: "cookie-link", expectedPath: "/cookie/resource", mode: .preRequest),
        .init(id: "ephemeral-active-teardown", title: "Ephemeral active teardown probe", anchorID: "ephemeral-teardown-link", expectedPath: "/resource/slow-ephemeral-teardown", mode: .preRequest),
        .init(id: "persistent-survivor-teardown", title: "Persistent teardown survivor probe", anchorID: "persistent-survivor-link", expectedPath: "/resource/slow-persistent-survivor", mode: .preRequest),
        .init(id: "late-callback-probe", title: "Timeout cancellation regression probe", anchorID: "late-callback-link", expectedPath: "/resource/slow-late-callback", mode: .preRequest),
        .init(id: "ephemeral-destroy", title: "Destroy Ephemeral store", anchorID: "", expectedPath: "", mode: .visible),
        .init(id: "background-transfer", title: "Background transfer", anchorID: "background-link", expectedPath: "/resource/slow-background", mode: .preRequest),
        .init(id: "termination-transfer", title: "Harness termination", anchorID: "termination-link", expectedPath: "/resource/slow-termination", mode: .preRequest)
    ]
}

/// Routes only an explicitly selected fixture action to the hidden companion.
@MainActor
final class SpikeNavigationDecider: WebPage.NavigationDeciding {
    weak var context: SpikeProfileContext?
    weak var harness: SpikeHarness?
    private var pendingIntent: SpikeScenarioIntent?
    private var responseRequest: URLRequest?

    func arm(_ intent: SpikeScenarioIntent) {
        pendingIntent = intent
        responseRequest = nil
    }

    func decidePolicy(
        for action: WebPage.NavigationAction,
        preferences: inout WebPage.NavigationPreferences
    ) async -> WKNavigationActionPolicy {
        guard let context, let harness,
              let url = action.request.url
        else {
            return .allow
        }

        guard let intent = pendingIntent else {
            return .allow
        }
        if intent.scenarioID == "blob", url.scheme?.lowercased() == "blob" {
            pendingIntent = nil
            harness.blobActionUnavailable(intent: intent, context: context)
            return .cancel
        }
        guard url.path == intent.expectedPath else {
            return .allow
        }

        let requestFields = SpikeRequestEvidence.fields(for: action.request)
        harness.record(
            kind: "webpage-action-observed",
            profileID: context.profileID,
            profile: context.profile.rawValue,
            operationID: intent.operationID,
            fields: requestFields.merging(intent.statusOwner.identityFields) { current, _ in current }.merging([
                "scenario": intent.scenarioID,
                "navigation_type": String(describing: action.navigationType),
                "should_perform_download": String(action.shouldPerformDownload),
                "intent_mode": Self.modeName(intent.mode),
                "request_preserved_without_reconstruction": "true"
            ]) { current, _ in current }
        )

        switch intent.mode {
        case .visible:
            responseRequest = action.request
            return .allow
        case .preRequest:
            pendingIntent = nil
            harness.beginDownload(request: action.request, intent: intent, context: context)
            return .cancel
        case .responseTriggered:
            responseRequest = action.request
            return .allow
        }
    }

    func decidePolicy(for response: WebPage.NavigationResponse) async -> WKNavigationResponsePolicy {
        guard let context, let harness,
              let intent = pendingIntent,
              let originalRequest = responseRequest,
              let responseURL = response.response.url,
              responseURL.path == intent.expectedPath
        else {
            return .allow
        }

        switch intent.mode {
        case .visible:
            pendingIntent = nil
            responseRequest = nil
            let shouldDownload = ["visible-control", "visible-image", "visible-video"].contains(intent.scenarioID)
            let policyName = shouldDownload ? "download" : "allow"
            harness.visibleResponseObserved(
                intent: intent,
                context: context,
                response: response.response,
                responsePolicy: policyName
            )
            return shouldDownload ? .download : .allow
        case .preRequest:
            return .allow
        case .responseTriggered:
            pendingIntent = nil
            responseRequest = nil
            harness.record(
                kind: "response-triggered-companion-replay",
                profileID: context.profileID,
                profile: context.profile.rawValue,
                operationID: intent.operationID,
                fields: [
                    "scenario": intent.scenarioID,
                    "response_url_origin": responseURL.host.map { "\(responseURL.scheme ?? "http")://\($0.lowercased())" } ?? "unknown",
                    "original_request_replayed": "true",
                    "request_mutated": "false",
                    "signed_token_recorded": "false"
                ]
            )
            harness.beginDownload(request: originalRequest, intent: intent, context: context)
            return .download
        }
    }

    func decideAuthenticationChallengeDisposition(
        for challenge: URLAuthenticationChallenge
    ) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        let host = challenge.protectionSpace.host.lowercased()
        let method = challenge.protectionSpace.authenticationMethod
        if method == NSURLAuthenticationMethodServerTrust,
           Self.isFixtureHost(host),
           let trust = challenge.protectionSpace.serverTrust
        {
            return (.useCredential, URLCredential(trust: trust))
        }
        if method == NSURLAuthenticationMethodHTTPBasic,
           Self.isFixtureHost(host),
           let intent = pendingIntent,
           ["basic-auth", "visible-basic"].contains(intent.scenarioID),
           let context,
           let harness
        {
            harness.record(
                kind: "webpage-authentication-challenge",
                profileID: context.profileID,
                profile: context.profile.rawValue,
                operationID: intent.operationID,
                fields: [
                    "origin": "http://\(host):\(challenge.protectionSpace.port)",
                    "method": "http-basic",
                    "identity_sha256_prefix": SpikeRequestEvidence.sanitizedIdentity("spike-basic-user"),
                    "credential_values_recorded": "false"
                ]
            )
            return (
                .useCredential,
                URLCredential(user: "spike-basic-user", password: UUID().uuidString, persistence: .forSession)
            )
        }
        return (.cancelAuthenticationChallenge, nil)
    }

    private static func modeName(_ mode: SpikeIntentMode) -> String {
        switch mode {
        case .visible: "visible"
        case .preRequest: "pre-request"
        case .responseTriggered: "response-triggered"
        }
    }

    private static func isFixtureHost(_ host: String) -> Bool {
        host == "127.0.0.1" || host == "localhost"
    }
}
