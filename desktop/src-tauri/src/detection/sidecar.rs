//! detection/sidecar.rs — SidecarManager: warm-worker pool / stream / cancel (§3.1).
//!
//! Rust port of `Detection/CellposeDetectionService.swift` +
//! `Services/ChildProcessTracker.swift`. Owns the Python sidecar process
//! lifecycle and exposes the three detection commands registered in `lib.rs`:
//!   * `run_detection`         — run one image against a warm worker (or a
//!                               one-shot fallback), stream stderr progress,
//!                               return the parsed payload
//!   * `cancel_detection`      — cross-platform `Child::start_kill()`, by run_id
//!   * `detection_availability`— venv present + `import cellpose` importable?
//!
//! ## Persistent-worker pool (Pass-24)
//!
//! A lab batch is 100+ phase-contrast images. Spawning a fresh Python +
//! importing torch + building the CellposeModel per image dominates wall time
//! (seconds of import/model-load for a sub-second inference). This module keeps
//! a small pool of **warm workers**: `cellpose_detect.py --serve` processes that
//! import once, build the model once, print `{"type":"ready"}`, then service
//! NDJSON requests over stdin — one framed `{"type":"result",...}` per image.
//!
//! Pool shape:
//!   * Keyed by a **config signature** (`config_signature`) covering every arg
//!     that changes model construction: model id, GPU/CPU, channels. Two images
//!     with the same signature reuse the same warm worker; a different signature
//!     spawns its own worker(s).
//!   * Capped at `pool_capacity()` = `min(POOL_CAP_MAX, available_parallelism)`
//!     workers PER signature. In v1 (single cyto3 config) that is one bucket.
//!   * A worker services exactly **one in-flight request at a time**: `detect()`
//!     removes it from the pool for the duration of the request and returns it
//!     when done. That checkout is the whole concurrency story — no per-worker
//!     lock is needed on the stdout stream because only the owner reads it.
//!
//! ## Fallback (never fully break)
//!
//! If a worker fails to emit `ready` within [`READY_TIMEOUT`], or the worker
//! path errors mid-request (broken pipe, unparseable frame, unexpected EOF),
//! `detect()` falls back to the original **one-shot** spawn path
//! (`run_one_shot`) for that request and logs the fallback. Detection therefore
//! degrades to the pre-pool behaviour rather than failing.
//!
//! ## Cancellation + Windows hardening
//!
//! * Cancel calls tokio `Child::start_kill()` (TerminateProcess on Windows,
//!   SIGKILL on Unix) on the **actual child handle** — no pid-reuse race, no
//!   `taskkill`. A killed worker is dropped from the pool; the next request
//!   spawns a fresh one.
//! * The launch orphan sweep uses the cross-platform `sysinfo` crate to find
//!   stray `*_detect.py` processes from a crashed prior session and kill them.
//!
//! Wire details preserved from the Swift host:
//!   * argv order (see `build_argv`), model-id `cp-` prefix strip
//!   * one-shot stdout = one JSON object; serve stdout = NDJSON frames
//!   * stderr = `\n`/`\r`-split, trimmed, non-empty → `{kind:"stage"}` events;
//!     the `using device: <dev>` line → `{kind:"device"}`; tqdm bars dropped
//!   * structured `{error,hint}` stdout → `sidecarFailed`
//!   * exit codes {15,-15,143,9,-9,137} ⇒ `cancelled`
//!
//! Windows v1 pins CPU-only Torch/TensorFlow runtimes for reproducibility (see
//! pyproject.toml). The backend therefore forces `use_gpu = false` at the IPC
//! trust boundary; the preserved DTO field cannot turn a CPU package into a
//! GPU runtime or create a placebo setting.

use std::collections::HashMap;
use std::process::Stdio;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::time::{Duration, Instant};

use tauri::{AppHandle, Emitter, Manager, State};
use tokio::io::{AsyncBufReadExt, AsyncReadExt, AsyncWriteExt, BufReader, Lines};
use tokio::process::{Child, ChildStdin, ChildStdout, Command};
use tokio::sync::{Mutex, Notify};

use crate::db::repo::Db;
use crate::detection::ipc::{
    progress_event_name, Availability, DetectionErrorDto, DetectionParams, DetectionProgress,
    DetectionResultDto, SidecarError, SidecarPayload,
};
use crate::paths::FileStore;

/// Sidecar scripts we own — used by the orphan sweep to identify stray
/// processes (mirrors `ChildProcessTracker.ownedScriptBasenames`).
const OWNED_SCRIPTS: &[&str] = &[
    "cellpose_detect.py",
    "cellpose4_detect.py",
    "cellpose_train.py",
    "stardist_detect.py",
    "sam_detect.py",
    "intensity_assays.py",
    "area_assays_detect.py",
    "puncta_detect.py",
    "track_cells.py",
    "neurite_outgrowth.py",
    "image_prepare.py",
    "classical_detect.py",
    "custom_detect.py",
    "omnipose_detect.py",
    "parity_workflows.py",
];

/// Signal-ish exit codes that mean the host terminated us on purpose.
const SIGNAL_EXIT_CODES: &[i32] = &[15, -15, 143, 9, -9, 137];

/// Hard cap on warm workers per config signature. `available_parallelism` is
/// then applied on top, so a 2-core box gets 2 and an 8-core box still caps at
/// this. cellpose inference is CPU/MPS-bound; more than a few concurrent
/// interpreters thrash rather than help, and each holds a full torch + model in
/// RAM. This MUST be at least the frontend's max detection concurrency
/// (`defaultMaxParallel()` = up to 4 in `kernel/store/store.ts`); otherwise the
/// last in-flight worker of every batch cycle is guaranteed to be evicted on
/// `return_worker_to_pool` and pays a full cold start (torch import + model
/// rebuild) on its next image.
const POOL_CAP_MAX: usize = 4;

/// How long we wait for a freshly-spawned worker to print `{"type":"ready"}`
/// before giving up on it and falling back to the one-shot path. Cold start is
/// torch import + model build; generous so a slow first import doesn't spuriously
/// trip the fallback.
const READY_TIMEOUT: Duration = Duration::from_secs(120);

/// Ready-handshake bound for Cellpose-SAM (`cpsam`) workers specifically. If the
/// install-time weight prefetch (`env::uv`) was ever skipped or the
/// `~/.cellpose/models` cache was cleared, cellpose 4 cold-downloads its ~1.15 GB
/// transformer weights on the worker's FIRST `CellposeModel` construction —
/// which, in serve mode, happens BEFORE it can print `ready`. [`READY_TIMEOUT`]'s
/// 120 s can't cover that download, so the SAM family gets a far larger bound.
/// Belt-and-suspenders with the install-time prefetch: in the common (prefetched)
/// case the cache is warm and `ready` still arrives quickly.
const READY_TIMEOUT_SAM: Duration = Duration::from_secs(900);

/// Per-request ceiling on how long we wait for a worker to return the matching
/// `result`/`error` frame. Guards against a wedged worker holding a request
/// forever; on timeout we kill that worker and fall back to one-shot.
const REQUEST_TIMEOUT: Duration = Duration::from_secs(600);

/// Registry of in-flight runs (for cancel) + the warm-worker pool.
/// `running` is keyed by client-generated `run_id`; `pool` by config signature.
#[derive(Default)]
pub struct SidecarManager {
    running: Mutex<HashMap<String, RunHandle>>,
    early_cancelled: Mutex<HashMap<String, Instant>>,
    /// Warm workers available for reuse, bucketed by config signature. A worker
    /// present here is idle; `detect()` removes it while a request is in flight.
    pool: Mutex<HashMap<String, Vec<Worker>>>,
}

/// Per-run cancellation handle. Lets `cancel_detection` terminate whatever
/// process is servicing the run right now — a warm worker or a one-shot child —
/// by killing the exact handle (no pid, no reuse race).
struct RunHandle {
    /// Set true by `cancel_detection` so the completion path reports `cancelled`
    /// even if the child raced to a non-signal exit.
    cancel_flag: Arc<AtomicBool>,
    /// How to actually terminate this run's process.
    kill: KillHandle,
}

/// The cancel mechanism, per path. Both end in a cross-platform
/// `Child::start_kill()` (TerminateProcess on Windows, SIGKILL on Unix); they
/// differ only in who owns the `Child` at cancel time.
#[derive(Clone)]
enum KillHandle {
    /// Warm worker: the `Child` lives inside the checked-out worker but is shared
    /// here via `Arc`. The request owner (`converse`) never locks this mutex, so
    /// cancel can lock + `start_kill()` instantly; the resulting stdout EOF ends
    /// the read loop.
    Worker(Arc<Mutex<Child>>),
    /// One-shot: the `Child` stays owned by `run_one_shot` (so its `wait()` needs
    /// no shared lock). Cancel fires this `Notify`; the one-shot body is
    /// `select!`ing on it and kills the child locally.
    OneShot(Arc<Notify>),
}

impl SidecarManager {
    pub fn new() -> Self {
        Self::default()
    }
}

/// Reserve/upgrade atomically with bounded early cancellation tombstones.
async fn register_run(app: &AppHandle, run_id: &str, handle: RunHandle) {
    let manager = app.state::<SidecarManager>();
    let mut running = manager.running.lock().await;
    let mut early = manager.early_cancelled.lock().await;
    early.retain(|_, time| time.elapsed() < Duration::from_secs(120));
    if early.remove(run_id).is_some() {
        handle.cancel_flag.store(true, Ordering::SeqCst);
        if let KillHandle::OneShot(notify) = &handle.kill {
            notify.notify_one();
        }
    }
    running.insert(run_id.to_owned(), handle);
}

/// A warm `--serve` worker: a long-lived Python process that built its model
/// once and now answers one NDJSON request per line. Removed from the pool while
/// busy, returned when idle; only the current owner touches `stdin`/`stdout`.
struct Worker {
    /// The config signature this worker was built for. Only requests with a
    /// matching signature may reuse it.
    config_sig: String,
    /// The child handle — shared so `cancel_detection` can `start_kill()` it and
    /// the pump can observe liveness. stdin/stdout/stderr were `take()`n out at
    /// spawn, so this handle is used only for kill/wait/id.
    child: Arc<Mutex<Child>>,
    /// Writer for request lines (NDJSON, one per image).
    stdin: ChildStdin,
    /// Buffered line reader over the worker's stdout (result/error frames).
    stdout: Lines<BufReader<ChildStdout>>,
    /// Shared "which run is active" slot the stderr pump reads to route progress
    /// events. `detect()` sets it for the duration of a request.
    active: Arc<Mutex<Option<ActiveRun>>>,
    /// Monotonic per-worker request id, echoed back in each frame's `id`.
    next_req_id: u64,
}

/// The run a worker is currently servicing — used by the shared stderr pump to
/// tag progress events with the right `run_id` and event name.
#[derive(Clone)]
struct ActiveRun {
    run_id: String,
    event_name: String,
}

// ===========================================================================
// Resolve + argv (shared by warm-worker and one-shot paths)
// ===========================================================================

