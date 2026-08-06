import Foundation

/// Pass-16: `ModelDownloader` for the Cellpose-SAM (4.x) family.
///
/// Sibling of `CellposeDownloader` (3.x). The two are deliberately kept as
/// SEPARATE downloaders rather than a generic+facade because:
///   * Each owns its own venv (`venv/` vs `venv4/`), install script, sentinel
///     file, and cached-probe key.
///   * The version-import probe predicate is *opposite* on either side:
///     3.x wants `major < 4`, 4.x wants `major >= 4`. Carving that into a
///     generic protocol-with-knobs hurts readability for negligible code
///     savings.
///
/// "Install" means `pip install cellpose>=4 …` into venv4. The ~1.15 GB CPSAM
/// transformer weights are NOT fetched here — cellpose 4 downloads them lazily
/// on the first `CellposeModel()` construction. C1's `cellpose4_detect.py`
/// surfaces that download to the UI via the existing ccDetectionStage pipeline,
/// so the user sees it as detection-progress lines rather than a silent hang.
struct CellposeSAMDownloader: ModelDownloader {
    let family: ModelFamily = .cellpose4

    /// Distinct from the 3.x cache key so the two probes don't clobber each other.
    private static let importableCacheKey = Cellpose4Availability.importableCacheKey

    // MARK: - isInstalled (cheap, main-safe)

    func isInstalled(modelId: String) -> Bool {
        guard let _ = Self.sharedPythonURL() else { return false }
        if let cached = UserDefaults.standard.object(forKey: Self.importableCacheKey) as? Bool {
            return cached
        }
        return false
    }

    // MARK: - probeInstalled (deep, off-main)

    func probeInstalled(modelId: String) async -> Bool {
        let python: URL? = await MainActor.run { Self.sharedPythonURL() }
        guard let python else { return false }
        return await Task.detached(priority: .userInitiated) {
            let ok = Self.runPythonImportCheck(pythonURL: python)
            UserDefaults.standard.set(ok, forKey: Self.importableCacheKey)
            return ok
        }.value
    }

    // MARK: - install

    func install(modelId: String, progress: ModelInstallProgress) async throws {
        await MainActor.run { progress.stage = .checkingDependencies }

        // venv4 may not exist yet. It used to fail here with "Open Models tab
        // and tap Install Cellpose-SAM… first", which is circular — the user
        // reaches this code path BY doing exactly that, from the Models tab.
        // Every cellpose4-family row (cpsam, cpsam_v2, cpdino…) hit it, so the
        // whole family was uninstallable on a machine that had never run the
        // separate install sheet. Bootstrap the venv here instead.
        var pythonURL = await MainActor.run(body: { () -> URL? in Self.sharedPythonURL() })
        if pythonURL == nil {
            await MainActor.run {
                progress.append("Cellpose-SAM environment not found — creating it…")
            }
            try await Self.bootstrapVenv4(progress: progress)
            pythonURL = await MainActor.run(body: { () -> URL? in Self.sharedPythonURL() })
        }
        guard let python = pythonURL else {
            let msg = "Could not create the Cellpose-SAM Python environment. "
                    + "See the log above for the installer output."
            await MainActor.run { progress.append(msg) }
            throw CellposeSAMDownloaderError.venvMissing(msg)
        }

        // Fast path: already importable.
        if Self.isCellposeSAMImportable(pythonURL: python) {
            await MainActor.run {
                progress.append("cellpose 4 already importable; nothing to install")
                progress.stage = .ready
            }
            return
        }

        try await Self.runPipInstall(
            pythonURL: python,
            packages: ["cellpose>=4", "numpy<2", "scipy", "scikit-image",
                       "tifffile", "torch"],
            progress: progress
        )

        // Optional vendor microscope-format readers for `python/_imageio.py`.
        // Same list and same best-effort semantics as CellposeDownloader —
        // failures here must never abort an otherwise-good install.
        for package in CellposeDownloader.optionalImageReaderPackages {
            await MainActor.run {
                progress.append("optional reader: pip install \(package)")
            }
            try? await Self.runPipInstall(pythonURL: python,
                                          packages: [package],
                                          progress: progress)
        }

        await MainActor.run { progress.stage = .verifying }
        let importable = Self.isCellposeSAMImportable(pythonURL: python, useCache: false)
        if !importable {
            throw CellposeSAMDownloaderError.pipFailed("cellpose 4 still not importable after pip install")
        }

        await MainActor.run {
            progress.append("cellpose 4 import verified")
            progress.stage = .ready
        }
    }

