//
//  BrowserTabPresentation.swift
//  MediaVault
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

/// Shared presentation rules for a logical browser tab.
enum BrowserTabPresentation {
    /// Returns whether a web tab has a committed URL eligible for page-specific actions.
    static func canShowPageActions(for tab: BrowserTab) -> Bool {
        guard case .web = tab.content,
              let url = tab.metadata.committedURL
        else {
            return false
        }

        return BrowserNavigation.isHTTPURL(url)
    }

    /// Finds the bookmark represented by a tab's committed HTTP URL.
    static func bookmarkID(
        for tab: BrowserTab?,
        bookmarks: [BrowserBookmark],
    ) -> UUID? {
        guard case .web = tab?.content,
              let url = tab?.metadata.committedURL
        else {
            return nil
        }

        return bookmarks.first(where: { $0.url == url })?.id
    }

    /// Returns the user-facing title shared by browser chrome and Tab Overview.
    static func title(for tab: BrowserTab) -> String {
        guard !tab.isStartPage else {
            return "Start Page"
        }

        if let title = tab.metadata.title?.trimmingCharacters(in: .whitespacesAndNewlines),
           !title.isEmpty {
            return title
        }

        return tab.metadata.committedURL?.host ?? "Web Page"
    }
}
