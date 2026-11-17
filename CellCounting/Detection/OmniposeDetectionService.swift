import Foundation

/// `DetectionService` for Omnipose's published 2D models and distance-field
/// reconstruction, with configurable thresholds and clustering.
///
/// Runs `Resources/python/omnipose_detect.py` inside the isolated
/// `python/venv_omni/` interpreter that `OmniposeDownloader` provisions.
/// Structurally the sibling of `CellposeSAMDetectionService`: different venv,
/// different sidecar, identical JSON contract on the way back.
///
/// Requests go to a warm `omnipose_detect.py --serve` worker per model and
/// GPU setting (see `ServedDetection`), so PyTorch and the model load once
/// rather than for every image. A failed worker falls back to a one-shot
/// process.
struct OmniposeDetectionService: DetectionService {
    let modelId: String

    init(modelId: String) {
        self.modelId = modelId
    }

    func detect(_ input: DetectionInput) async throws -> DetectionResult {
        let resolvedId = OmniposeDownloader.isKnownModelId(input.modelId) ? input.modelId : modelId
        guard OmniposeDownloader.isKnownModelId(resolvedId) else {
            throw DetectionError.modelNotInstalled(modelId: resolvedId)
        }

        guard let pythonURL = OmniposeDownloader.interpreter() else {
            throw DetectionError.modelNotInstalled(modelId: resolvedId)
        }
        guard let scriptURL = Self.resolveScriptURL() else {
            throw DetectionError.modelNotInstalled(modelId: resolvedId)
        }
        guard let imageURL = input.imageURL else {
            throw DetectionError.imageDecodeFailed
        }

        // Per-image arguments. The script path is not among them: the warm
        // worker is already running it, and a one-shot fallback prepends it.
        var args = [
            "--image", imageURL.path,
            "--model", resolvedId,
            "--pxPerUm", String(input.pxPerUm),
            "--conf", String(input.confidenceThreshold),
        ]
        let channelArg = input.channels.map(String.init).joined(separator: ",")
        if input.channels != [0, 0] && !input.channels.isEmpty {
            args += ["--channels", channelArg]
        }
        // Z-projection + which channel to segment on. Only the sidecars
        // built on `_cellpose_common.build_arg_parser` accept these;
        // StarDist/SAM hand-roll their parsers and would exit 2.
        args += input.channelStackArguments
        if let error = input.omniposeSettings.validationError {
            throw DetectionError.sidecarFailed(exitCode: -1, stderr: error)
        }
        args += input.omniposeSettings.arguments
        if input.backgroundSubtract {
            args += ["--bg-subtract", "--rolling-ball-radius", String(input.rollingBallRadius)]
        }
        args += input.preprocessingArguments
        if input.watershedSplit {
            args += ["--watershed",
                     "--watershed-min-distance", String(input.watershedMinDistance)]
        }
        args += [
            "--small-threshold", String(input.smallThreshold),
            "--large-threshold", String(input.largeThreshold),
        ]
        // Keep size classification independent of image rescaling. Omnipose
        // cyto2 was trained at a 30 px scale; an explicit diameter changes its
        // rescaling. Bacterial models generally use the acquired image scale.
        let expectedDiameterUm = input.expectedDiameterUm
        if expectedDiameterUm > 0 {
            args += ["--diameter", String(expectedDiameterUm)]
        }
        if !input.useGPU {
            args += ["--no-gpu"]
        }

        let outcome: SidecarOutcome
        // Resolved here: the stderr callback is a Sendable closure and must
        // not reach into main-actor state.
        let detectionStageNotification = Notification.Name.ccDetectionStage
        do {
            outcome = try await ServedDetection.run(
                key: Self.workerKey(pythonURL: pythonURL, scriptURL: scriptURL,
                                    model: resolvedId, useGPU: input.useGPU),
                pythonURL: pythonURL,
                scriptURL: scriptURL,
                requestArgs: args) { line in
                NotificationCenter.default.post(
                    name: detectionStageNotification, object: nil, userInfo: ["line": line])
            }
        } catch let error as DetectionError {
            throw error
        } catch {
            throw DetectionError.sidecarFailed(exitCode: -1, stderr: error.localizedDescription)
        }

        try outcome.throwIfFailed()
        return try await SidecarPayload.decodeResultOffMain(stdout: outcome.stdout, exitCode: outcome.exitCode)
    }

    /// Warm-worker identity: the environment, the script, the model and the
    /// GPU setting. Thresholds, clustering and every image setting travel
    /// with each request.
    nonisolated static func workerKey(pythonURL: URL, scriptURL: URL,
                                      model: String, useGPU: Bool) -> PersistentSidecarKey {
        ServedDetection.key(pythonURL: pythonURL, scriptURL: scriptURL,
                            signature: ServedDetection.omniposeSignature(model: model, useGPU: useGPU))
    }

    private static func resolveScriptURL() -> URL? {
        if let staged = PythonRuntime.stagedScriptURL(named: "omnipose_detect.py") {
            return staged
        }
        return PythonRuntime.bundledPythonURL(named: "omnipose_detect.py")
    }
}
