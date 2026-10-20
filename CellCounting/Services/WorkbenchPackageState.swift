import Foundation
import Observation

@MainActor @Observable
final class WorkbenchPackageState {
    var destination = ""
    var restore: WorkbenchJSON = .null
    var runningRemaining = false
    var requestedAction: String?
    var upgradePreview: WorkbenchJSON?
    var upgradeRevision: Int?
    var history: [WorkbenchJSON] = []
    var historyTotal = 0
    var historyCursor: String?
    var historyCursors: [String?] = [nil]
    var historyPage = 0
    var historyRevision: Int?
    var status: String { restore["status"].string ?? "" }
    var canAdvance: Bool { ["pending", "running"].contains(status) }
    func resetProject() { upgradePreview = nil; upgradeRevision = nil; history = []; historyCursor = nil; historyCursors = [nil]; historyPage = 0; historyRevision = nil }
}

extension WorkbenchSession {
    func reopenPackageRestore(at path: String) {
        guard canRefreshWithoutDiscardingEdits, !hasActiveWorkers else { return }
        perform("Reading retained restore progress…", refreshOnConflict: false) {
            let result = try await self.restoreRequest("package.restore.get", path: path)["result"]
            self.packages.destination = path; self.packages.restore = result["restore"]
            self.rememberRestoreDestination(path)
            self.reportStatus("Restore \(self.packages.status). Completed bytes remain retained; use explicit controls to continue.")
        }
    }

    func advancePackageRestore(remaining: Bool) {
        guard canRefreshWithoutDiscardingEdits, !hasActiveWorkers, packages.canAdvance else { return }
        packages.runningRemaining = remaining; packages.requestedAction = nil
        perform(remaining ? "Restoring verified artifact shards…" : "Restoring next artifact shard…", refreshOnConflict: false) {
            defer { self.packages.runningRemaining = false; self.packages.requestedAction = nil }
            repeat {
                let args = ["expectedRestoreRevision": self.packages.restore["restoreRevision"]]
                let result = try await self.restoreRequest("package.restore.advance", path: self.packages.destination, arguments: args)["result"]
                self.packages.restore = result["restore"]
                let progress = self.packages.restore["progress"]
                self.reportStatus("Restore: \(progress["completed"].integer ?? 0) / \(progress["total"].integer ?? 0) checkpoints verified.")
                if self.packages.requestedAction == "cancel", self.packages.canAdvance {
                    self.packages.restore = try await self.restoreRequest("package.restore.cancel", path: self.packages.destination,
                        arguments: ["expectedRestoreRevision": self.packages.restore["restoreRevision"]])["result"]["restore"]
                    break
                }
                if !remaining || !self.packages.canAdvance || self.packages.requestedAction == "stop" { break }
                await Task.yield()
            } while true
            if self.packages.status == "completed" { try await self.adoptRestoredProject(path: self.packages.destination) }
            else { self.reportStatus("Restore stopped at a verified checkpoint. Continue or cancel explicitly; retained source evidence is preserved.") }
        }
    }

    func controlPackageRestore(_ action: String) {
        guard ["stop", "cancel", "resume"].contains(action) else { return }
        if busy && packages.runningRemaining {
            if action != "resume" { packages.requestedAction = action }
            return
        }
        guard !busy, !hasActiveWorkers, canRefreshWithoutDiscardingEdits, action != "stop" else { return }
        perform("Updating retained package restore…", refreshOnConflict: false) {
            self.packages.restore = try await self.restoreRequest("package.restore." + action, path: self.packages.destination,
                arguments: ["expectedRestoreRevision": self.packages.restore["restoreRevision"]])["result"]["restore"]
            self.reportStatus("Restore \(self.packages.status). No source data was deleted.")
        }
    }

    func openCompletedPackageRestore() {
        guard packages.status == "completed", canRefreshWithoutDiscardingEdits, !hasActiveWorkers else { return }
        perform("Opening restored project…", refreshOnConflict: false) {
            try await self.adoptRestoredProject(path: self.packages.destination)
        }
    }

    func previewStorageUpgrade() {
        guard hasProject, canRefreshWithoutDiscardingEdits, !hasActiveWorkers else { return }
        perform("Previewing indexed storage migration…", refreshOnConflict: false) {
            self.packages.upgradePreview = try await self.call("project.storage.upgrade.preview")["result"]
            self.packages.upgradeRevision = self.revision
        }
    }

    func applyStorageUpgrade() {
        guard let preview = packages.upgradePreview, packages.upgradeRevision == revision,
              let fingerprint = preview["previewFingerprint"].string, canRefreshWithoutDiscardingEdits, !hasActiveWorkers else { return }
        perform("Preserving the original store and migrating its index…", refreshOnConflict: false) {
            let result = try await self.call("project.storage.upgrade.run", arguments: ["previewFingerprint": .string(fingerprint)], mutation: true)["result"]
            self.packages.upgradePreview = nil
            try await self.inspectFromChanges(preserveDisplayedImage: true)
            self.reportStatus("Indexed storage enabled. Original database recovery copy: \(result["recoveryPath"].string ?? "retained in the project recovery directory"). Scientific measurements were not recalculated.")
        }
    }

    func loadProjectHistory(direction: Int = 0) {
        perform("Reading project history page…", refreshOnConflict: false) {
            if direction == 0 || self.packages.historyRevision != self.revision {
                self.packages.historyCursors = [nil]; self.packages.historyPage = 0
            }
            var target = direction == 0 ? 0 : max(0, self.packages.historyPage + direction)
            if direction > 0, let next = self.packages.historyCursor {
                if self.packages.historyCursors.count > target { self.packages.historyCursors[target] = next }
                else { self.packages.historyCursors.append(next) }
            }
            target = min(target, self.packages.historyCursors.count - 1)
            var args: [String: WorkbenchJSON] = ["limit": .number(100)]
            if let cursor = self.packages.historyCursors[target] { args["cursor"] = .string(cursor) }
            do {
                let result = try await self.call("project.history", arguments: args)["result"]
                self.packages.history = result["history"].array
                self.packages.historyTotal = result["total"].integer ?? 0
                self.packages.historyCursor = result["nextCursor"].string
                self.packages.historyPage = target; self.packages.historyRevision = result["sourceRevision"].integer
            } catch {
                self.packages.historyCursor = nil; self.packages.historyCursors = [nil]; self.packages.historyRevision = nil
                throw error
            }
        }
    }
}
