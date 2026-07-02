//! detection/seg_npy.rs — `_seg.npy` round-trip (feature `seg-npy-io`). STUB.
//!
//! Round-trips masks with the Cellpose GUI's `_seg.npy` format so users can move
//! work between CellCounter and Cellpose. Kept lossless per the train-from-GUI
//! seam (ARCHITECTURE.md §3.5 note): a later fine-tuning feature consumes
//! `corrections` + `_seg.npy` masks.
//!
//! These are STUBS with the real signatures + `#[command]` registration so the
//! app compiles now; the `seg-npy-io` feature engineer fills the bodies.

use crate::db::models::CellDto;

/// Import a Cellpose `_seg.npy` for `image_id`, returning the decoded cells
/// (source-px contours). Bodies land with the `seg-npy-io` feature.
#[tauri::command]
pub async fn seg_npy_import(
    _image_id: String,
    _npy_path: String,
) -> Result<Vec<CellDto>, String> {
    Err("not implemented: seg_npy_import (feature seg-npy-io)".into())
}

/// Export the current cells for `image_id` to a Cellpose-compatible `_seg.npy`
/// at `out_path`. Returns the written path. Bodies land with `seg-npy-io`.
#[tauri::command]
pub async fn seg_npy_export(
    _image_id: String,
    _cells: Vec<CellDto>,
    _out_path: String,
) -> Result<String, String> {
    Err("not implemented: seg_npy_export (feature seg-npy-io)".into())
}
