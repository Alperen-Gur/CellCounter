import Foundation
import Observation

nonisolated struct WorkbenchGraphNodeType: Identifiable {
    let id: String
    let name: String
    let inputKinds: [String]
    let outputKind: String
    let schema: WorkbenchJSON
    let previewSupported: Bool
    init?(_ value: WorkbenchJSON) {
        guard let type = value["type"].string else { return nil }
        id = type; name = value["name"].string ?? type
        inputKinds = value["inputKinds"].array.compactMap(\.string)
        outputKind = value["outputKind"].string ?? ""
        schema = value["schema"]
        previewSupported = value["previewSupported"].bool == true
    }
}

struct WorkbenchGraphNodeDraft: Identifiable {
    var value: WorkbenchJSON
    let id: String
    var recipeSteps: [WorkbenchPreprocessingStep]
    var type: String { value["type"].string ?? "" }
    var name: String {
        get { value["name"].string ?? "" }
        set { set("name", .string(newValue)) }
    }
    var input: String {
        get { value["input"].string ?? "" }
        set { set("input", .string(newValue)) }
    }
    var inputs: [String] {
        get { value["inputs"].array.compactMap(\.string) }
        set { set("inputs", .array(newValue.map(WorkbenchJSON.string))) }
    }
    var recipe: [WorkbenchPreprocessingStep] {
        get { recipeSteps }
        set { recipeSteps = newValue; set("recipe", .array(newValue.map(\.json))) }
    }
    init?(_ value: WorkbenchJSON) {
        guard let id = value["id"].string else { return nil }
        self.id = id; self.value = value
        recipeSteps = value["recipe"].array.map {
            var fields = $0.object; fields.removeValue(forKey: "method")
            return WorkbenchPreprocessingStep(method: $0["method"].string ?? "", values: fields)
        }
    }
    mutating func set(_ key: String, _ newValue: WorkbenchJSON) {
        var fields = value.object; fields[key] = newValue; value = .object(fields)
    }
    /// The runtime resolves inherited acquisition selectors from the explicit input edge.
    /// Omit their previously normalized copies when a source connection changes.
    var json: WorkbenchJSON {
        var fields = value.object
        fields["name"] = name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : .string(name)
        if type == "analysis" {
            var parameters = fields["parameters"]?.object ?? [:]
            parameters.removeValue(forKey: "channel"); parameters.removeValue(forKey: "zProjection")
            fields["parameters"] = .object(parameters)
        }
        if ["volume-analysis", "plugin-segmentation", "model-segmentation"].contains(type) {
            fields.removeValue(forKey: "channel"); fields.removeValue(forKey: "target")
            fields.removeValue(forKey: "sourceParameters")
        }
        if type == "assay", ["nuclear_cytoplasmic", "neurite_outgrowth"].contains(fields["assay"]?.string ?? "") {
            var parameters = fields["assayParameters"]?.object ?? [:]
            parameters.removeValue(forKey: "nuclearImageId"); parameters.removeValue(forKey: "somaImageId")
            fields["assayParameters"] = .object(parameters)
        }
        return .object(fields)
    }
}

