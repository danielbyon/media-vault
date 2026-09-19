//
//  BrowserWebView.swift
//  MediaVault
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import PresentationSupport
import SwiftUI
import UIKit
import WebKit

/// A small, memory-only visual signature used to compare a live page with known-valid imagery.
///
/// A nontransparent pixel only proves that a WebKit backing surface was allocated. The Browser
/// instead compares a tiny normalized sample against the current revision's last valid preview
/// or page surface. The signature deliberately does not reject dark output: a genuinely black page
/// is valid when its known-valid signature is also black.
@MainActor
struct BrowserWebKitVisualSignature: Equatable {
    private static let sampleDimension = 4
    private static let renderDimension = 32
    private static let channelTolerance: UInt8 = 24

    private struct Sample: Equatable {
        let red: UInt8
        let green: UInt8
        let blue: UInt8
        let alpha: UInt8
    }

    private let samples: [Sample]

    /// Builds a signature from an existing revision-matching preview without retaining the image.
    init?(imageData: Data) {
        guard let image = UIImage(data: imageData)?.cgImage else {
            return nil
        }

        self.init(cgImage: image)
    }

    /// Builds a signature directly from a mounted surface using only a tiny bitmap context.
    init?(view: UIView) {
        guard view.bounds.width > 0, view.bounds.height > 0 else {
            return nil
        }

        var bytes = [UInt8](repeating: 0, count: Self.renderDimension * Self.renderDimension * 4)
        guard let context = CGContext(
            data: &bytes,
            width: Self.renderDimension,
            height: Self.renderDimension,
            bitsPerComponent: 8,
            bytesPerRow: Self.renderDimension * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue,
        ) else {
            return nil
        }

        context.saveGState()
        context.translateBy(x: 0, y: CGFloat(Self.renderDimension))
        context.scaleBy(
            x: CGFloat(Self.renderDimension) / view.bounds.width,
            y: -CGFloat(Self.renderDimension) / view.bounds.height,
        )
        view.layer.render(in: context)
        context.restoreGState()
        samples = Self.samples(from: bytes)
    }

    /// Builds a signature from the existing WebKit content surface before reparenting.
    ///
    /// A background WebKit view may have a zero-sized UIKit frame even though its document has
    /// already committed. Temporarily sizing that existing view lets its scroll surface render
    /// into the same tiny in-memory signature without taking a snapshot or retaining image data.
    init?(webView: WKWebView, fitting size: CGSize) {
        guard size.width > 0, size.height > 0 else {
            return nil
        }

        let originalBounds = webView.bounds
        let originalFrame = webView.frame
        webView.bounds = CGRect(origin: .zero, size: size)
        webView.layoutIfNeeded()
        let signature = Self(view: webView.scrollView)
        webView.bounds = originalBounds
        webView.frame = originalFrame
        webView.layoutIfNeeded()
        guard let signature else {
            return nil
        }

        self = signature
    }

    /// Compares sampled output with tolerance for compositor and image-decoder variation.
    func approximatelyMatches(_ other: Self) -> Bool {
        guard samples.count == other.samples.count else {
            return false
        }

        return zip(samples, other.samples).allSatisfy { left, right in
            abs(Int(left.red) - Int(right.red)) <= Int(Self.channelTolerance)
                && abs(Int(left.green) - Int(right.green)) <= Int(Self.channelTolerance)
                && abs(Int(left.blue) - Int(right.blue)) <= Int(Self.channelTolerance)
                && abs(Int(left.alpha) - Int(right.alpha)) <= Int(Self.channelTolerance)
        }
    }

    private init?(cgImage: CGImage) {
        var bytes = [UInt8](repeating: 0, count: Self.renderDimension * Self.renderDimension * 4)
        guard let context = CGContext(
            data: &bytes,
            width: Self.renderDimension,
            height: Self.renderDimension,
            bitsPerComponent: 8,
            bytesPerRow: Self.renderDimension * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue,
        ) else {
            return nil
        }

        context.interpolationQuality = .none
        context.draw(
            cgImage,
            in: CGRect(
                x: 0,
                y: 0,
                width: CGFloat(Self.renderDimension),
                height: CGFloat(Self.renderDimension),
            ),
        )
        samples = Self.samples(from: bytes)
    }

