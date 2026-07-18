//! env/uv.rs — uv-based Python environment bootstrap (ARCHITECTURE.md §3, kernel-env).
//!
//! Replaces the Swift `install_python.sh` + `CellposeInstaller` with `uv`. Two
//! commands, registered in `lib.rs`:
//!   * `env_install`      — stage sidecar scripts, then provision the env for the
//!                          requested model, streaming uv's stdout+stderr as
//!                          `env://install/log` Tauri events (live tail). For the
//!                          cyto3 family this is `uv sync` of the pyproject under
//!                          `<root>/py`; for Cellpose-SAM (`cpsam`) it is instead
//!                          an ISOLATED `uv venv` + `uv pip install` into a second
//!                          `.venv4` (see [`install_cellpose4_env`]) so the base
//!                          `cellpose>=3,<4` env is never disturbed — mirroring the
//!                          native app's separate `venv4`.
//!   * `env_availability` — is the (model-appropriate) venv present + `import
//!                          cellpose` importable? For `cpsam` the probe additionally
//!                          asserts cellpose major >= 4 against `.venv4`.
//!
//! The uv project lives at `<app-data>/py/` (a copy of `desktop/python/`,
//! including `pyproject.toml` and the sidecar scripts) — a short sibling of the
//! `CellCounter/` data root, kept short so the venv's deep dependency tree stays
//! under Windows' 260-char `MAX_PATH`. `uv sync` creates `<app-data>/py/.venv`
//! and installs the pinned deps (cellpose>=3,<4, numpy<2, pillow, scikit-image,
//! CPU torch/torchvision).
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
use crate::detection::sidecar::{is_cellpose_sam, CELLPOSE4_IMPORT_PROBE};
use crate::paths::FileStore;

/// Tauri event name the install log lines are emitted on.
pub const INSTALL_LOG_EVENT: &str = "env://install/log";

/// One line of install output, streamed to the UI as an event payload.
#[derive(Debug, Clone, serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub struct InstallLogLine {
    /// "stdout" | "stderr".
    pub stream: String,
    pub line: String,
    /// App-facing id of the model whose install produced this line. Serialized
    /// as `modelId` (via the struct's `rename_all = "camelCase"`) — a FROZEN
    /// contract the frontend filters on. The one global `env://install/log`
    /// stream carries every card's lines, so concurrent cyto3 + cpsam installs
    /// interleave; stamping each line lets each card show only its own.
    pub model_id: String,
}

/// Resolve the `uv` executable: an explicit `UV` env var wins (set by CI /
/// packaging), then the uv bundled beside the app binary (externalBin sidecar),
/// then `uv` on PATH.
fn uv_executable() -> String {
    if let Ok(uv) = std::env::var("UV") {
        return uv;
    }
    // Tauri drops the externalBin next to the main binary: `uv.exe` beside the
    // `.exe` on Windows, `Contents/MacOS/uv` on macOS. Prefer it so a fresh
    // install needs no `uv` on PATH.
    if let Ok(exe) = std::env::current_exe() {
        if let Some(dir) = exe.parent() {
            let bundled = dir.join(if cfg!(windows) { "uv.exe" } else { "uv" });
            if bundled.exists() {
                return bundled.to_string_lossy().into_owned();
            }
        }
    }
    "uv".to_string()
}

/// Interpreter pin for the sidecar env. `pyproject.toml` allows
/// `>=3.9,<3.13`; we pin a single version so the environment is reproducible
/// regardless of whatever Python happens to be on PATH, and so uv downloads a
/// managed interpreter when none matches (rather than silently using a stray
/// one). 3.11 is inside the supported range and has good wheel coverage for the
/// pinned deps (cellpose 3.x / numpy<2 / CPU torch).
const PINNED_PYTHON: &str = "3.11";

/// App-facing base (cyto3) model id. Used only as the `modelId` stamp for a
/// legacy no-arg `env_install()` call (which installs the base env); the frontend
/// always passes an explicit `modelId`, so this is the backward-compat default.
const BASE_MODEL_ID: &str = "cp-cyto3";

/// The Cellpose-SAM (`cellpose>=4`) pip package set installed into `.venv4`.
/// Mirrors the native `CellposeSAMDownloader.install(...)` set EXACTLY:
/// `cellpose>=4` pulls the SAM architecture, `numpy<2` keeps the stack numpy-1
/// clean, `scipy` + `scikit-image` cover the QC/segmentation helpers, and
/// `torch` resolves to the CPU wheel from PyPI's default index (on the Windows +
/// macOS release targets PyPI serves the CPU torch build, so no special mirror is
/// needed — see [`install_cellpose4_env`]). `roifile` is NOT listed even though
/// the ROI-export helper needs it in a cpsam-only install: `cellpose` declares
/// `roifile` as a direct dependency, so `uv pip install cellpose>=4` pulls it in
/// transitively. Deliberately built with `uv pip install` (no pyproject / no
/// lockfile) so it stays fully isolated from the base env's `pyproject.toml` +
/// `uv.lock`.
const CP4_PIP_PACKAGES: &[&str] = &["cellpose>=4", "numpy<2", "scipy", "scikit-image", "torch"];

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

