import SwiftUI

// Assays 2 + 3 — the two PIXEL-LEVEL readouts.
//
// Mounted by `IntensityAssaysPanel`. Unlike the other four assays, these two
// cannot be computed from `DetectedCell.channelIntensities`: Pearson's r and
// Manders' M1/M2 are defined over paired *pixel* values, and the N:C ratio
// needs the nucleus/cytoplasm split inside each mask. Per-cell means cannot
// stand in for either — a correlation of per-cell averages answers a different
// question and must not be labelled "Pearson".
//
// So this panel reads results back from the flat `image_stats` namespace that
// `CellCounting/python/intensity_assays.py` writes:
//
//     assay_coloc_pearson_image_incl_background / _in_cells / _cells_mean
//         / _cells_median   (the whole-image value is named for its caveat:
//         background zeros inflate it, so the in-cell value is the answer)
//     assay_coloc_m1_* / m2_*  + assay_coloc_threshold_a / _b
//     assay_nc_mean / _median / _sd / _n_cells / _n_skipped
//
// Those keys ride the existing `SidecarPayload.image_stats` →
// `DetectionRecord.imageStats` path, so no schema change was needed. Until the
// sidecar has run for an image, the panel says exactly that instead of showing
// a number it can't stand behind.

/// Colocalization (Pearson, Manders M1/M2) and the nuclear:cytoplasmic ratio.
struct ColocalizationPanel: View {
    let cells: [DetectedCell]
    let channels: [AssayChannel]
    let imageStats: [String: Double]

    /// Scope toggle for the colocalization figures.
    private enum Scope: String, CaseIterable, Hashable {
        case inCells, image, perCell

        var label: String {
            switch self {
            case .inCells: return "In cells"
            case .image:   return "Whole image"
            case .perCell: return "Per cell"
            }
        }
        var blurb: String {
            switch self {
            case .inCells:
                return "Pixels inside any cell mask — usually the figure you want."
            case .image:
                return "Every pixel, including background."
            case .perCell:
                return "Mean of the per-cell coefficients across all cells."
            }
        }
    }

    @State private var scope: Scope = .inCells

    private var coloc: ColocalizationResult? {
        IntensityAssays.colocalization(fromImageStats: imageStats)
    }

    private var nc: NuclearCytoplasmicResult? {
        IntensityAssays.nuclearCytoplasmic(fromImageStats: imageStats)
    }

    private func name(_ index: Int) -> String {
        channels.first { $0.index == index }?.displayName ?? "Channel \(index)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            nucleoCytoSection
            Divider().overlay(Tokens.divider)
            colocalizationSection
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
    }

    // MARK: Assay 2 — N:C ratio

    @ViewBuilder
    private var nucleoCytoSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            AssaySubsectionHeader(
                title: "Nuclear : cytoplasmic ratio",
                subtitle: IntensityAssayKind.nuclearCytoplasmic.subtitle)

