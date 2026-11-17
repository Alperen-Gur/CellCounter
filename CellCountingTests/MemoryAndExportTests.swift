import CoreGraphics
import Foundation
import ImageIO
import SwiftData
import Testing
import UniformTypeIdentifiers
@testable import CellCounting

// MARK: - Memory pressure

private final class FakePressureSource: MemoryPressureSource, @unchecked Sendable {
    var handler: (@Sendable (MemoryPressureLevel) -> Void)?
    var startCount = 0
    var stopCount = 0
    func start(handler: @escaping @Sendable (MemoryPressureLevel) -> Void) {
        startCount += 1
        self.handler = handler
    }
    func stop() { stopCount += 1 }
}

@Suite(.serialized) @MainActor
struct MemoryPressureTests {
    @Test func debounceIgnoresRepeatsButNotEscalation() {
        let source = FakePressureSource()
        var clock = Date(timeIntervalSince1970: 1_000)
        var purged: [MemoryPressureLevel] = []
        let center = NotificationCenter()
        var posted: [String] = []
        let token = center.addObserver(forName: .ccMemoryPressure, object: nil, queue: nil) { note in
            posted.append(MemoryPressureLevel(notification: note).rawValue)
        }
        defer { center.removeObserver(token) }
        let monitor = MemoryPressureMonitor(source: source, debounce: 10, now: { clock },
                                            center: center, purge: { purged.append($0) })
        monitor.start()
        monitor.start()
        #expect(source.startCount == 1)

        monitor.handle(.warning)                       // handled
        clock += 3; monitor.handle(.warning)           // repeat inside the window
        clock += 1; monitor.handle(.critical)          // escalation passes
        clock += 1; monitor.handle(.critical)          // repeat
        clock += 1; monitor.handle(.warning)           // lower level inside the window
        #expect(purged == [.warning, .critical])
        #expect(posted == ["warning", "critical"])
        #expect(monitor.suppressedCount == 3)

        clock += 30; monitor.handle(.warning)          // window passed
        #expect(purged == [.warning, .critical, .warning])
        #expect(monitor.handledCount == 3)

        monitor.stop()
        #expect(source.stopCount == 1)
    }

    @Test func eventsFromTheSourceReachTheHandler() async {
        let source = FakePressureSource()
        var purged: [MemoryPressureLevel] = []
        let monitor = MemoryPressureMonitor(source: source, debounce: 0, center: NotificationCenter(),
                                            purge: { purged.append($0) })
        monitor.start()
        source.handler?(.critical)
        for _ in 0..<20 where purged.isEmpty { await Task.yield() }
        #expect(purged == [.critical])
        monitor.stop()
    }

    @Test func decodedCellCacheRemoveAllEmptiesIt() {
        let cache = DecodedCellCache(countLimit: 4, byteLimit: 1_000_000)
        let cell = DetectedCell(cx: 1, cy: 1, diameter: 5, diameterPx: 10, confidence: 0.9)
        for _ in 0..<3 { cache.insert([cell], for: UUID(), revision: 0) }
        #expect(cache.retainedCount == 3)
        cache.removeAll()
        #expect(cache.retainedCount == 0)
        #expect(cache.retainedBytes == 0)
    }

    @Test func assayWorkerPurgeWithNothingRunningIsANoOp() async {
        let service = AssayWorkerService(idleSeconds: 60)
        await service.purgeForMemoryPressure()
        #expect(await service.hasActiveRequest == false)
    }
}

// MARK: - Exports