@MainActor @Observable
final class WorkbenchWorkflowGraphState {
    var nodeTypes: [WorkbenchGraphNodeType] = []
    var graphSchema: WorkbenchJSON = .null
    var limits: WorkbenchJSON = .null
    var notes: [String] = []
    var name = "Branching analysis"
    var target = "plane"
    var channel = 0
    var projection = "max"
    var nodes: [WorkbenchGraphNodeDraft] = []
    var loadedWorkflowID: String?
    var loadedVersion: Int?
    var selectedNodeID = ""
    var addType = "analysis"
    var preview: WorkbenchJSON?
    var previewArguments: WorkbenchJSON?
    var previewRevision: Int?
    var jobDetails: [String: WorkbenchJSON] = [:]
    var jobRevisions: [String: Int] = [:]
    var initialized = false
    var allTimePoints = true
    var errorNodeID: String?
    var nodePreview: WorkbenchJSON?
    var nodePreviewJobID = ""
    var nodePreviewNodeID = ""
    var nodePreviewCheckpointIndex = 0
    var nodePreviewRevision: Int?
    var nodePreviewGeneration = 0
    var nodePreviewError: String?
    var reviewRecords: [String: WorkbenchJSON] = [:]
    var reviewReasons: [String: String] = [:]
    var selectedReviewKeys: [String: String] = [:]
    var continuationDrafts: [String: WorkbenchGraphContinuationDraft] = [:]
    var graph: WorkbenchJSON {
        var fields: [String: WorkbenchJSON] = ["schemaVersion": .number(1), "target": .string(target),
            "nodes": .array(nodes.map(\.json))]
        if target == "volume" { fields["channel"] = .number(Double(channel)) }
        else { fields["sourceParameters"] = .object(["channel": .number(Double(channel)), "zProjection": .string(projection)]) }
        return .object(fields)
    }
    func configureCatalogue(_ result: WorkbenchJSON) {
        nodeTypes = result["nodeTypes"].array.compactMap(WorkbenchGraphNodeType.init)
        graphSchema = result["graphSchema"]; limits = result["limits"]
        notes = result["notes"].array.compactMap(\.string)
    }
    func load(_ workflow: WorkbenchWorkflow) {
        guard workflow.isGraph else { return }
        name = workflow.name; loadedWorkflowID = workflow.id; loadedVersion = workflow.version
        target = workflow.graph["target"].string ?? "plane"
        channel = target == "volume" ? workflow.graph["channel"].integer ?? 0
            : workflow.graph["sourceParameters"]["channel"].integer ?? 0
        projection = workflow.graph["sourceParameters"]["zProjection"].string ?? "max"
        nodes = workflow.graph["nodes"].array.compactMap(WorkbenchGraphNodeDraft.init)
        selectedNodeID = nodes.first?.id ?? ""; preview = nil; previewArguments = nil; previewRevision = nil
        initialized = true
        errorNodeID = nil
    }
    func outputKind(_ id: String, visiting: Set<String> = []) -> String {
        if id == "$source" { return "raw" }
        guard !visiting.contains(id), let node = nodes.first(where: { $0.id == id }) else { return "missing" }
        if node.type == "assay" {
            return outputKind(node.input, visiting: visiting.union([id])) == "analyzed" ? "analyzed" : "raw-measured"
        }
        return nodeTypes.first { $0.id == node.type }?.outputKind ?? "unknown"
    }
    func label(_ id: String) -> String {
        if id == "$source" { return "Source acquisition" }
        guard let node = nodes.first(where: { $0.id == id }) else { return "Missing source (\(id))" }
        return node.name.isEmpty ? (nodeTypes.first { $0.id == node.type }?.name ?? node.type) : node.name
    }
    func newID() -> String {
        var number = nodes.count + 1
        while nodes.contains(where: { $0.id == "node\(number)" }) { number += 1 }
        return "node\(number)"
    }
    func reset() {
        nodeTypes = []; graphSchema = .null; limits = .null; notes = []
        name = "Branching analysis"; target = "plane"; channel = 0; projection = "max"; nodes = []
        loadedWorkflowID = nil; loadedVersion = nil; selectedNodeID = ""; addType = "analysis"
        preview = nil; previewArguments = nil; previewRevision = nil; initialized = false
        jobDetails = [:]; jobRevisions = [:]
        allTimePoints = true; errorNodeID = nil
        nodePreview = nil; nodePreviewJobID = ""; nodePreviewNodeID = ""; nodePreviewCheckpointIndex = 0
        nodePreviewRevision = nil; nodePreviewGeneration += 1; nodePreviewError = nil
        reviewRecords = [:]; reviewReasons = [:]; selectedReviewKeys = [:]; continuationDrafts = [:]
    }
}

