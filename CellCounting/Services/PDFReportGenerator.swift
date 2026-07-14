import Foundation
import AppKit
import CoreGraphics
import ImageIO

/// 1-page A4 PDF lab-journal report.
///
/// Layout (A4 portrait at 144 dpi → 1190 × 1684 px):
///   - Header band: title block (file · date · model · version)
///   - Left ~52% column: annotated image
///   - Right ~48% column: counts + bin histogram + bin table + colony stats
///     + QC + (optional) F1 vs ground truth.
///   - Footer: three monospaced provenance lines.
///
/// Render path: the page is drawn **directly into a CoreGraphics PDF context**
/// with AppKit (`NSAttributedString`, `NSBezierPath`, `NSImage`) through a
/// flipped `NSGraphicsContext`. We deliberately do NOT go through SwiftUI's
/// `ImageRenderer`: that rasterizes the whole page to a bitmap and, in a
/// sandboxed / hardened-runtime Release build, can hand back a blank image
/// (producing an "empty" PDF). Direct CG drawing is deterministic, works the
/// same in every packaging context, keeps the text **vector/selectable**, and
/// is verifiable off-screen. All bin colors come from the single
/// `Tokens.binRamp` source of truth (via `binCGColor`) so the swatches, the
/// histogram bars, and the annotated-image ellipses match exactly.
enum PDFReportError: LocalizedError {
    case missingImageBitmap
    case renderFailed
    case writeFailed(Error)

    var errorDescription: String? {
        switch self {
        case .missingImageBitmap: return "Couldn't open the source image for the PDF report."
        case .renderFailed: return "Couldn't render the PDF report."
        case .writeFailed(let e): return "Couldn't write the PDF report: \(e.localizedDescription)"
        }
    }
}

struct PDFReportGenerator {

    // A4 at 144 dpi (matches 8.27" × 11.69").
    private static let pageWidth: CGFloat = 1190
    private static let pageHeight: CGFloat = 1684
    private static let margin: CGFloat = 48

    // Palette (mirrors the on-screen report styling). `nonisolated(unsafe)` so
    // the off-main render path can read these immutable NSColor constants.
    nonisolated(unsafe) private static let ink      = NSColor(srgbRed: 0.10, green: 0.10, blue: 0.12, alpha: 1)
    nonisolated(unsafe) private static let ink2     = NSColor(srgbRed: 0.35, green: 0.35, blue: 0.40, alpha: 1)
    nonisolated(unsafe) private static let ink3     = NSColor(srgbRed: 0.55, green: 0.55, blue: 0.60, alpha: 1)
    nonisolated(unsafe) private static let divider  = NSColor(srgbRed: 0.86, green: 0.86, blue: 0.88, alpha: 1)
    nonisolated(unsafe) private static let faintBg  = NSColor(srgbRed: 0.0,  green: 0.0,  blue: 0.0,  alpha: 0.04)

    /// Sendable snapshot of everything the PDF needs, captured on the MainActor
    /// so the actual render (full-res decode + composite + draw + write) can run
    /// off the main actor without touching any SwiftData `@Model`.
    struct Inputs: Sendable {
        let snapshot: ReportSnapshot
        let storedURL: URL
        let cells: [DetectedCell]
        let thresholds: [Double]
        let pxPerUm: Double
        let confidence: Double
    }

    /// Capture the report inputs from the live SwiftData models on the MainActor.
    /// Cheap (no image decode) — the heavy work happens in `writeReport(inputs:)`.
    @MainActor
    static func makeInputs(image: ImageRecord, state: AppState) -> Inputs {
        let snapshot = ReportSnapshot.make(image: image, state: state)
        return Inputs(snapshot: snapshot,
                      storedURL: image.storedURL,
                      cells: image.detection?.cells ?? [],
                      thresholds: snapshot.thresholds,
                      pxPerUm: snapshot.pxPerUm,
                      confidence: snapshot.confidence)
    }

