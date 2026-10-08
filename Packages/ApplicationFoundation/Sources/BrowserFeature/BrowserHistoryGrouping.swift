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

/// The calendar, locale, and time zone one History presentation uses to render chronology.
///
/// A visit instant belongs to different calendar days depending on the time zone that interprets it,
/// so a History row and the section that contains it must be rendered from a single configuration.
/// Carrying the three values together keeps grouping and row metadata from disagreeing, and lets a
/// caller substitute fixed values wherever a rendering must not depend on the machine producing it.
/// A reader of the app receives that reader's own current settings. The initializer normalizes the
/// calendar to the supplied time zone and locale, so the three values always describe one chronology
/// even when a caller passes values that were assembled separately.
struct BrowserHistoryPresentationContext: Equatable, Sendable {
    /// The calendar that defines day boundaries.
    var calendar: Calendar

    /// The locale that selects date and time conventions.
    var locale: Locale

    /// The time zone that interprets visit instants.
    var timeZone: TimeZone

    /// Creates the formatting context for one History presentation.
    ///
    /// The calendar is normalized to the supplied time zone and locale. A caller that passes values
    /// that disagree, such as a UTC calendar with a Los Angeles time zone, still receives day
    /// boundaries and rendered dates that describe the same local day.
    ///
    /// - Parameters:
    ///   - calendar: The calendar that defines day boundaries, normalized to `timeZone` and `locale`.
    ///   - locale: The locale that selects date and time conventions.
    ///   - timeZone: The time zone that interprets visit instants.
    init(calendar: Calendar, locale: Locale, timeZone: TimeZone) {
        var calendar = calendar
        calendar.locale = locale
        calendar.timeZone = timeZone
        self.calendar = calendar
        self.locale = locale
        self.timeZone = timeZone
    }
}

/// Pure chronological projection for durable History rows supplied by Issue #39.
enum BrowserHistoryGrouping {
    /// Groups History entries into day sections for a presentation context.
    ///
    /// - Parameters:
    ///   - entries: The entries to group.
    ///   - referenceDate: The instant that decides which section is "Today".
    ///   - context: The calendar, locale, and time zone used to render the chronology.
    /// - Returns: Sections ordered newest first, each holding its entries ordered newest first.
    static func groups(
        _ entries: [BrowserHistoryEntry],
        referenceDate: Date,
        context: BrowserHistoryPresentationContext,
    ) -> [BrowserHistoryGroup] {
        let calendar = context.calendar
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
                    day.formatted(resolved(.dateTime.month(.wide).day().year(), in: context))
                }
            return BrowserHistoryGroup(id: day, title: title, entries: grouped[day] ?? [])
        }
    }

    /// The secondary label shown beneath a History row's title.
    ///
    /// - Parameters:
    ///   - entry: The entry whose address and visit time are rendered.
    ///   - group: The section that contains the entry, which selects the time format.
    ///   - context: The calendar, locale, and time zone used to render the visit time.
    /// - Returns: The entry's host followed by its visit time.
    static func metadata(
        for entry: BrowserHistoryEntry,
        group: BrowserHistoryGroup,
        context: BrowserHistoryPresentationContext,
    ) -> String {
        let host = entry.url.host ?? entry.url.absoluteString
        let style: Date.FormatStyle = group.title == "Today" || group.title == "Yesterday"
            ? .dateTime.hour().minute()
            : .dateTime.month().day().hour().minute()
        return "\(host) · \(entry.visitedAt.formatted(resolved(style, in: context)))"
    }

    /// Redirects a date format style to a presentation context.
    ///
    /// A style built from `.dateTime` resolves its locale, calendar, and time zone from process-wide
    /// settings, so a caller that needs a specific rendering has to write those values onto the
    /// style after construction. The requested symbols survive the redirection.
    ///
    /// - Parameters:
    ///   - style: The style whose symbols describe the rendering.
    ///   - context: The calendar, locale, and time zone the rendering uses.
    /// - Returns: A style that formats with the supplied configuration.
    private static func resolved(
        _ style: Date.FormatStyle,
        in context: BrowserHistoryPresentationContext,
    ) -> Date.FormatStyle {
        var resolvedStyle = style
        resolvedStyle.locale = context.locale
        resolvedStyle.calendar = context.calendar
        resolvedStyle.timeZone = context.timeZone
        return resolvedStyle
    }
}
