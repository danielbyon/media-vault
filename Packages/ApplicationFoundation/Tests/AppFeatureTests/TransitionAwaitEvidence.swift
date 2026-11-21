//
//  TransitionAwaitEvidence.swift
//  MediaVault
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import ConcurrencyExtras
import Foundation

/// Keeps the producer and test body's suspension markers together for one invocation.
final class TransitionAwaitEvidence: Sendable {
    private let markers = LockIsolated<[String]>([])

    /// The timeout can cancel a test while its main actor or continuation is still blocked.
    /// Write directly from the cancellation handler so reporting does not depend on unwinding.
    @MainActor
    static func observe(
        _ test: StaticString,
        _ body: @MainActor (TransitionAwaitEvidence) async throws -> Void,
    ) async rethrows {
        let evidence = TransitionAwaitEvidence()
        try await withTaskCancellationHandler {
            evidence.mark("body.enter")
            defer {
                if Task.isCancelled {
                    evidence.report(test, boundary: "body.unwound")
                }
            }
            try await body(evidence)
        } onCancel: {
            evidence.report(test, boundary: "testTask.cancelled")
        }
    }

    func mark(_ stage: StaticString) {
        markers.withValue { markers in
            if markers.count == 64 {
                markers.append("additional markers omitted")
                return
            }
            guard markers.count < 64 else {
                return
            }

            markers.append("\(ProcessInfo.processInfo.systemUptime) \(stage) cancelled=\(Task.isCancelled)")
        }
    }

    private func report(_ test: StaticString, boundary: StaticString) {
        let text = "Transition waits \(test) \(boundary) @\(ProcessInfo.processInfo.systemUptime): "
            + markers.value.joined(separator: " | ") + "\n"
        FileHandle.standardError.write(Data(text.utf8))
    }
}
