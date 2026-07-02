import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: — Row model (built from real `ImageRecord`s)

private struct BatchMockRow {
    let name: String
    let status: BatchRowStatus
    let count: Int?
    let meanDiameter: Double?
    let distNorm: [Double]?
    let seed: Int
}

private func buildRealRows(for batch: BatchRecord, thresholds: [Double]) -> [BatchMockRow] {
    batch.images
        .sorted(by: { $0.importedAt < $1.importedAt })
        .enumerated()
        .map { i, img in
            let cells = img.detection?.cells ?? []
            let done = img.detection != nil
            let count = done ? cells.count : nil
            let meanDiam: Double? = {
                guard done, !cells.isEmpty else { return nil }
                return cells.reduce(0) { $0 + $1.diameter } / Double(cells.count)
            }()
            let distNorm: [Double]? = {
                guard done, !cells.isEmpty else { return nil }
                var bins = Array(repeating: 0.0, count: max(thresholds.count + 1, 5))
                for c in cells {
                    let idx = min(BinMath.binIndex(for: c.diameter, thresholds: thresholds), bins.count - 1)
                    bins[idx] += 1
                }
                while bins.count < 5 { bins.append(0) }
                let m = bins.prefix(5).max() ?? 1
                return Array(bins.prefix(5)).map { m > 0 ? $0 / m * 100 : 0 }
            }()
            return BatchMockRow(name: img.fileName,
                                status: done ? .done : .queued,
                                count: count,
                                meanDiameter: meanDiam,
                                distNorm: distNorm,
                                seed: i * 7 + 3)
        }
}

// MARK: — Main view

struct BatchView: View {
    @Bindable var state: AppState

    /// SwiftData relationship arrays (`batch.images`) are lazy and don't always
    /// propagate insert/delete to SwiftUI through the @Observable AppState
    /// boundary. Bumping this on `ccCorrectionsChanged`/`ccLibraryChanged`
    /// forces `rows` to recompute.
    @State private var refreshKey: Int = 0

    private var rows: [BatchMockRow] {
        _ = refreshKey // ensure read participates in body's dependency graph
        guard let batch = state.currentBatch else { return [] }
        return buildRealRows(for: batch, thresholds: batch.thresholds)
    }
    private var doneRows: [BatchMockRow] { rows.filter { $0.status == .done } }
    private var totalCells: Int { doneRows.compactMap(\.count).reduce(0, +) }
    private var meanCells: Int {
        let d = doneRows.count
        return d > 0 ? totalCells / d : 0
    }
    private var meanDiam: Double {
        let vals = doneRows.compactMap(\.meanDiameter)
        return vals.isEmpty ? 0 : vals.reduce(0, +) / Double(vals.count)
    }
    private var queueCount: Int { rows.filter { $0.status != .done }.count }

    private var sigmaCells: Double? {
        let counts = doneRows.compactMap(\.count).map { Double($0) }
        guard counts.count >= 2 else { return nil }
        let m = counts.reduce(0, +) / Double(counts.count)
        return sqrt(counts.reduce(0) { $0 + ($1 - m) * ($1 - m) } / Double(counts.count))
    }

    private var sigmaDiam: Double? {
        let vals = doneRows.compactMap(\.meanDiameter)
        guard vals.count >= 2 else { return nil }
        let m = vals.reduce(0, +) / Double(vals.count)
        return sqrt(vals.reduce(0) { $0 + ($1 - m) * ($1 - m) } / Double(vals.count))
    }

