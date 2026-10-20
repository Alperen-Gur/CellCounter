import AppKit
import Observation

@MainActor @Observable
final class WorkbenchReviewState {
    var sessions: [WorkbenchJSON] = []
    var selectedSessionID = ""
    var reviewerID = ""
    var session: WorkbenchJSON?
    var selectedItemID = ""
    var preview: NSImage?
    var overlay: NSImage?
    var previewInfo: WorkbenchJSON?
    var summary: WorkbenchJSON?
    var items: [WorkbenchJSON] { session?["items"].array ?? [] }
    var selectedItem: WorkbenchJSON? { items.first { $0["id"].string == selectedItemID } }
    var blinded: Bool { session?["blinded"].bool == true }
    func clearPreview() { preview = nil; overlay = nil; previewInfo = nil }
    func reset() {
        sessions = []; selectedSessionID = ""; reviewerID = ""; session = nil
        selectedItemID = ""; summary = nil; clearPreview()
    }
}

extension WorkbenchSession {
    func loadReviews() {
        perform("Loading review sessions…") {
            try await self.readReviewSessions()
            if !self.review.selectedSessionID.isEmpty { try await self.readReviewSession() }
            self.reportStatus("Review sessions loaded.")
        }
    }

    func selectReviewSession(_ id: String) {
        guard !busy else { return }
        review.selectedSessionID = id
        review.session = nil; review.selectedItemID = ""; review.clearPreview()
        perform("Loading review queue…") { try await self.readReviewSession() }
    }

    func selectReviewer(_ id: String) {
        guard !busy else { return }
        review.reviewerID = id
        review.clearPreview()
        perform("Loading declared reviewer’s queue…") { try await self.readReviewSession() }
    }

    func selectReviewItem(_ id: String) {
        guard !busy else { return }
        review.selectedItemID = id
        review.clearPreview()
        perform("Loading frozen review image…") { try await self.readReviewPreview() }
    }

    func loadReviewSlice(plane: String, index: Int?) {
        perform("Loading frozen review slice…") {
            try await self.readReviewPreview(plane: plane, index: index)
        }
    }

    func flagReviewImages(imageIDs: Set<String>, state: String, reason: String,
                          allTimePoints: Bool) {
        var args = reviewSelection(imageIDs: imageIDs, allTimePoints: allTimePoints)
        args["state"] = .string(state)
        if !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { args["reason"] = .string(reason) }
        perform("Saving review classification…") {
            _ = try await self.call("review.flag", arguments: args, mutation: true)
            try await self.inspect()
            self.review.summary = nil
            self.reportStatus("Review classification saved for the current analysis inputs.")
        }
    }

    func createReview(name: String, imageIDs: Set<String>, allTimePoints: Bool,
                      unit: String, sampleSize: Int, seed: Int, acceptedOnly: Bool,
                      blinded: Bool, reviewers: [(id: String, name: String)], requiredReviews: Int) {
        var args = reviewSelection(imageIDs: imageIDs, allTimePoints: allTimePoints)
        args.merge([
            "name": .string(name), "unit": .string(unit), "sampleSize": .number(Double(sampleSize)),
            "seed": .number(Double(seed)), "acceptedOnly": .bool(acceptedOnly), "blinded": .bool(blinded),
            "requiredReviews": .number(Double(requiredReviews)),
            "reviewers": .array(reviewers.map {
                .object(["id": .string($0.id), "name": .string($0.name)])
            })
        ]) { _, new in new }
        perform("Freezing a random review sample…") {
            let result = try await self.call("review.session.create", arguments: args, mutation: true)["result"]
            self.review.selectedSessionID = result["session"]["id"].string ?? ""
            self.review.reviewerID = reviewers.first?.id ?? ""
            self.review.selectedItemID = ""
            self.review.summary = nil
            try await self.inspect()
            try await self.readReviewSessions()
            try await self.readReviewSession()
            self.reportStatus("Random sample frozen. Review source and mask snapshots are retained.")
        }
    }

