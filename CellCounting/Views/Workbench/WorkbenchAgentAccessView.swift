import AppKit
import SwiftUI

/// Connection settings refer to the installed app, never private staged paths.
struct WorkbenchAgentAccessView: View {
    @Bindable var session: WorkbenchSession
    @Environment(\.dismiss) private var dismiss
    @State private var allowWrite = false
    @State private var allowPlugins = false
    @State private var toolMode = "compact"
    @State private var allowedPaths: [String] = []
    @State private var allowedOmeroProfiles: Set<String> = []
    @State private var allowOmeroConfiguration = false
    @State private var showingOmero = false
    @State private var feedback = ""
    @StateObject private var installer = CellposeInstaller(workbenchOnly: true)
    @State private var checkingReadiness = false
    @State private var readiness: WorkbenchRuntimeReadiness.Result?
    @State private var resourceReport: WorkbenchJSON = .null
    private var canRepair: Bool {
        !installer.isRunning && !checkingReadiness && !session.busy &&
        !session.hasActiveWorkers && !session.models.hasActiveTraining &&
        !TrainingService.isTrainingActive && session.canRefreshWithoutDiscardingEdits
    }
    private var command: String { Bundle.main.executableURL?.path ?? "" }
    private var arguments: [String] {
        var result = ["--workbench", "--omero-profiles", WorkbenchOmeroConfiguration.registryURL.path,
                      "mcp", "--project", session.projectPath, "--tool-mode", toolMode]
        if allowWrite { result.append("--allow-write") }
        if allowWrite && allowPlugins { result.append("--allow-plugins") }
        for path in allowedPaths { result += ["--allow-path", path] }
        for profile in allowedOmeroProfiles.sorted() { result += ["--allow-omero-profile", profile] }
        if allowWrite && allowOmeroConfiguration { result.append("--allow-omero-configuration") }
        return result
    }
    private var configuration: String {
        let object: [String: Any] = ["mcpServers": ["CellCounter": ["command": command, "args": arguments]]]
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]),
              let string = String(data: data, encoding: .utf8) else { return "" }
        return string
    }

    var body: some View {
        ScrollView {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("AI agent and command-line access").font(.title2)
                Spacer()
                Button("Done") { dismiss() }.disabled(installer.isRunning)
            }
            Text("Connect an MCP client to this project using the installed CellCounter application. GUI, CLI and agent operations use the same project revisions, masks and saved history.")
                .font(.callout).foregroundStyle(.secondary)
            if session.hasProject {
                LabeledContent("Project", value: session.projectName).font(.headline)
                Text(session.projectPath).font(.caption).textSelection(.enabled)
            } else {
                Text("Install the runtime here, then create or open a project to copy its scoped connection settings.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            GroupBox("Local runtime") {
                VStack(alignment: .leading, spacing: 8) {
                    if checkingReadiness { ProgressView("Checking Python and MCP…").controlSize(.small) }
                    else if let readiness {
                        Label(readiness.summary, systemImage: readiness.ready ? "checkmark.circle" : "exclamationmark.circle")
                            .font(.callout).textSelection(.enabled)
                    } else { Text("Readiness has not been checked.").font(.callout) }
                    HStack {
                        Button("Check readiness") { checkReadiness() }.disabled(checkingReadiness || installer.isRunning)
                        Button("Install or repair") {
                            guard canRepair, !ChildProcessTracker.shared.hasRunningProcesses else {
                                feedback = "Wait for active analysis, installation or other Python operations to finish before repairing the runtime."
                                return
                            }
                            readiness = nil
                            installer.start()
                        }.disabled(!canRepair)
                        if installer.isRunning { Button("Cancel installation") { installer.cancel() } }
                    }
                    Text("The standard installer creates a dedicated Workbench environment with pinned analysis and MCP dependencies using Python 3.11 or later. Close active agent connections before repair; pause background jobs and training first. Existing projects and model checkpoints are preserved.")
                        .font(.caption).foregroundStyle(.secondary)
                    if installer.isRunning { ProgressView(installer.progressHint).controlSize(.small) }
                    if let error = installer.error { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
                    if !installer.output.isEmpty {
                        DisclosureGroup("Installation details") {
                            ScrollView { Text(installer.output.suffix(80).joined(separator: "\n"))
                                .font(.caption.monospaced()).textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading) }.frame(maxHeight: 120)
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(6)
            }
            GroupBox("Access for this connection") {
                VStack(alignment: .leading, spacing: 10) {
                    Picker("Agent tool catalogue", selection: $toolMode) {
                        Text("Compact discovery and operations").tag("compact")
                        Text("One tool per operation").tag("operations")
                    }
                    Text("Compact mode provides discovery plus shared read/change tools. Both modes enforce the same project, file and executable permissions.")
                        .font(.caption).foregroundStyle(.secondary)
                    Toggle("Allow project changes and exports", isOn: $allowWrite)
                    Text("Off: inspect data and preview permitted operations. On: corrections, analysis and other project mutations require the current expected revision.")
                        .font(.caption).foregroundStyle(.secondary)
                    Toggle("Allow trusted executable plugins and model operations", isOn: $allowPlugins).disabled(!allowWrite)
                    Text("Executable access is a separate grant. It permits operations that run explicitly configured local code; it does not approve arbitrary model or plugin downloads.")
                        .font(.caption).foregroundStyle(.secondary)
                    Divider()
                    HStack { Text("Additional import and export paths").font(.callout); Spacer(); Button("Add path…", action: choosePath) }
                    ForEach(allowedPaths, id: \.self) { path in
                        HStack {
                            Text(path).font(.caption).lineLimit(2).textSelection(.enabled)
                            Spacer()
                            Button("Remove") { allowedPaths.removeAll { $0 == path } }.controlSize(.small)
                        }
                    }
                    Text("The connection is scoped to this project. Add only the files or folders the agent should read or write outside it.")
                        .font(.caption).foregroundStyle(.secondary)
                    DisclosureGroup("OMERO server and setup grants") {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Button("Load local profile names", action: session.loadOmeroConfiguration).disabled(session.busy)
                                Button("Connection setup…") { showingOmero = true }.disabled(session.busy)
                            }
                            ForEach(session.omero.profiles, id: \.agentProfileID) { profile in
                                let id = profile["id"].string ?? ""
                                Toggle("Allow read-only server access: \(profile["name"].string ?? id)", isOn: Binding(
                                    get: { allowedOmeroProfiles.contains(id) },
                                    set: { if $0 { allowedOmeroProfiles.insert(id) } else { allowedOmeroProfiles.remove(id) } }))
                            }
                            Text("Server access is limited to the named profiles you select. Importing a previewed raw region additionally requires project-write permission. Passwords and credential references are not placed in this MCP configuration.")
                                .font(.caption).foregroundStyle(.secondary)
                            Toggle("Allow host-local OMERO setup changes", isOn: $allowOmeroConfiguration).disabled(!allowWrite)
                            if allowWrite && allowOmeroConfiguration {
                                Button("Grant the selected registry directory") {
                                    let path = WorkbenchOmeroConfiguration.registryURL.deletingLastPathComponent().path
                                    if !allowedPaths.contains(path) { allowedPaths.append(path) }
                                }
                                Text("Setup also requires explicit path grants for the chosen interpreter, credential file and custom CA file. Probing the isolated runtime requires executable access. Existing saved profiles can be used without granting setup changes.")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }.padding(.top, 6)
                    }
                }.padding(6)
            }
            DisclosureGroup("Current view session and host capacity") {
                VStack(alignment: .leading, spacing: 8) {
                    if let id = session.sharedSession.id {
                        Text("This native view: \(id)").font(.caption.monospaced()).textSelection(.enabled)
                        Button("Copy view session ID") { copy(id, message: "Native view session ID copied.") }
                        Text("Agents can read this session and make an explicit navigation request. Current drafts defer navigation; ordinary analysis does not move the view.")
                            .font(.caption).foregroundStyle(.secondary)
                    } else { Text("Open a project to register this native view session.").font(.caption).foregroundStyle(.secondary) }
                    Button("Read host capacity") {
                        session.perform("Reading host capacity…") {
                            resourceReport = try await session.call("resource.report")["result"]
                        }
                    }.disabled(session.busy || installer.isRunning)
                    if resourceReport != .null {
                        Text("Python \(resourceReport["python"]["version"].string ?? "Unknown") · \(resourceReport["platform"]["system"].string ?? "") \(resourceReport["platform"]["machine"].string ?? "")")
                            .font(.caption)
                        Text("Logical CPUs: \(resourceReport["cpu"]["logicalCount"].integer.map(String.init) ?? "Unknown") · Physical memory: \(resourceReport["memory"]["physicalBytes"].integer.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .memory) } ?? "Unknown")")
                            .font(.caption)
                        ForEach(resourceReport["notes"].array.compactMap(\.string), id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary) }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            DisclosureGroup("MCP configuration") {
                ScrollView { Text(configuration).font(.system(.caption, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                    .frame(maxHeight: 190)
            }
            HStack {
                Button("Copy MCP configuration") { copy(configuration, message: "MCP configuration copied. Paste it into your MCP client's server settings.") }
                    .buttonStyle(.borderedProminent)
                Button("Copy CLI inspect command") {
                    let args = [command, "--workbench", "--project", session.projectPath, "call", "project.snapshot"]
                    copy(args.map(shellQuote).joined(separator: " "), message: "Canonical project inspection command copied.")
                }
            }.disabled(command.isEmpty || !session.hasProject)
            Text("MCP uses standard input/output. The installed app command opens no GUI and does not install dependencies automatically.")
                .font(.caption).foregroundStyle(.secondary)
            if !feedback.isEmpty { Text(feedback).font(.callout).foregroundStyle(.secondary) }
        }
        .padding(22)
        }.frame(width: 720).frame(idealHeight: 780, maxHeight: 860)
        .interactiveDismissDisabled(installer.isRunning)
        .sheet(isPresented: $showingOmero) { WorkbenchOmeroView(session: session, omero: session.omero) }
        .task { checkReadiness() }
        .onChange(of: installer.done) { _, done in if done { checkReadiness() } }
        .onChange(of: allowWrite) { _, enabled in if !enabled { allowPlugins = false; allowOmeroConfiguration = false } }
        .onChange(of: session.projectPath) { _, _ in feedback = "Project changed. Copy the updated configuration before reconnecting." }
    }
    private func checkReadiness() {
        guard !checkingReadiness, !installer.isRunning else { return }
        checkingReadiness = true
        Task {
            readiness = await WorkbenchRuntimeReadiness.check()
            checkingReadiness = false
        }
    }
    private func choosePath() {
        let panel = NSOpenPanel(); panel.title = "Grant access to an additional file or folder"
        panel.canChooseDirectories = true; panel.canChooseFiles = true; panel.allowsMultipleSelection = true
        panel.begin { response in
            guard response == .OK else { return }
            for url in panel.urls where !allowedPaths.contains(url.path) { allowedPaths.append(url.path) }
            feedback = ""
        }
    }
    private func copy(_ text: String, message: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        feedback = message
    }
    private func shellQuote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
}

private extension WorkbenchJSON {
    var agentProfileID: String { self["id"].string ?? "" }
}
