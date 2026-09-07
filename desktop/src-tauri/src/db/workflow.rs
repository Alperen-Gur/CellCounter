//! Durable workflow documents with atomic SQLite replacement. Queue summaries
//! can be loaded independently from large variants; no library-wide mask load.

use std::io::Write;

use rusqlite::{params, Connection, OptionalExtension};
use serde_json::Value;
use tauri::State;

use super::repo::Db;

const MAX_DOCUMENT_BYTES: usize = 16 * 1024 * 1024;

fn validate_key(key: &str) -> Result<(), String> {
    if key == "jobs" {
        return Ok(());
    }
    if let Some(id) = key
        .strip_prefix("variant-")
        .or_else(|| key.strip_prefix("run-"))
    {
        if id.len() == 36
            && uuid::Uuid::parse_str(id).is_ok_and(|uuid| uuid.hyphenated().to_string() == id)
        {
            return Ok(());
        }
    }
    Err("Invalid workflow key. Use jobs, variant-{UUID}, or run-{UUID}.".to_string())
}

struct BoundedJson(Vec<u8>);

impl Write for BoundedJson {
    fn write(&mut self, bytes: &[u8]) -> std::io::Result<usize> {
        if bytes.len() > MAX_DOCUMENT_BYTES.saturating_sub(self.0.len()) {
            return Err(std::io::Error::new(
                std::io::ErrorKind::InvalidData,
                "Workflow documents must be no larger than 16 MiB. Save fewer mask variants per document.",
            ));
        }
        self.0.extend_from_slice(bytes);
        Ok(bytes.len())
    }

    fn flush(&mut self) -> std::io::Result<()> {
        Ok(())
    }
}

fn save(conn: &Connection, key: &str, document: &Value) -> Result<(), String> {
    validate_key(key)?;
    // Bound serialization as it happens, before SQLite sees a write. A failed
    // validation, serialization or statement leaves the previous document intact.
    let mut encoded = BoundedJson(Vec::new());
    serde_json::to_writer(&mut encoded, document)
        .map_err(|error| format!("Could not save workflow document: {error}"))?;
    let json = String::from_utf8(encoded.0).map_err(|error| error.to_string())?;
    conn.execute(
        "INSERT INTO workflow_documents (key, document_json) VALUES (?1, ?2)
         ON CONFLICT(key) DO UPDATE SET document_json = excluded.document_json",
        params![key, json],
    )
    .map_err(|error| {
        format!("Could not save workflow document. Retry after checking free disk space: {error}")
    })?;
    Ok(())
}

fn load(conn: &Connection, key: &str) -> Result<Option<Value>, String> {
    validate_key(key)?;
    // Check size inside SQLite before returning text to Rust. This also keeps
    // a corrupt/externally modified database from bypassing the read limit.
    let stored: Option<Option<String>> = conn
        .query_row(
            "SELECT CASE WHEN length(CAST(document_json AS BLOB)) <= ?2
                     THEN document_json ELSE NULL END
           FROM workflow_documents WHERE key = ?1",
            params![key, MAX_DOCUMENT_BYTES as i64],
            |row| row.get(0),
        )
        .optional()
        .map_err(|error| format!("Could not load workflow document: {error}"))?;
    match stored {
        None => Ok(None),
        Some(None) => {
            Err("This workflow document exceeds 16 MiB and could not be loaded.".to_string())
        }
        Some(Some(json)) => serde_json::from_str(&json).map(Some).map_err(|error| {
            format!("This workflow document is damaged and could not be loaded: {error}")
        }),
    }
}

fn delete(conn: &Connection, key: &str) -> Result<(), String> {
    validate_key(key)?;
    conn.execute("DELETE FROM workflow_documents WHERE key = ?1", [key])
        .map_err(|error| format!("Could not delete workflow document: {error}"))?;
    Ok(())
}

/// Clear jobs/settings/variants in the same transaction as image records, so a
/// library wipe cannot leave resumable jobs referring to deleted images.
pub(crate) fn wipe_library_rows(conn: &mut Connection) -> Result<(), String> {
    let transaction = conn.transaction().map_err(|error| error.to_string())?;
    transaction
        .execute_batch(
            "DELETE FROM workflow_documents;
         DELETE FROM batches;
         DELETE FROM images;",
        )
        .map_err(|error| error.to_string())?;
    transaction.commit().map_err(|error| error.to_string())
}

#[tauri::command]
pub fn load_workflow_document(db: State<'_, Db>, key: String) -> Result<Option<Value>, String> {
    let conn = db.connection()?;
    load(&conn, &key)
}

#[tauri::command]
pub fn save_workflow_document(
    db: State<'_, Db>,
    key: String,
    document: Value,
) -> Result<(), String> {
    let conn = db.connection()?;
    save(&conn, &key, &document)
}

