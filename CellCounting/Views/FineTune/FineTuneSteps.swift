import SwiftUI
import SwiftData
import Charts
import AppKit

struct TrainingMaskReview: View {
    @Binding var samples: [TrainingSample]
    @Bindable var state: AppState
    @State private var index = 0
    @State private var mode: EditableOverlay.EditorMode = .view
    @State private var preview: NSImage?
    @State private var error: String?
    @State private var saving = false
    @State private var zoom: Double = 1
    @State private var loadedKey = ""

    private var sample: TrainingSample? { samples.indices.contains(index) ? samples[index] : nil }
    private var previewKey: String {
        guard let sample else { return "" }
        return "\(sample.id):\(sample.zProjection):\(sample.segmentChannel ?? -1)"
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            FTSectionTitle(title: "Review every mask", desc: "Trace missing boundaries, remove incorrect masks, and confirm the whole field. These edits are saved to the library. Point markers and boxes without contours must be replaced by traced outlines.")
            if let sample {
                HStack {
                    Button("Previous") { index -= 1 }.disabled(index == 0 || saving)
                    Text("\(index + 1) of \(samples.count) · \(sample.name)").font(.headline)
                    Button("Next") { index += 1 }.disabled(index + 1 >= samples.count || saving)
                    Spacer()
                    if sample.reviewed { Label("Reviewed", systemImage: "checkmark.circle.fill").foregroundStyle(.green) }
                }
                HStack {
                    Picker("Z projection", selection: Binding(get: { samples[index].zProjection }, set: { samples[index].zProjection = $0; samples[index].reviewed = false })) {
                        Text("Maximum").tag("max"); Text("Mean").tag("mean")
                        Text("Sum").tag("sum"); Text("Central plane").tag("none")
                    }.frame(width: 245)
                    Stepper("Source channel: \((sample.segmentChannel ?? 0) + 1)", value: Binding(
                        get: { samples[index].segmentChannel ?? 0 },
                        set: { samples[index].segmentChannel = $0; samples[index].useRGBLuminance = $0 == 0; samples[index].reviewed = false }), in: 0...255).frame(width: 235)
                    Text(sample.sourceSettingsKnown ? "Primary segmentation plane saved with this analysis." : "Legacy result: confirm the source plane matches the masks.").font(.caption).foregroundStyle(.secondary)
                }.disabled(saving || sample.sourceSettingsKnown)
                if sample.useRGBLuminance {
                    Text("Color photographs use RGB luminance. Fluorescence sources use the selected primary channel.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    Picker("Edit", selection: $mode) {
                        Text("Select").tag(EditableOverlay.EditorMode.view)
                        Text("Trace boundary").tag(EditableOverlay.EditorMode.trace)
                        Text("Remove").tag(EditableOverlay.EditorMode.remove)
                    }.pickerStyle(.segmented).frame(width: 390)
                    Spacer()
                    Text("Zoom")
                    Slider(value: $zoom, in: 0.25...4).frame(width: 150)
                }
                GeometryReader { geometry in
                    if let preview, loadedKey == previewKey {
                        let scale = min(geometry.size.width / Double(sample.width), geometry.size.height / Double(sample.height)) * zoom
                        ScrollView([.horizontal, .vertical]) {
                            ZStack(alignment: .topLeading) {
                                Image(nsImage: preview).resizable().interpolation(.high)
                                EditableOverlay(cells: Binding(get: { samples[index].cells }, set: { samples[index].cells = $0; samples[index].reviewed = false }),
                                                pxPerUm: calibration(for: sample.id), thresholds: [20, 30],
                                                overlayMode: .outline, uncertaintyThreshold: 0,
                                                viewScale: scale, editorMode: $mode)
                            }
                            .frame(width: Double(sample.width) * scale, height: Double(sample.height) * scale)
                        }.background(.black)
                    } else if error == nil {
                        ProgressView("Loading source plane…").frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }.frame(height: 440).disabled(saving)
                if let error { Text(error).foregroundStyle(Tokens.warning).textSelection(.enabled) }
                HStack {
                    Text("\(sample.cells.count) masks · \(samples.filter(\.reviewed).count)/\(samples.count) images reviewed")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button(saving ? "Checking masks…" : "Save masks and mark reviewed") { saveReview() }
                        .appButton(.primary, size: .md)
                        .disabled(saving || preview == nil || loadedKey != previewKey)
                }
            }
        }
        .task(id: previewKey) { await loadPreview() }
        .focusedSceneValue(\.cellCounterLocalShortcuts, shortcutActions)
    }
    private var shortcutActions: ScreenShortcutActions {
        var actions = ScreenShortcutActions()
        if !saving {
            if preview != nil && loadedKey == previewKey { actions.save = { saveReview() } }
            if index > 0 { actions.previous = { index -= 1 } }
            if index + 1 < samples.count { actions.next = { index += 1 } }
        }
        actions.zoomIn = { zoom = min(4, zoom + 0.25) }
        actions.zoomOut = { zoom = max(0.25, zoom - 0.25) }
        actions.fit = { zoom = 1 }
        return actions
    }
    private func record(for id: UUID) -> ImageRecord? {
        state.repos.allBatches().lazy.flatMap(\.images).first { $0.id == id }
    }
    private func calibration(for id: UUID) -> Double { max(0.0001, record(for: id)?.batch?.pxPerUm ?? 1) }
    private func loadPreview() async {
        guard let sample else { return }
        let key = previewKey
        preview = nil; loadedKey = ""; error = nil
        do {
            let data = try await TrainingDatasetService.preview(for: sample)
            guard !Task.isCancelled, key == previewKey else { return }
            guard let image = NSImage(data: data),
                  let bitmap = NSBitmapImageRep(data: data),
                  bitmap.pixelsWide == sample.width, bitmap.pixelsHigh == sample.height else {
                throw TrainingDatasetError.invalid("The source plane size differs from the masks. Reimport and segment this image.")
            }
            preview = image; loadedKey = key
        } catch { if !Task.isCancelled, key == previewKey { self.error = error.localizedDescription } }
    }
    private func saveReview() {
        guard let sample, let image = record(for: sample.id), let detection = image.detection else { return }
        let target = index
        saving = true; error = nil
        Task {
            do {
                _ = try await Task.detached(priority: .userInitiated) {
                    try TrainingLabelRasterizer.labels(width: sample.width, height: sample.height, cells: sample.cells)
                }.value
                guard samples.indices.contains(target), samples[target].id == sample.id else { saving = false; return }
                guard image.detection?.id == sample.detectionID,
                      detection.cellsRevision == sample.detectionRevision else {
                    throw TrainingDatasetError.invalid("This image's masks changed in the library. Reselect it in Dataset before saving your review.")
                }
                let old = detection.cells
                let oldByID = Dictionary(uniqueKeysWithValues: old.map { ($0.id, $0) })
                let newByID = Dictionary(uniqueKeysWithValues: sample.cells.map { ($0.id, $0) })
                var corrections = old.filter { newByID[$0.id] == nil }.map { CorrectionSpec(kind: "remove", cell: $0) }
                corrections += sample.cells.compactMap { cell in
                    guard oldByID[cell.id] != cell else { return nil }
                    return CorrectionSpec(kind: oldByID[cell.id] == nil ? "add" : "resize", cell: cell)
                }
                if !corrections.isEmpty {
                    _ = state.repos.commitCellEdit(cells: sample.cells, corrections: corrections, detection: detection, image: image)
                }
                try state.repos.context.save()
                samples[target].detectionRevision = detection.cellsRevision
                samples[target].reviewed = true
            } catch { self.error = error.localizedDescription }
            saving = false
        }
    }
}

