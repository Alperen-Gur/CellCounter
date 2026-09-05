import Foundation
import CryptoKit

nonisolated struct TrainingManifest: Codable, Sendable {
    var version = 1
    var split: TrainingSplit
    var samples: [Entry]
    struct Entry: Codable, Sendable {
        var id: String
        var name: String
        var imagePath: String
        var labelsPath: String
        var width: Int
        var height: Int
        var group: String
        var sourceHash: String
        var labelsHash: String
        var partition: String
        var zProjection: String
        var segmentChannel: Int?
        var useRGBLuminance: Bool = false
    }
}

enum TrainingDatasetService {
    @MainActor static func samples(from images: [ImageRecord]) -> [TrainingSample] {
        images.compactMap { image in
            guard let detection = image.detection else { return nil }
            let settings = detection.runSettings
            let selection = sourceSelection(settings)
            return TrainingSample(id: image.id, name: image.fileName,
                                  sourceURL: image.storedURL, width: image.widthPx,
                                  height: image.heightPx, cells: detection.cells,
                                  group: image.batch.map { "\($0.displayName) [\($0.id.uuidString.prefix(8))]" } ?? "Image \(image.id.uuidString.prefix(8))",
                                  sourceHash: image.fileHash ?? "",
                                  zProjection: detection.runSettings?.zProjection ?? "max",
                                  segmentChannel: selection.channel, useRGBLuminance: selection.luminance,
                                  sourceSettingsKnown: detection.runSettings != nil,
                                  detectionID: detection.id, detectionRevision: detection.cellsRevision)
        }
    }

    private static func sourceSelection(_ settings: AnalysisRunSettings?) -> (channel: Int, luminance: Bool) {
        let selected = max(0, settings?.segmentChannel ?? 0)
        let primary = settings?.channels.first ?? 0
        let order = [selected] + (0..<max(3, selected + 1)).filter { $0 != selected }
        let channel = primary > 0 && primary <= order.count ? order[primary - 1] : selected
        return (channel, primary == 0 && selected == 0)
    }

    /// Uses the same input plane as training review, without requiring masks.
    /// Suitable for import/setup previews with any installed source reader.
    @MainActor static func preview(image: ImageRecord, settings: AnalysisRunSettings) async throws -> Data {
        let selection = sourceSelection(settings)
        let sample = TrainingSample(id: image.id, name: image.fileName,
                                    sourceURL: image.storedURL, width: image.widthPx, height: image.heightPx,
                                    cells: [], group: "preview", sourceHash: image.fileHash ?? "",
                                    zProjection: settings.zProjection, segmentChannel: selection.channel,
                                    useRGBLuminance: selection.luminance)
        return try await preview(for: sample, preferredFamily: ModelFamily(rawValue: settings.modelFamily))
    }

