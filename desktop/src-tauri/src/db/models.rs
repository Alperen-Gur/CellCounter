//! db/models.rs — Rust row structs mirroring the TypeScript DTOs.
//!
//! These are the serde types that cross the Tauri IPC boundary. They are
//! `#[serde(rename_all = "camelCase")]` so they serialize EXACTLY as
//! `kernel/types.ts` (§3.2) declares — the frozen contract every page binds to.
//!
//! Two JSON shapes matter here and must not be confused:
//!   1. The DTO shape (camelCase) — what the UI sees over IPC. Defined here.
//!   2. The persisted `CellPayload` shape (stored inside `detections.cells_json`)
//!      — mirrors `Persistence/Records.swift`'s private `CellPayload`, notably
//!      the FLATTENED contour `contourFlat: [x0,y0,x1,y1,…]`. The DTO↔payload
//!      mapping lives here so `repo.rs` only ever deals in DTOs.
//!
//! Coordinate space: all geometry (cx, cy, contour) is SOURCE-PIXEL.

use serde::{Deserialize, Serialize};

// ---------------------------------------------------------------------------
// CellDTO — 1:1 with kernel/types.ts CellDTO
// ---------------------------------------------------------------------------

/// A detected (or manually-added) cell in SOURCE-PIXEL space.
///
/// Optional measurement/flag fields are `Option` and `skip_serializing_if`
/// none, so a manual marker serializes to the same minimal object the Swift
/// sidecar emits (absent keys, not `null`).
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CellDto {
    pub id: String,
    pub cx: f64,
    pub cy: f64,
    pub diameter_um: f64,
    pub diameter_px: f64,
    pub confidence: f64,

    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub area_um2: Option<f64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub perimeter_um: Option<f64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub circularity: Option<f64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub eccentricity: Option<f64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub mean_intensity: Option<f64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub integrated_density: Option<f64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub centroid_um_x: Option<f64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub centroid_um_y: Option<f64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub aspect_ratio: Option<f64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub solidity: Option<f64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub edge_touching: Option<bool>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub likely_clump: Option<bool>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub likely_debris: Option<bool>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub size_class: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub is_manual: Option<bool>,

    /// Polygon in source-px as `[[x, y], …]`; absent ⇒ render bbox/circle.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub contour_px: Option<Vec<[f64; 2]>>,
}

// ---------------------------------------------------------------------------
// ImageDTO — 1:1 with kernel/types.ts ImageDTO
// ---------------------------------------------------------------------------

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ImageDto {
    pub id: String,
    pub file_name: String,
    pub width_px: i64,
    pub height_px: i64,
    /// ISO-8601.
    pub imported_at: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub file_hash: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub confidence_override: Option<f64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub notes: Option<String>,
    /// Resolved by backend (`Images/<id>.<ext>`).
    pub stored_path: String,
    /// `Thumbnails/<id>.jpg`.
    pub thumb_path: String,
}

// ---------------------------------------------------------------------------
// DetectionDTO — 1:1 with kernel/types.ts DetectionDTO
// ---------------------------------------------------------------------------

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DetectionDto {
    pub id: String,
    pub image_id: String,
    pub detector_id: String,
    pub ran_at: String,
    pub cells: Vec<CellDto>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub image_stats: Option<std::collections::BTreeMap<String, f64>>,
}

// ---------------------------------------------------------------------------
// BatchDTO — 1:1 with kernel/types.ts BatchDTO
// ---------------------------------------------------------------------------

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct BatchDto {
    pub id: String,
    pub display_name: String,
    pub created_at: String,
    pub model_id: String,
    pub px_per_um: f64,
    pub thresholds: Vec<f64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub condition: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub px_per_um_source: Option<String>,
    pub image_ids: Vec<String>,
}

// ---------------------------------------------------------------------------
// GroundTruthDTO — 1:1 with kernel/types.ts GroundTruthDTO
// ---------------------------------------------------------------------------

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct GroundTruthDto {
    pub id: String,
    pub image_id: String,
    pub cx: f64,
    pub cy: f64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub diameter_um: Option<f64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub note: Option<String>,
    pub created_at: String,
}

// ---------------------------------------------------------------------------
// RoiDTO — mirrors ROIRecord (Persistence/Records.swift) + PersistencePort
// ---------------------------------------------------------------------------

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RoiDto {
    pub id: String,
    pub image_id: String,
    /// "include" | "exclude"
    pub kind: String,
    /// "rect" | "ellipse"
    pub shape: String,
    pub x: f64,
    pub y: f64,
    pub width: f64,
    pub height: f64,
    pub created_at: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub name: Option<String>,
}

// ---------------------------------------------------------------------------
// ConditionDTO — mirrors ConditionRecord
// ---------------------------------------------------------------------------

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ConditionDto {
    pub id: String,
    pub name: String,
    pub color: String,
    pub created_at: String,
    pub order: i64,
}

