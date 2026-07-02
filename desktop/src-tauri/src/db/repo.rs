//! db/repo.rs — data-access layer behind the PersistencePort `#[command]`s.
//!
//! Ported from `Persistence/Repositories.swift`. Every method in
//! `kernel/persistence/PersistencePort.ts` (§3.8) maps to one `#[tauri::command]`
//! here. All commands are `async` in TS (they cross IPC) but synchronous in
//! Rust — rusqlite is blocking and each call takes the connection mutex briefly.
//!
//! State: a single `Db` (a `Mutex<Connection>`) is managed by Tauri and opened
//! once at startup by `open_and_manage`. Foreign keys are ON so the cascade
//! rules in `schema.rs` fire. WAL mode keeps reads concurrent with the Swift
//! app on macOS.
//!
//! Command naming: snake_case Rust fn names are the invoke keys. The TS
//! `TauriSqlitePort` calls `invoke("all_batches")`, etc. (feature engineers
//! wire the exact names; they are registered in `lib.rs`).

use std::sync::Mutex;

use rusqlite::{params, Connection, OptionalExtension, Row};
use tauri::{AppHandle, Manager, State};
use uuid::Uuid;

use crate::db::models::{
    cells_from_json, cells_to_json, min_confidence, BatchDto, BinPresetDto, CalibrationPresetDto,
    CellDto, ConditionDto, CorrectionInput, DetectionDto, GroundTruthDto, ImageDto, RoiDto,
};
use crate::db::schema;
use crate::paths::FileStore;

/// Managed SQLite state. A single mutex-guarded connection is sufficient for a
/// desktop app (all access is short and serialized); no pool needed.
pub struct Db {
    conn: Mutex<Connection>,
    store: FileStore,
}

impl Db {
    /// Open the DB, apply pragmas, create the schema, and seed defaults.
    pub fn open(store: FileStore) -> Result<Self, String> {
        let conn = Connection::open(store.db_path())
            .map_err(|e| format!("open store.sqlite failed: {e}"))?;
        // Cascades + concurrency + durability tuned for a desktop store.
        conn.pragma_update(None, "foreign_keys", "ON")
            .map_err(|e| format!("enable foreign_keys failed: {e}"))?;
        conn.pragma_update(None, "journal_mode", "WAL")
            .map_err(|e| format!("set WAL failed: {e}"))?;
        conn.pragma_update(None, "synchronous", "NORMAL")
            .map_err(|e| format!("set synchronous failed: {e}"))?;
        // Wait up to 5s for a busy lock instead of erroring immediately (a
        // reader/writer overlap under WAL should retry, not fail).
        conn.pragma_update(None, "busy_timeout", 5000)
            .map_err(|e| format!("set busy_timeout failed: {e}"))?;
        schema::create_schema(&conn).map_err(|e| format!("create schema failed: {e}"))?;
        schema::seed_defaults(&conn).map_err(|e| format!("seed defaults failed: {e}"))?;
        Ok(Db {
            conn: Mutex::new(conn),
            store,
        })
    }

    fn lock(&self) -> Result<std::sync::MutexGuard<'_, Connection>, String> {
        self.conn.lock().map_err(|_| "db mutex poisoned".to_string())
    }

    /// The [`FileStore`] this DB was opened against — shared with the importer
    /// so it can resolve `Images/`/`Thumbnails/` paths under the same root.
    pub fn store(&self) -> &FileStore {
        &self.store
    }
}

/// Open the store and register it as Tauri managed state. Call from `lib.rs`
/// `setup`. Returns an error string on failure so setup can surface it.
pub fn open_and_manage(app: &AppHandle) -> Result<(), String> {
    let store = FileStore::from_app(app)?;
    let db = Db::open(store)?;
    app.manage(db);
    Ok(())
}

// ---------------------------------------------------------------------------
// small helpers
// ---------------------------------------------------------------------------

/// ISO-8601 (RFC3339) timestamp in UTC — the format `imported_at`/`ran_at`/… use.
pub fn now_iso8601() -> String {
    chrono::Utc::now().to_rfc3339()
}

fn new_id() -> String {
    Uuid::new_v4().to_string()
}

fn thresholds_to_json(t: &[f64]) -> String {
    serde_json::to_string(t).unwrap_or_else(|_| "[]".to_string())
}

fn thresholds_from_json(s: &str) -> Vec<f64> {
    serde_json::from_str(s).unwrap_or_default()
}

// ---------------------------------------------------------------------------
// row → DTO mappers
// ---------------------------------------------------------------------------

