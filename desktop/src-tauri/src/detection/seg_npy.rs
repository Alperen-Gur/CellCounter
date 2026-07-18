//! detection/seg_npy.rs — `_seg.npy` round-trip (feature `seg-npy-io`).
//!
//! Round-trips masks with the Cellpose GUI's `_seg.npy` format so users can move
//! work between CellCounter and Cellpose. Kept lossless per the train-from-GUI
//! seam (ARCHITECTURE.md §3.5 note): a later fine-tuning feature consumes
//! `corrections` + `_seg.npy` masks.
//!
//! Both commands shell out to `desktop/python/_seg_npy_io.py` running from the
//! SAME uv venv the detector uses (`FileStore::venv_python`). We reuse the
//! sidecar's spawn discipline — cwd = python dir (so `_cellpose_common` &
//! siblings import), stdin null, drain stdout, capture stderr — but this is a
//! short-lived, non-cancellable, non-streaming helper (no `SidecarManager`
//! registration, no progress events): a `_seg.npy` decode/encode is fast and
//! atomic, unlike a full Cellpose eval.
//!
//! Wire protocol (documented in `_seg_npy_io.py`):
//!   import →  stdout = SidecarPayload  `{width,height,cells,image_stats}`
//!   export →  stdout = `{"ok":true,"path":"<abs>","n_cells":N}`
//!   error  →  stdout = `{"error":"<code>","hint":"<detail>"}` + nonzero exit
//!
//! Boundary: this file owns process invocation + JSON mapping only. It does not
//! bootstrap the venv (kernel-env) nor persist the result (the Results panel
//! saves the returned detection via the PersistencePort). Re-uses cellpose/numpy
//! from the venv; never re-implements kernel logic.

use std::process::Stdio;

use serde_json::json;
use tauri::AppHandle;
use tokio::io::AsyncReadExt;
use tokio::process::Command;

use crate::db::models::CellDto;
use crate::detection::ipc::{DetectionResultDto, SidecarError, SidecarPayload};
use crate::detection::sidecar::resolve_helper_python;
use crate::paths::FileStore;

/// The staged Python helper this module drives.
const HELPER_SCRIPT: &str = "_seg_npy_io.py";

/// Resolve `(venv_python, helper_script)` or a human error explaining why the
/// round-trip can't run (venv missing / script not staged). The helper only
/// needs numpy + cellpose (not a specific model), so it runs in whichever env
/// EXISTS — base `.venv` preferred, else the cpsam `.venv4` — via
/// [`resolve_helper_python`]. With per-card installs a cpsam-only install (base
/// `.venv` absent) must still round-trip `_seg.npy`, so we no longer hardcode
/// `venv_python()`.
fn resolve_helper(store: &FileStore) -> Result<(std::path::PathBuf, std::path::PathBuf), String> {
    let script = store.python_script(HELPER_SCRIPT);
    if !script.exists() {
        return Err(format!(
            "seg-npy helper {HELPER_SCRIPT} is not staged in the python dir"
        ));
    }
    let python = resolve_helper_python(store)
        .ok_or_else(|| "python venv is not installed (install a model first)".to_string())?;
    Ok((python, script))
}

/// Run the helper with `args` (argv after the interpreter; `argv[0]` = script
/// path), returning captured `(stdout_bytes, stderr_text, exit_code)`.
///
/// cwd = python dir so the helper's `sys.path.insert(0, dirname(__file__))`
/// picks up `_cellpose_common` & friends, exactly like the detector spawn.
async fn run_helper(
    python: &std::path::Path,
    args: &[String],
    python_dir: &std::path::Path,
) -> Result<(Vec<u8>, String, i32), String> {
    let mut cmd = Command::new(python);
    cmd.args(args)
        .current_dir(python_dir)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .kill_on_drop(true);
    crate::proc::hide_console_tokio(&mut cmd);

    let mut child = cmd
        .spawn()
        .map_err(|e| format!("failed to spawn seg-npy helper: {e}"))?;

    // Drain stdout + stderr concurrently to avoid a full-pipe deadlock (an
    // embedded image / label map can push stderr logs past a pipe buffer).
    let stdout = child.stdout.take();
    let stderr = child.stderr.take();
    let stdout_task = tokio::spawn(async move {
        let mut out = Vec::new();
        if let Some(mut s) = stdout {
            let _ = s.read_to_end(&mut out).await;
        }
        out
    });
    let stderr_task = tokio::spawn(async move {
        let mut buf = Vec::new();
        if let Some(mut s) = stderr {
            let _ = s.read_to_end(&mut buf).await;
        }
        String::from_utf8_lossy(&buf).into_owned()
    });

    let status = child
        .wait()
        .await
        .map_err(|e| format!("seg-npy helper wait failed: {e}"))?;
    let stdout_bytes = stdout_task.await.unwrap_or_default();
    let stderr_text = stderr_task.await.unwrap_or_default();
    let exit_code = status.code().unwrap_or(-1);
    Ok((stdout_bytes, stderr_text, exit_code))
}

