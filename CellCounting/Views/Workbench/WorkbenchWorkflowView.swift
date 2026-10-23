import AppKit
import SwiftUI
import UniformTypeIdentifiers

private struct WorkbenchWorkflowPluginNode: Identifiable {
    let id = UUID()
    var kind = "plugin-measurement"
    var pluginID: String
    var parameters: [String: WorkbenchJSON]
    var retained: WorkbenchJSON? = nil
    var json: WorkbenchJSON {
        var value = retained?.object ?? [:]
        value["type"] = .string(kind)
        if kind == "assay" {
            value["assay"] = .string(pluginID); value["assayParameters"] = .object(parameters)
        } else if kind == "plugin-measurement" {
            value["pluginId"] = .string(pluginID); value["pluginParameters"] = .object(parameters)
        }
        return .object(value)
    }
}

struct WorkbenchWorkflowView: View {
    @Bindable var session: WorkbenchSession
    var embedded = false
    @Environment(\.dismiss) private var dismiss
    @State private var name = "Image analysis"
    @State private var includeExport = false
    @State private var updateSelected = false
    @State private var imageIDs: Set<String> = []
    @State private var exportDestination: URL?
    @State private var allTimePoints = true
    @State private var segmentationPluginID = ""
    @State private var segmentationParameters: [String: WorkbenchJSON] = [:]
    @State private var measurementNodes: [WorkbenchWorkflowPluginNode] = []
    @State private var modelSettings = WorkbenchModelInferenceSettings()
    @State private var includePreprocessing = false
    @State private var recipe: [WorkbenchPreprocessingStep] = []
    @State private var loadedAnalysis: WorkbenchJSON?
    @State private var loadedWorkflowID: String?
    @State private var retainedPreprocessingStep: WorkbenchJSON?
    @State private var retainedExportStep: WorkbenchJSON?
    @State private var distributionExpanded = false
    @State private var workflowStructure = "linear"

    private var builderVolume: Bool {
        if let step = loadedAnalysis {
            return step["type"].string == "volume-analysis" || step["target"].string == "volume"
        }
        return session.viewingVolume
    }
    private var preprocessingFilters: [WorkbenchPreprocessingFilter] {
        session.preprocessing.filters.filter { $0.dimensions.contains(builderVolume ? 3 : 2) }
    }
    private var invalidRecipe: Bool {
        includePreprocessing && (recipe.isEmpty || recipe.contains { step in !preprocessingFilters.contains { $0.id == step.method } })
    }
    private var maximumNodes: Int { min(16, 17 - (includePreprocessing ? 1 : 0) - (includeExport ? 1 : 0)) }

    private var compatiblePlugins: [WorkbenchPlugin] {
        session.extensions.plugins.filter {
            $0.enabled && $0.available && $0.dimensions.contains(builderVolume ? 3 : 2)
        }
    }
    private var segmenters: [WorkbenchPlugin] { compatiblePlugins.filter { $0.kind == "segmentation" } }
    private var measurementPlugins: [WorkbenchPlugin] { compatiblePlugins.filter { $0.kind == "measurement" } }
    private var assays: [WorkbenchAssay] { session.assays.catalog.filter { $0.dimensions.contains(builderVolume ? 3 : 2) } }
    private var modelID: String? {
        segmentationPluginID.hasPrefix("model:") ? String(segmentationPluginID.dropFirst(6)) : nil
    }
    private var selectedModel: WorkbenchRegisteredModel? {
        guard let modelID else { return nil }
        return session.models.models.first { $0.id == modelID && $0.enabled }
    }
    private var invalidMethod: Bool {
        if modelID != nil { return builderVolume || selectedModel == nil || !modelSettings.valid }
        return !segmentationPluginID.isEmpty && !segmenters.contains { $0.id == segmentationPluginID }
    }
    private var unavailableMethod: Bool {
        guard !segmentationPluginID.isEmpty else { return false }
        return modelID != nil ? selectedModel == nil : !segmenters.contains { $0.id == segmentationPluginID }
    }
    private var invalidNodes: Bool {
        measurementNodes.contains { node in
            node.kind == "assay"
                ? !assays.contains { $0.id == node.pluginID }
                : node.kind != "plugin-measurement" || !measurementPlugins.contains { $0.id == node.pluginID }
        }
    }

