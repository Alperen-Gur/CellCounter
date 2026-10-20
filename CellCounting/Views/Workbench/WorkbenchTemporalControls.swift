import AppKit
import SwiftUI

struct WorkbenchTemporalControls: View {
    @Bindable var session: WorkbenchSession
    @Bindable var temporal: WorkbenchTemporalState
    @State private var offsetPage = 0
    @State private var ambiguityPage = 0
    private var canOperate: Bool { session.temporalCanOperate }
    private var trackingCurrent: Bool {
        temporal.previewRevision == session.revision && temporal.renderedTrackingArguments == (try? session.temporalTrackingArguments())
    }
    private var propagationCurrent: Bool {
        temporal.propagationRevision == session.revision && temporal.renderedPropagationArguments == (try? session.temporalPropagationArguments())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            DisclosureGroup("Temporal inference") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Link saved observations with drift correction and gap closing. Automatic divisions remain unconfirmed inferences.")
                        .font(.caption).foregroundStyle(.secondary)
                    TextField("Analyzed times (1-based; blank = all)", text: $temporal.selectedTimes)
                    number("Maximum distance per frame", value: $temporal.maximumDistance)
                    Picker("Distance units", selection: $temporal.units) {
                        Text("Voxels").tag("voxel")
                        Text("Micrometres").tag("um")
                    }
                    Stepper("Missing frames allowed: \(temporal.maximumGap)", value: $temporal.maximumGap, in: 0...10)
                    Picker("Drift", selection: $temporal.driftMode) {
                        Text("None").tag("none")
                        Text("Explicit offsets").tag("explicit")
                        Text("Phase correlation").tag("phase-correlation")
                    }
                    if temporal.driftMode == "phase-correlation" {
                        number("Maximum drift (voxels)", value: $temporal.maximumDrift)
                        Text("Bounded source phase correlation estimates translation relative to the first selected frame; it requires acquired support across the full grid.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if temporal.driftMode == "explicit" { offsetControls }
                    Text("Positive drift is sample motion right/down/forward in source XYZ voxel coordinates. Association subtracts this offset before applying distance calibration.")
                        .font(.caption).foregroundStyle(.secondary)
                    Toggle("Infer unambiguous divisions", isOn: $temporal.divisions)
                    if temporal.divisions {
                        number("Minimum daughter / parent volume ratio", value: $temporal.minimumRatio)
                        number("Maximum daughter / parent volume ratio", value: $temporal.maximumRatio)
                        number("Maximum daughter distance (selected units)", value: $temporal.maximumDaughterDistance)
                        number("Required score margin", value: $temporal.ambiguityMargin)
                        Text("Adjacent-frame daughter pairs compete with other pairings and continuation hypotheses. Scores describe geometry, not division probabilities.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Toggle("Replace active graph, retaining its history", isOn: $temporal.replaceGraph)
                    TextField("Reason (optional)", text: $temporal.trackingReason, axis: .vertical)
                    Button("Preview temporal inference", action: session.previewTemporalTracking).disabled(!canOperate)
                    if let preview = temporal.trackPreview {
                        let counts = preview["counts"]
                        Text("\(counts["observations"].integer ?? 0) observations · \(counts["continuations"].integer ?? 0) continuations · \(counts["gaps"].integer ?? 0) gaps")
                            .font(.caption)
                        Text("\(counts["inferredDivisions"].integer ?? 0) inferred divisions · \(counts["ambiguousDivisions"].integer ?? 0) retained ambiguous candidates")
                            .font(.caption)
                        if !trackingCurrent { Text("Settings or source revision changed. Preview again before applying.").font(.caption).foregroundStyle(.orange) }
                        Button("Save inferred lineage", action: session.applyTemporalTracking)
                            .disabled(!canOperate || !trackingCurrent || (preview["replacesGraph"].bool == true && !temporal.replaceGraph))
                        DisclosureGroup("Preview graph and drift") {
                            WorkbenchLineageTimeline(graph: preview["graph"], lineageID: "", selectedNodeID: $temporal.selectedPreviewNode)
                                .frame(height: 220)
                            Text("This preview has not been saved. The graph on the right remains the saved result.").font(.caption).foregroundStyle(.secondary)
                            WorkbenchStructuredOutput(value: preview["drift"])
                        }
                        DisclosureGroup("Ambiguous candidates") {
                            let candidates = preview["ambiguities"].array
                            ForEach(Array(candidates.dropFirst(ambiguityPage * 20).prefix(20).enumerated()), id: \.offset) { _, item in
                                Text("T\((item["parent"]["timeIndex"].integer ?? 0) + 1) #\(item["parent"]["labelId"].integer ?? 0): score \(item["score"].number ?? 0, specifier: "%.3f"), alternative \(item["alternativeScore"].number ?? 0, specifier: "%.3f")")
                                    .font(.caption)
                            }
                            HStack {
                                Button("Previous") { ambiguityPage = max(0, ambiguityPage - 1) }.disabled(ambiguityPage == 0)
                                Button("Next") { ambiguityPage += 1 }.disabled((ambiguityPage + 1) * 20 >= candidates.count)
                            }
                        }
                    }
                }.padding(.top, 6)
            }
            DisclosureGroup("Propagate a mask correction") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Translate one exact saved object to selected times. Existing target masks need named replacement approval; no resegmentation occurs.")
                        .font(.caption).foregroundStyle(.secondary)
                    integer("Source time (1-based)", value: $temporal.sourceTime)
                    integer("Source object", value: $temporal.sourceLabel)
                    Picker("Motion", selection: $temporal.motion) {
                        Text("Source → target centroid").tag("lineage-centroid")
                        Text("Saved drift difference").tag("drift")
                        Text("Explicit voxel shifts").tag("explicit")
                    }
                    Text("Blank target identity follows only consecutive unique continuation links. Specify each target label across a division or missing observation.")
                        .font(.caption).foregroundStyle(.secondary)
                    ForEach($temporal.targets) { $target in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                integer("Time (1-based)", value: $target.time)
                                TextField("Target label or automatic", text: $target.label)
                                Button { temporal.targets.removeAll { $0.id == target.id } } label: { Image(systemName: "minus.circle") }
                                    .accessibilityLabel("Remove propagation target")
                            }
                            TextField("Replace full labels (comma-separated)", text: $target.replacements)
                            if temporal.motion == "explicit" {
                                HStack {
                                    number("X voxels", value: $target.x)
                                    number("Y voxels", value: $target.y)
                                    number("Z voxels", value: $target.z)
                                }
                            }
                            Toggle("Allow clipping outside acquired support", isOn: $target.allowClipping).font(.caption)
                            Toggle("Skip this target", isOn: $target.skip).font(.caption)
                        }.padding(8).background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 7))
                    }
                    Button("Add target time") {
                        temporal.targets.append(WorkbenchTemporalTarget(time: min(session.volume.timeCount, (temporal.targets.last?.time ?? temporal.sourceTime) + 1)))
                    }.disabled(temporal.targets.count >= 32)
                    TextField("Reason for correction or undo", text: $temporal.reason, axis: .vertical)
                    Button("Preview correction group") { session.previewTemporalPropagation() }
                        .disabled(!canOperate || temporal.targets.isEmpty || temporal.reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    if let preview = temporal.propagationPreview {
                        Text("\(preview["readyCount"].integer ?? 0) ready · \(preview["blockedCount"].integer ?? 0) blocked")
                            .font(.caption.bold())
                        if !propagationCurrent { Text("Targets, settings or source revision changed. Preview again before applying.").font(.caption).foregroundStyle(.orange) }
                        ForEach(Array(preview["targets"].array.enumerated()), id: \.offset) { _, target in
                            VStack(alignment: .leading, spacing: 4) {
                                Text("T\((target["timeIndex"].integer ?? 0) + 1) #\(target["labelId"].integer ?? 0) · \(target["status"].string ?? "")").font(.caption.bold())
                                Text("\(target["placedVoxels"].integer ?? 0) placed · \(target["clippedVoxels"].integer ?? 0) clipped voxels").font(.caption)
                                ForEach(Array(target["reasons"].array.enumerated()), id: \.offset) { _, reason in
                                    Text(reason["message"].string ?? "").font(.caption).foregroundStyle(.orange)
                                }
                                if !target["collisionLabelIds"].array.isEmpty {
                                    Text("Colliding labels: " + target["collisionLabelIds"].array.compactMap { $0.integer.map(String.init) }.joined(separator: ", "))
                                        .font(.caption).textSelection(.enabled)
                                }
                                ForEach(Array(target["warnings"].array.enumerated()), id: \.offset) { _, warning in Text(warning.string ?? "").font(.caption).foregroundStyle(.secondary) }
                                if let dataURL = target["overlayDataUrl"].string, let image = image(dataURL) {
                                    Image(nsImage: image).resizable().scaledToFit().frame(maxHeight: 200)
                                    Text("Selected XY slice \((target["previewIndex"].integer ?? 0) + 1); counts cover the full target volume.")
                                        .font(.caption).foregroundStyle(.secondary)
                                } else if target["status"].string != "skipped", let time = target["timeIndex"].integer {
                                    Button("Preview this target slice") { session.previewTemporalPropagation(time: time) }
                                        .disabled(!canOperate || !propagationCurrent)
                                }
                            }
                        }
                        Button("Apply correction group", action: session.applyTemporalPropagation)
                            .disabled(!canOperate || !propagationCurrent || preview["blockedCount"].integer != 0 || (preview["readyCount"].integer ?? 0) == 0)
                    }
                    DisclosureGroup("Correction group history") {
                        Button("Load correction groups", action: session.loadTemporalGroups).disabled(session.busy)
                        ForEach(Array(temporal.groups.enumerated()), id: \.offset) { index, group in
                            Button("Group \(index + 1) · \(group["status"].string ?? "") · \(group["appliedCount"].integer ?? 0) targets") {
                                if let id = group["id"].string { session.loadTemporalGroup(id) }
                            }.disabled(session.busy)
                        }
                        if let group = temporal.selectedGroup {
                            Text(group["reason"].string ?? "").font(.caption)
                            Text("Outputs \(group["outputsCurrent"].bool == true ? "current" : "historical") · \(group["skippedCount"].integer ?? 0) explicitly skipped")
                                .font(.caption)
                            Button("Undo whole group", action: session.undoTemporalGroup)
                                .disabled(!canOperate || group["undoAvailable"].bool != true || temporal.reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            Text("Undo is refused if any target was edited later. Completed history remains retained.").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }.padding(.top, 6)
            }
            if temporal.hasPendingDraft {
                Text("Temporal settings or previews are pending. They are retained while this editor is open.").font(.caption).foregroundStyle(.orange)
                Button("Discard temporal settings and previews") {
                    temporal.reset(imageID: session.volume.imageID, channel: session.volume.channel, time: session.volume.timeIndex,
                                   label: session.volume.selectedLabels.sorted().first ?? 1)
                }.disabled(session.busy)
            }
        }
    }

    private var offsetControls: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Offsets in XYZ voxels; first selected frame is the reference.").font(.caption)
            ForEach(Array(session.temporalTimes.dropFirst(offsetPage * 20).prefix(20)), id: \.self) { time in
                HStack {
                    Text("T\(time + 1)").font(.caption).frame(width: 38)
                    ForEach(0..<3, id: \.self) { axis in
                        TextField(["X", "Y", "Z"][axis], value: Binding(get: { temporal.offsets[time]?[axis] ?? 0 }, set: { value in
                            var values = temporal.offsets[time] ?? [0, 0, 0]; values[axis] = value; temporal.offsets[time] = values
                        }), format: .number).textFieldStyle(.roundedBorder)
                    }
                }
            }
            HStack {
                Button("Previous times") { offsetPage = max(0, offsetPage - 1) }.disabled(offsetPage == 0)
                Button("Next times") { offsetPage += 1 }.disabled((offsetPage + 1) * 20 >= session.temporalTimes.count)
            }
        }
    }
    private func number(_ title: String, value: Binding<Double>) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption); TextField(title, value: value, format: .number).textFieldStyle(.roundedBorder)
        }
    }
    private func integer(_ title: String, value: Binding<Int>) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption); TextField(title, value: value, format: .number).textFieldStyle(.roundedBorder)
        }
    }
    private func image(_ dataURL: String) -> NSImage? {
        guard let comma = dataURL.firstIndex(of: ","), let data = Data(base64Encoded: String(dataURL[dataURL.index(after: comma)...])) else { return nil }
        return NSImage(data: data)
    }
}
