//
//  CalculatorView.swift
//  MediaVault
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import ComposableArchitecture
import Dependencies
import SwiftUI

/// A calculator surface that adapts its basic keypad and history to the available width.
///
/// Compact, narrow, and accessibility-sized layouts keep the keypad and supporting content in a
/// vertical reading order. Regular-width layouts place the keypad beside history when both columns
/// fit. Hardware-keyboard input enters through the same button actions as touch input.
@MainActor
@preconcurrency
public struct CalculatorView: View {
    @Environment(\.horizontalSizeClass)
    private var horizontalSizeClass
    @Environment(\.dynamicTypeSize)
    private var dynamicTypeSize
    @FocusState
    private var focusedControl: FocusedControl?
    @ScaledMetric(relativeTo: .largeTitle)
    private var displayFontSize = 44

    private let store: StoreOf<CalculatorFeature>
    private let presentationOverride: CalculatorPresentation?
    private let displayOverride: String?
    private let inputHandler: (CalculatorInput) -> Void
    private let loadsPersistenceOnAppear: Bool

    /// Creates a calculator surface backed by the supplied store.
    ///
    /// - Parameters:
    ///   - store: The calculator store that owns displayed state and actions.
    ///   - presentationOverride: Optional transient presentation supplied by the composition root.
    ///     It is presentation-only and never enters the calculator reducer or persistence.
    ///   - displayOverride: Optional transient display text retained for callers that only need to
    ///     replace the main display. The expression and error continue to come from the store.
    ///   - inputHandler: An optional surface-input handler. When omitted, ordinary button inputs are
    ///     sent directly to the supplied calculator store and long-press input is ignored.
    ///   - loadsPersistenceOnAppear: Whether this view starts the calculator persistence load when
    ///     it appears. A composition root that owns a stable lifecycle task can disable this to
    ///     prevent a remounted calculator surface from reloading over live state.
    public init(
        store: StoreOf<CalculatorFeature>,
        presentationOverride: CalculatorPresentation? = nil,
        displayOverride: String? = nil,
        inputHandler: ((CalculatorInput) -> Void)? = nil,
        loadsPersistenceOnAppear: Bool = true,
    ) {
        self.store = store
        self.presentationOverride = presentationOverride
        self.displayOverride = displayOverride
        self.loadsPersistenceOnAppear = loadsPersistenceOnAppear
        self.inputHandler = inputHandler ?? { input in
            switch input {
            case .retryPersistence:
                store.send(.task)
            case let .button(button):
                store.send(.button(button))
            case .longPressEquals:
                break
            }
        }
    }

    private var renderedPresentation: CalculatorPresentation {
        presentationOverride
            ?? displayOverride.map {
                CalculatorPresentation(display: $0, expression: store.expression, error: store.error)
            }
            ?? store.presentation
    }

    /// Renders the display, controls, keypad, and calculation history.
    public var body: some View {
        GeometryReader { geometry in
            Group {
                if store.isLoading {
                    calculatorScrollView(availableWidth: geometry.size.width)
                } else {
                    calculatorScrollView(availableWidth: geometry.size.width)
                        .defaultFocus($focusedControl, .keypad(.clear))
                }
            }
            .onKeyPress(action: handleKeyPress)
            .onChange(of: store.isLoading) { _, isLoading in
                if isLoading {
                    focusedControl = nil
                }
            }
        }
        .task {
            guard loadsPersistenceOnAppear else {
                return
            }

            await store.send(.task).finish()
        }
    }

    /// Builds the calculator scroll view at the width supplied by its parent layout.
    private func calculatorScrollView(availableWidth: CGFloat) -> some View {
        ScrollView {
            Group {
                if CalculatorAdaptiveLayout.usesSideBySideLayout(
                    horizontalSizeClass: horizontalSizeClass,
                    dynamicTypeSize: dynamicTypeSize,
                    availableWidth: availableWidth,
                ) {
                    sideBySideContent
                } else {
                    verticalContent
                }
            }
            .frame(maxWidth: .infinity)
            .padding(16)
            .frame(maxWidth: .infinity)
        }
        .background(Color(uiColor: .systemBackground))
    }

    private enum FocusedControl: Hashable {
        case keypad(CalculatorButton)
        case copy
        case paste
        case retry
        case clearHistory
    }

