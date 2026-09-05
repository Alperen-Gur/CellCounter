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
    @State private var previewLoadId = UUID()
    @State private var sourcePreviewTask: Task<Void, Never>?
    private var job: AnalysisJob? { state.jobScheduler.job(jobId) }
    private var selectedItem: AnalysisJobItem? { job?.items.first { $0.id == selectedItemId } ?? job?.items.first }
    private var selectedImage: ImageRecord? { selectedItem?.imageId.flatMap { state.repos.image(id: $0) } }
    private var modelReady: Bool { state.detectorRegistry.isInstalled(settings.modelId, models: state.models) }

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
                    Picker("Representative image", selection: $selectedItemId) {
                        ForEach(job?.items ?? []) { item in Text(item.fileName).tag(Optional(item.id)) }
                    }
                    .onChange(of: selectedItemId) { _, _ in loadSample() }
                    GeometryReader { geometry in
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
                        .frame(width: geometry.size.width, height: geometry.size.height)
                    }.frame(minWidth: 380, minHeight: 310)
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
        .onDisappear { sourcePreviewTask?.cancel() }
        .task {
            if let job { settings = job.settings; preset = job.taskPreset; selectedItemId = job.items.first?.id }
            refreshPreview()
        }
        .onChange(of: job?.settings) { _, new in if let new, !edited { settings = new } }
        .onChange(of: selectedItem?.imageId) { _, _ in
            if settings.calibrationSource == "unconfirmed", let scale = selectedImage?.sourcePxPerUm {
                settings.pxPerUm = scale
                settings.calibrationSource = selectedImage?.sourceCalibrationSource ?? "metadata"
            }
            refreshPreview()
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

    private func refreshPreview() {
        guard let record = selectedImage else { return }
        let loadId = UUID(); previewLoadId = loadId
        let snapshot = settings
        let useSource = snapshot.supportsSourceChannels && modelReady
        previewImage = nil; previewCells = []
        sourcePreviewTask?.cancel()
        sourcePreviewTask = Task {
            do {
                let image: NSImage?
                if useSource {
                    let data = try await TrainingDatasetService.preview(image: record, settings: snapshot)
                    image = NSImage(data: data)
                } else {
                    let url = record.displayURL
                    image = await Task.detached(priority: .userInitiated) { ImageLoader.cachedDisplayImage(at: url) }.value
                }
                guard !Task.isCancelled, selectedImage?.id == record.id, previewLoadId == loadId else { return }
                previewImage = image
                if let detection = record.detection,
                   detection.runSettings?.hasSameInputs(as: snapshot) != false {
                    let cells = await state.loadCells(for: detection)
                    guard !Task.isCancelled, selectedImage?.id == record.id, previewLoadId == loadId else { return }
                    previewCells = cells
                }
            } catch {
                guard !Task.isCancelled, previewLoadId == loadId else { return }
                message = "Source preview could not be loaded: " + error.localizedDescription
            }
        }
    }
    private func loadSample() {
        guard let item = selectedItem, !busy else { return }
        if item.imageId != nil { refreshPreview(); return }
        busy = true
        Task {
            defer { busy = false }
            do {
                _ = try await state.jobScheduler.prepareSample(jobId, itemId: item.id)
                refreshPreview()
            } catch { message = error.localizedDescription }
        }
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
                refreshPreview()
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
