//! export/csv.rs — CSV export (cells / summary / annotations / comparison) (feature `export`).
//!
//! Port of the Swift `ExportService` CSV writers. Column orders + number
//! formats are reproduced EXACTLY from `Services/ExportService.swift` (they are
//! the frozen output contract in tasks.json → feat-export → output):
//!   * `cells.csv`   — per-cell measurements (Results). 23 columns.
//!   * `summary.csv` — per-image batch summary (Batch). 18 columns.
//!   * `annotations.csv` — ground-truth marks (id,cx_px,cy_px,cx_um,cy_um,…).
//!   * comparison CSV — condition,bin_label,count,percent,total_cells,batches.
//!
//! Two commands are registered in `lib.rs` (`export_cells_csv`,
//! `export_batch_summary_csv`); the annotation + comparison writers are exposed
//! as `pub(crate)` builders reused by the ROI/report/panel flows and available
//! for a future command wiring without changing this file's contract.

use rusqlite::{Connection, OptionalExtension};
use tauri::{AppHandle, State};

use crate::db::models::CellDto;
use crate::db::repo::Db;
use crate::export::provenance::{
    fmt_g, fmt_thresholds_bracket, open_reader, resolve_out_path, ExportContext, Provenance,
};
use crate::paths::FileStore;

/// What kind of CSV to write. Serialized camelCase from the UI. Retained from
/// the stub so callers that branch on kind keep compiling; the concrete writers
/// live below.
#[derive(Debug, Clone, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum CsvKind {
    Cells,
    BatchSummary,
    Comparison,
    Annotations,
}

// ---------------------------------------------------------------------------
// shared CSV formatting helpers (mirror ExportService private helpers)
// ---------------------------------------------------------------------------

/// RFC-4180-style quoting: quote when the value contains the separator, a quote,
/// or a newline; double embedded quotes. Mirrors `ExportService.csvEscape`.
pub(crate) fn csv_escape(s: &str, separator: &str) -> String {
    let needs_quote =
        s.contains(separator) || s.contains('"') || s.contains('\n') || s.contains('\r');
    if !needs_quote {
        return s.to_string();
    }
    let escaped = s.replace('"', "\"\"");
    format!("\"{escaped}\"")
}

/// The `#`-prefixed single-line config header embedded at the top of every CSV
/// (`ExportService.configHeaderComment`):
///   `# confidence=0.85; bins=[20,30]; model=cellpose-cyto3; pxPerUm=2.6`
pub(crate) fn config_header_comment(
    thresholds: &[f64],
    px_per_um: f64,
    confidence: f64,
    model_id: &str,
) -> String {
    format!(
        "# confidence={:.2}; bins={}; model={}; pxPerUm={}",
        confidence,
        fmt_thresholds_bracket(thresholds),
        model_id,
        fmt_g(px_per_um)
    )
}

/// `%.6f` for an optional measurement; empty string when absent (Swift `fmt`).
fn fmt6_opt(v: Option<f64>) -> String {
    match v {
        Some(x) => format!("{x:.6}"),
        None => String::new(),
    }
}

/// `1`/`0` for a flag (Swift `boolStr`); `false` when the flag is absent.
fn bool_str(v: Option<bool>) -> &'static str {
    if v.unwrap_or(false) {
        "1"
    } else {
        "0"
    }
}

// ---------------------------------------------------------------------------
// bin math (ports of Domain/SizeBin.swift BinMath, mirrored in calibration.ts)
// ---------------------------------------------------------------------------

/// Bin labels for a threshold ladder — `[20,30]` → `["< 20 µm","20–30 µm","> 30 µm"]`.
/// Empty thresholds → a single `"all"` bin. Port of `BinMath.bins(from:).label`.
pub(crate) fn bin_labels(thresholds: &[f64]) -> Vec<String> {
    if thresholds.is_empty() {
        return vec!["all".to_string()];
    }
    let fmt = |v: f64| -> String {
        if v.fract() == 0.0 {
            format!("{}", v as i64)
        } else {
            format!("{v:.1}")
        }
    };
    let mut out = Vec::with_capacity(thresholds.len() + 1);
    out.push(format!("< {} µm", fmt(thresholds[0])));
    for w in thresholds.windows(2) {
        out.push(format!("{}–{} µm", fmt(w[0]), fmt(w[1])));
    }
    out.push(format!("> {} µm", fmt(thresholds[thresholds.len() - 1])));
    out
}

