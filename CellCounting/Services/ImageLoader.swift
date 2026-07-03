import Foundation
import AppKit
import ImageIO
import UniformTypeIdentifiers
import CryptoKit

/// Decodes JPEG/PNG/TIFF/BMP via ImageIO; rejects anything else with a clear error.
struct LoadedImage {
    let cgImage: CGImage
    let widthPx: Int
    let heightPx: Int
}

/// Pass-17: result of importFile — carries the new ImageRecord, decoded image,
/// SHA-256 hash (hex), and an optional EXIF px/µm value for Lane C to fill in.
struct ImportResult {
    let record: ImageRecord
    let image: LoadedImage
    let fileHash: String
    /// Reserved for Lane C (EXIF px/µm extraction). Always nil until Lane C lands.
    let exifPxPerUm: Double?
}

enum ImageLoadError: LocalizedError {
    case unsupportedFormat(String)
    case decodeFailed
    case ioError(Error)

    var errorDescription: String? {
        switch self {
        case .unsupportedFormat(let ext): return "Unsupported image format “.\(ext)”. CellCounter accepts JPEG, PNG, and TIFF."
        case .decodeFailed:               return "Couldn't decode the image."
        case .ioError(let e):             return "File read error: \(e.localizedDescription)"
        }
    }
}

enum ImageLoader {
    /// Accepted extensions, lowercased.
    static let supported: Set<String> = ["jpg", "jpeg", "png", "tif", "tiff", "bmp"]

    static func load(_ url: URL) throws -> LoadedImage {
        let ext = url.pathExtension.lowercased()
        guard supported.contains(ext) else { throw ImageLoadError.unsupportedFormat(ext) }
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { throw ImageLoadError.decodeFailed }
        guard let cg = CGImageSourceCreateImageAtIndex(src, 0, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            throw ImageLoadError.decodeFailed
        }
        return LoadedImage(cgImage: cg, widthPx: cg.width, heightPx: cg.height)
    }

    /// Imports a user-dropped file: copies into FileStore.imagesDir, decodes, computes SHA-256,
    /// and returns an ImportResult (record + image + hash + reserved EXIF slot for Lane C).
    /// Must be called off the MainActor (it does file I/O).
    ///
    /// `precomputedHash`: pass the SHA-256 already computed by the dedup pass in
    /// `AppState.importAndAnalyze` so we don't re-read and re-hash the whole file
    /// a second time. Nil (the default) recomputes it here, preserving the old
    /// behavior for any caller that doesn't have the hash on hand.
    nonisolated static func importFile(_ url: URL, precomputedHash: String? = nil) throws -> ImportResult {
        let loaded = try load(url)
        let fileName = url.lastPathComponent

        // Compute SHA-256 of the raw file bytes (full file — typical 17 MB TIFFs hash in <50 ms).
        // Reuse the dedup-pass hash when the caller threads it through.
        let fileHash = precomputedHash ?? sha256Hex(of: url)

        let record = ImageRecord(fileName: fileName,
                                  originalPath: url.path,
                                  widthPx: loaded.widthPx,
                                  heightPx: loaded.heightPx)
        record.fileHash = fileHash

        // copy into FileStore — always store under a lowercased extension so
        // `ImageRecord.storedURL` (which also lowercases) resolves identically
        // on reload regardless of how the user cased the file.
        let dest = FileStore.shared.imageURL(for: record.id,
                                              extension: (fileName as NSString).pathExtension.lowercased())
        try? FileManager.default.removeItem(at: dest)
        do {
            try FileManager.default.copyItem(at: url, to: dest)
        } catch {
            throw ImageLoadError.ioError(error)
        }
        // write a small JPEG thumbnail; log a warning but don't fail the import — thumbnails are non-essential.
        if !writeThumbnail(loaded.cgImage, to: FileStore.shared.thumbURL(for: record.id)) {
            print("[ImageLoader] warning: thumbnail write failed for \(record.id)")
        }
        // Pass-17 Lane C: detect EXIF px/µm from the original file (before copy,
        // so we read the source on its natural URL — the stored copy is identical
        // but the source URL is available here).
        let exifResult = EXIFCalibration.detectPxPerUm(at: url)
        let exifPxPerUm: Double?
        if let r = exifResult {
            switch r.confidence {
            case .high, .medium:
                exifPxPerUm = r.pxPerUm
                NSLog("[EXIFCalibration] %@ → %.4f px/µm (source: %@, confidence: %@)",
                      url.lastPathComponent, r.pxPerUm, r.source.description,
                      r.confidence == .high ? "high" : "medium")
            case .low:
                exifPxPerUm = nil
                NSLog("[EXIFCalibration] %@ → %.4f px/µm (source: %@) — LOW confidence, ignoring",
                      url.lastPathComponent, r.pxPerUm, r.source.description)
            }
        } else {
            exifPxPerUm = nil
            NSLog("[EXIFCalibration] %@ — no calibration metadata found", url.lastPathComponent)
        }

        return ImportResult(record: record, image: loaded, fileHash: fileHash ?? "", exifPxPerUm: exifPxPerUm)
    }

    /// Computes SHA-256 of the file at `url` and returns the hex-encoded digest.
    /// Returns nil only if the file cannot be read.
    /// `nonisolated` so callers inside `Task.detached` don't get main-actor warnings.
    nonisolated static func sha256Hex(of url: URL) -> String? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Writes a JPEG thumbnail scaled to fit within `maxDim`. Returns `true` on success.
    /// Failure is always non-fatal — callers should log a warning but not abort the import.
    @discardableResult
    static func writeThumbnail(_ cg: CGImage, to url: URL, maxDim: Int = 256) -> Bool {
        let scale = Double(maxDim) / Double(max(cg.width, cg.height))
        let w = Int(Double(cg.width) * scale)
        let h = Int(Double(cg.height) * scale)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                                   bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                   bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let scaled = ctx.makeImage() else { return false }
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { return false }
        CGImageDestinationAddImage(dest, scaled, [kCGImageDestinationLossyCompressionQuality: 0.7] as CFDictionary)
        return CGImageDestinationFinalize(dest)
    }

    static func loadStored(_ record: ImageRecord) -> LoadedImage? {
        try? load(record.storedURL)
    }

    /// Lightweight: just open the thumbnail JPEG for grid views.
    static func loadThumb(_ record: ImageRecord) -> NSImage? {
        NSImage(contentsOf: record.thumbURL)
    }
}
