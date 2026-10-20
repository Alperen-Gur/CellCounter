//! Local host seams for source inspection and portable microscopy documents.
use crate::export::provenance::{open_reader, resolve_out_path, ExportContext};
use crate::{
    analysis::runner::{self, AssayManager},
    db::repo::Db,
    paths::FileStore,
};
use rusqlite::OptionalExtension;
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::path::{Component, Path};
use tauri::{AppHandle, State};

pub(crate) fn review_fingerprint(conn: &rusqlite::Connection, id: &str) -> Result<String, String> {
    let value: String=conn.query_row("SELECT CASE WHEN length(CAST(d.cells_json AS BLOB))>33554432 THEN NULL ELSE json_array(d.id,d.cells_json,d.detector_id,i.file_hash,i.width_px,i.height_px,i.analysis_path,b.px_per_um,b.thresholds_json,b.model_id,(SELECT document_json FROM workflow_documents WHERE key='run-' || i.id)) END FROM images i LEFT JOIN detections d ON d.image_id=i.id LEFT JOIN batches b ON i.batch_id=b.id WHERE i.id=?1",[id],|row|row.get(0)).map_err(|e|e.to_string())?;
    Ok(format!("{:x}", Sha256::digest(value.as_bytes())))
}

pub(crate) fn source_request(
    conn: &rusqlite::Connection,
    store: &FileStore,
    image_id: &str,
) -> Result<Value, String> {
    let context = ExportContext::load(conn, store, image_id)?;
    let source = if context.analysis_path.is_some() {
        let extension = Path::new(&context.file_name)
            .extension()
            .and_then(|v| v.to_str())
            .unwrap_or("")
            .to_ascii_lowercase();
        store.original_path(image_id, &extension)
    } else {
        context.stored_path
    };
    if !source.is_file() {
        return Err("The preserved source is missing. Reimport the image.".into());
    }
    let (width, height): (i64, i64) = conn
        .query_row(
            "SELECT width_px,height_px FROM images WHERE id=?1",
            [image_id],
            |row| Ok((row.get(0)?, row.get(1)?)),
        )
        .map_err(|e| e.to_string())?;
    if width <= 0 || height <= 0 || width.checked_mul(height).is_none_or(|v| v > 16_000_000) {
        return Err("Source inspection supports up to 16 megapixels. Use a lower-resolution workspace level.".into());
    }
    Ok(
        json!({"sourceWidth":width,"sourceHeight":height,"imageId":image_id,"sourcePath":source,"sourceHash":context.file_hash,"pxPerUm":context.px_per_um,"calibrationSource":context.px_per_um_source,"detectorId":context.detector_id,"cells":context.cells}),
    )
}

pub(crate) fn sequence_selection(conn: &rusqlite::Connection, id: &str) -> Result<Value, String> {
    let row:Option<(String,String)>=conn.query_row("SELECT d.detector_id,w.document_json FROM detections d JOIN workflow_documents w ON w.key='run-' || d.image_id WHERE d.image_id=?1",[id],|r|Ok((r.get(0)?,r.get(1)?))).optional().map_err(|e|e.to_string())?;
    let Some((detector, raw)) = row else {
        return Ok(Value::Null);
    };
    let run: Value = serde_json::from_str(&raw).map_err(|e| e.to_string())?;
    if run["version"] != 1 || !run["params"].is_object() {
        return Ok(Value::Null);
    }
    let mut options = json!({});
    captured_plane_options(&mut options, &run["params"], &detector);
    Ok(options)
}

