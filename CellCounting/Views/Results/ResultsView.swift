import SwiftUI
import AppKit
import SwiftData
import UniformTypeIdentifiers

// MARK: — Main view

struct ResultsView: View {
    @Bindable var state: AppState
    /// Pass-15: full-screen edit mode. Owned by RootView so it can also collapse
    /// the left AppSidebar and the top AppToolbar; this view collapses its own
    /// ResultsSidebar + BatchStrip when set, and surfaces the toggle in the
    /// viewer's right-side toolbar pill.
    @Binding var fullScreenEdit: Bool

    @State private var overlayMode: OverlayMode = .bbox
    @State private var showOverlay: Bool = true
    @State private var zoom: Double = 1.0
    @State private var editorMode: EditableOverlay.EditorMode = .view
    @State private var roiMode: ROIMode = .off
    @State private var profileMode: Bool = false
    // Pass-14 (F3): independent toggles for filled masks vs outline strokes.
    // `X` toggles fills, `Z` toggles outlines; `Space` flips the master
    // `showOverlay` (composite of both off / both on).
    @State private var showMaskFills: Bool = true
    @State private var showOutlines: Bool = true
    // Pass-15 (A2): multi-selection set shared between EditableOverlay and the
    // Cell-Edit toolbar's "delete selected" override.
    @State private var selectedCellIds: Set<UUID> = []

    var body: some View {
        if state.currentBatch == nil {
            EmptyStateView(
                title: "No analysis open",
                subtitle: "Drop a microscope image on the Home screen to start a new analysis.",
                symbol: "photo.stack"
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Tokens.bg)
        } else if state.currentBatch?.images.isEmpty == true {
            // Batch exists but holds zero images — typically a stale Recent
            // row, or right after a failed import before cleanup fires. We
            // render the empty state instead of the viewer.
            EmptyBatchState(state: state)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Tokens.bg)
        } else {
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    ViewerPanel(
                        state: state,
                        overlayMode: $overlayMode,
                        showOverlay: $showOverlay,
                        showMaskFills: $showMaskFills,
                        showOutlines: $showOutlines,
                        zoom: $zoom,
                        editorMode: $editorMode,
                        roiMode: $roiMode,
                        profileMode: $profileMode,
                        fullScreenEdit: $fullScreenEdit,
                        selectedCellIds: $selectedCellIds
                    )
                    // Pass-15: hide the batch strip in full-screen edit mode so
                    // the canvas can use the entire vertical extent of the window.
                    if !fullScreenEdit {
                        BatchStrip(state: state)
                            .frame(height: 96)
                    }
                }
                // Pass-15: hide the results sidebar in full-screen edit mode.
                if !fullScreenEdit {
                    ResultsSidebar(state: state,
                                   overlayMode: overlayMode,
                                   profileMode: $profileMode)
                        .frame(width: 360)
                }
            }
            // Pass-17 Lane C: EXIF calibration toast — shown when metadata-based
            // calibration was applied to this batch. Auto-dismisses after 5 s.
            .overlay(alignment: .top) {
                if let note = state.lastCalibrationNote {
                    ExifCalibrationToast(message: note)
                        .transition(.move(edge: .top).combined(with: .opacity))
                        .padding(.top, 10)
                        .animation(Tokens.Motion.ease, value: state.lastCalibrationNote)
                }
            }
            // Export feedback for the ⌘E / ⌘⇧E keyboard shortcuts — mirrors the
            // inline confirmation the ResultsExportPanel buttons show, so a
            // shortcut export is never silent (finding: results-export-silent-shortcuts).
            .overlay(alignment: .bottom) {
                if let toast = state.exportToast {
                    ExportFeedbackToast(message: toast.message, isError: toast.isError)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                        .padding(.bottom, 14)
                        .animation(Tokens.Motion.ease, value: state.exportToast?.message)
                }
            }
            .focusable()
            .focusEffectDisabled()
            // Space — master overlay toggle. Either both fills + outlines on,
            // or both off. When the user toggled them independently via X/Z,
            // Space brings them back into a consistent state.
            .onKeyPress(.space) {
                withAnimation(Tokens.Motion.easeFast) {
                    showOverlay.toggle()
                    if showOverlay {
                        showMaskFills = true
                        showOutlines = true
                    } else {
                        showMaskFills = false
                        showOutlines = false
                    }
                }
                return .handled
            }
            // X — toggle filled masks only (F1's colored mask render).
            .onKeyPress(.init("x")) {
                withAnimation(Tokens.Motion.easeFast) {
                    showMaskFills.toggle()
                    showOverlay = showMaskFills || showOutlines
                }
                return .handled
            }
            // Z — toggle outline strokes only.
            .onKeyPress(.init("z")) {
                withAnimation(Tokens.Motion.easeFast) {
                    showOutlines.toggle()
                    showOverlay = showMaskFills || showOutlines
                }
                return .handled
            }
            // ⌘+ zoom in, ⌘- zoom out, ⌘0 fit
            // Pass-15: upper bound raised to 4.0x to take advantage of the new
            // ScrollView pan + magnification gesture in the viewer.
            .onKeyPress(keys: [.init("+"), .init("=")]) { press in
                guard press.modifiers.contains(.command) else { return .ignored }
                zoom = min(4.0, zoom + 0.15)
                return .handled
            }
            .onKeyPress(keys: [.init("-")]) { press in
                guard press.modifiers.contains(.command) else { return .ignored }
                zoom = max(0.4, zoom - 0.15)
                return .handled
            }
            .onKeyPress(keys: [.init("0")]) { press in
                guard press.modifiers.contains(.command) else { return .ignored }
                // Fit-to-view: zoom = 1.0 means "image fits the visible viewport"
                // because RealImageViewer multiplies the fit-scale by `zoom`.
                withAnimation(Tokens.Motion.ease) { zoom = 1.0 }
                return .handled
            }
            // ⌘1 box overlay, ⌘2 outline overlay
            .onKeyPress(keys: [.init("1")]) { press in
                guard press.modifiers.contains(.command) else { return .ignored }
                overlayMode = .bbox
                return .handled
            }
            .onKeyPress(keys: [.init("2")]) { press in
                guard press.modifiers.contains(.command) else { return .ignored }
                overlayMode = .outline
                return .handled
            }
            // Pass-15 (A2): Delete / Backspace — bulk-delete the current
            // multi-selection. EditableOverlay handles this when it has focus;
            // this fallback fires when focus is elsewhere in the Results pane.
            // Empty-selection is a no-op (never deletes random cells).
            .onKeyPress(.delete) {
                guard editorMode == .view, !selectedCellIds.isEmpty else { return .ignored }
                deleteSelectedCells()
                return .handled
            }
            .onKeyPress(.deleteForward) {
                guard editorMode == .view, !selectedCellIds.isEmpty else { return .ignored }
                deleteSelectedCells()
                return .handled
            }
            // ← / → navigate images
            .onKeyPress(.leftArrow) {
                guard !sortedImages.isEmpty else { return .ignored }
                let newIdx = max(0, state.currentImageIdx - 1)
                withAnimation(Tokens.Motion.easeFast) { state.currentImageIdx = newIdx }
                return .handled
            }
            .onKeyPress(.rightArrow) {
                guard !sortedImages.isEmpty else { return .ignored }
                let newIdx = min(sortedImages.count - 1, state.currentImageIdx + 1)
                withAnimation(Tokens.Motion.easeFast) { state.currentImageIdx = newIdx }
                return .handled
            }
            // Esc — exit edit mode, then full-screen.
            // Pass-15: Esc first exits any active edit submode (add/remove/merge/
            // manualCount) back to .view, then on a subsequent press exits
            // full-screen edit. This matches the user's mental "back-out" flow.
            .onKeyPress(.escape) {
                if editorMode != .view {
                    editorMode = .view
                    return .handled
                }
                if fullScreenEdit {
                    withAnimation(Tokens.Motion.ease) { fullScreenEdit = false }
                    return .handled
                }
                return .ignored
            }
            // Hidden buttons for ⌘E / ⌘⇧E / ⌘R / ⌘⇧F — fired via .keyboardShortcut
            .overlay(
                Group {
                    Button("") { exportAnnotatedPNG() }
                        .keyboardShortcut("e", modifiers: [.command])
                        .hidden()
                        .allowsHitTesting(false)
                    Button("") { exportBoth() }
                        .keyboardShortcut("e", modifiers: [.command, .shift])
                        .hidden()
                        .allowsHitTesting(false)
                    Button("") { rerunDetection() }
                        .keyboardShortcut("r", modifiers: [.command])
                        .hidden()
                        .allowsHitTesting(false)
                    // Pass-15: ⌘⇧F toggles full-screen edit mode.
                    Button("") {
                        withAnimation(Tokens.Motion.ease) { fullScreenEdit.toggle() }
                    }
                    .keyboardShortcut("f", modifiers: [.command, .shift])
                    .hidden()
                    .allowsHitTesting(false)
                }
            )
        }
    }

    private var sortedImages: [ImageRecord] {
        (state.currentBatch?.images ?? []).sorted(by: { $0.importedAt < $1.importedAt })
    }

    /// Thresholds to use for display/binning/export — prefer the batch's persisted
    /// thresholds so analyses are reproducible, falling back to the live global setting.
    private var batchThresholds: [Double] {
        state.currentBatch?.thresholds ?? state.thresholds
    }

    private func exportAnnotatedPNG() {
        guard let image = state.currentImage, let detection = image.detection else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = (image.fileName as NSString).deletingPathExtension + "-annotated.png"
        // Snapshot the SwiftData-backed values on the main actor before the save
        // panel's completion closure fires, so the heavy compositing can run off
        // the MainActor without touching the model graph.
        let conf = state.effectiveConfidence(for: image)
        let imageURL = image.storedURL
        let cells = detection.cells
        let thresholds = batchThresholds
        let pxPerUm = state.pxPerUm
        let overlay = overlayMode
        panel.begin { resp in
            guard resp == .OK, let url = panel.url else { return }
            Task.detached {
                do {
                    try ExportService.compositeAnnotatedPNG(imageURL: imageURL,
                                                            cells: cells,
                                                            thresholds: thresholds,
                                                            pxPerUm: pxPerUm,
                                                            overlayMode: overlay,
                                                            confidence: conf,
                                                            to: url)
                    await state.flashExport("Saved · \(url.lastPathComponent)", isError: false)
                } catch {
                    await state.flashExport("Export failed: \(error.localizedDescription)", isError: true)
                }
            }
        }
    }

    private func exportBoth() {
        guard let image = state.currentImage, let detection = image.detection else { return }
        let base = (image.fileName as NSString).deletingPathExtension
        let pngPanel = NSSavePanel()
        pngPanel.allowedContentTypes = [.png]
        pngPanel.nameFieldStringValue = base + "-annotated.png"
        // Snapshot everything the writers need up front (main actor) so both
        // file writes run off the MainActor.
        let conf = state.effectiveConfidence(for: image)
        let modelId = state.currentBatch?.modelId ?? state.activeModelId
        let imageURL = image.storedURL
        let cells = detection.cells
        let imageFileName = image.fileName
        let thresholds = batchThresholds
        let pxPerUm = state.pxPerUm
        let overlay = overlayMode
        pngPanel.begin { resp in
            guard resp == .OK, let pngURL = pngPanel.url else { return }
            let csvPanel = NSSavePanel()
            csvPanel.allowedContentTypes = [.commaSeparatedText]
            csvPanel.nameFieldStringValue = base + ".csv"
            csvPanel.directoryURL = pngURL.deletingLastPathComponent()
            csvPanel.begin { resp2 in
                guard resp2 == .OK, let csvURL = csvPanel.url else {
                    // User cancelled the CSV step — still write the PNG.
                    Task.detached {
                        do {
                            try ExportService.compositeAnnotatedPNG(imageURL: imageURL, cells: cells,
                                                                    thresholds: thresholds, pxPerUm: pxPerUm,
                                                                    overlayMode: overlay, confidence: conf, to: pngURL)
                            await state.flashExport("Saved · \(pngURL.lastPathComponent)", isError: false)
                        } catch {
                            await state.flashExport("Export failed: \(error.localizedDescription)", isError: true)
                        }
                    }
                    return
                }
                Task.detached {
                    do {
                        try ExportService.compositeAnnotatedPNG(imageURL: imageURL, cells: cells,
                                                                thresholds: thresholds, pxPerUm: pxPerUm,
                                                                overlayMode: overlay, confidence: conf, to: pngURL)
                        try ExportService.writeCSVCore(cells: cells, imageFileName: imageFileName,
                                                       thresholds: thresholds, pxPerUm: pxPerUm,
                                                       confidence: conf, modelId: modelId,
                                                       separator: ",", to: csvURL)
                        await state.flashExport("Saved · \(pngURL.lastPathComponent) + \(csvURL.lastPathComponent)", isError: false)
                    } catch {
                        await state.flashExport("Export failed: \(error.localizedDescription)", isError: true)
                    }
                }
            }
        }
    }

    private func rerunDetection() {
        // Re-run detection on the current image, mirroring the
        // DetectionFailedBanner path. Guards on isRerunning + canRunDetection so
        // ⌘R doesn't spawn a duplicate subprocess or land on a stuck Processing
        // screen when no detector is available.
        guard let image = state.currentImage else { return }
        guard state.canRunDetection, !state.isRerunning(image) else { return }
        state.reRunDetection(on: image)
    }

    /// Pass-15 (A2): delete every cell in `selectedCellIds` from the current
    /// image's detection. Mirrors EditableOverlay.deleteCurrentSelection so the
    /// keyboard shortcut still works when the overlay doesn't hold focus.
    /// Empty-selection is a no-op. The mutation itself lives on AppState.removeCells.
    fileprivate func deleteSelectedCells() {
        state.removeCells(selectedCellIds)
        selectedCellIds.removeAll()
        // removeCells mutates detection.cells directly and posts no signal, so
        // notify observers (incl. RealImageViewer's liveCells mirror) to resync
        // (finding: overlay-stale-after-nonhandleedit-mutations).
        NotificationCenter.default.post(name: .ccCorrectionsChanged,
                                        object: state.currentImage?.id)
    }
}

