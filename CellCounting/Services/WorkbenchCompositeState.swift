import AppKit
import Observation

nonisolated struct WorkbenchCompositeChannel: Identifiable, Equatable {
    let id = UUID()
    var channel: Int
    var color: String
    var enabled = true
    var lower = ""
    var upper = ""
    var gamma = 1.0
    var opacity = 1.0

    var automatic: Bool { lower.trimmingCharacters(in: .whitespaces).isEmpty && upper.trimmingCharacters(in: .whitespaces).isEmpty }
    var valid: Bool {
        let colorValid = color.count == 7 && color.hasPrefix("#") && UInt32(color.dropFirst(), radix: 16) != nil
        let boundsValid = automatic || (Double(lower).map { $0.isFinite } == true &&
            Double(upper).map { $0.isFinite } == true && (Double(lower) ?? 0) < (Double(upper) ?? 0))
        return colorValid && boundsValid && gamma.isFinite && gamma >= 0.05 && gamma <= 20 &&
            opacity.isFinite && opacity >= 0 && opacity <= 1
    }
    var json: WorkbenchJSON {
        var value: [String: WorkbenchJSON] = [
            "channel": .number(Double(channel)), "color": .string(color.uppercased()), "enabled": .bool(enabled),
            "gamma": .number(gamma), "opacity": .number(opacity)
        ]
        if !automatic, let lower = Double(lower), let upper = Double(upper) {
            value["lower"] = .number(lower); value["upper"] = .number(upper)
        }
        return .object(value)
    }
}

extension WorkbenchCompositeChannel {
    init?(_ value: WorkbenchJSON) {
        guard let channel = value["channel"].integer, channel >= 0,
              let color = value["color"].string else { return nil }
        self.init(channel: channel, color: color)
        enabled = value["enabled"].bool ?? true
        lower = value["lower"].number.map { String($0) } ?? ""
        upper = value["upper"].number.map { String($0) } ?? ""
        gamma = value["gamma"].number ?? 1
        opacity = value["opacity"].number ?? 1
        guard valid else { return nil }
    }
}

@MainActor @Observable
final class WorkbenchCompositeState {
    var imageID = ""
    var channels: [WorkbenchCompositeChannel] = []
    var enabled = false
    var preview: NSImage?
    var rendered: WorkbenchJSON?
    var renderedArguments: WorkbenchJSON?
    var renderedSourceHash = ""
    var renderedRevision: Int?
    var volumeEnabled = false
    var volumeDescriptor: WorkbenchJSON?
    var volumeArguments: WorkbenchJSON?
    var volumeRevision: Int?
    var volumeRenderID = UUID().uuidString
    var volumeMaximumDimension = 128
    var maximumSize = 1024
    var notes: [String] = []
    var exportFormats: [WorkbenchImageExportFormat] = []
    var exportResult: WorkbenchJSON?
    let presets = WorkbenchDisplayPresetState()
    var presetReference: WorkbenchJSON?
    var presetResolvedSettings: WorkbenchJSON?
    private struct Draft {
        let channels: [WorkbenchCompositeChannel]
        let maximumSize: Int
        let volumeMaximumDimension: Int
    }
    private var drafts: [String: Draft] = [:]
    static let colors = ["#FF0000", "#00FF00", "#0000FF", "#FF00FF", "#00FFFF", "#FFFF00", "#FFFFFF", "#FF8800"]

    var valid: Bool {
        !channels.isEmpty && channels.count <= 8 && channels.contains(where: \.enabled) &&
            channels.allSatisfy(\.valid) && Set(channels.map(\.channel)).count == channels.count &&
            (64...2048).contains(maximumSize) && (16...128).contains(volumeMaximumDimension)
    }
    var channelArguments: WorkbenchJSON { .array(channels.map(\.json)) }
    var hasDraftChanges: Bool {
        renderedArguments?["channels"] != channelArguments ||
            renderedArguments?["maxSize"].integer != maximumSize
    }
    var volumeHasDraftChanges: Bool {
        volumeArguments?["channels"] != channelArguments ||
            volumeArguments?["maxDimension"].integer != volumeMaximumDimension
    }
    var activePresetReference: WorkbenchJSON? {
        guard let settings = presetResolvedSettings,
              settings["channels"] == channelArguments,
              settings["maxSize"].integer == maximumSize,
              settings["maxDimension"].integer == volumeMaximumDimension else { return nil }
        return presetReference
    }
    func invalidateEditedPresetReference() {
        if activePresetReference == nil { presetReference = nil; presetResolvedSettings = nil }
    }

