import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct WorkbenchImageExportView: View {
    @Bindable var session: WorkbenchSession
    @Bindable var exports: WorkbenchImageExportState
    @Environment(\.dismiss) private var dismiss

    private var image: WorkbenchImage? { session.images.first { $0.id == exports.imageID } }
    private var hasAnalysis: Bool {
        if exports.target == "plane" { return image?.cellCount != nil }
        return session.volume.imageID == exports.imageID && session.volume.inspection["frames"].array.contains {
            $0["timeIndex"].integer == exports.timeIndex && $0["channel"].integer == exports.channel
        }
    }
    private var canExport: Bool {
        guard image != nil, let format = exports.selectedFormat else { return false }
        return !session.busy && !session.hasActiveWorkers && (!format.requiresAnalysis || hasAnalysis)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Export image data").font(.title2)
                WorkbenchSavedRecordAccess(session: session, catalogues: ["imageExports"])
                Spacer()
                Button("Done") { dismiss() }.disabled(session.busy)
            }
            if let image {
                Text(image.name).font(.headline).lineLimit(2)
                if exports.target == "volume" {
                    Text("Full volume · Time \(exports.timeIndex + 1) · Channel \(exports.channel + 1) · All \(image.zCount) Z planes")
                        .font(.callout).foregroundStyle(.secondary)
                } else {
                    Text("2D plane or projection · First time point")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            if let error = session.error {
                Text(error).foregroundStyle(.red).textSelection(.enabled)
            }
            Picker("Format", selection: $exports.selectedFormatID) {
                ForEach(exports.availableFormats) { format in Text(format.name).tag(format.id) }
            }.disabled(session.busy)
            if let format = exports.selectedFormat {
                Text(format.description).font(.callout)
                selectionDescription(format)
                if format.requiresAnalysis && !hasAnalysis {
                    Text("Save an analysis for this selection before exporting labels, measurements or an overlay.")
                        .font(.callout).foregroundStyle(.orange)
                }
                if format.id == "overlay-png" {
                    Stepper("Maximum overlay dimension: \(exports.maximumOverlaySize) pixels",
                            value: $exports.maximumOverlaySize, in: 64...2048, step: 64)
                    Text("The overlay is a display image. Use label OME-TIFF for exact object identities and CSV for measurements.")
                        .font(.caption).foregroundStyle(.secondary)
                } else if format.id == "support-ome-tiff" {
                    Text("Support identifies measured samples. Filled pixels outside registered or processed support are excluded.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text("Save to a new file. Each export records the selected data, project revision and file hash.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if session.hasActiveWorkers {
                Text("Stop the background workflow at a checkpoint before exporting its saved results.")
                    .font(.callout).foregroundStyle(.orange)
            }
            if let result = exports.result, let path = result["destination"].string {
                Divider()
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(URL(fileURLWithPath: path).lastPathComponent).font(.headline)
                        Text(ByteCountFormatter.string(fromByteCount: Int64(result["bytes"].integer ?? 0),
                                                       countStyle: .file))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                    }
                }
                DisclosureGroup("Export provenance") {
                    VStack(alignment: .leading, spacing: 8) {
                        if let hash = result["sha256"].string {
                            Text("SHA-256: \(hash)").font(.caption.monospaced()).textSelection(.enabled)
                        }
                        WorkbenchStructuredOutput(value: result["provenance"]).frame(height: 150)
                    }.padding(.top, 6)
                }
            }
            Spacer(minLength: 0)
            HStack {
                if session.busy { ProgressView().controlSize(.small) }
                Text(session.status).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                Spacer()
                Button("Choose destination…", action: chooseDestination)
                    .buttonStyle(.borderedProminent).disabled(!canExport)
            }
        }.padding(24).frame(width: 630, height: 520)
        .task { session.loadImageExports() }
    }

    @ViewBuilder
    private func selectionDescription(_ format: WorkbenchImageExportFormat) -> some View {
        if exports.target == "plane" {
            let saved = format.requiresAnalysis
            let selectedChannel = saved ? (image?.parameters?["channel"].integer ?? 0) : exports.channel
            let selectedProjection = saved ? (image?.parameters?["zProjection"].string ?? "max") : exports.projection
            Text("\(saved ? "Saved analysis" : "Active source selection") · Channel \(selectedChannel + 1) · \(projectionName(selectedProjection))")
                .font(.caption).foregroundStyle(.secondary)
            if saved && (session.isPreview || session.parametersChanged) {
                Text("The current preview and unsaved parameter changes are excluded; this export uses the saved analysis.")
                    .font(.caption).foregroundStyle(.orange)
            }
        } else if format.requiresAnalysis && (session.volume.isPreview || session.volume.parametersChanged) {
            Text("This export uses the saved volume analysis for the displayed time and channel.")
                .font(.caption).foregroundStyle(.orange)
        }
    }

    private func projectionName(_ value: String) -> String {
        switch value {
        case "mean": "Mean Z projection"
        case "middle": "Middle Z plane"
        default: "Maximum Z projection"
        }
    }

    private func chooseDestination() {
        guard canExport, let format = exports.selectedFormat, let image else { return }
        let arguments = exports.arguments
        let panel = NSSavePanel()
        panel.title = "Export \(format.name)"
        panel.prompt = "Export"
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.allowsOtherFileTypes = false
        let suffix = format.fileExtension.split(separator: ".").last.map(String.init) ?? format.fileExtension
        if let type = UTType(filenameExtension: suffix) { panel.allowedContentTypes = [type] }
        let stem = URL(fileURLWithPath: image.name).deletingPathExtension().lastPathComponent
            .replacingOccurrences(of: ":", with: "-")
        let selection = exports.target == "volume" ? "-t\(exports.timeIndex + 1)-c\(exports.channel + 1)" : ""
        panel.nameFieldStringValue = "\(stem)\(selection)-\(format.id).\(format.fileExtension)"
        panel.message = "Choose a new file. Existing files will be preserved."
        panel.begin { response in
            guard response == .OK, let destination = panel.url else { return }
            session.exportImage(to: destination, arguments: arguments)
        }
    }
}
