//
//  BrowserTabTransitionPresentationCoordinator.swift
//  MediaVault
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import SwiftUI

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
    static func begin(
        coordinator: BrowserTabTransitionUIKitCoordinator,
        selectedTabID: BrowserTabID,
        bindings: BrowserTabTransitionPresentationBindings,
        direction: BrowserTabTransitionDirection,
        tabID: BrowserTabID,
        reduceMotion: Bool,
        onPresentationChange: @escaping () -> Void,
        onEvidenceUnavailable: @escaping () -> Void,
    ) {
        let returnsToAlreadyMountedTab = direction == .toBrowsing && selectedTabID == tabID
        let sourceRole: BrowserTabTransitionSurfaceRole = direction == .toOverview
            ? .content(tabID)
            : .card(tabID)
        bindings.latchedGeometry.wrappedValue = coordinator.surfaceRegistry.geometry(for: sourceRole)
        if direction == .toBrowsing {
            // Keep the opaque overview visual mounted until the card has revealed the live page.
            bindings.overviewVisualMounted.wrappedValue = true
        }

        coordinator.begin(
            token: coordinator.nextTransitionToken(),
            direction: direction,
            tabID: tabID,
            reduceMotion: reduceMotion,
            destinationRequiresReadiness: !returnsToAlreadyMountedTab,
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
            onEvidenceUnavailable: onEvidenceUnavailable,
            onFrozenSurfaceReady: {},
            onDestinationVisible: {
                if direction == .toBrowsing {
                    // The clone remains above this layer until the session removes it.
                    bindings.overviewVisualMounted.wrappedValue = false
                }
            },
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
