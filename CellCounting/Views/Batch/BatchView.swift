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
        // Researcher feedback #5: rows previously followed import order,
        // which is effectively random for a folder drop (filesystem
        // enumeration order, not alphabetical) and made clicking through a
        // batch disorienting. `localizedStandardCompare` is the same
        // natural/alphanumeric comparator Finder uses, so "img2" sorts
        // before "img10" instead of after it.
        .sorted(by: { $0.fileName.localizedStandardCompare($1.fileName) == .orderedAscending })
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

// MARK: — Display helpers

/// Best-effort "uploaded folder" name for a batch, derived from its images'
/// original (pre-import) file paths — NOT `batch.displayName`. For
/// multi-file imports `displayName` is a generic "Batch · N images · <date>"
/// string (see `AppState.proceedWithImport`), which is exactly the "labels
/// each batch 'Batch'" complaint from researcher feedback #7a. Returns the
/// shared parent directory's last path component when every image in the
/// batch was imported from the same folder; nil when that can't be
/// determined (single image, mixed-origin batch, or blank original paths) —
/// callers fall back to `displayName` in that case.
private func batchFolderLabel(for batch: BatchRecord) -> String? {
    guard batch.images.count > 1 else { return nil }
    let parents = Set(batch.images.compactMap { img -> String? in
        guard !img.originalPath.isEmpty else { return nil }
        let parent = (img.originalPath as NSString).deletingLastPathComponent
        return parent.isEmpty ? nil : parent
    })
    guard parents.count == 1, let common = parents.first else { return nil }
    let name = (common as NSString).lastPathComponent
    return name.isEmpty ? nil : name
}

/// Short absolute date string ("Jan 5, 14:32") — matches `HeaderRow.subtitle`'s format.
private func shortBatchDate(_ date: Date) -> String {
    let f = DateFormatter()
    f.dateFormat = "MMM d, HH:mm"
    return f.string(from: date)
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

    /// All batches, most-recent-first (mirrors `Repositories.allBatches()`).
    /// Fix (researcher #7b): the Batches tab previously only ever showed
    /// `state.currentBatch` — the single most-recently-opened batch — with no
    /// way to reach any other batch except by going back to Home. This backs
    /// the always-visible `BatchListSidebar` so every batch is one click away.
    @State private var allBatches: [BatchRecord] = []

    private func recomputeRows() {
        guard let batch = state.currentBatch else { rows = []; return }
        rows = buildRealRows(for: batch, thresholds: batch.thresholds)
    }

    private func reloadBatches() {
        allBatches = state.repos.allBatches()
    }

    /// Open Results at the tapped row's image. Bug fix: a table-row tap
    /// previously ran `state.view = .results` with no reference to the clicked
    /// row, so Results opened whatever `currentImageIdx` already pointed at
    /// (image 0, or the last-viewed image) instead of the row the user clicked.
    /// Resolve the tapped row's image id to its index in the SAME `importedAt`-
    /// sorted order `AppState.currentImage` indexes into — NOT the
    /// `localizedStandardCompare` order the table is displayed in — set
    /// `currentImageIdx`, then navigate. Mirrors `ImagesLibraryView.handleTap`,
    /// so table display order and Results resolution can't drift.
    private func openImage(_ imageId: UUID) {
        guard let batch = state.currentBatch else { return }
        let sorted = batch.images.sorted { $0.importedAt < $1.importedAt }
        if let idx = sorted.firstIndex(where: { $0.id == imageId }) {
            state.currentImageIdx = idx
        }
        state.view = .results
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
    /// Images in the batch with no saved detection yet. Detection runs INLINE
    /// (`AppState.proceedWithImport` analyzes a batch on the foreground
    /// `.processing` screen, then routes to Results) — there is no background
    /// job queue, so this is NOT a live queue count: by the time a batch is
    /// viewed here every image has already been through the pipeline, and a
    /// still-undetected image is un-analyzed (detection failed/cancelled), not
    /// "waiting". Drives the honest "N of M analyzed" header readout below.
    private var pendingCount: Int { rows.filter { $0.status != .done }.count }

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

    /// Human-readable range labels for the first five bins of the active batch
    /// (matches the `BinMath` split the per-row bars and summary card use), so
    /// the Distribution card can title each bar's exact count with its range.
    private var binLabels: [String] {
        BinMath.bins(from: state.currentBatch?.thresholds ?? state.thresholds).map(\.label)
    }

    var body: some View {
        HStack(spacing: 0) {
            // Fix (researcher #7b): persistent list of every batch, not just
            // the currently-open one — see `allBatches` above.
            BatchListSidebar(
                batches: allBatches,
                selectedId: state.currentBatchId,
                onSelect: { batch in state.currentBatchId = batch.id }
            )

            if state.currentBatch == nil {
                EmptyStateView(
                    title: allBatches.isEmpty ? "No batch open" : "No batch selected",
                    subtitle: allBatches.isEmpty
                        ? "Drop a folder of microscope images on the Home screen to create a batch."
                        : "Choose a batch from the list on the left to view its images and results.",
                    symbol: "books.vertical"
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Tokens.bg)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        HeaderRow(state: state, pendingCount: pendingCount, totalImages: rows.count)
                            .padding(.bottom, 18)

                        StatsRow(
                            totalCells: totalCells,
                            meanCells: meanCells,
                            meanDiam: meanDiam,
                            doneCount: doneRows.count,
                            total: rows.count,
                            sigmaCells: sigmaCells,
                            sigmaDiam: sigmaDiam,
                            distTotals: distTotals,
                            binLabels: binLabels
                        )
                        .padding(.bottom, 20)

                        BatchTable(rows: rows, binLabels: binLabels, onTap: openImage)
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
            }
        }
        // Moved off the (conditionally-present) detail ScrollView and onto the
        // outer HStack so they stay live — and the sidebar keeps refreshing —
        // even while no batch is selected. Previously these lived only inside
        // the `else` branch, so the empty-state screen never heard about
        // newly created/deleted batches until the user navigated away and back.
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("ccCorrectionsChanged"))) { _ in
            refreshKey &+= 1
            recomputeRows()
        }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("ccLibraryChanged"))) { _ in
            refreshKey &+= 1
            recomputeRows()
            reloadBatches()
        }
        .onAppear {
            recomputeRows()
            reloadBatches()
        }
        .onChange(of: state.currentBatchId) { _, _ in recomputeRows() }
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

