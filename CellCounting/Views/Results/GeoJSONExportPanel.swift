import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// GeoJSON export button for the Results sidebar — the QuPath/Shapely/GIS
/// counterpart to `ResultsExportPanel`'s "Export ImageJ ROIs (.zip)" button,
/// styled to match its sibling buttons exactly (same `appButton` variant,
/// same inline saved/error row).
///
/// NOT YET WIRED UP: this is a self-contained drop-in — add
/// `GeoJSONExportPanel(state: state)` next to
/// `ResultsExportPanel(state: state, overlayMode: overlayMode)` in
/// `ResultsView.swift` (that file composes `ColoniesPanel` / `NotesPanel` /
/// `AnalysisPanel` / `ResultsExportPanel` in sequence in its Results
/// sidebar). `ResultsView.swift` is outside this agent's ownership for this
/// pass — see the task's file-ownership list — so this view exists and works
/// standalone but isn't referenced from the view tree yet.
struct GeoJSONExportPanel: View {
    @Bindable var state: AppState

    @State private var lastSavedPath: String? = nil
    @State private var lastError: String? = nil
    @State private var clearWorkItem: DispatchWorkItem? = nil

    private var canExport: Bool {
        guard let img = state.currentImage else { return false }
        return img.detection != nil
    }

    var body: some View {
        VStack(spacing: 8) {
            Button {
                presentGeoJSONExport(state: state) { result in
                    switch result {
                    case .success(let url): flashSaved(url.path)
                    case .failure(let error): flashError(error.localizedDescription)
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Icon("download", size: 13)
                    Text("Export GeoJSON (.geojson)")
                }
                .frame(maxWidth: .infinity)
            }
            .appButton(.standard, size: .sm)
            .disabled(!canExport)
            .help("One Polygon Feature per cell, in image pixel coordinates — drag straight into QuPath, or open with Shapely/GeoPandas.")

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
        .animation(Tokens.Motion.ease, value: lastSavedPath)
        .animation(Tokens.Motion.ease, value: lastError)
    }

    // MARK: — Feedback (mirrors ResultsExportPanel's inline row timing exactly)

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

    private func prettyPath(_ path: String) -> String {
        let home = NSHomeDirectory()
        if path.hasPrefix(home) {
            return "~" + String(path.dropFirst(home.count))
        }
        return path
    }
}

/// Shared export orchestration: presents a save panel for the CURRENT
/// image's detection, then runs `GeoJSONExporter.write` off the main actor
/// (mirrors `ResultsExportPanel.performImageJROI`'s
/// snapshot-on-main/write-off-main shape exactly) and reports the outcome
/// via `onResult`.
///
/// Factored out as a free function (rather than private to
/// `GeoJSONExportPanel`) so both that panel's button AND the
/// "Export GeoJSON…" menu command (`AnalysisProtocolCommands.swift`) drive
/// the identical flow instead of two copies drifting apart. Each caller
/// picks its own feedback presentation — an inline row here, a toast via
/// `AppState.flashExport` for the menu command.
@MainActor
func presentGeoJSONExport(state: AppState, onResult: @escaping (Result<URL, Error>) -> Void) {
    guard let image = state.currentImage, let detection = image.detection else { return }
    let baseName = (image.fileName as NSString).deletingPathExtension

    let panel = NSSavePanel()
    panel.title = "Export GeoJSON"
    panel.prompt = "Export"
    panel.nameFieldStringValue = "\(baseName).geojson"
    if let utype = UTType(filenameExtension: "geojson") { panel.allowedContentTypes = [utype] }

    panel.begin { resp in
        guard resp == .OK, let url = panel.url else { return }

        // Snapshot plain values on the main actor, then run the (cheap but
        // non-zero for large detections) encode off it — same pattern
        // ExportService's CSV/ROI writers use from ResultsExportPanel.
        let conf = state.effectiveConfidence(for: image)
        let modelId = state.currentBatch?.modelId ?? state.activeModelId
        let cells = detection.cells
        let widthPx = image.widthPx
        let heightPx = image.heightPx
        let fileName = image.fileName
        let thresholds = state.thresholds
        let pxPerUm = state.pxPerUm

        Task { @MainActor in
            do {
                try await Task.detached {
                    try GeoJSONExporter.write(cells: cells,
                                              imageFileName: fileName,
                                              imageWidthPx: widthPx,
                                              imageHeightPx: heightPx,
                                              thresholds: thresholds,
                                              pxPerUm: pxPerUm,
                                              confidence: conf,
                                              modelId: modelId,
                                              to: url)
                }.value
                onResult(.success(url))
            } catch {
                onResult(.failure(error))
            }
        }
    }
}
