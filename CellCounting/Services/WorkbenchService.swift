import AppKit
import Foundation
import Observation

/// The native client carries the same request envelope as the CLI and MCP.
/// Project persistence and numerical operations belong to the shared runtime.
nonisolated enum WorkbenchJSON: Codable, Sendable, Equatable {
    case object([String: WorkbenchJSON]), array([WorkbenchJSON]), string(String)
    case number(Double), bool(Bool), null

    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        if value.decodeNil() { self = .null }
        else if let object = try? value.decode([String: WorkbenchJSON].self) { self = .object(object) }
        else if let array = try? value.decode([WorkbenchJSON].self) { self = .array(array) }
        else if let string = try? value.decode(String.self) { self = .string(string) }
        else if let bool = try? value.decode(Bool.self) { self = .bool(bool) }
        else { self = .number(try value.decode(Double.self)) }
    }

    func encode(to encoder: Encoder) throws {
        var value = encoder.singleValueContainer()
        switch self {
        case .object(let object): try value.encode(object)
        case .array(let array): try value.encode(array)
        case .string(let string): try value.encode(string)
        case .number(let number): try value.encode(number)
        case .bool(let bool): try value.encode(bool)
        case .null: try value.encodeNil()
        }
    }

    subscript(key: String) -> WorkbenchJSON {
        if case .object(let object) = self { return object[key] ?? .null }
        return .null
    }
    var string: String? { if case .string(let value) = self { return value }; return nil }
    var number: Double? { if case .number(let value) = self { return value }; return nil }
    var array: [WorkbenchJSON] { if case .array(let value) = self { return value }; return [] }
    var object: [String: WorkbenchJSON] { if case .object(let value) = self { return value }; return [:] }
    var bool: Bool? { if case .bool(let value) = self { return value }; return nil }
    var integer: Int? {
        guard let value = number, value.isFinite,
              value.rounded() == value, value >= Double(Int.min), value < Double(Int.max) else { return nil }
        return Int(value)
    }
}

nonisolated struct WorkbenchImage: Identifiable, Sendable {
    let id: String
    let name: String
    let width: Int
    let height: Int
    let channels: Int
    let zCount: Int
    let timeCount: Int
    let volumeFrameCount: Int
    let referenceCurrent: Bool
    let sourceHash: String
    let intensityUnits: String
    let variantOf: String?
    let preferredSourceParameters: WorkbenchJSON
    let preferredVolumeSelection: WorkbenchJSON
    let lineages: [WorkbenchJSON]
    let registration: WorkbenchJSON
    let validSupport: WorkbenchJSON
    let pxPerUm: Double?
    let cellCount: Int?
    let status: String
    let parameters: WorkbenchJSON?
    let archived: Bool

    init?(_ value: WorkbenchJSON) {
        guard let id = value["id"].string, let width = value["width"].integer,
              let height = value["height"].integer, width > 0, height > 0 else { return nil }
        self.id = id
        self.name = value["name"].string ?? id
        self.width = width
        self.height = height
        self.channels = max(1, value["channels"].integer ?? 1)
        self.zCount = max(1, value["zCount"].integer ?? 1)
        self.timeCount = max(1, value["timeCount"].integer ?? 1)
        self.volumeFrameCount = max(0, value["volumeFrameCount"].integer ?? 0)
        self.referenceCurrent = value["referenceCurrent"].bool == true
        self.sourceHash = value["sourceHash"].string ?? ""
        self.intensityUnits = value["intensityUnits"].string ?? ""
        self.variantOf = value["variantOf"].string
        self.preferredSourceParameters = value["preferredSourceParameters"]
        self.preferredVolumeSelection = value["preferredVolumeSelection"]
        self.lineages = value["lineages"].array
        self.registration = value["registration"]
        self.validSupport = value["validSupport"]
        self.pxPerUm = value["pxPerUm"].number
        self.cellCount = value["cellCount"].integer
        self.status = value["status"].string ?? "Imported"
        self.archived = value["archived"].bool == true
        if case .object = value["parameters"] { self.parameters = value["parameters"] }
        else { self.parameters = nil }
    }

    var supportsVolume: Bool { zCount > 1 || timeCount > 1 }
}

nonisolated struct WorkbenchSummary: Sendable {
    struct ImageSummary: Identifiable, Sendable {
        let id: String
        let name: String
        let cellCount: Int?
        let totalAreaPx: Double?
        let totalAreaUm2: Double?
        let meanDiameterUm: Double?
        let meanCellIntensity: Double?
    }

    let revision: Int
    let imageCount: Int
    let analyzedImageCount: Int
    let cellCount: Int
    let images: [ImageSummary]
    let volumes: WorkbenchJSON

    init(_ value: WorkbenchJSON) {
        revision = value["sourceRevision"].integer ?? 0
        imageCount = value["imageCount"].integer ?? 0
        analyzedImageCount = value["analyzedImageCount"].integer ?? 0
        cellCount = value["cellCount"].integer ?? 0
        volumes = value["volumes"]
        images = value["images"].array.compactMap { image in
            guard let id = image["imageId"].string else { return nil }
            return ImageSummary(
                id: id, name: image["name"].string ?? id,
                cellCount: image["cellCount"].integer,
                totalAreaPx: image["totalAreaPx"].number,
                totalAreaUm2: image["totalAreaUm2"].number,
                meanDiameterUm: image["meanDiameterUm"].number,
                meanCellIntensity: image["meanCellIntensity"].number)
        }
    }
}

nonisolated struct WorkbenchCell: Identifiable, Sendable {
    let id: Int
    let areaPx: Double
    let areaUm2: Double?
    let diameterUm: Double?
    let meanIntensity: Double?
    let contour: [[Double]]
    let contours: [[[Double]]]
    let cx: Double
    let cy: Double

    init?(_ value: WorkbenchJSON) {
        guard let id = value["labelId"].integer else { return nil }
        self.id = id
        self.areaPx = value["areaPx"].number ?? 0
        self.areaUm2 = value["areaUm2"].number
        self.diameterUm = value["diameterUm"].number
        self.meanIntensity = value["meanIntensity"].number
        self.cx = value["cx"].number ?? 0
        self.cy = value["cy"].number ?? 0
        self.contour = value["contourPx"].array.compactMap { point in
            let pair = point.array.compactMap(\.number)
            return pair.count == 2 && pair.allSatisfy(\.isFinite) ? pair : nil
        }
        let loops = value["contoursPx"].array.map { loop in
            loop.array.compactMap { point -> [Double]? in
                let pair = point.array.compactMap(\.number)
                return pair.count == 2 && pair.allSatisfy(\.isFinite) ? pair : nil
            }
        }.filter { !$0.isEmpty }
        self.contours = loops.isEmpty ? [self.contour] : loops
    }
}