// MARK: — Viewer

private struct ViewerPanel: View {
    @Bindable var state: AppState
    @Binding var overlayMode: OverlayMode
    @Binding var showOverlay: Bool
    // Pass-14 (F3): independent mask/outline toggles plumbed through to the
    // real-image viewer. `showMaskFills` is read by F1's colored-mask render
    // branch inside EditableOverlay; `showOutlines` gates the outline stroke
    // render at the wrapping-view level so today's build doesn't depend on
    // F1's branch landing first.
    @Binding var showMaskFills: Bool
    @Binding var showOutlines: Bool
    @Binding var zoom: Double
    @Binding var editorMode: EditableOverlay.EditorMode
    @Binding var roiMode: ROIMode
    @Binding var profileMode: Bool
    @Binding var fullScreenEdit: Bool
    // Pass-15 (A2): multi-selection set bound from ResultsView.
    @Binding var selectedCellIds: Set<UUID>

    /// Pass-15: cumulative reading from the in-flight pinch — used to derive
    /// a per-tick delta into the committed `zoom` Binding.
    @State private var pinchScale: CGFloat = 1.0

    /// Pass-17 (Lane B): bumps on `.ccAnnotationsChanged` so the status pill
    /// re-reads `annotationCountForCurrentImage`.
    @State private var annotationsTick: Int = 0

    /// Count of ground-truth annotations on the current image. Reads from the
    /// repo; cheap, no caching needed because the pill is small.
    private var annotationCountForCurrentImage: Int {
        guard let id = state.currentImage?.id else { return 0 }
        _ = annotationsTick
        return state.repos.annotations(for: id).count
    }

    /// Pinch / cmd-scroll magnification. Drives `zoom` directly so the
    /// ScrollView's content size reflows and scrollbars appear when needed.
    private var magnifyGesture: some Gesture {
        MagnificationGesture()
            .onChanged { value in
                let delta = max(0.0001, value / pinchScale)
                let proposed = zoom * Double(delta)
                zoom = min(4.0, max(0.4, proposed))
                pinchScale = value
            }
            .onEnded { _ in pinchScale = 1.0 }
    }

    var body: some View {
        // B4-5: wrap in GeometryReader so maxW/maxH follow the actual viewer size
        GeometryReader { geo in
            // Pass-15: when full-screen edit is on, let the canvas use the whole
            // window; otherwise keep the original cap so the image doesn't grow
            // wider than the side-panel layout intended.
            let maxW: CGFloat = fullScreenEdit
                ? max(geo.size.width - 40, 200)
                : min(geo.size.width - 40, 780)
            let maxH: CGFloat = fullScreenEdit
                ? max(geo.size.height - 40, 200)
                : min(geo.size.height - 40, 520)
            ZStack {
                CheckerBackground()

                // Pass-15: wrap the image+overlay in a ScrollView so two-finger
                // scroll / drag pans when zoomed. RealImageViewer's intrinsic
                // frame is (fitScale * zoom) × source, so when zoom > 1 the
                // content exceeds the viewport and scrollbars appear; when
                // zoom <= 1 the content centers thanks to the minWidth/minHeight
                // padding below.
                ScrollView([.horizontal, .vertical], showsIndicators: true) {
                    content(maxW: maxW, maxH: maxH, zoom: zoom)
                        .frame(minWidth: maxW, minHeight: maxH)
                }
                .scrollBounceBehavior(.basedOnSize)
                .gesture(magnifyGesture)
                .animation(Tokens.Motion.ease, value: zoom)

                ViewerControlsLeft(overlayMode: $overlayMode, showOverlay: $showOverlay)
                // C3 pass-6: QC metric badges — shown below the overlay-mode controls.
                VStack {
                    Color.clear.frame(height: 52) // vertically offset below ViewerControlsLeft pill
                    QCBadges(stats: state.currentImage?.detection?.imageStats)
                    Spacer()
                }
                .padding(.leading, 14)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                ViewerControlsRight(zoom: $zoom, state: state, fullScreenEdit: $fullScreenEdit)
                ViewerControlsTopCenter(
                    editorMode: $editorMode,
                    roiMode: $roiMode,
                    manualMarkerDiameter: $state.manualMarkerDiameter,
                    onRemoveTapped: {
                        // Pass-15 (A2): tapping Remove with an active multi-
                        // selection deletes the selection in one go instead
                        // of switching to .remove mode.
                        if !selectedCellIds.isEmpty {
                            state.removeCells(selectedCellIds)
                            selectedCellIds.removeAll()
                            // Notify observers to resync the overlay's liveCells
                            // mirror (finding: overlay-stale-after-nonhandleedit-
                            // mutations).
                            NotificationCenter.default.post(name: .ccCorrectionsChanged,
                                                            object: state.currentImage?.id)
                            return true
                        }
                        return false
                    },
                    // Pass-17 (Lane B): live "M of N marked" status pill.
                    annotationsCount: annotationCountForCurrentImage,
                    detectionsCount: state.currentImage?.detection?.cells.count ?? 0
                )

                // Pass-8: when the image is loaded but detection didn't produce a result,
                // surface the reason inline + give a one-click re-run.
                if let image = state.currentImage, image.detection == nil {
                    // Pass-14: disable Re-run while a detection is already
                    // in flight for this image. The button could otherwise be
                    // double-tapped (or re-rendered + auto-clicked by an
                    // ancestor's animation) and spawn a second cellpose
                    // subprocess that the Cancel handler then SIGTERM's,
                    // producing duplicate "detection cancelled" lines.
                    DetectionFailedBanner(
                        message: state.lastDetectionError
                            ?? "Detection didn't produce any results for this image.",
                        canRerun: state.canRunDetection && !state.isRerunning(image),
                        onRerun: {
                            guard !state.isRerunning(image) else { return }
                            state.reRunDetection(on: image)
                        })
                        .padding(20)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                        .allowsHitTesting(true)
                }

                // Line-profile gesture layer now lives INSIDE RealImageViewer's
                // image-sized ZStack (see RealImageViewer.body) so it samples the
                // correct pixels under centering / zoom / pan — it used to sit
                // here as a sibling with a wrong transform
                // (finding: lineprofile-ignores-centering-offset-and-zoom).
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(alignment: .leading) {
                Rectangle()
                    .fill(Tokens.border)
                    .frame(width: 0.5)
                    .frame(maxHeight: .infinity)
                    .allowsHitTesting(false)
            }
            .clipped()
            // Pass-17 (Lane B): refresh the annotate-mode status pill when
            // the annotation set for the current image changes.
            .onReceive(NotificationCenter.default.publisher(for: .ccAnnotationsChanged)) { note in
                if let id = note.object as? UUID, id == state.currentImage?.id {
                    annotationsTick &+= 1
                } else if note.object == nil {
                    annotationsTick &+= 1
                }
            }
        }
    }

    @ViewBuilder
    private func content(maxW: CGFloat, maxH: CGFloat, zoom: Double) -> some View {
        // Parent has already guarded for nil/empty batch, so we only reach
        // here with at least one real image. A nil `currentImage` is a
        // transient state during image switch — show the checker background.
        if let image = state.currentImage {
            // Pass-15: pass `zoom` into the real-image viewer so it multiplies
            // the fit-scale into its own intrinsic frame. That makes the
            // ScrollView's content size grow when zoom > 1 (so scrollbars
            // appear) and shrink when zoom < 1 (the minWidth/minHeight wrapper
            // in body re-centers the content).
            RealImageViewer(state: state,
                            image: image,
                            overlayMode: overlayMode,
                            showOverlay: showOverlay,
                            showMaskFills: showMaskFills,
                            showOutlines: showOutlines,
                            editorMode: $editorMode,
                            roiMode: $roiMode,
                            profileMode: $profileMode,
                            selectedCellIds: $selectedCellIds,
                            maxW: maxW,
                            maxH: maxH,
                            zoom: zoom)
        } else {
            Color.clear
        }
    }

}

// MARK: — Real-image viewer

private struct RealImageViewer: View {
    @Bindable var state: AppState
    let image: ImageRecord
    let overlayMode: OverlayMode
    let showOverlay: Bool
    // Pass-14 (F3): independent mask/outline visibility flags. `showOverlay`
    // is the master gate (Space). `showOutlines` gates the EditableOverlay's
    // outline render at this wrapping level so today's build does not depend
    // on F1's branch landing first. `showMaskFills` is forwarded to F1's
    // colored-mask render branch inside EditableOverlay once that lands.
    let showMaskFills: Bool
    let showOutlines: Bool
    @Binding var editorMode: EditableOverlay.EditorMode
    @Binding var roiMode: ROIMode
    // Line-profile mode is bound in so the LineProfileTool can live INSIDE the
    // image-sized ZStack below — that way its coordinate space already matches
    // the rendered image (centering, zoom, and scroll-pan are handled by the
    // wrapping ScrollView + drawW/drawH frame) instead of being sampled with a
    // wrong transform (finding: lineprofile-ignores-centering-offset-and-zoom).
    @Binding var profileMode: Bool
    // Pass-15 (A2): selection set is owned by ResultsView so it can be shared
    // with the EditorModeToolbar's "delete selected" override.
    @Binding var selectedCellIds: Set<UUID>
    let maxW: CGFloat
    let maxH: CGFloat
    /// Pass-15: multiplier applied to the fit-scale to drive the canvas size.
    /// When > 1 the content exceeds the wrapping ScrollView's viewport so the
    /// user can pan via two-finger scroll / drag; at 1.0 the image just fits.
    var zoom: Double = 1.0

