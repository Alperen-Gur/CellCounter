//! detection/ipc.rs — Rust↔Python sidecar wire structs + frontend DTOs.
//!
//! Two serde surfaces live here:
//!
//! 1. **Python sidecar wire protocol** (`SidecarPayload` / `SidecarCell` /
//!    `SidecarError`) — snake_case keys matching `cellpose_detect.py` stdout
//!    verbatim, ported 1:1 from `Detection/SidecarSchema.swift`.
//!
//! 2. **Frontend DTOs** (`DetectionParams`, `DetectionResultDto`,
//!    `DetectionErrorDto`, `Availability`) — camelCase, matching
//!    `kernel/transport/InferenceTransport.ts` (§3.1), the frozen contract.
//!
//! The boundary mapping (snake→camel, `contour_px` → `contourPx`) happens in
//! [`SidecarPayload::into_result_dto`], so `sidecar.rs` never touches raw JSON.

use serde::{Deserialize, Serialize};

use crate::db::models::CellDto;

// ===========================================================================
// 1. Python sidecar wire protocol (snake_case; = SidecarSchema.swift)
// ===========================================================================

/// Output envelope written by `cellpose_detect.py` on stdout (a single JSON
/// object). Snake-case keys match the Python verbatim.
#[derive(Debug, Deserialize)]
pub struct SidecarPayload {
    pub width: i64,
    pub height: i64,
    pub cells: Vec<SidecarCell>,
    /// Per-image stats blob (QC + colony). Optional for backward compat.
    #[serde(default)]
    pub image_stats: Option<std::collections::BTreeMap<String, f64>>,
}

/// Per-cell JSON produced by the sidecar. Optional fields are absent on manual
/// markers / legacy sidecars.
#[derive(Debug, Deserialize)]
pub struct SidecarCell {
    pub id: String,
    pub cx: f64,
    pub cy: f64,
    pub diameter_um: f64,
    pub diameter_px: f64,
    pub confidence: f64,
    #[serde(default)]
    pub area_um2: Option<f64>,
    #[serde(default)]
    pub perimeter_um: Option<f64>,
    #[serde(default)]
    pub circularity: Option<f64>,
    #[serde(default)]
    pub eccentricity: Option<f64>,
    #[serde(default)]
    pub mean_intensity: Option<f64>,
    #[serde(default)]
    pub integrated_density: Option<f64>,
    #[serde(default)]
    pub centroid_um_x: Option<f64>,
    #[serde(default)]
    pub centroid_um_y: Option<f64>,
    #[serde(default)]
    pub aspect_ratio: Option<f64>,
    #[serde(default)]
    pub solidity: Option<f64>,
    #[serde(default)]
    pub edge_touching: Option<bool>,
    #[serde(default)]
    pub likely_clump: Option<bool>,
    #[serde(default)]
    pub likely_debris: Option<bool>,
    #[serde(default)]
    pub size_class: Option<String>,
    #[serde(default)]
    pub is_manual: Option<bool>,
    /// Per-cell polygon contour `[[x, y], …]` in source-px.
    #[serde(default)]
    pub contour_px: Option<Vec<Vec<f64>>>,
}

/// Structured error a sidecar emits on a known failure (checked before decoding
/// a full payload). `{ "error": string, "hint"?: string }`.
#[derive(Debug, Deserialize)]
pub struct SidecarError {
    pub error: String,
    #[serde(default)]
    pub hint: Option<String>,
}

impl SidecarCell {
    /// Lift a wire cell into the camelCase `CellDto`. Contour pairs shorter than
    /// 2 are dropped; a contour with < 3 valid points becomes `None` (renders
    /// via bbox/circle) — mirrors the Swift decode.
    fn into_cell_dto(self) -> CellDto {
        let contour_px = self.contour_px.and_then(|pairs| {
            let pts: Vec<[f64; 2]> = pairs
                .into_iter()
                .filter_map(|p| {
                    if p.len() >= 2 {
                        Some([p[0], p[1]])
                    } else {
                        None
                    }
                })
                .collect();
            if pts.len() >= 3 {
                Some(pts)
            } else {
                None
            }
        });
        CellDto {
            id: self.id,
            cx: self.cx,
            cy: self.cy,
            diameter_um: self.diameter_um,
            diameter_px: self.diameter_px,
            confidence: self.confidence,
            area_um2: self.area_um2,
            perimeter_um: self.perimeter_um,
            circularity: self.circularity,
            eccentricity: self.eccentricity,
            mean_intensity: self.mean_intensity,
            integrated_density: self.integrated_density,
            centroid_um_x: self.centroid_um_x,
            centroid_um_y: self.centroid_um_y,
            aspect_ratio: self.aspect_ratio,
            solidity: self.solidity,
            edge_touching: self.edge_touching,
            likely_clump: self.likely_clump,
            likely_debris: self.likely_debris,
            size_class: self.size_class,
            is_manual: self.is_manual,
            contour_px,
        }
    }
}

