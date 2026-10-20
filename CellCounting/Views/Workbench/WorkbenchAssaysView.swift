import SwiftUI

struct WorkbenchAssaysView: View {
    @Bindable var session: WorkbenchSession
    @Bindable var assays: WorkbenchAssayState
    @Environment(\.dismiss) private var dismiss
    @State private var mode = "image"
    @State private var parameters: [String: WorkbenchJSON] = [:]
    private var selected: WorkbenchAssay? { assays.catalog.first { $0.id == assays.selectedID } }
    private var channelFields: [WorkbenchPluginParameter] {
        selected?.parameters.filter { $0.id == "channel" || $0.id.hasSuffix("_channel") || ["channel_a", "channel_b"].contains($0.id) } ?? []
    }
    private var canRun: Bool {
        guard let selected else { return false }
        return session.selectedImageID != nil && selected.dimensions.contains(session.viewingVolume ? 3 : 2) &&
            (!selected.requiresAnalysis || (session.viewingVolume ? session.volume.hasSavedAnalysis : session.selectedImage?.cellCount != nil)) &&
            !session.hasActiveWorkers && session.canRefreshWithoutDiscardingEdits
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack {
                Text("Measurements and assays").font(.title2)
                WorkbenchSavedRecordAccess(session: session, catalogues: ["assayRuns", "assaySeriesRuns"])
                Spacer()
                Button("Refresh", action: session.loadAssays)
                Button("Done") { dismiss() }
            }.disabled(session.busy)
            Text("Measure saved masks or selected source intensities. Each method states its inputs; historical results remain available when inputs change.")
                .font(.callout).foregroundStyle(.secondary)
            if let error = session.error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            Picker("Measurement scope", selection: $mode) {
                Text("Single acquisition").tag("image")
                Text("Scratch-wound time series").tag("series")
            }.pickerStyle(.segmented)
            if mode == "series" {
                WorkbenchAssaySeriesView(session: session, series: session.assaySeries)
            } else {
            HSplitView {
                ScrollView {
                    VStack(alignment: .leading, spacing: 11) {
                        Picker("Assay", selection: $assays.selectedID) {
                            Text("Select an assay").tag("")
                            ForEach(assays.catalog) { Text($0.name).tag($0.id) }
                        }
                        Text(session.selectedImage?.name ?? "Select an image first.").font(.headline)
                        if session.viewingVolume {
                            Text("3D saved labels · Time \(session.volume.timeIndex + 1) · Segmentation channel \(session.volume.channel + 1)")
                                .font(.caption).foregroundStyle(.secondary)
                        } else if selected?.requiresAnalysis == false {
                            Picker("Source channel", selection: $assays.sourceChannel) {
                                ForEach(0..<max(1, session.selectedImage?.channels ?? 1), id: \.self) { Text("Channel \($0 + 1)").tag($0) }
                            }
                            Picker("Z projection", selection: $assays.sourceProjection) {
                                Text("Maximum").tag("max"); Text("Mean").tag("mean"); Text("Middle plane").tag("middle")
                            }
                            Text("Segmentation is not required. These assay selectors leave the segmentation channel and saved masks unchanged.")
                                .font(.caption).foregroundStyle(.secondary)
                        } else {
                            Text("Saved 2D masks and their saved projection.").font(.caption).foregroundStyle(.secondary)
                        }
                        if let selected {
                            ForEach(selected.notes, id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary) }
                            WorkbenchAssayParameterControls(session: session, assay: selected, values: $parameters)
                            if !selected.dimensions.contains(session.viewingVolume ? 3 : 2) {
                                Text("This assay supports \(selected.dimensions.map { "\($0)D" }.joined(separator: ", ")).")
                                    .font(.caption).foregroundStyle(.orange)
                            }
                        }
                        HStack {
                            Button("Preview") { session.runAssay(parameters: parameters, previewOnly: true) }
                            Button("Run and save") { session.runAssay(parameters: parameters, previewOnly: false) }
                                .buttonStyle(.borderedProminent)
                        }.disabled(!canRun)
                        Divider()
                        Text("Saved results").font(.headline)
                        ForEach(Array(assays.runs.reversed().enumerated()), id: \.offset) { _, run in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(assays.catalog.first { $0.id == run["assay"].string }?.name ?? run["assay"].string ?? "Assay")
                                    .font(.callout.weight(.medium))
                                Text("Revision \(run["revision"].integer ?? 0)\(run["stale"].bool == true ? " · Out of date" : " · Current")")
                                    .font(.caption).foregroundStyle(run["stale"].bool == true ? Color.orange : Color.secondary)
                                if let id = run["runId"].string {
                                    HStack {
                                        Button("Inspect") { session.inspectAssayRun(id) }
                                        Button("Recompute") { session.recomputeAssay(id) }
                                    }
                                }
                            }.padding(.vertical, 4)
                        }
                    }.padding(.trailing, 12)
                }.frame(minWidth: 300, idealWidth: 340).disabled(session.busy)
                VStack(alignment: .leading, spacing: 10) {
                    Text(assays.preview ? "Unsaved preview" : assays.outputStale ? "Historical output — out of date" : "Assay output")
                        .font(.headline)
                    if let output = assays.output {
                        WorkbenchSupportNote(support: output["validSupport"],
                                             volume: output["validSupport"]["shape"].array.count == 3)
                        WorkbenchStructuredOutput(value: output)
                    } else {
                        ContentUnavailableView("Assay results", systemImage: "tablecells",
                            description: Text("Preview an assay or inspect a saved result."))
                    }
                }.frame(minWidth: 430).padding(.leading, 12)
            }
            }
            HStack {
                if session.busy { ProgressView().controlSize(.small) }
                Text(session.status).font(.caption).foregroundStyle(.secondary)
                Spacer()
            }
        }.padding(24).frame(width: 1120, height: 780)
        .task { resetParameters(); session.loadAssays() }
        .onChange(of: assays.selectedID) { _, _ in resetParameters() }
        .onChange(of: assays.catalog.map(\.id)) { _, _ in resetParameters() }
    }
    private func resetParameters() {
        parameters = selected?.initialParameters ?? [:]
        let channels = max(1, session.selectedImage?.channels ?? 1)
        for field in channelFields {
            if let index = parameters[field.id]?.integer { parameters[field.id] = .number(Double(min(channels - 1, index))) }
        }
        assays.sourceChannel = min(channels - 1, assays.sourceChannel)
    }
}

