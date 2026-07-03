import Foundation

/// Family-specific `DetectionService` for the Cellpose pipeline.
///
/// Instantiated per-model-id (cp-cyto3, cp-cyto3-r, cp-cyto2, cp-nuclei) so the
/// registry can route a detection call straight to the right cellpose
/// `model_type` string + flags. Any missing-binary / non-zero exit / parse
/// failure throws a `DetectionError` so the UI can surface the real cause.
struct CellposeDetectionService: DetectionService {
    let modelId: String

    /// App model id -> cellpose `model_type` string passed via `--model`.
    /// Note `cp-cyto3-r` also pipes through with `--restore`.
    private static let modelTypeMap: [String: String] = [
        "cp-cyto3":   "cyto3",
        "cp-cyto3-r": "cyto3",
        "cp-cyto2":   "cyto2",
        "cp-nuclei":  "nuclei",
    ]

    private static let restoreModelIds: Set<String> = ["cp-cyto3-r"]

    init(modelId: String) {
        self.modelId = modelId
    }

    func detect(_ input: DetectionInput) async throws -> DetectionResult {
        // Resolve sidecar paths via the shared availability probe so we share the
        // venv created by `scripts/install_python.sh` with the rest of the app.
        let availability = CellposeAvailability.detect()
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

        // The DetectionInput's modelId tells us what the *caller* asked for; we
        // prefer our own `modelId` (set at init) when it's a known cellpose id
        // so the registry's routing decision wins. If neither matches, forward
        // the caller's id verbatim and let the sidecar's `cp-` prefix-strip kick in.
        let resolvedAppId = Self.modelTypeMap[modelId] != nil ? modelId : input.modelId
        let cellposeModel = Self.modelTypeMap[resolvedAppId] ?? resolvedAppId
        let needsRestore = Self.restoreModelIds.contains(resolvedAppId)

        let channelArg = input.channels.map(String.init).joined(separator: ",")
        let isDefaultChannels = (input.channels == [0, 0] || input.channels.isEmpty)

        var args = [
            scriptURL.path,
            "--image", imageURL.path,
            "--model", cellposeModel,
            "--pxPerUm", String(input.pxPerUm),
            "--conf", String(input.confidenceThreshold),
        ]
        if !isDefaultChannels {
            args += ["--channels", channelArg]
        }
        if needsRestore {
            args += ["--restore"]
        }
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
            args += ["--no-gpu"]
        }

        let outcome: SidecarOutcome
        do {
            // Stream stderr lines into a `ccDetectionStage` notification so the
            // UI shows what cellpose is doing (loading model, computing flows,
            // running dynamics, …) instead of sitting at 0% for 60–90s.
            outcome = try await SidecarProcessRunner.run(pythonURL: pythonURL, args: args) { line in
                NotificationCenter.default.post(
                    name: .ccDetectionStage,
                    object: nil,
                    userInfo: ["line": line])
            }
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

}
