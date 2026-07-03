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

        var args = [
            scriptURL.path,
            "--image", imageURL.path,
            "--model", "cpsam",
            "--pxPerUm", String(input.pxPerUm),
            "--conf", String(input.confidenceThreshold),
        ]
        if !isDefaultChannels {
            args += ["--channels", channelArg]
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
