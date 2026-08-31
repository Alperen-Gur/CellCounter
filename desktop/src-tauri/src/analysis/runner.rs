//! Restricted launcher for portable assay sidecars.

use std::collections::HashMap;
use std::path::PathBuf;
use std::process::Stdio;
use std::sync::Mutex;
use std::time::Duration;

use serde::Serialize;
use serde_json::Value;
use tauri::AppHandle;
use tauri::State;
use tokio::io::{AsyncRead, AsyncReadExt};
use tokio::process::Command;
use tokio::sync::oneshot;
use uuid::Uuid;

use crate::db::repo::Db;
use crate::export::provenance::{open_reader, ExportContext};
use crate::paths::FileStore;

const MAX_ARG_COUNT: usize = 96;
const MAX_ARG_BYTES: usize = 32_768;
const MAX_PAYLOAD_BYTES: usize = 64 * 1024 * 1024;
const MAX_OUTPUT_BYTES: usize = 64 * 1024 * 1024;
const ASSAY_TIMEOUT: Duration = Duration::from_secs(20 * 60);
const MAX_LINE_PROFILE_PIXELS: u64 = 100_000_000;

#[derive(Default)]
pub struct AssayManager {
    // `None` means cancellation was already requested but the exact child has
    // not finished reaping yet. Keep the key until completion so a reused run
    // id cannot replace the old entry or be cleared by the old task.
    active: Mutex<HashMap<String, Option<oneshot::Sender<()>>>>,
}

struct StagedPayload(Option<PathBuf>);

impl Drop for StagedPayload {
    fn drop(&mut self) {
        if let Some(path) = self.0.as_ref() {
            let _ = std::fs::remove_file(path);
        }
    }
}

async fn read_bounded<R>(mut reader: R) -> Result<Vec<u8>, String>
where
    R: AsyncRead + Unpin,
{
    let mut kept = Vec::new();
    let mut buffer = [0_u8; 16 * 1024];
    let mut exceeded = false;
    loop {
        let read = reader
            .read(&mut buffer)
            .await
            .map_err(|error| format!("could not read assay output: {error}"))?;
        if read == 0 {
            break;
        }
        let remaining = MAX_OUTPUT_BYTES.saturating_add(1).saturating_sub(kept.len());
        if remaining > 0 {
            kept.extend_from_slice(&buffer[..read.min(remaining)]);
        }
        exceeded |= kept.len() > MAX_OUTPUT_BYTES || read > remaining;
    }
    if exceeded {
        Err("assay output exceeded the 64 MiB safety limit".to_string())
    } else {
        Ok(kept)
    }
}

fn clear_active(manager: &AssayManager, run_id: &str) {
    if let Ok(mut active) = manager.active.lock() {
        active.remove(run_id);
    }
}

struct AssaySpec {
    script: &'static str,
    payload_flag: Option<&'static str>,
}

fn assay_spec(kind: &str) -> Option<AssaySpec> {
    match kind {
        "intensity" => Some(AssaySpec {
            script: "intensity_assays.py",
            payload_flag: Some("--detection-json"),
        }),
        "area" => Some(AssaySpec {
            script: "area_assays_detect.py",
            payload_flag: None,
        }),
        "puncta" => Some(AssaySpec {
            script: "puncta_detect.py",
            payload_flag: Some("--cells-json"),
        }),
        "tracking" => Some(AssaySpec {
            script: "track_cells.py",
            payload_flag: Some("--input"),
        }),
        "neurite" => Some(AssaySpec {
            script: "neurite_outgrowth.py",
            payload_flag: Some("--soma-centroids"),
        }),
        _ => None,
    }
}

fn assay_python(store: &FileStore) -> Option<PathBuf> {
    [
        store.venv_python(),
        store.venv4_python(),
        store.venv_stardist_python(),
    ]
    .into_iter()
    .find(|path| path.exists())
}

