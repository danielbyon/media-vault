//
//  BrowserWebKitReadinessProbe.swift
//  MediaVault
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import UIKit
import WebKit

/// The only terminal outcomes produced by one WebKit readiness attempt.
@MainActor
enum BrowserWebKitReadinessResult {
    case ready
    case unavailable
}

/// Owns the temporal portion of one mounted WebKit readiness attempt.
///
/// The probe waits for the existing lifecycle prerequisites, samples the mounted surface, and
/// permits only one bounded compositor-settling retry after a nonblack mismatch. Visual evidence
/// construction and comparison remain in `BrowserWebKitVisualSignature`.
@MainActor
final class BrowserWebKitReadinessProbe: NSObject {
    /// Allows one initial surface sample and one sample after a compositor-settling window.
    private static let maximumVisualSamples = 2
    private static let maximumUnavailableViewTurns = 180
    private static let maximumMismatchSettlingTurns = 30

    private weak var webView: WKWebView?
    private let readinessContext: BrowserWebKitReadinessContext?
    private let hasCommittedDocument: () -> Bool
    private let visualSignature: (WKWebView) -> BrowserWebKitVisualSignature?
    private let onResult: (BrowserWebKitReadinessResult) -> Void
    private let onVisualInvalid: () -> Void
    private var unavailableViewTurnsRemaining = 0
    private var mismatchSettlingTurnsRemaining = 0
    private var visualSamplesRemaining = 0
    private var deferredAfterMismatch = false
    private var displayLink: CADisplayLink?

    init(
        webView: WKWebView,
        readinessContext: BrowserWebKitReadinessContext?,
        hasCommittedDocument: @escaping () -> Bool,
        visualSignature: @escaping (WKWebView) -> BrowserWebKitVisualSignature? = {
            BrowserWebKitVisualSignature(webView: $0)
        },
        onResult: @escaping (BrowserWebKitReadinessResult) -> Void,
        onVisualInvalid: @escaping () -> Void,
    ) {
        self.webView = webView
        self.readinessContext = readinessContext
        self.hasCommittedDocument = hasCommittedDocument
        self.visualSignature = visualSignature
        self.onResult = onResult
        self.onVisualInvalid = onVisualInvalid
        super.init()
    }

    func start() {
        unavailableViewTurnsRemaining = Self.maximumUnavailableViewTurns
        mismatchSettlingTurnsRemaining = 0
        visualSamplesRemaining = Self.maximumVisualSamples
        deferredAfterMismatch = false

        let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
        displayLink = link
        link.add(to: .main, forMode: .common)
    }

    func invalidate() {
        displayLink?.invalidate()
        displayLink = nil
    }

    func matches(webView: WKWebView, readinessContext: BrowserWebKitReadinessContext?) -> Bool {
        self.webView === webView
            && self.readinessContext == readinessContext
    }

    @objc
    private func tick(_: CADisplayLink) {
        guard let webView else {
            if consumeUnavailableViewTurn() {
                becomeUnavailable()
            }
            return
        }
        guard webView.bounds.width > 0,
              webView.bounds.height > 0,
              webView.window != nil
        else {
            if consumeUnavailableViewTurn() {
                becomeUnavailable()
            }
            return
        }
        guard !consumeSettlingTurn() else {
            return
        }
        guard visualSamplesRemaining > 0 else {
            becomeUnavailable()
            return
        }

        evaluate(webView: webView)
    }

    private func evaluate(webView: WKWebView) {
        // The previously committed document may remain visible while the new operation is still
        // between command dispatch and WebKit's commit callback. The reducer keeps this flag set
        // until correlated loading-finished metadata arrives, so never use that older document
        // as readiness evidence during the pending operation.
        guard readinessContext?.requiresFreshCommit != true else {
            waitForLifecycle()
            return
        }

        // A loading WebKit view has not yet produced the document surface this probe compares.
        guard !webView.isLoading, hasCommittedDocument() else {
            waitForLifecycle()
            return
        }

        // Without revision-scoped preview evidence, the destination cannot self-certify from its
        // current pixels.
        guard let expectedSignature = readinessContext?.expectedSignature else {
            becomeUnavailable()
            return
        }

        // A detected cover is a recoverable ownership conflict, not page evidence. Keep waiting
        // under the existing bounded attachment budget and preserve the diagnostic event.
        guard !BrowserWebKitVisualEvidence.hasOpaqueCover(in: webView) else {
            reportVisualInvalid()
            if consumeUnavailableViewTurn() {
                becomeUnavailable()
            }
            return
        }
        guard let observedSignature = visualSignature(webView) else {
            handleVisualMismatch(signature: nil)
            return
        }
        guard observedSignature.matches(expected: expectedSignature) else {
            handleVisualMismatch(signature: observedSignature)
            return
        }

        visualSamplesRemaining -= 1
        completeReady()
    }

    private func waitForLifecycle() {
        // A missing commit is not proof of readiness. Bound the wait so a failed WebKit
        // operation cannot leave the transition pending forever.
        if consumeUnavailableViewTurn() {
            becomeUnavailable()
        }
    }

    private func handleVisualMismatch(signature: BrowserWebKitVisualSignature?) {
        visualSamplesRemaining -= 1
        reportVisualInvalid()

        if signature?.isUniformBlack == true {
            becomeUnavailable()
        } else if !deferredAfterMismatch {
            deferredAfterMismatch = true
            mismatchSettlingTurnsRemaining = Self.maximumMismatchSettlingTurns
        } else {
            becomeUnavailable()
        }
    }

    private func consumeSettlingTurn() -> Bool {
        guard mismatchSettlingTurnsRemaining > 0 else {
            return false
        }

        mismatchSettlingTurnsRemaining -= 1
        return true
    }

    private func consumeUnavailableViewTurn() -> Bool {
        guard unavailableViewTurnsRemaining > 0 else {
            return true
        }

        unavailableViewTurnsRemaining -= 1
        return false
    }

    private func completeReady() {
        onResult(.ready)
        invalidate()
    }

    private func becomeUnavailable() {
        onResult(.unavailable)
        invalidate()
    }

    private func reportVisualInvalid() {
        onVisualInvalid()
    }
}
