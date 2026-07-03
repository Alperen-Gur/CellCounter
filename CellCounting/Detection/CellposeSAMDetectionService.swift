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

}
