//! export/provenance.rs — provenance sidecar writer + shared export context (feature `export`).
//!
//! Port of `Services/ProvenanceMetadata.swift`. Writes a machine-readable
//! provenance record alongside every export: model id + calibration value + its
//! source, thresholds, params, app/OS versions, and the source-image hash — so a
//! result can be traced back to exactly how it was produced.
//!
//! This file also hosts the small pieces of shared export plumbing every other
//! writer in the `export` module needs (they are sibling modules under
//! `crate::export`, declared in `mod.rs`, so `csv.rs` / `report.rs` reuse these):
//!   * [`ExportContext`] — the batch/image/detection snapshot loaded once from
//!     the store, mirroring `ProvenanceMetadata.capture` + `ReportSnapshot.make`.
//!   * a read-only SQLite reader ([`open_reader`]) so exports never fight the
//!     write mutex in `repo.rs` (WAL keeps readers concurrent).
//!   * [`resolve_out_path`] — a bare filename lands under the app-data
//!     `Exports/` dir; an absolute path is honored as-is.
//!
//! Runtime identity is deterministic from the app-owned model routing contract.
//! A derived cyto3 checkpoint is hashed from its confined model-store file;
//! package-managed built-in weights have an explicit nullable checksum plus a
//! reason instead of silently omitting the key.

use std::io::Read;
use std::path::{Path, PathBuf};

use rusqlite::{Connection, OpenFlags, OptionalExtension};
use serde_json::json;
use sha2::{Digest, Sha256};
use tauri::{AppHandle, State};

use crate::db::models::{cells_from_json, CellDto};
use crate::db::repo::Db;
use crate::paths::FileStore;

// ---------------------------------------------------------------------------
// Read-only SQLite reader
// ---------------------------------------------------------------------------

/// Open a fresh connection to the same `store.sqlite` the write path uses, for
/// export reads only. We deliberately open read-*write* (a second normal handle
/// in the same process is fine for SQLite) rather than read-only: a read-only
/// handle can't recover/attach the WAL if the `-shm` isn't already mapped, which
/// would spuriously fail an export. WAL mode keeps this concurrent with any
/// in-flight write in `repo.rs`; a busy timeout rides out a momentary lock.
/// These commands never mutate — they only `SELECT`.
pub(crate) fn open_reader(store: &FileStore) -> Result<Connection, String> {
    let conn = Connection::open_with_flags(
        store.db_path(),
        OpenFlags::SQLITE_OPEN_READ_WRITE | OpenFlags::SQLITE_OPEN_URI,
    )
    .map_err(|e| format!("could not open store for export read: {e}"))?;
    // Ride out a brief writer lock rather than erroring immediately.
    let _ = conn.busy_timeout(std::time::Duration::from_millis(3000));
    Ok(conn)
}

// ---------------------------------------------------------------------------
// Line endings
// ---------------------------------------------------------------------------

/// Platform newline for exported text artefacts (CSV / provenance block).
///
/// CSVs are opened by mixed tools (Excel, R, pandas, plain editors); on Windows
/// the native expectation is CRLF, so we emit `\r\n` there and `\n` elsewhere.
/// This is the single source of truth — every CSV/provenance writer joins and
/// terminates lines with [`newline()`] so the whole file has one consistent
/// ending rather than a mix of `\n` bodies under a `\r\n`-joined header.
pub(crate) const fn newline() -> &'static str {
    if cfg!(windows) {
        "\r\n"
    } else {
        "\n"
    }
}

// ---------------------------------------------------------------------------
// Output-path resolution
// ---------------------------------------------------------------------------

