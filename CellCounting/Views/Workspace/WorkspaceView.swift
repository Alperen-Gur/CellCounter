import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct WorkspaceView: View {
    @Bindable var state: AppState
    @Bindable var session: WorkspaceSession
    @State private var zoom = 1.0
    @State private var gridColumns = 2
    @State private var gridOverlap = 0.12
    @State private var maxRegistrationShift = 96
    @State private var lineageDistance = 80.0
    @State private var workflowName = "Recorded workflow"
    @State private var animationFPS = 8
    @State private var animationDuration = 3.0

    @Environment(AppTheme.self) private var theme

    var body: some View {
        VStack(spacing: 0) {
            header
            statusBar
            HStack(spacing: 0) {
                layerSidebar
                    .frame(width: 246)
                Divider().overlay(Tokens.divider)
                workspaceCanvas
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider().overlay(Tokens.divider)
                inspector
                    .frame(width: 354)
            }
        }
        .background(Tokens.bg)
        .onKeyPress(keys: [.init("s")]) { press in
            guard press.modifiers.contains(.command) else { return .ignored }
            presentWorkspaceSave()
            return .handled
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Microscopy workspace")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(Tokens.text)
                Text(session.workspace.name)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Tokens.textTertiary)
            }
            Spacer()
            Button("Images…") { presentImages() }
                .appButton(.standard, size: .sm)
                .accessibilityHint("Open local microscopy images as layers")
            Button("Current batch") { session.importCurrentBatch(state: state) }
                .appButton(.standard, size: .sm)
                .disabled(state.currentBatch == nil)
            Button("OME-Zarr…") { presentZarr() }
                .appButton(.standard, size: .sm)
            Menu {
                Button("New workspace") { session.reset() }
                Button("Open workspace…") { presentWorkspaceOpen() }
                Divider()
                Button("Save workspace…") { presentWorkspaceSave() }
            } label: {
                HStack(spacing: 5) { Icon("file", size: 12); Text("Project") }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(Tokens.bgToolbar)
        .overlay(alignment: .bottom) { Rectangle().fill(Tokens.divider).frame(height: 0.5) }
    }

    private var statusBar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                if session.isBusy { ProgressView().controlSize(.small) }
                Text(session.errorMessage ?? session.statusMessage)
                    .font(.system(size: 11.5))
                    .foregroundStyle(session.errorMessage == nil ? Tokens.textSecondary : Tokens.danger)
                    .lineLimit(2)
                Spacer()
                if session.isBusy {
                    Button("Cancel") { session.cancelCurrentWork() }
                        .buttonStyle(.plain)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(Tokens.danger)
                }
                Text("\(session.workspace.layers.count) layers")
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(Tokens.textTertiary)
            }
            .padding(.horizontal, 14)
            .frame(height: 34)
            if session.isBusy {
                ProgressView(value: session.progress)
                    .progressViewStyle(.linear)
                    .tint(theme.accentColor)
            }
        }
        .background(Tokens.bgSunken)
    }

    private var layerSidebar: some View {
        VStack(spacing: 0) {
            HStack {
                Text("LAYERS")
                    .font(.system(size: 10.5, weight: .semibold))
                    .tracking(0.5)
                    .foregroundStyle(Tokens.textTertiary)
                Spacer()
                Text("\(session.visibleImageLayers.count) visible")
                    .font(.system(size: 10))
                    .foregroundStyle(Tokens.textTertiary)
            }
            .padding(12)

            if session.workspace.layers.isEmpty {
                VStack(spacing: 10) {
                    Icon("layers", size: 28).foregroundStyle(Tokens.textTertiary)
                    Text("No layers")
                        .font(.system(size: 13, weight: .semibold))
                    Text("Open images, OME-Zarr, or the current batch.")
                        .font(.system(size: 11))
                        .foregroundStyle(Tokens.textTertiary)
                        .multilineTextAlignment(.center)
                }
                .padding(24)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(session.workspace.layers.reversed()) { layer in
                            layerRow(layer)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 12)
                }
            }
        }
        .background(Tokens.bgSidebar)
    }

    private func layerRow(_ layer: WorkspaceLayer) -> some View {
        let selected = session.selectedLayerID == layer.id
        return VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Button {
                    session.setLayerVisibility(layer.id, visible: !layer.isVisible)
                } label: {
                    Icon(layer.isVisible ? "eye" : "eyeoff", size: 12)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(layer.isVisible ? "Hide \(layer.name)" : "Show \(layer.name)")
                Icon(layerIcon(layer.kind), size: 13)
                    .foregroundStyle(selected ? theme.accentColor : Tokens.textSecondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(layer.name)
                        .font(.system(size: 11.5, weight: selected ? .semibold : .regular))
                        .foregroundStyle(Tokens.text)
                        .lineLimit(1)
                    Text(layer.kind.displayName)
                        .font(.system(size: 9.5))
                        .foregroundStyle(Tokens.textTertiary)
                }
                Spacer(minLength: 0)
            }
            if selected {
                HStack(spacing: 8) {
                    Text("Opacity").font(.system(size: 9.5)).foregroundStyle(Tokens.textTertiary)
                    Slider(value: Binding(
                        get: { session.workspace.layers.first(where: { $0.id == layer.id })?.opacity ?? 1 },
                        set: { session.setLayerOpacity(layer.id, opacity: $0) }), in: 0...1)
                    .controlSize(.mini)
                }
            }
        }
        .padding(9)
        .background(RoundedRectangle(cornerRadius: Tokens.Radius.md)
            .fill(selected ? theme.accentSoft : Color.clear))
        .contentShape(Rectangle())
        .onTapGesture { session.selectLayer(layer.id) }
    }

    private var workspaceCanvas: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button { zoom = max(0.2, zoom - 0.15) } label: { Icon("zoomout", size: 12) }
                    .buttonStyle(.plain).accessibilityLabel("Zoom out")
                Text("\(Int(zoom * 100))%")
                    .font(.system(size: 10.5, design: .monospaced))
                    .frame(width: 42)
                Button { zoom = min(8, zoom + 0.15) } label: { Icon("zoomin", size: 12) }
                    .buttonStyle(.plain).accessibilityLabel("Zoom in")
                Button { zoom = 1 } label: { Icon("fit", size: 12) }
                    .buttonStyle(.plain).accessibilityLabel("Fit image")
                Spacer()
                if session.inspectorTab == .labels {
                    Label("Paint mode", systemImage: session.paintErases ? "eraser" : "paintbrush")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(theme.accentColor)
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 34)
            .background(Tokens.bgToolbar)

            WorkspaceCanvas(session: session, zoom: zoom,
                            paintEnabled: session.inspectorTab == .labels)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            axisControls
        }
    }

    private var axisControls: some View {
        VStack(spacing: 6) {
            ForEach(session.workspace.axes.filter { $0.kind != .x && $0.kind != .y }) { axis in
                HStack(spacing: 10) {
                    Text(axis.name.uppercased())
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .frame(width: 26)
                    Slider(value: Binding(
                        get: { Double(session.workspace.position[axis.id]) },
                        set: { session.updateAxis(axis.id, value: Int($0.rounded())) }),
                           in: 0...Double(max(0, axis.length - 1)), step: 1)
                    Text("\(session.workspace.position[axis.id] + 1) / \(axis.length)")
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(Tokens.textSecondary)
                        .frame(width: 72, alignment: .trailing)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, session.workspace.axes.contains(where: { $0.kind != .x && $0.kind != .y }) ? 9 : 0)
        .background(Tokens.bgToolbar)
        .overlay(alignment: .top) { Rectangle().fill(Tokens.divider).frame(height: 0.5) }
    }

    private var inspector: some View {
        VStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(WorkspaceInspectorTab.allCases) { tab in
                        Button(tab.title) { session.inspectorTab = tab }
                            .font(.system(size: 10.5, weight: session.inspectorTab == tab ? .semibold : .regular))
                            .buttonStyle(.plain)
                            .padding(.horizontal, 8).padding(.vertical, 6)
                            .foregroundStyle(session.inspectorTab == tab ? theme.accentColor : Tokens.textSecondary)
                            .background(RoundedRectangle(cornerRadius: 6)
                                .fill(session.inspectorTab == tab ? theme.accentSoft : .clear))
                    }
                }
                .padding(8)
            }
            Divider().overlay(Tokens.divider)
            ScrollView {
                Group {
                    switch session.inspectorTab {
                    case .dataset: datasetInspector
                    case .align: alignmentInspector
                    case .lineage: lineageInspector
                    case .labels: paintInspector
                    case .workflows: workflowInspector
                    case .extensions: extensionInspector
                    case .animation: animationInspector
                    }
                }
                .padding(14)
            }
        }
        .background(Tokens.bgSidebar)
    }

    private var datasetInspector: some View {
        VStack(alignment: .leading, spacing: 12) {
            inspectorTitle("Dimensions", subtitle: "N-dimensional positions are preserved with every annotation.")
            WorkspaceCard {
                ForEach(session.workspace.axes) { axis in
                    HStack {
                        Text(axis.name).font(.system(size: 11.5, weight: .medium))
                        Spacer()
                        Text("\(axis.length) · \(axis.kind.rawValue)")
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(Tokens.textTertiary)
                    }
                }
            }
            if let plate = session.workspace.plate {
                inspectorTitle("Plate", subtitle: "\(plate.wells.count) wells · \(plate.rows.count) × \(plate.columns.count)")
                plateGrid(plate)
            }
            if let layer = session.selectedLayer, !layer.metadata.isEmpty {
                inspectorTitle("Selected layer", subtitle: layer.name)
                WorkspaceCard {
                    ForEach(layer.metadata.keys.sorted(), id: \.self) { key in
                        HStack(alignment: .firstTextBaseline) {
                            Text(key).foregroundStyle(Tokens.textTertiary)
                            Spacer()
                            Text(layer.metadata[key] ?? "")
                                .font(.system(size: 10.5, design: .monospaced))
                                .multilineTextAlignment(.trailing)
                        }
                        .font(.system(size: 10.5))
                    }
                }
            }
        }
    }

    private func plateGrid(_ plate: WorkspacePlate) -> some View {
        let columns = Array(repeating: GridItem(.flexible(), spacing: 3),
                            count: max(1, min(12, plate.columns.count)))
        return LazyVGrid(columns: columns, spacing: 3) {
            ForEach(plate.wells) { well in
                Text(well.label)
                    .font(.system(size: 8.5, design: .monospaced))
                    .frame(maxWidth: .infinity, minHeight: 22)
                    .background(RoundedRectangle(cornerRadius: 4).fill(theme.accentSoft))
                    .help("\(well.fields.count) field(s) · \(well.path)")
            }
        }
    }

    private var alignmentInspector: some View {
        VStack(alignment: .leading, spacing: 12) {
            inspectorTitle("Registration & stitching",
                           subtitle: "Local, bounded alignment. Source images are never modified.")
            WorkspaceCard {
                Text("Translation registration")
                    .font(.system(size: 12, weight: .semibold))
                Stepper("Max shift · \(maxRegistrationShift) px",
                        value: $maxRegistrationShift, in: 8...512, step: 8)
                    .font(.system(size: 11))
                Button("Register first two image layers") {
                    session.registerFirstPair(maxShift: maxRegistrationShift)
                }
                .appButton(.primary, size: .sm)
                .disabled(session.rasterLayers.count < 2 || session.isBusy)
            }
            WorkspaceCard {
                Text("Grid mosaic")
                    .font(.system(size: 12, weight: .semibold))
                Stepper("Columns · \(gridColumns)", value: $gridColumns, in: 1...24)
                    .font(.system(size: 11))
                HStack {
                    Text("Overlap")
                    Slider(value: $gridOverlap, in: 0...0.8)
                    Text("\(Int(gridOverlap * 100))%")
                        .font(.system(size: 10, design: .monospaced))
                }
                .font(.system(size: 11))
                Button("Stitch all image layers") {
                    session.stitchAll(columns: gridColumns, overlap: gridOverlap)
                }
                .appButton(.standard, size: .sm)
                .disabled(session.rasterLayers.count < 2 || session.isBusy)
            }
        }
    }

    private var lineageInspector: some View {
        VStack(alignment: .leading, spacing: 12) {
            inspectorTitle("Tracking & lineage",
                           subtitle: "Edit continuations, gaps, divisions, and merges.")
            WorkspaceCard {
                HStack {
                    Text("\(session.workspace.lineage.nodes.count) observations")
                    Spacer()
                    Text("\(session.workspace.lineage.edges.count) links")
                }
                .font(.system(size: 10.5, design: .monospaced))
                HStack {
                    Text("Link distance")
                    Slider(value: $lineageDistance, in: 5...500)
                    Text("\(Int(lineageDistance)) px")
                        .font(.system(size: 9.5, design: .monospaced))
                }
                .font(.system(size: 10.5))
                Button("Rebuild nearest-neighbour lineage") {
                    session.buildLineage(maxDistancePx: lineageDistance)
                }
                .appButton(.standard, size: .sm)
            }
            if !session.workspace.lineage.nodes.isEmpty {
                Text("Select two observations, then choose the relationship.")
                    .font(.system(size: 10.5)).foregroundStyle(Tokens.textTertiary)
                LazyVStack(spacing: 3) {
                    ForEach(session.workspace.lineage.nodes.prefix(200)) { node in
                        Button {
                            session.toggleLineageNode(node.id)
                        } label: {
                            HStack {
                                Text("T\(node.frame + 1)")
                                    .font(.system(size: 9.5, design: .monospaced))
                                Text("x \(Int(node.coordinate.x)) · y \(Int(node.coordinate.y))")
                                Spacer()
                                if session.selectedLineageNodeIDs.contains(node.id) {
                                    Icon("check", size: 10).foregroundStyle(theme.accentColor)
                                }
                            }
                            .font(.system(size: 10.5))
                            .padding(7)
                            .background(RoundedRectangle(cornerRadius: 5)
                                .fill(session.selectedLineageNodeIDs.contains(node.id) ? theme.accentSoft : Tokens.bgSunken))
                        }
                        .buttonStyle(.plain)
                    }
                }
                HStack {
                    Menu("Link as…") {
                        ForEach(WorkspaceLineageEdgeKind.allCases, id: \.self) { kind in
                            Button(kind.rawValue.capitalized) { session.linkSelected(kind: kind) }
                        }
                    }
                    .disabled(session.selectedLineageNodeIDs.count != 2)
                    Spacer()
                    Text("\(session.selectedLineageNodeIDs.count)/2 selected")
                        .font(.system(size: 9.5, design: .monospaced))
                        .foregroundStyle(Tokens.textTertiary)
                }
                ForEach(session.workspace.lineage.edges.suffix(20)) { edge in
                    HStack {
                        Text(edge.kind.rawValue.capitalized)
                            .font(.system(size: 10.5))
                        Spacer()
                        Button { session.unlink(edge.id) } label: { Icon("x", size: 9) }
                            .buttonStyle(.plain).accessibilityLabel("Remove lineage link")
                    }
                }
            }
        }
    }

    private var paintInspector: some View {
        VStack(alignment: .leading, spacing: 12) {
            inspectorTitle("Train by painting",
                           subtitle: "Paint multiclass semantic labels directly on the selected image.")
            if let layer = session.selectedLayer,
               let plane = session.planes[layer.id] {
                WorkspaceCard {
                    Picker("Class", selection: $session.paintClassValue) {
                        Text("Cell").tag(UInt16(1))
                        Text("Background").tag(UInt16(2))
                    }
                    .pickerStyle(.segmented)
                    HStack {
                        Text("Brush")
                        Slider(value: $session.paintRadius, in: 1...80)
                        Text("\(Int(session.paintRadius)) px")
                            .font(.system(size: 9.5, design: .monospaced))
                    }
                    .font(.system(size: 10.5))
                    Toggle("Erase", isOn: $session.paintErases)
                        .font(.system(size: 11))
                    HStack {
                        Button("Undo") { session.undoPaint(layerID: layer.id) }
                            .appButton(.ghost, size: .sm)
                        Button("Export 16-bit labels…") {
                            session.ensurePaintDocument(for: layer.id,
                                                        width: plane.width, height: plane.height)
                            presentLabelSave(layerID: layer.id)
                        }
                        .appButton(.primary, size: .sm)
                    }
                }
                .onAppear {
                    session.ensurePaintDocument(for: layer.id,
                                                width: plane.width, height: plane.height)
                }
            } else {
                emptyInspector("Select a loaded image layer to paint labels.")
            }
        }
    }

    private var workflowInspector: some View {
        VStack(alignment: .leading, spacing: 12) {
            inspectorTitle("Workflow recorder",
                           subtitle: "Records safe, declarative workspace operations—never scripts.")
            WorkspaceCard {
                TextField("Workflow name", text: $workflowName)
                    .textFieldStyle(.roundedBorder)
                HStack {
                    Button(session.isRecording ? "Stop" : "Record") { session.toggleRecording() }
                        .appButton(session.isRecording ? .danger : .primary, size: .sm)
                    Button("Save") { session.saveRecording(name: workflowName) }
                        .appButton(.standard, size: .sm)
                        .disabled(session.recordedSteps.isEmpty)
                    Spacer()
                    Text("\(session.recordedSteps.count) steps")
                        .font(.system(size: 9.5, design: .monospaced))
                }
                if session.isRecording {
                    Text("Layer, axis, registration, and stitching actions are being recorded.")
                        .font(.system(size: 10)).foregroundStyle(Tokens.warning)
                }
            }
            ForEach(session.workspace.workflows) { workflow in
                WorkspaceCard {
                    HStack {
                        VStack(alignment: .leading) {
                            Text(workflow.name).font(.system(size: 11.5, weight: .semibold))
                            Text("\(workflow.steps.count) deterministic steps")
                                .font(.system(size: 9.5)).foregroundStyle(Tokens.textTertiary)
                        }
                        Spacer()
                        Button("Run") { session.runWorkflow(workflow) }
                            .appButton(.standard, size: .sm)
                    }
                }
            }
        }
    }

    private var extensionInspector: some View {
        VStack(alignment: .leading, spacing: 12) {
            inspectorTitle("Curated extensions",
                           subtitle: "Built-in capabilities with a versioned contract. Executable third-party plugins remain disabled.")
            ForEach(WorkspaceExtensionKind.allCases, id: \.self) { kind in
                let matches = session.extensions.filter { $0.kind == kind }
                if !matches.isEmpty {
                    Text(kind.displayName.uppercased())
                        .font(.system(size: 9.5, weight: .bold))
                        .foregroundStyle(Tokens.textTertiary)
                    ForEach(matches) { item in
                        WorkspaceCard {
                            HStack(alignment: .top) {
                                Icon(extensionIcon(kind), size: 13).foregroundStyle(theme.accentColor)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(item.name).font(.system(size: 11.5, weight: .semibold))
                                    Text(item.summary).font(.system(size: 10.5)).foregroundStyle(Tokens.textSecondary)
                                    Text("v\(item.version) · bundled")
                                        .font(.system(size: 9, design: .monospaced)).foregroundStyle(Tokens.textTertiary)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private var animationInspector: some View {
        VStack(alignment: .leading, spacing: 12) {
            inspectorTitle("Animation export",
                           subtitle: "Create local GIFs from image frames or n-dimensional keyframes.")
            WorkspaceCard {
                Stepper("Frame rate · \(animationFPS) fps", value: $animationFPS, in: 1...30)
                    .font(.system(size: 11))
                HStack {
                    Text("Duration")
                    Slider(value: $animationDuration, in: 0.5...20)
                    Text("\(animationDuration, specifier: "%.1f") s")
                        .font(.system(size: 9.5, design: .monospaced))
                }
                .font(.system(size: 10.5))
                Button("Create keyframe plan") {
                    do {
                        let plan = try session.makeAnimationPlan(duration: animationDuration,
                                                                 fps: animationFPS)
                        session.addAnimationPlan(plan)
                    } catch { session.errorMessage = error.localizedDescription }
                }
                .appButton(.standard, size: .sm)
                Button("Export image sequence GIF…") { presentAnimationSave() }
                    .appButton(.primary, size: .sm)
                    .disabled(session.rasterLayers.count < 2 || session.isBusy)
            }
            ForEach(session.workspace.animationPlans) { plan in
                WorkspaceCard {
                    Text(plan.name).font(.system(size: 11.5, weight: .semibold))
                    Text("\(plan.keyframes.count) keyframes · \(plan.framesPerSecond) fps")
                        .font(.system(size: 9.5, design: .monospaced))
                        .foregroundStyle(Tokens.textTertiary)
                }
            }
        }
    }

    private func inspectorTitle(_ title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.system(size: 14, weight: .semibold)).foregroundStyle(Tokens.text)
            Text(subtitle).font(.system(size: 10.5)).foregroundStyle(Tokens.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func emptyInspector(_ text: String) -> some View {
        Text(text).font(.system(size: 11)).foregroundStyle(Tokens.textTertiary)
            .padding(14).frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: Tokens.Radius.md).fill(Tokens.bgSunken))
    }

    private func layerIcon(_ kind: WorkspaceLayerKind) -> String {
        switch kind {
        case .image: return "image"
        case .labels: return "layers"
        case .points: return "scope"
        case .shapes: return "bbox"
        case .surface: return "viewfinder"
        case .tracks: return "arrow"
        }
    }

    private func extensionIcon(_ kind: WorkspaceExtensionKind) -> String {
        switch kind {
        case .reader: return "folder"
        case .detector: return "cpu"
        case .assay: return "flask"
        case .measurement: return "ruler"
        case .exporter: return "download"
        }
    }

    private func presentImages() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.image]
        if panel.runModal() == .OK { session.importImages(panel.urls) }
    }

    private func presentZarr() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Open OME-Zarr"
        if panel.runModal() == .OK, let url = panel.url { session.openOMEZarr(url) }
    }

    private func presentWorkspaceSave() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = session.workspace.name + ".ccworkspace.json"
        panel.allowedContentTypes = [.json]
        if panel.runModal() == .OK, let url = panel.url { session.saveWorkspace(to: url) }
    }

    private func presentWorkspaceOpen() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.json]
        if panel.runModal() == .OK, let url = panel.url { session.loadWorkspace(from: url) }
    }

    private func presentLabelSave(layerID: UUID) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "training-labels.tiff"
        panel.allowedContentTypes = [.tiff]
        if panel.runModal() == .OK, let url = panel.url {
            session.exportTrainingLabel(layerID: layerID, to: url)
        }
    }

    private func presentAnimationSave() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "CellCounter-workspace.gif"
        panel.allowedContentTypes = [.gif]
        if panel.runModal() == .OK, let url = panel.url {
            session.exportRasterSequenceGIF(to: url, fps: animationFPS)
        }
    }
}

