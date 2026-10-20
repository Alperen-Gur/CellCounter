import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct WorkbenchSourcesView: View {
    @Bindable var session: WorkbenchSession
    @Bindable var sources: WorkbenchSourceState
    @State private var section = "tiff"
    var body: some View {
        TabView(selection: $section) {
            WorkbenchTIFFSourcesView(session: session, sources: sources).tabItem { Text("TIFF sources") }.tag("tiff")
            WorkbenchStorageView(session: session, storage: session.storage).tabItem { Text("OME-Zarr and tiled analysis") }.tag("zarr")
            WorkbenchOmeroView(session: session, omero: session.omero).tabItem { Text("OMERO") }.tag("omero")
        }.frame(width: 1120, height: 850).disabled(session.busy)
    }
}

private struct WorkbenchTIFFSourcesView: View {
    @Bindable var session: WorkbenchSession
    @Bindable var sources: WorkbenchSourceState
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Large TIFF sources and regions").font(.title2)
                WorkbenchSavedRecordAccess(session: session, catalogues: ["largeSources"])
                Spacer()
                Button("Import TIFF sources…", action: importSources)
                Button("Refresh", action: session.loadLargeSources)
                Button("Done") { dismiss() }
            }.disabled(session.busy)
            Text("Retain a large acquisition, inspect a bounded overview and extract a region at its original pixel resolution. The extracted region becomes a normal Workbench image.")
                .font(.callout).foregroundStyle(.secondary)
            if let error = session.error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            HSplitView {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        Picker("Retained source", selection: Binding(get: { sources.selectedID }, set: session.selectLargeSource)) {
                            Text("Choose a source").tag("")
                            ForEach(sources.sources) { Text($0.name).tag($0.id) }
                        }
                        if let source = sources.selected {
                            Text("\(source.width) × \(source.height) · \(source.dtype) · \(source.axes)").font(.caption)
                            Text("\(source.pageCount) pages · \(source.channels) channels · \(source.access) access")
                                .font(.caption).foregroundStyle(.secondary)
                            ForEach(source.limitations, id: \.self) {
                                Text($0).font(.caption).foregroundStyle(.orange)
                            }
                            if source.access != "unsupported" {
                                Stepper("Page \(sources.pageIndex + 1) of \(source.pageCount)",
                                    value: $sources.pageIndex, in: 0...(source.pageCount - 1))
                                Picker("Channel", selection: $sources.channel) {
                                    ForEach(0..<source.channels, id: \.self) { Text("Channel \($0 + 1)").tag($0) }
                                }
                                Button("Load overview", action: session.refreshSourceOverview)
                                Divider()
                                Text("Source region").font(.headline)
                                Text("Drag a rectangle on the overview or enter exact zero-based source coordinates.")
                                    .font(.caption).foregroundStyle(.secondary)
                                Grid(alignment: .leading) {
                                    regionField("Left X", value: $sources.x)
                                    regionField("Top Y", value: $sources.y)
                                    regionField("Width", value: $sources.width)
                                    regionField("Height", value: $sources.height)
                                }
                                Text("\(Double(sources.width) * Double(sources.height) / 1_000_000, specifier: "%.2f") million pixels · Maximum 16 million per extraction")
                                    .font(.caption).foregroundStyle(sources.validRegion ? Color.secondary : Color.orange)
                                TextField("Extracted image name (optional)", text: $name).textFieldStyle(.roundedBorder)
                                Button("Extract and open region") { session.extractSourceRegion(name: name) }
                                    .buttonStyle(.borderedProminent)
                                    .disabled(!sources.validRegion || !sources.overviewCurrent)
                            }
                            DisclosureGroup("Source calibration and metadata") {
                                WorkbenchStructuredOutput(value: source.descriptor).frame(height: 180)
                            }
                        }
                        Text("Source files up to 512 MiB are retained. The reader uses the first TIFF series with homogeneous pages. Overview sampling changes display only; extraction preserves source values.")
                            .font(.caption).foregroundStyle(.secondary)
                    }.padding(.trailing, 14)
                }.frame(minWidth: 300, idealWidth: 340).disabled(session.busy)
                VStack(alignment: .leading, spacing: 10) {
                    if sources.overviewCurrent, let image = sources.overview, let source = sources.selected {
                        WorkbenchSourceRegionCanvas(image: image, sourceWidth: source.width, sourceHeight: source.height,
                            x: $sources.x, y: $sources.y, width: $sources.width, height: $sources.height,
                            validRegion: sources.validRegion, enabled: !session.busy)
                        Text("Overview only · Region coordinates refer to original pixel edges").font(.caption).foregroundStyle(.secondary)
                    } else {
                        ContentUnavailableView("Load a source overview", systemImage: "viewfinder",
                            description: Text(sources.selected == nil ? "Import a TIFF source to choose an analysis region." :
                                sources.selected?.access == "unsupported" ? "This TIFF layout cannot be accessed safely by the bounded source reader." :
                                "Load the selected page and channel before extracting a region."))
                    }
                }.frame(minWidth: 560).padding(.leading, 14)
            }
            HStack {
                if session.busy { ProgressView().controlSize(.small) }
                Text(session.status).font(.caption).foregroundStyle(.secondary)
                Spacer()
            }
        }.padding(24).frame(width: 1100, height: 730)
        .task { sources.lastExtractedImageID = nil; session.loadLargeSources() }
        .onChange(of: sources.lastExtractedImageID) { _, id in if id != nil { dismiss() } }
    }

    private func regionField(_ label: String, value: Binding<Int>) -> some View {
        GridRow {
            Text(label).font(.caption)
            TextField(label, value: value, format: .number).textFieldStyle(.roundedBorder)
        }
    }

    private func importSources() {
        let panel = NSOpenPanel()
        panel.title = "Choose TIFF sources"
        panel.allowedContentTypes = [.tiff]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.begin { result in
            if result == .OK { session.importLargeSources(panel.urls, seriesIndex: 0) }
        }
    }
}

