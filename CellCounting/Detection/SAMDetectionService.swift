import Foundation

/// SAM-family `DetectionService` that shells out to `sam_detect.py` via the
/// shared Python venv. Routes per-model_type. Throws `DetectionError` on any
/// failure (including CellViT, which has no installable weights).
struct SAMDetectionService: DetectionService {
    let modelId: String

    init(modelId: String) {
        self.modelId = modelId
    }

    func detect(_ input: DetectionInput) async throws -> DetectionResult {
        // CellViT: no checkpoint route — surface as not-installed.
        guard let modelType = SAMDownloader.modelType(for: modelId) else {
            throw DetectionError.modelNotInstalled(modelId: modelId)
        }

        // Resolve python + script. The script lives next to cellpose_detect.py.
        guard let (pythonURL, scriptURL) = Self.resolveSidecar() else {
            throw DetectionError.modelNotInstalled(modelId: modelId)
        }
        guard let imageURL = input.imageURL else {
            throw DetectionError.imageDecodeFailed
        }

        var args = [
            scriptURL.path,
            "--image", imageURL.path,
            "--model", modelType,
            "--pxPerUm", String(input.pxPerUm),
            "--conf", String(input.confidenceThreshold),
            "--prompts", "auto",
        ]
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
            // Honour the user's "Use GPU" preference. The sam sidecar accepts
            // `--no-gpu` to force the SAM models onto CPU.
            args += ["--no-gpu"]
        }

        let outcome: SidecarOutcome
        do {
            outcome = try await Self.runSidecar(pythonURL: pythonURL, args: args)
        } catch {
            throw DetectionError.sidecarFailed(exitCode: -1, stderr: error.localizedDescription)
        }

        if outcome.exitCode != 0 {
            let stderrText = String(data: outcome.stderr, encoding: .utf8) ?? ""
            throw DetectionError.sidecarFailed(exitCode: outcome.exitCode, stderr: stderrText)
        }

        if let errPayload = try? JSONDecoder().decode(SidecarError.self, from: outcome.stdout) {
            let combined = "\(errPayload.error)\(errPayload.hint.map { ": \($0)" } ?? "")"
            throw DetectionError.sidecarFailed(exitCode: 0, stderr: combined)
        }

        let decoded: SidecarPayload
        do {
            decoded = try JSONDecoder().decode(SidecarPayload.self, from: outcome.stdout)
        } catch {
            let stdoutText = String(data: outcome.stdout, encoding: .utf8) ?? ""
            throw DetectionError.sidecarFailed(exitCode: outcome.exitCode,
                                               stderr: "Unparseable stdout: \(stdoutText.prefix(400))")
        }

        let cells = decoded.cells.map { c -> DetectedCell in
            DetectedCell(
                id: UUID(uuidString: c.id) ?? UUID(),
                cx: c.cx,
                cy: c.cy,
                diameter: c.diameter_um,
                diameterPx: c.diameter_px,
                confidence: c.confidence,
                areaMicrons2: c.area_um2,
                perimeterMicrons: c.perimeter_um,
                circularity: c.circularity,
                eccentricity: c.eccentricity,
                meanIntensity: c.mean_intensity,
                integratedDensity: c.integrated_density,
                centroidUmX: c.centroid_um_x,
                centroidUmY: c.centroid_um_y,
                aspectRatio: c.aspect_ratio,
                solidity: c.solidity,
                edgeTouching: c.edge_touching ?? false,
                likelyClump: c.likely_clump ?? false,
                likelyDebris: c.likely_debris ?? false,
                sizeClass: c.size_class ?? "",
                isManual: c.is_manual ?? false
            )
        }
        return DetectionResult(cells: cells,
                                imageWidth: decoded.width,
                                imageHeight: decoded.height,
                                imageStats: decoded.image_stats)
    }

    // MARK: — Sidecar resolution

    /// Locates (pythonURL, sam_detect.py). Mirrors CellposeAvailability's
    /// bundled-then-dev lookup but for the SAM script.
    private static func resolveSidecar() -> (URL, URL)? {
        let fm = FileManager.default

        // Primary: staged FileStore copy (venv lives here post-install).
        let stagedScript = FileStore.shared.pythonDir.appendingPathComponent("sam_detect.py")
        let stagedBin = FileStore.shared.pythonVenvDir.appendingPathComponent("bin")
        let stagedPy3 = stagedBin.appendingPathComponent("python3")
        let stagedPy  = stagedBin.appendingPathComponent("python")
        let stagedPython: URL? = {
            if fm.isExecutableFile(atPath: stagedPy3.path) { return stagedPy3 }
            if fm.isExecutableFile(atPath: stagedPy.path)  { return stagedPy }
            return nil
        }()
        if let p = stagedPython, fm.fileExists(atPath: stagedScript.path) {
            return (p, stagedScript)
        }
        // No dev-repo fallback any more — see PythonRuntime / pass-10 notes.
        return nil
    }

    // MARK: — Process plumbing

    private struct SidecarOutcome {
        var exitCode: Int32
        var stdout: Data
        var stderr: Data
    }

    private static func runSidecar(pythonURL: URL, args: [String]) async throws -> SidecarOutcome {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<SidecarOutcome, Error>) in
            Task.detached(priority: .userInitiated) {
                let process = Process()
                process.executableURL = pythonURL
                process.arguments = args

                let stdoutPipe = Pipe()
                let stderrPipe = Pipe()
                process.standardOutput = stdoutPipe
                process.standardError = stderrPipe

                let resumed = SAMResumeFlag()

                process.terminationHandler = { proc in
                    let outData = (try? stdoutPipe.fileHandleForReading.readToEnd()) ?? Data()
                    let errData = (try? stderrPipe.fileHandleForReading.readToEnd()) ?? Data()
                    if resumed.markAndCheck() {
                        continuation.resume(returning: SidecarOutcome(
                            exitCode: proc.terminationStatus,
                            stdout: outData,
                            stderr: errData))
                    }
                }

                do {
                    try process.run()
                } catch {
                    if resumed.markAndCheck() {
                        continuation.resume(throwing: error)
                    }
                }
            }
        }
    }
}

private final class SAMResumeFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false
    func markAndCheck() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if fired { return false }
        fired = true
        return true
    }
}
