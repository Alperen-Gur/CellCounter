//! export/report.rs — PDF report generator (feature `export`). STUB.
//!
//! Port of the Swift `PDFReportGenerator`: a per-image or per-batch PDF with the
//! overlay render, size histogram, size-class breakdown, QC badges, and the
//! provenance footer. STUB with the real signature + `#[command]` registration;
//! the `export` feature engineer fills the body (likely via a headless print of
//! a report HTML, or a Rust PDF crate).

/// Render a PDF report for `image_id` (per-image) to `out_path`. Returns the
/// written path.
#[tauri::command]
pub async fn export_pdf_report(
    _image_id: String,
    _out_path: String,
) -> Result<String, String> {
    Err("not implemented: export_pdf_report (feature export)".into())
}
