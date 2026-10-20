import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct WorkbenchPackageView: View {
    @Bindable var session: WorkbenchSession
    @Environment(\.dismiss) private var dismiss
    @State private var packageURL: URL?
    @State private var restorationDestination: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Project storage and packages").font(.title2)
                Spacer()
                Button("Done") { dismiss() }.disabled(session.busy)
            }
            Text("Verify a package, then reopen its sources, labels, workflows and history in a new project.")
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                Button("Choose ZIP package…", action: choosePackage).disabled(session.busy)
                Text(packageURL?.lastPathComponent ?? "No package selected").font(.callout)
            }
            if let error = session.error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            ScrollView {
            VStack(alignment: .leading, spacing: 16) {
            if session.hasProject { storageSection }
            restoreSection
            if packageURL != nil, let inspection = session.packageInspection {
                    VStack(alignment: .leading, spacing: 12) {
                        let package = inspection["package"]
                        Text(package["name"].string ?? "Microscopy project").font(.headline)
                        Text("\(package["imageCount"].integer ?? 0) images · Source revision \(package["sourceRevision"].integer ?? 0)")
                        if let frames = package["volumeFrameCount"].integer { Text("\(frames) analyzed volumes").font(.caption) }
                        if package["format"].integer == 2 {
                            Text("Metadata snapshot verified · \(package["shardCount"].integer ?? 0) artifact shards · \(package["artifactCount"].integer ?? 0) retained artifacts")
                                .font(.caption).foregroundStyle(.secondary)
                            Text("Artifact bytes are verified one checkpoint at a time during restore. Metadata inspection does not claim that those bytes have already been verified.")
                                .font(.caption).foregroundStyle(.secondary)
                        } else {
                            Text("\(inspection["integrity"]["fileCount"].integer ?? 0) files verified · \(ByteCountFormatter.string(fromByteCount: Int64(package["uncompressedBytes"].integer ?? 0), countStyle: .file)) expanded")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Divider()
                        Text("Dependencies").font(.headline)
                        let dependencies = inspection["dependencies"]
                        ForEach(Array(dependencies["warnings"].array.enumerated()), id: \.offset) { _, warning in
                            Text(warning.string ?? warning["message"].string ?? "A dependency needs attention.")
                                .font(.callout).foregroundStyle(.orange)
                        }
                        dependencyRows(dependencies["runtime"], title: "Runtime")
                        dependencyRows(dependencies["plugins"], title: "Plugins")
                        Text("Restored plugins remain disabled until explicitly enabled. Missing dependencies can prevent rerunning an analysis.")
                            .font(.caption).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                Button("Choose new destination and restore…", action: chooseDestination)
                    .buttonStyle(.borderedProminent).disabled(session.busy || !session.canRefreshWithoutDiscardingEdits || session.hasActiveWorkers)
            } else {
                Spacer()
            }
            }
            }
            HStack {
                if session.busy { ProgressView().controlSize(.small) }
                Text(session.status).font(.caption).foregroundStyle(.secondary)
                Spacer()
            }
        }.padding(24).frame(width: 790, height: 720)
        .onChange(of: session.projectPath) { _, path in
            if path == restorationDestination?.path, !path.isEmpty, session.packages.status != "completed" { dismiss() }
        }
    }

    private var storageSection: some View {
        DisclosureGroup("Current project storage and history") {
            VStack(alignment: .leading, spacing: 9) {
                Text("Storage format \(session.projectStorage["format"].integer ?? 1) · \(session.imageCount) images · \(session.projectStorage["historyCount"].integer ?? 0) history events")
                    .font(.caption)
                if session.projectStorage["format"].integer == 1 {
                    Button("Preview indexed storage migration", action: session.previewStorageUpgrade)
                        .disabled(session.busy || !session.canRefreshWithoutDiscardingEdits || session.hasActiveWorkers)
                    if let preview = session.packages.upgradePreview {
                        let plan = preview["plan"]
                        Text("Migrate \(plan["imageCount"].integer ?? 0) acquisitions and \(plan["measurementRows"].integer ?? 0) object measurements; preserve \(plan["historyCount"].integer ?? 0) history records.")
                            .font(.callout)
                        ForEach(Array(plan["notes"].array.enumerated()), id: \.offset) { _, note in
                            Text(note.string ?? "").font(.caption).foregroundStyle(.secondary)
                        }
                        Button("Preserve original store and enable indexed storage", action: session.applyStorageUpgrade)
                            .disabled(session.busy || session.packages.upgradeRevision != session.revision || session.hasActiveWorkers || !session.canRefreshWithoutDiscardingEdits)
                    }
                } else {
                    Text("Images, history and object measurements are read in revision-bound pages. Scientific source artifacts remain unchanged.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                DisclosureGroup("Scientific history") {
                    HStack {
                        Button("Refresh history") { session.loadProjectHistory() }
                        Button("Previous") { session.loadProjectHistory(direction: -1) }.disabled(session.packages.historyPage == 0)
                        Button("Next") { session.loadProjectHistory(direction: 1) }.disabled(session.packages.historyCursor == nil)
                        Text("Page \(session.packages.historyPage + 1) · \(session.packages.historyTotal) events").font(.caption)
                    }.disabled(session.busy)
                    ForEach(Array(session.packages.history.enumerated()), id: \.offset) { _, event in
                        Text("r\(event["revision"].integer ?? 0) · \(event["operation"].string ?? "Operation") · \(event["actor"]["name"].string ?? "Client") · \(event["at"].string ?? "")")
                            .font(.caption).textSelection(.enabled)
                    }
                }
            }.padding(.top, 8)
        }
    }

    private var restoreSection: some View {
        GroupBox("Resumable package restore") {
            VStack(alignment: .leading, spacing: 9) {
                HStack {
                    Button("Reopen partial restore…", action: reopenRestore).disabled(session.busy || !session.canRefreshWithoutDiscardingEdits)
                    if !session.packages.destination.isEmpty {
                        Button("Load last restore") { session.reopenPackageRestore(at: session.packages.destination) }
                            .disabled(session.busy || !session.canRefreshWithoutDiscardingEdits)
                    }
                }
                if session.packages.restore != .null {
                    let value = session.packages.restore
                    Text("\(value["name"].string ?? "Restored project") · \(session.packages.status)").font(.headline)
                    let completed = value["progress"]["completed"].integer ?? 0
                    let total = value["progress"]["total"].integer ?? 0
                    ProgressView(value: Double(completed), total: Double(max(1, total)))
                    Text("\(completed) / \(total) verified checkpoints · \(value["imageCount"].integer ?? 0) acquisitions")
                        .font(.caption)
                    HStack {
                        if session.packages.canAdvance {
                            Button("Run next") { session.advancePackageRestore(remaining: false) }.disabled(session.busy)
                            Button("Run remaining") { session.advancePackageRestore(remaining: true) }.disabled(session.busy)
                            if session.packages.runningRemaining {
                                Button("Stop after checkpoint") { session.controlPackageRestore("stop") }
                            }
                            Button("Cancel restore") { session.controlPackageRestore("cancel") }
                                .disabled(session.busy && !session.packages.runningRemaining)
                        } else if session.packages.status == "cancelled" {
                            Button("Resume retained restore") { session.controlPackageRestore("resume") }.disabled(session.busy)
                        } else if session.packages.status == "completed" {
                            Button("Open completed project", action: session.openCompletedPackageRestore)
                                .disabled(session.busy || !session.canRefreshWithoutDiscardingEdits)
                        }
                    }
                    Text("Stopping or cancelling preserves verified bytes and the restore journal. Reopening does not execute models, plugins or jobs.")
                        .font(.caption).foregroundStyle(.secondary)
                    DisclosureGroup("Destination and restore details") {
                        Text(session.packages.destination).font(.caption).textSelection(.enabled)
                        ForEach(Array(value["notes"].array.enumerated()), id: \.offset) { _, note in Text(note.string ?? "").font(.caption) }
                    }
                }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(5)
        }
    }

    private func reopenRestore() {
        let panel = NSOpenPanel(); panel.title = "Choose a retained partial restore folder"
        panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.allowsMultipleSelection = false
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            session.reopenPackageRestore(at: url.path)
        }
    }

    @ViewBuilder private func dependencyRows(_ value: WorkbenchJSON, title: String) -> some View {
        if !value.array.isEmpty {
            ForEach(Array(value.array.enumerated()), id: \.offset) { _, dependency in
                Text("\(dependency["name"].string ?? dependency["id"].string ?? title): \(dependency["status"].string ?? "Review required")")
                    .font(.callout)
            }
        } else if let status = value["status"].string ?? value.string {
            Text("\(title): \(status)").font(.callout)
        }
    }

    private func choosePackage() {
        let panel = NSOpenPanel()
        panel.title = "Choose an analysis package"
        panel.allowedContentTypes = [.zip]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            packageURL = url
            restorationDestination = nil
            session.inspectPackage(at: url)
        }
    }

    private func chooseDestination() {
        guard let packageURL, let package = session.packageInspection?["package"] else { return }
        let name = package["name"].string ?? packageURL.deletingPathExtension().lastPathComponent
        let panel = NSSavePanel()
        panel.title = "Restore into a new project folder"
        panel.prompt = "Restore"
        panel.nameFieldStringValue = "\(name)-restored.ccproject"
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            restorationDestination = url
            session.restorePackage(from: packageURL, to: url, name: url.deletingPathExtension().lastPathComponent)
        }
    }
}