/// Index of the bin a diameter falls into (first threshold it is strictly below,
/// else the open-top bin). Port of `BinMath.binIndex`.
pub(crate) fn bin_index(diameter_um: f64, thresholds: &[f64]) -> usize {
    for (i, t) in thresholds.iter().enumerate() {
        if diameter_um < *t {
            return i;
        }
    }
    thresholds.len()
}

// ===========================================================================
// cells.csv  (per-cell measurements)
// ===========================================================================

/// Column header for `cells.csv`, EXACTLY as `ExportService.writeCSV` +
/// tasks.json feat-export → output.
const CELLS_HEADER: &[&str] = &[
    "id",
    "cx_px",
    "cy_px",
    "diameter_um",
    "diameter_px",
    "bin_label",
    "confidence",
    "area_um2",
    "perimeter_um",
    "circularity",
    "eccentricity",
    "mean_intensity",
    "integrated_density",
    "image_filename",
    "centroid_um_x",
    "centroid_um_y",
    "aspect_ratio",
    "solidity",
    "size_class",
    "edge_touching",
    "likely_clump",
    "likely_debris",
    "is_manual",
];

/// Build the full `cells.csv` body (provenance block + config header + column
/// header + one row per visible cell). Rows are filtered by the effective
/// confidence `cutoff` so the CSV matches the on-screen overlay.
pub(crate) fn build_cells_csv(
    cells: &[CellDto],
    image_filename: &str,
    thresholds: &[f64],
    px_per_um: f64,
    cutoff: f64,
    model_id: &str,
    provenance: &Provenance,
) -> String {
    let sep = ",";
    let labels = bin_labels(thresholds);
    let mut lines: Vec<String> = Vec::new();

    // Provenance block first (self-describing), then the pass-15 config line.
    lines.push(provenance.as_csv_header());
    lines.push(config_header_comment(thresholds, px_per_um, cutoff, model_id));
    lines.push(CELLS_HEADER.join(sep));

    for cell in cells.iter().filter(|c| c.confidence >= cutoff) {
        let idx = bin_index(cell.diameter_um, thresholds);
        let safe_idx = idx.min(labels.len().saturating_sub(1));
        let bin_label = labels.get(safe_idx).map(String::as_str).unwrap_or("all");

        let row: Vec<String> = vec![
            cell.id.clone(),
            format!("{:.3}", cell.cx),
            format!("{:.3}", cell.cy),
            format!("{:.3}", cell.diameter_um),
            format!("{:.3}", cell.diameter_px),
            csv_escape(bin_label, sep),
            format!("{:.3}", cell.confidence),
            fmt6_opt(cell.area_um2),
            fmt6_opt(cell.perimeter_um),
            fmt6_opt(cell.circularity),
            fmt6_opt(cell.eccentricity),
            fmt6_opt(cell.mean_intensity),
            fmt6_opt(cell.integrated_density),
            csv_escape(image_filename, sep),
            fmt6_opt(cell.centroid_um_x),
            fmt6_opt(cell.centroid_um_y),
            fmt6_opt(cell.aspect_ratio),
            fmt6_opt(cell.solidity),
            csv_escape(cell.size_class.as_deref().unwrap_or(""), sep),
            bool_str(cell.edge_touching).to_string(),
            bool_str(cell.likely_clump).to_string(),
            bool_str(cell.likely_debris).to_string(),
            bool_str(cell.is_manual).to_string(),
        ];
        lines.push(row.join(sep));
    }

    lines.join("\n") + "\n"
}

