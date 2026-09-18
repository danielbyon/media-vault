//
//  BrowserNewTabDisposition.swift
//  MediaVault
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

/// The presentation selected for an explicitly created related browser tab.
public enum BrowserNewTabDisposition: Equatable, Sendable {
    /// Create the related tab without changing the selected tab.
    case background
    /// Create the related tab and select it immediately.
    case foreground
}

/// The stable values retained while the native new-tab choice is presented.
struct BrowserNewTabRequest: Equatable, Sendable {
    let url: URL
    let openerID: BrowserTabID?
}
