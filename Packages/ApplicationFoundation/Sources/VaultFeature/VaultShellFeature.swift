//
//  VaultShellFeature.swift
//  MediaVault
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import ComposableArchitecture

/// The authenticated top-level destinations.
public enum VaultShellTab: String, CaseIterable, Equatable, Hashable, Sendable {
    /// The media library destination placeholder.
    case library

    /// The collections destination placeholder.
    case collections

    /// The browser destination placeholder.
    case browser
}

/// The authenticated navigation shell.
///
/// This feature owns navigation state only. It intentionally does not know how credentials are
/// stored or how downstream media and browser features will be implemented.
@Reducer
public struct VaultShellFeature {
    /// State for the authenticated navigation shell.
    @ObservableState
    public struct State: Equatable, Sendable {
        /// The currently selected top-level destination.
        public var selectedTab: VaultShellTab

        /// Whether navigation-presented settings is visible.
        public var settingsPresented: Bool

        /// Creates the initial authenticated shell state.
        public init(
            selectedTab: VaultShellTab = .library,
            settingsPresented: Bool = false,
        ) {
            self.selectedTab = selectedTab
            self.settingsPresented = settingsPresented
        }
    }

    /// Navigation actions handled by the shell.
    public enum Action: Equatable, Sendable {
        /// Selects a top-level destination.
        case tabSelected(VaultShellTab)

        /// Presents settings from navigation.
        case settingsTapped

        /// Dismisses navigation-presented settings.
        case settingsDismissed
    }

    /// Creates the authenticated shell reducer.
    public init() {}

    /// Handles tab and settings navigation.
    public var body: some ReducerOf<Self> {
        Reduce { state, action in
            switch action {
            case let .tabSelected(tab):
                state.selectedTab = tab
            case .settingsTapped:
                state.settingsPresented = true
            case .settingsDismissed:
                state.settingsPresented = false
            }
            return .none
        }
    }
}
