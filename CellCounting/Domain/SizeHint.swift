import Foundation
import CoreGraphics

/// The expected cell size ("size hint") a run passes to the segmentation
/// sidecars, resolved exactly as the sidecars resolve it.
///
/// Cellpose, Cellpose-SAM and Cellpose-based custom models
/// (`cellpose_detect.py`, `cellpose4_detect.py`, `custom_detect.py`):
/// an explicit `--diameter` in µm wins; otherwise the midpoint of the first and
/// last size-class thresholds is used. The value is multiplied by the run
/// calibration and clamped to at least 15 px:
/// `max(15.0, diameter_um * pxPerUm)`. Cellpose then rescales the image so a
/// cell of that size becomes its training size (about 30 px).
///
/// Omnipose (`omnipose_detect.py`) rescales only for an explicit value and does
/// not clamp; automatic means the image is segmented at its acquired scale.
/// The classical detector uses an explicit value only to widen watershed seed
/// spacing. StarDist and SAM-family detectors do not receive it.
///
/// `expectedDiameterUm == 0` is the stored meaning of "automatic" everywhere
/// (`cc-expected-diameter`, `AnalysisRunSettings`, protocols); this type never
/// changes that.
nonisolated enum SizeHint {
    /// Sidecar clamp: `max(15.0, diameter_um * pxPerUm)`.
    static let minimumDiameterPx = 15.0
    /// Cellpose's training cell size for its cell models; a cell of the hinted
    /// size is rescaled to this (the nuclei model uses 17 px).
    static let modelDiameterPx = 30.0
    /// Four times `modelDiameterPx`: above this a cell model scales the image
    /// to a quarter of its size or less, which loses small cells and fine
    /// boundaries. 25 µm at 8.33 px/µm (208 px) is well past it.
    static let heavyShrinkDiameterPx = 120.0
    /// Fallback thresholds the Swift side forwards when a run has none
    /// (`AnalysisRunSettings.detectionInput`).
    static let fallbackSmallThresholdUm = 20.0
    static let fallbackLargeThresholdUm = 30.0

    /// How a detector family uses the hint.
    enum Behavior: String, Codable, Sendable {
        /// Cellpose family: automatic = size-class midpoint, clamped to 15 px.
        case cellposeRescale
        /// Omnipose: explicit value rescales without a clamp; automatic = no rescaling.
        case omniposeRescale
        /// Classical: explicit value widens watershed seed spacing; automatic = default spacing.
        case watershedSpacing
        /// Not passed to the detector.
        case unused
        /// Ensemble: passed to both members, and each uses it its own way.
        case mixed
    }

    static func behavior(modelFamily: String, modelId: String) -> Behavior {
        if modelFamily == "Omnipose" || modelId.hasPrefix("omni-") { return .omniposeRescale }
        switch modelFamily {
        case "Classical": return .watershedSpacing
        case "StarDist", "SAM-family": return .unused
        case "Ensemble": return .mixed
        // Custom StarDist models run through `custom_detect.run_stardist`,
        // which never reads `--diameter`; custom Cellpose checkpoints use
        // the Cellpose rule.
        case "Custom": return customModelKind(modelId) == "stardist" ? .unused : .cellposeRescale
        default: return .cellposeRescale
        }
    }

    /// The registered kind of a bring-your-own model, read straight from the
    /// `CustomModelStore` defaults blob (`cc-custom-models`) so this stays
    /// usable off the main actor.
    private static func customModelKind(_ modelId: String) -> String? {
        guard let data = UserDefaults.standard.data(forKey: "cc-custom-models"),
              let entries = try? JSONDecoder().decode([CustomModelKindEntry].self, from: data) else { return nil }
        return entries.first { $0.id == modelId }?.kind
    }

    /// The two fields of a stored `CustomModelEntry` this needs.
    private struct CustomModelKindEntry: Decodable, Sendable {
        let id: String
        let kind: String
    }

    static func behavior(for settings: AnalysisRunSettings) -> Behavior {
        behavior(modelFamily: settings.modelFamily, modelId: settings.modelId)
    }

    /// `0` (or any non-positive / non-finite value) is automatic.
    static func isAutomatic(_ expectedDiameterUm: Double) -> Bool {
        !(expectedDiameterUm.isFinite && expectedDiameterUm > 0)
    }

    /// Midpoint of the first and last size-class thresholds, the value the
    /// sidecar uses when no explicit diameter is set.
    static func automaticDiameterUm(thresholds: [Double]) -> Double {
        ((thresholds.first ?? fallbackSmallThresholdUm) + (thresholds.last ?? fallbackLargeThresholdUm)) / 2
    }

    /// The diameter in µm the Cellpose sidecars use.
    static func effectiveDiameterUm(expectedDiameterUm: Double, thresholds: [Double]) -> Double {
        isAutomatic(expectedDiameterUm) ? automaticDiameterUm(thresholds: thresholds) : expectedDiameterUm
    }

    /// Diameter in pixels before the clamp.
    static func unclampedDiameterPx(diameterUm: Double, pxPerUm: Double) -> Double {
        diameterUm * pxPerUm
    }

    /// Diameter in pixels the Cellpose sidecars pass to `model.eval`.
    static func segmentationDiameterPx(diameterUm: Double, pxPerUm: Double) -> Double {
        max(minimumDiameterPx, unclampedDiameterPx(diameterUm: diameterUm, pxPerUm: pxPerUm))
    }

    /// Converts a length measured on the image to a diameter in µm, rounded to
    /// 0.1 µm. Nil for an unusable length or calibration.
    static func measuredDiameterUm(lengthPx: Double, pxPerUm: Double) -> Double? {
        guard lengthPx.isFinite, lengthPx > 1, pxPerUm.isFinite, pxPerUm > 0 else { return nil }
        let um = (lengthPx / pxPerUm * 10).rounded() / 10
        return um > 0 ? um : nil
    }

    enum Warning: Equatable, Sendable {
        /// The implied size is under the clamp; the sidecar uses 15 px instead.
        case belowMinimum(px: Double)
        /// The image would be scaled down heavily before segmentation.
        case heavyShrink(px: Double)

        var message: String {
            switch self {
            case .belowMinimum(let px):
                return "About \(SizeHint.format(px, digits: 0)) px is below the 15 px minimum. CellCounter uses 15 px, so cells this small may be missed. Check the calibration."
            case .heavyShrink(let px):
                return "About \(SizeHint.format(px, digits: 0)) px. Images will be scaled down heavily for segmentation, which can lose small cells. Check the calibration and the value."
            }
        }
    }

    /// Warning for the Cellpose family's rescaling. Other behaviors have no
    /// clamp or no rescale, so no warning applies.
    static func warning(diameterUm: Double, pxPerUm: Double,
                        behavior: Behavior = .cellposeRescale) -> Warning? {
        guard behavior == .cellposeRescale,
              diameterUm.isFinite, diameterUm > 0, pxPerUm.isFinite, pxPerUm > 0 else { return nil }
        let raw = unclampedDiameterPx(diameterUm: diameterUm, pxPerUm: pxPerUm)
        if raw < minimumDiameterPx { return .belowMinimum(px: raw) }
        if raw > heavyShrinkDiameterPx { return .heavyShrink(px: raw) }
        return nil
    }

    /// What a run used, in a form that is stable to export.
    struct Resolved: Codable, Equatable, Sendable {
        /// "automatic" or "explicit".
        var source: String
        var behavior: Behavior
        /// Diameter in µm the detector used; nil when it used none.
        var diameterUm: Double?
        /// Diameter in pixels the detector used (after the clamp where one applies).
        var diameterPx: Double?

        var isAutomatic: Bool { source == "automatic" }
    }

    static func resolve(expectedDiameterUm: Double, thresholds: [Double], pxPerUm: Double,
                        behavior: Behavior) -> Resolved {
        let automatic = isAutomatic(expectedDiameterUm)
        let source = automatic ? "automatic" : "explicit"
        let validScale = pxPerUm.isFinite && pxPerUm > 0
        switch behavior {
        case .cellposeRescale:
            let um = effectiveDiameterUm(expectedDiameterUm: expectedDiameterUm, thresholds: thresholds)
            return Resolved(source: source, behavior: behavior, diameterUm: um,
                            diameterPx: validScale ? segmentationDiameterPx(diameterUm: um, pxPerUm: pxPerUm) : nil)
        case .omniposeRescale, .watershedSpacing:
            guard !automatic else { return Resolved(source: source, behavior: behavior) }
            return Resolved(source: source, behavior: behavior, diameterUm: expectedDiameterUm,
                            diameterPx: validScale ? unclampedDiameterPx(diameterUm: expectedDiameterUm, pxPerUm: pxPerUm) : nil)
        case .unused:
            return Resolved(source: source, behavior: behavior)
        case .mixed:
            // Each member turns the value into pixels its own way, so no
            // single pixel size is recorded.
            return Resolved(source: source, behavior: behavior,
                            diameterUm: automatic ? nil : expectedDiameterUm)
        }
    }

    static func resolve(_ settings: AnalysisRunSettings) -> Resolved {
        resolve(expectedDiameterUm: settings.expectedDiameterUm, thresholds: settings.thresholds,
                pxPerUm: settings.pxPerUm, behavior: behavior(for: settings))
    }

    /// One-line description for results and reports, for example
    /// "Automatic · 25 µm · 65 px" or "12 µm · 31 px".
    static func summary(_ resolved: Resolved) -> String {
        var parts: [String] = []
        if resolved.isAutomatic { parts.append("Automatic") }
        if let um = resolved.diameterUm { parts.append("\(format(um)) µm") }
        if let px = resolved.diameterPx { parts.append("\(format(px, digits: 0)) px") }
        if resolved.diameterUm == nil {
            switch resolved.behavior {
            case .omniposeRescale: parts.append("no rescaling")
            case .watershedSpacing: parts.append("default seed spacing")
            case .unused: parts = ["Not used by this model"]
            case .cellposeRescale, .mixed: break
            }
        }
        if resolved.behavior == .mixed { parts.append("per ensemble member") }
        return parts.joined(separator: " · ")
    }

    /// Locale-independent compact number: at most `digits` decimals, no trailing zeros.
    static func format(_ value: Double, digits: Int = 1) -> String {
        guard value.isFinite else { return "—" }
        let scale = pow(10, Double(max(0, digits)))
        let rounded = (value * scale).rounded() / scale
        if let whole = Int(exactly: rounded) { return String(whole) }
        var text = String(format: "%.\(max(0, digits))f", rounded)
        while text.contains("."), text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text
    }
}

/// Length of a line drawn on an aspect-fitted image, in source-image pixels.
/// Shared by the scale-bar calibration line and the cell-size measurement.
nonisolated enum LineMeasurement {
    static func imagePixelLength(from a: CGPoint, to b: CGPoint,
                                 viewSize: CGSize, imageSize: CGSize) -> Double? {
        guard viewSize.width > 0, viewSize.height > 0,
              imageSize.width > 0, imageSize.height > 0 else { return nil }
        let fitScale = min(viewSize.width / imageSize.width, viewSize.height / imageSize.height)
        guard fitScale > 0 else { return nil }
        return Double(hypot(b.x - a.x, b.y - a.y) / fitScale)
    }
}
