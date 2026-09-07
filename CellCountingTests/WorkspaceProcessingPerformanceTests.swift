import Foundation
import ImageIO
import Testing
@testable import CellCounting

struct WorkspaceProcessingPerformanceTests {
    @Test func stitchingAccountsForEveryLargeLiveBufferAndRejectsOverBudget() throws {
        let plane = WorkspacePixelPlane(width: 10, height: 10,
                                        pixels: Array(repeating: 1, count: 100))
        let tiles = [WorkspaceTile(plane: plane)]
        let estimate = ImageRegistrationService.memoryEstimate(
            tiles: tiles, outputPixels: 100, blend: .average)

        #expect(estimate.outputBytes == 400)
        #expect(estimate.coverageBytes == 200)
        #expect(estimate.liveInputBytes == 400)
        #expect(estimate.previewBytes == 400)
        #expect(estimate.fixedReserveBytes > 0)

        do {
            _ = try ImageRegistrationService.stitch(
                tiles: tiles, maxWorkingBytes: estimate.totalBytes - 1)
            Issue.record("Stitching must reject work before allocating beyond its budget")
        } catch let error as ImageRegistrationError {
            #expect(error == .workingMemoryExceeded(
                requiredBytes: estimate.totalBytes, limitBytes: estimate.totalBytes - 1))
        }
    }

    @Test func registrationChecksCancellationInsideItsSearchAndReportsProgress() throws {
        let width = 128
        let pixels = (0..<(width * width)).map { index in
            Float((index * 37 + index / width * 13) % 251) / 250
        }
        let plane = WorkspacePixelPlane(width: width, height: width, pixels: pixels)
        let cancellation = CancellationProbe(checksBeforeCancellation: 12)
        let progress = ProgressProbe()

        _ = try ImageRegistrationService.estimateTranslation(
            reference: plane, moving: plane, maxShift: 4,
            progress: { progress.record($0) })
        #expect(progress.updates.count > 1)
        #expect(progress.updates.last?.fraction == 1)
        #expect(progress.updates.allSatisfy { (0...1).contains($0.fraction) })

        #expect(throws: CancellationError.self) {
            _ = try ImageRegistrationService.estimateTranslation(
                reference: plane, moving: plane, maxShift: 32,
                cancellationCheck: { try cancellation.check() })
        }
        #expect(cancellation.checkCount > 12)
    }

    @Test func stitchingChecksCancellationInsideRows() throws {
        let plane = WorkspacePixelPlane(width: 128, height: 128,
                                        pixels: Array(repeating: 1, count: 128 * 128))
        let cancellation = CancellationProbe(checksBeforeCancellation: 6)
        #expect(throws: CancellationError.self) {
            _ = try ImageRegistrationService.stitch(
                tiles: [.init(plane: plane)],
                cancellationCheck: { try cancellation.check() })
        }
        #expect(cancellation.checkCount > 6)
    }

    @Test func maximumStitchPreservesNegativePixels() throws {
        let plane = WorkspacePixelPlane(width: 2, height: 2, pixels: [-4, -3, -2, -1])
        let result = try ImageRegistrationService.stitch(
            tiles: [.init(plane: plane)], blend: .maximum)
        #expect(result.plane.pixels == plane.pixels)
    }

    @Test func trainingLabelEncodingUsesOneProviderOwnedFullSizeBuffer() throws {
        let plan = try WorkspaceTrainingLabelService.encodingPlan(width: 64, height: 32)
        #expect(plan.pixelCount == 2_048)
        #expect(plan.bytesPerRow == 128)
        #expect(plan.providerBytes == 4_096)
        #expect(plan.fullSizeBufferCount == 1)
        #expect(throws: WorkspaceTrainingLabelError.dimensionsTooLarge) {
            _ = try WorkspaceTrainingLabelService.encodingPlan(width: Int.max, height: 2)
        }
    }

    @Test func providerOwnedTrainingLabelExportIsReadableAndSixteenBit() throws {
        var document = WorkspacePaintDocument(
            width: 16, height: 12,
            classes: [.init(value: 7, name: "Cell", colorHex: "#00FF00")])
        document.append(.init(classValue: 7, radiusPx: 2,
                              points: [.init(x: 8, y: 6)]))
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cc-label-buffer-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appendingPathComponent("labels.tiff")

        _ = try WorkspaceTrainingLabelService.export(
            document: document, sourceImageURL: directory.appendingPathComponent("source.tif"),
            labelURL: output)
        let source = try #require(CGImageSourceCreateWithURL(output as CFURL, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(image.width == 16)
        #expect(image.height == 12)
        #expect(image.bitsPerComponent == 16)
    }

    @Test func compactActorDocumentStoreRoundTripsOffMainAPIAndShrinksJSON() async throws {
        let axes = (0..<12).map { WorkspaceAxis(name: "Axis \($0)", kind: .other, length: 2) }
        var workspace = MicroscopyWorkspace(name: "Compact project", axes: axes)
        for index in 0..<40 {
            workspace.addLayer(.init(name: "Layer \(index)", kind: .image,
                                     source: .generated(operation: "test"), payload: .raster,
                                     axisIDs: axes.map(\.id)))
        }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cc-document-worker-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let compactURL = directory.appendingPathComponent("compact.json")
        let prettyURL = directory.appendingPathComponent("pretty.json")

        try await WorkspaceDocumentStore.saveInBackground(workspace, to: compactURL)
        try WorkspaceDocumentStore.save(workspace, to: prettyURL)
        let restored = try await WorkspaceDocumentStore.loadInBackground(from: compactURL)
        let compactSize = try compactURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        let prettySize = try prettyURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0

        #expect(restored.id == workspace.id)
        #expect(restored.name == workspace.name)
        #expect(restored.axes == workspace.axes)
        #expect(restored.layers == workspace.layers)
        #expect(abs(restored.createdAt.timeIntervalSince(workspace.createdAt)) < 1)
        #expect(abs(restored.modifiedAt.timeIntervalSince(workspace.modifiedAt)) < 1)
        #expect(compactSize < prettySize)
    }

    @Test func workflowForwardsProgressFromLongImageKernels() async throws {
        let referenceID = UUID()
        let movingID = UUID()
        let pixels = (0..<(96 * 96)).map { Float(($0 * 37) % 251) / 250 }
        let plane = WorkspacePixelPlane(width: 96, height: 96, pixels: pixels)
        var workspace = MicroscopyWorkspace(name: "Progress", axes: [])
        workspace.addLayer(.init(id: referenceID, name: "Reference", kind: .image,
                                 source: .generated(operation: "test"), payload: .raster,
                                 axisIDs: []))
        workspace.addLayer(.init(id: movingID, name: "Moving", kind: .image,
                                 source: .generated(operation: "test"), payload: .raster,
                                 axisIDs: []))
        let recorder = WorkflowProgressRecorder()

        _ = try await WorkspaceWorkflowService().execute(
            .init(name: "Registration", steps: [
                .register(referenceID: referenceID, movingID: movingID, maxShift: 12),
            ]),
            context: .init(workspace: workspace,
                           planes: [referenceID: plane, movingID: plane])) { update in
                await recorder.append(update)
            }

        let updates = await recorder.values
        // The bridge keeps only the latest update. A fast real kernel may
        // finish before its consumer runs, so only its final phase is required.
        // The controlled test below proves in-flight forwarding separately.
        #expect(updates.contains { $0.title == "Registering" && $0.stepFraction == 1 })
        #expect(updates.last?.fraction == 1)
    }

    @Test func workflowKernelForwardsInFlightProgressBeforeTheWorkerCanFinish() async throws {
        let acknowledgement = DispatchSemaphore(value: 0)
        let progress = ProgressProbe()
        let halfway = WorkspaceImageProcessingProgress(phase: "Controlled kernel",
                                                       completedUnits: 1, totalUnits: 2)
        let finished = WorkspaceImageProcessingProgress(phase: "Controlled kernel",
                                                        completedUnits: 2, totalUnits: 2)
        let forwardedBeforeCompletion = try await runWorkflowImageKernel(operation: { update in
            update(halfway)
            // Finite failure guard: dropping or failing to forward the update
            // cannot leave this test blocked forever. This is a handshake,
            // not a race against the speed of image registration.
            let delivered = acknowledgement.wait(timeout: .now() + 5) == .success
            update(finished)
            return delivered
        }, progress: { update in
            progress.record(update)
            if update == halfway { acknowledgement.signal() }
        })

        #expect(forwardedBeforeCompletion)
        #expect(progress.updates == [halfway, finished])
    }
}

private final class CancellationProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let checksBeforeCancellation: Int
    private var checks = 0

    init(checksBeforeCancellation: Int) {
        self.checksBeforeCancellation = checksBeforeCancellation
    }

    var checkCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return checks
    }

    func check() throws {
        lock.lock()
        checks += 1
        let shouldCancel = checks > checksBeforeCancellation
        lock.unlock()
        if shouldCancel { throw CancellationError() }
    }
}

private final class ProgressProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [WorkspaceImageProcessingProgress] = []

    var updates: [WorkspaceImageProcessingProgress] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func record(_ update: WorkspaceImageProcessingProgress) {
        lock.lock()
        storage.append(update)
        lock.unlock()
    }
}

private actor WorkflowProgressRecorder {
    private(set) var values: [WorkspaceWorkflowProgress] = []

    func append(_ update: WorkspaceWorkflowProgress) {
        values.append(update)
    }
}
