import AppKit
import Foundation
import Observation

/// Host-local configuration only. Portable projects never choose an interpreter,
/// server credential, or registry. CLI callers may explicitly override this path.
@MainActor enum WorkbenchOmeroConfiguration {
    static let preferenceKey = "cc-workbench-omero-registry"
    static var registryURL: URL {
        if let path = UserDefaults.standard.string(forKey: preferenceKey), path.hasPrefix("/") {
            return URL(fileURLWithPath: path)
        }
        return FileStore.location().appendingPathComponent("omero-profiles.json")
    }
}

nonisolated struct WorkbenchOmeroLocation: Identifiable, Equatable, Sendable {
    let kind: String
    let parentID: Int?
    let parentKind: String?
    let name: String
    var id: String { "\(kind):\(parentID.map(String.init) ?? "root")" }
}

@MainActor @Observable
final class WorkbenchOmeroState {
    var runtime: WorkbenchJSON = .null
    var probe: WorkbenchJSON = .null
    var candidate: WorkbenchJSON = .null
    var interpreterPath = ""
    var profiles: [WorkbenchJSON] = []
    var selectedProfileID = ""
    var profileID = ""
    var profileName = ""
    var host = ""
    var port = 4064
    var username = ""
    var credentialKind = "local-file"
    var credentialReference = ""
    var caPath = ""
    var savedProfileDraft: WorkbenchJSON = .null
    var connection: WorkbenchJSON = .null
    var groups: [WorkbenchJSON] = []
    var groupOffset = 0
    var nextGroupOffset: Int?
    var groupID = -1
    var locations: [WorkbenchOmeroLocation] = []
    var objects: [WorkbenchJSON] = []
    var objectOffset = 0
    var nextObjectOffset: Int?
    var image: WorkbenchJSON = .null
    var inspectedProfileID = ""
    var inspectedGroupID = -1
    var timeIndex = 0
    var channel = 0
    var zIndex = 0
    var x = 0
    var y = 0
    var width = 512
    var height = 512
    var importName = ""
    var preview: NSImage?
    var previewResult: WorkbenchJSON = .null
    var previewArguments: WorkbenchJSON = .null
    var previewConfigurationHash = ""
    var lastImportedImageID: String?
    var editorOpen = false
    var configurationHash: String { runtime["configurationHash"].string ?? "missing" }
    var imageID: Int? { image["id"].integer }
    var dimensions: WorkbenchJSON { image["dimensions"] }
    var selectedProfile: WorkbenchJSON { profiles.first { $0["id"].string == selectedProfileID } ?? .null }
    var location: WorkbenchOmeroLocation? { locations.last }
    var candidateCurrent: Bool { candidate["pythonPath"].string == interpreterPath && candidate["pythonSha256"].string != nil }
    var interpreterDirty: Bool { !interpreterPath.isEmpty && interpreterPath != runtime["pythonPath"].string }
    var profileArguments: WorkbenchJSON {
        var args: [String: WorkbenchJSON] = ["profileId": .string(profileID), "name": .string(profileName),
            "host": .string(host), "port": .number(Double(port)), "username": .string(username)]
        args[credentialKind == "environment" ? "passwordEnv" : "credentialFile"] = .string(credentialReference)
        if !caPath.isEmpty { args["caFile"] = .string(caPath) }
        return .object(args)
    }
    var configurationDirty: Bool {
        interpreterDirty || (!profileID.isEmpty && profileArguments != savedProfileDraft)
    }
    var validProfile: Bool {
        !profileID.isEmpty && !profileName.isEmpty && !host.isEmpty && !username.isEmpty &&
        !credentialReference.isEmpty && port > 0 && port < 65536
    }
    var selectionArguments: WorkbenchJSON {
        guard let imageID else { return .null }
        return .object(["profileId": .string(selectedProfileID), "groupId": .number(Double(groupID)),
            "imageId": .number(Double(imageID)), "timeIndex": .number(Double(timeIndex)),
            "channel": .number(Double(channel)), "zIndex": .number(Double(zIndex)),
            "x": .number(Double(x)), "y": .number(Double(y)),
            "width": .number(Double(width)), "height": .number(Double(height))])
    }
    var validRegion: Bool {
        guard imageID != nil, inspectedProfileID == selectedProfileID, inspectedGroupID == groupID,
              let sourceWidth = dimensions["x"].integer, let sourceHeight = dimensions["y"].integer else { return false }
        return x >= 0 && y >= 0 && width > 0 && height > 0 && x <= sourceWidth && y <= sourceHeight &&
            width <= sourceWidth - x && height <= sourceHeight - y &&
            Double(width) * Double(height) <= 16_000_000 &&
            timeIndex >= 0 && timeIndex < (dimensions["t"].integer ?? 0) &&
            channel >= 0 && channel < (dimensions["c"].integer ?? 0) &&
            zIndex >= 0 && zIndex < (dimensions["z"].integer ?? 0)
    }
    var previewCurrent: Bool {
        validRegion && preview != nil && previewResult["previewFingerprint"].string != nil &&
            previewArguments == selectionArguments && previewConfigurationHash == configurationHash
    }
    func clearPreview() { preview = nil; previewResult = .null; previewArguments = .null; previewConfigurationHash = "" }
    func clearImage() { image = .null; inspectedProfileID = ""; inspectedGroupID = -1; clearPreview() }
    func clearBrowse() {
        connection = .null; groups = []; groupOffset = 0; nextGroupOffset = nil; groupID = -1
        locations = []; objects = []; objectOffset = 0; nextObjectOffset = nil; clearImage()
    }
    func applyRuntime(_ result: WorkbenchJSON, preserveDraft: Bool = true) {
        let wasInterpreterDirty = interpreterDirty
        let previousHash = configurationHash
        runtime = result; profiles = result["profiles"].array
        if !preserveDraft || !wasInterpreterDirty { interpreterPath = result["pythonPath"].string ?? "" }
        if !profiles.contains(where: { $0["id"].string == selectedProfileID }) {
            selectedProfileID = profiles.first?["id"].string ?? ""; clearBrowse()
        }
        if previousHash != configurationHash { probe = .null; clearPreview() }
    }
    func loadProfileDraft(_ profile: WorkbenchJSON) {
        profileID = profile["id"].string ?? ""; profileName = profile["name"].string ?? ""
        host = profile["host"].string ?? ""; port = profile["port"].integer ?? 4064
        username = profile["username"].string ?? ""; credentialKind = profile["credentialKind"].string ?? "local-file"
        // Public descriptors deliberately omit credential/CA references. Editing
        // an existing profile requires supplying the intended references again.
        credentialReference = ""; caPath = ""; savedProfileDraft = profileArguments
    }
    func resetProjectContext() { lastImportedImageID = nil; clearPreview() }
}

