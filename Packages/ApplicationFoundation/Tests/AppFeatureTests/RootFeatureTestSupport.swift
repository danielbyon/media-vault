//
//  RootFeatureTestSupport.swift
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
import VaultFeature

@MainActor
func makeRootStore(
    vault: VaultFeature.State,
    calculator: CalculatorFeature.State = .init(),
    load: @escaping @Sendable () async throws -> CalculatorSnapshot? = { nil },
    verify: @escaping @Sendable (String) async -> VaultCredentialVerificationResult = { _ in .unavailable },
    save: @escaping @Sendable (CalculatorSnapshot) async throws -> Void = { _ in },
    date: Date = DeterministicTestSupport.referenceDate,
    uuid: UUID = DeterministicTestSupport.referenceUUID,
) -> TestStoreOf<RootFeature> {
    TestStore(initialState: RootFeature.State(calculator: calculator, vault: vault)) {
        RootFeature()
    } withDependencies: {
        $0.calculatorPersistence.load = load
        $0.calculatorPersistence.save = save
        $0.vaultCredential.verify = verify
        $0.date.now = date
        $0.uuid = .constant(uuid)
    }
}
