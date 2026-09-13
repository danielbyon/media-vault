//
//  RootFeatureTests+HiddenEntry.swift
//  MediaVault
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import AppFeature
import CalculatorFeature
import ComposableArchitecture
import Dependencies
import Foundation
import FoundationTestSupport
import Testing
import VaultFeature

extension RootFeatureTests {
    @Test("A successful hidden PIN leaves a non-empty calculator completely untouched")
    @MainActor
    func successfulHiddenPinPreservesNonEmptyCalculatorState() async throws {
        let entry = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000010"))
        let snapshot = CalculatorSnapshot(
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
        )
        let calculator = CalculatorFeature.State(snapshot: snapshot)
        let saves = LockIsolated<[CalculatorSnapshot]>([])
        let store = makeRootStore(
            vault: VaultFeature.State(
                phase: .locked,
                configuredKind: .pin,
                usesHiddenEntry: true,
            ),
            load: { snapshot },
            verify: { _ in .succeeded },
            save: { snapshot in
                saves.withValue { $0.append(snapshot) }
            },
        )

        await store.send(.calculator(.task)) {
            $0.calculator.isLoading = true
        }
        await store.receive(.calculator(.loaded(.success(snapshot)))) {
            $0.calculator = calculator
        }

        for (index, digit) in [1, 2, 3, 4].enumerated() {
            await store.send(.calculatorInput(.button(.digit(digit)))) {
                $0.hiddenEntry = .init(candidate: String((1 ... index + 1).map(String.init).joined()))
            }
        }
        await store.send(.calculatorInput(.button(.equals))) {
            $0.hiddenEntry?.isVerifying = true
        }
        await store.receive(.vault(.verifyHidden("1234"))) {
            $0.vault.isWorking = true
        }
        await store.receive(.vault(.hiddenVerificationCompleted(.succeeded))) {
            $0.hiddenEntry = nil
            $0.vault.phase = .authenticated
            $0.vault.isWorking = false
        }

        #expect(store.state.calculator == calculator)
        #expect(store.state.calculator.history.count == 1)
        #expect(store.state.calculator.history.allSatisfy { !$0.expression.contains("1234") })
        #expect(saves.value.isEmpty)
    }

    @Test("PIN-equals authenticates from ordinary digits followed by a normal equals tap")
    @MainActor
    func directPinEqualsSucceedsWithoutLongPress() async {
        let store = makeRootStore(
            vault: VaultFeature.State(
                phase: .locked,
                configuredKind: .pin,
                usesHiddenEntry: true,
            ),
            verify: { candidate in
                #expect(candidate == "1234")
                return .succeeded
            },
        )

        for (index, digit) in [1, 2, 3, 4].enumerated() {
            await store.send(.calculatorInput(.button(.digit(digit)))) {
                $0.hiddenEntry = .init(candidate: String((1 ... index + 1).map(String.init).joined()))
            }
        }
        await store.send(.calculatorInput(.button(.equals))) {
            $0.hiddenEntry?.isVerifying = true
        }
        await store.receive(.vault(.verifyHidden("1234"))) {
            $0.vault.isWorking = true
        }
        await store.receive(.vault(.hiddenVerificationCompleted(.succeeded))) {
            $0.hiddenEntry = nil
            $0.vault.phase = .authenticated
            $0.vault.isWorking = false
        }

        #expect(store.state.calculator == CalculatorFeature.State())
    }

