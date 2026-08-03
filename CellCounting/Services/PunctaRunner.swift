import Foundation
import CoreGraphics

// MARK: — Puncta / foci runner
//
// Resolves and invokes the standalone `puncta_detect.py` sidecar
// (`CellCounting/python/puncta_detect.py`, wrapping the pure functions in
// `_assays_puncta.py`) and decodes its JSON into the `Domain/
// PunctaAssay.swift` types.
//
// Structured exactly like `Services/AreaAssaysRunner.swift` — read that file
// first; the resolve/run/error shape here is deliberately identical so the
// two read as one family. Two differences, both forced by the sidecar:
//
//   1. `puncta_detect.py` prints its result dict at the TOP LEVEL (no
//      `{"ok","mode","result"}` envelope), so `run()` decodes `PunctaResult`
//      straight from stdout.
//   2. On a known failure it prints `{"error", "hint"}` to STDOUT and exits
//      non-zero, so the failure path sniffs stdout for that shape before
//      falling back to stderr — otherwise the user sees a bare exit code.
//
// Like the area assays, this is independent of `CellposeAvailability` and the
// per-model `*DetectionService` family: `puncta_detect.py` imports only
// numpy / scikit-image / scipy / Pillow, which every model family's install
// already provides. It reuses `FileStore.pythonInterpreterURL` purely because
// that is where those packages live.
//
// CALIBRATION: `--pxPerUm` is PIXELS PER MICROMETRE — the app's `AppState
// .pxPerUm` convention (e.g. 2.6), NOT the reciprocal `pixel_size_um` (µm per
// pixel) that `_imageio.load_planes` reports in its metadata. Pass
// `state.pxPerUm` through unchanged; inverting it silently rescales every
// spot diameter and assignment distance.
enum PunctaRunner {

    private static let scriptName = "puncta_detect.py"

    // MARK: Availability

    enum Availability {
        case available(pythonURL: URL, scriptURL: URL)
        case unavailable(reason: String)
    }