extension WorkbenchSession {
    func loadWorkflowGraphCatalogue() {
        perform("Loading branching workflow methods…", refreshOnConflict: false) {
            self.workflowGraph.configureCatalogue(try await self.call("workflow.graph.catalogue")["result"])
            self.reportStatus("Branching workflow methods loaded.")
        }
    }
    func seedWorkflowGraph() {
        let state = workflowGraph
        guard state.nodes.isEmpty else { return }
        state.target = viewingVolume ? "volume" : "plane"
        state.channel = viewingVolume ? volume.channel : channel; state.projection = projection
        var segmentation: [String: WorkbenchJSON] = ["id": .string("segment1"), "name": .string("Segmentation A"),
            "type": .string(viewingVolume ? "volume-analysis" : "analysis"), "input": .string("$source"),
            "parameters": viewingVolume ? volume.parameters : parameters]
        if !viewingVolume {
            var controls = parameters.object; controls.removeValue(forKey: "channel"); controls.removeValue(forKey: "zProjection")
            segmentation["parameters"] = .object(controls)
        }
        state.nodes = [
            .object(segmentation),
            .object(["id": .string("measure1"), "name": .string("Measurements A"), "type": .string("measurements"), "input": .string("segment1")]),
            .object(["id": .string("summary1"), "name": .string("Result summary"), "type": .string("summary"), "inputs": .array([.string("measure1")])])
        ].compactMap(WorkbenchGraphNodeDraft.init)
        state.selectedNodeID = "segment1"; state.initialized = true
    }
    func previewWorkflowGraph(arguments: [String: WorkbenchJSON]) {
        workflowGraph.preview = nil; workflowGraph.previewArguments = nil; workflowGraph.errorNodeID = nil
        perform("Previewing branching workflow…", refreshOnConflict: false) {
            let response: WorkbenchJSON
            do { response = try await self.call("workflow.graph.preview", arguments: arguments) }
            catch let failure as WorkbenchFailure {
                self.workflowGraph.errorNodeID = failure.details["nodeId"].string
                throw failure
            }
            self.workflowGraph.preview = response["result"]
            self.workflowGraph.previewArguments = .object(arguments)
            self.workflowGraph.previewRevision = response["revision"].integer ?? self.revision
            self.reportStatus("Branch relationships validated. Review the plan before saving a reusable version.")
        }
    }
    func saveWorkflowGraph(asNew: Bool, previewArguments: [String: WorkbenchJSON]) {
        let state = workflowGraph
        guard canRefreshWithoutDiscardingEdits, !hasActiveWorkers,
              state.previewArguments == .object(previewArguments), state.previewRevision == revision,
              state.preview != nil, !state.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              asNew || state.loadedWorkflowID != nil else { return }
        var arguments: [String: WorkbenchJSON] = ["name": .string(state.name.trimmingCharacters(in: .whitespacesAndNewlines)), "graph": state.graph]
        if !asNew, let id = state.loadedWorkflowID { arguments["workflowId"] = .string(id) }
        perform("Saving branching workflow…", refreshOnConflict: false) {
            let result = try await self.call("workflow.graph.save", arguments: arguments, mutation: true)["result"]
            guard let workflow = WorkbenchWorkflow(result["workflow"]), workflow.isGraph else {
                throw WorkbenchFailure(code: "invalid-response", message: "The branching workflow was saved, but its response could not be read. Refresh the workflow list before saving again.")
            }
            self.selectedWorkflowID = workflow.id
            state.load(workflow)
            try await self.inspect()
            self.reportStatus("Branching workflow version saved. Existing jobs retain their frozen workflow version.")
        }
    }
    func loadWorkflowGraphJob(_ id: String) {
        perform("Reading branch checkpoint bindings…", refreshOnConflict: false) {
            let response = try await self.readWorkflowJobSnapshot(id)
            self.workflowGraph.jobDetails[id] = response["result"]["job"]
            self.workflowGraph.jobRevisions[id] = response["revision"].integer
            self.reportStatus("Branch checkpoints loaded with their exact source and output bindings.")
        }
    }
    func loadWorkflowGraphVersion(_ id: String, version: Int) {
        perform("Loading branching workflow version…", refreshOnConflict: false) {
            let result = try await self.call("workflow.get", arguments: [
                "workflowId": .string(id), "version": .number(Double(version))])["result"]
            guard let workflow = WorkbenchWorkflow(result["workflow"]), workflow.isGraph else {
                throw WorkbenchFailure(code: "unsupported-workflow", message: "This version is a linear workflow. Select it in the Linear workflow builder.")
            }
            self.workflowGraph.load(workflow)
            self.reportStatus("Workflow version loaded for editing. Saving a version preserves all earlier definitions and jobs.")
        }
    }
    func previewWorkflowGraphNode(jobID: String, checkpointIndex: Int, nodeID: String) {
        guard !busy else { return }
        workflowGraph.nodePreview = nil; workflowGraph.nodePreviewJobID = jobID; workflowGraph.nodePreviewError = nil
        workflowGraph.nodePreviewNodeID = nodeID; workflowGraph.nodePreviewCheckpointIndex = checkpointIndex
        perform("Calculating branch node preview…", refreshOnConflict: false) {
            do {
                let response = try await self.readWorkflowNodePreviewSnapshot(arguments: [
                    "jobId": .string(jobID), "checkpointIndex": .number(Double(checkpointIndex)),
                    "nodeId": .string(nodeID), "maxSize": .number(768)])
                self.workflowGraph.nodePreview = response["result"]
                self.workflowGraph.nodePreviewRevision = response["revision"].integer
                self.workflowGraph.nodePreviewGeneration += 1
                self.reportStatus("Node preview calculated from its retained input. No checkpoint or branch output was changed.")
            } catch let failure as WorkbenchFailure {
                self.workflowGraph.nodePreviewError = failure.message
                throw failure
            }
        }
    }
    func openWorkflowGraphOutput(jobID: String, checkpointIndex: Int, nodeID: String,
                                 completion: @escaping @MainActor () -> Void) {
        guard !busy, !hasActiveWorkers, canRefreshWithoutDiscardingEdits else { return }
        perform("Opening retained branch output…", refreshOnConflict: false) {
            let job = try await self.call("job.get", arguments: ["jobId": .string(jobID)])["result"]["job"]
            guard job["outputsCurrent"].bool != false,
                  job["checkpoints"].array.indices.contains(checkpointIndex),
                  let saved = job["checkpoints"].array[checkpointIndex]["nodes"].array.first(where: { $0["nodeId"].string == nodeID }),
                  let imageID = saved["outputBinding"]["imageId"].string else {
                throw WorkbenchFailure(code: "branch-output-unavailable", message: "This branch output is unavailable or changed. Refresh the project and branch details before opening it.")
            }
            let image = try await self.resolveImage(imageID)
            let selection = saved["outputBinding"]["selection"]
            self.selectedImageID = imageID
            self.volume.configure(for: image)
            self.viewingVolume = selection["target"].string == "volume"
            if self.viewingVolume {
                self.volume.timeIndex = selection["timeIndex"].integer ?? 0
                self.volume.channel = selection["channel"].integer ?? 0
            }
            try await self.loadImage()
            self.reportStatus("Retained branch output opened with its saved source selection.")
            completion()
        }
    }
}
