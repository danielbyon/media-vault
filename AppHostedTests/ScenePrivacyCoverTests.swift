//
//  ScenePrivacyCoverTests.swift
//  MediaVault
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//

//
// ScenePrivacyCoverTests.swift
// MediaVault
//
// SPDX-License-Identifier: GPL-3.0-or-later
//
import CoreFoundation
import CoreGraphics
import Foundation
import Observation
import SwiftUI
import Testing
import UIKit
import UIUtilities
@testable import PresentationSupport

extension AppHostedUITests {
    @Suite("Scene privacy cover", .serialized)
    @MainActor
    struct ScenePrivacyCoverTests {
        private static let primaryDecoyAccessibilityIdentifier =
            "MediaVault.ScenePrivacyCoverPrimaryContent"
        private static let calculatorDisplayAccessibilityIdentifier =
            "MediaVault.ScenePrivacyCoverCalculatorDisplay"
        private static let calculatorKeyAccessibilityIdentifierPrefix =
            "MediaVault.ScenePrivacyCoverCalculatorKey."
        private static let expectedCalculatorGlyphs = [
            "⌫",
            "AC",
            "%",
            "÷",
            "7",
            "8",
            "9",
            "×",
            "4",
            "5",
            "6",
            "−",
            "1",
            "2",
            "3",
            "+",
            "0",
            "±",
            ".",
            "=",
        ]

        @Test("A covered scene receives a transparent interaction and accessibility barrier")
        func coveredSceneInstallsSceneBoundBarrier() throws {
            let host = try makeHost(isCovered: false)
            defer { unmount(host) }

            let coverWindow = try awaitPrivacyCoverWindow(in: host)
            expectPrivacyCoverWindow(coverWindow, in: host)
            let coverView = try #require(coverWindow.rootViewController?.view)

            #expect(host.scene.activationState == .foregroundActive)
            #expect(coverWindow.windowScene === host.scene)
            #expect(coverWindow.isHidden)
            #expect(coverWindow.isOpaque == false)
            #expect(coverWindow.alpha == 1)
            #expect(coverWindow.backgroundColor?.cgColor.alpha == 0)
            #expect(coverWindow.windowLevel > host.window.windowLevel)
            #expect(coverWindow.isUserInteractionEnabled)
            #expect(coverView.isUserInteractionEnabled)
            #expect(coverView.isOpaque == false)
            #expect(coverView.alpha == 1)
            #expect(coverView.backgroundColor?.cgColor.alpha == 0)
            #expect(coverView.subviews.isEmpty)
            #expect(coverView.accessibilityLabel == "Calculator")
            #expect(coverView.accessibilityViewIsModal)
            #expect(coverView.frame == coverWindow.bounds)
            #expect(coverView.bounds == coverWindow.bounds)

            let underlyingControl = UIButton(type: .system)
            underlyingControl.frame = CGRect(x: 16, y: 16, width: 120, height: 44)
            host.window.addSubview(underlyingControl)

            NotificationCenter.default.post(
                name: UIScene.willDeactivateNotification,
                object: host.scene,
            )

            #expect(coverWindow.isHidden == false)
            #expect(coverWindow.isKeyWindow)
            #expect(host.window.accessibilityElementsHidden)

            let coverPoint = underlyingControl.convert(
                CGPoint(x: underlyingControl.bounds.midX, y: underlyingControl.bounds.midY),
                to: coverWindow,
            )
            let hitView = coverWindow.hitTest(coverPoint, with: nil)
            #expect(hitView?.window === coverWindow)
            #expect(hitView !== underlyingControl)

            let primaryDecoy = try #require(primaryDecoy(in: host))
            #expect(primaryDecoy.isHidden == false)
            #expect(primaryDecoy.alpha == 1)
            #expect(primaryDecoy.isOpaque)
            #expect(primaryDecoy.backgroundColor?.cgColor.alpha == 1)
            #expect(primaryDecoy.frame == host.window.bounds)
            #expect(primaryDecoy.bounds == host.window.bounds)
            #expect(primaryDecoy.isAccessibilityElement == false)
            #expect(primaryDecoy.accessibilityElementsHidden)
            #expect(host.window.subviews.last === primaryDecoy)

            setCoverage(of: host, coverWindow: coverWindow, isCovered: true, revision: 2)
            NotificationCenter.default.post(
                name: UIScene.didActivateNotification,
                object: host.scene,
            )
            #expect(coverWindow.isHidden == false)
            #expect(host.window.accessibilityElementsHidden)

            setCoverage(of: host, coverWindow: coverWindow, isCovered: false, revision: 3)
            expectPrivacyCoverWindow(coverWindow, in: host)
            #expect(coverWindow.isHidden)
            #expect(primaryDecoy.isHidden)
            #expect(host.window.accessibilityElementsHidden == host.initialAccessibilityElementsHidden)
            #expect(host.window.isKeyWindow == host.wasKeyWindow)
        }

