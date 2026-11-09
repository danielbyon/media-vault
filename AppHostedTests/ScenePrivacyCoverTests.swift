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
import AppFeature
import CalculatorFeature
import ComposableArchitecture
import ConcurrencyExtras
import CoreFoundation
import CoreGraphics
import DecoySupport
import Dependencies
import Foundation
import FoundationTestSupport
import MediaLibrary
import ObjectiveC
import Observation
import QuartzCore
import Sharing
import SnapshotTesting
import SwiftUI
import Testing
import UIKit
import UIUtilities
import VaultFeature
@testable import BrowserFeature
@testable import PresentationSupport

extension AppHostedUITests {
    @Suite("Scene privacy cover", .serialized)
    @MainActor
    struct ScenePrivacyCoverTests {
        private static let scenePrivacyCoverWindowAccessibilityIdentifier =
            "MediaVault.ScenePrivacyCoverWindow"
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
        func coveredSceneInstallsSceneBoundBarrier() async throws {
            let host = try await makeHost(isCovered: false)
            var didUnmount = false
            defer { quarantineHostIfNeeded(host, didUnmount: didUnmount) }

            let coverWindow = try #require(privacyCoverWindow(in: host))
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
            underlyingControl.frame = CGRect(x: 120, y: 320, width: 120, height: 44)
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
            try expectCoverWindowHitTestResolvesToVisibleCover(
                at: coverPoint,
                in: coverWindow,
                primaryWindow: host.window,
            )

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

            try await setCoverage(of: host, coverWindow: coverWindow, isCovered: true, revision: 2)
            NotificationCenter.default.post(
                name: UIScene.didActivateNotification,
                object: host.scene,
            )
            #expect(coverWindow.isHidden == false)
            #expect(host.window.accessibilityElementsHidden)
            try expectCoverWindowHitTestResolvesToVisibleCover(
                at: coverPoint,
                in: coverWindow,
                primaryWindow: host.window,
            )

            try await setCoverage(of: host, coverWindow: coverWindow, isCovered: false, revision: 3)
            expectPrivacyCoverWindow(coverWindow, in: host)
            #expect(coverWindow.isHidden)
            #expect(primaryDecoy.isHidden)
            #expect(host.window.accessibilityElementsHidden == host.initialAccessibilityElementsHidden)
            #expect(host.window.isKeyWindow == host.wasKeyWindow)
            didUnmount = await unmount(host)
        }

        @Test("The hidden cover is laid out before the first scene deactivation")
        func hiddenCoverIsLaidOutBeforeFirstDeactivation() async throws {
            let host = try await makeHost(isCovered: false)
            var didUnmount = false
            defer { quarantineHostIfNeeded(host, didUnmount: didUnmount) }

            let coverWindow = try #require(privacyCoverWindow(in: host))
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
            didUnmount = await unmount(host)
        }

        @Test("willDeactivate immediately shows a decoy over the primary Library and Browser windows")
        func sceneWillDeactivateImmediatelyShowsPrimaryDecoy() async throws {
            try await expectPrimaryWindowDecoyImmediately(
                for: .library,
                notification: UIScene.willDeactivateNotification,
            )
            try await expectPrimaryWindowDecoyImmediately(
                for: .browser,
                notification: UIScene.willDeactivateNotification,
            )
        }

        @Test("didEnterBackground immediately shows a decoy over the primary Library and Browser windows")
        func sceneDidEnterBackgroundImmediatelyShowsPrimaryDecoy() async throws {
            try await expectPrimaryWindowDecoyImmediately(
                for: .library,
                notification: UIScene.didEnterBackgroundNotification,
            )
            try await expectPrimaryWindowDecoyImmediately(
                for: .browser,
                notification: UIScene.didEnterBackgroundNotification,
            )
        }

        @Test("The calculator face fits compact phone and wide iPad layouts")
        func calculatorFaceFitsCompactPhoneAndWideIPadLayouts() async throws {
            let layouts: [(ScenePrivacyCoverTestSurface, CGSize)] = [
                (.library, CGSize(width: 320, height: 568)),
                (.browser, CGSize(width: 1_024, height: 1_366)),
            ]

            for (surface, size) in layouts {
                let host = try await makeHost(isCovered: false, surface: surface)
                var didUnmount = false
                defer { quarantineHostIfNeeded(host, didUnmount: didUnmount) }

                let decoy = try #require(primaryDecoy(in: host))
                decoy.frame = CGRect(origin: .zero, size: size)
                decoy.setNeedsLayout()
                decoy.layoutIfNeeded()

                try expectCalculatorFace(in: decoy, surface: surface)

                let labels = decoy.subviews.compactMap { $0 as? UILabel }
                let contentWidth = try #require(labels.first?.frame.width)
                #expect(contentWidth <= 520)
                #expect(abs((labels.first?.frame.midX ?? 0) - decoy.bounds.midX) < 1)
                didUnmount = await unmount(host)
            }
        }

        @Test("A validated caller update reveals only after inactive coverage is confirmed")
        func validatedCallerUpdateRevealsAfterInactiveCoverage() async throws {
            let host = try await makeHost(isCovered: false)
            var didUnmount = false
            defer { quarantineHostIfNeeded(host, didUnmount: didUnmount) }

            NotificationCenter.default.post(
                name: UIScene.willDeactivateNotification,
                object: host.scene,
            )

            let coverWindow = try #require(privacyCoverWindow(in: host))
            expectPrivacyCoverWindow(coverWindow, in: host)
            #expect(coverWindow.isHidden == false)
            #expect(host.window.accessibilityElementsHidden)

            try await setCoverage(of: host, coverWindow: coverWindow, isCovered: true, revision: 2)
            expectPrivacyCoverWindow(coverWindow, in: host)
            #expect(coverWindow.isHidden == false)

            NotificationCenter.default.post(
                name: UIScene.didActivateNotification,
                object: host.scene,
            )
            expectPrivacyCoverWindow(coverWindow, in: host)
            #expect(coverWindow.isHidden == false)
            #expect(host.window.accessibilityElementsHidden)

            try await setCoverage(of: host, coverWindow: coverWindow, isCovered: false, revision: 3)

            expectPrivacyCoverWindow(coverWindow, in: host)
            #expect(coverWindow.isHidden)
            #expect(host.window.accessibilityElementsHidden == host.initialAccessibilityElementsHidden)
            #expect(host.window.isKeyWindow == host.wasKeyWindow)
            didUnmount = await unmount(host)
        }

        @Test("A covered caller update before willDeactivate remains acknowledged")
        func coveredCallerUpdateBeforeWillDeactivateRemainsAcknowledged() async throws {
            let host = try await makeHost(isCovered: false)
            var didUnmount = false
            defer { quarantineHostIfNeeded(host, didUnmount: didUnmount) }

            let coverWindow = try #require(privacyCoverWindow(in: host))
            expectPrivacyCoverWindow(coverWindow, in: host)
            #expect(coverWindow.isHidden)

            try await setCoverage(of: host, coverWindow: coverWindow, isCovered: true, revision: 2)
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

            try await setCoverage(of: host, coverWindow: coverWindow, isCovered: false, revision: 3)
            #expect(coverWindow.isHidden)
            #expect(host.window.accessibilityElementsHidden == host.initialAccessibilityElementsHidden)
            #expect(host.window.isKeyWindow == host.wasKeyWindow)
            didUnmount = await unmount(host)
        }

