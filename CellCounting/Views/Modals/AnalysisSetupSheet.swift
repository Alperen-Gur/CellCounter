import SwiftUI
import AppKit

struct AnalysisSetupSheet: View {
    @Bindable var state: AppState
    let jobId: UUID
    @State private var settings = AnalysisRunSettings()
    @State private var preset: AnalysisTaskPreset = .countCells
    @State private var selectedItemId: UUID?
    @State private var busy = false
    @State private var edited = false
    @State private var message: String?
    @State private var previewImage: NSImage?
    @State private var previewCells: [DetectedCell] = []
    @State private var previewImageId: UUID?
    @State private var previewError: String?
    @State private var preparingPlane = false
    /// Drag-to-measure on the preview sets the expected cell size.
    @State private var measuringCell = false
    @State private var measureStart: CGPoint?
    @State private var measureEnd: CGPoint?
    /// "Set diameter" chosen for a non-Cellpose model while the stored value
    /// is still 0 (automatic).
    @State private var choosingSize = false
    @State private var previewViewSize: CGSize = .zero
    // Pixel scale: every image has its own (`ImageScale`).
    /// Scales chosen here for single images; a nil value removes one.
    @State private var ownScales: [UUID: ImageScale.Value?] = [:]
    @State private var scaleEntries: [AppState.SetupScaleEntry] = []
    @State private var settingScale = false
    /// The scale editor applies to the selected image only (else to images without a scale).
    @State private var scaleForSelected = false
    @State private var scaleValue: Double = 0
    @State private var scaleMethod: ScaleMethod = .typed
    @State private var overrideFiles = false
    @State private var measuringScaleBar = false
    @State private var barLengthPx: Double = 0
    @State private var barLengthUm: Double = 100
    @State private var presetName = ""
    @State private var presetSaved: String?
    @State private var presets: [CalibrationPresetRecord] = []
    private enum ScaleMethod: Equatable { case typed, scaleBar, preset(String) }
    private var job: AnalysisJob? { state.jobScheduler.job(jobId) }
    private var selectedItem: AnalysisJobItem? { job?.items.first { $0.id == selectedItemId } ?? job?.items.first }
    private var selectedImage: ImageRecord? { selectedItem?.imageId.flatMap { state.repos.image(id: $0) } }
    private var modelReady: Bool { state.detectorRegistry.isInstalled(settings.modelId, models: state.models) }

    init(state: AppState, jobId: UUID) {
        self.state = state
        self.jobId = jobId
        let job = state.jobScheduler.job(jobId)
        _settings = State(initialValue: job?.settings ?? AnalysisRunSettings())
        _preset = State(initialValue: job?.taskPreset ?? .countCells)
        _selectedItemId = State(initialValue: job?.items.first?.id)
    }

    private var imageSelection: Binding<UUID?> {
        Binding(get: { selectedItem?.id }, set: { selectedItemId = $0 })
    }

