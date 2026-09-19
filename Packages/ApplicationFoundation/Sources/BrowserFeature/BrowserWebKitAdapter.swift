//
//  BrowserWebKitAdapter.swift
//  MediaVault
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import UIKit
import WebKit

/// Main-actor registry that exclusively owns live WebKit contexts keyed by logical tab IDs.
@MainActor
final class BrowserWebKitAdapter: NSObject {
    static let shared = BrowserWebKitAdapter()

    private var contexts: [BrowserTabID: Context] = [:]
    private var continuations: [UUID: AsyncStream<BrowserWebKitEvent>.Continuation] = [:]
    private var popupOpenersThisTurn: Set<BrowserTabID> = []
    private let makeTabID: () -> BrowserTabID
    private let snapshotter: @MainActor (
        WKWebView,
        WKSnapshotConfiguration?,
        @escaping @Sendable (UIImage?, Error?) -> Void,
    ) -> Void

    init(
        makeTabID: @escaping () -> BrowserTabID = BrowserTabID.init,
        snapshotter: @escaping @MainActor (
            WKWebView,
            WKSnapshotConfiguration?,
            @escaping @Sendable (UIImage?, Error?) -> Void,
        ) -> Void = { webView, configuration, completion in
            webView.takeSnapshot(with: configuration, completionHandler: completion)
        },
    ) {
        self.makeTabID = makeTabID
        self.snapshotter = snapshotter
    }

    var contextCount: Int {
        contexts.count
    }

    func hasContext(for tabID: BrowserTabID) -> Bool {
        contexts[tabID] != nil
    }

    /// Creates a context even for an unselected background tab and returns an existing one unchanged.
    @discardableResult
    func ensureContext(for tabID: BrowserTabID) -> WKWebView {
        if let context = contexts[tabID] {
            return context.webView
        }
        return createContext(tabID: tabID, configuration: configured(WKWebViewConfiguration())).webView
    }

    /// Resolves tab-owned modal UI and releases the tab's platform context.
    func destroyContext(for tabID: BrowserTabID) {
        guard let context = contexts.removeValue(forKey: tabID) else {
            return
        }

        context.resolvePendingDialog()
        context.adapter = nil
        context.webView.stopLoading()
        context.webView.navigationDelegate = nil
        context.webView.uiDelegate = nil
        context.webView.removeFromSuperview()
    }

    /// Attaches the registry-owned surface without transferring its ownership to reducer state.
    func attach(tabID: BrowserTabID, to container: UIView) {
        let webView = ensureContext(for: tabID)
        guard webView.superview !== container else {
            return
        }

        webView.removeFromSuperview()
        webView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            webView.topAnchor.constraint(equalTo: container.topAnchor),
            webView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
    }

    /// Detaches only the visual surface; background loading remains adapter-owned.
    func detach(tabID: BrowserTabID, from container: UIView) {
        if contexts[tabID]?.webView.superview === container {
            contexts[tabID]?.webView.removeFromSuperview()
        }
    }

    /// Executes a reducer command containing only stable identity and Sendable values.
    func execute(_ command: BrowserWebKitCommand) {
        switch command {
        case let .ensureContext(id):
            _ = ensureContext(for: id)
        case let .destroyContext(id):
            destroyContext(for: id)
        case let .load(id, url):
            let context = ensureContextObject(for: id)
            context.invalidateBackForwardTokens()
            context.webView.load(URLRequest(url: url))
        case let .goBack(id):
            contexts[id]?.goBack()
        case let .goForward(id):
            contexts[id]?.goForward()
        case let .reload(id):
            contexts[id]?.reload()
        case let .stop(id):
            contexts[id]?.webView.stopLoading()
        case let .showBackForwardList(id, direction):
            guard let context = contexts[id] else {
                return
            }

            emit(.backForwardEntries(
                tabID: id,
                direction: direction,
                entries: context.projectedBackForwardEntries(direction),
            ))
        case let .find(id, query):
            contexts[id]?.webView.find(query) { _ in }
        case let .goToBackForwardEntry(id, token):
            contexts[id]?.goToBackForwardEntry(token)
        case let .capturePreview(id, revision):
            guard let webView = contexts[id]?.webView else {
                emit(.preview(tabID: id, revision: revision, pngData: nil))
                return
            }

            snapshotter(webView, nil) { [weak self] image, _ in
                MainActor.assumeIsolated {
                    self?.emit(.preview(
                        tabID: id,
                        revision: revision,
                        pngData: image?.pngData(),
                    ))
                }
            }
        case let .dismissJavaScriptDialog(id):
            contexts[id]?.resolvePendingDialog()
        }
    }

