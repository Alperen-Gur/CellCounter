import Foundation

// MARK: — Intensity-based assays
//
// Domain model + pure computation for the six intensity assays. This file has
// no SwiftUI and no AppState dependency — the panels in Views/Results feed it
// `[DetectedCell]` plus the flat `imageStats` dictionary and render whatever
// comes back, which keeps the maths unit-testable on its own.
//
// TWO SOURCES OF TRUTH, DELIBERATELY
// ----------------------------------
// 1. **Computed live in Swift** from `DetectedCell.channelIntensities`, the
//    per-cell scalars the detection sidecar already emits. Everything that only
//    needs one number per cell per channel lands here — marker positivity,
//    transfection efficiency, live/dead, cell cycle. These recompute instantly
//    when the user drags a threshold, with no Python round-trip.
//
// 2. **Read back from `image_stats`** for the two assays that genuinely need
//    pixel-level data — nuclear:cytoplasmic ratio and colocalization. Pearson
//    and Manders are defined over *pixels*; they cannot be reconstructed from
//    per-cell means, and pretending otherwise would be a different statistic
//    wearing the same name. `CellCounting/python/intensity_assays.py` computes
//    them and writes flat `assay_*` keys into the same `image_stats` namespace
//    that colony/QC stats already use, so they reach the UI with no schema
//    change. Until that sidecar has run for an image, those two panels say so
//    rather than inventing a number.
//
// The Swift Otsu implementation below intentionally mirrors
// `_assays_intensity.otsu_threshold` bin-for-bin, including its midpoint
// refinement, so a threshold computed here and one computed in Python agree.

// MARK: — Channel descriptor

/// One channel available for assay selection, derived from the per-cell
/// `channelIntensities` the sidecar emitted.
struct AssayChannel: Identifiable, Hashable {
    let index: Int
    let name: String?

    var id: Int { index }

    /// "DAPI" when the file carried channel names, "Channel 0" otherwise.
    var displayName: String {
        if let name, !name.isEmpty { return name }
        return "Channel \(index)"
    }

    /// "1 · GFP" — used where the index needs to stay visible.
    var indexedName: String {
        if let name, !name.isEmpty { return "\(index) · \(name)" }
        return "Channel \(index)"
    }
}

// MARK: — Parameters

/// Which per-cell scalar an assay thresholds.
enum AssayMetric: String, CaseIterable, Identifiable, Hashable {
    case mean, integrated, median

    var id: String { rawValue }

    var label: String {
        switch self {
        case .mean:       return "Mean"
        case .integrated: return "Integrated"
        case .median:     return "Median"
        }
    }

    var blurb: String {
        switch self {
        case .mean:       return "Average pixel value inside the mask."
        case .integrated: return "Sum of pixel values — scales with cell size."
        case .median:     return "Robust to a few saturated pixels."
        }
    }
}

/// How a positivity threshold is chosen.
enum AssayThresholdMode: String, CaseIterable, Identifiable, Hashable {
    /// A value the user types or drags.
    case manual
    /// Otsu's method over the per-cell values.
    case otsu
    /// mean + k×SD of the negative population (split out with Otsu).
    case negativeSD

    var id: String { rawValue }

    var label: String {
        switch self {
        case .manual:     return "Manual"
        case .otsu:       return "Otsu"
        case .negativeSD: return "Mean + k·SD"
        }
    }

    var blurb: String {
        switch self {
        case .manual:
            return "Set the cut-off yourself."
        case .otsu:
            return "Automatic — splits the per-cell values at the point that "
                 + "maximises between-class variance."
        case .negativeSD:
            return "Cut-off = mean + k×SD of the negative population, which is "
                 + "taken as everything at or below the Otsu split."
        }
    }
}

// MARK: — Availability

/// Why an assay can or can't run right now. Every assay degrades into one of
/// these rather than showing a misleading zero.
///
/// Conforms to `Error` so it can be the failure type of the engine's
/// `Result` returns — the panels switch on it and render `message`; nothing
/// ever `throw`s it.
enum AssayAvailability: Error, Equatable {
    case ready
    /// The image doesn't carry enough channels.
    case needsChannels(have: Int, need: Int)
    /// Detection ran before multi-channel measurement existed.
    case noChannelData
    /// Pixel-level assay whose sidecar hasn't been run for this image.
    case needsSidecar
    /// Population assays need a population.
    case notEnoughCells(have: Int, need: Int)
    /// Two channel pickers resolved to the same channel.
    case duplicateChannels
    /// The per-cell values are constant, so no automatic split exists.
    case thresholdUnresolved