// ---------------------------------------------------------------------------
// CalibrationPresetDTO / BinPresetDTO — mirror the two preset records
// ---------------------------------------------------------------------------

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CalibrationPresetDto {
    pub id: String,
    pub name: String,
    pub px_per_um: f64,
    pub is_default: bool,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct BinPresetDto {
    pub id: String,
    pub name: String,
    pub thresholds: Vec<f64>,
}

// ---------------------------------------------------------------------------
// Correction input — mirrors CorrectionRecord fields written by recordCorrection
// ---------------------------------------------------------------------------

/// Payload for `record_correction`. `kind ∈ {add,remove,move,resize,accept,manual}`.
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CorrectionInput {
    pub kind: String,
    pub cell_id: String,
    pub cx: f64,
    pub cy: f64,
    pub diameter: f64,
}

// ---------------------------------------------------------------------------
// CalibrationDTO — 1:1 with kernel/types.ts CalibrationDTO (§3.6)
// ---------------------------------------------------------------------------

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CalibrationDto {
    pub px_per_um: f64,
    /// omeXML | tiffBaseline | olympus | zeiss | imagej | preset | manual | default
    pub source: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub confidence: Option<String>,
}

// ---------------------------------------------------------------------------
// Persisted CellPayload  (detections.cells_json)  ⇄  CellDto
// ---------------------------------------------------------------------------
//
// This is the STORAGE shape, mirroring the private `CellPayload` in
// `Persistence/Records.swift`. Two differences from the DTO:
//   * `diameter` (µm) instead of `diameterUm`
//   * `contourFlat: [x0,y0,x1,y1,…]` instead of `contourPx: [[x,y],…]`
// so a store.sqlite written by either app decodes with the other.

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct CellPayload {
    id: String,
    cx: f64,
    cy: f64,
    /// µm diameter (Swift field name is `diameter`, not `diameterUm`).
    diameter: f64,
    diameter_px: f64,
    confidence: f64,

    #[serde(default, skip_serializing_if = "Option::is_none")]
    area_microns2: Option<f64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    perimeter_microns: Option<f64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    circularity: Option<f64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    eccentricity: Option<f64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    mean_intensity: Option<f64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    integrated_density: Option<f64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    centroid_um_x: Option<f64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    centroid_um_y: Option<f64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    aspect_ratio: Option<f64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    solidity: Option<f64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    edge_touching: Option<bool>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    likely_clump: Option<bool>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    likely_debris: Option<bool>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    size_class: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    is_manual: Option<bool>,

    /// Flattened contour `[x0, y0, x1, y1, …]`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    contour_flat: Option<Vec<f64>>,
}

impl From<&CellDto> for CellPayload {
    fn from(c: &CellDto) -> Self {
        let contour_flat = c.contour_px.as_ref().and_then(|pts| {
            if pts.is_empty() {
                None
            } else {
                let mut flat = Vec::with_capacity(pts.len() * 2);
                for [x, y] in pts {
                    flat.push(*x);
                    flat.push(*y);
                }
                Some(flat)
            }
        });
        CellPayload {
            id: c.id.clone(),
            cx: c.cx,
            cy: c.cy,
            diameter: c.diameter_um,
            diameter_px: c.diameter_px,
            confidence: c.confidence,
            area_microns2: c.area_um2,
            perimeter_microns: c.perimeter_um,
            circularity: c.circularity,
            eccentricity: c.eccentricity,
            mean_intensity: c.mean_intensity,
            integrated_density: c.integrated_density,
            centroid_um_x: c.centroid_um_x,
            centroid_um_y: c.centroid_um_y,
            aspect_ratio: c.aspect_ratio,
            solidity: c.solidity,
            edge_touching: c.edge_touching,
            likely_clump: c.likely_clump,
            likely_debris: c.likely_debris,
            size_class: c.size_class.clone(),
            is_manual: c.is_manual,
            contour_flat,
        }
    }
}

impl From<CellPayload> for CellDto {
    fn from(p: CellPayload) -> Self {
        // Unflatten contour; require ≥ 2 complete points (Swift keeps ≥ 4 flats,
        // even length) so a malformed odd-length blob renders via bbox fallback.
        let contour_px = p.contour_flat.and_then(|flat| {
            if flat.len() >= 4 && flat.len() % 2 == 0 {
                let mut pts = Vec::with_capacity(flat.len() / 2);
                let mut i = 0;
                while i + 1 < flat.len() {
                    pts.push([flat[i], flat[i + 1]]);
                    i += 2;
                }
                Some(pts)
            } else {
                None
            }
        });
        CellDto {
            id: p.id,
            cx: p.cx,
            cy: p.cy,
            diameter_um: p.diameter,
            diameter_px: p.diameter_px,
            confidence: p.confidence,
            area_um2: p.area_microns2,
            perimeter_um: p.perimeter_microns,
            circularity: p.circularity,
            eccentricity: p.eccentricity,
            mean_intensity: p.mean_intensity,
            integrated_density: p.integrated_density,
            centroid_um_x: p.centroid_um_x,
            centroid_um_y: p.centroid_um_y,
            aspect_ratio: p.aspect_ratio,
            solidity: p.solidity,
            edge_touching: p.edge_touching,
            likely_clump: p.likely_clump,
            likely_debris: p.likely_debris,
            size_class: p.size_class,
            is_manual: p.is_manual,
            contour_px,
        }
    }
}

/// Serialize `cells` to the `cells_json` storage blob (flattened contours).
pub fn cells_to_json(cells: &[CellDto]) -> Result<String, serde_json::Error> {
    let payload: Vec<CellPayload> = cells.iter().map(CellPayload::from).collect();
    serde_json::to_string(&payload)
}

/// Decode a `cells_json` storage blob back into DTOs (unflattened contours).
/// A missing/corrupt blob yields an empty vec (matches Swift's `?? []`).
pub fn cells_from_json(json: &str) -> Vec<CellDto> {
    serde_json::from_str::<Vec<CellPayload>>(json)
        .map(|payload| payload.into_iter().map(CellDto::from).collect())
        .unwrap_or_default()
}

/// The denormalised `min_confidence` column: min over cells, else 1.0 for an
/// empty detection (mirrors `DetectionRecord.minConfidence`).
pub fn min_confidence(cells: &[CellDto]) -> f64 {
    cells
        .iter()
        .map(|c| c.confidence)
        .fold(f64::INFINITY, f64::min)
        .min(1.0)
}
