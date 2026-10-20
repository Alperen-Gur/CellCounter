import AppKit
import SwiftUI

private struct WorkbenchSweepValue: Identifiable {
    let id = UUID()
    var value: WorkbenchJSON
}

private struct WorkbenchSweepAxis: Identifiable {
    let id = UUID()
    var parameterID: String
    var values: [WorkbenchSweepValue]
}

struct WorkbenchSweepPanel: View {
    @Bindable var session: WorkbenchSession
    @Bindable var sweeps: WorkbenchSweepState
    let workflow: WorkbenchWorkflow?
    let imageIDs: Set<String>
    let timeIndices: [Int]?
    @State private var name = "Parameter comparison"
    @State private var axes: [WorkbenchSweepAxis] = []
    @State private var exportDirectory: URL?
    @State private var combinationPage = 0
    @State private var showingResults = false

    private var discoveryCurrent: Bool {
        workflow?.id == sweeps.workflowID && workflow?.version == sweeps.workflowVersion
    }
    private var arguments: [String: WorkbenchJSON] {
        var value: [String: WorkbenchJSON] = [
            "workflowId": .string(workflow?.id ?? ""),
            "workflowVersion": .number(Double(workflow?.version ?? 1)),
            "imageIds": .array(imageIDs.sorted().map(WorkbenchJSON.string)),
            "axes": .array(axes.compactMap { axis in
                guard let parameter = sweeps.parameters.first(where: { $0.id == axis.parameterID }) else { return nil }
                return parameter.axis(values: axis.values.map(\.value))
            })
        ]
        if let timeIndices { value["timeIndices"] = .array(timeIndices.map { .number(Double($0)) }) }
        if let exportDirectory { value["exportDirectory"] = .string(exportDirectory.path) }
        return value
    }
    private var combinationCount: Int { axes.reduce(1) { $0 * max(1, $1.values.count) } }
    private var ready: Bool {
        discoveryCurrent && !imageIDs.isEmpty && !axes.isEmpty && axes.count <= 6 && combinationCount <= 64 &&
            Set(axes.map(\.parameterID)).count == axes.count &&
            axes.allSatisfy { axis in !axis.values.isEmpty && axis.values.count <= 16 &&
                sweeps.parameters.contains { $0.id == axis.parameterID } } &&
            (workflow?.exportsPackage != true || exportDirectory != nil)
    }
    private var previewCurrent: Bool { sweeps.preview != nil && sweeps.previewArguments == .object(arguments) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Compare parameter combinations through the same saved workflow. Each combination creates independent image variants and a resumable analysis job.")
                .font(.caption).foregroundStyle(.secondary)
            if let workflow {
                Text("\(workflow.name) · v\(workflow.version) · \(imageIDs.count) selected images").font(.callout.bold())
                if workflow.isGraph {
                    Text("Each combination runs this complete branching workflow. Parameters identify their exact node; summaries keep technical branches separate and do not pool their object counts.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Button("Load adjustable parameters") {
                    axes = []; session.loadSweepParameters(workflow)
                }
                if discoveryCurrent {
                    if sweeps.parameters.isEmpty {
                        Text("This workflow has no adjustable parameters available in the current runtime. Source selectors and graph connections are changed by saving a workflow version, rather than through a parameter sweep.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    TextField("Sweep name", text: $name).textFieldStyle(.roundedBorder)
                    ForEach($axes) { $axis in axisEditor($axis) }
                    Button("Add parameter", systemImage: "plus") {
                        let used = Set(axes.map(\.parameterID))
                        if let parameter = sweeps.parameters.first(where: { !used.contains($0.id) }) {
                            axes.append(WorkbenchSweepAxis(parameterID: parameter.id,
                                values: [WorkbenchSweepValue(value: parameter.initialValue)]))
                        }
                    }.disabled(axes.count >= 6 || axes.count >= sweeps.parameters.count)
                    if workflow.exportsPackage {
                        Button("Choose export folder…", action: chooseExportDirectory)
                        Text(exportDirectory?.path ?? "A new package filename will be assigned to each combination.")
                            .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                    Text("\(combinationCount) combinations · Maximum 64").font(.caption)
                        .foregroundStyle(combinationCount > 64 ? Color.orange : Color.secondary)
                    Button("Preview sweep") { session.previewSweep(arguments: arguments) }.disabled(!ready)
                    if previewCurrent, let preview = sweeps.preview {
                        if workflow.isGraph {
                            Text("\(preview["combinationCount"].integer ?? 0) combinations create \(preview["requiredVariantCount"].integer ?? 0) isolated source variants, \(preview["requiredProcessedCount"].integer ?? 0) processed acquisitions and \(preview["requiredBranchImageCount"].integer ?? 0) branch mask images.")
                                .font(.caption)
                            Text("\(preview["nodeCheckpointCount"].integer ?? 0) scientific node checkpoints · \(preview["requiredImageCount"].integer ?? 0) total new images")
                                .font(.caption).foregroundStyle(.secondary)
                        } else {
                            Text("\(preview["combinationCount"].integer ?? 0) combinations create \(preview["requiredVariantCount"].integer ?? 0) mask variants and \(preview["requiredProcessedCount"].integer ?? 0) processed acquisitions.")
                                .font(.caption)
                        }
                        Text("These images do not inherit specimen assignments or reference approvals. Assign them explicitly before biological summaries.")
                            .font(.caption).foregroundStyle(.secondary)
                        ForEach(preview["notes"].array.compactMap(\.string), id: \.self) {
                            Text($0).font(.caption).foregroundStyle(.secondary)
                        }
                        DisclosureGroup("Preview combinations") {
                            ForEach(Array(preview["combinations"].array.enumerated()), id: \.offset) { _, combination in
                                VStack(alignment: .leading, spacing: 3) {
                                    Text("Combination \((combination["index"].integer ?? 0) + 1)").font(.caption.bold())
                                    ForEach(Array(combination["values"].array.enumerated()), id: \.offset) { _, value in
                                        Text("\(workbenchSweepAxisLocation(value, graph: workflow.graph)) · \(value["path"].string ?? "") = \(label(value["value"]))").font(.caption)
                                    }
                                }.padding(.vertical, 4)
                            }
                        }
                        Button("Create reviewed sweep") {
                            session.createSweep(name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                                                arguments: arguments)
                        }.buttonStyle(.borderedProminent)
                            .disabled(!ready || session.hasActiveWorkers || !session.canRefreshWithoutDiscardingEdits ||
                                name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || name.count > 200)
                    } else if sweeps.preview != nil {
                        Text("Selections changed. Preview the combinations again before creating the sweep.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(sweeps.notes, id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary) }
                }
            } else {
                Text("Select a saved workflow and images below.").font(.caption).foregroundStyle(.secondary)
            }
            Divider()
            HStack {
                Text("Saved sweeps").font(.headline)
                Spacer()
                Button("Refresh", action: session.loadSweeps)
            }
            Picker("Sweep", selection: Binding(get: { sweeps.selectedID }, set: session.selectSweep)) {
                Text("Select a sweep").tag("")
                ForEach(Array(sweeps.records.enumerated()), id: \.offset) { _, sweep in
                    Text("\(sweep["name"].string ?? "Sweep") · \(sweep["status"].string ?? "")")
                        .tag(sweep["id"].string ?? "")
                }
            }
            if let sweep = sweeps.detail { sweepDetails(sweep) }
        }.disabled(session.busy)
        .onChange(of: workflow?.id) { _, _ in resetBuilder() }
        .onChange(of: workflow?.version) { _, _ in resetBuilder() }
        .onChange(of: sweeps.selectedID) { _, _ in combinationPage = 0 }
        .sheet(isPresented: $showingResults) {
            WorkbenchSweepResultsView(session: session, sweeps: sweeps, sweepID: sweeps.selectedID)
        }
    }

    private func axisEditor(_ axis: Binding<WorkbenchSweepAxis>) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Picker("Parameter", selection: Binding(get: { axis.wrappedValue.parameterID }, set: { id in
                    axis.wrappedValue.parameterID = id
                    if let parameter = sweeps.parameters.first(where: { $0.id == id }) {
                        axis.wrappedValue.values = [WorkbenchSweepValue(value: parameter.initialValue)]
                    }
                })) {
                    ForEach(sweeps.parameters) { parameter in
                        Text("\(parameter.locationLabel) · \(parameter.label)").tag(parameter.id)
                    }
                }
                Button { axes.removeAll { $0.id == axis.wrappedValue.id } } label: { Image(systemName: "minus.circle") }
            }
            if let parameter = sweeps.parameters.first(where: { $0.id == axis.wrappedValue.parameterID }) {
                ForEach(axis.values) { value in
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 4) {
                            if parameter.canOmit {
                                Toggle("Use canonical default", isOn: Binding(
                                    get: { value.wrappedValue.value == .null },
                                    set: { value.wrappedValue.value = $0 ? .null : parameter.initialValue }))
                                    .font(.caption)
                            }
                            if value.wrappedValue.value != .null {
                                WorkbenchPluginParameters(definitions: [parameter.field], values: Binding(
                                    get: { ["value": value.wrappedValue.value] },
                                    set: { value.wrappedValue.value = $0["value"] ?? parameter.initialValue }))
                            }
                        }
                        Button {
                            axis.wrappedValue.values.removeAll { $0.id == value.wrappedValue.id }
                        } label: { Image(systemName: "minus.circle") }
                            .disabled(axis.wrappedValue.values.count <= 1)
                    }
                }
                Button("Add value") {
                    axis.wrappedValue.values.append(WorkbenchSweepValue(value: parameter.initialValue))
                }.disabled(axis.wrappedValue.values.count >= 16)
            }
        }.padding(10).background(.quaternary.opacity(0.35)).clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func sweepDetails(_ sweep: WorkbenchJSON) -> some View {
        let status = sweep["status"].string ?? ""
        let id = sweep["id"].string ?? ""
        let completed = sweep["progress"]["completed"].integer ?? 0
        let total = max(1, sweep["progress"]["total"].integer ?? 1)
        let combinations = sweep["combinations"].array
        let start = min(combinationPage * 8, max(0, combinations.count - 1) / 8 * 8)
        let workers = session.jobWorkers.filter { $0.targetKind == "sweep" && $0.targetID == id }
        let activeWorker = workers.last { $0.active }
        return VStack(alignment: .leading, spacing: 8) {
            Text(status.replacingOccurrences(of: "-", with: " ").capitalized).font(.callout.bold())
            if status == "awaiting-review" {
                Text("A branch needs an explicit mask review. Open its combination job in Jobs, inspect the retained mask and record a decision. Successful checkpoints remain saved; no worker approves reviews automatically.")
                    .font(.caption).foregroundStyle(.orange)
            }
            ProgressView(value: Double(completed), total: Double(total))
            Text("\(completed) of \(total) checkpoints complete").font(.caption)
            Button("Compare results and export…") { showingResults = true }
            if sweep["outputsCurrent"].bool == false || sweep["sourceInputsCurrent"].bool == false {
                Text("Inputs or results have changed since this sweep was created. Review the variants before interpreting comparisons.")
                    .font(.caption).foregroundStyle(.orange)
            }
            HStack {
                if ["pending", "running"].contains(status) {
                    Button("Run sweep in background") { session.startBackgroundSweep(id) }
                        .disabled(!session.canRefreshWithoutDiscardingEdits)
                    Button("Run next checkpoint") { session.changeSweep(id, action: "advance") }
                    Button("Pause") { session.changeSweep(id, action: "pause") }
                }
                if status == "paused" { Button("Resume") { session.changeSweep(id, action: "resume") } }
                if status == "failed" { Button("Retry") { session.changeSweep(id, action: "retry") } }
                if !["completed", "cancelled"].contains(status) {
                    Button("Cancel") { session.changeSweep(id, action: "cancel") }
                }
            }.disabled(session.hasActiveWorkers || !session.canRefreshWithoutDiscardingEdits)
            if let worker = activeWorker {
                HStack {
                    Text("Sweep worker: \(worker.status.capitalized)").font(.caption)
                    Spacer()
                    Button(worker.stopRequested ? "Stop requested" : "Stop after checkpoint") {
                        session.stopBackgroundJob(worker.id)
                    }.disabled(worker.stopRequested)
                }
                if let completed = worker.completed, let total = worker.total {
                    Text("Worker progress: \(completed) of \(total) checkpoints").font(.caption).foregroundStyle(.secondary)
                }
                Text("The whole sweep continues after the app closes. Stopping preserves the current checkpoint and pauses the remaining group.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text("Each advance commits one canonical checkpoint. The group completes scientific analysis before package exports. Individual jobs appear in the Jobs column.")
                .font(.caption).foregroundStyle(.secondary)
            if !workers.isEmpty {
                DisclosureGroup("Sweep worker history") {
                    ForEach(workers.reversed()) { worker in
                        VStack(alignment: .leading, spacing: 3) {
                            Text("\(worker.status.capitalized) · Revision \(worker.lastRevision.map(String.init) ?? "—")")
                                .font(.caption)
                            if let heartbeat = worker.heartbeat {
                                Text("Last heartbeat: \(heartbeat)").font(.caption).foregroundStyle(.secondary)
                            }
                            if let error = worker.error { Text(error).font(.caption).foregroundStyle(.orange) }
                        }
                    }
                }
            }
            if combinations.count > 8 {
                Stepper("Combination page \(combinationPage + 1)", value: $combinationPage,
                        in: 0...((combinations.count - 1) / 8))
            }
            ForEach(Array(combinations.enumerated()).dropFirst(start).prefix(8), id: \.offset) { _, combination in
                VStack(alignment: .leading, spacing: 4) {
                    let jobID = combination["jobId"].string ?? ""
                    let job = session.jobs.first { $0.id == jobID }
                    Text("Combination \((combination["index"].integer ?? 0) + 1) · \((job?.status ?? "pending").replacingOccurrences(of: "-", with: " ").capitalized)")
                        .font(.caption.bold())
                    if job?.status == "awaiting-review" {
                        Text("Review \(job?.name ?? "this job") in the Jobs column before continuing the sweep.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(Array(combination["values"].array.enumerated()), id: \.offset) { _, value in
                        Text("\(workbenchSweepAxisLocation(value, graph: sweep["baseWorkflow"]["graph"])) · \(value["path"].string ?? "") = \(label(value["value"]))")
                            .font(.caption).textSelection(.enabled)
                    }
                    ForEach(Array(combination["variants"].array.prefix(4).enumerated()), id: \.offset) { _, variant in
                        Text("\(imageName(variant["sourceImageId"].string)) → \(imageName(variant["imageId"].string))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if combination["variants"].array.count > 4 {
                        Text("+\(combination["variants"].array.count - 4) more variants").font(.caption).foregroundStyle(.secondary)
                    }
                }.padding(8).background(.quaternary.opacity(0.3)).clipShape(RoundedRectangle(cornerRadius: 6))
            }
            ForEach(sweep["notes"].array.compactMap(\.string), id: \.self) {
                Text($0).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func chooseExportDirectory() {
        let panel = NSOpenPanel()
        panel.title = "Choose a folder for sweep packages"
        panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.allowsMultipleSelection = false; panel.canCreateDirectories = true
        panel.begin { response in if response == .OK { exportDirectory = panel.url } }
    }
    private func resetBuilder() {
        axes = []; exportDirectory = nil; sweeps.resetDiscovery()
    }
    private func imageName(_ id: String?) -> String {
        guard let id else { return "Image" }
        return session.images.first { $0.id == id }?.name ?? id
    }
    private func label(_ value: WorkbenchJSON) -> String {
        value.string ?? value.number.map { String($0) } ?? value.bool.map { $0 ? "Yes" : "No" } ?? "Canonical default"
    }
}

func workbenchSweepAxisLocation(_ value: WorkbenchJSON, graph: WorkbenchJSON = .null) -> String {
    if let nodeID = value["nodeId"].string {
        if let name = value["nodeName"].string { return name }
        if graph["nodes"].array.contains(where: { $0["id"].string == nodeID }) {
            return workbenchGraphNodeLabel(graph, id: nodeID)
        }
        return "Node \(nodeID)"
    }
    return "Step \((value["stepIndex"].integer ?? 0) + 1)"
}