nonisolated struct WorkbenchFailure: LocalizedError, Sendable {
    let code: String
    let message: String
    var details: WorkbenchJSON = .null
    var errorDescription: String? { message }
}

enum WorkbenchService {
    static func request(operation: String, projectPath: String,
                        revision: Int? = nil, arguments: [String: WorkbenchJSON] = [:]) async throws -> WorkbenchJSON {
        let python = PythonRuntime.workbenchInterpreter(pythonDirectory: FileStore.shared.pythonDir)
        guard FileManager.default.isExecutableFile(atPath: python.path) else {
            throw WorkbenchFailure(code: "runtime-unavailable",
                message: "Install the local environment from AI agent and command-line access to use the workbench. Image analysis stays on this Mac.")
        }
        // Validate the complete bundled engine before reusing a persistent,
        // version-specific runtime. Detached workers keep that exact snapshot.
        let script = try PythonRuntime.stageWorkbenchSnapshot()
        var body: [String: WorkbenchJSON] = [
            "schemaVersion": .number(1), "operation": .string(operation),
            "requestId": .string(UUID().uuidString), "projectPath": .string(projectPath),
            "actor": .object(["kind": .string("human"), "name": .string("macOS")]),
            "arguments": .object(arguments)
        ]
        if let revision { body["expectedRevision"] = .number(Double(revision)) }
        let encoded = try JSONEncoder().encode(WorkbenchJSON.object(body))
        guard encoded.count <= 8 * 1024 * 1024 else {
            throw WorkbenchFailure(code: "request-too-large", message: "The workbench request exceeds the 8 MiB limit.")
        }
        // Large polygons and import lists can exceed macOS's argument limit.
        // Keep the request out of argv and readable only by this user.
        let requestDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cellcounter-workbench-request-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: requestDirectory, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: requestDirectory) }
        let requestURL = requestDirectory.appendingPathComponent("request.json")
        try encoded.write(to: requestURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: requestURL.path)
        var processArguments = [script.path]
        if operation.hasPrefix("omero.") {
            processArguments += ["--omero-profiles", WorkbenchOmeroConfiguration.registryURL.path]
        }
        if ["migration.library.capture", "migration.library.catalogue"].contains(operation),
           let helper = Bundle.main.executableURL {
            processArguments += ["--native-helper", helper.path]
        }
        if ["workspace.", "semantic.", "pointlineage.", "animation."].contains(where: operation.hasPrefix),
           !["workspace.list", "workspace.get", "workspace.undo", "workspace.layer.preview", "workspace.output.list", "workspace.output.export"].contains(operation), !operation.hasSuffix(".catalogue") {
            let microscopy = try MicroscopyRuntime.stage()
            processArguments += ["--microscopy-node", microscopy.nodeURL.path,
                                 "--microscopy-runtime", microscopy.manifestURL.deletingLastPathComponent().path]
        }
        // Transitive refresh can replay retained workspace-derived acquisitions,
        // including in a detached refresh worker. Keep its binding available
        // without making unrelated measurement refresh require optional Node.
        if operation == "resource.report" || operation.hasPrefix("refresh."),
           let microscopy = try? MicroscopyRuntime.stage() {
            processArguments += ["--microscopy-node", microscopy.nodeURL.path,
                                 "--microscopy-runtime", microscopy.manifestURL.deletingLastPathComponent().path]
        }
        processArguments += ["request", "--file", requestURL.path]
        let output = try await SidecarProcessRunner.run(
            pythonURL: python, args: processArguments, trackerKind: .other)
        guard let envelope = try? JSONDecoder().decode(WorkbenchJSON.self, from: output.stdout) else {
            let diagnostic = String(data: output.stderr.suffix(1200), encoding: .utf8) ?? ""
            throw WorkbenchFailure(code: "invalid-response",
                message: "The workbench runtime could not return a result. \(diagnostic)")
        }
        guard envelope["schemaVersion"].integer == 1 else {
            throw WorkbenchFailure(code: "unsupported-schema", message: "The workbench response version is unsupported.")
        }
        if case .bool(true) = envelope["ok"], output.exitCode == 0 { return envelope }
        throw WorkbenchFailure(code: envelope["error"]["code"].string ?? "operation-failed",
            message: envelope["error"]["message"].string ?? "The workbench operation failed.", details: envelope["error"]["details"])
    }
}

@MainActor
@Observable
final class WorkbenchSession {
    typealias RequestHandler = @MainActor (
        _ operation: String, _ projectPath: String, _ revision: Int?,
        _ arguments: [String: WorkbenchJSON]
    ) async throws -> WorkbenchJSON

    var projectPath: String
    var task: WorkbenchTask = .preparation
    private(set) var navigationCatalog: WorkbenchJSON = .null
    private(set) var projectName = ""
    private(set) var revision: Int?
    var images: [WorkbenchImage] = []
    private(set) var imageCount = 0
    private(set) var projectStorage: WorkbenchJSON = .null
    let imagePage = WorkbenchImagePageState()
    let measurementPage = WorkbenchMeasurementPageState()
    let packages = WorkbenchPackageState()
    let catalogues = WorkbenchCatalogueState()
    var selectedImageID: String?
    var selectedLabels: Set<Int> = []
    var cells: [WorkbenchCell] = []
    private(set) var preview: NSImage?
    private(set) var isPreview = false
    private(set) var busy = false
    private(set) var status = "Create or open a project to begin."
    var error: String?
    private(set) var errorContext: String?
    private(set) var summary: WorkbenchSummary?
    var workflows: [WorkbenchWorkflow] = []
    var jobs: [WorkbenchJob] = []
    var jobWorkers: [WorkbenchJobWorker] = []
    var selectedWorkflowID = ""
    private(set) var runningJobID: String?
    private(set) var requestedJobAction: String?
    var specimens: [WorkbenchSpecimen] = []
    var plates: [WorkbenchPlate] = []
    var assignments: [WorkbenchAssignment] = []
    private(set) var experimentSummary: WorkbenchJSON?
    private(set) var displayedParameters: WorkbenchJSON?
    private(set) var validSupport: WorkbenchJSON = .null
    private(set) var packageInspection: WorkbenchJSON?
    let volume = WorkbenchVolumeState()
    let extensions = WorkbenchExtensionState()
    let models = WorkbenchModelState()
    let assays = WorkbenchAssayState()
    let assaySeries = WorkbenchAssaySeriesState()
    let preprocessing = WorkbenchPreprocessingState()
    let review = WorkbenchReviewState()
    let sources = WorkbenchSourceState()
    let lineage = WorkbenchLineageState()
    let temporal = WorkbenchTemporalState()
    let registration = WorkbenchRegistrationState()
    let imageExports = WorkbenchImageExportState()
    let labelImport = WorkbenchLabelImportState()
    let comparison = WorkbenchMaskComparisonState()
    let annotations = WorkbenchAnnotationState()
    let sweeps = WorkbenchSweepState()
    let composite = WorkbenchCompositeState()
    let distribution = WorkbenchDistributionState()
    let resultRefresh = WorkbenchRefreshState()
    let workflowGraph = WorkbenchWorkflowGraphState()
    let migration = WorkbenchMigrationState()
    let layeredWorkspace = WorkbenchWorkspaceState()
    let sharedSession = WorkbenchSharedSessionState()
    let library = WorkbenchLibraryState()
    let statistics = WorkbenchStatisticsState()
    let experimentLayouts = WorkbenchExperimentLayoutState()
    let omero = WorkbenchOmeroState()
    let storage = WorkbenchStorageState()
    var viewingVolume = false

