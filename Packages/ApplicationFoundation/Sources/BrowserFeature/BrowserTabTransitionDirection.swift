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

/// The exact UIKit surface boundary participating in a tab transition.
enum BrowserTabTransitionSurfaceRole: Hashable, Sendable {
    /// The selected page viewport, excluding Browser chrome and the tab bar.
    case content(BrowserTabID)
    /// The preview region inside one overview card, excluding card chrome and footer controls.
    case card(BrowserTabID)
}

/// Layout-only estimate of the browsing page viewport used while Tab Overview is visible.
///
/// This is deliberately not a persisted snapshot size. It follows the current container, safe
/// area, and chrome placement so every card uses the current window geometry after rotation or
/// resizing. A mounted UIKit content boundary is preferred whenever one is available.
struct BrowserContentViewportGeometry: Equatable, Sendable {
    let size: CGSize

    var aspectRatio: CGFloat {
        guard size.height > 0 else {
            return 1
        }

        return size.width / size.height
    }

    static func measure(
        containerSize: CGSize,
        safeAreaTop: CGFloat,
        safeAreaLeading: CGFloat,
        safeAreaBottom: CGFloat,
        safeAreaTrailing: CGFloat,
        chromeHeight: CGFloat,
        chromeAtTop: Bool,
    ) -> Self {
        let width = max(1, containerSize.width - safeAreaLeading - safeAreaTrailing)
        let height = max(
            1,
            containerSize.height - safeAreaTop - safeAreaBottom - max(0, chromeHeight),
        )
        _ = chromeAtTop
        return Self(size: CGSize(width: width, height: height))
    }
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
