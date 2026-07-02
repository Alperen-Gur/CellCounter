import Foundation
import AppKit
import CoreGraphics
import ImageIO
import PDFKit
import SwiftUI
import UniformTypeIdentifiers

/// Pass-17: 1-page (occasionally 2-page) PDF lab-journal report.
///
/// Layout (A4 portrait at 144 dpi -> 1190 × 1684 px):
///   - Header band: title block (file · date · model · version)
///   - Left ~52% column: annotated image
///   - Right ~48% column: counts + bin histogram + bin table + colony stats
///     + QC + (optional) F1 vs ground truth.
///   - Footer: timestamp, app version, calibration source.
///
/// Render path: a standalone SwiftUI view (`PDFReportPage`) is composed and
/// passed through `ImageRenderer.render(rasterizationScale:)` into a CGContext
/// backing a PDFKit document. We deliberately do NOT touch the live view tree.
/// The annotated image is pre-rendered to an NSImage via the same compositing
/// primitives that `ExportService.writeAnnotatedPNG` uses so the visual style
/// matches the on-screen overlay 1:1.
enum PDFReportError: LocalizedError {
    case missingImageBitmap
    case renderFailed
    case writeFailed(Error)

    var errorDescription: String? {
        switch self {
        case .missingImageBitmap: return "Couldn't open the source image for the PDF report."
        case .renderFailed: return "Couldn't render the PDF report view."
        case .writeFailed(let e): return "Couldn't write the PDF report: \(e.localizedDescription)"
        }
    }
}

struct PDFReportGenerator {

    // A4 at 144 dpi (matches 8.27" × 11.69").
    private static let pageWidth: CGFloat = 1190
    private static let pageHeight: CGFloat = 1684

    /// Write a single-page PDF report for `image` to `url`. Synchronous; intended
    /// to be called from a background queue (the sample-folder orchestrator
    /// runs all writers serially off the main actor where possible).
    /// `annotations` is reserved for Lane B — when nil, the F1 row is omitted.
    static func writeReport(image: ImageRecord,
                            state: AppState,
                            annotations: Any? = nil,
                            to url: URL) throws {
        // Snapshot the values we need so we don't have to touch AppState from
        // any background context.
        let snapshot = ReportSnapshot.make(image: image, state: state)

        // Pre-render the annotated image bitmap (shared style with PNG export).
        let annotated = try renderAnnotatedNSImage(image: image,
                                                    detection: image.detection,
                                                    thresholds: snapshot.thresholds,
                                                    pxPerUm: snapshot.pxPerUm,
                                                    confidence: snapshot.confidence)

        let view = PDFReportPage(snapshot: snapshot, annotated: annotated)
            .frame(width: pageWidth, height: pageHeight)
            .environment(\.colorScheme, .light)

        // Render the SwiftUI view to a CGImage at the page resolution. We then
        // draw that image into a PDF context so PDFKit can finalize the file.
        guard let cgImage = renderViewToCGImage(view: view,
                                                 size: CGSize(width: pageWidth, height: pageHeight)) else {
            throw PDFReportError.renderFailed
        }

        var mediaBox = CGRect(x: 0, y: 0, width: pageWidth, height: pageHeight)
        guard let pdfData = CFDataCreateMutable(nil, 0),
              let consumer = CGDataConsumer(data: pdfData),
              let pdfCtx = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            throw PDFReportError.renderFailed
        }
        pdfCtx.beginPDFPage(nil)
        pdfCtx.draw(cgImage, in: mediaBox)
        pdfCtx.endPDFPage()
        pdfCtx.closePDF()

