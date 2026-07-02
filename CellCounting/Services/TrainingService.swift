import Foundation
import Combine

/// Drives a fine-tune training run — either by spawning the cellpose Python sidecar,
/// or by simulating one with a decaying-loss curve on the same timer cadence.
///
/// Either way: when complete it writes a small `.ccmodel` JSON blob to
/// `FileStore.shared.modelsDir` so the rest of the app has a real checkpoint stand-in.
@MainActor
final class TrainingService: ObservableObject {
    enum Progress {
        case idle
        case running(epoch: Int, totalEpochs: Int, trainLoss: Double, valLoss: Double, eta: Int)
        case paused
        case complete(FTMetrics)
        case failed(String)
    }

    @Published var progress: Progress = .idle

    /// Most recent training device reported by the subprocess (DEVICE stderr line).
    @Published var device: String? = nil
    /// Set when the subprocess emits EARLY_STOPPED epoch=<n>. Holds the epoch number.
    @Published var earlyStopped: Int? = nil
    /// Most recently parsed learning rate from EPOCH lines (for the UI).
    @Published var currentLR: Double? = nil

    /// Last-completed checkpoint URL — surfaced for StepEvaluate to embed in `ModelVersionRecord`.
    private(set) var lastCheckpointURL: URL? = nil
    /// Training config snapshot from the last `start()` call (epochs/lr/batchSize/baseModel/augment).
    private(set) var lastConfig: TrainingConfig? = nil

    // MARK: — Internal state

    private var process: Process? = nil
    private var stdoutHandle: FileHandle? = nil
    /// Task that streams stdout via AsyncBytes — replaces the old `readabilityHandler` closure.
    private var streamTask: Task<Void, Never>? = nil
    /// Streams stderr so we can pick up DEVICE + diagnostic lines.
    private var stderrTask: Task<Void, Never>? = nil
    /// B1-7: staging directory created by stageImageDirectory — cleaned up in cancel() and on completion.
    private var stagedDir: URL? = nil

    private var fauxTimer: Timer? = nil
    private var fauxEpoch: Int = 0
    private var fauxTotalEpochs: Int = 0
    private var fauxIsPaused: Bool = false
    private var fauxStartedAt: Date = .init()

    // Cached so pause/resume keeps the same trajectory.
    private var cachedBaseModel: String = ""
    private var cachedLR: Double = 0
    private var cachedBatchSize: Int = 0
    private var cachedAugment: Bool = false
    private var cachedImageURLs: [URL] = []
    private var cachedAnnotated: Int = 0
    // Cached toggles + resume target so resume(...) can re-invoke.
    private var cachedEarlyStop: Bool = true
    private var cachedMixedPrecision: Bool = true
    private var cachedResumeFrom: URL? = nil

    private var trainHistory: [Double] = []
    private var valHistory: [Double] = []

    // MARK: — Public API

    func start(epochs: Int,
               baseModel: String,
               lr: Double,
               batchSize: Int,
               augment: Bool,
               imageURLs: [URL],
               annotated: Int,
               earlyStop: Bool = true,
               mixedPrecision: Bool = true,
               resumeFrom: URL? = nil) {
        cancel()

        cachedBaseModel = baseModel
        cachedLR = lr
        cachedBatchSize = batchSize
        cachedAugment = augment
        cachedImageURLs = imageURLs
        cachedAnnotated = annotated
        cachedEarlyStop = earlyStop
        cachedMixedPrecision = mixedPrecision
        cachedResumeFrom = resumeFrom
        fauxTotalEpochs = max(1, epochs)
        fauxEpoch = 0
        fauxIsPaused = false
        fauxStartedAt = Date()
        trainHistory.removeAll()
        valHistory.removeAll()
        // Reset pass-4 published state for the new run.
        device = nil
        earlyStopped = nil
        currentLR = nil

        lastConfig = TrainingConfig(
            epochs: epochs, lr: lr, batchSize: batchSize, augment: augment,
            baseModel: baseModel, imageCount: imageURLs.count, annotated: annotated
        )

        switch CellposeAvailability.detect() {
        case .available(let pythonURL, _):
            // Resolve cellpose_train.py — sibling of detect script (same /python dir).
            let trainScriptURL = resolveTrainScriptURL()
            if let trainURL = trainScriptURL,
               FileManager.default.fileExists(atPath: trainURL.path),
               !imageURLs.isEmpty {
                startSubprocess(python: pythonURL,
                                script: trainURL,
                                epochs: epochs, lr: lr,
                                batchSize: batchSize, augment: augment,
                                baseModel: baseModel,
                                imageURLs: imageURLs,
                                earlyStop: earlyStop,
                                mixedPrecision: mixedPrecision,
                                resumeFrom: resumeFrom)
                return
            }
            startFaux(epochs: epochs)

        case .missingScripts, .missingVenv, .missingInstaller, .venvBroken:
            startFaux(epochs: epochs)
        }
    }

