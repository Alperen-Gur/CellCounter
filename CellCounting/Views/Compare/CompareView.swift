import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: — Compare conditions (pass 6)

/// Pools all batches per condition, then shows side-by-side diameter histograms
/// + bin breakdowns + mean/σ so the user can eyeball treatment vs. control.
/// All panels share a Y-axis scale so bar heights are visually comparable
/// across panels (you can't compare two histograms with independent Y-axes).
struct CompareView: View {
    @Bindable var state: AppState

    @State private var conditions: [ConditionRecord] = []
    /// Names of conditions currently included in the comparison.
    @State private var selected: Set<String> = []
    @State private var exportError: String? = nil

    private let maxSelected = 4
    private let minSelected = 1

    var body: some View {
        VStack(spacing: 0) {
            // Purpose banner — always visible, regardless of selection state,
            // so the tab explains itself the instant it's opened (researcher
            // feedback #6: "I don't know what it does — maybe it doesn't
            // work for me"). Previously nothing in the UI ever stated what
            // Compare does; the closest was a code comment no user sees.
            CompareIntroStrip()
                .padding(.horizontal, 24).padding(.top, 14).padding(.bottom, 2)

            ChipRow(
                conditions: conditions,
                selected: $selected,
                maxSelected: maxSelected
            )
            .padding(.horizontal, 24).padding(.top, 10).padding(.bottom, 14)

            Rectangle().fill(Tokens.divider).frame(height: 0.5)

            if conditions.isEmpty {
                EmptyConditionsState(state: state)
            } else if selected.isEmpty {
                EmptySelectionState()
            } else {
                let activeConditions = conditions.filter { selected.contains($0.name) }

                // Statistical honesty note (researcher feedback #6). Shown any
                // time there's pooled condition data on screen — not only
                // when a p-value is — since the per-condition mean/σ panels
                // below pool cells the same way the Mann–Whitney test does.
                PseudoreplicationCaveat()
                    .padding(.horizontal, 24).padding(.top, 14)

                PanelsScroll(state: state, conditions: activeConditions)

                // Mann–Whitney U panel only makes sense for pairwise comparison.
                // Show it when exactly two conditions are selected; otherwise
                // explain why it's absent instead of silently omitting it
                // (finding: compare-stats-silently-missing — selecting 1, 3,
                // or 4 conditions previously made the whole statistics
                // section vanish with zero explanation, which reads as
                // "broken" rather than "not applicable").
                if activeConditions.count == 2 {
                    MannWhitneyPanel(state: state, conditions: activeConditions)
                        .padding(.horizontal, 24)
                        .padding(.bottom, 18)
                } else {
                    NotPairwiseHint(count: activeConditions.count)
                        .padding(.horizontal, 24)
                        .padding(.bottom, 18)
                }
            }

            Rectangle().fill(Tokens.divider).frame(height: 0.5)

            BottomBar(state: state,
                      conditions: conditions.filter { selected.contains($0.name) },
                      exportError: $exportError)
                .padding(.horizontal, 24).padding(.vertical, 12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Tokens.bg)
        .onAppear { refresh() }
        // ⌘E — Export comparison CSV
        .overlay(
            Button("") {
                let selectedConditions = conditions.filter { selected.contains($0.name) }
                guard !selectedConditions.isEmpty else { return }
                let panel = NSSavePanel()
                panel.allowedContentTypes = [.commaSeparatedText]
                panel.nameFieldStringValue = "compare-conditions.csv"
                panel.begin { resp in
                    guard resp == .OK, let url = panel.url else { return }
                    exportCSV(conditions: selectedConditions, to: url)
                }
            }
            .keyboardShortcut("e", modifiers: [.command])
            .hidden()
            .allowsHitTesting(false)
        )
    }

    private func exportCSV(conditions: [ConditionRecord], to url: URL) {
        // Surface success/failure consistently with the BottomBar export
        // (finding: compare-export-silent) — the advertised ⌘E previously wrote
        // with `try?` and reported neither outcome, so a failed comparison
        // export looked successful.
        let thresholds = state.thresholds
        let bins = BinMath.bins(from: thresholds)
        var lines = [["condition", "bin_label", "count", "percent", "total_cells", "batches"].joined(separator: ",")]
        for cond in conditions {
            let batches = state.repos.batches(matching: cond.name)
            var cells: [DetectedCell] = []
            for b in batches {
                for img in b.images {
                    let cutoff = state.effectiveConfidence(for: img)
                    cells.append(contentsOf: (img.detection?.cells ?? []).filter { $0.confidence >= cutoff })
                }
            }
            let total = cells.count
            for (i, bin) in bins.enumerated() {
                let c = cells.filter { BinMath.binIndex(for: $0.diameter, thresholds: thresholds) == i }.count
                let pct = total > 0 ? Double(c) / Double(total) * 100 : 0
                lines.append([cond.name, bin.label, "\(c)", String(format: "%.3f", pct), "\(total)", "\(batches.count)"].joined(separator: ","))
            }
        }
        do {
            try (lines.joined(separator: "\n") + "\n").data(using: .utf8)?.write(to: url, options: .atomic)
            exportError = nil
        } catch {
            exportError = "Export failed: \(error.localizedDescription)"
        }
    }

    private func refresh() {
        conditions = state.repos.conditions()
        // Default selection: first two conditions if we have them.
        if selected.isEmpty {
            selected = Set(conditions.prefix(2).map(\.name))
        }
    }
}

// MARK: — Purpose banner

/// Always-visible, one-glance explanation of what Compare does — shown above
/// the chip row no matter what's selected. See the researcher feedback note
/// on `CompareView.body` for why this can't live only in the empty states:
/// Compare auto-selects up to two conditions on open (`refresh()` below), so
/// a first-time visitor usually never sees `EmptySelectionState` at all.
private struct CompareIntroStrip: View {
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Icon("compare", size: 13)
                .foregroundStyle(Tokens.textTertiary)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                Text("Compares cell-size distributions and counts between conditions.")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Tokens.textSecondary)
                Text("Cells are pooled per condition from every batch tagged with it. Select exactly two conditions below to also run a Mann–Whitney significance test between them.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Tokens.textTertiary)
            }
            Spacer(minLength: 0)
        }
    }
}

