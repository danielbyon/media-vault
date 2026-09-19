//
//  BrowserTabTransitionUIKitCoordinator.swift
//  MediaVault
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import SwiftUI
import UIKit

/// A weak registration for one exact Browser transition boundary.
@MainActor
final class BrowserTabTransitionSurfaceRegistry {
    enum Representation: Equatable {
        /// A SwiftUI or native preview that can be cloned for the handoff.
        case frozen
        /// A live UIKit surface whose pixels must move without reparenting or relayout.
        case live
    }

    private final class Entry {
        weak var view: UIView?
        var representation: Representation
        var isReady: Bool
        var readinessContext: BrowserWebKitReadinessContext?

        init(
            view: UIView,
            representation: Representation,
            isReady: Bool,
            readinessContext: BrowserWebKitReadinessContext?,
        ) {
            self.view = view
            self.representation = representation
            self.isReady = isReady
            self.readinessContext = readinessContext
        }
    }

    private var entries: [BrowserTabTransitionSurfaceRole: Entry] = [:]

    /// Called whenever a boundary mounts, unmounts, or lays out again.
    var onChange: (() -> Void)?
    /// Direct seam for lifecycle and visual-readiness ordering assertions.
    var onEvent: ((BrowserTabTransitionEvent) -> Void)?

    /// Registers the exact page or card preview boundary.
    ///
    /// A repeated registration for the same UIKit object preserves readiness. This matters for
    /// the retained browsing hierarchy: SwiftUI may update the bridge without the WebKit surface
    /// having left the window.
    func register(
        _ view: UIView,
        for role: BrowserTabTransitionSurfaceRole,
        representation: Representation = .frozen,
        isReady: Bool = true,
        readinessContext: BrowserWebKitReadinessContext? = nil,
    ) {
        if let entry = entries[role], entry.view === view {
            entry.representation = representation
            if entry.readinessContext != readinessContext {
                entry.isReady = isReady
            } else if isReady {
                entry.isReady = true
            }
            entry.readinessContext = readinessContext
        } else {
            entries[role] = Entry(
                view: view,
                representation: representation,
                isReady: isReady,
                readinessContext: readinessContext,
            )
        }
        onChange?()
    }

    /// Marks a still-registered boundary ready after its first committed display turn.
    func markReady(_ view: UIView, for role: BrowserTabTransitionSurfaceRole) {
        guard let entry = entries[role], entry.view === view, !entry.isReady else {
            return
        }

        entry.isReady = true
        onChange?()
    }

    /// Removes a boundary only when the caller still owns the registered view.
    func unregister(_ view: UIView, for role: BrowserTabTransitionSurfaceRole) {
        guard entries[role]?.view === view else {
            return
        }

        entries.removeValue(forKey: role)
        onChange?()
    }

    /// Returns the current UIKit view for a role.
    func view(for role: BrowserTabTransitionSurfaceRole) -> UIView? {
        entries[role]?.view
    }

    /// Returns the representation policy for one exact boundary.
    func representation(for role: BrowserTabTransitionSurfaceRole) -> Representation? {
        entries[role]?.representation
    }

    /// Returns whether a boundary has completed its attachment/layout/display-turn readiness.
    func isReady(for role: BrowserTabTransitionSurfaceRole) -> Bool {
        guard let entry = entries[role],
              let view = entry.view,
              entry.isReady,
              view.window != nil,
              view.bounds.width > 0,
              view.bounds.height > 0
        else {
            return false
        }

        return true
    }

    /// Converts one exact boundary into the shared overlay coordinate space.
    func frame(
        for role: BrowserTabTransitionSurfaceRole,
        in coordinateSpace: UIView,
    ) -> CGRect? {
        guard let view = view(for: role),
              view.window != nil,
              view.bounds.width > 0,
              view.bounds.height > 0
        else {
            return nil
        }

        return view.convert(view.bounds, to: coordinateSpace)
    }

    /// Returns the actual aspect ratio of a mounted transition boundary.
    func aspectRatio(for role: BrowserTabTransitionSurfaceRole) -> CGFloat? {
        guard let view = view(for: role),
              view.bounds.width > 0,
              view.bounds.height > 0
        else {
            return nil
        }

        return view.bounds.width / view.bounds.height
    }

