//! export/report.rs — PDF report generator (feature `export`).
//!
//! Port of `Services/PDFReportGenerator.swift`. Produces a single-page A4 PDF
//! lab-journal report whose *content* mirrors the Swift layout:
//!   - Header band: title + File / Date / Model / Version
//!   - Left column: the annotated image (cells drawn as bin-colored ellipses,
//!     same style as `ExportService.writeAnnotatedPNG`)
//!   - Right column: count summary, size-bin histogram, bin table with %,
//!     colony stats, QC scores, and (when annotations exist) F1 vs ground truth
//!   - Footer: three monospaced provenance lines
//!
//! The Swift original renders a SwiftUI view via `ImageRenderer` into a PDFKit
//! document. That path is macOS-only; here we emit a portable, self-contained
//! PDF by writing the PDF primitives directly (no external PDF crate — none is
//! in Cargo.toml, and pulling one in would touch the frozen dependency set).
//! The annotated image is decoded with the `image` crate, composited, re-encoded
//! as JPEG, and embedded as a `/DCTDecode` XObject.
//!
//! F1 note: the PDF needs the F1 number in Rust. `kernel/stats.ts.evaluateF1`
//! remains the canonical implementation for the UI; the greedy matcher here is a
//! faithful, self-contained port of `AnnotationMatcher.swift` used ONLY to stamp
//! the PDF footer number, so the report is complete without a round-trip to JS.

use std::fmt::Write as _;

use image::GenericImageView;
use rusqlite::Connection;
use tauri::{AppHandle, State};

use crate::db::models::CellDto;
use crate::db::repo::Db;
use crate::export::csv::{bin_index, bin_labels};
use crate::export::provenance::{
    fmt_g, open_reader, resolve_out_path, ExportContext, Provenance,
};
use crate::paths::FileStore;

// A4 at 144 dpi (matches the Swift `pageWidth`/`pageHeight`): 1190 × 1684.
const PAGE_W: f64 = 1190.0;
const PAGE_H: f64 = 1684.0;
const MARGIN: f64 = 48.0;

// ---------------------------------------------------------------------------
// OKLCH → sRGB (port of Theme/Tokens.swift bin palette used by the exporters)
// ---------------------------------------------------------------------------

/// The five bin colors, as OKLCH (L, C, Hdeg) — copied verbatim from
/// `ExportService.binOKLCH` / `PDFReportGenerator.binOKLCH`.
const BIN_OKLCH: [(f64, f64, f64); 5] = [
    (0.45, 0.14, 280.0),
    (0.58, 0.13, 230.0),
    (0.68, 0.11, 180.0),
    (0.78, 0.13, 105.0),
    (0.82, 0.16, 60.0),
];

/// Convert OKLCH → linear sRGB → gamma-encoded sRGB in [0,1]. Standard OKLab
/// matrices (Björn Ottosson). Values are clamped to [0,1].
fn oklch_to_srgb(l: f64, c: f64, h_deg: f64) -> (f64, f64, f64) {
    let h = h_deg.to_radians();
    let a = c * h.cos();
    let b = c * h.sin();

    // OKLab → LMS'
    let l_ = l + 0.3963377774 * a + 0.2158037573 * b;
    let m_ = l - 0.1055613458 * a - 0.0638541728 * b;
    let s_ = l - 0.0894841775 * a - 1.2914855480 * b;

    let l3 = l_ * l_ * l_;
    let m3 = m_ * m_ * m_;
    let s3 = s_ * s_ * s_;

    // LMS → linear sRGB
    let r = 4.0767416621 * l3 - 3.3077115913 * m3 + 0.2309699292 * s3;
    let g = -1.2684380046 * l3 + 2.6097574011 * m3 - 0.3413193965 * s3;
    let bl = -0.0041960863 * l3 - 0.7034186147 * m3 + 1.7076147010 * s3;

    (gamma(r), gamma(g), gamma(bl))
}

fn gamma(x: f64) -> f64 {
    let x = x.clamp(0.0, 1.0);
    if x <= 0.0031308 {
        (12.92 * x).clamp(0.0, 1.0)
    } else {
        (1.055 * x.powf(1.0 / 2.4) - 0.055).clamp(0.0, 1.0)
    }
}