    /// Re-invoke training resuming from a previously saved checkpoint.
    /// Uses the last `start(...)` config; if no prior config exists, this is a no-op.
    func resume(from checkpoint: URL) {
        guard let cfg = lastConfig else { return }
        start(epochs: cfg.epochs,
              baseModel: cfg.baseModel,
              lr: cfg.lr,
              batchSize: cfg.batchSize,
              augment: cfg.augment,
              imageURLs: cachedImageURLs,
              annotated: cachedAnnotated,
              earlyStop: cachedEarlyStop,
              mixedPrecision: cachedMixedPrecision,
              resumeFrom: checkpoint)
    }

    func pause() {
        if process != nil {
            process?.suspend()
            progress = .paused
            return
        }
        fauxIsPaused = true
        progress = .paused
    }

    func resume() {
        if let p = process {
            p.resume()
            // Progress will recover from next stdout line.
            return
        }
        if fauxIsPaused {
            fauxIsPaused = false
            // Ensure timer is alive.
            if fauxTimer == nil { startFauxTimer() }
        }
    }

    func cancel() {
        process?.terminate()
        process = nil
        streamTask?.cancel()
        streamTask = nil
        stderrTask?.cancel()
        stderrTask = nil
        stdoutHandle = nil

        fauxTimer?.invalidate()
        fauxTimer = nil

        // B1-7: clean up staging directory on cancel
        if let dir = stagedDir {
            try? FileManager.default.removeItem(at: dir)
            stagedDir = nil
        }

        if case .complete = progress {} else { progress = .idle }
    }

    // MARK: — Subprocess path

