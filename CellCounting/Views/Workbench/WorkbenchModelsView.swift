import AppKit
import Combine
import SwiftUI

struct WorkbenchModelInferenceSettings {
    var schema: WorkbenchJSON = .null
    var values: [String: WorkbenchJSON] = [:]
    var definitions: [WorkbenchPluginParameter] {
        let required = Set(schema["required"].array.compactMap(\.string))
        return schema["properties"].object.sorted { $0.key < $1.key }.map {
            WorkbenchPluginParameter(id: $0.key, schema: $0.value, required: required.contains($0.key))
        }
    }
    mutating func configure(_ schema: WorkbenchJSON, values saved: [String: WorkbenchJSON]? = nil) {
        self.schema = schema
        values = saved ?? Dictionary(uniqueKeysWithValues: definitions.compactMap {
            $0.required || $0.schema["default"] != .null ? ($0.id, $0.initialValue) : nil
        })
    }
    var valid: Bool {
        guard !schema["properties"].object.isEmpty,
              Set(values.keys).isSubset(of: Set(schema["properties"].object.keys)),
              schema["required"].array.compactMap(\.string).allSatisfy({ values[$0] != nil }) else { return false }
        return definitions.allSatisfy { field in
            guard let value = values[field.id] else { return !field.required }
            if !field.choices.isEmpty && !field.choices.contains(value) { return false }
            if field.type == "number" || field.type == "integer" {
                guard let number = value.number, number.isFinite,
                      field.type != "integer" || value.integer != nil else { return false }
                if let minimum = field.schema["minimum"].number, number < minimum { return false }
                if let maximum = field.schema["maximum"].number, number > maximum { return false }
                if let minimum = field.schema["exclusiveMinimum"].number, number <= minimum { return false }
            } else if field.type == "boolean" { return value.bool != nil }
            else if field.type == "string" { return value.string != nil }
            return true
        }
    }
}

struct WorkbenchModelInferenceControls: View {
    @Binding var settings: WorkbenchModelInferenceSettings
    var body: some View {
        WorkbenchPluginParameters(definitions: settings.definitions, values: $settings.values)
    }
}

