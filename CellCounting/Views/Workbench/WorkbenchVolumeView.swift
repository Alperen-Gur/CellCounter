import AppKit
import SwiftUI

struct WorkbenchVolumeControls: View {
    @Bindable var session: WorkbenchSession
    @Bindable var volume: WorkbenchVolumeState
    @State private var showingLineage = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Volume and time").font(.headline)
            Text("\(volume.dimensions.map(String.init).joined(separator: " × ")) voxels · \(volume.timeCount) time points")
                .font(.caption).foregroundStyle(.secondary)
            Picker("Time point", selection: Binding(get: { volume.timeIndex }, set: { session.changeVolumeFrame(timeIndex: $0) })) {
                ForEach(0..<volume.timeCount, id: \.self) { Text("Time \($0 + 1)").tag($0) }
            }
            Picker("Channel", selection: Binding(get: { volume.channel }, set: { session.changeVolumeFrame(channel: $0) })) {
                ForEach(0..<volume.channels, id: \.self) { Text("Channel \($0 + 1)").tag($0) }
            }
            if session.task == .segmentation {
            Divider()
            Text("3D segmentation").font(.headline)
            Picker("Method", selection: $volume.method) {
                Text("Otsu threshold").tag("otsu")
                Text("Manual threshold").tag("manual")
            }
            Picker("Foreground", selection: $volume.polarity) {
                Text("Bright objects").tag("bright")
                Text("Dark objects").tag("dark")
            }
            if volume.method == "manual" { field("Raw threshold", value: $volume.threshold) }
            integer("Minimum volume (voxels)", value: $volume.minVolumeVox)
            integer("Split distance (voxels)", value: $volume.minDistanceVox)
            HStack {
                Button("Preview") { session.analyzeVolume(previewOnly: true) }
                Button("Run 3D analysis") { session.analyzeVolume(previewOnly: false) }.buttonStyle(.borderedProminent)
            }
            Text("Threshold and 3D watershed use source intensities. Rendering uses a sampled display volume.")
                .font(.caption).foregroundStyle(.secondary)
            }
            if session.task == .preparation {
            Divider()
            Text("Voxel calibration").font(.headline)
            calibratedField("X (µm/voxel)", known: $volume.knownX, value: $volume.voxelXUm)
            calibratedField("Y (µm/voxel)", known: $volume.knownY, value: $volume.voxelYUm)
            calibratedField("Z (µm/voxel)", known: $volume.knownZ, value: $volume.voxelZUm)
            calibratedField("Time interval (seconds)", known: $volume.knownTime, value: $volume.timeStepSeconds)
            Text("Unchecked values are unknown. Apply to clear an incorrect calibration.")
                .font(.caption).foregroundStyle(.secondary)
            Button("Apply voxel calibration", action: session.applyVolumeCalibration).disabled(!validCalibration)
            }
            if session.task == .measurements, volume.timeCount > 1 { tracks }
        }
        .sheet(isPresented: $showingLineage) {
            WorkbenchLineageView(session: session, lineage: session.lineage)
        }
    }

    private var tracks: some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider()
            Text("Tracks").font(.headline)
            Text(volume.tracks?["status"].string == "stale" ? "Tracks are stale after a source or label change." :
                    "Analyze at least two time points, then link objects.")
                .font(.caption).foregroundStyle(volume.tracks?["status"].string == "stale" ? Color.orange : Color.secondary)
            field("Maximum linking distance", value: $volume.trackMaxDistance)
            Picker("Distance units", selection: $volume.trackUnits) {
                Text("Voxels").tag("voxel")
                if volume.calibrated { Text("Micrometres").tag("um") }
            }
            Stepper("Allowed missing frames: \(volume.trackMaxGapFrames)", value: $volume.trackMaxGapFrames, in: 0...10)
                .font(.caption)
            Button("Compute tracks", action: session.runVolumeTracks)
                .disabled(analyzedTimes < 2 || !volume.trackMaxDistance.isFinite || volume.trackMaxDistance <= 0)
            Text("Tracking computes one-to-one links. Review divisions in the separate lineage graph.")
                .font(.caption).foregroundStyle(.secondary)
            Button("Lineages and divisions…") { showingLineage = true }
            DisclosureGroup("Correct a link") {
                VStack(alignment: .leading, spacing: 8) {
                    integer("Source time (1-based)", value: $volume.trackSourceTime)
                    integer("Source object", value: $volume.trackSourceLabel)
                    integer("Target time (1-based)", value: $volume.trackTargetTime)
                    integer("Target object", value: $volume.trackTargetLabel)
                    HStack {
                        Button("Link") { session.editVolumeTrack(link: true) }
                        Button("Unlink") { session.editVolumeTrack(link: false) }
                    }.disabled(!validLink)
                }.padding(.top, 8)
            }
            if let tracks = volume.tracks {
                Text("\(tracks["tracks"].array.count) tracks · \(tracks["edges"].array.count) links")
                    .font(.caption).foregroundStyle(.secondary)
                ScrollView {
                    VStack(alignment: .leading, spacing: 7) {
                        ForEach(Array(tracks["tracks"].array.enumerated()), id: \.offset) { _, track in
                            Text("Track \(track["trackId"].integer ?? 0): " + track["observations"].array.map {
                                "T\(($0["timeIndex"].integer ?? 0) + 1)/#\($0["labelId"].integer ?? 0)"
                            }.joined(separator: " → "))
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.font(.caption.monospaced()).frame(maxHeight: 140).textSelection(.enabled)
            }
        }
    }

    private var analyzedTimes: Int {
        volume.inspection["frames"].array.filter { $0["channel"].integer == volume.channel }.count
    }
    private var validLink: Bool {
        volume.trackSourceTime >= 1 && volume.trackTargetTime <= volume.timeCount &&
        volume.trackTargetTime > volume.trackSourceTime && volume.trackSourceLabel > 0 && volume.trackTargetLabel > 0
    }
    private var validCalibration: Bool {
        [(volume.knownX, volume.voxelXUm), (volume.knownY, volume.voxelYUm),
         (volume.knownZ, volume.voxelZUm), (volume.knownTime, volume.timeStepSeconds)].allSatisfy {
            !$0.0 || ($0.1.isFinite && $0.1 > 0)
        }
    }
    private func calibratedField(_ title: String, known: Binding<Bool>, value: Binding<Double>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle(title, isOn: known).font(.caption)
            TextField(title, value: value, format: .number).textFieldStyle(.roundedBorder)
                .disabled(!known.wrappedValue).accessibilityLabel(title)
        }
    }
    private func field(_ title: String, value: Binding<Double>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            TextField(title, value: value, format: .number).textFieldStyle(.roundedBorder).accessibilityLabel(title)
        }
    }
    private func integer(_ title: String, value: Binding<Int>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            TextField(title, value: value, format: .number).textFieldStyle(.roundedBorder).accessibilityLabel(title)
        }
    }
}

