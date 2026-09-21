//
//  BrowserTabTransitionUIKitCoordinator+Execution.swift
//  MediaVault
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import UIKit
import WebKit

@MainActor
extension BrowserTabTransitionUIKitCoordinator {
    /// Creates a fixed-bounds, memory-only representation from the already visible surface.
    ///
    /// WebKit's `snapshotView` can return a nonnil but blank replica, so WebKit surfaces use the
    /// public hierarchy renderer instead. The result remains an in-memory UIKit image view; no
    /// page snapshot request or serialized preview data participates in the active transition.
    func makeFrozenSurface(from sourceView: UIView) -> UIView? {
        if !(sourceView is WKWebView),
           let replica = sourceView.snapshotView(afterScreenUpdates: false) {
            return replica
        }

        return BrowserSurfaceRenderer.imageView(
            from: sourceView,
            afterScreenUpdates: false,
            opaque: sourceView.isOpaque,
            renderingPolicy: sourceView is WKWebView ? .webKit : .appOwnedTransition,
        )
    }

    /// Cancels the temporary handoff and invalidates all pending completions.
    func cancel() {
        clearParkedSurfaceAssociation()
        endSession()
    }

    func surfaceChanged() {
        if let parkedState = parkedSurface {
            let role = BrowserTabTransitionSurfaceRole.card(parkedState.cardID)
            if let cardView = registry.view(for: role) {
                if parkedState.surface.superview !== cardView {
                    parkedState.surface.removeFromSuperview()
                    cardView.addSubview(parkedState.surface)
                }
                parkedState.surface.frame = cardView.bounds
                parkedState.surface.layer.cornerRadius = BrowserTabTransitionPresentation.cardCornerRadius
            } else {
                clearParkedSurfaceAssociation()
            }
        }

        guard isActive else {
            return
        }
        guard !surfaceChangeTaskScheduled else {
            return
        }
        guard let scheduledSession = session else {
            return
        }

        surfaceChangeTaskScheduled = true
        let scheduledToken = scheduledSession.token
        Task { @MainActor [weak self, weak scheduledSession] in
            await Task.yield()
            guard let self,
                  let scheduledSession,
                  session === scheduledSession,
                  session?.token == scheduledToken
            else {
                return
            }

            surfaceChangeTaskScheduled = false
            waitForDestination()
        }
    }

    func waitForDestination() {
        guard let session,
              let overlay,
              session.frozenSurface != nil || session.liveSurface != nil
        else {
            return
        }

        let role: BrowserTabTransitionSurfaceRole = session.direction == .toOverview
            ? .card(session.tabID)
            : .content(session.tabID)
        guard let destinationView = registry.view(for: role),
              let destinationRect = registry.frame(for: role, in: overlay)
        else {
            if !session.missingDestinationWasRecorded {
                record(.missingDestination)
                session.missingDestinationWasRecorded = true
            }
            scheduleDestinationAbort()
            return
        }
        guard !session.destinationRequiresReadiness || registry.isReady(for: role) else {
            if !session.missingDestinationWasRecorded {
                record(.missingDestination)
                session.missingDestinationWasRecorded = true
            }
            // An attached destination that is still visually unready has a usable exact clone.
            // Keep it visible until the readiness owner either proves page pixels or reports that
            // the evidence cannot be established.
            cancelDestinationWait()
            return
        }

        cancelDestinationWait()
        session.missingDestinationWasRecorded = false
        if session.destinationRole == role,
           session.animator != nil {
            return
        }
        if session.animator != nil {
            materializePresentation()
        }
        if hasMaterialAspectMismatch(destinationRect) {
            record(.aspectMismatch)
            if session.direction == .toBrowsing,
               session.frozenSurface != nil {
                // Preserve the exact frozen card while revealing the mounted browsing surface.
                // The material geometry guard still prevents an unsafe transform.
                completeWithOpacityOnly(
                    destinationView: destinationView,
                    destinationFrame: destinationRect,
                )
            } else {
                // A live source cannot use the frozen fallback path: finish the handoff while
                // restoring the existing WebKit surface instead of leaving the coordinator active.
                finish()
            }
            return
        }
        session.destinationRole = role
        session.destinationFrame = destinationRect
        if session.reduceMotion {
            record(.reduceMotion)
            completeWithOpacityOnly(destinationView: destinationView, destinationFrame: destinationRect)
        } else {
            record(.geometry)
            animate(to: destinationView, destinationFrame: destinationRect)
        }
    }

    func hasMaterialAspectMismatch(_ destinationFrame: CGRect) -> Bool {
        guard let sourceSurface = transitionSourceSurface,
              sourceSurface.bounds.width > 0,
              sourceSurface.bounds.height > 0,
              destinationFrame.width > 0,
              destinationFrame.height > 0
        else {
            return true
        }

        let sourceAspect = sourceSurface.bounds.width / sourceSurface.bounds.height
        let destinationAspect = destinationFrame.width / destinationFrame.height
        let relativeDifference = abs(sourceAspect - destinationAspect) / max(sourceAspect, destinationAspect)
        return relativeDifference > 0.08
    }

