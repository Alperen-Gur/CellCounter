import SwiftUI

struct WorkbenchPreprocessingView: View {
    @Bindable var session: WorkbenchSession
    @Bindable var preprocessing: WorkbenchPreprocessingState
    @Environment(\.dismiss) private var dismiss
    @State private var steps: [WorkbenchPreprocessingStep] = []
    @State private var name = ""
    @State private var originalImageID: String?
    @State private var rendererStatus = ""

    private var filters: [WorkbenchPreprocessingFilter] {
        preprocessing.filters.filter { $0.dimensions.contains(session.viewingVolume ? 3 : 2) }
    }
    private var recipe: WorkbenchJSON { .array(steps.map(\.json)) }
    private var currentPreview: Bool {
        preprocessing.recipe == recipe && preprocessing.sourceContext == session.preprocessingContext
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Preprocess image").font(.title2)
                Spacer()
                Button("Done") { dismiss() }.disabled(session.busy)
            }
            Text("Apply an ordered recipe to the selected source plane or volume. Saving creates a separate acquisition with the recipe and source selection recorded.")
                .font(.callout).foregroundStyle(.secondary)
            if let error = session.error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            HSplitView {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(session.selectedImage?.name ?? "Select an image").font(.headline)
                        Text(session.viewingVolume
                            ? "Volume · Time \(session.volume.timeIndex + 1) · Channel \(session.volume.channel + 1)"
                            : "Plane · Channel \(session.channel + 1) · Z \(session.projection)")
                            .font(.caption).foregroundStyle(.secondary)
                        WorkbenchPreprocessingRecipeEditor(steps: $steps, filters: filters)
                        TextField("Processed image name", text: $name).textFieldStyle(.roundedBorder)
                        HStack {
                            Button("Preview") { session.preprocess(recipe: steps.map(\.json), name: name, previewOnly: true) }
                            Button("Save processed image") { session.preprocess(recipe: steps.map(\.json), name: name, previewOnly: false) }
                                .buttonStyle(.borderedProminent)
                        }.disabled(steps.isEmpty || session.selectedImageID == nil)
                        ForEach(preprocessing.notes, id: \.self) {
                            Text($0).font(.caption).foregroundStyle(.secondary)
                        }
                        if let provenance = preprocessing.provenance, provenance["derived"].bool == true {
                            DisclosureGroup("This image’s preprocessing history") {
                                WorkbenchStructuredOutput(value: provenance["derivation"]).frame(height: 180)
                            }
                        }
                    }.padding(.trailing, 12)
                }.frame(minWidth: 330, idealWidth: 370).disabled(session.busy)
                VStack(alignment: .leading, spacing: 10) {
                    Text("Recipe preview").font(.headline)
                    if currentPreview, let display = preprocessing.display {
                        WorkbenchVolumeWebView(descriptor: display, descriptorIdentity: "preprocessing-\(preprocessing.generation)", generation: preprocessing.generation,
                            crosshair: display["originalDimensions"].array.map { max(0, ($0.integer ?? 1) / 2) },
                            onPointer: { _, _, _ in }, onStatus: { rendererStatus = $0 })
                            .frame(minHeight: 300)
                        Text(rendererStatus).font(.caption).foregroundStyle(.secondary)
                    } else if currentPreview, let image = preprocessing.preview {
                        Image(nsImage: image).resizable().scaledToFit().frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        ContentUnavailableView("Preview the recipe", systemImage: "slider.horizontal.3",
                            description: Text(preprocessing.preview == nil ? "Add filters and preview their combined effect." : "The recipe changed. Preview again to update the displayed result."))
                    }
                    if currentPreview, let summary = preprocessing.summary {
                        WorkbenchSupportNote(support: summary["validSupport"], volume: session.viewingVolume)
                        WorkbenchStructuredOutput(value: summary).frame(maxHeight: 150)
                    }
                }.frame(minWidth: 440).padding(.leading, 12)
            }
            HStack {
                if session.busy { ProgressView().controlSize(.small) }
                Text(session.status).font(.caption).foregroundStyle(.secondary)
                Spacer()
            }
        }.padding(24).frame(width: 1040, height: 730)
        .task {
            originalImageID = session.selectedImageID
            name = "\(session.selectedImage?.name ?? "Image") · processed"
            if steps.isEmpty { addStep() }
            session.loadPreprocessing()
        }
        .onChange(of: preprocessing.filters.map(\.id)) { _, _ in if steps.isEmpty { addStep() } }
        .onChange(of: session.selectedImageID) { _, selected in
            if selected != nil && selected != originalImageID { dismiss() }
        }
    }

    private func addStep() {
        guard let filter = filters.first else { return }
        steps.append(WorkbenchPreprocessingStep(method: filter.id, values: filter.defaults))
    }

}
