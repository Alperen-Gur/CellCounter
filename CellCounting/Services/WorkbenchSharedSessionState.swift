import Foundation
import Observation

@MainActor @Observable
final class WorkbenchSharedSessionState {
    var record: WorkbenchJSON = .null
    var observedRevision: Int?
    var pendingRevision: Int?
    var lastEvents: [WorkbenchJSON] = []
    var notice = ""
    var visible = false
    var polling = false
    var presentWorkspace = false
    var id: String? { record["id"].string }
    var sessionRevision: Int { record["sessionRevision"].integer ?? 0 }
    var navigation: WorkbenchJSON { record["navigation"] }
    var hasPendingNavigation: Bool { ["pending", "deferred"].contains(navigation["status"].string ?? "") }
    func reset() {
        record = .null; observedRevision = nil; pendingRevision = nil; lastEvents = []
        notice = ""; presentWorkspace = false
    }
}

extension WorkbenchSession {
    var viewSessionSelection: WorkbenchJSON {
        var selection: [String: WorkbenchJSON] = ["task": .string(task.rawValue)]
        if let image = selectedImage {
            selection["imageId"] = .string(image.id)
            selection["target"] = .string(viewingVolume ? "volume" : "plane")
            selection["channel"] = .number(Double(viewingVolume ? volume.channel : channel))
            if viewingVolume {
                selection["timeIndex"] = .number(Double(volume.timeIndex))
                selection["plane"] = .string(volume.plane)
                selection["index"] = .number(Double(volume.index))
            }
        }
        if layeredWorkspace.editorOpen, !layeredWorkspace.selectedID.isEmpty {
            selection["workspaceId"] = .string(layeredWorkspace.selectedID)
        }
        return .object(selection)
    }

    /// The existing five-second refresh lifecycle owns both workers and agent
    /// changes. No session or component creates a second polling loop.
    func refreshProjectActivity() {
        guard hasProject, sharedSession.visible, !busy, !sharedSession.polling else { return }
        let mayRefresh = canRefreshWithoutDiscardingEdits
        sharedSession.polling = true
        performActivity {
            defer { self.sharedSession.polling = false }
            let cursor = self.sharedSession.observedRevision ?? self.revision ?? 0
            let changes = try await self.call("project.changes", arguments: ["afterRevision": .number(Double(cursor)), "limit": .number(100)])["result"]
            let current = changes["projectRevision"].integer ?? cursor
            self.sharedSession.lastEvents = changes["events"].array
            if current != cursor || changes["resetRequired"].bool == true {
                if mayRefresh {
                    let selectedAffected = changes["resetRequired"].bool == true || changes["hasMore"].bool == true ||
                        changes["events"].array.contains { event in
                            event["imageEffects"].array.contains { $0["imageId"].string == self.selectedImageID }
                        }
                    try await self.inspectFromChanges(preserveDisplayedImage: !selectedAffected)
                    self.sharedSession.pendingRevision = nil
                    if selectedAffected && !self.hasActiveWorkers { try await self.loadImage() }
                    if self.layeredWorkspace.editorOpen, !self.layeredWorkspace.selectedID.isEmpty,
                       changes["events"].array.contains(where: { $0["domains"].array.compactMap(\.string).contains("workspace") }) {
                        self.layeredWorkspace.load(try await self.call("workspace.get", arguments: ["workspaceId": .string(self.layeredWorkspace.selectedID)])["result"])
                    }
                    self.sharedSession.notice = "Project changes synchronized at revision \(self.revision ?? current)."
                } else {
                    self.sharedSession.pendingRevision = current
                    self.sharedSession.notice = "Project revision \(current) is available. Your current draft is preserved; finish or discard it before refreshing."
                }
            }
            // Activity is complete even when recent catalogues are partial or
            // an unsaved draft deliberately defers the scientific snapshot.
            let activity = try await self.call("project.activity")["result"]
            let activeWorkerIDs = Set(activity["activeJobWorkers"].array.compactMap { $0["workerId"].string })
            let finishedWorkers = self.jobWorkers.filter { $0.active && !activeWorkerIDs.contains($0.id) }
            for worker in finishedWorkers {
                if let updated = WorkbenchJobWorker(try await self.call("job.worker.status", arguments: ["workerId": .string(worker.id)])["result"]["worker"]),
                   let index = self.jobWorkers.firstIndex(where: { $0.id == worker.id }) { self.jobWorkers[index] = updated }
            }
            self.jobWorkersFromActivity(activity["activeJobWorkers"].array)
            let activeTrainingIDs = Set(activity["activeTrainingJobs"].array.compactMap { $0["id"].string })
            let finishedTraining = self.models.jobs.filter { ["queued", "starting", "running", "cancelling"].contains($0["status"].string ?? "") && !activeTrainingIDs.contains($0["id"].string ?? "") }
            for job in finishedTraining {
                if let id = job["id"].string { self.models.updateJob(try await self.call("adaptation.train.status", arguments: ["jobId": .string(id)])["result"]["job"]) }
            }
            self.models.applyActivity(activity["activeTrainingJobs"].array)
            guard self.sharedSession.visible else { return }
            if self.sharedSession.id == nil || self.sharedSession.record["closed"].bool == true {
                self.sharedSession.record = try await self.call("session.open", arguments: ["name": .string("CellCounter on macOS"), "clientKind": .string("native")])["result"]["session"]
            } else if let id = self.sharedSession.id {
                self.sharedSession.record = try await self.call("session.get", arguments: ["sessionId": .string(id)])["result"]["session"]
            }
            if self.sharedSession.hasPendingNavigation {
                let request = self.sharedSession.navigation
                let currentRevision = self.sharedSession.record["projectRevision"].integer ?? current
                if request["observedProjectRevision"].integer != currentRevision {
                    try await self.acknowledgeNavigation("refused", revision: currentRevision,
                        reason: "The project changed after this navigation request. Request navigation against the current revision.")
                } else if ((!mayRefresh || self.hasActiveWorkers) && !self.isTaskOnlyNavigation(request["selection"])) || !self.sharedSession.visible {
                    if request["status"].string != "deferred" {
                        try await self.acknowledgeNavigation("deferred", revision: currentRevision,
                            reason: "The native view has a draft, active background work, or is not visible. Its current selection is preserved.")
                    }
                    self.sharedSession.notice = "Agent navigation is deferred. Finish the current draft or background work, then Apply navigation or Refuse."
                } else if request["status"].string == "pending" {
                    try await self.applyRequestedNavigation()
                }
            } else if let revision = self.revision, self.sharedSession.pendingRevision == nil,
                      let id = self.sharedSession.id,
                      self.sharedSession.record["selection"] != self.viewSessionSelection || self.sharedSession.record["observedProjectRevision"].integer != self.revision {
                self.sharedSession.record = try await self.call("session.update", arguments: [
                    "sessionId": .string(id), "expectedSessionRevision": .number(Double(self.sharedSession.sessionRevision)),
                    "observedProjectRevision": .number(Double(revision)), "selection": self.viewSessionSelection])["result"]["session"]
            }
            if !self.sharedSession.notice.isEmpty { self.reportStatus(self.sharedSession.notice) }
        }
    }

