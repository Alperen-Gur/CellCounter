import Foundation

// MARK: - Compact per-cell metrics

/// The per-cell values that screens listing or comparing many images read,
/// without outlines or optional measurements:
///
/// - `diameterUm`: the stored µm diameter. Batches (count, mean, size bins),
///   the Images library mini-bars and Compare (pooled diameters) read it.
///   Recalibration rewrites the stored µm values and the metrics with them,
///   so it is always in the batch's current calibration, exactly as the full
///   payload is.
/// - `diameterPx`: the stored pixel diameter, for converting with a different
///   scale where a screen needs it.
/// - `confidence`: compared with the image's effective cut-off (Compare).
/// - `cx`, `cy`: pixel-space centroid, for ROI include/exclude (`ROIRegion`).
///
/// Every value is the stored Float64 from the saved cell payload, bit for bit,
/// so a count, bin, mean or ROI test computed from these equals the same
/// computation over fully decoded cells. Thresholds, cut-offs and ROIs are
/// applied when read, never stored, because they can change after saving.
nonisolated struct CellMetrics: Sendable, Equatable {
    var diameterUm: [Double]
    var diameterPx: [Double]
    var confidence: [Double]
    var cx: [Double]
    var cy: [Double]

    var count: Int { diameterUm.count }

    init(diameterUm: [Double], diameterPx: [Double], confidence: [Double], cx: [Double], cy: [Double]) {
        self.diameterUm = diameterUm
        self.diameterPx = diameterPx
        self.confidence = confidence
        self.cx = cx
        self.cy = cy
    }

    init(cells: [DetectedCell]) {
        self.init(diameterUm: cells.map(\.diameter), diameterPx: cells.map(\.diameterPx),
                  confidence: cells.map(\.confidence), cx: cells.map(\.cx), cy: cells.map(\.cy))
    }

    static let empty = CellMetrics(diameterUm: [], diameterPx: [], confidence: [], cx: [], cy: [])

    var hasConsistentColumns: Bool {
        let n = count
        return diameterPx.count == n && confidence.count == n && cx.count == n && cy.count == n
    }

    /// The cells at `indices`, in the given order.
    func subset(_ indices: [Int]) -> CellMetrics {
        CellMetrics(diameterUm: indices.map { diameterUm[$0] }, diameterPx: indices.map { diameterPx[$0] },
                    confidence: indices.map { confidence[$0] }, cx: indices.map { cx[$0] },
                    cy: indices.map { cy[$0] })
    }
}

/// Binary form of `CellMetrics`, stored in `DetectionRecord.cellMetricsData`.
///
/// Layout (little-endian): the marker `CCM1`, a UInt32 cell count `n`, then
/// five columns of `n` IEEE-754 Float64 bit patterns each, in the order
/// diameterUm, diameterPx, confidence, cx, cy. Total size is `8 + 40 n`
/// bytes. Anything else decodes to nil and readers fall back to the full
/// cell payload.
nonisolated enum CellMetricsCodec {
    /// Stored in `DetectionRecord.cellMetricsVersion`. Bump it whenever the
    /// layout or the set of columns changes: rows with another version are
    /// read through the full payload until the backfill rewrites them.
    static let version = 1
    static let magic: [UInt8] = Array("CCM1".utf8)
    static let headerSize = 8
    static let columnCount = 5
    static let bytesPerCell = 8 * columnCount

    static func encode(_ cells: [DetectedCell]) -> Data {
        encode(CellMetrics(cells: cells))
    }

    static func encode(_ metrics: CellMetrics) -> Data {
        let n = metrics.count
        guard metrics.hasConsistentColumns, n <= Int(UInt32.max) else { return Data() }
        var data = Data(count: headerSize + n * bytesPerCell)
        data.withUnsafeMutableBytes { raw in
            for (index, byte) in magic.enumerated() { raw[index] = byte }
            raw.storeBytes(of: UInt32(n).littleEndian, toByteOffset: 4, as: UInt32.self)
            var offset = headerSize
            for column in [metrics.diameterUm, metrics.diameterPx, metrics.confidence, metrics.cx, metrics.cy] {
                for value in column {
                    raw.storeBytes(of: value.bitPattern.littleEndian, toByteOffset: offset, as: UInt64.self)
                    offset += 8
                }
            }
        }
        return data
    }

    static func decode(_ data: Data) -> CellMetrics? {
        guard data.count >= headerSize else { return nil }
        return data.withUnsafeBytes { raw -> CellMetrics? in
            for (index, byte) in magic.enumerated() where raw[index] != byte { return nil }
            let n = Int(UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: 4, as: UInt32.self)))
            guard raw.count == headerSize + n * bytesPerCell else { return nil }
            func column(_ index: Int) -> [Double] {
                let base = headerSize + index * n * 8
                return [Double](unsafeUninitializedCapacity: n) { buffer, initialized in
                    for cell in 0..<n {
                        let bits = UInt64(littleEndian: raw.loadUnaligned(fromByteOffset: base + cell * 8, as: UInt64.self))
                        buffer[cell] = Double(bitPattern: bits)
                    }
                    initialized = n
                }
            }
            return CellMetrics(diameterUm: column(0), diameterPx: column(1), confidence: column(2),
                               cx: column(3), cy: column(4))
        }
    }
}