        @Test("A stale uncovered value cannot reveal without post-deactivation confirmation")
        func staleUncoveredUpdateDoesNotRevealAfterActivation() async throws {
            let host = try await makeHost(isCovered: false)
            var didUnmount = false
            defer { quarantineHostIfNeeded(host, didUnmount: didUnmount) }

            #expect(host.scene.activationState == .foregroundActive)
            NotificationCenter.default.post(
                name: UIScene.willDeactivateNotification,
                object: host.scene,
            )

            let coverWindow = try #require(privacyCoverWindow(in: host))
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

            try await setCoverage(of: host, coverWindow: coverWindow, isCovered: true, revision: 2)
            expectPrivacyCoverWindow(coverWindow, in: host)
            #expect(coverWindow.isHidden == false)

            #expect(coverWindow.isHidden == false)

            try await setCoverage(of: host, coverWindow: coverWindow, isCovered: false, revision: 4)
            expectPrivacyCoverWindow(coverWindow, in: host)
            #expect(coverWindow.isHidden)
            #expect(host.window.accessibilityElementsHidden == host.initialAccessibilityElementsHidden)
            #expect(host.window.isKeyWindow == host.wasKeyWindow)
            didUnmount = await unmount(host)
        }

        @Test("A validated false update before activation reveals only after activation")
        func validatedCallerUpdateBeforeActivationRevealsAfterActivation() async throws {
            let host = try await makeHost(isCovered: false)
            var didUnmount = false
            defer { quarantineHostIfNeeded(host, didUnmount: didUnmount) }

            NotificationCenter.default.post(
                name: UIScene.willDeactivateNotification,
                object: host.scene,
            )

            let coverWindow = try #require(privacyCoverWindow(in: host))
            #expect(coverWindow.isHidden == false)
            #expect(host.window.accessibilityElementsHidden)

            try await setCoverage(of: host, coverWindow: coverWindow, isCovered: true, revision: 2)
            #expect(coverWindow.isHidden == false)

            try await setCoverage(of: host, coverWindow: coverWindow, isCovered: false, revision: 3)
            #expect(coverWindow.isHidden == false)
            #expect(host.window.accessibilityElementsHidden)

            NotificationCenter.default.post(
                name: UIScene.didActivateNotification,
                object: host.scene,
            )

            #expect(coverWindow.isHidden)
            #expect(host.window.accessibilityElementsHidden == host.initialAccessibilityElementsHidden)
            #expect(host.window.isKeyWindow == host.wasKeyWindow)
            didUnmount = await unmount(host)
        }

        @Test("An initially covered inactive scene waits for activation")
        func initiallyCoveredInactiveSceneWaitsForActivation() async throws {
            // UIKit exposes no public API for creating an inactive UIWindowScene in an app-hosted test.
            let host = try await makeHost(isCovered: true, initialSceneIsActiveOverride: false)
            var didUnmount = false
            defer { quarantineHostIfNeeded(host, didUnmount: didUnmount) }

            let coverWindow = try #require(privacyCoverWindow(in: host))
            expectPrivacyCoverWindow(coverWindow, in: host)
            #expect(coverWindow.isHidden == false)
            #expect(host.window.accessibilityElementsHidden)

            try await setCoverage(of: host, coverWindow: coverWindow, isCovered: false, revision: 2)
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
            didUnmount = await unmount(host)
        }

        @Test(
            "The real root decoy occludes private pixels when the cover window becomes key",
            arguments: RootPrivacySnapshotLayout.sentinelLayoutsForCurrentSimulator,
        )
        func rootPrivacyCoverSynchronouslyOccludesPrivateSentinel(
            _ layout: RootPrivacySnapshotLayout,
        ) async throws {
            let start = ContinuousClock.now
            let clock = LockIsolated(start)
            let (store, removeStoreDefaults) = try makeRootStore(
                phase: .authenticated,
                clock: clock,
            )
            defer { removeStoreDefaults() }
            await prepareRootSnapshotLibrary(store)
            let host = try await makeRootPrivacyHost(
                store: store,
                frame: CGRect(origin: .zero, size: layout.size),
                horizontalSizeClass: layout.horizontalSizeClass,
                scenePhase: .active,
            )
            // The host scene is active before its privacy-cover observer attaches. Posting this event
            // exercises that observer without creating a UIKit scene activation transition.
            NotificationCenter.default.post(
                name: UIScene.didActivateNotification,
                object: host.scene,
            )
            var sentinel: UIView?
            var privateControl: UIButton?

            do {
                try expectRootPrivacyCoverAttached(in: host, layout: layout)

                let bounds = host.window.bounds
                let sentinelCenters = [
                    CGPoint(x: 32, y: 32),
                    CGPoint(x: bounds.maxX - 32, y: 32),
                    CGPoint(x: 32, y: bounds.maxY - 32),
                    CGPoint(x: bounds.maxX - 32, y: bounds.maxY - 32),
                ]
                let privateSentinel = UIView(frame: bounds)
                privateSentinel.backgroundColor = .clear
                privateSentinel.isOpaque = false
                privateSentinel.isUserInteractionEnabled = false
                var sentinelPatches: [UIView] = []
                for center in sentinelCenters {
                    let patch = UIView(frame: CGRect(x: center.x - 14, y: center.y - 14, width: 28, height: 28))
                    patch.backgroundColor = UIColor(red: 1, green: 0, blue: 1, alpha: 1)
                    patch.isOpaque = true
                    privateSentinel.addSubview(patch)
                    sentinelPatches.append(patch)
                }
                sentinel = privateSentinel

                let control = UIButton(type: .system)
                control.frame = CGRect(x: bounds.midX - 50, y: bounds.midY - 22, width: 100, height: 44)
                privateControl = control

                host.window.addSubview(privateSentinel)
                host.window.addSubview(control)

                try await awaitCoreAnimationCommit()
                #expect(
                    try ScenePrivacyCoverSentinelTestSupport.colorInfluencePixelCounts(
                        in: host.window,
                        patches: sentinelPatches,
                        centeredAt: sentinelCenters,
                    )
                    .allSatisfy { $0 >= 48 },
                )

                let transition = try await deactivateAndAwaitPrivacyCover(in: host)
                let coverWindow = transition.coverWindow
                let primaryDecoy = try #require(primaryDecoy(in: host))
                let primaryDecoyAtKey = transition.primaryDecoyAtKey
                #expect(host.scene.activationState == .foregroundActive)
                #expect(coverWindow.windowScene === host.scene)
                #expect(coverWindow.windowLevel > host.window.windowLevel)
                #expect(coverWindow.isHidden == false)
                #expect(coverWindow.isKeyWindow)
                #expect(primaryDecoyAtKey.isPresent)
                #expect(primaryDecoyAtKey.superviewIsHostWindow)
                #expect(primaryDecoyAtKey.isTopmostSubview)
                #expect(primaryDecoyAtKey.isHidden == false)
                #expect(primaryDecoyAtKey.alpha == 1)
                #expect(primaryDecoyAtKey.isOpaque)
                #expect(primaryDecoyAtKey.backgroundColorAlpha == 1)
                #expect(primaryDecoyAtKey.frame == bounds)
                #expect(primaryDecoyAtKey.bounds == bounds)
                #expect(host.window.accessibilityElementsHidden)

                let coverView = try #require(coverWindow.rootViewController?.view)
                #expect(coverView.accessibilityLabel == "Calculator")
                #expect(coverView.accessibilityViewIsModal)
                let hitTestControl = try #require(privateControl)
                let controlPoint = hitTestControl.convert(
                    CGPoint(x: hitTestControl.bounds.midX, y: hitTestControl.bounds.midY),
                    to: coverWindow,
                )
                try expectCoverWindowHitTestResolvesToVisibleCover(
                    at: controlPoint,
                    in: coverWindow,
                    primaryWindow: host.window,
                )

                try await awaitCoreAnimationCommit()
                #expect(
                    try ScenePrivacyCoverSentinelTestSupport.colorInfluencePixelCounts(
                        in: host.window,
                        patches: sentinelPatches,
                        centeredAt: sentinelCenters,
                    )
                    .allSatisfy { $0 == 0 },
                )

                let decoyFrame = primaryDecoy.frame
                primaryDecoy.alpha = 0.5
                try await awaitCoreAnimationCommit()
                #expect(
                    try ScenePrivacyCoverSentinelTestSupport.colorInfluencePixelCounts(
                        in: host.window,
                        patches: sentinelPatches,
                        centeredAt: sentinelCenters,
                    )
                    .allSatisfy { $0 >= 48 },
                )

