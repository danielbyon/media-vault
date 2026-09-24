//
//  BrowserRefreshGestureArbitration.swift
//  MediaVault
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import SwiftUI
import UIKit

/// Identifies one mounted Browser refresh surface independently of its logical tab.
struct BrowserRefreshSurfaceID: Hashable {
    let rawValue: UUID

    init(_ rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}

/// Input sampled once when a physical gesture begins.
struct BrowserRefreshGestureInput: Equatable {
    let isInteractiveDismissalEnabled: Bool
    let isSoftwareKeyboardPresent: Bool

    var suppressesRefresh: Bool {
        isInteractiveDismissalEnabled && isSoftwareKeyboardPresent
    }
}

/// UIKit pan-recognizer states used by the WebKit adapter.
enum BrowserRefreshWebKitPanState: Equatable {
    case possible
    case began
    case changed
    case ended
    case cancelled
    case failed

    /// Translates the public UIKit recognizer lifecycle into Browser's explicit event vocabulary.
    init(gestureRecognizerState: UIGestureRecognizer.State) {
        switch gestureRecognizerState {
        case .possible:
            self = .possible
        case .began:
            self = .began
        case .changed:
            self = .changed
        case .ended:
            self = .ended
        case .cancelled:
            self = .cancelled
        case .failed:
            self = .failed
        @unknown default:
            self = .possible
        }
    }
}

/// Scroll phases used by the native error-surface adapter.
enum BrowserRefreshNativeScrollPhase: Equatable {
    case tracking
    case interacting
    case decelerating
    case idle
    case animating

    /// Translates SwiftUI's native scroll lifecycle without creating gesture semantics of its own.
    init(scrollPhase: ScrollPhase) {
        switch scrollPhase {
        case .tracking:
            self = .tracking
        case .interacting:
            self = .interacting
        case .decelerating:
            self = .decelerating
        case .idle:
            self = .idle
        case .animating:
            self = .animating
        @unknown default:
            self = .animating
        }
    }
}

/// Keyboard-presence events reduced without UIKit or NotificationCenter dependencies.
enum BrowserSoftwareKeyboardPresenceEvent: Equatable {
    case willShow
    case didShow
    case willChangeFrame(intersectsBrowserWindow: Bool)
    case didChangeFrame(intersectsBrowserWindow: Bool)
    case willHide
    case didHide
}

/// Tracks the local software keyboard through its full show and interactive-hide lifecycle.
struct BrowserSoftwareKeyboardPresenceState: Equatable {
    private(set) var isPresent = false

    /// Updates presence without treating focus alone or a transient frame as keyboard dismissal.
    mutating func receive(_ event: BrowserSoftwareKeyboardPresenceEvent) {
        switch event {
        case .willShow:
            isPresent = true
        case .didShow,
             .willHide:
            break
        case let .willChangeFrame(intersectsBrowserWindow):
            if intersectsBrowserWindow {
                isPresent = true
            }
        case let .didChangeFrame(intersectsBrowserWindow):
            isPresent = intersectsBrowserWindow
        case .didHide:
            isPresent = false
        }
    }
}

/// Deterministic Browser-local gesture state shared by WebKit and native refresh surfaces.
struct BrowserRefreshGestureArbitration {
    private enum GestureSource: Equatable {
        case webKit
        case native
    }

    private struct ActiveGesture {
        let id: UInt64
        let surfaceID: BrowserRefreshSurfaceID
        let source: GestureSource
        let suppressesRefresh: Bool
        var nativeInteractionStarted: Bool
    }

    private struct CompletedGesture {
        let id: UInt64
        let surfaceID: BrowserRefreshSurfaceID
        let suppressesRefresh: Bool
    }

    private(set) var activeSurfaceID: BrowserRefreshSurfaceID?
    private(set) var activeGestureID: UInt64?
    private(set) var completedGestureID: UInt64?
    private var activeGesture: ActiveGesture?
    private var completedGesture: CompletedGesture?
    private var nextGestureID: UInt64 = 0

    /// Makes one surface authoritative and discards any decision owned by its predecessor.
    mutating func mount(_ surfaceID: BrowserRefreshSurfaceID) {
        guard activeSurfaceID != surfaceID else {
            return
        }

        activeSurfaceID = surfaceID
        resetGestureState()
    }