/// Bin color as 8-bit RGB for image compositing.
fn bin_rgb8(index: usize) -> (u8, u8, u8) {
    let i = index.min(BIN_OKLCH.len() - 1);
    let (l, c, h) = BIN_OKLCH[i];
    let (r, g, b) = oklch_to_srgb(l, c, h);
    (
        (r * 255.0).round() as u8,
        (g * 255.0).round() as u8,
        (b * 255.0).round() as u8,
    )
}

/// Bin color as PDF `r g b` (0..1) tokens for vector drawing (histogram/table).
fn bin_pdf_rgb(index: usize) -> (f64, f64, f64) {
    let i = index.min(BIN_OKLCH.len() - 1);
    let (l, c, h) = BIN_OKLCH[i];
    oklch_to_srgb(l, c, h)
}

// ---------------------------------------------------------------------------
// Report snapshot (port of ReportSnapshot.make)
// ---------------------------------------------------------------------------

struct ReportSnapshot {
    file_name: String,
    date_iso: String,
    app_version: String,
    model_name: String,

    n_cells: usize,
    median_diameter: Option<f64>,
    mean_diameter: Option<f64>,
    sd_diameter: Option<f64>,
    iqr_low: Option<f64>,
    iqr_high: Option<f64>,

    bin_labels: Vec<String>,
    bin_counts: Vec<usize>,
    total_for_pct: usize,

    n_colonies: Option<i64>,
    confluency_pct: Option<f64>,
    mean_colony_size: Option<f64>,
    largest_colony: Option<i64>,
    focus_score: Option<f64>,
    illumination_residual: Option<f64>,

    f1: Option<f64>,
}

impl ReportSnapshot {
    fn make(ctx: &ExportContext, cutoff: f64, f1: Option<f64>) -> Self {
        let visible: Vec<&CellDto> = ctx.visible_cells(cutoff);
        let mut diameters: Vec<f64> = visible.iter().map(|c| c.diameter_um).collect();
        diameters.sort_by(|a, b| a.partial_cmp(b).unwrap_or(std::cmp::Ordering::Equal));
        let n = diameters.len();

        let percentile = |p: f64| -> Option<f64> {
            if diameters.is_empty() {
                return None;
            }
            let idx = ((p * (diameters.len() as f64 - 1.0)).round() as isize)
                .clamp(0, diameters.len() as isize - 1) as usize;
            Some(diameters[idx])
        };
        let median = percentile(0.5);
        let mean = if diameters.is_empty() {
            None
        } else {
            Some(diameters.iter().sum::<f64>() / n as f64)
        };
        let sd = match mean {
            Some(m) if diameters.len() > 1 => {
                let v = diameters.iter().map(|d| (d - m) * (d - m)).sum::<f64>()
                    / diameters.len() as f64;
                Some(v.sqrt())
            }
            _ => None,
        };
        let q1 = percentile(0.25);
        let q3 = percentile(0.75);

        // Bin counts aligned to the label ladder.
        let labels = bin_labels(&ctx.thresholds);
        let mut counts = vec![0usize; labels.len()];
        for c in &visible {
            let idx = bin_index(c.diameter_um, &ctx.thresholds).min(counts.len().saturating_sub(1));
            counts[idx] += 1;
        }

        let stats = &ctx.image_stats;
        let f = |k: &str| stats.get(k).copied();
        let fi = |k: &str| stats.get(k).map(|v| v.round() as i64);

        ReportSnapshot {
            file_name: ctx.file_name.clone(),
            date_iso: crate::db::repo::now_iso8601(),
            app_version: crate::export::provenance::APP_VERSION.to_string(),
            model_name: model_display_name(&ctx.model_id),
            n_cells: n,
            median_diameter: median,
            mean_diameter: mean,
            sd_diameter: sd,
            iqr_low: q1,
            iqr_high: q3,
            bin_labels: labels,
            bin_counts: counts,
            total_for_pct: n.max(1),
            n_colonies: fi("n_colonies"),
            confluency_pct: f("confluency_pct"),
            mean_colony_size: f("mean_colony_size_cells"),
            largest_colony: fi("largest_colony_size_cells"),
            focus_score: f("focus_score"),
            illumination_residual: f("illumination_residual"),
            f1,
        }
    }
}

/// Friendly model name for the header (mirrors `state.activeModelName` for v1).
fn model_display_name(model_id: &str) -> String {
    match model_id {
        "cp-cyto3" => "Cellpose cyto3".to_string(),
        other => other.to_string(),
    }
}

