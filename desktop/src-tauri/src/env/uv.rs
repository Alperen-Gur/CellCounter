//! env/uv.rs — uv-based Python environment bootstrap (ARCHITECTURE.md §3, kernel-env).
//!
//! Replaces the Swift `install_python.sh` + `CellposeInstaller` with `uv`. Two
//! commands, registered in `lib.rs`:
//!   * `env_install`      — stage sidecar scripts, then `uv sync` the pyproject
//!                          under `<root>/python`, streaming uv's stdout+stderr
//!                          as `env://install/log` Tauri events (live tail).
//!   * `env_availability` — is the venv present + `import cellpose` importable?
//!
//! The uv project lives at `<app-data>/CellCounter/python/` (a copy of
//! `desktop/python/`, including `pyproject.toml` and the sidecar scripts). `uv
//! sync` creates `<root>/python/.venv` and installs the pinned deps
//! (cellpose>=3,<4, numpy<2, pillow, scikit-image, CPU torch/torchvision).
//!
//! Portability decision (honored): the pyproject pins **CPU** torch/torchvision
//! wheels so the environment is reproducible across machines without a GPU
//! toolchain. CUDA is a future TODO — switch the `[tool.uv.sources]` torch
//! index and add a `--extra gpu` sync; no change is needed in this file.
//!
//! Progress events: uv prints resolution/download/build lines to stderr; we
//! stream every non-empty line so the Models page can render a live log exactly
//! like the Swift installer's `output` tail.

use std::process::Stdio;

use tauri::{AppHandle, Emitter};
use tokio::io::{AsyncReadExt, BufReader};
use tokio::process::Command;

use crate::detection::ipc::Availability;
use crate::paths::FileStore;

/// Tauri event name the install log lines are emitted on.
pub const INSTALL_LOG_EVENT: &str = "env://install/log";

/// One line of uv output, streamed to the UI as an event payload.
#[derive(Debug, Clone, serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub struct InstallLogLine {
    /// "stdout" | "stderr".
    pub stream: String,
    pub line: String,
}

/// Resolve the `uv` executable. Prefer an explicit `UV` env var (set by CI /
/// packaging), then fall back to `uv` on PATH.
fn uv_executable() -> String {
    std::env::var("UV").unwrap_or_else(|_| "uv".to_string())
}

/// Stage `desktop/python/` into the writable `<root>/python/` dir. In a packaged
/// build the sidecar scripts + `pyproject.toml` ship as resources; here we copy
/// them so `uv sync` and the sidecar run out of one writable location.
///
/// The source dir is resolved from the Tauri resource dir when packaged, else
/// from the dev-repo `desktop/python`. Missing sources are skipped (the caller
/// surfaces "scripts not staged" via availability).
fn stage_python_project(app: &AppHandle, store: &FileStore) -> Result<(), String> {
    use tauri::Manager;
    let dest = store.python_dir();
    std::fs::create_dir_all(&dest).map_err(|e| e.to_string())?;

    // Candidate source dirs, in priority order.
    let mut candidates: Vec<std::path::PathBuf> = Vec::new();
    if let Ok(resource_dir) = app.path().resource_dir() {
        candidates.push(resource_dir.join("python"));
        candidates.push(resource_dir.join("_up_").join("python")); // tauri resource flattening
    }
    // Dev fallback: <cwd>/../python or the repo desktop/python.
    if let Ok(cwd) = std::env::current_dir() {
        candidates.push(cwd.join("python"));
        candidates.push(cwd.join("..").join("python"));
    }

    let src = candidates.into_iter().find(|p| p.join("pyproject.toml").exists());
    let Some(src) = src else {
        // Nothing to stage from — leave dest as-is (may already be staged).
        return Ok(());
    };

    // Copy all files (flat dir — the sidecar scripts + pyproject live at top level).
    for entry in std::fs::read_dir(&src).map_err(|e| e.to_string())? {
        let entry = entry.map_err(|e| e.to_string())?;
        let path = entry.path();
        if path.is_file() {
            if let Some(name) = path.file_name() {
                let target = dest.join(name);
                std::fs::copy(&path, &target).map_err(|e| e.to_string())?;
            }
        }
    }
    Ok(())
}

// ===========================================================================
// COMMAND: env_install
// ===========================================================================

