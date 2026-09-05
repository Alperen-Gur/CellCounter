import Foundation
import Combine

/// Runs only real training. Missing labels, failed inference or invalid weights
/// are failures; completion requires successful held-out evaluation and reload.
@MainActor
final class TrainingService: ObservableObject {
    /// Shared with the background scheduler. The permit stays held until a
    /// cancelled subprocess has actually exited, including a suspended process.
    static let activityChangedNotification = Notification.Name("ccTrainingActivityChanged")
    private static var activeOwner: UUID?
    static var isTrainingActive: Bool { activeOwner != nil }
    private static func acquirePermit(_ owner: UUID) -> Bool {
        guard activeOwner == nil else { return false }
        activeOwner = owner
        NotificationCenter.default.post(name: activityChangedNotification, object: nil)
        return true
    }
    private static func releasePermit(_ owner: UUID) {
        guard activeOwner == owner else { return }
        activeOwner = nil
        NotificationCenter.default.post(name: activityChangedNotification, object: nil)
    }
    enum Progress {
        case idle
        case running(epoch: Int, totalEpochs: Int, trainLoss: Double, valLoss: Double, eta: Int)
        case paused
        case complete(FTMetrics)
        case failed(String)
    }
    @Published var progress: Progress = .idle
    @Published var device: String?
    @Published var earlyStopped: Int?
    @Published var currentLR: Double?
    @Published var status = ""
    @Published private(set) var canActivateCheckpoint = false
    private(set) var lastCheckpointURL: URL?
    private(set) var lastConfig: TrainingConfig?
    private(set) var lastManifest: TrainingManifest?
    private var process: Process?
    private var prepareTask: Task<Void, Never>?
    private var stagingTask: Task<URL, Error>?
    private var runID = UUID()
    private var cachedSamples: [TrainingSample] = []
    private var cachedSplit = TrainingSplit()
    private var cachedEarlyStop = true
    private var pendingMetrics: FTMetrics?
    private var diagnostic = ""
    private var lastRunning: Progress?

