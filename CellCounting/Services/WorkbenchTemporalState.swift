import Foundation
import Observation

struct WorkbenchTemporalTarget: Identifiable {
    let id = UUID()
    var time = 2
    var label = ""
    var replacements = ""
    var x = 0.0
    var y = 0.0
    var z = 0.0
    var allowClipping = false
    var skip = false
}

@MainActor @Observable
final class WorkbenchTemporalState {
    var imageID = ""
    var channel = 0
    var maximumDistance = 20.0
    var units = "voxel"
    var maximumGap = 0
    var selectedTimes = ""
    var driftMode = "none"
    var maximumDrift = 64.0
    var offsets: [Int: [Double]] = [:]
    var divisions = false
    var minimumRatio = 0.5
    var maximumRatio = 2.0
    var maximumDaughterDistance = 20.0
    var ambiguityMargin = 0.15
    var replaceGraph = false
    var trackingReason = ""
    var trackPreview: WorkbenchJSON?
    var renderedTrackingArguments: [String: WorkbenchJSON]?
    var previewRevision: Int?
    var selectedPreviewNode = ""
    var sourceTime = 1
    var sourceLabel = 1
    var motion = "lineage-centroid"
    var targets: [WorkbenchTemporalTarget] = []
    var reason = ""
    var propagationPreview: WorkbenchJSON?
    var renderedPropagationArguments: [String: WorkbenchJSON]?
    var propagationRevision: Int?
    var previewTargetTime: Int?
    var groups: [WorkbenchJSON] = []
    var selectedGroup: WorkbenchJSON?
    var initialDraft: WorkbenchJSON?

    var draft: WorkbenchJSON {
        .object(["maximumDistance": .number(maximumDistance), "units": .string(units),
            "maximumGap": .number(Double(maximumGap)), "times": .string(selectedTimes),
            "driftMode": .string(driftMode), "maximumDrift": .number(maximumDrift),
            "offsets": .object(Dictionary(uniqueKeysWithValues: offsets.map { (String($0.key), .array($0.value.map(WorkbenchJSON.number))) })),
            "divisions": .bool(divisions), "minimumRatio": .number(minimumRatio), "maximumRatio": .number(maximumRatio),
            "maximumDaughterDistance": .number(maximumDaughterDistance), "ambiguityMargin": .number(ambiguityMargin),
            "replaceGraph": .bool(replaceGraph), "trackingReason": .string(trackingReason),
            "sourceTime": .number(Double(sourceTime)), "sourceLabel": .number(Double(sourceLabel)),
            "motion": .string(motion), "reason": .string(reason), "targets": .array(targets.map { target in
                .object(["time": .number(Double(target.time)), "label": .string(target.label),
                    "replacements": .string(target.replacements), "x": .number(target.x), "y": .number(target.y), "z": .number(target.z),
                    "allowClipping": .bool(target.allowClipping), "skip": .bool(target.skip)])
            })])
    }
    var hasPendingDraft: Bool { initialDraft != nil && initialDraft != draft || trackPreview != nil || propagationPreview != nil }
    func acceptDraft() { initialDraft = draft }
    func reset(imageID: String = "", channel: Int = 0, time: Int = 0, label: Int = 1) {
        self.imageID = imageID; self.channel = channel
        maximumDistance = 20; units = "voxel"; maximumGap = 0; selectedTimes = ""
        driftMode = "none"; maximumDrift = 64; offsets = [:]; divisions = false
        minimumRatio = 0.5; maximumRatio = 2; maximumDaughterDistance = 20; ambiguityMargin = 0.15
        replaceGraph = false; trackingReason = ""; trackPreview = nil; renderedTrackingArguments = nil
        previewRevision = nil; selectedPreviewNode = ""
        sourceTime = time + 1; sourceLabel = label; motion = "lineage-centroid"; targets = []; reason = ""
        propagationPreview = nil; renderedPropagationArguments = nil; propagationRevision = nil; previewTargetTime = nil
        groups = []; selectedGroup = nil; initialDraft = draft
    }
}

