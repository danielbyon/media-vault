//
//  BrowserWebKitClient.swift
//  MediaVault
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Dependencies
import Foundation

/// Correlates one reducer-issued navigation command with its delegate events.
public struct BrowserNavigationOperationID: Hashable, Sendable {
    private let rawValue: UUID

    /// Creates an identity that is unique to one requested WebKit operation.
    public init() {
        rawValue = UUID()
    }
}

/// Sendable commands accepted by the live main-actor WebKit adapter.
public enum BrowserWebKitCommand: Equatable, Sendable {
    /// Creates a live context if one does not already exist.
    case ensureContext(tabID: BrowserTabID)
    /// Destroys one live context and resolves its transient UI.
    case destroyContext(tabID: BrowserTabID)
    /// Loads a destination in a tab context correlated to one preview invalidation.
    case load(
        tabID: BrowserTabID,
        url: URL,
        operationID: BrowserNavigationOperationID,
    )
    /// Navigates to WebKit's previous item correlated to one preview invalidation.
    case goBack(tabID: BrowserTabID, operationID: BrowserNavigationOperationID)
    /// Navigates to WebKit's next item correlated to one preview invalidation.
    case goForward(tabID: BrowserTabID, operationID: BrowserNavigationOperationID)
    /// Reloads the current WebKit item correlated to one preview invalidation.
    case reload(tabID: BrowserTabID, operationID: BrowserNavigationOperationID)
    /// Stops the current WebKit load.
    case stop(tabID: BrowserTabID)
    /// Projects one side of WebKit's back-forward list.
    case showBackForwardList(tabID: BrowserTabID, direction: BrowserNavigationDirection)
    /// Runs public WebKit Find on Page.
    case find(tabID: BrowserTabID, query: String)
    /// Navigates to a projected back-forward entry by its adapter-scoped opaque token, correlated
    /// to one preview invalidation.
    case goToBackForwardEntry(
        tabID: BrowserTabID,
        token: BrowserBackForwardEntry.Token,
        operationID: BrowserNavigationOperationID,
    )
    /// Captures a preview tagged with the tab's current document revision.
    case capturePreview(tabID: BrowserTabID, revision: BrowserTabPreviewRevision)
    /// Resolves any JavaScript dialog owned by a tab.
    case dismissJavaScriptDialog(tabID: BrowserTabID)
}

/// Side of WebKit's authoritative back-forward list.
public enum BrowserNavigationDirection: Equatable, Sendable {
    /// Earlier navigation items.
    case back
    /// Later navigation items.
    case forward
}

/// App-owned actions exposed for a link's public WebKit context menu.
public enum BrowserLinkContextAction: Equatable, Sendable {
    /// Loads the link in the active logical tab.
    case open
    /// Creates a related logical tab according to Browser settings.
    case openInNewTab
    /// Copies the complete link URL to the system clipboard.
    case copyLink
    /// Presents the system share sheet for the link URL.
    case shareLink
}

/// Identifies whether a WebKit event belongs to a reducer-issued operation.
public enum BrowserWebKitEventCorrelation: Equatable, Sendable {
    /// The adapter could not associate the callback with a reducer-issued command.
    case untracked
    /// The callback belongs to this reducer-issued operation.
    case operation(BrowserNavigationOperationID)
}

extension BrowserWebKitEventCorrelation {
    /// Returns the reducer operation named by this event, when WebKit supplied one.
    var operationID: BrowserNavigationOperationID? {
        switch self {
        case .untracked:
            nil
        case let .operation(operationID):
            operationID
        }
    }
}

/// Sendable app-relevant events emitted by the live WebKit adapter.
public enum BrowserWebKitEvent: Equatable, Sendable {
    /// Reports a WebKit navigation that was not issued by the reducer and therefore supersedes any
    /// pending reducer operation for the same tab.
    case navigationStarted(tabID: BrowserTabID)
    /// Reports app-visible page metadata and its explicit correlation status.
    case metadata(
        tabID: BrowserTabID,
        metadata: BrowserTab.Metadata,
        correlation: BrowserWebKitEventCorrelation,
    )
    /// Reports a mapped recoverable navigation failure and its explicit correlation status.
    case navigationFailed(
        tabID: BrowserTabID,
        error: BrowserNavigationError,
        correlation: BrowserWebKitEventCorrelation,
    )
    /// Reports termination of one content process.
    case processTerminated(tabID: BrowserTabID)
    /// Reports a site-created window using stable values only.
    case siteCreatedTab(openerID: BrowserTabID, tabID: BrowserTabID, url: URL, foreground: Bool)
    /// Requests closure of a tab originally created by script.
    case scriptCloseRequested(tabID: BrowserTabID)
    /// Reports scoped JavaScript dialog visibility.
    case javaScriptDialogChanged(tabID: BrowserTabID, isPresented: Bool)
    /// Reports projected public back-forward entries.
    case backForwardEntries(
        tabID: BrowserTabID,
        direction: BrowserNavigationDirection,
        entries: [BrowserBackForwardEntry],
    )
    /// Reports disposable PNG preview bytes with the revision requested by the reducer.
    case preview(tabID: BrowserTabID, revision: BrowserTabPreviewRevision, pngData: Data?)
    /// Reports an app-owned action selected from a public WebKit link menu.
    case linkContextAction(
        tabID: BrowserTabID,
        action: BrowserLinkContextAction,
        url: URL,
    )
}

/// Opaque identity for one projected WebKit back-forward item.
public struct BrowserBackForwardEntry: Identifiable, Equatable, Sendable {
    /// Token type scoped by the adapter/context that created it.
    public struct Token: Hashable, Sendable {
        let rawValue: UUID

        init() {
            rawValue = UUID()
        }
    }

    let token: Token
    let title: String?
    let url: URL

    /// SwiftUI identity for the projected entry.
    public var id: Token {
        token
    }

    init(title: String?, url: URL) {
        self.init(token: .init(), title: title, url: url)
    }

    init(token: Token, title: String?, url: URL) {
        self.token = token
        self.title = title
        self.url = url
    }
}

/// Sendable reducer-facing dependency in front of the main-actor platform registry.
struct BrowserWebKitClient: Sendable {
    /// Executes one stable, Sendable adapter command.
    var execute: @Sendable (BrowserWebKitCommand) async -> Void
    /// Creates a stream of stable, Sendable adapter events.
    var events: @Sendable () async -> AsyncStream<BrowserWebKitEvent>

    /// Creates a reducer-facing WebKit client.
    @preconcurrency
    init(
        execute: @escaping @Sendable (BrowserWebKitCommand) async -> Void,
        events: @escaping @Sendable () async -> AsyncStream<BrowserWebKitEvent>,
    ) {
        self.execute = execute
        self.events = events
    }
}

extension BrowserWebKitClient: DependencyKey {
    /// Main-actor live adapter bridge.
    static let liveValue = Self(
        execute: { command in await BrowserWebKitAdapter.shared.execute(command) },
        events: { await BrowserWebKitAdapter.shared.makeEventStream() },
    )
    /// Deterministic no-op client used unless a test overrides it.
    static let testValue = Self(execute: { _ in }, events: { AsyncStream { $0.finish() } })
}

extension DependencyValues {
    /// Reducer-facing WebKit dependency.
    var browserWebKit: BrowserWebKitClient {
        get { self[BrowserWebKitClient.self] }
        set { self[BrowserWebKitClient.self] = newValue }
    }
}
