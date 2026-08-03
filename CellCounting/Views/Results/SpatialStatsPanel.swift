import SwiftUI

// MOUNTED BY `ResultsView.swift`'s `AdditionalAssaysSection`:
//
//       SpatialStatsPanel(state: state, cells: cells, roiCount: roiCount)
//
//   The panel does NOT re-derive the cell list. It receives `ResultsSidebar`'s
//   already confidence- and ROI-filtered `cells` verbatim, so a hidden cell
//   can't skew the nearest-neighbour distribution, and the panel re-evaluates
//   whenever that array changes rather than depending on the untracked
//   `state.repos.rois(for:)` SwiftData fetch.
//
//   It draws its OWN leading `Divider()`, inside the same branch that decides
//   whether to render at all — a caller-supplied separator would still be
//   emitted when the panel hides itself and double up with its neighbour's.
//
// APPLICABILITY: renders `EmptyView` unless the current image has at least
// TWO visible detected cells — a nearest-neighbour distance and a
// Clark-Evans R are undefined below that — mirroring `MeasurementsPanel`/
// `ColoniesPanel`'s skip-when-there-is-nothing-to-show convention.
//
// Cheap enough to re-run freely: `spatial_stats.py` loads no pixel data at
// all, only the centroid list. Results live in local `@State`, are NOT
// persisted, and are tagged with an `AssayResultKey` (image id + cell count +
// confidence cutoff + ROI count) so a Clark-Evans R can never be read against
// a cell set it was not computed from. See `AssayResultKey` for the rationale.

/// Spatial-statistics results panel — nearest-neighbour distance, local
/// density, and the Clark-Evans clustering index. Runs `spatial_stats.py`
/// via `SpatialStatsRunner`.
struct SpatialStatsPanel: View {
    @Bindable var state: AppState
    /// `ResultsSidebar`'s already confidence- and ROI-filtered cells — see the
    /// header note.
    let cells: [DetectedCell]
    /// ROI count for the current image, part of the staleness fingerprint.
    let roiCount: Int

    @State private var params = SpatialStatsParams()
    @State private var settingsExpanded = false

    @State private var isRunning = false
    @State private var result: SpatialStatsResult? = nil
    /// Fingerprint of the inputs `result` was computed from — see the header
    /// note and `AssayResultKey`.
    @State private var resultKey: AssayResultKey? = nil
    @State private var errorMessage: String? = nil

    @Environment(AppTheme.self) private var theme

    // MARK: — Inputs

    /// Fingerprint of the cell set as it stands RIGHT NOW.
    private var currentKey: AssayResultKey {
        let image = state.currentImage
        return AssayResultKey(imageId: image?.id,
                              cellCount: cells.count,
                              cutoff: image.map { state.effectiveConfidence(for: $0) } ?? 0,
                              roiCount: roiCount)
    }

    /// Nil unless `result` was computed from exactly the cell set on screen
    /// right now — not merely from the same image.
    private var activeResult: SpatialStatsResult? {
        guard let resultKey, resultKey == currentKey else { return nil }
        return result
    }

    var body: some View {
        // Nearest-neighbour statistics need at least a pair of cells.
        if cells.count < 2 { return AnyView(EmptyView()) }
        return AnyView(content)
    }

    private var content: some View {
        VStack(spacing: 0) {
            // Drawn here, not by the caller — see the header note.
            Divider().overlay(Tokens.divider)

            panelBody
        }
        // Belt and braces alongside `AssayResultKey` — re-detect / split /
        // merge / delete all post this.
        .onReceive(NotificationCenter.default.publisher(for: .ccCorrectionsChanged)) { _ in
            result = nil
            resultKey = nil
        }
    }

    private var panelBody: some View {
        VStack(spacing: 0) {
            SectionHeader(title: "Spatial Statistics")

            settingsSection

            if let errorMessage {
                Text(errorMessage)
                    .font(.system(size: 11))
                    .foregroundStyle(Tokens.danger)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 10)
            }

            if let activeResult {
                Divider().overlay(Tokens.divider).padding(.vertical, 12)
                resultsSection(activeResult)
            } else {
                emptyState
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 18)
    }

    // MARK: — Run

