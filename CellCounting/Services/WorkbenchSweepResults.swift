import Foundation

nonisolated struct WorkbenchSweepMetrics: Sendable {
    let objectCount: Int?
    let foregroundSamples: Int?
    let meanObjectSizeSamples: Double?
    let totalPhysicalSize: Double?
    let meanObjectPhysicalSize: Double?
    let physicalSizeUnit: String
    let meanObjectIntensity: Double?
    var unitLabel: String {
        switch physicalSizeUnit {
        case "um3": return "µm³"
        case "um2": return "µm²"
        default: return "—"
        }
    }

    init?(_ value: WorkbenchJSON) {
        guard value != .null else { return nil }
        objectCount = value["objectCount"].integer
        foregroundSamples = value["foregroundSamples"].integer
        meanObjectSizeSamples = value["meanObjectSizeSamples"].number
        totalPhysicalSize = value["totalPhysicalSize"].number
        meanObjectPhysicalSize = value["meanObjectPhysicalSize"].number
        physicalSizeUnit = value["physicalSizeUnit"].string ?? ""
        meanObjectIntensity = value["meanObjectIntensity"].number
    }
}

nonisolated struct WorkbenchSweepResultRow: Identifiable, Sendable {
    let id: Int
    let combinationIndex: Int
    let jobID: String
    let sourceImageID: String
    let sourceName: String
    let variantImageID: String
    let workingImageID: String
    let nodeID: String?
    let nodeName: String?
    var branchLabel: String { nodeName ?? nodeID.map { "Node \($0)" } ?? "Linear analysis" }
    let target: String
    let sourceSelection: WorkbenchJSON
    let selection: WorkbenchJSON
    let checkpointStatus: String
    let status: String
    let reason: String?
    let analysisRevision: Int?
    let measurementRevision: Int?
    let labelsHash: String?
    let intensityUnits: String
    let metrics: WorkbenchSweepMetrics?

    init(_ value: WorkbenchJSON, index: Int) {
        id = index
        combinationIndex = value["combinationIndex"].integer ?? 0
        jobID = value["jobId"].string ?? ""
        sourceImageID = value["sourceImageId"].string ?? ""
        sourceName = value["sourceName"].string ?? sourceImageID
        variantImageID = value["variantImageId"].string ?? ""
        workingImageID = value["workingImageId"].string ?? variantImageID
        nodeID = value["nodeId"].string; nodeName = value["nodeName"].string
        target = value["target"].string ?? "plane"
        sourceSelection = value["sourceSelection"]; selection = value["selection"]
        checkpointStatus = value["checkpointStatus"].string ?? "pending"
        status = value["status"].string ?? "unavailable"
        reason = value["reason"].string
        analysisRevision = value["analysisRevision"].integer
        measurementRevision = value["measurementRevision"].integer
        labelsHash = value["labelsSha256"].string
        intensityUnits = value["intensityUnits"].string ?? ""
        metrics = WorkbenchSweepMetrics(value["metrics"])
    }

    func selectionLabel(_ value: WorkbenchJSON) -> String {
        let channel = value["channel"].integer ?? value["sourceParameters"]["channel"].integer ?? 0
        if target == "volume" {
            return "T\((value["timeIndex"].integer ?? 0) + 1) · C\(channel + 1)"
        }
        return "C\(channel + 1) · \(value["zProjection"].string ?? value["sourceParameters"]["zProjection"].string ?? "max")"
    }
}

nonisolated struct WorkbenchSweepBranchResult: Identifiable, Sendable {
    let id: String
    let name: String
    let totalInputs: Int
    let currentInputs: Int
    let pendingInputs: Int
    let staleInputs: Int
    let objectObservations: Int?
    let availableObjectObservations: Int?
    let comparisonComplete: Bool
    init?(_ value: WorkbenchJSON) {
        guard let id = value["nodeId"].string else { return nil }
        self.id = id; name = value["nodeName"].string ?? id
        totalInputs = value["totalInputs"].integer ?? 0
        currentInputs = value["currentInputs"].integer ?? 0
        pendingInputs = value["pendingInputs"].integer ?? 0
        staleInputs = value["staleInputs"].integer ?? 0
        objectObservations = value["objectObservations"].integer
        availableObjectObservations = value["availableObjectObservations"].integer
        comparisonComplete = value["comparisonComplete"].bool == true
    }
}