// ---------------------------------------------------------------------------
// F1 (port of AnnotationMatcher.swift greedy nearest-neighbour matcher)
// ---------------------------------------------------------------------------

struct GtPoint {
    cx: f64,
    cy: f64,
}

/// Greedy nearest-neighbour F1 in SOURCE-PIXEL space. A candidate links
/// ann↔det iff `dist ≤ matchRadiusFactor * max(det.diameterPx, 1)`. Candidates
/// sorted ascending; each ann/det claimed at most once. Returns `f1` (None when
/// there are no annotations). Port of `evaluateF1` / `AnnotationMatcher`.
fn evaluate_f1(annotations: &[GtPoint], detections: &[&CellDto], match_radius_factor: f64) -> Option<f64> {
    if annotations.is_empty() {
        return None;
    }
    // Build all admissible candidate pairs with their distance.
    struct Cand {
        ann: usize,
        det: usize,
        dist: f64,
    }
    let mut cands: Vec<Cand> = Vec::new();
    for (ai, a) in annotations.iter().enumerate() {
        for (di, d) in detections.iter().enumerate() {
            let radius = match_radius_factor * d.diameter_px.max(1.0);
            let dx = a.cx - d.cx;
            let dy = a.cy - d.cy;
            let dist = (dx * dx + dy * dy).sqrt();
            if dist <= radius {
                cands.push(Cand {
                    ann: ai,
                    det: di,
                    dist,
                });
            }
        }
    }
    cands.sort_by(|x, y| x.dist.partial_cmp(&y.dist).unwrap_or(std::cmp::Ordering::Equal));

    let mut ann_used = vec![false; annotations.len()];
    let mut det_used = vec![false; detections.len()];
    let mut tp = 0usize;
    for c in &cands {
        if !ann_used[c.ann] && !det_used[c.det] {
            ann_used[c.ann] = true;
            det_used[c.det] = true;
            tp += 1;
        }
    }
    let fp = detections.len() - tp;
    let fn_ = annotations.len() - tp;
    let precision = if tp + fp > 0 {
        tp as f64 / (tp + fp) as f64
    } else {
        0.0
    };
    let recall = if tp + fn_ > 0 {
        tp as f64 / (tp + fn_) as f64
    } else {
        0.0
    };
    if precision + recall > 0.0 {
        Some(2.0 * precision * recall / (precision + recall))
    } else {
        Some(0.0)
    }
}

/// Load ground-truth annotations for an image (px coords only — enough for F1).
fn load_annotations(conn: &Connection, image_id: &str) -> Vec<GtPoint> {
    let mut stmt = match conn.prepare(
        "SELECT cx, cy FROM ground_truth_annotations WHERE image_id = ?1 ORDER BY created_at",
    ) {
        Ok(s) => s,
        Err(_) => return Vec::new(),
    };
    stmt.query_map([image_id], |r| {
        Ok(GtPoint {
            cx: r.get::<_, f64>(0)?,
            cy: r.get::<_, f64>(1)?,
        })
    })
    .and_then(|rows| rows.collect::<rusqlite::Result<Vec<_>>>())
    .unwrap_or_default()
}

// ===========================================================================
// COMMAND: export_pdf_report
// ===========================================================================

/// Render a single-page PDF report for `image_id` to `out_path` (a bare
/// filename lands under `Exports/`). Returns the absolute written path.
#[tauri::command]
pub async fn export_pdf_report(
    app: AppHandle,
    db: State<'_, Db>,
    image_id: String,
    confidence: Option<f64>,
    out_path: String,
) -> Result<String, String> {
    let _ = &db;
    let store = FileStore::from_app(&app)?;
    let conn = open_reader(&store)?;
    let ctx = ExportContext::load(&conn, &store, &image_id)?;

    // Per-image override wins over the supplied global slider; else app default.
    let global = confidence.unwrap_or(0.5);
    let cutoff = ctx.effective_confidence(global);

    // F1 vs ground truth (omitted when no annotations).
    let annotations = load_annotations(&conn, &image_id);
    let visible: Vec<&CellDto> = ctx.visible_cells(cutoff);
    let f1 = evaluate_f1(&annotations, &visible, 1.0);

    let snapshot = ReportSnapshot::make(&ctx, cutoff, f1);
    let provenance = Provenance::capture(&ctx, cutoff);

    // Pre-render the annotated image as JPEG bytes (+ dims) for embedding.
    let annotated = render_annotated_jpeg(&ctx, cutoff);

    let pdf = build_pdf(&snapshot, &provenance, annotated);

    let resolved = resolve_out_path(&store, &out_path)?;
    std::fs::write(&resolved, pdf).map_err(|e| format!("could not write report.pdf: {e}"))?;
    Ok(resolved.to_string_lossy().into_owned())
}