    /// Releases a surface only if it still owns the shared Browser arbitration state.
    mutating func unmount(_ surfaceID: BrowserRefreshSurfaceID) {
        guard activeSurfaceID == surfaceID else {
            return
        }

        activeSurfaceID = nil
        resetGestureState()
    }

    /// Maps the WebKit pan lifecycle while sampling suppression only at `.began`.
    mutating func receiveWebKitPanState(
        _ panState: BrowserRefreshWebKitPanState,
        on surfaceID: BrowserRefreshSurfaceID,
        input: BrowserRefreshGestureInput,
    ) {
        guard activeSurfaceID == surfaceID else {
            return
        }

        switch panState {
        case .possible,
             .changed:
            break
        case .began:
            beginGesture(on: surfaceID, source: .webKit, input: input, nativeInteractionStarted: false)
        case .ended:
            completeGesture(on: surfaceID, source: .webKit)
        case .cancelled,
             .failed:
            cancelGesture(on: surfaceID, source: .webKit)
        }
    }

    /// Adapts SwiftUI scroll phases onto the same gesture latch used for WebKit pans.
    mutating func receiveNativeScrollPhase(
        _ phase: BrowserRefreshNativeScrollPhase,
        on surfaceID: BrowserRefreshSurfaceID,
        input: BrowserRefreshGestureInput,
    ) {
        guard activeSurfaceID == surfaceID else {
            return
        }

        switch phase {
        case .tracking:
            guard activeGesture?.surfaceID != surfaceID || activeGesture?.source != .native else {
                return
            }

            beginGesture(on: surfaceID, source: .native, input: input, nativeInteractionStarted: false)
        case .interacting:
            if var activeGesture,
               activeGesture.surfaceID == surfaceID,
               activeGesture.source == .native {
                activeGesture.nativeInteractionStarted = true
                self.activeGesture = activeGesture
            } else {
                beginGesture(on: surfaceID, source: .native, input: input, nativeInteractionStarted: true)
            }
        case .decelerating:
            completeGesture(on: surfaceID, source: .native)
        case .idle:
            guard let activeGesture,
                  activeGesture.surfaceID == surfaceID,
                  activeGesture.source == .native
            else {
                return
            }

            if activeGesture.nativeInteractionStarted {
                completeGesture(on: surfaceID, source: .native)
            } else {
                cancelGesture(on: surfaceID, source: .native)
            }
        case .animating:
            // Programmatic scrolling cannot create a refresh decision. If it interrupts an active
            // touch gesture, treat that gesture as cancelled; a completed result remains consumable.
            cancelGesture(on: surfaceID, source: .native)
        }
    }

    /// Consumes one pull decision after gesture completion or refresh acceptance.
    mutating func consumeRefresh(on surfaceID: BrowserRefreshSurfaceID) -> Bool {
        guard activeSurfaceID == surfaceID else {
            return false
        }

        let suppressesRefresh: Bool
        if let completedGesture, completedGesture.surfaceID == surfaceID {
            suppressesRefresh = completedGesture.suppressesRefresh
            self.completedGesture = nil
            completedGestureID = nil
        } else if let activeGesture, activeGesture.surfaceID == surfaceID {
            guard activeGesture.source == .webKit || activeGesture.nativeInteractionStarted else {
                return false
            }

            suppressesRefresh = activeGesture.suppressesRefresh
            self.activeGesture = nil
            activeGestureID = nil
        } else {
            return false
        }

        return !suppressesRefresh
    }

    private mutating func beginGesture(
        on surfaceID: BrowserRefreshSurfaceID,
        source: GestureSource,
        input: BrowserRefreshGestureInput,
        nativeInteractionStarted: Bool,
    ) {
        nextGestureID &+= 1
        activeGesture = ActiveGesture(
            id: nextGestureID,
            surfaceID: surfaceID,
            source: source,
            suppressesRefresh: input.suppressesRefresh,
            nativeInteractionStarted: nativeInteractionStarted,
        )
        activeGestureID = nextGestureID
        completedGesture = nil
        completedGestureID = nil
    }

    private mutating func completeGesture(on surfaceID: BrowserRefreshSurfaceID, source: GestureSource) {
        guard let activeGesture,
              activeGesture.surfaceID == surfaceID,
              activeGesture.source == source
        else {
            return
        }

        completedGesture = CompletedGesture(
            id: activeGesture.id,
            surfaceID: surfaceID,
            suppressesRefresh: activeGesture.suppressesRefresh,
        )
        completedGestureID = activeGesture.id
        self.activeGesture = nil
        activeGestureID = nil
    }

