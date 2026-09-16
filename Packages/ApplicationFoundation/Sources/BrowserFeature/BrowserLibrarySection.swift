//
//  BrowserLibrarySection.swift
//  MediaVault
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import ComposableArchitecture
import Foundation

/// A section exposed by the local Browser Library.
public enum BrowserLibrarySection: Equatable, Sendable {
    /// Saved bookmarks.
    case bookmarks
    /// Durable locally stored browsing History.
    case history
}

/// Source of the shared Clear History confirmation.
public enum BrowserClearHistorySource: Equatable, Sendable {
    /// Browser Library entry point.
    case library
    /// Authenticated Browser settings entry point.
    case settings
}

/// UI/domain seam value supplied by the durable bookmark store owned by Issue #39.
public struct BrowserBookmark: Identifiable, Equatable, Sendable {
    /// Stable bookmark identity retained across edits.
    public let id: UUID
    var title: String
    var url: URL
    var parentID: UUID?
    var siblingOrder: Int
    var faviconData: Data?

    init(id: UUID, title: String, url: URL, siblingOrder: Int, parentID: UUID? = nil, faviconData: Data? = nil) {
        self.id = id
        self.title = title
        self.url = url
        self.siblingOrder = siblingOrder
        self.parentID = parentID
        self.faviconData = faviconData
    }
}

/// UI/domain seam value supplied by the durable History store owned by Issue #39.
public struct BrowserHistoryEntry: Identifiable, Equatable, Sendable {
    /// Stable durable-History entry identity.
    public let id: UUID
    var title: String
    var url: URL
    var visitedAt: Date
}

/// State that exists only for one modal Browser Library presentation.
struct BrowserLibraryPresentation: Equatable, Sendable {
    var section: BrowserLibrarySection
    var bookmarkSearch: String
    var historySearch: String
    var bookmarkScrollPosition: UUID?
    var historyScrollPosition: UUID?
    var revealedBookmarkID: UUID?
    var referenceDate: Date

    init(
        section: BrowserLibrarySection,
        bookmarkSearch: String = "",
        historySearch: String = "",
        bookmarkScrollPosition: UUID? = nil,
        historyScrollPosition: UUID? = nil,
        revealedBookmarkID: UUID? = nil,
        referenceDate: Date = Date(timeIntervalSinceReferenceDate: 0),
    ) {
        self.section = section
        self.bookmarkSearch = bookmarkSearch
        self.historySearch = historySearch
        self.bookmarkScrollPosition = bookmarkScrollPosition
        self.historyScrollPosition = historyScrollPosition
        self.revealedBookmarkID = revealedBookmarkID
        self.referenceDate = referenceDate
    }
}

/// Transient add/edit form state. Issue #39 supplies durable storage through `BrowserLibraryClient`.
struct BrowserBookmarkEditor: Equatable, Sendable {
    var bookmarkID: UUID?
    var title: String
    var urlDraft: String
    var validationMessage: String?

    init(bookmarkID: UUID? = nil, title: String = "", urlDraft: String = "", validationMessage: String? = nil) {
        self.bookmarkID = bookmarkID
        self.title = title
        self.urlDraft = urlDraft
        self.validationMessage = validationMessage
    }
}

/// Injectable Issue #39 backing seam. These values are presentation models, not a storage schema.
struct BrowserLibraryClient: Sendable {
    var loadBookmarks: @Sendable () async throws -> [BrowserBookmark]
    var loadHistory: @Sendable () async throws -> [BrowserHistoryEntry]
    var saveBookmark: @Sendable (BrowserBookmark) async throws -> Void
    var deleteBookmark: @Sendable (UUID) async throws -> Void
    var deleteHistoryEntry: @Sendable (UUID) async throws -> Void
    var clearHistory: @Sendable () async throws -> Void
    var deleteAllBookmarks: @Sendable () async throws -> Void
}

extension BrowserLibraryClient: DependencyKey {
    static let liveValue = testValue
    static let testValue = Self(
        loadBookmarks: { [] },
        loadHistory: { [] },
        saveBookmark: { _ in },
        deleteBookmark: { _ in },
        deleteHistoryEntry: { _ in },
        clearHistory: {},
        deleteAllBookmarks: {},
    )
}

extension DependencyValues {
    /// Reducer-facing local Browser Library backing seam.
    var browserLibrary: BrowserLibraryClient {
        get { self[BrowserLibraryClient.self] }
        set { self[BrowserLibraryClient.self] = newValue }
    }
}

/// Local-only search used by the modal Browser Library.
enum BrowserLibrarySearch {
    static func bookmarks(_ values: [BrowserBookmark], query: String) -> [BrowserBookmark] {
        filter(values, query: query, title: \.title, url: \.url)
    }

    static func history(_ values: [BrowserHistoryEntry], query: String) -> [BrowserHistoryEntry] {
        filter(values, query: query, title: \.title, url: \.url)
    }

    private static func filter<Value>(
        _ values: [Value],
        query: String,
        title: KeyPath<Value, String>,
        url: KeyPath<Value, URL>,
    ) -> [Value] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else {
            return values
        }

        return values.filter {
            $0[keyPath: title].lowercased().contains(needle)
                || ($0[keyPath: url].host?.lowercased().contains(needle) == true)
                || $0[keyPath: url].absoluteString.lowercased().contains(needle)
        }
    }
}
