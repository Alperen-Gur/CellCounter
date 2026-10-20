import SwiftUI

struct WorkbenchModelEnvironmentControls: View {
    @Bindable var session: WorkbenchSession
    @Bindable var models: WorkbenchModelState
    let model: WorkbenchRegisteredModel
    @State private var query = ""
    @State private var packagePage = 0
    private let pageSize = 50

    private var response: WorkbenchJSON? { models.environmentRecords[model.id] }
    private var record: WorkbenchJSON { response?["environment"] ?? .null }
    private var records: [WorkbenchJSON] { response?["environments"].array ?? [] }
    private var filteredPackages: [WorkbenchJSON] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let values = record["inventory"]["packages"].array
        return term.isEmpty ? values : values.filter {
            ($0["name"].string ?? "").localizedCaseInsensitiveContains(term) ||
                ($0["version"].string ?? "").localizedCaseInsensitiveContains(term)
        }
    }
    private var status: String {
        switch model.environmentStatus {
        case "captured": return "Recorded"
        case "binding-changed": return "Interpreter binding changed"
        default: return "Not recorded"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Model environment").font(.headline)
                Spacer()
                Text(status).font(.caption).foregroundStyle(model.environmentStatus == "binding-changed" ? Color.orange : Color.secondary)
            }
            HStack {
                Button("Capture environment") { session.captureModelEnvironment(model.id) }
                    .disabled(!model.enabled || session.hasActiveWorkers || models.hasActiveTraining ||
                              !session.canRefreshWithoutDiscardingEdits)
                Button("Inspect saved records") { session.loadModelEnvironment(model.id) }
            }
            Text("Capture runs the registered interpreter and saves its observed Python, platform and package inventory. Probe compatibility remains a separate availability check.")
                .font(.caption).foregroundStyle(.secondary)
            if !model.enabled {
                Text("Enable this trusted registered model before capturing its interpreter environment.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if session.hasActiveWorkers || models.hasActiveTraining || !session.canRefreshWithoutDiscardingEdits {
                Text("Finish pending analysis edits and active batch or training work before capturing an environment.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if model.environmentStatus == "binding-changed" {
                Text("Rebinding Python cleared the active environment. Historical records remain available; capture the new binding explicitly.")
                    .font(.caption).foregroundStyle(.orange)
            }
            if let activeID = model.activeEnvironmentID {
                if let active = records.first(where: { $0["id"].string == activeID }) {
                    summary(active["summary"], title: "Active recorded binding")
                } else {
                    Text("An active environment record is saved. Inspect saved records to read its package and platform summary.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Text("Recorded status describes the last explicit capture. Execution compares inventory hashes; package metadata does not capture binary contents or GPU drivers.")
                .font(.caption).foregroundStyle(.secondary)
            DisclosureGroup("Environment history and packages (\(model.environmentCount))") {
                VStack(alignment: .leading, spacing: 8) {
                    if model.environmentCount == 0 {
                        Text("No saved environment records. Capture the registered environment to create one.")
                            .font(.caption).foregroundStyle(.secondary)
                    } else if records.isEmpty {
                        Button("Load environment history") { session.loadModelEnvironment(model.id) }
                    } else {
                        if records.count < model.environmentCount {
                            Button("Load complete environment history") { session.loadModelEnvironment(model.id) }
                        }
                        Picker("Saved record", selection: Binding(get: { record["id"].string ?? "" }, set: {
                            session.loadModelEnvironment(model.id, environmentID: $0)
                        })) {
                            ForEach(Array(records.enumerated()), id: \.offset) { _, item in
                                Text(recordTitle(item)).tag(item["id"].string ?? "")
                            }
                        }
                    }
                    if record["id"].string != nil {
                        summary(record["summary"], title: record["id"].string == model.activeEnvironmentID
                                ? "Selected active record" : "Selected historical record")
                        Text("Captured \(record["capturedAt"].string ?? "—") · Project revision \(record["capturedRevision"].integer.map(String.init) ?? "—")")
                            .font(.caption).foregroundStyle(.secondary)
                        DisclosureGroup("Binding and inventory identity") {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(record["pythonPath"].string ?? "").font(.caption).textSelection(.enabled)
                                Text("Interpreter SHA-256: \(record["pythonHash"].string ?? "—")")
                                    .font(.caption.monospaced()).textSelection(.enabled)
                                Text("Inventory SHA-256: \(record["hash"].string ?? "—")")
                                    .font(.caption.monospaced()).textSelection(.enabled)
                                Text("Python cache tag: \(record["inventory"]["python"]["cacheTag"].string ?? "—")")
                                    .font(.caption).foregroundStyle(.secondary)
                                Text("Byte order: \(record["inventory"]["platform"]["byteOrder"].string ?? "—")")
                                    .font(.caption).foregroundStyle(.secondary)
                            }.padding(.top, 5)
                        }
                        TextField("Search recorded packages or versions", text: $query)
                            .textFieldStyle(.roundedBorder)
                        let matches = filteredPackages
                        let page = min(packagePage, max(0, (matches.count - 1) / pageSize))
                        let offset = page * pageSize
                        if matches.isEmpty {
                            Text("No matching recorded packages.").font(.caption).foregroundStyle(.secondary)
                        } else {
                            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 5) {
                                GridRow {
                                    Text("Package").font(.caption.weight(.semibold))
                                    Text("Version").font(.caption.weight(.semibold))
                                }
                                ForEach(Array(matches.dropFirst(offset).prefix(pageSize).enumerated()), id: \.offset) { _, package in
                                    GridRow {
                                        Text(package["name"].string ?? "—")
                                        Text(package["version"].string ?? "—")
                                    }.font(.caption).textSelection(.enabled)
                                }
                            }.frame(maxWidth: .infinity, alignment: .leading)
                            HStack {
                                Button("Previous packages") { packagePage = max(0, page - 1) }.disabled(page == 0)
                                Text("\(offset + 1)–\(min(offset + pageSize, matches.count)) of \(matches.count)")
                                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                Button("Next packages") { packagePage = page + 1 }.disabled(offset + pageSize >= matches.count)
                            }
                        }
                    }
                }.padding(.top, 6)
            }
        }
        .onChange(of: model.id) { _, _ in query = ""; packagePage = 0 }
        .onChange(of: record["id"].string) { _, _ in packagePage = 0 }
        .onChange(of: query) { _, _ in packagePage = 0 }
    }

    private func summary(_ value: WorkbenchJSON, title: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption.weight(.semibold))
            Text("\(value["implementation"].string ?? "Python") \(value["pythonVersion"].string ?? "—") · \(value["system"].string ?? "—") \(value["machine"].string ?? "")")
                .font(.caption).foregroundStyle(.secondary)
            Text("\(value["packageCount"].integer ?? 0) recorded packages").font(.caption).foregroundStyle(.secondary)
        }
    }
    private func recordTitle(_ value: WorkbenchJSON) -> String {
        let date = String((value["capturedAt"].string ?? "Recorded environment").prefix(19)).replacingOccurrences(of: "T", with: " ")
        return "\(date) · Python \(value["summary"]["pythonVersion"].string ?? "—")\(value["id"].string == model.activeEnvironmentID ? " · Active" : "")"
    }
}
