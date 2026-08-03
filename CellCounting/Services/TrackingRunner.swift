import Foundation

// MARK: — Cell tracking / migration runner
//
// Resolves and invokes the standalone `track_cells.py` sidecar
// (`CellCounting/python/track_cells.py`, wrapping `_tracking.track()`) and
// decodes its JSON into `Domain/TrackingModel.swift`.
//
// Structured exactly like `Services/AreaAssaysRunner.swift` — read that file
// first. Same two sidecar-forced differences as `PunctaRunner`: the result
// dict is printed at the TOP LEVEL (no envelope), and a known failure prints
// `{"error","hint"}` to stdout with a non-zero exit.
//
// No pixel data crosses this boundary: tracking links per-frame CENTROIDS
// that were already detected, so the input is one JSON file, not N images.
//
// CALIBRATION: `--px-per-um` (note the hyphenated spelling this script uses,
// unlike puncta/spatial's `--pxPerUm`) is PIXELS PER MICROMETRE — `AppState
// .pxPerUm` verbatim (e.g. 2.6), NOT the reciprocal `pixel_size_um`. Every
// speed, path length and the max-displacement gate depend on it.
enum TrackingRunner {

    private static let scriptName = "track_cells.py"

    /// A track needs at least two ordered frames. Below this the sidecar's own
    /// degenerate-input branch fires (`message`, exit 0) — the panel checks
    /// this first so it can explain the situation without spawning a process.
    static let minimumFrames = 2

    // MARK: Availability

    enum Availability {
        case available(pythonURL: URL, scriptURL: URL)
        case unavailable(reason: String)
    }

    /// DEV-ONLY fallback — see `AreaAssaysRunner.devSourceTreeScriptURL`.
    private static func devSourceTreeScriptURL(named name: String) -> URL? {
        let thisFile = URL(fileURLWithPath: #filePath)
        let servicesDir = thisFile.deletingLastPathComponent()
        let ccDir = servicesDir.deletingLastPathComponent()
        let candidate = ccDir.appendingPathComponent("python/\(name)")
        return FileManager.default.fileExists(atPath: candidate.path) ? candidate : nil
    }

    static func resolve() -> Availability {
        let py = FileStore.shared.pythonInterpreterURL
        guard FileManager.default.isExecutableFile(atPath: py.path) else {
            return .unavailable(reason:
                "The shared Python environment isn't installed yet. Open Models and install "
                + "Cellpose once — tracking reuses the same environment (numpy / scipy); "
                + "no Cellpose model download is needed for it.")
        }
        if let staged = PythonRuntime.stagedScriptURL(named: scriptName) {
            return .available(pythonURL: py, scriptURL: staged)
        }
        if let bundled = PythonRuntime.bundledPythonURL(named: scriptName) {
            return .available(pythonURL: py, scriptURL: bundled)
        }
        if let dev = devSourceTreeScriptURL(named: scriptName) {
            return .available(pythonURL: py, scriptURL: dev)
        }
        return .unavailable(reason: "track_cells.py isn't staged or bundled in this build.")
    }

    // MARK: Errors

    enum TrackingRunnerError: LocalizedError {
        case notAvailable(reason: String)
        case notEnoughFrames(available: Int)
        case sidecarFailed(String)
        case cancelled
        case decodeFailed(String)

        var errorDescription: String? {
            switch self {
            case .notAvailable(let reason):
                return reason
            case .notEnoughFrames(let available):
                return available <= 1
                    ? "Tracking needs an ordered series of at least 2 frames — only "
                      + "\(available) image in this batch has detections. Import the whole "
                      + "time-lapse as one batch (frames in acquisition order) and run "
                      + "detection on each frame."
                    : "Tracking needs at least 2 frames with detections; found \(available)."
            case .sidecarFailed(let detail): return "Tracking failed: \(detail)"
            case .cancelled: return "Cancelled."
            case .decodeFailed(let detail): return "Couldn't parse the tracker's output: \(detail)"
            }
        }
    }

    private struct SidecarErrorPayload: Decodable {
        let error: String
        let hint: String?
        var text: String {
            guard let hint, !hint.isEmpty else { return error }
            return "\(error) — \(hint)"
        }
    }

    // MARK: Frame input

    /// One detection inside one frame. `id` is echoed straight back onto the
    /// matching `TrackPoint.source_id`.
    private struct FrameDetection: Encodable {
        let cx: Double
        let cy: Double
        let id: String
    }

    /// `--input`'s top-level shape: `{"frames": [[…], […]]}`, ONE inner array
    /// per timepoint, in acquisition order. An empty inner array is legal — it
    /// means "no cells detected in that frame", which just can't extend a
    /// track through it.
    private struct FramesPayload: Encodable {
        let frames: [[FrameDetection]]
    }

    private static func writeTempJSON<T: Encodable>(_ value: T) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cc-tracking-frames-\(UUID().uuidString).json")
        try JSONEncoder().encode(value).write(to: url, options: .atomic)
        return url
    }