        @Test("The hidden cover is laid out before the first scene deactivation")
        func hiddenCoverIsLaidOutBeforeFirstDeactivation() throws {
            let host = try makeHost(isCovered: false)
            defer { unmount(host) }

            let coverWindow = try awaitPrivacyCoverWindow(in: host)
            expectPrivacyCoverWindow(coverWindow, in: host)
            #expect(coverWindow.isHidden)

            let controller = try #require(coverWindow.rootViewController)
            #expect(controller.isViewLoaded)
            let coverView = try #require(controller.viewIfLoaded)
            #expect(coverView.bounds.width > 0)
            #expect(coverView.bounds.height > 0)
            #expect(coverView.isOpaque == false)
            #expect(coverView.backgroundColor?.cgColor.alpha == 0)
            #expect(coverView.subviews.isEmpty)
            #expect(coverView.accessibilityLabel == "Calculator")

            let primaryDecoy = try #require(primaryDecoy(in: host))
            #expect(primaryDecoy.isHidden)
            #expect(primaryDecoy.isOpaque)
            #expect(primaryDecoy.bounds == host.window.bounds)
            let display = try #require(primaryDecoy.subviews.compactMap { $0 as? UILabel }.first)
            #expect(display.text == "0")
            #expect(display.isHidden == false)
            #expect(display.bounds.width > 0)
            #expect(display.bounds.height > 0)

            NotificationCenter.default.post(
                name: UIScene.willDeactivateNotification,
                object: host.scene,
            )

            #expect(coverWindow.isHidden == false)
            #expect(coverWindow.isKeyWindow)
            #expect(coverWindow.isOpaque == false)
            #expect(coverView.isOpaque == false)
            #expect(coverView.subviews.isEmpty)
            #expect(host.window.accessibilityElementsHidden)
            #expect(primaryDecoy.isHidden == false)
            #expect(primaryDecoy.alpha == 1)
            #expect(primaryDecoy.isOpaque)
            #expect(primaryDecoy.frame == host.window.bounds)
            #expect(primaryDecoy.bounds == host.window.bounds)
            #expect(display.window === host.window)
            #expect(display.text == "0")
            #expect(display.frame.width > 0)
            #expect(display.frame.height > 0)
        }

        @Test("willDeactivate immediately shows a decoy over the primary Library and Browser windows")
        func sceneWillDeactivateImmediatelyShowsPrimaryDecoy() throws {
            try expectPrimaryWindowDecoyImmediately(
                for: .library,
                notification: UIScene.willDeactivateNotification,
            )
            try expectPrimaryWindowDecoyImmediately(
                for: .browser,
                notification: UIScene.willDeactivateNotification,
            )
        }

        @Test("didEnterBackground immediately shows a decoy over the primary Library and Browser windows")
        func sceneDidEnterBackgroundImmediatelyShowsPrimaryDecoy() throws {
            try expectPrimaryWindowDecoyImmediately(
                for: .library,
                notification: UIScene.didEnterBackgroundNotification,
            )
            try expectPrimaryWindowDecoyImmediately(
                for: .browser,
                notification: UIScene.didEnterBackgroundNotification,
            )
        }

