import Foundation
import Observation

nonisolated struct WorkbenchSeriesFrame: Identifiable, Sendable {
    var id = UUID()
    var imageID = ""
    var missing = false
    var missingReason = ""
    var timeKnown = true
    var seconds = 0.0
    var channel = 0
    var projection = "max"
    var timeIndex = 0
    var crop = false
    var x = 0
    var y = 0
    var width = 256
    var height = 256
    var arguments: WorkbenchJSON {
        var fields: [String: WorkbenchJSON] = ["timeSeconds": timeKnown ? .number(seconds) : .null]
        if missing { fields["missingReason"] = .string(missingReason) }
        else {
            fields["imageId"] = .string(imageID)
            fields["sourceParameters"] = .object(["channel": .number(Double(channel)), "zProjection": .string(projection)])
            fields["timeIndex"] = .number(Double(timeIndex))
            if crop { fields["region"] = .object(["x": .number(Double(x)), "y": .number(Double(y)), "width": .number(Double(width)), "height": .number(Double(height))]) }
        }
        return .object(fields)
    }
}

@MainActor @Observable
final class WorkbenchAssaySeriesState {
    var name = "Scratch-wound time series"
    var frames: [WorkbenchSeriesFrame] = []
    var baselineID: UUID?
    var parameters: [String: WorkbenchJSON] = [:]
    var catalogue: WorkbenchJSON = .null
    var runs: [WorkbenchJSON] = []
    var output: WorkbenchJSON?
    var selectedRun: WorkbenchJSON?
    var previewDefinition: WorkbenchJSON?
    var previewRevision: Int?
    var recomputeRunID: String?
    var exportFormats: [WorkbenchImageExportFormat] = []
    var exportFormat = "observations-csv"
    var exportResult: WorkbenchJSON?
    var definition: WorkbenchJSON {
        .object(["assay": .string("scratch_wound"), "name": .string(name), "frames": .array(frames.map(\.arguments)),
                 "baselineIndex": .number(Double(frames.firstIndex { $0.id == baselineID } ?? 0)), "parameters": .object(parameters)])
    }
    var complete: Bool {
        frames.count >= 2 && frames.count <= 128 && frames.contains { !$0.missing } && frames.contains { $0.id == baselineID } &&
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && frames.allSatisfy {
            (!$0.timeKnown || $0.seconds.isFinite) && ($0.missing ? !$0.missingReason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty : !$0.imageID.isEmpty)
        }
    }
    var parameterFields: [WorkbenchPluginParameter] {
        let schema = catalogue["definitionSchema"]["properties"]["parameters"]
        let required = Set(schema["required"].array.compactMap(\.string))
        return schema["properties"].object.sorted { $0.key < $1.key }.map {
            WorkbenchPluginParameter(id: $0.key, schema: $0.value, required: required.contains($0.key))
        }
    }
    func previewCurrent(_ revision: Int?) -> Bool {
        output?["previewFingerprint"].string != nil && previewRevision == revision &&
            (recomputeRunID != nil || previewDefinition == definition)
    }
    func add(image: WorkbenchImage?, missing: Bool = false) {
        guard frames.count < 128 else { return }
        var frame = WorkbenchSeriesFrame()
        frame.missing = missing
        frame.imageID = image?.id ?? ""
        frame.width = min(2000, image?.width ?? 256); frame.height = min(2000, image?.height ?? 256)
        // Never infer timestamps from image order or metadata with unknown units.
        frame.timeKnown = false
        frames.append(frame)
        if baselineID == nil { baselineID = frame.id }
    }
    func applyInspection(_ value: WorkbenchJSON) {
        runs = value["assaySeriesRuns"].array
        if let current = selectedRun, let updated = runs.first(where: { $0["runId"] == current["runId"] }) { selectedRun = updated }
    }
    func reset() {
        name = "Scratch-wound time series"; frames = []; baselineID = nil; parameters = [:]
        catalogue = .null; runs = []; output = nil; selectedRun = nil
        previewDefinition = nil; previewRevision = nil; recomputeRunID = nil; exportFormats = []; exportResult = nil
    }
}

