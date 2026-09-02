import Foundation
import AppKit
import ImageIO
import Observation

private nonisolated func runWorkspaceWorker<Value: Sendable>(
    priority: TaskPriority,
    operation: @escaping @Sendable () throws -> Value
) async throws -> Value {
    let worker = Task.detached(priority: priority, operation: operation)
    return try await withTaskCancellationHandler(operation: {
        try await worker.value
    }, onCancel: {
        worker.cancel()
    })
}

private nonisolated func loadWorkspaceRaster(
    at url: URL,
    maxDimension: Int = 2_048
) throws -> (WorkspacePixelPlane, CGImage?) {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(
            source, 0, [kCGImageSourceShouldCache: false] as CFDictionary
          ) else {
        throw ImageLoadError.decodeFailed
    }
    let plane = try ImageRegistrationService.grayscalePlane(
        from: image, maxDimension: maxDimension
    )
    return (plane, plane.makeCGImage())
}

private nonisolated final class WorkspaceProgressThrottle: @unchecked Sendable {
    private let lock = NSLock()
    private var lastUpdate = 0.0

    func publish(_ update: WorkspaceImageProcessingProgress,
                 handler: @escaping @MainActor @Sendable (WorkspaceImageProcessingProgress) -> Void) {
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock()
        let shouldPublish = update.completedUnits >= update.totalUnits || now - lastUpdate >= 0.05
        if shouldPublish { lastUpdate = now }
        lock.unlock()
        guard shouldPublish else { return }
        Task { @MainActor in handler(update) }
    }
}

enum WorkspaceInspectorTab: String, CaseIterable, Identifiable {
    case dataset, align, lineage, labels, workflows, extensions, animation
    var id: String { rawValue }
    var title: String {
        switch self {
        case .dataset: return "Dataset"
        case .align: return "Align"
        case .lineage: return "Lineage"
        case .labels: return "Paint"
        case .workflows: return "Workflow"
        case .extensions: return "Extensions"
        case .animation: return "Animate"
        }
    }
}

@Observable
@MainActor
final class WorkspaceSession {
    private(set) var workspace: MicroscopyWorkspace
    @ObservationIgnored private(set) var planes: [UUID: WorkspacePixelPlane] = [:]
    private(set) var displayImages: [UUID: NSImage] = [:]
    @ObservationIgnored private(set) var sourceURLs: [UUID: URL] = [:]
    @ObservationIgnored private var zarrArrays: [UUID: OMEZarrArrayDescriptor] = [:]
    private(set) var extensions: [WorkspaceExtensionDescriptor] = []

    @ObservationIgnored private var activeOperationTask: Task<Void, Never>?
    @ObservationIgnored private var planeLoadTask: Task<Void, Never>?
    @ObservationIgnored private var residentOrder: [UUID] = []
    @ObservationIgnored private var residentByteCosts: [UUID: Int] = [:]
    @ObservationIgnored private var residentBytes = 0
    private let residentByteBudget = 192 * 1_024 * 1_024

    var selectedLayerID: UUID?
    var selectedLineageNodeIDs: Set<UUID> = []
    var inspectorTab: WorkspaceInspectorTab = .dataset
    var isBusy = false
    var progress: Double = 0
    var statusMessage = "Open images, a CellCounter batch, or a local OME-Zarr dataset."
    var errorMessage: String?

    var isRecording = false
    var recordedSteps: [WorkspaceWorkflowStep] = []
    var paintClassValue: UInt16 = 1
    var paintRadius: Double = 12
    var paintErases = false

    init() {
        let y = WorkspaceAxis(name: "y", kind: .y, length: 1, unit: "pixel")
        let x = WorkspaceAxis(name: "x", kind: .x, length: 1, unit: "pixel")
        workspace = MicroscopyWorkspace(name: "Untitled workspace", axes: [y, x])
        Task { await loadExtensions() }
    }

    var selectedLayer: WorkspaceLayer? {
        workspace.layers.first { $0.id == selectedLayerID }
    }

    var rasterLayers: [WorkspaceLayer] {
        workspace.layers.filter { $0.kind == .image && $0.metadata["frame"] == nil }
    }

    var visibleImageLayers: [WorkspaceLayer] {
        let timeIndex = workspace.axes.first(where: { $0.kind == .time })
            .map { workspace.position[$0.id] }
        return workspace.layers.filter { layer in
            guard layer.kind == .image, layer.isVisible else { return false }
            guard let frame = layer.metadata["frame"].flatMap(Int.init) else { return true }
            guard let timeIndex else { return true }
            return frame == timeIndex
        }
    }

    var activeImage: NSImage? {
        guard let selectedLayerID else { return nil }
        return displayImages[selectedLayerID]
    }