    private static func samples(from bytes: [UInt8]) -> [Sample] {
        let step = renderDimension / sampleDimension
        return (0 ..< sampleDimension)
            .flatMap { row in
                (0 ..< sampleDimension).map { column in
                    let x = column * step + step / 2
                    let y = row * step + step / 2
                    let offset = (y * renderDimension + x) * 4
                    return Sample(
                        red: bytes[offset],
                        green: bytes[offset + 1],
                        blue: bytes[offset + 2],
                        alpha: bytes[offset + 3],
                    )
                }
            }
            .sorted { left, right in
                sortKey(for: left) < sortKey(for: right)
            }
    }

    private static func sortKey(for sample: Sample) -> UInt32 {
        UInt32(sample.red) << 24
            | UInt32(sample.green) << 16
            | UInt32(sample.blue) << 8
            | UInt32(sample.alpha)
    }
}

/// Explicit state for one WebKit surface's visual-readiness decision.
@MainActor
enum BrowserWebKitReadinessState: Equatable {
    case waitingForEvidence
    case visuallyInvalid
    case visuallyReady
    case evidenceUnavailable
}

/// Identifies the source selected for a WebKit readiness signature.
@MainActor
enum BrowserWebKitReadinessEvidence: Equatable {
    case waitingForEvidence
    case cachedPreview
    case lastValidSignature
    case currentWebKitSurface
    case unavailable
}

/// Known-valid visual evidence for one WebKit document revision.
@MainActor
struct BrowserWebKitReadinessContext: Equatable {
    let revision: BrowserTabPreviewRevision
    let expectedSignature: BrowserWebKitVisualSignature?
    let fallbackSignature: BrowserWebKitVisualSignature?
    let evidence: BrowserWebKitReadinessEvidence

    init(
        revision: BrowserTabPreviewRevision,
        expectedSignature: BrowserWebKitVisualSignature?,
    ) {
        self.init(
            revision: revision,
            expectedSignature: expectedSignature,
            fallbackSignature: nil,
            evidence: expectedSignature == nil ? .waitingForEvidence : .cachedPreview,
        )
    }

    init(
        revision: BrowserTabPreviewRevision,
        expectedSignature: BrowserWebKitVisualSignature?,
        fallbackSignature: BrowserWebKitVisualSignature?,
        evidence: BrowserWebKitReadinessEvidence,
    ) {
        self.revision = revision
        self.expectedSignature = expectedSignature
        self.fallbackSignature = fallbackSignature
        self.evidence = evidence
    }
}

/// Proves that an attached WebKit view has committed pixels matching known-valid imagery.
///
/// WebKit does not expose a public "first pixels committed" callback. The display-link boundary
/// prevents this check from racing the layout and compositor turn that follows an attachment.
@MainActor
private final class BrowserWebKitReadinessProbe: NSObject {
    private weak var view: UIView?
    private let expectedSignature: BrowserWebKitVisualSignature?
    private let fallbackSignature: BrowserWebKitVisualSignature?
    private let onStateChange: (BrowserWebKitReadinessState) -> Void
    private let onReady: (BrowserWebKitVisualSignature) -> Void
    private var displayLink: CADisplayLink?
    private(set) var state: BrowserWebKitReadinessState = .waitingForEvidence

    init(
        view: UIView,
        expectedSignature: BrowserWebKitVisualSignature?,
        fallbackSignature: BrowserWebKitVisualSignature?,
        onStateChange: @escaping (BrowserWebKitReadinessState) -> Void,
        onReady: @escaping (BrowserWebKitVisualSignature) -> Void,
    ) {
        self.view = view
        self.expectedSignature = expectedSignature
        self.fallbackSignature = fallbackSignature
        self.onStateChange = onStateChange
        self.onReady = onReady
        super.init()
    }

    func start() {
        let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
        displayLink = link
        link.add(to: .main, forMode: .common)
    }

    func invalidate() {
        displayLink?.invalidate()
        displayLink = nil
    }

    @objc
    private func tick(_ displayLink: CADisplayLink) {
        guard let view,
              view.window != nil,
              view.bounds.width > 0,
              view.bounds.height > 0,
              (view as? WKWebView)?.isLoading != true
        else {
            return
        }

        let expectedSignatures = [expectedSignature, fallbackSignature].compactMap(\.self)
        guard !expectedSignatures.isEmpty else {
            transition(to: .evidenceUnavailable)
            displayLink.invalidate()
            self.displayLink = nil
            return
        }
        guard let observedSignature = BrowserWebKitVisualSignature(view: view) else {
            transition(to: .visuallyInvalid)
            return
        }
        guard expectedSignatures.contains(where: observedSignature.approximatelyMatches) else {
            transition(to: .visuallyInvalid)
            return
        }

        transition(to: .visuallyReady)
        displayLink.invalidate()
        self.displayLink = nil
        onReady(observedSignature)
    }

