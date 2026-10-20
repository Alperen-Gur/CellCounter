import Foundation
import Observation

@MainActor @Observable
final class WorkbenchGraphContinuationDraft {
    var checkpointIndex = 0
    var corrections: [String: String] = [:]
    var imageQuery = ""
    var exportDestination = ""
    var preview: WorkbenchJSON = .null
    var previewArguments: WorkbenchJSON = .null
    var previewRevision: Int?
    var createdJobID: String?
    func arguments(jobID: String) -> WorkbenchJSON {
        var result: [String: WorkbenchJSON] = ["jobId": .string(jobID), "checkpointIndex": .number(Double(checkpointIndex)),
            "corrections": .array(corrections.keys.sorted().map { .object(["nodeId": .string($0), "imageId": .string(corrections[$0] ?? "")]) })]
        if !exportDestination.isEmpty { result["exportDestination"] = .string(exportDestination) }
        return .object(result)
    }
    func selectCheckpoint(_ index: Int) {
        checkpointIndex = index; corrections = [:]; preview = .null; previewArguments = .null; previewRevision = nil
    }
}

extension WorkbenchSession {
    func readGraphReview(jobID: String, checkpointIndex: Int, nodeID: String) {
        let key = "\(jobID):\(checkpointIndex):\(nodeID)"
        perform("Reading exact workflow review binding…", refreshOnConflict: false) {
            let result = try await self.call("job.graph.review.get", arguments: ["jobId": .string(jobID),
                "checkpointIndex": .number(Double(checkpointIndex)), "nodeId": .string(nodeID)])["result"]
            self.workflowGraph.reviewRecords[key] = result["review"]
            self.workflowGraph.selectedReviewKeys[jobID] = key
            self.reportStatus("Review binding and retained decisions loaded. Open the corresponding mask to inspect or correct it.")
        }
    }

    func recordGraphReview(_ review: WorkbenchJSON, choice: String, recommendation: Bool) {
        guard canRefreshWithoutDiscardingEdits, !hasActiveWorkers,
              let jobID = review["jobId"].string, let nodeID = review["nodeId"].string,
              let index = review["checkpointIndex"].integer, let fingerprint = review["inputFingerprint"].string,
              review["inputsCurrent"].bool == true else { return }
        let key = "\(jobID):\(index):\(nodeID)"
        let reason = (workflowGraph.reviewReasons[key] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !reason.isEmpty, reason.count <= 2000 else { error = "Enter a review reason of 1–2,000 characters."; return }
        var args: [String: WorkbenchJSON] = ["jobId": .string(jobID), "nodeId": .string(nodeID),
            "checkpointIndex": .number(Double(index)), "inputFingerprint": .string(fingerprint), "reason": .string(reason)]
        args[recommendation ? "recommendation" : "decision"] = .string(choice)
        if !recommendation { args["reviewerKind"] = .string("human") }
        perform(recommendation ? "Saving workflow recommendation…" : "Recording human-labelled workflow review…", refreshOnConflict: false) {
            let result = try await self.call(recommendation ? "job.graph.review.recommend" : "job.graph.review.decide", arguments: args, mutation: true)["result"]
            self.workflowGraph.reviewRecords[key] = result["review"]
            self.workflowGraph.selectedReviewKeys[jobID] = key
            self.workflowGraph.jobDetails[jobID] = result["job"]
            self.workflowGraph.jobRevisions[jobID] = self.revision
            try await self.inspectFromChanges(preserveDisplayedImage: true)
            self.reportStatus(recommendation ? "Recommendation retained. It did not complete the review gate." : choice == "approve"
                ? "Review approved for this exact mask. Resume checkpoint execution explicitly."
                : "Review rejected. Correct the mask and preview an independent continuation, or record a subsequent explicit decision.")
        }
    }

    func prepareGraphContinuation(jobID: String) {
        if workflowGraph.continuationDrafts[jobID] == nil {
            workflowGraph.continuationDrafts[jobID] = WorkbenchGraphContinuationDraft()
        }
    }
    func previewGraphContinuation(jobID: String) {
        guard let draft = workflowGraph.continuationDrafts[jobID], !draft.corrections.isEmpty,
              draft.corrections.count <= 8, !hasActiveWorkers, canRefreshWithoutDiscardingEdits else { return }
        let args = draft.arguments(jobID: jobID)
        perform("Planning continuation from corrected masks…", refreshOnConflict: false) {
            let result = try await self.call("job.graph.continue.preview", arguments: args.object)["result"]
            guard draft.arguments(jobID: jobID) == args else { return }
            draft.preview = result; draft.previewArguments = args; draft.previewRevision = self.revision
            self.reportStatus("Corrected continuation planned. Review the reused and reset branches before creating the new job.")
        }
    }
    func createGraphContinuation(jobID: String) {
        guard let draft = workflowGraph.continuationDrafts[jobID], let fingerprint = draft.preview["previewFingerprint"].string,
              draft.previewArguments == draft.arguments(jobID: jobID), draft.previewRevision == revision,
              !hasActiveWorkers, canRefreshWithoutDiscardingEdits else { return }
        var args = draft.arguments(jobID: jobID).object; args["previewFingerprint"] = .string(fingerprint)
        perform("Creating corrected workflow continuation…", refreshOnConflict: false) {
            let result = try await self.call("job.graph.continue.run", arguments: args, mutation: true)["result"]
            try await self.inspectFromChanges(preserveDisplayedImage: true)
            draft.createdJobID = result["job"]["id"].string; draft.preview = .null; draft.previewArguments = .null; draft.previewRevision = nil
            self.reportStatus("Independent continuation created. Corrected masks are preserved; run its remaining checkpoints from Jobs.")
        }
    }
}