    /// DEV-ONLY fallback — see the identical helper (and its full rationale)
    /// in `AreaAssaysRunner.devSourceTreeScriptURL`. `#filePath` is a
    /// compile-time constant naming THIS file's location on the build
    /// machine, so it never resolves for a distributed build.
    private static func devSourceTreeScriptURL(named name: String) -> URL? {
        let thisFile = URL(fileURLWithPath: #filePath)          // .../CellCounting/Services/PunctaRunner.swift
        let servicesDir = thisFile.deletingLastPathComponent()  // .../CellCounting/Services/
        let ccDir = servicesDir.deletingLastPathComponent()     // .../CellCounting/
        let candidate = ccDir.appendingPathComponent("python/\(name)")
        return FileManager.default.fileExists(atPath: candidate.path) ? candidate : nil
    }

    static func resolve() -> Availability {
        let py = FileStore.shared.pythonInterpreterURL
        guard FileManager.default.isExecutableFile(atPath: py.path) else {
            return .unavailable(reason:
                "The shared Python environment isn't installed yet. Open Models and install "
                + "Cellpose once — puncta detection reuses the same environment "
                + "(numpy / scikit-image); no Cellpose model download is needed for it.")
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
        return .unavailable(reason: "puncta_detect.py isn't staged or bundled in this build.")
    }

    // MARK: Errors

    enum PunctaRunnerError: LocalizedError {
        case notAvailable(reason: String)
        case noImageSelected
        case sidecarFailed(String)
        case cancelled
        case decodeFailed(String)

        var errorDescription: String? {
            switch self {
            case .notAvailable(let reason): return reason
            case .noImageSelected: return "Open an image first."
            case .sidecarFailed(let detail): return "Spot detection failed: \(detail)"
            case .cancelled: return "Cancelled."
            case .decodeFailed(let detail): return "Couldn't parse the detector's output: \(detail)"
            }
        }
    }

    /// The `{"error": …, "hint": …}` shape every CellCounter sidecar prints to
    /// stdout on a known failure (`emit_error`).
    private struct SidecarErrorPayload: Decodable {
        let error: String
        let hint: String?
        var text: String {
            guard let hint, !hint.isEmpty else { return error }
            return "\(error) — \(hint)"
        }
    }

    // MARK: Cell input

    /// One `--cells-json` entry. Optional fields are omitted from the encoded
    /// JSON (synthesized `encode(to:)` uses `encodeIfPresent`), so an entry
    /// carries EITHER a polygon or a centroid — which is exactly how
    /// `puncta_detect._load_cells_json` routes them.
    private struct CellsJSONEntry: Encodable {
        let label: String
        /// `[[x, y], …]` in source-image pixel space. `puncta_detect.py`
        /// accepts this key as an alias for `polygon`.
        let contour_px: [[Double]]?
        let cx: Double?
        let cy: Double?
    }

    /// Serialize `cells` for `--cells-json`.
    ///
    /// All-or-nothing on polygons, on purpose: `puncta_detect._load_cells_json`
    /// takes the polygon path as soon as ANY entry has a usable polygon and
    /// DROPS every centroid-only entry (a cell needs a shape to be rasterized
    /// into the label map). Mixing therefore silently loses cells. So we send
    /// polygons only when every cell has one, and centroids otherwise.
    private static func cellsJSON(for cells: [DetectedCell]) -> [CellsJSONEntry] {
        let allHavePolygons = !cells.isEmpty && cells.allSatisfy { ($0.contourPx?.count ?? 0) >= 3 }
        return cells.enumerated().map { index, cell in
            let label = "Cell \(index + 1)"
            if allHavePolygons, let contour = cell.contourPx {
                return CellsJSONEntry(label: label,
                                      contour_px: contour.map { [Double($0.x), Double($0.y)] },
                                      cx: nil, cy: nil)
            }
            return CellsJSONEntry(label: label, contour_px: nil, cx: cell.cx, cy: cell.cy)
        }
    }

    /// True when `cellsJSON(for:)` will emit exact per-cell polygons rather
    /// than the nearest-centroid fallback — surfaced in the UI so the user
    /// knows which assignment mode produced a given result.
    static func usesPolygonAssignment(_ cells: [DetectedCell]) -> Bool {
        !cells.isEmpty && cells.allSatisfy { ($0.contourPx?.count ?? 0) >= 3 }
    }

    private static func writeTempJSON<T: Encodable>(_ value: T) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cc-puncta-cells-\(UUID().uuidString).json")
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
            throw PunctaRunnerError.notAvailable(reason: reason)
        }

        let fullArgs = [scriptURL.path] + args
        let outcome: SidecarOutcome
        do {
            outcome = try await SidecarProcessRunner.run(pythonURL: pythonURL,
                                                        args: fullArgs,
                                                        trackerKind: .other)
        } catch {
            throw PunctaRunnerError.sidecarFailed(error.localizedDescription)
        }

        do {
            try outcome.throwIfFailed()
        } catch DetectionError.cancelled {
            throw PunctaRunnerError.cancelled
        } catch DetectionError.sidecarFailed(let exitCode, let stderr) {
            // Prefer the structured `{"error","hint"}` the sidecar prints to
            // stdout; fall back to the stderr tail, then the bare exit code.
            if let payload = try? JSONDecoder().decode(SidecarErrorPayload.self, from: outcome.stdout) {
                throw PunctaRunnerError.sidecarFailed(payload.text)
            }
            let tail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw PunctaRunnerError.sidecarFailed(
                tail.isEmpty ? "exit code \(exitCode)" : String(tail.suffix(400)))
        } catch {
            throw PunctaRunnerError.sidecarFailed(error.localizedDescription)
        }

        do {
            return try JSONDecoder().decode(R.self, from: outcome.stdout)
        } catch {
            let stdoutText = String(data: outcome.stdout, encoding: .utf8) ?? ""
            throw PunctaRunnerError.decodeFailed(String(stdoutText.prefix(400)))
        }
    }

    // MARK: Detect

    /// Detect sub-cellular spots in `imageURL` and assign them to `cells`.
    ///
    /// - Parameters:
    ///   - imageURL: the current image (`ImageRecord.storedURL`).
    ///   - pxPerUm: `AppState.pxPerUm` — PIXELS per micrometre, passed through
    ///     verbatim (see this file's header note).
    ///   - cells: the image's detected cells, already confidence/ROI-filtered
    ///     by the caller. Pass `[]` to detect spots without per-cell assignment.
    static func detect(imageURL: URL,
                       pxPerUm: Double,
                       cells: [DetectedCell],
                       params: PunctaParams) async throws -> PunctaResult {
        var cellsFileURL: URL? = nil
        if !cells.isEmpty {
            cellsFileURL = try writeTempJSON(cellsJSON(for: cells))
        }
        defer {
            if let cellsFileURL { try? FileManager.default.removeItem(at: cellsFileURL) }
        }

        var args = [
            "--image", imageURL.path,
            "--pxPerUm", String(pxPerUm),
            "--channel", String(params.channelIndex),
            "--method", params.method.rawValue,
            "--min-diameter-um", String(params.minDiameterUm),
            "--max-diameter-um", String(params.maxDiameterUm),
            "--threshold", String(params.threshold),
            "--overlap", String(params.overlap),
            "--focus-count-threshold", String(params.focusCountThreshold),
        ]
        if let cellsFileURL { args += ["--cells-json", cellsFileURL.path] }
        return try await run(PunctaResult.self, args: args)
    }
}