    var body: some View {
        if state.currentBatch == nil {
            EmptyStateView(
                title: "No batch open",
                subtitle: "Drop a folder of microscope images on the Home screen to create a batch.",
                symbol: "books.vertical"
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Tokens.bg)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    HeaderRow(state: state, queueCount: queueCount, totalImages: rows.count)
                        .padding(.bottom, 18)

                    StatsRow(
                        totalCells: totalCells,
                        meanCells: meanCells,
                        meanDiam: meanDiam,
                        doneCount: doneRows.count,
                        total: rows.count,
                        sigmaCells: sigmaCells,
                        sigmaDiam: sigmaDiam
                    )
                    .padding(.bottom, 20)

                    BatchTable(rows: rows, onTap: { state.view = .results })
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 24)
                .frame(maxWidth: 1100)
            }
            .frame(maxWidth: .infinity)
            // Delete — confirm-delete current batch
            .overlay(
                Group {
                    Button("") { deleteBatchShortcut() }
                        .keyboardShortcut(.delete, modifiers: [])
                        .hidden()
                        .allowsHitTesting(false)
                    Button("") { exportBatchShortcut() }
                        .keyboardShortcut("e", modifiers: [.command])
                        .hidden()
                        .allowsHitTesting(false)
                }
            )
            .onReceive(NotificationCenter.default.publisher(for: Notification.Name("ccCorrectionsChanged"))) { _ in
                refreshKey &+= 1
            }
            .onReceive(NotificationCenter.default.publisher(for: Notification.Name("ccLibraryChanged"))) { _ in
                refreshKey &+= 1
            }
        }
    }

    /// Keyboard shortcut wrappers — delegate to HeaderRow logic via AppState
    private func deleteBatchShortcut() {
        guard let batch = state.currentBatch else { return }
        let alert = NSAlert()
        alert.messageText = "Delete this batch?"
        alert.informativeText = "This removes all images and detections and cannot be undone."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            state.repos.deleteBatch(batch)
            state.currentBatchId = nil
            state.view = .home
            // Notify @Observable library stats to refresh.
            NotificationCenter.default.post(name: Notification.Name("ccLibraryChanged"), object: nil)
        }
    }

    @AppStorage("cc-export-csv-sep") private var csvSep: String = ","

    private func exportBatchShortcut() {
        guard let batch = state.currentBatch else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(batch.displayName)_summary.csv"
        if let utype = UTType(filenameExtension: "csv") { panel.allowedContentTypes = [utype] }
        panel.begin { resp in
            guard resp == .OK, let url = panel.url else { return }
            try? ExportService.writePerImageSummaryCSV(
                batch: batch,
                thresholds: batch.thresholds,
                pxPerUm: state.pxPerUm,
                separator: csvSep.isEmpty ? "," : csvSep,
                to: url
            )
        }
    }
}

// MARK: — Header

private struct HeaderRow: View {
    @Bindable var state: AppState
    let queueCount: Int
    let totalImages: Int
    @Environment(AppTheme.self) private var theme

    @AppStorage("cc-export-csv-sep") private var csvSeparator: String = ","

    @State private var exportFlash: String? = nil
    @State private var exportErrorFlash: String? = nil
    @State private var clearWorkItem: DispatchWorkItem? = nil