    func recordReview(decision: String, reason: String, errorType: String, adjudicate: Bool = false) {
        guard !review.selectedSessionID.isEmpty, !review.selectedItemID.isEmpty else { return }
        var args: [String: WorkbenchJSON] = [
            "sessionId": .string(review.selectedSessionID), "itemId": .string(review.selectedItemID),
            "decision": .string(decision)
        ]
        if !adjudicate {
            args["reviewerId"] = .string(review.reviewerID)
            args["errorType"] = .string(decision == "accept" ? "none" : errorType)
        }
        let trimmed = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { args["reason"] = .string(trimmed) }
        perform(adjudicate ? "Saving adjudication…" : "Saving independent review…") {
            _ = try await self.call(adjudicate ? "review.adjudicate" : "review.decision", arguments: args, mutation: true)
            try await self.inspect()
            try await self.readReviewSessions()
            try await self.readReviewSession(reloadPreview: false)
            self.review.summary = nil
            self.reportStatus("Decision recorded. Earlier decisions remain in the review history.")
        }
    }

    func revealReview(reason: String) {
        perform("Ending review presentation blinding…") {
            _ = try await self.call("review.reveal", arguments: [
                "sessionId": .string(self.review.selectedSessionID), "reason": .string(reason)
            ], mutation: true)
            try await self.inspect()
            try await self.readReviewSessions()
            try await self.readReviewSession(reloadPreview: false)
            self.reportStatus("Presentation blinding ended with a recorded reason.")
        }
    }

    func summarizeReview() {
        perform("Summarizing review quality control…") {
            let args: [String: WorkbenchJSON] = self.review.selectedSessionID.isEmpty
                ? [:] : ["sessionId": .string(self.review.selectedSessionID)]
            self.review.summary = try await self.call("review.summary", arguments: args)["result"]
            self.reportStatus("Review summary ready.")
        }
    }

    private func reviewSelection(imageIDs: Set<String>, allTimePoints: Bool) -> [String: WorkbenchJSON] {
        var args: [String: WorkbenchJSON] = [
            "imageIds": .array(imageIDs.sorted().map(WorkbenchJSON.string)),
            "target": .string(viewingVolume ? "volume" : "plane")
        ]
        if viewingVolume {
            args["channel"] = .number(Double(volume.channel))
            if !allTimePoints { args["timeIndices"] = .array([.number(Double(volume.timeIndex))]) }
        }
        return args
    }

    private func readReviewSessions() async throws {
        review.sessions = try await readCatalogue("reviewSessions")
        if review.selectedSessionID.isEmpty {
            review.selectedSessionID = review.sessions.first?["id"].string ?? ""
        }
    }

    private func readReviewSession(reloadPreview: Bool = true) async throws {
        guard !review.selectedSessionID.isEmpty else { return }
        let metadata = review.sessions.first { $0["id"].string == review.selectedSessionID }
        let reviewers = metadata?["reviewers"].array ?? []
        if !reviewers.contains(where: { $0["id"].string == review.reviewerID }) {
            review.reviewerID = reviewers.first?["id"].string ?? ""
        }
        var args: [String: WorkbenchJSON] = ["sessionId": .string(review.selectedSessionID)]
        if !review.reviewerID.isEmpty { args["reviewerId"] = .string(review.reviewerID) }
        review.session = try await call("review.session.get", arguments: args)["result"]["session"]
        if !review.items.contains(where: { $0["id"].string == review.selectedItemID }) {
            review.selectedItemID = review.items.first?["id"].string ?? ""
        }
        if reloadPreview && !review.selectedItemID.isEmpty { try await readReviewPreview() }
    }

    private func readReviewPreview(plane: String? = nil, index: Int? = nil) async throws {
        guard !review.selectedSessionID.isEmpty, !review.selectedItemID.isEmpty else { return }
        var args: [String: WorkbenchJSON] = [
            "sessionId": .string(review.selectedSessionID), "itemId": .string(review.selectedItemID),
            "maxSize": .number(2048)
        ]
        if let plane { args["plane"] = .string(plane) }
        if let index { args["index"] = .number(Double(index)) }
        review.clearPreview()
        let result = try await call("review.item.preview", arguments: args)["result"]
        review.preview = try decodePreview(result)
        review.overlay = try decodePreview(.object(["dataUrl": result["overlayDataUrl"]]))
        review.previewInfo = result
    }
}