/// Map an `images` row to `ImageDto`, resolving stored/thumb paths via the store.
fn row_to_image(row: &Row, store: &FileStore) -> rusqlite::Result<ImageDto> {
    let id: String = row.get("id")?;
    let file_name: String = row.get("file_name")?;
    // Extension for the stored path comes from the file name (lowercased).
    let ext = std::path::Path::new(&file_name)
        .extension()
        .and_then(|e| e.to_str())
        .unwrap_or("tif")
        .to_ascii_lowercase();
    let stored_path = store.image_path(&id, &ext).to_string_lossy().into_owned();
    let thumb_path = store.thumb_path(&id).to_string_lossy().into_owned();
    Ok(ImageDto {
        id,
        file_name,
        width_px: row.get("width_px")?,
        height_px: row.get("height_px")?,
        imported_at: row.get("imported_at")?,
        file_hash: row.get("file_hash")?,
        confidence_override: row.get("confidence_override")?,
        notes: row.get("notes")?,
        stored_path,
        thumb_path,
    })
}

fn batch_image_ids(conn: &Connection, batch_id: &str) -> rusqlite::Result<Vec<String>> {
    let mut stmt = conn.prepare(
        "SELECT id FROM images WHERE batch_id = ?1 ORDER BY imported_at DESC",
    )?;
    let ids = stmt
        .query_map(params![batch_id], |r| r.get::<_, String>(0))?
        .collect::<rusqlite::Result<Vec<_>>>()?;
    Ok(ids)
}

fn row_to_batch(conn: &Connection, row: &Row) -> rusqlite::Result<BatchDto> {
    let id: String = row.get("id")?;
    let thresholds_json: String = row.get("thresholds_json")?;
    let image_ids = batch_image_ids(conn, &id)?;
    Ok(BatchDto {
        id,
        display_name: row.get("display_name")?,
        created_at: row.get("created_at")?,
        model_id: row.get("model_id")?,
        px_per_um: row.get("px_per_um")?,
        thresholds: thresholds_from_json(&thresholds_json),
        condition: row.get("condition")?,
        px_per_um_source: row.get("px_per_um_source")?,
        image_ids,
    })
}

fn row_to_roi(row: &Row) -> rusqlite::Result<RoiDto> {
    Ok(RoiDto {
        id: row.get("id")?,
        image_id: row.get("image_id")?,
        kind: row.get("kind")?,
        shape: row.get("shape")?,
        x: row.get("x")?,
        y: row.get("y")?,
        width: row.get("width")?,
        height: row.get("height")?,
        created_at: row.get("created_at")?,
        name: row.get("name")?,
    })
}

fn row_to_annotation(row: &Row) -> rusqlite::Result<GroundTruthDto> {
    Ok(GroundTruthDto {
        id: row.get("id")?,
        image_id: row.get("image_id")?,
        cx: row.get("cx")?,
        cy: row.get("cy")?,
        diameter_um: row.get("diameter")?,
        note: row.get("note")?,
        created_at: row.get("created_at")?,
    })
}

fn row_to_condition(row: &Row) -> rusqlite::Result<ConditionDto> {
    Ok(ConditionDto {
        id: row.get("id")?,
        name: row.get("name")?,
        color: row.get("color")?,
        created_at: row.get("created_at")?,
        order: row.get("order")?,
    })
}

// ===========================================================================
// COMMANDS — batches
// ===========================================================================

#[tauri::command]
pub fn all_batches(db: State<'_, Db>) -> Result<Vec<BatchDto>, String> {
    let conn = db.lock()?;
    // Collect batch ids first, then build each DTO — `row_to_batch` runs a
    // sub-query for `image_ids`, which can't borrow the outer statement's row.
    let ids: Vec<String> = {
        let mut s = conn
            .prepare("SELECT id FROM batches ORDER BY created_at DESC")
            .map_err(|e| e.to_string())?;
        let collected = s
            .query_map([], |r| r.get::<_, String>(0))
            .map_err(|e| e.to_string())?
            .collect::<rusqlite::Result<Vec<_>>>()
            .map_err(|e| e.to_string())?;
        collected
    };
    let mut out = Vec::with_capacity(ids.len());
    for id in ids {
        if let Some(b) = fetch_batch(&conn, &id).map_err(|e| e.to_string())? {
            out.push(b);
        }
    }
    Ok(out)
}

fn fetch_batch(conn: &Connection, id: &str) -> rusqlite::Result<Option<BatchDto>> {
    let mut stmt = conn.prepare("SELECT * FROM batches WHERE id = ?1")?;
    let mut rows = stmt.query(params![id])?;
    if let Some(row) = rows.next()? {
        Ok(Some(row_to_batch(conn, row)?))
    } else {
        Ok(None)
    }
}