    /// Returns the exact size of a mounted transition boundary when it has a usable layout.
    func geometry(for role: BrowserTabTransitionSurfaceRole) -> BrowserContentViewportGeometry? {
        guard let view = view(for: role),
              view.bounds.width > 0,
              view.bounds.height > 0
        else {
            return nil
        }

        return BrowserContentViewportGeometry(size: view.bounds.size)
    }

    /// Emits a bounded event without adding production logging or persistence.
    func report(_ event: BrowserTabTransitionEvent) {
        onEvent?(event)
    }
}

/// Hosts SwiftUI preview content in the exact UIKit boundary used for card snapshots.
@MainActor
@preconcurrency
struct BrowserTabTransitionSurfaceHost<Content: View>: UIViewControllerRepresentable {
    let role: BrowserTabTransitionSurfaceRole
    let registry: BrowserTabTransitionSurfaceRegistry
    @ViewBuilder
    let content: Content

    func makeUIViewController(context _: Context) -> BrowserTabTransitionSurfaceHostController<Content> {
        BrowserTabTransitionSurfaceHostController(
            role: role,
            registry: registry,
            content: content,
        )
    }

    func updateUIViewController(
        _ uiViewController: BrowserTabTransitionSurfaceHostController<Content>,
        context _: Context,
    ) {
        uiViewController.update(content: content)
    }

    static func dismantleUIViewController(
        _ uiViewController: BrowserTabTransitionSurfaceHostController<Content>,
        coordinator _: (),
    ) {
        uiViewController.detach()
    }
}

/// UIKit host whose root view is exactly the preview region, without card footer or padding.
@MainActor
final class BrowserTabTransitionSurfaceHostController<Content: View>: UIViewController {
    private let role: BrowserTabTransitionSurfaceRole
    private let registry: BrowserTabTransitionSurfaceRegistry
    private var hostingController: UIHostingController<Content>?

    init(
        role: BrowserTabTransitionSurfaceRole,
        registry: BrowserTabTransitionSurfaceRegistry,
        content: Content,
    ) {
        self.role = role
        self.registry = registry
        hostingController = UIHostingController(rootView: content)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        nil
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        view.isOpaque = false
        view.clipsToBounds = true

        guard let hostingController else {
            return
        }

        addChild(hostingController)
        hostingController.view.backgroundColor = .clear
        hostingController.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(hostingController.view)
        NSLayoutConstraint.activate([
            hostingController.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            hostingController.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            hostingController.view.topAnchor.constraint(equalTo: view.topAnchor),
            hostingController.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        hostingController.didMove(toParent: self)
        registry.register(view, for: role)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        registry.register(view, for: role)
    }

    func update(content: Content) {
        hostingController?.rootView = content
        registry.register(view, for: role)
    }

    func detach() {
        registry.unregister(view, for: role)
        hostingController?.willMove(toParent: nil)
        hostingController?.view.removeFromSuperview()
        hostingController?.removeFromParent()
        hostingController = nil
    }
}

/// A transparent, non-interactive overlay that shares one coordinate space with all boundaries.
@MainActor
@preconcurrency
struct BrowserTabTransitionOverlay: UIViewRepresentable {
    let coordinator: BrowserTabTransitionUIKitCoordinator

    func makeUIView(context _: Context) -> BrowserTabTransitionOverlayView {
        let view = BrowserTabTransitionOverlayView()
        coordinator.attach(overlay: view)
        return view
    }

    func updateUIView(_ uiView: BrowserTabTransitionOverlayView, context _: Context) {
        coordinator.attach(overlay: uiView)
    }

    static func dismantleUIView(
        _: BrowserTabTransitionOverlayView,
        coordinator _: (),
    ) {}
}

/// Overlay view used as the common coordinate space for frozen surfaces.
@MainActor
final class BrowserTabTransitionOverlayView: UIView {
    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = .clear
        isOpaque = false
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        nil
    }
}

/// Test-observable hooks for one transient transition decision.
///
/// The coordinator never logs through this seam. Production callers use the empty value, while
/// BrowserFeature tests can observe the selected execution branch and the real UIKit animator.
enum BrowserTabTransitionEvent: Equatable {
    /// The destination WebKit surface was attached to the single Browser host.
    case targetAttached(BrowserTabID)
    /// The attached destination did not yet match known-valid page pixels.
    case targetVisualInvalid(BrowserTabID)
    /// The attached destination had no trustworthy visual evidence source.
    case targetEvidenceUnavailable(BrowserTabID)
    /// The attached destination matched known-valid page pixels.
    case targetVisualReady(BrowserTabID)
    /// The normal geometry animator was installed.
    case geometryAnimatorCreated(BrowserTabID)
    /// The authoritative destination was made visible beneath or beside the clone.
    case destinationRevealed(BrowserTabID)
    /// The temporary clone was removed after the destination became visible.
    case cloneRemoved(BrowserTabID)
}

struct BrowserTabTransitionDiagnostics {
    var onExecution: ((BrowserTabTransitionExecution) -> Void)?
    var onAnimatorCreated: ((UIViewPropertyAnimator) -> Void)?
    var onEvent: ((BrowserTabTransitionEvent) -> Void)?

