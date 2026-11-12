//
//  RootFeature.swift
//  MediaVault
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import BrowserFeature
import Combine
import ComposableArchitecture
import CoreFoundation
import DecoySupport
import Dependencies
import MediaLibrary
import PresentationSupport
import SwiftUI
import VaultFeature

/// The application-wide lifecycle phase used to start and evaluate an auto-lock grace period.
public enum VaultApplicationScenePhase: Equatable, Sendable {
    /// The application is foregrounded and can reveal its authenticated scenes.
    case active

    /// The application is temporarily inactive; no background grace period starts.
    case inactive

    /// The application has entered the background and may begin the shared grace period.
    case background

    /// The platform phase could not be interpreted, so configured vaults fail closed.
    case unknown
}

/// The application composition root for a registered decoy and the vault lifecycle.
@Reducer
public struct RootFeature {
    /// State owned by the application composition root.
    @ObservableState
    public struct State: Equatable, Sendable {
        /// The vault lifecycle and authenticated shell state.
        public var vault: VaultFeature.State

        /// The attempt currently waiting for hidden-credential evaluation.
        public var pendingHiddenAttemptID: DecoyHiddenEntryAttempt.ID?

        /// The vault session generation that owns the pending hidden-entry attempt.
        public var pendingHiddenSessionGeneration: UInt64?

        /// The monotonic instant when the whole application entered the background.
        public var autoLockBackgroundStartedAt: ContinuousClock.Instant?

        /// The timeout selected when the current background grace period began.
        public var autoLockTimeoutAtBackground: Duration?

        /// Keeps scene privacy covers in place until the application-wide active return is evaluated.
        public var applicationReturnPending: Bool

        /// The long-lived decoy surface associated with this root store.
        @ObservationStateIgnored
        public var decoySession: AnyDecoySession

        /// Creates root state for one already-composed decoy session.
        public init(
            decoySession: AnyDecoySession,
            vault: VaultFeature.State = .init(),
        ) {
            self.vault = vault
            self.decoySession = decoySession
            pendingHiddenAttemptID = nil
            pendingHiddenSessionGeneration = nil
            autoLockBackgroundStartedAt = nil
            autoLockTimeoutAtBackground = nil
            applicationReturnPending = false
        }

