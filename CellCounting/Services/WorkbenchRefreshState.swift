import Foundation
import Observation

nonisolated struct WorkbenchRefreshOutput: Identifiable {
    let value: WorkbenchJSON
    let id: String
    let kind: String
    let runID: String
    let imageID: String
    let imageName: String
    let label: String
    let status: String
    let freshness: String
    let latest: Bool
    let recomputable: Bool
    var runRef: WorkbenchJSON { .object(["kind": .string(kind), "runId": .string(runID)]) }
    var messages: [String] { (value["reasons"].array + value["blockers"].array).compactMap { $0["message"].string } }
    init?(_ value: WorkbenchJSON) {
        guard let kind = value["kind"].string, let runID = value["runId"].string else { return nil }
        self.value = value; self.kind = kind; self.runID = runID; id = "\(kind):\(runID)"
        imageID = value["imageId"].string ?? ""; imageName = value["imageName"].string ?? "Image"
        label = value["label"].string ?? ["assay-series": "Scratch-wound series", "assay": "Assay", "plugin-measurement": "Plugin measurement", "derived-image": "Derived image", "tracks": "Tracking", "lineage": "Lineage", "statistics": "Statistics"][kind] ?? "Saved result"
        status = value["status"].string ?? "blocked"; freshness = value["freshness"].string ?? "stale"
        latest = value["latest"].bool != false; recomputable = value["recomputable"].bool == true
    }
}

nonisolated struct WorkbenchRefreshJob: Identifiable {
    let value: WorkbenchJSON
    let id: String
    let name: String
    let status: String
    let completed: Int
    let total: Int
    let outputsCurrent: Bool
    let skippedCount: Int
    var canAdvance: Bool { ["pending", "running"].contains(status) }
    var canCancel: Bool { ["pending", "running", "paused", "blocked", "failed"].contains(status) }
    init?(_ value: WorkbenchJSON) {
        guard let id = value["id"].string else { return nil }
        self.value = value; self.id = id; name = value["name"].string ?? "Result refresh"
        status = value["status"].string ?? "pending"
        completed = value["progress"]["completed"].integer ?? 0
        total = max(1, value["progress"]["total"].integer ?? 1)
        outputsCurrent = value["outputsCurrent"].bool != false
        skippedCount = value["skippedCount"].integer ?? value["skipped"].array.count
    }
}

@MainActor @Observable
final class WorkbenchRefreshState {
    var scope = "image"
    var dependencyMode = "transitive"
    var includeHistory = false
    var includeCurrent = false
    var outputs: [WorkbenchRefreshOutput] = []
    var unhandled: [WorkbenchJSON] = []
    var counts: WorkbenchJSON = .null
    var notes: [String] = []
    var scanArguments: WorkbenchJSON?
    var scanRevision: Int?
    var selectedOutputIDs: Set<String> = []
    var plan: WorkbenchJSON?
    var planArguments: WorkbenchJSON?
    var previewFingerprint: String?
    var planRevision: Int?
    var name = "Refresh saved results"
    var skipBlocked = false
    var jobs: [WorkbenchRefreshJob] = []
    var selectedJobID = ""
    var selectedDetail: WorkbenchRefreshJob?
    var report: WorkbenchJSON?
    var exportFormats: [WorkbenchImageExportFormat] = []
    var exportFormat = "results-csv"
    var exportResult: WorkbenchJSON?
    var selectedJob: WorkbenchRefreshJob? { jobs.first { $0.id == selectedJobID } ?? selectedDetail }
    var selectedOutputs: [WorkbenchRefreshOutput] {
        outputs.filter { selectedOutputIDs.contains($0.id) && (includeCurrent || $0.freshness == "stale") }
    }
    func applyInspection(_ value: WorkbenchJSON) {
        jobs = value["refreshJobs"].array.compactMap(WorkbenchRefreshJob.init)
        if selectedJobID.isEmpty {
            selectedJobID = jobs.last?.id ?? ""; selectedDetail = nil
        }
    }
    func applyScan(_ response: WorkbenchJSON, arguments: [String: WorkbenchJSON]) {
        let result = response["result"]
        let sameScope = scanArguments == .object(arguments)
        outputs = result["outputs"].array.compactMap(WorkbenchRefreshOutput.init)
        unhandled = result["unhandled"].array; counts = result["counts"]
        notes = result["notes"].array.compactMap(\.string)
        scanRevision = response["revision"].integer ?? result["sourceRevision"].integer
        scanArguments = .object(arguments)
        if sameScope { selectedOutputIDs.formIntersection(Set(outputs.map(\.id))) }
        else { selectedOutputIDs = Set(outputs.filter { $0.latest && $0.freshness == "stale" }.map(\.id)) }
    }
    func select(_ job: WorkbenchRefreshJob) {
        selectedJobID = job.id; selectedDetail = job
        report = nil
        jobs.removeAll { $0.id == job.id }; jobs.append(job)
    }
    func reset() {
        scope = "image"; dependencyMode = "transitive"; includeHistory = false; includeCurrent = false; outputs = []; unhandled = []
        counts = .null; notes = []; scanArguments = nil; scanRevision = nil; selectedOutputIDs = []
        plan = nil; planArguments = nil; previewFingerprint = nil; planRevision = nil
        name = "Refresh saved results"; skipBlocked = false; jobs = []; selectedJobID = ""; selectedDetail = nil; report = nil
        exportFormats = []; exportFormat = "results-csv"; exportResult = nil
    }
}

