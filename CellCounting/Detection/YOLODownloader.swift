import Foundation

/// ModelDownloader for the YOLO family (Ultralytics YOLOv8 / YOLOv11).
///
/// Stand-in policy: the catalog descriptions ("YOLOv11 cells nano/small/medium",
/// trained on LIVECell, etc.) are aspirational — there are no canonical
/// microscope-cell-trained YOLOv11 weights from Ultralytics. We download the
/// COCO-pretrained checkpoints as a placeholder so the pipeline is end-to-end
/// runnable today. Detection on cells will work but accuracy will be poor
/// until the user fine-tunes on their own data. This is documented in the
/// install log and the model `note` field.
///
/// NuclePhaser is a separate case: there is no public weight URL, so we mark
/// the install as `.failed(...)` immediately rather than attempting a download.
struct YOLODownloader: ModelDownloader {
    let family: ModelFamily = .yolo

    /// Weight URLs for the COCO-pretrained Ultralytics YOLOv11 checkpoints.
    /// `nuclephaser` is intentionally absent — see `install(modelId:progress:)`.
    private static let weightURLs: [String: URL] = [
        "yo-n": URL(string: "https://github.com/ultralytics/assets/releases/download/v8.3.0/yolo11n.pt")!,
        "yo-s": URL(string: "https://github.com/ultralytics/assets/releases/download/v8.3.0/yolo11s.pt")!,
        "yo-m": URL(string: "https://github.com/ultralytics/assets/releases/download/v8.3.0/yolo11m.pt")!,
    ]

    // MARK: — Paths

    private static var yoloDir: URL {
        FileStore.shared.modelsDir.appendingPathComponent("yolo", isDirectory: true)
    }

    private static func weightsURL(for modelId: String) -> URL {
        yoloDir.appendingPathComponent("\(modelId).pt")
    }

    // MARK: — ModelDownloader

    /// Cheap, main-safe. No Process. Consults the import cache; if the cache
    /// says yes AND the .pt file exists, return true.
    func isInstalled(modelId: String) -> Bool {
        // NuclePhaser has no public weights — never report installed.
        if modelId == "nuclephaser" { return false }
        guard case .available(let py, _) = CellposeAvailability.detect() else { return false }
        guard FileManager.default.fileExists(atPath: Self.weightsURL(for: modelId).path) else {
            return false
        }
        return Self.importCache.cachedAnswer(pythonURL: py) == true
    }

    func probeInstalled(modelId: String) async -> Bool {
        if modelId == "nuclephaser" { return false }
        guard case .available(let py, _) = CellposeAvailability.detect() else { return false }
        guard FileManager.default.fileExists(atPath: Self.weightsURL(for: modelId).path) else {
            return false
        }
        // Run the `import ultralytics` probe off-main and seed the cache.
        return await Task.detached(priority: .userInitiated) {
            Self.importCache.isImportable(pythonURL: py)
        }.value
    }

