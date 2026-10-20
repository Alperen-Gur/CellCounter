import SwiftUI

struct WorkbenchExperimentLayoutsView: View {
    @Bindable var session: WorkbenchSession
    @Bindable var state: WorkbenchExperimentLayoutState
    @State private var slotPage = 0
    @State private var bindingSlot = ""
    @State private var showStatistics = false
    private var canWrite: Bool { !session.busy && !session.hasActiveWorkers && session.canRefreshWithoutDiscardingEdits }
    private var selectedSlots: [WorkbenchJSON] { state.selectedLayout?["definition"]["slots"].array ?? [] }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Picker("Saved layout", selection: $state.layoutID) {
                        Text("New layout").tag("")
                        ForEach(Array(state.layouts.enumerated()), id: \.offset) { _, row in Text(row["name"].string ?? "Layout").tag(row["id"].string ?? "") }
                    }
                    Stepper("Version \(state.layoutVersion)", value: $state.layoutVersion, in: 1...max(1, state.layouts.first { $0["id"].string == state.layoutID }?["latestVersion"].integer ?? 1))
                    Button("Load for editing") { session.loadExperimentLayout(editing: true) }.disabled(state.layoutID.isEmpty)
                    Button("Use for application") { session.loadExperimentLayout(editing: false) }.disabled(state.layoutID.isEmpty)
                }
                DisclosureGroup("Layout definition") {
                    VStack(alignment: .leading, spacing: 10) {
                        TextField("Layout name", text: $state.name)
                        WorkbenchFactorEditor(factors: $state.factors)
                        Toggle("Include a plate", isOn: $state.hasPlate)
                        if state.hasPlate { HStack { Stepper("Rows \(state.rows)", value: $state.rows, in: 1...100); Stepper("Columns \(state.columns)", value: $state.columns, in: 1...100) } }
                        HStack {
                            Text("Biological specimen slots").font(.headline)
                            Spacer(); Button("Previous") { slotPage -= 1 }.disabled(slotPage == 0)
                            Button("Next") { slotPage += 1 }.disabled((slotPage + 1) * 20 >= state.slots.count)
                        }
                        ForEach(Array(state.slots.indices.dropFirst(slotPage * 20).prefix(20)), id: \.self) { index in slotEditor(index) }
                        HStack {
                            Button("Add specimen slot") {
                                var slot = WorkbenchLayoutSlot(); slot.name = "Specimen \(state.slots.count + 1)"
                                slot.values = Dictionary(uniqueKeysWithValues: state.factors.map { ($0.id, $0.kind == "numeric" ? "0" : $0.levelList.first ?? "") })
                                state.slots.append(slot); slotPage = (state.slots.count - 1) / 20
                            }.disabled(state.slots.count >= 1000)
                            Text("\(state.slots.count) slots · one slot creates one biological specimen").font(.caption).foregroundStyle(.secondary)
                        }
                        TextField("Layout notes", text: $state.notes, axis: .vertical).lineLimit(2...4)
                        HStack {
                            Button("Save as new layout") { session.saveExperimentLayout(asNew: true) }.disabled(!canWrite || state.slots.isEmpty || state.name.isEmpty)
                            Button("Save new version") { session.saveExperimentLayout(asNew: false) }.disabled(!canWrite || state.layoutID.isEmpty || state.slots.isEmpty)
                            Button("Clear layout draft") { state.newLayout(); slotPage = 0 }
                        }
                    }.padding(6)
                }
                if let layout = state.selectedLayout {
                    GroupBox("Apply \(layout["name"].string ?? "layout") · Version \(layout["version"].integer ?? 1)") {
                        VStack(alignment: .leading, spacing: 10) {
                            TextField("Instance name", text: $state.instanceName)
                            TextField("Experiment", text: $state.experiment)
                            if layout["definition"]["plate"] != .null { TextField("New plate name", text: $state.plateName) }
                            Picker("Bind specimen slot", selection: $bindingSlot) {
                                Text("Choose a slot").tag("")
                                ForEach(Array(selectedSlots.enumerated()), id: \.offset) { _, slot in Text("\(slot["name"].string ?? "Slot") · \(slot["condition"].string ?? "")").tag(slot["key"].string ?? "") }
                            }
                            if !bindingSlot.isEmpty {
                                WorkbenchImageSelection(session: session, selection: Binding(get: { state.bindings[bindingSlot] ?? [] }, set: { state.bindings[bindingSlot] = $0 }), title: "Image fields for this specimen")
                                TextField("Field identifier (optional)", text: dictionaryBinding(\.fields, bindingSlot))
                            }
                            Text("\(selectedSlots.filter { !(state.bindings[$0["key"].string ?? ""] ?? []).isEmpty }.count) of \(selectedSlots.count) slots have image bindings. Empty slots remain explicit specimen identities.").font(.caption).foregroundStyle(.secondary)
                            DisclosureGroup("Reuse subject and block identities") {
                                Text("Leave blank to create new identities. Enter an exact existing ID only when the same subject or block is intentionally reused; matching names do not link specimens.").font(.caption).foregroundStyle(.secondary)
                                ForEach(mappingKeys("subjectKey"), id: \.self) { key in TextField("Subject \(key): existing ID", text: dictionaryBinding(\.subjects, key)) }
                                ForEach(mappingKeys("blockKey"), id: \.self) { key in TextField("Block \(key): existing ID", text: dictionaryBinding(\.blocks, key)) }
                            }
                            Toggle("Replace existing image assignments after review", isOn: $state.replaceAssignments)
                            HStack {
                                Button("Preview assignment changes", action: session.previewExperimentApplication).disabled(state.experiment.isEmpty || state.instanceName.isEmpty)
                                Button("Apply reviewed layout", action: session.applyExperimentLayout).buttonStyle(.borderedProminent).disabled(!canWrite || !state.applicationCurrent(session.revision))
                            }
                            if let preview = state.applicationPreview {
                                let plan = preview["plan"]
                                Text("\(plan["newSpecimens"].array.count) new specimens · \(plan["assignments"].array.count) assignments · \(plan["replacedAssignments"].array.count) replacements").font(.headline)
                                if !state.applicationCurrent(session.revision) { Text("Bindings or project revision changed. Preview again before applying.").font(.caption).foregroundStyle(.orange) }
                                WorkbenchStructuredOutput(value: plan).frame(minHeight: 140, maxHeight: 280)
                            }
                        }.padding(6)
                    }
                }
                GroupBox("Retained layout applications") {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Picker("Application", selection: $state.applicationID) { Text("Select an application").tag(""); ForEach(Array(state.applications.enumerated()), id: \.offset) { _, row in Text(row["instanceName"].string ?? row["name"].string ?? "Application").tag(row["id"].string ?? "") } }
                            Button("Inspect", action: session.loadExperimentApplication).disabled(state.applicationID.isEmpty)
                        }
                        if let application = state.selectedApplication {
                            Text("Prepare a statistical draft from the retained factor, subject and block rows. Outcome and input coverage are reviewed in Statistics.").font(.caption).foregroundStyle(.secondary)
                            HStack {
                                Button("Prepare statistical draft", action: session.draftStatisticsFromApplication).disabled(session.statistics.dirty)
                                Button("Open Statistics") { showStatistics = true }
                            }
                            if session.statistics.dirty { Text("Save or explicitly discard the current statistical draft before replacing its rows.").font(.caption).foregroundStyle(.orange) }
                            DisclosureGroup("Application provenance") { WorkbenchStructuredOutput(value: application).frame(minHeight: 120, maxHeight: 260) }
                        }
                    }.padding(6)
                }
            }.padding(.top, 12).textFieldStyle(.roundedBorder).disabled(session.busy)
        }.sheet(isPresented: $showStatistics) { WorkbenchStatisticsView(session: session, statistics: session.statistics) }
    }
    private func slotEditor(_ index: Int) -> some View {
        GroupBox("Slot \(index + 1)") {
            VStack(alignment: .leading, spacing: 7) {
                HStack { TextField("Specimen name", text: $state.slots[index].name); TextField("Condition", text: $state.slots[index].condition); Picker("Role", selection: $state.slots[index].role) { Text("Control").tag("control"); Text("Treatment").tag("treatment"); Text("Other").tag("other") } }
                ForEach(state.factors) { factor in
                    let value = Binding(get: { state.slots[index].values[factor.id] ?? "" }, set: { state.slots[index].values[factor.id] = $0 })
                    if factor.kind == "categorical" { Picker(factor.name, selection: value) { Text("Choose level").tag(""); ForEach(factor.levelList, id: \.self) { Text($0).tag($0) } } }
                    else { TextField("\(factor.name) \(factor.unit)", text: value) }
                }
                HStack { TextField("Subject key (optional)", text: $state.slots[index].subjectKey); TextField("Block key (optional)", text: $state.slots[index].blockKey) }
                if state.hasPlate {
                    Toggle("Place in a well", isOn: $state.slots[index].well)
                    if state.slots[index].well { HStack { Stepper("Row \(state.slots[index].row)", value: $state.slots[index].row, in: 1...state.rows); Stepper("Column \(state.slots[index].column)", value: $state.slots[index].column, in: 1...state.columns) } }
                }
                Button("Remove slot") { state.slots.remove(at: index); slotPage = min(slotPage, max(0, (state.slots.count - 1) / 20)) }
            }.padding(4)
        }
    }
    private func mappingKeys(_ name: String) -> [String] { Array(Set(selectedSlots.compactMap { $0[name].string })).sorted() }
    private func dictionaryBinding(_ path: ReferenceWritableKeyPath<WorkbenchExperimentLayoutState, [String: String]>, _ key: String) -> Binding<String> {
        Binding(get: { state[keyPath: path][key] ?? "" }, set: { state[keyPath: path][key] = $0 })
    }
}