    func reset(name: String = "Untitled workspace", cancelOperations: Bool = true) {
        if cancelOperations {
            activeOperationTask?.cancel()
            planeLoadTask?.cancel()
        }
        let y = WorkspaceAxis(name: "y", kind: .y, length: 1, unit: "pixel")
        let x = WorkspaceAxis(name: "x", kind: .x, length: 1, unit: "pixel")
        workspace = MicroscopyWorkspace(name: name, axes: [y, x])
        planes.removeAll(keepingCapacity: false)
        displayImages.removeAll(keepingCapacity: false)
        sourceURLs.removeAll(keepingCapacity: false)
        zarrArrays.removeAll(keepingCapacity: false)
        residentOrder.removeAll(keepingCapacity: false)
        residentByteCosts.removeAll(keepingCapacity: false)
        residentBytes = 0
        selectedLayerID = nil
        selectedLineageNodeIDs.removeAll()
        recordedSteps.removeAll()
        statusMessage = "New workspace"
        errorMessage = nil
    }

    func importImages(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        begin("Loading \(urls.count) image\(urls.count == 1 ? "" : "s")…")
        activeOperationTask?.cancel()
        activeOperationTask = Task {
            do {
                if urls.count > 8 {
                    let first = try await runWorkspaceWorker(priority: .userInitiated) {
                        guard let url = urls.first else { throw CancellationError() }
                        return try loadWorkspaceRaster(at: url, maxDimension: 1_536)
                    }
                    reset(name: urls.first?.deletingPathExtension().lastPathComponent ?? "Image sequence",
                          cancelOperations: false)
                    integrateFrameSources(urls, initialPlane: first.0, preparedImage: first.1)
                    finish("Loaded a bounded preview for \(urls.count) image frames.")
                } else {
                    let payloads = try await runWorkspaceWorker(priority: .userInitiated) {
                        try urls.map { url -> (URL, WorkspacePixelPlane, CGImage?) in
                            try Task.checkCancellation()
                            let prepared = try loadWorkspaceRaster(at: url)
                            return (url, prepared.0, prepared.1)
                        }
                    }
                    integrateImages(payloads)
                    finish("Loaded \(payloads.count) local image\(payloads.count == 1 ? "" : "s").")
                }
            } catch { fail(error) }
        }
    }

    func importCurrentBatch(state: AppState) {
        guard let batch = state.currentBatch else {
            errorMessage = "Open a CellCounter batch first."
            return
        }
        let images = state.orderedImages(in: batch)
        guard !images.isEmpty else { errorMessage = "The current batch contains no images."; return }
        begin("Building workspace from \(images.count) batch images…")
        activeOperationTask?.cancel()
        activeOperationTask = Task {
            var frames: [[DetectedCell]] = []
            var initialPlane: (WorkspacePixelPlane, CGImage?)?
            do {
                for (index, image) in images.enumerated() {
                    try Task.checkCancellation()
                    if initialPlane == nil, let loaded = ImageLoader.loadStored(image) {
                        initialPlane = try await runWorkspaceWorker(priority: .userInitiated) {
                            let plane = try ImageRegistrationService.grayscalePlane(from: loaded.cgImage,
                                                                                    maxDimension: 1_536)
                            return (plane, plane.makeCGImage())
                        }
                    }
                    if let detection = image.detection { frames.append(await state.loadCells(for: detection)) }
                    else { frames.append([]) }
                    progress = Double(index + 1) / Double(images.count)
                    await Task.yield()
                }
                reset(name: batch.displayName, cancelOperations: false)
                guard let initialPlane else { throw ImageRegistrationError.invalidPlane }
                integrateFrameSources(images.map(\.displayURL), initialPlane: initialPlane.0,
                                      preparedImage: initialPlane.1)
                importDetections(frames: frames)
                if lineageFrames().count >= 2 {
                    try await rebuildLineage(maxDistancePx: 80)
                }
                finish("Workspace created from “\(batch.displayName)”.")
            } catch { fail(error) }
        }
    }

