import Foundation
import Observation

nonisolated struct WorkbenchDisplayPreset: Identifiable {
    let value: WorkbenchJSON
    let id: String
    let name: String
    let version: Int
    var latestVersion: Int { value["latestVersion"].integer ?? version }
    var versionCount: Int { value["versionCount"].integer ?? latestVersion }
    var archived: Bool { value["archived"].bool == true }
    var notes: String { value["notes"].string ?? "" }
    var channels: [WorkbenchJSON] { value["channels"].array }
    var intensityUnits: String { value["intensityUnits"].string ?? "" }
    init?(_ value: WorkbenchJSON) {
        guard let id = value["id"].string, let version = value["version"].integer,
              let name = value["name"].string else { return nil }
        self.value = value; self.id = id; self.version = version; self.name = name
    }
}

@MainActor @Observable
final class WorkbenchDisplayPresetState {
    var records: [WorkbenchDisplayPreset] = []
    var selectedID = ""
    var selected: WorkbenchDisplayPreset?
    var includeArchived = false
    var name = ""
    var notes = ""
    var mapping: [Int: Int] = [:]
    var message = ""
    var warnings: [String] = []
    var loaded = false
    var importPreview: WorkbenchJSON?
    var importPath = ""
    var importName = ""
    var importRevision: Int?
    var exportResult: WorkbenchJSON?

    var visibleRecords: [WorkbenchDisplayPreset] {
        records.filter { includeArchived || !$0.archived || $0.id == selectedID }
    }
    var latest: WorkbenchDisplayPreset? { records.first { $0.id == selectedID } }
    var isArchived: Bool { latest?.archived ?? selected?.archived ?? false }
    var mappingJSON: WorkbenchJSON {
        .array((selected?.channels ?? []).compactMap { channel in
            guard let source = channel["channel"].integer, let target = mapping[source] else { return nil }
            return .object(["source": .number(Double(source)), "target": .number(Double(target))])
        })
    }
    func mappingValid(channelCount: Int) -> Bool {
        let sources = selected?.channels.compactMap { $0["channel"].integer } ?? []
        let targets = sources.compactMap { mapping[$0] }
        return !sources.isEmpty && targets.count == sources.count &&
            targets.allSatisfy { $0 >= 0 && $0 < channelCount } && Set(targets).count == targets.count
    }
    func resetMapping(channelCount: Int) {
        mapping = Dictionary(uniqueKeysWithValues: (selected?.channels ?? []).compactMap {
            guard let channel = $0["channel"].integer else { return nil }
            return (channel, channel < channelCount ? channel : -1)
        })
        message = ""; warnings = []
    }
    func updateList(_ values: [WorkbenchJSON]) {
        records = values.compactMap(WorkbenchDisplayPreset.init)
        loaded = true
    }
    func select(_ preset: WorkbenchDisplayPreset, channelCount: Int) {
        selectedID = preset.id; selected = preset
        name = preset.name; notes = preset.notes
        resetMapping(channelCount: channelCount)
    }
    func upsert(_ preset: WorkbenchDisplayPreset) {
        records.removeAll { $0.id == preset.id }
        records.append(preset)
        records.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    func reset() {
        records = []; selectedID = ""; selected = nil; includeArchived = false
        name = ""; notes = ""; mapping = [:]; message = ""; warnings = []; loaded = false
        importPreview = nil; importPath = ""; importName = ""; importRevision = nil; exportResult = nil
    }
}

extension WorkbenchSession {
    func reloadDisplayPresets() {
        perform("Loading display presets…", refreshOnConflict: false) {
            _ = try await self.readCatalogue("displayPresets")
            self.reportStatus("Display presets loaded.")
        }
    }

    func selectDisplayPreset(_ id: String, version: Int? = nil) {
        guard !busy else { return }
        let state = composite.presets
        if id.isEmpty { state.selectedID = ""; state.selected = nil; state.mapping = [:]; return }
        var arguments: [String: WorkbenchJSON] = ["presetId": .string(id)]
        if let version { arguments["version"] = .number(Double(version)) }
        perform("Loading display preset…", refreshOnConflict: false) {
            let result = try await self.call("display.preset.get", arguments: arguments)["result"]["preset"]
            guard let preset = WorkbenchDisplayPreset(result) else {
                throw WorkbenchFailure(code: "invalid-response", message: "The display preset could not be read. Refresh the preset list and try again.")
            }
            state.select(preset, channelCount: self.selectedImage?.channels ?? 1)
            self.reportStatus("Preset version \(preset.version) loaded. Choose Apply settings to update the display draft.")
        }
    }