/// Whether Windows long-path support is switched on, i.e.
/// `HKLM\SYSTEM\CurrentControlSet\Control\FileSystem\LongPathsEnabled` = 1.
///
/// When it is, the legacy 260-char `MAX_PATH` ceiling no longer applies and the
/// budget in [`long_path_warning`] is moot. Reading it back matters: enabling
/// this key is the exact workaround our own error message tells the user to
/// apply, and before this we ignored it — so following the advice changed
/// nothing and the install stayed blocked. Any failure to read is treated as
/// "not enabled", which keeps the conservative guard.
#[cfg(windows)]
fn long_paths_enabled() -> bool {
    let mut cmd = std::process::Command::new("reg");
    cmd.args([
        "query",
        r"HKLM\SYSTEM\CurrentControlSet\Control\FileSystem",
        "/v",
        "LongPathsEnabled",
    ]);
    crate::proc::hide_console_std(&mut cmd);
    match cmd.output() {
        // Output looks like: "    LongPathsEnabled    REG_DWORD    0x1"
        Ok(out) if out.status.success() => String::from_utf8_lossy(&out.stdout)
            .lines()
            .find(|l| l.contains("LongPathsEnabled"))
            .and_then(|l| l.split_whitespace().last())
            .is_some_and(|v| v != "0x0"),
        _ => false,
    }
}

#[cfg(not(windows))]
fn long_paths_enabled() -> bool {
    true
}

