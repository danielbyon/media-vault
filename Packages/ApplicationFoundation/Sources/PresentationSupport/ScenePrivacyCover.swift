//
//  ScenePrivacyCover.swift
//  MediaVault
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//

//
// ScenePrivacyCover.swift
// MediaVault
//
// SPDX-License-Identifier: GPL-3.0-or-later
//
import CoreFoundation
import CoreGraphics
import Foundation
import ObjectiveC
import QuartzCore
import SwiftUI
import UIKit

/// Adds a preloaded decoy to the primary scene window and a separate transparent interaction and accessibility barrier window.
///
/// The primary-window decoy is prepared while hidden so the system can capture
/// safe calculator content as soon as the scene deactivates. The separate window
/// covers app-owned presentations in that scene, including UIKit sheets and
/// dialogs, blocks input, and hides underlying windows from accessibility. Both
/// covers stay visible until the caller confirms that authentication and deadline
/// validation are complete. If the validated update arrives while the scene is
/// inactive, the covers remain until the scene activates.
@MainActor
public struct ScenePrivacyCover: UIViewRepresentable {
    /// Whether the caller requires the scene to stay covered.
    ///
    /// After deactivation, a `true` update confirms that the caller observed the
    /// covered state. A later `false` update authorizes revealing the scene after
    /// authentication and deadline validation complete.
    public let isCovered: Bool
    private let onCoverageUpdate: (@MainActor (Bool) -> Void)?
    private let initialSceneIsActiveOverride: Bool?

    /// Creates a scene cover that follows the application's validated privacy state.
    ///
    /// - Parameter isCovered: Whether the caller requires this scene to remain covered.
    public init(isCovered: Bool) {
        self.isCovered = isCovered
        onCoverageUpdate = nil
        initialSceneIsActiveOverride = nil
    }

    init(
        isCovered: Bool,
        initialSceneIsActiveOverride: Bool? = nil,
        onCoverageUpdate: @escaping @MainActor (Bool) -> Void,
    ) {
        self.isCovered = isCovered
        self.onCoverageUpdate = onCoverageUpdate
        self.initialSceneIsActiveOverride = initialSceneIsActiveOverride
    }

    /// Creates no separate coordinator because the anchor view owns scene lifecycle state.
    public func makeCoordinator() {}

    /// Creates the hidden anchor view that binds the cover to its exact window scene.
    ///
    /// - Parameter context: The representable context supplied by SwiftUI.
    /// - Returns: A view that manages this scene's transparent interaction and accessibility barrier.
    public func makeUIView(context _: Context) -> UIView {
        ScenePrivacyCoverAnchorView(
            isCovered: isCovered,
            initialSceneIsActiveOverride: initialSceneIsActiveOverride,
        )
    }

    /// Applies validated coverage updates to the scene window host.
    ///
    /// - Parameters:
    ///   - uiView: The anchor view previously created for this representable.
    ///   - context: The representable context supplied by SwiftUI.
    public func updateUIView(_ uiView: UIView, context _: Context) {
        guard let anchorView = uiView as? ScenePrivacyCoverAnchorView else {
            return
        }

        anchorView.update(isCovered: isCovered)
        onCoverageUpdate?(isCovered)
    }

    /// Removes lifecycle observers and the transparent interaction and accessibility barrier window when the anchor leaves the hierarchy.
    ///
    /// - Parameters:
    ///   - uiView: The anchor view being removed.
    ///   - coordinator: The coordinator created for this representable, which is unused.
    public static func dismantleUIView(_ uiView: UIView, coordinator _: Void) {
        (uiView as? ScenePrivacyCoverAnchorView)?.dismantle()
    }
}

@MainActor
private final class ScenePrivacyCoverAnchorView: UIView {
    private let host: ScenePrivacyCoverWindowHost

    init(isCovered: Bool, initialSceneIsActiveOverride: Bool?) {
        host = ScenePrivacyCoverWindowHost(
            isCovered: isCovered,
            initialSceneIsActiveOverride: initialSceneIsActiveOverride,
        )
        super.init(frame: .zero)

        isHidden = true
        isUserInteractionEnabled = false
        accessibilityElementsHidden = true
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        nil
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        host.attach(to: window?.windowScene, primaryWindow: window)
    }

    func update(isCovered: Bool) {
        host.update(isCovered: isCovered)
        host.attach(to: window?.windowScene, primaryWindow: window)
    }

    func dismantle() {
        host.dismantle()
    }
}

