import Foundation
import Observation

nonisolated struct WorkbenchRegisteredModel: Identifiable, Sendable {
    let id: String
    let name: String
    let backend: String
    let pythonPath: String
    let checkpointHash: String
    let enabled: Bool
    let training: WorkbenchJSON
    let inferenceSchema: WorkbenchJSON
    let supportsTraining: Bool
    let notes: [String]
    let environmentStatus: String
    let activeEnvironmentID: String?
    let activeEnvironmentHash: String?
    let environmentCount: Int
    let registrationConfig: WorkbenchJSON
    let modelArtifacts: [WorkbenchJSON]
    let artifactSetHash: String?
    init?(_ value: WorkbenchJSON) {
        guard let id = value["id"].string else { return nil }
        self.id = id
        name = value["name"].string ?? id
        backend = value["backend"].string ?? "cellpose3"
        pythonPath = value["pythonPath"].string ?? ""
        checkpointHash = value["checkpointHash"].string ?? ""
        enabled = value["enabled"].bool == true
        training = value["training"]
        inferenceSchema = value["inferenceSchema"]
        supportsTraining = value["supportsTraining"].bool == true
        notes = value["notes"].array.compactMap(\.string)
        environmentStatus = value["environmentStatus"].string ?? "unrecorded"
        activeEnvironmentID = value["activeEnvironmentId"].string
        activeEnvironmentHash = value["activeEnvironmentHash"].string
        environmentCount = value["environmentCount"].integer ?? 0
        registrationConfig = value["registrationConfig"]
        modelArtifacts = value["modelArtifacts"].array
        artifactSetHash = value["artifactSetHash"].string
    }
}

nonisolated struct WorkbenchModelBackend: Identifiable, Sendable {
    let id: String
    let name: String
    let supportsTraining: Bool
    let notes: [String]
    let registrationSchema: WorkbenchJSON
    let fileInputs: [WorkbenchJSON]
    init?(_ value: WorkbenchJSON) {
        guard let id = value["id"].string else { return nil }
        self.id = id; name = value["name"].string ?? id
        supportsTraining = value["supportsTraining"].bool == true
        notes = value["notes"].array.compactMap(\.string)
        registrationSchema = value["registrationSchema"]
        fileInputs = value["fileInputs"].array
    }
}

@MainActor @Observable
final class WorkbenchModelState {
    var models: [WorkbenchRegisteredModel] = []
    var jobs: [WorkbenchJSON] = []
    var selectedModelID = ""
    var probes: [String: WorkbenchJSON] = [:]
    var backends: [WorkbenchModelBackend] = []
    var environmentRecords: [String: WorkbenchJSON] = [:]
    var cards: [String: WorkbenchJSON] = [:]
    var cardDrafts: [String: WorkbenchModelCardDraft] = [:]
    var activation: WorkbenchJSON = .null
    var activationHistory: [WorkbenchJSON] = []
    func cardDraft(_ modelID: String) -> WorkbenchModelCardDraft {
        if let draft = cardDrafts[modelID] { return draft }
        let draft = WorkbenchModelCardDraft(); cardDrafts[modelID] = draft; return draft
    }
    var registrationName = "Local model"
    var registrationBackend = "cellpose3"
    var registrationPythonPath = ""
    var registrationCheckpointPath = ""
    var registrationFiles: [String: String] = [:]
    var registrationValues: [String: WorkbenchJSON] = [:]
    var hasActiveTraining: Bool {
        jobs.contains { ["queued", "starting", "running", "cancelling"].contains($0["status"].string ?? "") }
    }
    var selectedModel: WorkbenchRegisteredModel? { models.first { $0.id == selectedModelID } }
    func reset() {
        models = []; jobs = []; selectedModelID = ""; probes = [:]; backends = []; environmentRecords = [:]
        cards = [:]; cardDrafts = [:]; activation = .null; activationHistory = []
        registrationName = "Local model"; registrationBackend = "cellpose3"; registrationPythonPath = ""
        registrationCheckpointPath = ""; registrationFiles = [:]; registrationValues = [:]
    }
    func selectRegistrationBackend(_ id: String) {
        guard id != registrationBackend else { return }
        registrationBackend = id; registrationFiles = [:]
        let schema = backends.first { $0.id == id }?.registrationSchema ?? .null
        let required = Set(schema["required"].array.compactMap(\.string))
        let properties = schema["properties"].object
        registrationValues = Dictionary(uniqueKeysWithValues: properties.compactMap { key, value in
            if value["default"] != .null { return (key, value["default"]) }
            if required.contains(key) { return (key, WorkbenchPluginParameter(id: key, schema: value, required: true).initialValue) }
            return nil
        })
    }
    func applyInspection(_ value: WorkbenchJSON) {
        models = value["models"].array.compactMap(WorkbenchRegisteredModel.init)
        let active = value["activeTrainingJobs"].array
        let activeIDs = Set(active.compactMap { $0["id"].string })
        jobs = active + value["trainingJobs"].array.filter { !activeIDs.contains($0["id"].string ?? "") }
        if value["modelActivation"] != .null { activation = value["modelActivation"] }
        if selectedModelID.isEmpty { selectedModelID = activation["available"].bool == true ? activation["modelId"].string ?? "" : models.first?.id ?? "" }
    }
    func applyActivity(_ active: [WorkbenchJSON], recent: [WorkbenchJSON]? = nil) {
        let ids = Set(active.compactMap { $0["id"].string })
        jobs = active + (recent ?? jobs).filter { !ids.contains($0["id"].string ?? "") && !["queued", "starting", "running", "cancelling"].contains($0["status"].string ?? "") }
    }
    func updateJob(_ job: WorkbenchJSON) {
        guard let id = job["id"].string else { return }
        if let index = jobs.firstIndex(where: { $0["id"].string == id }) { jobs[index] = job }
        else { jobs.append(job) }
    }
}

