import SwiftUI

struct WorkbenchWorkflowGraphEditor: View {
    @Bindable var session: WorkbenchSession
    @Bindable var graph: WorkbenchWorkflowGraphState
    let imageIDs: Set<String>
    @State private var historyVersion = 1

    private var arguments: [String: WorkbenchJSON] {
        var values: [String: WorkbenchJSON] = ["graph": graph.graph]
        if !imageIDs.isEmpty { values["imageIds"] = .array(imageIDs.sorted().map(WorkbenchJSON.string)) }
        if !imageIDs.isEmpty && graph.target == "volume" && !graph.allTimePoints {
            values["timeIndices"] = .array([.number(Double(session.volume.timeIndex))])
        }
        return values
    }
    private var previewCurrent: Bool {
        graph.preview != nil && graph.previewArguments == .object(arguments) && graph.previewRevision == session.revision
    }
    private var selectableTypes: [WorkbenchGraphNodeType] {
        graph.nodeTypes.filter { type in
            if graph.target == "volume" && ["analysis", "model-segmentation"].contains(type.id) { return false }
            if graph.target == "plane" && type.id == "volume-analysis" { return false }
            if ["summary", "export"].contains(type.id) && graph.nodes.contains(where: { $0.type == type.id }) { return false }
            return true
        }
    }
    private var canSave: Bool {
        previewCurrent && session.canRefreshWithoutDiscardingEdits && !session.hasActiveWorkers &&
            !graph.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && graph.name.count <= 200
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("Workflow name", text: $graph.name).textFieldStyle(.roundedBorder)
            Text("Connect each method to its source. Segmentation creates independent mask variants; the summary keeps technical alternatives separate from biological replicates.")
                .font(.caption).foregroundStyle(.secondary)
            sourceControls
            if graph.nodeTypes.isEmpty {
                Button("Load branching methods", action: session.loadWorkflowGraphCatalogue)
            } else {
                WorkbenchWorkflowGraphRelationships(graph: graph.graph)
                HStack {
                    Menu("Add node", systemImage: "plus") {
                        ForEach(selectableTypes) { type in Button(type.name) { addNode(type) } }
                    }.disabled(graph.nodes.count >= (graph.limits["nodes"].integer ?? 32))
                    Spacer()
                    Text("\(graph.nodes.count) nodes").font(.caption).foregroundStyle(.secondary)
                }
                Picker("Edit node", selection: $graph.selectedNodeID) {
                    Text("Select a node").tag("")
                    ForEach(graph.nodes) { node in Text(graph.label(node.id)).tag(node.id) }
                }
                if let index = graph.nodes.firstIndex(where: { $0.id == graph.selectedNodeID }) {
                    WorkbenchWorkflowGraphNodeEditor(session: session, graph: graph, node: $graph.nodes[index])
                        .id(graph.selectedNodeID)
                    let isReferenced = graph.nodes.contains { $0.input == graph.selectedNodeID || $0.inputs.contains(graph.selectedNodeID) || [$0.value["nuclearInput"].string, $0.value["somaInput"].string].contains(graph.selectedNodeID) }
                    Button("Remove selected node", role: .destructive) {
                        graph.nodes.removeAll { $0.id == graph.selectedNodeID }
                        graph.selectedNodeID = graph.nodes.first?.id ?? ""
                    }.disabled(isReferenced)
                    if isReferenced {
                        Text("Reconnect dependent nodes before removing this node.").font(.caption).foregroundStyle(.secondary)
                    }
                }
                if let id = graph.errorNodeID {
                    HStack {
                        Text("Review node: \(graph.label(id))").font(.caption).foregroundStyle(.orange)
                        Button("Edit node") { graph.selectedNodeID = id }
                    }
                }
                Divider()
                Button("Preview branches and execution plan") { session.previewWorkflowGraph(arguments: arguments) }
                    .disabled(graph.nodes.isEmpty)
                if previewCurrent, let preview = graph.preview {
                    previewDetails(preview)
                } else if graph.preview != nil {
                    Text("The draft, selected inputs or project changed. Preview again before saving.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    Button("Save as new") { session.saveWorkflowGraph(asNew: true, previewArguments: arguments) }
                        .disabled(!canSave)
                    Button("Save version") { session.saveWorkflowGraph(asNew: false, previewArguments: arguments) }
                        .disabled(!canSave || graph.loadedWorkflowID == nil)
                }
                if !session.canRefreshWithoutDiscardingEdits || session.hasActiveWorkers {
                    Text("Finish image edits and stop active workers before saving. Your workflow draft is retained.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let loadedID = graph.loadedWorkflowID {
                    DisclosureGroup("Saved versions") {
                        Text("Editing version \(graph.loadedVersion ?? 1). Loading a version replaces this branching draft; existing jobs keep their own frozen versions.")
                            .font(.caption).foregroundStyle(.secondary)
                        let latest = max(graph.loadedVersion ?? 1, session.workflows.first { $0.id == loadedID }?.version ?? 1)
                        Stepper("Version \(historyVersion)", value: $historyVersion, in: 1...latest)
                        Button("Load this version into builder") {
                            session.loadWorkflowGraphVersion(loadedID, version: historyVersion)
                        }
                    }
                }
                DisclosureGroup("Supported relationships and limits") {
                    ForEach(graph.notes, id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary) }
                }
            }
        }
        .onAppear { if !graph.initialized { session.seedWorkflowGraph() } }
        .onChange(of: graph.loadedVersion) { _, version in historyVersion = version ?? 1 }
    }

