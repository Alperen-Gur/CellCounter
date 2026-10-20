import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct WorkbenchPluginParameters: View {
    let definitions: [WorkbenchPluginParameter]
    @Binding var values: [String: WorkbenchJSON]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(definitions) { field in
                VStack(alignment: .leading, spacing: 4) {
                    if !field.required {
                        Toggle("Use \(field.title)", isOn: Binding(get: { values[field.id] != nil }, set: { enabled in
                            values[field.id] = enabled ? field.initialValue : nil
                        })).font(.caption)
                    } else { Text(field.title).font(.caption.weight(.medium)) }
                    if field.required || values[field.id] != nil { input(field) }
                    if let description = field.schema["description"].string {
                        Text(description).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    @ViewBuilder private func input(_ field: WorkbenchPluginParameter) -> some View {
        if !field.choices.isEmpty {
            Picker(field.title, selection: Binding(get: {
                field.choices.firstIndex(of: values[field.id] ?? field.initialValue) ?? 0
            }, set: { values[field.id] = field.choices[$0] })) {
                ForEach(field.choices.indices, id: \.self) { Text(label(field.choices[$0])).tag($0) }
            }.labelsHidden()
        } else if field.type == "boolean" {
            Toggle(field.title, isOn: Binding(get: { values[field.id]?.bool ?? false },
                set: { values[field.id] = .bool($0) })).toggleStyle(.checkbox)
        } else if field.type == "integer" {
            TextField(field.title, value: Binding(get: { values[field.id]?.integer ?? field.initialValue.integer ?? 0 },
                set: { values[field.id] = .number(Double($0)) }), format: .number).textFieldStyle(.roundedBorder)
        } else if field.type == "number" {
            TextField(field.title, value: Binding(get: { values[field.id]?.number ?? field.initialValue.number ?? 0 },
                set: { values[field.id] = .number($0) }), format: .number).textFieldStyle(.roundedBorder)
        } else {
            TextField(field.title, text: Binding(get: { values[field.id]?.string ?? "" },
                set: { values[field.id] = .string($0) })).textFieldStyle(.roundedBorder)
        }
    }
    private func label(_ value: WorkbenchJSON) -> String {
        value.string ?? value.number.map { String($0) } ?? value.bool.map { $0 ? "Yes" : "No" } ?? "—"
    }
}

struct WorkbenchPluginsView: View {
    @Bindable var session: WorkbenchSession
    @Bindable var extensions: WorkbenchExtensionState
    @Environment(\.dismiss) private var dismiss
    @State private var values: [String: WorkbenchJSON] = [:]
    private var selected: WorkbenchPlugin? { extensions.plugins.first { $0.id == extensions.selectedPluginID } }

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack {
                Text("Local analysis plugins").font(.title2)
                WorkbenchSavedRecordAccess(session: session, catalogues: ["plugins"])
                Spacer()
                Button("Install manifest…", action: install)
                Button("Refresh", action: session.loadExtensions)
                Button("Done") { dismiss() }
            }.disabled(session.busy)
            Text("Install versioned readers, segmentation, measurement and export methods for this project. Settings and outputs are retained with each run.")
                .font(.callout).foregroundStyle(.secondary)
            if let error = session.error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            HSplitView {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        Picker("Plugin", selection: $extensions.selectedPluginID) {
                            Text("Select a plugin").tag("")
                            ForEach(extensions.plugins) { Text("\($0.name) · v\($0.version)").tag($0.id) }
                        }
                        if let plugin = selected {
                            Text(plugin.summary).font(.callout).foregroundStyle(.secondary)
                            Text("\(plugin.kind.capitalized) · \(plugin.dimensions.map { "\($0)D" }.joined(separator: ", "))")
                                .font(.caption)
                            Text("Source SHA-256: \(plugin.sourceHash)").font(.caption.monospaced()).textSelection(.enabled)
                            if let error = plugin.error { Text(error).font(.caption).foregroundStyle(.red) }
                            if plugin.enabled {
                                Button("Disable plugin") { session.setPluginEnabled(plugin.id, enabled: false) }
                            } else {
                                Text("Enabling trusts this local Python code with your account. Review its source before enabling.")
                                    .font(.callout).foregroundStyle(.secondary)
                                Button("Trust and enable") { session.setPluginEnabled(plugin.id, enabled: true) }
                                    .disabled(!plugin.available)
                            }
                            Divider()
                            WorkbenchPluginParameters(definitions: plugin.parameters, values: $values)
                            Text(targetDescription(plugin)).font(.caption).foregroundStyle(.secondary)
                            Button(actionTitle(plugin)) {
                                if plugin.kind == "reader" { read(plugin) }
                                else if plugin.kind == "exporter" { export(plugin) }
                                else { session.runPlugin(plugin, parameters: values) }
                            }.buttonStyle(.borderedProminent)
                                .disabled(!plugin.enabled || !plugin.available ||
                                    (plugin.kind != "reader" && (session.selectedImageID == nil ||
                                        !plugin.dimensions.contains(session.viewingVolume ? 3 : 2))))
                        } else {
                            Text("Choose a local plugin manifest to add a method. Installation retains source without executing it.")
                                .foregroundStyle(.secondary)
                        }
                    }.padding(.trailing, 12)
                }.frame(minWidth: 300, idealWidth: 340).disabled(session.busy)
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("Run history").font(.headline)
                        Spacer()
                        Button("Load results") { session.loadPluginResults() }.disabled(session.busy)
                    }
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 10) {
                            ForEach(Array(extensions.runs.enumerated()), id: \.offset) { _, run in
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(run["pluginId"].string ?? "Plugin").font(.callout.weight(.medium))
                                    Text("\(run["target"].string == "volume" ? "3D volume" : "2D plane") · Revision \(run["revision"].integer ?? 0)")
                                        .font(.caption).foregroundStyle(.secondary)
                                    if run["stale"].bool == true {
                                        Text("Out of date after source, geometry or calibration changes.").font(.caption).foregroundStyle(.orange)
                                    }
                                    Button("Inspect output") { session.loadPluginResults(runID: run["runId"].string) }.disabled(session.busy)
                                }
                            }
                        }
                    }.frame(maxHeight: 150)
                    if let run = extensions.runOutput {
                        Text(run["stale"].bool == true ? "Historical output — out of date" : "Saved output").font(.headline)
                        if run["kind"].string == "measurement" {
                            WorkbenchPluginOutput(output: run["output"])
                        } else if run["kind"].string == "exporter" {
                            WorkbenchStructuredOutput(value: run["output"])
                        } else {
                            Text("\(run["output"]["cellCount"].integer ?? 0) objects saved. Inspect labels and canonical measurements in the image workspace.")
                                .font(.callout)
                        }
                    } else {
                        Text("Select a run to inspect its measurements and declared units.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }.frame(minWidth: 360).padding(.leading, 12)
            }
            HStack {
                if session.busy { ProgressView().controlSize(.small) }
                Text(session.status).font(.caption).foregroundStyle(.secondary)
                Spacer()
            }
        }.padding(24).frame(width: 920, height: 640)
        .task {
            values = selected?.initialParameters ?? [:]
            session.loadExtensions()
        }
        .onChange(of: extensions.selectedPluginID) { _, _ in values = selected?.initialParameters ?? [:] }
        .onChange(of: extensions.plugins.map(\.id)) { _, _ in values = selected?.initialParameters ?? [:] }
    }

    private func targetDescription(_ plugin: WorkbenchPlugin) -> String {
        if plugin.kind == "reader" {
            return "Choose one source file. The reader’s pixels and original acquisition are retained in this project."
        }
        let name = session.selectedImage?.name ?? "No image selected"
        if plugin.kind == "exporter" {
            return "\(name) · Export the selected source and available saved labels to a new destination."
        }
        if session.viewingVolume {
            return "\(name) · Time \(session.volume.timeIndex + 1), channel \(session.volume.channel + 1). " +
                (plugin.kind == "measurement" ? "Measures saved 3D labels." : "Replaces the saved labels for this volume.")
        }
        return name + (plugin.kind == "measurement" ? " · Measures saved masks with their saved channel and projection." :
            " · Replaces saved 2D labels using the current channel and projection.")
    }
    private func install() {
        let panel = NSOpenPanel()
        panel.title = "Choose a local plugin manifest"
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.begin { result in if result == .OK, let url = panel.url { session.installPlugin(at: url) } }
    }

    private func actionTitle(_ plugin: WorkbenchPlugin) -> String {
        switch plugin.kind {
        case "reader": return "Choose file and import…"
        case "exporter": return "Choose export destination…"
        case "segmentation": return "Run and save segmentation"
        default: return "Run measurements"
        }
    }

    private func read(_ plugin: WorkbenchPlugin) {
        let panel = NSOpenPanel()
        panel.title = "Choose an acquisition for \(plugin.name)"
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.begin { response in
            if response == .OK, let url = panel.url {
                session.readWithPlugin(plugin, source: url, parameters: values)
            }
        }
    }

    private func export(_ plugin: WorkbenchPlugin) {
        let panel = NSSavePanel()
        panel.title = "Choose a new destination for \(plugin.name)"
        panel.nameFieldStringValue = "\(session.selectedImage?.name ?? "Image").export"
        panel.begin { response in
            if response == .OK, let url = panel.url {
                session.exportWithPlugin(plugin, destination: url, parameters: values)
            }
        }
    }
}

private struct WorkbenchPluginOutput: View {
    let output: WorkbenchJSON
    private var columns: [String] { output["units"].object.keys.sorted() }
    var body: some View {
        ScrollView([.horizontal, .vertical]) {
            LazyVStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Object").frame(width: 65, alignment: .leading)
                    ForEach(columns, id: \.self) { key in
                        Text("\(key) (\(output["units"][key].string ?? ""))").frame(width: 130, alignment: .leading)
                    }
                }.fontWeight(.semibold)
                Divider()
                metricRow("Summary", values: output["summary"])
                ForEach(Array(output["measurements"].array.enumerated()), id: \.offset) { _, row in
                    metricRow(String(row["labelId"].integer ?? 0), values: row["values"])
                }
            }.font(.caption.monospacedDigit()).textSelection(.enabled)
        }
    }
    private func metricRow(_ label: String, values: WorkbenchJSON) -> some View {
        HStack {
            Text(label).frame(width: 65, alignment: .leading)
            ForEach(columns, id: \.self) { key in
                Text(values[key].number.map { String(format: "%.4g", $0) } ?? "—")
                    .frame(width: 130, alignment: .leading)
            }
        }
    }
}
