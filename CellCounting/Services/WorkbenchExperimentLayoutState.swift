import Foundation
import Observation

struct WorkbenchLayoutSlot: Identifiable {
    var id = UUID().uuidString
    var name = "Specimen"
    var condition = "Control"
    var role = "control"
    var values: [String: String] = [:]
    var subjectKey = ""
    var blockKey = ""
    var well = false
    var row = 1
    var column = 1
}

@MainActor @Observable
final class WorkbenchExperimentLayoutState {
    var layouts: [WorkbenchJSON] = []
    var applications: [WorkbenchJSON] = []
    var acquisitionSessions: [WorkbenchJSON] = []
    var exclusions: WorkbenchJSON = .null
    var catalogue: WorkbenchJSON = .null
    var layoutID = ""
    var layoutVersion = 1
    var selectedLayout: WorkbenchJSON?
    var name = "Reusable experiment"
    var notes = ""
    var factors = [WorkbenchStatFactor(id: "condition", name: "Condition")]
    var slots: [WorkbenchLayoutSlot] = []
    var hasPlate = false
    var rows = 8
    var columns = 12
    var instanceName = "Experiment instance"
    var experiment = ""
    var plateName = ""
    var bindings: [String: Set<String>] = [:]
    var fields: [String: String] = [:]
    var subjects: [String: String] = [:]
    var blocks: [String: String] = [:]
    var replaceAssignments = false
    var applicationPreview: WorkbenchJSON?
    var previewArguments: WorkbenchJSON?
    var previewRevision: Int?
    var selectedApplication: WorkbenchJSON?
    var applicationID = ""
    var sessionID = ""
    var sessionVersion = 1
    var acquisitionName = "Acquisition session"
    var instrument = ""
    var operatorName = ""
    var startedAt = ""
    var endedAt = ""
    var acquisitionNotes = ""
    var acquisitionImages: Set<String> = []
    var selectedSession: WorkbenchJSON?
    var exclusionTarget = "specimen"
    var exclusionID = ""
    var excluded = true
    var exclusionReason = ""
    var selectedExclusion: WorkbenchJSON?
    var exclusionResolvedKey = ""
    var exclusionResolvedRevision: Int?
    func applyInspection(_ value: WorkbenchJSON) {
        layouts = value["experimentLayouts"].array; applications = value["experimentApplications"].array
        acquisitionSessions = value["acquisitionSessions"].array
    }
    func reset() {
        layouts = []; applications = []; acquisitionSessions = []; exclusions = .null; catalogue = .null
        newLayout(); selectedLayout = nil; instanceName = "Experiment instance"; experiment = ""; plateName = ""
        bindings = [:]; fields = [:]; subjects = [:]; blocks = [:]; replaceAssignments = false
        applicationPreview = nil; previewArguments = nil; previewRevision = nil; selectedApplication = nil; applicationID = ""
        newSession(); exclusionTarget = "specimen"; exclusionID = ""; exclusionReason = ""; excluded = true
        selectedExclusion = nil; exclusionResolvedKey = ""; exclusionResolvedRevision = nil
    }
    func newLayout() { layoutID = ""; layoutVersion = 1; name = "Reusable experiment"; notes = ""; factors = [WorkbenchStatFactor(id: "condition", name: "Condition")]; slots = []; hasPlate = false; rows = 8; columns = 12 }
    func loadLayout(_ layout: WorkbenchJSON, editing: Bool) {
        selectedLayout = layout; layoutID = layout["id"].string ?? ""; layoutVersion = layout["version"].integer ?? 1
        applicationPreview = nil; previewArguments = nil
        guard editing else { return }
        let definition = layout["definition"]
        name = definition["name"].string ?? "Layout"; notes = definition["notes"].string ?? ""
        factors = definition["factors"].array.map { value in WorkbenchStatFactor(id: value["id"].string ?? "", name: value["name"].string ?? "", kind: value["kind"].string ?? "categorical", levels: value["levels"].array.compactMap(\.string).joined(separator: ", "), reference: value["referenceLevel"].string ?? "", unit: value["unit"].string ?? "") }
        hasPlate = definition["plate"] != .null; rows = definition["plate"]["rows"].integer ?? 8; columns = definition["plate"]["columns"].integer ?? 12
        slots = definition["slots"].array.map { value in WorkbenchLayoutSlot(id: value["key"].string ?? UUID().uuidString, name: value["name"].string ?? "Specimen", condition: value["condition"].string ?? "", role: value["role"].string ?? "other", values: value["values"].object.mapValues { $0.string ?? $0.number.map { String($0) } ?? "" }, subjectKey: value["subjectKey"].string ?? "", blockKey: value["blockKey"].string ?? "", well: value["wellRow"] != .null, row: value["wellRow"].integer ?? 1, column: value["wellColumn"].integer ?? 1) }
    }
    func newSession() { sessionID = ""; sessionVersion = 1; acquisitionName = "Acquisition session"; instrument = ""; operatorName = ""; startedAt = ""; endedAt = ""; acquisitionNotes = ""; acquisitionImages = []; selectedSession = nil }
    var applicationArguments: WorkbenchJSON {
        var value: [String: WorkbenchJSON] = ["layoutId": .string(selectedLayout?["id"].string ?? ""), "version": .number(Double(selectedLayout?["version"].integer ?? 1)), "instanceName": .string(instanceName), "experiment": .string(experiment), "replaceAssignments": .bool(replaceAssignments)]
        value["bindings"] = .array((selectedLayout?["definition"]["slots"].array ?? []).map { slot in
            let key = slot["key"].string ?? ""
            var row: [String: WorkbenchJSON] = ["slotKey": .string(key), "imageIds": .array((bindings[key] ?? []).sorted().map(WorkbenchJSON.string))]
            if let field = fields[key], !field.isEmpty { row["field"] = .string(field) }; return .object(row)
        })
        if selectedLayout?["definition"]["plate"] != .null, !plateName.isEmpty { value["plateName"] = .string(plateName) }
        for (key, mapping) in [("subjectMapping", subjects), ("blockMapping", blocks)] {
            let entries = mapping.filter { !$0.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            if !entries.isEmpty { value[key] = .array(entries.keys.sorted().map { .object(["key": .string($0), "id": .string(entries[$0]!)]) }) }
        }
        return .object(value)
    }
    func applicationCurrent(_ revision: Int?) -> Bool { applicationPreview != nil && previewRevision == revision && previewArguments == applicationArguments }
}

extension WorkbenchSession {
    func readExperimentDefinitions() async throws {
        experimentLayouts.catalogue = try await call("experiment.layout.catalogue")["result"]
        _ = try await readCatalogue("experimentExclusions")
    }
    func experimentLayoutDefinition() throws -> [String: WorkbenchJSON] {
        let state = experimentLayouts
        let factors = state.factors.map { factor -> WorkbenchJSON in
            var value: [String: WorkbenchJSON] = ["id": .string(factor.id), "name": .string(factor.name), "kind": .string(factor.kind)]
            if factor.kind == "categorical" { value["levels"] = .array(factor.levelList.map(WorkbenchJSON.string)); value["referenceLevel"] = .string(factor.reference) }
            else if !factor.unit.isEmpty { value["unit"] = .string(factor.unit) }; return .object(value)
        }
        let slots = try state.slots.map { slot -> WorkbenchJSON in
            var values: [String: WorkbenchJSON] = [:]
            for factor in state.factors {
                let text = slot.values[factor.id] ?? ""
                if factor.kind == "numeric" {
                    guard let number = Double(text), number.isFinite else { throw WorkbenchFailure(code: "invalid-factor", message: "Enter a finite \(factor.name) value for \(slot.name).") }
                    values[factor.id] = .number(number)
                } else { values[factor.id] = .string(text) }
            }
            var row: [String: WorkbenchJSON] = ["key": .string(slot.id), "name": .string(slot.name), "condition": .string(slot.condition), "role": .string(slot.role), "values": .object(values)]
            if !slot.subjectKey.isEmpty { row["subjectKey"] = .string(slot.subjectKey) }
            if !slot.blockKey.isEmpty { row["blockKey"] = .string(slot.blockKey) }
            if state.hasPlate && slot.well { row["wellRow"] = .number(Double(slot.row)); row["wellColumn"] = .number(Double(slot.column)) }
            return .object(row)
        }
        var value: [String: WorkbenchJSON] = ["name": .string(state.name), "notes": .string(state.notes), "factors": .array(factors), "slots": .array(slots)]
        if state.hasPlate { value["plate"] = .object(["rows": .number(Double(state.rows)), "columns": .number(Double(state.columns))]) }; return value
    }
    func loadExperimentLayout(editing: Bool) {
        guard !experimentLayouts.layoutID.isEmpty else { return }
        let args: [String: WorkbenchJSON] = ["layoutId": .string(experimentLayouts.layoutID), "version": .number(Double(experimentLayouts.layoutVersion))]
        perform("Loading the retained layout version…") {
            let result = try await self.call("experiment.layout.get", arguments: args)["result"]["layout"]
            self.experimentLayouts.loadLayout(result, editing: editing)
            self.reportStatus(editing ? "Layout loaded for editing. Save appends a version; existing applications stay unchanged." : "Layout loaded for explicit specimen and image binding.")
        }
    }
    func saveExperimentLayout(asNew: Bool) {
        do {
            var args = try experimentLayoutDefinition()
            if !asNew { args["layoutId"] = .string(experimentLayouts.layoutID) }
            perform("Saving reusable experimental layout…") {
                let layout = try await self.call("experiment.layout.save", arguments: args, mutation: true)["result"]["layout"]
                try await self.inspect(); self.experimentLayouts.loadLayout(layout, editing: true)
                self.reportStatus("Layout version saved without creating specimens or changing assignments.")
            }
        } catch { self.error = error.localizedDescription }
    }
    func previewExperimentApplication() {
        let args = experimentLayouts.applicationArguments
        perform("Previewing specimen identities and assignment changes…") {
            self.experimentLayouts.applicationPreview = try await self.call("experiment.layout.apply.preview", arguments: args.object)["result"]
            self.experimentLayouts.previewArguments = args; self.experimentLayouts.previewRevision = self.revision
            self.reportStatus("Review new specimens, plate and assignment replacements before applying.")
        }
    }
    func applyExperimentLayout() {
        guard experimentLayouts.applicationCurrent(revision), let fingerprint = experimentLayouts.applicationPreview?["previewFingerprint"].string else { return }
        var args = experimentLayouts.applicationArguments.object; args["previewFingerprint"] = .string(fingerprint)
        perform("Applying the reviewed experiment layout…") {
            let result = try await self.call("experiment.layout.apply.run", arguments: args, mutation: true)["result"]
            self.experimentLayouts.selectedApplication = result["application"]
            self.experimentLayouts.applicationID = result["application"]["id"].string ?? ""
            self.experimentLayouts.applicationPreview = nil; try await self.inspect(); try await self.readExperimentDefinitions()
            self.reportStatus("Layout applied with new specimen identities and retained factor assignments.")
        }
    }
    func loadExperimentApplication() {
        let id = experimentLayouts.applicationID; guard !id.isEmpty else { return }
        perform("Loading layout application…") {
            self.experimentLayouts.selectedApplication = try await self.call("experiment.layout.application.get", arguments: ["applicationId": .string(id)])["result"]["application"]
        }
    }
    func draftStatisticsFromApplication() {
        guard !statistics.dirty, let id = experimentLayouts.selectedApplication?["id"].string else { return }
        do {
            let outcome = try statisticalDefinition()["outcome"]
            perform("Preparing statistical rows from the layout application…") {
                let result = try await self.call("experiment.layout.application.statistics", arguments: ["applicationId": .string(id), "outcome": outcome])["result"]
                self.statistics.selectedDesignID = ""; self.statistics.selectedDesign = nil
                self.statistics.loadDefinition(result["definition"], specimens: self.specimens)
                self.reportStatus("Statistical draft prepared. Open Statistics to choose its outcome and preview specimen coverage before saving.")
            }
        } catch { self.error = error.localizedDescription }
    }
    func loadAcquisitionSession() {
        let state = experimentLayouts; guard !state.sessionID.isEmpty else { return }
        let args: [String: WorkbenchJSON] = ["sessionId": .string(state.sessionID), "version": .number(Double(state.sessionVersion))]
        perform("Loading acquisition session metadata…") {
            let result = try await self.call("acquisition.session.get", arguments: args)["result"]["session"]
            state.selectedSession = result; state.acquisitionName = result["name"].string ?? ""; state.instrument = result["instrument"].string ?? ""
            state.operatorName = result["operator"].string ?? ""; state.startedAt = result["startedAt"].string ?? ""; state.endedAt = result["endedAt"].string ?? ""
            state.acquisitionNotes = result["notes"].string ?? ""; state.acquisitionImages = Set(result["members"].array.compactMap { $0["imageId"].string })
        }
    }
    func saveAcquisitionSession(asNew: Bool) {
        let state = experimentLayouts
        var args: [String: WorkbenchJSON] = ["name": .string(state.acquisitionName), "instrument": .string(state.instrument), "imageIds": .array(state.acquisitionImages.sorted().map(WorkbenchJSON.string)), "notes": .string(state.acquisitionNotes)]
        for (key, text) in [("operator", state.operatorName), ("startedAt", state.startedAt), ("endedAt", state.endedAt)] { if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { args[key] = .string(text) } }
        if !asNew { args["sessionId"] = .string(state.sessionID) }
        perform("Saving acquisition session metadata…") {
            let record = try await self.call("acquisition.session.save", arguments: args, mutation: true)["result"]["session"]
            state.selectedSession = record; state.sessionID = record["id"].string ?? ""; state.sessionVersion = record["version"].integer ?? 1
            try await self.inspect(); self.reportStatus("Acquisition membership saved; biological specimen assignments are unchanged.")
        }
    }
    func loadSelectedExclusion() {
        let state = experimentLayouts, key = experimentLayouts.exclusionTarget + ":" + experimentLayouts.exclusionID
        guard !state.exclusionID.isEmpty else { return }
        perform("Reading the selected target's effective exclusion decision…", refreshOnConflict: false) {
            state.selectedExclusion = nil; state.exclusionResolvedKey = ""; state.exclusionResolvedRevision = nil
            state.selectedExclusion = try await self.resolveCatalogueEntries("experimentExclusions", ids: [key]).first
            state.exclusionResolvedKey = key; state.exclusionResolvedRevision = self.revision
            self.reportStatus("Selected target resolved. The new decision draft is unchanged.")
        }
    }
    func saveExperimentExclusion() {
        let state = experimentLayouts
        let args: [String: WorkbenchJSON] = ["target": .string(state.exclusionTarget), "targetId": .string(state.exclusionID), "excluded": .bool(state.excluded), "reason": .string(state.exclusionReason)]
        perform("Recording the reasoned exclusion decision…") {
            _ = try await self.call("experiment.exclusion.set", arguments: args, mutation: true)
            try await self.inspect(); try await self.readExperimentDefinitions()
            state.selectedExclusion = try await self.resolveCatalogueEntries("experimentExclusions", ids: [state.exclusionTarget + ":" + state.exclusionID]).first
            state.exclusionResolvedKey = state.exclusionTarget + ":" + state.exclusionID; state.exclusionResolvedRevision = self.revision
            self.reportStatus("Exclusion history updated. Historical outputs remain retained; current summaries follow the effective decision.")
        }
    }
}
