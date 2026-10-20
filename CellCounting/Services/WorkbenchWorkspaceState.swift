import AppKit
import Foundation
import Observation

@MainActor @Observable
final class WorkbenchWorkspaceState {
    var workspaces: [WorkbenchJSON] = []
    var outputs: [WorkbenchJSON] = []
    var selectedID = ""
    var selectedLayerID = ""
    var record: WorkbenchJSON = .null
    var document: WorkbenchJSON = .null
    var savedDocument: WorkbenchJSON = .null
    var bindings: [WorkbenchJSON] = []
    var missingSources: [WorkbenchJSON] = []
    var generatedLayers: [WorkbenchJSON] = []
    var layerGrids: [WorkbenchJSON] = []
    var materializeName = "Derived workspace image"
    var materializePreview: WorkbenchJSON = .null
    var materializeRevision: Int?
    var materializeArguments: WorkbenchJSON = .null
    var importPath = ""
    var importFormat = "native"
    var importPreview: WorkbenchJSON = .null
    var preview: NSImage?
    var previewRevision: Int?
    var layerPreview: NSImage?
    var layerGrid = CGSize.zero
    var layerPreviewID = ""
    var layerPreviewRevision: Int?
    var editorOpen = false
    var drawing = false
    var paintEnabled = false
    var paintClass = 1
    var paintRadius = 12.0
    var paintErases = false
    var newName = "Layered workspace"
    var lineageDistance = 80.0
    var selectedWorkflowID = ""
    var selectedAnimationID = ""
    var historicalVersion: Int?
    var dirty: Bool { document != savedDocument }
    var isHistorical: Bool { (record["version"].integer ?? 0) != (record["latestVersion"].integer ?? 0) }
    var layers: [WorkbenchJSON] { document["layers"].array }
    var selectedLayer: WorkbenchJSON { layers.first { $0["id"].string == selectedLayerID } ?? .null }
    var selectedBinding: WorkbenchJSON { bindings.first { $0["layerId"].string == selectedLayerID } ?? .null }
    var paintDocument: WorkbenchJSON { document["paintDocuments"][selectedLayerID] }
    var classes: [WorkbenchJSON] { paintDocument["classes"].array }
    var visibleStrokes: [WorkspacePaintStroke] {
        paintDocument["strokes"].array.compactMap { value in
            guard value["position"].object.allSatisfy({ document["position"][$0.key] == $0.value }) else { return nil }
            let points = value["points"].array.compactMap { point -> WorkspaceCoordinate? in
                guard let x = point["x"].number, let y = point["y"].number else { return nil }
                return WorkspaceCoordinate(x: x, y: y)
            }
            return WorkspacePaintStroke(classValue: UInt16(clamping: value["classValue"].integer ?? 0),
                radiusPx: value["radius"].number ?? 1, points: points,
                position: WorkspacePosition(), erases: value["erases"].bool == true)
        }
    }
    func applyInspection(_ value: WorkbenchJSON) {
        workspaces = value["workspaces"].array
        outputs = value["workspaceOutputs"].array
        if selectedID.isEmpty { selectedID = workspaces.first?["id"].string ?? "" }
    }
    func load(_ result: WorkbenchJSON) {
        record = result["workspace"]; selectedID = record["id"].string ?? ""
        document = result["document"]; savedDocument = document
        bindings = result["layerBindings"].array; missingSources = result["missingSources"].array
        generatedLayers = result["generatedLayers"].array
        layerGrids = result["layerGrids"].array
        if !layers.contains(where: { $0["id"].string == selectedLayerID }) { selectedLayerID = layers.first?["id"].string ?? "" }
        historicalVersion = isHistorical ? record["version"].integer : nil
        invalidatePreview()
    }
    func invalidatePreview() {
        preview = nil; previewRevision = nil; layerPreview = nil; layerPreviewRevision = nil; layerPreviewID = ""; layerGrid = .zero
        materializePreview = .null; materializeRevision = nil; materializeArguments = .null
    }
    func reset() {
        workspaces = []; outputs = []; selectedID = ""; selectedLayerID = ""
        record = .null; document = .null; savedDocument = .null; bindings = []; missingSources = []; generatedLayers = []; layerGrids = []
        importPath = ""; importPreview = .null; historicalVersion = nil; drawing = false; paintEnabled = false
        invalidatePreview()
    }
    func editLayer(_ field: String, _ value: WorkbenchJSON) {
        var root = document.object
        root["layers"] = .array(layers.map { layer in
            guard layer["id"].string == selectedLayerID else { return layer }
            var edited = layer.object; edited[field] = value; return .object(edited)
        })
        document = .object(root)
    }
    func editDocument(_ field: String, _ value: WorkbenchJSON) {
        if field == "position", document[field] != value { invalidatePreview(); paintEnabled = false }
        var root = document.object; root[field] = value; document = .object(root)
    }
    func initializePaint() {
        guard layerGrid.width > 0, layerGrid.height > 0, paintDocument == .null else { return }
        var paints = document["paintDocuments"].object
        paints[selectedLayerID] = .object([
            "width": .number(Double(layerGrid.width)), "height": .number(Double(layerGrid.height)),
            "classes": .array([.object(["value": .number(1), "name": .string("Class 1"), "colorHex": .string("#00FFFF")]),
                               .object(["value": .number(2), "name": .string("Class 2"), "colorHex": .string("#FF9900")])]),
            "strokes": .array([])])
        editDocument("paintDocuments", .object(paints))
    }
    func appendStroke(_ points: [WorkspaceCoordinate]) {
        guard !points.isEmpty, points.count <= 4096, paintRadius.isFinite, (0.5...512).contains(paintRadius), layerGrid.width > 0,
              paintDocument["width"].number == layerGrid.width, paintDocument["height"].number == layerGrid.height else { return }
        var paint = paintDocument.object
        paint["strokes"] = .array(paintDocument["strokes"].array + [.object([
            "id": .string(UUID().uuidString), "classValue": .number(Double(paintClass)),
            "radius": .number(paintRadius), "erases": .bool(paintErases), "position": document["position"],
            "points": .array(points.map { .object(["x": .number($0.x), "y": .number($0.y)]) })])])
        var paints = document["paintDocuments"].object; paints[selectedLayerID] = .object(paint)
        editDocument("paintDocuments", .object(paints))
    }
    func undoDraftStroke() {
        var paint = paintDocument.object; var strokes = paintDocument["strokes"].array
        guard !strokes.isEmpty else { return }; strokes.removeLast(); paint["strokes"] = .array(strokes)
        var paints = document["paintDocuments"].object; paints[selectedLayerID] = .object(paint)
        editDocument("paintDocuments", .object(paints))
    }
}

