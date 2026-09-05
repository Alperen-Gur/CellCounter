import Foundation
import CoreGraphics
import ImageIO
import Accelerate
import UniformTypeIdentifiers

/// Fast display-only equivalent of `_training_dataset.prepare_preview` for
/// ordinary 8-bit photographs. Never color-converts, composites alpha, applies
/// EXIF orientation, or substitutes a channel. Scientific stacks and other
/// layouts continue through the shared Python source reader.
nonisolated enum NativeSourcePreview {
    struct Plane: Sendable {
        let width: Int
        let height: Int
        let values: [Float]
    }

    static func png(for sample: TrainingSample) throws -> Data? {
        guard ["png", "jpg", "jpeg", "bmp"].contains(sample.sourceURL.pathExtension.lowercased()) else { return nil }
        guard ["max", "mean", "sum", "none"].contains(sample.zProjection) else {
            throw TrainingDatasetError.invalid("Unknown Z projection: \(sample.zProjection)")
        }
        try Task.checkCancellation()
        guard let source = CGImageSourceCreateWithURL(sample.sourceURL as CFURL,
            [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) == 1,
              let type = CGImageSourceGetType(source) as String?,
              [UTType.png.identifier, UTType.jpeg.identifier, UTType.bmp.identifier].contains(type),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= 64_000_000 / height,
              let image = CGImageSourceCreateImageAtIndex(source, 0,
                [kCGImageSourceShouldCacheImmediately: true] as CFDictionary),
              let plane = try plane(in: image, channel: sample.segmentChannel,
                                    rgbLuminance: sample.useRGBLuminance) else { return nil }
        return try png(plane)
    }

    static func plane(in image: CGImage, channel: Int?, rgbLuminance: Bool) throws -> Plane? {
        guard image.bitsPerComponent == 8, !image.bitmapInfo.contains(.floatComponents),
              let model = image.colorSpace?.model, model == .rgb || model == .monochrome,
              let data = image.dataProvider?.data else { return nil }
        defer { withExtendedLifetime(data) {} }
        let width = image.width, height = image.height
        let (count, overflow) = width.multipliedReportingOverflow(by: height)
        guard width > 0, height > 0, !overflow, count <= 64_000_000 else { return nil }
        let components = image.bitsPerPixel / 8
        guard image.bitsPerPixel % 8 == 0 else { return nil }
        let colorCount = model == .rgb ? 3 : 1
        let alpha = image.alphaInfo
        let hasAlpha = [.first, .last, .premultipliedFirst, .premultipliedLast].contains(alpha)
        let premultiplied = alpha == .premultipliedFirst || alpha == .premultipliedLast
        let leading = [.first, .premultipliedFirst, .noneSkipFirst].contains(alpha)
        guard components == colorCount + (alpha == .none ? 0 : 1),
              alpha != .alphaOnly else { return nil }
        // A CGImage's component order is logical; little-endian 32-bit storage
        // reverses those four component bytes in memory.
        let order = image.bitmapInfo.intersection(.byteOrderMask)
        guard order.isEmpty || order == .byteOrder32Big || order == .byteOrder32Little else { return nil }
        let reverse = order == .byteOrder32Little
        guard !reverse || components == 4 else { return nil }
        func offset(_ component: Int) -> Int { reverse ? components - 1 - component : component }
        let colorOffsets = (0..<colorCount).map { offset($0 + (leading ? 1 : 0)) }
        let alphaOffset = hasAlpha ? offset(leading ? 0 : components - 1) : nil
        let luminance = rgbLuminance && model == .rgb
        if !luminance, let channel, !(0..<colorCount).contains(channel) {
            throw TrainingDatasetError.invalid("Selected source channel is missing")
        }
        let stride = image.bytesPerRow
        let (byteCount, byteOverflow) = stride.multipliedReportingOverflow(by: height)
        guard !byteOverflow, stride >= width * components, CFDataGetLength(data) >= byteCount,
              let bytes = CFDataGetBytePtr(data) else { return nil }
        var values = [Float](repeating: 0, count: count)
        for y in 0..<height {
            if y % 32 == 0 { try Task.checkCancellation() }
            for x in 0..<width {
                let base = y * stride + x * components
                // Premultiplication loses original RGB values for transparent
                // pixels. Do not pretend that unpremultiplying recovers them.
                if premultiplied, let alphaOffset, bytes[base + alphaOffset] != 255 { return nil }
                let value: Float
                if luminance {
                    let red = Float(bytes[base + colorOffsets[0]]) * Float(0.299)
                    let green = Float(bytes[base + colorOffsets[1]]) * Float(0.587)
                    let blue = Float(bytes[base + colorOffsets[2]]) * Float(0.114)
                    value = (red + green) + blue
                } else if let channel {
                    value = Float(bytes[base + colorOffsets[channel]])
                } else {
                    value = colorOffsets.reduce(Float(0)) { $0 + Float(bytes[base + $1]) } / Float(colorCount)
                }
                values[y * width + x] = value
            }
        }
        return Plane(width: width, height: height, values: values)
    }

    static func displayBytes(_ values: [Float]) throws -> [UInt8] {
        guard !values.isEmpty, values.allSatisfy(\.isFinite) else {
            throw TrainingDatasetError.invalid("Source contains empty or non-finite pixels")
        }
        try Task.checkCancellation()
        var sorted = values
        vDSP_vsort(&sorted, vDSP_Length(sorted.count), 1)
        // NumPy's default percentile method linearly interpolates adjacent
        // sorted samples at (N - 1) * q; it is not a histogram approximation.
        func percentile(_ q: Double) -> Double {
            let position = Double(sorted.count - 1) * q
            let lower = Int(position), upper = min(lower + 1, sorted.count - 1)
            let fraction = position - Double(lower)
            return Double(sorted[lower]) + (Double(sorted[upper]) - Double(sorted[lower])) * fraction
        }
        let low = percentile(0.01), high = percentile(0.99)
        let scale = max(high - low, 1e-8)
        var result = [UInt8](repeating: 0, count: values.count)
        for index in values.indices {
            if index % 65_536 == 0 { try Task.checkCancellation() }
            let value = min(1, max(0, (Double(values[index]) - low) / scale))
            result[index] = UInt8(value * 255)
        }
        return result
    }

    private static func png(_ plane: Plane) throws -> Data? {
        let bytes = try displayBytes(plane.values)
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let image = CGImage(width: plane.width, height: plane.height,
                bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: plane.width,
                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent),
              let output = CFDataCreateMutable(kCFAllocatorDefault, 0),
              let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }
}
