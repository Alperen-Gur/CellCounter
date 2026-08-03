import Foundation

// MARK: — Neurite outgrowth runner
//
// Resolves and invokes the standalone `neurite_outgrowth.py` sidecar
// (`CellCounting/python/neurite_outgrowth.py`, wrapping `_neurite.analyze()`)
// and decodes its JSON into `Domain/NeuriteModel.swift`.
//
// Structured exactly like `Services/AreaAssaysRunner.swift` — read that file
// first. Same two sidecar-forced differences as `PunctaRunner`: the result
// dict is printed at the TOP LEVEL (no envelope), and a known failure prints
// `{"error","hint"}` to stdout with a non-zero exit.
//
// INPUT SHAPE, worth knowing before reading the panel: `--neurite-mask` is a
// MASK, not a raw micrograph — `neurite_outgrowth._load_mask_image` treats
// every NONZERO pixel as neurite foreground. For a dark-background
// fluorescence image of a neurite stain that is a usable approximation (which
// is why the panel defaults it to the current image), but a real segmented /
// thresholded mask is the correct input, so the panel also lets the user pick
// one. A bright-field image with a light background would come out almost
// entirely "foreground" and produce meaningless lengths.
//
// Somas are supplied as `--soma-centroids` (a JSON file of the image's own
// detected cells) rather than `--soma-mask`: CellCounter stores per-cell
// centroids/contours, not a labelled soma raster. The sidecar then models
// each soma as a synthetic disc of `--soma-radius-um` — see `_neurite.py`'s
// module docstring for what that approximation costs.
//
// CALIBRATION: `--px-per-um` (hyphenated, like `track_cells.py`) is PIXELS
// PER MICROMETRE — `AppState.pxPerUm` verbatim (e.g. 2.6), NOT the reciprocal
// `pixel_size_um`. Every skeleton length and the soma-disc radius depend on it.
enum NeuriteRunner {

    private static let scriptName = "neurite_outgrowth.py"

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
                + "Cellpose once — neurite analysis reuses the same environment "
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
        return .unavailable(reason: "neurite_outgrowth.py isn't staged or bundled in this build.")
    }

    // MARK: Errors

    enum NeuriteRunnerError: LocalizedError {
        case notAvailable(reason: String)
        case noImageSelected
        case sidecarFailed(String)
        case cancelled
        case decodeFailed(String)

        var errorDescription: String? {
            switch self {
            case .notAvailable(let reason): return reason
            case .noImageSelected: return "Open an image first."
            case .sidecarFailed(let detail): return "Neurite analysis failed: \(detail)"
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

    // MARK: Soma input

    /// One `--soma-centroids` entry. `id` is echoed back as
    /// `NeuriteCellStat.soma_id`, which `NeuritePanel` renders as
    /// "Cell <id>" — so this carries the bare ordinal, not "Cell 1".
    private struct SomaCentroid: Encodable {
        let id: String
        let cx: Double
        let cy: Double
    }

    /// `--soma-centroids`' top-level shape: `{"cells": [...]}`.
    private struct SomaPayload: Encodable {
        let cells: [SomaCentroid]
    }

    private static func writeTempJSON<T: Encodable>(_ value: T) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cc-neurite-somas-\(UUID().uuidString).json")
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
            throw NeuriteRunnerError.notAvailable(reason: reason)
        }

        let fullArgs = [scriptURL.path] + args
        let outcome: SidecarOutcome
        do {
            outcome = try await SidecarProcessRunner.run(pythonURL: pythonURL,
                                                        args: fullArgs,
                                                        trackerKind: .other)
        } catch {
            throw NeuriteRunnerError.sidecarFailed(error.localizedDescription)
        }

        do {
            try outcome.throwIfFailed()
        } catch DetectionError.cancelled {
            throw NeuriteRunnerError.cancelled
        } catch DetectionError.sidecarFailed(let exitCode, let stderr) {
            if let payload = try? JSONDecoder().decode(SidecarErrorPayload.self, from: outcome.stdout) {
                throw NeuriteRunnerError.sidecarFailed(payload.text)
            }
            let tail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw NeuriteRunnerError.sidecarFailed(
                tail.isEmpty ? "exit code \(exitCode)" : String(tail.suffix(400)))
        } catch {
            throw NeuriteRunnerError.sidecarFailed(error.localizedDescription)
        }

        do {
            return try JSONDecoder().decode(R.self, from: outcome.stdout)
        } catch {
            let stdoutText = String(data: outcome.stdout, encoding: .utf8) ?? ""
            throw NeuriteRunnerError.decodeFailed(String(stdoutText.prefix(400)))
        }
    }

    // MARK: Analyze

    /// Skeletonize `neuriteMaskURL`, punch out each soma, and attribute the
    /// remaining skeleton to the nearest soma.
    ///
    /// - Parameters:
    ///   - neuriteMaskURL: the neurite mask (or, as a usable approximation for
    ///     a dark-background fluorescence stain, the current image itself —
    ///     see this file's header note).
    ///   - pxPerUm: `AppState.pxPerUm` — PIXELS per micrometre, verbatim.
    ///   - somas: the image's detected cells, already confidence/ROI-filtered.
    ///     Pass `[]` for whole-image skeleton totals with no per-cell
    ///     breakdown — a legitimate result the sidecar reports via `message`,
    ///     not an error.
    ///   - somaRadiusUm: synthetic soma-disc radius; only meaningful because
    ///     we supply centroids rather than a real soma footprint.
    static func analyze(neuriteMaskURL: URL,
                        pxPerUm: Double,
                        somas: [DetectedCell],
                        somaRadiusUm: Double) async throws -> NeuritePayload {
        var somaFileURL: URL? = nil
        if !somas.isEmpty {
            let payload = SomaPayload(cells: somas.enumerated().map { index, cell in
                SomaCentroid(id: "\(index + 1)", cx: cell.cx, cy: cell.cy)
            })
            somaFileURL = try writeTempJSON(payload)
        }
        defer {
            if let somaFileURL { try? FileManager.default.removeItem(at: somaFileURL) }
        }

        var args = [
            "--neurite-mask", neuriteMaskURL.path,
            "--px-per-um", String(pxPerUm),
            "--soma-radius-um", String(somaRadiusUm),
        ]
        if let somaFileURL { args += ["--soma-centroids", somaFileURL.path] }
        return try await run(NeuritePayload.self, args: args)
    }
}