#[tauri::command]
pub fn batch(db: State<'_, Db>, id: String) -> Result<Option<BatchDto>, String> {
    let conn = db.lock()?;
    fetch_batch(&conn, &id).map_err(|e| e.to_string())
}

#[tauri::command]
pub fn create_batch(
    db: State<'_, Db>,
    display_name: String,
    model_id: String,
    px_per_um: f64,
    thresholds: Vec<f64>,
    condition: Option<String>,
) -> Result<BatchDto, String> {
    let conn = db.lock()?;
    let id = new_id();
    let now = now_iso8601();
    conn.execute(
        "INSERT INTO batches
           (id, name, created_at, display_name, model_id, px_per_um, thresholds_json, condition, px_per_um_source)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, NULL)",
        params![
            id,
            display_name,
            now,
            display_name,
            model_id,
            px_per_um,
            thresholds_to_json(&thresholds),
            condition,
        ],
    )
    .map_err(|e| e.to_string())?;
    fetch_batch(&conn, &id)
        .map_err(|e| e.to_string())?
        .ok_or_else(|| "batch vanished after insert".to_string())
}

#[tauri::command]
pub fn batches_matching(db: State<'_, Db>, condition: String) -> Result<Vec<BatchDto>, String> {
    let conn = db.lock()?;
    let ids: Vec<String> = {
        let mut s = conn
            .prepare("SELECT id FROM batches WHERE condition = ?1 ORDER BY created_at DESC")
            .map_err(|e| e.to_string())?;
        let collected = s
            .query_map(params![condition], |r| r.get::<_, String>(0))
            .map_err(|e| e.to_string())?
            .collect::<rusqlite::Result<Vec<_>>>()
            .map_err(|e| e.to_string())?;
        collected
    };
    let mut out = Vec::with_capacity(ids.len());
    for id in ids {
        if let Some(b) = fetch_batch(&conn, &id).map_err(|e| e.to_string())? {
            out.push(b);
        }
    }
    Ok(out)
}

/// Delete a batch (cascades to images/detections/corrections/rois/annotations)
/// and remove the on-disk image + thumbnail files for its images first.
#[tauri::command]
pub fn delete_batch(db: State<'_, Db>, id: String) -> Result<(), String> {
    let conn = db.lock()?;
    remove_image_files_for_batch(&conn, &db.store, &id).map_err(|e| e.to_string())?;
    conn.execute("DELETE FROM batches WHERE id = ?1", params![id])
        .map_err(|e| e.to_string())?;
    Ok(())
}

fn remove_image_files_for_batch(
    conn: &Connection,
    store: &FileStore,
    batch_id: &str,
) -> rusqlite::Result<()> {
    let mut stmt = conn.prepare("SELECT id, file_name FROM images WHERE batch_id = ?1")?;
    let rows = stmt
        .query_map(params![batch_id], |r| {
            Ok((r.get::<_, String>(0)?, r.get::<_, String>(1)?))
        })?
        .collect::<rusqlite::Result<Vec<_>>>()?;
    for (id, file_name) in rows {
        remove_image_files(store, &id, &file_name);
    }
    Ok(())
}

fn remove_image_files(store: &FileStore, id: &str, file_name: &str) {
    if file_name.is_empty() {
        return; // guard against removing wrong/root paths (mirrors Swift B1-3)
    }
    let ext = std::path::Path::new(file_name)
        .extension()
        .and_then(|e| e.to_str())
        .unwrap_or("tif")
        .to_ascii_lowercase();
    let _ = std::fs::remove_file(store.image_path(id, &ext));
    let _ = std::fs::remove_file(store.thumb_path(id));
}

/// Delete every batch whose `images` array is empty (mirrors `cleanupEmptyBatches`).
#[tauri::command]
pub fn cleanup_empty_batches(db: State<'_, Db>) -> Result<(), String> {
    let conn = db.lock()?;
    conn.execute(
        "DELETE FROM batches
         WHERE id NOT IN (SELECT DISTINCT batch_id FROM images WHERE batch_id IS NOT NULL)",
        [],
    )
    .map_err(|e| e.to_string())?;
    Ok(())
}

// ===========================================================================
// COMMANDS — images
// ===========================================================================

#[tauri::command]
pub fn all_images(db: State<'_, Db>) -> Result<Vec<ImageDto>, String> {
    let conn = db.lock()?;
    let mut stmt = conn
        .prepare("SELECT * FROM images ORDER BY imported_at DESC")
        .map_err(|e| e.to_string())?;
    let out = stmt
        .query_map([], |r| row_to_image(r, &db.store))
        .map_err(|e| e.to_string())?
        .collect::<rusqlite::Result<Vec<_>>>()
        .map_err(|e| e.to_string())?;
    Ok(out)
}