@MainActor
private final class ScenePrivacyCoverWindowHost: NSObject {
    private weak var scene: UIWindowScene?
    private weak var primaryWindow: UIWindow?
    private var primaryDecoyView: ScenePrivacyCoverCalculatorView?
    private var coverWindow: ScenePrivacyCoverWindow?
    private var isCoveredByCaller: Bool
    private var policy: ScenePrivacyCoverPolicy?
    private let initialSceneIsActiveOverride: Bool?
    private weak var previousKeyWindow: UIWindow?
    private var accessibilitySnapshots: [WindowAccessibilitySnapshot] = []

    init(isCovered: Bool, initialSceneIsActiveOverride: Bool?) {
        isCoveredByCaller = isCovered
        self.initialSceneIsActiveOverride = initialSceneIsActiveOverride
        super.init()
    }

    func attach(to newScene: UIWindowScene?, primaryWindow newPrimaryWindow: UIWindow?) {
        guard scene !== newScene || primaryWindow !== newPrimaryWindow else {
            return
        }

        dismantle()
        guard let newScene, let newPrimaryWindow, newPrimaryWindow.windowScene === newScene else {
            return
        }

        scene = newScene
        primaryWindow = newPrimaryWindow
        let isSceneActive =
            initialSceneIsActiveOverride
                ?? (newScene.activationState == .foregroundActive)
        policy = ScenePrivacyCoverPolicy(
            isCoveredByCaller: isCoveredByCaller,
            isSceneActive: isSceneActive,
        )

        let primaryDecoyOverlay = ScenePrivacyCoverCalculatorView()
        primaryDecoyOverlay.frame = newPrimaryWindow.bounds
        primaryDecoyOverlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        primaryDecoyOverlay.isHidden = true
        primaryDecoyOverlay.isUserInteractionEnabled = false
        primaryDecoyOverlay.isAccessibilityElement = false
        primaryDecoyOverlay.accessibilityElementsHidden = true
        primaryDecoyOverlay.accessibilityIdentifier = "MediaVault.ScenePrivacyCoverPrimaryContent"
        newPrimaryWindow.addSubview(primaryDecoyOverlay)
        newPrimaryWindow.bringSubviewToFront(primaryDecoyOverlay)
        primaryDecoyOverlay.setNeedsLayout()
        primaryDecoyOverlay.layoutIfNeeded()
        primaryDecoyView = primaryDecoyOverlay

        let window = ScenePrivacyCoverWindow(windowScene: newScene)
        window.windowLevel = .normal + 1
        window.backgroundColor = .clear
        window.isOpaque = false
        window.isUserInteractionEnabled = true
        window.alpha = 1
        window.accessibilityIdentifier = "MediaVault.ScenePrivacyCoverWindow"
        window.isHidden = true
        let coverViewController = ScenePrivacyCoverViewController()
        window.rootViewController = coverViewController
        coverViewController.loadViewIfNeeded()
        coverViewController.view.frame = window.bounds
        coverViewController.view.setNeedsLayout()
        coverViewController.view.layoutIfNeeded()
        coverWindow = window

        observeLifecycle(of: newScene)

        updateCoverVisibility()
    }

    func update(isCovered: Bool) {
        isCoveredByCaller = isCovered

        guard scene != nil else {
            return
        }

        policy?.update(isCoveredByCaller: isCovered)
        updateCoverVisibility()
    }

    func dismantle() {
        if let scene {
            removeLifecycleObservers(from: scene)
        }

        hideCover()
        for snapshot in accessibilitySnapshots {
            snapshot.restore()
        }
        accessibilitySnapshots.removeAll()
        primaryDecoyView?.removeFromSuperview()
        primaryDecoyView = nil
        primaryWindow = nil
        coverWindow?.rootViewController = nil
        coverWindow?.isHidden = true
        coverWindow?.windowScene = nil
        coverWindow = nil
        scene = nil
        policy = nil
    }

    private func observeLifecycle(of scene: UIWindowScene) {
        let center = NotificationCenter.default
        center.addObserver(
            self,
            selector: #selector(sceneWillDeactivate(_:)),
            name: UIScene.willDeactivateNotification,
            object: scene,
        )
        center.addObserver(
            self,
            selector: #selector(sceneDidEnterBackground(_:)),
            name: UIScene.didEnterBackgroundNotification,
            object: scene,
        )
        center.addObserver(
            self,
            selector: #selector(sceneDidActivate(_:)),
            name: UIScene.didActivateNotification,
            object: scene,
        )
        center.addObserver(
            self,
            selector: #selector(sceneDidDisconnect(_:)),
            name: UIScene.didDisconnectNotification,
            object: scene,
        )
    }

    private func removeLifecycleObservers(from scene: UIWindowScene) {
        let center = NotificationCenter.default
        center.removeObserver(self, name: UIScene.willDeactivateNotification, object: scene)
        center.removeObserver(self, name: UIScene.didEnterBackgroundNotification, object: scene)
        center.removeObserver(self, name: UIScene.didActivateNotification, object: scene)
        center.removeObserver(self, name: UIScene.didDisconnectNotification, object: scene)
    }

