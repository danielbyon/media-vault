//
//  BrowserWebKitVisualEvidence.swift
//  MediaVault
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import UIKit
import WebKit

/// A small, memory-only visual signature used to compare a live page with revision evidence.
///
/// A nontransparent pixel only proves that a WebKit backing surface was allocated. The Browser
/// instead compares a tiny normalized sample against the current revision's preview. Dark and
/// uniformly colored pages remain valid page evidence only when that trusted preview agrees.
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

    /// Distinguishes a known blank black frame from other visual mismatches.
    var isUniformBlack: Bool {
        samples.allSatisfy { sample in
            sample.red <= 8
                && sample.green <= 8
                && sample.blue <= 8
                && sample.alpha >= 248
        }
    }

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
        guard let image = BrowserSurfaceRenderer.image(
            from: view,
            afterScreenUpdates: false,
            opaque: false,
            renderingPolicy: view is WKWebView ? .webKit : .appOwnedTransition,
            outputSize: CGSize(width: Self.renderDimension, height: Self.renderDimension),
        ), let cgImage = image.cgImage else {
            return nil
        }

        self.init(cgImage: cgImage)
    }

    /// Compares sampled output with tolerance for compositor and image-decoder variation.
    func approximatelyMatches(_ other: Self) -> Bool {
        guard samples.count == other.samples.count else {
            return false
        }

        let matchingSamples = zip(samples, other.samples).reduce(into: 0) { count, pair in
            let (left, right) = pair
            if abs(Int(left.red) - Int(right.red)) <= Int(Self.channelTolerance),
               abs(Int(left.green) - Int(right.green)) <= Int(Self.channelTolerance),
               abs(Int(left.blue) - Int(right.blue)) <= Int(Self.channelTolerance),
               abs(Int(left.alpha) - Int(right.alpha)) <= Int(Self.channelTolerance) {
                count += 1
            }
        }

        // Text and antialiasing can change a small part of a page between its preview and its
        // live WebKit rendering. Require a strong majority of matching samples so those local
        // differences are tolerated without accepting a uniformly blank or covered surface.
        let minimumMatchingSamples = (samples.count * 3 + 3) / 4
        return matchingSamples >= minimumMatchingSamples
    }

    /// Applies the readiness policy's explicit black-surface rule before approximate matching.
    func matches(expected: Self) -> Bool {
        if isUniformBlack {
            return expected.isUniformBlack
        }

        return approximatelyMatches(expected)
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
        let sampleValues = Self.samples(from: bytes)
        samples = sampleValues.sorted { left, right in
            Self.sortKey(for: left) < Self.sortKey(for: right)
        }
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
    }

    private static func sortKey(for sample: Sample) -> UInt32 {
        UInt32(sample.red) << 24
            | UInt32(sample.green) << 16
            | UInt32(sample.blue) << 8
            | UInt32(sample.alpha)
    }
}

/// Provides the direct-cover check used to reject an app-owned surface over WebKit content.
@MainActor
struct BrowserWebKitVisualEvidence {
    /// Rejects a direct opaque UIKit child that covers the registered WebKit boundary.
    static func hasOpaqueCover(in webView: WKWebView) -> Bool {
        webView.subviews.contains { subview in
            guard subview !== webView.scrollView,
                  !subview.isHidden,
                  subview.alpha >= 0.99,
                  webView.bounds.insetBy(dx: -1, dy: -1).contains(
                      subview.convert(subview.bounds, to: webView),
                  )
            else {
                return false
            }

            // WebKit's content view is an out-of-process rendering surface rather than an
            // app-owned colored overlay. Use only public UIKit state here; do not depend on
            // undocumented WebKit class-name prefixes to identify it.
            return subview.isOpaque && (subview.backgroundColor?.cgColor.alpha ?? 0) >= 0.99
        }
    }
}