    private func transition(to state: BrowserWebKitReadinessState) {
        guard self.state != state else {
            return
        }

        self.state = state
        onStateChange(state)
    }
}

/// UIKit bridge that mounts the selected adapter-owned WebKit surface.
@MainActor
@preconcurrency
public struct BrowserWebView: UIViewRepresentable {
    /// Stable logical identity of the surface to attach.
    public let tabID: BrowserTabID
    private let onRefresh: () -> Void
    private let transitionRegistry: BrowserTabTransitionSurfaceRegistry?
    private let readinessContext: BrowserWebKitReadinessContext?

    /// Creates a bridge for an adapter-owned WebKit context.
    public init(tabID: BrowserTabID, onRefresh: @escaping () -> Void) {
        self.tabID = tabID
        self.onRefresh = onRefresh
        transitionRegistry = nil
        readinessContext = nil
    }

    /// Creates a Browser page surface that also registers its exact transition boundary.
    init(
        tabID: BrowserTabID,
        onRefresh: @escaping () -> Void,
        transitionRegistry: BrowserTabTransitionSurfaceRegistry,
        readinessContext: BrowserWebKitReadinessContext? = nil,
    ) {
        self.tabID = tabID
        self.onRefresh = onRefresh
        self.transitionRegistry = transitionRegistry
        self.readinessContext = readinessContext
    }

    /// Tracks which adapter surface is currently mounted in the UIKit container.
    @MainActor
    @preconcurrency
    public final class Coordinator: NSObject {
        var tabID: BrowserTabID?
        private var onRefresh: () -> Void
        let transitionRegistry: BrowserTabTransitionSurfaceRegistry?
        private var readinessProbe: BrowserWebKitReadinessProbe?
        private var lastValidSignatures: [BrowserTabID: (
            revision: BrowserTabPreviewRevision,
            signature: BrowserWebKitVisualSignature,
        )] = [:]

        init(
            onRefresh: @escaping () -> Void,
            transitionRegistry: BrowserTabTransitionSurfaceRegistry?,
        ) {
            self.onRefresh = onRefresh
            self.transitionRegistry = transitionRegistry
        }

        func update(onRefresh: @escaping () -> Void) {
            self.onRefresh = onRefresh
        }

        func refresh() {
            onRefresh()
        }

        func invalidateReadinessProbe() {
            readinessProbe?.invalidate()
            readinessProbe = nil
        }

        func resolveReadinessContext(
            _ readinessContext: BrowserWebKitReadinessContext?,
            for webView: WKWebView,
            fitting container: UIView,
            tabID: BrowserTabID,
        ) -> BrowserWebKitReadinessContext? {
            guard let readinessContext else {
                return nil
            }

            let currentSurfaceSignature: BrowserWebKitVisualSignature? = {
                guard !webView.isLoading,
                      BrowserWebKitAdapter.shared.hasCommittedDocument(for: tabID)
                else {
                    return nil
                }

                return BrowserWebKitVisualSignature(
                    webView: webView,
                    fitting: container.bounds.size,
                )
            }()

            if let expectedSignature = readinessContext.expectedSignature {
                return BrowserWebKitReadinessContext(
                    revision: readinessContext.revision,
                    expectedSignature: expectedSignature,
                    fallbackSignature: currentSurfaceSignature,
                    evidence: .cachedPreview,
                )
            }

            if let lastValid = lastValidSignatures[tabID],
               lastValid.revision == readinessContext.revision {
                return BrowserWebKitReadinessContext(
                    revision: readinessContext.revision,
                    expectedSignature: lastValid.signature,
                    fallbackSignature: currentSurfaceSignature,
                    evidence: .lastValidSignature,
                )
            }

            if let currentSurfaceSignature {
                return BrowserWebKitReadinessContext(
                    revision: readinessContext.revision,
                    expectedSignature: currentSurfaceSignature,
                    fallbackSignature: nil,
                    evidence: .currentWebKitSurface,
                )
            }

            return BrowserWebKitReadinessContext(
                revision: readinessContext.revision,
                expectedSignature: nil,
                fallbackSignature: nil,
                evidence: .unavailable,
            )
        }

