//
//  BrowserViewInteractionTests.swift
//  MediaVault
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import ComposableArchitecture
import Foundation
import SwiftUI
import Testing
import UIKit
import WebKit
@testable import BrowserFeature

@Suite("Browser view interaction boundaries")
@MainActor
struct BrowserViewInteractionTests {
    @Test("Browsing a web tab mounts one interactive omnibox owner")
    func browsingWebTabMountsOneOmnibox() throws {
        let url = try #require(URL(string: "https://example.com"))
        let tab = BrowserTab.web(id: BrowserTabID(UUID(1)), url: url)
        let store = Store(initialState: BrowserFeature.State(tabs: [tab], selectedTabID: tab.id)) {
            BrowserFeature()
        }
        let hostingController = UIHostingController(rootView: BrowserView(store: store))
        let window = mount(hostingController, size: CGSize(width: 390, height: 844))

        #expect(descendants(of: hostingController.view, matching: UITextField.self).count == 1)

        window.isHidden = true
        window.rootViewController = nil
    }

    @Test("Browsing dismissal scope contains the page surface and Browser chrome")
    func browsingDismissalScopeContainsPageAndChrome() throws {
        let url = try #require(URL(string: "https://example.com"))
        let tab = BrowserTab.web(id: BrowserTabID(UUID(1)), url: url)
        let store = Store(initialState: BrowserFeature.State(tabs: [tab], selectedTabID: tab.id)) {
            BrowserFeature()
        }
        let hostingController = UIHostingController(rootView: BrowserView(store: store))
        let window = mount(hostingController, size: CGSize(width: 390, height: 844))

        let pageSurface = try #require(allViews(in: hostingController.view).compactMap { $0 as? WKWebView }.first)
        let chromeControl = try #require(allViews(in: hostingController.view).compactMap { $0 as? UIButton }.first)
        let dismissalRecognizer = try #require(
            browserDismissalRecognizers(in: hostingController.view).first,
        )

        #expect(browserDismissalRecognizers(in: hostingController.view).count == 1)
        #expect(dismissalRecognizer.view === hostingController.view)
        #expect(dismissalRecognizer.delaysTouchesBegan == false)
        #expect(dismissalRecognizer.delaysTouchesEnded == false)
        #expect(pageSurface.scrollView.keyboardDismissMode == .interactive)
        #expect(hostingController.view.bounds.contains(center(of: pageSurface, in: hostingController.view)))
        #expect(hostingController.view.bounds.contains(center(of: chromeControl, in: hostingController.view)))

        window.isHidden = true
        window.rootViewController = nil
    }

    @Test("Start Page native host receives interactive keyboard dismissal")
    func startPageNativeHostReceivesInteractiveDismissal() throws {
        let store = Store(initialState: BrowserFeature.State(initialTabID: BrowserTabID(UUID(1)))) {
            BrowserFeature()
        }
        let hostingController = UIHostingController(rootView: BrowserView(store: store))
        let window = mount(hostingController, size: CGSize(width: 390, height: 844))
        let textField = try #require(descendants(of: hostingController.view, matching: UITextField.self).first)

        #expect(
            descendants(of: hostingController.view, matching: UIScrollView.self)
                .contains(where: { $0.keyboardDismissMode == .interactive }),
        )
        #expect(
            browserDismissalRecognizers(in: hostingController.view).count == 1,
        )
        #expect(hostingController.view.bounds.contains(center(of: textField, in: hostingController.view)))

        window.isHidden = true
        window.rootViewController = nil
    }

    private func mount(_ controller: UIViewController, size: CGSize) -> UIWindow {
        let window = UIWindow(frame: CGRect(origin: .zero, size: size))
        window.rootViewController = controller
        window.makeKeyAndVisible()
        controller.view.frame = window.bounds
        controller.view.layoutIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
        return window
    }

    private func descendants<ViewType: UIView>(
        of view: UIView,
        matching _: ViewType.Type,
    ) -> [ViewType] {
        view.subviews.flatMap { subview in
            let matches = subview as? ViewType
            return (matches.map { [$0] } ?? []) + descendants(of: subview, matching: ViewType.self)
        }
    }

    private func browserDismissalRecognizers(in view: UIView) -> [UITapGestureRecognizer] {
        allViews(in: view)
            .flatMap { $0.gestureRecognizers ?? [] }
            .compactMap { $0 as? UITapGestureRecognizer }
            .filter { recognizer in
                !recognizer.cancelsTouchesInView
                    && String(describing: recognizer.delegate.map { type(of: $0) }).contains(
                        "BrowserPresentationTapCoordinator",
                    )
            }
    }

    private func allViews(in view: UIView) -> [UIView] {
        [view] + view.subviews.flatMap(allViews)
    }

    private func center(of view: UIView, in target: UIView) -> CGPoint {
        view.convert(
            CGPoint(x: view.bounds.midX, y: view.bounds.midY),
            to: target,
        )
    }
}