#[tauri::command]
pub fn sequence_snapshot(db: State<'_, Db>, image_ids: Vec<String>) -> Result<Vec<Value>, String> {
    if image_ids.is_empty() || image_ids.len() > 512 {
        return Err("Use 1 to 512 sequence frames".into());
    }
    let mut conn = db.connection()?;
    let tx = conn.transaction().map_err(|e| e.to_string())?;
    let mut output = Vec::new();
    let mut bytes = 0usize;
    let mut count = 0usize;
    let mut ids = std::collections::HashSet::new();
    for id in image_ids {
        if !ids.insert(id.clone()) {
            return Err("Duplicate sequence frame".into());
        }
        let (width,height,scale):(i64,i64,f64)=tx.query_row("SELECT i.width_px,i.height_px,b.px_per_um FROM images i JOIN batches b ON i.batch_id=b.id WHERE i.id=?1",[&id],|r|Ok((r.get(0)?,r.get(1)?,r.get(2)?))).map_err(|e|e.to_string())?;
        if !scale.is_finite() || scale <= 0.0 {
            return Err("Sequence calibration must be positive".into());
        }
        let row:Option<(String,String,String,String,Option<String>)>=tx.query_row("SELECT id,detector_id,ran_at,CASE WHEN length(CAST(cells_json AS BLOB))<=33554432 THEN cells_json ELSE NULL END,image_stats_json FROM detections WHERE image_id=?1",[&id],|r|Ok((r.get(0)?,r.get(1)?,r.get(2)?,r.get(3)?,r.get(4)?))).optional().map_err(|e|e.to_string())?;
        let detection = if let Some((detection_id, detector_id, ran_at, cells, stats)) = row {
            bytes = bytes.saturating_add(cells.len());
            let cells =
                crate::db::models::cells_from_json_checked(&cells).map_err(|e| e.to_string())?;
            count = count.saturating_add(cells.len());
            if bytes > 32 * 1024 * 1024 || count > 200_000 {
                return Err("Sequence exceeds 32 MiB or 200,000 masks".into());
            }
            json!(crate::db::models::DetectionDto {
                id: detection_id,
                image_id: id.clone(),
                detector_id,
                ran_at,
                cells,
                image_stats: stats.and_then(|v| serde_json::from_str(&v).ok())
            })
        } else {
            Value::Null
        };
        output.push(json!({"imageId":id,"width":width,"height":height,"pxPerUm":scale,"fingerprint":review_fingerprint(&tx,&id)?,"sourceSelection":sequence_selection(&tx,&id)?,"detection":detection}));
    }
    tx.commit().map_err(|e| e.to_string())?;
    Ok(output)
}

pub(crate) fn captured_plane_options(request: &mut Value, params: &Value, detector_id: &str) {
    request["projection"] = params["zProjection"]
        .as_str()
        .map(|v| json!(v))
        .unwrap_or(json!("max"));
    request["channel"] = params["segmentChannel"].clone();
    request["timeIndex"] = json!(0);
    request["zIndex"] = Value::Null;
    let model_id=params["modelId"].as_str().unwrap_or("");
    if model_id.starts_with("sd-") {
        request["sourcePolicy"] = json!("rgbMeanIfAutomatic");
    } else if detector_id.starts_with("stardist/") || detector_id.starts_with("classical/") {
        request["sourcePolicy"] = json!("legacyRgbMean");
        request["detectionChannels"] = params["channels"].clone();
    }
    // Cellpose's primary RGB slot is selected after source-channel reordering.
    // CP4, classical, StarDist and Omnipose have their own scalar source policy.
    if detector_id.starts_with("cellpose/")
        || detector_id.starts_with("omnipose/")
        || (detector_id.starts_with("custom/") && params["channels"].is_array())
    {
        let id = params["modelId"].as_str().unwrap_or("");
        if !matches!(
            id,
            "cpsam" | "cpsam_v2" | "cp4-cpsam" | "cp4-cpsam_v2" | "cp4-cpdino" | "cp4-cpdino-vitb"
        ) {
            request["detectionChannels"] = params["channels"].clone();
        }
    }
}

