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
                       revision: selectedImage?.detection?.cellsRevision, settings: settings)
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
                    GeometryReader { _ in
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
                        }
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
                        if image.detection?.runSettings?.hasSameInputs(as: settings) != true, image.detection != nil {
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
                            if !state.models.contains(where: { $0.id == settings.modelId && $0.family != .ensemble }) {
                                Text(settings.modelName).tag(settings.modelId)
                            }
                            ForEach(state.models.filter { $0.family != .ensemble }) { model in Text(model.name).tag(model.id) }
                        }.onChange(of: settings.modelId) { _, id in
                            if let model = state.models.first(where: { $0.id == id }) {
                                settings.modelName = model.name; settings.modelFamily = model.family.rawValue
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
                        Divider()
                        Text("Pixel calibration").font(.headline)
                        HStack {
                            TextField("Pixels per µm", value: Binding(get: { settings.pxPerUm }, set: { settings.pxPerUm = $0; settings.calibrationSource = "manual"; edited = true }), format: .number)
                                .textFieldStyle(.roundedBorder)
                            Text("px/µm").foregroundStyle(.secondary)
                        }
                        Text("Source: \(settings.calibrationSource)").font(.caption).foregroundStyle(.secondary)
                        if selectedImage != nil, selectedImage?.sourcePxPerUm == nil {
                            Text("No scale metadata in this image. Confirm pixels per µm for calibrated measurements.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        if let scale = selectedImage?.sourcePxPerUm {
                            Button("Use image metadata (\(scale.formatted()) px/µm)") {
                                settings.pxPerUm = scale; settings.calibrationSource = selectedImage?.sourceCalibrationSource ?? "metadata"
                                edited = true
                            }
                        }
                        TextField("Expected diameter (µm; 0 = auto)", value: $settings.expectedDiameterUm, format: .number)
                            .textFieldStyle(.roundedBorder)
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
            Divider()
            HStack {
                Button("Import and inspect") { submit(importOnly: true) }
                Spacer()
                Button("Preview this image") { preview() }
                    .disabled(!modelReady || state.jobScheduler.activeCount > 0 || TrainingService.isTrainingActive)
                Button("Process batch") { submit(importOnly: false) }
                    .buttonStyle(.borderedProminent).disabled(!modelReady)
            }.disabled(busy || settings.validationError != nil)
        }
        .padding(24).frame(width: 850)
        .background(Tokens.bg)
        .focusedSceneValue(\.cellCounterShortcuts, shortcutActions)
        .task(id: sourcePreviewKey) { await loadSourcePreview() }
        .task(id: maskPreviewKey) { await loadPreviewMasks() }
        .onChange(of: job?.settings) { _, new in if let new, !edited { settings = new } }
        .onChange(of: selectedItem?.imageId) { _, _ in
            if settings.calibrationSource == "unconfirmed", let scale = selectedImage?.sourcePxPerUm {
                settings.pxPerUm = scale
                settings.calibrationSource = selectedImage?.sourceCalibrationSource ?? "metadata"
            }
        }
        .onChange(of: settings) { old, new in if old != new { edited = true } }
    }

    private var shortcutActions: ScreenShortcutActions {
        var actions = ScreenShortcutActions()
        actions.isModalContext = true
        actions.cancel = { state.jobScheduler.cancelPreview(); state.analysisSetupJobId = nil }
        if !busy, settings.validationError == nil {
            actions.save = { saveThen { message = "Setup saved." } }
            if modelReady {
                actions.run = { submit(importOnly: false) }
                if state.jobScheduler.activeCount == 0, !TrainingService.isTrainingActive { actions.preview = { preview() } }
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
              detection.runSettings?.hasSameInputs(as: settings) == true else { return }
        let cells = await state.loadCells(for: detection)
        guard !Task.isCancelled else { return }
        previewCells = cells
    }
    private func saveThen(_ action: @escaping @MainActor () -> Void) {
        busy = true
        Task { @MainActor in
            defer { busy = false }
            do { try await state.jobScheduler.updateDraft(jobId, settings: settings, preset: preset); action() }
            catch { message = error.localizedDescription }
        }
    }
    private func preview() {
        guard let item = selectedItem else { return }
        busy = true; message = nil
        Task {
            defer { busy = false }
            do {
                try await state.jobScheduler.updateDraft(jobId, settings: settings, preset: preset)
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
                try await state.jobScheduler.updateDraft(jobId, settings: settings, preset: preset)
                try await state.commitAnalysisSetup(jobId)
                state.jobScheduler.maxParallel = state.maxParallel
                try await state.jobScheduler.enqueue(jobId, importOnly: importOnly)
                UserDefaults.standard.set(preset.resultsWorkspace, forKey: "cc-results-workspace-v1")
                state.analysisSetupJobId = nil
                state.view = importOnly ? .results : .queue
            } catch { message = error.localizedDescription }
        }
    }
}