// MARK: — Chip row

private struct ChipRow: View {
    let conditions: [ConditionRecord]
    @Binding var selected: Set<String>
    let maxSelected: Int
    @State private var showMinHint = false
    @State private var showMaxHint = false

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(conditions, id: \.id) { cond in
                    let isOn = selected.contains(cond.name)
                    Button {
                        if isOn {
                            if selected.count <= 1 {
                                // Enforce minSelected — flash hint instead
                                withAnimation(Tokens.Motion.easeFast) { showMinHint = true }
                                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                                    withAnimation(Tokens.Motion.easeFast) { showMinHint = false }
                                }
                            } else {
                                selected.remove(cond.name)
                            }
                        } else if selected.count < maxSelected {
                            selected.insert(cond.name)
                        } else {
                            // At the cap, tapping another chip previously did
                            // nothing at all (finding:
                            // compare-max-chip-silent-noop) — a button that
                            // silently no-ops reads as broken. Flash a hint,
                            // mirroring the minSelected floor above.
                            withAnimation(Tokens.Motion.easeFast) { showMaxHint = true }
                            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                                withAnimation(Tokens.Motion.easeFast) { showMaxHint = false }
                            }
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Circle()
                                .fill(Color(hex: cond.color) ?? .gray)
                                .frame(width: 8, height: 8)
                            Text(cond.name)
                                .font(.system(size: 12, weight: isOn ? .semibold : .medium))
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(
                            RoundedRectangle(cornerRadius: Tokens.Radius.md, style: .continuous)
                                .fill(isOn ? (Color(hex: cond.color)?.opacity(0.18) ?? Tokens.bgElevated)
                                            : Tokens.bgSunken))
                        .overlay(
                            RoundedRectangle(cornerRadius: Tokens.Radius.md, style: .continuous)
                                .strokeBorder(isOn ? (Color(hex: cond.color) ?? Tokens.borderStrong)
                                                   : Tokens.border,
                                              lineWidth: isOn ? 1 : 0.5))
                        .foregroundStyle(Tokens.text)
                    }
                    .buttonStyle(.plain)
                }

                Spacer(minLength: 0)

                if showMinHint {
                    Text("Select at least one")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Tokens.danger)
                        .transition(.opacity)
                } else if showMaxHint {
                    Text("Up to \(maxSelected) at a time — deselect one first")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Tokens.danger)
                        .transition(.opacity)
                } else {
                    Text("Select 1–\(maxSelected) conditions")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Tokens.textTertiary)
                        .transition(.opacity)
                }
            }
        }
    }
}

