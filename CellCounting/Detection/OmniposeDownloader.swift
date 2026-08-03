import Foundation

/// `ModelDownloader` for the Omnipose family.
///
/// Omnipose gets its OWN virtualenv, `python/venv_omni/`, for the same reason
/// Cellpose-SAM gets `venv4/`: the `omnipose` package pulls `cellpose_omni`, a
/// Cellpose fork that pins an older numpy/torch tail. Installing it into the
/// shared `venv/` would break Cellpose 3.x, and into `venv4/` would break
/// `cellpose>=4`. Three independent environments, three independent installs,
/// no shared pins.
///
/// Unlike the Cellpose families there is no bundled `install_python_omni.sh`.
/// The venv is created and populated directly from here with
/// `/usr/bin/env python3 -m venv` followed by `pip install`, which keeps the
/// whole install self-contained in one file — no extra shell script to stage
/// through `PythonRuntime`, and no extra entry in the Xcode copy phase. The
/// on-disk shape (own venv dir, own sentinel, own cached probe key) matches
/// the Cellpose-SAM pattern exactly.
///
/// Weights are small (~26 MB per model) and are fetched lazily by
/// `cellpose_omni` on the first detection run, into `~/.cellpose_omni/models/`.
struct OmniposeDownloader: ModelDownloader {
    let family: ModelFamily = .omnipose

    /// Catalog id → Omnipose pretrained name. Mirrors `_MODEL_MAP` in
    /// `omnipose_detect.py`; the sidecar re-resolves so either can be extended
    /// first, but keeping both means an unknown id fails before we spawn.
    static let modelMap: [String: String] = [
        "omni-bact-phase": "bact_phase_omni",
        "omni-bact-fluor": "bact_fluor_omni",
        "omni-cyto2":      "cyto2_omni",
        "omni-worm":       "worm_omni",
        "omni-plant":      "plant_omni",
    ]

    static func isKnownModelId(_ id: String) -> Bool { modelMap[id] != nil }

    /// Distinct from the 3.x / 4.x keys so the three probes never clobber
    /// each other.
    static let importableCacheKey = "cc-omnipose-importable"

    // MARK: — Paths

    /// `~/Library/Application Support/CellCounter/python/venv_omni/`
    static var venvDir: URL {
        FileStore.shared.pythonDir.appendingPathComponent("venv_omni", isDirectory: true)
    }

    /// Written when an install starts, removed only on a clean finish. Its
    /// presence means the last install died mid-pip, so the venv may have a
    /// python but no working omnipose — the same trick both Cellpose
    /// installers use.
    static var installIncompleteSentinel: URL {
        FileStore.shared.pythonDir.appendingPathComponent(".cc-install-incomplete-omni")
    }

    static func interpreter() -> URL? {
        let fm = FileManager.default
        if fm.fileExists(atPath: installIncompleteSentinel.path) { return nil }
        let bin = venvDir.appendingPathComponent("bin")
        let py3 = bin.appendingPathComponent("python3")
        let py = bin.appendingPathComponent("python")
        if fm.isExecutableFile(atPath: py3.path) { return py3 }
        if fm.isExecutableFile(atPath: py.path) { return py }
        return nil
    }