// MARK: — Batches rail
//
// Researcher feedback #7b: the Batches tab could only ever show the single
// most-recently-opened batch (`state.currentBatch`) — every OTHER batch was
// reachable only via Home → Recents, which just routes back to this same
// view showing the same one batch. This rail lists every batch
// (`Repositories.allBatches()`, newest first) so the Batches tab is a real
// browsing surface on its own, independent of Home.
private struct BatchListSidebar: View {
    let batches: [BatchRecord]
    let selectedId: UUID?
    let onSelect: (BatchRecord) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("All batches")
                .font(.system(size: 10.5, weight: .semibold))
                .tracking(0.04 * 10.5)
                .foregroundStyle(Tokens.textTertiary)
                .textCase(.uppercase)
                .padding(.horizontal, 14)
                .padding(.top, 16)
                .padding(.bottom, 8)

            if batches.isEmpty {
                Text("No batches yet.")
                    .font(.system(size: 12))
                    .foregroundStyle(Tokens.textTertiary)
                    .padding(.horizontal, 14)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 1) {
                        ForEach(batches, id: \.id) { batch in
                            BatchListRow(batch: batch,
                                        isSelected: batch.id == selectedId,
                                        onSelect: { onSelect(batch) })
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 12)
                }
            }
        }
        .frame(width: 220)
        .frame(maxHeight: .infinity)
        .background(Tokens.bgSidebar)
        .background(.regularMaterial.opacity(0.4))
        .overlay(alignment: .trailing) { Rectangle().fill(Tokens.border).frame(width: 0.5) }
    }
}

private struct BatchListRow: View {
    let batch: BatchRecord
    let isSelected: Bool
    let onSelect: () -> Void