        @Test("The calculator face fits compact phone and wide iPad layouts")
        func calculatorFaceFitsCompactPhoneAndWideIPadLayouts() throws {
            let layouts: [(ScenePrivacyCoverTestSurface, CGSize)] = [
                (.library, CGSize(width: 320, height: 568)),
                (.browser, CGSize(width: 1_024, height: 1_366)),
            ]

            for (surface, size) in layouts {
                let host = try makeHost(isCovered: false, surface: surface)
                defer { unmount(host) }

                let decoy = try #require(primaryDecoy(in: host))
                decoy.frame = CGRect(origin: .zero, size: size)
                decoy.setNeedsLayout()
                decoy.layoutIfNeeded()

                try expectCalculatorFace(in: decoy, surface: surface)

                let labels = decoy.subviews.compactMap { $0 as? UILabel }
                let contentWidth = try #require(labels.first?.frame.width)
                #expect(contentWidth <= 520)
                #expect(abs((labels.first?.frame.midX ?? 0) - decoy.bounds.midX) < 1)
            }
        }

        @Test("A validated caller update reveals only after inactive coverage is confirmed")
        func validatedCallerUpdateRevealsAfterInactiveCoverage() throws {
            let host = try makeHost(isCovered: false)
            defer { unmount(host) }

            NotificationCenter.default.post(
                name: UIScene.willDeactivateNotification,
                object: host.scene,
            )

            let coverWindow = try awaitPrivacyCoverWindow(in: host)
            expectPrivacyCoverWindow(coverWindow, in: host)
            #expect(coverWindow.isHidden == false)
            #expect(host.window.accessibilityElementsHidden)

            setCoverage(of: host, coverWindow: coverWindow, isCovered: true, revision: 2)
            expectPrivacyCoverWindow(coverWindow, in: host)
            #expect(coverWindow.isHidden == false)

            NotificationCenter.default.post(
                name: UIScene.didActivateNotification,
                object: host.scene,
            )
            expectPrivacyCoverWindow(coverWindow, in: host)
            #expect(coverWindow.isHidden == false)
            #expect(host.window.accessibilityElementsHidden)

            setCoverage(of: host, coverWindow: coverWindow, isCovered: false, revision: 3)

            expectPrivacyCoverWindow(coverWindow, in: host)
            #expect(coverWindow.isHidden)
            #expect(host.window.accessibilityElementsHidden == host.initialAccessibilityElementsHidden)
            #expect(host.window.isKeyWindow == host.wasKeyWindow)
        }

        @Test("A covered caller update before willDeactivate remains acknowledged")
        func coveredCallerUpdateBeforeWillDeactivateRemainsAcknowledged() throws {
            let host = try makeHost(isCovered: false)
            defer { unmount(host) }

            let coverWindow = try awaitPrivacyCoverWindow(in: host)
            expectPrivacyCoverWindow(coverWindow, in: host)
            #expect(coverWindow.isHidden)

            setCoverage(of: host, coverWindow: coverWindow, isCovered: true, revision: 2)
            #expect(coverWindow.isHidden == false)

            NotificationCenter.default.post(
                name: UIScene.willDeactivateNotification,
                object: host.scene,
            )
            expectPrivacyCoverWindow(coverWindow, in: host)
            #expect(coverWindow.isHidden == false)

            NotificationCenter.default.post(
                name: UIScene.didActivateNotification,
                object: host.scene,
            )
            expectPrivacyCoverWindow(coverWindow, in: host)
            #expect(coverWindow.isHidden == false)

            setCoverage(of: host, coverWindow: coverWindow, isCovered: false, revision: 3)
            #expect(coverWindow.isHidden)
            #expect(host.window.accessibilityElementsHidden == host.initialAccessibilityElementsHidden)
            #expect(host.window.isKeyWindow == host.wasKeyWindow)
        }

