//
//  BrowserHistoryGroupingTests.swift
//  MediaVault
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
@testable import BrowserFeature

@Suite("Browser History chronological presentation")
struct BrowserHistoryGroupingTests {
    @Test("History groups Today, Yesterday, and calendar dates newest first")
    func chronologicalGrouping() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
        let reference = Date(timeIntervalSince1970: 1_725_926_400)
        let url = try #require(URL(string: "https://example.com"))
        let entries = [
            BrowserHistoryEntry(
                id: UUID(),
                title: "Older",
                url: url,
                visitedAt: reference.addingTimeInterval(-172_800),
            ),
            BrowserHistoryEntry(id: UUID(), title: "Today", url: url, visitedAt: reference.addingTimeInterval(3_600)),
            BrowserHistoryEntry(
                id: UUID(),
                title: "Yesterday",
                url: url,
                visitedAt: reference.addingTimeInterval(-3_600),
            ),
            BrowserHistoryEntry(id: UUID(), title: "Newest", url: url, visitedAt: reference.addingTimeInterval(7_200)),
        ]

        let groups = BrowserHistoryGrouping.groups(entries, referenceDate: reference, calendar: calendar)

        #expect(groups.map(\.title).prefix(2) == ["Today", "Yesterday"])
        #expect(groups[0].entries.map(\.title) == ["Newest", "Today"])
        #expect(groups.count == 3)
    }
}
