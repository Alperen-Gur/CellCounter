import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

nonisolated struct WorkspaceWorkflowContext: Sendable {
    var workspace: MicroscopyWorkspace
    var planes: [UUID: WorkspacePixelPlane]
}

nonisolated struct WorkspaceWorkflowProgress: Sendable, Equatable {
    var completedSteps: Int
    var totalSteps: Int
    var title: String
    var stepFraction: Double = 0

    var fraction: Double {
        guard totalSteps > 0 else { return 1 }
        return min(max((Double(completedSteps) + stepFraction) / Double(totalSteps), 0), 1)
    }
}

private nonisolated func runWorkflowImageKernel<Value: Sendable>(
    operation: @escaping @Sendable (@escaping ImageRegistrationService.ProgressHandler) throws -> Value,
    progress: @escaping @Sendable (WorkspaceImageProcessingProgress) async -> Void
) async throws -> Value {
    let (updates, continuation) = AsyncStream.makeStream(
        of: WorkspaceImageProcessingProgress.self,
        bufferingPolicy: .bufferingNewest(1)
    )
    let worker = Task.detached(priority: .userInitiated) {
        defer { continuation.finish() }
        return try operation { continuation.yield($0) }
    }
    return try await withTaskCancellationHandler(operation: {
        for await update in updates {
            try Task<Never, Never>.checkCancellation()
            await progress(update)
        }
        return try await worker.value
    }, onCancel: {
        worker.cancel()
        continuation.finish()
    })
}

nonisolated enum WorkspaceWorkflowError: LocalizedError, Equatable {
    case layerMissing(UUID)
    case planeMissing(UUID)
    case invalidColumns
    case unsupportedSchema(Int)

    var errorDescription: String? {
        switch self {
        case .layerMissing: return "A workflow layer no longer exists in this workspace."
        case .planeMissing: return "A workflow operation requires pixels that are not loaded."
        case .invalidColumns: return "Stitching requires at least one grid column."
        case .unsupportedSchema(let version): return "Workspace schema version \(version) is not supported."
        }
    }
}

