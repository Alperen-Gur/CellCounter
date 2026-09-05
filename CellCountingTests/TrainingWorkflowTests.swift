import Foundation
import CoreGraphics
import Testing
@testable import CellCounting

struct TrainingWorkflowTests {
    private func cell(_ x: Double, _ y: Double, side: Double = 2) -> DetectedCell {
        DetectedCell(cx: x + side / 2, cy: y + side / 2, diameter: side, diameterPx: side,
                     contourPx: [.init(x: x, y: y), .init(x: x + side, y: y),
                                 .init(x: x + side, y: y + side), .init(x: x, y: y + side)])
    }
    private func sample(index: Int, group: String? = nil) -> TrainingSample {
        TrainingSample(id: UUID(), name: "field-\(index).tif",
                       sourceURL: URL(fileURLWithPath: "/tmp/field-\(index).tif"),
                       width: 6, height: 5, cells: [cell(0, 0)],
                       group: group ?? "specimen-\(index)", sourceHash: "hash-\(index)", reviewed: true)
    }
    private func temporary() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("training-test-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @MainActor @Test func datasetSelectionSnapshotsLatestMasksAndPlaneSettings() {
        let image = ImageRecord(fileName: "reviewed.tif", originalPath: "/fixture/reviewed.tif", widthPx: 6, heightPx: 5)
        let unlabeled = ImageRecord(fileName: "unlabeled.tif", originalPath: "/fixture/unlabeled.tif", widthPx: 6, heightPx: 5)
        let detection = DetectionRecord(detectorId: "cp-cyto3", cells: [cell(0, 0), cell(4, 3)])
        image.detection = detection
        detection.cells = [cell(4, 3)]
        var settings = AnalysisRunSettings()
        settings.zProjection = "mean"; settings.segmentChannel = 2
        detection.runSettings = settings
        let snapshot = TrainingDatasetService.samples(from: [image, unlabeled])
        #expect(snapshot.count == 1)
        #expect(snapshot[0].cells.count == 1)
        #expect(snapshot[0].cells[0].cx == 5)
        #expect(snapshot[0].zProjection == "mean" && snapshot[0].segmentChannel == 2)
        #expect(snapshot[0].sourceSettingsKnown)
        #expect(snapshot[0].detectionID == detection.id)
        #expect(snapshot[0].detectionRevision == detection.cellsRevision)
        #expect(!snapshot[0].reviewed)
        detection.cells = [cell(0, 0)]
        #expect(snapshot[0].cells[0].cx == 5)
    }
    @Test func deterministicGroupSplitKeepsRelatedImagesTogether() throws {
        let samples = (0..<12).map { sample(index: $0, group: "specimen-\($0 / 2)") }
        let split = TrainingSplit(trainPercent: 50, validationPercent: 25, seed: 77)
        let assignments = try split.assignments(for: samples)
        #expect(assignments == (try split.assignments(for: Array(samples.reversed()))))
        #expect(Set(assignments.values) == Set(["train", "validation", "test"]))
        for pair in stride(from: 0, to: 12, by: 2) {
            #expect(assignments[samples[pair].id] == assignments[samples[pair + 1].id])
        }
        #expect(assignments.values.filter { $0 == "train" }.count == 6)
        #expect(assignments.values.filter { $0 == "validation" }.count == 4)
        #expect(assignments.values.filter { $0 == "test" }.count == 2)
    }
    @Test func insufficientGroupsAndInvalidSharesFail() {
        #expect(throws: TrainingDatasetError.self) {
            try TrainingSplit().assignments(for: [sample(index: 0), sample(index: 1)])
        }
        #expect(throws: TrainingDatasetError.self) {
            try TrainingSplit(trainPercent: 80, validationPercent: 20).assignments(for: (0..<5).map { sample(index: $0) })
        }
    }
    @Test func duplicateContentHashAndDuplicateIdentityFail() {
        var samples = (0..<4).map { sample(index: $0) }
        samples[3].sourceHash = samples[0].sourceHash
        #expect(throws: TrainingDatasetError.self) { try TrainingSplit().assignments(for: samples) }
        samples[3] = samples[0]
        #expect(throws: TrainingDatasetError.self) { try TrainingSplit().assignments(for: samples) }
    }
    @Test func rasterUsesSourceCoordinatesAndDistinctInstanceIDs() throws {
        let labels = try TrainingLabelRasterizer.labels(width: 6, height: 5, cells: [cell(0, 0), cell(4, 3)])
        #expect(labels.count == 30)
        #expect(labels[0] == 1 && labels[1] == 1 && labels[6] == 1 && labels[7] == 1)
        #expect(labels[22] == 2 && labels[23] == 2 && labels[28] == 2 && labels[29] == 2)
        #expect(labels.filter { $0 != 0 }.count == 8)
        let removed = try TrainingLabelRasterizer.labels(width: 6, height: 5, cells: [cell(4, 3)])
        #expect(removed[0] == 0 && removed[22] == 1)
    }
    @Test func invalidOverlappingAndMissingContoursFail() {
        #expect(throws: TrainingDatasetError.self) {
            try TrainingLabelRasterizer.labels(width: 6, height: 5, cells: [cell(0, 0), cell(1, 1)])
        }
        let marker = DetectedCell(cx: 2, cy: 2, diameter: 2, diameterPx: 2)
        #expect(throws: TrainingDatasetError.self) {
            try TrainingLabelRasterizer.labels(width: 6, height: 5, cells: [marker])
        }
        #expect(throws: TrainingDatasetError.self) {
            try TrainingLabelRasterizer.labels(width: 6, height: 5, cells: [cell(100, 100)])
        }
        #expect(throws: TrainingDatasetError.self) {
            try TrainingLabelRasterizer.labels(width: 65536, height: 65536, cells: [cell(0, 0)])
        }
    }
    @Test func stagingWritesActualCorrectedMasksAndFrozenSources() throws {
        let directory = try temporary()
        defer { try? FileManager.default.removeItem(at: directory) }
        var samples = (0..<3).map { sample(index: $0) }
        for i in samples.indices {
            samples[i].sourceURL = directory.appendingPathComponent("source-\(i).tif")
            try Data("original-source-\(i)".utf8).write(to: samples[i].sourceURL)
            samples[i].sourceHash = try TrainingDatasetService.fileHash(samples[i].sourceURL)
            samples[i].cells = [cell(4, 3)]
            samples[i].zProjection = "mean"; samples[i].segmentChannel = 2
        }
        let manifestURL = try TrainingDatasetService.stage(samples: samples, split: TrainingSplit(),
                                                            in: directory.appendingPathComponent("stage"))
        let manifest = try JSONDecoder().decode(TrainingManifest.self, from: Data(contentsOf: manifestURL))
        #expect(manifest.samples.count == 3)
        #expect(Set(manifest.samples.map(\.partition)) == Set(["train", "validation", "test"]))
        for entry in manifest.samples {
            #expect(entry.zProjection == "mean" && entry.segmentChannel == 2)
            let bytes = try Data(contentsOf: URL(fileURLWithPath: entry.labelsPath))
            #expect(bytes.count == 6 * 5 * 4)
            #expect(bytes[0] == 0)
            #expect(bytes[22 * 4] == 1)
            #expect(entry.sourceHash == (try TrainingDatasetService.fileHash(URL(fileURLWithPath: entry.imagePath))))
        }
        let staged = manifest.samples.first { $0.id == samples[0].id.uuidString }!
        try Data("changed-original".utf8).write(to: samples[0].sourceURL)
        #expect(try Data(contentsOf: URL(fileURLWithPath: staged.imagePath)) == Data("original-source-0".utf8))
    }
    @Test func unreviewedImagesAndChangedOrDuplicateSourceBytesFail() throws {
        let directory = try temporary()
        defer { try? FileManager.default.removeItem(at: directory) }
        var samples = (0..<3).map { sample(index: $0) }
        samples[0].reviewed = false
        #expect(throws: TrainingDatasetError.self) {
            try TrainingDatasetService.stage(samples: samples, split: TrainingSplit(), in: directory.appendingPathComponent("unreviewed"))
        }
        for i in samples.indices {
            samples[i].reviewed = true
            samples[i].sourceHash = ""
            samples[i].sourceURL = directory.appendingPathComponent("same-\(i).tif")
            try Data("same-image-content".utf8).write(to: samples[i].sourceURL)
        }
        #expect(throws: TrainingDatasetError.self) {
            try TrainingDatasetService.stage(samples: samples, split: TrainingSplit(), in: directory.appendingPathComponent("duplicates"))
        }
        samples[0].sourceHash = "changed"
        #expect(throws: TrainingDatasetError.self) {
            try TrainingDatasetService.stage(samples: samples, split: TrainingSplit(), in: directory.appendingPathComponent("changed"))
        }
    }
    @MainActor @Test func unlabeledTrainingFailsWithoutSimulatedProgress() {
        let trainer = TrainingService()
        trainer.start(epochs: 10, baseModel: "cp-cyto3", lr: 0.001, batchSize: 1,
                      augment: false, imageURLs: [URL(fileURLWithPath: "/tmp/image.tif")], annotated: 100)
        if case .failed(let message) = trainer.progress { #expect(message.contains("corrected cell masks")) }
        else { Issue.record("Unlabeled input must fail immediately") }
        #expect(!trainer.canActivateCheckpoint)
        #expect(!TrainingService.isTrainingActive)
        #expect(trainer.lastCheckpointURL == nil)
    }
    @Test func invalidMetricsAndMissingEvaluationCannotActivate() throws {
        #expect(!FTMetrics(ap50: 1, f1: 1, precision: 1, recall: 1, meanDiamError: 0).isValid)
        #expect(!FTMetrics(ap50: .nan, f1: 1, precision: 1, recall: 1, meanDiamError: 0, testImages: 1).isValid)
        let directory = try temporary()
        defer { try? FileManager.default.removeItem(at: directory) }
        let checkpoint = directory.appendingPathComponent("empty.ccmodel")
        try Data().write(to: checkpoint)
        #expect(throws: (any Error).self) { try TrainingService.validateResult(checkpoint: checkpoint) }
        try Data(repeating: 42, count: 2048).write(to: checkpoint)
        #expect(throws: (any Error).self) { try TrainingService.validateResult(checkpoint: checkpoint) }
    }
    @Test func verifiedResultRequiresMatchingWeightsAndIsolatedReport() throws {
        let directory = try temporary()
        defer { try? FileManager.default.removeItem(at: directory) }
        let checkpoint = directory.appendingPathComponent("report-fixture.ccmodel")
        let bytes = Data(repeating: 42, count: 2048)
        try bytes.write(to: checkpoint)
        let entries = ["train", "validation", "test"].enumerated().map { index, partition in
            TrainingManifest.Entry(id: String(index), name: "field-\(index)",
                                   imagePath: "/fixture/\(index).png", labelsPath: "/fixture/\(index).u32",
                                   width: 6, height: 5, group: "specimen-\(index)",
                                   sourceHash: String(repeating: String(index), count: 64),
                                   labelsHash: String(repeating: "a", count: 64), partition: partition,
                                   zProjection: "max", segmentChannel: 0)
        }
        let metrics = FTMetrics(ap50: 0.8, f1: 0.7, precision: 0.6, recall: 0.9,
                                meanDiamError: 1.25, testImages: 1)
        var report = TrainingResultReport(kind: "cellpose", checkpointHash: try TrainingDatasetService.fileHash(checkpoint),
                                          checkpointValidated: true,
                                          dataset: TrainingManifest(split: TrainingSplit(), samples: entries), metrics: metrics)
        let reportURL = checkpoint.deletingPathExtension().appendingPathExtension("json")
        try JSONEncoder().encode(report).write(to: reportURL)
        #expect(try TrainingService.validateResult(checkpoint: checkpoint) == metrics)
        try Data(repeating: 43, count: 2048).write(to: checkpoint)
        #expect(throws: TrainingDatasetError.self) { try TrainingService.validateResult(checkpoint: checkpoint) }
        try bytes.write(to: checkpoint)
        report.dataset.samples[2].group = report.dataset.samples[0].group
        try JSONEncoder().encode(report).write(to: reportURL)
        #expect(throws: TrainingDatasetError.self) { try TrainingService.validateResult(checkpoint: checkpoint) }
    }

}
