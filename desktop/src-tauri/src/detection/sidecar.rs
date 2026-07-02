//! detection/sidecar.rs — SidecarManager: spawn / stream / cancel (§3.1).
//!
//! Rust port of `Detection/CellposeDetectionService.swift` +
//! `Services/ChildProcessTracker.swift`. Owns the Python sidecar process
//! lifecycle and exposes the three detection commands registered in `lib.rs`:
//!   * `run_detection`         — spawn, stream stderr progress, drain stdout JSON
//!   * `cancel_detection`      — SIGTERM → (300 ms) → SIGKILL, by run_id
//!   * `detection_availability`— venv present + `import cellpose` importable?
//!
//! Wire details reproduced verbatim from the Swift host:
//!   * argv order (see `build_argv`), model-id `cp-` prefix strip
//!   * stdout = one JSON object drained concurrently (no full-pipe deadlock)
//!   * stderr = `\n`/`\r`-split, trimmed, non-empty → `{kind:"stage"}` events;
//!     the `using device: <dev>` line → `{kind:"device"}`; tqdm bars dropped
//!   * structured `{error,hint}` stdout → `sidecarFailed`
//!   * exit codes {15,-15,143,9,-9,137} ⇒ `cancelled`
//!   * orphan sweep at launch kills stray `cellpose_detect.py` (PPID re-parented)
//!
//! CUDA: v1 pins CPU torch wheels for portability (see pyproject.toml). GPU
//! selection still flows through `use_gpu`/`--no-gpu`; wiring a real CUDA build
//! is a future TODO — no code change needed here, only the wheel index.

use std::collections::HashMap;
use std::process::Stdio;
use std::sync::Arc;

use tauri::{AppHandle, Emitter, Manager, State};
use tokio::io::{AsyncReadExt, BufReader};
use tokio::process::{Child, Command};
use tokio::sync::Mutex;

use crate::detection::ipc::{
    progress_event_name, Availability, DetectionErrorDto, DetectionParams, DetectionProgress,
    DetectionResultDto, SidecarError, SidecarPayload,
};
use crate::db::repo::Db;
use crate::paths::FileStore;

/// Sidecar scripts we own — used by the orphan sweep to identify stray
/// processes (mirrors `ChildProcessTracker.ownedScriptBasenames`).
const OWNED_SCRIPTS: &[&str] = &[
    "cellpose_detect.py",
    "cellpose_train.py",
    "stardist_detect.py",
    "yolo_detect.py",
    "sam_detect.py",
];

/// Signal-ish exit codes that mean the host terminated us on purpose.
const SIGNAL_EXIT_CODES: &[i32] = &[15, -15, 143, 9, -9, 137];

/// Registry of in-flight runs so `cancel_detection` can find a run's PID.
/// Keyed by client-generated `run_id`.
#[derive(Default)]
pub struct SidecarManager {
    running: Mutex<HashMap<String, RunHandle>>,
}

struct RunHandle {
    /// OS pid of the spawned python process (for signalling on cancel).
    pid: u32,
    /// Set true by `cancel_detection` so the completion path reports `cancelled`
    /// even if the child raced to a non-signal exit.
    cancel_flag: Arc<std::sync::atomic::AtomicBool>,
}

impl SidecarManager {
    pub fn new() -> Self {
        Self::default()
    }
}

/// Resolve the venv python + staged `cellpose_detect.py`, or report why the
/// model isn't runnable. Mirrors `CellposeAvailability.detect()` (simplified:
/// uv gives us a single `.venv`, no sandbox-bundle staging tiers).
fn resolve_sidecar(store: &FileStore) -> Result<(std::path::PathBuf, std::path::PathBuf), String> {
    let python = store.venv_python();
    let script = store.python_script("cellpose_detect.py");
    if !script.exists() {
        return Err("sidecar script cellpose_detect.py is not staged".into());
    }
    if !python.exists() {
        return Err("python venv is not installed".into());
    }
    Ok((python, script))
}