    private var subtitle: String {
        guard let batch = state.currentBatch else { return "" }
        let modelName = state.models.first(where: { $0.id == batch.modelId })?.name ?? batch.modelId
        let f = DateFormatter()
        f.dateFormat = "MMM d, HH:mm"
        let when = f.string(from: batch.createdAt)
        return "\(totalImages) image\(totalImages == 1 ? "" : "s") · started \(when) · \(modelName)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(state.currentBatch?.displayName ?? "Batch")
                        .font(.system(size: 22, weight: .bold))
                        .tracking(-0.02 * 22)
                        .foregroundStyle(Tokens.text)
                    Text(subtitle)
                        .font(.system(size: 13))
                        .foregroundStyle(Tokens.textTertiary)
                }
                Spacer()
                HStack(spacing: 8) {
                    if queueCount > 0 {
                        QueueBadge(count: queueCount)
                    }
                    Button {
                        exportBatch()
                    } label: {
                        HStack(spacing: 5) {
                            Icon("download", size: 12)
                            Text("Export batch")
                        }
                    }
                    .appButton(.standard, size: .sm)
                    .disabled(state.currentBatch == nil)

                    Button {
                        deleteBatch()
                    } label: {
                        Icon("trash", size: 13)
                    }
                    .appButton(.danger, size: .sm)
                    .frame(width: 28, height: 28)
                    .help("Delete this batch")
                }
            }

            if let flash = exportFlash {
                HStack(spacing: 6) {
                    Icon("check", size: 11).foregroundStyle(Tokens.success)
                    Text("Saved · \(flash)")
                        .font(.system(size: 11))
                        .foregroundStyle(Tokens.textSecondary)
                        .lineLimit(1).truncationMode(.middle)
                }
                .transition(.opacity)
            } else if let err = exportErrorFlash {
                HStack(spacing: 6) {
                    Icon("triangle-alert", size: 11).foregroundStyle(Tokens.danger)
                    Text(err)
                        .font(.system(size: 11))
                        .foregroundStyle(Tokens.textSecondary)
                        .lineLimit(2)
                }
                .transition(.opacity)
            }
        }
        .animation(Tokens.Motion.ease, value: exportFlash)
        .animation(Tokens.Motion.ease, value: exportErrorFlash)
    }

    // MARK: — Export

    private func exportBatch() {
        guard let batch = state.currentBatch else { return }
        let baseName = sanitize(batch.displayName)
        let defaultName = "\(baseName)_summary.csv"
        let panel = NSSavePanel()
        panel.nameFieldStringValue = defaultName
        if let utype = UTType(filenameExtension: "csv") { panel.allowedContentTypes = [utype] }
        panel.begin { resp in
            guard resp == .OK, let url = panel.url else { return }
            do {
                try ExportService.writePerImageSummaryCSV(
                    batch: batch,
                    thresholds: batch.thresholds,
                    pxPerUm: state.pxPerUm,
                    separator: csvSeparator.isEmpty ? "," : csvSeparator,
                    to: url
                )
                flashSaved(url.path)
            } catch {
                flashError(error.localizedDescription)
            }
        }
    }

    private func sanitize(_ name: String) -> String {
        let bad = CharacterSet(charactersIn: "/\\:*?\"<>|")
        return name.components(separatedBy: bad).joined(separator: "_")
    }

    private func flashSaved(_ path: String) {
        exportErrorFlash = nil
        exportFlash = prettyPath(path)
        scheduleClear()
    }

    private func flashError(_ message: String) {
        exportFlash = nil
        exportErrorFlash = message
        scheduleClear()
    }

    private func scheduleClear() {
        clearWorkItem?.cancel()
        let item = DispatchWorkItem {
            withAnimation(Tokens.Motion.ease) {
                exportFlash = nil
                exportErrorFlash = nil
            }
        }
        clearWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0, execute: item)
    }

    private func prettyPath(_ path: String) -> String {
        let home = NSHomeDirectory()
        if path.hasPrefix(home) { return "~" + String(path.dropFirst(home.count)) }
        return path
    }

    // MARK: — Delete

    private func deleteBatch() {
        guard let batch = state.currentBatch else { return }
        let alert = NSAlert()
        alert.messageText = "Delete this batch?"
        alert.informativeText = "This removes all images and detections and cannot be undone."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            state.repos.deleteBatch(batch)
            state.currentBatchId = nil
            state.view = .home
            // Notify @Observable library stats to refresh.
            NotificationCenter.default.post(name: Notification.Name("ccLibraryChanged"), object: nil)
        }
    }
}

private struct QueueBadge: View {
    let count: Int
    @Environment(AppTheme.self) private var theme

    var body: some View {
        HStack(spacing: 6) {
            AppSpinner()
            Text("\(count) in queue")
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(theme.accentColor)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 3)
        .background(Capsule().fill(theme.accentSoft))
    }
}

// MARK: — Stats row

private struct StatsRow: View {
    let totalCells: Int
    let meanCells: Int
    let meanDiam: Double
    let doneCount: Int
    let total: Int
    let sigmaCells: Double?
    let sigmaDiam: Double?

    var body: some View {
        HStack(spacing: 12) {
            StatCard(
                label: "Total Cells",
                value: totalCells.formatted(),
                sub: "across \(doneCount) of \(total) images"
            )
            StatCard(
                label: "Mean / Image",
                value: meanCells.formatted(),
                sub: sigmaCells.map { String(format: "σ = %.0f cells", $0) }
            )
            MeanDiamCard(meanDiam: meanDiam, sigmaDiam: sigmaDiam)
            DistributionCard()
        }
    }
}

private struct StatCard: View {
    let label: String
    let value: String
    var sub: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label.uppercased())
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.04 * 11)
                .foregroundStyle(Tokens.textTertiary)
            Text(value)
                .font(.system(size: 22, weight: .semibold, design: .monospaced))
                .tracking(-0.01 * 22)
                .foregroundStyle(Tokens.text)
                .padding(.top, 2)
            if let sub {
                Text(sub)
                    .font(.system(size: 11))
                    .foregroundStyle(Tokens.textTertiary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Tokens.Radius.lg, style: .continuous).fill(Tokens.bgElevated))
        .overlay(RoundedRectangle(cornerRadius: Tokens.Radius.lg, style: .continuous).strokeBorder(Tokens.border, lineWidth: 0.5))
    }
}