// ---------------------------------------------------------------------------
// Annotated image compositing (shared style with writeAnnotatedPNG)
// ---------------------------------------------------------------------------

struct AnnotatedJpeg {
    bytes: Vec<u8>,
    width: u32,
    height: u32,
}

/// Decode the stored image, draw each visible cell as a bin-colored, faintly
/// filled ellipse (matching `writeAnnotatedPNG` outline mode), and re-encode as
/// JPEG. Returns `None` when the image can't be decoded (the PDF then omits the
/// image panel rather than failing the whole report).
fn render_annotated_jpeg(ctx: &ExportContext, cutoff: f64) -> Option<AnnotatedJpeg> {
    let img = image::open(&ctx.stored_path).ok()?;
    let (w, h) = img.dimensions();
    let mut rgb = img.to_rgb8();

    // Route through `visible_cells` so the on-screen/overlay visibility rule
    // (confidence >= cutoff) lives in exactly one place.
    for cell in ctx.visible_cells(cutoff) {
        let idx = bin_index(cell.diameter_um, &ctx.thresholds);
        let (cr, cg, cb) = bin_rgb8(idx);
        let r = (cell.diameter_px / 2.0).max(1.0);
        draw_ellipse(&mut rgb, cell.cx, cell.cy, r, (cr, cg, cb));
    }

    // Encode JPEG. `DynamicImage::write_to(.., ImageFormat::Jpeg)` is the
    // version-stable encode path (0.24/0.25) and produces a `/DCTDecode`-ready
    // stream. Report image is illustrative, so default quality is fine.
    let mut bytes: Vec<u8> = Vec::new();
    let mut cursor = std::io::Cursor::new(&mut bytes);
    image::DynamicImage::ImageRgb8(rgb)
        .write_to(&mut cursor, image::ImageFormat::Jpeg)
        .ok()?;

    Some(AnnotatedJpeg {
        bytes,
        width: w,
        height: h,
    })
}

/// Draw a filled (α≈0.18) + stroked ellipse of `color` centered at (cx,cy) with
/// radius `r` onto an RGB buffer. A lightweight rasterization — the report image
/// is illustrative, so we approximate the Swift CoreGraphics stroke/fill with a
/// filled disc blended at low alpha plus a ring for the outline.
fn draw_ellipse(
    buf: &mut image::RgbImage,
    cx: f64,
    cy: f64,
    r: f64,
    color: (u8, u8, u8),
) {
    let (w, hgt) = (buf.width() as i64, buf.height() as i64);
    let r_out = r;
    let r_in = (r - r.max(2.0) * 0.14).max(0.0); // ring thickness ~ line width
    let x0 = ((cx - r_out).floor() as i64).max(0);
    let x1 = ((cx + r_out).ceil() as i64).min(w - 1);
    let y0 = ((cy - r_out).floor() as i64).max(0);
    let y1 = ((cy + r_out).ceil() as i64).min(hgt - 1);
    if x1 < x0 || y1 < y0 {
        return;
    }
    let r_out2 = r_out * r_out;
    let r_in2 = r_in * r_in;
    for py in y0..=y1 {
        for px in x0..=x1 {
            let dx = px as f64 + 0.5 - cx;
            let dy = py as f64 + 0.5 - cy;
            let d2 = dx * dx + dy * dy;
            if d2 <= r_out2 {
                let pixel = buf.get_pixel_mut(px as u32, py as u32);
                if d2 >= r_in2 {
                    // Outline ring: opaque stroke.
                    pixel[0] = color.0;
                    pixel[1] = color.1;
                    pixel[2] = color.2;
                } else {
                    // Interior: faint fill (blend ~18%).
                    blend(pixel, color, 0.18);
                }
            }
        }
    }
}

fn blend(pixel: &mut image::Rgb<u8>, color: (u8, u8, u8), alpha: f64) {
    let inv = 1.0 - alpha;
    pixel[0] = (pixel[0] as f64 * inv + color.0 as f64 * alpha).round() as u8;
    pixel[1] = (pixel[1] as f64 * inv + color.1 as f64 * alpha).round() as u8;
    pixel[2] = (pixel[2] as f64 * inv + color.2 as f64 * alpha).round() as u8;
}