#[tauri::command]
pub async fn parity_source(
    app: AppHandle,
    db: State<'_, Db>,
    manager: State<'_, AssayManager>,
    image_id: String,
    operation: String,
    mut request: Value,
    run_id: String,
) -> Result<Value, String> {
    uuid::Uuid::parse_str(&run_id).map_err(|_| "Source run ID must be a UUID")?;
    if !["source", "prompt", "channels"].contains(&operation.as_str()) {
        return Err("Unsupported source operation".into());
    }
    let store = FileStore::from_app(&app)?;
    let conn = open_reader(&store)?;
    let canonical = source_request(&conn, &store, &image_id)?;
    let map = request
        .as_object_mut()
        .ok_or("Source options must be an object")?;
    for (key, value) in canonical.as_object().ok_or("Invalid source record")? {
        map.insert(key.clone(), value.clone());
    }
    if map.get("workspaceExact").and_then(Value::as_bool) == Some(true)
        && canonical["sourceWidth"].as_u64().unwrap_or(0)
            * canonical["sourceHeight"].as_u64().unwrap_or(0)
            > 4_000_000
    {
        return Err("Exact workspace source planes support up to four megapixels".into());
    }
    if operation != "source" {
        let raw: Option<String> = conn
            .query_row(
                "SELECT document_json FROM workflow_documents WHERE key=?1",
                [format!("run-{image_id}")],
                |r| r.get(0),
            )
            .optional()
            .map_err(|e| e.to_string())?;
        let run=raw.and_then(|v|serde_json::from_str::<Value>(&v).ok()).filter(|v|v["version"]==1 && v["params"].is_object()).ok_or("Rerun a saved setup before applying source-mask workflows; this historical run has no captured source selection")?;
        let detector = canonical["detectorId"].as_str().unwrap_or("").to_owned();
        let mut options = json!({});
        captured_plane_options(&mut options, &run["params"], &detector);
        for (key, value) in options
            .as_object()
            .ok_or("Invalid captured source options")?
        {
            map.insert(key.clone(), value.clone());
        }
    }
    map.insert("operation".into(), Value::String(operation.clone()));
    let preview = store.analysis_dir().join(format!("preview-{run_id}.png"));
    // Source preview files are scoped to the asset protocol and are released
    // by the viewer after replacement/unmount; source files remain untouched.
    map.insert("previewPath".into(), json!(preview));
    let _ = &db;
    let result = runner::run_assay(
        app,
        manager,
        "parity".into(),
        vec![],
        Some(request.to_string()),
        run_id,
    )
    .await;
    if result.is_err() {
        let _ = std::fs::remove_file(preview);
    }
    result
}

#[tauri::command]
pub fn release_source_preview(app: AppHandle, path: String) -> Result<(), String> {
    let store = FileStore::from_app(&app)?;
    let candidate = Path::new(&path);
    if candidate.parent() != Some(store.analysis_dir().as_path())
        || !candidate
            .file_name()
            .and_then(|v| v.to_str())
            .is_some_and(|v| v.starts_with("preview-") && v.ends_with(".png"))
    {
        return Err("Invalid preview path".into());
    }
    match std::fs::remove_file(candidate) {
        Ok(()) => Ok(()),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(()),
        Err(e) => Err(e.to_string()),
    }
}

