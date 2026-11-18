import Foundation

// MARK: — Shared sidecar wire types (all four detection families)

/// Output envelope written by every Python detection sidecar.
/// Snake-case keys match the JSON from the Python scripts verbatim.
nonisolated struct SidecarPayload: Decodable, Sendable {
    let width: Int
    let height: Int
    let cells: [SidecarCell]
    /// Per-image stats blob (C2 colony + C3 QC). Optional for backward compat.
    /// Only its numeric values; `runtime` is decoded separately below.
    let image_stats: [String: Double]?
    /// `image_stats.runtime`: what ran (Cellpose sidecars). Nil when absent
    /// or unreadable; a damaged block never fails the payload.
    let runtime: DetectorRuntimeInfo?

    private enum CodingKeys: String, CodingKey { case width, height, cells, image_stats }

    private nonisolated struct StatKey: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        width = try container.decode(Int.self, forKey: .width)
        height = try container.decode(Int.self, forKey: .height)
        cells = try container.decode([SidecarCell].self, forKey: .cells)
        guard container.contains(.image_stats), try !container.decodeNil(forKey: .image_stats) else {
            image_stats = nil
            runtime = nil
            return
        }
        let stats = try container.nestedContainer(keyedBy: StatKey.self, forKey: .image_stats)
        var numbers: [String: Double] = [:]
        var runtime: DetectorRuntimeInfo?
        for key in stats.allKeys {
            if key.stringValue == "runtime" {
                runtime = try? stats.decode(DetectorRuntimeInfo.self, forKey: key)
            } else if let value = try? stats.decode(Double.self, forKey: key) {
                // Non-numeric values are not image statistics; skip them
                // rather than failing the whole result.
                numbers[key.stringValue] = value
            }
        }
        image_stats = numbers
        self.runtime = runtime
    }
}

/// Per-cell JSON produced by every detection script.
nonisolated struct SidecarCell: Decodable, Sendable {
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
    /// Per-channel intensities, emitted by `measure_cells` only when the source
    /// has more than one channel. `ChannelIntensity`'s synthesized coding keys
    /// match these wire names verbatim, so no custom mapping is needed.
    let channel_intensities: [ChannelIntensity]?
}

/// Structured error emitted by a sidecar when a known failure occurs
/// (e.g. model not found, import error). The Swift host checks for this
/// before attempting to decode a full SidecarPayload.
nonisolated struct SidecarError: Decodable, Sendable {
    let error: String
    let hint: String?
}

/// A sidecar's stdout is either a structured error object or a payload. Both
/// shapes are decoded from the SAME parsed JSON tree (one `JSONDecoder` pass):
/// the error shape is tried first because it only reads two top-level keys, and
/// the payload is decoded only when it does not match.
nonisolated enum SidecarOutput: Decodable, Sendable {
    case failure(SidecarError)
    case payload(SidecarPayload)

    init(from decoder: Decoder) throws {
        if let err = try? SidecarError(from: decoder) {
            self = .failure(err)
        } else {
            self = .payload(try SidecarPayload(from: decoder))
        }
    }
}

/// Decoded, mapped detection output. A plain `Sendable` value so the decode can
/// run off the main actor and hand back one result.
nonisolated struct DecodedSidecarResult: Sendable {
    let cells: [DetectedCell]
    let imageWidth: Int
    let imageHeight: Int
    let imageStats: [String: Double]?
    var runtime: DetectorRuntimeInfo? = nil
}

extension SidecarPayload {
    /// Single source of truth for turning a sidecar's stdout into a
    /// `DetectionResult`. Every detection family funnels through this so the
    /// structured-error check, the payload decode, and the per-cell field
    /// mapping (including every `?? …` default) live in exactly one place.
    ///
    /// The parse and mapping run off the main actor (`@concurrent`) and the
    /// stdout is parsed once. Only the final `DetectionResult` wrapper is built
    /// on the caller's actor.
    ///
    /// - Parameters:
    ///   - stdout: the sidecar's raw stdout bytes.
    ///   - exitCode: the sidecar's exit code, used only for the parse-failure
    ///     error message.
    ///   - isolatingJSON: when true (StarDist-style sidecars whose libraries
    ///     print banners to stdout) a failed decode is retried from the first
    ///     `{` offset that yields valid JSON.
    /// - Throws: `DetectionError.sidecarFailed` on a structured `SidecarError`
    ///   payload or an unparseable payload.
    static func decodeResultOffMain(stdout: Data, exitCode: Int32,
                                    isolatingJSON: Bool = false) async throws -> DetectionResult {
        let r = try await decodeOffMain(stdout: stdout, exitCode: exitCode,
                                        isolatingJSON: isolatingJSON)
        return DetectionResult(cells: r.cells,
                               imageWidth: r.imageWidth,
                               imageHeight: r.imageHeight,
                               imageStats: r.imageStats,
                               runtime: r.runtime)
    }

    /// Synchronous variant for callers outside the detection services (runs on
    /// the caller's actor). Prefer `decodeResultOffMain`.
    static func decodeResult(stdout: Data, exitCode: Int32) throws -> DetectionResult {
        let r = try decodeSync(stdout: stdout, exitCode: exitCode)
        return DetectionResult(cells: r.cells,
                               imageWidth: r.imageWidth,
                               imageHeight: r.imageHeight,
                               imageStats: r.imageStats,
                               runtime: r.runtime)
    }

    @concurrent
    static func decodeOffMain(stdout: Data, exitCode: Int32,
                              isolatingJSON: Bool) async throws -> DecodedSidecarResult {
        do {
            return try decodeSync(stdout: stdout, exitCode: exitCode)
        } catch {
            guard isolatingJSON else { throw error }
            // Only an unparseable stdout is retried; a structured sidecar
            // error is final. The retry data is a strict suffix, so equal
            // length means nothing was stripped.
            let isolated = StarDistDetectionService.isolatingJSON(stdout)
            guard isolated.count != stdout.count else { throw error }
            return try decodeSync(stdout: isolated, exitCode: exitCode)
        }
    }

    /// Synchronous decode + mapping. Exposed (internal) so it is testable.
    nonisolated static func decodeSync(stdout: Data, exitCode: Int32) throws -> DecodedSidecarResult {
        let decoded: SidecarPayload
        do {
            switch try JSONDecoder().decode(SidecarOutput.self, from: stdout) {
            case .failure(let errPayload):
                let combined = "\(errPayload.error)\(errPayload.hint.map { ": \($0)" } ?? "")"
                throw DetectionError.sidecarFailed(exitCode: 0, stderr: combined)
            case .payload(let p):
                decoded = p
            }
        } catch let e as DetectionError {
            throw e
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
                contourPx: contour,
                channelIntensities: c.channel_intensities
            )
        }
        return DecodedSidecarResult(cells: cells,
                                    imageWidth: decoded.width,
                                    imageHeight: decoded.height,
                                    imageStats: decoded.image_stats,
                                    runtime: decoded.runtime)
    }
}