    /// `imageURLs` is kept for existing callers, but URLs alone never constitute
    /// a labeled dataset. Callers must provide reviewed corrected mask snapshots.
    func start(epochs: Int, baseModel: String, lr: Double, batchSize: Int,
               augment: Bool, imageURLs: [URL], annotated: Int,
               earlyStop: Bool = true, mixedPrecision: Bool = false,
               resumeFrom: URL? = nil, samples: [TrainingSample]? = nil,
               split: TrainingSplit = TrainingSplit()) {
        cancel()
        let token = runID
        lastCheckpointURL = nil; lastManifest = nil; pendingMetrics = nil
        canActivateCheckpoint = false; diagnostic = ""; device = nil
        earlyStopped = nil; currentLR = nil
        guard let samples, !samples.isEmpty else {
            progress = .failed("Select and review corrected cell masks in Fine-tune before training. Image files alone do not contain labels.")
            return
        }
        guard epochs >= 6, batchSize > 0, lr.isFinite, lr > 0 else {
            progress = .failed("Use at least six epochs, a positive learning rate and batch size."); return
        }
        guard !mixedPrecision else {
            progress = .failed("This Cellpose 3.x training workflow uses full precision. Turn off mixed precision."); return
        }
        let resumeURL: URL?
        if let resumeFrom { resumeURL = resumeFrom }
        else if let custom = CustomModelStore.entry(for: baseModel), custom.kind == .cellpose, custom.runtime == .base {
            resumeURL = custom.url
        } else { resumeURL = nil }
        guard ["cp-cyto3", "cp-nuclei"].contains(baseModel) || resumeURL != nil else {
            progress = .failed("Select Cellpose cyto3, nuclei, or a Cellpose 3.x custom checkpoint."); return
        }
        guard case .available(let python, _) = CellposeAvailability.detect() else {
            progress = .failed("Install a Cellpose 3.x model in Models before training."); return
        }
        guard let script = PythonRuntime.stagedScriptURL(named: "cellpose_train.py")
                ?? PythonRuntime.bundledPythonURL(named: "cellpose_train.py") else {
            progress = .failed("The training helper is missing. Reinstall the app."); return
        }
        guard Self.acquirePermit(token) else {
            progress = .failed("Another training run is still active or stopping. Wait for it to finish before starting again.")
            return
        }
        cachedSamples = samples; cachedSplit = split; cachedEarlyStop = earlyStop
        lastConfig = TrainingConfig(epochs: epochs, lr: lr, batchSize: batchSize,
                                    augment: augment, baseModel: baseModel,
                                    imageCount: samples.count, annotated: samples.filter(\.reviewed).count,
                                    imageURLs: samples.map(\.sourceURL))
        status = "Preparing reviewed masks…"
        progress = .running(epoch: 0, totalEpochs: epochs, trainLoss: .nan, valLoss: .nan, eta: 0)
        let stage = FileManager.default.temporaryDirectory.appendingPathComponent("cellcounter-training-\(token)", isDirectory: true)
        let staging = Task.detached(priority: .userInitiated) {
            try TrainingDatasetService.stage(samples: samples, split: split, in: stage)
        }
        stagingTask = staging
        prepareTask = Task { [weak self] in
            do {
                let manifest = try await staging.value
                guard let self, self.runID == token, !Task.isCancelled else {
                    try? FileManager.default.removeItem(at: stage)
                    Self.releasePermit(token)
                    return
                }
                self.lastManifest = try JSONDecoder().decode(TrainingManifest.self, from: Data(contentsOf: manifest))
                self.launch(python: python, script: script, manifest: manifest, stage: stage,
                            token: token, epochs: epochs, baseModel: baseModel, lr: lr,
                            batchSize: batchSize, augment: augment, earlyStop: earlyStop,
                            resumeFrom: resumeURL)
            } catch {
                try? FileManager.default.removeItem(at: stage)
                Self.releasePermit(token)
                guard let self, self.runID == token, !Task.isCancelled else { return }
                self.progress = .failed(error.localizedDescription)
            }
        }
    }

    func resume(from checkpoint: URL) {
        guard let config = lastConfig else { return }
        start(epochs: config.epochs, baseModel: config.baseModel, lr: config.lr,
              batchSize: config.batchSize, augment: config.augment,
              imageURLs: config.imageURLs, annotated: config.annotated,
              earlyStop: cachedEarlyStop, resumeFrom: checkpoint, samples: cachedSamples, split: cachedSplit)
    }
    func pause() {
        guard let process, process.isRunning, process.suspend() else { return }
        lastRunning = progress; progress = .paused; status = "Paused"
    }
    func resume() {
        guard let process, process.isRunning, process.resume() else { return }
        progress = lastRunning ?? .idle; status = "Resuming…"
    }
    func cancel() {
        let previousID = runID
        runID = UUID()
        prepareTask?.cancel(); prepareTask = nil
        stagingTask?.cancel(); stagingTask = nil
        if let process, process.isRunning { process.resume(); process.terminate() }
        else { Self.releasePermit(previousID) }
        process = nil
        if case .complete = progress {} else { progress = .idle }
    }

