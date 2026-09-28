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
/// requires two stable display opportunities without claiming pixel verification. Production
/// advances from a display link; tests can disable that driver and advance the same logic directly.
@MainActor
final class BrowserWebKitReadinessProbe: NSObject {
    /// The display-turn barrier is a presentation grace period, not visual evidence.
    private static let requiredStableDisplayTurns = 2
    static let maximumReadinessTurns = 180

    private weak var webView: WKWebView?
    private let readinessContext: BrowserWebKitReadinessContext?
    private let automaticallyAdvancesDisplayTurns: Bool
    private let isAdapterOwned: () -> Bool
    private let hasCommittedDocument: () -> Bool
    private let onResult: (BrowserWebKitReadinessResult) -> Void
    private let onPresentationBlocked: () -> Void
    private var readinessTurnsRemaining = 0
    private var stableDisplayTurns = 0
    private var didReportPresentationBlocked = false
    private var hasStarted = false
    private var isActive = false
    private var displayLink: CADisplayLink?

    init(
        webView: WKWebView,
        readinessContext: BrowserWebKitReadinessContext?,
        automaticallyAdvancesDisplayTurns: Bool = true,
        isAdapterOwned: @escaping () -> Bool,
        hasCommittedDocument: @escaping () -> Bool,
        onResult: @escaping (BrowserWebKitReadinessResult) -> Void,
        onPresentationBlocked: @escaping () -> Void,
    ) {
        self.webView = webView
        self.readinessContext = readinessContext
        self.automaticallyAdvancesDisplayTurns = automaticallyAdvancesDisplayTurns
        self.isAdapterOwned = isAdapterOwned
        self.hasCommittedDocument = hasCommittedDocument
        self.onResult = onResult
        self.onPresentationBlocked = onPresentationBlocked
        super.init()
    }

    func start() {
        guard !hasStarted else {
            return
        }

        hasStarted = true
        isActive = true
        readinessTurnsRemaining = Self.maximumReadinessTurns
        stableDisplayTurns = 0
        didReportPresentationBlocked = false

        guard automaticallyAdvancesDisplayTurns else {
            return
        }

        let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
        displayLink = link
        link.add(to: .main, forMode: .common)
    }

    func invalidate() {
        displayLink?.invalidate()
        displayLink = nil
        isActive = false
    }

    /// Advances one readiness turn only when automatic display-link driving is disabled.
    func advanceReadinessTurnForTesting() {
        guard !automaticallyAdvancesDisplayTurns else {
            return
        }

        advanceReadinessTurn()
    }

    func matches(webView: WKWebView, readinessContext: BrowserWebKitReadinessContext?) -> Bool {
        self.webView === webView
            && self.readinessContext == readinessContext
    }

    @objc
    private func tick(_: CADisplayLink) {
        advanceReadinessTurn()
    }

    private func advanceReadinessTurn() {
        guard isActive else {
            return
        }
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
        guard isActive else {
            return
        }

        onResult(.unavailable)
        invalidate()
    }
}