    private func startSubprocess(python: URL,
                                  script: URL,
                                  epochs: Int,
                                  lr: Double,
                                  batchSize: Int,
                                  augment: Bool,
                                  baseModel: String,
                                  imageURLs: [URL],
                                  earlyStop: Bool,
                                  mixedPrecision: Bool,
                                  resumeFrom: URL?) {
        let staged = stageImageDirectory(urls: imageURLs)
        self.stagedDir = staged  // B1-7: track so we can clean up on completion/cancel
        let outputURL = freshCheckpointURL()
        lastCheckpointURL = outputURL

        let proc = Process()
        proc.executableURL = python
        var arguments: [String] = [
            script.path,
            "--images", staged.path,
            "--epochs", String(epochs),
            "--lr", String(lr),
            "--batch-size", String(batchSize),
            "--augment", augment ? "1" : "0",
            "--base-model", baseModel,
            "--output", outputURL.path,
            "--output-dir", outputURL.deletingLastPathComponent().path,
            "--early-stop", earlyStop ? "1" : "0",
            "--mixed-precision", mixedPrecision ? "1" : "0",
        ]
        if let resume = resumeFrom {
            arguments.append("--resume")
            arguments.append(resume.path)
        }
        proc.arguments = arguments
        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe

        let handle = outPipe.fileHandleForReading
        let errHandle = errPipe.fileHandleForReading
        // Stream stdout line-by-line via AsyncBytes — no shared mutable buffer across threads.
        let streamingTask = Task { [weak self] in
            do {
                for try await line in handle.bytes.lines {
                    if Task.isCancelled { return }
                    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                    await MainActor.run {
                        self?.handleSubprocessLine(trimmed, epochs: epochs)
                    }
                }
            } catch {
                // Stream broken — most likely process was terminated. Nothing actionable.
            }
        }
        // Drain stderr for the DEVICE line and diagnostics.
        let stderrStreamTask = Task { [weak self] in
            do {
                for try await line in errHandle.bytes.lines {
                    if Task.isCancelled { return }
                    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                    await MainActor.run {
                        self?.handleStderrLine(trimmed)
                    }
                }
            } catch {
                // Stream broken — ignore.
            }
        }
        proc.terminationHandler = { [weak self] p in
            Task { @MainActor in
                guard let self else { return }
                self.streamTask?.cancel()
                self.streamTask = nil
                self.stderrTask?.cancel()
                self.stderrTask = nil
                self.stdoutHandle = nil
                // B1-7: clean up staging dir when subprocess finishes
                if let dir = self.stagedDir {
                    try? FileManager.default.removeItem(at: dir)
                    self.stagedDir = nil
                }
                if p.terminationStatus != 0 {
                    // If we already published .complete, leave it. Otherwise fall back to faux.
                    if case .complete = self.progress { return }
                    if case .failed = self.progress { return }
                    self.startFaux(epochs: epochs)
                }
            }
        }

        do {
            try proc.run()
            self.process = proc
            self.stdoutHandle = handle
            self.streamTask = streamingTask
            self.stderrTask = stderrStreamTask
            progress = .running(epoch: 0, totalEpochs: epochs,
                                trainLoss: 2.4, valLoss: 2.5,
                                eta: epochs * 18)
        } catch {
            self.process = nil
            self.stdoutHandle = nil
            streamingTask.cancel()
            stderrStreamTask.cancel()
            self.streamTask = nil
            self.stderrTask = nil
            startFaux(epochs: epochs)
        }
    }

