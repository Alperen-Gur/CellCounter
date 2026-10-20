import AppKit
import Charts
import SwiftUI
import UniformTypeIdentifiers

struct WorkbenchAssaySeriesView: View {
    @Bindable var session: WorkbenchSession
    @Bindable var series: WorkbenchAssaySeriesState
    @State private var outputMetric = "gapAreaPx"
    private var canMutate: Bool { !session.hasActiveWorkers && session.canRefreshWithoutDiscardingEdits }
    var body: some View {
        HSplitView {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    TextField("Series name", text: $series.name).textFieldStyle(.roundedBorder)
                    Text("Ordered observations").font(.headline)
                    Text("Choose exact acquisitions and timestamps in seconds. Unknown times and missing observations remain explicit. Images must show the same aligned field; this assay does not register them.")
                        .font(.caption).foregroundStyle(.secondary)
                    ForEach($series.frames) { $frame in
                        frameEditor($frame)
                    }
                    HStack {
                        Button("Add acquisition") { series.add(image: session.selectedImage) }
                        Button("Add missing observation") { series.add(image: nil, missing: true) }
                    }.disabled(series.frames.count >= 128)
                    Text("\(series.frames.count) of 128 observations · Up to 4 million pixels per selected region and 64 million in total.")
                        .font(.caption).foregroundStyle(.secondary)
                    if !series.frames.isEmpty {
                        Picker("Closure baseline", selection: $series.baselineID) {
                            ForEach(Array(series.frames.enumerated()), id: \.element.id) { index, frame in
                                Text("Observation \(index + 1)\(frame.missing ? " · Missing" : "")").tag(Optional(frame.id))
                            }
                        }
                    }
                    DisclosureGroup("Scratch-wound measurement settings") {
                        WorkbenchPluginParameters(definitions: series.parameterFields, values: $series.parameters)
                    }
                    HStack {
                        Button("Preview series", action: session.previewAssaySeries).disabled(!series.complete || !canMutate)
                        Button(series.recomputeRunID == nil ? "Save reviewed series" : "Save replacement series", action: session.saveAssaySeriesPreview)
                            .buttonStyle(.borderedProminent).disabled(!series.previewCurrent(session.revision) || !canMutate)
                    }
                    if series.output != nil && series.selectedRun == nil && !series.previewCurrent(session.revision) {
                        Text("Settings or project inputs changed. Preview again before saving.").font(.caption).foregroundStyle(.orange)
                    }
                    Divider()
                    Text("Retained series").font(.headline)
                    ForEach(Array(series.runs.reversed().enumerated()), id: \.offset) { _, run in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(run["name"].string ?? "Scratch-wound series").font(.callout.weight(.medium))
                            Text("\(run["frameCount"].integer ?? 0) observations · \(run["outputsCurrent"].bool == true ? "Current inputs" : "Inputs changed")")
                                .font(.caption).foregroundStyle(run["outputsCurrent"].bool == true ? Color.secondary : Color.orange)
                            if let id = run["runId"].string {
                                HStack {
                                    Button("Inspect") { session.readAssaySeries(id) }
                                    Button("Preview recomputation") { session.previewAssaySeriesReplacement(id) }.disabled(!canMutate)
                                }
                            }
                        }
                    }
                }.padding(.trailing, 12)
            }.frame(minWidth: 350, idealWidth: 400, maxWidth: 450).disabled(session.busy)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let output = series.output { outputView(output) }
                    else { ContentUnavailableView("Scratch-wound series", systemImage: "chart.xyaxis.line", description: Text("Add at least two ordered observations, choose a baseline, and preview their common acquired region.")) }
                }.padding(.leading, 12)
            }.frame(minWidth: 450)
        }
    }
    private func frameEditor(_ binding: Binding<WorkbenchSeriesFrame>) -> some View {
        let frame = binding.wrappedValue
        let index = series.frames.firstIndex { $0.id == frame.id } ?? 0
        let image = session.images.first { $0.id == frame.imageID }
        return GroupBox("Observation \(index + 1)") {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Button("Move up") { series.frames.swapAt(index, index - 1) }.disabled(index == 0)
                    Button("Move down") { series.frames.swapAt(index, index + 1) }.disabled(index + 1 >= series.frames.count)
                    Spacer()
                    Button("Remove", role: .destructive) {
                        series.frames.removeAll { $0.id == frame.id }
                        if series.baselineID == frame.id { series.baselineID = series.frames.first?.id }
                    }
                }.controlSize(.small)
                Toggle("Known timestamp", isOn: binding.timeKnown)
                if frame.timeKnown { TextField("Time (seconds)", value: binding.seconds, format: .number).textFieldStyle(.roundedBorder) }
                else { Text("Time is unknown; this observation is omitted from rate fits.").font(.caption).foregroundStyle(.secondary) }
                if frame.missing {
                    TextField("Reason this observation is missing", text: binding.missingReason, axis: .vertical).textFieldStyle(.roundedBorder)
                } else {
                    WorkbenchImageChoice(session: session, selection: binding.imageID, title: "Acquisition")
                    HStack {
                        Picker("Channel", selection: binding.channel) { ForEach(0..<max(1, image?.channels ?? 1), id: \.self) { Text("\($0 + 1)").tag($0) } }
                        TextField("Source time index (0-based)", value: binding.timeIndex, format: .number).textFieldStyle(.roundedBorder)
                    }
                    Picker("Z projection", selection: binding.projection) { Text("Maximum").tag("max"); Text("Mean").tag("mean"); Text("Middle plane").tag("middle") }
                    Toggle("Select a source region", isOn: binding.crop)
                    if frame.crop {
                        HStack { integer("X (pixels)", binding.x); integer("Y (pixels)", binding.y) }
                        HStack { integer("Width (pixels)", binding.width); integer("Height (pixels)", binding.height) }
                    }
                    Text("Region coordinates use source pixel edges. Every measured frame must select the same grid and region.").font(.caption).foregroundStyle(.secondary)
                }
            }.padding(5)
        }
    }
    private func integer(_ label: String, _ value: Binding<Int>) -> some View {
        VStack(alignment: .leading) { Text(label).font(.caption); TextField(label, value: value, format: .number).textFieldStyle(.roundedBorder) }
    }
    @ViewBuilder private func outputView(_ output: WorkbenchJSON) -> some View {
        Text(series.selectedRun == nil ? "Unsaved series preview" : "Retained series").font(.headline)
        if series.selectedRun?["outputsCurrent"].bool == false { Text("Historical inputs changed. The retained measurements are preserved; preview recomputation to append a replacement.").font(.caption).foregroundStyle(.orange) }
        let support = output["commonSupport"]
        let region = support["sourceRegion"]
        Text("Common measured region: X \(region["x"].integer ?? 0), Y \(region["y"].integer ?? 0), \(region["width"].integer ?? 0) × \(region["height"].integer ?? 0) source pixels.")
            .font(.callout)
        Text("\(support["samples"].integer ?? 0) acquired samples in every measured observation · \(((support["fraction"].number ?? 0) * 100).formatted(.number.precision(.fractionLength(1))))% of the requested region. Excluded acquired coverage is listed for each observation.")
            .font(.caption).foregroundStyle(.secondary)
        let eligible = output["specimen"]["inferentiallyEligible"].bool == true
        Text(eligible ? "One coherent biological specimen · One repeated-measure series." : "Descriptive series only · Specimen assignment is unassigned, mixed, incomplete or excluded.")
            .font(.caption).foregroundStyle(eligible ? Color.secondary : Color.orange)
        Picker("Plot", selection: $outputMetric) {
            Text("Gap area (pixels²)").tag("gapAreaPx")
            Text("Gap area (µm²)").tag("gapAreaUm2")
            Text("Normalized closure (fraction)").tag("closureFraction")
        }
        Chart(Array(output["frames"].array.enumerated()), id: \.offset) { _, row in
            if let time = row["timeSeconds"].number, let value = row[outputMetric].number {
                PointMark(x: .value("Time (seconds)", time), y: .value(metricTitle, value))
                    .accessibilityLabel("Observation \((row["index"].integer ?? 0) + 1)")
            }
        }.chartXAxisLabel("Time (seconds)").chartYAxisLabel(metricTitle).frame(height: 170)
        let rate = output["rates"][outputMetric]
        HStack {
            Text("Descriptive slope: \(workbenchScalarText(rate["slopePerSecond"])) \(rateUnit)")
            Text("R²: \(workbenchScalarText(rate["rSquared"]))").foregroundStyle(.secondary)
        }.font(.caption)
        Text("Uses observations \(rate["usedIndices"].array.compactMap(\.integer).map { String($0 + 1) }.joined(separator: ", ")). Area change per second is not cell migration speed.")
            .font(.caption).foregroundStyle(.secondary)
        DisclosureGroup("Observations, omitted points, intervals and coverage") {
            WorkbenchStructuredOutput(value: .object(["observations": output["frames"], "baseline": output["baseline"], "rate": rate, "notes": output["notes"]]))
                .frame(minHeight: 150, maxHeight: 350)
        }
        if series.selectedRun != nil {
            Divider()
            Picker("Export format", selection: $series.exportFormat) { ForEach(series.exportFormats) { Text($0.name).tag($0.id) } }
            Button("Export retained series…", action: export).disabled(session.busy || !canMutate)
            if let path = series.exportResult?["destination"].string { Text(path).font(.caption).textSelection(.enabled) }
        }
    }
    private var metricTitle: String { outputMetric == "closureFraction" ? "Closure fraction" : outputMetric == "gapAreaUm2" ? "Gap area (µm²)" : "Gap area (pixels²)" }
    private var rateUnit: String { outputMetric == "closureFraction" ? "fraction/s" : outputMetric == "gapAreaUm2" ? "µm²/s" : "pixels²/s" }
    private func export() {
        guard let format = series.exportFormats.first(where: { $0.id == series.exportFormat }) else { return }
        let panel = NSSavePanel(); panel.allowedContentTypes = [UTType(filenameExtension: format.fileExtension) ?? .data]
        panel.nameFieldStringValue = "scratch-wound-series.\(format.fileExtension)"
        if panel.runModal() == .OK, let url = panel.url { session.exportAssaySeries(to: url) }
    }
}