struct WorkbenchAcquisitionSessionsView: View {
    @Bindable var session: WorkbenchSession
    @Bindable var state: WorkbenchExperimentLayoutState
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 11) {
                HStack {
                    Picker("Saved session", selection: $state.sessionID) { Text("New acquisition session").tag(""); ForEach(Array(state.acquisitionSessions.enumerated()), id: \.offset) { _, row in Text(row["name"].string ?? "Session").tag(row["id"].string ?? "") } }
                    Stepper("Version \(state.sessionVersion)", value: $state.sessionVersion, in: 1...max(1, state.acquisitionSessions.first { $0["id"].string == state.sessionID }?["version"].integer ?? 1))
                    Button("Load for editing", action: session.loadAcquisitionSession).disabled(state.sessionID.isEmpty)
                }
                TextField("Acquisition session name", text: $state.acquisitionName)
                TextField("Instrument", text: $state.instrument)
                TextField("Operator (optional)", text: $state.operatorName)
                HStack { TextField("Started at, e.g. 2026-10-21T09:00:00+03:00", text: $state.startedAt); TextField("Ended at (optional, with time zone)", text: $state.endedAt) }
                Text("Leave unknown times blank. Saved timestamps require an explicit time zone; image order does not imply acquisition time.").font(.caption).foregroundStyle(.secondary)
                WorkbenchImageSelection(session: session, selection: $state.acquisitionImages, title: "Session acquisitions")
                TextField("Acquisition notes", text: $state.acquisitionNotes, axis: .vertical).lineLimit(2...4)
                HStack {
                    Button("Save as new session") { session.saveAcquisitionSession(asNew: true) }
                    Button("Save new version") { session.saveAcquisitionSession(asNew: false) }.disabled(state.sessionID.isEmpty)
                    Button("Clear session draft") { state.newSession() }
                }.disabled(state.acquisitionName.isEmpty || state.instrument.isEmpty || session.hasActiveWorkers || !session.canRefreshWithoutDiscardingEdits)
                Text("Session membership records acquisition metadata and exact source identities. It does not change specimen assignments or biological replicate counts.").font(.caption).foregroundStyle(.secondary)
                if let record = state.selectedSession { DisclosureGroup("Retained source membership") { WorkbenchStructuredOutput(value: record).frame(minHeight: 120, maxHeight: 260) } }
            }.padding(.top, 12).textFieldStyle(.roundedBorder).disabled(session.busy)
        }
    }
}