        /// Compares lifecycle and attempt state while ignoring the retained UI session reference.
        public static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.vault == rhs.vault
                && lhs.pendingHiddenAttemptID == rhs.pendingHiddenAttemptID
                && lhs.pendingHiddenSessionGeneration == rhs.pendingHiddenSessionGeneration
                && lhs.autoLockBackgroundStartedAt == rhs.autoLockBackgroundStartedAt
                && lhs.autoLockTimeoutAtBackground == rhs.autoLockTimeoutAtBackground
                && lhs.applicationReturnPending == rhs.applicationReturnPending
        }
    }

    /// Actions handled by the root and forwarded to child features.
    public enum Action: Equatable, Sendable {
        /// Starts root-owned lifecycle work.
        case task

        /// Applies the application-wide scene phase to the shared session lifecycle.
        case applicationPhaseChanged(VaultApplicationScenePhase)

        /// Reports local scene activation without changing the application-wide grace period.
        case sceneBecameActive

        /// Applies the selected emergency gesture for one foreground scene.
        case emergencyLockGestureRecognized(
            gesture: VaultEmergencyLockGesture,
            isForeground: Bool,
        )

        /// Receives a normalized attempt emitted by the active decoy session.
        case decoyAttempt(DecoyHiddenEntryAttempt)

        /// Forwards vault lifecycle and shell actions.
        case vault(VaultFeature.Action)
    }

    @Dependency(\.vaultSessionClock)
    var sessionClock

    @Dependency(\.mediaLibrary)
    var mediaLibrary

    @Dependency(\.browserProfileConfigurationFence)
    var browserProfileConfigurationFence

    private let definition: DecoyDefinition

    /// Creates the generic host for one statically registered decoy.
    ///
    /// - Parameter definition: The active decoy's declared triggers and session factory.
    public init(definition: DecoyDefinition) {
        self.definition = definition
    }

    /// Composes vault lifecycle handling with generic decoy-attempt policy.
    public var body: some ReducerOf<Self> {
        Scope(state: \.vault, action: \.vault) {
            VaultFeature()
        }
        Reduce { state, action in
            switch action {
            case .task:
                return .merge(
                    updateTriggerConfiguration(state: state),
                    .send(.vault(.task)),
                )
            case let .applicationPhaseChanged(phase):
                return handleApplicationPhase(phase, state: &state)
            case .sceneBecameActive:
                return .none
            case let .emergencyLockGestureRecognized(gesture, isForeground):
                guard gesture != .off,
                      isForeground,
                      state.vault.phase == .authenticated,
                      state.vault.sessionSettings.emergencyLockGesture == gesture
                else {
                    return .none
                }

                return lockApplication(state: &state)
            case let .decoyAttempt(attempt):
                return handle(attempt, state: &state)
            case let .vault(vaultAction):
                return handleVaultAction(vaultAction, state: &state)
            }
        }
    }

    private func handleApplicationPhase(
        _ phase: VaultApplicationScenePhase,
        state: inout State,
    ) -> Effect<Action> {
        switch phase {
        case .inactive:
            return .none
        case .unknown:
            state.applicationReturnPending = true
            guard state.vault.configuredKind != nil || state.vault.phase == .authenticated else {
                return .none
            }

            return lockApplication(state: &state)
        case .background:
            return handleApplicationBackground(state: &state)
        case .active:
            return handleApplicationActive(state: &state)
        }
    }

    private func handleApplicationBackground(state: inout State) -> Effect<Action> {
        state.applicationReturnPending = true
        guard state.vault.phase == .authenticated else {
            state.autoLockBackgroundStartedAt = nil
            state.autoLockTimeoutAtBackground = nil
            return .none
        }
        guard state.autoLockBackgroundStartedAt == nil else {
            return .none
        }
        guard let instant = sessionClock.now() else {
            return lockApplication(state: &state)
        }

        let timeout = state.vault.sessionSettings.autoLockTimeout.duration ?? .zero
        guard timeout > .zero else {
            return lockApplication(state: &state)
        }

        state.autoLockBackgroundStartedAt = instant
        state.autoLockTimeoutAtBackground = timeout
        return .none
    }

    private func handleApplicationActive(state: inout State) -> Effect<Action> {
        guard state.applicationReturnPending
            || state.autoLockBackgroundStartedAt != nil
        else {
            return .none
        }

        let backgroundStart = state.autoLockBackgroundStartedAt
        let originalTimeout = state.autoLockTimeoutAtBackground ?? .zero
        state.autoLockBackgroundStartedAt = nil
        state.autoLockTimeoutAtBackground = nil
        guard let backgroundStart else {
            let authorizationIsInFlight = state.vault.isWorking
                && (state.vault.phase == .authentication
                    || state.vault.pendingHiddenVerificationID != nil)
            guard state.vault.phase == .authenticated || authorizationIsInFlight else {
                state.applicationReturnPending = false
                return .none
            }

            let effect = lockApplication(state: &state)
            state.applicationReturnPending = false
            return effect
        }
        guard state.vault.phase == .authenticated else {
            state.applicationReturnPending = false
            return .none
        }
        guard let now = sessionClock.now() else {
            let effect = lockApplication(state: &state)
            state.applicationReturnPending = false
            return effect
        }

        let elapsed = backgroundStart.duration(to: now)
        guard elapsed >= .zero else {
            let effect = lockApplication(state: &state)
            state.applicationReturnPending = false
            return effect
        }

        let currentTimeout = state.vault.sessionSettings.autoLockTimeout.duration ?? .zero
        guard elapsed < min(originalTimeout, currentTimeout) else {
            let effect = lockApplication(state: &state)
            state.applicationReturnPending = false
            return effect
        }

        state.applicationReturnPending = false
        return .none
    }

    private func lockApplication(state: inout State) -> Effect<Action> {
        state.autoLockBackgroundStartedAt = nil
        state.autoLockTimeoutAtBackground = nil
        let pendingAttemptID = state.pendingHiddenAttemptID
        state.pendingHiddenAttemptID = nil
        state.pendingHiddenSessionGeneration = nil

        let lock = state.vault
            .commitGlobalLock(
                advanceResourceLoadGeneration: mediaLibrary.advanceResourceLoadGeneration,
                advanceBrowserProfileConfigurationGeneration: browserProfileConfigurationFence.advance,
            )
            .map(Action.vault)
        let update = updateTriggerConfiguration(state: state)
        guard let pendingAttemptID else {
            return .merge(lock, update)
        }

        return .merge(
            lock,
            update,
            deliver(
                attemptID: pendingAttemptID,
                result: .failure(.evaluationFailed),
                to: state.decoySession,
            ),
        )
    }

    private func handle(
        _ attempt: DecoyHiddenEntryAttempt,
        state: inout State,
    ) -> Effect<Action> {
        let declarations = definition.declaredTriggers.filter { $0.id == attempt.triggerID }
        guard declarations.count == 1,
              let descriptor = declarations.first,
              descriptor.intentKind == attempt.intent.kind
        else {
            return deliver(attemptID: attempt.id, result: .success(false), to: state.decoySession)
        }

        let configuration = triggerConfiguration(for: state.vault)
        guard configuration.isEnabled(attempt.triggerID) else {
            return deliver(attemptID: attempt.id, result: .success(false), to: state.decoySession)
        }

        switch attempt.intent {
        case .authenticationRequest:
            let nextPhase: VaultFeature.Action
            switch state.vault.phase {
            case .unconfigured:
                nextPhase = .beginSetup
            case .locked:
                nextPhase = .beginAuthentication
            case .loading,
                 .unavailable,
                 .setup,
                 .authentication,
                 .authenticated:
                return deliver(attemptID: attempt.id, result: .success(false), to: state.decoySession)
            }

            let supersededAttemptID = state.pendingHiddenAttemptID
            state.pendingHiddenAttemptID = nil
            state.pendingHiddenSessionGeneration = nil
            if let supersededAttemptID {
                return .concatenate(
                    .send(.vault(nextPhase)),
                    deliver(
                        attemptID: supersededAttemptID,
                        result: .failure(.evaluationFailed),
                        to: state.decoySession,
                    ),
                    deliver(attemptID: attempt.id, result: .success(true), to: state.decoySession),
                )
            }

            return .concatenate(
                .send(.vault(nextPhase)),
                deliver(attemptID: attempt.id, result: .success(true), to: state.decoySession),
            )
        case let .credentialCandidate(candidate):
            guard state.vault.canUseHiddenEntry,
                  !state.vault.isWorking,
                  state.pendingHiddenAttemptID == nil
            else {
                return deliver(attemptID: attempt.id, result: .success(false), to: state.decoySession)
            }

            state.pendingHiddenAttemptID = attempt.id
            state.pendingHiddenSessionGeneration = state.vault.sessionGeneration
            return .send(.vault(.verifyHidden(attemptID: attempt.id, candidate: candidate)))
        }
    }

    private func handleVaultAction(
        _ action: VaultFeature.Action,
        state: inout State,
    ) -> Effect<Action> {
        var completion: DecoyHiddenEntryCompletion?
        switch action {
        case let .hiddenVerificationCompleted(
            sessionGeneration,
            requestGeneration,
            attemptID,
            result,
        ):
            guard state.pendingHiddenAttemptID == attemptID,
                  state.pendingHiddenSessionGeneration == sessionGeneration,
                  state.vault.sessionGeneration == sessionGeneration,
                  state.vault.hiddenVerificationRequestGeneration == requestGeneration
            else {
                return .none
            }

            state.pendingHiddenAttemptID = nil
            state.pendingHiddenSessionGeneration = nil
            completion = DecoyHiddenEntryCompletion(attemptID: attemptID, result: result)
        case .beginAuthentication,
             .beginSetup:
            state.pendingHiddenSessionGeneration = nil
            if let attemptID = state.pendingHiddenAttemptID {
                state.pendingHiddenAttemptID = nil
                completion = DecoyHiddenEntryCompletion(
                    attemptID: attemptID,
                    result: .failure(.evaluationFailed),
                )
            }
        case .lock:
            state.autoLockBackgroundStartedAt = nil
            state.autoLockTimeoutAtBackground = nil
            state.pendingHiddenSessionGeneration = nil
            if let attemptID = state.pendingHiddenAttemptID {
                state.pendingHiddenAttemptID = nil
                completion = DecoyHiddenEntryCompletion(
                    attemptID: attemptID,
                    result: .failure(.evaluationFailed),
                )
            }
        default:
            break
        }

        let update = updateTriggerConfiguration(state: state)
        guard let completion else {
            return update
        }

        return .merge(update, deliver(completion, to: state.decoySession))
    }

    private func triggerConfiguration(
        for vault: VaultFeature.State,
    ) -> DecoyHiddenEntryTriggerConfiguration {
        let authenticationEntryIsValid = vault.phase == .unconfigured || vault.phase == .locked
        let enabledTriggerIDs = Set(definition.declaredTriggers.compactMap { descriptor in
            switch descriptor.intentKind {
            case .authenticationRequest:
                authenticationEntryIsValid ? descriptor.id : nil
            case .credentialCandidate:
                vault.canUseHiddenEntry ? descriptor.id : nil
            }
        })
        return DecoyHiddenEntryTriggerConfiguration(
            declaredTriggers: definition.declaredTriggers,
            enabledTriggerIDs: enabledTriggerIDs,
        )
    }

    private func updateTriggerConfiguration(state: State) -> Effect<Action> {
        let session = state.decoySession
        let configuration = triggerConfiguration(for: state.vault)
        return .run { _ in
            await session.updateTriggerConfiguration(configuration)
        }
    }

    private func deliver(
        attemptID: DecoyHiddenEntryAttempt.ID,
        result: Result<Bool, DecoyHiddenEntryError>,
        to session: AnyDecoySession,
    ) -> Effect<Action> {
        deliver(.init(attemptID: attemptID, result: result), to: session)
    }

    private func deliver(
        _ completion: DecoyHiddenEntryCompletion,
        to session: AnyDecoySession,
    ) -> Effect<Action> {
        .run { _ in
            await session.deliver(completion)
        }
    }
}