        do {
            try (pdfData as Data).write(to: url, options: [.atomic])
        } catch {
            throw PDFReportError.writeFailed(error)
        }
    }

    // MARK: — SwiftUI → CGImage

    private static func renderViewToCGImage<V: View>(view: V, size: CGSize) -> CGImage? {
        let renderer = ImageRenderer(content: view)
        renderer.proposedSize = ProposedViewSize(size)
        renderer.scale = 1.0
        return renderer.cgImage
    }

    // MARK: — Annotated overlay (shared style with writeAnnotatedPNG)

    /// Renders the annotated overlay into an NSImage. Mirrors the bitmap
    /// compositing inside `ExportService.writeAnnotatedPNG` so the PDF report's
    /// embedded image is visually identical to the standalone `annotated.png`.
    static func renderAnnotatedNSImage(image: ImageRecord,
                                        detection: DetectionRecord?,
                                        thresholds: [Double],
                                        pxPerUm: Double,
                                        confidence: Double) throws -> NSImage {
        guard let loaded = ImageLoader.loadStored(image) else {
            throw PDFReportError.missingImageBitmap
        }
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

        if let det = detection {
            ctx.saveGState()
            ctx.translateBy(x: 0, y: CGFloat(h))
            ctx.scaleBy(x: 1, y: -1)
            let lineWidth = max(1.5, CGFloat(min(w, h)) * 0.0025)
            ctx.setLineWidth(lineWidth)
            ctx.setLineJoin(.round)
            let cells = det.cells.filter { $0.confidence >= confidence }
            for cell in cells {
                let idx = BinMath.binIndex(for: cell.diameter, thresholds: thresholds)
                let color = binCGColor(idx)
                ctx.setStrokeColor(color)
                let fill = color.copy(alpha: 0.18) ?? color
                ctx.setFillColor(fill)
                let r = cell.diameterPx / 2
                let rect = CGRect(x: cell.cx - r, y: cell.cy - r,
                                   width: cell.diameterPx, height: cell.diameterPx)
                ctx.fillEllipse(in: rect)
                ctx.strokeEllipse(in: rect)
            }
            ctx.restoreGState()
        }

        guard let outImage = ctx.makeImage() else {
            throw PDFReportError.renderFailed
        }
        return NSImage(cgImage: outImage, size: NSSize(width: w, height: h))
    }

    /// OKLCH values copied from `ExportService.binCGColor` so visual style matches.
    private static let binOKLCH: [(l: Double, c: Double, h: Double)] = [
        (0.45, 0.14, 280),
        (0.58, 0.13, 230),
        (0.68, 0.11, 180),
        (0.78, 0.13, 105),
        (0.82, 0.16,  60),
    ]
    private static func binCGColor(_ index: Int) -> CGColor {
        let i = max(0, min(index, binOKLCH.count - 1))
        let v = binOKLCH[i]
        let s = OKLCH(v.l, v.c, v.h).srgb
        return CGColor(red: CGFloat(s.r), green: CGFloat(s.g), blue: CGFloat(s.b), alpha: 1)
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

    // Pass-18 (Lane R): provenance block — surfaced as a 3-line monospaced
    // footer at the bottom of the PDF so the page is self-describing.
    let provenance: ProvenanceMetadata?

    static func make(image: ImageRecord, state: AppState) -> ReportSnapshot {
        let isoFmt = ISO8601DateFormatter()
        isoFmt.formatOptions = [.withInternetDateTime]
        let dateStr = isoFmt.string(from: Date())

        let appVersion: String = {
            let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
            return v
        }()

        let cutoff = state.effectiveConfidence(for: image)
        let cells: [DetectedCell] = (image.detection?.cells ?? []).filter { $0.confidence >= cutoff }
        let diameters = cells.map(\.diameter).sorted()
        let n = diameters.count

        func percentile(_ p: Double) -> Double? {
            guard !diameters.isEmpty else { return nil }
            let idx = max(0, min(diameters.count - 1, Int((p * Double(diameters.count - 1)).rounded())))
            return diameters[idx]
        }

        let median = percentile(0.5)
        let mean: Double? = diameters.isEmpty ? nil : diameters.reduce(0, +) / Double(n)
        let sd: Double? = {
            guard let m = mean, diameters.count > 1 else { return nil }
            let v = diameters.reduce(0) { $0 + ($1 - m) * ($1 - m) } / Double(diameters.count)
            return v.squareRoot()
        }()
        let q1 = percentile(0.25)
        let q3 = percentile(0.75)

        // Bin counts
        var counts: [Int] = Array(repeating: 0, count: BinMath.bins(from: state.thresholds).count)
        for c in cells {
            let idx = BinMath.binIndex(for: c.diameter, thresholds: state.thresholds)
            let clamped = max(0, min(idx, counts.count - 1))
            counts[clamped] += 1
        }
        let bins = BinMath.bins(from: state.thresholds)
        var binPairs: [(label: String, count: Int)] = []
        for (i, b) in bins.enumerated() {
            binPairs.append((label: b.label, count: i < counts.count ? counts[i] : 0))
        }

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
            pxPerUm: state.pxPerUm,
            confidence: cutoff,
            thresholds: state.thresholds,
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
            f1: nil,
            calibrationSource: (image.batch ?? state.currentBatch)?.pxPerUmSource ?? "manual",
            provenance: ProvenanceMetadata.capture(for: image, state: state)
        )
    }
}

// MARK: — Report page (SwiftUI, used only for rendering)

private struct PDFReportPage: View {
    let snapshot: ReportSnapshot
    let annotated: NSImage

    private let bg = Color.white
    private let ink = Color(red: 0.10, green: 0.10, blue: 0.12)
    private let inkSecondary = Color(red: 0.35, green: 0.35, blue: 0.40)
    private let divider = Color(red: 0.86, green: 0.86, blue: 0.88)
    private let accent = Color(red: 0.20, green: 0.45, blue: 0.85)