#[tauri::command]
pub async fn export_reviewed_dataset(
    app: AppHandle,
    db: State<'_, Db>,
    manager: State<'_, AssayManager>,
    selections: Vec<Value>,
    out_dir: String,
    run_id: String,
) -> Result<Value, String> {
    uuid::Uuid::parse_str(&run_id).map_err(|_| "Dataset run ID must be a UUID")?;
    if selections.is_empty() || selections.len() > 512 {
        return Err("Choose 1 to 512 reviewed images".into());
    }
    let store = FileStore::from_app(&app)?;
    let conn = open_reader(&store)?;
    conn.execute_batch("BEGIN DEFERRED TRANSACTION")
        .map_err(|e| e.to_string())?;
    let mut samples = Vec::new();
    let mut sample_bytes = 0usize;
    let mut total_cells = 0usize;
    let mut vertices = 0usize;
    let mut pixels = 0u64;
    let mut ids = std::collections::HashSet::new();
    for selection in selections {
        let id = selection
            .get("imageId")
            .and_then(Value::as_str)
            .ok_or("Missing image identity")?;
        if !ids.insert(id.to_owned()) {
            return Err("Duplicate selection".into());
        }
        let group = selection
            .get("group")
            .and_then(Value::as_str)
            .filter(|g| !g.trim().is_empty() && g.len() <= 128)
            .ok_or("Assign each image an independent specimen group")?;
        let mut sample = source_request(&conn, &store, id)?;
        if sample["cells"]
            .as_array()
            .is_none_or(|cells| cells.is_empty())
        {
            return Err("Every training image needs a nonempty reviewed mask".into());
        }
        let review: Option<String> = conn
            .query_row(
                "SELECT document_json FROM workflow_documents WHERE key=?1",
                [format!("advanced-{id}")],
                |row| row.get(0),
            )
            .optional()
            .map_err(|e| e.to_string())?;
        let review = review
            .and_then(|s| serde_json::from_str::<Value>(&s).ok())
            .ok_or("Mark each training image reviewed in Results before exporting")?;
        let detection_id: String = conn
            .query_row("SELECT id FROM detections WHERE image_id=?1", [id], |row| {
                row.get(0)
            })
            .map_err(|e| e.to_string())?;
        let digest = review_fingerprint(&conn, id)?;
        if review["reviewedDetectionId"].as_str() != Some(detection_id.as_str())
            || review["reviewedDetectionHash"].as_str() != Some(digest.as_str())
        {
            return Err("The image changed after review; review it again before exporting".into());
        }
        sample["group"] = json!(group.trim());
        sample["reviewConfidence"] = review["reviewConfidence"].clone();
        let run: Option<String> = conn
            .query_row(
                "SELECT document_json FROM workflow_documents WHERE key=?1",
                [format!("run-{id}")],
                |row| row.get(0),
            )
            .optional()
            .map_err(|e| e.to_string())?;
        sample["run"]=run.and_then(|s|serde_json::from_str::<Value>(&s).ok()).filter(|v|v["version"]==1 && v["params"].is_object()).ok_or("Historical analysis has no captured source selection; rerun and review before training export")?;
        if sample["calibrationSource"]
            .as_str()
            .is_none_or(|v| v == "default")
            || review["reviewConfidence"].as_str() != Some("high")
        {
            return Err(
                "Training snapshots require verified calibration and high review confidence".into(),
            );
        }
        let params = sample["run"]["params"].clone();
        let detector = sample["detectorId"].as_str().unwrap_or("").to_owned();
        captured_plane_options(&mut sample, &params, &detector);
        sample_bytes = sample_bytes.saturating_add(
            serde_json::to_vec(&sample)
                .map_err(|e| e.to_string())?
                .len(),
        );
        let cells = sample["cells"]
            .as_array()
            .ok_or("Invalid reviewed geometry")?;
        total_cells = total_cells.saturating_add(cells.len());
        vertices = vertices.saturating_add(
            cells
                .iter()
                .map(|cell| cell["contourPx"].as_array().map_or(0, |p| p.len()))
                .sum::<usize>(),
        );
        pixels = pixels.saturating_add(
            sample["sourceWidth"]
                .as_u64()
                .unwrap_or(0)
                .saturating_mul(sample["sourceHeight"].as_u64().unwrap_or(0)),
        );
        if sample_bytes > 32 * 1024 * 1024
            || total_cells > 200_000
            || vertices > 500_000
            || pixels > 128_000_000
        {
            return Err("Training snapshot exceeds aggregate limits: 32 MiB metadata, 200,000 masks, 500,000 vertices or 128 megapixels; select fewer fields".into());
        }
        samples.push(sample);
    }
    conn.execute_batch("COMMIT").map_err(|e| e.to_string())?;
    let destination = resolve_out_path(&store, &out_dir)?;
    std::fs::create_dir_all(&destination).map_err(|e| e.to_string())?;
    let snapshot_id = uuid::Uuid::new_v4();
    let staging = destination.join(format!(".reviewed-{snapshot_id}.partial"));
    let request = json!({"operation":"dataset","outDir":destination,"snapshotId":snapshot_id,"samples":samples,"createdAt":chrono::Utc::now().to_rfc3339()});
    let _ = &db;
    let result = runner::run_assay(
        app,
        manager,
        "parity".into(),
        vec![],
        Some(request.to_string()),
        run_id,
    )
    .await;
    let publication = match result {
        Ok(mut result) => {
            let target = destination.join(format!("reviewed-{snapshot_id}"));
            if result["path"].as_str() != target.to_str()
                || result["stagingPath"].as_str() != staging.to_str()
            {
                Err("Training helper returned an unexpected publication path".into())
            } else {
                std::fs::rename(&staging, &target)
                    .map_err(|e| e.to_string())
                    .map(|_| {
                        if let Some(object) = result.as_object_mut() {
                            object.remove("stagingPath");
                        }
                        result
                    })
            }
        }
        Err(error) => Err(error),
    };
    if publication.is_err() {
        let _ = std::fs::remove_dir_all(&staging);
    }
    publication
}