// MARK: — Panels

/// Fully materialized data for one condition panel. Everything the panel
/// renders (pooled cell count, mean/σ, per-bin counts, histogram buckets) is
/// computed ONCE in a single pass so the panel's `body` never re-fetches from
/// SwiftData or re-scans cells (finding: compareview-pooled-recompute).
private struct PooledCondition: Identifiable {
    let id: String              // condition name — stable across renders
    let condition: ConditionRecord
    let batchCount: Int
    let cellCount: Int
    let mean: Double
    let sigma: Double
    let bins: [SizeBin]
    let binCounts: [Int]        // parallel to `bins`
    let buckets: [Int]          // histogram buckets (HistogramMath.bucketCount)
}

private struct PanelsScroll: View {
    @Bindable var state: AppState
    let conditions: [ConditionRecord]

    /// Materialized once per (conditions × thresholds) change instead of on
    /// every SwiftUI body pass. Recomputed via `.onAppear` / `.onChange`.
    @State private var pooled: [PooledCondition] = []
    @State private var sharedYMax: Int = 1

    var body: some View {
        ScrollView {
            HStack(alignment: .top, spacing: 16) {
                ForEach(pooled) { p in
                    ConditionPanel(data: p, sharedYMax: sharedYMax)
                        .frame(maxWidth: .infinity)
                }
            }
            .padding(.horizontal, 24).padding(.vertical, 18)
        }
        .onAppear { recompute() }
        // Recompute only when the set of conditions or the size thresholds
        // change — not on every hover / selection-independent invalidation.
        .onChange(of: conditions.map(\.name)) { _, _ in recompute() }
        .onChange(of: state.thresholds) { _, _ in recompute() }
        .onChange(of: state.confidence) { _, _ in recompute() }
    }

    /// Single-pass materialization: one SwiftData fetch + one cell scan per
    /// condition, computing pooled stats, per-bin counts, and histogram buckets
    /// together, plus the shared Y-axis max.
    private func recompute() {
        let thresholds = state.thresholds
        let bins = BinMath.bins(from: thresholds)
        var result: [PooledCondition] = []
        var yMax = 1
        for cond in conditions {
            let batches = state.repos.batches(matching: cond.name)
            var diameters: [Double] = []
            for b in batches {
                for img in b.images {
                    if let cells = img.detection?.cells {
                        // Same per-image confidence cutoff every other stat uses
                        // (finding: compare-ignores-confidence-cutoff).
                        let cutoff = state.effectiveConfidence(for: img)
                        diameters.reserveCapacity(diameters.count + cells.count)
                        for c in cells where c.confidence >= cutoff { diameters.append(c.diameter) }
                    }
                }
            }
            let n = diameters.count
            // Mean / σ.
            var mean = 0.0
            var sigma = 0.0
            if n > 0 {
                let dn = Double(n)
                mean = diameters.reduce(0, +) / dn
                let variance = diameters.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / dn
                sigma = sqrt(variance)
            }
            // Per-bin counts + histogram buckets in the same pass.
            var binCounts = Array(repeating: 0, count: bins.count)
            var buckets = Array(repeating: 0, count: HistogramMath.bucketCount)
            for d in diameters {
                let bi = BinMath.binIndex(for: d, thresholds: thresholds)
                if bi >= 0 && bi < binCounts.count { binCounts[bi] += 1 }
                let raw = (d - HistogramMath.histMin) / (HistogramMath.histMax - HistogramMath.histMin) * Double(HistogramMath.bucketCount)
                let hi = min(HistogramMath.bucketCount - 1, max(0, Int(raw)))
                buckets[hi] += 1
            }
            yMax = max(yMax, buckets.max() ?? 1)
            result.append(PooledCondition(id: cond.name,
                                          condition: cond,
                                          batchCount: batches.count,
                                          cellCount: n,
                                          mean: mean,
                                          sigma: sigma,
                                          bins: bins,
                                          binCounts: binCounts,
                                          buckets: buckets))
        }
        pooled = result
        sharedYMax = yMax
    }
}

private struct ConditionPanel: View {
    let data: PooledCondition
    let sharedYMax: Int

