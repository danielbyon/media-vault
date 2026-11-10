//
//  ScenePrivacyCoverSentinelTestSupport.swift
//  MediaVault
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import CoreFoundation
import CoreGraphics
import ObjectiveC
import QuartzCore
import UIKit

/// Counts RGB changes in sentinel regions from paired-color window captures.
@MainActor
enum ScenePrivacyCoverSentinelTestSupport {
    static func colorInfluencePixelCounts(
        in window: UIWindow,
        patches: [UIView],
        centeredAt points: [CGPoint],
    ) throws -> [Int] {
        guard patches.count == points.count, !patches.isEmpty else {
            throw RasterizationFailure.invalidSentinelLayout
        }

        let originalColors = patches.map { $0.backgroundColor ?? .clear }
        defer {
            setPatchColors(originalColors, on: patches, in: window)
        }

        setPatchColors(Array(repeating: .magenta, count: patches.count), on: patches, in: window)
        let magentaPixels = try capturePixels(in: window)

        setPatchColors(Array(repeating: .green, count: patches.count), on: patches, in: window)
        let greenPixels = try capturePixels(in: window)

        return try points.map { point in
            try rgbDifferencePixelCount(
                between: magentaPixels,
                and: greenPixels,
                centeredAt: point,
            )
        }
    }

    private static func setPatchColors(_ colors: [UIColor], on patches: [UIView], in window: UIWindow) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        UIView.performWithoutAnimation {
            for (patch, color) in zip(patches, colors) {
                patch.backgroundColor = color
            }
            window.layoutIfNeeded()
        }
        CATransaction.commit()
    }

    private static func capturePixels(in window: UIWindow) throws -> WindowPixels {
        let width = Int(window.bounds.width.rounded())
        let height = Int(window.bounds.height.rounded())
        guard width > 0, height > 0,
              CGFloat(width) == window.bounds.width,
              CGFloat(height) == window.bounds.height
        else {
            throw RasterizationFailure.invalidWindowDimensions
        }

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(bounds: window.bounds, format: format)
        var renderedHierarchy = false
        let image = renderer.image { _ in
            renderedHierarchy = window.drawHierarchy(
                in: window.bounds,
                afterScreenUpdates: true,
            )
        }
        guard renderedHierarchy,
              let cgImage = image.cgImage,
              cgImage.width == width,
              cgImage.height == height
        else {
            throw RasterizationFailure.windowCaptureFailed
        }

        let bytesPerRow = width * 4
        var pixelData = [UInt8](repeating: 0, count: bytesPerRow * height)
        let bitmapInfo = CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
        let rendered = pixelData.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: bitmapInfo,
            ) else {
                return false
            }

            context.translateBy(x: 0, y: CGFloat(height))
            context.scaleBy(x: 1, y: -1)
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard rendered, pixelData.count == bytesPerRow * height else {
            throw RasterizationFailure.bitmapRenderingFailed
        }

        return WindowPixels(width: width, height: height, rgba: pixelData)
    }

    private static func rgbDifferencePixelCount(
        between first: WindowPixels,
        and second: WindowPixels,
        centeredAt point: CGPoint,
    ) throws -> Int {
        guard first.width == second.width,
              first.height == second.height,
              first.rgba.count == first.width * first.height * 4,
              second.rgba.count == second.width * second.height * 4
        else {
            throw RasterizationFailure.invalidPixelBuffer
        }

        let sideLength = 8
        let originX = Int((point.x - CGFloat(sideLength) / 2).rounded(.down))
        let originY = Int((point.y - CGFloat(sideLength) / 2).rounded(.down))
        guard originX >= 0,
              originY >= 0,
              originX + sideLength <= first.width,
              originY + sideLength <= first.height
        else {
            throw RasterizationFailure.sentinelRegionOutOfBounds
        }

        var differentPixels = 0
        for y in originY ..< originY + sideLength {
            for x in originX ..< originX + sideLength {
                let offset = (y * first.width + x) * 4
                if first.rgba[offset] != second.rgba[offset]
                    || first.rgba[offset + 1] != second.rgba[offset + 1]
                    || first.rgba[offset + 2] != second.rgba[offset + 2] {
                    differentPixels += 1
                }
            }
        }
        return differentPixels
    }

    private struct WindowPixels {
        let width: Int
        let height: Int
        let rgba: [UInt8]
    }

    private enum RasterizationFailure: Error {
        case invalidSentinelLayout
        case invalidWindowDimensions
        case windowCaptureFailed
        case bitmapRenderingFailed
        case invalidPixelBuffer
        case sentinelRegionOutOfBounds
    }
}