/// Windows `MAX_PATH` guard for the venv. Returns `Some(message)` when the venv
/// base directory is long enough that installing deep dependency trees (e.g.
/// torch under `.venv\Lib\site-packages\…`) is likely to exceed the legacy
/// 260-char `MAX_PATH` limit and long-path support isn't switched on. On
/// non-Windows targets this is always `None` (no such limit).
///
/// `RESERVE` budgets the tail we don't control below the venv base:
/// `\Lib\site-packages\` (~19) plus the deepest bundled dependency file — torch's
/// deepest header lands ~160 chars under the venv base. We warn once the base
/// leaves less than that headroom under 260. With the venv base now at the short
/// `<app-data>\py\.venv` (~66 chars for a typical user), a normal install clears
/// this comfortably; the guard only trips for pathological bases (e.g. an
/// unusually long or redirected profile path), staying a genuine safety net
/// rather than the blanket rejection the old 200-char reserve caused.
fn long_path_warning(venv_dir: &std::path::Path) -> Option<String> {
    if !cfg!(windows) {
        return None;
    }
    // Honour the workaround this function's own message recommends: with long
    // paths enabled the 260-char ceiling is lifted, so don't refuse the install.
    if long_paths_enabled() {
        return None;
    }
    const MAX_PATH: usize = 260;
    // `\Lib\site-packages\` (~19) + torch's deepest bundled file (~140) ≈ 160.
    // NOT the old 200: that flagged any base over 60 chars — even the default
    // ~66-char venv base — forcing the very registry edit this fix removes.
    const RESERVE: usize = 160;
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

/// Stage the python project, then provision the env for `model_id`, streaming
/// output as events. Resolves to `()` on a clean exit; rejects with the failing
/// uv command's exit code + tail. The UI subscribes to [`INSTALL_LOG_EVENT`] for
/// the live log.
///
/// Routing (frozen contract item 4): when `model_id` resolves to Cellpose-SAM
/// (`cpsam`) we build the ISOLATED `.venv4` via [`install_cellpose4_env`]; any
/// other id — including `None` (the backward-compatible no-arg call) — runs the
/// unchanged base `uv sync` in [`install_base_env`]. The JS side invokes this as
/// `invoke("env_install", { modelId })`.
#[tauri::command]
pub async fn env_install(app: AppHandle, model_id: Option<String>) -> Result<(), String> {
    let store = FileStore::from_app(&app)?;
    // Stage the python project for BOTH paths: the cpsam sidecar
    // (`cellpose4_detect.py`) is staged here alongside the cyto3 scripts and
    // still runs out of `<root>/py`, and the base path needs the pyproject +
    // uv.lock present before `uv sync`.
    stage_python_project(&app, &store)?;

    // The app-facing model id every install-log line is stamped with (FIX 5,
    // frozen `modelId` contract). A `None` (legacy no-arg) call installs the base
    // env, so fall back to the base model id — those lines then still route to
    // the cyto3 card's filtered log.
    let model_id = model_id.unwrap_or_else(|| BASE_MODEL_ID.to_string());

    if is_cellpose_sam(&model_id) {
        install_cellpose4_env(&app, &store, &model_id).await
    } else {
        install_base_env(&app, &store, &model_id).await
    }
}

/// Base (cyto3, `cellpose>=3,<4`) install: `uv sync --frozen` the staged
/// pyproject under `<root>/py`, creating `.venv`. Unchanged from the original
/// single-env behaviour; the base `pyproject.toml` / `uv.lock` are authoritative.
async fn install_base_env(
    app: &AppHandle,
    store: &FileStore,
    model_id: &str,
) -> Result<(), String> {
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

    run_streamed_command(app, cmd, "uv sync", model_id).await
}

/// Cellpose-SAM (`cellpose>=4`) install into the ISOLATED `.venv4`. Mirrors the
/// native `CellposeSAMDownloader`: create a second venv next to `.venv`, then
/// `uv pip install` the cp4 package set into it — NO lockfile and NO `--frozen`,
/// so the base env's `pyproject.toml` / `uv.lock` are never touched. A FINAL step
/// prefetches the ~1.15 GB CPSAM transformer weights (FIX 2): cellpose 4 would
/// otherwise download them lazily on the first `CellposeModel` construction —
/// which, in serve mode, happens before the worker's `ready` handshake and would
/// overrun the host's `READY_TIMEOUT` (and a batch of workers would each
/// re-download). Fetching them at install time caches them so the first detection
/// is fast. Every step streams through [`INSTALL_LOG_EVENT`] exactly like the
/// base sync.
async fn install_cellpose4_env(
    app: &AppHandle,
    store: &FileStore,
    model_id: &str,
) -> Result<(), String> {
    let venv4_dir = store.venv4_dir();

    // Same Windows MAX_PATH preflight as the base path — `.venv4` buries torch
    // just as deeply as `.venv`, so guard against the 260-char ceiling here too.
    if let Some(msg) = long_path_warning(&venv4_dir) {
        return Err(msg);
    }

    // 1) Create the isolated venv with the pinned interpreter. `uv venv` fetches
    //    a managed 3.11 when none is on PATH (same as `uv sync --python` above)
    //    and is idempotent — re-running rebuilds a clean `.venv4`.
    let mut venv_cmd = Command::new(uv_executable());
    venv_cmd
        .arg("venv")
        .arg(&venv4_dir)
        .arg("--python")
        .arg(PINNED_PYTHON)
        .current_dir(store.python_dir())
        .env_remove("VIRTUAL_ENV")
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .kill_on_drop(true);
    crate::proc::hide_console_tokio(&mut venv_cmd);
    run_streamed_command(app, venv_cmd, "uv venv", model_id).await?;

    // 2) Install the cp4 package set INTO `.venv4` (targeted via `--python`) from
    //    PLAIN PyPI — no `--extra-index-url` (FIX 4). Under uv's default index
    //    strategy an extra PyTorch-mirror index would ALSO serve `numpy` and pull
    //    it from the mirror instead of PyPI (a reproducibility/trust regression);
    //    the native `CellposeSAMDownloader` likewise installs with plain pip. On
    //    the Windows + macOS release targets PyPI's default torch wheel is the CPU
    //    build, so this still yields CPU torch. No lockfile / no `--frozen` — this
    //    env is resolved fresh each install.
    let venv4_python = store.venv4_python();
    let mut pip_cmd = Command::new(uv_executable());
    pip_cmd
        .arg("pip")
        .arg("install")
        // Target the just-created venv4 interpreter explicitly.
        .arg("--python")
        .arg(&venv4_python)
        .args(CP4_PIP_PACKAGES)
        .current_dir(store.python_dir())
        .env_remove("VIRTUAL_ENV")
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .kill_on_drop(true);
    crate::proc::hide_console_tokio(&mut pip_cmd);
    run_streamed_command(app, pip_cmd, "uv pip install", model_id).await?;

    // 3) Prefetch the ~1.15 GB Cellpose-SAM transformer weights NOW, while the
    //    install log is live (FIX 2). cellpose 4 lazily downloads them on the
    //    FIRST `CellposeModel(pretrained_model="cpsam")` construction; in serve
    //    mode that first construction happens BEFORE the worker prints `ready`, so
    //    a cold download would overrun the host's `READY_TIMEOUT` — and a batch
    //    that spawns several workers would have each re-download. Constructing the
    //    model once here caches the weights (under `~/.cellpose/models`), so every
    //    later detection finds a warm cache and the constructor is fast. Streamed
    //    through the SAME mechanism as the uv steps so the multi-hundred-MB
    //    download shows progress; a non-zero exit FAILS the install with the
    //    captured tail (a clear install-time error beats a silent first-run stall).
    let mut prefetch_cmd = Command::new(&venv4_python);
    prefetch_cmd
        .arg("-c")
        .arg("from cellpose import models; models.CellposeModel(gpu=False, pretrained_model='cpsam')")
        .current_dir(store.python_dir())
        .env_remove("VIRTUAL_ENV")
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .kill_on_drop(true);
    crate::proc::hide_console_tokio(&mut prefetch_cmd);
    run_streamed_command(app, prefetch_cmd, "cellpose-sam weight prefetch", model_id).await
}

/// Spawn a fully-configured `Command`, stream its stdout+stderr as
/// [`INSTALL_LOG_EVENT`] lines (the Models page live tail, each stamped with
/// `model_id` so concurrent installs stay isolated — FIX 5), and map the exit
/// status: `Ok(())` on success, else an error carrying the exit code + the stderr
/// (fallback stdout) tail. `label` names the step in the error (`uv sync` /
/// `uv venv` / `uv pip install` / `cellpose-sam weight prefetch`) so they all
/// behave identically — the streamer is intentionally command-agnostic, driving
/// both the uv steps and the venv4-python weight prefetch.
async fn run_streamed_command(
    app: &AppHandle,
    mut cmd: Command,
    label: &str,
    model_id: &str,
) -> Result<(), String> {
    let mut child = cmd
        .spawn()
        .map_err(|e| format!("failed to spawn {label}: {e}"))?;

    // Stream stdout + stderr concurrently, line by line.
    let stdout = child.stdout.take();
    let stderr = child.stderr.take();

    let out_task = spawn_line_pump(app.clone(), stdout, "stdout", model_id.to_string());
    let err_task = spawn_line_pump(app.clone(), stderr, "stderr", model_id.to_string());

    let status = child
        .wait()
        .await
        .map_err(|e| format!("{label} wait failed: {e}"))?;
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
        Err(format!("{label} failed (exit {code}): {}", tail.trim()))
    }
}

