import Foundation
import Observation

@MainActor @Observable
final class WorkbenchLibraryState {
    var editorOpen = false
    var collections: [WorkbenchJSON] = []
    var selectedIDs: Set<String> = []
    var metadata: WorkbenchJSON = .null
    var name = ""
    var notes = ""
    var tags = ""
    var channelNames: [String] = []
    var originalDraft: WorkbenchJSON?
    var collectionID = ""
    var collectionName = ""
    var collectionDescription = ""
    var collectionMembers: Set<String> = []
    var originalCollection: WorkbenchJSON?
    var duplicateGroups: [WorkbenchJSON] = []
    var repairPath = ""
    var repairPreview: WorkbenchJSON?
    var repairRevision: Int?
    var draft: WorkbenchJSON { .object(["name": .string(name), "notes": .string(notes), "tags": .string(tags), "channelNames": .array(channelNames.map(WorkbenchJSON.string))]) }
    var collectionDraft: WorkbenchJSON { .object(["name": .string(collectionName), "description": .string(collectionDescription), "imageIds": .array(collectionMembers.sorted().map(WorkbenchJSON.string))]) }
    var dirty: Bool { originalDraft != nil && originalDraft != draft || originalCollection != nil && originalCollection != collectionDraft }
    func applyMetadata(_ value: WorkbenchJSON) {
        metadata = value; name = value["name"].string ?? ""; notes = value["notes"].string ?? ""
        tags = value["tags"].array.compactMap(\.string).joined(separator: ", ")
        channelNames = value["channelNames"].array.compactMap(\.string)
        originalDraft = draft; repairPreview = nil; repairPath = ""
    }
    func editCollection(_ value: WorkbenchJSON) {
        collectionID = value["id"].string ?? ""; collectionName = value["name"].string ?? ""
        collectionDescription = value["description"].string ?? ""
        collectionMembers = Set(value["imageIds"].array.compactMap(\.string)); originalCollection = collectionDraft
    }
    func reset() {
        collections = []; selectedIDs = []; metadata = .null; originalDraft = nil
        name = ""; notes = ""; tags = ""; channelNames = []; editCollection(.null)
        duplicateGroups = []; repairPath = ""; repairPreview = nil; repairRevision = nil
    }
}

extension WorkbenchSession {
    func searchLibrary() {
        perform("Loading project collections…", refreshOnConflict: false) {
            self.library.collections = try await self.readCatalogue("collections")
            self.reportStatus("Library metadata loaded. Search acquisitions in the paged browser; selections persist across pages.")
        }
    }
    func editLibraryImage(_ imageID: String) {
        guard !library.dirty else { error = "Save or discard the pending library metadata before editing another image."; return }
        perform("Loading acquisition metadata…", refreshOnConflict: false) {
            self.library.applyMetadata(try await self.call("image.metadata.get", arguments: ["imageId": .string(imageID)])["result"]["image"])
        }
    }
    func saveLibraryMetadata() {
        guard let id = library.metadata["id"].string, !hasActiveWorkers else { return }
        let args: [String: WorkbenchJSON] = ["imageId": .string(id), "name": .string(library.name), "notes": .string(library.notes),
            "tags": .array(libraryTags(library.tags).map(WorkbenchJSON.string)), "channelNames": .array(library.channelNames.map(WorkbenchJSON.string))]
        perform("Saving acquisition metadata…", refreshOnConflict: false) {
            self.library.applyMetadata(try await self.call("image.metadata.set", arguments: args, mutation: true)["result"]["image"])
            try await self.inspectFromChanges(preserveDisplayedImage: true)
            self.reportStatus("Metadata saved. Scientific masks, measurements and assignments are preserved.")
        }
    }
    func archiveLibrarySelection(_ archived: Bool) {
        guard !library.selectedIDs.isEmpty, !library.dirty, !hasActiveWorkers else { return }
        perform(archived ? "Archiving acquisitions…" : "Restoring acquisitions…", refreshOnConflict: false) {
            _ = try await self.call("image.archive", arguments: ["imageIds": .array(self.library.selectedIDs.sorted().map(WorkbenchJSON.string)), "archived": .bool(archived)], mutation: true)
            try await self.inspectFromChanges(preserveDisplayedImage: true)
            self.library.selectedIDs = []
            self.reportStatus("Library visibility updated; source data, measurements and history remain retained.")
        }
    }
    func saveLibraryCollection(asNew: Bool) {
        guard !hasActiveWorkers else { return }
        var args = library.collectionDraft.object
        if !asNew && !library.collectionID.isEmpty { args["collectionId"] = .string(library.collectionID) }
        perform("Saving image collection…", refreshOnConflict: false) {
            self.library.editCollection(try await self.call("collection.save", arguments: args, mutation: true)["result"]["collection"])
            self.library.collections = try await self.readCatalogue("collections")
            try await self.inspectFromChanges(preserveDisplayedImage: true)
            self.reportStatus("Collection saved. Membership is separate from biological specimen assignments.")
        }
    }
    func archiveLibraryCollection(_ archived: Bool) {
        guard !library.collectionID.isEmpty, !library.dirty, !hasActiveWorkers else { return }
        perform("Updating collection visibility…", refreshOnConflict: false) {
            _ = try await self.call("collection.archive", arguments: ["collectionId": .string(self.library.collectionID), "archived": .bool(archived)], mutation: true)
            self.library.collections = try await self.readCatalogue("collections")
            try await self.inspectFromChanges(preserveDisplayedImage: true)
        }
    }
    func findLibraryDuplicates() {
        perform("Finding exact source duplicates…", refreshOnConflict: false) {
            self.library.duplicateGroups = try await self.call("library.duplicates", arguments: ["includeArchived": .bool(true)])["result"]["groups"].array
            self.reportStatus("Exact duplicate source bytes identified. No images were merged.")
        }
    }
    func previewLibraryRepair(_ path: String) {
        guard let id = library.metadata["id"].string else { return }
        library.repairPath = path; library.repairPreview = nil
        perform("Comparing source identity…", refreshOnConflict: false) {
            self.library.repairPreview = try await self.call("image.relink.preview", arguments: ["imageId": .string(id), "path": .string(path)])["result"]["preview"]
            self.library.repairRevision = self.revision
        }
    }
    func applyLibraryRepair() {
        guard let id = library.metadata["id"].string, let preview = library.repairPreview,
              preview["identityMatches"].bool == true, let fingerprint = preview["previewFingerprint"].string,
              library.repairRevision == revision, !library.dirty, !hasActiveWorkers else { return }
        perform("Restoring exact original source bytes…", refreshOnConflict: false) {
            _ = try await self.call("image.relink.run", arguments: ["imageId": .string(id), "path": .string(self.library.repairPath), "previewFingerprint": .string(fingerprint)], mutation: true)
            self.library.repairPreview = nil
            try await self.inspectFromChanges(preserveDisplayedImage: true)
            self.reportStatus("Original source identity restored; displaced evidence and scientific history are preserved.")
        }
    }
    private func libraryTags(_ value: String) -> [String] {
        Array(Set(value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })).sorted()
    }
}