/// Insert a freshly-imported image row (called by the importer command after it
/// writes files). Kept in the repo so all DB writes live behind one mutex.
#[allow(clippy::too_many_arguments)]
pub fn insert_image_row(
    db: &Db,
    id: &str,
    file_name: &str,
    original_path: &str,
    width_px: i64,
    height_px: i64,
    imported_at: &str,
    file_hash: Option<&str>,
) -> Result<ImageDto, String> {
    let conn = db.lock()?;
    conn.execute(
        "INSERT INTO images
           (id, file_name, original_path, width_px, height_px, imported_at,
            confidence_override, file_hash, notes, batch_id)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, NULL, ?7, NULL, NULL)",
        params![
            id,
            file_name,
            original_path,
            width_px,
            height_px,
            imported_at,
            file_hash
        ],
    )
    .map_err(|e| e.to_string())?;
    let mut stmt = conn
        .prepare("SELECT * FROM images WHERE id = ?1")
        .map_err(|e| e.to_string())?;
    let img = stmt
        .query_row(params![id], |r| row_to_image(r, &db.store))
        .map_err(|e| e.to_string())?;
    Ok(img)
}

/// Returns the first existing image whose `file_hash` matches AND whose
/// `file_name` matches, excluding `excluding_id` (mirrors `imageRecord(matchingHash:)`).
#[tauri::command]
pub fn image_matching_hash(
    db: State<'_, Db>,
    hash: String,
    file_name: String,
    excluding_id: Option<String>,
) -> Result<Option<ImageDto>, String> {
    let conn = db.lock()?;
    let mut stmt = conn
        .prepare(
            "SELECT * FROM images
             WHERE file_name = ?1 AND file_hash = ?2
             ORDER BY imported_at DESC",
        )
        .map_err(|e| e.to_string())?;
    let candidates = stmt
        .query_map(params![file_name, hash], |r| row_to_image(r, &db.store))
        .map_err(|e| e.to_string())?
        .collect::<rusqlite::Result<Vec<_>>>()
        .map_err(|e| e.to_string())?;
    let excl = excluding_id.as_deref();
    Ok(candidates
        .into_iter()
        .find(|img| excl != Some(img.id.as_str())))
}

/// Groups of 2+ images sharing a `file_hash` (mirrors `duplicateGroups`).
/// Images with NULL hash are excluded. Groups sorted by first filename.
#[tauri::command]
pub fn duplicate_groups(db: State<'_, Db>) -> Result<Vec<Vec<ImageDto>>, String> {
    let conn = db.lock()?;
    let mut stmt = conn
        .prepare(
            "SELECT * FROM images WHERE file_hash IS NOT NULL ORDER BY imported_at DESC",
        )
        .map_err(|e| e.to_string())?;
    let all = stmt
        .query_map([], |r| row_to_image(r, &db.store))
        .map_err(|e| e.to_string())?
        .collect::<rusqlite::Result<Vec<_>>>()
        .map_err(|e| e.to_string())?;

    use std::collections::BTreeMap;
    let mut by_hash: BTreeMap<String, Vec<ImageDto>> = BTreeMap::new();
    for img in all {
        if let Some(h) = img.file_hash.clone() {
            by_hash.entry(h).or_default().push(img);
        }
    }
    let mut groups: Vec<Vec<ImageDto>> =
        by_hash.into_values().filter(|g| g.len() >= 2).collect();
    groups.sort_by(|a, b| {
        a.first()
            .map(|i| i.file_name.as_str())
            .unwrap_or("")
            .cmp(b.first().map(|i| i.file_name.as_str()).unwrap_or(""))
    });
    Ok(groups)
}

/// Remove image + thumbnail from disk, then delete the row (cascades).
#[tauri::command]
pub fn delete_image(db: State<'_, Db>, id: String) -> Result<(), String> {
    let conn = db.lock()?;
    let file_name: Option<String> = conn
        .query_row(
            "SELECT file_name FROM images WHERE id = ?1",
            params![id],
            |r| r.get(0),
        )
        .optional()
        .map_err(|e| e.to_string())?;
    if let Some(fname) = file_name {
        remove_image_files(&db.store, &id, &fname);
    }
    conn.execute("DELETE FROM images WHERE id = ?1", params![id])
        .map_err(|e| e.to_string())?;
    Ok(())
}

