//
//  RootFeatureTests+Replay.swift
//  MediaVault
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import AppFeature
import CalculatorFeature
import ComposableArchitecture
import ConcurrencyExtras
import Dependencies
import Foundation
import FoundationTestSupport
import Testing
import VaultFeature

extension RootFeatureTests {
    @Test("An incorrect direct PIN-equals candidate from a non-empty calculator matches ordinary input")
    @MainActor
    func incorrectDirectPinEqualsReplaysFromNonEmptyCalculator() async throws {
        let entry = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000014"))
        let calculator = makeNonEmptyCalculator(entry: entry)
        let directSaves = LockIsolated<[CalculatorSnapshot]>([])
        let ordinarySaves = LockIsolated<[CalculatorSnapshot]>([])
        let (directStore, ordinaryStore) = makeReplayStores(
            calculator: calculator,
            entry: entry,
            directSaves: directSaves,
            ordinarySaves: ordinarySaves,
        )

        for (index, digit) in [1, 2, 3, 4].enumerated() {
            await directStore.send(.calculatorInput(.button(.digit(digit)))) {
                $0.hiddenEntry = .init(candidate: String((1 ... index + 1).map(String.init).joined()))
            }
        }
        await directStore.send(.calculatorInput(.button(.equals))) {
            $0.hiddenEntry?.isVerifying = true
        }
        await completeFailedDirectCandidate(
            directStore: directStore,
            ordinaryStore: ordinaryStore,
            entry: entry,
        )

        #expect(directStore.state.vault.phase == .locked)
        #expect(directStore.state.calculator == ordinaryStore.state.calculator)
        #expect(directSaves.value == ordinarySaves.value)
    }
}

private func makeNonEmptyCalculator(entry: UUID) -> CalculatorFeature.State {
    CalculatorFeature.State(
        snapshot: CalculatorSnapshot(
            display: "7",
            expression: "3+4",
            memory: "9",
            history: [
                CalculatorHistoryEntry(
                    id: entry,
                    expression: "2+5",
                    result: "7",
                    date: DeterministicTestSupport.referenceDate,
                ),
            ],
            isShowingResult: false,
        ),
    )
}

@MainActor
private func makeReplayStores(
    calculator: CalculatorFeature.State,
    entry: UUID,
    directSaves: LockIsolated<[CalculatorSnapshot]>,
    ordinarySaves: LockIsolated<[CalculatorSnapshot]>,
) -> (TestStoreOf<RootFeature>, TestStoreOf<RootFeature>) {
    let directStore = makeRootStore(
        vault: VaultFeature.State(
            phase: .locked,
            configuredKind: .pin,
            usesHiddenEntry: true,
        ),
        calculator: calculator,
        verify: { _ in .incorrect },
        save: { snapshot in
            directSaves.withValue { $0.append(snapshot) }
        },
        uuid: entry,
    )
    let ordinaryStore = makeRootStore(
        vault: VaultFeature.State(
            phase: .locked,
            configuredKind: .pin,
            usesHiddenEntry: false,
        ),
        calculator: calculator,
        save: { snapshot in
            ordinarySaves.withValue { $0.append(snapshot) }
        },
        uuid: entry,
    )
    return (directStore, ordinaryStore)
}

@MainActor
private func completeFailedDirectCandidate(
    directStore: TestStoreOf<RootFeature>,
    ordinaryStore: TestStoreOf<RootFeature>,
    entry: UUID,
) async {
    await directStore.receive(.vault(.verifyHidden("1234"))) {
        $0.vault.isWorking = true
    }
    await directStore.receive(.vault(.hiddenVerificationCompleted(.incorrect))) {
        $0.hiddenEntry = nil
        $0.vault.isWorking = false
    }
    for (index, digit) in [1, 2, 3, 4].enumerated() {
        let digits = [1, 2, 3, 4]
            .prefix(index + 1)
            .map(String.init)
            .joined()
        await ordinaryStore.send(.calculator(.button(.digit(digit)))) {
            $0.calculator.display = "4" + digits
            $0.calculator.expression = "3+4" + digits
        }
        await directStore.receive(.calculator(.button(.digit(digit)))) {
            $0.calculator = ordinaryStore.state.calculator
        }
    }
    await ordinaryStore.send(.calculator(.button(.equals))) {
        $0.calculator.display = "41237"
        $0.calculator.expression = "41237"
        $0.calculator.isShowingResult = true
        $0.calculator.history = [
            CalculatorHistoryEntry(
                id: entry,
                expression: "3+41234",
                result: "41237",
                date: DeterministicTestSupport.referenceDate,
            ),
            CalculatorHistoryEntry(
                id: entry,
                expression: "2+5",
                result: "7",
                date: DeterministicTestSupport.referenceDate,
            ),
        ]
    }
    await directStore.receive(.calculator(.button(.equals))) {
        $0.calculator = ordinaryStore.state.calculator
    }
}