    private var color: Color { Color(hex: data.condition.color) ?? .gray }

    private func pct(_ k: Int) -> Double {
        guard data.cellCount > 0 else { return 0 }
        return Double(k) / Double(data.cellCount) * 100
    }

    var body: some View {
        let bins = data.bins
        let counts = data.binCounts
        VStack(alignment: .leading, spacing: 14) {
            // Header
            HStack(spacing: 8) {
                Circle().fill(color).frame(width: 10, height: 10)
                Text(data.condition.name)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Tokens.text)
                Spacer(minLength: 0)
            }

            if data.cellCount == 0 {
                // finding: compare-zero-data-looks-broken. A condition with
                // no tagged batches (or tagged batches with nothing detected
                // yet) used to fall straight through to "0 cells · 0
                // batches", "0.0 ± 0.0 µm", an all-empty histogram, and a
                // column of 0% bin bars — indistinguishable from a
                // crash/regression at a glance, and the most likely concrete
                // cause behind researcher feedback #6 ("maybe it doesn't
                // work for me"): Compare always opens with the auto-seeded
                // "Control" condition selected (see `refresh()` on
                // CompareView), but batches are only tagged with a condition
                // via the optional, skippable drag-and-drop import picker —
                // so a wall of zeros is what most users see the first time
                // they open this tab.
                NoDataHint(conditionName: data.condition.name)
            } else {
                // Pooled stats
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(data.cellCount) cells · \(data.batchCount) batch\(data.batchCount == 1 ? "" : "es")")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(Tokens.textSecondary)
                    Text(String(format: "%.1f ± %.1f µm", data.mean, data.sigma))
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(Tokens.textTertiary)
                }

                // Histogram (shared Y axis) — buckets precomputed.
                PooledHistogram(buckets: data.buckets, thresholds: bins.isEmpty ? [] : thresholdsFromBins,
                                color: color, sharedYMax: sharedYMax)

                // Bin breakdown
                VStack(spacing: 6) {
                    ForEach(Array(bins.enumerated()), id: \.element.id) { i, bin in
                        let c = i < counts.count ? counts[i] : 0
                        BinBar(label: bin.label, color: Tokens.binColor(i),
                               count: c, pct: pct(c))
                    }
                }

                // Mono trio
                HStack(spacing: 10) {
                    MonoStat(label: "% small",       value: pct(counts.first ?? 0))
                    MonoStat(label: "% intermediate", value: counts.count >= 3 ? pct(counts[1]) : 0)
                    MonoStat(label: "% large",       value: pct(counts.last ?? 0))
                }
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: Tokens.Radius.lg, style: .continuous)
                .fill(Tokens.bgElevated))
        .overlay(
            RoundedRectangle(cornerRadius: Tokens.Radius.lg, style: .continuous)
                .strokeBorder(Tokens.border, lineWidth: 0.5))
    }

    /// Reconstruct the threshold tick values for the histogram from the bin
    /// boundaries (the interior `min` values). Cheap and avoids re-plumbing the
    /// raw thresholds array through PooledCondition.
    private var thresholdsFromBins: [Double] {
        // bins are [<t0, t0–t1, …, >tn]; the interior boundaries are the
        // thresholds. Drop the first bin's min (0) and take each bin.max that
        // is finite.
        data.bins.dropLast().map(\.max)
    }
}

/// Shown inside a `ConditionPanel` when the condition has zero pooled cells.
/// Replaces a confusing wall of zeros with an explanation and a concrete next
/// step — batch → condition tagging only happens through the optional
/// drag-and-drop import picker today; there's no way to tag/retag an existing
/// batch's condition from the Batches tab (out of scope here — see the
/// REPORTED section of the audit for the Batches-view owner).
private struct NoDataHint: View {
    let conditionName: String
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("No cells tagged \"\(conditionName)\" yet.")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Tokens.textSecondary)
            Text("A batch only counts toward a condition when it's tagged with one at import time (drag files onto Home and choose a condition). Tag a batch with \"\(conditionName)\" to populate this panel.")
                .font(.system(size: 11.5))
                .foregroundStyle(Tokens.textTertiary)
        }
        .padding(.vertical, 2)
    }
}

// MARK: — Pooled histogram (mirrors DistributionPanel in ResultsView)

