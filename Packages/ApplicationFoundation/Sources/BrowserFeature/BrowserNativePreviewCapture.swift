//
//  BrowserNativePreviewCapture.swift
//  MediaVault
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import PresentationSupport
import SwiftUI
import UIKit

/// Owns the short-lived capture seam for the currently mounted app-owned Browser surface.
///
/// The controller receives the exact host view created for the native Browser surface. It never
/// searches an arbitrary ancestor or captures the surrounding Browser chrome, and it returns PNG
/// bytes to the view that requested the capture so reducer state never receives a platform view.
@MainActor
final class BrowserNativePreviewCaptureController {
    private weak var surfaceView: UIView?
    private let drawHierarchy: @MainActor (UIView, CGRect, Bool) -> Bool

    init(
        drawHierarchy: @escaping @MainActor (UIView, CGRect, Bool) -> Bool = {
            view,
            bounds,
            afterScreenUpdates in
            view.drawHierarchy(in: bounds, afterScreenUpdates: afterScreenUpdates)
        },
    ) {
        self.drawHierarchy = drawHierarchy
    }

    /// Registers the explicit mounted native surface boundary.
    func attach(surface: UIView) {
        surfaceView = surface
    }

    /// Releases the registered surface when SwiftUI dismantles its host.
    func detach(surface: UIView) {
        if surfaceView === surface {
            surfaceView = nil
        }
    }

    /// Captures the mounted surface and rejects renderer failures instead of caching empty data.
    func capture() -> Data? {
        guard let surface = surfaceView,
              surface.window != nil,
              surface.bounds.width > 0,
              surface.bounds.height > 0
        else {
            return nil
        }

        // Preview data preserves the mounted surface's display scale. The card applies its own
        // aspect-fill policy when it renders this disposable cache representation.
        return BrowserSurfaceRenderer.image(
            from: surface,
            afterScreenUpdates: true,
            opaque: false,
            renderingPolicy: .nativePreview,
            drawHierarchy: drawHierarchy,
        )?.pngData()
    }
}

/// Hosts one app-owned native Browser surface in a named UIKit boundary.
@MainActor
@preconcurrency
struct BrowserNativePreviewCapture<Content: View>: UIViewControllerRepresentable {
    let content: Content
    let controller: BrowserNativePreviewCaptureController
    let transitionRegistry: BrowserTabTransitionSurfaceRegistry?
    let transitionRole: BrowserTabTransitionSurfaceRole?

    init(
        content: Content,
        controller: BrowserNativePreviewCaptureController,
        transitionRegistry: BrowserTabTransitionSurfaceRegistry? = nil,
        transitionRole: BrowserTabTransitionSurfaceRole? = nil,
    ) {
        self.content = content
        self.controller = controller
        self.transitionRegistry = transitionRegistry
        self.transitionRole = transitionRole
    }

    func makeUIViewController(context _: Context) -> BrowserNativePreviewCaptureHostController<Content> {
        BrowserNativePreviewCaptureHostController(
            content: content,
            controller: controller,
            transitionRegistry: transitionRegistry,
            transitionRole: transitionRole,
        )
    }

    func updateUIViewController(
        _ uiViewController: BrowserNativePreviewCaptureHostController<Content>,
        context _: Context,
    ) {
        uiViewController.update(
            content: content,
            transitionRegistry: transitionRegistry,
            transitionRole: transitionRole,
        )
    }

    static func dismantleUIViewController(
        _ uiViewController: BrowserNativePreviewCaptureHostController<Content>,
        coordinator _: (),
    ) {
        uiViewController.detachSurface()
    }
}

/// UIKit host whose root view is the only surface the native preview controller may draw.
@MainActor
final class BrowserNativePreviewCaptureHostController<Content: View>: UIViewController {
    private let controller: BrowserNativePreviewCaptureController
    private var transitionRegistry: BrowserTabTransitionSurfaceRegistry?
    private var transitionRole: BrowserTabTransitionSurfaceRole?
    private var hostingController: UIHostingController<Content>?

    init(
        content: Content,
        controller: BrowserNativePreviewCaptureController,
        transitionRegistry: BrowserTabTransitionSurfaceRegistry?,
        transitionRole: BrowserTabTransitionSurfaceRole?,
    ) {
        self.controller = controller
        self.transitionRegistry = transitionRegistry
        self.transitionRole = transitionRole
        super.init(nibName: nil, bundle: nil)
        hostingController = UIHostingController(rootView: content)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        nil
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        view.isOpaque = false
        controller.attach(surface: view)
        registerTransitionSurface()

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
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        registerTransitionSurface()
        applyInteractiveKeyboardDismissal()
    }

    func update(
        content: Content,
        transitionRegistry: BrowserTabTransitionSurfaceRegistry?,
        transitionRole: BrowserTabTransitionSurfaceRole?,
    ) {
        hostingController?.rootView = content
        updateTransitionRegistration(
            transitionRegistry: transitionRegistry,
            transitionRole: transitionRole,
        )
        controller.attach(surface: view)
        registerTransitionSurface()
        applyInteractiveKeyboardDismissal()
    }

    func detachSurface() {
        controller.detach(surface: view)
        if let transitionRegistry, let transitionRole {
            transitionRegistry.unregister(view, for: transitionRole)
        }
        hostingController?.willMove(toParent: nil)
        hostingController?.view.removeFromSuperview()
        hostingController?.removeFromParent()
        hostingController = nil
    }

    private func registerTransitionSurface() {
        guard let transitionRegistry, let transitionRole else {
            return
        }

        transitionRegistry.register(view, for: transitionRole)
    }

    private func updateTransitionRegistration(
        transitionRegistry: BrowserTabTransitionSurfaceRegistry?,
        transitionRole: BrowserTabTransitionSurfaceRole?,
    ) {
        guard self.transitionRegistry !== transitionRegistry || self.transitionRole != transitionRole else {
            return
        }

        if let oldRegistry = self.transitionRegistry,
           let oldRole = self.transitionRole {
            oldRegistry.unregister(view, for: oldRole)
        }
        self.transitionRegistry = transitionRegistry
        self.transitionRole = transitionRole
    }

    /// Reapplies Browser's interactive scroll policy inside the nested SwiftUI root.
    private func applyInteractiveKeyboardDismissal() {
        guard let hostingView = hostingController?.view else {
            return
        }

        hostingView.layoutIfNeeded()
        for scrollView in descendants(of: hostingView).compactMap({ $0 as? UIScrollView }) {
            KeyboardDismissalSupport.setInteractiveDismissal(true, on: scrollView)
        }
    }

    private func descendants(of view: UIView) -> [UIView] {
        view.subviews + view.subviews.flatMap(descendants)
    }
}