    func resolveRequestedNavigation(apply: Bool) {
        guard !busy, sharedSession.hasPendingNavigation else { return }
        if apply && (!canRefreshWithoutDiscardingEdits || hasActiveWorkers) && !isTaskOnlyNavigation(sharedSession.navigation["selection"]) {
            sharedSession.notice = "Finish or discard the draft and pause background work before applying navigation."; return
        }
        perform(apply ? "Applying requested navigation…" : "Refusing requested navigation…", refreshOnConflict: false) {
            if apply { try await self.applyRequestedNavigation() }
            else {
                let latest = try await self.call("session.get", arguments: ["sessionId": .string(self.sharedSession.id ?? "")])["result"]["session"]
                self.sharedSession.record = latest
                try await self.acknowledgeNavigation("refused", revision: latest["projectRevision"].integer ?? self.revision ?? 0,
                    reason: "Navigation was refused in the native view.")
            }
        }
    }

    private func applyRequestedNavigation() async throws {
        guard let id = sharedSession.id else { return }
        sharedSession.record = try await call("session.get", arguments: ["sessionId": .string(id)])["result"]["session"]
        let current = sharedSession.record["projectRevision"].integer ?? revision ?? 0
        guard sharedSession.visible else {
            try await acknowledgeNavigation("deferred", revision: current,
                reason: "The Workbench is no longer visible. Return to it before applying navigation.")
            return
        }
        guard sharedSession.navigation["observedProjectRevision"].integer == current,
              isTaskOnlyNavigation(sharedSession.navigation["selection"]) || revision == current else {
            try await acknowledgeNavigation("refused", revision: current, reason: "The native view or navigation request has an older project revision. Refresh and issue a current request.")
            return
        }
        let selection = sharedSession.navigation["selection"]
        let previousTask = task
        do {
            try await loadNavigationSelection(selection)
            try await acknowledgeNavigation("applied", revision: current, reason: "Applied in the visible native Workbench after preserving all drafts.")
            sharedSession.notice = "Requested navigation applied. Your analysis and edit drafts are preserved."
        } catch {
            if let requestedTask = selection["task"].string.flatMap(WorkbenchTask.init(rawValue:)), task == requestedTask {
                task = previousTask
            }
            try? await acknowledgeNavigation("refused", revision: current, reason: String("The native view could not display this selection: \(error.localizedDescription)".prefix(1000)))
            throw error
        }
    }

    private func acknowledgeNavigation(_ outcome: String, revision: Int, reason: String) async throws {
        guard let id = sharedSession.id, let navigationID = sharedSession.navigation["id"].string else { return }
        sharedSession.record = try await call("session.navigation.ack", arguments: [
            "sessionId": .string(id), "expectedSessionRevision": .number(Double(sharedSession.sessionRevision)),
            "navigationId": .string(navigationID), "observedProjectRevision": .number(Double(revision)),
            "outcome": .string(outcome), "reason": .string(reason)])["result"]["session"]
    }

    func closeViewSession() async {
        guard let id = sharedSession.id else { return }
        do {
            let latest = try await call("session.get", arguments: ["sessionId": .string(id)])["result"]["session"]
            if latest["closed"].bool != true {
                _ = try await call("session.close", arguments: ["sessionId": .string(id), "expectedSessionRevision": latest["sessionRevision"]])
            }
        } catch { /* Closing metadata must not discard a draft or block project navigation. */ }
        sharedSession.record = .null
    }
}