    @State private var liveCells: [DetectedCell] = []
    /// Pass-17 (Lane B): in-memory mirror of the ground-truth annotations on
    /// this image. Synced from `state.repos.annotations(for:)` on appear / image
    /// change. Holding this in @State (instead of querying inside `body`) lets
    /// a click both persist + repaint the crosshair layer in the same tick.
    @State private var annotations: [GroundTruthAnnotation] = []
    // Pass-11 K6: cache the loaded NSImage off-main. Calling NSImage(contentsOf:)
    // synchronously inside `body` hit the disk on every render, freezing Results
    // for hundreds of ms on large microscope TIFFs. Now we load on appear /
    // image change in a detached Task and only Image() when the cache is ready.
    @State private var loadedImage: NSImage? = nil
    @State private var loadedImageId: UUID? = nil
    @State private var imageLoadTask: Task<Void, Never>? = nil

    /// Thresholds to use for display/binning/export — prefer the batch's
    /// persisted thresholds for reproducibility, fall back to live global.
    private var batchThresholds: [Double] {
        state.currentBatch?.thresholds ?? state.thresholds
    }

    var body: some View {
        let srcW = max(1, CGFloat(image.widthPx))
        let srcH = max(1, CGFloat(image.heightPx))
        // Pass-15: bake `zoom` into the fit-scale so the rendered frame size
        // tracks the user's magnification. EditableOverlay maps source-pixel
        // coordinates to view-points using this same `scale` (passed via
        // `viewScale:`) so its hit-testing stays correct as the user zooms.
        let fitScale = min(maxW / srcW, maxH / srcH)
        let scale = fitScale * CGFloat(zoom)
        let drawW = srcW * scale
        let drawH = srcH * scale

        ZStack(alignment: .bottomLeading) {
            ZStack {
                if let ns = loadedImage, loadedImageId == image.id {
                    Image(nsImage: ns)
                        .resizable()
                        .interpolation(.medium)
                        .aspectRatio(contentMode: .fit)
                } else if loadedImageId == image.id {
                    // Tried and failed to load.
                    Rectangle().fill(Tokens.bgSunken)
                    VStack(spacing: 6) {
                        Image(systemName: "photo.badge.exclamationmark")
                            .font(.system(size: 24, weight: .regular))
                            .foregroundStyle(Tokens.textTertiary)
                        Text("Image unavailable")
                            .font(.system(size: 12))
                            .foregroundStyle(Tokens.textTertiary)
                    }
                } else {
                    // Loading.
                    Rectangle().fill(Tokens.bgSunken)
                    AppSpinner()
                }

                // Pass-14 (F3): the overlay is visible when the master flag
                // is on AND at least one of the fills/outlines toggles is on.
                // F1 will consume `showMaskFills` directly inside EditableOverlay
                // to gate the colored-mask fill render; the outline strokes are
                // gated here so the build works standalone.
                if showOverlay && (showOutlines || showMaskFills) {
                    // Pass-15: the EditableOverlay binding exposes ONLY the
                    // cells that pass the effective confidence cutoff. Cells
                    // below the slider are hidden from the overlay entirely.
                    // The setter merges edits back into the full `liveCells`,
                    // preserving the hidden tail so a stricter cutoff doesn't
                    // discard cells from the SwiftData store. A2 owns
                    // EditableOverlay; this filter sits one layer above it.
                    let cutoff = state.effectiveConfidence(for: image)
                    let visibleBinding = Binding<[DetectedCell]>(
                        get: { liveCells.filter { $0.confidence >= cutoff } },
                        set: { newVisible in
                            let newById = Dictionary(uniqueKeysWithValues:
                                newVisible.map { ($0.id, $0) })
                            var merged: [DetectedCell] = []
                            var seen = Set<UUID>()
                            for c in liveCells {
                                if c.confidence >= cutoff {
                                    if let updated = newById[c.id] {
                                        merged.append(updated)
                                        seen.insert(c.id)
                                    }
                                    // else: visible cell removed by the user.
                                } else {
                                    merged.append(c)   // hidden — preserve
                                }
                            }
                            for c in newVisible where !seen.contains(c.id) {
                                merged.append(c)       // overlay-added
                            }
                            liveCells = merged
                        }
                    )
                    EditableOverlay(
                        cells: visibleBinding,
                        pxPerUm: state.pxPerUm,
                        thresholds: batchThresholds,
                        overlayMode: overlayMode,
                        uncertaintyThreshold: cutoff,
                        viewScale: Double(scale),
                        viewOffset: .zero,
                        onEdit: { handleEdit($0) },
                        editorMode: $editorMode,
                        manualMarkerDiameter: state.manualMarkerDiameter,
                        externalSelectedCellIds: $selectedCellIds,
                        // Pass-17 (Lane B): ground-truth annotations layer.
                        // The overlay only renders crosshairs (read-only) — the
                        // click-to-add/remove path goes through the callbacks
                        // below so we own persistence.
                        annotations: annotations,
                        onAddAnnotation: { p in addAnnotation(at: p) },
                        onRemoveAnnotation: { a in removeAnnotation(a) }
                    )
                }

                // ROI layer — drawn above cells so include/exclude regions are
                // always visible regardless of overlay mode.
                EditableROI(state: state,
                            image: image,
                            viewScale: Double(scale),
                            viewOffset: .zero,
                            mode: $roiMode)
                    .frame(width: drawW, height: drawH)

                // Line-profile gesture layer — sits inside the image-sized ZStack
                // so its local coordinate space is exactly the rendered image.
                // scale = fitScale * zoom and offset = .zero are therefore the
                // correct transform; the ScrollView handles centering + pan.
                if profileMode {
                    LineProfileTool(
                        image: image,
                        viewScale: Double(scale),
                        viewOffset: .zero,
                        mode: Binding(
                            get: { profileMode ? .drawing : .idle },
                            set: { if $0 == .idle { profileMode = false } }
                        )
                    )
                    .frame(width: drawW, height: drawH)
                }
            }
            .frame(width: drawW, height: drawH)
            .shadow(color: .black.opacity(0.16), radius: 12, y: 4)

            ScaleBar(pxPerUm: state.pxPerUm, fitScale: scale)
                .padding(.leading, 16)
                .padding(.bottom, 14)
        }
        .frame(width: drawW, height: drawH)
        .onAppear { syncFromDetection(); syncAnnotations(); loadImageAsync() }
        .onChange(of: image.id) { syncFromDetection(); syncAnnotations(); loadImageAsync() }
        // The overlay draws from the private `liveCells` mirror, which otherwise
        // only resyncs on image.id change. Three paths mutate `detection.cells`
        // directly on the model while the image stays selected — multi-select
        // delete (removeCells), ⌘R re-run, and Split — so resync the mirror when
        // the model's cell set changes or a corrections signal fires, else the
        // canvas keeps drawing deleted/old cells
        // (finding: overlay-stale-after-nonhandleedit-mutations).
        .onChange(of: image.detection?.cells.count) { syncFromDetection() }
        .onReceive(NotificationCenter.default.publisher(for: .ccCorrectionsChanged)) { note in
            // Corrections are posted with object == nil (broadcast) or the
            // affected image id. Resync in both cases; a broadcast may follow a
            // re-run/split that replaced this image's DetectionRecord wholesale
            // (which .onChange on the old relationship's count can miss).
            if note.object == nil || (note.object as? UUID) == image.id {
                syncFromDetection()
            }
        }
        // Pass-17 (Lane B): the F1 sidebar panel pings this when an external
        // tool (Reset, Export, etc.) mutates annotations so we resync.
        .onReceive(NotificationCenter.default.publisher(for: .ccAnnotationsChanged)) { note in
            if let id = note.object as? UUID, id == image.id {
                syncAnnotations()
            }
        }
        .onDisappear { imageLoadTask?.cancel(); imageLoadTask = nil }
    }