/// The complete model allowlist for the Windows 1.0.8 release. Keeping this
/// mapping closed is intentional: an unknown app id must fail before spawning
/// Python, never get stripped/defaulted into a different model.
pub const WINDOWS_MODEL_IDS: [&str; 19] = [
    "cpsam_v2",
    "cp4-cpsam",
    "cp4-cpsam_v2",
    "cp4-cpdino",
    "cp4-cpdino-vitb",
    "cp-cyto3",
    "cp-cyto3-r",
    "cp-cyto2",
    "cp-nuclei",
    "sd-fluo",
    "sd-he",
    "sd-dsb2018",
    "cw-otsu",
    "cw-triangle",
    "cw-adaptive",
    "cw-manual",
    "omni-bact-phase",
    "omni-bact-fluor",
    "omni-cyto2",
];
pub fn is_classical(id: &str) -> bool {
    id.starts_with("cw-") && runtime_model_name(id).is_some()
}
pub fn is_omnipose(id: &str) -> bool {
    id.starts_with("omni-") && runtime_model_name(id).is_some()
}

/// Exact Python-side model name for a supported app id.
pub fn runtime_model_name(model_id: &str) -> Option<&'static str> {
    match model_id {
        "custom-cellpose" => Some("custom-cellpose"),
        "custom-stardist" => Some("custom-stardist"),
        "cpsam_v2" => Some("cpsam"),
        "cp4-cpsam" => Some("cpsam"),
        "cp4-cpsam_v2" => Some("cpsam_v2"),
        "cp4-cpdino" => Some("cpdino"),
        "cp4-cpdino-vitb" => Some("cpdino-vitb"),
        "cp-cyto3" | "cp-cyto3-r" => Some("cyto3"),
        "cp-cyto2" => Some("cyto2"),
        "cp-nuclei" => Some("nuclei"),
        "sd-he" => Some("2D_versatile_he"),
        "sd-dsb2018" => Some("2D_paper_dsb2018"),
        "cw-otsu" => Some("cw-otsu"),
        "cw-triangle" => Some("cw-triangle"),
        "cw-adaptive" => Some("cw-adaptive"),
        "cw-manual" => Some("cw-manual"),
        "omni-bact-phase" => Some("bact_phase_omni"),
        "omni-bact-fluor" => Some("bact_fluor_omni"),
        "omni-cyto2" => Some("cyto2_omni"),
        "sd-fluo" => Some("2D_versatile_fluo"),
        _ => None,
    }
}

pub fn is_supported_model(model_id: &str) -> bool {
    runtime_model_name(model_id).is_some()
}

/// Whether an app-facing model id routes to the Cellpose-SAM (`cellpose>=4`)
/// family — i.e. the isolated `.venv4` + `cellpose4_detect.py` sidecar rather
/// than the base cyto3 env. The frozen contract fixes the SAM id as bare
/// `cpsam` (no `cp-` prefix), so the test is on the prefix-stripped slug.
pub fn is_cellpose_sam(model_id: &str) -> bool {
    model_id == "cpsam_v2" || model_id.starts_with("cp4-")
}

pub fn is_stardist(model_id: &str) -> bool {
    model_id.starts_with("sd-") || model_id == "custom-stardist"
}

/// Version-aware `import cellpose` probe for the Cellpose-SAM (`cellpose>=4`)
/// family. Exit 0 iff cellpose imports AND its major version is >= 4 (venv4 got
/// the cp4 wheel); exit 2 when an OLDER cellpose imports (wrong venv — should
/// never happen in venv4); exit 1 when the import itself fails. Mirrors
/// `CellposeSAMDownloader.runPythonImportCheck` in the native app; shared with
/// `env::uv::env_availability`.
pub(crate) const CELLPOSE4_IMPORT_PROBE: &str = r#"
import sys
try:
    import cellpose
    v = getattr(cellpose, "version", None) or ""
    if not isinstance(v, str):
        v = str(v)
    major = int(v.split(".")[0]) if v else 0
    sys.exit(0 if major >= 4 else 2)
except Exception:
    sys.exit(1)
"#;

/// Resolve the model-appropriate venv python + staged detect script, or report
/// why the model isn't runnable. Mirrors `CellposeAvailability.detect()` /
/// `Cellpose4Availability.detect()` (simplified: uv gives us the venv directly,
/// no sandbox-bundle staging tiers). Cellpose-SAM (`cpsam`) routes to the
/// isolated `.venv4` + `cellpose4_detect.py`; every other model uses the base
/// `.venv` + `cellpose_detect.py`.
fn resolve_sidecar(
    store: &FileStore,
    model_id: &str,
) -> Result<(std::path::PathBuf, std::path::PathBuf), String> {
    if model_id == "custom-cellpose" || model_id == "custom-stardist" {
        let python = if model_id == "custom-stardist" {
            store.venv_stardist_python()
        } else {
            store.venv_python()
        };
        let script = store.python_script("custom_detect.py");
        if !python.is_file() || !script.is_file() {
            return Err("Install the matching Cellpose or StarDist runtime first".into());
        }
        Ok((python, script))
    } else if is_cellpose_sam(model_id) {
        let python = store.venv4_python();
        let script = store.python_script("cellpose4_detect.py");
        if !script.exists() {
            return Err("sidecar script cellpose4_detect.py is not staged".into());
        }
        if !python.exists() {
            return Err("Cellpose-SAM python venv (venv4) is not installed".into());
        }
        Ok((python, script))
    } else if is_stardist(model_id) {
        let python = store.venv_stardist_python();
        let script = store.python_script("stardist_detect.py");
        if !script.exists() {
            return Err("sidecar script stardist_detect.py is not staged".into());
        }
        if !python.exists() {
            return Err("StarDist Python environment is not installed".into());
        }
        Ok((python, script))
    } else if is_classical(model_id) || is_omnipose(model_id) {
        let python = if is_omnipose(model_id) {
            store.venv_omni_python()
        } else {
            store.venv_python()
        };
        let script = store.python_script(if is_omnipose(model_id) {
            "omnipose_detect.py"
        } else {
            "classical_detect.py"
        });
        if !python.is_file() || !script.is_file() {
            return Err("The selected detector environment is not installed".into());
        }
        Ok((python, script))
    } else if ["cp-cyto3", "cp-cyto3-r", "cp-cyto2", "cp-nuclei"].contains(&model_id) {
        let python = store.venv_python();
        let script = store.python_script("cellpose_detect.py");
        if !script.exists() {
            return Err("sidecar script cellpose_detect.py is not staged".into());
        }
        if !python.exists() {
            return Err("python venv is not installed".into());
        }
        Ok((python, script))
    } else {
        Err(format!("unsupported model id: {model_id}"))
    }
}

/// Resolve a venv python for the SHARED helper scripts (`_seg_npy_io.py`,
/// `_export_imagej_roi.py`) that can run in EITHER environment. Unlike
/// [`resolve_sidecar`], these helpers don't run a model — they only need a Python
/// with numpy / cellpose / roifile — so route them to whichever venv EXISTS:
/// prefer the base `.venv`, else fall back to the cpsam `.venv4` (which is
/// provisioned with numpy + cellpose, and cellpose pulls roifile transitively,
/// so both helpers import there too).
///
/// Models install per-card now, so "cpsam installed, base `.venv` absent" is a
/// reachable state; without this fallback ROI export and the `_seg.npy`
/// round-trip would hard-fail with a misleading "install Cellpose first" error
/// even though a usable Python is right there in `.venv4`. Returns `None` only
/// when NEITHER venv exists, so the caller can surface a single "install a model
/// first" message.
pub(crate) fn resolve_helper_python(store: &FileStore) -> Option<std::path::PathBuf> {
    let base = store.venv_python();
    if base.exists() {
        return Some(base);
    }
    let venv4 = store.venv4_python();
    if venv4.exists() {
        return Some(venv4);
    }
    None
}

/// Build the EXACT one-shot argv from `CellposeDetectionService.swift`.
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
    let custom = p.model_id.starts_with("custom-");
    let model = if custom {
        p.checkpoint_path
            .clone()
            .expect("Custom checkpoints resolve from the private registry")
    } else {
        runtime_model_name(&p.model_id)
            .expect("Validated model identity")
            .to_string()
    };

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
        "--z-project".into(),
        p.z_projection.clone(),
        "--preprocessing-preset".into(),
        p.preprocessing_preset
            .clone()
            .unwrap_or_else(|| "none".into()),
    ];
    if let Some(channel) = p.segment_channel {
        args.push("--segment-channel".into());
        args.push(channel.to_string());
    }
    if let Some(checkpoint) = p
        .checkpoint_path
        .as_deref()
        .filter(|_| !p.model_id.starts_with("custom-"))
    {
        args.push("--checkpoint".into());
        args.push(checkpoint.to_string());
    }

    if p.model_id.starts_with("custom-") {
        args.extend([
            "--custom-kind".into(),
            if p.model_id == "custom-stardist" {
                "stardist"
            } else {
                "cellpose"
            }
            .into(),
        ]);
    }
    if p.model_id == "cp-cyto3-r" {
        args.push("--restore".into());
    }
    let is_default_channels = p.channels == [0, 0];
    if !is_stardist(&p.model_id) && !is_default_channels {
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
    if !is_stardist(&p.model_id) && p.expected_diameter_um > 0.0 {
        args.push("--diameter".into());
        args.push(p.expected_diameter_um.to_string());
    }
    if !is_stardist(&p.model_id) && !p.use_gpu {
        args.push("--no-gpu".into());
    }
    if p.model_id == "cw-manual" {
        args.extend([
            "--threshold-value".into(),
            p.classical_threshold.unwrap_or(128.0).to_string(),
        ]);
    }
    args
}

/// Build the argv for a persistent `--serve` worker: only the
/// model-determining args (model, channels, GPU) plus `--pxPerUm` (required by
/// the parser even though it is overridden per-request). Per-image params
/// (image / conf / thresholds / bg-subtract / watershed) are NOT here — they
/// arrive per-request over stdin.
fn build_serve_argv(script: &std::path::Path, p: &DetectionParams) -> Vec<String> {
    let model = runtime_model_name(&p.model_id)
        .expect("build_serve_argv is only called after model allowlist validation")
        .to_string();

    let mut args: Vec<String> = vec![
        script.to_string_lossy().into_owned(),
        "--serve".into(),
        "--model".into(),
        model,
        // `--pxPerUm` is `required=True` on the shared parser; supply the first
        // request's value as a placeholder. Every request overrides it, so the
        // exact value here is irrelevant beyond satisfying argparse.
        "--pxPerUm".into(),
        p.px_per_um.to_string(),
    ];
    if let Some(checkpoint) = p
        .checkpoint_path
        .as_deref()
        .filter(|_| !p.model_id.starts_with("custom-"))
    {
        args.push("--checkpoint".into());
        args.push(checkpoint.to_string());
    }

    if p.model_id == "cp-cyto3-r" {
        args.push("--restore".into());
    }
    let is_default_channels = p.channels == [0, 0];
    if !is_default_channels {
        args.push("--channels".into());
        args.push(format!("{},{}", p.channels[0], p.channels[1]));
    }
    if !p.use_gpu {
        args.push("--no-gpu".into());
    }
    args
}