// MARK: - Stored metrics on a detection

extension DetectionRecord {
    /// Stores metrics bytes with their codec version (0 when nil, meaning
    /// "not written"). Every write of the cell payload calls this.
    nonisolated func storeCellMetrics(_ data: Data?) {
        cellMetricsData = data
        cellMetricsVersion = data == nil ? 0 : CellMetricsCodec.version
    }

    /// Stored metrics when they were written by the current codec and agree
    /// with the stored cell count; nil means "derive them from the payload".
    nonisolated static func currentMetrics(data: Data?, version: Int, cellCountSummary: Int) -> CellMetrics? {
        guard version == CellMetricsCodec.version, let data,
              let metrics = CellMetricsCodec.decode(data) else { return nil }
        if cellCountSummary >= 0, metrics.count != cellCountSummary { return nil }
        return metrics
    }

    /// Metrics for a detection: the stored ones, or else the same values taken
    /// from the full cell payload (rows not backfilled yet). An unreadable
    /// payload gives no cells, as `decodeCellsData` always has.
    nonisolated static func metrics(storedData: Data?, version: Int, cellCountSummary: Int,
                                    payload: () -> Data) -> CellMetrics {
        if let stored = currentMetrics(data: storedData, version: version, cellCountSummary: cellCountSummary) {
            return stored
        }
        return CellMetrics(cells: decodeCellsData(payload()))
    }
}

// MARK: - Read-time statistics