#[tauri::command]
pub fn mark_image_reviewed(
    db: State<'_, Db>,
    image_id: String,
    confidence: String,
) -> Result<(), String> {
    if !["high", "medium", "low"].contains(&confidence.as_str()) {
        return Err("Choose high, medium, or low review confidence".into());
    }
    let mut conn = db.connection()?;
    let tx = conn.transaction().map_err(|e| e.to_string())?;
    let (id, _cells): (String, String) = tx
        .query_row(
            "SELECT id,cells_json FROM detections WHERE image_id=?1",
            [&image_id],
            |row| Ok((row.get(0)?, row.get(1)?)),
        )
        .map_err(|e| e.to_string())?;
    let key = format!("advanced-{image_id}");
    let existing: Option<String> = tx
        .query_row(
            "SELECT document_json FROM workflow_documents WHERE key=?1",
            [&key],
            |row| row.get(0),
        )
        .optional()
        .map_err(|e| e.to_string())?;
    let mut document = existing
        .map(|s| serde_json::from_str::<Value>(&s))
        .transpose()
        .map_err(|e| e.to_string())?
        .unwrap_or(json!({"version":1}));
    if !document.is_object() {
        return Err("Saved review document is damaged".into());
    }
    document["reviewedDetectionId"] = json!(id);
    document["reviewedDetectionHash"] = json!(review_fingerprint(&tx, &image_id)?);
    document["reviewConfidence"] = json!(confidence);
    document["reviewedAt"] = json!(chrono::Utc::now().to_rfc3339());
    tx.execute("INSERT INTO workflow_documents(key,document_json) VALUES(?1,?2) ON CONFLICT(key) DO UPDATE SET document_json=excluded.document_json",rusqlite::params![key,document.to_string()]).map_err(|e|e.to_string())?;
    tx.commit().map_err(|e| e.to_string())
}

#[tauri::command]
pub fn workspace_read(
    root: String,
    path: String,
    max_bytes: Option<usize>,
) -> Result<Option<Vec<u8>>, String> {
    // Path membership is checked after canonicalization as well, so a chunk
    // symlink cannot escape the user-selected local OME-Zarr directory.
    let root = std::fs::canonicalize(root).map_err(|e| e.to_string())?;
    if !root.is_dir() {
        return Err("Choose a local OME-Zarr directory".into());
    }
    let relative = Path::new(&path);
    if relative
        .components()
        .any(|c| !matches!(c, Component::Normal(_) | Component::CurDir))
    {
        return Err("OME-Zarr paths must stay inside their dataset".into());
    }
    let candidate = match std::fs::canonicalize(root.join(relative)) {
        Ok(p) => p,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(e) => return Err(e.to_string()),
    };
    if !candidate.starts_with(&root) || !candidate.is_file() {
        return Err("Dataset member is outside the selected directory".into());
    }
    let limit = max_bytes.unwrap_or(64 * 1024 * 1024).min(64 * 1024 * 1024);
    if std::fs::metadata(&candidate)
        .map_err(|e| e.to_string())?
        .len()
        > limit as u64
    {
        return Err("Dataset member exceeds its read budget".into());
    }
    use std::io::Read;
    let mut bytes = Vec::new();
    std::fs::File::open(candidate)
        .map_err(|e| e.to_string())?
        .take(limit as u64 + 1)
        .read_to_end(&mut bytes)
        .map_err(|e| e.to_string())?;
    if bytes.len() > limit {
        return Err("Dataset member grew beyond its read budget".into());
    }
    Ok(Some(bytes))
}

