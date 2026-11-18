import SwiftUI
import AppKit
import UniformTypeIdentifiers
import SwiftData

// MARK: — Row model (built from per-image values read off the main actor)

private struct BatchMockRow: Sendable {
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

private struct BatchExportImageSnapshot: Sendable {
    let fileName: String
    let imageURL: URL
    let cellsData: Data
    let confidence: Double
    /// The image's own scale, for its scale bar.
    let pxPerUm: Double
}

/// Per-image figures kept between refreshes, so a refresh decodes metrics
/// only for images whose cells (or the batch thresholds) changed.
private struct BatchRowFigures {
    let key: LibraryMetricsReader.DetectionKey
    let thresholds: [Double]
    let summary: CellMetricsStats.ImageSummary
}

/// One table row. A row is done when the image has a detection; count, mean
/// diameter and bins cover every stored cell (`CellMetricsStats.imageSummary`).
private func makeBatchRow(entry: LibraryMetricsReader.ImageEntry,
                          summary: CellMetricsStats.ImageSummary?,
                          index: Int, fileSizeBytes: Int64?) -> BatchMockRow {
    let summary = entry.detection == nil ? nil : summary
    return BatchMockRow(name: entry.fileName,
                        status: summary != nil ? .done : .queued,
                        count: summary?.count,
                        meanDiameter: summary?.meanDiameter,
                        distNorm: summary?.bars,
                        distCounts: summary?.binCounts,
                        seed: index * 7 + 3,
                        imageId: entry.id,
                        thumbURL: FileStore.shared.thumbURL(for: entry.id),
                        widthPx: entry.widthPx,
                        heightPx: entry.heightPx,
                        fileSizeBytes: fileSizeBytes)
}

/// Folder info per batch, kept across visits to the Batches tab and keyed by
/// the batch's `contentRevision` when it was computed.
@MainActor
private enum BatchFolderInfoCache {
    static var entries: [UUID: (revision: Int, info: BatchFolderInfo)] = [:]
}

/// `ImageRecord.storedURL` for an image entry.
private func storedURL(of entry: LibraryMetricsReader.ImageEntry) -> URL {
    let raw = (entry.fileName as NSString).pathExtension
    return FileStore.shared.imageURL(for: entry.id, extension: raw.isEmpty ? "tif" : raw.lowercased())
}

// MARK: — Display helpers

/// One formatter for every batch date on this screen ("Jan 5, 14:32").
private let batchDateFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "MMM d, HH:mm"
    return f
}()

/// Short absolute date string ("Jan 5, 14:32") — matches `HeaderRow.subtitle`'s format.
private func shortBatchDate(_ date: Date) -> String {
    batchDateFormatter.string(from: date)
}

/// Snapshot a batch and export its analyzed images without touching SwiftData
/// from the background compositor. The picker selects only the parent; the
/// writer creates a child folder named exactly like the visible batch title.
@MainActor
private func beginAnnotatedBatchExport(
    batch: BatchRecord,
    batchName: String,
    state: AppState,
    completion: @escaping (Result<ExportService.BatchAnnotatedFolderResult, Error>) -> Void
) {
    let thresholds = batch.thresholds
    let pxPerUm = batch.pxPerUm
    let snapshots = state.orderedImages(in: batch).compactMap { image -> BatchExportImageSnapshot? in
        guard let detection = image.detection else { return nil }
        return .init(
            fileName: image.fileName,
            imageURL: image.displayURL,
            cellsData: detection.cellsData,
            confidence: state.effectiveConfidence(for: image),
            pxPerUm: image.currentPxPerUm)
    }
    guard !snapshots.isEmpty else {
        completion(.failure(ExportError.noAnalyzedImages))
        return
    }

    let panel = NSOpenPanel()
    panel.title = "Choose where to export \(batchName)"
    panel.prompt = "Export"
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = false
    panel.canCreateDirectories = true
    panel.begin { response in
        guard response == .OK, let parent = panel.url else { return }
        Task { @MainActor in
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    // Decode each image's cells just before it is drawn, so only
                    // one image's cells and bitmap are in memory at a time.
                    return try ExportService.writeBatchAnnotatedPNGs(
                        batchName: batchName,
                        imageCount: snapshots.count,
                        thresholds: thresholds,
                        pxPerUm: pxPerUm,
                        overlayMode: .outline,
                        parentDirectory: parent,
                        loadImage: { index in
                            let snapshot = snapshots[index]
                            return ExportService.BatchAnnotatedImageInput(
                                fileName: snapshot.fileName,
                                imageURL: snapshot.imageURL,
                                cells: DetectionRecord.decodeCellsData(snapshot.cellsData),
                                confidence: snapshot.confidence,
                                pxPerUm: snapshot.pxPerUm)
                        })
                }.value
                completion(.success(result))
            } catch {
                completion(.failure(error))
            }
        }
    }
}

