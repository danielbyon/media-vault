//
//  BrowserTabTransitionUIKitCoordinator.swift
//  MediaVault
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import SwiftUI
import UIKit

/// Records the visual boundaries crossed by the most recently completed transition session.
struct BrowserTabTransitionPresentationOutcome: Equatable {
    var surfaceWasInstalled = false
    var destinationWasRevealed = false
}

/// Owns every mutable resource for one tab-transition handoff.
///
/// A transition has one lifecycle owner from installation through teardown. UIKit completions and
/// display-turn callbacks validate this same session identity, token, and generation before they
/// touch a surface or invoke a callback.
@MainActor
final class BrowserTabTransitionSession {
    var token: Int
    var direction: BrowserTabTransitionDirection
    var tabID: BrowserTabID
    var reduceMotion: Bool
    var destinationRequiresReadiness: Bool
    var completion: (() -> Void)?
    var destinationReveal: (() -> Void)?
    var evidenceUnavailable: (() -> Void)?
    var ownsVisibleSurface: Bool
    var frozenSurface: UIView?
    weak var liveSurface: UIView?
    var originalCenter: CGPoint?
    var originalTransform: CGAffineTransform?
    var originalAlpha: CGFloat?
    var originalCornerRadius: CGFloat?
    var originalCornerCurve: CALayerCornerCurve?
    var originalMasksToBounds: Bool?
    var animator: UIViewPropertyAnimator?
    var destinationWaitProbe: BrowserTabTransitionDisplayTurnProbe?
    var destinationWaitTurnsRemaining = 0
    var generation = 0
    var destinationRole: BrowserTabTransitionSurfaceRole?
    var destinationFrame: CGRect?
    var missingDestinationWasRecorded = false

    init(
        token: Int,
        direction: BrowserTabTransitionDirection,
        tabID: BrowserTabID,
        reduceMotion: Bool,
        destinationRequiresReadiness: Bool,
        completion: @escaping () -> Void,
        evidenceUnavailable: @escaping () -> Void,
        destinationReveal: @escaping () -> Void,
    ) {
        self.token = token
        self.direction = direction
        self.tabID = tabID
        self.reduceMotion = reduceMotion
        self.destinationRequiresReadiness = destinationRequiresReadiness
        self.completion = completion
        self.evidenceUnavailable = evidenceUnavailable
        self.destinationReveal = destinationReveal
        ownsVisibleSurface = false
    }

    func retarget(
        token: Int,
        direction: BrowserTabTransitionDirection,
        tabID: BrowserTabID,
        reduceMotion: Bool,
        destinationRequiresReadiness: Bool,
        completion: @escaping () -> Void,
        evidenceUnavailable: @escaping () -> Void,
        destinationReveal: @escaping () -> Void,
    ) {
        self.token = token
        self.direction = direction
        self.tabID = tabID
        self.reduceMotion = reduceMotion
        self.destinationRequiresReadiness = destinationRequiresReadiness
        self.completion = completion
        self.evidenceUnavailable = evidenceUnavailable
        self.destinationReveal = destinationReveal
        destinationRole = nil
        destinationFrame = nil
        ownsVisibleSurface = false
        missingDestinationWasRecorded = false
    }
}

@MainActor
final class BrowserTabTransitionParkedSurfaceState {
    let surface: UIView
    let cardID: BrowserTabID

    init(surface: UIView, cardID: BrowserTabID) {
        self.surface = surface
        self.cardID = cardID
    }
}

/// Owns every mutable value for one Browser tab-transition handoff.
///
/// The normal animation and bounded fallback branches are implemented in extensions, but they
/// all mutate this one state owner and use the same generation and transition identity guards for
/// asynchronous completions.
@MainActor
final class BrowserTabTransitionUIKitCoordinator: ObservableObject {
    /// Invalidation token for SwiftUI's view-local projection of the coordinator-owned phase.
    @Published
    private(set) var lifecycleRevision = 0
    private(set) var presentationOutcome = BrowserTabTransitionPresentationOutcome()
    let registry: BrowserTabTransitionSurfaceRegistry
    var session: BrowserTabTransitionSession?
    var parkedSurface: BrowserTabTransitionParkedSurfaceState?
    var surfaceChangeTaskScheduled = false
    weak var overlay: BrowserTabTransitionOverlayView?
    let diagnostics: BrowserTabTransitionDiagnostics
    private var transitionToken = 0