actor WorkspaceWorkflowService {
    typealias ProgressHandler = @Sendable (WorkspaceWorkflowProgress) async -> Void

    func execute(_ workflow: WorkspaceWorkflow,
                 context initial: WorkspaceWorkflowContext,
                 progress: ProgressHandler? = nil) async throws -> WorkspaceWorkflowContext {
        var context = initial
        let total = workflow.steps.count
        for (index, step) in workflow.steps.enumerated() {
            try Task.checkCancellation()
            if let progress {
                await progress(.init(completedSteps: index, totalSteps: total, title: step.title))
            }
            context = try await applying(step, to: context, stepIndex: index,
                                         totalSteps: total, progress: progress)
            if index.isMultiple(of: 4) { await Task.yield() }
        }
        if let progress {
            await progress(.init(completedSteps: total, totalSteps: total, title: "Complete"))
        }
        return context
    }

    private func applying(_ step: WorkspaceWorkflowStep,
                          to initial: WorkspaceWorkflowContext,
                          stepIndex: Int,
                          totalSteps: Int,
                          progress: ProgressHandler?) async throws -> WorkspaceWorkflowContext {
        var context = initial
        switch step {
        case .setLayerVisibility(let id, let visible):
            guard let index = context.workspace.layers.firstIndex(where: { $0.id == id }) else {
                throw WorkspaceWorkflowError.layerMissing(id)
            }
            context.workspace.layers[index].isVisible = visible

        case .setLayerOpacity(let id, let opacity):
            guard let index = context.workspace.layers.firstIndex(where: { $0.id == id }) else {
                throw WorkspaceWorkflowError.layerMissing(id)
            }
            context.workspace.layers[index].opacity = min(max(opacity, 0), 1)

        case .translateLayer(let id, let x, let y):
            guard let index = context.workspace.layers.firstIndex(where: { $0.id == id }) else {
                throw WorkspaceWorkflowError.layerMissing(id)
            }
            context.workspace.layers[index].transform = context.workspace.layers[index].transform
                .concatenating(.translation(x: x, y: y))

        case .register(let referenceID, let movingID, let maxShift):
            guard context.workspace.layers.contains(where: { $0.id == referenceID }) else {
                throw WorkspaceWorkflowError.layerMissing(referenceID)
            }
            guard let movingIndex = context.workspace.layers.firstIndex(where: { $0.id == movingID }) else {
                throw WorkspaceWorkflowError.layerMissing(movingID)
            }
            guard let reference = context.planes[referenceID] else {
                throw WorkspaceWorkflowError.planeMissing(referenceID)
            }
            guard let moving = context.planes[movingID] else {
                throw WorkspaceWorkflowError.planeMissing(movingID)
            }
            let result = try await runWorkflowImageKernel(operation: { update in
                try ImageRegistrationService.estimateTranslation(
                    reference: reference, moving: moving, maxShift: maxShift,
                    progress: update)
            }, progress: { update in
                guard let progress else { return }
                await progress(.init(completedSteps: stepIndex, totalSteps: totalSteps,
                                     title: update.phase, stepFraction: update.fraction))
            })
            context.workspace.layers[movingIndex].transform = result.transform

        case .stitch(let layerIDs, let columns, let overlap, let outputName):
            guard columns > 0 else { throw WorkspaceWorkflowError.invalidColumns }
            let planes = try layerIDs.map { id -> WorkspacePixelPlane in
                guard context.workspace.layers.contains(where: { $0.id == id }) else {
                    throw WorkspaceWorkflowError.layerMissing(id)
                }
                guard let plane = context.planes[id] else { throw WorkspaceWorkflowError.planeMissing(id) }
                return plane
            }
            let transforms = ImageRegistrationService.gridTransforms(
                planes: planes, columns: columns, overlapFraction: overlap)
            let tiles = zip(layerIDs, zip(planes, transforms)).map { id, pair in
                WorkspaceTile(id: id, plane: pair.0, transform: pair.1)
            }
            let physicalBudget = Int(min(UInt64(384 * 1_024 * 1_024),
                                         ProcessInfo.processInfo.physicalMemory / 8))
            let stitched = try await runWorkflowImageKernel(operation: { update in
                try ImageRegistrationService.stitch(
                    tiles: tiles, maxOutputPixels: 48_000_000,
                    maxWorkingBytes: max(192 * 1_024 * 1_024, physicalBudget),
                    progress: update)
            }, progress: { update in
                guard let progress else { return }
                await progress(.init(completedSteps: stepIndex, totalSteps: totalSteps,
                                     title: update.phase, stepFraction: update.fraction))
            })
            let axisIDs = context.workspace.layers.first(where: { $0.id == layerIDs.first })?.axisIDs ?? []
            let layer = WorkspaceLayer(
                name: outputName, kind: .image,
                source: .generated(operation: "grid-stitch"), payload: .raster,
                axisIDs: axisIDs,
                metadata: ["columns": String(columns), "overlap": String(overlap)])
            context.workspace.addLayer(layer)
            context.planes[layer.id] = stitched.plane

        case .selectAxis(let axisID, let index):
            context.workspace.updatePosition(axisID: axisID, index: index)
        }
        context.workspace.modifiedAt = Date()
        return context
    }
}

actor WorkspaceWorkflowRecorder {
    private(set) var name: String
    private(set) var steps: [WorkspaceWorkflowStep] = []

    init(name: String = "Recorded workflow") { self.name = name }

    func rename(_ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { name = trimmed }
    }

    func record(_ step: WorkspaceWorkflowStep) { steps.append(step) }
    func undo() -> WorkspaceWorkflowStep? { steps.popLast() }
    func clear() { steps.removeAll(keepingCapacity: true) }
    func snapshot() -> WorkspaceWorkflow { WorkspaceWorkflow(name: name, steps: steps) }
}

nonisolated enum WorkspaceDocumentStore {
    static func save(_ workspace: MicroscopyWorkspace, to url: URL) throws {
        let data = try JSONEncoder.workspace.encode(workspace)
        try data.write(to: url, options: .atomic)
    }

    static func load(from url: URL) throws -> MicroscopyWorkspace {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        let workspace = try JSONDecoder.workspace.decode(MicroscopyWorkspace.self, from: data)
        try validate(workspace)
        return workspace
    }

    static func saveWorkflow(_ workflow: WorkspaceWorkflow, to url: URL) throws {
        try JSONEncoder.workspace.encode(workflow).write(to: url, options: .atomic)
    }

    static func loadWorkflow(from url: URL) throws -> WorkspaceWorkflow {
        try JSONDecoder.workspace.decode(WorkspaceWorkflow.self,
                                         from: Data(contentsOf: url, options: .mappedIfSafe))
    }

    /// Executes JSON coding and file I/O away from the main actor. The compact encoder also
    /// produces materially smaller project files than the human-readable compatibility API.
    static func saveInBackground(_ workspace: MicroscopyWorkspace, to url: URL) async throws {
        try await WorkspaceDocumentStoreActor.shared.saveCompact(workspace, to: url)
    }

    static func loadInBackground(from url: URL) async throws -> MicroscopyWorkspace {
        try await WorkspaceDocumentStoreActor.shared.load(from: url)
    }
}

