import Foundation

/// Pass-16: family-specific `DetectionService` for Cellpose-SAM (4.x / CPSAM).
///
/// Structurally identical to `CellposeDetectionService` (3.x) but points at the
/// `venv4/bin/python3` interpreter and the `cellpose4_detect.py` sidecar that
/// C1 ships. The two services coexist; AppState picks one based on the
/// active model id.
///
/// First-run note: cellpose 4 lazily downloads ~1.15 GB of CPSAM transformer
/// weights into `~/.cellpose/models/` the first time `CellposeModel()` is
/// constructed. C1's `cellpose4_detect.py` emits progress lines to stderr
/// during that download which surface to the ProcessingView through the
/// existing `ccDetectionStage` notification used by the 3.x service.
struct CellposeSAMDetectionService: DetectionService {
    let modelId: String

    init(modelId: String) {
        self.modelId = modelId
    }

    func detect(_ input: DetectionInput) async throws -> DetectionResult {
        let availability = Cellpose4Availability.detect()
        let pythonURL: URL
        let scriptURL: URL
        switch availability {
        case .available(let py, let script):
            pythonURL = py
            scriptURL = script
        case .missingScripts, .missingVenv, .missingInstaller, .venvBroken:
            throw DetectionError.modelNotInstalled(modelId: modelId)
        }

        guard let imageURL = input.imageURL else {
            throw DetectionError.imageDecodeFailed
        }

        // The cp4 sidecar only takes a single architecture (CPSAM); we still
        // pass --model for forward compatibility in case C1 ships variants.
        let channelArg = input.channels.map(String.init).joined(separator: ",")
        let isDefaultChannels = (input.channels == [0, 0] || input.channels.isEmpty)

        let resolvedModelName = Self.resolvedModelName(input.modelId, fallback: modelId)
        var requestArgs = [
            "--image", imageURL.path,
            // The catalog id IS the cellpose `pretrained_model` string
            // (cpsam / cpsam_v2 / cpdino / cpdino-vitb). Hardcoding "cpsam"
            // here would silently run the original checkpoint no matter which
            // row the user activated. Prefer the input's id, falling back to
            // this instance's, and to cpsam only if neither is a cp4 id.
            "--model", resolvedModelName,
            "--pxPerUm", String(input.pxPerUm),
            "--conf", String(input.confidenceThreshold),
        ]
        if !isDefaultChannels {
            requestArgs += ["--channels", channelArg]
        }
        // Z-projection + which channel to segment on. Only the sidecars
        // built on `_cellpose_common.build_arg_parser` accept these;
        // StarDist/SAM hand-roll their parsers and would exit 2.
        requestArgs += input.channelStackArguments
        if input.backgroundSubtract {
            requestArgs += ["--bg-subtract", "--rolling-ball-radius", String(input.rollingBallRadius)]
        }
        requestArgs += input.preprocessingArguments
        if input.watershedSplit {
            requestArgs += [
                "--watershed",
                "--watershed-min-distance", String(input.watershedMinDistance),
            ]
        }
        requestArgs += [
            "--small-threshold", String(input.smallThreshold),
            "--large-threshold", String(input.largeThreshold),
        ]
        // Freeze the explicit diameter with the job. Zero omits the override
        // and retains the sidecar's automatic diameter behavior.
        let expectedDiameterUm = input.expectedDiameterUm
        if expectedDiameterUm > 0 {
            requestArgs += ["--diameter", String(expectedDiameterUm)]
        }
        if !input.useGPU {
            requestArgs += ["--no-gpu"]
        }

        let outcome: SidecarOutcome
        let detectionStageNotification = Notification.Name("ccDetectionStage")
        do {
            let key = PersistentSidecarKey(
                pythonPath: pythonURL.standardizedFileURL.path,
                scriptPath: scriptURL.standardizedFileURL.path,
                modelSignature: "cellpose4|\(resolvedModelName)|gpu=\(input.useGPU)")
            outcome = try await ReusableSidecarRunner.run(
                key: key,
                pythonURL: pythonURL,
                scriptURL: scriptURL,
                requestArgs: requestArgs) { line in
                NotificationCenter.default.post(
                    name: detectionStageNotification,
                    object: nil,
                    userInfo: ["line": line])
            }
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
        return try SidecarPayload.decodeResult(stdout: outcome.stdout, exitCode: outcome.exitCode)
    }

    /// Resolve which cellpose 4.x checkpoint to run.
    ///
    /// Never returns an id the cp4 family doesn't own — a stray 3.x id would
    /// otherwise be forwarded to `pretrained_model=` and fail deep inside
    /// cellpose. `cpsam` is the documented v4 default, so that's the floor.
    static func resolvedModelName(_ primary: String, fallback: String) -> String {
        if isKnownModelId(primary) { return primary }
        if isKnownModelId(fallback) { return fallback }
        return "cpsam"
    }
}