/// Build the EXACT argv from `CellposeDetectionService.swift`.
///
/// `["cellpose_detect.py", "--image", <path>, "--model", <cyto3>,
///   "--pxPerUm", <f>, "--conf", <f>]`
/// then conditionally `--channels c,c` (omitted when 0,0),
/// `--bg-subtract --rolling-ball-radius <n>`,
/// `--watershed --watershed-min-distance <n>`,
/// always `--small-threshold <f> --large-threshold <f>`,
/// and `--no-gpu` when `use_gpu == false`. Model-id `cp-` prefix is stripped.
///
/// (`--restore` is cp-cyto3-r only; not in v1, so never emitted.)
fn build_argv(script: &std::path::Path, image_path: &str, p: &DetectionParams) -> Vec<String> {
    let model = p
        .model_id
        .strip_prefix("cp-")
        .unwrap_or(&p.model_id)
        .to_string();

    let mut args: Vec<String> = vec![
        script.to_string_lossy().into_owned(),
        "--image".into(),
        image_path.to_string(),
        "--model".into(),
        model,
        "--pxPerUm".into(),
        p.px_per_um.to_string(),
        "--conf".into(),
        p.confidence_threshold.to_string(),
    ];

    let is_default_channels = p.channels == [0, 0];
    if !is_default_channels {
        args.push("--channels".into());
        args.push(format!("{},{}", p.channels[0], p.channels[1]));
    }
    if p.background_subtract {
        args.push("--bg-subtract".into());
        args.push("--rolling-ball-radius".into());
        args.push(p.rolling_ball_radius.to_string());
    }
    if p.watershed_split {
        args.push("--watershed".into());
        args.push("--watershed-min-distance".into());
        // Python declares `--watershed-min-distance type=int`; the TS field is a
        // JS `number`, so round to an integer string so `8` and `8.0` both parse
        // (matches the Swift host, which passes an `Int`).
        args.push((p.watershed_min_distance_um.round() as i64).to_string());
    }
    args.push("--small-threshold".into());
    args.push(p.small_threshold_um.to_string());
    args.push("--large-threshold".into());
    args.push(p.large_threshold_um.to_string());
    if !p.use_gpu {
        args.push("--no-gpu".into());
    }
    args
}

/// Parse a stderr line into a progress event. Returns `None` for lines that
/// should be dropped (tqdm bars). The device line
/// `"[cellpose_detect] using device: <dev> (torch …)"` becomes `Device`.
fn parse_progress_line(run_id: &str, line: &str) -> Option<DetectionProgress> {
    // Drop tqdm progress bars (they contain the `%|…|` glyph run).
    if line.contains("%|") {
        return None;
    }
    if let Some(idx) = line.find("using device:") {
        let after = line[idx + "using device:".len()..].trim();
        // Take the token up to the first space or '(' and uppercase it.
        let dev: String = after
            .chars()
            .take_while(|c| !c.is_whitespace() && *c != '(')
            .collect();
        if !dev.is_empty() {
            return Some(DetectionProgress::Device {
                run_id: run_id.to_string(),
                device: dev.to_uppercase(),
            });
        }
    }
    Some(DetectionProgress::Stage {
        run_id: run_id.to_string(),
        line: line.to_string(),
    })
}

// ===========================================================================
// COMMAND: run_detection
// ===========================================================================