extension WorkbenchSession {
    func loadOmeroConfiguration() {
        perform("Reading local OMERO configuration…", refreshOnConflict: false) {
            let result = try await self.omeroProjectless("omero.runtime.inspect")["result"]
            self.omero.applyRuntime(result)
            self.reportStatus("OMERO configuration loaded. Connect explicitly to browse a server.")
        }
    }

    func chooseOmeroRegistry(_ url: URL) {
        guard !busy else { return }
        UserDefaults.standard.set(url.path, forKey: WorkbenchOmeroConfiguration.preferenceKey)
        omero.runtime = .null; omero.probe = .null; omero.candidate = .null; omero.clearBrowse()
        loadOmeroConfiguration()
    }

    func inspectOmeroInterpreter() {
        let path = omero.interpreterPath
        perform("Reading isolated interpreter identity…", refreshOnConflict: false) {
            self.omero.candidate = try await self.omeroProjectless("omero.runtime.candidate", arguments: ["pythonPath": .string(path)])["result"]
            self.reportStatus("Interpreter bytes identified. This action did not execute it.")
        }
    }

    func bindOmeroInterpreter() {
        guard omero.candidateCurrent else { return }
        let args: [String: WorkbenchJSON] = ["pythonPath": .string(omero.interpreterPath),
            "pythonSha256": omero.candidate["pythonSha256"], "expectedConfigurationHash": .string(omero.configurationHash)]
        perform("Binding isolated OMERO interpreter…", refreshOnConflict: false) {
            let result = try await self.omeroProjectless("omero.runtime.configure", arguments: args)["result"]
            self.omero.applyRuntime(result, preserveDraft: false); self.omero.candidate = .null
            self.reportStatus("Interpreter bound. Probe compatibility before connecting.")
        }
    }

    func probeOmeroRuntime() {
        perform("Probing isolated OMERO runtime…", refreshOnConflict: false) {
            self.omero.probe = try await self.omeroProjectless("omero.runtime.probe")["result"]
            self.reportStatus("OMERO runtime probe completed without a server connection.")
        }
    }

    func saveOmeroProfile() {
        guard omero.validProfile else { return }
        let draft = omero.profileArguments
        var args = draft.object; args["expectedConfigurationHash"] = .string(omero.configurationHash)
        perform("Saving local OMERO profile…", refreshOnConflict: false) {
            let result = try await self.omeroProjectless("omero.profile.save", arguments: args)["result"]
            self.omero.applyRuntime(result); self.omero.savedProfileDraft = draft
            self.omero.selectedProfileID = draft["profileId"].string ?? ""; self.omero.clearBrowse()
            self.reportStatus("Named profile saved on this Mac. Credentials are excluded from projects.")
        }
    }

    func selectOmeroProfile(_ id: String) {
        guard !busy else { return }
        omero.selectedProfileID = id; omero.clearBrowse()
    }

    func loadOmeroGroups(offset: Int = 0) {
        guard !omero.selectedProfileID.isEmpty else { return }
        let profileID = omero.selectedProfileID
        perform("Connecting and listing OMERO groups…", refreshOnConflict: false) {
            let result = try await self.omeroProjectless("omero.group.list", arguments: [
                "profileId": .string(profileID), "offset": .number(Double(offset)), "limit": .number(50)])["result"]
            guard self.omero.selectedProfileID == profileID else { return }
            self.omero.connection = result["connection"]; self.omero.groups = result["groups"].array
            self.omero.groupOffset = offset; self.omero.nextGroupOffset = result["nextOffset"].integer
            self.reportStatus("OMERO groups loaded. Choose a group and hierarchy.")
        }
    }

