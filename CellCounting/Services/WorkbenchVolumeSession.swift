import Foundation

extension WorkbenchSession {
    private var volumeArguments: [String: WorkbenchJSON] {
        ["imageId": .string(volume.imageID), "timeIndex": .number(Double(volume.timeIndex)),
         "channel": .number(Double(volume.channel))]
    }

    func setVolumeMode(_ enabled: Bool) {
        guard !busy, viewingVolume != enabled else { return }
        viewingVolume = enabled
        perform("Loading image view…") { try await self.loadImage() }
    }

    func loadVolume() async throws {
        guard let image = selectedImage else { return }
        extensions.invalidateResults()
        assays.invalidateResults()
        volume.configure(for: image)
        volume.invalidateDisplay()
        let generation = volume.generation
        let result = try await call("volume.inspect", arguments: ["imageId": .string(image.id)])["result"]
        guard generation == volume.generation, selectedImageID == image.id else { return }
        volume.applyInspection(result)
        volume.restoreAnalysisParameters()
        let args = volumeArguments
        let display = try await call("volume.display", arguments: args.merging([
            "maxDimension": .number(128), "includeLabels": .bool(true)
        ], uniquingKeysWith: { _, new in new }))["result"]
        guard generation == volume.generation, selectedImageID == image.id else { return }
        volume.display = display
        volume.displayedParameters = volume.parameters
        volume.displayedTime = volume.timeIndex
        volume.displayedChannel = volume.channel
        if volume.hasSavedAnalysis {
            try await readMeasurementPage()
            guard generation == volume.generation else { return }
            volume.validSupport = image.validSupport
        }
        try await loadVolumeSlice()
        if volume.tracksStatus != "none" {
            volume.tracks = try await call("tracks.get", arguments: [
                "imageId": .string(image.id), "channel": .number(Double(volume.channel))
            ])["result"]
        }
        reportStatus("Volume loaded. Scientific measurements use the full source volume.")
    }

    func changeVolumeFrame(timeIndex: Int? = nil, channel: Int? = nil) {
        guard !busy else { return }
        if let timeIndex { volume.timeIndex = min(max(0, timeIndex), volume.timeCount - 1) }
        if let channel { volume.channel = min(max(0, channel), volume.channels - 1) }
        perform("Loading volume frame…") { try await self.loadVolume() }
    }

    func changeVolumeSlice(plane: String? = nil, index: Int? = nil) {
        guard !busy else { return }
        if let plane, ["xy", "xz", "yz"].contains(plane) { volume.plane = plane }
        if let index { volume.crosshair[volume.normalAxis] = min(max(0, index), volume.indexCount - 1) }
        volume.polygon = []
        volume.selectedLabels = []
        perform("Loading source plane…") { try await self.loadVolumeSlice() }
    }

    func handleVolumePointer(voxel: [Double], plane: String?, generation: Int) {
        guard !busy, generation == volume.generation, voxel.count == 3,
              voxel.allSatisfy(\.isFinite) else { return }
        let target = zip(voxel, volume.dimensions).map {
            Int(min(max(0, $0.0.rounded()), Double($0.1 - 1)))
        }
        let targetPlane = plane.flatMap { ["xy", "xz", "yz"].contains($0) ? $0 : nil } ?? volume.plane
        guard target != volume.crosshair || targetPlane != volume.plane else { return }
        volume.crosshair = target
        changeVolumeSlice(plane: targetPlane)
    }

    func loadVolumeSlice() async throws {
        volume.sliceImage = nil
        volume.sliceContours = []
        measurementPage.volumeOverlay = nil
        volume.polygon = []
        let generation = volume.generation
        let plane = volume.plane, index = volume.index, time = volume.timeIndex, channel = volume.channel
        var args = volumeArguments
        args["plane"] = .string(plane)
        args["index"] = .number(Double(index))
        args["includeContours"] = .bool(false)
        // No maxSize: the source plane is returned at its original resolution.
        // The runtime caps the entire selected scientific volume at 8M voxels.
        let result = try await call("volume.slice", arguments: args)["result"]
        guard generation == volume.generation, plane == volume.plane, index == volume.index,
              time == volume.timeIndex, channel == volume.channel else { return }
        volume.sliceImage = try decodePreview(result)
        volume.sliceWidth = max(1, result["width"].integer ?? 1)
        volume.sliceHeight = max(1, result["height"].integer ?? 1)
        volume.sliceContours = result["contours"].array.compactMap(WorkbenchSliceContour.init)
        volume.slicePlane = plane; volume.sliceIndex = index
        volume.sliceTime = time; volume.sliceChannel = channel
        if volume.hasSavedAnalysis { try await loadSavedMaskOverlay() }
    }

