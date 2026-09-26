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
    private let isProfileConfigurationReady: Bool
    private let refreshGestureArbitrator: BrowserRefreshGestureArbitrator?
    private let softwareKeyboardPresence: BrowserSoftwareKeyboardPresence?

    /// Creates a bridge for an adapter-owned WebKit context.
    public init(tabID: BrowserTabID, onRefresh: @escaping () -> Void) {
        self.tabID = tabID
        self.onRefresh = onRefresh
        adapter = .shared
        transitionRegistry = nil
        readinessContext = nil
        readinessCoordinator = .init(adapter: adapter)
        isProfileConfigurationReady = true
        refreshGestureArbitrator = nil
        softwareKeyboardPresence = nil
    }

    /// Creates a Browser page surface that also registers its exact transition boundary.
    init(
        tabID: BrowserTabID,
        onRefresh: @escaping () -> Void,
        transitionRegistry: BrowserTabTransitionSurfaceRegistry,
        adapter: BrowserWebKitAdapter = .shared,
        isProfileConfigurationReady: Bool = true,
        readinessContext: BrowserWebKitReadinessContext? = nil,
        readinessCoordinator: BrowserWebKitReadinessCoordinator? = nil,
        refreshGestureArbitrator: BrowserRefreshGestureArbitrator? = nil,
        softwareKeyboardPresence: BrowserSoftwareKeyboardPresence? = nil,
    ) {
        self.tabID = tabID
        self.onRefresh = onRefresh
        self.adapter = adapter
        self.transitionRegistry = transitionRegistry
        self.readinessContext = readinessContext
        self.readinessCoordinator = readinessCoordinator ?? .init(adapter: adapter)
        self.isProfileConfigurationReady = isProfileConfigurationReady
        self.refreshGestureArbitrator = refreshGestureArbitrator
        self.softwareKeyboardPresence = softwareKeyboardPresence
    }

    /// Tracks which adapter surface is currently mounted in the UIKit container.
    @MainActor
    @preconcurrency
    public final class Coordinator: NSObject {
        var tabID: BrowserTabID?
        private var onRefresh: () -> Void
        private var readinessContext: BrowserWebKitReadinessContext?
        private weak var refreshControl: UIRefreshControl?
        let transitionRegistry: BrowserTabTransitionSurfaceRegistry?
        private let readinessCoordinator: BrowserWebKitReadinessCoordinator
        let adapter: BrowserWebKitAdapter
        private var refreshGestureArbitrator: BrowserRefreshGestureArbitrator?
        private var softwareKeyboardPresence: BrowserSoftwareKeyboardPresence?
        private var refreshSurfaceTabID: BrowserTabID?
        private(set) var refreshSurfaceID: BrowserRefreshSurfaceID?
        private var isInteractiveDismissalEnabled = false
        private weak var observedPanGestureRecognizer: UIPanGestureRecognizer?

        init(
            onRefresh: @escaping () -> Void,
            transitionRegistry: BrowserTabTransitionSurfaceRegistry?,
            readinessCoordinator: BrowserWebKitReadinessCoordinator? = nil,
            adapter: BrowserWebKitAdapter = .shared,
            refreshGestureArbitrator: BrowserRefreshGestureArbitrator? = nil,
            softwareKeyboardPresence: BrowserSoftwareKeyboardPresence? = nil,
        ) {
            self.onRefresh = onRefresh
            self.transitionRegistry = transitionRegistry
            self.adapter = adapter
            self.readinessCoordinator = readinessCoordinator ?? .init(adapter: adapter)
            self.refreshGestureArbitrator = refreshGestureArbitrator
            self.softwareKeyboardPresence = softwareKeyboardPresence
        }

        func update(onRefresh: @escaping () -> Void) {
            self.onRefresh = onRefresh
        }

        func refresh() {
            onRefresh()
        }

        /// Assigns a new surface identity when the mounted tab or Browser owner changes.
        func updateRefreshSurface(
            tabID: BrowserTabID,
            arbitrator: BrowserRefreshGestureArbitrator?,
            keyboardPresence: BrowserSoftwareKeyboardPresence?,
            isInteractiveDismissalEnabled: Bool,
        ) {
            let surfaceOwnerChanged = refreshSurfaceTabID != tabID
                || refreshGestureArbitrator !== arbitrator
            if surfaceOwnerChanged {
                unmountRefreshSurface()
                refreshGestureArbitrator = arbitrator
                softwareKeyboardPresence = keyboardPresence
                refreshSurfaceTabID = tabID
                if let arbitrator {
                    let surfaceID = BrowserRefreshSurfaceID()
                    refreshSurfaceID = surfaceID
                    arbitrator.mount(surfaceID)
                }
            } else {
                softwareKeyboardPresence = keyboardPresence
            }
            self.isInteractiveDismissalEnabled = isInteractiveDismissalEnabled
        }

        /// Observes WebKit's existing pan recognizer without taking ownership of its delegate.
        func observePanGesture(_ recognizer: UIPanGestureRecognizer) {
            guard observedPanGestureRecognizer !== recognizer else {
                return
            }

            unobservePanGesture()
            recognizer.addTarget(self, action: #selector(scrollPanStateChanged(_:)))
            observedPanGestureRecognizer = recognizer
        }

        func unobservePanGesture() {
            if let observedPanGestureRecognizer {
                observedPanGestureRecognizer.removeTarget(self, action: #selector(scrollPanStateChanged(_:)))
            }
            observedPanGestureRecognizer = nil
        }

        func unmountRefreshSurface() {
            if let refreshSurfaceID {
                refreshGestureArbitrator?.unmount(refreshSurfaceID)
            }
            refreshSurfaceID = nil
            refreshSurfaceTabID = nil
        }

        private func inputAtGestureStart() -> BrowserRefreshGestureInput {
            .init(
                isInteractiveDismissalEnabled: isInteractiveDismissalEnabled,
                isSoftwareKeyboardPresent: softwareKeyboardPresence?.isPresent == true,
            )
        }

        private func receivePanState(
            _ panState: BrowserRefreshWebKitPanState,
            sampleGestureInput: Bool,
        ) {
            guard let refreshGestureArbitrator, let refreshSurfaceID else {
                return
            }

            let input = sampleGestureInput
                ? inputAtGestureStart()
                : .init(isInteractiveDismissalEnabled: false, isSoftwareKeyboardPresent: false)
            refreshGestureArbitrator.receiveWebKitPanState(panState, on: refreshSurfaceID, input: input)
        }

        private func shouldDispatchRefresh() -> Bool {
            guard let refreshGestureArbitrator else {
                return true
            }
            guard let refreshSurfaceID else {
                return false
            }

            return refreshGestureArbitrator.consumeRefresh(on: refreshSurfaceID)
        }

        /// Replaces any Browser refresh action with one bound to this coordinator.
        func bindRefreshControl(_ refreshControl: UIRefreshControl) {
            if self.refreshControl !== refreshControl {
                unbindRefreshControl()
            }

            let action = #selector(Coordinator.refreshControlValueChanged(_:))
            refreshControl.removeTarget(nil, action: action, for: .valueChanged)
            refreshControl.addTarget(self, action: action, for: .valueChanged)
            self.refreshControl = refreshControl
        }

        /// Removes this coordinator's action and ends refreshing only while it owns the control.
        func unbindRefreshControl() {
            guard let refreshControl else {
                return
            }

            let action = #selector(Coordinator.refreshControlValueChanged(_:))
            let ownsRefreshAction = refreshControl.actions(
                forTarget: self,
                forControlEvent: .valueChanged,
            )?.contains(NSStringFromSelector(action)) == true

            refreshControl.removeTarget(
                self,
                action: action,
                for: .valueChanged,
            )
            if ownsRefreshAction {
                refreshControl.endRefreshing()
            }
            self.refreshControl = nil
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
            guard shouldDispatchRefresh() else {
                return
            }

            refresh()
        }

        @objc
        private func scrollPanStateChanged(_ recognizer: UIPanGestureRecognizer) {
            receivePanGestureState(recognizer.state)
        }

        /// Applies UIKit pan lifecycle states through the same sampling boundary as the installed target.
        func receivePanGestureState(_ state: UIGestureRecognizer.State) {
            let panState = BrowserRefreshWebKitPanState(gestureRecognizerState: state)
            receivePanState(panState, sampleGestureInput: panState == .began)
        }
    }

    /// Creates bridge coordination state without retaining a WebKit object.
    public func makeCoordinator() -> Coordinator {
        Coordinator(
            onRefresh: onRefresh,
            transitionRegistry: transitionRegistry,
            readinessCoordinator: readinessCoordinator,
            adapter: adapter,
            refreshGestureArbitrator: refreshGestureArbitrator,
            softwareKeyboardPresence: softwareKeyboardPresence,
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
        context.coordinator.updateRefreshSurface(
            tabID: tabID,
            arbitrator: refreshGestureArbitrator,
            keyboardPresence: softwareKeyboardPresence,
            isInteractiveDismissalEnabled: context.environment.scrollDismissesKeyboardMode == .interactively,
        )
        let webKitAdapter = context.coordinator.adapter
        if let previous = context.coordinator.tabID, previous != tabID {
            context.coordinator.unobservePanGesture()
            context.coordinator.unbindRefreshControl()
            let previousWebView = webKitAdapter.webView(for: previous)
            webKitAdapter.detach(tabID: previous, from: uiView)
            if let previousWebView {
                context.coordinator.transitionRegistry?.unregister(previousWebView, for: .content(previous))
            }
            context.coordinator.invalidateReadinessProbe()
        }
        context.coordinator.tabID = tabID
        guard isProfileConfigurationReady else {
            context.coordinator.invalidateReadinessProbe()
            return
        }
        guard let webView = webKitAdapter.ensureActiveContext(for: tabID) else {
            context.coordinator.invalidateReadinessProbe()
            return
        }

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
            webView.scrollView.refreshControl = refreshControl
        }
        if let refreshControl = webView.scrollView.refreshControl {
            context.coordinator.bindRefreshControl(refreshControl)
        }
        context.coordinator.observePanGesture(webView.scrollView.panGestureRecognizer)
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
        coordinator.unobservePanGesture()
        coordinator.unbindRefreshControl()
        coordinator.unmountRefreshSurface()
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
