//
//  MediaLibraryIngestionTests.swift
//  MediaVault
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Testing
@testable import MediaLibrary

struct MediaLibraryIngestionTests {
    @Test("Ingestion states keep their stable persisted values")
    func ingestionStateMappings() {
        #expect(
            MediaIngestionState.allCases.map(\.rawValue) == [
                "received",
                "validating",
                "duplicateCheck",
                "ready",
                "committing",
                "complete",
                "awaitingUserDecision",
                "failed",
                "cancelled",
            ],
        )
    }

    @Test("Every supported state has a stable raw SQLite mapping")
    func ingestionStateRawValuesAreUnique() {
        let rawValues = MediaIngestionState.allCases.map(\.rawValue)
        #expect(Set(rawValues).count == rawValues.count)
        #expect(rawValues.count == 9)
    }
}
