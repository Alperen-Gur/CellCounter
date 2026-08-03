import Foundation

/// `DetectionService` for a bring-your-own model — a Cellpose checkpoint or a
/// StarDist model directory the user trained somewhere else and registered in
/// the Models tab.
///
/// Runs `Resources/python/custom_detect.py`, which dispatches on
/// `--custom-kind` to either `CellposeModel(pretrained_model:)` or
/// `StarDist2D(None, name:, basedir:)` and then funnels through the same shared
/// measurement + emission path as every built-in detector, so the results are
/// directly comparable and export identically.
///
/// Which interpreter runs it depends on the entry's `runtime`:
///   * `.base`      → the shared `venv/` (Cellpose 3.x and StarDist live here)
///   * `.cellpose4` → the isolated `venv4/` (Cellpose-SAM checkpoints)
struct CustomModelDetectionService: DetectionService {
    let modelId: String

    init(modelId: String) {
        self.modelId = modelId
    }

    func detect(_ input: DetectionInput) async throws -> DetectionResult {
        // The host may hand us either the service's own id or the input's;
        // prefer the input so a mid-flight model switch can't run the wrong one.
        let resolvedId = CustomModelStore.isCustomId(input.modelId) ? input.modelId : modelId
        guard let entry = CustomModelStore.entry(for: resolvedId) else {
            throw DetectionError.modelNotInstalled(modelId: resolvedId)
        }

        // Fail before spawning Python when the model has been moved or deleted
        // since it was registered — the message from `validate` names the
        // actual problem, which a framework stack trace would not.
        do {
            try CustomModelStore.validate(path: entry.path, kind: entry.kind)
        } catch {
            throw DetectionError.sidecarFailed(
                exitCode: 0,
                stderr: "Custom model '\(entry.name)' can't be used: "
                      + (error.localizedDescription))
        }

        let pythonURL = try Self.interpreter(for: entry)

        guard let scriptURL = Self.resolveScriptURL() else {
            throw DetectionError.modelNotInstalled(modelId: resolvedId)
        }
        guard let imageURL = input.imageURL else {
            throw DetectionError.imageDecodeFailed
        }

        // Exactly the shared flag set every other sidecar takes, plus
        // --custom-kind. `--model` carries the absolute path.
        var args = [
            scriptURL.path,
            "--image", imageURL.path,
            "--model", entry.path,
            "--custom-kind", entry.kind.rawValue,
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
        // Same `--diameter` contract as the Cellpose services: 0 == "Auto" ==
        // omit the flag so the sidecar keeps its bin-derived prior.
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
        // A custom model can be a StarDist model directory, and loading one
        // drags in csbdeep/stardist — libraries that print banner lines to
        // STDOUT ("Found model …", "Loading network weights from …") ahead of
        // our JSON, which makes `JSONDecoder` fail on a leading `F`. The
        // sidecar-side silencing is the real fix; this is the same host-side
        // safety net `StarDistDetectionService` already applies, reused here
        // rather than duplicated.
        return try SidecarPayload.decodeResult(
            stdout: StarDistDetectionService.isolatingJSON(outcome.stdout),
            exitCode: outcome.exitCode)
    }

    // MARK: — Resolution

    /// Pick the interpreter for this entry's runtime, or throw a message that
    /// tells the user which environment they still need to install.
    static func interpreter(for entry: CustomModelEntry) throws -> URL {
        switch entry.runtime {
        case .base:
            if case .available(let py, _) = CellposeAvailability.detect() {
                return py
            }
            throw DetectionError.sidecarFailed(
                exitCode: 0,
                stderr: "Custom model '\(entry.name)' needs the base Python environment. "
                      + "Open Models and install Cellpose first.")
        case .cellpose4:
            if case .available(let py, _) = Cellpose4Availability.detect() {
                return py
            }
            throw DetectionError.sidecarFailed(
                exitCode: 0,
                stderr: "Custom model '\(entry.name)' is a Cellpose-SAM (4.x) checkpoint and "
                      + "needs that environment. Open Models and install Cellpose-SAM first.")
        }
    }

    /// Cheap, main-safe check that the runtime this entry needs exists.
    /// No subprocess — filesystem only, so it is safe from `isInstalled`.
    static func runtimeAvailable(for entry: CustomModelEntry) -> Bool {
        switch entry.runtime {
        case .base:
            if case .available = CellposeAvailability.detect() { return true }
            return false
        case .cellpose4:
            if case .available = Cellpose4Availability.detect() { return true }
            return false
        }
    }

    private static func resolveScriptURL() -> URL? {
        if let staged = PythonRuntime.stagedScriptURL(named: "custom_detect.py") {
            return staged
        }
        return PythonRuntime.bundledPythonURL(named: "custom_detect.py")
    }
}

// MARK: — Downloader

/// `ModelDownloader` for the Custom family.
///
/// There is nothing to download: the user already has the model. "Installed"
/// means the path still validates AND the Python environment it needs exists.
/// `install()` therefore only re-validates and reports — it never fetches
/// anything, and it is the code path the Models row's Get button hits if a
/// registered model's file goes missing.
struct CustomModelDownloader: ModelDownloader {
    let family: ModelFamily = .custom

