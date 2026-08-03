import Foundation

// MARK: — Area / region assays runner
//
// Resolves and invokes the standalone `area_assays_detect.py` sidecar
// (`CellCounting/python/area_assays_detect.py`, wrapping the pure functions
// in `_assays_area.py`) and decodes its JSON into the `Domain/
// AreaAssayModels.swift` types.
//
// Deliberately independent of `CellposeAvailability` / the per-model
// `*DetectionService` family: `area_assays_detect.py` never imports
// cellpose / stardist / torch — it only needs numpy + scikit-image + scipy
// + Pillow, which are already installed for EVERY model family (see
// `scripts/install_python.sh`'s `CC_PIP_PACKAGES`). It reuses the same
// staged venv (`FileStore.pythonInterpreterURL`) purely because that's
// where those packages already live, not because it depends on a detector.
// One real consequence of piggybacking on that shared venv, worth knowing:
// the ONE-TIME Cellpose install (Models tab) is still the thing that
// creates it, so a user has to have run that install once before an area
// assay can run, even though the assay itself never touches Cellpose.
//
// ⚠️ INTEGRATION GAP (see the agent report for full detail): as of this
// pass, `"_assays_area.py"` and `"area_assays_detect.py"` are NOT YET in
// `PythonRuntime.bundledScriptNames` (Services/PythonRuntime.swift) — the
// single source of truth for which `python/*.py` files `PythonRuntime.
// stageScripts()` copies from the app bundle into the writable, executable
// `FileStore.pythonDir` on install/update. Until that array (owned by
// another pass — not edited here) lists these two files, `resolve()` below
// will only find them via the DEV-ONLY source-tree fallback (see
// `devSourceTreeScriptURL`), never in a real installed/distributed .app.
enum AreaAssaysRunner {

    private static let scriptName = "area_assays_detect.py"

    // MARK: Availability

    enum Availability {
        case available(pythonURL: URL, scriptURL: URL)
        case unavailable(reason: String)
    }