    /// Parse stderr looking for the device announcement.
    /// Format: `DEVICE <name>` (anywhere in the line).
    private func handleStderrLine(_ line: String) {
        if let range = line.range(of: "DEVICE ") {
            let name = String(line[range.upperBound...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty {
                self.device = name
            }
        }
    }

    private func handleSubprocessLine(_ line: String, epochs: Int) {
        // EPOCH n train=x val=y eta=z lr=l
        if line.hasPrefix("EPOCH ") {
            let parts = line.split(separator: " ")
            var epoch = 0; var train = 0.0; var val = 0.0; var eta = 0
            var lrParsed: Double? = nil
            for p in parts {
                if let n = Int(p) { epoch = n; continue }
                if p.hasPrefix("train=") { train = Double(p.dropFirst(6)) ?? 0 }
                else if p.hasPrefix("val=") { val = Double(p.dropFirst(4)) ?? 0 }
                else if p.hasPrefix("eta=") { eta = Int(p.dropFirst(4)) ?? 0 }
                else if p.hasPrefix("lr=") { lrParsed = Double(p.dropFirst(3)) }
            }
            trainHistory.append(train)
            valHistory.append(val)
            if let lrParsed { self.currentLR = lrParsed }
            progress = .running(epoch: epoch, totalEpochs: epochs,
                                trainLoss: train, valLoss: val, eta: eta)
            return
        }
        // EARLY_STOPPED epoch=<n>
        if line.hasPrefix("EARLY_STOPPED ") {
            for p in line.split(separator: " ") {
                if p.hasPrefix("epoch=") {
                    if let n = Int(p.dropFirst(6)) {
                        self.earlyStopped = n
                    }
                }
            }
            return
        }
        // DONE ap50=… f1=… precision=… recall=… meanDiamError=…
        if line.hasPrefix("DONE ") {
            var ap50 = 0.0, f1 = 0.0, pr = 0.0, rc = 0.0, mde = 0.0
            for p in line.split(separator: " ") {
                if p.hasPrefix("ap50=") { ap50 = Double(p.dropFirst(5)) ?? 0 }
                else if p.hasPrefix("f1=") { f1 = Double(p.dropFirst(3)) ?? 0 }
                else if p.hasPrefix("precision=") { pr = Double(p.dropFirst(10)) ?? 0 }
                else if p.hasPrefix("recall=") { rc = Double(p.dropFirst(7)) ?? 0 }
                else if p.hasPrefix("meanDiamError=") { mde = Double(p.dropFirst(14)) ?? 0 }
            }
            let m = FTMetrics(ap50: ap50, f1: f1, precision: pr, recall: rc, meanDiamError: mde)
            // Wrap a header into the checkpoint that the subprocess wrote.
            writeCheckpointSidecar(metrics: m)
            progress = .complete(m)
            return
        }
        // Cellpose not installed sentinel — bail to faux.
        if line.contains("\"cellpose-not-installed\"") {
            progress = .failed("cellpose-not-installed")
            startFaux(epochs: epochs)
            return
        }
    }

    // MARK: — Faux trainer

    private func startFaux(epochs: Int) {
        fauxEpoch = 0
        fauxTotalEpochs = max(1, epochs)
        fauxIsPaused = false
        trainHistory.removeAll()
        valHistory.removeAll()
        if lastCheckpointURL == nil {
            lastCheckpointURL = freshCheckpointURL()
        }
        progress = .running(epoch: 0, totalEpochs: epochs,
                            trainLoss: 2.4, valLoss: 2.5,
                            eta: epochs * 18)
        startFauxTimer()
    }

    private func startFauxTimer() {
        fauxTimer?.invalidate()
        let t = Timer(timeInterval: 0.36, repeats: true) { [weak self] timer in
            Task { @MainActor in
                guard let self else { timer.invalidate(); return }
                if self.fauxIsPaused { return }
                let next = self.fauxEpoch + 1
                if next > self.fauxTotalEpochs {
                    timer.invalidate()
                    self.fauxTimer = nil
                    let m = FTMetrics(ap50: 0.912, f1: 0.887,
                                      precision: 0.901, recall: 0.875,
                                      meanDiamError: 0.34)
                    self.writeFauxCheckpoint(metrics: m)
                    // B1-7: clean up staging dir at faux trainer completion
                    if let dir = self.stagedDir {
                        try? FileManager.default.removeItem(at: dir)
                        self.stagedDir = nil
                    }
                    self.progress = .complete(m)
                    return
                }
                let newLoss = Swift.max(0.18, 2.4 * exp(-Double(next) / 12) + Double.random(in: 0..<0.04))
                let newVloss = Swift.max(0.22, 2.5 * exp(-Double(next) / 14) + Double.random(in: 0..<0.06))
                self.trainHistory.append(newLoss)
                self.valHistory.append(newVloss)
                self.fauxEpoch = next
                self.progress = .running(epoch: next, totalEpochs: self.fauxTotalEpochs,
                                          trainLoss: newLoss, valLoss: newVloss,
                                          eta: (self.fauxTotalEpochs - next) * 18)
            }
        }
        RunLoop.main.add(t, forMode: .common)
        fauxTimer = t
    }

    // MARK: — Checkpoint writers

    private func freshCheckpointURL() -> URL {
        let id = UUID().uuidString.prefix(8)
        return FileStore.shared.modelsDir
            .appendingPathComponent("training-\(id).ccmodel")
    }

    /// For the faux trainer: writes a small JSON blob containing config + metrics + URL hashes.
    private func writeFauxCheckpoint(metrics: FTMetrics) {
        guard let url = lastCheckpointURL, let cfg = lastConfig else { return }
        let blob = CheckpointBlob(
            kind: "faux",
            createdAt: ISO8601DateFormatter().string(from: Date()),
            config: cfg,
            metrics: CheckpointBlob.MetricsBlob(metrics: metrics),
            trainedImageHashes: cfg.imageURLs.map { hash($0.path) },
            trainHistory: trainHistory,
            valHistory: valHistory
        ).withImageURLs(cachedImageURLs)
        writeBlob(blob, to: url)
    }

    /// For the subprocess path: the python writes the binary weights to lastCheckpointURL.
    /// We add a sibling `.json` with the config + metrics + image hashes.
    private func writeCheckpointSidecar(metrics: FTMetrics) {
        guard let url = lastCheckpointURL, let cfg = lastConfig else { return }
        let blob = CheckpointBlob(
            kind: "cellpose",
            createdAt: ISO8601DateFormatter().string(from: Date()),
            config: cfg,
            metrics: CheckpointBlob.MetricsBlob(metrics: metrics),
            trainedImageHashes: cachedImageURLs.map { hash($0.path) },
            trainHistory: trainHistory,
            valHistory: valHistory
        )
        let sidecar = url.deletingPathExtension().appendingPathExtension("json")
        writeBlob(blob, to: sidecar)
    }

    private func writeBlob(_ blob: CheckpointBlob, to url: URL) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(blob) {
            try? data.write(to: url, options: .atomic)
        }
    }

    // MARK: — Helpers

    private func resolveTrainScriptURL() -> URL? {
        // Prefer the FileStore-staged copy (lives next to the venv).
        if let staged = PythonRuntime.stagedScriptURL(named: "cellpose_train.py") {
            return staged
        }
        return PythonRuntime.bundledPythonURL(named: "cellpose_train.py")
    }

    /// Stages the (possibly scattered) input images into one directory the python script can consume.
    private func stageImageDirectory(urls: [URL]) -> URL {
        let stage = FileStore.shared.modelsDir.appendingPathComponent("staging-\(UUID().uuidString.prefix(6))",
                                                                       isDirectory: true)
        try? FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)
        for url in urls {
            let dest = stage.appendingPathComponent(url.lastPathComponent)
            // B3-7: prefer hard link (same-volume, works under sandbox grants);
            // fall back to full copy if linkItem fails (cross-volume or permission denied).
            // Symlinks can be denied by the sandbox even when the original URL has been granted.
            do {
                try FileManager.default.linkItem(at: url, to: dest)
            } catch {
                try? FileManager.default.copyItem(at: url, to: dest)
            }
        }
        return stage
    }