extension WorkbenchSession {
    func previewWorkspaceMaterialization() {
        let state = layeredWorkspace
        guard !state.dirty, !state.isHistorical, !state.drawing, !state.selectedLayerID.isEmpty else { return }
        let args: [String: WorkbenchJSON] = ["workspaceId": .string(state.selectedID), "layerId": .string(state.selectedLayerID), "name": .string(state.materializeName)]
        perform("Previewing generated scientific acquisition…") {
            state.materializePreview = .null
            state.materializePreview = try await self.call("workspace.materialize.preview", arguments: args)["result"]
            state.materializeArguments = .object(args); state.materializeRevision = self.revision
            self.reportStatus("Exact generated grid, source parents and acquired support are ready for review.")
        }
    }
    func materializeWorkspaceImage() {
        let state = layeredWorkspace
        let args: [String: WorkbenchJSON] = ["workspaceId": .string(state.selectedID), "layerId": .string(state.selectedLayerID), "name": .string(state.materializeName)]
        guard canRefreshWithoutDiscardingEdits, !hasActiveWorkers, !state.isHistorical,
              state.materializeRevision == revision, state.materializeArguments == .object(args),
              let fingerprint = state.materializePreview["previewFingerprint"].string else { return }
        perform("Creating scientific image from generated layer…") {
            var arguments = args; arguments["previewFingerprint"] = .string(fingerprint)
            let result = try await self.call("workspace.materialize.run", arguments: arguments, mutation: true)["result"]
            try await self.inspect()
            state.materializePreview = .null; state.materializeRevision = nil
            if let imageID = result["derivedImageId"].string {
                self.selectedImageID = imageID
                try await self.loadImage()
            }
            self.reportStatus("Independent scientific image created with exact source parents and support. Assign its biological specimen explicitly if appropriate.")
        }
    }
    func loadLayeredWorkspace(_ id: String? = nil, version: Int? = nil) {
        guard !layeredWorkspace.dirty, !layeredWorkspace.drawing else {
            error = "Save or discard the workspace draft before changing workspace or version."; return
        }
        let selected = id ?? layeredWorkspace.selectedID
        guard !selected.isEmpty else { return }
        perform("Loading layered workspace…") {
            var args: [String: WorkbenchJSON] = ["workspaceId": .string(selected)]
            if let version { args["version"] = .number(Double(version)) }
            self.layeredWorkspace.load(try await self.call("workspace.get", arguments: args)["result"])
        }
    }
    func workspaceMutation(_ operation: String, arguments: [String: WorkbenchJSON] = [:], reload: Bool = true) {
        guard !hasActiveWorkers, !layeredWorkspace.drawing,
              !layeredWorkspace.dirty || operation == "workspace.document.set" else { return }
        perform("Updating layered workspace…") {
            let result = try await self.call(operation, arguments: arguments, mutation: true)["result"]
            if let id = result["workspace"]["id"].string { self.layeredWorkspace.selectedID = id }
            try await self.inspect()
            if reload, !self.layeredWorkspace.selectedID.isEmpty {
                self.layeredWorkspace.load(try await self.call("workspace.get", arguments: ["workspaceId": .string(self.layeredWorkspace.selectedID)])["result"])
            }
            self.reportStatus("Layered workspace operation saved in the shared project history.")
        }
    }
    func saveLayeredWorkspace() {
        guard layeredWorkspace.dirty, !layeredWorkspace.isHistorical, !hasActiveWorkers, !layeredWorkspace.drawing else { return }
        let id = layeredWorkspace.selectedID, document = layeredWorkspace.document
        perform("Saving workspace draft…") {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("cellcounter-workspace-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            defer { try? FileManager.default.removeItem(at: directory) }
            let path = directory.appendingPathComponent("workspace.json")
            let data = try JSONEncoder().encode(document)
            guard data.count <= 32 * 1024 * 1024 else { throw WorkbenchFailure(code: "workspace-document-limit", message: "The workspace draft exceeds 32 MiB.") }
            try data.write(to: path, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
            _ = try await self.call("workspace.document.set", arguments: ["workspaceId": .string(id), "path": .string(path.path)], mutation: true)
            try await self.inspect()
            self.layeredWorkspace.load(try await self.call("workspace.get", arguments: ["workspaceId": .string(id)])["result"])
            self.reportStatus("Workspace draft saved as a new immutable version. Canonical source images and instance masks are unchanged.")
        }
    }
    func previewWorkspaceImport() {
        guard !layeredWorkspace.importPath.isEmpty, !layeredWorkspace.dirty else { return }
        perform("Previewing workspace import…") {
            self.layeredWorkspace.importPreview = try await self.call("workspace.import.preview", arguments: [
                "path": .string(self.layeredWorkspace.importPath), "format": .string(self.layeredWorkspace.importFormat)])["result"]
        }
    }
    func renderLayeredWorkspace() {
        guard !layeredWorkspace.dirty else { return }
        perform("Rendering saved workspace…") {
            let result = try await self.call("workspace.preview", arguments: ["workspaceId": .string(self.layeredWorkspace.selectedID), "width": .number(1024), "height": .number(768)])["result"]
            self.layeredWorkspace.preview = try self.decodePreview(result)
            self.layeredWorkspace.previewRevision = self.revision
        }
    }
    func loadWorkspacePaintSource(layerID: String? = nil) {
        let selectedLayer = layerID ?? layeredWorkspace.selectedLayerID
        guard !layeredWorkspace.dirty, !selectedLayer.isEmpty else { return }
        perform("Loading exact paint source…") {
            let state = self.layeredWorkspace
            let result = try await self.call("workspace.layer.preview", arguments: ["workspaceId": .string(state.selectedID), "layerId": .string(selectedLayer), "maxSize": .number(1024)])["result"]
            state.layerPreview = try self.decodePreview(result)
            state.layerGrid = CGSize(width: result["width"].number ?? 0, height: result["height"].number ?? 0)
            state.layerPreviewID = selectedLayer; state.layerPreviewRevision = self.revision
        }
    }
}
