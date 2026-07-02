import SwiftUI
import AppKit

// MARK: — Main View

struct ImagesLibraryView: View {
    @Bindable var state: AppState

    @State private var images: [ImageRecord] = []
    @State private var selectedIDs: Set<UUID> = []
    @State private var multiSelectMode = false
    @State private var showFindDuplicates = false
    @State private var isHashingForDupes = false

    private let columns = [
        GridItem(.adaptive(minimum: 180, maximum: 240), spacing: 14)
    ]

    var body: some View {
        Group {
            if images.isEmpty {
                EmptyStateView(
                    title: "No images yet",
                    subtitle: "Drop microscope images on Home to get started.",
                    symbol: "photo.on.rectangle.angled"
                )
            } else {
                VStack(spacing: 0) {
                    // Toolbar strip
                    HStack(spacing: 10) {
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
                        let nameMap = disambiguatedNames()
                        LazyVGrid(columns: columns, spacing: 14) {
                            ForEach(images, id: \.id) { image in
                                ImageThumbCell(
                                    image: image,
                                    displayName: nameMap[image.id] ?? image.fileName,
                                    state: state,
                                    isSelected: selectedIDs.contains(image.id),
                                    multiSelectMode: multiSelectMode,
                                    onTap: { handleTap(image: image) },
                                    onDelete: { confirmDelete(image: image) }
                                )
                            }
                        }
                        .padding(20)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Tokens.bg)
        .onAppear { reload() }
        // Refresh when detections land or images are added.
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("ccCorrectionsChanged"))) { _ in reload() }
        .sheet(isPresented: $showFindDuplicates) {
            FindDuplicatesSheet(state: state, onDismiss: { showFindDuplicates = false; reload() })
        }
        // Delete — delete selected image(s) with confirmation
        .overlay(
            Group {
                Button("") {
                    if !selectedIDs.isEmpty { deleteSelected() }
                    else if let first = images.first { confirmDelete(image: first) }
                }
                .keyboardShortcut(.delete, modifiers: [])
                .hidden()
                .allowsHitTesting(false)
                // ⌘A — select all
                Button("") {
                    multiSelectMode = true
                    selectedIDs = Set(images.map(\.id))
                }
                .keyboardShortcut("a", modifiers: [.command])
                .hidden()
                .allowsHitTesting(false)
            }
        )
        // Enter — open selected (first selected or first image) in Results
        .onKeyPress(.return) {
            if let firstSelected = selectedIDs.first,
               let image = images.first(where: { $0.id == firstSelected }) {
                handleTap(image: image)
                return .handled
            }
            return .ignored
        }
    }

    // MARK: — Helpers

    private func reload() {
        images = state.repos.allImages()
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

        // Snapshot storedURLs and ids off-main-safe values.
        let pairs: [(UUID, URL)] = needsHash.map { ($0.id, $0.storedURL) }
        let reposRef = state.repos

        Task.detached(priority: .userInitiated) {
            for (imageId, url) in pairs {
                guard let hash = ImageLoader.sha256Hex(of: url) else { continue }
                await MainActor.run {
                    // Look up the live record by id and write the hash.
                    let all = reposRef.allImages()
                    if let img = all.first(where: { $0.id == imageId }) {
                        reposRef.setFileHash(hash, on: img)
                    }
                }
            }
            await MainActor.run {
                isHashingForDupes = false
                showFindDuplicates = true
            }
        }
    }

    /// Returns disambiguated display names for images that share the same fileName.
    /// Duplicates get _2, _3, … appended so the grid label is always unique.
    private func disambiguatedNames() -> [UUID: String] {
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

    private func handleTap(image: ImageRecord) {
        if multiSelectMode {
            if selectedIDs.contains(image.id) {
                selectedIDs.remove(image.id)
            } else {
                selectedIDs.insert(image.id)
            }
            return
        }
        // Navigate to results for this image.
        guard let batch = image.batch else { return }
        state.currentBatchId = batch.id
        let sorted = batch.images.sorted { $0.importedAt < $1.importedAt }
        if let idx = sorted.firstIndex(where: { $0.id == image.id }) {
            state.currentImageIdx = idx
        }
        state.view = .results
    }

    private func confirmDelete(image: ImageRecord) {
        let alert = NSAlert()
        alert.messageText = "Delete \"\(image.fileName)\"?"
        alert.informativeText = "This removes the image and its detection. This cannot be undone."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            state.repos.deleteImage(image)
            NotificationCenter.default.post(name: Notification.Name("ccLibraryChanged"), object: nil)
            reload()
        }
    }

    private func deleteSelected() {
        let idsToDelete = selectedIDs
        let toDelete = images.filter { idsToDelete.contains($0.id) }
        let alert = NSAlert()
        alert.messageText = "Delete \(toDelete.count) image\(toDelete.count == 1 ? "" : "s")?"
        alert.informativeText = "This removes the images and their detections. This cannot be undone."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            for image in toDelete {
                state.repos.deleteImage(image)
            }
            NotificationCenter.default.post(name: Notification.Name("ccLibraryChanged"), object: nil)
            selectedIDs = []
            reload()
        }
    }
}

// MARK: — Thumbnail Cell

private struct ImageThumbCell: View {
    let image: ImageRecord
    /// Disambiguated display name — may differ from image.fileName when multiple
    /// images in the batch share the same original filename (e.g. plate01.tif _2, _3).
    let displayName: String
    @Bindable var state: AppState
    let isSelected: Bool
    let multiSelectMode: Bool
    let onTap: () -> Void
    let onDelete: () -> Void

    @State private var hovered = false
    @State private var thumb: NSImage? = nil

    @Environment(AppTheme.self) private var theme

    private var cellCount: Int {
        image.detection?.cells.count ?? 0
    }

    private var distNorm: [Double]? {
        guard let det = image.detection else { return nil }
        let cells = det.cells
        guard !cells.isEmpty else { return nil }
        let thresholds = image.batch?.thresholds ?? state.thresholds
        var bins = Array(repeating: 0.0, count: max(thresholds.count + 1, 5))
        for c in cells {
            let idx = min(BinMath.binIndex(for: c.diameter, thresholds: thresholds), bins.count - 1)
            bins[idx] += 1
        }
        while bins.count < 5 { bins.append(0) }
        let m = bins.prefix(5).max() ?? 1
        return Array(bins.prefix(5)).map { m > 0 ? $0 / m * 100 : 0 }
    }

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
                        if image.detection != nil {
                            VStack {
                                Spacer()
                                HStack {
                                    Spacer()
                                    Text("\(cellCount) cells")
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
        .onAppear { loadThumb() }
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

    private func loadThumb() {
        // Pass-11 K6: capture the URL on the MainActor before hopping off —
        // touching `image.thumbURL` inside the detached Task would read a
        // SwiftData @Model property off-main, which is undefined behaviour
        // (and may crash under aggressive isolation checking).
        let url = image.thumbURL
        Task.detached(priority: .utility) {
            let img = NSImage(contentsOf: url)
            await MainActor.run { thumb = img }
        }
    }
}
