import AppKit
import Charts
import SwiftUI
import UniformTypeIdentifiers

struct WorkbenchAnnotationsView: View {
    @Bindable var session: WorkbenchSession
    @Bindable var annotations: WorkbenchAnnotationState
    @Environment(\.dismiss) private var dismiss
    @State private var vertexPage = 0
    @State private var physicalProfile = false

    private var image: WorkbenchImage? { session.images.first { $0.id == annotations.imageID } }
    private var sliceCount: Int {
        guard let image else { return 1 }
        switch annotations.plane {
        case "xz": return image.height
        case "yz": return image.width
        default: return image.zCount
        }
    }
    private var resultCurrent: Bool { annotations.measurementCurrent(revision: session.revision) }
    private var vertexIndices: [Int] {
        let start = min(vertexPage * 100, max(0, annotations.points.count - 1) / 100 * 100)
        return Array(start..<min(start + 100, annotations.points.count))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Annotations and intensity profiles").font(.title2)
                Spacer()
                if annotations.dirty { Text("Unsaved geometry").font(.caption).foregroundStyle(.orange) }
                Button("Done") { dismiss() }.disabled(session.busy)
            }
            Text("Draw in source pixel coordinates. Measurements use current calibration; channel overrides change sampled intensities while preserving the saved geometry.")
                .font(.callout).foregroundStyle(.secondary)
            if let error = session.error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            HSplitView {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(image?.name ?? "Image").font(.headline)
                        Picker("Saved annotation", selection: Binding(
                            get: { annotations.selectedID }, set: session.selectAnnotation)) {
                            Text("New annotation").tag("")
                            ForEach(Array(annotations.records.enumerated()), id: \.offset) { _, item in
                                Text("\(item["name"].string ?? "Annotation")\(item["deleted"].bool == true ? " · Deleted" : "")")
                                    .tag(item["id"].string ?? "")
                            }
                        }
                        HStack {
                            Button("New", action: annotations.newDraft)
                            Button("Reload saved") { session.selectAnnotation(annotations.selectedID) }
                                .disabled(annotations.selectedID.isEmpty)
                        }
                        DisclosureGroup("Import annotation geometry") {
                            VStack(alignment: .leading, spacing: 7) {
                                Button("Choose annotation JSON…", action: chooseAnnotationImport)
                                    .disabled(annotations.dirty)
                                if annotations.dirty {
                                    Text("Save or explicitly reload the edited geometry before importing.")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                if let preview = annotations.importPreview {
                                    Text(preview["source"]["name"].string ?? "Annotation JSON").font(.callout.bold())
                                    let imported = preview["annotation"]
                                    Text("\(imported["name"].string ?? "Annotation") · \(imported["geometry"]["type"].string ?? "Geometry") · \(imported["geometry"]["points"].array.count) vertices")
                                        .font(.caption)
                                    Text(imported["target"].string == "volume"
                                        ? "Volume slice · \((imported["selection"]["plane"].string ?? "xy").uppercased()) · Time \((imported["selection"]["timeIndex"].integer ?? 0) + 1) · Slice \((imported["selection"]["index"].integer ?? 0) + 1)"
                                        : "2D projection · \(imported["selection"]["sourceParameters"]["zProjection"].string ?? "max")")
                                        .font(.caption).foregroundStyle(.secondary)
                                    Text(preview["compatibility"]["sourceMatches"].bool == true
                                        ? "Source content and coordinate grid match."
                                        : "Source compatibility has not been confirmed.")
                                        .font(.caption)
                                    if preview["compatibility"]["calibrationMatches"].bool != true {
                                        Text("Calibration differs. Measurements will use this project's current calibration.")
                                            .font(.caption).foregroundStyle(.orange)
                                    }
                                    ForEach(preview["notes"].array.compactMap(\.string), id: \.self) {
                                        Text($0).font(.caption).foregroundStyle(.secondary)
                                    }
                                    HStack {
                                        Button("Import as new annotation", action: session.importAnnotation)
                                            .disabled(annotations.dirty || session.hasActiveWorkers ||
                                                preview["compatibility"]["sourceMatches"].bool != true)
                                        Button("Dismiss preview") {
                                            annotations.importPath = nil; annotations.importPreview = nil
                                        }
                                    }
                                }
                            }.padding(.top, 6)
                        }
                        TextField("Annotation name", text: $annotations.name).textFieldStyle(.roundedBorder)
                        TextField("Notes", text: $annotations.notes, axis: .vertical)
                            .textFieldStyle(.roundedBorder).lineLimit(2...4)
                        Picker("Geometry", selection: $annotations.kind) {
                            Text("Point").tag("point"); Text("Line").tag("line")
                            Text("Polyline").tag("polyline"); Text("Polygon").tag("polygon")
                        }
                        Picker("Canvas tool", selection: $annotations.editVertices) {
                            Text("Draw vertices").tag(false); Text("Move vertices").tag(true)
                        }.pickerStyle(.segmented)
                        Text(annotations.editVertices
                            ? "Drag a vertex to move it, or enter its exact coordinates below."
                            : "Click to place vertices. Lines use two points; polylines and polygons use successive clicks. Polygon boundaries close automatically.")
                            .font(.caption).foregroundStyle(.secondary)
                        HStack {
                            Button("Remove last vertex") {
                                if !annotations.points.isEmpty { annotations.points.removeLast(); annotations.selectedVertex = nil }
                            }.disabled(annotations.points.isEmpty)
                            Button("Clear geometry") { annotations.points = []; annotations.selectedVertex = nil }
                                .disabled(annotations.points.isEmpty)
                        }
                        DisclosureGroup("Source selection") {
                            sourceControls
                        }
                        if !annotations.sourceCurrent {
                            Button("Load selected source", action: session.refreshAnnotationSource)
                                .buttonStyle(.borderedProminent)
                        }
                        DisclosureGroup("Exact vertices (\(annotations.points.count))") {
                            VStack(alignment: .leading, spacing: 6) {
                                if annotations.points.count > 100 {
                                    Stepper("Page \(vertexPage + 1)", value: $vertexPage,
                                            in: 0...max(0, (annotations.points.count - 1) / 100))
                                }
                                ForEach(vertexIndices, id: \.self) { index in
                                    HStack(spacing: 6) {
                                        Text("\(index + 1)").frame(width: 25)
                                        TextField("U", value: vertexBinding(index, axis: 0), format: .number)
                                        TextField("V", value: vertexBinding(index, axis: 1), format: .number)
                                        Button {
                                            annotations.points.remove(at: index); annotations.selectedVertex = nil
                                        } label: { Image(systemName: "minus.circle") }
                                    }.textFieldStyle(.roundedBorder)
                                }
                                Text("U and V follow the displayed horizontal and vertical source axes. Sample centres are index + 0.5.")
                                    .font(.caption).foregroundStyle(.secondary)
                            }.padding(.top, 6)
                        }
                        Divider()
                        Picker("Measurement channel", selection: $annotations.measurementChannel) {
                            ForEach(0..<(image?.channels ?? 1), id: \.self) { Text("Channel \($0 + 1)").tag($0) }
                        }
                        if ["line", "polyline"].contains(annotations.kind) {
                            Toggle("Set profile sample count", isOn: $annotations.useFixedProfileSamples)
                            if annotations.useFixedProfileSamples {
                                Stepper("\(annotations.profileSamples) samples", value: $annotations.profileSamples, in: 2...4096)
                            }
                            Text("Samples are uniform in pixel arc length. Missing values remain gaps in the profile.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        HStack {
                            Button("Measure", action: session.measureAnnotation).disabled(!annotations.canMeasure)
                            Button("Save annotation", action: session.saveAnnotation)
                                .buttonStyle(.borderedProminent)
                                .disabled(!annotations.canMeasure || session.hasActiveWorkers)
                        }
                        if !annotations.selectedID.isEmpty {
                            HStack {
                                Button("Delete", role: .destructive, action: session.deleteAnnotation)
                                    .disabled(annotations.deleted || annotations.dirty || session.hasActiveWorkers)
                                Button("Undo saved change", action: session.undoAnnotation)
                                    .disabled(annotations.savedRecord?["undoAvailable"].bool != true ||
                                              annotations.dirty || session.hasActiveWorkers)
                            }
                            if annotations.deleted {
                                Text("This saved annotation is deleted. Undo restores its preceding state.")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            DisclosureGroup("Revision history") {
                                WorkbenchStructuredOutput(value: .object([
                                    "history": annotations.savedRecord?["history"] ?? .array([])
                                ])).frame(height: 160)
                            }
                            DisclosureGroup("Export saved annotation") {
                                VStack(alignment: .leading, spacing: 7) {
                                    Picker("Format", selection: $annotations.exportFormatID) {
                                        ForEach(annotations.exportFormats) { Text($0.name).tag($0.id) }
                                    }
                                    if let format = annotations.exportFormats.first(where: { $0.id == annotations.exportFormatID }) {
                                        Text(format.description).font(.caption).foregroundStyle(.secondary)
                                    }
                                    Button("Choose destination…", action: exportAnnotation)
                                        .disabled(annotations.deleted || annotations.dirty || session.hasActiveWorkers ||
                                            (annotations.exportFormatID == "profile-csv" && !["line", "polyline"].contains(annotations.kind)))
                                    if annotations.dirty {
                                        Text("Save the edited geometry before exporting.").font(.caption).foregroundStyle(.secondary)
                                    }
                                    if let path = annotations.exportResult?["destination"].string {
                                        Button("Show last export in Finder") {
                                            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                                        }
                                    }
                                }.padding(.top, 6)
                            }
                        }
                    }.padding(.trailing, 12)
                }.frame(minWidth: 350, idealWidth: 400, maxWidth: 450).disabled(session.busy)
                VStack(alignment: .leading, spacing: 10) {
                    if annotations.sourceCurrent, let source = annotations.sourceImage {
                        WorkbenchAnnotationCanvas(annotations: annotations, image: source)
                            .frame(minHeight: 260)
                            .disabled(session.busy || annotations.deleted)
                        Text("Geometry source · Channel \(annotations.channel + 1) · \(annotations.sourceWidth) × \(annotations.sourceHeight) source samples")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        ContentUnavailableView("Load annotation source", systemImage: "pencil.and.outline",
                            description: Text("Load the selected plane before drawing or measuring geometry."))
                            .frame(minHeight: 260)
                    }
                    if resultCurrent, let measured = annotations.result?["measurement"] {
                        annotationResults(measured)
                    } else {
                        Text(annotations.result == nil ? "Measure a point, line, polyline or polygon to inspect its calibrated metrics and intensities."
                             : "Geometry, source selection or calibration changed. Measure again for current results.")
                            .font(.callout).foregroundStyle(.secondary).frame(minHeight: 100)
                    }
                }.padding(.leading, 12).frame(minWidth: 540)
            }
            HStack {
                if session.busy { ProgressView().controlSize(.small) }
                Text(session.status).font(.caption).foregroundStyle(.secondary)
                Spacer()
            }
        }.padding(24).frame(width: 1160, height: 800)
        .task { session.loadAnnotations() }
        .onDisappear { annotations.editorOpen = false }
        .onChange(of: annotations.plane) { _, _ in annotations.index = min(annotations.index, sliceCount - 1) }
        .onChange(of: annotations.selectedID) { _, _ in vertexPage = 0 }
    }

    private var sourceControls: some View {
        VStack(alignment: .leading, spacing: 7) {
            if image?.supportsVolume == true {
                Picker("Source view", selection: $annotations.target) {
                    if (image?.timeCount ?? 1) <= 1 { Text("2D projection").tag("plane") }
                    Text("Orthogonal volume slice").tag("volume")
                }
                if (image?.timeCount ?? 1) > 1 {
                    Text("Time series annotations retain an explicit time point and slice.").font(.caption).foregroundStyle(.secondary)
                }
            }
            Picker("Geometry source channel", selection: $annotations.channel) {
                ForEach(0..<(image?.channels ?? 1), id: \.self) { Text("Channel \($0 + 1)").tag($0) }
            }
            if annotations.target == "volume" {
                Stepper("Time \(annotations.timeIndex + 1)", value: $annotations.timeIndex,
                        in: 0...max(0, (image?.timeCount ?? 1) - 1))
                Picker("Plane", selection: $annotations.plane) {
                    Text("XY").tag("xy"); Text("XZ").tag("xz"); Text("YZ").tag("yz")
                }
                Stepper("Slice \(annotations.index + 1) of \(sliceCount)", value: $annotations.index,
                        in: 0...(sliceCount - 1))
            } else {
                Picker("Z projection", selection: $annotations.projection) {
                    Text("Maximum").tag("max"); Text("Mean").tag("mean"); Text("Middle plane").tag("middle")
                }
                Text("Projected annotations use the first time point.").font(.caption).foregroundStyle(.secondary)
            }
        }.padding(.top, 6)
    }

    private func vertexBinding(_ index: Int, axis: Int) -> Binding<Double> {
        Binding(get: { annotations.points.indices.contains(index) ? annotations.points[index][axis] : 0 },
                set: { if $0.isFinite && annotations.points.indices.contains(index) { annotations.points[index][axis] = $0 } })
    }

    private func exportAnnotation() {
        guard let format = annotations.exportFormats.first(where: { $0.id == annotations.exportFormatID }) else { return }
        let panel = NSSavePanel()
        panel.title = "Export \(format.name)"
        panel.prompt = "Export"
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.allowsOtherFileTypes = false
        if let type = UTType(filenameExtension: format.fileExtension) { panel.allowedContentTypes = [type] }
        let stem = annotations.name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        panel.nameFieldStringValue = "\(stem)-\(format.id).\(format.fileExtension)"
        panel.message = "Choose a new file. Existing files will be preserved."
        panel.begin { response in
            guard response == .OK, let destination = panel.url else { return }
            session.exportAnnotation(to: destination)
        }
    }

    private func chooseAnnotationImport() {
        let panel = NSOpenPanel()
        panel.title = "Preview annotation geometry"
        panel.allowedContentTypes = [.json]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose a CellCounter geometry JSON export from the same acquisition. Import creates a new annotation."
        panel.begin { response in
            guard response == .OK, let source = panel.url else { return }
            session.previewAnnotationImport(source)
        }
    }

    @ViewBuilder
    private func annotationResults(_ measured: WorkbenchJSON) -> some View {
        let profile = measured["profile"]
        if !profile["values"].array.isEmpty {
            let hasPhysical = profile["positionsUm"].array.allSatisfy { $0.number != nil }
            HStack {
                Text("Intensity profile · Channel \((measured["measurementChannel"].integer ?? 0) + 1)").font(.headline)
                Spacer()
                Toggle("µm", isOn: $physicalProfile).disabled(!hasPhysical).toggleStyle(.switch).controlSize(.small)
            }
            WorkbenchAnnotationProfile(profile: profile, physical: physicalProfile && hasPhysical)
                .frame(height: 150)
        }
        WorkbenchSupportNote(support: measured["validSupport"])
        WorkbenchStructuredOutput(value: .object([
            "geometry": measured["geometry"], "intensity": measured["intensity"],
            "pixelSpacingUm": measured["pixelSpacingUm"]
        ])).frame(height: 125)
        DisclosureGroup("Measurement conventions") {
            ScrollView {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(measured["notes"].array.compactMap(\.string), id: \.self) {
                        Text($0).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }.frame(maxHeight: 110)
        }
    }
}