extension WorkbenchSession {
    func readSeriesMethods() async throws {
        assaySeries.catalogue = try await call("assay.series.catalogue")["result"]
        assaySeries.runs = try await readCatalogue("assaySeriesRuns")
        assaySeries.exportFormats = try await call("assay.series.export.catalogue")["result"]["formats"].array.compactMap(WorkbenchImageExportFormat.init)
        if assaySeries.parameters.isEmpty {
            assaySeries.parameters = Dictionary(uniqueKeysWithValues: assaySeries.parameterFields.compactMap {
                $0.required || $0.schema["default"] != .null ? ($0.id, $0.initialValue) : nil
            })
        }
    }
    func previewAssaySeries() {
        guard assaySeries.complete, !hasActiveWorkers else { return }
        let definition = assaySeries.definition
        perform("Calculating the explicit-time series on common acquired support…") {
            let output = try await self.call("assay.series.preview", arguments: definition.object)["result"]["preview"]
            self.assaySeries.output = output; self.assaySeries.selectedRun = nil
            self.assaySeries.previewDefinition = definition; self.assaySeries.previewRevision = self.revision
            self.assaySeries.recomputeRunID = nil; self.assaySeries.exportResult = nil
            self.reportStatus("Series preview ready. Review common coverage, baseline and the observations used for each rate before saving.")
        }
    }
    func saveAssaySeriesPreview() {
        guard !hasActiveWorkers, assaySeries.previewCurrent(revision), let fingerprint = assaySeries.output?["previewFingerprint"].string else { return }
        let previous = assaySeries.recomputeRunID
        var args = previous.map { ["runId": WorkbenchJSON.string($0)] } ?? assaySeries.definition.object
        args["previewFingerprint"] = .string(fingerprint)
        perform(previous == nil ? "Saving scratch-wound series…" : "Saving replacement scratch-wound series…") {
            let result = try await self.call(previous == nil ? "assay.series.run" : "assay.series.recompute.run", arguments: args, mutation: true)["result"]
            self.assaySeries.output = result["output"]; self.assaySeries.selectedRun = result["run"]
            self.assaySeries.previewDefinition = nil; self.assaySeries.previewRevision = nil; self.assaySeries.recomputeRunID = nil
            try await self.inspect(); try await self.readSeriesMethods()
            self.reportStatus("Series saved as one repeated-measure observation. Previous results remain retained.")
        }
    }
    func readAssaySeries(_ id: String) {
        perform("Loading retained scratch-wound observations…") {
            let result = try await self.call("assay.series.results", arguments: ["runId": .string(id)])["result"]
            self.assaySeries.output = result["output"]; self.assaySeries.selectedRun = result["run"]
            self.assaySeries.previewDefinition = nil; self.assaySeries.previewRevision = nil; self.assaySeries.recomputeRunID = nil
            self.assaySeries.exportResult = nil
            self.reportStatus("Retained series loaded. The editable observation draft is unchanged.")
        }
    }
    func previewAssaySeriesReplacement(_ id: String) {
        perform("Recomputing the saved series for review…") {
            self.assaySeries.output = try await self.call("assay.series.recompute.preview", arguments: ["runId": .string(id)])["result"]["preview"]
            self.assaySeries.selectedRun = nil; self.assaySeries.previewDefinition = nil
            self.assaySeries.previewRevision = self.revision; self.assaySeries.recomputeRunID = id
            self.assaySeries.exportResult = nil
            self.reportStatus("Replacement preview ready. Saving appends a new result linked to the original series.")
        }
    }
    func exportAssaySeries(to destination: URL) {
        guard let id = assaySeries.selectedRun?["runId"].string else { return }
        let format = assaySeries.exportFormat
        perform("Exporting the complete retained series…") {
            self.assaySeries.exportResult = try await self.call("assay.series.export", arguments: ["runId": .string(id), "format": .string(format), "destination": .string(destination.path)], mutation: true)["result"]
            try await self.inspect()
            self.reportStatus("All retained observations and provenance exported; missing measurements remain empty.")
        }
    }
}
