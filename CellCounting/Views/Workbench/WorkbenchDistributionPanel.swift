import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct WorkbenchDistributionPanel: View {
    @Bindable var session: WorkbenchSession
    @Bindable var distribution: WorkbenchDistributionState
    let workflow: WorkbenchWorkflow?
    let imageIDs: Set<String>
    let timeIndices: [Int]?

    private var planArguments: [String: WorkbenchJSON] {
        var value: [String: WorkbenchJSON] = [
            "workflowId": .string(workflow?.id ?? ""),
            "workflowVersion": .number(Double(workflow?.version ?? 1)),
            "imageIds": .array(imageIDs.sorted().map(WorkbenchJSON.string))
        ]
        if let timeIndices { value["timeIndices"] = .array(timeIndices.map { .number(Double($0)) }) }
        return value
    }
    private var planCurrent: Bool {
        distribution.plan != nil && distribution.planArguments == .object(planArguments) &&
            distribution.planRevision == session.revision
    }
    private var canMutate: Bool { session.canRefreshWithoutDiscardingEdits && !session.hasActiveWorkers }
    private var previewCurrent: Bool {
        distribution.resultPreview != nil && distribution.resultRevision == session.revision &&
            distribution.resultDistributionID == distribution.selectedID &&
            distribution.resultTaskID == distribution.selectedTaskID
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let localTask = distribution.localTask {
                restoredTask(localTask)
                Divider()
            }
            Text("Create one portable task for each selected image and time point. Each task runs the complete saved workflow in its own restored project.")
                .font(.caption).foregroundStyle(.secondary)
            DisclosureGroup("Create work packets") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Uses the saved workflow, images and time scope selected above.")
                        .font(.caption).foregroundStyle(.secondary)
                    if workflow?.isGraph == true {
                        Text("Each task contains the entire saved graph for one source image and time point. Source selectors, node connections and method versions remain frozen; branches are not distributed as unrelated jobs.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    TextField("Distribution name", text: $distribution.name).textFieldStyle(.roundedBorder)
                    Button("Preview work packets") { session.previewDistribution(arguments: planArguments) }
                        .disabled(workflow == nil || imageIDs.isEmpty)
                    if let plan = distribution.plan {
                        Text("\(plan["taskCount"].integer ?? 0) tasks · \(plan["workflow"]["name"].string ?? "Saved workflow") v\(plan["workflow"]["version"].integer ?? 1)")
                            .font(.callout.weight(.semibold))
                        if plan["workflow"]["kind"].string == "dag" {
                            Text("Complete branching workflows · \(plan["nodeCheckpointCount"].integer ?? 0) scientific node checkpoints across all tasks")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        DisclosureGroup("Planned inputs") {
                            ForEach(Array(plan["tasks"].array.enumerated()), id: \.offset) { offset, task in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("\(offset + 1). \(task["imageName"].string ?? "Image")").font(.caption)
                                    Text(selectionLabel(task)).font(.caption).foregroundStyle(.secondary)
                                    if let nodes = task["nodeCheckpointCount"].integer {
                                        Text("\(nodes) node checkpoints · \(task["newImageCount"].integer ?? 0) new images · \(task["segmentationBranchCount"].integer ?? 0) separate segmentation branches")
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                        requirements(plan["requirements"])
                        notes(plan["notes"])
                        if !planCurrent {
                            Text("The workflow selection or project changed. Preview the work packets again before creating them.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Button("Create distribution") { session.createDistribution(arguments: planArguments) }
                            .disabled(!canMutate || !planCurrent || distribution.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }.padding(.top, 6)
            }
            Divider()
            Picker("Distribution", selection: Binding(get: { distribution.selectedID }, set: {
                session.loadDistribution($0)
            })) {
                Text("Select distributed work").tag("")
                ForEach(distribution.groups) { Text($0.name).tag($0.id) }
            }
            if !distribution.selectedID.isEmpty {
                Button("Refresh distribution") { session.loadDistribution(distribution.selectedID) }
            }
            if let group = distribution.detail {
                let current = distribution.currentGroup ?? group
                Text("\(current.collectedCount) of \(current.taskCount) results collected · \(current.status.capitalized)")
                    .font(.caption)
                if !current.sourceInputsCurrent {
                    Text("Coordinator source inputs changed after this distribution was created. Returned results must pass the original task and version checks before collection.")
                        .font(.caption).foregroundStyle(.orange)
                }
                Table(group.tasks, selection: $distribution.selectedTaskID) {
                    TableColumn("Task") { task in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(taskName(task)).lineLimit(2)
                            Text(selectionLabel(task.value)).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    TableColumn("State", value: \.status).width(min: 65, ideal: 75)
                }.frame(minHeight: 130, maxHeight: 210)
                if let task = distribution.selectedTask {
                    taskActions(task, group: group)
                }
                notes(group.value["notes"])
            } else if distribution.groups.isEmpty {
                Text("Create a distribution to export work packets and collect returned results here.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !canMutate {
                Text("Finish pending analysis edits and stop active workers before creating, exporting, preparing or collecting work.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !distribution.message.isEmpty {
                Text(distribution.message).font(.caption).foregroundStyle(.secondary)
            }
            if let path = distribution.lastExportPath {
                Button("Show exported packet in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                }
            }
        }
    }

    private func taskActions(_ task: WorkbenchDistributedTask, group: WorkbenchDistribution) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Selected: \(taskName(task))").font(.caption.weight(.semibold))
            HStack {
                Button("Export task bundle…") { chooseTaskExport(task: task, collected: false) }
                    .disabled(!canMutate)
                Button("Preview returned result…", action: chooseResult)
            }
            Text("On the worker machine, choose Project → Restore analysis package. Review local model and plugin setup, prepare the runnable job below, then use the existing job controls.")
                .font(.caption).foregroundStyle(.secondary)
            if let preview = distribution.resultPreview,
               distribution.resultDistributionID == group.id, distribution.resultTaskID == task.id {
                VStack(alignment: .leading, spacing: 7) {
                    Text("Returned result").font(.callout.weight(.semibold))
                    Text(URL(fileURLWithPath: distribution.resultPath).lastPathComponent).font(.caption).textSelection(.enabled)
                    if let job = WorkbenchJob(preview["job"]) {
                        Text("\(job.name) · \(job.status.capitalized) · \(job.completed)/\(job.total) checkpoints")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if preview["summary"]["kind"].string == "dag" {
                        returnedGraphSummary(preview["summary"], graph: preview["job"]["workflow"]["graph"])
                    } else {
                        if let count = preview["summary"]["cellCount"].integer {
                            Text("\(count) 2D object observations").font(.caption).foregroundStyle(.secondary)
                        }
                        if let count = preview["summary"]["volumes"]["cellCount"].integer {
                            Text("\(count) 3D object observations").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    runtimeDifferences(preview["runtimeDifferences"])
                    notes(preview["notes"])
                    Text("Collection retains this result as an isolated project. It does not merge masks or biological assignments into the coordinator.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Collect isolated result", action: session.collectDistributedResult)
                        .disabled(!canMutate || !previewCurrent)
                    if !previewCurrent {
                        Button("Preview result again") {
                            session.previewDistributedResult(at: URL(fileURLWithPath: distribution.resultPath))
                        }
                        Text("The coordinator changed after preview. Validate the returned package again before collection.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }.padding(9).background(.quaternary.opacity(0.25)).clipShape(RoundedRectangle(cornerRadius: 7))
            }
            if task.status == "collected" {
                Button("Export collected result…") { chooseTaskExport(task: task, collected: true) }
                    .disabled(!canMutate)
                Text("Restore the exported result as a separate project to inspect its images, masks and measurements.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func restoredTask(_ task: WorkbenchJSON) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Restored work task").font(.headline)
            Text("\(task["workflow"]["name"].string ?? "Saved workflow") · \(selectionLabel(task))")
                .font(.caption).foregroundStyle(.secondary)
            if task["workflow"]["kind"].string == "dag" {
                Text("This task runs one complete branching workflow. Completed node outputs remain together in the final result package, with their original source relationships.")
                    .font(.caption).foregroundStyle(.secondary)
                DisclosureGroup("Frozen branch connections") {
                    WorkbenchWorkflowGraphRelationships(graph: task["workflow"]["graph"])
                }
            }
            requirements(task["requirements"])
            if !task["runtime"]["currentDifferences"].array.isEmpty {
                runtimeDifferences(task["runtime"]["currentDifferences"])
                Text(task["prepared"].bool == true
                    ? "The local environment changed after preparation. To execute with a different runtime, restore a fresh original task bundle and prepare it explicitly."
                    : "Review these local runtime differences before preparing the task.")
                    .font(.caption).foregroundStyle(.orange)
            }
            if task["prepared"].bool == true {
                if let job = distribution.localJob {
                    Text("\(job.name) · \(job.status.capitalized) · \(job.completed)/\(job.total) checkpoints")
                        .font(.callout)
                    Text("Use this job’s existing controls to run, pause, resume or start it in the background.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Export completed result…", action: chooseCompletedResult)
                        .disabled(!canMutate || job.status != "completed" || !job.outputsCurrent)
                    Text("Export again after the job is completed. A workflow’s own export step captures a pre-completion snapshot and cannot serve as the returned result.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else {
                if task["requirements"]["requiresExportDestination"].bool == true {
                    Button("Choose workflow export destination…", action: chooseRemoteExport)
                    Text(distribution.taskExportDestination?.lastPathComponent ?? "Required before preparing this job")
                        .font(.caption).foregroundStyle(.secondary)
                }
                DisclosureGroup("Runtime compatibility") {
                    VStack(alignment: .leading, spacing: 7) {
                        runtimeDifferences(task["runtime"]["differences"])
                        Toggle("Allow recorded runtime differences", isOn: $distribution.allowRuntimeDifferences)
                        Text("Preparation normally requires matching runtime versions. Allowing differences records them in the returned result; it does not enable plugins or models.")
                            .font(.caption).foregroundStyle(.secondary)
                    }.padding(.top, 5)
                }
                Button("Prepare runnable job", action: session.prepareDistributedTask)
                    .disabled(!canMutate || (task["requirements"]["requiresExportDestination"].bool == true &&
                                             distribution.taskExportDestination == nil))
            }
        }.padding(10).background(.quaternary.opacity(0.25)).clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func requirements(_ value: WorkbenchJSON) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            let plugins = value["pluginIds"].array.compactMap(\.string)
            let models = value["modelIds"].array.compactMap(\.string)
            if !plugins.isEmpty || !models.isEmpty {
                Text("Executable dependencies").font(.caption.weight(.semibold))
                ForEach(plugins, id: \.self) { id in
                    let plugin = session.extensions.plugins.first { $0.id == id }
                    Text("Plugin: \(plugin?.name ?? id) · \(plugin?.enabled == true && plugin?.available == true ? "Enabled locally" : "Local setup required")")
                        .font(.caption).foregroundStyle(.secondary)
                }
                ForEach(models, id: \.self) { id in
                    let model = session.models.models.first { $0.id == id }
                    Text("Model: \(model?.name ?? id) · \(model?.enabled == true ? "Enabled locally" : "Local setup required")")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text("On the worker machine, review and enable local plugins under Workflows. Configure model interpreters and enable models under Segmentation & correction → Registered models. Preparation does not grant executable trust.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func returnedGraphSummary(_ summary: WorkbenchJSON, graph: WorkbenchJSON) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("Separate branch results").font(.caption.weight(.semibold))
            Text("Technical alternatives are retained separately. Counts are not pooled across branches or treated as biological replicates.")
                .font(.caption).foregroundStyle(.secondary)
            ForEach(Array(summary["branches"].array.enumerated()), id: \.offset) { _, branch in
                DisclosureGroup(workbenchGraphNodeLabel(graph, id: branch["nodeId"].string ?? "")) {
                    ForEach(Array(branch["records"].array.enumerated()), id: \.offset) { _, record in
                        VStack(alignment: .leading, spacing: 4) {
                            Text("\(session.images.first { $0.id == record["sourceImageId"].string }?.name ?? "Task acquisition") · \(workbenchGraphSelectionLabel(record["sourceSelection"]))")
                                .font(.caption)
                            if let count = record["summary"]["cellCount"].integer {
                                Text("\(count) object observations in this branch").font(.caption).foregroundStyle(.secondary)
                            }
                            WorkbenchStructuredOutput(value: record["summary"]).frame(height: 160)
                        }
                    }
                }
            }
        }
    }

    private func runtimeDifferences(_ values: WorkbenchJSON) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if !values.array.isEmpty {
                Text("\(values.array.count) recorded runtime differences").font(.caption.weight(.semibold))
                ForEach(Array(values.array.enumerated()), id: \.offset) { _, value in
                    Text(value.string ?? value["message"].string ?? value["component"].string ?? "Runtime dependency differs")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
    private func notes(_ value: WorkbenchJSON) -> some View {
        ForEach(value.array.compactMap(\.string), id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary) }
    }
    private func taskName(_ task: WorkbenchDistributedTask) -> String {
        "\(task.index + 1). \(session.images.first { $0.id == task.sourceImageID }?.name ?? "Image")"
    }
    private func selectionLabel(_ task: WorkbenchJSON) -> String {
        if task["target"].string == "volume" {
            return "3D · Time \((task["timeIndex"].integer ?? 0) + 1) · Channel \((task["channel"].integer ?? 0) + 1)"
        }
        return "2D · Saved projection and channel"
    }

    private func chooseTaskExport(task: WorkbenchDistributedTask, collected: Bool) {
        let groupID = distribution.selectedID
        let panel = NSSavePanel()
        panel.title = collected ? "Export collected result project" : "Export portable work task"
        panel.allowedContentTypes = [.zip]; panel.canCreateDirectories = true
        panel.nameFieldStringValue = "task-\(task.index + 1)-\(collected ? "result" : "bundle").zip"
        panel.message = collected ? "Save a new package for separate restoration and inspection."
            : "Save a new package to restore as an isolated project on another machine."
        panel.begin { result in
            guard result == .OK, let url = panel.url else { return }
            guard distribution.selectedID == groupID, distribution.selectedTaskID == task.id else {
                session.error = "The selected work task changed. Select the intended task and export again."
                return
            }
            session.exportDistributionTask(to: url, collected: collected)
        }
    }
    private func chooseResult() {
        let groupID = distribution.selectedID
        let taskID = distribution.selectedTaskID
        let panel = NSOpenPanel()
        panel.title = "Preview returned task result"
        panel.message = "Choose the final project ZIP exported after the worker job completed."
        panel.allowedContentTypes = [.zip]; panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.begin { result in
            guard result == .OK, let url = panel.url else { return }
            guard distribution.selectedID == groupID, distribution.selectedTaskID == taskID else {
                session.error = "The selected work task changed. Select the intended task and preview its returned result again."
                return
            }
            session.previewDistributedResult(at: url)
        }
    }
    private func chooseRemoteExport() {
        let taskID = distribution.localTask?["id"].string
        let panel = NSSavePanel()
        panel.title = "Choose restored workflow export destination"
        panel.message = "Choose a new file. This workflow export is separate from the final completed result package."
        panel.allowedContentTypes = [.zip]; panel.canCreateDirectories = true
        panel.nameFieldStringValue = "work-task-workflow.zip"
        panel.begin { result in
            if result == .OK, distribution.localTask?["id"].string == taskID {
                distribution.taskExportDestination = panel.url
            }
        }
    }
    private func chooseCompletedResult() {
        let taskID = distribution.localTask?["id"].string
        let projectPath = session.projectPath
        let panel = NSSavePanel()
        panel.title = "Export completed work result"
        panel.message = "Export the completed project to a new ZIP, then return it to the coordinator for collection."
        panel.allowedContentTypes = [.zip]; panel.canCreateDirectories = true
        panel.nameFieldStringValue = "completed-work-result.zip"
        panel.begin { result in
            guard result == .OK, let url = panel.url else { return }
            guard session.projectPath == projectPath, distribution.localTask?["id"].string == taskID,
                  distribution.localJob?.status == "completed", distribution.localJob?.outputsCurrent == true,
                  canMutate else {
                session.error = "The restored task or its current completion state changed. Refresh the task before exporting the completed result."
                return
            }
            session.export(to: url)
        }
    }
}