struct TrainingLossPoint: Identifiable {
    var id: Int { epoch }
    var epoch: Int
    var train: Double
    var validation: Double
}
struct TrainingRunView: View {
    @ObservedObject var trainer: TrainingService
    @State private var history: [TrainingLossPoint] = []
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            FTSectionTitle(title: "Training on reviewed masks", desc: "Losses are shown only when Cellpose measures them. Validation checks select the saved checkpoint; test images remain held out.")
            Text(trainer.status).font(.headline)
            if let device = trainer.device { Text("Device: \(device.uppercased())").foregroundStyle(.secondary) }
            switch trainer.progress {
            case .running(let epoch, let total, _, _, let eta):
                ProgressView(value: Double(epoch), total: Double(max(1, total)))
                Text(epoch == 0 ? "Preparing data and model…" : "Last measured epoch \(epoch)/\(total)" + (eta > 0 ? " · about \(max(1, eta / 60)) minutes remaining" : ""))
                Button("Pause") { trainer.pause() }
            case .paused: Button("Resume") { trainer.resume() }
            case .failed(let message): Text(message).foregroundStyle(Tokens.warning).textSelection(.enabled)
            default: EmptyView()
            }
            if !history.isEmpty {
                Chart(history) { point in
                    LineMark(x: .value("Epoch", point.epoch), y: .value("Loss", point.train))
                        .foregroundStyle(by: .value("Series", "Training"))
                    LineMark(x: .value("Epoch", point.epoch), y: .value("Loss", point.validation))
                        .foregroundStyle(by: .value("Series", "Validation"))
                }.frame(height: 230)
            }
        }
        .onReceive(trainer.$progress) { progress in
            guard case .running(let epoch, _, let train, let val, _) = progress,
                  epoch > 0, train.isFinite, val.isFinite else { return }
            history.removeAll { $0.epoch == epoch }
            history.append(.init(epoch: epoch, train: train, validation: val))
        }
    }
}

