import ComposableArchitecture
import Dependencies
import SwiftUI

/// A width-agnostic calculator surface for compact phones, large phones, and regular-width iPads.
///
/// The view uses flexible grid columns and a centered maximum content width. It does not inspect
/// device models or branch on iPhone/iPad identity; later adaptive-layout work can extend this
/// surface without changing the reducer or persistence contracts.
@MainActor
public struct CalculatorView: View {
  private let store: StoreOf<CalculatorFeature>

  public init(store: StoreOf<CalculatorFeature>) {
    self.store = store
  }

  public var body: some View {
    ScrollView {
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
      .padding(16)
      .frame(maxWidth: .infinity)
    }
    .background(Color(uiColor: .systemBackground))
    .task {
      await store.send(.task).finish()
    }
  }

  @ViewBuilder
  private var displayPanel: some View {
    VStack(alignment: .trailing, spacing: 6) {
      Text(store.expression.isEmpty ? " " : store.expression)
        .font(.callout.monospaced())
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .trailing)
        .lineLimit(1)
        .minimumScaleFactor(0.6)

      Text(store.error == nil ? store.display : "Error")
        .font(.system(size: 44, weight: .regular, design: .rounded).monospacedDigit())
        .foregroundStyle(store.error == nil ? Color.primary : Color.red)
        .frame(maxWidth: .infinity, alignment: .trailing)
        .lineLimit(1)
        .minimumScaleFactor(0.5)
        .accessibilityLabel("Calculator display")
        .accessibilityValue(store.error == nil ? store.display : "Error")
    }
    .padding(.horizontal, 4)
    .padding(.vertical, 12)
  }

  private var clipboardControls: some View {
    HStack(spacing: 12) {
      Button("Copy") { store.send(.button(.copy)) }
      Button("Paste") { store.send(.button(.paste)) }
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
        store.send(.task)
      }
      .buttonStyle(.bordered)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(12)
    .background(.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
  }

  private var keypad: some View {
    LazyVGrid(
      columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 4),
      spacing: 10
    ) {
      ForEach(Key.all, id: \.button) { key in
        Button {
          store.send(.button(key.button))
        } label: {
          Text(key.title)
            .font(.system(size: 21, weight: .medium, design: .rounded))
            .frame(maxWidth: .infinity, minHeight: 48)
            .contentShape(Rectangle())
        }
        .buttonStyle(.borderedProminent)
        .tint(key.isOperator ? .orange : .gray)
        .accessibilityLabel(key.accessibilityLabel)
      }
    }
    .disabled(store.isLoading)
  }

  @ViewBuilder
  private var historyPanel: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Text("History")
          .font(.headline)
        Spacer()
        if !store.history.isEmpty {
          Button("Clear") { store.send(.button(.clearHistory)) }
            .font(.subheadline)
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
    Key(title: "AC", button: .clear, isOperator: false, accessibilityLabel: "Clear"),
    Key(title: "⌫", button: .delete, isOperator: false, accessibilityLabel: "Delete"),
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
    Key(title: "M+", button: .memoryAdd, isOperator: false, accessibilityLabel: "Add to memory"),
    Key(title: "M−", button: .memorySubtract, isOperator: false, accessibilityLabel: "Subtract from memory"),
    Key(title: "MR", button: .memoryRecall, isOperator: false, accessibilityLabel: "Recall memory"),
    Key(title: "MC", button: .memoryClear, isOperator: false, accessibilityLabel: "Clear memory"),
    Key(title: "0", button: .digit(0), isOperator: false, accessibilityLabel: "Zero"),
    Key(title: "±", button: .sign, isOperator: false, accessibilityLabel: "Change sign"),
    Key(title: ".", button: .decimal, isOperator: false, accessibilityLabel: "Decimal"),
    Key(title: "=", button: .equals, isOperator: true, accessibilityLabel: "Equals"),
    Key(title: "(", button: .openParenthesis, isOperator: true, accessibilityLabel: "Open parenthesis"),
    Key(title: ")", button: .closeParenthesis, isOperator: true, accessibilityLabel: "Close parenthesis")
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
              date: Date(timeIntervalSince1970: 1_725_000_000)
            )
          ]
        )
      )
    ) {
      CalculatorFeature()
    }
  }
  CalculatorView(store: store)
}
