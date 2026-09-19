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
    private final class Entry {
        weak var view: UIView?

        init(view: UIView) {
            self.view = view
        }
    }

    private var entries: [BrowserTabTransitionSurfaceRole: Entry] = [:]

    /// Called whenever a boundary mounts, unmounts, or lays out again.
    var onChange: (() -> Void)?

    /// Registers the exact page or card preview boundary.
    func register(_ view: UIView, for role: BrowserTabTransitionSurfaceRole) {
        if entries[role]?.view !== view {
            entries[role] = Entry(view: view)
        }
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

/// Owns only the temporary UIKit clone used during one Browser handoff.
@MainActor
final class BrowserTabTransitionUIKitCoordinator {
    private let registry: BrowserTabTransitionSurfaceRegistry
    private weak var overlay: BrowserTabTransitionOverlayView?
    private weak var frozenSurface: UIView?
    private weak var parkedSurface: UIView?
    private var parkedCardID: BrowserTabID?
    private var animator: UIViewPropertyAnimator?
    private var fallbackTask: Task<Void, Never>?
    private var animationGeneration = 0
    private var token: Int?
    private var direction: BrowserTabTransitionDirection?
    private var tabID: BrowserTabID?
    private var destinationRole: BrowserTabTransitionSurfaceRole?
    private var destinationFrame: CGRect?
    private var reduceMotion = false
    private var completion: (() -> Void)?

    init(registry: BrowserTabTransitionSurfaceRegistry = .init()) {
        self.registry = registry
        registry.onChange = { [weak self] in
            self?.surfaceChanged()
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

    /// Starts or retargets a frozen handoff after synchronously cloning the exact source view.
    func begin(
        token: Int,
        direction: BrowserTabTransitionDirection,
        tabID: BrowserTabID,
        reduceMotion: Bool,
        onPresentationChange: () -> Void,
        onCompletion: @escaping () -> Void,
    ) {
        cancelFallback()

        if isActive {
            if direction == .toBrowsing {
                _ = moveParkedSurfaceToOverlay()
            }
            materializePresentation()
            self.token = token
            self.direction = direction
            self.tabID = tabID
            destinationRole = nil
            destinationFrame = nil
            self.reduceMotion = reduceMotion
            frozenSurface?.alpha = 1
            completion = onCompletion
            if direction == .toBrowsing {
                clearParkedSurfaceAssociation()
            }
            onPresentationChange()
            waitForDestination()
            return
        }

        animationGeneration += 1
        self.token = token
        self.direction = direction
        self.tabID = tabID
        destinationRole = nil
        destinationFrame = nil
        self.reduceMotion = reduceMotion
        completion = onCompletion

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
              let sourceFrame = registry.frame(for: sourceRole, in: overlay),
              let clone = sourceView.snapshotView(afterScreenUpdates: false)
        else {
            onPresentationChange()
            scheduleFallback()
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
        onPresentationChange()
        waitForDestination()
    }

    /// Cancels the temporary handoff and invalidates all pending completions.
    func cancel() {
        cancelFallback()
        animationGeneration += 1
        animator?.stopAnimation(true)
        animator = nil
        frozenSurface?.removeFromSuperview()
        frozenSurface = nil
        clearParkedSurfaceAssociation()
        token = nil
        direction = nil
        tabID = nil
        destinationRole = nil
        destinationFrame = nil
        completion = nil
    }

    private func surfaceChanged() {
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
              frozenSurface != nil
        else {
            return
        }

        let role: BrowserTabTransitionSurfaceRole = direction == .toOverview
            ? .card(tabID)
            : .content(tabID)
        guard let destinationView = registry.view(for: role),
              let destinationRect = registry.frame(for: role, in: overlay)
        else {
            scheduleFallback()
            return
        }

        cancelFallback()
        if destinationRole == role,
           destinationFrame == destinationRect,
           animator != nil {
            return
        }
        if animator != nil {
            materializePresentation()
        }
        if hasMaterialAspectMismatch(destinationRect) {
            finishFallback()
            return
        }
        destinationRole = role
        destinationFrame = destinationRect
        if reduceMotion {
            completeWithOpacityOnly(destinationView: destinationView, destinationFrame: destinationRect)
        } else {
            animate(to: destinationView, destinationFrame: destinationRect)
        }
    }

    private func hasMaterialAspectMismatch(_ destinationFrame: CGRect) -> Bool {
        guard let frozenSurface,
              frozenSurface.bounds.width > 0,
              frozenSurface.bounds.height > 0,
              destinationFrame.width > 0,
              destinationFrame.height > 0
        else {
            return true
        }

        let sourceAspect = frozenSurface.bounds.width / frozenSurface.bounds.height
        let destinationAspect = destinationFrame.width / destinationFrame.height
        let relativeDifference = abs(sourceAspect - destinationAspect) / max(sourceAspect, destinationAspect)
        return relativeDifference > 0.08
    }

    private func animate(to destinationView: UIView, destinationFrame: CGRect) {
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
            duration: 0.38,
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
            } else {
                self.frozenSurface?.removeFromSuperview()
                self.frozenSurface = nil
            }
            finish()
        }
        animator = nextAnimator
        nextAnimator.startAnimation()
    }

    private func completeWithOpacityOnly(destinationView: UIView, destinationFrame: CGRect) {
        guard let frozenSurface,
              let direction
        else {
            finishFallback()
            return
        }

        if direction == .toOverview {
            parkFrozenSurface(in: destinationView)
            animator = nil
            finish()
            return
        }

        // A Reduce Motion handoff never transforms the clone. It only removes the exact card
        // image after the browsing surface has mounted beneath it.
        frozenSurface.frame = destinationFrame

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

            self.frozenSurface?.removeFromSuperview()
            self.frozenSurface = nil
            finish()
        }
        animator = fade
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
        fallbackTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else {
                return
            }
            guard let self,
                  animationGeneration == generation,
                  token == transitionToken
            else {
                return
            }

            finishFallback()
        }
    }

    private func finishFallback() {
        cancelFallback()
        guard token != nil else {
            return
        }

        animationGeneration += 1
        animator?.stopAnimation(true)
        animator = nil
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

            frozenSurface?.removeFromSuperview()
            frozenSurface = nil
            finish()
        }
        animator = fade
        fade.startAnimation()
    }

    private func finish() {
        cancelFallback()
        animationGeneration += 1
        if direction != .toOverview {
            clearParkedSurfaceAssociation()
        }
        token = nil
        direction = nil
        tabID = nil
        destinationRole = nil
        destinationFrame = nil
        let callback = completion
        completion = nil
        callback?()
    }

    private func cancelFallback() {
        fallbackTask?.cancel()
        fallbackTask = nil
    }
}
