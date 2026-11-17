import Foundation
import CoreGraphics
import ImageIO
import SwiftData
import SwiftUI
import Testing
import UniformTypeIdentifiers
@testable import CellCounting

@MainActor
struct ResultsRenderingTests {
    // MARK: — Fixtures

    private func key(image: UUID = UUID(uuidString: "00000000-0000-0000-0000-0000000000A1")!,
                     detection: UUID? = UUID(uuidString: "00000000-0000-0000-0000-0000000000D1")!,
                     revision: Int = 3, confidence: Double = 0.5,
                     regions: [ReviewRegion] = [], pxPerUm: Double = 2) -> ReviewDataKey {
        ReviewDataKey(imageId: image, detectionId: detection, revision: revision,
                      confidence: confidence, regions: regions, pxPerUm: pxPerUm)
    }

    private func square(x: Double, y: Double, side: Double) -> [CGPoint] {
        [CGPoint(x: x, y: y), CGPoint(x: x + side, y: y),
         CGPoint(x: x + side, y: y + side), CGPoint(x: x, y: y + side)]
    }

    /// A contour cell whose diameter (µm) puts it in bin 0 below 10 and bin 1 above.
    private func contourCell(x: Double, y: Double, side: Double, diameter: Double = 5,
                             confidence: Double = 0.9) -> DetectedCell {
        DetectedCell(cx: x + side / 2, cy: y + side / 2, diameter: diameter, diameterPx: side,
                     confidence: confidence, contourPx: square(x: x, y: y, side: side))
    }

    private func elements(_ path: Path) -> [Path.Element] {
        var out: [Path.Element] = []
        path.forEach { out.append($0) }
        return out
    }

    private func commands(_ cells: [DetectedCell], scale: Double = 1,
                          uncertainty: Double = 0.5, outline: Bool = false) -> [OverlayRenderPlan.Command] {
        OverlayRenderPlan.commands(cells: cells, drawOrder: Array(cells.indices),
                                   sourceBounds: cells.map(CellSpatialIndex.sourceBounds),
                                   thresholds: [10], outlineShapes: outline,
                                   uncertaintyThreshold: uncertainty,
                                   viewScale: scale, viewOffset: .zero)
    }

    // MARK: — Overlay resync skip

    @Test func overlaySyncIsSkippedOnlyWhenEveryInputIsUnchanged() {
        let synced = ResultsOverlaySyncState(preparation: key(), liveRevision: 7)
        func skip(_ current: ResultsOverlaySyncState, synced: ResultsOverlaySyncState? = synced,
                  loaded: Bool = true, error: Bool = false) -> Bool {
            ResultsOverlaySyncPolicy.canSkip(current: current, synced: synced,
                                             loadedCellsMatch: loaded, hasLoadError: error)
        }
        // A broadcast about another image: nothing moved for this one.
        #expect(skip(ResultsOverlaySyncState(preparation: key(), liveRevision: 7)))
        // Never synced, a failed load, or a stale cell mirror always reload.
        #expect(!skip(ResultsOverlaySyncState(preparation: key(), liveRevision: 7), synced: nil))
        #expect(!skip(ResultsOverlaySyncState(preparation: key(), liveRevision: 7), error: true))
        #expect(!skip(ResultsOverlaySyncState(preparation: key(), liveRevision: 7), loaded: false))
        // This image's cells were edited, re-detected or recalibrated.
        #expect(!skip(ResultsOverlaySyncState(preparation: key(revision: 4), liveRevision: 7)))
        #expect(!skip(ResultsOverlaySyncState(preparation: key(detection: UUID()), liveRevision: 7)))
        // The filter inputs moved.
        #expect(!skip(ResultsOverlaySyncState(preparation: key(confidence: 0.6), liveRevision: 7)))
        #expect(!skip(ResultsOverlaySyncState(preparation: key(pxPerUm: 3), liveRevision: 7)))
        let roi = ReviewRegion(kind: "include", x: 0, y: 0, width: 10, height: 10)
        #expect(!skip(ResultsOverlaySyncState(preparation: key(regions: [roi]), liveRevision: 7)))
        // A local edit not yet reloaded from the store.
        #expect(!skip(ResultsOverlaySyncState(preparation: key(), liveRevision: 8)))
    }

    @Test func overlayReactsToBroadcastsAndItsOwnImageOnly() {
        let mine = UUID(), other = UUID()
        #expect(ResultsOverlaySyncPolicy.concerns(nil, imageId: mine))
        #expect(ResultsOverlaySyncPolicy.concerns(mine, imageId: mine))
        #expect(!ResultsOverlaySyncPolicy.concerns(other, imageId: mine))
        #expect(!ResultsOverlaySyncPolicy.concerns("not an id", imageId: mine))
    }

