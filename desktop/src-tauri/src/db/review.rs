//! Persistent, indexed Review queue. Page reads never open cells_json. Geometry
//! is fetched only for a visible card, and decisions read the latest stored mask.
use rusqlite::{params, Connection, OptionalExtension};
use serde::{Deserialize, Serialize};
use std::sync::Mutex;
use tauri::State;

use super::models::{cell_from_json_checked, CellDto, ImageDto};
use super::repo::{now_iso8601, row_to_image, Db};
use crate::paths::FileStore;

const CUTOFF: f64 = 0.65;
const MAX_PAGE: usize = 64;
const MAX_NEIGHBORS: usize = 96;
const MAX_CELL_BYTES: usize = 65_536;
const MAX_UNDO_BYTES: usize = 16 * 1024 * 1024;

/// Only the last Review decision in this app session can be undone. This
/// memento is bounded to one cell, stays local, and vanishes on app restart.
#[derive(Default)]
pub struct ReviewUndoState(Mutex<Option<UndoRecord>>);

struct UndoRecord {
    token: String,
    detection_id: String,
    cell_id: String,
    correction_id: String,
    ran_at: String,
    detector_id: String,
    before: String,
    after: Option<String>,
    index: i64,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ReviewDecisionOutcome {
    undo_token: Option<String>,
    undo_unavailable_reason: Option<String>,
}

// Keep only the six scalar fields needed by the queue. No contour, per-channel
// array, or other unbounded property is copied into this index.
const PROJECTION: &str = "json_object('id', json_extract(j.value,'$.id'),
 'cx', json_extract(j.value,'$.cx'), 'cy', json_extract(j.value,'$.cy'),
 'diameter', json_extract(j.value,'$.diameter'),
 'diameterPx', json_extract(j.value,'$.diameterPx'),
 'confidence', json_extract(j.value,'$.confidence'))";