    func makeEventStream() -> AsyncStream<BrowserWebKitEvent> {
        let streamID = UUID()
        return AsyncStream { continuation in
            continuations[streamID] = continuation
            continuation.onTermination = { @Sendable [weak self] _ in
                Task { @MainActor in self?.continuations.removeValue(forKey: streamID) }
            }
        }
    }

    /// Ignores replacement-navigation cancellation and maps genuine failures to stable categories.
    static func navigationError(_ error: Error, failingURL: URL) -> BrowserNavigationError? {
        let code = (error as NSError).code
        guard code != NSURLErrorCancelled else {
            return nil
        }

        switch code {
        case NSURLErrorNotConnectedToInternet:
            return .noInternet(failingURL)
        case NSURLErrorCannotFindHost,
             NSURLErrorDNSLookupFailed:
            return .serverNotFound(failingURL)
        case NSURLErrorCannotConnectToHost,
             NSURLErrorNetworkConnectionLost:
            return .connectionFailed(failingURL)
        default:
            return .pageCouldNotLoad(failingURL)
        }
    }

    fileprivate func emit(_ event: BrowserWebKitEvent) {
        for continuation in continuations.values {
            continuation.yield(event)
        }
    }

    func makePopup(openerID: BrowserTabID, configuration: WKWebViewConfiguration, url: URL?) -> WKWebView {
        let tabID = makeTabID()
        let context = createContext(tabID: tabID, configuration: configured(configuration))
        let foreground = popupOpenersThisTurn.insert(openerID).inserted
        if foreground {
            DispatchQueue.main.async { [weak self] in self?.popupOpenersThisTurn.remove(openerID) }
        }
        guard let destination = url ?? URL(string: "about:blank") else {
            preconditionFailure("WebKit's about:blank URL must be representable")
        }

        emit(.siteCreatedTab(
            openerID: openerID,
            tabID: tabID,
            url: destination,
            foreground: foreground,
        ))
        return context.webView
    }

    private func ensureContextObject(for tabID: BrowserTabID) -> Context {
        if let context = contexts[tabID] {
            return context
        }

        return createContext(tabID: tabID, configuration: configured(WKWebViewConfiguration()))
    }

    private func createContext(tabID: BrowserTabID, configuration: WKWebViewConfiguration) -> Context {
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.allowsBackForwardNavigationGestures = true
        let context = Context(tabID: tabID, webView: webView, adapter: self)
        webView.navigationDelegate = context
        webView.uiDelegate = context
        contexts[tabID] = context
        return context
    }

    private func configured(_ configuration: WKWebViewConfiguration) -> WKWebViewConfiguration {
        configuration.allowsPictureInPictureMediaPlayback = false
        configuration.allowsAirPlayForMediaPlayback = false
        return configuration
    }
}

/// Adapter-private token registry for projected WebKit back-forward items.
@MainActor
final class BrowserBackForwardTokenRegistry<Item: AnyObject> {
    private var items: [BrowserBackForwardEntry.Token: Item] = [:]

    func rebuild(_ newItems: [Item]) -> [BrowserBackForwardEntry.Token] {
        items.removeAll(keepingCapacity: true)
        return newItems.map { item in
            let token = BrowserBackForwardEntry.Token()
            items[token] = item
            return token
        }
    }

    func resolve(_ token: BrowserBackForwardEntry.Token) -> Item? {
        items[token]
    }

    func invalidate() {
        items.removeAll(keepingCapacity: true)
    }
}

/// Adapter-private availability model for the public WebKit link context menu.
enum BrowserWebKitLinkContextMenu {
    static let actions: [BrowserLinkContextAction] = [
        .open,
        .openInNewTab,
        .copyLink,
        .shareLink,
    ]

    static func actions(for linkURL: URL?) -> [BrowserLinkContextAction] {
        linkURL == nil ? [] : actions
    }
}

/// Projects the URL of WebKit's authoritative current history item into app-visible metadata.
///
/// `WKWebView.url` can change for same-document navigation and provisional loads. The history
/// item's URL is the public WebKit source that distinguishes committed navigation from a failed
/// provisional destination.
struct BrowserWebKitCommittedURLProjection: Equatable, Sendable {
    private(set) var committedURL: URL?

    init(committedURL: URL? = nil) {
        self.committedURL = committedURL
    }

    mutating func update(authoritativeCurrentItemURL: URL?) {
        guard let authoritativeCurrentItemURL else {
            return
        }

        committedURL = authoritativeCurrentItemURL
    }
}