    func openOMEZarr(_ rootURL: URL) {
        begin("Reading OME-Zarr metadata…")
        activeOperationTask?.cancel()
        activeOperationTask = Task {
            do {
                let dataset = try await OMEZarrService.shared.inspect(rootURL: rootURL)
                guard let base = dataset.arrays.first else {
                    throw OMEZarrError.malformedMetadata("no multiscale arrays")
                }
                let previewArray = try OMEZarrService.arrayForViewport(
                    in: dataset, viewportSize: CGSize(width: 1_200, height: 900),
                    backingScaleFactor: 2)
                let previewIndex = dataset.arrays.firstIndex(where: { $0.id == previewArray.id }) ?? 0
                let axes = zip(base.axes, base.shape).map { descriptor, length in
                    WorkspaceAxis(name: descriptor.name, kind: descriptor.kind,
                                  length: length, unit: descriptor.unit,
                                  scale: descriptor.scale)
                }
                reset(name: dataset.name, cancelOperations: false)
                workspace.axes = axes
                workspace.position = WorkspacePosition().clamped(to: axes)
                workspace.plate = dataset.plate
                for (level, array) in dataset.arrays.enumerated() {
                    let layer = WorkspaceLayer(
                        name: level == 0 ? dataset.name : "\(dataset.name) · level \(level)",
                        kind: .image,
                        source: .omeZarr(rootName: rootURL.lastPathComponent,
                                         arrayPath: array.path, level: level),
                        payload: .raster, axisIDs: axes.map(\.id),
                        isVisible: level == previewIndex,
                        metadata: [
                            "shape": array.shape.map(String.init).joined(separator: " × "),
                            "chunks": array.chunks.map(String.init).joined(separator: " × "),
                            "dtype": array.dataType,
                            "codec": array.compressorID ?? "none",
                        ])
                    workspace.addLayer(layer)
                    zarrArrays[layer.id] = array
                    if level == previewIndex {
                        let fixed = Dictionary(uniqueKeysWithValues: axes.map { ($0.name, 0) })
                        let plane = try await OMEZarrService.shared.readPlane(array: array,
                                                                             fixedIndices: fixed)
                        let workspacePlane = WorkspacePixelPlane(width: plane.width,
                                                                 height: plane.height,
                                                                 pixels: plane.pixels)
                        let prepared = try await runWorkspaceWorker(priority: .utility) {
                            workspacePlane.makeCGImage()
                        }
                        storePlane(workspacePlane, for: layer.id, preparedImage: prepared)
                        selectedLayerID = layer.id
                    }
                    sourceURLs[layer.id] = rootURL
                }
                if selectedLayerID == nil { selectedLayerID = workspace.layers.first?.id }
                finish(dataset.plate == nil
                       ? "Opened \(dataset.arrays.count)-level OME-Zarr dataset."
                       : "Opened OME-Zarr plate with \(dataset.plate?.wells.count ?? 0) wells.")
            } catch { fail(error) }
        }
    }

    func selectLayer(_ id: UUID) {
        selectedLayerID = id
        if displayImages[id] == nil { schedulePlaneLoad(preferredLayerID: id) }
    }

    func setLayerVisibility(_ id: UUID, visible: Bool) {
        guard let index = workspace.layers.firstIndex(where: { $0.id == id }) else { return }
        workspace.layers[index].isVisible = visible
        record(.setLayerVisibility(id: id, visible: visible))
        if visible, displayImages[id] == nil { schedulePlaneLoad(preferredLayerID: id) }
    }

    func setLayerOpacity(_ id: UUID, opacity: Double) {
        guard let index = workspace.layers.firstIndex(where: { $0.id == id }) else { return }
        workspace.layers[index].opacity = min(max(opacity, 0), 1)
        record(.setLayerOpacity(id: id, opacity: opacity))
    }

    func updateAxis(_ axisID: UUID, value: Int) {
        workspace.updatePosition(axisID: axisID, index: value)
        if workspace.axes.first(where: { $0.id == axisID })?.kind == .time,
           let frameLayer = workspace.layers.first(where: {
               $0.kind == .image && $0.metadata["frame"].flatMap(Int.init) == value
           }) {
            selectedLayerID = frameLayer.id
        }
        record(.selectAxis(axisID: axisID, index: value))
        schedulePlaneLoad()
    }

    func registerFirstPair(maxShift: Int = 96) {
        guard rasterLayers.count >= 2 else { errorMessage = "Load at least two raster layers."; return }
        let reference = rasterLayers[0]
        let moving = rasterLayers[1]
        begin("Registering \(moving.name) to \(reference.name)…")
        activeOperationTask?.cancel()
        let progressSink = WorkspaceProgressThrottle()
        activeOperationTask = Task {
            do {
                let referencePlane = try await operationPlane(for: reference)
                let movingPlane = try await operationPlane(for: moving)
                let result = try await runWorkspaceWorker(priority: .userInitiated) {
                    try ImageRegistrationService.estimateTranslation(reference: referencePlane,
                                                                     moving: movingPlane,
                                                                     maxShift: maxShift,
                                                                     progress: { [weak self] update in
                        progressSink.publish(update) { [weak self] update in
                            self?.progress = update.fraction
                            self?.statusMessage = update.phase
                        }
                    })
                }
                if let index = workspace.layers.firstIndex(where: { $0.id == moving.id }) {
                    workspace.layers[index].transform = result.transform
                    workspace.layers[index].metadata["registration-score"] = String(format: "%.4f", result.score)
                }
                record(.register(referenceID: reference.id, movingID: moving.id, maxShift: maxShift))
                finish("Registered with correlation \(String(format: "%.3f", result.score)).")
            } catch { fail(error) }
        }
    }