private struct PooledHistogram: View {
    /// Precomputed histogram buckets (from PanelsScroll.recompute) so this view
    /// never re-scans the pooled cells on a body pass.
    let buckets: [Int]
    let thresholds: [Double]
    let color: Color
    let sharedYMax: Int

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("DIAMETER")
                    .tracking(0.04 * 11)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Tokens.textSecondary)
                Spacer()
                Text("\(Int(HistogramMath.histMin)) – \(Int(HistogramMath.histMax)) µm")
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(Tokens.textTertiary)
            }
            .padding(.bottom, 4)

            HStack(alignment: .bottom, spacing: 2) {
                ForEach(0..<HistogramMath.bucketCount, id: \.self) { i in
                    let h = buckets[i]
                    let frac = sharedYMax > 0
                        ? max(CGFloat(h) / CGFloat(sharedYMax), h > 0 ? 2 / 70 : 0)
                        : 0
                    RoundedRectangle(cornerRadius: 2)
                        .fill(color.opacity(0.85))
                        .frame(maxWidth: .infinity)
                        .frame(height: 70 * frac)
                }
            }
            .frame(height: 70)
            .padding(.top, 4)

            // Threshold ticks
            ZStack(alignment: .topLeading) {
                Color.clear.frame(height: 12)
                ForEach(Array(thresholds.enumerated()), id: \.offset) { _, t in
                    let raw = (t - HistogramMath.histMin) / (HistogramMath.histMax - HistogramMath.histMin)
                    let pos = min(0.98, max(0.02, raw))
                    GeometryReader { geo in
                        Text("\(Int(t))")
                            .font(.system(size: 9.5, design: .monospaced))
                            .foregroundStyle(Tokens.textTertiary)
                            .position(x: geo.size.width * pos, y: 6)
                    }
                }
            }
            .clipped()
        }
    }
}

/// Histogram math kept in one place so we (a) share it between panels and (b)
/// match the buckets in `ResultsView.DistributionPanel`. Don't change without
/// also updating ResultsView's bucket count / range.
enum HistogramMath {
    static let bucketCount = 24
    static let histMin: Double = 8
    static let histMax: Double = 60

    static func buckets(for cells: [DetectedCell]) -> [Int] {
        var out = Array(repeating: 0, count: bucketCount)
        for c in cells {
            let raw = (c.diameter - histMin) / (histMax - histMin) * Double(bucketCount)
            let i = min(bucketCount - 1, max(0, Int(raw)))
            out[i] += 1
        }
        return out
    }
}

// MARK: — Bin bar / mono stat

private struct BinBar: View {
    let label: String
    let color: Color
    let count: Int
    let pct: Double

    var body: some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 3)
                .fill(color)
                .frame(width: 10, height: 10)
            Text(label)
                .font(.system(size: 11.5))
                .foregroundStyle(Tokens.textSecondary)
                .lineLimit(1)
            Spacer(minLength: 8)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Tokens.bgSunken)
                        .frame(height: 5)
                    RoundedRectangle(cornerRadius: 2)
                        .fill(color)
                        .frame(width: geo.size.width * CGFloat(pct / 100), height: 5)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 5)
            Text("\(count)")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Tokens.textTertiary)
                .frame(width: 36, alignment: .trailing)
        }
    }
}

private struct MonoStat: View {
    let label: String
    let value: Double
    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(String(format: "%.1f%%", value))
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .foregroundStyle(Tokens.text)
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .tracking(0.04 * 10)
                .foregroundStyle(Tokens.textTertiary)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Tokens.Radius.sm, style: .continuous)
                .fill(Tokens.bgSunken))
    }
}

// MARK: — Empty states

