import AppKit
import Observation

@MainActor @Observable
final class WorkbenchAnnotationState {
    var imageID = ""
    var records: [WorkbenchJSON] = []
    var selectedID = ""
    var savedRecord: WorkbenchJSON?
    var savedDraft: WorkbenchJSON?
    var name = "Annotation"
    var notes = ""
    var kind = "line"
    var points: [[Double]] = []
    var target = "plane"
    var channel = 0
    var projection = "max"
    var timeIndex = 0
    var plane = "xy"
    var index = 0
    var measurementChannel = 0
    var profileSamples = 512
    var useFixedProfileSamples = false
    var editVertices = false
    var selectedVertex: Int?
    var sourceImage: NSImage?
    var sourceArguments: WorkbenchJSON?
    var sourceWidth = 1
    var sourceHeight = 1
    var result: WorkbenchJSON?
    var measuredDraft: WorkbenchJSON?
    var measuredChannel: Int?
    var measuredSamples: Int?
    var measuredRevision: Int?
    var editorOpen = false
    var exportFormats: [WorkbenchImageExportFormat] = []
    var exportFormatID = "geometry-json"
    var exportResult: WorkbenchJSON?
    var importPath: String?
    var importPreview: WorkbenchJSON?

    var selectionArguments: [String: WorkbenchJSON] {
        if target == "volume" {
            return ["target": .string(target), "timeIndex": .number(Double(timeIndex)),
                    "channel": .number(Double(channel)), "plane": .string(plane), "index": .number(Double(index))]
        }
        return ["target": .string(target), "sourceParameters": .object([
            "channel": .number(Double(channel)), "zProjection": .string(projection)
        ])]
    }
    var draft: WorkbenchJSON {
        var values = selectionArguments
        values["name"] = .string(name)
        values["notes"] = .string(notes)
        values["geometry"] = .object(["type": .string(kind),
                                      "points": .array(points.map { .array($0.map(WorkbenchJSON.number)) })])
        return .object(values)
    }
    var dirty: Bool { selectedID.isEmpty ? !points.isEmpty : savedDraft != draft }
    var deleted: Bool { savedRecord?["deleted"].bool == true }
    var sourceCurrent: Bool { sourceImage != nil && sourceArguments == .object(selectionArguments) }
    var geometryComplete: Bool {
        switch kind {
        case "point": return points.count == 1
        case "line": return points.count == 2
        case "polygon": return points.count >= 3
        default: return points.count >= 2
        }
    }
    var canMeasure: Bool {
        geometryComplete && !deleted && sourceCurrent && !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            points.allSatisfy { $0.count == 2 && $0[0].isFinite && $0[1].isFinite &&
                $0[0] >= 0 && $0[1] >= 0 && $0[0] <= Double(sourceWidth) && $0[1] <= Double(sourceHeight) }
    }
    var requestedSamples: Int? {
        useFixedProfileSamples && ["line", "polyline"].contains(kind) ? profileSamples : nil
    }
    func measurementCurrent(revision: Int?) -> Bool {
        result != nil && measuredDraft == draft && measuredChannel == measurementChannel &&
            measuredSamples == requestedSamples && measuredRevision == revision
    }
    func invalidateMeasurement() {
        result = nil; measuredDraft = nil; measuredChannel = nil; measuredSamples = nil; measuredRevision = nil
    }
    func applyRecord(_ value: WorkbenchJSON) {
        savedRecord = value
        selectedID = value["id"].string ?? ""
        name = value["name"].string ?? "Annotation"
        notes = value["notes"].string ?? ""
        kind = value["geometry"]["type"].string ?? "line"
        points = value["geometry"]["points"].array.map { $0.array.compactMap(\.number) }
        target = value["target"].string ?? "plane"
        let selection = value["selection"]
        if target == "volume" {
            channel = selection["channel"].integer ?? 0
            timeIndex = selection["timeIndex"].integer ?? 0
            plane = selection["plane"].string ?? "xy"
            index = selection["index"].integer ?? 0
        } else {
            channel = selection["sourceParameters"]["channel"].integer ?? 0
            projection = selection["sourceParameters"]["zProjection"].string ?? "max"
        }
        measurementChannel = channel
        selectedVertex = nil
        savedDraft = draft
        invalidateMeasurement()
    }
    func newDraft() {
        selectedID = ""; savedRecord = nil; savedDraft = nil
        name = "\(kind.capitalized) annotation"; notes = ""; points = []; selectedVertex = nil
        measurementChannel = channel; invalidateMeasurement()
    }
    func reset() {
        imageID = ""; records = []; sourceImage = nil; sourceArguments = nil
        exportFormats = []; exportResult = nil; importPath = nil; importPreview = nil
        editorOpen = false; newDraft()
    }
}