    func stitchAll(columns: Int, overlap: Double) {
        let layers = rasterLayers
        guard layers.count >= 2 else { errorMessage = "Load at least two raster layers."; return }
        begin("Stitching \(layers.count) layers…")
        activeOperationTask?.cancel()
        let progressSink = WorkspaceProgressThrottle()
        let physicalBudget = Int(min(ProcessInfo.processInfo.physicalMemory / 8,
                                     UInt64(384 * 1_024 * 1_024)))
        activeOperationTask = Task {
            do {
                var sourcePlanes: [WorkspacePixelPlane] = []
                sourcePlanes.reserveCapacity(layers.count)
                for (index, layer) in layers.enumerated() {
                    try Task.checkCancellation()
                    sourcePlanes.append(try await operationPlane(for: layer))
                    progress = 0.15 * Double(index + 1) / Double(layers.count)
                }
                let stitchPlanes = sourcePlanes
                let prepared = try await runWorkspaceWorker(priority: .userInitiated) {
                    let transforms = ImageRegistrationService.gridTransforms(
                        planes: stitchPlanes, columns: columns, overlapFraction: overlap)
                    let tiles = zip(layers, zip(stitchPlanes, transforms)).map { layer, pair in
                        WorkspaceTile(id: layer.id, plane: pair.0, transform: pair.1)
                    }
                    let result = try ImageRegistrationService.stitch(
                        tiles: tiles, maxOutputPixels: 48_000_000,
                        maxWorkingBytes: max(192 * 1_024 * 1_024, physicalBudget),
                        progress: { [weak self] update in
                            progressSink.publish(update) { [weak self] update in
                                self?.progress = 0.15 + 0.8 * update.fraction
                                self?.statusMessage = update.phase
                            }
                        })
                    return (result, result.plane.makeCGImage())
                }
                let result = prepared.0
                let layer = WorkspaceLayer(
                    name: "Stitched mosaic", kind: .image,
                    source: .generated(operation: "grid-stitch"), payload: .raster,
                    axisIDs: workspace.axes.filter { $0.kind == .x || $0.kind == .y }.map(\.id),
                    metadata: ["tiles": String(layers.count), "columns": String(columns)])
                workspace.addLayer(layer)
                storePlane(result.plane, for: layer.id, preparedImage: prepared.1)
                selectedLayerID = layer.id
                record(.stitch(layerIDs: layers.map(\.id), columns: columns,
                               overlap: overlap, outputName: layer.name))
                finish("Created \(result.plane.width) × \(result.plane.height) mosaic.")
            } catch { fail(error) }
        }
    }

    func buildLineage(maxDistancePx: Double) {
        guard lineageFrames().count >= 2 else {
            errorMessage = "Lineage building needs points from at least two frames."
            return
        }
        begin("Building lineages…")
        activeOperationTask?.cancel()
        activeOperationTask = Task {
            do {
                try await rebuildLineage(maxDistancePx: maxDistancePx)
                finish("Built \(workspace.lineage.edges.count) lineage links.")
            } catch { fail(error) }
        }
    }

    private func lineageFrames() -> [WorkspaceLineageFrame] {
        workspace.layers.compactMap { layer -> WorkspaceLineageFrame? in
            guard case .points(let points) = layer.payload,
                  let frame = layer.metadata["frame"].flatMap(Int.init) else { return nil }
            return WorkspaceLineageFrame(frame: frame, points: points)
        }.sorted { $0.frame < $1.frame }
    }

    private func rebuildLineage(maxDistancePx: Double) async throws {
        let frames = lineageFrames()
        guard frames.count >= 2 else { return }
        let result = try await WorkspaceLineageService.build(
            frames: frames, maxDistancePixels: maxDistancePx) { update in
                await self.applyLineageProgress(update)
            }
        workspace.lineage = result.graph
        selectedLineageNodeIDs.removeAll()
        errorMessage = nil
    }

    func toggleLineageNode(_ id: UUID) {
        if selectedLineageNodeIDs.contains(id) { selectedLineageNodeIDs.remove(id) }
        else if selectedLineageNodeIDs.count < 2 { selectedLineageNodeIDs.insert(id) }
    }

