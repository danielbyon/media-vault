//
//  BrowserDestructiveConfirmation.swift
//  MediaVault
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

/// Bulk destructive confirmation presented by the app-owned Browser UI.
enum BrowserDestructiveConfirmation: Equatable, Sendable {
    case clearHistory
    case deleteAllBookmarks(count: Int?)
    case closeAllTabs(count: Int)
    case closeOtherTabs(keeping: BrowserTabID, count: Int)
}
