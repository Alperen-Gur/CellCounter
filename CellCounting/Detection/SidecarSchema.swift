import Foundation

// MARK: — Shared sidecar wire types (all four detection families)

/// Output envelope written by every Python detection sidecar.
/// Snake-case keys match the JSON from the Python scripts verbatim.
struct SidecarPayload: Decodable {
    let width: Int
    let height: Int
    let cells: [SidecarCell]
    /// Per-image stats blob (C2 colony + C3 QC). Optional for backward compat.
    let image_stats: [String: Double]?
}

/// Per-cell JSON produced by every detection script.
struct SidecarCell: Decodable {
    let id: String
    let cx: Double
    let cy: Double
    let diameter_um: Double
    let diameter_px: Double
    let confidence: Double
    // Per-cell measurements (optional; absent from legacy sidecars).
    let area_um2: Double?
    let perimeter_um: Double?
    let circularity: Double?
    let eccentricity: Double?
    let mean_intensity: Double?
    let integrated_density: Double?
    // Quality flags (optional; absent from older sidecars → defaults applied at decode).
    let centroid_um_x: Double?
    let centroid_um_y: Double?
    let aspect_ratio: Double?
    let solidity: Double?
    let edge_touching: Bool?
    let likely_clump: Bool?
    let likely_debris: Bool?
    let size_class: String?
    let is_manual: Bool?
    /// Pass-14: per-cell polygon contour in image-pixel coords, as [[x, y], …].
    /// Optional — legacy sidecars and non-cellpose detectors don't emit it.
    let contour_px: [[Double]]?
}

/// Structured error emitted by a sidecar when a known failure occurs
/// (e.g. model not found, import error). The Swift host checks for this
/// before attempting to decode a full SidecarPayload.
struct SidecarError: Decodable {
    let error: String
    let hint: String?
}

extension SidecarPayload {
    /// Single source of truth for turning a sidecar's stdout into a
    /// `DetectionResult`. Every detection family (Cellpose, CellposeSAM, SAM,
    /// StarDist) funnels through this so the structured-error check, the
    /// payload decode, and the per-cell field mapping (including every `?? …`
    /// default) live in exactly one place and can't drift between detectors.
    ///
    /// - Parameters:
    ///   - stdout: the sidecar's raw stdout bytes.
    ///   - exitCode: the sidecar's exit code, used only for the parse-failure
    ///     error message.
    /// - Throws: `DetectionError.sidecarFailed` on a structured `SidecarError`
    ///   payload or an unparseable payload.
    static func decodeResult(stdout: Data, exitCode: Int32) throws -> DetectionResult {
        if let errPayload = try? JSONDecoder().decode(SidecarError.self, from: stdout) {
            let combined = "\(errPayload.error)\(errPayload.hint.map { ": \($0)" } ?? "")"
            throw DetectionError.sidecarFailed(exitCode: 0, stderr: combined)
        }

        let decoded: SidecarPayload
        do {
            decoded = try JSONDecoder().decode(SidecarPayload.self, from: stdout)
        } catch {
            let stdoutText = String(data: stdout, encoding: .utf8) ?? ""
            throw DetectionError.sidecarFailed(exitCode: exitCode,
                                               stderr: "Unparseable stdout: \(stdoutText.prefix(400))")
        }

        let cells = decoded.cells.map { c -> DetectedCell in
            let id = UUID(uuidString: c.id) ?? UUID()
            // Lift contour pairs into a CGPoint array (skip malformed pairs).
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
