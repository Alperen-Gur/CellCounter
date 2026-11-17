import Foundation
import CoreGraphics
import ImageIO

/// 256-bucket grey-level histogram shown under "Intensity histogram".
nonisolated struct IntensityHistogramData: Equatable, Sendable {
    let buckets: [Int]       // 256 entries
    let minVal: Int
    let maxVal: Int
    let mean: Double
    let sigma: Double

    static let empty = IntensityHistogramData(buckets: Array(repeating: 0, count: 256),
                                              minVal: 0, maxVal: 0, mean: 0, sigma: 0)
}

/// One point of a line profile: its index along the line and its grey level.
nonisolated struct LineProfileSample: Equatable, Sendable {
    let position: Int   // 0..<count
    let intensity: Double
}

/// Histogram and line-profile pixels for the Results sidebar and viewer.
///
/// Callers resolve the image's decodable file URL on the main actor and pass
/// only that value here, so no SwiftData model crosses actors. Work runs on
/// this actor, and each request is skipped when its calling task (a view's
/// `.task(id:)`) has been cancelled.
///
/// The pixels are produced exactly as before: the same ImageIO decode as
/// `ImageLoader.load`, the same 8-bit DeviceGray `CGContext` draw (a 512 px
/// downsample for the histogram, full resolution for the profile) and the
/// same arithmetic. What changed is how often that happens: a histogram is
/// kept per file, and the full-resolution grey plane of the image being
/// profiled is kept while the profile tool is open (up to
/// `planeByteLimit`), instead of being rebuilt for every line.
actor ResultsPixelSampler {
    static let shared = ResultsPixelSampler()

    /// A file on disk, as it was when its pixels were read.
    nonisolated private struct FileKey: Hashable {
        let url: URL
        let size: Int?
        let modified: Date?

        init(_ url: URL) {
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            self.url = url
            size = values?.fileSize
            modified = values?.contentModificationDate
        }
    }

    nonisolated private struct GreyPlane {
        let pixels: [UInt8]
        let width: Int
        let height: Int
    }

    private let histogramLimit = 64
    private var histograms: [FileKey: IntensityHistogramData] = [:]
    /// Large planes are not kept: one byte per source pixel.
    private let planeByteLimit = 64 * 1_024 * 1_024
    private var plane: (key: FileKey, value: GreyPlane)?

    /// Nil when the calling task was cancelled; `.empty` when the file can't
    /// be decoded (as before).
    func histogram(at url: URL) -> IntensityHistogramData? {
        guard !Task.isCancelled else { return nil }
        let key = FileKey(url)
        if let cached = histograms[key] { return cached }
        guard let image = Self.decode(url) else { return .empty }
        guard !Task.isCancelled else { return nil }
        let data = Self.histogram(of: image)
        if histograms.count >= histogramLimit { histograms.removeAll(keepingCapacity: true) }
        histograms[key] = data
        return data
    }

    /// Nil when the calling task was cancelled; empty when the file can't be
    /// decoded (as before). `start`/`end` are source-pixel coordinates.
    func profile(at url: URL, from start: CGPoint, to end: CGPoint,
                 count: Int) -> [LineProfileSample]? {
        guard !Task.isCancelled else { return nil }
        guard count > 0 else { return [] }
        let key = FileKey(url)
        let grey: GreyPlane
        if let plane, plane.key == key {
            grey = plane.value
        } else {
            guard let image = Self.decode(url), let made = Self.greyPlane(of: image) else { return [] }
            guard !Task.isCancelled else { return nil }
            grey = made
            plane = made.pixels.count <= planeByteLimit ? (key, made) : nil
        }
        return Self.sample(grey, from: start, to: end, count: count)
    }

    /// Drop the kept grey plane of `url` (the profile tool closed).
    func releasePlane(for url: URL) {
        if plane?.key.url == url { plane = nil }
    }

    // MARK: — Pixels (unchanged arithmetic)

    /// The decode `ImageLoader.load` performs for an already resolved,
    /// natively supported URL.
    nonisolated private static func decode(_ url: URL) -> CGImage? {
        LocalTiming.measure(.imageDecode) { () -> CGImage? in
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
            return CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCache: false] as CFDictionary)
        }
    }

    /// Histogram of the image downsampled to at most 512 px.
    nonisolated private static func histogram(of src: CGImage) -> IntensityHistogramData {
        let maxDim = 512
        let srcW = src.width, srcH = src.height
        let scale = min(1.0, Double(maxDim) / Double(max(srcW, srcH)))
        let dstW = max(1, Int(Double(srcW) * scale))
        let dstH = max(1, Int(Double(srcH) * scale))

        var pixels = [UInt8](repeating: 0, count: dstW * dstH)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let ctx = CGContext(data: buffer.baseAddress,
                                      width: dstW, height: dstH,
                                      bitsPerComponent: 8, bytesPerRow: dstW,
                                      space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            ctx.draw(src, in: CGRect(x: 0, y: 0, width: dstW, height: dstH))
            return true
        }
        guard drawn else { return .empty }

        var buckets = Array(repeating: 0, count: 256)
        var sum: Double = 0
        var minV = 255, maxV = 0
        for v in pixels {
            buckets[Int(v)] += 1
            sum += Double(v)
            if Int(v) < minV { minV = Int(v) }
            if Int(v) > maxV { maxV = Int(v) }
        }
        let n = Double(pixels.count)
        let mean = n > 0 ? sum / n : 0
        var variance: Double = 0
        for v in pixels { variance += (Double(v) - mean) * (Double(v) - mean) }
        let sigma = n > 1 ? sqrt(variance / n) : 0

        return IntensityHistogramData(buckets: buckets, minVal: minV, maxVal: maxV,
                                      mean: mean, sigma: sigma)
    }

    /// Full-resolution 8-bit grey rendering of the image.
    nonisolated private static func greyPlane(of cg: CGImage) -> GreyPlane? {
        let w = cg.width, h = cg.height
        guard w > 0, h > 0 else { return nil }
        var pixels = [UInt8](repeating: 0, count: w * h)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let ctx = CGContext(data: buffer.baseAddress, width: w, height: h,
                                      bitsPerComponent: 8, bytesPerRow: w,
                                      space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        return drawn ? GreyPlane(pixels: pixels, width: w, height: h) : nil
    }

    /// `count` evenly spaced bilinear samples from `start` to `end`.
    nonisolated private static func sample(_ plane: GreyPlane, from start: CGPoint, to end: CGPoint,
                               count: Int) -> [LineProfileSample] {
        var result: [LineProfileSample] = []
        result.reserveCapacity(count)
        let dx = Double(end.x - start.x) / Double(count - 1)
        let dy = Double(end.y - start.y) / Double(count - 1)
        for i in 0..<count {
            let px = Double(start.x) + dx * Double(i)
            let py = Double(start.y) + dy * Double(i)
            let intensity = bilinear(pixels: plane.pixels, width: plane.width, height: plane.height,
                                     x: px, y: py)
            result.append(LineProfileSample(position: i, intensity: intensity))
        }
        return result
    }

    /// Bilinear interpolation. Returns 0 for out-of-bounds samples (clamp at border).
    nonisolated private static func bilinear(pixels: [UInt8], width: Int, height: Int,
                                 x: Double, y: Double) -> Double {
        let x0 = max(0, min(width  - 1, Int(x)))
        let y0 = max(0, min(height - 1, Int(y)))
        let x1 = min(width  - 1, x0 + 1)
        let y1 = min(height - 1, y0 + 1)
        let fx = x - Double(x0)
        let fy = y - Double(y0)
        let p00 = Double(pixels[y0 * width + x0])
        let p10 = Double(pixels[y0 * width + x1])
        let p01 = Double(pixels[y1 * width + x0])
        let p11 = Double(pixels[y1 * width + x1])
        return p00 * (1 - fx) * (1 - fy)
             + p10 * fx       * (1 - fy)
             + p01 * (1 - fx) * fy
             + p11 * fx       * fy
    }
}
