import Foundation
import CoreGraphics

/// GeoJSON (RFC 7946) exporter — the QuPath / Python-Shapely / GIS-tooling
/// half of CellCounter's export story, alongside the ImageJ RoiSet.zip
/// exporter (`ExportService.writeImageJROIsCore`, `python/_export_imagej_roi.py`).
/// Deliberately mirrors that exporter's conventions where they line up:
///   - same "contour when present, else a shape derived from cx/cy/diameter"
///     fallback (there: an OVAL ROI; here: an N-gon approximating a circle),
///   - same "filter to confidence >= cutoff" semantics as the CSV/PNG/ROI
///     writers (Pass-15's "exports must match what's on screen" rule),
///   - same live re-binning via `BinMath.bins(from:)` that the per-cell and
///     per-image summary CSVs use, instead of trusting a possibly-stale/empty
///     stored `sizeClass` string.
///
/// COORDINATE SYSTEM (read this before piping the output anywhere): every
/// coordinate this file emits is in SOURCE-IMAGE PIXEL SPACE — origin at the
/// image's top-left corner, x increasing right, y increasing DOWN. This is
/// NOT a geographic coordinate system and no CRS transform is applied or
/// implied. QuPath's own shape exports use the identical convention ("origin
/// (0, 0) as the top left corner of the full-resolution image" — QuPath
/// docs, "Exporting annotations"), and Shapely/GeoPandas are equally happy
/// treating these as plain Cartesian coordinates — just don't feed this file
/// into a tool that assumes WGS84 lon/lat. The `coordinate_space` /
/// `note` keys on the FeatureCollection's `properties` restate this inside
/// the file itself.
enum GeoJSONExporter {

    // MARK: — Errors

    enum GeoJSONError: LocalizedError {
        case noCells
        case encodeFailed
        case writeFailed(Error)

        var errorDescription: String? {
            switch self {
            case .noCells: return "There are no detected cells to export."
            case .encodeFailed: return "Couldn't encode the GeoJSON file."
            case .writeFailed(let e): return "Couldn't write the GeoJSON file: \(e.localizedDescription)"
            }
        }
    }

    /// Which object type this feature's geometry came from — carried in
    /// `properties.contour_source` so a fallback circle can never be mistaken
    /// for a measured boundary. Honesty requirement from the brief: "note
    /// this in the properties so it's honest."
    enum ContourSource: String, Sendable {
        case measured
        case approximatedCircle = "approximated_circle"
    }

    /// Vertex count for the fallback circle approximation. High enough to
    /// look and measure like a circle (area/perimeter within ~0.1% of the
    /// true circle) without bloating the file for detections that are
    /// mostly real contours anyway.
    private static let fallbackCircleVertexCount = 32

    // MARK: — Public entry points

    /// Builds the full `FeatureCollection` as a JSON-serializable object
    /// (`[String: Any]` tree of String/NSNumber/Bool/Array/Dictionary leaves
    /// — the natural shape for `JSONSerialization`, and far simpler than
    /// hand-rolling `Encodable` for GeoJSON's deliberately loose,
    /// heterogeneous `properties` bags). `cells` is filtered to
    /// `confidence >= confidence` internally, matching every other exporter.
    nonisolated static func featureCollection(cells rawCells: [DetectedCell],
                                              imageFileName: String,
                                              imageWidthPx: Int,
                                              imageHeightPx: Int,
                                              thresholds: [Double],
                                              pxPerUm: Double,
                                              confidence: Double = 0.0,
                                              modelId: String) -> [String: Any] {
        let bins = BinMath.bins(from: thresholds)
        let cells = rawCells.filter { $0.confidence >= confidence }

        let features: [[String: Any]] = cells.map { cell in
            feature(for: cell, bins: bins, thresholds: thresholds, pxPerUm: pxPerUm)
        }

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]