    private func launch(python: URL, script: URL, manifest: URL, stage: URL,
                        token: UUID, epochs: Int, baseModel: String, lr: Double,
                        batchSize: Int, augment: Bool, earlyStop: Bool, resumeFrom: URL?) {
        let output = FileStore.shared.modelsDir.appendingPathComponent("training-\(token).ccmodel")
        let proc = Process(); proc.executableURL = python
        proc.arguments = [script.path, "--manifest", manifest.path, "--epochs", String(epochs),
                          "--lr", String(lr), "--batch-size", String(batchSize),
                          "--augment", augment ? "1" : "0", "--base-model", baseModel,
                          "--output", output.path, "--early-stop", earlyStop ? "1" : "0"]
        if let resumeFrom { proc.arguments! += ["--resume", resumeFrom.path] }
        var environment = ProcessInfo.processInfo.environment
        environment["PYTHONUNBUFFERED"] = "1"; proc.environment = environment
        let out = Pipe(), err = Pipe(); proc.standardOutput = out; proc.standardError = err
        let stdoutTask = Task { [weak self] in
            do {
                for try await line in out.fileHandleForReading.bytes.lines {
                    guard let self, self.runID == token else { continue }
                    self.consume(line, epochs: epochs)
                }
            } catch {}
        }
        let stderrTask = Task { [weak self] in
            do {
                for try await line in err.fileHandleForReading.bytes.lines {
                    guard let self, self.runID == token else { continue }
                    if line.hasPrefix("DEVICE ") { self.device = String(line.dropFirst(7)) }
                    self.diagnostic = String((self.diagnostic + "\n" + line).suffix(4000))
                }
            } catch {}
        }
        // Install before launch so even immediate failures are observed.
        // Await both pipes before inspecting DONE or report files.
        proc.terminationHandler = { [weak self] terminated in
            Task { @MainActor in
                await stdoutTask.value; await stderrTask.value
                defer {
                    try? FileManager.default.removeItem(at: stage)
                    Self.releasePermit(token)
                }
                guard let self, self.runID == token else {
                    Self.removeIncompleteCheckpoint(output)
                    return
                }
                self.process = nil
                guard terminated.terminationStatus == 0, let expected = self.pendingMetrics else {
                    self.canActivateCheckpoint = false
                    Self.removeIncompleteCheckpoint(output)
                    self.progress = .failed(self.status.hasPrefix("Error: ") ? String(self.status.dropFirst(7)) : "Training failed. \(self.diagnostic)")
                    return
                }
                do {
                    let metrics = try Self.validateResult(checkpoint: output)
                    guard metrics == expected else { throw TrainingDatasetError.invalid("Training report and completion metrics do not match.") }
                    self.lastCheckpointURL = output; self.canActivateCheckpoint = true
                    self.status = "Training and held-out evaluation complete"
                    self.progress = .complete(metrics)
                } catch {
                    Self.removeIncompleteCheckpoint(output)
                    self.progress = .failed(error.localizedDescription)
                }
            }
        }
        do {
            try proc.run()
            ChildProcessTracker.shared.register(proc, kind: .other)
            process = proc
        } catch {
            proc.terminationHandler = nil
            stdoutTask.cancel(); stderrTask.cancel()
            try? out.fileHandleForReading.close(); try? err.fileHandleForReading.close()
            try? FileManager.default.removeItem(at: stage)
            Self.releasePermit(token)
            progress = .failed("Could not start training: \(error.localizedDescription)")
        }
    }

    private func consume(_ line: String, epochs: Int) {
        if line.hasPrefix("STATUS ") {
            if case .paused = progress {} else { status = String(line.dropFirst(7)) }
            return
        }
        if line.hasPrefix("EPOCH ") {
            let parts = line.split(separator: " ")
            let fields = Dictionary(parts.dropFirst(2).compactMap { part -> (String, String)? in
                let pair = part.split(separator: "=", maxSplits: 1)
                return pair.count == 2 ? (String(pair[0]), String(pair[1])) : nil
            }, uniquingKeysWith: { _, new in new })
            guard parts.count > 1, let epoch = Int(parts[1]),
                  let train = fields["train"].flatMap(Double.init), train.isFinite,
                  let val = fields["val"].flatMap(Double.init), val.isFinite else { return }
            currentLR = fields["lr"].flatMap(Double.init)
            let measurement = Progress.running(epoch: epoch, totalEpochs: epochs, trainLoss: train,
                                               valLoss: val, eta: fields["eta"].flatMap(Int.init) ?? 0)
            if case .paused = progress { lastRunning = measurement }
            else {
                status = "Training epoch \(epoch) of \(epochs)"
                progress = measurement
            }
        } else if line.hasPrefix("EARLY_STOPPED epoch=") {
            earlyStopped = Int(line.dropFirst("EARLY_STOPPED epoch=".count))
        } else if line.hasPrefix("DONE "), let data = String(line.dropFirst(5)).data(using: .utf8) {
            pendingMetrics = try? JSONDecoder().decode(FTMetrics.self, from: data)
        } else if let data = line.data(using: .utf8),
                  let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let error = payload["error"] as? String { status = "Error: \(error)" }
    }