/// Resolve an export destination.
///
/// The save-dialog path is the trust boundary: a *fully qualified* absolute path
/// (one the user picked in the native picker) is used verbatim; anything else is
/// treated as a bare filename and confined under the app-data `Exports/` dir.
///
/// "Fully qualified" here means an OS-absolute path — one that has BOTH a root
/// and (on Windows) a drive prefix, so `C:\Users\…\out.csv` qualifies but the
/// drive-*relative* `C:out.csv`, root-relative `\out.csv`, and bare `out.csv`
/// do not. `Path::is_absolute()` already enforces the drive+root rule on
/// Windows, so it is the correct predicate for the "verbatim" branch (the old
/// `parent().is_some()` test wrongly treated `C:out.csv` — whose parent is
/// `C:` — as qualified and wrote it relative to that drive's cwd).
///
/// For the confined branch we reject any component that would escape the base:
/// a `..` or an absolute/prefix component in the (non-qualified) request is a
/// traversal attempt and is refused rather than silently relocated. The parent
/// dir is created so the writer can't fail on a missing directory. Returns the
/// absolute path to write to.
pub(crate) fn resolve_out_path(store: &FileStore, out_path: &str) -> Result<PathBuf, String> {
    use std::path::Component;

    let requested = Path::new(out_path);

    // A user-picked absolute path (drive + root on Windows) is trusted verbatim.
    let resolved = if requested.is_absolute() {
        requested.to_path_buf()
    } else {
        // Everything else is confined under Exports/. Reject any component that
        // could escape the base: `..`, or a root/prefix (drive-relative like
        // `C:foo`, root-relative like `\foo`) sneaking into a "bare" name.
        let base = store.exports_dir();
        for comp in requested.components() {
            match comp {
                Component::Normal(_) | Component::CurDir => {}
                Component::ParentDir => {
                    return Err(format!(
                        "refusing to export outside the Exports directory: {out_path}"
                    ));
                }
                Component::RootDir | Component::Prefix(_) => {
                    return Err(format!(
                        "refusing to export to a non-relative path: {out_path}"
                    ));
                }
            }
        }
        base.join(requested)
    };
    if let Some(parent) = resolved.parent() {
        std::fs::create_dir_all(parent)
            .map_err(|e| format!("could not create export directory: {e}"))?;
    }
    Ok(resolved)
}

// ---------------------------------------------------------------------------
// ExportContext — the snapshot every writer reads from
// ---------------------------------------------------------------------------

/// A per-image snapshot loaded once from the store: the image row, its 1:1
/// detection (cells + image stats), and the owning batch's calibration. Mirrors
/// the fields `ProvenanceMetadata.capture` + `ReportSnapshot.make` read off the
/// live `AppState` in the Swift app, but sourced from SQLite so exports run off
/// any thread without the UI.
#[derive(Clone, Debug)]
pub(crate) struct ExportContext {
    pub image_id: String,
    pub file_name: String,
    pub stored_path: PathBuf,
    pub analysis_path: Option<PathBuf>,
    pub file_hash: Option<String>,
    pub confidence_override: Option<f64>,

    pub detector_id: Option<String>,
    pub ran_at: Option<String>,
    pub cells: Vec<CellDto>,
    pub image_stats: std::collections::BTreeMap<String, f64>,

    /// Owning batch calibration (falls back to sensible defaults when the image
    /// isn't attached to a batch yet).
    pub px_per_um: f64,
    pub px_per_um_source: String,
    pub thresholds: Vec<f64>,
    pub model_id: String,
    /// Exact model used by the latest detection. This comes from immutable
    /// `detections.detector_id`, not the owning batch's mutable/default model.
    pub run_model_id: String,
    pub detector_runtime: String,
    pub checkpoint_identity: String,
    pub weights_checkpoint_path: Option<PathBuf>,
    pub weights_sha256_reason: Option<String>,
}

fn run_model_from_detector(detector_id: Option<&str>, batch_model_id: &str) -> String {
    let candidate = detector_id
        .and_then(|value| value.strip_prefix("cellpose/"))
        .unwrap_or(batch_model_id);
    if matches!(candidate, "cpsam_v2" | "cp-cyto3" | "sd-fluo")
        || candidate.starts_with("cp-cyto3@")
    {
        candidate.to_string()
    } else {
        batch_model_id.to_string()
    }
}

fn sha256_file(path: &Path) -> Result<String, String> {
    let mut file = std::fs::File::open(path)
        .map_err(|error| format!("could not open checkpoint for hashing: {error}"))?;
    let mut hasher = Sha256::new();
    let mut buffer = [0_u8; 1024 * 1024];
    loop {
        let count = file
            .read(&mut buffer)
            .map_err(|error| format!("could not hash checkpoint: {error}"))?;
        if count == 0 {
            break;
        }
        hasher.update(&buffer[..count]);
    }
    Ok(format!("{:x}", hasher.finalize()))
}