    /// DEV-ONLY fallback: resolves a python helper directly from the source
    /// tree via `#filePath`, so the assay is exercisable during development
    /// before the bundling wire-up described above lands. `#filePath` is a
    /// compile-time constant naming THIS source file's location on the
    /// machine that built the binary — meaningless (and harmlessly absent)
    /// on any other machine, so this never fires for a distributed build.
    /// Delete this function (and its one call site below) once
    /// `PythonRuntime.bundledScriptNames` lists the two new scripts and a
    /// real Xcode build stages them like every other sidecar helper.
    private static func devSourceTreeScriptURL(named name: String) -> URL? {
        let thisFile = URL(fileURLWithPath: #filePath)         // .../CellCounting/Services/AreaAssaysRunner.swift
        let servicesDir = thisFile.deletingLastPathComponent() // .../CellCounting/Services/
        let ccDir = servicesDir.deletingLastPathComponent()    // .../CellCounting/
        let candidate = ccDir.appendingPathComponent("python/\(name)")
        return FileManager.default.fileExists(atPath: candidate.path) ? candidate : nil
    }

    static func resolve() -> Availability {
        let py = FileStore.shared.pythonInterpreterURL
        guard FileManager.default.isExecutableFile(atPath: py.path) else {
            return .unavailable(reason:
                "The shared Python environment isn't installed yet. Open Models and install "
                + "Cellpose once — area assays reuse the same environment (numpy / scikit-image), "
                + "no Cellpose model download required for them specifically.")
        }
        // 1) Primary (production) path: staged copy in the writable container.
        if let staged = PythonRuntime.stagedScriptURL(named: scriptName) {
            return .available(pythonURL: py, scriptURL: staged)
        }
        // 2) Bundled-but-not-yet-staged (mirrors the shape of the other
        //    Availability probes; in practice #1 covers it once staged).
        if let bundled = PythonRuntime.bundledPythonURL(named: scriptName) {
            return .available(pythonURL: py, scriptURL: bundled)
        }
        // 3) DEV-ONLY source-tree fallback — see doc comment above.
        if let dev = devSourceTreeScriptURL(named: scriptName) {
            return .available(pythonURL: py, scriptURL: dev)
        }
        return .unavailable(reason:
            "area_assays_detect.py isn't bundled yet (PythonRuntime.bundledScriptNames needs it "
            + "added — see AreaAssaysRunner.swift's header comment).")
    }

    // MARK: Errors

    enum AreaAssayRunnerError: LocalizedError {
        case notAvailable(reason: String)
        case noImageSelected
        case sidecarFailed(String)
        case cancelled
        case decodeFailed(String)

        var errorDescription: String? {
            switch self {
            case .notAvailable(let reason): return reason
            case .noImageSelected: return "Choose an image first."
            case .sidecarFailed(let detail): return "Area assay failed: \(detail)"
            case .cancelled: return "Cancelled."
            case .decodeFailed(let detail): return "Couldn't parse the assay's output: \(detail)"
            }
        }
    }

    /// The `{"error": …, "hint": …}` shape every CellCounter sidecar prints to
    /// stdout on a known failure (`emit_error`). Decoded in preference to the
    /// stderr tail so a corrupt TIFF reads "image-open-failed — cannot identify
    /// image file" instead of "exit code 3". Mirrors `PunctaRunner`,
    /// `SpatialStatsRunner`, `TrackingRunner` and `NeuriteRunner` verbatim.
    private struct SidecarErrorPayload: Decodable {
        let error: String
        let hint: String?
        var text: String {
            guard let hint, !hint.isEmpty else { return error }
            return "\(error) — \(hint)"
        }
    }

    // MARK: Wire envelope

    /// `area_assays_detect.py`'s stdout shape: `{"ok", "mode", "result"}`.
    /// `R` is decoded directly as whichever `AreaAssayModels` type matches
    /// the mode the caller requested — the caller always knows which mode
    /// it invoked, so there's no need to sniff `mode` at runtime. Named `R`
    /// rather than `Result` so it doesn't shadow the standard library's
    /// `Result<Success, Failure>` in this scope.
    private struct Envelope<R: Decodable>: Decodable {
        let ok: Bool
        let mode: String
        let result: R
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
            throw AreaAssayRunnerError.notAvailable(reason: reason)
        }

        let fullArgs = [scriptURL.path] + args
        let outcome: SidecarOutcome
        do {
            outcome = try await SidecarProcessRunner.run(pythonURL: pythonURL,
                                                          args: fullArgs,
                                                          trackerKind: .other)
        } catch {
            throw AreaAssayRunnerError.sidecarFailed(error.localizedDescription)
        }

        do {
            try outcome.throwIfFailed()
        } catch DetectionError.cancelled {
            throw AreaAssayRunnerError.cancelled
        } catch DetectionError.sidecarFailed(let exitCode, let stderr) {
            // Prefer the structured `{"error","hint"}` the sidecar prints to
            // stdout; fall back to the stderr tail, then the bare exit code.
            if let payload = try? JSONDecoder().decode(SidecarErrorPayload.self, from: outcome.stdout) {
                throw AreaAssayRunnerError.sidecarFailed(payload.text)
            }
            let tail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw AreaAssayRunnerError.sidecarFailed(
                tail.isEmpty ? "exit code \(exitCode)" : String(tail.suffix(400)))
        } catch {
            throw AreaAssayRunnerError.sidecarFailed(error.localizedDescription)
        }

        do {
            let envelope = try JSONDecoder().decode(Envelope<R>.self, from: outcome.stdout)
            return envelope.result
        } catch {
            let stdoutText = String(data: outcome.stdout, encoding: .utf8) ?? ""
            throw AreaAssayRunnerError.decodeFailed(String(stdoutText.prefix(400)))
        }
    }

    // MARK: Confluence

