import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct WorkbenchDisplayPresetControls: View {
    @Bindable var session: WorkbenchSession
    @Bindable var composite: WorkbenchCompositeState
    @Bindable var presets: WorkbenchDisplayPresetState

    private var image: WorkbenchImage? { session.selectedImage }
    private var canSave: Bool {
        composite.valid && !session.hasActiveWorkers && session.canRefreshWithoutDiscardingEdits &&
            !presets.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            presets.notes.count <= 4000 && ["raw-source", "processed-source"].contains(image?.intensityUnits ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Picker("Display preset", selection: Binding(get: { presets.selectedID }, set: {
                    session.selectDisplayPreset($0)
                })) {
                    Text("Current display draft").tag("")
                    ForEach(presets.visibleRecords) { preset in
                        Text("\(preset.name)\(preset.archived ? " · archived" : "")").tag(preset.id)
                    }
                }
                Button(action: session.reloadDisplayPresets) { Image(systemName: "arrow.clockwise") }
                    .help("Refresh display presets").accessibilityLabel("Refresh display presets")
            }
            if let preset = presets.selected {
                HStack {
                    Text("Version \(preset.version) · \(preset.intensityUnits == "processed-source" ? "Processed source intensity" : "Raw source intensity")")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Apply settings", action: session.applyDisplayPreset)
                        .disabled(!presets.mappingValid(channelCount: image?.channels ?? 1))
                }
                if !presets.mappingValid(channelCount: image?.channels ?? 1) {
                    Text("Review Target channel mapping in Preset details before applying this preset.")
                        .font(.caption).foregroundStyle(.orange)
                }
            }
            Text("Apply settings updates this image’s display draft. Render the slice or volume when ready.")
                .font(.caption).foregroundStyle(.secondary)
            DisclosureGroup("Preset details and versions") {
                VStack(alignment: .leading, spacing: 8) {
                    WorkbenchSavedRecordAccess(session: session, catalogues: ["displayPresets"])
                    Toggle("Show archived presets", isOn: $presets.includeArchived)
                    if let preset = presets.selected {
                        Picker("Saved version", selection: Binding(get: { preset.version }, set: {
                            session.selectDisplayPreset(preset.id, version: $0)
                        })) {
                            ForEach(1...max(1, presets.latest?.latestVersion ?? preset.latestVersion), id: \.self) {
                                Text("Version \($0)").tag($0)
                            }
                        }
                        Text("Every version retains its channel settings. Selecting a version does not apply it.")
                            .font(.caption).foregroundStyle(.secondary)
                        if !preset.notes.isEmpty {
                            Text(preset.notes).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                        Text("Target channel mapping").font(.caption.weight(.semibold))
                        ForEach(Array(preset.channels.enumerated()), id: \.offset) { _, value in
                            if let source = value["channel"].integer {
                                Picker("Preset channel \(source + 1)", selection: Binding(
                                    get: { presets.mapping[source] ?? -1 },
                                    set: { presets.mapping[source] = $0; presets.message = ""; presets.warnings = [] }
                                )) {
                                    Text("Choose a target channel").tag(-1)
                                    ForEach(0..<(image?.channels ?? 1), id: \.self) {
                                        Text("Image channel \($0 + 1)").tag($0)
                                    }
                                }
                            }
                        }
                        Text("Channel numbers are matched by index initially. Confirm their meaning for this image; every preset channel needs a distinct target.")
                            .font(.caption).foregroundStyle(.secondary)
                        if !presets.mappingValid(channelCount: image?.channels ?? 1) {
                            Text("Choose an available, distinct target for every channel before applying.")
                                .font(.caption).foregroundStyle(.orange)
                        }
                        Button(presets.isArchived ? "Restore preset" : "Archive preset") {
                            session.archiveDisplayPreset(!presets.isArchived)
                        }.disabled(session.hasActiveWorkers || !session.canRefreshWithoutDiscardingEdits)
                        Text("Archiving hides the preset from the default list and preserves all versions.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Divider()
                    TextField("Preset name", text: $presets.name).textFieldStyle(.roundedBorder)
                    TextField("Preset notes", text: $presets.notes, axis: .vertical)
                        .textFieldStyle(.roundedBorder).lineLimit(2...4)
                    Stepper("Slice/projection limit: \(composite.maximumSize) pixels", value: $composite.maximumSize,
                            in: 64...2048, step: 64).font(.caption)
                    Text("Save uses the channel draft above, its source intensity units and the slice/3D preview bounds. Image selection and camera are not stored.")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Button("Save as new") { session.saveDisplayPreset(asNew: true) }.disabled(!canSave)
                        Button("Save version") { session.saveDisplayPreset(asNew: false) }
                            .disabled(!canSave || presets.selected == nil || presets.isArchived)
                    }
                    if presets.isArchived {
                        Text("Restore this preset before saving another version, or save the draft as a new preset.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if !session.canRefreshWithoutDiscardingEdits || session.hasActiveWorkers {
                        Text("Finish pending analysis edits and stop active workers before saving or archiving presets.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Divider()
                    HStack {
                        Button("Import preset JSON…", action: chooseImport)
                        Button("Export selected version…", action: chooseExport)
                            .disabled(presets.selected == nil || session.hasActiveWorkers || !session.canRefreshWithoutDiscardingEdits)
                    }
                    if let preview = presets.importPreview {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(preview["source"]["name"].string ?? "Preset file").font(.caption.weight(.semibold))
                            Text("\(preview["preset"]["channels"].array.count) channels · \(preview["preset"]["intensityUnits"].string == "processed-source" ? "Processed source intensity" : "Raw source intensity")")
                                .font(.caption).foregroundStyle(.secondary)
                            TextField("Imported preset name", text: $presets.importName).textFieldStyle(.roundedBorder)
                            ForEach(preview["notes"].array.compactMap(\.string), id: \.self) {
                                Text($0).font(.caption).foregroundStyle(.secondary)
                            }
                            Text("Import creates a new local preset. The current display draft and renders stay in place.")
                                .font(.caption).foregroundStyle(.secondary)
                            HStack {
                                Button("Import as new preset", action: session.importDisplayPreset)
                                    .disabled(presets.importRevision != session.revision || session.hasActiveWorkers ||
                                              !session.canRefreshWithoutDiscardingEdits)
                                Button("Dismiss preview") {
                                    presets.importPreview = nil; presets.importPath = ""; presets.importRevision = nil
                                }
                            }
                            if presets.importRevision != session.revision {
                                Button("Preview file again") {
                                    session.previewDisplayPresetImport(at: URL(fileURLWithPath: presets.importPath))
                                }
                                Text("The project changed after this preview. Preview the file again before importing.")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }.padding(8).background(.quaternary.opacity(0.25)).clipShape(RoundedRectangle(cornerRadius: 7))
                    }
                    if let path = presets.exportResult?["destination"].string {
                        Button("Show preset export in Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                        }
                    }
                }.padding(.top, 5)
            }
            if let reference = composite.activePresetReference {
                Text("Display draft: \(reference["name"].string ?? "Preset") · version \(reference["version"].integer ?? 1)")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !presets.message.isEmpty {
                Text(presets.message).font(.caption).foregroundStyle(.secondary)
            }
            ForEach(presets.warnings, id: \.self) {
                Text($0).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func chooseImport() {
        let panel = NSOpenPanel()
        panel.title = "Import display preset"
        panel.message = "Choose a CellCounter display preset JSON file to preview."
        panel.allowedContentTypes = [.json]
        panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.begin { result in
            guard result == .OK, let url = panel.url else { return }
            session.previewDisplayPresetImport(at: url)
        }
    }

    private func chooseExport() {
        guard let preset = presets.selected else { return }
        let panel = NSSavePanel()
        panel.title = "Export display preset version \(preset.version)"
        panel.message = "Save this immutable preset version to a new JSON file. Image pixels and camera settings are not included."
        panel.allowedContentTypes = [.json]; panel.canCreateDirectories = true
        let name = preset.name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        panel.nameFieldStringValue = "\(name)-v\(preset.version).json"
        panel.begin { result in
            guard result == .OK, let url = panel.url else { return }
            session.exportDisplayPreset(to: url)
        }
    }
}