#[tauri::command]
pub fn attach_image_to_batch(
    db: State<'_, Db>,
    image_id: String,
    batch_id: String,
) -> Result<(), String> {
    let conn = db.lock()?;
    conn.execute(
        "UPDATE images SET batch_id = ?1 WHERE id = ?2",
        params![batch_id, image_id],
    )
    .map_err(|e| e.to_string())?;
    Ok(())
}

/// Per-image freeform notes (mirrors the Swift `ImageRecord.notes` / NotesPanel).
/// Off the `PersistencePort` interface (like `import_image`) — a standalone
/// command the Results sidebar calls directly. `notes = None` clears the field.
#[tauri::command]
pub fn set_image_notes(
    db: State<'_, Db>,
    image_id: String,
    notes: Option<String>,
) -> Result<(), String> {
    let conn = db.lock()?;
    conn.execute(
        "UPDATE images SET notes = ?1 WHERE id = ?2",
        params![notes, image_id],
    )
    .map_err(|e| e.to_string())?;
    Ok(())
}

/// Per-image confidence-cutoff override (mirrors Swift `AppState.setConfidenceOverride`).
/// `value = None` clears the override so the global confidence applies again.
#[tauri::command]
pub fn set_image_confidence_override(
    db: State<'_, Db>,
    image_id: String,
    value: Option<f64>,
) -> Result<(), String> {
    let conn = db.lock()?;
    conn.execute(
        "UPDATE images SET confidence_override = ?1 WHERE id = ?2",
        params![value, image_id],
    )
    .map_err(|e| e.to_string())?;
    Ok(())
}

// ===========================================================================
// COMMANDS — detections & corrections
// ===========================================================================

/// Save (replace) the 1:1 detection for an image. Because `idx_detection_image`
/// is unique, we upsert on `image_id` — re-running detection replaces the row
/// (matching the Swift "we re-run to replace" 1:1 relationship).
#[tauri::command]
pub fn save_detection(
    db: State<'_, Db>,
    image_id: String,
    detector_id: String,
    cells: Vec<CellDto>,
    image_stats: Option<std::collections::BTreeMap<String, f64>>,
) -> Result<DetectionDto, String> {
    let conn = db.lock()?;
    let cells_json = cells_to_json(&cells).map_err(|e| e.to_string())?;
    let min_conf = min_confidence(&cells);
    let stats_json = match &image_stats {
        Some(m) if !m.is_empty() => Some(serde_json::to_string(m).map_err(|e| e.to_string())?),
        _ => None,
    };
    let now = now_iso8601();
    // Preserve the correction log across re-detection. `corrections` FKs on
    // `detections.id` (ON DELETE CASCADE), so the old DELETE+INSERT-with-a-new-id
    // silently wiped every hand-correction whenever the user re-ran detection.
    // Instead reuse the existing detection id (1:1 per image) and UPDATE the
    // cells in place, so the append-only correction log stays attached (it feeds
    // the future train-from-GUI seam).
    let existing_id: Option<String> = conn
        .query_row(
            "SELECT id FROM detections WHERE image_id = ?1",
            params![image_id],
            |r| r.get(0),
        )
        .optional()
        .map_err(|e| e.to_string())?;
    let id = match existing_id {
        Some(existing) => {
            conn.execute(
                "UPDATE detections
                   SET detector_id = ?2, ran_at = ?3, cells_json = ?4,
                       min_confidence = ?5, image_stats_json = ?6
                 WHERE id = ?1",
                params![existing, detector_id, now, cells_json, min_conf, stats_json],
            )
            .map_err(|e| e.to_string())?;
            existing
        }
        None => {
            let id = new_id();
            conn.execute(
                "INSERT INTO detections
                   (id, image_id, detector_id, ran_at, cells_json, min_confidence, image_stats_json)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)",
                params![id, image_id, detector_id, now, cells_json, min_conf, stats_json],
            )
            .map_err(|e| e.to_string())?;
            id
        }
    };
    Ok(DetectionDto {
        id,
        image_id,
        detector_id,
        ran_at: now,
        cells,
        image_stats: image_stats.filter(|m| !m.is_empty()),
    })
}

#[tauri::command]
pub fn get_detection(db: State<'_, Db>, image_id: String) -> Result<Option<DetectionDto>, String> {
    let conn = db.lock()?;
    let mut stmt = conn
        .prepare("SELECT * FROM detections WHERE image_id = ?1")
        .map_err(|e| e.to_string())?;
    let det = stmt
        .query_row(params![image_id], |r| {
            let cells_json: String = r.get("cells_json")?;
            let stats_json: Option<String> = r.get("image_stats_json")?;
            let image_stats = stats_json.and_then(|s| serde_json::from_str(&s).ok());
            Ok(DetectionDto {
                id: r.get("id")?,
                image_id: r.get("image_id")?,
                detector_id: r.get("detector_id")?,
                ran_at: r.get("ran_at")?,
                cells: cells_from_json(&cells_json),
                image_stats,
            })
        })
        .optional()
        .map_err(|e| e.to_string())?;
    Ok(det)
}