    /// `~/.cellpose_omni/models/` — where `cellpose_omni` caches weights.
    private static var weightsDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cellpose_omni/models", isDirectory: true)
    }

    // MARK: — isInstalled (cheap, main-safe)

    func isInstalled(modelId: String) -> Bool {
        guard Self.isKnownModelId(modelId) else { return false }
        guard Self.interpreter() != nil else { return false }
        // Cached answer only — never fork a process from here.
        return (UserDefaults.standard.object(forKey: Self.importableCacheKey) as? Bool) ?? false
    }

    // MARK: — probeInstalled (deep, off-main)

    func probeInstalled(modelId: String) async -> Bool {
        guard Self.isKnownModelId(modelId) else { return false }
        guard let py = Self.interpreter() else { return false }
        return await Task.detached(priority: .userInitiated) {
            let ok = Self.runImportProbe(pythonURL: py)
            UserDefaults.standard.set(ok, forKey: Self.importableCacheKey)
            return ok
        }.value
    }

    // MARK: — install

    func install(modelId: String, progress: ModelInstallProgress) async throws {
        guard Self.isKnownModelId(modelId) else {
            throw OmniposeInstallError.unknownModel(modelId)
        }
        await MainActor.run { progress.stage = .checkingDependencies }

        // Fast path — already importable in a healthy venv.
        if let py = Self.interpreter(), Self.runImportProbe(pythonURL: py) {
            UserDefaults.standard.set(true, forKey: Self.importableCacheKey)
            await MainActor.run {
                progress.append("[omnipose] already installed; nothing to do")
                progress.stage = .ready
            }
            return
        }

        let fm = FileManager.default
        try? fm.createDirectory(at: FileStore.shared.pythonDir, withIntermediateDirectories: true)

        // A venv dir with no pip is a corpse from an interrupted run — remove
        // it rather than trying to install into it.
        let venv = Self.venvDir
        let pipURL = venv.appendingPathComponent("bin/pip")
        if fm.fileExists(atPath: venv.path) && !fm.fileExists(atPath: pipURL.path) {
            await MainActor.run {
                progress.append("[omnipose] removing half-installed venv at \(venv.path)")
            }
            try? fm.removeItem(at: venv)
        }

        // Sentinel down before any long-running work, cleared only on success.
        try? Data().write(to: Self.installIncompleteSentinel)
        UserDefaults.standard.set(false, forKey: Self.importableCacheKey)

        // 1) Create the venv.
        if !fm.fileExists(atPath: venv.path) {
            await MainActor.run {
                progress.stage = .installingDependencies(line: "creating venv_omni…")
                progress.append("[omnipose] creating venv at \(venv.path)")
            }
            try await Self.runStreaming(
                executable: URL(fileURLWithPath: "/usr/bin/env"),
                args: ["python3", "-m", "venv", venv.path],
                progress: progress)
        } else {
            await MainActor.run { progress.append("[omnipose] reusing existing venv_omni") }
        }

        guard let python = Self.interpreterIgnoringSentinel() else {
            throw OmniposeInstallError.venvCreationFailed(venv.path)
        }

        // 2) Upgrade pip, then install the stack.
        await MainActor.run {
            progress.stage = .installingDependencies(line: "upgrading pip…")
        }
        try await Self.runStreaming(executable: python,
                                    args: ["-m", "pip", "install", "--upgrade", "pip"],
                                    progress: progress)

        await MainActor.run {
            progress.stage = .installingDependencies(line: "installing omnipose…")
            progress.append("[omnipose] pip install omnipose (this pulls torch — several minutes)")
        }
        // `omnipose` brings `cellpose_omni` with it. numpy<2 matches what the
        // Omnipose stack expects, same constraint the Cellpose installers use.
        try await Self.runStreaming(
            executable: python,
            args: ["-m", "pip", "install", "--no-input",
                   "omnipose", "numpy<2", "pillow", "scikit-image", "torch", "torchvision"],
            progress: progress)

        // 3) Verify.
        await MainActor.run { progress.stage = .verifying }
        let importable = Self.runImportProbe(pythonURL: python)
        UserDefaults.standard.set(importable, forKey: Self.importableCacheKey)
        if !importable {
            throw OmniposeInstallError.notImportableAfterInstall
        }

        try? fm.removeItem(at: Self.installIncompleteSentinel)
        await MainActor.run {
            progress.append("[omnipose] import verified — weights download on first detection")
            progress.stage = .ready
        }
    }

    // MARK: — uninstall

    @MainActor
    func uninstall(modelId: String) throws {
        // Remove only this family's weight cache. The venv is shared across all
        // omni-* ids, so it stays until the user resets storage — same policy
        // the Cellpose downloaders use for their venvs.
        let dir = Self.weightsDir
        if FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.removeItem(at: dir)
        }
        UserDefaults.standard.removeObject(forKey: Self.importableCacheKey)
    }

    // MARK: — diskUsageBytes

    @MainActor
    func diskUsageBytes(modelId: String) -> Int64 {
        Self.directorySize(at: Self.venvDir) + Self.directorySize(at: Self.weightsDir)
    }

    // MARK: — detector

    @MainActor
    func detector(for modelId: String) -> DetectionService? {
        guard Self.isKnownModelId(modelId) else { return nil }
        return OmniposeDetectionService(modelId: modelId)
    }

    // MARK: — Helpers

    /// Interpreter lookup that ignores the incomplete-install sentinel. Used
    /// DURING an install, when the sentinel is deliberately present.
    private static func interpreterIgnoringSentinel() -> URL? {
        let fm = FileManager.default
        let bin = venvDir.appendingPathComponent("bin")
        let py3 = bin.appendingPathComponent("python3")
        let py = bin.appendingPathComponent("python")
        if fm.isExecutableFile(atPath: py3.path) { return py3 }
        if fm.isExecutableFile(atPath: py.path) { return py }
        return nil
    }

    /// `python -c "import cellpose_omni"`. Blocking — callers hop off-main.
    private static func runImportProbe(pythonURL: URL) -> Bool {
        guard FileManager.default.isExecutableFile(atPath: pythonURL.path) else { return false }
        let p = Process()
        p.executableURL = pythonURL
        p.arguments = ["-c", "import cellpose_omni, omnipose"]
        p.standardOutput = Pipe()
        p.standardError = Pipe()
        do {
            try p.run()
            p.waitUntilExit()
            return p.terminationStatus == 0
        } catch {
            return false
        }
    }

    private static func directorySize(at url: URL) -> Int64 {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else { return 0 }
        guard let it = fm.enumerator(at: url,
                                     includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .fileSizeKey],
                                     options: [.skipsHiddenFiles]) else { return 0 }
        var total: Int64 = 0
        for case let fileURL as URL in it {
            let vals = try? fileURL.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileSizeKey])
            total += Int64(vals?.totalFileAllocatedSize ?? vals?.fileSize ?? 0)
        }
        return total
    }

    /// Spawn a process off the MainActor and stream both pipes into `progress`.
    /// Throws on non-zero exit, with the last few lines for context.
    private static func runStreaming(executable: URL,
                                     args: [String],
                                     progress: ModelInstallProgress) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            Task.detached(priority: .userInitiated) {
                let process = Process()
                process.executableURL = executable
                process.arguments = args

                let outPipe = Pipe()
                let errPipe = Pipe()
                process.standardOutput = outPipe
                process.standardError = errPipe

                let tail = OmniposeTailBuffer(capacity: 8)
                let resumed = OmniposeResumeFlag()

                let forward: (FileHandle) -> Void = { handle in
                    handle.readabilityHandler = { fh in
                        let data = fh.availableData
                        if data.isEmpty {
                            fh.readabilityHandler = nil
                            return
                        }
                        guard let text = String(data: data, encoding: .utf8) else { return }
                        for raw in text.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
                            let line = String(raw).trimmingCharacters(in: .whitespaces)
                            if line.isEmpty { continue }
                            tail.push(line)
                            Task { @MainActor in
                                progress.append(line)
                                progress.stage = .installingDependencies(line: line)
                            }
                        }
                    }
                }
                forward(outPipe.fileHandleForReading)
                forward(errPipe.fileHandleForReading)

                process.terminationHandler = { proc in
                    outPipe.fileHandleForReading.readabilityHandler = nil
                    errPipe.fileHandleForReading.readabilityHandler = nil
                    guard resumed.markAndCheck() else { return }
                    if proc.terminationStatus == 0 {
                        cont.resume()
                    } else {
                        let recent = tail.snapshot().joined(separator: " | ")
                        cont.resume(throwing: OmniposeInstallError.processFailed(
                            command: executable.lastPathComponent,
                            code: proc.terminationStatus,
                            tail: recent))
                    }
                }

                do {
                    try process.run()
                    // Register so quitting mid-install SIGTERMs the pip child
                    // rather than orphaning a multi-minute download.
                    Task { @MainActor in
                        ChildProcessTracker.shared.register(process, kind: .install)
                    }
                } catch {
                    outPipe.fileHandleForReading.readabilityHandler = nil
                    errPipe.fileHandleForReading.readabilityHandler = nil
                    if resumed.markAndCheck() { cont.resume(throwing: error) }
                }
            }
        }
    }
}

