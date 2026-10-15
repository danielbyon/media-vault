//
//  BrowserDownloadHost.swift
//  MediaVault
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import CoreFoundation
import CoreGraphics
import Foundation
import ObjectiveC
import QuartzCore
import QuickLook
import SwiftUI
import UIKit
import UIUtilities

/// Root-mounted bridge. It remains present when the authenticated shell switches sections or a
/// full-screen native controller detaches its underlying view. Paths never enter reducer state.
@MainActor
public struct BrowserDownloadHost: UIViewControllerRepresentable {
    private var nativeCoordinator = BrowserDownloadNativeCoordinator.shared
    private let renderToken: BrowserDownloadRootRenderToken
    private let currentRenderToken: @MainActor () -> BrowserDownloadRootRenderToken
    private let authenticated: @MainActor () -> Bool
    private let observeAuthentication: @MainActor (@escaping @MainActor () -> Void) -> (@MainActor () -> Void)

    /// The observer must notify synchronously when the live root authentication phase changes and
    /// return a cancellation closure. The predicate is read again at every native admission.
    public init(
        renderToken: BrowserDownloadRootRenderToken,
        currentRenderToken: @escaping @MainActor () -> BrowserDownloadRootRenderToken,
        authenticated: @escaping @MainActor () -> Bool,
        observeAuthentication: @escaping @MainActor (@escaping @MainActor () -> Void) -> (@MainActor () -> Void),
    ) {
        self.renderToken = renderToken
        self.currentRenderToken = currentRenderToken
        self.authenticated = authenticated
        self.observeAuthentication = observeAuthentication
    }

    /// Internal composition seam for window-hosted tests with independently owned scratch files.
    /// Authentication, scene admission, and native dismissal still use the same implementation.
    func using(coordinator: BrowserDownloadNativeCoordinator) -> Self {
        var host = self
        host.nativeCoordinator = coordinator
        return host
    }

    /// Creates the root-mounted presenter and its synchronous authentication observation.
    public func makeUIViewController(context _: Context) -> BrowserDownloadHostController {
        let controller = BrowserDownloadHostController()
        controller.nativeCoordinator = nativeCoordinator
        controller.authentication = authenticated
        controller.currentRenderToken = currentRenderToken
        controller.rootUpdated(renderToken)
        controller.cancelAuthenticationObservation = observeAuthentication {
            nativeCoordinator.authenticationChanged()
        }
        return controller
    }

    /// Records reconciliation, then requests actual root layout evidence before uncovering.
    public func updateUIViewController(_ controller: BrowserDownloadHostController, context _: Context) {
        controller.rootUpdated(renderToken)
    }

    /// Cancels root observation while retaining any unresolved native presentation registration.
    public static func dismantleUIViewController(_ controller: BrowserDownloadHostController, coordinator _: ()) {
        controller.cancelAuthenticationObservation?()
        controller.cancelAuthenticationObservation = nil
        controller.cancelRenderVerification()
        controller.nativeCoordinator.unregister(controller)
    }
}

/// Lightweight root presenter; its registration is independent of temporary view attachment.
@MainActor
public final class BrowserDownloadHostController: UIViewController {
    var nativeCoordinator = BrowserDownloadNativeCoordinator.shared
    let registrationID = UUID()
    var authentication: @MainActor () -> Bool = { false }
    var currentRenderToken: @MainActor () -> BrowserDownloadRootRenderToken = {
        .init(surfaceID: "unmounted", authenticated: false, privacyGeneration: 0)
    }

    var cancelAuthenticationObservation: (@MainActor () -> Void)?
    private(set) var hostingScene: UIWindowScene?
    private(set) var rootRender = BrowserDownloadRootRenderState()
    private var renderVerification: Task<Void, Never>?
    private var renderVerificationID = UUID()

    func rootUpdated(_ token: BrowserDownloadRootRenderToken) {
        cancelRenderVerification()
        guard rootRender.update(token: token, liveToken: currentRenderToken()) else {
            return
        }

        requestRenderVerification()
    }

    func invalidateRootRender() {
        rootRender.invalidate()
        requestRenderVerification()
    }

    func cancelRenderVerification() {
        renderVerification?.cancel()
        renderVerification = nil
    }