#[tauri::command]
pub fn record_correction(
    db: State<'_, Db>,
    detection_id: String,
    c: CorrectionInput,
) -> Result<(), String> {
    let conn = db.lock()?;
    conn.execute(
        "INSERT INTO corrections
           (id, detection_id, kind, cell_id, cx, cy, diameter, created_at)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)",
        params![
            new_id(),
            detection_id,
            c.kind,
            c.cell_id,
            c.cx,
            c.cy,
            c.diameter,
            now_iso8601()
        ],
    )
    .map_err(|e| e.to_string())?;
    Ok(())
}

// ===========================================================================
// COMMANDS — rois
// ===========================================================================

#[tauri::command]
pub fn rois(db: State<'_, Db>, image_id: String) -> Result<Vec<RoiDto>, String> {
    let conn = db.lock()?;
    let mut stmt = conn
        .prepare("SELECT * FROM rois WHERE image_id = ?1 ORDER BY created_at")
        .map_err(|e| e.to_string())?;
    let out = stmt
        .query_map(params![image_id], row_to_roi)
        .map_err(|e| e.to_string())?
        .collect::<rusqlite::Result<Vec<_>>>()
        .map_err(|e| e.to_string())?;
    Ok(out)
}

/// Insert or replace an ROI (the DTO carries its own id, generated client-side
/// or reused). `image_id` on the row wins over any stale value in the DTO.
#[tauri::command]
pub fn save_roi(db: State<'_, Db>, image_id: String, roi: RoiDto) -> Result<(), String> {
    let conn = db.lock()?;
    let id = if roi.id.is_empty() { new_id() } else { roi.id };
    let created_at = if roi.created_at.is_empty() {
        now_iso8601()
    } else {
        roi.created_at
    };
    conn.execute(
        "INSERT OR REPLACE INTO rois
           (id, image_id, kind, shape, x, y, width, height, created_at, name)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10)",
        params![
            id,
            image_id,
            roi.kind,
            roi.shape,
            roi.x,
            roi.y,
            roi.width,
            roi.height,
            created_at,
            roi.name
        ],
    )
    .map_err(|e| e.to_string())?;
    Ok(())
}

#[tauri::command]
pub fn delete_roi(db: State<'_, Db>, id: String) -> Result<(), String> {
    let conn = db.lock()?;
    conn.execute("DELETE FROM rois WHERE id = ?1", params![id])
        .map_err(|e| e.to_string())?;
    Ok(())
}

// ===========================================================================
// COMMANDS — ground-truth annotations
// ===========================================================================

#[tauri::command]
pub fn annotations(db: State<'_, Db>, image_id: String) -> Result<Vec<GroundTruthDto>, String> {
    let conn = db.lock()?;
    let mut stmt = conn
        .prepare("SELECT * FROM ground_truth_annotations WHERE image_id = ?1 ORDER BY created_at")
        .map_err(|e| e.to_string())?;
    let out = stmt
        .query_map(params![image_id], row_to_annotation)
        .map_err(|e| e.to_string())?
        .collect::<rusqlite::Result<Vec<_>>>()
        .map_err(|e| e.to_string())?;
    Ok(out)
}

#[tauri::command]
pub fn add_annotation(db: State<'_, Db>, a: GroundTruthDto) -> Result<(), String> {
    let conn = db.lock()?;
    let id = if a.id.is_empty() { new_id() } else { a.id };
    let created_at = if a.created_at.is_empty() {
        now_iso8601()
    } else {
        a.created_at
    };
    conn.execute(
        "INSERT OR REPLACE INTO ground_truth_annotations
           (id, image_id, cx, cy, diameter, created_at, note)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)",
        params![id, a.image_id, a.cx, a.cy, a.diameter_um, created_at, a.note],
    )
    .map_err(|e| e.to_string())?;
    Ok(())
}

#[tauri::command]
pub fn delete_annotation(db: State<'_, Db>, id: String) -> Result<(), String> {
    let conn = db.lock()?;
    conn.execute(
        "DELETE FROM ground_truth_annotations WHERE id = ?1",
        params![id],
    )
    .map_err(|e| e.to_string())?;
    Ok(())
}

