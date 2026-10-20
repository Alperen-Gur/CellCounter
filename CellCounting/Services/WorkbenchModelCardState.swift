import Foundation
import Observation

@MainActor @Observable
final class WorkbenchModelCardDraft {
    var intendedUse = ""
    var limitations = ""
    var notes = ""
    var evaluationIDs: Set<String> = []
    var activationReason = ""
    private var baseline: WorkbenchJSON = .object(["intendedUse": .string(""), "limitations": .string(""), "notes": .string(""), "evaluations": .array([])])
    private var definition: WorkbenchJSON { .object(["intendedUse": .string(intendedUse), "limitations": .string(limitations), "notes": .string(notes), "evaluations": .array(evaluationIDs.sorted().map(WorkbenchJSON.string))]) }
    var dirty: Bool { definition != baseline }
    func load(_ card: WorkbenchJSON) {
        intendedUse = card["intendedUse"].string ?? ""; limitations = card["limitations"].string ?? ""
        notes = card["notes"].string ?? ""; evaluationIDs = Set(card["evaluations"].array.compactMap { $0["evaluationId"].string })
        baseline = definition
    }
}

extension WorkbenchSession {
    func loadModelCard(_ id: String, version: Int? = nil) {
        var args: [String: WorkbenchJSON] = ["modelId": .string(id)]
        if let version { args["version"] = .number(Double(version)) }
        perform("Loading retained model card…", refreshOnConflict: false) {
            self.models.cards[id] = try await self.call("model.card.get", arguments: args)["result"]
            let defaultResult = try await self.call("model.activation.get")["result"]
            self.models.activation = defaultResult["activation"]; self.models.activationHistory = defaultResult["history"].array
            self.reportStatus("Card and future-default history loaded. Authored drafts and inference settings are unchanged.")
        }
    }
    func saveModelCard(_ id: String) {
        let draft = models.cardDraft(id)
        let args: [String: WorkbenchJSON] = ["modelId": .string(id), "intendedUse": .string(draft.intendedUse),
            "limitations": .string(draft.limitations), "notes": .string(draft.notes),
            "evaluationIds": .array(draft.evaluationIDs.sorted().map(WorkbenchJSON.string))]
        perform("Saving an immutable authored model card…") {
            let card = try await self.call("model.card.save", arguments: args, mutation: true)["result"]["card"]
            self.models.cards[id] = try await self.call("model.card.get", arguments: ["modelId": .string(id)])["result"]
            draft.load(card); try await self.inspect()
            self.reportStatus("Model card version saved with exact model, training and comparison identities.")
        }
    }
    func setFutureModelDefault(_ id: String?, reason: String) {
        perform("Recording the future model-selection default…") {
            self.models.activation = try await self.call("model.activation.set", arguments: [
                "modelId": id.map(WorkbenchJSON.string) ?? .null, "reason": .string(reason)], mutation: true)["result"]["activation"]
            try await self.inspect()
            let record = try await self.call("model.activation.get")["result"]
            self.models.activationHistory = record["history"].array
            self.reportStatus("Future default updated. Current model controls, trusted state, saved masks and workflows are unchanged.")
        }
    }
}