/// Write a per-cell `cells.csv` for `image_id`. The UI passes the live `cells`
/// (so manual edits are reflected) + the active `px_per_um` + the current global
/// `confidence` slider; provenance, thresholds, filename, and model id are
/// loaded from the store. Rows below the effective confidence are filtered so
/// the CSV matches the on-screen overlay (mirrors `ExportService.writeCSV`). A
/// bare `out_path` filename lands under `Exports/`. Returns the absolute path.
#[tauri::command]
pub async fn export_cells_csv(
    app: AppHandle,
    db: State<'_, Db>,
    image_id: String,
    cells: Vec<CellDto>,
    px_per_um: f64,
    confidence: Option<f64>,
    out_path: String,
) -> Result<String, String> {
    let _ = &db;
    let store = FileStore::from_app(&app)?;
    let conn = open_reader(&store)?;
    let ctx = ExportContext::load(&conn, &store, &image_id)?;

    // Effective confidence: per-image override wins over the supplied global
    // slider (mirrors `AppState.effectiveConfidence`); absent both, include all.
    let global = confidence.unwrap_or(0.0);
    let cutoff = ctx.effective_confidence(global);
    let provenance = Provenance::capture(&ctx, cutoff);

    let body = build_cells_csv(
        &cells,
        &ctx.file_name,
        &ctx.thresholds,
        px_per_um,
        cutoff,
        ctx.detector_id.as_deref().unwrap_or(&ctx.model_id),
        &provenance,
    );

    let resolved = resolve_out_path(&store, &out_path)?;
    std::fs::write(&resolved, body).map_err(|e| format!("could not write cells.csv: {e}"))?;
    Ok(resolved.to_string_lossy().into_owned())
}

// ===========================================================================
// summary.csv  (per-image batch summary)
// ===========================================================================

/// Column header for `summary.csv`, EXACTLY as
/// `ExportService.writePerImageSummaryCSV` + tasks.json feat-export → output.
const SUMMARY_HEADER: &[&str] = &[
    "image",
    "n_cells",
    "mean_diameter",
    "sd_diameter",
    "n_small",
    "n_intermediate",
    "n_large",
    "pct_clumps",
    "pct_debris",
    "pct_edge",
    "confluency",
    "n_colonies",
    "mean_colony_size",
    "largest_colony",
    "focus_score",
    "illumination_residual",
    "model_used",
    "ran_at",
];

/// One image's detection as read for the summary CSV.
struct SummaryImage {
    file_name: String,
    imported_at: String,
    has_detection: bool,
    cells: Vec<CellDto>,
    image_stats: std::collections::BTreeMap<String, f64>,
    detector_id: String,
    ran_at: String,
}

/// Write a one-row-per-image `summary.csv` for the whole batch. All values come
/// from the store (saved detections). A bare `out_path` filename lands under
/// `Exports/`. Returns the absolute path.
#[tauri::command]
pub async fn export_batch_summary_csv(
    app: AppHandle,
    db: State<'_, Db>,
    batch_id: String,
    out_path: String,
) -> Result<String, String> {
    let _ = &db;
    let store = FileStore::from_app(&app)?;
    let conn = open_reader(&store)?;

    // Batch calibration + label for the config header / provenance.
    let (px_per_um, px_per_um_source, thresholds, model_id) = conn
        .query_row(
            "SELECT px_per_um, px_per_um_source, thresholds_json, model_id
               FROM batches WHERE id = ?1",
            [&batch_id],
            |r| {
                Ok((
                    r.get::<_, f64>(0)?,
                    r.get::<_, Option<String>>(1)?,
                    r.get::<_, String>(2)?,
                    r.get::<_, String>(3)?,
                ))
            },
        )
        .optional()
        .map_err(|e| format!("batch lookup failed: {e}"))?
        .map(|(px, src, th, mid)| {
            let thresholds: Vec<f64> = serde_json::from_str(&th).unwrap_or_default();
            (px, src.unwrap_or_else(|| "default".into()), thresholds, mid)
        })
        .ok_or_else(|| format!("no batch with id {batch_id}"))?;

    let images = load_batch_summary_images(&conn, &batch_id)?;
    let body = build_summary_csv(
        &images,
        &thresholds,
        px_per_um,
        &px_per_um_source,
        &model_id,
    );

    let resolved = resolve_out_path(&store, &out_path)?;
    std::fs::write(&resolved, body).map_err(|e| format!("could not write summary.csv: {e}"))?;
    Ok(resolved.to_string_lossy().into_owned())
}