    /// Off-main-safe render: decode the source, composite the overlay, draw the
    /// one-page PDF, and write it — purely on Sendable value types. Callers run
    /// this inside a `Task.detached` to keep the MainActor free during export;
    /// this is the heaviest export step (full-res decode + composite).
    nonisolated static func writeReport(inputs: Inputs, to url: URL) throws {
        // Best-effort annotated overlay: if the source can't be decoded we still
        // emit the text report rather than failing (mirrors the Rust port).
        let annotated = try? renderAnnotatedNSImage(imageURL: inputs.storedURL,
                                                    cells: inputs.cells,
                                                    thresholds: inputs.thresholds,
                                                    pxPerUm: inputs.pxPerUm,
                                                    confidence: inputs.confidence)
        let data = try renderPDFData(snapshot: inputs.snapshot, annotated: annotated)
        do {
            try data.write(to: url, options: [.atomic])
        } catch {
            throw PDFReportError.writeFailed(error)
        }
    }

    /// Convenience for MainActor callers that hold the live models. Captures the
    /// inputs then renders synchronously on the caller's thread. `annotations` is
    /// reserved for Lane B — when nil the F1 row is derived from stored annotations.
    @MainActor
    static func writeReport(image: ImageRecord,
                            state: AppState,
                            annotations: Any? = nil,
                            to url: URL) throws {
        try writeReport(inputs: makeInputs(image: image, state: state), to: url)
    }

    /// Draw the one-page report into a fresh CG PDF context and return the bytes.
    /// Pure CoreGraphics/AppKit (no SwiftUI / ImageRenderer), so it is
    /// deterministic and renders identically on any thread and in any packaging.
    nonisolated static func renderPDFData(snapshot: ReportSnapshot, annotated: NSImage?) throws -> Data {
        var mediaBox = CGRect(x: 0, y: 0, width: pageWidth, height: pageHeight)
        guard let pdfData = CFDataCreateMutable(nil, 0),
              let consumer = CGDataConsumer(data: pdfData),
              let pdfCtx = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            throw PDFReportError.renderFailed
        }

        pdfCtx.beginPDFPage(nil)
        // Flip the CG coordinate system to a top-left origin (y-down) and wrap it
        // in a `flipped: true` NSGraphicsContext. This is the canonical recipe for
        // drawing AppKit content top-down into a CG PDF context: the CTM flip puts
        // the origin at the top-left, and `flipped: true` makes AppKit render text
        // and images right-side-up rather than mirrored.
        pdfCtx.translateBy(x: 0, y: pageHeight)
        pdfCtx.scaleBy(x: 1, y: -1)
        let gctx = NSGraphicsContext(cgContext: pdfCtx, flipped: true)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = gctx
        drawReport(snapshot: snapshot, annotated: annotated)
        NSGraphicsContext.restoreGraphicsState()
        pdfCtx.endPDFPage()
        pdfCtx.closePDF()