struct TrainingEvaluationView: View {
    @Bindable var state: AppState
    @ObservedObject var trainer: TrainingService
    @State private var modelName = "My fine-tuned model"
    @State private var savedID: String?
    @State private var error: String?
    private var metrics: FTMetrics? { if case .complete(let metrics) = trainer.progress { return metrics }; return nil }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            FTSectionTitle(title: "Held-out test results", desc: "These measurements come from the saved checkpoint on specimens excluded from training and checkpoint selection.")
            if let metrics {
                Text("\(metrics.testImages) held-out images").font(.headline)
                HStack(spacing: 25) {
                    metric("AP at IoU 0.5", metrics.ap50)
                    metric("F1", metrics.f1)
                    metric("Precision", metrics.precision)
                    metric("Recall", metrics.recall)
                }
                Text("Mean diameter error: \(metrics.meanDiamError, specifier: "%.2f") px")
                Text("AP is the mean per-image TP/(TP+FP+FN) at IoU ≥ 0.5. Precision, recall and F1 pool object matches across test images. Diameter error compares image mean equivalent-area diameters in source pixels.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let manifest = trainer.lastManifest {
                DisclosureGroup("Dataset and split") {
                    ForEach(manifest.samples, id: \.id) { entry in
                        HStack { Text(entry.name); Spacer(); Text(entry.partition.capitalized).foregroundStyle(.secondary) }
                    }
                    Text("Split seed: \(manifest.split.seed)")
                }
            }
            HStack {
                TextField("Model name", text: $modelName).textFieldStyle(.roundedBorder)
                Button(savedID == nil ? "Save to Models" : "Saved") { saveModel() }
                    .appButton(.primary, size: .md)
                    .disabled(savedID != nil || !trainer.canActivateCheckpoint || modelName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if let savedID {
                    Button("Use this model") {
                        state.activeModelId = savedID; state.refreshDetector(); state.view = .home
                    }.appButton(.standard, size: .md)
                }
            }
            if let error { Text(error).foregroundStyle(Tokens.warning) }
            Text("The model and its dataset hashes, split assignments and measured evaluation are saved together.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .focusedSceneValue(\.cellCounterLocalShortcuts, shortcutActions)
    }
    private var shortcutActions: ScreenShortcutActions {
        var actions = ScreenShortcutActions()
        if savedID == nil && trainer.canActivateCheckpoint && !modelName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            actions.save = { saveModel() }
        }
        return actions
    }
    private func metric(_ label: String, _ value: Double) -> some View {
        VStack(alignment: .leading) { Text(label).font(.caption); Text(value, format: .number.precision(.fractionLength(3))).font(.title2.monospacedDigit()) }
    }
    private func saveModel() {
        guard let metrics, savedID == nil else { return }
        let name = modelName.trimmingCharacters(in: .whitespacesAndNewlines)
        let entry = CustomModelEntry(name: name,
                                     path: FileStore.shared.modelsDir.appendingPathComponent("finetune-\(UUID()).ccmodel").path,
                                     kind: .cellpose, runtime: .base)
        do {
            try trainer.copyValidatedCheckpoint(to: entry.url)
            guard CustomModelStore.add(entry) else { throw TrainingDatasetError.invalid("Could not register the saved model.") }
            let trainingCount = trainer.lastManifest?.samples.filter { $0.partition == "train" }.count ?? 0
            let record = ModelVersionRecord(modelId: entry.id, version: 1, trainedOnImages: trainingCount,
                                            trainedOnCorrections: trainingCount, checkpointPath: entry.path,
                                            metrics: ["ap50": metrics.ap50, "f1": metrics.f1,
                                                      "precision": metrics.precision, "recall": metrics.recall,
                                                      "meanDiamErrorPx": metrics.meanDiamError,
                                                      "testImages": Double(metrics.testImages)])
            state.repos.recordModelVersion(record)
            savedID = entry.id
        } catch { self.error = error.localizedDescription }
    }
}