    private mutating func cancelGesture(on surfaceID: BrowserRefreshSurfaceID, source: GestureSource) {
        guard activeGesture?.surfaceID == surfaceID,
              activeGesture?.source == source
        else {
            return
        }

        activeGesture = nil
        activeGestureID = nil
        completedGesture = nil
        completedGestureID = nil
    }

    private mutating func resetGestureState() {
        activeGesture = nil
        activeGestureID = nil
        completedGesture = nil
        completedGestureID = nil
    }
}

/// Shared reference used by Browser-owned UIKit and SwiftUI surface adapters.
@MainActor
final class BrowserRefreshGestureArbitrator {
    private var state = BrowserRefreshGestureArbitration()

    var mountedSurfaceID: BrowserRefreshSurfaceID? {
        state.activeSurfaceID
    }

    func mount(_ surfaceID: BrowserRefreshSurfaceID) {
        state.mount(surfaceID)
    }

    func unmount(_ surfaceID: BrowserRefreshSurfaceID) {
        state.unmount(surfaceID)
    }

    func receiveWebKitPanState(
        _ panState: BrowserRefreshWebKitPanState,
        on surfaceID: BrowserRefreshSurfaceID,
        input: BrowserRefreshGestureInput,
    ) {
        state.receiveWebKitPanState(panState, on: surfaceID, input: input)
    }

    func receiveNativeScrollPhase(
        _ phase: BrowserRefreshNativeScrollPhase,
        on surfaceID: BrowserRefreshSurfaceID,
        input: BrowserRefreshGestureInput,
    ) {
        state.receiveNativeScrollPhase(phase, on: surfaceID, input: input)
    }

    func consumeRefresh(on surfaceID: BrowserRefreshSurfaceID) -> Bool {
        state.consumeRefresh(on: surfaceID)
    }
}

/// Browser-owned keyboard visibility input populated by the UIKit notification adapter.
@MainActor
final class BrowserSoftwareKeyboardPresence {
    private var state = BrowserSoftwareKeyboardPresenceState()

    var isPresent: Bool {
        state.isPresent
    }

    func receive(_ event: BrowserSoftwareKeyboardPresenceEvent) {
        state.receive(event)
    }
}

/// Observes only keyboard notifications whose local frame belongs to the Browser's current window.
@MainActor
@preconcurrency
struct BrowserSoftwareKeyboardPresenceObserver: UIViewRepresentable {
    private let presence: BrowserSoftwareKeyboardPresence
    private let notificationCenter: NotificationCenter

    init(
        presence: BrowserSoftwareKeyboardPresence,
        notificationCenter: NotificationCenter = .default,
    ) {
        self.presence = presence
        self.notificationCenter = notificationCenter
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(presence: presence, notificationCenter: notificationCenter)
    }

    func makeUIView(context: Context) -> AnchorView {
        let view = AnchorView()
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = false
        context.coordinator.attach(view)
        return view
    }

    func updateUIView(_ uiView: AnchorView, context: Context) {
        context.coordinator.attach(uiView)
    }

    static func dismantleUIView(_: AnchorView, coordinator: Coordinator) {
        coordinator.stopObserving()
    }

    /// Reports UIKit window changes so pending keyboard frames can be reconciled without a delay.
    @MainActor
    @preconcurrency
    final class AnchorView: UIView {
        var onWindowChange: (() -> Void)?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            onWindowChange?()
        }
    }

    /// Owns notification registration separately from the pure keyboard and gesture state models.
    @MainActor
    @preconcurrency
    final class Coordinator: NSObject {
        private struct NotificationScope: Equatable {
            let screenID: ObjectIdentifier?
            let sceneID: ObjectIdentifier?

            @MainActor
            func belongs(to window: UIWindow) -> Bool {
                if let screenID, screenID != ObjectIdentifier(window.screen) {
                    return false
                }

                if let sceneID,
                   let targetScene = window.windowScene,
                   sceneID != ObjectIdentifier(targetScene) {
                    return false
                }

                return true
            }
        }

        /// A compact notification snapshot retained only while the Browser anchor has no window.
        private struct PendingKeyboardNotification {
            let scope: NotificationScope
            let name: Notification.Name
            let beginFrame: CGRect?
            let endFrame: CGRect?
            let visibleFrame: CGRect?
        }