@Suite(.serialized) @MainActor
struct StreamingExportTests {
    private func tempRoot() -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cc-memx-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func writeSolidPNG(to url: URL, width: Int, height: Int) throws {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                bytesPerRow: 0, space: space,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(gray: 0.3, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        #expect(CGImageDestinationFinalize(destination))
    }

    private func cells(_ count: Int, seed: Double) -> [DetectedCell] {
        (0..<count).map { index in
            let x = 30 + seed + Double(index) * 25
            let contour = (0..<12).map { point in
                CGPoint(x: x + 8 * cos(Double(point) / 1.9), y: 40 + 8 * sin(Double(point) / 1.9))
            }
            return DetectedCell(cx: x, cy: 40, diameter: 6 + Double(index), diameterPx: 16,
                                confidence: 0.5 + Double(index % 4) * 0.12, contourPx: contour)
        }
    }

    @Test func perImageExportMatchesTheDirectCompositeBytesAndLoadsLazily() throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.png")
        try writeSolidPNG(to: source, width: 320, height: 200)
        let inputs = (0..<3).map { index in
            ExportService.BatchAnnotatedImageInput(fileName: "field\(index % 2).tif", imageURL: source,
                                                   cells: cells(4 + index, seed: Double(index)),
                                                   confidence: 0.55)
        }
        let output = root.appendingPathComponent("out", isDirectory: true)
        let batchFolder = output.appendingPathComponent("Plate", isDirectory: true)
        var filesWhenLoaded: [Int] = []
        let result = try ExportService.writeBatchAnnotatedPNGs(
            batchName: "Plate", imageCount: inputs.count, thresholds: [10, 20], pxPerUm: 2,
            overlayMode: .outline, parentDirectory: output,
            loadImage: { index in
                filesWhenLoaded.append(
                    (try? FileManager.default.contentsOfDirectory(atPath: batchFolder.path).count) ?? 0)
                return inputs[index]
            })
        // Image n is requested only after images 0..<n have been written.
        #expect(filesWhenLoaded == [0, 1, 2])
        #expect(result.errors.isEmpty)
        #expect(result.written == ["field0-annotated.png", "field1-annotated.png", "field0-annotated_2.png"])

        for (input, name) in zip(inputs, result.written) {
            let expected = root.appendingPathComponent("expected-\(name)")
            try ExportService.compositeAnnotatedPNG(imageURL: input.imageURL, cells: input.cells,
                                                    thresholds: [10, 20], pxPerUm: 2,
                                                    overlayMode: .outline, confidence: input.confidence,
                                                    to: expected)
            #expect(try Data(contentsOf: result.folder.appendingPathComponent(name))
                    == Data(contentsOf: expected))
        }

        // The array form is the same call with an array-backed loader.
        let again = try ExportService.writeBatchAnnotatedPNGs(
            batchName: "Plate again", images: inputs, thresholds: [10, 20], pxPerUm: 2,
            overlayMode: .outline, parentDirectory: output)
        #expect(again.written == result.written)
        for name in result.written {
            #expect(try Data(contentsOf: again.folder.appendingPathComponent(name))
                    == Data(contentsOf: result.folder.appendingPathComponent(name)))
        }
    }

    @Test func summaryCSVOffMainIsByteIdenticalToTheDecodingPath() async throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let repos = Repositories(inMemory: true)
        let context = repos.context
        let batch = BatchRecord(name: "b", displayName: "b", modelId: "fixture", pxPerUm: 2,
                                thresholds: [10, 20])
        context.insert(batch)
        let names = ["a.tif", "b.tif", "a.tif", "c.tif"]
        for (index, name) in names.enumerated() {
            let image = ImageRecord(fileName: name, originalPath: "", widthPx: 320, heightPx: 200)
            image.importedAt = Date(timeIntervalSince1970: 1_700_000_000 + Double(index) * 60)
            context.insert(image)
            image.batch = batch
            if index != 3 {                              // the last image is never analysed
                let detection = DetectionRecord(detectorId: "fixture", cells: cells(5 + index, seed: Double(index)),
                                                imageStats: ["confluency_pct": 12.5, "n_colonies": Double(index)])
                context.insert(detection)
                detection.image = image
                image.detection = detection
            }
            if index == 1 { image.confidenceOverride = 0.7 }
        }
        try context.save()

        let old = root.appendingPathComponent("old.csv")
        let new = root.appendingPathComponent("new.csv")
        try ExportService.writePerImageSummaryCSV(batch: batch, thresholds: [10, 20], pxPerUm: 2,
                                                  confidence: 0.6, separator: ";", to: old)
        try await ExportService.writePerImageSummaryCSVOffMain(batch: batch, thresholds: [10, 20], pxPerUm: 2,
                                                               confidence: 0.6, separator: ";", to: new)
        let oldBytes = try Data(contentsOf: old)
        #expect(oldBytes == (try Data(contentsOf: new)))
        let text = String(decoding: oldBytes, as: UTF8.self)
        #expect(text.split(separator: "\n").count == 2 + names.count)
        #expect(text.contains("a_2.tif"))
    }
}

// MARK: - PDF image size

struct PDFEmbeddedImageSizeTests {
    @Test func largeSourcesAreReducedToThePrintSizeOfTheirBox() throws {
        // 12000 x 8000 fits the 590-unit width: 590 x 393.3 units, times 300/144.
        let size = try #require(PDFReportGenerator.embeddedImagePixelSize(sourceWidth: 12_000, sourceHeight: 8_000))
        #expect(size.width == 1_230)    // ceil(590 * 300 / 144)
        #expect(size.height == 820)     // ceil(393.33 * 300 / 144)
        // Aspect ratio is kept to within a pixel.
        #expect(abs(Double(size.width) / Double(size.height) - 1.5) < 0.01)
    }

