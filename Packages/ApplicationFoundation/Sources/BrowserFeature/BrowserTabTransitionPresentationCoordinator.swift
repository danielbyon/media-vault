//
//  BrowserTabTransitionPresentationCoordinator.swift
//  MediaVault
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import SwiftUI

/// Keeps destination availability, bounded retries, and preparation in one session policy.
@MainActor
struct BrowserTabTransitionDestinationReadinessPolicy {
    enum MountedSurfaceWaitPolicy: Equatable {
        case cancelWhenMountedButUnready
        case retryUntilUsable
    }

    let requiresReadySurface: Bool
    let displayTurnBudget: Int
    let mountedSurfaceWaitPolicy: MountedSurfaceWaitPolicy
    var prepareDestination: (() -> Bool)?

    init(
        requiresReadySurface: Bool = true,
        displayTurnBudget: Int = 8,
        mountedSurfaceWaitPolicy: MountedSurfaceWaitPolicy = .cancelWhenMountedButUnready,
        prepareDestination: (() -> Bool)? = nil,
    ) {
        self.requiresReadySurface = requiresReadySurface
        self.displayTurnBudget = displayTurnBudget
        self.mountedSurfaceWaitPolicy = mountedSurfaceWaitPolicy
        self.prepareDestination = prepareDestination
    }
}

/// SwiftUI's single projection of the mutable UIKit transition session.
@MainActor
struct BrowserTabTransitionViewState: Equatable {
    var overviewVisualMounted = false
    var latchedGeometry: BrowserContentViewportGeometry?
}

/// SwiftUI bindings updated by the UIKit transition session at visual lifecycle boundaries.
@MainActor
struct BrowserTabTransitionPresentationBindings {
    let state: Binding<BrowserTabTransitionViewState>

    var overviewVisualMounted: Binding<Bool> {
        state.overviewVisualMounted
    }

    var latchedGeometry: Binding<BrowserContentViewportGeometry?> {
        state.latchedGeometry
    }
}

/// Coordinates Browser's visual presentation state around one UIKit handoff.
///
/// Reducer presentation actions remain in `BrowserView`'s store. This type owns only the
/// view-local ordering that keeps the opaque overview layer and the exact UIKit representation
/// alive until the transition session reports a real destination boundary.
@MainActor
enum BrowserTabTransitionPresentationCoordinator {
    private static let destinationWaitDisplayTurnBudget = 8
    static let overviewDestinationWaitDisplayTurnBudget = 32

    static func begin(
        coordinator: BrowserTabTransitionUIKitCoordinator,
        selectedTabID: BrowserTabID,
        bindings: BrowserTabTransitionPresentationBindings,
        direction: BrowserTabTransitionDirection,
        tabID: BrowserTabID,
        reduceMotion: Bool,
        transitionToken: Int? = nil,
        onDestinationPreparation: (() -> BrowserTabTransitionDestinationPreparation)? = nil,
        onTransitionInvalidated: ((Int, BrowserTabTransitionDirection) -> Void)? = nil,
        onPresentationChange: @escaping () -> Void,
        onPresentationUnavailable: @escaping () -> Void,
    ) {
        let sessionToken = transitionToken ?? coordinator.nextTransitionToken()
        let destinationPreparation: (() -> Bool)? =
            if direction == .toOverview, let onDestinationPreparation {
                {
                    onDestinationPreparation() != .awaitingReadiness
                }
            } else {
                nil
            }
        let returnsToAlreadyMountedTab = direction == .toBrowsing && selectedTabID == tabID
        let destinationReadiness = BrowserTabTransitionDestinationReadinessPolicy(
            requiresReadySurface: !returnsToAlreadyMountedTab,
            displayTurnBudget: direction == .toOverview
                ? overviewDestinationWaitDisplayTurnBudget
                : destinationWaitDisplayTurnBudget,
            mountedSurfaceWaitPolicy: direction == .toOverview
                ? .retryUntilUsable
                : .cancelWhenMountedButUnready,
            prepareDestination: destinationPreparation,
        )
        let sourceRole: BrowserTabTransitionSurfaceRole = direction == .toOverview
            ? .content(tabID)
            : .card(tabID)
        bindings.latchedGeometry.wrappedValue = coordinator.surfaceRegistry.geometry(for: sourceRole)
        if direction == .toBrowsing {
            // Keep the opaque overview visual mounted until the card has revealed the live page.
            bindings.overviewVisualMounted.wrappedValue = true
        }

        coordinator.begin(
            token: sessionToken,
            direction: direction,
            tabID: tabID,
            reduceMotion: reduceMotion,
            destinationReadiness: destinationReadiness,
            onPresentationChange: onPresentationChange,
            onCompletion: {
                if direction == .toOverview {
                    bindings.overviewVisualMounted.wrappedValue = true
                } else if !coordinator.presentationOutcome.surfaceWasInstalled
                    || coordinator.presentationOutcome.destinationWasRevealed {
                    bindings.overviewVisualMounted.wrappedValue = false
                }
                bindings.latchedGeometry.wrappedValue = nil
            },
            onPresentationUnavailable: onPresentationUnavailable,
            onFrozenSurfaceReady: {},
            onDestinationVisible: {
                if direction == .toBrowsing {
                    // The clone remains above this layer until the session removes it.
                    bindings.overviewVisualMounted.wrappedValue = false
                }
            },
            onTransitionInvalidated: onTransitionInvalidated,
        )
    }

    static func cancel(
        coordinator: BrowserTabTransitionUIKitCoordinator,
        isOverviewPresented: Bool,
        bindings: BrowserTabTransitionPresentationBindings,
    ) {
        coordinator.cancel()
        bindings.overviewVisualMounted.wrappedValue = isOverviewPresented
        bindings.latchedGeometry.wrappedValue = nil
    }
}