/// Creates the active decoy session and root store once for the application lifetime.
@MainActor
public enum RootComposition {
    /// Composes the root around the shipping decoy's statically registered definition.
    ///
    /// - Parameter vault: The initial vault state, primarily supplied by deterministic tests.
    /// - Returns: A root store whose decoy session remains stable across view updates.
    public static func makeStore(vault: VaultFeature.State = .init()) -> StoreOf<RootFeature> {
        makeStore(definition: ShippingDecoyRegistry.defaultDefinition, vault: vault)
    }

    static func makeStore(
        definition: DecoyDefinition,
        vault: VaultFeature.State,
    ) -> StoreOf<RootFeature> {
        let relay = DecoyAttemptRelay()
        let initialConfiguration = DecoyHiddenEntryTriggerConfiguration(
            declaredTriggers: definition.declaredTriggers,
            enabledTriggerIDs: [],
        )
        let context = DecoySessionContext(
            triggerConfiguration: initialConfiguration,
            attemptSink: { relay.submit($0) },
        )
        let session = definition.makeSession(context)
        let store = Store(
            initialState: RootFeature.State(decoySession: session, vault: vault),
        ) {
            RootFeature(definition: definition)
        }
        relay.store = store
        return store
    }
}

@MainActor
private final class DecoyAttemptRelay {
    weak var store: StoreOf<RootFeature>?

