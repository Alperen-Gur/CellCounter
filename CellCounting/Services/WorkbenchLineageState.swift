import Foundation
import Observation

@MainActor @Observable
final class WorkbenchLineageState {
    var graph: WorkbenchJSON?
    var suggestions: WorkbenchJSON?
    var selectedNodeID = ""
    var selectedLineageID = ""
    var parentTime = 1
    var parentLabel = 1
    var daughterTime = 2
    var daughterOne = 1
    var daughterTwo = 2
    var targetLabel = 1
    var replaceExisting = false
    var reason = ""
    var maximumDistance = 20.0
    var distanceUnits = "voxel"
    var minimumRatio = 0.5
    var maximumRatio = 2.0
    var editorOpen = false
    var savedCorrectionDraft: WorkbenchJSON?
    var exportFormats: [WorkbenchImageExportFormat] = []
    var exportFormatID = "graph-json"
    var exportResult: WorkbenchJSON?
    var correctionDraft: WorkbenchJSON {
        .object(["parentTime": .number(Double(parentTime)), "parentLabel": .number(Double(parentLabel)),
            "daughterTime": .number(Double(daughterTime)), "daughterOne": .number(Double(daughterOne)),
            "daughterTwo": .number(Double(daughterTwo)), "targetLabel": .number(Double(targetLabel)),
            "replaceExisting": .bool(replaceExisting), "reason": .string(reason)])
    }
    var hasUnsavedCorrection: Bool { savedCorrectionDraft != nil && savedCorrectionDraft != correctionDraft }
    var selectedNode: WorkbenchJSON? {
        graph?["nodes"].array.first { $0["id"].string == selectedNodeID }
    }
    var status: String { graph?["status"].string ?? "none" }
    func reset() {
        graph = nil; suggestions = nil; selectedNodeID = ""; selectedLineageID = ""
        reason = ""; replaceExisting = false
        savedCorrectionDraft = nil
        exportFormats = []; exportResult = nil
    }
    func apply(_ result: WorkbenchJSON, acceptsDraft: Bool = false) {
        graph = result
        if !result["nodes"].array.contains(where: { $0["id"].string == selectedNodeID }) {
            selectedNodeID = result["nodes"].array.first?["id"].string ?? ""
        }
        if !result["lineages"].array.contains(where: { $0["id"].string == selectedLineageID }) {
            selectedLineageID = result["lineages"].array.first?["id"].string ?? ""
        }
        if acceptsDraft || savedCorrectionDraft == nil { savedCorrectionDraft = correctionDraft }
    }
    func discardCorrectionDraft() {
        guard let saved = savedCorrectionDraft else { return }
        parentTime = saved["parentTime"].integer ?? 1
        parentLabel = saved["parentLabel"].integer ?? 1
        daughterTime = saved["daughterTime"].integer ?? 2
        daughterOne = saved["daughterOne"].integer ?? 1
        daughterTwo = saved["daughterTwo"].integer ?? 2
        targetLabel = saved["targetLabel"].integer ?? 1
        replaceExisting = saved["replaceExisting"].bool == true
        reason = saved["reason"].string ?? ""
    }
}

