import Foundation

/// `ModelDownloader` for the Cellpose family.
///
/// Cellpose is special-cased: the *package itself* manages weight downloads
/// (the first `model.eval()` call pulls the requested checkpoint into
/// `~/.cellpose/models/` inside the sandbox container). We therefore don't
/// fetch weights manually — "installing" really means "ensure the shared
/// Python venv exists and has `cellpose` importable".
///
/// All four cellpose model ids (`cp-cyto3`, `cp-cyto3-r`, `cp-cyto2`,
/// `cp-nuclei`) share the same Python install, so install/uninstall is
/// effectively a family-wide operation.
struct CellposeDownloader: ModelDownloader {
    let family: ModelFamily = .cellpose

    /// UserDefaults key used to cache the import probe outcome for the session.
    private static let importableCacheKey = "cc-cellpose-importable"

    // MARK: - isInstalled (cheap, main-safe)

    /// Never forks a process. Returns the last cached importability answer
    /// if we have one; otherwise leans on file presence so the UI can at least
    /// show "Get" while the async probe runs.
    func isInstalled(modelId: String) -> Bool {
        guard let _ = Self.sharedPythonURL() else { return false }
        // If we've successfully probed at some point this session, trust it.
        if let cached = UserDefaults.standard.object(forKey: Self.importableCacheKey) as? Bool {
            return cached
        }
        // No cached probe yet — assume not installed until the async probe lands.
        // This matches the existing semantics for fresh sessions.
        return false
    }

    // MARK: - probeInstalled (deep, off-main)

    func probeInstalled(modelId: String) async -> Bool {
        // Resolve the venv python on the MainActor (sharedPythonURL hits the
        // FileManager + FileStore — cheap but main-safe-only by convention).
        let python: URL? = await MainActor.run { Self.sharedPythonURL() }
        guard let python else { return false }
        // The actual `python -c "import cellpose"` fork runs detached.
        return await Task.detached(priority: .userInitiated) {
            let ok = Self.runPythonImportCheck(pythonURL: python)
            UserDefaults.standard.set(ok, forKey: Self.importableCacheKey)
            return ok
        }.value
    }

    // MARK: - install

    func install(modelId: String, progress: ModelInstallProgress) async throws {
        await MainActor.run { progress.stage = .checkingDependencies }

        guard let python = await MainActor.run(body: { () -> URL? in Self.sharedPythonURL() }) else {
            let msg = "Open Models tab and tap “Install Cellpose…” first."
            await MainActor.run { progress.append(msg) }
            throw CellposeDownloaderError.venvMissing(msg)
        }

        // Fast path: already importable.
        if Self.isCellposeImportable(pythonURL: python) {
            await MainActor.run {
                progress.append("cellpose already importable; nothing to install")
                progress.stage = .ready
            }
            return
        }

        // Pip-install cellpose + friends into the shared venv, streaming output
        // into the progress object so the Models row can show live lines.
        //
        // Pass-13: pin cellpose to the 3.x line. Cellpose 4.0 (released 2025)
        // shipped a brand-new architecture (CPSAM, a 1.15 GB transformer model
        // downloaded on first instantiation) and silently ignores the
        // `model_type=` argument that our `cellpose_detect.py` sidecar passes.
        // On 4.x the sidecar therefore (a) downloads ~1.15 GB on every cold
        // run with no UI signal — which is what "Processing stuck at 92%"
        // actually was — and (b) ignores the user-selected cyto3/nuclei
        // weights. Pinning <4 keeps the sidecar contract intact until we
        // ship a 4.x-aware version of the script.
        try await Self.runPipInstall(
            pythonURL: python,
            packages: ["cellpose>=3.0,<4", "numpy<2", "scipy", "scikit-image", "torch"],
            progress: progress
        )

        // Verify.
        await MainActor.run { progress.stage = .verifying }
        let importable = Self.isCellposeImportable(pythonURL: python, useCache: false)
        if !importable {
            throw CellposeDownloaderError.pipFailed("cellpose still not importable after pip install")
        }

        await MainActor.run {
            progress.append("cellpose import verified")
            progress.stage = .ready
        }
    }