/// Atomic, one-time upgrade. SQLite streams existing blobs through json_each;
/// Rust never collects the library's masks. Triggers keep the compact index in
/// the SAME transaction as every detection write, including existing IPC paths.
pub(crate) fn migrate(conn: &Connection) -> rusqlite::Result<()> {
    let exists: bool = conn.query_row(
        "SELECT EXISTS(SELECT 1 FROM sqlite_master WHERE type='table' AND name='review_candidates')",
        [], |r| r.get(0),
    )?;
    if exists {
        return Ok(());
    }
    let tx = conn.unchecked_transaction()?;
    tx.execute_batch(&format!(r#"
      CREATE TABLE review_candidates (
        detection_id TEXT NOT NULL REFERENCES detections(id) ON DELETE CASCADE,
        cell_id TEXT NOT NULL,
        confidence REAL NOT NULL,
        cell_json TEXT NOT NULL,
        PRIMARY KEY (detection_id, cell_id)
      );
      CREATE INDEX idx_review_order ON review_candidates(confidence, detection_id, cell_id);
      CREATE INDEX IF NOT EXISTS idx_corrections_cell ON corrections(detection_id, cell_id);
      INSERT INTO review_candidates
        SELECT d.id, json_extract(j.value,'$.id'), json_extract(j.value,'$.confidence'), {PROJECTION}
        FROM detections d, json_each(d.cells_json) j
        WHERE json_extract(j.value,'$.confidence') < {CUTOFF};
      CREATE TRIGGER review_detection_insert AFTER INSERT ON detections BEGIN
        INSERT INTO review_candidates
          SELECT new.id, json_extract(j.value,'$.id'), json_extract(j.value,'$.confidence'), {PROJECTION}
          FROM json_each(new.cells_json) j WHERE json_extract(j.value,'$.confidence') < {CUTOFF};
      END;
      CREATE TRIGGER review_detection_update AFTER UPDATE OF cells_json ON detections BEGIN
        DELETE FROM review_candidates WHERE detection_id = new.id;
        INSERT INTO review_candidates
          SELECT new.id, json_extract(j.value,'$.id'), json_extract(j.value,'$.confidence'), {PROJECTION}
          FROM json_each(new.cells_json) j WHERE json_extract(j.value,'$.confidence') < {CUTOFF};
      END;
    "#))?;
    tx.commit()
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ReviewCursor {
    pub confidence: f64,
    pub detection_id: String,
    pub cell_id: String,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ReviewItem {
    pub key: String,
    pub cell: CellDto,
    pub image: ImageDto,
    pub detection_id: String,
    pub px_per_um: f64,
    pub batch_name: String,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ReviewPage {
    pub items: Vec<ReviewItem>,
    pub next_cursor: Option<ReviewCursor>,
    pub total_pending: i64,
}

fn page(
    conn: &Connection,
    store: &FileStore,
    after: Option<ReviewCursor>,
    limit: usize,
) -> Result<ReviewPage, String> {
    if !(1..=MAX_PAGE).contains(&limit) {
        return Err("Review page size must be between 1 and 64.".into());
    }
    if let Some(c) = &after {
        if !c.confidence.is_finite() || c.detection_id.len() > 128 || c.cell_id.len() > 128 {
            return Err("Invalid Review cursor.".into());
        }
    }
    // Row-value keyset comparison uses idx_review_order, even deep into the
    // queue. Corrected candidates never cross IPC, including Keep decisions.
    let after = after.unwrap_or(ReviewCursor {
        confidence: -f64::MAX,
        detection_id: String::new(),
        cell_id: String::new(),
    });
    let mut stmt = conn
        .prepare(
            "SELECT i.*, d.cell_count, r.detection_id, r.cell_json,
                COALESCE(b.px_per_um,1.0) AS review_scale,
                COALESCE(b.display_name,'Unbatched') AS review_batch
         FROM review_candidates r INDEXED BY idx_review_order
         JOIN detections d ON d.id = r.detection_id
         JOIN images i ON i.id = d.image_id
         LEFT JOIN batches b ON b.id = i.batch_id
         WHERE (r.confidence,r.detection_id,r.cell_id) > (?1,?2,?3)
           AND NOT EXISTS(SELECT 1 FROM corrections c
             WHERE c.detection_id=r.detection_id AND c.cell_id=r.cell_id)
         ORDER BY r.confidence,r.detection_id,r.cell_id LIMIT ?4",
        )
        .map_err(|e| e.to_string())?;
    let mut rows = stmt
        .query(params![
            after.confidence,
            after.detection_id,
            after.cell_id,
            limit + 1
        ])
        .map_err(|e| e.to_string())?;
    let mut items = Vec::with_capacity(limit + 1);
    while let Some(row) = rows.next().map_err(|e| e.to_string())? {
        let json: String = row.get("cell_json").map_err(|e| e.to_string())?;
        let cell = cell_from_json_checked(&json)
            .map_err(|e| format!("Review cell cannot be read: {e}"))?;
        let detection_id: String = row.get("detection_id").map_err(|e| e.to_string())?;
        items.push(ReviewItem {
            key: format!("{detection_id}:{}", cell.id),
            cell,
            detection_id,
            image: row_to_image(row, store).map_err(|e| e.to_string())?,
            px_per_um: row.get("review_scale").map_err(|e| e.to_string())?,
            batch_name: row.get("review_batch").map_err(|e| e.to_string())?,
        });
    }
    let more = items.len() > limit;
    items.truncate(limit);
    let next_cursor = if more {
        items.last().map(|item| ReviewCursor {
            confidence: item.cell.confidence,
            detection_id: item.detection_id.clone(),
            cell_id: item.cell.id.clone(),
        })
    } else {
        None
    };
    let total_pending = conn
        .query_row(
            "SELECT COALESCE(SUM(uncorrected_count),0) FROM detections",
            [],
            |r| r.get(0),
        )
        .map_err(|e| e.to_string())?;
    Ok(ReviewPage {
        items,
        next_cursor,
        total_pending,
    })
}

#[tauri::command]
pub async fn review_page(
    db: State<'_, Db>,
    after: Option<ReviewCursor>,
    limit: Option<usize>,
) -> Result<ReviewPage, String> {
    let conn = db.connection()?;
    page(&conn, db.store(), after, limit.unwrap_or(MAX_PAGE))
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ReviewContext {
    pub cell: CellDto,
    pub neighbors: Vec<CellDto>,
    pub limited: bool,
}

fn context(
    conn: &Connection,
    detection_id: &str,
    cell_id: &str,
) -> Result<Option<ReviewContext>, String> {
    // Large individual contours fall back to a circle for this preview only.
    // Persisted geometry stays intact, and the UI discloses the approximation.
    let selection = format!("CASE WHEN length(CAST(j.value AS BLOB)) <= {MAX_CELL_BYTES} THEN j.value ELSE {PROJECTION} END");
    let target: Option<(String, bool)> = conn
        .query_row(
            &format!(
                "SELECT {selection}, length(CAST(j.value AS BLOB)) > {MAX_CELL_BYTES}
         FROM detections d, json_each(d.cells_json) j
         WHERE d.id=?1 AND json_extract(j.value,'$.id')=?2
           AND NOT EXISTS(SELECT 1 FROM corrections WHERE detection_id=?1 AND cell_id=?2) LIMIT 1"
            ),
            params![detection_id, cell_id],
            |r| Ok((r.get(0)?, r.get(1)?)),
        )
        .optional()
        .map_err(|e| e.to_string())?;
    let Some((json, mut limited)) = target else {
        return Ok(None);
    };
    let cell =
        cell_from_json_checked(&json).map_err(|e| format!("Review cell cannot be read: {e}"))?;
    // Enclose the 560×320 crop, including the shifted crop near image edges.
    let radius = (cell.diameter_px * 5.0).max(240.0) * 1.75;
    let mut stmt = conn
        .prepare(&format!(
            "SELECT {selection}, length(CAST(j.value AS BLOB)) > {MAX_CELL_BYTES}
         FROM detections d, json_each(d.cells_json) j
         WHERE d.id=?1 AND json_extract(j.value,'$.id') != ?2
           AND ABS(json_extract(j.value,'$.cx')-?3) <= ?5 + json_extract(j.value,'$.diameterPx')/2
           AND ABS(json_extract(j.value,'$.cy')-?4) <= ?5 + json_extract(j.value,'$.diameterPx')/2
         LIMIT ?6"
        ))
        .map_err(|e| e.to_string())?;
    let mut rows = stmt
        .query(params![
            detection_id,
            cell_id,
            cell.cx,
            cell.cy,
            radius,
            MAX_NEIGHBORS + 1
        ])
        .map_err(|e| e.to_string())?;
    let mut neighbors = Vec::new();
    while let Some(row) = rows.next().map_err(|e| e.to_string())? {
        if neighbors.len() == MAX_NEIGHBORS {
            limited = true;
            break;
        }
        let json: String = row.get(0).map_err(|e| e.to_string())?;
        limited |= row.get::<_, bool>(1).map_err(|e| e.to_string())?;
        neighbors.push(
            cell_from_json_checked(&json)
                .map_err(|e| format!("Nearby cell cannot be read: {e}"))?,
        );
    }
    Ok(Some(ReviewContext {
        cell,
        neighbors,
        limited,
    }))
}

#[tauri::command]
pub async fn review_context(
    db: State<'_, Db>,
    detection_id: String,
    cell_id: String,
) -> Result<Option<ReviewContext>, String> {
    let conn = db.connection()?;
    context(&conn, &detection_id, &cell_id)
}

#[derive(Clone, Copy, Debug, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum ReviewAction {
    Keep,
    Reject,
    Resize,
}

fn decide(
    conn: &mut Connection,
    detection_id: &str,
    cell_id: &str,
    action: ReviewAction,
    diameter_um: Option<f64>,
) -> Result<Option<String>, String> {
    if matches!(action, ReviewAction::Resize)
        && !diameter_um.is_some_and(|d| d.is_finite() && d > 0.0 && d <= 1_000_000.0)
    {
        return Err("Enter a finite diameter above zero and at most 1,000,000 µm.".into());
    }
    let tx = conn
        .transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)
        .map_err(|e| e.to_string())?;
    let reviewed: bool = tx
        .query_row(
            "SELECT EXISTS(SELECT 1 FROM corrections WHERE detection_id=?1 AND cell_id=?2)",
            params![detection_id, cell_id],
            |r| r.get(0),
        )
        .map_err(|e| e.to_string())?;
    // Retries after a lost IPC response and other-window decisions are harmless.
    if reviewed {
        return Ok(None);
    }
    let stored: Option<(String, f64)> = tx
        .query_row(
            "SELECT r.cell_json,COALESCE(b.px_per_um,1.0) FROM review_candidates r
         JOIN detections d ON d.id=r.detection_id JOIN images i ON i.id=d.image_id
         LEFT JOIN batches b ON b.id=i.batch_id WHERE r.detection_id=?1 AND r.cell_id=?2",
            params![detection_id, cell_id],
            |r| Ok((r.get(0)?, r.get(1)?)),
        )
        .optional()
        .map_err(|e| e.to_string())?;
    let Some((json, scale)) = stored else {
        return Ok(None);
    };
    let cell = cell_from_json_checked(&json)
        .map_err(|e| format!("This saved cell cannot be edited safely: {e}"))?;
    let kind = match action {
        ReviewAction::Keep => "accept",
        ReviewAction::Reject => "remove",
        ReviewAction::Resize => {
            let diameter = diameter_um.expect("validated diameter");
            if !scale.is_finite() || scale <= 0.0 || !(diameter * scale).is_finite() {
                return Err(
                    "This image has an invalid calibration. Set its calibration before resizing."
                        .into(),
                );
            }
            "resize"
        }
    };
    let correction_id = uuid::Uuid::new_v4().to_string();
    tx.execute(
        "INSERT INTO corrections(id,detection_id,kind,cell_id,cx,cy,diameter,created_at) VALUES(?1,?2,?3,?4,?5,?6,?7,?8)",
        params![correction_id,detection_id,kind,cell_id,cell.cx,cell.cy,
            if matches!(action, ReviewAction::Resize) { diameter_um.unwrap() } else { cell.diameter_um },now_iso8601()],
    ).map_err(|e| e.to_string())?;
    if !matches!(action, ReviewAction::Keep) {
        // Modify only the selected JSON element of the current stored result.
        // Neither the frontend nor Rust decodes/replaces sibling contours, and
        // unknown future measurement properties survive these edits unchanged.
        let index: i64 = tx
            .query_row(
                "SELECT j.key FROM detections d,json_each(d.cells_json) j
             WHERE d.id=?1 AND json_extract(j.value,'$.id')=?2 LIMIT 1",
                params![detection_id, cell_id],
                |r| r.get(0),
            )
            .map_err(|e| e.to_string())?;
        let path = format!("$[{index}]");
        match action {
            ReviewAction::Reject => {
                tx.execute(
                "UPDATE detections SET cells_json=json_remove(cells_json,?2),cell_count=cell_count-1 WHERE id=?1",
                params![detection_id,path],
            ).map_err(|e| e.to_string())?;
            }
            ReviewAction::Resize => {
                tx.execute(
                    "UPDATE detections SET cells_json=json_set(cells_json,?2,?3,?4,?5) WHERE id=?1",
                    params![
                        detection_id,
                        format!("{path}.diameter"),
                        diameter_um.unwrap(),
                        format!("{path}.diameterPx"),
                        diameter_um.unwrap() * scale
                    ],
                )
                .map_err(|e| e.to_string())?;
            }
            ReviewAction::Keep => unreachable!(),
        }
        tx.execute(
            "UPDATE detections SET min_confidence=COALESCE((
               SELECT MIN(json_extract(j.value,'$.confidence')) FROM json_each(cells_json) j
             ),1.0) WHERE id=?1",
            [detection_id],
        )
        .map_err(|e| e.to_string())?;
    }
    tx.execute(
        "UPDATE detections SET uncorrected_count=(
           SELECT COUNT(*) FROM review_candidates r WHERE r.detection_id=?1
             AND NOT EXISTS(SELECT 1 FROM corrections c WHERE c.detection_id=r.detection_id AND c.cell_id=r.cell_id)
         ) WHERE id=?1", [detection_id],
    ).map_err(|e| e.to_string())?;
    tx.commit().map_err(|e| e.to_string())?;
    Ok(Some(correction_id))
}

fn prepare_undo(
    conn: &Connection,
    detection_id: &str,
    cell_id: &str,
) -> Result<Option<UndoRecord>, String> {
    conn.query_row(
        "SELECT d.ran_at,d.detector_id,j.key,j.value FROM detections d,json_each(d.cells_json) j
         WHERE d.id=?1 AND json_extract(j.value,'$.id')=?2 AND length(CAST(j.value AS BLOB))<=?3
           AND NOT EXISTS(SELECT 1 FROM corrections WHERE detection_id=?1 AND cell_id=?2) LIMIT 1",
        params![detection_id, cell_id, MAX_UNDO_BYTES],
        |row| {
            Ok(UndoRecord {
                token: uuid::Uuid::new_v4().to_string(),
                detection_id: detection_id.into(),
                cell_id: cell_id.into(),
                correction_id: String::new(),
                ran_at: row.get(0)?,
                detector_id: row.get(1)?,
                index: row.get(2)?,
                before: row.get(3)?,
                after: None,
            })
        },
    )
    .optional()
    .map_err(|e| e.to_string())
}

fn finish_undo(conn: &Connection, mut record: UndoRecord) -> Result<UndoRecord, String> {
    record.correction_id = conn.query_row(
        "SELECT id FROM corrections WHERE detection_id=?1 AND cell_id=?2 ORDER BY rowid DESC LIMIT 1",
        params![record.detection_id,record.cell_id], |r| r.get(0),
    ).map_err(|e| e.to_string())?;
    record.after = conn
        .query_row(
            "SELECT j.value FROM detections d,json_each(d.cells_json) j
         WHERE d.id=?1 AND json_extract(j.value,'$.id')=?2 LIMIT 1",
            params![record.detection_id, record.cell_id],
            |r| r.get(0),
        )
        .optional()
        .map_err(|e| e.to_string())?;
    Ok(record)
}

fn undo(conn: &mut Connection, record: &UndoRecord) -> Result<(), String> {
    let tx = conn
        .transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)
        .map_err(|e| e.to_string())?;
    let revision: Option<(String, String)> = tx
        .query_row(
            "SELECT ran_at,detector_id FROM detections WHERE id=?1",
            [&record.detection_id],
            |r| Ok((r.get(0)?, r.get(1)?)),
        )
        .optional()
        .map_err(|e| e.to_string())?;
    let conflict = "Cannot undo: this saved result changed after your Review decision.";
    if revision != Some((record.ran_at.clone(), record.detector_id.clone())) {
        return Err(conflict.into());
    }
    let current: Option<String> = tx
        .query_row(
            "SELECT j.value FROM detections d,json_each(d.cells_json) j
         WHERE d.id=?1 AND json_extract(j.value,'$.id')=?2 LIMIT 1",
            params![record.detection_id, record.cell_id],
            |r| r.get(0),
        )
        .optional()
        .map_err(|e| e.to_string())?;
    let value = |json: &Option<String>| -> Result<Option<serde_json::Value>, String> {
        json.as_ref()
            .map(|s| serde_json::from_str(s).map_err(|e| e.to_string()))
            .transpose()
    };
    if value(&current)? != value(&record.after)? {
        return Err(conflict.into());
    }
    let audit_matches: bool = tx.query_row(
        "SELECT COUNT(*)=1 AND MAX(id)=?3 FROM corrections WHERE detection_id=?1 AND cell_id=?2",
        params![record.detection_id,record.cell_id,record.correction_id], |r| r.get(0),
    ).map_err(|e| e.to_string())?;
    if !audit_matches {
        return Err(conflict.into());
    }
    tx.execute(
        "DELETE FROM corrections WHERE id=?1",
        [&record.correction_id],
    )
    .map_err(|e| e.to_string())?;
    if record.after.as_ref() != Some(&record.before) {
        if record.after.is_none() {
            // Restore a rejected cell at its original array position. Other
            // cells (and unknown measurement fields) stay exactly as saved.
            tx.execute(
                "UPDATE detections SET cells_json=(SELECT json_group_array(json(value)) FROM (
                   SELECT j.key AS position,j.value AS value FROM json_each(cells_json) j
                   UNION ALL SELECT ?2-0.5,?3 ORDER BY position
                 )),cell_count=cell_count+1 WHERE id=?1",
                params![record.detection_id, record.index, record.before],
            )
            .map_err(|e| e.to_string())?;
        } else {
            let index: i64 = tx.query_row(
                "SELECT j.key FROM detections d,json_each(d.cells_json) j WHERE d.id=?1 AND json_extract(j.value,'$.id')=?2",
                params![record.detection_id,record.cell_id], |r| r.get(0),
            ).map_err(|e| e.to_string())?;
            tx.execute(
                "UPDATE detections SET cells_json=json_set(cells_json,?2,json(?3)) WHERE id=?1",
                params![record.detection_id, format!("$[{index}]"), record.before],
            )
            .map_err(|e| e.to_string())?;
        }
        tx.execute("UPDATE detections SET min_confidence=COALESCE((SELECT MIN(json_extract(j.value,'$.confidence')) FROM json_each(cells_json) j),1.0) WHERE id=?1",
            [&record.detection_id]).map_err(|e| e.to_string())?;
    }
    tx.execute("UPDATE detections SET uncorrected_count=(SELECT COUNT(*) FROM review_candidates r WHERE r.detection_id=?1
        AND NOT EXISTS(SELECT 1 FROM corrections c WHERE c.detection_id=r.detection_id AND c.cell_id=r.cell_id)) WHERE id=?1",
        [&record.detection_id]).map_err(|e| e.to_string())?;
    tx.commit().map_err(|e| e.to_string())
}

