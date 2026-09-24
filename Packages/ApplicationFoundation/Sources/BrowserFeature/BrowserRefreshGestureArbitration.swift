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

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = false
        context.coordinator.attach(view)
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.attach(uiView)
    }

    static func dismantleUIView(_: UIView, coordinator: Coordinator) {
        coordinator.stopObserving()
    }

    /// Owns notification registration separately from the pure keyboard and gesture state models.
    @MainActor
    @preconcurrency
    final class Coordinator: NSObject {
        private let presence: BrowserSoftwareKeyboardPresence
        private let notificationCenter: NotificationCenter
        private weak var anchorView: UIView?
        private weak var scopedWindow: UIWindow?
        private var isObserving = false

        init(presence: BrowserSoftwareKeyboardPresence, notificationCenter: NotificationCenter) {
            self.presence = presence
            self.notificationCenter = notificationCenter
        }

        func attach(_ view: UIView) {
            anchorView = view
            guard !isObserving else {
                return
            }

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

        func stopObserving() {
            notificationCenter.removeObserver(self)
            isObserving = false
            scopedWindow = nil
            anchorView = nil
            presence.receive(.didHide)
        }

        @objc
        private func handleKeyboardNotification(_ notification: Notification) {
            guard let window = anchorView?.window,
                  isLocalNotification(notification, for: window)
            else {
                return
            }

            switch notification.name {
            case UIResponder.keyboardWillShowNotification:
                guard intersectsWindow(
                    notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect,
                    window: window,
                ) else {
                    return
                }

                scopedWindow = window
                presence.receive(.willShow)
            case UIResponder.keyboardDidShowNotification:
                guard scopedWindow === window,
                      intersectsWindow(
                          notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect,
                          window: window,
                      )
                else {
                    return
                }

                presence.receive(.didShow)
            case UIResponder.keyboardWillChangeFrameNotification:
                let endFrame = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect
                let beginFrame = notification.userInfo?[UIResponder.keyboardFrameBeginUserInfoKey] as? CGRect
                let intersects = intersectsWindow(endFrame, window: window)
                    || intersectsWindow(beginFrame, window: window)
                guard intersects else {
                    return
                }

                scopedWindow = window
                presence.receive(.willChangeFrame(intersectsBrowserWindow: true))
            case UIResponder.keyboardDidChangeFrameNotification:
                let endFrame = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect
                let belongsToWindow = scopedWindow === window
                    || notificationFrameBelongsToWindow(notification, window: window, includingBeginFrame: true)
                guard let endFrame, belongsToWindow else {
                    return
                }

                let intersects = intersectsWindow(endFrame, window: window)
                presence.receive(.didChangeFrame(intersectsBrowserWindow: intersects))
                scopedWindow = intersects ? window : nil
            case UIResponder.keyboardWillHideNotification:
                guard scopedWindow === window,
                      notificationFrameBelongsToWindow(notification, window: window, includingBeginFrame: true)
                else {
                    return
                }

                presence.receive(.willHide)
            case UIResponder.keyboardDidHideNotification:
                guard scopedWindow === window,
                      notificationFrameBelongsToWindow(notification, window: window, includingBeginFrame: true)
                else {
                    return
                }

                presence.receive(.didHide)
                scopedWindow = nil
            default:
                break
            }
        }

        private func isLocalNotification(_ notification: Notification, for window: UIWindow) -> Bool {
            if let localValue = notification.userInfo?[UIResponder.keyboardIsLocalUserInfoKey] as? NSNumber,
               !localValue.boolValue {
                return false
            }

            if let sourceWindow = notification.object as? UIWindow {
                guard sourceWindow.screen === window.screen else {
                    return false
                }

                if let sourceScene = sourceWindow.windowScene,
                   let targetScene = window.windowScene,
                   sourceScene !== targetScene {
                    return false
                }
            } else if let sourceScreen = notification.object as? UIScreen,
                      sourceScreen !== window.screen {
                return false
            }

            return true
        }

        private func notificationFrameBelongsToWindow(
            _ notification: Notification,
            window: UIWindow,
            includingBeginFrame: Bool,
        ) -> Bool {
            let endFrame = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect
            let beginFrame = includingBeginFrame
                ? notification.userInfo?[UIResponder.keyboardFrameBeginUserInfoKey] as? CGRect
                : nil
            guard endFrame != nil || beginFrame != nil else {
                return scopedWindow === window
            }

            return intersectsWindow(endFrame, window: window)
                || intersectsWindow(beginFrame, window: window)
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