#[tauri::command]
pub fn export_workspace_bytes(
    app: AppHandle,
    out_path: String,
    bytes: Vec<u8>,
    no_overwrite: Option<bool>,
) -> Result<String, String> {
    if bytes.len() > 256 * 1024 * 1024 {
        return Err("Workspace export exceeds 256 MiB".into());
    }
    let store = FileStore::from_app(&app)?;
    let target = resolve_out_path(&store, &out_path)?;
    let temporary = target.with_extension(format!("{}.partial", uuid::Uuid::new_v4()));
    use std::io::Write;
    let result = (|| {
        let mut file = std::fs::OpenOptions::new()
            .create_new(true)
            .write(true)
            .open(&temporary)?;
        file.write_all(&bytes)?;
        file.sync_all()?;
        drop(file);
        if no_overwrite.unwrap_or(false) {
            // Publish without replacing an original document or another export.
            std::fs::hard_link(&temporary, &target)?;
            std::fs::remove_file(&temporary)
        } else {
            std::fs::rename(&temporary, &target)
        }
    })();
    if let Err(e) = result {
        let _ = std::fs::remove_file(temporary);
        return Err(e.to_string());
    }
    Ok(target.to_string_lossy().into_owned())
}

pub(crate) fn checkpoint_digest(path: &Path) -> Result<String, String> {
    use std::io::Read;
    let mut file = std::fs::File::open(path).map_err(|e| e.to_string())?;
    let mut digest = Sha256::new();
    let mut bytes = [0u8; 64 * 1024];
    let mut total = 0u64;
    loop {
        let count = file.read(&mut bytes).map_err(|e| e.to_string())?;
        if count == 0 {
            break;
        }
        total += count as u64;
        if total > 2 * 1024 * 1024 * 1024 {
            return Err("Checkpoint exceeds 2 GiB".into());
        }
        digest.update(&bytes[..count]);
    }
    Ok(format!("{:x}", digest.finalize()))
}
pub(crate) fn custom_model(
    conn: &rusqlite::Connection,
    store: &FileStore,
    id: &str,
) -> Result<Value, String> {
    let suffix = id
        .strip_prefix("custom-")
        .ok_or("Invalid custom model identity")?;
    uuid::Uuid::parse_str(suffix).map_err(|_| "Invalid custom model identity")?;
    let raw: Option<String> = conn
        .query_row(
            "SELECT document_json FROM workflow_documents WHERE key='custom-models'",
            [],
            |r| r.get(0),
        )
        .optional()
        .map_err(|e| e.to_string())?;
    let registry: Value = raw
        .map(|s| serde_json::from_str(&s))
        .transpose()
        .map_err(|e| e.to_string())?
        .unwrap_or(json!({"version":1,"models":[]}));
    if registry["version"] != 1 {
        return Err("Unsupported custom model catalogue version".into());
    }
    let mut model = registry["models"]
        .as_array()
        .and_then(|models| models.iter().find(|m| m["id"].as_str() == Some(id)))
        .cloned()
        .ok_or("Custom model is not registered")?;
    let root = std::fs::canonicalize(store.models_dir().join(id)).map_err(|e| e.to_string())?;
    let path = std::fs::canonicalize(
        model["path"]
            .as_str()
            .ok_or("Custom model path is missing")?,
    )
    .map_err(|e| e.to_string())?;
    if !path.starts_with(&root)
        || !["cellpose", "stardist"].contains(&model["kind"].as_str().unwrap_or(""))
    {
        return Err("Custom model is outside its checkpoint directory".into());
    }
    let files = model["filesSha256"]
        .as_object()
        .ok_or("Checkpoint registry needs reimporting to capture exact per-file identity")?;
    for (name, expected) in files {
        if Path::new(name)
            .components()
            .any(|c| !matches!(c, Component::Normal(_)))
            || Path::new(name).components().count() != 1
        {
            return Err("Invalid checkpoint member identity".into());
        }
        let candidate = if model["kind"] == "cellpose" {
            path.clone()
        } else {
            std::fs::canonicalize(path.join(name)).map_err(|e| e.to_string())?
        };
        if !candidate.starts_with(&root)
            || !candidate.is_file()
            || checkpoint_digest(&candidate)?.as_str() != expected.as_str().unwrap_or("")
        {
            return Err(
                "Custom checkpoint changed after import; reimport it to record a new identity"
                    .into(),
            );
        }
    }
    model["path"] = json!(path);
    Ok(model)
}
#[tauri::command]
pub fn import_custom_model(
    app: AppHandle,
    db: State<'_, Db>,
    source_path: String,
    kind: String,
    name: String,
) -> Result<Value, String> {
    if !["cellpose", "stardist"].contains(&kind.as_str())
        || name.trim().is_empty()
        || name.len() > 128
    {
        return Err("Choose a model kind and name".into());
    }
    let store = FileStore::from_app(&app)?;
    let source = std::fs::canonicalize(source_path).map_err(|e| e.to_string())?;
    let id = format!("custom-{}", uuid::Uuid::new_v4());
    let directory = store.models_dir().join(&id);
    std::fs::create_dir(&directory).map_err(|e| e.to_string())?;
    let result = (|| -> Result<Value, String> {
        let mut fingerprint = Sha256::new();
        let mut file_hashes = serde_json::Map::new();
        use std::io::{Read, Write};
        let mut copy_file = |from: &Path, to: &Path| -> Result<(), String> {
            let meta = std::fs::symlink_metadata(from).map_err(|e| e.to_string())?;
            if !meta.is_file() || meta.len() > 2 * 1024 * 1024 * 1024 {
                return Err("Checkpoint must be a regular file smaller than 2 GiB".into());
            }
            let mut input = std::fs::File::open(from).map_err(|e| e.to_string())?;
            let mut output = std::fs::OpenOptions::new()
                .write(true)
                .create_new(true)
                .open(to)
                .map_err(|e| e.to_string())?;
            let mut buffer = [0u8; 64 * 1024];
            let mut digest = Sha256::new();
            let mut total = 0u64;
            loop {
                let count = input.read(&mut buffer).map_err(|e| e.to_string())?;
                if count == 0 {
                    break;
                }
                total += count as u64;
                if total > 2 * 1024 * 1024 * 1024 {
                    return Err("Checkpoint grew beyond 2 GiB".into());
                }
                output
                    .write_all(&buffer[..count])
                    .map_err(|e| e.to_string())?;
                digest.update(&buffer[..count]);
            }
            output.sync_all().map_err(|e| e.to_string())?;
            let hash = format!("{:x}", digest.finalize());
            let member = to
                .file_name()
                .and_then(|v| v.to_str())
                .ok_or("Invalid checkpoint member")?;
            fingerprint.update(member.as_bytes());
            fingerprint.update([0]);
            fingerprint.update(hash.as_bytes());
            file_hashes.insert(member.into(), json!(hash));
            Ok(())
        };
        let path = if kind == "cellpose" {
            let path = directory.join("checkpoint");
            copy_file(&source, &path)?;
            path
        } else {
            if !source.is_dir()
                || !source.join("config.json").is_file()
                || !["weights_best.h5", "weights_now.h5"]
                    .iter()
                    .any(|f| source.join(f).is_file())
            {
                return Err(
                    "StarDist directory needs config.json and weights_best.h5 or weights_now.h5"
                        .into(),
                );
            }
            for file in [
                "config.json",
                "thresholds.json",
                "weights_best.h5",
                "weights_now.h5",
            ] {
                let from = source.join(file);
                if from.exists() {
                    copy_file(&from, &directory.join(file))?;
                }
            }
            directory.clone()
        };
        let model = json!({"id":id,"kind":kind,"name":name.trim(),"path":path,"sha256":format!("{:x}",fingerprint.finalize()),"filesSha256":file_hashes,"importedAt":chrono::Utc::now().to_rfc3339()});
        let conn = db.connection()?;
        let raw: Option<String> = conn
            .query_row(
                "SELECT document_json FROM workflow_documents WHERE key='custom-models'",
                [],
                |r| r.get(0),
            )
            .optional()
            .map_err(|e| e.to_string())?;
        let mut registry: Value = raw
            .map(|s| serde_json::from_str(&s))
            .transpose()
            .map_err(|e| e.to_string())?
            .unwrap_or(json!({"version":1,"models":[]}));
        let models = registry["models"]
            .as_array_mut()
            .ok_or("Saved custom model catalogue is damaged")?;
        if models.len() >= 128 {
            return Err("Custom model catalogue supports 128 checkpoints".into());
        }
        models.push(model.clone());
        conn.execute("INSERT INTO workflow_documents(key,document_json) VALUES('custom-models',?1) ON CONFLICT(key) DO UPDATE SET document_json=excluded.document_json",[registry.to_string()]).map_err(|e|e.to_string())?;
        Ok(model)
    })();
    if result.is_err() {
        let _ = std::fs::remove_dir_all(directory);
    }
    result
}

