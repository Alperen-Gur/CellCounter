//! export/roi.rs — ImageJ RoiSet export (feature `export`).
//!
//! Port of `ExportService.writeImageJROIs`. Builds the small detection JSON the
//! helper reads and invokes the existing `desktop/python/_export_imagej_roi.py`
//! from the same uv venv the detection sidecar uses. The helper writes an
//! ImageJ-compatible `RoiSet.zip` (POLYGON when a cell carries `contour_px` with
//! ≥ 3 points, else an OVAL from `diameter_px`; ROIs are named `cell_00001…`).
//!
//! Helper CLI (documented in the script header):
//!   `python _export_imagej_roi.py --in detection.json --out RoiSet.zip`
//! Helper stdout on success: `{"ok":true,"n_rois":N,"path":"/abs/RoiSet.zip"}`;
//! on failure exit 1 + `{"ok":false,"error":"…"}`.

use std::io::Write as _;
use std::process::Stdio;

use serde::Serialize;
use tauri::{AppHandle, State};
use tokio::process::Command;

use crate::db::models::CellDto;
use crate::db::repo::Db;
use crate::export::provenance::resolve_out_path;
use crate::paths::FileStore;

/// Per-cell payload the Python helper reads (snake-case keys, matching the
/// script's input schema + the Swift `ROICellWire`). `contour_px` is `[[x,y],…]`
/// or `null` (oval fallback).
#[derive(Serialize)]
struct RoiCellWire {
    id: String,
    cx: f64,
    cy: f64,
    diameter_px: f64,
    contour_px: Option<Vec<[f64; 2]>>,
    name: Option<String>,
}

#[derive(Serialize)]
struct RoiWireBlob {
    width: i64,
    height: i64,
    cells: Vec<RoiCellWire>,
}

/// The helper's stdout JSON. `ok=false` (with `error`) surfaces as an error even
/// on exit 0; a parse failure on exit 0 is non-fatal (the zip was written).
#[derive(serde::Deserialize)]
struct RoiHelperResult {
    ok: bool,
    #[serde(default)]
    #[allow(dead_code)]
    n_rois: Option<i64>,
    #[serde(default)]
    #[allow(dead_code)]
    path: Option<String>,
    #[serde(default)]
    error: Option<String>,
}

/// Export `cells` for `image_id` (with `image_width`/`image_height`) to an
/// ImageJ `RoiSet.zip` at `out_path` (a bare filename lands under `Exports/`).
/// Returns the absolute written path.
#[tauri::command]
pub async fn export_imagej_roi(
    app: AppHandle,
    db: State<'_, Db>,
    image_id: String,
    cells: Vec<CellDto>,
    image_width: i64,
    image_height: i64,
    out_path: String,
) -> Result<String, String> {
    let _ = (&db, &image_id);
    let store = FileStore::from_app(&app)?;

    // Resolve the venv python + the staged helper (same path the sidecar uses).
    let python = store.venv_python();
    if !python.exists() {
        return Err(
            "Python venv is not installed. Install Cellpose first to enable ROI export.".into(),
        );
    }
    let script = store.python_script("_export_imagej_roi.py");
    if !script.exists() {
        return Err("ROI export helper (_export_imagej_roi.py) is not staged.".into());
    }

    if cells.is_empty() {
        return Err("There are no detected cells to export.".into());
    }
    if image_width <= 0 || image_height <= 0 {
        return Err("Invalid image dimensions for ROI export.".into());
    }

    // Build the wire blob. A contour is passed only when it has ≥ 3 points
    // (otherwise the helper falls back to an oval anyway; matching the Swift
    // `contourPx.flatMap { !isEmpty }`).
    let wire_cells: Vec<RoiCellWire> = cells
        .iter()
        .map(|c| RoiCellWire {
            id: c.id.clone(),
            cx: c.cx,
            cy: c.cy,
            diameter_px: c.diameter_px,
            contour_px: c.contour_px.as_ref().and_then(|pts| {
                if pts.len() >= 3 {
                    Some(pts.clone())
                } else {
                    None
                }
            }),
            name: None,
        })
        .collect();
    let blob = RoiWireBlob {
        width: image_width,
        height: image_height,
        cells: wire_cells,
    };

    // Write the input JSON to a temp file next to the export (helper reads a
    // path, not stdin). Placed in the app-data Exports dir with a unique name.
    let input_path = store.exports_dir().join(format!(
        "cc-roi-{}.json",
        uuid::Uuid::new_v4().simple()
    ));
    {
        let json = serde_json::to_vec(&blob)
            .map_err(|e| format!("could not serialize ROI input: {e}"))?;
        let mut f = std::fs::File::create(&input_path)
            .map_err(|e| format!("could not create ROI input file: {e}"))?;
        f.write_all(&json)
            .map_err(|e| format!("could not write ROI input file: {e}"))?;
    }
    // Ensure the temp input is cleaned up regardless of outcome.
    struct TempFile(std::path::PathBuf);
    impl Drop for TempFile {
        fn drop(&mut self) {
            let _ = std::fs::remove_file(&self.0);
        }
    }
    let _cleanup = TempFile(input_path.clone());

    let resolved = resolve_out_path(&store, &out_path)?;

    // Spawn the helper: `python _export_imagej_roi.py --in <json> --out <zip>`.
    // cwd = python dir so the helper resolves its siblings if needed.
    let output = Command::new(&python)
        .arg(&script)
        .arg("--in")
        .arg(&input_path)
        .arg("--out")
        .arg(&resolved)
        .current_dir(store.python_dir())
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .output()
        .await
        .map_err(|e| format!("failed to spawn ROI helper: {e}"))?;

    let stdout = String::from_utf8_lossy(&output.stdout);
    let stderr = String::from_utf8_lossy(&output.stderr);

    if !output.status.success() {
        // The helper writes structured errors to stdout; surface those first.
        if let Ok(parsed) = serde_json::from_str::<RoiHelperResult>(stdout.trim()) {
            if let Some(msg) = parsed.error {
                return Err(format!("ImageJ ROI export failed: {msg}"));
            }
        }
        let combined = if stderr.trim().is_empty() {
            stdout.trim()
        } else {
            stderr.trim()
        };
        let code = output.status.code().unwrap_or(-1);
        let preview: String = combined.chars().take(400).collect();
        return Err(format!("ImageJ ROI export failed (exit {code}): {preview}"));
    }

    // Exit 0 but ok=false ⇒ still an error the helper reported explicitly.
    if let Ok(parsed) = serde_json::from_str::<RoiHelperResult>(stdout.trim()) {
        if !parsed.ok {
            if let Some(msg) = parsed.error {
                return Err(format!("ImageJ ROI export failed: {msg}"));
            }
        }
    }

    Ok(resolved.to_string_lossy().into_owned())
}