#[tauri::command]
pub fn delete_workflow_document(db: State<'_, Db>, key: String) -> Result<(), String> {
    let conn = db.connection()?;
    delete(&conn, &key)
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn database() -> Connection {
        let conn = Connection::open_in_memory().unwrap();
        super::super::schema::create_schema(&conn).unwrap();
        conn
    }

    #[test]
    fn persists_replaces_and_deletes_independent_documents_across_reopen() {
        let path = std::env::temp_dir().join(format!("workflow-{}.sqlite", uuid::Uuid::new_v4()));
        let variant_key = format!("variant-{}", uuid::Uuid::new_v4());
        let run_key = format!("run-{}", uuid::Uuid::new_v4());
        {
            let conn = Connection::open(&path).unwrap();
            super::super::schema::create_schema(&conn).unwrap();
            assert_eq!(load(&conn, "jobs").unwrap(), None);
            save(&conn, "jobs", &json!({"jobs": [{"status": "queued"}]})).unwrap();
            save(&conn, &variant_key, &json!({"cells": [1, 2, 3]})).unwrap();
            save(&conn, &run_key, &json!({"modelId": "cpsam_v2"})).unwrap();
            save(&conn, "jobs", &json!({"jobs": [{"status": "paused"}]})).unwrap();
        }
        {
            let conn = Connection::open(&path).unwrap();
            assert_eq!(
                load(&conn, "jobs").unwrap().unwrap()["jobs"][0]["status"],
                "paused"
            );
            assert_eq!(
                load(&conn, &variant_key).unwrap(),
                Some(json!({"cells": [1, 2, 3]}))
            );
            assert_eq!(
                load(&conn, &run_key).unwrap().unwrap()["modelId"],
                "cpsam_v2"
            );
            delete(&conn, &variant_key).unwrap();
            delete(&conn, &variant_key).unwrap();
            assert_eq!(load(&conn, &variant_key).unwrap(), None);
            assert!(load(&conn, "jobs").unwrap().is_some());
        }
        std::fs::remove_file(path).unwrap();
    }

    #[test]
    fn rejects_unconfined_or_noncanonical_keys_on_every_operation() {
        let conn = database();
        for key in [
            "",
            "../jobs",
            "jobs.json",
            "jobs/extra",
            "variant-not-a-uuid",
            "run-{34d7b492-7935-44c5-9a03-3b4a57b7004c}",
            "variant-34d7b492793544c59a033b4a57b7004c",
            "unknown",
        ] {
            assert!(save(&conn, key, &json!({})).is_err(), "{key}");
            assert!(load(&conn, key).is_err(), "{key}");
            assert!(delete(&conn, key).is_err(), "{key}");
        }
    }

    #[test]
    fn byte_limit_rejects_oversize_without_replacing_saved_state() {
        let conn = database();
        save(&conn, "jobs", &json!({"keep": true})).unwrap();
        // Unicode counts as bytes, not characters. Serialized quotes also count.
        let oversized = Value::String("µ".repeat(MAX_DOCUMENT_BYTES / 2));
        let error = save(&conn, "jobs", &oversized).unwrap_err();
        assert!(error.contains("16 MiB"), "{error}");
        assert_eq!(load(&conn, "jobs").unwrap(), Some(json!({"keep": true})));
        let at_limit = Value::String("x".repeat(MAX_DOCUMENT_BYTES - 2));
        save(&conn, "jobs", &at_limit).unwrap();
        assert_eq!(load(&conn, "jobs").unwrap(), Some(at_limit));
    }

    #[test]
    fn damaged_or_oversized_stored_documents_do_not_look_like_missing_state() {
        let conn = database();
        conn.execute("INSERT INTO workflow_documents VALUES ('jobs', '{')", [])
            .unwrap();
        assert!(load(&conn, "jobs").unwrap_err().contains("damaged"));
        conn.pragma_update(None, "ignore_check_constraints", "ON")
            .unwrap();
        conn.execute(
            "UPDATE workflow_documents SET document_json = ?1 WHERE key = 'jobs'",
            ["x".repeat(MAX_DOCUMENT_BYTES + 1)],
        )
        .unwrap();
        assert!(load(&conn, "jobs").unwrap_err().contains("16 MiB"));
    }

    #[test]
    fn library_wipe_clears_workflows_and_images_but_keeps_presets() {
        let mut conn = database();
        conn.execute(
            "INSERT INTO images (id, file_name, original_path, width_px, height_px, imported_at)
            VALUES ('image', 'local.png', '/local.png', 10, 10, '2026-09-08')",
            [],
        )
        .unwrap();
        conn.execute(
            "INSERT INTO calibration_presets (id, name, px_per_um, is_default)
            VALUES ('preset', 'Saved calibration', 2.5, 0)",
            [],
        )
        .unwrap();
        save(&conn, "jobs", &json!({"jobs": [{"imageId": "image"}]})).unwrap();
        wipe_library_rows(&mut conn).unwrap();
        assert_eq!(load(&conn, "jobs").unwrap(), None);
        let count: i64 = conn
            .query_row("SELECT COUNT(*) FROM images", [], |row| row.get(0))
            .unwrap();
        assert_eq!(count, 0);
        let count: i64 = conn
            .query_row("SELECT COUNT(*) FROM calibration_presets", [], |row| {
                row.get(0)
            })
            .unwrap();
        assert_eq!(count, 1);
    }

    #[test]
    fn failed_library_wipe_rolls_back_workflow_deletion() {
        let mut conn = database();
        save(&conn, "jobs", &json!({"jobs": []})).unwrap();
        conn.execute_batch("DROP TABLE batches;").unwrap();
        assert!(wipe_library_rows(&mut conn).is_err());
        assert_eq!(load(&conn, "jobs").unwrap(), Some(json!({"jobs": []})));
    }
}
