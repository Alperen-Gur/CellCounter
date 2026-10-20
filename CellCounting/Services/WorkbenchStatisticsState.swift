import Foundation
import Observation

struct WorkbenchStatFactor: Identifiable {
    var id: String
    var name: String
    var kind = "categorical"
    var levels = "Control, Treatment"
    var reference = "Control"
    var unit = ""
    var levelList: [String] { levels.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty } }
}
struct WorkbenchStatSpecimen: Identifiable {
    var id: String
    var name: String
    var subject = ""
    var block = ""
    var values: [String: String] = [:]
    var exclusion = ""
}
struct WorkbenchStatContrast: Identifiable {
    var id = UUID().uuidString
    var factorID = ""
    var reference = ""
    var comparison = ""
}
struct WorkbenchStatInteraction: Identifiable {
    var id = UUID()
    var first = ""
    var second = ""
}

@MainActor @Observable
final class WorkbenchStatisticsState {
    var editorOpen = false
    var catalogue: WorkbenchJSON = .null
    var designs: [WorkbenchJSON] = []
    var runs: [WorkbenchJSON] = []
    var selectedDesignID = ""
    var selectedVersion = 1
    var selectedDesign: WorkbenchJSON?
    var name = "Specimen comparison"
    var outcomeKind = "measurement"
    var metric = "count"
    var target = "plane"
    var time = 1
    var channel = 1
    var assayRunID = ""
    var assayMetricPath = ""
    var assayMetrics: WorkbenchJSON?
    var factors = [WorkbenchStatFactor(id: "condition", name: "Condition")]
    var rows: [WorkbenchStatSpecimen] = []
    var definitionPreview: WorkbenchJSON?
    var previewDefinition: WorkbenchJSON?
    var definitionPreviewRevision: Int?
    var originalDraft: WorkbenchJSON?
    var method = "welch-t"
    var terms: Set<String> = ["condition"]
    var contrasts: [WorkbenchStatContrast] = []
    var interactions: [WorkbenchStatInteraction] = []
    var blocking = "none"
    var covariance = "classical"
    var confidence = 0.95
    var multiplicity = "holm"
    var inferencePreview: WorkbenchJSON?
    var inferenceArguments: [String: WorkbenchJSON]?
    var inferenceRevision: Int?
    var recomputeRunID: String?
    var selectedRun: WorkbenchJSON?
    var exportFormats: [WorkbenchImageExportFormat] = []
    var exportFormat = "results-json"
    var exportResult: WorkbenchJSON?
    var draft: WorkbenchJSON {
        .object(["name": .string(name), "outcomeKind": .string(outcomeKind), "metric": .string(metric), "target": .string(target),
            "time": .number(Double(time)), "channel": .number(Double(channel)), "assayRunId": .string(assayRunID), "metricPath": .string(assayMetricPath),
            "factors": .array(factors.map { .object(["id": .string($0.id), "name": .string($0.name), "kind": .string($0.kind),
                "levels": .string($0.levels), "reference": .string($0.reference), "unit": .string($0.unit)]) }),
            "rows": .array(rows.map { .object(["id": .string($0.id), "subject": .string($0.subject), "block": .string($0.block),
                "values": .object($0.values.mapValues(WorkbenchJSON.string)), "exclusion": .string($0.exclusion)]) })])
    }
    var dirty: Bool { originalDraft != nil && originalDraft != draft }
    func applyInspection(_ value: WorkbenchJSON) {
        designs = value["statisticsDesigns"].array; runs = value["statisticsRuns"].array
        if let selected = selectedDesign,
           let compact = designs.first(where: { $0["id"] == selected["id"] && $0["version"] == selected["version"] }) {
            var updated = selected.object
            updated["inputsCurrent"] = compact["inputsCurrent"]; selectedDesign = .object(updated)
        }
        if let selected = selectedRun, let compact = runs.first(where: { $0["id"] == selected["id"] }) {
            var updated = selected.object
            updated["outputsCurrent"] = compact["outputsCurrent"]
            updated["replacementRunId"] = compact["replacementRunId"]; selectedRun = .object(updated)
        }
    }
    func reset() {
        designs = []; runs = []; selectedDesignID = ""; selectedDesign = nil; selectedVersion = 1
        rows = []; factors = [WorkbenchStatFactor(id: "condition", name: "Condition")]
        name = "Specimen comparison"; outcomeKind = "measurement"; metric = "count"; target = "plane"; time = 1; channel = 1
        assayRunID = ""; assayMetricPath = ""; assayMetrics = nil
        method = "welch-t"; terms = ["condition"]; contrasts = []; interactions = []; blocking = "none"
        covariance = "classical"; confidence = 0.95; multiplicity = "holm"
        originalDraft = draft; definitionPreview = nil; previewDefinition = nil
        inferencePreview = nil; selectedRun = nil; inferenceArguments = nil; recomputeRunID = nil
        exportFormats = []; exportResult = nil; catalogue = .null
    }
    func loadDefinition(_ value: WorkbenchJSON, specimens: [WorkbenchSpecimen]) {
        name = value["name"].string ?? "Specimen comparison"
        let outcome = value["outcome"]
        outcomeKind = outcome["kind"].string ?? "measurement"; metric = outcome["metric"].string ?? "count"
        target = outcome["target"].string ?? "plane"; time = (outcome["timeIndex"].integer ?? 0) + 1; channel = (outcome["channel"].integer ?? 0) + 1
        assayRunID = outcome["runId"].string ?? ""; assayMetricPath = outcome["metricPath"].string ?? ""
        factors = value["factors"].array.map { factor in
            WorkbenchStatFactor(id: factor["id"].string ?? "factor", name: factor["name"].string ?? "Factor", kind: factor["kind"].string ?? "categorical",
                levels: factor["levels"].array.compactMap(\.string).joined(separator: ", "), reference: factor["referenceLevel"].string ?? "", unit: factor["unit"].string ?? "")
        }
        let exclusions = Dictionary(uniqueKeysWithValues: value["exclusions"].array.compactMap { entry -> (String, String)? in
            guard let id = entry["specimenId"].string else { return nil }; return (id, entry["reason"].string ?? "")
        })
        rows = value["rows"].array.compactMap { row in
            guard let id = row["specimenId"].string else { return nil }
            return WorkbenchStatSpecimen(id: id, name: specimens.first { $0.id == id }?.name ?? "Retained specimen",
                subject: row["subjectId"].string ?? "", block: row["blockId"].string ?? "",
                values: row["values"].object.mapValues { $0.string ?? $0.number.map { String($0) } ?? "" }, exclusion: exclusions[id] ?? "")
        }
        terms = Set(factors.map(\.id)); contrasts = []; interactions = []
        definitionPreview = nil; previewDefinition = nil; inferencePreview = nil; originalDraft = draft
    }
}