    private func syncFromDetection() {
        liveCells = image.detection?.cells ?? []
    }

    /// Pass-17 (Lane B): reload the annotations for the current image from
    /// SwiftData. Cheap — `annotations(for:)` is a single predicate fetch.
    private func syncAnnotations() {
        annotations = state.repos.annotations(for: image.id)
    }

    /// Pass-17 (Lane B): persist a new ground-truth annotation at the given
    /// source-pixel coords. The sidebar's GroundTruthPanel re-reads via the
    /// notification below so its F1 numbers refresh in the same tick.
    private func addAnnotation(at p: CGPoint) {
        let ann = GroundTruthAnnotation(imageId: image.id,
                                        cx: Double(p.x),
                                        cy: Double(p.y))
        state.repos.addAnnotation(ann)
        syncAnnotations()
        NotificationCenter.default.post(name: .ccAnnotationsChanged, object: image.id)
    }

    /// Pass-17 (Lane B): toggle-delete an annotation when the user clicks one
    /// in `.annotate` mode.
    private func removeAnnotation(_ ann: GroundTruthAnnotation) {
        state.repos.deleteAnnotation(ann)
        syncAnnotations()
        NotificationCenter.default.post(name: .ccAnnotationsChanged, object: image.id)
    }

    /// Pass-11 K6: load the full-res NSImage off-main and cache. Replaces the
    /// `NSImage(contentsOf:)` call that used to run inside `body`.
    private func loadImageAsync() {
        // Cancel any in-flight load for a previous image.
        imageLoadTask?.cancel()
        // If we already have the right image, no-op.
        if loadedImageId == image.id, loadedImage != nil { return }
        loadedImage = nil
        loadedImageId = nil
        let url = image.storedURL
        let targetId = image.id
        imageLoadTask = Task.detached(priority: .userInitiated) {
            let ns = NSImage(contentsOf: url)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                // Only commit if the user hasn't moved on to a different image.
                loadedImage = ns
                loadedImageId = targetId
            }
        }
    }

    private func handleEdit(_ event: EditableOverlay.EditEvent) {
        guard let det = image.detection else { return }
        // Persist the new cell list to the detection blob.
        det.cells = liveCells
        try? state.repos.context.save()
        let isManualMode = (editorMode == .manualCount)
        switch event {
        case .removed(let c):
            state.recordCorrection(kind: "remove", cellId: c.id,
                                   cx: c.cx, cy: c.cy, diameter: c.diameter)
        case .added(let c):
            // Distinguish manual-count placements from add-mode placements for the audit trail.
            let kind = isManualMode ? "manual" : "add"
            state.recordCorrection(kind: kind, cellId: c.id,
                                   cx: c.cx, cy: c.cy, diameter: c.diameter)
        case .merged(let removed, let added):
            for r in removed {
                state.recordCorrection(kind: "remove", cellId: r.id,
                                       cx: r.cx, cy: r.cy, diameter: r.diameter)
            }
            state.recordCorrection(kind: "add", cellId: added.id,
                                   cx: added.cx, cy: added.cy, diameter: added.diameter)
        case .resized(let c, _):
            state.recordCorrection(kind: "resize", cellId: c.id,
                                   cx: c.cx, cy: c.cy, diameter: c.diameter)
        }
    }
}

// MARK: — Cell overlay (boxes/outlines only — transparent BG)

private struct CellOverlay: View {
    let cells: [DetectedCell]
    /// Source image's pixel size; overlay maps cell coords from this into the
    /// rendered area, which is sized by the parent.
    let sourceSize: CGSize
    let overlayMode: OverlayMode
    let thresholds: [Double]
    let uncertaintyThreshold: Double

    var body: some View {
        Canvas { context, size in
            let sx = size.width / max(1, sourceSize.width)
            let sy = size.height / max(1, sourceSize.height)
            // Cells are in source-image pixel space — apply per-axis scale (will be equal under aspect-fit).
            for c in cells {
                let idx = BinMath.binIndex(for: c.diameter, thresholds: thresholds)
                let col = Tokens.binColor(idx)
                let isUncertain = c.confidence < uncertaintyThreshold
                let dxPx = c.diameterPx * sx
                let dyPx = c.diameterPx * sy
                let r = min(dxPx, dyPx) / 2  // B4-6: use min so non-uniform scale doesn't oversize cells
                let cx = c.cx * sx
                let cy = c.cy * sy
                let rect = CGRect(x: cx - r, y: cy - r, width: r * 2, height: r * 2)
                let path = overlayMode == .outline
                    ? Path(ellipseIn: rect)
                    : Path(roundedRect: rect, cornerRadius: 2)
                context.fill(path, with: .color(col.opacity(overlayMode == .outline ? 0.18 : 0.10)))
                let style: StrokeStyle = isUncertain
                    ? StrokeStyle(lineWidth: 1.5, dash: [3.5, 3])
                    : StrokeStyle(lineWidth: 1.5)
                context.stroke(path, with: .color(col), style: style)
            }
        }
        .allowsHitTesting(false)
    }
}

