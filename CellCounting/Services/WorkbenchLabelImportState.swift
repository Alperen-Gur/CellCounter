import AppKit
import Observation

@MainActor @Observable
final class WorkbenchLabelImportState {
    var path = ""
    var previewArguments: WorkbenchJSON?
    var result: WorkbenchJSON?
    var previewImage: NSImage?
    var display: WorkbenchJSON?
    var generation = 0
    var applied = false

    func clearPreview() {
        previewArguments = nil; result = nil; previewImage = nil; display = nil
        generation += 1
    }
    func reset() { path = ""; applied = false; clearPreview() }
}

extension WorkbenchSession {
    var labelImportArguments: [String: WorkbenchJSON] {
        var args: [String: WorkbenchJSON] = [
            "imageId": .string(selectedImageID ?? ""), "path": .string(labelImport.path),
            "target": .string(viewingVolume ? "volume" : "plane")
        ]
        if viewingVolume {
            args["timeIndex"] = .number(Double(volume.timeIndex))
            args["channel"] = .number(Double(volume.channel))
        } else {
            args["sourceParameters"] = .object([
                "channel": .number(Double(channel)), "zProjection": .string(projection)
            ])
        }
        return args
    }

    var labelImportPreviewCurrent: Bool {
        labelImport.previewArguments == .object(labelImportArguments) &&
            labelImport.result?["previewFingerprint"].string != nil &&
            (labelImport.previewImage != nil || labelImport.display != nil)
    }

    func chooseLabelImport(_ url: URL) {
        labelImport.path = url.path
        previewLabelImport()
    }

    func previewLabelImport() {
        guard selectedImageID != nil, !labelImport.path.isEmpty else { return }
        let source = labelImportArguments
        var args = source
        args["maxSize"] = .number(768)
        perform("Previewing external labels against the selected source…") {
            self.labelImport.clearPreview()
            let result = try await self.call("mask.import.preview", arguments: args)["result"]
            if case .object = result["display"] {
                self.labelImport.display = result["display"]
            } else {
                self.labelImport.previewImage = try self.decodePreview(result)
            }
            self.labelImport.result = result
            self.labelImport.previewArguments = .object(source)
            self.reportStatus("Inspect the label alignment, then apply to save exact object identities.")
        }
    }

    func applyLabelImport() {
        guard labelImportPreviewCurrent, !hasActiveWorkers,
              let fingerprint = labelImport.result?["previewFingerprint"].string else { return }
        var args = labelImportArguments
        args["previewFingerprint"] = .string(fingerprint)
        perform("Saving imported labels and recalculating measurements…") {
            _ = try await self.call("mask.import.run", arguments: args, mutation: true)
            try await self.inspect()
            self.invalidateSummaries()
            try await self.loadImage()
            self.labelImport.applied = true
            self.reportStatus("Imported labels saved. Use Undo correction to restore the previous mask.")
        }
    }
}
