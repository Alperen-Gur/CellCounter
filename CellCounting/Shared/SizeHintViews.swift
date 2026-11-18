import SwiftUI

/// What the expected cell size means at a calibration: the size in pixels the
/// detector will use, an inline warning when that is outside the range the
/// model works well with, and one line on why it matters.
struct SizeHintDetails: View {
    let expectedDiameterUm: Double
    let thresholds: [Double]
    let pxPerUm: Double
    var behavior: SizeHint.Behavior = .cellposeRescale
    var showsWhy: Bool = true
    var fontSize: CGFloat = 11

    static let why = "Used to scale images for segmentation. Set it close to the typical diameter of your cells."

    private var resolved: SizeHint.Resolved {
        SizeHint.resolve(expectedDiameterUm: expectedDiameterUm, thresholds: thresholds,
                         pxPerUm: pxPerUm, behavior: behavior)
    }

    private var meaning: String {
        let r = resolved
        let scale = "\(SizeHint.format(pxPerUm, digits: 3)) px/µm"
        switch behavior {
        case .cellposeRescale, .omniposeRescale:
            if let px = r.diameterPx { return "≈ \(SizeHint.format(px, digits: 0)) px at \(scale)" }
            return r.diameterUm == nil
                ? "Automatic: images are segmented at their acquired scale."
                : "Enter a pixel scale to see the size in pixels."
        case .watershedSpacing:
            return r.diameterUm == nil
                ? "This model uses it only to space split points. Automatic keeps the default spacing."
                : "This model uses it only to space split points (at least half this size)."
        case .unused:
            return "This model does not use the expected cell size."
        case .mixed:
            return "Each ensemble member uses it its own way: Cellpose models rescale to it, "
                + "Omnipose only for a set value, StarDist and SAM ignore it."
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(meaning)
                .font(.system(size: fontSize + 0.5, weight: .medium).monospacedDigit())
                .foregroundStyle(Tokens.textSecondary)
            if let diameter = resolved.diameterUm,
               let warning = SizeHint.warning(diameterUm: diameter, pxPerUm: pxPerUm, behavior: behavior) {
                Label(warning.message, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: fontSize))
                    .foregroundStyle(Tokens.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if showsWhy, behavior == .cellposeRescale || behavior == .omniposeRescale {
                Text(Self.why)
                    .font(.system(size: fontSize))
                    .foregroundStyle(Tokens.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
