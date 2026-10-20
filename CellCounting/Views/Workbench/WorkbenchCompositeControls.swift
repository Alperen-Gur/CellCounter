import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct WorkbenchCompositeControls: View {
    @Bindable var session: WorkbenchSession
    @Bindable var composite: WorkbenchCompositeState
    @State private var expanded = false

    private var image: WorkbenchImage? { session.selectedImage }
    private var units: String {
        if image?.intensityUnits == "processed-source" { return "Processed source intensity" }
        if image?.intensityUnits == "raw-source" { return "Raw source intensity" }
        let result = composite.rendered?["imageId"].string == image?.id ? composite.rendered : composite.volumeDescriptor
        guard result?["imageId"].string == image?.id else { return "Source intensity" }
        return result?["intensityUnits"].string == "processed-source" ? "Processed source intensity" : "Raw source intensity"
    }

    var body: some View {
        DisclosureGroup("Channel display", isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 10) {
                Text(session.viewingVolume
                    ? "Use these channel settings for a source slice or a 3D composite. Render each view when ready."
                    : "Combine channels for the selected projection.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("Display controls do not change segmentation channels or scientific measurements.")
                    .font(.caption).foregroundStyle(.secondary)
                WorkbenchDisplayPresetControls(session: session, composite: composite, presets: composite.presets)
                ForEach($composite.channels) { $channel in
                    channelControls($channel)
                }
                Button("Add display channel", systemImage: "plus") {
                    let used = Set(composite.channels.map(\.channel))
                    if let channel = (0..<(image?.channels ?? 1)).first(where: { !used.contains($0) }) {
                        composite.channels.append(WorkbenchCompositeChannel(channel: channel,
                            color: WorkbenchCompositeState.colors[channel % WorkbenchCompositeState.colors.count]))
                    }
                }.disabled(composite.channels.count >= min(8, image?.channels ?? 1))
                Text("Additive RGB display. Transparent pixels are outside acquired support.")
                    .font(.caption).foregroundStyle(.secondary)
                if session.viewingVolume { volumeControls }
                Divider()
                Toggle(session.viewingVolume ? "Show slice composite" : "Show projection composite", isOn: $composite.enabled)
                HStack {
                    Button(session.viewingVolume ? "Render slice composite" : "Render projection composite", action: session.previewComposite)
                        .buttonStyle(.borderedProminent)
                        .disabled(!composite.valid || (!session.viewingVolume && (image?.timeCount ?? 1) > 1))
                    Button(session.viewingVolume ? "Source slice" : "Source projection") { composite.enabled = false }
                }
                if !composite.valid {
                    Text("Choose distinct channels, enable at least one, and enter valid windows, gamma and opacity.")
                        .font(.caption).foregroundStyle(.orange)
                }
                if !session.viewingVolume, (image?.timeCount ?? 1) > 1 {
                    Text("Select Volume and time below to choose an explicit time point.")
                        .font(.caption).foregroundStyle(.secondary)
                } else if composite.enabled && !session.compositeLocationCurrent {
                    Text("The source selection changed. Render the selected slice or projection again to display its composite.")
                        .font(.caption).foregroundStyle(.secondary)
                } else if composite.hasDraftChanges && composite.preview != nil {
                    Text("Slice or projection display changes are pending. This canvas keeps its last rendered settings until the next render.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if session.compositeLocationCurrent, let result = composite.rendered {
                    DisclosureGroup(session.viewingVolume ? "Rendered slice details" : "Rendered projection details") {
                        VStack(alignment: .leading, spacing: 5) {
                            Text("\(result["previewWidth"].integer ?? 0) × \(result["previewHeight"].integer ?? 0) display pixels from \(result["width"].integer ?? 0) × \(result["height"].integer ?? 0) source pixels")
                                .font(.caption).foregroundStyle(.secondary)
                            channelDetails(result)
                            ForEach(composite.notes, id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary) }
                        }.padding(.top, 5)
                    }
                    DisclosureGroup(session.viewingVolume ? "Export rendered slice" : "Export rendered projection") {
                        VStack(alignment: .leading, spacing: 7) {
                            Text(composite.exportFormats.first?.description ??
                                "Export a bounded PNG display with its channel settings and source provenance.")
                                .font(.caption).foregroundStyle(.secondary)
                            if session.viewingVolume {
                                Text("This PNG contains the selected source slice composite. The 3D camera view is not included.")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Button(session.viewingVolume ? "Export slice composite PNG…" : "Export projection composite PNG…", action: chooseExport)
                                .disabled(!session.canExportComposite)
                            if !session.canExportComposite {
                                Text("Render current display settings and finish pending analysis edits before exporting. Stop active workers first.")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            if let path = composite.exportResult?["destination"].string {
                                Button("Show export in Finder") {
                                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                                }
                            }
                        }.padding(.top, 5)
                    }
                }
            }.padding(.top, 7)
        }
        .task { composite.configure(for: image) }
        .onChange(of: image?.id) { _, _ in composite.configure(for: image) }
        .onChange(of: composite.channelArguments) { _, _ in composite.invalidateEditedPresetReference() }
        .onChange(of: composite.maximumSize) { _, _ in composite.invalidateEditedPresetReference() }
        .onChange(of: composite.volumeMaximumDimension) { _, _ in composite.invalidateEditedPresetReference() }
    }

    private var volumeControls: some View {
        VStack(alignment: .leading, spacing: 7) {
            Divider()
            Toggle("Show 3D composite", isOn: $composite.volumeEnabled)
            Picker("3D preview resolution", selection: $composite.volumeMaximumDimension) {
                if ![64, 96, 128].contains(composite.volumeMaximumDimension) {
                    Text("Up to \(composite.volumeMaximumDimension) voxels per axis").tag(composite.volumeMaximumDimension)
                }
                Text("Up to 64 voxels per axis").tag(64)
                Text("Up to 96 voxels per axis").tag(96)
                Text("Up to 128 voxels per axis").tag(128)
            }
            HStack {
                Button("Render 3D composite", action: session.renderVolumeComposite)
                    .buttonStyle(.borderedProminent)
                    .disabled(!composite.valid || session.volume.isPreview || session.volume.parametersChanged ||
                              session.volume.imageID != image?.id)
                Button("Analysis volume") { composite.volumeEnabled = false }
            }
            Text("Automatic windows use the complete selected volume, so they may differ from slice windows. Measurements and saved labels use analysis channel \(session.volume.channel + 1).")
                .font(.caption).foregroundStyle(.secondary)
            if session.volume.isPreview || session.volume.parametersChanged {
                Text("Run or restore the analysis settings before rendering a composite with saved labels.")
                    .font(.caption).foregroundStyle(.secondary)
            } else if composite.volumeEnabled && !session.volumeCompositeCurrent {
                Text("Render the current time point again. The image, project revision or saved analysis labels changed.")
                    .font(.caption).foregroundStyle(.secondary)
            } else if session.volumeCompositeCurrent && composite.volumeHasDraftChanges {
                Text("3D display changes are pending. The volume keeps its last rendered channel settings until Render 3D composite.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if session.volumeCompositeCurrent, let result = composite.volumeDescriptor {
                DisclosureGroup("Rendered 3D details") {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("\(dimensions(result["dimensions"])) display voxels from \(dimensions(result["originalDimensions"])) source voxels")
                            .font(.caption).foregroundStyle(.secondary)
                        Text("Time \((result["timeIndex"].integer ?? 0) + 1) · \(result["labelStatus"].string == "current" ? "Saved labels from analysis channel \(session.volume.channel + 1)" : "No saved analysis labels")")
                            .font(.caption).foregroundStyle(.secondary)
                        channelDetails(result)
                        ForEach(result["notes"].array.compactMap(\.string), id: \.self) {
                            Text($0).font(.caption).foregroundStyle(.secondary)
                        }
                    }.padding(.top, 5)
                }
            }
        }
    }

    private func channelDetails(_ result: WorkbenchJSON) -> some View {
        ForEach(Array(result["channels"].array.enumerated()), id: \.offset) { _, channel in
            if channel["enabled"].bool != false {
                Text("Channel \((channel["channel"].integer ?? 0) + 1) · \(channel["windowMode"].string ?? "auto") window · \(formatted(channel["lower"].number)) to \(formatted(channel["upper"].number))")
                    .font(.caption).foregroundStyle(.secondary)
                if channel["constantRange"].bool == true {
                    Text("This channel has a constant intensity range; its automatic display is black.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func dimensions(_ value: WorkbenchJSON) -> String {
        value.array.compactMap(\.integer).map(String.init).joined(separator: " × ")
    }

    private func channelControls(_ channel: Binding<WorkbenchCompositeChannel>) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Toggle("Channel \(channel.wrappedValue.channel + 1)", isOn: channel.enabled).font(.callout)
                Spacer()
                ColorPicker("Channel \(channel.wrappedValue.channel + 1) color",
                    selection: colorBinding(channel.color), supportsOpacity: false)
                    .labelsHidden().accessibilityLabel("Channel \(channel.wrappedValue.channel + 1) display color")
                Button {
                    composite.channels.removeAll { $0.id == channel.wrappedValue.id }
                } label: { Image(systemName: "minus.circle") }
                    .disabled(composite.channels.count <= 1)
                    .accessibilityLabel("Remove display channel \(channel.wrappedValue.channel + 1)")
            }
            DisclosureGroup("Color and intensity window") {
                VStack(alignment: .leading, spacing: 7) {
                    Picker("Source channel", selection: channel.channel) {
                        ForEach(0..<(image?.channels ?? 1), id: \.self) { Text("Channel \($0 + 1)").tag($0) }
                    }
                    TextField("Color (#RRGGBB)", text: channel.color)
                        .textFieldStyle(.roundedBorder).accessibilityLabel("Display color hexadecimal value")
                    Text("\(units) window").font(.caption)
                    HStack {
                        TextField("Lower · auto", text: channel.lower).accessibilityLabel("Lower intensity bound; blank for automatic")
                        TextField("Upper · auto", text: channel.upper).accessibilityLabel("Upper intensity bound; blank for automatic")
                    }.textFieldStyle(.roundedBorder)
                    Text("Leave both bounds blank for automatic min/max. Otherwise, lower must be less than upper.")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Text("Gamma").font(.caption)
                        TextField("Gamma", value: channel.gamma, format: .number).textFieldStyle(.roundedBorder)
                    }
                    Text("Gamma above 1 brightens the display. Range: 0.05–20.")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Text("Opacity").font(.caption)
                        Slider(value: channel.opacity, in: 0...1)
                            .accessibilityLabel("Channel \(channel.wrappedValue.channel + 1) opacity")
                        Text(channel.wrappedValue.opacity, format: .percent.precision(.fractionLength(0)))
                            .font(.caption.monospacedDigit()).frame(width: 38)
                    }
                }.padding(.top, 5)
            }
        }.padding(9).background(.quaternary.opacity(0.25)).clipShape(RoundedRectangle(cornerRadius: 7))
    }

    private func colorBinding(_ hex: Binding<String>) -> Binding<Color> {
        Binding(get: {
            let value = UInt32(hex.wrappedValue.dropFirst(), radix: 16) ?? 0xFFFFFF
            return Color(red: Double((value >> 16) & 255) / 255,
                         green: Double((value >> 8) & 255) / 255, blue: Double(value & 255) / 255)
        }, set: { color in
            guard let rgb = NSColor(color).usingColorSpace(.deviceRGB) else { return }
            let components = [rgb.redComponent, rgb.greenComponent, rgb.blueComponent].map {
                min(255, max(0, Int(($0 * 255).rounded())))
            }
            hex.wrappedValue = String(format: "#%02X%02X%02X", components[0], components[1], components[2])
        })
    }
    private func formatted(_ value: Double?) -> String {
        value.map { $0.formatted(.number.precision(.significantDigits(1...6))) } ?? "—"
    }
    private func chooseExport() {
        guard session.canExportComposite else { return }
        let panel = NSSavePanel()
        panel.title = session.viewingVolume ? "Export rendered slice composite" : "Export rendered projection composite"
        panel.allowedContentTypes = [.png]
        panel.message = "Save the last rendered source slice or projection to a new PNG. Scientific pixels and measurements remain unchanged."
        panel.canCreateDirectories = true
        let stem = (image?.name ?? "Image").replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        panel.nameFieldStringValue = "\(stem)-composite.png"
        panel.begin { result in
            guard result == .OK, let url = panel.url else { return }
            session.exportComposite(to: url)
        }
    }
}
