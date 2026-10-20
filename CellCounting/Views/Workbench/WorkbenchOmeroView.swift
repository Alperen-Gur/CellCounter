import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct WorkbenchOmeroView: View {
    @Bindable var session: WorkbenchSession
    @Bindable var omero: WorkbenchOmeroState
    @Environment(\.dismiss) private var dismiss
    @State private var setupExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("OMERO sources").font(.title2)
                Spacer()
                Button("Refresh local configuration", action: session.loadOmeroConfiguration)
                Button("Done") { dismiss() }
            }.disabled(session.busy)
            Text("Browse a named server with read-only access. Preview one exact raw T/C/Z region, then import it into the current project with its origin and known calibration.")
                .font(.callout).foregroundStyle(.secondary)
            if let error = session.error { Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled) }
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    DisclosureGroup("Connection setup and isolated runtime", isExpanded: $setupExpanded) { setup.padding(.top, 10) }
                    browse
                    if omero.imageID != nil { region }
                }.padding(.trailing, 6)
            }.disabled(session.busy)
            HStack {
                if session.busy { ProgressView().controlSize(.small) }
                Text(session.status).font(.caption).foregroundStyle(.secondary)
                Spacer()
            }
        }
        .padding(22).frame(minWidth: 850, idealWidth: 980, maxWidth: 1120, minHeight: 650, idealHeight: 820)
        .interactiveDismissDisabled(session.busy)
        .onAppear { omero.editorOpen = true; setupExpanded = omero.profiles.isEmpty; session.loadOmeroConfiguration() }
        .onDisappear { omero.editorOpen = false }
    }

    private var setup: some View {
        VStack(alignment: .leading, spacing: 14) {
            GroupBox("Host-local connection registry") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(WorkbenchOmeroConfiguration.registryURL.path).font(.caption).textSelection(.enabled)
                        Spacer()
                        Button("Choose registry…", action: chooseRegistry)
                    }
                    Text("The registry stores server names and local credential references. Portable projects contain neither credentials nor interpreter choices. A different registry is an explicit local setting.")
                        .font(.caption).foregroundStyle(.secondary)
                }.padding(6)
            }
            GroupBox("Isolated OMERO interpreter") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        TextField("Absolute Python interpreter path", text: $omero.interpreterPath).textFieldStyle(.roundedBorder)
                        Button("Choose…") { chooseFile(title: "Choose the isolated OMERO Python interpreter") { omero.interpreterPath = $0.path; omero.candidate = .null } }
                    }
                    HStack {
                        Button("Read interpreter identity", action: session.inspectOmeroInterpreter).disabled(omero.interpreterPath.isEmpty)
                        Button("Bind isolated interpreter", action: session.bindOmeroInterpreter).disabled(!omero.candidateCurrent)
                        Button("Probe isolated runtime", action: session.probeOmeroRuntime)
                            .disabled(omero.runtime["pythonPath"].string == nil || omero.interpreterDirty)
                    }
                    if omero.candidateCurrent {
                        Text("Selected interpreter identified without execution. Binding records its exact file hash.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if omero.probe["ready"].bool == true {
                        Label("OMERO \(omero.probe["omeroVersion"].string ?? "") · Ice \(omero.probe["iceVersion"].string ?? "") · Python \(omero.probe["pythonVersion"].string ?? "")", systemImage: "checkmark.circle")
                            .font(.callout)
                    } else {
                        Text(omero.runtime["status"].string == "runtime-required" ? "Bind a preinstalled isolated interpreter." : "Compatibility has not been probed for the current binding.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Text("OMERO requires its own environment with requirements-omero.txt and a compatible Ice 3.6 platform wheel. The ordinary Workbench and detector environments remain separate. Probe compatibility runs the configured local interpreter without connecting to a server.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Reveal OMERO requirements") {
                        if let url = Bundle.main.resourceURL?.appendingPathComponent("python/requirements-omero.txt") {
                            NSWorkspace.shared.activateFileViewerSelecting([url])
                        }
                    }.controlSize(.small)
                }.padding(6)
            }
            GroupBox("Named profile") {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Menu("Edit existing profile") {
                            ForEach(omero.profiles, id: \.omeroID) { profile in
                                Button(profile["name"].string ?? "Profile") { omero.loadProfileDraft(profile) }
                            }
                        }.disabled(omero.profiles.isEmpty)
                        Button("New profile") { omero.loadProfileDraft(.null) }
                        Spacer()
                        if omero.configurationDirty { Text("Unsaved local settings").font(.caption).foregroundStyle(.orange) }
                    }
                    Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                        GridRow { Text("Profile ID"); TextField("Stable local identifier", text: $omero.profileID) }
                        GridRow { Text("Name"); TextField("Connection name", text: $omero.profileName) }
                        GridRow { Text("Host"); TextField("server.example.org", text: $omero.host) }
                        GridRow { Text("TLS port"); TextField("4064", value: $omero.port, format: .number).frame(maxWidth: 150, alignment: .leading) }
                        GridRow { Text("User name"); TextField("OMERO user name", text: $omero.username) }
                    }.textFieldStyle(.roundedBorder)
                    Picker("Credential reference", selection: $omero.credentialKind) {
                        Text("Private local file").tag("local-file")
                        Text("Environment variable").tag("environment")
                    }.pickerStyle(.segmented)
                    HStack {
                        TextField(omero.credentialKind == "environment" ? "Password environment-variable name" : "Absolute credential JSON path", text: $omero.credentialReference)
                            .textFieldStyle(.roundedBorder)
                        if omero.credentialKind == "local-file" {
                            Button("Choose file…") { chooseFile(title: "Choose a user-only OMERO credential file") { omero.credentialReference = $0.path } }
                        }
                    }
                    Text(omero.credentialKind == "environment"
                        ? "Use the name of a variable available to the application process. Do not enter the password here."
                        : "Select an existing JSON file containing a password field, owned by your user with mode 0600. Its contents are read only by the isolated connection worker.")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack {
                        TextField("Optional custom certificate authority PEM path", text: $omero.caPath).textFieldStyle(.roundedBorder)
                        Button("Choose CA…") { chooseFile(title: "Choose a certificate authority PEM file") { omero.caPath = $0.path } }
                        if !omero.caPath.isEmpty { Button("Use platform CAs") { omero.caPath = "" } }
                    }
                    Text("TLS certificate and host-name validation are required. Editing a profile requires choosing its credential reference again; secret references are not returned by the public catalogue.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Save local profile", action: session.saveOmeroProfile).buttonStyle(.borderedProminent).disabled(!omero.validProfile)
                }.padding(6)
            }
        }
    }

    private var browse: some View {
        GroupBox("Browse sources") {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Picker("Connection profile", selection: Binding(get: { omero.selectedProfileID }, set: session.selectOmeroProfile)) {
                        Text("Choose a profile").tag("")
                        ForEach(omero.profiles, id: \.omeroID) { Text($0["name"].string ?? "Profile").tag($0["id"].string ?? "") }
                    }
                    Button("Connect and list groups") { session.loadOmeroGroups() }
                        .disabled(omero.selectedProfileID.isEmpty || omero.runtime["pythonPath"].string == nil || omero.interpreterDirty)
                }
                if !omero.selectedProfileID.isEmpty {
                    Text("\(omero.selectedProfile["host"].string ?? "") · \(omero.selectedProfile["username"].string ?? "") · validated TLS")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if !omero.groups.isEmpty {
                    HStack {
                        Picker("Group", selection: Binding(get: { omero.groupID }, set: { value in
                            omero.groupID = value; omero.locations = []; omero.objects = []; omero.clearImage()
                        })) {
                            Text("Choose a group").tag(-1)
                            ForEach(omero.groups, id: \.omeroID) { Text($0["name"].string ?? "Group").tag($0["id"].integer ?? -1) }
                        }
                        Button("Previous groups") { session.loadOmeroGroups(offset: max(0, omero.groupOffset - 50)) }.disabled(omero.groupOffset == 0)
                        Button("More groups") { if let offset = omero.nextGroupOffset { session.loadOmeroGroups(offset: offset) } }.disabled(omero.nextGroupOffset == nil)
                    }
                    HStack {
                        Button("Projects") { session.browseOmero(kind: "project", name: "Projects") }
                        Button("Screens and plates") { session.browseOmero(kind: "screen", name: "Screens") }
                        Button("All images in group") { session.browseOmero(kind: "image", name: "Images") }
                    }.disabled(omero.groupID < 0)
                }
                if !omero.locations.isEmpty {
                    ScrollView(.horizontal) {
                        HStack {
                            ForEach(Array(omero.locations.enumerated()), id: \.offset) { index, location in
                                if index > 0 { Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary) }
                                Button(location.name) { session.browseOmero(kind: location.kind, parentID: location.parentID,
                                    parentKind: location.parentKind, name: location.name, backTo: index) }
                            }
                        }
                    }
                    VStack(spacing: 0) {
                        ForEach(omero.objects, id: \.omeroID) { object in
                            HStack {
                                Image(systemName: object["kind"].string == "image" ? "photo" : "folder")
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(object["name"].string ?? "Unnamed source")
                                    if let row = object["row"].integer, let column = object["column"].integer {
                                        Text("Well row \(row + 1), column \(column + 1)").font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                                Button(object["kind"].string == "image" ? "Select image" : "Open") { session.openOmeroObject(object) }
                            }.padding(.vertical, 6)
                            Divider()
                        }
                        if omero.objects.isEmpty { Text("No items in this page.").foregroundStyle(.secondary).padding(12) }
                    }
                    HStack {
                        Text("Page \(omero.objectOffset / 50 + 1) · up to 50 sources").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Previous") { pageObjects(max(0, omero.objectOffset - 50)) }.disabled(omero.objectOffset == 0)
                        Button("Next") { if let offset = omero.nextObjectOffset { pageObjects(offset) } }.disabled(omero.nextObjectOffset == nil)
                    }
                }
            }.padding(6)
        }
    }

    private var region: some View {
        GroupBox("Exact raw region") {
            VStack(alignment: .leading, spacing: 10) {
                Text(omero.image["name"].string ?? "Selected image").font(.headline)
                Text("\(omero.dimensions["x"].integer ?? 0) × \(omero.dimensions["y"].integer ?? 0) pixels · \(omero.dimensions["z"].integer ?? 0) Z · \(omero.dimensions["c"].integer ?? 0) channels · \(omero.dimensions["t"].integer ?? 0) time points · \(omero.image["dtype"].string ?? "")")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    selector("Time", value: $omero.timeIndex, count: omero.dimensions["t"].integer ?? 1)
                    selector("Channel", value: $omero.channel, count: omero.dimensions["c"].integer ?? 1)
                    selector("Z plane", value: $omero.zIndex, count: omero.dimensions["z"].integer ?? 1)
                }
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                    GridRow { Text("Left X (pixels)"); integerField("Left X", value: $omero.x); Text("Top Y (pixels)"); integerField("Top Y", value: $omero.y) }
                    GridRow { Text("Width (pixels)"); integerField("Width", value: $omero.width); Text("Height (pixels)"); integerField("Height", value: $omero.height) }
                }
                Text("XY coordinates are zero-based source pixel edges. Maximum 16 million pixels and 128 MiB of raw samples per import. T/C/Z controls are displayed one-based; the retained provenance stores exact zero-based indices.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("Preview raw region", action: session.previewOmeroRegion).disabled(!omero.validRegion)
                    TextField("Imported image name", text: $omero.importName).textFieldStyle(.roundedBorder)
                    Button("Import exact raw region", action: session.importOmeroRegion).buttonStyle(.borderedProminent)
                        .disabled(!session.hasProject || !omero.previewCurrent || session.hasActiveWorkers || !session.canRefreshWithoutDiscardingEdits)
                }
                if let preview = omero.preview {
                    if !omero.previewCurrent {
                        Text("Selection or local configuration changed. Refresh the preview before importing.").font(.caption).foregroundStyle(.orange)
                    }
                    Image(nsImage: preview).resizable().interpolation(.none).scaledToFit()
                        .frame(maxWidth: .infinity, maxHeight: 360).background(Color.black.opacity(0.04))
                        .accessibilityLabel("Bounded display preview of the selected raw OMERO region")
                    Text("Display normalization is only for this preview. Imported pixels retain raw dtype and values; the selected plane becomes local channel 1, time 1, Z 1. This import does not copy the whole series.")
                        .font(.caption).foregroundStyle(.secondary)
                    DisclosureGroup("Source selection and provenance") {
                        WorkbenchStructuredOutput(value: .object(omero.previewResult.object.filter { $0.key != "dataUrl" })).frame(height: 200)
                    }
                }
                ForEach(omero.image["notes"].array.compactMap(\.string), id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary) }
            }.padding(6)
        }
    }

    private func selector(_ label: String, value: Binding<Int>, count: Int) -> some View {
        Stepper("\(label) \(value.wrappedValue + 1) of \(max(1, count))", value: value, in: 0...max(0, count - 1))
            .accessibilityLabel(label)
    }
    private func integerField(_ label: String, value: Binding<Int>) -> some View {
        TextField(label, value: value, format: .number).textFieldStyle(.roundedBorder).frame(maxWidth: 180).accessibilityLabel(label)
    }
    private func pageObjects(_ offset: Int) {
        guard let location = omero.location else { return }
        session.browseOmero(kind: location.kind, parentID: location.parentID, parentKind: location.parentKind, name: location.name, offset: offset)
    }
    private func chooseFile(title: String, completion: @escaping (URL) -> Void) {
        let panel = NSOpenPanel(); panel.title = title; panel.canChooseFiles = true; panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.begin { response in if response == .OK, let url = panel.url { completion(url) } }
    }
    private func chooseRegistry() {
        let panel = NSSavePanel(); panel.title = "Choose a host-local OMERO registry"
        panel.message = "Choose a new registry filename or the existing registry you intend to use. This chooser does not overwrite its contents."
        panel.nameFieldStringValue = "omero-profiles.json"; panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true; panel.directoryURL = WorkbenchOmeroConfiguration.registryURL.deletingLastPathComponent()
        panel.begin { response in if response == .OK, let url = panel.url { session.chooseOmeroRegistry(url) } }
    }
}

private extension WorkbenchJSON {
    var omeroID: String { self["id"].string ?? self["id"].integer.map(String.init) ?? "" }
}
