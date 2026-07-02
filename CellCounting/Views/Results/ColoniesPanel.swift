import SwiftUI

// Splice instructions (C2 / pass 6):
//   `ColoniesPanel` is inserted in the Results sidebar (see `ResultsView.swift`,
//   `ResultsSidebar.body`) BETWEEN the existing `DistributionPanel` and the
//   `MeasurementsPanel`. Wrap with `Divider().overlay(Tokens.divider)` on each
//   side to match the other panels' separator pattern, e.g.:
//
//       DistributionPanel(cells: cells, thresholds: state.thresholds)
//       Divider().overlay(Tokens.divider)
//       ColoniesPanel(state: state)
//       Divider().overlay(Tokens.divider)
//       ThresholdsPanel(state: state)
//       ...
//       MeasurementsPanel(cells: cells)
//
// The panel reads `state.currentImage?.detection?.imageStats` (a flat
// `[String: Double]` namespace shared with C3's QC keys). When the current
// image has no colony stats (legacy detections / mock detector), the panel
// hides itself entirely — mirroring `MeasurementsPanel`'s skip-when-empty
// behaviour so the sidebar doesn't show stale zero values.

/// Stem-cell-enrichment readout. Surfaces the five C2 colony statistics:
/// confluency, n_colonies, mean colony size, largest colony size, largest
/// colony area, and mean nearest-neighbour distance. Keratinocyte stem cells
/// form holoclones — dense colonies of small round cells — so these numbers
/// quantify how stem-cell-enriched the current image is.
struct ColoniesPanel: View {
    @Bindable var state: AppState

    private var stats: [String: Double] {
        state.currentImage?.detection?.imageStats ?? [:]
    }

    /// The panel is meaningful only when at least one C2 key is populated.
    /// We probe `confluency_pct` because it's always emitted when colony stats
    /// ran successfully (even if no colonies were found, confluency is set).
    private var hasColonyData: Bool {
        stats["confluency_pct"] != nil
            || stats["n_colonies"] != nil
            || stats["mean_colony_size_cells"] != nil
    }

    var body: some View {
        // Skip entirely when no C2 data — same pattern as MeasurementsPanel.
        if !hasColonyData { return AnyView(EmptyView()) }

        let confluency  = stats["confluency_pct"] ?? 0
        let nColonies   = Int(stats["n_colonies"] ?? 0)
        let meanColony  = stats["mean_colony_size_cells"] ?? 0
        let largest     = Int(stats["largest_colony_size_cells"] ?? 0)
        let largestArea = stats["largest_colony_area_um2"] ?? 0
        let nnDistance  = stats["mean_nn_distance_um"] ?? 0

        return AnyView(
            VStack(spacing: 0) {
                SectionHeader(title: "Colonies")
                VStack(spacing: 4) {
                    ColonyRow(label: "Confluency",
                              value: String(format: "%.1f", confluency),
                              unit: "%")
                    ColonyRow(label: "Colonies (≥3 cells)",
                              value: "\(nColonies)",
                              unit: "")
                    ColonyRow(label: "Mean colony size",
                              value: meanColony > 0 ? String(format: "%.1f", meanColony) : "—",
                              unit: meanColony > 0 ? "cells" : "")
                    ColonyRow(label: "Largest colony",
                              value: largest > 0 ? "\(largest)" : "—",
                              unit: largest > 0 ? "cells" : "")
                    if largestArea > 0 {
                        ColonyRow(label: "Largest colony area",
                                  value: largestArea >= 10_000
                                    ? String(format: "%.2e", largestArea)
                                    : String(format: "%.0f", largestArea),
                                  unit: "µm²")
                    }
                    ColonyRow(label: "Mean nearest-neighbour",
                              value: nnDistance > 0 ? String(format: "%.1f", nnDistance) : "—",
                              unit: nnDistance > 0 ? "µm" : "")
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 18)
        )
    }
}

/// Two-column key/value row matching `MeasurementsPanel`'s `MeasRow` style.
/// Kept private so we don't collide with the existing `MeasRow` declared
/// inside `ResultsView.swift` (also private).
private struct ColonyRow: View {
    let label: String
    let value: String
    let unit: String

    var body: some View {
        HStack {
            Text(label)
                .font(.system(size: 12.5))
                .foregroundStyle(Tokens.textSecondary)
            Spacer()
            HStack(spacing: 3) {
                Text(value)
                    .font(.system(size: 12.5, design: .monospaced))
                    .foregroundStyle(Tokens.text)
                if !unit.isEmpty {
                    Text(unit)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Tokens.textTertiary)
                }
            }
        }
        .padding(.vertical, 4)
    }
}
