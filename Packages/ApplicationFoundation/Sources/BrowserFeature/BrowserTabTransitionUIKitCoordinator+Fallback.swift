//
//  BrowserTabTransitionUIKitCoordinator+Fallback.swift
//  MediaVault
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import UIKit
import WebKit

@MainActor
extension BrowserTabTransitionUIKitCoordinator {
    /// Creates the exact card surface from the live layer after the WebKit compositor has moved it.
    ///
    /// This path is intentionally separate from `makeFrozenSurface(from:)`: a WebKit
    /// `snapshotView` can be non-nil while still containing no committed page pixels. The live
    /// layer renderer gives the direct-live fallback a fixed-bounds card representation without
    /// asking WebKit to navigate, resize, or serialize reducer preview state.
    func makeRenderedSurface(from sourceView: UIView) -> UIView? {
        if let renderedSurfaceFactory {
            return renderedSurfaceFactory(sourceView)
        }

        return BrowserSurfaceRenderer.imageView(
            from: sourceView,
            afterScreenUpdates: false,
            opaque: sourceView.isOpaque,
            renderingPolicy: sourceView is WKWebView ? .webKit : .appOwnedTransition,
        )
    }

    func completeWithOpacityOnly(destinationView: UIView) {
        guard let session else {
            return
        }

        if let liveSurface = session.liveSurface {
            if session.direction == .toOverview {
                guard let exactCardSurface = makeRenderedSurface(from: liveSurface) else {
                    // A reduced-motion overview transition must not reveal a card that was not
                    // proven to contain the live page pixels. The live WebKit surface remains
                    // authoritative while the Browser owner restores the browsing presentation.
                    abortUnprovableTransition()
                    return
                }

                // Reduced Motion removes the geometry animation, but the overview still receives
                // the exact rendered page rather than exposing a cached or placeholder preview.
                session.frozenSurface = exactCardSurface
                parkFrozenSurface(in: destinationView)
            }

            revealDestination()
            restoreLiveSurface()
            session.animator = nil
            finish()
            return
        }

        guard let frozenSurface = session.frozenSurface
        else {
            finish()
            return
        }

        if session.direction == .toOverview {
            revealDestination()
            parkFrozenSurface(in: destinationView)
            session.animator = nil
            finish()
            return
        }

        // A Reduce Motion handoff never transforms the clone. It only removes the exact card
        // image after the browsing surface has mounted beneath it.
        revealDestination()

        let fade = UIViewPropertyAnimator(duration: 0.15, curve: .easeOut) { [weak frozenSurface] in
            frozenSurface?.alpha = 0
        }
        let generation = session.generation
        let transitionToken = session.token
        fade.addCompletion { [weak self, weak session] _ in
            guard let self, let session,
                  session.generation == generation,
                  session.token == transitionToken
            else {
                return
            }

            removeFrozenSurface()
            finish()
        }
        session.animator = fade
        diagnostics.onAnimatorCreated?(fade)
        fade.startAnimation()
    }

    func parkFrozenSurface(in cardView: UIView) {
        guard let session,
              let frozenSurface = session.frozenSurface
        else {
            return
        }

        frozenSurface.removeFromSuperview()
        frozenSurface.transform = .identity
        frozenSurface.alpha = 1
        frozenSurface.translatesAutoresizingMaskIntoConstraints = true
        frozenSurface.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        frozenSurface.frame = cardView.bounds
        frozenSurface.layer.cornerRadius = BrowserTabTransitionPresentation.cardCornerRadius
        frozenSurface.layer.masksToBounds = true
        cardView.addSubview(frozenSurface)
        retainParkedSurface(frozenSurface, for: session.tabID)
        // The parked clone is owned by the coordinator, not by the completed session. Clearing
        // the session reference lets central teardown remove only transient transition resources.
        session.frozenSurface = nil
    }

    /// Reparents a reduced-motion card clone before a rapid reverse can retarget it.
    @discardableResult
    func moveParkedSurfaceToOverlay() -> Bool {
        guard let session,
              let parkedSurface = parkedSurface?.surface,
              let overlay
        else {
            return false
        }

        let frame = parkedSurface.convert(parkedSurface.bounds, to: overlay)
        parkedSurface.removeFromSuperview()
        overlay.addSubview(parkedSurface)
        parkedSurface.frame = frame
        session.frozenSurface = parkedSurface
        clearParkedSurfaceState()
        return true
    }

    func clearParkedSurfaceAssociation() {
        parkedSurface?.surface.removeFromSuperview()
        clearParkedSurfaceState()
    }