fn assay_flag_takes_value(kind: &str, flag: &str) -> Option<bool> {
    let allowed: &[(&str, bool)] = match kind {
        "intensity" => &[
            ("--image", true), ("--assay", true), ("--per-cell", false),
            ("--channel", true), ("--threshold-mode", true),
            ("--channel-a", true), ("--channel-b", true),
            ("--live-channel", true), ("--dead-channel", true),
            ("--nuclear-channel", true), ("--dna-channel", true),
        ],
        "area" => &[("--mode", true), ("--pxPerUm", true), ("--image", true)],
        "puncta" => &[
            ("--image", true), ("--channel", true), ("--pxPerUm", true),
            ("--threshold", true),
        ],
        "tracking" => &[
            ("--px-per-um", true), ("--frame-interval-min", true),
            ("--max-displacement-um", true),
        ],
        "neurite" => &[
            ("--neurite-mask", true), ("--px-per-um", true),
            ("--soma-radius-um", true),
        ],
        _ => &[],
    };
    allowed.iter().find_map(|(candidate, takes_value)| {
        (*candidate == flag).then_some(*takes_value)
    })
}

fn validate_args(kind: &str, args: &[String], reserved: Option<&str>) -> Result<(), String> {
    if args.len() > MAX_ARG_COUNT {
        return Err(format!("too many assay arguments (maximum {MAX_ARG_COUNT})"));
    }
    for arg in args {
        if arg.len() > MAX_ARG_BYTES || arg.contains('\0') {
            return Err("an assay argument is too large or contains a null byte".to_string());
        }
        if reserved.is_some_and(|flag| arg == flag) {
            return Err(format!("{arg} is managed by CellCounter and cannot be overridden"));
        }
    }
    let mut index = 0;
    while index < args.len() {
        let flag = &args[index];
        let takes_value = assay_flag_takes_value(kind, flag)
            .ok_or_else(|| format!("{flag} is not an allowed option for the {kind} assay"))?;
        index += 1;
        if takes_value {
            if index >= args.len() {
                return Err(format!("{flag} requires a value"));
            }
            index += 1;
        }
    }
    Ok(())
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct AssayAvailability {
    available: bool,
    reason: Option<String>,
}

#[derive(Serialize, Debug)]
#[serde(rename_all = "camelCase")]
pub struct LineProfilePoint {
    distance_px: f64,
    distance_um: f64,
    value: f64,
}

fn pixel_rgb(image: &image::DynamicImage, x: u32, y: u32) -> [f64; 3] {
    match image {
        image::DynamicImage::ImageLuma8(buffer) => {
            let value = buffer.get_pixel(x, y).0[0] as f64 / u8::MAX as f64;
            [value; 3]
        }
        image::DynamicImage::ImageLumaA8(buffer) => {
            let value = buffer.get_pixel(x, y).0[0] as f64 / u8::MAX as f64;
            [value; 3]
        }
        image::DynamicImage::ImageRgb8(buffer) => buffer.get_pixel(x, y).0.map(|v| v as f64 / u8::MAX as f64),
        image::DynamicImage::ImageRgba8(buffer) => {
            let p = buffer.get_pixel(x, y).0;
            [p[0], p[1], p[2]].map(|v| v as f64 / u8::MAX as f64)
        }
        image::DynamicImage::ImageLuma16(buffer) => {
            let value = buffer.get_pixel(x, y).0[0] as f64 / u16::MAX as f64;
            [value; 3]
        }
        image::DynamicImage::ImageLumaA16(buffer) => {
            let value = buffer.get_pixel(x, y).0[0] as f64 / u16::MAX as f64;
            [value; 3]
        }
        image::DynamicImage::ImageRgb16(buffer) => buffer.get_pixel(x, y).0.map(|v| v as f64 / u16::MAX as f64),
        image::DynamicImage::ImageRgba16(buffer) => {
            let p = buffer.get_pixel(x, y).0;
            [p[0], p[1], p[2]].map(|v| v as f64 / u16::MAX as f64)
        }
        image::DynamicImage::ImageRgb32F(buffer) => buffer.get_pixel(x, y).0.map(f64::from),
        image::DynamicImage::ImageRgba32F(buffer) => {
            let p = buffer.get_pixel(x, y).0;
            [p[0], p[1], p[2]].map(f64::from)
        }
        _ => [0.0; 3],
    }
}

fn bilinear_channel(
    image: &image::DynamicImage,
    x: f64,
    y: f64,
    channel: &str,
) -> f64 {
    let x = x.clamp(0.0, image.width().saturating_sub(1) as f64);
    let y = y.clamp(0.0, image.height().saturating_sub(1) as f64);
    let x0 = x.floor() as u32;
    let y0 = y.floor() as u32;
    let x1 = (x0 + 1).min(image.width() - 1);
    let y1 = (y0 + 1).min(image.height() - 1);
    let tx = x - x0 as f64;
    let ty = y - y0 as f64;
    let sample = |sx: u32, sy: u32| -> f64 {
        let pixel = pixel_rgb(image, sx, sy);
        match channel {
            "red" => pixel[0] as f64,
            "green" => pixel[1] as f64,
            "blue" => pixel[2] as f64,
            _ => 0.2126 * pixel[0] as f64 + 0.7152 * pixel[1] as f64 + 0.0722 * pixel[2] as f64,
        }
    };
    let top = sample(x0, y0) * (1.0 - tx) + sample(x1, y0) * tx;
    let bottom = sample(x0, y1) * (1.0 - tx) + sample(x1, y1) * tx;
    top * (1.0 - ty) + bottom * ty
}

fn validate_line_image_dimensions(width: u32, height: u32) -> Result<(), String> {
    let pixels = u64::from(width)
        .checked_mul(u64::from(height))
        .ok_or_else(|| "line-profile image dimensions overflow".to_string())?;
    if width == 0 || height == 0 || pixels > MAX_LINE_PROFILE_PIXELS {
        return Err(format!(
            "line-profile source is too large ({width}×{height}); use a cropped image below 100 megapixels"
        ));
    }
    Ok(())
}

fn calculate_line_profile(
    image: &image::DynamicImage,
    start: [f64; 2],
    end: [f64; 2],
    px_per_um: f64,
    channel: &str,
    requested_samples: Option<usize>,
) -> Result<Vec<LineProfilePoint>, String> {
    if !matches!(channel, "luma" | "red" | "green" | "blue") {
        return Err(format!("unsupported line-profile channel: {channel}"));
    }
    if !(px_per_um > 0.0) || !px_per_um.is_finite() {
        return Err("pxPerUm must be a positive finite number".to_string());
    }
    if start.into_iter().chain(end).any(|value| !value.is_finite()) {
        return Err("line-profile coordinates must be finite".to_string());
    }
    let dx = end[0] - start[0];
    let dy = end[1] - start[1];
    let length = (dx * dx + dy * dy).sqrt();
    if length < 1e-6 {
        return Err("choose two different points for the line profile".to_string());
    }
    let samples = requested_samples
        .unwrap_or_else(|| length.ceil() as usize + 1)
        .clamp(2, 10_000);
    Ok((0..samples)
        .map(|index| {
            let fraction = index as f64 / (samples - 1) as f64;
            let distance_px = length * fraction;
            LineProfilePoint {
                distance_px,
                distance_um: distance_px / px_per_um,
                value: bilinear_channel(
                    image,
                    start[0] + dx * fraction,
                    start[1] + dy * fraction,
                    channel,
                ),
            }
        })
        .collect())
}

#[tauri::command]
#[allow(clippy::too_many_arguments)]
pub async fn line_profile(
    app: AppHandle,
    db: State<'_, Db>,
    image_id: String,
    start_x: f64,
    start_y: f64,
    end_x: f64,
    end_y: f64,
    px_per_um: f64,
    channel: String,
    samples: Option<usize>,
) -> Result<Vec<LineProfilePoint>, String> {
    let store = FileStore::from_app(&app)?;
    let conn = open_reader(&store)?;
    let context = ExportContext::load(&conn, &store, &image_id)?;
    let source_path = context.analysis_path.clone().unwrap_or(context.stored_path.clone());
    let _ = &db;
    tokio::task::spawn_blocking(move || {
        let (width, height) = image::image_dimensions(&source_path)
            .map_err(|error| format!("could not inspect source image for line profile: {error}"))?;
        validate_line_image_dimensions(width, height)?;
        let image = image::open(&source_path)
            .map_err(|error| format!("could not open source image for line profile: {error}"))?;
        calculate_line_profile(
            &image,
            [start_x, start_y],
            [end_x, end_y],
            px_per_um,
            &channel,
            samples,
        )
    })
    .await
    .map_err(|error| format!("line-profile worker failed: {error}"))?
}

#[tauri::command]
pub async fn assay_availability(app: AppHandle, kind: String) -> Result<AssayAvailability, String> {
    let spec = assay_spec(&kind).ok_or_else(|| format!("unsupported assay kind: {kind}"))?;
    let store = FileStore::from_app(&app)?;
    crate::env::uv::stage_python_project(&app, &store)?;
    let Some(python) = assay_python(&store) else {
        return Ok(AssayAvailability {
            available: false,
            reason: Some("Install one of the three built-in models to provision the local Python analysis runtime.".to_string()),
        });
    };
    if !store.python_script(spec.script).exists() {
        return Ok(AssayAvailability {
            available: false,
            reason: Some(format!("{} is not staged in the local runtime", spec.script)),
        });
    }
    let mut command = Command::new(python);
    command
        .args(["-c", "import numpy, scipy, skimage, PIL"])
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .kill_on_drop(true);
    crate::proc::hide_console_tokio(&mut command);
    let ready = tokio::time::timeout(Duration::from_secs(20), command.status())
        .await
        .ok()
        .and_then(Result::ok)
        .is_some_and(|status| status.success());
    Ok(AssayAvailability {
        available: ready,
        reason: (!ready).then_some(
            "The installed model runtime is missing numpy/scipy/scikit-image/Pillow; reinstall that model and retry."
                .to_string(),
        ),
    })
}

/// Run one allowlisted assay script. Arguments are passed directly to Python
/// without a shell; payload-backed flags are generated in app-owned storage.
#[tauri::command]
pub async fn run_assay(
    app: AppHandle,
    manager: State<'_, AssayManager>,
    kind: String,
    args: Vec<String>,
    payload_json: Option<String>,
    run_id: String,
) -> Result<Value, String> {
    Uuid::parse_str(&run_id).map_err(|_| "assay run id must be a UUID".to_string())?;
    let spec = assay_spec(&kind).ok_or_else(|| format!("unsupported assay kind: {kind}"))?;
    validate_args(&kind, &args, spec.payload_flag)?;
    if payload_json.as_ref().is_some_and(|payload| payload.len() > MAX_PAYLOAD_BYTES) {
        return Err("assay payload exceeds the 64 MiB safety limit".to_string());
    }

    let store = FileStore::from_app(&app)?;
    crate::env::uv::stage_python_project(&app, &store)?;
    let python = assay_python(&store).ok_or_else(|| {
        "No local Python analysis runtime is installed. Install one of the three built-in models first."
            .to_string()
    })?;
    let script = store.python_script(spec.script);
    if !script.exists() {
        return Err(format!("assay sidecar {} is not staged", spec.script));
    }

    let payload_path = match (spec.payload_flag, payload_json) {
        (Some(flag), Some(payload)) => {
            let path = store
                .exports_dir()
                .join(format!(".assay-{}-{}.json", kind, Uuid::new_v4()));
            let write_path = path.clone();
            let validation_kind = kind.clone();
            tokio::task::spawn_blocking(move || {
                serde_json::from_str::<Value>(&payload)
                    .map_err(|error| format!("invalid {validation_kind} payload JSON: {error}"))?;
                std::fs::write(&write_path, payload)
                    .map_err(|error| format!("could not stage {validation_kind} input: {error}"))
            })
            .await
            .map_err(|error| format!("{kind} input worker failed: {error}"))??;
            Some((flag, path))
        }
        (Some(_), None) if matches!(kind.as_str(), "tracking" | "puncta" | "intensity") => {
            return Err(format!("{kind} requires a structured detection/sequence payload"));
        }
        _ => None,
    };
    let staged_payload = StagedPayload(payload_path.as_ref().map(|(_, path)| path.clone()));

    let mut command = Command::new(&python);
    command
        .arg(&script)
        .args(&args)
        .current_dir(store.python_dir())
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .kill_on_drop(true);
    if let Some((flag, path)) = payload_path.as_ref() {
        command.arg(flag).arg(path);
    }
    crate::proc::hide_console_tokio(&mut command);
    let mut child = command
        .spawn()
        .map_err(|error| format!("could not launch {kind} assay: {error}"))?;
    let stdout = child.stdout.take().ok_or_else(|| {
        let _ = child.start_kill();
        format!("{kind} assay stdout is unavailable")
    })?;
    let stderr = child.stderr.take().ok_or_else(|| {
        let _ = child.start_kill();
        format!("{kind} assay stderr is unavailable")
    })?;
    let stdout_task = tokio::spawn(read_bounded(stdout));
    let stderr_task = tokio::spawn(read_bounded(stderr));
    let (cancel, mut cancel_rx) = oneshot::channel();
    {
        let mut active = manager
            .active
            .lock()
            .map_err(|_| "assay manager is unavailable".to_string())?;
        if active.contains_key(&run_id) {
            let _ = child.start_kill();
            return Err("an assay with this run id is already active".to_string());
        }
        active.insert(run_id.clone(), Some(cancel));
    }
    let status = tokio::select! {
        waited = tokio::time::timeout(ASSAY_TIMEOUT, child.wait()) => match waited {
            Ok(result) => result.map_err(|error| format!("could not wait for {kind} assay: {error}")),
            Err(_) => {
                let _ = child.start_kill();
                let _ = child.wait().await;
                Err(format!("{kind} assay timed out after 20 minutes"))
            }
        },
        _ = &mut cancel_rx => {
            let _ = child.start_kill();
            let _ = child.wait().await;
            Err(format!("{kind} assay was cancelled"))
        }
    };
    clear_active(&manager, &run_id);
    let stdout = stdout_task
        .await
        .map_err(|error| format!("{kind} stdout reader failed: {error}"))??;
    let stderr = stderr_task
        .await
        .map_err(|error| format!("{kind} stderr reader failed: {error}"))??;
    let status = status?;
    drop(staged_payload);
    let stdout = String::from_utf8(stdout)
        .map_err(|_| format!("{kind} assay returned non-UTF-8 output"))?;
    let stderr = String::from_utf8_lossy(&stderr);
    let parsed: Value = serde_json::from_str(stdout.trim()).map_err(|error| {
        format!(
            "could not parse {kind} assay output: {error}. Details: {}",
            stderr.chars().rev().take(1200).collect::<String>().chars().rev().collect::<String>()
        )
    })?;
    if !status.success() {
        let reason = parsed
            .get("error")
            .and_then(Value::as_str)
            .unwrap_or("assay sidecar failed");
        let hint = parsed.get("hint").and_then(Value::as_str).unwrap_or("");
        return Err(if hint.is_empty() {
            reason.to_string()
        } else {
            format!("{reason}: {hint}")
        });
    }
    Ok(parsed)
}

#[tauri::command]
pub fn cancel_assay(manager: State<'_, AssayManager>, run_id: String) -> Result<bool, String> {
    let mut active = manager
        .active
        .lock()
        .map_err(|_| "assay manager is unavailable".to_string())?;
    let cancel = active.get_mut(&run_id).and_then(Option::take);
    Ok(cancel.is_some_and(|sender| sender.send(()).is_ok()))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn assay_kind_is_closed_and_payload_flags_cannot_be_injected() {
        assert!(assay_spec("tracking").is_some());
        assert!(assay_spec("arbitrary.py").is_none());
        assert!(validate_args("tracking", &["--input".into(), "other.json".into()], Some("--input"))
            .is_err());
        assert!(validate_args("tracking", &["--px-per-um".into(), "2.6".into()], Some("--input"))
            .is_ok());
        assert!(validate_args("tracking", &["--arbitrary".into(), "value".into()], Some("--input"))
            .is_err());
    }

    #[test]
    fn line_profile_is_calibrated_and_uses_exact_endpoints() {
        let mut image = image::RgbImage::new(2, 1);
        image.put_pixel(0, 0, image::Rgb([0, 0, 0]));
        image.put_pixel(1, 0, image::Rgb([255, 255, 255]));
        let points = calculate_line_profile(
            &image::DynamicImage::ImageRgb8(image),
            [0.0, 0.0],
            [1.0, 0.0],
            2.0,
            "luma",
            Some(3),
        )
        .unwrap();
        assert_eq!(points.len(), 3);
        assert!((points[0].value - 0.0).abs() < 1e-9);
        assert!((points[1].value - 0.5).abs() < 1e-6);
        assert!((points[2].value - 1.0).abs() < 1e-9);
        assert!((points[2].distance_um - 0.5).abs() < 1e-9);
    }

    #[test]
    fn line_profile_rejects_oversized_images_before_allocation() {
        assert!(validate_line_image_dimensions(10_000, 10_000).is_ok());
        assert!(validate_line_image_dimensions(10_001, 10_000).is_err());
        assert!(validate_line_image_dimensions(u32::MAX, u32::MAX).is_err());
    }
}
