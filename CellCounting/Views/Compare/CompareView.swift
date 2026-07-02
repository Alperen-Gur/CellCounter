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
            ChipRow(
                conditions: conditions,
                selected: $selected,
                maxSelected: maxSelected
            )
            .padding(.horizontal, 24).padding(.top, 18).padding(.bottom, 14)

            Rectangle().fill(Tokens.divider).frame(height: 0.5)

            if conditions.isEmpty {
                EmptyConditionsState(state: state)
            } else if selected.isEmpty {
                EmptySelectionState()
            } else {
                let activeConditions = conditions.filter { selected.contains($0.name) }
                PanelsScroll(state: state, conditions: activeConditions)

                // Mann–Whitney U panel only makes sense for pairwise comparison.
                // Show it when exactly two conditions are selected.
                if activeConditions.count == 2 {
                    MannWhitneyPanel(state: state, conditions: activeConditions)
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
        let thresholds = state.thresholds
        let bins = BinMath.bins(from: thresholds)
        var lines = [["condition", "bin_label", "count", "percent", "total_cells", "batches"].joined(separator: ",")]
        for cond in conditions {
            let batches = state.repos.batches(matching: cond.name)
            var cells: [DetectedCell] = []
            for b in batches { for img in b.images { cells.append(contentsOf: img.detection?.cells ?? []) } }
            let total = cells.count
            for (i, bin) in bins.enumerated() {
                let c = cells.filter { BinMath.binIndex(for: $0.diameter, thresholds: thresholds) == i }.count
                let pct = total > 0 ? Double(c) / Double(total) * 100 : 0
                lines.append([cond.name, bin.label, "\(c)", String(format: "%.3f", pct), "\(total)", "\(batches.count)"].joined(separator: ","))
            }
        }
        try? (lines.joined(separator: "\n") + "\n").data(using: .utf8)?.write(to: url, options: .atomic)
    }

    private func refresh() {
        conditions = state.repos.conditions()
        // Default selection: first two conditions if we have them.
        if selected.isEmpty {
            selected = Set(conditions.prefix(2).map(\.name))
        }
    }
}

// MARK: — Chip row

private struct ChipRow: View {
    let conditions: [ConditionRecord]
    @Binding var selected: Set<String>
    let maxSelected: Int
    @State private var showMinHint = false

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

private struct PanelsScroll: View {
    @Bindable var state: AppState
    let conditions: [ConditionRecord]

    /// Cells pooled by condition name. Computed once; passed to each panel.
    private var pooled: [(condition: ConditionRecord, batches: [BatchRecord], cells: [DetectedCell])] {
        conditions.map { cond in
            let batches = state.repos.batches(matching: cond.name)
            var cells: [DetectedCell] = []
            for b in batches {
                for img in b.images {
                    cells.append(contentsOf: img.detection?.cells ?? [])
                }
            }
            return (cond, batches, cells)
        }
    }

    /// Shared Y-axis maximum across all panels — critical for visual comparison.
    private var sharedYMax: Int {
        var m = 1
        for p in pooled {
            let h = HistogramMath.buckets(for: p.cells)
            m = max(m, h.max() ?? 1)
        }
        return m
    }

    var body: some View {
        ScrollView {
            HStack(alignment: .top, spacing: 16) {
                ForEach(Array(pooled.enumerated()), id: \.offset) { _, p in
                    ConditionPanel(
                        condition: p.condition,
                        batches: p.batches,
                        cells: p.cells,
                        thresholds: state.thresholds,
                        sharedYMax: sharedYMax)
                        .frame(maxWidth: .infinity)
                }
            }
            .padding(.horizontal, 24).padding(.vertical, 18)
        }
    }
}

private struct ConditionPanel: View {
    let condition: ConditionRecord
    let batches: [BatchRecord]
    let cells: [DetectedCell]
    let thresholds: [Double]
    let sharedYMax: Int

    private var color: Color { Color(hex: condition.color) ?? .gray }

    private var stats: (mean: Double, sigma: Double) {
        guard !cells.isEmpty else { return (0, 0) }
        let diams = cells.map(\.diameter)
        let n = Double(diams.count)
        let mean = diams.reduce(0, +) / n
        let variance = diams.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / n
        return (mean, sqrt(variance))
    }

    private var bins: [SizeBin] { BinMath.bins(from: thresholds) }

    private func countFor(binIdx i: Int) -> Int {
        cells.filter { BinMath.binIndex(for: $0.diameter, thresholds: thresholds) == i }.count
    }

    private func pct(_ k: Int) -> Double {
        guard !cells.isEmpty else { return 0 }
        return Double(k) / Double(cells.count) * 100
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Header
            HStack(spacing: 8) {
                Circle().fill(color).frame(width: 10, height: 10)
                Text(condition.name)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Tokens.text)
                Spacer(minLength: 0)
            }

            // Pooled stats
            VStack(alignment: .leading, spacing: 4) {
                Text("\(cells.count) cells · \(batches.count) batch\(batches.count == 1 ? "" : "es")")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Tokens.textSecondary)
                Text(String(format: "%.1f ± %.1f µm", stats.mean, stats.sigma))
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Tokens.textTertiary)
            }

            // Histogram (shared Y axis)
            PooledHistogram(cells: cells, thresholds: thresholds,
                            color: color, sharedYMax: sharedYMax)

            // Bin breakdown
            VStack(spacing: 6) {
                ForEach(Array(bins.enumerated()), id: \.element.id) { i, bin in
                    let c = countFor(binIdx: i)
                    BinBar(label: bin.label, color: Tokens.binColor(i),
                           count: c, pct: pct(c))
                }
            }

            // Mono trio
            HStack(spacing: 10) {
                MonoStat(label: "% small",       value: pct(countFor(binIdx: 0)))
                MonoStat(label: "% intermediate", value: bins.count >= 3 ? pct(countFor(binIdx: 1)) : 0)
                MonoStat(label: "% large",       value: pct(countFor(binIdx: bins.count - 1)))
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
}

// MARK: — Pooled histogram (mirrors DistributionPanel in ResultsView)

private struct PooledHistogram: View {
    let cells: [DetectedCell]
    let thresholds: [Double]
    let color: Color
    let sharedYMax: Int

    var body: some View {
        let buckets = HistogramMath.buckets(for: cells)
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
            Text("No conditions yet")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Tokens.textSecondary)
            Text("Create conditions in Settings → Conditions, then tag your batches when importing.")
                .font(.system(size: 12))
                .foregroundStyle(Tokens.textTertiary)
                .multilineTextAlignment(.center)
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
            Text("Pick at least one condition")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Tokens.textSecondary)
            Text("Tap a chip above to add it to the comparison.")
                .font(.system(size: 12))
                .foregroundStyle(Tokens.textTertiary)
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
                    cells.append(contentsOf: img.detection?.cells ?? [])
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

    private var groups: [Pooled] {
        conditions.map { cond in
            let batches = state.repos.batches(matching: cond.name)
            var ds: [Double] = []
            for b in batches {
                for img in b.images {
                    if let cells = img.detection?.cells {
                        ds.reserveCapacity(ds.count + cells.count)
                        for c in cells { ds.append(c.diameter) }
                    }
                }
            }
            return Pooled(condition: cond, diameters: ds)
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
            } else if let r = Statistics.mannWhitneyU(gs[0].diameters, gs[1].diameters) {
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