    private struct SourcePreviewKey: Equatable {
        var itemId: UUID?
        var imageId: UUID?
        var family: String
        var sourcePlane: Bool
        var channel: Int
        var channels: [Int]
        var projection: String
    }
    private var sourcePreviewKey: SourcePreviewKey {
        SourcePreviewKey(itemId: selectedItem?.id, imageId: selectedItem?.imageId,
                         family: settings.modelFamily, sourcePlane: settings.supportsSourceChannels && modelReady,
                         channel: settings.segmentChannel, channels: settings.channels, projection: settings.zProjection)
    }
    private struct MaskPreviewKey: Equatable {
        var imageId: UUID?
        var detectionId: UUID?
        var revision: Int?
        var settings: AnalysisRunSettings
    }
    private var maskPreviewKey: MaskPreviewKey {
        MaskPreviewKey(imageId: selectedImage?.id, detectionId: selectedImage?.detection?.id,
                       revision: selectedImage?.detection?.cellsRevision, settings: selectedSettings)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Set up analysis").font(.title2.weight(.semibold))
                    Text("\(job?.title ?? "Batch") · \(job?.items.count ?? 0) images").foregroundStyle(.secondary)
                }
                Spacer()
                Button("Close") { state.jobScheduler.cancelPreview(); state.analysisSetupJobId = nil }.keyboardShortcut(.cancelAction)
            }
            HStack(alignment: .top, spacing: 22) {
                VStack(alignment: .leading, spacing: 12) {
                    Picker("Representative image", selection: imageSelection) {
                        if job?.items.isEmpty != false { Text("No images").tag(nil as UUID?) }
                        ForEach(job?.items ?? []) { item in Text(item.fileName).tag(Optional(item.id)) }
                    }
                    GeometryReader { geo in
                        ZStack {
                            Rectangle().fill(Color.black.opacity(0.9))
                            if let image = previewImage {
                                Image(nsImage: image).resizable().scaledToFit()
                                if let record = selectedImage {
                                    Canvas { context, size in
                                        let scale = min(size.width / Double(max(1, record.widthPx)), size.height / Double(max(1, record.heightPx)))
                                        let offset = CGPoint(x: (size.width - Double(record.widthPx) * scale) / 2,
                                                             y: (size.height - Double(record.heightPx) * scale) / 2)
                                        for cell in previewCells {
                                            var path = Path()
                                            if let contour = cell.contourPx, let first = contour.first {
                                                path.move(to: CGPoint(x: first.x * scale + offset.x, y: first.y * scale + offset.y))
                                                for point in contour.dropFirst() { path.addLine(to: CGPoint(x: point.x * scale + offset.x, y: point.y * scale + offset.y)) }
                                                path.closeSubpath()
                                            } else {
                                                let radius = cell.diameterPx * scale / 2
                                                path.addEllipse(in: CGRect(x: cell.cx * scale + offset.x - radius,
                                                                          y: cell.cy * scale + offset.y - radius,
                                                                          width: radius * 2, height: radius * 2))
                                            }
                                            context.stroke(path, with: .color(.green), lineWidth: 1)
                                        }
                                    }
                                }
                            } else { Text("Preparing representative image…").foregroundStyle(.white) }
                            measurementOverlay
                        }
                        .contentShape(Rectangle())
                        .gesture(measureGesture(in: geo.size),
                                 including: measuringCell || measuringScaleBar ? .all : .subviews)
                    }.frame(minWidth: 380).frame(height: 310)
                    if preparingPlane {
                        Text("Preparing selected channel…").font(.caption).foregroundStyle(.secondary)
                    }
                    if let previewError {
                        Text(previewError).font(.caption).foregroundStyle(.orange).lineLimit(3)
                    }
                    if let image = selectedImage {
                        Text("\(image.widthPx) × \(image.heightPx) pixels · \(previewCells.count) masks")
                            .font(.callout).foregroundStyle(.secondary)
                        if image.detection?.runSettings?.hasSameInputs(as: selectedSettings) != true, image.detection != nil {
                            Label("Settings changed — preview again to see their effect.", systemImage: "arrow.clockwise")
                                .font(.callout).foregroundStyle(.orange)
                        }
                    }
                    Text("The preview runs on this whole image. Matching results are reused when you start the batch.")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }.frame(maxWidth: .infinity)

                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        Picker("Task", selection: $preset) { ForEach(AnalysisTaskPreset.allCases) { Text($0.title).tag($0) } }
                            .onChange(of: preset) { _, new in settings = new.applying(to: settings); edited = true }
                        Text(preset.detail).font(.callout).foregroundStyle(.secondary)
                        Picker("Model", selection: $settings.modelId) {
                            // Unavailable and coming-soon rows cannot be picked;
                            // a saved run that names one still shows it.
                            if !state.models.contains(where: { $0.id == settings.modelId && $0.family != .ensemble && $0.isSelectable }) {
                                Text(settings.modelName).tag(settings.modelId)
                            }
                            ForEach(state.models.filter { $0.family != .ensemble && $0.isSelectable }) { model in Text(model.name).tag(model.id) }
                        }.onChange(of: settings.modelId) { _, id in
                            if let model = state.models.first(where: { $0.id == id }) {
                                settings.modelName = model.name; settings.modelFamily = model.family.rawValue
                                if settings.usesOmnipose, settings.omniposeSettings == nil {
                                    settings.omniposeSettings = state.omniposeSettings
                                }
                            }
                            edited = true
                        }
                        if !modelReady {
                            Text("Install this model in Models to run detection. You can import and inspect images now.")
                                .font(.callout).foregroundStyle(.secondary)
                            Button("Open Models") { saveThen { state.analysisSetupJobId = nil; state.view = .models } }
                        }
                        if settings.modelId == "cw-manual" {
                            TextField("Manual threshold (raw intensity)", value: $settings.manualThreshold, format: .number)
                                .textFieldStyle(.roundedBorder)
                        }
                        if settings.usesOmnipose {
                            DisclosureGroup("Omnipose reconstruction") {
                                OmniposeSettingsControls(settings: Binding(
                                    get: { settings.omniposeSettings ?? .init() },
                                    set: { settings.omniposeSettings = $0 }
                                ))
                            }
                        }
                        Divider()
                        pixelScaleControls
                        expectedCellSizeControls
                        Divider()
                        if settings.supportsSourceChannels {
                        Picker("Z projection", selection: $settings.zProjection) {
                            Text("Maximum").tag("max"); Text("Mean").tag("mean")
                            Text("Sum").tag("sum"); Text("Central plane").tag("none")
                        }
                        Stepper("Segmentation channel: \(settings.segmentChannel + 1)", value: $settings.segmentChannel, in: 0...63)
                        Text("Channel numbers follow the source acquisition. Display composites are for inspection; inference reads the source where supported.")
                            .font(.caption).foregroundStyle(.secondary)
                        } else {
                            Text("This model analyzes the display plane. Channel and Z controls are available with Cellpose, Omnipose, and Classical models.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        HStack { Text("Confidence"); Slider(value: $settings.confidence, in: 0...1); Text(settings.confidence, format: .number.precision(.fractionLength(2))) }
                        Toggle("Split touching cells", isOn: $settings.watershedSplit)
                        Toggle("Subtract background", isOn: $settings.backgroundSubtract)
                        Toggle("Use GPU when available", isOn: $settings.useGPU)
                        DisclosureGroup("Advanced preprocessing") {
                            Picker("Preprocessing", selection: $settings.preprocessingPreset) {
                                ForEach(PreprocessingPreset.allCases, id: \.rawValue) { Text($0.label).tag($0.rawValue) }
                            }
                            Stepper("Background radius: \(settings.rollingBallRadius) px", value: $settings.rollingBallRadius, in: 1...1000)
                            Stepper("Split distance: \(settings.watershedMinDistanceUm) µm", value: $settings.watershedMinDistanceUm, in: 1...1000)
                        }
                    }.padding(.trailing, 5)
                }.frame(width: 310, height: 420)
            }
            .disabled(busy)
            if let error = settings.validationError { Text(error).foregroundStyle(.red).font(.callout) }
            if let message { Text(message).foregroundStyle(.secondary).font(.callout).lineLimit(3) }
            if busy { HStack { ProgressView().controlSize(.small); Text(state.processingStageLine.isEmpty ? "Working…" : state.processingStageLine).font(.callout).lineLimit(1) } }
            // App-wide; can also be changed while the batch runs.
            ModelResourceInlineRow(state: state)
            Divider()
            HStack {
                Button("Import and inspect") { submit(importOnly: true) }
                Spacer()
                Button("Preview this image") { preview() }
                    .disabled(!modelReady || state.jobScheduler.activeCount > 0 || TrainingService.isTrainingActive
                              || !selectedHasScale)
                // Start is blocked while any image has no scale.
                Button("Process batch") { submit(importOnly: false) }
                    .buttonStyle(.borderedProminent).disabled(!modelReady || scaleSummary.missing > 0)
                    .help(scaleSummary.missing > 0 ? "Set a scale for every image first." : "")
            }.disabled(busy || settings.validationError != nil)
        }
        .padding(24).frame(width: 850)
        .background(Tokens.bg)
        .focusedSceneValue(\.cellCounterShortcuts, shortcutActions)
        .task(id: sourcePreviewKey) { await loadSourcePreview() }
        .task(id: maskPreviewKey) { await loadPreviewMasks() }
        .onChange(of: job?.settings) { _, new in if let new, !edited { settings = new } }
        .onChange(of: selectedItem?.imageId) { _, _ in
            measuringCell = false; measuringScaleBar = false; measureStart = nil; measureEnd = nil
        }
        .onChange(of: settings) { old, new in if old != new { edited = true } }
        // Each image's scale: from its file, set here, or the scale for images without one.
        .onAppear { refreshScaleEntries() }
        .onChange(of: job?.items.map(\.imageId)) { _, _ in refreshScaleEntries() }
        .onChange(of: ownScales) { _, _ in refreshScaleEntries() }
        .onChange(of: fallbackScale) { _, _ in refreshScaleEntries() }
    }

    // MARK: Expected cell size

    private var sizeBehavior: SizeHint.Behavior { SizeHint.behavior(for: settings) }
    private var sizeIsAutomatic: Bool { SizeHint.isAutomatic(settings.expectedDiameterUm) }

    /// Automatic stores 0, as before. For Cellpose-family models, choosing a
    /// value starts from the size the automatic rule already uses, so
    /// segmentation is unchanged until it is edited. Other models treat any
    /// value as a change (Omnipose starts rescaling, Classical widens seed
    /// spacing), so their field opens empty and stays automatic until a
    /// diameter is typed or measured.
    private var automaticSize: Binding<Bool> {
        Binding(get: { sizeIsAutomatic && !choosingSize }, set: { automatic in
            if automatic {
                settings.expectedDiameterUm = 0
                choosingSize = false
            } else if sizeIsAutomatic {
                if sizeBehavior == .cellposeRescale {
                    settings.expectedDiameterUm = SizeHint.automaticDiameterUm(thresholds: settings.thresholds)
                } else {
                    choosingSize = true
                }
            }
        })
    }

    private var automaticSizeLabel: String {
        sizeBehavior == .cellposeRescale
            ? "Automatic (midpoint of size classes, \(SizeHint.format(SizeHint.automaticDiameterUm(thresholds: settings.thresholds))) µm)"
            : "Automatic"
    }

    @ViewBuilder private var expectedCellSizeControls: some View {
        Text("Expected cell size").font(.headline)
        Picker("Expected cell size", selection: automaticSize) {
            Text(automaticSizeLabel).tag(true)
            Text("Set diameter").tag(false)
        }
        .pickerStyle(.radioGroup).labelsHidden()
        HStack {
            if !sizeIsAutomatic || choosingSize {
                TextField("Diameter", value: $settings.expectedDiameterUm, format: .number)
                    .textFieldStyle(.roundedBorder).frame(width: 80)
                Text("µm").foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Button(measuringCell ? "Cancel measuring" : "Measure on image") {
                measuringCell.toggle()
                if measuringCell { measureStart = nil; measureEnd = nil }
            }
            .disabled(previewImage == nil || selectedImage == nil || !(selectedPxPerUm > 0))
            .help("Drag across a typical cell in the preview to set its diameter.")
        }
        // At this image's own scale: images with other scales get another size in pixels.
        SizeHintDetails(expectedDiameterUm: settings.expectedDiameterUm, thresholds: settings.thresholds,
                        pxPerUm: selectedPxPerUm, behavior: sizeBehavior)
    }

    /// The line drawn while measuring, labelled with its length in µm.
    @ViewBuilder private var measurementOverlay: some View {
        if measuringScaleBar, measureStart == nil {
            Text("Drag along the scale bar")
                .font(.callout.weight(.medium)).foregroundStyle(.white)
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(Color.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 6))
                .allowsHitTesting(false)
        }
        if measuringScaleBar, let start = measureStart, let end = measureEnd {
            let label = measuredLengthPx(start, end, in: nil).map { "\(Int($0.rounded())) px" } ?? ""
            Canvas { context, _ in
                var path = Path()
                path.move(to: start); path.addLine(to: end)
                context.stroke(path, with: .color(.cyan), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                context.draw(Text(label).font(.system(size: 11, weight: .semibold).monospacedDigit()).foregroundStyle(.cyan),
                             at: CGPoint(x: (start.x + end.x) / 2, y: min(start.y, end.y) - 12))
            }
            .allowsHitTesting(false)
        }
        if measuringCell, measureStart == nil {
            Text("Drag across a typical cell")
                .font(.callout.weight(.medium)).foregroundStyle(.white)
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(Color.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 6))
                .allowsHitTesting(false)
        }
        // Only while measuring: afterwards the stored diameter is the record,
        // and a later px/µm edit would relabel this line with another value.
        if measuringCell, let start = measureStart, let end = measureEnd {
            let label = measuredLengthPx(start, end, in: nil).flatMap {
                SizeHint.measuredDiameterUm(lengthPx: $0, pxPerUm: selectedPxPerUm)
            }.map { "\(SizeHint.format($0)) µm" } ?? ""
            Canvas { context, _ in
                var path = Path()
                path.move(to: start); path.addLine(to: end)
                context.stroke(path, with: .color(.yellow), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                for point in [start, end] {
                    context.fill(Path(ellipseIn: CGRect(x: point.x - 3, y: point.y - 3, width: 6, height: 6)), with: .color(.yellow))
                }
                context.draw(Text(label).font(.system(size: 11, weight: .semibold).monospacedDigit()).foregroundStyle(.yellow),
                             at: CGPoint(x: (start.x + end.x) / 2, y: min(start.y, end.y) - 12))
            }
            .allowsHitTesting(false)
        }
    }

    private func measuredLengthPx(_ a: CGPoint, _ b: CGPoint, in size: CGSize?) -> Double? {
        guard let record = selectedImage else { return nil }
        return LineMeasurement.imagePixelLength(
            from: a, to: b, viewSize: size ?? previewViewSize,
            imageSize: CGSize(width: record.widthPx, height: record.heightPx))
    }

    private func measureGesture(in size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                previewViewSize = size
                measureStart = value.startLocation; measureEnd = value.location
            }
            .onEnded { value in
                previewViewSize = size
                measureStart = value.startLocation; measureEnd = value.location
                if measuringScaleBar {
                    // Full-resolution pixels, like the scale-bar tab of Calibrate.
                    if let length = measuredLengthPx(value.startLocation, value.location, in: size), length > 1 {
                        barLengthPx = length
                        updateScaleFromBar()
                        measuringScaleBar = false
                    }
                    return
                }
                if let length = measuredLengthPx(value.startLocation, value.location, in: size),
                   let um = SizeHint.measuredDiameterUm(lengthPx: length, pxPerUm: selectedPxPerUm) {
                    settings.expectedDiameterUm = um
                    measuringCell = false
                }
            }
    }

    private var shortcutActions: ScreenShortcutActions {
        var actions = ScreenShortcutActions()
        actions.isModalContext = true
        actions.cancel = { state.jobScheduler.cancelPreview(); state.analysisSetupJobId = nil }
        if !busy, settings.validationError == nil {
            actions.save = { saveThen { message = "Setup saved." } }
            if modelReady {
                if scaleSummary.missing == 0 { actions.run = { submit(importOnly: false) } }
                if state.jobScheduler.activeCount == 0, !TrainingService.isTrainingActive, selectedHasScale {
                    actions.preview = { preview() }
                }
            }
        }
        return actions
    }

    /// One task per source/plane selection. Metadata, job status, confidence and
    /// mask updates never restart the image reader, and leaving cancels it.
    private func loadSourcePreview() async {
        guard let item = selectedItem else { return }
        previewError = nil
        preparingPlane = false
        if previewImageId != item.imageId {
            previewImage = nil
            previewImageId = item.imageId
        }
        if item.imageId == nil {
            do { _ = try await state.jobScheduler.prepareSample(jobId, itemId: item.id) }
            catch { if !Task.isCancelled { previewError = error.localizedDescription } }
            return // Observed imageId starts the next task after import finishes.
        }
        guard let record = selectedImage else { return }
        let snapshot = settings
        if previewImageId != record.id {
            previewImage = nil
            previewImageId = record.id
        }
        let url = record.displayURL
        let original = await Task.detached(priority: .userInitiated) {
            ImageLoader.cachedReviewPreview(at: url)
        }.value
        guard !Task.isCancelled else { return }
        previewImage = original
        guard snapshot.supportsSourceChannels && modelReady else {
            preparingPlane = false
            if original == nil { previewError = "This image could not be displayed." }
            return
        }
        preparingPlane = true
        do {
            let data = try await TrainingDatasetService.preview(image: record, settings: snapshot)
            guard !Task.isCancelled else { return }
            if let image = NSImage(data: data) { previewImage = image }
            else { previewError = "The selected channel could not be displayed. Showing the original image." }
        } catch {
            guard !Task.isCancelled else { return }
            previewError = "Showing the original image. Selected channel: " + error.localizedDescription
        }
        preparingPlane = false
    }

    private func loadPreviewMasks() async {
        previewCells = []
        guard let record = selectedImage, let detection = record.detection,
              detection.runSettings?.hasSameInputs(as: selectedSettings) == true else { return }
        let cells = await state.loadCells(for: detection)
        guard !Task.isCancelled else { return }
        previewCells = cells
    }
    private func saveThen(_ action: @escaping @MainActor () -> Void) {
        busy = true
        Task { @MainActor in
            defer { busy = false }
            do { try await saveDraft(); action() }
            catch { message = error.localizedDescription }
        }
    }
    private func preview() {
        guard let item = selectedItem else { return }
        busy = true; message = nil
        Task {
            defer { busy = false }
            do {
                try await saveDraft()
                try await state.commitAnalysisSetup(jobId)
                try await state.jobScheduler.preview(jobId, itemId: item.id)
                message = "Preview complete. Review the masks before processing the batch."
            } catch { message = error.localizedDescription }
        }
    }
    private func submit(importOnly: Bool) {
        busy = true; message = nil
        Task {
            defer { busy = false }
            do {
                try await saveDraft()
                try await state.commitAnalysisSetup(jobId)
                state.jobScheduler.maxParallel = state.maxParallel
                try await state.jobScheduler.enqueue(jobId, importOnly: importOnly)
                UserDefaults.standard.set(preset.resultsWorkspace, forKey: "cc-results-workspace-v1")
                state.analysisSetupJobId = nil
                state.view = importOnly ? .results : .queue
            } catch { message = error.localizedDescription }
        }
    }

    /// Settings, task and the scales chosen for single images, together.
    private func saveDraft() async throws {
        try await state.saveAnalysisSetupDraft(jobId, settings: settings, preset: preset, ownScales: ownScales)
        ownScales = [:]
        refreshScaleEntries()
    }

    // MARK: Pixel scale

    /// The job's scale for images without one.
    private var fallbackScale: ImageScale.Value? {
        ImageScale.Value(settings.pxPerUm, source: settings.calibrationSource)
    }
    private var scaleSummary: ImageScale.Summary { ImageScale.summarize(scaleEntries.map(\.summaryEntry)) }
    private var selectedScaleEntry: AppState.SetupScaleEntry? {
        scaleEntries.first { $0.id == selectedItem?.id }
    }
    /// The selected image's own scale; previews and the size hint use it.
    private var selectedPxPerUm: Double { selectedScaleEntry?.scale?.pxPerUm ?? 0 }
    private var selectedHasScale: Bool { selectedScaleEntry?.scale != nil }
    /// The settings the selected image is analysed with.
    private var selectedSettings: AnalysisRunSettings { settings.withScale(selectedScaleEntry?.scale) }
    private var objectiveWarning: String? {
        ImageScale.objectiveWarning(scaleEntries.map { (fileName: $0.fileName, pxPerUm: $0.scale?.pxPerUm) })
    }
    /// Images the editor's override would replace the file's scale of.
    private var overridableEntries: [AppState.SetupScaleEntry] {
        if scaleForSelected {
            guard let entry = selectedScaleEntry, entry.file != nil else { return [] }
            return [entry]
        }
        return scaleEntries.filter { $0.file != nil && ($0.own == nil || ImageScale.isOverride($0.own?.source)) }
    }
    private var editorSource: String {
        switch scaleMethod {
        case .typed: return ImageScale.typedSource
        case .scaleBar: return ImageScale.scaleBarSource
        case .preset(let name): return ImageScale.presetSource(name)
        }
    }
    private var offersSavePreset: Bool {
        if case .preset = scaleMethod { return false }
        return true
    }
    private var editorCanApply: Bool {
        guard ImageScale.isUsable(scaleValue) else { return false }
        if scaleForSelected {
            guard let entry = selectedScaleEntry else { return false }
            return entry.file == nil || overrideFiles
        }
        return true
    }

    private func refreshScaleEntries() {
        scaleEntries = state.setupScaleEntries(jobId: jobId, fallback: fallbackScale, ownScales: ownScales)
    }

    private func openScaleEditor(forSelected: Bool) {
        scaleForSelected = forSelected
        overrideFiles = false
        presetSaved = nil
        let current = forSelected ? selectedScaleEntry?.scale?.pxPerUm : fallbackScale?.pxPerUm
        scaleValue = current ?? 0
        scaleMethod = .typed
        presets = state.repos.calibrationPresets()
        settingScale = true
    }

    private func updateScaleFromBar() {
        guard barLengthPx > 1, barLengthUm > 0 else { return }
        scaleValue = barLengthPx / barLengthUm
        scaleMethod = .scaleBar
    }

    private func applyScaleEditor() {
        guard editorCanApply else { return }
        let value = ImageScale.Value(pxPerUm: scaleValue, source: editorSource)
        func override(_ file: ImageScale.Value) -> ImageScale.Value {
            ImageScale.Value(pxPerUm: scaleValue, source: ImageScale.overrideSource(filePxPerUm: file.pxPerUm))
        }
        if scaleForSelected, let entry = selectedScaleEntry {
            if let file = entry.file { ownScales[entry.id] = .some(override(file)) }
            else { ownScales[entry.id] = .some(value) }
        } else {
            settings.pxPerUm = value.pxPerUm
            settings.calibrationSource = value.source
            if overrideFiles {
                for entry in overridableEntries {
                    if let file = entry.file { ownScales[entry.id] = .some(override(file)) }
                }
            }
        }
        edited = true
        settingScale = false
        measuringScaleBar = false
    }

    @ViewBuilder private var pixelScaleControls: some View {
        let summary = scaleSummary
        Text("Pixel scale").font(.headline)
        VStack(alignment: .leading, spacing: 2) {
            ForEach(summary.lines, id: \.self) { line in Text(line) }
            if let line = summary.readOnImportLine { Text(line).foregroundStyle(.secondary) }
            if let line = summary.missingLine {
                HStack {
                    Label(line, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                    Spacer(minLength: 0)
                    Button("Set scale…") { openScaleEditor(forSelected: false) }
                }
            }
        }
        .font(.callout)
        if summary.missing > 0 {
            Text("Set a scale for every image before starting. Three ways: a scale recorded in an image's file is used automatically; draw a line along the scale bar on the preview; or type px/µm.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        if let warning = objectiveWarning {
            Label(warning, systemImage: "exclamationmark.triangle")
                .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
        }
        HStack(alignment: .firstTextBaseline) {
            Text("For images without a scale: " + (fallbackScale.map { "\(ImageScale.format($0.pxPerUm)) px/µm (\(ImageScale.label($0.source)))" } ?? "not set"))
                .font(.caption).foregroundStyle(.secondary)
            Spacer(minLength: 0)
            if summary.missing == 0 { Button("Change…") { openScaleEditor(forSelected: false) }.font(.caption) }
        }
        if let entry = selectedScaleEntry {
            HStack(alignment: .firstTextBaseline) {
                Text("This image: " + (entry.scale.map { ImageScale.caption($0.value) }
                                       ?? (entry.readOnImport ? "read from the file when imported" : "no scale")))
                    .font(.caption)
                Spacer(minLength: 0)
                Button("Change…") { openScaleEditor(forSelected: true) }.font(.caption)
            }
        }
        if settingScale { scaleEditor }
    }

    @ViewBuilder private var scaleEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Apply to", selection: $scaleForSelected) {
                Text("Images without a scale").tag(false)
                if selectedScaleEntry != nil { Text("Only this image").tag(true) }
            }
            .pickerStyle(.radioGroup)
            .onChange(of: scaleForSelected) { _, _ in overrideFiles = false }
            HStack {
                TextField("px/µm", value: Binding(get: { scaleValue },
                                                   set: { scaleValue = $0; scaleMethod = .typed }), format: .number)
                    .textFieldStyle(.roundedBorder).frame(width: 90)
                Text("px/µm").foregroundStyle(.secondary)
                Spacer(minLength: 0)
                if !presets.isEmpty {
                    Menu("Presets") {
                        ForEach(presets) { preset in
                            Button("\(preset.name) · \(ImageScale.format(preset.pxPerUm)) px/µm") {
                                scaleValue = preset.pxPerUm
                                scaleMethod = .preset(preset.name)
                            }
                        }
                    }
                    .fixedSize()
                }
            }
            HStack {
                Button(measuringScaleBar ? "Cancel drawing" : "Draw on the scale bar") {
                    measuringScaleBar.toggle()
                    measuringCell = false
                    measureStart = nil; measureEnd = nil
                }
                .disabled(previewImage == nil || selectedImage == nil)
                if barLengthPx > 0 {
                    Text("\(Int(barLengthPx.rounded())) px =").foregroundStyle(.secondary)
                    TextField("µm", value: Binding(get: { barLengthUm },
                                                    set: { barLengthUm = $0; updateScaleFromBar() }), format: .number)
                        .textFieldStyle(.roundedBorder).frame(width: 60)
                    Text("µm").foregroundStyle(.secondary)
                }
            }
            if !overridableEntries.isEmpty {
                Toggle(scaleForSelected ? "Override the file's scale for this image"
                                        : "Override the file's scale for \(ImageScale.countText(overridableEntries.count))",
                       isOn: $overrideFiles)
                    .toggleStyle(.checkbox)
                if overrideFiles, ImageScale.isUsable(scaleValue) {
                    Text("Your value: \(ImageScale.format(scaleValue)) px/µm").foregroundStyle(.orange)
                    ForEach(ImageScale.overrideLines(yours: scaleValue, files: overridableEntries.compactMap { $0.file?.pxPerUm }),
                            id: \.self) { line in
                        Text(line).foregroundStyle(.orange)
                    }
                    Text("Recorded as “manual override (file: … px/µm)”.").foregroundStyle(.secondary)
                }
            }
            if scaleForSelected, let entry = selectedScaleEntry, entry.own != nil {
                Button(entry.file != nil ? "Use the file's scale again" : "Remove this image's own scale") {
                    ownScales[entry.id] = .some(nil)
                    edited = true
                    settingScale = false
                }
            }
            HStack {
                Button("Apply") { applyScaleEditor() }.disabled(!editorCanApply)
                Button("Cancel") { settingScale = false; measuringScaleBar = false }
                Spacer(minLength: 0)
            }
            // Offered after a scale-bar measurement or a typed value.
            if ImageScale.isUsable(scaleValue), offersSavePreset {
                HStack {
                    TextField("Save as preset, e.g. Nikon Ts2 · 10×", text: $presetName)
                        .textFieldStyle(.roundedBorder)
                    Button("Save as preset") {
                        let name = presetName.trimmingCharacters(in: .whitespaces)
                        guard !name.isEmpty else { return }
                        state.repos.upsertCalibrationPreset(CalibrationPresetRecord(name: name, pxPerUm: scaleValue))
                        presets = state.repos.calibrationPresets()
                        presetSaved = name
                        presetName = ""
                    }
                    .disabled(presetName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                if let presetSaved { Text("Saved preset “\(presetSaved)”.").foregroundStyle(.secondary) }
            }
        }
        .font(.caption)
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Tokens.bgSunken))
    }
}
