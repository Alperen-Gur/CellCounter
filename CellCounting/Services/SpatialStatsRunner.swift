import Foundation

// MARK: — Spatial-statistics runner
//
// Resolves and invokes the standalone `spatial_stats.py` sidecar
// (`CellCounting/python/spatial_stats.py`, wrapping the pure functions in
// `_spatial.py`) and decodes its JSON into `Domain/SpatialStats.swift`.
//
// Structured exactly like `Services/AreaAssaysRunner.swift` — read that file
// first. Same two sidecar-forced differences as `PunctaRunner`: the result
// dict is printed at the TOP LEVEL (no `{"ok","mode","result"}` envelope),
// and a known failure prints `{"error","hint"}` to stdout with a non-zero
// exit.
//
// The cheapest of the four assay sidecars: no pixel data is loaded at all,
// only centroids, so this is safe to re-run on every detection/ROI change.
//
// CALIBRATION: `--pxPerUm` is PIXELS PER MICROMETRE — `AppState.pxPerUm`
// verbatim (e.g. 2.6), NOT the reciprocal `pixel_size_um`. Every nearest-
// neighbour distance, density radius and the Clark-Evans R depend on it.
enum SpatialStatsRunner {

    private static let scriptName = "spatial_stats.py"

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
                + "Cellpose once — spatial statistics reuse the same environment "
                + "(numpy / scipy); no Cellpose model download is needed for them.")
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
        return .unavailable(reason: "spatial_stats.py isn't staged or bundled in this build.")
    }

    // MARK: Errors

    enum SpatialStatsRunnerError: LocalizedError {
        case notAvailable(reason: String)
        case noCells
        case sidecarFailed(String)
        case cancelled
        case decodeFailed(String)

        var errorDescription: String? {
            switch self {
            case .notAvailable(let reason): return reason
            case .noCells: return "This image has no detected cells to analyse."
            case .sidecarFailed(let detail): return "Spatial statistics failed: \(detail)"
            case .cancelled: return "Cancelled."
            case .decodeFailed(let detail): return "Couldn't parse the sidecar's output: \(detail)"
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

    // MARK: Cell input

    /// One `--cells-json` entry: `{"label", "cx", "cy"}` in source-image pixel
    /// space. `label` is echoed back verbatim on each `per_cell` row.
    private struct CentroidEntry: Encodable {
        let label: String
        let cx: Double
        let cy: Double
    }

    private static func writeTempJSON<T: Encodable>(_ value: T) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cc-spatial-cells-\(UUID().uuidString).json")
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
            throw SpatialStatsRunnerError.notAvailable(reason: reason)
        }

        let fullArgs = [scriptURL.path] + args
        let outcome: SidecarOutcome
        do {
            outcome = try await SidecarProcessRunner.run(pythonURL: pythonURL,
                                                        args: fullArgs,
                                                        trackerKind: .other)
        } catch {
            throw SpatialStatsRunnerError.sidecarFailed(error.localizedDescription)
        }

        do {
            try outcome.throwIfFailed()
        } catch DetectionError.cancelled {
            throw SpatialStatsRunnerError.cancelled
        } catch DetectionError.sidecarFailed(let exitCode, let stderr) {
            if let payload = try? JSONDecoder().decode(SidecarErrorPayload.self, from: outcome.stdout) {
                throw SpatialStatsRunnerError.sidecarFailed(payload.text)
            }
            let tail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw SpatialStatsRunnerError.sidecarFailed(
                tail.isEmpty ? "exit code \(exitCode)" : String(tail.suffix(400)))
        } catch {
            throw SpatialStatsRunnerError.sidecarFailed(error.localizedDescription)
        }

        do {
            return try JSONDecoder().decode(R.self, from: outcome.stdout)
        } catch {
            let stdoutText = String(data: outcome.stdout, encoding: .utf8) ?? ""
            throw SpatialStatsRunnerError.decodeFailed(String(stdoutText.prefix(400)))
        }
    }

    // MARK: Compute

    /// Nearest-neighbour distance, local density and the Clark-Evans index for
    /// one image's cell centroids.
    ///
    /// - Parameters:
    ///   - cells: the image's detected cells, already confidence/ROI-filtered.
    ///   - pxPerUm: `AppState.pxPerUm` — PIXELS per micrometre, verbatim.
    ///   - widthPx/heightPx: the real image dimensions
    ///     (`ImageRecord.widthPx`/`.heightPx`). Passed explicitly because
    ///     Clark-Evans R is a function of the observed AREA — omitting them
    ///     makes the sidecar infer a padded centroid bounding box, which
    ///     understates the field and biases R upward.
    static func compute(cells: [DetectedCell],
                        pxPerUm: Double,
                        widthPx: Int,
                        heightPx: Int,
                        params: SpatialStatsParams) async throws -> SpatialStatsResult {
        guard !cells.isEmpty else { throw SpatialStatsRunnerError.noCells }

        let entries = cells.enumerated().map { index, cell in
            CentroidEntry(label: "Cell \(index + 1)", cx: cell.cx, cy: cell.cy)
        }
        let cellsFileURL = try writeTempJSON(entries)
        defer { try? FileManager.default.removeItem(at: cellsFileURL) }

        var args = [
            "--cells-json", cellsFileURL.path,
            "--pxPerUm", String(pxPerUm),
            "--radius-um", String(params.radiusUm),
        ]
        if widthPx > 0 { args += ["--width", String(widthPx)] }
        if heightPx > 0 { args += ["--height", String(heightPx)] }
        if params.heatmap {
            args += ["--heatmap",
                     "--heatmap-bin-um", String(params.heatmapBinUm),
                     "--heatmap-max-bins", String(params.heatmapMaxBins)]
        }
        return try await run(SpatialStatsResult.self, args: args)
    }
}
