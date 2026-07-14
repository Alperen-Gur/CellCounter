import Foundation
import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

enum ExportError: LocalizedError {
    case missingImageBitmap
    case encodeFailed
    case writeFailed(Error)
    case pythonUnavailable
    case roiExportFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingImageBitmap: return "Couldn't open the source image for export."
        case .encodeFailed: return "Couldn't encode the export file."
        case .writeFailed(let e): return "Couldn't write the export file: \(e.localizedDescription)"
        case .pythonUnavailable:
            return "Python venv is not installed. Install Cellpose first to enable ROI export."
        case .roiExportFailed(let msg):
            return "ImageJ ROI export failed: \(msg)"
        }
    }
}

enum ExportService {

    // MARK: — One-click sample folder (Pass-17)

    /// Result of a `writeSampleFolder` call. The folder URL is always returned
    /// even when some writers failed — half a folder is more useful than none,
    /// per the Pass-17 brief. `errors` lists per-file failures so the UI can
    /// surface them.
    struct SampleFolderResult {
        let folder: URL
        let written: [String]                   // filenames actually emitted
        let errors: [(filename: String, error: Error)]
    }

    /// Sanitize a filename component so it survives `cmd-O` / Finder display.
    /// Strips characters that don't round-trip on macOS / Linux / Windows.
    static func sanitizeFilename(_ name: String) -> String {
        let bad = CharacterSet(charactersIn: "/\\:*?\"<>|\u{0}\n\r\t")
        let parts = name.components(separatedBy: bad)
        var cleaned = parts.joined(separator: "_")
        while cleaned.contains("__") {
            cleaned = cleaned.replacingOccurrences(of: "__", with: "_")
        }
        cleaned = cleaned.trimmingCharacters(in: CharacterSet(charactersIn: " ._"))
        return cleaned.isEmpty ? "sample" : cleaned
    }

