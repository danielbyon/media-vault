//
//  VaultCredentialView.swift
//  MediaVault
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import ComposableArchitecture
import SwiftUI
import UIKit

/// The setup and normal-authentication surface for the vault boundary.
@MainActor
@preconcurrency
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
@preconcurrency
public struct VaultShellView: View {
    private let store: StoreOf<VaultShellFeature>

    /// Creates the authenticated shell from its navigation store.
    public init(store: StoreOf<VaultShellFeature>) {
        self.store = store
    }

    /// Renders the three top-level destinations and navigation-presented settings.
    public var body: some View {
        NavigationStack {
            TabView(selection: selectedTab) {
                Tab("Library", systemImage: "photo.on.rectangle.angled", value: .library) {
                    placeholder("Library", systemImage: "photo.on.rectangle.angled")
                }
                Tab("Collections", systemImage: "rectangle.stack", value: .collections) {
                    placeholder("Collections", systemImage: "rectangle.stack")
                }
                Tab("Browser", systemImage: "safari", value: .browser) {
                    placeholder("Browser", systemImage: "safari")
                }
            }
            .tabViewStyle(.sidebarAdaptable)
            .navigationTitle(title(for: store.selectedTab))
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Settings", systemImage: "gearshape") {
                        store.send(.settingsTapped)
                    }
                }
            }
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
                SettingsPlaceholderView()
            }
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

private struct SettingsPlaceholderView: View {
    var body: some View {
        NavigationStack {
            Text("Settings")
                .navigationTitle("Settings")
        }
    }
}