        @Test("A stale uncovered value cannot reveal without post-deactivation confirmation")
        func staleUncoveredUpdateDoesNotRevealAfterActivation() throws {
            let host = try makeHost(isCovered: false)
            defer { unmount(host) }

            #expect(host.scene.activationState == .foregroundActive)
            NotificationCenter.default.post(
                name: UIScene.willDeactivateNotification,
                object: host.scene,
            )

            let coverWindow = try awaitPrivacyCoverWindow(in: host)
            expectPrivacyCoverWindow(coverWindow, in: host)
            #expect(coverWindow.isHidden == false)
            #expect(host.window.accessibilityElementsHidden)

            NotificationCenter.default.post(
                name: UIScene.didActivateNotification,
                object: host.scene,
            )
            expectPrivacyCoverWindow(coverWindow, in: host)
            #expect(coverWindow.isHidden == false)
            #expect(host.window.accessibilityElementsHidden)

            setCoverage(of: host, coverWindow: coverWindow, isCovered: true, revision: 2)
            expectPrivacyCoverWindow(coverWindow, in: host)
            #expect(coverWindow.isHidden == false)

            setCoverage(of: host, coverWindow: coverWindow, isCovered: true, revision: 3)
            #expect(coverWindow.isHidden == false)

            setCoverage(of: host, coverWindow: coverWindow, isCovered: false, revision: 4)
            expectPrivacyCoverWindow(coverWindow, in: host)
            #expect(coverWindow.isHidden)
            #expect(host.window.accessibilityElementsHidden == host.initialAccessibilityElementsHidden)
            #expect(host.window.isKeyWindow == host.wasKeyWindow)
        }

        @Test("A validated false update before activation reveals only after activation")
        func validatedCallerUpdateBeforeActivationRevealsAfterActivation() throws {
            let host = try makeHost(isCovered: false)
            defer { unmount(host) }

            NotificationCenter.default.post(
                name: UIScene.willDeactivateNotification,
                object: host.scene,
            )

            let coverWindow = try awaitPrivacyCoverWindow(in: host)
            #expect(coverWindow.isHidden == false)
            #expect(host.window.accessibilityElementsHidden)

            setCoverage(of: host, coverWindow: coverWindow, isCovered: true, revision: 2)
            #expect(coverWindow.isHidden == false)

            setCoverage(of: host, coverWindow: coverWindow, isCovered: false, revision: 3)
            #expect(coverWindow.isHidden == false)
            #expect(host.window.accessibilityElementsHidden)

            NotificationCenter.default.post(
                name: UIScene.didActivateNotification,
                object: host.scene,
            )

            #expect(coverWindow.isHidden)
            #expect(host.window.accessibilityElementsHidden == host.initialAccessibilityElementsHidden)
            #expect(host.window.isKeyWindow == host.wasKeyWindow)
        }

        @Test("An initially covered inactive scene waits for activation")
        func initiallyCoveredInactiveSceneWaitsForActivation() throws {
            // UIKit exposes no public API for creating an inactive UIWindowScene in an app-hosted test.
            let host = try makeHost(isCovered: true, initialSceneIsActiveOverride: false)
            defer { unmount(host) }

            let coverWindow = try awaitPrivacyCoverWindow(in: host)
            expectPrivacyCoverWindow(coverWindow, in: host)
            #expect(coverWindow.isHidden == false)
            #expect(host.window.accessibilityElementsHidden)

            setCoverage(of: host, coverWindow: coverWindow, isCovered: false, revision: 2)
            #expect(coverWindow.isHidden == false)
            #expect(host.window.accessibilityElementsHidden)

            NotificationCenter.default.post(
                name: UIScene.didActivateNotification,
                object: host.scene,
            )
            expectPrivacyCoverWindow(coverWindow, in: host)
            #expect(coverWindow.isHidden)
            #expect(host.window.accessibilityElementsHidden == host.initialAccessibilityElementsHidden)
            #expect(host.window.isKeyWindow == host.wasKeyWindow)
        }