private struct EmptyConditionsState: View {
    @Bindable var state: AppState
    var body: some View {
        VStack(spacing: 10) {
            Icon("compare", size: 36)
                .foregroundStyle(Tokens.textQuaternary.opacity(0.7))
                .padding(.bottom, 2)
            Text("No conditions yet")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Tokens.textSecondary)
            Text("Conditions (e.g. \"Control\", \"Drug A\") group your batches so Compare can pool and contrast their cell sizes.")
                .font(.system(size: 12))
                .foregroundStyle(Tokens.textTertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 340)
            Text("Create conditions in Settings → Conditions, then tag your batches when importing.")
                .font(.system(size: 12))
                .foregroundStyle(Tokens.textTertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 340)
            Button("Open Settings") { state.view = .settings }
                .appButton(.primary, size: .sm)
                .padding(.top, 4)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct EmptySelectionState: View {
    var body: some View {
        VStack(spacing: 8) {
            Icon("compare", size: 36)
                .foregroundStyle(Tokens.textQuaternary.opacity(0.7))
                .padding(.bottom, 2)
            Text("Pick at least one condition")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Tokens.textSecondary)
            Text("Tap a chip above to add it to the comparison. Select two to also see a Mann–Whitney significance test between them.")
                .font(.system(size: 12))
                .foregroundStyle(Tokens.textTertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: — Bottom bar / CSV export

private struct BottomBar: View {
    @Bindable var state: AppState
    let conditions: [ConditionRecord]
    @Binding var exportError: String?

    var body: some View {
        HStack(spacing: 10) {
            if let err = exportError {
                Text(err)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Tokens.danger)
            } else {
                Text("CSV: one row per (condition × bin) with count and percentage.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Tokens.textTertiary)
            }
            Spacer(minLength: 0)
            Button {
                exportCSV()
            } label: {
                HStack(spacing: 6) {
                    Icon("download", size: 12)
                    Text("Export comparison CSV")
                }
            }
            .appButton(.primary, size: .sm)
            .disabled(conditions.isEmpty)
            .opacity(conditions.isEmpty ? 0.5 : 1)
        }
    }

    private func exportCSV() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "compare-conditions-\(timestamp()).csv"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            try writeCSV(to: url)
            exportError = nil
        } catch {
            exportError = "Export failed: \(error.localizedDescription)"
        }
    }

    private func writeCSV(to url: URL) throws {
        let thresholds = state.thresholds
        let bins = BinMath.bins(from: thresholds)
        var lines: [String] = []
        lines.append(["condition", "bin_label", "count", "percent", "total_cells", "batches"].joined(separator: ","))

        for cond in conditions {
            let batches = state.repos.batches(matching: cond.name)
            var cells: [DetectedCell] = []
            for b in batches {
                for img in b.images {
                    let cutoff = state.effectiveConfidence(for: img)
                    cells.append(contentsOf: (img.detection?.cells ?? []).filter { $0.confidence >= cutoff })
                }
            }
            let total = cells.count
            for (i, bin) in bins.enumerated() {
                let c = cells.filter { BinMath.binIndex(for: $0.diameter, thresholds: thresholds) == i }.count
                let pct = total > 0 ? Double(c) / Double(total) * 100 : 0
                let row: [String] = [
                    csvEscape(cond.name),
                    csvEscape(bin.label),
                    "\(c)",
                    String(format: "%.3f", pct),
                    "\(total)",
                    "\(batches.count)"
                ]
                lines.append(row.joined(separator: ","))
            }
        }

        let body = lines.joined(separator: "\n") + "\n"
        try body.data(using: .utf8)?.write(to: url, options: .atomic)
    }

    private func csvEscape(_ s: String) -> String {
        if s.contains(",") || s.contains("\"") || s.contains("\n") {
            return "\"\(s.replacingOccurrences(of: "\"", with: "\"\""))\""
        }
        return s
    }

    private func timestamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f.string(from: Date())
    }
}

// Color(hex:) is defined in Theme/OKLCH.swift

// MARK: — Comparison guidance / statistical caveat

/// Shown above the pooled per-condition panels whenever 1+ conditions are
/// selected — i.e. any time pooled numbers are on screen, not only when a
/// p-value is. Researcher feedback (#6) asked for a visible, honest caveat:
/// the Mann–Whitney test (and the mean/σ shown above it in each
/// `ConditionPanel`) pools every individual segmented cell as if it were an
/// independent replicate. The true unit of replication is the image / well /
/// patient, not the cell — pooling this way inflates n and produces
/// spuriously small p-values. This mirrors the longer disclosure already in
/// the repo's README.md ("Before you publish" section) — same limitation,
/// condensed for in-app display. This is a known, already-documented
/// limitation; the actual fix (aggregating to one value per replicate before
/// testing) is a statistics/workflow change out of scope for this pass.
private struct PseudoreplicationCaveat: View {
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Icon("info", size: 12)
                .foregroundStyle(Tokens.warning)
                .padding(.top, 1)
            Text("Statistical note: this pools individual cells as independent replicates, not images, wells, or patients. Aggregate to one value per replicate (e.g. median diameter per image) before drawing condition-level conclusions — treat the test below as descriptive, not confirmatory.")
                .font(.system(size: 11.5))
                .foregroundStyle(Tokens.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: Tokens.Radius.md, style: .continuous)
                .fill(Tokens.warning.opacity(0.10)))
        .overlay(
            RoundedRectangle(cornerRadius: Tokens.Radius.md, style: .continuous)
                .strokeBorder(Tokens.warning.opacity(0.28), lineWidth: 0.5))
    }
}