    func configure(for image: WorkbenchImage?) {
        guard let image else { return }
        guard imageID != image.id else { return }
        if !imageID.isEmpty {
            drafts[imageID] = Draft(channels: channels, maximumSize: maximumSize,
                                   volumeMaximumDimension: volumeMaximumDimension)
        }
        imageID = image.id
        channels = drafts[image.id]?.channels ?? (0..<min(3, image.channels)).map {
            WorkbenchCompositeChannel(channel: $0, color: image.channels == 1 ? "#FFFFFF" : Self.colors[$0])
        }
        maximumSize = drafts[image.id]?.maximumSize ?? 1024
        volumeMaximumDimension = drafts[image.id]?.volumeMaximumDimension ?? 128
        enabled = false
        volumeEnabled = false
        presetReference = nil; presetResolvedSettings = nil
        presets.resetMapping(channelCount: image.channels)
    }
    func reset() {
        imageID = ""; channels = []; drafts = [:]; enabled = false
        preview = nil; rendered = nil; renderedArguments = nil; renderedSourceHash = ""; renderedRevision = nil
        volumeEnabled = false; volumeDescriptor = nil; volumeArguments = nil; volumeRevision = nil
        volumeRenderID = UUID().uuidString
        notes = []; exportFormats = []; exportResult = nil
        presetReference = nil; presetResolvedSettings = nil; presets.reset()
    }
}

extension WorkbenchSession {
    var compositeLocation: [String: WorkbenchJSON] {
        var value: [String: WorkbenchJSON] = [
            "imageId": .string(selectedImageID ?? ""), "target": .string(viewingVolume ? "volume" : "plane")
        ]
        if viewingVolume {
            value["timeIndex"] = .number(Double(volume.timeIndex))
            value["plane"] = .string(volume.plane)
            value["index"] = .number(Double(volume.index))
        } else { value["sourceParameters"] = .object(["zProjection": .string(projection)]) }
        return value
    }
    var compositeArguments: [String: WorkbenchJSON] {
        var value = compositeLocation
        value["channels"] = composite.channelArguments
        value["maxSize"] = .number(Double(composite.maximumSize))
        if let preset = composite.activePresetReference { value["presetRef"] = preset }
        return value
    }
    var compositeLocationCurrent: Bool {
        guard let arguments = composite.renderedArguments?.object,
              selectedImage?.sourceHash == composite.renderedSourceHash else { return false }
        return compositeLocation.allSatisfy { arguments[$0.key] == $0.value } &&
            arguments["target"] == compositeLocation["target"]
    }
    var displayedComposite: NSImage? {
        composite.enabled && compositeLocationCurrent ? composite.preview : nil
    }
    var canExportComposite: Bool {
        composite.preview != nil && compositeLocationCurrent && !composite.hasDraftChanges &&
            composite.renderedRevision == revision && !hasActiveWorkers && canRefreshWithoutDiscardingEdits
    }

    var volumeCompositeCurrent: Bool {
        guard viewingVolume, let image = selectedImage, volume.imageID == image.id,
              let display = composite.volumeDescriptor,
              let arguments = composite.volumeArguments, composite.volumeRevision == revision,
              display["imageId"].string == image.id, display["sourceHash"].string == image.sourceHash,
              arguments["timeIndex"].integer == volume.timeIndex,
              arguments["labelChannel"].integer == volume.channel,
              !volume.isPreview, !volume.parametersChanged else { return false }
        let frame = volume.inspection["frames"].array.first {
            $0["timeIndex"].integer == volume.timeIndex && $0["channel"].integer == volume.channel
        }
        if display["labelStatus"].string == "current" {
            guard let frame else { return false }
            let source = display["labelSource"]
            return source["analysisRevision"] == frame["analysisRevision"] &&
                source["measurementRevision"] == frame["measurementRevision"] &&
                source["inputFingerprint"] == frame["inputFingerprint"]
        }
        return display["labelStatus"].string == "absent" && frame == nil
    }
    var displayedVolumeComposite: WorkbenchJSON? {
        composite.volumeEnabled && volumeCompositeCurrent ? composite.volumeDescriptor : nil
    }