actor WorkspaceDocumentStoreActor {
    static let shared = WorkspaceDocumentStoreActor()

    func saveCompact(_ workspace: MicroscopyWorkspace, to url: URL) throws {
        try Task<Never, Never>.checkCancellation()
        let data = try JSONEncoder.workspaceCompact.encode(workspace)
        try Task<Never, Never>.checkCancellation()
        try data.write(to: url, options: .atomic)
    }

    func load(from url: URL) throws -> MicroscopyWorkspace {
        try Task<Never, Never>.checkCancellation()
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        try Task<Never, Never>.checkCancellation()
        let workspace = try JSONDecoder.workspace.decode(MicroscopyWorkspace.self, from: data)
        try WorkspaceDocumentStore.validate(workspace)
        return workspace
    }
}

private extension WorkspaceDocumentStore {
    nonisolated static func validate(_ workspace: MicroscopyWorkspace) throws {
        guard workspace.schemaVersion == MicroscopyWorkspace.currentSchemaVersion else {
            throw WorkspaceWorkflowError.unsupportedSchema(workspace.schemaVersion)
        }
        let issues = workspace.validationIssues()
        guard issues.isEmpty else {
            throw CocoaError(.fileReadCorruptFile,
                             userInfo: [NSLocalizedDescriptionKey: issues.joined(separator: "; ")])
        }
    }
}