        private func makeHost(
            isCovered: Bool,
            surface: ScenePrivacyCoverTestSurface = .library,
            initialSceneIsActiveOverride: Bool? = nil,
        ) throws -> ScenePrivacyCoverTestHost {
            let window = UIKitTestSupport.makeWindow(
                frame: CGRect(x: 0, y: 0, width: 390, height: 844),
            )
            let model = ScenePrivacyCoverTestModel(
                isCovered: isCovered,
                showsCover: false,
                surface: surface,
                initialSceneIsActiveOverride: initialSceneIsActiveOverride,
            )
            let controller = UIHostingController(rootView: ScenePrivacyCoverHarness(model: model))
            window.rootViewController = controller
            window.makeKeyAndVisible()
            window.layoutIfNeeded()
            controller.view.layoutIfNeeded()

            let scene = try #require(window.windowScene)
            let host = ScenePrivacyCoverTestHost(
                window: window,
                controller: controller,
                model: model,
                scene: scene,
                baselineWindowIDs: Set(scene.windows.map(ObjectIdentifier.init)),
                initialAccessibilityElementsHidden: window.accessibilityElementsHidden,
                wasKeyWindow: window.isKeyWindow,
            )

            #expect(scene.activationState == .foregroundActive)
            model.showsCover = true
            model.revision = 1
            controller.view.setNeedsLayout()
            window.layoutIfNeeded()
            controller.view.layoutIfNeeded()
            _ = try awaitPrivacyCoverWindow(in: host)
            return host
        }

        private func unmount(_ host: ScenePrivacyCoverTestHost) {
            host.model.isCovered = false
            host.model.revision = .max
            host.model.showsCover = false
            waitUntil(in: host, "Scene privacy cover teardown") {
                privacyCoverWindows(in: host).isEmpty && primaryDecoy(in: host) == nil
            }

            #expect(host.window.accessibilityElementsHidden == host.initialAccessibilityElementsHidden)
            #expect(host.window.isKeyWindow == host.wasKeyWindow)
            #expect(privacyCoverWindows(in: host).isEmpty)
            #expect(primaryDecoy(in: host) == nil)

            host.window.rootViewController = nil
            host.window.isHidden = true
        }

        private func setCoverage(
            of host: ScenePrivacyCoverTestHost,
            coverWindow: UIWindow,
            isCovered: Bool,
            revision: Int,
        ) {
            host.model.isCovered = isCovered
            host.model.revision = revision
            waitUntil(in: host, "coverage update \(revision)") {
                host.model.receivedUpdates.last == isCovered
            }
            expectPrivacyCoverWindow(coverWindow, in: host)
            expectLastCoverageUpdate(isCovered, from: host)
            print("ScenePrivacyCover.updateUIView Bool trace: \(host.model.receivedUpdates)")
        }

        private func privacyCoverWindows(in host: ScenePrivacyCoverTestHost) -> [UIWindow] {
            host.scene.windows.filter {
                $0.accessibilityIdentifier == "MediaVault.ScenePrivacyCoverWindow"
                    && !host.baselineWindowIDs.contains(ObjectIdentifier($0))
            }
        }

        private func privacyCoverWindow(in host: ScenePrivacyCoverTestHost) -> UIWindow? {
            privacyCoverWindows(in: host).first
        }

        private func primaryDecoy(in host: ScenePrivacyCoverTestHost) -> UIView? {
            host.window.subviews.first {
                $0.accessibilityIdentifier == Self.primaryDecoyAccessibilityIdentifier
            }
        }

