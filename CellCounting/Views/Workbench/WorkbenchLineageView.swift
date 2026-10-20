import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct WorkbenchLineageView: View {
    @Bindable var session: WorkbenchSession
    @Bindable var lineage: WorkbenchLineageState
    @Environment(\.dismiss) private var dismiss
    private var hasReason: Bool { !lineage.reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private var validTimes: Bool {
        lineage.parentTime >= 1 && lineage.daughterTime > lineage.parentTime &&
            lineage.daughterTime <= session.volume.timeCount
    }
    private var canCorrect: Bool { lineage.status == "current" && hasReason && !session.busy }
    private var canExport: Bool {
        lineage.status == "current" && !lineage.hasUnsavedCorrection &&
            session.canRefreshWithoutDiscardingEdits && !session.hasActiveWorkers
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Lineages and divisions").font(.title2)
                Spacer()
                Button("Refresh", action: session.loadLineage).disabled(session.temporal.hasPendingDraft)
                Button("Done") { dismiss() }
            }.disabled(session.busy)
            Text("\(session.selectedImage?.name ?? "Image") · Channel \(session.volume.channel + 1)")
                .font(.caption).foregroundStyle(.secondary)
            if let error = session.error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            if lineage.status == "stale" {
                Text("Source labels, calibration or base tracks changed. The saved graph is historical; preview new temporal inference or initialize from current tracks before adding corrections.")
                    .font(.callout).foregroundStyle(.orange)
            }
            HSplitView {
                ScrollView {
                    VStack(alignment: .leading, spacing: 11) {
                        Text("Graph status: \(lineage.status)").font(.headline)
                        WorkbenchTemporalControls(session: session, temporal: session.temporal)
                        Divider()
                        TextField("Reason for graph changes", text: $lineage.reason, axis: .vertical)
                            .textFieldStyle(.roundedBorder).lineLimit(2...4)
                        Button("Initialize from current tracks", action: session.initializeLineage)
                        Text("Lineage branches are stored separately from the one-to-one tracking graph. Initialization creates a new graph snapshot.")
                            .font(.caption).foregroundStyle(.secondary)
                        Button("Undo graph change", action: session.undoLineage)
                            .disabled(!canCorrect || lineage.graph?["undoAvailable"].bool != true)
                        if lineage.hasUnsavedCorrection {
                            Text("Pending correction fields have not been applied to the graph.").font(.caption).foregroundStyle(.orange)
                            Button("Clear pending correction", action: lineage.discardCorrectionDraft)
                        }
                        DisclosureGroup("Export saved lineage") {
                            VStack(alignment: .leading, spacing: 7) {
                                Picker("Format", selection: $lineage.exportFormatID) {
                                    ForEach(lineage.exportFormats) { Text($0.name).tag($0.id) }
                                }
                                if let format = lineage.exportFormats.first(where: { $0.id == lineage.exportFormatID }) {
                                    Text(format.description).font(.caption).foregroundStyle(.secondary)
                                }
                                Button("Choose destination…", action: chooseExport).disabled(!canExport)
                                if !canExport {
                                    Text("Export requires a current saved graph and no pending mask or graph edits.")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                if let path = lineage.exportResult?["destination"].string {
                                    Button("Show last export in Finder") {
                                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                                    }
                                }
                            }.padding(.top, 6)
                        }
                        Divider()
                        Text("Reviewed division").font(.headline)
                        integer("Parent time (1-based)", value: $lineage.parentTime)
                        integer("Parent object", value: $lineage.parentLabel)
                        integer("Daughter time (1-based)", value: $lineage.daughterTime)
                        integer("First daughter object", value: $lineage.daughterOne)
                        integer("Second daughter object", value: $lineage.daughterTwo)
                        Toggle("Replace existing conflicting links", isOn: $lineage.replaceExisting)
                            .font(.caption)
                        Button("Save division", action: session.saveLineageDivision)
                            .buttonStyle(.borderedProminent)
                            .disabled(!canCorrect || !validTimes || lineage.parentLabel < 1 ||
                                lineage.daughterOne < 1 || lineage.daughterTwo < 1 || lineage.daughterOne == lineage.daughterTwo)
                        DisclosureGroup("Correct continuation link") {
                            integer("Target object at daughter time", value: $lineage.targetLabel)
                            HStack {
                                Button("Link") { session.correctLineageLink(link: true) }
                                Button("Unlink") { session.correctLineageLink(link: false) }
                            }.disabled(!canCorrect || !validTimes || lineage.parentLabel < 1 || lineage.targetLabel < 1)
                        }
                        DisclosureGroup("Suggest divisions from geometry") {
                            VStack(alignment: .leading, spacing: 8) {
                                number("Maximum parent-to-daughter distance", value: $lineage.maximumDistance)
                                Picker("Units", selection: $lineage.distanceUnits) {
                                    Text("Voxels").tag("voxel")
                                    if session.volume.calibrated { Text("Micrometres").tag("um") }
                                }
                                number("Minimum combined volume / parent", value: $lineage.minimumRatio)
                                number("Maximum combined volume / parent", value: $lineage.maximumRatio)
                                Button("Find candidates", action: session.suggestLineageDivisions)
                                    .disabled(!validTimes || !lineage.maximumDistance.isFinite || lineage.maximumDistance <= 0 ||
                                        !lineage.minimumRatio.isFinite || !lineage.maximumRatio.isFinite ||
                                        lineage.minimumRatio <= 0 || lineage.maximumRatio < lineage.minimumRatio)
                                Text("Candidates use distance and combined volume. They are not division probabilities; a reviewed decision and reason are required to save.")
                                    .font(.caption).foregroundStyle(.secondary)
                                if let suggestions = lineage.suggestions {
                                    if suggestions["truncated"].bool == true {
                                        Text("Candidate search reached its bounded search limit.").font(.caption).foregroundStyle(.orange)
                                    }
                                    ForEach(Array(suggestions["candidates"].array.enumerated()), id: \.offset) { _, candidate in
                                        Button {
                                            session.useLineageCandidate(candidate)
                                        } label: {
                                            VStack(alignment: .leading, spacing: 3) {
                                                Text("#\(candidate["parent"]["labelId"].integer ?? 0) → " +
                                                    candidate["daughters"].array.map { "#\($0["labelId"].integer ?? 0)" }.joined(separator: " + "))
                                                Text("Combined volume ratio \(candidate["combinedVolumeRatio"].number ?? 0, specifier: "%.3f")")
                                                    .font(.caption).foregroundStyle(.secondary)
                                            }
                                        }.buttonStyle(.bordered)
                                    }
                                }
                            }.padding(.top, 8)
                        }
                    }.padding(.trailing, 12)
                }.frame(minWidth: 300, idealWidth: 330, maxWidth: 380).disabled(session.busy)
                VStack(alignment: .leading, spacing: 10) {
                    if let graph = lineage.graph, lineage.status != "none" {
                        HStack {
                            Picker("Lineage", selection: $lineage.selectedLineageID) {
                                Text("All lineages").tag("")
                                ForEach(Array(graph["lineages"].array.enumerated()), id: \.offset) { index, item in
                                    Text("Lineage \(index + 1) · \(item["divisionCount"].integer ?? 0) divisions")
                                        .tag(item["id"].string ?? "")
                                }
                            }
                            Text("Graph revision \(graph["graphRevision"].integer ?? 0)").font(.caption)
                        }
                        WorkbenchLineageTimeline(graph: graph, lineageID: lineage.selectedLineageID,
                                                 selectedNodeID: $lineage.selectedNodeID)
                            .frame(minHeight: 230, idealHeight: 300)
                        if let node = lineage.selectedNode {
                            HStack {
                                Text("Time \((node["timeIndex"].integer ?? 0) + 1) · Object \(node["labelId"].integer ?? 0)")
                                    .font(.callout.bold())
                                Spacer()
                                Menu("Use observation") {
                                    Button("Parent") {
                                        lineage.parentTime = (node["timeIndex"].integer ?? 0) + 1
                                        lineage.parentLabel = node["labelId"].integer ?? 1
                                    }
                                    Button("First daughter") {
                                        lineage.daughterTime = (node["timeIndex"].integer ?? 0) + 1
                                        lineage.daughterOne = node["labelId"].integer ?? 1
                                    }
                                    Button("Second daughter") {
                                        lineage.daughterTime = (node["timeIndex"].integer ?? 0) + 1
                                        lineage.daughterTwo = node["labelId"].integer ?? 1
                                    }
                                    Button("Continuation target") {
                                        lineage.daughterTime = (node["timeIndex"].integer ?? 0) + 1
                                        lineage.targetLabel = node["labelId"].integer ?? 1
                                    }
                                }
                                Button("Inspect in volume") { session.inspectLineageObservation(); dismiss() }
                                    .disabled(lineage.status == "stale")
                            }.disabled(session.busy)
                        }
                        TabView {
                            WorkbenchStructuredOutput(value: graph["summary"]).tabItem { Text("Summary") }
                            ScrollView {
                                VStack(alignment: .leading, spacing: 8) {
                                    ForEach(Array(graph["divisions"].array.enumerated()), id: \.offset) { _, division in
                                        HStack(alignment: .top) {
                                            VStack(alignment: .leading, spacing: 3) {
                                                Text("T\((division["parent"]["timeIndex"].integer ?? 0) + 1) #\(division["parent"]["labelId"].integer ?? 0) → " +
                                                    division["daughters"].array.map { "T\(($0["timeIndex"].integer ?? 0) + 1) #\($0["labelId"].integer ?? 0)" }.joined(separator: " + "))
                                                Text(division["reason"].string ?? "").font(.caption).foregroundStyle(.secondary)
                                                if division["origin"].string == "inferred" {
                                                    Text("Inferred · unconfirmed").font(.caption).foregroundStyle(.orange)
                                                }
                                            }
                                            Spacer()
                                            if let id = division["id"].string {
                                                Button("Remove") { session.removeLineageDivision(id) }.disabled(!canCorrect)
                                            }
                                        }
                                    }
                                }.padding(8)
                            }.tabItem { Text("Divisions") }
                            WorkbenchStructuredOutput(value: .object(["tracks": graph["tracks"]])).tabItem { Text("Track measurements") }
                            WorkbenchStructuredOutput(value: .object(["history": graph["history"]])).tabItem { Text("History") }
                        }.frame(minHeight: 150, idealHeight: 190)
                    } else {
                        ContentUnavailableView("No lineage graph", systemImage: "point.3.connected.trianglepath.dotted",
                            description: Text("Analyze and track the time series, then initialize a lineage graph."))
                    }
                }.padding(.leading, 12).frame(minWidth: 650)
            }
            HStack {
                if session.busy { ProgressView().controlSize(.small) }
                Text(session.status).font(.caption).foregroundStyle(.secondary)
                Spacer()
            }
        }.padding(24).frame(width: 1150, height: 790)
        .task {
            lineage.editorOpen = true
            session.prepareTemporalControls()
            if !session.temporal.hasPendingDraft { session.loadLineage() }
        }
        .onDisappear { lineage.editorOpen = false }
    }

    private func chooseExport() {
        guard canExport, let format = lineage.exportFormats.first(where: { $0.id == lineage.exportFormatID }) else { return }
        let panel = NSSavePanel()
        panel.title = "Export \(format.name)"
        panel.message = "Choose a new file. Existing files will be preserved."
        panel.canCreateDirectories = true; panel.isExtensionHidden = false
        if let type = UTType(filenameExtension: format.fileExtension) { panel.allowedContentTypes = [type] }
        let stem = (session.selectedImage?.name ?? "Lineage")
            .replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        panel.nameFieldStringValue = "\(stem)-lineage-\(format.id).\(format.fileExtension)"
        panel.begin { response in
            guard response == .OK, let destination = panel.url else { return }
            session.exportLineage(to: destination)
        }
    }

    private func integer(_ title: String, value: Binding<Int>) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption)
            TextField(title, value: value, format: .number).textFieldStyle(.roundedBorder)
        }
    }
    private func number(_ title: String, value: Binding<Double>) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption)
            TextField(title, value: value, format: .number).textFieldStyle(.roundedBorder)
        }
    }
}