        private let presence: BrowserSoftwareKeyboardPresence
        private let notificationCenter: NotificationCenter
        private weak var anchorView: UIView?
        private weak var observedWindow: UIWindow?
        private weak var scopedWindow: UIWindow?
        private var pendingKeyboardNotification: PendingKeyboardNotification?
        private var isObserving = false

        init(presence: BrowserSoftwareKeyboardPresence, notificationCenter: NotificationCenter) {
            self.presence = presence
            self.notificationCenter = notificationCenter
        }

        func attach(_ view: UIView) {
            if anchorView !== view {
                if anchorView != nil {
                    clearKeyboardState()
                    observedWindow = nil
                }
                if let oldAnchor = anchorView as? BrowserSoftwareKeyboardPresenceObserver.AnchorView {
                    oldAnchor.onWindowChange = nil
                }
                anchorView = view
            }

            if let anchorView = view as? BrowserSoftwareKeyboardPresenceObserver.AnchorView {
                anchorView.onWindowChange = { [weak self] in
                    self?.anchorViewDidMoveToWindow()
                }
            }

            if !isObserving {
                let notifications: [Notification.Name] = [
                    UIResponder.keyboardWillShowNotification,
                    UIResponder.keyboardDidShowNotification,
                    UIResponder.keyboardWillChangeFrameNotification,
                    UIResponder.keyboardDidChangeFrameNotification,
                    UIResponder.keyboardWillHideNotification,
                    UIResponder.keyboardDidHideNotification,
                ]
                for name in notifications {
                    notificationCenter.addObserver(
                        self,
                        selector: #selector(handleKeyboardNotification(_:)),
                        name: name,
                        object: nil,
                    )
                }
                isObserving = true
            }

            updateObservedWindow(to: view.window)
        }

        func stopObserving() {
            notificationCenter.removeObserver(self)
            isObserving = false
            if let anchorView = anchorView as? BrowserSoftwareKeyboardPresenceObserver.AnchorView {
                anchorView.onWindowChange = nil
            }
            anchorView = nil
            observedWindow = nil
            clearKeyboardState()
        }

        private func anchorViewDidMoveToWindow() {
            guard let anchorView else {
                return
            }

            updateObservedWindow(to: anchorView.window)
        }

        private func updateObservedWindow(to window: UIWindow?) {
            guard observedWindow !== window else {
                return
            }

            if observedWindow != nil {
                clearKeyboardState()
            }
            observedWindow = window

            if let window {
                reconcilePendingKeyboardNotification(in: window)
            }
        }

        @objc
        private func handleKeyboardNotification(_ notification: Notification) {
            guard let scope = notificationScope(for: notification) else {
                return
            }

            let beginFrame = notification.userInfo?[UIResponder.keyboardFrameBeginUserInfoKey] as? CGRect
            let endFrame = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect
            guard let window = anchorView?.window else {
                retainPendingKeyboardNotification(
                    name: notification.name,
                    scope: scope,
                    beginFrame: beginFrame,
                    endFrame: endFrame,
                )
                return
            }
            guard scope.belongs(to: window) else {
                return
            }

            handleKeyboardNotification(
                named: notification.name,
                beginFrame: beginFrame,
                endFrame: endFrame,
                window: window,
            )
        }

        private func notificationScope(for notification: Notification) -> NotificationScope? {
            if let localValue = notification.userInfo?[UIResponder.keyboardIsLocalUserInfoKey] as? NSNumber,
               !localValue.boolValue {
                return nil
            }

            if let sourceWindow = notification.object as? UIWindow {
                return NotificationScope(
                    screenID: ObjectIdentifier(sourceWindow.screen),
                    sceneID: sourceWindow.windowScene.map { ObjectIdentifier($0) },
                )
            }

            if let sourceScreen = notification.object as? UIScreen {
                return NotificationScope(
                    screenID: ObjectIdentifier(sourceScreen),
                    sceneID: nil,
                )
            }

            return NotificationScope(screenID: nil, sceneID: nil)
        }

