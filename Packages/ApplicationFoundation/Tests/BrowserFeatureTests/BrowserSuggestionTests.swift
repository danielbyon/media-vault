//
//  BrowserSuggestionTests.swift
//  MediaVault
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
@testable import BrowserFeature

private func suggestionTestURL(_ value: String) -> URL {
    guard let url = URL(string: value) else {
        preconditionFailure("Static browser-suggestion test URLs must be valid")
    }

    return url
}

@Suite("Browser suggestions and local library search")
struct BrowserSuggestionTests {
    private let bookmark = BrowserBookmark(
        id: UUID(1),
        title: "Private Example",
        url: suggestionTestURL("https://example.com/private?stored=query"),
        siblingOrder: 0,
    )
    private let history = BrowserHistoryEntry(
        id: UUID(2),
        title: "Example Visit",
        url: suggestionTestURL("https://example.com/history?secret=fragment"),
        visitedAt: Date(timeIntervalSince1970: 100),
    )

    @Test("Omnibox matches only title and hostname, case-insensitively")
    func narrowLocalMatching() {
        #expect(BrowserSuggestions.local(query: "PRIVATE", bookmarks: [bookmark], history: [history]).count == 1)
        #expect(BrowserSuggestions.local(query: "example.com", bookmarks: [bookmark], history: [history]).count == 2)
        #expect(BrowserSuggestions.local(query: "stored", bookmarks: [bookmark], history: [history]).isEmpty)
        #expect(BrowserSuggestions.local(query: "secret", bookmarks: [bookmark], history: [history]).isEmpty)
    }

    @Test("Bookmarks precede History and win exact-URL deduplication")
    func orderingAndDeduplication() {
        let duplicate = BrowserHistoryEntry(
            id: UUID(3),
            title: "Duplicate",
            url: bookmark.url,
            visitedAt: .distantFuture,
        )
        let suggestions = BrowserSuggestions.local(
            query: "example",
            bookmarks: [bookmark],
            history: [duplicate, history],
        )
        #expect(suggestions.map(\.kind) == [.bookmark(bookmark.id), .history(history.id)])
    }

    @Test("Provider results follow local results and the explicit search action is last")
    func completeOrdering() {
        let suggestions = BrowserSuggestions.complete(
            draft: "example",
            provider: .duckDuckGo,
            bookmarks: [bookmark],
            history: [history],
            providerValues: ["example privacy", "example photos"],
        )
        #expect(suggestions.map(\.kind) == [
            .bookmark(bookmark.id),
            .history(history.id),
            .provider("example privacy"),
            .provider("example photos"),
            .search(provider: .duckDuckGo, query: "example"),
        ])
    }

    @Test("Browser Library search is intentionally broader and entirely local")
    func librarySearch() {
        #expect(BrowserLibrarySearch.bookmarks([bookmark], query: "stored").map(\.id) == [bookmark.id])
        #expect(BrowserLibrarySearch.history([history], query: "secret").map(\.id) == [history.id])
    }

    @Test("Copied-link preview removes credentials and query fragments and truncates")
    func copiedLinkPreview() throws {
        let url =
            try #require(
                URL(
                    string: "https://person:password@example.com/a/very/long/private/destination/path?token=secret#section",
                ),
            )
        let preview = BrowserSuggestions.copiedLinkPreview(url, maximumLength: 32)
        #expect(!preview.contains("password"))
        #expect(!preview.contains("token"))
        #expect(!preview.contains("section"))
        #expect(preview.count <= 32)
        #expect(preview.hasSuffix("…"))
    }

    @Test("Start Page bookmark projection preserves seam ordering")
    func startPageOrdering() throws {
        let later = try BrowserBookmark(
            id: UUID(4),
            title: "Later",
            url: #require(URL(string: "https://later.example")),
            siblingOrder: 99,
        )
        #expect(BrowserSuggestions.startPageBookmarks([later, bookmark]).map(\.id) == [later.id, bookmark.id])
    }
}

extension UUID {
    fileprivate init(_ value: UInt8) {
        self.init(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, value, 0, 0))
    }
}
