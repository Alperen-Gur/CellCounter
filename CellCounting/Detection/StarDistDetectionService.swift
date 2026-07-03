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
        if !input.useGPU {
            // Honour the user's "Use GPU" preference. The stardist sidecar
            // accepts `--no-gpu` to pin TensorFlow to CPU.
            args += ["--no-gpu"]
        }

        let outcome: SidecarOutcome
        do {
            outcome = try await SidecarProcessRunner.run(pythonURL: pythonURL, args: args)
        } catch {
            throw DetectionError.sidecarFailed(exitCode: -1, stderr: error.localizedDescription)
        }

        if outcome.exitCode != 0 {
            let stderrText = String(data: outcome.stderr, encoding: .utf8) ?? ""
            throw DetectionError.sidecarFailed(exitCode: outcome.exitCode, stderr: stderrText)
        }

        // Structured error path: the script reported a known failure on stdout.
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

    // MARK: — Script resolution

    /// Resolve `stardist_detect.py` from the bundle (prod) or the dev repo (DEBUG).
    private static func resolveScriptURL() -> URL? {
        if let staged = PythonRuntime.stagedScriptURL(named: "stardist_detect.py") {
            return staged
        }
        return PythonRuntime.bundledPythonURL(named: "stardist_detect.py")
    }

}