#[tauri::command]
pub async fn review_decision(
    db: State<'_, Db>,
    undo_state: State<'_, ReviewUndoState>,
    detection_id: String,
    cell_id: String,
    action: ReviewAction,
    diameter_um: Option<f64>,
) -> Result<ReviewDecisionOutcome, String> {
    let mut conn = db.connection()?;
    let mut last = undo_state
        .0
        .lock()
        .map_err(|_| "Review undo state is unavailable.")?;
    let before = prepare_undo(&conn, &detection_id, &cell_id)?;
    let applied = decide(&mut conn, &detection_id, &cell_id, action, diameter_um)?;
    // The write already committed. A memento capture error must not report the
    // decision as failed or tempt the UI to apply it a second time.
    *last = before
        .filter(|_| applied.is_some())
        .and_then(|record| finish_undo(&conn, record).ok())
        .filter(|record| Some(&record.correction_id) == applied.as_ref());
    Ok(ReviewDecisionOutcome {
        undo_token: last.as_ref().map(|r| r.token.clone()),
        undo_unavailable_reason: if last.is_none() {
            Some("Decision saved. Undo is unavailable because this cell changed or its record exceeds 16 MiB.".into())
        } else {
            None
        },
    })
}

#[tauri::command]
pub async fn review_undo(
    db: State<'_, Db>,
    undo_state: State<'_, ReviewUndoState>,
    token: String,
) -> Result<(), String> {
    let mut conn = db.connection()?;
    let mut last = undo_state
        .0
        .lock()
        .map_err(|_| "Review undo state is unavailable.")?;
    let record = last.as_ref().filter(|r| r.token == token)
        .ok_or("This decision can no longer be undone. Only the last Review decision in this app session is available.")?;
    undo(&mut conn, record)?;
    *last = None;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::{json, Value};

    struct Fixture {
        root: std::path::PathBuf,
        store: FileStore,
    }
    impl Fixture {
        fn new() -> Self {
            let root = std::env::temp_dir().join(format!("review-{}", uuid::Uuid::new_v4()));
            Self {
                store: FileStore::new(&root).unwrap(),
                root,
            }
        }
        fn connection(&self) -> Connection {
            let conn = Connection::open(self.store.db_path()).unwrap();
            conn.pragma_update(None, "foreign_keys", "ON").unwrap();
            super::super::schema::create_schema(&conn).unwrap();
            conn
        }
    }
    impl Drop for Fixture {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.root);
        }
    }
    fn cell(id: &str, confidence: f64) -> Value {
        json!({"id":id,"cx":10.0,"cy":20.0,"diameter":8.0,"diameterPx":16.0,
            "confidence":confidence,"contourFlat":[0,0,2,0,2,2],"futureMeasurement":{"retain":true}})
    }
    fn insert(conn: &Connection, id: &str, cells: &[Value]) {
        conn.execute(
            "INSERT INTO images(id,file_name,original_path,width_px,height_px,imported_at)
            VALUES(?1,?2,'/source.png',1024,1024,'2026-09-08')",
            params![id, format!("{id}.png")],
        )
        .unwrap();
        conn.execute("INSERT INTO detections(id,image_id,detector_id,ran_at,cells_json,min_confidence,cell_count,uncorrected_count)
            VALUES(?1,?1,'cp-cyto3','2026-09-08',?2,0.1,?3,?4)",
            params![id,serde_json::to_string(cells).unwrap(),cells.len(),cells.iter().filter(|c| c["confidence"].as_f64().unwrap()<CUTOFF).count()]).unwrap();
    }
    fn saved(conn: &Connection, id: &str) -> Value {
        let json: String = conn
            .query_row("SELECT cells_json FROM detections WHERE id=?1", [id], |r| {
                r.get(0)
            })
            .unwrap();
        serde_json::from_str(&json).unwrap()
    }
    fn audit_count(conn: &Connection) -> i64 {
        conn.query_row("SELECT COUNT(*) FROM corrections", [], |r| r.get(0))
            .unwrap()
    }

    #[test]
    fn pages_over_1200_cells_remain_compact_and_keeps_survive_real_reopen() {
        let f = Fixture::new();
        let mut skipped = Vec::new();
        {
            let mut conn = f.connection();
            let cells: Vec<_> = (0..1205)
                .map(|i| cell(&format!("cell-{i:04}"), (i % 5) as f64 / 10.0))
                .collect();
            insert(&conn, "first", &cells);
            insert(
                &conn,
                "second",
                &[cell("cell-0000", 0.1), cell("at-cutoff", 0.65)],
            );
            // Represents a correction made by the old application before upgrade.
            conn.execute("INSERT INTO corrections VALUES('old','first','move','cell-0001',10,20,8,'2026-01-01')", []).unwrap();
            conn.execute(
                "UPDATE detections SET uncorrected_count=uncorrected_count-1 WHERE id='first'",
                [],
            )
            .unwrap();
            migrate(&conn).unwrap();
            let mut after = None;
            let mut seen = std::collections::HashSet::new();
            loop {
                let result = page(&conn, &f.store, after, 64).unwrap();
                assert!(result.items.len() <= 64);
                assert!(serde_json::to_vec(&result).unwrap().len() < 100_000);
                for item in &result.items {
                    assert!(item.cell.contour_px.is_none());
                    assert!(seen.insert(item.key.clone()), "duplicate keyset item");
                    if seen.len() % 7 == 0 {
                        skipped.push(item.key.clone());
                    } else {
                        decide(
                            &mut conn,
                            &item.detection_id,
                            &item.cell.id,
                            ReviewAction::Keep,
                            None,
                        )
                        .unwrap();
                    }
                }
                after = result.next_cursor;
                if after.is_none() {
                    break;
                }
            }
            assert_eq!(seen.len(), 1205);
            assert!(
                seen.contains("second:cell-0000"),
                "cell ids are detection-scoped"
            );
            assert!(!seen.contains("first:cell-0001"));
        }
        let db = Db::open(f.store.clone()).unwrap();
        let conn = db.connection().unwrap();
        let mut actual = Vec::new();
        let mut after = None;
        loop {
            let result = page(&conn, &f.store, after, 64).unwrap();
            assert_eq!(result.total_pending, skipped.len() as i64);
            actual.extend(result.items.into_iter().map(|item| item.key));
            after = result.next_cursor;
            if after.is_none() {
                break;
            }
        }
        assert_eq!(actual, skipped, "only skipped cells reappear after reopen");
    }

    #[test]
    fn page_reads_do_not_parse_saved_contours_or_rebuild_index_on_reopen() {
        let f = Fixture::new();
        let conn = f.connection();
        insert(&conn, "first", &[cell("a", 0.1)]);
        migrate(&conn).unwrap();
        assert!(context(&conn, "first", "a")
            .unwrap()
            .unwrap()
            .cell
            .contour_px
            .is_some());
        // Known-negative control: corrupt the mask behind the index. A context
        // read MUST fail, while page/index reads must remain independent of it.
        conn.execute_batch(
            "DROP TRIGGER review_detection_update; UPDATE detections SET cells_json='broken';",
        )
        .unwrap();
        assert!(context(&conn, "first", "a").is_err());
        assert_eq!(page(&conn, &f.store, None, 64).unwrap().items.len(), 1);
        migrate(&conn).unwrap();
        assert_eq!(page(&conn, &f.store, None, 64).unwrap().items.len(), 1);
    }

    #[test]
    fn decisions_use_latest_mask_preserve_unknown_fields_and_retry_once() {
        let f = Fixture::new();
        let mut conn = f.connection();
        migrate(&conn).unwrap();
        insert(
            &conn,
            "first",
            &[cell("a", 0.1), cell("b", 0.2), cell("c", 0.3)],
        );
        let stale_page = page(&conn, &f.store, None, 64).unwrap();
        assert_eq!(stale_page.items.len(), 3);
        // Another editor changed a sibling AFTER the page snapshot.
        conn.execute("UPDATE detections SET cells_json=json_set(cells_json,'$[2].cx',333.0) WHERE id='first'", []).unwrap();
        decide(&mut conn, "first", "a", ReviewAction::Reject, None).unwrap();
        decide(&mut conn, "first", "b", ReviewAction::Resize, Some(22.0)).unwrap();
        decide(&mut conn, "first", "b", ReviewAction::Resize, Some(99.0)).unwrap();
        let cells = saved(&conn, "first");
        assert_eq!(cells.as_array().unwrap().len(), 2);
        assert_eq!(cells[0]["id"], "b");
        assert_eq!(cells[0]["diameter"], 22.0);
        assert_eq!(cells[0]["diameterPx"], 22.0); // unbatched scale = 1
        assert_eq!(cells[1]["cx"], 333.0);
        assert_eq!(cells[1]["futureMeasurement"]["retain"], true);
        assert_eq!(cells[0]["contourFlat"], json!([0, 0, 2, 0, 2, 2]));
        assert_eq!(audit_count(&conn), 2);
        let pending = page(&conn, &f.store, None, 64).unwrap();
        assert_eq!(pending.total_pending, 1);
        assert_eq!(pending.items[0].cell.id, "c");
        conn.execute("DELETE FROM images WHERE id='first'", [])
            .unwrap();
        assert!(page(&conn, &f.store, None, 64).unwrap().items.is_empty());
        assert_eq!(audit_count(&conn), 0);
    }

    #[test]
    fn failed_decision_rolls_back_mask_audit_counter_and_candidate_index() {
        let f = Fixture::new();
        let mut conn = f.connection();
        migrate(&conn).unwrap();
        insert(&conn, "first", &[cell("a", 0.1), cell("b", 0.2)]);
        let before = saved(&conn, "first");
        conn.execute_batch(
            "CREATE TRIGGER refuse_review AFTER UPDATE OF cells_json ON detections
            BEGIN SELECT RAISE(ABORT,'simulated disk write failure'); END;",
        )
        .unwrap();
        assert!(decide(&mut conn, "first", "a", ReviewAction::Reject, None).is_err());
        assert_eq!(saved(&conn, "first"), before);
        assert_eq!(audit_count(&conn), 0);
        let result = page(&conn, &f.store, None, 64).unwrap();
        assert_eq!(result.items.len(), 2);
        assert_eq!(result.total_pending, 2);
        conn.execute_batch("DROP TRIGGER refuse_review").unwrap();
        decide(&mut conn, "first", "a", ReviewAction::Reject, None).unwrap();
        assert_eq!(audit_count(&conn), 1);
    }

    #[test]
    fn visible_context_is_bounded_and_does_not_modify_large_original_contours() {
        let f = Fixture::new();
        let conn = f.connection();
        migrate(&conn).unwrap();
        let mut cells: Vec<_> = (0..200).map(|i| cell(&format!("c{i}"), 0.1)).collect();
        cells[0]["contourFlat"] = json!(vec![12_345.0; 20_000]);
        insert(&conn, "first", &cells);
        let result = context(&conn, "first", "c0").unwrap().unwrap();
        assert!(result.limited);
        assert!(result.cell.contour_px.is_none());
        assert_eq!(result.neighbors.len(), MAX_NEIGHBORS);
        assert!(serde_json::to_vec(&result).unwrap().len() < 65_536);
        assert_eq!(
            saved(&conn, "first")[0]["contourFlat"]
                .as_array()
                .unwrap()
                .len(),
            20_000
        );
    }

    #[test]
    fn invalid_inputs_do_not_write_and_migration_failure_can_retry_atomically() {
        let f = Fixture::new();
        let mut conn = f.connection();
        insert(&conn, "first", &[cell("a", 0.1)]);
        conn.execute("UPDATE detections SET cells_json='broken'", [])
            .unwrap();
        assert!(migrate(&conn).is_err());
        conn.execute(
            "UPDATE detections SET cells_json=?1",
            [json!([cell("a", 0.1)]).to_string()],
        )
        .unwrap();
        migrate(&conn).unwrap();
        for size in [0, 65, usize::MAX] {
            assert!(page(&conn, &f.store, None, size).is_err());
        }
        for diameter in [f64::NAN, f64::INFINITY, -1.0, 0.0, 1_000_001.0] {
            assert!(decide(
                &mut conn,
                "first",
                "a",
                ReviewAction::Resize,
                Some(diameter)
            )
            .is_err());
        }
        assert_eq!(audit_count(&conn), 0);
        assert_eq!(page(&conn, &f.store, None, 64).unwrap().items.len(), 1);
    }

    #[test]
    fn undo_restores_each_decision_with_original_order_fields_and_review_count() {
        for action in [
            ReviewAction::Keep,
            ReviewAction::Reject,
            ReviewAction::Resize,
        ] {
            let f = Fixture::new();
            let mut conn = f.connection();
            migrate(&conn).unwrap();
            insert(
                &conn,
                "first",
                &[cell("a", 0.1), cell("b", 0.2), cell("c", 0.3)],
            );
            let original = saved(&conn, "first");
            let before = prepare_undo(&conn, "first", "b").unwrap().unwrap();
            let correction_id = decide(&mut conn, "first", "b", action, Some(22.0))
                .unwrap()
                .unwrap();
            let record = finish_undo(&conn, before).unwrap();
            assert_eq!(record.correction_id, correction_id);
            assert_eq!(page(&conn, &f.store, None, 1).unwrap().total_pending, 2);
            undo(&mut conn, &record).unwrap();
            assert_eq!(saved(&conn, "first"), original, "{action:?}");
            assert_eq!(audit_count(&conn), 0);
            assert_eq!(page(&conn, &f.store, None, 1).unwrap().total_pending, 3);
            assert!(undo(&mut conn, &record).is_err(), "cannot undo twice");
        }
    }

    #[test]
    fn undo_rejects_changed_masks_and_rolls_back_if_restoration_write_fails() {
        let f = Fixture::new();
        let mut conn = f.connection();
        migrate(&conn).unwrap();
        insert(&conn, "first", &[cell("a", 0.1), cell("b", 0.2)]);
        let before = prepare_undo(&conn, "first", "a").unwrap().unwrap();
        decide(&mut conn, "first", "a", ReviewAction::Resize, Some(22.0)).unwrap();
        let record = finish_undo(&conn, before).unwrap();
        conn.execute("UPDATE detections SET cells_json=json_set(cells_json,'$[0].cx',321.0) WHERE id='first'", []).unwrap();
        assert!(undo(&mut conn, &record).unwrap_err().contains("changed"));
        assert_eq!(saved(&conn, "first")[0]["cx"], 321.0);
        assert_eq!(audit_count(&conn), 1);
        // Restore expected target but change the detection revision, as a
        // rerun/editor commit would: undo must still refuse the old memento.
        conn.execute(
            "UPDATE detections SET cells_json=json_set(cells_json,'$[0].cx',10.0),ran_at='new-run'",
            [],
        )
        .unwrap();
        assert!(undo(&mut conn, &record).unwrap_err().contains("changed"));
        conn.execute("UPDATE detections SET ran_at='2026-09-08'", [])
            .unwrap();
        let expected = saved(&conn, "first");
        conn.execute_batch("CREATE TRIGGER fail_undo AFTER UPDATE OF cells_json ON detections BEGIN SELECT RAISE(ABORT,'disk full'); END;").unwrap();
        assert!(undo(&mut conn, &record).is_err());
        assert_eq!(saved(&conn, "first"), expected);
        assert_eq!(audit_count(&conn), 1);
        assert_eq!(page(&conn, &f.store, None, 64).unwrap().total_pending, 1);
    }
}