/// Shown in place of `MannWhitneyPanel` when the active selection isn't
/// exactly two conditions. Previously the whole statistics section just
/// disappeared with no explanation when 1, 3, or 4 conditions were selected
/// (finding: compare-stats-silently-missing) — indistinguishable from a bug.
private struct NotPairwiseHint: View {
    let count: Int

    private var message: String {
        count <= 1
            ? "Select a second condition above to run a Mann–Whitney significance test between them."
            : "The significance test compares exactly two conditions at a time. Narrow your selection to 2 to see it."
    }

    var body: some View {
        HStack(spacing: 8) {
            Icon("info", size: 12)
                .foregroundStyle(Tokens.textTertiary)
            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(Tokens.textTertiary)
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Tokens.Radius.lg, style: .continuous)
                .fill(Tokens.bgElevated))
        .overlay(
            RoundedRectangle(cornerRadius: Tokens.Radius.lg, style: .continuous)
                .strokeBorder(Tokens.border, lineWidth: 0.5))
    }
}

// MARK: — Mann–Whitney U panel (pairwise comparison)

/// Shown only when exactly two conditions are selected. Pools all cells per
/// condition and runs a two-tailed Mann–Whitney U test on diameters.
/// The actual stats math lives in `Services/Statistics.swift`.
private struct MannWhitneyPanel: View {
    @Bindable var state: AppState
    let conditions: [ConditionRecord]

    private struct Pooled {
        let condition: ConditionRecord
        let diameters: [Double]
    }

    /// Pooled diameters + Mann–Whitney result, materialized once per
    /// (conditions × thresholds) change instead of on every SwiftUI body pass.
    /// Mirrors PanelsScroll.recompute so the fetch/decode/scan/sort happens once
    /// per data change rather than per render / confidence-slider tick
    /// (findings: compare-groups-recompute-per-body, mannwhitney-repools-every-body-pass).
    @State private var groups: [Pooled] = []
    @State private var result: MannWhitneyResult? = nil

    /// Single-pass materialization: one SwiftData fetch + one cell scan per
    /// condition, applying the SAME per-image confidence cutoff every other stat
    /// in the app uses (finding: compare-ignores-confidence-cutoff), then runs
    /// the Mann–Whitney test on the pooled diameters.
    private func recompute() {
        var gs: [Pooled] = []
        for cond in conditions {
            let batches = state.repos.batches(matching: cond.name)
            var ds: [Double] = []
            for b in batches {
                for img in b.images {
                    if let cells = img.detection?.cells {
                        let cutoff = state.effectiveConfidence(for: img)
                        ds.reserveCapacity(ds.count + cells.count)
                        for c in cells where c.confidence >= cutoff { ds.append(c.diameter) }
                    }
                }
            }
            gs.append(Pooled(condition: cond, diameters: ds))
        }
        groups = gs
        if gs.count == 2, gs[0].diameters.count >= 3, gs[1].diameters.count >= 3 {
            result = Statistics.mannWhitneyU(gs[0].diameters, gs[1].diameters)
        } else {
            result = nil
        }
    }

    var body: some View {
        let gs = groups
        // Need both groups to have at least 3 cells to compute meaningful stats.
        let enoughData = gs.count == 2 && gs[0].diameters.count >= 3 && gs[1].diameters.count >= 3

        VStack(alignment: .leading, spacing: 12) {
            // Section header
            HStack(spacing: 6) {
                Text("COMPARISON")
                    .tracking(0.05 * 11)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Tokens.textSecondary)
                Spacer(minLength: 0)
                Text("Mann–Whitney U test")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Tokens.textTertiary)
            }

