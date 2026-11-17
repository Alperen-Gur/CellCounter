import Foundation

/// SAM-family `DetectionService` that shells out to `sam_detect.py` via the
/// shared Python venv. Routes per-model_type. Throws `DetectionError` on any
/// failure (including CellViT, which has no installable weights).
///
/// Requests go to a warm `sam_detect.py --serve` worker per model type and
/// GPU setting (see `ServedDetection`), so micro_sam and the SAM model load
/// once rather than for every image. A failed worker falls back to a
/// one-shot process.
struct SAMDetectionService: DetectionService {
    let modelId: String

    init(modelId: String) {
        self.modelId = modelId
    }

    func detect(_ input: DetectionInput) async throws -> DetectionResult {
        // CellViT: no checkpoint route — surface as not-installed.
        guard let modelType = SAMDownloader.modelType(for: modelId) else {
            throw DetectionError.modelNotInstalled(modelId: modelId)
        }

        // Resolve python + script. The script lives next to cellpose_detect.py.
        guard let (pythonURL, scriptURL) = Self.resolveSidecar() else {
            throw DetectionError.modelNotInstalled(modelId: modelId)
        }
        guard let imageURL = input.imageURL else {
            throw DetectionError.imageDecodeFailed
        }

        // Per-image arguments. The script path is not among them: the warm
        // worker is already running it, and a one-shot fallback prepends it.
        var args = [
            "--image", imageURL.path,
            "--model", modelType,
            "--pxPerUm", String(input.pxPerUm),
            "--conf", String(input.confidenceThreshold),
            "--prompts", "auto",
        ]
        if input.backgroundSubtract {
            args += ["--bg-subtract", "--rolling-ball-radius", String(input.rollingBallRadius)]
        }
        args += input.preprocessingArguments
        if input.watershedSplit {
            args += [
                "--watershed",
                "--watershed-min-distance", String(input.watershedMinDistance),
            ]
        }
        args += [
            "--small-threshold", String(input.smallThreshold),
            "--large-threshold", String(input.largeThreshold),
        ]
        if !input.useGPU {
            // Honour the user's "Use GPU" preference. The sam sidecar accepts
            // `--no-gpu` to force the SAM models onto CPU.
            args += ["--no-gpu"]
        }

        let outcome: SidecarOutcome
        do {
            outcome = try await ServedDetection.run(
                key: Self.workerKey(pythonURL: pythonURL, scriptURL: scriptURL,
                                    modelType: modelType, useGPU: input.useGPU),
                pythonURL: pythonURL,
                scriptURL: scriptURL,
                requestArgs: args)
        } catch let error as DetectionError {
            throw error
        } catch {
            throw DetectionError.sidecarFailed(exitCode: -1, stderr: error.localizedDescription)
        }

        // Non-zero exit → shared mapping: host-termination signal codes become
        // .cancelled (swallowed by callers), everything else .sidecarFailed.
        try outcome.throwIfFailed()

        // Structured-error check, payload decode, and per-cell mapping are
        // shared across all detection families via SidecarPayload.decodeResult.
        return try await SidecarPayload.decodeResultOffMain(stdout: outcome.stdout, exitCode: outcome.exitCode)
    }

    /// Warm-worker identity: the environment, the script, the micro_sam
    /// model type and the GPU setting. Everything else travels with each
    /// request.
    nonisolated static func workerKey(pythonURL: URL, scriptURL: URL,
                                      modelType: String, useGPU: Bool) -> PersistentSidecarKey {
        ServedDetection.key(pythonURL: pythonURL, scriptURL: scriptURL,
                            signature: ServedDetection.samSignature(modelType: modelType, useGPU: useGPU))
    }

    // MARK: — Sidecar resolution

    /// Locates (pythonURL, sam_detect.py). Mirrors CellposeAvailability's
    /// bundled-then-dev lookup but for the SAM script.
    private static func resolveSidecar() -> (URL, URL)? {
        let fm = FileManager.default

        // Primary: staged FileStore copy (venv lives here post-install).
        let stagedScript = FileStore.shared.pythonDir.appendingPathComponent("sam_detect.py")
        let stagedBin = FileStore.shared.pythonVenvDir.appendingPathComponent("bin")
        let stagedPy3 = stagedBin.appendingPathComponent("python3")
        let stagedPy  = stagedBin.appendingPathComponent("python")
        let stagedPython: URL? = {
            if fm.isExecutableFile(atPath: stagedPy3.path) { return stagedPy3 }
            if fm.isExecutableFile(atPath: stagedPy.path)  { return stagedPy }
            return nil
        }()
        if let p = stagedPython, fm.fileExists(atPath: stagedScript.path) {
            return (p, stagedScript)
        }
        // No dev-repo fallback any more — see PythonRuntime / pass-10 notes.
        return nil
    }

}