    var message: String {
        switch self {
        case .ready:
            return ""
        case .needsChannels(let have, let need):
            return "Requires \(need) channels — this image has \(have). "
                 + "Open a multi-channel file (CZI, ND2, LIF, multi-page TIFF) "
                 + "to use this assay."
        case .noChannelData:
            return "This detection has no per-channel intensity data. Re-run "
                 + "detection on a multi-channel image to populate it."
        case .needsSidecar:
            return "Pixel-level assay — run the intensity-assay step for this "
                 + "image to compute it. Per-cell averages can't stand in for "
                 + "a pixel-level coefficient."
        case .notEnoughCells(let have, let need):
            return "Needs at least \(need) cells to find a population; this "
                 + "image has \(have). Pool more fields of view."
        case .duplicateChannels:
            return "Pick two different channels."
        case .thresholdUnresolved:
            return "The per-cell intensities are constant, so no automatic "
                 + "cut-off exists. Switch to a manual threshold."
        }
    }

    var isReady: Bool { self == .ready }
}

// MARK: — Assay catalog

/// The six assays, named the way researchers search for them.
enum IntensityAssayKind: String, CaseIterable, Identifiable, Hashable {
    case markerPositive
    case nuclearCytoplasmic
    case colocalization
    case liveDead
    case transfectionEfficiency
    case cellCycle

    var id: String { rawValue }

    var title: String {
        switch self {
        case .markerPositive:        return "% marker-positive"
        case .nuclearCytoplasmic:    return "Nuclear : cytoplasmic ratio"
        case .colocalization:        return "Colocalization"
        case .liveDead:              return "Live / dead viability"
        case .transfectionEfficiency: return "Transfection efficiency"
        case .cellCycle:             return "Cell cycle (DNA content)"
        }
    }

    var subtitle: String {
        switch self {
        case .markerPositive:
            return "Ki67, EdU, BrdU, cleaved caspase-3 — one channel, one cut-off."
        case .nuclearCytoplasmic:
            return "Nuclear vs cytoplasmic intensity per cell (translocation)."
        case .colocalization:
            return "Pearson r and Manders M1/M2 between two channels."
        case .liveDead:
            return "Two-channel viability — calcein / EthD-1, PI, …"
        case .transfectionEfficiency:
            return "% of cells expressing the reporter (GFP, mCherry, …)."
        case .cellCycle:
            return "G1 / S / G2-M estimate from integrated DNA intensity."
        }
    }

    /// Minimum channel count the assay needs.
    var minimumChannels: Int {
        switch self {
        case .colocalization, .liveDead: return 2
        default: return 1
        }
    }

    /// Extra terms users type when looking for this readout. Kept next to the
    /// assay so a future search field has a single source of truth.
    var searchAliases: [String] {
        switch self {
        case .markerPositive:
            return ["ki67", "edu", "brdu", "cleaved caspase", "proliferation",
                    "apoptosis", "percent positive"]
        case .nuclearCytoplasmic:
            return ["n:c", "nc ratio", "translocation", "nuclear translocation"]
        case .colocalization:
            return ["coloc", "pearson", "manders", "m1", "m2", "overlap"]
        case .liveDead:
            return ["viability", "calcein", "propidium iodide", "ethd-1",
                    "percent viable"]
        case .transfectionEfficiency:
            return ["transfection", "gfp positive", "reporter", "electroporation"]
        case .cellCycle:
            return ["cell cycle", "dna content", "g1", "s phase", "g2m",
                    "ploidy", "2n", "4n"]
        }
    }

    /// True when the assay needs pixel-level data and therefore the Python
    /// sidecar; false when Swift can compute it live from per-cell scalars.
    var requiresSidecar: Bool {
        switch self {
        case .nuclearCytoplasmic, .colocalization: return true
        default: return false
        }
    }
}

// MARK: — Results

/// One cell's positivity call.
struct AssayCellFlag: Identifiable, Hashable {
    let id: UUID
    let value: Double
    let isPositive: Bool
}