    /// Deferred followups verify uncovering only. Native privacy revocation remains synchronous.
    func requestRenderVerification() {
        cancelRenderVerification()
        let verificationID = UUID()
        renderVerificationID = verificationID
        renderVerification = Task { [weak self] in
            for _ in 0 ..< 100 {
                guard let self, !Task.isCancelled else {
                    return
                }

                commitRootLayoutIfAttached()
                if rootRender.confirmed {
                    break
                }
                do { try await Task.sleep(for: .milliseconds(20)) } catch { break }
            }
            if self?.renderVerificationID == verificationID {
                self?.renderVerification = nil
            }
        }
    }

    private func commitRootLayoutIfAttached() {
        guard let scene = hostingScene, scene.activationState == .foregroundActive,
              let window = viewIfLoaded?.window, let root = window.rootViewController,
              root.viewIfLoaded?.window === window, root.presentedViewController == nil,
              !root.isBeingDismissed, let token = rootRender.token, token == currentRenderToken() else {
            return
        }

        let revision = rootRender.revision
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self, weak root, weak window] in
            MainActor.assumeIsolated {
                guard let self, let root, let window else {
                    return
                }

                self.rootRender.confirm(
                    revision: revision,
                    token: token,
                    liveToken: self.currentRenderToken(),
                    rootAttached: root.viewIfLoaded?.window === window && self.viewIfLoaded?.window === window,
                    modalsAbsent: root.presentedViewController == nil && !root.isBeingDismissed,
                    layoutCommitted: true,
                )
                self.nativeCoordinator.rootRenderConfirmed()
            }
        }
        root.view.setNeedsLayout()
        root.view.layoutIfNeeded()
        CATransaction.commit()
    }

    override public func loadView() {
        view = UIView()
        view.isUserInteractionEnabled = false
    }

    /// Geometry changes update concealment independently of root render-token confirmation.
    override public func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        if let hostingScene {
            nativeCoordinator.refreshCoverGeometry(in: hostingScene)
        }
    }

    override public func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if hostingScene == nil, let scene = view.window?.windowScene {
            hostingScene = scene
            nativeCoordinator.register(self)
        }
        nativeCoordinator.confirmAbsence()
        requestRenderVerification()
    }
}

