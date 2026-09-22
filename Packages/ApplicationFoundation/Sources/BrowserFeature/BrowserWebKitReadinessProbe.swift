//
//  BrowserWebKitReadinessProbe.swift
//  MediaVault
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import UIKit
import WebKit

/// The only terminal outcomes produced by one WebKit presentation-readiness attempt.
@MainActor
enum BrowserWebKitReadinessResult {
    case ready
    case unavailable
}

/// Owns the temporal portion of one mounted WebKit presentation-readiness attempt.
///
/// `WKNavigationDelegate.didCommit` means WebKit is beginning to update the main frame and
/// `didFinish` means navigation completed. Neither public callback certifies that an out-of-process
/// WebKit page pixel has been presented onscreen. This probe therefore checks lifecycle state and
/// requires two stable display opportunities without claiming pixel verification.
@MainActor
final class BrowserWebKitReadinessProbe: NSObject {
    /// The display-turn barrier is a presentation grace period, not visual evidence.
    private static let requiredStableDisplayTurns = 2
    private static let maximumReadinessTurns = 180

    private weak var webView: WKWebView?
    private let readinessContext: BrowserWebKitReadinessContext?
    private let isAdapterOwned: () -> Bool
    private let hasCommittedDocument: () -> Bool
    private let onResult: (BrowserWebKitReadinessResult) -> Void
    private let onPresentationBlocked: () -> Void
    private var readinessTurnsRemaining = 0
    private var stableDisplayTurns = 0
    private var didReportPresentationBlocked = false
    private var displayLink: CADisplayLink?

    init(
        webView: WKWebView,
        readinessContext: BrowserWebKitReadinessContext?,
        isAdapterOwned: @escaping () -> Bool,
        hasCommittedDocument: @escaping () -> Bool,
        onResult: @escaping (BrowserWebKitReadinessResult) -> Void,
        onPresentationBlocked: @escaping () -> Void,
    ) {
        self.webView = webView
        self.readinessContext = readinessContext
        self.isAdapterOwned = isAdapterOwned
        self.hasCommittedDocument = hasCommittedDocument
        self.onResult = onResult
        self.onPresentationBlocked = onPresentationBlocked
        super.init()
    }

    func start() {
        readinessTurnsRemaining = Self.maximumReadinessTurns
        stableDisplayTurns = 0
        didReportPresentationBlocked = false

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
        guard consumeReadinessTurn() else {
            becomeUnavailable()
            return
        }
        guard let webView,
              isAdapterOwned()
        else {
            waitForNextDisplayTurn()
            return
        }
        guard webView.window != nil,
              webView.bounds.width > 0,
              webView.bounds.height > 0
        else {
            waitForNextDisplayTurn()
            return
        }
        guard readinessContext?.requiresFreshCommit != true,
              hasCommittedDocument(),
              !webView.isLoading
        else {
            waitForNextDisplayTurn()
            return
        }
        guard !BrowserWebKitPresentationGuard.hasOpaqueCover(in: webView) else {
            stableDisplayTurns = 0
            if !didReportPresentationBlocked {
                didReportPresentationBlocked = true
                onPresentationBlocked()
            }
            if readinessTurnsRemaining == 0 {
                becomeUnavailable()
            }
            return
        }

        didReportPresentationBlocked = false
        stableDisplayTurns += 1
        guard stableDisplayTurns >= Self.requiredStableDisplayTurns else {
            return
        }

        onResult(.ready)
        invalidate()
    }

    private func consumeReadinessTurn() -> Bool {
        guard readinessTurnsRemaining > 0 else {
            return false
        }

        readinessTurnsRemaining -= 1
        return true
    }

    private func waitForNextDisplayTurn() {
        stableDisplayTurns = 0
        if readinessTurnsRemaining == 0 {
            becomeUnavailable()
        }
    }

    private func becomeUnavailable() {
        guard displayLink != nil else {
            return
        }

        onResult(.unavailable)
        invalidate()
    }
}
