import SwiftUI

struct WorkbenchSavedRecordAccess: View {
    @Bindable var session: WorkbenchSession
    var catalogues: [String]
    @State private var showing = false
    var body: some View {
        Button("Browse saved records…") { showing = true }
            .help("Page through recent and older records without replacing editor drafts.")
            .disabled(!session.hasProject || session.busy)
            .sheet(isPresented: $showing) { WorkbenchCatalogueBrowser(session: session, catalogues: catalogues) }
    }
}

struct WorkbenchCatalogueBrowser: View {
    @Bindable var session: WorkbenchSession
    let catalogues: [String]
    @Environment(\.dismiss) private var dismiss
    private var state: WorkbenchCatalogueState { session.catalogues }
    private var choices: [String] { catalogues.isEmpty ? WorkbenchCatalogueState.titles.keys.sorted() : catalogues }
    private var versioned: Bool { ["workflows", "displayPresets", "statisticsDesigns", "experimentLayouts", "acquisitionSessions", "workspaces"].contains(state.catalogue) }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Text("Saved records").font(.title2); Spacer(); Button("Done") { dismiss() } }
            Text("Editor choices contain recent records and records you explicitly keep. Browse all retained pages here; loading a record does not overwrite a draft or start execution.").font(.callout).foregroundStyle(.secondary)
            HStack {
                Picker("Catalogue", selection: Binding(get: { state.catalogue }, set: { session.browseCatalogue($0) })) {
                    ForEach(choices, id: \.self) { Text(WorkbenchCatalogueState.titles[$0] ?? $0).tag($0) }
                }
                Button("Refresh page") { session.browseCatalogue(state.catalogue) }
            }.disabled(session.busy)
            if let error = session.error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            HStack {
                Button("Previous") { session.browseCatalogue(state.catalogue, direction: -1) }.disabled(state.pageIndex == 0)
                Text("Page \(state.pageIndex + 1) · \(state.entries.count) returned · \(state.total) retained").font(.caption.monospacedDigit())
                Button("Next") { session.browseCatalogue(state.catalogue, direction: 1) }.disabled(state.nextCursor == nil)
                Spacer()
            }.disabled(session.busy)
            if state.sourceRevision != nil && state.sourceRevision != session.revision {
                Text("This page belongs to an earlier project revision. Refresh it before keeping a record. Existing selections remain retained.").font(.caption).foregroundStyle(.orange)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(state.entries.enumerated()), id: \.offset) { _, entry in record(entry) }
                }
            }
            DisclosureGroup("Look up an exact retained record") {
                HStack {
                    TextField("Record ID", text: Binding(get: { state.exactID }, set: { state.exactID = $0 })).textFieldStyle(.roundedBorder)
                    if versioned {
                        Toggle("Exact version", isOn: Binding(get: { state.useExactVersion }, set: { state.useExactVersion = $0 }))
                        if state.useExactVersion { TextField("Version", value: Binding(get: { state.exactVersion }, set: { state.exactVersion = $0 }), format: .number).frame(width: 70) }
                    }
                    Button("Look up", action: session.lookupCatalogueRecord).disabled(state.exactID.isEmpty)
                }
                if let entry = state.exactEntry { record(entry, revision: state.exactRevision) }
            }.disabled(session.busy)
            DisclosureGroup("Records kept in editor choices (\(state.pinnedCount) of 40)") {
                ScrollView {
                    ForEach(state.pins.keys.sorted(), id: \.self) { key in
                        ForEach((state.pins[key] ?? []).sorted(), id: \.self) { id in
                            HStack {
                                Text("\(WorkbenchCatalogueState.titles[key] ?? key): \(state.rows[key]?.first { state.identity($0, catalogue: key) == id }.map(title) ?? id)").font(.caption)
                                Spacer(); Button("Release") { state.pins[key]?.remove(id) }.controlSize(.small)
                            }
                        }
                    }
                }.frame(maxHeight: 120)
                Text("Releasing removes a browser pin on the next refresh. Open editor selections remain protected independently.").font(.caption).foregroundStyle(.secondary)
            }
            Text(session.status).font(.caption).foregroundStyle(.secondary)
        }.padding(22).frame(width: 820, height: 680)
            .task { let key = choices.contains(state.catalogue) ? state.catalogue : choices.first ?? "workflows"; session.browseCatalogue(key) }
    }
    private func title(_ entry: WorkbenchJSON) -> String {
        entry["name"].string ?? entry["instanceName"].string ?? entry["label"].string ?? entry["manifest"]["name"].string ?? entry["assay"].string ?? entry["imageName"].string ?? entry["operation"].string ?? "Retained record"
    }
    private func record(_ entry: WorkbenchJSON, revision: Int? = nil) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title(entry)).font(.callout.weight(.medium))
                Text([entry["status"].string, entry["version"].integer.map { "Version \($0)" }, entry["createdAt"].string, entry["updatedAt"].string].compactMap { $0 }.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
                if entry["outputsCurrent"].bool == false || entry["inputsCurrent"].bool == false { Text("Historical inputs changed").font(.caption).foregroundStyle(.orange) }
                DisclosureGroup("Record details") { WorkbenchStructuredOutput(value: entry).frame(minHeight: 80, maxHeight: 180) }
            }
            Spacer()
            Button("Keep in editor choices") { session.keepCatalogueRecord(entry, key: state.catalogue) }
                .disabled(session.busy || (revision ?? state.sourceRevision) != session.revision)
        }.padding(8).background(.quaternary.opacity(0.25)).clipShape(RoundedRectangle(cornerRadius: 7))
    }
}