    private func handleKeyPress(_ keyPress: KeyPress) -> KeyPress.Result {
        let focusedControlIsNonKeypad =
            if let focusedControl {
                if case .keypad = focusedControl {
                    false
                } else {
                    true
                }
            } else {
                false
            }

        if CalculatorHardwareKeyMapper.shouldDeferNativeActivation(
            for: keyPress.characters,
            focusedControlIsNonKeypad: focusedControlIsNonKeypad,
        ) {
            return .ignored
        }

        guard let button = CalculatorHardwareKeyMapper.button(
            for: keyPress.characters,
            isDelete: keyPress.key == .delete,
            isEscape: keyPress.key == .escape,
        ) else {
            return .ignored
        }

        inputHandler(.button(button))
        return .handled
    }

    private var verticalContent: some View {
        VStack(spacing: 16) {
            displayPanel
            if store.persistenceError != nil {
                persistenceFailurePanel
            }
            clipboardControls
            keypad
            historyPanel
        }
        .frame(maxWidth: 520)
    }

    private var sideBySideContent: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(spacing: 16) {
                displayPanel
                keypad
            }
            .frame(minWidth: 320, maxWidth: 520)

            VStack(spacing: 16) {
                if store.persistenceError != nil {
                    persistenceFailurePanel
                }
                clipboardControls
                historyPanel
            }
            .frame(minWidth: 240, maxWidth: 360)
        }
        .frame(maxWidth: 896)
    }

    private var displayPanel: some View {
        VStack(alignment: .trailing, spacing: 6) {
            Text(renderedPresentation.expression.isEmpty ? " " : renderedPresentation.expression)
                .font(.callout.monospaced())
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .lineLimit(1)
                .minimumScaleFactor(0.6)

            Text(renderedPresentation.error == nil ? renderedPresentation.display : "Error")
                .font(.system(size: displayFontSize, weight: .regular, design: .rounded).monospacedDigit())
                .foregroundStyle(renderedPresentation.error == nil ? Color.primary : Color.red)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .accessibilityLabel("Calculator display")
                .accessibilityValue(renderedPresentation.error == nil ? renderedPresentation.display : "Error")
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 12)
    }

    private var clipboardControls: some View {
        HStack(spacing: 12) {
            Button("Copy") { inputHandler(.button(.copy)) }
                .focused($focusedControl, equals: .copy)
            Button("Paste") { inputHandler(.button(.paste)) }
                .focused($focusedControl, equals: .paste)
        }
        .buttonStyle(.bordered)
        .frame(maxWidth: .infinity, alignment: .trailing)
        .disabled(store.isLoading)
    }

    private var persistenceFailurePanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("History unavailable")
                .font(.headline)
                .foregroundStyle(.red)
            Text("Calculations can continue, but history cannot be saved or restored.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Button("Retry") {
                inputHandler(.retryPersistence)
            }
            .buttonStyle(.bordered)
            .focused($focusedControl, equals: .retry)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
    }

    private var keypad: some View {
        LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 4),
            spacing: 10,
        ) {
            ForEach(Key.all, id: \.button) { key in
                keyButton(key)
            }
        }
        .disabled(store.isLoading)
    }

    @ViewBuilder
    private func keyButton(_ key: Key) -> some View {
        if key.button == .equals {
            baseKeyButton(key)
                .highPriorityGesture(
                    LongPressGesture(minimumDuration: 0.75)
                        .onEnded { _ in
                            inputHandler(.longPressEquals)
                        },
                )
                .accessibilityAction(named: Text("Long press")) {
                    inputHandler(.longPressEquals)
                }
        } else {
            baseKeyButton(key)
        }
    }

    private func baseKeyButton(_ key: Key) -> some View {
        Button {
            inputHandler(.button(key.button))
        } label: {
            Text(key.title)
                .font(.system(.title3, design: .rounded, weight: .medium))
                .frame(maxWidth: .infinity, minHeight: 48)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderedProminent)
        .tint(key.isOperator ? .orange : .gray)
        .accessibilityLabel(key.accessibilityLabel)
        .focused($focusedControl, equals: .keypad(key.button))
    }

    private var historyPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("History")
                    .font(.headline)
                Spacer()
                if !store.history.isEmpty {
                    Button("Clear") { inputHandler(.button(.clearHistory)) }
                        .font(.subheadline)
                        .accessibilityLabel("Clear history")
                        .accessibilityIdentifier("calculator.clear-history")
                        .focused($focusedControl, equals: .clearHistory)
                }
            }

            if store.history.isEmpty {
                Text("No calculations yet")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(store.history) { entry in
                    HStack {
                        Text(entry.expression)
                            .font(.subheadline.monospaced())
                            .lineLimit(1)
                        Spacer(minLength: 12)
                        Text(entry.result)
                            .font(.subheadline.monospacedDigit())
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 14))
    }
}