    var method = "otsu"
    var polarity = "bright"
    var threshold = 128.0
    var adaptiveBlockSize = 51
    var adaptiveOffsetMode = "auto"
    var adaptiveOffset = 1.0
    var fillHoles = false
    var fillHolesExplicit = false
    var minAreaPx = 16
    var minDistancePx = 8
    var channel = 0
    var projection = "max"
    var calibration = 1.0
    var polygon: [[Double]] = []
    var drawingPolygon = false
    @ObservationIgnored private var imageGeneration = 0
    @ObservationIgnored private let request: RequestHandler
    @ObservationIgnored private let preferences: UserDefaults

    init(preferences: UserDefaults = .standard,
         request: @escaping RequestHandler = { operation, path, revision, arguments in
             try await WorkbenchService.request(operation: operation, projectPath: path,
                                                revision: revision, arguments: arguments)
         }) {
        self.preferences = preferences
        self.request = request
        self.projectPath = preferences.string(forKey: "cc-workbench-project") ?? ""
        self.packages.destination = preferences.string(forKey: "cc-workbench-restore-destination") ?? ""
    }

    var selectedImage: WorkbenchImage? { images.first { $0.id == selectedImageID } }
    var hasProject: Bool { revision != nil }
    var hasDisplayedImage: Bool { viewingVolume ? volume.display != nil : preview != nil }
    var activeWorkerCount = 0
    var hasActiveWorkers: Bool { activeWorkerCount > 0 || jobWorkers.contains { $0.active } }
    var canRefreshWithoutDiscardingEdits: Bool {
        guard !busy else { return false }
        if annotations.editorOpen && annotations.dirty { return false }
        if layeredWorkspace.editorOpen && (layeredWorkspace.dirty || layeredWorkspace.drawing) { return false }
        if lineage.editorOpen && lineage.hasUnsavedCorrection { return false }
        if lineage.editorOpen && temporal.hasPendingDraft { return false }
        if library.editorOpen && library.dirty { return false }
        if statistics.editorOpen && statistics.dirty { return false }
        if viewingVolume {
            return !volume.parametersChanged && !volume.isPreview && volume.polygon.isEmpty &&
                volume.editMode == "select" && volume.selectedLabels.isEmpty
        }
        return !parametersChanged && !isPreview && polygon.isEmpty && !drawingPolygon && selectedLabels.isEmpty
    }
    var parametersChanged: Bool { displayedParameters != nil && displayedParameters != parameters }
    var parameters: WorkbenchJSON {
        var values: [String: WorkbenchJSON] = [
            "method": .string(method), "polarity": .string(polarity),
            "minAreaPx": .number(Double(minAreaPx)), "minDistancePx": .number(Double(minDistancePx)),
            "channel": .number(Double(channel)), "zProjection": .string(projection)
        ]
        if method == "manual" { values["threshold"] = .number(threshold) }
        if method == "adaptive" {
            values["adaptiveBlockSize"] = .number(Double(adaptiveBlockSize))
            values["adaptiveOffsetMode"] = .string(adaptiveOffsetMode)
            if adaptiveOffsetMode == "manual" { values["adaptiveOffset"] = .number(adaptiveOffset) }
        }
        if fillHoles || fillHolesExplicit { values["fillHoles"] = .bool(fillHoles) }
        return .object(values)
    }

    func loadNavigationCatalog() async {
        // Navigation discovery is available before a project is opened.
        // Older runtimes keep the stable built-in task labels as a fallback.
        if let response = try? await request("navigation.catalog", "", nil, [:]) {
            navigationCatalog = response["result"]
        }
    }

    func open(path: String) {
        perform("Opening project…") {
            let response = try await self.projectSnapshot(path: path)
            if self.projectPath != path { await self.closeViewSession() }
            if self.projectPath != path { self.resetCatalogs() }
            self.projectPath = path
            self.preferences.set(path, forKey: "cc-workbench-project")
            self.summary = nil
            self.applyInspection(response)
            try await self.readImagePage()
            if self.selectedImageID == nil { self.selectedImageID = self.imagePage.images.first?.id }
            if !self.hasActiveWorkers { try await self.loadImage() }
            self.status = "Project opened."
        }
    }

    func create(path: String, name: String) {
        perform("Creating project…") {
            _ = try await self.request("project.create", path, nil, ["name": .string(name)])
            await self.closeViewSession()
            self.resetCatalogs()
            self.projectPath = path
            self.preferences.set(path, forKey: "cc-workbench-project")
            self.summary = nil
            try await self.inspect()
            try await self.loadImage()
            self.status = "Project created. Import images to begin."
        }
    }

    func inspectPackage(at url: URL) {
        packageInspection = nil
        perform("Inspecting analysis package…") {
            let response = try await self.request("package.inspect", "", nil, ["path": .string(url.path)])
            self.packageInspection = response["result"]
            self.reportStatus(response["result"]["package"]["format"].integer == 2 ? "Package metadata verified. Artifact shards will be verified as each restore checkpoint completes." : "Package integrity verified. Choose a new project destination to restore.")
        }
    }