/// Assay 1 (% marker-positive) and assay 5 (transfection efficiency) — same
/// maths, different framing.
struct MarkerPositivityResult: Equatable {
    let channel: AssayChannel
    let metric: AssayMetric
    let mode: AssayThresholdMode
    let threshold: Double
    /// Populated for `.negativeSD`: how the negative population was resolved.
    let negativeMean: Double?
    let negativeSD: Double?
    let k: Double?

    let cellCount: Int
    let positiveCount: Int
    let meanPositive: Double?
    let meanNegative: Double?
    let flags: [AssayCellFlag]

    var negativeCount: Int { cellCount - positiveCount }
    var percentPositive: Double {
        cellCount > 0 ? 100.0 * Double(positiveCount) / Double(cellCount) : 0
    }
}

/// Assay 4 — live/dead viability.
struct ViabilityResult: Equatable {
    enum State: String { case live, dead, unlabelled }

    let liveChannel: AssayChannel
    let deadChannel: AssayChannel
    let liveThreshold: Double
    let deadThreshold: Double
    let metric: AssayMetric

    let cellCount: Int
    let liveCount: Int
    let deadCount: Int
    let unlabelledCount: Int
    let doublePositiveCount: Int
    let states: [UUID: State]

    /// live / (live + dead) — the standard readout; unlabelled cells excluded.
    var percentViable: Double {
        let denom = liveCount + deadCount
        return denom > 0 ? 100.0 * Double(liveCount) / Double(denom) : 0
    }
    /// live / every segmented cell.
    var percentViableOfAll: Double {
        cellCount > 0 ? 100.0 * Double(liveCount) / Double(cellCount) : 0
    }
    var percentDead: Double {
        let denom = liveCount + deadCount
        return denom > 0 ? 100.0 * Double(deadCount) / Double(denom) : 0
    }
}

/// Assay 6 — cell-cycle phase estimate.
struct CellCycleResult: Equatable {
    enum Phase: String, CaseIterable {
        case subG1 = "sub-G1"
        case g1 = "G1"
        case s = "S"
        case g2m = "G2/M"
        case aboveG2M = "> G2/M"

        var explanation: String {
            switch self {
            case .subG1:    return "Below the 2n gate — apoptotic bodies or debris."
            case .g1:       return "2n DNA content."
            case .s:        return "Between the 2n and 4n gates — replicating."
            case .g2m:      return "4n DNA content."
            case .aboveG2M: return "Above the 4n gate — polyploid, or two cells segmented as one."
            }
        }
    }

    let channel: AssayChannel
    let cellCount: Int
    let g1Peak: Double
    let g2Peak: Double
    /// False when no second peak was found near 2× G1 and 2× G1 was assumed.
    let g2PeakFound: Bool
    let gateWidth: Double
    let counts: [Phase: Int]
    let phases: [UUID: Phase]
    /// Histogram of per-cell integrated DNA intensity, for the sparkline.
    let histogram: [Int]
    let histogramRange: ClosedRange<Double>

    var g2OverG1: Double { g1Peak > 0 ? g2Peak / g1Peak : 0 }

    func percent(_ phase: Phase) -> Double {
        guard cellCount > 0 else { return 0 }
        return 100.0 * Double(counts[phase] ?? 0) / Double(cellCount)
    }

    /// Shown verbatim in the UI. This is a peak-and-gate heuristic, not a
    /// Watson / Dean-Jett-Fox model fit — do not let the wording drift.
    static let caveat =
        "Estimate. Phases are gated around the 2n and 4n peaks of the "
        + "integrated-DNA histogram, not fitted with a cell-cycle model. "
        + "Verify against flow cytometry before reporting."
}

/// Assay 3 — colocalization, read back from the sidecar's `image_stats`.
struct ColocalizationResult: Equatable {
    struct Scope: Equatable {
        let pearson: Double?
        let mandersM1: Double?
        let mandersM2: Double?

        var isEmpty: Bool { pearson == nil && mandersM1 == nil && mandersM2 == nil }
    }

    let channelA: Int
    let channelB: Int
    let thresholdA: Double?
    let thresholdB: Double?
    /// Whole image, every pixel.
    let image: Scope
    /// Restricted to pixels inside a cell mask.
    let inCells: Scope
    /// Mean/median of the per-cell coefficients.
    let perCellMeanPearson: Double?
    let perCellMedianPearson: Double?
    let perCellMeanM1: Double?
    let perCellMeanM2: Double?
    let perCellCount: Int?

