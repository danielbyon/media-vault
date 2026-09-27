//
//  BrowserWebKitReadinessCoordinator.swift
//  MediaVault
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import WebKit

/// Lifecycle state supplied by the current reducer transition.
@MainActor
struct BrowserWebKitReadinessContext: Equatable {
    /// Distinguishes successive reducer-issued navigation lifecycles while the same WebView stays
    /// mounted, so a pending probe cannot be reused for a newer operation.
    let navigationOperationID: BrowserNavigationOperationID?
    /// Prevents a pending reducer navigation from treating the previously committed document as
    /// presentation-ready until that operation has completed and its metadata has been consumed.
    var requiresFreshCommit: Bool {
        navigationOperationID != nil
    }

    init(navigationOperationID: BrowserNavigationOperationID? = nil) {
        self.navigationOperationID = navigationOperationID
    }
}

/// Owns the active WebKit probe and coordinates it with adapter identity and transition events.
@MainActor
final class BrowserWebKitReadinessCoordinator {
    private let adapter: BrowserWebKitAdapter
    private let automaticallyAdvancesDisplayTurns: Bool
    private var readinessProbe: BrowserWebKitReadinessProbe?
    private var readinessProbeGeneration = 0

    /// Creates a coordinator that uses display-link turns unless a deterministic test driver is requested.
    init(
        adapter: BrowserWebKitAdapter = .shared,
        automaticallyAdvancesDisplayTurns: Bool = true,
    ) {
        self.adapter = adapter
        self.automaticallyAdvancesDisplayTurns = automaticallyAdvancesDisplayTurns
    }

    func context(navigationOperationID: BrowserNavigationOperationID? = nil) -> BrowserWebKitReadinessContext {
        BrowserWebKitReadinessContext(navigationOperationID: navigationOperationID)
    }

    func invalidate() {
        readinessProbeGeneration &+= 1
        readinessProbe?.invalidate()
        readinessProbe = nil
    }

    /// Advances the active probe once when automatic display-link advancement is disabled.
    func advanceReadinessTurnForTesting() {
        guard !automaticallyAdvancesDisplayTurns else {
            return
        }

        readinessProbe?.advanceReadinessTurnForTesting()
    }

    private func ownsReadinessProbe(generation: Int) -> Bool {
        readinessProbeGeneration == generation && readinessProbe != nil
    }

    func resolve(
        _ readinessContext: BrowserWebKitReadinessContext?,
        for webView: WKWebView,
        tabID: BrowserTabID,
    ) -> BrowserWebKitReadinessContext? {
        guard let readinessContext,
              adapter.webView(for: tabID) === webView
        else {
            return nil
        }

        return readinessContext
    }

    func schedule(
        for webView: WKWebView,
        tabID: BrowserTabID,
        readinessContext: BrowserWebKitReadinessContext?,
        onResult: @escaping (BrowserWebKitReadinessResult) -> Void,
        onPresentationBlocked: @escaping () -> Void,
    ) {
        if readinessProbe?.matches(webView: webView, readinessContext: readinessContext) == true {
            return
        }

        readinessProbe?.invalidate()
        readinessProbeGeneration &+= 1
        let generation = readinessProbeGeneration
        let probe = BrowserWebKitReadinessProbe(
            webView: webView,
            readinessContext: readinessContext,
            automaticallyAdvancesDisplayTurns: automaticallyAdvancesDisplayTurns,
            isAdapterOwned: { [weak webView, adapter] in
                guard let webView else {
                    return false
                }

                return adapter.webView(for: tabID) === webView
            },
            hasCommittedDocument: { [weak webView, adapter] in
                guard let webView,
                      let adapterWebView = adapter.webView(for: tabID),
                      adapterWebView === webView
                else {
                    return false
                }

                return adapter.hasCommittedDocument(for: tabID)
            },
            onResult: { [weak self] result in
                guard let self,
                      ownsReadinessProbe(generation: generation)
                else {
                    return
                }

                readinessProbe = nil
                onResult(result)
            },
            onPresentationBlocked: { [weak self] in
                guard let self,
                      ownsReadinessProbe(generation: generation)
                else {
                    return
                }

                onPresentationBlocked()
            },
        )
        readinessProbe = probe
        probe.start()
    }
}
