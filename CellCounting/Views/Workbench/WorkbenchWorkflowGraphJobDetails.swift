import AppKit
import SwiftUI

struct WorkbenchWorkflowGraphJobDetails: View {
    @Bindable var session: WorkbenchSession
    @Bindable var graphState: WorkbenchWorkflowGraphState
    let job: WorkbenchJob
    @Environment(\.dismiss) private var dismiss
    @State private var checkpointPage = 0
    @State private var summaryBranch = ""
    @State private var summaryPage = 0
    private let pageSize = 10
    private var detail: WorkbenchJSON? { graphState.jobDetails[job.id] }
    private var detailCurrent: Bool { detail != nil && graphState.jobRevisions[job.id] == session.revision }
    private var checkpoints: [WorkbenchJSON] { detail?["checkpoints"].array ?? [] }
    private var graph: WorkbenchJSON { detail?["workflow"]["graph"] ?? job.graph }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let nodeID = job.nextNodeID {
                Text("Next node: \(label(nodeID))").font(.caption.weight(.semibold))
                if let source = job.nextImageID {
                    Text("Source: \(imageName(source))\(job.nextTimeIndex.map { " · Time \($0 + 1)" } ?? "")")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if let failedNode = job.errorUnit["nodeId"].string ?? job.errorDetails["nodeId"].string {
                Text("Stopped at: \(label(failedNode))\(job.errorUnit["imageId"].string.map { " · \(imageName($0))" } ?? "")\(job.errorUnit["timeIndex"].integer.map { " · Time \($0 + 1)" } ?? "")")
                    .font(.caption).foregroundStyle(.orange)
            }
            if !job.staleNodeIDs.isEmpty {
                Text("Changed branches: \(Array(Set(job.staleNodeIDs)).sorted().map(label).joined(separator: ", "))")
                    .font(.caption).foregroundStyle(.orange)
            }
            if job.continuation != .null {
                Text("Independent continuation from a retained job. Corrected masks were copied; reused ancestors and new downstream results are recorded separately.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if job.pendingReview != .null {
                reviewControls(job.pendingReview)
            } else if job.status == "awaiting-review" {
                Text("Execution is waiting for an explicit mask review. Refresh branch details to load its exact input.")
                    .font(.caption).foregroundStyle(.orange)
            }
            if let selectedKey = graphState.selectedReviewKeys[job.id], let selected = graphState.reviewRecords[selectedKey],
               selected["nodeId"] != job.pendingReview["nodeId"] || selected["checkpointIndex"] != job.pendingReview["checkpointIndex"] {
                DisclosureGroup("Selected review history") { reviewControls(selected) }
            }
            DisclosureGroup("Branch progress") {
                ForEach(Array(job.nodeProgress.enumerated()), id: \.offset) { _, progress in
                    HStack {
                        Text(label(progress["nodeId"].string ?? ""))
                        Spacer()
                        Text("\(progress["completed"].integer ?? 0) of \(progress["total"].integer ?? 0)").monospacedDigit()
                    }.font(.caption)
                }
                Text("Nodes execute one checkpoint at a time. Pause or retry retains completed outputs; no branch runs independently behind these controls.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            DisclosureGroup("Source relationships, node previews and results") {
                VStack(alignment: .leading, spacing: 10) {
                    Button(detail == nil ? "Load branch details" : "Refresh branch details") {
                        session.loadWorkflowGraphJob(job.id)
                    }.disabled(session.busy)
                    if let revision = graphState.jobRevisions[job.id] {
                        Text("Saved detail snapshot at project revision \(revision).\(detailCurrent ? "" : " Refresh details after job or project changes.")")
                            .font(.caption).foregroundStyle(detailCurrent ? Color.secondary : Color.orange)
                    }
                    if detail != nil {
                        WorkbenchWorkflowGraphRelationships(graph: graph)
                        checkpointDetails
                        DisclosureGroup("Continue from corrected masks") {
                            if let draft = graphState.continuationDrafts[job.id] {
                                WorkbenchGraphContinuationControls(session: session, draft: draft, job: job, graph: graph,
                                    checkpoints: checkpoints, detailCurrent: detailCurrent)
                            }
                        }.onAppear { session.prepareGraphContinuation(jobID: job.id) }
                        if detail?["summary"] != .null, let summary = detail?["summary"] {
                            summaryDetails(summary)
                        }
                    }
                }
            }
            if graphState.nodePreviewJobID == job.id {
                if let error = graphState.nodePreviewError {
                    Text("\(label(graphState.nodePreviewNodeID)) · Source selection \(graphState.nodePreviewCheckpointIndex + 1): \(error)")
                        .font(.caption).foregroundStyle(.orange)
                }
                if let preview = graphState.nodePreview {
                    if graphState.nodePreviewRevision == session.revision {
                        WorkbenchWorkflowGraphNodePreview(result: preview, generation: graphState.nodePreviewGeneration,
                            nodeName: label(preview["nodeId"].string ?? ""),
                            sourceName: imageName(preview["sourceImageId"].string ?? ""))
                    } else {
                        Text("The project changed after this node preview. Refresh branch details and request the preview again.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var checkpointDetails: some View {
        VStack(alignment: .leading, spacing: 9) {
            pagination(page: $checkpointPage, total: checkpoints.count, label: "Source selections")
            ForEach(Array(checkpoints.enumerated()).dropFirst(checkpointPage * pageSize).prefix(pageSize), id: \.offset) { index, checkpoint in
                DisclosureGroup {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(checkpoint["nodes"].array.enumerated()), id: \.offset) { _, node in
                            checkpointNode(node, checkpoint: checkpoint, index: index)
                        }
                    }.padding(.top, 5)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(imageName(checkpoint["imageId"].string ?? "")).font(.caption.weight(.semibold))
                        Text("\(workbenchGraphSelectionLabel(checkpoint["sourceSelection"])) · \(checkpoint["status"].string ?? "pending")")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func checkpointNode(_ node: WorkbenchJSON, checkpoint: WorkbenchJSON, index: Int) -> some View {
        let id = node["nodeId"].string ?? ""
        let definition = graph["nodes"].array.first { $0["id"].string == id } ?? .null
        let kind = definition["type"].string ?? ""
        let inputID = definition["input"].string ?? ""
        let inputIDs = (inputID.isEmpty ? [] : [inputID]) + definition["inputs"].array.compactMap(\.string)
            + (definition["nuclearInput"].string.map { [$0] } ?? [])
        let upstreamReady = !inputIDs.isEmpty && inputIDs.allSatisfy { parent in
            parent == "$source" || checkpoint["nodes"].array.contains { $0["nodeId"].string == parent && $0["status"].string == "completed" }
        }
        let previewSupported = graphState.nodeTypes.first { $0.id == kind }?.previewSupported == true
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label(id)).font(.caption.weight(.semibold))
                Spacer()
                Text((node["status"].string ?? "pending").replacingOccurrences(of: "-", with: " ").capitalized).font(.caption)
            }
            Text("From: \(inputIDs.map(label).joined(separator: ", "))").font(.caption).foregroundStyle(.secondary)
            if let nuclear = definition["nuclearInput"].string {
                Text("Nuclear mask: \(label(nuclear))").font(.caption).foregroundStyle(.secondary)
            }
            if node["correctionOrigin"] != .null {
                Text("Exact corrected mask copied into this continuation.").font(.caption).foregroundStyle(.secondary)
            } else if node["reusedFrom"] != .null {
                Text("Current completed output reused from the preceding job.").font(.caption).foregroundStyle(.secondary)
            }
            if let input = node["inputBinding"]["imageId"].string {
                Text("Input: \(imageName(input)) · \(workbenchGraphSelectionLabel(node["inputBinding"]["selection"]))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let output = node["outputBinding"]["imageId"].string {
                Text("Output: \(imageName(output)) · \(workbenchGraphSelectionLabel(node["outputBinding"]["selection"]))")
                    .font(.caption)
                if node["outputBinding"]["analyzed"].bool == true {
                    Button("Open branch output in image viewer") {
                        session.openWorkflowGraphOutput(jobID: job.id, checkpointIndex: index, nodeID: id) { dismiss() }
                    }.disabled(session.busy || session.hasActiveWorkers || !detailCurrent || !job.outputsCurrent || !session.canRefreshWithoutDiscardingEdits)
                }
                DisclosureGroup("Retained output binding") {
                    Text("Image identity: \(output)").font(.caption.monospaced()).textSelection(.enabled)
                    if let revision = node["completedRevision"].integer { Text("Completed at revision \(revision)").font(.caption) }
                    if let hash = node["outputBinding"]["labelsHash"].string {
                        Text("Labels SHA-256: \(hash)").font(.caption.monospaced()).textSelection(.enabled)
                    }
                    if !node["stepResults"].array.isEmpty {
                        WorkbenchStructuredOutput(value: .object(["results": node["stepResults"]])).frame(height: 180)
                    }
                }
            }
            if kind == "review", node["review"] != .null || node["status"].string == "awaiting-review" || node["status"].string == "completed" {
                Button("Read review binding and decisions") {
                    session.readGraphReview(jobID: job.id, checkpointIndex: index, nodeID: id)
                }.disabled(session.busy)
            }
            if previewSupported {
                Button(kind == "measurements" ? "Read retained measurements" : "Calculate node preview") {
                    session.previewWorkflowGraphNode(jobID: job.id, checkpointIndex: index, nodeID: id)
                }.disabled(session.busy || !detailCurrent || !job.outputsCurrent || !upstreamReady)
                if !upstreamReady {
                    Text("Run the upstream checkpoint first so this node has an exact retained input.").font(.caption).foregroundStyle(.secondary)
                }
            } else if ["plugin-segmentation", "plugin-measurement", "model-segmentation"].contains(kind) {
                Text("This executable method runs only through an explicit job checkpoint; it has no read-only calculation preview.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.padding(8).background(.quaternary.opacity(0.3)).clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func reviewControls(_ review: WorkbenchJSON) -> some View {
        WorkbenchGraphReviewControls(session: session, state: graphState, job: job, graph: graph, review: review) {
            let reviewID = review["nodeId"].string ?? ""
            guard let inputID = graph["nodes"].array.first(where: { $0["id"].string == reviewID })?["input"].string,
                  let index = review["checkpointIndex"].integer else { return }
            session.openWorkflowGraphOutput(jobID: job.id, checkpointIndex: index, nodeID: inputID) { dismiss() }
        }
    }

    private func summaryDetails(_ summary: WorkbenchJSON) -> some View {
        let branches = summary["branches"].array
        let selected = branches.first { $0["nodeId"].string == summaryBranch } ?? branches.first ?? .null
        let records = selected["records"].array
        return DisclosureGroup("Separate branch summaries") {
            VStack(alignment: .leading, spacing: 8) {
                Text("Each row is a source acquisition/time within one technical branch. Branch alternatives and time points are not biological replicates.")
                    .font(.caption).foregroundStyle(.secondary)
                Picker("Summary branch", selection: Binding(get: { selected["nodeId"].string ?? "" }, set: {
                    summaryBranch = $0; summaryPage = 0
                })) {
                    ForEach(Array(branches.enumerated()), id: \.offset) { _, branch in
                        Text(label(branch["nodeId"].string ?? "")).tag(branch["nodeId"].string ?? "")
                    }
                }
                pagination(page: $summaryPage, total: records.count, label: "Branch records")
                ForEach(Array(records.enumerated()).dropFirst(summaryPage * pageSize).prefix(pageSize), id: \.offset) { _, record in
                    DisclosureGroup {
                        WorkbenchStructuredOutput(value: record["summary"]).frame(height: 220)
                        if !record["stepResults"].array.isEmpty {
                            WorkbenchStructuredOutput(value: .object(["methodResults": record["stepResults"]])).frame(height: 180)
                        }
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(label(selected["nodeId"].string ?? "")) · \(imageName(record["sourceImageId"].string ?? ""))").font(.caption.weight(.semibold))
                            Text("\(workbenchGraphSelectionLabel(record["sourceSelection"])) → \(imageName(record["imageId"].string ?? ""))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    private func pagination(page: Binding<Int>, total: Int, label: String) -> some View {
        HStack {
            Text("\(label): \(total)").font(.caption)
            Spacer()
            Button("Previous") { page.wrappedValue = max(0, page.wrappedValue - 1) }.disabled(page.wrappedValue == 0)
            Button("Next") { page.wrappedValue += 1 }.disabled((page.wrappedValue + 1) * pageSize >= total)
        }
    }
    private func imageName(_ id: String) -> String { session.images.first { $0.id == id }?.name ?? "Retained acquisition" }
    private func label(_ id: String) -> String { workbenchGraphNodeLabel(graph, id: id) }
}

private struct WorkbenchWorkflowGraphNodePreview: View {
    let result: WorkbenchJSON
    let generation: Int
    let nodeName: String
    let sourceName: String
    @State private var crosshair = [0, 0, 0]
    @State private var viewerStatus = ""
    private var preview: WorkbenchJSON { result["preview"] }
    private var image: NSImage? {
        guard let encoded = preview["overlayDataUrl"].string ?? preview["dataUrl"].string,
              let marker = encoded.range(of: ";base64,"),
              let data = Data(base64Encoded: String(encoded[marker.upperBound...])) else { return nil }
        return NSImage(data: data)
    }
    private var measurements: WorkbenchJSON {
        if preview["output"] != .null { return preview["output"] }
        var fields = preview.object
        for key in ["dataUrl", "overlayDataUrl", "display"] { fields.removeValue(forKey: key) }
        if let cells = fields["cells"] {
            fields["cellCount"] = fields["cellCount"] ?? .number(Double(cells.array.count))
            fields["cells"] = .array(cells.array.prefix(100).map { cell in
                var columns = cell.object
                columns.removeValue(forKey: "contourPx"); columns.removeValue(forKey: "contoursPx")
                return .object(columns)
            })
            if cells.array.count > 100 { fields["displayNote"] = .string("Showing the first 100 of \(cells.array.count) objects in this preview table.") }
        }
        return .object(fields)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(nodeName) · \(sourceName)").font(.callout.weight(.semibold))
            Text(workbenchGraphSelectionLabel(result["sourceSelection"])).font(.caption).foregroundStyle(.secondary)
            Text(result["mode"].string == "retained-measurements"
                 ? "Read-only measurements of the retained input masks."
                 : "Fresh calculation from this node's retained input. This does not replace an output or complete a checkpoint.")
                .font(.caption).foregroundStyle(.secondary)
            if preview["display"] != .null {
                WorkbenchVolumeWebView(descriptor: preview["display"], descriptorIdentity: "graph-preview:\(generation)",
                    generation: generation, crosshair: crosshair,
                    onPointer: { voxel, _, observedGeneration in
                        if observedGeneration == generation { crosshair = voxel.map { max(0, Int($0.rounded())) } }
                    }, onStatus: { viewerStatus = $0 })
                    .frame(minHeight: 270)
                Text("Sampled display for inspection; scientific measurements use full-resolution voxels.")
                    .font(.caption).foregroundStyle(.secondary)
                if !viewerStatus.isEmpty { Text(viewerStatus).font(.caption).foregroundStyle(.secondary) }
            } else if let image {
                Image(nsImage: image).resizable().scaledToFit().frame(maxHeight: 280)
                    .accessibilityLabel("Read-only preview of \(nodeName) for \(sourceName)")
            }
            DisclosureGroup("Preview measurements and method details") {
                WorkbenchStructuredOutput(value: measurements).frame(height: 260)
            }
        }.padding(10).background(.quaternary.opacity(0.4)).clipShape(RoundedRectangle(cornerRadius: 8))
    }
}