        private func expectPrimaryWindowDecoyImmediately(
            for surface: ScenePrivacyCoverTestSurface,
            notification: Notification.Name,
        ) throws {
            let host = try makeHost(isCovered: false, surface: surface)
            defer { unmount(host) }

            let coverWindow = try awaitPrivacyCoverWindow(in: host)
            let primaryDecoy = try #require(primaryDecoy(in: host))
            try expectCalculatorFace(in: primaryDecoy, surface: surface)

            #expect(host.model.surface == surface)
            #expect(primaryDecoy.superview === host.window)
            #expect(primaryDecoy.isHidden)
            #expect(primaryDecoy.isUserInteractionEnabled == false)
            #expect(coverWindow.isHidden)

            let underlyingControl = UIButton(type: .system)
            underlyingControl.frame = CGRect(
                x: host.window.bounds.midX - 24,
                y: host.window.bounds.midY - 24,
                width: 48,
                height: 48,
            )
            host.window.addSubview(underlyingControl)

            NotificationCenter.default.post(name: notification, object: host.scene)

            try expectCalculatorFace(in: primaryDecoy, surface: surface)
            #expect(primaryDecoy.isHidden == false)
            #expect(primaryDecoy.window === host.window)
            #expect(primaryDecoy.frame == host.window.bounds)
            #expect(primaryDecoy.alpha == 1)
            #expect(primaryDecoy.backgroundColor?.cgColor.alpha == 1)
            #expect(host.window.subviews.last === primaryDecoy)
            #expect(coverWindow.isHidden == false)
            #expect(coverWindow.isKeyWindow)
            #expect(host.window.accessibilityElementsHidden)
            #expect(coverWindow.isOpaque == false)
            #expect(coverWindow.isUserInteractionEnabled)
            #expect(coverWindow.backgroundColor?.cgColor.alpha == 0)
            let coverView = try #require(coverWindow.rootViewController?.view)
            #expect(coverView.isOpaque == false)
            #expect(coverView.isUserInteractionEnabled)
            #expect(coverView.backgroundColor?.cgColor.alpha == 0)
            #expect(coverView.subviews.isEmpty)
            #expect(coverView.accessibilityLabel == "Calculator")
            #expect(coverView.isAccessibilityElement)
            #expect(coverView.accessibilityElementsHidden == false)
            #expect(coverView.accessibilityViewIsModal)

            let coverPoint = underlyingControl.convert(
                CGPoint(x: underlyingControl.bounds.midX, y: underlyingControl.bounds.midY),
                to: coverWindow,
            )
            let hitView = coverWindow.hitTest(coverPoint, with: nil)
            #expect(hitView?.window === coverWindow)
            #expect(hitView !== underlyingControl)
        }

        private func expectCalculatorFace(
            in decoy: UIView,
            surface: ScenePrivacyCoverTestSurface,
        ) throws {
            let labels = decoy.subviews.compactMap { $0 as? UILabel }
            let display = try #require(
                labels.first {
                    $0.accessibilityIdentifier == Self.calculatorDisplayAccessibilityIdentifier
                },
            )
            let keys = labels
                .filter {
                    $0.accessibilityIdentifier?.hasPrefix(
                        Self.calculatorKeyAccessibilityIdentifierPrefix,
                    ) == true
                }
                .sorted { ($0.accessibilityIdentifier ?? "") < ($1.accessibilityIdentifier ?? "") }

            #expect(display.text == "0")
            #expect(keys.compactMap(\.text) == Self.expectedCalculatorGlyphs)
            #expect(keys.count == 20)
            #expect(decoy.isOpaque)
            #expect(decoy.backgroundColor?.cgColor.alpha == 1)
            #expect(decoy.isUserInteractionEnabled == false)
            #expect(decoy.isAccessibilityElement == false)
            #expect(decoy.accessibilityElementsHidden)

            for label in [display] + keys {
                #expect(label.isHidden == false)
                #expect(label.bounds.width > 0)
                #expect(label.bounds.height >= 44)
                #expect(label.isAccessibilityElement == false)
                #expect(decoy.bounds.contains(label.frame))
                #expect(decoy.safeAreaLayoutGuide.layoutFrame.contains(label.frame))
            }