                primaryDecoy.alpha = 1
                try await awaitCoreAnimationCommit()
                #expect(
                    try ScenePrivacyCoverSentinelTestSupport.colorInfluencePixelCounts(
                        in: host.window,
                        patches: sentinelPatches,
                        centeredAt: sentinelCenters,
                    )
                    .allSatisfy { $0 == 0 },
                )

                primaryDecoy.alpha = 0
                try await awaitCoreAnimationCommit()
                #expect(
                    try ScenePrivacyCoverSentinelTestSupport.colorInfluencePixelCounts(
                        in: host.window,
                        patches: sentinelPatches,
                        centeredAt: sentinelCenters,
                    )
                    .allSatisfy { $0 >= 48 },
                )

                primaryDecoy.alpha = 1
                primaryDecoy.frame = bounds.insetBy(dx: bounds.width / 4, dy: bounds.height / 4)
                primaryDecoy.setNeedsLayout()
                primaryDecoy.layoutIfNeeded()
                try await awaitCoreAnimationCommit()
                #expect(
                    try ScenePrivacyCoverSentinelTestSupport.colorInfluencePixelCounts(
                        in: host.window,
                        patches: sentinelPatches,
                        centeredAt: sentinelCenters,
                    )
                    .allSatisfy { $0 >= 48 },
                )

                primaryDecoy.frame = decoyFrame
                primaryDecoy.setNeedsLayout()
                primaryDecoy.layoutIfNeeded()
                try await awaitCoreAnimationCommit()
                #expect(
                    try ScenePrivacyCoverSentinelTestSupport.colorInfluencePixelCounts(
                        in: host.window,
                        patches: sentinelPatches,
                        centeredAt: sentinelCenters,
                    )
                    .allSatisfy { $0 == 0 },
                )

                store.send(.applicationPhaseChanged(.background))
                try await awaitCoreAnimationCommit()
                NotificationCenter.default.post(
                    name: UIScene.didEnterBackgroundNotification,
                    object: host.scene,
                )
                #expect(store.state.applicationReturnPending)
                #expect(coverWindow.isHidden == false)

                clock.withValue { $0 = start.advanced(by: .seconds(9)) }
                store.send(.applicationPhaseChanged(.active))
                try await awaitCoreAnimationCommit()
                #expect(store.state.vault.phase == .authenticated)
                #expect(store.state.applicationReturnPending == false)
                #expect(coverWindow.isHidden == false)
                #expect(
                    try ScenePrivacyCoverSentinelTestSupport.colorInfluencePixelCounts(
                        in: host.window,
                        patches: sentinelPatches,
                        centeredAt: sentinelCenters,
                    )
                    .allSatisfy { $0 == 0 },
                )

                NotificationCenter.default.post(
                    name: UIScene.didActivateNotification,
                    object: host.scene,
                )
                #expect(coverWindow.isHidden)
                #expect(host.window.isKeyWindow == host.wasKeyWindow)
                #expect(primaryDecoy.isHidden)
                #expect(
                    try ScenePrivacyCoverSentinelTestSupport.colorInfluencePixelCounts(
                        in: host.window,
                        patches: sentinelPatches,
                        centeredAt: sentinelCenters,
                    )
                    .allSatisfy { $0 >= 48 },
                )

                NotificationCenter.default.post(
                    name: UIScene.didEnterBackgroundNotification,
                    object: host.scene,
                )
                #expect(host.scene.activationState == .foregroundActive)
                #expect(coverWindow.isHidden == false)
                #expect(coverWindow.isKeyWindow)
                #expect(primaryDecoy.isHidden == false)
                #expect(host.window.accessibilityElementsHidden)
                try await awaitCoreAnimationCommit()
                #expect(
                    try ScenePrivacyCoverSentinelTestSupport.colorInfluencePixelCounts(
                        in: host.window,
                        patches: sentinelPatches,
                        centeredAt: sentinelCenters,
                    )
                    .allSatisfy { $0 == 0 },
                )

                privateSentinel.removeFromSuperview()
                control.removeFromSuperview()
                sentinel = nil
                privateControl = nil
                try await unmountRootPrivacyHost(host)
            } catch {
                sentinel?.removeFromSuperview()
                privateControl?.removeFromSuperview()
                try? await unmountRootPrivacyHost(host)
                throw error
            }
        }

        @Test(
            "An authenticated root stays protected until activation and locks before an expired return is revealed",
            arguments: RootPrivacySnapshotLayout.allCases,
        )
        func rootPrivacyReturnAndExpiryOrdering(_ layout: RootPrivacySnapshotLayout) async throws {
            let start = ContinuousClock.now
            let clock = LockIsolated(start)
            let (store, removeStoreDefaults) = try makeRootStore(
                phase: .authenticated,
                clock: clock,
            )
            defer { removeStoreDefaults() }
            await prepareRootSnapshotLibrary(store)
            let host = try await makeRootPrivacyHost(
                store: store,
                frame: CGRect(origin: .zero, size: layout.size),
                horizontalSizeClass: layout.horizontalSizeClass,
                scenePhase: .active,
            )

            do {
                try expectRootPrivacyCoverAttached(in: host, layout: layout)

                let transition = try await deactivateAndAwaitPrivacyCover(in: host)
                let coverWindow = transition.coverWindow
                try expectRootPrivacyState(
                    host,
                    phase: .authenticated,
                    returnPending: false,
                    coverVisible: true,
                    expectedCoverWindow: coverWindow,
                )

                store.send(.applicationPhaseChanged(.background))
                try await awaitCoreAnimationCommit()
                NotificationCenter.default.post(
                    name: UIScene.didEnterBackgroundNotification,
                    object: host.scene,
                )
                #expect(store.state.applicationReturnPending)
                #expect(store.state.autoLockBackgroundStartedAt == start)
                #expect(store.state.autoLockTimeoutAtBackground == .seconds(30))
                try expectRootPrivacyState(
                    host,
                    phase: .authenticated,
                    returnPending: true,
                    coverVisible: true,
                    expectedCoverWindow: coverWindow,
                )

                clock.withValue { $0 = start.advanced(by: .seconds(9)) }
                store.send(.applicationPhaseChanged(.active))
                try await awaitCoreAnimationCommit()
                #expect(store.state.vault.phase == .authenticated)
                #expect(store.state.applicationReturnPending == false)
                #expect(coverWindow.isHidden == false)
                try expectRootPrivacyState(
                    host,
                    phase: .authenticated,
                    returnPending: false,
                    coverVisible: true,
                    expectedCoverWindow: coverWindow,
                )
                try await postSceneLifecycleNotificationAndAwaitKeyWindow(
                    UIScene.didActivateNotification,
                    target: host.window,
                    in: host,
                    description: "Primary window becomes key after a validated return",
                )
                try expectRootPrivacyState(
                    host,
                    phase: .authenticated,
                    returnPending: false,
                    coverVisible: false,
                )

                let secondBackgroundStart = start.advanced(by: .seconds(10))
                clock.withValue { $0 = secondBackgroundStart }
                store.send(.applicationPhaseChanged(.background))
                #expect(store.state.applicationReturnPending)
                let secondTransition = try await deactivateAndAwaitPrivacyCover(in: host)
                let secondCoverWindow = secondTransition.coverWindow
                #expect(secondCoverWindow === coverWindow)
                NotificationCenter.default.post(
                    name: UIScene.didEnterBackgroundNotification,
                    object: host.scene,
                )
                try await awaitCoreAnimationCommit()
                #expect(store.state.autoLockBackgroundStartedAt == secondBackgroundStart)
                #expect(store.state.autoLockTimeoutAtBackground == .seconds(30))

                clock.withValue { $0 = secondBackgroundStart.advanced(by: .seconds(31)) }
                store.send(.applicationPhaseChanged(.active))
                try await awaitCoreAnimationCommit()
                #expect(store.state.vault.phase == .locked)
                #expect(store.state.applicationReturnPending == false)
                try expectRootPrivacyState(
                    host,
                    phase: .locked,
                    returnPending: false,
                    coverVisible: true,
                    expectedCoverWindow: coverWindow,
                )
                try await postSceneLifecycleNotificationAndAwaitKeyWindow(
                    UIScene.didActivateNotification,
                    target: host.window,
                    in: host,
                    description: "Primary window becomes key after auto-lock expiry",
                )
                try expectRootPrivacyState(
                    host,
                    phase: .locked,
                    returnPending: false,
                    coverVisible: false,
                )

                try await unmountRootPrivacyHost(host)
            } catch {
                try? await unmountRootPrivacyHost(host)
                throw error
            }
        }

        @Test("Root presentation content snapshots cover primary shell states")
        func rootPresentationSnapshotsCoverPrimaryShellStates() async throws {
            for layout in RootPrivacySnapshotLayout.allCases {
                let lockedClock = LockIsolated(ContinuousClock.now)
                let lockedPersistenceLoad = CalculatorPersistenceLoadSignal()
                let (lockedStore, removeLockedDefaults) = try makeRootStore(
                    phase: .locked,
                    clock: lockedClock,
                    calculatorPersistenceLoad: lockedPersistenceLoad,
                )
                defer { removeLockedDefaults() }
                try await assertRootPresentationSnapshotState(
                    store: lockedStore,
                    layout: layout,
                    phase: .locked,
                    name: "root-content-v1-calculator",
                    calculatorPersistenceLoad: lockedPersistenceLoad,
                )

                let (authenticatedStore, removeAuthenticatedDefaults) = try makeRootStore(
                    phase: .authenticated,
                    clock: LockIsolated(ContinuousClock.now),
                )
                defer { removeAuthenticatedDefaults() }
                try await assertRootPresentationSnapshotState(
                    store: authenticatedStore,
                    layout: layout,
                    phase: .authenticated,
                    name: "root-content-v1-library",
                )

                let resumedStart = ContinuousClock.now
                let resumedClock = LockIsolated(resumedStart)
                let (resumedStore, removeResumedDefaults) = try makeRootStore(
                    phase: .authenticated,
                    clock: resumedClock,
                )
                defer { removeResumedDefaults() }
                await prepareRootSnapshotLibrary(resumedStore)
                resumedStore.send(.applicationPhaseChanged(.background))
                resumedClock.withValue { $0 = resumedStart.advanced(by: .seconds(9)) }
                resumedStore.send(.applicationPhaseChanged(.active))
                #expect(resumedStore.state.vault.phase == .authenticated)
                #expect(!resumedStore.state.applicationReturnPending)
                try await assertRootPresentationSnapshotState(
                    store: resumedStore,
                    layout: layout,
                    phase: .authenticated,
                    name: "root-content-v1-library",
                )

                let expiredStart = ContinuousClock.now
                let expiredClock = LockIsolated(expiredStart)
                let expiredPersistenceLoad = CalculatorPersistenceLoadSignal()
                let (expiredStore, removeExpiredDefaults) = try makeRootStore(
                    phase: .authenticated,
                    clock: expiredClock,
                    calculatorPersistenceLoad: expiredPersistenceLoad,
                )
                defer { removeExpiredDefaults() }
                await prepareRootSnapshotLibrary(expiredStore)
                expiredStore.send(.applicationPhaseChanged(.background))
                expiredClock.withValue { $0 = expiredStart.advanced(by: .seconds(31)) }
                expiredStore.send(.applicationPhaseChanged(.active))
                #expect(expiredStore.state.vault.phase == .locked)
                #expect(!expiredStore.state.applicationReturnPending)
                try await assertRootPresentationSnapshotState(
                    store: expiredStore,
                    layout: layout,
                    phase: .locked,
                    name: "root-content-v1-calculator",
                    calculatorPersistenceLoad: expiredPersistenceLoad,
                )
            }
        }

        private func makeRootStore(
            phase: VaultFeaturePhase,
            clock: LockIsolated<ContinuousClock.Instant>,
            calculatorPersistenceLoad: CalculatorPersistenceLoadSignal? = nil,
        ) throws -> (
            store: StoreOf<RootFeature>,
            removePersistentDomain: () -> Void,
        ) {
            var vault = VaultFeature.State(phase: phase, configuredKind: .pin)
            vault.sessionSettings = VaultSessionSettings(autoLockTimeout: .seconds30)
            vault.sessionSettingsLoaded = true
            let suiteName = "ScenePrivacySnapshots.\(UUID().uuidString)"
            let defaults = try #require(UserDefaults(suiteName: suiteName))
            defaults.removePersistentDomain(forName: suiteName)

            let store = withDependencies {
                $0.defaultAppStorage = defaults
                $0.uuid = .incrementing
                $0.vaultCredential.loadConfiguration = { nil }
                $0.vaultCredential.verify = { _ in .succeeded }
                $0.calculatorPersistence.load = {
                    calculatorPersistenceLoad?.loadStarted()
                    defer { calculatorPersistenceLoad?.loadReturned() }
                    return nil
                }
                $0.calculatorPersistence.save = { _ in }
                $0.vaultSessionClock.now = { clock.value }
                $0.vaultSessionSettings.load = {
                    VaultSessionSettings(autoLockTimeout: .seconds30)
                }
                $0.browserOpenTabsSession.load = { .missing }
                $0.browserSettings.load = { .init() }
                $0.browserLibrary.loadBookmarks = { [] }
                $0.browserLibrary.loadHistory = { [] }
                $0.browserClipboard.readHTTPURL = { nil }
                $0.browserWebKit = BrowserWebKitClient(
                    execute: { _ in },
                    events: { AsyncStream { $0.finish() } },
                )
                $0.mediaLibrary.loadAssets = { [] }
                $0.mediaLibrary.resourceData = { _ in Data() }
            } operation: {
                RootComposition.makeStore(vault: vault)
            }
            return (
                store: store,
                removePersistentDomain: {
                    defaults.removePersistentDomain(forName: suiteName)
                },
            )
        }

        private func expectRootPrivacyState(
            _ host: ScenePrivacyCoverTestHost,
            phase: VaultFeaturePhase,
            returnPending: Bool,
            coverVisible: Bool,
            expectedCoverWindow: UIWindow? = nil,
        ) throws {
            let store = try #require(host.model.rootStore)
            #expect(store.state.vault.phase == phase)
            #expect(store.state.applicationReturnPending == returnPending)
            if phase == .authenticated {
                #expect(store.state.vault.shell.library.isLoading == false)
            }

            if coverVisible {
                let coverWindow = try #require(privacyCoverWindow(in: host))
                let primaryDecoy = try #require(primaryDecoy(in: host))
                if let expectedCoverWindow {
                    #expect(coverWindow === expectedCoverWindow)
                }
                #expect(coverWindow.windowScene === host.scene)
                #expect(coverWindow.windowLevel > host.window.windowLevel)
                #expect(coverWindow.isHidden == false)
                #expect(coverWindow.isKeyWindow)
                #expect(coverWindow.rootViewController?.view.accessibilityLabel == "Calculator")
                #expect(primaryDecoy.superview === host.window)
                #expect(primaryDecoy.isHidden == false)
                #expect(host.window.accessibilityElementsHidden)
                #expect(host.window.isKeyWindow == false)
            } else {
                if let coverWindow = privacyCoverWindow(in: host) {
                    #expect(coverWindow.isHidden)
                    #expect(coverWindow.isKeyWindow == false)
                }
                if let primaryDecoy = primaryDecoy(in: host) {
                    #expect(primaryDecoy.isHidden)
                }
                #expect(host.window.accessibilityElementsHidden == host.initialAccessibilityElementsHidden)
                #expect(host.window.isKeyWindow == host.wasKeyWindow)
            }
        }

        private func expectRootPrivacyCoverAttached(
            in host: ScenePrivacyCoverTestHost,
            layout: RootPrivacySnapshotLayout,
        ) throws {
            #expect(host.window.rootViewController === host.controller)
            #expect(host.window.windowScene === host.scene)
            #expect(host.scene.activationState == .foregroundActive)
            #expect(host.scene.windows.contains { $0 === host.window })
            #expect(host.window.frame.size == layout.size)
            #expect(host.window.bounds.size == layout.size)
            #expect(host.model.horizontalSizeClass == layout.horizontalSizeClass)

            let coverWindow = try #require(privacyCoverWindow(in: host))
            let coverController = try #require(coverWindow.rootViewController)
            #expect(coverController.isViewLoaded)
            let coverView = try #require(coverController.viewIfLoaded)
            let primaryDecoy = try #require(primaryDecoy(in: host))
            #expect(coverWindow.windowScene === host.scene)
            #expect(coverWindow.isHidden)
            #expect(coverWindow.isKeyWindow == false)
            #expect(!coverWindow.bounds.isEmpty)
            #expect(!coverView.frame.isEmpty)
            #expect(!coverView.bounds.isEmpty)
            #expect(coverView.isUserInteractionEnabled)
            #expect(coverView.isAccessibilityElement)
            #expect(!coverView.accessibilityElementsHidden)
            #expect(coverView.accessibilityViewIsModal)
            #expect(coverView.accessibilityTraits == .staticText)
            #expect(primaryDecoy.superview === host.window)
            #expect(primaryDecoy.isHidden)
            #expect(primaryDecoy.frame == host.window.bounds)
            #expect(!primaryDecoy.frame.isEmpty)
            #expect(!primaryDecoy.bounds.isEmpty)
        }

        /// Asserts the root state and snapshots its production content at the requested layout.
        private func assertRootPresentationSnapshotState(
            store: StoreOf<RootFeature>,
            layout: RootPrivacySnapshotLayout,
            phase: VaultFeaturePhase,
            name: String,
            calculatorPersistenceLoad: CalculatorPersistenceLoadSignal? = nil,
        ) async throws {
            await prepareRootSnapshotLibrary(store)
            guard phase == .locked || phase == .authenticated else {
                Issue.record("Root content snapshots require a locked or authenticated vault")
                return
            }

            #expect(store.state.vault.phase == phase)
            if phase == .authenticated {
                #expect(store.state.vault.shell.selectedTab == .library)
                #expect(store.state.vault.shell.library.assets.isEmpty)
                #expect(!store.state.vault.shell.library.isLoading)
                #expect(!store.state.vault.shell.library.isImporting)
                #expect(!store.state.vault.shell.library.isPickerPresented)
                #expect(!store.state.vault.shell.library.isSessionLocked)
                #expect(store.state.vault.shell.library.error == nil)
                #expect(!store.state.vault.shell.settingsPresented)
            }

            try await awaitCoreAnimationCommit()
            let host = try await makeRootPrivacyHost(
                store: store,
                frame: CGRect(origin: .zero, size: layout.size),
                horizontalSizeClass: layout.horizontalSizeClass,
                scenePhase: .active,
            )
            do {
                if let calculatorPersistenceLoad {
                    try await awaitRootPrivacyHostEvent(
                        calculatorPersistenceLoad.started,
                        continuation: calculatorPersistenceLoad.startedContinuation,
                        event: "root snapshot calculator persistence load starts",
                    )
                    try await awaitRootPrivacyHostEvent(
                        calculatorPersistenceLoad.returned,
                        continuation: calculatorPersistenceLoad.returnedContinuation,
                        event: "root snapshot calculator persistence load returns",
                    )
                }
                try expectRootPrivacyState(
                    host,
                    phase: phase,
                    returnPending: false,
                    coverVisible: false,
                )
                try await awaitCoreAnimationCommit()
                let snapshotName = "\(name)-\(layout.snapshotName)"
                if phase == .locked {
                    assertRootPresentationContentSnapshot(
                        of: store.decoySession.rootView,
                        layout: layout,
                        name: snapshotName,
                    )
                } else {
                    assertRootPresentationContentSnapshot(
                        of: MediaLibraryView(
                            store: store.scope(
                                state: \.vault.shell.library,
                                action: \.vault.shell.library,
                            ),
                        ),
                        layout: layout,
                        name: snapshotName,
                    )
                }
            } catch {
                try? await unmountRootPrivacyHost(host)
                throw error
            }
            try await unmountRootPrivacyHost(host)
        }

        private func assertRootPresentationContentSnapshot(
            of content: some View,
            layout: RootPrivacySnapshotLayout,
            name: String,
        ) {
            assertSnapshot(
                of: content
                    .environment(\.scenePhase, .active)
                    .environment(\.horizontalSizeClass, layout.horizontalSizeClass)
                    .environment(\.colorScheme, .light),
                as: .image(
                    layout: .device(config: layout.imageConfiguration),
                    traits: layout.imageConfiguration.traits,
                ),
                named: name,
            )
        }

        private func prepareRootSnapshotLibrary(_ store: StoreOf<RootFeature>) async {
            guard store.state.vault.phase == .authenticated else {
                return
            }

            await store.send(.vault(.shell(.library(.task)))).finish()
        }

        @MainActor
        private struct RootPrivacyPrimaryDecoyState: Sendable {
            let isPresent: Bool
            let isHidden: Bool
            let alpha: CGFloat
            let isOpaque: Bool
            let backgroundColorAlpha: CGFloat?
            let frame: CGRect
            let bounds: CGRect
            let superviewIsHostWindow: Bool
            let isTopmostSubview: Bool

            init(decoy: UIView?, hostWindow: UIWindow) {
                guard let decoy else {
                    isPresent = false
                    isHidden = true
                    alpha = 0
                    isOpaque = false
                    backgroundColorAlpha = nil
                    frame = .zero
                    bounds = .zero
                    superviewIsHostWindow = false
                    isTopmostSubview = false
                    return
                }

                isPresent = true
                isHidden = decoy.isHidden
                alpha = decoy.alpha
                isOpaque = decoy.isOpaque
                backgroundColorAlpha = decoy.backgroundColor?.cgColor.alpha
                frame = decoy.frame
                bounds = decoy.bounds
                superviewIsHostWindow = decoy.superview === hostWindow
                isTopmostSubview = hostWindow.subviews.last === decoy
            }
        }

        private struct RootPrivacyCoverTransition {
            let coverWindow: UIWindow
            let primaryDecoyAtKey: RootPrivacyPrimaryDecoyState
        }

        /// Awaits the cover window's key event before capturing protected-state snapshots.
        private func deactivateAndAwaitPrivacyCover(
            in host: ScenePrivacyCoverTestHost,
        ) async throws -> RootPrivacyCoverTransition {
            let scene = host.scene
            let coverWindow = try #require(privacyCoverWindow(in: host))
            #expect(coverWindow.windowScene === scene)
            #expect(coverWindow.isHidden)

            let (keyWindowEvents, continuation) = AsyncStream<RootPrivacyPrimaryDecoyState>.makeStream(
                bufferingPolicy: .bufferingNewest(1),
            )
            let observer = ScenePrivacyNotificationObserver(
                token: NotificationCenter.default.addObserver(
                    forName: UIWindow.didBecomeKeyNotification,
                    object: coverWindow,
                    queue: .main,
                ) { _ in
                    let state = MainActor.assumeIsolated { () -> RootPrivacyPrimaryDecoyState? in
                        guard coverWindow.windowScene === scene,
                              !coverWindow.isHidden,
                              coverWindow.isKeyWindow
                        else {
                            return nil
                        }

                        return RootPrivacyPrimaryDecoyState(
                            decoy: primaryDecoy(in: host),
                            hostWindow: host.window,
                        )
                    }
                    if let state {
                        continuation.yield(state)
                    }
                },
            )
            continuation.onTermination = { _ in observer.remove() }
            let timeout = Task {
                do {
                    try await Task.sleep(for: .seconds(10))
                } catch {
                    return
                }
                continuation.finish()
            }
            defer {
                timeout.cancel()
                continuation.finish()
            }

            let primaryDecoyAtKey = try await withTaskCancellationHandler {
                var iterator = keyWindowEvents.makeAsyncIterator()
                NotificationCenter.default.post(
                    name: UIScene.willDeactivateNotification,
                    object: scene,
                )
                guard let primaryDecoyAtKey = await iterator.next() else {
                    throw ScenePrivacyCallbackTimeout(
                        event: "Scene privacy cover becomes key after deactivation",
                    )
                }

                return primaryDecoyAtKey
            } onCancel: {
                continuation.finish()
            }

            #expect(coverWindow.windowScene === scene)
            #expect(coverWindow.isHidden == false)
            #expect(coverWindow.isKeyWindow)
            return RootPrivacyCoverTransition(
                coverWindow: coverWindow,
                primaryDecoyAtKey: primaryDecoyAtKey,
            )
        }

        private func postSceneLifecycleNotificationAndAwaitKeyWindow(
            _ notificationName: Notification.Name,
            target: UIWindow,
            in host: ScenePrivacyCoverTestHost,
            description: String,
        ) async throws {
            let scene = host.scene
            #expect(target.windowScene === scene)
            let (keyWindowEvents, continuation) = AsyncStream<Void>.makeStream(
                bufferingPolicy: .bufferingNewest(1),
            )
            let observer = ScenePrivacyNotificationObserver(
                token: NotificationCenter.default.addObserver(
                    forName: UIWindow.didBecomeKeyNotification,
                    object: nil,
                    queue: .main,
                ) { notification in
                    guard let window = notification.object as? UIWindow,
                          window === target,
                          window.windowScene === scene
                    else {
                        return
                    }

                    continuation.yield(())
                },
            )
            continuation.onTermination = { _ in observer.remove() }
            // Lifecycle notifications drive progress; the timer only bounds a missing callback.
            let timeout = Task {
                do {
                    try await Task.sleep(for: .seconds(10))
                } catch {
                    return
                }
                continuation.finish()
            }
            defer {
                timeout.cancel()
                continuation.finish()
            }

            try await withTaskCancellationHandler {
                try await confirmation(
                    Comment(stringLiteral: description),
                    expectedCount: 1,
                ) { confirmed in
                    NotificationCenter.default.post(name: notificationName, object: scene)
                    var iterator = keyWindowEvents.makeAsyncIterator()
                    guard await iterator.next() != nil else {
                        throw ScenePrivacyCallbackTimeout(event: description)
                    }

                    confirmed()
                }
            } onCancel: {
                continuation.finish()
            }
        }

        private func makeHost(
            isCovered: Bool,
            surface: ScenePrivacyCoverTestSurface = .library,
            initialSceneIsActiveOverride: Bool? = nil,
            frame: CGRect = CGRect(x: 0, y: 0, width: 390, height: 844),
            horizontalSizeClass: UserInterfaceSizeClass = .compact,
        ) async throws -> ScenePrivacyCoverTestHost {
            let host = try mountHost(
                isCovered: isCovered,
                surface: surface,
                initialSceneIsActiveOverride: initialSceneIsActiveOverride,
                frame: frame,
                rootStore: nil,
                horizontalSizeClass: horizontalSizeClass,
            )
            do {
                try await awaitCoverageUpdate(in: host, expected: isCovered) {
                    host.model.showsCover = true
                    host.model.revision = 1
                    host.controller.view.setNeedsLayout()
                    host.window.layoutIfNeeded()
                    host.controller.view.layoutIfNeeded()
                }
                _ = try #require(privacyCoverWindow(in: host))
                _ = try #require(primaryDecoy(in: host))
            } catch {
                _ = await unmount(host)
                throw error
            }
            return host
        }

        private func makeRootPrivacyHost(
            store: StoreOf<RootFeature>,
            frame: CGRect,
            horizontalSizeClass: UserInterfaceSizeClass,
            scenePhase: ScenePhase,
        ) async throws -> ScenePrivacyCoverTestHost {
            let window = UIKitTestSupport.makeWindow(frame: frame)
            let scene = try #require(window.windowScene)
            let baselineWindowIDs = Set(scene.windows.map(ObjectIdentifier.init))
            let isCovered = scenePhase != .active || store.state.applicationReturnPending
            let model = ScenePrivacyCoverTestModel(
                isCovered: isCovered,
                showsCover: true,
                surface: .library,
                initialSceneIsActiveOverride: nil,
                rootStore: store,
                horizontalSizeClass: horizontalSizeClass,
            )
            model.scenePhase = scenePhase

            let rootView = RootView(store: store)
                .environment(\.scenePhase, scenePhase)
                .environment(\.horizontalSizeClass, horizontalSizeClass)
            let rootViewDisappearance = RootPrivacySnapshotViewDisappearance()
            let instrumentedRootView = rootView.onDisappear {
                rootViewDisappearance.signal()
            }
            let (appearanceEvents, appearanceContinuation) = AsyncStream<Void>.makeStream(
                bufferingPolicy: .bufferingNewest(1),
            )
            let controller = RootPrivacySnapshotHostingController(rootView: AnyView(instrumentedRootView))
            controller.onDidAppear = { appearanceContinuation.yield(()) }
            window.rootViewController = controller
            controller.view.frame = window.bounds
            controller.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            window.makeKeyAndVisible()
            window.setNeedsLayout()
            controller.view.setNeedsLayout()
            window.layoutIfNeeded()
            controller.view.layoutIfNeeded()

            let host = ScenePrivacyCoverTestHost(
                window: window,
                controller: controller,
                model: model,
                scene: scene,
                baselineWindowIDs: baselineWindowIDs,
                initialAccessibilityElementsHidden: window.accessibilityElementsHidden,
                wasKeyWindow: window.isKeyWindow,
                rootViewDisappearance: rootViewDisappearance,
            )
            #expect(scene.activationState == .foregroundActive)
            do {
                try await awaitRootPrivacyHostEvent(
                    appearanceEvents,
                    continuation: appearanceContinuation,
                    event: "root snapshot host appearance",
                )
            } catch {
                try? await unmountRootPrivacyHost(host)
                throw error
            }
            controller.onDidAppear = nil
            return host
        }

        private func unmountRootPrivacyHost(_ host: ScenePrivacyCoverTestHost) async throws {
            guard let controller = host.controller as? RootPrivacySnapshotHostingController else {
                RootPrivacySnapshotHostQuarantine.retain(host)
                throw ScenePrivacyCallbackTimeout(event: "root snapshot host controller")
            }
            guard let rootViewDisappearance = host.rootViewDisappearance else {
                RootPrivacySnapshotHostQuarantine.retain(host)
                throw ScenePrivacyCallbackTimeout(event: "root snapshot SwiftUI content")
            }

            host.model.rootStore = nil
            host.model.scenePhase = .active
            host.model.isCovered = false
            host.model.revision = .max
            host.model.showsCover = false
            controller.rootView = AnyView(Color.clear)
            do {
                try await awaitRootPrivacyHostEvent(
                    rootViewDisappearance.events,
                    continuation: rootViewDisappearance.continuation,
                    event: "root snapshot SwiftUI content disappearance",
                )
                try await awaitCoreAnimationCommit()
            } catch {
                RootPrivacySnapshotHostQuarantine.retain(host)
                throw error
            }
            RootPrivacySnapshotHostQuarantine.retain(host)
            try await awaitCoreAnimationCommit()

            #expect(host.window.isKeyWindow == host.wasKeyWindow)
            #expect(privacyCoverWindows(in: host).isEmpty)
            #expect(primaryDecoy(in: host) == nil)
        }

        private func awaitRootPrivacyHostEvent(
            _ events: AsyncStream<Void>,
            continuation: AsyncStream<Void>.Continuation,
            event: String,
        ) async throws {
            let timeout = Task {
                do {
                    try await Task.sleep(for: .seconds(10))
                } catch {
                    return
                }
                continuation.finish()
            }
            defer {
                timeout.cancel()
                continuation.finish()
            }

            try await withTaskCancellationHandler {
                var iterator = events.makeAsyncIterator()
                guard await iterator.next() != nil else {
                    throw ScenePrivacyCallbackTimeout(event: event)
                }
            } onCancel: {
                continuation.finish()
            }
        }

        private func awaitCoreAnimationCommit() async throws {
            let (events, continuation) = AsyncStream<Void>.makeStream(
                bufferingPolicy: .bufferingNewest(1),
            )
            let timeout = Task {
                do {
                    try await Task.sleep(for: .seconds(10))
                } catch {
                    return
                }
                continuation.finish()
            }
            defer {
                timeout.cancel()
                continuation.finish()
            }

            CATransaction.begin()
            CATransaction.setCompletionBlock {
                continuation.yield(())
            }
            CATransaction.commit()

            try await withTaskCancellationHandler {
                var iterator = events.makeAsyncIterator()
                guard await iterator.next() != nil else {
                    if Task.isCancelled {
                        throw CancellationError()
                    }
                    throw ScenePrivacyCallbackTimeout(event: "Core Animation transaction completion")
                }
            } onCancel: {
                continuation.finish()
            }
        }

        private func mountHost(
            isCovered: Bool,
            surface: ScenePrivacyCoverTestSurface,
            initialSceneIsActiveOverride: Bool?,
            frame: CGRect,
            rootStore: StoreOf<RootFeature>?,
            horizontalSizeClass: UserInterfaceSizeClass,
        ) throws -> ScenePrivacyCoverTestHost {
            let window = UIKitTestSupport.makeWindow(
                frame: frame,
            )
            let scene = try #require(window.windowScene)
            let baselineWindowIDs = Set(scene.windows.map(ObjectIdentifier.init))
            let model = ScenePrivacyCoverTestModel(
                isCovered: isCovered,
                showsCover: false,
                surface: surface,
                initialSceneIsActiveOverride: initialSceneIsActiveOverride,
                rootStore: rootStore,
                horizontalSizeClass: horizontalSizeClass,
            )
            let controller = RootPrivacySnapshotHostingController(
                rootView: AnyView(ScenePrivacyCoverHarness(model: model)),
            )
            window.rootViewController = controller
            controller.view.frame = window.bounds
            controller.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            window.makeKeyAndVisible()
            window.layoutIfNeeded()
            controller.view.layoutIfNeeded()

            let host = ScenePrivacyCoverTestHost(
                window: window,
                controller: controller,
                model: model,
                scene: scene,
                baselineWindowIDs: baselineWindowIDs,
                initialAccessibilityElementsHidden: window.accessibilityElementsHidden,
                wasKeyWindow: window.isKeyWindow,
                rootViewDisappearance: nil,
            )

            #expect(scene.activationState == .foregroundActive)
            return host
        }

        private func unmount(_ host: ScenePrivacyCoverTestHost) async -> Bool {
            guard let controller = host.controller as? RootPrivacySnapshotHostingController else {
                RootPrivacySnapshotHostQuarantine.retain(host)
                return false
            }

            let (disappearanceEvents, disappearanceContinuation) = AsyncStream<Void>.makeStream(
                bufferingPolicy: .bufferingNewest(1),
            )
            controller.onDidDisappear = { disappearanceContinuation.yield(()) }
            host.model.rootStore = nil
            host.model.scenePhase = .active
            host.model.isCovered = false
            host.model.revision = .max
            host.model.showsCover = false
            host.window.isHidden = true

            do {
                try await awaitRootPrivacyHostEvent(
                    disappearanceEvents,
                    continuation: disappearanceContinuation,
                    event: "privacy cover host disappearance",
                )
                controller.onDidDisappear = nil
                try await awaitCoreAnimationCommit()
            } catch {
                RootPrivacySnapshotHostQuarantine.retain(host)
                return false
            }

            host.window.rootViewController = nil

            #expect(host.window.accessibilityElementsHidden == host.initialAccessibilityElementsHidden)
            #expect(host.window.isKeyWindow == host.wasKeyWindow)
            #expect(privacyCoverWindows(in: host).isEmpty)
            #expect(primaryDecoy(in: host) == nil)
            return true
        }

        private func quarantineHostIfNeeded(
            _ host: ScenePrivacyCoverTestHost,
            didUnmount: Bool,
        ) {
            guard !didUnmount else {
                return
            }

            host.window.isHidden = true
            RootPrivacySnapshotHostQuarantine.retain(host)
        }

        private func setCoverage(
            of host: ScenePrivacyCoverTestHost,
            coverWindow: UIWindow,
            isCovered: Bool,
            revision: Int,
        ) async throws {
            try await awaitCoverageUpdate(in: host, expected: isCovered) {
                host.model.isCovered = isCovered
                host.model.revision = revision
                host.controller.view.setNeedsLayout()
                host.window.layoutIfNeeded()
                host.controller.view.layoutIfNeeded()
            }
            expectPrivacyCoverWindow(coverWindow, in: host)
            expectLastCoverageUpdate(isCovered, from: host)
            print("ScenePrivacyCover.updateUIView Bool trace: \(host.model.receivedUpdates)")
        }

        private func awaitCoverageUpdate(
            in host: ScenePrivacyCoverTestHost,
            expected: Bool,
            operation: () -> Void,
        ) async throws {
            let (updates, continuation) = AsyncStream<Bool>.makeStream(
                bufferingPolicy: .bufferingNewest(1),
            )
            host.model.onCoverageUpdate = { continuation.yield($0) }
            defer {
                host.model.onCoverageUpdate = nil
                continuation.finish()
            }
            // A missing SwiftUI update becomes a bounded test failure, not a hang.
            let timeout = Task {
                do {
                    try await Task.sleep(for: .seconds(10))
                } catch {
                    return
                }
                continuation.finish()
            }
            defer { timeout.cancel() }

            try await withTaskCancellationHandler {
                try await confirmation(
                    "Scene privacy coverage updates to \(expected)",
                    expectedCount: 1,
                ) { confirmed in
                    operation()
                    var iterator = updates.makeAsyncIterator()
                    while let value = await iterator.next() {
                        guard value == expected else {
                            continue
                        }

                        confirmed()
                        return
                    }
                    throw ScenePrivacyCallbackTimeout(event: "coverage update to \(expected)")
                }
            } onCancel: {
                continuation.finish()
            }
        }

        private func privacyCoverWindows(in host: ScenePrivacyCoverTestHost) -> [UIWindow] {
            host.scene.windows.filter {
                $0.accessibilityIdentifier == Self.scenePrivacyCoverWindowAccessibilityIdentifier
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
        ) async throws {
            let host = try await makeHost(isCovered: false, surface: surface)
            var didUnmount = false
            defer { quarantineHostIfNeeded(host, didUnmount: didUnmount) }

            let coverWindow = try #require(privacyCoverWindow(in: host))
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
            try expectCoverWindowHitTestResolvesToVisibleCover(
                at: coverPoint,
                in: coverWindow,
                primaryWindow: host.window,
            )
            didUnmount = await unmount(host)
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

        private func expectCoverWindowHitTestResolvesToVisibleCover(
            at coverPoint: CGPoint,
            in coverWindow: UIWindow,
            primaryWindow: UIWindow,
        ) throws {
            let coverView = try #require(coverWindow.rootViewController?.view)
            let windowScene = try #require(coverWindow.windowScene)
            #expect(windowScene.windows.contains { $0 === coverWindow })
            #expect(primaryWindow.windowScene === windowScene)
            #expect(!coverWindow.isHidden)
            #expect(coverWindow.isKeyWindow)
            #expect(coverWindow.alpha > 0)
            #expect(coverWindow.isUserInteractionEnabled)
            #expect(coverWindow.bounds.contains(coverPoint))
            #expect(coverWindow.point(inside: coverPoint, with: nil))
            #expect(coverView.window === coverWindow)
            #expect(coverView.isUserInteractionEnabled)
            #expect(coverView.isAccessibilityElement)
            #expect(!coverView.accessibilityElementsHidden)
            #expect(coverView.accessibilityViewIsModal)
            #expect(coverWindow.windowLevel > primaryWindow.windowLevel)
            let coverViewPoint = coverView.convert(coverPoint, from: coverWindow)
            #expect(coverView.point(inside: coverViewPoint, with: nil))

            let hitView = try #require(coverWindow.hitTest(coverPoint, with: nil))
            #expect(hitView === coverView || hitView.isDescendant(of: coverView))
            #expect(hasVisibleInteractiveAncestry(from: hitView, through: coverView))
            #expect(hitView.window === coverWindow)
            let hitViewPoint = hitView.convert(coverPoint, from: coverWindow)
            #expect(hitView.point(inside: hitViewPoint, with: nil))
        }

        private func hasVisibleInteractiveAncestry(
            from view: UIView,
            through ancestor: UIView,
        ) -> Bool {
            var currentView: UIView? = view
            var effectiveAlpha: CGFloat = 1
            while let currentAncestor = currentView {
                guard !currentAncestor.isHidden, currentAncestor.isUserInteractionEnabled else {
                    return false
                }

                effectiveAlpha *= currentAncestor.alpha
                if currentAncestor === ancestor {
                    return effectiveAlpha > 0.01
                }
                currentView = currentAncestor.superview
            }
            return false
        }

        private func expectLastCoverageUpdate(_ expected: Bool, from host: ScenePrivacyCoverTestHost) {
            #expect(host.model.receivedUpdates.last == expected)
        }
    }
}