    // MARK: - uninstall

    @MainActor
    func uninstall(modelId: String) throws {
        // No-op for the same reason the 3.x path does no-op: the cpsam id
        // is a thin wrapper over the venv4 python package, which is shared
        // across any future cp4 model ids we add. We never touch the
        // ~/.cellpose/models/ weights cache here.
        UserDefaults.standard.removeObject(forKey: Self.importableCacheKey)
    }

    // MARK: - diskUsageBytes

    @MainActor
    func diskUsageBytes(modelId: String) -> Int64 {
        // CPSAM weights land in the SAME ~/.cellpose/models/ dir as 3.x
        // weights (cellpose doesn't split caches by major version). We report
        // the total here too; a more precise per-version breakdown would
        // require inspecting filenames, which is brittle. The shared
        // weights-dir scan is consistent with how the 3.x downloader reports.
        let home = FileManager.default.homeDirectoryForCurrentUser
        let weightsDir = home.appendingPathComponent(".cellpose/models", isDirectory: true)
        return Self.directorySize(at: weightsDir)
    }

    // MARK: - detector

    @MainActor
    func detector(for modelId: String) -> DetectionService? {
        guard CellposeSAMDetectionService.isKnownModelId(modelId) else { return nil }
        return CellposeSAMDetectionService(modelId: modelId)
    }

    // MARK: - Helpers

    /// Create `venv4` by running the bundled `install_python_cp4.sh`, the same
    /// script and arguments `CellposeSAMInstaller` uses. Kept here so the
    /// Models-tab install button is self-sufficient and does not depend on the
    /// user having opened the separate Cellpose-SAM sheet first.
    private static func bootstrapVenv4(progress: ModelInstallProgress) async throws {
        let fm = FileManager.default
        try PythonRuntime.stageScripts()

        let scriptURL = FileStore.shared.pythonInstallCp4ScriptURL
        guard fm.fileExists(atPath: scriptURL.path) else {
            throw CellposeSAMDownloaderError.venvMissing(
                "Cellpose-SAM install script missing after staging: \(scriptURL.path)")
        }
        if !fm.isExecutableFile(atPath: scriptURL.path) {
            try? fm.setAttributes([.posixPermissions: 0o755],
                                  ofItemAtPath: scriptURL.path)
        }

        // Wipe a half-built venv4 before reusing it, same preflight as
        // CellposeSAMInstaller.start(). A venv4 that exists but has no pip is
        // the residue of an interrupted run; `python3 -m venv` will happily
        // reuse the directory and the pip step then fails on every retry.
        let venv4Dir = FileStore.shared.pythonVenv4Dir
        let pipURL = venv4Dir.appendingPathComponent("bin/pip")
        if fm.fileExists(atPath: venv4Dir.path) && !fm.fileExists(atPath: pipURL.path) {
            await MainActor.run {
                progress.append("Removing a partially-built environment before retrying…")
            }
            try? fm.removeItem(at: venv4Dir)
        }

        try? fm.createDirectory(at: FileStore.shared.pythonDir,
                                withIntermediateDirectories: true)
        // Mark the install incomplete for the duration and drop the cached
        // import probe, so a crash mid-run is detected as broken rather than
        // reported as installed. Both keys are distinct from the 3.x ones.
        try? Data().write(to: FileStore.shared.cellpose4InstallIncompleteSentinel)
        UserDefaults.standard.set(false, forKey: Cellpose4Availability.importableCacheKey)

        let venvPath = FileStore.shared.pythonVenv4Dir.path
        let scriptsDir = FileStore.shared.pythonDir.path

        let exitCode: Int32 = try await Task.detached(priority: .userInitiated) {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/bin/bash")
            proc.arguments = [scriptURL.path, venvPath, scriptsDir]
            proc.currentDirectoryURL = FileStore.shared.pythonDir

            let pipe = Pipe()
            proc.standardOutput = pipe
            proc.standardError = pipe
            try proc.run()
            ChildProcessTracker.shared.register(proc, kind: .other)
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            proc.waitUntilExit()
            if let text = String(data: data, encoding: .utf8), !text.isEmpty {
                let tail = text.split(separator: "\n").suffix(40).joined(separator: "\n")
                await MainActor.run { progress.append(tail) }
            }
            return proc.terminationStatus
        }.value

        guard exitCode == 0 else {
            throw CellposeSAMDownloaderError.venvMissing(
                "Cellpose-SAM environment setup failed (exit code \(exitCode)).")
        }

        // Clear BOTH pieces of failure state, in the order CellposeSAMInstaller
        // uses. Removing only the sentinel is not enough: `detect()` also
        // returns .venvBroken when the cached probe is literally `false`, and
        // this function set it to `false` on the way in. Leaving it there meant
        // the venv was built correctly and then immediately reported broken —
        // `sharedPythonURL()` returned nil and the caller threw "Could not
        // create the Cellpose-SAM Python environment" on a successful install.
        // `removeObject` (not `set(true)`) so the next `detect()` re-probes for
        // real rather than trusting a value we assumed.
        UserDefaults.standard.removeObject(forKey: Cellpose4Availability.importableCacheKey)
        try? fm.removeItem(at: FileStore.shared.cellpose4InstallIncompleteSentinel)
    }