        // Foreign member on the FeatureCollection (RFC 7946 §6.1 explicitly
        // permits members beyond "type"/"features" — the same allowance
        // GDAL/ESRI GeoJSON writers rely on for a top-level "crs"). Mirrors
        // the `# confidence=…; bins=…; model=…; pxPerUm=…` config-header
        // convention already used at the top of every CSV export
        // (`ExportService.configHeaderComment`), just as a real JSON object
        // instead of a comment string.
        let collectionProperties: [String: Any] = [
            "generator": "CellCounter \(Self.appVersion) (\(Self.appBuild))",
            "coordinate_space": "image_pixels_top_left_origin_y_down",
            "note": "Coordinates are in SOURCE IMAGE PIXEL SPACE (origin top-left, x right, y down) — not geographic. No CRS transform is defined; import directly into QuPath / Shapely / GeoPandas without reprojecting.",
            "image_filename": imageFileName,
            "image_width_px": imageWidthPx,
            "image_height_px": imageHeightPx,
            "px_per_um": pxPerUm,
            "model_id": modelId,
            "confidence_threshold": confidence,
            "thresholds_um": thresholds,
            "exported_at": iso.string(from: Date()),
            "n_features": features.count,
        ]

        return [
            "type": "FeatureCollection",
            "properties": collectionProperties,
            "features": features,
        ]
    }

    /// Encodes + writes the FeatureCollection for `cells` to `url`. Throws
    /// `.noCells` when the confidence-filtered set is empty rather than
    /// writing a technically-valid-but-useless empty FeatureCollection —
    /// mirrors `ExportService.writeImageJROIsCore`'s identical refusal ("There
    /// are no detected cells to export").
    ///
    /// `nonisolated` / plain-value parameters only, so callers can run this
    /// off the main actor inside `Task.detached` exactly like
    /// `ExportService.writeCSVCore` / `writeImageJROIsCore` — see
    /// `Views/Results/GeoJSONExportPanel.swift` for that call site.
    nonisolated static func write(cells: [DetectedCell],
                                  imageFileName: String,
                                  imageWidthPx: Int,
                                  imageHeightPx: Int,
                                  thresholds: [Double],
                                  pxPerUm: Double,
                                  confidence: Double = 0.0,
                                  modelId: String,
                                  to url: URL) throws {
        let visible = cells.filter { $0.confidence >= confidence }
        guard !visible.isEmpty else { throw GeoJSONError.noCells }

        let obj = featureCollection(cells: cells,
                                    imageFileName: imageFileName,
                                    imageWidthPx: imageWidthPx,
                                    imageHeightPx: imageHeightPx,
                                    thresholds: thresholds,
                                    pxPerUm: pxPerUm,
                                    confidence: confidence,
                                    modelId: modelId)
        guard JSONSerialization.isValidJSONObject(obj) else { throw GeoJSONError.encodeFailed }
        let data: Data
        do {
            data = try JSONSerialization.data(withJSONObject: obj,
                                              options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        } catch {
            throw GeoJSONError.encodeFailed
        }
        do {
            try data.write(to: url, options: [.atomic])
        } catch {
            throw GeoJSONError.writeFailed(error)
        }
    }

    // MARK: — Per-cell feature

    /// One GeoJSON `Feature` per cell: a `Polygon` geometry (single exterior
    /// ring — cells have no holes) plus a `properties` bag carrying both
    /// snake_case measurement fields (matching the per-cell CSV's column
    /// names 1:1, so cross-referencing the two exports is trivial) and
    /// QuPath's own recognized keys (`objectType`, `classification`,
    /// `isLocked`, `measurements`) so a straight drag-and-drop import into
    /// QuPath comes in already classified/colored by size bin.
    private static func feature(for cell: DetectedCell,
                                bins: [SizeBin],
                                thresholds: [Double],
                                pxPerUm: Double) -> [String: Any] {
        let (rawRing, source) = polygonRing(for: cell)
        let closedRing = closeRing(rawRing)
        let orientedRing = ensureCounterClockwise(closedRing)
        let coordinates: [[[Double]]] = [orientedRing.map { [Double($0.x), Double($0.y)] }]

        let idx = BinMath.binIndex(for: cell.diameter, thresholds: thresholds)
        let safeIdx = max(0, min(idx, bins.count - 1))
        let binLabel = bins.isEmpty ? "all" : bins[safeIdx].label

        let areaPx2 = polygonArea(orientedRing)
        let areaUm2: Double? = {
            if let stored = cell.areaMicrons2 { return stored }
            guard pxPerUm > 0 else { return nil }
            return areaPx2 / (pxPerUm * pxPerUm)
        }()

        // QuPath-native measurement list (properties.measurements) — shows up
        // directly in QuPath's per-object measurement table/plots on import.
        var measurements: [[String: Any]] = [
            ["name": "Diameter (\u{b5}m)", "value": cell.diameter],
            ["name": "Diameter (px)", "value": cell.diameterPx],
            ["name": "Confidence", "value": cell.confidence],
            ["name": "Area (px^2)", "value": areaPx2],
        ]
        if let v = areaUm2 { measurements.append(["name": "Area (\u{b5}m^2)", "value": v]) }
        if let v = cell.perimeterMicrons { measurements.append(["name": "Perimeter (\u{b5}m)", "value": v]) }
        if let v = cell.circularity { measurements.append(["name": "Circularity", "value": v]) }
        if let v = cell.solidity { measurements.append(["name": "Solidity", "value": v]) }
        if let v = cell.aspectRatio { measurements.append(["name": "Aspect ratio", "value": v]) }
        if let v = cell.eccentricity { measurements.append(["name": "Eccentricity", "value": v]) }
        if let v = cell.meanIntensity { measurements.append(["name": "Mean intensity", "value": v]) }
        if let v = cell.integratedDensity { measurements.append(["name": "Integrated density", "value": v]) }

        // Flat snake_case properties — mirrors ExportService.writeCSVCore's
        // header 1:1 (id, cx_px, cy_px, diameter_um, diameter_px, bin_label,
        // confidence, area_um2, perimeter_um, circularity, eccentricity,
        // mean_intensity, integrated_density, centroid_um_x/y, aspect_ratio,
        // solidity, size_class, edge_touching, likely_clump, likely_debris,
        // is_manual) so a user cross-referencing the CSV and this GeoJSON of
        // the same detection sees matching column/property names.
        var properties: [String: Any] = [
            "id": cell.id.uuidString,
            "objectType": "detection",
            "classification": ["name": binLabel],
            "isLocked": false,
            "measurements": measurements,

            "cx_px": cell.cx,
            "cy_px": cell.cy,
            "diameter_um": cell.diameter,
            "diameter_px": cell.diameterPx,
            "area_px2": areaPx2,
            "confidence": cell.confidence,
            "bin_label": binLabel,
            "size_class": cell.sizeClass,
            "edge_touching": cell.edgeTouching,
            "likely_clump": cell.likelyClump,
            "likely_debris": cell.likelyDebris,
            "is_manual": cell.isManual,
            "contour_source": source.rawValue,
        ]
        if let v = areaUm2 { properties["area_um2"] = v }
        if let v = cell.perimeterMicrons { properties["perimeter_um"] = v }
        if let v = cell.circularity { properties["circularity"] = v }
        if let v = cell.eccentricity { properties["eccentricity"] = v }
        if let v = cell.meanIntensity { properties["mean_intensity"] = v }
        if let v = cell.integratedDensity { properties["integrated_density"] = v }
        if let v = cell.centroidUmX { properties["centroid_um_x"] = v }
        if let v = cell.centroidUmY { properties["centroid_um_y"] = v }
        if let v = cell.aspectRatio { properties["aspect_ratio"] = v }
        if let v = cell.solidity { properties["solidity"] = v }

        return [
            "type": "Feature",
            "id": cell.id.uuidString,
            "geometry": [
                "type": "Polygon",
                "coordinates": coordinates,
            ],
            "properties": properties,
        ]
    }

    // MARK: — Contour source

    /// Real contour when present (>= 3 points, matching the same floor the
    /// ImageJ exporter's polygon path uses); otherwise a circle sampled at
    /// `fallbackCircleVertexCount` points from centroid + diameter — the
    /// same fallback shape ImageJ export uses (an OVAL ROI), so the two
    /// exports agree on which cells are "measured" vs "approximated." Note
    /// this DOESN'T clamp points into `[0, width) x [0, height)` the way
    /// `_export_imagej_roi.py` does for ImageJ's stricter ROI format —
    /// GeoJSON/Shapely/QuPath all handle geometry that extends slightly past
    /// the image edge without complaint, and clamping would flatten a real
    /// detected boundary at the border, which is less honest than leaving it
    /// as measured.
    private static func polygonRing(for cell: DetectedCell) -> (points: [CGPoint], source: ContourSource) {
        if let contour = cell.contourPx, contour.count >= 3 {
            return (contour, .measured)
        }
        let r = max(0.5, cell.diameterPx / 2)
        var pts: [CGPoint] = []
        pts.reserveCapacity(fallbackCircleVertexCount)
        for i in 0..<fallbackCircleVertexCount {
            let theta = 2 * Double.pi * Double(i) / Double(fallbackCircleVertexCount)
            pts.append(CGPoint(x: cell.cx + r * cos(theta), y: cell.cy + r * sin(theta)))
        }
        return (pts, .approximatedCircle)
    }

    // MARK: — RFC 7946 ring hygiene

    /// Closes a ring by repeating the first point as the last, per RFC 7946
    /// §3.1.6: "the first and last positions are equivalent, and they MUST
    /// contain identical values." No-ops if already closed.
    private static func closeRing(_ points: [CGPoint]) -> [CGPoint] {
        guard let first = points.first else { return points }
        if let last = points.last, last.x == first.x, last.y == first.y {
            return points
        }
        return points + [first]
    }

    /// RFC 7946 §3.1.6: "...the exterior ring... MUST follow the right-hand
    /// rule... counterclockwise." That rule is a statement about the sign of
    /// the shoelace formula applied to the raw (x, y) numbers — GeoJSON has
    /// no notion of "image space," so this reverses point order whenever the
    /// signed area is negative, full stop. In on-screen terms (our y axis
    /// points DOWN, unlike the rule's implicit y-up assumption) that means a
    /// spec-compliant ring will visually look clockwise here — that's
    /// expected, not a bug, and is exactly what the RFC's own text asks for
    /// when applied literally to pixel coordinates.
    private static func ensureCounterClockwise(_ ring: [CGPoint]) -> [CGPoint] {
        guard signedArea(ring) < 0 else { return ring }
        return ring.reversed()
    }

    /// Shoelace formula. Safe on an open or closed ring — the repeated
    /// closing vertex contributes exactly 0 to the sum.
    private static func signedArea(_ ring: [CGPoint]) -> Double {
        guard ring.count >= 3 else { return 0 }
        var sum = 0.0
        for i in 0..<ring.count {
            let p0 = ring[i]
            let p1 = ring[(i + 1) % ring.count]
            sum += Double(p0.x) * Double(p1.y) - Double(p1.x) * Double(p0.y)
        }
        return sum / 2
    }

    private static func polygonArea(_ ring: [CGPoint]) -> Double {
        abs(signedArea(ring))
    }

    // MARK: — App identity (small, intentionally-duplicated bundle readers —
    // mirrors the same two-liner already independently duplicated by
    // `ProvenanceMetadata` and `SettingsView.AboutSection`, rather than
    // reaching into either of those files, which this agent doesn't own.)

    private static var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }
    private static var appBuild: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
    }
}