struct WorkbenchVolumeStage: View {
    @Bindable var session: WorkbenchSession
    @Bindable var volume: WorkbenchVolumeState

    private var compositeDisplay: WorkbenchJSON? { session.displayedVolumeComposite }
    private var display: WorkbenchJSON? {
        volume.parametersChanged ? nil : (compositeDisplay ?? volume.display)
    }
    private var displayIdentity: String {
        compositeDisplay == nil ? "analysis:\(volume.generation)" : "composite:\(session.composite.volumeRenderID)"
    }
    private var renderLabel: String {
        if volume.isPreview { return "Unsaved 3D preview" }
        if compositeDisplay != nil {
            let pending = session.composite.volumeHasDraftChanges ? " · display changes pending" : ""
            let labels = compositeDisplay?["labelStatus"].string == "current"
                ? "saved labels channel \(volume.channel + 1)" : "no saved labels"
            return "Sampled 3D composite · \(labels)\(pending)"
        }
        if session.composite.volumeEnabled && !session.volumeCompositeCurrent {
            return "Analysis volume · render the 3D composite again for this selection"
        }
        return "Sampled 3D rendering · click a plane to inspect source coordinates"
    }

    var body: some View {
        VSplitView {
            VStack(spacing: 0) {
                ZStack {
                    WorkbenchVolumeWebView(descriptor: display, descriptorIdentity: displayIdentity,
                        generation: volume.generation,
                        crosshair: volume.crosshair,
                        onPointer: { session.handleVolumePointer(voxel: $0, plane: $1, generation: $2) },
                        onStatus: { volume.viewerStatus = $0 })
                        .opacity(display == nil ? 0 : 1)
                        .allowsHitTesting(display != nil && !session.busy)
                        .accessibilityHidden(display == nil)
                        .disabled(session.busy || display == nil)
                    if display == nil {
                        ContentUnavailableView(volume.parametersChanged ? "Settings changed" : "Volume preview",
                            systemImage: "cube.transparent",
                            description: Text(volume.parametersChanged ? "Preview or run to update the volume and labels." : "Loading the selected volume…"))
                    }
                }
                HStack {
                    Text(renderLabel)
                    Spacer()
                    if let display {
                        Text(display["dimensions"].array.compactMap(\.integer).map(String.init).joined(separator: " × "))
                    }
                }.font(.caption).foregroundStyle(volume.isPreview ? Color.orange : Color.secondary).padding(7)
                if !volume.viewerStatus.isEmpty {
                    Text(volume.viewerStatus).font(.caption).foregroundStyle(.secondary).padding(.horizontal, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }.frame(minHeight: 220, idealHeight: 320)
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Text("Source plane").font(.caption.weight(.semibold))
                    Picker("Plane", selection: Binding(get: { volume.plane }, set: { session.changeVolumeSlice(plane: $0) })) {
                        Text("XY").tag("xy"); Text("XZ").tag("xz"); Text("YZ").tag("yz")
                    }.pickerStyle(.segmented).frame(width: 150)
                    Stepper("Plane \(volume.index + 1) / \(volume.indexCount)",
                        value: Binding(get: { volume.index }, set: { session.changeVolumeSlice(index: $0) }),
                        in: 0...max(0, volume.indexCount - 1)).font(.caption.monospacedDigit())
                    Spacer()
                    Text("Exact label coordinates").font(.caption).foregroundStyle(.secondary)
                }.padding(8).disabled(session.busy || volume.isPreview)
                WorkbenchSourcePlane(session: session, volume: volume)
            }.frame(minHeight: 180, idealHeight: 260)
        }
    }
}

