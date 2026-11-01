//
//  VaultCredentialView.swift
//  MediaVault
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import BrowserFeature
import ComposableArchitecture
import MediaLibrary
import SwiftUI
import UIKit

/// The setup and normal-authentication surface for the vault boundary.
@MainActor
public struct VaultCredentialView: View {
    private let store: StoreOf<VaultFeature>

    /// Creates a credential surface backed by a vault store.
    public init(store: StoreOf<VaultFeature>) {
        self.store = store
    }

    /// Renders setup or normal authentication according to the vault phase.
    public var body: some View {
        switch store.phase {
        case .setup:
            setupView
        case .authentication:
            authenticationView
        case .loading,
             .unconfigured,
             .unavailable,
             .locked,
             .authenticated:
            Color.clear
        }
    }

    private var setupView: some View {
        NavigationStack {
            setupForm
                .navigationTitle("Set up vault")
        }
    }

    private var setupForm: some View {
        Form {
            setupCredentialSection
            errorMessage
            Section {
                Button("Create vault") {
                    store.send(.submitSetup)
                }
                .disabled(store.isWorking)
            }
        }
    }

    private var setupCredentialSection: some View {
        Section("Credential") {
            Picker(
                "Type",
                selection: Binding(
                    get: { store.setupKind },
                    set: { store.send(.setupKindSelected($0)) },
                ),
            ) {
                Text("PIN").tag(VaultCredentialKind.pin)
                Text("Password").tag(VaultCredentialKind.password)
            }

            credentialField(
                title: store.setupKind == .pin ? "PIN" : "Password",
                value: Binding(
                    get: { store.credentialInput },
                    set: { store.send(.setupCredentialChanged($0)) },
                ),
            )
            credentialField(
                title: "Confirm",
                value: Binding(
                    get: { store.confirmationInput },
                    set: { store.send(.setupConfirmationChanged($0)) },
                ),
            )

            if store.setupKind == .pin {
                Toggle(
                    "Enable equals unlock",
                    isOn: Binding(
                        get: { store.usesHiddenEntry },
                        set: { store.send(.pinEqualsChanged($0)) },
                    ),
                )
            }
        }
    }

    private var authenticationView: some View {
        NavigationStack {
            authenticationForm
                .navigationTitle("Unlock vault")
        }
    }

    private var authenticationForm: some View {
        Form {
            Section("Unlock") {
                credentialField(
                    title: store.configuredKind == .pin ? "PIN" : "Password",
                    value: Binding(
                        get: { store.credentialInput },
                        set: { store.send(.authenticationCredentialChanged($0)) },
                    ),
                )
            }

            errorMessage
            Section {
                Button("Unlock") {
                    store.send(.submitAuthentication)
                }
                .disabled(store.isWorking)
            }
        }
    }

    @ViewBuilder
    private func credentialField(title: String, value: Binding<String>) -> some View {
        if activeCredentialKind == .pin {
            SecureField(title, text: value)
                .keyboardType(.numberPad)
                .textContentType(.oneTimeCode)
        } else {
            SecureField(title, text: value)
                .textContentType(.password)
        }
    }

    private var activeCredentialKind: VaultCredentialKind {
        store.phase == .authentication ? (store.configuredKind ?? .password) : store.setupKind
    }

    @ViewBuilder
    private var errorMessage: some View {
        if let error = store.error {
            Section {
                Text(message(for: error))
                    .foregroundStyle(.red)
            }
        }
    }

    private func message(for error: VaultFeatureError) -> String {
        switch error {
        case .invalidCredential:
            "Enter a valid credential."
        case .mismatchedCredentials:
            "The confirmation does not match."
        case .incorrectCredential:
            "That credential is not correct."
        case .unavailable:
            "The vault credential is temporarily unavailable."
        case .alreadyConfigured:
            "The vault has already been configured."
        }
    }
}

/// The authenticated library, collections, and browser shell.
@MainActor
public struct VaultShellView: View {
    private let store: StoreOf<VaultShellFeature>
    private let sessionSettings: VaultSessionSettings
    private let onLock: () -> Void
    private let onEmergencyLockGesture: @MainActor @Sendable (VaultEmergencyLockGesture, Bool) -> Void
    private let onSessionSettingsChanged: (VaultSessionSettings) -> Void
    @Environment(\.scenePhase)
    private var scenePhase

    /// Creates the authenticated shell from its navigation store.
    public init(
        store: StoreOf<VaultShellFeature>,
        sessionSettings: VaultSessionSettings,
        onLock: @escaping () -> Void,
        onEmergencyLockGesture: @escaping @MainActor @Sendable (VaultEmergencyLockGesture, Bool) -> Void,
        onSessionSettingsChanged: @escaping (VaultSessionSettings) -> Void,
    ) {
        self.store = store
        self.sessionSettings = sessionSettings
        self.onLock = onLock
        self.onEmergencyLockGesture = onEmergencyLockGesture
        self.onSessionSettingsChanged = onSessionSettingsChanged
    }

