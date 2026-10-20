import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct WorkbenchWorkspaceView: View {
    @Bindable var session: WorkbenchSession
    @Bindable var workspace: WorkbenchWorkspaceState
    @Environment(\.dismiss) private var dismiss
    @State private var pane = "Layers"
    @State private var bindingImageID = ""
    @State private var bindingRole = "raw-source"
    @State private var bindingTarget = "plane"
    @State private var bindingChannel = 0
    @State private var bindingTime = 0
    @State private var bindingZ = 0
    @State private var bindingProjection = "max"
    @State private var bindingFollowsPosition = false
    @State private var zarrBindingFollowsPosition = true
    @State private var version = 1
    @State private var newClassName = ""
    @State private var newClassValue = 3
    @State private var referenceLayerID = ""
    @State private var maxShift = 96
    @State private var columns = 2
    @State private var overlap = 0.12
    private var canEdit: Bool { !session.busy && !session.hasActiveWorkers && !workspace.isHistorical && !workspace.drawing }
    private var canRun: Bool { canEdit && !workspace.dirty && !workspace.selectedID.isEmpty }
    private var boundImage: WorkbenchImage? { session.images.first { $0.id == bindingImageID } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Layered workspace").font(.title2)
                WorkbenchSavedRecordAccess(session: session, catalogues: ["workspaces", "workspaceOutputs", "zarrSources"])
                Spacer()
                if workspace.dirty { Text("Unsaved workspace draft").font(.caption).foregroundStyle(.orange) }
                Button("Save draft", action: session.saveLayeredWorkspace).disabled(!canEdit || !workspace.dirty)
                Button("Discard draft") { workspace.document = workspace.savedDocument; workspace.drawing = false }
                    .disabled(!canEdit || !workspace.dirty)
                Button("Done") { dismiss() }.disabled(session.busy || workspace.dirty || workspace.drawing)
            }
            Text("Layers, semantic class journals and presentation outputs use the shared project runtime. Acquired pixels, calibrated measurements and instance masks remain separate.")
                .font(.callout).foregroundStyle(.secondary)
            if let error = session.error { Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled) }
            HStack {
                Picker("Workspace", selection: Binding(get: { workspace.selectedID }, set: { session.loadLayeredWorkspace($0) })) {
                    Text("Select a workspace").tag("")
                    ForEach(workspace.workspaces, id: idKey) { Text($0["name"].string ?? "Workspace").tag($0["id"].string ?? "") }
                }.disabled(session.busy || workspace.dirty)
                TextField("New workspace name", text: $workspace.newName).frame(maxWidth: 210)
                Button("Create") { session.workspaceMutation("workspace.create", arguments: ["name": .string(workspace.newName)]) }
                    .disabled(!canEdit || workspace.dirty || workspace.newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Menu("Import…") {
                    Button("Native workspace JSON…") { chooseImport("native") }
                    Button("Portable workspace JSON…") { chooseImport("portable") }
                }.disabled(!canEdit || workspace.dirty)
            }
            if workspace.importPreview != .null { importReview }
            HSplitView {
                ScrollView { sidebar.padding(8) }.frame(minWidth: 210, idealWidth: 240, maxWidth: 280)
                VStack(spacing: 10) {
                    Picker("Workspace task", selection: $pane) {
                        ForEach(["Layers", "Paint", "Vectors", "Workflows", "Outputs"], id: \.self) { Text($0) }
                    }.pickerStyle(.segmented)
                    if pane == "Paint" { paintCanvas }
                    else if pane == "Vectors" { WorkbenchWorkspaceVectorEditor(session: session, workspace: workspace) }
                    else if pane == "Outputs" { outputs }
                    else {
                        previewCanvas
                        if pane == "Workflows" { workflowControls }
                    }
                }.padding(10).frame(minWidth: 420)
                ScrollView { inspector.padding(10) }.frame(minWidth: 275, idealWidth: 310, maxWidth: 350)
            }
            if session.busy { ProgressView(session.status).controlSize(.small) }
            else { Text(session.status).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
        }
        .padding(18).frame(minWidth: 1080, idealWidth: 1180, minHeight: 700, idealHeight: 780)
        .interactiveDismissDisabled(session.busy || workspace.dirty || workspace.drawing)
        .onAppear {
            workspace.editorOpen = true
            if workspace.document == .null { session.loadLayeredWorkspace() }
            bindingImageID = session.selectedImageID ?? session.images.first?.id ?? ""
        }
        .onDisappear { workspace.editorOpen = false; workspace.paintEnabled = false; workspace.drawing = false }
        .onChange(of: session.revision) { _, _ in
            // Keep drafts and camera/context, but never display stale pixels as
            // if they belong to a new source or changed label binding.
            workspace.preview = nil; workspace.previewRevision = nil
            workspace.layerPreview = nil; workspace.layerPreviewRevision = nil
            workspace.materializePreview = .null; workspace.materializeRevision = nil
        }
    }
    private var idKey: KeyPath<WorkbenchJSON, String> { \.workspaceIdentity }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Layers").font(.headline)
            if workspace.layers.isEmpty { Text("Add a canonical image or import a saved workspace.").font(.callout).foregroundStyle(.secondary) }
            ForEach(workspace.layers, id: idKey) { layer in
                Button {
                    workspace.selectedLayerID = layer["id"].string ?? ""
                    workspace.layerPreview = nil; workspace.layerPreviewID = ""; workspace.paintEnabled = false
                } label: {
                    HStack {
                        Image(systemName: layer["visible"].bool == true ? "eye" : "eye.slash")
                        VStack(alignment: .leading) {
                            Text(layer["name"].string ?? "Layer").lineLimit(2)
                            Text(layer["kind"].string ?? "").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if layer["id"].string == workspace.selectedLayerID { Image(systemName: "checkmark") }
                    }.contentShape(Rectangle())
                }.buttonStyle(.plain).disabled(workspace.drawing || session.busy)
            }
            Divider()
            if workspace.record != .null {
                Text("Version \(workspace.record["version"].integer ?? 0)").font(.caption)
                if workspace.isHistorical { Text("Historical version. Load the latest version to edit.").font(.caption).foregroundStyle(.orange) }
                if workspace.record["sourceBindingsCurrent"].bool == false { Text("One or more saved source bindings changed. Rebind the intended current source before rendering.").font(.caption).foregroundStyle(.orange) }
                if workspace.record["sourceBindingsCurrent"] == .null { Text("External source ranges are verified when used. Saved metadata alone does not prove current bytes.").font(.caption).foregroundStyle(.secondary) }
                DisclosureGroup("Versions and source details") {
                    Stepper("Version \(version)", value: $version, in: 1...max(1, workspace.record["latestVersion"].integer ?? 1))
                    Button("Load version") { session.loadLayeredWorkspace(version: version) }.disabled(workspace.dirty || session.busy)
                    Button("Load latest") { session.loadLayeredWorkspace() }.disabled(workspace.dirty || session.busy)
                    Button("Undo saved workspace change") {
                        session.workspaceMutation("workspace.undo", arguments: ["workspaceId": .string(workspace.selectedID)])
                    }.disabled(!canRun || workspace.record["undoAvailable"].bool != true)
                    ForEach(Array(workspace.missingSources.enumerated()), id: \.offset) { _, item in
                        Text("\(item["name"].string ?? "Layer"): \(item["reason"].string ?? "Explicit source binding required")")
                            .font(.caption).foregroundStyle(.orange)
                    }
                    ForEach(workspace.record["notes"].array.compactMap(\.string), id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary) }
                }
                Button("Export portable workspace…") { exportWorkspace() }.disabled(!canRun)
            }
        }
    }

    private var previewCanvas: some View {
        VStack(spacing: 10) {
            HStack {
                Text("Saved layer composition").font(.headline)
                Spacer()
                Button("Render preview", action: session.renderLayeredWorkspace).disabled(!canRun)
            }
            if let image = workspace.preview, workspace.previewRevision == session.revision {
                Image(nsImage: image).resizable().interpolation(.high).scaledToFit().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView("Render the saved workspace", systemImage: "square.3.layers.3d",
                    description: Text(workspace.dirty ? "Save the draft to render its current layer composition." : "All raster layers need explicit compatible source bindings or retained snapshots."))
            }
            Text("Presentation transforms and blending do not resample source measurements or modify instance masks.")
                .font(.caption).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var paintCanvas: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Semantic class paint").font(.headline)
                Spacer()
                Button("Load source plane") { session.loadWorkspacePaintSource() }.disabled(!canRun || workspace.selectedLayerID.isEmpty)
            }
            if let image = workspace.layerPreview, workspace.layerPreviewID == workspace.selectedLayerID,
               workspace.layerPreviewRevision == session.revision, workspace.layerGrid.width > 0 {
                GeometryReader { geometry in
                    let scale = min(geometry.size.width / workspace.layerGrid.width, geometry.size.height / workspace.layerGrid.height)
                    let size = CGSize(width: workspace.layerGrid.width * scale, height: workspace.layerGrid.height * scale)
                    ZStack {
                        Image(nsImage: image).resizable().interpolation(.high)
                        WorkspacePaintOverlay(imageSize: workspace.layerGrid, strokes: workspace.visibleStrokes,
                            enabled: workspace.paintEnabled && !session.busy && !session.hasActiveWorkers && !workspace.isHistorical && workspace.paintRadius.isFinite && (0.5...512).contains(workspace.paintRadius),
                            classValue: UInt16(clamping: workspace.paintClass), radius: workspace.paintRadius, erases: workspace.paintErases,
                            onInteractionChanged: { workspace.drawing = $0 }, onStroke: workspace.appendStroke)
                    }.frame(width: size.width, height: size.height)
                        .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
                }.frame(minHeight: 280)
                if workspace.paintDocument == .null {
                    Button("Create semantic journal for this grid") { workspace.initializePaint() }.disabled(!canEdit)
                } else {
                    Toggle("Enable painting", isOn: $workspace.paintEnabled).disabled(!canEdit)
                    HStack {
                        Picker("Class", selection: $workspace.paintClass) {
                            ForEach(workspace.classes, id: \.workspaceClassValue) { Text($0["name"].string ?? "Class").tag($0["value"].integer ?? 1) }
                        }
                        Toggle("Erase", isOn: $workspace.paintErases)
                    }
                    HStack {
                        Text("Radius 0.5–512 (source px)")
                        TextField("Radius", value: $workspace.paintRadius, format: .number).frame(width: 70)
                        Button("Undo draft stroke", action: workspace.undoDraftStroke).disabled(workspace.paintDocument["strokes"].array.isEmpty)
                    }.disabled(!canEdit)
                    DisclosureGroup("Classes") {
                        HStack {
                            TextField("Class name", text: $newClassName)
                            TextField("Value", value: $newClassValue, format: .number).frame(width: 70)
                            Button("Add") { addClass() }.disabled(!canEdit || newClassName.isEmpty || !(1...65535).contains(newClassValue) || workspace.classes.contains { $0["value"].integer == newClassValue })
                        }
                    }
                }
                Button("Render saved semantic labels") {
                    session.workspaceMutation("semantic.render", arguments: ["workspaceId": .string(workspace.selectedID), "layerId": .string(workspace.selectedLayerID)], reload: false)
                }.disabled(!canRun || workspace.paintDocument == .null)
            } else {
                ContentUnavailableView("Load the selected layer’s source", systemImage: "paintbrush",
                    description: Text("Painting uses its exact source grid before display transforms. Imported journals must match that grid; coordinates are never silently rescaled."))
            }
            Text("Brush paths are a visual guide. The shared capsule rasterizer produces retained uint16 semantic classes; these class values are not cell instance IDs. Save, then render and export the exact TIFF under Outputs.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var inspector: some View {
        VStack(alignment: .leading, spacing: 12) {
            if workspace.selectedLayer != .null {
                Text("Selected layer").font(.headline)
                TextField("Name", text: layerString("name"))
                Toggle("Visible", isOn: Binding(get: { workspace.selectedLayer["visible"].bool ?? true }, set: { workspace.editLayer("visible", .bool($0)) }))
                Slider(value: layerNumber("opacity", fallback: 1), in: 0...1) { Text("Opacity") }
                Picker("Blend", selection: layerString("blendMode")) {
                    ForEach(["normal", "additive", "multiply", "screen", "difference"], id: \.self) { Text($0.capitalized) }
                }
                DisclosureGroup("Transform and intensity window") {
                    ForEach(["a", "b", "c", "d", "tx", "ty"], id: \.self) { field in
                        HStack { Text(field); TextField(field, value: nestedNumber("transform", field, fallback: ["a", "d"].contains(field) ? 1 : 0), format: .number) }
                    }
                    ForEach(["min", "max", "gamma"], id: \.self) { field in
                        HStack { Text(field); TextField(field, value: nestedNumber("display", field, fallback: field == "min" ? 0 : 1), format: .number) }
                    }
                    Text("Windows use source intensity units. Geometry edits are display transforms only.").font(.caption).foregroundStyle(.secondary)
                }
                Divider()
            }
            WorkbenchWorkspacePositionControls(workspace: workspace, editable: canEdit)
            bindingControls
            DisclosureGroup("OME-Zarr source layer") {
                WorkbenchZarrSourceSelection(session: session, storage: session.storage)
                if session.storage.array != .null {
                    ForEach(["x", "y", "width", "height"], id: \.self) { field in
                        HStack {
                            Text(field.capitalized + " (level pixels)").font(.caption)
                            TextField(field, value: zarrRegionField(field), format: .number).frame(minWidth: 70)
                        }
                    }
                    Toggle("Follow workspace positions", isOn: $zarrBindingFollowsPosition)
                    HStack {
                        Button("Add Zarr layer") { bindZarrSource(add: true) }
                        Button("Rebind selected") { bindZarrSource(add: false) }.disabled(workspace.selectedLayerID.isEmpty)
                    }.disabled(!canRun || !session.storage.validRegion || Double(session.storage.width) * Double(session.storage.height) > 4_000_000)
                    Text("Bind an exact selected-level region of at most four million pixels. The shared NGFF reader resolves T/Z/C on demand and checks retained read identities; overview pixels are never used as scientific source data.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("Register a local OME-Zarr source under Images & preparation → Sources before binding it here.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Divider()
            DisclosureGroup("Whole document exchange") {
                Text("Import a shared workspace document to edit large point, shape, lineage or animation metadata. The shared engine validates it and retains a new version. Original imports remain archived.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Replace metadata from shared JSON…") { replaceDocument() }.disabled(!canRun)
            }
        }.textFieldStyle(.roundedBorder).disabled(session.busy || session.hasActiveWorkers || workspace.isHistorical || workspace.drawing)
    }

    private var bindingControls: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("Canonical source binding").font(.headline)
            if workspace.selectedBinding != .null {
                let source = session.images.first { $0.id == workspace.selectedBinding["imageId"].string }
                Text(workspace.selectedBinding["sourceKind"].string == "zarr" ? "Current: external OME-Zarr · \(workspace.selectedBinding["arrayPath"].string ?? "")" : "Current: \(source?.name ?? "Retained source") · \(workspace.selectedBinding["role"].string ?? "")")
                    .font(.caption).foregroundStyle(.secondary)
                Text(workspace.selectedBinding["positionAxes"].object.isEmpty ? "Fixed acquisition position" : "Follows exact workspace time, Z and channel positions")
                    .font(.caption).foregroundStyle(.secondary)
                if workspace.selectedBinding["sourceKind"].string == "zarr" {
                    Text("External source currentness is checked when samples are read. Explicit rebinding accepts the selected source state; retained prior outputs keep their original identities.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            WorkbenchImageChoice(session: session, selection: $bindingImageID, title: "Image")
            Picker("Pixels", selection: $bindingRole) {
                Text("Acquired source").tag("raw-source"); Text("Exact saved instance labels").tag("instance-labels")
            }
            Picker("Selection", selection: $bindingTarget) { Text("2D projection").tag("plane"); Text("Volume XY slice").tag("volume") }
            if let image = boundImage {
                Stepper("Channel \(bindingChannel + 1)", value: $bindingChannel, in: 0...max(0, image.channels - 1))
                if bindingTarget == "volume" {
                    Stepper("Time \(bindingTime + 1)", value: $bindingTime, in: 0...max(0, image.timeCount - 1))
                    Stepper("Z \(bindingZ + 1)", value: $bindingZ, in: 0...max(0, image.zCount - 1))
                    if bindingRole == "raw-source" {
                        Toggle("Follow workspace positions", isOn: $bindingFollowsPosition)
                        Text("Resolve acquired pixels at each exact time, Z and channel position, including saved animation frames. Labels and generated layers remain fixed snapshots.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    Picker("Z projection", selection: $bindingProjection) { Text("Maximum").tag("max"); Text("Mean").tag("mean"); Text("Middle").tag("middle") }
                }
            }
            HStack {
                Button("Add layer") { bindSource(add: true) }
                Button("Bind selected") { bindSource(add: false) }.disabled(workspace.selectedLayerID.isEmpty)
            }.disabled(!canRun || boundImage == nil)
            Text("Explicit binding changes presentation input only. Semantic journal dimensions must match exactly; saved instance-label selections must match their analysis.")
                .font(.caption).foregroundStyle(.secondary)
        }.onChange(of: bindingImageID) { _, _ in bindingChannel = 0; bindingTime = 0; bindingZ = 0 }
    }

    private var workflowControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            DisclosureGroup("Saved layer workflows") {
                Picker("Workflow", selection: $workspace.selectedWorkflowID) {
                    Text("Choose layer workflow").tag("")
                    ForEach(workspace.document["workflows"].array, id: idKey) { Text($0["name"].string ?? "Workflow").tag($0["id"].string ?? "") }
                }
                Button("Replay saved layer workflow") {
                    session.workspaceMutation("workspace.replay", arguments: ["workspaceId": .string(workspace.selectedID), "workflowId": .string(workspace.selectedWorkflowID)])
                }.disabled(!canRun || workspace.selectedWorkflowID.isEmpty)
                Picker("Reference layer", selection: $referenceLayerID) {
                    Text("Choose reference").tag("")
                    ForEach(workspace.layers.filter { $0["kind"].string == "image" }, id: idKey) { Text($0["name"].string ?? "Image").tag($0["id"].string ?? "") }
                }
                HStack {
                    TextField("Maximum shift", value: $maxShift, format: .number).frame(width: 90)
                    Button("Add registration workflow") { addWorkflow(stitch: false) }.disabled(!canEdit || referenceLayerID.isEmpty || workspace.selectedLayerID.isEmpty || referenceLayerID == workspace.selectedLayerID)
                }
                HStack {
                    Stepper("Columns \(columns)", value: $columns, in: 1...64)
                    TextField("Overlap", value: $overlap, format: .number).frame(width: 70)
                    Button("Add stitch workflow") { addWorkflow(stitch: true) }.disabled(!canEdit || workspace.layers.filter { $0["kind"].string == "image" }.count < 2)
                }
            }
            WorkbenchWorkspaceAnimationEditor(session: session, workspace: workspace)
            DisclosureGroup("Point lineages and saved animations") {
                HStack {
                    TextField("Maximum point distance (source px)", value: $workspace.lineageDistance, format: .number)
                    Button("Build point lineage") { session.workspaceMutation("pointlineage.build", arguments: ["workspaceId": .string(workspace.selectedID), "maxDistance": .number(workspace.lineageDistance)]) }
                        .disabled(!canRun || workspace.lineageDistance <= 0 || workspace.document["lineage"]["nodes"].array.isEmpty)
                }
                Text("Associates retained point observations. This graph is separate from segmented-cell volume lineages.").font(.caption).foregroundStyle(.secondary)
                Picker("Animation", selection: $workspace.selectedAnimationID) {
                    Text("Choose saved animation").tag("")
                    ForEach(workspace.document["animationPlans"].array, id: idKey) { Text($0["name"].string ?? "Animation").tag($0["id"].string ?? "") }
                }
                Button("Render saved animation") { session.workspaceMutation("animation.render", arguments: ["workspaceId": .string(workspace.selectedID), "planId": .string(workspace.selectedAnimationID)]) }
                    .disabled(!canRun || workspace.selectedAnimationID.isEmpty)
            }
        }.font(.callout)
    }

    private var outputs: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                Text("Retained outputs").font(.headline)
                materializationControls
                ForEach(workspace.outputs.filter { $0["workspaceId"].string == workspace.selectedID }, id: idKey) { output in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(output["operation"].string == "semantic.render" ? "Semantic class labels" : "Presentation output").font(.headline)
                        Text("Version \(output["workspaceVersion"].integer ?? 0) · \(output["outputsCurrent"].bool == true ? "Current" : output["outputsCurrent"].bool == false ? "Historical / changed inputs" : "External source verification required")").font(.caption).foregroundStyle(.secondary)
                        ForEach(output["files"].array, id: idKey) { artifact in
                            HStack {
                                Text(artifact["kind"].string ?? "Artifact").font(.callout)
                                Spacer()
                                Text(ByteCountFormatter.string(fromByteCount: Int64(artifact["bytes"].integer ?? 0), countStyle: .file)).font(.caption)
                                Button("Export…") { exportOutput(output, artifact: artifact) }.disabled(!canRun)
                            }
                        }
                    }.padding(10).background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                }
            }
        }
    }

    private var materializationControls: some View {
        GroupBox("Generated layer → scientific image") {
            VStack(alignment: .leading, spacing: 8) {
                let generated = workspace.generatedLayers.first { $0["layerId"].string == workspace.selectedLayerID }
                Text(workspace.selectedLayer["name"].string ?? "Select a generated image layer").font(.callout.weight(.semibold))
                Text("Create an independent intensity acquisition from the exact generated grid and its acquired support. Display transforms, semantic class paint and exported screenshots are not treated as source pixels.")
                    .font(.caption).foregroundStyle(.secondary)
                TextField("New scientific image name", text: $workspace.materializeName)
                Button("Preview scientific image", action: session.previewWorkspaceMaterialization)
                    .disabled(!canRun || generated?["materializable"].bool != true || workspace.materializeName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if let generated, generated["materializable"].bool != true {
                    Text("This retained layer lacks exact generated support and canonical parent provenance. Keep it as presentation evidence or regenerate it from bound acquisitions.")
                        .font(.caption).foregroundStyle(.orange)
                }
                if workspace.materializePreview != .null {
                    let value = workspace.materializePreview
                    Text("\(value["width"].integer ?? 0) × \(value["height"].integer ?? 0) float32 samples · \(value["validSamples"].integer ?? 0) acquired / \(value["totalSamples"].integer ?? 0) total")
                        .font(.caption.monospacedDigit())
                    Text("\(value["parents"].array.count) exact parent bindings retained · \(value["calibration"] == .null ? "Physical calibration unknown" : "Physical calibration retained")")
                        .font(.caption)
                    ForEach(value["notes"].array.compactMap(\.string), id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary) }
                    DisclosureGroup("Coordinate and parent provenance") {
                        WorkbenchStructuredOutput(value: .object(["coordinateIdentity": value["coordinateIdentity"], "pixelToWorkspace": value["pixelToWorkspace"], "parents": value["parents"]]))
                            .frame(height: 180)
                    }
                    Button("Create scientific image", action: session.materializeWorkspaceImage)
                        .disabled(!canRun || workspace.materializeRevision != session.revision || workspace.materializeArguments["name"].string != workspace.materializeName || workspace.materializeArguments["layerId"].string != workspace.selectedLayerID)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var importReview: some View {
        GroupBox("Workspace import preview") {
            VStack(alignment: .leading, spacing: 6) {
                Text(URL(fileURLWithPath: workspace.importPath).lastPathComponent).font(.headline)
                Text("\(workspace.importPreview["missingSources"].array.count) layer sources require explicit binding.").font(.callout)
                ForEach(workspace.importPreview["notes"].array.compactMap(\.string), id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary) }
                HStack {
                    Button("Import as new workspace") {
                        session.workspaceMutation("workspace.import.run", arguments: ["path": .string(workspace.importPath), "format": .string(workspace.importFormat), "previewFingerprint": workspace.importPreview["previewFingerprint"]])
                        workspace.importPreview = .null
                    }.disabled(!canEdit || workspace.dirty)
                    Button("Dismiss preview") { workspace.importPreview = .null }
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func layerString(_ key: String) -> Binding<String> {
        Binding(get: { workspace.selectedLayer[key].string ?? "" }, set: { workspace.editLayer(key, .string($0)) })
    }
    private func layerNumber(_ key: String, fallback: Double) -> Binding<Double> {
        Binding(get: { workspace.selectedLayer[key].number ?? fallback }, set: { workspace.editLayer(key, .number($0)) })
    }
    private func nestedNumber(_ section: String, _ key: String, fallback: Double) -> Binding<Double> {
        Binding(get: { workspace.selectedLayer[section][key].number ?? fallback }, set: {
            var fields = workspace.selectedLayer[section].object; fields[key] = .number($0); workspace.editLayer(section, .object(fields))
        })
    }
    private func bindSource(add: Bool) {
        guard let image = boundImage else { return }
        var selection: [String: WorkbenchJSON] = ["target": .string(bindingTarget), "channel": .number(Double(bindingChannel))]
        if bindingTarget == "volume" { selection["timeIndex"] = .number(Double(bindingTime)); selection["zIndex"] = .number(Double(bindingZ)) }
        else { selection["zProjection"] = .string(bindingProjection) }
        var args: [String: WorkbenchJSON] = ["workspaceId": .string(workspace.selectedID), "imageId": .string(image.id), "role": .string(bindingRole), "selection": .object(selection)]
        if bindingRole == "raw-source", bindingTarget == "volume" { args["followPosition"] = .bool(bindingFollowsPosition) }
        if add { args["name"] = .string(image.name) } else { args["layerId"] = .string(workspace.selectedLayerID) }
        session.workspaceMutation(add ? "workspace.layer.add" : "workspace.source.bind", arguments: args)
    }
    private func zarrRegionField(_ field: String) -> Binding<Int> {
        Binding(get: {
            switch field { case "x": return session.storage.x; case "y": return session.storage.y; case "width": return session.storage.width; default: return session.storage.height }
        }, set: { value in
            switch field { case "x": session.storage.x = value; case "y": session.storage.y = value; case "width": session.storage.width = value; default: session.storage.height = value }
        })
    }
    private func bindZarrSource(add: Bool) {
        guard canRun, session.storage.validRegion else { return }
        var args = session.storage.selection.object
        for (key, value) in session.storage.region.object { args[key] = value }
        args["workspaceId"] = .string(workspace.selectedID)
        args["followPosition"] = .bool(zarrBindingFollowsPosition)
        if add { args["name"] = .string(session.storage.source["name"].string ?? "OME-Zarr region") }
        else { args["layerId"] = .string(workspace.selectedLayerID) }
        session.workspaceMutation(add ? "workspace.zarr.add" : "workspace.zarr.bind", arguments: args)
    }
    private func chooseImport(_ format: String) {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.json]; panel.canChooseDirectories = false
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            workspace.importPath = url.path; workspace.importFormat = format; workspace.importPreview = .null
            session.previewWorkspaceImport()
        }
    }
    private func replaceDocument() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.json]
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            session.workspaceMutation("workspace.document.set", arguments: ["workspaceId": .string(workspace.selectedID), "path": .string(url.path)])
        }
    }
    private func addClass() {
        var paints = workspace.document["paintDocuments"].object; var paint = workspace.paintDocument.object
        paint["classes"] = .array(workspace.classes + [.object(["value": .number(Double(newClassValue)), "name": .string(newClassName), "colorHex": .string("#FF9900")])])
        paints[workspace.selectedLayerID] = .object(paint); workspace.editDocument("paintDocuments", .object(paints))
        workspace.paintClass = newClassValue; newClassValue = min(65535, newClassValue + 1); newClassName = ""
    }
    private func addWorkflow(stitch: Bool) {
        let step: WorkbenchJSON = stitch ? .object(["type": .string("stitch"), "layerIDs": .array(workspace.layers.filter { $0["kind"].string == "image" }.map { $0["id"] }), "columns": .number(Double(columns)), "overlap": .number(overlap), "outputName": .string("Stitched layer")]) :
            .object(["type": .string("register"), "referenceID": .string(referenceLayerID), "movingID": .string(workspace.selectedLayerID), "maxShift": .number(Double(maxShift))])
        let id = UUID().uuidString
        workspace.editDocument("workflows", .array(workspace.document["workflows"].array + [.object(["id": .string(id), "name": .string(stitch ? "Stitch image layers" : "Register selected layer"), "createdAt": .string(ISO8601DateFormatter().string(from: Date())), "steps": .array([step])])]))
        workspace.selectedWorkflowID = id
    }
    private func exportWorkspace() { publish("workspace.export", args: ["workspaceId": .string(workspace.selectedID)], name: "workspace.json") }
    private func exportOutput(_ output: WorkbenchJSON, artifact: WorkbenchJSON) {
        let kind = artifact["kind"].string ?? "artifact"
        let ext = kind == "semantic-label-tiff" ? "tif" : kind == "presentation-gif" ? "gif" : kind.contains("project") || kind.contains("workspace") ? "json" : "bin"
        publish("workspace.output.export", args: ["outputId": output["id"], "artifactId": artifact["id"]], name: "\(kind).\(ext)")
    }
    private func publish(_ operation: String, args: [String: WorkbenchJSON], name: String) {
        let path = session.projectPath, revision = session.revision
        let panel = NSSavePanel(); panel.nameFieldStringValue = name; panel.canCreateDirectories = true
        panel.begin { response in
            guard response == .OK, let destination = panel.url else { return }
            guard session.projectPath == path, session.revision == revision, canRun else { session.error = "Project changed while choosing the destination. Choose Export again."; return }
            guard !FileManager.default.fileExists(atPath: destination.path) else { session.error = "Choose a new destination; existing exports are preserved."; return }
            session.perform("Exporting workspace output…") {
                var values = args; values["destination"] = .string(destination.path)
                _ = try await session.call(operation, arguments: values, mutation: true)
                try await session.inspect()
                NSWorkspace.shared.activateFileViewerSelecting([destination])
                session.reportStatus("Workspace export saved. Historical exports remain unchanged.")
            }
        }
    }
}

private extension WorkbenchJSON {
    var workspaceIdentity: String { self["id"].string ?? "" }
    var workspaceClassValue: Int { self["value"].integer ?? 0 }
}