// MARK: — Main view

struct BatchView: View {
    @Bindable var state: AppState

    /// Table rows for `rowsBatchId`, in display order. Built from values read
    /// in a background context: no `ImageRecord`/`DetectionRecord` is kept
    /// alive by this screen, and no cell outlines are decoded for it.
    @State private var rows: [BatchMockRow] = []
    @State private var rowsBatchId: UUID? = nil
    /// The entries behind `rows`, same order, for single-image updates.
    @State private var entries: [LibraryMetricsReader.ImageEntry] = []
    @State private var figures: [UUID: BatchRowFigures] = [:]
    @State private var fileSizes: [UUID: Int64] = [:]
    /// Coalesces change notifications: an edit to one image (notification
    /// object = its id) rebuilds that row; anything else re-reads the batch,
    /// decoding metrics only for images whose cells changed.
    @State private var refresher = CoalescedRefresh()

    /// All batches, most-recent-first (mirrors `Repositories.allBatches()`).
    /// Fix (researcher #7b): the Batches tab previously only ever showed
    /// `state.currentBatch` — the single most-recently-opened batch — with no
    /// way to reach any other batch except by going back to Home. This backs
    /// the always-visible `BatchListSidebar` so every batch is one click away.
    @State private var allBatches: [BatchRecord] = []
    /// Folder label and image count per batch, computed in the background
    /// from image paths and refreshed when a batch's `contentRevision` moves,
    /// so rendering the rail never walks `batch.images`.
    @State private var folderInfo: [UUID: BatchFolderInfo] = [:]
    @State private var batchListRefresher = CoalescedRefresh()
    @State private var search = ""
    @FocusState private var searchFocused: Bool
    private var visibleBatches: [BatchRecord] {
        search.isEmpty ? allBatches : allBatches.filter {
            title(for: $0).localizedCaseInsensitiveContains(search)
                || ($0.condition ?? "").localizedCaseInsensitiveContains(search)
        }
    }

    /// Researcher feedback #7a: prefer the folder the user actually dropped
    /// (see `BatchFolderInfo.label`) over the generic `displayName`.
    private func title(for batch: BatchRecord) -> String {
        folderInfo[batch.id]?.label ?? batch.displayName
    }

    private func imageCount(for batch: BatchRecord) -> Int {
        batch.imageCountSummary >= 0 ? batch.imageCountSummary : (folderInfo[batch.id]?.imageCount ?? 0)
    }