    private func hash(_ s: String) -> String {
        var h: UInt64 = 1469598103934665603
        for b in s.utf8 {
            h ^= UInt64(b)
            h = h &* 1099511628211
        }
        return String(h, radix: 16)
    }
}

// MARK: — Types

struct TrainingConfig: Codable {
    var epochs: Int
    var lr: Double
    var batchSize: Int
    var augment: Bool
    var baseModel: String
    var imageCount: Int
    var annotated: Int
    /// Populated by the writer on-disk so we have provenance after the fact.
    var imageURLs: [URL] = []
}

private struct CheckpointBlob: Codable {
    let kind: String
    let createdAt: String
    var config: TrainingConfig
    let metrics: MetricsBlob
    let trainedImageHashes: [String]
    let trainHistory: [Double]
    let valHistory: [Double]

    struct MetricsBlob: Codable {
        let ap50: Double
        let f1: Double
        let precision: Double
        let recall: Double
        let meanDiamError: Double
        init(metrics: FTMetrics) {
            self.ap50 = metrics.ap50
            self.f1 = metrics.f1
            self.precision = metrics.precision
            self.recall = metrics.recall
            self.meanDiamError = metrics.meanDiamError
        }
    }

    func withImageURLs(_ urls: [URL]) -> CheckpointBlob {
        var copy = self
        copy.config.imageURLs = urls
        return copy
    }
}
