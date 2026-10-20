import SwiftUI

struct WorkbenchModelCardControls: View {
    @Bindable var session: WorkbenchSession
    @Bindable var models: WorkbenchModelState
    let model: WorkbenchRegisteredModel
    @Bindable var draft: WorkbenchModelCardDraft
    private var saved: WorkbenchJSON { models.cards[model.id]?["card"] ?? .null }
    private var versions: [WorkbenchJSON] { models.cards[model.id]?["cards"].array ?? [] }
    private var canWrite: Bool { !session.busy && !session.hasActiveWorkers && !models.hasActiveTraining && session.canRefreshWithoutDiscardingEdits }
    private var evaluations: [WorkbenchJSON] {
        session.extensions.datasets.flatMap { dataset in dataset["evaluations"].array.filter { row in
            ["baseline", "candidate"].contains { row["choices"][$0]["modelId"].string == model.id }
        } }
    }
    var body: some View {
        DisclosureGroup("Model card and future default") {
            VStack(alignment: .leading, spacing: 9) {
                Button("Read saved card and history") { session.loadModelCard(model.id) }
                if saved != .null {
                    HStack {
                        Text("Card version \(saved["version"].integer ?? 1)").font(.callout.weight(.medium))
                        if saved["inputsCurrent"].bool == false { Text("Model binding changed").font(.caption).foregroundStyle(.orange) }
                    }
                    Picker("Saved card version", selection: Binding(get: { saved["version"].integer ?? 1 }, set: { session.loadModelCard(model.id, version: $0) })) {
                        ForEach(Array(versions.enumerated()), id: \.offset) { _, card in Text("Version \(card["version"].integer ?? 1)").tag(card["version"].integer ?? 1) }
                    }
                    Text(saved["intendedUse"].string ?? "").font(.caption)
                    Text(saved["limitations"].string ?? "").font(.caption).foregroundStyle(.secondary)
                    Button("Load saved card into draft") { draft.load(saved) }.disabled(draft.dirty)
                    DisclosureGroup("Frozen evidence identities") { WorkbenchStructuredOutput(value: saved).frame(maxHeight: 180) }
                }
                Text("Author a new card version").font(.callout.weight(.medium))
                TextField("Intended use", text: $draft.intendedUse, axis: .vertical).lineLimit(2...5)
                TextField("Known limitations", text: $draft.limitations, axis: .vertical).lineLimit(2...5)
                TextField("Additional notes", text: $draft.notes, axis: .vertical).lineLimit(2...4)
                if draft.dirty { Text("Unsaved card draft").font(.caption).foregroundStyle(.orange) }
                DisclosureGroup("Link retained comparisons") {
                    WorkbenchSavedRecordAccess(session: session, catalogues: ["adaptationDatasets"])
                    Text("Choices include loaded reference datasets. Keep an older dataset in editor choices to link its retained comparisons.").font(.caption).foregroundStyle(.secondary)
                    ForEach(Array(evaluations.enumerated()), id: \.offset) { _, evaluation in
                        if let id = evaluation["id"].string {
                            Toggle("Comparison \(evaluation["evaluationNumber"].integer ?? 0) · \(evaluation["biologicalTestN"].integer ?? 0) test specimens", isOn: Binding(get: { draft.evaluationIDs.contains(id) }, set: { if $0 { draft.evaluationIDs.insert(id) } else { draft.evaluationIDs.remove(id) } }))
                        }
                    }
                    Text("\(draft.evaluationIDs.count) retained comparison identities selected").font(.caption)
                }
                HStack {
                    Button("Save new card version") { session.saveModelCard(model.id) }
                        .disabled(!canWrite || draft.intendedUse.count > 4000 || draft.limitations.count > 8000 || draft.notes.count > 4000)
                    if draft.dirty { Button("Discard card draft") { draft.load(saved) } }
                }
                Text("Authored intended use is documentation, not an accuracy certification. The card retains the exact model, observed environment, training and linked evaluation identities.").font(.caption).foregroundStyle(.secondary)
                Divider()
                Text("Future model-selection default").font(.callout.weight(.medium))
                if let id = models.activation["modelId"].string {
                    Text(models.models.first { $0.id == id }?.name ?? "Retained model default").font(.caption)
                    if models.activation["available"].bool != true { Text("The saved default is disabled or its binding changed. Select and trust the intended model explicitly.").font(.caption).foregroundStyle(.orange) }
                } else { Text("No model default is saved.").font(.caption).foregroundStyle(.secondary) }
                TextField("Reason for changing the future default", text: $draft.activationReason, axis: .vertical).lineLimit(2...3)
                HStack {
                    Button("Use this model for future selections") { session.setFutureModelDefault(model.id, reason: draft.activationReason) }.disabled(!model.enabled)
                    Button("Clear default") { session.setFutureModelDefault(nil, reason: draft.activationReason) }
                }.disabled(!canWrite || draft.activationReason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || draft.activationReason.count > 2000)
                Text("Current drafts, saved workflows and masks stay unchanged. To roll back, choose the previous registered model and record a new default decision; trust is never enabled by this preference.").font(.caption).foregroundStyle(.secondary)
                DisclosureGroup("Default-selection history") {
                    ForEach(Array(models.activationHistory.reversed().prefix(50).enumerated()), id: \.offset) { _, record in
                        Text("\(record["createdAt"].string ?? "") · \(record["reason"].string ?? "")").font(.caption)
                    }
                    if models.activationHistory.count > 50 { Text("Showing the latest 50 of \(models.activationHistory.count) retained decisions.").font(.caption).foregroundStyle(.secondary) }
                }
            }.textFieldStyle(.roundedBorder)
        }
    }
}
