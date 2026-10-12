//! Resolve the immutable analysis source selection before rendering an overlay.
use super::provenance::ExportContext;
use crate::{analysis::runner::AssayManager, paths::FileStore};
use rusqlite::Connection;
use serde_json::Value;
use std::path::PathBuf;
use tauri::{AppHandle, State};

pub(crate) struct TemporaryDisplay(pub PathBuf);
impl Drop for TemporaryDisplay {
    fn drop(&mut self) {
        let _ = std::fs::remove_file(&self.0);
    }
}

pub(crate) fn capture(
    conn: &Connection,
    store: &FileStore,
    context: &ExportContext,
) -> Result<Option<Value>, String> {
    // Reconstruct even the default plane: the import preview is a mutable
    // derivative, and only the source helper verifies the recorded source hash.
    if !context.run_parameters.is_object() {
        return Err("This historical analysis has no saved source selection. Rerun a saved setup before exporting a source-aligned overlay.".into());
    }
    let mut request = crate::parity::source_request(conn, store, &context.image_id)?;
    crate::parity::captured_plane_options(
        &mut request,
        &context.run_parameters,
        context.detector_id.as_deref().unwrap_or(""),
    );
    if let Some(object) = request.as_object_mut() {
        object.remove("cells");
    }
    Ok(Some(request))
}
pub(crate) async fn prepare(
    app: AppHandle,
    manager: State<'_, AssayManager>,
    request: Option<Value>,
) -> Result<Option<TemporaryDisplay>, String> {
    let Some(request) = request else {
        return Ok(None);
    };
    crate::parity::prepare_export_display(app, manager, request, uuid::Uuid::new_v4().to_string())
        .await
        .map(|path| Some(TemporaryDisplay(path)))
}
