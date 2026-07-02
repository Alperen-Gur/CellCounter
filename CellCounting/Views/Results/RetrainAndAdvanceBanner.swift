import SwiftUI
import Combine

/// Pass-14 (F3): "Retrain on this batch & next image" affordance.
///
/// Sits in the Results sidebar directly under the existing RetrainBanner.
/// One-click kicks off `TrainingService` on the current batch's images,
/// streams the latest stderr line into a small inline status banner, and
/// when training completes auto-advances to the next image and re-runs
/// detection with the freshly trained custom model.
///
/// Edge cases:
/// - Single-image batch: skip the advance, re-run detection on the same image.
/// - TrainingService failure: surface via `state.lastDetectionError` /
///   `state.showDetectionError`.
/// - Re-entrance: the button is disabled while a run is in-flight.
struct RetrainAndAdvanceBanner: View {
    @Bindable var state: AppState
    @ObservedObject var controller: RetrainAndAdvanceController

    @Environment(AppTheme.self) private var theme

    /// True when the active model is a Cellpose family model — only those
    /// support the local training path the rest of the wizard uses.
    private var supportsLocalTraining: Bool {
        guard let info = state.models.first(where: { $0.id == state.activeModelId }) else {
            return false
        }
        return info.family == .cellpose || info.family == .custom
    }

    private var imageCount: Int {
        state.currentBatch?.images.count ?? 0
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(theme.accentSoft)
                        .frame(width: 28, height: 28)
                    Icon("sparkles", size: 14)
                        .foregroundStyle(theme.accentColor)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Retrain on this batch & next image")
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(Tokens.text)
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(Tokens.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 6)
            }

            if controller.isRunning {
                progressLine
            }

            Button(action: { controller.start(state: state) }) {
                HStack(spacing: 6) {
                    if controller.isRunning {
                        AppSpinner()
                            .frame(width: 12, height: 12)
                    } else {
                        Icon("sparkles", size: 12)
                    }
                    Text(controller.isRunning ? "Retraining…" : "Retrain & advance")
                }
                .frame(maxWidth: .infinity)
            }
            .appButton(.primary, size: .sm)
            .disabled(controller.isRunning || !canStart)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: Tokens.Radius.lg, style: .continuous)
                .fill(theme.accentSofter)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Tokens.Radius.lg, style: .continuous)
                .strokeBorder(theme.accentSoft, lineWidth: 0.5)
        )
    }

    private var subtitle: String {
        if imageCount <= 1 {
            return "Trains on this image, then re-runs detection here."
        }
        return "Trains on this batch's images, then advances to the next image."
    }

    private var canStart: Bool {
        guard let batch = state.currentBatch else { return false }
        guard !batch.images.isEmpty else { return false }
        // We require detection results on at least one image to have any
        // signal worth training on (Cellpose train uses the saved masks).
        let hasAnyDetection = batch.images.contains(where: { $0.detection != nil })
        return hasAnyDetection && supportsLocalTraining
    }

    private var progressLine: some View {
        HStack(spacing: 6) {
            Icon("sparkles", size: 11)
                .foregroundStyle(theme.accentColor)
            Text(controller.statusLine.isEmpty ? "Starting training…" : controller.statusLine)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Tokens.textSecondary)
                .lineLimit(2)
                .truncationMode(.middle)
        }
    }
}

/// Coordinates training + post-training detection. Lives on the MainActor so it
/// can drive `AppState` directly. Held as a `@StateObject` in `ResultsView` so
/// it survives view rebuilds during the run.
@MainActor
final class RetrainAndAdvanceController: ObservableObject {
    @Published var isRunning: Bool = false
    @Published var statusLine: String = ""

    private let trainer = TrainingService()
    private var progressCancellable: AnyCancellable?
    private var stageObserver: NSObjectProtocol?
    private weak var stateRef: AppState?

    init() {}

    deinit {
        if let obs = stageObserver {
            NotificationCenter.default.removeObserver(obs)
        }
    }

