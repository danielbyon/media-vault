//
//  BrowserTabSwipe.swift
//  MediaVault
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import CoreGraphics

/// Classifies Tab Overview drags without owning tab identity, gesture state, or reducer behavior.
enum BrowserTabSwipe {
    /// The axis selected by the first meaningful movement in a drag.
    enum Axis: Equatable {
        case horizontal
        case vertical
    }

    /// The result of releasing a horizontally classified drag.
    enum Outcome: Equatable {
        case cancel
        case dismiss
    }

    /// The existing horizontal distance required to close a tab.
    static let dismissalDistance: CGFloat = 80

    /// Selects horizontal movement only when it strictly dominates vertical movement.
    static func axis(for translation: CGSize) -> Axis {
        abs(translation.width) > abs(translation.height) ? .horizontal : .vertical
    }

    /// Returns the release outcome for a drag whose axis was already locked by the view.
    static func outcome(for translation: CGSize, axis: Axis) -> Outcome? {
        guard axis == .horizontal else {
            return nil
        }

        return abs(translation.width) > dismissalDistance ? .dismiss : .cancel
    }
}
