import Foundation

/// SAM-family `ModelDownloader`. Reuses the shared Python venv set up by
/// `scripts/install_python.sh`, installs the `micro_sam` package on demand,
/// and triggers checkpoint downloads via `micro_sam.util.get_sam_model`.
///
/// Honest scope:
/// - MobileSAM, μSAM LM-generalist, μSAM EM-generalist, patho-sam: real,
///   downloadable via micro_sam's Hugging Face hub fetch.
/// - CellSAM, SAMCell-Generalist, SAMCell-Cyto: no public CDN for original
///   weights; we install μSAM LM (`vit_b_lm`) as a stand-in so the user has a
///   functional SAM-flavoured detector. Marked clearly in the catalog notes.
/// - CellViT: requires custom weights not exposed by micro_sam. We always
///   return `.failed(...)`; the SAM detection service then throws
///   `DetectionError.modelNotInstalled` on use.
struct SAMDownloader: ModelDownloader {
    let family: ModelFamily = .sam

    /// Per-interpreter import-probe cache. See YOLO/StarDist for the same pattern.
    fileprivate static let importCache = PythonModuleImportCache(module: "micro_sam")

    // MARK: — App id → micro_sam model_type mapping

    /// Returns the micro_sam `model_type` for an app-level model id, or nil if
    /// the model is not supported by this downloader (e.g. cellvit).
    static func modelType(for modelId: String) -> String? {
        switch modelId {
        case "mobilesam":   return "vit_t"
        case "usam-lm":     return "vit_b_lm"
        case "usam-em":     return "vit_b_em_organelles"
        case "cellsam":     return "vit_b_lm"            // substitute
        case "samcell-g":   return "vit_b_lm"            // substitute
        case "samcell-c":   return "vit_b_lm"            // substitute
        case "patho-sam":   return "vit_b_histopathology"
        case "cellvit":     return nil
        default:            return nil
        }
    }

    /// Models we know we can't install (no checkpoint route available).
    private static let unsupported: Set<String> = ["cellvit"]

    // MARK: — Paths

    /// Resolves the shared venv python binary (same one Cellpose uses).
    /// Returns nil if no venv exists; install() surfaces that as a failure.
    private func venvPython() -> URL? {
        let fm = FileManager.default
        // 1) Primary: staged venv under FileStore (created by CellposeInstaller).
        let stagedBin = FileStore.shared.pythonVenvDir.appendingPathComponent("bin")
        let stagedPy3 = stagedBin.appendingPathComponent("python3")
        let stagedPy  = stagedBin.appendingPathComponent("python")
        if fm.isExecutableFile(atPath: stagedPy3.path) { return stagedPy3 }
        if fm.isExecutableFile(atPath: stagedPy.path)  { return stagedPy }
        // No dev-repo fallback any more — the only supported install path is
        // CellposeInstaller writing the venv into FileStore. The previous
        // fallback masked bundling bugs (see pass 10).
        return nil
    }