private struct CheckerBackground: View {
    var body: some View {
        Canvas { context, size in
            let sq: CGFloat = 16
            var row = 0
            var y: CGFloat = 0
            while y < size.height {
                var col = 0
                var x: CGFloat = 0
                while x < size.width {
                    let c = (row + col) % 2 == 0 ? Tokens.bgSunken : Tokens.bg
                    context.fill(
                        Path(CGRect(x: x, y: y, width: sq, height: sq)),
                        with: .color(c)
                    )
                    x += sq; col += 1
                }
                y += sq; row += 1
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct ScaleBar: View {
    let pxPerUm: Double
    let fitScale: CGFloat

    private let micronsBar: Double = 100

    private var widthOnScreen: CGFloat {
        // (microns * pxPerUm) = source-pixel length, then scaled by fitScale.
        max(8, CGFloat(micronsBar * pxPerUm) * fitScale)
    }

    var body: some View {
        HStack(spacing: 8) {
            Rectangle()
                .fill(.white)
                .frame(width: widthOnScreen, height: 2)
            Text("\(Int(micronsBar)) µm")
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(Color.black.opacity(0.55))
        )
    }
}

private struct ViewerControlsLeft: View {
    @Binding var overlayMode: OverlayMode
    @Binding var showOverlay: Bool

    var body: some View {
        VStack {
            HStack(spacing: 6) {
                SegmentedPicker(
                    value: $overlayMode,
                    options: [
                        (value: .bbox, label: "Box"),
                        (value: .outline, label: "Outline"),
                    ]
                )
                Button {
                    withAnimation(Tokens.Motion.easeFast) { showOverlay.toggle() }
                } label: {
                    Icon(showOverlay ? "eye" : "eyeoff", size: 14)
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Tokens.textSecondary)
            }
            .padding(4)
            .background(
                RoundedRectangle(cornerRadius: Tokens.Radius.md)
                    .fill(Tokens.bgToolbar)
                    .overlay(
                        RoundedRectangle(cornerRadius: Tokens.Radius.md)
                            .strokeBorder(Tokens.border, lineWidth: 0.5)
                    )
            )
            .shadow(color: .black.opacity(0.06), radius: 2, y: 1)
            Spacer()
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct ViewerControlsTopCenter: View {
    @Binding var editorMode: EditableOverlay.EditorMode
    @Binding var roiMode: ROIMode
    @Binding var manualMarkerDiameter: Double
    /// Pass-15 (A2): override fired by the toolbar's Remove button — returns
    /// `true` if the tap was consumed (used to delete an active selection
    /// instead of switching to .remove mode).
    var onRemoveTapped: (() -> Bool)? = nil
    /// Pass-17 (Lane B): annotated count + detected count for the status pill
    /// that surfaces in `.annotate` mode. Nil-state hides the pill.
    var annotationsCount: Int = 0
    var detectionsCount: Int = 0

    var body: some View {
        HStack(spacing: 8) {
            EditorModeToolbar(mode: $editorMode,
                              manualMarkerDiameter: $manualMarkerDiameter,
                              onRemoveTapped: onRemoveTapped)
            ROIModePicker(mode: $roiMode)
            // Pass-17 (Lane B): live "M of N marked" status when annotating.
            if editorMode == .annotate {
                AnnotateStatusPill(annotated: annotationsCount,
                                   detected: detectionsCount)
            }
        }
        .padding(.top, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

/// Pass-17 (Lane B): small pill next to the EditorModeToolbar showing how
/// many ground-truth marks the user has placed so far vs the detector's
/// count. Helps the user keep score against their target — "the user counted
/// 403 by hand, detector says X" is the exact use-case.
private struct AnnotateStatusPill: View {
    let annotated: Int
    let detected: Int
    var body: some View {
        HStack(spacing: 4) {
            Text("Annotation mode —")
                .font(.system(size: 11.5))
                .foregroundStyle(Tokens.textSecondary)
            Text("\(annotated)")
                .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                .foregroundStyle(Tokens.text)
            Text("of")
                .font(.system(size: 11.5))
                .foregroundStyle(Tokens.textSecondary)
            Text("\(detected)")
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundStyle(Tokens.textSecondary)
            Text("marked")
                .font(.system(size: 11.5))
                .foregroundStyle(Tokens.textSecondary)
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(
            RoundedRectangle(cornerRadius: Tokens.Radius.md)
                .fill(Tokens.bgToolbar)
                .overlay(
                    RoundedRectangle(cornerRadius: Tokens.Radius.md)
                        .strokeBorder(Tokens.border, lineWidth: 0.5)
                )
        )
        .shadow(color: .black.opacity(0.06), radius: 2, y: 1)
    }
}

private struct ViewerControlsRight: View {
    @Binding var zoom: Double
    @Bindable var state: AppState
    // Pass-15: full-screen edit toggle is also surfaced in this right-side
    // cluster so the user can collapse the sidebar+toolbar from inside the
    // viewer. Binding is currently unused here pending the toggle button UI,
    // but kept on the struct so call sites (which were updated in parallel)
    // continue to compile.
    @Binding var fullScreenEdit: Bool

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 6) {
                zoomGroup
                // Pass-15: full-screen edit toggle — pill next to zoom so it's
                // discoverable and lines up visually with the existing controls.
                fullScreenToggle
            }
            // Bug #3: SplitTouchingButton placed BELOW zoom controls in its own row
            // so it never overlaps ViewerControlsLeft (shape segmented control) regardless
            // of viewer width. Both clusters are strictly right-aligned in a VStack.
            SplitTouchingButton(state: state)
            Spacer()
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
    }

    private var fullScreenToggle: some View {
        Button {
            withAnimation(Tokens.Motion.ease) { fullScreenEdit.toggle() }
        } label: {
            Image(systemName: fullScreenEdit
                  ? "arrow.down.right.and.arrow.up.left"
                  : "arrow.up.left.and.arrow.down.right.square")
                .font(.system(size: 13, weight: .regular))
                .frame(width: 28, height: 28)
        }
        .buttonStyle(.plain)
        .foregroundStyle(fullScreenEdit ? Tokens.text : Tokens.textSecondary)
        .padding(4)
        .background(
            RoundedRectangle(cornerRadius: Tokens.Radius.md)
                .fill(Tokens.bgToolbar)
                .overlay(
                    RoundedRectangle(cornerRadius: Tokens.Radius.md)
                        .strokeBorder(Tokens.border, lineWidth: 0.5)
                )
        )
        .shadow(color: .black.opacity(0.06), radius: 2, y: 1)
        .help(fullScreenEdit
              ? "Exit full-screen edit (⌘⇧F or Esc)"
              : "Full-screen edit (⌘⇧F)")
    }

    private var zoomGroup: some View {
        Group {
            HStack(spacing: 2) {
                Button { zoom = max(0.4, zoom - 0.15) } label: {
                    Icon("zoomout", size: 14).frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Tokens.textSecondary)

                Text("\(Int(zoom * 100))%")
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(Tokens.textSecondary)
                    .padding(.horizontal, 6)
                    .frame(minWidth: 40)

                // Pass-15: upper bound raised to 4.0x to match the keyboard
                // shortcut and pinch-gesture upper bound.
                Button { zoom = min(4.0, zoom + 0.15) } label: {
                    Icon("zoomin", size: 14).frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Tokens.textSecondary)

                Button { withAnimation(Tokens.Motion.ease) { zoom = 1.0 } } label: {
                    Icon("fit", size: 13).frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Tokens.textSecondary)
            }
            .padding(4)
            .background(
                RoundedRectangle(cornerRadius: Tokens.Radius.md)
                    .fill(Tokens.bgToolbar)
                    .overlay(
                        RoundedRectangle(cornerRadius: Tokens.Radius.md)
                            .strokeBorder(Tokens.border, lineWidth: 0.5)
                    )
            )
            .shadow(color: .black.opacity(0.06), radius: 2, y: 1)
        }
    }
}

// MARK: — Sidebar

private struct ResultsSidebar: View {
    @Bindable var state: AppState
    let overlayMode: OverlayMode
    @Binding var profileMode: Bool

    /// Bumped on ROI count change to force a re-evaluation of `cells`
    /// (which reads through `state.repos.rois(for:)`).
    @State private var roiSignal: Int = 0

    /// Pass-14 (F3): one-click "Retrain on this batch & next image" controller.
    /// Held as @StateObject so it survives view rebuilds during the run.
    @StateObject private var retrainController = RetrainAndAdvanceController()

    /// Pass-12: dropped the fallback-cells alternate path. The parent view
    /// guards against `images.isEmpty` and routes to EmptyBatchState, so the
    /// sidebar is only mounted when a real image is selected. If detection
    /// hasn't run yet, `cells` falls back to empty — the existing
    /// DetectionFailedBanner handles re-running.
    private var rawCells: [DetectedCell] {
        state.currentImage?.detection?.cells ?? []
    }
    /// Pass-15: the confidence slider is now a real filter. Cells whose
    /// `confidence` is below the effective cutoff (per-image override beats
    /// global) are hidden everywhere downstream — TotalBlock count, BinsPanel,
    /// DistributionPanel, MeasurementsPanel, ResultsExportPanel — *because they
    /// all read this computed property*. Underlying SwiftData rows are
    /// untouched, so the slider can be dragged back down freely. A2 and A4
    /// can layer their own filters on top without rewriting this body.
    private var cells: [DetectedCell] {
        guard let image = state.currentImage else { return rawCells }
        _ = roiSignal  // make this dependent on the bump signal
        let cutoff = state.effectiveConfidence(for: image)
        let confidenceFiltered = rawCells.filter { $0.confidence >= cutoff }
        let rois = state.repos.rois(for: image.id)
        return ROIFilter.apply(cells: confidenceFiltered, rois: rois)
    }
    private var roiCount: Int {
        guard let image = state.currentImage else { return 0 }
        return state.repos.rois(for: image.id).count
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                TotalBlock(cells: cells)
                RetrainBanner(state: state, onTrain: { state.view = .fineTune })
                    .padding(.horizontal, 18)
                    .padding(.bottom, 8)
                // Pass-14 (F3): one-click retrain + advance — sits directly
                // below the standard RetrainBanner so the two affordances live
                // together. Always shown so the user can re-iterate even
                // without 10+ corrections.
                RetrainAndAdvanceBanner(state: state, controller: retrainController)
                    .padding(.horizontal, 18)
                    .padding(.bottom, 8)
                Divider().overlay(Tokens.divider)
                SizeBinsPanel(state: state, cells: cells)
                Divider().overlay(Tokens.divider)
                DistributionPanel(cells: cells, thresholds: state.currentBatch?.thresholds ?? state.thresholds)
                Divider().overlay(Tokens.divider)
                ColoniesPanel(state: state)
                Divider().overlay(Tokens.divider)
                ScalePanel(state: state)
                Divider().overlay(Tokens.divider)
                ConfidencePanel(state: state)
                MeasurementsPanel(cells: cells)
                Divider().overlay(Tokens.divider)
                // Pass-17 (Lane B): F1 / precision / recall vs ground truth.
                // Renders nothing when there are zero annotations, so this
                // doesn't pollute the sidebar for users who never use it.
                GroundTruthPanel(state: state, detections: cells)
                // Pass-18 (Lane N): freeform per-image notes — donor / passage /
                // observations the filename can't carry. Sits between
                // GroundTruthPanel and AnalysisPanel so it's adjacent to the
                // experimenter-facing controls.
                Divider().overlay(Tokens.divider)
                NotesPanel(state: state)
                Divider().overlay(Tokens.divider)
                AnalysisPanel(state: state, profileMode: $profileMode)
                Divider().overlay(Tokens.divider)
                ResultsExportPanel(state: state, overlayMode: overlayMode)
            }
        }
        .background(Tokens.bg)
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(Tokens.border)
                .frame(width: 0.5)
                .frame(maxHeight: .infinity)
        }
        .onChange(of: roiCount) { roiSignal &+= 1 }
    }
}

// MARK: — Total block

private struct TotalBlock: View {
    let cells: [DetectedCell]

    private var total: Int { cells.count }
    private var diameters: [Double] { cells.map(\.diameter) }
    private var mean: Double {
        guard !diameters.isEmpty else { return 0 }
        return diameters.reduce(0, +) / Double(diameters.count)
    }
    private var stdev: Double {
        guard diameters.count > 1 else { return 0 }
        let m = mean
        return sqrt(diameters.reduce(0) { $0 + ($1 - m) * ($1 - m) } / Double(diameters.count))
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(total.formatted())
                .font(.system(size: 38, weight: .semibold, design: .monospaced))
                .foregroundStyle(Tokens.text)
                .kerning(-0.02 * 38)

            VStack(alignment: .leading, spacing: 2) {
                Text("cells detected")
                    .font(.system(size: 13))
                    .foregroundStyle(Tokens.textSecondary)
                HStack(spacing: 0) {
                    Text("µ = ")
                        .font(.system(size: 11))
                        .foregroundStyle(Tokens.textTertiary)
                    Text(String(format: "%.1f", mean))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Tokens.textTertiary)
                    Text(" µm · σ = ")
                        .font(.system(size: 11))
                        .foregroundStyle(Tokens.textTertiary)
                    Text(String(format: "%.1f", stdev))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Tokens.textTertiary)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 18)
        .padding(.top, 22)
        .padding(.bottom, 18)
    }
}

// MARK: — Size bins panel (Pass-15: consolidated BinsPanel + ThresholdsPanel)

/// One unified panel for the Results sidebar: shows each size bin row with
/// color swatch, range label, count, and percentage — and lets the user
/// edit the threshold value (right-edge of each bin except the open-ended
/// last one) inline + delete bins via a hover-revealed trash icon. The
/// `+ Add bin` button lives at the bottom of the panel. Replaces the
/// previous read-only `BinsPanel` and separate `ThresholdsPanel`.
///
/// Data model is unchanged — edits propagate to both `state.thresholds`
/// AND `state.currentBatch?.thresholds`, mirroring the old ThresholdsPanel
/// behavior so the binning recomputes immediately for this batch.
private struct SizeBinsPanel: View {
    @Bindable var state: AppState
    let cells: [DetectedCell]

    /// Use the batch's persisted thresholds for display so the count is reproducible.
    private var displayThresholds: [Double] {
        state.currentBatch?.thresholds ?? state.thresholds
    }

    private var bins: [SizeBin] { BinMath.bins(from: displayThresholds) }
    private var total: Int { cells.count }

    private func count(for index: Int) -> Int {
        cells.filter { BinMath.binIndex(for: $0.diameter, thresholds: displayThresholds) == index }.count
    }

    var body: some View {
        VStack(spacing: 0) {
            SectionHeader(title: "Size bins")
                .padding(.bottom, 0)

            // Render one row per bin. The last bin ("> N µm") has no editable
            // threshold of its own — its left edge IS the previous row's right
            // edge — so thresholdIndex is nil there. Pass-13: id by offset and
            // guard `state.thresholds.indices.contains(i)` inside row callbacks
            // so a stale binding during a delete animation can't crash with
            // "Index out of range".
            ForEach(Array(bins.enumerated()), id: \.offset) { pair in
                let i = pair.offset
                let bin = pair.element
                let c = count(for: i)
                let pct = total > 0 ? Double(c) / Double(total) * 100 : 0
                let color = Tokens.binColor(i)
                let isLast = (i == bins.count - 1)
                // The threshold that gates this row's right edge is at index `i`
                // in `state.thresholds` for every row except the last.
                let thresholdIndex: Int? = isLast ? nil : i
                VStack(spacing: 0) {
                    if i > 0 {
                        Divider().overlay(Tokens.divider)
                    }
                    SizeBinRow(
                        state: state,
                        label: bin.label,
                        color: color,
                        count: c,
                        pct: pct,
                        thresholdIndex: thresholdIndex,
                        // Must keep at least one threshold so we always have ≥ 2 bins.
                        canDelete: thresholdIndex != nil && state.thresholds.count > 1
                    )
                }
            }

            // + Add bin button — relocated here from the old SectionHeader action.
            Button {
                let last = state.thresholds.last ?? 30
                withAnimation(Tokens.Motion.ease) {
                    state.thresholds.append(last + 10)
                    state.currentBatch?.thresholds = state.thresholds
                }
            } label: {
                HStack(spacing: 6) {
                    Icon("plus", size: 11)
                    Text("Add bin")
                        .font(.system(size: 12, weight: .medium))
                }
                .frame(maxWidth: .infinity)
            }
            .appButton(.standard, size: .sm)
            .padding(.top, 12)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 18)
    }
}

/// One row inside `SizeBinsPanel`. Displays the bin's color swatch, range
/// label, count, percentage, and a thin progress bar — and when the row
/// represents an editable threshold (i.e. not the open-ended last bin),
/// clicking the label opens an inline TextField, and a trash icon appears
/// on hover. Edits mirror into `state.currentBatch?.thresholds`.
private struct SizeBinRow: View {
    @Bindable var state: AppState
    let label: String
    let color: Color
    let count: Int
    let pct: Double
    /// Index into `state.thresholds` for the threshold that gates this row's
    /// right edge. `nil` for the last "> N" bin (no editable threshold).
    let thresholdIndex: Int?
    let canDelete: Bool

    @State private var hovering: Bool = false
    @State private var editing: Bool = false
    @State private var text: String = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 4) {
            HStack(spacing: 12) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(color)
                    .frame(width: 14, height: 14)

                if editing,
                   let i = thresholdIndex,
                   state.thresholds.indices.contains(i) {
                    // Inline TextField — replaces the label while editing.
                    TextField("", text: $text)
                        .font(.system(size: 12.5, design: .monospaced))
                        .foregroundStyle(Tokens.text)
                        .textFieldStyle(.plain)
                        .focused($focused)
                        .frame(maxWidth: 70)
                        .onSubmit { commit() }
                        .onChange(of: focused) {
                            if !focused { commit() }
                        }
                    Text("µm")
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(Tokens.textTertiary)
                    Spacer()
                } else {
                    // Read-mode label. For editable rows, clicking enters edit mode.
                    Text(label)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Tokens.text)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            guard let i = thresholdIndex,
                                  state.thresholds.indices.contains(i) else { return }
                            text = state.thresholds[i].trimmedString
                            editing = true
                            focused = true
                        }
                    Spacer()
                }

                Text("\(count)")
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Tokens.text)
                    .frame(minWidth: 44, alignment: .trailing)
                Text(String(format: "%.1f%%", pct))
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(Tokens.textTertiary)
                    .frame(minWidth: 40, alignment: .trailing)

                // Trash icon — reserved as a fixed-width slot so the row layout
                // doesn't shift between hover states. Only rendered when this
                // row maps to a deletable threshold and the pointer is over it.
                ZStack {
                    if canDelete && hovering {
                        Button(action: deleteThreshold) {
                            Icon("minus", size: 12)
                                .foregroundStyle(Tokens.textSecondary)
                                .frame(width: 24, height: 24)
                        }
                        .buttonStyle(.plain)
                        .help("Remove this threshold")
                    }
                }
                .frame(width: 24, height: 24)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2).fill(Tokens.bgSunken)
                    RoundedRectangle(cornerRadius: 2).fill(color)
                        .frame(width: geo.size.width * pct / 100)
                        .animation(Tokens.Motion.easeSlow, value: pct)
                }
            }
            .frame(height: 3)
        }
        .padding(.vertical, 8)
        .onHover { hovering = $0 }
    }

    private func commit() {
        guard let i = thresholdIndex,
              state.thresholds.indices.contains(i) else {
            editing = false
            return
        }
        if let v = Double(text) {
            state.thresholds[i] = v
            // Mirror into the current batch so the histogram + binning recompute
            // immediately for this analysis (Pass-12 K4/K5).
            state.currentBatch?.thresholds = state.thresholds
        }
        editing = false
    }

    private func deleteThreshold() {
        guard let i = thresholdIndex,
              state.thresholds.indices.contains(i),
              state.thresholds.count > 1 else { return }
        withAnimation(Tokens.Motion.ease) {
            state.thresholds.remove(at: i)
            // Mirror the change into the current batch (Pass-12 K4/K5).
            state.currentBatch?.thresholds = state.thresholds
        }
    }

}