    static func confluenceMask(maskURL: URL,
                               pxPerUm: Double,
                               minObjectSizeUm2: Double? = nil) async throws -> ConfluenceResult {
        var args = ["--mode", "confluence", "--pxPerUm", String(pxPerUm), "--mask", maskURL.path]
        if let minObjectSizeUm2 { args += ["--min-object-size-um2", String(minObjectSizeUm2)] }
        return try await run(ConfluenceResult.self, args: args)
    }

    static func confluenceThreshold(imageURL: URL,
                                    pxPerUm: Double,
                                    thresholdMethod: String = "otsu",
                                    fixedThreshold: Double? = nil,
                                    invert: Bool? = nil,
                                    smoothSigmaPx: Double? = nil,
                                    minObjectSizeUm2: Double? = nil) async throws -> ConfluenceResult {
        var args = ["--mode", "confluence", "--pxPerUm", String(pxPerUm),
                    "--image", imageURL.path, "--threshold-method", thresholdMethod]
        if let fixedThreshold { args += ["--fixed-threshold", String(fixedThreshold)] }
        if let invert { args += [invert ? "--invert" : "--no-invert"] }
        if let smoothSigmaPx { args += ["--smooth-sigma-px", String(smoothSigmaPx)] }
        if let minObjectSizeUm2 { args += ["--min-object-size-um2", String(minObjectSizeUm2)] }
        return try await run(ConfluenceResult.self, args: args)
    }

    // MARK: Scratch wound

    static func scratchWoundSingle(imageURL: URL,
                                   pxPerUm: Double,
                                   textureWindowPx: Int? = nil,
                                   minGapSizeUm2: Double? = nil) async throws -> ScratchWoundFrameResult {
        var args = ["--mode", "scratch-wound", "--pxPerUm", String(pxPerUm), "--image", imageURL.path]
        if let textureWindowPx { args += ["--texture-window-px", String(textureWindowPx)] }
        if let minGapSizeUm2 { args += ["--min-gap-size-um2", String(minGapSizeUm2)] }
        return try await run(ScratchWoundFrameResult.self, args: args)
    }

    /// `imageURLs` must be in chronological order — that order becomes the
    /// series' frame index (and pairs positionally with `timepointsHours`).
    static func scratchWoundSeries(imageURLs: [URL],
                                   pxPerUm: Double,
                                   timepointsHours: [Double]? = nil,
                                   textureWindowPx: Int? = nil,
                                   minGapSizeUm2: Double? = nil) async throws -> ScratchWoundSeriesResult {
        guard !imageURLs.isEmpty else { throw AreaAssayRunnerError.noImageSelected }
        var args = ["--mode", "scratch-wound", "--pxPerUm", String(pxPerUm)]
        for url in imageURLs { args += ["--image", url.path] }
        if let timepointsHours {
            args += ["--timepoints-hours", timepointsHours.map { String($0) }.joined(separator: ",")]
        }
        if let textureWindowPx { args += ["--texture-window-px", String(textureWindowPx)] }
        if let minGapSizeUm2 { args += ["--min-gap-size-um2", String(minGapSizeUm2)] }
        return try await run(ScratchWoundSeriesResult.self, args: args)
    }

    // MARK: Spheroid / organoid

    static func spheroid(imageURL: URL,
                         pxPerUm: Double,
                         invert: Bool? = nil,
                         minObjectAreaUm2: Double? = nil,
                         minCircularity: Double? = nil) async throws -> SpheroidResult {
        var args = ["--mode", "spheroid", "--pxPerUm", String(pxPerUm), "--image", imageURL.path]
        if let invert { args += [invert ? "--invert" : "--no-invert"] }
        if let minObjectAreaUm2 { args += ["--min-object-area-um2", String(minObjectAreaUm2)] }
        if let minCircularity { args += ["--min-circularity", String(minCircularity)] }
        return try await run(SpheroidResult.self, args: args)
    }
}
