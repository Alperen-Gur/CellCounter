import Foundation

/// `DetectionService` for Omnipose — bacteria and anything filamentous or
/// elongated, where Cellpose's round-cell diameter prior actively hurts.
///
/// Runs `Resources/python/omnipose_detect.py` inside the isolated
/// `python/venv_omni/` interpreter that `OmniposeDownloader` provisions.
/// Structurally the sibling of `CellposeSAMDetectionService`: different venv,
/// different sidecar, identical JSON contract on the way back.
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

        var args = [
            scriptURL.path,
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
        args += ChannelStackSettings.sidecarArguments()
        if input.backgroundSubtract {
            args += ["--bg-subtract", "--rolling-ball-radius", String(input.rollingBallRadius)]
        }
        if input.watershedSplit {
            args += ["--watershed",
                     "--watershed-min-distance", String(input.watershedMinDistance)]
        }
        args += [
            "--small-threshold", String(input.smallThreshold),
            "--large-threshold", String(input.largeThreshold),
        ]
        // Deliberately NOT defaulted from the size bins. Omnipose's whole
        // premise is that an elongated cell has no meaningful "diameter", and
        // its own docs recommend leaving the prior unset for the omni models.
        // We forward a diameter only when the user explicitly pinned one.
        let expectedDiameterUm = UserDefaults.standard.double(forKey: "cc-expected-diameter")
        if expectedDiameterUm > 0 {
            args += ["--diameter", String(expectedDiameterUm)]
        }
        if !input.useGPU {
            args += ["--no-gpu"]
        }

        let outcome: SidecarOutcome
        do {
            outcome = try await SidecarProcessRunner.run(pythonURL: pythonURL, args: args) { line in
                NotificationCenter.default.post(
                    name: .ccDetectionStage, object: nil, userInfo: ["line": line])
            }
        } catch {
            throw DetectionError.sidecarFailed(exitCode: -1, stderr: error.localizedDescription)
        }

        try outcome.throwIfFailed()
        return try SidecarPayload.decodeResult(stdout: outcome.stdout, exitCode: outcome.exitCode)
    }

    private static func resolveScriptURL() -> URL? {
        if let staged = PythonRuntime.stagedScriptURL(named: "omnipose_detect.py") {
            return staged
        }
        return PythonRuntime.bundledPythonURL(named: "omnipose_detect.py")
    }
}
