import Foundation

nonisolated struct WorkbenchWorkflow: Identifiable, Sendable {
    let id: String
    let name: String
    let version: Int
    let steps: [WorkbenchJSON]
    let kind: String
    let graph: WorkbenchJSON
    var isGraph: Bool { kind == "dag" }
    var exportsPackage: Bool { (isGraph ? graph["nodes"].array : steps).contains { $0["type"].string == "export" } }
    var analyzesVolumes: Bool {
        if isGraph { return graph["target"].string == "volume" }
        guard let step = segmentationStep else { return false }
        return step["type"].string == "volume-analysis" || step["target"].string == "volume"
    }
    var segmentationStep: WorkbenchJSON? {
        steps.first { ["analysis", "volume-analysis", "plugin-segmentation", "model-segmentation"].contains($0["type"].string ?? "") }
    }

    init?(_ value: WorkbenchJSON) {
        guard let id = value["id"].string else { return nil }
        self.id = id
        name = value["name"].string ?? "Workflow"
        version = value["version"].integer ?? 1
        steps = value["steps"].array
        kind = value["kind"].string ?? "linear"
        graph = value["graph"]
    }
}

nonisolated struct WorkbenchJob: Identifiable, Sendable {
    let id: String
    let name: String
    let status: String
    let completed: Int
    let total: Int
    let nextType: String?
    let nextImageID: String?
    let nextTimeIndex: Int?
    let nextChannel: Int?
    let nextStepIndex: Int?
    let nextWorkingImageID: String?
    let nextWorkingSelection: WorkbenchJSON
    let workingImageIDs: [String]
    let sourceImageIDs: [String]
    let error: String?
    let errorDetails: WorkbenchJSON
    let errorUnit: WorkbenchJSON
    let outputsCurrent: Bool
    let kind: String
    let graph: WorkbenchJSON
    let nodeProgress: [WorkbenchJSON]
    let staleNodeIDs: [String]
    let nextNodeID: String?
    let nextNodeType: String?
    let pendingReview: WorkbenchJSON
    let continuation: WorkbenchJSON
    var isGraph: Bool { kind == "dag" }
    var canAdvance: Bool { ["pending", "running"].contains(status) }
    var canCancel: Bool { ["pending", "running", "paused", "blocked", "failed", "awaiting-review"].contains(status) }

    init?(_ value: WorkbenchJSON) {
        guard let id = value["id"].string else { return nil }
        self.id = id
        kind = value["kind"].string ?? "linear"
        graph = value["workflow"]["graph"]
        nodeProgress = value["nodeProgress"].array
        staleNodeIDs = value["staleNodeIds"].array.compactMap { $0.string ?? $0["nodeId"].string }
        nextNodeID = value["nextUnit"]["nodeId"].string
        nextNodeType = value["nextUnit"]["nodeType"].string
        pendingReview = value["pendingReview"]
        continuation = value["continuation"]
        name = value["name"].string ?? "Analysis job"
        status = value["status"].string ?? "pending"
        completed = value["progress"]["completed"].integer ?? 0
        total = max(1, value["progress"]["total"].integer ?? 1)
        nextType = value["nextUnit"]["type"].string
        nextImageID = value["nextUnit"]["imageId"].string
        nextTimeIndex = value["nextUnit"]["timeIndex"].integer
        nextChannel = value["nextUnit"]["channel"].integer
        nextStepIndex = value["nextUnit"]["stepIndex"].integer
        nextWorkingImageID = value["nextUnit"]["workingImageId"].string
        nextWorkingSelection = value["nextUnit"]["workingSelection"]
        workingImageIDs = value["workingImageIds"].array.compactMap(\.string)
        sourceImageIDs = value["imageIds"].array.compactMap(\.string)
        error = value["error"]["message"].string ?? value["error"].string
        errorDetails = value["error"]["details"]
        errorUnit = value["error"]["unit"]
        if case .bool(false) = value["outputsCurrent"] { outputsCurrent = false }
        else { outputsCurrent = true }
    }
}

nonisolated struct WorkbenchSpecimen: Identifiable, Sendable {
    let id: String
    let name: String
    let experiment: String
    let condition: String
    let role: String

    init?(_ value: WorkbenchJSON) {
        guard let id = value["id"].string else { return nil }
        self.id = id
        name = value["name"].string ?? ""
        experiment = value["experiment"].string ?? ""
        condition = value["condition"].string ?? ""
        role = value["role"].string ?? "other"
    }
}

nonisolated struct WorkbenchPlate: Identifiable, Sendable {
    let id: String
    let name: String
    let rows: Int
    let columns: Int

    init?(_ value: WorkbenchJSON) {
        guard let id = value["id"].string else { return nil }
        self.id = id
        name = value["name"].string ?? ""
        rows = max(1, value["rows"].integer ?? 1)
        columns = max(1, value["columns"].integer ?? 1)
    }
}

nonisolated struct WorkbenchAssignment: Sendable {
    let imageID: String
    let specimenID: String
    let plateID: String?
    let wellRow: Int?
    let wellColumn: Int?
    let field: String?

    init?(_ value: WorkbenchJSON) {
        guard let imageID = value["imageId"].string, let specimenID = value["specimenId"].string else { return nil }
        self.imageID = imageID
        self.specimenID = specimenID
        plateID = value["plateId"].string
        wellRow = value["wellRow"].integer
        wellColumn = value["wellColumn"].integer
        field = value["field"].string
    }
}
