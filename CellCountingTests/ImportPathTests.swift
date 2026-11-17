import Foundation
import SwiftData
import Testing
import CryptoKit
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers
@testable import CellCounting

/// The import path reads each file once and builds its work off the main
/// actor; these tests check its results equal the previous implementation's.
/// All files live in temporary folders.
@Suite(.serialized) @MainActor
struct ImportPathTests {
    private func temporary() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("import-path-test-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Deterministic bytes that differ from chunk to chunk.
    private func bytes(_ count: Int, seed: UInt32 = 1) -> Data {
        var state = seed
        var data = Data(count: count)
        data.withUnsafeMutableBytes { raw in
            for index in raw.indices {
                state = state &* 1_664_525 &+ 1_013_904_223
                raw[index] = UInt8(truncatingIfNeeded: state >> 24)
            }
        }
        return data
    }

    private func digestBytes(hex: String) -> Data? {
        var data = Data()
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2, limitedBy: hex.endIndex) ?? hex.endIndex
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            data.append(byte)
            index = next
        }
        return data
    }

    /// The previous import: `FileManager.copyItem`, then SHA-256 of the copy
    /// read whole (`ImageLoader.sha256Hex` used `.mappedIfSafe`).
    private func previousCopyAndHash(_ source: URL, to destination: URL) throws -> (hex: String, digest: Data) {
        try FileManager.default.copyItem(at: source, to: destination)
        let digest = SHA256.hash(data: try Data(contentsOf: destination, options: .mappedIfSafe))
        return (digest.map { String(format: "%02x", $0) }.joined(), Data(digest))
    }

    private func writeImage(_ url: URL, type: UTType, width: Int, height: Int,
                            gray16: Bool = false, pages: Int = 1) throws {
        let context: CGContext
        if gray16 {
            context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 16,
                                             bytesPerRow: 0, space: CGColorSpaceCreateDeviceGray(),
                                             bitmapInfo: CGImageAlphaInfo.none.rawValue))
        } else {
            context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                             bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        }
        for band in 0..<8 {
            let level = CGFloat(band) / 7
            context.setFillColor(CGColor(red: level, green: 1 - level, blue: 0.5, alpha: 1))
            context.fill(CGRect(x: band * width / 8, y: 0, width: width / 8 + 1, height: height))
        }
        let image = try #require(context.makeImage())
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString,
                                                                       pages, nil))
        for _ in 0..<pages { CGImageDestinationAddImage(destination, image, nil) }
        #expect(CGImageDestinationFinalize(destination))
    }

    private func pixelSizeAndType(_ url: URL) throws -> (width: Int, height: Int, type: String) {
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        let width = try #require(properties[kCGImagePropertyPixelWidth] as? Int)
        let height = try #require(properties[kCGImagePropertyPixelHeight] as? Int)
        return (width, height, (CGImageSourceGetType(source) as String?) ?? "")
    }

    @Test func streamingCopyAndHashEqualsCopyThenHash() throws {
        let directory = try temporary(); defer { try? FileManager.default.removeItem(at: directory) }
        let chunk = 64 * 1_024
        for (index, size) in [0, 1, chunk - 1, chunk, chunk + 1, 5 * chunk + 17].enumerated() {
            let source = directory.appendingPathComponent("source-\(index).tif")
            try bytes(size, seed: UInt32(index + 1)).write(to: source)
            let previousURL = directory.appendingPathComponent("previous-\(index).tif")
            let previous = try previousCopyAndHash(source, to: previousURL)
            let previousBytes = try Data(contentsOf: previousURL)

            // Streaming write (another volume) and clone (same volume).
            for allowClone in [false, true] {
                let destination = directory.appendingPathComponent("new-\(index)-\(allowClone).tif")
                let hash = try ImportFileDigest.copyAndHash(from: source, to: destination,
                                                            chunkSize: chunk, allowClone: allowClone)
                #expect(hash == previous.hex)
                #expect(digestBytes(hex: hash) == previous.digest)
                #expect(try Data(contentsOf: destination) == previousBytes)
                // The copy keeps the source's modification time, like copyItem.
                #expect(ImportFileStamp(fileAt: destination) == ImportFileStamp(fileAt: previousURL))
            }
            // Without a reusable drop hash, the import copy hashes what it writes.
            let imported = directory.appendingPathComponent("imported-\(index).tif")
            #expect(try ImportFileDigest.copy(source, to: imported, knownHash: nil, knownStamp: nil,
                                              chunkSize: chunk) == previous.hex)
            #expect(try Data(contentsOf: imported) == previousBytes)
            // Drop-time hashing gives the same value.
            #expect(ImportFileDigest.sha256Hex(of: source, chunkSize: chunk) == previous.hex)
            #expect(ImportFileDigest.digest(of: source, chunkSize: chunk)?.hash == previous.hex)
            #expect(ImageLoader.sha256Hex(of: source) == previous.hex)
        }
        #expect(ImageLoader.sha256Hex(of: directory.appendingPathComponent("missing.tif")) == nil)
        // An existing destination is never overwritten, and a failed copy leaves nothing behind.
        let source = directory.appendingPathComponent("source-1.tif")
        #expect(throws: (any Error).self) {
            try ImportFileDigest.copyAndHash(from: source, to: directory.appendingPathComponent("previous-2.tif"),
                                             allowClone: false)
        }
        #expect(try Data(contentsOf: directory.appendingPathComponent("previous-2.tif")).count == chunk - 1)
        let failed = directory.appendingPathComponent("failed.tif")
        #expect(throws: (any Error).self) {
            try ImportFileDigest.copyAndHash(from: directory.appendingPathComponent("missing.tif"), to: failed)
        }
        #expect(!FileManager.default.fileExists(atPath: failed.path))
    }

    @Test func dropHashIsReusedOnlyWhileSizeAndModificationTimeMatch() throws {
        let directory = try temporary(); defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.tif")
        let content = bytes(300_000)
        try content.write(to: source)
        let stampedTime = Date(timeIntervalSince1970: 1_600_000_000.5)
        try FileManager.default.setAttributes([.modificationDate: stampedTime], ofItemAtPath: source.path)
        let digest = try #require(ImportFileDigest.digest(of: source))
        let stamp = try #require(digest.stamp)
        #expect(stamp == ImportFileStamp(fileAt: source))
        #expect(stamp.size == Int64(content.count))
        #expect(ImportFileStamp(fileAt: directory.appendingPathComponent("missing.tif")) == nil)

        // A marker shows whether the drop hash was reused or the copy was hashed.
        let marker = String(repeating: "ab", count: 32)
        var copies = 0
        func importedHash(_ knownHash: String?, _ knownStamp: ImportFileStamp?) throws -> String {
            copies += 1
            let destination = directory.appendingPathComponent("copy-\(copies).tif")
            let hash = try ImportFileDigest.copy(source, to: destination, knownHash: knownHash, knownStamp: knownStamp)
            #expect(try Data(contentsOf: destination) == Data(contentsOf: source))
            return hash
        }

        // Same size and modification time: reused, the file is only copied.
        #expect(try importedHash(marker, stamp) == marker)
        // No stamp, or no hash: the copy is hashed.
        #expect(try importedHash(marker, nil) == digest.hash)
        #expect(try importedHash(nil, stamp) == digest.hash)
        // Modification time changed (same bytes and size): hashed again.
        try FileManager.default.setAttributes([.modificationDate: stampedTime.addingTimeInterval(1)],
                                              ofItemAtPath: source.path)
        #expect(try importedHash(marker, stamp) == digest.hash)
        // Size changed, modification time put back: hashed, giving the new content's hash.
        var grown = content
        grown.append(7)
        try grown.write(to: source)
        try FileManager.default.setAttributes([.modificationDate: stampedTime], ofItemAtPath: source.path)
        #expect(ImportFileStamp(fileAt: source)?.modifiedNanoseconds == stamp.modifiedNanoseconds)
        #expect(try importedHash(marker, stamp) == ImportFileDigest.hex(SHA256.hash(data: grown)))
        // Back to the stamped size and time: reused again.
        try content.write(to: source)
        try FileManager.default.setAttributes([.modificationDate: stampedTime], ofItemAtPath: source.path)
        #expect(try importedHash(marker, stamp) == marker)
    }

    @Test func thumbnailHasThePreviousPixelSizeAndFormat() throws {
        let directory = try temporary(); defer { try? FileManager.default.removeItem(at: directory) }
        let cases: [(name: String, type: UTType, width: Int, height: Int, gray16: Bool, pages: Int)] = [
            ("landscape.png", .png, 640, 480, false, 1),
            ("portrait16.tif", .tiff, 300, 1_000, true, 1),
            ("small.png", .png, 100, 60, false, 1),
            ("odd.jpg", .jpeg, 1_001, 333, false, 1),
            ("stack.tif", .tiff, 513, 257, false, 2),
            ("exact.tif", .tiff, 256, 64, false, 1),
        ]
        for item in cases {
            let url = directory.appendingPathComponent(item.name)
            try writeImage(url, type: item.type, width: item.width, height: item.height,
                           gray16: item.gray16, pages: item.pages)
            let loaded = try ImageLoader.load(url)
            let previousURL = directory.appendingPathComponent("previous-\(item.name).jpg")
            let newURL = directory.appendingPathComponent("new-\(item.name).jpg")
            #expect(ImageLoader.writeThumbnail(loaded.cgImage, to: previousURL))
            #expect(ImageLoader.writeThumbnail(fromImageAt: url, pixelWidth: loaded.widthPx,
                                               pixelHeight: loaded.heightPx, to: newURL))
            let previous = try pixelSizeAndType(previousURL)
            let new = try pixelSizeAndType(newURL)
            #expect(new.width == previous.width && new.height == previous.height, "\(item.name)")
            #expect(new.type == UTType.jpeg.identifier && previous.type == UTType.jpeg.identifier)
        }
    }

    @Test func hashIndexLookupEqualsFullLibraryScan() throws {
        let repos = Repositories(inMemory: true)
        let batch = repos.createBatch(displayName: "Duplicates", modelId: "cp-cyto3", pxPerUm: 1, thresholds: [20, 30])
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        for index in 0..<60 {
            let image = ImageRecord(fileName: "image-\(index).tif", originalPath: "/source/image-\(index).tif",
                                    widthPx: 10, heightPx: 10)
            image.fileHash = index % 9 == 0 ? nil : "hash-\(index % 23)"
            // Distinct import times in shuffled order, so "newest first" picks between copies.
            image.importedAt = base.addingTimeInterval(Double((index * 37) % 60))
            repos.attach(image: image, to: batch, save: false)
        }
        try repos.context.save()
        // Present and absent hashes.
        let wanted = Set((0..<30).map { "hash-\($0)" })
        // The scan `importAndAnalyze` used before.
        let scanned = Dictionary(repos.allImages().compactMap { image -> (String, ImageRecord)? in
            guard let hash = image.fileHash else { return nil }
            return (hash, image)
        }, uniquingKeysWith: { first, _ in first })
        let expected = scanned.filter { wanted.contains($0.key) }.mapValues(\.id)
        #expect(expected.count == 23)
        for chunkSize in [1, 4, 500] {
            #expect(repos.firstImagesByFileHash(wanted, chunkSize: chunkSize).mapValues(\.id) == expected)
        }
        #expect(repos.firstImagesByFileHash([]).isEmpty)
        #expect(repos.firstImagesByFileHash(["hash-missing"]).isEmpty)
    }

    @Test func jobItemsBuiltOffMainEqualInit() async throws {
        let directory = try temporary(); defer { try? FileManager.default.removeItem(at: directory) }
        let png = directory.appendingPathComponent("plain.png")
        try writeImage(png, type: .png, width: 64, height: 32)
        let stack = directory.appendingPathComponent("stack.tif")
        try writeImage(stack, type: .tiff, width: 40, height: 20, pages: 3)
        let vendor = directory.appendingPathComponent("raw.czi")
        try bytes(4_096).write(to: vendor)
        let missing = directory.appendingPathComponent("missing.tif")
        let stamp = try #require(ImportFileStamp(fileAt: png))
        let sources: [AnalysisJobItem.Source] = [
            .init(url: png, knownHash: "h1", knownHashStamp: stamp),
            .init(url: stack),
            .init(url: vendor, knownHash: "h3"),
            .init(url: missing),
            .init(url: stack, imageId: UUID(), knownHash: "h5", displayName: "Stored stack.tif"),
            .init(url: png, knownHashStamp: stamp),
        ]
        let expected = sources.map {
            AnalysisJobItem(url: $0.url, imageId: $0.imageId, knownHash: $0.knownHash,
                            knownHashStamp: $0.knownHashStamp, displayName: $0.displayName)
        }
        let built = await AnalysisJobItem.make(sources)
        #expect(built.count == expected.count)
        for (item, reference) in zip(built, expected) {
            var normalized = item
            normalized.id = reference.id
            #expect(normalized == reference)
        }
        #expect(Set(built.map(\.id)).count == built.count)
        // The compared values are the meaningful ones.
        #expect(built[0].sourceBookmark != nil && built[4].sourceBookmark == nil)
        #expect(built[1].estimatedBytes == Int64(40 * 20 * 3 * 8))
        #expect(built[2].estimatedBytes == 0 && built[3].estimatedBytes == 0)
        #expect(built[0].status == .pending && built[4].status == .ready)
        #expect(built[0].knownHashStamp == stamp && built[5].knownHashStamp == nil)

        // The stamp survives the job store's JSON; items saved before it existed decode without one.
        let data = try JSONEncoder().encode(built[0])
        #expect(try JSONDecoder().decode(AnalysisJobItem.self, from: data) == built[0])
        var legacy = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        legacy.removeValue(forKey: "knownHashStamp")
        let decoded = try JSONDecoder().decode(AnalysisJobItem.self,
                                               from: try JSONSerialization.data(withJSONObject: legacy))
        #expect(decoded.knownHashStamp == nil && decoded.knownHash == "h1")
    }
}