    @Test func tallSourcesAreLimitedByTheBoxHeight() throws {
        let size = try #require(PDFReportGenerator.embeddedImagePixelSize(sourceWidth: 3_000, sourceHeight: 9_000))
        #expect(size.height == 2_459)   // ceil(1180 * 300 / 144)
        #expect(size.width <= 820)
    }

    @Test func smallSourcesAreLeftAlone() {
        #expect(PDFReportGenerator.embeddedImagePixelSize(sourceWidth: 800, sourceHeight: 600) == nil)
        #expect(PDFReportGenerator.embeddedImagePixelSize(sourceWidth: 0, sourceHeight: 600) == nil)
    }
}

// MARK: - Embedding cache janitor

struct EmbeddingCacheJanitorTests {
    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cc-embed-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    /// A cache folder with one file of `bytes`, last used `age` seconds ago.
    @discardableResult
    private func makeEntry(_ name: String, in root: URL, bytes: Int, age: TimeInterval) throws -> URL {
        let dir = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("0.0")
        try Data(repeating: 7, count: bytes).write(to: file)
        let date = Date().addingTimeInterval(-age)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: file.path)
        var times = [timeval(tv_sec: Int(date.timeIntervalSince1970), tv_usec: 0),
                     timeval(tv_sec: Int(date.timeIntervalSince1970), tv_usec: 0)]
        utimes(file.path, &times)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: dir.path)
        return dir
    }

    @Test func removesOnlyOrphansAndKeepsUnmappableEntries() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let live = UUID(), gone = UUID()
        let keep = try makeEntry("\(live.uuidString)-vit_b.zarr", in: root, bytes: 100, age: 10)
        let keepOther = try makeEntry("\(live.uuidString)-vit_h.zarr", in: root, bytes: 100, age: 10)
        let orphan = try makeEntry("\(gone.uuidString)-vit_b.zarr", in: root, bytes: 100, age: 10)
        let foreign = try makeEntry("notes.zarr", in: root, bytes: 100, age: 10)
        let shortName = try makeEntry("\(live.uuidString).zarr", in: root, bytes: 100, age: 10)

        let report = EmbeddingCacheJanitor.clean(directory: root, liveImageIDs: [live], byteCap: .max)
        #expect(report.orphansRemoved == 1)
        #expect(report.capRemoved == 0)
        #expect(report.bytesFreed == 100)
        let fm = FileManager.default
        #expect(fm.fileExists(atPath: keep.path))
        #expect(fm.fileExists(atPath: keepOther.path))
        #expect(!fm.fileExists(atPath: orphan.path))
        #expect(fm.fileExists(atPath: foreign.path))
        #expect(fm.fileExists(atPath: shortName.path))
    }

    @Test func enforcesTheCapOldestFirst() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let a = UUID(), b = UUID(), c = UUID()
        let oldest = try makeEntry("\(a.uuidString)-m.zarr", in: root, bytes: 1_000, age: 3_000)
        let middle = try makeEntry("\(b.uuidString)-m.zarr", in: root, bytes: 1_000, age: 2_000)
        let newest = try makeEntry("\(c.uuidString)-m.zarr", in: root, bytes: 1_000, age: 1_000)

        let report = EmbeddingCacheJanitor.clean(directory: root, liveImageIDs: [a, b, c], byteCap: 2_500)
        #expect(report.orphansRemoved == 0)
        #expect(report.capRemoved == 1)
        #expect(report.bytesKept == 2_000)
        let fm = FileManager.default
        #expect(!fm.fileExists(atPath: oldest.path))
        #expect(fm.fileExists(atPath: middle.path))
        #expect(fm.fileExists(atPath: newest.path))

        let second = EmbeddingCacheJanitor.clean(directory: root, liveImageIDs: [a, b, c], byteCap: 500)
        #expect(second.capRemoved == 2)
        #expect(second.bytesKept == 0)
    }

    @Test func parsesTheImageIDFromCacheNames() {
        let id = UUID()
        #expect(EmbeddingCacheJanitor.imageID(fromFileName: "\(id.uuidString)-vit_b.zarr") == id)
        #expect(EmbeddingCacheJanitor.imageID(fromFileName: "\(id.uuidString).zarr") == nil)
        #expect(EmbeddingCacheJanitor.imageID(fromFileName: "readme.txt") == nil)
    }

    @Test func aMissingFolderIsNotAnError() {
        let report = EmbeddingCacheJanitor.clean(directory: URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)"),
                                                 liveImageIDs: [], byteCap: 0)
        #expect(report == EmbeddingCacheJanitor.Report())
    }
}
