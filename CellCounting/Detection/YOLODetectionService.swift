import Foundation

/// YOLO-family (Ultralytics) `DetectionService` that shells out to
/// `Resources/python/yolo_detect.py`. Throws `DetectionError` on any failure.
struct YOLODetectionService: DetectionService {
    let modelId: String
    /// Resolved lazily via a closure so tests can inject a custom path.
    let weightsPathProvider: @Sendable () -> URL

    init(modelId: String, weightsPath: URL) {
        self.modelId = modelId
        self.weightsPathProvider = { weightsPath }
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

        // Resolve the YOLO script next to the shared cellpose script so both
        // production (bundled Resources) and dev (repo) layouts work uniformly.
        guard let scriptURL = Self.locateYOLOScript() else {
            throw DetectionError.modelNotInstalled(modelId: modelId)
        }

        // Verify weights actually exist.
        let weightsURL = weightsPathProvider()
        guard FileManager.default.fileExists(atPath: weightsURL.path) else {
            throw DetectionError.modelNotInstalled(modelId: modelId)
        }

        guard let imageURL = input.imageURL else {
            throw DetectionError.imageDecodeFailed
        }

        var args: [String] = [
            scriptURL.path,
            "--image", imageURL.path,
            "--weights", weightsURL.path,
            "--pxPerUm", String(input.pxPerUm),
            "--conf", String(input.confidenceThreshold),
        ]
        if input.backgroundSubtract {
            args += ["--bg-subtract", "--rolling-ball-radius", String(input.rollingBallRadius)]
        }
        args += [
            "--small-threshold", String(input.smallThreshold),
            "--large-threshold", String(input.largeThreshold),
        ]
        if !input.useGPU {
            // Honour the user's "Use GPU" preference. The yolo sidecar accepts
            // `--no-gpu` to force Ultralytics onto CPU (no MPS, no CUDA).
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

        // Structured error from the script (e.g. ultralytics-not-installed)?
        // Structured-error check, payload decode, and per-cell mapping are
        // shared across all detection families via SidecarPayload.decodeResult.
        return try SidecarPayload.decodeResult(stdout: outcome.stdout, exitCode: outcome.exitCode)
    }

    // MARK: — Script locator

    private static func locateYOLOScript() -> URL? {
        if let staged = PythonRuntime.stagedScriptURL(named: "yolo_detect.py") {
            return staged
        }
        return PythonRuntime.bundledPythonURL(named: "yolo_detect.py")
    }

}