extension WorkbenchSession {
    func loadLineage() {
        guard !volume.imageID.isEmpty else { return }
        perform("Loading lineage graph…") {
            if self.lineage.graph?["imageId"].string != self.volume.imageID ||
                self.lineage.graph?["channel"].integer != self.volume.channel {
                self.lineage.reset()
            }
            try await self.inspect()
            let result = try await self.call("lineage.get", arguments: self.lineageSelection)["result"]
            self.lineage.apply(result)
            self.lineage.exportFormats = try await self.call("lineage.export.catalogue")["result"]["formats"].array
                .compactMap(WorkbenchImageExportFormat.init)
            self.lineage.suggestions = nil
            self.reportStatus("Lineage graph loaded.")
        }
    }
    func initializeLineage() {
        var args = lineageSelection
        let reason = lineage.reason.trimmingCharacters(in: .whitespacesAndNewlines)
        if !reason.isEmpty { args["reason"] = .string(reason) }
        changeLineage("lineage.initialize", arguments: args, message: "Initializing lineage from current tracking…")
    }
    func saveLineageDivision() {
        var args = lineageSelection
        args.merge([
            "parentTimeIndex": .number(Double(lineage.parentTime - 1)),
            "parentLabelId": .number(Double(lineage.parentLabel)),
            "daughterTimeIndex": .number(Double(lineage.daughterTime - 1)),
            "daughterLabelIds": .array([.number(Double(lineage.daughterOne)), .number(Double(lineage.daughterTwo))]),
            "replaceExisting": .bool(lineage.replaceExisting), "reason": .string(lineage.reason)
        ]) { _, new in new }
        changeLineage("lineage.division.set", arguments: args, message: "Saving reviewed division…")
    }
    func removeLineageDivision(_ id: String) {
        var args = lineageSelection
        args["divisionId"] = .string(id); args["reason"] = .string(lineage.reason)
        changeLineage("lineage.division.remove", arguments: args, message: "Removing division…")
    }
    func correctLineageLink(link: Bool) {
        var args = lineageSelection
        args.merge([
            "sourceTimeIndex": .number(Double(lineage.parentTime - 1)),
            "sourceLabelId": .number(Double(lineage.parentLabel)),
            "targetTimeIndex": .number(Double(lineage.daughterTime - 1)),
            "targetLabelId": .number(Double(lineage.targetLabel)),
            "reason": .string(lineage.reason)
        ]) { _, new in new }
        changeLineage(link ? "lineage.link" : "lineage.unlink", arguments: args, message: "Saving lineage link correction…")
    }
    func undoLineage() {
        var args = lineageSelection
        args["reason"] = .string(lineage.reason)
        changeLineage("lineage.undo", arguments: args, message: "Restoring previous lineage graph…")
    }
    func suggestLineageDivisions() {
        var args = lineageSelection
        args.merge([
            "parentTimeIndex": .number(Double(lineage.parentTime - 1)),
            "daughterTimeIndex": .number(Double(lineage.daughterTime - 1)),
            "maxDistance": .number(lineage.maximumDistance), "units": .string(lineage.distanceUnits),
            "minCombinedVolumeRatio": .number(lineage.minimumRatio),
            "maxCombinedVolumeRatio": .number(lineage.maximumRatio), "limit": .number(50)
        ]) { _, new in new }
        perform("Finding geometric division candidates…") {
            self.lineage.suggestions = try await self.call("lineage.suggest", arguments: args)["result"]
            self.reportStatus("Geometric candidates ready for manual review; no divisions were saved.")
        }
    }
    func useLineageCandidate(_ candidate: WorkbenchJSON) {
        lineage.parentTime = (candidate["parent"]["timeIndex"].integer ?? 0) + 1
        lineage.parentLabel = candidate["parent"]["labelId"].integer ?? 1
        let daughters = candidate["daughters"].array
        lineage.daughterTime = (daughters.first?["timeIndex"].integer ?? 1) + 1
        lineage.daughterOne = daughters.first?["labelId"].integer ?? 1
        lineage.daughterTwo = daughters.dropFirst().first?["labelId"].integer ?? 2
        lineage.replaceExisting = candidate["requiresReplacement"].bool == true
    }
    func inspectLineageObservation() {
        guard let node = lineage.selectedNode else { return }
        perform("Opening lineage observation…") {
            self.volume.timeIndex = node["timeIndex"].integer ?? self.volume.timeIndex
            self.volume.channel = self.lineage.graph?["channel"].integer ?? self.volume.channel
            self.volume.crosshair = zip(["cx", "cy", "cz"], self.volume.dimensions).map {
                min(max(0, Int(((node[$0.0].number ?? 0.5) - 0.5).rounded())), $0.1 - 1)
            }
            try await self.loadVolume()
            if let label = node["labelId"].integer { self.volume.selectedLabels = [label] }
            self.reportStatus("Lineage observation opened in the volume workspace.")
        }
    }
    private var lineageSelection: [String: WorkbenchJSON] {
        ["imageId": .string(volume.imageID), "channel": .number(Double(volume.channel))]
    }
    func exportLineage(to destination: URL) {
        guard lineage.status == "current", !lineage.hasUnsavedCorrection, !hasActiveWorkers,
              canRefreshWithoutDiscardingEdits, let graph = lineage.graph,
              let imageID = graph["imageId"].string, let channel = graph["channel"].integer else { return }
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            error = "Choose a new export filename. Existing files are preserved."
            return
        }
        let args: [String: WorkbenchJSON] = [
            "imageId": .string(imageID), "channel": .number(Double(channel)),
            "format": .string(lineage.exportFormatID), "destination": .string(destination.path)
        ]
        perform("Exporting saved lineage graph…", refreshOnConflict: false) {
            self.lineage.exportResult = try await self.call("lineage.export", arguments: args, mutation: true)["result"]
            try await self.inspect()
            self.reportStatus("Exported lineage \(destination.lastPathComponent).")
        }
    }
    private func changeLineage(_ operation: String, arguments: [String: WorkbenchJSON], message: String) {
        perform(message) {
            let result = try await self.call(operation, arguments: arguments, mutation: true)["result"]
            try await self.inspect()
            self.lineage.apply(result, acceptsDraft: true)
            self.lineage.suggestions = nil
            self.invalidateSummaries()
            self.reportStatus("Lineage change saved with its reason and graph history.")
        }
    }
}