/// Turn a nonzero-exit / structured-error helper result into a `String` error.
/// Prefers the helper's `{error,hint}` JSON on stdout; falls back to trailing
/// stderr; finally a stdout preview.
fn helper_error(stdout: &[u8], stderr: &str, exit_code: i32) -> String {
    if let Ok(err) = serde_json::from_slice::<SidecarError>(stdout) {
        return match err.hint {
            Some(h) => format!("{}: {}", err.error, h),
            None => err.error,
        };
    }
    let tail = stderr.lines().rev().find(|l| !l.trim().is_empty());
    if let Some(line) = tail {
        return format!("seg-npy helper failed (exit {exit_code}): {}", line.trim());
    }
    let preview: String = String::from_utf8_lossy(stdout).chars().take(300).collect();
    format!("seg-npy helper failed (exit {exit_code}): {preview}")
}

// ===========================================================================
// COMMAND: seg_npy_import
// ===========================================================================

/// Import a Cellpose `_seg.npy` for the image at `image_path`, returning the
/// decoded cells + dimensions as a `DetectionResultDto` (source-px contours).
///
/// `px_per_um` + the size thresholds drive the SAME measurement loop the live
/// detector uses (`_cellpose_common.measure_cells`), so an imported mask is
/// measured identically to model output. The Results panel persists the result
/// via `saveDetection` (this command does not write the DB — the transport /
/// persistence split is deliberate).
#[tauri::command]
pub async fn seg_npy_import(
    app: AppHandle,
    image_path: String,
    npy_path: String,
    px_per_um: f64,
    small_threshold_um: Option<f64>,
    large_threshold_um: Option<f64>,
) -> Result<DetectionResultDto, String> {
    let store = FileStore::from_app(&app)?;
    let (python, script) = resolve_helper(&store)?;

    let small_t = small_threshold_um.unwrap_or(20.0);
    let large_t = large_threshold_um.unwrap_or(30.0);
    // px/µm must be positive for the µm conversion; guard against a 0 slipping in.
    let ppu = if px_per_um > 0.0 { px_per_um } else { 1.0 };

    let args: Vec<String> = vec![
        script.to_string_lossy().into_owned(),
        "import".into(),
        "--image".into(),
        image_path,
        "--npy".into(),
        npy_path,
        "--pxPerUm".into(),
        ppu.to_string(),
        "--small-threshold".into(),
        small_t.to_string(),
        "--large-threshold".into(),
        large_t.to_string(),
    ];

    let (stdout_bytes, stderr_text, exit_code) =
        run_helper(&python, &args, &store.python_dir()).await?;

    if exit_code != 0 {
        return Err(helper_error(&stdout_bytes, &stderr_text, exit_code));
    }
    // A structured error can still arrive on a 0 exit (defensive) — check first.
    if let Ok(err) = serde_json::from_slice::<SidecarError>(&stdout_bytes) {
        return Err(match err.hint {
            Some(h) => format!("{}: {}", err.error, h),
            None => err.error,
        });
    }

    // Reuse the sidecar payload → DTO mapping (snake→camel, contour lift) so
    // imported cells are shaped exactly like a live detection's cells.
    let payload: SidecarPayload = serde_json::from_slice(&stdout_bytes).map_err(|e| {
        let preview: String = String::from_utf8_lossy(&stdout_bytes)
            .chars()
            .take(300)
            .collect();
        format!("unparseable seg-npy import output: {e}; got: {preview}")
    })?;
    Ok(payload.into_result_dto())
}

// ===========================================================================
// COMMAND: seg_npy_export
// ===========================================================================

