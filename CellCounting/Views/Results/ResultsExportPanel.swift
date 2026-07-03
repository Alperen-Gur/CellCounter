import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct ResultsExportPanel: View {
    @Bindable var state: AppState
    let overlayMode: OverlayMode

    @AppStorage("cc-export-folder")            private var exportFolder: String = ""
    @AppStorage("cc-export-csv-sep")           private var csvSeparator: String = ","
    @AppStorage("cc-export-timestamp")         private var appendTimestamp: Bool = true
    @AppStorage("cc-export-organize-by-batch") private var organizeByBatch: Bool = true

    @State private var lastSavedPath: String? = nil
    @State private var lastError: String? = nil
    @State private var clearWorkItem: DispatchWorkItem? = nil

    var body: some View {
        VStack(spacing: 0) {
            SectionHeader(title: "Export")
                .padding(.bottom, 0)

            VStack(spacing: 8) {
                // Pass-17: the one-click "Export sample folder" — primary CTA
                // above the per-format buttons. Writes a self-contained
                // <basename>_<timestamp>/ bundle with original + overlay +
                // CSVs + ImageJ ROIs + report.md + report.pdf.
                Button {
                    runExport(kind: .sampleFolder)
                } label: {
                    HStack(spacing: 6) {
                        Icon("download", size: 13)
                        Text("Export sample folder…")
                    }
                    .frame(maxWidth: .infinity)
                }
                .appButton(.primary, size: .sm)
                .disabled(!canExport)

                HStack(spacing: 8) {
                    Button {
                        runExport(kind: .png)
                    } label: {
                        HStack(spacing: 6) {
                            Icon("image", size: 13)
                            Text("Annotated PNG")
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .appButton(.standard, size: .sm)
                    .disabled(!canExport)

                    Button {
                        runExport(kind: .csv)
                    } label: {
                        HStack(spacing: 6) {
                            Icon("table", size: 13)
                            Text("CSV")
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .appButton(.standard, size: .sm)
                    .disabled(!canExport)
                }

                Button {
                    runExport(kind: .both)
                } label: {
                    HStack(spacing: 6) {
                        Icon("download", size: 13)
                        Text("Export both")
                    }
                    .frame(maxWidth: .infinity)
                }
                .appButton(.standard, size: .sm)
                .disabled(!canExport)

                // One-row-per-image summary CSV for the whole batch. Always
                // enabled when a batch is open; rows for unanalyzed images
                // emit blanks.
                Button {
                    runExport(kind: .summary)
                } label: {
                    HStack(spacing: 6) {
                        Icon("table", size: 13)
                        Text("Summary CSV")
                    }
                    .frame(maxWidth: .infinity)
                }
                .appButton(.standard, size: .sm)
                .disabled(state.currentBatch == nil)

                // Pass-14 (F3): ImageJ ROI export. Writes a RoiSet.zip the user
                // can drag into Fiji's ROI Manager — polygon ROIs for cells with
                // contour data, oval ROIs as a fallback.
                Button {
                    runExport(kind: .imagejROI)
                } label: {
                    HStack(spacing: 6) {
                        Icon("download", size: 13)
                        Text("Export ImageJ ROIs (.zip)")
                    }
                    .frame(maxWidth: .infinity)
                }
                .appButton(.standard, size: .sm)
                .disabled(!canExport)

                if let path = lastSavedPath {
                    HStack(spacing: 6) {
                        Icon("check", size: 11)
                            .foregroundStyle(Tokens.success)
                        Text("Saved · \(prettyPath(path))")
                            .font(.system(size: 11))
                            .foregroundStyle(Tokens.textSecondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .transition(.opacity)
                } else if let err = lastError {
                    HStack(spacing: 6) {
                        Icon("triangle-alert", size: 11)
                            .foregroundStyle(Tokens.danger)
                        Text(err)
                            .font(.system(size: 11))
                            .foregroundStyle(Tokens.textSecondary)
                            .lineLimit(2)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .transition(.opacity)
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 18)
        .animation(Tokens.Motion.ease, value: lastSavedPath)
        .animation(Tokens.Motion.ease, value: lastError)
    }

    // MARK: — Permissions

    private var canExport: Bool {
        guard let img = state.currentImage else { return false }
        return img.detection != nil
    }

    // MARK: — Export plumbing

    private enum ExportKind { case csv, png, both, summary, imagejROI, sampleFolder }

    private func runExport(kind: ExportKind) {
        let batch = state.currentBatch
        let stamp = appendTimestamp ? "-\(timestampString())" : ""

        // Pass-17: one-click sample folder. Uses an open panel scoped to
        // directories so the user picks a *parent* — the writer creates the
        // timestamped subfolder inside it.
        if kind == .sampleFolder {
            guard let image = state.currentImage else { return }
            chooseParentDir(batch: batch) { parent in
                guard let parent else { return }
                performSampleFolder(image: image, parentDir: parent)
            }
            return
        }

        // The per-batch Summary CSV doesn't require a current image — it
        // iterates every image in the batch and emits a row each.
        if kind == .summary {
            guard let batch else { return }
            let baseName = sanitize(batch.displayName)
            let defaultName = "\(baseName)_summary\(stamp).csv"
            chooseURL(defaultName: defaultName, ext: "csv", batch: batch) { url in
                guard let url else { return }
                performSummaryCSV(batch: batch, url: url)
            }
            return
        }

        guard let image = state.currentImage,
              let detection = image.detection else { return }
        let baseName = (image.fileName as NSString).deletingPathExtension

        switch kind {
        case .sampleFolder:
            // Handled above before the per-image guard; this branch keeps
            // the switch exhaustive.
            break
        case .summary:
            // Handled above before the per-image guard; this branch is
            // unreachable but keeps the switch exhaustive.
            break
        case .imagejROI:
            let defaultName = "\(baseName)_RoiSet\(stamp).zip"
            chooseURL(defaultName: defaultName, ext: "zip", batch: batch) { url in
                guard let url else { return }
                performImageJROI(detection: detection, image: image, url: url)
            }
        case .csv:
            let defaultName = "\(baseName)\(stamp).csv"
            chooseURL(defaultName: defaultName, ext: "csv", batch: batch) { url in
                guard let url else { return }
                performCSV(detection: detection, image: image, url: url)
            }
        case .png:
            let defaultName = "\(baseName)\(stamp).png"
            chooseURL(defaultName: defaultName, ext: "png", batch: batch) { url in
                guard let url else { return }
                performPNG(detection: detection, image: image, url: url)
            }
        case .both:
            // PNG first, then CSV — two save panels back-to-back.
            let pngName = "\(baseName)\(stamp).png"
            chooseURL(defaultName: pngName, ext: "png", batch: batch) { pngURL in
                guard let pngURL else { return }
                performPNG(detection: detection, image: image, url: pngURL) {
                    let csvName = "\(baseName)\(stamp).csv"
                    chooseURL(defaultName: csvName, ext: "csv", batch: batch, startingAt: pngURL.deletingLastPathComponent()) { csvURL in
                        guard let csvURL else { return }
                        performCSV(detection: detection, image: image, url: csvURL)
                    }
                }
            }
        }
    }

    /// Pass-17: open panel scoped to directories — the user picks where the
    /// sample folder should be created. The orchestrator creates a fresh
    /// `<basename>_<timestamp>/` inside the picked parent.
    private func chooseParentDir(batch: BatchRecord?,
                                 completion: @escaping (URL?) -> Void) {
        let panel = NSOpenPanel()
        panel.title = "Choose parent folder for sample bundle"
        panel.prompt = "Choose"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        if let dir = defaultDirectory(for: batch) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            panel.directoryURL = dir
        }
        panel.begin { resp in
            completion(resp == .OK ? panel.url : nil)
        }
    }

    private func chooseURL(defaultName: String,
                           ext: String,
                           batch: BatchRecord?,
                           startingAt overrideDir: URL? = nil,
                           completion: @escaping (URL?) -> Void) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = defaultName
        if let utype = UTType(filenameExtension: ext) { panel.allowedContentTypes = [utype] }
        if let dir = overrideDir ?? defaultDirectory(for: batch) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            panel.directoryURL = dir
        }
        panel.begin { resp in
            completion(resp == .OK ? panel.url : nil)
        }
    }

    private func defaultDirectory(for batch: BatchRecord?) -> URL? {
        let root: URL
        if !exportFolder.isEmpty {
            // Prefer the security-scoped bookmark when present — the raw path
            // string alone won't work after a relaunch under the sandbox.
            // The caller is responsible for stopping access via withCustomFolderAccess.
            if let bookmarked = SecurityBookmarks.resolve("cc-export-folder-bookmark") {
                // We started access; immediately stop here and re-resolve in the
                // write path. This call is only used to compute panel.directoryURL.
                let url = bookmarked
                SecurityBookmarks.stop(bookmarked)
                root = url
            } else {
                root = URL(fileURLWithPath: exportFolder, isDirectory: true)
            }
        } else {
            root = FileStore.shared.defaultUserExports
        }
        if organizeByBatch, let batch {
            return root.appendingPathComponent(sanitize(batch.displayName), isDirectory: true)
        }
        return root
    }

    /// Runs `body` with security-scoped access to the user-picked export folder
    /// (when one is configured). The NSSavePanel result URL already carries an
    /// implicit grant, but writes that fall under the custom folder also need
    /// the parent bookmark to be active.
    private func withCustomFolderAccess<T>(_ body: () throws -> T) rethrows -> T {
        guard !exportFolder.isEmpty else { return try body() }
        let url = SecurityBookmarks.resolve("cc-export-folder-bookmark")
        defer { SecurityBookmarks.stop(url) }
        return try body()
    }

    /// Pass-17: orchestrate the full sample-folder bundle. Runs every writer
    /// in sequence inside `withCustomFolderAccess` and surfaces a summary in
    /// the inline status row. Sub-writer failures don't abort the whole run.
    private func performSampleFolder(image: ImageRecord, parentDir: URL) {
        // `writeSampleFolder` is now async: it offloads the heavy PNG
        // compositing, CSV building, and the ImageJ-ROI Python subprocess to
        // background tasks so the window stays responsive during the export.
        // We keep security-scoped access to the custom export folder open across
        // the await (the synchronous `withCustomFolderAccess` helper can't span
        // an async boundary because its `defer` fires too early).
        let scoped = exportFolder.isEmpty ? nil : SecurityBookmarks.resolve("cc-export-folder-bookmark")
        Task { @MainActor in
            defer { SecurityBookmarks.stop(scoped) }
            do {
                let result = try await ExportService.writeSampleFolder(image: image,
                                                                       state: state,
                                                                       overlayMode: overlayMode,
                                                                       parentDir: parentDir)
                if result.errors.isEmpty {
                    flashSaved(result.folder.path)
                } else {
                    let firstErr = result.errors.first!
                    let msg = "Saved \(result.folder.lastPathComponent) (\(result.errors.count) of \(result.written.count + result.errors.count) files failed: \(firstErr.filename) — \(firstErr.error.localizedDescription))"
                    lastSavedPath = result.folder.path
                    lastError = msg
                    scheduleClear()
                }
            } catch {
                flashError(error.localizedDescription)
            }
        }
    }

    /// Per-batch summary CSV — one row per image with cell-count aggregations,
    /// flag percentages, colony stats, and QC scalars.
    /// Pass-15: use the current-image effective cutoff as the batch-wide
    /// cutoff. When no current image is loaded, fall back to the global
    /// confidence.
    private func performSummaryCSV(batch: BatchRecord, url: URL) {
        let conf: Double = {
            if let img = state.currentImage { return state.effectiveConfidence(for: img) }
            return state.confidence
        }()
        do {
            try withCustomFolderAccess {
                try ExportService.writePerImageSummaryCSV(
                    batch: batch,
                    thresholds: state.thresholds,
                    pxPerUm: state.pxPerUm,
                    confidence: conf,
                    separator: csvSeparator.isEmpty ? "," : csvSeparator,
                    to: url
                )
            }
            flashSaved(url.path)
        } catch {
            flashError(error.localizedDescription)
        }
    }

    /// Pass-14 (F3): export ImageJ-compatible RoiSet.zip via the Python helper.
    /// Pass-15: thread effective confidence + thresholds + model so the helper
    /// can filter and write a sibling RoiSet.config.txt.
    private func performImageJROI(detection: DetectionRecord, image: ImageRecord, url: URL) {
        let conf = state.effectiveConfidence(for: image)
        let modelId = state.currentBatch?.modelId ?? state.activeModelId
        // Snapshot the model values on the main actor, then run the blocking
        // Python subprocess off-main so the UI doesn't freeze during export.
        let cells = detection.cells
        let widthPx = image.widthPx
        let heightPx = image.heightPx
        let fileName = image.fileName
        let thresholds = state.thresholds
        let pxPerUm = state.pxPerUm
        let scoped = exportFolder.isEmpty ? nil : SecurityBookmarks.resolve("cc-export-folder-bookmark")
        Task { @MainActor in
            defer { SecurityBookmarks.stop(scoped) }
            do {
                try await Task.detached {
                    try ExportService.writeImageJROIsCore(cells: cells,
                                                          imageWidthPx: widthPx,
                                                          imageHeightPx: heightPx,
                                                          imageFileName: fileName,
                                                          thresholds: thresholds,
                                                          pxPerUm: pxPerUm,
                                                          confidence: conf,
                                                          modelId: modelId,
                                                          to: url)
                }.value
                flashSaved(url.path)
            } catch {
                flashError(error.localizedDescription)
            }
        }
    }

    private func performCSV(detection: DetectionRecord, image: ImageRecord, url: URL) {
        // Pass-15: thread the effective confidence + model id so the CSV's
        // `# confidence=…; bins=…; model=…; pxPerUm=…` header is honest and
        // the row count matches what the user sees in the UI.
        let conf = state.effectiveConfidence(for: image)
        let modelId = state.currentBatch?.modelId ?? state.activeModelId
        // Snapshot on main, build + write the CSV off-main.
        let cells = detection.cells
        let fileName = image.fileName
        let thresholds = state.thresholds
        let pxPerUm = state.pxPerUm
        let sep = csvSeparator.isEmpty ? "," : csvSeparator
        let scoped = exportFolder.isEmpty ? nil : SecurityBookmarks.resolve("cc-export-folder-bookmark")
        Task { @MainActor in
            defer { SecurityBookmarks.stop(scoped) }
            do {
                try await Task.detached {
                    try ExportService.writeCSVCore(cells: cells,
                                                   imageFileName: fileName,
                                                   thresholds: thresholds,
                                                   pxPerUm: pxPerUm,
                                                   confidence: conf,
                                                   modelId: modelId,
                                                   separator: sep,
                                                   to: url)
                }.value
                flashSaved(url.path)
            } catch {
                flashError(error.localizedDescription)
            }
        }
    }

    private func performPNG(detection: DetectionRecord,
                            image: ImageRecord,
                            url: URL,
                            then: (() -> Void)? = nil) {
        // Pass-15: filter the burned-in overlay to the effective cutoff too,
        // matching the on-screen render.
        let conf = state.effectiveConfidence(for: image)
        // Snapshot on main, composite the full-res PNG off-main so the window
        // doesn't freeze while a large TIFF is decoded + drawn.
        let imageURL = image.storedURL
        let cells = detection.cells
        let thresholds = state.thresholds
        let pxPerUm = state.pxPerUm
        let overlay = overlayMode
        let scoped = exportFolder.isEmpty ? nil : SecurityBookmarks.resolve("cc-export-folder-bookmark")
        Task { @MainActor in
            defer { SecurityBookmarks.stop(scoped) }
            do {
                try await Task.detached {
                    try ExportService.compositeAnnotatedPNG(imageURL: imageURL,
                                                            cells: cells,
                                                            thresholds: thresholds,
                                                            pxPerUm: pxPerUm,
                                                            overlayMode: overlay,
                                                            confidence: conf,
                                                            to: url)
                }.value
                flashSaved(url.path)
                then?()
            } catch {
                flashError(error.localizedDescription)
            }
        }
    }

    // MARK: — Feedback

    private func flashSaved(_ path: String) {
        lastError = nil
        lastSavedPath = path
        scheduleClear()
    }

    private func flashError(_ message: String) {
        lastSavedPath = nil
        lastError = message
        scheduleClear()
    }

    private func scheduleClear() {
        clearWorkItem?.cancel()
        let item = DispatchWorkItem {
            withAnimation(Tokens.Motion.ease) {
                lastSavedPath = nil
                lastError = nil
            }
        }
        clearWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0, execute: item)
    }

    // MARK: — Helpers

    private func sanitize(_ name: String) -> String {
        let bad = CharacterSet(charactersIn: "/\\:*?\"<>|")
        return name.components(separatedBy: bad).joined(separator: "_")
    }

    private func timestampString() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f.string(from: Date())
    }

    private func prettyPath(_ path: String) -> String {
        let home = NSHomeDirectory()
        if path.hasPrefix(home) {
            return "~" + String(path.dropFirst(home.count))
        }
        return path
    }
}