/// Stage the python project, then `uv sync` it, streaming output as events.
/// Resolves to `()` on a clean exit; rejects with the uv exit code + tail on
/// failure. The UI subscribes to [`INSTALL_LOG_EVENT`] for the live log.
#[tauri::command]
pub async fn env_install(app: AppHandle) -> Result<(), String> {
    let store = FileStore::from_app(&app)?;
    stage_python_project(&app, &store)?;

    let project_dir = store.python_dir();
    if !project_dir.join("pyproject.toml").exists() {
        return Err(format!(
            "pyproject.toml not found under {}. Sidecar scripts were not staged.",
            project_dir.display()
        ));
    }

    // `uv sync` creates `.venv` in the project dir and installs the locked deps.
    // `--project <dir>` pins the project; we also set cwd for good measure.
    let mut cmd = Command::new(uv_executable());
    cmd.arg("sync")
        .arg("--project")
        .arg(&project_dir)
        .current_dir(&project_dir)
        // uv respects VIRTUAL_ENV; make sure a stray one doesn't hijack the sync.
        .env_remove("VIRTUAL_ENV")
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .kill_on_drop(true);
    crate::proc::hide_console_tokio(&mut cmd);

    let mut child = cmd
        .spawn()
        .map_err(|e| format!("failed to spawn uv (is it installed and on PATH?): {e}"))?;

    // Stream stdout + stderr concurrently, line by line.
    let stdout = child.stdout.take();
    let stderr = child.stderr.take();

    let out_task = spawn_line_pump(app.clone(), stdout, "stdout");
    let err_task = spawn_line_pump(app.clone(), stderr, "stderr");

    let status = child
        .wait()
        .await
        .map_err(|e| format!("uv sync wait failed: {e}"))?;
    let out_tail = out_task.await.unwrap_or_default();
    let err_tail = err_task.await.unwrap_or_default();

    if status.success() {
        Ok(())
    } else {
        let code = status.code().unwrap_or(-1);
        // Prefer stderr tail (uv errors go there); fall back to stdout.
        let tail = if !err_tail.trim().is_empty() {
            err_tail
        } else {
            out_tail
        };
        Err(format!("uv sync failed (exit {code}): {}", tail.trim()))
    }
}

/// Spawn a task that reads a child pipe, emits each non-empty trimmed line as an
/// [`INSTALL_LOG_EVENT`], and returns the last ~40 lines joined (for error tail).
fn spawn_line_pump<R>(
    app: AppHandle,
    reader: Option<R>,
    stream: &'static str,
) -> tokio::task::JoinHandle<String>
where
    R: tokio::io::AsyncRead + Unpin + Send + 'static,
{
    tokio::spawn(async move {
        let mut tail: std::collections::VecDeque<String> = std::collections::VecDeque::new();
        if let Some(reader) = reader {
            let mut r = BufReader::new(reader);
            let mut buf: Vec<u8> = Vec::new();
            let mut byte = [0u8; 1];
            loop {
                match r.read(&mut byte).await {
                    Ok(0) => break,
                    Ok(_) => {
                        let b = byte[0];
                        if b == b'\n' || b == b'\r' {
                            emit_line(&app, stream, &buf, &mut tail);
                            buf.clear();
                        } else {
                            buf.push(b);
                        }
                    }
                    Err(_) => break,
                }
            }
            if !buf.is_empty() {
                emit_line(&app, stream, &buf, &mut tail);
            }
        }
        tail.into_iter().collect::<Vec<_>>().join("\n")
    })
}

fn emit_line(
    app: &AppHandle,
    stream: &str,
    raw: &[u8],
    tail: &mut std::collections::VecDeque<String>,
) {
    let text = String::from_utf8_lossy(raw);
    let line = text.trim();
    if line.is_empty() {
        return;
    }
    let _ = app.emit(
        INSTALL_LOG_EVENT,
        InstallLogLine {
            stream: stream.to_string(),
            line: line.to_string(),
        },
    );
    tail.push_back(line.to_string());
    if tail.len() > 40 {
        tail.pop_front();
    }
}

// ===========================================================================
// COMMAND: env_availability
// ===========================================================================

/// Is the Python environment usable? venv present + `import cellpose` works.
/// Same probe shape as `detection_availability` but exposed under the `env`
/// command surface for the Models page.
#[tauri::command]
pub async fn env_availability(app: AppHandle) -> Result<Availability, String> {
    let store = FileStore::from_app(&app)?;
    let python = store.venv_python();
    if !python.exists() {
        return Ok(Availability {
            installed: false,
            reason: Some("Python environment is not installed.".into()),
        });
    }
    let mut cmd = Command::new(&python);
    cmd.args(["-c", "import cellpose"])
        .current_dir(store.python_dir())
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::piped());
    crate::proc::hide_console_tokio(&mut cmd);
    let output = cmd
        .output()
        .await
        .map_err(|e| format!("availability probe failed to spawn: {e}"))?;
    if output.status.success() {
        Ok(Availability {
            installed: true,
            reason: None,
        })
    } else {
        let stderr = String::from_utf8_lossy(&output.stderr);
        Ok(Availability {
            installed: false,
            reason: Some(format!(
                "Cellpose is not importable. {}",
                stderr.lines().last().unwrap_or("").trim()
            )),
        })
    }
}