extension WorkbenchSession {
    func loadAnnotations() {
        guard let image = selectedImage else { return }
        annotations.imageID = image.id
        annotations.target = viewingVolume || image.timeCount > 1 ? "volume" : "plane"
        annotations.channel = viewingVolume ? volume.channel : channel
        annotations.timeIndex = viewingVolume ? volume.timeIndex : 0
        annotations.plane = viewingVolume ? volume.plane : "xy"
        annotations.index = viewingVolume ? volume.index : max(0, image.zCount / 2)
        annotations.projection = projection
        annotations.editorOpen = true
        annotations.importPath = nil; annotations.importPreview = nil
        annotations.newDraft()
        perform("Loading source annotations…", refreshOnConflict: false) {
            try await self.readAnnotations()
            try await self.readAnnotationSource()
            let exports = try await self.call("annotation.export.catalogue")["result"]
            self.annotations.exportFormats = exports["formats"].array.compactMap(WorkbenchImageExportFormat.init)
            self.reportStatus("Draw source-coordinate geometry or select a saved annotation.")
        }
    }

    private func readAnnotations() async throws {
        let result = try await call("annotation.list", arguments: [
            "imageId": .string(annotations.imageID), "includeDeleted": .bool(true)
        ])["result"]
        annotations.records = result["annotations"].array
    }

    func refreshAnnotationSource() {
        perform("Loading annotation source selection…", refreshOnConflict: false) {
            try await self.readAnnotationSource()
            self.reportStatus("Source selection loaded. Geometry remains in exact source coordinates.")
        }
    }

    private func readAnnotationSource() async throws {
        let selection = WorkbenchJSON.object(annotations.selectionArguments)
        annotations.sourceImage = nil; annotations.sourceArguments = nil
        let result: WorkbenchJSON
        if annotations.target == "volume" {
            result = try await call("volume.slice", arguments: [
                "imageId": .string(annotations.imageID), "timeIndex": .number(Double(annotations.timeIndex)),
                "channel": .number(Double(annotations.channel)), "plane": .string(annotations.plane),
                "index": .number(Double(annotations.index)), "maxSize": .number(1024)
            ])["result"]
        } else {
            result = try await call("image.preview", arguments: [
                "imageId": .string(annotations.imageID),
                "parameters": selection["sourceParameters"], "maxSize": .number(1024)
            ])["result"]
        }
        annotations.sourceImage = try decodePreview(result)
        annotations.sourceWidth = result["width"].integer ?? 1
        annotations.sourceHeight = result["height"].integer ?? 1
        annotations.sourceArguments = selection
    }

    func selectAnnotation(_ id: String) {
        guard !id.isEmpty else { annotations.newDraft(); return }
        perform("Loading saved annotation geometry…", refreshOnConflict: false) {
            let result = try await self.call("annotation.get", arguments: [
                "imageId": .string(self.annotations.imageID), "annotationId": .string(id)
            ])["result"]
            self.annotations.applyRecord(result["annotation"])
            if !self.annotations.sourceCurrent { try await self.readAnnotationSource() }
            self.reportStatus(self.annotations.deleted ? "Deleted annotation selected. Undo can restore it." : "Saved annotation loaded.")
        }
    }

    func measureAnnotation() {
        guard annotations.canMeasure else { return }
        let draft = annotations.draft
        let measurementChannel = annotations.measurementChannel
        let samples = annotations.requestedSamples
        var args: [String: WorkbenchJSON] = [
            "imageId": .string(annotations.imageID), "measurementChannel": .number(Double(measurementChannel)),
            "maxSize": .number(1024)
        ]
        if !annotations.selectedID.isEmpty && !annotations.dirty {
            args["annotationId"] = .string(annotations.selectedID)
        } else { args["draft"] = draft }
        if let samples { args["profileSamples"] = .number(Double(samples)) }
        perform("Measuring annotation geometry and source intensities…", refreshOnConflict: false) {
            let response = try await self.call("annotation.measure", arguments: args)
            self.annotations.result = response["result"]
            self.annotations.measuredDraft = draft
            self.annotations.measuredChannel = measurementChannel
            self.annotations.measuredSamples = samples
            self.annotations.measuredRevision = response["revision"].integer ?? self.revision
            self.reportStatus("Annotation measured with current calibration and exact source support.")
        }
    }