/// The figures list and compare screens show, computed from `CellMetrics`.
/// Each function reproduces the arithmetic those screens used on decoded
/// cells (same operations, same order), so the results are identical.
nonisolated enum CellMetricsStats {
    /// `BinMath.binIndex(for:thresholds:)` with the thresholds sorted once.
    static func binIndex(_ diameter: Double, sortedThresholds: [Double]) -> Int {
        for (index, threshold) in sortedThresholds.enumerated() where diameter < threshold { return index }
        return sortedThresholds.count
    }

    /// Per-bin cell counts as the Batches table and the Images library draw
    /// them: one bin per threshold gap (at least five), then only the first
    /// five bins. Cells in a sixth or later bin are not shown, as before.
    static func fiveBinCounts(_ diameters: [Double], thresholds: [Double]) -> [Double] {
        let sorted = thresholds.sorted()
        var bins = Array(repeating: 0.0, count: max(thresholds.count + 1, 5))
        for diameter in diameters {
            let index = min(binIndex(diameter, sortedThresholds: sorted), bins.count - 1)
            bins[index] += 1
        }
        while bins.count < 5 { bins.append(0) }
        return Array(bins.prefix(5))
    }

    /// Bar heights in percent of the tallest of the five bins.
    static func normalizedBars(_ counts: [Double]) -> [Double] {
        let tallest = counts.max() ?? 1
        return counts.map { tallest > 0 ? $0 / tallest * 100 : 0 }
    }

    /// One analysed image as a Batches table row or a Library tile shows it:
    /// every stored cell, no confidence cut-off and no ROI.
    nonisolated struct ImageSummary: Sendable, Equatable {
        let count: Int
        /// Mean stored µm diameter; nil without cells.
        let meanDiameter: Double?
        /// `fiveBinCounts`; nil without cells.
        let binCounts: [Double]?
        /// `normalizedBars(binCounts)`; nil without cells.
        let bars: [Double]?
    }

    static func imageSummary(_ metrics: CellMetrics, thresholds: [Double]) -> ImageSummary {
        guard metrics.count > 0 else {
            return ImageSummary(count: 0, meanDiameter: nil, binCounts: nil, bars: nil)
        }
        let mean = metrics.diameterUm.reduce(0, +) / Double(metrics.count)
        let counts = fiveBinCounts(metrics.diameterUm, thresholds: thresholds)
        return ImageSummary(count: metrics.count, meanDiameter: mean, binCounts: counts,
                            bars: normalizedBars(counts))
    }

    /// Indices of the cells at or above `cutoff` that pass the ROIs, in stored
    /// order: the cells Results counts for an image (`confidence >= cutoff`,
    /// then `ROIFilter.apply`).
    static func visibleIndices(_ metrics: CellMetrics, cutoff: Double, rois: [ROIRegion] = []) -> [Int] {
        let includes = rois.filter { $0.kind == "include" }
        let excludes = rois.filter { $0.kind == "exclude" }
        var indices: [Int] = []
        indices.reserveCapacity(metrics.count)
        for index in 0..<metrics.count where metrics.confidence[index] >= cutoff {
            if rois.isEmpty || ROIRegion.passes(x: metrics.cx[index], y: metrics.cy[index],
                                                includes: includes, excludes: excludes) {
                indices.append(index)
            }
        }
        return indices
    }

    /// Stored µm diameters of the cells at or above `cutoff`, in stored order
    /// (Compare's pooled values).
    static func diameters(_ metrics: CellMetrics, atOrAbove cutoff: Double) -> [Double] {
        diameters(diameterUm: metrics.diameterUm, confidence: metrics.confidence, atOrAbove: cutoff)
    }

    static func diameters(diameterUm: [Double], confidence: [Double], atOrAbove cutoff: Double) -> [Double] {
        var values: [Double] = []
        values.reserveCapacity(diameterUm.count)
        for index in 0..<min(diameterUm.count, confidence.count) where confidence[index] >= cutoff {
            values.append(diameterUm[index])
        }
        return values
    }
}

// MARK: - ROI geometry without the model

/// The geometry of an `ROIRecord` as a value, with the same include/exclude
/// rule and point test as `ROIFilter`, so ROI filtering can run on metrics
/// away from the main actor.
nonisolated struct ROIRegion: Sendable, Equatable {
    var kind: String
    var shape: String
    var x: Double
    var y: Double
    var width: Double
    var height: Double

    init(kind: String, shape: String, x: Double, y: Double, width: Double, height: Double) {
        self.kind = kind
        self.shape = shape
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    init(_ record: ROIRecord) {
        self.init(kind: record.kind, shape: record.shape, x: record.x, y: record.y,
                  width: record.width, height: record.height)
    }

    /// Same test as `ROIFilter.contains(roi:x:y:)`.
    func contains(x px: Double, y py: Double) -> Bool {
        switch shape {
        case "ellipse":
            let rw = width / 2
            let rh = height / 2
            guard rw > 0, rh > 0 else { return false }
            let cx = x + rw
            let cy = y + rh
            let nx = (px - cx) / rw
            let ny = (py - cy) / rh
            return nx * nx + ny * ny <= 1
        default:
            return px >= x && px <= x + width && py >= y && py <= y + height
        }
    }

    /// Same rule as `ROIFilter.apply`: inside at least one include ROI when
    /// there are any, and inside no exclude ROI.
    static func passes(x: Double, y: Double, includes: [ROIRegion], excludes: [ROIRegion]) -> Bool {
        if !includes.isEmpty, !includes.contains(where: { $0.contains(x: x, y: y) }) { return false }
        return !excludes.contains(where: { $0.contains(x: x, y: y) })
    }
}
