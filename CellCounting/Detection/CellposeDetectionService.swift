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
            // Stream stderr lines into a `ccDetectionStage` notification so the
            // UI shows what cellpose is doing (loading model, computing flows,
            // running dynamics, …) instead of sitting at 0% for 60–90s.
            outcome = try await SidecarProcessRunner.run(pythonURL: pythonURL, args: args) { line in
                NotificationCenter.default.post(
                    name: .ccDetectionStage,
                    object: nil,
                    userInfo: ["line": line])
            }
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

}
