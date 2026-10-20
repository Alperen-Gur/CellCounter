import AppKit
import SwiftUI

struct WorkbenchLibraryView: View {
    @Bindable var session: WorkbenchSession
    @Bindable var library: WorkbenchLibraryState
    @Environment(\.dismiss) private var dismiss
    @State private var collectionSelection = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Project library").font(.title2)
                WorkbenchSavedRecordAccess(session: session, catalogues: ["collections"])
                Spacer()
                Button("Done") { dismiss() }.disabled(session.busy || library.dirty)
            }
            if let error = session.error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            HSplitView {
                VStack(alignment: .leading, spacing: 8) {
                    WorkbenchImageSelection(session: session, selection: $library.selectedIDs, title: "Library images")
                    HStack {
                        Button("Edit metadata") { if let id = library.selectedIDs.first { session.editLibraryImage(id) } }
                            .disabled(library.selectedIDs.count != 1 || library.dirty)
                        Button("Archive") { session.archiveLibrarySelection(true) }
                        Button("Restore") { session.archiveLibrarySelection(false) }
                    }.disabled(session.busy || session.hasActiveWorkers || library.selectedIDs.isEmpty)
                    HStack {
                        Text("\(library.selectedIDs.count) images selected across pages").font(.caption).foregroundStyle(.secondary)
                        Button("Clear selection") { library.selectedIDs = [] }.disabled(session.busy)
                    }
                    Text("Archive changes visibility only. Source bytes, masks, assignments and history remain retained.")
                        .font(.caption).foregroundStyle(.secondary)
                }.frame(minWidth: 380)
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        if library.metadata != .null {
                            Text("Acquisition metadata").font(.headline)
                            TextField("Name", text: $library.name)
                            TextField("Notes", text: $library.notes, axis: .vertical).lineLimit(3...8)
                            TextField("Tags, comma-separated", text: $library.tags)
                            ForEach(library.channelNames.indices, id: \.self) { index in
                                TextField("Channel \(index + 1)", text: $library.channelNames[index])
                            }
                            HStack {
                                Button("Save metadata", action: session.saveLibraryMetadata).disabled(session.hasActiveWorkers)
                                Button("Discard metadata draft") { library.applyMetadata(library.metadata) }
                            }
                            DisclosureGroup("Restore a missing or corrupt original") {
                                Text("Only a file with the exact original content hash can repair this acquisition. Different pixels must be imported as a new image.").font(.caption).foregroundStyle(.secondary)
                                Button("Choose original file…", action: chooseRepair)
                                if let preview = library.repairPreview {
                                    Text("Retained source: \(preview["currentArtifactStatus"].string ?? "unknown") · identity \(preview["identityMatches"].bool == true ? "matches" : "differs")").font(.caption)
                                    Button("Restore exact source", action: session.applyLibraryRepair)
                                        .disabled(preview["identityMatches"].bool != true || library.repairRevision != session.revision || library.dirty || session.hasActiveWorkers)
                                }
                            }
                        }
                        Divider()
                        Text("Collections").font(.headline)
                        Picker("Saved collection", selection: $collectionSelection) {
                            Text("New collection").tag("")
                            ForEach(Array(library.collections.enumerated()), id: \.offset) { _, item in
                                Text((item["name"].string ?? "Collection") + (item["archived"].bool == true ? " · Archived" : "")).tag(item["id"].string ?? "")
                            }
                        }
                        Button("Load selected collection") {
                            library.editCollection(library.collections.first { $0["id"].string == collectionSelection } ?? .null)
                        }.disabled(library.dirty)
                        TextField("Collection name", text: $library.collectionName)
                        TextField("Description", text: $library.collectionDescription, axis: .vertical)
                        Text("\(library.collectionMembers.count) members").font(.caption)
                        HStack {
                            Button("Add selected images") { library.collectionMembers.formUnion(library.selectedIDs) }
                            Button("Remove selected images") { library.collectionMembers.subtract(library.selectedIDs) }
                        }.disabled(library.selectedIDs.isEmpty)
                        HStack {
                            Button("Save as new") { session.saveLibraryCollection(asNew: true) }
                            Button("Save collection") { session.saveLibraryCollection(asNew: false) }.disabled(library.collectionID.isEmpty)
                        }.disabled(session.hasActiveWorkers || library.collectionName.isEmpty)
                        HStack {
                            Button("Archive collection") { session.archiveLibraryCollection(true) }
                            Button("Restore collection") { session.archiveLibraryCollection(false) }
                        }.disabled(library.collectionID.isEmpty || library.dirty || session.hasActiveWorkers)
                        Button("Discard collection draft") {
                            library.editCollection(library.collections.first { $0["id"].string == library.collectionID } ?? .null)
                        }
                        Text("Collections organize images. Use Experiments and specimens to define biological replicates.")
                            .font(.caption).foregroundStyle(.secondary)
                        DisclosureGroup("Exact duplicate sources") {
                            Button("Find duplicates", action: session.findLibraryDuplicates)
                            ForEach(Array(library.duplicateGroups.enumerated()), id: \.offset) { _, group in
                                Text(group["names"].array.compactMap(\.string).joined(separator: " · ")).font(.caption)
                            }
                            Text("This reports identical retained source bytes without merging independent analyses or assignments.").font(.caption).foregroundStyle(.secondary)
                        }
                    }.padding(.leading, 12).textFieldStyle(.roundedBorder).disabled(session.busy)
                }.frame(minWidth: 400)
            }
            Text(session.status).font(.caption).foregroundStyle(.secondary)
        }.padding(22).frame(width: 1020, height: 760)
        .task {
            library.editorOpen = true
            if library.originalCollection == nil { library.editCollection(.null) }
            if !library.dirty { session.searchLibrary() }
        }
        .onDisappear { library.editorOpen = false }
        .interactiveDismissDisabled(library.dirty || session.busy)
    }
    private func chooseRepair() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.title = "Choose exact original acquisition"
        panel.begin { response in if response == .OK, let path = panel.url?.path { session.previewLibraryRepair(path) } }
    }
}
