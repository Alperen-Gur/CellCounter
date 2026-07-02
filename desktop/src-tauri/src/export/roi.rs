//! export/roi.rs — ImageJ RoiSet export (feature `export`). STUB.
//!
//! Invokes the existing `desktop/python/_export_imagej_roi.py` helper (copied
//! from the Swift app) to write an ImageJ-compatible `RoiSet.zip` — one `.roi`
//! per cell (polygon when a `contour_px` exists, else oval). The helper's CLI:
//!   `python _export_imagej_roi.py --in detection.json --out RoiSet.zip`
//! and its input JSON schema are documented in that file's header.
//!
//! STUB with the real signature + `#[command]` registration; the `export`
//! feature engineer builds the JSON, spawns the helper from the venv, and
//! returns the written path.

use crate::db::models::CellDto;

/// Export `cells` for `image_id` (with `image_width`/`image_height`) to an
/// ImageJ `RoiSet.zip` at `out_path`. Returns the written path.
#[tauri::command]
pub async fn export_imagej_roi(
    _image_id: String,
    _cells: Vec<CellDto>,
    _image_width: i64,
    _image_height: i64,
    _out_path: String,
) -> Result<String, String> {
    Err("not implemented: export_imagej_roi (feature export)".into())
}
