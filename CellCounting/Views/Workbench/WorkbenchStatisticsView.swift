import AppKit
import Charts
import SwiftUI
import UniformTypeIdentifiers

struct WorkbenchStatisticsView: View {
    @Bindable var session: WorkbenchSession
    @Bindable var statistics: WorkbenchStatisticsState
    @Environment(\.dismiss) private var dismiss
    @State private var rowPage = 0
    @State private var selectedRunID = ""
    private var canWrite: Bool { !session.busy && !session.hasActiveWorkers }
    private var definitionCurrent: Bool { statistics.definitionPreviewRevision == session.revision && statistics.previewDefinition == (try? session.statisticalDefinition()) }
    private var inferenceCurrent: Bool {
        statistics.inferenceRevision == session.revision && (statistics.recomputeRunID != nil || statistics.inferenceArguments?["analysis"] == session.statisticalAnalysis)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Biological-replicate statistics").font(.title2)
                WorkbenchSavedRecordAccess(session: session, catalogues: ["statisticsDesigns", "statisticsRuns", "specimens", "assayRuns", "assaySeriesRuns"])
                Spacer()
                Button("Refresh saved records", action: session.loadStatistics).disabled(session.busy)
                Button("Done") { dismiss() }.disabled(session.busy || statistics.dirty)
            }
            Text("One input row is one biological specimen. Subject and block identifiers describe the declared design; image objects never increase biological n.")
                .font(.callout).foregroundStyle(.secondary)
            if let error = session.error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            TabView {
                design.tabItem { Text("Design and inputs") }
                inference.tabItem { Text("Inference") }
                reports.tabItem { Text("Saved reports") }
            }
            Text(session.status).font(.caption).foregroundStyle(.secondary)
        }.padding(22).frame(width: 1120, height: 800)
        .task { statistics.editorOpen = true; session.loadStatistics() }
        .onDisappear { statistics.editorOpen = false }
        .interactiveDismissDisabled(session.busy || statistics.dirty)
    }
    private var design: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Picker("Saved design", selection: $statistics.selectedDesignID) {
                        Text("New design").tag("")
                        ForEach(Array(statistics.designs.enumerated()), id: \.offset) { _, value in
                            Text((value["name"].string ?? "Design") + (value["inputsCurrent"].bool == true ? "" : " · Historical inputs"))
                                .tag(value["id"].string ?? "")
                        }
                    }
                    Stepper("Version \(statistics.selectedVersion)", value: $statistics.selectedVersion, in: 1...max(1, statistics.designs.first { $0["id"].string == statistics.selectedDesignID }?["latestVersion"].integer ?? 1))
                    Button("Load for editing") { session.loadStatisticalDesign(forEditing: true) }.disabled(statistics.selectedDesignID.isEmpty || statistics.dirty)
                    Button("New design") { statistics.reset(); statistics.originalDraft = statistics.draft; session.loadStatistics() }.disabled(statistics.dirty)
                }
                TextField("Design name", text: $statistics.name)
                outcomeControls
                GroupBox("Factors") {
                    WorkbenchFactorEditor(factors: $statistics.factors).padding(5)
                        .onChange(of: statistics.factors.map(\.id)) { _, ids in statistics.terms.formIntersection(Set(ids)) }
                }
                GroupBox("Specimen input rows") {
                    VStack(alignment: .leading, spacing: 9) {
                        HStack {
                            Button("Add project specimens", action: session.seedStatisticalRows)
                            Text("\(statistics.rows.count) specimens · all assigned images must have compatible current measurements").font(.caption)
                            Spacer()
                            Button("Previous") { rowPage = max(0, rowPage - 1) }.disabled(rowPage == 0)
                            Button("Next") { rowPage += 1 }.disabled((rowPage + 1) * 20 >= statistics.rows.count)
                        }
                        ForEach(Array(statistics.rows.indices.dropFirst(rowPage * 20).prefix(20)), id: \.self) { index in
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text(statistics.rows[index].name).font(.callout.bold())
                                    TextField("Subject ID (pairing)", text: $statistics.rows[index].subject)
                                    TextField("Block ID", text: $statistics.rows[index].block)
                                    Button("Remove row") { statistics.rows.remove(at: index) }
                                }
                                HStack {
                                    ForEach(statistics.factors) { factor in
                                        if factor.kind == "categorical" {
                                            Picker(factor.name, selection: valueBinding(index, factor: factor.id)) {
                                                Text("Choose level").tag("")
                                                ForEach(factor.levelList, id: \.self) { Text($0).tag($0) }
                                            }
                                        } else { TextField(factor.name, text: valueBinding(index, factor: factor.id)) }
                                    }
                                }
                                TextField("Exclusion reason (blank includes specimen)", text: $statistics.rows[index].exclusion)
                                Divider()
                            }
                        }
                    }.padding(5)
                }
                HStack {
                    Button("Preview input coverage", action: session.previewStatisticalDesign)
                    Button("Save as new design") { session.saveStatisticalDesign(asNew: true) }
                        .disabled(!canWrite || !definitionCurrent)
                    Button("Save new version") { session.saveStatisticalDesign(asNew: false) }
                        .disabled(!canWrite || statistics.selectedDesignID.isEmpty || !definitionCurrent)
                    if statistics.dirty {
                        Button("Discard design draft") {
                            if let selected = statistics.selectedDesign { statistics.loadDefinition(selected["definition"], specimens: session.specimens) }
                            else { statistics.reset(); session.loadStatistics() }
                        }
                    }
                }
                if let preview = statistics.definitionPreview {
                    Text(preview["ready"].bool == true ? "Complete inputs are ready to freeze." : "This design can be saved as a draft; blocked inputs must be resolved before inference.").font(.headline)
                    blockers(preview["blockers"])
                    specimenTable(preview["rows"], units: preview["units"].string ?? "")
                    if !definitionCurrent { Text("Design or project revision changed. Preview coverage again.").foregroundStyle(.orange) }
                }
                DisclosureGroup("Design conventions and limits") { notes(statistics.catalogue["notes"]) }
            }.padding(.top, 12).textFieldStyle(.roundedBorder).disabled(session.busy)
        }
    }
    private var outcomeControls: some View {
        GroupBox("Outcome") {
            VStack(alignment: .leading, spacing: 8) {
                Picker("Source", selection: $statistics.outcomeKind) { Text("Saved object measurements").tag("measurement"); Text("Saved assay metric").tag("assay"); Text("Scratch-wound series rate").tag("assay-series") }
                if statistics.outcomeKind == "measurement" {
                    HStack {
                        Picker("Dimensionality", selection: $statistics.target) { Text("2D saved projections").tag("plane"); Text("3D selected frame").tag("volume") }
                        Picker("Metric", selection: $statistics.metric) {
                            ForEach(Array(statistics.catalogue["outcomes"].array.filter { $0["targets"].array.contains(.string(statistics.target)) }.enumerated()), id: \.offset) { _, item in
                                Text(metricLabel(item["id"].string ?? "") + " (\(item["units"].string ?? ""))").tag(item["id"].string ?? "")
                            }
                        }
                    }
                    if statistics.target == "volume" {
                        HStack { number("Time (1-based)", value: $statistics.time); number("Channel (1-based)", value: $statistics.channel) }
                    }
                } else if statistics.outcomeKind == "assay-series" {
                    Picker("Current exemplar series", selection: $statistics.assayRunID) {
                        Text("Choose a retained series").tag("")
                        ForEach(Array(session.assaySeries.runs.enumerated()), id: \.offset) { _, run in
                            Text((run["name"].string ?? "Series") + (run["outputsCurrent"].bool == true ? "" : " · Historical inputs")).tag(run["runId"].string ?? "")
                        }
                    }
                    Picker("Descriptive rate", selection: $statistics.assayMetricPath) {
                        Text("Choose rate").tag("")
                        ForEach(Array(statistics.catalogue["seriesOutcomes"].array.enumerated()), id: \.offset) { _, metric in
                            Text((metric["metricPath"].string ?? "Rate") + " (" + (metric["units"].string ?? "") + ")").tag(metric["metricPath"].string ?? "")
                        }
                    }
                    Text("Exactly one compatible, current series is required per included biological specimen. Repeated frames do not increase biological n; ambiguous multiple series block inference.").font(.caption).foregroundStyle(.secondary)
                } else {
                    HStack {
                        Picker("Current exemplar assay", selection: $statistics.assayRunID) {
                            Text("Choose retained assay").tag("")
                            ForEach(Array(session.assays.summaryRuns.enumerated()), id: \.offset) { _, run in
                                Text("\(run["assay"].string ?? "Assay") · \(session.images.first { $0.id == run["imageId"].string }?.name ?? "Image")").tag(run["runId"].string ?? "")
                            }
                        }
                        Button("Load measured outcomes", action: session.loadStatisticalAssayMetrics).disabled(statistics.assayRunID.isEmpty)
                    }
                    Picker("Measured output", selection: $statistics.assayMetricPath) {
                        Text("Choose outcome").tag("")
                        ForEach(Array((statistics.assayMetrics?["metrics"].array ?? []).enumerated()), id: \.offset) { _, metric in Text(metric["path"].string ?? "").tag(metric["path"].string ?? "") }
                    }
                    Text("The exemplar freezes assay parameters and source selection. Compatible current runs are required across every included specimen.").font(.caption).foregroundStyle(.secondary)
                }
            }.padding(5)
        }
    }
    private var inference: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if let design = statistics.selectedDesign {
                    Text("\(design["name"].string ?? "Design") · version \(design["version"].integer ?? 1) · \(design["includedCount"].integer ?? 0) included specimens")
                        .font(.headline)
                    if design["inputsCurrent"].bool != true { Text("Frozen inputs are historical. Save a new design version or recompute a retained result from current measurements.").foregroundStyle(.orange) }
                } else { Text("Save or explicitly load a design version in Design and inputs first.").foregroundStyle(.secondary) }
                Picker("Method", selection: $statistics.method) {
                    ForEach(Array(statistics.catalogue["methods"].array.enumerated()), id: \.offset) { _, method in Text(method["name"].string ?? "").tag(method["id"].string ?? "") }
                }
                if let method = statistics.catalogue["methods"].array.first(where: { $0["id"].string == statistics.method }) { notes(method["assumptions"]) }
                if statistics.method == "linear-model" {
                    GroupBox("Declared model terms") {
                        VStack(alignment: .leading) {
                            ForEach(statistics.factors) { factor in Toggle(factor.name, isOn: Binding(get: { statistics.terms.contains(factor.id) }, set: { if $0 { statistics.terms.insert(factor.id) } else { statistics.terms.remove(factor.id) } })) }
                            ForEach($statistics.interactions) { $interaction in
                                HStack {
                                    factorPicker("First factor", selection: $interaction.first)
                                    Text("×")
                                    factorPicker("Second factor", selection: $interaction.second)
                                    Button("Remove") { statistics.interactions.removeAll { $0.id == interaction.id } }
                                }
                            }
                            Button("Add two-factor interaction") { statistics.interactions.append(WorkbenchStatInteraction()) }.disabled(statistics.interactions.count >= 32)
                        }.padding(5)
                    }
                    HStack {
                        Picker("Fixed blocking", selection: $statistics.blocking) { Text("None").tag("none"); Text("Subject fixed effects").tag("subject"); Text("Block fixed effects").tag("block") }
                        Picker("Covariance", selection: $statistics.covariance) { Text("Classical").tag("classical"); Text("HC3 robust approximation").tag("HC3") }
                    }
                    Text("Subject/block coefficients are fixed effects. This is not a random-effects or general repeated-measures model.").font(.caption).foregroundStyle(.secondary)
                }
                GroupBox("Declared comparison family") {
                    VStack(alignment: .leading) {
                        ForEach($statistics.contrasts) { $contrast in
                            let factor = statistics.factors.first { $0.id == contrast.factorID }
                            HStack {
                                Picker("Factor", selection: $contrast.factorID) {
                                    Text("Choose factor").tag("")
                                    ForEach(statistics.factors.filter { $0.kind == "categorical" }) { Text($0.name).tag($0.id) }
                                }
                                Picker("Reference", selection: $contrast.reference) { ForEach(factor?.levelList ?? [], id: \.self) { Text($0).tag($0) } }
                                Picker("Comparison", selection: $contrast.comparison) { ForEach(factor?.levelList ?? [], id: \.self) { Text($0).tag($0) } }
                                Button("Remove") { statistics.contrasts.removeAll { $0.id == contrast.id } }
                            }
                        }
                        Button("Add contrast") {
                            let factor = statistics.factors.first { $0.kind == "categorical" }
                            statistics.contrasts.append(WorkbenchStatContrast(factorID: factor?.id ?? "", reference: factor?.reference ?? "", comparison: factor?.levelList.last ?? ""))
                        }.disabled(statistics.contrasts.count >= 64)
                        Text("Effects are comparison minus reference. Linear models without declared contrasts report non-block coefficients.").font(.caption).foregroundStyle(.secondary)
                    }.padding(5)
                }
                HStack {
                    VStack(alignment: .leading) { Text("Pointwise confidence level").font(.caption); TextField("Confidence", value: $statistics.confidence, format: .number) }
                    Picker("Multiple testing", selection: $statistics.multiplicity) { Text("None").tag("none"); Text("Holm family-wise").tag("holm"); Text("Benjamini–Hochberg FDR").tag("benjamini-hochberg") }
                }
                HStack {
                    Button("Preview inference") { session.previewStatisticalInference() }.disabled(statistics.selectedDesign == nil || statistics.dirty)
                    Button("Retain previewed result", action: session.saveStatisticalInference)
                        .disabled(!canWrite || !inferenceCurrent || statistics.inferencePreview?["status"].string != "ready")
                }
                if let preview = statistics.inferencePreview {
                    if !inferenceCurrent { Text("Settings or project revision changed. Preview again before saving.").foregroundStyle(.orange) }
                    resultView(preview)
                }
            }.padding(.top, 12).textFieldStyle(.roundedBorder).disabled(session.busy)
        }
    }
    private var reports: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Picker("Saved result", selection: $selectedRunID) {
                        Text("Choose retained result").tag("")
                        ForEach(Array(statistics.runs.enumerated()), id: \.offset) { index, value in
                            Text("\(value["name"].string ?? "Result") · \(value["method"].string ?? "") · \(index + 1)" + (value["outputsCurrent"].bool == true ? "" : " · Historical")).tag(value["id"].string ?? "")
                        }
                    }
                    Button("Load result") { session.loadStatisticalRun(selectedRunID) }.disabled(selectedRunID.isEmpty)
                }
                if let run = statistics.selectedRun {
                    Text("\(run["name"].string ?? "Result") · \(run["outputsCurrent"].bool == true ? "Current inputs" : "Historical inputs")").font(.headline)
                    resultView(run["result"])
                    DisclosureGroup("Exact specimen input table") { specimenTable(run["inputTable"]["rows"], units: run["result"]["units"].string ?? "") }
                    HStack {
                        Button("Preview recomputation from current inputs") { session.previewStatisticalInference(recompute: true) }
                            .disabled(run["replacementRunId"].string != nil || statistics.dirty)
                        if run["predecessorRunId"].string != nil { Text("This run retains a link to its predecessor.").font(.caption) }
                    }
                    if statistics.recomputeRunID != nil, let preview = statistics.inferencePreview {
                        Text("Current-input recomputation preview").font(.headline)
                        resultView(preview)
                        Button("Retain replacement result", action: session.saveStatisticalInference)
                            .disabled(!canWrite || !inferenceCurrent || preview["status"].string != "ready")
                    }
                    HStack {
                        Picker("Export", selection: $statistics.exportFormat) { ForEach(statistics.exportFormats) { Text($0.name).tag($0.id) } }
                        Button("Choose destination…", action: chooseExport).disabled(!canWrite)
                    }
                    if let format = statistics.exportFormats.first(where: { $0.id == statistics.exportFormat }) { Text(format.description).font(.caption).foregroundStyle(.secondary) }
                    if statistics.exportFormat == "effects-svg" { Text("SVG uses the optional reporting dependency. A missing dependency leaves the saved numerical result available for JSON/CSV export.").font(.caption).foregroundStyle(.secondary) }
                    if let path = statistics.exportResult?["destination"].string { Button("Show exported report") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) } }
                }
            }.padding(.top, 12).disabled(session.busy)
        }
    }
    private func resultView(_ value: WorkbenchJSON) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("\(value["status"].string ?? "") · biological n = \(value["biologicalN"].integer ?? 0) · \(value["units"].string ?? "")").font(.headline)
            blockers(value["blockers"])
            let rows = value["results"].array
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack {
                    Text(row["comparison"].string.map { "\($0) − \(row["reference"].string ?? "")" } ?? row["id"].string ?? "Effect").frame(maxWidth: .infinity, alignment: .leading)
                    Text("Effect \(format(row["estimate"]))")
                    Text("CI \(row["confidenceInterval"].array.map(format).joined(separator: " to "))")
                    Text("p \(format(row["pValue"])) · adjusted \(format(row["adjustedPValue"]))")
                    Text(row["status"].string ?? "").foregroundStyle(.secondary)
                }.font(.caption).textSelection(.enabled)
            }
            if !value["plotTable"].array.isEmpty {
                Chart {
                    ForEach(Array(value["plotTable"].array.enumerated()), id: \.offset) { index, row in
                        let result = value["results"].array.first { $0["id"] == row["id"] }
                        let label = result?["comparison"].string.map { "\($0) − \(result?["reference"].string ?? "")" }
                            ?? "Effect \(index + 1)"
                        if let estimate = row["estimate"].number { PointMark(x: .value("Effect", estimate), y: .value("Comparison", label)) }
                        let interval = row["confidenceInterval"].array.compactMap(\.number)
                        if interval.count == 2 { RuleMark(xStart: .value("Lower", interval[0]), xEnd: .value("Upper", interval[1]), y: .value("Comparison", label)) }
                    }
                }.frame(height: CGFloat(min(600, max(140, value["plotTable"].array.count * 26))))
                Text("Intervals are pointwise; multiple-testing adjustment applies to the declared p-value family.").font(.caption).foregroundStyle(.secondary)
            }
            DisclosureGroup("Assumptions, estimability and coefficients") {
                notes(value["notes"])
                WorkbenchStructuredOutput(value: value["modelStatus"])
                WorkbenchStructuredOutput(value: value["coefficients"])
            }
        }
    }
    private func specimenTable(_ rows: WorkbenchJSON, units: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(Array(rows.array.prefix(100).enumerated()), id: \.offset) { _, row in
                Text("\(row["name"].string ?? session.specimens.first { $0.id == row["specimenId"].string }?.name ?? "Specimen") · \(format(row["value"])) \(units) · \(row["included"].bool == true ? "Included" : row["reason"].string ?? "Excluded")").font(.caption)
            }
            if rows.array.count > 100 { Text("Showing the first 100 rows. Export inputs CSV for the complete retained table.").font(.caption).foregroundStyle(.secondary) }
        }
    }
    private func blockers(_ rows: WorkbenchJSON) -> some View { ForEach(Array(rows.array.enumerated()), id: \.offset) { _, row in Text(row["message"].string ?? row.string ?? "").font(.caption).foregroundStyle(.orange) } }
    private func notes(_ rows: WorkbenchJSON) -> some View { ForEach(Array(rows.array.enumerated()), id: \.offset) { _, row in Text(row.string ?? "").font(.caption).foregroundStyle(.secondary) } }
    private func valueBinding(_ index: Int, factor: String) -> Binding<String> { Binding(get: { statistics.rows[index].values[factor] ?? "" }, set: { statistics.rows[index].values[factor] = $0 }) }
    private func factorPicker(_ title: String, selection: Binding<String>) -> some View { Picker(title, selection: selection) { Text("Choose factor").tag(""); ForEach(statistics.factors) { Text($0.name).tag($0.id) } } }
    private func number(_ title: String, value: Binding<Int>) -> some View { VStack(alignment: .leading) { Text(title).font(.caption); TextField(title, value: value, format: .number) } }
    private func format(_ value: WorkbenchJSON) -> String { value.number.map { String(format: "%.5g", $0) } ?? "—" }
    private func metricLabel(_ value: String) -> String { ["count": "Objects per image", "meanAreaPx": "Mean object area", "meanAreaUm2": "Mean object area", "meanVolumeVox": "Mean object size", "meanVolumeUm3": "Mean object volume", "meanIntensity": "Mean object intensity"][value] ?? value }
    private func chooseExport() {
        guard let format = statistics.exportFormats.first(where: { $0.id == statistics.exportFormat }) else { return }
        let panel = NSSavePanel(); panel.title = "Export retained statistical result"; panel.canCreateDirectories = true
        panel.nameFieldStringValue = "statistics-\(format.id).\(format.fileExtension)"
        if let type = UTType(filenameExtension: format.fileExtension) { panel.allowedContentTypes = [type] }
        panel.begin { response in if response == .OK, let destination = panel.url { session.exportStatisticalRun(to: destination) } }
    }
}
