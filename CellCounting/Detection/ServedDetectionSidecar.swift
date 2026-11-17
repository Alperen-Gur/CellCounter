import Foundation

/// Warm-worker routing for the detectors that used to start a new Python
/// process, and reload their model, for every image: StarDist, Omnipose,
/// custom (fine-tuned) models, the classical detector and SAM (whole-image
/// detection and point/box refinement).
///
/// Each request goes to a `--serve` worker in `PersistentSidecarPool`, which
/// keeps the interpreter and the loaded model between images (at most two
/// warm workers, each retired after the pool's idle timeout). When the worker
/// cannot be started or fails, the request is re-run as the one-shot process
/// it used to be. Cancellation behaves as it does for a one-shot run: the
/// worker is stopped and the request ends as `DetectionError.cancelled`.
///
/// The fallback rule is the one `ReusableSidecarRunner` applies to Cellpose
/// and Cellpose-SAM; it lives here as a separate function so it can be tested
/// with an injected pool and launcher.
nonisolated enum ServedDetection {

    // MARK: - Worker identity

    /// Signature prefix of workers that run in the base `venv/`.
    ///
    /// `DetectorRegistry.install` and `AppState` retire every worker whose
    /// signature starts with the prefix of the Python environment they just
    /// changed ("cellpose3|" for `venv/`, which StarDist, the classical
    /// detector and base custom models share with Cellpose 3; "cellpose4|"
    /// for `venv4/`). Each signature therefore starts with its environment's
    /// prefix rather than its detector's name.
    static let baseRuntimePrefix = "cellpose3|"
    /// Signature prefix of workers that run in `venv4/` (Cellpose-SAM).
    static let cellpose4RuntimePrefix = "cellpose4|"
    /// Signature prefix of workers that run in `venv_omni/`. Nothing retires
    /// it on install yet; the prefix keeps these workers apart and gives such
    /// a hook something to match.
    static let omniposeRuntimePrefix = "omnipose|"

    /// StarDist has one model per name. TensorFlow chooses the device itself
    /// and the sidecar has no GPU switch, so the GPU setting is not part of
    /// the signature.
    static func stardistSignature(model: String) -> String {
        "\(baseRuntimePrefix)stardist|\(model)"
    }

    /// Omnipose's model is built from its name and the GPU setting.
    static func omniposeSignature(model: String, useGPU: Bool) -> String {
        "\(omniposeRuntimePrefix)\(model)|gpu=\(useGPU)"
    }

    /// A custom model is identified by its path and kind, and runs in the
    /// environment its entry names. A Cellpose checkpoint is also built for
    /// the GPU setting; a StarDist folder is not (TensorFlow chooses). The
    /// worker reloads the model by itself when the file at the path changes.
    static func customSignature(path: String, kind: String,
                                usesCellpose4Runtime: Bool, useGPU: Bool) -> String {
        let prefix = usesCellpose4Runtime ? cellpose4RuntimePrefix : baseRuntimePrefix
        let device = kind == "stardist" ? "" : "|gpu=\(useGPU)"
        return "\(prefix)custom|\(kind)|\(path)\(device)"
    }

    /// The classical detector has no model and always runs on the CPU, so
    /// every threshold method shares one worker. The method travels with
    /// each request.
    static let classicalSignature = "\(baseRuntimePrefix)classical"

    /// SAM detection (`sam_detect.py --prompts auto`) runs in the base
    /// `venv/`, where `SAMDownloader` installs micro_sam, so installing any
    /// base-environment model (SAM included) retires it. Keyed by micro_sam
    /// model type and the GPU setting, as Omnipose is. (The automatic path
    /// in `sam_detect.py` does not apply `--no-gpu` yet, so both settings
    /// load the same model; the key stays right if that changes.)
    static func samSignature(modelType: String, useGPU: Bool) -> String {
        "\(baseRuntimePrefix)sam|\(modelType)|gpu=\(useGPU)"
    }

    /// Point/box refinement (`sam_detect.py --prompts interactive`) gets its
    /// own worker per micro_sam model type, apart from detection, so a click
    /// never waits in a queue behind a batch image. The worker keeps the
    /// recently clicked images' embeddings in memory. Refinement does not
    /// pass `--no-gpu`, so its model always sits on micro_sam's default
    /// device.
    static func samPromptSignature(modelType: String) -> String {
        "\(baseRuntimePrefix)sam-prompt|\(modelType)|device=default"
    }

    /// The pool key. The interpreter path identifies the Python environment;
    /// paths are standardized as `CellposeDetectionService` does, so two
    /// spellings of one path share a worker.
    static func key(pythonURL: URL, scriptURL: URL, signature: String) -> PersistentSidecarKey {
        PersistentSidecarKey(
            pythonPath: pythonURL.standardizedFileURL.path,
            scriptPath: scriptURL.standardizedFileURL.path,
            modelSignature: signature)
    }

    // MARK: - Fallback decision

    /// What to do when the warm worker did not return a response.
    enum FailureResponse: Equatable {
        /// The worker was stopped on purpose (Cancel, app quit, task
        /// cancellation). Report this exit code, which
        /// `SidecarOutcome.throwIfFailed` turns into `.cancelled`.
        case reportExit(Int32)
        /// The calling task was cancelled: stop without a fallback run.
        case cancel
        /// The worker could not start, crashed or broke the protocol: run the
        /// request as a one-shot process instead.
        case runOneShot
    }

    /// Exit statuses of a process the host terminated on purpose: SIGTERM and
    /// SIGKILL, as signal numbers and as shell-style statuses.
    static let cancellationStatuses: Set<Int32> = [15, -15, 143, 9, -9, 137]

    static func failureResponse(to error: Error, taskCancelled: Bool) -> FailureResponse {
        if case PersistentSidecarError.processTerminated(let status, _) = error,
           cancellationStatuses.contains(status) {
            return .reportExit(status)
        }
        if error is CancellationError { return .cancel }
        return taskCancelled ? .cancel : .runOneShot
    }

    // MARK: - Running a request

    /// Launches a one-shot process: `python args…`, where `args` begins with
    /// the script path.
    typealias OneShotLauncher = @Sendable (
        _ pythonURL: URL,
        _ args: [String],
        _ onStderrLine: (@Sendable (String) -> Void)?
    ) async throws -> SidecarOutcome

    static let processOneShot: OneShotLauncher = { pythonURL, args, onStderrLine in
        try await SidecarProcessRunner.run(pythonURL: pythonURL, args: args, onStderrLine: onStderrLine)
    }

    /// Runs one detection request on the shared warm pool.
    ///
    /// - Parameter requestArgs: the per-image arguments, without the script
    ///   path. The worker receives them as they are; a one-shot fallback runs
    ///   `script requestArgs…`.
    static func run(
        key: PersistentSidecarKey,
        pythonURL: URL,
        scriptURL: URL,
        requestArgs: [String],
        onStderrLine: (@Sendable (String) -> Void)? = nil
    ) async throws -> SidecarOutcome {
        try await run(key: key, pythonURL: pythonURL, scriptURL: scriptURL,
                      requestArgs: requestArgs, pool: PersistentSidecarPool.shared,
                      oneShot: processOneShot, onStderrLine: onStderrLine)
    }

    /// `run` with the pool and the one-shot launcher supplied, for tests.
    static func run(
        key: PersistentSidecarKey,
        pythonURL: URL,
        scriptURL: URL,
        requestArgs: [String],
        pool: PersistentSidecarPool,
        oneShot: OneShotLauncher,
        onStderrLine: (@Sendable (String) -> Void)? = nil
    ) async throws -> SidecarOutcome {
        do {
            return try await pool.run(
                key: key,
                pythonURL: pythonURL,
                scriptURL: scriptURL,
                args: requestArgs,
                onStderrLine: onStderrLine)
        } catch {
            switch failureResponse(to: error, taskCancelled: Task.isCancelled) {
            case .reportExit(let status):
                var stderr = Data()
                if case PersistentSidecarError.processTerminated(_, let detail) = error { stderr = detail }
                return SidecarOutcome(exitCode: status, stdout: Data(), stderr: stderr)
            case .cancel:
                throw DetectionError.cancelled
            case .runOneShot:
                NSLog("%@", "[ServedDetection] warm worker unavailable for \(key.modelSignature); "
                      + "using one-shot fallback: \(error)")
                return try await oneShot(pythonURL, [scriptURL.path] + requestArgs, onStderrLine)
            }
        }
    }
}
