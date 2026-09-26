//
//  ShippingDecoyRegistry.swift
//  MediaVault
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import CalculatorFeature
import DecoySupport

/// The decoy selected by the application's static build-time registration.
@MainActor
@preconcurrency
public enum ShippingDecoyRegistry {
    /// Calculator is the sole shipping decoy and the default for the application.
    public static let defaultDefinition = CalculatorDecoyAdapter.definition
}