// MARK: — Errors

enum OmniposeInstallError: LocalizedError {
    case unknownModel(String)
    case venvCreationFailed(String)
    case notImportableAfterInstall
    case processFailed(command: String, code: Int32, tail: String)

    var errorDescription: String? {
        switch self {
        case .unknownModel(let id):
            return "Unknown Omnipose model id: \(id)"
        case .venvCreationFailed(let path):
            return "Couldn't create the Omnipose environment at \(path). "
                 + "Check that `python3 -m venv` works on this machine."
        case .notImportableAfterInstall:
            return "pip finished but `import cellpose_omni` still fails. "
                 + "The Omnipose environment is incomplete — try installing again."
        case .processFailed(let command, let code, let tail):
            return "\(command) exited with code \(code). \(tail)"
        }
    }
}

// MARK: — File-private concurrency helpers

/// Bounded ring buffer of the most recent output lines, so a failure message
/// can carry context without holding the whole log.
private final class OmniposeTailBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []
    private let capacity: Int
    init(capacity: Int) { self.capacity = capacity }
    func push(_ line: String) {
        lock.lock(); defer { lock.unlock() }
        items.append(line)
        if items.count > capacity { items.removeFirst(items.count - capacity) }
    }
    func snapshot() -> [String] {
        lock.lock(); defer { lock.unlock() }
        return items
    }
}

/// One-shot guard for the Process termination handler.
private final class OmniposeResumeFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false
    func markAndCheck() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if fired { return false }
        fired = true
        return true
    }
}