    private func run() {
        guard let image = state.currentImage else {
            errorMessage = "Open an image first."
            return
        }
        errorMessage = nil
        result = nil
        resultKey = nil
        isRunning = true

        // Captured BEFORE the run so a cell edit that lands while the sidecar
        // is working invalidates the result instead of being stamped onto it.
        let startKey = currentKey
        // The REAL image dimensions, not a centroid bounding box: Clark-Evans
        // R is a function of the observed area, so letting the sidecar infer
        // the field would bias it (see SpatialStatsRunner.compute).
        let widthPx = image.widthPx
        let heightPx = image.heightPx
        // PIXELS PER MICROMETRE — forwarded to `--pxPerUm` verbatim. Never the
        // reciprocal `pixel_size_um`; see SpatialStatsRunner's header note.
        let pxPerUm = state.pxPerUm
        let cellsSnapshot = cells
        let paramsSnapshot = params

        Task { @MainActor in
            defer { isRunning = false }
            do {
                let r = try await SpatialStatsRunner.compute(cells: cellsSnapshot,
                                                             pxPerUm: pxPerUm,
                                                             widthPx: widthPx,
                                                             heightPx: heightPx,
                                                             params: paramsSnapshot)
                result = r
                resultKey = startKey
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    // MARK: — Settings

    private var settingsSection: some View {
        VStack(spacing: 0) {
            Button {
                withAnimation(Tokens.Motion.easeFast) { settingsExpanded.toggle() }
            } label: {
                HStack {
                    HStack(spacing: 6) {
                        Icon(settingsExpanded ? "chevron" : "chevronr", size: 11)
                            .foregroundStyle(Tokens.textTertiary)
                        Text("Density settings")
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundStyle(Tokens.text)
                    }
                    Spacer()
                    Text(String(format: "r = %.0f µm", params.radiusUm))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Tokens.textTertiary)
                }
            }
            .buttonStyle(.plain)

            if settingsExpanded {
                VStack(spacing: 10) {
                    VStack(spacing: 3) {
                        HStack {
                            Text("Local-density radius")
                                .font(.system(size: 11.5))
                                .foregroundStyle(Tokens.textSecondary)
                            Spacer()
                            Text(String(format: "%.0f µm", params.radiusUm))
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(Tokens.textTertiary)
                        }
                        Slider(value: $params.radiusUm, in: 5...500).tint(theme.accentColor)
                    }

                    HStack {
                        Text("Density heatmap")
                            .font(.system(size: 11.5))
                            .foregroundStyle(Tokens.textSecondary)
                        Spacer()
                        CustomToggle(isOn: $params.heatmap)
                    }

                    if params.heatmap {
                        VStack(spacing: 3) {
                            HStack {
                                Text("Heatmap bin size")
                                    .font(.system(size: 11.5))
                                    .foregroundStyle(Tokens.textSecondary)
                                Spacer()
                                Text(String(format: "%.0f µm", params.heatmapBinUm))
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(Tokens.textTertiary)
                            }
                            Slider(value: $params.heatmapBinUm, in: 2...200).tint(theme.accentColor)
                        }
                    }

                    Text("\(cells.count) cell centroid(s) from the current image.")
                        .font(.system(size: 10))
                        .foregroundStyle(Tokens.textQuaternary)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    Button {
                        run()
                    } label: {
                        HStack(spacing: 6) {
                            if isRunning {
                                AppSpinner()
                            } else {
                                Image(systemName: "point.3.connected.trianglepath.dotted")
                                    .font(.system(size: 11))
                            }
                            Text(isRunning ? "Computing…"
                                           : (activeResult == nil ? "Compute spatial stats" : "Recompute"))
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .appButton(.primary, size: .sm)
                    .disabled(isRunning)
                }
                .padding(.top, 10)
            }
        }
    }

    // MARK: — Empty state

    private var emptyState: some View {
        RoundedRectangle(cornerRadius: Tokens.Radius.sm)
            .fill(Tokens.bgSunken)
            .frame(height: 64)
            .overlay(
                Text(isRunning ? "Computing spatial statistics…" : "No spatial statistics computed yet")
                    .font(.system(size: 11))
                    .foregroundStyle(Tokens.textTertiary)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Tokens.Radius.sm)
                    .strokeBorder(Tokens.border, lineWidth: 0.5)
            )
            .padding(.top, 12)
    }

    // MARK: — Results

    @ViewBuilder
    private func resultsSection(_ result: SpatialStatsResult) -> some View {
        if result.nCells < 2 {
            Text(result.message ?? "Not enough cells to compute spatial statistics.")
                .font(.system(size: 11.5))
                .foregroundStyle(Tokens.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            VStack(spacing: 10) {
                clarkEvansCard(result)

                VStack(spacing: 4) {
                    SpatialStatRow(label: "Cells analyzed", value: "\(result.nCells)", unit: "")
                    SpatialStatRow(label: "Mean NND", value: fmt(result.meanNndUm), unit: "µm")
                    SpatialStatRow(label: "Median NND", value: fmt(result.medianNndUm), unit: "µm")
                    SpatialStatRow(label: "Min NND", value: fmt(result.minNndUm), unit: "µm")
                    SpatialStatRow(label: "Max NND", value: fmt(result.maxNndUm), unit: "µm")
                    SpatialStatRow(label: "Mean local density",
                                   value: result.meanLocalDensity.map { String(format: "%.1f", $0) } ?? "—",
                                   unit: "cells / \(Int(result.densityRadiusUm))µm")
                }
            }

            if let heatmap = result.heatmap {
                Divider().overlay(Tokens.divider).padding(.vertical, 10)
                heatmapView(heatmap)
            }

            if !result.perCell.isEmpty {
                Divider().overlay(Tokens.divider).padding(.vertical, 10)
                perCellTable(result.perCell)
            }
        }
    }

    private func clarkEvansCard(_ result: SpatialStatsResult) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                if let cls = result.clarkEvansClass {
                    Circle()
                        .fill(Tokens.binColor(cls.tokenBinIndex))
                        .frame(width: 8, height: 8)
                    Text(cls.label)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(Tokens.text)
                }
                Spacer()
                if let r = result.clarkEvansR {
                    Text("R = " + String(format: "%.2f", r))
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(Tokens.textSecondary)
                }
            }
            if let interpretation = result.clarkEvansInterpretation {
                Text(interpretation)
                    .font(.system(size: 10.5))
                    .foregroundStyle(Tokens.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: Tokens.Radius.sm)
                .fill(Tokens.bgSunken)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Tokens.Radius.sm)
                .strokeBorder(Tokens.border, lineWidth: 0.5)
        )
    }

    private func heatmapView(_ heatmap: SpatialHeatmap) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Density heatmap")
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(Tokens.textSecondary)
            Canvas { ctx, size in
                let rows = heatmap.grid.count
                guard rows > 0 else { return }
                let cols = heatmap.grid[0].count
                guard cols > 0 else { return }
                let cellW = size.width / CGFloat(cols)
                let cellH = size.height / CGFloat(rows)
                let maxCount = max(heatmap.maxCount, 1)
                for r in 0..<rows {
                    let row = heatmap.grid[r]
                    for c in 0..<cols where c < row.count {
                        let frac = row[c] / maxCount
                        guard frac > 0 else { continue }
                        let rect = CGRect(x: CGFloat(c) * cellW, y: CGFloat(r) * cellH,
                                          width: cellW, height: cellH)
                        ctx.fill(Path(rect), with: .color(theme.accentColor.opacity(0.10 + 0.80 * frac)))
                    }
                }
            }
            .frame(height: 140)
            .frame(maxWidth: .infinity)
            .background(Tokens.bgSunken)
            .cornerRadius(Tokens.Radius.sm)
            .overlay(
                RoundedRectangle(cornerRadius: Tokens.Radius.sm)
                    .strokeBorder(Tokens.border, lineWidth: 0.5)
            )
        }
    }

    private func perCellTable(_ rows: [SpatialCellStat]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Per-cell nearest-neighbour distance")
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(Tokens.textSecondary)
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(rows) { row in
                        HStack {
                            Text(row.label ?? "#\(row.index)")
                                .font(.system(size: 10.5, design: .monospaced))
                                .foregroundStyle(Tokens.textSecondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer()
                            Text(fmt(row.nnDistanceUm) + " µm")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(Tokens.text)
                            Text("· \(row.localDensity) nearby")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(Tokens.textTertiary)
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
            .frame(maxHeight: 160)
        }
    }

    private func fmt(_ v: Double?) -> String {
        v.map { String(format: "%.1f", $0) } ?? "—"
    }
}

/// Two-column key/value row — matches `MeasRow`/`ColonyRow`'s established
/// style (kept private + independently named so this file has no symbol
/// collision with either).
private struct SpatialStatRow: View {
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