    /// Manders is meaningless without its threshold — always render this.
    var thresholdNote: String {
        let a = thresholdA.map { String(format: "%.4g", $0) } ?? "—"
        let b = thresholdB.map { String(format: "%.4g", $0) } ?? "—"
        return "Manders thresholds: A > \(a), B > \(b)"
    }
}

/// Assay 2 — nuclear:cytoplasmic ratio, read back from `image_stats`.
struct NuclearCytoplasmicResult: Equatable {
    let channel: Int
    let cellCount: Int
    let skippedCount: Int
    let meanRatio: Double
    let medianRatio: Double
    let sdRatio: Double?
}

// MARK: — Engine

/// Pure functions. No I/O, no global state, no SwiftUI.
enum IntensityAssays {

    // MARK: Channel discovery

    /// Channels present in the detection, in index order. Empty when the
    /// detection predates multi-channel measurement.
    static func channels(in cells: [DetectedCell]) -> [AssayChannel] {
        var names: [Int: String] = [:]
        var indices = Set<Int>()
        for cell in cells {
            guard let entries = cell.channelIntensities else { continue }
            for entry in entries {
                indices.insert(entry.channel)
                if names[entry.channel] == nil,
                   let n = entry.name, !n.isEmpty {
                    names[entry.channel] = n
                }
            }
        }
        return indices.sorted().map { AssayChannel(index: $0, name: names[$0]) }
    }

    /// Best guess at the DNA channel, by name. Used only to pick a sensible
    /// default in the pickers — the user can always override it.
    static func likelyDNAChannel(in channels: [AssayChannel]) -> AssayChannel? {
        let needles = ["dapi", "hoechst", "draq", "sytox", "dna"]
        return channels.first { channel in
            guard let name = channel.name?.lowercased() else { return false }
            return needles.contains { name.contains($0) }
        }
    }

    /// Best guess at a marker/reporter channel: the first channel that doesn't
    /// look like a DNA stain, falling back to the first channel.
    static func likelyMarkerChannel(in channels: [AssayChannel]) -> AssayChannel? {
        let dna = likelyDNAChannel(in: channels)
        return channels.first { $0.index != dna?.index } ?? channels.first
    }

    /// Per-cell scalar for one channel, paired with the owning cell id. Cells
    /// missing that channel are skipped, so `count` can be < `cells.count`.
    static func values(in cells: [DetectedCell],
                       channel: Int,
                       metric: AssayMetric) -> [(id: UUID, value: Double)] {
        var out: [(id: UUID, value: Double)] = []
        out.reserveCapacity(cells.count)
        for cell in cells {
            guard let entries = cell.channelIntensities,
                  let entry = entries.first(where: { $0.channel == channel })
            else { continue }
            let v: Double?
            switch metric {
            case .mean:       v = entry.mean
            case .integrated: v = entry.integrated
            case .median:     v = entry.median ?? entry.mean
            }
            guard let value = v, value.isFinite else { continue }
            out.append((id: cell.id, value: value))
        }
        return out
    }

    // MARK: Thresholding

    /// Otsu's threshold — a bin-for-bin port of
    /// `_assays_intensity.otsu_threshold`, including the midpoint refinement,
    /// so Swift and Python agree on the same data.
    ///
    /// Returns nil for an empty or constant input.
    static func otsuThreshold(_ values: [Double], bins: Int = 256) -> Double? {
        let v = values.filter { $0.isFinite }
        guard v.count >= 2 else { return nil }
        guard let vmin = v.min(), let vmax = v.max(), vmax > vmin else { return nil }

        let n = max(2, bins)
        let width = (vmax - vmin) / Double(n)
        guard width > 0 else { return nil }

        var counts = [Double](repeating: 0, count: n)
        for value in v {
            var idx = Int((value - vmin) / width)
            if idx >= n { idx = n - 1 }        // the max lands in the last bin
            if idx < 0 { idx = 0 }
            counts[idx] += 1
        }
        let centers = (0..<n).map { vmin + (Double($0) + 0.5) * width }

        // Forward / reverse cumulative weights and means.
        var weight1 = [Double](repeating: 0, count: n)
        var cumSum1 = [Double](repeating: 0, count: n)
        var running = 0.0
        var runningSum = 0.0
        for i in 0..<n {
            running += counts[i]
            runningSum += counts[i] * centers[i]
            weight1[i] = running
            cumSum1[i] = runningSum
        }
        let total = running
        let totalSum = runningSum

        var best = -1.0
        var bestIndex = -1
        for i in 0..<(n - 1) {
            let w1 = weight1[i]
            let w2 = total - w1
            guard w1 > 0, w2 > 0 else { continue }
            let m1 = cumSum1[i] / w1
            let m2 = (totalSum - cumSum1[i]) / w2
            let variance = w1 * w2 * (m1 - m2) * (m1 - m2)
            if variance > best {
                best = variance
                bestIndex = i
            }
        }
        guard bestIndex >= 0, best > 0 else { return nil }

        // Refine onto the real gap between the two classes: with few cells the
        // between-class variance plateaus across every empty bin, argmax picks
        // the first plateau index, and its bin centre can fall inside the low
        // cluster. Same fix as the Python side.
        let boundary = vmin + Double(bestIndex + 1) * width
        let low = v.filter { $0 <= boundary }
        let high = v.filter { $0 > boundary }
        if let lowMax = low.max(), let highMin = high.min() {
            return 0.5 * (lowMax + highMin)
        }
        return centers[bestIndex]
    }

