//
//  BrowserJavaScriptDialogPresentation.swift
//  MediaVault
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//

/// Action choices required by one JavaScript dialog type.
enum BrowserJavaScriptDialogAction: Equatable, Sendable {
    /// Dismisses a confirm or prompt without accepting it.
    case cancel
    /// Acknowledges an alert or accepts a confirm or prompt.
    case ok
}

/// Platform-independent semantic description used to build JavaScript dialog UI.
struct BrowserJavaScriptDialogPresentation: Equatable, Sendable {
    var actions: [BrowserJavaScriptDialogAction]
    var includesTextField: Bool

    /// JavaScript alert has one acknowledgement action and no cancellation action.
    static let alert = Self(actions: [.ok], includesTextField: false)
    /// JavaScript confirm has Cancel and OK actions.
    static let confirm = Self(actions: [.cancel, .ok], includesTextField: false)
    /// JavaScript prompt has text input plus Cancel and OK actions.
    static let prompt = Self(actions: [.cancel, .ok], includesTextField: true)
}