    // MARK: — Assay panel notification filter

    @Test func assayResultsSurviveNotificationsAboutOtherImages() {
        let image = UUID(), detection = UUID()
        let result = AssayDetectionStamp(imageId: image, detectionId: detection, cellsRevision: 2)
        let same = AssayDetectionStamp(imageId: image, detectionId: detection, cellsRevision: 2)
        func clears(_ object: Any?, result: AssayDetectionStamp? = result,
                    current: AssayDetectionStamp?) -> Bool {
            AssayResultInvalidation.shouldClear(object: object, result: result, current: current)
        }
        // Another image analysed by a running batch: targeted or broadcast.
        #expect(!clears(UUID(), current: same))
        #expect(!clears(nil, current: same))
        // Targeted at the result's image: always cleared, as before.
        #expect(clears(image, current: same))
        // A broadcast after this image's detection changed.
        #expect(clears(nil, current: AssayDetectionStamp(imageId: image, detectionId: detection,
                                                         cellsRevision: 3)))
        #expect(clears(nil, current: AssayDetectionStamp(imageId: image, detectionId: UUID(),
                                                         cellsRevision: 2)))
        // The result belongs to an image that is not open: kept, and shown
        // again only if still current (below).
        #expect(!clears(nil, current: AssayDetectionStamp(imageId: UUID(), detectionId: nil,
                                                          cellsRevision: 0)))
        #expect(!clears(nil, current: nil))
        // Nothing to clear.
        #expect(!clears(image, result: nil, current: same))

        #expect(AssayResultInvalidation.isCurrent(result: result, current: same))
        #expect(!AssayResultInvalidation.isCurrent(result: result, current: AssayDetectionStamp(
            imageId: image, detectionId: detection, cellsRevision: 9)))
        #expect(!AssayResultInvalidation.isCurrent(result: nil, current: same))
    }

    // MARK: — Batched paths

    @Test func mergedContourPathsEqualTheirPerCellPaths() throws {
        // Far apart, so all share one layer; bins alternate.
        let cells = (0..<6).map { i in
            contourCell(x: Double(i) * 100, y: Double(i % 2) * 100, side: 20 + Double(i),
                        diameter: i.isMultiple(of: 2) ? 5 : 15)
        }
        let plan = commands(cells)
        let cache = OverlayGeometryCache()
        _ = cache.prepare(cells: cells, revision: 1)
        var fills: [Int: Path] = [:], strokes: [Int: Path] = [:]
        for command in plan {
            switch command {
            case .fillContours(let bin, let path): fills[bin] = path
            case .strokeContours(let bin, let path, let dashed):
                #expect(!dashed)
                strokes[bin] = path
            default: Issue.record("unexpected command \(command)")
            }
        }
        #expect(fills.count == 2 && strokes.count == 2)
        for bin in [0, 1] {
            let members = cells.filter { BinMath.binIndex(for: $0.diameter, thresholds: [10]) == bin }
            let perCell = members.map { cache.path(for: $0.id, contour: $0.contourPx!) }
            let merged = try #require(fills[bin])
            #expect(elements(merged) == perCell.flatMap(elements))
            let union = perCell.map(\.boundingRect).reduce(CGRect.null) { $0.union($1) }
            #expect(merged.boundingRect == union)
            #expect(elements(try #require(strokes[bin])) == elements(merged))
        }
    }

    @Test func overlappingCellsKeepTheirDrawingOrder() {
        // 0 and 1 overlap; 2 is far away; 3 overlaps 1.
        let cells = [contourCell(x: 0, y: 0, side: 20), contourCell(x: 10, y: 10, side: 20),
                     contourCell(x: 300, y: 300, side: 20), contourCell(x: 25, y: 25, side: 20)]
        let plan = commands(cells)
        var fillOrder: [[CGRect]] = []
        for case .fillContours(_, let path) in plan {
            var subpaths: [CGRect] = []
            var current = Path()
            path.forEach { element in
                if case .closeSubpath = element {
                    current.closeSubpath(); subpaths.append(current.boundingRect); current = Path()
                } else if case .move(let p) = element { current.move(to: p) }
                else if case .line(let p) = element { current.addLine(to: p) }
            }
            fillOrder.append(subpaths)
        }
        func position(of cell: DetectedCell) -> Int? {
            let bounds = CellSpatialIndex.sourceBounds(cell)
            return fillOrder.firstIndex { $0.contains(bounds) }
        }
        let p = cells.map(position)
        #expect(p.allSatisfy { $0 != nil })
        #expect(p[0]! < p[1]!)
        #expect(p[1]! < p[3]!)
        // The isolated cell joins the first layer.
        #expect(p[2] == p[0])
        // Every cell is filled exactly once.
        #expect(fillOrder.map(\.count).reduce(0, +) == cells.count)
    }

    @Test func dashedOutlinesAreDrawnPerCellAndLeftOutOfTheMergedStroke() throws {
        let solid = contourCell(x: 0, y: 0, side: 20)
        let dashed = contourCell(x: 100, y: 0, side: 20, confidence: 0.1)
        let plan = commands([solid, dashed])
        var fills: [Path] = [], solidStrokes: [Path] = [], dashedStrokes: [Path] = []
        for command in plan {
            switch command {
            case .fillContours(_, let path): fills.append(path)
            case .strokeContours(_, let path, let isDashed):
                if isDashed { dashedStrokes.append(path) } else { solidStrokes.append(path) }
            default: Issue.record("unexpected command \(command)")
            }
        }
        let cache = OverlayGeometryCache()
        let solidPath = cache.path(for: solid.id, contour: solid.contourPx!)
        let dashedPath = cache.path(for: dashed.id, contour: dashed.contourPx!)
        #expect(fills.count == 1)
        #expect(elements(try #require(fills.first)) == elements(solidPath) + elements(dashedPath))
        #expect(solidStrokes.map(elements) == [elements(solidPath)])
        #expect(dashedStrokes.map(elements) == [elements(dashedPath)])
    }

    @Test func nonFiniteContoursAreDrawnAloneInTheirOwnLayer() {
        var broken = contourCell(x: 200, y: 200, side: 20)
        broken.contourPx![1] = CGPoint(x: Double.nan, y: 5)
        let cells = [contourCell(x: 0, y: 0, side: 20), broken, contourCell(x: 400, y: 0, side: 20)]
        let fills = commands(cells).compactMap { command -> Path? in
            if case .fillContours(_, let path) = command { return path }
            return nil
        }
        // Without the broken cell all three would share one path.
        #expect(fills.count == 3)
        let cache = OverlayGeometryCache()
        #expect(elements(fills[0]) == elements(cache.path(for: cells[0].id, contour: cells[0].contourPx!)))
        #expect(elements(fills[2]) == elements(cache.path(for: cells[2].id, contour: cells[2].contourPx!)))
    }

    @Test func layersMatchABruteForceAssignment() {
        var seed: UInt64 = 0x9E37_79B9_7F4A_7C15
        func random(_ range: ClosedRange<Double>) -> Double {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return range.lowerBound + Double(seed >> 11) / Double(1 << 53) * (range.upperBound - range.lowerBound)
        }
        for round in 0..<20 {
            let count = 50 + round * 20
            var rects = (0..<count).map { _ in
                CGRect(x: random(0...800), y: random(0...600),
                       width: random(0.5...60), height: random(0.5...60))
            }
            if round.isMultiple(of: 5) { rects[count / 2] = .infinite }
            let layers = OverlayRenderPlan.layers(for: rects)
            var expected = [Int](repeating: 0, count: count)
            var floor = 0, top = -1
            for j in 0..<count {
                guard OverlayRenderPlan.isUsable(rects[j]) else {
                    top += 1; expected[j] = top; floor = top + 1; continue
                }
                var layer = floor
                for i in 0..<j where OverlayRenderPlan.isUsable(rects[i])
                    && OverlayRenderPlan.overlaps(rects[i], rects[j]) {
                    layer = max(layer, expected[i] + 1)
                }
                expected[j] = layer
                top = max(top, layer)
            }
            #expect(layers == expected)
            // Items of one layer never touch.
            for i in 0..<count { for j in (i + 1)..<count where layers[i] == layers[j] {
                #expect(!OverlayRenderPlan.overlaps(rects[i], rects[j]))
            } }
        }
    }

    // MARK: — Tiny cells

    @Test func cellsUnderTwoPointsOnScreenBecomeDots() throws {
        #expect(OverlayRenderPlan.isTiny(CGSize(width: 1.9, height: 1.9)))
        #expect(OverlayRenderPlan.isTiny(CGSize(width: 0, height: 0)))
        #expect(OverlayRenderPlan.isTiny(CGSize(width: -1.5, height: 1)))
        #expect(!OverlayRenderPlan.isTiny(CGSize(width: 2, height: 0.5)))
        #expect(!OverlayRenderPlan.isTiny(CGSize(width: Double.nan, height: 1)))
        #expect(!OverlayRenderPlan.isTiny(CGSize(width: 1, height: Double.nan)))
        #expect(!OverlayRenderPlan.isTiny(CGSize(width: Double.infinity, height: 1)))

        // A 20 px contour cell: full drawing at 1×, a dot at 0.05× (1 pt).
        let cell = contourCell(x: 100, y: 100, side: 20)
        #expect(commands([cell], scale: 1).contains {
            if case .fillContours = $0 { return true }; return false
        })
        let dots = commands([cell], scale: 0.05)
        #expect(dots.count == 1)
        guard case .fillDots(let bin, let uncertain, let path) = try #require(dots.first) else {
            Issue.record("expected a dot"); return
        }
        #expect(bin == 0 && !uncertain)
        // The dot covers the outer edge of the 1 pt stroke.
        let bounds = path.boundingRect
        #expect(abs(bounds.minX - (100 * 0.05 - 0.5)) < 1e-9)
        #expect(abs(bounds.width - (20 * 0.05 + 1)) < 1e-9)

        // Cells without a contour: 1.5 pt box stroke.
        let box = DetectedCell(cx: 50, cy: 50, diameter: 5, diameterPx: 10, confidence: 0.1)
        let boxDots = commands([box], scale: 0.15)
        guard case .fillDots(_, let boxUncertain, let boxPath) = try #require(boxDots.first) else {
            Issue.record("expected a dot"); return
        }
        #expect(boxUncertain)
        #expect(abs(boxPath.boundingRect.width - (10 * 0.15 + 1.5)) < 1e-9)
        #expect(commands([box], scale: 1).contains {
            if case .strokeBox(_, _, let dashed) = $0 { return dashed }; return false
        })
        // Manual pins keep their fixed size whatever the zoom.
        let pin = DetectedCell(cx: 5, cy: 5, diameter: 1, diameterPx: 1, isManual: true)
        #expect(commands([pin], scale: 0.01).count == 1)
        if case .pin(let index) = commands([pin], scale: 0.01)[0] { #expect(index == 0) }
        else { Issue.record("expected a pin") }
    }

    // MARK: — Memoization

    @Test func memoRecomputesOnlyWhenItsKeyChanges() {
        let memo = KeyedMemo<ResultsCellsIdentity, Int>()
        let cells = [contourCell(x: 0, y: 0, side: 5), contourCell(x: 10, y: 0, side: 5)]
        let identity = try! #require(ResultsCellsIdentity(revision: key(), cells: cells))
        var calls = 0
        func read(_ id: ResultsCellsIdentity) -> Int { memo.value(for: id) { calls += 1; return calls } }
        #expect(read(identity) == 1)
        #expect(read(identity) == 1)
        // New revision (an edit), new cutoff, or a different array.
        #expect(read(try! #require(ResultsCellsIdentity(revision: key(revision: 4), cells: cells))) == 2)
        #expect(read(try! #require(ResultsCellsIdentity(revision: key(revision: 4, confidence: 0.7),
                                                         cells: cells))) == 3)
        #expect(read(try! #require(ResultsCellsIdentity(revision: key(revision: 4, confidence: 0.7),
                                                         cells: Array(cells.prefix(1))))) == 4)
        #expect(memo.computeCount == 4)
        // Without a key there is nothing to vouch for the array: no memo.
        #expect(ResultsCellsIdentity(revision: nil, cells: cells) == nil)
    }

    @Test func decodedImageStatsFollowTheStoredBytes() throws {
        let repos = Repositories(inMemory: true)
        let detection = DetectionRecord(detectorId: "test", cells: [], imageStats: ["focus_score": 0.5])
        repos.context.insert(detection)
        let derived = ResultsDerivedValues()
        #expect(derived.imageStats(of: detection) == ["focus_score": 0.5])
        #expect(derived.imageStats(of: detection) == detection.imageStats)
        detection.imageStatsData = try JSONEncoder().encode(["focus_score": 0.9])
        #expect(derived.imageStats(of: detection) == ["focus_score": 0.9])
        detection.imageStatsData = nil
        #expect(derived.imageStats(of: detection).isEmpty)
        #expect(derived.imageStats(of: nil).isEmpty)
    }

    // MARK: — Histogram and line profile

    private func writeGradientPNG(width: Int, height: Int) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cc-results-pixels-\(UUID()).png")
        let context = try #require(CGContext(data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        for x in 0..<width {
            let level = CGFloat(x) / CGFloat(max(1, width - 1))
            context.setFillColor(CGColor(red: level, green: level * 0.5, blue: 1 - level, alpha: 1))
            context.fill(CGRect(x: x, y: 0, width: 1, height: height))
        }
        let image = try #require(context.makeImage())
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL,
            UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return url
    }

    /// The pre-change histogram: decode via `ImageLoader`, draw at ≤ 512 px grey.
    private func referenceHistogram(_ url: URL) throws -> IntensityHistogramData {
        let src = try ImageLoader.load(url).cgImage
        let scale = min(1.0, 512.0 / Double(max(src.width, src.height)))
        let w = max(1, Int(Double(src.width) * scale)), h = max(1, Int(Double(src.height) * scale))
        var pixels = [UInt8](repeating: 0, count: w * h)
        pixels.withUnsafeMutableBytes { buffer in
            let ctx = CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(),
                                bitmapInfo: CGImageAlphaInfo.none.rawValue)!
            ctx.draw(src, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        var buckets = Array(repeating: 0, count: 256)
        var sum = 0.0, minV = 255, maxV = 0
        for v in pixels {
            buckets[Int(v)] += 1; sum += Double(v)
            minV = min(minV, Int(v)); maxV = max(maxV, Int(v))
        }
        let n = Double(pixels.count), mean = sum / n
        let variance = pixels.reduce(0.0) { $0 + (Double($1) - mean) * (Double($1) - mean) }
        return IntensityHistogramData(buckets: buckets, minVal: minV, maxVal: maxV,
                                      mean: mean, sigma: sqrt(variance / n))
    }

    @Test func histogramAndProfileMatchTheFullResolutionComputation() async throws {
        let url = try writeGradientPNG(width: 700, height: 40)
        defer { try? FileManager.default.removeItem(at: url) }
        let sampler = ResultsPixelSampler()
        let histogram = try #require(await sampler.histogram(at: url))
        #expect(histogram == (try referenceHistogram(url)))
        // Kept per file: the second request returns the same value.
        #expect(await sampler.histogram(at: url) == histogram)

        // Reference: the full-resolution grey plane rebuilt for each line.
        let src = try ImageLoader.load(url).cgImage
        var grey = [UInt8](repeating: 0, count: src.width * src.height)
        grey.withUnsafeMutableBytes { buffer in
            let ctx = CGContext(data: buffer.baseAddress, width: src.width, height: src.height,
                                bitsPerComponent: 8, bytesPerRow: src.width,
                                space: CGColorSpaceCreateDeviceGray(),
                                bitmapInfo: CGImageAlphaInfo.none.rawValue)!
            ctx.draw(src, in: CGRect(x: 0, y: 0, width: src.width, height: src.height))
        }
        func reference(from a: CGPoint, to b: CGPoint, count: Int) -> [LineProfileSample] {
            (0..<count).map { i in
                let x = Double(a.x) + Double(b.x - a.x) / Double(count - 1) * Double(i)
                let y = Double(a.y) + Double(b.y - a.y) / Double(count - 1) * Double(i)
                let x0 = max(0, min(src.width - 1, Int(x))), y0 = max(0, min(src.height - 1, Int(y)))
                let x1 = min(src.width - 1, x0 + 1), y1 = min(src.height - 1, y0 + 1)
                let fx = x - Double(x0), fy = y - Double(y0)
                func p(_ px: Int, _ py: Int) -> Double { Double(grey[py * src.width + px]) }
                let value = p(x0, y0) * (1 - fx) * (1 - fy) + p(x1, y0) * fx * (1 - fy)
                    + p(x0, y1) * (1 - fx) * fy + p(x1, y1) * fx * fy
                return LineProfileSample(position: i, intensity: value)
            }
        }
        let lines = [(CGPoint(x: 3.5, y: 2.25), CGPoint(x: 690.75, y: 37)),
                     (CGPoint(x: 600, y: 39), CGPoint(x: -20, y: 0))]
        for (a, b) in lines {
            // The second line reuses the kept grey plane.
            let profile = try #require(await sampler.profile(at: url, from: a, to: b, count: 256))
            #expect(profile == reference(from: a, to: b, count: 256))
        }
        await sampler.releasePlane(for: url)
        let again = try #require(await sampler.profile(at: url, from: lines[0].0, to: lines[0].1, count: 256))
        #expect(again == reference(from: lines[0].0, to: lines[0].1, count: 256))
    }
}