private struct MeanDiamCard: View {
    let meanDiam: Double
    let sigmaDiam: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Mean Diameter".uppercased())
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.04 * 11)
                .foregroundStyle(Tokens.textTertiary)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(String(format: "%.1f", meanDiam))
                    .font(.system(size: 22, weight: .semibold, design: .monospaced))
                    .tracking(-0.01 * 22)
                    .foregroundStyle(Tokens.text)
                Text("µm")
                    .font(.system(size: 13))
                    .foregroundStyle(Tokens.textTertiary)
            }
            .padding(.top, 2)
            if let sigma = sigmaDiam {
                Text(String(format: "σ = %.1f µm", sigma))
                    .font(.system(size: 11))
                    .foregroundStyle(Tokens.textTertiary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Tokens.Radius.lg, style: .continuous).fill(Tokens.bgElevated))
        .overlay(RoundedRectangle(cornerRadius: Tokens.Radius.lg, style: .continuous).strokeBorder(Tokens.border, lineWidth: 0.5))
    }
}

private struct DistributionCard: View {
    private let heights: [CGFloat] = [18, 34, 56, 42, 22]

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Distribution".uppercased())
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.04 * 11)
                .foregroundStyle(Tokens.textTertiary)
            HStack(alignment: .bottom, spacing: 3) {
                ForEach(0..<5, id: \.self) { i in
                    Tokens.binColor(i)
                        .frame(maxWidth: .infinity)
                        .frame(height: 32 * heights[i] / 100)
                        .clipShape(RoundedRectangle(cornerRadius: 2, style: .continuous))
                }
            }
            .frame(height: 32)
            .padding(.top, 4)
            Text("across all bins")
                .font(.system(size: 11))
                .foregroundStyle(Tokens.textTertiary)
                .padding(.top, 2)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Tokens.Radius.lg, style: .continuous).fill(Tokens.bgElevated))
        .overlay(RoundedRectangle(cornerRadius: Tokens.Radius.lg, style: .continuous).strokeBorder(Tokens.border, lineWidth: 0.5))
    }
}

// MARK: — Table

private struct BatchTable: View {
    let rows: [BatchMockRow]
    let onTap: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            TableHead()
            ForEach(Array(rows.enumerated()), id: \.offset) { i, row in
                TableRow(row: row, isFirst: i == 0, onTap: onTap)
            }
        }
        .background(RoundedRectangle(cornerRadius: Tokens.Radius.lg, style: .continuous).fill(Tokens.bgElevated))
        .overlay(RoundedRectangle(cornerRadius: Tokens.Radius.lg, style: .continuous).strokeBorder(Tokens.border, lineWidth: 0.5))
        .clipShape(RoundedRectangle(cornerRadius: Tokens.Radius.lg, style: .continuous))
    }
}

private struct TableHead: View {
    var body: some View {
        TableGrid {
            Color.clear.frame(width: 32, height: 1)
            Color.clear.frame(width: 56, height: 1)
            Text("File")
            Text("Status")
            Text("Count")
            Text("Bin Distribution")
            Text("Mean Ø")
            Color.clear.frame(width: 32, height: 1)
        }
        .font(.system(size: 11, weight: .semibold))
        .tracking(0.04 * 11)
        .foregroundStyle(Tokens.textTertiary)
        .textCase(.uppercase)
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(Tokens.bgSunken)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Tokens.border).frame(height: 0.5)
        }
    }
}

private struct TableRow: View {
    let row: BatchMockRow
    let isFirst: Bool
    let onTap: () -> Void
    @State private var hovered = false

    var body: some View {
        Button {
            if row.status == .done { onTap() }
        } label: {
            TableGrid {
                // Status dot
                HStack { StatusDot(status: row.status) }

                // Thumbnail
                ThumbDots(seed: row.seed)
                    .frame(width: 44, height: 44)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

                // Filename
                VStack(alignment: .leading, spacing: 1) {
                    Text(row.name)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Tokens.text)
                    Text(fileSubline(for: row.status))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Tokens.textTertiary)
                }

                // Status label
                statusLabel(for: row)

                // Count
                Text(row.count.map { $0.formatted() } ?? "—")
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Tokens.text)
                    .frame(maxWidth: .infinity, alignment: .trailing)