nonisolated struct WorkbenchSweepCombinationResult: Identifiable, Sendable {
    let id: Int
    let jobID: String
    let status: String
    let values: [WorkbenchJSON]
    let totalInputs: Int
    let currentInputs: Int
    let pendingInputs: Int
    let staleInputs: Int
    let objectObservations: Int?
    let availableObjectObservations: Int?
    let comparisonComplete: Bool
    let branchResults: [WorkbenchSweepBranchResult]
    var isGraph: Bool { !branchResults.isEmpty || values.contains { $0["nodeId"].string != nil } }

    init(_ value: WorkbenchJSON) {
        id = value["index"].integer ?? 0
        jobID = value["jobId"].string ?? ""
        status = value["status"].string ?? "pending"
        values = value["values"].array
        totalInputs = value["totalInputs"].integer ?? 0
        currentInputs = value["currentInputs"].integer ?? 0
        pendingInputs = value["pendingInputs"].integer ?? 0
        staleInputs = value["staleInputs"].integer ?? 0
        objectObservations = value["objectObservations"].integer
        availableObjectObservations = value["availableObjectObservations"].integer
        comparisonComplete = value["comparisonComplete"].bool == true
        branchResults = value["branchResults"].array.compactMap(WorkbenchSweepBranchResult.init)
    }
}

nonisolated struct WorkbenchSweepResults: Sendable {
    let sweepID: String
    let name: String
    let sourceRevision: Int
    let definitionHash: String
    let sourceInputsCurrent: Bool
    let complete: Bool
    let combinations: [WorkbenchSweepCombinationResult]
    let rows: [WorkbenchSweepResultRow]
    let offset: Int
    let limit: Int
    let total: Int
    let nextOffset: Int?
    let notes: [String]
    var isGraph: Bool { combinations.contains( where: \.isGraph) || rows.contains { $0.nodeID != nil } }

    init?(_ value: WorkbenchJSON) {
        guard let sweepID = value["sweepId"].string, let revision = value["sourceRevision"].integer else { return nil }
        self.sweepID = sweepID
        name = value["name"].string ?? "Parameter sweep"
        sourceRevision = revision
        definitionHash = value["definitionHash"].string ?? ""
        sourceInputsCurrent = value["sourceInputsCurrent"].bool == true
        complete = value["complete"].bool == true
        combinations = value["combinations"].array.map(WorkbenchSweepCombinationResult.init)
        offset = value["pagination"]["offset"].integer ?? 0
        limit = value["pagination"]["limit"].integer ?? 100
        total = value["pagination"]["total"].integer ?? 0
        nextOffset = value["pagination"]["nextOffset"].integer
        let firstIndex = value["pagination"]["offset"].integer ?? 0
        rows = value["rows"].array.enumerated().map { WorkbenchSweepResultRow($0.element, index: firstIndex + $0.offset) }
        notes = value["notes"].array.compactMap(\.string)
    }
}

extension WorkbenchSession {
    func loadSweepResults(_ sweepID: String, offset: Int = 0, limit: Int = 100) {
        perform("Loading sweep comparison results…", refreshOnConflict: false) {
            if self.sweeps.exportFormats.isEmpty {
                self.sweeps.exportFormats = try await self.call("sweep.export.catalogue")["result"]["formats"].array
                    .compactMap(WorkbenchImageExportFormat.init)
            }
            let response = try await self.readSweepResultsSnapshot(arguments: [
                "sweepId": .string(sweepID), "offset": .number(Double(offset)), "limit": .number(Double(limit))
            ])
            guard let results = WorkbenchSweepResults(response["result"]) else {
                throw WorkbenchFailure(code: "invalid-response", message: "The sweep comparison response is incomplete.")
            }
            self.sweeps.results = results
            self.reportStatus("Sweep comparison snapshot loaded at project revision \(results.sourceRevision).")
        }
    }

    func exportSweepResults(_ sweepID: String, format: String, to destination: URL) {
        guard !hasActiveWorkers, canRefreshWithoutDiscardingEdits else { return }
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            error = "Choose a new destination. Sweep exports preserve existing files."
            return
        }
        perform("Exporting all sweep comparison rows…", refreshOnConflict: false) {
            self.sweeps.exportResult = try await self.call("sweep.export", arguments: [
                "sweepId": .string(sweepID), "format": .string(format), "destination": .string(destination.path)
            ], mutation: true)["result"]
            try await self.inspect()
            self.reportStatus("Exported all sweep rows to \(destination.lastPathComponent).")
        }
    }
}
