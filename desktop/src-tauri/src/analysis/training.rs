//! Local Cellpose 3 fine-tuning with explicit checkpoint lineage.

use std::collections::{BTreeMap, VecDeque};
use std::path::{Path, PathBuf};
use std::process::Stdio;
use std::sync::Mutex;

use rusqlite::OptionalExtension;
use serde::{Deserialize, Serialize};
use tauri::{AppHandle, Emitter, State};
use tokio::io::{AsyncBufReadExt, BufReader};
use tokio::process::Command;
use tokio::sync::oneshot;
use uuid::Uuid;

use crate::db::models::ModelVersionDto;
use crate::db::repo::{self, Db};
use crate::paths::FileStore;

const TRAINING_EVENT: &str = "training://progress";

#[derive(Default)]
pub struct TrainingManager {
    active: Mutex<Option<ActiveTraining>>,
}

struct ActiveTraining {
    run_id: String,
    cancel: oneshot::Sender<()>,
}

struct CheckpointCleanup {
    staging_dir: PathBuf,
    final_path: PathBuf,
    committed: bool,
}

impl Drop for CheckpointCleanup {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.staging_dir);
        if !self.committed {
            let _ = std::fs::remove_file(&self.final_path);
        }
    }
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TrainingRequest {
    pub run_id: String,
    pub dataset_dir: String,
    pub epochs: i64,
    pub learning_rate: f64,
    pub batch_size: i64,
    pub augment: bool,
    pub early_stop: bool,
    pub mixed_precision: bool,
    pub resume_version_id: Option<String>,
}

#[derive(Clone, Serialize)]
#[serde(rename_all = "camelCase")]
struct TrainingEvent {
    run_id: String,
    stream: String,
    line: String,
}

fn validate_request(request: &TrainingRequest) -> Result<(), String> {
    if request.run_id.is_empty() || request.run_id.len() > 128 || request.run_id.contains('\0') {
        return Err("training run id is invalid".to_string());
    }
    if !(6..=500).contains(&request.epochs) {
        return Err("epochs must be between 6 and 500 so validation and warmup can run".to_string());
    }
    if !(request.learning_rate.is_finite()
        && request.learning_rate >= 1e-7
        && request.learning_rate <= 0.1)
    {
        return Err("learning rate must be between 0.0000001 and 0.1".to_string());
    }
    if !(1..=128).contains(&request.batch_size) {
        return Err("batch size must be between 1 and 128".to_string());
    }
    if request.mixed_precision {
        return Err("Mixed precision is unavailable in the CPU-only Windows runtime.".to_string());
    }
    Ok(())
}

fn image_mask_pairs(dir: &Path) -> Result<usize, String> {
    const MAX_DEPTH: usize = 64;
    const IMAGE_EXTS: &[&str] = &["png", "jpg", "jpeg", "tif", "tiff", "bmp"];
    fn walk(dir: &Path, depth: usize, count: &mut usize) -> Result<(), String> {
        if depth > MAX_DEPTH {
            return Ok(());
        }
        for entry in std::fs::read_dir(dir).map_err(|error| error.to_string())? {
            let entry = entry.map_err(|error| error.to_string())?;
            let file_type = entry.file_type().map_err(|error| error.to_string())?;
            if file_type.is_symlink() {
                continue;
            }
            let path = entry.path();
            if file_type.is_dir() {
                walk(&path, depth + 1, count)?;
                continue;
            }
            let extension = path
                .extension()
                .and_then(|value| value.to_str())
                .unwrap_or("")
                .to_ascii_lowercase();
            let stem = path.file_stem().and_then(|value| value.to_str()).unwrap_or("");
            if !IMAGE_EXTS.contains(&extension.as_str()) || stem.ends_with("_masks") {
                continue;
            }
            let paired = ["png", "tif", "tiff", "npy"].iter().any(|mask_ext| {
                path.with_file_name(format!("{stem}_masks.{mask_ext}")).is_file()
            });
            if paired {
                *count += 1;
            }
        }
        Ok(())
    }
    if !dir.is_dir() {
        return Err("Choose a folder containing images and matching _masks files.".to_string());
    }
    let mut count = 0;
    walk(dir, 0, &mut count)?;
    Ok(count)
}

