//
//  ScenePrivacyCoverPolicy.swift
//  MediaVault
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//

/// Tracks whether a scene may reveal its content after deactivation.
///
/// A scene remains covered while inactive. After deactivation, the caller must
/// report that coverage is required and later report that validation is
/// complete. Either update may arrive before the scene's activation callback;
/// the content is revealed only after both conditions are true and the scene is
/// active.
struct ScenePrivacyCoverPolicy {
    private(set) var isCoveredByCaller: Bool
    private(set) var isSceneActive: Bool
    private(set) var isAwaitingPostDeactivationCoverageAcknowledgement: Bool
    private(set) var hasPostDeactivationCoverageAcknowledgement: Bool
    private(set) var hasUncoveredUpdateAfterCoverageAcknowledgement: Bool

    init(isCoveredByCaller: Bool, isSceneActive: Bool) {
        self.isCoveredByCaller = isCoveredByCaller
        self.isSceneActive = isSceneActive
        isAwaitingPostDeactivationCoverageAcknowledgement = !isSceneActive
        hasPostDeactivationCoverageAcknowledgement = !isSceneActive && isCoveredByCaller
        hasUncoveredUpdateAfterCoverageAcknowledgement = false
    }

    /// Whether the scene should display its privacy-cover window.
    var shouldShowCover: Bool {
        guard isSceneActive else {
            return true
        }
        guard !isCoveredByCaller else {
            return true
        }
        guard isAwaitingPostDeactivationCoverageAcknowledgement else {
            return false
        }

        return
            !(hasPostDeactivationCoverageAcknowledgement
                && hasUncoveredUpdateAfterCoverageAcknowledgement)
    }

    mutating func update(isCoveredByCaller: Bool) {
        self.isCoveredByCaller = isCoveredByCaller

        if isCoveredByCaller {
            if isAwaitingPostDeactivationCoverageAcknowledgement {
                hasPostDeactivationCoverageAcknowledgement = true
                hasUncoveredUpdateAfterCoverageAcknowledgement = false
            }
        } else if isAwaitingPostDeactivationCoverageAcknowledgement,
                  hasPostDeactivationCoverageAcknowledgement {
            hasUncoveredUpdateAfterCoverageAcknowledgement = true
        }

        reconcileAfterEvent()
    }

    mutating func sceneWillDeactivate() {
        guard isSceneActive else {
            return
        }

        isSceneActive = false
        isAwaitingPostDeactivationCoverageAcknowledgement = true
        hasPostDeactivationCoverageAcknowledgement = isCoveredByCaller
        hasUncoveredUpdateAfterCoverageAcknowledgement = false
    }

    mutating func sceneDidActivate() {
        isSceneActive = true
        reconcileAfterEvent()
    }

    private mutating func reconcileAfterEvent() {
        guard isSceneActive,
              !isCoveredByCaller,
              isAwaitingPostDeactivationCoverageAcknowledgement,
              hasPostDeactivationCoverageAcknowledgement,
              hasUncoveredUpdateAfterCoverageAcknowledgement
        else {
            return
        }

        isAwaitingPostDeactivationCoverageAcknowledgement = false
        hasPostDeactivationCoverageAcknowledgement = false
        hasUncoveredUpdateAfterCoverageAcknowledgement = false
    }
}
