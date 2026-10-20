import Foundation
import Testing
@testable import CellCounting

@Suite(.serialized) @MainActor
struct WorkbenchStateRetentionTests {
    @Test func futureDefaultNeverReplacesAnExistingModelSelectionOrTrust() {
        let models = WorkbenchModelState()
        let first: WorkbenchJSON = .object(["models": .array([.object(["id": .string("first"), "enabled": .bool(false)])]),
            "modelActivation": .object(["modelId": .string("older-default"), "available": .bool(true)])])
        models.applyInspection(first)
        #expect(models.selectedModelID == "older-default")
        #expect(models.models.first?.enabled == false)
        models.selectedModelID = "authored-selection"
        models.applyInspection(.object(["models": .array([]),
            "modelActivation": .object(["modelId": .string("new-default"), "available": .bool(true)])]))
        #expect(models.selectedModelID == "authored-selection")
    }

    @Test func modelCardDirtyStateTracksAuthoredChangesAndRestoredBaseline() {
        let draft = WorkbenchModelCardDraft()
        let saved: WorkbenchJSON = .object(["intendedUse": .string("Cell outlines"), "limitations": .string("No crowded tissue"),
            "notes": .string("Local reference set"), "evaluations": .array([.object(["evaluationId": .string("evaluation")])])])
        draft.load(saved)
        #expect(!draft.dirty && draft.evaluationIDs == ["evaluation"])
        draft.intendedUse = "Other use"
        #expect(draft.dirty)
        draft.load(saved)
        #expect(!draft.dirty)
        draft.activationReason = "Choose for future analyses"
        #expect(!draft.dirty)
    }

    @Test func completeTrainingActivityIsNotInferredFromRecentCatalogueRows() {
        let models = WorkbenchModelState()
        models.applyInspection(.object(["trainingJobs": .array([]), "activeTrainingJobs": .array([
            .object(["id": .string("old-active-job"), "status": .string("running")])])]))
        #expect(models.hasActiveTraining && models.jobs.count == 1)
        models.applyActivity([], recent: [.object(["id": .string("old-active-job"), "status": .string("completed")])])
        #expect(!models.hasActiveTraining)
        #expect(models.jobs.first?["status"].string == "completed")
    }
}