/// Holds a notification token so its stream can remove the observer when it ends.
private struct ScenePrivacyCallbackTimeout: Error, CustomStringConvertible {
    let event: String

    var description: String {
        "Timed out waiting for the test event: \(event)."
    }
}

private final class ScenePrivacyNotificationObserver: @unchecked Sendable {
    private let token: NSObjectProtocol

    init(token: NSObjectProtocol) {
        self.token = token
    }

    func remove() {
        NotificationCenter.default.removeObserver(token)
    }
}

@MainActor
@Observable
private final class ScenePrivacyCoverTestModel {
    var isCovered: Bool
    var revision: Int
    var showsCover: Bool
    var scenePhase: ScenePhase
    var rootStore: StoreOf<RootFeature>?
    let surface: ScenePrivacyCoverTestSurface
    let initialSceneIsActiveOverride: Bool?
    let horizontalSizeClass: UserInterfaceSizeClass
    @ObservationIgnored
    var receivedUpdates: [Bool] = []
    @ObservationIgnored
    var onCoverageUpdate: (@MainActor (Bool) -> Void)?

    init(
        isCovered: Bool,
        showsCover: Bool,
        surface: ScenePrivacyCoverTestSurface,
        initialSceneIsActiveOverride: Bool?,
        rootStore: StoreOf<RootFeature>?,
        horizontalSizeClass: UserInterfaceSizeClass,
    ) {
        self.isCovered = isCovered
        revision = 0
        self.showsCover = showsCover
        scenePhase = .active
        self.rootStore = rootStore
        self.surface = surface
        self.initialSceneIsActiveOverride = initialSceneIsActiveOverride
        self.horizontalSizeClass = horizontalSizeClass
    }

