import SwiftUI
import AppKit
import SwiftData

// MARK: — Main View

struct ImagesLibraryView: View {
    @Bindable var state: AppState

    /// Library rows as plain values read in a background context; this
    /// screen keeps no `ImageRecord` or `DetectionRecord` alive.
    @State private var images: [LibraryMetricsReader.ImageEntry] = []
    @State private var batchThresholds: [UUID: [Double]] = [:]
    @State private var imageNames: [UUID: String] = [:]
    /// Tile reload tokens: one per image (an edit to that image) and one for
    /// all tiles (any other change). Only tiles on screen reload.
    @State private var tileRevisions: [UUID: Int] = [:]
    @State private var allTilesRevision = 0
    @State private var refresher = CoalescedRefresh()
    /// False until the first read arrives, so the empty state does not flash.
    @State private var hasLoaded = false
    @State private var selectedIDs: Set<UUID> = []
    @State private var multiSelectMode = false
    @State private var showFindDuplicates = false
    @State private var isHashingForDupes = false
    @State private var search = ""
    @FocusState private var searchFocused: Bool
    @FocusState private var gridFocused: Bool

    private var visibleImages: [LibraryMetricsReader.ImageEntry] {
        search.isEmpty ? images : images.filter { (imageNames[$0.id] ?? $0.fileName).localizedCaseInsensitiveContains(search) }
    }
    private var selectedImage: LibraryMetricsReader.ImageEntry? { visibleImages.first { selectedIDs.contains($0.id) } }

    private let columns = [
        GridItem(.adaptive(minimum: 180, maximum: 240), spacing: 14)
    ]