extension WorkbenchSession {
    func loadModels() {
        perform("Loading project models…") {
            try await self.inspect()
            self.models.backends = try await self.call("model.catalog")["result"]["backends"].array.compactMap(WorkbenchModelBackend.init)
            if !self.models.selectedModelID.isEmpty && self.models.selectedModel == nil {
                let record = try await self.resolveCatalogueEntries("models", ids: [self.models.selectedModelID])
                if let model = record.first.flatMap(WorkbenchRegisteredModel.init) { self.models.models.append(model) }
            }
            if !self.hasDisplayedImage { try await self.loadImage() }
            self.reportStatus("Project model registry and training jobs loaded.")
        }
    }

    func registerModel(name: String, backend: String, pythonPath: String, checkpointPath: String,
                       files: [String: String] = [:], registrationConfig: [String: WorkbenchJSON] = [:]) {
        var arguments: [String: WorkbenchJSON] = [
            "name": .string(name), "backend": .string(backend),
            "pythonPath": .string(pythonPath), "checkpointPath": .string(checkpointPath)
        ]
        for (key, path) in files where ["configPath", "thresholdsPath"].contains(key) && !path.isEmpty { arguments[key] = .string(path) }
        if !registrationConfig.isEmpty { arguments["registrationConfig"] = .object(registrationConfig) }
        changeModel("model.register", arguments: arguments, message: "Registering local model…", finished: "Exact model weights and configuration retained with immutable identities.")
    }

    func configureModel(_ modelID: String, pythonPath: String? = nil, enabled: Bool? = nil) {
        var args: [String: WorkbenchJSON] = ["modelId": .string(modelID)]
        if let pythonPath { args["pythonPath"] = .string(pythonPath) }
        if let enabled { args["enabled"] = .bool(enabled) }
        models.probes[modelID] = nil
        if pythonPath != nil { models.environmentRecords[modelID] = nil }
        changeModel("model.configure", arguments: args, message: "Updating registered model…", finished: "Model configuration updated.")
    }

    func probeModel(_ modelID: String) {
        perform("Checking model runtime…") {
            self.models.probes[modelID] = try await self.call("model.probe", arguments: ["modelId": .string(modelID)])["result"]
            self.reportStatus("Model runtime availability checked.")
        }
    }