private struct WorkbenchSourcePlane: View {
    @Bindable var session: WorkbenchSession
    @Bindable var volume: WorkbenchVolumeState
    @State private var zoom = 0.0
    @FocusState private var planeFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("\(volume.sliceWidth) × \(volume.sliceHeight) source pixels\(displayLabel)")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Picker("Source plane zoom", selection: $zoom) {
                    Text("Fit").tag(0.0); Text("1:1").tag(1.0); Text("2×").tag(2.0)
                    Text("4×").tag(4.0); Text("8×").tag(8.0)
                }.frame(width: 140)
            }.padding(.horizontal, 9).padding(.vertical, 4)
        GeometryReader { geometry in
            let size = CGSize(width: volume.sliceWidth, height: volume.sliceHeight)
            let scale = zoom > 0 ? zoom : min(geometry.size.width / size.width, geometry.size.height / size.height)
            let canvasWidth = max(geometry.size.width, size.width * scale)
            let canvasHeight = max(geometry.size.height, size.height * scale)
            let rect = CGRect(x: (canvasWidth - size.width * scale) / 2,
                              y: (canvasHeight - size.height * scale) / 2,
                              width: size.width * scale, height: size.height * scale)
            ScrollView([.horizontal, .vertical]) {
            ZStack {
                Color.black.opacity(0.9)
                if let image = session.displayedComposite ?? volume.sliceImage, volume.sliceIsCurrent, !volume.isPreview {
                    Image(nsImage: image).resizable().interpolation(.none)
                        .frame(width: rect.width, height: rect.height).position(x: rect.midX, y: rect.midY)
                    if !volume.parametersChanged, let overlay = session.measurementPage.volumeOverlay {
                        Image(nsImage: overlay).resizable().interpolation(.none)
                            .frame(width: rect.width, height: rect.height).position(x: rect.midX, y: rect.midY).allowsHitTesting(false)
                    }
                    Canvas { context, _ in
                        if !volume.parametersChanged {
                            for contour in volume.sliceContours where volume.selectedLabels.contains(contour.id) {
                                let selected = volume.selectedLabels.contains(contour.id)
                                context.stroke(path(contour.loops, rect: rect, scale: scale),
                                    with: .color(selected ? .yellow : .cyan), lineWidth: selected ? 2.5 : 1)
                            }
                        }
                        if !volume.polygon.isEmpty {
                            context.stroke(path([volume.polygon], rect: rect, scale: scale, close: false),
                                with: .color(.orange), style: StrokeStyle(lineWidth: 2, dash: [4, 3]))
                        }
                    }.contentShape(Rectangle())
                        .onTapGesture { point in planeFocused = true; click(point, rect: rect, scale: scale) }
                        .accessibilityLabel("Exact source plane editor. Selected plane coordinates map directly to source voxels.")
                } else {
                    Text(volume.isPreview ? "Run 3D analysis to inspect and correct saved labels." : "Loading source plane…")
                        .font(.callout).foregroundStyle(.white.opacity(0.8))
                }
            }.frame(width: canvasWidth, height: canvasHeight)
                .focusable().focused($planeFocused)
                .onKeyPress(keys: [.delete, .deleteForward, .escape, .return, .init("z")]) { press in
                    guard !session.busy, !KeyboardShortcutContext.isEditingText,
                          !KeyboardShortcutContext.hasNativeSheet else { return .ignored }
                    if press.key == .escape, press.modifiers.isEmpty {
                        volume.polygon = []; volume.selectedLabels = []; volume.editMode = "select"
                        return .handled
                    }
                    guard volume.canEdit else { return .ignored }
                    if press.key == .init("z"), press.modifiers == .command { session.undoVolume(); return .handled }
                    guard press.modifiers.isEmpty else { return .ignored }
                    if press.key == .return, volume.editMode == "polygon", volume.polygon.count >= 3,
                       !volume.polygonReplaceSelected || volume.selectedLabels.count == 1 {
                        session.editVolume("polygon"); return .handled
                    }
                    if press.key == .delete || press.key == .deleteForward {
                        if volume.editMode == "polygon", !volume.polygon.isEmpty { volume.polygon.removeLast(); return .handled }
                        if volume.editMode == "select", !volume.selectedLabels.isEmpty { session.editVolume("delete"); return .handled }
                    }
                    return .ignored
                }
            }
        }
        }
    }

    private var displayLabel: String {
        if session.displayedComposite != nil {
            return session.composite.hasDraftChanges ? " · Composite changes pending" : " · Composite display"
        }
        return session.composite.enabled ? " · Preview composite for this selection" : ""
    }

    private func path(_ loops: [[[Double]]], rect: CGRect, scale: Double, close: Bool = true) -> Path {
        var path = Path()
        for loop in loops {
            guard let first = loop.first, first.count == 2 else { continue }
            path.move(to: CGPoint(x: rect.minX + first[0] * scale, y: rect.minY + first[1] * scale))
            for point in loop.dropFirst() where point.count == 2 {
                path.addLine(to: CGPoint(x: rect.minX + point[0] * scale, y: rect.minY + point[1] * scale))
            }
            if close { path.closeSubpath() }
        }
        return path
    }

    private func click(_ point: CGPoint, rect: CGRect, scale: Double) {
        guard !session.busy, volume.canEdit, rect.contains(point), scale > 0 else { return }
        let u = min(Double(volume.sliceWidth) - 0.0001, max(0, (point.x - rect.minX) / scale))
        let v = min(Double(volume.sliceHeight) - 0.0001, max(0, (point.y - rect.minY) / scale))
        if volume.editMode == "polygon" { volume.polygon.append([u, v]); return }
        if volume.editMode == "paint" || volume.editMode == "erase" {
            session.editVolume("brush", point: [u, v]); return
        }
        let point3D: [Double]
        switch volume.plane {
        case "xz": point3D = [u, Double(volume.index) + 0.5, v]
        case "yz": point3D = [Double(volume.index) + 0.5, u, v]
        default: point3D = [u, v, Double(volume.index) + 0.5]
        }
        session.pickSavedLabel(x: point3D[0], y: point3D[1], z: point3D[2],
            extending: NSEvent.modifierFlags.contains(.command) || NSEvent.modifierFlags.contains(.shift))
    }
}

