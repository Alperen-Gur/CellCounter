import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct WorkbenchLabelImportView: View {
    @Bindable var session: WorkbenchSession
    @Bindable var labelImport: WorkbenchLabelImportState
    @Environment(\.dismiss) private var dismiss
    @State private var rendererStatus = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Import label masks").font(.title2)
                WorkbenchSavedRecordAccess(session: session, catalogues: ["labelImports"])
                Spacer()
                Button("Done") { dismiss() }.disabled(session.busy)
            }
            Text("Import integer object labels from a TIFF or NumPy array. Dimensions must match the selected source exactly; label IDs and coordinates are preserved.")
                .font(.callout).foregroundStyle(.secondary)
            if let error = session.error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            HSplitView {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(session.selectedImage?.name ?? "Select an image").font(.headline)
                        Text(session.viewingVolume
                            ? "Full volume · Time \(session.volume.timeIndex + 1) · Channel \(session.volume.channel + 1)"
                            : "2D source · Channel \(session.channel + 1) · Z \(session.projection) · First time point")
                            .font(.caption).foregroundStyle(.secondary)
                        Button("Choose label file…", action: chooseFile)
                        if !labelImport.path.isEmpty {
                            Text(URL(fileURLWithPath: labelImport.path).lastPathComponent)
                                .font(.callout).textSelection(.enabled)
                            Button("Refresh preview", action: session.previewLabelImport)
                        }
                        if session.labelImportPreviewCurrent, let result = labelImport.result {
                            Divider()
                            Text("\(result["summary"]["labelCount"].integer ?? 0) objects").font(.headline)
                            Text("\(result["summary"]["foregroundSampleCount"].integer ?? 0) labeled \(session.viewingVolume ? "voxels" : "pixels") · Maximum label ID \(result["summary"]["maxLabelId"].integer ?? 0)")
                                .font(.caption).foregroundStyle(.secondary)
                            Text("\(result["source"]["dtype"].string ?? "") · Shape \(result["source"]["shape"].array.compactMap(\.integer).map(String.init).joined(separator: " × "))")
                                .font(.caption).foregroundStyle(.secondary)
                            WorkbenchSupportNote(support: result["summary"]["validSupport"], volume: session.viewingVolume)
                            DisclosureGroup("File and selection provenance") {
                                WorkbenchStructuredOutput(value: .object([
                                    "source": result["source"], "selection": result["selection"]
                                ])).frame(height: 160)
                            }
                        }
                        Text("Applying replaces the saved masks for this selection and recalculates measurements. The previous mask is retained for Undo correction.")
                            .font(.caption).foregroundStyle(.secondary)
                        Text("Labels in filled or unsupported source samples are rejected. A changed file requires a new preview.")
                            .font(.caption).foregroundStyle(.secondary)
                        if session.hasActiveWorkers {
                            Text("Stop the background workflow at a checkpoint before applying labels.")
                                .font(.caption).foregroundStyle(.orange)
                        }
                        Button("Apply imported labels", action: session.applyLabelImport)
                            .buttonStyle(.borderedProminent)
                            .disabled(!session.labelImportPreviewCurrent || session.hasActiveWorkers)
                    }.padding(.trailing, 12)
                }.frame(minWidth: 300, idealWidth: 340).disabled(session.busy)
                VStack(alignment: .leading, spacing: 9) {
                    Text("Alignment preview").font(.headline)
                    if session.labelImportPreviewCurrent, let display = labelImport.display {
                        WorkbenchVolumeWebView(descriptor: display, descriptorIdentity: "labelImport-\(labelImport.generation)", generation: labelImport.generation,
                            crosshair: display["originalDimensions"].array.map { max(0, ($0.integer ?? 1) / 2) },
                            onPointer: { _, _, _ in }, onStatus: { rendererStatus = $0 })
                            .frame(minHeight: 320)
                        Text(rendererStatus).font(.caption).foregroundStyle(.secondary)
                        Text("Volume rendering is sampled for display. The saved label array retains full resolution.")
                            .font(.caption).foregroundStyle(.secondary)
                    } else if session.labelImportPreviewCurrent, let image = labelImport.previewImage {
                        Image(nsImage: image).resizable().scaledToFit()
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        ContentUnavailableView("Preview imported labels", systemImage: "square.stack.3d.up",
                            description: Text("Choose a label file and inspect its alignment before applying."))
                    }
                }.frame(minWidth: 430).padding(.leading, 12)
            }
            HStack {
                if session.busy { ProgressView().controlSize(.small) }
                Text(session.status).font(.caption).foregroundStyle(.secondary)
                Spacer()
            }
        }.padding(24).frame(width: 1030, height: 710)
        .task { labelImport.reset() }
        .onChange(of: labelImport.applied) { _, applied in if applied { dismiss() } }
    }

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.title = "Choose an integer label array"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = ["tif", "tiff", "npy"].compactMap { UTType(filenameExtension: $0) }
        panel.begin { response in
            guard response == .OK, let path = panel.url else { return }
            session.chooseLabelImport(path)
        }
    }
}
