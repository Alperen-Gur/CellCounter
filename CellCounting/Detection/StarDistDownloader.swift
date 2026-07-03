import Foundation

/// `ModelDownloader` for the StarDist family.
///
/// Shares the same Python venv that `CellposeAvailability.detect()` resolves —
/// every family installs into the single venv created by `scripts/install_python.sh`.
///
/// StarDist itself caches its pretrained weights under `~/.keras/stardist/<model_name>/`
/// (in a sandboxed app, "~" resolves to the container). We never download the
/// weights ourselves; we ask the StarDist library to prefetch them and then ask
/// it again at detection time. Uninstall removes only the per-model weight dir
/// and leaves the (shared) Python package in place.
struct StarDistDownloader: ModelDownloader {
    let family: ModelFamily = .stardist

    // MARK: — Model id mapping

    /// Maps the app's catalog ids to the canonical StarDist pretrained names.
    static let modelMap: [String: String] = [
        "sd-fluo": "2D_versatile_fluo",
        "sd-he":   "2D_versatile_he",
        "sd-dsb":  "2D_paper_dsb2018",
    ]

    private static func resolvedName(for modelId: String) -> String {
        modelMap[modelId] ?? modelId
    }

    // MARK: — Per-session install cache

    /// Tracks whether `import stardist` succeeded already this session, so we
    /// don't shell out for `isInstalled` every time the list refreshes.
    /// Keyed by python executable path to invalidate if the venv moves.
    private static let importCache = PythonModuleImportCache(module: "stardist")

    /// Cheap, main-safe. The expensive `import stardist` check is
    /// only consulted from `Self.importCache`, which caches an answer per
    /// python path. If we have no cached answer, treat as not-installed —
    /// `probeInstalled(modelId:)` will fill in the cache off-main.
    func isInstalled(modelId: String) -> Bool {
        guard case .available(let py, _) = CellposeAvailability.detect() else { return false }
        // Cached-only lookup: never forks a process.
        guard Self.importCache.cachedAnswer(pythonURL: py) == true else { return false }
        // Weights are present iff the model directory exists on disk.
        return Self.weightsDirURL(for: modelId).map {
            var isDir: ObjCBool = false
            return FileManager.default.fileExists(atPath: $0.path, isDirectory: &isDir) && isDir.boolValue
        } ?? false
    }