    // MARK: - uninstall

    @MainActor
    func uninstall(modelId: String) throws {
        // No-op: the Python package is shared by all four cellpose model ids
        // (cp-cyto3, cp-cyto3-r, cp-cyto2, cp-nuclei). Removing it on the user
        // pressing "Remove" for a single model would break the others.
        // The on-disk weights live under `~/.cellpose/models/` and are managed
        // by the cellpose package itself; we deliberately do not touch them.
        UserDefaults.standard.removeObject(forKey: Self.importableCacheKey)
    }

    // MARK: - diskUsageBytes

    @MainActor
    func diskUsageBytes(modelId: String) -> Int64 {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let weightsDir = home.appendingPathComponent(".cellpose/models", isDirectory: true)
        return Self.directorySize(at: weightsDir)
    }

    // MARK: - detector

    @MainActor
    func detector(for modelId: String) -> DetectionService? {
        guard CellposeDetectionService.isKnownModelId(modelId) else { return nil }
        return CellposeDetectionService(modelId: modelId)
    }

    // MARK: - Helpers

    /// Resolve the shared venv python interpreter via `CellposeAvailability`.
    private static func sharedPythonURL() -> URL? {
        if case let .available(py, _) = CellposeAvailability.detect() {
            return py
        }
        return nil
    }

    /// Run `python -c "import cellpose"` and return whether it succeeded.
    /// The result is cached in UserDefaults under `cc-cellpose-importable` for
    /// the session so repeated `isInstalled(_:)` queries from the Models view
    /// don't fork a process every time.
    private static func isCellposeImportable(pythonURL: URL, useCache: Bool = true) -> Bool {
        if useCache, let cached = UserDefaults.standard.object(forKey: importableCacheKey) as? Bool {
            return cached
        }
        let ok = runPythonImportCheck(pythonURL: pythonURL)
        UserDefaults.standard.set(ok, forKey: importableCacheKey)
        return ok
    }

    private static func runPythonImportCheck(pythonURL: URL) -> Bool {
        // Pass-13: probe both importability AND version. A plain `import cellpose`
        // succeeds on 4.x venvs but our sidecar script targets the 3.x API; if
        // we say "installed" the user's next detection will silently download
        // 1.15 GB of weights and look like a hang. Exit-code contract:
        //   0  → cellpose 3.x importable, sidecar will work
        //   2  → cellpose 4.x or newer importable (sidecar incompatible)
        //   1  → import failed / version unparseable
        let probe = """
        import sys
        try:
            import cellpose
            v = getattr(cellpose, 'version', None) or ''
            if not isinstance(v, str):
                v = str(v)
            major = int(v.split('.')[0]) if v else 0
            if major >= 4:
                sys.exit(2)
            sys.exit(0)
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

    /// Stream `python -m pip install ...` into `progress.lastLogLines` line by line.
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

                let resumed = CellposePipResumeFlag()

                // Stream stdout/stderr -> progress.append on the main actor.
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
                        cont.resume(throwing: CellposeDownloaderError.pipFailed(
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

    /// Sum of file sizes under `url`, recursing. Returns 0 if the dir doesn't exist.
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

enum CellposeDownloaderError: LocalizedError {
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

private final class CellposePipResumeFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false
    func markAndCheck() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if fired { return false }
        fired = true
        return true
    }
}

// MARK: - CellposeDetectionService bridge

extension CellposeDetectionService {
    /// Whether a given app-level model id belongs to the cellpose family.
    /// Kept here (rather than on `ModelCatalog`) so the downloader's
    /// `detector(for:)` can give a fast yes/no without touching the catalog.
    static func isKnownModelId(_ id: String) -> Bool {
        switch id {
        case "cp-cyto3", "cp-cyto3-r", "cp-cyto2", "cp-nuclei":
            return true
        default:
            return false
        }
    }
}