// MARK: — Distribution panel

private struct DistributionPanel: View {
    let cells: [DetectedCell]
    let thresholds: [Double]

    // Delegate bucket computation to the shared HistogramMath (defined in CompareView.swift).
    private var histData: [Int] { HistogramMath.buckets(for: cells) }
    private var maxH: Int { histData.max() ?? 1 }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("DISTRIBUTION")
                    .tracking(0.04 * 13)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Tokens.textSecondary)
                Spacer()
                Text("\(Int(HistogramMath.histMin)) – \(Int(HistogramMath.histMax)) µm")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Tokens.textTertiary)
            }
            .padding(.bottom, 4)

            HStack(alignment: .bottom, spacing: 2) {
                ForEach(0..<HistogramMath.bucketCount, id: \.self) { i in
                    let h = histData[i]
                    let heightFrac = maxH > 0 ? max(CGFloat(h) / CGFloat(maxH), 2 / 80) : 2 / 80
                    let center = HistogramMath.histMin + (Double(i) + 0.5) * (HistogramMath.histMax - HistogramMath.histMin) / Double(HistogramMath.bucketCount)
                    let bi = BinMath.binIndex(for: center, thresholds: thresholds)
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Tokens.binColor(bi))
                        .frame(maxWidth: .infinity)
                        .frame(height: 80 * heightFrac)
                }
            }
            .frame(height: 80)
            .padding(.top, 8)

            ZStack(alignment: .topLeading) {
                Color.clear.frame(height: 14)
                ForEach(Array(thresholds.enumerated()), id: \.offset) { i, t in
                    let rawPos = (t - HistogramMath.histMin) / (HistogramMath.histMax - HistogramMath.histMin)
                    let pos = min(0.98, max(0.02, rawPos))
                    GeometryReader { geo in
                        Text("\(Int(t))")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(Tokens.textTertiary)
                            .position(x: geo.size.width * pos, y: 7)
                    }
                }
            }
            .clipped()
            .padding(.top, 4)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 18)
    }
}

// MARK: — Scale panel

private struct ScalePanel: View {
    @Bindable var state: AppState
    @Environment(AppTheme.self) private var theme

    /// Pass-16: derive the objective label from the actual calibration instead
    /// of hardcoding "20×". Maps the Olympus IX73 preset ladder
    /// (1.3 / 2.6 / 5.2 / 10.4 px/µm = 5× / 10× / 20× / 40×) with ±25% tolerance.
    static func objectiveLabel(for pxPerUm: Double) -> String {
        let presets: [(Double, String)] = [
            (1.3, "5×"), (2.6, "10×"), (5.2, "20×"), (10.4, "40×"),
        ]
        if let match = presets.first(where: { abs(pxPerUm - $0.0) / $0.0 < 0.25 }) {
            return "\(match.1) objective"
        }
        return "custom"
    }

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Scale")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Tokens.textTertiary)
                Text(String(format: "%.1f px / µm · %@", state.pxPerUm, Self.objectiveLabel(for: state.pxPerUm)))
                    .font(.system(size: 12.5, design: .monospaced))
                    .foregroundStyle(Tokens.text)
            }
            Spacer()
            Button("Calibrate…") { state.showCalibration = true }
                .appButton(.standard, size: .sm)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 18)
    }
}

// MARK: — Confidence panel

/// Pass-15: the confidence slider now drives a real client-side filter. Cells
/// with `confidence < value` are hidden from overlay/counts/exports without
/// being deleted from SwiftData — moving the slider down brings them back.
///
/// When a `currentImage` is loaded, edits write to that image's
/// `confidenceOverride` so each slide can carry its own cutoff. The "Reset"
/// button clears the override (back to the global default). When no image is
/// loaded yet, edits fall back to writing the global `state.confidence`.
private struct ConfidencePanel: View {
    @Bindable var state: AppState
    @State private var expanded: Bool = false
    @Environment(AppTheme.self) private var theme

    private var value: Double {
        if let img = state.currentImage { return state.effectiveConfidence(for: img) }
        return state.confidence
    }
    private var hasOverride: Bool {
        state.currentImage?.confidenceOverride != nil
    }