    func browseOmero(kind: String, parentID: Int? = nil, parentKind: String? = nil, name: String,
                     offset: Int = 0, backTo: Int? = nil) {
        guard !omero.selectedProfileID.isEmpty, omero.groupID >= 0 else { return }
        let profile = omero.selectedProfileID, group = omero.groupID
        let location = WorkbenchOmeroLocation(kind: kind, parentID: parentID, parentKind: parentKind, name: name)
        var args: [String: WorkbenchJSON] = ["profileId": .string(profile), "groupId": .number(Double(group)),
            "kind": .string(kind), "offset": .number(Double(offset)), "limit": .number(50)]
        if let parentID { args["parentId"] = .number(Double(parentID)) }
        if let parentKind { args["parentKind"] = .string(parentKind) }
        perform("Browsing OMERO \(name)…", refreshOnConflict: false) {
            let result = try await self.omeroProjectless("omero.object.list", arguments: args)["result"]
            guard self.omero.selectedProfileID == profile, self.omero.groupID == group else { return }
            if let backTo { self.omero.locations = Array(self.omero.locations.prefix(backTo + 1)) }
            else if self.omero.location != location {
                if parentID == nil { self.omero.locations = [] }
                self.omero.locations.append(location)
            }
            self.omero.objects = result["objects"].array; self.omero.objectOffset = offset
            self.omero.nextObjectOffset = result["nextOffset"].integer
            self.omero.connection = result["connection"]; self.omero.clearImage()
            self.reportStatus("OMERO hierarchy page loaded.")
        }
    }

    func openOmeroObject(_ object: WorkbenchJSON) {
        guard let id = object["id"].integer, let kind = object["kind"].string else { return }
        if kind == "image" { inspectOmeroImage(id); return }
        let child = ["project": "dataset", "dataset": "image", "screen": "plate", "plate": "well", "well": "image"][kind]
        guard let child else { return }
        browseOmero(kind: child, parentID: id, parentKind: kind, name: object["name"].string ?? kind.capitalized)
    }

    func inspectOmeroImage(_ id: Int) {
        let profile = omero.selectedProfileID, group = omero.groupID
        guard !profile.isEmpty, group >= 0 else { return }
        perform("Reading OMERO image dimensions…", refreshOnConflict: false) {
            let result = try await self.omeroProjectless("omero.image.inspect", arguments: [
                "profileId": .string(profile), "groupId": .number(Double(group)), "imageId": .number(Double(id))])["result"]
            guard self.omero.selectedProfileID == profile, self.omero.groupID == group else { return }
            self.omero.image = result["image"]; self.omero.connection = result["connection"]
            self.omero.inspectedProfileID = profile; self.omero.inspectedGroupID = group
            self.omero.timeIndex = 0; self.omero.channel = 0; self.omero.zIndex = 0
            self.omero.x = 0; self.omero.y = 0
            self.omero.width = min(512, result["image"]["dimensions"]["x"].integer ?? 512)
            self.omero.height = min(512, result["image"]["dimensions"]["y"].integer ?? 512)
            self.omero.importName = result["image"]["name"].string ?? "OMERO region"
            self.omero.clearPreview(); self.reportStatus("Image metadata loaded. Select an exact raw region to preview.")
        }
    }

    func previewOmeroRegion() {
        guard omero.validRegion else { return }
        let selection = omero.selectionArguments, configurationHash = omero.configurationHash
        var args = selection.object; args["maxSize"] = .number(1024)
        perform("Previewing exact raw OMERO region…", refreshOnConflict: false) {
            let result = try await self.omeroProjectless("omero.import.preview", arguments: args)["result"]
            guard self.omero.selectionArguments == selection, self.omero.configurationHash == configurationHash else { return }
            self.omero.preview = try self.decodePreview(result); self.omero.previewResult = result
            self.omero.previewArguments = selection; self.omero.previewConfigurationHash = configurationHash
            self.reportStatus("Raw region previewed. Import rechecks the selected source bytes.")
        }
    }

    func importOmeroRegion() {
        guard hasProject, omero.previewCurrent, !hasActiveWorkers, canRefreshWithoutDiscardingEdits else { return }
        var args = omero.selectionArguments.object; args["previewFingerprint"] = omero.previewResult["previewFingerprint"]
        let name = omero.importName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty { args["name"] = .string(name) }
        perform("Importing verified raw OMERO region…") {
            let result = try await self.call("omero.import.run", arguments: args, mutation: true)["result"]
            try await self.inspect(); self.selectedImageID = result["imageId"].string
            self.viewingVolume = false; self.invalidateSummaries(); try await self.loadImage()
            self.omero.lastImportedImageID = result["imageId"].string
            self.reportStatus("Exact raw region imported with server, T/C/Z, XY origin and calibration provenance.")
        }
    }
}