#[tauri::command]
pub fn delete_all_annotations(db: State<'_, Db>, image_id: String) -> Result<(), String> {
    let conn = db.lock()?;
    conn.execute(
        "DELETE FROM ground_truth_annotations WHERE image_id = ?1",
        params![image_id],
    )
    .map_err(|e| e.to_string())?;
    Ok(())
}

// ===========================================================================
// COMMANDS — conditions
// ===========================================================================

#[tauri::command]
pub fn conditions(db: State<'_, Db>) -> Result<Vec<ConditionDto>, String> {
    let conn = db.lock()?;
    let mut stmt = conn
        .prepare("SELECT * FROM conditions ORDER BY \"order\"")
        .map_err(|e| e.to_string())?;
    let out = stmt
        .query_map([], row_to_condition)
        .map_err(|e| e.to_string())?
        .collect::<rusqlite::Result<Vec<_>>>()
        .map_err(|e| e.to_string())?;
    Ok(out)
}

#[tauri::command]
pub fn create_condition(
    db: State<'_, Db>,
    name: String,
    color: String,
) -> Result<ConditionDto, String> {
    let conn = db.lock()?;
    // Place at end (mirrors createCondition nextOrder logic).
    let next_order: i64 = conn
        .query_row(
            "SELECT COALESCE(MAX(\"order\"), -1) + 1 FROM conditions",
            [],
            |r| r.get(0),
        )
        .map_err(|e| e.to_string())?;
    let id = new_id();
    let now = now_iso8601();
    conn.execute(
        "INSERT INTO conditions (id, name, color, created_at, \"order\")
         VALUES (?1, ?2, ?3, ?4, ?5)",
        params![id, name, color, now, next_order],
    )
    .map_err(|e| e.to_string())?;
    Ok(ConditionDto {
        id,
        name,
        color,
        created_at: now,
        order: next_order,
    })
}

#[tauri::command]
pub fn rename_condition(db: State<'_, Db>, id: String, name: String) -> Result<(), String> {
    let conn = db.lock()?;
    conn.execute(
        "UPDATE conditions SET name = ?1 WHERE id = ?2",
        params![name, id],
    )
    .map_err(|e| e.to_string())?;
    Ok(())
}

#[tauri::command]
pub fn reorder_conditions(db: State<'_, Db>, ordered_ids: Vec<String>) -> Result<(), String> {
    let mut conn = db.lock()?;
    let tx = conn.transaction().map_err(|e| e.to_string())?;
    for (i, id) in ordered_ids.iter().enumerate() {
        tx.execute(
            "UPDATE conditions SET \"order\" = ?1 WHERE id = ?2",
            params![i as i64, id],
        )
        .map_err(|e| e.to_string())?;
    }
    tx.commit().map_err(|e| e.to_string())?;
    Ok(())
}

#[tauri::command]
pub fn delete_condition(db: State<'_, Db>, id: String) -> Result<(), String> {
    let conn = db.lock()?;
    conn.execute("DELETE FROM conditions WHERE id = ?1", params![id])
        .map_err(|e| e.to_string())?;
    Ok(())
}

// ===========================================================================
// COMMANDS — presets
// ===========================================================================

#[tauri::command]
pub fn calibration_presets(db: State<'_, Db>) -> Result<Vec<CalibrationPresetDto>, String> {
    let conn = db.lock()?;
    let mut stmt = conn
        .prepare("SELECT id, name, px_per_um, is_default FROM calibration_presets ORDER BY name")
        .map_err(|e| e.to_string())?;
    let out = stmt
        .query_map([], |r| {
            Ok(CalibrationPresetDto {
                id: r.get(0)?,
                name: r.get(1)?,
                px_per_um: r.get(2)?,
                is_default: r.get::<_, i64>(3)? != 0,
            })
        })
        .map_err(|e| e.to_string())?
        .collect::<rusqlite::Result<Vec<_>>>()
        .map_err(|e| e.to_string())?;
    Ok(out)
}

#[tauri::command]
pub fn upsert_calibration_preset(db: State<'_, Db>, p: CalibrationPresetDto) -> Result<(), String> {
    let conn = db.lock()?;
    let id = if p.id.is_empty() { new_id() } else { p.id };
    conn.execute(
        "INSERT OR REPLACE INTO calibration_presets (id, name, px_per_um, is_default)
         VALUES (?1, ?2, ?3, ?4)",
        params![id, p.name, p.px_per_um, if p.is_default { 1 } else { 0 }],
    )
    .map_err(|e| e.to_string())?;
    Ok(())
}