    func applyDisplayPreset() {
        let state = composite.presets
        guard let image = selectedImage, let preset = state.selected,
              state.mappingValid(channelCount: image.channels) else { return }
        let arguments: [String: WorkbenchJSON] = [
            "presetId": .string(preset.id), "version": .number(Double(preset.version)),
            "imageId": .string(image.id), "channelMapping": state.mappingJSON
        ]
        perform("Applying display preset settings…", refreshOnConflict: false) {
            let result = try await self.call("display.preset.resolve", arguments: arguments)["result"]
            let settings = result["settings"]
            let channels = settings["channels"].array.compactMap(WorkbenchCompositeChannel.init)
            guard self.selectedImageID == image.id, self.selectedImage?.sourceHash == image.sourceHash else {
                throw WorkbenchFailure(code: "selection-changed", message: "The selected image changed. Apply the preset again to the current image.")
            }
            guard result["compatibility"]["compatible"].bool == true,
                  !channels.isEmpty, channels.count == settings["channels"].array.count,
                  channels.contains(where: \.enabled),
                  channels.allSatisfy({ $0.channel < image.channels }),
                  Set(channels.map(\.channel)).count == channels.count,
                  let maxSize = settings["maxSize"].integer, (64...2048).contains(maxSize),
                  let maxDimension = settings["maxDimension"].integer, (16...128).contains(maxDimension),
                  settings["intensityUnits"].string == image.intensityUnits else {
                throw WorkbenchFailure(code: "invalid-response", message: "The preset settings are not compatible with this image. Refresh the preset and review its channel mapping.")
            }
            self.composite.channels = channels
            self.composite.maximumSize = maxSize
            self.composite.volumeMaximumDimension = maxDimension
            self.composite.presetReference = result["presetRef"]
            self.composite.presetResolvedSettings = settings
            state.warnings = result["compatibility"]["warnings"].array.compactMap(\.string)
            state.message = "Applied \(preset.name), version \(preset.version), to the display draft. Render when ready."
            self.reportStatus(state.message)
        }
    }

    func saveDisplayPreset(asNew: Bool) {
        let state = composite.presets
        guard canRefreshWithoutDiscardingEdits, !hasActiveWorkers, composite.valid,
              let image = selectedImage, ["raw-source", "processed-source"].contains(image.intensityUnits),
              !state.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              asNew || (state.selected != nil && !state.isArchived) else { return }
        var arguments: [String: WorkbenchJSON] = [
            "name": .string(state.name.trimmingCharacters(in: .whitespacesAndNewlines)),
            "notes": .string(state.notes), "channels": composite.channelArguments,
            "maxSize": .number(Double(composite.maximumSize)),
            "maxDimension": .number(Double(composite.volumeMaximumDimension)),
            "intensityUnits": .string(image.intensityUnits)
        ]
        if !asNew, let preset = state.selected { arguments["presetId"] = .string(preset.id) }
        perform(asNew ? "Saving new display preset…" : "Saving display preset version…", refreshOnConflict: false) {
            let previousRevision = self.revision
            let result = try await self.call("display.preset.save", arguments: arguments, mutation: true)["result"]["preset"]
            self.carryDisplayRevision(afterMetadataRevision: previousRevision)
            guard let preset = WorkbenchDisplayPreset(result) else {
                throw WorkbenchFailure(code: "invalid-response", message: "The preset was saved, but its response could not be read. Refresh the preset list before saving again.")
            }
            state.upsert(preset); state.select(preset, channelCount: image.channels)
            state.message = "Saved \(preset.name), version \(preset.version). The display draft and rendered views are unchanged."
            self.reportStatus(state.message)
        }
    }