/// The per-image request line written to a warm worker's stdin. Field names
/// match the Python `_PER_IMAGE_KEYS`; anything omitted keeps the argv default.
/// This is the serve-mode analogue of the per-image argv flags in `build_argv`.
fn build_request_json(id: u64, image_path: &str, p: &DetectionParams) -> String {
    // Assemble via serde_json::Value so escaping (paths with quotes/backslashes,
    // esp. on Windows) is always correct.
    let mut map = serde_json::Map::new();
    map.insert("id".into(), serde_json::json!(id));
    map.insert("image".into(), serde_json::json!(image_path));
    map.insert(
        "preprocessing_preset".into(),
        serde_json::json!(p
            .preprocessing_preset
            .clone()
            .unwrap_or_else(|| "none".into())),
    );
    map.insert("z_project".into(), serde_json::json!(p.z_projection));
    map.insert(
        "segment_channel".into(),
        serde_json::json!(p.segment_channel),
    );
    map.insert("conf".into(), serde_json::json!(p.confidence_threshold));
    map.insert("pxPerUm".into(), serde_json::json!(p.px_per_um));
    map.insert(
        "small_threshold".into(),
        serde_json::json!(p.small_threshold_um),
    );
    map.insert(
        "large_threshold".into(),
        serde_json::json!(p.large_threshold_um),
    );
    if p.expected_diameter_um > 0.0 {
        map.insert("diameter".into(), serde_json::json!(p.expected_diameter_um));
    }
    map.insert(
        "bg_subtract".into(),
        serde_json::json!(p.background_subtract),
    );
    map.insert(
        "rolling_ball_radius".into(),
        serde_json::json!(p.rolling_ball_radius),
    );
    map.insert("watershed".into(), serde_json::json!(p.watershed_split));
    // Python declares this int; round to match `build_argv`'s integer coercion.
    map.insert(
        "watershed_min_distance".into(),
        serde_json::json!(p.watershed_min_distance_um.round() as i64),
    );
    serde_json::Value::Object(map).to_string()
}

/// Signature that determines model construction. Two requests with the same
/// signature may share a warm worker; a different one spawns its own. Covers
/// model id, GPU/CPU, and channels (channels change both model.eval and image
/// loading). Per-image params are deliberately excluded.
///
/// The model-id slug keeps the Cellpose-SAM (`cpsam`) family in its own bucket:
/// its signature (`model=cpsam|…`) never matches a cyto3 signature
/// (`model=cyto3|…`), so a warm cyto3 worker (base `.venv`) is never reused for
/// a cpsam request — which must run the `.venv4` + `cellpose4_detect.py` pair.
fn config_signature(p: &DetectionParams) -> String {
    let model = runtime_model_name(&p.model_id)
        .expect("config_signature is only called after model allowlist validation");
    format!(
        "model={model}|restore={}|checkpoint={}|gpu={}|channels={},{}|identity={}",
        p.model_id == "cp-cyto3-r",
        p.checkpoint_path.as_deref().unwrap_or("base"),
        p.use_gpu,
        p.channels[0],
        p.channels[1],
        p.runtime_identity_key.as_deref().unwrap_or("uncaptured")
    )
}

fn resolve_derived_checkpoint(
    db: &Db,
    store: &FileStore,
    model_id: &str,
) -> Result<Option<String>, String> {
    if !model_id.starts_with("cp-cyto3@") {
        return Ok(None);
    }
    let raw = crate::db::repo::model_checkpoint_for(db, model_id)?
        .ok_or_else(|| "The selected fine-tuned cp-cyto3 version does not exist.".to_string())?;
    let models_dir = std::fs::canonicalize(store.models_dir())
        .map_err(|error| format!("Could not resolve the model store: {error}"))?;
    let checkpoint = std::fs::canonicalize(&raw)
        .map_err(|error| format!("The selected checkpoint is missing: {error}"))?;
    if !checkpoint.is_file() || !checkpoint.starts_with(&models_dir) {
        return Err(
            "The selected checkpoint is not a regular file inside CellCounter's model store."
                .to_string(),
        );
    }
    Ok(Some(checkpoint.to_string_lossy().into_owned()))
}

fn enforce_windows_runtime_contract(params: &mut DetectionParams) {
    params.checkpoint_path = None;
    params.runtime_identity_key = None;
    params.runtime_cancel_flag = None;
    params.runtime_cancel_notify = None;
    params.use_gpu = false;
}