    func animate(to destinationView: UIView, destinationFrame: CGRect) {
        guard let session else {
            return
        }

        if session.liveSurface != nil {
            animateLiveSurface(to: destinationView, destinationFrame: destinationFrame)
            return
        }

        guard let frozenSurface = session.frozenSurface,
              destinationFrame.width > 0,
              frozenSurface.bounds.width > 0
        else {
            finish()
            return
        }

        session.generation += 1
        session.animator?.stopAnimation(true)
        let destinationScale = destinationFrame.width / frozenSurface.bounds.width
        let destinationRadius = BrowserTabTransitionPresentation(
            direction: session.direction,
        ).destinationCornerRadius
        let localDestinationRadius = destinationRadius / max(destinationScale, 0.001)

        let nextAnimator = UIViewPropertyAnimator(
            duration: 0.22,
            curve: .easeInOut,
        ) { [weak frozenSurface] in
            guard let frozenSurface else {
                return
            }

            frozenSurface.center = CGPoint(x: destinationFrame.midX, y: destinationFrame.midY)
            frozenSurface.transform = CGAffineTransform(
                scaleX: destinationScale,
                y: destinationScale,
            )
            frozenSurface.layer.cornerRadius = localDestinationRadius
        }
        let generation = session.generation
        let transitionToken = session.token
        nextAnimator.addCompletion { [weak self, weak session, weak destinationView] _ in
            guard let self, let session else {
                return
            }
            guard session.generation == generation,
                  session.token == transitionToken
            else {
                return
            }

            session.animator = nil
            if session.direction == .toOverview, let destinationView {
                parkFrozenSurface(in: destinationView)
                revealDestination()
            } else {
                revealDestination()
                removeFrozenSurface()
            }
            finish()
        }
        session.animator = nextAnimator
        registry.report(.geometryAnimatorCreated(session.tabID))
        diagnostics.onAnimatorCreated?(nextAnimator)
        nextAnimator.startAnimation()
    }

    private var transitionSourceSurface: UIView? {
        session?.liveSurface ?? session?.frozenSurface
    }

    func prepareLiveSurface(_ surface: UIView) {
        guard let session else {
            return
        }

        session.liveSurface = surface
        session.originalCenter = surface.center
        session.originalTransform = surface.transform
        session.originalAlpha = surface.alpha
        session.originalCornerRadius = surface.layer.cornerRadius
        session.originalCornerCurve = surface.layer.cornerCurve
        session.originalMasksToBounds = surface.layer.masksToBounds
        surface.layer.cornerCurve = .continuous
        surface.layer.masksToBounds = true
    }

    func animateLiveSurface(to destinationView: UIView, destinationFrame: CGRect) {
        guard let session,
              let liveSurface = session.liveSurface,
              let overlay,
              let superview = liveSurface.superview,
              destinationFrame.width > 0,
              liveSurface.bounds.width > 0
        else {
            // A live page has no safe frozen fallback here. End the handoff while restoring the
            // existing WebKit surface instead of leaving the coordinator active without a host.
            if session?.liveSurface != nil {
                finish()
            } else {
                finish()
            }
            return
        }

        session.generation += 1
        session.animator?.stopAnimation(true)
        let sourceFrame = liveSurface.convert(liveSurface.bounds, to: overlay)
        let sourceCenter = liveSurface.convert(
            CGPoint(x: liveSurface.bounds.midX, y: liveSurface.bounds.midY),
            to: superview,
        )
        let destinationCenter = overlay.convert(
            CGPoint(x: destinationFrame.midX, y: destinationFrame.midY),
            to: superview,
        )
        let destinationScale = destinationFrame.width / max(sourceFrame.width, 0.001)
        let destinationRadius = BrowserTabTransitionPresentation(
            direction: session.direction,
        ).destinationCornerRadius
        let localDestinationRadius = destinationRadius / max(destinationScale, 0.001)
        let originalTransform = session.originalTransform ?? .identity
        let destinationTransform = CGAffineTransform(
            translationX: destinationCenter.x - sourceCenter.x,
            y: destinationCenter.y - sourceCenter.y,
        )
        .concatenating(originalTransform)
        .scaledBy(
            x: destinationScale,
            y: destinationScale,
        )

        let nextAnimator = UIViewPropertyAnimator(
            duration: 0.22,
            curve: .easeInOut,
        ) { [weak liveSurface] in
            guard let liveSurface else {
                return
            }

            // The WebKit view keeps its Auto Layout bounds. Only the compositor transform and
            // layer mask change, so WebKit never receives a resize or a new page attachment.
            liveSurface.transform = destinationTransform
            liveSurface.layer.cornerRadius = localDestinationRadius
        }
        let generation = session.generation
        let transitionToken = session.token
        nextAnimator.addCompletion { [weak self, weak session] (_: UIViewAnimatingPosition) in
            guard let self, let session,
                  session.generation == generation,
                  session.token == transitionToken
            else {
                return
            }

            session.animator = nil
            if session.direction == .toOverview,
               let exactCardSurface = makeRenderedSurface(from: liveSurface) {
                // snapshotView(afterScreenUpdates: false) is a fast path for ordinary UIKit
                // surfaces, but WebKit may return an uncommitted replica. Capture the already
                // composited live layer instead, before restoring the page to its full viewport.
                session.frozenSurface = exactCardSurface
                parkFrozenSurface(in: destinationView)
                revealDestination()
            } else {
                revealDestination()
            }
            restoreLiveSurface()
            finish()
        }
        session.animator = nextAnimator
        registry.report(.geometryAnimatorCreated(session.tabID))
        diagnostics.onAnimatorCreated?(nextAnimator)
        nextAnimator.startAnimation()
    }
}
