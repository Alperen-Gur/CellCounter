import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct WorkbenchSweepResultsView: View {
    @Bindable var session: WorkbenchSession
    @Bindable var sweeps: WorkbenchSweepState
    let sweepID: String
    @Environment(\.dismiss) private var dismiss
    @State private var selectedCombination: Int?
    @State private var selectedRow: Int?
    @State private var metricMode = "counts"
    @State private var formatID = "results-csv"
    @State private var pageSize = 100

    private var results: WorkbenchSweepResults? { sweeps.results?.sweepID == sweepID ? sweeps.results : nil }
    private var selectedInput: WorkbenchSweepResultRow? {
        results?.rows.first { $0.id == selectedRow }
    }
    private var currentCombination: WorkbenchSweepCombinationResult? {
        results?.combinations.first { $0.id == selectedCombination }
    }
    private var metricTitles: [String] {
        switch metricMode {
        case "physical": return ["Total area / volume", "Mean object area / volume", "Unit"]
        case "intensity": return ["Mean object intensity", "Intensity units", "Object count"]
        default: return ["Object count", "Foreground samples", "Mean object samples"]
        }
    }
    private var canExport: Bool {
        !session.hasActiveWorkers && session.canRefreshWithoutDiscardingEdits && results != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(results?.name ?? "Sweep comparison").font(.title2)
                Spacer()
                Button("Refresh") { load(offset: results?.offset ?? 0) }
                Button("Done") { dismiss() }
            }.disabled(session.busy)
            Text("These are descriptive measurements of analysis variants from the same acquisitions. Counts across time are object observations, not unique cells or independent biological replicates.")
                .font(.callout).foregroundStyle(.secondary)
            if let error = session.error { Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled) }
            if let results {
                HStack {
                    Text("Snapshot revision \(results.sourceRevision) · \(results.complete ? "Complete" : "Partial") comparison")
                        .font(.caption)
                    if !results.sourceInputsCurrent {
                        Text("Original source inputs changed").font(.caption).foregroundStyle(.orange)
                    }
                    if let revision = session.revision, revision > results.sourceRevision {
                        Text("Project revision changed; refresh for current status.").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Table(results.combinations, selection: $selectedCombination) {
                    TableColumn("Combination") { Text(String($0.id + 1)) }.width(80)
                    TableColumn("Job state", value: \.status).width(100)
                    TableColumn("Current inputs") { Text("\($0.currentInputs) / \($0.totalInputs)") }.width(110)
                    TableColumn("Pending inputs") { Text(String($0.pendingInputs)) }.width(100)
                    TableColumn("Stale inputs") { Text(String($0.staleInputs)) }.width(90)
                    TableColumn(results.isGraph ? "Segmentation branches" : "Complete object observations") {
                        Text($0.isGraph ? "\($0.branchResults.count) separate branches" : $0.objectObservations.map(String.init) ?? "—")
                    }
                    TableColumn(results.isGraph ? "Branch coverage" : "Available observations") {
                        Text($0.isGraph ? ($0.comparisonComplete ? "Complete" : "Partial") :
                            "\($0.availableObjectObservations.map(String.init) ?? "—")\($0.comparisonComplete ? "" : " · Partial")")
                    }
                }.frame(minHeight: 130, idealHeight: 170, maxHeight: 200)
                if let combination = currentCombination {
                    ScrollView(.horizontal) {
                        HStack(spacing: 14) {
                            ForEach(Array(combination.values.enumerated()), id: \.offset) { _, value in
                                Text("\(workbenchSweepAxisLocation(value)) · \(value["path"].string ?? ""): \(scalar(value["value"]))")
                                    .font(.caption).textSelection(.enabled)
                            }
                        }
                    }.frame(height: 26)
                    if combination.isGraph {
                        branchResults(combination)
                    }
                } else if results.isGraph {
                    Text("Select a combination to inspect each branch separately. Object counts are never pooled across alternative branches.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    Text("Input measurements").font(.headline)
                    Picker("Metrics", selection: $metricMode) {
                        Text("Samples and counts").tag("counts")
                        Text("Physical size").tag("physical")
                        Text("Intensity").tag("intensity")
                    }.pickerStyle(.segmented).frame(width: 390)
                    Spacer()
                    Picker("Rows per page", selection: $pageSize) {
                        Text("50").tag(50); Text("100").tag(100); Text("250").tag(250); Text("500").tag(500)
                    }.frame(width: 170).disabled(session.busy)
                }
                Table(results.rows, selection: $selectedRow) {
                    TableColumn("Combination") { Text(String($0.combinationIndex + 1)) }.width(80)
                    TableColumn("Acquisition", value: \.sourceName).width(min: 140, ideal: 180)
                    TableColumn("Branch", value: \.branchLabel).width(min: 110, ideal: 140)
                    TableColumn("Dimension") { Text($0.target == "volume" ? "3D" : "2D") }.width(60)
                    TableColumn("Selection") { Text($0.selectionLabel($0.selection)) }.width(105)
                    TableColumn("State", value: \.status).width(90)
                    TableColumn(metricTitles[0]) { Text(metric($0, column: 0)) }
                    TableColumn(metricTitles[1]) { Text(metric($0, column: 1)) }
                    TableColumn(metricTitles[2]) { Text(metric($0, column: 2)) }
                }.frame(minHeight: 180, idealHeight: 220)
                HStack {
                    Text(results.total == 0 ? "No input rows" :
                        "Rows \(results.offset + 1)–\(results.offset + results.rows.count) of \(results.total)")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Previous") { load(offset: max(0, results.offset - results.limit)) }
                        .disabled(results.offset == 0 || session.busy)
                    Button("Next") { if let next = results.nextOffset { load(offset: next) } }
                        .disabled(results.nextOffset == nil || session.busy)
                }
                if let row = selectedInput {
                    VStack(alignment: .leading, spacing: 4) {
                        if let reason = row.reason { Text(reason).font(.caption).foregroundStyle(.orange) }
                        Text("\(row.branchLabel) · Source \(row.sourceName) [\(row.selectionLabel(row.sourceSelection))] → \(session.images.first { $0.id == row.workingImageID }?.name ?? "Retained output")")
                            .font(.caption).textSelection(.enabled)
                        Text("Checkpoint: \(row.checkpointStatus) · Analysis revision \(row.analysisRevision.map(String.init) ?? "—") · Measurement revision \(row.measurementRevision.map(String.init) ?? "—")")
                            .font(.caption).foregroundStyle(.secondary)
                        DisclosureGroup("Output identity") {
                            Text("Working image: \(row.workingImageID)").font(.caption.monospaced()).textSelection(.enabled)
                            if let node = row.nodeID { Text("Node: \(node)").font(.caption.monospaced()).textSelection(.enabled) }
                            if let hash = row.labelsHash {
                                Text("Label SHA-256: \(hash)").font(.caption.monospaced()).textSelection(.enabled)
                            }
                        }
                    }
                }
                DisclosureGroup("Comparison notes") {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(results.notes, id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary) }
                        }
                    }.frame(maxHeight: 90)
                }
                HStack {
                    Picker("Export", selection: $formatID) {
                        ForEach(sweeps.exportFormats) { Text($0.name).tag($0.id) }
                    }.frame(width: 300)
                    Button("Export all rows…", action: chooseExport).disabled(!canExport)
                    if let path = sweeps.exportResult?["destination"].string,
                       sweeps.exportResult?["sweepId"].string == sweepID {
                        Button("Show export in Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                        }
                    }
                    Spacer()
                }.disabled(session.busy)
                Text(sweeps.exportFormats.first { $0.id == formatID }?.description ??
                    "Exports include all input rows. Pending or stale measurements remain blank.")
                    .font(.caption).foregroundStyle(.secondary)
                if !canExport {
                    Text("Stop active workers and finish or clear pending canvas edits before exporting.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else if !session.busy {
                ContentUnavailableView("No comparison loaded", systemImage: "tablecells",
                    description: Text("Refresh to read the current sweep results."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            HStack {
                if session.busy { ProgressView().controlSize(.small) }
                Text(session.status).font(.caption).foregroundStyle(.secondary)
                Spacer()
            }
        }.padding(22).frame(width: 1160, height: 830)
        .task { load(offset: 0) }
        .onChange(of: pageSize) { _, _ in load(offset: 0) }
    }

    private func load(offset: Int) {
        selectedRow = nil
        session.loadSweepResults(sweepID, offset: offset, limit: pageSize)
    }
    private func branchResults(_ combination: WorkbenchSweepCombinationResult) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Separate branch results · Combination \(combination.id + 1)").font(.callout.weight(.semibold))
            Text("Each branch reports observations across its own source/time inputs. Alternative branches are not pooled or treated as biological replicates.")
                .font(.caption).foregroundStyle(.secondary)
            Table(combination.branchResults) {
                TableColumn("Branch", value: \.name).width(min: 140, ideal: 190)
                TableColumn("Current inputs") { Text("\($0.currentInputs) / \($0.totalInputs)") }
                TableColumn("Pending inputs") { Text(String($0.pendingInputs)) }
                TableColumn("Stale inputs") { Text(String($0.staleInputs)) }
                TableColumn("Complete observations") { Text($0.objectObservations.map(String.init) ?? "—") }
                TableColumn("Available observations") {
                    Text("\($0.availableObjectObservations.map(String.init) ?? "—")\($0.comparisonComplete ? "" : " · Partial")")
                }
            }.frame(minHeight: 90, idealHeight: 120, maxHeight: 150)
        }
    }
    private func scalar(_ value: WorkbenchJSON) -> String {
        value.string ?? value.number.map { String($0) } ?? value.bool.map { $0 ? "Yes" : "No" } ?? "Canonical default"
    }
    private func number(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "—" }
        return value.formatted(.number.precision(.significantDigits(1...6)))
    }
    private func metric(_ row: WorkbenchSweepResultRow, column: Int) -> String {
        guard let values = row.metrics else { return "—" }
        switch metricMode {
        case "physical":
            if column == 0 { return number(values.totalPhysicalSize) }
            if column == 1 { return number(values.meanObjectPhysicalSize) }
            return values.unitLabel
        case "intensity":
            if column == 0 { return number(values.meanObjectIntensity) }
            if column == 1 { return row.intensityUnits.replacingOccurrences(of: "-", with: " ") }
            return values.objectCount.map(String.init) ?? "—"
        default:
            if column == 0 { return values.objectCount.map(String.init) ?? "—" }
            if column == 1 { return values.foregroundSamples.map(String.init) ?? "—" }
            return number(values.meanObjectSizeSamples)
        }
    }
    private func chooseExport() {
        guard canExport, let format = sweeps.exportFormats.first(where: { $0.id == formatID }) else { return }
        let panel = NSSavePanel()
        panel.title = "Export \(format.name)"
        panel.message = "Export every input row to a new file. Existing files will be preserved."
        panel.canCreateDirectories = true; panel.isExtensionHidden = false
        if let type = UTType(filenameExtension: format.fileExtension) { panel.allowedContentTypes = [type] }
        let stem = (results?.name ?? "Sweep").replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        panel.nameFieldStringValue = "\(stem)-\(format.id).\(format.fileExtension)"
        panel.begin { response in
            guard response == .OK, let destination = panel.url else { return }
            session.exportSweepResults(sweepID, format: format.id, to: destination)
        }
    }
}