    func restorePackage(from packageURL: URL, to destination: URL, name: String) {
        guard canRefreshWithoutDiscardingEdits, !hasActiveWorkers else { return }
        if packageInspection?["package"]["format"].integer == 2 {
            perform("Starting resumable package restore…", refreshOnConflict: false) {
                let result = try await self.restoreRequest("package.restore.start", path: destination.path,
                    arguments: ["path": .string(packageURL.path), "name": .string(name)])["result"]
                self.packages.destination = destination.path; self.packages.restore = result["restore"]
                self.rememberRestoreDestination(destination.path)
                self.reportStatus("Restore prepared. Run a verified shard checkpoint or continue all remaining checkpoints.")
            }
            return
        }
        perform("Restoring analysis package…") {
            let response = try await self.request("package.restore", destination.path, nil,
                ["path": .string(packageURL.path), "name": .string(name)])
            await self.closeViewSession()
            self.resetCatalogs()
            self.projectPath = destination.path
            self.preferences.set(destination.path, forKey: "cc-workbench-project")
            self.applyInspection(response)
            try await self.inspect()
            try await self.loadImage()
            self.reportStatus("Package restored as a new project. Review dependencies before rerunning analyses.")
        }
    }

    func refresh() {
        guard !projectPath.isEmpty else { return }
        perform("Refreshing project…") {
            try await self.inspect()
            if !self.hasActiveWorkers { try await self.loadImage() }
            self.status = "Project is current at revision \(self.revision ?? 0)."
        }
    }

    func select(_ id: String) {
        guard !busy else { return }
        guard canRefreshWithoutDiscardingEdits, !hasActiveWorkers else {
            error = "Save or clear the current draft and object selection, and stop active background work before changing images. Your current view is preserved."; return
        }
        selectedImageID = id
        perform("Loading image…") { try await self.loadImage(); self.status = "Image loaded." }
    }

    func importImages(_ urls: [URL]) {
        perform("Importing images…") {
            try await self.importImageFiles(urls)
            self.reportStatus("Images imported.")
        }
    }

    func importImageFiles(_ urls: [URL]) async throws {
        _ = try await call("image.import", arguments: ["paths": .array(urls.map { .string($0.path) })], mutation: true)
        try await inspect()
        try await loadImage()
        invalidateSummaries()
    }

    func duplicateImage(name: String, copyAnalysis: Bool) {
        guard let imageID = selectedImageID else { return }
        var args: [String: WorkbenchJSON] = [
            "imageId": .string(imageID), "copyAnalysis": .bool(copyAnalysis)
        ]
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { args["name"] = .string(trimmed) }
        perform("Creating independent mask variant…") {
            let result = try await self.call("image.duplicate", arguments: args, mutation: true)["result"]
            try await self.inspect()
            self.selectedImageID = result["imageId"].string
            self.invalidateSummaries()
            try await self.loadImage()
            self.reportStatus("Independent mask variant created from the same acquisition.")
        }
    }

    func analyze(previewOnly: Bool) {
        guard let id = selectedImageID else { return }
        let args: [String: WorkbenchJSON] = ["imageId": .string(id), "parameters": parameters, "cellLimit": .number(200)]
        if previewOnly {
            perform("Previewing segmentation…") {
                self.clearDisplayedImage()
                let response = try await self.call("analysis.preview", arguments: args)
                let rendered = response["result"]["overlayDataUrl"].string != nil
                    ? WorkbenchJSON.object(["dataUrl": response["result"]["overlayDataUrl"]]) : response["result"]
                self.preview = try self.decodePreview(rendered)
                self.displayedParameters = args["parameters"]
                self.cells = response["result"]["cells"].array.compactMap(WorkbenchCell.init)
                self.measurementPage.total = response["result"]["cellCount"].integer ?? self.cells.count
                self.validSupport = response["result"]["validSupport"]
                self.isPreview = true
                self.status = "Preview only. Run analysis to save these masks."
            }
        } else {
            mutate("analysis.run", arguments: args, message: "Analyzing image…",
                   finished: "Analysis saved.")
        }
    }

    func applyCalibration() {
        guard let id = selectedImageID else { return }
        mutate("calibration.set", arguments: ["imageId": .string(id), "pxPerUm": .number(calibration)],
               message: "Updating calibration…", finished: "Calibration updated.")
    }

    func edit(_ action: String) {
        guard let id = selectedImageID, !isPreview, !parametersChanged else { return }
        var args: [String: WorkbenchJSON] = [
            "imageId": .string(id), "action": .string(action)
        ]
        if action == "polygon" {
            args["polygon"] = .array(polygon.map { .array($0.map(WorkbenchJSON.number)) })
        } else {
            args["labelIds"] = .array(selectedLabels.sorted().map { .number(Double($0)) })
        }
        mutate("mask.edit", arguments: args, message: "Saving correction…",
               finished: "Correction saved and measurements updated.")
    }

    func undo() {
        guard let id = selectedImageID, !parametersChanged else { return }
        mutate("mask.undo", arguments: ["imageId": .string(id)],
               message: "Undoing correction…", finished: "Correction undone.")
    }

    func summarize() {
        summary = nil
        perform("Summarizing project…") {
            let response = try await self.call("summary.get")
            self.summary = WorkbenchSummary(response["result"])
            self.status = "Project summary is ready."
        }
    }

    func export(to url: URL) {
        perform("Exporting project…") {
            _ = try await self.call("project.export", arguments: ["destination": .string(url.path)], mutation: true)
            try await self.inspect()
            self.summary = nil
            self.status = "Exported \(url.lastPathComponent)."
        }
    }

    func loadWorkflows() {
        perform("Loading workflows…") {
            try await self.inspect()
            if !self.hasActiveWorkers { try await self.readExtensionCatalogs() }
            self.assays.catalog = try await self.call("assay.catalog")["result"]["assays"].array.compactMap(WorkbenchAssay.init)
            try await self.readPreprocessingCatalog()
            if self.workflowGraph.nodeTypes.isEmpty {
                self.workflowGraph.configureCatalogue(try await self.call("workflow.graph.catalogue")["result"])
            }
            if !self.hasActiveWorkers && !self.hasDisplayedImage { try await self.loadImage() }
            self.status = "Workflows and jobs loaded."
        }
    }

    func startBackgroundJob(_ jobID: String) {
        guard canRefreshWithoutDiscardingEdits else { return }
        perform("Starting background workflow…") {
            _ = try await self.call("job.worker.start", arguments: ["jobId": .string(jobID)], mutation: true)
            try await self.inspect()
            if !self.hasActiveWorkers && !self.hasDisplayedImage { try await self.loadImage() }
            self.reportStatus("Background workflow started. It continues if this window or application closes.")
        }
    }