fn detector_provenance(
    conn: &Connection,
    store: &FileStore,
    model_id: &str,
) -> (String, String, Option<PathBuf>, Option<String>) {
    if let Some(version_id) = model_id.strip_prefix("cp-cyto3@").filter(|id| !id.is_empty()) {
        let runtime = "python=.venv; cellpose>=3,<4; torch=cpu; device=cpu".to_string();
        let identity = format!("cp-cyto3-derived:{version_id}");
        let raw: Option<String> = conn
            .query_row(
                "SELECT checkpoint_path FROM model_versions WHERE id = ?1 AND model_id = 'cp-cyto3'",
                [version_id],
                |row| row.get(0),
            )
            .optional()
            .ok()
            .flatten();
        let Some(raw) = raw else {
            return (
                runtime,
                identity,
                None,
                Some("Derived checkpoint metadata is missing from model_versions.".to_string()),
            );
        };
        let models_dir = std::fs::canonicalize(store.models_dir());
        let checkpoint = std::fs::canonicalize(raw);
        match (models_dir, checkpoint) {
            (Ok(models_dir), Ok(checkpoint))
                if checkpoint.is_file() && checkpoint.starts_with(&models_dir) =>
            {
                (runtime, identity, Some(checkpoint), None)
            }
            _ => (
                runtime,
                identity,
                None,
                Some("Derived checkpoint is missing or outside CellCounter's model store.".to_string()),
            ),
        }
    } else {
        match model_id {
            "cpsam_v2" => (
                "python=.venv4; cellpose>=4; torch=cpu; device=cpu".to_string(),
                "cellpose:cpsam".to_string(),
                None,
                Some("Cellpose manages built-in cpsam weights in its package cache; the exact file path is not persisted with this run.".to_string()),
            ),
            "sd-fluo" => (
                "python=.venvsd; stardist>=0.9,<0.10; tensorflow>=2.16,<2.17-cpu; device=cpu".to_string(),
                "stardist:2D_versatile_fluo".to_string(),
                None,
                Some("StarDist stores this built-in checkpoint as a model directory; a canonical archive checksum is not available.".to_string()),
            ),
            _ => (
                "python=.venv; cellpose>=3,<4; torch=cpu; device=cpu".to_string(),
                "cellpose:cyto3".to_string(),
                None,
                Some("Cellpose manages built-in cyto3 weights in its package cache; the exact file path is not persisted with this run.".to_string()),
            ),
        }
    }
}

impl ExportContext {
    /// Load the context for `image_id`. Errors only when the image row is
    /// missing; a missing detection yields empty cells/stats (a still-valid
    /// export target — e.g. provenance for an un-analyzed image).
    pub(crate) fn load(conn: &Connection, store: &FileStore, image_id: &str) -> Result<Self, String> {
        // --- image row ---
        let image = conn
            .query_row(
                "SELECT file_name, file_hash, confidence_override, batch_id, stored_ext, analysis_path
                   FROM images WHERE id = ?1",
                [image_id],
                |r| {
                    Ok((
                        r.get::<_, String>(0)?,
                        r.get::<_, Option<String>>(1)?,
                        r.get::<_, Option<f64>>(2)?,
                        r.get::<_, Option<String>>(3)?,
                        r.get::<_, Option<String>>(4)?,
                        r.get::<_, Option<String>>(5)?,
                    ))
                },
            )
            .optional()
            .map_err(|e| format!("image lookup failed: {e}"))?
            .ok_or_else(|| format!("no image with id {image_id}"))?;
        let (file_name, file_hash, confidence_override, batch_id, stored_ext, analysis_path) = image;

        // --- stored path (Images/<id>.<ext>, ext from file_name) ---
        let ext = stored_ext.unwrap_or_else(|| Path::new(&file_name)
            .extension()
            .and_then(|e| e.to_str())
            .unwrap_or("tif")
            .to_ascii_lowercase());
        let stored_path = store.image_path(image_id, &ext);

        // --- 1:1 detection ---
        let detection = conn
            .query_row(
                "SELECT detector_id, ran_at, cells_json, image_stats_json
                   FROM detections WHERE image_id = ?1",
                [image_id],
                |r| {
                    Ok((
                        r.get::<_, String>(0)?,
                        r.get::<_, String>(1)?,
                        r.get::<_, String>(2)?,
                        r.get::<_, Option<String>>(3)?,
                    ))
                },
            )
            .optional()
            .map_err(|e| format!("detection lookup failed: {e}"))?;

        let (detector_id, ran_at, cells, image_stats) = match detection {
            Some((det_id, ran, cells_json, stats_json)) => {
                let cells = cells_from_json(&cells_json);
                let stats: std::collections::BTreeMap<String, f64> = stats_json
                    .and_then(|s| serde_json::from_str(&s).ok())
                    .unwrap_or_default();
                (Some(det_id), Some(ran), cells, stats)
            }
            None => (None, None, Vec::new(), std::collections::BTreeMap::new()),
        };

        // --- owning batch calibration (per-batch px/µm wins; else defaults) ---
        // A missing batch row (or an image not attached to a batch) falls back to
        // the sensible defaults — provenance is a still-valid export target for an
        // un-batched image.
        let (px_per_um, px_per_um_source, thresholds, model_id) = match batch_id {
            Some(bid) => load_batch_calibration(conn, &bid)?.unwrap_or_else(default_batch_calibration),
            None => default_batch_calibration(),
        };

        let run_model_id = run_model_from_detector(detector_id.as_deref(), &model_id);
        let (detector_runtime, checkpoint_identity, weights_checkpoint_path, weights_sha256_reason) =
            detector_provenance(conn, store, &run_model_id);

        Ok(ExportContext {
            image_id: image_id.to_string(),
            file_name,
            stored_path,
            analysis_path: analysis_path.map(PathBuf::from),
            file_hash,
            confidence_override,
            detector_id,
            ran_at,
            cells,
            image_stats,
            px_per_um,
            px_per_um_source,
            thresholds,
            model_id,
            run_model_id,
            detector_runtime,
            checkpoint_identity,
            weights_checkpoint_path,
            weights_sha256_reason,
        })
    }

