import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct WorkbenchStorageView: View {
    @Bindable var session: WorkbenchSession
    @Bindable var storage: WorkbenchStorageState
    @Environment(\.dismiss) private var dismiss
    private var writesBlocked: Bool { session.busy || session.hasActiveWorkers || !session.canRefreshWithoutDiscardingEdits }
    private var planCurrent: Bool { storage.plan != .null && storage.planRevision == session.revision && storage.plannedArguments == storage.planArguments }
    private var worker: WorkbenchJobWorker? { session.jobWorkers.first { $0.active && $0.targetKind == "tiled-analysis" && $0.targetID == storage.selectedAnalysisID } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("OME-Zarr sources and tiled analysis").font(.title2)
                WorkbenchSavedRecordAccess(session: session, catalogues: ["zarrSources", "tiledAnalyses"])
                Spacer()
                Button("Open local OME-Zarr…") { chooseSource(rebind: false) }.disabled(writesBlocked)
                Button("Refresh", action: session.loadStorage).disabled(session.busy)
                Button("Done") { dismiss() }.disabled(session.busy)
            }
            Text("Choose an NGFF image group, resolution level and exact T/C/Z plane. Extract a source-resolution region or process a larger region through durable tile checkpoints.")
                .font(.callout).foregroundStyle(.secondary)
            if let error = session.error { Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled) }
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    sourceSelection
                    if storage.array != .null { regionAndPlan }
                    savedAnalyses
                }.padding(.trailing, 6)
            }
            HStack {
                if session.busy { ProgressView().controlSize(.small) }
                Text(session.status).font(.caption).foregroundStyle(.secondary)
                Spacer()
            }
        }.padding(22).frame(minWidth: 900, idealWidth: 1100, minHeight: 680, idealHeight: 790)
        .interactiveDismissDisabled(session.busy)
        .task { session.loadStorage() }
    }

    private var sourceSelection: some View {
        WorkbenchZarrSourceSelection(session: session, storage: storage, onRelocate: { chooseSource(rebind: true) })
    }

    private var regionAndPlan: some View {
        VStack(alignment: .leading, spacing: 12) {
            if storage.overviewCurrent, let image = storage.overview {
                WorkbenchSourceRegionCanvas(image: image, sourceWidth: storage.dimension("x"), sourceHeight: storage.dimension("y"),
                    x: $storage.x, y: $storage.y, width: $storage.width, height: $storage.height,
                    validRegion: storage.validRegion, enabled: !session.busy)
                    .frame(height: 310).accessibilityLabel("Selected-level overview with exact source-region selection")
                Text("Drag a region or enter exact coordinates below. The overview is display sampling; all region coordinates use the \(storage.dimension("x")) × \(storage.dimension("y")) selected-level source grid.")
                    .font(.caption).foregroundStyle(.secondary)
            } else if storage.overview != nil {
                Text("Source selection changed. Read a new overview to use direct region selection.").font(.caption).foregroundStyle(.orange)
            }
            GroupBox("Region on the selected resolution level") {
                VStack(alignment: .leading, spacing: 10) {
                    regionFields(x: $storage.x, y: $storage.y, width: $storage.width, height: $storage.height)
                    HStack {
                        Button("Use whole selected plane") { storage.x = 0; storage.y = 0; storage.width = storage.dimension("x"); storage.height = storage.dimension("y") }
                        Text("\(Double(storage.width) * Double(storage.height), format: .number) source pixels").font(.caption)
                    }
                    Text("Ordinary extraction retains up to 16 million source pixels. Larger regions use a separate bounded tile plan.")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack {
                        TextField("Extracted image name (optional)", text: $storage.imageName).textFieldStyle(.roundedBorder)
                        Button("Extract exact region for analysis", action: session.extractZarrRegion)
                            .disabled(writesBlocked || !storage.validRegion || Double(storage.width) * Double(storage.height) > 16_000_000 || storage.source["available"].bool != true)
                    }
                    DisclosureGroup("Create tiled analysis") { tiledPlan.padding(.top, 10) }
                }.padding(6).disabled(session.busy)
            }
        }
    }

    private var tiledPlan: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Global threshold-connected components across tiles. Shared-edge objects are reconciled before minimum-area filtering. This processes one selected plane; it does not run tiled watershed or learned models.")
                .font(.caption).foregroundStyle(.secondary)
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                GridRow {
                    Text("Threshold method")
                    Picker("Threshold method", selection: $storage.method) { Text("Global Otsu").tag("otsu"); Text("Manual raw intensity").tag("manual") }.labelsHidden()
                }
                if storage.method == "manual" { GridRow { Text("Threshold (raw intensity)"); TextField("Raw threshold", value: $storage.threshold, format: .number).textFieldStyle(.roundedBorder) } }
                GridRow {
                    Text("Foreground")
                    Picker("Foreground", selection: $storage.polarity) { Text("Brighter than threshold").tag("bright"); Text("Darker than threshold").tag("dark") }.labelsHidden()
                }
                GridRow {
                    Text("Connectivity")
                    Picker("Connectivity", selection: $storage.connectivity) { Text("4 neighbours").tag(4); Text("8 neighbours, including diagonals").tag(8) }.labelsHidden()
                }
                GridRow { Text("Minimum global area (pixels)"); integerField("Minimum global area", value: $storage.minAreaPx) }
                GridRow { Text("Tile edge (pixels)"); integerField("Tile edge", value: $storage.tileSize) }
                GridRow { Text("Halo width (pixels)"); integerField("Halo width", value: $storage.halo) }
            }
            Button("Preview tile plan", action: session.previewTiledPlan).disabled(!storage.validRegion || session.hasActiveWorkers)
            if planCurrent {
                Text("\(storage.plan["tileCount"].integer ?? 0) tiles · \(storage.plan["checkpointCount"].integer ?? 0) checkpoints · estimated maximum working memory \(bytes(storage.plan["estimatedMaximumWorkingBytes"]))")
                    .font(.callout)
                Text("This preview plans work without segmenting. Each completed checkpoint and its source identity is retained; background execution can continue after the app closes.")
                    .font(.caption).foregroundStyle(.secondary)
                DisclosureGroup("Limits and scientific conventions") {
                    Text("Maximum 4,096 tiles, one billion region pixels, 512 MiB estimated working memory and 8 GiB retained artifacts per analysis. Tile edges use 64–1,024 pixels; halos use 1–64 pixels.").font(.caption)
                    ForEach(storage.plan["notes"].array.compactMap(\.string), id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary) }
                }
            } else if storage.plan != .null {
                Text("The plan no longer matches these settings and project revision. Preview again before creating it.").font(.caption).foregroundStyle(.orange)
            }
            HStack {
                TextField("Saved analysis name (optional)", text: $storage.analysisName).textFieldStyle(.roundedBorder)
                Button("Create tiled analysis", action: session.createTiledAnalysis).buttonStyle(.borderedProminent).disabled(writesBlocked || !planCurrent)
            }
        }
    }

    private var savedAnalyses: some View {
        GroupBox("Saved tiled analyses") {
            VStack(alignment: .leading, spacing: 12) {
                Picker("Analysis", selection: Binding(get: { storage.selectedAnalysisID }, set: storage.selectAnalysis)) {
                    Text("Create a tile plan first").tag("")
                    ForEach(storage.analyses, id: \.storageID) { Text("\($0["name"].string ?? "Analysis") · \($0["status"].string ?? "")").tag($0["id"].string ?? "") }
                }.disabled(session.busy)
                if storage.analysis != .null {
                    let analysis = storage.analysis
                    let status = analysis["status"].string ?? "pending"
                    Text("\(status.capitalized) · \(analysis["phase"].string ?? "") · \(analysis["progress"]["completed"].integer ?? 0) / \(analysis["progress"]["total"].integer ?? 0) checkpoints · \(bytes(analysis["retainedBytes"])) retained").font(.callout)
                    ProgressView(value: analysis["progress"]["completed"].number ?? 0, total: max(1, analysis["progress"]["total"].number ?? 1))
                    Text("Source \(analysis["sourceName"].string ?? "") · level \(analysis["selection"]["arrayPath"].string ?? "") · time \((analysis["selection"]["timeIndex"].integer ?? 0) + 1), channel \((analysis["selection"]["channel"].integer ?? 0) + 1), Z \((analysis["selection"]["zIndex"].integer ?? 0) + 1)").font(.caption)
                    if let error = analysis["error"]["message"].string { Text(error).font(.callout).foregroundStyle(.red) }
                    Text(analysis["sourceInputsCurrent"].bool == false ? "External source bytes changed. Restore the original source before resuming or exporting." : "External source currentness has not been rechecked. Presence and completed outputs do not prove current source identity.")
                        .font(.caption).foregroundStyle(analysis["sourceInputsCurrent"].bool == false ? Color.orange : Color.secondary)
                    Text(analysis["sourceVerifiedAt"].string.map { "Last complete source verification: \($0)" } ?? "The final source verification pass has not completed.")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack {
                        if ["pending", "running"].contains(status) {
                            Button("Run next checkpoint") { session.controlTiledAnalysis("advance") }.disabled(writesBlocked)
                            Button("Run in background") { session.controlTiledAnalysis("worker.start") }.disabled(writesBlocked)
                            Button("Pause") { session.controlTiledAnalysis("pause") }.disabled(writesBlocked)
                        }
                        if ["paused", "failed"].contains(status) { Button("Resume retained checkpoints") { session.controlTiledAnalysis("resume") }.disabled(writesBlocked) }
                        if !["completed", "cancelled"].contains(status) { Button("Cancel remaining work") { session.controlTiledAnalysis("cancel") }.disabled(writesBlocked) }
                    }
                    if let worker {
                        HStack {
                            Text("Background worker: \(worker.status)").font(.caption)
                            Button(worker.stopRequested ? "Stop requested" : "Stop after current checkpoint") { session.stopBackgroundJob(worker.id) }
                                .disabled(session.busy || worker.stopRequested)
                        }
                    } else if session.hasActiveWorkers {
                        Text("Another background operation owns this project. Stop it from its existing execution controls before changing this analysis.").font(.caption).foregroundStyle(.orange)
                    }
                    if let count = analysis["objectCount"].integer {
                        Text("\(count) globally reconciled objects\(status == "completed" ? "" : " · publication or verification may still be pending")").font(.callout)
                    }
                    DisclosureGroup("Object measurements and retained tiles") { retainedResults.padding(.top, 8) }
                    DisclosureGroup("Exact label region and export") { labelsAndExport.padding(.top, 8) }
                }
            }.padding(6)
        }
    }

    private var retainedResults: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Button("Read object measurements") { session.readTiledPage("objects") }.disabled(storage.analysis["objectCount"].integer == nil)
                Button("Read tile checkpoints") { session.readTiledPage("tiles") }
            }.disabled(session.busy)
            if storage.objectPage["analysisId"].string == storage.selectedAnalysisID {
                ScrollView(.horizontal) {
                    Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 6) {
                        GridRow { Text("Object"); Text("Area (pixels)"); Text("Area (µm²)"); Text("X (source px)"); Text("Y (source px)"); Text("Mean raw intensity") }.fontWeight(.semibold)
                        ForEach(storage.objectPage["objects"].array, id: \.storageID) { object in
                            GridRow { Text(number(object["id"])); Text(number(object["areaPx"])); Text(number(object["areaUm2"])); Text(number(object["centroidX"])); Text(number(object["centroidY"])); Text(number(object["meanIntensity"])) }
                        }
                    }.font(.caption).textSelection(.enabled)
                }
                paging(storage.objectPage, revision: storage.objectRevision, kind: "objects", size: 100)
            }
            if storage.tilePage["analysisId"].string == storage.selectedAnalysisID {
                Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 6) {
                    GridRow { Text("Tile"); Text("Source region (px)"); Text("Checkpoint"); Text("Local components") }.fontWeight(.semibold)
                    ForEach(storage.tilePage["tiles"].array, id: \.storageTileID) { tile in
                        GridRow {
                            Text("\((tile["index"].integer ?? 0) + 1)")
                            Text("\(number(tile["x"])), \(number(tile["y"])) · \(number(tile["width"])) × \(number(tile["height"]))")
                            Text(tile["status"].string ?? "pending"); Text(number(tile["componentCount"]))
                        }
                    }
                }.font(.caption).textSelection(.enabled)
                paging(storage.tilePage, revision: storage.tileRevision, kind: "tiles", size: 50)
            }
        }
    }

    private var labelsAndExport: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Read up to one million retained label pixels. Coordinates refer to the selected source level, not the overview.").font(.caption).foregroundStyle(.secondary)
            regionFields(x: $storage.labelX, y: $storage.labelY, width: $storage.labelWidth, height: $storage.labelHeight).disabled(session.busy)
            Button("Read retained label region", action: session.previewTiledLabels).disabled(session.busy || !storage.validLabelRegion)
            if let image = storage.labelPreview, storage.labelPreviewSelection == storage.labelArguments {
                Image(nsImage: image).resizable().interpolation(.none).scaledToFit().frame(maxWidth: .infinity, maxHeight: 330)
                    .accessibilityLabel("Display of exact retained tiled label region")
                Text("Retained labels read at revision \(storage.labelPreviewRevision ?? 0). The display is scaled.").font(.caption).foregroundStyle(.secondary)
            }
            Picker("Export format", selection: $storage.selectedFormat) {
                ForEach(storage.formats, id: \.storageID) { Text($0["name"].string ?? "Format").tag($0["id"].string ?? "") }
            }
            if let format = storage.formats.first(where: { $0["id"].string == storage.selectedFormat }) {
                Text(format["description"].string ?? "").font(.caption).foregroundStyle(.secondary)
            }
            Button("Export completed tiled results…", action: chooseExport)
                .disabled(writesBlocked || storage.analysis["status"].string != "completed")
            Text("Exports recheck external source identities, retain full-resolution labels or the complete global object table, and never replace an existing file.").font(.caption).foregroundStyle(.secondary)
            if let path = storage.lastExport["destination"].string {
                Button("Reveal exported file") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
            }
        }
    }
    private func paging(_ page: WorkbenchJSON, revision: Int?, kind: String, size: Int) -> some View {
        HStack {
            Text("\(page["offset"].integer ?? 0) offset · \(page["total"].integer ?? 0) total · read at revision \(revision ?? 0)\(revision == session.revision ? "" : " · refresh for current state")").font(.caption).foregroundStyle(.secondary)
            Spacer()
            Button("Previous") { session.readTiledPage(kind, offset: max(0, (page["offset"].integer ?? 0) - size)) }.disabled(session.busy || page["offset"].integer == 0)
            Button("Next") { if let offset = page["nextOffset"].integer { session.readTiledPage(kind, offset: offset) } }.disabled(session.busy || page["nextOffset"].integer == nil)
        }
    }
    private func regionFields(x: Binding<Int>, y: Binding<Int>, width: Binding<Int>, height: Binding<Int>) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
            GridRow { Text("Left X (zero-based)"); integerField("Left X", value: x); Text("Top Y (zero-based)"); integerField("Top Y", value: y) }
            GridRow { Text("Width (source pixels)"); integerField("Width", value: width); Text("Height (source pixels)"); integerField("Height", value: height) }
        }
    }
    private func integerField(_ label: String, value: Binding<Int>) -> some View {
        TextField(label, value: value, format: .number).textFieldStyle(.roundedBorder).frame(maxWidth: 160).accessibilityLabel(label)
    }
    private func selector(_ label: String, value: Binding<Int>, count: Int) -> some View {
        Stepper("\(label) \(value.wrappedValue + 1) of \(count)", value: value, in: 0...max(0, count - 1))
    }
    private func number(_ value: WorkbenchJSON) -> String { value.number.map { $0.formatted(.number.precision(.fractionLength(0...4))) } ?? "Unknown" }
    private func bytes(_ value: WorkbenchJSON) -> String { value.integer.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .memory) } ?? "Unknown" }
    private func chooseSource(rebind: Bool) {
        let panel = NSOpenPanel(); panel.title = rebind ? "Relocate the identical OME-Zarr source" : "Choose one local OME-Zarr image group"
        panel.message = "Choose the image-group directory. Plate or collection roots are not silently reduced to their first image."
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        panel.begin { response in if response == .OK, let url = panel.url { session.importZarrSource(url, rebind: rebind) } }
    }
    private func chooseExport() {
        guard let format = storage.formats.first(where: { $0["id"].string == storage.selectedFormat }) else { return }
        let panel = NSSavePanel(); panel.title = "Export completed tiled results to a new file"
        panel.nameFieldStringValue = "Tiled results." + (format["extension"].string ?? "zip")
        if let ext = format["extension"].string, let type = UTType(filenameExtension: ext) { panel.allowedContentTypes = [type] }
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            guard !FileManager.default.fileExists(atPath: url.path) else { session.error = "Choose a new filename. Existing exports remain unchanged."; return }
            session.exportTiledAnalysis(to: url)
        }
    }
}

private extension WorkbenchJSON {
    var storageID: String { self["id"].string ?? self["id"].integer.map(String.init) ?? "" }
    var storagePath: String { self["path"].string ?? "" }
    var storageTileID: Int { self["index"].integer ?? 0 }
}
