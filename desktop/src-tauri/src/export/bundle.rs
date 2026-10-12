//! Snapshot-based text reports, ground truth, and local sample folders.
use super::provenance::{open_reader, resolve_out_path, ExportContext, Provenance};
use crate::db::repo::Db;
use crate::paths::FileStore;
use rusqlite::{Connection, OptionalExtension};
use serde::Serialize;
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::{
    collections::{BTreeMap, HashSet},
    io::{Read, Write},
    path::{Path, PathBuf},
};
use tauri::{AppHandle, State};

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct Annotation {
    id: String,
    x: f64,
    y: f64,
    diameter_um: Option<f64>,
    note: Option<String>,
}
fn annotations(conn: &Connection, id: &str) -> Result<Vec<Annotation>, String> {
    let mut query=conn.prepare("SELECT id,cx,cy,diameter,note FROM ground_truth_annotations WHERE image_id=?1 ORDER BY created_at,id LIMIT 100001").map_err(|e|e.to_string())?;
    let rows = query
        .query_map([id], |r| {
            Ok(Annotation {
                id: r.get(0)?,
                x: r.get(1)?,
                y: r.get(2)?,
                diameter_um: r.get(3)?,
                note: r.get(4)?,
            })
        })
        .map_err(|e| e.to_string())?;
    let values = rows
        .collect::<Result<Vec<_>, _>>()
        .map_err(|e| e.to_string())?;
    if values.len() > 100_000 {
        return Err("Ground truth exceeds the export budget".into());
    }
    if values.iter().any(|p| {
        !p.x.is_finite()
            || !p.y.is_finite()
            || p.diameter_um.is_some_and(|d| !d.is_finite() || d <= 0.0)
    }) {
        return Err("Ground-truth geometry is invalid".into());
    }
    Ok(values)
}
fn csv(value: &str) -> String {
    let literal = if value.trim_start().starts_with(['=', '+', '-', '@']) {
        format!("'{value}")
    } else {
        value.to_owned()
    };
    format!("\"{}\"", literal.replace('"', "\"\""))
}
fn annotation_csv(points: &[Annotation]) -> String {
    let mut out = String::from("id,x_px,y_px,diameter_um,note\r\n");
    for p in points {
        out.push_str(&format!(
            "{},{},{},{},{}\r\n",
            csv(&p.id),
            p.x,
            p.y,
            p.diameter_um.map(|d| d.to_string()).unwrap_or_default(),
            csv(p.note.as_deref().unwrap_or(""))
        ));
    }
    out
}
fn md(value: &str) -> String {
    let mut out = String::new();
    for c in value.chars() {
        match c {
            '\n' | '\r' => out.push(' '),
            '&' => out.push_str("&amp;"),
            '<' => out.push_str("&lt;"),
            '>' => out.push_str("&gt;"),
            c if "\\`*_{}[]()#+.!|~-".contains(c) => {
                out.push('\\');
                out.push(c);
            }
            _ => out.push(c),
        }
    }
    out
}
fn run_record(conn: &Connection, image_id: &str) -> Result<Value, String> {
    let saved: Option<String> = conn
        .query_row(
            "SELECT document_json FROM workflow_documents WHERE key=?1",
            [format!("run-{image_id}")],
            |r| r.get(0),
        )
        .optional()
        .map_err(|e| e.to_string())?;
    saved
        .map(|s| serde_json::from_str(&s).map_err(|e| e.to_string()))
        .transpose()
        .map(|v| v.unwrap_or(Value::Null))
}
fn provenance(ctx: &ExportContext, cutoff: f64, run: &Value) -> Result<Value, String> {
    let mut value: Value = serde_json::from_str(&Provenance::capture(ctx, cutoff).as_json())
        .map_err(|e| e.to_string())?;
    // Unknown historical preprocessing is unknown, never an invented false flag.
    value["background_subtract"] = run["params"]["backgroundSubtract"].clone();
    value["watershed_split"] = run["params"]["watershedSplit"].clone();
    value["run"] = run.clone();
    Ok(value)
}
fn markdown(ctx: &ExportContext, cutoff: f64, points: &[Annotation], prov: &Value) -> String {
    let count = ctx.visible_cells(cutoff).len();
    format!("# {}\n\nObjects above confidence threshold: {}\n\nCalibration: {} px/µm ({})\n\nModel: {}\n\nGround-truth marks: {}\n\n## Provenance\n\n{}\n",md(&ctx.file_name),count,ctx.px_per_um,md(&ctx.px_per_um_source),md(&ctx.run_model_id),points.len(),prov.as_object().map(|m|m.iter().map(|(k,v)|format!("- **{}:** {}",md(k),md(&v.to_string()))).collect::<Vec<_>>().join("\n")).unwrap_or_default())
}
fn context(
    conn: &Connection,
    store: &FileStore,
    id: &str,
    confidence: Option<f64>,
    cell_ids: Option<&[String]>,
) -> Result<(ExportContext, f64), String> {
    uuid::Uuid::parse_str(id).map_err(|_| "Invalid image identity")?;
    let mut ctx = ExportContext::load(conn, store, id)?;
    let mut vertices = 0usize;
    if ctx.cells.len() > 100_000 {
        return Err("Sample export exceeds 100,000 objects".into());
    }
    for cell in &ctx.cells {
        if ![
            cell.cx,
            cell.cy,
            cell.diameter_px,
            cell.diameter_um,
            cell.confidence,
        ]
        .iter()
        .all(|n| n.is_finite())
            || cell.diameter_px <= 0.0
            || cell.diameter_um <= 0.0
        {
            return Err("A saved object contains invalid measurements".into());
        }
        if let Some(points) = &cell.contour_px {
            vertices = vertices.saturating_add(points.len());
            if vertices > 1_000_000
                || points
                    .iter()
                    .any(|p| !p[0].is_finite() || !p[1].is_finite())
            {
                return Err("Sample geometry exceeds its finite-coordinate budget".into());
            }
        }
    }
    let cutoff = ctx.effective_confidence(confidence.unwrap_or(0.5));
    if !cutoff.is_finite()
        || !(0.0..=1.0).contains(&cutoff)
        || !ctx.px_per_um.is_finite()
        || ctx.px_per_um <= 0.0
    {
        return Err("Export confidence/calibration is invalid".into());
    }
    if let Some(ids) = cell_ids {
        let selected: HashSet<&str> = ids.iter().map(String::as_str).collect();
        let saved: HashSet<&str> = ctx.cells.iter().map(|cell| cell.id.as_str()).collect();
        if selected.len() != ids.len() || !selected.iter().all(|id| saved.contains(id)) {
            return Err("The selected results changed. Reload before exporting".into());
        }
        ctx.cells.retain(|c| selected.contains(c.id.as_str()));
    }
    Ok((ctx, cutoff))
}
fn write_atomic(path: &Path, bytes: &[u8]) -> Result<(), String> {
    let temporary = path.with_extension(format!("{}.partial", uuid::Uuid::new_v4()));
    let result = (|| -> std::io::Result<()> {
        let mut file = std::fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(&temporary)?;
        file.write_all(bytes)?;
        file.sync_all()?;
        drop(file);
        std::fs::rename(&temporary, path)
    })();
    if let Err(error) = result {
        let _ = std::fs::remove_file(&temporary);
        return Err(error.to_string());
    }
    Ok(())
}
#[tauri::command]
pub async fn export_markdown_report(
    app: AppHandle,
    image_id: String,
    confidence: Option<f64>,
    cell_ids: Option<Vec<String>>,
    out_path: String,
) -> Result<String, String> {
    let store = FileStore::from_app(&app)?;
    tauri::async_runtime::spawn_blocking(move || {
        let conn = open_reader(&store)?;
        conn.execute_batch("BEGIN DEFERRED TRANSACTION")
            .map_err(|e| e.to_string())?;
        let (ctx, cutoff) = context(&conn, &store, &image_id, confidence, cell_ids.as_deref())?;
        let points = annotations(&conn, &image_id)?;
        let run = run_record(&conn, &image_id)?;
        let body = markdown(&ctx, cutoff, &points, &provenance(&ctx, cutoff, &run)?);
        let target = resolve_out_path(&store, &out_path)?;
        write_atomic(&target, body.as_bytes())?;
        Ok(target.to_string_lossy().into_owned())
    })
    .await
    .map_err(|e| e.to_string())?
}
#[tauri::command]
pub async fn export_ground_truth(
    app: AppHandle,
    image_id: String,
    format: String,
    out_path: String,
) -> Result<String, String> {
    let store = FileStore::from_app(&app)?;
    tauri::async_runtime::spawn_blocking(move|| { let conn=open_reader(&store)?;conn.execute_batch("BEGIN DEFERRED TRANSACTION").map_err(|e|e.to_string())?;
        let (ctx,_)=context(&conn,&store,&image_id,None,None)?;let points=annotations(&conn,&image_id)?;
        let body=match format.as_str() { "csv"=>annotation_csv(&points),"json"=>serde_json::to_string_pretty(&json!({"schemaVersion":1,"imageId":image_id,"sourceSha256":ctx.file_hash,"coordinateSpace":"source-pixels","pxPerUm":ctx.px_per_um,"annotations":points})).map_err(|e|e.to_string())?,_=>return Err("Choose CSV or JSON ground truth".into()) };
        let target=resolve_out_path(&store,&out_path)?;write_atomic(&target,body.as_bytes())?;Ok(target.to_string_lossy().into_owned())
    }).await.map_err(|e|e.to_string())?
}
#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SampleBundleResult {
    path: String,
    warnings: Vec<String>,
}
struct PartialFolder(PathBuf);
impl Drop for PartialFolder {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}
fn copy_source(source: &Path, destination: &Path) -> Result<String, String> {
    let mut input = std::fs::File::open(source).map_err(|e| e.to_string())?;
    if input.metadata().map_err(|e| e.to_string())?.len() > 2 * 1024 * 1024 * 1024 {
        return Err("Sample source exceeds the 2 GiB copy budget".into());
    }
    let mut output = std::fs::OpenOptions::new()
        .create_new(true)
        .write(true)
        .open(destination)
        .map_err(|e| e.to_string())?;
    let mut buffer = vec![0u8; 1024 * 1024];
    let mut hash = Sha256::new();
    let mut total = 0u64;
    loop {
        let count = input.read(&mut buffer).map_err(|e| e.to_string())?;
        if count == 0 {
            break;
        }
        total += count as u64;
        if total > 2 * 1024 * 1024 * 1024 {
            return Err("Source grew beyond the copy budget".into());
        }
        hash.update(&buffer[..count]);
        output
            .write_all(&buffer[..count])
            .map_err(|e| e.to_string())?;
    }
    output.sync_all().map_err(|e| e.to_string())?;
    Ok(format!("{:x}", hash.finalize()))
}
#[tauri::command]
pub async fn export_sample_bundle(
    app: AppHandle,
    manager: State<'_, crate::analysis::runner::AssayManager>,
    db: State<'_, Db>,
    image_id: String,
    confidence: Option<f64>,
    cell_ids: Option<Vec<String>>,
    overlay_mode: String,
    out_dir: String,
) -> Result<SampleBundleResult, String> {
    let store = FileStore::from_app(&app)?;
    let roi_image_id = image_id.clone();
    let snapshot_store = store.clone();
    let snapshot_id = image_id.clone();
    let (mut ctx, cutoff, points, prov, report, display_request, dimensions) =
        tauri::async_runtime::spawn_blocking(move || {
            let conn = open_reader(&snapshot_store)?;
            conn.execute_batch("BEGIN DEFERRED TRANSACTION")
                .map_err(|e| e.to_string())?;
            let (ctx, cutoff) = context(
                &conn,
                &snapshot_store,
                &snapshot_id,
                confidence,
                cell_ids.as_deref(),
            )?;
            let points = annotations(&conn, &snapshot_id)?;
            let run = run_record(&conn, &snapshot_id)?;
            let prov = provenance(&ctx, cutoff, &run)?;
            let report = super::report::capture_report(&conn, &ctx, cutoff)?;
            let request = super::display::capture(&conn, &snapshot_store, &ctx);
            let dimensions: (i64, i64) = conn
                .query_row(
                    "SELECT width_px,height_px FROM images WHERE id=?1",
                    [&snapshot_id],
                    |r| Ok((r.get(0)?, r.get(1)?)),
                )
                .map_err(|e| e.to_string())?;
            Ok::<_, String>((ctx, cutoff, points, prov, report, request, dimensions))
        })
        .await
        .map_err(|e| e.to_string())??;
    let original_stored_path = ctx.stored_path.clone();
    let display = match display_request {
        Ok(request) => super::display::prepare(app.clone(), manager, request).await,
        Err(error) => Err(error),
    };
    let mut display_warnings = Vec::new();
    let prepared_display = match display {
        Ok(value) => value,
        Err(error) => {
            display_warnings.push(format!("Overlay omitted: {error}"));
            None
        }
    };
    if let Some(display) = &prepared_display {
        ctx.stored_path = display.0.clone();
    }
    let has_display = display_warnings.is_empty();
    let (mut result, roi_cells, dimensions) = tauri::async_runtime::spawn_blocking(move|| {
        let _display_guard=prepared_display;
        let parent=if out_dir.trim().is_empty(){store.exports_dir()}else{resolve_out_path(&store,&out_dir)?};std::fs::create_dir_all(&parent).map_err(|e|e.to_string())?;
        let name=format!("sample-{}",uuid::Uuid::new_v4());let target=parent.join(&name);let temporary=parent.join(format!(".{name}.partial"));std::fs::create_dir(&temporary).map_err(|e|e.to_string())?;let _guard=PartialFolder(temporary.clone());
        let mut hashes=BTreeMap::new();let mut warnings=display_warnings;
        let mut add=|name:&str,bytes:&[u8]|->Result<(),String>{write_atomic(&temporary.join(name),bytes)?;hashes.insert(name.to_owned(),format!("{:x}",Sha256::digest(bytes)));Ok(())};
        add("report.md",markdown(&ctx,cutoff,&points,&prov).as_bytes())?;
        add("provenance.json",&serde_json::to_vec_pretty(&prov).map_err(|e|e.to_string())?)?;
        add("annotations.csv",annotation_csv(&points).as_bytes())?;
        add("annotations.json",&serde_json::to_vec_pretty(&json!({"schemaVersion":1,"coordinateSpace":"source-pixels","imageId":image_id,"annotations":points})).map_err(|e|e.to_string())?)?;
        add("geometry.json",&serde_json::to_vec_pretty(&json!({"coordinateSpace":"source-pixels","cells":ctx.visible_cells(cutoff)})).map_err(|e|e.to_string())?)?;
        let captured=Provenance::capture(&ctx,cutoff);
        add("cells.csv",super::csv::build_cells_csv(&ctx.cells,&ctx.file_name,&ctx.thresholds,ctx.px_per_um,cutoff,&ctx.run_model_id,&captured).as_bytes())?;
        add("summary.csv",format!("image_id,file_name,objects,px_per_um\r\n{},{},{},{}\r\n",csv(&image_id),csv(&ctx.file_name),ctx.visible_cells(cutoff).len(),ctx.px_per_um).as_bytes())?;
        if has_display { match super::annotated::render_file(&ctx.stored_path,&ctx.cells,&ctx.thresholds,cutoff,&overlay_mode) {Ok(bytes)=>add("annotated.png",&bytes)?,Err(error)=>warnings.push(format!("annotated.png: {error}"))} }
        let pdf = match super::report::render_report(&ctx,cutoff,&report,has_display) {
            Ok(bytes) => bytes,
            Err(error) => { warnings.push(format!("PDF image omitted: {error}")); super::report::render_report(&ctx,cutoff,&report,false)? }
        };
        add("report.pdf", &pdf)?;
        drop(add);
        let extension=Path::new(&ctx.file_name).extension().and_then(|e|e.to_str()).filter(|e|!e.is_empty() && e.len()<=16 && e.chars().all(|c|c.is_ascii_alphanumeric())).unwrap_or("bin").to_ascii_lowercase();
        let source=if ctx.analysis_path.is_some(){store.original_path(&image_id,&extension)}else{original_stored_path};let original_name=format!("original.{extension}");let source_hash=copy_source(&source,&temporary.join(&original_name))?;
        if ctx.file_hash.as_ref().is_some_and(|expected|!expected.eq_ignore_ascii_case(&source_hash)) {return Err("Preserved source failed its recorded SHA-256 identity check".into());}
        hashes.insert(original_name,source_hash);
        let roi_cells = ctx.visible_cells(cutoff).into_iter().cloned().collect::<Vec<_>>();
        let manifest=json!({"schemaVersion":1,"imageId":image_id,"originalFileName":ctx.file_name,"files":hashes,"warnings":warnings});write_atomic(&temporary.join("manifest.json"),&serde_json::to_vec_pretty(&manifest).map_err(|e|e.to_string())?)?;
        std::fs::rename(&temporary,&target).map_err(|e|e.to_string())?;Ok::<_,String>((SampleBundleResult{path:target.to_string_lossy().into_owned(),warnings}, roi_cells, dimensions))
    }).await.map_err(|e|e.to_string())??;
    let roi_path = Path::new(&result.path).join("imagej_rois.zip");
    if !roi_cells.is_empty() {
        if let Err(error) = super::roi::export_imagej_roi(
            app,
            db,
            roi_image_id,
            roi_cells,
            dimensions.0,
            dimensions.1,
            roi_path.to_string_lossy().into_owned(),
        )
        .await
        {
            let _ = std::fs::remove_file(&roi_path);
            result.warnings.push(format!("imagej_rois.zip: {error}"));
        }
    }
    let manifest_path = Path::new(&result.path).join("manifest.json");
    let update = (|| -> Result<(), String> {
        let mut manifest: Value =
            serde_json::from_slice(&std::fs::read(&manifest_path).map_err(|e| e.to_string())?)
                .map_err(|e| e.to_string())?;
        if roi_path.is_file() {
            let bytes = std::fs::read(&roi_path).map_err(|e| e.to_string())?;
            manifest["files"]["imagej_rois.zip"] = json!(format!("{:x}", Sha256::digest(bytes)));
        }
        manifest["warnings"] = json!(result.warnings);
        write_atomic(
            &manifest_path,
            &serde_json::to_vec_pretty(&manifest).map_err(|e| e.to_string())?,
        )
    })();
    if let Err(error) = update {
        result
            .warnings
            .push(format!("Manifest finalization: {error}"));
    }
    Ok(result)
}
