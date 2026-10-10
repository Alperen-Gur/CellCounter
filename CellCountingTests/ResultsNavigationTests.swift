import AppKit
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import CellCounting

struct ResultsNavigationTests {
    @Test func viewerResolutionTracksCanvasDensityInStableBoundedBuckets() {
        let source = CGSize(width: 20_000, height: 10_000)
        #expect(ViewerImageResolution.pixelSize(source: source,
            display: CGSize(width: 780, height: 390), displayScale: 2) == 2_048)
        #expect(ViewerImageResolution.pixelSize(source: source,
            display: CGSize(width: 790, height: 395), displayScale: 2) == 2_048)
        #expect(ViewerImageResolution.pixelSize(source: source,
            display: CGSize(width: 1_560, height: 780), displayScale: 2) == 4_096)
        #expect(ViewerImageResolution.pixelSize(source: source,
            display: CGSize(width: 50_000, height: 25_000), displayScale: 2) == ViewerImageResolution.maximumPixelSize)
        #expect(ViewerImageResolution.pixelSize(source: CGSize(width: 500, height: 250),
            display: CGSize(width: 780, height: 390), displayScale: 2) == 500)
    }

    @Test @MainActor func viewerBitmapPreservesRawOrientationAndOriginalLoading() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("cc-viewer-\(UUID()).tiff")
        defer { try? FileManager.default.removeItem(at: url) }
        let context = try #require(CGContext(data: nil, width: 120, height: 60,
            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(NSColor.red.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: 120, height: 60))
        let original = try #require(context.makeImage())
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL,
            UTType.tiff.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, original, [kCGImagePropertyOrientation: 6] as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))

        let small = try #require(ImageLoader.cachedViewerImage(at: url, maxPixelSize: 32))
        let larger = try #require(ImageLoader.cachedViewerImage(at: url, maxPixelSize: 64))
        #expect(small.size == CGSize(width: 32, height: 16))
        #expect(larger.size == CGSize(width: 64, height: 32))
        // Requested resolution participates in cache identity.
        #expect(small !== larger)
        let repeated = try #require(ImageLoader.cachedViewerImage(at: url, maxPixelSize: 32))
        #expect(small === repeated)
        let loaded = try ImageLoader.load(url)
        #expect(loaded.widthPx == 120 && loaded.heightPx == 60)
    }

    @Test @MainActor func preparedFilterAndGeometryAvoidFirstCanvasRebuilding() {
        let cells = [
            DetectedCell(cx: 10, cy: 10, diameter: 5, diameterPx: 5, confidence: 0.9),
            DetectedCell(cx: 50, cy: 50, diameter: 5, diameterPx: 5, confidence: 0.3),
        ]
        let key = ReviewDataKey(imageId: UUID(), detectionId: UUID(), revision: 1,
                                confidence: 0.65, regions: [], pxPerUm: 1)
        let summary = ReviewSummary.make(cells: cells, confidence: key.confidence, regions: [])
        let summaryCache = ReviewSummaryCache()
        summaryCache.store(summary, for: key)
        let count = summaryCache.rebuildCount
        // A seed is read without re-filtering the supplied source snapshot.
        #expect(summaryCache.value(for: key, cells: []).cells.map(\.id) == [cells[0].id])
        #expect(summaryCache.rebuildCount == count)

        let prepared = CellSpatialIndex(cells: summary.cells)
        let geometryCache = OverlayGeometryCache()
        let first = geometryCache.prepare(cells: summary.cells, revision: 1, preparedIndex: prepared)
        #expect(first.query(CGRect(x: 9, y: 9, width: 2, height: 2)).indices == [0])
        #expect(geometryCache.indexBuildCount == 0)
        var edited = summary.cells
        edited[0].cx = 100
        let updated = geometryCache.prepare(cells: edited, revision: 2)
        #expect(geometryCache.indexBuildCount == 1)
        #expect(updated.query(CGRect(x: 99, y: 9, width: 2, height: 2)).indices == [0])
    }
}
