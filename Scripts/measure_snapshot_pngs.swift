import Foundation
import CoreGraphics
import ImageIO
import Darwin

struct Raster {
    let width: Int
    let height: Int
    let rgba: [UInt8]
}

func diagnosticError(_ message: String, code: Int) -> NSError {
    NSError(domain: "Issue9FailureBDiagnostic", code: code, userInfo: [
        NSLocalizedDescriptionKey: message
    ])
}

func decodePNG(_ path: String) throws -> Raster {
    let url = URL(fileURLWithPath: path)
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
    else {
        throw diagnosticError("Could not decode PNG at \(path)", code: 1)
    }

    let width = image.width
    let height = image.height
    let bytesPerRow = width * 4
    var rgba = [UInt8](repeating: 0, count: height * bytesPerRow)
    guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else {
        throw diagnosticError("Could not create the sRGB color space", code: 2)
    }

    var didDraw = false
    rgba.withUnsafeMutableBytes { buffer in
        let bitmapInfo = CGBitmapInfo.byteOrder32Big.rawValue
            | CGImageAlphaInfo.premultipliedLast.rawValue
        guard let context = CGContext(
            data: buffer.baseAddress,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else {
            return
        }
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        didDraw = true
    }
    guard didDraw else {
        throw diagnosticError("Could not render PNG pixels into sRGB", code: 3)
    }
    return Raster(width: width, height: height, rgba: rgba)
}

func differenceImage(_ reference: Raster, _ actual: Raster) throws -> CGImage {
    guard reference.width == actual.width, reference.height == actual.height else {
        throw diagnosticError("Pixel mask requires equal image dimensions", code: 4)
    }
    guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else {
        throw diagnosticError("Could not create the sRGB color space", code: 2)
    }
    let bytesPerPixel = 4
    var mask = [UInt8](repeating: 0, count: reference.width * reference.height * bytesPerPixel)
    for pixel in 0..<(reference.width * reference.height) {
        let offset = pixel * bytesPerPixel
        let changed = (0..<bytesPerPixel).contains {
            reference.rgba[offset + $0] != actual.rgba[offset + $0]
        }
        mask[offset] = changed ? 255 : 0
        mask[offset + 1] = 0
        mask[offset + 2] = changed ? 255 : 0
        mask[offset + 3] = 255
    }
    let bitmapInfo = CGBitmapInfo.byteOrder32Big.rawValue
        | CGImageAlphaInfo.premultipliedLast.rawValue
    let provider = CGDataProvider(data: Data(mask) as CFData)!
    guard let image = CGImage(
        width: reference.width,
        height: reference.height,
        bitsPerComponent: 8,
        bitsPerPixel: 32,
        bytesPerRow: reference.width * bytesPerPixel,
        space: colorSpace,
        bitmapInfo: CGBitmapInfo(rawValue: bitmapInfo),
        provider: provider,
        decode: nil,
        shouldInterpolate: false,
        intent: .defaultIntent
    ) else {
        throw diagnosticError("Could not create the difference mask", code: 5)
    }
    return image
}

func writePNG(_ image: CGImage, to path: String) throws {
    let url = URL(fileURLWithPath: path)
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    guard let destination = CGImageDestinationCreateWithURL(
        url as CFURL,
        "public.png" as CFString,
        1,
        nil
    ) else {
        throw diagnosticError("Could not create PNG output at \(path)", code: 6)
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
        throw diagnosticError("Could not write PNG output at \(path)", code: 7)
    }
}

func pixelMetrics(
    reference: Raster,
    actual: Raster
) -> (differingPixels: Int, maxChannelDifference: Int) {
    var differingPixels = 0
    var maxChannelDifference = 0
    for pixel in 0..<(reference.width * reference.height) {
        let offset = pixel * 4
        var pixelDiffers = false
        for channel in 0..<4 {
            let delta = abs(
                Int(reference.rgba[offset + channel]) - Int(actual.rgba[offset + channel])
            )
            if delta > 0 {
                pixelDiffers = true
                maxChannelDifference = max(maxChannelDifference, delta)
            }
        }
        if pixelDiffers {
            differingPixels += 1
        }
    }
    return (differingPixels, maxChannelDifference)
}

func dimensionMismatchResult(snapshot: String, reference: Raster, actual: Raster) -> [String: Any] {
    [
        "snapshot": snapshot,
        "status": "dimension-mismatch",
        "referenceWidth": reference.width,
        "referenceHeight": reference.height,
        "actualWidth": actual.width,
        "actualHeight": actual.height,
        "dimensionsMatch": false,
        "pixelDifferenceCount": NSNull(),
        "maxChannelDifference": NSNull(),
        "differenceImagePath": NSNull(),
        "colorSpace": "sRGB",
        "channels": "8-bit premultiplied RGBA"
    ]
}

func compareMatchingDimensions(
    snapshot: String,
    reference: Raster,
    actual: Raster,
    differencePath: String?
) -> [String: Any] {
    let metrics = pixelMetrics(reference: reference, actual: actual)
    var result: [String: Any] = [
        "snapshot": snapshot,
        "status": "compared",
        "width": reference.width,
        "height": reference.height,
        "dimensionsMatch": true,
        "totalPixels": reference.width * reference.height,
        "pixelDifferenceCount": metrics.differingPixels,
        "maxChannelDifference": metrics.maxChannelDifference,
        "colorSpace": "sRGB",
        "channels": "8-bit premultiplied RGBA",
        "differenceMask": "opaque magenta marks changed pixels"
    ]
    if let differencePath {
        do {
            let image = try differenceImage(reference, actual)
            try writePNG(image, to: differencePath)
            result["differenceImagePath"] = differencePath
        } catch {
            result["differenceImageError"] = String(describing: error)
        }
    }
    return result
}

func compare(_ pair: [String: Any]) -> [String: Any] {
    let snapshot = pair["snapshot"] as? String ?? "unknown"
    guard let referencePath = pair["reference_path"] as? String,
          let actualPath = pair["actual_path"] as? String else {
        return ["snapshot": snapshot, "status": "missing-image"]
    }
    do {
        let reference = try decodePNG(referencePath)
        let actual = try decodePNG(actualPath)
        guard reference.width == actual.width, reference.height == actual.height else {
            return dimensionMismatchResult(snapshot: snapshot, reference: reference, actual: actual)
        }
        return compareMatchingDimensions(
            snapshot: snapshot,
            reference: reference,
            actual: actual,
            differencePath: pair["difference_path"] as? String
        )
    } catch {
        return [
            "snapshot": snapshot,
            "status": "decode-error",
            "error": String(describing: error)
        ]
    }
}

func run() throws -> Int32 {
    let arguments = CommandLine.arguments
    guard arguments.count == 3 else {
        FileHandle.standardError.write(Data(
            "Usage: measure_snapshot_pngs.swift pairs.json output.json\n".utf8
        ))
        return 2
    }

    let pairData = try Data(contentsOf: URL(fileURLWithPath: arguments[1]))
    let pairs = try JSONSerialization.jsonObject(with: pairData) as? [[String: Any]] ?? []
    let results = pairs.map(compare)
    let outputData = try JSONSerialization.data(
        withJSONObject: results,
        options: [.prettyPrinted, .sortedKeys]
    )
    try outputData.write(to: URL(fileURLWithPath: arguments[2]), options: .atomic)
    return results.contains(where: { result in
        let status = result["status"] as? String ?? ""
        return status == "decode-error" || status == "missing-image"
            || result["differenceImageError"] != nil
    }) ? 1 : 0
}

do {
    exit(try run())
} catch {
    FileHandle.standardError.write(Data("Snapshot metric failure: \(error)\n".utf8))
    exit(1)
}
