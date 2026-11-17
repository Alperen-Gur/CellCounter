import Foundation
import CoreGraphics
import ImageIO

/// An image drawn once into an 8-bit DeviceGray plane at full resolution,
/// top row first: the pixels the native prompt-refinement fallback reads.
nonisolated struct PromptImagePlane: Sendable {
    let width: Int
    let height: Int
    let pixels: [UInt8]

    var byteCount: Int { pixels.count }

    /// The first image in the file, decoded as `ImageLoader` and the
    /// fallback always have.
    static func decodeImage(_ url: URL) throws -> CGImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw DetectionError.imageDecodeFailed
        }
        return image
    }

    /// Pixel dimensions from the file's properties, without decoding it.
    static func pixelSize(of url: URL) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              width > 0, height > 0 else { return nil }
        return (width, height)
    }

    /// The whole image in the grey format of `drawCrop`.
    static func draw(_ image: CGImage) throws -> PromptImagePlane {
        let width = image.width, height = image.height
        let pixels = try render(image, width: width, height: height, translateX: 0, translateY: 0)
        return PromptImagePlane(width: width, height: height, pixels: pixels)
    }

    /// Draws only a `width` x `height` rectangle of `image` whose top-left
    /// corner is (`x`, `y`) in image pixels (origin top left), row by row.
    /// Pixel for pixel the same as `draw(image).crop(...)`.
    static func drawCrop(of image: CGImage, x: Int, y: Int, width: Int, height: Int) throws -> [UInt8] {
        // Bitmap memory runs top row first while Core Graphics' y axis points
        // up, so the image is shifted to put the rectangle's top-left corner
        // at the context's top-left. (Before planes were kept the fallback
        // flipped the y axis here instead, which drew the rectangle mirrored
        // about the image's horizontal centre line.)
        try render(image, width: width, height: height,
                   translateX: -CGFloat(x), translateY: -CGFloat(image.height - y - height))
    }

    private static func render(_ image: CGImage, width: Int, height: Int,
                               translateX: CGFloat, translateY: CGFloat) throws -> [UInt8] {
        guard width > 0, height > 0 else { throw DetectionError.imageDecodeFailed }
        var pixels = [UInt8](repeating: 0, count: width * height)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: width,
                                          space: CGColorSpaceCreateDeviceGray(),
                                          bitmapInfo: CGImageAlphaInfo.none.rawValue) else {
                return false
            }
            context.interpolationQuality = .medium
            context.translateBy(x: translateX, y: translateY)
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return true
        }
        guard drawn else { throw DetectionError.imageDecodeFailed }
        return pixels
    }

    /// The pixels of a rectangle in image coordinates (origin top left), row
    /// by row. Pixels outside the image read 0, as an undrawn context does.
    func crop(x: Int, y: Int, width cropWidth: Int, height cropHeight: Int) -> [UInt8] {
        guard cropWidth > 0, cropHeight > 0 else { return [] }
        var out = [UInt8](repeating: 0, count: cropWidth * cropHeight)
        let firstColumn = max(0, x), endColumn = min(width, x + cropWidth)
        guard endColumn > firstColumn else { return out }
        let count = endColumn - firstColumn
        pixels.withUnsafeBufferPointer { source in
            out.withUnsafeMutableBufferPointer { destination in
                guard let from = source.baseAddress, let to = destination.baseAddress else { return }
                for row in 0..<cropHeight {
                    let sourceRow = y + row
                    guard sourceRow >= 0, sourceRow < height else { continue }
                    (to + row * cropWidth + (firstColumn - x))
                        .update(from: from + sourceRow * width + firstColumn, count: count)
                }
            }
        }
        return out
    }
}

/// Where the fallback reads a click's pixels from.
nonisolated enum PromptPixelSource: Sendable {
    /// The whole image, drawn once and kept in memory.
    case plane(PromptImagePlane)
    /// An image too large to keep: each click decodes the file and draws
    /// only its crop.
    case file(URL)
}