    init(
        registry: BrowserTabTransitionSurfaceRegistry = .init(),
        diagnostics: BrowserTabTransitionDiagnostics = .init(),
    ) {
        self.registry = registry
        self.diagnostics = diagnostics
        registry.onChange = { [weak self] in
            self?.surfaceChanged()
        }
        registry.onEvent = { [weak self] event in
            guard let self else {
                return
            }

            self.diagnostics.onEvent?(event)
            if case .targetEvidenceUnavailable = event {
                handleEvidenceUnavailable()
            }
        }
    }

    /// The registry used by content and card boundary bridges.
    var surfaceRegistry: BrowserTabTransitionSurfaceRegistry {
        registry
    }

    /// Ends the single session and invalidates every completion that still captures it.
    func endSession() {
        tearDownSessionResources()
        session = nil
        surfaceChangeTaskScheduled = false
        lifecycleRevision &+= 1
    }

    private func tearDownSessionResources(
        preservingFrozenSurface: Bool = false,
        keepingLiveAssociation: Bool = false,
    ) {
        guard let session else {
            return
        }

        if preservingFrozenSurface {
            materializePresentation()
        }
        session.generation += 1
        session.destinationWaitProbe?.invalidate()
        session.destinationWaitProbe = nil
        session.destinationWaitTurnsRemaining = 0
        session.animator?.stopAnimation(true)
        session.animator = nil
        restoreLiveSurface(keepingAssociation: keepingLiveAssociation)
        if !preservingFrozenSurface {
            session.frozenSurface?.removeFromSuperview()
            session.frozenSurface = nil
        }
    }

    /// Allocates the identity used to reject stale animation and display-turn completions.
    func nextTransitionToken() -> Int {
        transitionToken += 1
        return transitionToken
    }

    func resetPresentationOutcome() {
        presentationOutcome = .init()
    }

    func markDestinationRevealed() {
        presentationOutcome.destinationWasRevealed = true
    }

    /// The direction owned by the current session.
    var direction: BrowserTabTransitionDirection? {
        session?.direction
    }

    /// The tab owned by the current session.
    var tabID: BrowserTabID? {
        session?.tabID
    }

    /// Whether the transition's exact clone or live surface currently owns the visible handoff.
    var ownsVisibleSurface: Bool {
        session?.ownsVisibleSurface ?? false
    }

    /// Whether a temporary clone currently owns the handoff.
    var isActive: Bool {
        session != nil
    }

    func retainParkedSurface(_ surface: UIView, for cardID: BrowserTabID) {
        parkedSurface = .init(surface: surface, cardID: cardID)
    }

    func clearParkedSurfaceState() {
        parkedSurface = nil
    }

    func clearParkedSurface(for cardID: BrowserTabID) {
        guard parkedSurface?.cardID == cardID else {
            return
        }

        clearParkedSurfaceAssociation()
    }

    /// Mounts the common overlay coordinate space.
    func attach(overlay: BrowserTabTransitionOverlayView) {
        self.overlay = overlay
        surfaceChanged()
    }

    /// Releases an overlay without touching a parked exact card representation.
    func detach(overlay: BrowserTabTransitionOverlayView) {
        if self.overlay === overlay {
            self.overlay = nil
        }
    }