/// Warm-worker pool capacity per signature: `available_parallelism` capped at
/// [`POOL_CAP_MAX`], floored at 1.
fn pool_capacity() -> usize {
    let par = std::thread::available_parallelism()
        .map(|n| n.get())
        .unwrap_or(1);
    par.clamp(1, POOL_CAP_MAX)
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
    db: State<'_, Db>,
    image_path: String,
    mut params: DetectionParams,
    run_id: String,
) -> Result<DetectionResultDto, DetectionErrorDto> {
    let store = FileStore::from_app(&app).map_err(|_| DetectionErrorDto::ImageDecodeFailed)?;
    let invalid = || DetectionErrorDto::SidecarFailed {
        exit_code: 2,
        stderr: "Invalid analysis parameters or model identity".into(),
    };
    uuid::Uuid::parse_str(&run_id).map_err(|_| invalid())?;
    if params.model_id == "custom-cellpose"
        || params.model_id == "custom-stardist"
        || !params.px_per_um.is_finite()
        || params.px_per_um <= 0.0
        || !params.confidence_threshold.is_finite()
        || !(0.0..=1.0).contains(&params.confidence_threshold)
        || !params.small_threshold_um.is_finite()
        || !params.large_threshold_um.is_finite()
        || params.small_threshold_um < 0.0
        || params.large_threshold_um <= params.small_threshold_um
        || !params.expected_diameter_um.is_finite()
        || params.expected_diameter_um < 0.0
        || params.classical_threshold.is_some_and(|v| !v.is_finite())
        || !["none", "clahe", "denoise", "normalize"]
            .contains(&params.preprocessing_preset.as_deref().unwrap_or("none"))
    {
        return Err(invalid());
    }

    if !["max", "mean", "sum", "none"].contains(&params.z_projection.as_str()) {
        return Err(DetectionErrorDto::SidecarFailed {
            exit_code: 2,
            stderr: "Invalid Z projection. Choose max, mean, sum, or none.".to_string(),
        });
    }
    crate::env::uv::stage_python_project(&app, &store).map_err(|stderr| {
        DetectionErrorDto::SidecarFailed {
            exit_code: -1,
            stderr,
        }
    })?;
    let requested_model_id = params.model_id.clone();
    // `checkpointPath` is an internal trust-boundary field. Never honor a value
    // deserialized from IPC; only the canonical DB lineage lookup below may set it.
    enforce_windows_runtime_contract(&mut params);
    let mut custom_checkpoint_identity = None;
    if requested_model_id.starts_with("custom-") {
        let model = {
            let conn = db
                .connection()
                .map_err(|stderr| DetectionErrorDto::SidecarFailed {
                    exit_code: 3,
                    stderr,
                })?;
            crate::parity::custom_model(&conn, &store, &requested_model_id).map_err(|stderr| {
                DetectionErrorDto::SidecarFailed {
                    exit_code: 3,
                    stderr,
                }
            })?
        };
        custom_checkpoint_identity = model["sha256"].as_str().map(str::to_owned);
        params.checkpoint_path = model["path"].as_str().map(str::to_owned);
        params.model_id = if model["kind"] == "stardist" {
            "custom-stardist"
        } else {
            "custom-cellpose"
        }
        .into();
    } else if requested_model_id.starts_with("cp-cyto3@") {
        params.checkpoint_path = resolve_derived_checkpoint(&db, &store, &requested_model_id)
            .map_err(|_| DetectionErrorDto::ModelNotInstalled {
                model_id: requested_model_id.clone(),
            })?;
        params.model_id = "cp-cyto3".to_string();
    }

    let (python, script) = resolve_sidecar(&store, &params.model_id).map_err(|_| {
        DetectionErrorDto::ModelNotInstalled {
            model_id: params.model_id.clone(),
        }
    })?;
    let snapshot_model = if requested_model_id.starts_with("cp-cyto3@") {
        "cp-cyto3"
    } else {
        &requested_model_id
    };
    let snapshot_path = crate::env::uv::runtime_snapshot_path(&store, snapshot_model);
    let custom = requested_model_id.starts_with("custom-");
    let snapshot_exists = snapshot_path.is_file();
    let probe_args = if custom || (!snapshot_exists && is_classical(&params.model_id)) {
        None
    } else {
        Some(
            crate::env::uv::runtime_snapshot_args(&store, snapshot_model, true).map_err(
                |stderr| DetectionErrorDto::SidecarFailed {
                    exit_code: 3,
                    stderr,
                },
            )?,
        )
    };
    // Source projection can be slow for a vendor stack. Register cancellation
    // before opening its reader, and retain its temporary TIFF until inference
    // finishes; concurrent runs never replace one another's selected plane.
    let preparation_cancelled = Arc::new(AtomicBool::new(false));
    let preparation_notify = Arc::new(Notify::new());
    params.runtime_cancel_flag = Some(preparation_cancelled.clone());
    params.runtime_cancel_notify = Some(preparation_notify.clone());
    register_run(
        &app,
        &run_id,
        RunHandle {
            cancel_flag: preparation_cancelled.clone(),
            kill: KillHandle::OneShot(preparation_notify.clone()),
        },
    )
    .await;
    if preparation_cancelled.load(Ordering::SeqCst) {
        deregister_run(&app, &run_id).await;
        return Err(DetectionErrorDto::Cancelled);
    }
    let source_identity = match verified_source_identity(&db, &store, &image_path, preparation_cancelled.clone()).await {
        Ok(identity) => identity,
        Err(error) => { deregister_run(&app, &run_id).await; return Err(error); }
    };
    // Probe actual package versions and checkpoint bytes before using a cached
    // worker. A changed environment/checkpoint/script gets a distinct pool key.
    let mut probe = Command::new(&python);
    if custom || (!snapshot_exists && is_classical(&params.model_id)) {
        let package_names = if params.model_id == "custom-stardist" {
            "['stardist','csbdeep','tensorflow','numpy']"
        } else if is_classical(&params.model_id) {
            "['scikit-image','scipy','numpy']"
        } else {
            "['cellpose','torch','numpy']"
        };
        probe.args(["-c",&format!("import importlib.metadata as m,json;print(json.dumps({{n:m.version(n) for n in {package_names}}}))")]);
    } else {
        probe.args(
            probe_args
                .as_ref()
                .expect("Built-in probe arguments were validated"),
        );
    }
    probe
        .current_dir(store.python_dir())
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .kill_on_drop(true);
    crate::proc::hide_console_tokio(&mut probe);
    let probe_result = tokio::select! {
        biased;
        _=preparation_notify.notified()=>Err(DetectionErrorDto::Cancelled),
        value=tokio::time::timeout(Duration::from_secs(120),probe.output())=>match value {
            Ok(Ok(output)) if output.status.success()=>Ok(output),
            Ok(Ok(output))=>Err(DetectionErrorDto::SidecarFailed{exit_code:3,stderr:String::from_utf8_lossy(&output.stderr).into_owned()}),
            Ok(Err(error))=>Err(DetectionErrorDto::SidecarFailed{exit_code:3,stderr:error.to_string()}),
            Err(_)=>Err(DetectionErrorDto::SidecarFailed{exit_code:3,stderr:"Exact runtime/checkpoint verification timed out".into()}),
        }
    };
    let probe_output = match probe_result {
        Ok(output) => output,
        Err(error) => {
            deregister_run(&app, &run_id).await;
            return Err(error);
        }
    };
    if preparation_cancelled.load(Ordering::SeqCst) {
        deregister_run(&app, &run_id).await;
        return Err(DetectionErrorDto::Cancelled);
    }
    let identity_result = (|| -> Result<serde_json::Value, DetectionErrorDto> {
        let mut runtime_identity = if custom || !snapshot_exists {
            serde_json::json!({"schemaVersion":1,"packages":serde_json::from_slice::<serde_json::Value>(&probe_output.stdout).map_err(|e|DetectionErrorDto::SidecarFailed{exit_code:3,stderr:e.to_string()})?})
        } else {
            serde_json::from_slice::<serde_json::Value>(&std::fs::read(&snapshot_path).map_err(
                |e| DetectionErrorDto::SidecarFailed {
                    exit_code: 3,
                    stderr: e.to_string(),
                },
            )?)
            .map_err(|e| DetectionErrorDto::SidecarFailed {
                exit_code: 3,
                stderr: e.to_string(),
            })?
        };
        runtime_identity["modelId"] = serde_json::json!(requested_model_id);
        runtime_identity["modelFamily"] = serde_json::json!(if is_stardist(&params.model_id) { "stardist" } else if is_classical(&params.model_id) { "classical" } else if is_omnipose(&params.model_id) { "omnipose" } else { "cellpose" });
        if let Some(checkpoint) = params.checkpoint_path.as_deref() {
            let digest = if let Some(identity) = custom_checkpoint_identity.as_ref() {
                identity.clone()
            } else {
                crate::parity::checkpoint_digest(std::path::Path::new(checkpoint)).map_err(
                    |stderr| DetectionErrorDto::SidecarFailed {
                        exit_code: 3,
                        stderr,
                    },
                )?
            };
            runtime_identity["selectedCheckpointSha256"] = serde_json::json!(digest);
        }
        let mut key = runtime_identity.to_string();
        key.push_str(&python.to_string_lossy());
        for member in [
            script.clone(),
            store.python_script("_cellpose_common.py"),
            store.python_script("_imageio.py"),
            store.python_script("_preprocessing.py"),
        ] {
            key.push_str(
                &crate::parity::checkpoint_digest(&member).map_err(|stderr| {
                    DetectionErrorDto::SidecarFailed {
                        exit_code: 3,
                        stderr,
                    }
                })?,
            );
        }
        use sha2::Digest;
        params.runtime_identity_key = Some(format!("{:x}", sha2::Sha256::digest(key.as_bytes())));
        runtime_identity["implementationSha256"] = serde_json::json!(params.runtime_identity_key);
        if let Some(checkpoints) = runtime_identity["checkpoints"].as_array_mut() {
            for checkpoint in checkpoints {
                if let Some(map) = checkpoint.as_object_mut() {
                    if let Some(path) = map.remove("path") {
                        map.insert(
                            "fileName".into(),
                            serde_json::json!(path
                                .as_str()
                                .and_then(|p| std::path::Path::new(p).file_name())
                                .map(|p| p.to_string_lossy().into_owned())),
                        );
                    }
                }
            }
        }
        Ok(runtime_identity)
    })();
    let runtime_identity = match identity_result {
        Ok(value) => value,
        Err(error) => {
            deregister_run(&app, &run_id).await;
            return Err(error);
        }
    };
    let source = crate::images::projection::prepare(
        &db,
        &store,
        &image_path,
        &params.z_projection,
        &preparation_notify,
    )
    .await
    .map_err(|stderr| DetectionErrorDto::SidecarFailed {
        exit_code: 3,
        stderr,
    });
    deregister_run(&app, &run_id).await;
    if preparation_cancelled.load(Ordering::SeqCst) {
        return Err(DetectionErrorDto::Cancelled);
    }
    let source = source?;
    let image_path = source.path.clone();

    // StarDist's public API is one-shot only. Do not attempt the Cellpose
    // `--serve` handshake (and do not hide a failed handshake behind a retry):
    // route it directly to the cancellable one-shot runner.
    if is_stardist(&params.model_id)
        || is_classical(&params.model_id)
        || is_omnipose(&params.model_id)
        || params.model_id.starts_with("custom-")
    {
        let mut result = run_one_shot(
            &app,
            &python,
            &script,
            &store,
            &image_path,
            &params,
            &run_id,
        )
        .await?;
        verify_completed_source(&app, &run_id, source_identity, preparation_cancelled.clone(), preparation_notify.clone()).await?;
        result.runtime_identity = Some(runtime_identity);
        return Ok(result);
    }

    // Shared cancellation state and bounded early tombstones cover the handoff
    // between preparation and either inference runner. Try the warm-worker path first; on any
    // worker-side malfunction fall back to the one-shot spawn so detection never
    // fully breaks. A structured per-image error from the worker is surfaced
    // directly (not retried).
    let mut result = match run_via_worker(
        &app,
        &python,
        &script,
        &store,
        &image_path,
        &params,
        &run_id,
    )
    .await
    {
        Ok(dto) => Ok(dto),
        Err(WorkerAttempt::Cancelled) => Err(DetectionErrorDto::Cancelled),
        Err(WorkerAttempt::SidecarError(dto)) => {
            // The worker ran the image and reported a structured sidecar error
            // (bad image, eval-failed, …). That is a real per-image failure, not
            // a worker malfunction — surface it directly, do NOT retry one-shot
            // (a retry would just reproduce the same error at higher cost).
            Err(dto)
        }
        Err(WorkerAttempt::Fallback(reason)) => {
            eprintln!(
                "[sidecar] warm-worker path unavailable ({reason}); \
                 falling back to one-shot spawn for run {run_id}"
            );
            run_one_shot(
                &app,
                &python,
                &script,
                &store,
                &image_path,
                &params,
                &run_id,
            )
            .await
        }
    }?;
    verify_completed_source(&app, &run_id, source_identity, preparation_cancelled.clone(), preparation_notify.clone()).await?;
    result.runtime_identity = Some(runtime_identity);
    Ok(result)
}

async fn verify_completed_source(app: &AppHandle, run_id: &str, source: (std::path::PathBuf, String), cancelled: Arc<AtomicBool>, notify: Arc<Notify>) -> Result<(), DetectionErrorDto> {
    // Keep cancellation available while the final streaming source check runs;
    // a cancellation in the inference handoff gap is consumed as a tombstone.
    register_run(app, run_id, RunHandle { cancel_flag: cancelled.clone(), kill: KillHandle::OneShot(notify) }).await;
    let result=verify_source_bytes(source.0,source.1,cancelled.clone()).await;
    deregister_run(app,run_id).await;
    if cancelled.load(Ordering::SeqCst) { return Err(DetectionErrorDto::Cancelled); }
    result
}

async fn verified_source_identity(db: &Db, store: &FileStore, input: &str, cancelled: Arc<AtomicBool>) -> Result<(std::path::PathBuf, String), DetectionErrorDto> {
    use rusqlite::OptionalExtension;
    let invalid = |message: String| DetectionErrorDto::SidecarFailed { exit_code: 3, stderr: message };
    let requested = std::path::Path::new(input);
    let stem = requested.file_stem().and_then(|name| name.to_str()).ok_or_else(|| invalid("Analysis requires an imported source image".into()))?;
    let record: Option<(String, String, Option<String>, Option<String>, Option<String>)> = {
        let conn = db.connection().map_err(invalid)?;
        conn.query_row("SELECT id,file_name,stored_ext,analysis_path,file_hash FROM images WHERE id=?1 OR analysis_path=?2", rusqlite::params![stem,input], |r| Ok((r.get(0)?,r.get(1)?,r.get(2)?,r.get(3)?,r.get(4)?))).optional().map_err(|error| invalid(error.to_string()))?
    };
    let (id, name, stored_ext, analysis, hash) = record.ok_or_else(|| invalid("Analysis requires an imported source image".into()))?;
    let extension = std::path::Path::new(&name).extension().and_then(|ext| ext.to_str()).unwrap_or("tif");
    let (permitted, source) = if let Some(path) = analysis {
        (std::path::PathBuf::from(path), store.original_path(&id, extension))
    } else {
        let path = store.image_path(&id, stored_ext.as_deref().unwrap_or(extension));
        (path.clone(), path)
    };
    if requested.canonicalize().map_err(|error| invalid(error.to_string()))? != permitted.canonicalize().map_err(|error| invalid(error.to_string()))? {
        return Err(invalid("Analysis path does not match its imported source".into()));
    }
    let hash = hash.filter(|value| value.len()==64 && value.bytes().all(|byte| byte.is_ascii_hexdigit())).ok_or_else(|| invalid("This historical image has no immutable source SHA-256; reimport it before analysis".into()))?;
    verify_source_bytes(source.clone(), hash.clone(), cancelled).await?;
    Ok((source,hash))
}

async fn verify_source_bytes(path: std::path::PathBuf, expected: String, cancelled: Arc<AtomicBool>) -> Result<(), DetectionErrorDto> {
    tokio::task::spawn_blocking(move || {
        use sha2::Digest;
        use std::io::Read;
        let invalid = |message: String| DetectionErrorDto::SidecarFailed { exit_code: 3, stderr: message };
        let mut file = std::fs::File::open(&path).map_err(|error| invalid(error.to_string()))?;
        let before = file.metadata().map_err(|error| invalid(error.to_string()))?;
        let mut hash = sha2::Sha256::new();
        let mut bytes = [0u8;65536];
        loop {
            if cancelled.load(Ordering::SeqCst) { return Err(DetectionErrorDto::Cancelled); }
            let count = file.read(&mut bytes).map_err(|error| invalid(error.to_string()))?;
            if count == 0 { break; }
            hash.update(&bytes[..count]);
        }
        let after = std::fs::metadata(&path).map_err(|error| invalid(error.to_string()))?;
        if before.len()!=after.len() || before.modified().ok()!=after.modified().ok() || !format!("{:x}",hash.finalize()).eq_ignore_ascii_case(&expected) {
            return Err(invalid("The preserved source changed after import; reimport it before analysis".into()));
        }
        Ok(())
    }).await.map_err(|error| DetectionErrorDto::SidecarFailed { exit_code:3, stderr:error.to_string() })?
}

