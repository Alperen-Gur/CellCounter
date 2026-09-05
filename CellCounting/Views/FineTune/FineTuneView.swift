import SwiftUI

nonisolated struct FTMetrics: Codable, Equatable, Sendable {
    var ap50: Double
    var f1: Double
    var precision: Double
    var recall: Double
    /// Difference in mean equivalent-area diameter, in source pixels.
    var meanDiamError: Double
    var testImages: Int = 0

    var isValid: Bool {
        [ap50, f1, precision, recall].allSatisfy { $0.isFinite && (0...1).contains($0) }
            && meanDiamError.isFinite && meanDiamError >= 0 && testImages > 0
    }
}

struct FineTuneView: View {
    @Bindable var state: AppState
    @State private var step = 0
    @State private var records: [ImageRecord] = []
    @State private var samples: [TrainingSample] = []
    @State private var split = TrainingSplit()
    @State private var baseModel = "cp-cyto3"
    @State private var epochs = 40
    @State private var learningRate = 0.0002
    @State private var batchSize = 4
    @State private var augment = true
    @State private var earlyStop = true
    @StateObject private var trainer = TrainingService()
    private let steps = ["Dataset", "Review masks", "Split", "Configure", "Train", "Evaluate"]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Fine-tune a model").font(.title.bold())
                Text("Train locally from reviewed library masks. Keep independent specimens in separate training, validation and test groups.")
                    .foregroundStyle(.secondary)
                HStack(spacing: 12) {
                    ForEach(steps.indices, id: \.self) { index in
                        Text("\(index + 1) · \(steps[index])")
                            .font(.caption.weight(index == step ? .bold : .regular))
                            .foregroundStyle(index == step ? Tokens.text : Tokens.textTertiary)
                    }
                }
                FTCard {
                    switch step {
                    case 0: dataset
                    case 1:
                        TrainingMaskReview(samples: $samples, state: state)
                        FTFooterBar(onBack: { step = 0 }, onNext: { step = 2 },
                                    nextDisabled: samples.isEmpty || !samples.allSatisfy(\.reviewed))
                    case 2: splitConfiguration
                    case 3: configuration
                    case 4:
                        TrainingRunView(trainer: trainer)
                        if case .failed = trainer.progress {
                            FTFooterBar(onBack: { step = 3 }, onNext: startTraining, nextLabel: "Retry")
                        } else {
                            Button("Cancel training") { trainer.cancel(); step = 3 }
                        }
                    default:
                        TrainingEvaluationView(state: state, trainer: trainer)
                        FTFooterBar(onBack: { trainer.cancel(); samples = []; step = 0 },
                                    backLabel: "Train another", onNext: { state.view = .home }, nextLabel: "Done")
                    }
                }
            }
            .frame(maxWidth: 1100, alignment: .leading)
            .padding(28).frame(maxWidth: .infinity, alignment: .top)
        }
        .background(Tokens.bg)
        .focusedSceneValue(\.cellCounterShortcuts, shortcuts)
        .task { records = state.repos.allBatches().flatMap(\.images).filter { $0.detection != nil }.sorted { $0.importedAt > $1.importedAt } }
        .onReceive(trainer.$progress) { progress in if case .complete = progress { step = 5 } }
        .onDisappear { trainer.cancel() }
    }

    private var shortcuts: ScreenShortcutActions {
        var actions = ScreenShortcutActions()
        if step == 0, !records.isEmpty {
            actions.selectAll = { samples = TrainingDatasetService.samples(from: records) }
        }
        if (1...3).contains(step) { actions.previous = { step -= 1 } }
        if step == 0 && !samples.isEmpty { actions.next = { step = 1 } }
        if step == 1 && !samples.isEmpty && samples.allSatisfy(\.reviewed) { actions.next = { step = 2 } }
        if step == 2 && assignments != nil { actions.next = { step = 3 } }
        if step == 3 && learningRate.isFinite && learningRate > 0 && !processingIsActive {
            actions.run = startTraining
        }
        if step == 4 {
            actions.cancel = { trainer.cancel(); step = 3 }
            switch trainer.progress {
            case .running: actions.pauseResume = { trainer.pause() }
            case .paused: actions.pauseResume = { trainer.resume() }
            case .failed: actions.previous = { step = 3 }; if !processingIsActive { actions.run = startTraining }
            default: break
            }
        }
        if step == 5 { actions.next = { state.view = .home } }
        return actions
    }

    private var dataset: some View {
        VStack(alignment: .leading, spacing: 14) {
            FTSectionTitle(title: "Choose library images", desc: "Import and segment images first. Select images with complete masks, then review every boundary. Counts and point annotations alone cannot train a segmentation model.")
            if records.isEmpty {
                ContentUnavailableView("No segmented images", systemImage: "photo.on.rectangle", description: Text("Import images and create a segmentation, then return here."))
            } else {
                Text("\(samples.count) selected").font(.headline)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(records, id: \.id) { record in
                            Toggle(isOn: Binding(get: { samples.contains { $0.id == record.id } }, set: { selected in
                                if selected {
                                    samples += TrainingDatasetService.samples(from: [record])
                                } else { samples.removeAll { $0.id == record.id } }
                            })) {
                                HStack {
                                    Text(record.fileName)
                                    Spacer()
                                    Text(record.batch?.displayName ?? "Ungrouped").foregroundStyle(.secondary)
                                    Text("\(record.detection?.summaryCellCount ?? 0) masks").foregroundStyle(.secondary)
                                }
                            }.toggleStyle(.checkbox)
                        }
                    }
                }.frame(maxHeight: 330)
            }
            FTFooterBar(onNext: { step = 1 }, nextDisabled: samples.isEmpty)
        }
    }

    private var assignments: [UUID: String]? { try? split.assignments(for: samples) }
    private var splitError: String? {
        do { _ = try split.assignments(for: samples); return nil }
        catch { return error.localizedDescription }
    }
    private var splitConfiguration: some View {
        VStack(alignment: .leading, spacing: 16) {
            FTSectionTitle(title: "Keep related images together", desc: "Enter the same specimen or biological replicate name for all related fields. Batches are grouped together initially. Crops and repeated fields from one specimen must share a group. Percentages allocate whole groups, so image counts may differ from the requested ratio.")
            HStack {
                Stepper("Train: \(split.trainPercent)%", value: $split.trainPercent, in: 10...80, step: 5)
                Stepper("Validation: \(split.validationPercent)%", value: $split.validationPercent, in: 5...45, step: 5)
                Text("Test: \(100 - split.trainPercent - split.validationPercent)%")
                TextField("Split seed", value: $split.seed, format: .number).frame(width: 90).textFieldStyle(.roundedBorder)
            }
            ScrollView {
                VStack(spacing: 8) {
                    ForEach($samples) { $sample in
                        HStack {
                            Text(sample.name).frame(maxWidth: .infinity, alignment: .leading)
                            TextField("Specimen group", text: $sample.group).textFieldStyle(.roundedBorder)
                                .frame(width: 270).accessibilityLabel("Specimen group for \(sample.name)")
                            Text(assignments?[sample.id]?.capitalized ?? "—").frame(width: 85, alignment: .leading)
                        }
                    }
                }
            }.frame(maxHeight: 350)
            if let assignments {
                Text(["train", "validation", "test"].map { key in
                    "\(assignments.values.filter { $0 == key }.count) \(key) images"
                }.joined(separator: " · ")).font(.headline)
            }
            if let splitError { Text(splitError).foregroundStyle(Tokens.warning) }
            Text("Duplicate source files are rejected. Test images never select a checkpoint or tune training; they are used once for the final report.")
                .font(.callout).foregroundStyle(.secondary)
            FTFooterBar(onBack: { step = 1 }, onNext: { step = 3 }, nextDisabled: assignments == nil)
        }
    }
    private var processingIsActive: Bool {
        state.jobScheduler.activeCount > 0 || state.jobScheduler.activeJobId != nil || state.jobScheduler.previewItemId != nil
    }
    private var configuration: some View {
        VStack(alignment: .leading, spacing: 18) {
            FTSectionTitle(title: "Training settings", desc: "Uses the installed Cellpose 3.x environment and full-precision training. Install the selected base model in Models before starting.")
            Picker("Base model", selection: $baseModel) {
                Text("Cellpose cyto3").tag("cp-cyto3")
                Text("Cellpose nuclei").tag("cp-nuclei")
                ForEach(CustomModelStore.all().filter { $0.kind == .cellpose && $0.runtime == .base }) { model in
                    Text(model.name).tag(model.id)
                }
            }.frame(maxWidth: 450)
            Stepper("Epochs: \(epochs)", value: $epochs, in: 6...2000)
            HStack {
                Text("Learning rate")
                TextField("Learning rate", value: $learningRate, format: .number.precision(.fractionLength(1...6)))
                    .textFieldStyle(.roundedBorder).frame(width: 160)
            }
            Stepper("Images per training batch: \(batchSize)", value: $batchSize, in: 1...32)
            Toggle("Additional scale augmentation", isOn: $augment)
            Text("Cellpose's built-in flips and rotations remain enabled. This option also randomizes image scale.")
                .font(.caption).foregroundStyle(.secondary)
            Toggle("Stop after five validation checks without improvement", isOn: $earlyStop)
            Text("The checkpoint with the lowest measured validation loss is evaluated on the held-out test images. GPU is used when available.")
                .foregroundStyle(.secondary)
            if processingIsActive {
                Text("Pause image processing and finish any preview before training. The model device is shared with Processing.")
                    .foregroundStyle(Tokens.warning)
                Button("Open Processing") { state.view = .queue }
            }
            FTFooterBar(onBack: { step = 2 }, onNext: startTraining, nextLabel: "Start training",
                        nextDisabled: !learningRate.isFinite || learningRate <= 0 || processingIsActive)
        }
    }
    private func startTraining() {
        guard !processingIsActive else { step = 3; return }
        step = 4
        trainer.start(epochs: epochs, baseModel: baseModel, lr: learningRate,
                      batchSize: batchSize, augment: augment,
                      imageURLs: samples.map(\.sourceURL), annotated: samples.count,
                      earlyStop: earlyStop, samples: samples, split: split)
    }
}

struct FTCard<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 16) { content }
            .padding(24).frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: Tokens.Radius.lg).fill(Tokens.bgElevated))
            .overlay(RoundedRectangle(cornerRadius: Tokens.Radius.lg).strokeBorder(Tokens.border, lineWidth: 0.5))
    }
}
struct FTSectionTitle: View {
    let title: String
    let desc: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            if let desc { Text(desc).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
        }
    }
}
struct FTFooterBar: View {
    var onBack: (() -> Void)? = nil
    var backLabel = "Back"
    var onNext: (() -> Void)? = nil
    var nextLabel = "Continue"
    var nextDisabled = false
    var body: some View {
        HStack {
            if let onBack { Button(backLabel, action: onBack).appButton(.standard, size: .md) }
            Spacer()
            if let onNext { Button(nextLabel, action: onNext).appButton(.primary, size: .md).disabled(nextDisabled) }
        }.padding(.top, 12)
    }
}
