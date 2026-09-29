//
//  CalculatorPersistenceTests.swift
//  MediaVault
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import CalculatorFeature
import Foundation
import PersistenceSupport
import Testing

@Suite("Calculator persistence")
struct CalculatorPersistenceTests {
    @Test("History survives a fresh feature state and remains isolated per database")
    func historySurvivesRelaunchAndIsIsolated() async throws {
        let firstDatabase = try PersistenceStore.makeInMemory()
        let secondDatabase = try PersistenceStore.makeInMemory()
        let firstClient = CalculatorPersistenceClient.forDatabase(firstDatabase)
        let secondClient = CalculatorPersistenceClient.forDatabase(secondDatabase)
        let snapshot = try CalculatorSnapshot(
            display: "14",
            expression: "14",
            history: [
                CalculatorHistoryEntry(
                    id: #require(UUID(uuidString: "00000000-0000-0000-0000-000000000003")),
                    expression: "2+3×4",
                    result: "14",
                    date: Date(timeIntervalSince1970: 1_725_000_000),
                ),
            ],
        )

        try await firstClient.save(snapshot)

        #expect(try await firstClient.load() == snapshot)
        #expect(try await secondClient.load() == nil)
        #expect(try await CalculatorFeature.State(snapshot: firstClient.load()).history == snapshot.history)
    }

    @Test("A legacy calculator snapshot without angle mode decodes as Degrees")
    func legacySnapshotDefaultsToDegrees() throws {
        let legacyPayload = Data(
            #"{"display":"14","expression":"14","memory":"5","history":[],"isShowingResult":false}"#.utf8,
        )

        let snapshot = try JSONDecoder().decode(CalculatorSnapshot.self, from: legacyPayload)
        let encoded = try JSONEncoder().encode(snapshot)
        let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])

        #expect(snapshot.display == "14")
        #expect(snapshot.memory == "5")
        #expect(object["angleMode"] as? String == "degrees")
    }

    @Test("A persisted Radians mode survives a snapshot round trip")
    func radiansModeSurvivesSnapshotRoundTrip() throws {
        let payload = Data(
            #"{"display":"0","expression":"","memory":null,"history":[],"isShowingResult":false,"angleMode":"radians"}"#.utf8,
        )

        let snapshot = try JSONDecoder().decode(CalculatorSnapshot.self, from: payload)
        let encoded = try JSONEncoder().encode(snapshot)
        let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])

        #expect(object["angleMode"] as? String == "radians")
        #expect(CalculatorFeature.State(snapshot: snapshot).angleMode == .radians)
    }
}