/// Outcome of an attempt to service a request via the warm-worker pool.
enum WorkerAttempt {
    /// The run was cancelled while bound to a worker.
    Cancelled,
    /// The worker produced a structured sidecar error for this image — a real
    /// per-image failure; surface it (do not retry one-shot).
    SidecarError(DetectionErrorDto),
    /// The worker path could not be used (no ready worker / broken pipe /
    /// timeout / unparseable frame). Carries a human reason for the log; the
    /// caller retries via one-shot.
    Fallback(String),
}

/// Acquire (or spawn) a warm worker for this config, send the request, stream
/// stderr progress, and read frames until the matching `result`/`error`.
async fn run_via_worker(
    app: &AppHandle,
    python: &std::path::Path,
    script: &std::path::Path,
    store: &FileStore,
    image_path: &str,
    params: &DetectionParams,
    run_id: &str,
) -> Result<DetectionResultDto, WorkerAttempt> {
    let sig = config_signature(params);
    let event_name = progress_event_name(run_id);
    // The run the worker's stderr pump should tag progress with. Passed into the
    // acquisition so it is attached FROM SPAWN — a freshly-spawned worker prints
    // its cold-start `using device:` line (and other stage lines) DURING the
    // ready handshake, before this request's read loop begins; attaching now
    // means those lines still reach the first image's run.
    let initial_active = ActiveRun {
        run_id: run_id.to_string(),
        event_name: event_name.clone(),
    };

    // 1) Register the run for cancellation BEFORE acquiring the worker. Spawning
    //    a cold worker blocks up to READY_TIMEOUT (torch import + model build);
    //    if the registry entry only appeared afterwards, a Cancel arriving during
    //    that window would find no entry and be a silent no-op for up to two
    //    minutes — exactly the (slowest, first) image a user is most likely to
    //    cancel. We register with a `Notify` kill handle the spawn loop selects
    //    on, then UPGRADE the handle to the real child once the worker is up.
    let cancel_flag = params
        .runtime_cancel_flag
        .clone()
        .unwrap_or_else(|| Arc::new(AtomicBool::new(false)));
    let cancel_notify = params
        .runtime_cancel_notify
        .clone()
        .unwrap_or_else(|| Arc::new(Notify::new()));
    register_run(
        app,
        run_id,
        RunHandle {
            cancel_flag: cancel_flag.clone(),
            kill: KillHandle::OneShot(cancel_notify.clone()),
        },
    )
    .await;

    // Get a warm worker: pop an idle one from the pool (and point its pump at
    // this run), else spawn + await ready with the pump already attached. The
    // spawn path polls `cancel_flag` / selects on `cancel_notify`, so a cancel
    // during cold start aborts the spawn (its child is reaped on drop) instead
    // of being dropped. On spawn/ready failure, request a one-shot fallback.
    let mut worker = match take_or_spawn_worker(
        app,
        python,
        script,
        store,
        params,
        &sig,
        &initial_active,
        &cancel_flag,
        &cancel_notify,
    )
    .await
    {
        Ok(w) => w,
        Err(SpawnOutcome::Cancelled) => {
            deregister_run(app, run_id).await;
            return Err(WorkerAttempt::Cancelled);
        }
        Err(SpawnOutcome::Failed(reason)) => {
            deregister_run(app, run_id).await;
            return Err(WorkerAttempt::Fallback(reason));
        }
        Err(SpawnOutcome::SidecarError(error)) => {
            deregister_run(app, run_id).await;
            return Err(WorkerAttempt::SidecarError(error));
        }
    };

    // 2) Upgrade the cancel handle to bind THIS worker's child, so a cancel
    //    during the request kills the real process (the `Notify` handle only
    //    covered the cold-start window above).
    {
        let mgr = app.state::<SidecarManager>();
        let mut running = mgr.running.lock().await;
        running.insert(
            run_id.to_string(),
            RunHandle {
                cancel_flag: cancel_flag.clone(),
                kill: KillHandle::Worker(worker.child.clone()),
            },
        );
    }
    // If cancel already fired between spawn and the handle upgrade, honour it.
    if cancel_flag.load(Ordering::SeqCst) {
        deregister_run(app, run_id).await;
        kill_worker(&worker).await;
        return Err(WorkerAttempt::Cancelled);
    }

    // 3) Send the request line and read frames until our id comes back.
    let req_id = worker.next_req_id;
    worker.next_req_id += 1;
    let request = build_request_json(req_id, image_path, params);

    let outcome = converse(&mut worker, req_id, &request, &cancel_flag).await;

    // 4) Detach the pump from this run regardless of outcome, and deregister so
    //    a later cancel for this run_id is a no-op.
    {
        let mut active = worker.active.lock().await;
        *active = None;
    }
    deregister_run(app, run_id).await;

    let was_cancelled = cancel_flag.load(Ordering::SeqCst);

    match outcome {
        Converse::Result(payload) => {
            // Healthy worker → return it to the pool for reuse — UNLESS a cancel
            // raced in at the same instant the frame arrived: `cancel_detection`
            // has already `start_kill()`ed this child, so recycling it would push
            // a dead process into the idle pool (the next checkout would only
            // discover the broken pipe). Reap it instead of repooling.
            if was_cancelled {
                kill_worker(&worker).await;
            } else {
                return_worker_to_pool(app, worker).await;
            }
            Ok(payload.into_result_dto())
        }
        Converse::SidecarError { error, hint } => {
            // Worker itself is fine (it framed a clean error); recycle it — but,
            // as above, if a cancel already start_kill()ed the child, reap it
            // rather than repooling a dead process.
            if was_cancelled {
                kill_worker(&worker).await;
            } else {
                return_worker_to_pool(app, worker).await;
            }
            let combined = match hint {
                Some(h) => format!("{error}: {h}"),
                None => error,
            };
            Err(WorkerAttempt::SidecarError(
                DetectionErrorDto::SidecarFailed {
                    exit_code: 0,
                    stderr: combined,
                },
            ))
        }
        Converse::Cancelled => {
            kill_worker(&worker).await;
            Err(WorkerAttempt::Cancelled)
        }
        Converse::Broken { reason, dispatched } => {
            // Pipe/parse/timeout failure. Kill the worker (it may be wedged).
            kill_worker(&worker).await;
            if was_cancelled {
                Err(WorkerAttempt::Cancelled)
            } else if dispatched {
                // The worker already had the request in hand (EOF / read error /
                // timeout after a successful stdin write). Re-running one-shot
                // here would run the most expensive work in the app a SECOND
                // time for the same image — and a chronically-too-short
                // REQUEST_TIMEOUT would silently double every slow image. Surface
                // the failure instead of masking it with a hidden retry.
                eprintln!(
                    "[sidecar] warm worker lost after dispatch for run {} ({}); \
                     NOT re-running one-shot (would double the eval)",
                    run_id, reason
                );
                Err(WorkerAttempt::SidecarError(
                    DetectionErrorDto::SidecarFailed {
                        exit_code: -1,
                        stderr: format!(
                            "The detection worker stopped responding after the image was \
                         sent ({reason}). The image was not re-run automatically to \
                         avoid doubling the work; try running it again."
                        ),
                    },
                ))
            } else {
                // The worker never accepted the request (stdin write/flush error)
                // — safe to fall back to a fresh one-shot spawn with no risk of
                // double work.
                Err(WorkerAttempt::Fallback(reason))
            }
        }
    }
}

/// Result of one request/response exchange with a warm worker.
enum Converse {
    Result(SidecarPayload),
    SidecarError {
        error: String,
        hint: Option<String>,
    },
    Cancelled,
    /// The exchange failed. `dispatched` records whether the request line was
    /// already written+flushed into the worker's stdin before the failure:
    ///   * `dispatched == false` — the worker never accepted the work (a stdin
    ///     write/flush error), so re-running one-shot is safe and free of the
    ///     double-work hazard.
    ///   * `dispatched == true`  — the worker may already be running this image
    ///     (EOF / read error / timeout AFTER a successful write). A one-shot
    ///     retry would then run the most expensive work in the app twice, so the
    ///     caller does NOT retry; it surfaces the failure instead.
    Broken {
        reason: String,
        dispatched: bool,
    },
}

/// Write the request line, then read stdout frames until we see our `id`.
/// stderr progress is handled out-of-band by the worker's pump task.
async fn converse(
    worker: &mut Worker,
    req_id: u64,
    request_json: &str,
    cancel_flag: &Arc<AtomicBool>,
) -> Converse {
    // Write "<json>\n" and flush. A failure BEFORE the flush completes means the
    // worker never accepted the request → the caller may safely retry one-shot.
    if let Err(e) = worker.stdin.write_all(request_json.as_bytes()).await {
        return Converse::Broken {
            reason: format!("stdin write failed: {e}"),
            dispatched: false,
        };
    }
    if let Err(e) = worker.stdin.write_all(b"\n").await {
        return Converse::Broken {
            reason: format!("stdin newline write failed: {e}"),
            dispatched: false,
        };
    }
    if let Err(e) = worker.stdin.flush().await {
        return Converse::Broken {
            reason: format!("stdin flush failed: {e}"),
            dispatched: false,
        };
    }

    // From here the worker has the request and may be actively processing this
    // image; any failure below is `dispatched: true` so we never re-run the
    // expensive eval a second time behind the user's back.
    //
    // A single deadline bounds the WHOLE exchange. Wrapping each `next_line()`
    // in its own `timeout(REQUEST_TIMEOUT, …)` would reset the clock on every
    // stray banner / non-matching frame we `continue` past, so a chattering-but-
    // wedged worker (emitting noise, never our result id) could hold the request
    // forever — defeating the guard's stated purpose. Compute it once.
    let deadline = tokio::time::Instant::now() + REQUEST_TIMEOUT;
    loop {
        if cancel_flag.load(Ordering::SeqCst) {
            return Converse::Cancelled;
        }
        let line = match tokio::time::timeout_at(deadline, worker.stdout.next_line()).await {
            Err(_) => {
                return Converse::Broken {
                    reason: "request timed out".into(),
                    dispatched: true,
                }
            }
            Ok(Ok(Some(l))) => l,
            Ok(Ok(None)) => {
                return Converse::Broken {
                    reason: "worker closed stdout (EOF)".into(),
                    dispatched: true,
                }
            }
            Ok(Err(e)) => {
                return Converse::Broken {
                    reason: format!("stdout read failed: {e}"),
                    dispatched: true,
                }
            }
        };
        let trimmed = line.trim();
        if trimmed.is_empty() {
            continue;
        }
        // Each frame is one JSON object: ready|result|error. We only act on
        // frames whose id matches this request; stray frames are ignored.
        let frame: serde_json::Value = match serde_json::from_str(trimmed) {
            Ok(v) => v,
            Err(_) => {
                // A non-JSON line on stdout should not happen in serve mode, but
                // torch/numpy/cellpose (or an imported plugin) occasionally
                // prints a warning or banner. Treating that as a fatal worker
                // failure would surface a scary "worker stopped responding"
                // error even though detection is still proceeding. Resync by
                // skipping the stray line and reading the next frame — mirroring
                // how one-shot mode tolerates stdout noise.
                eprintln!(
                    "[sidecar] skipping non-JSON worker stdout line: {}",
                    trimmed.chars().take(200).collect::<String>()
                );
                continue;
            }
        };
        let ftype = frame.get("type").and_then(|v| v.as_str()).unwrap_or("");
        match ftype {
            "ready" => {
                // A late duplicate ready (shouldn't happen post-handshake); skip.
                continue;
            }
            "result" => {
                if frame.get("id").and_then(|v| v.as_u64()) != Some(req_id) {
                    continue; // not ours
                }
                let payload = match frame.get("payload") {
                    Some(p) => p.clone(),
                    None => {
                        return Converse::Broken {
                            reason: "result frame missing payload".into(),
                            dispatched: true,
                        }
                    }
                };
                match serde_json::from_value::<SidecarPayload>(payload) {
                    Ok(pl) => return Converse::Result(pl),
                    Err(e) => {
                        return Converse::Broken {
                            reason: format!("payload decode failed: {e}"),
                            dispatched: true,
                        }
                    }
                }
            }
            "error" => {
                if frame.get("id").and_then(|v| v.as_u64()) != Some(req_id) {
                    continue; // not ours
                }
                let error = frame
                    .get("error")
                    .and_then(|v| v.as_str())
                    .unwrap_or("detect-failed")
                    .to_string();
                let hint = frame
                    .get("hint")
                    .and_then(|v| v.as_str())
                    .map(|s| s.to_string());
                return Converse::SidecarError { error, hint };
            }
            _ => continue, // unknown frame type — ignore defensively
        }
    }
}