    init(
        onExecution: ((BrowserTabTransitionExecution) -> Void)? = nil,
        onAnimatorCreated: ((UIViewPropertyAnimator) -> Void)? = nil,
        onEvent: ((BrowserTabTransitionEvent) -> Void)? = nil,
    ) {
        self.onExecution = onExecution
        self.onAnimatorCreated = onAnimatorCreated
        self.onEvent = onEvent
    }
}

/// Delivers a bounded number of display turns without introducing a wall-clock transition delay.
@MainActor
private final class BrowserTabTransitionDisplayTurnProbe: NSObject {
    private let onTurn: () -> Bool
    private var displayLink: CADisplayLink?

    init(onTurn: @escaping () -> Bool) {
        self.onTurn = onTurn
        super.init()
    }

    func start() {
        let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
        displayLink = link
        link.add(to: .main, forMode: .common)
    }

    func invalidate() {
        displayLink?.invalidate()
        displayLink = nil
    }

    @objc
    private func tick(_ displayLink: CADisplayLink) {
        if onTurn() {
            displayLink.invalidate()
            self.displayLink = nil
        }
    }
}

/// Owns only the temporary UIKit representation used during one Browser handoff.
@MainActor
final class BrowserTabTransitionUIKitCoordinator {
    private let registry: BrowserTabTransitionSurfaceRegistry
    private weak var overlay: BrowserTabTransitionOverlayView?
    private weak var frozenSurface: UIView?
    private weak var liveSurface: UIView?
    private weak var parkedSurface: UIView?
    private var fallbackSurface: UIView?
    private var parkedCardID: BrowserTabID?
    private var fallbackRole: BrowserTabTransitionSurfaceRole?
    private var animator: UIViewPropertyAnimator?
    private var fallbackDisplayTurnProbe: BrowserTabTransitionDisplayTurnProbe?
    private var fallbackDisplayTurnsRemaining = 0
    private var animationGeneration = 0
    private var token: Int?
    private var direction: BrowserTabTransitionDirection?
    private var tabID: BrowserTabID?
    private var destinationRole: BrowserTabTransitionSurfaceRole?
    private var destinationFrame: CGRect?
    private var reduceMotion = false
    private var completion: (() -> Void)?
    private var destinationReveal: (() -> Void)?
    private var evidenceUnavailable: (() -> Void)?
    private var missingDestinationWasRecorded = false
    private var destinationRequiresReadiness = true
    private var liveSurfaceOriginalCenter: CGPoint?
    private var liveSurfaceOriginalTransform: CGAffineTransform?
    private var liveSurfaceOriginalAlpha: CGFloat?
    private var liveSurfaceOriginalCornerRadius: CGFloat?
    private var liveSurfaceOriginalCornerCurve: CALayerCornerCurve?
    private var liveSurfaceOriginalMasksToBounds: Bool?
    private var fallbackDestinationReveal: (() -> Void)?
    private let diagnostics: BrowserTabTransitionDiagnostics

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