    func linkSelected(kind: WorkspaceLineageEdgeKind) {
        let selected = workspace.lineage.nodes.filter { selectedLineageNodeIDs.contains($0.id) }
            .sorted { $0.frame < $1.frame }
        guard selected.count == 2 else { errorMessage = "Select exactly two observations."; return }
        do {
            try workspace.lineage.link(parentID: selected[0].id, childID: selected[1].id, kind: kind)
            selectedLineageNodeIDs.removeAll()
            statusMessage = "Added \(kind.rawValue) lineage link."
            errorMessage = nil
        } catch { failWithoutStopping(error) }
    }

    func unlink(_ edgeID: UUID) { workspace.lineage.unlink(edgeID: edgeID) }

    func ensurePaintDocument(for layerID: UUID, width: Int, height: Int) {
        guard workspace.paintDocuments[layerID] == nil else { return }
        workspace.paintDocuments[layerID] = WorkspacePaintDocument(
            width: width, height: height,
            classes: [
                WorkspaceLabelClass(value: 1, name: "Cell", colorHex: "#00D7FF"),
                WorkspaceLabelClass(value: 2, name: "Background", colorHex: "#FFB020"),
            ])
    }

    func appendPaintStroke(layerID: UUID, points: [WorkspaceCoordinate]) {
        guard !points.isEmpty, workspace.paintDocuments[layerID] != nil else { return }
        let stroke = WorkspacePaintStroke(classValue: paintClassValue,
                                          radiusPx: paintRadius,
                                          points: points,
                                          position: workspace.position,
                                          erases: paintErases)
        workspace.paintDocuments[layerID]?.append(stroke)
    }

    func undoPaint(layerID: UUID) {
        _ = workspace.paintDocuments[layerID]?.undo()
    }

    func exportTrainingLabel(layerID: UUID, to url: URL) {
        guard let document = workspace.paintDocuments[layerID],
              let source = sourceURLs[layerID] else {
            errorMessage = "Select a local image layer with painted labels."
            return
        }
        let position = workspace.position
        begin("Exporting 16-bit training labels…")
        activeOperationTask?.cancel()
        activeOperationTask = Task {
            do {
                _ = try await runWorkspaceWorker(priority: .utility) {
                    try WorkspaceTrainingLabelService.export(document: document,
                                                             sourceImageURL: source,
                                                             labelURL: url,
                                                             position: position)
                }
                finish("Saved 16-bit training labels to \(url.lastPathComponent).")
            } catch { fail(error) }
        }
    }

    func toggleRecording() {
        isRecording.toggle()
        if isRecording { recordedSteps.removeAll(keepingCapacity: true) }
    }

    func saveRecording(name: String) {
        guard !recordedSteps.isEmpty else { errorMessage = "Record at least one workspace action."; return }
        workspace.workflows.append(WorkspaceWorkflow(name: name, steps: recordedSteps))
        isRecording = false
        statusMessage = "Saved workflow with \(recordedSteps.count) steps."
    }

    func runWorkflow(_ workflow: WorkspaceWorkflow) {
        begin("Running \(workflow.name)…")
        let context = WorkspaceWorkflowContext(workspace: workspace, planes: planes)
        activeOperationTask?.cancel()
        activeOperationTask = Task {
            do {
                let result = try await WorkspaceWorkflowService().execute(workflow, context: context) {
                    update in
                    await self.applyWorkflowProgress(update)
                }
                workspace = result.workspace
                planes = result.planes
                rebuildDisplayImages()
                finish("Completed \(workflow.name).")
            } catch { fail(error) }
        }
    }

    private func applyLineageProgress(_ update: WorkspaceLineageBuildProgress) {
        progress = update.totalTransitions > 0
            ? Double(update.completedTransitions) / Double(update.totalTransitions) : 1
        statusMessage = "Linking frame \(update.completedTransitions) of \(update.totalTransitions)…"
    }

    private func applyWorkflowProgress(_ update: WorkspaceWorkflowProgress) {
        progress = update.fraction
        statusMessage = update.title
    }

    func saveWorkspace(to url: URL) {
        let snapshot = workspace
        begin("Saving workspace…")
        activeOperationTask?.cancel()
        activeOperationTask = Task {
            do {
                try await WorkspaceDocumentStore.saveInBackground(snapshot, to: url)
                finish("Saved \(url.lastPathComponent).")
            } catch { fail(error) }
        }
    }

    func loadWorkspace(from url: URL) {
        begin("Opening workspace…")
        activeOperationTask?.cancel()
        activeOperationTask = Task {
            do {
                let loaded = try await WorkspaceDocumentStore.loadInBackground(from: url)
                workspace = loaded
                planes.removeAll(); displayImages.removeAll(); sourceURLs.removeAll()
                zarrArrays.removeAll(); residentOrder.removeAll(); residentByteCosts.removeAll()
                residentBytes = 0
                selectedLayerID = workspace.layers.first?.id
                finish("Opened \(url.lastPathComponent). Relink external image layers to display pixels.")
            } catch { fail(error) }
        }
    }