    /// mean + k×SD of the negative population.
    ///
    /// The negative population is everything at or below the Otsu split (or the
    /// median if Otsu can't split). Returns the threshold plus the mean and SD
    /// it was built from, so the UI can show its work.
    static func negativeSDThreshold(_ values: [Double], k: Double = 3.0)
        -> (threshold: Double, mean: Double, sd: Double, count: Int)? {
        let v = values.filter { $0.isFinite }
        guard !v.isEmpty else { return nil }

        let split = otsuThreshold(v) ?? median(v)
        var negative = v.filter { $0 <= split }
        if negative.count < 2 {
            negative = v.filter { $0 <= median(v) }
        }
        guard !negative.isEmpty else { return nil }

        let mean = negative.reduce(0, +) / Double(negative.count)
        var sd = 0.0
        if negative.count > 1 {
            let ss = negative.reduce(0) { $0 + ($1 - mean) * ($1 - mean) }
            sd = (ss / Double(negative.count - 1)).squareRoot()
        }
        return (threshold: mean + k * sd, mean: mean, sd: sd, count: negative.count)
    }

    /// Resolve one of the three modes into a concrete cut-off.
    static func resolveThreshold(_ values: [Double],
                                 mode: AssayThresholdMode,
                                 manual: Double,
                                 k: Double = 3.0)
        -> (threshold: Double, negativeMean: Double?, negativeSD: Double?)? {
        switch mode {
        case .manual:
            return (manual, nil, nil)
        case .otsu:
            guard let t = otsuThreshold(values) else { return nil }
            return (t, nil, nil)
        case .negativeSD:
            guard let r = negativeSDThreshold(values, k: k) else { return nil }
            return (r.threshold, r.mean, r.sd)
        }
    }

    // MARK: Assay 1 / 5 — positivity

    /// % of cells above the cut-off in one channel. Backs both
    /// `% marker-positive` and `transfection efficiency` — the readouts differ
    /// only in what the panel calls them.
    static func markerPositive(cells: [DetectedCell],
                               channel: AssayChannel,
                               metric: AssayMetric = .mean,
                               mode: AssayThresholdMode = .otsu,
                               manualThreshold: Double = 0,
                               k: Double = 3.0)
        -> Result<MarkerPositivityResult, AssayAvailability> {
        let pairs = values(in: cells, channel: channel.index, metric: metric)
        guard !pairs.isEmpty else { return .failure(.noChannelData) }

        let raw = pairs.map(\.value)
        guard let resolved = resolveThreshold(raw, mode: mode,
                                              manual: manualThreshold, k: k)
        else { return .failure(.thresholdUnresolved) }

        let threshold = resolved.threshold
        let flags = pairs.map {
            AssayCellFlag(id: $0.id, value: $0.value, isPositive: $0.value > threshold)
        }
        let positives = flags.filter(\.isPositive).map(\.value)
        let negatives = flags.filter { !$0.isPositive }.map(\.value)

        return .success(MarkerPositivityResult(
            channel: channel,
            metric: metric,
            mode: mode,
            threshold: threshold,
            negativeMean: resolved.negativeMean,
            negativeSD: resolved.negativeSD,
            k: mode == .negativeSD ? k : nil,
            cellCount: flags.count,
            positiveCount: positives.count,
            meanPositive: positives.isEmpty ? nil : positives.reduce(0, +) / Double(positives.count),
            meanNegative: negatives.isEmpty ? nil : negatives.reduce(0, +) / Double(negatives.count),
            flags: flags))
    }

