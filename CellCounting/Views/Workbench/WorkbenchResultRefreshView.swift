import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct WorkbenchResultRefreshView: View {
    @Bindable var session: WorkbenchSession
    @Bindable var refresh: WorkbenchRefreshState
    @Environment(\.dismiss) private var dismiss

    private var scopeArguments: [String: WorkbenchJSON] {
        var value: [String: WorkbenchJSON] = ["dependencyMode": .string(refresh.dependencyMode)]
        if refresh.scope == "image", let id = session.selectedImageID { value["imageIds"] = .array([.string(id)]) }
        return value
    }
    private var scanArguments: [String: WorkbenchJSON] {
        var value = scopeArguments; value["includeHistory"] = .bool(refresh.includeHistory); return value
    }
    private var planArguments: [String: WorkbenchJSON] {
        var value = scopeArguments
        value["runRefs"] = .array(refresh.selectedOutputs.sorted { $0.id < $1.id }.map(\.runRef))
        value["includeCurrent"] = .bool(refresh.includeCurrent)
        return value
    }
    private var scopeCurrent: Bool { refresh.scanArguments == .object(scanArguments) }
    private var planCurrent: Bool {
        refresh.plan != nil && refresh.planArguments == .object(planArguments) &&
            refresh.planRevision == session.revision && refresh.previewFingerprint != nil
    }
    private var canMutate: Bool { session.canRefreshWithoutDiscardingEdits && !session.hasActiveWorkers }

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack {
                Text("Result freshness").font(.title2)
                WorkbenchSavedRecordAccess(session: session, catalogues: ["refreshJobs"])
                Spacer()
                Button("Done") { dismiss() }.disabled(session.busy)
            }
            Text("Plan affected derived images, tracking, lineages, measurements and statistics in dependency order. Each checkpoint retains original acquisitions and predecessor results.")
                .font(.callout).foregroundStyle(.secondary)
            if let error = session.error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            HSplitView {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        scanControls
                        resultTable
                        planControls
                        otherOutputs
                    }.padding(.trailing, 12)
                }.frame(minWidth: 450).disabled(session.busy)
                ScrollView {
                    VStack(alignment: .leading, spacing: 11) {
                        HStack {
                            Text("Refresh runs").font(.headline)
                            Spacer()
                            Button("Refresh list", action: session.listResultRefreshes).disabled(session.busy)
                        }
                        Picker("Refresh run", selection: Binding(get: { refresh.selectedJobID }, set: {
                            session.loadResultRefresh($0)
                        })) {
                            Text("Select a refresh run").tag("")
                            ForEach(refresh.jobs) { Text("\($0.name) · \($0.status)").tag($0.id) }
                        }.disabled(session.busy)
                        if let job = refresh.selectedJob { jobControls(job) }
                        else {
                            Text("Create a plan from the selected affected results. Completed replacements remain available after stopping a run.")
                                .font(.callout).foregroundStyle(.secondary)
                        }
                    }.padding(.leading, 12)
                }.frame(minWidth: 360)
            }
            HStack {
                if session.busy { ProgressView().controlSize(.small) }
                Text(session.status).font(.caption).foregroundStyle(.secondary)
                Spacer()
            }
        }.padding(22).frame(width: 1060, height: 740)
        .task {
            if session.selectedImageID == nil { refresh.scope = "project" }
            session.inspectResultFreshness(arguments: scanArguments)
        }
    }

    private var scanControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Scope", selection: $refresh.scope) {
                Text("Current image").tag("image").disabled(session.selectedImageID == nil)
                Text("Whole project").tag("project")
            }.pickerStyle(.segmented)
            if refresh.scope == "image" {
                Text(session.selectedImage?.name ?? "Select an image").font(.callout.weight(.medium))
            }
            Picker("Dependencies", selection: $refresh.dependencyMode) {
                Text("Affected downstream results").tag("transitive")
                Text("Assays and measurement plugins only").tag("measurements")
            }
            Button("Scan saved results") { session.inspectResultFreshness(arguments: scanArguments) }
            DisclosureGroup("History and selection options") {
                VStack(alignment: .leading, spacing: 6) {
                    Toggle("Show historical results", isOn: $refresh.includeHistory)
                    Toggle("Allow current results in a new refresh", isOn: $refresh.includeCurrent)
                    Text("The default selection includes the latest stale results. Historical and current results require an explicit selection.")
                        .font(.caption).foregroundStyle(.secondary)
                }.padding(.top, 5)
            }
            if refresh.scanRevision != nil {
                Text("\(refresh.counts["current"].integer ?? 0) current · \(refresh.counts["stale"].integer ?? 0) stale · \(refresh.counts["blocked"].integer ?? 0) blocked")
                    .font(.caption)
                if !scopeCurrent {
                    Text("Scan again to apply the changed scope or history setting.").font(.caption).foregroundStyle(.orange)
                }
                if refresh.scanRevision != session.revision || refresh.planRevision.map({ $0 != session.revision }) == true {
                    Text("This report describes a different project revision. Finish edits and refresh the project before creating or running checkpoints.")
                        .font(.caption).foregroundStyle(.orange)
                    Button("Refresh project state", action: session.refresh).disabled(!canMutate)
                }
            }
        }
    }

    private var resultTable: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text("Saved outputs").font(.headline)
                Spacer()
                Button("Select latest stale") {
                    refresh.selectedOutputIDs = Set(refresh.outputs.filter { $0.latest && $0.freshness == "stale" }.map(\.id))
                }.disabled(!scopeCurrent)
                Button("Clear") { refresh.selectedOutputIDs = [] }
            }
            Table(refresh.outputs, selection: $refresh.selectedOutputIDs) {
                TableColumn("Result") { output in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(output.label).lineLimit(2)
                        Text(output.imageName).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        if !output.latest { Text("Historical").font(.caption).foregroundStyle(.secondary) }
                    }
                }
                TableColumn("Status") { output in
                    Text(output.status.capitalized).foregroundStyle(output.status == "current" ? Color.secondary : Color.orange)
                }.width(min: 55, ideal: 65)
                TableColumn("Reason") { output in
                    Text(output.messages.first ?? (output.freshness == "current" ? "Inputs match" : "Inputs changed"))
                        .font(.caption).lineLimit(3)
                }
            }.frame(minHeight: 170, maxHeight: 260)
            Text("\(refresh.selectedOutputIDs.count) selected").font(.caption).foregroundStyle(.secondary)
            if refresh.selectedOutputIDs.count != refresh.selectedOutputs.count {
                Text("Some selected results are current. Enable Allow current results or remove them from the selection before planning.")
                    .font(.caption).foregroundStyle(.orange)
            }
            DisclosureGroup("Selected result details") {
                ForEach(refresh.outputs.filter { refresh.selectedOutputIDs.contains($0.id) }) { output in
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(output.label) · \(output.imageName)").font(.caption.weight(.semibold))
                        if output.value["target"].string == "volume" {
                            Text("3D · Time \((output.value["timeIndex"].integer ?? 0) + 1) · Channel \((output.value["channel"].integer ?? 0) + 1)")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        messages(output.value["reasons"])
                        messages(output.value["blockers"])
                        if output.value["replacementRunId"].string != nil {
                            Text("A replacement result is already retained in history.").font(.caption).foregroundStyle(.secondary)
                        }
                        DisclosureGroup("Record identity") {
                            Text("\(output.kind) · \(output.runID)").font(.caption.monospaced()).textSelection(.enabled)
                            Text("Saved revision \(output.value["revision"].integer.map(String.init) ?? "—")")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }.padding(.vertical, 5)
                }
            }
        }
    }

    private var planControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            Button("Preview result refresh") { session.previewResultRefresh(arguments: planArguments) }
                .disabled(!scopeCurrent || refresh.selectedOutputs.isEmpty ||
                          refresh.selectedOutputs.count != refresh.selectedOutputIDs.count)
            if let plan = refresh.plan {
                Text("\(plan["readyCount"].integer ?? 0) ready · \(plan["blockedCount"].integer ?? 0) blocked")
                    .font(.callout.weight(.semibold))
                if plan["usesExecutableCode"].bool == true {
                    Text("This plan includes enabled local executable methods. Running checkpoints executes the retained model/plugin bindings described in the plan.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                DisclosureGroup("Ordered checkpoint plan") {
                    ForEach(Array(plan["units"].array.enumerated()), id: \.offset) { index, unit in
                        VStack(alignment: .leading, spacing: 4) {
                            Text("\(index + 1). \(unit["label"].string ?? "Result") · \(unit["status"].string ?? "pending")").font(.caption.bold())
                            Text("\(unit["imageName"].string ?? "Project") · \((unit["kind"].string ?? "").replacingOccurrences(of: "-", with: " "))")
                                .font(.caption).foregroundStyle(.secondary)
                            let dependencies = unit["dependsOn"].array.compactMap(\.string)
                            if !dependencies.isEmpty {
                                Text("After: " + dependencies.map { dependency in
                                    plan["units"].array.first { $0["id"].string == dependency || $0["unitId"].string == dependency }?["label"].string ?? "preceding retained checkpoint"
                                }.joined(separator: ", ")).font(.caption).foregroundStyle(.secondary)
                            }
                            messages(unit["reasons"]); messages(unit["blockers"])
                        }.padding(.vertical, 4)
                    }
                }
                if !plan["assignmentTransfers"].array.isEmpty {
                    DisclosureGroup("Explicit specimen assignment transfers") {
                        ForEach(Array(plan["assignmentTransfers"].array.enumerated()), id: \.offset) { _, transfer in
                            Text("\(session.images.first { $0.id == transfer["imageId"].string }?.name ?? "Acquisition") → \(session.specimens.first { $0.id == transfer["specimenId"].string }?.name ?? "Specimen") through its replacement checkpoint")
                                .font(.caption)
                        }
                        Text("Technical alternatives do not create additional biological replicates.").font(.caption).foregroundStyle(.secondary)
                    }
                }
                if (plan["blockedCount"].integer ?? 0) > 0 {
                    ForEach(Array(plan["units"].array.filter { $0["status"].string == "blocked" }.enumerated()), id: \.offset) { _, unit in
                        VStack(alignment: .leading, spacing: 3) {
                            Text("\(unit["label"].string ?? "Result") · \(unit["imageName"].string ?? "Image")")
                                .font(.caption.weight(.semibold))
                            messages(unit["blockers"])
                        }
                    }
                    Toggle("Skip these blocked results and retain their reasons", isOn: $refresh.skipBlocked)
                    Text("A completed run with skipped results still has incomplete refresh coverage.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                notes(plan["notes"])
                TextField("Refresh run name", text: $refresh.name).textFieldStyle(.roundedBorder)
                Button("Create refresh run") { session.createResultRefresh(arguments: planArguments) }
                    .disabled(!canMutate || !planCurrent || (plan["readyCount"].integer ?? 0) == 0 ||
                              ((plan["blockedCount"].integer ?? 0) > 0 && !refresh.skipBlocked))
                if !planCurrent {
                    Text("Selection or project state changed. Preview the refresh plan again before creating checkpoints.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if !canMutate {
                Text("Read-only scans preserve your drafts. Finish pending analysis edits and stop other workers before recomputing results.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text(refresh.dependencyMode == "measurements"
                 ? "Measurement-only refresh preserves masks and topology; it does not regenerate segmentation or tracking."
                 : "Transitive refresh creates explicit replacements. Ambiguous correction transfer blocks the plan; pixel propagation and review decisions remain explicit actions. Historical exports stay unchanged.")
                .font(.caption).foregroundStyle(.secondary)
            notes(.array(refresh.notes.map(WorkbenchJSON.string)))
        }
    }

    private var otherOutputs: some View {
        DisclosureGroup("Other saved results (\(refresh.unhandled.count))") {
            LazyVStack(alignment: .leading, spacing: 9) {
                ForEach(Array(refresh.unhandled.enumerated()), id: \.offset) { _, item in
                    VStack(alignment: .leading, spacing: 3) {
                        Text((item["kind"].string ?? "Saved result").replacingOccurrences(of: "-", with: " ").capitalized)
                            .font(.caption.weight(.semibold))
                        Text(item["message"].string ?? "This output requires a separate action.")
                            .font(.caption).foregroundStyle(.secondary)
                        if let action = item["action"].string {
                            Text(action).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }.padding(.top, 5)
        }
    }

    private func jobControls(_ job: WorkbenchRefreshJob) -> some View {
        let workers = session.jobWorkers.filter { $0.targetKind == "refresh" && $0.targetID == job.id }
        let active = workers.last { $0.active }
        let executionComplete = job.status == "completed"
        let coverageComplete = executionComplete && job.outputsCurrent && job.skippedCount == 0
        return VStack(alignment: .leading, spacing: 9) {
            Text(job.name).font(.headline)
            Text(job.status.capitalized).font(.callout)
            ProgressView(value: Double(job.completed), total: Double(job.total))
            Text("\(job.completed) of \(job.total) checkpoints complete").font(.caption)
            Text("Execution: \(executionComplete ? "Complete" : "Incomplete") · Refresh coverage: \(coverageComplete ? "Complete" : "Incomplete")")
                .font(.caption).foregroundStyle(coverageComplete ? Color.secondary : Color.orange)
            if job.skippedCount > 0 {
                Text("Refresh coverage is incomplete: \(job.skippedCount) blocked results were explicitly skipped.")
                    .font(.caption).foregroundStyle(.orange)
            }
            if !job.outputsCurrent {
                Text("Some saved replacements are out of date because their inputs changed after this run.")
                    .font(.caption).foregroundStyle(.orange)
            }
            if let error = job.value["error"]["message"].string ?? job.value["error"].string {
                Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
            }
            if let active {
                Text("Background worker: \(active.status)").font(.caption)
                Button(active.stopRequested ? "Stop requested" : "Stop after checkpoint") {
                    session.stopBackgroundJob(active.id)
                }.disabled(session.busy || active.stopRequested)
                Text("Stopping pauses the refresh after the current saved replacement. Completed checkpoints are retained.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                HStack {
                    if job.canAdvance {
                        Button("Run next") { session.controlResultRefresh(job.id, action: "advance") }
                        Button("Start background") { session.startBackgroundResultRefresh(job.id) }
                        Button("Pause") { session.controlResultRefresh(job.id, action: "pause") }
                    }
                    if job.status == "paused" { Button("Resume") { session.controlResultRefresh(job.id, action: "resume") } }
                    if ["failed", "blocked"].contains(job.status) {
                        Button("Retry") { session.controlResultRefresh(job.id, action: "retry") }
                    }
                }.disabled(!canMutate)
                if job.canCancel {
                    Button("Cancel remaining") { session.controlResultRefresh(job.id, action: "cancel") }.disabled(!canMutate)
                }
            }
            Button("Load checkpoint details") { session.loadResultRefresh(job.id) }.disabled(session.busy)
            if let detail = refresh.selectedDetail, detail.id == job.id,
               detail.completed == job.completed, detail.status == job.status {
                if let report = refresh.report {
                    notes(report["notes"])
                }
                DisclosureGroup("Checkpoints and retained predecessors") {
                    ForEach(Array(detail.value["units"].array.enumerated()), id: \.offset) { _, unit in
                        VStack(alignment: .leading, spacing: 4) {
                            Text("\(unit["label"].string ?? "Result") · \(unit["imageName"].string ?? "Image")")
                                .font(.caption.weight(.semibold))
                            Text((unit["status"].string ?? "pending").capitalized).font(.caption).foregroundStyle(.secondary)
                            if unit["resultRunId"].string != nil || unit["resultImageId"].string != nil {
                                Text("Replacement saved; predecessor retained.").font(.caption).foregroundStyle(.secondary)
                            }
                        }.padding(.vertical, 4)
                    }
                    ForEach(Array(detail.value["skipped"].array.enumerated()), id: \.offset) { _, unit in
                        Text("Skipped: \(unit["label"].string ?? "Result")").font(.caption.weight(.semibold))
                        messages(unit["blockers"])
                    }
                }
                DisclosureGroup("Replacement relationships") {
                    ForEach(Array(detail.value["imageReplacements"].array.enumerated()), id: \.offset) { _, replacement in
                        Text("\(session.images.first { $0.id == replacement["previousImageId"].string }?.name ?? "Original image") → \(session.images.first { $0.id == replacement["imageId"].string }?.name ?? "Retained replacement")").font(.caption)
                    }
                    ForEach(Array(detail.value["runReplacements"].array.enumerated()), id: \.offset) { _, replacement in
                        Text("\((replacement["kind"].string ?? "Result").replacingOccurrences(of: "-", with: " ").capitalized): predecessor and replacement retained").font(.caption)
                    }
                }
            }
            if !workers.isEmpty {
                DisclosureGroup("Worker history") {
                    ForEach(workers.reversed()) { worker in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(worker.status.capitalized).font(.caption)
                            if let error = worker.error { Text(error).font(.caption).foregroundStyle(.orange) }
                        }
                    }
                }
            }
            DisclosureGroup("Export refresh report") {
                VStack(alignment: .leading, spacing: 7) {
                    Picker("Format", selection: $refresh.exportFormat) {
                        ForEach(refresh.exportFormats) { Text($0.name).tag($0.id) }
                    }
                    Text(refresh.exportFormats.first { $0.id == refresh.exportFormat }?.description ??
                         "Export the complete run, including blocked skips and predecessor/replacement provenance.")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("Execution completion and refresh coverage are reported separately. Previous exported files stay unchanged.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Export report…", action: chooseExport)
                        .disabled(!canMutate || refresh.exportFormats.isEmpty)
                    if let path = refresh.exportResult?["destination"].string {
                        Button("Show refresh report in Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                        }
                    }
                }.padding(.top, 5)
            }
        }
    }
    private func messages(_ values: WorkbenchJSON) -> some View {
        ForEach(Array(values.array.enumerated()), id: \.offset) { _, item in
            if let message = item["message"].string { Text(message).font(.caption).foregroundStyle(.secondary) }
        }
    }
    private func notes(_ values: WorkbenchJSON) -> some View {
        ForEach(values.array.compactMap(\.string), id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary) }
    }
    private func chooseExport() {
        guard let format = refresh.exportFormats.first(where: { $0.id == refresh.exportFormat }) else { return }
        let refreshID = refresh.selectedJobID
        let panel = NSSavePanel()
        panel.title = "Export result refresh report"
        panel.allowedContentTypes = [UTType(filenameExtension: format.fileExtension) ?? .data]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "result-refresh.\(format.fileExtension)"
        panel.begin { result in
            guard result == .OK, let url = panel.url else { return }
            guard refresh.selectedJobID == refreshID, refresh.exportFormat == format.id else {
                session.error = "The selected refresh run or format changed. Choose the intended report and export again."; return
            }
            session.exportResultRefresh(to: url)
        }
    }
}