            if let nc {
                VStack(spacing: 4) {
                    AssayHeadlineRow(value: String(format: "%.2f", nc.meanRatio),
                                     unit: "N:C",
                                     caption: "mean across \(nc.cellCount) cells")
                    AssayStatRow(label: "Mean N:C",
                                 value: String(format: "%.3f", nc.meanRatio),
                                 emphasized: true)
                    AssayStatRow(label: "Median N:C",
                                 value: String(format: "%.3f", nc.medianRatio))
                    if let sd = nc.sdRatio {
                        AssayStatRow(label: "SD", value: String(format: "%.3f", sd))
                    }
                    AssayStatRow(label: "Channel", value: name(nc.channel))
                    AssayStatRow(label: "Cells measured", value: "\(nc.cellCount)")
                    if nc.skippedCount > 0 {
                        AssayStatRow(label: "Skipped", value: "\(nc.skippedCount)",
                                     unit: "cells")
                    }
                    AssayCaption(
                        "Cytoplasm = cell mask minus nuclear mask. Cells without "
                        + "both a nucleus and a measurable cytoplasmic ring are "
                        + "skipped rather than reported as infinite.")
                }
            } else {
                AssayUnavailableNote(
                    "Needs the nucleus/cytoplasm split, which is a pixel-level "
                    + "operation. Run the intensity-assay step with a nuclear "
                    + "mask (or a DNA channel to threshold) for this image.")
            }
        }
    }

    // MARK: Assay 3 — colocalization

    @ViewBuilder
    private var colocalizationSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            AssaySubsectionHeader(
                title: "Colocalization",
                subtitle: IntensityAssayKind.colocalization.subtitle)

            if channels.count < 2 && coloc == nil {
                AssayUnavailableNote(
                    AssayAvailability.needsChannels(have: channels.count, need: 2).message)
            } else if let coloc {
                colocBody(coloc)
            } else {
                AssayUnavailableNote(AssayAvailability.needsSidecar.message)
                cellLevelFallback
            }
        }
    }

    @ViewBuilder
    private func colocBody(_ result: ColocalizationResult) -> some View {
        VStack(spacing: 4) {
            AssayStatRow(label: "Channel A", value: name(result.channelA))
            AssayStatRow(label: "Channel B", value: name(result.channelB))

            SegmentedPicker(value: $scope,
                            options: Scope.allCases.map { ($0, $0.label) })
                .padding(.vertical, 4)
            AssayCaption(scope.blurb)

            let values = coefficients(result, scope: scope)
            if values.pearson == nil && values.m1 == nil && values.m2 == nil {
                AssayUnavailableNote(
                    "The sidecar didn't emit coefficients for this scope. "
                    + "Re-run the intensity-assay step to populate it.")
            } else {
                AssayHeadlineRow(
                    value: values.pearson.map { String(format: "%.3f", $0) } ?? "—",
                    unit: "r",
                    caption: "Pearson correlation, \(scope.label.lowercased())")
                AssayStatRow(label: "Pearson r",
                             value: values.pearson.map { String(format: "%.4f", $0) } ?? "—",
                             emphasized: true)
                AssayStatRow(label: "Manders M1",
                             value: values.m1.map { String(format: "%.4f", $0) } ?? "—")
                AssayStatRow(label: "Manders M2",
                             value: values.m2.map { String(format: "%.4f", $0) } ?? "—")
            }

            if scope == .perCell, let n = result.perCellCount {
                AssayStatRow(label: "Cells", value: "\(n)")
                if let median = result.perCellMedianPearson {
                    AssayStatRow(label: "Median r",
                                 value: String(format: "%.4f", median))
                }
            }

            Divider().overlay(Tokens.divider).padding(.vertical, 4)

            AssayCaption(result.thresholdNote)
            AssayCaption(
                "M1 is the fraction of channel-A signal that sits on pixels "
                + "above the channel-B threshold; M2 is the mirror image. Both "
                + "are threshold-dependent — quote the thresholds above with "
                + "them. Pearson is threshold-free.")
        }
    }

    /// Pull the three coefficients for the selected scope.
    private func coefficients(_ result: ColocalizationResult, scope: Scope)
        -> (pearson: Double?, m1: Double?, m2: Double?) {
        switch scope {
        case .image:
            return (result.image.pearson, result.image.mandersM1, result.image.mandersM2)
        case .inCells:
            return (result.inCells.pearson, result.inCells.mandersM1, result.inCells.mandersM2)
        case .perCell:
            return (result.perCellMeanPearson, result.perCellMeanM1, result.perCellMeanM2)
        }
    }

    /// Shown while the sidecar hasn't run. This is a *population* statistic —
    /// do cells bright in A tend to be bright in B — and is labelled as such so
    /// it can never be mistaken for pixel-level Pearson.
    @ViewBuilder
    private var cellLevelFallback: some View {
        if channels.count >= 2 {
            let a = channels[0]
            let b = channels[1]
            if let r = IntensityAssays.cellLevelCorrelation(cells: cells,
                                                            channelA: a.index,
                                                            channelB: b.index) {
                VStack(spacing: 4) {
                    AssayStatRow(label: "Cell-level correlation",
                                 value: String(format: "%.4f", r))
                    AssayCaption(
                        "\(a.displayName) vs \(b.displayName), computed from the "
                        + "per-cell mean intensities already on hand. This asks "
                        + "whether cells bright in one channel tend to be bright "
                        + "in the other — it is NOT pixel-level Pearson and is "
                        + "not a substitute for it.")
                }
                .padding(.top, 6)
            }
        }
    }
}