    private var sliderBinding: Binding<Double> {
        Binding(
            get: { value },
            set: { newVal in
                if let img = state.currentImage {
                    state.setConfidenceOverride(newVal, on: img)
                } else {
                    state.confidence = newVal
                }
            }
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            Button {
                withAnimation(Tokens.Motion.easeFast) { expanded.toggle() }
            } label: {
                HStack {
                    HStack(spacing: 6) {
                        Icon(expanded ? "chevron" : "chevronr", size: 11)
                            .foregroundStyle(Tokens.textTertiary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Confidence cutoff")
                                .font(.system(size: 12.5, weight: .medium))
                                .foregroundStyle(Tokens.text)
                            Text(hasOverride
                                 ? "Per-image override · slide hides low-confidence cells"
                                 : "Hides cells below the threshold (no re-detection)")
                                .font(.system(size: 11))
                                .foregroundStyle(Tokens.textTertiary)
                        }
                    }
                    Spacer()
                    Text(String(format: "%.2f", value))
                        .font(.system(size: 12.5, design: .monospaced))
                        .foregroundStyle(Tokens.textSecondary)
                }
            }
            .buttonStyle(.plain)

            if expanded {
                VStack(spacing: 4) {
                    Slider(value: sliderBinding, in: 0...1)
                        .tint(theme.accentColor)
                    HStack {
                        Text("0.00")
                        Spacer()
                        if hasOverride, let img = state.currentImage {
                            Button("Reset to global") {
                                state.setConfidenceOverride(nil, on: img)
                            }
                            .buttonStyle(.plain)
                            .font(.system(size: 11))
                            .foregroundStyle(theme.accentColor)
                            Spacer()
                        }
                        Text("1.00")
                    }
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Tokens.textTertiary)
                }
                .padding(.top, 12)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 18)
    }
}

// MARK: — Measurements panel (A1 pass-5)

/// Shows mean morphology + intensity values across all cells in the current image.
/// Hidden entirely when no cell carries measurement data (backward-compat with
/// mock / legacy detections that don't populate the optional fields).
private struct MeasurementsPanel: View {
    let cells: [DetectedCell]

    // Cells that actually carry measurement data.
    private var measured: [DetectedCell] { cells.filter { $0.areaMicrons2 != nil } }

    private func meanOf(_ kp: KeyPath<DetectedCell, Double?>) -> Double? {
        let vals = measured.compactMap { $0[keyPath: kp] }
        guard !vals.isEmpty else { return nil }
        return vals.reduce(0, +) / Double(vals.count)
    }

    private var meanArea: Double?        { meanOf(\.areaMicrons2) }
    private var meanPerimeter: Double?   { meanOf(\.perimeterMicrons) }
    private var meanCircularity: Double? { meanOf(\.circularity) }
    private var meanEccentricity: Double? { meanOf(\.eccentricity) }

    var body: some View {
        // Skip the panel entirely when no cell has measurement data.
        if measured.isEmpty { return AnyView(EmptyView()) }

        return AnyView(
            VStack(spacing: 0) {
                Divider().overlay(Tokens.divider)
                VStack(spacing: 0) {
                    SectionHeader(title: "Measurements")
                    VStack(spacing: 4) {
                        if let v = meanArea {
                            MeasRow(label: "Mean area", value: String(format: "%.1f", v), unit: "µm²")
                        }
                        if let v = meanPerimeter {
                            MeasRow(label: "Mean perimeter", value: String(format: "%.1f", v), unit: "µm")
                        }
                        if let v = meanCircularity {
                            MeasRow(label: "Mean circularity", value: String(format: "%.3f", v), unit: "")
                        }
                        if let v = meanEccentricity {
                            MeasRow(label: "Mean eccentricity", value: String(format: "%.3f", v), unit: "")
                        }
                    }
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 18)
            }
        )
    }
}

private struct MeasRow: View {
    let label: String
    let value: String
    let unit: String

    var body: some View {
        HStack {
            Text(label)
                .font(.system(size: 12.5))
                .foregroundStyle(Tokens.textSecondary)
            Spacer()
            HStack(spacing: 3) {
                Text(value)
                    .font(.system(size: 12.5, design: .monospaced))
                    .foregroundStyle(Tokens.text)
                if !unit.isEmpty {
                    Text(unit)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Tokens.textTertiary)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: — Export panel (Export agent will replace; keep buttons rendering as no-ops)

private struct ExportPanel: View {
    var body: some View {
        VStack(spacing: 0) {
            SectionHeader(title: "Export")
                .padding(.bottom, 0)

            VStack(spacing: 8) {
                HStack(spacing: 8) {
                    Button {
                    } label: {
                        HStack(spacing: 6) {
                            Icon("image", size: 13)
                            Text("Annotated PNG")
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .appButton(.standard, size: .sm)

                    Button {
                    } label: {
                        HStack(spacing: 6) {
                            Icon("table", size: 13)
                            Text("CSV")
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .appButton(.standard, size: .sm)
                }

                Button {
                } label: {
                    HStack(spacing: 6) {
                        Icon("download", size: 13)
                        Text("Export both")
                    }
                    .frame(maxWidth: .infinity)
                }
                .appButton(.primary, size: .sm)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 18)
    }
}

// MARK: — Batch strip

private struct BatchStrip: View {
    @Bindable var state: AppState

    @Environment(AppTheme.self) private var theme

    private var sortedImages: [ImageRecord] {
        (state.currentBatch?.images ?? []).sorted(by: { $0.importedAt < $1.importedAt })
    }

    // The strip only shows real images. ResultsView's empty-batch guard
    // renders EmptyBatchState before this view is mounted, so the
    // `sortedImages.isEmpty` branch is defensive.
    var body: some View {
        if sortedImages.isEmpty {
            EmptyView()
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Array(sortedImages.enumerated()), id: \.element.id) { i, img in
                        BatchThumb(
                            image: img,
                            isActive: i == state.currentImageIdx,
                            accentColor: theme.accentColor
                        )
                        .onTapGesture {
                            withAnimation(Tokens.Motion.easeFast) {
                                state.currentImageIdx = i
                            }
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            }
            .frame(height: 96)
            .background(Tokens.bg)
            .overlay(alignment: .top) {
                Rectangle()
                    .fill(Tokens.border)
                    .frame(height: 0.5)
            }
        }
    }
}

private struct BatchThumb: View {
    let image: ImageRecord
    let isActive: Bool
    let accentColor: Color

    // Cache the thumbnail; loadThumb hit disk on every body render previously.
    @State private var thumb: NSImage? = nil
    @State private var thumbLoaded: Bool = false

    private var count: Int { image.detection?.cells.count ?? 0 }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Group {
                if let ns = thumb {
                    Image(nsImage: ns)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    BatchThumbSim()
                }
            }
            .frame(width: 110, height: 70)
            .clipped()
            .onAppear {
                guard !thumbLoaded else { return }
                thumbLoaded = true
                let url = image.thumbURL
                Task.detached(priority: .utility) {
                    let ns = NSImage(contentsOf: url)
                    await MainActor.run { thumb = ns }
                }
            }

            Text("\(count)")
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(.white)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.black.opacity(0.72))
                )
                .padding(4)
        }
        .frame(width: 110, height: 70)
        .clipShape(RoundedRectangle(cornerRadius: Tokens.Radius.md))
        .overlay(
            RoundedRectangle(cornerRadius: Tokens.Radius.md)
                .strokeBorder(
                    isActive ? accentColor : Color.clear,
                    lineWidth: 1.5
                )
        )
        .background(
            RoundedRectangle(cornerRadius: Tokens.Radius.md)
                .fill(Tokens.bgSunken)
        )
        .animation(Tokens.Motion.easeFast, value: isActive)
    }
}

// MARK: — Empty batch state (pass 12)

/// Shown when ResultsView has a `currentBatch` selected but the batch contains
/// zero images (stale Recents row, all-imports-failed leftover). Replaces the
/// procedural ghost viewer + 8-thumb fallback strip that used to render here.
private struct EmptyBatchState: View {
    @Bindable var state: AppState

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "tray")
                .font(.system(size: 56, weight: .light))
                .foregroundStyle(Tokens.textQuaternary.opacity(0.7))
                .padding(.bottom, 4)
            Text("Batch has no images yet")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Tokens.textSecondary)
            Text("Drop new microscope images on Home to add to this batch.")
                .font(.system(size: 13))
                .foregroundStyle(Tokens.textTertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
            Button("Back to Home") { state.view = .home }
                .appButton(.primary, size: .sm)
                .padding(.top, 4)
        }
        .padding(.vertical, 80)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: — EXIF calibration toast (Pass-17 Lane C)

/// Non-blocking top-bar toast shown when EXIF metadata set this batch's px/µm.
/// Auto-dismissed after 5 s by AppState; the view itself is just a pill.
private struct ExifCalibrationToast: View {
    let message: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "ruler")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.green)
            Text(message)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Tokens.text)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: Tokens.Radius.md, style: .continuous)
                .fill(Tokens.bgElevated)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Tokens.Radius.md, style: .continuous)
                .strokeBorder(Tokens.borderStrong, lineWidth: 0.5)
        )
        .shadow(color: Color.black.opacity(0.14), radius: 8, y: 2)
    }
}

/// Non-blocking toast for keyboard-shortcut exports (⌘E / ⌘⇧E). Mirrors the
/// success/error styling of the ResultsExportPanel inline status row so the
/// two export paths give consistent feedback.
struct ExportFeedbackToast: View {
    let message: String
    let isError: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(isError ? Tokens.danger : Tokens.success)
            Text(message)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Tokens.text)
                .lineLimit(2)
                .truncationMode(.middle)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: Tokens.Radius.md, style: .continuous)
                .fill(Tokens.bgElevated)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Tokens.Radius.md, style: .continuous)
                .strokeBorder(Tokens.borderStrong, lineWidth: 0.5)
        )
        .shadow(color: Color.black.opacity(0.14), radius: 8, y: 2)
    }
}

// MARK: — Detection-failed banner (pass 8)

