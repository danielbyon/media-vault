//
//  BrowserProfileConfigurationGate.swift
//  MediaVault
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//

// Test fixtures compiled by both the SwiftPM BrowserFeatureTests target and the
// application-hosted AppHostedTests target. The gate and WebKit fixture let
// profile-configuration tests suspend and resume stored-profile setup, and the
// BrowserFeature.State builders produce states whose profile is already ready.

@testable import BrowserFeature

extension BrowserFeature.State {
    /// Creates a logical Browser state whose stored profile has already been configured.
    static func readyForTesting(initialTabID: BrowserTabID = .init()) -> Self {
        var state = Self(initialTabID: initialTabID)
        state.profileLifecycle = .ready
        return state
    }

    /// Creates a tabbed Browser state whose stored profile has already been configured.
    static func readyForTesting(
        tabs: [BrowserTab],
        selectedTabID: BrowserTabID,
        presentation: BrowserPresentation = .browsing,
        focusedField: BrowserFocusedField = .none,
        omniboxDraft: String = "",
    ) -> Self {
        var state = Self(
            tabs: tabs,
            selectedTabID: selectedTabID,
            presentation: presentation,
            focusedField: focusedField,
            omniboxDraft: omniboxDraft,
        )
        state.profileLifecycle = .ready
        return state
    }
}

actor BrowserProfileConfigurationGate {
    private var startedProfile: BrowserBrowsingProfile?
    private var startContinuation: CheckedContinuation<BrowserBrowsingProfile, Never>?
    private var releaseContinuation: CheckedContinuation<Void, Never>?
    private var releasedBeforeSuspension = false
    private var shouldPauseNextConfiguration = true
    private var requestedProfileConfigurations: [BrowserBrowsingProfile] = []

    func pause(_ profile: BrowserBrowsingProfile) async {
        requestedProfileConfigurations.append(profile)
        guard shouldPauseNextConfiguration else {
            return
        }

        shouldPauseNextConfiguration = false

        if let startContinuation {
            self.startContinuation = nil
            startContinuation.resume(returning: profile)
        } else {
            startedProfile = profile
        }

        await withCheckedContinuation { continuation in
            if releasedBeforeSuspension {
                releasedBeforeSuspension = false
                continuation.resume()
            } else {
                releaseContinuation = continuation
            }
        }
    }

    func requestedProfiles() -> [BrowserBrowsingProfile] {
        requestedProfileConfigurations
    }

    func waitUntilStarted() async -> BrowserBrowsingProfile {
        if let startedProfile {
            self.startedProfile = nil
            return startedProfile
        }

        return await withCheckedContinuation { continuation in
            startContinuation = continuation
        }
    }

    func release() {
        if let releaseContinuation {
            self.releaseContinuation = nil
            releaseContinuation.resume()
        } else {
            releasedBeforeSuspension = true
        }
    }
}

@MainActor
final class BrowserProfileWebKitFixture {
    private let adapter: BrowserWebKitAdapter
    private let gate: BrowserProfileConfigurationGate

    init(adapter: BrowserWebKitAdapter, gate: BrowserProfileConfigurationGate) {
        self.adapter = adapter
        self.gate = gate
    }

    func execute(_ command: BrowserWebKitCommand) async {
        if case let .configureProfile(profile, _) = command {
            await gate.pause(profile)
            adapter.execute(command)
        } else if case .load = command {
            // Keep the test at the context-creation boundary without issuing a network request.
        } else {
            adapter.execute(command)
        }
    }
}
