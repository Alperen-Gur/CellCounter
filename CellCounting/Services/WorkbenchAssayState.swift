import Foundation
import Observation

nonisolated struct WorkbenchAssay: Identifiable, Sendable {
    let id: String
    let name: String
    let dimensions: [Int]
    let requiresAnalysis: Bool
    let notes: [String]
    let imageReferenceArguments: [String]
    let parameters: [WorkbenchPluginParameter]
    init?(_ value: WorkbenchJSON) {
        guard let id = value["id"].string else { return nil }
        self.id = id; name = value["name"].string ?? id
        dimensions = value["dimensions"].array.compactMap(\.integer)
        requiresAnalysis = value["requiresAnalysis"].bool ?? true
        notes = value["notes"].array.compactMap(\.string)
        imageReferenceArguments = value["imageReferenceArguments"].array.compactMap(\.string)
        let required = Set(value["parameters"]["required"].array.compactMap(\.string))
        parameters = value["parameters"]["properties"].object.sorted { $0.key < $1.key }.map {
            WorkbenchPluginParameter(id: $0.key, schema: $0.value, required: required.contains($0.key))
        }
    }
    var initialParameters: [String: WorkbenchJSON] {
        Dictionary(uniqueKeysWithValues: parameters.compactMap {
            $0.required || $0.schema["default"] != .null ? ($0.id, $0.initialValue) : nil
        })
    }
}

@MainActor @Observable
final class WorkbenchAssayState {
    var sourceChannel = 0
    var sourceProjection = "max"
    var catalog: [WorkbenchAssay] = []
    var selectedID = ""
    var runs: [WorkbenchJSON] = []
    var output: WorkbenchJSON?
    var outputStale = false
    var preview = false
    var summaryRuns: [WorkbenchJSON] = []
    var summaryRunID = ""
    var metricPath = ""
    var metricDescriptor: WorkbenchJSON?
    var biologicalSummary: WorkbenchJSON?
    func reset() {
        catalog = []; selectedID = ""; summaryRuns = []; summaryRunID = ""; metricPath = ""
        metricDescriptor = nil; invalidateResults()
    }
    func invalidateResults() {
        runs = []; output = nil; preview = false; outputStale = false
        biologicalSummary = nil
    }
    func applyInspection(_ value: WorkbenchJSON) {
        summaryRuns = value["assayRuns"].array
        if summaryRunID.isEmpty {
            summaryRunID = summaryRuns.last?["runId"].string ?? ""
            metricDescriptor = nil; metricPath = ""
        }
        if biologicalSummary?["sourceRevision"].integer != value["project"]["revision"].integer {
            biologicalSummary = nil
        }
    }
}

extension WorkbenchSession {
    func loadAssayMetrics(runID: String) {
        guard !runID.isEmpty else { return }
        assays.summaryRunID = runID
        assays.metricDescriptor = nil; assays.metricPath = ""; assays.biologicalSummary = nil
        perform("Discovering measured assay outputs…") {
            let result = try await self.call("assay.metrics", arguments: ["runId": .string(runID)])["result"]
            self.assays.metricDescriptor = result
            self.assays.metricPath = result["metrics"].array.first?["path"].string ?? ""
            self.reportStatus("Measured assay outputs loaded.")
        }
    }

    func summarizeBiologicalAssay(imageIDs: Set<String>?) {
        guard !assays.summaryRunID.isEmpty, !assays.metricPath.isEmpty,
              assays.metricDescriptor?["current"].bool == true else { return }
        var args: [String: WorkbenchJSON] = [
            "runId": .string(assays.summaryRunID), "metricPath": .string(assays.metricPath)
        ]
        if let imageIDs { args["imageIds"] = .array(imageIDs.sorted().map(WorkbenchJSON.string)) }
        perform("Summarizing assays by biological specimen…") {
            self.assays.biologicalSummary = nil
            self.assays.biologicalSummary = try await self.call("experiment.assay.summary", arguments: args)["result"]
            self.reportStatus("Assay summary computed with equal weight for complete biological specimens.")
        }
    }

    func loadAssays() {
        perform("Loading assay methods…") {
            try await self.inspect()
            if !self.hasDisplayedImage { try await self.loadImage() }
            self.assays.catalog = try await self.call("assay.catalog")["result"]["assays"].array.compactMap(WorkbenchAssay.init)
            if !self.assays.catalog.contains(where: { $0.id == self.assays.selectedID }) {
                self.assays.selectedID = self.assays.catalog.first?.id ?? ""
            }
            try await self.readAssayRuns()
            try await self.readSeriesMethods()
            self.reportStatus("Assay methods and saved results loaded.")
        }
    }
    func runAssay(parameters values: [String: WorkbenchJSON], previewOnly: Bool) {
        guard let imageID = selectedImageID, !assays.selectedID.isEmpty else { return }
        var args: [String: WorkbenchJSON] = [
            "imageId": .string(imageID), "assay": .string(assays.selectedID),
            "parameters": .object(values), "target": .string(viewingVolume ? "volume" : "plane")
        ]
        if viewingVolume {
            args["timeIndex"] = .number(Double(volume.timeIndex))
            args["channel"] = .number(Double(volume.channel))
        } else if assays.catalog.first(where: { $0.id == assays.selectedID })?.requiresAnalysis == false {
            args["sourceParameters"] = .object(["channel": .number(Double(assays.sourceChannel)), "zProjection": .string(assays.sourceProjection)])
        }
        perform(previewOnly ? "Previewing assay…" : "Running assay…") {
            self.assays.output = nil
            let result = try await self.call(previewOnly ? "assay.preview" : "assay.run",
                arguments: args, mutation: !previewOnly)["result"]
            if !previewOnly { try await self.inspect(); try await self.readAssayRuns() }
            self.assays.output = result["output"]
            self.assays.preview = previewOnly
            self.assays.outputStale = false
            self.reportStatus(previewOnly ? "Assay preview ready; no result saved." : "Assay result saved with its input dependencies.")
        }
    }
    func inspectAssayRun(_ runID: String) {
        perform("Loading saved assay…") {
            let run = try await self.call("assay.results", arguments: ["runId": .string(runID)])["result"]["runs"].array.first
            self.assays.output = run?["output"]
            self.assays.outputStale = run?["stale"].bool == true
            self.assays.preview = false
            self.reportStatus("Saved assay loaded.")
        }
    }
    func recomputeAssay(_ runID: String) {
        perform("Recomputing assay from current inputs…") {
            let result = try await self.call("assay.recompute", arguments: ["runId": .string(runID)], mutation: true)["result"]
            try await self.inspect()
            try await self.readAssayRuns()
            self.assays.output = result["output"]
            self.assays.preview = false; self.assays.outputStale = false
            self.reportStatus("Updated assay saved; the previous result remains in history.")
        }
    }
    private func readAssayRuns() async throws {
        let values = try await readCatalogue("assayRuns")
        assays.runs = values.filter { selectedImageID == nil || $0["imageId"].string == selectedImageID }
    }
}