    func probeInstalled(modelId: String) async -> Bool {
        let py: URL? = {
            if case .available(let p, _) = CellposeAvailability.detect() { return p }
            return nil
        }()
        guard let py else { return false }
        // Deep probe runs off-main; result is cached so `isInstalled` returns truth next time.
        let importable = await Task.detached(priority: .userInitiated) {
            Self.importCache.isImportable(pythonURL: py)
        }.value
        if !importable { return false }
        guard let weightsDir = Self.weightsDirURL(for: modelId) else { return false }
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: weightsDir.path, isDirectory: &isDir) && isDir.boolValue
    }

    func install(modelId: String, progress: ModelInstallProgress) async throws {
        await progress.setStage(.checkingDependencies)

        let availability = CellposeAvailability.detect()
        let pythonURL: URL
        switch availability {
        case .available(let py, _):
            pythonURL = py
        case .missingVenv, .missingInstaller, .missingScripts:
            throw NSError(domain: "StarDistDownloader", code: 1, userInfo: [
                NSLocalizedDescriptionKey:
                    "Python venv not found. Run scripts/install_python.sh first."
            ])
        case .venvBroken(let reason):
            throw NSError(domain: "StarDistDownloader", code: 1, userInfo: [
                NSLocalizedDescriptionKey:
                    "Python venv is broken: \(reason) Reinstall from the Models tab."
            ])
        }

        // 1) Install stardist + tensorflow + csbdeep if needed.
        if !Self.importCache.isImportable(pythonURL: pythonURL) {
            await progress.appendAsync("[stardist] installing python dependencies …")
            try await Self.pipInstallStarDistStack(pythonURL: pythonURL, progress: progress)
            Self.importCache.invalidate(pythonURL: pythonURL)
            // Re-check; surface a clean error if pip silently failed.
            if !Self.importCache.isImportable(pythonURL: pythonURL) {
                throw NSError(domain: "StarDistDownloader", code: 2, userInfo: [
                    NSLocalizedDescriptionKey:
                        "pip install completed but `import stardist` still fails."
                ])
            }
        } else {
            await progress.appendAsync("[stardist] python deps already present")
        }

        // 2) Prefetch the requested pretrained model so the first detect call is fast.
        let modelName = Self.resolvedName(for: modelId)
        await progress.setStage(.downloading(progress: 0, bytesPerSec: nil))
        await progress.appendAsync("[stardist] downloading weights for \(modelName) …")
        try await Self.prefetchModel(pythonURL: pythonURL,
                                     modelName: modelName,
                                     progress: progress)

        // 3) Verify the weights directory is now on disk.
        await progress.setStage(.verifying)
        guard let weightsDir = Self.weightsDirURL(for: modelId) else {
            throw NSError(domain: "StarDistDownloader", code: 3, userInfo: [
                NSLocalizedDescriptionKey: "Could not resolve StarDist weights directory."
            ])
        }
        var isDir: ObjCBool = false
        if !FileManager.default.fileExists(atPath: weightsDir.path, isDirectory: &isDir) || !isDir.boolValue {
            await progress.appendAsync("[stardist] warning: weights dir missing after prefetch: \(weightsDir.path)")
            // The from_pretrained call may have cached to a slightly different
            // location on some versions — don't fail outright, just warn.
        }
        await progress.appendAsync("[stardist] ready")
    }

    @MainActor
    func uninstall(modelId: String) throws {
        guard let weightsDir = Self.weightsDirURL(for: modelId) else { return }
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: weightsDir.path, isDirectory: &isDir), isDir.boolValue {
            try FileManager.default.removeItem(at: weightsDir)
        }
        // Leave the shared `stardist` package in place — other sd-* ids may need it.
    }

    @MainActor
    func diskUsageBytes(modelId: String) -> Int64 {
        guard let weightsDir = Self.weightsDirURL(for: modelId) else { return 0 }
        return Self.directorySize(at: weightsDir)
    }

    @MainActor
    func detector(for modelId: String) -> DetectionService? {
        guard Self.modelMap[modelId] != nil else { return nil }
        return StarDistDetectionService(modelId: modelId)
    }

    // MARK: — Weights directory

    /// `~/.keras/stardist/<model_name>/` — same path StarDist itself uses.
    /// In a sandbox, the home dir is the container.
    static func weightsDirURL(for modelId: String) -> URL? {
        guard let name = modelMap[modelId] else { return nil }
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home
            .appendingPathComponent(".keras")
            .appendingPathComponent("stardist")
            .appendingPathComponent(name)
    }

    private static func directorySize(at url: URL) -> Int64 {
        let fm = FileManager.default
        guard let it = fm.enumerator(at: url,
                                      includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey],
                                      options: [.skipsHiddenFiles]) else { return 0 }
        var total: Int64 = 0
        for case let fileURL as URL in it {
            let vals = try? fileURL.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey])
            let bytes = vals?.totalFileAllocatedSize ?? vals?.fileAllocatedSize ?? 0
            total += Int64(bytes)
        }
        return total
    }

    // MARK: — Subprocess helpers

    /// Decide which TensorFlow distribution to install based on CPU arch.
    /// Apple Silicon (arm64) gets `tensorflow-macos` + `tensorflow-metal`; everything else
    /// gets plain `tensorflow`. The metal plugin gives us GPU acceleration via MPS.
    private static func tensorflowPackages() -> [String] {
        var sysinfo = utsname()
        uname(&sysinfo)
        // `utsname.machine` is a fixed-size C char array; reinterpret as a
        // NUL-terminated C string. 256 is the max length on Darwin.
        let machine = withUnsafePointer(to: &sysinfo.machine) { ptr -> String in
            ptr.withMemoryRebound(to: CChar.self, capacity: 256) { String(cString: $0) }
        }
        if machine == "arm64" {
            return ["tensorflow-macos==2.16.*", "tensorflow-metal"]
        }
        return ["tensorflow"]
    }

    private static func pipInstallStarDistStack(pythonURL: URL,
                                                progress: ModelInstallProgress) async throws {
        var packages = ["stardist", "csbdeep"]
        packages.append(contentsOf: tensorflowPackages())

        let args = ["-m", "pip", "install", "--upgrade"] + packages
        try await runStreaming(pythonURL: pythonURL,
                               args: args,
                               stageOnLine: { line in
                                   await progress.setStage(.installingDependencies(line: line))
                                   await progress.appendAsync(line)
                               })
    }

    /// Prefetch the model weights by invoking `from_pretrained` once. Streams the
    /// python-side stderr lines through `progress.append`.
    private static func prefetchModel(pythonURL: URL,
                                      modelName: String,
                                      progress: ModelInstallProgress) async throws {
        // Single -c expression keeps argv simple and shell-quote-free.
        let snippet = """
        import sys
        try:
            from stardist.models import StarDist2D
            StarDist2D.from_pretrained('\(modelName)')
            sys.stderr.write('[prefetch] ok: \(modelName)\\n')
        except Exception as exc:
            sys.stderr.write('[prefetch] failed: ' + repr(exc) + '\\n')
            raise
        """
        try await runStreaming(pythonURL: pythonURL,
                               args: ["-c", snippet],
                               stageOnLine: { line in
                                   await progress.appendAsync(line)
                               })
    }

    /// Spawn `python <args>` off the MainActor and stream stdout+stderr lines
    /// into `onLine`. Throws on non-zero exit.
    private static func runStreaming(pythonURL: URL,
                                     args: [String],
                                     stageOnLine onLine: @escaping @Sendable (String) async -> Void) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            Task.detached(priority: .userInitiated) {
                let process = Process()
                process.executableURL = pythonURL
                process.arguments = args

                let outPipe = Pipe()
                let errPipe = Pipe()
                process.standardOutput = outPipe
                process.standardError = errPipe

                let resumed = StarDistResumeFlag()

                // Line-buffered streaming for both pipes.
                let outHandler = LineStreamer { line in
                    Task { await onLine(line) }
                }
                let errHandler = LineStreamer { line in
                    Task { await onLine(line) }
                }
                outPipe.fileHandleForReading.readabilityHandler = { handle in
                    let data = handle.availableData
                    if data.isEmpty {
                        outPipe.fileHandleForReading.readabilityHandler = nil
                    } else {
                        outHandler.feed(data)
                    }
                }
                errPipe.fileHandleForReading.readabilityHandler = { handle in
                    let data = handle.availableData
                    if data.isEmpty {
                        errPipe.fileHandleForReading.readabilityHandler = nil
                    } else {
                        errHandler.feed(data)
                    }
                }

                process.terminationHandler = { proc in
                    outPipe.fileHandleForReading.readabilityHandler = nil
                    errPipe.fileHandleForReading.readabilityHandler = nil
                    outHandler.flush()
                    errHandler.flush()
                    guard resumed.markAndCheck() else { return }
                    if proc.terminationStatus == 0 {
                        cont.resume(returning: ())
                    } else {
                        cont.resume(throwing: NSError(
                            domain: "StarDistDownloader",
                            code: Int(proc.terminationStatus),
                            userInfo: [NSLocalizedDescriptionKey:
                                "python exited with code \(proc.terminationStatus)"]))
                    }
                }

                do {
                    try process.run()
                } catch {
                    if resumed.markAndCheck() {
                        cont.resume(throwing: error)
                    }
                }
            }
        }
    }
}

