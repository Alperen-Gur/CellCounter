import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct WorkbenchMigrationView: View {
    @Bindable var session: WorkbenchSession
    @Environment(\.dismiss) private var dismiss
    var onOpenProject: (() -> Void)?
    @State private var page = 0
    @State private var confirmCancel = false
    private var migration: WorkbenchMigrationState { session.migration }
    private var settled: Bool { session.canRefreshWithoutDiscardingEdits && !session.hasActiveWorkers }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Import native library").font(.title2)
                Spacer()
                Button("Done") { dismiss() }.disabled(session.busy)
            }
            Text("Copy acquisitions and preserve historical records in a new Workbench project. Your original library remains available.")
                .font(.callout).foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if migration.hasMigration { progressSection }
                    GroupBox("Capture or open an archive") {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                Text(URL(fileURLWithPath: migration.sourceDirectory).lastPathComponent.isEmpty ? "Choose a library folder" : URL(fileURLWithPath: migration.sourceDirectory).lastPathComponent)
                                Spacer()
                                Button("Choose library folder…", action: chooseSource)
                            }
                            Text(migration.selectedLegacyIDs.isEmpty ? "Scientific import scope: all archived images." : "Scientific import scope: \(migration.selectedLegacyIDs.count) selected images.")
                                .font(.callout)
                            Text("The archive retains all library records and referenced evidence, including records outside the selected image scope. Historical detections contain centres, diameters and optional contours; they are preserved without being converted into exact masks.")
                                .font(.caption).foregroundStyle(.secondary)
                            HStack {
                                Button("Capture and preview…", action: capture).disabled(migration.sourceDirectory.isEmpty)
                                Button("Open existing archive…", action: openArchive)
                            }
                            if !migration.archivePath.isEmpty {
                                DisclosureGroup("Archive location") { Text(migration.archivePath).font(.caption).textSelection(.enabled) }
                            }
                        }.padding(6)
                    }.disabled(!settled)
                    if migration.hasPlan { previewSection }
                    if !migration.mappings.isEmpty { historicalSection }
                    if migration.hasMigration { retainedRecordsSection }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            if let error = session.error { Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled) }
            HStack {
                if session.busy { ProgressView().controlSize(.small) }
                Text(session.status).font(.caption).foregroundStyle(.secondary)
                Spacer()
            }
        }
        .padding(22).frame(minWidth: 760, idealWidth: 850, minHeight: 630, idealHeight: 760)
        .interactiveDismissDisabled(session.busy)
        .onChange(of: migration.selectedLegacyID) { _, _ in migration.geometry = .null }
        .onChange(of: migration.selectedEntity) { _, _ in migration.recordsPage = .null }
        .confirmationDialog("Cancel the remaining migration checkpoints?", isPresented: $confirmCancel) {
            Button("Cancel remaining import", role: .destructive) { session.controlLibraryMigration("cancel") }
        } message: { Text("Completed checkpoints and the original library remain preserved. A cancelled migration cannot resume; a new import requires a new project.") }
    }

    private var progressSection: some View {
        GroupBox("Migration in this project") {
            VStack(alignment: .leading, spacing: 10) {
                let progress = migration.descriptor["progress"]
                HStack {
                    Text(migration.status.capitalized).font(.headline)
                    Spacer()
                    Text("\(progress["completed"].integer ?? 0) / \(progress["total"].integer ?? 0) checkpoints").monospacedDigit()
                }
                ProgressView(value: Double(progress["completed"].integer ?? 0), total: Double(max(1, progress["total"].integer ?? 1)))
                if let next = migration.descriptor["nextUnit"]["name"].string {
                    Text("Next: \(migration.descriptor["nextUnit"]["type"].string == "file" ? "retain evidence" : "import acquisition") · \(next)").font(.caption)
                }
                if let message = migration.descriptor["error"]["message"].string {
                    Text(message).foregroundStyle(.red)
                    Text("Restore the source bytes named in the error, then resume. Completed checkpoints are retained.").font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    Button("Run next") { session.advanceLibraryMigration(remaining: false) }.disabled(!settled || !migration.canAdvance)
                    Button("Run remaining") { session.advanceLibraryMigration(remaining: true) }.disabled(!settled || !migration.canAdvance)
                    if ["paused", "failed"].contains(migration.status) {
                        Button("Resume") { session.controlLibraryMigration("resume") }.disabled(!settled)
                    } else {
                        Button(migration.runningRemaining ? "Pause after checkpoint" : "Pause") { session.controlLibraryMigration("pause") }
                            .disabled(!migration.canAdvance || (session.busy && !migration.runningRemaining) || session.hasActiveWorkers)
                    }
                    if !["completed", "cancelled"].contains(migration.status) {
                        Button("Cancel remaining…") { confirmCancel = true }.disabled(session.busy && !migration.runningRemaining)
                    }
                }
                if migration.requestedAction != nil { Text("The current checkpoint will finish before the requested action.").font(.caption).foregroundStyle(.secondary) }
                if migration.status == "completed" {
                    Text(migration.descriptor["evidenceComplete"].bool == true ? "Available evidence retention complete." : "Migration checkpoints finished with missing evidence.")
                        .font(.callout)
                    Text(migration.descriptor["scientificImportComplete"].bool == true ? "All selected acquisitions imported." : "Some selected acquisitions remain missing or archived only.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if migration.status == "completed" || migration.status == "cancelled" {
                    Button("Open imported project") { onOpenProject?(); dismiss() }.disabled(session.busy)
                    Text("Missing or unsupported acquisitions remain explicitly archived. New segmentation can create canonical masks; historical files and measurements remain unchanged.").font(.caption).foregroundStyle(.secondary)
                }
            }.padding(6)
        }
    }

    private var previewSection: some View {
        GroupBox("Import preview") {
            VStack(alignment: .leading, spacing: 12) {
                let counts = migration.plan["counts"]
                Text("\(counts["importableImages"].integer ?? 0) importable · \(counts["archivedOnlyImages"].integer ?? 0) archived only · \(counts["missingImages"].integer ?? 0) missing sources").font(.headline)
                Text("\(counts["files"].integer ?? 0) evidence files · \(counts["missingFiles"].integer ?? 0) missing files · \(ByteCountFormatter.string(fromByteCount: Int64(migration.plan["totalBytes"].integer ?? 0), countStyle: .file)) retained")
                    .font(.caption).foregroundStyle(.secondary)
                let rows = migration.plan["images"].array
                ForEach(Array(rows.dropFirst(page * 25).prefix(25).enumerated()), id: \.offset) { _, row in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack { Text(row["name"].string ?? "Archived image"); Spacer(); Text(row["status"].string ?? "Unknown").foregroundStyle(.secondary) }
                        if let reason = row["reason"].string { Text(reason).font(.caption).foregroundStyle(.secondary) }
                    }
                }
                if rows.count > 25 {
                    HStack {
                        Button("Previous") { page = max(0, page - 1) }.disabled(page == 0)
                        Text("Page \(page + 1) of \(max(1, (rows.count + 24) / 25))").font(.caption)
                        Button("Next") { page += 1 }.disabled((page + 1) * 25 >= rows.count)
                    }
                }
                DisclosureGroup("Retention and interpretation") {
                    ForEach(Array(migration.plan["notes"].array.enumerated()), id: \.offset) { _, note in
                        Text(note.string ?? "").font(.caption).foregroundStyle(.secondary)
                    }
                }
                TextField("New project name", text: Bindable(migration).name).textFieldStyle(.roundedBorder)
                Button("Choose new project and begin…", action: chooseDestination).buttonStyle(.borderedProminent)
                    .disabled(!settled || migration.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Text("Beginning creates a resumable import plan. Run its checkpoints to retain files and import acquisitions.").font(.caption).foregroundStyle(.secondary)
            }.padding(6)
        }
    }

    private var historicalSection: some View {
        GroupBox("Historical geometry") {
            VStack(alignment: .leading, spacing: 10) {
                Text("Read original object centres, dimensions and contours independently of current masks. Original measurements use their recorded conventions and calibration.")
                    .font(.caption).foregroundStyle(.secondary)
                Picker("Archived image", selection: Bindable(migration).selectedLegacyID) {
                    Text("Choose an image").tag("")
                    ForEach(Array(migration.mappings.enumerated()), id: \.offset) { _, row in
                        Text(row["name"].string ?? "Archived image").tag(row["legacyImageId"].string ?? "")
                    }
                }
                HStack {
                    Button("Read historical geometry") { session.loadLegacyGeometry(imageID: migration.selectedLegacyID) }
                        .disabled(session.busy || migration.selectedLegacyID.isEmpty)
                    Spacer()
                    if let total = migration.geometry["total"].integer { Text("\(total) historical objects").font(.caption) }
                }
                if !migration.geometry["cells"].array.isEmpty {
                    Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 5) {
                        GridRow { Text("X (px)"); Text("Y (px)"); Text("Diameter (px)"); Text("Diameter (µm)"); Text("Contour points") }.font(.caption.bold())
                        ForEach(Array(migration.geometry["cells"].array.enumerated()), id: \.offset) { _, cell in
                            GridRow {
                                Text(number(cell["cx"])); Text(number(cell["cy"])); Text(number(cell["diameterPx"])); Text(number(cell["diameter"]))
                                Text("\(cell["contourFlat"].array.count / 2)")
                            }.font(.caption.monospacedDigit())
                        }
                    }
                }
                if migration.geometry["total"].integer != nil {
                    let offset = migration.geometry["offset"].integer ?? 0
                    HStack {
                        Button("Previous objects") { session.loadLegacyGeometry(imageID: migration.selectedLegacyID, offset: max(0, offset - 100)) }.disabled(session.busy || offset == 0)
                        Button("Next objects") {
                            if let next = migration.geometry["nextOffset"].integer { session.loadLegacyGeometry(imageID: migration.selectedLegacyID, offset: next) }
                        }.disabled(session.busy || migration.geometry["nextOffset"].integer == nil)
                    }
                }
                DisclosureGroup("Historical variant and provenance") {
                    TextField("Optional archived variant ID", text: Bindable(migration).variantID).textFieldStyle(.roundedBorder)
                    if let record = migration.geometry["recordId"].string { Text("Original record: \(record)").font(.caption).textSelection(.enabled) }
                    if let hash = migration.geometry["archiveHash"].string { Text("Archive SHA-256: \(hash)").font(.caption).textSelection(.enabled) }
                }
            }.padding(6)
        }
    }

    private var retainedRecordsSection: some View {
        DisclosureGroup("Retained records and evidence") {
            VStack(alignment: .leading, spacing: 12) {
                Text("Original settings, corrections, ROIs, conditions, model versions and unsupported records remain available without changing their meaning.").font(.caption).foregroundStyle(.secondary)
                let entities = migration.descriptor["entities"].array
                Picker("Record type", selection: Bindable(migration).selectedEntity) {
                    Text("Choose a type").tag("")
                    ForEach(Array(entities.enumerated()), id: \.offset) { _, entity in
                        Text("\(entity["name"].string ?? "Record") (\(entity["recordCount"].integer ?? 0))").tag(entity["name"].string ?? "")
                    }
                }
                Button("Read retained records") { session.loadMigrationRecords(entity: migration.selectedEntity) }
                    .disabled(session.busy || migration.selectedEntity.isEmpty)
                ForEach(Array(migration.recordsPage["records"].array.enumerated()), id: \.offset) { offset, record in
                    DisclosureGroup(record["name"].string ?? record["fileName"].string ?? record["label"].string ?? "Record \((migration.recordsPage["offset"].integer ?? 0) + offset + 1)") {
                        ForEach(record.object.keys.sorted(), id: \.self) { key in
                            LabeledContent(key, value: archiveField(record[key])).font(.caption).textSelection(.enabled)
                        }
                    }
                }
                if let total = migration.recordsPage["total"].integer {
                    Text("\(total) retained records").font(.caption)
                    HStack {
                        Button("Previous records") { session.loadMigrationRecords(entity: migration.selectedEntity, offset: max(0, (migration.recordsPage["offset"].integer ?? 0) - 25)) }
                            .disabled(session.busy || (migration.recordsPage["offset"].integer ?? 0) == 0)
                        Button("Next records") { if let next = migration.recordsPage["nextOffset"].integer { session.loadMigrationRecords(entity: migration.selectedEntity, offset: next) } }
                            .disabled(session.busy || migration.recordsPage["nextOffset"].integer == nil)
                    }
                }
                Divider()
                Button("Read file evidence") { session.loadMigrationEvidence() }.disabled(session.busy)
                ForEach(Array(migration.evidencePage["files"].array.enumerated()), id: \.offset) { _, file in
                    VStack(alignment: .leading, spacing: 3) {
                        Text("\(file["name"].string ?? "File") · \(file["role"].string ?? "Evidence") · \(file["status"].string == "missing" ? "Missing" : file["checkpointStatus"].string == "completed" ? "Retained" : "Pending")").font(.callout)
                        Text(file["originalPath"].string ?? "").font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                }
                if migration.evidencePage["total"].integer != nil {
                    HStack {
                        Button("Previous files") { session.loadMigrationEvidence(offset: max(0, (migration.evidencePage["offset"].integer ?? 0) - 50)) }
                            .disabled(session.busy || (migration.evidencePage["offset"].integer ?? 0) == 0)
                        Button("Next files") { if let next = migration.evidencePage["nextOffset"].integer { session.loadMigrationEvidence(offset: next) } }
                            .disabled(session.busy || migration.evidencePage["nextOffset"].integer == nil)
                    }
                }
            }.padding(.top, 8)
        }
    }
    private func archiveField(_ value: WorkbenchJSON) -> String {
        if value["encoding"].string == "base64" { return "Opaque data retained in archive (base64)" }
        if let date = value["iso8601"].string { return date }
        if let string = value.string { return String(string.prefix(800)) + (string.count > 800 ? "…" : "") }
        if let number = value.number { return number.formatted() }
        if let bool = value.bool { return bool ? "Yes" : "No" }
        if case .array(let items) = value { return "\(items.count) retained values" }
        if case .object(let fields) = value { return "\(fields.count) retained fields" }
        return "—"
    }

    private func number(_ value: WorkbenchJSON) -> String { value.number.map { $0.formatted(.number.precision(.fractionLength(0...3))) } ?? "—" }
    private func chooseSource() {
        let panel = NSOpenPanel(); panel.title = "Choose the native CellCounter library root"
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            migration.sourceDirectory = url.path; migration.selectedLegacyIDs = []; migration.clearPreview(); page = 0
        }
    }
    private func capture() {
        let panel = NSSavePanel(); panel.title = "Save a new read-only library archive"
        panel.allowedContentTypes = [.json]; panel.nameFieldStringValue = "CellCounter-library-archive.json"
        panel.begin { response in guard response == .OK, let url = panel.url else { return }; page = 0; session.captureLibraryArchive(to: url) }
    }
    private func openArchive() {
        let panel = NSOpenPanel(); panel.title = "Open a native or Windows library archive"
        panel.allowedContentTypes = [.json]; panel.allowsMultipleSelection = false
        panel.begin { response in guard response == .OK, let url = panel.url else { return }; page = 0; session.previewLibraryArchive(at: url) }
    }
    private func chooseDestination() {
        let panel = NSSavePanel(); panel.title = "Create a new migration project"; panel.prompt = "Begin import"
        panel.nameFieldStringValue = migration.name + ".ccproject"; panel.canCreateDirectories = true
        panel.begin { response in guard response == .OK, let url = panel.url else { return }; session.createLibraryMigration(at: url) }
    }
}