struct WorkbenchSourceRegionCanvas: View {
    let image: NSImage
    let sourceWidth: Int
    let sourceHeight: Int
    @Binding var x: Int
    @Binding var y: Int
    @Binding var width: Int
    @Binding var height: Int
    let validRegion: Bool
    let enabled: Bool
    var body: some View {
        GeometryReader { geometry in
            let scale = min(geometry.size.width / Double(sourceWidth), geometry.size.height / Double(sourceHeight))
            let rect = CGRect(x: (geometry.size.width - Double(sourceWidth) * scale) / 2,
                              y: (geometry.size.height - Double(sourceHeight) * scale) / 2,
                              width: Double(sourceWidth) * scale, height: Double(sourceHeight) * scale)
            ZStack(alignment: .topLeading) {
                Color.black.opacity(0.08)
                Image(nsImage: image).resizable().frame(width: rect.width, height: rect.height)
                    .position(x: rect.midX, y: rect.midY)
                Canvas { context, _ in
                    guard validRegion else { return }
                    let region = CGRect(x: rect.minX + Double(x) * scale,
                        y: rect.minY + Double(y) * scale,
                        width: Double(width) * scale, height: Double(height) * scale)
                    context.fill(Path(region), with: .color(.accentColor.opacity(0.14)))
                    context.stroke(Path(region), with: .color(.yellow), lineWidth: 2)
                }
            }.contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 2).onChanged { drag in
                    guard enabled, rect.contains(drag.startLocation), scale > 0 else { return }
                    let startX = min(Double(sourceWidth), max(0, (drag.startLocation.x - rect.minX) / scale))
                    let startY = min(Double(sourceHeight), max(0, (drag.startLocation.y - rect.minY) / scale))
                    let endX = min(Double(sourceWidth), max(0, (drag.location.x - rect.minX) / scale))
                    let endY = min(Double(sourceHeight), max(0, (drag.location.y - rect.minY) / scale))
                    x = min(sourceWidth - 1, Int(floor(min(startX, endX))))
                    y = min(sourceHeight - 1, Int(floor(min(startY, endY))))
                    width = max(1, Int(ceil(max(startX, endX))) - x)
                    height = max(1, Int(ceil(max(startY, endY))) - y)
                })
        }
    }
}