    var body: some View {
        Group {
            if images.isEmpty && !hasLoaded {
                Color.clear
            } else if images.isEmpty {
                EmptyStateView(
                    title: "No images yet",
                    subtitle: "Drop microscope images on Home to get started.",
                    symbol: "photo.on.rectangle.angled"
                )
            } else {
                VStack(spacing: 0) {
                    // Toolbar strip
                    HStack(spacing: 10) {
                        TextField("Find images", text: $search)
                            .textFieldStyle(.roundedBorder).frame(maxWidth: 260)
                            .focused($searchFocused)
                        Spacer()
                        if multiSelectMode && !selectedIDs.isEmpty {
                            Button {
                                deleteSelected()
                            } label: {
                                HStack(spacing: 5) {
                                    Icon("trash", size: 12)
                                    Text("Delete \(selectedIDs.count)")
                                }
                            }
                            .appButton(.danger, size: .sm)
                        }
                        Button(selectedIDs.isEmpty ? "Copy library to Workbench…" : "Copy selected to Workbench…") {
                            state.prepareLibraryMigration(imageIDs: selectedIDs)
                        }
                        .appButton(.standard, size: .sm)
                        .disabled(state.preparingLibraryMigration || state.isPreparingImport || state.jobScheduler.activeCount > 0 || TrainingService.isTrainingActive)
                        // Pass-17: Find Duplicates
                        Button {
                            findDuplicates()
                        } label: {
                            HStack(spacing: 5) {
                                if isHashingForDupes {
                                    ProgressView()
                                        .controlSize(.mini)
                                } else {
                                    Icon("doc.on.doc", size: 12)
                                }
                                Text(isHashingForDupes ? "Scanning…" : "Find duplicates")
                            }
                        }
                        .appButton(.standard, size: .sm)
                        .disabled(isHashingForDupes)

                        Toggle(isOn: $multiSelectMode) {
                            Text("Select")
                                .font(.system(size: 12, weight: .medium))
                        }
                        .toggleStyle(.button)
                        .appButton(.standard, size: .sm)
                        .onChange(of: multiSelectMode) { _, newValue in
                            if !newValue { selectedIDs = [] }
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 8)
                    .background(Tokens.bgToolbar)
                    .overlay(alignment: .bottom) {
                        Rectangle().fill(Tokens.border).frame(height: 0.5)
                    }

                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 14) {
                            ForEach(visibleImages, id: \.id) { image in
                                ImageThumbCell(
                                    image: image,
                                    displayName: imageNames[image.id] ?? image.fileName,
                                    thresholds: image.batchId.flatMap { batchThresholds[$0] } ?? state.thresholds,
                                    revision: "\(allTilesRevision).\(tileRevisions[image.id] ?? 0)",
                                    container: state.repos.container,
                                    isSelected: selectedIDs.contains(image.id),
                                    multiSelectMode: multiSelectMode,
                                    onTap: { handleTap(image: image) },
                                    onDelete: { confirmDelete(image: image) }
                                )
                            }
                        }
                        .padding(20)
                    }
                    .focusable().focused($gridFocused)
                    .onKeyPress(keys: [.delete, .return]) { press in
                        guard press.modifiers.isEmpty, !KeyboardShortcutContext.isEditingText,
                              !KeyboardShortcutContext.hasNativeSheet, !KeyboardShortcutContext.hasOverlay(state) else { return .ignored }
                        if press.key == .delete, !selectedIDs.isEmpty { deleteSelected(); return .handled }
                        if press.key == .return, let image = selectedImage { openImage(image); return .handled }
                        return .ignored
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Tokens.bg)
        .onAppear { reload(delay: .zero) }
        .onDisappear { refresher.cancel() }
        // An edit to one image (notification object = its id) reloads only
        // that tile; other corrections and library changes re-read the list
        // (image rows only) and reload the tiles on screen.
        .onReceive(NotificationCenter.default.publisher(for: .ccCorrectionsChanged)) { note in
            refresher.request(CoalescedRefresh.imageId(of: note), perform: refresh)
        }
        .onReceive(NotificationCenter.default.publisher(for: .ccLibraryChanged)) { _ in reload() }
        .sheet(isPresented: $showFindDuplicates) {
            FindDuplicatesSheet(state: state, onDismiss: { showFindDuplicates = false; reload() })
        }
        .focusedSceneValue(\.cellCounterShortcuts, shortcutActions)
    }

    private var shortcutActions: ScreenShortcutActions {
        var actions = ScreenShortcutActions()
        if !images.isEmpty { actions.find = { searchFocused = true } }
        if !visibleImages.isEmpty {
            actions.selectAll = { multiSelectMode = true; selectedIDs = Set(visibleImages.map(\.id)); gridFocused = true }
            actions.previous = { selectAdjacent(-1) }
            actions.next = { selectAdjacent(1) }
        }
        if !selectedIDs.isEmpty { actions.deleteSelection = { deleteSelected() } }
        if selectedImage != nil { actions.openSelection = { if let image = selectedImage { openImage(image) } } }
        if !selectedIDs.isEmpty || !search.isEmpty {
            actions.cancel = { selectedIDs = []; search = ""; searchFocused = false }
        }
        return actions
    }

    private func selectAdjacent(_ delta: Int) {
        guard !visibleImages.isEmpty else { return }
        let current = selectedImage.flatMap { image in visibleImages.firstIndex { $0.id == image.id } }
        let index = max(0, min(visibleImages.count - 1, (current ?? (delta > 0 ? -1 : visibleImages.count)) + delta))
        multiSelectMode = true; selectedIDs = [visibleImages[index].id]; gridFocused = true
    }

    // MARK: — Helpers

    private func reload(delay: Duration = .milliseconds(250)) {
        refresher.request(delay: delay, perform: refresh)
    }

    private func refresh(everything: Bool, imageIds: Set<UUID>) async {
        guard everything else {
            for id in imageIds { tileRevisions[id, default: 0] &+= 1 }
            return
        }
        // Researcher feedback #5: `allImages()` returns import order, which
        // is effectively random across a folder drop (filesystem enumeration
        // order, not alphabetical) and made scanning the grid disorienting.
        // Sort by filename with Finder's natural/alphanumeric comparator so
        // "img2" sorts before "img10". Display order only — `handleTap`
        // below still resolves `currentImageIdx` against a separate
        // `importedAt`-sorted array to match `AppState.currentImage`'s
        // indexing scheme (Shared/AppState.swift), so that sort must NOT be
        // changed independently or tapping a thumbnail would open the wrong
        // image in Results.
        let container = state.repos.container
        let result = await LibraryMetricsReader.run { try LibraryMetricsReader.library(container: container) }
        guard !Task.isCancelled else { return }
        guard let read = result else { hasLoaded = true; return }
        let loaded = read.images
            .sorted { $0.fileName.localizedStandardCompare($1.fileName) == .orderedAscending }
        images = loaded
        batchThresholds = read.thresholds
        imageNames = disambiguatedNames(for: loaded)
        selectedIDs.formIntersection(Set(loaded.map(\.id)))
        allTilesRevision &+= 1
        hasLoaded = true
    }

    /// The selected rows' records, fetched from the main context only when
    /// an action needs them.
    private func records(_ ids: Set<UUID>) -> [ImageRecord] {
        let wanted = Array(ids)
        let byId = Dictionary(
            ((try? state.repos.context.fetch(FetchDescriptor<ImageRecord>(
                predicate: #Predicate { wanted.contains($0.id) }))) ?? []).map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first })
        return images.compactMap { byId[$0.id] }
    }

    /// Pass-17: back-fill hashes for any un-hashed images, then present FindDuplicatesSheet.
    private func findDuplicates() {
        let needsHash = state.repos.imagesNeedingHash()
        guard !needsHash.isEmpty else {
            // All hashes present — open sheet directly.
            showFindDuplicates = true
            return
        }

        isHashingForDupes = true

        // Snapshot only Sendable values (ids + URLs) to cross the actor
        // boundary. Previously the loop re-fetched the entire images table
        // (`allImages()`) on every iteration and did an individual
        // `context.save()` per hash — O(N·M) fetches + N saves. Now it's N
        // hashes off-main, then ONE fetch + one map build + one save on-main.
        let pairs: [(UUID, URL)] = needsHash.map { ($0.id, $0.storedURL) }
        let reposRef = state.repos

        Task.detached(priority: .userInitiated) {
            // Hash off the main thread, then apply all writes + a single save.
            var hashes: [(UUID, String)] = []
            for (imageId, url) in pairs {
                guard let hash = ImageLoader.sha256Hex(of: url) else { continue }
                hashes.append((imageId, hash))
            }
            let computed = hashes
            await MainActor.run {
                // Single fetch, single map, single save — instead of per-image.
                let byId = Dictionary(
                    reposRef.allImages().map { ($0.id, $0) },
                    uniquingKeysWith: { first, _ in first })
                for (imageId, hash) in computed {
                    byId[imageId]?.fileHash = hash
                }
                try? reposRef.context.save()
                isHashingForDupes = false
                showFindDuplicates = true
            }
        }
    }

    /// Returns disambiguated display names for images that share the same fileName.
    /// Duplicates get _2, _3, … appended so the grid label is always unique.
    private func disambiguatedNames(for images: [LibraryMetricsReader.ImageEntry]) -> [UUID: String] {
        var counts: [String: Int] = [:]
        var seen: [String: Int] = [:]
        for img in images { counts[img.fileName, default: 0] += 1 }
        var result: [UUID: String] = [:]
        for img in images {
            if counts[img.fileName, default: 0] <= 1 {
                result[img.id] = img.fileName
            } else {
                seen[img.fileName, default: 0] += 1
                let n = seen[img.fileName]!
                if n == 1 {
                    result[img.id] = img.fileName
                } else {
                    let base = (img.fileName as NSString).deletingPathExtension
                    let ext  = (img.fileName as NSString).pathExtension
                    result[img.id] = ext.isEmpty ? "\(base)_\(n)" : "\(base)_\(n).\(ext)"
                }
            }
        }
        return result
    }

    private func handleTap(image: LibraryMetricsReader.ImageEntry) {
        if multiSelectMode {
            if selectedIDs.contains(image.id) {
                selectedIDs.remove(image.id)
            } else {
                selectedIDs.insert(image.id)
            }
            return
        }
        openImage(image)
    }

    private func openImage(_ image: LibraryMetricsReader.ImageEntry) {
        // Navigate to results for this image.
        guard let batchId = image.batchId, let batch = state.repos.batch(id: batchId) else { return }
        state.currentBatchId = batch.id
        let sorted = state.orderedImages(in: batch)
        if let idx = sorted.firstIndex(where: { $0.id == image.id }) {
            state.currentImageIdx = idx
        }
        state.view = .results
    }

    private func confirmDelete(image entry: LibraryMetricsReader.ImageEntry) {
        guard let image = records([entry.id]).first else { return }
        let alert = NSAlert()
        alert.messageText = "Delete \"\(image.fileName)\"?"
        alert.informativeText = "This removes the image and its detection. This cannot be undone."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            do { try state.repos.deleteImage(image) }
            catch {
                state.flashExport("The image could not be deleted: \(error.localizedDescription)", isError: true)
                return
            }
            NotificationCenter.default.post(name: Notification.Name("ccLibraryChanged"), object: nil)
            reload()
        }
    }

    private func deleteSelected() {
        let toDelete = records(selectedIDs)
        let alert = NSAlert()
        alert.messageText = "Delete \(toDelete.count) image\(toDelete.count == 1 ? "" : "s")?"
        alert.informativeText = "This removes the images and their detections. This cannot be undone."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            do { try state.repos.deleteImages(toDelete) }
            catch {
                state.flashExport("The images could not be deleted: \(error.localizedDescription)", isError: true)
                return
            }
            NotificationCenter.default.post(name: Notification.Name("ccLibraryChanged"), object: nil)
            selectedIDs = []
            reload()
        }
    }
}

// MARK: — Thumbnail Cell

/// What a Library tile shows about an image's detection.
nonisolated private struct LibraryTile: Sendable, Equatable {
    let hasDetection: Bool
    /// `DetectionRecord.summaryCellCount`.
    let cellCount: Int
    /// The 5-bar size mini-chart; nil without cells.
    let bars: [Double]?
}

/// Reads Library tiles one at a time, off the main actor, from compact cell
/// metrics (the full payload only for detections not backfilled yet). A tile
/// that scrolls away before its turn is skipped: its task is cancelled.
private actor LibraryTileLoader {
    static let shared = LibraryTileLoader()

    func tile(imageId: UUID, thresholds: [Double], container: ModelContainer) throws -> LibraryTile? {
        try Task.checkCancellation()
        guard let entry = try LibraryMetricsReader.image(id: imageId, container: container, metrics: .all,
                                                          resolvingBatch: false) else {
            return nil
        }
        guard let detection = entry.detection else {
            return LibraryTile(hasDetection: false, cellCount: 0, bars: nil)
        }
        let bars = detection.metrics.flatMap { CellMetricsStats.imageSummary($0, thresholds: thresholds).bars }
        return LibraryTile(hasDetection: true, cellCount: detection.cellCount, bars: bars)
    }
}

private struct ImageThumbCell: View {
    let image: LibraryMetricsReader.ImageEntry
    /// Disambiguated display name — may differ from image.fileName when multiple
    /// images in the batch share the same original filename (e.g. plate01.tif _2, _3).
    let displayName: String
    /// The image's batch thresholds (app-wide ones for an image without a batch).
    let thresholds: [Double]
    /// Changes when this tile's count and bars must be re-read.
    let revision: String
    let container: ModelContainer
    let isSelected: Bool
    let multiSelectMode: Bool
    let onTap: () -> Void
    let onDelete: () -> Void

    @State private var hovered = false
    @State private var thumb: NSImage? = nil
    @State private var tile: LibraryTile? = nil

    @Environment(AppTheme.self) private var theme

    private var distNorm: [Double]? { tile?.bars }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Button(action: onTap) {
                VStack(alignment: .leading, spacing: 0) {
                    // Thumbnail
                    ZStack {
                        if let img = thumb {
                            Image(nsImage: img)
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                                .frame(height: 140)
                                .clipped()
                        } else {
                            Rectangle()
                                .fill(Tokens.bgSunken)
                                .frame(height: 140)
                            Image(systemName: "photo")
                                .font(.system(size: 28, weight: .light))
                                .foregroundStyle(Tokens.textQuaternary)
                        }

                        // Cell count badge
                        if let tile, tile.hasDetection {
                            VStack {
                                Spacer()
                                HStack {
                                    Spacer()
                                    Text("\(tile.cellCount) cells")
                                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                        .foregroundStyle(.white)
                                        .padding(.horizontal, 7)
                                        .padding(.vertical, 3)
                                        .background(Capsule().fill(Color.black.opacity(0.6)))
                                        .padding(6)
                                }
                            }
                        }

                        // Pass-18 (Lane N): notes badge — bottom-left corner.
                        // Surfaces that this image carries freeform notes and
                        // previews the first ~80 chars on hover. Edit lives
                        // in Results' NotesPanel; this is read-only.
                        if let notes = image.notes, !notes.isEmpty {
                            VStack {
                                Spacer()
                                HStack {
                                    Icon("info", size: 11)
                                        .foregroundStyle(.white)
                                        .frame(width: 18, height: 18)
                                        .background(Circle().fill(Color.black.opacity(0.6)))
                                        .padding(6)
                                        .help(notesTooltip(notes))
                                    Spacer()
                                }
                            }
                        }
                    }
                    .frame(height: 140)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

                    VStack(alignment: .leading, spacing: 4) {
                        Text(displayName)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(Tokens.text)
                            .lineLimit(1)
                            .truncationMode(.middle)

                        // Bin distribution mini-bar
                        if let norm = distNorm {
                            HStack(alignment: .bottom, spacing: 2) {
                                ForEach(0..<5, id: \.self) { i in
                                    let h = max(3, norm[i] * 0.2)
                                    Tokens.binColor(i)
                                        .frame(maxWidth: .infinity)
                                        .frame(height: h)
                                        .clipShape(RoundedRectangle(cornerRadius: 1, style: .continuous))
                                }
                            }
                            .frame(height: 20)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 8)
                }
                .background(
                    RoundedRectangle(cornerRadius: Tokens.Radius.lg, style: .continuous)
                        .fill(isSelected ? theme.accentSoft : Tokens.bgElevated)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: Tokens.Radius.lg, style: .continuous)
                        .strokeBorder(
                            isSelected ? theme.accentColor : (hovered ? Tokens.borderStrong : Tokens.border),
                            lineWidth: isSelected ? 1.5 : 0.5
                        )
                )
            }
            .buttonStyle(.plain)

            // Hover delete button (when not in multi-select mode)
            if hovered && !multiSelectMode {
                Button(action: onDelete) {
                    Image(systemName: "trash.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.white)
                        .frame(width: 26, height: 26)
                        .background(Circle().fill(Tokens.danger))
                        .shadow(color: .black.opacity(0.2), radius: 2, y: 1)
                }
                .buttonStyle(.plain)
                .padding(8)
                .transition(.opacity.combined(with: .scale(scale: 0.85)))
            }

            // Multi-select checkmark overlay
            if multiSelectMode {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 18))
                    .foregroundStyle(isSelected ? theme.accentColor : Tokens.textTertiary)
                    .background(Circle().fill(Color.white).padding(3))
                    .padding(8)
            }
        }
        .animation(Tokens.Motion.easeFast, value: hovered)
        .animation(Tokens.Motion.easeFast, value: isSelected)
        .onHover { hovered = $0 }
        .task(id: image.id) { await loadThumbnail() }
        .task(id: "\(image.id)|\(revision)|\(thresholds)") { await loadTile() }
    }

    /// Pass-18 (Lane N): trim notes to ~80 chars for the hover tooltip on the
    /// library thumbnail. Library is intentionally read-only for notes — full
    /// editing lives in Results' NotesPanel.
    private func notesTooltip(_ notes: String) -> String {
        let trimmed = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count <= 80 { return trimmed }
        let idx = trimmed.index(trimmed.startIndex, offsetBy: 80)
        return trimmed[..<idx] + "…"
    }

    private func loadThumbnail() async {
        // Pass-11 K6: capture the URL on the MainActor before hopping off —
        // touching a SwiftData model inside the detached task would read it
        // off-main, which is undefined behaviour.
        let url = FileStore.shared.thumbURL(for: image.id)
        let loaded = await LibraryMetricsReader.run { ImageLoader.cachedThumbnail(at: url) }
        guard !Task.isCancelled, let loaded else { return }
        thumb = loaded
    }

    /// Count badge and size bars from the image's compact cell metrics; the
    /// task is cancelled when the tile scrolls away or its inputs change.
    private func loadTile() async {
        let loaded: LibraryTile?
        do {
            loaded = try await LibraryTileLoader.shared.tile(imageId: image.id, thresholds: thresholds,
                                                              container: container)
        } catch {
            return
        }
        guard !Task.isCancelled else { return }
        tile = loaded
    }
}