    func analyzeVolume(previewOnly: Bool) {
        guard !volume.imageID.isEmpty else { return }
        var args = volumeArguments
        args["parameters"] = volume.parameters
        args["cellLimit"] = .number(200)
        if previewOnly {
            perform("Previewing 3D segmentation…") {
                self.volume.invalidateDisplay()
                let response = try await self.call("volume.analysis.preview", arguments: args)["result"]
                self.volume.display = response["display"]
                self.volume.cells = response["cells"].array.compactMap(WorkbenchVolumeCell.init)
                self.measurementPage.total = response["cellCount"].integer ?? self.volume.cells.count
                self.volume.validSupport = response["validSupport"]
                self.volume.displayedParameters = args["parameters"]
                self.volume.displayedTime = args["timeIndex"]?.integer
                self.volume.displayedChannel = args["channel"]?.integer
                self.volume.isPreview = true
                self.reportStatus("Unsaved 3D preview. Run analysis to save labels before correcting them.")
            }
        } else {
            mutateVolume("volume.analysis.run", arguments: args, message: "Analyzing full source volume…",
                         finished: "3D analysis and volumetric measurements saved.")
        }
    }

    func applyVolumeCalibration() {
        let v = volume
        let args: [String: WorkbenchJSON] = [
            "imageId": .string(v.imageID),
            "voxelSizeUm": .object([
                "x": v.knownX ? .number(v.voxelXUm) : .null,
                "y": v.knownY ? .number(v.voxelYUm) : .null,
                "z": v.knownZ ? .number(v.voxelZUm) : .null]),
            "timeStepSeconds": v.knownTime ? .number(v.timeStepSeconds) : .null
        ]
        mutateVolume("volume.calibration.set", arguments: args, message: "Updating voxel calibration…",
                     finished: "Voxel calibration updated. Existing tracks may require recomputation.")
    }

    func editVolume(_ action: String, point: [Double]? = nil) {
        guard volume.canEdit else { return }
        var args = volumeArguments
        args["action"] = .string(action)
        switch action {
        case "polygon":
            guard volume.polygon.count >= 3 else { return }
            args["plane"] = .string(volume.plane)
            args["index"] = .number(Double(volume.index))
            args["polygon"] = .array(volume.polygon.map { .array($0.map(WorkbenchJSON.number)) })
            if volume.polygonReplaceSelected {
                guard volume.selectedLabels.count == 1, let selected = volume.selectedLabels.first else { return }
                args["labelId"] = .number(Double(selected))
            }
        case "brush":
            guard let point, point.count == 2 else { return }
            args["center"] = .array(volume.voxelCenter(u: point[0], v: point[1]).map(WorkbenchJSON.number))
            args["radiusVox"] = .number(volume.brushRadiusVox)
            args["labelId"] = .number(Double(volume.paintLabel))
            args["mode"] = .string(volume.editMode == "erase" ? "erase" : "paint")
        case "delete", "merge":
            guard !volume.selectedLabels.isEmpty else { return }
            args["labelIds"] = .array(volume.selectedLabels.sorted().map { .number(Double($0)) })
        default: return
        }
        mutateVolume("volume.mask.edit", arguments: args, message: "Saving 3D correction…",
                     finished: "3D labels and measurements updated.")
    }

    func undoVolume() {
        guard volume.canEdit else { return }
        mutateVolume("volume.mask.undo", arguments: volumeArguments,
                     message: "Undoing 3D correction…", finished: "3D correction undone.")
    }

    func runVolumeTracks() {
        var args: [String: WorkbenchJSON] = [
            "imageId": .string(volume.imageID), "channel": .number(Double(volume.channel)),
            "maxDistance": .number(volume.trackMaxDistance), "units": .string(volume.trackUnits),
            "maxGapFrames": .number(Double(volume.trackMaxGapFrames))
        ]
        let times = volume.inspection["frames"].array.filter {
            $0["channel"].integer == volume.channel
        }.compactMap { $0["timeIndex"].integer }.sorted()
        args["timeIndices"] = .array(times.map { .number(Double($0)) })
        mutateVolume("tracks.run", arguments: args, message: "Linking objects through time…",
                     finished: "Tracks saved. Inspect links before interpreting motion.")
    }

    func editVolumeTrack(link: Bool) {
        let args: [String: WorkbenchJSON] = [
            "imageId": .string(volume.imageID), "channel": .number(Double(volume.channel)),
            "sourceTimeIndex": .number(Double(volume.trackSourceTime - 1)),
            "sourceLabelId": .number(Double(volume.trackSourceLabel)),
            "targetTimeIndex": .number(Double(volume.trackTargetTime - 1)),
            "targetLabelId": .number(Double(volume.trackTargetLabel))
        ]
        mutateVolume(link ? "tracks.link" : "tracks.unlink", arguments: args,
                     message: "Saving track correction…", finished: "Track correction saved.")
    }

    private func mutateVolume(_ operation: String, arguments: [String: WorkbenchJSON],
                              message: String, finished: String) {
        perform(message) {
            _ = try await self.call(operation, arguments: arguments, mutation: true)
            try await self.inspect()
            try await self.loadVolume()
            self.invalidateSummaries()
            self.reportStatus(finished)
        }
    }
}