// ---------------------------------------------------------------------------
// Minimal PDF writer
// ---------------------------------------------------------------------------

/// A PDF content-stream builder in PDF *user space* (origin bottom-left). We draw
/// with a top-left mental model and flip Y at emit time via `ty()`.
#[derive(Default)]
struct Content {
    ops: String,
}

impl Content {
    fn ty(y: f64) -> f64 {
        PAGE_H - y
    }

    /// Filled rectangle (top-left x,y in top-down coords; w,h in px).
    fn rect_fill(&mut self, x: f64, y: f64, w: f64, h: f64, rgb: (f64, f64, f64)) {
        let _ = write!(
            self.ops,
            "{:.3} {:.3} {:.3} rg\n{:.2} {:.2} {:.2} {:.2} re f\n",
            rgb.0,
            rgb.1,
            rgb.2,
            x,
            Self::ty(y + h),
            w,
            h
        );
    }

    /// Stroked rectangle outline.
    fn rect_stroke(&mut self, x: f64, y: f64, w: f64, h: f64, rgb: (f64, f64, f64), lw: f64) {
        let _ = write!(
            self.ops,
            "{:.3} {:.3} {:.3} RG\n{:.2} w\n{:.2} {:.2} {:.2} {:.2} re S\n",
            rgb.0,
            rgb.1,
            rgb.2,
            lw,
            x,
            Self::ty(y + h),
            w,
            h
        );
    }

    /// A horizontal divider line.
    fn hline(&mut self, x0: f64, x1: f64, y: f64, rgb: (f64, f64, f64), lw: f64) {
        let _ = write!(
            self.ops,
            "{:.3} {:.3} {:.3} RG\n{:.2} w\n{:.2} {:.2} m {:.2} {:.2} l S\n",
            rgb.0,
            rgb.1,
            rgb.2,
            lw,
            x0,
            Self::ty(y),
            x1,
            Self::ty(y)
        );
    }

    /// Text at (x,y) top-down baseline-ish; `font` is the resource name (F1
    /// Helvetica, F2 Helvetica-Bold, F3 Courier).
    fn text(&mut self, x: f64, y: f64, size: f64, font: &str, rgb: (f64, f64, f64), s: &str) {
        let _ = write!(
            self.ops,
            "BT\n{:.3} {:.3} {:.3} rg\n/{} {:.1} Tf\n{:.2} {:.2} Td\n({}) Tj\nET\n",
            rgb.0,
            rgb.1,
            rgb.2,
            font,
            size,
            x,
            Self::ty(y) - size,
            pdf_escape(s)
        );
    }

    /// Draw the embedded image XObject `/Im0` into the box (top-left x,y, w,h).
    fn image(&mut self, x: f64, y: f64, w: f64, h: f64) {
        let _ = write!(
            self.ops,
            "q\n{:.2} 0 0 {:.2} {:.2} {:.2} cm\n/Im0 Do\nQ\n",
            w,
            h,
            x,
            Self::ty(y + h)
        );
    }
}

/// Escape a string for a PDF literal `( … )`. Non-ASCII is dropped to stay
/// inside the WinAnsi/Standard encoding of the base-14 fonts.
fn pdf_escape(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    for ch in s.chars() {
        match ch {
            '\\' => out.push_str("\\\\"),
            '(' => out.push_str("\\("),
            ')' => out.push_str("\\)"),
            '\n' => out.push(' '),
            '\r' => {}
            c if (c as u32) < 128 => out.push(c),
            // Map the common µ to "u" so "µm" reads as "um" rather than vanishing.
            'µ' => out.push('u'),
            '±' => out.push('~'),
            '–' | '—' => out.push('-'),
            '·' => out.push('-'),
            _ => {} // drop other non-ASCII
        }
    }
    out
}

/// Colors (mirror the Swift PDFReportPage palette).
const INK: (f64, f64, f64) = (0.10, 0.10, 0.12);
const INK2: (f64, f64, f64) = (0.35, 0.35, 0.40);
const INK3: (f64, f64, f64) = (0.55, 0.55, 0.60);
const DIVIDER: (f64, f64, f64) = (0.86, 0.86, 0.88);

