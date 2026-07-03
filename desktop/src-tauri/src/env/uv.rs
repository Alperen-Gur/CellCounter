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

/// Interpreter pin for the sidecar env. `pyproject.toml` allows
/// `>=3.9,<3.13`; we pin a single version so the environment is reproducible
/// regardless of whatever Python happens to be on PATH, and so uv downloads a
/// managed interpreter when none matches (rather than silently using a stray
/// one). 3.11 is inside the supported range and has good wheel coverage for the
/// pinned deps (cellpose 3.x / numpy<2 / CPU torch).
const PINNED_PYTHON: &str = "3.11";

/// Cheap "is the staged copy already current?" check: identical length and
/// byte-for-byte contents. Reading both files is fine here — the sidecar scripts
/// are small — and avoids re-copying (and thus locking/clobbering) a file the
/// destination already holds verbatim.
fn files_match(src: &std::path::Path, dest: &std::path::Path) -> bool {
    let (Ok(a), Ok(b)) = (std::fs::metadata(src), std::fs::metadata(dest)) else {
        return false;
    };
    if a.len() != b.len() {
        return false;
    }
    match (std::fs::read(src), std::fs::read(dest)) {
        (Ok(sa), Ok(sb)) => sa == sb,
        _ => false,
    }
}

/// Windows MAX_PATH guard for the venv. Returns `Some(message)` when the venv
/// base directory is long enough that installing deep dependency trees (e.g.
/// torch under `.venv\Lib\site-packages\…`) is likely to exceed the legacy
/// 260-char `MAX_PATH` limit, and long-path support isn't a given. On non-Windows
/// targets this is always `None` (no such limit).
///
/// `RESERVE` is a conservative budget for the tail we don't control:
/// `\Lib\site-packages\` (~19) plus a nested package file path (torch ships files
/// well over 150 chars deep), so we flag once the venv base alone leaves too
/// little headroom under 260.
fn long_path_warning(venv_dir: &std::path::Path) -> Option<String> {
    if !cfg!(windows) {
        return None;
    }
    const MAX_PATH: usize = 260;
    const RESERVE: usize = 200; // "\Lib\site-packages\" + deepest known dep file
    let base_len = venv_dir.as_os_str().len();
    if base_len + RESERVE > MAX_PATH {
        Some(format!(
            "The install directory is too deep for Windows' 260-character path \
             limit:\n  {}\nInstalling large dependencies (e.g. torch) would fail \
             with a path-too-long error. Enable long paths (set the registry key \
             HKLM\\SYSTEM\\CurrentControlSet\\Control\\FileSystem\\LongPathsEnabled \
             to 1, then reboot), or move the app data to a shorter location.",
            venv_dir.display()
        ))
    } else {
        None
    }
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
    // Skip files whose contents already match the staged copy so a still-running
    // orphan sidecar / antivirus lock on Windows can't fail the copy of a file
    // that is already current.
    //
    // A file that DIFFERS from the staged copy (the source was updated) must be
    // refreshed; if that copy fails we abort. Reporting success while leaving a
    // stale `pyproject.toml`/sidecar on disk would let `env_install` "succeed"
    // against an out-of-date environment — the existence-only gate in
    // `env_install` can't catch it, so a failed refresh is fatal here.
    for entry in std::fs::read_dir(&src).map_err(|e| e.to_string())? {
        let entry = entry.map_err(|e| e.to_string())?;
        let path = entry.path();
        if path.is_file() {
            if let Some(name) = path.file_name() {
                let target = dest.join(name);
                if files_match(&path, &target) {
                    continue; // already staged and identical — don't touch it
                }
                if let Err(e) = std::fs::copy(&path, &target) {
                    return Err(format!(
                        "could not update staged file {}: {e}. Close any running \
                         detection and retry (a lock on the file blocks the update).",
                        target.display()
                    ));
                }
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

    // Windows MAX_PATH preflight: the venv site-packages tree
    // (`…\.venv\Lib\site-packages\`) plus a deeply-nested dependency file (torch
    // buries files well past 100 chars) can blow past the legacy 260-char limit,
    // which fails `uv sync` with an opaque copy/extract error. Detect the risk up
    // front and surface an actionable message (enable long paths) instead.
    if let Some(msg) = long_path_warning(&store.venv_dir()) {
        return Err(msg);
    }

    // Pin the interpreter so the env is reproducible regardless of the ambient
    // Python on PATH. Writing a `.python-version` next to the pyproject makes the
    // pin visible to any later `uv` invocation in this dir; `--python` below
    // enforces it for this sync (and lets uv fetch a managed 3.11 when none is
    // installed). A best-effort write is fine — `--python` is authoritative.
    let _ = std::fs::write(project_dir.join(".python-version"), PINNED_PYTHON);

    // `uv sync` creates `.venv` in the project dir and installs the locked deps.
    // `--project <dir>` pins the project; we also set cwd for good measure.
    let mut cmd = Command::new(uv_executable());
    cmd.arg("sync")
        // Install exactly the committed uv.lock (staged alongside pyproject) so
        // every machine resolves identical versions; fail loudly on a stale lock.
        .arg("--frozen")
        .arg("--project")
        .arg(&project_dir)
        // Pin the interpreter explicitly (matches the staged `.python-version`);
        // uv downloads a managed build if no matching interpreter is on PATH.
        .arg("--python")
        .arg(PINNED_PYTHON)
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

// ===========================================================================
// COMMAND: env_uv_available
// ===========================================================================

/// Preflight for the `uv` toolchain: is it installed and on PATH (or pointed to
/// by the `UV` env var)? Runs `uv --version`. Surfaced in onboarding / the
/// Models page BEFORE enabling Install, so a missing toolchain is caught up
/// front with actionable guidance rather than as a mid-install spawn failure.
///
/// Returns [`Availability`] for symmetry with `env_availability`: `installed`
/// true when `uv --version` runs, else a `reason` with the install hint.
#[tauri::command]
pub async fn env_uv_available() -> Result<Availability, String> {
    let mut cmd = Command::new(uv_executable());
    cmd.arg("--version")
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    crate::proc::hide_console_tokio(&mut cmd);

    match cmd.output().await {
        Ok(output) if output.status.success() => Ok(Availability {
            installed: true,
            reason: Some(String::from_utf8_lossy(&output.stdout).trim().to_string()),
        }),
        // Spawned but exited non-zero (unusual for `--version`) — report the tail.
        Ok(output) => {
            let stderr = String::from_utf8_lossy(&output.stderr);
            Ok(Availability {
                installed: false,
                reason: Some(format!(
                    "uv is installed but did not respond as expected. {}",
                    stderr.lines().last().unwrap_or("").trim()
                )),
            })
        }
        // Could not spawn — uv is not installed / not on PATH.
        Err(_) => Ok(Availability {
            installed: false,
            reason: Some(
                "uv was not found. Install it from https://docs.astral.sh/uv/ \
                 (or set the UV environment variable to its path), then retry."
                    .into(),
            ),
        }),
    }
}