    @Test("A failed hidden PIN from an empty calculator replays normal digits and equals")
    @MainActor
    func failedHiddenPinReplaysFromEmptyCalculator() async throws {
        let testUUID = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000011"))
        let store = makeRootStore(
            vault: VaultFeature.State(
                phase: .locked,
                configuredKind: .pin,
                usesHiddenEntry: true,
            ),
            verify: { _ in .incorrect },
            date: DeterministicTestSupport.referenceDate,
            uuid: testUUID,
        )

        for (index, digit) in [1, 2, 3, 4].enumerated() {
            await store.send(.calculatorInput(.button(.digit(digit)))) {
                $0.hiddenEntry = .init(candidate: String((1 ... index + 1).map(String.init).joined()))
            }
        }
        await store.send(.calculatorInput(.button(.equals))) {
            $0.hiddenEntry?.isVerifying = true
        }
        await store.receive(.vault(.verifyHidden("1234"))) {
            $0.vault.isWorking = true
        }
        await store.receive(.vault(.hiddenVerificationCompleted(.incorrect))) {
            $0.hiddenEntry = nil
            $0.vault.isWorking = false
        }

        for (index, digit) in [1, 2, 3, 4].enumerated() {
            let expression = [1, 2, 3, 4]
                .prefix(index + 1)
                .map(String.init)
                .joined()
            await store.receive(.calculator(.button(.digit(digit)))) {
                $0.calculator.display = expression
                $0.calculator.expression = expression
            }
        }
        await store.receive(.calculator(.button(.equals))) {
            $0.calculator.display = "1234"
            $0.calculator.expression = "1234"
            $0.calculator.isShowingResult = true
            $0.calculator.history = [
                CalculatorHistoryEntry(
                    id: testUUID,
                    expression: "1234",
                    result: "1234",
                    date: DeterministicTestSupport.referenceDate,
                ),
            ]
        }
    }

    @Test("Unavailable direct PIN-equals verification replays ordinary calculator input")
    @MainActor
    func unavailableHiddenVerificationReplaysCandidate() async throws {
        let testUUID = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000012"))
        let store = makeRootStore(
            vault: VaultFeature.State(
                phase: .locked,
                configuredKind: .pin,
                usesHiddenEntry: true,
            ),
            verify: { _ in .unavailable },
            date: DeterministicTestSupport.referenceDate,
            uuid: testUUID,
        )

        for (index, digit) in [1, 2, 3, 4].enumerated() {
            await store.send(.calculatorInput(.button(.digit(digit)))) {
                $0.hiddenEntry = .init(candidate: String((1 ... index + 1).map(String.init).joined()))
            }
        }
        await store.send(.calculatorInput(.button(.equals))) {
            $0.hiddenEntry?.isVerifying = true
        }
        await store.receive(.vault(.verifyHidden("1234"))) {
            $0.vault.isWorking = true
        }
        await store.receive(.vault(.hiddenVerificationCompleted(.unavailable))) {
            $0.hiddenEntry = nil
            $0.vault.isWorking = false
        }

        for (index, digit) in [1, 2, 3, 4].enumerated() {
            let expression = [1, 2, 3, 4]
                .prefix(index + 1)
                .map(String.init)
                .joined()
            await store.receive(.calculator(.button(.digit(digit)))) {
                $0.calculator.display = expression
                $0.calculator.expression = expression
            }
        }
        await store.receive(.calculator(.button(.equals))) {
            $0.calculator.display = "1234"
            $0.calculator.expression = "1234"
            $0.calculator.isShowingResult = true
            $0.calculator.history = [
                CalculatorHistoryEntry(
                    id: testUUID,
                    expression: "1234",
                    result: "1234",
                    date: DeterministicTestSupport.referenceDate,
                ),
            ]
        }

        #expect(store.state.vault.phase == .locked)
    }

    @Test("A non-eligible button cancels capture and replays the buffered digits")
    @MainActor
    func nonEligibleInputCancelsAndReplaysCandidate() async {
        let store = makeRootStore(
            vault: VaultFeature.State(
                phase: .locked,
                configuredKind: .pin,
                usesHiddenEntry: true,
            ),
        )

        await store.send(.calculatorInput(.button(.digit(8)))) {
            $0.hiddenEntry = .init(candidate: "8")
        }
        await store.send(.calculatorInput(.button(.add))) {
            $0.hiddenEntry = nil
        }
        await store.receive(.calculator(.button(.digit(8)))) {
            $0.calculator.display = "8"
            $0.calculator.expression = "8"
        }
        await store.receive(.calculator(.button(.add))) {
            $0.calculator.expression = "8+"
        }
        #expect(store.state.hiddenEntry == nil)
    }
}