/// Compose the whole page content stream, then assemble the PDF file bytes.
fn build_pdf(snap: &ReportSnapshot, prov: &Provenance, annotated: Option<AnnotatedJpeg>) -> Vec<u8> {
    let mut c = Content::default();

    let content_left = MARGIN;
    let content_right = PAGE_W - MARGIN;
    let mut y = MARGIN;

    // ---- header ----
    c.text(content_left, y, 26.0, "F2", INK, "CellCounter analysis report");
    y += 34.0;
    c.text(
        content_left,
        y,
        11.0,
        "F1",
        INK2,
        &format!("File: {}    Date: {}", snap.file_name, snap.date_iso),
    );
    y += 18.0;
    c.text(
        content_left,
        y,
        11.0,
        "F1",
        INK2,
        &format!("Model: {}    Version: {}", snap.model_name, snap.app_version),
    );
    y += 20.0;
    c.hline(content_left, content_right, y, DIVIDER, 1.0);
    y += 18.0;

    // Two columns: left image (~52%), right analysis (fixed 480 like Swift).
    let right_w = 480.0;
    let col_gap = 24.0;
    let left_w = content_right - content_left - right_w - col_gap;
    let left_x = content_left;
    let right_x = content_left + left_w + col_gap;
    let columns_top = y;

    // ---- left column: annotated image ----
    c.text(left_x, columns_top, 10.0, "F2", INK2, "ANNOTATED IMAGE");
    let img_top = columns_top + 16.0;
    let img_box_h = 1180.0_f64.min(PAGE_H - img_top - 120.0);
    if let Some(a) = &annotated {
        // Fit the image into the left box preserving aspect ratio.
        let (fit_w, fit_h) = fit_box(a.width as f64, a.height as f64, left_w, img_box_h);
        c.image(left_x, img_top, fit_w, fit_h);
        c.rect_stroke(left_x, img_top, fit_w, fit_h, DIVIDER, 1.0);
    } else {
        c.rect_stroke(left_x, img_top, left_w, 200.0, DIVIDER, 1.0);
        c.text(
            left_x + 12.0,
            img_top + 24.0,
            12.0,
            "F1",
            INK2,
            "Source image unavailable.",
        );
    }

    // ---- right column ----
    let mut ry = columns_top;

    // Count summary.
    c.text(right_x, ry, 10.0, "F2", INK2, "COUNT SUMMARY");
    ry += 18.0;
    c.text(
        right_x,
        ry,
        18.0,
        "F2",
        INK,
        &format!("{} cells detected", snap.n_cells),
    );
    ry += 22.0;
    if let Some(med) = snap.median_diameter {
        let mut parts: Vec<String> = vec![format!("median {:.1} um", med)];
        if let Some(m) = snap.mean_diameter {
            parts.push(format!("mean {:.1} um", m));
        }
        if let Some(s) = snap.sd_diameter {
            parts.push(format!("sd {:.1} um", s));
        }
        c.text(right_x, ry, 12.0, "F1", INK2, &parts.join("  -  "));
        ry += 16.0;
    }
    if let (Some(lo), Some(hi)) = (snap.iqr_low, snap.iqr_high) {
        c.text(
            right_x,
            ry,
            12.0,
            "F1",
            INK2,
            &format!("IQR: {lo:.1} - {hi:.1} um"),
        );
        ry += 16.0;
    }
    ry += 8.0;

    // Histogram.
    c.text(right_x, ry, 10.0, "F2", INK2, "SIZE BIN DISTRIBUTION");
    ry += 16.0;
    let hist_h = 110.0;
    draw_histogram(&mut c, right_x, ry, right_w, hist_h, &snap.bin_counts);
    ry += hist_h + 14.0;

    // Bin table (color swatch + label + count(pct)).
    for (i, label) in snap.bin_labels.iter().enumerate() {
        let count = snap.bin_counts.get(i).copied().unwrap_or(0);
        let pct = 100.0 * count as f64 / snap.total_for_pct as f64;
        let swatch = bin_pdf_rgb(i);
        c.rect_fill(right_x, ry - 9.0, 10.0, 10.0, swatch);
        c.text(right_x + 16.0, ry, 12.0, "F1", INK, label);
        let right_txt = format!("{count} ({pct:.1}%)");
        // right-align-ish: place near the right edge.
        c.text(
            right_x + right_w - 96.0,
            ry,
            12.0,
            "F2",
            INK2,
            &right_txt,
        );
        ry += 16.0;
    }
    ry += 10.0;

    // Colonies.
    c.text(right_x, ry, 10.0, "F2", INK2, "COLONIES");
    ry += 16.0;
    if let (Some(n), Some(conf)) = (snap.n_colonies, snap.confluency_pct) {
        c.text(
            right_x,
            ry,
            13.0,
            "F2",
            INK,
            &format!("{n} colonies  -  {conf:.1}% confluency"),
        );
        ry += 16.0;
        let mut extras: Vec<String> = Vec::new();
        if let Some(m) = snap.mean_colony_size {
            extras.push(format!("mean {m:.1} cells/colony"));
        }
        if let Some(l) = snap.largest_colony {
            extras.push(format!("largest {l} cells"));
        }
        if !extras.is_empty() {
            c.text(right_x, ry, 11.0, "F1", INK2, &extras.join("  -  "));
            ry += 16.0;
        }
    } else {
        c.text(right_x, ry, 12.0, "F1", INK2, "No colony data recorded.");
        ry += 16.0;
    }
    ry += 10.0;

    // QC scores.
    c.text(right_x, ry, 10.0, "F2", INK2, "QC SCORES");
    ry += 16.0;
    let focus = snap
        .focus_score
        .map(|v| format!("{v:.3}"))
        .unwrap_or_else(|| "-".to_string());
    let illum = snap
        .illumination_residual
        .map(|v| format!("{v:.3}"))
        .unwrap_or_else(|| "-".to_string());
    c.text(right_x, ry, 10.0, "F1", INK2, "Focus");
    c.text(right_x + 200.0, ry, 10.0, "F1", INK2, "Illumination residual");
    ry += 14.0;
    c.text(right_x, ry, 14.0, "F2", INK, &focus);
    c.text(right_x + 200.0, ry, 14.0, "F2", INK, &illum);
    ry += 22.0;

    // F1 vs ground truth (only when annotations exist).
    if let Some(f1) = snap.f1 {
        c.text(right_x, ry, 10.0, "F2", INK2, "GROUND TRUTH");
        ry += 16.0;
        c.text(
            right_x,
            ry,
            13.0,
            "F1",
            INK,
            &format!("F1 vs annotations: {f1:.3}"),
        );
    }

    // ---- footer: provenance lines ----
    let footer_y = PAGE_H - MARGIN - 40.0;
    c.hline(content_left, content_right, footer_y - 10.0, DIVIDER, 1.0);
    for (i, line) in provenance_footer_lines(prov).iter().enumerate() {
        c.text(
            content_left,
            footer_y + (i as f64) * 12.0,
            9.0,
            "F3",
            INK3,
            line,
        );
    }

    assemble_pdf(&c.ops, annotated.as_ref())
}