    func loadModelEnvironment(_ modelID: String, environmentID: String? = nil) {
        var arguments: [String: WorkbenchJSON] = ["modelId": .string(modelID)]
        if let environmentID { arguments["environmentId"] = .string(environmentID) }
        perform("Reading saved model environment…", refreshOnConflict: false) {
            let result = try await self.call("model.environment.get", arguments: arguments)["result"]
            guard result["modelId"].string == modelID else {
                throw WorkbenchFailure(code: "invalid-response", message: "The saved environment records could not be read. Refresh the model registry and try again.")
            }
            self.models.environmentRecords[modelID] = result
            self.reportStatus("Saved environment records loaded. Reading them does not execute the model interpreter.")
        }
    }

    func captureModelEnvironment(_ modelID: String) {
        guard canRefreshWithoutDiscardingEdits, !hasActiveWorkers, !models.hasActiveTraining,
              models.models.first(where: { $0.id == modelID })?.enabled == true else { return }
        perform("Capturing registered model environment…", refreshOnConflict: false) {
            let result = try await self.call("model.environment.capture", arguments: ["modelId": .string(modelID)], mutation: true)["result"]
            let environment = result["environment"]
            guard let environmentID = environment["id"].string, result["model"]["id"].string == modelID else {
                throw WorkbenchFailure(code: "invalid-response", message: "Environment capture returned an unreadable record. Inspect saved records before capturing again.")
            }
            var records = self.models.environmentRecords[modelID]?["environments"].array ?? []
            records.removeAll { $0["id"].string == environmentID }
            var compact = environment.object
            compact["inventory"] = nil
            records.append(.object(compact))
            self.models.environmentRecords[modelID] = .object([
                "modelId": .string(modelID), "activeEnvironmentId": .string(environmentID),
                "environments": .array(records), "environment": environment
            ])
            try await self.inspect()
            self.reportStatus("Environment inventory captured as an immutable record. Model execution checks the recorded inventory before running.")
        }
    }

    func runRegisteredModel(_ modelID: String, parameters values: [String: WorkbenchJSON]) {
        guard let imageID = selectedImageID, !viewingVolume else { return }
        changeModel("model.run", arguments: [
            "modelId": .string(modelID), "imageId": .string(imageID),
            "parameters": .object(values), "sourceParameters": parameters
        ], message: "Running registered segmentation model…", finished: "Model segmentation and measurements saved.", reloadImage: true)
    }

    func startModelTraining(datasetID: String, modelID: String, name: String,
                            parameters values: [String: WorkbenchJSON]) {
        var args = values
        args["datasetId"] = .string(datasetID); args["modelId"] = .string(modelID); args["name"] = .string(name)
        changeModel("adaptation.train.start", arguments: args, message: "Starting local model training…",
                    finished: "Training started. Refresh progress or return later to collect the completed model.")
    }

    func refreshModelTraining(_ jobID: String) {
        perform("Reading training progress…") {
            let result = try await self.call("adaptation.train.status", arguments: ["jobId": .string(jobID)])["result"]
            self.models.updateJob(result["job"])
            self.reportStatus("Training progress updated.")
        }
    }

    func refreshTrainingJobs() {
        perform("Reading training progress…") {
            try await self.inspect()
            self.reportStatus("Training jobs updated.")
        }
    }

    func cancelModelTraining(_ jobID: String) {
        changeModel("adaptation.train.cancel", arguments: ["jobId": .string(jobID)], message: "Requesting training cancellation…",
                    finished: "Cancellation requested. Training stops at the next supported boundary.")
    }

    func collectModelTraining(_ jobID: String) {
        changeModel("adaptation.train.collect", arguments: ["jobId": .string(jobID)], message: "Collecting completed model…",
                    finished: "Trained model and held-out evaluation collected into this project.")
    }

    private func changeModel(_ operation: String, arguments: [String: WorkbenchJSON],
                             message: String, finished: String, reloadImage: Bool = false) {
        perform(message) {
            let result = try await self.call(operation, arguments: arguments, mutation: true)["result"]
            if let id = result["model"]["id"].string { self.models.selectedModelID = id }
            try await self.inspect()
            if result["job"] != .null { self.models.updateJob(result["job"]) }
            if reloadImage || !self.hasDisplayedImage { try await self.loadImage() }
            self.invalidateSummaries()
            self.reportStatus(finished)
        }
    }
}