    /// Re-reads the open batch (`everything`) or only `imageIds`, then
    /// rebuilds the rows. Metrics are decoded off the main actor, and only
    /// for images whose `(detection, cellsRevision)` or thresholds changed.
    private func refreshRows(everything: Bool, imageIds: Set<UUID>) async {
        guard let batch = state.currentBatch else {
            rows = []; entries = []; rowsBatchId = nil
            return
        }
        let batchId = batch.id
        let thresholds = batch.thresholds
        let container = state.repos.container
        if rowsBatchId != batchId {
            figures = [:]
        }
        let known = Set(figures.values.filter { $0.thresholds == thresholds }.map(\.key))

        var updated: [LibraryMetricsReader.ImageEntry]
        if !everything, rowsBatchId == batchId {
            let ids = Array(imageIds)
            guard let read = await LibraryMetricsReader.run({
                try ids.map { try LibraryMetricsReader.image(id: $0, container: container, metrics: .allExcept(known)) }
            }), !Task.isCancelled, state.currentBatchId == batchId else { return }
            updated = entries
            let positions = Dictionary(updated.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
            for (id, entry) in zip(ids, read) {
                let belongs = entry?.batchId == batchId
                switch (positions[id], belongs) {
                case (let index?, true): updated[index] = entry!
                case (nil, false): continue          // another batch's image
                default:
                    // Added to or removed from this batch: re-read it whole.
                    refresher.request(perform: refreshRows)
                    return
                }
            }
        } else {
            guard let read = await LibraryMetricsReader.run({
                try LibraryMetricsReader.batchImages(batchId: batchId, container: container,
                                                     metrics: .allExcept(known))
            }), !Task.isCancelled, state.currentBatchId == batchId else { return }
            updated = read.sorted { $0.fileName.localizedStandardCompare($1.fileName) == .orderedAscending }
        }

        // Figures: reuse unchanged ones, compute the rest from fresh metrics.
        var nextFigures: [UUID: BatchRowFigures] = [:]
        func addFigures(_ entry: LibraryMetricsReader.ImageEntry) {
            guard let detection = entry.detection else { return }
            if let cached = figures[entry.id], cached.key == detection.key, cached.thresholds == thresholds {
                nextFigures[entry.id] = cached
            } else if let metrics = detection.metrics {
                nextFigures[entry.id] = BatchRowFigures(
                    key: detection.key, thresholds: thresholds,
                    summary: CellMetricsStats.imageSummary(metrics, thresholds: thresholds))
            }
        }
        updated.forEach(addFigures)
        // Safety net: an analysed image whose metrics were skipped as known
        // but has no cached figures is read again with its metrics.
        let missing = updated.filter { $0.detection != nil && nextFigures[$0.id] == nil }.map(\.id)
        if !missing.isEmpty {
            guard let reread = await LibraryMetricsReader.run({
                try missing.compactMap { try LibraryMetricsReader.image(id: $0, container: container, metrics: .all) }
            }), !Task.isCancelled, state.currentBatchId == batchId else { return }
            let positions = Dictionary(updated.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
            for entry in reread where entry.batchId == batchId {
                guard let index = positions[entry.id] else { continue }
                updated[index] = entry
                addFigures(entry)
            }
        }

        // Stat stored copies not seen before, off the main actor.
        let unseen = updated.filter { fileSizes[$0.id] == nil }.map { ($0.id, storedURL(of: $0)) }
        var sizes = fileSizes
        if !unseen.isEmpty {
            let measured = await Task.detached(priority: .utility) { () -> [UUID: Int64] in
                var result: [UUID: Int64] = [:]
                for (id, url) in unseen {
                    if let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize {
                        result[id] = Int64(size)
                    }
                }
                return result
            }.value
            guard !Task.isCancelled, state.currentBatchId == batchId else { return }
            sizes.merge(measured) { _, new in new }
        }

        figures = nextFigures
        fileSizes = sizes
        // Metrics were only needed for the figures above.
        entries = updated.map(\.withoutMetrics)
        rowsBatchId = batchId
        rows = updated.enumerated().map { index, entry in
            makeBatchRow(entry: entry, summary: nextFigures[entry.id]?.summary,
                         index: index, fileSizeBytes: sizes[entry.id])
        }
    }

    private func reloadBatches() {
        allBatches = state.repos.allBatches()
        // Labels already known (also from an earlier visit) show at once;
        // they are recomputed only for batches that are new or changed.
        for batch in allBatches where folderInfo[batch.id] == nil {
            if let known = BatchFolderInfoCache.entries[batch.id] { folderInfo[batch.id] = known.info }
        }
        let stale = allBatches.filter { BatchFolderInfoCache.entries[$0.id]?.revision != $0.contentRevision }
            .map { ($0.id, $0.contentRevision) }
        guard !stale.isEmpty else { return }
        let container = state.repos.container
        Task { @MainActor in
            let ids = stale.map(\.0)
            guard let info = await LibraryMetricsReader.run({
                try LibraryMetricsReader.folderInfo(batchIds: ids, container: container)
            }) else { return }
            for (id, revision) in stale {
                guard let value = info[id] else { continue }
                BatchFolderInfoCache.entries[id] = (revision, value)
                folderInfo[id] = value
            }
        }
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
        let sorted = state.orderedImages(in: batch)
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
                batches: visibleBatches,
                title: title(for:),
                imageCount: imageCount(for:),
                search: $search, searchFocused: $searchFocused,
                selectedId: state.currentBatchId,
                onSelect: { batch in state.currentBatchId = batch.id },
                onArchive: { batch in BatchArchiveController.beginArchive(batchId: batch.id, state: state) },
                onRemove: { batch in BatchArchiveController.confirmRemoval(of: batch.id, state: state) }
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
                        HeaderRow(state: state, title: state.currentBatch.map(title(for:)) ?? "Batch",
                                  pendingCount: pendingCount, totalImages: rows.count)
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
                .overlay(alignment: .bottom) {
                    if let toast = state.exportToast {
                        ExportFeedbackToast(message: toast.message, isError: toast.isError)
                            .padding(.bottom, 24)
                    }
                }
            }
        }
        .focusedSceneValue(\.cellCounterShortcuts, shortcutActions)
        // Moved off the (conditionally-present) detail ScrollView and onto the
        // outer HStack so they stay live — and the sidebar keeps refreshing —
        // even while no batch is selected. Previously these lived only inside
        // the `else` branch, so the empty-state screen never heard about
        // newly created/deleted batches until the user navigated away and back.
        //
        // A correction naming an image (notification object = its id) only
        // rebuilds that row; one without an image, or a library change,
        // re-reads the batch (coalesced, decoding only changed images).
        .onReceive(NotificationCenter.default.publisher(for: .ccCorrectionsChanged)) { note in
            refresher.request(CoalescedRefresh.imageId(of: note), perform: refreshRows)
        }
        .onReceive(NotificationCenter.default.publisher(for: .ccLibraryChanged)) { _ in
            refresher.request(perform: refreshRows)
            batchListRefresher.request { _, _ in reloadBatches() }
        }
        .onAppear {
            reloadBatches()
        }
        .onDisappear {
            refresher.cancel()
            batchListRefresher.cancel()
        }
        .task(id: state.currentBatchId) {
            refresher.request(delay: .zero, perform: refreshRows)
        }
    }