    private static func removeIncompleteCheckpoint(_ output: URL) {
        let files = [output, output.deletingPathExtension().appendingPathExtension("json"),
                     output.deletingPathExtension().appendingPathExtension("best"),
                     output.deletingLastPathComponent().appendingPathComponent("models")
                        .appendingPathComponent(output.deletingPathExtension().lastPathComponent + "-last")]
        for file in files { try? FileManager.default.removeItem(at: file) }
    }

    nonisolated static func validateResult(checkpoint: URL) throws -> FTMetrics {
        let attributes = try FileManager.default.attributesOfItem(atPath: checkpoint.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              (attributes[.size] as? NSNumber)?.intValue ?? 0 >= 1024 else {
            throw TrainingDatasetError.invalid("Training did not produce a usable checkpoint file.")
        }
        let reportURL = checkpoint.deletingPathExtension().appendingPathExtension("json")
        let report = try JSONDecoder().decode(TrainingResultReport.self, from: Data(contentsOf: reportURL))
        let m = report.metrics
        guard report.kind == "cellpose", report.checkpointValidated,
              report.checkpointHash == (try TrainingDatasetService.fileHash(checkpoint)),
              m.isValid, report.dataset.samples.filter({ $0.partition == "test" }).count == m.testImages,
              report.dataset.samples.contains(where: { $0.partition == "train" }),
              report.dataset.samples.contains(where: { $0.partition == "validation" }) else {
            throw TrainingDatasetError.invalid("The checkpoint has no verified held-out evaluation, or its contents changed.")
        }
        var partitions: [String: String] = [:]
        var hashes = Set<String>()
        for entry in report.dataset.samples {
            guard ["train", "validation", "test"].contains(entry.partition), !entry.group.isEmpty,
                  entry.sourceHash.count == 64, entry.labelsHash.count == 64,
                  hashes.insert(entry.sourceHash).inserted,
                  partitions[entry.group] == nil || partitions[entry.group] == entry.partition else {
                throw TrainingDatasetError.invalid("The training report contains duplicate images or specimen leakage.")
            }
            partitions[entry.group] = entry.partition
        }
        return m
    }

    func copyValidatedCheckpoint(to destination: URL) throws {
        guard canActivateCheckpoint, let source = lastCheckpointURL else {
            throw TrainingDatasetError.invalid("Complete training and held-out evaluation before saving a model.")
        }
        _ = try Self.validateResult(checkpoint: source)
        let fm = FileManager.default
        try fm.copyItem(at: source, to: destination)
        do {
            try fm.copyItem(at: source.deletingPathExtension().appendingPathExtension("json"),
                            to: destination.deletingPathExtension().appendingPathExtension("json"))
            _ = try Self.validateResult(checkpoint: destination)
        } catch {
            try? fm.removeItem(at: destination)
            try? fm.removeItem(at: destination.deletingPathExtension().appendingPathExtension("json"))
            throw error
        }
    }
}

nonisolated struct TrainingConfig: Codable {
    var epochs: Int
    var lr: Double
    var batchSize: Int
    var augment: Bool
    var baseModel: String
    var imageCount: Int
    var annotated: Int
    var imageURLs: [URL] = []
}

nonisolated struct TrainingResultReport: Codable {
    var kind: String
    var checkpointHash: String
    var checkpointValidated: Bool
    var dataset: TrainingManifest
    var metrics: FTMetrics
}