/// Read every image in the batch + its 1:1 detection, sorted by import order
/// (stable, reproducible rows — mirrors the Swift `sorted { importedAt }`).
fn load_batch_summary_images(
    conn: &Connection,
    batch_id: &str,
) -> Result<Vec<SummaryImage>, String> {
    let mut stmt = conn
        .prepare(
            "SELECT i.file_name, i.imported_at,
                    d.detector_id, d.ran_at, d.cells_json, d.image_stats_json
               FROM images i
               LEFT JOIN detections d ON d.image_id = i.id
              WHERE i.batch_id = ?1
              ORDER BY i.imported_at ASC",
        )
        .map_err(|e| e.to_string())?;
    let rows = stmt
        .query_map([batch_id], |r| {
            let file_name: String = r.get(0)?;
            let imported_at: String = r.get(1)?;
            let detector_id: Option<String> = r.get(2)?;
            let ran_at: Option<String> = r.get(3)?;
            let cells_json: Option<String> = r.get(4)?;
            let stats_json: Option<String> = r.get(5)?;
            Ok((
                file_name,
                imported_at,
                detector_id,
                ran_at,
                cells_json,
                stats_json,
            ))
        })
        .map_err(|e| e.to_string())?
        .collect::<rusqlite::Result<Vec<_>>>()
        .map_err(|e| e.to_string())?;

    let mut out = Vec::with_capacity(rows.len());
    for (file_name, imported_at, detector_id, ran_at, cells_json, stats_json) in rows {
        let has_detection = cells_json.is_some();
        let cells = cells_json
            .as_deref()
            .map(crate::db::models::cells_from_json)
            .unwrap_or_default();
        let image_stats: std::collections::BTreeMap<String, f64> = stats_json
            .and_then(|s| serde_json::from_str(&s).ok())
            .unwrap_or_default();
        out.push(SummaryImage {
            file_name,
            imported_at,
            has_detection,
            cells,
            image_stats,
            detector_id: detector_id.unwrap_or_default(),
            ran_at: ran_at.unwrap_or_default(),
        });
    }
    Ok(out)
}

