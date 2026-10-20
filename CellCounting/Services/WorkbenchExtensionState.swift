import Foundation
import Observation

nonisolated struct WorkbenchPlugin: Identifiable, Sendable {
    let id: String
    let name: String
    let version: String
    let kind: String
    let summary: String
    let enabled: Bool
    let available: Bool
    let dimensions: [Int]
    let parameters: [WorkbenchPluginParameter]
    let sourceHash: String
    let error: String?

    init?(_ value: WorkbenchJSON) {
        guard let id = value["pluginId"].string else { return nil }
        self.id = id
        let manifest = value["manifest"]
        name = manifest["name"].string ?? id
        version = manifest["version"].string ?? ""
        kind = manifest["kind"].string ?? ""
        summary = manifest["description"].string ?? ""
        enabled = value["enabled"].bool == true
        available = value["available"].bool != false
        dimensions = manifest["supportedDimensions"].array.compactMap(\.integer)
        let required = Set(manifest["parameters"]["required"].array.compactMap(\.string))
        parameters = manifest["parameters"]["properties"].object.sorted { $0.key < $1.key }.map {
            WorkbenchPluginParameter(id: $0.key, schema: $0.value, required: required.contains($0.key))
        }
        sourceHash = value["sourceHash"].string ?? ""
        error = value["error"]["message"].string
    }

    var initialParameters: [String: WorkbenchJSON] {
        Dictionary(uniqueKeysWithValues: parameters.compactMap {
            $0.required || $0.schema["default"] != .null ? ($0.id, $0.initialValue) : nil
        })
    }
}

nonisolated struct WorkbenchPluginParameter: Identifiable, Sendable {
    let id: String
    let schema: WorkbenchJSON
    let required: Bool
    var title: String { schema["title"].string ?? id }
    var type: String { schema["type"].string ?? "string" }
    var choices: [WorkbenchJSON] { schema["enum"].array }
    var initialValue: WorkbenchJSON {
        if schema["default"] != .null { return schema["default"] }
        if let first = choices.first { return first }
        switch type {
        case "integer", "number":
            let value = max(schema["minimum"].number ?? -.infinity,
                            min(0, schema["maximum"].number ?? .infinity))
            return .number(type == "integer" ? value.rounded(.up) : value)
        case "boolean": return .bool(false)
        default: return .string("")
        }
    }
}

@MainActor @Observable
final class WorkbenchExtensionState {
    var plugins: [WorkbenchPlugin] = []
    var runs: [WorkbenchJSON] = []
    var runOutput: WorkbenchJSON?
    var datasets: [WorkbenchJSON] = []
    var suggestions: WorkbenchJSON?
    var evaluationPreview: WorkbenchJSON?
    var evaluationArguments: WorkbenchJSON?
    var evaluationRevision: Int?
    var selectedPluginID = ""
    var selectedDatasetID = ""
    var referenceCurrent: [String: Bool] = [:]
    var selectedDataset: WorkbenchJSON? {
        datasets.first { $0["id"].string == selectedDatasetID }
    }
    func reset() {
        plugins = []; runs = []; runOutput = nil; datasets = []; suggestions = nil
        selectedPluginID = ""; selectedDatasetID = ""; referenceCurrent = [:]
        evaluationPreview = nil; evaluationArguments = nil; evaluationRevision = nil
    }
    func invalidateResults() { runs = []; runOutput = nil; suggestions = nil }
    func normalizeSelection() {
        if selectedPluginID.isEmpty { selectedPluginID = plugins.first?.id ?? "" }
        if selectedDatasetID.isEmpty {
            selectedDatasetID = datasets.first?["id"].string ?? ""
        }
    }
}

extension WorkbenchSession {
    func loadExtensions() {
        perform("Loading project extensions…") {
            try await self.inspect()
            try await self.readExtensionCatalogs()
            if !self.hasDisplayedImage { try await self.loadImage() }
            if let id = self.selectedImageID {
                self.extensions.runs = try await self.call("plugin.results",
                    arguments: ["imageId": .string(id)])["result"]["runs"].array
                self.extensions.runOutput = nil
            }
            self.reportStatus("Project extensions and reference datasets loaded.")
        }
    }