    /// `~/.cache/micro_sam/models/<model_type>` — where micro_sam stores checkpoints.
    private func cacheDir(for modelType: String) -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home
            .appendingPathComponent(".cache/micro_sam/models", isDirectory: true)
            .appendingPathComponent(modelType, isDirectory: true)
    }

    // MARK: — ModelDownloader

    /// Cheap, main-safe. No Process. Consults the cache; if the cache
    /// hasn't been seeded yet we return false (probeInstalled will fill it).
    func isInstalled(modelId: String) -> Bool {
        if Self.unsupported.contains(modelId) { return false }
        guard let modelType = Self.modelType(for: modelId) else { return false }
        guard let py = venvPython() else { return false }
        // Cached-only lookup: never forks.
        guard Self.importCache.cachedAnswer(pythonURL: py) == true else { return false }
        let dir = cacheDir(for: modelType)
        guard let contents = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else {
            return false
        }
        return !contents.isEmpty
    }

    func probeInstalled(modelId: String) async -> Bool {
        if Self.unsupported.contains(modelId) { return false }
        guard let modelType = Self.modelType(for: modelId) else { return false }
        guard let py = venvPython() else { return false }
        let importable = await Task.detached(priority: .userInitiated) {
            Self.importCache.isImportable(pythonURL: py)
        }.value
        if !importable { return false }
        let dir = cacheDir(for: modelType)
        guard let contents = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else {
            return false
        }
        return !contents.isEmpty
    }

    func install(modelId: String, progress: ModelInstallProgress) async throws {
        // 1) Unsupported models — fail loudly so the UI shows a real message.
        if Self.unsupported.contains(modelId) {
            await MainActor.run {
                progress.stage = .failed("CellViT requires custom weights; not yet integrated.")
            }
            return
        }
        guard let modelType = Self.modelType(for: modelId) else {
            await MainActor.run {
                progress.stage = .failed("Unknown SAM model id: \(modelId)")
            }
            return
        }
        guard let py = venvPython() else {
            await MainActor.run {
                progress.stage = .failed("Python venv not found. Run scripts/install_python.sh first.")
            }
            return
        }

        // 2) Check micro_sam — install if missing.
        await MainActor.run {
            progress.stage = .checkingDependencies
            progress.append("[SAM] checking for micro_sam in \(py.path)")
        }
        let importCheck = Self.runSync(py, args: ["-c", "import micro_sam"])
        if importCheck != 0 {
            await MainActor.run {
                progress.stage = .installingDependencies(line: "pip install micro_sam")
                progress.append("[SAM] micro_sam not found — pip install …")
            }
            try await Self.runStreaming(py,
                                        args: ["-m", "pip", "install", "--upgrade", "micro_sam"],
                                        progress: progress)
            // Invalidate the cached probe so the next isInstalled query re-checks
            // through the newly-installed micro_sam package.
            Self.importCache.invalidate(pythonURL: py)
        }

        // 3) Trigger checkpoint download via micro_sam.util.get_sam_model.
        //    The HF hub fetch happens inside the Python process; we surface
        //    its stdout/stderr lines to the progress log.
        await MainActor.run {
            progress.stage = .downloading(progress: 0, bytesPerSec: nil)
            progress.append("[SAM] downloading checkpoint for model_type=\(modelType)")
            if modelId == "cellsam" || modelId == "samcell-g" || modelId == "samcell-c" {
                progress.append("[SAM] note: \(modelId) substitutes μSAM LM (vit_b_lm) — original CellSAM/SAMCell weights are not on a public CDN")
            }
        }
        let snippet = "from micro_sam.util import get_sam_model; get_sam_model(model_type='\(modelType)')"
        try await Self.runStreaming(py,
                                    args: ["-c", snippet],
                                    progress: progress)

        // 4) Verify the cache dir landed.
        await MainActor.run { progress.stage = .verifying }
        let dir = cacheDir(for: modelType)
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        if contents.isEmpty {
            await MainActor.run {
                progress.stage = .failed("Checkpoint cache empty at \(dir.path) — download may have failed.")
            }
            return
        }
        await MainActor.run {
            progress.append("[SAM] checkpoint ready at \(dir.path)")
        }
    }

    @MainActor
    func uninstall(modelId: String) throws {
        guard let modelType = Self.modelType(for: modelId) else { return }
        // If multiple app-ids share a model_type (cellsam/samcell-g/samcell-c
        // all use vit_b_lm), only remove the cache if no other installed id
        // depends on the same type. We don't know "installed" here cheaply,
        // so the conservative behaviour: only remove the dir, and let other
        // models re-download on next install. The pip-installed micro_sam
        // package itself stays in the venv.
        let dir = cacheDir(for: modelType)
        if FileManager.default.fileExists(atPath: dir.path) {
            try FileManager.default.removeItem(at: dir)
        }
    }

    @MainActor
    func diskUsageBytes(modelId: String) -> Int64 {
        guard let modelType = Self.modelType(for: modelId) else { return 0 }
        let dir = cacheDir(for: modelType)
        var total: Int64 = 0
        if let en = FileManager.default.enumerator(at: dir,
                                                    includingPropertiesForKeys: [.fileSizeKey],
                                                    options: [.skipsHiddenFiles]) {
            for case let url as URL in en {
                if let sz = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                    total += Int64(sz)
                }
            }
        }
        return total
    }

    @MainActor
    func detector(for modelId: String) -> DetectionService? {
        if Self.unsupported.contains(modelId) {
            // CellViT has no installable checkpoint. Return nil; the registry
            // propagates nil to the caller, which throws DetectionError.modelNotInstalled.
            return nil
        }
        guard Self.modelType(for: modelId) != nil else { return nil }
        return SAMDetectionService(modelId: modelId)
    }

    // MARK: — Process helpers

    /// Runs a process synchronously, returning the exit code. Discards output.
    /// Used for cheap importability checks. Off-main is fine; we don't await.
    static func runSync(_ tool: URL, args: [String]) -> Int32 {
        let p = Process()
        p.executableURL = tool
        p.arguments = args
        p.standardOutput = Pipe()
        p.standardError = Pipe()
        do {
            try p.run()
            p.waitUntilExit()
            return p.terminationStatus
        } catch {
            return -1
        }
    }

    /// Runs a process, streaming stdout+stderr lines into `progress.append(_:)`.
    /// Throws if the process exits non-zero, with the last few stderr lines in
    /// the error message so the UI's `.failed(...)` is informative.
    static func runStreaming(_ tool: URL,
                             args: [String],
                             progress: ModelInstallProgress) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            Task.detached(priority: .userInitiated) {
                let p = Process()
                p.executableURL = tool
                p.arguments = args
                let outPipe = Pipe()
                let errPipe = Pipe()
                p.standardOutput = outPipe
                p.standardError = errPipe

                let tail = TailBuffer(capacity: 8)

                // Line-buffered streaming for each pipe.
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
                                // Heuristic: pip pulls down packages; surface that as installing-deps.
                                if line.contains("Downloading") || line.contains("Collecting") {
                                    progress.stage = .installingDependencies(line: line)
                                }
                            }
                        }
                    }
                }
                forward(outPipe.fileHandleForReading)
                forward(errPipe.fileHandleForReading)

                let flag = ResumeFlagSAM()
                p.terminationHandler = { proc in
                    outPipe.fileHandleForReading.readabilityHandler = nil
                    errPipe.fileHandleForReading.readabilityHandler = nil
                    guard flag.markAndCheck() else { return }
                    if proc.terminationStatus == 0 {
                        cont.resume()
                    } else {
                        let recent = tail.snapshot().joined(separator: " | ")
                        let msg = "Process \(tool.lastPathComponent) exited \(proc.terminationStatus). \(recent)"
                        cont.resume(throwing: NSError(
                            domain: "SAMDownloader",
                            code: Int(proc.terminationStatus),
                            userInfo: [NSLocalizedDescriptionKey: msg]))
                    }
                }
                do {
                    try p.run()
                    // Register so a quit mid-install SIGTERMs the pip child
                    // instead of orphaning a multi-minute download.
                    Task { @MainActor in
                        ChildProcessTracker.shared.register(p, kind: .install)
                    }
                } catch {
                    if flag.markAndCheck() { cont.resume(throwing: error) }
                }
            }
        }
    }
}

/// Bounded ring buffer for the most-recent stderr lines so failure messages
/// can include context without holding the entire log in memory.
private final class TailBuffer: @unchecked Sendable {
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

private final class ResumeFlagSAM: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false
    func markAndCheck() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if fired { return false }
        fired = true
        return true
    }
}
