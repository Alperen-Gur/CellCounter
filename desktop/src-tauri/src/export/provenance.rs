//! export/provenance.rs — provenance sidecar writer (feature `export`). STUB.
//!
//! Writes a machine-readable provenance record alongside every export: the
//! model id + version, calibration value + its source (EXIF/preset/manual),
//! thresholds, params, sidecar/app versions, and the source image hash — so a
//! result can be traced back to exactly how it was produced. STUB with the real
//! signature + `#[command]` registration; the `export` feature engineer fills
//! the body.

/// Write a provenance JSON sidecar for a detection on `image_id` to `out_path`.
/// Returns the written path.
#[tauri::command]
pub async fn export_provenance(
    _image_id: String,
    _out_path: String,
) -> Result<String, String> {
    Err("not implemented: export_provenance (feature export)".into())
}