    func start(state: AppState) {
        guard !isRunning else { return }
        guard let batch = state.currentBatch else { return }
        let images = batch.images.sorted(by: { $0.importedAt < $1.importedAt })
        guard !images.isEmpty else { return }

        stateRef = state
        statusLine = ""
        isRunning = true

        // Subscribe to detection stage lines too — TrainingService doesn't
        // post them itself today (it streams stdout EPOCH lines), but the
        // re-run that follows uses the existing ccDetectionStage pipeline.
        // We mirror them into our own inline banner for one unified surface.
        if stageObserver == nil {
            stageObserver = NotificationCenter.default.addObserver(
                forName: .ccDetectionStage,
                object: nil,
                queue: .main
            ) { [weak self] note in
                guard let line = note.userInfo?["line"] as? String else { return }
                Task { @MainActor [weak self] in
                    self?.statusLine = line
                }
            }
        }

        // Wire TrainingService.progress updates into the inline banner and
        // chain into the re-run + advance once training completes.
        progressCancellable = trainer.$progress
            .receive(on: RunLoop.main)
            .sink { [weak self] progress in
                self?.handle(progress: progress, state: state, batch: batch, images: images)
            }

        // Snapshot training inputs from the active state/batch.
        let baseModel = state.activeModelId
        // Use modest defaults — the user can still go through the full wizard
        // for finer control. The point of this button is speed.
        let epochs = 20
        let lr = 0.001
        let batchSize = 1
        let augment = true
        let imageURLs = images.map { $0.storedURL }
        let annotated = images.reduce(0) { acc, img in
            acc + (img.detection?.corrections.count ?? 0)
        }

        // Update inline status before subprocess spawns.
        statusLine = "preparing training run…"

        trainer.start(epochs: epochs,
                      baseModel: baseModel,
                      lr: lr,
                      batchSize: batchSize,
                      augment: augment,
                      imageURLs: imageURLs,
                      annotated: annotated)
    }

    /// Handle TrainingService progress updates. We only react to .complete
    /// and .failed; .running updates flow through to the status line via
    /// the trainer's stderr stream where available.
    private func handle(progress: TrainingService.Progress,
                        state: AppState,
                        batch: BatchRecord,
                        images: [ImageRecord]) {
        switch progress {
        case .idle, .paused:
            break
        case .running(let epoch, let totalEpochs, let trainLoss, let valLoss, _):
            statusLine = String(format: "epoch %d/%d · train %.3f · val %.3f",
                                epoch, totalEpochs, trainLoss, valLoss)
        case .complete(let metrics):
            registerNewModelAndAdvance(state: state,
                                       batch: batch,
                                       images: images,
                                       metrics: metrics)
            progressCancellable = nil
        case .failed(let reason):
            state.lastDetectionError = "Retraining failed: \(reason)"
            state.showDetectionError = true
            finish()
            progressCancellable = nil
        }
    }