/// Grey planes of the images the native prompt-refinement fallback was used
/// on, so a click crops from memory instead of decoding the whole file again.
///
/// The first click on an image decodes it and draws it once (off this actor
/// and off the main thread); cancelling that click stops the work at the next
/// step. At most `countLimit` planes and `byteLimit` bytes are kept, least
/// recently used out first. An image larger than `byteLimit` is never drawn
/// whole: each of its clicks decodes the file and draws only the crop.
/// Entries are keyed by the file's path, size and modification date, so a
/// replaced file is read again. Memory pressure empties the cache.
actor PromptImagePlaneCache {
    static let shared = PromptImagePlaneCache()

    nonisolated static let defaultCountLimit = 2
    /// One byte per pixel.
    nonisolated static let defaultByteLimit = 128 * 1_024 * 1_024

    /// A file on disk, as it was when its pixels were read.
    nonisolated struct FileKey: Hashable, Sendable {
        let path: String
        let size: Int?
        let modified: Date?

        init(_ url: URL) {
            path = url.standardizedFileURL.path
            let attributes = try? FileManager.default.attributesOfItem(atPath: path)
            size = (attributes?[.size] as? NSNumber)?.intValue
            modified = attributes?[.modificationDate] as? Date
        }
    }

    private let countLimit: Int
    private let byteLimit: Int
    private var planes: [FileKey: PromptImagePlane] = [:]
    /// Least recently used first.
    private var order: [FileKey] = []
    private var bytes = 0

    init(countLimit: Int = PromptImagePlaneCache.defaultCountLimit,
         byteLimit: Int = PromptImagePlaneCache.defaultByteLimit) {
        self.countLimit = max(1, countLimit)
        self.byteLimit = max(1, byteLimit)
    }

    var cachedCount: Int { planes.count }
    var cachedBytes: Int { bytes }
    func isCached(_ url: URL) -> Bool { planes[FileKey(url)] != nil }

    /// The pixels of the image at `url`.
    ///
    /// - Throws: `DetectionError.imageDecodeFailed` when the file can't be
    ///   decoded, `CancellationError` when the calling task was cancelled.
    func source(for url: URL) async throws -> PromptPixelSource {
        try Task.checkCancellation()
        let key = FileKey(url)
        if let plane = planes[key] {
            touch(key)
            return .plane(plane)
        }
        let source = try await Self.load(url, byteLimit: byteLimit)
        if case .plane(let plane) = source { insert(plane, for: key) }
        // A finished plane is kept even for a caller that stopped waiting.
        try Task.checkCancellation()
        return source
    }

    func removeAll() {
        planes.removeAll()
        order.removeAll()
        bytes = 0
    }

    @concurrent
    nonisolated private static func load(_ url: URL, byteLimit: Int) async throws -> PromptPixelSource {
        if let size = PromptImagePlane.pixelSize(of: url), size.width * size.height > byteLimit {
            return .file(url)
        }
        let image = try PromptImagePlane.decodeImage(url)
        try Task.checkCancellation()
        guard image.width * image.height <= byteLimit else { return .file(url) }
        return .plane(try PromptImagePlane.draw(image))
    }

    private func touch(_ key: FileKey) {
        order.removeAll { $0 == key }
        order.append(key)
    }

    private func insert(_ plane: PromptImagePlane, for key: FileKey) {
        if let previous = planes.removeValue(forKey: key) {
            bytes -= previous.byteCount
            order.removeAll { $0 == key }
        }
        guard plane.byteCount <= byteLimit else { return }
        while !order.isEmpty, order.count >= countLimit || bytes + plane.byteCount > byteLimit {
            let oldest = order.removeFirst()
            if let evicted = planes.removeValue(forKey: oldest) { bytes -= evicted.byteCount }
        }
        planes[key] = plane
        order.append(key)
        bytes += plane.byteCount
    }
}
