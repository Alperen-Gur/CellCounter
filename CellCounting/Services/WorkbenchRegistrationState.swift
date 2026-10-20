import AppKit
import Observation

@MainActor @Observable
final class WorkbenchRegistrationState {
    var fixedID = ""
    var movingID = ""
    var fixedChannel = 0
    var movingChannel = 0
    var fixedTime = 0
    var movingTime = 0
    var fixedProjection = "max"
    var movingProjection = "max"
    var shiftX = 0.0
    var shiftY = 0.0
    var interpolation = "linear"
    var fillValue = 0.0
    var upsampleFactor = 10
    var maximumShift = 100.0
    var window = "hann"
    var estimate: WorkbenchJSON?
    var estimateContext: WorkbenchJSON?
    var previewArguments: WorkbenchJSON?
    var preview: NSImage?
    var fixedPreview: NSImage?
    var overlay: NSImage?
    var supportPreview: NSImage?
    var support: WorkbenchJSON?
    var lastCreatedImageID: String?

    var selection: [String: WorkbenchJSON] {
        ["fixedImageId": .string(fixedID), "movingImageId": .string(movingID),
         "fixedSelection": .object(["channel": .number(Double(fixedChannel)),
                                   "timeIndex": .number(Double(fixedTime)), "zProjection": .string(fixedProjection)]),
         "movingSelection": .object(["channel": .number(Double(movingChannel)),
                                    "timeIndex": .number(Double(movingTime)), "zProjection": .string(movingProjection)])]
    }
    var transform: [String: WorkbenchJSON] {
        var args = selection
        args["shiftPx"] = .object(["x": .number(shiftX), "y": .number(shiftY)])
        args["interpolation"] = .string(interpolation)
        args["fillValue"] = .number(fillValue)
        if estimateContext == .object(selection), let fingerprint = estimate?["inputFingerprint"].string {
            args["expectedInputFingerprint"] = .string(fingerprint)
        }
        return args
    }
    var previewCurrent: Bool { preview != nil && previewArguments == .object(transform) }
    var validTransform: Bool {
        !fixedID.isEmpty && !movingID.isEmpty && fixedID != movingID &&
            shiftX.isFinite && shiftY.isFinite && abs(shiftX) <= 1_000_000 &&
            abs(shiftY) <= 1_000_000 && fillValue.isFinite
    }
    func clearPreview() {
        preview = nil; fixedPreview = nil; overlay = nil; supportPreview = nil
        previewArguments = nil; support = nil
    }
    func reset() {
        fixedID = ""; movingID = ""; estimate = nil; estimateContext = nil
        lastCreatedImageID = nil; clearPreview()
    }
}

extension WorkbenchSession {
    func loadRegistration() {
        perform("Loading registration sources…") {
            try await self.inspect()
            if let current = self.selectedImageID { self.registration.movingID = current }
            if self.registration.fixedID == self.registration.movingID { self.registration.fixedID = "" }
            if !self.registration.fixedID.isEmpty { _ = try await self.resolveImage(self.registration.fixedID) }
            self.registration.lastCreatedImageID = nil
            self.registration.estimate = nil
            self.registration.estimateContext = nil
            self.registration.clearPreview()
            self.reportStatus("Choose fixed and moving 2D source selections.")
        }
    }

    func estimateRegistration() {
        let selection = registration.selection
        var args = selection
        args["upsampleFactor"] = .number(Double(registration.upsampleFactor))
        args["maxShiftPx"] = .number(registration.maximumShift)
        args["window"] = .string(registration.window)
        perform("Estimating 2D translation…") {
            self.registration.clearPreview()
            let result = try await self.call("registration.estimate", arguments: args)["result"]
            self.registration.estimate = result
            self.registration.estimateContext = .object(selection)
            self.registration.shiftX = result["shiftPx"]["x"].number ?? 0
            self.registration.shiftY = result["shiftPx"]["y"].number ?? 0
            self.reportStatus("Translation estimated. Inspect overlap and valid support before saving.")
        }
    }

    func applyRegistration(name: String, previewOnly: Bool) {
        guard registration.validTransform else { return }
        let transform = registration.transform
        var args = transform
        args["maxSize"] = .number(1024)
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !previewOnly && !trimmed.isEmpty { args["name"] = .string(trimmed) }
        perform(previewOnly ? "Previewing translated source…" : "Saving registered acquisition…") {
            self.registration.clearPreview()
            let result = try await self.call(previewOnly ? "registration.preview" : "registration.apply",
                arguments: args, mutation: !previewOnly)["result"]
            if previewOnly {
                self.registration.preview = try self.decodePreview(result)
                self.registration.fixedPreview = try self.decodePreview(.object(["dataUrl": result["fixedDataUrl"]]))
                self.registration.overlay = try self.decodePreview(.object(["dataUrl": result["overlayDataUrl"]]))
                self.registration.supportPreview = try self.decodePreview(.object(["dataUrl": result["supportDataUrl"]]))
                self.registration.support = result["support"]
                self.registration.previewArguments = .object(transform)
                self.reportStatus("Registration preview ready. Filled pixels are marked separately from measured source.")
            } else {
                try await self.inspect()
                self.selectedImageID = result["derivedImageId"].string
                self.invalidateSummaries()
                try await self.loadImage()
                self.registration.lastCreatedImageID = result["derivedImageId"].string
                self.reportStatus("Registered image saved on the fixed grid with exact valid-support provenance.")
            }
        }
    }
}