    func install(modelId: String, progress: ModelInstallProgress) async throws {
        // 1) NuclePhaser short-circuit.
        if modelId == "nuclephaser" {
            await MainActor.run {
                progress.stage = .failed("NuclePhaser weights aren't publicly available yet — pick another YOLO model.")
                progress.append("NuclePhaser: no public download URL is currently available.")
            }
            return
        }

        guard let url = Self.weightURLs[modelId] else {
            await MainActor.run {
                progress.stage = .failed("Unknown YOLO model id: \(modelId)")
            }
            return
        }

        // 2) Pre-flight venv via the shared CellposeAvailability lookup.
        await MainActor.run {
            progress.stage = .checkingDependencies
            progress.append("Resolving shared Python venv...")
        }

        let availability = await MainActor.run { CellposeAvailability.detect() }
        let pythonURL: URL
        switch availability {
        case .available(let py, _):
            pythonURL = py
        case .missingVenv:
            await MainActor.run {
                progress.stage = .failed("Python venv is missing. Run scripts/install_python.sh first.")
            }
            return
        case .missingInstaller, .missingScripts:
            await MainActor.run {
                progress.stage = .failed("Python sidecar is not set up. Run scripts/install_python.sh.")
            }
            return
        case .venvBroken(let reason):
            await MainActor.run {
                progress.stage = .failed("Python venv is broken (\(reason)). Reinstall Cellpose from the Models tab.")
            }
            return
        }

        // 3) Ensure ultralytics is importable; pip install if not.
        if !Self.canImportUltralytics(pythonURL: pythonURL) {
            await MainActor.run {
                progress.stage = .installingDependencies(line: "pip install ultralytics")
                progress.append("Installing ultralytics into venv (one-time, ~80 MB of deps)...")
            }
            do {
                try await Self.pipInstall(pythonURL: pythonURL, packages: ["ultralytics"], progress: progress)
            } catch {
                await MainActor.run {
                    progress.stage = .failed("pip install ultralytics failed: \(error.localizedDescription)")
                }
                return
            }
            // Re-verify after pip install. Invalidate the cache first so the
            // re-probe actually re-runs `python -c "import ultralytics"`.
            Self.importCache.invalidate(pythonURL: pythonURL)
            if !Self.canImportUltralytics(pythonURL: pythonURL) {
                await MainActor.run {
                    progress.stage = .failed("ultralytics installed but still not importable.")
                }
                return
            }
        }

        // 4) Download the .pt file (skip if already on disk and non-empty).
        let dest = Self.weightsURL(for: modelId)
        let fm = FileManager.default
        try fm.createDirectory(at: Self.yoloDir, withIntermediateDirectories: true)

        let needsDownload: Bool
        if fm.fileExists(atPath: dest.path),
           let attrs = try? fm.attributesOfItem(atPath: dest.path),
           let size = attrs[.size] as? Int64, size > 1024 {
            needsDownload = false
        } else {
            needsDownload = true
        }

        if needsDownload {
            await MainActor.run {
                progress.stage = .downloading(progress: 0, bytesPerSec: nil)
                progress.append("Downloading \(modelId).pt from \(url.host ?? "ultralytics") ...")
                progress.append("Note: standard COCO-pretrained YOLOv11 weights are being used as a stand-in;")
                progress.append("there are no canonical microscope-cell weights from Ultralytics yet.")
            }
            try await WeightDownloader.download(url, to: dest, expectedSHA256: nil, progress: progress)
        } else {
            await MainActor.run {
                progress.append("Weights already on disk at \(dest.path); skipping download.")
            }
        }

        // 5) Verify the checkpoint by asking ultralytics to load it.
        await MainActor.run {
            progress.stage = .verifying
            progress.append("Verifying checkpoint via YOLO(...).info() ...")
        }
        let verifyOK = await Self.verifyCheckpoint(pythonURL: pythonURL, weightsPath: dest)
        if !verifyOK {
            // Don't delete the file — let the user retry. But fail the stage.
            await MainActor.run {
                progress.stage = .failed("YOLO checkpoint failed to load. The file may be corrupt; try re-downloading.")
            }
            return
        }

        await MainActor.run {
            progress.append("YOLO \(modelId) ready. Heads-up: weights are COCO-pretrained, not cell-trained.")
        }
        // Registry sets stage = .ready on return.
    }

    @MainActor
    func uninstall(modelId: String) throws {
        let path = Self.weightsURL(for: modelId)
        if FileManager.default.fileExists(atPath: path.path) {
            try FileManager.default.removeItem(at: path)
        }
    }

