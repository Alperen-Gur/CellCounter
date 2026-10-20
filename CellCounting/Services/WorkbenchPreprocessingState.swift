import AppKit
import Observation

nonisolated struct WorkbenchPreprocessingFilter: Identifiable, Sendable {
    let id: String
    let dimensions: [Int]
    let defaults: [String: WorkbenchJSON]
    let parameters: [WorkbenchPluginParameter]
    let effect: String
    let name: String
    let notes: [String]

    init?(_ value: WorkbenchJSON, schema: WorkbenchJSON) {
        guard let method = value["method"].string else { return nil }
        id = method
        name = value["name"].string ?? method.replacingOccurrences(of: "-", with: " ").capitalized
        notes = value["notes"].array.compactMap(\.string)
        dimensions = value["dimensions"].array.compactMap(\.integer)
        let initialDefaults = value["defaults"].object
        defaults = initialDefaults
        parameters = initialDefaults.keys.sorted().map { key in
            var fields = schema["properties"][key].object
            fields["default"] = initialDefaults[key]
            fields["title"] = .string(Self.parameterName(key))
            if let units = value["parameterUnits"][key].string {
                let unitDescription = "Units: \(units.replacingOccurrences(of: "-", with: " "))."
                let existing = fields["description"]?.string
                fields["description"] = .string(existing.map { "\($0) \(unitDescription)" } ?? unitDescription)
            }
            return WorkbenchPluginParameter(id: key, schema: .object(fields), required: true)
        }
        effect = value["intensityEffect"].string?.replacingOccurrences(of: "-", with: " ") ?? ""
    }

    private static func parameterName(_ key: String) -> String {
        switch key {
        case "clipLimit": return "Contrast clip limit"
        case "lowerPercentile": return "Lower percentile"
        case "upperPercentile": return "Upper percentile"
        case "size": return "Neighborhood size (odd)"
        case "sigma": return "Gaussian sigma"
        case "radius": return "Radius"
        case "psfSigmaXY": return "Synthetic PSF sigma in XY"
        case "psfSigmaZ": return "Synthetic PSF sigma in Z"
        case "clipAtZero": return "Clip negative values to zero"
        case "level": return "Background level to subtract"
        case "amount": return "Sharpening amount"
        default: return key.capitalized
        }
    }
}

nonisolated struct WorkbenchPreprocessingStep: Identifiable {
    let id = UUID()
    var method: String
    var values: [String: WorkbenchJSON]
    var json: WorkbenchJSON {
        var result = values
        result["method"] = .string(method)
        return .object(result)
    }
}

@MainActor @Observable
final class WorkbenchPreprocessingState {
    var filters: [WorkbenchPreprocessingFilter] = []
    var notes: [String] = []
    var preview: NSImage?
    var display: WorkbenchJSON?
    var recipe: WorkbenchJSON?
    var sourceContext: String?
    var summary: WorkbenchJSON?
    var provenance: WorkbenchJSON?
    var generation = 0
    func invalidatePreview() {
        preview = nil; display = nil; recipe = nil; sourceContext = nil; summary = nil
        generation += 1
    }
    func reset() { filters = []; notes = []; provenance = nil; invalidatePreview() }
}

extension WorkbenchSession {
    var preprocessingContext: String {
        "\(selectedImageID ?? "")|\(viewingVolume)|\(viewingVolume ? volume.timeIndex : 0)|\(viewingVolume ? volume.channel : channel)|\(viewingVolume ? "" : projection)"
    }

    func loadPreprocessing() {
        perform("Loading preprocessing methods…") {
            try await self.readPreprocessingCatalog()
            self.preprocessing.invalidatePreview()
            if let imageID = self.selectedImageID {
                self.preprocessing.provenance = try await self.call("preprocessing.inspect",
                    arguments: ["imageId": .string(imageID)])["result"]
            }
            self.reportStatus("Preprocessing methods loaded.")
        }
    }

    func readPreprocessingCatalog() async throws {
        let result = try await call("preprocessing.catalogue")["result"]
        preprocessing.filters = result["filters"].array.compactMap {
            WorkbenchPreprocessingFilter($0, schema: result["recipeSchema"]["items"])
        }
        preprocessing.notes = result["notes"].array.compactMap(\.string)
    }

    func preprocess(recipe: [WorkbenchJSON], name: String, previewOnly: Bool) {
        guard let imageID = selectedImageID else { return }
        let context = preprocessingContext
        var args: [String: WorkbenchJSON] = [
            "imageId": .string(imageID), "recipe": .array(recipe),
            "target": .string(viewingVolume ? "volume" : "plane")
        ]
        if viewingVolume {
            args["timeIndex"] = .number(Double(volume.timeIndex))
            args["channel"] = .number(Double(volume.channel))
        } else {
            args["sourceParameters"] = parameters
        }
        if !previewOnly && !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            args["name"] = .string(name.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        perform(previewOnly ? "Previewing preprocessing recipe…" : "Creating processed acquisition…") {
            self.preprocessing.invalidatePreview()
            let result = try await self.call(previewOnly ? "preprocessing.preview" : "preprocessing.run",
                arguments: args, mutation: !previewOnly)["result"]
            if previewOnly {
                guard context == self.preprocessingContext else { return }
                self.preprocessing.preview = try self.decodePreview(result)
                if case .object = result["display"] { self.preprocessing.display = result["display"] }
                self.preprocessing.recipe = .array(recipe)
                self.preprocessing.sourceContext = context
                self.preprocessing.summary = result["summary"]
                self.reportStatus("Recipe preview ready. Source pixels and masks are unchanged.")
            } else {
                try await self.inspect()
                self.selectedImageID = result["derivedImageId"].string
                self.invalidateSummaries()
                try await self.loadImage()
                self.reportStatus("Processed acquisition created with its frozen recipe and source selection.")
            }
        }
    }
}