    func stopBackgroundJob(_ workerID: String) {
        let mayRefresh = canRefreshWithoutDiscardingEdits
        perform("Requesting stop after the current checkpoint…") {
            let response = try await self.request("job.worker.stop", self.projectPath, nil, [
                "workerId": .string(workerID), "reason": .string("Stop requested from the macOS Workbench.")
            ])
            if let worker = WorkbenchJobWorker(response["result"]["worker"]),
               let index = self.jobWorkers.firstIndex(where: { $0.id == worker.id }) {
                self.jobWorkers[index] = worker
            }
            if mayRefresh {
                try await self.inspect()
                if !self.hasActiveWorkers && !self.hasDisplayedImage { try await self.loadImage() }
            }
            self.reportStatus("Stop requested. The worker will preserve the current checkpoint before pausing.")
        }
    }

    func refreshBackgroundProgress() { refreshProjectActivity() }

    func jobWorkersFromActivity(_ values: [WorkbenchJSON]) {
        activeWorkerCount = values.compactMap(WorkbenchJobWorker.init).filter(\.active).count
        let active = values.compactMap(WorkbenchJobWorker.init)
        let ids = Set(active.map(\.id))
        jobWorkers = active + jobWorkers.filter { !$0.active && !ids.contains($0.id) }
    }

    func saveWorkflow(name: String, updateID: String?, includeExport: Bool,
                      segmentationPlugin: String? = nil,
                      segmentationParameters: [String: WorkbenchJSON] = [:],
                      measurementPlugins: [WorkbenchJSON] = [],
                      registeredModel: String? = nil,
                      modelParameters: [String: WorkbenchJSON] = [:],
                      preprocessingRecipe: [WorkbenchJSON] = [],
                      analysisOverride: WorkbenchJSON? = nil,
                      preprocessingOverride: WorkbenchJSON? = nil,
                      exportOverride: WorkbenchJSON? = nil) {
        var analysis: WorkbenchJSON = viewingVolume
            ? .object(["type": .string("volume-analysis"), "parameters": volume.parameters,
                       "channel": .number(Double(volume.channel))])
            : .object(["type": .string("analysis"), "parameters": parameters])
        if let pluginID = segmentationPlugin {
            var plugin: [String: WorkbenchJSON] = [
                "type": .string("plugin-segmentation"), "pluginId": .string(pluginID),
                "pluginParameters": .object(segmentationParameters),
                "target": .string(viewingVolume ? "volume" : "plane")
            ]
            if viewingVolume { plugin["channel"] = .number(Double(volume.channel)) }
            else { plugin["sourceParameters"] = parameters }
            analysis = .object(plugin)
        }
        if let modelID = registeredModel {
            analysis = .object(["type": .string("model-segmentation"), "modelId": .string(modelID),
                               "modelParameters": .object(modelParameters), "sourceParameters": parameters])
        }
        if let analysisOverride {
            var loaded = analysisOverride.object
            if loaded["type"]?.string == "plugin-segmentation" {
                loaded["pluginParameters"] = .object(segmentationParameters)
            } else if loaded["type"]?.string == "model-segmentation" {
                loaded["modelParameters"] = .object(modelParameters)
            }
            analysis = .object(loaded)
        }
        var steps: [WorkbenchJSON] = []
        if !preprocessingRecipe.isEmpty {
            var preprocessing = preprocessingOverride?.object ?? [:]
            preprocessing["type"] = .string("preprocessing")
            preprocessing["recipe"] = .array(preprocessingRecipe)
            steps.append(.object(preprocessing))
        }
        steps += [analysis] + measurementPlugins + [
            .object(["type": .string("measurements")]),
            .object(["type": .string("summary")])
        ]
        if includeExport { steps.append(exportOverride ?? .object(["type": .string("export")])) }
        var args: [String: WorkbenchJSON] = ["name": .string(name), "steps": .array(steps)]
        if let updateID { args["workflowId"] = .string(updateID) }
        perform("Saving workflow…") {
            let response = try await self.call("workflow.save", arguments: args, mutation: true)
            self.selectedWorkflowID = response["result"]["workflow"]["id"].string ?? ""
            try await self.inspect()
            if !self.hasDisplayedImage { try await self.loadImage() }
            self.status = "Workflow saved. Existing jobs keep their original workflow version."
        }
    }

    func createJob(imageIDs: Set<String>, exportDestination: URL?, timeIndices: [Int]? = nil) {
        guard !selectedWorkflowID.isEmpty, canRefreshWithoutDiscardingEdits, !hasActiveWorkers,
              let workflow = workflows.first(where: { $0.id == selectedWorkflowID }) else { return }
        var args: [String: WorkbenchJSON] = [
            "workflowId": .string(selectedWorkflowID),
            "workflowVersion": .number(Double(workflow.version)),
            "imageIds": .array(imageIDs.sorted().map(WorkbenchJSON.string))
        ]
        if let exportDestination { args["exportDestination"] = .string(exportDestination.path) }
        if let timeIndices { args["timeIndices"] = .array(timeIndices.map { .number(Double($0)) }) }
        perform("Creating analysis job…") {
            _ = try await self.call("job.create", arguments: args, mutation: true)
            try await self.inspect()
            if !self.hasDisplayedImage { try await self.loadImage() }
            self.status = "Job created. Choose Run next or Run remaining to begin."
        }
    }

    func advanceJob(_ id: String, remaining: Bool) {
        guard canRefreshWithoutDiscardingEdits, !hasActiveWorkers else { return }
        perform(remaining ? "Running workflow…" : "Running next checkpoint…") {
            self.runningJobID = id
            defer { self.runningJobID = nil; self.requestedJobAction = nil }
            repeat {
                _ = try await self.call("job.advance", arguments: ["jobId": .string(id)], mutation: true)
                try await self.inspect()
                guard let job = self.jobs.first(where: { $0.id == id }) else { break }
                if let action = self.requestedJobAction, job.canAdvance {
                    _ = try await self.call("job.\(action)", arguments: ["jobId": .string(id)], mutation: true)
                    try await self.inspect()
                    break
                }
                guard remaining && job.canAdvance else { break }
            } while true
            try await self.loadImage()
            self.summary = nil
            self.experimentSummary = nil
            self.status = "Job \(self.jobs.first(where: { $0.id == id })?.status ?? "updated")."
        }
    }

