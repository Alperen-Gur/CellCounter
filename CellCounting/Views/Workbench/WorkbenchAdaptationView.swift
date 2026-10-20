import SwiftUI

struct WorkbenchAdaptationView: View {
    @Bindable var session: WorkbenchSession
    @Bindable var extensions: WorkbenchExtensionState
    @Environment(\.dismiss) private var dismiss
    @State private var reviewImageID = ""
    @State private var reviewNote = ""
    @State private var datasetName = "Reviewed reference dataset"
    @State private var imageIDs: Set<String> = []
    @State private var resolvedImageIDs: Set<String> = []
    @State private var assignmentRevision: Int?
    @State private var partitions: [String: String] = [:]
    @State private var suggestionImageIDs: Set<String> = []
    @State private var freezeExtraChannels = false
    @State private var frozenChannelsText = "0, 1, 2"
    @State private var baselineKind = "model"
    @State private var candidateKind = "model"
    @State private var baselineID = ""
    @State private var candidateID = ""
    @State private var baselineValues: [String: WorkbenchJSON] = [:]
    @State private var candidateValues: [String: WorkbenchJSON] = [:]

    private var eligibleImages: [WorkbenchImage] { session.images.filter { $0.cellCount != nil && $0.timeCount == 1 } }
    private var segmenters: [WorkbenchPlugin] {
        extensions.plugins.filter { $0.enabled && $0.available && $0.kind == "segmentation" && $0.dimensions.contains(2) }
    }
    private var frozenChannels: [Int]? {
        let parts = frozenChannelsText.split(separator: ",", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        let values = parts.compactMap(Int.init)
        return (1...3).contains(parts.count) && values.count == parts.count && values.allSatisfy { (0...65535).contains($0) } && Set(values).count == values.count ? values : nil
    }
    private var comparisonArguments: WorkbenchJSON {
        .object(["datasetId": .string(extensions.selectedDatasetID),
                 "baseline": .object([baselineKind == "model" ? "modelId" : "pluginId": .string(baselineID), "parameters": .object(baselineValues)]),
                 "candidate": .object([candidateKind == "model" ? "modelId" : "pluginId": .string(candidateID), "parameters": .object(candidateValues)])])
    }
    private var comparisonCurrent: Bool {
        extensions.evaluationRevision == session.revision && extensions.evaluationArguments == comparisonArguments
    }
    private var selectedSpecimens: [WorkbenchSpecimen] {
        let ids = Set(session.assignments.filter { imageIDs.contains($0.imageID) }.map(\.specimenID))
        return session.specimens.filter { ids.contains($0.id) }
    }
    private var canApprove: Bool {
        !reviewImageID.isEmpty && session.selectedImageID == reviewImageID && !session.viewingVolume &&
        !session.isPreview && !session.parametersChanged && session.preview != nil
    }
    private var splitValid: Bool {
        let groups = selectedSpecimens.map { partitions[$0.id] ?? "train" }
        let assigned = Set(session.assignments.filter { imageIDs.contains($0.imageID) }.map(\.imageID))
        return !datasetName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && datasetName.count <= 200 &&
            !imageIDs.isEmpty && imageIDs.count <= 200 &&
            imageIDs == resolvedImageIDs && assignmentRevision == session.revision && imageIDs == assigned &&
            Set(groups) == Set(["train", "validation", "test"]) && (!freezeExtraChannels || frozenChannels != nil)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
            Text("Reference datasets, training and comparison").font(.title2)
                WorkbenchSavedRecordAccess(session: session, catalogues: ["adaptationDatasets", "plugins", "models", "specimens", "assignments"])
                Spacer()
                Button("Refresh", action: session.loadExtensions).disabled(session.busy)
                Button("Done") { dismiss() }.disabled(session.busy)
            }
            Text("Review 2D masks, preserve specimen boundaries, then compare enabled segmenters on the same frozen test references.")
                .font(.callout).foregroundStyle(.secondary)
            if let error = session.error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            TabView {
                review.tabItem { Text("1 · Review") }
                dataset.tabItem { Text("2 · Freeze dataset") }
                WorkbenchTrainingPanel(session: session, extensions: extensions, models: session.models)
                    .tabItem { Text("3 · Train") }
                comparison.tabItem { Text("4 · Compare segmenters") }
            }.disabled(session.busy)
            HStack {
                if session.busy { ProgressView().controlSize(.small) }
                Text(session.status).font(.caption).foregroundStyle(.secondary)
                Spacer()
            }
        }.padding(24).frame(width: 960, height: 680)
        .task {
            reviewImageID = eligibleImages.contains(where: { $0.id == session.selectedImageID }) ? session.selectedImageID ?? "" : eligibleImages.first?.id ?? ""
            session.loadExtensions()
        }
        .onChange(of: baselineID) { _, _ in baselineValues = initialParameters(kind: baselineKind, id: baselineID) }
        .onChange(of: baselineKind) { _, _ in baselineID = ""; baselineValues = [:] }
        .onChange(of: candidateID) { _, _ in candidateValues = initialParameters(kind: candidateKind, id: candidateID) }
        .onChange(of: candidateKind) { _, _ in candidateID = ""; candidateValues = [:] }
    }

    private var review: some View {
        HSplitView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Approve a reviewed mask").font(.headline)
                WorkbenchImageChoice(session: session, selection: $reviewImageID, title: "Image",
                    eligible: { $0.timeCount == 1 }, filters: ["analysisTarget": .string("plane")])
                Button("Open mask for review") {
                    session.showReferenceImage(reviewImageID); dismiss()
                }.disabled(reviewImageID.isEmpty)
                Text("Inspect and correct the complete saved mask in the workbench. Return here to record your approval.")
                    .font(.callout).foregroundStyle(.secondary)
                TextField("Review note (optional)", text: $reviewNote, axis: .vertical)
                    .lineLimit(3...5).textFieldStyle(.roundedBorder)
                HStack {
                    Button("Approve current mask") { session.approveReference(imageID: reviewImageID, approved: true, note: reviewNote) }
                        .buttonStyle(.borderedProminent).disabled(!canApprove || reviewNote.count > 2000)
                    Button("Revoke") { session.approveReference(imageID: reviewImageID, approved: false, note: reviewNote) }
                        .disabled(reviewImageID.isEmpty || extensions.referenceCurrent[reviewImageID] != true || reviewNote.count > 2000)
                }
                Text(extensions.referenceCurrent[reviewImageID] == true ? "Current mask approved." : "Current mask has no valid approval.")
                    .font(.caption).foregroundStyle(.secondary)
                if eligibleImages.isEmpty {
                    Text("Run a 2D segmentation first. Volumetric and time-series reference datasets are not supported here yet.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
            }.padding(14).frame(minWidth: 350)
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Suggested images").font(.headline)
                    Spacer()
                    Button("Suggest") { session.suggestReferences(imageIDs: suggestionImageIDs) }.disabled(suggestionImageIDs.isEmpty || suggestionImageIDs.count > 200)
                }
                WorkbenchImageSelection(session: session, selection: $suggestionImageIDs, title: "Candidate acquisitions (up to 200)")
                Text("Combines feature diversity with heuristic difficulty. Frozen test specimens are excluded.")
                    .font(.caption).foregroundStyle(.secondary)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(Array((extensions.suggestions?["suggestions"].array ?? []).enumerated()), id: \.offset) { _, suggestion in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(suggestion["name"].string ?? "Image").font(.callout.weight(.medium))
                                Text(suggestion["selectionReason"].string == "feature-diversity" ? "Representative feature diversity" : "Potentially difficult annotation")
                                    .font(.caption).foregroundStyle(.secondary)
                                Text(suggestion["reason"].string ?? "").font(.caption).foregroundStyle(.secondary)
                                Button("Inspect image") {
                                    if let id = suggestion["imageId"].string { session.showReferenceImage(id); dismiss() }
                                }
                            }
                        }
                    }
                }
                Text("Scores do not estimate segmentation error probability.").font(.caption).foregroundStyle(.secondary)
            }.padding(14).frame(minWidth: 350)
        }
    }

    private var dataset: some View {
        HSplitView {
            VStack(alignment: .leading, spacing: 10) {
                TextField("Dataset name", text: $datasetName).textFieldStyle(.roundedBorder)
                Text("Select approved images").font(.headline)
                Text("\(imageIDs.count) / 200 images selected").font(.caption).foregroundStyle(.secondary)
                WorkbenchImageSelection(session: session, selection: $imageIDs,
                    eligible: { $0.timeCount == 1 && $0.referenceCurrent }, title: "Approved acquisitions",
                    filters: ["analysisTarget": .string("plane"), "referenceCurrent": .bool(true)])
                Button("Resolve selected specimen assignments") {
                    let selected = imageIDs
                    session.resolveAdaptationSpecimens(imageIDs: selected) { revision in resolvedImageIDs = selected; assignmentRevision = revision }
                }.disabled(imageIDs.isEmpty || imageIDs.count > 200)
                if resolvedImageIDs != imageIDs || assignmentRevision != session.revision {
                    Text("Resolve assignments after changing the selected images or project revision. Recent specimen pages are not the complete experiment.").font(.caption).foregroundStyle(.orange)
                }
                Text("Assign each image to a biological specimen in Experiments before freezing the dataset.")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(14).frame(minWidth: 340)
            VStack(alignment: .leading, spacing: 12) {
                Text("Keep specimens in one partition").font(.headline)
                Text("Choose validation and test specimens. All other selected specimens form the training split.")
                    .font(.callout).foregroundStyle(.secondary)
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(selectedSpecimens) { specimen in
                            HStack {
                                Text(specimen.name).frame(maxWidth: .infinity, alignment: .leading)
                                Picker("Partition for \(specimen.name)", selection: Binding(
                                    get: { partitions[specimen.id] ?? "train" }, set: { partitions[specimen.id] = $0 })) {
                                    Text("Train").tag("train"); Text("Validation").tag("validation"); Text("Test").tag("test")
                                }.labelsHidden().frame(width: 130)
                            }
                        }
                    }
                }
                Text("All three splits require independent specimens. Frozen test specimens stay outside later training and annotation suggestions.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Freeze explicit acquired input channels", isOn: $freezeExtraChannels)
                if freezeExtraChannels {
                    TextField("Acquired channel indices, e.g. 0, 1, 2", text: $frozenChannelsText).textFieldStyle(.roundedBorder)
                    Text("Choose one to three zero-based channels acquired by every sample, including the approved mask's primary channel. Exact planes share the reference support crop; no channels are synthesized. Up to 512 MiB of inputs and references are retained.").font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("Only each approved reference's primary channel is frozen. Multi-channel models require a new explicit-channel dataset.").font(.caption).foregroundStyle(.secondary)
                }
                Button("Freeze dataset") {
                    let selectedPartitions = Dictionary(uniqueKeysWithValues: selectedSpecimens.map { ($0.id, partitions[$0.id] ?? "train") })
                    session.createReferenceDataset(name: datasetName.trimmingCharacters(in: .whitespacesAndNewlines), imageIDs: imageIDs, partitions: selectedPartitions, inputChannels: freezeExtraChannels ? frozenChannels : nil)
                }.buttonStyle(.borderedProminent).disabled(!splitValid)
            }.padding(14).frame(minWidth: 360)
        }
    }

    private var comparison: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Frozen dataset", selection: $extensions.selectedDatasetID) {
                Text("Select a dataset").tag("")
                ForEach(Array(extensions.datasets.enumerated()), id: \.offset) { _, dataset in
                    Text(dataset["name"].string ?? "Dataset").tag(dataset["id"].string ?? "")
                }
            }
            if let selected = extensions.selectedDataset {
                Text("\(selected["counts"]["train"].integer ?? 0) train · \(selected["counts"]["validation"].integer ?? 0) validation · \(selected["counts"]["test"].integer ?? 0) test images")
                    .font(.caption).foregroundStyle(.secondary)
                DisclosureGroup("Frozen samples and specimen partitions") {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 5) {
                            ForEach(Array(selected["samples"].array.enumerated()), id: \.offset) { _, sample in
                                Text("\(sample["name"].string ?? "Image") · \(sample["specimen"]["name"].string ?? sample["specimenId"].string ?? "Specimen") · \(sample["partition"].string ?? "")\(sample["currentReference"].bool == false ? " · Current mask changed; frozen reference preserved" : "")")
                            }
                        }.font(.caption).textSelection(.enabled)
                    }.frame(maxHeight: 100)
                }
                HSplitView {
                    modelChoice(title: "Baseline", kind: $baselineKind, id: $baselineID, values: $baselineValues).frame(minWidth: 260)
                    modelChoice(title: "Candidate", kind: $candidateKind, id: $candidateID, values: $candidateValues).frame(minWidth: 260)
                }.frame(minHeight: 110, maxHeight: 220)
                HStack {
                    Button("Preview input compatibility") { session.previewReferenceComparison(comparisonArguments) }
                        .disabled(baselineID.isEmpty || candidateID.isEmpty)
                    Button("Compare on frozen test specimens") { session.evaluateReferenceDataset(comparisonArguments) }
                        .buttonStyle(.borderedProminent).disabled(!comparisonCurrent || extensions.evaluationPreview?["ready"].bool != true || session.hasActiveWorkers || session.models.hasActiveTraining || !session.canRefreshWithoutDiscardingEdits)
                }
                if let preview = extensions.evaluationPreview {
                    if !comparisonCurrent { Text("Comparison choices or project revision changed. Preview compatibility again.").font(.caption).foregroundStyle(.orange) }
                    ForEach(Array(preview["blockers"].array.enumerated()), id: \.offset) { _, blocker in
                        Text("\(blocker["role"].string.map { $0.capitalized + ": " } ?? "")\(blocker["message"].string ?? "Incompatible frozen input")").font(.caption).foregroundStyle(.orange)
                    }
                    DisclosureGroup("Exact frozen input compatibility") { WorkbenchStructuredOutput(value: preview["samples"]).frame(maxHeight: 160) }
                }
                Text("This comparison runs enabled segmenters; it does not train a model. Repeated test inspection is recorded.")
                    .font(.caption).foregroundStyle(.secondary)
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        ForEach(Array(selected["evaluations"].array.reversed().enumerated()), id: \.offset) { _, evaluation in
                            evaluationView(evaluation)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                ContentUnavailableView("No frozen dataset", systemImage: "square.stack", description: Text("Approve masks and assign specimen partitions first."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }.padding(14)
    }

    private func initialParameters(kind: String, id: String) -> [String: WorkbenchJSON] {
        if kind == "plugin" { return segmenters.first { $0.id == id }?.initialParameters ?? [:] }
        var settings = WorkbenchModelInferenceSettings(); settings.configure(session.models.models.first { $0.id == id }?.inferenceSchema ?? .null)
        return settings.values
    }
    private func modelChoice(title: String, kind: Binding<String>, id: Binding<String>, values: Binding<[String: WorkbenchJSON]>) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Text(title).font(.headline)
                Picker("Method source", selection: kind) { Text("Registered model").tag("model"); Text("Segmentation plugin").tag("plugin") }
                Picker("Enabled method", selection: id) {
                    Text("Select a method").tag("")
                    if kind.wrappedValue == "model" {
                        ForEach(session.models.models.filter(\.enabled)) { Text("\($0.name) · \($0.backend)").tag($0.id) }
                    } else { ForEach(segmenters) { Text("\($0.name) · v\($0.version)").tag($0.id) } }
                }
                if kind.wrappedValue == "plugin", let selected = segmenters.first(where: { $0.id == id.wrappedValue }) {
                    WorkbenchPluginParameters(definitions: selected.parameters, values: values)
                } else if let model = session.models.models.first(where: { $0.id == id.wrappedValue }) {
                    let settings = WorkbenchModelInferenceSettings(schema: model.inferenceSchema, values: values.wrappedValue)
                    WorkbenchPluginParameters(definitions: settings.definitions, values: values)
                    Text("Primary input is the frozen reference channel; additional channel controls refer to acquired indices retained in this dataset.").font(.caption).foregroundStyle(.secondary)
                }
            }.padding(.horizontal, 8)
        }
    }
    private func evaluationView(_ value: WorkbenchJSON) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("Comparison \(value["evaluationNumber"].integer ?? 0) · \(value["biologicalTestN"].integer ?? 0) test specimens")
                .font(.headline)
            Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 5) {
                GridRow { Text("Metric"); Text("Baseline"); Text("Candidate"); Text("Change") }.fontWeight(.semibold)
                ForEach(["ap50", "f1", "precision", "recall", "meanDiamError"], id: \.self) { metric in
                    GridRow {
                        Text(metric == "meanDiamError" ? "Mean diameter error (px)" : metric.uppercased())
                        Text(format(value["baseline"][metric].number))
                        Text(format(value["candidate"][metric].number))
                        Text(format(value["delta"][metric].number))
                    }
                }
            }.font(.caption.monospacedDigit())
            Text("Paired descriptive results. Diameter error is better when lower; the other displayed metrics are better when higher.")
                .font(.caption).foregroundStyle(.secondary)
        }.textSelection(.enabled)
    }
    private func format(_ value: Double?) -> String { value.map { String(format: "%.4f", $0) } ?? "—" }
}
