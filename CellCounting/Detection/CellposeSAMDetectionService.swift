import Foundation

/// Pass-16: family-specific `DetectionService` for Cellpose-SAM (4.x / CPSAM).
///
/// Structurally identical to `CellposeDetectionService` (3.x) but points at the
/// `venv4/bin/python3` interpreter and the `cellpose4_detect.py` sidecar that
/// C1 ships. The two services coexist; AppState picks one based on the
/// active model id.
///
/// First-run note: cellpose 4 lazily downloads ~1.15 GB of CPSAM transformer
/// weights into `~/.cellpose/models/` the first time `CellposeModel()` is
/// constructed. C1's `cellpose4_detect.py` emits progress lines to stderr
/// during that download which surface to the ProcessingView through the
/// existing `ccDetectionStage` notification used by the 3.x service.
struct CellposeSAMDetectionService: DetectionService {
    let modelId: String

    init(modelId: String) {
        self.modelId = modelId
    }

    func detect(_ input: DetectionInput) async throws -> DetectionResult {
        let availability = Cellpose4Availability.detect()
        let pythonURL: URL
        let scriptURL: URL
        switch availability {
        case .available(let py, let script):
            pythonURL = py
            scriptURL = script
        case .missingScripts, .missingVenv, .missingInstaller, .venvBroken:
            throw DetectionError.modelNotInstalled(modelId: modelId)
        }

        guard let imageURL = input.imageURL else {
            throw DetectionError.imageDecodeFailed
        }

        // The cp4 sidecar only takes a single architecture (CPSAM); we still
        // pass --model for forward compatibility in case C1 ships variants.
        let channelArg = input.channels.map(String.init).joined(separator: ",")
        let isDefaultChannels = (input.channels == [0, 0] || input.channels.isEmpty)

        var args = [
            scriptURL.path,
            "--image", imageURL.path,
            "--model", "cpsam",
            "--pxPerUm", String(input.pxPerUm),
            "--conf", String(input.confidenceThreshold),
        ]
        if !isDefaultChannels {
            args += ["--channels", channelArg]
        }
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
            args += ["--no-gpu"]
        }

        let outcome: SidecarOutcome
        do {
            outcome = try await Self.runSidecar(pythonURL: pythonURL, args: args)
        } catch {
            throw DetectionError.sidecarFailed(exitCode: -1, stderr: error.localizedDescription)
        }

        if outcome.exitCode != 0 {
            let signalCodes: Set<Int32> = [15, -15, 143, 9, -9, 137]
            if signalCodes.contains(outcome.exitCode) {
                throw DetectionError.cancelled
            }
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
            let id = UUID(uuidString: c.id) ?? UUID()
            let contour: [CGPoint]? = c.contour_px.flatMap { pairs in
                let pts = pairs.compactMap { p -> CGPoint? in
                    guard p.count >= 2 else { return nil }
                    return CGPoint(x: p[0], y: p[1])
                }
                return pts.count >= 3 ? pts : nil
            }
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
                isManual: c.is_manual ?? false,
                contourPx: contour
            )
        }
        return DetectionResult(cells: cells,
                               imageWidth: decoded.width,
                               imageHeight: decoded.height,
                               imageStats: decoded.image_stats)
    }

    // MARK: — Sidecar plumbing

    private struct SidecarOutcome {
        var exitCode: Int32
        var stdout: Data
        var stderr: Data
    }

    /// Mirror of the 3.x runner: detached Process, concurrent stdout+stderr
    /// drainage, one-shot continuation resume, stderr lines piped to the UI
    /// via `ccDetectionStage`. The duplication is deliberate — keeps the
    /// hot detection path in one file per family and lets the 3.x version
    /// stay untouched.
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

                let stderrAccumulator = CellposeSAMStderrSink()
                stderrPipe.fileHandleForReading.readabilityHandler = { handle in
                    let chunk = handle.availableData
                    if chunk.isEmpty { return }
                    stderrAccumulator.append(chunk)
                    guard let text = String(data: chunk, encoding: .utf8) else { return }
                    for raw in text.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
                        let line = String(raw).trimmingCharacters(in: .whitespaces)
                        guard !line.isEmpty else { continue }
                        Task { @MainActor in
                            NotificationCenter.default.post(
                                name: .ccDetectionStage,
                                object: nil,
                                userInfo: ["line": line])
                        }
                    }
                }

                let stdoutAccumulator = CellposeSAMStderrSink()
                stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
                    let chunk = handle.availableData
                    if chunk.isEmpty { return }
                    stdoutAccumulator.append(chunk)
                }

                let resumed = CellposeSAMResumeFlag()

                process.terminationHandler = { proc in
                    stderrPipe.fileHandleForReading.readabilityHandler = nil
                    stdoutPipe.fileHandleForReading.readabilityHandler = nil
                    if let tailOut = try? stdoutPipe.fileHandleForReading.readToEnd() {
                        stdoutAccumulator.append(tailOut)
                    }
                    if let tailErr = try? stderrPipe.fileHandleForReading.readToEnd() {
                        stderrAccumulator.append(tailErr)
                    }
                    if resumed.markAndCheck() {
                        continuation.resume(returning: SidecarOutcome(
                            exitCode: proc.terminationStatus,
                            stdout: stdoutAccumulator.snapshot(),
                            stderr: stderrAccumulator.snapshot()))
                    }
                }

                do {
                    try process.run()
                    Task { @MainActor in
                        ChildProcessTracker.shared.register(process, kind: .detection)
                    }
                } catch {
                    stderrPipe.fileHandleForReading.readabilityHandler = nil
                    stdoutPipe.fileHandleForReading.readabilityHandler = nil
                    if resumed.markAndCheck() {
                        continuation.resume(throwing: error)
                    }
                }
            }
        }
    }
}

private final class CellposeSAMStderrSink: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    func append(_ chunk: Data) {
        lock.lock(); defer { lock.unlock() }
        buffer.append(chunk)
    }
    func snapshot() -> Data {
        lock.lock(); defer { lock.unlock() }
        return buffer
    }
}

private final class CellposeSAMResumeFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false
    func markAndCheck() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if fired { return false }
        fired = true
        return true
    }
}