    private static func sharedPythonURL() -> URL? {
        if case let .available(py, _) = Cellpose4Availability.detect() {
            return py
        }
        return nil
    }

    /// Cached version-aware import probe. Distinct from the 3.x predicate:
    ///   0  → cellpose >= 4.0 importable (this is what we want)
    ///   2  → cellpose < 4 importable (wrong venv — should never hit in venv4)
    ///   1  → import failed
    private static func isCellposeSAMImportable(pythonURL: URL, useCache: Bool = true) -> Bool {
        if useCache, let cached = UserDefaults.standard.object(forKey: importableCacheKey) as? Bool {
            return cached
        }
        let ok = runPythonImportCheck(pythonURL: pythonURL)
        UserDefaults.standard.set(ok, forKey: importableCacheKey)
        return ok
    }

    private static func runPythonImportCheck(pythonURL: URL) -> Bool {
        let probe = """
        import sys
        try:
            import cellpose
            v = getattr(cellpose, 'version', None) or ''
            if not isinstance(v, str):
                v = str(v)
            major = int(v.split('.')[0]) if v else 0
            if major >= 4:
                sys.exit(0)
            sys.exit(2)
        except Exception:
            sys.exit(1)
        """
        let p = Process()
        p.executableURL = pythonURL
        p.arguments = ["-c", probe]
        let null = Pipe()
        p.standardOutput = null
        p.standardError = null
        do {
            try p.run()
            p.waitUntilExit()
            return p.terminationStatus == 0
        } catch {
            return false
        }
    }

