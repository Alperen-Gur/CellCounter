import Foundation
import Observation

nonisolated struct WorkbenchImageExportFormat: Identifiable, Sendable {
    let id: String
    let name: String
    let fileExtension: String
    let mediaType: String
    let targets: [String]
    let requiresAnalysis: Bool
    let description: String

    init?(_ value: WorkbenchJSON) {
        guard let id = value["id"].string, let fileExtension = value["extension"].string else { return nil }
        self.id = id
        self.name = value["name"].string ?? id
        self.fileExtension = fileExtension
        self.mediaType = value["mediaType"].string ?? "application/octet-stream"
        self.targets = value["targets"].array.compactMap(\.string)
        self.requiresAnalysis = value["requiresAnalysis"].bool == true
        self.description = value["description"].string ?? ""
    }
}

@MainActor @Observable
final class WorkbenchImageExportState {
    var formats: [WorkbenchImageExportFormat] = []
    var selectedFormatID = ""
    var imageID = ""
    var target = "plane"
    var timeIndex = 0
    var channel = 0
    var projection = "max"
    var maximumOverlaySize = 2048
    var result: WorkbenchJSON?

    var availableFormats: [WorkbenchImageExportFormat] { formats.filter { $0.targets.contains(target) } }
    var selectedFormat: WorkbenchImageExportFormat? { availableFormats.first { $0.id == selectedFormatID } }
    var arguments: [String: WorkbenchJSON] {
        var args: [String: WorkbenchJSON] = [
            "imageId": .string(imageID), "format": .string(selectedFormatID), "target": .string(target)
        ]
        if target == "volume" {
            args["timeIndex"] = .number(Double(timeIndex))
            args["channel"] = .number(Double(channel))
        } else if selectedFormatID == "source-ome-tiff" || selectedFormatID == "support-ome-tiff" {
            args["sourceParameters"] = .object([
                "channel": .number(Double(channel)), "zProjection": .string(projection)
            ])
        }
        if selectedFormatID == "overlay-png" { args["maxSize"] = .number(Double(maximumOverlaySize)) }
        return args
    }

    func reset() {
        formats = []; selectedFormatID = ""; imageID = ""; result = nil
    }
}

extension WorkbenchSession {
    func loadImageExports() {
        guard let image = selectedImage else { return }
        imageExports.imageID = image.id
        imageExports.target = viewingVolume ? "volume" : "plane"
        imageExports.timeIndex = viewingVolume ? volume.timeIndex : 0
        imageExports.channel = viewingVolume ? volume.channel : channel
        imageExports.projection = projection
        imageExports.result = nil
        perform("Loading scientific export formats…") {
            let result = try await self.call("image.export.catalogue")["result"]
            self.imageExports.formats = result["formats"].array.compactMap(WorkbenchImageExportFormat.init)
            if self.imageExports.selectedFormat == nil {
                self.imageExports.selectedFormatID = self.imageExports.availableFormats.first?.id ?? ""
            }
            self.reportStatus("Choose a scientific image export and a new destination.")
        }
    }

    func exportImage(to destination: URL, arguments: [String: WorkbenchJSON]) {
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            error = "Choose a new destination. Scientific exports preserve existing files."
            return
        }
        var args = arguments
        args["destination"] = .string(destination.path)
        perform("Exporting scientific image data…") {
            self.imageExports.result = nil
            let result = try await self.call("image.export", arguments: args, mutation: true)["result"]
            self.imageExports.result = result
            try await self.inspect()
            self.reportStatus("Export saved: \(destination.lastPathComponent)")
        }
    }
}