    private var shortcutActions: ScreenShortcutActions {
        var actions = ScreenShortcutActions()
        actions.find = { searchFocused = true }
        if state.currentBatch != nil { actions.deleteSelection = { deleteBatchShortcut() } }
        if !rows.isEmpty { actions.openSelection = { if let id = rows.first?.imageId { openImage(id) } } }
        if !doneRows.isEmpty { actions.export = { exportBatchShortcut() } }
        if !visibleBatches.isEmpty {
            actions.previous = { selectBatch(-1) }
            actions.next = { selectBatch(1) }
        }
        return actions
    }

    private func selectBatch(_ delta: Int) {
        guard !visibleBatches.isEmpty else { return }
        let current = visibleBatches.firstIndex { $0.id == state.currentBatchId }
        let index = max(0, min(visibleBatches.count - 1, (current ?? (delta > 0 ? -1 : visibleBatches.count)) + delta))
        state.currentBatchId = visibleBatches[index].id
    }

    /// Keyboard shortcut wrappers — delegate to HeaderRow logic via AppState
    private func deleteBatchShortcut() {
        guard let batch = state.currentBatch else { return }
        BatchArchiveController.confirmRemoval(of: batch.id, state: state)
    }

    private func exportBatchShortcut() {
        guard let batch = state.currentBatch else { return }
        beginAnnotatedBatchExport(batch: batch, batchName: title(for: batch), state: state) { result in
            switch result {
            case .success(let output):
                if let first = output.errors.first {
                    state.flashExport(
                        "Saved \(output.written.count) PNGs; \(output.errors.count) failed (\(first.filename): \(first.message))",
                        isError: true)
                } else {
                    state.flashExport(
                        "Saved \(output.written.count) PNGs in \(output.folder.lastPathComponent)",
                        isError: false)
                }
            case .failure(let error):
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
    /// Row title and image count, from `BatchView`'s background-read
    /// folder info (rows never walk `batch.images`).
    let title: (BatchRecord) -> String
    let imageCount: (BatchRecord) -> Int
    @Binding var search: String
    var searchFocused: FocusState<Bool>.Binding
    let selectedId: UUID?
    let onSelect: (BatchRecord) -> Void
    let onArchive: (BatchRecord) -> Void
    let onRemove: (BatchRecord) -> Void

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

            TextField("Find batches", text: $search).textFieldStyle(.roundedBorder)
                .focused(searchFocused).padding(.horizontal, 12).padding(.bottom, 10)

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
                                        title: title(batch),
                                        imageCount: imageCount(batch),
                                        isSelected: batch.id == selectedId,
                                        onSelect: { onSelect(batch) })
                                .contextMenu {
                                    Button("Archive Batch…") { onArchive(batch) }
                                    Button("Delete Batch…") { onRemove(batch) }
                                }
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
    let title: String
    let imageCount: Int
    let isSelected: Bool
    let onSelect: () -> Void

    @Environment(AppTheme.self) private var theme
    @State private var hovered = false

    private var subtitle: String {
        let n = imageCount
        return "\(n) image\(n == 1 ? "" : "s") · \(shortBatchDate(batch.createdAt))"
    }

    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
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
    /// Researcher feedback #7a: this used to render `batch.displayName`
    /// directly, which for multi-image imports is a generic
    /// "Batch · N images · <date>" string — literally the word "Batch" the
    /// researcher was pointing at. `BatchView` passes the folder the user
    /// actually dropped (derived from the images' original paths), falling
    /// back to `displayName` (e.g. the single-file case) when no common
    /// folder can be determined.
    let title: String
    let pendingCount: Int
    let totalImages: Int
    @Environment(AppTheme.self) private var theme

    @State private var exportFlash: String? = nil
    @State private var exportErrorFlash: String? = nil
    @State private var clearWorkItem: DispatchWorkItem? = nil

    private var subtitle: String {
        guard let batch = state.currentBatch else { return "" }
        let modelName = state.models.first(where: { $0.id == batch.modelId })?.name ?? batch.modelId
        let when = shortBatchDate(batch.createdAt)
        // The scales in use: each image has its own ("2 scales").
        let scales = state.scaleSummary(for: batch).overview
        return "\(totalImages) image\(totalImages == 1 ? "" : "s") · started \(when) · \(modelName) · \(scales)"
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
                        archiveBatch()
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "archivebox")
                                .font(.system(size: 12))
                            Text("Archive…")
                        }
                    }
                    .appButton(.standard, size: .sm)
                    .disabled(state.currentBatch == nil)
                    .help("Move this batch, its images, outlines and calibration into an archive folder and free the space in your library")

