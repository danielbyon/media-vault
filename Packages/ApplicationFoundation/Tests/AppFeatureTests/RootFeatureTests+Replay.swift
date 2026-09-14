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
        let snapshot = makeNonEmptyCalculatorSnapshot(entry: entry)
        let directSaves = LockIsolated<[CalculatorSnapshot]>([])
        let ordinarySaves = LockIsolated<[CalculatorSnapshot]>([])
        let (directStore, ordinaryStore) = makeReplayStores(
            snapshot: snapshot,
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

        await directStore.finish()
        await ordinaryStore.finish()

        let directSnapshot = try #require(directSaves.value.last)
        let ordinarySnapshot = try #require(ordinarySaves.value.last)
        #expect(directSnapshot == ordinarySnapshot)
        #expect(directSnapshot == calculatorSnapshot(from: directStore.state.calculator))
        #expect(ordinarySnapshot == calculatorSnapshot(from: ordinaryStore.state.calculator))
    }

    @Test("A failed hidden replay retains the newest snapshot during a persistence burst")
    @MainActor
    func failedHiddenReplayPersistsNewestSnapshotDuringBurst() async throws {
        let entry = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000015"))
        let fixtures = makeBurstReplayStores(entry: entry)
        var firstSaveStartedIterator = fixtures.firstSaveStarted.makeAsyncIterator()

        for (index, digit) in [1, 2, 3, 4].enumerated() {
            await fixtures.directStore.send(.calculatorInput(.button(.digit(digit)))) {
                $0.hiddenEntry = .init(candidate: String((1 ... index + 1).map(String.init).joined()))
            }
        }
        await fixtures.directStore.send(.calculatorInput(.button(.equals))) {
            $0.hiddenEntry?.isVerifying = true
        }

        let replayTask = Task { @MainActor in
            await completeFailedDirectCandidate(
                directStore: fixtures.directStore,
                ordinaryStore: fixtures.ordinaryStore,
                entry: entry,
            )
        }
        _ = await firstSaveStartedIterator.next()
        await replayTask.value
        fixtures.releaseFirstSave.yield(())

        await fixtures.directStore.finish()
        await fixtures.ordinaryStore.finish()

        #expect(fixtures.directStore.state.calculator == fixtures.ordinaryStore.state.calculator)
        #expect(fixtures.directSaves.value.last == calculatorSnapshot(
            from: fixtures.directStore.state.calculator,
        ))
    }
}

private struct BurstReplayFixtures {
    let directStore: TestStoreOf<RootFeature>
    let ordinaryStore: TestStoreOf<RootFeature>
    let firstSaveStarted: AsyncStream<Void>
    let releaseFirstSave: AsyncStream<Void>.Continuation
    let directSaves: LockIsolated<[CalculatorSnapshot]>
}

@MainActor
private func makeBurstReplayStores(entry: UUID) -> BurstReplayFixtures {
    let firstSaveStarted = AsyncStream<Void>.makeStream()
    let releaseFirstSave = AsyncStream<Void>.makeStream()
    let directSaves = LockIsolated<[CalculatorSnapshot]>([])
    let saveCount = LockIsolated(0)
    let directStore = makeRootStore(
        vault: VaultFeature.State(
            phase: .locked,
            configuredKind: .pin,
            usesHiddenEntry: true,
        ),
        calculator: makeNonEmptyCalculator(entry: entry),
        verify: { _ in .incorrect },
        save: { snapshot in
            let call = saveCount.withValue { count in
                let call = count
                count += 1
                return call
            }
            if call == 0 {
                firstSaveStarted.continuation.yield(())
                var releaseIterator = releaseFirstSave.stream.makeAsyncIterator()
                _ = await releaseIterator.next()
            }
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
        calculator: makeNonEmptyCalculator(entry: entry),
        save: { _ in },
        uuid: entry,
    )
    return BurstReplayFixtures(
        directStore: directStore,
        ordinaryStore: ordinaryStore,
        firstSaveStarted: firstSaveStarted.stream,
        releaseFirstSave: releaseFirstSave.continuation,
        directSaves: directSaves,
    )
}

private func calculatorSnapshot(from state: CalculatorFeature.State) -> CalculatorSnapshot {
    CalculatorSnapshot(
        display: state.display,
        expression: state.expression,
        memory: state.memory,
        history: state.history,
        isShowingResult: state.isShowingResult,
    )
}

private func makeNonEmptyCalculatorSnapshot(entry: UUID) -> CalculatorSnapshot {
    CalculatorSnapshot(
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
}

private func makeNonEmptyCalculator(entry: UUID) -> CalculatorFeature.State {
    CalculatorFeature.State(snapshot: makeNonEmptyCalculatorSnapshot(entry: entry))
}

@MainActor
private func makeReplayStores(
    snapshot: CalculatorSnapshot,
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
        calculator: CalculatorFeature.State(snapshot: snapshot),
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
        calculator: CalculatorFeature.State(snapshot: snapshot),
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
