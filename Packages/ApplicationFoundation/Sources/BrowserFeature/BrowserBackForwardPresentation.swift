//
//  BrowserBackForwardPresentation.swift
//  MediaVault
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//

/// Transient presentation of one projected side of WebKit's back-forward list.
struct BrowserBackForwardPresentation: Equatable, Sendable {
    var tabID: BrowserTabID
    var direction: BrowserNavigationDirection
    var entries: [BrowserBackForwardEntry]
}