    func archiveDisplayPreset(_ archived: Bool) {
        guard canRefreshWithoutDiscardingEdits, !hasActiveWorkers, let preset = composite.presets.selected else { return }
        perform(archived ? "Archiving display preset…" : "Restoring display preset…", refreshOnConflict: false) {
            let previousRevision = self.revision
            let result = try await self.call("display.preset.archive", arguments: [
                "presetId": .string(preset.id), "archived": .bool(archived)
            ], mutation: true)["result"]["preset"]
            self.carryDisplayRevision(afterMetadataRevision: previousRevision)
            guard let updated = WorkbenchDisplayPreset(result) else {
                throw WorkbenchFailure(code: "invalid-response", message: "The archive change was saved. Refresh the preset list to read its current state.")
            }
            self.composite.presets.upsert(updated)
            self.composite.presets.message = archived
                ? "Preset archived. Enable Show archived presets to restore it later."
                : "Preset restored. Its saved versions remain available."
            self.reportStatus(self.composite.presets.message)
        }
    }

    func previewDisplayPresetImport(at url: URL) {
        let state = composite.presets
        perform("Reading display preset JSON…", refreshOnConflict: false) {
            state.importPreview = nil
            let response = try await self.call("display.preset.import.preview", arguments: ["path": .string(url.path)])
            let result = response["result"]
            guard result["previewFingerprint"].string != nil, result["preset"]["name"].string != nil else {
                throw WorkbenchFailure(code: "invalid-response", message: "The preset file could not be previewed. Choose a CellCounter display preset JSON file and try again.")
            }
            state.importPath = url.path
            state.importPreview = result
            state.importName = result["preset"]["name"].string ?? "Imported display preset"
            state.importRevision = response["revision"].integer ?? self.revision
            self.reportStatus("Preset file preview ready. Import creates a new local preset without changing display settings.")
        }
    }

    func importDisplayPreset() {
        let state = composite.presets
        guard canRefreshWithoutDiscardingEdits, !hasActiveWorkers,
              state.importRevision == revision, !state.importPath.isEmpty,
              let fingerprint = state.importPreview?["previewFingerprint"].string else { return }
        var arguments: [String: WorkbenchJSON] = [
            "path": .string(state.importPath), "previewFingerprint": .string(fingerprint)
        ]
        let name = state.importName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty { arguments["name"] = .string(name) }
        perform("Importing display preset…", refreshOnConflict: false) {
            let previousRevision = self.revision
            let result = try await self.call("display.preset.import.run", arguments: arguments, mutation: true)["result"]
            self.carryDisplayRevision(afterMetadataRevision: previousRevision)
            guard let preset = WorkbenchDisplayPreset(result["preset"]) else {
                throw WorkbenchFailure(code: "invalid-response", message: "The preset was imported, but its response could not be read. Refresh the preset list before importing again.")
            }
            state.upsert(preset); state.select(preset, channelCount: self.selectedImage?.channels ?? 1)
            state.importPreview = nil; state.importPath = ""; state.importRevision = nil
            state.message = "Imported \(preset.name) as a new local preset. Choose Apply settings to use it."
            self.reportStatus(state.message)
        }
    }

    func exportDisplayPreset(to destination: URL) {
        guard canRefreshWithoutDiscardingEdits, !hasActiveWorkers, let preset = composite.presets.selected else { return }
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            error = "Choose a new filename. Preset exports preserve existing files."
            return
        }
        perform("Exporting display preset version…", refreshOnConflict: false) {
            let previousRevision = self.revision
            let result = try await self.call("display.preset.export", arguments: [
                "presetId": .string(preset.id), "version": .number(Double(preset.version)),
                "format": .string("preset-json"), "destination": .string(destination.path)
            ], mutation: true)["result"]
            self.carryDisplayRevision(afterMetadataRevision: previousRevision)
            self.composite.presets.exportResult = result
            self.reportStatus("Exported \(preset.name), version \(preset.version), to \(destination.lastPathComponent).")
        }
    }

    private func carryDisplayRevision(afterMetadataRevision previous: Int?) {
        if let previous, composite.renderedRevision == previous { composite.renderedRevision = revision }
        if let previous, composite.volumeRevision == previous { composite.volumeRevision = revision }
    }
}