    func makeAnimationPlan(duration: Double = 3, fps: Int = 12) throws -> WorkspaceAnimationPlan {
        let visible = Set(workspace.layers.filter(\.isVisible).map(\.id))
        let first = WorkspaceAnimationKeyframe(timeSeconds: 0, position: workspace.position,
                                               zoom: 1, visibleLayerIDs: visible)
        var endPosition = workspace.position
        for axis in workspace.axes where axis.kind == .time || axis.kind == .z {
            endPosition[axis.id] = axis.length - 1
        }
        let last = WorkspaceAnimationKeyframe(timeSeconds: max(0.1, duration),
                                              position: endPosition, zoom: 1.15,
                                              visibleLayerIDs: visible)
        let plan = WorkspaceAnimationPlan(name: "Workspace animation",
                                          framesPerSecond: fps,
                                          keyframes: [first, last])
        _ = try WorkspaceAnimationService.frameStates(for: plan)
        return plan
    }

    func addAnimationPlan(_ plan: WorkspaceAnimationPlan) {
        workspace.animationPlans.append(plan)
        statusMessage = "Added \(plan.keyframes.count)-keyframe animation plan."
        errorMessage = nil
    }

    func exportRasterSequenceGIF(to url: URL, fps: Int) {
        let urls = workspace.layers.filter { $0.kind == .image }
            .compactMap { sourceURLs[$0.id] }
            .filter { !$0.hasDirectoryPath }
        guard urls.count >= 2 else { errorMessage = "Load at least two local image frames."; return }
        begin("Exporting \(urls.count)-frame GIF…")
        activeOperationTask?.cancel()
        activeOperationTask = Task {
            do {
                try await runWorkspaceWorker(priority: .utility) {
                    try WorkspaceAnimationService.exportGIF(imageURLs: urls,
                                                            outputURL: url,
                                                            framesPerSecond: fps)
                }
                finish("Saved animation to \(url.lastPathComponent).")
            } catch { fail(error) }
        }
    }

    private func importDetections(frames: [[DetectedCell]]) {
        let timeAxis: WorkspaceAxis
        if let existing = workspace.axes.first(where: { $0.kind == .time }) { timeAxis = existing }
        else {
            timeAxis = WorkspaceAxis(name: "t", kind: .time, length: max(1, frames.count), unit: "frame")
            workspace.axes.insert(timeAxis, at: 0)
        }
        for (frame, cells) in frames.enumerated() {
            let points = cells.map { cell in
                WorkspacePoint(id: cell.id,
                               coordinate: WorkspaceCoordinate(x: cell.cx, y: cell.cy),
                               position: WorkspacePosition(indices: [timeAxis.id: frame]),
                               label: "Cell", features: [
                                "diameter": cell.diameter,
                                "confidence": cell.confidence,
                               ])
            }
            let layer = WorkspaceLayer(name: "Cells · frame \(frame + 1)", kind: .points,
                                       source: .generated(operation: "CellCounter detections"),
                                       payload: .points(points), axisIDs: workspace.axes.map(\.id),
                                       metadata: ["frame": String(frame)])
            workspace.addLayer(layer)
        }
    }

    private func integrateImages(_ payloads: [(URL, WorkspacePixelPlane, CGImage?)],
                                 frameIndexed: Bool = false) {
        guard !payloads.isEmpty else { return }
        if workspace.layers.isEmpty {
            let maxWidth = payloads.map { $0.1.width }.max() ?? 1
            let maxHeight = payloads.map { $0.1.height }.max() ?? 1
            var axes: [WorkspaceAxis] = []
            if frameIndexed && payloads.count > 1 {
                axes.append(WorkspaceAxis(name: "t", kind: .time,
                                          length: payloads.count, unit: "frame"))
            }
            axes.append(WorkspaceAxis(name: "y", kind: .y, length: maxHeight, unit: "pixel"))
            axes.append(WorkspaceAxis(name: "x", kind: .x, length: maxWidth, unit: "pixel"))
            workspace.axes = axes
        }
        let timeAxis = workspace.axes.first(where: { $0.kind == .time })
        for (index, payload) in payloads.enumerated() {
            var metadata = ["width": String(payload.1.width), "height": String(payload.1.height)]
            if frameIndexed { metadata["frame"] = String(index) }
            let layer = WorkspaceLayer(
                name: payload.0.deletingPathExtension().lastPathComponent,
                kind: .image,
                source: .localFile(bookmarkID: nil, displayName: payload.0.lastPathComponent),
                payload: .raster, axisIDs: workspace.axes.map(\.id),
                metadata: metadata)
            workspace.addLayer(layer)
            sourceURLs[layer.id] = payload.0
            storePlane(payload.1, for: layer.id, preparedImage: payload.2)
            if let timeAxis, frameIndexed { workspace.position[timeAxis.id] = index }
            if selectedLayerID == nil { selectedLayerID = layer.id }
        }
        workspace.position = workspace.position.clamped(to: workspace.axes)
    }