    /// The confidence floor for this image: per-image override wins over the
    /// supplied global (mirrors `AppState.effectiveConfidence`). Callers pass
    /// the global slider value; export panels already resolve it, but the
    /// override is applied here as a safety net.
    pub(crate) fn effective_confidence(&self, global: f64) -> f64 {
        self.confidence_override.unwrap_or(global)
    }

    /// Cells visible at `cutoff` — the analytical artefact must match the
    /// on-screen overlay, so every writer filters by the effective confidence
    /// (mirrors `ExportService.writeCSV`'s `confidence >= cutoff`).
    pub(crate) fn visible_cells(&self, cutoff: f64) -> Vec<&CellDto> {
        self.cells.iter().filter(|c| c.confidence >= cutoff).collect()
    }
}

/// The default batch calibration used when an image has no owning batch (or the
/// batch row is missing): 2.6 px/µm, `[20,30]` thresholds, cyto3.
pub(crate) fn default_batch_calibration() -> (f64, String, Vec<f64>, String) {
    (2.6, "default".to_string(), vec![20.0, 30.0], "cp-cyto3".to_string())
}

/// Read a batch's calibration (px/µm + source + thresholds + model id).
/// Returns `Ok(None)` when no batch row with `batch_id` exists, so the caller
/// decides whether that is an error (a batch-summary export of a nonexistent
/// batch) or a fall back to [`default_batch_calibration`] (an un-batched image).
/// The single query + mapping lives here so `csv.rs` and `ExportContext::load`
/// stay in lock-step.
pub(crate) fn load_batch_calibration(
    conn: &Connection,
    batch_id: &str,
) -> Result<Option<(f64, String, Vec<f64>, String)>, String> {
    let row = conn
        .query_row(
            "SELECT px_per_um, px_per_um_source, thresholds_json, model_id
               FROM batches WHERE id = ?1",
            [batch_id],
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
        .map_err(|e| format!("batch lookup failed: {e}"))?;
    Ok(row.map(|(px, source, thresholds_json, model_id)| {
        let thresholds: Vec<f64> = serde_json::from_str(&thresholds_json).unwrap_or_default();
        (
            px,
            source.unwrap_or_else(|| "default".to_string()),
            thresholds,
            model_id,
        )
    }))
}

// ---------------------------------------------------------------------------
// Provenance — the reproducibility block
// ---------------------------------------------------------------------------

/// The app version stamped into every export (`Cargo.toml` `version`). The Swift
/// app reads `CFBundleShortVersionString`; here the crate version is the analogue.
pub(crate) const APP_VERSION: &str = env!("CARGO_PKG_VERSION");

/// Best-effort OS descriptor (family only — we don't shell out for a version).
pub(crate) fn os_descriptor() -> String {
    format!("{} ({})", std::env::consts::OS, std::env::consts::ARCH)
}

/// A captured provenance snapshot for one image's analysis (port of
/// `ProvenanceMetadata`). Runtime/checkpoint identity is always present. The
/// weights checksum is nullable only with an explicit reason.
#[derive(Clone, Debug)]
pub(crate) struct Provenance {
    pub app_version: String,
    pub os_version: String,
    pub model_id: String,
    pub detector_runtime: String,
    pub checkpoint_identity: String,
    pub weights_sha256: Option<String>,
    pub weights_sha256_reason: Option<String>,
    pub px_per_um: f64,
    pub px_per_um_source: String,
    pub thresholds: Vec<f64>,
    pub confidence_floor: f64,
    pub background_subtract: bool,
    pub watershed_split: bool,
    pub exported_at: String,
    pub image_id: Option<String>,
    pub file_name: Option<String>,
    pub file_hash: Option<String>,
    pub detection_ran_at: Option<String>,
}

impl Provenance {
    /// Capture from an [`ExportContext`]. `background_subtract` / `watershed_split`
    /// aren't persisted per-detection in the fresh SQLite store, so we default
    /// them to the Swift `AppState` defaults (false/false); the panel can pass a
    /// captured value if it ever threads params through.
    pub(crate) fn capture(ctx: &ExportContext, confidence_floor: f64) -> Self {
        let (weights_sha256, weights_sha256_reason) = match ctx.weights_checkpoint_path.as_deref() {
            Some(path) => match sha256_file(path) {
                Ok(hash) => (Some(hash), None),
                Err(reason) => (None, Some(reason)),
            },
            None => (None, ctx.weights_sha256_reason.clone()),
        };
        Provenance {
            app_version: APP_VERSION.to_string(),
            os_version: os_descriptor(),
            model_id: ctx.run_model_id.clone(),
            detector_runtime: ctx.detector_runtime.clone(),
            checkpoint_identity: ctx.checkpoint_identity.clone(),
            weights_sha256,
            weights_sha256_reason,
            px_per_um: ctx.px_per_um,
            px_per_um_source: ctx.px_per_um_source.clone(),
            thresholds: ctx.thresholds.clone(),
            confidence_floor,
            background_subtract: false,
            watershed_split: false,
            exported_at: crate::db::repo::now_iso8601(),
            image_id: Some(ctx.image_id.clone()),
            file_name: Some(ctx.file_name.clone()),
            file_hash: ctx.file_hash.clone(),
            detection_ran_at: ctx.ran_at.clone(),
        }
    }

    /// CSV-comment-friendly multi-line block ("# <key>: <value>" per row),
    /// mirroring `ProvenanceMetadata.asCSVHeader`. No trailing newline (callers
    /// join with "\n"). Absent optional fields are omitted cleanly.
    pub(crate) fn as_csv_header(&self) -> String {
        let mut lines: Vec<String> = Vec::new();
        lines.push(format!("# app_version: {}", self.app_version));
        lines.push(format!("# os_version: {}", self.os_version));
        lines.push(format!("# model_id: {}", self.model_id));
        lines.push(format!("# detector_runtime: {}", self.detector_runtime));
        lines.push(format!("# checkpoint_identity: {}", self.checkpoint_identity));
        lines.push(format!(
            "# weights_sha256: {}",
            self.weights_sha256.as_deref().unwrap_or("null")
        ));
        if let Some(reason) = &self.weights_sha256_reason {
            lines.push(format!("# weights_sha256_reason: {reason}"));
        }
        lines.push(format!("# pxPerUm: {}", fmt_g(self.px_per_um)));
        lines.push(format!("# pxPerUm_source: {}", self.px_per_um_source));
        lines.push(format!("# confidence_floor: {:.4}", self.confidence_floor));
        lines.push(format!("# thresholds: {}", fmt_thresholds_bracket(&self.thresholds)));
        lines.push(format!(
            "# background_subtract: {}",
            if self.background_subtract { "true" } else { "false" }
        ));
        lines.push(format!(
            "# watershed_split: {}",
            if self.watershed_split { "true" } else { "false" }
        ));
        lines.push(format!("# exported_at: {}", self.exported_at));
        if let Some(id) = &self.image_id {
            lines.push(format!("# image_id: {id}"));
        }
        if let Some(hash) = &self.file_hash {
            lines.push(format!("# image_sha256: {hash}"));
        }
        if let Some(ran) = &self.detection_ran_at {
            lines.push(format!("# detection_ran_at: {ran}"));
        }
        lines.join(newline())
    }

    /// Pretty-printed, key-sorted JSON (mirrors `ProvenanceMetadata.asJSON`,
    /// which uses `[.prettyPrinted, .sortedKeys]`). `serde_json::to_string_pretty`
    /// preserves the key order of a `serde_json::Value` built from a `BTreeMap`,
    /// which sorts keys — so we assemble the object as sorted key/value pairs.
    pub(crate) fn as_json(&self) -> String {
        // Build with sorted keys by inserting into a BTreeMap-backed object.
        let mut map = serde_json::Map::new();
        map.insert("app_version".into(), json!(self.app_version));
        map.insert("os_version".into(), json!(self.os_version));
        map.insert("model_id".into(), json!(self.model_id));
        map.insert("detector_runtime".into(), json!(self.detector_runtime));
        map.insert("checkpoint_identity".into(), json!(self.checkpoint_identity));
        map.insert("weights_sha256".into(), json!(self.weights_sha256));
        map.insert(
            "weights_sha256_reason".into(),
            json!(self.weights_sha256_reason),
        );
        map.insert("px_per_um".into(), json!(self.px_per_um));
        map.insert("px_per_um_source".into(), json!(self.px_per_um_source));
        map.insert("thresholds".into(), json!(self.thresholds));
        map.insert("confidence_floor".into(), json!(self.confidence_floor));
        map.insert("background_subtract".into(), json!(self.background_subtract));
        map.insert("watershed_split".into(), json!(self.watershed_split));
        map.insert("exported_at".into(), json!(self.exported_at));
        if let Some(id) = &self.image_id {
            map.insert("image_id".into(), json!(id));
        }
        if let Some(name) = &self.file_name {
            map.insert("image_filename".into(), json!(name));
        }
        if let Some(hash) = &self.file_hash {
            map.insert("image_sha256".into(), json!(hash));
        }
        if let Some(ran) = &self.detection_ran_at {
            map.insert("detection_ran_at".into(), json!(ran));
        }
        // serde_json::Map preserves insertion order unless the `preserve_order`
        // feature is off (default), in which case it is a BTreeMap that sorts
        // keys for us — either way `to_string_pretty` yields deterministic,
        // sorted output matching the Swift `.sortedKeys` contract.
        let value = serde_json::Value::Object(map);
        serde_json::to_string_pretty(&value).unwrap_or_else(|_| "{}".to_string())
    }
}

/// `%g`-style number (drops trailing zeros; matches Swift `String(format:"%g")`).
pub(crate) fn fmt_g(v: f64) -> String {
    // Rust's default float formatting already drops trailing zeros for typical
    // calibration values (2.6, 5.2). Guard the whole-number case explicitly so
    // 2.0 renders "2" like %g rather than "2".
    if v.fract() == 0.0 && v.abs() < 1e15 {
        format!("{}", v as i64)
    } else {
        // Trim to a compact representation without scientific notation for the
        // ranges we care about.
        let s = format!("{v}");
        s
    }
}

/// Render thresholds as `[20,30]` (integers drop the `.0`), matching the Swift
/// `binFmt` used in provenance + the config-header comment.
pub(crate) fn fmt_thresholds_bracket(thresholds: &[f64]) -> String {
    let inner = thresholds
        .iter()
        .map(|v| {
            if v.fract() == 0.0 {
                format!("{}", *v as i64)
            } else {
                format!("{v}")
            }
        })
        .collect::<Vec<_>>()
        .join(",");
    format!("[{inner}]")
}

// ===========================================================================
// COMMAND: export_provenance
// ===========================================================================

/// Write a provenance JSON sidecar for the detection on `image_id` to
/// `out_path` (a bare filename lands under `Exports/`). Returns the absolute
/// written path. Pretty-printed + key-sorted, matching the Swift bundle's
/// `provenance.json`.
#[tauri::command]
pub async fn export_provenance(
    app: AppHandle,
    db: State<'_, Db>,
    image_id: String,
    confidence: Option<f64>,
    out_path: String,
) -> Result<String, String> {
    let store = FileStore::from_app(&app)?;
    let resolved = tokio::task::spawn_blocking(move || {
        let conn = open_reader(&store)?;
        let ctx = ExportContext::load(&conn, &store, &image_id)?;
        // Per-image override wins over the supplied global slider; else the app
        // default (0.5) so the `confidence_floor` field is never a bare 0.
        let global = confidence.unwrap_or(0.5);
        let cutoff = ctx.effective_confidence(global);
        let provenance = Provenance::capture(&ctx, cutoff);
        let resolved = resolve_out_path(&store, &out_path)?;
        std::fs::write(&resolved, provenance.as_json())
            .map_err(|e| format!("could not write provenance.json: {e}"))?;
        Ok::<PathBuf, String>(resolved)
    })
    .await
    .map_err(|error| format!("provenance worker failed: {error}"))??;
    // Keep the managed DB handle alive for the command's lifetime (we read via
    // our own connection, but binding it documents the dependency + reserves the
    // param for callers that pass it).
    let _ = &db;
    Ok(resolved.to_string_lossy().into_owned())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn latest_detection_identity_overrides_existing_batch_model_for_provenance() {
        let root = std::env::temp_dir().join(format!("cellcounter-provenance-{}", uuid::Uuid::new_v4()));
        let store = FileStore::new(&root).unwrap();
        let checkpoint = store.models_dir().join("derived.ccmodel");
        std::fs::write(&checkpoint, b"real derived checkpoint bytes").unwrap();
        let checkpoint = std::fs::canonicalize(checkpoint).unwrap();

        let conn = Connection::open_in_memory().unwrap();
        crate::db::schema::create_schema(&conn).unwrap();
        conn.execute(
            "INSERT INTO batches
             (id,name,created_at,display_name,model_id,px_per_um,thresholds_json,px_per_um_source)
             VALUES ('batch','batch','now','batch','cp-cyto3',2.6,'[20,30]','manual')",
            [],
        ).unwrap();
        conn.execute(
            "INSERT INTO images
             (id,file_name,original_path,width_px,height_px,imported_at,stored_ext,batch_id)
             VALUES ('image','image.tif','source.tif',10,10,'now','tif','batch')",
            [],
        ).unwrap();
        conn.execute(
            "INSERT INTO model_versions
             (id,model_id,version,created_at,trained_on_images,trained_on_corrections,checkpoint_path,metrics_json)
             VALUES ('derived','cp-cyto3',1,'now',3,0,?1,'{}')",
            [checkpoint.to_string_lossy().as_ref()],
        ).unwrap();
        conn.execute(
            "INSERT INTO detections
             (id,image_id,detector_id,ran_at,cells_json,min_confidence)
             VALUES ('detection','image','cellpose/cp-cyto3@derived','now','[]',0.5)",
            [],
        ).unwrap();

        let context = ExportContext::load(&conn, &store, "image").unwrap();
        assert_eq!(context.model_id, "cp-cyto3");
        assert_eq!(context.run_model_id, "cp-cyto3@derived");
        assert_eq!(context.checkpoint_identity, "cp-cyto3-derived:derived");
        assert!(context.weights_checkpoint_path.is_some());
        assert!(context.weights_sha256_reason.is_none());
        let provenance = Provenance::capture(&context, 0.5);
        assert_eq!(provenance.model_id, "cp-cyto3@derived");
        assert!(provenance.weights_sha256.is_some());
        assert!(provenance.as_json().contains("\"weights_sha256\""));

        let _ = std::fs::remove_dir_all(root);
    }

    #[test]
    fn built_in_checkpoint_checksum_is_explicitly_nullable() {
        let conn = Connection::open_in_memory().unwrap();
        let root = std::env::temp_dir().join(format!("cellcounter-provenance-{}", uuid::Uuid::new_v4()));
        let store = FileStore::new(&root).unwrap();
        let (_, identity, checkpoint, reason) = detector_provenance(&conn, &store, "cpsam_v2");
        assert_eq!(identity, "cellpose:cpsam");
        assert!(checkpoint.is_none());
        assert!(reason.is_some());
        let _ = std::fs::remove_dir_all(root);
    }
}
