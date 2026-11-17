import CoreGraphics
import Foundation
import SwiftData
import Testing
@testable import CellCounting

/// Compact per-cell metrics (`DetectionRecord.cellMetricsData`): the codec,
/// that every cell write keeps them in sync, that list and compare figures
/// computed from them equal the same figures computed from fully decoded
/// cells (as the screens did before), the background reader, and the
/// backfill. Every test uses an in-memory store.
@Suite(.serialized) @MainActor
struct CellMetricsTests {
    // MARK: - Fixtures

    /// Deterministic cells with diameters on and around the [20, 30] µm
    /// thresholds, confidences on and around common cut-offs, centroids on
    /// ROI edges, and outlines (which the metrics leave out).
    private func cells(_ count: Int, seed: Int = 1, pxPerUm: Double = 2) -> [DetectedCell] {
        var state = UInt64(truncatingIfNeeded: seed) &* 6364136223846793005 &+ 1442695040888963407
        func next() -> Double {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Double(state >> 11) / Double(1 << 53)
        }
        let edgeDiameters: [Double] = [20, 30, 19.999999999999996, 30.000000000000004, 8, 60, 0.1, 85]
        let edgeConfidences: [Double] = [0.5, 0.65, 0.4999999999999999, 1, 0]
        return (0..<count).map { index in
            let diameter = index % 5 == 0 ? edgeDiameters[index % edgeDiameters.count] : 5 + next() * 50
            let confidence = index % 7 == 0 ? edgeConfidences[index % edgeConfidences.count] : next()
            let cx = index % 11 == 0 ? 100 : next() * 400
            let cy = index % 13 == 0 ? 50 : next() * 300
            let contour = (0..<12).map { point in
                CGPoint(x: cx + 4 * cos(Double(point) / 2), y: cy + 4 * sin(Double(point) / 2))
            }
            return DetectedCell(cx: cx, cy: cy, diameter: diameter, diameterPx: diameter * pxPerUm,
                                confidence: confidence, areaMicrons2: diameter * diameter * 0.78,
                                perimeterMicrons: diameter * 3.14, centroidUmX: cx / pxPerUm,
                                centroidUmY: cy / pxPerUm, edgeTouching: index % 3 == 0,
                                contourPx: contour)
        }
    }

    private func library(thresholds: [Double] = [20, 30], condition: String? = nil)
        -> (Repositories, BatchRecord) {
        let repos = Repositories(inMemory: true)
        let batch = repos.createBatch(displayName: "Metrics", modelId: "cp-cyto3", pxPerUm: 2,
                                      thresholds: thresholds, condition: condition)
        return (repos, batch)
    }

    @discardableResult
    private func addImage(_ repos: Repositories, _ batch: BatchRecord, name: String,
                          cells: [DetectedCell]?, path: String? = nil) -> ImageRecord {
        let image = ImageRecord(fileName: name, originalPath: path ?? "/plate/\(name)", widthPx: 400, heightPx: 300)
        repos.context.insert(image)
        repos.attach(image: image, to: batch)
        if let cells { repos.saveDetection(cells, detectorId: "test", for: image) }
        return image
    }

    private func storedMetrics(_ detection: DetectionRecord) throws -> CellMetrics {
        #expect(detection.cellMetricsVersion == CellMetricsCodec.version)
        let data = try #require(detection.cellMetricsData)
        return try #require(CellMetricsCodec.decode(data))
    }

    /// The stored metrics are exactly the stored cells' values.
    private func expectInSync(_ detection: DetectionRecord) throws {
        let decoded = DetectionRecord.decodeCellsData(detection.cellsData)
        let metrics = try storedMetrics(detection)
        #expect(metrics == CellMetrics(cells: decoded))
        #expect(metrics.count == detection.cellCountSummary)
    }

    private func bits(_ values: [Double]) -> [UInt64] { values.map(\.bitPattern) }

    // MARK: - Reference arithmetic (as the screens computed it from cells)

