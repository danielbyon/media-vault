//
//  EmergencyLockGestureObserver.swift
//  MediaVault
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import CoreGraphics
import CoreMotion
import Foundation
import ObjectiveC
import SwiftUI
import UIKit

/// Adds the one selected emergency-lock gesture without taking ownership of browser input.
struct EmergencyLockGestureObserver: ViewModifier {
    let gesture: VaultEmergencyLockGesture
    let isForeground: Bool
    let onRecognized: @MainActor @Sendable (VaultEmergencyLockGesture, Bool) -> Void

    func body(content: Content) -> some View {
        switch gesture {
        case .off:
            content
        case .shake:
            content.background {
                ShakeMotionObserver(
                    isForeground: isForeground,
                    onRecognized: { onRecognized(gesture, isForeground) },
                )
            }
        case .quadrupleTap:
            content.simultaneousGesture(
                TapGesture(count: 4)
                    .onEnded {
                        guard isForeground else {
                            return
                        }

                        onRecognized(gesture, isForeground)
                    },
            )
        }
    }
}

/// Classifies accelerometer samples into rate-limited shake events.
struct EmergencyLockShakeClassifier {
    private var lastRecognitionTime: TimeInterval?

    mutating func recognizes(magnitude: Double, atUptime uptime: TimeInterval) -> Bool {
        guard magnitude.isFinite, magnitude >= 2.5 else {
            return false
        }

        if let lastRecognitionTime, uptime - lastRecognitionTime < 1 {
            return false
        }

        lastRecognitionTime = uptime
        return true
    }
}

/// Observes accelerometer samples only while the selected shake gesture can lock the vault.
private struct ShakeMotionObserver: UIViewRepresentable {
    let isForeground: Bool
    let onRecognized: @MainActor @Sendable () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context _: Context) -> UIView {
        UIView(frame: .zero)
    }

    func updateUIView(_: UIView, context: Context) {
        context.coordinator.update(
            isForeground: isForeground,
            onRecognized: onRecognized,
        )
    }

    static func dismantleUIView(_: UIView, coordinator: Coordinator) {
        coordinator.stop()
    }

    @MainActor
    final class Coordinator {
        private let motionManager = CMMotionManager()
        private var isUpdating = false
        private var shakeClassifier = EmergencyLockShakeClassifier()
        private var onRecognized: (@MainActor @Sendable () -> Void)?

        func update(
            isForeground: Bool,
            onRecognized: @escaping @MainActor @Sendable () -> Void,
        ) {
            self.onRecognized = onRecognized
            guard isForeground else {
                stop()
                return
            }
            guard !isUpdating, motionManager.isAccelerometerAvailable else {
                return
            }

            isUpdating = true
            motionManager.accelerometerUpdateInterval = 0.1
            motionManager.startAccelerometerUpdates(to: .main) { [weak self] data, _ in
                guard let acceleration = data?.acceleration else {
                    return
                }

                let magnitude = sqrt(
                    acceleration.x * acceleration.x
                        + acceleration.y * acceleration.y
                        + acceleration.z * acceleration.z,
                )
                Task { @MainActor [weak self] in
                    self?.recognizeShakeIfNeeded(magnitude: magnitude)
                }
            }
        }

        func stop() {
            guard isUpdating else {
                return
            }

            motionManager.stopAccelerometerUpdates()
            isUpdating = false
        }

        private func recognizeShakeIfNeeded(magnitude: Double) {
            guard isUpdating, let onRecognized else {
                return
            }
            guard shakeClassifier.recognizes(
                magnitude: magnitude,
                atUptime: ProcessInfo.processInfo.systemUptime,
            ) else {
                return
            }

            onRecognized()
        }
    }
}