#[tauri::command]
pub async fn run_detection(
    app: AppHandle,
    image_path: String,
    params: DetectionParams,
    run_id: String,
) -> Result<DetectionResultDto, DetectionErrorDto> {
    let store = FileStore::from_app(&app).map_err(|_| DetectionErrorDto::ImageDecodeFailed)?;

    let (python, script) = resolve_sidecar(&store).map_err(|_| {
        DetectionErrorDto::ModelNotInstalled {
            model_id: params.model_id.clone(),
        }
    })?;

    // `argv[0]` is the script path; the whole vec becomes the arguments to the
    // python interpreter (`python <script> --image …`), matching the Swift host
    // which sets `process.arguments = args` with `args[0] == scriptURL.path`.
    let argv = build_argv(&script, &image_path, &params);

    // Spawn: cwd = python dir so `sys.path.insert(0, dirname(__file__))` finds
    // the `_cellpose_common` sibling modules.
    let mut cmd = Command::new(&python);
    cmd.args(&argv)
        .current_dir(store.python_dir())
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .kill_on_drop(true);

    let mut child: Child = cmd
        .spawn()
        .map_err(|e| DetectionErrorDto::SidecarFailed {
            exit_code: -1,
            stderr: format!("failed to spawn sidecar: {e}"),
        })?;

    let pid = child.id().unwrap_or(0);
    let cancel_flag = Arc::new(std::sync::atomic::AtomicBool::new(false));

    // Register the run so cancel_detection can find the pid.
    {
        let mgr = app.state::<SidecarManager>();
        let mut running = mgr.running.lock().await;
        running.insert(
            run_id.clone(),
            RunHandle {
                pid,
                cancel_flag: cancel_flag.clone(),
            },
        );
    }

    // --- stderr: stream line-by-line as progress events ---
    let stderr = child.stderr.take();
    let event_name = progress_event_name(&run_id);
    let stderr_task = {
        let app = app.clone();
        let run_id = run_id.clone();
        let event_name = event_name.clone();
        tokio::spawn(async move {
            let mut collected = String::new();
            if let Some(stderr) = stderr {
                let mut reader = BufReader::new(stderr);
                // Split on both \n and \r by reading bytes and buffering.
                let mut buf: Vec<u8> = Vec::new();
                let mut byte = [0u8; 1];
                loop {
                    match reader.read(&mut byte).await {
                        Ok(0) => break, // EOF
                        Ok(_) => {
                            let b = byte[0];
                            if b == b'\n' || b == b'\r' {
                                flush_stderr_line(&app, &event_name, &run_id, &buf, &mut collected);
                                buf.clear();
                            } else {
                                buf.push(b);
                            }
                        }
                        Err(_) => break,
                    }
                }
                // Trailing partial line.
                if !buf.is_empty() {
                    flush_stderr_line(&app, &event_name, &run_id, &buf, &mut collected);
                }
            }
            collected
        })
    };

    // --- stdout: drain concurrently into a buffer (avoids full-pipe deadlock) ---
    let stdout = child.stdout.take();
    let stdout_task = tokio::spawn(async move {
        let mut out = Vec::new();
        if let Some(mut stdout) = stdout {
            let _ = stdout.read_to_end(&mut out).await;
        }
        out
    });

    // Wait for exit + both drains.
    let status = child.wait().await;
    let stdout_bytes = stdout_task.await.unwrap_or_default();
    let stderr_text = stderr_task.await.unwrap_or_default();

    // Deregister the run.
    {
        let mgr = app.state::<SidecarManager>();
        let mut running = mgr.running.lock().await;
        running.remove(&run_id);
    }

    let was_cancelled = cancel_flag.load(std::sync::atomic::Ordering::SeqCst);

    let exit_code: i32 = match status {
        Ok(s) => s.code().unwrap_or_else(|| {
            // No exit code ⇒ killed by signal. On Unix, surface the signal.
            #[cfg(unix)]
            {
                use std::os::unix::process::ExitStatusExt;
                s.signal().map(|sig| -sig).unwrap_or(-1)
            }
            #[cfg(not(unix))]
            {
                -1
            }
        }),
        Err(e) => {
            return Err(DetectionErrorDto::SidecarFailed {
                exit_code: -1,
                stderr: e.to_string(),
            });
        }
    };

    // Signal exit (Cancel button / app quit / SIGKILL) ⇒ cancelled.
    if was_cancelled || SIGNAL_EXIT_CODES.contains(&exit_code) {
        return Err(DetectionErrorDto::Cancelled);
    }

    if exit_code != 0 {
        return Err(DetectionErrorDto::SidecarFailed {
            exit_code,
            stderr: stderr_text,
        });
    }

    // Structured sidecar error on stdout takes precedence over payload parse.
    if let Ok(err_payload) = serde_json::from_slice::<SidecarError>(&stdout_bytes) {
        let combined = match err_payload.hint {
            Some(h) => format!("{}: {}", err_payload.error, h),
            None => err_payload.error,
        };
        return Err(DetectionErrorDto::SidecarFailed {
            exit_code: 0,
            stderr: combined,
        });
    }

    // Decode the full payload.
    match serde_json::from_slice::<SidecarPayload>(&stdout_bytes) {
        Ok(payload) => Ok(payload.into_result_dto()),
        Err(_) => {
            let preview: String = String::from_utf8_lossy(&stdout_bytes)
                .chars()
                .take(400)
                .collect();
            Err(DetectionErrorDto::SidecarFailed {
                exit_code,
                stderr: format!("Unparseable stdout: {preview}"),
            })
        }
    }
}

/// Trim + emit one stderr line as a progress event, and append it to the
/// collected buffer (for error surfacing).
fn flush_stderr_line(
    app: &AppHandle,
    event_name: &str,
    run_id: &str,
    raw: &[u8],
    collected: &mut String,
) {
    let text = String::from_utf8_lossy(raw);
    let line = text.trim();
    if line.is_empty() {
        return;
    }
    collected.push_str(line);
    collected.push('\n');
    if let Some(progress) = parse_progress_line(run_id, line) {
        let _ = app.emit(event_name, progress);
    }
}

// ===========================================================================
// COMMAND: cancel_detection  (SIGTERM → 300ms → SIGKILL)
// ===========================================================================

#[tauri::command]
pub async fn cancel_detection(app: AppHandle, run_id: String) -> Result<(), String> {
    let pid = {
        let mgr = app.state::<SidecarManager>();
        let running = mgr.running.lock().await;
        match running.get(&run_id) {
            Some(handle) => {
                handle
                    .cancel_flag
                    .store(true, std::sync::atomic::Ordering::SeqCst);
                handle.pid
            }
            None => return Ok(()), // already finished — nothing to cancel
        }
    };
    if pid == 0 {
        return Ok(());
    }
    terminate_then_kill(pid).await;
    Ok(())
}

