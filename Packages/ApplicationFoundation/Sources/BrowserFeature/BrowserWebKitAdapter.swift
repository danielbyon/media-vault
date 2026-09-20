//
//  BrowserWebKitAdapter.swift
//  MediaVault
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import UIKit
import WebKit

/// Internal observation seam for proving WebKit surface ownership without production logging.
enum BrowserWebKitAttachmentEvent: Equatable {
    case attached(BrowserTabID)
    case detached(BrowserTabID)
}

/// Main-actor registry that exclusively owns live WebKit contexts keyed by logical tab IDs.
@MainActor
final class BrowserWebKitAdapter: NSObject {
    static let shared = BrowserWebKitAdapter()

    private var contexts: [BrowserTabID: Context] = [:]
    private var continuations: [UUID: AsyncStream<BrowserWebKitEvent>.Continuation] = [:]
    private var popupOpenersThisTurn: Set<BrowserTabID> = []
    private let makeTabID: () -> BrowserTabID
    private let makeWebView: @MainActor (CGRect, WKWebViewConfiguration) -> WKWebView
    private let snapshotter: @MainActor (
        WKWebView,
        WKSnapshotConfiguration?,
        @escaping @Sendable (UIImage?, Error?) -> Void,
    ) -> Void

    /// Test-only observation seam for actual adapter attachment operations.
    var attachmentObserver: ((BrowserWebKitAttachmentEvent) -> Void)?

    init(
        makeTabID: @escaping () -> BrowserTabID = BrowserTabID.init,
        makeWebView: @escaping @MainActor (CGRect, WKWebViewConfiguration) -> WKWebView = {
            frame,
            configuration in WKWebView(frame: frame, configuration: configuration)
        },
        snapshotter: @escaping @MainActor (
            WKWebView,
            WKSnapshotConfiguration?,
            @escaping @Sendable (UIImage?, Error?) -> Void,
        ) -> Void = { webView, configuration, completion in
            webView.takeSnapshot(with: configuration, completionHandler: completion)
        },
    ) {
        self.makeTabID = makeTabID
        self.makeWebView = makeWebView
        self.snapshotter = snapshotter
    }

    var contextCount: Int {
        contexts.count
    }

    func hasContext(for tabID: BrowserTabID) -> Bool {
        contexts[tabID] != nil
    }

    /// Returns an existing live surface without creating a new WebKit context.
    func webView(for tabID: BrowserTabID) -> WKWebView? {
        contexts[tabID]?.webView
    }

    /// Reports whether the adapter-owned context has committed its current document.
    func hasCommittedDocument(for tabID: BrowserTabID) -> Bool {
        contexts[tabID]?.hasCommittedDocument == true
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
        attachmentObserver?(.attached(tabID))
    }

    /// Detaches only the visual surface; background loading remains adapter-owned.
    func detach(tabID: BrowserTabID, from container: UIView) {
        if contexts[tabID]?.webView.superview === container {
            contexts[tabID]?.webView.removeFromSuperview()
            attachmentObserver?(.detached(tabID))
        }
    }

