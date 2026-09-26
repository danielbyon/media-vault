//
//  CalculatorViewSnapshotTests.swift
//  MediaVault
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import ComposableArchitecture
import DecoySupport
import Dependencies
import Foundation
import FoundationTestSupport
import SnapshotTesting
import SwiftUI
import Testing
@testable import CalculatorFeature

@MainActor
@Suite("Calculator view snapshots")
struct CalculatorViewSnapshotTests {
    @Test("The initial calculator fits the compact phone configuration")
    func initialCompactPhone() {
        assertSnapshot(
            of: view(state: CalculatorFeature.State()),
            as: .image(layout: .device(config: DeterministicTestSupport.compactPhone)),
        )
    }

    @Test("A completed calculation and history fit the large phone configuration")
    func completedLargePhone() throws {
        try assertSnapshot(
            of: view(state: completedState()),
            as: .image(layout: .device(config: DeterministicTestSupport.largePhone)),
        )
    }

    @Test("An error state is readable at regular iPad width")
    func errorRegularWidthIPad() {
        var state = CalculatorFeature.State(snapshot: CalculatorSnapshot(display: "7", expression: "7"))
        state.error = .invalidExpression
        assertSnapshot(
            of: view(state: state),
            as: .image(layout: .device(config: DeterministicTestSupport.regularWidthIPad)),
        )
    }

    @Test("A captured hidden candidate keeps the calculator surface at regular iPad width")
    func hiddenCaptureRegularWidthIPad() {
        var calculator = CalculatorFeature.State()
        calculator.isLoading = true
        var adapterState = CalculatorDecoyAdapter.State(
            calculator: calculator,
            triggerConfiguration: DecoyHiddenEntryTriggerConfiguration(
                declaredTriggers: CalculatorDecoyAdapter.supportedTriggers,
                enabledTriggerIDs: [CalculatorDecoyAdapter.pinEqualsTrigger.id],
            ),
        )
        adapterState.lifecycle = .capturing(CalculatorDecoyCandidateBuffer(digits: "1234"))
        let store = adapterStore(
            state: adapterState,
        )

        #expect(store.presentation.display == "1234")
        assertSnapshot(
            of: decoyView(store: store),
            as: .image(layout: .device(config: DeterministicTestSupport.regularWidthIPad)),
        )
    }

    @Test("A failed hidden candidate is rendered as ordinary calculator state")
    func failedHiddenCandidateRegularWidthIPad() {
        var calculator = CalculatorFeature.State(
            snapshot: CalculatorSnapshot(
                display: "1234",
                expression: "1234",
                history: [
                    CalculatorHistoryEntry(
                        id: DeterministicTestSupport.referenceUUID,
                        expression: "1234",
                        result: "1234",
                        date: DeterministicTestSupport.referenceDate,
                    ),
                ],
                isShowingResult: true,
            ),
        )
        calculator.isLoading = true
        let store = adapterStore(state: CalculatorDecoyAdapter.State(calculator: calculator))

        assertSnapshot(
            of: decoyView(store: store),
            as: .image(layout: .device(config: DeterministicTestSupport.regularWidthIPad)),
        )
    }

    private func completedState() throws -> CalculatorFeature.State {
        try CalculatorFeature.State(
            snapshot: CalculatorSnapshot(
                display: "14",
                expression: "14",
                memory: "5",
                history: [
                    CalculatorHistoryEntry(
                        id: #require(UUID(uuidString: "00000000-0000-0000-0000-000000000004")),
                        expression: "2+3×4",
                        result: "14",
                        date: Date(timeIntervalSince1970: 1_725_000_000),
                    ),
                    CalculatorHistoryEntry(
                        id: #require(UUID(uuidString: "00000000-0000-0000-0000-000000000005")),
                        expression: "10%",
                        result: "0.1",
                        date: Date(timeIntervalSince1970: 1_725_000_001),
                    ),
                ],
            ),
        )
    }

    private func view(state: CalculatorFeature.State) -> some View {
        let store = withDependencies {
            $0.calculatorPersistence.load = { nil }
            $0.calculatorPersistence.save = { _ in }
        } operation: {
            Store(initialState: state) {
                CalculatorFeature()
            }
        }
        return CalculatorView(store: store)
            .environment(\.colorScheme, .light)
    }

    private func adapterStore(
        state: CalculatorDecoyAdapter.State,
    ) -> StoreOf<CalculatorDecoyAdapter> {
        withDependencies {
            $0.calculatorPersistence.load = { nil }
            $0.calculatorPersistence.save = { _ in }
        } operation: {
            Store(initialState: state) {
                CalculatorDecoyAdapter()
            }
        }
    }

    private func decoyView(store: StoreOf<CalculatorDecoyAdapter>) -> some View {
        CalculatorView(
            store: store.scope(state: \.calculator, action: \.calculator),
            presentationOverride: store.presentation,
            inputHandler: { store.send(.input($0)) },
            loadsPersistenceOnAppear: false,
        )
        .environment(\.colorScheme, .light)
    }
}
