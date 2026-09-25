//
//  BrowserTabCardDrag.swift
//  MediaVault
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import ComposableArchitecture
import Foundation
import SwiftUI
import UIKit

/// Transient view state for the card currently receiving a direct-manipulation gesture.
struct BrowserTabCardDrag: Equatable {
    let tabID: BrowserTabID
    let axis: BrowserTabSwipe.Axis
    let horizontalTranslation: CGFloat
}

/// Tracks one tab-card press, its recognized drag, and its transient presentation state.
///
/// The press classification survives drag presentation cleanup so a completed drag cannot be
/// reinterpreted as a Button activation. A new physical press begins a fresh interaction.
struct BrowserTabCardInteraction: Equatable {
    private enum SelectionState: Equatable {
        case idle
        case tapEligible
        case dragRecognized
        case activated
    }

    private(set) var drag: BrowserTabCardDrag?
    private var interactionTabID: BrowserTabID?
    private var selectionState = SelectionState.idle
    private var physicalPressIsActive = false

    /// Begins a new physical interaction at the Button's press-down boundary.
    mutating func beginPhysicalPress(for tabID: BrowserTabID) {
        guard interactionTabID != tabID
            || !physicalPressIsActive
            || selectionState != .dragRecognized
        else {
            return
        }

        interactionTabID = tabID
        selectionState = .tapEligible
        physicalPressIsActive = true
        drag = nil
    }

    /// Records Button release without making a completed drag eligible for activation again.
    mutating func endPhysicalPress(for tabID: BrowserTabID) {
        guard interactionTabID == tabID else {
            return
        }

        physicalPressIsActive = false
    }

    /// Locks the first recognized drag axis and updates the card's horizontal presentation.
    mutating func updateDrag(for tabID: BrowserTabID, translation: CGSize) {
        let axis =
            if let drag, drag.tabID == tabID {
                drag.axis
            } else {
                BrowserTabSwipe.axis(for: translation)
            }

        interactionTabID = tabID
        selectionState = .dragRecognized
        physicalPressIsActive = true
        drag = BrowserTabCardDrag(
            tabID: tabID,
            axis: axis,
            horizontalTranslation: axis == .horizontal ? translation.width : 0,
        )
    }

    /// Returns the existing close outcome for the locked drag axis, if it is horizontal.
    func swipeOutcome(for tabID: BrowserTabID, translation: CGSize) -> BrowserTabSwipe.Outcome? {
        guard let drag, drag.tabID == tabID else {
            return nil
        }

        return BrowserTabSwipe.outcome(for: translation, axis: drag.axis)
    }

    /// Clears direct-manipulation presentation while retaining drag-based activation suppression.
    mutating func finishDrag(for tabID: BrowserTabID) {
        guard drag?.tabID == tabID else {
            return
        }

        drag = nil
    }

    /// Allows a genuine tap once and rejects activation after any recognized drag.
    mutating func consumeSelection(for tabID: BrowserTabID) -> Bool {
        guard interactionTabID == tabID else {
            guard selectionState == .idle else {
                return false
            }

            interactionTabID = tabID
            selectionState = .activated
            return true
        }
        guard selectionState == .tapEligible else {
            return false
        }

        selectionState = .activated
        return true
    }
}

/// Reports the start of a standard Button press without replacing its activation semantics.
struct BrowserTabCardPressTrackingButtonStyle: ButtonStyle {
    let onPressBegan: () -> Void
    let onPressEnded: () -> Void

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .onChange(of: configuration.isPressed) { _, isPressed in
                if isPressed {
                    onPressBegan()
                } else {
                    onPressEnded()
                }
            }
    }
}

struct BrowserChromeHeightPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

struct BrowserContentViewportPreferenceKey: PreferenceKey {
    static let defaultValue: BrowserContentViewportGeometry? = nil

    static func reduce(
        value: inout BrowserContentViewportGeometry?,
        nextValue: () -> BrowserContentViewportGeometry?,
    ) {
        if let nextGeometry = nextValue() {
            value = nextGeometry
        }
    }
}

/// Measures the page region produced by the same safe-area chrome structure used for browsing.
///
/// The geometry reader is inside the view whose bottom or top safe-area bar reserves Browser
/// chrome. SwiftUI therefore supplies the resulting page region directly instead of requiring a
/// second implementation of safe-area and chrome arithmetic.
struct BrowserContentViewportProbe: View {
    let chromeHeight: CGFloat
    let chromeAtTop: Bool