extension WorkbenchSession {
    var temporalCanOperate: Bool {
        !busy && !hasActiveWorkers && !volume.parametersChanged && !volume.isPreview && volume.polygon.isEmpty &&
            volume.editMode == "select" && !lineage.hasUnsavedCorrection &&
            !(annotations.editorOpen && annotations.dirty) && !(layeredWorkspace.editorOpen && layeredWorkspace.dirty)
    }
    var temporalTimes: [Int] {
        volume.inspection["frames"].array.filter { $0["channel"].integer == volume.channel }
            .compactMap { $0["timeIndex"].integer }.sorted()
    }
    func prepareTemporalControls() {
        if temporal.imageID != volume.imageID || temporal.channel != volume.channel {
            temporal.reset(imageID: volume.imageID, channel: volume.channel, time: volume.timeIndex,
                           label: volume.selectedLabels.sorted().first ?? 1)
        }
    }
    func temporalTrackingArguments() throws -> [String: WorkbenchJSON] {
        let times: [Int]
        if temporal.selectedTimes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { times = temporalTimes }
        else { times = try temporalIntegerList(temporal.selectedTimes, title: "Times", minimum: 1).map { $0 - 1 } }
        guard times.count >= 2, Set(times).count == times.count else {
            throw WorkbenchFailure(code: "invalid-time-selection", message: "Choose at least two distinct analyzed time points.")
        }
        var drift: [String: WorkbenchJSON] = ["mode": .string(temporal.driftMode)]
        if temporal.driftMode == "phase-correlation" { drift["maxShiftVox"] = .number(temporal.maximumDrift) }
        if temporal.driftMode == "explicit" {
            drift["offsets"] = .array(times.map { time in
                let values = temporal.offsets[time] ?? [0, 0, 0]
                return .object(["timeIndex": .number(Double(time)), "x": .number(values[0]),
                                "y": .number(values[1]), "z": .number(values[2])])
            })
        }
        var args: [String: WorkbenchJSON] = ["imageId": .string(volume.imageID), "channel": .number(Double(volume.channel)),
            "timeIndices": .array(times.map { .number(Double($0)) }), "maxDistancePerFrame": .number(temporal.maximumDistance),
            "units": .string(temporal.units), "maxGapFrames": .number(Double(temporal.maximumGap)), "drift": .object(drift),
            "division": .object(["enabled": .bool(temporal.divisions), "minCombinedVolumeRatio": .number(temporal.minimumRatio),
                "maxCombinedVolumeRatio": .number(temporal.maximumRatio), "maxDaughterDistance": .number(temporal.maximumDaughterDistance),
                "ambiguityMargin": .number(temporal.ambiguityMargin)]), "replaceGraph": .bool(temporal.replaceGraph)]
        let reason = temporal.trackingReason.trimmingCharacters(in: .whitespacesAndNewlines)
        if !reason.isEmpty { args["reason"] = .string(reason) }
        return args
    }
    func previewTemporalTracking() {
        guard temporalCanOperate else { return }
        do {
            let args = try temporalTrackingArguments()
            perform("Previewing temporal inference…", refreshOnConflict: false) {
                self.temporal.trackPreview = try await self.call("temporal.track.preview", arguments: args)["result"]
                self.temporal.renderedTrackingArguments = args; self.temporal.previewRevision = self.revision
                self.reportStatus("Temporal inference preview ready. Inferred divisions remain unconfirmed.")
            }
        } catch { self.error = error.localizedDescription }
    }
    func applyTemporalTracking() {
        guard temporalCanOperate, temporal.previewRevision == revision,
              let preview = temporal.trackPreview, let fingerprint = preview["previewFingerprint"].string,
              var args = temporal.renderedTrackingArguments else { return }
        do {
            guard args == (try temporalTrackingArguments()) else {
                throw WorkbenchFailure(code: "preview-expired", message: "Tracking settings changed. Preview again before applying.")
            }
            args["previewFingerprint"] = .string(fingerprint)
            perform("Saving inferred lineage…", refreshOnConflict: false) {
                let result = try await self.call("temporal.track.run", arguments: args, mutation: true)["result"]
                try await self.inspect()
                self.lineage.apply(result["graph"], acceptsDraft: true)
                self.temporal.trackPreview = nil; self.temporal.renderedTrackingArguments = nil
                self.temporal.acceptDraft(); self.invalidateSummaries()
                self.reportStatus("Inferred lineage saved with exact inputs, drift and ambiguity records. Masks are unchanged.")
            }
        } catch { self.error = error.localizedDescription }
    }
    func temporalPropagationArguments() throws -> [String: WorkbenchJSON] {
        let targets: [WorkbenchJSON] = try temporal.targets.map { target in
            var value: [String: WorkbenchJSON] = ["timeIndex": .number(Double(target.time - 1)),
                "replaceLabelIds": .array(try temporalIntegerList(target.replacements, title: "Replacement labels", minimum: 1).map { .number(Double($0)) }),
                "allowClipping": .bool(target.allowClipping), "skip": .bool(target.skip)]
            if !target.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                guard let label = Int(target.label), label > 0 else {
                    throw WorkbenchFailure(code: "invalid-label", message: "Target labels must be positive integers, or blank for a consecutive unique lineage identity.")
                }
                value["labelId"] = .number(Double(label))
            }
            if temporal.motion == "explicit" { value["shiftVox"] = .object(["x": .number(target.x), "y": .number(target.y), "z": .number(target.z)]) }
            return .object(value)
        }
        return ["imageId": .string(volume.imageID), "channel": .number(Double(volume.channel)),
            "sourceTimeIndex": .number(Double(temporal.sourceTime - 1)), "sourceLabelId": .number(Double(temporal.sourceLabel)),
            "motion": .string(temporal.motion), "targets": .array(targets), "reason": .string(temporal.reason)]
    }
    func previewTemporalPropagation(time: Int? = nil) {
        guard temporalCanOperate else { return }
        do {
            var args = try temporalPropagationArguments()
            let scientific = args
            if let time { args["previewTimeIndex"] = .number(Double(time)) }
            args["maxSize"] = .number(768)
            perform("Previewing temporal corrections…", refreshOnConflict: false) {
                self.temporal.propagationPreview = try await self.call("temporal.propagate.preview", arguments: args)["result"]
                self.temporal.renderedPropagationArguments = scientific; self.temporal.propagationRevision = self.revision
                self.temporal.previewTargetTime = time
                self.reportStatus("Correction preview ready. Resolve collisions and clipping before applying the group.")
            }
        } catch { self.error = error.localizedDescription }
    }
    func applyTemporalPropagation() {
        guard temporalCanOperate, temporal.propagationRevision == revision,
              let preview = temporal.propagationPreview, preview["blockedCount"].integer == 0,
              (preview["readyCount"].integer ?? 0) > 0, let fingerprint = preview["previewFingerprint"].string,
              var args = temporal.renderedPropagationArguments else { return }
        do {
            guard args == (try temporalPropagationArguments()) else {
                throw WorkbenchFailure(code: "preview-expired", message: "Correction settings changed. Preview again before applying.")
            }
            args["previewFingerprint"] = .string(fingerprint)
            perform("Applying temporal correction group…", refreshOnConflict: false) {
                self.temporal.selectedGroup = try await self.call("temporal.propagate.run", arguments: args, mutation: true)["result"]["propagation"]
                try await self.inspect(); try await self.loadVolume()
                self.lineage.apply(try await self.call("lineage.get", arguments: ["imageId": .string(self.volume.imageID), "channel": .number(Double(self.volume.channel))])["result"])
                self.temporal.propagationPreview = nil; self.temporal.renderedPropagationArguments = nil
                self.temporal.trackPreview = nil; self.temporal.renderedTrackingArguments = nil
                self.temporal.acceptDraft(); self.invalidateSummaries()
                try await self.readTemporalGroups()
                self.reportStatus("Temporal corrections saved as one undoable group. Previous graph outputs are historical.")
            }
        } catch { self.error = error.localizedDescription }
    }
    func loadTemporalGroups() {
        guard !busy else { return }
        perform("Loading temporal correction history…", refreshOnConflict: false) { try await self.readTemporalGroups() }
    }
    private func readTemporalGroups() async throws {
        temporal.groups = try await call("temporal.propagate.list", arguments: ["imageId": .string(volume.imageID)])["result"]["propagations"].array
    }
    func loadTemporalGroup(_ id: String) {
        perform("Loading retained correction group…", refreshOnConflict: false) {
            self.temporal.selectedGroup = try await self.call("temporal.propagate.get", arguments: ["imageId": .string(self.volume.imageID), "propagationId": .string(id)])["result"]["propagation"]
        }
    }
    func undoTemporalGroup() {
        guard temporalCanOperate, let group = temporal.selectedGroup, group["undoAvailable"].bool == true,
              let id = group["id"].string, !temporal.reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        perform("Restoring correction group inputs…", refreshOnConflict: false) {
            self.temporal.selectedGroup = try await self.call("temporal.propagate.undo", arguments: ["imageId": .string(self.volume.imageID),
                "propagationId": .string(id), "reason": .string(self.temporal.reason)], mutation: true)["result"]["propagation"]
            try await self.inspect(); try await self.loadVolume(); try await self.readTemporalGroups()
            self.temporal.propagationPreview = nil; self.temporal.trackPreview = nil; self.temporal.acceptDraft()
            self.lineage.apply(try await self.call("lineage.get", arguments: ["imageId": .string(self.volume.imageID), "channel": .number(Double(self.volume.channel))])["result"])
            self.reportStatus("Correction group restored. Later conflicting target edits would block this undo.")
        }
    }
    private func temporalIntegerList(_ text: String, title: String, minimum: Int) throws -> [Int] {
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return [] }
        return try text.split(whereSeparator: { $0 == "," || $0.isWhitespace }).map { token in
            guard let value = Int(token), value >= minimum else {
                throw WorkbenchFailure(code: "invalid-list", message: "\(title) must be a comma-separated list of integers at least \(minimum).")
            }
            return value
        }
    }
}
