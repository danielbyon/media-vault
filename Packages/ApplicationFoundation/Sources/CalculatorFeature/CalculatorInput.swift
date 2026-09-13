//
//  CalculatorInput.swift
//  MediaVault
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

/// A calculator surface input before it is dispatched to the calculator reducer.
///
/// The input seam lets a composition root add an interaction policy around the calculator without
/// making the calculator aware of the policy's domain. Ordinary button input remains represented by
/// ``button(_:)``; the equals long press has its own event so it cannot also become an equals button
/// action.
public enum CalculatorInput: Equatable, Sendable {
    /// A persistence retry request that can still cancel an active input policy.
    case retryPersistence

    /// A normal calculator button interaction.
    case button(CalculatorButton)

    /// A long press of the equals control.
    case longPressEquals
}