    @MainActor
    func diskUsageBytes(modelId: String) -> Int64 {
        let path = Self.weightsURL(for: modelId)
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path.path),
              let size = attrs[.size] as? Int64 else { return 0 }
        return size
    }

    @MainActor
    func detector(for modelId: String) -> DetectionService? {
        // NuclePhaser has no installable weights. Return nil; the registry propagates
        // nil to the caller, which throws DetectionError.modelNotInstalled.
        if modelId == "nuclephaser" { return nil }
        guard Self.weightURLs[modelId] != nil else { return nil }
        let path = Self.weightsURL(for: modelId)
        return YOLODetectionService(modelId: modelId, weightsPath: path)
    }

    // MARK: — Python helpers

    /// Session-lived cache for `python -c "import ultralytics"`. Keyed by
    /// python interpreter path. Sub-second per check, but cumulative cost
    /// across a render of N rows was the original main-thread stall.
    fileprivate static let importCache = PythonModuleImportCache(module: "ultralytics")

    /// Synchronous import check. Only called from off-main contexts
    /// (`probeInstalled` and `install`). `isInstalled` reads from the cache.
    private static func canImportUltralytics(pythonURL: URL) -> Bool {
        Self.importCache.isImportable(pythonURL: pythonURL)
    }

    /// Streams `pip install` output into `progress.append(_:)` so the UI can show it.
    private static func pipInstall(pythonURL: URL,
                                    packages: [String],
                                    progress: ModelInstallProgress) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            Task.detached(priority: .userInitiated) {
                let proc = Process()
                proc.executableURL = pythonURL
                proc.arguments = ["-m", "pip", "install", "--upgrade"] + packages

                let outPipe = Pipe()
                let errPipe = Pipe()
                proc.standardOutput = outPipe
                proc.standardError = errPipe

                let resumed = YOLOInstallResumeFlag()

                // Stream stdout line-by-line into progress.
                outPipe.fileHandleForReading.readabilityHandler = { handle in
                    let data = handle.availableData
                    guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
                    let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
                    for line in lines {
                        let s = String(line)
                        Task { @MainActor in
                            progress.stage = .installingDependencies(line: s)
                            progress.append(s)
                        }
                    }
                }
                errPipe.fileHandleForReading.readabilityHandler = { handle in
                    let data = handle.availableData
                    guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
                    let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
                    for line in lines {
                        let s = String(line)
                        Task { @MainActor in progress.append(s) }
                    }
                }

                proc.terminationHandler = { p in
                    outPipe.fileHandleForReading.readabilityHandler = nil
                    errPipe.fileHandleForReading.readabilityHandler = nil
                    if resumed.markAndCheck() {
                        if p.terminationStatus == 0 {
                            continuation.resume()
                        } else {
                            continuation.resume(throwing: NSError(
                                domain: "YOLODownloader",
                                code: Int(p.terminationStatus),
                                userInfo: [NSLocalizedDescriptionKey: "pip exited \(p.terminationStatus)"]))
                        }
                    }
                }

                do {
                    try proc.run()
                } catch {
                    outPipe.fileHandleForReading.readabilityHandler = nil
                    errPipe.fileHandleForReading.readabilityHandler = nil
                    if resumed.markAndCheck() {
                        continuation.resume(throwing: error)
                    }
                }
            }
        }
    }

    /// Spawns `python -c "from ultralytics import YOLO; YOLO('<path>').info()"`.
    private static func verifyCheckpoint(pythonURL: URL, weightsPath: URL) async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            Task.detached(priority: .userInitiated) {
                let proc = Process()
                proc.executableURL = pythonURL
                // Single-quote-safe: the weights path comes from FileStore (no user input),
                // but escape backslashes/quotes defensively anyway.
                let escaped = weightsPath.path
                    .replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "'", with: "\\'")
                proc.arguments = [
                    "-c",
                    "from ultralytics import YOLO; YOLO('\(escaped)').info()"
                ]
                proc.standardOutput = Pipe()
                proc.standardError = Pipe()
                do {
                    try proc.run()
                    proc.waitUntilExit()
                    continuation.resume(returning: proc.terminationStatus == 0)
                } catch {
                    continuation.resume(returning: false)
                }
            }
        }
    }
}

/// One-shot flag for the pip Process terminationHandler.
private final class YOLOInstallResumeFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false
    func markAndCheck() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if fired { return false }
        fired = true
        return true
    }
}