    // MARK: Core runner

    private static func run<R: Decodable>(_ resultType: R.Type,
                                          args: [String]) async throws -> R {
        let pythonURL: URL
        let scriptURL: URL
        switch resolve() {
        case .available(let py, let script):
            pythonURL = py
            scriptURL = script
        case .unavailable(let reason):
            throw TrackingRunnerError.notAvailable(reason: reason)
        }

        let fullArgs = [scriptURL.path] + args
        let outcome: SidecarOutcome
        do {
            outcome = try await SidecarProcessRunner.run(pythonURL: pythonURL,
                                                        args: fullArgs,
                                                        trackerKind: .other)
        } catch {
            throw TrackingRunnerError.sidecarFailed(error.localizedDescription)
        }

        do {
            try outcome.throwIfFailed()
        } catch DetectionError.cancelled {
            throw TrackingRunnerError.cancelled
        } catch DetectionError.sidecarFailed(let exitCode, let stderr) {
            if let payload = try? JSONDecoder().decode(SidecarErrorPayload.self, from: outcome.stdout) {
                throw TrackingRunnerError.sidecarFailed(payload.text)
            }
            let tail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw TrackingRunnerError.sidecarFailed(
                tail.isEmpty ? "exit code \(exitCode)" : String(tail.suffix(400)))
        } catch {
            throw TrackingRunnerError.sidecarFailed(error.localizedDescription)
        }

        do {
            return try JSONDecoder().decode(R.self, from: outcome.stdout)
        } catch {
            let stdoutText = String(data: outcome.stdout, encoding: .utf8) ?? ""
            throw TrackingRunnerError.decodeFailed(String(stdoutText.prefix(400)))
        }
    }

    // MARK: Track

    /// Link centroids across an ORDERED image series into per-cell tracks.
    ///
    /// - Parameters:
    ///   - frames: one entry per timepoint, IN ACQUISITION ORDER — the caller
    ///     is responsible for that ordering (the panel uses the current
    ///     batch's images sorted by `importedAt`, which is the order they were
    ///     imported/dropped). Frames with no detections are kept in place as
    ///     empty arrays so the frame INDEX still maps to real elapsed time.
    ///   - pxPerUm: `AppState.pxPerUm` — PIXELS per micrometre, verbatim.
    ///   - frameIntervalMin: minutes between consecutive frames.
    static func track(frames: [[DetectedCell]],
                      pxPerUm: Double,
                      frameIntervalMin: Double,
                      maxDisplacementUm: Double) async throws -> TrackingPayload {
        // Degenerate input is the sidecar's business (it reports it through
        // `message`, exit 0) — but a series that can't possibly produce a
        // track is worth catching here so the user gets a specific, actionable
        // sentence instead of a spawned process and an empty panel.
        let framesWithCells = frames.filter { !$0.isEmpty }.count
        guard frames.count >= minimumFrames, framesWithCells >= minimumFrames else {
            throw TrackingRunnerError.notEnoughFrames(available: framesWithCells)
        }

        let payload = FramesPayload(frames: frames.map { frame in
            frame.map { FrameDetection(cx: $0.cx, cy: $0.cy, id: $0.id.uuidString) }
        })
        let inputURL = try writeTempJSON(payload)
        defer { try? FileManager.default.removeItem(at: inputURL) }

        let args = [
            "--input", inputURL.path,
            "--px-per-um", String(pxPerUm),
            "--frame-interval-min", String(frameIntervalMin),
            "--max-displacement-um", String(maxDisplacementUm),
        ]
        return try await run(TrackingPayload.self, args: args)
    }
}