struct WorkbenchModelsView: View {
    @Bindable var session: WorkbenchSession
    @Bindable var models: WorkbenchModelState
    @Environment(\.dismiss) private var dismiss
    @State private var inference = WorkbenchModelInferenceSettings()
    private var registrationBackend: WorkbenchModelBackend? { models.backends.first { $0.id == models.registrationBackend } }
    private var registrationDefinitions: [WorkbenchPluginParameter] {
        let schema = registrationBackend?.registrationSchema ?? .null
        let required = Set(schema["required"].array.compactMap(\.string))
        return schema["properties"].object.sorted { $0.key < $1.key }.map {
            WorkbenchPluginParameter(id: $0.key, schema: $0.value, required: required.contains($0.key))
        }
    }
    private var registrationValid: Bool {
        guard let backend = registrationBackend,
              !models.registrationName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              models.registrationName.count <= 200, !models.registrationPythonPath.isEmpty,
              !models.registrationCheckpointPath.isEmpty else { return false }
        return backend.fileInputs.allSatisfy { $0["required"].bool != true || !(models.registrationFiles[$0["key"].string ?? ""] ?? "").isEmpty }
            && backend.registrationSchema["required"].array.compactMap(\.string).allSatisfy { models.registrationValues[$0] != nil }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Registered models").font(.title2)
                WorkbenchSavedRecordAccess(session: session, catalogues: ["models", "trainingJobs"])
                Spacer()
                Button("Refresh", action: session.loadModels)
                Button("Done") { dismiss() }
            }.disabled(session.busy)
            Text("Register a local checkpoint and its matching Python environment. Model parameters follow the selected backend.")
                .font(.callout).foregroundStyle(.secondary)
            if let error = session.error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            HSplitView {
                ScrollView {
                    VStack(alignment: .leading, spacing: 11) {
                        Text("Register a checkpoint").font(.headline)
                        TextField("Model name", text: $models.registrationName).textFieldStyle(.roundedBorder)
                        Picker("Backend", selection: Binding(get: { models.registrationBackend }, set: { models.selectRegistrationBackend($0) })) {
                            ForEach(models.backends) { Text($0.name).tag($0.id) }
                        }
                        pathField("Matching Python executable", value: $models.registrationPythonPath)
                        pathField("Exact checkpoint weights", value: $models.registrationCheckpointPath)
                        ForEach(Array((registrationBackend?.fileInputs ?? []).enumerated()), id: \.offset) { _, file in
                            let key = file["key"].string ?? ""
                            pathField((file["name"].string ?? key) + (file["required"].bool == true ? " (required)" : " (optional)"), value: Binding(
                                get: { models.registrationFiles[key] ?? "" }, set: { models.registrationFiles[key] = $0 }))
                        }
                        WorkbenchPluginParameters(definitions: registrationDefinitions, values: $models.registrationValues)
                        ForEach(registrationBackend?.notes ?? [], id: \.self) {
                            Text($0).font(.caption).foregroundStyle(.secondary)
                        }
                        Button("Register local model") {
                            session.registerModel(name: models.registrationName.trimmingCharacters(in: .whitespacesAndNewlines), backend: models.registrationBackend,
                                pythonPath: models.registrationPythonPath, checkpointPath: models.registrationCheckpointPath,
                                files: models.registrationFiles, registrationConfig: models.registrationValues)
                        }.disabled(!registrationValid || !session.canRefreshWithoutDiscardingEdits || session.hasActiveWorkers || models.hasActiveTraining)
                        Divider()
                        Text("Training").font(.headline)
                        Text("Freeze reviewed masks and independent specimen splits in Reference datasets and comparison, then open its Train tab.")
                            .font(.callout).foregroundStyle(.secondary)
                    }.padding(.trailing, 12)
                }.frame(minWidth: 330)
                ScrollView {
                    VStack(alignment: .leading, spacing: 11) {
                        Picker("Registered model", selection: $models.selectedModelID) {
                            Text("Select a model").tag("")
                            ForEach(models.models) { Text($0.name).tag($0.id) }
                        }
                        if let model = models.selectedModel {
                            Text("\(model.backend) · \(model.enabled ? "Enabled" : "Disabled")").font(.caption)
                            Text(model.pythonPath).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                            DisclosureGroup("Exact model artifacts") {
                                Text("Checkpoint SHA-256: \(model.checkpointHash)").font(.caption.monospaced()).textSelection(.enabled)
                                ForEach(Array(model.modelArtifacts.enumerated()), id: \.offset) { _, artifact in
                                    Text("\(artifact["role"].string ?? "Artifact") · \(artifact["filename"].string ?? "") · \(artifact["bytes"].integer ?? 0) bytes")
                                        .font(.caption).textSelection(.enabled)
                                }
                                if let hash = model.artifactSetHash { Text("Artifact set SHA-256: \(hash)").font(.caption.monospaced()).textSelection(.enabled) }
                                if model.registrationConfig != .null { WorkbenchStructuredOutput(value: model.registrationConfig).frame(maxHeight: 130) }
                            }
                            HStack {
                                Button(model.enabled ? "Disable" : "Enable") { session.configureModel(model.id, enabled: !model.enabled) }
                                Button("Rebind Python…") { rebind(model.id) }
                                Button("Probe compatibility") { session.probeModel(model.id) }
                            }
                            if let probe = models.probes[model.id] {
                                if probe["available"].bool == true {
                                    Text("\(model.backend) \(probe["backendVersion"].string ?? probe["cellposeVersion"].string ?? "") · Python \(probe["pythonVersion"].string ?? "")")
                                        .font(.caption).foregroundStyle(.secondary)
                                    if probe["tensorflowGPU"].bool != nil {
                                        Text("TensorFlow GPU: \(probe["tensorflowGPU"].bool == true ? "available" : "unavailable")").font(.caption).foregroundStyle(.secondary)
                                    } else {
                                        Text("CUDA: \(probe["cuda"].bool == true ? "available" : "unavailable") · MPS: \(probe["mps"].bool == true ? "available" : "unavailable")")
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                    if probe["checkpointLoaded"].bool == false {
                                        Text("Installed API checked. Weight architecture and any required decoder are checked during explicit inference.").font(.caption).foregroundStyle(.secondary)
                                    }
                                } else {
                                    Text(probe["error"].string ?? probe["error"]["message"].string ?? "Runtime is unavailable.")
                                        .font(.callout).foregroundStyle(.orange)
                                }
                            }
                            Divider()
                            WorkbenchModelEnvironmentControls(session: session, models: models, model: model)
                            Divider()
                            WorkbenchModelCardControls(session: session, models: models, model: model, draft: models.cardDraft(model.id))
                            Divider()
                            Text("Segment selected 2D image").font(.headline)
                            Text(session.selectedImage?.name ?? "Select an image in the workbench.").font(.callout)
                            WorkbenchModelInferenceControls(settings: $inference)
                            ForEach(model.notes, id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary) }
                            Button("Run and save segmentation") {
                                session.runRegisteredModel(model.id, parameters: inference.values)
                            }.buttonStyle(.borderedProminent)
                                .disabled(!model.enabled || session.selectedImageID == nil || session.viewingVolume ||
                                    !inference.valid)
                            if session.viewingVolume {
                                Text("Switch to the 2D projection view to use this registered model. Volumetric methods are available through compatible plugins.")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }.padding(.leading, 12)
                }.frame(minWidth: 360)
            }.disabled(session.busy)
            HStack {
                if session.busy { ProgressView().controlSize(.small) }
                Text(session.status).font(.caption).foregroundStyle(.secondary)
                Spacer()
            }
        }.padding(24).frame(width: 940, height: 680).task { configureInference(); session.loadModels() }
        .onChange(of: models.selectedModelID) { _, _ in configureInference() }
        .onChange(of: models.selectedModel?.inferenceSchema ?? .null) { _, _ in configureInference() }
    }

