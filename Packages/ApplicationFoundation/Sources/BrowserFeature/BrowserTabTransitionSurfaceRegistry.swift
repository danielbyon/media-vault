//
//  BrowserTabTransitionSurfaceRegistry.swift
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

    /// The registry's authoritative readiness result for one mounted boundary.
    enum Readiness: Equatable {
        case pending
        case ready
    }

    private final class Entry {
        weak var view: UIView?
        var representation: Representation
        var readiness: Readiness

        init(
            view: UIView,
            representation: Representation,
            readiness: Readiness,
        ) {
            self.view = view
            self.representation = representation
            self.readiness = readiness
        }
    }

    private var entries: [BrowserTabTransitionSurfaceRole: Entry] = [:]

    /// Called when registration or UIKit boundary layout may change destination geometry.
    var onChange: (() -> Void)?
    /// Called when destination layout changes without changing a registered boundary.
    var onDestinationLayoutChange: (() -> Void)?
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
    ) {
        if let entry = entries[role], entry.view === view {
            let nextReadiness: Readiness = entry.readiness == .ready || isReady ? .ready : .pending
            guard entry.representation != representation
                || entry.readiness != nextReadiness
            else {
                // Registration is also the layout notification used by UIKit hosts. The view may
                // have acquired a window or nonzero bounds without changing any stored metadata.
                onChange?()
                return
            }

            entry.representation = representation
            entry.readiness = nextReadiness
        } else {
            entries[role] = Entry(
                view: view,
                representation: representation,
                readiness: isReady ? .ready : .pending,
            )
        }
        onChange?()
    }

    /// Marks a still-registered boundary ready after its first committed display turn.
    func markReady(_ view: UIView, for role: BrowserTabTransitionSurfaceRole) {
        _ = setReadiness(.ready, view: view, for: role)
    }

    /// Clears readiness for an unchanged boundary before a new visual lifecycle begins.
    func resetReadiness(_ view: UIView, for role: BrowserTabTransitionSurfaceRole) {
        _ = setReadiness(.pending, view: view, for: role)
    }

    /// Records the one readiness result used by transition execution and later probes.
    @discardableResult
    func setReadiness(
        _ readiness: Readiness,
        view: UIView,
        for role: BrowserTabTransitionSurfaceRole,
    ) -> Bool {
        guard let entry = entries[role], entry.view === view, entry.readiness != readiness else {
            return false
        }

        entry.readiness = readiness
        onChange?()
        return true
    }

    /// Removes a boundary only when the caller still owns the registered view.
    func unregister(_ view: UIView, for role: BrowserTabTransitionSurfaceRole) {
        guard entries[role]?.view === view else {
            return
        }

        entries.removeValue(forKey: role)
        onChange?()
    }

    /// Reports changed layout evidence without publishing a surface lifecycle change.
    func notifyLayoutChanged() {
        onDestinationLayoutChange?()
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
              entry.readiness == .ready,
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
    var isReady = true
    @ViewBuilder
    let content: Content

    func makeUIViewController(context _: Context) -> BrowserTabTransitionSurfaceHostController<Content> {
        BrowserTabTransitionSurfaceHostController(
            role: role,
            registry: registry,
            isReady: isReady,
            content: content,
        )
    }

    func updateUIViewController(
        _ uiViewController: BrowserTabTransitionSurfaceHostController<Content>,
        context _: Context,
    ) {
        uiViewController.update(content: content, isReady: isReady)
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
    private var isReady: Bool

    init(
        role: BrowserTabTransitionSurfaceRole,
        registry: BrowserTabTransitionSurfaceRegistry,
        isReady: Bool,
        content: Content,
    ) {
        self.role = role
        self.registry = registry
        self.isReady = isReady
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
        registry.register(view, for: role, isReady: isReady)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        registry.register(view, for: role, isReady: isReady)
    }

    func update(content: Content, isReady: Bool) {
        self.isReady = isReady
        hostingController?.rootView = content
        registry.register(view, for: role, isReady: isReady)
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
    /// The attached destination is blocked by an app-owned presentation surface.
    case targetPresentationBlocked(BrowserTabID)
    /// The attached destination could not satisfy presentation readiness within its bounded wait.
    case targetPresentationUnavailable(BrowserTabID)
    /// The attached destination satisfied lifecycle presentation readiness.
    case targetPresentationReady(BrowserTabID)
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
final class BrowserTabTransitionDisplayTurnProbe: NSObject {
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
