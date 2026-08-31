//! GeoJSON export for QuPath, Shapely, and other image-analysis tools.
//!
//! Coordinates are source-image pixels with a top-left origin and y increasing
//! downward. This is intentionally not geographic data; the collection carries
//! that fact as metadata so downstream tools never infer a CRS silently.

use serde_json::{json, Map, Value};
use tauri::{AppHandle, State};

use crate::db::models::CellDto;
use crate::db::repo::{self, Db};
use crate::export::csv::{bin_index, bin_labels};
use crate::export::provenance::{open_reader, resolve_out_path, ExportContext};
use crate::paths::FileStore;

const FALLBACK_CIRCLE_VERTICES: usize = 32;

fn signed_area(ring: &[[f64; 2]]) -> f64 {
    if ring.len() < 3 {
        return 0.0;
    }
    let mut sum = 0.0;
    for index in 0..ring.len() {
        let current = ring[index];
        let next = ring[(index + 1) % ring.len()];
        sum += current[0] * next[1] - next[0] * current[1];
    }
    sum / 2.0
}

fn polygon_ring(cell: &CellDto) -> (Vec<[f64; 2]>, &'static str) {
    let (mut ring, source) = match cell.contour_px.as_ref().filter(|points| points.len() >= 3) {
        Some(points) => (points.clone(), "measured"),
        None => {
            let radius = (cell.diameter_px / 2.0).max(0.5);
            let points = (0..FALLBACK_CIRCLE_VERTICES)
                .map(|index| {
                    let theta = std::f64::consts::TAU * index as f64
                        / FALLBACK_CIRCLE_VERTICES as f64;
                    [
                        cell.cx + radius * theta.cos(),
                        cell.cy + radius * theta.sin(),
                    ]
                })
                .collect();
            (points, "approximated_circle")
        }
    };

    if ring.first() != ring.last() {
        if let Some(first) = ring.first().copied() {
            ring.push(first);
        }
    }
    // RFC 7946 exterior rings follow the right-hand rule. Apply it to the raw
    // pixel coordinates even though their display y-axis points downward.
    if signed_area(&ring) < 0.0 {
        ring.reverse();
    }
    (ring, source)
}

fn push_measurement(measurements: &mut Vec<Value>, name: &str, value: Option<f64>) {
    if let Some(value) = value {
        measurements.push(json!({ "name": name, "value": value }));
    }
}

fn insert_optional(properties: &mut Map<String, Value>, key: &str, value: Option<f64>) {
    if let Some(value) = value {
        properties.insert(key.to_string(), json!(value));
    }
}

fn feature(cell: &CellDto, thresholds: &[f64], px_per_um: f64) -> Value {
    let (ring, contour_source) = polygon_ring(cell);
    let area_px2 = signed_area(&ring).abs();
    let area_um2 = cell.area_um2.or_else(|| {
        (px_per_um > 0.0).then_some(area_px2 / (px_per_um * px_per_um))
    });
    let labels = bin_labels(thresholds);
    let label = labels
        .get(bin_index(cell.diameter_um, thresholds))
        .cloned()
        .unwrap_or_else(|| "all".to_string());

    let mut measurements = vec![
        json!({ "name": "Diameter (µm)", "value": cell.diameter_um }),
        json!({ "name": "Diameter (px)", "value": cell.diameter_px }),
        json!({ "name": "Confidence", "value": cell.confidence }),
        json!({ "name": "Area (px^2)", "value": area_px2 }),
    ];
    push_measurement(&mut measurements, "Area (µm^2)", area_um2);
    push_measurement(&mut measurements, "Perimeter (µm)", cell.perimeter_um);
    push_measurement(&mut measurements, "Circularity", cell.circularity);
    push_measurement(&mut measurements, "Solidity", cell.solidity);
    push_measurement(&mut measurements, "Aspect ratio", cell.aspect_ratio);
    push_measurement(&mut measurements, "Eccentricity", cell.eccentricity);
    push_measurement(&mut measurements, "Mean intensity", cell.mean_intensity);
    push_measurement(
        &mut measurements,
        "Integrated density",
        cell.integrated_density,
    );

    let mut properties = Map::from_iter([
        ("id".to_string(), json!(cell.id)),
        ("objectType".to_string(), json!("detection")),
        ("classification".to_string(), json!({ "name": label })),
        ("isLocked".to_string(), json!(false)),
        ("measurements".to_string(), json!(measurements)),
        ("cx_px".to_string(), json!(cell.cx)),
        ("cy_px".to_string(), json!(cell.cy)),
        ("diameter_um".to_string(), json!(cell.diameter_um)),
        ("diameter_px".to_string(), json!(cell.diameter_px)),
        ("area_px2".to_string(), json!(area_px2)),
        ("confidence".to_string(), json!(cell.confidence)),
        ("bin_label".to_string(), json!(label)),
        (
            "size_class".to_string(),
            json!(cell.size_class.as_deref().unwrap_or("")),
        ),
        (
            "edge_touching".to_string(),
            json!(cell.edge_touching.unwrap_or(false)),
        ),
        (
            "likely_clump".to_string(),
            json!(cell.likely_clump.unwrap_or(false)),
        ),
        (
            "likely_debris".to_string(),
            json!(cell.likely_debris.unwrap_or(false)),
        ),
        ("is_manual".to_string(), json!(cell.is_manual.unwrap_or(false))),
        ("contour_source".to_string(), json!(contour_source)),
    ]);
    insert_optional(&mut properties, "area_um2", area_um2);
    insert_optional(&mut properties, "perimeter_um", cell.perimeter_um);
    insert_optional(&mut properties, "circularity", cell.circularity);
    insert_optional(&mut properties, "eccentricity", cell.eccentricity);
    insert_optional(&mut properties, "mean_intensity", cell.mean_intensity);
    insert_optional(
        &mut properties,
        "integrated_density",
        cell.integrated_density,
    );
    insert_optional(&mut properties, "centroid_um_x", cell.centroid_um_x);
    insert_optional(&mut properties, "centroid_um_y", cell.centroid_um_y);
    insert_optional(&mut properties, "aspect_ratio", cell.aspect_ratio);
    insert_optional(&mut properties, "solidity", cell.solidity);

    json!({
        "type": "Feature",
        "id": cell.id,
        "geometry": { "type": "Polygon", "coordinates": [ring] },
        "properties": properties,
    })
}