private struct WorkspaceCard<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 10) { content }
            .padding(11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: Tokens.Radius.md).fill(Tokens.bgElevated))
            .overlay(RoundedRectangle(cornerRadius: Tokens.Radius.md)
                .strokeBorder(Tokens.border, lineWidth: 0.5))
    }
}

private struct WorkspaceCanvas: View {
    @Bindable var session: WorkspaceSession
    let zoom: Double
    let paintEnabled: Bool

    @State private var liveStroke: [WorkspaceCoordinate] = []

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Tokens.bgSunken
                if let selected = session.selectedLayer,
                   let image = session.displayImages[selected.id] {
                    let fit = fittedRect(imageSize: image.size, in: geometry.size, zoom: zoom)
                    ZStack {
                        ForEach(session.visibleImageLayers) { layer in
                            if let layerImage = session.displayImages[layer.id] {
                                Image(nsImage: layerImage)
                                    .resizable()
                                    .interpolation(.high)
                                    .frame(width: fit.width, height: fit.height)
                                    .opacity(layer.opacity)
                                    .offset(x: layer.transform.tx * fit.width / max(1, layerImage.size.width),
                                            y: layer.transform.ty * fit.height / max(1, layerImage.size.height))
                                    .blendMode(blendMode(layer.blendMode))
                            }
                        }
                        workspaceOverlays(size: fit.size, selectedImageSize: image.size)
                        paintOverlay(size: fit.size, selectedImageSize: image.size,
                                     layerID: selected.id)
                    }
                    .frame(width: fit.width, height: fit.height)
                    .position(x: fit.midX, y: fit.midY)
                    .contentShape(Rectangle())
                    .gesture(paintEnabled ? paintGesture(rect: fit, imageSize: image.size,
                                                         layerID: selected.id) : nil)
                } else {
                    VStack(spacing: 10) {
                        Icon("image", size: 34).foregroundStyle(Tokens.textTertiary)
                        Text("Select a loaded image layer")
                            .font(.system(size: 13, weight: .semibold))
                        Text("OME-Zarr metadata remains available even when its codec cannot be decoded locally.")
                            .font(.system(size: 10.5)).foregroundStyle(Tokens.textTertiary)
                            .multilineTextAlignment(.center).frame(maxWidth: 360)
                    }
                }
            }
            .clipped()
        }
    }

    private func fittedRect(imageSize: CGSize, in container: CGSize, zoom: Double) -> CGRect {
        let scale = min(container.width / max(1, imageSize.width),
                        container.height / max(1, imageSize.height)) * zoom
        let size = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        return CGRect(x: (container.width - size.width) / 2,
                      y: (container.height - size.height) / 2,
                      width: size.width, height: size.height)
    }

    private func workspaceOverlays(size: CGSize, selectedImageSize: CGSize) -> some View {
        Canvas { context, _ in
            let scaleX = size.width / max(1, selectedImageSize.width)
            let scaleY = size.height / max(1, selectedImageSize.height)
            for layer in session.workspace.layers where layer.isVisible {
                switch layer.payload {
                case .points(let points):
                    for point in points where visible(point.position) {
                        let p = layer.transform.applying(to: point.coordinate)
                        let rect = CGRect(x: p.x * scaleX - 3, y: p.y * scaleY - 3, width: 6, height: 6)
                        context.fill(Path(ellipseIn: rect), with: .color(.cyan.opacity(layer.opacity)))
                    }
                case .shapes(let shapes):
                    for shape in shapes where visible(shape.position) {
                        var path = Path()
                        for (index, vertex) in shape.vertices.enumerated() {
                            let p = layer.transform.applying(to: vertex)
                            let cg = CGPoint(x: p.x * scaleX, y: p.y * scaleY)
                            index == 0 ? path.move(to: cg) : path.addLine(to: cg)
                        }
                        if shape.kind == .polygon { path.closeSubpath() }
                        context.stroke(path, with: .color(.yellow.opacity(layer.opacity)), lineWidth: 1.5)
                    }
                case .tracks(let tracks):
                    for track in tracks {
                        var path = Path()
                        for (index, vertex) in track.vertices.enumerated() {
                            let p = layer.transform.applying(to: vertex.coordinate)
                            let cg = CGPoint(x: p.x * scaleX, y: p.y * scaleY)
                            index == 0 ? path.move(to: cg) : path.addLine(to: cg)
                        }
                        context.stroke(path, with: .color(.mint.opacity(layer.opacity)), lineWidth: 2)
                    }
                default: break
                }
            }
        }
        .frame(width: size.width, height: size.height)
        .allowsHitTesting(false)
    }

    private func paintOverlay(size: CGSize, selectedImageSize: CGSize,
                              layerID: UUID) -> some View {
        Canvas { context, _ in
            let scaleX = size.width / max(1, selectedImageSize.width)
            let scaleY = size.height / max(1, selectedImageSize.height)
            let document = session.workspace.paintDocuments[layerID]
            for stroke in document?.strokes ?? [] where visible(stroke.position) {
                draw(stroke: stroke, context: &context, scaleX: scaleX, scaleY: scaleY)
            }
            if !liveStroke.isEmpty {
                let preview = WorkspacePaintStroke(classValue: session.paintClassValue,
                                                   radiusPx: session.paintRadius,
                                                   points: liveStroke,
                                                   position: session.workspace.position,
                                                   erases: session.paintErases)
                draw(stroke: preview, context: &context, scaleX: scaleX, scaleY: scaleY)
            }
        }
        .frame(width: size.width, height: size.height)
        .allowsHitTesting(false)
    }

    private func draw(stroke: WorkspacePaintStroke, context: inout GraphicsContext,
                      scaleX: Double, scaleY: Double) {
        guard let first = stroke.points.first else { return }
        var path = Path()
        path.move(to: CGPoint(x: first.x * scaleX, y: first.y * scaleY))
        for point in stroke.points.dropFirst() {
            path.addLine(to: CGPoint(x: point.x * scaleX, y: point.y * scaleY))
        }
        let color: Color = stroke.erases ? .white.opacity(0.35)
            : (stroke.classValue == 1 ? .cyan.opacity(0.52) : .orange.opacity(0.52))
        context.stroke(path, with: .color(color),
                       style: StrokeStyle(lineWidth: max(1, stroke.radiusPx * 2 * scaleX),
                                          lineCap: .round, lineJoin: .round))
    }

    private func paintGesture(rect: CGRect, imageSize: CGSize, layerID: UUID) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { value in
                let x = min(max(0, value.location.x / rect.width * imageSize.width), imageSize.width - 1)
                let y = min(max(0, value.location.y / rect.height * imageSize.height), imageSize.height - 1)
                let point = WorkspaceCoordinate(x: x, y: y)
                let minimumSpacing = max(0.75, session.paintRadius * 0.08)
                if let last = liveStroke.last, hypot(point.x - last.x, point.y - last.y) < minimumSpacing {
                    return
                }
                liveStroke.append(point)
            }
            .onEnded { _ in
                session.ensurePaintDocument(for: layerID,
                                            width: Int(imageSize.width), height: Int(imageSize.height))
                session.appendPaintStroke(layerID: layerID, points: liveStroke)
                liveStroke.removeAll(keepingCapacity: true)
            }
    }

    private func visible(_ position: WorkspacePosition) -> Bool {
        position.indices.allSatisfy { session.workspace.position[$0.key] == $0.value }
    }

    private func blendMode(_ mode: WorkspaceBlendMode) -> BlendMode {
        switch mode {
        case .normal: return .normal
        case .additive: return .plusLighter
        case .multiply: return .multiply
        case .screen: return .screen
        case .difference: return .difference
        }
    }
}
