import Foundation
import CoreGraphics

/// One channel's intensity statistics over a single cell's mask.
///
/// Emitted by the Python sidecar as the `channel_intensities` array whenever
/// the source image had more than one channel (a fluorescence stack, an RGB
/// photo, a vendor `.czi`/`.nd2`/`.lif`/`.oir` acquisition…). The key is
/// omitted entirely for single-channel sources, so `DetectedCell
/// .channelIntensities` is nil for the ordinary grayscale case.
///
/// Wire shape, verbatim:
/// ```json
/// {"channel": 0, "name": "DAPI", "mean": 123.4,
///  "integrated": 45678.0, "median": 120.0}
/// ```
///
/// `mean` / `integrated` / `median` are in the **source file's raw units**, not
/// rescaled to 0–255 — per-channel quantification is meaningless after a
/// per-image renormalisation. `integrated` is `mean * areaPx`, matching the
/// definition of `DetectedCell.integratedDensity`.
struct ChannelIntensity: Codable, Hashable {
    /// Zero-based channel index, matching the order in the source file.
    let channel: Int
    /// Channel label from the vendor metadata ("DAPI", "GFP", "R"…). Falls
    /// back to "Ch<index>" when the file carries no name. Optional so legacy
    /// or hand-written payloads that omit it still decode.
    let name: String?
    /// Mean pixel value inside the cell mask, in source units.
    let mean: Double
    /// `mean * areaPx` — integrated density for this channel.
    let integrated: Double
    /// Median pixel value inside the mask. Optional: robust to sidecars that
    /// can't compute it.
    let median: Double?

    init(channel: Int, name: String? = nil, mean: Double,
         integrated: Double, median: Double? = nil) {
        self.channel = channel
        self.name = name
        self.mean = mean
        self.integrated = integrated
        self.median = median
    }

    /// Human-facing label — the vendor name when present, else "Ch<index>".
    var displayName: String {
        if let name, !name.isEmpty { return name }
        return "Ch\(channel)"
    }
}

/// A single detected cell in image space.
struct DetectedCell: Identifiable, Hashable {
    let id: UUID
    /// Center in source-image pixel coordinates.
    var cx: Double
    var cy: Double
    /// Diameter in micrometers.
    var diameter: Double
    /// Diameter in pixels (= diameter * scale.pxPerUm).
    var diameterPx: Double
    /// Detector confidence in [0, 1].
    var confidence: Double

    // MARK: — Per-cell measurements (optional; nil for legacy / mock cells)
    /// Mask area in µm².
    var areaMicrons2: Double?
    /// Mask perimeter in µm.
    var perimeterMicrons: Double?
    /// Circularity in [0, 1]: 1 = perfect circle.
    var circularity: Double?
    /// Eccentricity in [0, 1]: 0 = circle, 1 = line segment.
    var eccentricity: Double?
    /// Mean pixel intensity of the masked region (0–255 scale).
    var meanIntensity: Double?
    /// Integrated density = areaPx * meanIntensity.
    var integratedDensity: Double?

    // MARK: — Per-cell quality flags (pass 6 / C1)
    /// Centroid X in micrometers (cx / pxPerUm). Stored for convenience so export doesn't need calibration.
    var centroidUmX: Double?
    /// Centroid Y in micrometers (cy / pxPerUm).
    var centroidUmY: Double?
    /// Aspect ratio: major_axis_length / minor_axis_length (≥ 1.0; 1.0 = circle).
    var aspectRatio: Double?
    /// Solidity: mask area / convex hull area (in [0, 1]; 1.0 = convex).
    var solidity: Double?
    /// True if the cell centroid is within 16 px of any image border.
    var edgeTouching: Bool = false
    /// True if diameter_um > 80 µm (likely a clump of cells; threshold configurable).
    var likelyClump: Bool = false
    /// True if solidity < 0.7 AND diameter_um < 8 AND mean_intensity > 220
    /// (heuristic for debris fragments; all three conditions required).
    var likelyDebris: Bool = false
    /// Size class derived from configurable thresholds: "small" | "intermediate" | "large".
    var sizeClass: String = ""
    /// True when this marker was placed manually via the manual-count tool (not from a Python sidecar).
    var isManual: Bool = false

    /// Pass-14: per-cell polygon contour in image-pixel coords.
    /// Nil for legacy detections (renders via the bbox/circle path) and manual markers.
    var contourPx: [CGPoint]? = nil

    /// Per-channel intensity statistics over this cell's mask, one entry per
    /// channel in source order. Nil for single-channel images, legacy
    /// detections, and manual markers — `meanIntensity`/`integratedDensity`
    /// remain the single-plane values in every case.
    var channelIntensities: [ChannelIntensity]? = nil

    init(id: UUID = UUID(), cx: Double, cy: Double, diameter: Double, diameterPx: Double, confidence: Double = 1,
         areaMicrons2: Double? = nil, perimeterMicrons: Double? = nil, circularity: Double? = nil,
         eccentricity: Double? = nil, meanIntensity: Double? = nil, integratedDensity: Double? = nil,
         centroidUmX: Double? = nil, centroidUmY: Double? = nil,
         aspectRatio: Double? = nil, solidity: Double? = nil,
         edgeTouching: Bool = false, likelyClump: Bool = false, likelyDebris: Bool = false,
         sizeClass: String = "", isManual: Bool = false,
         contourPx: [CGPoint]? = nil,
         channelIntensities: [ChannelIntensity]? = nil) {
        self.id = id
        self.cx = cx
        self.cy = cy
        self.diameter = diameter
        self.diameterPx = diameterPx
        self.confidence = confidence
        self.areaMicrons2 = areaMicrons2
        self.perimeterMicrons = perimeterMicrons
        self.circularity = circularity
        self.eccentricity = eccentricity
        self.meanIntensity = meanIntensity
        self.integratedDensity = integratedDensity
        self.centroidUmX = centroidUmX
        self.centroidUmY = centroidUmY
        self.aspectRatio = aspectRatio
        self.solidity = solidity
        self.edgeTouching = edgeTouching
        self.likelyClump = likelyClump
        self.likelyDebris = likelyDebris
        self.sizeClass = sizeClass
        self.isManual = isManual
        self.contourPx = contourPx
        self.channelIntensities = channelIntensities
    }

    var boundingBox: CGRect {
        CGRect(x: cx - diameterPx/2, y: cy - diameterPx/2, width: diameterPx, height: diameterPx)
    }

    /// True when this cell carries usable multi-channel measurements.
    var hasChannelIntensities: Bool {
        (channelIntensities?.isEmpty == false)
    }

    /// Intensity entry for `index`, or nil when this cell has no per-channel
    /// data or the index is out of range. Matches on the stored `channel`
    /// value rather than array position so a filtered/reordered array is safe.
    func channelIntensity(_ index: Int) -> ChannelIntensity? {
        channelIntensities?.first { $0.channel == index }
    }
}