    func renderVolumeComposite() {
        composite.configure(for: selectedImage)
        guard viewingVolume, let image = selectedImage, volume.imageID == image.id,
              composite.valid, !volume.isPreview, !volume.parametersChanged else { return }
        var arguments: [String: WorkbenchJSON] = [
            "imageId": .string(image.id), "timeIndex": .number(Double(volume.timeIndex)),
            "channels": composite.channelArguments,
            "maxDimension": .number(Double(composite.volumeMaximumDimension)),
            "labelChannel": .number(Double(volume.channel))
        ]
        if let preset = composite.activePresetReference { arguments["presetRef"] = preset }
        let sourceHash = image.sourceHash
        let dimensions = [image.width, image.height, image.zCount]
        perform("Rendering 3D channel composite…", refreshOnConflict: false) {
            let response = try await self.call("image.composite.volume", arguments: arguments)
            let display = response["result"]
            guard display["displayKind"].string == "composite", display["components"].integer == 4,
                  display["componentOrder"].string == "rgba", display["sourceHash"].string == sourceHash,
                  display["originalDimensions"].array.compactMap(\.integer) == dimensions,
                  display["timeIndex"].integer == arguments["timeIndex"]?.integer,
                  display["labelChannel"].integer == arguments["labelChannel"]?.integer else {
                throw WorkbenchFailure(code: "invalid-response",
                    message: "The 3D composite source or coordinate grid does not match the selected volume. Render again before displaying it.")
            }
            self.composite.volumeDescriptor = display
            self.composite.volumeArguments = .object(arguments)
            self.composite.volumeRevision = response["revision"].integer ?? self.revision
            self.composite.volumeRenderID = UUID().uuidString
            self.composite.volumeEnabled = true
            self.reportStatus("3D composite rendered. Scientific measurements still use analysis channel \(self.volume.channel + 1).")
        }
    }

    func previewComposite() {
        composite.configure(for: selectedImage)
        guard let image = selectedImage, composite.valid else { return }
        if !viewingVolume && image.timeCount > 1 {
            error = "Use Volume and time to select an explicit time point for the composite."
            return
        }
        let arguments = compositeArguments
        let sourceHash = image.sourceHash
        let expectedWidth = viewingVolume && volume.plane == "yz" ? image.height : image.width
        let expectedHeight = viewingVolume && volume.plane != "xy" ? image.zCount : image.height
        perform("Rendering channel composite…", refreshOnConflict: false) {
            let response = try await self.call("image.composite.preview", arguments: arguments)
            let result = response["result"]
            guard result["sourceHash"].string == sourceHash,
                  result["width"].integer == expectedWidth, result["height"].integer == expectedHeight else {
                throw WorkbenchFailure(code: "invalid-response",
                    message: "The composite coordinate grid does not match the selected source plane. Preview again before displaying it.")
            }
            let preview = try self.decodePreview(result)
            self.composite.preview = preview
            self.composite.rendered = result
            self.composite.renderedArguments = .object(arguments)
            self.composite.renderedSourceHash = sourceHash
            self.composite.renderedRevision = response["revision"].integer ?? self.revision
            self.composite.enabled = true
            self.composite.notes = result["notes"].array.compactMap(\.string)
            if self.composite.exportFormats.isEmpty {
                self.composite.exportFormats = try await self.call("image.composite.export.catalogue")["result"]["formats"].array
                    .compactMap(WorkbenchImageExportFormat.init)
            }
            self.reportStatus("Composite rendered. Analysis channels, labels and measurements are unchanged.")
        }
    }

    func exportComposite(to destination: URL) {
        guard canExportComposite, var arguments = composite.renderedArguments?.object else { return }
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            error = "Choose a new filename. Composite exports preserve existing files."
            return
        }
        arguments["format"] = .string("composite-png")
        arguments["destination"] = .string(destination.path)
        perform("Exporting rendered channel composite…", refreshOnConflict: false) {
            self.composite.exportResult = try await self.call("image.composite.export", arguments: arguments, mutation: true)["result"]
            try await self.inspect()
            self.reportStatus("Composite display exported to \(destination.lastPathComponent).")
        }
    }
}
