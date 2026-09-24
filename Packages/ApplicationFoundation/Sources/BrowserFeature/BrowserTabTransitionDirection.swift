//
//  BrowserTabTransitionDirection.swift
//  MediaVault
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

/// Opaque equality token for one logical tab's current previewable document.
///
/// The UUID is deliberately private. Callers may compare revisions to reject stale work, but
/// they cannot infer ordering or use the value as persisted metadata.
public struct BrowserTabPreviewRevision: Equatable, Hashable, Sendable {
    private let token: UUID

    /// Creates a new revision token for the current transient document state.
    public init() {
        token = UUID()
    }
}

/// The direction of one exact UIKit handoff between browsing and Tab Overview.
enum BrowserTabTransitionDirection: Equatable, Sendable {
    /// The selected browsing surface is moving into Tab Overview.
    case toOverview
    /// A tab-card preview is moving into the selected browsing surface.
    case toBrowsing
}

/// Reports whether a transition destination can be used or needs additional preparation.
enum BrowserTabTransitionDestinationPreparation: Equatable, Sendable {
    /// A local request was issued to establish an authoritative destination.
    case requested
    /// The mounted destination is already usable without repositioning.
    case alreadyUsable
    /// The destination is not ready to use yet.
    case awaitingReadiness
}

/// The exact UIKit surface boundary participating in a tab transition.
enum BrowserTabTransitionSurfaceRole: Hashable, Sendable {
    /// The selected page viewport, excluding Browser chrome and the tab bar.
    case content(BrowserTabID)
    /// The preview region inside one overview card, excluding card chrome and footer controls.
    case card(BrowserTabID)
}

/// Layout-only geometry of the browsing page viewport used while Tab Overview is visible.
///
/// The value comes either from the mounted UIKit content boundary or from a SwiftUI layout probe
/// that uses the same safe-area and chrome structure as the browsing presentation. It is never a
/// persisted snapshot size.
struct BrowserContentViewportGeometry: Equatable, Sendable {
    let size: CGSize

    var aspectRatio: CGFloat {
        guard size.height > 0 else {
            return 1
        }

        return size.width / size.height
    }
}

/// The transient branch selected by one UIKit transition handoff.
///
/// This value is intentionally Browser-local and contains no page identity, URL, or persisted
/// state. Tests can observe the coordinator's decision without requiring production logging.
enum BrowserTabTransitionExecution: Equatable, Sendable {
    /// The source and destination boundaries share compatible geometry and use the normal motion.
    case geometry
    /// Reduce Motion requested an opacity-only handoff.
    case reduceMotion
    /// The source boundary could not be synchronously cloned.
    case missingSource
    /// The destination boundary was not mounted before the bounded wait expired.
    case missingDestination
    /// The source and destination aspect ratios exceeded the safety threshold.
    case aspectMismatch
}

/// Presentation endpoints shared by the UIKit clone and the overview card surface.
struct BrowserTabTransitionPresentation: Equatable, Sendable {
    /// The existing Tab Overview preview corner radius.
    static let cardCornerRadius: CGFloat = 14
    /// The full browsing viewport is intentionally unrounded.
    static let viewportCornerRadius: CGFloat = 0

    let direction: BrowserTabTransitionDirection

    /// Returns the endpoint corner radius for the requested presentation surface.
    func cornerRadius(for endpoint: BrowserTabTransitionEndpoint) -> CGFloat {
        switch endpoint {
        case .card:
            Self.cardCornerRadius
        case .viewport:
            Self.viewportCornerRadius
        }
    }

    /// Corner radius at the source side of the transition.
    var sourceCornerRadius: CGFloat {
        cornerRadius(for: direction == .toOverview ? .viewport : .card)
    }

    /// Corner radius at the destination side of the transition.
    var destinationCornerRadius: CGFloat {
        cornerRadius(for: direction == .toOverview ? .card : .viewport)
    }
}

/// The two visual endpoints used for transition corner-radius calculations.
enum BrowserTabTransitionEndpoint: Equatable, Sendable {
    /// The overview card preview boundary.
    case card
    /// The live browsing viewport boundary.
    case viewport
}
