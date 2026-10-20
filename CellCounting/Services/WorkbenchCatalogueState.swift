import Foundation
import Observation

@MainActor @Observable
final class WorkbenchCatalogueState {
    static let titles: [String: String] = ["jobs": "Batch jobs", "sweeps": "Parameter sweeps", "jobWorkers": "Background workers", "imageExports": "Scientific exports", "displayPresets": "Display presets", "distributions": "Distributed work", "refreshJobs": "Result refresh plans", "collections": "Image collections", "zarrSources": "OME-Zarr sources", "tiledAnalyses": "Tiled analyses", "statisticsDesigns": "Statistical designs", "statisticsRuns": "Statistical results", "workspaces": "Layered workspaces", "workspaceOutputs": "Workspace outputs", "labelImports": "Label imports", "workflows": "Saved workflows", "experimentLayouts": "Experiment layouts", "experimentApplications": "Layout applications", "acquisitionSessions": "Acquisition sessions", "experimentExclusions": "Exclusion decisions", "plugins": "Local plugins", "adaptationDatasets": "Reference datasets", "models": "Registered models", "trainingJobs": "Training jobs", "assayRuns": "Assay results", "assaySeriesRuns": "Scratch-wound series", "reviewSessions": "Review sessions", "largeSources": "Large TIFF sources", "specimens": "Biological specimens", "plates": "Plates", "assignments": "Image assignments"]
    var metadata: [String: WorkbenchJSON] = [:]
    var rows: [String: [WorkbenchJSON]] = [:]
    var pins: [String: Set<String>] = [:]
    var catalogue = "workflows"
    var entries: [WorkbenchJSON] = []
    var total = 0
    var nextCursor: String?
    var cursors: [String?] = [nil]
    var pageIndex = 0
    var sourceRevision: Int?
    var exactID = ""
    var exactVersion = 1
    var useExactVersion = false
    var exactEntry: WorkbenchJSON?
    var exactRevision: Int?
    func identity(_ entry: WorkbenchJSON, catalogue: String) -> String? {
        if catalogue == "assignments" { return entry["imageId"].string }
        if catalogue == "plugins" { return entry["pluginId"].string }
        if catalogue == "experimentExclusions", let target = entry["target"].string, let id = entry["targetId"].string { return target + ":" + id }
        return entry["id"].string ?? entry["runId"].string ?? entry["exportId"].string ?? entry["workerId"].string
    }
    func values(_ value: WorkbenchJSON, key: String) -> [WorkbenchJSON] {
        if ["specimens", "plates", "assignments"].contains(key) { return value["experimentalDesign"][key].array }
        if key == "experimentExclusions" { return ["image", "specimen"].flatMap { value[key][$0].object.values } }
        return value[key].array
    }
    func reset() { metadata = [:]; rows = [:]; pins = [:]; resetPage(); exactID = ""; exactEntry = nil }
    func resetPage() { entries = []; total = 0; nextCursor = nil; cursors = [nil]; pageIndex = 0; sourceRevision = nil }
    func keep(_ entry: WorkbenchJSON, catalogue key: String) {
        guard let id = identity(entry, catalogue: key) else { return }
        pins[key, default: []].insert(id)
        var values = rows[key] ?? []; values.removeAll { identity($0, catalogue: key) == id }; values.append(entry); rows[key] = values
    }
    func absorb(_ value: WorkbenchJSON) {
        metadata = value["cataloguePages"].object
        for key in Self.titles.keys { rows[key] = values(value, key: key) }
    }
    var pinnedCount: Int { pins.values.reduce(0) { $0 + $1.count } }
}