    func requestJobStop(cancel: Bool) {
        guard runningJobID != nil else { return }
        requestedJobAction = cancel ? "cancel" : "pause"
        status = cancel ? "Cancelling after the current checkpoint…" : "Pausing after the current checkpoint…"
    }

    func changeJob(_ id: String, action: String) {
        guard canRefreshWithoutDiscardingEdits, !hasActiveWorkers else { return }
        perform("Updating job…") {
            _ = try await self.call("job.\(action)", arguments: ["jobId": .string(id)], mutation: true)
            try await self.inspect()
            if !self.hasDisplayedImage { try await self.loadImage() }
            self.status = "Job updated."
        }
    }

    func loadExperiment() {
        perform("Loading experiment…") {
            try await self.inspect()
            if !self.hasDisplayedImage { try await self.loadImage() }
            try await self.readExperimentDefinitions()
            self.status = "Specimens, layouts, acquisition sessions and exclusion history loaded."
        }
    }

    func updateExperiment(_ operation: String, arguments: [String: WorkbenchJSON]) {
        perform("Saving experiment…") {
            _ = try await self.call(operation, arguments: arguments, mutation: true)
            try await self.inspect()
            if !self.hasDisplayedImage { try await self.loadImage() }
            self.experimentSummary = nil
            self.summary = nil
            self.status = "Experimental design saved."
        }
    }

    func summarizeExperiment() {
        experimentSummary = nil
        perform("Summarizing biological specimens…") {
            self.experimentSummary = try await self.call("experiment.summary")["result"]
            self.status = "Biological specimen summary ready."
        }
    }

    private func resetCatalogs() {
        images = []; imageCount = 0; selectedImageID = nil; imagePage.reset(); measurementPage.reset(); packages.resetProject()
        workflows = []; jobs = []; jobWorkers = []; selectedWorkflowID = ""
        specimens = []; plates = []; assignments = []
        experimentSummary = nil; summary = nil
        extensions.reset()
        models.reset()
        assays.reset()
        assaySeries.reset()
        preprocessing.reset()
        review.reset()
        sources.reset()
        lineage.reset()
        temporal.reset()
        registration.reset()
        imageExports.reset()
        labelImport.reset()
        comparison.reset()
        annotations.reset()
        sweeps.reset()
        composite.reset()
        distribution.reset()
        resultRefresh.reset()
        workflowGraph.reset()
        migration.reset()
        layeredWorkspace.reset()
        sharedSession.reset()
        library.reset()
        statistics.reset()
        experimentLayouts.reset()
        catalogues.reset()
        activeWorkerCount = 0
        omero.resetProjectContext()
        storage.reset()
        volume.imageID = ""
        volume.invalidateDisplay()
    }

    private func mutate(_ operation: String, arguments: [String: WorkbenchJSON],
                        message: String, finished: String) {
        perform(message) {
            _ = try await self.call(operation, arguments: arguments, mutation: true)
            try await self.inspect()
            try await self.loadImage()
            self.summary = nil
            self.experimentSummary = nil
            self.status = finished
        }
    }

    func call(_ operation: String, arguments: [String: WorkbenchJSON] = [:],
                      mutation: Bool = false) async throws -> WorkbenchJSON {
        var boundedArguments = arguments
        let cellResponseOperations: Set<String> = ["analysis.preview", "analysis.run", "volume.analysis.preview", "volume.analysis.run",
            "calibration.set", "mask.edit", "mask.undo", "volume.calibration.set", "volume.mask.edit", "volume.mask.undo",
            "model.run", "plugin.run", "mask.import.preview", "mask.import.run"]
        if cellResponseOperations.contains(operation), boundedArguments["cellLimit"] == nil { boundedArguments["cellLimit"] = .number(200) }
        let response = try await request(operation, projectPath, mutation ? revision : nil, boundedArguments)
        if operation.hasPrefix("session.") || operation == "project.changes" || operation == "project.activity" || operation == "adaptation.train.status" || operation == "job.worker.status" {
            // Session/activity envelopes report the current revision without
            // authorizing this view to adopt a newer scientific snapshot.
            return response
        }
        if let updated = response["revision"].integer {
            if mutation { revision = updated }
            else if !["project.inspect", "project.snapshot"].contains(operation), let revision, revision != updated {
                throw WorkbenchFailure(code: "revision-conflict",
                    message: "Another client changed this project while the result was loading.")
            }
        }
        return response
    }

    func requestSnapshot(project: String, arguments: [String: WorkbenchJSON]) async throws -> WorkbenchJSON {
        try await request("project.snapshot", project, nil, arguments)
    }

    func restoreRequest(_ operation: String, path: String, arguments: [String: WorkbenchJSON] = [:]) async throws -> WorkbenchJSON {
        guard ["package.restore.start", "package.restore.get", "package.restore.advance", "package.restore.cancel", "package.restore.resume"].contains(operation) else {
            throw WorkbenchFailure(code: "invalid-operation", message: "Unsupported package restore checkpoint.")
        }
        return try await request(operation, path, nil, arguments)
    }

    func rememberRestoreDestination(_ path: String) { preferences.set(path, forKey: "cc-workbench-restore-destination") }

    func adoptRestoredProject(path: String) async throws {
        await closeViewSession(); resetCatalogs(); clearDisplayedImage()
        projectPath = path; preferences.set(path, forKey: "cc-workbench-project")
        try await inspect(); try await loadImage()
        reportStatus("Verified package restored as a new project. Models and executable plugins require explicit trust before use.")
    }

    func migrationProjectless(_ operation: String, arguments: [String: WorkbenchJSON]) async throws -> WorkbenchJSON {
        guard ["migration.library.capture", "migration.library.preview", "migration.library.catalogue"].contains(operation) else {
            throw WorkbenchFailure(code: "invalid-operation", message: "This migration operation requires a project.")
        }
        return try await request(operation, "", nil, arguments)
    }

    func omeroProjectless(_ operation: String, arguments: [String: WorkbenchJSON] = [:]) async throws -> WorkbenchJSON {
        guard operation.hasPrefix("omero."), operation != "omero.import.run" else {
            throw WorkbenchFailure(code: "invalid-operation", message: "Import requires the current project revision.")
        }
        // Host registry CAS and network previews do not authorize adoption of a
        // newer project revision and never carry project-scoped credentials.
        return try await request(operation, "", nil, arguments)
    }

