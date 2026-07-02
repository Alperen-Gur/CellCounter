import Foundation

/// Family-specific `DetectionService` for the Cellpose pipeline.
///
/// Instantiated per-model-id (cp-cyto3, cp-cyto3-r, cp-cyto2, cp-nuclei) so the
/// registry can route a detection call straight to the right cellpose
/// `model_type` string + flags. Any missing-binary / non-zero exit / parse
/// failure throws a `DetectionError` so the UI can surface the real cause.
struct CellposeDetectionService: DetectionService {
    let modelId: String

    /// App model id -> cellpose `model_type` string passed via `--model`.
    /// Note `cp-cyto3-r` also pipes through with `--restore`.
    private static let modelTypeMap: [String: String] = [
        "cp-cyto3":   "cyto3",
        "cp-cyto3-r": "cyto3",
        "cp-cyto2":   "cyto2",
        "cp-nuclei":  "nuclei",
    ]

    private static let restoreModelIds: Set<String> = ["cp-cyto3-r"]

    init(modelId: String) {
        self.modelId = modelId
    }

    func detect(_ input: DetectionInput) async throws -> DetectionResult {
        // Resolve sidecar paths via the shared availability probe so we share the
        // venv created by `scripts/install_python.sh` with the rest of the app.
        let availability = CellposeAvailability.detect()
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

        // The DetectionInput's modelId tells us what the *caller* asked for; we
        // prefer our own `modelId` (set at init) when it's a known cellpose id
        // so the registry's routing decision wins. If neither matches, forward
        // the caller's id verbatim and let the sidecar's `cp-` prefix-strip kick in.
        let resolvedAppId = Self.modelTypeMap[modelId] != nil ? modelId : input.modelId
        let cellposeModel = Self.modelTypeMap[resolvedAppId] ?? resolvedAppId
        let needsRestore = Self.restoreModelIds.contains(resolvedAppId)

        let channelArg = input.channels.map(String.init).joined(separator: ",")
        let isDefaultChannels = (input.channels == [0, 0] || input.channels.isEmpty)

        var args = [
            scriptURL.path,
            "--image", imageURL.path,
            "--model", cellposeModel,
            "--pxPerUm", String(input.pxPerUm),
            "--conf", String(input.confidenceThreshold),
        ]
        if !isDefaultChannels {
            args += ["--channels", channelArg]
        }
        if needsRestore {
            args += ["--restore"]
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
            // Pass-13: SIGTERM (15) / SIGKILL (9) and their Process-API
            // mirrored values (-15, -9, 143, 137) mean the host terminated
            // the subprocess on purpose — Cancel button, app quit, or
            // ChildProcessTracker.terminateAll(). Treating those as
            // "detection failed" leaves an error banner sitting on the image
            // forever. Throw a distinct .cancelled so callers can swallow it.
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
            // Pass-14: lift contour pairs into CGPoint array (skip malformed pairs).
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

    // MARK: — Sidecar plumbing (kept self-contained per the family-service contract)

    private struct SidecarOutcome {
        var exitCode: Int32
        var stdout: Data
        var stderr: Data
    }

    /// Spawn the sidecar Process off the main actor and bridge its termination
    /// handler into structured concurrency. The continuation is resumed at
    /// most once thanks to `ResumeFlag`.
    ///
    /// Pass-13: stderr is streamed line-by-line into a `ccDetectionStage`
    /// notification so the UI can show what cellpose is actually doing
    /// (loading model, computing flows, running dynamics, …). Without this
    /// the ProcessingView bar sits at 0% for 60–90s and looks broken.
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

                // Collected stderr — we still want the full buffer for error
                // surfacing on non-zero exit, but we *also* tap each line as
                // it arrives so the UI can show live progress.
                let stderrAccumulator = CellposeStderrSink()
                stderrPipe.fileHandleForReading.readabilityHandler = { handle in
                    let chunk = handle.availableData
                    if chunk.isEmpty { return } // EOF
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

                // Pass-14: drain stdout CONCURRENTLY too. Reading only at
                // terminationHandler time deadlocks for any payload bigger
                // than the OS pipe buffer (~16–64 KB on macOS). A 130-cell
                // JSON payload is ~60 KB — right at the limit. The Python
                // side blocks on `sys.stdout.write(...)`, we block on
                // `process.terminationHandler` never firing, and the user
                // sits forever on "serializing JSON…".
                let stdoutAccumulator = CellposeStderrSink()
                stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
                    let chunk = handle.availableData
                    if chunk.isEmpty { return } // EOF
                    stdoutAccumulator.append(chunk)
                }

                let resumed = CellposeResumeFlag()

                process.terminationHandler = { proc in
                    // Detach BOTH readability handlers before final drain —
                    // otherwise they can race the readToEnd() calls below.
                    stderrPipe.fileHandleForReading.readabilityHandler = nil
                    stdoutPipe.fileHandleForReading.readabilityHandler = nil
                    // Pull anything still sitting in the OS pipe buffer that
                    // the handlers missed between the last fire and EOF.
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
                    // Pass-13: hand the Process to the global tracker so it
                    // gets SIGTERM'd on app quit. terminationHandler will
                    // un-register via the chained callback the tracker installs.
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

/// Thread-safe accumulator for the cellpose subprocess's stderr stream.
/// readabilityHandler fires on a background queue and the terminationHandler
/// reads `snapshot()` — both serialize through `lock`.
private final class CellposeStderrSink: @unchecked Sendable {
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

/// One-shot resume guard for the Process termination handler.
private final class CellposeResumeFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false
    func markAndCheck() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if fired { return false }
        fired = true
        return true
    }
}
