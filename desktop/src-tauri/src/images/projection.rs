//! Re-project a preserved proprietary source without mutating its imported
//! display or shared analysis TIFF. Each request owns and cleans its derivative.

use std::path::PathBuf;
use std::process::Stdio;
use std::time::Duration;

use rusqlite::OptionalExtension;
use tokio::io::{AsyncRead, AsyncReadExt};
use tokio::process::Command;
use tokio::sync::Notify;

use crate::db::repo::Db;
use crate::paths::FileStore;

pub(crate) struct PreparedSource {
    pub path: String,
    temporary: Option<PathBuf>,
}

impl Drop for PreparedSource {
    fn drop(&mut self) {
        if let Some(path) = &self.temporary {
            let _ = std::fs::remove_file(path);
        }
    }
}

pub(crate) async fn prepare(
    db: &Db,
    store: &FileStore,
    image_path: &str,
    projection: &str,
    cancel: &Notify,
) -> Result<PreparedSource, String> {
    let unchanged = || PreparedSource {
        path: image_path.to_string(),
        temporary: None,
    };
    if projection == "max" {
        return Ok(unchanged());
    }
    // Standard TIFFs are preserved intact and can be projected by the detector.
    // Only vendor imports have an already-projected `analysis_path` column.
    let record: Option<(String, String)> = {
        let conn = db.connection()?;
        conn.query_row(
            "SELECT id, file_name FROM images WHERE analysis_path = ?1",
            [image_path],
            |row| Ok((row.get(0)?, row.get(1)?)),
        )
        .optional()
        .map_err(|error| error.to_string())?
    };
    let Some((id, filename)) = record else {
        return Ok(unchanged());
    };
    let extension = std::path::Path::new(&filename)
        .extension()
        .and_then(|value| value.to_str())
        .unwrap_or("")
        .to_ascii_lowercase();
    let original = store.original_path(&id, &extension);
    if !original.is_file() {
        return Err("The preserved microscopy source is missing. Reimport the original container to select a different Z projection.".to_string());
    }
    let python = store.venv_io_python();
    if !python.is_file() {
        return Err("Changing this container's Z projection needs the microscopy reader. Reinstall a model from Models, then retry.".to_string());
    }
    let output_path = store
        .analysis_dir()
        .join(format!("projection-{}.tiff", uuid::Uuid::new_v4()));
    let prepared = PreparedSource {
        path: output_path.to_string_lossy().into_owned(),
        temporary: Some(output_path.clone()),
    };
    let mut command = Command::new(python);
    command
        .arg(store.python_script("image_prepare.py"))
        .arg("--analysis-only")
        .arg("--image")
        .arg(original)
        .arg("--analysis-output")
        .arg(&output_path)
        .args(["--z-project", projection])
        .current_dir(store.python_dir())
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .kill_on_drop(true);
    crate::proc::hide_console_tokio(&mut command);
    let mut child = command
        .spawn()
        .map_err(|error| format!("Could not start the microscopy reader: {error}"))?;
    let stdout = child
        .stdout
        .take()
        .ok_or("Microscopy reader stdout is unavailable")?;
    let stderr = child
        .stderr
        .take()
        .ok_or("Microscopy reader stderr is unavailable")?;
    let stdout_task = tokio::spawn(read_pipe(stdout));
    let stderr_task = tokio::spawn(read_pipe(stderr));
    let status = tokio::select! {
        biased;
        _ = cancel.notified() => Err("Source projection was cancelled.".to_string()),
        result = tokio::time::timeout(Duration::from_secs(20 * 60), child.wait()) => {
            match result {
                Ok(result) => result.map_err(|error| format!("Microscopy reader failed: {error}")),
                Err(_) => Err("Source projection timed out after 20 minutes. Retry with a smaller source stack.".to_string()),
            }
        }
    };
    if status.is_err() {
        let _ = child.start_kill();
        // Wait for file handles to close before the temporary TIFF is removed,
        // including on Windows where deleting an open file can fail.
        let _ = child.wait().await;
    }
    let stdout = stdout_task.await.map_err(|error| error.to_string())??;
    let _stderr = stderr_task.await.map_err(|error| error.to_string())??;
    let status = status?;
    if !status.success() || !output_path.is_file() {
        let payload: serde_json::Value = serde_json::from_slice(&stdout).unwrap_or_default();
        let hint = payload
            .get("hint")
            .and_then(|value| value.as_str())
            .unwrap_or(
                "Could not prepare the selected source projection. Check the source and retry.",
            );
        return Err(hint.to_string());
    }
    Ok(prepared)
}

async fn read_pipe(pipe: impl AsyncRead + Unpin) -> Result<Vec<u8>, String> {
    const LIMIT: usize = 1024 * 1024;
    let mut bytes = Vec::new();
    pipe.take((LIMIT + 1) as u64)
        .read_to_end(&mut bytes)
        .await
        .map_err(|error| error.to_string())?;
    if bytes.len() > LIMIT {
        return Err("The microscopy reader returned too much diagnostic output.".to_string());
    }
    Ok(bytes)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn standard_source_stays_intact_and_vendor_never_falls_back_when_original_is_missing() {
        let root = std::env::temp_dir().join(format!("projection-test-{}", uuid::Uuid::new_v4()));
        let store = FileStore::new(&root).unwrap();
        let db = Db::open(store.clone()).unwrap();
        let cancel = Notify::new();
        let source = prepare(&db, &store, "standard.tiff", "mean", &cancel)
            .await
            .unwrap();
        assert_eq!(source.path, "standard.tiff");
        assert!(source.temporary.is_none());
        let analysis = store.analysis_path("vendor").to_string_lossy().into_owned();
        db.connection().unwrap().execute(
            "INSERT INTO images (id, file_name, original_path, width_px, height_px, imported_at, analysis_path)
             VALUES ('vendor', 'sample.czi', '/external/source.czi', 8, 6, '2026-09-08', ?1)", [&analysis]
        ).unwrap();
        let unchanged = prepare(&db, &store, &analysis, "max", &cancel)
            .await
            .unwrap();
        assert_eq!(unchanged.path, analysis);
        let error = prepare(&db, &store, &analysis, "sum", &cancel)
            .await
            .err()
            .unwrap();
        assert!(
            error.contains("preserved microscopy source is missing"),
            "{error}"
        );
        drop(db);
        std::fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn projected_files_are_removed_without_deleting_the_imported_source() {
        let path = std::env::temp_dir().join(format!("projection-{}.tiff", uuid::Uuid::new_v4()));
        std::fs::write(&path, b"temporary projection").unwrap();
        drop(PreparedSource {
            path: path.to_string_lossy().into_owned(),
            temporary: Some(path.clone()),
        });
        assert!(!path.exists());
        std::fs::write(&path, b"preserved source").unwrap();
        drop(PreparedSource {
            path: path.to_string_lossy().into_owned(),
            temporary: None,
        });
        assert!(path.exists());
        std::fs::remove_file(path).unwrap();
    }

    #[tokio::test]
    async fn reader_diagnostics_are_bounded() {
        assert_eq!(read_pipe(b"ready".as_slice()).await.unwrap(), b"ready");
        let oversized = vec![b'x'; 1024 * 1024 + 1];
        assert!(read_pipe(oversized.as_slice())
            .await
            .unwrap_err()
            .contains("too much"));
    }
}
