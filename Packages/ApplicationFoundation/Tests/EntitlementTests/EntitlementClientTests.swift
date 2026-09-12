//
//  EntitlementClientTests.swift
//  MediaVault
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Dependencies
import Testing
@testable import Entitlement

@Suite("Entitlement client")
struct EntitlementClientTests {
    @Dependency(\.entitlement)
    private var entitlement

    @Test("The default test adapter is deterministically unentitled")
    func testValueIsDeterministicallyUnentitled() async throws {
        #expect(try await EntitlementClient.testValue.currentState() == .notEntitled)
    }

    @Test("The entitlement dependency exposes injected state and operation results")
    func injectedValuesAreExposed() async throws {
        let results = try await withDependencies {
            $0.entitlement.currentState = { .entitled }
            $0.entitlement.purchase = { .purchased }
            $0.entitlement.restore = { .restored }
        } operation: {
            let state = try await entitlement.currentState()
            let purchase = await entitlement.purchase()
            let restore = await entitlement.restore()
            return (state, purchase, restore)
        }

        #expect(results.0 == .entitled)
        #expect(results.1 == .purchased)
        #expect(results.2 == .restored)
    }

    @Test("The entitlement dependency preserves state lookup failures")
    func stateLookupFailureIsPreserved() async {
        let result: EntitlementError? = await withDependencies {
            $0.entitlement.currentState = { throw EntitlementError.storeFailure }
        } operation: {
            do {
                _ = try await entitlement.currentState()
                return nil
            } catch let error as EntitlementError {
                return error
            } catch {
                return nil
            }
        }

        #expect(result == EntitlementError.storeFailure)
    }
}