    private func isBoundSceneNotification(_ notification: Notification) -> Bool {
        guard let scene, let notificationScene = notification.object as? UIWindowScene else {
            return false
        }

        return notificationScene === scene
    }

    @objc
    private func sceneWillDeactivate(_ notification: Notification) {
        guard isBoundSceneNotification(notification) else {
            return
        }

        policy?.sceneWillDeactivate()
        updateCoverVisibility()
    }

    @objc
    private func sceneDidEnterBackground(_ notification: Notification) {
        guard isBoundSceneNotification(notification) else {
            return
        }

        policy?.sceneWillDeactivate()
        updateCoverVisibility()
    }

    @objc
    private func sceneDidActivate(_ notification: Notification) {
        guard isBoundSceneNotification(notification) else {
            return
        }

        policy?.sceneDidActivate()
        updateCoverVisibility()
    }

    @objc
    private func sceneDidDisconnect(_ notification: Notification) {
        guard isBoundSceneNotification(notification) else {
            return
        }

        dismantle()
    }

    private func showCover() {
        guard let scene, let coverWindow else {
            return
        }

        showPrimaryDecoy()
        guard coverWindow.isHidden else {
            return
        }

        previousKeyWindow = scene.windows.first(where: \.isKeyWindow)
        accessibilitySnapshots = scene.windows
            .filter { $0 !== coverWindow }
            .map(WindowAccessibilitySnapshot.init)

        for snapshot in accessibilitySnapshots {
            snapshot.window?.accessibilityElementsHidden = true
            snapshot.window?.endEditing(true)
        }

        coverWindow.makeKeyAndVisible()
        _ = coverWindow.rootViewController?.becomeFirstResponder()
    }

    private func updateCoverVisibility() {
        if policy?.shouldShowCover == true {
            showCover()
        } else {
            hideCover()
        }
    }

    private func hideCover() {
        guard let scene, let coverWindow else {
            return
        }
        guard !coverWindow.isHidden else {
            hidePrimaryDecoy()
            return
        }

        for snapshot in accessibilitySnapshots {
            snapshot.restore()
        }
        accessibilitySnapshots.removeAll()
        hidePrimaryDecoy()

        coverWindow.isHidden = true
        if let previousKeyWindow, previousKeyWindow.windowScene === scene {
            previousKeyWindow.makeKey()
        }
        previousKeyWindow = nil
    }

    private func showPrimaryDecoy() {
        guard let primaryWindow, let primaryDecoyView else {
            return
        }

        primaryDecoyView.frame = primaryWindow.bounds
        primaryWindow.bringSubviewToFront(primaryDecoyView)
        primaryDecoyView.alpha = 1
        primaryDecoyView.isOpaque = true
        primaryDecoyView.setNeedsLayout()
        primaryDecoyView.layoutIfNeeded()
        primaryDecoyView.isHidden = false
    }

    private func hidePrimaryDecoy() {
        primaryDecoyView?.isHidden = true
    }
}

@MainActor
private final class ScenePrivacyCoverWindow: UIWindow {
    override var canBecomeKey: Bool {
        true
    }
}

@MainActor
private final class ScenePrivacyCoverViewController: UIViewController {
    override func loadView() {
        let barrierView = UIView()
        barrierView.backgroundColor = .clear
        barrierView.isOpaque = false
        barrierView.isUserInteractionEnabled = true
        barrierView.isAccessibilityElement = true
        barrierView.accessibilityElementsHidden = false
        barrierView.accessibilityViewIsModal = true
        barrierView.accessibilityIdentifier = "MediaVault.ScenePrivacyCoverContent"
        barrierView.accessibilityLabel = "Calculator"
        barrierView.accessibilityTraits = .staticText

        view = barrierView
    }

    override var canBecomeFirstResponder: Bool {
        true
    }

    override func pressesBegan(_: Set<UIPress>, with _: UIPressesEvent?) {}

    override func pressesEnded(_: Set<UIPress>, with _: UIPressesEvent?) {}

    override func pressesCancelled(_: Set<UIPress>, with _: UIPressesEvent?) {}
}

/// Draws a calculator-style decoy while private scene content is covered.
///
/// The fixed labels do not accept input or appear in the accessibility tree. Their layout stays
/// inside the safe area and caps the content width on iPad.
@MainActor
final class ScenePrivacyCoverCalculatorView: UIView {
    private static let keypadGlyphs = [
        ["⌫", "AC", "%", "÷"],
        ["7", "8", "9", "×"],
        ["4", "5", "6", "−"],
        ["1", "2", "3", "+"],
        ["0", "±", ".", "="],
    ]
    private static let orangeKeyGlyphs: Set = ["÷", "×", "−", "+", "="]