    /// Stream `python -m pip install …` lines into `progress`. Functionally
    /// identical to the 3.x sibling; duplicated rather than factored because
    /// (a) the file lives in the same module so the indirection saves nothing
    /// at the call site, and (b) the 3.x version is intentionally untouched
    /// in this pass.
    private static func runPipInstall(pythonURL: URL,
                                       packages: [String],
                                       progress: ModelInstallProgress) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            Task.detached(priority: .userInitiated) {
                let process = Process()
                process.executableURL = pythonURL
                process.arguments = ["-m", "pip", "install", "--no-input"] + packages

                let stdoutPipe = Pipe()
                let stderrPipe = Pipe()
                process.standardOutput = stdoutPipe
                process.standardError = stderrPipe

                let resumed = CellposeSAMPipResumeFlag()

                let outHandle = stdoutPipe.fileHandleForReading
                let errHandle = stderrPipe.fileHandleForReading
                outHandle.readabilityHandler = { handle in
                    let data = handle.availableData
                    guard !data.isEmpty, let s = String(data: data, encoding: .utf8) else { return }
                    for line in s.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
                        let trimmed = String(line)
                        if trimmed.isEmpty { continue }
                        Task { @MainActor in
                            progress.append(trimmed)
                            progress.stage = .installingDependencies(line: trimmed)
                        }
                    }
                }
                errHandle.readabilityHandler = { handle in
                    let data = handle.availableData
                    guard !data.isEmpty, let s = String(data: data, encoding: .utf8) else { return }
                    for line in s.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
                        let trimmed = String(line)
                        if trimmed.isEmpty { continue }
                        Task { @MainActor in
                            progress.append(trimmed)
                            progress.stage = .installingDependencies(line: trimmed)
                        }
                    }
                }

                process.terminationHandler = { proc in
                    outHandle.readabilityHandler = nil
                    errHandle.readabilityHandler = nil
                    if !resumed.markAndCheck() { return }
                    if proc.terminationStatus == 0 {
                        cont.resume()
                    } else {
                        cont.resume(throwing: CellposeSAMDownloaderError.pipFailed(
                            "pip install exited \(proc.terminationStatus)"))
                    }
                }

                do {
                    try process.run()
                    // Register so a quit mid-install SIGTERMs the pip child
                    // instead of orphaning a multi-minute download.
                    Task { @MainActor in
                        ChildProcessTracker.shared.register(process, kind: .install)
                    }
                } catch {
                    outHandle.readabilityHandler = nil
                    errHandle.readabilityHandler = nil
                    if resumed.markAndCheck() {
                        cont.resume(throwing: error)
                    }
                }
            }
        }
    }

    private static func directorySize(at url: URL) -> Int64 {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else {
            return 0
        }
        guard let enumerator = fm.enumerator(
            at: url,
            includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .fileSizeKey],
            options: [.skipsHiddenFiles],
            errorHandler: nil
        ) else { return 0 }

        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            let values = try? fileURL.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileSizeKey])
            if let allocated = values?.totalFileAllocatedSize {
                total += Int64(allocated)
            } else if let size = values?.fileSize {
                total += Int64(size)
            }
        }
        return total
    }
}

// MARK: - Errors

enum CellposeSAMDownloaderError: LocalizedError {
    case venvMissing(String)
    case pipFailed(String)

    var errorDescription: String? {
        switch self {
        case .venvMissing(let m): return m
        case .pipFailed(let m): return m
        }
    }
}

// MARK: - Resume flag (one-shot continuation guard, file-private)

private final class CellposeSAMPipResumeFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false
    func markAndCheck() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if fired { return false }
        fired = true
        return true
    }
}

// MARK: - CellposeSAMDetectionService bridge

extension CellposeSAMDetectionService {
    /// Whether a given app-level model id belongs to the cp4 family.
    /// Currently a single id (`cpsam`); kept as a function for future ids.
    static func isKnownModelId(_ id: String) -> Bool {
        knownModelIds.contains(id)
    }

    /// Every checkpoint the cellpose 4.x `pretrained_model=` constructor
    /// accepts, per https://cellpose.readthedocs.io/en/latest/models.html
    /// (verified against that page). All four share the SAME `venv4/` install
    /// and differ only in the weights cellpose downloads on first use — so
    /// adding one costs no new dependency and no licence change.
    ///
    /// The id IS the `pretrained_model` string. `cellpose4_detect.py` strips
    /// any `cp4-`/`cellpose4-` prefix and passes the rest straight through.
    static let knownModelIds: Set<String> = [
        "cpsam",        // original CellposeSAM (SAM-ViTL)
        "cpsam_v2",     // revised CellposeSAM — better on low-contrast regions
        "cpdino",       // CellposeDINO (DINOv3-ViTL), adjustable tile size
        "cpdino-vitb",  // CellposeDINO (DINOv3-ViTB), smaller and faster
    ]
}