/// SIGTERM a pid, wait 300 ms, then SIGKILL if it's still alive. On non-Unix
/// this best-effort no-ops beyond the kill_on_drop path (v1 targets desktop
/// Unix + Windows; Windows uses TerminateProcess via the tokio kill fallback).
async fn terminate_then_kill(pid: u32) {
    #[cfg(unix)]
    {
        // SIGTERM
        unsafe {
            libc_kill(pid as i32, 15);
        }
        tokio::time::sleep(std::time::Duration::from_millis(300)).await;
        // SIGKILL (harmless if already reaped).
        unsafe {
            libc_kill(pid as i32, 9);
        }
    }
    #[cfg(not(unix))]
    {
        // Windows: taskkill /PID <pid> /F. Fire-and-forget.
        let _ = Command::new("taskkill")
            .args(["/PID", &pid.to_string(), "/F", "/T"])
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .status()
            .await;
    }
}

// Minimal FFI to `kill(2)` so we don't pull in the whole `libc`/`nix` crate
// just to send two signals. Present only on Unix.
#[cfg(unix)]
extern "C" {
    #[link_name = "kill"]
    fn libc_kill(pid: i32, sig: i32) -> i32;
}

// ===========================================================================
// COMMAND: detection_availability
// ===========================================================================

/// Is the active model runnable right now? venv present + `import cellpose`
/// importable. We probe by spawning `python -c "import cellpose"` (fast; the
/// interpreter is warm after install) so a half-built venv reads as unavailable.
#[tauri::command]
pub async fn detection_availability(
    app: AppHandle,
    _db: State<'_, Db>,
    model_id: String,
) -> Result<Availability, String> {
    let _ = model_id; // v1: cyto3 only; the venv either has cellpose or not.
    let store = FileStore::from_app(&app)?;

    let python = store.venv_python();
    let script = store.python_script("cellpose_detect.py");
    if !script.exists() {
        return Ok(Availability {
            installed: false,
            reason: Some("Sidecar scripts are not staged.".into()),
        });
    }
    if !python.exists() {
        return Ok(Availability {
            installed: false,
            reason: Some("Python environment is not installed.".into()),
        });
    }

    // Probe importability.
    let output = Command::new(&python)
        .args(["-c", "import cellpose"])
        .current_dir(store.python_dir())
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::piped())
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
                "Cellpose is not importable from the environment. {}",
                stderr.lines().last().unwrap_or("").trim()
            )),
        })
    }
}

// ===========================================================================
// Orphan sweep (launch) — kill stray sidecar processes from prior sessions
// ===========================================================================

/// Kill orphaned sidecar processes left by a previous (crashed) session.
/// PPID == 1 + cmdline contains one of our scripts ⇒ ours (mirrors
/// `ChildProcessTracker.sweepOrphans`). Best-effort; never blocks startup —
/// call it from a spawned task in `setup`.
pub fn sweep_orphans() {
    #[cfg(unix)]
    {
        use std::process::Command as StdCommand;
        let out = match StdCommand::new("/bin/ps")
            .args(["-ax", "-o", "pid=,ppid=,command="])
            .output()
        {
            Ok(o) => o,
            Err(e) => {
                eprintln!("[sidecar] orphan sweep: failed to run ps: {e}");
                return;
            }
        };
        let text = String::from_utf8_lossy(&out.stdout);
        let mut killed = 0usize;
        for line in text.lines() {
            let trimmed = line.trim();
            if trimmed.is_empty() {
                continue;
            }
            // "<pid> <ppid> <command...>"
            let mut it = trimmed.splitn(3, char::is_whitespace);
            let pid = it.next().and_then(|s| s.trim().parse::<i32>().ok());
            let ppid = it.next().and_then(|s| s.trim().parse::<i32>().ok());
            let command = it.next().unwrap_or("");
            let (Some(pid), Some(ppid)) = (pid, ppid) else {
                continue;
            };
            if ppid != 1 {
                continue; // only re-parented orphans are ours to reap
            }
            let is_ours = OWNED_SCRIPTS.iter().any(|s| command.contains(s));
            if !is_ours {
                continue;
            }
            unsafe {
                if libc_kill(pid, 9) == 0 {
                    killed += 1;
                }
            }
        }
        if killed > 0 {
            eprintln!("[sidecar] reaped {killed} orphan subprocess(es) from prior session");
        }
    }
    #[cfg(not(unix))]
    {
        // Windows orphan sweep: match the image name via WMIC/tasklist is
        // noisy; kill_on_drop + explicit cancel cover the common cases. Left as
        // a TODO for the Windows hardening pass.
    }
}