#[allow(clippy::too_many_arguments)]
fn feature_collection(
    cells: &[CellDto],
    file_name: &str,
    width_px: i64,
    height_px: i64,
    thresholds: &[f64],
    px_per_um: f64,
    confidence: f64,
    model_id: &str,
) -> Result<Value, String> {
    let features: Vec<Value> = cells
        .iter()
        .filter(|cell| cell.confidence >= confidence)
        .map(|cell| feature(cell, thresholds, px_per_um))
        .collect();
    if features.is_empty() {
        return Err("There are no detected cells to export.".to_string());
    }

    Ok(json!({
        "type": "FeatureCollection",
        "properties": {
            "generator": format!("CellCounter {}", env!("CARGO_PKG_VERSION")),
            "coordinate_space": "image_pixels_top_left_origin_y_down",
            "note": "Coordinates are in SOURCE IMAGE PIXEL SPACE (origin top-left, x right, y down), not geographic. No CRS transform is defined; import directly into QuPath, Shapely, or GeoPandas without reprojecting.",
            "image_filename": file_name,
            "image_width_px": width_px,
            "image_height_px": height_px,
            "px_per_um": px_per_um,
            "model_id": model_id,
            "confidence_threshold": confidence,
            "thresholds_um": thresholds,
            "exported_at": repo::now_iso8601(),
            "n_features": features.len(),
        },
        "features": features,
    }))
}

/// Export live, ROI-filtered cells as a GeoJSON FeatureCollection. The caller
/// supplies cells so manual edits and the visible ROI selection are preserved.
#[tauri::command]
#[allow(clippy::too_many_arguments)]
pub async fn export_geojson(
    app: AppHandle,
    db: State<'_, Db>,
    image_id: String,
    cells: Vec<CellDto>,
    image_width: i64,
    image_height: i64,
    px_per_um: f64,
    confidence: Option<f64>,
    out_path: String,
) -> Result<String, String> {
    let store = FileStore::from_app(&app)?;
    let conn = open_reader(&store)?;
    let context = ExportContext::load(&conn, &store, &image_id)?;
    let cutoff = context.effective_confidence(confidence.unwrap_or(0.0));
    let model_id = context
        .detector_id
        .as_deref()
        .unwrap_or(&context.model_id);
    let collection = feature_collection(
        &cells,
        &context.file_name,
        image_width,
        image_height,
        &context.thresholds,
        px_per_um,
        cutoff,
        model_id,
    )?;
    let body = serde_json::to_string_pretty(&collection)
        .map_err(|error| format!("could not encode GeoJSON: {error}"))?;
    let resolved = resolve_out_path(&store, &out_path)?;
    std::fs::write(&resolved, body)
        .map_err(|error| format!("could not write GeoJSON: {error}"))?;
    let _ = &db;
    Ok(resolved.to_string_lossy().into_owned())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn cell(contour_px: Option<Vec<[f64; 2]>>) -> CellDto {
        CellDto {
            id: "cell-1".to_string(),
            cx: 10.0,
            cy: 20.0,
            diameter_um: 5.0,
            diameter_px: 10.0,
            confidence: 0.9,
            area_um2: None,
            perimeter_um: None,
            circularity: None,
            eccentricity: None,
            mean_intensity: None,
            integrated_density: None,
            centroid_um_x: None,
            centroid_um_y: None,
            aspect_ratio: None,
            solidity: None,
            edge_touching: None,
            likely_clump: None,
            likely_debris: None,
            size_class: None,
            is_manual: None,
            contour_px,
        }
    }

    #[test]
    fn fallback_circle_is_closed_and_declared_as_approximation() {
        let value = feature(&cell(None), &[20.0, 30.0], 2.0);
        let ring = value["geometry"]["coordinates"][0]
            .as_array()
            .expect("polygon ring");
        assert_eq!(ring.len(), FALLBACK_CIRCLE_VERTICES + 1);
        assert_eq!(ring.first(), ring.last());
        assert_eq!(value["properties"]["contour_source"], "approximated_circle");
    }

    #[test]
    fn measured_ring_is_rfc_closed_and_counter_clockwise() {
        let value = feature(
            &cell(Some(vec![[0.0, 0.0], [0.0, 4.0], [4.0, 0.0]])),
            &[],
            1.0,
        );
        let ring: Vec<[f64; 2]> = serde_json::from_value(
            value["geometry"]["coordinates"][0].clone(),
        )
        .expect("ring");
        assert_eq!(ring.first(), ring.last());
        assert!(signed_area(&ring) >= 0.0);
        assert_eq!(value["properties"]["contour_source"], "measured");
    }

    #[test]
    fn collection_refuses_an_empty_visible_result() {
        let mut hidden = cell(None);
        hidden.confidence = 0.2;
        let result = feature_collection(
            &[hidden],
            "sample.tif",
            100,
            100,
            &[20.0],
            2.0,
            0.5,
            "cpsam_v2",
        );
        assert_eq!(
            result.expect_err("hidden cell must not export"),
            "There are no detected cells to export."
        );
    }
}