    /// `BatchView.buildRealRows` before metrics, for one analysed image.
    private func referenceBatchRow(_ cells: [DetectedCell], thresholds: [Double])
        -> (count: Int, mean: Double?, counts: [Double]?, norm: [Double]?) {
        let meanDiam: Double? = cells.isEmpty ? nil
            : cells.reduce(0) { $0 + $1.diameter } / Double(cells.count)
        let distCounts: [Double]? = {
            guard !cells.isEmpty else { return nil }
            var bins = Array(repeating: 0.0, count: max(thresholds.count + 1, 5))
            for c in cells {
                let idx = min(BinMath.binIndex(for: c.diameter, thresholds: thresholds), bins.count - 1)
                bins[idx] += 1
            }
            while bins.count < 5 { bins.append(0) }
            return Array(bins.prefix(5))
        }()
        let distNorm: [Double]? = distCounts.map { bins in
            let m = bins.max() ?? 1
            return bins.map { m > 0 ? $0 / m * 100 : 0 }
        }
        return (cells.count, meanDiam, distCounts, distNorm)
    }

    /// `ImagesLibraryView.ImageThumbCell.distribution` before metrics.
    private func referenceLibraryBars(_ cellsData: Data?, thresholds: [Double]) -> [Double]? {
        guard let cellsData else { return nil }
        let cells = DetectionRecord.decodeCellsData(cellsData)
        guard !cells.isEmpty else { return nil }
        var bins = Array(repeating: 0.0, count: max(thresholds.count + 1, 5))
        for c in cells {
            let idx = min(BinMath.binIndex(for: c.diameter, thresholds: thresholds), bins.count - 1)
            bins[idx] += 1
        }
        while bins.count < 5 { bins.append(0) }
        let m = bins.prefix(5).max() ?? 1
        return Array(bins.prefix(5)).map { m > 0 ? $0 / m * 100 : 0 }
    }

    /// Compare's pooled values before metrics, for one detection.
    private func referencePooled(_ cellsData: Data, cutoff: Double) -> [Double] {
        var diameters: [Double] = []
        for cell in DetectionRecord.decodeCellsData(cellsData) where cell.confidence >= cutoff {
            diameters.append(cell.diameter)
        }
        return diameters
    }

    /// Compare's pooled statistics before metrics (`computeComparisonOutputs`).
    private func referencePoolStats(_ diameters: [Double], thresholds: [Double])
        -> (mean: Double, sigma: Double, bins: [Int], buckets: [Int]) {
        let sortedThresholds = thresholds.sorted()
        let n = diameters.count
        let mean = n == 0 ? 0 : diameters.reduce(0, +) / Double(n)
        let sigma = n == 0 ? 0 : sqrt(diameters.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(n))
        var binCounts = Array(repeating: 0, count: sortedThresholds.count + 1)
        var buckets = Array(repeating: 0, count: 24)
        for diameter in diameters {
            let bin = sortedThresholds.firstIndex(where: { diameter < $0 }) ?? sortedThresholds.count
            binCounts[bin] += 1
            let raw = (diameter - 8) / (60 - 8) * 24
            buckets[min(23, max(0, Int(raw)))] += 1
        }
        return (mean, sigma, binCounts, buckets)
    }

    private func expectSameFigures(_ metrics: CellMetrics, _ cells: [DetectedCell], thresholds: [Double]) {
        let summary = CellMetricsStats.imageSummary(metrics, thresholds: thresholds)
        let reference = referenceBatchRow(cells, thresholds: thresholds)
        #expect(summary.count == reference.count)
        #expect(summary.meanDiameter?.bitPattern == reference.mean?.bitPattern)
        #expect(summary.binCounts == reference.counts)
        #expect(summary.bars == reference.norm)
    }

    // MARK: - Codec

    @Test func codecRoundTripsEveryValueBitForBit() throws {
        var fixture = cells(97)
        fixture[1].diameter = -0.0
        fixture[2].confidence = .leastNonzeroMagnitude
        fixture[3].cx = 1e300
        fixture[4].cy = -123.456
        let data = CellMetricsCodec.encode(fixture)
        #expect(data.count == CellMetricsCodec.headerSize + fixture.count * CellMetricsCodec.bytesPerCell)
        #expect(data.prefix(4) == Data("CCM1".utf8))
        let decoded = try #require(CellMetricsCodec.decode(data))
        #expect(decoded.count == fixture.count)
        #expect(bits(decoded.diameterUm) == bits(fixture.map(\.diameter)))
        #expect(bits(decoded.diameterPx) == bits(fixture.map(\.diameterPx)))
        #expect(bits(decoded.confidence) == bits(fixture.map(\.confidence)))
        #expect(bits(decoded.cx) == bits(fixture.map(\.cx)))
        #expect(bits(decoded.cy) == bits(fixture.map(\.cy)))
        #expect(CellMetricsCodec.encode(decoded) == data)
        // A slice that does not start at index 0 decodes the same.
        var padded = Data([9, 9, 9])
        padded.append(data)
        #expect(CellMetricsCodec.decode(padded.dropFirst(3)) == decoded)
    }

