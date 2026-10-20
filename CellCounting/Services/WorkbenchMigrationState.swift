import Foundation
import Observation

@MainActor @Observable
final class WorkbenchMigrationState {
    var sourceDirectory = ""
    var selectedLegacyIDs: [String] = []
    var archivePath = ""
    var captureReceipt: WorkbenchJSON = .null
    var plan: WorkbenchJSON = .null
    var descriptor: WorkbenchJSON = .null
    var runningRemaining = false
    var requestedAction: String?
    var geometry: WorkbenchJSON = .null
    var selectedLegacyID = ""
    var variantID = ""
    var selectedEntity = ""
    var recordsPage: WorkbenchJSON = .null
    var evidencePage: WorkbenchJSON = .null
    var name = "Imported library"

    var hasPlan: Bool { plan["previewFingerprint"].string != nil }
    var hasMigration: Bool { descriptor["id"].string != nil }
    var status: String { descriptor["status"].string ?? "" }
    var mappings: [WorkbenchJSON] { descriptor["imageMappings"].array }
    var canAdvance: Bool { ["pending", "running"].contains(status) }
    func applyInspection(_ value: WorkbenchJSON) { descriptor = value["migration"] }
    func clearPreview() { plan = .null; captureReceipt = .null }
    func reset() {
        descriptor = .null; plan = .null; captureReceipt = .null; geometry = .null
        runningRemaining = false; requestedAction = nil; selectedLegacyID = ""; variantID = ""
        selectedEntity = ""; recordsPage = .null; evidencePage = .null
    }
}

extension WorkbenchSession {
    func captureLibraryArchive(to destination: URL) {
        guard canRefreshWithoutDiscardingEdits, !hasActiveWorkers else { return }
        var args: [String: WorkbenchJSON] = ["platform": .string("macos"),
            "sourceDirectory": .string(migration.sourceDirectory), "destination": .string(destination.path)]
        if !migration.selectedLegacyIDs.isEmpty { args["selectedImageIds"] = .array(migration.selectedLegacyIDs.map(WorkbenchJSON.string)) }
        migration.clearPreview()
        perform("Capturing a read-only library snapshot…", refreshOnConflict: false) {
            let result = try await self.migrationProjectless("migration.library.capture", arguments: args)["result"]
            guard let path = result["archivePath"].string else {
                throw WorkbenchFailure(code: "invalid-response", message: "Capture returned no archive path. Inspect the selected destination before capturing again.")
            }
            self.migration.archivePath = path; self.migration.captureReceipt = result
            self.migration.plan = try await self.migrationProjectless("migration.library.preview", arguments: ["path": .string(path)])["result"]["plan"]
            self.reportStatus("Library snapshot captured. Review the import plan before choosing a new project.")
        }
    }
    func previewLibraryArchive(at url: URL) {
        guard canRefreshWithoutDiscardingEdits, !hasActiveWorkers else { return }
        migration.archivePath = url.path; migration.clearPreview()
        perform("Previewing library migration…", refreshOnConflict: false) {
            self.migration.plan = try await self.migrationProjectless("migration.library.preview", arguments: ["path": .string(url.path)])["result"]["plan"]
            self.reportStatus("Migration preview ready. All-library evidence and selected scientific imports are listed separately.")
        }
    }
    func loadLibraryMigration() {
        guard hasProject else { return }
        perform("Loading migration progress…", refreshOnConflict: false) {
            self.migration.descriptor = try await self.call("migration.library.get")["result"]["migration"]
            self.reportStatus("Migration progress loaded.")
        }
    }
    func advanceLibraryMigration(remaining: Bool) {
        guard canRefreshWithoutDiscardingEdits, !hasActiveWorkers, migration.canAdvance else { return }
        migration.runningRemaining = remaining; migration.requestedAction = nil
        perform(remaining ? "Importing retained evidence and acquisitions…" : "Importing next migration checkpoint…", refreshOnConflict: false) {
            defer { self.migration.runningRemaining = false; self.migration.requestedAction = nil }
            repeat {
                let response = try await self.call("migration.library.advance", mutation: true)
                self.migration.descriptor = response["result"]["migration"]
                if let action = self.migration.requestedAction, self.migration.canAdvance {
                    self.migration.descriptor = try await self.call("migration.library." + action, mutation: true)["result"]["migration"]
                    break
                }
                if !remaining || !self.migration.canAdvance { break }
                let progress = self.migration.descriptor["progress"]
                self.reportStatus("Migration: \(progress["completed"].integer ?? 0) of \(progress["total"].integer ?? 0) checkpoints retained.")
                await Task.yield()
            } while true
            try await self.inspect()
            if !self.hasActiveWorkers { try await self.loadImage() }
            self.reportStatus(self.migration.status == "completed" ? "Library migration completed. Original data remains unchanged; historical geometry is retained separately." : "Migration \(self.migration.status). Completed checkpoints remain retained.")
        }
    }
    func controlLibraryMigration(_ action: String) {
        guard ["pause", "resume", "cancel"].contains(action), !hasActiveWorkers else { return }
        if migration.runningRemaining && busy {
            if action != "resume" { migration.requestedAction = action }
            return
        }
        guard canRefreshWithoutDiscardingEdits else { return }
        perform("Updating migration…", refreshOnConflict: false) {
            self.migration.descriptor = try await self.call("migration.library." + action, mutation: true)["result"]["migration"]
            try await self.inspect()
            self.reportStatus("Migration \(self.migration.status). Original files and completed checkpoints are preserved.")
        }
    }
    func loadMigrationRecords(entity: String, offset: Int = 0) {
        guard !entity.isEmpty else { return }
        perform("Reading retained library records…", refreshOnConflict: false) {
            self.migration.recordsPage = try await self.call("migration.records.get", arguments: [
                "entity": .string(entity), "offset": .number(Double(offset)), "limit": .number(25)])["result"]
            self.migration.selectedEntity = entity
            self.reportStatus("Read-only archived records loaded. Opaque data remains retained in the exact archive.")
        }
    }
    func loadMigrationEvidence(offset: Int = 0) {
        perform("Reading retained library evidence…", refreshOnConflict: false) {
            self.migration.evidencePage = try await self.call("migration.evidence.list", arguments: [
                "offset": .number(Double(offset)), "limit": .number(50)])["result"]
            self.reportStatus("Retained, pending and missing evidence loaded.")
        }
    }
    func loadLegacyGeometry(imageID: String, offset: Int = 0) {
        var args: [String: WorkbenchJSON] = ["imageId": .string(imageID), "offset": .number(Double(offset)), "limit": .number(100)]
        if !migration.variantID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { args["variantId"] = .string(migration.variantID) }
        perform("Reading historical library geometry…", refreshOnConflict: false) {
            self.migration.geometry = try await self.call("migration.geometry.get", arguments: args)["result"]
            self.migration.selectedLegacyID = imageID
            self.reportStatus("Historical centres and contours loaded. These are not editable instance masks.")
        }
    }
}