        private func retainPendingKeyboardNotification(
            name: Notification.Name,
            scope: NotificationScope,
            beginFrame: CGRect?,
            endFrame: CGRect?,
        ) {
            let previous = pendingKeyboardNotification?.scope == scope
                ? pendingKeyboardNotification
                : nil
            var visibleFrame = previous?.visibleFrame

            switch name {
            case UIResponder.keyboardWillShowNotification:
                visibleFrame = endFrame
            case UIResponder.keyboardDidShowNotification:
                visibleFrame = endFrame
            case UIResponder.keyboardWillChangeFrameNotification:
                if visibleFrame == nil {
                    visibleFrame = beginFrame ?? endFrame
                }
            case UIResponder.keyboardDidChangeFrameNotification:
                if let endFrame {
                    visibleFrame = endFrame
                }
            case UIResponder.keyboardWillHideNotification:
                if visibleFrame == nil {
                    visibleFrame = beginFrame ?? endFrame
                }
            case UIResponder.keyboardDidHideNotification:
                if visibleFrame == nil {
                    visibleFrame = beginFrame ?? endFrame
                }
            default:
                return
            }

            pendingKeyboardNotification = PendingKeyboardNotification(
                scope: scope,
                name: name,
                beginFrame: beginFrame,
                endFrame: endFrame,
                visibleFrame: visibleFrame,
            )
        }

        private func reconcilePendingKeyboardNotification(in window: UIWindow) {
            guard let pendingKeyboardNotification else {
                return
            }

            self.pendingKeyboardNotification = nil

            guard pendingKeyboardNotification.scope.belongs(to: window) else {
                return
            }

            handleKeyboardNotification(
                named: pendingKeyboardNotification.name,
                beginFrame: pendingKeyboardNotification.beginFrame,
                endFrame: pendingKeyboardNotification.endFrame,
                visibleFrameEvidence: pendingKeyboardNotification.visibleFrame,
                window: window,
            )
        }

        private func handleKeyboardNotification(
            named name: Notification.Name,
            beginFrame: CGRect?,
            endFrame: CGRect?,
            visibleFrameEvidence: CGRect? = nil,
            window: UIWindow,
        ) {
            let beginIntersects = intersectsWindow(beginFrame, window: window)
            let endIntersects = intersectsWindow(endFrame, window: window)
            let visibleFrameIntersects = intersectsWindow(visibleFrameEvidence, window: window)

            switch name {
            case UIResponder.keyboardWillShowNotification:
                guard endIntersects else {
                    return
                }

                scopedWindow = window
                presence.receive(.willShow)
            case UIResponder.keyboardDidShowNotification:
                guard endIntersects else {
                    return
                }

                if scopedWindow !== window {
                    scopedWindow = window
                    presence.receive(.willShow)
                }
                presence.receive(.didShow)
            case UIResponder.keyboardWillChangeFrameNotification:
                guard beginIntersects || endIntersects || visibleFrameIntersects else {
                    return
                }

                scopedWindow = window
                presence.receive(.willChangeFrame(intersectsBrowserWindow: true))
            case UIResponder.keyboardDidChangeFrameNotification:
                guard endFrame != nil,
                      scopedWindow === window || beginIntersects || endIntersects || visibleFrameIntersects
                else {
                    return
                }

                presence.receive(.didChangeFrame(intersectsBrowserWindow: endIntersects))
                scopedWindow = endIntersects ? window : nil
            case UIResponder.keyboardWillHideNotification:
                guard scopedWindow === window || beginIntersects || endIntersects || visibleFrameIntersects else {
                    return
                }

                if !presence.isPresent {
                    presence.receive(.willShow)
                }
                scopedWindow = window
                presence.receive(.willHide)
            case UIResponder.keyboardDidHideNotification:
                guard scopedWindow === window || beginIntersects || endIntersects || visibleFrameIntersects else {
                    return
                }

                presence.receive(.didHide)
                scopedWindow = nil
            default:
                break
            }
        }

        private func clearKeyboardState() {
            scopedWindow = nil
            pendingKeyboardNotification = nil
            presence.receive(.didHide)
        }

        private func intersectsWindow(_ screenFrame: CGRect?, window: UIWindow) -> Bool {
            guard let screenFrame,
                  !screenFrame.isNull,
                  !screenFrame.isInfinite,
                  screenFrame.width > 0,
                  screenFrame.height > 0
            else {
                return false
            }

            let windowFrame = window.convert(screenFrame, from: window.screen.coordinateSpace)
            return windowFrame.intersects(window.bounds)
        }
    }
}