private extension JSONEncoder {
    nonisolated static var workspace: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    nonisolated static var workspaceCompact: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

private extension JSONDecoder {
    nonisolated static var workspace: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

// MARK: - Train-by-painting export

nonisolated struct WorkspaceTrainingSample: Sendable, Equatable {
    var imageURL: URL
    var labelURL: URL
    var classes: [WorkspaceLabelClass]
}

nonisolated enum WorkspaceTrainingLabelError: LocalizedError, Equatable {
    case emptyDocument
    case dimensionsTooLarge
    case noForeground
    case imageWriteFailed

    var errorDescription: String? {
        switch self {
        case .emptyDocument: return "The training label canvas is empty."
        case .dimensionsTooLarge: return "The training label dimensions exceed safe memory limits."
        case .noForeground: return "Paint at least one foreground class before exporting."
        case .imageWriteFailed: return "The 16-bit training label could not be written."
        }
    }
}

nonisolated struct WorkspaceTrainingLabelEncodingPlan: Sendable, Equatable {
    var pixelCount: Int
    var bytesPerRow: Int
    var providerBytes: Int

    /// The encoder rasterizes directly into the buffer owned by Core Graphics.
    var fullSizeBufferCount: Int { 1 }
}

nonisolated enum WorkspaceTrainingLabelService {
    typealias CancellationCheck = @Sendable () throws -> Void

    nonisolated static func encodingPlan(width: Int, height: Int) throws -> WorkspaceTrainingLabelEncodingPlan {
        guard width > 0, height > 0 else { throw WorkspaceTrainingLabelError.emptyDocument }
        let pixels = width.multipliedReportingOverflow(by: height)
        let rowBytes = width.multipliedReportingOverflow(by: MemoryLayout<UInt16>.stride)
        let providerBytes = pixels.partialValue.multipliedReportingOverflow(
            by: MemoryLayout<UInt16>.stride)
        guard !pixels.overflow, !rowBytes.overflow, !providerBytes.overflow,
              pixels.partialValue <= 268_435_456 else {
            throw WorkspaceTrainingLabelError.dimensionsTooLarge
        }
        return .init(pixelCount: pixels.partialValue, bytesPerRow: rowBytes.partialValue,
                     providerBytes: providerBytes.partialValue)
    }

    nonisolated static func export(document: WorkspacePaintDocument,
                                   sourceImageURL: URL,
                                   labelURL: URL,
                                   position: WorkspacePosition = WorkspacePosition(),
                                   cancellationCheck: CancellationCheck = {
                                       try Task<Never, Never>.checkCancellation()
                                   }) throws -> WorkspaceTrainingSample {
        let plan = try encodingPlan(width: document.width, height: document.height)
        try cancellationCheck()
        let rawBuffer = UnsafeMutableRawPointer.allocate(
            byteCount: plan.providerBytes, alignment: MemoryLayout<UInt16>.alignment)
        rawBuffer.initializeMemory(as: UInt8.self, repeating: 0, count: plan.providerBytes)
        let labels = rawBuffer.bindMemory(to: UInt16.self, capacity: plan.pixelCount)
        var providerOwnsBuffer = false
        defer {
            if !providerOwnsBuffer { rawBuffer.deallocate() }
        }
        try rasterize(document: document, position: position, into: labels,
                      cancellationCheck: cancellationCheck)
        var hasForeground = false
        for index in 0..<plan.pixelCount {
            if index.isMultiple(of: 65_536) { try cancellationCheck() }
            if labels[index] > 0 { hasForeground = true; break }
        }
        guard hasForeground else { throw WorkspaceTrainingLabelError.noForeground }
        guard let provider = CGDataProvider(
            dataInfo: rawBuffer, data: UnsafeRawPointer(rawBuffer), size: plan.providerBytes,
            releaseData: { info, _, _ in info?.deallocate() }) else {
            throw WorkspaceTrainingLabelError.imageWriteFailed
        }
        providerOwnsBuffer = true
        guard let image = CGImage(width: document.width, height: document.height,
                                  bitsPerComponent: 16, bitsPerPixel: 16,
                                  bytesPerRow: plan.bytesPerRow,
                                  space: CGColorSpaceCreateDeviceGray(),
                                  bitmapInfo: [.byteOrder16Little], provider: provider,
                                  decode: nil, shouldInterpolate: false,
                                  intent: .defaultIntent),
              let destination = CGImageDestinationCreateWithURL(
                labelURL as CFURL, UTType.tiff.identifier as CFString, 1, nil) else {
            throw WorkspaceTrainingLabelError.imageWriteFailed
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw WorkspaceTrainingLabelError.imageWriteFailed
        }
        return WorkspaceTrainingSample(imageURL: sourceImageURL,
                                       labelURL: labelURL,
                                       classes: document.classes)
    }

    private nonisolated static func rasterize(
        document: WorkspacePaintDocument,
        position: WorkspacePosition,
        into labels: UnsafeMutablePointer<UInt16>,
        cancellationCheck: CancellationCheck
    ) throws {
        for (strokeIndex, stroke) in document.strokes.enumerated() where stroke.position == position {
            if strokeIndex.isMultiple(of: 8) { try cancellationCheck() }
            let value: UInt16 = (stroke.erases ? 0 : stroke.classValue).littleEndian
            let radius = stroke.radiusPx.isFinite ? max(0.5, stroke.radiusPx) : 0.5
            if stroke.points.count == 1 {
                paintDisk(stroke.points[0], radius: radius, value: value,
                          width: document.width, height: document.height, into: labels)
                continue
            }
            for (segmentIndex, pair) in zip(stroke.points, stroke.points.dropFirst()).enumerated() {
                if segmentIndex.isMultiple(of: 32) { try cancellationCheck() }
                let dx = pair.1.x - pair.0.x
                let dy = pair.1.y - pair.0.y
                guard dx.isFinite, dy.isFinite else { continue }
                let distance = hypot(dx, dy)
                let rawSteps = ceil(distance / max(1, radius * 0.5))
                let dimensionLimit = max(document.width, document.height)
                    .multipliedReportingOverflow(by: 4)
                let maxSteps = max(1, dimensionLimit.overflow ? Int.max : dimensionLimit.partialValue)
                let steps = max(1, rawSteps >= Double(maxSteps) ? maxSteps : Int(rawSteps))
                for step in 0...steps {
                    if step.isMultiple(of: 2_048) { try cancellationCheck() }
                    let t = Double(step) / Double(steps)
                    paintDisk(.init(x: pair.0.x + dx * t, y: pair.0.y + dy * t),
                              radius: radius, value: value,
                              width: document.width, height: document.height, into: labels)
                }
            }
        }
    }

    private nonisolated static func paintDisk(
        _ point: WorkspaceCoordinate, radius: Double, value: UInt16,
        width: Int, height: Int, into labels: UnsafeMutablePointer<UInt16>
    ) {
        guard point.x.isFinite, point.y.isFinite, radius.isFinite else { return }
        let lastX = Double(width - 1)
        let lastY = Double(height - 1)
        let lowX = max(0, min(lastX, floor(point.x - radius)))
        let highX = max(0, min(lastX, ceil(point.x + radius)))
        let lowY = max(0, min(lastY, floor(point.y - radius)))
        let highY = max(0, min(lastY, ceil(point.y + radius)))
        guard point.x + radius >= 0, point.y + radius >= 0,
              point.x - radius <= lastX, point.y - radius <= lastY else { return }
        let minX = Int(lowX), maxX = Int(highX)
        let minY = Int(lowY), maxY = Int(highY)
        let radiusSquared = radius * radius
        for y in minY...maxY {
            for x in minX...maxX {
                let dx = Double(x) + 0.5 - point.x
                let dy = Double(y) + 0.5 - point.y
                if dx * dx + dy * dy <= radiusSquared { labels[y * width + x] = value }
            }
        }
    }
}
