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

/// UIKit bridge that mounts the selected adapter-owned WebKit surface.
@MainActor
@preconcurrency
public struct BrowserWebView: UIViewRepresentable {
    /// Stable logical identity of the surface to attach.
    public let tabID: BrowserTabID
    private let onRefresh: () -> Void
    private let transitionRegistry: BrowserTabTransitionSurfaceRegistry?

    /// Creates a bridge for an adapter-owned WebKit context.
    public init(tabID: BrowserTabID, onRefresh: @escaping () -> Void) {
        self.tabID = tabID
        self.onRefresh = onRefresh
        transitionRegistry = nil
    }

    /// Creates a Browser page surface that also registers its exact transition boundary.
    init(
        tabID: BrowserTabID,
        onRefresh: @escaping () -> Void,
        transitionRegistry: BrowserTabTransitionSurfaceRegistry,
    ) {
        self.tabID = tabID
        self.onRefresh = onRefresh
        self.transitionRegistry = transitionRegistry
    }

    /// Tracks which adapter surface is currently mounted in the UIKit container.
    @MainActor
    @preconcurrency
    public final class Coordinator: NSObject {
        var tabID: BrowserTabID?
        private var onRefresh: () -> Void
        let transitionRegistry: BrowserTabTransitionSurfaceRegistry?

        init(
            onRefresh: @escaping () -> Void,
            transitionRegistry: BrowserTabTransitionSurfaceRegistry?,
        ) {
            self.onRefresh = onRefresh
            self.transitionRegistry = transitionRegistry
        }

        func update(onRefresh: @escaping () -> Void) {
            self.onRefresh = onRefresh
        }

        func refresh() {
            onRefresh()
        }

        @objc
        func refreshControlValueChanged(_ sender: UIRefreshControl) {
            sender.endRefreshing()
            refresh()
        }
    }

    /// Creates bridge coordination state without retaining a WebKit object.
    public func makeCoordinator() -> Coordinator {
        Coordinator(onRefresh: onRefresh, transitionRegistry: transitionRegistry)
    }

    /// Creates the neutral UIKit container that receives the adapter-owned surface.
    public func makeUIView(context _: Context) -> UIView {
        UIView()
    }

    /// Attaches the requested stable tab and detaches any prior tab surface.
    public func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.update(onRefresh: onRefresh)
        if let previous = context.coordinator.tabID, previous != tabID {
            BrowserWebKitAdapter.shared.detach(tabID: previous, from: uiView)
            context.coordinator.transitionRegistry?.unregister(uiView, for: .content(previous))
        }
        context.coordinator.tabID = tabID
        let webView = BrowserWebKitAdapter.shared.ensureContext(for: tabID)
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
        BrowserWebKitAdapter.shared.attach(tabID: tabID, to: uiView)
        transitionRegistry?.register(uiView, for: .content(tabID))
    }

    /// Detaches the visual surface while leaving context lifetime under adapter control.
    public static func dismantleUIView(_ uiView: UIView, coordinator: Coordinator) {
        if let mountedTabID = coordinator.tabID {
            BrowserWebKitAdapter.shared.detach(tabID: mountedTabID, from: uiView)
            coordinator.transitionRegistry?.unregister(uiView, for: .content(mountedTabID))
        }
    }
}