/// Outcome of acquiring a worker: either a fatal spawn/ready failure (fall back
/// to one-shot) or a cancel that arrived during the cold-start window.
enum SpawnOutcome {
    Failed(String),
    SidecarError(DetectionErrorDto),
    Cancelled,
}

/// Pop an idle worker matching `sig` from the pool, or spawn a fresh one and
/// await its `ready` handshake. Either way the returned worker's stderr pump is
/// already pointed at `initial_active`. The spawn path watches `cancel_flag` /
/// `cancel_notify` so a cancel arriving during the (up to READY_TIMEOUT) cold
/// start aborts the spawn instead of being dropped.
#[allow(clippy::too_many_arguments)]
async fn take_or_spawn_worker(
    app: &AppHandle,
    python: &std::path::Path,
    script: &std::path::Path,
    store: &FileStore,
    params: &DetectionParams,
    sig: &str,
    initial_active: &ActiveRun,
    cancel_flag: &Arc<AtomicBool>,
    cancel_notify: &Arc<Notify>,
) -> Result<Worker, SpawnOutcome> {
    // Fast path: reuse an idle warm worker. Point its pump at this run before
    // handing it back (a reused worker prints no cold-start lines, but any stray
    // stderr should still be attributed to the current run).
    {
        let mgr = app.state::<SidecarManager>();
        let mut pool = mgr.pool.lock().await;
        let idle = pool.get_mut(sig).and_then(|bucket| bucket.pop());
        pool.retain(|_, bucket| !bucket.is_empty());
        if let Some(worker) = idle {
            drop(pool);
            *worker.active.lock().await = Some(initial_active.clone());
            return Ok(worker);
        }
    }
    // Slow path: spawn a new one and await ready. `params` carries the
    // model-determining args; its signature is asserted to equal `sig`.
    debug_assert_eq!(&config_signature(params), sig);
    spawn_worker(
        app,
        python,
        script,
        store,
        params,
        initial_active,
        cancel_flag,
        cancel_notify,
    )
    .await
}

/// Spawn `cellpose_detect.py --serve …`, wire its pipes, start the stderr pump
/// (attached to `initial_active` so cold-start lines route to the first run),
/// and block until it prints `{"type":"ready"}` (or [`READY_TIMEOUT`] elapses).
/// The worker's signature is derived from `params` (only model-determining args
/// reach the serve argv).
#[allow(clippy::too_many_arguments)]
async fn spawn_worker(
    app: &AppHandle,
    python: &std::path::Path,
    script: &std::path::Path,
    store: &FileStore,
    params: &DetectionParams,
    initial_active: &ActiveRun,
    cancel_flag: &Arc<AtomicBool>,
    cancel_notify: &Arc<Notify>,
) -> Result<Worker, SpawnOutcome> {
    let sig = config_signature(params);
    let argv = build_serve_argv(script, params);

    let mut cmd = Command::new(python);
    cmd.args(&argv)
        .current_dir(store.python_dir())
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .kill_on_drop(true);
    crate::proc::hide_console_tokio(&mut cmd);

    // If a cancel already landed before we even spawn, don't start the process.
    if cancel_flag.load(Ordering::SeqCst) {
        return Err(SpawnOutcome::Cancelled);
    }

    let mut child: Child = cmd
        .spawn()
        .map_err(|e| SpawnOutcome::Failed(format!("failed to spawn serve worker: {e}")))?;

    let stdin = child
        .stdin
        .take()
        .ok_or_else(|| SpawnOutcome::Failed("serve worker has no stdin".to_string()))?;
    let stdout = child
        .stdout
        .take()
        .ok_or_else(|| SpawnOutcome::Failed("serve worker has no stdout".to_string()))?;
    let stderr = child.stderr.take();

    let mut stdout_lines = BufReader::new(stdout).lines();
    // Start the pump ALREADY attached to the first run so the cold-start
    // `using device:` / stage lines printed during model build (before `ready`)
    // are forwarded to that run instead of dropped.
    let active: Arc<Mutex<Option<ActiveRun>>> = Arc::new(Mutex::new(Some(initial_active.clone())));

    // Start the stderr pump: routes lines to whatever run is active. Lives for
    // the worker's lifetime, ends on stderr EOF (worker exit).
    if let Some(stderr) = stderr {
        let app = app.clone();
        let active = active.clone();
        tokio::spawn(async move {
            pump_worker_stderr(app, active, stderr).await;
        });
    }

    // Cellpose-SAM's first `CellposeModel` construction may cold-download
    // ~1.15 GB of weights when the install-time prefetch was skipped or the
    // cache evicted, so that family gets a much larger ready bound; every other
    // model cold-starts on import + model-build only, which 120 s covers.
    let ready_timeout = if is_cellpose_sam(&params.model_id) {
        READY_TIMEOUT_SAM
    } else {
        READY_TIMEOUT
    };

    // Block on the ready handshake, but also race a cancel: this is the up-to-
    // `ready_timeout` cold-start window (torch import + model build, plus a
    // possible SAM weight download) during which a user's Cancel would otherwise
    // be dropped. If `cancel_notify` fires (or the flag is already set), return
    // `Cancelled`; dropping `child` here reaps the half-started process via
    // `kill_on_drop`. The pump above is already forwarding any stderr the worker
    // prints during import/model-build.
    let ready_line = tokio::select! {
        biased;
        _ = cancel_notify.notified() => return Err(SpawnOutcome::Cancelled),
        res = tokio::time::timeout(ready_timeout, stdout_lines.next_line()) => match res {
            Err(_) => {
                return Err(SpawnOutcome::Failed(format!(
                    "worker did not emit ready within {:?}",
                    ready_timeout
                )))
            }
            Ok(Ok(Some(l))) => l,
            Ok(Ok(None)) => return Err(SpawnOutcome::Failed("worker exited before ready".into())),
            Ok(Err(e)) => return Err(SpawnOutcome::Failed(format!("reading ready failed: {e}"))),
        },
    };
    // A cancel may have raced in just as `ready` arrived; honour it so we don't
    // hand back a worker for a run the user already abandoned.
    if cancel_flag.load(Ordering::SeqCst) {
        return Err(SpawnOutcome::Cancelled);
    }
    let trimmed = ready_line.trim();
    // A structured model/download failure is already conclusive. Do not hide
    // it behind a second one-shot download; expose its recovery hint at once.
    if let Ok(error) = serde_json::from_str::<SidecarError>(trimmed) {
        return Err(SpawnOutcome::SidecarError(
            DetectionErrorDto::SidecarFailed {
                exit_code: 4,
                stderr: error
                    .hint
                    .map(|hint| format!("{}: {hint}", error.error))
                    .unwrap_or(error.error),
            },
        ));
    }
    let ok = serde_json::from_str::<serde_json::Value>(trimmed)
        .ok()
        .and_then(|v| v.get("type").and_then(|t| t.as_str()).map(|s| s == "ready"))
        .unwrap_or(false);
    if !ok {
        return Err(SpawnOutcome::Failed(format!(
            "expected ready frame, got: {}",
            trimmed.chars().take(200).collect::<String>()
        )));
    }

    Ok(Worker {
        config_sig: sig,
        child: Arc::new(Mutex::new(child)),
        stdin,
        stdout: stdout_lines,
        active,
        next_req_id: 0,
    })
}

/// Continuously forward a worker's stderr lines to the active run's progress
/// event. Splits on `\n`/`\r` like the one-shot pump. When no run is active the
/// line is dropped (idle chatter between requests is not attributable to a run).
async fn pump_worker_stderr(
    app: AppHandle,
    active: Arc<Mutex<Option<ActiveRun>>>,
    stderr: tokio::process::ChildStderr,
) {
    let mut reader = BufReader::new(stderr);
    let mut buf: Vec<u8> = Vec::new();
    let mut byte = [0u8; 1];
    loop {
        match reader.read(&mut byte).await {
            Ok(0) => break, // EOF — worker gone
            Ok(_) => {
                let b = byte[0];
                if b == b'\n' || b == b'\r' {
                    emit_worker_stderr_line(&app, &active, &buf).await;
                    buf.clear();
                } else {
                    buf.push(b);
                }
            }
            Err(_) => break,
        }
    }
    if !buf.is_empty() {
        emit_worker_stderr_line(&app, &active, &buf).await;
    }
}

/// Emit one trimmed stderr line under the currently-active run (if any).
async fn emit_worker_stderr_line(
    app: &AppHandle,
    active: &Arc<Mutex<Option<ActiveRun>>>,
    raw: &[u8],
) {
    let text = String::from_utf8_lossy(raw);
    let line = text.trim();
    if line.is_empty() {
        return;
    }
    let current = { active.lock().await.clone() };
    if let Some(run) = current {
        if let Some(progress) = parse_progress_line(&run.run_id, line) {
            let _ = app.emit(&run.event_name, progress);
        }
    }
}

/// Return a healthy worker to its pool bucket if there is room; otherwise drop
/// it (which, via `kill_on_drop`, terminates the process).
async fn return_worker_to_pool(app: &AppHandle, worker: Worker) {
    let cap = pool_capacity();
    let manager = app.state::<SidecarManager>();
    let mut evicted = Vec::new();
    {
        let mut pool = manager.pool.lock().await;
        pool.retain(|_, bucket| !bucket.is_empty());
        // Prefer the most recently requested model and evict old runtime keys.
        let stale: Vec<String> = pool
            .keys()
            .filter(|key| *key != &worker.config_sig)
            .cloned()
            .collect();
        for key in stale {
            if let Some(bucket) = pool.remove(&key) {
                evicted.extend(bucket);
            }
        }
        let bucket = pool.entry(worker.config_sig.clone()).or_default();
        if bucket.len() < cap {
            bucket.push(worker);
        } else {
            evicted.push(worker);
        }
    }
    // Process termination never holds the pool lock.
    for worker in evicted {
        kill_worker(&worker).await;
    }
}

