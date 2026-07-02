//! export/csv.rs — CSV export (cells / summary / annotations) (feature `export`). STUB.
//!
//! Port of the Swift `ExportService` CSV writers. Three flavours (§4):
//!   * per-cell measurements (Results)
//!   * per-image batch summary (Batch)
//!   * comparison export (Compare)
//! plus ground-truth annotations. STUBs with real signatures + `#[command]`
//! registration; the `export` feature engineer fills the bodies.

use crate::db::models::CellDto;

/// What kind of CSV to write. Serialized camelCase from the UI.
#[derive(Debug, Clone, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum CsvKind {
    Cells,
    BatchSummary,
    Comparison,
    Annotations,
}

/// Write a per-cell CSV for `image_id` to `out_path`. Returns the written path.
#[tauri::command]
pub async fn export_cells_csv(
    _image_id: String,
    _cells: Vec<CellDto>,
    _px_per_um: f64,
    _out_path: String,
) -> Result<String, String> {
    Err("not implemented: export_cells_csv (feature export)".into())
}

/// Write a per-image batch-summary CSV for `batch_id` to `out_path`.
#[tauri::command]
pub async fn export_batch_summary_csv(
    _batch_id: String,
    _out_path: String,
) -> Result<String, String> {
    Err("not implemented: export_batch_summary_csv (feature export)".into())
}