struct WorkbenchVolumeCorrectionBar: View {
    @Bindable var session: WorkbenchSession
    @Bindable var volume: WorkbenchVolumeState

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 10) {
                Picker("Correction tool", selection: $volume.editMode) {
                    Text("Select").tag("select"); Text("Polygon").tag("polygon")
                    Text("3D brush").tag("paint"); Text("3D eraser").tag("erase")
                }.frame(width: 190)
                .onChange(of: volume.editMode) { _, _ in volume.polygon = [] }
                Button("Delete") { session.editVolume("delete") }.disabled(volume.selectedLabels.isEmpty)
                Button("Merge") { session.editVolume("merge") }.disabled(volume.selectedLabels.count < 2)
                Button("Undo", action: session.undoVolume)
                Text("\(volume.selectedLabels.count) selected").font(.caption).foregroundStyle(.secondary)
                Spacer()
            }
            if volume.editMode == "polygon" {
                HStack {
                    Toggle("Replace selected object's plane", isOn: $volume.polygonReplaceSelected).font(.caption)
                    Button("Save polygon") { session.editVolume("polygon") }
                        .disabled(volume.polygon.count < 3 || (volume.polygonReplaceSelected && volume.selectedLabels.count != 1))
                    Button("Clear") { volume.polygon = [] }
                }
                Text("Click source-plane vertices. Return saves; Delete removes the last vertex; Escape clears. Other planes are preserved.")
                    .font(.caption).foregroundStyle(.secondary)
            } else if volume.editMode == "paint" || volume.editMode == "erase" {
                HStack {
                    Text("Object").font(.caption)
                    TextField("Object label", value: $volume.paintLabel, format: .number).frame(width: 70)
                    Text("Sphere radius (voxels)").font(.caption)
                    TextField("Brush radius", value: $volume.brushRadiusVox, format: .number).frame(width: 70)
                    Text("Click source plane to apply a 3D sphere.").font(.caption).foregroundStyle(.secondary)
                }.textFieldStyle(.roundedBorder)
            }
        }.padding(9).disabled(session.busy || !volume.canEdit)
    }
}