    private func pathField(_ title: String, value: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            HStack {
                TextField(title, text: value).textFieldStyle(.roundedBorder)
                Button("Choose…") { chooseFile(title: title) { value.wrappedValue = $0.path } }
            }
        }
    }
    private func configureInference() { inference.configure(models.selectedModel?.inferenceSchema ?? .null) }
    private func rebind(_ id: String) { chooseFile(title: "Choose the matching model Python executable") { session.configureModel(id, pythonPath: $0.path) } }
    private func chooseFile(title: String, completion: @escaping (URL) -> Void) {
        let panel = NSOpenPanel()
        panel.title = title; panel.allowsMultipleSelection = false; panel.canChooseDirectories = false
        panel.showsHiddenFiles = true
        panel.begin { result in if result == .OK, let url = panel.url { completion(url) } }
    }
}

struct WorkbenchTrainingPanel: View {
    @Bindable var session: WorkbenchSession
    @Bindable var extensions: WorkbenchExtensionState
    @Bindable var models: WorkbenchModelState
    @State private var name = "Adapted Cellpose model"
    @State private var epochs = 40
    @State private var learningRate = 0.0002
    @State private var batchSize = 4
    @State private var augment = true
    @State private var earlyStop = true
    @State private var seed = 42
    @State private var device = "auto"
    @State private var timeoutHours = 6