/// Export `cells` for the image at `image_path` (dimensions `image_width` x
/// `image_height`) to a Cellpose-compatible `_seg.npy` at `out_path`. Returns
/// the absolute path actually written.
///
/// The helper rasterizes each cell's `contour_px` (or a `diameter_px` disc when
/// no contour) into a contiguous 1..N label map and writes `masks` + `outlines`
/// losslessly so the file opens in the Cellpose GUI and can feed the future
/// train seam. `cells` cross the IPC as the frozen camelCase `CellDto`; we
/// re-serialize them into the snake_case geometry JSON the helper reads.
#[tauri::command]
pub async fn seg_npy_export(
    app: AppHandle,
    image_path: String,
    cells: Vec<CellDto>,
    image_width: i64,
    image_height: i64,
    out_path: String,
) -> Result<String, String> {
    let store = FileStore::from_app(&app)?;
    let (python, script) = resolve_helper(&store)?;

    // Build the helper's input JSON: {width,height,cells:[…]} with source-px
    // geometry. The helper reads `contour_px` / `cx` / `cy` / `diameter_px`.
    let cells_json: Vec<serde_json::Value> = cells
        .iter()
        .map(|c| {
            let mut obj = json!({
                "id": c.id,
                "cx": c.cx,
                "cy": c.cy,
                "diameter_px": c.diameter_px,
                "diameter_um": c.diameter_um,
            });
            if let Some(contour) = &c.contour_px {
                obj["contour_px"] = json!(contour);
            }
            obj
        })
        .collect();
    let input = json!({
        "width": image_width,
        "height": image_height,
        "cells": cells_json,
    });

    // Stage the input JSON in Exports/ (guaranteed writable) rather than argv, so
    // a large cell list never hits command-line length limits.
    let tmp_in = store
        .exports_dir()
        .join(format!("._segnpy_in_{}.json", unique_token()));
    let input_str = serde_json::to_string(&input).map_err(|e| e.to_string())?;
    // `std::fs` (blocking) matches the rest of the backend — the crate does not
    // enable tokio's `fs` feature — and this is a tiny, one-shot write.
    std::fs::write(&tmp_in, input_str)
        .map_err(|e| format!("could not stage seg-npy input JSON: {e}"))?;

    let mut args: Vec<String> = vec![
        script.to_string_lossy().into_owned(),
        "export".into(),
        "--cells".into(),
        tmp_in.to_string_lossy().into_owned(),
        "--out".into(),
        out_path,
    ];
    if !image_path.is_empty() {
        args.push("--image".into());
        args.push(image_path);
    }

    let run = run_helper(&python, &args, &store.python_dir()).await;
    // Best-effort cleanup of the staged input regardless of outcome.
    let _ = std::fs::remove_file(&tmp_in);
    let (stdout_bytes, stderr_text, exit_code) = run?;

    if exit_code != 0 {
        return Err(helper_error(&stdout_bytes, &stderr_text, exit_code));
    }

    // Parse `{ok, path, n_cells}`; surface `{error,hint}` if it slipped through.
    let value: serde_json::Value = serde_json::from_slice(&stdout_bytes).map_err(|e| {
        let preview: String = String::from_utf8_lossy(&stdout_bytes)
            .chars()
            .take(300)
            .collect();
        format!("unparseable seg-npy export output: {e}; got: {preview}")
    })?;
    if value.get("ok").and_then(|v| v.as_bool()) == Some(true) {
        let path = value
            .get("path")
            .and_then(|v| v.as_str())
            .unwrap_or_default()
            .to_string();
        Ok(path)
    } else {
        let err = value
            .get("error")
            .and_then(|v| v.as_str())
            .unwrap_or("seg-npy export failed");
        let hint = value.get("hint").and_then(|v| v.as_str()).unwrap_or("");
        Err(if hint.is_empty() {
            err.to_string()
        } else {
            format!("{err}: {hint}")
        })
    }
}

/// Tiny unique-ish token for the temp input filename (pid + wall-clock nanos).
/// Enough to disambiguate concurrent exports without widening this module's
/// dependency surface.
fn unique_token() -> String {
    use std::time::{SystemTime, UNIX_EPOCH};
    let nanos = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_nanos())
        .unwrap_or(0);
    format!("{}_{}", std::process::id(), nanos)
}