    private func integrateFrameSources(_ urls: [URL], initialPlane: WorkspacePixelPlane,
                                       preparedImage: CGImage? = nil) {
        guard !urls.isEmpty else { return }
        let time = WorkspaceAxis(name: "t", kind: .time, length: urls.count, unit: "frame")
        let y = WorkspaceAxis(name: "y", kind: .y, length: initialPlane.height, unit: "pixel")
        let x = WorkspaceAxis(name: "x", kind: .x, length: initialPlane.width, unit: "pixel")
        workspace.axes = [time, y, x]
        workspace.position = WorkspacePosition(indices: [time.id: 0])
        for (index, url) in urls.enumerated() {
            let layer = WorkspaceLayer(
                name: url.deletingPathExtension().lastPathComponent,
                kind: .image,
                source: .localFile(bookmarkID: nil, displayName: url.lastPathComponent),
                payload: .raster, axisIDs: [time.id, y.id, x.id],
                metadata: ["frame": String(index)])
            workspace.addLayer(layer)
            sourceURLs[layer.id] = url
            if index == 0 { storePlane(initialPlane, for: layer.id, preparedImage: preparedImage) }
            if selectedLayerID == nil { selectedLayerID = layer.id }
        }
        schedulePlaneLoad()
    }

    private func schedulePlaneLoad(preferredLayerID: UUID? = nil) {
        planeLoadTask?.cancel()
        let position = workspace.position
        let axes = workspace.axes
        let layers = workspace.layers
        let urls = sourceURLs
        let arrays = zarrArrays
        planeLoadTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(80))
                try Task.checkCancellation()
                let timeAxis = axes.first(where: { $0.kind == .time })
                let currentFrame = timeAxis.map { position[$0.id] }
                var candidates = layers.filter { layer in
                    guard layer.kind == .image else { return false }
                    if layer.id == preferredLayerID { return true }
                    guard let frame = layer.metadata["frame"].flatMap(Int.init),
                          let currentFrame else { return layer.isVisible }
                    return abs(frame - currentFrame) <= 1
                }
                candidates.sort { lhs, rhs in
                    if lhs.id == preferredLayerID { return true }
                    if rhs.id == preferredLayerID { return false }
                    let left = lhs.metadata["frame"].flatMap(Int.init) ?? currentFrame ?? 0
                    let right = rhs.metadata["frame"].flatMap(Int.init) ?? currentFrame ?? 0
                    return abs(left - (currentFrame ?? 0)) < abs(right - (currentFrame ?? 0))
                }
                for layer in candidates.prefix(5) {
                    try Task.checkCancellation()
                    if let array = arrays[layer.id] {
                        var fixed: [String: Int] = [:]
                        for (index, descriptor) in array.axes.enumerated() {
                            guard descriptor.kind != .x, descriptor.kind != .y,
                                  axes.indices.contains(index) else { continue }
                            fixed[descriptor.name] = position[axes[index].id]
                        }
                        let decoded = try await OMEZarrService.shared.readPlane(array: array,
                                                                                fixedIndices: fixed)
                        let plane = WorkspacePixelPlane(width: decoded.width, height: decoded.height,
                                                        pixels: decoded.pixels)
                        let image = try await runWorkspaceWorker(priority: .utility) { plane.makeCGImage() }
                        self?.storePlane(plane, for: layer.id, preparedImage: image)
                        let spatialPixels = zip(array.shape, array.axes).reduce(1) { partial, pair in
                            guard partial != Int.max,
                                  pair.1.kind == .x || pair.1.kind == .y else { return partial }
                            let next = partial.multipliedReportingOverflow(by: pair.0)
                            return next.overflow ? Int.max : next.partialValue
                        }
                        if spatialPixels <= 4_000_000,
                           let neighborAxis = array.axes.indices.first(where: {
                            array.axes[$0].kind == .time || array.axes[$0].kind == .z
                        }), axes.indices.contains(neighborAxis) {
                            let descriptor = array.axes[neighborAxis]
                            let current = fixed[descriptor.name, default: 0]
                            for neighbor in [current - 1, current + 1]
                            where neighbor >= 0 && neighbor < array.shape[neighborAxis] {
                                try Task.checkCancellation()
                                var neighborIndices = fixed
                                neighborIndices[descriptor.name] = neighbor
                                _ = try await OMEZarrService.shared.readPlane(
                                    array: array, fixedIndices: neighborIndices)
                            }
                        }
                    } else if let url = urls[layer.id], !url.hasDirectoryPath {
                        let prepared = try await runWorkspaceWorker(priority: .userInitiated) {
                            try loadWorkspaceRaster(at: url, maxDimension: 1_536)
                        }
                        self?.storePlane(prepared.0, for: layer.id, preparedImage: prepared.1)
                    }
                }
            } catch is CancellationError {
                return
            } catch {
                self?.failWithoutStopping(error)
            }
        }
    }

    private func operationPlane(for layer: WorkspaceLayer) async throws -> WorkspacePixelPlane {
        if let cached = planes[layer.id] { return cached }
        if let array = zarrArrays[layer.id] {
            var fixed: [String: Int] = [:]
            for (index, descriptor) in array.axes.enumerated() {
                guard descriptor.kind != .x, descriptor.kind != .y,
                      workspace.axes.indices.contains(index) else { continue }
                fixed[descriptor.name] = workspace.position[workspace.axes[index].id]
            }
            let decoded = try await OMEZarrService.shared.readPlane(array: array,
                                                                    fixedIndices: fixed)
            let plane = WorkspacePixelPlane(width: decoded.width, height: decoded.height,
                                            pixels: decoded.pixels)
            let image = try await runWorkspaceWorker(priority: .utility) { plane.makeCGImage() }
            storePlane(plane, for: layer.id, preparedImage: image)
            return plane
        }
        guard let url = sourceURLs[layer.id], !url.hasDirectoryPath else {
            throw WorkspaceWorkflowError.planeMissing(layer.id)
        }
        let prepared = try await runWorkspaceWorker(priority: .userInitiated) {
            try loadWorkspaceRaster(at: url, maxDimension: 2_048)
        }
        storePlane(prepared.0, for: layer.id, preparedImage: prepared.1)
        return prepared.0
    }

    private func storePlane(_ plane: WorkspacePixelPlane, for id: UUID,
                            preparedImage: CGImage? = nil) {
        let cost = plane.pixels.count * MemoryLayout<Float>.stride + plane.width * plane.height
        if let prior = residentByteCosts[id] { residentBytes -= prior }
        planes[id] = plane
        if let image = preparedImage ?? plane.makeCGImage() {
            displayImages[id] = NSImage(cgImage: image,
                                        size: NSSize(width: image.width, height: image.height))
        }
        residentByteCosts[id] = cost
        residentBytes += cost
        residentOrder.removeAll { $0 == id }
        residentOrder.append(id)
        trimResidentPlanes(keeping: id)
    }

    private func trimResidentPlanes(keeping protectedID: UUID? = nil) {
        var deferred: [UUID] = []
        while residentBytes > residentByteBudget, !residentOrder.isEmpty {
            let id = residentOrder.removeFirst()
            if id == protectedID {
                deferred.append(id)
                if residentOrder.isEmpty { break }
                continue
            }
            residentBytes -= residentByteCosts.removeValue(forKey: id) ?? 0
            planes[id] = nil
            displayImages[id] = nil
        }
        residentOrder.append(contentsOf: deferred)
    }

    private func rebuildDisplayImages() {
        for (id, plane) in planes where displayImages[id] == nil {
            if let image = plane.makeCGImage() {
                displayImages[id] = NSImage(cgImage: image,
                                            size: NSSize(width: image.width, height: image.height))
            }
        }
    }

    private func loadExtensions() async {
        extensions = await WorkspaceExtensionRegistry.shared.all()
    }

    func cancelCurrentWork() {
        activeOperationTask?.cancel()
        planeLoadTask?.cancel()
        activeOperationTask = nil
        planeLoadTask = nil
        isBusy = false
        progress = 0
        statusMessage = "Cancelled."
    }

    private func record(_ step: WorkspaceWorkflowStep) {
        if isRecording { recordedSteps.append(step) }
    }

    private func begin(_ message: String) {
        isBusy = true; progress = 0; statusMessage = message; errorMessage = nil
    }

    private func finish(_ message: String) {
        isBusy = false; progress = 1; statusMessage = message; errorMessage = nil
    }

    private func fail(_ error: Error) {
        if error is CancellationError {
            isBusy = false
            progress = 0
            statusMessage = "Cancelled."
            errorMessage = nil
            return
        }
        isBusy = false; progress = 0; errorMessage = error.localizedDescription
    }

    private func failWithoutStopping(_ error: Error) { errorMessage = error.localizedDescription }
}