    func recordCoverageUpdate(_ isCovered: Bool) {
        receivedUpdates.append(isCovered)
        onCoverageUpdate?(isCovered)
    }
}

/// Provides fixed dimensions and traits for phone and iPad privacy snapshots.
enum RootPrivacySnapshotLayout: CaseIterable, Sendable {
    case compactIPhone
    case regularWidthIPad

    /// Chooses sentinel geometries that fit the current simulator display.
    static var sentinelLayoutsForCurrentSimulator: [Self] {
        let modelIdentifier = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] ?? ""
        return modelIdentifier.hasPrefix("iPad") ? allCases : [.compactIPhone]
    }

    var size: CGSize {
        switch self {
        case .compactIPhone:
            CGSize(width: 320, height: 568)
        case .regularWidthIPad:
            CGSize(width: 1_024, height: 1_366)
        }
    }

    var horizontalSizeClass: UserInterfaceSizeClass {
        switch self {
        case .compactIPhone:
            .compact
        case .regularWidthIPad:
            .regular
        }
    }

    var imageConfiguration: ViewImageConfig {
        switch self {
        case .compactIPhone:
            DeterministicTestSupport.compactPhone
        case .regularWidthIPad:
            DeterministicTestSupport.regularWidthIPad
        }
    }

    var snapshotName: String {
        switch self {
        case .compactIPhone:
            "compact-iphone"
        case .regularWidthIPad:
            "regular-ipad"
        }
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
                if let rootStore = model.rootStore, rootStore.state.vault.phase == .locked {
                    rootStore.state.decoySession.rootView
                } else {
                    VStack(alignment: .leading) {
                        Text(model.surface.heading)
                        Text(model.surface.detail)
                    }
                }
                ScenePrivacyCover(
                    isCovered: model.isCovered,
                    initialSceneIsActiveOverride: model.initialSceneIsActiveOverride,
                    onCoverageUpdate: { model.recordCoverageUpdate($0) },
                )
                .frame(width: 1, height: 1)
                Text(String(model.revision))
                    .hidden()
                    .accessibilityHidden(true)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .environment(\.colorScheme, .light)
            .environment(\.horizontalSizeClass, model.horizontalSizeClass)
        } else {
            Color.clear
        }
    }
}

