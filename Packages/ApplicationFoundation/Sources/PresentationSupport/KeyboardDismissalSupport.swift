//
//  KeyboardDismissalSupport.swift
//  MediaVault
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import SwiftUI
import UIKit

/// The small UIKit mapping required by the shared keyboard-dismissal convention.
@MainActor
@preconcurrency
public enum KeyboardDismissalSupport {
    /// Applies or removes the shared interactive scroll policy on a UIKit scroll view.
    ///
    /// `true` maps the shared SwiftUI interactive policy to UIKit's `.interactive`; `false` restores
    /// `.none`. No other SwiftUI or UIKit keyboard-dismissal modes are translated by this seam.
    public static func setInteractiveDismissal(_ enabled: Bool, on scrollView: UIScrollView) {
        scrollView.keyboardDismissMode = enabled ? .interactive : .none
    }
}

extension View {
    /// Enables scoped outside-tap and interactive swipe dismissal for an optional focus value.
    ///
    /// The modifier observes taps only within the adopting view subtree. Public text-input controls
    /// are excluded so tapping an input can acquire or retain focus, while the non-cancelling tap
    /// recognizer allows an outside button, scroll view, or WebKit surface to process its own touch.
    /// Omitting the modifier leaves the surrounding presentation unchanged.
    @MainActor
    @preconcurrency
    public func keyboardDismissal(focus: FocusState<(some Hashable)?>.Binding) -> some View {
        modifier(KeyboardDismissalModifier(focus: focus))
    }
}

@MainActor
@preconcurrency
private struct KeyboardDismissalModifier<Focus: Hashable>: ViewModifier {
    let focus: FocusState<Focus?>.Binding

    func body(content: Content) -> some View {
        content
            .scrollDismissesKeyboard(.interactively)
            .background {
                KeyboardDismissalTapObserver(focus: focus)
            }
    }
}

@MainActor
@preconcurrency
private struct KeyboardDismissalTapObserver<Focus: Hashable>: UIViewRepresentable {
    let focus: FocusState<Focus?>.Binding

    func makeCoordinator() -> KeyboardDismissalTapCoordinator {
        KeyboardDismissalTapCoordinator(
            isFocused: { focus.wrappedValue != nil },
            dismiss: { focus.wrappedValue = nil },
        )
    }

    func makeUIView(context: Context) -> KeyboardDismissalAnchorView {
        let view = KeyboardDismissalAnchorView()
        view.onSuperviewChange = { [weak coordinator = context.coordinator, weak view] in
            coordinator?.mount(on: view?.superview)
        }
        return view
    }

    func updateUIView(_ uiView: KeyboardDismissalAnchorView, context: Context) {
        context.coordinator.mount(on: uiView.superview)
    }

    static func dismantleUIView(_: KeyboardDismissalAnchorView, coordinator: KeyboardDismissalTapCoordinator) {
        coordinator.unmount()
    }
}

@MainActor
@preconcurrency
private final class KeyboardDismissalAnchorView: UIView {
    var onSuperviewChange: (() -> Void)?

    override func didMoveToSuperview() {
        super.didMoveToSuperview()
        onSuperviewChange?()
    }
}

/// Coordinates the UIKit recognizer used by one adopting presentation subtree.
@MainActor
final class KeyboardDismissalTapCoordinator: NSObject, UIGestureRecognizerDelegate {
    private let isFocused: () -> Bool
    private let dismiss: () -> Void
    private weak var hostView: UIView?
    private var tapRecognizer: UITapGestureRecognizer?

    init(isFocused: @escaping () -> Bool, dismiss: @escaping () -> Void) {
        self.isFocused = isFocused
        self.dismiss = dismiss
    }

    func mount(on hostView: UIView?) {
        guard let hostView else {
            unmount()
            return
        }
        guard self.hostView !== hostView else {
            return
        }

        unmount()
        let recognizer = UITapGestureRecognizer(target: self, action: #selector(handleTapGesture(_:)))
        recognizer.cancelsTouchesInView = false
        recognizer.delaysTouchesBegan = false
        recognizer.delaysTouchesEnded = false
        recognizer.delegate = self
        hostView.addGestureRecognizer(recognizer)
        self.hostView = hostView
        tapRecognizer = recognizer
    }

    func unmount() {
        if let tapRecognizer, let hostView {
            hostView.removeGestureRecognizer(tapRecognizer)
        }
        tapRecognizer = nil
        hostView = nil
    }

    func handleTap() {
        guard isFocused() else {
            return
        }

        dismiss()
    }

    @objc
    private func handleTapGesture(_ recognizer: UITapGestureRecognizer) {
        guard recognizer.state == .ended else {
            return
        }

        handleTap()
    }

    func gestureRecognizer(_: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        guard let hostView else {
            return false
        }

        return KeyboardDismissalTapPolicy.shouldDismiss(touchView: touch.view, within: hostView)
    }

    func gestureRecognizer(
        _: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith _: UIGestureRecognizer,
    ) -> Bool {
        true
    }
}

/// Decides whether a touch inside the adopting subtree is an outside-input dismissal candidate.
enum KeyboardDismissalTapPolicy {
    static func shouldDismiss(touchView: UIView?, within hostView: UIView) -> Bool {
        var current = touchView
        while let view = current {
            if view is UITextField || view is UITextView || view is UISearchBar {
                return false
            }
            if view === hostView {
                return true
            }
            current = view.superview
        }
        return false
    }
}