    @Environment(AppTheme.self) private var theme
    @State private var hovered = false

    private var subtitle: String {
        let n = batch.images.count
        return "\(n) image\(n == 1 ? "" : "s") · \(shortBatchDate(batch.createdAt))"
    }

    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 3) {
                Text(batchFolderLabel(for: batch) ?? batch.displayName)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(isSelected ? theme.accentColor : Tokens.text)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(Tokens.textTertiary)
                    .lineLimit(1)
                if let cond = batch.condition, !cond.isEmpty {
                    Text(cond)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(theme.accentColor)
                        .lineLimit(1)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(theme.accentSoft))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: Tokens.Radius.md, style: .continuous)
                    .fill(isSelected ? theme.accentSoft : (hovered ? Tokens.hover : Color.clear))
            )
            .contentShape(RoundedRectangle(cornerRadius: Tokens.Radius.md, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .animation(Tokens.Motion.easeFast, value: hovered)
    }
}

// MARK: — Header

private struct HeaderRow: View {
    @Bindable var state: AppState
    let pendingCount: Int
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

    /// Researcher feedback #7a: this used to render `batch.displayName`
    /// directly, which for multi-image imports is a generic
    /// "Batch · N images · <date>" string — literally the word "Batch" the
    /// researcher was pointing at. Prefer the folder the user actually
    /// dropped (derived from the images' original paths); fall back to
    /// `displayName` (e.g. the single-file case) when no common folder can
    /// be determined.
    private var title: String {
        guard let batch = state.currentBatch else { return "Batch" }
        return batchFolderLabel(for: batch) ?? batch.displayName
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 22, weight: .bold))
                        .tracking(-0.02 * 22)
                        .foregroundStyle(Tokens.text)
                    Text(subtitle)
                        .font(.system(size: 13))
                        .foregroundStyle(Tokens.textTertiary)
                    BatchConditionControl(state: state)
                        .padding(.top, 4)
                }
                Spacer()
                HStack(spacing: 8) {
                    if pendingCount > 0 {
                        AnalysisProgress(done: totalImages - pendingCount, total: totalImages)
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

// MARK: — Condition tag control
//
// `BatchRecord.condition` already exists and is exactly what Compare pools
// batches by (`Repositories.batches(matching:)`), but the only path that
// ever set it was the optional "Tag this batch" picker shown after a
// drag-and-drop import on Home. Every button-driven import (⌘O, ⌘⇧O, Home's
// "Choose images…"/"Choose folder…" buttons) skips that picker entirely,
// and once a batch existed there was no way to tag or retag it — so Compare
// stayed empty for most users. This is a small always-visible control on the
// batch header that sets/clears `condition` directly and saves immediately.
private struct BatchConditionControl: View {
    @Bindable var state: AppState
    @Environment(AppTheme.self) private var theme

    @State private var conditions: [ConditionRecord] = []
    @State private var showingNewField = false
    @State private var newName = ""

    private var currentCondition: String? { state.currentBatch?.condition }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Menu {
                Button("No condition") { setCondition(nil) }
                if !conditions.isEmpty {
                    Divider()
                    ForEach(conditions, id: \.id) { c in
                        Button {
                            setCondition(c.name)
                        } label: {
                            if c.name == currentCondition {
                                Label(c.name, systemImage: "checkmark")
                            } else {
                                Text(c.name)
                            }
                        }
                    }
                }
                Divider()
                Button("New condition…") {
                    newName = ""
                    showingNewField = true
                }
            } label: {
                HStack(spacing: 5) {
                    Icon("flask", size: 10)
                    Text(currentCondition ?? "No condition")
                        .font(.system(size: 11.5, weight: .medium))
                    Icon("chevron", size: 9)
                }
                .foregroundStyle(currentCondition != nil ? theme.accentColor : Tokens.textSecondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(
                    Capsule().fill(currentCondition != nil ? theme.accentSoft : Tokens.bgSunken)
                )
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Tag this batch with an experimental condition. Compare groups batches by this tag.")

            if showingNewField {
                HStack(spacing: 6) {
                    TextField("Condition name…", text: $newName)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(
                            RoundedRectangle(cornerRadius: Tokens.Radius.sm, style: .continuous)
                                .fill(Tokens.bgElevated))
                        .overlay(
                            RoundedRectangle(cornerRadius: Tokens.Radius.sm, style: .continuous)
                                .strokeBorder(Tokens.borderStrong, lineWidth: 0.5))
                        .frame(width: 150)
                        .onSubmit { addAndSetNewCondition() }
                    Button("Add") { addAndSetNewCondition() }
                        .appButton(.primary, size: .sm)
                        .disabled(newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Button("Cancel") { showingNewField = false; newName = "" }
                        .appButton(.ghost, size: .sm)
                }
                .transition(.opacity)
            }
        }
        .animation(Tokens.Motion.easeFast, value: showingNewField)
        .onAppear { refresh() }
        .onChange(of: state.currentBatchId) { _, _ in
            // The sidebar can switch batches while an in-progress "new
            // condition" entry is open; SwiftUI reuses this view's @State
            // across that switch (same position in the tree), so without
            // this reset a half-typed name from batch A could get applied
            // to batch B after the user clicks over.
            showingNewField = false
            newName = ""
            refresh()
        }
    }

    private func refresh() {
        conditions = state.repos.conditions()
    }

    private func setCondition(_ name: String?) {
        guard let batch = state.currentBatch else { return }
        batch.condition = name
        try? state.repos.context.save()
    }

    private func addAndSetNewCondition() {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        // Cycle a palette-ish hue so new conditions get distinct colors —
        // mirrors HomeView's ConditionPickerOverlay.
        let palette = ["#4db3a8", "#d97757", "#7b88e0", "#c074b8", "#e0b04d"]
        let color = palette[conditions.count % palette.count]
        state.repos.createCondition(name: trimmed, color: color)
        setCondition(trimmed)
        newName = ""
        showingNewField = false
        refresh()
    }
}

// Honest replacement for the old "N in queue" pill. Detection runs INLINE
// (`AppState.proceedWithImport` analyzes a batch on the foreground `.processing`
// screen, then routes to Results) — there is no background job queue, so a
// spinning "in queue" badge on a batch shown here implied active work that
// isn't happening. This reports the real done/total split instead, and shows
// only while some image is still un-analyzed (hidden once every image has a
// detection). Determinate wording, no perpetual spinner.
private struct AnalysisProgress: View {
    let done: Int
    let total: Int
    @Environment(AppTheme.self) private var theme

    var body: some View {
        Text("\(done) of \(total) analyzed")
            .font(.system(size: 11.5, weight: .semibold))
            .foregroundStyle(theme.accentColor)
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
    let binLabels: [String]

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
            DistributionCard(totals: distTotals, labels: binLabels)
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
    /// Range labels ("< 20 µm", "20–30 µm", …) aligned to `totals` by index,
    /// used to title each bar's exact count. May be shorter/longer than five;
    /// callers guard by index.
    var labels: [String] = []

    /// Bar heights (0–28pt) normalised to the largest bin so the tallest bar
    /// always fills the card. Capped a touch below the old 32pt to leave room
    /// for the per-bin count label above each bar.
    private var heights: [CGFloat] {
        guard let totals, let maxV = totals.max(), maxV > 0 else {
            return Array(repeating: 0, count: 5)
        }
        return totals.map { CGFloat($0 / maxV) * 28 }
    }

    private func label(for i: Int) -> String {
        labels.indices.contains(i) ? labels[i] : "bin \(i + 1)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Distribution".uppercased())
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.04 * 11)
                .foregroundStyle(Tokens.textTertiary)
            if let totals {
                // Each bin renders its exact cell count above a normalised bar,
                // so the batch-level split is legible without opening any image.
                HStack(alignment: .bottom, spacing: 3) {
                    ForEach(0..<5, id: \.self) { i in
                        let count = i < totals.count ? Int(totals[i]) : 0
                        VStack(spacing: 2) {
                            Text(count.formatted())
                                .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                                .foregroundStyle(count > 0 ? Tokens.textSecondary : Tokens.textQuaternary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.6)
                            Spacer(minLength: 0)
                            Tokens.binColor(i)
                                .frame(maxWidth: .infinity)
                                .frame(height: max(2, heights[i]))
                                .clipShape(RoundedRectangle(cornerRadius: 2, style: .continuous))
                        }
                        .frame(maxWidth: .infinity)
                        .help("\(label(for: i)): \(count) cell\(count == 1 ? "" : "s")")
                    }
                }
                .frame(height: 42)
                .padding(.top, 4)
            } else {
                HStack {
                    Text("—")
                        .font(.system(size: 22, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Tokens.textTertiary)
                    Spacer()
                }
                .frame(height: 42)
                .padding(.top, 4)
            }
            Text("cells per bin")
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
    var binLabels: [String] = []
    /// Called with the tapped row's image id (not just a bare "open") so the
    /// parent can resolve it to the correct Results index — see `openImage`.
    let onTap: (UUID) -> Void

    var body: some View {
        // LazyVStack so only visible rows are constructed — a batch of several
        // hundred images no longer materializes every TableRow (with its badges,
        // mini-bars, hover state) up front. The whole table already lives inside
        // the parent ScrollView, so lazy loading works as intended.
        LazyVStack(spacing: 0) {
            TableHead()
            ForEach(Array(rows.enumerated()), id: \.offset) { i, row in
                TableRow(row: row, isFirst: i == 0, binLabels: binLabels, onTap: onTap)
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
    var binLabels: [String] = []
    let onTap: (UUID) -> Void
    @State private var hovered = false
    @State private var thumb: NSImage? = nil

    var body: some View {
        Button {
            if row.status == .done { onTap(row.imageId) }
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

                // Bin distribution bars with exact per-bin counts
                BinStack(distNorm: row.distNorm, distCounts: row.distCounts, labels: binLabels)

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
            // Inline detection means an undetected image here is un-analyzed
            // (failed/cancelled), not sitting in a live queue — say so plainly
            // rather than implying it's about to be picked up.
            Text("Not analyzed")
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
        case .running: trailing = "analyzing…"
        case .queued:  trailing = ""          // status column already reads "Not analyzed"
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
            // Honest live label — no fabricated percentage. Cellpose 3.x has no
            // granular numeric progress callback (see AppState.processingStageLine),
            // so a hard-coded "64%" was fiction; the spinner already conveys "in
            // progress". Note: `buildRealRows` never emits `.running` today, so
            // this stays latent until AppState exposes the in-flight image id.
            Text("Analyzing…")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(theme.accentColor)
        }
    }
}

private struct BinStack: View {
    let distNorm: [Double]?
    /// Raw per-bin cell counts (5 bins) for this image, aligned to `distNorm`.
    /// Rendered as an exact number above each bar so a batch's per-image split
    /// is readable in the table without opening each image.
    let distCounts: [Double]?
    /// Range labels for tooltips, aligned by index. May be empty.
    var labels: [String] = []

    private func label(for i: Int) -> String {
        labels.indices.contains(i) ? labels[i] : "bin \(i + 1)"
    }

    var body: some View {
        if let norm = distNorm {
            HStack(alignment: .bottom, spacing: 5) {
                ForEach(0..<5, id: \.self) { i in
                    let count = (distCounts?.indices.contains(i) == true) ? Int(distCounts![i]) : 0
                    // Bar height (not width) now encodes the fraction so the
                    // exact count can sit directly above each bin.
                    let h = max(3, CGFloat(norm[i]) / 100 * 16)
                    VStack(spacing: 2) {
                        Text(count.formatted())
                            .font(.system(size: 9.5, design: .monospaced))
                            .foregroundStyle(count > 0 ? Tokens.textSecondary : Tokens.textQuaternary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)
                        Tokens.binColor(i)
                            .frame(height: h)
                            .frame(maxWidth: .infinity)
                            .clipShape(RoundedRectangle(cornerRadius: 1, style: .continuous))
                    }
                    .frame(maxWidth: 34)
                    .help("\(label(for: i)): \(count) cell\(count == 1 ? "" : "s")")
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