    var body: some View {
        ZStack {
            bg.ignoresSafeArea()
            VStack(alignment: .leading, spacing: 0) {
                header
                Rectangle().fill(divider).frame(height: 1).padding(.vertical, 12)
                HStack(alignment: .top, spacing: 24) {
                    leftColumn
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                    rightColumn
                        .frame(width: 480, alignment: .topLeading)
                }
                Spacer(minLength: 0)
                Rectangle().fill(divider).frame(height: 1).padding(.top, 8)
                footer
            }
            .padding(48)
        }
        .frame(width: 1190, height: 1684)
        .foregroundStyle(ink)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("CellCounter analysis report")
                .font(.system(size: 26, weight: .bold))
            HStack(spacing: 16) {
                LabelKV(k: "File",  v: snapshot.fileName)
                LabelKV(k: "Date",  v: snapshot.dateISO)
            }
            HStack(spacing: 16) {
                LabelKV(k: "Model", v: snapshot.modelName)
                LabelKV(k: "Version", v: snapshot.appVersion)
            }
        }
    }

    private var leftColumn: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionTitle("Annotated image")
            Image(nsImage: annotated)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: .infinity, maxHeight: 1280, alignment: .top)
                .background(Color.black.opacity(0.04))
                .overlay(
                    Rectangle().stroke(divider, lineWidth: 1)
                )
        }
    }

    private var rightColumn: some View {
        VStack(alignment: .leading, spacing: 18) {
            countSummarySection
            histogramSection
            binTableSection
            colonySection
            qcSection
            if let f1 = snapshot.f1 {
                SectionTitle("Ground truth")
                Text(String(format: "F1 vs annotations: %.3f", f1))
                    .font(.system(size: 13))
            }
        }
    }

    private var countSummarySection: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionTitle("Count summary")
            Text("\(snapshot.nCells) cells detected")
                .font(.system(size: 18, weight: .semibold))
            if let med = snapshot.medianDiameter {
                let parts: [String] = [
                    String(format: "median %.1f µm", med),
                    snapshot.meanDiameter.map { String(format: "mean %.1f µm", $0) } ?? "",
                    snapshot.sdDiameter.map { String(format: "σ %.1f µm", $0) } ?? "",
                ].filter { !$0.isEmpty }
                Text(parts.joined(separator: " · "))
                    .font(.system(size: 12))
                    .foregroundStyle(inkSecondary)
            }
            if let lo = snapshot.iqrLow, let hi = snapshot.iqrHigh {
                Text(String(format: "IQR: %.1f – %.1f µm", lo, hi))
                    .font(.system(size: 12))
                    .foregroundStyle(inkSecondary)
            }
        }
    }

    private var histogramSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionTitle("Size bin distribution")
            HistogramCanvas(bins: snapshot.binCounts)
                .frame(height: 110)
                .frame(maxWidth: .infinity)
                .overlay(Rectangle().stroke(divider, lineWidth: 1))
        }
    }

    private var binTableSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(snapshot.binCounts.enumerated()), id: \.offset) { idx, entry in
                HStack {
                    Circle()
                        .fill(swiftUIBinColor(idx))
                        .frame(width: 10, height: 10)
                    Text(entry.label)
                        .font(.system(size: 12))
                    Spacer()
                    let pct = 100.0 * Double(entry.count) / Double(snapshot.totalForPct)
                    Text("\(entry.count) (\(String(format: "%.1f", pct))%)")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(inkSecondary)
                }
            }
        }
    }

    private var colonySection: some View {
        VStack(alignment: .leading, spacing: 4) {
            SectionTitle("Colonies")
            if let n = snapshot.nColonies, let conf = snapshot.confluencyPct {
                Text("\(n) colonies · \(String(format: "%.1f", conf))% confluency")
                    .font(.system(size: 13, weight: .medium))
                let extras: [String] = [
                    snapshot.meanColonySize.map { String(format: "mean %.1f cells/colony", $0) } ?? "",
                    snapshot.largestColony.map { "largest \($0) cells" } ?? "",
                ].filter { !$0.isEmpty }
                if !extras.isEmpty {
                    Text(extras.joined(separator: " · "))
                        .font(.system(size: 11))
                        .foregroundStyle(inkSecondary)
                }
            } else {
                Text("No colony data recorded.")
                    .font(.system(size: 12))
                    .foregroundStyle(inkSecondary)
            }
        }
    }

    private var qcSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            SectionTitle("QC scores")
            HStack(spacing: 24) {
                qcRow(label: "Focus", value: snapshot.focusScore, fmt: "%.3f")
                qcRow(label: "Illumination residual", value: snapshot.illuminationResidual, fmt: "%.3f")
            }
        }
    }

    private func qcRow(label: String, value: Double?, fmt: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.system(size: 10)).foregroundStyle(inkSecondary)
            Text(value.map { String(format: fmt, $0) } ?? "—")
                .font(.system(size: 14, weight: .semibold))
        }
    }

    private var footer: some View {
        // Pass-18 (Lane R): three monospaced provenance lines. When provenance
        // is missing (e.g. unit-test path), fall back to the legacy one-row
        // footer so the PDF still renders.
        VStack(alignment: .leading, spacing: 2) {
            if let prov = snapshot.provenance {
                ForEach(Array(Self.provenanceFooterLines(prov).enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .font(.system(size: 9, weight: .regular, design: .monospaced))
                        .foregroundStyle(Color(red: 0.55, green: 0.55, blue: 0.60))
                }
            } else {
                HStack {
                    Text(snapshot.dateISO).font(.system(size: 10)).foregroundStyle(inkSecondary)
                    Spacer()
                    Text("CellCounter v\(snapshot.appVersion)")
                        .font(.system(size: 10)).foregroundStyle(inkSecondary)
                    Spacer()
                    Text("Calibration: \(snapshot.calibrationSource) · \(String(format: "%.3f px/µm", snapshot.pxPerUm))")
                        .font(.system(size: 10)).foregroundStyle(inkSecondary)
                }
            }
        }
    }

    /// Compose the three monospaced footer lines from a provenance block.
    /// Nil-valued tokens are omitted cleanly so the lines stay tidy when e.g.
    /// the git SHA or weights hash isn't available.
    static func provenanceFooterLines(_ p: ProvenanceMetadata) -> [String] {
        // Line 1: generated by CellCounter <version> [(<sha>)] · <model> [@ <hash[..8]>]
        var line1 = "generated by CellCounter \(p.appVersion)"
        if let sha = p.appBuildSHA { line1 += " (\(sha))" }
        line1 += " · \(p.modelName)"
        if let wh = p.weightsHash {
            line1 += " @ \(String(wh.prefix(8)))"
        }
        // Line 2: detector: <library>@<version> · macOS <osversion>
        var line2 = "detector: \(p.modelFamily)"
        if let dv = p.detectorVersion { line2 += "@\(dv)" }
        line2 += " · \(p.osVersion)"
        // Line 3: calibration: <pxPerUm> px/µm (<source>)
        let line3 = String(format: "calibration: %.4g px/µm (%@)", p.pxPerUm, p.pxPerUmSource)
        return [line1, line2, line3]
    }

    private func swiftUIBinColor(_ idx: Int) -> Color {
        let palette: [(Double, Double, Double)] = [
            (0.30, 0.20, 0.55),
            (0.25, 0.45, 0.70),
            (0.30, 0.65, 0.65),
            (0.85, 0.75, 0.30),
            (0.95, 0.60, 0.25),
        ]
        let i = max(0, min(idx, palette.count - 1))
        let p = palette[i]
        return Color(red: p.0, green: p.1, blue: p.2)
    }
}

