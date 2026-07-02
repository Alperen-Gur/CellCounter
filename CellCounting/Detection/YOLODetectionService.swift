import Foundation

/// YOLO-family (Ultralytics) `DetectionService` that shells out to
/// `Resources/python/yolo_detect.py`. Throws `DetectionError` on any failure.
struct YOLODetectionService: DetectionService {
    let modelId: String
    /// Resolved lazily via a closure so tests can inject a custom path.
    let weightsPathProvider: @Sendable () -> URL

    init(modelId: String, weightsPath: URL) {
        self.modelId = modelId
        self.weightsPathProvider = { weightsPath }
    }

    func detect(_ input: DetectionInput) async throws -> DetectionResult {
        let availability = CellposeAvailability.detect()
        let pythonURL: URL
        switch availability {
        case .available(let py, _):
            pythonURL = py
        case .missingScripts, .missingVenv, .missingInstaller, .venvBroken:
            throw DetectionError.modelNotInstalled(modelId: modelId)
        }

        // Resolve the YOLO script next to the shared cellpose script so both
        // production (bundled Resources) and dev (repo) layouts work uniformly.
        guard let scriptURL = Self.locateYOLOScript() else {
            throw DetectionError.modelNotInstalled(modelId: modelId)
        }

        // Verify weights actually exist.
        let weightsURL = weightsPathProvider()
        guard FileManager.default.fileExists(atPath: weightsURL.path) else {
            throw DetectionError.modelNotInstalled(modelId: modelId)
        }

        guard let imageURL = input.imageURL else {
            throw DetectionError.imageDecodeFailed
        }

        var args: [String] = [
            scriptURL.path,
            "--image", imageURL.path,
            "--weights", weightsURL.path,
            "--pxPerUm", String(input.pxPerUm),
            "--conf", String(input.confidenceThreshold),
        ]
        if input.backgroundSubtract {
            args += ["--bg-subtract", "--rolling-ball-radius", String(input.rollingBallRadius)]
        }
        args += [
            "--small-threshold", String(input.smallThreshold),
            "--large-threshold", String(input.largeThreshold),
        ]
        if !input.useGPU {
            // Honour the user's "Use GPU" preference. The yolo sidecar accepts
            // `--no-gpu` to force Ultralytics onto CPU (no MPS, no CUDA).
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

        // Structured error from the script (e.g. ultralytics-not-installed)?
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
            let id = UUID(uuidString: c.id) ?? UUID()
            return DetectedCell(
                id: id,
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

    // MARK: — Script locator

    private static func locateYOLOScript() -> URL? {
        if let staged = PythonRuntime.stagedScriptURL(named: "yolo_detect.py") {
            return staged
        }
        return PythonRuntime.bundledPythonURL(named: "yolo_detect.py")
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

                let resumed = YOLOResumeFlag()

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

private final class YOLOResumeFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false
    func markAndCheck() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if fired { return false }
        fired = true
        return true
    }
}
