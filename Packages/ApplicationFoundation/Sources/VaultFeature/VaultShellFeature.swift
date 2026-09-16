//
//  VaultShellFeature.swift
//  MediaVault
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import BrowserFeature
import ComposableArchitecture
import MediaLibrary

/// The authenticated top-level destinations.
public enum VaultShellTab: String, CaseIterable, Equatable, Hashable, Sendable {
    /// The authenticated media library destination.
    case library

    /// The collections destination placeholder.
    case collections

    /// The authenticated browser destination.
    case browser
}

/// The authenticated navigation shell.
///
/// This feature owns top-level navigation and composes the authenticated Library state. It
/// intentionally does not know how credentials are stored or how Collections will be implemented.
@Reducer
public struct VaultShellFeature {
    /// State for the authenticated navigation shell.
    @ObservableState
    public struct State: Equatable, Sendable {
        /// The currently selected top-level destination.
        public var selectedTab: VaultShellTab

        /// Whether navigation-presented settings is visible.
        public var settingsPresented: Bool

        /// The authenticated Library feature state.
        public var library: MediaLibraryFeature.State

        /// The standalone authenticated browser feature state.
        public var browser: BrowserFeature.State

        /// Creates the initial authenticated shell state.
        public init(
            selectedTab: VaultShellTab = .library,
            settingsPresented: Bool = false,
            library: MediaLibraryFeature.State = .init(),
            browser: BrowserFeature.State = .init(),
        ) {
            self.selectedTab = selectedTab
            self.settingsPresented = settingsPresented
            self.library = library
            self.browser = browser
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

        /// Forwards Library actions.
        case library(MediaLibraryFeature.Action)

        /// Forwards Browser actions.
        case browser(BrowserFeature.Action)
    }

    /// Creates the authenticated shell reducer.
    public init() {}

    /// Handles tab and settings navigation.
    public var body: some ReducerOf<Self> {
        Scope(state: \.library, action: \.library) {
            MediaLibraryFeature()
        }
        Scope(state: \.browser, action: \.browser) {
            BrowserFeature()
        }
        Reduce { state, action in
            switch action {
            case let .tabSelected(tab):
                state.selectedTab = tab
            case .settingsTapped:
                state.settingsPresented = true
            case .settingsDismissed:
                state.settingsPresented = false
            case .library,
                 .browser:
                return .none
            }
            return .none
        }
    }
}
