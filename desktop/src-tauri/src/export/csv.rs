//! export/csv.rs — CSV export (cells / summary) (feature `export`).
//!
//! Port of the Swift `ExportService` CSV writers. Column orders + number
//! formats are reproduced EXACTLY from `Services/ExportService.swift` (they are
//! the frozen output contract in tasks.json → feat-export → output):
//!   * `cells.csv`   — per-cell measurements (Results). 23 columns.
//!   * `summary.csv` — per-image batch summary (Batch). 18 columns.
//!
//! Two commands are registered in `lib.rs` (`export_cells_csv`,
//! `export_batch_summary_csv`). The Compare view's comparison CSV and the
//! ground-truth annotations CSV are produced on the JS side (kernel/stats), so
//! no Rust builders for them live here.

use rusqlite::Connection;
use tauri::{AppHandle, State};

use crate::db::models::CellDto;
use crate::db::repo::Db;
use crate::export::provenance::{
    fmt_g, fmt_thresholds_bracket, newline, open_reader, resolve_out_path, ExportContext,
    Provenance,
};
use crate::paths::FileStore;

// ---------------------------------------------------------------------------
// shared CSV formatting helpers (mirror ExportService private helpers)
// ---------------------------------------------------------------------------

/// RFC-4180-style quoting: quote when the value contains the separator, a quote,
/// or a newline; double embedded quotes. Mirrors `ExportService.csvEscape`.
///
/// Additionally neutralizes spreadsheet formula-injection: a free-text field that
/// begins with `=`, `+`, `-`, `@`, tab, or CR is treated by Excel/LibreOffice as
/// a formula on open. Since attacker-influenceable values (e.g. a source image
/// filename like `=HYPERLINK(...)` or `+cmd|'/c calc'!A1.tif`) flow verbatim into
/// the CSV, we prefix a `'` guard so the cell is imported as literal text. This
/// intentionally diverges from the frozen Swift output contract, which has the
/// same gap. All free-text columns (filename, size_class, detector_id, ran_at,
/// bin labels) route through here; purely numeric columns are formatted directly
/// and never reach this function, so numbers are unaffected.
pub(crate) fn csv_escape(s: &str, separator: &str) -> String {
    let first_dangerous = matches!(
        s.chars().next(),
        Some('=') | Some('+') | Some('-') | Some('@') | Some('\t') | Some('\r')
    );
    // Guard by prefixing an apostrophe (the conventional "force text" marker).
    let guarded = if first_dangerous {
        let mut g = String::with_capacity(s.len() + 1);
        g.push('\'');
        g.push_str(s);
        std::borrow::Cow::Owned(g)
    } else {
        std::borrow::Cow::Borrowed(s)
    };
    let s = guarded.as_ref();

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

    let nl = newline();
    lines.join(nl) + nl
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
    /// Per-image confidence override; when present it wins over the global
    /// slider for this image's effective cutoff (mirrors `AppState`).
    confidence_override: Option<f64>,
    has_detection: bool,
    cells: Vec<CellDto>,
    image_stats: std::collections::BTreeMap<String, f64>,
    detector_id: String,
    ran_at: String,
}

/// Write a one-row-per-image `summary.csv` for the whole batch. All values come
/// from the store (saved detections). Each image's cells are filtered by that
/// image's effective confidence (`confidence_override ?? global` — matching
/// `AppState.effectiveConfidence` and the Swift `writePerImageSummaryCSV`), so
/// the summary counts agree with the on-screen overlay per image. The optional
/// `confidence` is the global slider fallback (absent → 0, include all cells). A
/// bare `out_path` filename lands under `Exports/`. Returns the absolute path.
#[tauri::command]
pub async fn export_batch_summary_csv(
    app: AppHandle,
    db: State<'_, Db>,
    batch_id: String,
    confidence: Option<f64>,
    out_path: String,
) -> Result<String, String> {
    let _ = &db;
    let store = FileStore::from_app(&app)?;
    let conn = open_reader(&store)?;

    // Batch calibration + label for the config header / provenance. Shares the
    // single query/mapping in `provenance.rs`; a batch-summary export of a
    // nonexistent batch is a real error, so a missing row is surfaced here
    // (unlike `ExportContext`, which falls back to defaults for un-batched images).
    let (px_per_um, px_per_um_source, thresholds, model_id) =
        crate::export::provenance::load_batch_calibration(&conn, &batch_id)?
            .ok_or_else(|| format!("no batch with id {batch_id}"))?;

    let global_confidence = confidence.unwrap_or(0.0);
    let images = load_batch_summary_images(&conn, &batch_id)?;
    let body = build_summary_csv(
        &images,
        &thresholds,
        px_per_um,
        &px_per_um_source,
        &model_id,
        global_confidence,
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
            "SELECT i.file_name, i.imported_at, i.confidence_override,
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
            let confidence_override: Option<f64> = r.get(2)?;
            let detector_id: Option<String> = r.get(3)?;
            let ran_at: Option<String> = r.get(4)?;
            let cells_json: Option<String> = r.get(5)?;
            let stats_json: Option<String> = r.get(6)?;
            Ok((
                file_name,
                imported_at,
                confidence_override,
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
    for (file_name, imported_at, confidence_override, detector_id, ran_at, cells_json, stats_json) in
        rows
    {
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
            confidence_override,
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
    global_confidence: f64,
) -> String {
    let sep = ",";
    let small_t = thresholds.first().copied().unwrap_or(20.0);
    let large_t = thresholds.last().copied().unwrap_or(30.0);

    // Provenance block over the batch (image-agnostic — no per-image hash). The
    // confidence floor stamped here is the batch-wide global slider (mirrors the
    // Swift summary, which threads `confidence` into the header); per-image
    // overrides are applied to each row's cell filter below.
    let prov = Provenance {
        app_version: crate::export::provenance::APP_VERSION.to_string(),
        os_version: crate::export::provenance::os_descriptor(),
        model_id: model_id.to_string(),
        px_per_um,
        px_per_um_source: px_per_um_source.to_string(),
        thresholds: thresholds.to_vec(),
        confidence_floor: global_confidence,
        background_subtract: false,
        watershed_split: false,
        exported_at: crate::db::repo::now_iso8601(),
        image_id: None,
        file_name: None,
        file_hash: None,
        detection_ran_at: None,
    };

    let mut lines: Vec<String> = Vec::new();
    lines.push(prov.as_csv_header());
    lines.push(config_header_comment(
        thresholds,
        px_per_um,
        global_confidence,
        model_id,
    ));
    lines.push(SUMMARY_HEADER.join(sep));

    // Disambiguate duplicate filenames with _2, _3… (mirrors the Swift map).
    let mut name_counts: std::collections::HashMap<&str, usize> = std::collections::HashMap::new();
    for img in images {
        *name_counts.entry(img.file_name.as_str()).or_insert(0) += 1;
    }
    let mut name_seen: std::collections::HashMap<&str, usize> = std::collections::HashMap::new();

    for img in images {
        // Filter this image's cells by ITS OWN effective cutoff
        // (`confidence_override ?? global`), so each summary row aggregates over
        // the same cells the on-screen overlay shows — matching Swift's
        // `writePerImageSummaryCSV`. Absent both, `global_confidence` is 0 and
        // all saved cells are included.
        let effective_conf = img.confidence_override.unwrap_or(global_confidence);
        let cells: Vec<&CellDto> = img
            .cells
            .iter()
            .filter(|c| c.confidence >= effective_conf)
            .collect();
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

    let nl = newline();
    lines.join(nl) + nl
}