@MainActor
private final class Context: NSObject, WKNavigationDelegate, WKUIDelegate {
    let tabID: BrowserTabID
    let webView: WKWebView
    weak var adapter: BrowserWebKitAdapter?
    private var pendingDialogResolution: (() -> Void)?
    private var observations: [NSKeyValueObservation] = []
    private var committedURLProjection = BrowserWebKitCommittedURLProjection()
    private let backForwardTokens = BrowserBackForwardTokenRegistry<WKBackForwardListItem>()

    init(tabID: BrowserTabID, webView: WKWebView, adapter: BrowserWebKitAdapter) {
        self.tabID = tabID
        self.webView = webView
        self.adapter = adapter
        super.init()
        observations = [
            webView.observe(\.isLoading, options: [.initial, .new]) { [weak self] _, _ in
                Task { @MainActor in self?.emitMetadata() }
            },
            webView.observe(\.estimatedProgress, options: [.new]) { [weak self] _, _ in
                Task { @MainActor in self?.emitMetadata() }
            },
            webView.observe(\.canGoBack, options: [.new]) { [weak self] _, _ in
                Task { @MainActor in self?.emitMetadata() }
            },
            webView.observe(\.canGoForward, options: [.new]) { [weak self] _, _ in
                Task { @MainActor in self?.emitMetadata() }
            },
            webView.observe(\.title, options: [.new]) { [weak self] _, _ in
                Task { @MainActor in self?.emitMetadata() }
            },
            webView.observe(\.url, options: [.new]) { [weak self] _, _ in
                Task { @MainActor in self?.emitMetadata() }
            },
        ]
    }

    func projectedBackForwardEntries(_ direction: BrowserNavigationDirection) -> [BrowserBackForwardEntry] {
        let items = direction == .back ? webView.backForwardList.backList : webView.backForwardList.forwardList
        let tokens = backForwardTokens.rebuild(items)
        return zip(tokens, items).map { token, item in
            BrowserBackForwardEntry(token: token, title: item.title, url: item.url)
        }
    }

    func goToBackForwardEntry(_ token: BrowserBackForwardEntry.Token) {
        guard let item = backForwardTokens.resolve(token) else {
            return
        }

        backForwardTokens.invalidate()
        webView.go(to: item)
    }

    func invalidateBackForwardTokens() {
        backForwardTokens.invalidate()
    }

    func goBack() {
        invalidateBackForwardTokens()
        webView.goBack()
    }

    func goForward() {
        invalidateBackForwardTokens()
        webView.goForward()
    }

    func reload() {
        invalidateBackForwardTokens()
        webView.reload()
    }

    func webView(_ webView: WKWebView, didCommit _: WKNavigation?) {
        backForwardTokens.invalidate()
        committedURLProjection.update(authoritativeCurrentItemURL: webView.backForwardList.currentItem?.url)
        emitMetadata()
    }

    func webView(_: WKWebView, didFinish _: WKNavigation?) {
        backForwardTokens.invalidate()
        emitMetadata()
    }

    func webView(_: WKWebView, didFail _: WKNavigation?, withError error: Error) {
        emit(error)
    }

    func webView(_: WKWebView, didFailProvisionalNavigation _: WKNavigation?, withError error: Error) {
        emit(error)
    }

    func webViewWebContentProcessDidTerminate(_: WKWebView) {
        adapter?.emit(.processTerminated(tabID: tabID))
    }

    func webView(
        _: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures _: WKWindowFeatures,
    ) -> WKWebView? {
        adapter?.makePopup(openerID: tabID, configuration: configuration, url: navigationAction.request.url)
    }