    func materializePresentation() {
        guard let session else {
            return
        }

        if let liveSurface = session.liveSurface {
            let presentation = liveSurface.layer.presentation()
            session.generation += 1
            session.animator?.pauseAnimation()
            session.animator?.stopAnimation(true)
            session.animator = nil
            if let presentation {
                liveSurface.layer.removeAllAnimations()
                liveSurface.center = presentation.position
                liveSurface.transform = presentation.affineTransform()
                liveSurface.alpha = CGFloat(presentation.opacity)
                liveSurface.layer.cornerRadius = presentation.cornerRadius
            }
            return
        }

        guard let frozenSurface = session.frozenSurface else {
            session.animator = nil
            return
        }

        let presentation = frozenSurface.layer.presentation()
        session.generation += 1
        session.animator?.pauseAnimation()
        session.animator?.stopAnimation(true)
        session.animator = nil

        let displayedCenter = presentation?.position ?? frozenSurface.center
        let displayedTransform = presentation?.affineTransform() ?? frozenSurface.transform
        let displayedAlpha = presentation.map { CGFloat($0.opacity) } ?? frozenSurface.alpha
        let displayedScale = max(
            sqrt(displayedTransform.a * displayedTransform.a + displayedTransform.c * displayedTransform.c),
            0.001,
        )
        let displayedRadius = (presentation?.cornerRadius ?? frozenSurface.layer.cornerRadius) * displayedScale

        frozenSurface.layer.removeAllAnimations()
        frozenSurface.center = displayedCenter
        frozenSurface.transform = displayedTransform
        frozenSurface.alpha = displayedAlpha
        frozenSurface.layer.cornerRadius = displayedRadius / displayedScale
    }

    /// Waits briefly for an unmounted destination to appear, then aborts without revealing it.
    /// The clone remains visible during this bounded wait; it is never retained as a second
    /// transition lifecycle.
    func scheduleDestinationAbort() {
        guard let session,
              session.destinationWaitProbe == nil
        else {
            return
        }

        let generation = session.generation
        let transitionToken = session.token
        let probe = BrowserTabTransitionDisplayTurnProbe { [weak self, weak session] in
            guard let self, let session,
                  self.session === session,
                  session.generation == generation,
                  session.token == transitionToken
            else {
                return true
            }
            guard session.destinationWaitTurnsRemaining > 0 else {
                abortUnprovableTransition()
                return true
            }

            session.destinationWaitTurnsRemaining -= 1
            return false
        }
        session.destinationWaitProbe = probe
        probe.start()
    }

    func restoreLiveSurface(keepingAssociation: Bool = false) {
        guard let session else {
            return
        }
        guard let liveSurface = session.liveSurface else {
            session.originalCenter = nil
            session.originalTransform = nil
            session.originalAlpha = nil
            session.originalCornerRadius = nil
            session.originalCornerCurve = nil
            session.originalMasksToBounds = nil
            return
        }

        liveSurface.layer.removeAllAnimations()
        if let originalCenter = session.originalCenter {
            liveSurface.center = originalCenter
        }
        if let originalTransform = session.originalTransform {
            liveSurface.transform = originalTransform
        }
        if let originalAlpha = session.originalAlpha {
            liveSurface.alpha = originalAlpha
        }
        if let originalCornerRadius = session.originalCornerRadius {
            liveSurface.layer.cornerRadius = originalCornerRadius
        }
        if let originalCornerCurve = session.originalCornerCurve {
            liveSurface.layer.cornerCurve = originalCornerCurve
        }
        if let originalMasksToBounds = session.originalMasksToBounds {
            liveSurface.layer.masksToBounds = originalMasksToBounds
        }
        guard !keepingAssociation else {
            return
        }

        session.liveSurface = nil
        session.originalCenter = nil
        session.originalTransform = nil
        session.originalAlpha = nil
        session.originalCornerRadius = nil
        session.originalCornerCurve = nil
        session.originalMasksToBounds = nil
    }

    func revealDestination() {
        if let session {
            markDestinationRevealed()
            setOwnsVisibleSurface(false)
            registry.report(.destinationRevealed(session.tabID))
            session.destinationReveal?()
        }
    }

    func removeFrozenSurface() {
        guard let session,
              let frozenSurface = session.frozenSurface
        else {
            return
        }

        frozenSurface.removeFromSuperview()
        session.frozenSurface = nil
        reportCloneRemoved()
    }

    func reportCloneRemoved() {
        if let session {
            registry.report(.cloneRemoved(session.tabID))
        }
    }

    /// Aborts an unprovable browsing handoff without revealing a potentially blank surface.
    func handlePresentationUnavailable() {
        guard let session,
              session.destinationReadiness.requiresReadySurface,
              session.direction == .toBrowsing
        else {
            return
        }

        abortUnprovableTransition()
    }

    /// Ends a handoff when its destination cannot be proven safe to reveal.
    func abortUnprovableTransition() {
        guard let session else {
            return
        }

        let callback = session.presentationUnavailable
        finish()
        callback?()
    }

    func record(_ execution: BrowserTabTransitionExecution) {
        diagnostics.onExecution?(execution)
    }

    func finish() {
        guard let session else {
            return
        }

        let currentDirection = session.direction
        if currentDirection != .toOverview {
            clearParkedSurfaceAssociation()
        }
        let callback = session.completion
        endSession()
        callback?()
    }

    func cancelDestinationWait() {
        session?.destinationWaitProbe?.invalidate()
        session?.destinationWaitProbe = nil
        session?.destinationWaitTurnsRemaining = 0
    }
}