    private var selectedWorkflow: WorkbenchWorkflow? {
        session.workflows.first { $0.id == session.selectedWorkflowID }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Saved workflows").font(.title2)
                WorkbenchSavedRecordAccess(session: session, catalogues: ["workflows", "jobs", "sweeps", "jobWorkers", "distributions"])
                Spacer()
                Button("Refresh", action: session.loadWorkflows).disabled(session.busy)
                if !embedded { Button("Done") { dismiss() } }
            }
            Text("A workflow uses fixed settings and saves each completed image. Resume interrupted jobs from the last completed checkpoint.")
                .font(.callout).foregroundStyle(.secondary)
            if let error = session.error { Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled) }
            HSplitView {
                ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    DisclosureGroup("Create or edit workflow") {
                        VStack(alignment: .leading, spacing: 10) {
                            Picker("Workflow structure", selection: $workflowStructure) {
                                Text("Linear").tag("linear")
                                Text("Branching").tag("branching")
                            }.pickerStyle(.segmented)
                            if workflowStructure == "branching" {
                                WorkbenchWorkflowGraphEditor(session: session, graph: session.workflowGraph, imageIDs: imageIDs)
                            } else {
                            TextField("Workflow name", text: $name).textFieldStyle(.roundedBorder)
                            Toggle("Preprocess each source before segmentation", isOn: $includePreprocessing)
                            if includePreprocessing {
                                stepCard("1", "Create processed acquisition", "The selected channel becomes a separate source with its recipe retained.")
                                WorkbenchPreprocessingRecipeEditor(steps: $recipe, filters: preprocessingFilters)
                                Text("Later steps use channel 1 of the processed acquisition. Multi-channel assays and fixed nuclear mask references cannot be used after this single-channel recipe. Assign processed images to specimens explicitly.")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            if let loadedAnalysis {
                                Text("Loaded settings: \(stepLabel(loadedAnalysis))").font(.caption).foregroundStyle(.secondary)
                                Button("Use current image settings instead") { resetAnalysisToCurrent() }
                            }
                            Picker("Segmentation method", selection: Binding(get: { segmentationPluginID }, set: chooseSegmentation)) {
                                Text("Current threshold and watershed settings").tag("")
                                ForEach(segmenters) { Text("\($0.name) · v\($0.version)").tag($0.id) }
                                if !builderVolume {
                                    ForEach(session.models.models.filter(\.enabled)) {
                                        Text("\($0.name) · \($0.backend)").tag("model:\($0.id)")
                                    }
                                }
                                if unavailableMethod {
                                    Text("\(segmentationPluginID) · Unavailable").tag(segmentationPluginID)
                                }
                            }
                            if let model = selectedModel {
                                stepCard(includePreprocessing ? "2" : "1", "Registered model segmentation", model.name)
                                WorkbenchModelInferenceControls(settings: $modelSettings)
                                ForEach(model.notes, id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary) }
                            } else if let plugin = segmenters.first(where: { $0.id == segmentationPluginID }) {
                                stepCard(includePreprocessing ? "2" : "1", "Plugin segmentation", "\(plugin.name) · \(builderVolume ? "3D volume" : "2D plane")")
                                WorkbenchPluginParameters(definitions: plugin.parameters, values: $segmentationParameters)
                            } else {
                            if let loadedAnalysis {
                                stepCard(includePreprocessing ? "2" : "1", "Saved segmentation settings", stepLabel(loadedAnalysis))
                            } else if builderVolume {
                                stepCard(includePreprocessing ? "2" : "1", "Analyze volumes", "\(session.volume.method == "manual" ? "Manual threshold" : "Otsu") · Channel \(session.volume.channel + 1) · 3D watershed")
                            } else {
                                stepCard(includePreprocessing ? "2" : "1", "Analyze images", "\(WorkbenchClassicalMethod.title(session.method)) · Channel \(session.channel + 1) · \(session.projection) projection")
                            }
                            }
                            ForEach($measurementNodes) { $node in
                                VStack(alignment: .leading, spacing: 8) {
                                    HStack {
                                        Text(node.kind == "assay" ? "Assay" : node.kind == "plugin-measurement"
                                             ? "Plugin measurement" : "Saved step: \(node.kind)").font(.callout.bold())
                                        Spacer()
                                        Button { moveNode(node.id, offset: -1) } label: { Image(systemName: "arrow.up") }
                                            .disabled(measurementNodes.first?.id == node.id)
                                        Button { moveNode(node.id, offset: 1) } label: { Image(systemName: "arrow.down") }
                                            .disabled(measurementNodes.last?.id == node.id)
                                        Button { measurementNodes.removeAll { $0.id == node.id } } label: { Image(systemName: "minus.circle") }
                                    }
                                    Picker("Method", selection: Binding(get: { node.pluginID }, set: { id in
                                        node.pluginID = id; node.retained = nil
                                        node.parameters = node.kind == "assay"
                                            ? assays.first { $0.id == id }?.initialParameters ?? [:]
                                            : measurementPlugins.first { $0.id == id }?.initialParameters ?? [:]
                                    })) {
                                        if node.kind == "assay" {
                                            ForEach(assays) { Text($0.name).tag($0.id) }
                                        } else {
                                            ForEach(measurementPlugins) { Text("\($0.name) · v\($0.version)").tag($0.id) }
                                        }
                                        if !(node.kind == "assay" ? assays.contains { $0.id == node.pluginID }
                                              : measurementPlugins.contains { $0.id == node.pluginID }) {
                                            Text("\(node.pluginID.isEmpty ? node.kind : node.pluginID) · Unavailable").tag(node.pluginID)
                                        }
                                    }
                                    if node.kind == "assay", let assay = assays.first(where: { $0.id == node.pluginID }) {
                                        WorkbenchAssayParameterControls(session: session, assay: assay, values: $node.parameters)
                                        if assay.id == "nuclear_cytoplasmic" {
                                            Text("The nuclear image is a fixed reference. Every job image must share its original acquisition and projection.")
                                                .font(.caption).foregroundStyle(.secondary)
                                        }
                                    } else if let plugin = measurementPlugins.first(where: { $0.id == node.pluginID }) {
                                        WorkbenchPluginParameters(definitions: plugin.parameters, values: $node.parameters)
                                    } else {
                                        Text("This saved step is unavailable in the current project. It is retained; choose a replacement or remove it explicitly before saving.")
                                            .font(.caption).foregroundStyle(.orange)
                                    }
                                }.padding(10).background(.quaternary.opacity(0.3)).clipShape(RoundedRectangle(cornerRadius: 8))
                            }
                            Button("Add plugin measurement", systemImage: "plus") {
                                if let plugin = measurementPlugins.first {
                                    measurementNodes.append(WorkbenchWorkflowPluginNode(pluginID: plugin.id, parameters: plugin.initialParameters))
                                }
                            }.disabled(measurementPlugins.isEmpty || measurementNodes.count >= maximumNodes)
                            Button("Add assay", systemImage: "plus") {
                                if let assay = assays.first {
                                    measurementNodes.append(WorkbenchWorkflowPluginNode(kind: "assay", pluginID: assay.id,
                                                                                        parameters: assay.initialParameters))
                                }
                            }.disabled(assays.isEmpty || measurementNodes.count >= maximumNodes)
                            stepCard("\(2 + measurementNodes.count + (includePreprocessing ? 1 : 0))", builderVolume ? "Measure volumes" : "Measure objects",
                                     builderVolume ? "Voxel counts, calibrated volumes, centroids and source intensity" : "Area, calibrated diameter and source intensity")
                            stepCard("\(3 + measurementNodes.count + (includePreprocessing ? 1 : 0))", "Summarize", "Descriptive image and project results")
                            if !segmentationPluginID.isEmpty || !measurementNodes.isEmpty {
                                Text("Saving pins model or plugin identities and parameters. Executable methods must remain explicitly enabled for the job.")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Toggle("Include a ZIP export step", isOn: $includeExport)
                            if includeExport {
                                stepCard("\(4 + measurementNodes.count + (includePreprocessing ? 1 : 0))", "Export package", "Choose a new destination when creating each job")
                                if let destination = retainedExportStep?["destination"].string {
                                    Text("Saved destination retained: \(destination)").font(.caption).textSelection(.enabled)
                                    Button("Remove fixed destination from workflow") { retainedExportStep = nil }
                                }
                            }
                            Toggle("Save a new version of the loaded workflow", isOn: $updateSelected)
                                .disabled(loadedWorkflowID == nil || loadedWorkflowID != selectedWorkflow?.id)
                            Button("Save workflow") {
                                session.saveWorkflow(name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                                    updateID: updateSelected ? loadedWorkflowID : nil, includeExport: includeExport,
                                    segmentationPlugin: segmentationPluginID.isEmpty || modelID != nil ? nil : segmentationPluginID,
                                    segmentationParameters: segmentationParameters, measurementPlugins: measurementNodes.map(\.json),
                                    registeredModel: modelID, modelParameters: modelSettings.values,
                                    preprocessingRecipe: includePreprocessing ? recipe.map(\.json) : [],
                                    analysisOverride: loadedAnalysis, preprocessingOverride: retainedPreprocessingStep,
                                    exportOverride: retainedExportStep)
                            }
                            .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                                invalidMethod || invalidNodes || invalidRecipe || measurementNodes.count > maximumNodes)
                            }
                        }.padding(.top, 8)
                    }
                    Divider()
                    Picker("Workflow", selection: $session.selectedWorkflowID) {
                        Text("Select a workflow").tag("")
                        ForEach(session.workflows) { workflow in
                            Text("\(workflow.name) · v\(workflow.version)").tag(workflow.id)
                        }
                    }
                    if let workflow = selectedWorkflow {
                        Button("Load selected workflow into builder") { loadWorkflow(workflow) }
                        if workflow.isGraph {
                            WorkbenchWorkflowGraphRelationships(graph: workflow.graph)
                            Text("Each segmentation branch creates a separate technical alternative for every selected source and time point. The summary retains those relationships.")
                                .font(.caption).foregroundStyle(.secondary)
                        } else {
                            Text(workflow.steps.enumerated().map { index, step in
                                "\(index + 1). \(stepLabel(step))"
                            }.joined(separator: "\n")).font(.caption).foregroundStyle(.secondary)
                        }
                        if workflow.analyzesVolumes {
                            Toggle("Analyze all time points", isOn: $allTimePoints)
                            if !allTimePoints {
                                Text("Time \(session.volume.timeIndex + 1) for each selected image. This time must exist in every image.")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        if workflow.exportsPackage {
                            HStack {
                                Button("Choose export destination…", action: chooseExport)
                                Text(exportDestination?.lastPathComponent ?? "Required for this job").font(.caption)
                            }
                        }
                    }
                    WorkbenchImageSelection(session: session, selection: $imageIDs)
                    Button("Create job for \(imageIDs.count) images") {
                        session.createJob(imageIDs: imageIDs,
                            exportDestination: selectedWorkflow?.exportsPackage == true ? exportDestination : nil,
                            timeIndices: selectedWorkflow?.analyzesVolumes == true && !allTimePoints
                                ? [session.volume.timeIndex] : nil)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(selectedWorkflow == nil || imageIDs.isEmpty ||
                              !session.canRefreshWithoutDiscardingEdits || session.hasActiveWorkers ||
                              (selectedWorkflow?.exportsPackage == true && exportDestination == nil))
                    Divider()
                    DisclosureGroup("Parameter sweeps") {
                        WorkbenchSweepPanel(session: session, sweeps: session.sweeps,
                            workflow: selectedWorkflow, imageIDs: imageIDs,
                            timeIndices: selectedWorkflow?.analyzesVolumes == true && !allTimePoints
                                ? [session.volume.timeIndex] : nil)
                            .padding(.top, 8)
                    }
                    DisclosureGroup("Distributed work", isExpanded: $distributionExpanded) {
                        WorkbenchDistributionPanel(session: session, distribution: session.distribution,
                            workflow: selectedWorkflow, imageIDs: imageIDs,
                            timeIndices: selectedWorkflow?.analyzesVolumes == true && !allTimePoints
                                ? [session.volume.timeIndex] : nil)
                            .padding(.top, 8)
                    }
                }
                }
                .padding(.trailing, 12).frame(minWidth: 330)
                .disabled(session.busy)

                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        Text("Jobs").font(.headline)
                        if session.jobs.isEmpty {
                            Text("Create a job from a saved workflow to begin.").foregroundStyle(.secondary)
                        }
                        ForEach(session.jobs.reversed()) { job in
                            jobCard(job)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 12)
                }.frame(minWidth: 330)
            }
            HStack {
                if session.busy { ProgressView().controlSize(.small) }
                Text(session.status).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(embedded ? 16 : 22)
        .frame(width: embedded ? nil : 1020, height: embedded ? nil : 730)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            imageIDs = Set(session.selectedImageID.map { [$0] } ?? [])
            distributionExpanded = session.distribution.localTask != nil
            session.loadWorkflows()
        }
        .onChange(of: session.distribution.localTask?["id"].string) { _, id in
            if id != nil { distributionExpanded = true }
        }
        .onChange(of: session.selectedWorkflowID) { _, _ in exportDestination = nil; updateSelected = false }
        .onChange(of: includePreprocessing) { _, enabled in
            if enabled && recipe.isEmpty, let filter = preprocessingFilters.first {
                recipe = [WorkbenchPreprocessingStep(method: filter.id, values: filter.defaults)]
            }
        }
    }

    private func stepCard(_ number: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(number).font(.caption.bold()).padding(5).background(.quaternary).clipShape(Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout.bold())
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func stepLabel(_ step: WorkbenchJSON) -> String {
        switch step["type"].string {
        case "preprocessing":
            return "Preprocessing: " + step["recipe"].array.map { $0["method"].string ?? "Filter" }.joined(separator: " → ")
        case "analysis":
            let parameters = step["parameters"]
            let method = WorkbenchClassicalMethod.title(parameters["method"].string ?? "otsu")
            return "\(method), channel \((parameters["channel"].integer ?? 0) + 1), \(parameters["zProjection"].string ?? "max") projection"
        case "volume-analysis":
            let method = step["parameters"]["method"].string == "manual" ? "Manual threshold" : "Otsu"
            return "3D \(method), channel \((step["channel"].integer ?? 0) + 1)"
        case "measurements": return "Object measurements"
        case "plugin-segmentation": return "Plugin segmentation: \(step["pluginId"].string ?? "Unknown") (\(step["target"].string == "volume" ? "3D" : "2D"))"
        case "plugin-measurement": return "Plugin measurements: \(step["pluginId"].string ?? "Unknown")"
        case "model-segmentation":
            return "Registered model: \(session.models.models.first { $0.id == step["modelId"].string }?.name ?? step["modelId"].string ?? "Unknown")"
        case "assay": return "Assay: \(session.assays.catalog.first { $0.id == step["assay"].string }?.name ?? step["assay"].string ?? "Unknown")"
        case "summary": return "Project summary"
        case "export": return "ZIP analysis package"
        default: return step["type"].string ?? "Unknown step"
        }
    }

    private func jobCard(_ job: WorkbenchJob) -> some View {
        let workers = session.jobWorkers.filter { $0.targetKind == "job" && $0.targetID == job.id }
        let activeWorker = workers.last { $0.active }
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(job.name).font(.headline)
                Spacer()
                Text(job.status.replacingOccurrences(of: "-", with: " ").capitalized).font(.caption)
            }
            ProgressView(value: Double(job.completed), total: Double(job.total))
            Text("\(job.completed) of \(job.total) checkpoints complete").font(.caption)
            if let next = job.nextType, !job.isGraph {
                let nextName = job.nextImageID.flatMap { id in session.images.first { $0.id == id }?.name } ?? next
                Text("Next: \(nextName)").font(.caption).foregroundStyle(.secondary)
                if let workingID = job.nextWorkingImageID, workingID != job.nextImageID {
                    Text("Processed acquisition: \(session.images.first { $0.id == workingID }?.name ?? workingID)")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let step = job.nextStepIndex {
                    Text("Analysis step \(step + 1)").font(.caption).foregroundStyle(.secondary)
                }
                if let time = job.nextTimeIndex, let channel = job.nextChannel {
                    let workingTime = job.nextWorkingSelection["timeIndex"].integer ?? time
                    let workingChannel = job.nextWorkingSelection["channel"].integer ?? channel
                    Text("Time \(workingTime + 1) · Channel \(workingChannel + 1)").font(.caption).foregroundStyle(.secondary)
                }
            }
            let processed = job.workingImageIDs.filter { !job.sourceImageIDs.contains($0) }
            if !processed.isEmpty && !job.isGraph {
                Text("Processed results: \(processed.prefix(5).map { id in session.images.first { $0.id == id }?.name ?? id }.joined(separator: ", "))\(processed.count > 5 ? " …" : "")")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let error = job.error { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
            if job.isGraph {
                WorkbenchWorkflowGraphJobDetails(session: session, graphState: session.workflowGraph, job: job)
            }
            if !job.outputsCurrent {
                Text("Results are out of date because analysis inputs or the experimental design changed.")
                    .font(.caption).foregroundStyle(.orange)
            }
            if job.status == "blocked" {
                Text(job.isGraph ? "A review or dependency needs attention. Completed outputs remain intact. For mask corrections, preview a corrected continuation below; changed acquisition inputs require a new ordinary job." : "Inputs changed. Review the updated images and create a new job.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let worker = activeWorker {
                HStack {
                    Text("Background worker: \(worker.status)").font(.caption)
                    Spacer()
                    Button(worker.stopRequested ? "Stop requested" : "Stop after checkpoint") {
                        session.stopBackgroundJob(worker.id)
                    }.disabled(session.busy || worker.stopRequested)
                }
                Text("The worker continues after the app closes. Stopping preserves the current checkpoint and pauses the job.")
                    .font(.caption).foregroundStyle(.secondary)
            } else if session.runningJobID == job.id {
                HStack {
                    Button("Pause after checkpoint") { session.requestJobStop(cancel: false) }
                    Button("Cancel after checkpoint") { session.requestJobStop(cancel: true) }
                }.disabled(session.requestedJobAction != nil)
            } else {
                if let worker = session.jobWorkers.first(where: { $0.active && $0.targetKind == "sweep" }) {
                    Text("A sweep worker is running. Use its sweep controls to request a stop after the checkpoint.")
                        .font(.caption).foregroundStyle(.secondary)
                    if let completed = worker.completed, let total = worker.total {
                        Text("Sweep progress: \(completed) of \(total) checkpoints").font(.caption).foregroundStyle(.secondary)
                    }
                }
                HStack {
                    if job.canAdvance {
                        Button("Start background") { session.startBackgroundJob(job.id) }
                            .disabled(session.hasActiveWorkers || !session.canRefreshWithoutDiscardingEdits)
                        Button("Run next") { session.advanceJob(job.id, remaining: false) }
                        Button("Run remaining") { session.advanceJob(job.id, remaining: true) }
                    }
                    if job.status == "paused" {
                        Button("Resume") { session.changeJob(job.id, action: "resume") }
                    }
                    if job.status == "failed" {
                        Button("Retry") { session.changeJob(job.id, action: "retry") }
                    }
                    if job.canCancel {
                        Button("Cancel") { session.changeJob(job.id, action: "cancel") }
                    }
                }.disabled(session.busy || session.hasActiveWorkers || !session.canRefreshWithoutDiscardingEdits)
            }
            if !workers.isEmpty {
                DisclosureGroup("Worker history") {
                    ForEach(workers.reversed()) { worker in
                        VStack(alignment: .leading, spacing: 3) {
                            Text("\(worker.status.capitalized) · Last revision \(worker.lastRevision.map(String.init) ?? "—")")
                                .font(.caption)
                            if let error = worker.error { Text(error).font(.caption).foregroundStyle(.orange) }
                        }
                    }
                }
            }
        }.padding(12).background(.quaternary.opacity(0.45)).clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func chooseExport() {
        let panel = NSSavePanel()
        panel.title = "Choose a new package destination for this job"
        panel.allowedContentTypes = [.zip]
        panel.nameFieldStringValue = "\(session.projectName)-workflow.zip"
        panel.begin { response in
            if response == .OK { exportDestination = panel.url }
        }
    }

    private func moveNode(_ id: UUID, offset: Int) {
        guard let index = measurementNodes.firstIndex(where: { $0.id == id }),
              measurementNodes.indices.contains(index + offset) else { return }
        measurementNodes.swapAt(index, index + offset)
    }

    private func chooseSegmentation(_ id: String) {
        let previous = loadedAnalysis
        let wasVolume = builderVolume
        let plugin = segmenters.first { $0.id == id }
        segmentationPluginID = id
        segmentationParameters = plugin?.initialParameters ?? [:]
        modelSettings.configure(selectedModel?.inferenceSchema ?? .null)
        guard let previous else { return }
        let planeParameters = previous["type"].string == "analysis"
            ? previous["parameters"] : previous["sourceParameters"]
        let volumeChannel = previous["channel"].integer ?? session.volume.channel
        if id.hasPrefix("model:") {
            loadedAnalysis = .object(["type": .string("model-segmentation"),
                "modelId": .string(String(id.dropFirst(6))), "modelParameters": .object(modelSettings.values),
                "sourceParameters": planeParameters == .null ? session.parameters : planeParameters])
        } else if !id.isEmpty {
            var step: [String: WorkbenchJSON] = ["type": .string("plugin-segmentation"),
                "pluginId": .string(id), "pluginParameters": .object(segmentationParameters),
                "target": .string(wasVolume ? "volume" : "plane")]
            if wasVolume { step["channel"] = .number(Double(volumeChannel)) }
            else { step["sourceParameters"] = planeParameters == .null ? session.parameters : planeParameters }
            loadedAnalysis = .object(step)
        } else if wasVolume {
            loadedAnalysis = .object(["type": .string("volume-analysis"),
                "parameters": previous["type"].string == "volume-analysis" ? previous["parameters"] : session.volume.parameters,
                "channel": .number(Double(volumeChannel))])
        } else {
            loadedAnalysis = .object(["type": .string("analysis"),
                "parameters": planeParameters == .null ? session.parameters : planeParameters])
        }
    }

    private func resetAnalysisToCurrent() {
        loadedAnalysis = nil
        chooseSegmentation("")
    }

    private func loadWorkflow(_ workflow: WorkbenchWorkflow) {
        if workflow.isGraph {
            workflowStructure = "branching"
            session.workflowGraph.load(workflow)
            return
        }
        workflowStructure = "linear"
        name = workflow.name; loadedWorkflowID = workflow.id; updateSelected = true
        loadedAnalysis = workflow.segmentationStep
        includeExport = workflow.exportsPackage
        retainedExportStep = workflow.steps.first { $0["type"].string == "export" }
        includePreprocessing = workflow.steps.contains { $0["type"].string == "preprocessing" }
        retainedPreprocessingStep = workflow.steps.first { $0["type"].string == "preprocessing" }
        recipe = retainedPreprocessingStep?["recipe"].array.map { value in
            var parameters = value.object; parameters.removeValue(forKey: "method")
            return WorkbenchPreprocessingStep(method: value["method"].string ?? "", values: parameters)
        } ?? []
        let step = workflow.segmentationStep ?? .null
        segmentationPluginID = step["type"].string == "model-segmentation"
            ? "model:\(step["modelId"].string ?? "")" : step["pluginId"].string ?? ""
        segmentationParameters = step["pluginParameters"].object
        modelSettings.configure(selectedModel?.inferenceSchema ?? .null, values: step["modelParameters"].object)
        measurementNodes = workflow.steps.filter {
            !["preprocessing", "analysis", "volume-analysis", "plugin-segmentation", "model-segmentation",
              "measurements", "summary", "export"].contains($0["type"].string ?? "")
        }.map { step in
            WorkbenchWorkflowPluginNode(kind: step["type"].string ?? "", pluginID: step["assay"].string ?? step["pluginId"].string ?? "",
                parameters: step["type"].string == "assay" ? step["assayParameters"].object : step["pluginParameters"].object,
                retained: step)
        }
    }
}