fn next_version_and_corrections(db: &Db) -> Result<(i64, i64), String> {
    let conn = db.connection()?;
    let next = conn
        .query_row(
            "SELECT COALESCE(MAX(version), 0) + 1 FROM model_versions WHERE model_id = 'cp-cyto3'",
            [],
            |row| row.get(0),
        )
        .map_err(|error| error.to_string())?;
    let corrections = conn
        .query_row("SELECT COUNT(*) FROM corrections", [], |row| row.get(0))
        .map_err(|error| error.to_string())?;
    Ok((next, corrections))
}

fn resume_checkpoint(db: &Db, id: Option<&str>) -> Result<Option<PathBuf>, String> {
    let Some(id) = id else { return Ok(None) };
    let conn = db.connection()?;
    let path: Option<String> = conn
        .query_row(
            "SELECT checkpoint_path FROM model_versions WHERE id = ?1 AND model_id = 'cp-cyto3'",
            [id],
            |row| row.get(0),
        )
        .optional()
        .map_err(|error| error.to_string())?;
    let path = path.ok_or_else(|| "The selected checkpoint version no longer exists.".to_string())?;
    let models_dir = std::fs::canonicalize(db.store().models_dir())
        .map_err(|error| format!("Could not resolve the model store: {error}"))?;
    let path = std::fs::canonicalize(path)
        .map_err(|error| format!("The selected checkpoint is missing: {error}"))?;
    if !path.is_file() || !path.starts_with(models_dir) {
        return Err("The selected checkpoint is missing or outside CellCounter storage.".to_string());
    }
    Ok(Some(path))
}

async fn pump_lines<R>(
    app: AppHandle,
    run_id: String,
    stream: &'static str,
    reader: R,
) -> Vec<String>
where
    R: tokio::io::AsyncRead + Unpin,
{
    let mut lines = BufReader::new(reader).lines();
    let mut tail = VecDeque::new();
    while let Ok(Some(mut line)) = lines.next_line().await {
        if line.len() > 8192 {
            line.truncate(8192);
            line.push('…');
        }
        if line.trim().is_empty() {
            continue;
        }
        let _ = app.emit(
            TRAINING_EVENT,
            TrainingEvent {
                run_id: run_id.clone(),
                stream: stream.to_string(),
                line: line.clone(),
            },
        );
        if tail.len() == 80 {
            tail.pop_front();
        }
        tail.push_back(line);
    }
    tail.into()
}

fn parse_metrics(lines: &[String]) -> Result<BTreeMap<String, f64>, String> {
    let done = lines
        .iter()
        .rev()
        .find(|line| line.starts_with("DONE "))
        .ok_or_else(|| "Training completed without final evaluation metrics.".to_string())?;
    let mut metrics = BTreeMap::new();
    for field in done.split_whitespace().skip(1) {
        let Some((key, value)) = field.split_once('=') else { continue };
        if let Ok(value) = value.parse::<f64>() {
            if value.is_finite() {
                metrics.insert(key.to_string(), value);
            }
        }
    }
    if metrics.is_empty() {
        Err("Training returned malformed final metrics.".to_string())
    } else {
        Ok(metrics)
    }
}

fn clear_active(manager: &TrainingManager, run_id: &str) {
    if let Ok(mut active) = manager.active.lock() {
        if active.as_ref().is_some_and(|value| value.run_id == run_id) {
            *active = None;
        }
    }
}