struct WorkbenchAssayParameterControls: View {
    @Bindable var session: WorkbenchSession
    let assay: WorkbenchAssay
    @Binding var values: [String: WorkbenchJSON]
    private var channelFields: [WorkbenchPluginParameter] {
        assay.parameters.filter { $0.id == "channel" || $0.id.hasSuffix("_channel") || ["channel_a", "channel_b"].contains($0.id) }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(channelFields) { field in
                Picker(field.id.replacingOccurrences(of: "_", with: " ").capitalized, selection: Binding(
                    get: { values[field.id]?.integer ?? field.initialValue.integer ?? 0 },
                    set: { values[field.id] = .number(Double($0)) })) {
                    ForEach(0..<(session.selectedImage?.channels ?? 1), id: \.self) { Text("Channel \($0 + 1)").tag($0) }
                }
            }
            WorkbenchPluginParameters(definitions: assay.parameters.filter { parameter in
                !channelFields.contains(where: { $0.id == parameter.id }) && !["nuclearImageId", "somaImageId"].contains(parameter.id)
            }, values: $values)
            if ["nuclear_cytoplasmic", "neurite_outgrowth"].contains(assay.id) {
                let referenceKey = assay.id == "neurite_outgrowth" ? "somaImageId" : "nuclearImageId"
                WorkbenchImageChoice(session: session, selection: Binding(
                    get: { values[referenceKey]?.string ?? "" }, set: { values[referenceKey] = .string($0) }),
                    title: assay.id == "neurite_outgrowth" ? "Soma mask image" : "Nuclear mask image",
                    eligible: { $0.id != session.selectedImageID && $0.parameters?["zProjection"] == session.selectedImage?.parameters?["zProjection"] },
                    filters: ["sourceHash": .string(session.selectedImage?.sourceHash ?? ""), "analysisTarget": .string("plane")])
                Text("Both masks must use the same original acquisition, Z projection, calibration and acquired support. Create an image variant and segment the reference channel separately.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

/// Readable tables and scalar fields for the different scientific assay outputs.
/// Nested results remain inspectable without asking users to interpret JSON.
struct WorkbenchStructuredOutput: View {
    let value: WorkbenchJSON
    var body: some View {
        ScrollView([.horizontal, .vertical]) {
            WorkbenchStructuredFields(value: value).padding(4)
        }.textSelection(.enabled)
    }
}

private struct WorkbenchStructuredFields: View {
    let value: WorkbenchJSON
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(value.object.keys.sorted().filter { $0 != "ok" }, id: \.self) { key in
                let item = value[key]
                if !item.object.isEmpty {
                    DisclosureGroup(key.replacingOccurrences(of: "_", with: " ").capitalized) {
                        WorkbenchStructuredFields(value: item).padding(.leading, 8)
                    }
                } else if !item.array.isEmpty {
                    DisclosureGroup("\(key.replacingOccurrences(of: "_", with: " ").capitalized) (\(item.array.count))") {
                        WorkbenchStructuredRows(rows: item.array).frame(minHeight: 60, maxHeight: 360)
                    }
                } else {
                    HStack(alignment: .top) {
                        Text(key.replacingOccurrences(of: "_", with: " ").capitalized).fontWeight(.medium)
                        Text(workbenchScalarText(item)).foregroundStyle(.secondary)
                    }
                }
            }
        }.font(.caption)
    }
}

private struct WorkbenchStructuredRows: View {
    let rows: [WorkbenchJSON]
    let columns: [String]
    init(rows: [WorkbenchJSON]) {
        self.rows = rows
        columns = Set(rows.flatMap { $0.object.keys }).sorted()
    }
    var body: some View {
        ScrollView([.horizontal, .vertical]) {
            LazyVStack(alignment: .leading, spacing: 5) {
                if !columns.isEmpty {
                    HStack {
                        ForEach(columns, id: \.self) { Text($0).fontWeight(.semibold).frame(width: 125, alignment: .leading) }
                    }
                }
                ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                    if columns.isEmpty {
                        HStack { Text(String(index + 1)).frame(width: 40); Text(workbenchScalarText(row)) }
                    } else {
                        HStack {
                            ForEach(columns, id: \.self) { Text(workbenchScalarText(row[$0])).frame(width: 125, alignment: .leading) }
                        }
                    }
                }
            }.font(.caption.monospacedDigit())
        }
    }
}

func workbenchScalarText(_ value: WorkbenchJSON) -> String {
    switch value {
    case .string(let string): return string
    case .number(let number): return String(format: "%.6g", number)
    case .bool(let flag): return flag ? "Yes" : "No"
    case .null: return "—"
    case .array(let values): return values.map(workbenchScalarText).joined(separator: ", ")
    case .object(let fields): return fields.keys.sorted().map { "\($0): \(workbenchScalarText(fields[$0] ?? .null))" }.joined(separator: "; ")
    }
}