    // MARK: Assay 4 — live / dead

    /// Two-channel viability.
    ///
    /// Classification, stated because conventions differ:
    /// * **dead** — positive in the dead channel, whatever the live channel
    ///   says. The membrane-impermeant dead stain only enters compromised
    ///   cells, so it outranks a residual live signal.
    /// * **live** — positive in the live channel and negative in the dead one.
    /// * **unlabelled** — negative in both; reported separately rather than
    ///   folded into either class.
    static func viability(cells: [DetectedCell],
                          liveChannel: AssayChannel,
                          deadChannel: AssayChannel,
                          metric: AssayMetric = .mean,
                          liveMode: AssayThresholdMode = .otsu,
                          deadMode: AssayThresholdMode = .otsu,
                          liveManual: Double = 0,
                          deadManual: Double = 0,
                          k: Double = 3.0)
        -> Result<ViabilityResult, AssayAvailability> {
        guard liveChannel.index != deadChannel.index else {
            return .failure(.duplicateChannels)
        }
        let livePairs = values(in: cells, channel: liveChannel.index, metric: metric)
        let deadPairs = values(in: cells, channel: deadChannel.index, metric: metric)
        guard !livePairs.isEmpty, !deadPairs.isEmpty else {
            return .failure(.noChannelData)
        }

        guard let liveResolved = resolveThreshold(livePairs.map(\.value),
                                                  mode: liveMode,
                                                  manual: liveManual, k: k),
              let deadResolved = resolveThreshold(deadPairs.map(\.value),
                                                  mode: deadMode,
                                                  manual: deadManual, k: k)
        else { return .failure(.thresholdUnresolved) }

        let deadByID = Dictionary(deadPairs.map { ($0.id, $0.value) },
                                  uniquingKeysWith: { a, _ in a })

        var states: [UUID: ViabilityResult.State] = [:]
        var live = 0, dead = 0, unlabelled = 0, doublePositive = 0
        for pair in livePairs {
            guard let deadValue = deadByID[pair.id] else { continue }
            let livePos = pair.value > liveResolved.threshold
            let deadPos = deadValue > deadResolved.threshold
            if livePos && deadPos { doublePositive += 1 }
            if deadPos {
                states[pair.id] = .dead
                dead += 1
            } else if livePos {
                states[pair.id] = .live
                live += 1
            } else {
                states[pair.id] = .unlabelled
                unlabelled += 1
            }
        }
        guard !states.isEmpty else { return .failure(.noChannelData) }

        return .success(ViabilityResult(
            liveChannel: liveChannel,
            deadChannel: deadChannel,
            liveThreshold: liveResolved.threshold,
            deadThreshold: deadResolved.threshold,
            metric: metric,
            cellCount: states.count,
            liveCount: live,
            deadCount: dead,
            unlabelledCount: unlabelled,
            doublePositiveCount: doublePositive,
            states: states))
    }

    // MARK: Assay 6 — cell cycle from DNA content

    /// Minimum population before phase gating means anything.
    static let cellCycleMinimumCells = 20

