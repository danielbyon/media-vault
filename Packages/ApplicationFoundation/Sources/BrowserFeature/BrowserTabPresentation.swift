//
//  BrowserTabPresentation.swift
//  MediaVault
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

/// Shared presentation rules for a logical browser tab.
enum BrowserTabPresentation {
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
        tab.isStartPage
            ? "Start Page"
            : (tab.metadata.title ?? tab.metadata.committedURL?.host ?? "Web Page")
    }
}