    func submit(_ attempt: DecoyHiddenEntryAttempt) {
        store?.send(.decoyAttempt(attempt))
    }
}

/// The surface selected by the application's lifecycle state.
@MainActor
public struct RootView: View {
    private let store: StoreOf<RootFeature>
    private let downloads: BrowserDownloadClient
    private let privacyGeneration: @MainActor () -> UInt64
    private let downloadHost: @MainActor (BrowserDownloadHost) -> BrowserDownloadHost
    @State
    private var downloadPrivacyGeneration: UInt64 = 0
    @Environment(\.scenePhase)
    private var scenePhase

    /// Creates the root view from the application's single root store.
    ///
    /// - Parameter store: The store that owns the root composition.
    public init(store: StoreOf<RootFeature>) {
        self.init(
            store: store,
            downloads: .liveValue,
            privacyGeneration: { BrowserDownloadPrivacy.generation },
            downloadHost: { $0 },
        )
    }

    /// Internal test composition owns the download client/coordinator without replacing live root
    /// authentication or the body-to-layout render-token protocol.
    init(
        store: StoreOf<RootFeature>,
        downloads: BrowserDownloadClient,
        privacyGeneration: @escaping @MainActor () -> UInt64,
        downloadHost: @escaping @MainActor (BrowserDownloadHost) -> BrowserDownloadHost,
    ) {
        self.store = store
        self.downloads = downloads
        self.privacyGeneration = privacyGeneration
        self.downloadHost = downloadHost
    }

