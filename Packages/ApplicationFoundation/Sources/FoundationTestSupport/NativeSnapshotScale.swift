//
//  NativeSnapshotScale.swift
//  MediaVault
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import CoreFoundation
import Foundation
import ObjectiveC
import SnapshotTesting
import Testing
import UIKit

/// Selects exact image references for the simulator's native rendering scale.
public struct NativeSnapshotScale: Sendable {
    /// The native pixels rendered per point.
    public let value: CGFloat

    /// Validates explicit qualification settings without changing the native scale.
    public static func resolve(
        nativeScale: CGFloat,
        environment: [String: String],
    ) throws -> Self {
        guard nativeScale == 2 || nativeScale == 3 else {
            throw ScaleValidationError(description: "Unsupported native snapshot scale: \(nativeScale)")
        }

        let qualification = environment["NATIVE_SNAPSHOT_QUALIFICATION"]
        if let qualification, qualification != "1" {
            throw ScaleValidationError(description: "Invalid native snapshot qualification marker")
        }
        if let expected = environment["NATIVE_SNAPSHOT_EXPECTED_SCALE"] {
            guard expected == "2" || expected == "3" else {
                throw ScaleValidationError(description: "Invalid native snapshot expected scale: \(expected)")
            }
            guard Double(expected) == Double(nativeScale) else {
                throw ScaleValidationError(description: "Expected snapshot scale \(expected), observed \(nativeScale)")
            }
        } else if qualification == "1" {
            throw ScaleValidationError(description: "Native snapshot qualification requires an expected scale")
        }
        return Self(value: nativeScale)
    }

    /// Reads and records the environment inside the test process before validating it.
    /// Direct Xcode runs may omit qualification settings and still use native references.
    @MainActor
    public static func current(capture: String, target: String) throws -> Self {
        let environment = ProcessInfo.processInfo.environment
        let nativeScale = UIScreen.main.scale
        let result = Result { try resolve(nativeScale: nativeScale, environment: environment) }
        let validationError: String? =
            switch result {
            case .success:
                nil
            case let .failure(error):
                String(describing: error)
            }
        let observation: [String: Any] = [
            "schemaVersion": 1,
            "qualification": environment["NATIVE_SNAPSHOT_QUALIFICATION"] as Any? ?? NSNull(),
            "expectedScale": environment["NATIVE_SNAPSHOT_EXPECTED_SCALE"] as Any? ?? NSNull(),
            "recordMode": environment["SNAPSHOT_TESTING_RECORD"] as Any? ?? NSNull(),
            "nativeScale": Double(nativeScale),
            "referenceScale": Double(nativeScale),
            "capture": capture,
            "target": target,
            "processID": Int(ProcessInfo.processInfo.processIdentifier),
            "processName": ProcessInfo.processInfo.processName,
            "validationError": validationError as Any? ?? NSNull(),
        ]
        try Attachment.record(
            JSONSerialization.data(withJSONObject: observation, options: .sortedKeys),
            named: "native-snapshot-environment.json",
        )
        return try result.get()
    }

    /// Preserves fixture geometry and traits while specifying the rendering scale.
    @MainActor
    public func configuration(_ original: ViewImageConfig) -> ViewImageConfig {
        var configuration = original
        configuration.traits = UITraitCollection(traitsFrom: [
            original.traits,
            UITraitCollection(displayScale: value),
        ])
        return configuration
    }

    /// Keeps canonical names at 2x and selects separate 3x image references.
    public func referenceName(_ name: String?) -> String? {
        guard value == 3 else {
            return name
        }

        return name.map { "\($0)-3x" } ?? "3x"
    }
}

private struct ScaleValidationError: Error, CustomStringConvertible {
    let description: String
}
