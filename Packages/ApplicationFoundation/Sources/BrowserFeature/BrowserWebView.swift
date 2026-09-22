//
//  BrowserWebView.swift
//  MediaVault
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import PresentationSupport
import SwiftUI
import UIKit
import WebKit

/// UIKit bridge that mounts the selected adapter-owned WebKit surface.
@MainActor
@preconcurrency
public struct BrowserWebView: UIViewRepresentable {
    /// Stable logical identity of the surface to attach.
    public let tabID: BrowserTabID
    private let onRefresh: () -> Void
    private let adapter: BrowserWebKitAdapter
    private let transitionRegistry: BrowserTabTransitionSurfaceRegistry?
    private let readinessContext: BrowserWebKitReadinessContext?
    private let readinessCoordinator: BrowserWebKitReadinessCoordinator

    /// Creates a bridge for an adapter-owned WebKit context.
    public init(tabID: BrowserTabID, onRefresh: @escaping () -> Void) {
        self.tabID = tabID
        self.onRefresh = onRefresh
        adapter = .shared
        transitionRegistry = nil
        readinessContext = nil
        readinessCoordinator = .init(adapter: adapter)
    }

    /// Creates a Browser page surface that also registers its exact transition boundary.
    init(
        tabID: BrowserTabID,
        onRefresh: @escaping () -> Void,
        transitionRegistry: BrowserTabTransitionSurfaceRegistry,
        adapter: BrowserWebKitAdapter = .shared,
        readinessContext: BrowserWebKitReadinessContext? = nil,
        readinessCoordinator: BrowserWebKitReadinessCoordinator? = nil,
    ) {
        self.tabID = tabID
        self.onRefresh = onRefresh
        self.adapter = adapter
        self.transitionRegistry = transitionRegistry
        self.readinessContext = readinessContext
        self.readinessCoordinator = readinessCoordinator ?? .init(adapter: adapter)
    }

    /// Tracks which adapter surface is currently mounted in the UIKit container.
    @MainActor
    @preconcurrency
    public final class Coordinator: NSObject {
        var tabID: BrowserTabID?
        private var onRefresh: () -> Void
        private var readinessContext: BrowserWebKitReadinessContext?
        let transitionRegistry: BrowserTabTransitionSurfaceRegistry?
        private let readinessCoordinator: BrowserWebKitReadinessCoordinator
        let adapter: BrowserWebKitAdapter

        init(
            onRefresh: @escaping () -> Void,
            transitionRegistry: BrowserTabTransitionSurfaceRegistry?,
            readinessCoordinator: BrowserWebKitReadinessCoordinator? = nil,
            adapter: BrowserWebKitAdapter = .shared,
        ) {
            self.onRefresh = onRefresh
            self.transitionRegistry = transitionRegistry
            self.adapter = adapter
            self.readinessCoordinator = readinessCoordinator ?? .init(adapter: adapter)
        }

        func update(onRefresh: @escaping () -> Void) {
            self.onRefresh = onRefresh
        }

        func refresh() {
            onRefresh()
        }

        func invalidateReadinessProbe() {
            readinessCoordinator.invalidate()
        }

        func updateReadinessContext(_ readinessContext: BrowserWebKitReadinessContext?) -> Bool {
            guard self.readinessContext != readinessContext else {
                return false
            }

            self.readinessContext = readinessContext
            return true
        }

        func resolveReadinessContext(
            _ readinessContext: BrowserWebKitReadinessContext?,
            for webView: WKWebView,
            tabID: BrowserTabID,
        ) -> BrowserWebKitReadinessContext? {
            readinessCoordinator.resolve(
                readinessContext,
                for: webView,
                tabID: tabID,
            )
        }