            let orangeKeyIndices: Set = [3, 7, 11, 15, 19]
            for (index, key) in keys.enumerated() {
                #expect(key.backgroundColor == (orangeKeyIndices.contains(index)
                        ? .systemOrange
                        : .secondarySystemBackground))
            }

            let faceText = [
                decoy.accessibilityLabel,
                decoy.accessibilityValue,
                decoy.accessibilityHint,
            ] + ([display] + keys).flatMap { label in
                [label.text, label.accessibilityLabel, label.accessibilityValue, label.accessibilityHint]
            }
            for fixtureText in [surface.heading, surface.detail] {
                #expect(
                    faceText
                        .compactMap(\.self)
                        .allSatisfy { !$0.localizedCaseInsensitiveContains(fixtureText) },
                )
            }
        }

        private func expectPrivacyCoverWindow(
            _ coverWindow: UIWindow,
            in host: ScenePrivacyCoverTestHost,
        ) {
            let matchingWindows = privacyCoverWindows(in: host)
            #expect(matchingWindows.count == 1)
            #expect(matchingWindows.first === coverWindow)
        }

        private func expectLastCoverageUpdate(_ expected: Bool, from host: ScenePrivacyCoverTestHost) {
            #expect(host.model.receivedUpdates.last == expected)
        }

        private func awaitPrivacyCoverWindow(in host: ScenePrivacyCoverTestHost) throws -> UIWindow {
            waitUntil(in: host, "scene privacy cover window") {
                privacyCoverWindow(in: host) != nil && primaryDecoy(in: host) != nil
            }

            return try #require(privacyCoverWindow(in: host))
        }

        private func waitUntil(
            in host: ScenePrivacyCoverTestHost,
            _ description: String,
            condition: () -> Bool,
        ) {
            for _ in 0 ..< 100 {
                host.window.layoutIfNeeded()
                host.controller.view.layoutIfNeeded()
                if condition() {
                    return
                }
                _ = CFRunLoopRunInMode(.defaultMode, 0, true)
            }
            Issue.record("Timed out waiting for \(description)")
        }
    }
}

@MainActor
@Observable
private final class ScenePrivacyCoverTestModel {
    var isCovered: Bool
    var revision: Int
    var showsCover: Bool
    let surface: ScenePrivacyCoverTestSurface
    let initialSceneIsActiveOverride: Bool?
    @ObservationIgnored
    var receivedUpdates: [Bool] = []

    init(
        isCovered: Bool,
        showsCover: Bool,
        surface: ScenePrivacyCoverTestSurface,
        initialSceneIsActiveOverride: Bool?,
    ) {
        self.isCovered = isCovered
        revision = 0
        self.showsCover = showsCover
        self.surface = surface
        self.initialSceneIsActiveOverride = initialSceneIsActiveOverride
    }
}

private enum ScenePrivacyCoverTestSurface: Equatable {
    case library
    case browser

    var heading: String {
        switch self {
        case .library:
            "Library"
        case .browser:
            "Start Page"
        }
    }

    var detail: String {
        switch self {
        case .library:
            "Sample media"
        case .browser:
            "example.com"
        }
    }
}

@MainActor
private struct ScenePrivacyCoverHarness: View {
    @Bindable
    var model: ScenePrivacyCoverTestModel

    var body: some View {
        if model.showsCover {
            ZStack(alignment: .topLeading) {
                VStack(alignment: .leading) {
                    Text(model.surface.heading)
                    Text(model.surface.detail)
                }
                ScenePrivacyCover(
                    isCovered: model.isCovered,
                    initialSceneIsActiveOverride: model.initialSceneIsActiveOverride,
                    onCoverageUpdate: { model.receivedUpdates.append($0) },
                )
                .frame(width: 1, height: 1)
                Text(String(model.revision))
                    .hidden()
                    .accessibilityHidden(true)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            Color.clear
        }
    }
}

@MainActor
private struct ScenePrivacyCoverTestHost {
    let window: UIWindow
    let controller: UIHostingController<ScenePrivacyCoverHarness>
    let model: ScenePrivacyCoverTestModel
    let scene: UIWindowScene
    let baselineWindowIDs: Set<ObjectIdentifier>
    let initialAccessibilityElementsHidden: Bool
    let wasKeyWindow: Bool
}