private struct WorkbenchAnnotationCanvas: View {
    @Bindable var annotations: WorkbenchAnnotationState
    let image: NSImage
    var body: some View {
        WorkspaceGeometryCanvas(points: $annotations.points, selectedVertex: $annotations.selectedVertex,
            kind: annotations.kind, editVertices: annotations.editVertices,
            sourceWidth: annotations.sourceWidth, sourceHeight: annotations.sourceHeight, image: image)
    }
}

private struct WorkbenchAnnotationProfile: View {
    let profile: WorkbenchJSON
    let physical: Bool
    private struct Sample: Identifiable {
        let id: Int
        let distance: Double
        let intensity: Double
        let segment: Int
    }
    private var samples: [Sample] {
        let positions = profile[physical ? "positionsUm" : "positionsPx"].array
        var segment = 0
        return profile["values"].array.enumerated().compactMap { index, value in
            guard positions.indices.contains(index), let x = positions[index].number, let y = value.number else {
                segment += 1
                return nil
            }
            return Sample(id: index, distance: x, intensity: y, segment: segment)
        }
    }
    var body: some View {
        Chart(samples) { point in
            LineMark(x: .value("Distance", point.distance), y: .value("Intensity", point.intensity),
                     series: .value("Continuous segment", point.segment))
                .foregroundStyle(Color.accentColor)
        }
        .chartXAxisLabel(physical ? "Distance (µm)" : "Distance (pixels)")
        .chartYAxisLabel("Source intensity")
        .chartLegend(.hidden)
    }
}