/// Fit (iw,ih) into (bw,bh) preserving aspect ratio.
fn fit_box(iw: f64, ih: f64, bw: f64, bh: f64) -> (f64, f64) {
    if iw <= 0.0 || ih <= 0.0 {
        return (bw, bh);
    }
    let scale = (bw / iw).min(bh / ih);
    (iw * scale, ih * scale)
}

/// Draw a mini bar chart of bin counts with count labels above each bar.
fn draw_histogram(c: &mut Content, x: f64, y: f64, w: f64, h: f64, counts: &[usize]) {
    c.rect_stroke(x, y, w, h, DIVIDER, 1.0);
    let n = counts.len().max(1);
    let max_v = counts.iter().copied().max().unwrap_or(1).max(1) as f64;
    let gap = 6.0;
    let inner_pad = 8.0;
    let total_gap = gap * (n as f64 - 1.0).max(0.0);
    let bar_w = ((w - total_gap - inner_pad * 2.0) / n as f64).max(2.0);
    for (i, &count) in counts.iter().enumerate() {
        let frac = count as f64 / max_v;
        let bar_h = ((h - 22.0) * frac).max(1.0);
        let bx = x + inner_pad + i as f64 * (bar_w + gap);
        let by = y + h - 18.0 - bar_h; // top-down y of the bar's top edge
        c.rect_fill(bx, by, bar_w, bar_h, bin_pdf_rgb(i));
        // Count label above the bar.
        c.text(bx, by - 2.0, 9.0, "F2", INK2, &count.to_string());
    }
}

