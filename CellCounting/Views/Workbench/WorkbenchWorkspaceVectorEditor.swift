import SwiftUI

/// Layer-vector editing reuses the measured-annotation source-grid canvas.
/// All changes remain ordinary workspace metadata until the shared engine saves.
struct WorkbenchWorkspaceVectorEditor: View {
    @Bindable var session: WorkbenchSession
    @Bindable var workspace: WorkbenchWorkspaceState
    @State private var sourceLayerID = ""
    @State private var selectedItemID = ""
    @State private var selectedVertex: Int?
    @State private var moveVertices = false
    @State private var shapeKind = "polygon"
    @State private var observationFrame = 0
    @State private var page = 0
    @State private var parentID = ""
    @State private var childID = ""
    @State private var edgeKind = "continuation"
    @State private var geometrySearch = ""
    @State private var observationSearch = ""
    @State private var edgePage = 0
    private var editable: Bool { !session.busy && !session.hasActiveWorkers && !workspace.isHistorical }
    private var isPoints: Bool { workspace.selectedLayer["kind"].string == "points" }
    private var items: [WorkbenchJSON] { workspace.selectedLayer[isPoints ? "points" : "shapes"].array }
    private var item: WorkbenchJSON { items.first { $0["id"].string == selectedItemID } ?? .null }
    private var displayedItems: [WorkbenchJSON] {
        let filtered = items.filter { geometrySearch.isEmpty || ($0["label"].string ?? "").localizedCaseInsensitiveContains(geometrySearch) }
        var values = Array(filtered.prefix(100))
        if item != .null && !values.contains(where: { $0["id"] == item["id"] }) { values.insert(item, at: 0) }
        return values
    }
    private var geometryKind: String { isPoints ? "point" : item["kind"].string ?? "polygon" }
    private var sourceLayers: [WorkbenchJSON] { workspace.layers.filter { ["image", "labels"].contains($0["kind"].string ?? "") } }
    private var sourceReady: Bool { workspace.layerPreview != nil && workspace.layerPreviewID == sourceLayerID && workspace.layerPreviewRevision == session.revision }
    private var points: Binding<[[Double]]> {
        Binding(get: {
            let values = isPoints ? [item["coordinate"]] : item["vertices"].array
            return values.compactMap { value in
                guard let x = value["x"].number, let y = value["y"].number else { return nil }
                return [x, y]
            }
        }, set: { values in
            let coordinates = values.map { WorkbenchJSON.object(["x": .number($0[0]), "y": .number($0[1])]) }
            editItem(isPoints ? "coordinate" : "vertices", isPoints ? coordinates.first ?? .null : .array(coordinates))
            if isPoints, let first = coordinates.first {
                var graph = workspace.document["lineage"].object
                graph["nodes"] = .array(workspace.document["lineage"]["nodes"].array.map { node in
                    guard node["id"].string == selectedItemID else { return node }
                    var changed = node.object; changed["coordinate"] = first; return .object(changed)
                })
                workspace.editDocument("lineage", .object(graph))
            }
        })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Picker("Coordinate source", selection: $sourceLayerID) {
                    Text("Choose raster layer").tag("")
                    ForEach(sourceLayers, id: \.vectorIdentity) { Text($0["name"].string ?? "Image").tag($0["id"].string ?? "") }
                }
                Button("Load source") { session.loadWorkspacePaintSource(layerID: sourceLayerID) }
                    .disabled(!editable || workspace.dirty || sourceLayerID.isEmpty)
            }
            HStack {
                Button("New point layer") { newLayer(kind: "points") }
                Button("New shape layer") { newLayer(kind: "shapes") }
            }.disabled(!editable || !sourceReady)
            if ["points", "shapes"].contains(workspace.selectedLayer["kind"].string ?? "") {
                TextField("Find geometry by label (up to 100 matches)", text: $geometrySearch)
                HStack {
                    Picker("Geometry", selection: $selectedItemID) {
                        Text("Select geometry").tag("")
                        ForEach(Array(displayedItems.enumerated()), id: \.element.vectorIdentity) { index, value in
                            Text(value["label"].string ?? "\(isPoints ? "Point" : "Shape") \(index + 1)").tag(value["id"].string ?? "")
                        }
                    }
                    if !isPoints {
                        Picker("Kind", selection: $shapeKind) {
                            ForEach(["polygon", "rectangle", "ellipse", "line"], id: \.self) { Text($0.capitalized) }
                        }.frame(width: 130)
                    }
                    Button("Add") { addItem() }.disabled(!editable || !sourceReady)
                    Button("Delete") { deleteItem() }.disabled(!editable || item == .null)
                }
                if let source = workspace.layerPreview, sourceReady, item != .null {
                    WorkspaceGeometryCanvas(points: points, selectedVertex: $selectedVertex,
                        kind: geometryKind, editVertices: moveVertices,
                        sourceWidth: Int(workspace.layerGrid.width), sourceHeight: Int(workspace.layerGrid.height), image: source)
                        .frame(minHeight: 220).disabled(!editable)
                    HStack {
                        Toggle("Move existing vertices", isOn: $moveVertices)
                        TextField("Label", text: Binding(get: { item["label"].string ?? "" }, set: { editItem("label", .string($0)) }))
                    }.disabled(!editable)
                    if isPoints {
                        HStack {
                            Stepper("Observation frame \(observationFrame)", value: $observationFrame, in: 0...999999)
                            Button("Use as point-lineage observation") { useObservation() }.disabled(!editable)
                        }
                    }
                    DisclosureGroup("Exact source coordinates") {
                        HStack {
                            Button("Previous") { page = max(0, page - 1) }.disabled(page == 0)
                            Text("\(points.wrappedValue.count) vertices").font(.caption)
                            Button("Next") { page += 1 }.disabled((page + 1) * 25 >= points.wrappedValue.count)
                        }
                        ForEach(Array(points.wrappedValue.indices.dropFirst(page * 25).prefix(25)), id: \.self) { index in
                            HStack {
                                Text("\(index + 1)").font(.caption)
                                TextField("X", value: coordinate(index, axis: 0), format: .number)
                                TextField("Y", value: coordinate(index, axis: 1), format: .number)
                                Button("Remove") { var values = points.wrappedValue; values.remove(at: index); points.wrappedValue = values }
                                    .disabled(isPoints)
                            }.disabled(!editable)
                        }
                    }
                } else {
                    ContentUnavailableView("Choose geometry on an exact source grid", systemImage: "point.topleft.down.curvedto.point.bottomright.up",
                        description: Text("Load a raster layer, then add or select point/shape geometry. Source coordinates are retained before display transforms."))
                }
            } else {
                ContentUnavailableView("Select or create a vector layer", systemImage: "pencil.tip.crop.circle")
            }
            pointGraphControls
            Text("Point and shape layers are presentation geometry. Use Annotations and intensity profiles for calibrated measurements. Deleting an observation also removes its connected point-graph links from this draft; saved history is retained.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .onAppear { if sourceLayerID.isEmpty { sourceLayerID = sourceLayers.first?["id"].string ?? "" } }
        .onChange(of: workspace.selectedLayerID) { _, _ in selectedItemID = ""; selectedVertex = nil; page = 0 }
    }

