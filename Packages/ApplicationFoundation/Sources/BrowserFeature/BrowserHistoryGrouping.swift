//
//  BrowserHistoryGrouping.swift
//  MediaVault
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

/// One chronological section in the durable History presentation.
struct BrowserHistoryGroup: Identifiable, Equatable, Sendable {
    var id: Date
    var title: String
    var entries: [BrowserHistoryEntry]
}

/// Pure chronological projection for durable History rows supplied by Issue #39.
enum BrowserHistoryGrouping {
    static func groups(
        _ entries: [BrowserHistoryEntry],
        referenceDate: Date,
        calendar: Calendar,
    ) -> [BrowserHistoryGroup] {
        let startOfToday = calendar.startOfDay(for: referenceDate)
        let startOfYesterday = calendar.date(byAdding: .day, value: -1, to: startOfToday)
        let grouped = Dictionary(grouping: entries.sorted { $0.visitedAt > $1.visitedAt }) {
            calendar.startOfDay(for: $0.visitedAt)
        }
        return grouped.keys.sorted(by: >).map { day in
            let title: String =
                if day == startOfToday {
                    "Today"
                } else if day == startOfYesterday {
                    "Yesterday"
                } else {
                    day.formatted(.dateTime.month(.wide).day().year())
                }
            return BrowserHistoryGroup(id: day, title: title, entries: grouped[day] ?? [])
        }
    }

    static func metadata(for entry: BrowserHistoryEntry, group: BrowserHistoryGroup) -> String {
        let host = entry.url.host ?? entry.url.absoluteString
        let visit = entry.visitedAt.formatted(group.title == "Today" || group.title == "Yesterday"
            ? .dateTime.hour().minute()
            : .dateTime.month().day().hour().minute())
        return "\(host) · \(visit)"
    }
}