        func scheduleReadinessProbe(
            for webView: WKWebView,
            tabID: BrowserTabID,
            readinessContext: BrowserWebKitReadinessContext? = nil,
        ) {
            guard let transitionRegistry,
                  !transitionRegistry.isReady(for: .content(tabID))
            else {
                return
            }

            readinessCoordinator.schedule(
                for: webView,
                tabID: tabID,
                readinessContext: readinessContext,
                onResult: { [weak transitionRegistry, weak webView] result in
                    guard let transitionRegistry, let webView else {
                        return
                    }

                    switch result {
                    case .unavailable:
                        transitionRegistry.report(.targetPresentationUnavailable(tabID))
                    case .ready:
                        transitionRegistry.markReady(webView, for: .content(tabID))
                        transitionRegistry.report(.targetPresentationReady(tabID))
                    }
                },
                onPresentationBlocked: { [weak transitionRegistry, weak webView] in
                    guard let transitionRegistry, let webView else {
                        return
                    }

                    transitionRegistry.setReadiness(
                        .pending,
                        view: webView,
                        for: .content(tabID),
                    )
                    transitionRegistry.report(.targetPresentationBlocked(tabID))
                },
            )
        }

        @objc
        func refreshControlValueChanged(_ sender: UIRefreshControl) {
            sender.endRefreshing()
            refresh()
        }
    }

    /// Creates bridge coordination state without retaining a WebKit object.
    public func makeCoordinator() -> Coordinator {
        Coordinator(
            onRefresh: onRefresh,
            transitionRegistry: transitionRegistry,
            readinessCoordinator: readinessCoordinator,
            adapter: adapter,
        )
    }

    /// Creates the neutral UIKit container that receives the adapter-owned surface.
    public func makeUIView(context _: Context) -> UIView {
        UIView()
    }

    /// Attaches the requested stable tab and detaches any prior tab surface.
    public func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.update(
            onRefresh: onRefresh,
        )
        let webKitAdapter = context.coordinator.adapter
        if let previous = context.coordinator.tabID, previous != tabID {
            let previousWebView = webKitAdapter.webView(for: previous)
            webKitAdapter.detach(tabID: previous, from: uiView)
            if let previousWebView {
                context.coordinator.transitionRegistry?.unregister(previousWebView, for: .content(previous))
            }
            context.coordinator.invalidateReadinessProbe()
        }
        context.coordinator.tabID = tabID
        let webView = webKitAdapter.ensureContext(for: tabID)
        let resolvedReadinessContext = context.coordinator.resolveReadinessContext(
            readinessContext,
            for: webView,
            tabID: tabID,
        )
        if context.coordinator.updateReadinessContext(resolvedReadinessContext) {
            context.coordinator.transitionRegistry?.resetReadiness(
                webView,
                for: .content(tabID),
            )
        }
        KeyboardDismissalSupport.setInteractiveDismissal(
            context.environment.scrollDismissesKeyboardMode == .interactively,
            on: webView.scrollView,
        )
        if webView.scrollView.refreshControl == nil {
            let refreshControl = UIRefreshControl()
            refreshControl.addTarget(
                context.coordinator,
                action: #selector(Coordinator.refreshControlValueChanged(_:)),
                for: .valueChanged,
            )
            webView.scrollView.refreshControl = refreshControl
        }
        webKitAdapter.attach(tabID: tabID, to: uiView)
        transitionRegistry?.report(.targetAttached(tabID))
        transitionRegistry?.register(
            webView,
            for: .content(tabID),
            representation: .live,
            isReady: false,
        )
        context.coordinator.scheduleReadinessProbe(
            for: webView,
            tabID: tabID,
            readinessContext: resolvedReadinessContext,
        )
    }

    /// Detaches the visual surface while leaving context lifetime under adapter control.
    public static func dismantleUIView(_ uiView: UIView, coordinator: Coordinator) {
        if let mountedTabID = coordinator.tabID {
            let webView = coordinator.adapter.webView(for: mountedTabID)
            coordinator.invalidateReadinessProbe()
            coordinator.adapter.detach(tabID: mountedTabID, from: uiView)
            if let webView {
                coordinator.transitionRegistry?.unregister(webView, for: .content(mountedTabID))
            }
        }
    }
}