        return pdfData as Data
    }

    // MARK: — Page drawing (CoreGraphics / AppKit, top-left coords)

    nonisolated private static func drawReport(snapshot snap: ReportSnapshot, annotated: NSImage?) {
        let contentLeft = margin
        let contentRight = pageWidth - margin
        var y = margin

        // ---- header ----
        draw("CellCounter analysis report", at: CGPoint(x: contentLeft, y: y), size: 26, weight: .bold, color: ink)
        y += 34
        draw("File: \(snap.fileName)    Date: \(snap.dateISO)", at: CGPoint(x: contentLeft, y: y), size: 11, color: ink2)
        y += 18
        draw("Model: \(snap.modelName)    Version: \(snap.appVersion)", at: CGPoint(x: contentLeft, y: y), size: 11, color: ink2)
        y += 20
        hLine(x0: contentLeft, x1: contentRight, y: y, color: divider, width: 1)
        y += 18

        // Two columns: right analysis fixed 480 (like the on-screen report),
        // left image takes the rest.
        let rightW: CGFloat = 480
        let colGap: CGFloat = 24
        let leftW = contentRight - contentLeft - rightW - colGap
        let leftX = contentLeft
        let rightX = contentLeft + leftW + colGap
        let columnsTop = y

        // ---- left column: annotated image ----
        sectionTitle("Annotated image", at: CGPoint(x: leftX, y: columnsTop))
        let imgTop = columnsTop + 16
        let imgBoxH = min(1180, pageHeight - imgTop - 120)
        if let a = annotated, a.size.width > 0, a.size.height > 0 {
            let (fitW, fitH) = fitBox(a.size.width, a.size.height, leftW, imgBoxH)
            faintBg.setFill()
            NSBezierPath(rect: NSRect(x: leftX, y: imgTop, width: fitW, height: fitH)).fill()
            a.draw(in: NSRect(x: leftX, y: imgTop, width: fitW, height: fitH))
            strokeRect(x: leftX, y: imgTop, w: fitW, h: fitH, color: divider, width: 1)
        } else {
            strokeRect(x: leftX, y: imgTop, w: leftW, h: 200, color: divider, width: 1)
            draw("Source image unavailable.", at: CGPoint(x: leftX + 12, y: imgTop + 20), size: 12, color: ink2)
        }

        // ---- right column ----
        var ry = columnsTop

        // Count summary.
        sectionTitle("Count summary", at: CGPoint(x: rightX, y: ry)); ry += 18
        draw("\(snap.nCells) cells detected", at: CGPoint(x: rightX, y: ry), size: 18, weight: .semibold, color: ink); ry += 24
        if let med = snap.medianDiameter {
            var parts = [String(format: "median %.1f µm", med)]
            if let m = snap.meanDiameter { parts.append(String(format: "mean %.1f µm", m)) }
            if let s = snap.sdDiameter { parts.append(String(format: "σ %.1f µm", s)) }
            draw(parts.joined(separator: " · "), at: CGPoint(x: rightX, y: ry), size: 12, color: ink2); ry += 16
        }
        if let lo = snap.iqrLow, let hi = snap.iqrHigh {
            draw(String(format: "IQR: %.1f – %.1f µm", lo, hi), at: CGPoint(x: rightX, y: ry), size: 12, color: ink2); ry += 16
        }
        ry += 8

        // Histogram.
        sectionTitle("Size bin distribution", at: CGPoint(x: rightX, y: ry)); ry += 16
        let histH: CGFloat = 110
        drawHistogram(x: rightX, y: ry, w: rightW, h: histH, bins: snap.binCounts)
        ry += histH + 14

        // Bin table (swatch + label + count(pct)).
        for (i, entry) in snap.binCounts.enumerated() {
            let pct = snap.totalForPct > 0 ? 100.0 * Double(entry.count) / Double(snap.totalForPct) : 0
            NSColor(cgColor: binCGColor(i))?.setFill()
            NSBezierPath(rect: NSRect(x: rightX, y: ry - 9, width: 10, height: 10)).fill()
            draw(entry.label, at: CGPoint(x: rightX + 16, y: ry - 11), size: 12, color: ink)
            drawRight(String(format: "%d (%.1f%%)", entry.count, pct), rightX: rightX + rightW, y: ry - 11, size: 12, weight: .medium, color: ink2)
            ry += 16
        }
        ry += 10

        // Colonies.
        sectionTitle("Colonies", at: CGPoint(x: rightX, y: ry)); ry += 16
        if let n = snap.nColonies, let conf = snap.confluencyPct {
            draw("\(n) colonies · \(String(format: "%.1f", conf))% confluency", at: CGPoint(x: rightX, y: ry), size: 13, weight: .medium, color: ink); ry += 16
            var extras: [String] = []
            if let m = snap.meanColonySize { extras.append(String(format: "mean %.1f cells/colony", m)) }
            if let l = snap.largestColony { extras.append("largest \(l) cells") }
            if !extras.isEmpty { draw(extras.joined(separator: " · "), at: CGPoint(x: rightX, y: ry), size: 11, color: ink2); ry += 16 }
        } else {
            draw("No colony data recorded.", at: CGPoint(x: rightX, y: ry), size: 12, color: ink2); ry += 16
        }
        ry += 10

        // QC scores.
        sectionTitle("QC scores", at: CGPoint(x: rightX, y: ry)); ry += 16
        let focus = snap.focusScore.map { String(format: "%.3f", $0) } ?? "—"
        let illum = snap.illuminationResidual.map { String(format: "%.3f", $0) } ?? "—"
        draw("Focus", at: CGPoint(x: rightX, y: ry), size: 10, color: ink2)
        draw("Illumination residual", at: CGPoint(x: rightX + 200, y: ry), size: 10, color: ink2); ry += 14
        draw(focus, at: CGPoint(x: rightX, y: ry), size: 14, weight: .semibold, color: ink)
        draw(illum, at: CGPoint(x: rightX + 200, y: ry), size: 14, weight: .semibold, color: ink); ry += 22

        // F1 vs ground truth (only when present).
        if let f1 = snap.f1 {
            sectionTitle("Ground truth", at: CGPoint(x: rightX, y: ry)); ry += 16
            draw(String(format: "F1 vs annotations: %.3f", f1), at: CGPoint(x: rightX, y: ry), size: 13, color: ink)
        }

        // ---- footer: provenance lines ----
        let footerY = pageHeight - margin - 40
        hLine(x0: contentLeft, x1: contentRight, y: footerY - 10, color: divider, width: 1)
        let lines: [String] = snap.provenance.map { Self.provenanceFooterLines($0) }
            ?? ["\(snap.dateISO)    CellCounter v\(snap.appVersion)    Calibration: \(snap.calibrationSource) · \(String(format: "%.3f px/µm", snap.pxPerUm))"]
        for (i, line) in lines.enumerated() {
            draw(line, at: CGPoint(x: contentLeft, y: footerY + CGFloat(i) * 12), size: 9, color: ink3, mono: true)
        }
    }

    // MARK: — Drawing primitives (flipped/top-left coords)

    /// Draw `s` with its top-left at `p`.
    nonisolated private static func draw(_ s: String, at p: CGPoint, size: CGFloat,
                             weight: NSFont.Weight = .regular, color: NSColor, mono: Bool = false) {
        attributed(s, size: size, weight: weight, color: color, mono: mono).draw(at: p)
    }

    /// Draw `s` right-aligned so its right edge sits at `rightX`, top at `y`.
    nonisolated private static func drawRight(_ s: String, rightX: CGFloat, y: CGFloat, size: CGFloat,
                                  weight: NSFont.Weight = .regular, color: NSColor) {
        let a = attributed(s, size: size, weight: weight, color: color, mono: false)
        a.draw(at: CGPoint(x: rightX - a.size().width, y: y))
    }

    /// Uppercased, tracked section label.
    nonisolated private static func sectionTitle(_ s: String, at p: CGPoint) {
        let font = NSFont.systemFont(ofSize: 10, weight: .semibold)
        let a = NSAttributedString(string: s.uppercased(),
                                   attributes: [.font: font, .foregroundColor: ink2, .kern: 1.2])
        a.draw(at: p)
    }

    nonisolated private static func attributed(_ s: String, size: CGFloat, weight: NSFont.Weight,
                                   color: NSColor, mono: Bool = false) -> NSAttributedString {
        let font = mono ? NSFont.monospacedSystemFont(ofSize: size, weight: weight)
                        : NSFont.systemFont(ofSize: size, weight: weight)
        return NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: color])
    }

    nonisolated private static func hLine(x0: CGFloat, x1: CGFloat, y: CGFloat, color: NSColor, width: CGFloat) {
        color.setStroke()
        let p = NSBezierPath()
        p.move(to: NSPoint(x: x0, y: y))
        p.line(to: NSPoint(x: x1, y: y))
        p.lineWidth = width
        p.stroke()
    }

    nonisolated private static func strokeRect(x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat, color: NSColor, width: CGFloat) {
        color.setStroke()
        let p = NSBezierPath(rect: NSRect(x: x, y: y, width: w, height: h))
        p.lineWidth = width
        p.stroke()
    }

    /// Fit (iw,ih) into (bw,bh) preserving aspect ratio.
    nonisolated private static func fitBox(_ iw: CGFloat, _ ih: CGFloat, _ bw: CGFloat, _ bh: CGFloat) -> (CGFloat, CGFloat) {
        guard iw > 0, ih > 0 else { return (bw, bh) }
        let scale = min(bw / iw, bh / ih)
        return (iw * scale, ih * scale)
    }

    /// Mini bar chart of bin counts with count labels above each bar.
    nonisolated private static func drawHistogram(x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat,
                                      bins: [(label: String, count: Int)]) {
        strokeRect(x: x, y: y, w: w, h: h, color: divider, width: 1)
        let n = max(1, bins.count)
        let maxV = CGFloat(max(bins.map(\.count).max() ?? 1, 1))
        let gap: CGFloat = 6
        let innerPad: CGFloat = 8
        let totalGap = gap * CGFloat(max(0, n - 1))
        let barW = max(2, (w - totalGap - innerPad * 2) / CGFloat(n))
        for (i, b) in bins.enumerated() {
            let frac = CGFloat(b.count) / maxV
            let barH = max(1, (h - 22) * frac)
            let bx = x + innerPad + CGFloat(i) * (barW + gap)
            let by = y + h - 18 - barH
            NSColor(cgColor: binCGColor(i))?.setFill()
            NSBezierPath(rect: NSRect(x: bx, y: by, width: barW, height: barH)).fill()
            // Count label centered above the bar (clamped so the tallest bar's
            // label never draws above the chart's top edge).
            let a = attributed("\(b.count)", size: 9, weight: .semibold, color: ink2)
            let lx = bx + (barW - a.size().width) / 2
            let ly = max(y + 1, by - 12)
            a.draw(at: CGPoint(x: lx, y: ly))
        }
    }

    // MARK: — Annotated overlay (shared style with writeAnnotatedPNG)

    /// Renders the annotated overlay into an NSImage from Sendable value types
    /// (source URL + decoded cells), so it can run off the MainActor — mirrors
    /// `ExportService.compositeAnnotatedPNG` so the PDF's embedded image is
    /// visually identical to the standalone `annotated.png`.
    nonisolated static func renderAnnotatedNSImage(imageURL: URL,
                                                   cells: [DetectedCell],
                                                   thresholds: [Double],
                                                   pxPerUm: Double,
                                                   confidence: Double) throws -> NSImage {
        let loaded = try ImageLoader.load(imageURL)
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
            throw PDFReportError.renderFailed
        }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))

        let visibleCells = cells.filter { $0.confidence >= confidence }
        if !visibleCells.isEmpty {
            ctx.saveGState()
            ctx.translateBy(x: 0, y: CGFloat(h))
            ctx.scaleBy(x: 1, y: -1)
            let lineWidth = max(1.5, CGFloat(min(w, h)) * 0.0025)
            ctx.setLineWidth(lineWidth)
            ctx.setLineJoin(.round)
            for cell in visibleCells {
                let idx = BinMath.binIndex(for: cell.diameter, thresholds: thresholds)
                let color = binCGColor(idx)
                ctx.setStrokeColor(color)
                let fill = color.copy(alpha: 0.18) ?? color
                ctx.setFillColor(fill)

                // Fix (same class as the PNG export bug): draw the TRUE per-cell
                // contour polygon whenever one exists, matching the on-screen
                // overlay (EditableOverlay.CellsCanvas) and
                // ExportService.compositeAnnotatedPNG. The PDF's embedded image
                // previously always drew a diameter-derived ellipse here, so it
                // never matched the real cell outline the user sees on screen or
                // in the annotated PNG. Cells without a contour (legacy
                // detections, manual markers) keep the ellipse fallback.
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
                    let rect = CGRect(x: cell.cx - r, y: cell.cy - r,
                                       width: cell.diameterPx, height: cell.diameterPx)
                    ctx.fillEllipse(in: rect)
                    ctx.strokeEllipse(in: rect)
                }
            }
            ctx.restoreGState()
        }

        guard let outImage = ctx.makeImage() else {
            throw PDFReportError.renderFailed
        }
        return NSImage(cgImage: outImage, size: NSSize(width: w, height: h))
    }

    /// Bin CGColor derived from the single `Tokens.binRamp` source of truth, so
    /// the PDF's overlay ellipses, the histogram bars, and the table swatches
    /// all match the on-screen swatches and the PNG export.
    nonisolated private static func binCGColor(_ index: Int) -> CGColor {
        let ramp = Tokens.binRamp
        let i = max(0, min(index, ramp.count - 1))
        let s = ramp[i].srgb
        return CGColor(red: CGFloat(s.r), green: CGFloat(s.g), blue: CGFloat(s.b), alpha: 1)
    }

    /// Compose the three monospaced footer lines from a provenance block.
    /// Nil-valued tokens are omitted cleanly so the lines stay tidy when e.g.
    /// the git SHA or weights hash isn't available.
    nonisolated static func provenanceFooterLines(_ p: ProvenanceMetadata) -> [String] {
        var line1 = "generated by CellCounter \(p.appVersion)"
        if let sha = p.appBuildSHA { line1 += " (\(sha))" }
        line1 += " · \(p.modelName)"
        if let wh = p.weightsHash { line1 += " @ \(String(wh.prefix(8)))" }
        var line2 = "detector: \(p.modelFamily)"
        if let dv = p.detectorVersion { line2 += "@\(dv)" }
        line2 += " · \(p.osVersion)"
        let line3 = String(format: "calibration: %.4g px/µm (%@)", p.pxPerUm, p.pxPerUmSource)
        return [line1, line2, line3]
    }
}