    private var sourceControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Source acquisition").font(.headline)
            Picker("Dimensions", selection: $graph.target) {
                Text("2D projection").tag("plane")
                Text("3D volume").tag("volume")
            }
            Picker("Source channel", selection: $graph.channel) {
                ForEach(0..<32, id: \.self) {
                    Text("Channel \($0 + 1)").tag($0)
                }
            }
            if graph.target == "plane" {
                Picker("Z projection", selection: $graph.projection) {
                    Text("Maximum").tag("max"); Text("Mean").tag("mean"); Text("Middle plane").tag("middle")
                }
            } else {
                Toggle("Preview all time points", isOn: $graph.allTimePoints)
                if !graph.allTimePoints { Text("Preview time \(session.volume.timeIndex + 1) in each selected image.").font(.caption) }
            }
            Text("\(imageIDs.count) selected source images. Segmentation may explicitly choose another raw acquisition channel. Projection and time stay fixed; processed acquisitions use their single retained channel.")
                .font(.caption).foregroundStyle(.secondary)
        }.padding(10).background(.quaternary.opacity(0.3)).clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func previewDetails(_ preview: WorkbenchJSON) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Branch relationships validated").font(.callout.weight(.semibold))
            if preview["plan"] != .null {
                let plan = preview["plan"]
                Text("\(plan["sourceCount"].integer ?? 0) source images · \(plan["checkpointCount"].integer ?? 0) image/time selections · \(plan["nodeCheckpointCount"].integer ?? 0) scientific checkpoints · \(plan["newImageCount"].integer ?? 0) new images")
                    .font(.caption)
                Text("\(plan["segmentationBranchCount"].integer ?? 0) segmentation branches remain separate technical results.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("Select images below and preview again to calculate execution size.").font(.caption).foregroundStyle(.secondary)
            }
            DisclosureGroup("Validated execution order") {
                ForEach(Array(preview["order"].array.enumerated()), id: \.offset) { index, value in
                    let id = value.string ?? ""
                    let output = preview["nodeOutputs"].array.first { $0["nodeId"].string == id } ?? .null
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(index + 1). \(graph.label(id))").font(.caption.weight(.medium))
                        Text("\(output["outputKind"].string ?? "Output") · \(workbenchGraphSelectionLabel(output["selection"]))\(output["processed"].bool == true ? " · Processed acquisition" : "")")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func addNode(_ type: WorkbenchGraphNodeType) {
        let id = graph.newID()
        let number = graph.nodes.filter { $0.type == type.id }.count + 1
        let candidates = (["$source"] + graph.nodes.map(\.id)).filter { type.inputKinds.contains(graph.outputKind($0)) }
        var fields: [String: WorkbenchJSON] = ["id": .string(id), "type": .string(type.id), "name": .string("\(type.name) \(number)")]
        if ["summary", "mask-merge"].contains(type.id) { fields["inputs"] = .array([]) }
        else { fields["input"] = .string(candidates.contains(graph.selectedNodeID) ? graph.selectedNodeID : candidates.last ?? "") }
        if type.id == "analysis" || type.id == "volume-analysis" {
            var values = (type.id == "analysis" ? session.parameters : session.volume.parameters).object
            values.removeValue(forKey: "channel"); values.removeValue(forKey: "zProjection")
            fields["parameters"] = .object(values)
        } else if type.id == "preprocessing" {
            if let filter = session.preprocessing.filters.first(where: { $0.dimensions.contains(graph.target == "volume" ? 3 : 2) }) {
                fields["recipe"] = .array([WorkbenchPreprocessingStep(method: filter.id, values: filter.defaults).json])
            }
        } else if type.id == "review" {
            fields["prompt"] = .string("Review the exact saved mask before continuing.")
            fields["requireHuman"] = .bool(true)
        } else if type.id == "mask-merge" {
            fields["mode"] = .string("union"); fields["connectivity"] = .string("faces")
        }
        if let node = WorkbenchGraphNodeDraft(.object(fields)) { graph.nodes.append(node); graph.selectedNodeID = node.id }
    }
}

private struct WorkbenchWorkflowGraphNodeEditor: View {
    @Bindable var session: WorkbenchSession
    @Bindable var graph: WorkbenchWorkflowGraphState
    @Binding var node: WorkbenchGraphNodeDraft
    private var definition: WorkbenchGraphNodeType? { graph.nodeTypes.first { $0.id == node.type } }
    private var inputs: [String] {
        (["$source"] + graph.nodes.filter { $0.id != node.id }.map(\.id)).filter {
            let kind = graph.outputKind($0)
            if node.type == "assay", let assay = assays.first(where: { $0.id == node.value["assay"].string }), assay.requiresAnalysis { return kind == "analyzed" }
            return definition?.inputKinds.contains(kind) == true
        }
    }
    private var plugins: [WorkbenchPlugin] {
        session.extensions.plugins.filter { $0.enabled && $0.available &&
            $0.dimensions.contains(graph.target == "volume" ? 3 : 2) &&
            $0.kind == (node.type == "plugin-segmentation" ? "segmentation" : "measurement") }
    }
    private var assays: [WorkbenchAssay] {
        session.assays.catalog.filter { $0.dimensions.contains(graph.target == "volume" ? 3 : 2) }
    }
    private var thresholdFields: [WorkbenchPluginParameter] {
        let allowed: Set<String> = node.type == "analysis"
            ? ["method", "threshold", "polarity", "minAreaPx", "minDistancePx", "adaptiveBlockSize", "adaptiveOffsetMode", "adaptiveOffset", "fillHoles"]
            : ["method", "threshold", "polarity", "minVolumeVox", "minDistanceVox"]
        return (definition?.schema["properties"]["parameters"]["properties"].object ?? [:])
            .filter { allowed.contains($0.key) && thresholdFieldVisible($0.key) }.sorted { $0.key < $1.key }.map {
                var schema = $0.value.object
                schema["title"] = .string(parameterTitle($0.key))
                return WorkbenchPluginParameter(id: $0.key, schema: .object(schema), required: $0.key != "fillHoles")
            }
    }

    private func thresholdFieldVisible(_ key: String) -> Bool {
        let parameters = node.value["parameters"]
        let method = parameters["method"].string ?? "otsu"
        if key == "threshold" { return method == "manual" }
        if key.hasPrefix("adaptive") {
            return method == "adaptive" && (key != "adaptiveOffset" || parameters["adaptiveOffsetMode"].string == "manual")
        }
        return true
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(definition?.name ?? node.type).font(.headline)
            TextField("Node name", text: $node.name).textFieldStyle(.roundedBorder)
            if node.type == "summary" {
                summaryInputs
            } else if node.type == "mask-merge" {
                mergeInputs
            } else {
                Picker("Input from", selection: $node.input) {
                    Text("Select an input").tag("")
                    ForEach(inputs, id: \.self) { Text(graph.label($0)).tag($0) }
                    if !node.input.isEmpty && !inputs.contains(node.input) {
                        Text("\(graph.label(node.input)) · Incompatible input").tag(node.input)
                    }
                }
            }
            if ["analysis", "volume-analysis", "plugin-segmentation", "model-segmentation"].contains(node.type) { sourceChannelControls }
            nodeControls
            DisclosureGroup("Node identity") { Text(node.id).font(.caption.monospaced()).textSelection(.enabled) }
        }.padding(10).background(.quaternary.opacity(0.4)).clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var summaryInputs: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Collect terminal results").font(.callout.weight(.semibold))
            ForEach(inputs, id: \.self) { id in
                Toggle(graph.label(id), isOn: Binding(get: { node.inputs.contains(id) }, set: { enabled in
                    node.inputs = enabled ? Array(Set(node.inputs + [id])).sorted() : node.inputs.filter { $0 != id }
                }))
            }
            ForEach(node.inputs.filter { !inputs.contains($0) }, id: \.self) { id in
                HStack {
                    Text("\(graph.label(id)) · Incompatible reference").font(.caption).foregroundStyle(.orange)
                    Button("Remove reference") { node.inputs = node.inputs.filter { $0 != id } }
                }
            }
            Button("Use all terminal scientific outputs") {
                let consumed = Set(graph.nodes.filter { !["summary", "export"].contains($0.type) }.flatMap { value in
                    [value.input] + value.inputs + [value.value["nuclearInput"].string ?? "", value.value["somaInput"].string ?? ""]
                })
                node.inputs = inputs.filter { !consumed.contains($0) }
            }
            Text("This collects references to each branch. It does not merge masks or count branch alternatives as independent biological specimens.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var nodeControls: some View {
        switch node.type {
        case "preprocessing":
            WorkbenchPreprocessingRecipeEditor(steps: $node.recipe,
                filters: session.preprocessing.filters.filter { $0.dimensions.contains(graph.target == "volume" ? 3 : 2) })
        case "analysis", "volume-analysis":
            WorkbenchPluginParameters(definitions: thresholdFields, values: values("parameters"))
            Text("A manual threshold requires a threshold value in source intensity units. Channel and projection are inherited from the input.")
                .font(.caption).foregroundStyle(.secondary)
        case "plugin-segmentation", "plugin-measurement":
            pluginControls
        case "model-segmentation":
            modelControls
        case "assay":
            assayControls
        case "review":
            TextField("Review instruction", text: Binding(get: { node.value["prompt"].string ?? "" }, set: { node.set("prompt", .string($0)) }), axis: .vertical)
                .lineLimit(2...4).textFieldStyle(.roundedBorder)
            Toggle("Require a human-labelled review decision", isOn: Binding(get: { node.value["requireHuman"].bool != false }, set: { node.set("requireHuman", .bool($0)) }))
            Text("Execution stops at this exact mask. Agent recommendations remain separate; they cannot complete a human-required gate. Reviewer roles are self-declared, not authentication.")
                .font(.caption).foregroundStyle(.secondary)
        case "mask-merge":
            Picker("Foreground operation", selection: Binding(get: { node.value["mode"].string ?? "union" }, set: { node.set("mode", .string($0)) })) {
                Text("Union · foreground in either input").tag("union")
                Text("Intersection · foreground in both inputs").tag("intersection")
            }
            Picker("Connected components", selection: Binding(get: { node.value["connectivity"].string ?? "faces" }, set: { node.set("connectivity", .string($0)) })) {
                Text("Face neighbours").tag("faces"); Text("All neighbours, including diagonals").tag("full")
            }
            Text("Requires the same acquisition, grid and valid support. The output has new instance IDs; touching foreground objects may merge. Neither input mask is replaced.")
                .font(.caption).foregroundStyle(.secondary)
        case "measurements":
            Text("Measures the exact masks produced by its input branch using current calibration.")
                .font(.caption).foregroundStyle(.secondary)
        case "summary":
            EmptyView()
        case "export":
            Text("Choose a new ZIP destination when creating the job. The package retains all branch results and the workflow definition.")
                .font(.caption).foregroundStyle(.secondary)
            if let destination = node.value["destination"].string {
                Text("Saved destination: \(URL(fileURLWithPath: destination).lastPathComponent)").font(.caption)
                Button("Choose destination for each job instead") { var fields = node.value.object; fields.removeValue(forKey: "destination"); node.value = .object(fields) }
            }
        default:
            Text("This saved node is unavailable in this runtime. Its definition is retained; install a compatible runtime before saving or running it.")
                .font(.caption).foregroundStyle(.orange)
        }
    }

    private var pluginControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Plugin", selection: Binding(get: { node.value["pluginId"].string ?? "" }, set: { id in
                replaceMethod(["pluginId": .string(id), "pluginParameters": .object(plugins.first { $0.id == id }?.initialParameters ?? [:])])
            })) {
                Text("Select an enabled plugin").tag("")
                ForEach(plugins) { Text("\($0.name) · v\($0.version)").tag($0.id) }
                if let id = node.value["pluginId"].string, !plugins.contains(where: { $0.id == id }) {
                    Text("Saved plugin unavailable").tag(id)
                }
            }
            if let plugin = plugins.first(where: { $0.id == node.value["pluginId"].string }) {
                WorkbenchPluginParameters(definitions: plugin.parameters, values: values("pluginParameters"))
            }
        }
    }

    private var modelControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Registered model", selection: Binding(get: { node.value["modelId"].string ?? "" }, set: { id in
                var settings = WorkbenchModelInferenceSettings()
                settings.configure(session.models.models.first { $0.id == id }?.inferenceSchema ?? .null)
                replaceMethod(["modelId": .string(id), "modelParameters": .object(settings.values)])
            })) {
                Text("Select an enabled model").tag("")
                ForEach(session.models.models.filter(\.enabled)) { Text("\($0.name) · \($0.backend)").tag($0.id) }
                if let id = node.value["modelId"].string, !session.models.models.contains(where: { $0.id == id && $0.enabled }) {
                    Text("Saved model unavailable").tag(id)
                }
            }
            if let model = session.models.models.first(where: { $0.id == node.value["modelId"].string && $0.enabled }) {
                WorkbenchModelInferenceControls(settings: Binding(get: {
                    var settings = WorkbenchModelInferenceSettings()
                    settings.configure(model.inferenceSchema, values: node.value["modelParameters"].object)
                    return settings
                }, set: { node.set("modelParameters", .object($0.values)) }))
                ForEach(model.notes, id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary) }
            }
            if graph.target == "volume" { Text("Registered models currently support 2D workflows. Use a volume method or a compatible plugin.").font(.caption).foregroundStyle(.orange) }
        }
    }

    private var assayControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Assay", selection: Binding(get: { node.value["assay"].string ?? "" }, set: { id in
                replaceMethod(["assay": .string(id), "assayParameters": .object(assays.first { $0.id == id }?.initialParameters ?? [:])])
            })) {
                Text("Select an assay").tag("")
                ForEach(assays) { Text($0.name).tag($0.id) }
                if let id = node.value["assay"].string, !assays.contains(where: { $0.id == id }) {
                    Text("Saved assay unsupported here").tag(id)
                }
            }
            if let assay = assays.first(where: { $0.id == node.value["assay"].string }) {
                if ["nuclear_cytoplasmic", "neurite_outgrowth"].contains(assay.id) {
                    let port = assay.id == "neurite_outgrowth" ? "somaInput" : "nuclearInput"
                    Picker(assay.id == "neurite_outgrowth" ? "Soma mask branch" : "Nuclear mask branch", selection: Binding(get: { node.value[port].string ?? "" }, set: { node.set(port, .string($0)) })) {
                        Text("Select a separate analyzed branch").tag("")
                        ForEach(inputs.filter { $0 != node.input && graph.outputKind($0) == "analyzed" }, id: \.self) { Text(graph.label($0)).tag($0) }
                    }
                    WorkbenchPluginParameters(definitions: assay.parameters.filter { !["nuclearImageId", "somaImageId"].contains($0.id) }, values: values("assayParameters"))
                    Text("The separate branch supplies exact paired reference masks. Both branches must retain the same acquisition, projection, support and grid.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    WorkbenchAssayParameterControls(session: session, assay: assay, values: values("assayParameters"))
                }
                if !assay.requiresAnalysis { Text("This assay can consume the acquired source or a processed branch directly. Object counts remain unavailable unless exact masks exist.").font(.caption).foregroundStyle(.secondary) }
                Text("Assay channels refer to this branch's acquisition. A processed branch has only Channel 1; multi-channel assays require an unprocessed branch.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func values(_ key: String) -> Binding<[String: WorkbenchJSON]> {
        Binding(get: { node.value[key].object }, set: { edited in
            var next = edited
            if key == "parameters", ["analysis", "volume-analysis"].contains(node.type) {
                let method = next["method"]?.string ?? "otsu"
                if method != "manual" { next.removeValue(forKey: "threshold") }
                if method != "adaptive" {
                    for key in ["adaptiveBlockSize", "adaptiveOffsetMode", "adaptiveOffset"] { next.removeValue(forKey: key) }
                } else if next["adaptiveOffsetMode"]?.string != "manual" { next.removeValue(forKey: "adaptiveOffset") }
            }
            node.set(key, .object(next))
        })
    }
    private func replaceMethod(_ parameters: [String: WorkbenchJSON]) {
        var fields = ["id": WorkbenchJSON.string(node.id), "type": .string(node.type), "input": .string(node.input)]
        if !node.name.isEmpty { fields["name"] = .string(node.name) }
        if let sourceChannel = node.value["sourceChannel"].integer { fields["sourceChannel"] = .number(Double(sourceChannel)) }
        fields.merge(parameters) { _, new in new }; node.value = .object(fields)
    }
    private var sourceChannelControls: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle("Choose a raw source channel for this branch", isOn: Binding(get: { node.value["sourceChannel"].integer != nil }, set: { enabled in
                var fields = node.value.object; fields["sourceChannel"] = enabled ? .number(Double(graph.channel)) : nil; node.value = .object(fields)
            }))
            if node.value["sourceChannel"].integer != nil {
                Picker("Branch source channel", selection: Binding(get: { node.value["sourceChannel"].integer ?? graph.channel }, set: { node.set("sourceChannel", .number(Double($0))) })) {
                    ForEach(0..<32, id: \.self) { Text("Channel \($0 + 1)").tag($0) }
                }
                Text("The channel must exist in every source. A processed single-channel input cannot silently recover channels from its parent.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
    private var mergeInputs: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(0..<2, id: \.self) { index in
                Picker(index == 0 ? "First mask branch" : "Second mask branch", selection: Binding(get: {
                    node.inputs.indices.contains(index) ? node.inputs[index] : ""
                }, set: { id in
                    var values = node.inputs
                    while values.count < 2 { values.append("") }
                    values[index] = id; node.inputs = values
                })) {
                    Text("Select an analyzed branch").tag("")
                    ForEach(inputs, id: \.self) { Text(graph.label($0)).tag($0) }
                }
            }
        }
    }
    private func parameterTitle(_ key: String) -> String {
        switch key {
        case "method": return "Threshold method"
        case "threshold": return "Manual threshold (source intensity)"
        case "polarity": return "Object polarity"
        case "minAreaPx": return "Minimum area (pixels²)"
        case "adaptiveBlockSize": return "Neighbourhood (odd pixels, 3–501)"
        case "adaptiveOffsetMode": return "Adaptive offset mode"
        case "adaptiveOffset": return "Offset (source intensity)"
        case "fillHoles": return "Fill enclosed holes"
        case "minDistancePx": return "Minimum separation (pixels)"
        case "minVolumeVox": return "Minimum volume (voxels)"
        case "minDistanceVox": return "Minimum separation (voxels)"
        default: return key
        }
    }
}

struct WorkbenchWorkflowGraphRelationships: View {
    let graph: WorkbenchJSON
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Source acquisition", systemImage: "photo.on.rectangle").font(.caption.weight(.semibold))
            ForEach(Array(graph["nodes"].array.enumerated()), id: \.offset) { _, node in
                let sources = ["summary", "mask-merge"].contains(node["type"].string ?? "") ? node["inputs"].array.compactMap(\.string) : [node["input"].string ?? ""]
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: node["type"].string == "summary" ? "arrow.triangle.merge" : "arrow.turn.down.right").foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(workbenchGraphNodeLabel(graph, id: node["id"].string ?? "")).font(.caption.weight(.semibold))
                        Text("From: \(sources.map { workbenchGraphNodeLabel(graph, id: $0) }.joined(separator: ", "))")
                            .font(.caption).foregroundStyle(.secondary)
                        if let nuclear = node["nuclearInput"].string {
                            Text("Nuclear masks: \(workbenchGraphNodeLabel(graph, id: nuclear))").font(.caption).foregroundStyle(.secondary)
                        }
                        if let soma = node["somaInput"].string { Text("Soma masks: \(workbenchGraphNodeLabel(graph, id: soma))").font(.caption).foregroundStyle(.secondary) }
                        if let channel = node["sourceChannel"].integer { Text("Raw source channel \(channel + 1)").font(.caption).foregroundStyle(.secondary) }
                    }
                }
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

func workbenchGraphNodeLabel(_ graph: WorkbenchJSON, id: String) -> String {
    if id == "$source" { return "Source acquisition" }
    guard let node = graph["nodes"].array.first(where: { $0["id"].string == id }) else { return id.isEmpty ? "Input not selected" : "Missing node (\(id))" }
    return node["name"].string ?? node["type"].string?.replacingOccurrences(of: "-", with: " ").capitalized ?? id
}

func workbenchGraphSelectionLabel(_ selection: WorkbenchJSON) -> String {
    let channel = "Channel \((selection["channel"].integer ?? 0) + 1)"
    if selection["target"].string == "volume" {
        return selection["timeIndex"].integer.map { "Time \($0 + 1) · \(channel) · 3D volume" } ?? "Selected time points · \(channel) · 3D volume"
    }
    return "\(channel) · \(selection["zProjection"].string ?? "max") projection"
}
