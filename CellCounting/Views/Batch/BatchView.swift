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
    /// Raw per-bin counts (5 bins) for this image, or nil if undetected.
    /// Aggregated across the batch to drive the summary Distribution card.
    let distCounts: [Double]?
    let seed: Int
    /// Real per-image metadata for the thumbnail + subline (never fabricated).
    let imageId: UUID
    let thumbURL: URL
    let widthPx: Int
    let heightPx: Int
    /// On-disk size of our stored copy, in bytes. nil when the file can't be stat'd.
    let fileSizeBytes: Int64?
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
            let distCounts: [Double]? = {
                guard done, !cells.isEmpty else { return nil }
                var bins = Array(repeating: 0.0, count: max(thresholds.count + 1, 5))
                for c in cells {
                    let idx = min(BinMath.binIndex(for: c.diameter, thresholds: thresholds), bins.count - 1)
                    bins[idx] += 1
                }
                while bins.count < 5 { bins.append(0) }
                return Array(bins.prefix(5))
            }()
            let distNorm: [Double]? = distCounts.map { bins in
                let m = bins.max() ?? 1
                return bins.map { m > 0 ? $0 / m * 100 : 0 }
            }
            let fileSizeBytes: Int64? = (try? img.storedURL.resourceValues(forKeys: [.fileSizeKey]))
                .flatMap { $0.fileSize }
                .map(Int64.init)
            return BatchMockRow(name: img.fileName,
                                status: done ? .done : .queued,
                                count: count,
                                meanDiameter: meanDiam,
                                distNorm: distNorm,
                                distCounts: distCounts,
                                seed: i * 7 + 3,
                                imageId: img.id,
                                thumbURL: img.thumbURL,
                                widthPx: img.widthPx,
                                heightPx: img.heightPx,
                                fileSizeBytes: fileSizeBytes)
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

    /// Materialized once per change (batch switch / refreshKey bump) rather than
    /// on every SwiftUI body pass. `buildRealRows` is O(images × cells); the old
    /// computed `rows` re-ran it for every derived property (doneRows, totals,
    /// sigmas, …), rescanning the whole detection 5-7× per invalidation.
    @State private var rows: [BatchMockRow] = []

    private func recomputeRows() {
        guard let batch = state.currentBatch else { rows = []; return }
        rows = buildRealRows(for: batch, thresholds: batch.thresholds)
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

    /// Real per-bin cell totals summed across every detected image in the batch,
    /// using the same 5-bin `BinMath` split the per-row bars use. nil when no
    /// detected image has any cells, so the card can show a neutral placeholder.
    private var distTotals: [Double]? {
        let counts = doneRows.compactMap(\.distCounts)
        guard !counts.isEmpty else { return nil }
        var totals = Array(repeating: 0.0, count: 5)
        for c in counts {
            for i in 0..<min(5, c.count) { totals[i] += c[i] }
        }
        return totals.reduce(0, +) > 0 ? totals : nil
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
                        sigmaDiam: sigmaDiam,
                        distTotals: distTotals
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
            .overlay(alignment: .bottom) {
                if let toast = state.exportToast {
                    ExportFeedbackToast(message: toast.message, isError: toast.isError)
                        .padding(.bottom, 24)
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: Notification.Name("ccCorrectionsChanged"))) { _ in
                refreshKey &+= 1
                recomputeRows()
            }
            .onReceive(NotificationCenter.default.publisher(for: Notification.Name("ccLibraryChanged"))) { _ in
                refreshKey &+= 1
                recomputeRows()
            }
            .onAppear { recomputeRows() }
            .onChange(of: state.currentBatchId) { _, _ in recomputeRows() }
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
            do {
                try ExportService.writePerImageSummaryCSV(
                    batch: batch,
                    thresholds: batch.thresholds,
                    pxPerUm: state.pxPerUm,
                    separator: csvSep.isEmpty ? "," : csvSep,
                    to: url
                )
                state.flashExport("Saved \(url.lastPathComponent)", isError: false)
            } catch {
                state.flashExport("Export failed: \(error.localizedDescription)", isError: true)
            }
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
    let distTotals: [Double]?

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
            DistributionCard(totals: distTotals)
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
    /// Real per-bin cell totals across the batch (5 bins), or nil when nothing
    /// has been detected yet — in which case we show a neutral placeholder
    /// rather than a fabricated shape.
    let totals: [Double]?

    /// Bar heights (0–32pt) normalised to the largest bin so the tallest bar
    /// always fills the card.
    private var heights: [CGFloat] {
        guard let totals, let maxV = totals.max(), maxV > 0 else {
            return Array(repeating: 0, count: 5)
        }
        return totals.map { CGFloat($0 / maxV) * 32 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Distribution".uppercased())
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.04 * 11)
                .foregroundStyle(Tokens.textTertiary)
            if totals == nil {
                HStack {
                    Text("—")
                        .font(.system(size: 22, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Tokens.textTertiary)
                    Spacer()
                }
                .frame(height: 32)
                .padding(.top, 4)
            } else {
                HStack(alignment: .bottom, spacing: 3) {
                    ForEach(0..<5, id: \.self) { i in
                        Tokens.binColor(i)
                            .frame(maxWidth: .infinity)
                            .frame(height: max(0, heights[i]))
                            .clipShape(RoundedRectangle(cornerRadius: 2, style: .continuous))
                    }
                }
                .frame(height: 32)
                .padding(.top, 4)
            }
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
        // LazyVStack so only visible rows are constructed — a batch of several
        // hundred images no longer materializes every TableRow (with its badges,
        // mini-bars, hover state) up front. The whole table already lives inside
        // the parent ScrollView, so lazy loading works as intended.
        LazyVStack(spacing: 0) {
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
    @State private var thumb: NSImage? = nil

    var body: some View {
        Button {
            if row.status == .done { onTap() }
        } label: {
            TableGrid {
                // Status dot
                HStack { StatusDot(status: row.status) }

                // Thumbnail — real per-image thumbnail, falling back to the
                // stylized ThumbDots only while it loads or if it's missing.
                Group {
                    if let thumb {
                        Image(nsImage: thumb)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    } else {
                        ThumbDots(seed: row.seed)
                    }
                }
                .frame(width: 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .onAppear { loadThumb() }

                // Filename
                VStack(alignment: .leading, spacing: 1) {
                    Text(row.name)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Tokens.text)
                    Text(fileSubline(for: row))
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

    private func fileSubline(for row: BatchMockRow) -> String {
        // Real pixel dimensions (from the ImageRecord); "—" when unknown so we
        // never invent a size. Real on-disk file size when we could stat it.
        let dims: String = (row.widthPx > 0 && row.heightPx > 0)
            ? "\(row.widthPx) × \(row.heightPx)"
            : "—"
        let size: String? = row.fileSizeBytes.map {
            ByteCountFormatter.string(fromByteCount: $0, countStyle: .file)
        }
        let trailing: String
        switch row.status {
        case .done:    trailing = size ?? ""
        case .running: trailing = "processing…"
        case .queued:  trailing = "queued"
        case .error:   trailing = "error"
        }
        return trailing.isEmpty ? dims : "\(dims) · \(trailing)"
    }

    private func loadThumb() {
        // Capture the URL on the MainActor before hopping off the actor —
        // matches the RecentRow/ImageThumbCell thumbnail-loading pattern.
        let url = row.thumbURL
        Task.detached(priority: .utility) {
            let img = NSImage(contentsOf: url)
            await MainActor.run { thumb = img }
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