/// Kill a worker's child immediately (cross-platform TerminateProcess/SIGKILL).
/// Used on cancel or when a worker is deemed broken. The worker is not returned
/// to the pool afterward.
async fn kill_worker(worker: &Worker) {
    let mut child = worker.child.lock().await;
    let _ = child.start_kill();
}

/// Remove a run from the cancel registry.
async fn deregister_run(app: &AppHandle, run_id: &str) {
    let mgr = app.state::<SidecarManager>();
    let mut running = mgr.running.lock().await;
    running.remove(run_id);
}

// ===========================================================================
// One-shot fallback path (the original per-image spawn)
// ===========================================================================

/// The original one-shot detection: spawn `cellpose_detect.py --image …`, stream
/// stderr progress, drain the single stdout JSON, map exit codes. Kept intact as
/// the fallback when the warm-worker path is unavailable, so detection never
/// fully breaks.
async fn run_one_shot(
    app: &AppHandle,
    python: &std::path::Path,
    script: &std::path::Path,
    store: &FileStore,
    image_path: &str,
    params: &DetectionParams,
    run_id: &str,
) -> Result<DetectionResultDto, DetectionErrorDto> {
    let argv = build_argv(script, image_path, params);

    // Spawn: cwd = python dir so `sys.path.insert(0, dirname(__file__))` finds
    // the `_cellpose_common` sibling modules.
    let mut cmd = Command::new(python);
    cmd.args(&argv)
        .current_dir(store.python_dir())
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .kill_on_drop(true);
    if is_stardist(&params.model_id) {
        // Keep pretrained weights inside CellCounter's own local model store;
        // do not scatter them through the user's global Keras cache.
        cmd.env("KERAS_HOME", store.models_dir().join("keras"))
            .env("TF_CPP_MIN_LOG_LEVEL", "2");
    }
    crate::proc::hide_console_tokio(&mut cmd);

    let cancel_flag = params
        .runtime_cancel_flag
        .clone()
        .unwrap_or_else(|| Arc::new(AtomicBool::new(false)));
    let cancel_notify = params
        .runtime_cancel_notify
        .clone()
        .unwrap_or_else(|| Arc::new(Notify::new()));

    // Register the run so cancel_detection can signal this child. The one-shot
    // body owns the `Child` and `select!`s on `cancel_notify` to kill it.
    register_run(
        app,
        run_id,
        RunHandle {
            cancel_flag: cancel_flag.clone(),
            kill: KillHandle::OneShot(cancel_notify.clone()),
        },
    )
    .await;

    if cancel_flag.load(Ordering::SeqCst) {
        deregister_run(app, run_id).await;
        return Err(DetectionErrorDto::Cancelled);
    }
    let mut child: Child = match cmd.spawn() {
        Ok(child) => child,
        Err(error) => {
            deregister_run(app, run_id).await;
            return Err(DetectionErrorDto::SidecarFailed {
                exit_code: -1,
                stderr: format!("failed to spawn sidecar: {error}"),
            });
        }
    };

    // Take the pipes out; the `Child` stays owned by this function so its
    // `wait()` needs no shared lock. Cancel reaches us via a `Notify` instead.
    let stderr = child.stderr.take();
    let stdout = child.stdout.take();

    // --- stderr: stream line-by-line as progress events ---
    let event_name = progress_event_name(run_id);
    let stderr_task = {
        let app = app.clone();
        let run_id = run_id.to_string();
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
    let stdout_task = tokio::spawn(async move {
        let mut out = Vec::new();
        if let Some(mut stdout) = stdout {
            let _ = stdout.read_to_end(&mut out).await;
        }
        out
    });

    // Wait for exit, racing a cancel. On cancel we `start_kill()` locally
    // (cross-platform TerminateProcess/SIGKILL) and then reap. Owning the child
    // here means cancel never contends for a lock held across `wait()`.
    //
    // `child.wait()` is written INLINE as a `select!` branch so tokio pins it on
    // the macro's stack and drops it when the macro returns — releasing its
    // `&mut child` borrow before we (possibly) call `child.start_kill()` after
    // the select. Only this one branch borrows `child`; the cancel branch
    // borrows `cancel_notify`, so there is no double mutable borrow inside the
    // select.
    let mut exited: Option<std::io::Result<std::process::ExitStatus>> = None;
    let cancelled_wait = tokio::select! {
        biased;
        _ = cancel_notify.notified() => true,          // cancelled: reap below
        s = child.wait() => { exited = Some(s); false } // exited on its own
    };
    let status = if cancelled_wait {
        let _ = child.start_kill();
        child.wait().await
    } else {
        // Safe: the `false` arm always sets `exited` before the select returns.
        exited.expect("wait branch sets exited")
    };
    let stdout_bytes = stdout_task.await.unwrap_or_default();
    let stderr_text = stderr_task.await.unwrap_or_default();

    // Deregister the run.
    deregister_run(app, run_id).await;

    let was_cancelled = cancel_flag.load(Ordering::SeqCst);

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
// COMMAND: cancel_detection  (cross-platform Child::start_kill())
// ===========================================================================

#[tauri::command]
pub async fn cancel_detection(app: AppHandle, run_id: String) -> Result<(), String> {
    uuid::Uuid::parse_str(&run_id).map_err(|_| "Detection cancellation ID must be a UUID")?;
    // Snapshot the kill handle under the registry lock, then release it before
    // doing the actual kill so we never hold the registry mutex across a kill.
    let kill = {
        let mgr = app.state::<SidecarManager>();
        let running = mgr.running.lock().await;
        match running.get(&run_id) {
            Some(handle) => {
                handle.cancel_flag.store(true, Ordering::SeqCst);
                handle.kill.clone()
            }
            None => {
                let mut early = mgr.early_cancelled.lock().await;
                early.retain(|_, time| time.elapsed() < Duration::from_secs(120));
                if early.len() >= 256 {
                    if let Some(oldest) = early
                        .iter()
                        .min_by_key(|(_, time)| **time)
                        .map(|(key, _)| key.clone())
                    {
                        early.remove(&oldest);
                    }
                }
                early.insert(run_id.clone(), Instant::now());
                return Ok(());
            }
        }
    };
    // Cross-platform terminate: TerminateProcess on Windows, SIGKILL on Unix.
    // No pid, so no reuse race.
    match kill {
        KillHandle::Worker(child) => {
            // `converse` never locks this mutex, so the lock is uncontended and
            // the kill is immediate; the worker's stdout then hits EOF and its
            // read loop unwinds to `Cancelled`.
            let mut guard = child.lock().await;
            let _ = guard.start_kill();
        }
        KillHandle::OneShot(notify) => {
            // Wake the one-shot body's `select!`, which kills + reaps its own
            // child locally. `notify_one()` (NOT `notify_waiters()`) stores a
            // permit if the body has not parked on `notified()` yet, so a cancel
            // that races ahead of the `select!` is not lost — the body consumes
            // the permit the instant it awaits.
            notify.notify_one();
        }
    }
    Ok(())
}

// ===========================================================================
// COMMAND: detection_availability
// ===========================================================================

/// Is `model_id` runnable right now? The model-appropriate venv is present + the
/// staged detect script exists + `import cellpose` works. We probe by spawning
/// `python -c "import cellpose"` (fast; the interpreter is warm after install)
/// so a half-built venv reads as unavailable. Per the frozen contract, `cpsam`
/// routes to the isolated `.venv4` + `cellpose4_detect.py` and the probe
/// additionally asserts cellpose major >= 4; every other model uses the base
/// `.venv` + `cellpose_detect.py`. Invoked from JS as
/// `invoke("detection_availability", { modelId })`.
#[tauri::command]
pub async fn detection_availability(
    app: AppHandle,
    db: State<'_, Db>,
    mut model_id: String,
) -> Result<Availability, String> {
    let store = FileStore::from_app(&app)?;
    let custom_requested = model_id.starts_with("custom-");
    if custom_requested {
        let model = {
            let conn = db.connection()?;
            match crate::parity::custom_model(&conn, &store, &model_id) {
                Ok(model) => model,
                Err(reason) => {
                    return Ok(Availability {
                        installed: false,
                        reason: Some(reason),
                    })
                }
            }
        };
        model_id = if model["kind"] == "stardist" {
            "sd-fluo"
        } else {
            "cp-cyto3"
        }
        .into();
    } else if model_id.starts_with("cp-cyto3@") {
        if let Err(reason) = resolve_derived_checkpoint(&db, &store, &model_id) {
            return Ok(Availability {
                installed: false,
                reason: Some(reason),
            });
        }
        model_id = "cp-cyto3".to_string();
    }
    let cpsam = is_cellpose_sam(&model_id);
    let stardist = is_stardist(&model_id);

    if !is_supported_model(&model_id) {
        return Ok(Availability {
            installed: false,
            reason: Some(format!(
                "Unsupported model id `{model_id}`. Choose a model from the Windows catalogue."
            )),
        });
    }

    if let Err(reason) = crate::env::uv::stage_python_project(&app, &store) {
        return Ok(Availability {
            installed: false,
            reason: Some(reason),
        });
    }

    // Route to the model-appropriate venv python, staged detect script, and
    // import probe (the cpsam probe asserts cellpose >= 4).
    let (python, script, probe) = if cpsam {
        (
            store.venv4_python(),
            store.python_script("cellpose4_detect.py"),
            CELLPOSE4_IMPORT_PROBE,
        )
    } else if stardist {
        (
            store.venv_stardist_python(),
            store.python_script("stardist_detect.py"),
            "import stardist, csbdeep, tensorflow",
        )
    } else if is_omnipose(&model_id) {
        (
            store.venv_omni_python(),
            store.python_script("omnipose_detect.py"),
            "import cellpose_omni, omnipose",
        )
    } else if is_classical(&model_id) {
        (
            store.venv_python(),
            store.python_script("classical_detect.py"),
            "import numpy, scipy, skimage, PIL",
        )
    } else {
        (
            store.venv_python(),
            store.python_script("cellpose_detect.py"),
            "import cellpose",
        )
    };

    if !script.exists() {
        return Ok(Availability {
            installed: false,
            reason: Some(
                "The local analysis script could not be prepared. Restart CellCounter and retry."
                    .into(),
            ),
        });
    }
    if !python.exists() {
        return Ok(Availability {
            installed: false,
            reason: Some(if cpsam {
                "Cellpose-SAM environment (venv4) is not installed.".into()
            } else if stardist {
                "StarDist environment (.venvsd) is not installed.".into()
            } else {
                "Python environment is not installed.".into()
            }),
        });
    }
    if stardist
        && !custom_requested
        && !store
            .models_dir()
            .join("keras/models")
            .join(runtime_model_name(&model_id).unwrap_or(""))
            .is_dir()
    {
        return Ok(Availability {
            installed: false,
            reason: Some(
                "StarDist fluorescence weights are missing. Reinstall sd-fluo from Models.".into(),
            ),
        });
    }

    // Probe importability.
    let mut cmd = Command::new(&python);
    cmd.args(if custom_requested || is_classical(&model_id) {
        vec!["-c".to_string(), probe.to_string()]
    } else {
        crate::env::uv::runtime_snapshot_args(&store, &model_id, true)?
    })
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
            } else if stardist {
                format!("StarDist is not importable from its isolated environment. {tail}")
            } else {
                format!("Cellpose is not importable from the environment. {tail}")
            }),
        })
    }
}