                // Bin distribution bars
                BinStack(distNorm: row.distNorm)

                // Mean diameter
                Text(row.meanDiameter.map { String(format: "%.1f µm", $0) } ?? "—")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Tokens.textSecondary)

                // Chevron
                if row.status == .done {
                    Icon("chevronr", size: 14)
                        .foregroundStyle(Tokens.textTertiary)
                } else {
                    Color.clear.frame(width: 32, height: 1)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(hovered && row.status == .done ? Tokens.hover : Color.clear)
            .overlay(alignment: .top) {
                if !isFirst {
                    Rectangle().fill(Tokens.divider).frame(height: 0.5)
                }
            }
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .animation(Tokens.Motion.easeFast, value: hovered)
    }

    @ViewBuilder
    private func statusLabel(for row: BatchMockRow) -> some View {
        switch row.status {
        case .done:
            Text("Completed")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Tokens.success)
        case .running:
            RunningLabel()
        case .queued:
            Text("Queued")
                .font(.system(size: 12))
                .foregroundStyle(Tokens.textTertiary)
        case .error:
            Text("Error")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Tokens.danger)
        }
    }

    private func fileSubline(for status: BatchRowStatus) -> String {
        switch status {
        case .done:    return "2048 × 2048 · 16 MB"
        case .running: return "2048 × 2048 · processing…"
        case .queued:  return "2048 × 2048 · queued"
        case .error:   return "2048 × 2048 · error"
        }
    }
}

private struct RunningLabel: View {
    @Environment(AppTheme.self) private var theme

    var body: some View {
        HStack(spacing: 6) {
            AppSpinner()
            Text("Analyzing 64%")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(theme.accentColor)
        }
    }
}

private struct BinStack: View {
    let distNorm: [Double]?

    var body: some View {
        if let norm = distNorm {
            HStack(alignment: .center, spacing: 3) {
                ForEach(0..<5, id: \.self) { i in
                    let w = max(4, norm[i] * 0.5)
                    Tokens.binColor(i)
                        .frame(width: w, height: 10)
                        .clipShape(RoundedRectangle(cornerRadius: 1, style: .continuous))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            Text("—")
                .font(.system(size: 11))
                .foregroundStyle(Tokens.textQuaternary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: — Grid layout helper

private struct TableGrid<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        BatchGridLayout {
            content
        }
    }
}

private struct BatchGridLayout: Layout {
    // Columns: 32 56 1.4fr 0.9fr 0.7fr 1.5fr 0.9fr 32  gap=10
    private static let fracs: [CGFloat] = [1.4, 0.9, 0.7, 1.5, 0.9]
    private static let totalFrac: CGFloat = fracs.reduce(0, +)

    func makeCache(subviews: Subviews) -> () { () }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let total = proposal.width ?? 800
        let (cols, _) = computeCols(totalWidth: total)
        let maxH = subviews.enumerated().map { i, sv in
            sv.sizeThatFits(ProposedViewSize(width: cols[min(i, cols.count-1)], height: nil)).height
        }.max() ?? 44
        return CGSize(width: total, height: maxH)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let (cols, _) = computeCols(totalWidth: bounds.width)
        var x = bounds.minX
        for (i, sv) in subviews.enumerated() {
            let w = cols[min(i, cols.count - 1)]
            let h = sv.sizeThatFits(ProposedViewSize(width: w, height: nil)).height
            sv.place(at: CGPoint(x: x, y: bounds.midY - h/2),
                     proposal: ProposedViewSize(width: w, height: h))
            x += w + 10
        }
    }

    private func computeCols(totalWidth: CGFloat) -> ([CGFloat], CGFloat) {
        let fixed: CGFloat = 32 + 56 + 32
        let gaps: CGFloat = 10 * 7
        let flex = max(0, totalWidth - fixed - gaps)
        let unit = flex / Self.totalFrac
        let cols: [CGFloat] = [32, 56, unit*1.4, unit*0.9, unit*0.7, unit*1.5, unit*0.9, 32]
        return (cols, unit)
    }
}
