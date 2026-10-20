import Foundation
import Observation

nonisolated struct WorkbenchSweepParameter: Identifiable, Sendable {
    let stepIndex: Int?
    let nodeID: String?
    let nodeName: String?
    let path: String
    let label: String
    let schema: WorkbenchJSON
    let currentValue: WorkbenchJSON
    let present: Bool
    let canOmit: Bool
    var id: String { nodeID.map { "node:\($0):\(path)" } ?? "step:\(stepIndex ?? 0):\(path)" }
    var locationLabel: String { nodeID.map { nodeName ?? $0 } ?? "Step \((stepIndex ?? 0) + 1)" }
    var isGraph: Bool { nodeID != nil }
    func axis(values: [WorkbenchJSON]) -> WorkbenchJSON {
        var result: [String: WorkbenchJSON] = ["path": .string(path), "values": .array(values)]
        if let nodeID { result["nodeId"] = .string(nodeID) }
        else if let stepIndex { result["stepIndex"] = .number(Double(stepIndex)) }
        return .object(result)
    }
    var field: WorkbenchPluginParameter {
        var schema = self.schema.object
        schema["title"] = .string(label)
        return WorkbenchPluginParameter(id: "value", schema: .object(schema), required: true)
    }
    var initialValue: WorkbenchJSON {
        present && currentValue != .null ? currentValue : field.initialValue
    }
    init?(_ value: WorkbenchJSON) {
        let step = value["stepIndex"].integer, node = value["nodeId"].string
        guard (step != nil) != (node != nil), let path = value["path"].string else { return nil }
        stepIndex = step; nodeID = node; nodeName = value["nodeName"].string; self.path = path
        label = value["label"].string ?? path
        schema = value["schema"]; currentValue = value["currentValue"]
        present = value["present"].bool == true
        canOmit = value["canOmit"].bool == true
    }
}

@MainActor @Observable
final class WorkbenchSweepState {
    var workflowID = ""
    var workflowVersion: Int?
    var parameters: [WorkbenchSweepParameter] = []
    var notes: [String] = []
    var preview: WorkbenchJSON?
    var previewArguments: WorkbenchJSON?
    var records: [WorkbenchJSON] = []
    var selectedID = ""
    var detail: WorkbenchJSON?
    var results: WorkbenchSweepResults?
    var exportFormats: [WorkbenchImageExportFormat] = []
    var exportResult: WorkbenchJSON?

    func resetDiscovery() {
        workflowID = ""; workflowVersion = nil; parameters = []; notes = []
        preview = nil; previewArguments = nil
    }
    func reset() {
        resetDiscovery(); records = []; selectedID = ""; detail = nil
        results = nil; exportFormats = []; exportResult = nil
    }
    func applyInspection(_ value: WorkbenchJSON) {
        guard value["sweeps"] != .null else { return }
        records = value["sweeps"].array
        if selectedID.isEmpty {
            selectedID = ""; detail = nil
        } else if var detail = detail?.object, let compact = records.first(where: { $0["id"].string == selectedID }) {
            for (key, value) in compact.object where key != "baseWorkflow" { detail[key] = value }
            self.detail = .object(detail)
        }
    }
}

extension WorkbenchSession {
    func loadSweepParameters(_ workflow: WorkbenchWorkflow) {
        sweeps.resetDiscovery()
        perform("Loading sweep parameters…", refreshOnConflict: false) {
            let result = try await self.call("sweep.parameters", arguments: [
                "workflowId": .string(workflow.id), "workflowVersion": .number(Double(workflow.version))
            ])["result"]
            self.sweeps.workflowID = result["workflow"]["id"].string ?? workflow.id
            self.sweeps.workflowVersion = result["workflow"]["version"].integer ?? workflow.version
            self.sweeps.parameters = result["candidatePaths"].array.compactMap(WorkbenchSweepParameter.init)
                .filter { $0.isGraph == workflow.isGraph }
            self.sweeps.notes = result["notes"].array.compactMap(\.string)
            self.reportStatus("Choose discovered parameter values, then preview the combinations.")
        }
    }

    func previewSweep(arguments: [String: WorkbenchJSON]) {
        sweeps.preview = nil; sweeps.previewArguments = nil
        perform("Previewing parameter combinations…", refreshOnConflict: false) {
            self.sweeps.preview = try await self.call("sweep.preview", arguments: arguments)["result"]
            self.sweeps.previewArguments = .object(arguments)
            self.reportStatus("Sweep preview ready. Each combination will use independent mask variants.")
        }
    }

    func createSweep(name: String, arguments: [String: WorkbenchJSON]) {
        guard sweeps.previewArguments == .object(arguments), !hasActiveWorkers, canRefreshWithoutDiscardingEdits else { return }
        var arguments = arguments
        arguments["name"] = .string(name)
        changeSweep("sweep.create", arguments: arguments, message: "Creating parameter sweep…")
    }

    func loadSweeps() {
        perform("Loading parameter sweeps…", refreshOnConflict: false) {
            try await self.readSweepList()
            if !self.sweeps.selectedID.isEmpty { try await self.readSelectedSweep() }
            self.reportStatus("Saved parameter sweeps loaded.")
        }
    }

    func selectSweep(_ id: String) {
        sweeps.selectedID = id; sweeps.detail = nil
        guard !id.isEmpty else { return }
        perform("Loading parameter sweep…", refreshOnConflict: false) {
            try await self.readSelectedSweep()
            self.reportStatus("Parameter sweep details loaded.")
        }
    }

    func changeSweep(_ id: String, action: String) {
        guard !hasActiveWorkers, canRefreshWithoutDiscardingEdits else { return }
        changeSweep("sweep.\(action)", arguments: ["sweepId": .string(id)],
                    message: action == "advance" ? "Completing one sweep checkpoint…" : "Updating parameter sweep…")
    }

    func startBackgroundSweep(_ sweepID: String) {
        guard !hasActiveWorkers, canRefreshWithoutDiscardingEdits else { return }
        perform("Starting background parameter sweep…", refreshOnConflict: false) {
            _ = try await self.call("sweep.worker.start", arguments: ["sweepId": .string(sweepID)], mutation: true)
            try await self.inspect()
            self.reportStatus("Background sweep started. It continues through remaining combinations after the app closes.")
        }
    }

    private func readSelectedSweep() async throws {
        sweeps.detail = try await call("sweep.get", arguments: ["sweepId": .string(sweeps.selectedID)])["result"]["sweep"]
    }

    func readSweepList() async throws {
        sweeps.records = try await readCatalogue("sweeps")
    }

    private func changeSweep(_ operation: String, arguments: [String: WorkbenchJSON], message: String) {
        perform(message, refreshOnConflict: false) {
            let sweep = try await self.call(operation, arguments: arguments, mutation: true)["result"]["sweep"]
            self.sweeps.selectedID = sweep["id"].string ?? ""
            self.sweeps.detail = sweep
            self.sweeps.preview = nil; self.sweeps.previewArguments = nil
            try await self.inspect()
            self.invalidateSummaries()
            self.reportStatus(operation == "sweep.create"
                ? "Sweep created. Original masks remain unchanged; variants have independent analysis jobs."
                : "Sweep checkpoint state saved.")
        }
    }
}