/// Owns native controllers and scene covers, separately from download bytes. UIKit presentation
/// can complete after privacy revocation; unresolved presentations keep their cover and admission
/// until actual absence is proven. No handoff exception delays scratch revocation.
@MainActor
final class BrowserDownloadNativeCoordinator: NSObject, QLPreviewControllerDataSource,
    QLPreviewControllerDelegate, UIAdaptivePresentationControllerDelegate {
    static let shared = BrowserDownloadNativeCoordinator(owner: .shared)

    @MainActor
    private final class Registration {
        weak var controller: BrowserDownloadHostController?
        let scene: UIWindowScene
        var active: Bool
        var mounted = true

        init(controller: BrowserDownloadHostController, scene: UIWindowScene) {
            self.controller = controller
            self.scene = scene
            active = scene.activationState == .foregroundActive
        }
    }

    private let owner: BrowserDownloadOwner
    private var registrations: [UUID: Registration] = [:]
    private var covers: [ObjectIdentifier: UIWindow] = [:]
    private var coverGeometryDisplayLink: CADisplayLink?
    private var observers: [NSObjectProtocol] = []
    private var subscription: Task<Void, Never>?
    private var followup: Task<Void, Never>?
    private(set) var nativeController: UIViewController?
    private weak var presenter: UIViewController?
    private var presentationHost: BrowserDownloadHostController?
    private var request: BrowserDownloadPresentation?
    private var lifetime = BrowserDownloadPresentationLifetime()

    /// UIKit attachment can precede its presentation completion callback. Hosted fixtures observe
    /// this milestone without changing admission or the unresolved-presentation privacy barrier.
    var nativePresentationCompleted: Bool {
        lifetime.completed
    }

    /// Redacted lifecycle evidence for bounded hosted-test failures; no source paths or content.
    var presentationDiagnostics: String {
        "admitted=\(lifetime.admitted) completed=\(lifetime.completed) revoked=\(lifetime.revoked) "
            + "pending=\(lifetime.dismissalPending) requested=\(lifetime.dismissalRequested) "
            + "native=\(nativeController != nil) presenting=\(nativeController?.presentingViewController != nil) "
            + "attached=\(nativeController?.viewIfLoaded?.window != nil) "
            + "beingPresented=\(nativeController?.isBeingPresented == true) "
            + "beingDismissed=\(nativeController?.isBeingDismissed == true) "
            + "presenterMatches=\(presenter?.presentedViewController === nativeController && nativeController != nil)"
    }

    #if DEBUG
    /// Optional, synchronous qualification evidence. Normal application composition leaves this nil.
    /// Values describe actual registered scenes, cover windows and the existing native/root barriers;
    /// observations neither authorize work nor alter controller, source or registration lifetimes.
    var qualificationObservation: (@MainActor (String, [String: String]) -> Void)?
    #endif

    private func recordQualification(_ event: String) {
        #if DEBUG
        guard let qualificationObservation else {
            return
        }

        for (id, registration) in registrations {
            let scene = registration.scene
            let active = registration.active && scene.activationState == .foregroundActive
            let nativeBarrier = lifetime.admitted && presentationHost?.hostingScene === scene
            let cover = covers[ObjectIdentifier(scene)]
            qualificationObservation(event, [
                "registration": id.uuidString,
                "sceneSession": scene.session.persistentIdentifier,
                "activation": String(scene.activationState.rawValue),
                "mounted": String(registration.mounted),
                "generation": String(owner.snapshot.generation),
                "operation": request?.downloadID.rawValue.uuidString ?? "none",
                "request": request?.requestID.uuidString ?? "none",
                "coverVisible": String(cover?.isHidden == false && cover?.windowScene === scene),
                "coverFrame": String(describing: cover?.frame),
                "sceneBounds": String(describing: scene.effectiveGeometry.coordinateSpace.bounds),
                "nativeBarrier": String(nativeBarrier),
                "nativeLifecycle": presentationDiagnostics,
                "rootProof": String(registration.mounted && registration.controller?.rootRender.canReleaseCover(
                    sceneActive: active,
                    nativeAdmissionHeld: nativeBarrier,
                ) == true),
            ])
        }
        #endif
    }

    private var previewURL: URL?
    private lazy var sceneAuthorization = BrowserDownloadSceneRegistry(authenticated: { [weak self] in
        guard let self else {
            return false
        }

        return registrations.values.allSatisfy { $0.controller?.authentication() == true }
    })

    init(owner: BrowserDownloadOwner) {
        self.owner = owner
        super.init()
    }

    isolated deinit {
        coverGeometryDisplayLink?.invalidate()
    }

    private var authorized: Bool {
        sceneAuthorization.isAuthorized && registrations.values.allSatisfy {
            $0.mounted && $0.active && $0.scene.activationState == .foregroundActive
                && $0.controller?.authentication() == true
        }
    }

    func register(_ controller: BrowserDownloadHostController) {
        defer { recordQualification("rootRegistered") }
        guard let scene = controller.hostingScene else {
            return
        }

        registrations[controller.registrationID] = Registration(controller: controller, scene: scene)
        sceneAuthorization.register(controller.registrationID, active: scene.activationState == .foregroundActive)
        owner.presentationWillRevoke = { [weak self] in self?.concealNativePresentation() }
        owner.installAuthorization { [weak self] in self?.authorized == true }
        installObservers()
        if subscription == nil {
            subscription = Task { [weak self, owner] in
                for await snapshot in owner.subscribe() {
                    guard let self else {
                        return
                    }

                    reconcile(snapshot)
                }
            }
        }
        if !authorized {
            revoke()
        }
    }

    func unregister(_ controller: BrowserDownloadHostController) {
        defer { recordQualification("rootUnregistered") }
        guard let registration = registrations[controller.registrationID] else {
            return
        }

        registration.mounted = false
        registration.active = false
        sceneAuthorization.setActive(false, for: controller.registrationID)
        // A detached unresolved presenter must keep its scene cover and lifetime registration.
        revoke()
        if presentationHost !== controller {
            registrations.removeValue(forKey: controller.registrationID)
            sceneAuthorization.unregister(controller.registrationID)
        }
        reevaluate()
    }

    func rootRenderConfirmed() {
        defer { recordQualification("rootLayoutConfirmed") }
        reevaluate()
    }

    func authenticationChanged() {
        defer { recordQualification("authenticationChanged") }
        for registration in registrations.values {
            registration.controller?.invalidateRootRender()
        }
        if authorized {
            owner.recheckAuthorization()
            reevaluate()
        } else {
            revoke()
        }
    }

    private func installObservers() {
        guard observers.isEmpty else {
            return
        }

        for name in [
            UIScene.willDeactivateNotification,
            UIScene.didEnterBackgroundNotification,
            UIScene.didActivateNotification,
            UIScene.didDisconnectNotification,
        ] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) {
                [weak self] notification in
                // OperationQueue.main delivers this UIKit lifecycle observer synchronously on
                // the main queue. Only Sendable scene identity enters MainActor, never Notification.
                precondition(Thread.isMainThread)
                guard let scene = notification.object as? UIWindowScene else {
                    return
                }

                let sceneID = ObjectIdentifier(scene)
                MainActor.assumeIsolated { self?.transition(sceneID: sceneID, name: name) }
            })
        }
    }

    private func transition(sceneID: ObjectIdentifier, name: Notification.Name) {
        defer { recordQualification(name.rawValue) }
        guard let scene = registrations.values.first(where: { ObjectIdentifier($0.scene) == sceneID })?.scene
        else {
            return
        }

        let affected = registrations.values.filter { $0.scene === scene }
        guard !affected.isEmpty else {
            return
        }

        if name == UIScene.didActivateNotification {
            for (id, registration) in registrations where registration.scene === scene {
                registration.active = true
                sceneAuthorization.setActive(true, for: id)
                registration.controller?.requestRenderVerification()
            }
            if authorized {
                owner.recheckAuthorization()
            }
            reevaluate()
            return
        }
        let changed = affected.contains { $0.active }
        for (id, registration) in registrations where registration.scene === scene {
            registration.active = false
            sceneAuthorization.setActive(false, for: id)
        }
        if changed || name == UIScene.didDisconnectNotification {
            revoke()
        }
        if name == UIScene.didDisconnectNotification {
            for (id, registration) in registrations where registration.scene === scene {
                registration.mounted = false
                if presentationHost?.registrationID != id {
                    registrations.removeValue(forKey: id)
                    sceneAuthorization.unregister(id)
                }
            }
            reevaluate()
        }
    }

    private func concealNativePresentation() {
        defer { recordQualification("nativeConcealment") }
        for registration in registrations.values {
            registration.controller?.invalidateRootRender()
        }
        lifetime.revoke()
        for registration in registrations.values {
            showCover(in: registration.scene)
        }
        requestDismissal()
    }

    private func revoke() {
        defer { recordQualification("privacyRevoked") }
        for registration in registrations.values {
            registration.controller?.invalidateRootRender()
        }
        lifetime.revoke()
        // Conceal above all registered application windows before revoking bytes or dismissing UIKit.
        if request != nil || !owner.snapshot.records.isEmpty || owner.privacyCleanupPending || !covers.isEmpty {
            for registration in registrations.values {
                showCover(in: registration.scene)
            }
        }
        owner.invalidateAuthorization()
        requestDismissal()
        reevaluate()
    }

    private func reconcile(_: BrowserDownloadSnapshot) {
        // Buffered deliveries can be obsolete after synchronous revocation or native dismissal.
        let snapshot = owner.snapshot
        if let request, snapshot.presentation != request {
            lifetime.revoke()
            for registration in registrations.values {
                showCover(in: registration.scene)
            }
            requestDismissal()
        }
        if nativeController == nil, let newRequest = snapshot.presentation, authorized {
            present(newRequest)
        }
        reevaluate()
    }

    private func present(_ newRequest: BrowserDownloadPresentation) {
        // An unresolved controller is a barrier, not an unavailable-presenter rejection.
        guard lifetime.admissionDecision(presenterAvailable: true) != .waitForAbsence else {
            return
        }
        guard authorized, let host = registrations.values.compactMap(\.controller).first else {
            rejectPresentation(newRequest)
            return
        }

        var anchor: UIViewController = host.view.window?.rootViewController ?? host
        while let presented = anchor.presentedViewController {
            anchor = presented
        }
        let presenterAvailable = anchor.viewIfLoaded?.window != nil && !anchor.isBeingDismissed && !anchor
            .isBeingPresented
        guard lifetime.admissionDecision(presenterAvailable: presenterAvailable) == .present,
              let url = owner.presentationURL(for: newRequest) else {
            rejectPresentation(newRequest)
            return
        }
        guard let controller = makeNativeController(for: newRequest, url: url) else {
            return
        }

        request = newRequest
        nativeController = controller
        presentationHost = host
        presenter = anchor
        _ = lifetime.begin()
        if let popover = controller.popoverPresentationController {
            popover.sourceView = anchor.view
            popover.sourceRect = CGRect(x: anchor.view.bounds.midX, y: anchor.view.bounds.midY, width: 1, height: 1)
            popover.permittedArrowDirections = []
        }
        // Mark unresolved before UIKit is called; inactivity during this await revokes this identity.
        anchor.present(controller, animated: false) { [weak self, weak controller] in
            MainActor.assumeIsolated {
                guard let self, let controller, self.nativeController === controller else {
                    return
                }

                self.lifetime.complete()
                self.recordQualification("nativePresentationCompleted")
                controller.presentationController?.delegate = self
                if self.lifetime.revoked || !self.authorized || self.owner.snapshot.presentation != newRequest {
                    self.lifetime.revoke()
                    for registration in self.registrations.values {
                        self.showCover(in: registration.scene)
                    }
                    self.requestDismissal()
                }
                self.confirmAbsence()
            }
        }
    }

    private func rejectPresentation(_ rejected: BrowserDownloadPresentation) {
        owner.execute(.init(snapshot: owner.snapshot, action: .dismissPresentation(rejected.requestID)))
    }

    private func makeNativeController(for newRequest: BrowserDownloadPresentation, url: URL) -> UIViewController? {
        switch newRequest.kind {
        case .preview:
            // The SDK's Quick Look item protocol is supplied by the NSURL category, not Swift URL.
            // swiftlint:disable:next legacy_objc_type
            guard QLPreviewController.canPreview(url as NSURL) else {
                owner.presentationUnavailable(newRequest, discard: false)
                return nil
            }

            previewURL = url
            let preview = QLPreviewController()
            preview.dataSource = self
            preview.delegate = self
            return preview
        case .share:
            guard let provider = NSItemProvider(contentsOf: url) else {
                owner.presentationUnavailable(newRequest, discard: true)
                if owner.snapshot.cleanupNeedsRetry {
                    for registration in registrations.values {
                        showCover(in: registration.scene)
                    }
                }
                return nil
            }

            let activity = UIActivityViewController(
                activityItemsConfiguration: UIActivityItemsConfiguration(itemProviders: [provider]),
            )
            activity.completionWithItemsHandler = { [weak self, weak activity] _, _, _, _ in
                Task { @MainActor in
                    guard let self, let activity, self.nativeController === activity else {
                        return
                    }

                    self.lifetime.activityEnded()
                    self.scheduleAbsenceChecks()
                }
            }
            return activity
        }
    }

    private func requestDismissal() {
        defer { recordQualification("nativeDismissalRechecked") }
        guard let nativeController else {
            return
        }

        lifetime.activityEnded()
        // Completion may mark absence pending before UIKit has actually removed the controller.
        // That flag must not suppress an inactivity-triggered dismissal request.
        if lifetime.requestDismissal(isPresented: nativeController.presentingViewController != nil) {
            nativeController.dismiss(animated: false) { [weak self] in
                MainActor.assumeIsolated { self?.confirmAbsence() }
            }
        }
        scheduleAbsenceChecks()
    }

    private func scheduleAbsenceChecks() {
        guard followup == nil else {
            return
        }

        followup = Task { [weak self] in
            for _ in 0 ..< 100 {
                do { try await Task.sleep(for: .milliseconds(20)) } catch { break }
                guard let self else {
                    return
                }

                confirmAbsence()
                if nativeController == nil {
                    break
                }
                if lifetime.revoked {
                    requestDismissal()
                }
            }
            self?.followup = nil
        }
    }

    func confirmAbsence() {
        defer { recordQualification("nativeAbsenceRechecked") }
        guard let controller = nativeController, lifetime.completed,
              controller.presentingViewController == nil,
              presenter?.presentedViewController !== controller,
              controller.viewIfLoaded?.window == nil,
              !controller.isBeingPresented, !controller.isBeingDismissed else {
            return
        }
        guard lifetime.confirmAbsence(isAbsent: true) else {
            return
        }

        recordQualification("nativeAbsenceConfirmed")
        let completedRequest = request
        let hostID = presentationHost?.registrationID
        nativeController = nil
        presenter = nil
        presentationHost = nil
        request = nil
        previewURL = nil
        if let completedRequest {
            owner.execute(.init(snapshot: owner.snapshot, action: .dismissPresentation(completedRequest.requestID)))
        }
        if let hostID, registrations[hostID]?.mounted == false {
            registrations.removeValue(forKey: hostID)
            sceneAuthorization.unregister(hostID)
        }
        for registration in registrations.values {
            registration.controller?.requestRenderVerification()
        }
        reconcile(owner.snapshot)
    }

    /// Read-only observation of actual scene cover windows for hosted UIKit qualification.
    func coverWindow(in scene: UIWindowScene) -> UIWindow? {
        covers[ObjectIdentifier(scene)]
    }

    /// Refreshes an existing cover after registered-root or cover-window layout. This does not
    /// confirm safe root rendering or release admission; those require their own immutable token.
    func refreshCoverGeometry(in scene: UIWindowScene) {
        guard let window = covers[ObjectIdentifier(scene)] else {
            return
        }

        let bounds = scene.effectiveGeometry.coordinateSpace.bounds
        if window.frame != bounds {
            window.frame = bounds
        }
    }

    /// UIKit can resize a scene without laying out either registered controller. While covers
    /// exist, refresh their scene-coordinate frames before each display update independently of
    /// those layout callbacks. Geometry updates never confirm a root token or release admission.
    private func startCoverGeometryUpdatesIfNeeded() {
        guard coverGeometryDisplayLink == nil else {
            return
        }

        // The display link retains its target. Keep the coordinator weak in the target's closure
        // so a discarded fixture/owner cannot be retained by the main run loop.
        let target = BrowserDownloadCoverGeometryTarget { [weak self] in
            guard let self else {
                return
            }

            for window in covers.values {
                if let scene = window.windowScene {
                    refreshCoverGeometry(in: scene)
                }
            }
        }
        let link = CADisplayLink(target: target, selector: #selector(BrowserDownloadCoverGeometryTarget.update))
        coverGeometryDisplayLink = link
        link.add(to: .main, forMode: .common)
    }

    private func showCover(in scene: UIWindowScene) {
        let key = ObjectIdentifier(scene)
        let window = covers[key] ?? UIWindow(windowScene: scene)
        let controller = BrowserDownloadCoverController()
        controller.geometryChanged = { [weak self, weak scene] in
            guard let scene else {
                return
            }

            self?.refreshCoverGeometry(in: scene)
        }
        controller.view.backgroundColor = .systemBackground
        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = 20
        stack.alignment = .center
        let label = UILabel()
        label.text = "Private content hidden"
        label.font = .preferredFont(forTextStyle: .title2)
        label.adjustsFontForContentSizeCategory = true
        label.numberOfLines = 0
        label.textAlignment = .center
        let retry = UIButton(type: .system)
        retry.setTitle("Retry Download Cleanup", for: .normal)
        retry.titleLabel?.font = .preferredFont(forTextStyle: .body)
        retry.titleLabel?.adjustsFontForContentSizeCategory = true
        retry.titleLabel?.numberOfLines = 0
        retry.titleLabel?.textAlignment = .center
        retry.addAction(UIAction { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else {
                    return
                }

                self.owner.execute(.init(snapshot: self.owner.snapshot, action: .retryCleanup))
                self.reevaluate()
            }
        }, for: .touchUpInside)
        retry.isHidden = !owner.snapshot.cleanupNeedsRetry
        stack.addArrangedSubview(label)
        stack.addArrangedSubview(retry)
        stack.translatesAutoresizingMaskIntoConstraints = false
        controller.view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: controller.view.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: controller.view.centerYAnchor),
            stack.leadingAnchor.constraint(
                greaterThanOrEqualTo: controller.view.safeAreaLayoutGuide.leadingAnchor,
                constant: 20,
            ),
            stack.trailingAnchor.constraint(
                lessThanOrEqualTo: controller.view.safeAreaLayoutGuide.trailingAnchor,
                constant: -20,
            ),
        ])
        window.rootViewController = controller
        let highest = scene.windows.filter { $0 !== window }.map(\.windowLevel.rawValue).max() ?? 0
        window.windowLevel = UIWindow.Level(rawValue: max(UIWindow.Level.alert.rawValue + 1, highest + 1))
        window.frame = scene.effectiveGeometry.coordinateSpace.bounds
        window.isHidden = false
        covers[key] = window
        startCoverGeometryUpdatesIfNeeded()
    }

    private func reevaluate() {
        defer { recordQualification("coverReevaluated") }
        // Download admission remains global, but concealment belongs to each scene. An inactive
        // scene cannot keep another scene's verified safe root covered after its own native barrier
        // resolves. Unresolved presentation ownership still protects its actual hosting scene.
        for (sceneID, window) in Array(covers) {
            let scoped = registrations.values.filter { ObjectIdentifier($0.scene) == sceneID }
            let nativeBarrier = lifetime.admitted && presentationHost?.hostingScene === window.windowScene
            let rootSafe = !scoped.isEmpty && scoped.allSatisfy {
                $0.mounted && $0.controller?.rootRender.canReleaseCover(
                    sceneActive: $0.active && $0.scene.activationState == .foregroundActive,
                    nativeAdmissionHeld: nativeBarrier,
                ) == true
            }
            if rootSafe {
                window.isHidden = true
                window.rootViewController = nil
                covers.removeValue(forKey: sceneID)
            } else if owner.snapshot.cleanupNeedsRetry, let scene = window.windowScene {
                // Cleanup denies downloads, not the application. Keep recovery on covers still
                // awaiting their own scene/root proof, without covering a safe neighboring scene.
                showCover(in: scene)
            }
        }
        if registrations.isEmpty, nativeController == nil {
            owner.presentationWillRevoke = nil
            subscription?.cancel()
            subscription = nil
            for observer in observers {
                NotificationCenter.default.removeObserver(observer)
            }
            observers.removeAll()
            for window in covers.values {
                window.isHidden = true
                window.rootViewController = nil
            }
            covers.removeAll()
        }
        if covers.isEmpty {
            coverGeometryDisplayLink?.invalidate()
            coverGeometryDisplayLink = nil
        }
    }

    func numberOfPreviewItems(in _: QLPreviewController) -> Int {
        previewURL == nil ? 0 : 1
    }

    func previewController(_: QLPreviewController, previewItemAt _: Int) -> any QLPreviewItem {
        // Quick Look's SDK declares NSURL category conformance to its NSObject-based item protocol.
        // swiftlint:disable:next legacy_objc_type
        previewURL.map { $0 as NSURL } ?? NSURL()
    }

    /// Unlike its data source, the installed SDK does not actor-annotate the Quick Look delegate.
    /// Transport only reference identity across this boundary; all UIKit reads and lifetime changes
    /// execute on MainActor and reject a delayed callback from a previously dismissed controller.
    nonisolated func previewControllerDidDismiss(_ controller: QLPreviewController) {
        let identity = ObjectIdentifier(controller)
        Task { @MainActor [weak self] in
            guard let self, let current = nativeController,
                  ObjectIdentifier(current) == identity else {
                return
            }

            lifetime.activityEnded()
            scheduleAbsenceChecks()
        }
    }

    func presentationControllerDidDismiss(_: UIPresentationController) {
        lifetime.activityEnded()
        scheduleAbsenceChecks()
    }
}

/// A scene cover follows UIKit layout while never treating layout as authentication evidence.
@MainActor
final class BrowserDownloadCoverController: UIViewController {
    var geometryChanged: (@MainActor () -> Void)?

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        geometryChanged?()
    }
}

/// A weakly captured geometry callback separates display-link ownership from download ownership.
@MainActor
private final class BrowserDownloadCoverGeometryTarget: NSObject {
    private let refresh: @MainActor () -> Void

    init(refresh: @escaping @MainActor () -> Void) {
        self.refresh = refresh
        super.init()
    }

    @objc
    func update() {
        refresh()
    }
}