extension WorkbenchSession {
    /// The one project-change lifecycle resolves retained selections explicitly;
    /// recent catalogue pages never imply that older records were deleted.
    func projectSnapshot(path: String? = nil, selected: [WorkbenchJSON] = []) async throws -> WorkbenchJSON {
        let project = path ?? projectPath
        var selections: [String: Set<String>] = project == projectPath ? catalogues.pins : [:]
        if project == projectPath {
            let current: [(String, String)] = [("workflows", selectedWorkflowID), ("models", models.selectedModelID), ("plugins", extensions.selectedPluginID),
                ("adaptationDatasets", extensions.selectedDatasetID), ("sweeps", sweeps.selectedID), ("distributions", distribution.selectedID),
                ("refreshJobs", resultRefresh.selectedJobID), ("reviewSessions", review.selectedSessionID), ("largeSources", sources.selectedID),
                ("zarrSources", storage.sourceID), ("tiledAnalyses", storage.selectedAnalysisID), ("workspaces", layeredWorkspace.selectedID),
                ("statisticsDesigns", statistics.selectedDesignID), ("statisticsRuns", statistics.selectedRun?["id"].string ?? ""),
                ("assayRuns", assays.summaryRunID), ("assaySeriesRuns", assaySeries.selectedRun?["runId"].string ?? ""),
                ("experimentLayouts", experimentLayouts.layoutID), ("experimentApplications", experimentLayouts.applicationID),
                ("acquisitionSessions", experimentLayouts.sessionID), ("displayPresets", composite.presets.selectedID)]
            for (key, id) in current where !id.isEmpty { selections[key, default: []].insert(id) }
        }
        let entries: [WorkbenchJSON] = selections.keys.sorted().flatMap { key in (selections[key] ?? []).sorted().map {
            .object(["catalogue": .string(key), "entryId": .string($0)])
        } }
        let response = try await requestSnapshot(project: project, arguments: ["selectedImageIds": .array(selected), "selectedCatalogueEntries": .array(entries)])
        var value = response["result"].object
        for selected in value["selectedCatalogueEntries"]?.array ?? [] {
            guard let key = selected["catalogue"].string, let id = selected["entryId"].string else { continue }
            if selected["missing"].bool == true {
                error = "An open saved record is no longer available in this project. Its draft is retained. Choose another record explicitly."
                continue
            }
            let record = selected["entry"]
            var values = catalogues.values(.object(value), key: key)
            values.removeAll { catalogues.identity($0, catalogue: key) == id }; values.append(record)
            if ["specimens", "plates", "assignments"].contains(key) {
                var design = value["experimentalDesign"]?.object ?? [:]; design[key] = .array(values); value["experimentalDesign"] = .object(design)
            } else if key != "experimentExclusions" { value[key] = .array(values) }
        }
        var envelope = response.object; envelope["result"] = .object(value)
        return .object(envelope)
    }
    func readCatalogue(_ key: String) async throws -> [WorkbenchJSON] {
        let result = try await call("project.catalogue", arguments: ["catalogue": .string(key), "limit": .number(25)])["result"]
        var entries = result["entries"].array
        let present = Set(entries.compactMap { catalogues.identity($0, catalogue: key) })
        let retained = (catalogues.pins[key] ?? []).subtracting(present)
        if !retained.isEmpty {
            entries += try await resolveCatalogueEntries(key, ids: retained)
        }
        catalogues.rows[key] = entries
        catalogues.metadata[key] = .object(["total": result["total"], "returned": result["returned"], "partial": result["partial"], "nextCursor": result["nextCursor"]])
        publishCatalogue(key)
        return entries
    }
    func browseCatalogue(_ key: String, direction: Int = 0) {
        if catalogues.catalogue != key { catalogues.catalogue = key; catalogues.resetPage(); catalogues.exactEntry = nil; catalogues.useExactVersion = false }
        perform("Loading saved records…", refreshOnConflict: false) {
            if direction == 0 { self.catalogues.resetPage() }
            let index = direction == 0 ? 0 : self.catalogues.pageIndex + direction
            guard index >= 0 else { return }
            let cursor = direction > 0 ? self.catalogues.nextCursor : self.catalogues.cursors.indices.contains(index) ? self.catalogues.cursors[index] : nil
            if direction > 0 && cursor == nil { return }
            var args: [String: WorkbenchJSON] = ["catalogue": .string(key), "limit": .number(25)]
            if let cursor { args["cursor"] = .string(cursor) }
            let result: WorkbenchJSON
            do { result = try await self.call("project.catalogue", arguments: args)["result"] }
            catch let failure as WorkbenchFailure where ["snapshot-changed", "revision-conflict"].contains(failure.code) {
                self.catalogues.resetPage()
                throw WorkbenchFailure(code: failure.code, message: "The project changed while browsing. Refresh the project, then load this catalogue again; editor drafts are retained.")
            }
            self.catalogues.entries = result["entries"].array; self.catalogues.total = result["total"].integer ?? 0
            self.catalogues.nextCursor = result["nextCursor"].string; self.catalogues.sourceRevision = result["sourceRevision"].integer
            if index >= self.catalogues.cursors.count { self.catalogues.cursors.append(cursor) }
            self.catalogues.pageIndex = index
            self.reportStatus("Saved-record page loaded. Choose a record to keep it available in its existing editor.")
        }
    }
    func lookupCatalogueRecord() {
        let key = catalogues.catalogue, id = catalogues.exactID
        guard !id.isEmpty else { return }
        var args: [String: WorkbenchJSON] = ["catalogue": .string(key), "entryId": .string(id)]
        if catalogues.useExactVersion { args["version"] = .number(Double(catalogues.exactVersion)) }
        perform("Looking up the exact retained record…", refreshOnConflict: false) {
            self.catalogues.exactEntry = nil; self.catalogues.exactRevision = nil
            let result = try await self.call("project.catalogue.get", arguments: args)["result"]
            self.catalogues.exactEntry = result["entry"]; self.catalogues.exactRevision = result["sourceRevision"].integer
            self.reportStatus("Exact saved record loaded without reading the complete catalogue.")
        }
    }
    func keepCatalogueRecord(_ entry: WorkbenchJSON, key: String) {
        guard catalogues.pinnedCount < 40 || catalogues.pins[key]?.contains(catalogues.identity(entry, catalogue: key) ?? "") == true else {
            error = "At most 40 older records can stay in editor choices. Release unused records in Saved records before keeping another."; return
        }
        catalogues.keep(entry, catalogue: key); publishCatalogue(key)
        reportStatus("Record retained in the existing editor's choices. Existing drafts and selections are unchanged.")
    }
    func resolveCatalogueEntries(_ key: String, ids: Set<String>) async throws -> [WorkbenchJSON] {
        var records: [WorkbenchJSON] = []
        let identifiers = ids.sorted()
        for start in stride(from: 0, to: identifiers.count, by: 200) {
            records += try await resolveCatalogueBatch(key, ids: Array(identifiers.dropFirst(start).prefix(200)))
        }
        return records
    }
    private func resolveCatalogueBatch(_ key: String, ids: [String]) async throws -> [WorkbenchJSON] {
        do {
            let response = try await call("project.catalogue.getMany", arguments: ["catalogue": .string(key), "entryIds": .array(ids.map(WorkbenchJSON.string))])
            guard response["result"]["sourceRevision"].integer == revision else {
                throw WorkbenchFailure(code: "snapshot-changed", message: "The project changed while resolving exact saved records. Refresh and resolve the selection again.")
            }
            return response["result"]["entries"].array
        } catch let failure as WorkbenchFailure where failure.code == "catalogue-batch-too-large" && ids.count > 1 {
            let middle = ids.count / 2
            let first = try await resolveCatalogueBatch(key, ids: Array(ids.prefix(middle)))
            return first + (try await resolveCatalogueBatch(key, ids: Array(ids.dropFirst(middle))))
        }
    }
    func resolveAdaptationSpecimens(imageIDs: Set<String>, completion: @escaping (Int?) -> Void) {
        guard !imageIDs.isEmpty, imageIDs.count <= 200 else { return }
        perform("Resolving exact specimen assignments for the selected reference images…", refreshOnConflict: false) {
            let values = try await self.resolveCatalogueEntries("assignments", ids: imageIDs)
            let selected = values.compactMap(WorkbenchAssignment.init)
            let specimens = try await self.resolveCatalogueEntries("specimens", ids: Set(selected.map(\.specimenID))).compactMap(WorkbenchSpecimen.init)
            self.assignments.removeAll { imageIDs.contains($0.imageID) }; self.assignments += selected
            let ids = Set(specimens.map(\.id)); self.specimens.removeAll { ids.contains($0.id) }; self.specimens += specimens
            completion(self.revision)
            self.reportStatus("Resolved \(selected.count) of \(imageIDs.count) selected image assignments. Unassigned acquisitions cannot enter a specimen-disjoint dataset.")
        }
    }
    func pinKnownCatalogue(_ key: String, id: String) {
        guard !id.isEmpty, let entry = catalogues.rows[key]?.first(where: { catalogues.identity($0, catalogue: key) == id }) else { return }
        if catalogues.pinnedCount < 40 || catalogues.pins[key]?.contains(id) == true { catalogues.keep(entry, catalogue: key) }
    }
    func publishCatalogue(_ key: String) {
        let entries = catalogues.rows[key] ?? []
        switch key {
        case "workflows": workflows = entries.compactMap(WorkbenchWorkflow.init)
        case "jobs": jobs = entries.compactMap(WorkbenchJob.init)
        case "jobWorkers":
            let active = jobWorkers.filter(\.active), ids = Set(active.map(\.id))
            jobWorkers = active + entries.compactMap(WorkbenchJobWorker.init).filter { !ids.contains($0.id) }
        case "specimens": specimens = entries.compactMap(WorkbenchSpecimen.init)
        case "plates": plates = entries.compactMap(WorkbenchPlate.init)
        case "assignments": assignments = entries.compactMap(WorkbenchAssignment.init)
        case "models": models.models = entries.compactMap(WorkbenchRegisteredModel.init)
        case "trainingJobs": models.applyActivity(models.jobs.filter { ["queued", "starting", "running", "cancelling"].contains($0["status"].string ?? "") }, recent: entries)
        case "plugins": extensions.plugins = entries.compactMap(WorkbenchPlugin.init)
        case "adaptationDatasets": extensions.datasets = entries
        case "collections": library.collections = entries
        case "sweeps": sweeps.records = entries
        case "distributions": distribution.groups = entries.compactMap(WorkbenchDistribution.init)
        case "refreshJobs": resultRefresh.jobs = entries.compactMap(WorkbenchRefreshJob.init)
        case "assayRuns": assays.summaryRuns = entries; assays.runs = entries.filter { selectedImageID == nil || $0["imageId"].string == selectedImageID }
        case "assaySeriesRuns": assaySeries.runs = entries
        case "reviewSessions": review.sessions = entries
        case "largeSources": sources.sources = entries.compactMap(WorkbenchLargeSource.init)
        case "zarrSources": storage.sources = entries
        case "tiledAnalyses": storage.analyses = entries
        case "statisticsDesigns": statistics.designs = entries
        case "statisticsRuns": statistics.runs = entries
        case "experimentLayouts": experimentLayouts.layouts = entries
        case "experimentApplications": experimentLayouts.applications = entries
        case "acquisitionSessions": experimentLayouts.acquisitionSessions = entries
        case "experimentExclusions": experimentLayouts.exclusions = .object(["decisions": .array(entries)])
        case "workspaces": layeredWorkspace.workspaces = entries
        case "workspaceOutputs": layeredWorkspace.outputs = entries
        case "displayPresets": composite.presets.updateList(entries)
        default: break
        }
    }
}