extension WorkbenchSession {
    func inspectResultFreshness(arguments: [String: WorkbenchJSON]) {
        perform("Reading saved result freshness…", refreshOnConflict: false) {
            let response = try await self.readRefreshSnapshot("refresh.inspect", arguments: arguments)
            self.resultRefresh.applyScan(response, arguments: arguments)
            if self.resultRefresh.exportFormats.isEmpty {
                self.resultRefresh.exportFormats = try await self.readRefreshSnapshot("refresh.export.catalogue", arguments: [:])["result"]["formats"].array.compactMap(WorkbenchImageExportFormat.init)
            }
            self.reportStatus("Saved result freshness loaded. Scientific drafts are preserved.")
        }
    }
    func previewResultRefresh(arguments: [String: WorkbenchJSON]) {
        perform("Planning result recomputation…", refreshOnConflict: false) {
            let response = try await self.readRefreshSnapshot("refresh.preview", arguments: arguments)
            self.resultRefresh.plan = response["result"]["plan"]
            self.resultRefresh.planArguments = .object(arguments)
            self.resultRefresh.previewFingerprint = response["result"]["previewFingerprint"].string
            self.resultRefresh.planRevision = response["revision"].integer ?? response["result"]["plan"]["sourceRevision"].integer
            self.resultRefresh.skipBlocked = false
            self.reportStatus("Refresh plan ready. Review ready outputs and blockers before creating checkpoints.")
        }
    }
    func createResultRefresh(arguments: [String: WorkbenchJSON]) {
        let state = resultRefresh
        guard canRefreshWithoutDiscardingEdits, !hasActiveWorkers, state.planRevision == revision,
              state.planArguments == .object(arguments), let fingerprint = state.previewFingerprint,
              (state.plan?["readyCount"].integer ?? 0) > 0,
              (state.plan?["blockedCount"].integer ?? 0) == 0 || state.skipBlocked else { return }
        var values = arguments
        values["previewFingerprint"] = .string(fingerprint); values["skipBlocked"] = .bool(state.skipBlocked)
        let name = state.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty { values["name"] = .string(name) }
        perform("Creating result refresh checkpoints…", refreshOnConflict: false) {
            let result = try await self.call("refresh.create", arguments: values, mutation: true)["result"]
            guard let job = WorkbenchRefreshJob(result["refresh"]) else {
                throw WorkbenchFailure(code: "invalid-response", message: "The result refresh was created, but its details could not be read. Refresh the job list before creating another.")
            }
            state.select(job)
            try await self.inspect()
            state.plan = nil; state.previewFingerprint = nil; state.planArguments = nil
            self.reportStatus("Result refresh created. Run one checkpoint or start the background worker.")
        }
    }
    func loadResultRefresh(_ id: String) {
        guard !id.isEmpty else { return }
        perform("Reading result refresh checkpoints…", refreshOnConflict: false) {
            let result = try await self.readRefreshSnapshot("refresh.results", arguments: ["refreshId": .string(id)])["result"]
            if let job = WorkbenchRefreshJob(result["refresh"]) { self.resultRefresh.select(job) }
            self.resultRefresh.report = result
            self.reportStatus("Result refresh details loaded.")
        }
    }
    func listResultRefreshes() {
        perform("Reading result refresh history…", refreshOnConflict: false) {
            let result = try await self.readRefreshSnapshot("refresh.list", arguments: [:])["result"]
            self.resultRefresh.jobs = result["refreshes"].array.compactMap(WorkbenchRefreshJob.init)
            self.reportStatus("Result refresh history loaded.")
        }
    }
    func controlResultRefresh(_ id: String, action: String) {
        guard canRefreshWithoutDiscardingEdits, !hasActiveWorkers,
              ["advance", "pause", "resume", "retry", "cancel"].contains(action) else { return }
        perform(action == "advance" ? "Recomputing next saved result…" : "Updating result refresh…", refreshOnConflict: false) {
            let result = try await self.call("refresh.\(action)", arguments: ["refreshId": .string(id)], mutation: true)["result"]
            if let job = WorkbenchRefreshJob(result["refresh"]) { self.resultRefresh.select(job) }
            try await self.inspect()
            self.invalidateSummaries()
            self.reportStatus(action == "advance"
                ? "Replacement checkpoint saved. Original acquisitions, corrections and predecessor results are retained."
                : "Result refresh updated.")
        }
    }
    func startBackgroundResultRefresh(_ id: String) {
        guard canRefreshWithoutDiscardingEdits, !hasActiveWorkers else { return }
        perform("Starting background result refresh…", refreshOnConflict: false) {
            _ = try await self.call("refresh.worker.start", arguments: ["refreshId": .string(id)], mutation: true)
            try await self.inspect()
            self.reportStatus("Result refresh started in the background. Stop after the current checkpoint to preserve completed replacements.")
        }
    }
    func exportResultRefresh(to destination: URL) {
        guard canRefreshWithoutDiscardingEdits, !hasActiveWorkers, !resultRefresh.selectedJobID.isEmpty else { return }
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            error = "Choose a new filename. Refresh reports preserve existing files."; return
        }
        let id = resultRefresh.selectedJobID
        let format = resultRefresh.exportFormat
        perform("Exporting result refresh report…", refreshOnConflict: false) {
            self.resultRefresh.exportResult = try await self.call("refresh.export", arguments: [
                "refreshId": .string(id), "format": .string(format), "destination": .string(destination.path)
            ], mutation: true)["result"]
            try await self.inspect()
            self.reportStatus("Refresh report exported with predecessor and replacement provenance.")
        }
    }
}
