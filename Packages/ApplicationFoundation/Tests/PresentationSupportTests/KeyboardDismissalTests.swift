//
//  KeyboardDismissalTests.swift
//  MediaVault
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import SwiftUI
import Testing
import UIKit
@testable import PresentationSupport

@Suite("Keyboard dismissal presentation support")
@MainActor
struct KeyboardDismissalTests {
    @Test("Outside taps ignore text inputs but admit controls inside the scoped host")
    func outsideTapPolicy() {
        let host = UIView()
        let textField = UITextField()
        let textFieldSubview = UIView()
        let button = UIButton(type: .system)
        let outside = UIView()
        host.addSubview(textField)
        textField.addSubview(textFieldSubview)
        host.addSubview(button)

        #expect(!KeyboardDismissalTapPolicy.shouldDismiss(touchView: textField, within: host))
        #expect(!KeyboardDismissalTapPolicy.shouldDismiss(touchView: textFieldSubview, within: host))
        #expect(KeyboardDismissalTapPolicy.shouldDismiss(touchView: button, within: host))
        #expect(!KeyboardDismissalTapPolicy.shouldDismiss(touchView: outside, within: host))
    }

    @Test("The scoped tap recognizer dismisses focus without cancelling the original interaction")
    func tapRecognizerPreservesUnderlyingInteraction() throws {
        var isFocused = true
        var dismissals = 0
        let host = UIView()
        let coordinator = KeyboardDismissalTapCoordinator(
            isFocused: { isFocused },
            dismiss: { dismissals += 1 },
        )
        coordinator.mount(on: host)

        let recognizer = try #require(host.gestureRecognizers?.compactMap { $0 as? UITapGestureRecognizer }.first)
        let otherRecognizer = UITapGestureRecognizer()
        #expect(recognizer.cancelsTouchesInView == false)
        #expect(recognizer.delaysTouchesBegan == false)
        #expect(recognizer.delaysTouchesEnded == false)
        #expect(coordinator.gestureRecognizer(
            recognizer,
            shouldRecognizeSimultaneouslyWith: otherRecognizer,
        ))

        coordinator.handleTap()
        #expect(dismissals == 1)
        isFocused = false
        coordinator.handleTap()
        #expect(dismissals == 1)
    }

    @Test("UIKit receives only the shared interactive policy")
    func interactivePolicyMapping() {
        let scrollView = UIScrollView()

        KeyboardDismissalSupport.setInteractiveDismissal(true, on: scrollView)
        #expect(scrollView.keyboardDismissMode == .interactive)

        KeyboardDismissalSupport.setInteractiveDismissal(false, on: scrollView)
        #expect(scrollView.keyboardDismissMode == .none)
    }

    @Test("The public modifier accepts a generic optional FocusState")
    func genericFocusStateModifierCompiles() {
        let _: any View.Type = FocusStateProbe.self
    }

    private struct FocusStateProbe: View {
        private enum Field: Hashable {
            case omnibox
        }

        @FocusState
        private var focusedField: Field?

        var body: some View {
            TextField("Search", text: .constant(""))
                .focused($focusedField, equals: .omnibox)
                .keyboardDismissal(focus: $focusedField)
        }
    }
}