struct WorkbenchExperimentExclusionsView: View {
    @Bindable var session: WorkbenchSession
    @Bindable var state: WorkbenchExperimentLayoutState
    private var resolved: Bool { state.exclusionResolvedKey == state.exclusionTarget + ":" + state.exclusionID && state.exclusionResolvedRevision == session.revision }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 11) {
                Text("Reasoned exclusions").font(.headline)
                Text("Exclude a biological specimen or an individual acquisition from current summaries. Exclusion is independent of archive visibility; original data and earlier decisions remain retained.").font(.callout).foregroundStyle(.secondary)
                Picker("Target", selection: $state.exclusionTarget) { Text("Biological specimen").tag("specimen"); Text("Image field").tag("image") }.onChange(of: state.exclusionTarget) { _, _ in state.exclusionID = "" }
                if state.exclusionTarget == "specimen" {
                    Picker("Specimen", selection: $state.exclusionID) { Text("Choose specimen").tag(""); ForEach(session.specimens) { Text("\($0.name) · \($0.experiment)").tag($0.id) } }
                } else { WorkbenchImageChoice(session: session, selection: $state.exclusionID, title: "Acquisition") }
                Button("Read current decision", action: session.loadSelectedExclusion).disabled(state.exclusionID.isEmpty)
                if resolved {
                    if let decision = state.selectedExclusion {
                        Text(decision["excluded"].bool == true ? "Current decision: excluded" : "Current decision: included").font(.callout.weight(.medium))
                        Text(decision["reason"].string ?? "").font(.caption).foregroundStyle(.secondary)
                    } else { Text("No explicit exclusion decision is saved for this target.").font(.caption).foregroundStyle(.secondary) }
                }
                Picker("New decision", selection: $state.excluded) { Text("Exclude").tag(true); Text("Restore inclusion").tag(false) }
                TextField("Reason for this decision", text: $state.exclusionReason, axis: .vertical).lineLimit(2...4).textFieldStyle(.roundedBorder)
                Button("Record decision", action: session.saveExperimentExclusion).buttonStyle(.borderedProminent)
                    .disabled(state.exclusionID.isEmpty || state.exclusionReason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || session.hasActiveWorkers || !session.canRefreshWithoutDiscardingEdits)
                Divider()
                WorkbenchSavedRecordAccess(session: session, catalogues: ["experimentExclusions", "specimens"])
                Text("The saved-record catalogue shows the latest decision for each target, including restored inclusion. It is paged and is not the complete decision history. Earlier decision operations remain in Project storage and packages → Project history.").font(.caption).foregroundStyle(.secondary)
                DisclosureGroup("Loaded latest decisions") { WorkbenchStructuredOutput(value: state.exclusions["decisions"]).frame(minHeight: 120, maxHeight: 240) }
            }.padding(.top, 12).disabled(session.busy)
        }
    }
}
