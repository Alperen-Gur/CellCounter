import AppKit
import Foundation
import Observation

@MainActor @Observable
final class WorkbenchStorageState {
    var sources: [WorkbenchJSON] = []
    var analyses: [WorkbenchJSON] = []
    var sourceID = ""
    var arrayPath = ""
    var timeIndex = 0
    var channel = 0
    var zIndex = 0
    var x = 0
    var y = 0
    var width = 512
    var height = 512
    var imageName = ""
    var overview: NSImage?
    var overviewResult: WorkbenchJSON = .null
    var overviewSelection: WorkbenchJSON = .null
    var overviewMetadataHash = ""
    var method = "otsu"
    var threshold = 0.0
    var polarity = "bright"
    var connectivity = 8
    var minAreaPx = 9
    var tileSize = 512
    var halo = 1
    var analysisName = ""
    var plan: WorkbenchJSON = .null
    var plannedArguments: WorkbenchJSON = .null
    var planRevision: Int?
    var selectedAnalysisID = ""
    var objectPage: WorkbenchJSON = .null
    var objectRevision: Int?
    var tilePage: WorkbenchJSON = .null
    var tileRevision: Int?
    var labelX = 0
    var labelY = 0
    var labelWidth = 512
    var labelHeight = 512
    var labelPreview: NSImage?
    var labelPreviewSelection: WorkbenchJSON = .null
    var labelPreviewRevision: Int?
    var formats: [WorkbenchJSON] = []
    var selectedFormat = "labels-ngff-zip"
    var lastExport: WorkbenchJSON = .null
    var source: WorkbenchJSON { sources.first { $0["id"].string == sourceID } ?? .null }
    var array: WorkbenchJSON { source["arrays"].array.first { $0["path"].string == arrayPath } ?? .null }
    var analysis: WorkbenchJSON { analyses.first { $0["id"].string == selectedAnalysisID } ?? .null }
    func dimension(_ axis: String) -> Int {
        guard let index = array["axes"].array.firstIndex(where: { $0["name"].string == axis }),
              index < array["shape"].array.count else { return 1 }
        return max(1, array["shape"].array[index].integer ?? 1)
    }
    var selection: WorkbenchJSON { .object(["sourceId": .string(sourceID), "arrayPath": .string(arrayPath),
        "timeIndex": .number(Double(timeIndex)), "channel": .number(Double(channel)), "zIndex": .number(Double(zIndex))]) }
    var region: WorkbenchJSON { .object(["x": .number(Double(x)), "y": .number(Double(y)),
        "width": .number(Double(width)), "height": .number(Double(height))]) }
    var validSelection: Bool {
        array != .null && timeIndex >= 0 && timeIndex < dimension("t") && channel >= 0 && channel < dimension("c") && zIndex >= 0 && zIndex < dimension("z")
    }
    var validRegion: Bool {
        validSelection && x >= 0 && y >= 0 && width > 0 && height > 0 && x <= dimension("x") && y <= dimension("y") &&
            width <= dimension("x") - x && height <= dimension("y") - y
    }
    var overviewCurrent: Bool { overview != nil && selection == overviewSelection && overviewMetadataHash == source["metadataHash"].string }
    var parameters: WorkbenchJSON {
        var result: [String: WorkbenchJSON] = ["method": .string(method), "polarity": .string(polarity),
            "connectivity": .number(Double(connectivity)), "minAreaPx": .number(Double(minAreaPx))]
        if method == "manual" { result["threshold"] = .number(threshold) }
        return .object(result)
    }
    var planArguments: WorkbenchJSON {
        .object(selection.object.merging(["region": region, "tileSize": .number(Double(tileSize)),
            "halo": .number(Double(halo)), "parameters": parameters]) { _, next in next })
    }
    var labelArguments: WorkbenchJSON { .object(["analysisId": .string(selectedAnalysisID), "x": .number(Double(labelX)),
        "y": .number(Double(labelY)), "width": .number(Double(labelWidth)), "height": .number(Double(labelHeight))]) }
    var validLabelRegion: Bool {
        let region = analysis["region"]
        guard let x = region["x"].integer, let y = region["y"].integer,
              let width = region["width"].integer, let height = region["height"].integer else { return false }
        return labelX >= x && labelY >= y && labelWidth > 0 && labelHeight > 0 &&
            labelX - x <= width && labelY - y <= height &&
            labelWidth <= width - (labelX - x) && labelHeight <= height - (labelY - y) &&
            Double(labelWidth) * Double(labelHeight) <= 1_000_000
    }
    func configureSource(_ id: String) {
        sourceID = id; configureArray(source["arrays"].array.first?["path"].string ?? "")
    }
    func configureArray(_ path: String) {
        arrayPath = path; timeIndex = 0; channel = 0; zIndex = 0; x = 0; y = 0
        width = min(512, dimension("x")); height = min(512, dimension("y"))
        overview = nil; overviewResult = .null; overviewSelection = .null; plan = .null; planRevision = nil
    }
    func selectAnalysis(_ id: String) {
        selectedAnalysisID = id; objectPage = .null; tilePage = .null; labelPreview = nil; lastExport = .null
        labelX = analysis["region"]["x"].integer ?? 0; labelY = analysis["region"]["y"].integer ?? 0
        labelWidth = min(512, analysis["region"]["width"].integer ?? 512)
        labelHeight = min(512, analysis["region"]["height"].integer ?? 512)
    }
    func applyInspection(_ value: WorkbenchJSON) {
        sources = value["zarrSources"].array; analyses = value["tiledAnalyses"].array
        if sourceID.isEmpty { configureSource(sources.last?["id"].string ?? "") }
        if selectedAnalysisID.isEmpty { selectAnalysis(analyses.last?["id"].string ?? "") }
    }
    func reset() { sources = []; analyses = []; configureSource(""); selectAnalysis(""); formats = []; lastExport = .null }
}