            if !enoughData {
                Text("Not enough data for statistical comparison")
                    .font(.system(size: 12))
                    .foregroundStyle(Tokens.textTertiary)
                    .padding(.vertical, 8)
            } else if let r = result {
                StatsBody(a: gs[0], b: gs[1], result: r)
            } else {
                Text("Not enough data for statistical comparison")
                    .font(.system(size: 12))
                    .foregroundStyle(Tokens.textTertiary)
                    .padding(.vertical, 8)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Tokens.Radius.lg, style: .continuous)
                .fill(Tokens.bgElevated))
        .overlay(
            RoundedRectangle(cornerRadius: Tokens.Radius.lg, style: .continuous)
                .strokeBorder(Tokens.border, lineWidth: 0.5))
        .onAppear { recompute() }
        // Recompute only when the compared conditions, size thresholds, or the
        // confidence cutoff change — not on every hover / unrelated invalidation.
        .onChange(of: conditions.map(\.name)) { _, _ in recompute() }
        .onChange(of: state.thresholds) { _, _ in recompute() }
        .onChange(of: state.confidence) { _, _ in recompute() }
    }

    private struct StatsBody: View {
        let a: Pooled
        let b: Pooled
        let result: MannWhitneyResult

        private var isSignificant: Bool { result.pValue < 0.05 }
        private var sigColor: Color { isSignificant ? Tokens.success : Tokens.textTertiary }

        var body: some View {
            VStack(alignment: .leading, spacing: 10) {
                // Per-group rows
                groupRow(label: "Batch A", name: a.condition.name,
                         color: Color(hex: a.condition.color) ?? .gray,
                         n: result.n1, median: result.median1)
                groupRow(label: "Batch B", name: b.condition.name,
                         color: Color(hex: b.condition.color) ?? .gray,
                         n: result.n2, median: result.median2)

                HStack {
                    Text("Median difference")
                        .font(.system(size: 12))
                        .foregroundStyle(Tokens.textSecondary)
                    Spacer(minLength: 0)
                    Text(String(format: "%+.1f µm", result.medianDifference))
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Tokens.text)
                }

                Rectangle().fill(Tokens.divider).frame(height: 0.5).padding(.vertical, 2)

                // Stat triplet: U, z, p (with significance dot)
                HStack(alignment: .firstTextBaseline, spacing: 18) {
                    statCell(label: "U", value: String(format: "%.0f", result.u))
                    statCell(label: "z", value: String(format: "%.2f", result.z))
                    HStack(spacing: 6) {
                        Circle()
                            .fill(sigColor)
                            .frame(width: 7, height: 7)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(result.significanceLabel)
                                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                                .foregroundStyle(Tokens.text)
                            Text("two-tailed")
                                .font(.system(size: 10))
                                .foregroundStyle(Tokens.textTertiary)
                        }
                    }
                    Spacer(minLength: 0)
                }

                HStack(spacing: 6) {
                    Text(String(format: "Effect size r = %+.2f", result.rankBiserial))
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(Tokens.textSecondary)
                    Text("(\(result.effectSizeLabel))")
                        .font(.system(size: 12))
                        .foregroundStyle(Tokens.textTertiary)
                    Spacer(minLength: 0)
                }
            }
        }

        @ViewBuilder
        private func groupRow(label: String, name: String, color: Color,
                              n: Int, median: Double) -> some View {
            HStack(spacing: 8) {
                Text(label)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Tokens.textTertiary)
                    .frame(width: 54, alignment: .leading)
                Circle().fill(color).frame(width: 8, height: 8)
                Text(name)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Tokens.text)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(String(format: "n = %d cells", n))
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Tokens.textSecondary)
                Text(String(format: "median %.1f µm", median))
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Tokens.textSecondary)
                    .frame(minWidth: 130, alignment: .trailing)
            }
        }

        @ViewBuilder
        private func statCell(label: String, value: String) -> some View {
            VStack(alignment: .leading, spacing: 1) {
                Text(value)
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Tokens.text)
                Text(label)
                    .font(.system(size: 10, weight: .medium))
                    .tracking(0.04 * 10)
                    .foregroundStyle(Tokens.textTertiary)
            }
        }
    }
}

#if DEBUG
#Preview("Mann–Whitney self-test") {
    let ok = Statistics._selfTest()
    return Text(ok ? "Statistics self-test: PASS" : "Statistics self-test: FAIL")
        .font(.system(.body, design: .monospaced))
        .padding()
}
#endif