    func readExtensionCatalogs() async throws {
        extensions.plugins = try await readCatalogue("plugins").compactMap(WorkbenchPlugin.init)
        extensions.normalizeSelection()
    }

    func installPlugin(at url: URL) {
        changeExtension("plugin.install", arguments: ["manifestPath": .string(url.path)],
                        message: "Installing local plugin source…", finished: "Plugin installed disabled. Review it before enabling.")
    }

    func setPluginEnabled(_ pluginID: String, enabled: Bool) {
        changeExtension("plugin.setEnabled", arguments: ["pluginId": .string(pluginID), "enabled": .bool(enabled)],
                        message: "Updating plugin trust…", finished: enabled ? "Plugin enabled." : "Plugin disabled.")
    }

    func runPlugin(_ plugin: WorkbenchPlugin, parameters values: [String: WorkbenchJSON]) {
        guard let imageID = selectedImageID, ["segmentation", "measurement"].contains(plugin.kind) else { return }
        var args: [String: WorkbenchJSON] = [
            "pluginId": .string(plugin.id), "imageId": .string(imageID), "parameters": .object(values),
            "target": .string(viewingVolume ? "volume" : "plane")
        ]
        if viewingVolume {
            args["timeIndex"] = .number(Double(volume.timeIndex))
            args["channel"] = .number(Double(volume.channel))
        } else if plugin.kind == "segmentation" { args["sourceParameters"] = parameters }
        changeExtension("plugin.run", arguments: args, message: "Running local plugin…",
                        finished: "Plugin output saved with provenance.", reloadImage: true)
    }

    func readWithPlugin(_ plugin: WorkbenchPlugin, source: URL, parameters: [String: WorkbenchJSON]) {
        guard plugin.kind == "reader" else { return }
        perform("Reading acquisition with local plugin…") {
            let result = try await self.call("plugin.read", arguments: [
                "pluginId": .string(plugin.id), "path": .string(source.path), "parameters": .object(parameters)
            ], mutation: true)["result"]
            try await self.inspect()
            self.selectedImageID = result["imageId"].string ?? result["importedImageIds"].array.first?.string
            self.invalidateSummaries()
            try await self.loadImage()
            self.reportStatus("Reader output imported; original file and reader provenance retained.")
        }
    }

    func exportWithPlugin(_ plugin: WorkbenchPlugin, destination: URL, parameters values: [String: WorkbenchJSON]) {
        guard let imageID = selectedImageID, plugin.kind == "exporter" else { return }
        var args: [String: WorkbenchJSON] = [
            "pluginId": .string(plugin.id), "imageId": .string(imageID), "parameters": .object(values),
            "destination": .string(destination.path), "target": .string(viewingVolume ? "volume" : "plane")
        ]
        if viewingVolume {
            args["timeIndex"] = .number(Double(volume.timeIndex))
            args["channel"] = .number(Double(volume.channel))
        } else { args["sourceParameters"] = parameters }
        perform("Exporting with local plugin…") {
            let result = try await self.call("plugin.export", arguments: args, mutation: true)["result"]
            try await self.inspect()
            self.extensions.runs = try await self.call("plugin.results", arguments: [
                "imageId": .string(imageID)
            ])["result"]["runs"].array
            if let runID = result["run"]["runId"].string {
                self.extensions.runOutput = try await self.call("plugin.results", arguments: [
                    "runId": .string(runID)
                ])["result"]["runs"].array.first
            }
            self.reportStatus("Exported \(destination.lastPathComponent); exact output retained in the project.")
        }
    }

    func loadPluginResults(runID: String? = nil) {
        perform("Loading plugin results…") {
            var args: [String: WorkbenchJSON] = [:]
            if let runID { args["runId"] = .string(runID) }
            else if let imageID = self.selectedImageID { args["imageId"] = .string(imageID) }
            let rows = try await self.call("plugin.results", arguments: args)["result"]["runs"].array
            if runID != nil { self.extensions.runOutput = rows.first }
            else { self.extensions.runs = rows; self.extensions.runOutput = nil }
            self.reportStatus("Plugin results loaded with currentness checks.")
        }
    }

