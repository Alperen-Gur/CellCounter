import Foundation

/// `DetectionService` that runs StarDist 2D inference via the shared Python venv
/// and `Resources/python/stardist_detect.py`. Throws `DetectionError` on any failure.
struct StarDistDetectionService: DetectionService {
    /// Which catalog model id this instance handles (e.g. `sd-fluo`).
    let modelId: String

    init(modelId: String) {
        self.modelId = modelId
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

        // The cellpose script and the stardist script live side-by-side in
        // Resources/python/. We reuse the same resolution rule but swap the filename.
        guard let scriptURL = Self.resolveScriptURL() else {
            throw DetectionError.modelNotInstalled(modelId: modelId)
        }

        guard let imageURL = input.imageURL else {
            throw DetectionError.imageDecodeFailed
        }

        // The caller passes the app-level model id; map it to the StarDist name.
        // If the host accidentally hands us a model id we don't know, throw —
        // running with the wrong model produces bogus results.
        let resolved = StarDistDownloader.modelMap[input.modelId]
            ?? StarDistDownloader.modelMap[modelId]
        guard let stardistName = resolved else {
            throw DetectionError.modelNotInstalled(modelId: input.modelId)
        }

        var args = [
            scriptURL.path,
            "--image",   imageURL.path,
            "--model",   stardistName,
            "--pxPerUm", String(input.pxPerUm),
            "--conf",    String(input.confidenceThreshold),
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
        // NOTE: deliberately no `--no-gpu` here.
        //
        // This used to append `--no-gpu` whenever the user turned "Use GPU"
        // off, on the assumption (stated in the comment it replaced) that the
        // stardist sidecar accepted it. It does not: `stardist_detect.py`
        // hand-rolls its own `parse_args()` rather than using
        // `_cellpose_common.build_arg_parser`, and that parser defines no
        // `--no-gpu`. argparse therefore exited with code 2, printed usage to
        // stderr, and wrote nothing to stdout — so EVERY StarDist run with the
        // GPU toggle off failed with an unparseable-stdout error, which is a
        // confusing way to say "unrecognized argument".
        //
        // Verified by running the real sidecar:
        //   stardist_detect.py: error: unrecognized arguments: --no-gpu
        //
        // Dropping the flag makes StarDist work in both toggle positions. The
        // toggle simply has no effect on StarDist yet: TensorFlow picks its own
        // device, and pinning it to CPU needs a flag on the Python side (which
        // this lane doesn't own). Better an honest no-op than a hard failure.

        let outcome: SidecarOutcome
        do {
            outcome = try await SidecarProcessRunner.run(pythonURL: pythonURL, args: args)
        } catch {
            throw DetectionError.sidecarFailed(exitCode: -1, stderr: error.localizedDescription)
        }

        // Non-zero exit → shared mapping: host-termination signal codes become
        // .cancelled (swallowed by callers), everything else .sidecarFailed.
        try outcome.throwIfFailed()

        // Structured error path: the script reported a known failure on stdout.
        // Structured-error check, payload decode, and per-cell mapping are
        // shared across all detection families via SidecarPayload.decodeResult.
        //
        // `isolatingJSON` is a StarDist-only guard — see its doc comment.
        return try SidecarPayload.decodeResult(stdout: Self.isolatingJSON(outcome.stdout),
                                               exitCode: outcome.exitCode)
    }

    /// Strip anything the stardist library printed to stdout ahead of our JSON.
    ///
    /// Every sidecar keeps stdout clean for the payload and logs to stderr —
    /// but stardist itself doesn't play along. Verified against the real
    /// library (0.9.2), stdout on a normal run begins:
    ///
    ///     Found model '2D_versatile_fluo' for 'StarDist2D'.
    ///     Loading network weights from 'weights_best.h5'.
    ///     {"width": 300, …}
    ///
    /// and on a first run it also carries the weights-download progress bar.
    /// `JSONDecoder` sees a leading `F` and fails, so EVERY StarDist detection
    /// died with "Unparseable stdout" no matter how well the run went.
    ///
    /// The proper fix is for the sidecar to silence the library (that file is
    /// owned by another lane), so this is the host-side safety net: try the
    /// bytes as-is first, and only if that fails re-try from each `{` in turn.
    /// The first offset that decodes is the payload. Confined to StarDist
    /// rather than pushed into the shared `SidecarPayload.decodeResult`, so no
    /// other detector's strictness is relaxed.
    static func isolatingJSON(_ stdout: Data) -> Data {
        // Fast path: already clean (and the only path once the sidecar is fixed).
        if (try? JSONSerialization.jsonObject(with: stdout)) != nil { return stdout }

        let open = UInt8(ascii: "{")
        var index = stdout.startIndex
        while let next = stdout[index...].firstIndex(of: open) {
            let candidate = stdout[next...]
            if (try? JSONSerialization.jsonObject(with: candidate)) != nil {
                return Data(candidate)
            }
            index = stdout.index(after: next)
            if index >= stdout.endIndex { break }
        }
        // Nothing decodable — hand back the original so the error message the
        // caller builds still shows what the sidecar actually printed.
        return stdout
    }

    // MARK: — Script resolution

    /// Resolve `stardist_detect.py` from the bundle (prod) or the dev repo (DEBUG).
    private static func resolveScriptURL() -> URL? {
        if let staged = PythonRuntime.stagedScriptURL(named: "stardist_detect.py") {
            return staged
        }
        return PythonRuntime.bundledPythonURL(named: "stardist_detect.py")
    }

}