extension WorkbenchSession {
    func loadStorage() {
        perform("Reading OME-Zarr sources and tiled analyses…") {
            try await self.inspectFromChanges(preserveDisplayedImage: true)
            self.storage.formats = try await self.call("tiled.analysis.export.catalogue")["result"]["formats"].array
            self.reportStatus("Source catalogue and retained tiled progress loaded. External chunk currentness is checked during reads.")
        }
    }
    func importZarrSource(_ url: URL, rebind: Bool = false) {
        guard canRefreshWithoutDiscardingEdits, !hasActiveWorkers else { return }
        var args: [String: WorkbenchJSON] = ["path": .string(url.path)]
        if rebind { args["sourceId"] = .string(storage.sourceID) }
        perform(rebind ? "Verifying relocated OME-Zarr source…" : "Cataloguing local OME-Zarr image group…") {
            let result = try await self.call(rebind ? "zarr.rebind" : "zarr.import", arguments: args, mutation: true)["result"]
            try await self.inspectFromChanges(preserveDisplayedImage: true)
            self.storage.configureSource(result["source"]["id"].string ?? self.storage.sourceID)
            self.reportStatus(rebind ? "Source location rebound after retained identity checks." : "OME-Zarr metadata retained. Choose a resolution level and exact acquisition plane.")
        }
    }
    func previewZarrSource() {
        guard storage.validSelection else { return }
        let selection = storage.selection, metadataHash = storage.source["metadataHash"].string ?? ""
        var args = selection.object; args["maxSize"] = .number(1024)
        perform("Reading selected-level OME-Zarr overview…", refreshOnConflict: false) {
            let result = try await self.call("zarr.overview", arguments: args)["result"]
            guard self.storage.selection == selection, self.storage.source["metadataHash"].string == metadataHash else { return }
            self.storage.overview = try self.decodePreview(result); self.storage.overviewResult = result
            self.storage.overviewSelection = selection; self.storage.overviewMetadataHash = metadataHash
            self.reportStatus("Bounded overview loaded. Region coordinates use the selected source resolution level.")
        }
    }
    func extractZarrRegion() {
        guard storage.validRegion, Double(storage.width) * Double(storage.height) <= 16_000_000,
              canRefreshWithoutDiscardingEdits, !hasActiveWorkers else { return }
        var args = storage.selection.object.merging(storage.region.object) { _, next in next }
        let name = storage.imageName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty { args["name"] = .string(name) }
        perform("Extracting exact OME-Zarr source region…") {
            let result = try await self.call("zarr.extract", arguments: args, mutation: true)["result"]
            try await self.inspect(); self.selectedImageID = result["imageId"].string
            self.viewingVolume = false; self.invalidateSummaries(); try await self.loadImage()
            self.reportStatus("Selected-level raw region retained with calibration, origin and exact chunk-read provenance.")
        }
    }
    func previewTiledPlan() {
        guard storage.validRegion, !hasActiveWorkers else { return }
        let args = storage.planArguments
        perform("Planning bounded tiled analysis…", refreshOnConflict: false) {
            let result = try await self.call("tiled.analysis.preview", arguments: args.object)["result"]
            self.storage.plan = result["plan"]; self.storage.plannedArguments = args; self.storage.planRevision = self.revision
            self.reportStatus("Tile plan prepared. No segmentation was executed by this preview.")
        }
    }
    func createTiledAnalysis() {
        guard storage.plan != .null, storage.planRevision == revision, storage.plannedArguments == storage.planArguments,
              canRefreshWithoutDiscardingEdits, !hasActiveWorkers else { return }
        var args = storage.planArguments.object
        let name = storage.analysisName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty { args["name"] = .string(name) }
        perform("Creating durable tiled analysis…") {
            let result = try await self.call("tiled.analysis.create", arguments: args, mutation: true)["result"]
            try await self.inspectFromChanges(preserveDisplayedImage: true)
            self.storage.selectAnalysis(result["analysis"]["id"].string ?? "")
            self.reportStatus("Tiled analysis created. Run individual checkpoints or start the shared background worker.")
        }
    }
    func controlTiledAnalysis(_ action: String) {
        guard ["advance", "pause", "resume", "cancel", "worker.start"].contains(action), !storage.selectedAnalysisID.isEmpty,
              canRefreshWithoutDiscardingEdits, !hasActiveWorkers else { return }
        let id = storage.selectedAnalysisID
        perform(action == "worker.start" ? "Starting tiled background analysis…" : "Updating tiled analysis…") {
            _ = try await self.call("tiled.analysis." + action, arguments: ["analysisId": .string(id)], mutation: true)
            try await self.inspectFromChanges(preserveDisplayedImage: true)
            self.reportStatus(action == "worker.start" ? "Tiled worker started. It continues after this window or application closes." : "Tiled checkpoint state saved; previous results remain retained.")
        }
    }
    func readTiledPage(_ kind: String, offset: Int = 0) {
        guard ["objects", "tiles"].contains(kind), !storage.selectedAnalysisID.isEmpty else { return }
        let id = storage.selectedAnalysisID
        perform("Reading retained tiled \(kind)…", refreshOnConflict: false) {
            let result = try await self.call("tiled.analysis." + kind, arguments: ["analysisId": .string(id),
                "offset": .number(Double(offset)), "limit": .number(kind == "objects" ? 100 : 50)])["result"]
            guard self.storage.selectedAnalysisID == id else { return }
            if kind == "objects" { self.storage.objectPage = result; self.storage.objectRevision = self.revision }
            else { self.storage.tilePage = result; self.storage.tileRevision = self.revision }
            self.reportStatus("Retained result page loaded.")
        }
    }
    func previewTiledLabels() {
        guard storage.validLabelRegion else { return }
        let selection = storage.labelArguments
        var args = selection.object; args["maxSize"] = .number(1024)
        perform("Reading exact retained label region…", refreshOnConflict: false) {
            let result = try await self.call("tiled.analysis.labels.region", arguments: args)["result"]
            guard self.storage.labelArguments == selection else { return }
            let display = result["overlayDataUrl"].string ?? result["dataUrl"].string ?? ""
            self.storage.labelPreview = try self.decodePreview(.object(["dataUrl": .string(display)]))
            self.storage.labelPreviewSelection = selection; self.storage.labelPreviewRevision = self.revision
            self.reportStatus("Exact retained label region loaded for display.")
        }
    }
    func exportTiledAnalysis(to url: URL) {
        guard storage.analysis["status"].string == "completed", !hasActiveWorkers,
              canRefreshWithoutDiscardingEdits else { return }
        let args: [String: WorkbenchJSON] = ["analysisId": .string(storage.selectedAnalysisID),
            "format": .string(storage.selectedFormat), "destination": .string(url.path)]
        perform("Verifying and exporting tiled results…") {
            self.storage.lastExport = try await self.call("tiled.analysis.export", arguments: args, mutation: true)["result"]
            try await self.inspectFromChanges(preserveDisplayedImage: true)
            self.reportStatus("Tiled results exported to a new file after source identity verification.")
        }
    }
}