@MainActor
private final class RootPrivacySnapshotHostingController: UIHostingController<AnyView> {
    var onDidAppear: (() -> Void)?
    var onDidDisappear: (() -> Void)?

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        onDidAppear?()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        onDidDisappear?()
    }
}

private final class CalculatorPersistenceLoadSignal: Sendable {
    let started: AsyncStream<Void>
    let startedContinuation: AsyncStream<Void>.Continuation
    let returned: AsyncStream<Void>
    let returnedContinuation: AsyncStream<Void>.Continuation

    init() {
        (started, startedContinuation) = AsyncStream<Void>.makeStream(
            bufferingPolicy: .bufferingNewest(1),
        )
        (returned, returnedContinuation) = AsyncStream<Void>.makeStream(
            bufferingPolicy: .bufferingNewest(1),
        )
    }

    func loadStarted() {
        startedContinuation.yield(())
    }

    func loadReturned() {
        returnedContinuation.yield(())
    }
}

@MainActor
private final class RootPrivacySnapshotViewDisappearance {
    let events: AsyncStream<Void>
    let continuation: AsyncStream<Void>.Continuation

    init() {
        (events, continuation) = AsyncStream<Void>.makeStream(
            bufferingPolicy: .bufferingNewest(1),
        )
    }

    func signal() {
        continuation.yield(())
    }
}

@MainActor
private struct ScenePrivacyCoverTestHost {
    let window: UIWindow
    let controller: UIViewController
    let model: ScenePrivacyCoverTestModel
    let scene: UIWindowScene
    let baselineWindowIDs: Set<ObjectIdentifier>
    let initialAccessibilityElementsHidden: Bool
    let wasKeyWindow: Bool
    let rootViewDisappearance: RootPrivacySnapshotViewDisappearance?
}

@MainActor
private enum RootPrivacySnapshotHostQuarantine {
    private(set) static var retainedHosts: [ScenePrivacyCoverTestHost] = []

    static func retain(_ host: ScenePrivacyCoverTestHost) {
        guard !retainedHosts.contains(where: { $0.window === host.window }) else {
            return
        }

        retainedHosts.append(host)
    }
}