/// Assemble the `summary.csv` body, matching `writePerImageSummaryCSV` value
/// formatting: mean/sd `%.3f`, pct `%.2f`, colony/focus/illum from `imageStats`.
fn build_summary_csv(
    images: &[SummaryImage],
    thresholds: &[f64],
    px_per_um: f64,
    px_per_um_source: &str,
    model_id: &str,
) -> String {
    let sep = ",";
    let small_t = thresholds.first().copied().unwrap_or(20.0);
    let large_t = thresholds.last().copied().unwrap_or(30.0);

    // Provenance block over the batch (image-agnostic — no per-image hash).
    let mut prov = Provenance {
        app_version: crate::export::provenance::APP_VERSION.to_string(),
        os_version: crate::export::provenance::os_descriptor(),
        model_id: model_id.to_string(),
        px_per_um,
        px_per_um_source: px_per_um_source.to_string(),
        thresholds: thresholds.to_vec(),
        confidence_floor: 0.0,
        background_subtract: false,
        watershed_split: false,
        exported_at: crate::db::repo::now_iso8601(),
        image_id: None,
        file_name: None,
        file_hash: None,
        detection_ran_at: None,
    };
    prov.confidence_floor = 0.0;

    let mut lines: Vec<String> = Vec::new();
    lines.push(prov.as_csv_header());
    lines.push(config_header_comment(thresholds, px_per_um, 0.0, model_id));
    lines.push(SUMMARY_HEADER.join(sep));

    // Disambiguate duplicate filenames with _2, _3… (mirrors the Swift map).
    let mut name_counts: std::collections::HashMap<&str, usize> = std::collections::HashMap::new();
    for img in images {
        *name_counts.entry(img.file_name.as_str()).or_insert(0) += 1;
    }
    let mut name_seen: std::collections::HashMap<&str, usize> = std::collections::HashMap::new();

    for img in images {
        // Confidence floor for the summary is 0 (include all saved cells) — the
        // Swift default when no cutoff is threaded; the batch summary aggregates
        // the whole detection.
        let cells: Vec<&CellDto> = img.cells.iter().collect();
        let n_cells = cells.len();
        let diameters: Vec<f64> = cells.iter().map(|c| c.diameter_um).collect();

        let mean_d = if diameters.is_empty() {
            0.0
        } else {
            diameters.iter().sum::<f64>() / diameters.len() as f64
        };
        let sd_d = if diameters.len() > 1 {
            let m = mean_d;
            let var = diameters.iter().map(|d| (d - m) * (d - m)).sum::<f64>()
                / diameters.len() as f64;
            var.sqrt()
        } else {
            0.0
        };

        // Size-class counts: prefer the C1 sizeClass field, else compute.
        let (mut n_small, mut n_inter, mut n_large) = (0usize, 0usize, 0usize);
        for c in &cells {
            let cls = match c.size_class.as_deref() {
                Some(s) if !s.is_empty() => s.to_string(),
                _ => {
                    if c.diameter_um < small_t {
                        "small".to_string()
                    } else if c.diameter_um >= large_t {
                        "large".to_string()
                    } else {
                        "intermediate".to_string()
                    }
                }
            };
            match cls.as_str() {
                "small" => n_small += 1,
                "large" => n_large += 1,
                _ => n_inter += 1,
            }
        }

        let denom = n_cells.max(1) as f64;
        let n_clumps = cells.iter().filter(|c| c.likely_clump.unwrap_or(false)).count();
        let n_debris = cells.iter().filter(|c| c.likely_debris.unwrap_or(false)).count();
        let n_edge = cells.iter().filter(|c| c.edge_touching.unwrap_or(false)).count();
        let pct_clumps = 100.0 * n_clumps as f64 / denom;
        let pct_debris = 100.0 * n_debris as f64 / denom;
        let pct_edge = 100.0 * n_edge as f64 / denom;

        let stats = &img.image_stats;
        let stat = |key: &str, decimals: usize| -> String {
            match stats.get(key) {
                Some(v) => format!("{:.*}", decimals, v),
                None => String::new(),
            }
        };
        let stat_int = |key: &str| -> String {
            match stats.get(key) {
                Some(v) => format!("{}", v.round() as i64),
                None => String::new(),
            }
        };

        // Blank the count columns entirely when there's no detection (a 0 would
        // wrongly read as "measured zero cells").
        let has = img.has_detection;
        let n_cells_str = if has { n_cells.to_string() } else { String::new() };
        let mean_d_str = if has && n_cells > 0 { format!("{mean_d:.3}") } else { String::new() };
        let sd_d_str = if has && n_cells > 1 { format!("{sd_d:.3}") } else { String::new() };
        let small_str = if has { n_small.to_string() } else { String::new() };
        let inter_str = if has { n_inter.to_string() } else { String::new() };
        let large_str = if has { n_large.to_string() } else { String::new() };
        let clumps_str = if has && n_cells > 0 { format!("{pct_clumps:.2}") } else { String::new() };
        let debris_str = if has && n_cells > 0 { format!("{pct_debris:.2}") } else { String::new() };
        let edge_str = if has && n_cells > 0 { format!("{pct_edge:.2}") } else { String::new() };

        // Disambiguated display name.
        let display_name = if name_counts.get(img.file_name.as_str()).copied().unwrap_or(0) > 1 {
            let seen = name_seen.entry(img.file_name.as_str()).or_insert(0);
            *seen += 1;
            let suffix = *seen;
            if suffix == 1 {
                img.file_name.clone()
            } else {
                let path = std::path::Path::new(&img.file_name);
                let stem = path.file_stem().and_then(|s| s.to_str()).unwrap_or(&img.file_name);
                match path.extension().and_then(|e| e.to_str()) {
                    Some(ext) if !ext.is_empty() => format!("{stem}_{suffix}.{ext}"),
                    _ => format!("{stem}_{suffix}"),
                }
            }
        } else {
            img.file_name.clone()
        };

        let row: Vec<String> = vec![
            csv_escape(&display_name, sep),
            n_cells_str,
            mean_d_str,
            sd_d_str,
            small_str,
            inter_str,
            large_str,
            clumps_str,
            debris_str,
            edge_str,
            stat("confluency_pct", 2),
            stat_int("n_colonies"),
            stat("mean_colony_size_cells", 2),
            stat_int("largest_colony_size_cells"),
            stat("focus_score", 4),
            stat("illumination_residual", 4),
            csv_escape(&img.detector_id, sep),
            csv_escape(&img.ran_at, sep),
        ];
        // `imported_at` is only used for the ORDER BY; keep it referenced so the
        // struct field isn't dead in release builds.
        let _ = &img.imported_at;
        lines.push(row.join(sep));
    }

    lines.join("\n") + "\n"
}