    /// Starts or retargets a handoff after preparing the exact source representation.
    func begin(
        token: Int,
        direction: BrowserTabTransitionDirection,
        tabID: BrowserTabID,
        reduceMotion: Bool,
        destinationRequiresReadiness: Bool = true,
        onPresentationChange: () -> Void,
        onCompletion: @escaping () -> Void,
        onEvidenceUnavailable: @escaping () -> Void = {},
        onFrozenSurfaceReady: () -> Void = {},
        onDestinationVisible: @escaping () -> Void = {},
    ) {
        resetPresentationOutcome()
        surfaceChangeTaskScheduled = false

        if let session {
            if direction == .toBrowsing {
                _ = moveParkedSurfaceToOverlay()
            }
            tearDownSessionResources(
                preservingFrozenSurface: true,
                keepingLiveAssociation: true,
            )
            session.retarget(
                token: token,
                direction: direction,
                tabID: tabID,
                reduceMotion: reduceMotion,
                destinationRequiresReadiness: destinationRequiresReadiness,
                completion: onCompletion,
                evidenceUnavailable: onEvidenceUnavailable,
                destinationReveal: onDestinationVisible,
            )
            lifecycleRevision &+= 1
            session.frozenSurface?.alpha = 1
            if direction == .toBrowsing {
                clearParkedSurfaceAssociation()
            }
            markVisibleSurfaceOwned()
            onFrozenSurfaceReady()
            onPresentationChange()
            waitForDestination()
            return
        }

        session = BrowserTabTransitionSession(
            token: token,
            direction: direction,
            tabID: tabID,
            reduceMotion: reduceMotion,
            destinationRequiresReadiness: destinationRequiresReadiness,
            completion: onCompletion,
            evidenceUnavailable: onEvidenceUnavailable,
            destinationReveal: onDestinationVisible,
        )
        lifecycleRevision &+= 1
        guard let session else {
            return
        }

        session.generation += 1

        if direction == .toOverview {
            clearParkedSurfaceAssociation()
        }

        if direction == .toBrowsing,
           parkedSurface?.cardID == tabID,
           parkedSurface != nil,
           moveParkedSurfaceToOverlay() {
            // Reuse the exact clone that represented this selected card in overview. The
            // reducer may have refreshed its cache while overview was visible, but that must not
            // replace the image already handed to the user.
            session.frozenSurface?.alpha = 1
            markVisibleSurfaceOwned()
            onFrozenSurfaceReady()
            onPresentationChange()
            waitForDestination()
            return
        }

        if direction == .toBrowsing {
            clearParkedSurfaceAssociation()
        }

        let sourceRole: BrowserTabTransitionSurfaceRole = direction == .toOverview
            ? .content(tabID)
            : .card(tabID)
        guard let sourceView = registry.view(for: sourceRole),
              let overlay,
              let sourceFrame = registry.frame(for: sourceRole, in: overlay)
        else {
            record(.missingSource)
            onPresentationChange()
            finish()
            return
        }

        if direction == .toOverview,
           registry.representation(for: sourceRole) == .live {
            prepareLiveSurface(sourceView)
            markVisibleSurfaceOwned()
            onFrozenSurfaceReady()
            onPresentationChange()
            waitForDestination()
            return
        }

        guard let clone = makeFrozenSurface(from: sourceView) else {
            record(.missingSource)
            onPresentationChange()
            finish()
            return
        }

        clone.bounds = sourceView.bounds
        clone.center = CGPoint(x: sourceFrame.midX, y: sourceFrame.midY)
        clone.transform = .identity
        clone.layer.cornerCurve = .continuous
        clone.layer.masksToBounds = true
        clone.layer.cornerRadius = direction == .toOverview
            ? BrowserTabTransitionPresentation.viewportCornerRadius
            : BrowserTabTransitionPresentation.cardCornerRadius
        overlay.addSubview(clone)
        session.frozenSurface = clone

        // The clone is installed before reducer state changes so SwiftUI can never remove the
        // only visible representation while the destination hierarchy is mounting.
        markVisibleSurfaceOwned()
        onFrozenSurfaceReady()
        onPresentationChange()
        waitForDestination()
    }

    private func markVisibleSurfaceOwned() {
        presentationOutcome.surfaceWasInstalled = true
        setOwnsVisibleSurface(true)
    }

    func setOwnsVisibleSurface(_ value: Bool) {
        guard let session else {
            return
        }

        if session.ownsVisibleSurface != value {
            session.ownsVisibleSurface = value
            lifecycleRevision &+= 1
        }
    }
}