    /// Renders the three top-level destinations and navigation-presented settings.
    public var body: some View {
        NavigationStack {
            TabView(selection: selectedTab) {
                Tab("Library", systemImage: "photo.on.rectangle.angled", value: .library) {
                    MediaLibraryView(store: store.scope(state: \.library, action: \.library))
                }
                Tab("Collections", systemImage: "rectangle.stack", value: .collections) {
                    placeholder("Collections", systemImage: "rectangle.stack")
                }
                Tab("Browser", systemImage: "safari", value: .browser) {
                    BrowserView(store: store.scope(state: \.browser, action: \.browser))
                }
            }
            .tabViewStyle(.sidebarAdaptable)
            .navigationTitle(title(for: store.selectedTab))
            .toolbar {
                if store.selectedTab != .browser {
                    ToolbarItemGroup(placement: .topBarTrailing) {
                        Button("Lock", systemImage: "lock.fill", action: onLock)
                            .accessibilityHint("Locks the vault and returns to the calculator.")
                            .accessibilityIdentifier("vault.lock")
                        Button("Settings", systemImage: "gearshape") {
                            store.send(.settingsTapped)
                        }
                    }
                }
            }
            .toolbar(
                store.selectedTab == .browser ? .hidden : .visible,
                for: .navigationBar,
            )
            .background { browserKeyboardShortcutHost }
            .modifier(EmergencyLockGestureObserver(
                gesture: sessionSettings.emergencyLockGesture,
                isForeground: scenePhase == .active,
                onRecognized: onEmergencyLockGesture,
            ))
            .sheet(
                isPresented: Binding(
                    get: { store.settingsPresented },
                    set: { isPresented in
                        if !isPresented {
                            store.send(.settingsDismissed)
                        }
                    },
                ),
            ) {
                AuthenticatedSettingsView(
                    browserStore: store.scope(state: \.browser, action: \.browser),
                    sessionSettings: sessionSettings,
                    onSessionSettingsChanged: onSessionSettingsChanged,
                )
            }
        }
    }

    /// Registers Command-L only while Browser owns the authenticated shell destination.
    @ViewBuilder
    private var browserKeyboardShortcutHost: some View {
        if store.selectedTab == .browser {
            Button {
                store.send(.browser(.omniboxFocused))
            } label: {
                EmptyView()
            }
            .keyboardShortcut("l", modifiers: .command)
            .accessibilityHidden(true)
            .frame(width: 0, height: 0)
        }
    }

    private var selectedTab: Binding<VaultShellTab> {
        Binding(
            get: { store.selectedTab },
            set: { store.send(.tabSelected($0)) },
        )
    }

    private func title(for tab: VaultShellTab) -> String {
        switch tab {
        case .library:
            "Library"
        case .collections:
            "Collections"
        case .browser:
            "Browser"
        }
    }

    private func placeholder(_ title: String, systemImage: String) -> some View {
        ContentUnavailableView(
            title,
            systemImage: systemImage,
            description: Text("This destination is ready for its next feature."),
        )
    }
}

private struct AuthenticatedSettingsView: View {
    let browserStore: StoreOf<BrowserFeature>
    let sessionSettings: VaultSessionSettings
    let onSessionSettingsChanged: (VaultSessionSettings) -> Void

    var body: some View {
        NavigationStack {
            List {
                Section("Auto-Lock") {
                    Picker("When the app is backgrounded", selection: autoLockTimeout) {
                        Text("Immediately").tag(VaultAutoLockTimeout.immediately)
                        Text("30 seconds").tag(VaultAutoLockTimeout.seconds30)
                        Text("1 minute").tag(VaultAutoLockTimeout.minute1)
                        Text("5 minutes").tag(VaultAutoLockTimeout.minutes5)
                        Text("15 minutes").tag(VaultAutoLockTimeout.minutes15)
                    }
                    .pickerStyle(.menu)
                    Text("The timer starts only after all app windows leave the foreground.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("Emergency Lock Gesture") {
                    Picker("Gesture", selection: emergencyLockGesture) {
                        Text("Off").tag(VaultEmergencyLockGesture.off)
                        Text("Shake").tag(VaultEmergencyLockGesture.shake)
                        Text("Four taps").tag(VaultEmergencyLockGesture.quadrupleTap)
                    }
                    .pickerStyle(.menu)
                    Text("The selected gesture locks the vault. Gestures never unlock it.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                NavigationLink {
                    BrowserSettingsView(store: browserStore)
                } label: {
                    Label("Browser", systemImage: "safari")
                }
            }
            .navigationTitle("Settings")
        }
    }

    private var autoLockTimeout: Binding<VaultAutoLockTimeout> {
        Binding(
            get: { sessionSettings.autoLockTimeout },
            set: { timeout in
                var settings = sessionSettings
                settings.autoLockTimeout = timeout
                onSessionSettingsChanged(settings)
            },
        )
    }

    private var emergencyLockGesture: Binding<VaultEmergencyLockGesture> {
        Binding(
            get: { sessionSettings.emergencyLockGesture },
            set: { gesture in
                var settings = sessionSettings
                settings.emergencyLockGesture = gesture
                onSessionSettingsChanged(settings)
            },
        )
    }
}