    @Test func codecHandlesEmptyAndRejectsMalformedData() {
        let empty = CellMetricsCodec.encode([DetectedCell]())
        #expect(empty.count == CellMetricsCodec.headerSize)
        #expect(CellMetricsCodec.decode(empty) == CellMetrics.empty)
        let data = CellMetricsCodec.encode(cells(5))
        #expect(CellMetricsCodec.decode(Data()) == nil)
        #expect(CellMetricsCodec.decode(data.dropLast()) == nil)
        #expect(CellMetricsCodec.decode(data + Data([0])) == nil)
        var wrongMarker = data
        wrongMarker[0] = UInt8(ascii: "X")
        #expect(CellMetricsCodec.decode(wrongMarker) == nil)
        // Plain cell JSON is not mistaken for metrics.
        #expect(CellMetricsCodec.decode(DetectionRecord.makeStorageSnapshot(cells(3)).data) == nil)
        // Inconsistent columns are never written.
        let broken = CellMetrics(diameterUm: [1, 2], diameterPx: [1], confidence: [1, 1], cx: [0, 0], cy: [0, 0])
        #expect(CellMetricsCodec.encode(broken).isEmpty)
    }

    @Test func storedMetricsAreUsedOnlyWhenCurrentAndConsistent() {
        let fixture = cells(10)
        let data = CellMetricsCodec.encode(fixture)
        let expected = CellMetrics(cells: fixture)
        #expect(DetectionRecord.currentMetrics(data: data, version: CellMetricsCodec.version, cellCountSummary: 10) == expected)
        #expect(DetectionRecord.currentMetrics(data: data, version: CellMetricsCodec.version, cellCountSummary: -1) == expected)
        #expect(DetectionRecord.currentMetrics(data: data, version: 0, cellCountSummary: 10) == nil)
        #expect(DetectionRecord.currentMetrics(data: data, version: CellMetricsCodec.version + 1, cellCountSummary: 10) == nil)
        #expect(DetectionRecord.currentMetrics(data: data, version: CellMetricsCodec.version, cellCountSummary: 9) == nil)
        #expect(DetectionRecord.currentMetrics(data: nil, version: CellMetricsCodec.version, cellCountSummary: 10) == nil)
        // Missing or stale metrics fall back to the full payload.
        let payload = DetectionRecord.makeStorageSnapshot(fixture).data
        #expect(DetectionRecord.metrics(storedData: nil, version: 0, cellCountSummary: 10, payload: { payload }) == expected)
        #expect(DetectionRecord.metrics(storedData: data, version: 0, cellCountSummary: 10,
                                        payload: { CellsBlobCodec.compress(payload) }) == expected)
        #expect(DetectionRecord.metrics(storedData: nil, version: 0, cellCountSummary: 10,
                                        payload: { Data("unreadable".utf8) }) == CellMetrics.empty)
    }

    // MARK: - Kept in sync with every cell write

    @Test func everyCellWriteKeepsMetricsInSync() throws {
        let (repos, batch) = library()
        let image = addImage(repos, batch, name: "a.tif", cells: cells(40))
        let detection = try #require(image.detection)
        try expectInSync(detection)

        // `cells` setter.
        detection.cells = cells(25, seed: 2)
        try expectInSync(detection)

        // Prepared snapshot (Results edits, Review, recalibration, rescaled variants).
        detection.applyStorageSnapshot(DetectionRecord.makeStorageSnapshot(cells(12, seed: 3)))
        try expectInSync(detection)

        // Edit commit path.
        var edited = DetectionRecord.decodeCellsData(detection.cellsData)
        edited.removeFirst(2)
        _ = repos.commitCellEdit(cells: edited, corrections: [], detection: detection, image: image)
        try expectInSync(detection)

        // A hand-built snapshot without metrics stores none (readers use the payload).
        let plain = DetectionRecord.makeStorageSnapshot(cells(4, seed: 4))
        detection.applyStorageSnapshot(DetectionRecord.CellsStorageSnapshot(
            data: plain.data, minimumConfidence: plain.minimumConfidence, count: plain.count))
        #expect(detection.cellMetricsData == nil)
        #expect(detection.cellMetricsVersion == 0)

        // Re-run replaces the detection with a new, in-sync record.
        repos.saveDetection(cells(8, seed: 5), detectorId: "rerun", for: image)
        try expectInSync(try #require(image.detection))
    }

    @Test func recalibrationRewritesMetricsWithTheCells() async throws {
        let (repos, batch) = library()
        let image = addImage(repos, batch, name: "cal.tif", cells: cells(30, pxPerUm: 2))
        let before = try storedMetrics(try #require(image.detection))
        let state = AppState(repos: repos)
        try await state.recalibrateBatch(batch, pxPerUm: 5, source: "manual")
        let detection = try #require(image.detection)
        try expectInSync(detection)
        let after = try storedMetrics(detection)
        #expect(after.diameterUm != before.diameterUm)
        #expect(after.diameterUm == DetectionRecord.decodeCellsData(detection.cellsData).map(\.diameter))
        #expect(bits(after.diameterPx) == bits(before.diameterPx))
    }

    @Test func archiveSnapshotCopiesMetricsAndRestoresOlderArchives() throws {
        let (repos, batch) = library()
        let image = addImage(repos, batch, name: "arch.tif", cells: cells(9))
        let detection = try #require(image.detection)
        let row = BatchRecordsSnapshot.Detection(detection)
        #expect(row.cellMetricsData == detection.cellMetricsData)
        #expect(row.cellMetricsVersion == CellMetricsCodec.version)
        let copy = row.makeRecord()
        #expect(copy.cellMetricsData == detection.cellMetricsData)
        #expect(copy.cellMetricsVersion == detection.cellMetricsVersion)
        #expect(BatchRecordsSnapshot.Detection(copy) == row)

        // An archive written before the fields existed reads back nil and 0.
        var older = row
        older.cellMetricsData = nil
        older.cellMetricsVersion = 0
        let restored = older.makeRecord()
        #expect(restored.cellMetricsData == nil)
        #expect(restored.cellMetricsVersion == 0)
        #expect(BatchRecordsSnapshot.Detection(restored) == older)
    }

    // MARK: - Same figures as the full decode

    @Test func batchRowsAndLibraryBarsEqualTheFullDecode() throws {
        let thresholdSets: [[Double]] = [[20, 30], [30, 20], [], [15], [10, 20, 30, 40, 50, 60]]
        for (seed, count) in [(1, 0), (2, 1), (3, 64), (4, 500)] {
            let fixture = cells(count, seed: seed)
            let data = DetectionRecord.makeStorageSnapshot(fixture).data
            let metrics = try #require(CellMetricsCodec.decode(CellMetricsCodec.encode(fixture)))
            for thresholds in thresholdSets {
                expectSameFigures(metrics, DetectionRecord.decodeCellsData(data), thresholds: thresholds)
                let bars = CellMetricsStats.imageSummary(metrics, thresholds: thresholds).bars
                #expect(bars == referenceLibraryBars(data, thresholds: thresholds))
                for diameter in [0.0, 19.9, 20, 25, 30, 45, 61] {
                    #expect(CellMetricsStats.binIndex(diameter, sortedThresholds: thresholds.sorted())
                            == BinMath.binIndex(for: diameter, thresholds: thresholds))
                }
            }
        }
    }

    @Test func pooledCompareValuesEqualTheFullDecode() throws {
        let thresholds: [Double] = [20, 30]
        var pooledFromMetrics: [Double] = []
        var pooledFromCells: [Double] = []
        for (seed, cutoff) in [(10, 0.5), (11, 0.65), (12, 0.0), (13, 1.0)] {
            let fixture = cells(200, seed: seed)
            let data = DetectionRecord.makeStorageSnapshot(fixture).data
            let metrics = try #require(CellMetricsCodec.decode(CellMetricsCodec.encode(fixture)))
            let fromMetrics = CellMetricsStats.diameters(metrics, atOrAbove: cutoff)
            let fromCells = referencePooled(data, cutoff: cutoff)
            #expect(bits(fromMetrics) == bits(fromCells))
            pooledFromMetrics += fromMetrics
            pooledFromCells += fromCells
        }
        let output = ComparisonPoolStats.summarize(name: "Control", batchCount: 2,
                                                   diameters: pooledFromMetrics, thresholds: thresholds)
        let reference = referencePoolStats(pooledFromCells, thresholds: thresholds)
        #expect(output.mean.bitPattern == reference.mean.bitPattern)
        #expect(output.sigma.bitPattern == reference.sigma.bitPattern)
        #expect(output.binCounts == reference.bins)
        #expect(output.buckets == reference.buckets)
        #expect(output.diameters.count == pooledFromCells.count)
    }

    @Test func confidenceOverrideAndRunCutoffMatchEffectiveConfidence() throws {
        let (repos, batch) = library()
        let withOverride = addImage(repos, batch, name: "override.tif", cells: cells(50, seed: 20))
        withOverride.confidenceOverride = 0.73
        let withRun = addImage(repos, batch, name: "run.tif", cells: nil)
        var settings = AnalysisRunSettings()
        settings.confidence = 0.31
        repos.saveDetection(cells(50, seed: 21), detectorId: "test", for: withRun, runSettings: settings)
        let global = addImage(repos, batch, name: "global.tif", cells: cells(50, seed: 22))
        let none = addImage(repos, batch, name: "none.tif", cells: nil)
        try repos.context.save()
        let state = AppState(repos: repos)

        let entries = try LibraryMetricsReader.batchImages(batchId: batch.id, container: repos.container, metrics: .all)
        #expect(entries.count == 4)
        for image in [withOverride, withRun, global, none] {
            let entry = try #require(entries.first { $0.id == image.id })
            let cutoff = entry.cutoff(global: state.confidence)
            #expect(cutoff == state.effectiveConfidence(for: image))
            guard let detection = image.detection else {
                #expect(entry.detection == nil)
                continue
            }
            let metrics = try #require(entry.detection?.metrics)
            #expect(bits(CellMetricsStats.diameters(metrics, atOrAbove: cutoff))
                    == bits(referencePooled(detection.cellsData, cutoff: cutoff)))
        }
    }

    @Test func roiFilteringEqualsROIFilterOnDecodedCells() throws {
        let (repos, batch) = library()
        let image = addImage(repos, batch, name: "roi.tif", cells: cells(300, seed: 30))
        let rois = [
            ROIRecord(imageId: image.id, kind: "include", shape: "rect", x: 100, y: 50, width: 200, height: 150),
            ROIRecord(imageId: image.id, kind: "include", shape: "ellipse", x: 0, y: 0, width: 120, height: 100),
            ROIRecord(imageId: image.id, kind: "exclude", shape: "rect", x: 150, y: 80, width: 30, height: 30),
            ROIRecord(imageId: image.id, kind: "exclude", shape: "ellipse", x: 250, y: 150, width: 0, height: 40),
        ]
        let detection = try #require(image.detection)
        let decoded = DetectionRecord.decodeCellsData(detection.cellsData)
        let metrics = try storedMetrics(detection)
        let regions = rois.map(ROIRegion.init)
        // Boundary points: on the rectangle edges and the ellipse boundary.
        for (x, y) in [(100.0, 50.0), (300, 200), (60, 0), (0, 50), (120, 50), (150, 80), (180, 110)] {
            for (roi, region) in zip(rois, regions) {
                #expect(region.contains(x: x, y: y) == ROIFilter.contains(roi: roi, x: x, y: y))
            }
        }
        for cutoff in [0.0, 0.5, 0.65] {
            for subset in [[], [rois[2]], [rois[0], rois[2]], rois] {
                let expected = ROIFilter.apply(cells: decoded.filter { $0.confidence >= cutoff }, rois: subset)
                let indices = CellMetricsStats.visibleIndices(metrics, cutoff: cutoff, rois: subset.map(ROIRegion.init))
                #expect(indices.map { decoded[$0].id } == expected.map(\.id))
                expectSameFigures(metrics.subset(indices), expected, thresholds: batch.thresholds)
            }
        }
    }

    @Test func figuresAfterRecalibrationEqualTheFullDecode() async throws {
        let (repos, batch) = library(thresholds: [12, 15])
        let images = (0..<3).map { addImage(repos, batch, name: "f\($0).tif", cells: cells(120, seed: 40 + $0)) }
        let state = AppState(repos: repos)
        try await state.recalibrateBatch(batch, pxPerUm: 3.7, source: "manual")
        try repos.context.save()
        let entries = try LibraryMetricsReader.batchImages(batchId: batch.id, container: repos.container, metrics: .all)
        for image in images {
            let detection = try #require(image.detection)
            let entry = try #require(entries.first { $0.id == image.id })
            let metrics = try #require(entry.detection?.metrics)
            expectSameFigures(metrics, DetectionRecord.decodeCellsData(detection.cellsData), thresholds: batch.thresholds)
            #expect(entry.detection?.cellsRevision == detection.cellsRevision)
        }
    }

    // MARK: - Background reader

    @Test func readerReturnsValuesAndSkipsKnownMetrics() throws {
        let (repos, batch) = library(condition: "Control")
        let analysed = addImage(repos, batch, name: "b.tif", cells: cells(20, seed: 50))
        let empty = addImage(repos, batch, name: "a.tif", cells: [])
        let pending = addImage(repos, batch, name: "c.tif", cells: nil)
        let other = repos.createBatch(displayName: "Other", modelId: "cp-cyto3", pxPerUm: 2,
                                      thresholds: [20, 30], condition: "Treated")
        addImage(repos, other, name: "x.tif", cells: cells(5, seed: 51), path: "/elsewhere/x.tif")
        try repos.context.save()

        let entries = try LibraryMetricsReader.batchImages(batchId: batch.id, container: repos.container, metrics: .all)
        #expect(Set(entries.map(\.id)) == [analysed.id, empty.id, pending.id])
        let analysedEntry = try #require(entries.first { $0.id == analysed.id })
        #expect(analysedEntry.batchId == batch.id)
        #expect(analysedEntry.detection?.cellCount == analysed.detection?.summaryCellCount)
        let analysedDetection = try #require(analysed.detection)
        #expect(analysedEntry.detection?.metrics == CellMetrics(cells: analysedDetection.cells))
        #expect(entries.first { $0.id == empty.id }?.detection?.metrics == CellMetrics.empty)
        #expect(entries.first { $0.id == pending.id }?.hasDetection == false)
        #expect(entries.first { $0.id == pending.id }?.detection == nil)

        let known = Set(entries.compactMap { $0.detection?.key })
        let again = try LibraryMetricsReader.batchImages(batchId: batch.id, container: repos.container,
                                                         metrics: .allExcept(known))
        #expect(again.allSatisfy { $0.detection?.metrics == nil })
        #expect(again.compactMap { $0.detection?.key } == entries.compactMap { $0.detection?.key })

        let single = try #require(try LibraryMetricsReader.image(id: analysed.id, container: repos.container, metrics: .none))
        #expect(single.detection?.metrics == nil)
        #expect(single.detection?.cellCount == 20)
        #expect(try LibraryMetricsReader.image(id: UUID(), container: repos.container, metrics: .all) == nil)

        #expect(try LibraryMetricsReader.batchIds(condition: "Control", container: repos.container) == [batch.id])
        let info = try LibraryMetricsReader.folderInfo(batchIds: [batch.id, other.id], container: repos.container)
        #expect(info[batch.id] == BatchFolderInfo(imageCount: 3, label: "plate"))
        #expect(info[other.id] == BatchFolderInfo(imageCount: 1, label: nil))

        let all = try LibraryMetricsReader.library(container: repos.container)
        #expect(all.images.count == 4)
        #expect(all.thresholds[batch.id] == [20, 30])
        #expect(all.images.first { $0.id == analysed.id }?.hasDetection == true)
    }

    @Test func readerFallsBackToThePayloadForRowsWithoutMetrics() throws {
        let (repos, batch) = library()
        let image = addImage(repos, batch, name: "legacy.tif", cells: cells(33, seed: 60))
        let detection = try #require(image.detection)
        detection.storeCellMetrics(nil)
        try repos.context.save()
        let entry = try #require(try LibraryMetricsReader.image(id: image.id, container: repos.container, metrics: .all))
        #expect(entry.detection?.metrics == CellMetrics(cells: detection.cells))

        // Legacy rows without a stored count take it from their cells.
        detection.cellCountSummary = -1
        try repos.context.save()
        let legacy = try #require(try LibraryMetricsReader.image(id: image.id, container: repos.container, metrics: .none))
        #expect(legacy.detection?.cellCount == 33)
    }

    @Test func folderLabelMatchesTheSharedParentFolder() {
        #expect(BatchFolderInfo.label(originalPaths: ["/a/plate/1.tif", "/a/plate/2.tif"]) == "plate")
        #expect(BatchFolderInfo.label(originalPaths: ["/a/plate/1.tif", "", "/a/plate/2.tif"]) == "plate")
        #expect(BatchFolderInfo.label(originalPaths: ["/a/plate/1.tif"]) == nil)
        #expect(BatchFolderInfo.label(originalPaths: ["/a/plate/1.tif", "/a/other/2.tif"]) == nil)
        #expect(BatchFolderInfo.label(originalPaths: ["", ""]) == nil)
        #expect(BatchFolderInfo.label(originalPaths: ["1.tif", "2.tif"]) == nil)
    }

    // MARK: - Backfill

    @Test func backfillFillsMetricsAndIsIdempotent() async throws {
        let (repos, batch) = library()
        var images: [ImageRecord] = []
        for index in 0..<11 {
            images.append(addImage(repos, batch, name: "\(index).tif", cells: cells(15 + index, seed: 70 + index)))
        }
        // Saved before metrics existed, or by another codec version.
        for (index, image) in images.enumerated() {
            let detection = try #require(image.detection)
            if index == 3 {
                detection.cellMetricsData = Data([1, 2, 3])
                detection.cellMetricsVersion = CellMetricsCodec.version + 7
            } else {
                detection.storeCellMetrics(nil)
            }
        }
        // An unreadable payload is skipped and left as it is.
        let damaged = addImage(repos, batch, name: "damaged.tif", cells: cells(3, seed: 99))
        let damagedDetection = try #require(damaged.detection)
        damagedDetection.cellsData = Data("not cells".utf8)
        damagedDetection.storeCellMetrics(nil)
        try repos.context.save()

        let revisions = images.map { $0.detection?.cellsRevision }
        let written = try await repos.backfillCellMetrics(chunkSize: 4)
        #expect(written == images.count)
        for image in images { try expectInSync(try #require(image.detection)) }
        #expect(images.map { $0.detection?.cellsRevision } == revisions)
        #expect(damagedDetection.cellMetricsData == nil)
        #expect(damagedDetection.cellMetricsVersion == 0)

        #expect(try await repos.backfillCellMetrics(chunkSize: 4) == 0)
        #expect(!repos.context.hasChanges)
    }

    @Test func backfillWaitsWhileArchiveOrRestoreHoldsUpkeep() async throws {
        let (repos, batch) = library()
        let image = addImage(repos, batch, name: "held.tif", cells: cells(6))
        let detection = try #require(image.detection)
        detection.storeCellMetrics(nil)
        try repos.context.save()

        repos.holdVariantCompaction()
        #expect(repos.isBackgroundUpkeepHeld)
        #expect(try await repos.backfillCellMetrics() == 0)
        #expect(detection.cellMetricsVersion == 0)
        repos.releaseVariantCompaction()
        #expect(!repos.isBackgroundUpkeepHeld)
        #expect(try await repos.backfillCellMetrics() == 1)
        try expectInSync(detection)
    }

    // MARK: - Coalesced refresh

    @Test func refreshRequestsAreCoalesced() async throws {
        let refresh = CoalescedRefresh()
        var calls: [(Bool, Set<UUID>)] = []
        let a = UUID(), b = UUID()
        refresh.request(a, delay: .zero) { everything, ids in calls.append((everything, ids)) }
        refresh.request(b, delay: .zero) { everything, ids in calls.append((everything, ids)) }
        for _ in 0..<200 where calls.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        #expect(calls.count == 1)
        #expect(calls.first?.0 == false)
        #expect(calls.first?.1 == [a, b])

        calls = []
        refresh.request(a, delay: .zero) { everything, ids in calls.append((everything, ids)) }
        refresh.request(nil, delay: .zero) { everything, ids in calls.append((everything, ids)) }
        for _ in 0..<200 where calls.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        #expect(calls.count == 1)
        #expect(calls.first?.0 == true)
        #expect(calls.first?.1 == [])
    }
}