        func scheduleReadinessProbe(
            for view: UIView,
            tabID: BrowserTabID,
            readinessContext: BrowserWebKitReadinessContext? = nil,
        ) {
            guard let transitionRegistry,
                  !transitionRegistry.isReady(for: .content(tabID))
            else {
                return
            }

            readinessProbe?.invalidate()
            let probe = BrowserWebKitReadinessProbe(
                view: view,
                expectedSignature: readinessContext?.expectedSignature,
                fallbackSignature: readinessContext?.fallbackSignature,
                onStateChange: { [weak transitionRegistry] state in
                    switch state {
                    case .visuallyInvalid:
                        transitionRegistry?.report(.targetVisualInvalid(tabID))
                    case .evidenceUnavailable:
                        transitionRegistry?.report(.targetEvidenceUnavailable(tabID))
                    case .waitingForEvidence,
                         .visuallyReady:
                        break
                    }
                },
                onReady: { [weak self, weak view] signature in
                    guard let self, let view else {
                        return
                    }

                    if let readinessContext {
                        lastValidSignatures[tabID] = (readinessContext.revision, signature)
                    }
                    transitionRegistry.markReady(view, for: .content(tabID))
                    transitionRegistry.report(.targetVisualReady(tabID))
                    readinessProbe = nil
                },
            )
            readinessProbe = probe
            probe.start()
        }

        @objc
        func refreshControlValueChanged(_ sender: UIRefreshControl) {
            sender.endRefreshing()
            refresh()
        }
    }

    /// Creates bridge coordination state without retaining a WebKit object.
    public func makeCoordinator() -> Coordinator {
        Coordinator(onRefresh: onRefresh, transitionRegistry: transitionRegistry)
    }

    /// Creates the neutral UIKit container that receives the adapter-owned surface.
    public func makeUIView(context _: Context) -> UIView {
        UIView()
    }

    /// Attaches the requested stable tab and detaches any prior tab surface.
    public func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.update(onRefresh: onRefresh)
        if let previous = context.coordinator.tabID, previous != tabID {
            let previousWebView = BrowserWebKitAdapter.shared.webView(for: previous)
            BrowserWebKitAdapter.shared.detach(tabID: previous, from: uiView)
            if let previousWebView {
                context.coordinator.transitionRegistry?.unregister(previousWebView, for: .content(previous))
            }
            context.coordinator.invalidateReadinessProbe()
        }
        context.coordinator.tabID = tabID
        let webView = BrowserWebKitAdapter.shared.ensureContext(for: tabID)
        let resolvedReadinessContext = context.coordinator.resolveReadinessContext(
            readinessContext,
            for: webView,
            fitting: uiView,
            tabID: tabID,
        )
        KeyboardDismissalSupport.setInteractiveDismissal(
            context.environment.scrollDismissesKeyboardMode == .interactively,
            on: webView.scrollView,
        )
        if webView.scrollView.refreshControl == nil {
            let refreshControl = UIRefreshControl()
            refreshControl.addTarget(
                context.coordinator,
                action: #selector(Coordinator.refreshControlValueChanged(_:)),
                for: .valueChanged,
            )
            webView.scrollView.refreshControl = refreshControl
        }
        BrowserWebKitAdapter.shared.attach(tabID: tabID, to: uiView)
        transitionRegistry?.report(.targetAttached(tabID))
        transitionRegistry?.register(
            webView,
            for: .content(tabID),
            representation: .live,
            isReady: false,
            readinessContext: resolvedReadinessContext,
        )
        context.coordinator.scheduleReadinessProbe(
            for: webView,
            tabID: tabID,
            readinessContext: resolvedReadinessContext,
        )
    }

    /// Detaches the visual surface while leaving context lifetime under adapter control.
    public static func dismantleUIView(_ uiView: UIView, coordinator: Coordinator) {
        if let mountedTabID = coordinator.tabID {
            let webView = BrowserWebKitAdapter.shared.webView(for: mountedTabID)
            coordinator.invalidateReadinessProbe()
            BrowserWebKitAdapter.shared.detach(tabID: mountedTabID, from: uiView)
            if let webView {
                coordinator.transitionRegistry?.unregister(webView, for: .content(mountedTabID))
            }
        }
    }
}