    func isInstalled(modelId: String) -> Bool {
        guard let entry = CustomModelStore.entry(for: modelId) else { return false }
        guard (try? CustomModelStore.validate(path: entry.path, kind: entry.kind)) != nil else {
            return false
        }
        return CustomModelDetectionService.runtimeAvailable(for: entry)
    }

    func probeInstalled(modelId: String) async -> Bool {
        // Everything the check needs is a filesystem stat, so the deep probe is
        // the same as the cheap one. No subprocess to hop off-main for.
        await MainActor.run { isInstalled(modelId: modelId) }
    }

    func install(modelId: String, progress: ModelInstallProgress) async throws {
        await MainActor.run { progress.stage = .verifying }
        guard let entry = CustomModelStore.entry(for: modelId) else {
            throw NSError(domain: "CustomModelDownloader", code: 1, userInfo: [
                NSLocalizedDescriptionKey:
                    "This custom model is no longer registered. Add it again from Models.",
            ])
        }
        do {
            try CustomModelStore.validate(path: entry.path, kind: entry.kind)
        } catch {
            throw NSError(domain: "CustomModelDownloader", code: 2, userInfo: [
                NSLocalizedDescriptionKey: error.localizedDescription,
            ])
        }
        guard CustomModelDetectionService.runtimeAvailable(for: entry) else {
            throw NSError(domain: "CustomModelDownloader", code: 3, userInfo: [
                NSLocalizedDescriptionKey:
                    "\(entry.name) needs the \(entry.runtime.displayName). Install it from Models first.",
            ])
        }
        await MainActor.run {
            progress.append("[custom] \(entry.name) validated at \(entry.path)")
            progress.stage = .ready
        }
    }

    @MainActor
    func uninstall(modelId: String) throws {
        // Deregister only. We never delete the user's own model file — it lives
        // outside our storage and may be shared with other tools.
        CustomModelStore.remove(id: modelId)
    }

    @MainActor
    func diskUsageBytes(modelId: String) -> Int64 {
        guard let entry = CustomModelStore.entry(for: modelId) else { return 0 }
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: entry.path, isDirectory: &isDir) else { return 0 }
        if !isDir.boolValue {
            let attrs = try? fm.attributesOfItem(atPath: entry.path)
            return Int64((attrs?[.size] as? Int) ?? 0)
        }
        guard let it = fm.enumerator(at: entry.url,
                                     includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .fileSizeKey],
                                     options: [.skipsHiddenFiles]) else { return 0 }
        var total: Int64 = 0
        for case let fileURL as URL in it {
            let vals = try? fileURL.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileSizeKey])
            total += Int64(vals?.totalFileAllocatedSize ?? vals?.fileSize ?? 0)
        }
        return total
    }

    @MainActor
    func detector(for modelId: String) -> DetectionService? {
        guard CustomModelStore.entry(for: modelId) != nil else { return nil }
        return CustomModelDetectionService(modelId: modelId)
    }
}
