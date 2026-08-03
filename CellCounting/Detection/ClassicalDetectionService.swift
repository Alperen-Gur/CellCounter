import Foundation

/// `DetectionService` for the deep-learning-free detector: threshold →
/// distance transform → watershed → label, via `classical_detect.py`.
///
/// No weights, no download, no GPU, no network. It runs in the shared `venv/`
/// because it needs scikit-image and scipy, both of which `install_python.sh`
/// already installs — so there is no per-model install step and nothing to
/// keep up to date.
///
/// It is deterministic: the same image and the same arguments always produce
/// the same labels. That makes it the detector to use when a figure has to be
/// exactly reproducible, when the machine has no GPU or no network, and as the
/// cheapest possible second opinion inside the Ensemble family.
struct ClassicalDetectionService: DetectionService {
    let modelId: String

    init(modelId: String) {
        self.modelId = modelId
    }

    /// Catalog id → `--threshold-method`. Kept here (rather than only in
    /// Python) so an unknown id fails Swift-side instead of silently
    /// defaulting to Otsu after a process spawn.
    static let methodMap: [String: String] = [
        "cw-otsu":     "otsu",
        "cw-triangle": "triangle",
        "cw-adaptive": "adaptive",
        "cw-manual":   "manual",
        "cw-li":       "li",
        "cw-yen":      "yen",
        "cw-mean":     "mean",
    ]

    /// UserDefaults key for the `cw-manual` cutoff, in the image's own
    /// intensity units (0–255 for 8-bit). 0 means "not set", in which case the
    /// sidecar falls back to Otsu rather than producing an empty mask.
    static let manualThresholdKey = "cc-classical-manual-threshold"

    static func isKnownModelId(_ id: String) -> Bool { methodMap[id] != nil }

    func detect(_ input: DetectionInput) async throws -> DetectionResult {
        let resolvedId = Self.methodMap[input.modelId] != nil ? input.modelId : modelId
        guard let method = Self.methodMap[resolvedId] else {
            throw DetectionError.modelNotInstalled(modelId: resolvedId)
        }

        // Shares the base venv — the classical pipeline needs scikit-image and
        // scipy, which live there. Nothing Cellpose-specific is imported.
        let pythonURL: URL
        switch CellposeAvailability.detect() {
        case .available(let py, _):
            pythonURL = py
        case .missingScripts, .missingVenv, .missingInstaller, .venvBroken:
            throw DetectionError.sidecarFailed(
                exitCode: 0,
                stderr: "The classical detector needs the base Python environment "
                      + "(scikit-image + scipy). Open Models and install Cellpose once — "
                      + "after that this detector never needs another download.")
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
            "--threshold-method", method,
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
        if method == "manual" {
            let value = UserDefaults.standard.double(forKey: Self.manualThresholdKey)
            if value > 0 {
                args += ["--threshold-value", String(value)]
            }
        }
        if input.backgroundSubtract {
            args += ["--bg-subtract", "--rolling-ball-radius", String(input.rollingBallRadius)]
        }
        // The classical pipeline always watersheds — that IS the detector — so
        // we forward the seed spacing unconditionally. Passing `--watershed`
        // as well is harmless (the sidecar recognises it as already implied)
        // but pointless, so we don't.
        args += ["--watershed-min-distance", String(input.watershedMinDistance)]
        args += [
            "--small-threshold", String(input.smallThreshold),
            "--large-threshold", String(input.largeThreshold),
        ]
        // An explicit expected diameter is a genuinely useful prior here: it
        // widens the watershed seed spacing so two cells of diameter D aren't
        // split into four fragments.
        let expectedDiameterUm = UserDefaults.standard.double(forKey: "cc-expected-diameter")
        if expectedDiameterUm > 0 {
            args += ["--diameter", String(expectedDiameterUm)]
        }
        // Always CPU — pass the flag so the sidecar's device log line is honest.
        args += ["--no-gpu"]

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
        if let staged = PythonRuntime.stagedScriptURL(named: "classical_detect.py") {
            return staged
        }
        return PythonRuntime.bundledPythonURL(named: "classical_detect.py")
    }
}

// MARK: — Downloader

/// `ModelDownloader` for the Classical family — the always-available one.
///
/// There is genuinely nothing to install: no weights, no pip package beyond
/// what the base environment already has. `install()` exists only to satisfy
/// the protocol and reports ready immediately, and `isInstalled` is true as
/// soon as the base venv exists.
///
/// That "no install step" property is what makes this family usable as a
/// fallback — `ModelCatalog.classicalFallbackId` resolves to a working
/// detector on any machine where the app has ever run a detection, with no
/// network and no GPU.
struct ClassicalDownloader: ModelDownloader {
    let family: ModelFamily = .classical

    func isInstalled(modelId: String) -> Bool {
        guard ClassicalDetectionService.isKnownModelId(modelId) else { return false }
        // Filesystem only — safe to call during view body evaluation.
        if case .available = CellposeAvailability.detect() { return true }
        return false
    }

    func probeInstalled(modelId: String) async -> Bool {
        // No subprocess needed: scikit-image and scipy are guaranteed by
        // install_python.sh, so venv presence is the whole answer.
        await MainActor.run { isInstalled(modelId: modelId) }
    }

    func install(modelId: String, progress: ModelInstallProgress) async throws {
        await MainActor.run {
            progress.append("[classical] no download required — scikit-image only")
        }
        guard ClassicalDetectionService.isKnownModelId(modelId) else {
            throw NSError(domain: "ClassicalDownloader", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Unknown classical model id: \(modelId)",
            ])
        }
        if case .available = CellposeAvailability.detect() {
            await MainActor.run { progress.stage = .ready }
            return
        }
        throw NSError(domain: "ClassicalDownloader", code: 2, userInfo: [
            NSLocalizedDescriptionKey:
                "The classical detector needs the base Python environment "
              + "(scikit-image + scipy). Install Cellpose once from Models; "
              + "this detector then works forever without another download.",
        ])
    }

    @MainActor
    func uninstall(modelId: String) throws {
        // Nothing on disk belongs to this family.
    }

    @MainActor
    func diskUsageBytes(modelId: String) -> Int64 { 0 }

    @MainActor
    func detector(for modelId: String) -> DetectionService? {
        guard ClassicalDetectionService.isKnownModelId(modelId) else { return nil }
        return ClassicalDetectionService(modelId: modelId)
    }
}
