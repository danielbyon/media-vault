//
//  BrowserHistoryGroupingTests.swift
//  MediaVault
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import FoundationTestSupport
import Testing
@testable import BrowserFeature

@Suite("Browser History chronological presentation")
struct BrowserHistoryGroupingTests {
    // `Date.FormatStyle` separates a clock time from its day period with a narrow no-break space
    // (U+202F), so the expectations below spell that character out with an escape rather than an
    // ordinary space.

    /// Ten minutes before the shared reference date: 2024-08-30 06:30 UTC, which is the evening of
    /// 2024-08-29 in Los Angeles.
    private static let recentVisit = DeterministicTestSupport.referenceDate.addingTimeInterval(-600)

    /// Just under two days before the shared reference date: 2024-08-28 06:50 UTC, which is late on
    /// 2024-08-27 in Los Angeles.
    private static let olderVisit = DeterministicTestSupport.referenceDate.addingTimeInterval(-172_200)

    @Test("History groups Today, Yesterday, and calendar dates newest first")
    func chronologicalGrouping() throws {
        let context = try utcContext()
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

        let groups = BrowserHistoryGrouping.groups(entries, referenceDate: reference, context: context)

        #expect(groups.map(\.title).prefix(2) == ["Today", "Yesterday"])
        #expect(groups[0].entries.map(\.title) == ["Newest", "Today"])
        #expect(groups.count == 3)
    }

    @Test("History rows render visit times in the time zone they are given")
    func metadataUsesSuppliedTimeZone() throws {
        let entry = try historyEntry(visitedAt: Self.recentVisit)
        let losAngeles = try losAngelesContext()
        let utc = try utcContext()

        let losAngelesMetadata = try metadata(for: entry, in: losAngeles)
        let utcMetadata = try metadata(for: entry, in: utc)

        #expect(losAngelesMetadata == "history.example · 11:30\u{202F}PM")
        #expect(utcMetadata == "history.example · 6:30\u{202F}AM")
    }

    @Test("A section label and its row metadata always describe the same calendar day")
    func sectionLabelsAndRowMetadataAgree() throws {
        // The older visit sits one day before the reference date in UTC and two days before it in
        // Los Angeles. Grouping and row formatting read the same context, so two zones that
        // disagreed there would file the row under a label that contradicts the row's own date.
        let entry = try historyEntry(visitedAt: Self.olderVisit)
        let recentEntry = try historyEntry(visitedAt: Self.recentVisit)
        let entries = [recentEntry, entry]
        let losAngeles = try losAngelesContext()
        let utc = try utcContext()

        let losAngelesGroups = BrowserHistoryGrouping.groups(
            entries,
            referenceDate: DeterministicTestSupport.referenceDate,
            context: losAngeles,
        )
        let losAngelesGroup = try #require(losAngelesGroups.last)
        let losAngelesMetadata = BrowserHistoryGrouping.metadata(
            for: entry,
            group: losAngelesGroup,
            context: losAngeles,
        )

        #expect(losAngelesGroups.map(\.title) == ["Today", "August 27, 2024"])
        #expect(losAngelesMetadata == "history.example · Aug 27 at 11:50\u{202F}PM")

        let utcGroups = BrowserHistoryGrouping.groups(
            entries,
            referenceDate: DeterministicTestSupport.referenceDate,
            context: utc,
        )
        let utcGroup = try #require(utcGroups.last)
        let utcMetadata = BrowserHistoryGrouping.metadata(for: entry, group: utcGroup, context: utc)

        #expect(utcGroups.map(\.title) == ["Today", "August 28, 2024"])
        #expect(utcMetadata == "history.example · Aug 28 at 6:50\u{202F}AM")
    }