    /// G1 / S / G2-M **estimate** from per-cell integrated DNA intensity.
    ///
    /// Port of `_assays_intensity.cell_cycle`: histogram the integrated
    /// intensities up to the 99.5th percentile, smooth, take the tallest peak
    /// as G1 (2n), take the tallest peak in [1.6×G1, 2.4×G1] as G2/M (4n)
    /// (falling back to exactly 2×G1), then gate at ±`gateWidth` around each
    /// peak with S in between.
    ///
    /// This is a heuristic, not a model fit — see `CellCycleResult.caveat`.
    static func cellCycle(cells: [DetectedCell],
                          channel: AssayChannel,
                          bins: Int = 64,
                          gateWidth: Double = 0.15)
        -> Result<CellCycleResult, AssayAvailability> {
        let pairs = values(in: cells, channel: channel.index, metric: .integrated)
        guard !pairs.isEmpty else { return .failure(.noChannelData) }
        guard pairs.count >= cellCycleMinimumCells else {
            return .failure(.notEnoughCells(have: pairs.count,
                                            need: cellCycleMinimumCells))
        }

        let raw = pairs.map(\.value).filter { $0.isFinite }
        guard let lo = raw.min(), let maxV = raw.max(), maxV > 0 else {
            return .failure(.thresholdUnresolved)
        }
        var cap = percentile(raw, 99.5)
        if !(cap > lo) { cap = maxV }
        guard cap > lo else { return .failure(.thresholdUnresolved) }

        let n = max(8, bins)
        let width = (cap - lo) / Double(n)
        guard width > 0 else { return .failure(.thresholdUnresolved) }

        var counts = [Int](repeating: 0, count: n)
        for value in raw where value >= lo && value <= cap {
            var idx = Int((value - lo) / width)
            if idx >= n { idx = n - 1 }
            counts[idx] += 1
        }
        let centers = (0..<n).map { lo + (Double($0) + 0.5) * width }
        let smoothed = movingAverage(counts.map(Double.init), window: 3)

        // Peak picking: plateau-tolerant local maxima, then the tallest.
        var peaks: [Int] = []
        for i in 0..<n {
            let left = i > 0 ? smoothed[i - 1] : -Double.infinity
            let right = i < n - 1 ? smoothed[i + 1] : -Double.infinity
            guard smoothed[i] > 0, smoothed[i] >= left, smoothed[i] >= right
            else { continue }
            if let last = peaks.last, last == i - 1, smoothed[i] == smoothed[i - 1] {
                continue                      // collapse plateaus to their head
            }
            peaks.append(i)
        }
        guard let g1Index = peaks.max(by: { smoothed[$0] < smoothed[$1] }) else {
            return .failure(.thresholdUnresolved)
        }
        let g1 = centers[g1Index]
        guard g1 > 0 else { return .failure(.thresholdUnresolved) }

        let window = peaks.filter {
            $0 != g1Index && centers[$0] >= 1.6 * g1 && centers[$0] <= 2.4 * g1
        }
        let g2Index = window.max(by: { smoothed[$0] < smoothed[$1] })
        let g2 = g2Index.map { centers[$0] } ?? (2.0 * g1)

        let gw = max(0.01, gateWidth)
        var g1High = g1 * (1 + gw)
        var g2Low = g2 * (1 - gw)
        let g1Low = g1 * (1 - gw)
        let g2High = g2 * (1 + gw)
        if g2Low <= g1High {                  // overlapping gates — split the difference
            let mid = 0.5 * (g1High + g2Low)
            g1High = mid
            g2Low = mid
        }

        var phases: [UUID: CellCycleResult.Phase] = [:]
        var counted: [CellCycleResult.Phase: Int] = [:]
        for pair in pairs {
            let phase: CellCycleResult.Phase
            if pair.value < g1Low            { phase = .subG1 }
            else if pair.value <= g1High     { phase = .g1 }
            else if pair.value < g2Low       { phase = .s }
            else if pair.value <= g2High     { phase = .g2m }
            else                             { phase = .aboveG2M }
            phases[pair.id] = phase
            counted[phase, default: 0] += 1
        }

        return .success(CellCycleResult(
            channel: channel,
            cellCount: pairs.count,
            g1Peak: g1,
            g2Peak: g2,
            g2PeakFound: g2Index != nil,
            gateWidth: gw,
            counts: counted,
            phases: phases,
            histogram: counts,
            histogramRange: lo...cap))
    }

    // MARK: Assay 3 / 2 — pixel-level results read back from the sidecar

    /// Decode `assay_coloc_*` keys written by `intensity_assays.py`.
    /// Returns nil when the sidecar hasn't run for this image.
    static func colocalization(fromImageStats stats: [String: Double])
        -> ColocalizationResult? {
        guard let a = stats["assay_coloc_channel_a"],
              let b = stats["assay_coloc_channel_b"] else { return nil }
        let image = ColocalizationResult.Scope(
            // Renamed in `_assays_intensity.py` to make its caveat explicit: the
            // whole-image Pearson counts background zeros, which inflates it
            // badly (measured 0.93 where the true in-cell r was -0.01).
            pearson: stats["assay_coloc_pearson_image_incl_background"],
            mandersM1: stats["assay_coloc_m1_image"],
            mandersM2: stats["assay_coloc_m2_image"])
        let inCells = ColocalizationResult.Scope(
            pearson: stats["assay_coloc_pearson_in_cells"],
            mandersM1: stats["assay_coloc_m1_in_cells"],
            mandersM2: stats["assay_coloc_m2_in_cells"])
        guard !image.isEmpty || !inCells.isEmpty else { return nil }
        return ColocalizationResult(
            channelA: Int(a),
            channelB: Int(b),
            thresholdA: stats["assay_coloc_threshold_a"],
            thresholdB: stats["assay_coloc_threshold_b"],
            image: image,
            inCells: inCells,
            perCellMeanPearson: stats["assay_coloc_pearson_cells_mean"],
            perCellMedianPearson: stats["assay_coloc_pearson_cells_median"],
            perCellMeanM1: stats["assay_coloc_m1_cells_mean"],
            perCellMeanM2: stats["assay_coloc_m2_cells_mean"],
            perCellCount: stats["assay_coloc_n_cells"].map { Int($0) })
    }