#[tauri::command]
pub async fn run_fine_tune(
    app: AppHandle,
    db: State<'_, Db>,
    manager: State<'_, TrainingManager>,
    request: TrainingRequest,
) -> Result<ModelVersionDto, String> {
    validate_request(&request)?;
    let dataset_dir = PathBuf::from(&request.dataset_dir);
    let image_count = tokio::task::spawn_blocking({
        let dataset_dir = dataset_dir.clone();
        move || image_mask_pairs(&dataset_dir)
    })
    .await
    .map_err(|error| format!("Dataset scan failed: {error}"))??;
    if image_count < 3 {
        return Err("Fine-tuning needs at least three image/_masks pairs so train, validation, and test splits are non-empty.".to_string());
    }

    let store = FileStore::from_app(&app)?;
    crate::env::uv::stage_python_project(&app, &store)?;
    let python = store.venv_python();
    let script = store.python_script("cellpose_train.py");
    if !python.exists() || !script.exists() {
        return Err("Install cp-cyto3 before fine-tuning.".to_string());
    }
    let resume = resume_checkpoint(&db, request.resume_version_id.as_deref())?;
    let (version, correction_count) = next_version_and_corrections(&db)?;
    let id = Uuid::new_v4().to_string();
    let final_path = store
        .models_dir()
        .join(format!("cp-cyto3-v{version}-{id}.ccmodel"));
    let staging_dir = store.models_dir().join(format!(".training-{id}"));
    std::fs::create_dir(&staging_dir)
        .map_err(|error| format!("Could not create training workspace: {error}"))?;
    let partial_path = staging_dir.join("checkpoint.partial");
    let mut cleanup = CheckpointCleanup {
        staging_dir: staging_dir.clone(),
        final_path: final_path.clone(),
        committed: false,
    };

    let (cancel, mut cancel_rx) = oneshot::channel();
    {
        let mut active = manager.active.lock().map_err(|_| "training manager is unavailable")?;
        if active.is_some() {
            return Err("Another fine-tuning run is already active.".to_string());
        }
        *active = Some(ActiveTraining {
            run_id: request.run_id.clone(),
            cancel,
        });
    }

    let mut command = Command::new(&python);
    command
        .arg(&script)
        .arg("--images")
        .arg(&dataset_dir)
        .args(["--epochs", &request.epochs.to_string()])
        .args(["--lr", &request.learning_rate.to_string()])
        .args(["--batch-size", &request.batch_size.to_string()])
        .args(["--augment", if request.augment { "1" } else { "0" }])
        .args(["--base-model", "cp-cyto3"])
        .arg("--output")
        .arg(&partial_path)
        .arg("--output-dir")
        .arg(&staging_dir)
        .args(["--early-stop", if request.early_stop { "1" } else { "0" }])
        .args([
            "--mixed-precision",
            if request.mixed_precision { "1" } else { "0" },
        ])
        .current_dir(store.python_dir())
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .kill_on_drop(true);
    if let Some(path) = resume {
        command.arg("--resume").arg(path);
    }
    crate::proc::hide_console_tokio(&mut command);
    let mut child = match command.spawn() {
        Ok(child) => child,
        Err(error) => {
            clear_active(&manager, &request.run_id);
            return Err(format!("Could not start fine-tuning: {error}"));
        }
    };
    let stdout = match child.stdout.take() {
        Some(stdout) => stdout,
        None => {
            clear_active(&manager, &request.run_id);
            let _ = child.start_kill();
            return Err("Training stdout is unavailable".to_string());
        }
    };
    let stderr = match child.stderr.take() {
        Some(stderr) => stderr,
        None => {
            clear_active(&manager, &request.run_id);
            let _ = child.start_kill();
            return Err("Training stderr is unavailable".to_string());
        }
    };
    let stdout_task = tokio::spawn(pump_lines(
        app.clone(),
        request.run_id.clone(),
        "stdout",
        stdout,
    ));
    let stderr_task = tokio::spawn(pump_lines(
        app,
        request.run_id.clone(),
        "stderr",
        stderr,
    ));

    let status = tokio::select! {
        result = child.wait() => result.map_err(|error| format!("Training wait failed: {error}")),
        _ = &mut cancel_rx => {
            let _ = child.start_kill();
            let _ = child.wait().await;
            Err("Fine-tuning was cancelled.".to_string())
        }
    };
    let stdout_lines = stdout_task.await.unwrap_or_default();
    let stderr_lines = stderr_task.await.unwrap_or_default();
    clear_active(&manager, &request.run_id);
    let status = match status {
        Ok(status) => status,
        Err(error) => {
            return Err(error);
        }
    };
    if !status.success() {
        let detail = stderr_lines
            .last()
            .or_else(|| stdout_lines.last())
            .cloned()
            .unwrap_or_else(|| "Fine-tuning sidecar failed.".to_string());
        return Err(detail);
    }
    let metrics = parse_metrics(&stdout_lines)?;
    let checkpoint_size = std::fs::metadata(&partial_path)
        .map_err(|error| format!("Training did not produce a checkpoint: {error}"))?
        .len();
    if checkpoint_size < 1024 {
        return Err("Training produced an invalid empty checkpoint.".to_string());
    }
    std::fs::rename(&partial_path, &final_path)
        .map_err(|error| format!("Could not finalize the trained checkpoint: {error}"))?;

    let created_at = repo::now_iso8601();
    let models_dir = std::fs::canonicalize(store.models_dir())
        .map_err(|error| format!("Could not resolve the model store: {error}"))?;
    let canonical_checkpoint = std::fs::canonicalize(&final_path)
        .map_err(|error| format!("Could not resolve the finalized checkpoint: {error}"))?;
    if !canonical_checkpoint.is_file() || !canonical_checkpoint.starts_with(&models_dir) {
        return Err("Refusing to record a checkpoint outside CellCounter's model store.".to_string());
    }
    let checkpoint_path = canonical_checkpoint.to_string_lossy().into_owned();
    let metrics_json = serde_json::to_string(&metrics).map_err(|error| error.to_string())?;
    let conn = db.connection()?;
    conn.execute(
        "INSERT INTO model_versions
         (id, model_id, version, created_at, trained_on_images,
          trained_on_corrections, checkpoint_path, metrics_json)
         VALUES (?1, 'cp-cyto3', ?2, ?3, ?4, ?5, ?6, ?7)",
        rusqlite::params![
            id,
            version,
            created_at,
            image_count as i64,
            correction_count,
            checkpoint_path,
            metrics_json,
        ],
    )
    .map_err(|error| error.to_string())?;
    cleanup.committed = true;
    Ok(ModelVersionDto {
        id,
        model_id: "cp-cyto3".to_string(),
        version,
        created_at,
        trained_on_images: image_count as i64,
        trained_on_corrections: correction_count,
        checkpoint_path,
        metrics,
    })
}

