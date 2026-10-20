import AppKit
import Observation

@MainActor @Observable
final class WorkbenchMaskComparisonState {
    var leftID = ""
    var rightID = ""
    var target = "plane"
    var timeIndex = 0
    var channel = 0
    var plane = "xy"
    var index = 0
    var result: WorkbenchJSON?
    var resultArguments: WorkbenchJSON?
    var resultRevision: Int?
    var overlay: NSImage?
    var source: NSImage?

    var arguments: [String: WorkbenchJSON] {
        var args: [String: WorkbenchJSON] = [
            "leftImageId": .string(leftID), "rightImageId": .string(rightID), "target": .string(target)
        ]
        if target == "volume" {
            args["timeIndex"] = .number(Double(timeIndex))
            args["channel"] = .number(Double(channel))
            args["plane"] = .string(plane)
            args["index"] = .number(Double(index))
        }
        return args
    }
    func clearResult() {
        result = nil; resultArguments = nil; resultRevision = nil; overlay = nil; source = nil
    }
    func reset() { leftID = ""; rightID = ""; clearResult() }
}

extension WorkbenchSession {
    var comparisonCurrent: Bool {
        comparison.result != nil && comparison.resultArguments == .object(comparison.arguments) &&
            comparison.resultRevision == revision
    }

    func prepareMaskComparison() {
        comparison.clearResult()
        comparison.leftID = selectedImageID ?? ""
        comparison.target = viewingVolume ? "volume" : "plane"
        comparison.timeIndex = viewingVolume ? volume.timeIndex : 0
        comparison.channel = viewingVolume ? volume.channel : 0
        comparison.plane = viewingVolume ? volume.plane : "xy"
        comparison.index = viewingVolume ? volume.index : 0
        // A page or metadata-cache miss never discards a deliberate variant ID.
        if comparison.rightID == comparison.leftID { comparison.rightID = "" }
    }

    func compareSavedMasks() {
        guard !comparison.leftID.isEmpty, !comparison.rightID.isEmpty else { return }
        let inputs = comparison.arguments
        var args = inputs
        args["maxSize"] = .number(768)
        perform("Comparing exact saved masks…", refreshOnConflict: false) {
            self.comparison.clearResult()
            let response = try await self.call("mask.compare", arguments: args)
            let result = response["result"]
            self.comparison.source = try self.decodePreview(result)
            self.comparison.overlay = try self.decodePreview(.object(["dataUrl": result["overlayDataUrl"]]))
            self.comparison.result = result
            self.comparison.resultArguments = .object(inputs)
            self.comparison.resultRevision = response["revision"].integer ?? self.revision
            self.reportStatus("Saved masks compared. Agreement measures describe the selected analyses.")
        }
    }
}