    func createLibraryMigration(at destination: URL) {
        guard canRefreshWithoutDiscardingEdits, !hasActiveWorkers, migration.hasPlan,
              let fingerprint = migration.plan["previewFingerprint"].string else { return }
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            error = "Choose a new project folder. Migration preserves existing projects."; return
        }
        let archivePath = migration.archivePath
        let name = migration.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { error = "Enter a name for the new project."; return }
        perform("Creating migration project…", refreshOnConflict: false) {
            _ = try await self.request("migration.library.run", destination.path, nil, [
                "path": .string(archivePath), "previewFingerprint": .string(fingerprint), "name": .string(name)])
            await self.closeViewSession()
            self.resetCatalogs()
            self.clearDisplayedImage()
            self.projectPath = destination.path
            self.preferences.set(destination.path, forKey: "cc-workbench-project")
            try await self.inspect()
            self.migration.archivePath = archivePath
            self.reportStatus("Migration project created. Run the retained file and acquisition checkpoints to finish importing.")
        }
    }

    func inspect() async throws {
        try await inspectFromChanges(preserveDisplayedImage: false)
    }

    func inspectFromChanges(preserveDisplayedImage: Bool) async throws {
        let selected = selectedImageID.map { [WorkbenchJSON.string($0)] } ?? []
        let response = try await projectSnapshot(selected: selected)
        applyInspection(response, preserveDisplayedImage: preserveDisplayedImage)
        try await readImagePage()
        if selectedImageID == nil { selectedImageID = imagePage.images.first?.id }
    }

    private func applyInspection(_ response: WorkbenchJSON, preserveDisplayedImage: Bool = false) {
        let value = response["result"]
        let updatedRevision = value["project"]["revision"].integer ?? response["revision"].integer
        if updatedRevision != revision {
            summary = nil; experimentSummary = nil
            if preserveDisplayedImage {
                if composite.renderedRevision == revision { composite.renderedRevision = updatedRevision }
                if composite.volumeRevision == revision { composite.volumeRevision = updatedRevision }
            } else { clearDisplayedImage() }
        }
        catalogues.absorb(value)
        projectName = value["project"]["name"].string ?? "Microscopy project"
        revision = updatedRevision
        sharedSession.observedRevision = updatedRevision
        sharedSession.pendingRevision = nil
        images = []
        extensions.referenceCurrent = [:]
        cacheImages(value["images"].array.compactMap(WorkbenchImage.init))
        imageCount = value["imageCount"].integer ?? images.count
        projectStorage = value["storage"]
        library.collections = value["collections"].array
        extensions.plugins = value["plugins"].array.compactMap(WorkbenchPlugin.init)
        extensions.datasets = value["adaptationDatasets"].array
        extensions.normalizeSelection()
        migration.applyInspection(value)
        layeredWorkspace.applyInspection(value)
        models.applyInspection(value)
        composite.presets.updateList(value["displayPresets"].array)
        distribution.applyInspection(value)
        resultRefresh.applyInspection(value)
        statistics.applyInspection(value)
        experimentLayouts.applyInspection(value)
        sweeps.applyInspection(value)
        assays.applyInspection(value)
        assaySeries.applyInspection(value)
        review.sessions = value["reviewSessions"].array
        sources.applyInspection(value)
        storage.applyInspection(value)
        workflows = value["workflows"].array.compactMap(WorkbenchWorkflow.init)
        jobs = value["jobs"].array.compactMap(WorkbenchJob.init)
        let activeWorkers = value["activeJobWorkers"].array
        let activeIDs = Set(activeWorkers.compactMap { $0["workerId"].string })
        jobWorkers = (activeWorkers + value["jobWorkers"].array.filter { !activeIDs.contains($0["workerId"].string ?? "") }).compactMap(WorkbenchJobWorker.init)
        activeWorkerCount = value["activeWorkerCount"].integer ?? activeWorkers.count
        let design = value["experimentalDesign"]
        specimens = design["specimens"].array.compactMap(WorkbenchSpecimen.init)
        plates = design["plates"].array.compactMap(WorkbenchPlate.init)
        assignments = design["assignments"].array.compactMap(WorkbenchAssignment.init)
        if selectedWorkflowID.isEmpty { selectedWorkflowID = workflows.first?.id ?? "" }
        // Library page membership never clears a selected image ID.
    }

    private func clearDisplayedImage() {
        measurementPage.reset()
        extensions.invalidateResults()
        assays.invalidateResults()
        preprocessing.invalidatePreview()
        preview = nil
        cells = []
        validSupport = .null
        isPreview = false
        selectedLabels = []
        polygon = []
        drawingPolygon = false
        displayedParameters = nil
        volume.invalidateDisplay()
    }

    private func restoreParameters(for image: WorkbenchImage) {
        let saved = image.parameters ?? image.preferredSourceParameters
        method = saved["method"].string ?? "otsu"
        polarity = saved["polarity"].string ?? "bright"
        threshold = saved["threshold"].number ?? 128
        adaptiveBlockSize = saved["adaptiveBlockSize"].integer ?? 51
        adaptiveOffsetMode = saved["adaptiveOffsetMode"].string ?? "auto"
        adaptiveOffset = saved["adaptiveOffset"].number ?? 1
        fillHoles = saved["fillHoles"].bool ?? false
        fillHolesExplicit = saved["fillHoles"].bool != nil
        minAreaPx = saved["minAreaPx"].integer ?? 16
        minDistancePx = saved["minDistancePx"].integer ?? 8
        channel = min(image.channels - 1, max(0, saved["channel"].integer ?? 0))
        projection = saved["zProjection"].string ?? "max"
    }

    private func sourcePreview(imageID: String, parameters: WorkbenchJSON) async throws -> NSImage {
        let response = try await call("image.preview", arguments: [
            "imageId": .string(imageID), "maxSize": .number(768), "parameters": parameters
        ])
        return try decodePreview(response["result"])
    }

    func decodePreview(_ result: WorkbenchJSON) throws -> NSImage {
        guard let url = result["dataUrl"].string,
              let comma = url.firstIndex(of: ","),
              let data = Data(base64Encoded: String(url[url.index(after: comma)...])),
              let image = NSImage(data: data) else {
            throw WorkbenchFailure(code: "invalid-response", message: "The runtime returned an unreadable image preview.")
        }
        return image
    }

    func loadImage() async throws {
        imageGeneration += 1
        let generation = imageGeneration
        clearDisplayedImage()
        guard let selectedImageID else { return }
        let image = try await resolveImage(selectedImageID)
        if volume.imageID != image.id {
            volume.configure(for: image)
            viewingVolume = image.supportsVolume
        }
        if viewingVolume {
            try await loadVolume()
            return
        }
        calibration = image.pxPerUm ?? 1
        restoreParameters(for: image)
        let source = try await sourcePreview(imageID: image.id, parameters: parameters)
        guard generation == imageGeneration, selectedImageID == image.id else { return }
        preview = source
        displayedParameters = parameters
        if image.cellCount != nil || image.status == "analyzed" || image.status == "current" {
            try await readMeasurementPage()
            guard generation == imageGeneration, selectedImageID == image.id else { return }
            validSupport = image.validSupport
            try await loadSavedMaskOverlay()
        }
    }

    /// Explicit view navigation from a named local session. Ordinary scientific
    /// operations never call this method or move the selected image.
    func loadNavigationSelection(_ selection: WorkbenchJSON) async throws {
        let requestedTask: WorkbenchTask?
        if let taskID = selection["task"].string {
            guard let nextTask = WorkbenchTask(rawValue: taskID) else {
                throw WorkbenchFailure(code: "task-unavailable", message: "The requested workbench task is unavailable.")
            }
            requestedTask = nextTask
            if isTaskOnlyNavigation(selection) { task = nextTask; return }
        } else { requestedTask = nil }
        if let workspaceID = selection["workspaceId"].string {
            layeredWorkspace.load(try await call("workspace.get", arguments: ["workspaceId": .string(workspaceID)])["result"])
            sharedSession.presentWorkspace = true
        }
        guard let imageID = selection["imageId"].string else {
            if let requestedTask { task = requestedTask }
            return
        }
        let image = try await resolveImage(imageID)
        let target = selection["target"].string ?? "plane"
        let requestedChannel = selection["channel"].integer ?? 0
        guard requestedChannel >= 0, requestedChannel < image.channels else {
            throw WorkbenchFailure(code: "channel-unavailable", message: "The requested display channel is unavailable.")
        }
        if target == "plane", (selection["timeIndex"].integer ?? 0) != 0 {
            throw WorkbenchFailure(code: "selection-unavailable", message: "Use volume navigation for an explicit time point.")
        }
        selectedImageID = imageID
        clearDisplayedImage()
        if target == "volume" {
            viewingVolume = true
            volume.configure(for: image)
            volume.timeIndex = selection["timeIndex"].integer ?? 0
            volume.channel = requestedChannel
            volume.plane = selection["plane"].string ?? "xy"
            volume.crosshair[volume.normalAxis] = selection["index"].integer ?? 0
            try await loadVolume()
        } else {
            viewingVolume = false
            restoreParameters(for: image)
            channel = requestedChannel
            calibration = image.pxPerUm ?? 1
            preview = try await sourcePreview(imageID: imageID, parameters: parameters)
            displayedParameters = parameters
            // Displaying a different source channel does not reinterpret saved
            // segmentation. Its geometry is shown only for the saved selection.
            if image.parameters?["channel"].integer == requestedChannel {
                try await readMeasurementPage()
                validSupport = image.validSupport
                try await loadSavedMaskOverlay()
            }
        }
        if let requestedTask { task = requestedTask }
    }

    func reportStatus(_ message: String) { status = message }

    /// Read a revision-labelled report without replacing the main canvas or its edit state.
    func readSweepResultsSnapshot(arguments: [String: WorkbenchJSON]) async throws -> WorkbenchJSON {
        try await request("sweep.results", projectPath, nil, arguments)
    }

    func readWorkflowJobSnapshot(_ id: String) async throws -> WorkbenchJSON {
        try await request("job.get", projectPath, nil, ["jobId": .string(id)])
    }

    func readWorkflowNodePreviewSnapshot(arguments: [String: WorkbenchJSON]) async throws -> WorkbenchJSON {
        try await request("job.graph.node.preview", projectPath, nil, arguments)
    }

    func readRefreshSnapshot(_ operation: String, arguments: [String: WorkbenchJSON]) async throws -> WorkbenchJSON {
        guard ["refresh.inspect", "refresh.preview", "refresh.get", "refresh.results", "refresh.list", "refresh.export.catalogue"].contains(operation) else {
            throw WorkbenchFailure(code: "invalid-operation", message: "This result refresh operation is not a snapshot read.")
        }
        return try await request(operation, projectPath, nil, arguments)
    }

    func invalidateSummaries() { summary = nil; experimentSummary = nil; assays.biologicalSummary = nil }

    /// Background observation shares the same serialization gate without
    /// clearing a user action's error or flashing a new status every timer tick.
    func performActivity(action: @escaping @MainActor () async throws -> Void) {
        guard !busy else { sharedSession.polling = false; return }
        busy = true
        Task {
            defer { busy = false; sharedSession.polling = false }
            do { try await action() }
            catch { sharedSession.notice = "Shared activity could not refresh: \(error.localizedDescription). Existing drafts are preserved." }
        }
    }

    func perform(_ message: String, refreshOnConflict: Bool = true,
                 action: @escaping @MainActor () async throws -> Void) {
        guard !busy else { return }
        let mayRefreshAfterConflict = canRefreshWithoutDiscardingEdits
        let actionName = message.replacingOccurrences(of: "…", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        busy = true
        status = message
        error = nil; errorContext = nil
        Task {
            defer { busy = false }
            do { try await action() }
            catch let failure as WorkbenchFailure {
                let conflict = failure.code.contains("revision") || failure.code.contains("conflict") || failure.code == "snapshot-changed"
                if refreshOnConflict && conflict && mayRefreshAfterConflict {
                    do {
                        try await inspect()
                        if !hasActiveWorkers { try await loadImage() }
                        error = "\(failure.message) The project was refreshed. Inspect the updated result before retrying."
                    } catch {
                        self.error = "\(failure.message) The project could not be refreshed: \(error.localizedDescription) Refresh from the Project menu before retrying."
                    }
                } else if refreshOnConflict && conflict {
                    error = "\(failure.message) Your current edits are preserved. Review or clear them before refreshing the project and retrying."
                } else { error = failure.message }
                errorContext = actionName
                status = "Could not complete: \(actionName)."
            }
            catch {
                self.error = error.localizedDescription
                errorContext = actionName
                status = "Could not complete: \(actionName)."
            }
        }
    }
}

nonisolated enum WorkbenchClassicalMethod {
    static let names: [(id: String, title: String)] = [("otsu", "Otsu threshold"), ("triangle", "Triangle threshold"),
        ("li", "Li threshold"), ("yen", "Yen threshold"), ("mean", "Mean threshold"),
        ("adaptive", "Adaptive threshold"), ("manual", "Manual threshold")]
    static func title(_ method: String) -> String { names.first { $0.id == method }?.title ?? method }
}