/// Spawn a task that reads a child pipe, emits each non-empty trimmed line as an
/// [`INSTALL_LOG_EVENT`], and returns the last ~40 lines joined (for error tail).
fn spawn_line_pump<R>(
    app: AppHandle,
    reader: Option<R>,
    stream: &'static str,
    model_id: String,
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
                            emit_line(&app, stream, &model_id, &buf, &mut tail);
                            buf.clear();
                        } else {
                            buf.push(b);
                        }
                    }
                    Err(_) => break,
                }
            }
            if !buf.is_empty() {
                emit_line(&app, stream, &model_id, &buf, &mut tail);
            }
        }
        tail.into_iter().collect::<Vec<_>>().join("\n")
    })
}

fn emit_line(
    app: &AppHandle,
    stream: &str,
    model_id: &str,
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
            model_id: model_id.to_string(),
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

/// Is the Python environment for `model_id` usable? The model-appropriate venv
/// is present + `import cellpose` works. Same probe shape as
/// `detection_availability` but exposed under the `env` command surface for the
/// Models page. `model_id` follows the frozen contract: `cpsam` probes the
/// isolated `.venv4` and asserts cellpose major >= 4; any other id — including
/// `None` (the backward-compatible no-arg call) — probes the base `.venv`. The
/// JS side invokes this as `invoke("env_availability", { modelId })`.
#[tauri::command]
pub async fn env_availability(
    app: AppHandle,
    model_id: Option<String>,
) -> Result<Availability, String> {
    let store = FileStore::from_app(&app)?;
    let cpsam = is_cellpose_sam(model_id.as_deref().unwrap_or(""));

    // Route to the model-appropriate venv + import probe. cpsam checks `.venv4`
    // with the version-asserting probe; everything else checks the base `.venv`
    // with a plain `import cellpose`.
    let (python, probe) = if cpsam {
        (store.venv4_python(), CELLPOSE4_IMPORT_PROBE)
    } else {
        (store.venv_python(), "import cellpose")
    };

    if !python.exists() {
        return Ok(Availability {
            installed: false,
            reason: Some(if cpsam {
                "Cellpose-SAM environment (venv4) is not installed.".into()
            } else {
                "Python environment is not installed.".into()
            }),
        });
    }
    let mut cmd = Command::new(&python);
    cmd.args(["-c", probe])
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
        let tail = stderr.lines().last().unwrap_or("").trim();
        Ok(Availability {
            installed: false,
            reason: Some(if cpsam {
                format!("Cellpose-SAM (cellpose >= 4) is not importable from venv4. {tail}")
            } else {
                format!("Cellpose is not importable. {tail}")
            }),
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