                    Button {
                        deleteBatch()
                    } label: {
                        Icon("trash", size: 13)
                    }
                    .appButton(.danger, size: .sm)
                    .frame(width: 28, height: 28)
                    .help("Archive or delete this batch")
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
        beginAnnotatedBatchExport(batch: batch, batchName: title, state: state) { result in
            switch result {
            case .success(let output):
                if let first = output.errors.first {
                    flashError(
                        "Saved \(output.written.count) PNGs; \(output.errors.count) failed (\(first.filename): \(first.message))")
                } else {
                    flashSaved(output.folder.path)
                }
            case .failure(let error):
                flashError(error.localizedDescription)
            }
        }
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

    /// Batch removal always offers archiving first; permanent deletion is the
    /// explicit second choice (see `BatchArchiveController`).
    private func deleteBatch() {
        guard let batch = state.currentBatch else { return }
        BatchArchiveController.confirmRemoval(of: batch.id, state: state)
    }

    private func archiveBatch() {
        guard let batch = state.currentBatch else { return }
        BatchArchiveController.beginArchive(batchId: batch.id, state: state)
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
            ForEach(Array(rows.enumerated()), id: \.element.imageId) { i, row in
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
                .task(id: row.thumbURL) { await loadThumb() }

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

    /// Runs while the row is on screen; a row scrolled away before its
    /// thumbnail is read skips the read.
    private func loadThumb() async {
        // Capture the URL on the MainActor before hopping off the actor —
        // matches the RecentRow/ImageThumbCell thumbnail-loading pattern.
        let url = row.thumbURL
        let img = await LibraryMetricsReader.run { ImageLoader.cachedThumbnail(at: url) }
        guard !Task.isCancelled, let img else { return }
        thumb = img
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
            // progress". Note: `makeBatchRow` never emits `.running` today, so
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