private struct SectionTitle: View {
    let title: String
    init(_ t: String) { self.title = t }
    var body: some View {
        Text(title.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(Color(red: 0.35, green: 0.35, blue: 0.40))
            .tracking(1.2)
    }
}

private struct LabelKV: View {
    let k: String
    let v: String
    var body: some View {
        HStack(spacing: 4) {
            Text("\(k):")
                .font(.system(size: 11))
                .foregroundStyle(Color(red: 0.35, green: 0.35, blue: 0.40))
            Text(v)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
        }
    }
}

private struct HistogramCanvas: View {
    let bins: [(label: String, count: Int)]
    var body: some View {
        Canvas { ctx, size in
            let maxV = max(bins.map(\.count).max() ?? 1, 1)
            let barCount = max(1, bins.count)
            let gap: CGFloat = 6
            let totalGap = gap * CGFloat(max(0, barCount - 1))
            let barW = max(2, (size.width - totalGap - 16) / CGFloat(barCount))
            let palette: [(Double, Double, Double)] = [
                (0.30, 0.20, 0.55),
                (0.25, 0.45, 0.70),
                (0.30, 0.65, 0.65),
                (0.85, 0.75, 0.30),
                (0.95, 0.60, 0.25),
            ]
            for (i, b) in bins.enumerated() {
                let frac = CGFloat(b.count) / CGFloat(maxV)
                let h = max(1, (size.height - 22) * frac)
                let x = 8 + CGFloat(i) * (barW + gap)
                let y = size.height - 18 - h
                let p = palette[min(i, palette.count - 1)]
                let color = Color(red: p.0, green: p.1, blue: p.2)
                ctx.fill(Path(CGRect(x: x, y: y, width: barW, height: h)),
                          with: .color(color))
                // count label above bar
                let countText = Text("\(b.count)")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(Color(red: 0.25, green: 0.25, blue: 0.30))
                ctx.draw(countText, at: CGPoint(x: x + barW / 2, y: y - 6), anchor: .bottom)
            }
        }
    }
}