struct WorkbenchVolumeMeasurements: View {
    @Bindable var session: WorkbenchSession
    @Bindable var volume: WorkbenchVolumeState

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if !volume.parametersChanged {
                WorkbenchSupportNote(support: volume.validSupport, volume: true).padding(.horizontal, 10)
            }
            if !volume.isPreview { WorkbenchMeasurementPageControls(session: session, page: session.measurementPage, volume: true).padding(.horizontal, 10) }
            else { Text("Unsaved preview: \(volume.cells.count) displayed rows of \(session.measurementPage.total) objects. Run analysis for paged measurements.").font(.caption).padding(.horizontal, 10) }
            Table(volume.parametersChanged ? [] : volume.cells, selection: Binding(get: {
                volume.selectedLabels.intersection(Set(volume.cells.map(\.id)))
            }, set: { next in
                let outside = volume.selectedLabels.subtracting(Set(volume.cells.map(\.id)))
                session.selectSavedLabels(outside.union(next))
            })) {
                TableColumn("Object") { Text(String($0.id)) }.width(min: 50, ideal: 60)
                TableColumn("Voxels") { Text(String($0.voxelCount)) }
                TableColumn("Volume (µm³)") { Text(format($0.volumeUm3)) }
                TableColumn("Diameter (µm)") { Text(format($0.diameterUm)) }
                TableColumn("Centroid (voxel)") { Text($0.centroid.map { String(format: "%.1f", $0) }.joined(separator: ", ")) }
                TableColumn("Mean intensity") { Text(format($0.meanIntensity)) }
            }
        }.font(.caption.monospacedDigit()).disabled(session.busy || volume.parametersChanged || volume.isPreview)
    }
    private func format(_ value: Double?) -> String { value.map { String(format: "%.3f", $0) } ?? "—" }
}