    /// Decode `assay_nc_*` keys written by `intensity_assays.py`.
    static func nuclearCytoplasmic(fromImageStats stats: [String: Double])
        -> NuclearCytoplasmicResult? {
        guard let mean = stats["assay_nc_mean"],
              let median = stats["assay_nc_median"] else { return nil }
        return NuclearCytoplasmicResult(
            channel: Int(stats["assay_nc_channel"] ?? 0),
            cellCount: Int(stats["assay_nc_n_cells"] ?? 0),
            skippedCount: Int(stats["assay_nc_n_skipped"] ?? 0),
            meanRatio: mean,
            medianRatio: median,
            sdRatio: stats["assay_nc_sd"])
    }

    /// Correlation of the **per-cell** intensities of two channels.
    ///
    /// This is NOT pixel-level Pearson and must never be labelled as such: it
    /// asks whether cells bright in A tend to be bright in B, which is a
    /// population question, not a subcellular-overlap one. Offered because it
    /// is genuinely useful (and computable without the sidecar) — the panel
    /// labels it "cell-level correlation".
    static func cellLevelCorrelation(cells: [DetectedCell],
                                     channelA: Int,
                                     channelB: Int,
                                     metric: AssayMetric = .mean) -> Double? {
        guard channelA != channelB else { return nil }
        let aPairs = values(in: cells, channel: channelA, metric: metric)
        let bByID = Dictionary(values(in: cells, channel: channelB, metric: metric)
                                .map { ($0.id, $0.value) },
                               uniquingKeysWith: { a, _ in a })
        var xs: [Double] = []
        var ys: [Double] = []
        for pair in aPairs {
            guard let y = bByID[pair.id] else { continue }
            xs.append(pair.value)
            ys.append(y)
        }
        guard xs.count >= 2 else { return nil }

        let mx = xs.reduce(0, +) / Double(xs.count)
        let my = ys.reduce(0, +) / Double(ys.count)
        var num = 0.0, dx = 0.0, dy = 0.0
        for i in 0..<xs.count {
            let a = xs[i] - mx
            let b = ys[i] - my
            num += a * b
            dx += a * a
            dy += b * b
        }
        let denom = (dx * dy).squareRoot()
        guard denom > 0, denom.isFinite else { return nil }
        return num / denom
    }

    // MARK: Small statistics helpers

    static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        return sorted.count % 2 == 0
            ? 0.5 * (sorted[mid - 1] + sorted[mid])
            : sorted[mid]
    }

    /// Linear-interpolated percentile, matching numpy's default.
    static func percentile(_ values: [Double], _ p: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        if sorted.count == 1 { return sorted[0] }
        let rank = (p / 100.0) * Double(sorted.count - 1)
        let lower = Int(rank.rounded(.down))
        let upper = min(lower + 1, sorted.count - 1)
        let frac = rank - Double(lower)
        return sorted[lower] + frac * (sorted[upper] - sorted[lower])
    }

    static func movingAverage(_ values: [Double], window: Int) -> [Double] {
        var w = max(1, window)
        if w % 2 == 0 { w += 1 }
        guard w > 1, values.count >= w else { return values }
        let pad = w / 2
        var padded = [Double]()
        padded.reserveCapacity(values.count + 2 * pad)
        padded.append(contentsOf: Array(repeating: values.first ?? 0, count: pad))
        padded.append(contentsOf: values)
        padded.append(contentsOf: Array(repeating: values.last ?? 0, count: pad))
        var out = [Double]()
        out.reserveCapacity(values.count)
        for i in 0..<values.count {
            var sum = 0.0
            for j in 0..<w { sum += padded[i + j] }
            out.append(sum / Double(w))
        }
        return out
    }
}
