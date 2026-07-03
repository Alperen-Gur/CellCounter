import Foundation

/// `DetectionService` that runs StarDist 2D inference via the shared Python venv
/// and `Resources/python/stardist_detect.py`. Throws `DetectionError` on any failure.
struct StarDistDetectionService: DetectionService {
    /// Which catalog model id this instance handles (e.g. `sd-fluo`).
    let modelId: String

    init(modelId: String) {
        self.modelId = modelId
    }

    func detect(_ input: DetectionInput) async throws -> DetectionResult {
        let availability = CellposeAvailability.detect()
        let pythonURL: URL
        switch availability {
        case .available(let py, _):
            pythonURL = py
        case .missingScripts, .missingVenv, .missingInstaller, .venvBroken:
            throw DetectionError.modelNotInstalled(modelId: modelId)
        }

        // The cellpose script and the stardist script live side-by-side in
        // Resources/python/. We reuse the same resolution rule but swap the filename.
        guard let scriptURL = Self.resolveScriptURL() else {
            throw DetectionError.modelNotInstalled(modelId: modelId)
        }

        guard let imageURL = input.imageURL else {
            throw DetectionError.imageDecodeFailed
        }

        // The caller passes the app-level model id; map it to the StarDist name.
        // If the host accidentally hands us a model id we don't know, throw —
        // running with the wrong model produces bogus results.
        let resolved = StarDistDownloader.modelMap[input.modelId]
            ?? StarDistDownloader.modelMap[modelId]
        guard let stardistName = resolved else {
            throw DetectionError.modelNotInstalled(modelId: input.modelId)
        }

        var args = [
            scriptURL.path,
            "--image",   imageURL.path,
            "--model",   stardistName,
            "--pxPerUm", String(input.pxPerUm),
            "--conf",    String(input.confidenceThreshold),
        ]
        if input.backgroundSubtract {
            args += ["--bg-subtract", "--rolling-ball-radius", String(input.rollingBallRadius)]
        }
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
            // Honour the user's "Use GPU" preference. The stardist sidecar
            // accepts `--no-gpu` to pin TensorFlow to CPU.
            args += ["--no-gpu"]
        }

        let outcome: SidecarOutcome
        do {
            outcome = try await SidecarProcessRunner.run(pythonURL: pythonURL, args: args)
        } catch {
            throw DetectionError.sidecarFailed(exitCode: -1, stderr: error.localizedDescription)
        }

        // Non-zero exit → shared mapping: host-termination signal codes become
        // .cancelled (swallowed by callers), everything else .sidecarFailed.
        try outcome.throwIfFailed()

        // Structured error path: the script reported a known failure on stdout.
        // Structured-error check, payload decode, and per-cell mapping are
        // shared across all detection families via SidecarPayload.decodeResult.
        return try SidecarPayload.decodeResult(stdout: outcome.stdout, exitCode: outcome.exitCode)
    }

    // MARK: — Script resolution

    /// Resolve `stardist_detect.py` from the bundle (prod) or the dev repo (DEBUG).
    private static func resolveScriptURL() -> URL? {
        if let staged = PythonRuntime.stagedScriptURL(named: "stardist_detect.py") {
            return staged
        }
        return PythonRuntime.bundledPythonURL(named: "stardist_detect.py")
    }

}
