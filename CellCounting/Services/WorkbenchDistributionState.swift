import Foundation
import Observation

nonisolated struct WorkbenchDistributedTask: Identifiable {
    let value: WorkbenchJSON
    let id: String
    let index: Int
    let sourceImageID: String
    let imageID: String
    let target: String
    let timeIndex: Int?
    let channel: Int?
    let status: String
    init?(_ value: WorkbenchJSON) {
        guard let id = value["id"].string else { return nil }
        self.value = value; self.id = id
        index = value["index"].integer ?? 0
        sourceImageID = value["sourceImageId"].string ?? ""
        imageID = value["imageId"].string ?? ""
        target = value["target"].string ?? "plane"
        timeIndex = value["timeIndex"].integer; channel = value["channel"].integer
        status = value["status"].string ?? "pending"
    }
}

nonisolated struct WorkbenchDistribution: Identifiable {
    let value: WorkbenchJSON
    let id: String
    let name: String
    let taskCount: Int
    let collectedCount: Int
    let status: String
    let sourceInputsCurrent: Bool
    var tasks: [WorkbenchDistributedTask] { value["tasks"].array.compactMap(WorkbenchDistributedTask.init) }
    init?(_ value: WorkbenchJSON) {
        guard let id = value["id"].string else { return nil }
        self.value = value; self.id = id
        name = value["name"].string ?? "Distributed work"
        taskCount = value["taskCount"].integer ?? 0
        collectedCount = value["collectedCount"].integer ?? 0
        status = value["status"].string ?? "pending"
        sourceInputsCurrent = value["sourceInputsCurrent"].bool != false
    }
}

@MainActor @Observable
final class WorkbenchDistributionState {
    var groups: [WorkbenchDistribution] = []
    var selectedID = ""
    var detail: WorkbenchDistribution?
    var selectedTaskID: String?
    var name = "Distributed analysis"
    var plan: WorkbenchJSON?
    var planArguments: WorkbenchJSON?
    var planRevision: Int?
    var localTask: WorkbenchJSON?
    var allowRuntimeDifferences = false
    var taskExportDestination: URL?
    var resultPreview: WorkbenchJSON?
    var resultPath = ""
    var resultDistributionID = ""
    var resultTaskID = ""
    var resultRevision: Int?
    var lastExportPath: String?
    var message = ""
    var selectedTask: WorkbenchDistributedTask? { detail?.tasks.first { $0.id == selectedTaskID } }
    var currentGroup: WorkbenchDistribution? { groups.first { $0.id == selectedID } ?? detail }
    var localJob: WorkbenchJob? { localTask.flatMap { WorkbenchJob($0["job"]) } }

    func applyInspection(_ value: WorkbenchJSON) {
        groups = value["distributions"].array.compactMap(WorkbenchDistribution.init)
        let task = value["distributedTask"]
        if task["id"].string != localTask?["id"].string {
            allowRuntimeDifferences = false; taskExportDestination = nil
        }
        localTask = task["id"].string == nil ? nil : task
        if selectedID.isEmpty && detail == nil {
            selectedID = ""; detail = nil; selectedTaskID = nil
        }
    }
    func select(_ group: WorkbenchDistribution) {
        let changed = selectedID != group.id
        selectedID = group.id; detail = group
        groups.removeAll { $0.id == group.id }; groups.append(group)
        if changed || !group.tasks.contains(where: { $0.id == selectedTaskID }) {
            selectedTaskID = group.tasks.first?.id
        }
    }
    func reset() {
        groups = []; selectedID = ""; detail = nil; selectedTaskID = nil; name = "Distributed analysis"
        plan = nil; planArguments = nil; planRevision = nil; localTask = nil
        allowRuntimeDifferences = false; taskExportDestination = nil
        resultPreview = nil; resultPath = ""; resultDistributionID = ""; resultTaskID = ""; resultRevision = nil
        lastExportPath = nil; message = ""
    }
}