    func approveReference(imageID: String, approved: Bool, note: String) {
        var args: [String: WorkbenchJSON] = ["imageId": .string(imageID), "approved": .bool(approved)]
        if !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { args["note"] = .string(note) }
        changeExtension("adaptation.reference.set",
            arguments: args,
            message: "Saving reference review…", finished: approved ? "Current mask approved as a reference." : "Reference approval revoked.")
    }

    func showReferenceImage(_ imageID: String) {
        guard !busy, !imageID.isEmpty else { return }
        selectedImageID = imageID
        viewingVolume = false
        perform("Loading reference mask…") {
            let image = try await self.resolveImage(imageID)
            self.volume.configure(for: image)
            try await self.loadImage()
        }
    }

    func suggestReferences(imageIDs: Set<String>) {
        guard !imageIDs.isEmpty, imageIDs.count <= 200 else { return }
        perform("Suggesting reference images…") {
            self.extensions.suggestions = try await self.call("adaptation.suggest",
                arguments: ["limit": .number(12), "imageIds": .array(imageIDs.sorted().map(WorkbenchJSON.string))])["result"]
            self.reportStatus("Suggestions ready. Difficulty scores are annotation heuristics.")
        }
    }

    func createReferenceDataset(name: String, imageIDs: Set<String>, partitions: [String: String], inputChannels: [Int]? = nil) {
        var arguments: [String: WorkbenchJSON] = [
            "name": .string(name), "imageIds": .array(imageIDs.sorted().map(WorkbenchJSON.string)),
            "validationSpecimenIds": .array(partitions.filter { $0.value == "validation" }.keys.sorted().map(WorkbenchJSON.string)),
            "testSpecimenIds": .array(partitions.filter { $0.value == "test" }.keys.sorted().map(WorkbenchJSON.string))
        ]
        if let inputChannels { arguments["inputChannels"] = .array(inputChannels.map { .number(Double($0)) }) }
        changeExtension("adaptation.dataset.create", arguments: arguments, message: "Freezing reference dataset…", finished: "Immutable specimen split saved.")
    }

    func previewReferenceComparison(_ arguments: WorkbenchJSON) {
        perform("Checking exact frozen input compatibility…", refreshOnConflict: false) {
            self.extensions.evaluationPreview = nil
            let preview = try await self.call("adaptation.evaluate.preview", arguments: arguments.object)["result"]["preview"]
            self.extensions.evaluationPreview = preview
            self.extensions.evaluationArguments = arguments; self.extensions.evaluationRevision = self.revision
            self.reportStatus(preview["ready"].bool == true ? "Frozen inputs are compatible. Run comparison explicitly when ready." : "Resolve the displayed compatibility blockers before comparison.")
        }
    }
    func evaluateReferenceDataset(_ arguments: WorkbenchJSON) {
        guard extensions.evaluationRevision == revision, extensions.evaluationArguments == arguments,
              extensions.evaluationPreview?["ready"].bool == true,
              let fingerprint = extensions.evaluationPreview?["previewFingerprint"].string else { return }
        var args = arguments.object; args["previewFingerprint"] = .string(fingerprint)
        changeExtension("adaptation.evaluate", arguments: args,
            message: "Comparing segmenters on frozen held-out specimens…", finished: "Paired comparison saved with exact input and model identities.")
    }

    private func changeExtension(_ operation: String, arguments: [String: WorkbenchJSON],
                                 message: String, finished: String, reloadImage: Bool = false) {
        perform(message) {
            let response = try await self.call(operation, arguments: arguments, mutation: true)["result"]
            if let id = response["plugin"]["pluginId"].string { self.extensions.selectedPluginID = id }
            if let id = response["dataset"]["id"].string { self.extensions.selectedDatasetID = id }
            if let id = response["imageId"].string, let current = response["current"].bool {
                self.extensions.referenceCurrent[id] = current
            }
            try await self.inspect()
            try await self.readExtensionCatalogs()
            if reloadImage {
                try await self.loadImage()
                if let id = self.selectedImageID {
                    self.extensions.runs = try await self.call("plugin.results",
                        arguments: ["imageId": .string(id)])["result"]["runs"].array
                    self.extensions.runOutput = nil
                }
            } else if !self.hasDisplayedImage { try await self.loadImage() }
            self.invalidateSummaries()
            self.reportStatus(finished)
        }
    }
}
