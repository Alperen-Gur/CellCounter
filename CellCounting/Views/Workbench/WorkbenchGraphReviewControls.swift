import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct WorkbenchGraphReviewControls: View {
    @Bindable var session: WorkbenchSession
    @Bindable var state: WorkbenchWorkflowGraphState
    let job: WorkbenchJob
    let graph: WorkbenchJSON
    let review: WorkbenchJSON
    let openInput: () -> Void
    @State private var recommendation = "revise"
    private var nodeID: String { review["nodeId"].string ?? "" }
    private var checkpointIndex: Int { review["checkpointIndex"].integer ?? 0 }
    private var key: String { "\(job.id):\(checkpointIndex):\(nodeID)" }
    private var reason: Binding<String> {
        Binding(get: { state.reviewReasons[key] ?? "" }, set: { state.reviewReasons[key] = $0 })
    }
    private var current: Bool { review["inputsCurrent"].bool == true }
    private var canWrite: Bool {
        current && !session.busy && !session.hasActiveWorkers && session.canRefreshWithoutDiscardingEdits
            && !(state.reviewReasons[key] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (state.reviewReasons[key] ?? "").count <= 2000
    }
    private var actions: [String] { review["nextActions"].array.compactMap(\.string) }

    var body: some View {
        GroupBox("Review: \(workbenchGraphNodeLabel(graph, id: nodeID))") {
            VStack(alignment: .leading, spacing: 9) {
                Text(review["prompt"].string ?? "Inspect the retained mask before continuing this branch.")
                    .font(.callout)
                Text("\(imageName(review["inputBinding"]["imageId"].string)) · \(workbenchGraphSelectionLabel(review["inputBinding"]["selection"]))")
                    .font(.caption).foregroundStyle(.secondary)
                Text(review["requireHuman"].bool != false
                     ? "Human review required. Agent recommendations are retained but cannot complete this gate."
                     : "This gate accepts an explicit human or permitted agent decision.")
                    .font(.caption).foregroundStyle(.secondary)
                if !current {
                    Text("This review input changed. Refresh the binding; if the mask was corrected, create an independent continuation below.")
                        .font(.caption).foregroundStyle(.orange)
                }
                HStack {
                    Button("Refresh review binding") {
                        session.readGraphReview(jobID: job.id, checkpointIndex: checkpointIndex, nodeID: nodeID)
                    }.disabled(session.busy)
                    Button("Open input mask", action: openInput)
                        .disabled(session.busy || session.hasActiveWorkers || !current || !job.outputsCurrent || !session.canRefreshWithoutDiscardingEdits)
                }
                if actions.contains("decide") || actions.contains("recommend") {
                    TextField("Reason for this review", text: reason, axis: .vertical).lineLimit(2...5)
                    if actions.contains("recommend") {
                        HStack {
                            Picker("Recommendation", selection: $recommendation) {
                                Text("Revise").tag("revise"); Text("Approve").tag("approve"); Text("Reject").tag("reject")
                            }.frame(maxWidth: 320)
                            Button("Save recommendation") {
                                session.recordGraphReview(review, choice: recommendation, recommendation: true)
                            }.disabled(!canWrite)
                        }
                    }
                    if actions.contains("decide") {
                        HStack {
                            Button("Approve as human reviewer") {
                                session.recordGraphReview(review, choice: "approve", recommendation: false)
                            }
                            Button("Reject as human reviewer") {
                                session.recordGraphReview(review, choice: "reject", recommendation: false)
                            }
                        }.disabled(!canWrite)
                        Text("These buttons record a self-declared human review, not authenticated identity. Approval permits the next checkpoint; it does not start execution.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if review["decision"] != .null {
                    Text("Latest decision: \((review["decision"]["decision"].string ?? "Recorded").capitalized)")
                        .font(.caption.weight(.semibold))
                }
                if !review["recommendations"].array.isEmpty || !review["decisions"].array.isEmpty {
                    DisclosureGroup("Retained review history") {
                        ForEach(Array((review["recommendations"].array + review["decisions"].array).sorted {
                            ($0["revision"].integer ?? 0) < ($1["revision"].integer ?? 0)
                        }.suffix(100).enumerated()), id: \.offset) { _, record in
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\((record["decision"].string ?? record["recommendation"].string ?? "Review").capitalized) · \(record["reviewerKind"].string ?? record["actor"]["kind"].string ?? "Declared reviewer") · \(record["at"].string ?? "")")
                                    .font(.caption.weight(.semibold))
                                Text(record["reason"].string ?? "").font(.caption).textSelection(.enabled)
                            }
                        }
                        if review["recommendations"].array.count + review["decisions"].array.count > 100 {
                            Text("Showing the latest 100 retained entries. Full history remains available through the shared operations.").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(4)
        }
    }
    private func imageName(_ id: String?) -> String {
        session.images.first { $0.id == id }?.name ?? "Retained acquisition"
    }
}

struct WorkbenchGraphContinuationControls: View {
    @Bindable var session: WorkbenchSession
    @Bindable var draft: WorkbenchGraphContinuationDraft
    let job: WorkbenchJob
    let graph: WorkbenchJSON
    let checkpoints: [WorkbenchJSON]
    let detailCurrent: Bool
    private var checkpoint: WorkbenchJSON {
        checkpoints.indices.contains(draft.checkpointIndex) ? checkpoints[draft.checkpointIndex] : .null
    }
    private var branches: [WorkbenchJSON] {
        checkpoint["nodes"].array.filter { node in
            node["status"].string == "completed" && graph["nodes"].array.contains {
                $0["id"].string == node["nodeId"].string
                    && ["analysis", "volume-analysis", "model-segmentation", "plugin-segmentation", "mask-merge"].contains($0["type"].string ?? "")
            }
        }
    }
    private var needsExport: Bool { graph["nodes"].array.contains { $0["type"].string == "export" } }
    private var previewCurrent: Bool {
        draft.preview["previewFingerprint"].string != nil && draft.previewRevision == session.revision
            && draft.previewArguments == draft.arguments(jobID: job.id)
    }
    private var canMutate: Bool { !session.busy && !session.hasActiveWorkers && session.canRefreshWithoutDiscardingEdits }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Continue from saved corrections in a new job. The original job and masks remain available. Corrected branches are copied exactly; downstream review gates, measurements and exports run again.")
                .font(.caption).foregroundStyle(.secondary)
            if checkpoints.isEmpty {
                Text("Load branch details to select the original source and completed mask branches.").font(.caption)
            } else {
                Stepper("Source selection \(draft.checkpointIndex + 1) of \(checkpoints.count)", value: Binding(
                    get: { draft.checkpointIndex }, set: { draft.selectCheckpoint($0) }), in: 0...max(0, checkpoints.count - 1))
                Text("\(imageName(checkpoint["imageId"].string)) · \(workbenchGraphSelectionLabel(checkpoint["sourceSelection"]))")
                    .font(.caption).foregroundStyle(.secondary)
                TextField("Filter corrected image choices by name", text: $draft.imageQuery)
                if branches.isEmpty {
                    Text("This source selection has no completed segmentation or mask-merge branch yet.").font(.caption)
                }
                ForEach(Array(branches.enumerated()), id: \.offset) { _, node in correctionRow(node) }
                Text("Select up to eight branches. Candidate images share the retained source bytes and contain saved masks; the preview also verifies calibration, support, channel and time exactly.")
                    .font(.caption).foregroundStyle(.secondary)
                if needsExport {
                    HStack {
                        Text(draft.exportDestination.isEmpty ? "A new ZIP destination is required for this continuation." : URL(fileURLWithPath: draft.exportDestination).lastPathComponent)
                            .font(.caption).lineLimit(2)
                        Spacer()
                        Button("Choose new ZIP…", action: chooseExport)
                    }
                }
                HStack {
                    Button("Preview corrected continuation") { session.previewGraphContinuation(jobID: job.id) }
                        .disabled(!canMutate || !detailCurrent || draft.corrections.isEmpty || draft.corrections.values.contains("") || draft.corrections.count > 8 || (needsExport && draft.exportDestination.isEmpty))
                    Button("Create continuation job") { session.createGraphContinuation(jobID: job.id) }
                        .disabled(!canMutate || !previewCurrent)
                }
                if draft.preview != .null {
                    if previewCurrent { planDetails }
                    else { Text("The selection or project changed. Preview again before creating the continuation.").font(.caption).foregroundStyle(.orange) }
                }
                if let created = draft.createdJobID {
                    Text("Created \(session.jobs.first { $0.id == created }?.name ?? "a new continuation job"). Use its existing job controls to run the remaining checkpoints.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func correctionRow(_ node: WorkbenchJSON) -> some View {
        let id = node["nodeId"].string ?? ""
        let selected = draft.corrections[id]
        let binding = node["outputBinding"]
        return VStack(alignment: .leading, spacing: 5) {
            Toggle("Use corrected mask: \(workbenchGraphNodeLabel(graph, id: id))", isOn: Binding(
                get: { draft.corrections[id] != nil }, set: { enabled in
                    draft.corrections[id] = enabled ? (binding["imageId"].string ?? "") : nil
                }))
                .disabled(selected == nil && draft.corrections.count >= 8)
            if selected != nil {
                WorkbenchImageChoice(session: session, selection: Binding(get: { draft.corrections[id] ?? "" }, set: { draft.corrections[id] = $0 }),
                    title: "Corrected image", filters: ["sourceHash": binding["sourceHash"], "analysisTarget": binding["selection"]["target"]])
                Text(workbenchGraphSelectionLabel(binding["selection"])).font(.caption).foregroundStyle(.secondary)
            }
        }.padding(8).background(.quaternary.opacity(0.25)).clipShape(RoundedRectangle(cornerRadius: 6))
    }
    private var planDetails: some View {
        let plan = draft.preview["plan"]
        return VStack(alignment: .leading, spacing: 5) {
            Text("\(plan["newImageCount"].integer ?? 0) independent corrected images will be retained.").font(.caption.weight(.semibold))
            Text("Reuse: \(labels(plan["reusedNodeIds"]))").font(.caption)
            Text("Run again: \(labels(plan["resetNodeIds"]))").font(.caption)
            ForEach(Array(plan["notes"].array.compactMap(\.string).enumerated()), id: \.offset) { _, note in
                Text(note).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
    private func labels(_ values: WorkbenchJSON) -> String {
        let names = values.array.compactMap(\.string).map { workbenchGraphNodeLabel(graph, id: $0) }
        return names.isEmpty ? "None" : names.joined(separator: ", ")
    }
    private func imageName(_ id: String?) -> String { session.images.first { $0.id == id }?.name ?? "Retained acquisition" }
    private func chooseExport() {
        let panel = NSSavePanel(); panel.allowedContentTypes = [.zip]; panel.nameFieldStringValue = "corrected-continuation.zip"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard !FileManager.default.fileExists(atPath: url.path) else {
            session.error = "Choose a new ZIP filename. Existing exported results are preserved."; return
        }
        draft.exportDestination = url.path
    }
}