    /// Executes a reducer command containing only stable identity and Sendable values.
    func execute(_ command: BrowserWebKitCommand) {
        switch command {
        case let .ensureContext(id):
            _ = ensureContext(for: id)
        case let .destroyContext(id):
            destroyContext(for: id)
        case let .load(id, url, operationID):
            let context = ensureContextObject(for: id)
            context.load(url, operationID: operationID)
        case let .goBack(id, operationID):
            contexts[id]?.goBack(operationID: operationID)
        case let .goForward(id, operationID):
            contexts[id]?.goForward(operationID: operationID)
        case let .reload(id, operationID):
            contexts[id]?.reload(operationID: operationID)
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
        case let .goToBackForwardEntry(id, token, operationID):
            contexts[id]?.goToBackForwardEntry(token, operationID: operationID)
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
        let webView = makeWebView(.zero, configuration)
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

private final class BrowserWebKitNavigationReference {
    weak var value: WKNavigation?

    init(_ value: WKNavigation) {
        self.value = value
    }
}

/// Keeps one WebKit context's reducer-operation identity and delegate-navigation lifecycle together.
///
/// WebKit may deliver callbacks for an older navigation after a newer command has been issued, and
/// some history commands complete without returning a `WKNavigation` at all. Keeping those cases
/// in one tracker makes the accepted-current-navigation rule explicit at every delegate boundary.
@MainActor
private struct BrowserWebKitNavigationCorrelation {
    struct Completion {
        let operationID: BrowserNavigationOperationID?
    }

    private(set) var hasCommittedDocument = false
    private var wasCommittedBeforeNavigation = false
    private var activeNavigationIdentifier: ObjectIdentifier?
    private var isAwaitingNavigationRegistration = false
    private var operationIDs: [ObjectIdentifier: BrowserNavigationOperationID] = [:]
    private var activeNavigationReference: BrowserWebKitNavigationReference?
    private var supersededNavigations: [BrowserWebKitNavigationReference] = []
    private(set) var generation = 0

    private mutating func pruneSupersededNavigations() {
        supersededNavigations.removeAll { $0.value == nil }
    }

    private mutating func rememberSupersededNavigation(_ navigation: WKNavigation?) {
        pruneSupersededNavigations()
        guard let navigation else {
            return
        }

        supersededNavigations.append(.init(navigation))
    }

    mutating func beginNavigation() {
        rememberSupersededNavigation(activeNavigationReference?.value)
        wasCommittedBeforeNavigation = hasCommittedDocument
        hasCommittedDocument = false
        activeNavigationIdentifier = nil
        activeNavigationReference = nil
        isAwaitingNavigationRegistration = true
        operationIDs.removeAll(keepingCapacity: true)
        generation &+= 1
    }

    /// Registers the navigation returned by a command. Returns `false` for a synchronous no-op.
    mutating func register(
        _ navigation: WKNavigation?,
        operationID: BrowserNavigationOperationID,
    ) -> Bool {
        isAwaitingNavigationRegistration = false
        generation &+= 1
        guard let navigation else {
            hasCommittedDocument = wasCommittedBeforeNavigation
            return false
        }

        let navigationIdentifier = ObjectIdentifier(navigation)
        discardSupersededNavigation(navigation)
        activeNavigationIdentifier = navigationIdentifier
        activeNavigationReference = .init(navigation)
        operationIDs[navigationIdentifier] = operationID
        return true
    }

    /// Accepts an unregistered navigation created outside the reducer command path.
    mutating func acceptExternalNavigation(_ navigation: WKNavigation?) -> Bool {
        guard let navigation else {
            return false
        }

        let navigationIdentifier = ObjectIdentifier(navigation)
        pruneSupersededNavigations()
        guard !isAwaitingNavigationRegistration,
              !supersededNavigations.contains(where: { $0.value === navigation }),
              operationIDs[navigationIdentifier] == nil,
              activeNavigationIdentifier != navigationIdentifier
        else {
            return false
        }

        hasCommittedDocument = false
        operationIDs.removeAll(keepingCapacity: true)
        activeNavigationIdentifier = navigationIdentifier
        activeNavigationReference = .init(navigation)
        generation &+= 1
        return true
    }

    func isCurrent(_ navigation: WKNavigation?) -> Bool {
        guard let navigation, let activeNavigationIdentifier else {
            return false
        }

        return ObjectIdentifier(navigation) == activeNavigationIdentifier
    }

    mutating func commit(_ navigation: WKNavigation?) -> Bool {
        guard isCurrent(navigation) else {
            return false
        }

        hasCommittedDocument = true
        return true
    }

    mutating func finish(_ navigation: WKNavigation?) -> Completion? {
        guard isCurrent(navigation) else {
            return nil
        }

        hasCommittedDocument = true
        return Completion(operationID: consumeOperationID(for: navigation))
    }

    func operationID(for navigation: WKNavigation?) -> BrowserNavigationOperationID? {
        guard let navigation else {
            return nil
        }

        return operationIDs[ObjectIdentifier(navigation)]
    }

    /// Returns the operation whose navigation is currently supplying KVO metadata.
    ///
    /// KVO does not carry a `WKNavigation`, but metadata emitted after a correlated commit still
    /// belongs to that operation until its delegate finish callback consumes the identity.
    func currentOperationID() -> BrowserNavigationOperationID? {
        guard let activeNavigationIdentifier else {
            return nil
        }

        return operationIDs[activeNavigationIdentifier]
    }

    mutating func consumeOperationID(for navigation: WKNavigation?) -> BrowserNavigationOperationID? {
        guard let navigation else {
            return nil
        }
        guard let operationID = operationIDs.removeValue(forKey: ObjectIdentifier(navigation)) else {
            return nil
        }

        generation &+= 1
        return operationID
    }

    mutating func discardSupersededNavigation(_ navigation: WKNavigation?) {
        guard let navigation else {
            return
        }

        supersededNavigations.removeAll { $0.value === navigation || $0.value == nil }
    }

    mutating func processTerminated() {
        hasCommittedDocument = false
        isAwaitingNavigationRegistration = false
        activeNavigationIdentifier = nil
        operationIDs.removeAll(keepingCapacity: true)
        activeNavigationReference = nil
        supersededNavigations.removeAll(keepingCapacity: true)
        generation &+= 1
    }
}

@MainActor
private final class Context: NSObject, WKNavigationDelegate, WKUIDelegate {
    let tabID: BrowserTabID
    let webView: WKWebView
    weak var adapter: BrowserWebKitAdapter?
    var hasCommittedDocument: Bool {
        navigationCorrelation.hasCommittedDocument
    }

    private var pendingDialogResolution: (() -> Void)?
    private var observations: [NSKeyValueObservation] = []
    private var navigationCorrelation = BrowserWebKitNavigationCorrelation()
    private var committedURLProjection = BrowserWebKitCommittedURLProjection()
    private let backForwardTokens = BrowserBackForwardTokenRegistry<WKBackForwardListItem>()

    init(tabID: BrowserTabID, webView: WKWebView, adapter: BrowserWebKitAdapter) {
        self.tabID = tabID
        self.webView = webView
        self.adapter = adapter
        super.init()
        observations = [
            webView.observe(\.isLoading, options: [.initial, .new]) { [weak self] _, _ in
                self?.scheduleMetadataEmission()
            },
            webView.observe(\.estimatedProgress, options: [.new]) { [weak self] _, _ in
                self?.scheduleMetadataEmission()
            },
            webView.observe(\.canGoBack, options: [.new]) { [weak self] _, _ in
                self?.scheduleMetadataEmission()
            },
            webView.observe(\.canGoForward, options: [.new]) { [weak self] _, _ in
                self?.scheduleMetadataEmission()
            },
            webView.observe(\.title, options: [.new]) { [weak self] _, _ in
                self?.scheduleMetadataEmission()
            },
            webView.observe(\.url, options: [.new]) { [weak self] _, _ in
                self?.scheduleMetadataEmission()
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

    func load(_ url: URL, operationID: BrowserNavigationOperationID) {
        navigationCorrelation.beginNavigation()
        invalidateBackForwardTokens()
        let navigation = webView.load(URLRequest(url: url))
        register(navigation, operationID: operationID)
    }

    func goToBackForwardEntry(
        _ token: BrowserBackForwardEntry.Token,
        operationID: BrowserNavigationOperationID,
    ) {
        guard let item = backForwardTokens.resolve(token) else {
            navigationCorrelation.beginNavigation()
            register(nil, operationID: operationID)
            return
        }

        backForwardTokens.invalidate()
        navigationCorrelation.beginNavigation()
        register(webView.go(to: item), operationID: operationID)
    }

    func invalidateBackForwardTokens() {
        backForwardTokens.invalidate()
    }

    func goBack(operationID: BrowserNavigationOperationID) {
        navigationCorrelation.beginNavigation()
        invalidateBackForwardTokens()
        register(webView.goBack(), operationID: operationID)
    }

    func goForward(operationID: BrowserNavigationOperationID) {
        navigationCorrelation.beginNavigation()
        invalidateBackForwardTokens()
        register(webView.goForward(), operationID: operationID)
    }

    func reload(operationID: BrowserNavigationOperationID) {
        navigationCorrelation.beginNavigation()
        invalidateBackForwardTokens()
        register(webView.reload(), operationID: operationID)
    }

    func webView(_: WKWebView, didStartProvisionalNavigation navigation: WKNavigation?) {
        // A command registers its WKNavigation immediately after issuing the WebKit call. The
        // correlation tracker rejects callbacks from that registration window and from known or
        // stale navigations before an external page can supersede the pending operation.
        guard navigationCorrelation.acceptExternalNavigation(navigation) else {
            navigationCorrelation.discardSupersededNavigation(navigation)
            return
        }

        adapter?.emit(.navigationStarted(tabID: tabID))
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation?) {
        guard navigationCorrelation.commit(navigation) else {
            navigationCorrelation.discardSupersededNavigation(navigation)
            return
        }

        backForwardTokens.invalidate()
        committedURLProjection.update(authoritativeCurrentItemURL: webView.backForwardList.currentItem?.url)
        // The committed projection is updated here for adapter-owned history and readiness state.
        // Reducer metadata is emitted once, from didFinish, so one navigation has one logical
        // invalidation/completion path instead of a commit observation plus a second completion.
    }

    func webView(_: WKWebView, didFinish navigation: WKNavigation?) {
        guard let completion = navigationCorrelation.finish(navigation) else {
            navigationCorrelation.discardSupersededNavigation(navigation)
            _ = navigationCorrelation.consumeOperationID(for: navigation)
            return
        }

        backForwardTokens.invalidate()
        emitMetadata(operationID: completion.operationID)
    }

    func webView(_: WKWebView, didFail navigation: WKNavigation?, withError error: Error) {
        guard navigationCorrelation.isCurrent(navigation) else {
            navigationCorrelation.discardSupersededNavigation(navigation)
            _ = navigationCorrelation.consumeOperationID(for: navigation)
            return
        }

        emit(error, navigation: navigation)
    }

    func webView(
        _: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation?,
        withError error: Error,
    ) {
        guard navigationCorrelation.isCurrent(navigation) else {
            navigationCorrelation.discardSupersededNavigation(navigation)
            _ = navigationCorrelation.consumeOperationID(for: navigation)
            return
        }

        emit(error, navigation: navigation)
    }

    func webViewWebContentProcessDidTerminate(_: WKWebView) {
        navigationCorrelation.processTerminated()
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

    private func scheduleMetadataEmission() {
        let generation = navigationCorrelation.generation
        let operationID = navigationCorrelation.currentOperationID()
        Task { @MainActor [weak self] in
            guard let self,
                  navigationCorrelation.generation == generation
            else {
                return
            }

            emitMetadata(operationID: operationID)
        }
    }

    private func emitMetadata(operationID: BrowserNavigationOperationID? = nil) {
        synchronizeCommittedURL()
        let metadata = BrowserTab.Metadata(
            committedURL: committedURLProjection.committedURL,
            title: webView.title,
            isLoading: webView.isLoading,
            estimatedProgress: webView.estimatedProgress,
            canGoBack: webView.canGoBack,
            canGoForward: webView.canGoForward,
        )
        let correlation: BrowserWebKitEventCorrelation = operationID.map { .operation($0) }
            ?? .untracked
        adapter?.emit(.metadata(
            tabID: tabID,
            metadata: metadata,
            correlation: correlation,
        ))
    }

    private func synchronizeCommittedURL() {
        let previousURL = committedURLProjection.committedURL
        committedURLProjection.update(authoritativeCurrentItemURL: webView.backForwardList.currentItem?.url)
        if committedURLProjection.committedURL != previousURL {
            backForwardTokens.invalidate()
        }
    }

    private func emit(_ error: Error, navigation: WKNavigation?) {
        let url = (error as NSError).userInfo[NSURLErrorFailingURLErrorKey] as? URL ?? webView.url
        let operationID = navigationCorrelation.operationID(for: navigation)
        guard let url, let mapped = BrowserWebKitAdapter.navigationError(error, failingURL: url) else {
            // WebKit reports user cancellation as an unmapped navigation error. It still must
            // complete the reducer-issued operation or the preview lifecycle remains pending.
            emitMetadata(operationID: operationID)
            _ = navigationCorrelation.consumeOperationID(for: navigation)
            return
        }

        let correlation: BrowserWebKitEventCorrelation = operationID
            .map { .operation($0) }
            ?? .untracked
        adapter?.emit(.navigationFailed(
            tabID: tabID,
            error: mapped,
            correlation: correlation,
        ))
        _ = navigationCorrelation.consumeOperationID(for: navigation)
    }

    private func register(
        _ navigation: WKNavigation?,
        operationID: BrowserNavigationOperationID,
    ) {
        if !navigationCorrelation.register(navigation, operationID: operationID) {
            // History can change between the reducer reading its metadata and this command
            // reaching WebKit. A synchronous no-op still completes with the command identity.
            emitMetadata(operationID: operationID)
        }
    }
}