    var body: some View {
        HSplitView {
            ScrollView {
                VStack(alignment: .leading, spacing: 11) {
                    Text("Train on frozen references").font(.headline)
                    Picker("Dataset", selection: $extensions.selectedDatasetID) {
                        Text("Select a frozen dataset").tag("")
                        ForEach(Array(extensions.datasets.enumerated()), id: \.offset) { _, dataset in
                            Text(dataset["name"].string ?? "Dataset").tag(dataset["id"].string ?? "")
                        }
                    }
                    Picker("Base model", selection: $models.selectedModelID) {
                        Text("Select a registered model").tag("")
                        ForEach(models.models.filter { $0.enabled && $0.supportsTraining }) { Text($0.name).tag($0.id) }
                        if let model = models.selectedModel, !model.supportsTraining {
                            Text("\(model.name) · Inference only").tag(model.id).disabled(true)
                        }
                    }
                    TextField("Training run name", text: $name).textFieldStyle(.roundedBorder)
                    Stepper("Epochs: \(epochs)", value: $epochs, in: 6...2000)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Learning rate").font(.caption).foregroundStyle(.secondary)
                        TextField("Learning rate", value: $learningRate, format: .number).textFieldStyle(.roundedBorder)
                    }
                    Stepper("Batch size: \(batchSize)", value: $batchSize, in: 1...32)
                    TextField("Random seed", value: $seed, format: .number).textFieldStyle(.roundedBorder)
                        .accessibilityLabel("Training random seed")
                    Toggle("Augment training samples", isOn: $augment)
                    Toggle("Early stopping using validation", isOn: $earlyStop)
                    Picker("Compute device", selection: $device) { Text("Automatic").tag("auto"); Text("CPU").tag("cpu") }
                    Stepper("Maximum duration: \(timeoutHours) hours", value: $timeoutHours, in: 1...24)
                    Text("Training uses the training split and checkpoint selection uses validation. Final metrics use the frozen held-out test specimens.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Start local training") {
                        session.startModelTraining(datasetID: extensions.selectedDatasetID, modelID: models.selectedModelID,
                            name: name.trimmingCharacters(in: .whitespacesAndNewlines), parameters: [
                                "epochs": .number(Double(epochs)), "learningRate": .number(learningRate),
                                "batchSize": .number(Double(batchSize)), "augment": .bool(augment), "earlyStop": .bool(earlyStop),
                                "seed": .number(Double(seed)), "device": .string(device),
                                "timeoutSeconds": .number(Double(timeoutHours * 3600))])
                    }.buttonStyle(.borderedProminent)
                        .disabled(session.busy || extensions.selectedDatasetID.isEmpty || models.selectedModel?.enabled != true ||
                                  models.selectedModel?.supportsTraining != true ||
                                  name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || name.count > 200 ||
                                  !learningRate.isFinite || learningRate <= 0 || learningRate > 1 ||
                                  seed < 0 || seed > 4294967295)
                    if models.models.isEmpty {
                        Text("Register a Cellpose 3 checkpoint under Segmentation & correction → Registered models first.").font(.caption).foregroundStyle(.secondary)
                    }
                }.padding(14)
            }.frame(minWidth: 350).disabled(session.busy)
            VStack(alignment: .leading, spacing: 11) {
                HStack {
                    Text("Training jobs").font(.headline)
                    Spacer()
                    Button("Refresh", action: session.refreshTrainingJobs).disabled(session.busy)
                }
                Text("Progress follows the shared project activity refresh.").font(.caption).foregroundStyle(.secondary)
                ScrollView {
                    VStack(alignment: .leading, spacing: 15) {
                        ForEach(Array(models.jobs.reversed().enumerated()), id: \.offset) { _, job in jobCard(job) }
                        if models.jobs.isEmpty {
                            Text("Training jobs remain attached to this project after the panel closes.")
                                .font(.callout).foregroundStyle(.secondary)
                        }
                    }
                }
            }.padding(14).frame(minWidth: 400)
        }
    }

    private func jobCard(_ job: WorkbenchJSON) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(job["name"].string ?? "Training job").font(.headline)
            Text("\(job["status"].string ?? "Unknown")\(job["phase"].string.map { " · \($0)" } ?? "")")
                .font(.caption).foregroundStyle(.secondary)
            if let epoch = job["progress"]["epoch"].integer {
                let total = max(1, job["progress"]["totalEpochs"].integer ?? 1)
                ProgressView(value: Double(epoch), total: Double(total))
                Text("Epoch \(epoch) / \(total)").font(.caption.monospacedDigit())
                Text("Training loss: \(format(job["progress"]["trainLoss"].number)) · Validation loss: \(format(job["progress"]["validationLoss"].number))")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            if let error = job["error"].string ?? job["error"]["message"].string { Text(error).font(.callout).foregroundStyle(.red) }
            if let id = job["id"].string {
                HStack {
                    Button("Status") { session.refreshModelTraining(id) }
                    if ["queued", "starting", "running"].contains(job["status"].string ?? "") {
                        Button("Request cancellation") { session.cancelModelTraining(id) }
                    }
                    if job["status"].string == "completed" {
                        Button("Collect model and results") { session.collectModelTraining(id) }.buttonStyle(.borderedProminent)
                    }
                }.disabled(session.busy)
            }
            if job["status"].string == "interrupted" {
                Text("This run was interrupted. Its frozen dataset remains available for a new training run.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if job["metrics"] != .null {
                Text("Held-out evaluation").font(.caption.weight(.semibold))
                Text("AP50 \(format(job["metrics"]["ap50"].number)) · F1 \(format(job["metrics"]["f1"].number)) · \(job["metrics"]["testImages"].integer ?? 0) test images")
                    .font(.caption.monospacedDigit())
            }
            if job["resultModelId"].string != nil {
                Text("Collected model is available under Registered models.").font(.caption).foregroundStyle(.secondary)
            }
        }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.4)).clipShape(RoundedRectangle(cornerRadius: 8))
    }
    private func format(_ value: Double?) -> String { value.map { String(format: "%.4f", $0) } ?? "—" }
}