/// Three monospaced footer lines (port of `provenanceFooterLines`), minus the
/// weights hash / detector version we don't probe in v1.
fn provenance_footer_lines(p: &Provenance) -> Vec<String> {
    let line1 = format!(
        "generated by CellCounter {} - {}",
        p.app_version, p.model_id
    );
    let line2 = format!("detector: cellpose - {}", p.os_version);
    let line3 = format!(
        "calibration: {} px/um ({})",
        fmt_g(p.px_per_um),
        p.px_per_um_source
    );
    vec![line1, line2, line3]
}

// ---------------------------------------------------------------------------
// PDF object assembly
// ---------------------------------------------------------------------------

/// Assemble the final PDF bytes from the content stream + (optional) image
/// XObject. Objects:
///   1 Catalog, 2 Pages, 3 Page, 4 Contents(stream), 5 Font F1 (Helvetica),
///   6 Font F2 (Helvetica-Bold), 7 Font F3 (Courier), 8 Image XObject (opt).
fn assemble_pdf(content: &str, image: Option<&AnnotatedJpeg>) -> Vec<u8> {
    let mut objects: Vec<Vec<u8>> = Vec::new();

    let has_image = image.is_some();
    let img_obj_id = 8;

    // 1: Catalog
    objects.push(b"<< /Type /Catalog /Pages 2 0 R >>".to_vec());
    // 2: Pages
    objects.push(b"<< /Type /Pages /Kids [3 0 R] /Count 1 >>".to_vec());
    // 3: Page
    let xobject = if has_image {
        format!("/XObject << /Im0 {img_obj_id} 0 R >> ")
    } else {
        String::new()
    };
    let page = format!(
        "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 {PAGE_W:.0} {PAGE_H:.0}] \
         /Resources << /Font << /F1 5 0 R /F2 6 0 R /F3 7 0 R >> {xobject}>> \
         /Contents 4 0 R >>"
    );
    objects.push(page.into_bytes());
    // 4: Contents stream
    let mut stream = Vec::new();
    stream.extend_from_slice(format!("<< /Length {} >>\nstream\n", content.len()).as_bytes());
    stream.extend_from_slice(content.as_bytes());
    stream.extend_from_slice(b"\nendstream");
    objects.push(stream);
    // 5,6,7: fonts
    objects.push(b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>".to_vec());
    objects.push(b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica-Bold /Encoding /WinAnsiEncoding >>".to_vec());
    objects.push(b"<< /Type /Font /Subtype /Type1 /BaseFont /Courier /Encoding /WinAnsiEncoding >>".to_vec());
    // 8: image XObject (optional)
    if let Some(a) = image {
        let mut obj = Vec::new();
        obj.extend_from_slice(
            format!(
                "<< /Type /XObject /Subtype /Image /Width {} /Height {} \
                 /ColorSpace /DeviceRGB /BitsPerComponent 8 /Filter /DCTDecode /Length {} >>\nstream\n",
                a.width,
                a.height,
                a.bytes.len()
            )
            .as_bytes(),
        );
        obj.extend_from_slice(&a.bytes);
        obj.extend_from_slice(b"\nendstream");
        objects.push(obj);
    }

    // Serialize with a cross-reference table.
    let mut out: Vec<u8> = Vec::new();
    out.extend_from_slice(b"%PDF-1.7\n%\xE2\xE3\xCF\xD3\n");
    let mut offsets: Vec<usize> = Vec::with_capacity(objects.len());
    for (i, obj) in objects.iter().enumerate() {
        offsets.push(out.len());
        let header = format!("{} 0 obj\n", i + 1);
        out.extend_from_slice(header.as_bytes());
        out.extend_from_slice(obj);
        out.extend_from_slice(b"\nendobj\n");
    }

    let xref_pos = out.len();
    let count = objects.len() + 1; // +1 for the free object 0
    out.extend_from_slice(format!("xref\n0 {count}\n").as_bytes());
    out.extend_from_slice(b"0000000000 65535 f \n");
    for off in &offsets {
        let entry = format!("{off:010} 00000 n \n");
        out.extend_from_slice(entry.as_bytes());
    }
    let trailer = format!(
        "trailer\n<< /Size {count} /Root 1 0 R >>\nstartxref\n{xref_pos}\n%%EOF\n"
    );
    out.extend_from_slice(trailer.as_bytes());

    // `has_image`/`img_obj_id` only meaningful when an image exists; keep the
    // borrow of `image` alive for the whole function (drops here).
    let _ = image;
    out
}