    /// Whether a temporary clone currently owns the handoff.
    var isActive: Bool {
        token != nil
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
        cancelFallback()

        if isActive {
            if direction == .toBrowsing {
                _ = moveParkedSurfaceToOverlay()
            }
            materializePresentation()
            restoreLiveSurface()
            self.token = token
            self.direction = direction
            self.tabID = tabID
            destinationRole = nil
            destinationFrame = nil
            self.reduceMotion = reduceMotion
            self.destinationRequiresReadiness = destinationRequiresReadiness
            frozenSurface?.alpha = 1
            completion = onCompletion
            evidenceUnavailable = onEvidenceUnavailable
            destinationReveal = onDestinationVisible
            missingDestinationWasRecorded = false
            if direction == .toBrowsing {
                clearParkedSurfaceAssociation()
            }
            onFrozenSurfaceReady()
            onPresentationChange()
            waitForDestination()
            return
        }

        animationGeneration += 1
        clearFallbackSurface()
        self.token = token
        self.direction = direction
        self.tabID = tabID
        destinationRole = nil
        destinationFrame = nil
        self.reduceMotion = reduceMotion
        self.destinationRequiresReadiness = destinationRequiresReadiness
        completion = onCompletion
        evidenceUnavailable = onEvidenceUnavailable
        destinationReveal = onDestinationVisible
        missingDestinationWasRecorded = false

        if direction == .toOverview {
            clearParkedSurfaceAssociation()
        }

        if direction == .toBrowsing,
           parkedCardID == tabID,
           parkedSurface != nil,
           moveParkedSurfaceToOverlay() {
            // Reuse the exact clone that represented this selected card in overview. The
            // reducer may have refreshed its cache while overview was visible, but that must not
            // replace the image already handed to the user.
            frozenSurface?.alpha = 1
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
        frozenSurface = clone

        // The clone is installed before reducer state changes so SwiftUI can never remove the
        // only visible representation while the destination hierarchy is mounting.
        onFrozenSurfaceReady()
        onPresentationChange()
        waitForDestination()
    }

    /// Creates a fixed-bounds, memory-only representation when UIKit cannot provide its fast
    /// replica. The fallback is deliberately local to Browser transitions: it never asks WebKit
    /// to capture a page and never serializes the rendered image as PNG data.
    private func makeFrozenSurface(from sourceView: UIView) -> UIView? {
        if let replica = sourceView.snapshotView(afterScreenUpdates: false) {
            return replica
        }

        guard sourceView.bounds.width > 0,
              sourceView.bounds.height > 0
        else {
            return nil
        }

        let format = UIGraphicsImageRendererFormat()
        format.scale = sourceView.window?.windowScene?.screen.scale ?? sourceView.traitCollection.displayScale
        format.opaque = sourceView.isOpaque
        let renderer = UIGraphicsImageRenderer(size: sourceView.bounds.size, format: format)
        let image = renderer.image { context in
            if !sourceView.drawHierarchy(in: sourceView.bounds, afterScreenUpdates: false) {
                sourceView.layer.render(in: context.cgContext)
            }
        }
        guard image.size.width > 0, image.size.height > 0 else {
            return nil
        }

        let imageView = UIImageView(image: image)
        imageView.contentMode = .scaleToFill
        imageView.clipsToBounds = true
        return imageView
    }

    /// Cancels the temporary handoff and invalidates all pending completions.
    func cancel() {
        cancelFallback()
        animationGeneration += 1
        animator?.stopAnimation(true)
        animator = nil
        restoreLiveSurface()
        frozenSurface?.removeFromSuperview()
        frozenSurface = nil
        clearParkedSurfaceAssociation()
        clearFallbackSurface()
        token = nil
        direction = nil
        tabID = nil
        destinationRole = nil
        destinationFrame = nil
        completion = nil
        destinationReveal = nil
        evidenceUnavailable = nil
        missingDestinationWasRecorded = false
        destinationRequiresReadiness = true
    }

    private func surfaceChanged() {
        if let fallbackSurface,
           let fallbackRole,
           let overlay,
           registry.isReady(for: fallbackRole),
           registry.frame(for: fallbackRole, in: overlay) != nil {
            completeFallbackHandoff(fallbackSurface: fallbackSurface)
        }

        if let parkedCardID {
            let role = BrowserTabTransitionSurfaceRole.card(parkedCardID)
            if let parkedSurface,
               let cardView = registry.view(for: role),
               parkedSurface.superview === cardView {
                parkedSurface.frame = cardView.bounds
                parkedSurface.layer.cornerRadius = BrowserTabTransitionPresentation.cardCornerRadius
            } else if registry.view(for: role) == nil {
                clearParkedSurfaceAssociation()
            }
        }

        guard isActive else {
            return
        }

        Task { @MainActor [weak self] in
            await Task.yield()
            self?.waitForDestination()
        }
    }

    private func waitForDestination() {
        guard let direction,
              let tabID,
              let overlay,
              frozenSurface != nil || liveSurface != nil
        else {
            return
        }

        let role: BrowserTabTransitionSurfaceRole = direction == .toOverview
            ? .card(tabID)
            : .content(tabID)
        guard let destinationView = registry.view(for: role),
              let destinationRect = registry.frame(for: role, in: overlay)
        else {
            if !missingDestinationWasRecorded {
                record(.missingDestination)
                missingDestinationWasRecorded = true
            }
            scheduleFallback()
            return
        }
        guard !destinationRequiresReadiness || registry.isReady(for: role) else {
            if !missingDestinationWasRecorded {
                record(.missingDestination)
                missingDestinationWasRecorded = true
            }
            // An attached destination that is still visually unready has a usable exact clone,
            // so keep the handoff active until WebKit proves the expected page pixels. The
            // bounded missing-mount fallback is only for a destination that has not materialized
            // at all; opacity completion here would reveal a blank backing surface.
            cancelFallback()
            return
        }

        cancelFallback()
        missingDestinationWasRecorded = false
        if destinationRole == role,
           animator != nil {
            return
        }
        if animator != nil {
            materializePresentation()
        }
        if hasMaterialAspectMismatch(destinationRect) {
            record(.aspectMismatch)
            if liveSurface != nil {
                // A live source cannot use the frozen fallback path: finish the handoff while
                // restoring the existing WebKit surface instead of leaving the coordinator active.
                finish()
            } else {
                finishFallback()
            }
            return
        }
        destinationRole = role
        destinationFrame = destinationRect
        if reduceMotion {
            record(.reduceMotion)
            completeWithOpacityOnly(destinationView: destinationView, destinationFrame: destinationRect)
        } else {
            record(.geometry)
            animate(to: destinationView, destinationFrame: destinationRect)
        }
    }

    private func hasMaterialAspectMismatch(_ destinationFrame: CGRect) -> Bool {
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

    private func animate(to destinationView: UIView, destinationFrame: CGRect) {
        if liveSurface != nil {
            animateLiveSurface(to: destinationView, destinationFrame: destinationFrame)
            return
        }

        guard let frozenSurface,
              let direction,
              destinationFrame.width > 0,
              frozenSurface.bounds.width > 0
        else {
            finishFallback()
            return
        }

        animationGeneration += 1
        animator?.stopAnimation(true)
        let destinationScale = destinationFrame.width / frozenSurface.bounds.width
        let destinationRadius = BrowserTabTransitionPresentation(
            direction: direction,
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
        let generation = animationGeneration
        let transitionToken = token
        nextAnimator.addCompletion { [weak self, weak destinationView] _ in
            guard let self else {
                return
            }
            guard animationGeneration == generation,
                  token == transitionToken
            else {
                return
            }

            animator = nil
            if direction == .toOverview, let destinationView {
                parkFrozenSurface(in: destinationView)
                revealDestination()
            } else {
                revealDestination()
                removeFrozenSurface()
            }
            finish()
        }
        animator = nextAnimator
        if let tabID {
            registry.report(.geometryAnimatorCreated(tabID))
        }
        diagnostics.onAnimatorCreated?(nextAnimator)
        nextAnimator.startAnimation()
    }

    private var transitionSourceSurface: UIView? {
        liveSurface ?? frozenSurface
    }

    private func prepareLiveSurface(_ surface: UIView) {
        liveSurface = surface
        liveSurfaceOriginalCenter = surface.center
        liveSurfaceOriginalTransform = surface.transform
        liveSurfaceOriginalAlpha = surface.alpha
        liveSurfaceOriginalCornerRadius = surface.layer.cornerRadius
        liveSurfaceOriginalCornerCurve = surface.layer.cornerCurve
        liveSurfaceOriginalMasksToBounds = surface.layer.masksToBounds
        surface.layer.cornerCurve = .continuous
        surface.layer.masksToBounds = true
    }

    private func animateLiveSurface(to destinationView: UIView, destinationFrame: CGRect) {
        guard let liveSurface,
              let direction,
              let overlay,
              let superview = liveSurface.superview,
              destinationFrame.width > 0,
              liveSurface.bounds.width > 0
        else {
            // A live page has no safe frozen fallback here. End the handoff while restoring the
            // existing WebKit surface instead of leaving the coordinator active without a host.
            if liveSurface != nil {
                finish()
            } else {
                finishFallback()
            }
            return
        }

        animationGeneration += 1
        animator?.stopAnimation(true)
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
            direction: direction,
        ).destinationCornerRadius
        let localDestinationRadius = destinationRadius / max(destinationScale, 0.001)
        let originalTransform = liveSurfaceOriginalTransform ?? .identity
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
        let generation = animationGeneration
        let transitionToken = token
        nextAnimator.addCompletion { [weak self] _ in
            guard let self,
                  animationGeneration == generation,
                  token == transitionToken
            else {
                return
            }

            animator = nil
            if direction == .toOverview,
               let exactCardSurface = makeRenderedSurface(from: liveSurface) {
                // snapshotView(afterScreenUpdates: false) is a fast path for ordinary UIKit
                // surfaces, but WebKit may return an uncommitted replica. Capture the already
                // composited live layer instead, before restoring the page to its full viewport.
                frozenSurface = exactCardSurface
                parkFrozenSurface(in: destinationView)
                revealDestination()
            } else {
                revealDestination()
            }
            restoreLiveSurface()
            finish()
        }
        animator = nextAnimator
        if let tabID {
            registry.report(.geometryAnimatorCreated(tabID))
        }
        diagnostics.onAnimatorCreated?(nextAnimator)
        nextAnimator.startAnimation()
    }

    /// Creates the exact card surface from the live layer after the WebKit compositor has moved it.
    ///
    /// This path is intentionally separate from `makeFrozenSurface(from:)`: a WebKit
    /// `snapshotView` can be non-nil while still containing no committed page pixels. The live
    /// layer renderer gives the direct-live fallback a fixed-bounds card representation without
    /// asking WebKit to navigate, resize, or serialize reducer preview state.
    private func makeRenderedSurface(from sourceView: UIView) -> UIView? {
        guard sourceView.bounds.width > 0,
              sourceView.bounds.height > 0
        else {
            return nil
        }

        let format = UIGraphicsImageRendererFormat()
        format.scale = sourceView.window?.windowScene?.screen.scale ?? sourceView.traitCollection.displayScale
        format.opaque = sourceView.isOpaque
        let image = UIGraphicsImageRenderer(size: sourceView.bounds.size, format: format).image { context in
            sourceView.layer.render(in: context.cgContext)
        }
        guard image.size.width > 0,
              image.size.height > 0
        else {
            return nil
        }

        let imageView = UIImageView(image: image)
        imageView.contentMode = .scaleToFill
        imageView.clipsToBounds = true
        return imageView
    }

    private func completeWithOpacityOnly(destinationView: UIView, destinationFrame: CGRect) {
        if let liveSurface,
           direction == .toOverview,
           let exactCardSurface = makeRenderedSurface(from: liveSurface) {
            // Reduced Motion removes the geometry animation, but the overview still receives
            // the exact rendered page rather than exposing a cached or placeholder preview.
            frozenSurface = exactCardSurface
            parkFrozenSurface(in: destinationView)
            revealDestination()
            restoreLiveSurface()
            animator = nil
            finish()
            return
        }

        if liveSurface != nil {
            revealDestination()
            restoreLiveSurface()
            animator = nil
            finish()
            return
        }

        guard let frozenSurface,
              let direction
        else {
            finishFallback()
            return
        }

        if direction == .toOverview {
            revealDestination()
            parkFrozenSurface(in: destinationView)
            animator = nil
            finish()
            return
        }

        // A Reduce Motion handoff never transforms the clone. It only removes the exact card
        // image after the browsing surface has mounted beneath it.
        frozenSurface.frame = destinationFrame
        revealDestination()

        let fade = UIViewPropertyAnimator(duration: 0.15, curve: .easeOut) { [weak frozenSurface] in
            frozenSurface?.alpha = 0
        }
        let generation = animationGeneration
        let transitionToken = token
        fade.addCompletion { [weak self] _ in
            guard let self,
                  animationGeneration == generation,
                  token == transitionToken
            else {
                return
            }

            removeFrozenSurface()
            finish()
        }
        animator = fade
        diagnostics.onAnimatorCreated?(fade)
        fade.startAnimation()
    }

    private func parkFrozenSurface(in cardView: UIView) {
        guard let frozenSurface else {
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
        parkedSurface = frozenSurface
        parkedCardID = tabID
    }

    /// Reparents a reduced-motion card clone before a rapid reverse can retarget it.
    @discardableResult
    private func moveParkedSurfaceToOverlay() -> Bool {
        guard let parkedSurface,
              let overlay
        else {
            return false
        }

        let frame = parkedSurface.convert(parkedSurface.bounds, to: overlay)
        parkedSurface.removeFromSuperview()
        overlay.addSubview(parkedSurface)
        parkedSurface.frame = frame
        frozenSurface = parkedSurface
        self.parkedSurface = nil
        parkedCardID = nil
        return true
    }

    private func clearParkedSurfaceAssociation() {
        parkedSurface?.removeFromSuperview()
        parkedSurface = nil
        parkedCardID = nil
    }

    private func materializePresentation() {
        if let liveSurface {
            let presentation = liveSurface.layer.presentation()
            animationGeneration += 1
            animator?.pauseAnimation()
            animator?.stopAnimation(true)
            animator = nil
            if let presentation {
                liveSurface.layer.removeAllAnimations()
                liveSurface.center = presentation.position
                liveSurface.transform = presentation.affineTransform()
                liveSurface.alpha = CGFloat(presentation.opacity)
                liveSurface.layer.cornerRadius = presentation.cornerRadius
            }
            return
        }

        guard let frozenSurface else {
            animator = nil
            return
        }

        let presentation = frozenSurface.layer.presentation()
        animationGeneration += 1
        animator?.pauseAnimation()
        animator?.stopAnimation(true)
        animator = nil

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

    private func scheduleFallback() {
        cancelFallback()
        let generation = animationGeneration
        let transitionToken = token
        fallbackDisplayTurnsRemaining = 8
        let probe = BrowserTabTransitionDisplayTurnProbe { [weak self] in
            guard let self,
                  animationGeneration == generation,
                  token == transitionToken
            else {
                return true
            }
            guard fallbackDisplayTurnsRemaining > 0 else {
                finishFallback()
                return true
            }

            fallbackDisplayTurnsRemaining -= 1
            return false
        }
        fallbackDisplayTurnProbe = probe
        probe.start()
    }

    private func finishFallback() {
        cancelFallback()
        guard let direction,
              let tabID,
              let overlay
        else {
            finish()
            return
        }

        // A live WebKit source remains the only truthful representation while its card
        // destination is still mounting. Hiding it here would recreate the black-frame bug.
        if direction == .toOverview, liveSurface != nil {
            return
        }

        guard let frozenSurface else {
            finish()
            return
        }

        animationGeneration += 1
        animator?.stopAnimation(true)
        animator = nil

        let role: BrowserTabTransitionSurfaceRole = direction == .toOverview
            ? .card(tabID)
            : .content(tabID)
        if registry.isReady(for: role),
           registry.frame(for: role, in: overlay) != nil {
            // The authoritative destination is visible before the frozen representation begins
            // its opacity handoff. This ordering prevents a black frame in either direction.
            revealDestination()
            let fade = UIViewPropertyAnimator(
                duration: reduceMotion ? 0.15 : 0.2,
                curve: .easeOut,
            ) { [weak frozenSurface] in
                frozenSurface?.alpha = 0
            }
            let generation = animationGeneration
            let transitionToken = token
            fade.addCompletion { [weak self] _ in
                guard let self,
                      animationGeneration == generation,
                      token == transitionToken
                else {
                    return
                }

                frozenSurface.removeFromSuperview()
                self.frozenSurface = nil
                reportCloneRemoved()
                finish()
            }
            animator = fade
            diagnostics.onAnimatorCreated?(fade)
            fade.startAnimation()
            return
        }

        // A destination that never mounted cannot be faded away safely. Retain the valid clone
        // as a temporary visible fallback. It is removed only after the registry reports a
        // ready destination, so an empty wrapper can never expose a black frame.
        fallbackSurface = frozenSurface
        fallbackRole = role
        fallbackDestinationReveal = destinationReveal
        self.frozenSurface = nil
        finish()
    }

    private func completeFallbackHandoff(fallbackSurface: UIView) {
        guard let fallbackRole,
              registry.isReady(for: fallbackRole),
              let overlay,
              registry.frame(for: fallbackRole, in: overlay) != nil,
              animator == nil
        else {
            return
        }

        revealFallbackDestination()
        let generation = animationGeneration
        let transitionToken = token
        let fade = UIViewPropertyAnimator(duration: 0.15, curve: .easeOut) {
            fallbackSurface.alpha = 0
        }
        fade.addCompletion { [weak self, weak fallbackSurface] _ in
            guard let self,
                  animationGeneration == generation,
                  token == transitionToken
            else {
                return
            }

            animator = nil
            fallbackSurface?.removeFromSuperview()
            reportCloneRemoved()
            self.fallbackSurface = nil
            self.fallbackRole = nil
            fallbackDestinationReveal = nil
            // The normal fallback path already finished the logical transition before retaining
            // this clone. Keep the cleanup safe if a future path retains it while still active.
            if token != nil {
                finish()
            }
        }
        animator = fade
        diagnostics.onAnimatorCreated?(fade)
        fade.startAnimation()
    }

    private func clearFallbackSurface() {
        fallbackSurface?.removeFromSuperview()
        fallbackSurface = nil
        fallbackRole = nil
        fallbackDestinationReveal = nil
    }

    private func restoreLiveSurface() {
        guard let liveSurface else {
            liveSurfaceOriginalCenter = nil
            liveSurfaceOriginalTransform = nil
            liveSurfaceOriginalAlpha = nil
            liveSurfaceOriginalCornerRadius = nil
            liveSurfaceOriginalCornerCurve = nil
            liveSurfaceOriginalMasksToBounds = nil
            return
        }

        liveSurface.layer.removeAllAnimations()
        if let originalCenter = liveSurfaceOriginalCenter {
            liveSurface.center = originalCenter
        }
        if let originalTransform = liveSurfaceOriginalTransform {
            liveSurface.transform = originalTransform
        }
        if let originalAlpha = liveSurfaceOriginalAlpha {
            liveSurface.alpha = originalAlpha
        }
        if let originalCornerRadius = liveSurfaceOriginalCornerRadius {
            liveSurface.layer.cornerRadius = originalCornerRadius
        }
        if let originalCornerCurve = liveSurfaceOriginalCornerCurve {
            liveSurface.layer.cornerCurve = originalCornerCurve
        }
        if let originalMasksToBounds = liveSurfaceOriginalMasksToBounds {
            liveSurface.layer.masksToBounds = originalMasksToBounds
        }
        self.liveSurface = nil
        liveSurfaceOriginalCenter = nil
        liveSurfaceOriginalTransform = nil
        liveSurfaceOriginalAlpha = nil
        liveSurfaceOriginalCornerRadius = nil
        liveSurfaceOriginalCornerCurve = nil
        liveSurfaceOriginalMasksToBounds = nil
    }

    private func revealDestination() {
        if let tabID {
            registry.report(.destinationRevealed(tabID))
        }
        destinationReveal?()
    }

    private func revealFallbackDestination() {
        if let tabID {
            registry.report(.destinationRevealed(tabID))
        }
        fallbackDestinationReveal?()
    }

    private func removeFrozenSurface() {
        guard let frozenSurface else {
            return
        }

        frozenSurface.removeFromSuperview()
        self.frozenSurface = nil
        reportCloneRemoved()
    }

    private func reportCloneRemoved() {
        if let tabID {
            registry.report(.cloneRemoved(tabID))
        }
    }

    /// Aborts an unprovable browsing handoff without revealing a potentially blank surface.
    private func handleEvidenceUnavailable() {
        guard isActive,
              destinationRequiresReadiness,
              direction == .toBrowsing
        else {
            return
        }

        let callback = evidenceUnavailable
        frozenSurface?.removeFromSuperview()
        frozenSurface = nil
        finish()
        callback?()
    }

    private func record(_ execution: BrowserTabTransitionExecution) {
        diagnostics.onExecution?(execution)
    }

    private func finish() {
        cancelFallback()
        animationGeneration += 1
        restoreLiveSurface()
        if direction != .toOverview {
            clearParkedSurfaceAssociation()
        }
        frozenSurface = nil
        token = nil
        direction = nil
        tabID = nil
        destinationRole = nil
        destinationFrame = nil
        let callback = completion
        completion = nil
        destinationReveal = nil
        evidenceUnavailable = nil
        missingDestinationWasRecorded = false
        destinationRequiresReadiness = true
        callback?()
    }

    private func cancelFallback() {
        fallbackDisplayTurnProbe?.invalidate()
        fallbackDisplayTurnProbe = nil
        fallbackDisplayTurnsRemaining = 0
    }
}