// MARK: — Report snapshot (pure value type — Sendable)

struct ReportSnapshot {
    let fileName: String
    let dateISO: String
    let appVersion: String
    let modelName: String
    let pxPerUm: Double
    let confidence: Double
    let thresholds: [Double]

    let nCells: Int
    let medianDiameter: Double?
    let meanDiameter: Double?
    let sdDiameter: Double?
    let iqrLow: Double?
    let iqrHigh: Double?

    let binCounts: [(label: String, count: Int)]
    let totalForPct: Int

    let nColonies: Int?
    let confluencyPct: Double?
    let meanColonySize: Double?
    let largestColony: Int?

    let focusScore: Double?
    let illuminationResidual: Double?

    let f1: Double?
    let calibrationSource: String

    // Provenance block — surfaced as a 3-line monospaced footer so the page is
    // self-describing.
    let provenance: ProvenanceMetadata?

    static func make(image: ImageRecord, state: AppState) -> ReportSnapshot {
        let isoFmt = ISO8601DateFormatter()
        isoFmt.formatOptions = [.withInternetDateTime]
        let dateStr = isoFmt.string(from: Date())

        let appVersion: String = {
            let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
            return v
        }()

        // Resolve calibration from the batch first, falling back to global state —
        // exactly as ProvenanceMetadata.capture does — so the report body and its
        // provenance footer report the SAME px/µm, thresholds, and confidence.
        let batch = image.batch ?? state.currentBatch
        let pxPerUm = batch?.pxPerUm ?? state.pxPerUm
        let thresholds = batch?.thresholds ?? state.thresholds

        let cutoff = state.effectiveConfidence(for: image)
        let cells: [DetectedCell] = (image.detection?.cells ?? []).filter { $0.confidence >= cutoff }
        let diameters = cells.map(\.diameter).sorted()
        let n = diameters.count

        // Type-7 (linear-interpolation) quantile — matches numpy's default and
        // avoids the nearest-rank bias, so the reported IQR is unbiased and
        // consistent with the canonical median used below.
        func quantile(_ p: Double) -> Double? {
            guard !diameters.isEmpty else { return nil }
            if diameters.count == 1 { return diameters[0] }
            let h = p * Double(diameters.count - 1)
            let lo = Int(h.rounded(.down))
            let hi = Swift.min(lo + 1, diameters.count - 1)
            return diameters[lo] + (h - Double(lo)) * (diameters[hi] - diameters[lo])
        }

        // Use the app's canonical median (proper even-count averaging) rather
        // than a nearest-rank estimate, so the report agrees with the on-screen
        // and CSV medians.
        let median: Double? = diameters.isEmpty ? nil : Statistics.median(diameters)
        let mean: Double? = diameters.isEmpty ? nil : diameters.reduce(0, +) / Double(n)
        let sd: Double? = {
            guard let m = mean, diameters.count > 1 else { return nil }
            let v = diameters.reduce(0) { $0 + ($1 - m) * ($1 - m) } / Double(diameters.count)
            return v.squareRoot()
        }()
        let q1 = quantile(0.25)
        let q3 = quantile(0.75)

        // Bin counts
        var counts: [Int] = Array(repeating: 0, count: BinMath.bins(from: thresholds).count)
        for c in cells {
            let idx = BinMath.binIndex(for: c.diameter, thresholds: thresholds)
            let clamped = max(0, min(idx, counts.count - 1))
            counts[clamped] += 1
        }
        let bins = BinMath.bins(from: thresholds)
        var binPairs: [(label: String, count: Int)] = []
        for (i, b) in bins.enumerated() {
            binPairs.append((label: b.label, count: i < counts.count ? counts[i] : 0))
        }

        // F1 vs ground-truth annotations — computed with the app's canonical
        // matcher (same as the on-screen ground-truth panel) so the report is
        // complete when the user has labeled the image. `evaluate` returns a
        // nil F1 when there are no annotations, so the section self-omits.
        let annotations = state.repos.annotations(for: image.id)
        let f1 = AnnotationMatcher.evaluate(annotations: annotations,
                                            detections: cells,
                                            matchRadiusFactor: 1.0).f1

        // Image stats
        let stats = image.detection?.imageStats ?? [:]
        let nColonies: Int? = stats["n_colonies"].map { Int($0.rounded()) }
        let confluency = stats["confluency_pct"]
        let meanColony = stats["mean_colony_size_cells"]
        let largestColony: Int? = stats["largest_colony_size_cells"].map { Int($0.rounded()) }
        let focus = stats["focus_score"]
        let illum = stats["illumination_residual"]

        return ReportSnapshot(
            fileName: image.fileName,
            dateISO: dateStr,
            appVersion: appVersion,
            modelName: state.activeModelName,
            pxPerUm: pxPerUm,
            confidence: cutoff,
            thresholds: thresholds,
            nCells: n,
            medianDiameter: median,
            meanDiameter: mean,
            sdDiameter: sd,
            iqrLow: q1,
            iqrHigh: q3,
            binCounts: binPairs,
            totalForPct: max(1, n),
            nColonies: nColonies,
            confluencyPct: confluency,
            meanColonySize: meanColony,
            largestColony: largestColony,
            focusScore: focus,
            illuminationResidual: illum,
            f1: f1,
            calibrationSource: (image.batch ?? state.currentBatch)?.pxPerUmSource ?? "manual",
            provenance: ProvenanceMetadata.capture(for: image, state: state)
        )
    }
}
