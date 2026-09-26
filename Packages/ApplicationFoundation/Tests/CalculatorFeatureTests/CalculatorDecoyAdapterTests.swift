//
//  CalculatorDecoyAdapterTests.swift
//  MediaVault
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import ComposableArchitecture
import ConcurrencyExtras
import CustomDump
import DecoySupport
import Foundation
import Testing
@testable import CalculatorFeature

@Suite("Calculator decoy adapter")
@MainActor
struct CalculatorDecoyAdapterTests {
    private let historyID = uuid("00000000-0000-0000-0000-000000000041")
    private let firstAttemptID = uuid("00000000-0000-0000-0000-000000000051")
    private let secondAttemptID = uuid("00000000-0000-0000-0000-000000000052")
    private let fixedDate = Date(timeIntervalSince1970: 1_725_000_000)

    @Test("The calculator publishes stable identifiers for both supported triggers")
    func triggerDescriptorsAreStable() {
        #expect(CalculatorDecoyAdapter.longPressEqualsTrigger.id.rawValue == "calculator.long-press-equals")
        #expect(CalculatorDecoyAdapter.pinEqualsTrigger.id.rawValue == "calculator.pin-equals")
        #expect(CalculatorDecoyAdapter.longPressEqualsTrigger.intentKind == .authenticationRequest)
        #expect(CalculatorDecoyAdapter.pinEqualsTrigger.intentKind == .credentialCandidate)
        #expect(
            CalculatorDecoyAdapter.supportedTriggers == [
                CalculatorDecoyAdapter.longPressEqualsTrigger,
                CalculatorDecoyAdapter.pinEqualsTrigger,
            ],
        )
    }

    @Test("The calculator publishes its build-time decoy definition")
    func calculatorDefinitionDeclaresItsSupportedTriggers() {
        let definition = CalculatorDecoyAdapter.definition

        #expect(definition.id == "calculator")
        #expect(definition.displayName == "Calculator")
        #expect(definition.declaredTriggers == CalculatorDecoyAdapter.supportedTriggers)
    }

    @Test("Disabled triggers leave ordinary calculator input unchanged")
    func disabledTriggersDoNotEmitAttempts() async {
        let store = makeAdapterStore(configuration: configuration())

        await store.send(.input(.button(.digit(7))))
        await store.receive(.calculator(.button(.digit(7)))) {
            $0.calculator.display = "7"
            $0.calculator.expression = "7"
        }
        await store.send(.input(.longPressEquals))

        #expect(store.state.lifecycle == .idle)
        #expect(store.state.calculator.display == "7")
        #expect(store.state.presentation.display == "7")
        await store.finish()
    }

    @Test("PIN capture does not begin while the calculator is loading")
    func pinCaptureIsDisabledWhileLoading() async {
        var calculator = CalculatorFeature.State()
        calculator.isLoading = true
        let store = makeAdapterStore(
            calculator: calculator,
            configuration: configuration(pinEqualsEnabled: true),
        )

        await store.send(.input(.button(.digit(4))))
        await store.receive(.calculator(.button(.digit(4))))

        #expect(store.state.lifecycle == .idle)
        #expect(store.state.calculator.isLoading)
        #expect(store.state.presentation.display == "0")
        await store.finish()
    }

    @Test("PIN capture projects digits without changing or saving calculator state")
    func captureProjectsTransientDigits() async {
        let saves = LockIsolated<[CalculatorSnapshot]>([])
        let calculator = CalculatorFeature.State(
            snapshot: CalculatorSnapshot(display: "2", expression: "2+"),
        )
        let candidate = "731904826501"
        let store = makeAdapterStore(
            calculator: calculator,
            configuration: configuration(pinEqualsEnabled: true),
            saves: saves,
        )

        var candidatePrefix = ""
        for character in candidate {
            guard let digit = Int(String(character)) else {
                preconditionFailure("The redaction fixture must contain decimal digits.")
            }

            candidatePrefix.append(character)
            await store.send(.input(.button(.digit(digit)))) {
                $0.lifecycle = .capturing(candidateBuffer(candidatePrefix))
            }
        }

        #expect(store.state.calculator == calculator)
        #expect(
            store.state.presentation == CalculatorPresentation(
                display: candidate,
                expression: "2+\(candidate)",
                error: nil,
            ),
        )
        #expect(saves.value.isEmpty)

        let reflected = String(reflecting: store.state)
        let dumped = String(customDumping: store.state)
        #expect(!reflected.contains(candidate))
        #expect(!dumped.contains(candidate))
        await store.finish()
    }

    @Test("An accepted PIN candidate is discarded without durable calculator effects")
    func acceptedCandidateDoesNotReachCalculatorStateOrPersistence() async {
        let saves = LockIsolated<[CalculatorSnapshot]>([])
        let id = DecoyHiddenEntryAttempt.ID(firstAttemptID)
        let store = makeAdapterStore(
            configuration: configuration(pinEqualsEnabled: true),
            uuidValues: [firstAttemptID],
            saves: saves,
        )

        let attempt = await submitCandidate("1234", attemptID: id, to: store)

        await store.send(.completion(FakeDecoyHost(result: .success(true)).completion(for: attempt))) {
            $0.lifecycle = .idle
        }

        #expect(store.state.calculator == CalculatorFeature.State())
        #expect(store.state.calculator.history.isEmpty)
        #expect(store.state.presentation.display == "0")
        #expect(saves.value.isEmpty)
        await store.finish()
    }

    @Test("Rejected and failed PIN attempts match ordinary input and final persistence")
    func rejectedAndFailedCandidatesReplayThroughCalculatorReducer() async {
        await assertFailedCandidateMatchesOrdinaryInput(.success(false))
        await assertFailedCandidateMatchesOrdinaryInput(.failure(.evaluationFailed))
    }

    @Test("Rejected PIN replay retains the newest snapshot during a persistence burst")
    func rejectedPINReplayPersistsNewestSnapshotDuringBurst() async {
        let initialSnapshot = CalculatorSnapshot(
            display: "7",
            expression: "3+4",
            memory: "9",
        )
        let directCalculator = CalculatorFeature.State(snapshot: initialSnapshot)
        let ordinaryCalculator = CalculatorFeature.State(snapshot: initialSnapshot)
        let firstSaveStarted = AsyncStream<Void>.makeStream()
        let releaseFirstSave = AsyncStream<Void>.makeStream()
        let saveCount = LockIsolated(0)
        let firstSaveSnapshot = LockIsolated<CalculatorSnapshot?>(nil)
        let directSaves = LockIsolated<[CalculatorSnapshot]>([])
        let ordinarySaves = LockIsolated<[CalculatorSnapshot]>([])
        let attemptID = DecoyHiddenEntryAttempt.ID(firstAttemptID)
        let fakeHost = FakeDecoyHost(result: .success(false))
        let directStore = makeHostedAdapterStore(
            calculator: directCalculator,
            configuration: configuration(),
            host: fakeHost,
            uuidValues: [firstAttemptID, historyID],
            persistenceSave: { snapshot in
                let call = saveCount.withValue { count in
                    let call = count
                    count += 1
                    return call
                }
                if call == 0 {
                    firstSaveSnapshot.withValue { $0 = snapshot }
                    firstSaveStarted.continuation.yield(())
                    var releaseIterator = releaseFirstSave.stream.makeAsyncIterator()
                    _ = await releaseIterator.next()
                }
                directSaves.withValue { $0.append(snapshot) }
            },
        )
        let ordinaryStore = makeCalculatorStore(
            saves: ordinarySaves,
            calculator: ordinaryCalculator,
        )

        let firstSaveStartedTask = Task { @MainActor in
            var iterator = firstSaveStarted.stream.makeAsyncIterator()
            _ = await iterator.next()
        }
        let firstButton = CalculatorButton.digit(5)
        await ordinaryStore.send(.button(firstButton)) {
            $0.display = "45"
            $0.expression = "3+45"
        }
        await directStore.send(.adapter(.input(.button(firstButton))))
        let calculatorAfterFirstSave = ordinaryStore.state
        await directStore.receive(.adapter(.calculator(.button(firstButton)))) {
            $0.adapter.calculator = calculatorAfterFirstSave
        }
        await firstSaveStartedTask.value
        let firstSaveExpectedSnapshot = ordinaryStore.state.snapshot
        let enabledConfiguration = configuration(pinEqualsEnabled: true)
        await directStore.send(.adapter(.triggerConfigurationChanged(enabledConfiguration))) {
            $0.adapter.triggerConfiguration = enabledConfiguration
        }

        var candidatePrefix = ""
        for digit in [1, 2, 3, 4] {
            candidatePrefix.append("\(digit)")
            await directStore.send(.adapter(.input(.button(.digit(digit))))) {
                $0.adapter.lifecycle = .capturing(candidateBuffer(candidatePrefix))
            }
        }
        await directStore.send(.adapter(.input(.button(.equals)))) {
            $0.adapter.lifecycle = .credentialEvaluationPending(
                candidate: candidateBuffer("1234"),
                attemptID: attemptID,
            )
        }
        let attempt = DecoyHiddenEntryAttempt(
            id: attemptID,
            triggerID: CalculatorDecoyAdapter.pinEqualsTrigger.id,
            intent: .credentialCandidate(.init("1234")),
        )
        await directStore.receive(.adapter(.delegate(.hiddenEntryAttempt(attempt))))
        await directStore.receive(.adapter(.completion(fakeHost.completion(for: attempt)))) {
            $0.adapter.lifecycle = .idle
        }

        let replayButtons: [CalculatorButton] = [1, 2, 3, 4].map(CalculatorButton.digit) + [.equals]
        let expectedDisplays = ["451", "4512", "45123", "451234", "451237"]
        let expectedExpressions = ["3+451", "3+4512", "3+45123", "3+451234", "451237"]
        let replayHistory = CalculatorHistoryEntry(
            id: historyID,
            expression: "3+451234",
            result: "451237",
            date: fixedDate,
        )
        for (index, button) in replayButtons.enumerated() {
            await ordinaryStore.send(.button(button)) {
                $0.display = expectedDisplays[index]
                $0.expression = expectedExpressions[index]
                if index == replayButtons.count - 1 {
                    $0.history = [replayHistory]
                    $0.isShowingResult = true
                }
            }
            let expectedCalculator = ordinaryStore.state
            await directStore.receive(.adapter(.calculator(.button(button)))) {
                $0.adapter.calculator = expectedCalculator
            }
        }

        #expect(saveCount.value == 1)
        #expect(directStore.state.adapter.calculator != directCalculator)
        #expect(firstSaveSnapshot.value == firstSaveExpectedSnapshot)
        #expect(directStore.state.adapter.calculator.snapshot != firstSaveSnapshot.value)
        #expect(directSaves.value.isEmpty)

        releaseFirstSave.continuation.yield(())
        await directStore.finish()
        await ordinaryStore.finish()

        #expect(directStore.state.adapter.calculator == ordinaryStore.state)
        #expect(directSaves.value.last == directStore.state.adapter.calculator.snapshot)
        #expect(directSaves.value.last == ordinarySaves.value.last)
    }

    @Test("Ordinary input cancels capture and follows the buffered digits")
    func nonCandidateInputReplaysCaptureBeforeContinuing() async {
        let saves = LockIsolated<[CalculatorSnapshot]>([])
        let store = makeAdapterStore(
            configuration: configuration(pinEqualsEnabled: true),
            saves: saves,
        )

        await store.send(.input(.button(.digit(4)))) {
            $0.lifecycle = .capturing(candidateBuffer("4"))
        }
        await store.send(.input(.button(.add))) {
            $0.lifecycle = .idle
        }
        await store.receive(.calculator(.button(.digit(4)))) {
            $0.calculator.display = "4"
            $0.calculator.expression = "4"
        }
        await store.receive(.calculator(.button(.add))) {
            $0.calculator.expression = "4+"
        }

        #expect(store.state.calculator.expression == "4+")
        #expect(saves.value.last == CalculatorSnapshot(display: "4", expression: "4+"))
        await store.finish()
    }

    @Test("Persistence retry reconciles a captured candidate before retrying")
    func retryReplaysCaptureBeforeCoreRetry() async {
        let store = makeAdapterStore(configuration: configuration(pinEqualsEnabled: true))

        await store.send(.input(.button(.digit(8)))) {
            $0.lifecycle = .capturing(candidateBuffer("8"))
        }
        await store.send(.input(.retryPersistence)) {
            $0.lifecycle = .idle
        }
        await store.receive(.calculator(.button(.digit(8)))) {
            $0.calculator.display = "8"
            $0.calculator.expression = "8"
        }
        await store.receive(.calculator(.task)) {
            $0.calculator.isLoading = true
        }
        await store.receive(.calculator(.loaded(.success(nil)))) {
            $0.calculator.isLoading = false
        }

        #expect(store.state.calculator.display == "8")
        #expect(store.state.calculator.expression == "8")
        await store.finish()
    }

    @Test("The thirteenth PIN digit replays the full input as ordinary calculator input")
    func captureOverflowReplaysCandidateAndOverflowDigit() async {
        let store = makeAdapterStore(configuration: configuration(pinEqualsEnabled: true))
        let prefixes = [
            "1",
            "12",
            "123",
            "1234",
            "12345",
            "123456",
            "1234567",
            "12345678",
            "123456789",
            "1234567890",
            "12345678901",
            "123456789012",
        ]
        let digits = [1, 2, 3, 4, 5, 6, 7, 8, 9, 0, 1, 2]

        for (digit, prefix) in zip(digits, prefixes) {
            await store.send(.input(.button(.digit(digit)))) {
                $0.lifecycle = .capturing(candidateBuffer(prefix))
            }
        }
        await store.send(.input(.button(.digit(3)))) {
            $0.lifecycle = .idle
        }

        let ordinaryPrefixes = prefixes + ["1234567890123"]
        for (digit, prefix) in zip(digits + [3], ordinaryPrefixes) {
            await store.receive(.calculator(.button(.digit(digit)))) {
                $0.calculator.display = prefix
                $0.calculator.expression = prefix
            }
        }

        #expect(store.state.calculator.expression == "1234567890123")
        await store.finish()
    }

    @Test("Long press supersedes a pending credential attempt and stale results are ignored")
    func longPressSupersedesPendingCredentialAttempt() async {
        let saves = LockIsolated<[CalculatorSnapshot]>([])
        let oldID = DecoyHiddenEntryAttempt.ID(firstAttemptID)
        let newID = DecoyHiddenEntryAttempt.ID(secondAttemptID)
        let store = makeAdapterStore(
            configuration: configuration(pinEqualsEnabled: true, longPressEqualsEnabled: true),
            uuidValues: [firstAttemptID, secondAttemptID],
            saves: saves,
        )

        await submitCandidate("12", attemptID: oldID, to: store)
        await store.send(.input(.button(.digit(9))))
        await store.send(.input(.retryPersistence))
        #expect(store.state.calculator.expression.isEmpty)
        #expect(saves.value.isEmpty)

        await store.send(.input(.longPressEquals)) {
            $0.lifecycle = .authenticationRequestPending(attemptID: newID)
        }
        await store.receive(.calculator(.button(.digit(1)))) {
            $0.calculator.display = "1"
            $0.calculator.expression = "1"
        }
        await store.receive(.calculator(.button(.digit(2)))) {
            $0.calculator.display = "12"
            $0.calculator.expression = "12"
        }
        await store.receive(.delegate(.hiddenEntryAttempt(.init(
            id: newID,
            triggerID: CalculatorDecoyAdapter.longPressEqualsTrigger.id,
            intent: .authenticationRequest,
        ))))

        await store.send(
            .completion(.init(attemptID: oldID, result: .success(false))),
        )
        #expect(store.state.calculator.expression == "12")
        await store.send(
            .completion(.init(attemptID: newID, result: .failure(.evaluationFailed))),
        ) {
            $0.lifecycle = .idle
        }

        #expect(store.state.calculator.expression == "12")
        #expect(store.state.calculator.history.isEmpty)
        #expect(saves.value.last?.expression == "12")
        await store.finish()
    }

    @Test("A disabled long-press trigger cannot supersede a pending credential attempt")
    func disabledLongPressCannotSupersedeCredentialAttempt() async {
        let id = DecoyHiddenEntryAttempt.ID(firstAttemptID)
        let store = makeAdapterStore(
            configuration: configuration(pinEqualsEnabled: true),
            uuidValues: [firstAttemptID],
        )

        await submitCandidate("6", attemptID: id, to: store)
        await store.send(.input(.longPressEquals))

        #expect(
            store.state.lifecycle == .credentialEvaluationPending(
                candidate: candidateBuffer("6"),
                attemptID: id,
            ),
        )
        #expect(store.state.calculator.expression.isEmpty)
        await store.send(.completion(.init(attemptID: id, result: .success(true)))) {
            $0.lifecycle = .idle
        }
        await store.finish()
    }

    @Test("Long press during capture replays the candidate and requests authentication")
    func longPressReconcilesCaptureBeforeAuthenticationRequest() async {
        let id = DecoyHiddenEntryAttempt.ID(firstAttemptID)
        let store = makeAdapterStore(
            configuration: configuration(pinEqualsEnabled: true, longPressEqualsEnabled: true),
            uuidValues: [firstAttemptID],
        )

        await store.send(.input(.button(.digit(6)))) {
            $0.lifecycle = .capturing(candidateBuffer("6"))
        }
        await store.send(.input(.longPressEquals)) {
            $0.lifecycle = .authenticationRequestPending(attemptID: id)
        }
        await store.receive(.calculator(.button(.digit(6)))) {
            $0.calculator.display = "6"
            $0.calculator.expression = "6"
        }
        await store.receive(.delegate(.hiddenEntryAttempt(.init(
            id: id,
            triggerID: CalculatorDecoyAdapter.longPressEqualsTrigger.id,
            intent: .authenticationRequest,
        ))))

        await store.send(
            .completion(.init(attemptID: id, result: .success(false))),
        ) {
            $0.lifecycle = .idle
        }
        #expect(store.state.calculator.expression == "6")
        await store.finish()
    }

    @Test("A configuration update reconciles an unsubmitted disabled PIN capture")
    func disablingPinTriggerFlushesUnsubmittedCandidate() async {
        let store = makeAdapterStore(configuration: configuration(pinEqualsEnabled: true))

        await store.send(.input(.button(.digit(5)))) {
            $0.lifecycle = .capturing(candidateBuffer("5"))
        }
        await store.send(.triggerConfigurationChanged(configuration(pinEqualsEnabled: false))) {
            $0.lifecycle = .idle
            $0.triggerConfiguration = configuration(pinEqualsEnabled: false)
        }
        await store.receive(.calculator(.button(.digit(5)))) {
            $0.calculator.display = "5"
            $0.calculator.expression = "5"
        }

        #expect(store.state.calculator.expression == "5")
        await store.finish()
    }

    private func assertFailedCandidateMatchesOrdinaryInput(
        _ result: Result<Bool, DecoyHiddenEntryError>,
    ) async {
        let directSaves = LockIsolated<[CalculatorSnapshot]>([])
        let ordinarySaves = LockIsolated<[CalculatorSnapshot]>([])
        let attemptID = DecoyHiddenEntryAttempt.ID(firstAttemptID)
        let digits = [1, 2, 3, 4]
        let prefixes = ["1", "12", "123", "1234"]
        let directStore = makeAdapterStore(
            configuration: configuration(pinEqualsEnabled: true),
            uuidValues: [firstAttemptID, historyID],
            saves: directSaves,
        )
        let ordinaryStore = makeCalculatorStore(saves: ordinarySaves)

        let attempt = await submitCandidate("1234", attemptID: attemptID, to: directStore)
        await directStore.send(.completion(FakeDecoyHost(result: result).completion(for: attempt))) {
            $0.lifecycle = .idle
        }
        for (index, digit) in digits.enumerated() {
            await directStore.receive(.calculator(.button(.digit(digit)))) {
                $0.calculator.display = prefixes[index]
                $0.calculator.expression = prefixes[index]
            }
            await ordinaryStore.send(.button(.digit(digit))) {
                $0.display = prefixes[index]
                $0.expression = prefixes[index]
            }
        }
        await directStore.receive(.calculator(.button(.equals))) {
            $0.calculator.display = "1234"
            $0.calculator.expression = "1234"
            $0.calculator.isShowingResult = true
            $0.calculator.history = [historyEntry()]
        }
        await ordinaryStore.send(.button(.equals)) {
            $0.display = "1234"
            $0.expression = "1234"
            $0.isShowingResult = true
            $0.history = [historyEntry()]
        }

        await directStore.finish()
        await ordinaryStore.finish()

        let expectedSnapshot = CalculatorSnapshot(
            display: "1234",
            expression: "1234",
            history: [historyEntry()],
            isShowingResult: true,
        )
        #expect(directStore.state.calculator == ordinaryStore.state)
        #expect(directStore.state.calculator.snapshot == expectedSnapshot)
        #expect(directSaves.value.last == ordinarySaves.value.last)
        #expect(directSaves.value.last == expectedSnapshot)
    }

    @discardableResult
    private func submitCandidate(
        _ digits: String,
        attemptID: DecoyHiddenEntryAttempt.ID,
        to store: TestStoreOf<CalculatorDecoyAdapter>,
    ) async -> DecoyHiddenEntryAttempt {
        var prefix = ""
        for character in digits {
            prefix.append(character)
            guard let digit = Int(String(character)) else {
                preconditionFailure("Candidate fixtures must contain decimal digits.")
            }

            await store.send(.input(.button(.digit(digit)))) {
                $0.lifecycle = .capturing(candidateBuffer(prefix))
            }
        }

        await store.send(.input(.button(.equals))) {
            $0.lifecycle = .credentialEvaluationPending(
                candidate: candidateBuffer(digits),
                attemptID: attemptID,
            )
        }
        let attempt = DecoyHiddenEntryAttempt(
            id: attemptID,
            triggerID: CalculatorDecoyAdapter.pinEqualsTrigger.id,
            intent: .credentialCandidate(.init(digits)),
        )
        await store.receive(.delegate(.hiddenEntryAttempt(attempt)))
        return attempt
    }

    private func makeAdapterStore(
        calculator: CalculatorFeature.State = .init(),
        configuration: DecoyHiddenEntryTriggerConfiguration =
            CalculatorDecoyAdapter.defaultTriggerConfiguration,
        uuidValues: [UUID] = [],
        saves: LockIsolated<[CalculatorSnapshot]>? = nil,
        persistenceSave: (@Sendable (CalculatorSnapshot) async throws -> Void)? = nil,
    ) -> TestStoreOf<CalculatorDecoyAdapter> {
        let generatedIDs = LockIsolated(uuidValues)
        let saveSnapshot: @Sendable (CalculatorSnapshot) async throws -> Void = persistenceSave ?? { snapshot in
            saves?.withValue { $0.append(snapshot) }
        }
        return TestStore(
            initialState: CalculatorDecoyAdapter.State(
                calculator: calculator,
                triggerConfiguration: configuration,
            ),
        ) {
            CalculatorDecoyAdapter()
        } withDependencies: {
            $0.calculatorPersistence.load = { nil }
            $0.calculatorPersistence.save = { snapshot in
                try await saveSnapshot(snapshot)
            }
            $0.date.now = fixedDate
            $0.uuid = .init {
                generatedIDs.withValue { values in
                    guard !values.isEmpty else {
                        preconditionFailure("The test must provide each UUID before the action that generates it.")
                    }

                    return values.removeFirst()
                }
            }
        }
    }

    private func makeHostedAdapterStore(
        calculator: CalculatorFeature.State,
        configuration: DecoyHiddenEntryTriggerConfiguration,
        host: FakeDecoyHost,
        uuidValues: [UUID],
        persistenceSave: @escaping @Sendable (CalculatorSnapshot) async throws -> Void,
    ) -> TestStoreOf<CalculatorDecoyHostHarness> {
        let generatedIDs = LockIsolated(uuidValues)
        return TestStore(
            initialState: CalculatorDecoyHostHarness.State(
                adapter: CalculatorDecoyAdapter.State(
                    calculator: calculator,
                    triggerConfiguration: configuration,
                ),
            ),
        ) {
            CalculatorDecoyHostHarness(host: host)
        } withDependencies: {
            $0.calculatorPersistence.load = { nil }
            $0.calculatorPersistence.save = persistenceSave
            $0.date.now = fixedDate
            $0.uuid = .init {
                generatedIDs.withValue { values in
                    guard !values.isEmpty else {
                        preconditionFailure("The test must provide each UUID before the action that generates it.")
                    }

                    return values.removeFirst()
                }
            }
        }
    }

    private func makeCalculatorStore(
        saves: LockIsolated<[CalculatorSnapshot]>,
        calculator: CalculatorFeature.State = .init(),
    ) -> TestStoreOf<CalculatorFeature> {
        TestStore(initialState: calculator) {
            CalculatorFeature()
        } withDependencies: {
            $0.calculatorPersistence.load = { nil }
            $0.calculatorPersistence.save = { snapshot in
                saves.withValue { $0.append(snapshot) }
            }
            $0.date.now = fixedDate
            $0.uuid = .constant(historyID)
        }
    }

    private func configuration(
        pinEqualsEnabled: Bool = false,
        longPressEqualsEnabled: Bool = false,
    ) -> DecoyHiddenEntryTriggerConfiguration {
        var enabled: Set<DecoyHiddenEntryTriggerID> = []
        if pinEqualsEnabled {
            enabled.insert(CalculatorDecoyAdapter.pinEqualsTrigger.id)
        }
        if longPressEqualsEnabled {
            enabled.insert(CalculatorDecoyAdapter.longPressEqualsTrigger.id)
        }
        return DecoyHiddenEntryTriggerConfiguration(
            declaredTriggers: CalculatorDecoyAdapter.supportedTriggers,
            enabledTriggerIDs: enabled,
        )
    }

    private func candidateBuffer(_ digits: String) -> CalculatorDecoyCandidateBuffer {
        CalculatorDecoyCandidateBuffer(digits: digits)
    }

    private func historyEntry() -> CalculatorHistoryEntry {
        CalculatorHistoryEntry(
            id: historyID,
            expression: "1234",
            result: "1234",
            date: fixedDate,
        )
    }
}

private struct FakeDecoyHost {
    let result: Result<Bool, DecoyHiddenEntryError>

    func completion(
        for attempt: DecoyHiddenEntryAttempt,
    ) -> DecoyHiddenEntryCompletion {
        DecoyHiddenEntryCompletion(attemptID: attempt.id, result: result)
    }
}

@Reducer
private struct CalculatorDecoyHostHarness {
    @ObservableState
    struct State: Equatable {
        var adapter: CalculatorDecoyAdapter.State
    }

    enum Action: Equatable {
        case adapter(CalculatorDecoyAdapter.Action)
    }

    let host: FakeDecoyHost

    var body: some ReducerOf<Self> {
        Scope(state: \.adapter, action: \.adapter) {
            CalculatorDecoyAdapter()
        }
        Reduce { _, action in
            guard case let .adapter(.delegate(.hiddenEntryAttempt(attempt))) = action else {
                return .none
            }

            return .send(.adapter(.completion(host.completion(for: attempt))))
        }
    }
}

private func uuid(_ value: String) -> UUID {
    guard let parsedUUID = UUID(uuidString: value) else {
        preconditionFailure("The calculator decoy test UUID fixture must be valid.")
    }

    return parsedUUID
}