impl SidecarPayload {
    /// Map the whole payload to the frontend `DetectionResultDto`.
    pub fn into_result_dto(self) -> DetectionResultDto {
        DetectionResultDto {
            image_width: self.width,
            image_height: self.height,
            cells: self.cells.into_iter().map(SidecarCell::into_cell_dto).collect(),
            image_stats: self.image_stats,
        }
    }
}

// ===========================================================================
// 2. Frontend DTOs (camelCase; = InferenceTransport.ts §3.1)
// ===========================================================================

/// Detection params from the UI. `#[serde(rename_all = "camelCase")]` so it
/// matches the TS `DetectionParams` field-for-field.
#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DetectionParams {
    /// v1: always "cp-cyto3". The `cp-` prefix is stripped for `--model`.
    pub model_id: String,
    pub px_per_um: f64,
    pub confidence_threshold: f64,
    /// [cyto, nuclei]; 0=gray,1=r,2=g,3=b. Default [0,0] ⇒ `--channels` omitted.
    pub channels: [i32; 2],
    pub background_subtract: bool,
    pub rolling_ball_radius: i64,
    pub watershed_split: bool,
    pub watershed_min_distance_um: f64,
    pub small_threshold_um: f64,
    pub large_threshold_um: f64,
    /// Explicit Cellpose expected-diameter prior (µm). 0 ⇒ Auto: derive it from
    /// the size bins (`(small+large)/2`), preserving the legacy behaviour.
    #[serde(default)]
    pub expected_diameter_um: f64,
    /// false ⇒ `--no-gpu`.
    pub use_gpu: bool,
}

/// Detection result returned to the UI (= TS `DetectionResultDTO`).
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct DetectionResultDto {
    pub image_width: i64,
    pub image_height: i64,
    pub cells: Vec<CellDto>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub image_stats: Option<std::collections::BTreeMap<String, f64>>,
}

/// Detection error union (= TS `DetectionError`). Serialized as an internally
/// tagged object: `{ "kind": "sidecarFailed", "exitCode": 1, "stderr": "…" }`.
#[derive(Debug, Clone, Serialize)]
#[serde(tag = "kind", rename_all = "camelCase")]
pub enum DetectionErrorDto {
    #[serde(rename_all = "camelCase")]
    ModelNotInstalled { model_id: String },
    #[serde(rename_all = "camelCase")]
    SidecarFailed { exit_code: i32, stderr: String },
    #[serde(rename = "imageDecodeFailed")]
    ImageDecodeFailed,
    #[serde(rename = "cancelled")]
    Cancelled,
}

/// Availability result (= TS `{ installed: boolean; reason?: string }`).
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Availability {
    pub installed: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub reason: Option<String>,
}

// ===========================================================================
// Progress events (= TS DetectionProgress). Emitted on the per-run event name.
// ===========================================================================

/// A single progress event streamed from stderr, keyed by `run_id`. Serialized
/// tagged so the TS side can `switch (p.kind)`.
#[derive(Debug, Clone, Serialize)]
#[serde(tag = "kind", rename_all = "camelCase")]
pub enum DetectionProgress {
    /// Human-readable stderr line.
    #[serde(rename_all = "camelCase")]
    Stage { run_id: String, line: String },
    /// Parsed device line ("MPS" | "CPU" | "CUDA:0").
    #[serde(rename_all = "camelCase")]
    Device { run_id: String, device: String },
    /// Future SAM weight-download progress.
    #[serde(rename_all = "camelCase")]
    Weights {
        run_id: String,
        done_mb: f64,
        total_mb: f64,
    },
}

/// Tauri event name a run's progress is emitted on. The TS transport listens on
/// this exact name and forwards to `onProgress`.
pub fn progress_event_name(run_id: &str) -> String {
    format!("detection://progress/{run_id}")
}