// ===========================================================================
// Orphan sweep (launch) — kill stray sidecar processes from prior sessions
// ===========================================================================

/// Kill orphaned sidecar processes left by a previous (crashed) session.
///
/// Cross-platform via the `sysinfo` crate (replaces the old Unix-only `/bin/ps`
/// scrape). We enumerate every process, and any that is running one of our owned
/// `*_detect.py` scripts **staged under THIS app's `python_dir`** — and whose
/// pid is not our own — is killed.
///
/// The scoping to `python_dir` is important: matching a bare basename
/// (`cellpose_detect.py`) against every process's argv is global to the whole
/// machine, so an unrelated process that merely mentions that filename (another
/// checkout of this project, a user's own script, an editor/terminal showing the
/// path) would be wrongly killed. By requiring the resolved script path to live
/// under our own staged python dir, only sidecars this app actually launched
/// (from that exact directory) are candidates. When `cmd()` is unavailable we
/// fall back to matching the process's `exe()` path against `python_dir` (our
/// staged venv interpreter lives under it) rather than `name()`, which is only
/// the interpreter basename and can never contain a staged script path.
///
/// Best-effort; never blocks startup — call it from a spawned thread in `setup`.
pub fn sweep_orphans(python_dir: std::path::PathBuf) {
    use sysinfo::{ProcessesToUpdate, System};

    // The set of absolute script paths this app would ever launch. Built from
    // the SAME `python_dir.join(name)` the app spawns with — deliberately NOT
    // canonicalized: the process argv we match against below is the un-resolved
    // launch path, so canonicalizing only this side (e.g. /var -> /private/var,
    // or a symlinked app-data dir) would make `contains` miss a genuine orphan.
    // The exact staged path is still specific enough to never touch an unrelated
    // process.
    let owned_paths: Vec<String> = OWNED_SCRIPTS
        .iter()
        .map(|name| python_dir.join(name).to_string_lossy().into_owned())
        .collect();

    // Fallback identifier for when `cmd()` is empty (platform/permission
    // dependent on macOS): our sidecars are launched with the staged venv
    // interpreter, which lives UNDER `python_dir` (`<python_dir>/.venv/bin/python`
    // etc.). So an orphan whose executable path is rooted at our python_dir is
    // ours even when its argv (and thus the script path) is unavailable. Matching
    // `python_dir` (not a bare interpreter basename like `python3.11`) keeps this
    // scoped to processes THIS app staged and launched.
    let python_dir_prefix = python_dir.to_string_lossy().into_owned();

    // Our own pid — never target ourselves even if argv somehow matched.
    let self_pid = std::process::id();

    // Enumerate every process once. `ProcessesToUpdate::All` refreshes the whole
    // table; `true` prunes entries for processes that have since died.
    let mut sys = System::new();
    sys.refresh_processes(ProcessesToUpdate::All, true);

    let mut killed = 0usize;
    for (pid, process) in sys.processes() {
        if pid.as_u32() == self_pid {
            continue;
        }

        // Match against the full command line (interpreter + script + args).
        // `cmd()` yields the argv vector as `&[OsString]`; join lossily so a
        // script path shows up regardless of which argv slot it lands in.
        let cmdline: String = process
            .cmd()
            .iter()
            .map(|s| s.to_string_lossy())
            .collect::<Vec<_>>()
            .join(" ");

        let is_ours = if !cmdline.is_empty() {
            // Preferred path: a match on the FULL staged script path under our
            // python_dir, so we never kill an unrelated process that happens to
            // mention the bare script basename.
            owned_paths.iter().any(|p| cmdline.contains(p.as_str()))
        } else {
            // `cmd()` is empty on this platform for this process. `name()` is only
            // the interpreter basename (e.g. `python3.11`) and can NEVER contain a
            // staged script path, so the old name()-based fallback was a no-op.
            // Instead match the process's executable path against our python_dir:
            // our sidecar's interpreter is staged under it, so an exe rooted there
            // is ours — while still being scoped to processes this app launched.
            process
                .exe()
                .map(|exe| exe.to_string_lossy().contains(python_dir_prefix.as_str()))
                .unwrap_or(false)
        };
        if !is_ours {
            continue;
        }

        // Kill it. `sysinfo::Process::kill()` sends SIGKILL on Unix and calls
        // TerminateProcess on Windows — cross-platform, no pid-reuse trickery
        // beyond what the OS gives us at this instant.
        if process.kill() {
            killed += 1;
        }
    }

    if killed > 0 {
        eprintln!("[sidecar] reaped {killed} orphan subprocess(es) from prior session");
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn params(model_id: &str) -> DetectionParams {
        DetectionParams {
            model_id: model_id.to_string(),
            classical_threshold: None,
            preprocessing_preset: None,
            checkpoint_path: None,
            runtime_identity_key: None,
            runtime_cancel_flag: None,
            runtime_cancel_notify: None,
            px_per_um: 2.6,
            confidence_threshold: 0.55,
            channels: [2, 1],
            segment_channel: None,
            z_projection: "max".to_string(),
            background_subtract: true,
            rolling_ball_radius: 42,
            watershed_split: true,
            watershed_min_distance_um: 7.6,
            small_threshold_um: 20.0,
            large_threshold_um: 30.0,
            expected_diameter_um: 24.0,
            use_gpu: false,
        }
    }

    fn value_after<'a>(args: &'a [String], flag: &str) -> Option<&'a str> {
        args.iter()
            .position(|v| v == flag)
            .and_then(|i| args.get(i + 1))
            .map(String::as_str)
    }

    #[test]
    fn source_plane_settings_reach_one_shot_and_warm_requests() {
        let mut request = params("cp-cyto3");
        request.segment_channel = Some(3);
        request.z_projection = "sum".to_string();
        for model in WINDOWS_MODEL_IDS {
            request.model_id = model.to_string();
            let args = build_argv(std::path::Path::new("detect.py"), "stack.tiff", &request);
            assert_eq!(value_after(&args, "--segment-channel"), Some("3"));
            assert_eq!(value_after(&args, "--z-project"), Some("sum"));
        }
        let frame: serde_json::Value =
            serde_json::from_str(&build_request_json(1, "stack.tiff", &request)).unwrap();
        assert_eq!(frame["segment_channel"], 3);
        assert_eq!(frame["z_project"], "sum");
        request.segment_channel = None;
        let frame: serde_json::Value =
            serde_json::from_str(&build_request_json(2, "stack.tiff", &request)).unwrap();
        assert!(frame["segment_channel"].is_null());
    }

    #[test]
    fn windows_model_allowlist_is_exact_and_ordered() {
        assert_eq!(WINDOWS_MODEL_IDS.len(), 19);
        assert_eq!(runtime_model_name("cpsam_v2"), Some("cpsam"));
        assert_eq!(runtime_model_name("cp-cyto3"), Some("cyto3"));
        assert_eq!(runtime_model_name("sd-fluo"), Some("2D_versatile_fluo"));
        for unsupported in ["cpsam", "cyto3", "", "unknown"] {
            assert_eq!(runtime_model_name(unsupported), None, "{unsupported}");
            assert!(!is_supported_model(unsupported));
        }
    }

    #[test]
    fn client_cannot_inject_a_checkpoint_or_gpu_into_windows_runtime() {
        for model_id in WINDOWS_MODEL_IDS {
            let mut request = params(model_id);
            request.checkpoint_path = Some(r"C:\untrusted\model.pt".to_string());
            request.use_gpu = true;
            enforce_windows_runtime_contract(&mut request);
            let args = build_argv(std::path::Path::new("detect.py"), "image.tif", &request);
            assert!(!args.iter().any(|value| value == "--checkpoint"));
            if model_id != "sd-fluo" {
                assert!(args.iter().any(|value| value == "--no-gpu"));
            }
            assert!(!request.use_gpu);
        }
    }

    #[test]
    fn backend_checkpoint_is_part_of_worker_identity_and_argv() {
        let mut request = params("cp-cyto3");
        request.checkpoint_path = Some(r"C:\CellCounter\Models\v1.ccmodel".to_string());
        let args = build_serve_argv(std::path::Path::new("detect.py"), &request);
        assert_eq!(
            value_after(&args, "--checkpoint"),
            Some(r"C:\CellCounter\Models\v1.ccmodel")
        );
        assert!(config_signature(&request).contains("v1.ccmodel"));
    }

    #[test]
    fn cellpose_argv_maps_exact_checkpoint_and_preserves_controls() {
        let args = build_argv(
            std::path::Path::new("detect.py"),
            r"C:\data\cell 1.tif",
            &params("cp-cyto3"),
        );
        assert_eq!(value_after(&args, "--model"), Some("cyto3"));
        assert_eq!(value_after(&args, "--image"), Some(r"C:\data\cell 1.tif"));
        assert_eq!(value_after(&args, "--channels"), Some("2,1"));
        assert_eq!(value_after(&args, "--diameter"), Some("24"));
        assert_eq!(value_after(&args, "--watershed-min-distance"), Some("8"));
        assert!(args.iter().any(|v| v == "--no-gpu"));
    }

    #[test]
    fn cpsam_v2_maps_only_to_cpsam_checkpoint() {
        let args = build_serve_argv(
            std::path::Path::new("cellpose4_detect.py"),
            &params("cpsam_v2"),
        );
        assert_eq!(value_after(&args, "--model"), Some("cpsam"));
        assert!(is_cellpose_sam("cpsam_v2"));
        assert!(!is_cellpose_sam("cpsam"));
    }

    #[test]
    fn stardist_argv_never_receives_cellpose_only_flags() {
        let args = build_argv(
            std::path::Path::new("stardist_detect.py"),
            r"D:\images\nuclei.tif",
            &params("sd-fluo"),
        );
        assert_eq!(value_after(&args, "--model"), Some("2D_versatile_fluo"));
        for forbidden in ["--channels", "--diameter", "--no-gpu"] {
            assert!(!args.iter().any(|v| v == forbidden), "{forbidden}");
        }
        assert!(args.iter().any(|v| v == "--bg-subtract"));
        assert!(args.iter().any(|v| v == "--watershed"));
    }

    #[test]
    fn progress_parser_filters_bars_and_extracts_device() {
        assert!(parse_progress_line("run", "10%|██| 1/10").is_none());
        match parse_progress_line("run", "[cellpose_detect] using device: cuda:0 (torch)") {
            Some(DetectionProgress::Device { run_id, device }) => {
                assert_eq!(run_id, "run");
                assert_eq!(device, "CUDA:0");
            }
            other => panic!("unexpected progress: {other:?}"),
        }
    }
}