extension WorkbenchSession {
    func loadStatistics() {
        perform("Loading specimen-level statistics…", refreshOnConflict: false) {
            self.statistics.catalogue = try await self.call("statistics.catalogue")["result"]
            self.assaySeries.runs = try await self.readCatalogue("assaySeriesRuns")
            self.statistics.designs = try await self.readCatalogue("statisticsDesigns")
            self.statistics.runs = try await self.readCatalogue("statisticsRuns")
            self.statistics.exportFormats = try await self.call("statistics.export.catalogue")["result"]["formats"].array.compactMap(WorkbenchImageExportFormat.init)
            if self.statistics.originalDraft == nil { self.statistics.originalDraft = self.statistics.draft }
            self.reportStatus("Statistical designs use biological specimens; image objects do not increase biological n.")
        }
    }
    func seedStatisticalRows() {
        perform("Loading biological specimens into the statistical draft…", refreshOnConflict: false) {
            var all: [WorkbenchSpecimen] = []; var cursor: String?
            repeat {
                var args: [String: WorkbenchJSON] = ["catalogue": .string("specimens"), "limit": .number(100)]
                if let cursor { args["cursor"] = .string(cursor) }
                let result = try await self.call("project.catalogue", arguments: args)["result"]
                guard (result["total"].integer ?? 0) <= 1000 else { throw WorkbenchFailure(code: "selection-limit", message: "A statistical design supports at most 1,000 specimens. Select a retained layout application or a bounded specimen cohort.") }
                all += result["entries"].array.compactMap(WorkbenchSpecimen.init); cursor = result["nextCursor"].string
            } while cursor != nil
            let existing = Set(self.statistics.rows.map(\.id))
            let levels = Array(Set(all.map(\.condition))).sorted()
            if self.statistics.factors.count == 1 && self.statistics.factors[0].id == "condition" {
                self.statistics.factors[0].levels = levels.joined(separator: ", "); self.statistics.factors[0].reference = levels.first ?? ""
            }
            self.statistics.rows += all.filter { !existing.contains($0.id) }.map { specimen in
                WorkbenchStatSpecimen(id: specimen.id, name: specimen.name, values: Dictionary(uniqueKeysWithValues: self.statistics.factors.map { factor in
                    (factor.id, factor.id == "condition" ? specimen.condition : factor.kind == "numeric" ? "0" : factor.levelList.first ?? "")
                }))
            }
            self.reportStatus("All \(all.count) project specimens were resolved explicitly; the loaded catalogue page was not treated as the whole experiment.")
        }
    }
    func statisticalDefinition() throws -> WorkbenchJSON {
        var outcome: [String: WorkbenchJSON] = ["kind": .string(statistics.outcomeKind)]
        if ["assay", "assay-series"].contains(statistics.outcomeKind) {
            outcome["runId"] = .string(statistics.assayRunID); outcome["metricPath"] = .string(statistics.assayMetricPath)
        } else {
            outcome["metric"] = .string(statistics.metric); outcome["target"] = .string(statistics.target)
            if statistics.target == "volume" { outcome["timeIndex"] = .number(Double(statistics.time - 1)); outcome["channel"] = .number(Double(statistics.channel - 1)) }
        }
        let factors: [WorkbenchJSON] = statistics.factors.map { factor in
            var value: [String: WorkbenchJSON] = ["id": .string(factor.id), "name": .string(factor.name), "kind": .string(factor.kind)]
            if factor.kind == "categorical" { value["levels"] = .array(factor.levelList.map(WorkbenchJSON.string)); value["referenceLevel"] = .string(factor.reference) }
            else if !factor.unit.isEmpty { value["unit"] = .string(factor.unit) }
            return .object(value)
        }
        let rows: [WorkbenchJSON] = try statistics.rows.map { row in
            var values: [String: WorkbenchJSON] = [:]
            for factor in statistics.factors {
                let text = row.values[factor.id] ?? ""
                if factor.kind == "numeric" {
                    guard let number = Double(text), number.isFinite else {
                        throw WorkbenchFailure(code: "invalid-factor-value", message: "\(row.name) needs a finite numeric value for \(factor.name).")
                    }
                    values[factor.id] = .number(number)
                } else { values[factor.id] = .string(text) }
            }
            var value: [String: WorkbenchJSON] = ["specimenId": .string(row.id), "values": .object(values)]
            if !row.subject.isEmpty { value["subjectId"] = .string(row.subject) }
            if !row.block.isEmpty { value["blockId"] = .string(row.block) }
            return .object(value)
        }
        return .object(["name": .string(statistics.name), "outcome": .object(outcome), "factors": .array(factors), "rows": .array(rows),
            "exclusions": .array(statistics.rows.filter { !$0.exclusion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.map {
                .object(["specimenId": .string($0.id), "reason": .string($0.exclusion)])
            })])
    }
    func previewStatisticalDesign() {
        do {
            let definition = try statisticalDefinition()
            perform("Resolving biological-replicate inputs…", refreshOnConflict: false) {
                self.statistics.definitionPreview = try await self.call("statistics.design.preview", arguments: definition.object)["result"]["plan"]
                self.statistics.previewDefinition = definition; self.statistics.definitionPreviewRevision = self.revision
                self.reportStatus("Review specimen coverage and exclusions before saving the design.")
            }
        } catch { self.error = error.localizedDescription }
    }
    func saveStatisticalDesign(asNew: Bool) {
        guard !hasActiveWorkers, let preview = statistics.definitionPreview,
              statistics.definitionPreviewRevision == revision, let fingerprint = preview["previewFingerprint"].string else { return }
        do {
            let definition = try statisticalDefinition()
            guard definition == statistics.previewDefinition else { throw WorkbenchFailure(code: "preview-expired", message: "Design fields changed. Preview the design again before saving.") }
            var args = definition.object; args["previewFingerprint"] = .string(fingerprint)
            if !asNew && !statistics.selectedDesignID.isEmpty { args["designId"] = .string(statistics.selectedDesignID) }
            perform("Saving statistical design version…", refreshOnConflict: false) {
                let design = try await self.call("statistics.design.save", arguments: args, mutation: true)["result"]["design"]
                self.statistics.selectedDesign = design; self.statistics.selectedDesignID = design["id"].string ?? ""
                self.statistics.selectedVersion = design["version"].integer ?? 1; self.statistics.originalDraft = self.statistics.draft
                self.statistics.definitionPreview = nil; self.statistics.inferencePreview = nil
                try await self.inspectFromChanges(preserveDisplayedImage: true)
                self.reportStatus("Design and exact specimen input table retained as an immutable version.")
            }
        } catch { self.error = error.localizedDescription }
    }
    func loadStatisticalDesign(forEditing: Bool) {
        guard !statistics.selectedDesignID.isEmpty, !statistics.dirty else { return }
        perform("Loading saved design version…", refreshOnConflict: false) {
            let design = try await self.call("statistics.design.get", arguments: ["designId": .string(self.statistics.selectedDesignID), "version": .number(Double(self.statistics.selectedVersion))])["result"]["design"]
            self.statistics.selectedDesign = design
            if forEditing { self.statistics.loadDefinition(design["definition"], specimens: self.specimens) }
            self.statistics.inferencePreview = nil
        }
    }
    func loadStatisticalAssayMetrics() {
        guard !statistics.assayRunID.isEmpty else { return }
        perform("Loading assay outcome choices…", refreshOnConflict: false) {
            self.statistics.assayMetrics = try await self.call("assay.metrics", arguments: ["runId": .string(self.statistics.assayRunID)])["result"]
            self.statistics.assayMetricPath = self.statistics.assayMetrics?["metrics"].array.first?["path"].string ?? ""
        }
    }
    var statisticalAnalysis: WorkbenchJSON {
        var value: [String: WorkbenchJSON] = ["method": .string(statistics.method), "blocking": .string(statistics.blocking),
            "covariance": .string(statistics.covariance), "confidenceLevel": .number(statistics.confidence), "multiplicity": .string(statistics.multiplicity),
            "contrasts": .array(statistics.contrasts.map { .object(["id": .string($0.id), "factorId": .string($0.factorID), "reference": .string($0.reference), "comparison": .string($0.comparison)]) })]
        if statistics.method == "linear-model" {
            value["terms"] = .array(statistics.terms.sorted().map(WorkbenchJSON.string))
            value["interactions"] = .array(statistics.interactions.map { .array([.string($0.first), .string($0.second)]) })
        }
        return .object(value)
    }
    func previewStatisticalInference(recompute: Bool = false) {
        var args: [String: WorkbenchJSON]
        let operation: String
        if recompute {
            guard let id = statistics.selectedRun?["id"].string else { return }
            args = ["runId": .string(id)]; operation = "statistics.recompute.preview"
        } else {
            guard let design = statistics.selectedDesign, let id = design["id"].string, let version = design["version"].integer else { return }
            args = ["designId": .string(id), "version": .number(Double(version)), "analysis": statisticalAnalysis]; operation = "statistics.preview"
        }
        perform(recompute ? "Previewing recomputation from current specimens…" : "Previewing declared statistical inference…", refreshOnConflict: false) {
            self.statistics.inferencePreview = try await self.call(operation, arguments: args)["result"]["preview"]
            self.statistics.inferenceArguments = args; self.statistics.inferenceRevision = self.revision
            self.statistics.recomputeRunID = recompute ? args["runId"]?.string : nil
            self.reportStatus("Inference preview ready. Review assumptions, estimability and pointwise intervals before retaining a result.")
        }
    }
    func saveStatisticalInference() {
        guard !hasActiveWorkers, let preview = statistics.inferencePreview, preview["status"].string == "ready",
              statistics.inferenceRevision == revision, let fingerprint = preview["previewFingerprint"].string,
              var args = statistics.inferenceArguments else { return }
        if statistics.recomputeRunID == nil && args["analysis"] != statisticalAnalysis { error = "Inference settings changed. Preview again before saving."; return }
        args["previewFingerprint"] = .string(fingerprint)
        let operation = statistics.recomputeRunID == nil ? "statistics.run" : "statistics.recompute.run"
        perform("Retaining statistical result…", refreshOnConflict: false) {
            self.statistics.selectedRun = try await self.call(operation, arguments: args, mutation: true)["result"]["run"]
            self.statistics.inferencePreview = nil; self.statistics.inferenceArguments = nil; self.statistics.recomputeRunID = nil
            try await self.inspectFromChanges(preserveDisplayedImage: true)
            self.reportStatus("Statistical result retained with its exact specimen table, declared model and provenance.")
        }
    }
    func loadStatisticalRun(_ id: String) {
        perform("Loading retained statistical result…", refreshOnConflict: false) {
            self.statistics.selectedRun = try await self.call("statistics.get", arguments: ["runId": .string(id)])["result"]["run"]
        }
    }
    func exportStatisticalRun(to destination: URL) {
        guard let id = statistics.selectedRun?["id"].string, !hasActiveWorkers else { return }
        guard !FileManager.default.fileExists(atPath: destination.path) else { error = "Choose a new export file; existing results are preserved."; return }
        perform("Exporting retained statistical report…", refreshOnConflict: false) {
            self.statistics.exportResult = try await self.call("statistics.export", arguments: ["runId": .string(id), "format": .string(self.statistics.exportFormat), "destination": .string(destination.path)], mutation: true)["result"]
            try await self.inspectFromChanges(preserveDisplayedImage: true)
            self.reportStatus("Retained statistical report exported.")
        }
    }
}