    /// Renders the decoy session, credential surface, or authenticated shell.
    public var body: some View {
        let renderToken = BrowserDownloadRootRenderToken(
            surfaceID: rootSurfaceIdentity,
            authenticated: store.vault.phase == .authenticated,
            privacyGeneration: downloadPrivacyGeneration,
        )
        return ZStack {
            surface
                .padding(
                    .top,
                    RootSurfaceLayout.browserTopInset(
                        vaultPhase: store.vault.phase,
                        selectedTab: store.vault.shell.selectedTab,
                    ),
                )
                .safeAreaInset(edge: .top, spacing: 0) {
                    if store.vault.phase == .authenticated,
                       store.vault.shell.selectedTab == .browser,
                       !privacyCoverIsVisible {
                        HStack {
                            lockButton
                            Spacer()
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 4)
                        .background(.bar)
                    }
                }
                .accessibilityHidden(privacyCoverIsVisible)
                .allowsHitTesting(!privacyCoverIsVisible)
            if privacyCoverIsVisible {
                Color.black
                    .ignoresSafeArea()
                    .accessibilityHidden(true)
                    .allowsHitTesting(true)
            }
        }
        .background {
            ScenePrivacyCover(isCovered: privacyCoverIsVisible)
        }
        .background {
            downloadHost(BrowserDownloadHost(
                renderToken: renderToken,
                currentRenderToken: {
                    .init(
                        surfaceID: rootSurfaceIdentity,
                        authenticated: store.vault.phase == .authenticated,
                        privacyGeneration: privacyGeneration(),
                    )
                },
                authenticated: { store.vault.phase == .authenticated },
                observeAuthentication: { changed in
                    // Store.publisher delivers synchronously on UIScheduler when the store is
                    // mutated on MainActor. Admission also reads the live phase, never this projection.
                    let observation = store.publisher
                        .map { $0.vault.phase == .authenticated }
                        .removeDuplicates()
                        .sink { _ in MainActor.assumeIsolated { changed() } }
                    return { observation.cancel() }
                },
            ))
            .frame(width: 0, height: 0)
        }
        .task {
            // This projection forces a new body/token after privacy revocation even while Browser
            // is unmounted. Live admission continues to read the store and native registry directly.
            for await snapshot in await downloads.events() {
                downloadPrivacyGeneration = snapshot.generation
            }
        }
        .task {
            await store.send(.task).finish()
        }
    }

    private var rootSurfaceIdentity: String {
        switch store.vault.phase {
        case .setup:
            "setup"
        case .authentication:
            "authentication"
        case .authenticated:
            "authenticated"
        case .unavailable:
            "unavailable"
        case .loading:
            "loading"
        case .unconfigured:
            "unconfigured"
        case .locked:
            "locked"
        }
    }

    private var privacyCoverIsVisible: Bool {
        scenePhase != .active || store.applicationReturnPending
    }

    private var lockButton: some View {
        Button {
            store.send(.vault(.lock))
        } label: {
            Label("Lock", systemImage: "lock.fill")
        }
        .buttonStyle(.bordered)
        .accessibilityLabel("Lock")
        .accessibilityHint("Locks the vault and returns to the calculator.")
        .accessibilityIdentifier("vault.lock")
        .accessibilityHidden(privacyCoverIsVisible)
        .allowsHitTesting(!privacyCoverIsVisible)
    }

    /// Routes an observer callback through the root's current gesture and vault-phase checks.
    func routeEmergencyLockGesture(_ gesture: VaultEmergencyLockGesture, isForeground: Bool) {
        _ = store.send(.emergencyLockGestureRecognized(gesture: gesture, isForeground: isForeground))
    }

    @ViewBuilder
    private var surface: some View {
        switch store.vault.phase {
        case .setup,
             .authentication:
            VaultCredentialView(store: store.scope(state: \.vault, action: \.vault))
        case .authenticated:
            VaultShellView(
                store: store.scope(state: \.vault.shell, action: \.vault.shell),
                sessionSettings: store.vault.sessionSettings,
                onLock: { store.send(.vault(.lock)) },
                onEmergencyLockGesture: { gesture, isForeground in
                    routeEmergencyLockGesture(gesture, isForeground: isForeground)
                },
                onSessionSettingsChanged: {
                    store.send(.vault(.sessionSettingsChanged($0)))
                },
            )
        case .unavailable:
            decoySurface
                .safeAreaInset(edge: .bottom) {
                    vaultUnavailablePanel
                }
        case .loading,
             .unconfigured,
             .locked:
            decoySurface
        }
    }

    private var decoySurface: some View {
        store.decoySession.rootView
    }

    private var vaultUnavailablePanel: some View {
        VStack(spacing: 8) {
            Text("Vault unavailable")
                .font(.headline)
                .foregroundStyle(.red)
            Text("Credential storage could not be read. Try again when it is available.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Retry vault configuration", systemImage: "arrow.clockwise") {
                store.send(.vault(.retryConfiguration))
            }
            .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(.thinMaterial)
    }
}

/// Layout decisions shared by the root surface and its focused tests.
enum RootSurfaceLayout {
    /// Space reserved above an authenticated Browser surface for its lock bar.
    static let authenticatedBrowserTopInset: CGFloat = 24

    /// Returns the top inset for the surface currently represented by vault state.
    static func browserTopInset(
        vaultPhase: VaultFeaturePhase,
        selectedTab: VaultShellTab,
    ) -> CGFloat {
        if vaultPhase == .authenticated, selectedTab == .browser {
            authenticatedBrowserTopInset
        } else {
            0
        }
    }
}
