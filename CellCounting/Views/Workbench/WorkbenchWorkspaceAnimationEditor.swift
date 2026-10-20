import SwiftUI

/// Keyframes are metadata. The shared engine alone interpolates and renders.
struct WorkbenchWorkspaceAnimationEditor: View {
    @Bindable var session: WorkbenchSession
    @Bindable var workspace: WorkbenchWorkspaceState
    @State private var selectedFrameID = ""
    @State private var planName = "Workspace animation"
    @State private var time = 0.0
    @State private var zoom = 1.0
    @State private var centerX = 0.0
    @State private var centerY = 0.0
    @State private var selectedStep = 0
    @State private var sequenceFPS = 12
    private var canEdit: Bool { !session.busy && !session.hasActiveWorkers && !workspace.isHistorical && !workspace.drawing }
    private var plan: WorkbenchJSON { workspace.document["animationPlans"].array.first { $0["id"].string == workspace.selectedAnimationID } ?? .null }
    private var frame: WorkbenchJSON { plan["keyframes"].array.first { $0["id"].string == selectedFrameID } ?? .null }
    private var workflow: WorkbenchJSON { workspace.document["workflows"].array.first { $0["id"].string == workspace.selectedWorkflowID } ?? .null }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            DisclosureGroup("Animation keyframes") {
                HStack {
                    TextField("Animation name", text: $planName)
                    Button("Create plan") { createPlan() }.disabled(!canEdit || planName.isEmpty)
                }
                HStack {
                    Stepper("Sequence rate \(sequenceFPS) fps", value: $sequenceFPS, in: 1...60)
                    Button("Create image-layer sequence") { createLayerSequence() }
                        .disabled(!canEdit || workspace.layers.filter { ["image", "labels"].contains($0["kind"].string ?? "") }.count < 2)
                }
                Text("A layer sequence shows one retained image layer per keyframe in layer order. It changes presentation visibility, not acquisition time or scientific measurements.")
                    .font(.caption).foregroundStyle(.secondary)
                Picker("Plan", selection: $workspace.selectedAnimationID) {
                    Text("Choose animation").tag("")
                    ForEach(workspace.document["animationPlans"].array, id: \.animationIdentity) { Text($0["name"].string ?? "Animation").tag($0["id"].string ?? "") }
                }
                if plan != .null {
                    HStack {
                        TextField("Frames per second", value: Binding(get: { plan["framesPerSecond"].integer ?? 12 }, set: { editPlan("framesPerSecond", .number(Double($0))) }), format: .number).frame(width: 110)
                        Picker("Easing", selection: Binding(get: { plan["easing"].string ?? "linear" }, set: { editPlan("easing", .string($0)) })) {
                            Text("Linear").tag("linear"); Text("Ease in and out").tag("easeInOut")
                        }
                    }.disabled(!canEdit)
                    Picker("Keyframe", selection: $selectedFrameID) {
                        Text("New keyframe").tag("")
                        ForEach(plan["keyframes"].array, id: \.animationIdentity) { Text("\($0["timeSeconds"].number ?? 0, specifier: "%.2f") seconds").tag($0["id"].string ?? "") }
                    }
                    HStack {
                        number("Time (s)", $time); number("Zoom", $zoom)
                        number("Center X (px)", $centerX); number("Center Y (px)", $centerY)
                    }
                    HStack {
                        Button(selectedFrameID.isEmpty ? "Capture current view" : "Replace with current view") { captureFrame() }
                            .disabled(!canEdit || !time.isFinite || time < 0 || !zoom.isFinite || zoom <= 0 || zoom > 64 || !centerX.isFinite || !centerY.isFinite)
                        Button("Delete keyframe") { editPlan("keyframes", .array(plan["keyframes"].array.filter { $0["id"].string != selectedFrameID })); selectedFrameID = "" }
                            .disabled(!canEdit || selectedFrameID.isEmpty)
                    }
                    Text("Capture stores the current axis position and visible layer set with camera center/zoom. Set layer visibility and position first. Two or more distinct times are needed to render a changing animation.")
                        .font(.caption).foregroundStyle(.secondary)
                    if frame != .null {
                        Text("\(frame["visibleLayerIDs"].array.count) visible layers retained in this keyframe.").font(.caption)
                        DisclosureGroup("Edit this keyframe’s sources and visibility") {
                            ForEach(workspace.document["axes"].array.filter { !["x", "y"].contains($0["kind"].string ?? "") }, id: \.animationIdentity) { axis in
                                let id = axis["id"].string ?? ""
                                Stepper("\(axis["name"].string ?? "Axis"): \((frame["position"][id].integer ?? 0) + 1) / \(axis["length"].integer ?? 1)", value: Binding(
                                    get: { frame["position"][id].integer ?? 0 }, set: {
                                        var position = frame["position"].object; position[id] = .number(Double($0)); editFrame("position", .object(position))
                                    }), in: 0...max(0, (axis["length"].integer ?? 1) - 1))
                            }
                            ForEach(workspace.layers, id: \.animationIdentity) { layer in
                                let id = layer["id"].string ?? ""
                                Toggle(layer["name"].string ?? "Layer", isOn: Binding(
                                    get: { frame["visibleLayerIDs"].array.contains(.string(id)) }, set: { visible in
                                        var values = frame["visibleLayerIDs"].array.filter { $0.string != id }
                                        if visible { values.append(.string(id)) }; editFrame("visibleLayerIDs", .array(values))
                                    }))
                            }
                            Button("Use keyframe in workspace draft") { useFrame() }
                            Text("These edits change only this keyframe. Save the workspace before rendering. Fixed snapshots cannot supply another acquisition position; dynamic raw-source bindings resolve the requested samples.")
                                .font(.caption).foregroundStyle(.secondary)
                        }.disabled(!canEdit)
                    }
                }
            }
            if workflow != .null {
                DisclosureGroup("Edit saved layer-workflow draft") {
                    Picker("Step", selection: $selectedStep) {
                        ForEach(Array(workflow["steps"].array.enumerated()), id: \.offset) { index, step in Text("\(index + 1). \(step["type"].string ?? "Step")").tag(index) }
                    }
                    HStack {
                        Button("Move earlier") { moveStep(-1) }.disabled(!canEdit || selectedStep <= 0)
                        Button("Move later") { moveStep(1) }.disabled(!canEdit || selectedStep + 1 >= workflow["steps"].array.count)
                        Button("Remove step") { var steps = workflow["steps"].array; if steps.indices.contains(selectedStep) { steps.remove(at: selectedStep); editWorkflow(steps); selectedStep = max(0, selectedStep - 1) } }.disabled(!canEdit || workflow["steps"].array.isEmpty)
                    }
                    Button("Append current layer display settings") { appendDisplaySteps() }.disabled(!canEdit || workspace.selectedLayerID.isEmpty)
                    Text("Edits create a new workspace version on Save draft; imported steps retain their original order unless explicitly moved or removed.").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .onChange(of: selectedFrameID) { _, _ in
            if frame != .null { time = frame["timeSeconds"].number ?? 0; zoom = frame["zoom"].number ?? 1; centerX = frame["center"]["x"].number ?? 0; centerY = frame["center"]["y"].number ?? 0 }
        }
    }
    private func number(_ title: String, _ binding: Binding<Double>) -> some View {
        VStack(alignment: .leading) { Text(title).font(.caption); TextField(title, value: binding, format: .number).frame(minWidth: 65) }.disabled(!canEdit)
    }
    private func createPlan() {
        let id = UUID().uuidString
        workspace.editDocument("animationPlans", .array(workspace.document["animationPlans"].array + [.object([
            "id": .string(id), "name": .string(planName), "framesPerSecond": .number(12), "easing": .string("linear"), "keyframes": .array([])])]))
        workspace.selectedAnimationID = id; selectedFrameID = ""; time = 0
    }
    private func createLayerSequence() {
        let layers = workspace.layers.filter { ["image", "labels"].contains($0["kind"].string ?? "") }
        guard (2...3600).contains(layers.count) else { return }
        let id = UUID().uuidString
        let firstLayer = layers[0]
        let grid = workspace.layerGrids.first { $0["layerId"].string == firstLayer["id"].string }
        guard let width = grid?["width"].number, let height = grid?["height"].number else {
            session.reportStatus("Reload the workspace's retained layer grids before creating an image-layer sequence."); return
        }
        let transform = firstLayer["transform"]
        let cx = (transform["a"].number ?? 1) * width / 2 + (transform["c"].number ?? 0) * height / 2 + (transform["tx"].number ?? 0)
        let cy = (transform["b"].number ?? 0) * width / 2 + (transform["d"].number ?? 1) * height / 2 + (transform["ty"].number ?? 0)
        let frames = layers.enumerated().map { index, layer -> WorkbenchJSON in
            .object(["id": .string(UUID().uuidString), "timeSeconds": .number(Double(index) / Double(sequenceFPS)),
                "position": workspace.document["position"], "zoom": .number(1),
                "center": .object(["x": .number(cx), "y": .number(cy)]), "visibleLayerIDs": .array([layer["id"]])])
        }
        workspace.editDocument("animationPlans", .array(workspace.document["animationPlans"].array + [.object([
            "id": .string(id), "name": .string(planName), "framesPerSecond": .number(Double(sequenceFPS)), "easing": .string("linear"), "keyframes": .array(frames)])]))
        workspace.selectedAnimationID = id; selectedFrameID = ""; centerX = cx; centerY = cy
    }
    private func editFrame(_ key: String, _ value: WorkbenchJSON) {
        editPlan("keyframes", .array(plan["keyframes"].array.map { item in
            guard item["id"].string == selectedFrameID else { return item }
            var updated = item.object; updated[key] = value; return .object(updated)
        }))
    }
    private func useFrame() {
        let selected = frame
        workspace.editDocument("position", selected["position"])
        workspace.editDocument("layers", .array(workspace.layers.map { layer in
            var updated = layer.object; updated["visible"] = .bool(selected["visibleLayerIDs"].array.contains(layer["id"])); return .object(updated)
        }))
    }
    private func editPlan(_ key: String, _ value: WorkbenchJSON) {
        workspace.editDocument("animationPlans", .array(workspace.document["animationPlans"].array.map { item in
            guard item["id"].string == workspace.selectedAnimationID else { return item }; var changed = item.object; changed[key] = value; return .object(changed)
        }))
    }
    private func captureFrame() {
        let id = selectedFrameID.isEmpty ? UUID().uuidString : selectedFrameID
        let captured: WorkbenchJSON = .object(["id": .string(id), "timeSeconds": .number(time), "position": workspace.document["position"], "zoom": .number(zoom),
            "center": .object(["x": .number(centerX), "y": .number(centerY)]), "visibleLayerIDs": .array(workspace.layers.filter { $0["visible"].bool == true }.map { $0["id"] })])
        let frames = (plan["keyframes"].array.filter { $0["id"].string != id } + [captured]).sorted { ($0["timeSeconds"].number ?? 0) < ($1["timeSeconds"].number ?? 0) }
        editPlan("keyframes", .array(frames)); selectedFrameID = id
    }
    private func editWorkflow(_ steps: [WorkbenchJSON]) {
        workspace.editDocument("workflows", .array(workspace.document["workflows"].array.map { item in
            guard item["id"].string == workspace.selectedWorkflowID else { return item }; var changed = item.object; changed["steps"] = .array(steps); return .object(changed)
        }))
    }
    private func moveStep(_ delta: Int) {
        var steps = workflow["steps"].array; let next = selectedStep + delta
        guard steps.indices.contains(selectedStep), steps.indices.contains(next) else { return }
        steps.swapAt(selectedStep, next); editWorkflow(steps); selectedStep = next
    }
    private func appendDisplaySteps() {
        let layer = workspace.selectedLayer, id = layer["id"]
        editWorkflow(workflow["steps"].array + [
            .object(["type": .string("visibility"), "layerID": id, "visible": layer["visible"]]),
            .object(["type": .string("opacity"), "layerID": id, "opacity": layer["opacity"]]),
            .object(["type": .string("translate"), "layerID": id, "x": layer["transform"]["tx"], "y": layer["transform"]["ty"]])])
    }
}
private extension WorkbenchJSON { var animationIdentity: String { self["id"].string ?? "" } }