#[tauri::command]
pub fn delete_calibration_preset(db: State<'_, Db>, id: String) -> Result<(), String> {
    let conn = db.lock()?;
    conn.execute("DELETE FROM calibration_presets WHERE id = ?1", params![id])
        .map_err(|e| e.to_string())?;
    Ok(())
}

#[tauri::command]
pub fn bin_presets(db: State<'_, Db>) -> Result<Vec<BinPresetDto>, String> {
    let conn = db.lock()?;
    let mut stmt = conn
        .prepare("SELECT id, name, thresholds_json FROM bin_presets ORDER BY name")
        .map_err(|e| e.to_string())?;
    let out = stmt
        .query_map([], |r| {
            let thresholds_json: String = r.get(2)?;
            Ok(BinPresetDto {
                id: r.get(0)?,
                name: r.get(1)?,
                thresholds: thresholds_from_json(&thresholds_json),
            })
        })
        .map_err(|e| e.to_string())?
        .collect::<rusqlite::Result<Vec<_>>>()
        .map_err(|e| e.to_string())?;
    Ok(out)
}

// ===========================================================================
// COMMANDS — counts & review & wipe
// ===========================================================================

#[tauri::command]
pub fn total_image_count(db: State<'_, Db>) -> Result<i64, String> {
    let conn = db.lock()?;
    conn.query_row("SELECT COUNT(*) FROM images", [], |r| r.get(0))
        .map_err(|e| e.to_string())
}

#[tauri::command]
pub fn total_batch_count(db: State<'_, Db>) -> Result<i64, String> {
    let conn = db.lock()?;
    conn.query_row("SELECT COUNT(*) FROM batches", [], |r| r.get(0))
        .map_err(|e| e.to_string())
}

/// Count low-confidence CELLS (not detections) that have not been triaged.
/// A cell is triaged when a correction row exists for its `cell_id` (any kind),
/// mirroring `uncorrectedCellCount(below:)`. We pre-filter detections by the
/// denormalised `min_confidence` column, then decode + subtract corrected ids.
#[tauri::command]
pub fn uncorrected_cell_count(db: State<'_, Db>, below_confidence: f64) -> Result<i64, String> {
    let conn = db.lock()?;
    let mut stmt = conn
        .prepare("SELECT id, cells_json FROM detections WHERE min_confidence < ?1")
        .map_err(|e| e.to_string())?;
    let rows = stmt
        .query_map(params![below_confidence], |r| {
            Ok((r.get::<_, String>(0)?, r.get::<_, String>(1)?))
        })
        .map_err(|e| e.to_string())?
        .collect::<rusqlite::Result<Vec<_>>>()
        .map_err(|e| e.to_string())?;

    let mut total: i64 = 0;
    for (det_id, cells_json) in rows {
        // Corrected cell ids for this detection.
        let mut cstmt = conn
            .prepare("SELECT DISTINCT cell_id FROM corrections WHERE detection_id = ?1")
            .map_err(|e| e.to_string())?;
        let corrected: std::collections::HashSet<String> = cstmt
            .query_map(params![det_id], |r| r.get::<_, String>(0))
            .map_err(|e| e.to_string())?
            .collect::<rusqlite::Result<std::collections::HashSet<_>>>()
            .map_err(|e| e.to_string())?;
        let cells = cells_from_json(&cells_json);
        total += cells
            .iter()
            .filter(|c| c.confidence < below_confidence && !corrected.contains(&c.id))
            .count() as i64;
    }
    Ok(total)
}

/// Delete every batch (cascades to images/detections/corrections/rois/annotations)
/// and wipe the on-disk Images + Thumbnails dirs. Preserves workflow config
/// (conditions, presets, model_versions) and the python venv (mirrors
/// `wipeAllUserData`).
#[tauri::command]
pub fn wipe_all_user_data(db: State<'_, Db>) -> Result<(), String> {
    let conn = db.lock()?;
    conn.execute("DELETE FROM batches", [])
        .map_err(|e| e.to_string())?;
    // Images not attached to any batch would survive the cascade — remove them
    // explicitly so a wipe is total (their cascade clears detections/rois/gt).
    conn.execute("DELETE FROM images", [])
        .map_err(|e| e.to_string())?;

    let images_dir = db.store.images_dir();
    let thumbs_dir = db.store.thumbs_dir();
    let _ = std::fs::remove_dir_all(&images_dir);
    let _ = std::fs::remove_dir_all(&thumbs_dir);
    std::fs::create_dir_all(&images_dir).map_err(|e| e.to_string())?;
    std::fs::create_dir_all(&thumbs_dir).map_err(|e| e.to_string())?;
    Ok(())
}