    func webView(
        _: WKWebView,
        contextMenuConfigurationForElement elementInfo: WKContextMenuElementInfo,
        completionHandler: @MainActor (UIContextMenuConfiguration?) -> Void,
    ) {
        guard let url = elementInfo.linkURL else {
            // Returning nil preserves WebKit's native editing and non-link context menus.
            completionHandler(nil)
            return
        }

        let actions = BrowserWebKitLinkContextMenu.actions(for: url)

        let configuration = UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            UIMenu(title: "", children: actions.compactMap { self?.linkAction($0, url: url) })
        }
        completionHandler(configuration)
    }

    private func linkAction(_ action: BrowserLinkContextAction, url: URL) -> UIAction {
        let title =
            switch action {
            case .open:
                "Open"
            case .openInNewTab:
                "Open in New Tab"
            case .copyLink:
                "Copy Link"
            case .shareLink:
                "Share Link"
            }

        return UIAction(title: title) { [weak self] _ in
            guard let self else {
                return
            }

            adapter?.emit(.linkContextAction(tabID: tabID, action: action, url: url))
        }
    }

    func webViewDidClose(_: WKWebView) {
        adapter?.emit(.scriptCloseRequested(tabID: tabID))
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptAlertPanelWithMessage message: String,
        initiatedByFrame _: WKFrameInfo,
        completionHandler: @escaping @MainActor () -> Void,
    ) {
        present(
            .alert,
            title: webView.url?.host,
            message: message,
        ) { _ in completionHandler() }
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptConfirmPanelWithMessage message: String,
        initiatedByFrame _: WKFrameInfo,
        completionHandler: @escaping @MainActor (Bool) -> Void,
    ) {
        present(
            .confirm,
            title: webView.url?.host,
            message: message,
        ) { action in completionHandler(action == .ok) }
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptTextInputPanelWithPrompt prompt: String,
        defaultText: String?,
        initiatedByFrame _: WKFrameInfo,
        completionHandler: @escaping @MainActor (String?) -> Void,
    ) {
        guard let presenter = webView.window?.rootViewController else {
            completionHandler(nil)
            return
        }

        let alert = UIAlertController(title: webView.url?.host, message: prompt, preferredStyle: .alert)
        alert.addTextField { $0.text = defaultText }
        pendingDialogResolution = { [weak alert] in alert?.dismiss(animated: false)
            completionHandler(nil)
        }
        for action in BrowserJavaScriptDialogPresentation.prompt.actions {
            switch action {
            case .cancel:
                alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { [weak self] _ in
                    self?.finish { completionHandler(nil) }
                })
            case .ok:
                alert.addAction(UIAlertAction(title: "OK", style: .default) { [weak self, weak alert] _ in
                    self?.finish { completionHandler(alert?.textFields?.first?.text) }
                })
            }
        }
        adapter?.emit(.javaScriptDialogChanged(tabID: tabID, isPresented: true))
        presenter.present(alert, animated: true)
    }

    func resolvePendingDialog() {
        pendingDialogResolution?()
        pendingDialogResolution = nil
    }

    private func present(
        _ presentation: BrowserJavaScriptDialogPresentation,
        title: String?,
        message: String,
        completion: @escaping @MainActor (BrowserJavaScriptDialogAction) -> Void,
    ) {
        let fallbackAction = presentation.actions.contains(.cancel) ? BrowserJavaScriptDialogAction.cancel : .ok
        guard let presenter = webView.window?.rootViewController else {
            completion(fallbackAction)
            return
        }

        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        pendingDialogResolution = { [weak alert] in alert?.dismiss(animated: false)
            completion(fallbackAction)
        }
        for action in presentation.actions {
            let actionTitle = action == .cancel ? "Cancel" : "OK"
            let style: UIAlertAction.Style = action == .cancel ? .cancel : .default
            alert.addAction(UIAlertAction(title: actionTitle, style: style) { [weak self] _ in
                self?.finish { completion(action) }
            })
        }
        adapter?.emit(.javaScriptDialogChanged(tabID: tabID, isPresented: true))
        presenter.present(alert, animated: true)
    }

    private func finish(_ completion: () -> Void) {
        pendingDialogResolution = nil
        completion()
        adapter?.emit(.javaScriptDialogChanged(tabID: tabID, isPresented: false))
    }

    private func emitMetadata() {
        synchronizeCommittedURL()
        adapter?.emit(.metadata(tabID: tabID, .init(
            committedURL: committedURLProjection.committedURL,
            title: webView.title,
            isLoading: webView.isLoading,
            estimatedProgress: webView.estimatedProgress,
            canGoBack: webView.canGoBack,
            canGoForward: webView.canGoForward,
        )))
    }

    private func synchronizeCommittedURL() {
        let previousURL = committedURLProjection.committedURL
        committedURLProjection.update(authoritativeCurrentItemURL: webView.backForwardList.currentItem?.url)
        if committedURLProjection.committedURL != previousURL {
            backForwardTokens.invalidate()
        }
    }

    private func emit(_ error: Error) {
        let url = (error as NSError).userInfo[NSURLErrorFailingURLErrorKey] as? URL ?? webView.url
        guard let url, let mapped = BrowserWebKitAdapter.navigationError(error, failingURL: url) else {
            return
        }

        adapter?.emit(.navigationFailed(tabID: tabID, mapped))
    }
}