struct WorkbenchLineageTimeline: View {
    let graph: WorkbenchJSON
    let lineageID: String
    @Binding var selectedNodeID: String
    private struct Mark {
        let id: String
        let point: CGPoint
        let label: String
    }
    var body: some View {
        let allTracks = graph["tracks"].array.filter { lineageID.isEmpty || $0["lineageId"].string == lineageID }
        let tracks = Array(allTracks.prefix(200))
        let allTimes = tracks.flatMap { $0["observations"].array.compactMap { $0["timeIndex"].integer } }
        let firstTime = allTimes.min() ?? 0
        let lastTime = allTimes.max() ?? firstTime
        let canvasWidth = max(650.0, min(16_000.0, Double(lastTime - firstTime + 1) * 42 + 80))
        let timeScale = (canvasWidth - 100) / Double(max(1, lastTime - firstTime))
        let marks: [Mark] = Array(tracks.enumerated().flatMap { row, track in
            track["observations"].array.compactMap { node -> Mark? in
                guard let id = node["id"].string, let time = node["timeIndex"].integer else { return nil }
                return Mark(id: id, point: CGPoint(x: 60 + Double(time - firstTime) * timeScale,
                                                  y: 45 + Double(row) * 28),
                            label: "#\(node["labelId"].integer ?? 0)")
            }
        }.prefix(2000))
        let positions = Dictionary(marks.map { ($0.id, $0.point) }, uniquingKeysWith: { first, _ in first })
        VStack(alignment: .leading, spacing: 5) {
            ScrollView([.horizontal, .vertical]) {
                Canvas { context, _ in
                    let ticks = max(1, min(20, lastTime - firstTime + 1))
                    for tick in 0..<ticks {
                        let time = firstTime + Int(Double(tick) * Double(lastTime - firstTime) / Double(max(1, ticks - 1)))
                        let point = CGPoint(x: 60 + Double(time - firstTime) * timeScale, y: 15)
                        context.draw(Text("T\(time + 1)").font(.caption).foregroundStyle(.secondary), at: point)
                    }
                    for edge in graph["edges"].array {
                        guard let from = positions[edge["sourceNodeId"].string ?? ""],
                              let to = positions[edge["targetNodeId"].string ?? ""] else { continue }
                        var path = Path()
                        path.move(to: from); path.addLine(to: to)
                        context.stroke(path, with: .color(edge["kind"].string == "division" ? Color.orange : Color.secondary.opacity(0.65)),
                                       lineWidth: edge["kind"].string == "division" ? 2 : 1)
                    }
                    for mark in marks {
                        let selected = mark.id == selectedNodeID
                        let circle = Path(ellipseIn: CGRect(x: mark.point.x - 5, y: mark.point.y - 5, width: 10, height: 10))
                        context.fill(circle, with: .color(selected ? .orange : .accentColor))
                        if selected { context.draw(Text(mark.label).font(.caption.bold()), at: CGPoint(x: mark.point.x, y: mark.point.y + 11)) }
                    }
                }.frame(width: canvasWidth, height: max(150, Double(tracks.count) * 28 + 60))
                    .contentShape(Rectangle())
                    .onTapGesture { point in
                        if let nearest = marks.min(by: {
                            hypot($0.point.x - point.x, $0.point.y - point.y) < hypot($1.point.x - point.x, $1.point.y - point.y)
                        }), hypot(nearest.point.x - point.x, nearest.point.y - point.y) <= 14 {
                            selectedNodeID = nearest.id
                        }
                    }
                    .accessibilityLabel("Lineage timeline. Columns show time; rows show track segments. Orange edges are reviewed divisions.")
            }.background(.quaternary.opacity(0.25))
            Text("Time → · Each row is a track segment · Orange edges: divisions" +
                (allTracks.count > 200 || allTimes.count > 2000 ? " · Display limited to 200 tracks and 2,000 observations; select a lineage to narrow." : ""))
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