    private var pointGraphControls: some View {
        DisclosureGroup("Point-lineage correction") {
            let nodes = workspace.document["lineage"]["nodes"].array
            let edges = workspace.document["lineage"]["edges"].array
            TextField("Find observations by label or frame (up to 100 matches)", text: $observationSearch)
            HStack {
                nodePicker("Parent", selection: $parentID, nodes: nodes)
                nodePicker("Child", selection: $childID, nodes: nodes)
            }
            HStack {
                Picker("Relationship", selection: $edgeKind) { ForEach(["continuation", "gap", "division", "merge"], id: \.self) { Text($0.capitalized) } }
                Button("Link observations") { linkObservation() }.disabled(!editable || parentID.isEmpty || childID.isEmpty || parentID == childID)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 5) {
                    ForEach(Array(edges.dropFirst(edgePage * 50).prefix(50)), id: \.vectorIdentity) { edge in
                        HStack {
                            Text(edge["kind"].string?.capitalized ?? "Link").font(.caption)
                            Text("\(nodeLabel(edge["parentID"].string, nodes: nodes)) → \(nodeLabel(edge["childID"].string, nodes: nodes))").font(.caption)
                            Spacer()
                            Button("Unlink") {
                                var graph = workspace.document["lineage"].object
                                graph["edges"] = .array(graph["edges"]?.array.filter { $0["id"] != edge["id"] } ?? [])
                                workspace.editDocument("lineage", .object(graph))
                            }.disabled(!editable)
                        }
                    }
                }
            }.frame(maxHeight: 120)
            HStack {
                Button("Previous links") { edgePage = max(0, edgePage - 1) }.disabled(edgePage == 0)
                Text("\(edges.count) links").font(.caption)
                Button("Next links") { edgePage += 1 }.disabled((edgePage + 1) * 50 >= edges.count)
            }
            Text("Shared graph validation checks time direction and relationships when saving. These explicit point links remain separate from automatic segmented-cell inference.").font(.caption).foregroundStyle(.secondary)
        }
    }
    private func nodePicker(_ title: String, selection: Binding<String>, nodes: [WorkbenchJSON]) -> some View {
        let filtered = nodes.filter { node in
            observationSearch.isEmpty || (node["label"].string ?? "").localizedCaseInsensitiveContains(observationSearch)
                || "T\(node["frame"].integer ?? 0)".localizedCaseInsensitiveContains(observationSearch)
        }
        var displayed = Array(filtered.prefix(100))
        if let selected = nodes.first(where: { $0["id"].string == selection.wrappedValue }),
           !displayed.contains(where: { $0["id"] == selected["id"] }) { displayed.insert(selected, at: 0) }
        return Picker(title, selection: selection) {
            Text("Choose observation").tag("")
            ForEach(displayed, id: \.vectorIdentity) { node in
                Text("T\(node["frame"].integer ?? 0) · \(node["label"].string ?? "point")").tag(node["id"].string ?? "")
            }
        }
    }
    private func nodeLabel(_ id: String?, nodes: [WorkbenchJSON]) -> String {
        guard let node = nodes.first(where: { $0["id"].string == id }) else { return "Unknown" }
        return "T\(node["frame"].integer ?? 0) · \(node["label"].string ?? "point") (\(Int(node["coordinate"]["x"].number ?? 0)), \(Int(node["coordinate"]["y"].number ?? 0)))"
    }
    private func editItem(_ key: String, _ value: WorkbenchJSON) {
        workspace.editLayer(isPoints ? "points" : "shapes", .array(items.map {
            guard $0["id"].string == selectedItemID else { return $0 }; var next = $0.object; next[key] = value; return .object(next)
        }))
    }
    private func coordinate(_ index: Int, axis: Int) -> Binding<Double> {
        Binding(get: { points.wrappedValue.indices.contains(index) ? points.wrappedValue[index][axis] : 0 }, set: { value in
            guard value.isFinite else { return }; var next = points.wrappedValue
            if next.indices.contains(index) { next[index][axis] = value; points.wrappedValue = next }
        })
    }
    private func newLayer(kind: String) {
        guard let source = sourceLayers.first(where: { $0["id"].string == sourceLayerID }) else { return }
        let id = UUID().uuidString
        var layer = source.object
        layer["id"] = .string(id); layer["name"] = .string(kind == "points" ? "Point layer" : "Shape layer")
        layer["kind"] = .string(kind); layer["visible"] = .bool(true); layer["opacity"] = .number(1)
        layer["points"] = kind == "points" ? .array([]) : nil
        layer["shapes"] = kind == "shapes" ? .array([]) : nil
        workspace.editDocument("layers", .array(workspace.layers + [.object(layer)])); workspace.selectedLayerID = id
    }
    private func addItem() {
        let id = UUID().uuidString
        let center = WorkbenchJSON.object(["x": .number(Double(workspace.layerGrid.width / 2)), "y": .number(Double(workspace.layerGrid.height / 2))])
        var value: [String: WorkbenchJSON] = ["id": .string(id), "position": workspace.document["position"], "label": .string(isPoints ? "Point \(items.count + 1)" : "Shape \(items.count + 1)")]
        if isPoints { value["coordinate"] = center }
        else { value["kind"] = .string(shapeKind); value["vertices"] = .array([]) }
        workspace.editLayer(isPoints ? "points" : "shapes", .array(items + [.object(value)])); selectedItemID = id
    }
    private func deleteItem() {
        workspace.editLayer(isPoints ? "points" : "shapes", .array(items.filter { $0["id"].string != selectedItemID }))
        var graph = workspace.document["lineage"].object
        graph["nodes"] = .array(workspace.document["lineage"]["nodes"].array.filter { $0["id"].string != selectedItemID })
        graph["edges"] = .array(workspace.document["lineage"]["edges"].array.filter { $0["parentID"].string != selectedItemID && $0["childID"].string != selectedItemID })
        workspace.editDocument("lineage", .object(graph)); selectedItemID = ""
    }
    private func useObservation() {
        var graph = workspace.document["lineage"].object
        let node = WorkbenchJSON.object(["id": .string(selectedItemID), "frame": .number(Double(observationFrame)), "coordinate": item["coordinate"], "label": item["label"]])
        graph["nodes"] = .array(workspace.document["lineage"]["nodes"].array.filter { $0["id"].string != selectedItemID } + [node])
        workspace.editDocument("lineage", .object(graph))
    }
    private func linkObservation() {
        var graph = workspace.document["lineage"].object
        graph["edges"] = .array(workspace.document["lineage"]["edges"].array + [.object(["id": .string(UUID().uuidString), "parentID": .string(parentID), "childID": .string(childID), "kind": .string(edgeKind)])])
        workspace.editDocument("lineage", .object(graph))
    }
}

private extension WorkbenchJSON { var vectorIdentity: String { self["id"].string ?? "" } }