    /// Folder timestamp suffix: `YYYY-MM-DD_HH-MM-SS` (filesystem-safe).
    private static func folderTimestamp(_ date: Date = Date()) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        f.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return f.string(from: date)
    }

    /// Write the full sample bundle:
    ///   <image_basename>_<YYYY-MM-DD_HH-MM-SS>/
    ///     original.<ext>   (symlink when possible; copy otherwise)
    ///     annotated.png
    ///     cells.csv
    ///     summary.csv
    ///     imagej_rois.zip
    ///     annotations.json + annotations.csv  (only when Lane B writers ship)
    ///     report.md
    ///     report.pdf
    ///
    /// Per-writer errors are collected, not rethrown — a missing venv (no ROI
    /// export) doesn't lose the CSV/PNG/PDF. The outer `throws` only fires
    /// when the destination folder itself can't be created (i.e. no useful
    /// work is possible).
    @discardableResult
    @MainActor
    static func writeSampleFolder(image: ImageRecord,
                                  state: AppState,
                                  overlayMode: OverlayMode,
                                  parentDir: URL) async throws -> SampleFolderResult {
        let baseName = sanitizeFilename((image.fileName as NSString).deletingPathExtension)
        let folderName = "\(baseName)_\(folderTimestamp())"
        let folder = parentDir.appendingPathComponent(folderName, isDirectory: true)

        do {
            try FileManager.default.createDirectory(at: folder,
                                                    withIntermediateDirectories: true)
        } catch {
            throw ExportError.writeFailed(error)
        }

        var written: [String] = []
        var errors: [(String, Error)] = []

        let conf = state.effectiveConfidence(for: image)
        // Global cutoff (not the exported image's override) — the per-image
        // summary writer resolves each row's own override against this fallback.
        let globalConf = state.confidence
        let modelId = state.currentBatch?.modelId ?? state.activeModelId
        let pxPerUm = state.pxPerUm
        let thresholds = state.thresholds
        // Pass-18 (Lane R): capture provenance once and thread it through every
        // writer below. `ProvenanceMetadata.capture` is MainActor-bound (reads
        // AppState + BatchRecord), which is fine here — `writeSampleFolder`
        // already reads state directly on the MainActor.
        let provenance = ProvenanceMetadata.capture(for: image, state: state)

        // 1) original.<ext>
        let srcURL = image.storedURL
        let srcExt: String = {
            let raw = (image.fileName as NSString).pathExtension
            return raw.isEmpty ? "tif" : raw.lowercased()
        }()
        let originalDest = folder.appendingPathComponent("original.\(srcExt)")
        do {
            try copyOrSymlink(from: srcURL, to: originalDest)
            written.append(originalDest.lastPathComponent)
        } catch {
            errors.append((originalDest.lastPathComponent, error))
        }

        // Snapshot the SwiftData-backed values ONCE on the main actor so the
        // heavy PNG compositing + CSV building + ROI subprocess below can run
        // off the MainActor (via Task.detached) without touching the model
        // graph. This keeps the whole window responsive during a sample export.
        let srcImageURL = image.storedURL
        let imageFileName = image.fileName
        let imageWidthPx = image.widthPx
        let imageHeightPx = image.heightPx
        let detectionCells: [DetectedCell]? = image.detection?.cells

        // 2) annotated.png — only with a detection. Composited off-main.
        if let cells = detectionCells {
            let pngURL = folder.appendingPathComponent("annotated.png")
            do {
                try await Task.detached {
                    try compositeAnnotatedPNG(imageURL: srcImageURL,
                                              cells: cells,
                                              thresholds: thresholds,
                                              pxPerUm: pxPerUm,
                                              overlayMode: overlayMode,
                                              confidence: conf,
                                              provenance: provenance,
                                              to: pngURL)
                }.value
                written.append(pngURL.lastPathComponent)
            } catch {
                errors.append((pngURL.lastPathComponent, error))
            }
        }

        // 3) cells.csv — built + written off-main.
        if let cells = detectionCells {
            let csvURL = folder.appendingPathComponent("cells.csv")
            do {
                try await Task.detached {
                    try writeCSVCore(cells: cells,
                                     imageFileName: imageFileName,
                                     thresholds: thresholds,
                                     pxPerUm: pxPerUm,
                                     confidence: conf,
                                     modelId: modelId,
                                     separator: ",",
                                     provenance: provenance,
                                     to: csvURL)
                }.value
                written.append(csvURL.lastPathComponent)
            } catch {
                errors.append((csvURL.lastPathComponent, error))
            }
        }

        // 4) summary.csv — per-image rollup for the parent batch.
        if let batch = image.batch ?? state.currentBatch {
            let summaryURL = folder.appendingPathComponent("summary.csv")
            do {
                try writePerImageSummaryCSV(batch: batch,
                                            thresholds: thresholds,
                                            pxPerUm: pxPerUm,
                                            confidence: globalConf,
                                            separator: ",",
                                            provenance: provenance,
                                            to: summaryURL)
                written.append(summaryURL.lastPathComponent)
            } catch {
                errors.append((summaryURL.lastPathComponent, error))
            }
        }

        // 5) imagej_rois.zip — best-effort; skipped if the Python venv is
        // missing or there are no cells to export. The blocking Python
        // subprocess wait runs off-main.
        if let cells = detectionCells, !cells.isEmpty {
            let roiURL = folder.appendingPathComponent("imagej_rois.zip")
            do {
                try await Task.detached {
                    try writeImageJROIsCore(cells: cells,
                                            imageWidthPx: imageWidthPx,
                                            imageHeightPx: imageHeightPx,
                                            imageFileName: imageFileName,
                                            thresholds: thresholds,
                                            pxPerUm: pxPerUm,
                                            confidence: conf,
                                            modelId: modelId,
                                            to: roiURL)
                }.value
                written.append(roiURL.lastPathComponent)
            } catch {
                errors.append((roiURL.lastPathComponent, error))
            }
        }

        // 6) annotations.json / annotations.csv — Lane B (Pass-17). Only
        // emitted when the user actually placed ground-truth marks on this
        // image. Best-effort, same as the other writers: failure here doesn't
        // block the rest of the bundle.
        let annsForImage = state.repos.annotations(for: image.id)
        if !annsForImage.isEmpty {
            let jsonURL = folder.appendingPathComponent("annotations.json")
            do {
                try writeAnnotationsJSON(image: image,
                                         annotations: annsForImage,
                                         pxPerUm: pxPerUm,
                                         provenance: provenance,
                                         to: jsonURL)
                written.append(jsonURL.lastPathComponent)
            } catch {
                errors.append((jsonURL.lastPathComponent, error))
            }
            let csvURL = folder.appendingPathComponent("annotations.csv")
            do {
                try writeAnnotationsCSV(image: image,
                                        annotations: annsForImage,
                                        pxPerUm: pxPerUm,
                                        provenance: provenance,
                                        to: csvURL)
                written.append(csvURL.lastPathComponent)
            } catch {
                errors.append((csvURL.lastPathComponent, error))
            }
        }

        // 6b) provenance.json — Pass-18 (Lane R). Always written alongside the
        // bundle so a collaborator has a single self-describing file even if
        // they don't open the per-file CSV headers. Best-effort, like all other
        // writers — a failure here doesn't block the report.
        let provURL = folder.appendingPathComponent("provenance.json")
        do {
            try provenance.asJSON.write(to: provURL, options: [.atomic])
            written.append(provURL.lastPathComponent)
        } catch {
            errors.append((provURL.lastPathComponent, error))
        }

        // 7) report.md
        let mdURL = folder.appendingPathComponent("report.md")
        do {
            try writeReportMarkdown(image: image, state: state, to: mdURL)
            written.append(mdURL.lastPathComponent)
        } catch {
            errors.append((mdURL.lastPathComponent, error))
        }

        // 8) report.pdf — capture the inputs on the MainActor (cheap), then run
        // the heavy render (full-res decode + composite + draw) off it via
        // Task.detached so the one-click sample export doesn't freeze the UI on
        // its single heaviest step. PDFReportGenerator is pure CoreGraphics now,
        // so it's safe to render off the main actor.
        let pdfURL = folder.appendingPathComponent("report.pdf")
        let pdfInputs = PDFReportGenerator.makeInputs(image: image, state: state)
        do {
            try await Task.detached {
                try PDFReportGenerator.writeReport(inputs: pdfInputs, to: pdfURL)
            }.value
            written.append(pdfURL.lastPathComponent)
        } catch {
            errors.append((pdfURL.lastPathComponent, error))
        }

        return SampleFolderResult(folder: folder, written: written, errors: errors)
    }

    /// Best-effort: try symlink first (cheap; resolves to the original), fall
    /// back to a copy if symlinks aren't supported on the destination volume.
    /// Removes any existing destination first.
    private static func copyOrSymlink(from src: URL, to dst: URL) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: dst.path) {
            try fm.removeItem(at: dst)
        }
        do {
            try fm.createSymbolicLink(at: dst, withDestinationURL: src)
            return
        } catch {
            // fall through to copy
        }
        try fm.copyItem(at: src, to: dst)
    }

    /// Write the human-readable report stub. Mirrors the per-image rollup
    /// shown in the PDF so grep across a folder of samples is useful.
    static func writeReportMarkdown(image: ImageRecord,
                                    state: AppState,
                                    to url: URL) throws {
        let snapshot = ReportSnapshot.make(image: image, state: state)

        func fmt(_ v: Double?, decimals: Int = 1) -> String {
            guard let v else { return "—" }
            return String(format: "%.\(decimals)f", v)
        }
        let binsList = snapshot.thresholds.map(\.trimmedString).joined(separator: ", ")

        let coloniesLine: String = {
            if let n = snapshot.nColonies, let pct = snapshot.confluencyPct {
                return "\(n) colonies (\(String(format: "%.1f", pct))% confluency)"
            }
            return "—"
        }()

        let iqr: String
        if let lo = snapshot.iqrLow, let hi = snapshot.iqrHigh {
            iqr = "\(String(format: "%.1f", lo))–\(String(format: "%.1f", hi)) µm"
        } else {
            iqr = "—"
        }

        let f1Line = snapshot.f1.map { String(format: "%.3f", $0) } ?? "no annotations"

        let md = """
        # CellCounter analysis — \(snapshot.fileName)
        - Date: \(snapshot.dateISO)
        - Model: \(snapshot.modelName)
        - pxPerUm: \(String(format: "%.4g", snapshot.pxPerUm))
        - Confidence threshold: \(String(format: "%.2f", snapshot.confidence))
        - Bin thresholds: [\(binsList)]
        - Cells detected: \(snapshot.nCells)
        - Median diameter: \(fmt(snapshot.medianDiameter)) µm
        - Mean diameter: \(fmt(snapshot.meanDiameter)) µm
        - IQR: \(iqr)
        - Colonies: \(coloniesLine)
        - Focus score: \(fmt(snapshot.focusScore, decimals: 3))
        - Illumination residual: \(fmt(snapshot.illuminationResidual, decimals: 3))
        - F1 vs ground truth: \(f1Line)

        See report.pdf for full layout including image and histogram.

        \(ProvenanceMetadata.capture(for: image, state: state).asMarkdown)
        """
        guard let data = md.data(using: .utf8) else { throw ExportError.encodeFailed }
        do {
            try data.write(to: url, options: [.atomic])
        } catch {
            throw ExportError.writeFailed(error)
        }
    }

    // MARK: — CSV

    static func writeCSV(detection: DetectionRecord,
                         image: ImageRecord,
                         thresholds: [Double],
                         pxPerUm: Double,
                         confidence: Double? = nil,
                         modelId: String? = nil,
                         separator: String = ",",
                         provenance: ProvenanceMetadata? = nil,
                         to url: URL) throws {
        // Snapshot the SwiftData-backed values on the caller's actor, then hand
        // off to the `nonisolated` core so the row-building + write can run off
        // the MainActor when called from a `Task.detached`.
        try writeCSVCore(cells: detection.cells,
                         imageFileName: image.fileName,
                         thresholds: thresholds,
                         pxPerUm: pxPerUm,
                         confidence: confidence,
                         modelId: modelId ?? detection.detectorId,
                         separator: separator,
                         provenance: provenance,
                         to: url)
    }

    /// Off-main-safe CSV writer: builds every row + writes the file from Sendable
    /// value types only (no SwiftData `@Model` access).
    nonisolated static func writeCSVCore(cells: [DetectedCell],
                                         imageFileName: String,
                                         thresholds: [Double],
                                         pxPerUm: Double,
                                         confidence: Double? = nil,
                                         modelId: String,
                                         separator: String = ",",
                                         provenance: ProvenanceMetadata? = nil,
                                         to url: URL) throws {
        let bins = BinMath.bins(from: thresholds)
        let header = ["id", "cx_px", "cy_px", "diameter_um", "diameter_px", "bin_label", "confidence",
                      "area_um2", "perimeter_um", "circularity", "eccentricity",
                      "mean_intensity", "integrated_density",
                      // pass-6 quality flags (appended at the end)
                      "image_filename", "centroid_um_x", "centroid_um_y", "aspect_ratio",
                      "solidity", "size_class", "edge_touching", "likely_clump", "likely_debris", "is_manual"]
        var lines: [String] = []
        // Pass-18 (Lane R): prepend the full provenance block when supplied, so
        // a collaborator can reproduce the analysis from the CSV alone. Pass-15's
        // single-line config header follows underneath for backwards
        // compatibility with existing parsers that scan only the first comment.
        if let provenance {
            // asCSVHeader already terminates with \n; drop it so the join below
            // doesn't double-newline.
            let block = provenance.asCSVHeader.trimmingCharacters(in: .newlines)
            lines.append(block)
        }
        lines.append(configHeaderComment(thresholds: thresholds,
                                          pxPerUm: pxPerUm,
                                          confidence: confidence ?? 0.0,
                                          modelId: modelId))
        lines.append(header.joined(separator: separator))

        // Pass-15: filter rows by the effective confidence cutoff. The CSV is
        // an analytical artifact, not the raw detection — it must match what
        // the user sees on screen.
        let cutoff = confidence ?? 0.0
        let visibleCells = cells.filter { $0.confidence >= cutoff }
        for cell in visibleCells {
            let idx = BinMath.binIndex(for: cell.diameter, thresholds: thresholds)
            let safeIdx = max(0, min(idx, bins.count - 1))
            let binLabel = bins.isEmpty ? "all" : bins[safeIdx].label

            func fmt(_ v: Double?) -> String {
                guard let v else { return "" }
                return String(format: "%.6f", v)
            }
            func boolStr(_ b: Bool) -> String { b ? "1" : "0" }

            let row: [String] = [
                cell.id.uuidString,
                String(format: "%.3f", cell.cx),
                String(format: "%.3f", cell.cy),
                String(format: "%.3f", cell.diameter),
                String(format: "%.3f", cell.diameterPx),
                csvEscape(binLabel, separator: separator),
                String(format: "%.3f", cell.confidence),
                fmt(cell.areaMicrons2),
                fmt(cell.perimeterMicrons),
                fmt(cell.circularity),
                fmt(cell.eccentricity),
                fmt(cell.meanIntensity),
                fmt(cell.integratedDensity),
                // pass-6 quality flags
                csvEscape(imageFileName, separator: separator),
                fmt(cell.centroidUmX),
                fmt(cell.centroidUmY),
                fmt(cell.aspectRatio),
                fmt(cell.solidity),
                csvEscape(cell.sizeClass, separator: separator),
                boolStr(cell.edgeTouching),
                boolStr(cell.likelyClump),
                boolStr(cell.likelyDebris),
                boolStr(cell.isManual)
            ]
            lines.append(row.joined(separator: separator))
        }

        let body = lines.joined(separator: "\n") + "\n"
        guard let data = body.data(using: .utf8) else { throw ExportError.encodeFailed }
        do {
            try data.write(to: url, options: [.atomic])
        } catch {
            throw ExportError.writeFailed(error)
        }
    }

    nonisolated private static func csvEscape(_ s: String, separator: String) -> String {
        // Neutralize spreadsheet formula injection: a free-text field beginning
        // with `=`, `+`, `-`, `@`, tab, or CR is executed as a formula by
        // Excel/LibreOffice on open. Attacker-influenceable values (image
        // filenames like `=HYPERLINK(...)`, free-text notes) flow verbatim into
        // the CSV, so prefix an apostrophe ("force text" marker) to import the
        // cell as literal text. Mirrors the Rust csv_escape guard.
        var guarded = s
        if let first = s.first,
           first == "=" || first == "+" || first == "-" || first == "@"
            || first == "\t" || first == "\r" {
            guarded = "'" + s
        }
        let needsQuote = guarded.contains(separator) || guarded.contains("\"")
            || guarded.contains("\n") || guarded.contains("\r")
        if !needsQuote { return guarded }
        let escaped = guarded.replacingOccurrences(of: "\"", with: "\"\"")
        return "\"\(escaped)\""
    }

    /// Pass-15: render the `#`-prefixed config header line embedded at the top
    /// of every CSV (and at the head of `RoiSet.config.txt`) so the analysis is
    /// self-describing. Format:
    ///   `# confidence=0.85; bins=[20,30]; model=cellpose-cyto3; pxPerUm=2.6`
    nonisolated static func configHeaderComment(thresholds: [Double],
                                    pxPerUm: Double,
                                    confidence: Double,
                                    modelId: String) -> String {
        let binsStr = "[" + thresholds.map(\.trimmedString).joined(separator: ",") + "]"
        let confStr = String(format: "%.2f", confidence)
        let pxStr   = String(format: "%g", pxPerUm)
        return "# confidence=\(confStr); bins=\(binsStr); model=\(modelId); pxPerUm=\(pxStr)"
    }

    // MARK: — Annotated PNG

    static func writeAnnotatedPNG(image: ImageRecord,
                                  detection: DetectionRecord,
                                  thresholds: [Double],
                                  pxPerUm: Double,
                                  overlayMode: OverlayMode,
                                  confidence: Double = 0.0,
                                  provenance: ProvenanceMetadata? = nil,
                                  to url: URL) throws {
        // Snapshot the SwiftData-backed values (source URL + decoded cells) on
        // the caller's actor, then hand off to the `nonisolated` compositor.
        // Callers that want to keep the MainActor free run the compositor inside
        // a `Task.detached` with these same value-type snapshots.
        try compositeAnnotatedPNG(imageURL: image.storedURL,
                                  cells: detection.cells,
                                  thresholds: thresholds,
                                  pxPerUm: pxPerUm,
                                  overlayMode: overlayMode,
                                  confidence: confidence,
                                  provenance: provenance,
                                  to: url)
    }

    /// Off-main-safe PNG compositor: full-res decode + overlay draw + encode
    /// operating purely on Sendable value types (no SwiftData `@Model` access),
    /// so it can run inside a `Task.detached` without touching the MainActor.
    nonisolated static func compositeAnnotatedPNG(imageURL: URL,
                                                  cells: [DetectedCell],
                                                  thresholds: [Double],
                                                  pxPerUm: Double,
                                                  overlayMode: OverlayMode,
                                                  confidence: Double = 0.0,
                                                  provenance: ProvenanceMetadata? = nil,
                                                  to url: URL) throws {
        guard let loaded = try? ImageLoader.load(imageURL) else { throw ExportError.missingImageBitmap }
        let cg = loaded.cgImage
        let w = cg.width
        let h = cg.height

        let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: nil,
                                  width: w,
                                  height: h,
                                  bitsPerComponent: 8,
                                  bytesPerRow: 0,
                                  space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw ExportError.encodeFailed
        }

        // Draw bitmap (CG origin is bottom-left; image draws right-side-up here since
        // we composite in image-space; we'll flip when drawing scale bar text via NSGraphicsContext.)
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))

        // Detected cells use image-space coordinates with origin at top-left.
        // Flip into CG bottom-left space for drawing primitives.
        ctx.saveGState()
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: 1, y: -1)

        let lineWidth = max(1.5, CGFloat(min(w, h)) * 0.0025)
        ctx.setLineWidth(lineWidth)
        ctx.setLineJoin(.round)

        // Pass-15: respect the confidence cutoff so the PNG matches the
        // on-screen overlay. `confidence == 0.0` (the default) means "include
        // everything" — used by code paths that haven't been migrated yet.
        let cutoff = confidence
        let drawableCells = cells.filter { $0.confidence >= cutoff }
        for cell in drawableCells {
            let idx = BinMath.binIndex(for: cell.diameter, thresholds: thresholds)
            let color = binCGColor(idx)
            ctx.setStrokeColor(color)
            // Faint fill for readability
            let fill = color.copy(alpha: 0.18) ?? color
            ctx.setFillColor(fill)

            // Fix (researcher #2): render the TRUE per-cell contour polygon
            // whenever one exists — this is exactly what the on-screen overlay
            // (EditableOverlay.CellsCanvas) draws. The exported PNG previously
            // always drew a box ("Vierecke") or ellipse from the diameter, so it
            // never matched the outlines the user saw and reviewer-drew. Cells
            // without a contour (legacy detections, manual markers) keep the
            // diameter-derived bbox/outline fallback.
            if let contour = cell.contourPx, contour.count >= 3 {
                let poly = CGMutablePath()
                poly.move(to: CGPoint(x: contour[0].x, y: contour[0].y))
                for i in 1..<contour.count {
                    poly.addLine(to: CGPoint(x: contour[i].x, y: contour[i].y))
                }
                poly.closeSubpath()
                ctx.addPath(poly)
                ctx.drawPath(using: .fillStroke)
            } else {
                let r = cell.diameterPx / 2
                let rect = CGRect(x: cell.cx - r, y: cell.cy - r, width: cell.diameterPx, height: cell.diameterPx)

                switch overlayMode {
                case .bbox:
                    ctx.fill(rect)
                    ctx.stroke(rect)
                case .outline:
                    ctx.fillEllipse(in: rect)
                    ctx.strokeEllipse(in: rect)
                }
            }
        }
        ctx.restoreGState()

        // Scale bar: bottom-left in viewer-space (which corresponds to top-left of the unflipped CG image).
        // Because the image draws upright in CG context here (origin bottom-left, image drawn at (0,0)),
        // "bottom-left" of the photo == bottom-left of the CG context (i.e. low y values).
        drawScaleBar(into: ctx,
                     imageWidth: w,
                     imageHeight: h,
                     pxPerUm: pxPerUm)

        guard let outImage = ctx.makeImage() else { throw ExportError.encodeFailed }
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL,
                                                         UTType.png.identifier as CFString,
                                                         1, nil) else {
            throw ExportError.encodeFailed
        }
        // Pass-18 (Lane R): embed the provenance block as PNG text chunks so
        // the annotated image is self-describing too. CoreGraphics maps the
        // `kCGImagePropertyPNGDictionary` text keys to `tEXt`/`iTXt` chunks.
        var pngOptions: CFDictionary? = nil
        if let provenance {
            let pngDict: [CFString: Any] = [
                kCGImagePropertyPNGDescription: "CellCounter analysis — see provenance.json",
                kCGImagePropertyPNGSoftware: "CellCounter \(provenance.appVersion) (\(provenance.appBuild))",
                kCGImagePropertyPNGComment: provenance.asCSVHeader,
            ]
            pngOptions = [kCGImagePropertyPNGDictionary as CFString: pngDict] as CFDictionary
        }
        CGImageDestinationAddImage(dest, outImage, pngOptions)
        if !CGImageDestinationFinalize(dest) {
            throw ExportError.encodeFailed
        }
    }

    // MARK: — Scale bar

    nonisolated private static func drawScaleBar(into ctx: CGContext,
                                     imageWidth w: Int,
                                     imageHeight h: Int,
                                     pxPerUm: Double) {
        let barLengthPx = max(20.0, 100.0 * pxPerUm)
        let barHeight: CGFloat = max(3, CGFloat(min(w, h)) * 0.006)
        let padding: CGFloat = max(12, CGFloat(min(w, h)) * 0.018)
        let fontSize: CGFloat = max(11, CGFloat(min(w, h)) * 0.022)

        let label = "100 µm"

        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: fontSize, weight: .medium),
            .foregroundColor: NSColor.white
        ]
        let attrText = NSAttributedString(string: label, attributes: attrs)
        let textSize = attrText.size()

        let capsuleHPad: CGFloat = max(8, fontSize * 0.6)
        let capsuleVPad: CGFloat = max(6, fontSize * 0.4)
        let gap: CGFloat = max(6, fontSize * 0.4)

        let capsuleWidth = max(CGFloat(barLengthPx), textSize.width) + capsuleHPad * 2
        let capsuleHeight = barHeight + gap + textSize.height + capsuleVPad * 2

        // Bottom-left in viewer-space corresponds to top-left of source image.
        // In CG (origin bottom-left), drawn image upright means the photo's top is at y=h.
        // We want the bar visually at the bottom-left of the photo, which in this CG
        // context is the bottom-left (low y).
        let originX = padding
        let originY = padding

        let capsuleRect = CGRect(x: originX,
                                 y: originY,
                                 width: capsuleWidth,
                                 height: capsuleHeight)

        // Capsule background (black translucent)
        let radius = capsuleHeight / 2
        let path = CGPath(roundedRect: capsuleRect,
                          cornerWidth: radius,
                          cornerHeight: radius,
                          transform: nil)
        ctx.saveGState()
        ctx.addPath(path)
        ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 0.62))
        ctx.fillPath()
        ctx.restoreGState()

        // White scale bar — placed at top of the capsule contents
        let barX = capsuleRect.midX - CGFloat(barLengthPx) / 2
        let barY = capsuleRect.maxY - capsuleVPad - barHeight
        ctx.saveGState()
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: barX, y: barY, width: CGFloat(barLengthPx), height: barHeight))
        ctx.restoreGState()

        // Text — render with NSAttributedString via NSGraphicsContext.
        // flipped: true matches AppKit's top-left origin so the text is right-side up in the PNG.
        // (B4-1 fix: was flipped: false which caused upside-down text in exported images)
        ctx.saveGState()
        let textX = capsuleRect.midX - textSize.width / 2
        let textY = capsuleRect.minY + capsuleVPad
        let ns = NSGraphicsContext(cgContext: ctx, flipped: true)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ns
        attrText.draw(at: CGPoint(x: textX, y: textY))
        NSGraphicsContext.restoreGraphicsState()
        ctx.restoreGState()
    }

    // MARK: — Bin colors

    /// Bin CGColors precomputed once from `Tokens.binRamp`. `.srgb` runs
    /// cos/sin + three pow() per call, and `binCGColor` is invoked once per
    /// drawn cell on the heaviest export path — caching the (fixed, 5-entry)
    /// ramp avoids re-running the OKLCH→sRGB conversion thousands of times.
    nonisolated private static let binCGColors: [CGColor] = Tokens.binRamp.map { color in
        let s = color.srgb
        return CGColor(red: CGFloat(s.r),
                       green: CGFloat(s.g),
                       blue: CGFloat(s.b),
                       alpha: 1)
    }

    /// CGColor for bin `index`, derived from the single `Tokens.binRamp` source
    /// of truth (OKLCH → sRGB) so exported overlays never drift from the
    /// on-screen SwiftUI swatches.
    nonisolated private static func binCGColor(_ index: Int) -> CGColor {
        let i = max(0, min(index, binCGColors.count - 1))
        return binCGColors[i]
    }

    // MARK: — Per-image summary CSV (C2 pass-6)

    /// Turn a `SizeBin.label` (e.g. `"< 20 µm"`, `"20–30 µm"`, `"> 30 µm"`, or
    /// the thresholds-empty fallback `"all"`) into a stable, ASCII,
    /// spreadsheet-safe column-name fragment: `"lt_20um"`, `"20_30um"`,
    /// `"gt_30um"`, `"all"`. Multi-character tokens (`" µm"`, `"<"`, `">"`,
    /// dashes) are substituted before the generic space→`"_"` pass; a
    /// defensive final pass strips anything left that isn't
    /// alphanumeric/underscore, so this stays safe even if `SizeBin.label`
    /// phrasing changes upstream.
    nonisolated private static func sanitizeBinLabel(_ label: String) -> String {
        var s = label
        s = s.replacingOccurrences(of: " µm", with: "um")
        s = s.replacingOccurrences(of: "<", with: "lt_")
        s = s.replacingOccurrences(of: ">", with: "gt_")
        s = s.replacingOccurrences(of: "–", with: "_")   // en dash (range)
        s = s.replacingOccurrences(of: "—", with: "_")   // em dash, just in case
        s = s.replacingOccurrences(of: "-", with: "_")   // ascii hyphen, just in case
        s = s.replacingOccurrences(of: "µ", with: "u")   // any leftover micro sign
        s = s.replacingOccurrences(of: " ", with: "_")
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_"))
        s = s.components(separatedBy: allowed.inverted).joined()
        while s.contains("__") {
            s = s.replacingOccurrences(of: "__", with: "_")
        }
        s = s.trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        return s.isEmpty ? "bin" : s
    }

    /// Write a one-row-per-image summary CSV for the entire batch.
    ///
    /// Columns match the user-specified order exactly:
    ///   image, n_cells, mean_diameter, sd_diameter,
    ///   n_bin1_<range>, n_bin2_<range>, … n_binN_<range>,
    ///   pct_clumps, pct_debris, pct_edge, confluency, n_colonies, mean_colony_size,
    ///   largest_colony, focus_score, illumination_residual, model_used, ran_at
    ///
    /// The `n_bin*` block is generated dynamically from `BinMath.bins(from:
    /// thresholds)` — one count column per size bin, so it scales to any
    /// number of thresholds rather than the historical hardcoded low/high
    /// pair. Column names encode the bin's 1-based index plus its sanitized
    /// label (see `sanitizeBinLabel`), e.g. thresholds `[20, 30]` produce
    /// `n_bin1_lt_20um, n_bin2_20_30um, n_bin3_gt_30um`.
    ///
    /// - Per-cell aggregations (counts, percentages, mean/sd diameter) come from
    ///   `image.detection?.cells`.
    /// - Per-image scalars (`confluency`, `n_colonies`, `mean_colony_size`,
    ///   `largest_colony`, `focus_score`, `illumination_residual`) come from
    ///   `image.detection?.imageStats` (C2 + C3 share this namespace).
    /// - When C1 quality flags are not populated on legacy detections, the
    ///   corresponding cells contribute "false" to count denominators but no
    ///   row is dropped. When a detection is missing entirely, the per-image
    ///   columns (including every `n_bin*` column) emit empty strings.
    ///
    /// `model_used` = the detection's `detectorId`; `ran_at` = ISO 8601 from
    /// `detection.ranAt`. Writes atomically as UTF-8.
    static func writePerImageSummaryCSV(batch: BatchRecord,
                                         thresholds: [Double],
                                         pxPerUm: Double,
                                         confidence: Double = 0.0,
                                         separator: String = ",",
                                         provenance: ProvenanceMetadata? = nil,
                                         to url: URL) throws {
        // Size bins are the single source of truth shared with the per-cell
        // CSV and the on-screen overlay (`BinMath.bins`). Deriving the header
        // from this array — instead of a hardcoded small/intermediate/large
        // triple — guarantees exactly one count column per bin, for any
        // number of thresholds.
        let bins = BinMath.bins(from: thresholds)
        let binColumnNames: [String] = bins.enumerated().map { i, bin in
            "n_bin\(i + 1)_\(sanitizeBinLabel(bin.label))"
        }

        let header = [
            "image", "n_cells", "mean_diameter", "sd_diameter",
        ] + binColumnNames + [
            "pct_clumps", "pct_debris", "pct_edge",
            "confluency", "n_colonies", "mean_colony_size", "largest_colony",
            "focus_score", "illumination_residual",
            "model_used", "ran_at",
        ]

        let isoFormatter: ISO8601DateFormatter = {
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime]
            return f
        }()

        func fmt(_ v: Double?, decimals: Int = 3) -> String {
            guard let v else { return "" }
            return String(format: "%.\(decimals)f", v)
        }
        func fmtPct(_ v: Double) -> String { String(format: "%.2f", v) }
        func stat(_ s: [String: Double], _ key: String, decimals: Int = 3) -> String {
            guard let v = s[key] else { return "" }
            return String(format: "%.\(decimals)f", v)
        }
        func statInt(_ s: [String: Double], _ key: String) -> String {
            guard let v = s[key] else { return "" }
            return String(Int(v.rounded()))
        }

        // Sort images by import order for stable, reproducible CSV rows.
        let sortedImages = batch.images.sorted { $0.importedAt < $1.importedAt }

        // Build a disambiguated filename map: if multiple images share the same
        // fileName, append _2, _3… so downstream CSV analysis has unique row keys.
        var fileNameCounts: [String: Int] = [:]
        var fileNameSeen: [String: Int] = [:]
        for img in sortedImages { fileNameCounts[img.fileName, default: 0] += 1 }
        func disambiguatedName(for img: ImageRecord) -> String {
            guard fileNameCounts[img.fileName, default: 0] > 1 else { return img.fileName }
            fileNameSeen[img.fileName, default: 0] += 1
            let suffix = fileNameSeen[img.fileName]!
            if suffix == 1 { return img.fileName }
            let base = (img.fileName as NSString).deletingPathExtension
            let ext  = (img.fileName as NSString).pathExtension
            return ext.isEmpty ? "\(base)_\(suffix)" : "\(base)_\(suffix).\(ext)"
        }

        var lines: [String] = []
        // Pass-18 (Lane R): emit the full provenance block above the
        // pass-15 single-line config header so the summary CSV is reproducible.
        if let provenance {
            let block = provenance.asCSVHeader.trimmingCharacters(in: .newlines)
            lines.append(block)
        }
        lines.append(configHeaderComment(thresholds: thresholds,
                                          pxPerUm: pxPerUm,
                                          confidence: confidence,
                                          modelId: batch.modelId))
        lines.append(header.joined(separator: separator))

        for image in sortedImages {
            // Filter per-image cells by THIS image's own effective cutoff so
            // each summary row aggregates over the same cells visible for that
            // image. `confidence` is the global fallback; an image with its own
            // `confidenceOverride` must use that, not one image's cutoff applied
            // batch-wide (matches AppState.effectiveConfidence semantics).
            let effectiveConf = image.confidenceOverride ?? confidence
            let cells = (image.detection?.cells ?? []).filter { $0.confidence >= effectiveConf }
            let nCells = cells.count
            let diameters = cells.map(\.diameter)

            // Mean / SD of diameter (µm).
            let meanD: Double = diameters.isEmpty
                ? 0
                : diameters.reduce(0, +) / Double(diameters.count)
            let sdD: Double = {
                guard diameters.count > 1 else { return 0 }
                let m = meanD
                let variance = diameters.reduce(0) { $0 + ($1 - m) * ($1 - m) } / Double(diameters.count)
                return sqrt(variance)
            }()

            // Size-bin counts. Compute LIVE from the batch's current
            // thresholds rather than the per-cell `sizeClass` string frozen at
            // detection time. Bins are a reclassification of stored
            // measurements, so the summary must track a post-hoc re-binning the
            // same way the on-screen bins do — otherwise the exported n_bin*
            // columns would silently disagree with the UI. Mirrors the
            // per-cell CSV's bucketing (`writeCSVCore` above): bucket with
            // `BinMath.binIndex`, clamped into range.
            var binCounts = [Int](repeating: 0, count: bins.count)
            for c in cells {
                let idx = BinMath.binIndex(for: c.diameter, thresholds: thresholds)
                let safeIdx = max(0, min(idx, bins.count - 1))
                binCounts[safeIdx] += 1
            }

            // Flag percentages — denominator is total cells; 0 when no cells.
            let denom = max(1, nCells)
            let nClumps = cells.filter { $0.likelyClump }.count
            let nDebris = cells.filter { $0.likelyDebris }.count
            let nEdge   = cells.filter { $0.edgeTouching }.count
            let pctClumps = 100.0 * Double(nClumps) / Double(denom)
            let pctDebris = 100.0 * Double(nDebris) / Double(denom)
            let pctEdge   = 100.0 * Double(nEdge)   / Double(denom)

            // Per-image stats (C2 + C3 namespace).
            let stats: [String: Double] = image.detection?.imageStats ?? [:]

            // Detection metadata.
            let modelUsed: String = image.detection?.detectorId ?? ""
            let ranAt: String = image.detection.map { isoFormatter.string(from: $0.ranAt) } ?? ""

            // If there's no detection at all, emit blanks for the count columns
            // too — otherwise zeros would imply "we measured zero cells" which
            // is confusing for unanalyzed images.
            let hasDetection = image.detection != nil
            let nCellsStr     = hasDetection ? String(nCells) : ""
            let meanDStr      = (hasDetection && nCells > 0) ? fmt(meanD, decimals: 3) : ""
            let sdDStr        = (hasDetection && nCells > 1) ? fmt(sdD, decimals: 3) : ""
            // One count string per bin, aligned 1:1 (same order, same count)
            // with `binColumnNames` in the header, so this stays correct for
            // any number of bins. Same "blank when unanalyzed" convention as
            // nCellsStr above.
            let binCountStrs: [String] = hasDetection
                ? binCounts.map { String($0) }
                : Array(repeating: "", count: bins.count)
            let clumpsStr     = (hasDetection && nCells > 0) ? fmtPct(pctClumps) : ""
            let debrisStr     = (hasDetection && nCells > 0) ? fmtPct(pctDebris) : ""
            let edgeStr       = (hasDetection && nCells > 0) ? fmtPct(pctEdge)   : ""

            let row: [String] = [
                csvEscape(disambiguatedName(for: image), separator: separator),
                nCellsStr,
                meanDStr,
                sdDStr,
            ] + binCountStrs + [
                clumpsStr,
                debrisStr,
                edgeStr,
                stat(stats, "confluency_pct", decimals: 2),
                statInt(stats, "n_colonies"),
                stat(stats, "mean_colony_size_cells", decimals: 2),
                statInt(stats, "largest_colony_size_cells"),
                stat(stats, "focus_score", decimals: 4),
                stat(stats, "illumination_residual", decimals: 4),
                csvEscape(modelUsed, separator: separator),
                csvEscape(ranAt, separator: separator),
            ]
            lines.append(row.joined(separator: separator))
        }

        let body = lines.joined(separator: "\n") + "\n"
        guard let data = body.data(using: .utf8) else { throw ExportError.encodeFailed }
        do {
            try data.write(to: url, options: [.atomic])
        } catch {
            throw ExportError.writeFailed(error)
        }
    }

    // MARK: — ImageJ RoiSet.zip (Pass-14 F3)

    /// Cell payload sent to the Python helper. Snake-case keys so `_export_imagej_roi.py`
    /// can read it without a translation layer.
    private struct ROICellWire: Encodable {
        let id: String
        let cx: Double
        let cy: Double
        let diameter_px: Double
        let contour_px: [[Double]]?
        let name: String?
    }

    private struct ROIWireBlob: Encodable {
        let width: Int
        let height: Int
        let cells: [ROICellWire]
    }

    private struct ROIHelperResult: Decodable {
        let ok: Bool
        let n_rois: Int?
        let path: String?
        let error: String?
    }

    /// Write an ImageJ-compatible `RoiSet.zip` for the given detection.
    ///
    /// Polygon ROIs are emitted when a cell has a non-nil `contourPx`; cells
    /// without contours fall back to an OVAL ROI sized from `diameterPx`.
    /// Each ROI's z/c/t position is set to 1 (2D images).
    ///
    /// Blocks the caller on the venv Python subprocess. The helper finishes
    /// in well under a second even for 500+ cells.
    ///
    /// Pass-15: filters by `confidence` and writes a sibling
    /// `RoiSet.config.txt` next to the .zip (since `roifile` doesn't expose a
    /// metadata channel we control) so the analysis is self-describing.
    static func writeImageJROIs(image: ImageRecord,
                                detection: DetectionRecord,
                                thresholds: [Double] = [],
                                pxPerUm: Double = 1.0,
                                confidence: Double = 0.0,
                                modelId: String? = nil,
                                to url: URL) throws {
        // Snapshot the SwiftData-backed values on the caller's actor, then hand
        // off to the `nonisolated` core so the (blocking) Python subprocess wait
        // runs off the MainActor when invoked from a `Task.detached`.
        try writeImageJROIsCore(cells: detection.cells,
                                imageWidthPx: image.widthPx,
                                imageHeightPx: image.heightPx,
                                imageFileName: image.fileName,
                                thresholds: thresholds,
                                pxPerUm: pxPerUm,
                                confidence: confidence,
                                modelId: modelId ?? detection.detectorId,
                                to: url)
    }

    /// Off-main-safe ROI writer: encodes the wire blob, spawns + waits on the
    /// Python helper, and writes the sibling config file, all from Sendable
    /// value types (no SwiftData `@Model` access).
    nonisolated static func writeImageJROIsCore(cells rawCells: [DetectedCell],
                                                imageWidthPx: Int,
                                                imageHeightPx: Int,
                                                imageFileName: String,
                                                thresholds: [Double] = [],
                                                pxPerUm: Double = 1.0,
                                                confidence: Double = 0.0,
                                                modelId: String,
                                                to url: URL) throws {
        // Resolve the venv python + the helper script via the same path the
        // detection sidecars use.
        let availability = CellposeAvailability.detect()
        let pythonURL: URL
        switch availability {
        case .available(let py, _):
            pythonURL = py
        case .missingScripts, .missingVenv, .missingInstaller, .venvBroken:
            throw ExportError.pythonUnavailable
        }

        let scriptURL: URL = {
            if let staged = PythonRuntime.stagedScriptURL(named: "_export_imagej_roi.py") {
                return staged
            }
            // Fallback to the bundle path; shouldn't normally hit because
            // stageScripts() copies the helper next to the venv.
            return PythonRuntime.bundledPythonURL(named: "_export_imagej_roi.py")
                ?? FileStore.shared.pythonDir.appendingPathComponent("_export_imagej_roi.py")
        }()

        // Pass-15: filter to cells above the effective cutoff so the ROI zip
        // matches the visible overlay / CSV.
        let cells = rawCells.filter { $0.confidence >= confidence }
        guard !cells.isEmpty else {
            throw ExportError.roiExportFailed("There are no detected cells to export.")
        }

        let wireCells: [ROICellWire] = cells.map { c in
            let contour: [[Double]]? = c.contourPx.flatMap { pts in
                guard !pts.isEmpty else { return nil }
                return pts.map { [Double($0.x), Double($0.y)] }
            }
            return ROICellWire(
                id: c.id.uuidString,
                cx: c.cx,
                cy: c.cy,
                diameter_px: c.diameterPx,
                contour_px: contour,
                name: nil
            )
        }
        let blob = ROIWireBlob(width: imageWidthPx,
                               height: imageHeightPx,
                               cells: wireCells)

        let inputURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cc-roi-\(UUID().uuidString.prefix(8)).json")
        defer { try? FileManager.default.removeItem(at: inputURL) }

        do {
            let data = try JSONEncoder().encode(blob)
            try data.write(to: inputURL, options: [.atomic])
        } catch {
            throw ExportError.writeFailed(error)
        }

        let proc = Process()
        proc.executableURL = pythonURL
        proc.arguments = [
            scriptURL.path,
            "--in", inputURL.path,
            "--out", url.path,
        ]
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        proc.standardOutput = stdoutPipe
        proc.standardError = stderrPipe

        do {
            try proc.run()
        } catch {
            throw ExportError.writeFailed(error)
        }

        // CRITICAL: drain BOTH pipes concurrently BEFORE waitUntilExit(). The
        // helper writes one stderr line per skipped/degenerate cell, so a
        // detection with many malformed contours can fill the OS pipe buffer
        // (~16–64 KB); if we joined the process first it would block on
        // `sys.stderr.write` and never exit, deadlocking waitUntilExit()
        // forever. Reading each handle on its own background queue keeps both
        // buffers moving and bounds memory to the emitted payload. Mirrors
        // SidecarProcessRunner / ChildProcessTracker's concurrent-drain rule.
        let drainLock = NSLock()
        var stdoutData = Data()
        var stderrData = Data()
        let drainGroup = DispatchGroup()
        func drain(_ pipe: Pipe, into store: @escaping (Data) -> Void) {
            drainGroup.enter()
            DispatchQueue.global(qos: .utility).async {
                let d = (try? pipe.fileHandleForReading.readToEnd()) ?? Data()
                drainLock.lock(); store(d); drainLock.unlock()
                drainGroup.leave()
            }
        }
        drain(stdoutPipe) { stdoutData = $0 }
        drain(stderrPipe) { stderrData = $0 }

        // Soft watchdog backstop: if the helper wedges, terminate it so the
        // export surfaces an error instead of hanging the export thread.
        let watchdog = DispatchWorkItem { [weak proc] in
            guard let proc, proc.isRunning else { return }
            proc.terminate()
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 120.0, execute: watchdog)
        proc.waitUntilExit()
        watchdog.cancel()
        drainGroup.wait()

        if proc.terminationStatus != 0 {
            let stderrText = String(data: stderrData, encoding: .utf8) ?? ""
            let stdoutText = String(data: stdoutData, encoding: .utf8) ?? ""
            // The helper writes structured errors to stdout; surface those first.
            if let parsed = try? JSONDecoder().decode(ROIHelperResult.self, from: stdoutData),
               let msg = parsed.error {
                throw ExportError.roiExportFailed(msg)
            }
            let combined = stderrText.isEmpty ? stdoutText : stderrText
            throw ExportError.roiExportFailed("exit \(proc.terminationStatus): \(combined.prefix(400))")
        }

        // Parse the success payload — non-fatal if we can't, since the zip
        // was already written.
        if let result = try? JSONDecoder().decode(ROIHelperResult.self, from: stdoutData),
           result.ok == false,
           let msg = result.error {
            throw ExportError.roiExportFailed(msg)
        }

        // Pass-15: write a sibling `<RoiSet>.config.txt` so analysis is
        // self-describing. `roifile` (used by the Python helper) has no
        // metadata channel we control, so we put it adjacent to the .zip.
        // Best-effort: failure to write this file does NOT fail the export.
        let configURL = url.deletingPathExtension().appendingPathExtension("config.txt")
        let header = configHeaderComment(thresholds: thresholds,
                                         pxPerUm: pxPerUm,
                                         confidence: confidence,
                                         modelId: modelId)
        let body = "\(header)\n# image=\(imageFileName); n_rois=\(cells.count)\n"
        try? body.data(using: .utf8)?.write(to: configURL, options: [.atomic])
    }

    // MARK: — Ground-truth annotations (Pass-17, Lane B)

    /// ISO-8601 formatter for the JSON/CSV `created_at` field. Reused via a
    /// type-level static so we don't pay the init cost per cell.
    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    /// Write a portable JSON file describing the ground-truth annotations on
    /// `image`. Shape:
    ///   {
    ///     "image_id": "...",
    ///     "image_filename": "...",
    ///     "pxPerUm": 2.6,
    ///     "annotations": [
    ///       { "id": "...", "cx": 412.5, "cy": 309.1,
    ///         "diameter": null, "note": null,
    ///         "created_at": "2026-05-27T13:24:08.123Z" }, ...
    ///     ]
    ///   }
    /// Intended for direct ingestion into a Jupyter notebook for F1 analysis.
    static func writeAnnotationsJSON(image: ImageRecord,
                                     annotations: [GroundTruthAnnotation],
                                     pxPerUm: Double,
                                     provenance: ProvenanceMetadata? = nil,
                                     to url: URL) throws {
        struct AnnotationOut: Encodable {
            let id: String
            let cx: Double
            let cy: Double
            let diameter: Double?
            let note: String?
            let created_at: String
        }
        struct Envelope: Encodable {
            let image_id: String
            let image_filename: String
            let pxPerUm: Double
            let annotations: [AnnotationOut]
            // Pass-18 (Lane R): siblings — present only when supplied.
            let provenance: ProvenanceMetadata?
        }
        let out = Envelope(
            image_id: image.id.uuidString,
            image_filename: image.fileName,
            pxPerUm: pxPerUm,
            annotations: annotations.map { a in
                AnnotationOut(id: a.id.uuidString,
                              cx: a.cx,
                              cy: a.cy,
                              diameter: a.diameter,
                              note: a.note,
                              created_at: isoFormatter.string(from: a.createdAt))
            },
            provenance: provenance
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data: Data
        do {
            data = try encoder.encode(out)
        } catch {
            throw ExportError.encodeFailed
        }
        do {
            try data.write(to: url, options: [.atomic])
        } catch {
            throw ExportError.writeFailed(error)
        }
    }

    /// Write a CSV describing the ground-truth annotations. Header:
    ///   id,cx_px,cy_px,cx_um,cy_um,diameter_um,note,created_at
    /// Centroid coords are emitted in both pixels (matches detection CSV) and
    /// µm (matches the per-cell measurements columns) so the file is usable
    /// for direct ImageJ overlay without a conversion step.
    static func writeAnnotationsCSV(image: ImageRecord,
                                    annotations: [GroundTruthAnnotation],
                                    pxPerUm: Double,
                                    provenance: ProvenanceMetadata? = nil,
                                    to url: URL) throws {
        let separator = ","
        var lines: [String] = []
        // Pass-18 (Lane R): full provenance block first when supplied.
        if let provenance {
            let block = provenance.asCSVHeader.trimmingCharacters(in: .newlines)
            lines.append(block)
        }
        // Self-describing config-style comment header so downstream tooling
        // knows the calibration that converted pixels → µm.
        let pxStr = String(format: "%g", pxPerUm)
        lines.append("# image=\(image.fileName); n=\(annotations.count); pxPerUm=\(pxStr)")
        lines.append(["id", "cx_px", "cy_px", "cx_um", "cy_um",
                      "diameter_um", "note", "created_at"].joined(separator: separator))
        let pxToUm = pxPerUm > 0 ? 1.0 / pxPerUm : 0.0
        for a in annotations {
            let cxUm = a.cx * pxToUm
            let cyUm = a.cy * pxToUm
            let diamStr: String
            if let d = a.diameter { diamStr = String(format: "%.3f", d) } else { diamStr = "" }
            let row: [String] = [
                a.id.uuidString,
                String(format: "%.3f", a.cx),
                String(format: "%.3f", a.cy),
                String(format: "%.3f", cxUm),
                String(format: "%.3f", cyUm),
                diamStr,
                csvEscape(a.note ?? "", separator: separator),
                isoFormatter.string(from: a.createdAt)
            ]
            lines.append(row.joined(separator: separator))
        }
        let body = lines.joined(separator: "\n") + "\n"
        guard let data = body.data(using: .utf8) else { throw ExportError.encodeFailed }
        do {
            try data.write(to: url, options: [.atomic])
        } catch {
            throw ExportError.writeFailed(error)
        }
    }
}