private struct Key {
    let title: String
    let button: CalculatorButton
    let isOperator: Bool
    let accessibilityLabel: String

    static let all: [Key] = [
        Key(title: "⌫", button: .delete, isOperator: false, accessibilityLabel: "Delete"),
        Key(title: "AC", button: .clear, isOperator: false, accessibilityLabel: "Clear"),
        Key(title: "%", button: .percent, isOperator: true, accessibilityLabel: "Percent"),
        Key(title: "÷", button: .divide, isOperator: true, accessibilityLabel: "Divide"),
        Key(title: "7", button: .digit(7), isOperator: false, accessibilityLabel: "Seven"),
        Key(title: "8", button: .digit(8), isOperator: false, accessibilityLabel: "Eight"),
        Key(title: "9", button: .digit(9), isOperator: false, accessibilityLabel: "Nine"),
        Key(title: "×", button: .multiply, isOperator: true, accessibilityLabel: "Multiply"),
        Key(title: "4", button: .digit(4), isOperator: false, accessibilityLabel: "Four"),
        Key(title: "5", button: .digit(5), isOperator: false, accessibilityLabel: "Five"),
        Key(title: "6", button: .digit(6), isOperator: false, accessibilityLabel: "Six"),
        Key(title: "−", button: .subtract, isOperator: true, accessibilityLabel: "Subtract"),
        Key(title: "1", button: .digit(1), isOperator: false, accessibilityLabel: "One"),
        Key(title: "2", button: .digit(2), isOperator: false, accessibilityLabel: "Two"),
        Key(title: "3", button: .digit(3), isOperator: false, accessibilityLabel: "Three"),
        Key(title: "+", button: .add, isOperator: true, accessibilityLabel: "Add"),
        Key(title: "0", button: .digit(0), isOperator: false, accessibilityLabel: "Zero"),
        Key(title: "±", button: .sign, isOperator: false, accessibilityLabel: "Change sign"),
        Key(title: ".", button: .decimal, isOperator: false, accessibilityLabel: "Decimal"),
        Key(title: "=", button: .equals, isOperator: true, accessibilityLabel: "Equals"),
        Key(title: "M+", button: .memoryAdd, isOperator: false, accessibilityLabel: "Add to memory"),
        Key(title: "M−", button: .memorySubtract, isOperator: false, accessibilityLabel: "Subtract from memory"),
        Key(title: "MR", button: .memoryRecall, isOperator: false, accessibilityLabel: "Recall memory"),
        Key(title: "MC", button: .memoryClear, isOperator: false, accessibilityLabel: "Clear memory"),
        Key(title: "(", button: .openParenthesis, isOperator: true, accessibilityLabel: "Open parenthesis"),
        Key(title: ")", button: .closeParenthesis, isOperator: true, accessibilityLabel: "Close parenthesis"),
    ]
}

#Preview("Calculator initial") {
    let store = withDependencies {
        $0.calculatorPersistence.load = { nil }
        $0.calculatorPersistence.save = { _ in }
    } operation: {
        Store(initialState: CalculatorFeature.State()) {
            CalculatorFeature()
        }
    }
    CalculatorView(store: store)
}

#Preview("Calculator history") {
    let store = withDependencies {
        $0.calculatorPersistence.load = { nil }
        $0.calculatorPersistence.save = { _ in }
    } operation: {
        Store(
            initialState: CalculatorFeature.State(
                snapshot: CalculatorSnapshot(
                    display: "14",
                    expression: "14",
                    history: [
                        CalculatorHistoryEntry(
                            id: UUID(),
                            expression: "2+3×4",
                            result: "14",
                            date: Date(timeIntervalSince1970: 1_725_000_000),
                        ),
                    ],
                ),
            ),
        ) {
            CalculatorFeature()
        }
    }
    CalculatorView(store: store)
}