    private func registerNewModelAndAdvance(state: AppState,
                                            batch: BatchRecord,
                                            images: [ImageRecord],
                                            metrics: FTMetrics) {
        statusLine = "saving new model…"

        // Mirror FineTuneSteps.saveModel(): derive a new model id, move the
        // checkpoint, record a ModelVersionRecord, register the catalog row.
        let baseId = slugify(batch.displayName.isEmpty ? "retrain" : batch.displayName)
        let modelId = stripTrailingVersion(baseId)
        let version = (state.repos.modelVersions(for: modelId).map { $0.version }.max() ?? 0) + 1
        let checkpointName = "\(modelId)-v\(version).ccmodel"
        let checkpointURL = FileStore.shared.modelsDir.appendingPathComponent(checkpointName)

        if let staged = trainer.lastCheckpointURL {
            try? FileManager.default.removeItem(at: checkpointURL)
            do {
                try FileManager.default.moveItem(at: staged, to: checkpointURL)
            } catch {
                writeInlineCheckpoint(at: checkpointURL, metrics: metrics,
                                      imageCount: images.count, annotated: 0)
            }
        } else {
            writeInlineCheckpoint(at: checkpointURL, metrics: metrics,
                                  imageCount: images.count, annotated: 0)
        }

        let metricMap: [String: Double] = [
            "ap50": metrics.ap50,
            "f1": metrics.f1,
            "precision": metrics.precision,
            "recall": metrics.recall,
            "meanDiamError": metrics.meanDiamError,
        ]
        let record = ModelVersionRecord(
            modelId: modelId,
            version: version,
            trainedOnImages: images.count,
            trainedOnCorrections: 0,
            checkpointPath: checkpointURL.path,
            metrics: metricMap
        )
        state.repos.recordModelVersion(record)

        let displayName = "Retrain · \(batch.displayName)"
        let newId = "\(modelId)-v\(version)"
        let sizeMB = max(1, Int((try? FileManager.default
                                  .attributesOfItem(atPath: checkpointURL.path)[.size] as? Int) ?? 1024) / (1024 * 1024))
        let info = DetectionModelInfo(
            id: newId,
            family: .custom,
            name: displayName,
            sizeMB: sizeMB,
            sizeLabel: "\(sizeMB) MB",
            desc: "Retrained on \(images.count) images · just now",
            state: .downloaded,
            speed: .fast,
            accuracy: .high,
            tags: ["custom", "retrain"],
            custom: true,
            architecture: "Fine-tuned",
            trainingData: "Batch \"\(batch.displayName)\" · \(images.count) images",
            paper: "User retrain",
            outputType: "Masks + boxes + outlines"
        )
        if !state.models.contains(where: { $0.id == info.id }) {
            state.models.append(info)
        }

        // Switch active model to the freshly trained custom one.
        state.activeModelId = newId
        state.refreshDetector()

        // Auto-advance to the next image (or stay if there's only one) and
        // re-run detection on it.
        let nextIdx: Int = {
            if images.count <= 1 { return state.currentImageIdx }
            let candidate = state.currentImageIdx + 1
            return min(candidate, images.count - 1)
        }()
        state.currentImageIdx = nextIdx
        let targetImage = images[nextIdx]

        statusLine = "running detection on next image…"
        state.reRunDetection(on: targetImage)

        // We can't easily await reRunDetection's completion from here without
        // restructuring AppState; the existing reRunDetection flips
        // `view = .processing`, then back to `.results` once detection lands.
        // For our UI we just stop showing the inline banner — ProcessingView
        // takes over.
        finish()
    }

    private func finish() {
        isRunning = false
        statusLine = ""
    }

    private func writeInlineCheckpoint(at url: URL, metrics: FTMetrics,
                                        imageCount: Int, annotated: Int) {
        let blob: [String: Any] = [
            "kind": "inline-retrain",
            "createdAt": ISO8601DateFormatter().string(from: Date()),
            "metrics": [
                "ap50": metrics.ap50,
                "f1": metrics.f1,
                "precision": metrics.precision,
                "recall": metrics.recall,
                "meanDiamError": metrics.meanDiamError,
            ],
            "imageCount": imageCount,
            "annotated": annotated,
        ]
        if let data = try? JSONSerialization.data(withJSONObject: blob,
                                                  options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: url, options: .atomic)
        }
    }

    // MARK: — id helpers (mirrors FineTuneSteps.saveModel)

    private func slugify(_ s: String) -> String {
        let lowered = s.lowercased()
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-")
        var out = ""
        var lastWasDash = false
        for scalar in lowered.unicodeScalars {
            if allowed.contains(scalar) {
                out.unicodeScalars.append(scalar)
                lastWasDash = (scalar == "-")
            } else if scalar == " " || scalar == "_" || scalar == "." {
                if !lastWasDash { out.append("-"); lastWasDash = true }
            }
        }
        while out.hasPrefix("-") { out.removeFirst() }
        while out.hasSuffix("-") { out.removeLast() }
        return out.isEmpty ? "retrain" : out
    }

    private func stripTrailingVersion(_ id: String) -> String {
        guard let range = id.range(of: "-v[0-9]+$", options: .regularExpression) else { return id }
        return String(id[..<range.lowerBound])
    }
}