extension WorkbenchSession {
    func previewDistribution(arguments: [String: WorkbenchJSON]) {
        perform("Planning distributed work…", refreshOnConflict: false) {
            let response = try await self.call("distribution.preview", arguments: arguments)
            self.distribution.plan = response["result"]["plan"]
            self.distribution.planArguments = .object(arguments)
            self.distribution.planRevision = response["revision"].integer ?? self.revision
            self.reportStatus("Work packet plan ready. Review it before creating the distribution.")
        }
    }
    func createDistribution(arguments: [String: WorkbenchJSON]) {
        guard canRefreshWithoutDiscardingEdits, !hasActiveWorkers,
              distribution.planRevision == revision, distribution.planArguments == .object(arguments),
              !distribution.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        var values = arguments
        values["name"] = .string(distribution.name.trimmingCharacters(in: .whitespacesAndNewlines))
        perform("Creating distributed work…", refreshOnConflict: false) {
            let result = try await self.call("distribution.create", arguments: values, mutation: true)["result"]
            guard let group = WorkbenchDistribution(result["distribution"]) else {
                throw WorkbenchFailure(code: "invalid-response", message: "The distribution was created, but its details could not be read. Refresh workflows before creating another.")
            }
            self.distribution.select(group)
            try await self.inspect()
            self.distribution.plan = nil; self.distribution.planArguments = nil; self.distribution.planRevision = nil
            self.reportStatus("Distribution created. Export a separate bundle for each task.")
        }
    }
    func loadDistribution(_ id: String) {
        guard !id.isEmpty else { return }
        perform("Loading distributed work…", refreshOnConflict: false) {
            let result = try await self.call("distribution.get", arguments: ["distributionId": .string(id)])["result"]
            guard let group = WorkbenchDistribution(result["distribution"]) else {
                throw WorkbenchFailure(code: "invalid-response", message: "The distribution could not be read. Refresh workflows and select it again.")
            }
            self.distribution.select(group)
            self.reportStatus("Distributed work loaded.")
        }
    }
    func exportDistributionTask(to destination: URL, collected: Bool) {
        guard canRefreshWithoutDiscardingEdits, !hasActiveWorkers,
              let task = distribution.selectedTask, let group = distribution.detail else { return }
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            error = "Choose a new filename. Distributed work exports preserve existing files."; return
        }
        let operation = collected ? "distribution.result.export" : "distribution.bundle.export"
        perform(collected ? "Exporting collected result…" : "Exporting work task bundle…", refreshOnConflict: false) {
            let result = try await self.call(operation, arguments: [
                "distributionId": .string(group.id), "taskId": .string(task.id),
                "destination": .string(destination.path)
            ], mutation: true)["result"]
            self.distribution.lastExportPath = result["destination"].string ?? destination.path
            try await self.inspect()
            let refreshed = try await self.call("distribution.get", arguments: ["distributionId": .string(group.id)])["result"]
            if let updated = WorkbenchDistribution(refreshed["distribution"]) { self.distribution.select(updated) }
            self.reportStatus(collected
                ? "Collected result exported. Restore it as a separate project to inspect its analysis."
                : "Task bundle exported. Restore it as a new project on the worker machine.")
        }
    }
    func previewDistributedResult(at url: URL) {
        guard let task = distribution.selectedTask, let group = distribution.detail else { return }
        perform("Previewing returned task result…", refreshOnConflict: false) {
            self.distribution.resultPreview = nil
            let response = try await self.call("distribution.result.preview", arguments: [
                "distributionId": .string(group.id), "taskId": .string(task.id), "path": .string(url.path)
            ])
            let result = response["result"]
            guard result["previewFingerprint"].string != nil else {
                throw WorkbenchFailure(code: "invalid-response", message: "The returned result could not be previewed. Choose the final package exported after this task's job completed.")
            }
            self.distribution.resultPreview = result
            self.distribution.resultPath = url.path
            self.distribution.resultDistributionID = group.id
            self.distribution.resultTaskID = task.id
            self.distribution.resultRevision = response["revision"].integer ?? self.revision
            self.reportStatus("Returned result validated for collection as an isolated project.")
        }
    }
    func collectDistributedResult() {
        let state = distribution
        guard canRefreshWithoutDiscardingEdits, !hasActiveWorkers, state.resultRevision == revision,
              state.resultDistributionID == state.selectedID, state.resultTaskID == state.selectedTaskID,
              let fingerprint = state.resultPreview?["previewFingerprint"].string else { return }
        let arguments: [String: WorkbenchJSON] = [
            "distributionId": .string(state.resultDistributionID), "taskId": .string(state.resultTaskID),
            "path": .string(state.resultPath), "previewFingerprint": .string(fingerprint)
        ]
        perform("Collecting isolated task result…", refreshOnConflict: false) {
            let result = try await self.call("distribution.result.collect", arguments: arguments, mutation: true)["result"]
            if let group = WorkbenchDistribution(result["distribution"]) { state.select(group) }
            try await self.inspect()
            state.resultPreview = nil; state.resultPath = ""; state.resultRevision = nil
            state.message = "Result collected as an isolated project. Original masks and biological assignments are unchanged."
            self.reportStatus(state.message)
        }
    }
    func prepareDistributedTask() {
        guard canRefreshWithoutDiscardingEdits, !hasActiveWorkers,
              let task = distribution.localTask, task["prepared"].bool != true else { return }
        var arguments: [String: WorkbenchJSON] = ["allowRuntimeDifferences": .bool(distribution.allowRuntimeDifferences)]
        if let destination = distribution.taskExportDestination { arguments["exportDestination"] = .string(destination.path) }
        perform("Preparing restored work task…", refreshOnConflict: false) {
            let result = try await self.call("distribution.task.prepare", arguments: arguments, mutation: true)["result"]
            self.distribution.localTask = result["task"]
            try await self.inspect()
            self.reportStatus("Runnable job prepared. Use the existing job controls to run or resume it.")
        }
    }
}
