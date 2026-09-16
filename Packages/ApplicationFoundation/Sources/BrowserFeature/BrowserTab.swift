//
//  BrowserTab.swift
//  MediaVault
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

/// Opaque stable identity for one logical browser tab.
///
/// The UUID backing this value is intentionally hidden from Browser clients. Keeping the wrapper
/// distinct from bookmark and History identifiers prevents those persistence identities from being
/// used accidentally at the live-tab and WebKit adapter boundary.
public struct BrowserTabID: Hashable, Sendable {
    let rawValue: UUID

    /// Creates an identity backed by a caller-supplied UUID.
    public init(_ rawValue: UUID) {
        self.rawValue = rawValue
    }

    /// Creates a new logical tab identity.
    public init() {
        rawValue = UUID()
    }
}

/// The browser surface currently replacing the normal page presentation.
public enum BrowserPresentation: Equatable, Sendable {
    /// Normal selected-tab browsing surface.
    case browsing
    /// App-owned overview of all logical tabs.
    case tabOverview
}

/// The app-owned address-field focus target.
public enum BrowserFocusedField: Equatable, Hashable, Sendable {
    /// No browser text field owns focus.
    case none
    /// The native Start Page field owns focus.
    case startPage
    /// The page chrome field owns focus.
    case chrome
}

/// Stable app-visible metadata for a logical browser tab.
public struct BrowserTab: Identifiable, Equatable, Sendable {
    /// Stable identity shared with the adapter registry.
    public let id: BrowserTabID
    /// App-visible tab content category.
    public var content: Content
    /// Stable identity of the tab that created this related tab.
    public var openerID: BrowserTabID?
    /// Whether public WebKit window creation produced this tab.
    public var isScriptCreated: Bool
    /// Sendable projection of current WebKit metadata.
    public var metadata: Metadata

    /// Creates a logical tab without retaining platform objects.
    public init(
        id: BrowserTabID,
        content: Content,
        openerID: BrowserTabID? = nil,
        isScriptCreated: Bool = false,
        metadata: Metadata = .init(),
    ) {
        self.id = id
        self.content = content
        self.openerID = openerID
        self.isScriptCreated = isScriptCreated
        self.metadata = metadata
    }

    /// Creates a native Start Page tab.
    public static func startPage(id: BrowserTabID) -> Self {
        Self(id: id, content: .startPage)
    }

    /// Creates a normal web tab.
    public static func web(id: BrowserTabID, url: URL, openerID: BrowserTabID? = nil) -> Self {
        Self(id: id, content: .web(requestedURL: url), openerID: openerID)
    }

    /// Creates a web tab that may honor a later script-close request.
    public static func scriptCreatedWeb(id: BrowserTabID, openerID: BrowserTabID, url: URL) -> Self {
        Self(id: id, content: .web(requestedURL: url), openerID: openerID, isScriptCreated: true)
    }

    /// Whether the tab currently presents native Start Page content.
    public var isStartPage: Bool {
        if case .startPage = content {
            true
        } else {
            false
        }
    }

    /// Whether WebKit reports a prior back-forward item.
    public var canGoBack: Bool {
        metadata.canGoBack
    }

    /// Logical content variants; none contain WebKit or UIKit objects.
    public enum Content: Equatable, Sendable {
        /// Native Start Page content outside WebKit history.
        case startPage
        /// Web content rooted at the requested destination.
        case web(requestedURL: URL)
        /// App-owned recoverable navigation failure UI.
        case error(BrowserNavigationError)
        /// A terminated content process that can be reloaded.
        case terminated(lastCommittedURL: URL?)
    }

    /// Framework-derived values needed to render browser chrome.
    public struct Metadata: Equatable, Sendable {
        /// Last URL committed by WebKit.
        public var committedURL: URL?
        /// Current page title reported by WebKit.
        public var title: String?
        /// Whether WebKit is loading.
        public var isLoading: Bool
        /// Current public WebKit estimated progress.
        public var estimatedProgress: Double
        /// Whether WebKit can navigate backward.
        public var canGoBack: Bool
        /// Whether WebKit can navigate forward.
        public var canGoForward: Bool
        /// Opportunistic audibility state when public API support is available.
        public var isAudible: Bool?

        /// Creates a Sendable metadata projection.
        public init(
            committedURL: URL? = nil,
            title: String? = nil,
            isLoading: Bool = false,
            estimatedProgress: Double = 0,
            canGoBack: Bool = false,
            canGoForward: Bool = false,
            isAudible: Bool? = nil,
        ) {
            self.committedURL = committedURL
            self.title = title
            self.isLoading = isLoading
            self.estimatedProgress = estimatedProgress
            self.canGoBack = canGoBack
            self.canGoForward = canGoForward
            self.isAudible = isAudible
        }
    }
}

/// Stable user-facing navigation failure categories.
public enum BrowserNavigationError: Equatable, Sendable {
    /// The device has no network connection.
    case noInternet(URL)
    /// DNS or host resolution failed.
    case serverNotFound(URL)
    /// A connection could not be established or was lost.
    case connectionFailed(URL)
    /// Navigation failed for another user-recoverable reason.
    case pageCouldNotLoad(URL)

    /// Destination associated with the failure.
    public var url: URL {
        switch self {
        case let .noInternet(url),
             let .serverNotFound(url),
             let .connectionFailed(url),
             let .pageCouldNotLoad(url):
            url
        }
    }
}