#[tauri::command]
pub fn import_workspace_project(path: String) -> Result<String, String> {
    use std::io::Read;
    let path = std::fs::canonicalize(path).map_err(|e| e.to_string())?;
    if !path.is_file()
        || std::fs::metadata(&path).map_err(|e| e.to_string())?.len() > 16 * 1024 * 1024
    {
        return Err("Workspace project must be a UTF-8 file up to 16 MiB".into());
    }
    let mut bytes = Vec::new();
    std::fs::File::open(path)
        .map_err(|e| e.to_string())?
        .take(16 * 1024 * 1024 + 1)
        .read_to_end(&mut bytes)
        .map_err(|e| e.to_string())?;
    if bytes.len() > 16 * 1024 * 1024 {
        return Err("Workspace project grew beyond 16 MiB".into());
    }
    String::from_utf8(bytes).map_err(|_| "Workspace project must use UTF-8".into())
}

/// The export caller supplies an immutable source/run snapshot from its read transaction.
pub(crate) async fn prepare_export_display(
    app: AppHandle,
    manager: State<'_, AssayManager>,
    mut request: Value,
    run_id: String,
) -> Result<std::path::PathBuf, String> {
    uuid::Uuid::parse_str(&run_id).map_err(|_| "Export run ID must be a UUID")?;
    let store = FileStore::from_app(&app)?;
    let output = store.analysis_dir().join(format!("preview-{run_id}.png"));
    request["operation"] = json!("source");
    request["previewPath"] = json!(output);
    request["exportFull"] = json!(true);
    request["includeValues"] = json!(false);
    request["timeIndex"] = json!(0);
    request["zIndex"] = Value::Null;
    let result = runner::run_assay(
        app,
        manager,
        "parity".into(),
        vec![],
        Some(request.to_string()),
        run_id,
    )
    .await;
    match result {
        Ok(value) if value["stride"] == 1 => Ok(output),
        Ok(_) => {
            let _ = std::fs::remove_file(&output);
            Err("Export source was unexpectedly sampled".into())
        }
        Err(reason) => {
            let _ = std::fs::remove_file(&output);
            Err(reason)
        }
    }
}