    private let displayLabel = UILabel()
    private var keyLabels: [UILabel] = []

    override init(frame: CGRect) {
        super.init(frame: frame)

        backgroundColor = .systemBackground
        isOpaque = true
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        accessibilityElementsHidden = true

        displayLabel.accessibilityIdentifier = "MediaVault.ScenePrivacyCoverCalculatorDisplay"
        displayLabel.text = "0"
        displayLabel.textAlignment = .right
        displayLabel.textColor = .label
        displayLabel.isAccessibilityElement = false
        displayLabel.adjustsFontSizeToFitWidth = true
        displayLabel.minimumScaleFactor = 0.5
        addSubview(displayLabel)

        for (rowIndex, row) in Self.keypadGlyphs.enumerated() {
            for (columnIndex, glyph) in row.enumerated() {
                let keyLabel = UILabel()
                keyLabel.accessibilityIdentifier =
                    "MediaVault.ScenePrivacyCoverCalculatorKey.row.\(rowIndex).column.\(columnIndex)"
                keyLabel.text = glyph
                keyLabel.textAlignment = .center
                keyLabel.textColor = Self.orangeKeyGlyphs.contains(glyph) ? .white : .label
                keyLabel.backgroundColor = Self.orangeKeyGlyphs.contains(glyph)
                    ? .systemOrange
                    : .secondarySystemBackground
                keyLabel.layer.cornerCurve = .continuous
                keyLabel.layer.masksToBounds = true
                keyLabel.isAccessibilityElement = false
                keyLabel.adjustsFontSizeToFitWidth = true
                keyLabel.minimumScaleFactor = 0.5
                addSubview(keyLabel)
                keyLabels.append(keyLabel)
            }
        }

        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()

        let safeFrame = safeAreaLayoutGuide.layoutFrame
        guard safeFrame.width > 0, safeFrame.height > 0 else {
            return
        }

        let contentWidth = min(520, max(0, safeFrame.width - 32))
        guard contentWidth > 0 else {
            return
        }

        let compactHeight = safeFrame.height < 430
        let verticalInset: CGFloat = compactHeight ? 4 : 16
        let rowSpacing: CGFloat = compactHeight ? 4 : 8
        let displaySpacing: CGFloat = compactHeight ? 6 : 14
        let targetDisplayHeight = min(144, max(40, contentWidth * 0.24))
        let targetKeyHeight = min(116, max(44, contentWidth * 0.22))
        let maximumDisplayHeight = safeFrame.height
            - (verticalInset * 2)
            - displaySpacing
            - (rowSpacing * 4)
            - (44 * 5)
        let displayHeight = min(targetDisplayHeight, max(40, maximumDisplayHeight))
        let availableKeyHeight = (
            safeFrame.height
                - (verticalInset * 2)
                - displayHeight
                - displaySpacing
                - (rowSpacing * 4),
        ) / 5
        let keyHeight = min(targetKeyHeight, availableKeyHeight)
        let contentX = safeFrame.midX - contentWidth / 2
        let displayY = safeFrame.minY + verticalInset

        displayLabel.frame = CGRect(
            x: contentX,
            y: displayY,
            width: contentWidth,
            height: displayHeight,
        )
        displayLabel.font = .monospacedDigitSystemFont(
            ofSize: min(84, max(44, displayHeight * 0.62)),
            weight: .light,
        )

        let keySpacing = min(12, max(8, contentWidth * 0.02))
        let keyWidth = (contentWidth - (keySpacing * 3)) / 4
        for (index, keyLabel) in keyLabels.enumerated() {
            let row = index / 4
            let column = index % 4
            keyLabel.frame = CGRect(
                x: contentX + CGFloat(column) * (keyWidth + keySpacing),
                y: displayY + displayHeight + displaySpacing + CGFloat(row) * (keyHeight + rowSpacing),
                width: keyWidth,
                height: keyHeight,
            )
            keyLabel.layer.cornerRadius = min(keyWidth, keyHeight) / 2
            keyLabel.font = .systemFont(ofSize: min(32, keyHeight * 0.46), weight: .medium)
        }
    }

    override func safeAreaInsetsDidChange() {
        super.safeAreaInsetsDidChange()
        setNeedsLayout()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        nil
    }
}

@MainActor
private final class WindowAccessibilitySnapshot {
    weak var window: UIWindow?
    private let accessibilityElementsHidden: Bool

    init(window: UIWindow) {
        self.window = window
        accessibilityElementsHidden = window.accessibilityElementsHidden
    }

    func restore() {
        window?.accessibilityElementsHidden = accessibilityElementsHidden
    }
}