    @Test("The Library snapshot baseline renders from the shared reference context")
    func librarySnapshotBaselineContext() throws {
        // BrowserViewSnapshotTests injects these same fixed values before rendering the committed
        // library-history-regular-ipad image, which shows the History row as
        // "history.example · 11:30 PM". Pinning that string against the shared values keeps the
        // harness and the baseline in step, and the differing UTC rendering proves the string comes
        // from the injected time zone rather than from the machine running the test.
        let context = presentationContext(
            timeZone: DeterministicTestSupport.referenceTimeZone,
            locale: DeterministicTestSupport.referenceLocale,
            calendar: DeterministicTestSupport.referenceCalendar,
        )
        let entry = try historyEntry(visitedAt: Self.recentVisit)
        let utc = try utcContext()

        let baselineMetadata = try metadata(for: entry, in: context)
        let utcMetadata = try metadata(for: entry, in: utc)

        #expect(DeterministicTestSupport.referenceTimeZone.identifier == "America/Los_Angeles")
        #expect(baselineMetadata == "history.example · 11:30\u{202F}PM")
        #expect(utcMetadata != baselineMetadata)
    }

    @Test("A context with a mismatched calendar still labels sections and rows for the same day")
    func contextNormalizesCalendarToSuppliedTimeZone() throws {
        // A caller can assemble the two values independently: here a UTC calendar arrives alongside a
        // Los Angeles time zone. Without normalization the sections would be cut at UTC midnight and
        // carry a title for one day while the rows inside them printed another. The visit sits 30
        // minutes after the reference date, which is just past midnight in Los Angeles.
        var utcCalendar = Calendar(identifier: .gregorian)
        utcCalendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
        let losAngeles = try #require(TimeZone(identifier: "America/Los_Angeles"))
        let referenceDate = DeterministicTestSupport.referenceDate
        let context = presentationContext(
            timeZone: losAngeles,
            locale: DeterministicTestSupport.referenceLocale,
            calendar: utcCalendar,
        )
        let entry = try historyEntry(visitedAt: referenceDate.addingTimeInterval(1_800))

        let groups = BrowserHistoryGrouping.groups([entry], referenceDate: referenceDate, context: context)
        let group = try #require(groups.first)
        let metadata = BrowserHistoryGrouping.metadata(for: entry, group: group, context: context)

        #expect(context.calendar.timeZone == losAngeles)
        #expect(context.calendar.locale == DeterministicTestSupport.referenceLocale)
        #expect(group.title == "August 30, 2024")
        #expect(metadata == "history.example · Aug 30 at 12:10\u{202F}AM")
    }

    private func historyEntry(visitedAt: Date) throws -> BrowserHistoryEntry {
        let id = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000003"))
        let url = try #require(URL(string: "https://history.example/visited"))
        return BrowserHistoryEntry(id: id, title: "Visited Page", url: url, visitedAt: visitedAt)
    }

    private func metadata(
        for entry: BrowserHistoryEntry,
        in context: BrowserHistoryPresentationContext,
    ) throws -> String {
        let groups = BrowserHistoryGrouping.groups(
            [entry],
            referenceDate: DeterministicTestSupport.referenceDate,
            context: context,
        )
        let group = try #require(groups.first)
        return BrowserHistoryGrouping.metadata(for: entry, group: group, context: context)
    }

    private func losAngelesContext() throws -> BrowserHistoryPresentationContext {
        let timeZone = try #require(TimeZone(identifier: "America/Los_Angeles"))
        return presentationContext(timeZone: timeZone)
    }

    private func utcContext() throws -> BrowserHistoryPresentationContext {
        let timeZone = try #require(TimeZone(secondsFromGMT: 0))
        return presentationContext(timeZone: timeZone)
    }

    private func presentationContext(
        timeZone: TimeZone,
        locale: Locale = DeterministicTestSupport.referenceLocale,
        calendar: Calendar = Calendar(identifier: .gregorian),
    ) -> BrowserHistoryPresentationContext {
        BrowserHistoryPresentationContext(calendar: calendar, locale: locale, timeZone: timeZone)
    }
}