    func saveAnnotation() {
        guard annotations.canMeasure, !hasActiveWorkers else { return }
        var args = annotations.draft.object
        args["imageId"] = .string(annotations.imageID)
        if !annotations.selectedID.isEmpty { args["annotationId"] = .string(annotations.selectedID) }
        mutateAnnotation("annotation.save", args: args)
    }

    func deleteAnnotation() {
        guard !annotations.selectedID.isEmpty, !hasActiveWorkers else { return }
        mutateAnnotation("annotation.delete", args: [
            "imageId": .string(annotations.imageID), "annotationId": .string(annotations.selectedID)
        ])
    }

    func undoAnnotation() {
        guard !annotations.selectedID.isEmpty, !hasActiveWorkers else { return }
        mutateAnnotation("annotation.undo", args: [
            "imageId": .string(annotations.imageID), "annotationId": .string(annotations.selectedID)
        ])
    }

    private func mutateAnnotation(_ operation: String, args: [String: WorkbenchJSON]) {
        perform("Saving annotation revision…", refreshOnConflict: false) {
            let result = try await self.call(operation, arguments: args, mutation: true)["result"]
            self.annotations.applyRecord(result["annotation"])
            try await self.inspect()
            try await self.readAnnotations()
            if !self.annotations.sourceCurrent { try await self.readAnnotationSource() }
            self.reportStatus("Annotation revision saved. Cell masks and canvas edits are preserved.")
        }
    }

    func exportAnnotation(to destination: URL) {
        guard !annotations.selectedID.isEmpty, !annotations.dirty, !annotations.deleted, !hasActiveWorkers else { return }
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            error = "Choose a new destination. Annotation exports preserve existing files."
            return
        }
        var args: [String: WorkbenchJSON] = [
            "imageId": .string(annotations.imageID), "annotationId": .string(annotations.selectedID),
            "format": .string(annotations.exportFormatID), "destination": .string(destination.path)
        ]
        if annotations.exportFormatID != "geometry-json" {
            args["measurementChannel"] = .number(Double(annotations.measurementChannel))
            if let samples = annotations.requestedSamples { args["profileSamples"] = .number(Double(samples)) }
        }
        perform("Exporting saved annotation…", refreshOnConflict: false) {
            let result = try await self.call("annotation.export", arguments: args, mutation: true)["result"]
            self.annotations.exportResult = result
            try await self.inspect()
            self.reportStatus("Annotation exported to \(destination.lastPathComponent).")
        }
    }

    func previewAnnotationImport(_ source: URL) {
        guard !annotations.dirty else { return }
        let imageID = annotations.imageID
        annotations.importPath = nil; annotations.importPreview = nil
        perform("Checking annotation source and geometry…", refreshOnConflict: false) {
            let result = try await self.call("annotation.import.preview", arguments: [
                "imageId": .string(imageID), "path": .string(source.path)
            ])["result"]
            self.annotations.importPath = source.path
            self.annotations.importPreview = result
            self.reportStatus("Annotation compatibility preview ready. Import creates a separate saved annotation.")
        }
    }

    func importAnnotation() {
        guard !annotations.dirty, !hasActiveWorkers,
              let path = annotations.importPath,
              let preview = annotations.importPreview,
              preview["imageId"].string == annotations.imageID,
              let fingerprint = preview["previewFingerprint"].string else { return }
        perform("Importing annotation geometry…", refreshOnConflict: false) {
            let result = try await self.call("annotation.import.run", arguments: [
                "imageId": .string(self.annotations.imageID), "path": .string(path),
                "previewFingerprint": .string(fingerprint)
            ], mutation: true)["result"]
            self.annotations.applyRecord(result["annotation"])
            self.annotations.importPath = nil; self.annotations.importPreview = nil
            try await self.inspect()
            try await self.readAnnotations()
            if !self.annotations.sourceCurrent { try await self.readAnnotationSource() }
            self.reportStatus("Imported a new annotation with its source evidence. Existing masks are preserved.")
        }
    }
}