// MARK: — Helpers (file-private types kept out of MainActor isolation)

/// Splits an incoming Data byte stream into newline-delimited UTF-8 lines and
/// hands each one to `emit`. Holds a small carry buffer between calls.
private final class LineStreamer: @unchecked Sendable {
    private var buffer = Data()
    private let emit: @Sendable (String) -> Void
    private let lock = NSLock()
    init(emit: @escaping @Sendable (String) -> Void) { self.emit = emit }

    func feed(_ data: Data) {
        lock.lock(); defer { lock.unlock() }
        buffer.append(data)
        while let nl = buffer.firstIndex(of: 0x0A) {
            let lineData = buffer.subdata(in: buffer.startIndex..<nl)
            buffer.removeSubrange(buffer.startIndex...nl)
            if let line = String(data: lineData, encoding: .utf8), !line.isEmpty {
                emit(line)
            }
        }
    }

    func flush() {
        lock.lock(); defer { lock.unlock() }
        if !buffer.isEmpty, let line = String(data: buffer, encoding: .utf8), !line.isEmpty {
            emit(line)
        }
        buffer.removeAll()
    }
}

/// One-shot guard for the Process termination handler.
private final class StarDistResumeFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false
    func markAndCheck() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if fired { return false }
        fired = true
        return true
    }
}

// MARK: — MainActor bridging for the progress object

private extension ModelInstallProgress {
    /// Async setter for `stage` that hops to the MainActor.
    func setStage(_ newStage: ModelInstallStage) async {
        await MainActor.run { self.stage = newStage }
    }

    /// Async wrapper around the MainActor-isolated `append(_:)`.
    /// Named differently so it doesn't shadow the sync version.
    func appendAsync(_ line: String) async {
        await MainActor.run { self.append(line) }
    }
}
