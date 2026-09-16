//
//  BrowserSuggestions.swift
//  MediaVault
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

/// Stable suggestion identity and routing payload.
enum BrowserSuggestionKind: Equatable, Sendable {
    case bookmark(UUID)
    case history(UUID)
    case provider(String)
    case search(provider: BrowserSearchProvider, query: String)
    case copiedLink(URL)
}

/// An app-owned suggestion row.
struct BrowserSuggestion: Identifiable, Equatable, Sendable {
    var id: String
    var title: String
    var subtitle: String?
    var kind: BrowserSuggestionKind
}

/// Pure local ranking, provider composition, and copied-link presentation helpers.
enum BrowserSuggestions {
    /// Returns bookmark then History matches using titles and hostnames only.
    ///
    /// URL paths, query strings, and fragments are deliberately excluded from omnibox matching.
    static func local(
        query: String,
        bookmarks: [BrowserBookmark],
        history: [BrowserHistoryEntry],
    ) -> [BrowserSuggestion] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else {
            return []
        }

        let bookmarkMatches = bookmarks.enumerated()
            .compactMap { offset, bookmark -> (Int, Int, BrowserSuggestion)? in
                let title = bookmark.title.lowercased()
                let host = bookmark.url.host?.lowercased() ?? ""
                guard title.contains(needle) || host.contains(needle) else {
                    return nil
                }

                let rank = title == needle || host == needle
                    ? 0
                    : (title.hasPrefix(needle) || host.hasPrefix(needle) ? 1 : 2)
                return (rank, offset, BrowserSuggestion(
                    id: "bookmark:\(bookmark.id)",
                    title: bookmark.title,
                    subtitle: bookmark.url.host,
                    kind: .bookmark(bookmark.id),
                ))
            }
            .sorted { ($0.0, $0.1) < ($1.0, $1.1) }
            .map(\.2)

        let bookmarkURLs = Set(bookmarks.map { normalizedIdentity($0.url) })
        let historyMatches = history.compactMap { entry -> BrowserSuggestion? in
            let title = entry.title.lowercased()
            let host = entry.url.host?.lowercased() ?? ""
            guard title.contains(needle) || host.contains(needle),
                  !bookmarkURLs.contains(normalizedIdentity(entry.url))
            else {
                return nil
            }

            return BrowserSuggestion(
                id: "history:\(entry.id)",
                title: entry.title,
                subtitle: entry.url.host,
                kind: .history(entry.id),
            )
        }
        return bookmarkMatches + historyMatches
    }

    /// Composes all suggestion tiers and always places explicit search last.
    static func complete(
        draft: String,
        provider: BrowserSearchProvider,
        bookmarks: [BrowserBookmark],
        history: [BrowserHistoryEntry],
        providerValues: [String],
    ) -> [BrowserSuggestion] {
        let query = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            return []
        }

        return local(query: query, bookmarks: bookmarks, history: history)
            + providerValues.map {
                BrowserSuggestion(id: "provider:\($0)", title: $0, subtitle: provider.displayName, kind: .provider($0))
            }
            + [BrowserSuggestion(
                id: "search:\(provider.rawValue):\(query)",
                title: "Search \(provider.displayName) for “\(query)”",
                subtitle: nil,
                kind: .search(provider: provider, query: query),
            )]
    }

    /// Preserves the bookmark seam's order for native Start Page tiles.
    static func startPageBookmarks(_ bookmarks: [BrowserBookmark]) -> [BrowserBookmark] {
        bookmarks
    }

    /// Produces a credential/query/fragment-free, bounded copied-link destination preview.
    static func copiedLinkPreview(_ url: URL, maximumLength: Int = 72) -> String {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.user = nil
        components?.password = nil
        components?.query = nil
        components?.fragment = nil
        let value = components?.string ?? (url.host ?? "Link")
        guard maximumLength > 1, value.count > maximumLength else {
            return String(value.prefix(max(0, maximumLength)))
        }

        return String(value.prefix(maximumLength - 1)) + "…"
    }

    private static func normalizedIdentity(_ url: URL) -> String {
        url.absoluteString.lowercased()
    }
}