    var body: some View {
        GeometryReader { proxy in
            Color.clear.preference(
                key: BrowserContentViewportPreferenceKey.self,
                value: proxy.size.width > 0 && proxy.size.height > 0
                    ? BrowserContentViewportGeometry(size: proxy.size)
                    : nil,
            )
        }
        .safeAreaBar(
            edge: chromeAtTop ? .top : .bottom,
            spacing: 0,
        ) {
            Color.clear
                .frame(height: chromeHeight)
                .accessibilityHidden(true)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

@MainActor
@preconcurrency
struct BrowserPresentationKeyboardDismissalModifier: ViewModifier {
    let isEnabled: Bool
    let focus: FocusState<BrowserFocusedField?>.Binding

    func body(content: Content) -> some View {
        content
            .scrollDismissesKeyboard(isEnabled ? .interactively : .automatic)
            .background {
                BrowserPresentationTapObserver(focus: focus, isEnabled: isEnabled)
            }
    }
}

/// Installs one non-cancelling outside-tap observer on the hosting view for the whole browsing
/// presentation. SwiftUI's generic keyboard-dismissal modifier mounts its UIKit observer beside a
/// complex safe-area presentation, so this Browser-owned observer deliberately resolves the
/// hosting view as its gesture owner and covers both page content and chrome.
@MainActor
@preconcurrency
struct BrowserPresentationTapObserver: UIViewRepresentable {
    let focus: FocusState<BrowserFocusedField?>.Binding
    let isEnabled: Bool

    func makeCoordinator() -> BrowserPresentationTapCoordinator {
        BrowserPresentationTapCoordinator(
            isFocused: { focus.wrappedValue != nil },
            dismiss: { focus.wrappedValue = nil },
            isEnabled: isEnabled,
        )
    }

    func makeUIView(context: Context) -> BrowserPresentationTapAnchorView {
        let view = BrowserPresentationTapAnchorView()
        view.onHierarchyChange = { [weak coordinator = context.coordinator, weak view] in
            coordinator?.mount(on: view.flatMap(Self.hostingView(containing:)))
        }
        return view
    }

    func updateUIView(_ uiView: BrowserPresentationTapAnchorView, context: Context) {
        context.coordinator.update(isEnabled: isEnabled)
        context.coordinator.mount(on: Self.hostingView(containing: uiView))
    }

    static func dismantleUIView(
        _: BrowserPresentationTapAnchorView,
        coordinator: BrowserPresentationTapCoordinator,
    ) {
        coordinator.unmount()
    }

    private static func hostingView(containing view: UIView) -> UIView? {
        if let rootView = view.window?.rootViewController?.view {
            return rootView
        }

        var rootView = view
        while let superview = rootView.superview {
            rootView = superview
        }
        return rootView === view ? nil : rootView
    }
}

@MainActor
@preconcurrency
final class BrowserPresentationTapAnchorView: UIView {
    var onHierarchyChange: (() -> Void)?

    override func didMoveToSuperview() {
        super.didMoveToSuperview()
        onHierarchyChange?()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        onHierarchyChange?()
    }
}

/// Coordinates the single Browser-wide tap recognizer while leaving the tapped control's own
/// interaction intact.
@MainActor
@preconcurrency
final class BrowserPresentationTapCoordinator: NSObject, UIGestureRecognizerDelegate {
    private let isFocused: () -> Bool
    private let dismiss: () -> Void
    private var isEnabled: Bool
    private weak var hostView: UIView?
    private var tapRecognizer: UITapGestureRecognizer?

    init(
        isFocused: @escaping () -> Bool,
        dismiss: @escaping () -> Void,
        isEnabled: Bool,
    ) {
        self.isFocused = isFocused
        self.dismiss = dismiss
        self.isEnabled = isEnabled
    }

    func update(isEnabled: Bool) {
        self.isEnabled = isEnabled
    }

    func mount(on hostView: UIView?) {
        guard isEnabled, let hostView else {
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

    @objc
    private func handleTapGesture(_ recognizer: UITapGestureRecognizer) {
        guard recognizer.state == .ended, isFocused() else {
            return
        }

        dismiss()
    }

    func gestureRecognizer(_: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        guard let hostView else {
            return false
        }

        var current = touch.view
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

    func gestureRecognizer(
        _: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith _: UIGestureRecognizer,
    ) -> Bool {
        true
    }
}