// ===========================================================================
// annotations.csv  (ground-truth marks) — builder reused by the bundle flows
// ===========================================================================

/// A ground-truth annotation as read for the annotations CSV.
pub(crate) struct AnnotationRow {
    pub id: String,
    pub cx: f64,
    pub cy: f64,
    pub diameter_um: Option<f64>,
    pub note: Option<String>,
    pub created_at: String,
}

/// Build an `annotations.csv` body. Header (EXACTLY the Swift
/// `writeAnnotationsCSV`): `id,cx_px,cy_px,cx_um,cy_um,diameter_um,note,created_at`.
/// Centroids are emitted in both px and µm so the file overlays in ImageJ
/// without a conversion step.
pub(crate) fn build_annotations_csv(
    file_name: &str,
    annotations: &[AnnotationRow],
    px_per_um: f64,
) -> String {
    let sep = ",";
    let mut lines: Vec<String> = Vec::new();
    lines.push(format!(
        "# image={}; n={}; pxPerUm={}",
        file_name,
        annotations.len(),
        fmt_g(px_per_um)
    ));
    lines.push(
        ["id", "cx_px", "cy_px", "cx_um", "cy_um", "diameter_um", "note", "created_at"].join(sep),
    );
    let px_to_um = if px_per_um > 0.0 { 1.0 / px_per_um } else { 0.0 };
    for a in annotations {
        let cx_um = a.cx * px_to_um;
        let cy_um = a.cy * px_to_um;
        let diam = a.diameter_um.map(|d| format!("{d:.3}")).unwrap_or_default();
        let row: Vec<String> = vec![
            a.id.clone(),
            format!("{:.3}", a.cx),
            format!("{:.3}", a.cy),
            format!("{cx_um:.3}"),
            format!("{cy_um:.3}"),
            diam,
            csv_escape(a.note.as_deref().unwrap_or(""), sep),
            a.created_at.clone(),
        ];
        lines.push(row.join(sep));
    }
    lines.join("\n") + "\n"
}

// ===========================================================================
// comparison CSV  (Compare view) — builder reused by feat-compare
// ===========================================================================

/// One per-condition pooled row for the comparison CSV.
pub(crate) struct ComparisonRow {
    pub condition: String,
    pub bin_label: String,
    pub count: usize,
    pub percent: f64,
    pub total_cells: usize,
    pub batches: usize,
}

/// Build a comparison CSV body. Columns (EXACTLY tasks.json feat-compare →
/// output): `condition,bin_label,count,percent,total_cells,batches`.
pub(crate) fn build_comparison_csv(rows: &[ComparisonRow]) -> String {
    let sep = ",";
    let mut lines: Vec<String> = Vec::new();
    lines.push(["condition", "bin_label", "count", "percent", "total_cells", "batches"].join(sep));
    for r in rows {
        let row: Vec<String> = vec![
            csv_escape(&r.condition, sep),
            csv_escape(&r.bin_label, sep),
            r.count.to_string(),
            format!("{:.2}", r.percent),
            r.total_cells.to_string(),
            r.batches.to_string(),
        ];
        lines.push(row.join(sep));
    }
    lines.join("\n") + "\n"
}