#[tauri::command]
pub fn cancel_fine_tune(
    manager: State<'_, TrainingManager>,
    run_id: String,
) -> Result<(), String> {
    let active = manager.active.lock().map_err(|_| "training manager is unavailable")?.take();
    if let Some(active) = active {
        if active.run_id == run_id {
            let _ = active.cancel.send(());
        } else {
            let mut slot = manager.active.lock().map_err(|_| "training manager is unavailable")?;
            *slot = Some(active);
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parser_requires_real_metrics() {
        let metrics = parse_metrics(&["DONE ap50=0.8 f1=0.7".to_string()]).expect("metrics");
        assert_eq!(metrics.get("ap50"), Some(&0.8));
        assert!(parse_metrics(&["EPOCH 1 train=1 val=1".to_string()]).is_err());
    }

    #[test]
    fn dataset_pair_scan_ignores_unpaired_and_symlink_like_entries() {
        let root = std::env::temp_dir().join(format!("cellcounter-train-test-{}", Uuid::new_v4()));
        std::fs::create_dir_all(&root).expect("dir");
        std::fs::write(root.join("a.png"), b"image").expect("image");
        std::fs::write(root.join("a_masks.png"), b"mask").expect("mask");
        std::fs::write(root.join("unpaired.tif"), b"image").expect("unpaired");
        assert_eq!(image_mask_pairs(&root).expect("scan"), 1);
        std::fs::remove_dir_all(root).expect("cleanup");
    }

    #[test]
    fn trainer_source_cannot_fabricate_success_or_empty_checkpoints() {
        let source = include_str!("../../../python/cellpose_train.py");
        for forbidden in [
            "empty dataset → faux progress",
            "train_loss = max(",
            "ap50=0.900",
            "write_bytes(b\"\")",
            "train=0.20 val=0.25",
            "ap50 = precision * recall",
        ] {
            assert!(!source.contains(forbidden), "forbidden trainer fallback: {forbidden}");
        }
        assert!(source.contains("no-image-mask-pairs"));
        assert!(source.contains("final checkpoint is missing or empty"));
    }
}