    @MainActor static func preview(for sample: TrainingSample, preferredFamily: ModelFamily? = nil) async throws -> Data {
        let interpreters = PythonRuntime.vendorReaderInterpreters(preferredFamily: preferredFamily)
        guard !interpreters.isEmpty,
              let script = PythonRuntime.stagedScriptURL(named: "_training_dataset.py")
                ?? PythonRuntime.bundledPythonURL(named: "_training_dataset.py") else {
            throw TrainingDatasetError.invalid("Install an image-reading model in Models to preview the selected source plane.")
        }
        let control = PreviewProcessControl()
        let worker = Task.detached(priority: .userInitiated) {
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("training-preview-\(UUID())")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: dir) }
            let output = dir.appendingPathComponent("preview.png")
            var lastError = "Source plane could not be decoded."
            for (index, python) in interpreters.enumerated() {
                try Task.checkCancellation()
                let errorURL = dir.appendingPathComponent("error-\(index).txt")
                _ = FileManager.default.createFile(atPath: errorURL.path, contents: nil)
                let errors = try FileHandle(forWritingTo: errorURL)
                defer { try? errors.close() }
                let process = Process(); process.executableURL = python
                process.arguments = [script.path, "--preview", sample.sourceURL.path,
                                     "--output", output.path, "--z-project", sample.zProjection]
                if let channel = sample.segmentChannel { process.arguments! += ["--channel", String(channel)] }
                if sample.useRGBLuminance { process.arguments!.append("--rgb-luminance") }
                process.standardError = errors; process.standardOutput = FileHandle.nullDevice
                do {
                    try control.start(process)
                    await MainActor.run { ChildProcessTracker.shared.register(process, kind: .other) }
                    process.waitUntilExit()
                    await MainActor.run { ChildProcessTracker.shared.forget(process) }
                    try Task.checkCancellation()
                    if process.terminationStatus == 0 { return try Data(contentsOf: output) }
                    lastError = (try? String(contentsOf: errorURL, encoding: .utf8)) ?? lastError
                } catch is CancellationError { throw CancellationError() }
                catch { lastError = error.localizedDescription }
            }
            throw TrainingDatasetError.invalid(lastError)
        }
        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel(); control.cancel()
        }
    }

    private nonisolated final class PreviewProcessControl: @unchecked Sendable {
        private let lock = NSLock()
        private var process: Process?
        private var cancelled = false
        func start(_ process: Process) throws {
            lock.lock(); defer { lock.unlock() }
            guard !cancelled else { throw CancellationError() }
            try process.run()
            self.process = process
        }
        func cancel() {
            lock.lock(); defer { lock.unlock() }
            cancelled = true
            if let process, process.isRunning { process.terminate() }
        }
    }

    /// Owns only `directory`, which the caller creates uniquely for this run.
    nonisolated static func stage(samples: [TrainingSample], split: TrainingSplit,
                                  in directory: URL) throws -> URL {
        guard !samples.isEmpty, samples.allSatisfy(\.reviewed) else {
            throw TrainingDatasetError.invalid("Review and confirm every selected image before training.")
        }
        let assignments = try split.assignments(for: samples)
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        var entries: [TrainingManifest.Entry] = []
        var contentHashes = Set<String>()
        for sample in samples.sorted(by: { $0.id.uuidString < $1.id.uuidString }) {
            try Task.checkCancellation()
            let source = directory.appendingPathComponent(sample.id.uuidString).appendingPathExtension(sample.sourceURL.pathExtension)
            // A copy freezes source bytes, even if the original gets replaced during training.
            try fm.copyItem(at: sample.sourceURL, to: source)
            let hash = try fileHash(source)
            guard contentHashes.insert(hash).inserted else {
                throw TrainingDatasetError.invalid("Duplicate source bytes: \(sample.name). Remove repeated images before training.")
            }
            if !sample.sourceHash.isEmpty && sample.sourceHash != hash {
                throw TrainingDatasetError.invalid("\(sample.name) changed on disk after import. Reimport and review it before training.")
            }
            let labels = try TrainingLabelRasterizer.labels(width: sample.width, height: sample.height, cells: sample.cells)
            let labelURL = directory.appendingPathComponent("\(sample.id.uuidString).labels.u32")
            let littleEndian = labels.map(\.littleEndian)
            let data = littleEndian.withUnsafeBytes { Data($0) }
            try data.write(to: labelURL, options: .atomic)
            entries.append(.init(id: sample.id.uuidString, name: sample.name, imagePath: source.path,
                                 labelsPath: labelURL.path, width: sample.width, height: sample.height,
                                 group: sample.group.trimmingCharacters(in: .whitespacesAndNewlines), sourceHash: hash,
                                 labelsHash: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
                                 partition: assignments[sample.id]!, zProjection: sample.zProjection,
                                 segmentChannel: sample.segmentChannel, useRGBLuminance: sample.useRGBLuminance))
        }
        let url = directory.appendingPathComponent("dataset.json")
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(TrainingManifest(split: split, samples: entries)).write(to: url, options: .atomic)
        return url
    }

    nonisolated static func fileHash(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty { hash.update(data: data) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