/// Floating banner shown over the viewer when an image was imported but its
/// detection didn't land — typically because no model was installed, or the
/// Python sidecar crashed. Provides an inline reason + a one-click re-run.
private struct DetectionFailedBanner: View {
    let message: String
    let canRerun: Bool
    let onRerun: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Color.orange)
            VStack(alignment: .leading, spacing: 4) {
                Text("Detection failed for this image")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Tokens.text)
                Text(message)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Tokens.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            Button { onRerun() } label: {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.clockwise")
                    Text("Re-run detection")
                }
                .font(.system(size: 12, weight: .medium))
            }
            .appButton(.primary, size: .sm)
            .disabled(!canRerun)
            .help(canRerun
                  ? "Run the selected detection model on this image again."
                  : "The active model isn't installed. Open Models to install it.")
        }
        .padding(14)
        .frame(maxWidth: 560)
        .background(
            RoundedRectangle(cornerRadius: Tokens.Radius.lg, style: .continuous)
                .fill(Tokens.bgElevated)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Tokens.Radius.lg, style: .continuous)
                .strokeBorder(Tokens.borderStrong, lineWidth: 0.5)
        )
        .shadow(color: Color.black.opacity(0.18), radius: 12, y: 4)
    }
}

// MARK: — Ground-truth F1 panel (pass 17, Lane B)

/// Compares the user's ground-truth annotations against the model's detections
/// for the current image and renders precision / recall / F1. Defensive
/// behavior:
///   • Zero annotations → renders nothing.
///   • Zero detections + N annotations → shows recall = 0 message.
///   • Recomputes live when annotations change (notification) or the user
///     drags the matchRadiusFactor slider.
///
/// The matching algorithm runs on @MainActor — fine for our cell counts
/// (≤ ~1000 typical, hard cap ~5000 — see `AnnotationMatcher`).
private struct GroundTruthPanel: View {
    @Bindable var state: AppState
    /// The same `cells` collection the rest of ResultsSidebar uses — already
    /// filtered by confidence + ROI.
    let detections: [DetectedCell]

    /// Bump on annotation add/remove (NotificationCenter) so SwiftUI re-runs
    /// `body` and the F1 numbers refresh.
    @State private var annotationsTick: Int = 0
    /// Strict ↔ lenient slider — multiplies each detection's diameter to form
    /// the match radius. 1.0 means "anywhere inside the detected cell counts".
    @State private var matchRadiusFactor: Double = 1.0

    @Environment(AppTheme.self) private var theme

    /// Memoized annotations + matcher Score. The repo fetch and the O(N·M)
    /// matcher used to run inside computed properties evaluated 3+ times on
    /// every body pass — including every confidence-slider tick and ROI change,
    /// since this panel lives in ResultsSidebar and re-renders on unrelated
    /// sidebar invalidations. Now they recompute only when their real inputs
    /// change (annotation tick, current image, detection set, match radius)
    /// (finding: groundtruth-panel-redundant-fetches-and-matcher-per-render).
    @State private var cachedAnnotations: [GroundTruthAnnotation] = []
    @State private var cachedScore: AnnotationMatcher.Score? = nil

    /// Single fetch + single matcher pass; caches both results.
    private func recompute() {
        guard let img = state.currentImage else {
            cachedAnnotations = []
            cachedScore = nil
            return
        }
        let anns = state.repos.annotations(for: img.id)
        cachedAnnotations = anns
        cachedScore = AnnotationMatcher.evaluate(annotations: anns,
                                                 detections: detections,
                                                 matchRadiusFactor: matchRadiusFactor)
    }

    var body: some View {
        // Empty-annotation guard: render nothing. Avoids cluttering the
        // sidebar for users who never use this feature.
        Group {
            if cachedAnnotations.isEmpty {
                EmptyView()
            } else {
                content
            }
        }
        .onAppear { recompute() }
        // Recompute on the inputs that actually change the result — not on every
        // unrelated sidebar invalidation.
        .onChange(of: annotationsTick) { _, _ in recompute() }
        .onChange(of: state.currentImage?.id) { _, _ in recompute() }
        .onChange(of: detections.count) { _, _ in recompute() }
        .onChange(of: matchRadiusFactor) { _, _ in recompute() }
        // Recompute on annotation add/remove. ImageId-scoped — we only react
        // when the change applies to the currently-displayed image.
        .onReceive(NotificationCenter.default.publisher(for: .ccAnnotationsChanged)) { note in
            if let id = note.object as? UUID, id == state.currentImage?.id {
                annotationsTick &+= 1
            } else if note.object == nil {
                annotationsTick &+= 1
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        let s = cachedScore ?? AnnotationMatcher.evaluate(
            annotations: cachedAnnotations,
            detections: detections,
            matchRadiusFactor: matchRadiusFactor)
        VStack(spacing: 0) {
            Divider().overlay(Tokens.divider)
            VStack(spacing: 0) {
                SectionHeader(
                    title: "Ground truth",
                    trailing: AnyView(
                        HStack(spacing: 6) {
                            Button("Export…") { exportAnnotations() }
                                .buttonStyle(.plain)
                                .font(.system(size: 12))
                                .foregroundStyle(theme.accentColor)
                                .help("Save annotations.json + annotations.csv to a folder.")
                            Button {
                                resetAnnotations()
                            } label: {
                                Icon("trash", size: 11)
                                    .foregroundStyle(Tokens.textTertiary)
                            }
                            .buttonStyle(.plain)
                            .help("Delete every ground-truth annotation on this image.")
                        }
                    )
                )

                // Headline counts row.
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text("\(cachedAnnotations.count)")
                            .font(.system(size: 14, weight: .semibold, design: .monospaced))
                            .foregroundStyle(Tokens.text)
                        Text("annotations · matched to")
                            .font(.system(size: 11.5))
                            .foregroundStyle(Tokens.textSecondary)
                        Text("\(s.tp)/\(detections.count)")
                            .font(.system(size: 11.5, design: .monospaced))
                            .foregroundStyle(Tokens.text)
                        Text("detections @")
                            .font(.system(size: 11.5))
                            .foregroundStyle(Tokens.textSecondary)
                        Text(String(format: "%.1f×", matchRadiusFactor))
                            .font(.system(size: 11.5, design: .monospaced))
                            .foregroundStyle(Tokens.textSecondary)
                        Text("dia.")
                            .font(.system(size: 11.5))
                            .foregroundStyle(Tokens.textSecondary)
                    }

                    if detections.isEmpty {
                        Text("Detection ran but matched 0 of \(cachedAnnotations.count) annotations (recall = 0).")
                            .font(.system(size: 11.5))
                            .foregroundStyle(Tokens.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.top, 2)
                .padding(.bottom, 12)

                // Metric rows.
                metricRow("Precision", value: s.precision)
                metricRow("Recall",    value: s.recall)
                f1Row(value: s.f1)
                Divider().overlay(Tokens.divider)
                    .padding(.vertical, 8)
                countRow("False positives", count: s.fp,
                         help: "Detections without a matching annotation.")
                countRow("False negatives", count: s.fn,
                         help: "Annotations without a matching detection.")

                // Slider.
                VStack(spacing: 6) {
                    HStack {
                        Text("Match radius")
                            .font(.system(size: 11.5))
                            .foregroundStyle(Tokens.textSecondary)
                        Spacer()
                        Text(String(format: "%.2f× diameter", matchRadiusFactor))
                            .font(.system(size: 11.5, design: .monospaced))
                            .foregroundStyle(Tokens.textTertiary)
                    }
                    Slider(value: $matchRadiusFactor, in: 0.3...2.0)
                        .tint(theme.accentColor)
                    HStack {
                        Text("0.3× (strict)")
                        Spacer()
                        Text("2.0× (lenient)")
                    }
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(Tokens.textTertiary)
                }
                .padding(.top, 12)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 18)
        }
    }

    private func metricRow(_ label: String, value: Double?) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 12.5))
                .foregroundStyle(Tokens.textSecondary)
            Spacer()
            Text(value.map { String(format: "%.2f", $0) } ?? "—")
                .font(.system(size: 13, weight: .medium, design: .monospaced))
                .foregroundStyle(Tokens.text)
        }
        .padding(.vertical, 4)
    }

    /// F1 row — visually emphasized ("big number") per the brief.
    private func f1Row(value: Double?) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text("F1")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Tokens.text)
            Spacer()
            Text(value.map { String(format: "%.2f", $0) } ?? "—")
                .font(.system(size: 22, weight: .semibold, design: .monospaced))
                .foregroundStyle(Tokens.text)
        }
        .padding(.vertical, 6)
    }

    private func countRow(_ label: String, count: Int, help: String) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 12.5))
                .foregroundStyle(Tokens.textSecondary)
                .help(help)
            Spacer()
            Text("\(count)")
                .font(.system(size: 12.5, design: .monospaced))
                .foregroundStyle(Tokens.text)
        }
        .padding(.vertical, 3)
    }

    // MARK: — Actions

    /// Reset (delete every annotation on this image), with a confirmation dialog.
    private func resetAnnotations() {
        guard let img = state.currentImage else { return }
        let alert = NSAlert()
        alert.messageText = "Remove all ground-truth annotations?"
        alert.informativeText = "This deletes the \(cachedAnnotations.count) annotation\(cachedAnnotations.count == 1 ? "" : "s") on this image. The detection itself is not affected."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        state.repos.deleteAllAnnotations(for: img.id)
        annotationsTick &+= 1
        NotificationCenter.default.post(name: .ccAnnotationsChanged, object: img.id)
    }

    /// Write `<basename>.annotations.json` + `<basename>.annotations.csv`
    /// into a user-picked folder.
    private func exportAnnotations() {
        guard let img = state.currentImage else { return }
        // Fetch fresh for the export (infrequent, off the render path) so the
        // written file can't lag the cached mirror.
        let anns = state.repos.annotations(for: img.id)
        guard !anns.isEmpty else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose folder"
        panel.message = "Export annotations.json + annotations.csv to this folder."
        let base = (img.fileName as NSString).deletingPathExtension
        panel.begin { resp in
            guard resp == .OK, let folder = panel.url else { return }
            let jsonURL = folder.appendingPathComponent("\(base).annotations.json")
            let csvURL  = folder.appendingPathComponent("\(base).annotations.csv")
            try? ExportService.writeAnnotationsJSON(image: img,
                                                    annotations: anns,
                                                    pxPerUm: state.pxPerUm,
                                                    to: jsonURL)
            try? ExportService.writeAnnotationsCSV(image: img,
                                                   annotations: anns,
                                                   pxPerUm: state.pxPerUm,
                                                   to: csvURL)
        }
    }
}


