//! Full-resolution annotated PNG export for one result or a complete batch.

use std::collections::HashSet;
use std::io::Cursor;
use std::path::{Path, PathBuf};

use image::{DynamicImage, ImageFormat, Rgb, RgbImage};
use rusqlite::OptionalExtension;
use tauri::{AppHandle, State};

use crate::db::models::CellDto;
use crate::db::repo::Db;
use crate::export::csv::bin_index;
use crate::export::provenance::{open_reader, resolve_out_path, ExportContext};
use crate::paths::FileStore;

const BIN_RGB: [(u8, u8, u8); 5] = [
    (83, 78, 158),
    (42, 143, 182),
    (28, 172, 150),
    (176, 196, 66),
    (239, 176, 51),
];

fn blend(pixel: &mut Rgb<u8>, color: (u8, u8, u8), alpha: f64) {
    let inverse = 1.0 - alpha;
    pixel[0] = (pixel[0] as f64 * inverse + color.0 as f64 * alpha).round() as u8;
    pixel[1] = (pixel[1] as f64 * inverse + color.1 as f64 * alpha).round() as u8;
    pixel[2] = (pixel[2] as f64 * inverse + color.2 as f64 * alpha).round() as u8;
}

fn put(buf: &mut RgbImage, x: i64, y: i64, color: (u8, u8, u8)) {
    if x >= 0 && y >= 0 && x < buf.width() as i64 && y < buf.height() as i64 {
        *buf.get_pixel_mut(x as u32, y as u32) = Rgb([color.0, color.1, color.2]);
    }
}

/// Liang–Barsky clipping bounds raster work before integer conversion.
fn clipped_line(width: u32, height: u32, from: [f64; 2], to: [f64; 2]) -> Option<([f64; 2], [f64; 2])> {
    if width == 0 || height == 0 || from.iter().chain(to.iter()).any(|v| !v.is_finite()) { return None; }
    let dx = to[0] - from[0]; let dy = to[1] - from[1];
    if !dx.is_finite() || !dy.is_finite() { return None; }
    let mut lo: f64 = 0.0; let mut hi: f64 = 1.0;
    for (p, q) in [(-dx, from[0]), (dx, width as f64 - 1.0 - from[0]), (-dy, from[1]), (dy, height as f64 - 1.0 - from[1])] {
        if p == 0.0 { if q < 0.0 { return None; } }
        else { let r = q / p; if p < 0.0 { lo = lo.max(r); } else { hi = hi.min(r); } if lo > hi { return None; } }
    }
    let point = |t: f64| [(from[0] + t * dx).clamp(0.0, width as f64 - 1.0), (from[1] + t * dy).clamp(0.0, height as f64 - 1.0)];
    Some((point(lo), point(hi)))
}

pub(crate) fn geometry_budget(cells: &[CellDto], width: u32, height: u32, circles: bool) -> Result<(), String> {
    if cells.len() > 100_000 { return Err("Overlay exceeds 100,000 objects".into()); }
    let mut work: f64 = 0.0; let mut vertices = 0usize;
    for cell in cells {
        if [cell.cx, cell.cy, cell.diameter_px, cell.diameter_um, cell.confidence].iter().any(|v| !v.is_finite()) || cell.diameter_px <= 0.0 { return Err("Overlay geometry must be finite with positive diameters".into()); }
        let r = (cell.diameter_px / 2.0).max(1.0);
        let x0 = (cell.cx - r).floor().max(0.0); let x1 = (cell.cx + r).ceil().min(width as f64 - 1.0);
        let y0 = (cell.cy - r).floor().max(0.0); let y1 = (cell.cy + r).ceil().min(height as f64 - 1.0);
        if circles || cell.contour_px.as_ref().map_or(true, |points| points.len() < 3) { work += (x1 - x0 + 1.0).max(0.0) * (y1 - y0 + 1.0).max(0.0); }
        if let Some(points) = &cell.contour_px {
            vertices = vertices.saturating_add(points.len());
            if vertices > 1_000_000 || points.iter().flatten().any(|v| !v.is_finite()) { return Err("Overlay contour budget exceeded or coordinates invalid".into()); }
            if !circles { for i in 0..points.len() { if let Some((a,b)) = clipped_line(width,height,points[i],points[(i+1)%points.len()]) { work += (b[0]-a[0]).abs().max((b[1]-a[1]).abs()) + 1.0; } } }
        }
        // Box mode and line thickness are covered conservatively as well.
        work += 4.0 * (width as f64 + height as f64).min(4.0 * r + 4.0);
        if work > 100_000_000.0 { return Err("Overlay exceeds its bounded rendering budget. Export fewer objects".into()); }
    }
    Ok(())
}

fn draw_line(buf: &mut RgbImage, from: [f64; 2], to: [f64; 2], color: (u8, u8, u8)) {
    let Some((from, to)) = clipped_line(buf.width(), buf.height(), from, to) else { return; };
    let (mut x0, mut y0) = (from[0].round() as i64, from[1].round() as i64);
    let (x1, y1) = (to[0].round() as i64, to[1].round() as i64);
    let dx = (x1 - x0).abs();
    let sx = if x0 < x1 { 1 } else { -1 };
    let dy = -(y1 - y0).abs();
    let sy = if y0 < y1 { 1 } else { -1 };
    let mut error = dx + dy;
    loop {
        put(buf, x0, y0, color);
        put(buf, x0 + 1, y0, color);
        put(buf, x0, y0 + 1, color);
        if x0 == x1 && y0 == y1 {
            break;
        }
        let doubled = 2 * error;
        if doubled >= dy {
            error += dy;
            x0 += sx;
        }
        if doubled <= dx {
            error += dx;
            y0 += sy;
        }
    }
}

fn draw_contour(buf: &mut RgbImage, contour: &[[f64; 2]], color: (u8, u8, u8)) {
    for index in 0..contour.len() {
        draw_line(buf, contour[index], contour[(index + 1) % contour.len()], color);
    }
}

fn draw_box(buf: &mut RgbImage, cell: &CellDto, color: (u8, u8, u8)) {
    let radius = (cell.diameter_px / 2.0).max(1.0);
    let left = cell.cx - radius;
    let top = cell.cy - radius;
    let right = cell.cx + radius;
    let bottom = cell.cy + radius;
    draw_line(buf, [left, top], [right, top], color);
    draw_line(buf, [right, top], [right, bottom], color);
    draw_line(buf, [right, bottom], [left, bottom], color);
    draw_line(buf, [left, bottom], [left, top], color);
}

fn draw_circle(buf: &mut RgbImage, cell: &CellDto, color: (u8, u8, u8)) {
    let radius = (cell.diameter_px / 2.0).max(1.0);
    let outer = radius * radius;
    let inner_radius = (radius - radius.max(2.0) * 0.12).max(0.0);
    let inner = inner_radius * inner_radius;
    let x0 = (cell.cx - radius).floor().max(0.0) as i64;
    let x1 = (cell.cx + radius).ceil().min(buf.width() as f64 - 1.0) as i64;
    let y0 = (cell.cy - radius).floor().max(0.0) as i64;
    let y1 = (cell.cy + radius).ceil().min(buf.height() as f64 - 1.0) as i64;
    for y in y0..=y1 {
        for x in x0..=x1 {
            let dx = x as f64 + 0.5 - cell.cx;
            let dy = y as f64 + 0.5 - cell.cy;
            let distance = dx * dx + dy * dy;
            if distance <= outer {
                let pixel = buf.get_pixel_mut(x as u32, y as u32);
                if distance >= inner {
                    *pixel = Rgb([color.0, color.1, color.2]);
                } else {
                    blend(pixel, color, 0.18);
                }
            }
        }
    }
}

fn render(
    image: DynamicImage,
    cells: &[CellDto],
    thresholds: &[f64],
    cutoff: f64,
    overlay_mode: &str,
) -> Result<Vec<u8>, String> {
    if overlay_mode != "outline" && overlay_mode != "bbox" {
        return Err(format!("unsupported overlay mode: {overlay_mode}"));
    }
    geometry_budget(cells, image.width(), image.height(), false)?;
    let mut rgb = image.to_rgb8();
    for cell in cells.iter().filter(|cell| cell.confidence >= cutoff) {
        let color = BIN_RGB[bin_index(cell.diameter_um, thresholds).min(BIN_RGB.len() - 1)];
        if overlay_mode == "bbox" {
            draw_box(&mut rgb, cell, color);
        } else if let Some(contour) = cell.contour_px.as_ref().filter(|points| points.len() >= 3) {
            draw_contour(&mut rgb, contour, color);
        } else {
            draw_circle(&mut rgb, cell, color);
        }
    }
    let mut output = Cursor::new(Vec::new());
    DynamicImage::ImageRgb8(rgb)
        .write_to(&mut output, ImageFormat::Png)
        .map_err(|error| format!("could not encode annotated PNG: {error}"))?;
    Ok(output.into_inner())
}

pub(crate) fn render_file(
    path: &Path,
    cells: &[CellDto],
    thresholds: &[f64],
    cutoff: f64,
    overlay_mode: &str,
) -> Result<Vec<u8>, String> {
    let mut reader = image::ImageReader::open(path).map_err(|error| format!("could not open source image: {error}"))?;
    let mut limits = image::Limits::default();
    limits.max_alloc = Some(128 * 1024 * 1024);
    reader.limits(limits);
    let image = reader.decode().map_err(|error| format!("could not decode bounded export image: {error}"))?;
    render(image, cells, thresholds, cutoff, overlay_mode)
}

fn safe_component(name: &str) -> String {
    let mut output = String::with_capacity(name.len());
    for character in name.chars() {
        if character.is_control()
            || matches!(character, '/' | '\\' | ':' | '*' | '?' | '"' | '<' | '>' | '|')
        {
            output.push('_');
        } else {
            output.push(character);
        }
    }
    while output.contains("__") {
        output = output.replace("__", "_");
    }
    let trimmed = output.trim_matches([' ', '.', '_']);
    if trimmed.is_empty() {
        "sample".to_string()
    } else {
        trimmed.to_string()
    }
}

fn unique_folder(parent: &Path, name: &str) -> Result<PathBuf, String> {
    let base = safe_component(name);
    for suffix in 1..=10_000 {
        let candidate = if suffix == 1 {
            parent.join(&base)
        } else {
            parent.join(format!("{base}-{suffix}"))
        };
        match std::fs::create_dir(&candidate) {
            Ok(()) => return Ok(candidate),
            Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => continue,
            Err(error) => return Err(format!("could not create export folder: {error}")),
        }
    }
    Err("could not create a unique export folder".to_string())
}

#[tauri::command]
pub async fn export_annotated_png(
    app: AppHandle,
    manager: State<'_, crate::analysis::runner::AssayManager>,
    db: State<'_, Db>,
    image_id: String,
    cells: Vec<CellDto>,
    confidence: Option<f64>,
    overlay_mode: String,
    out_path: String,
) -> Result<String, String> {
    let store = FileStore::from_app(&app)?;
    let (mut context, display_request) = {
        let conn = open_reader(&store)?;
        conn.execute_batch("BEGIN DEFERRED TRANSACTION").map_err(|e|e.to_string())?;
        let context = ExportContext::load(&conn, &store, &image_id)?;
        let request = super::display::capture(&conn, &store, &context)?;
        (context, request)
    };
    let temporary = super::display::prepare(app, manager, display_request).await?;
    if let Some(display) = &temporary { context.stored_path = display.0.clone(); }
    let cutoff = context.effective_confidence(confidence.unwrap_or(0.0));
    let png = render_file(
        &context.stored_path,
        &cells,
        &context.thresholds,
        cutoff,
        &overlay_mode,
    )?;
    let resolved = resolve_out_path(&store, &out_path)?;
    std::fs::write(&resolved, png)
        .map_err(|error| format!("could not write annotated PNG: {error}"))?;
    let _ = &db;
    Ok(resolved.to_string_lossy().into_owned())
}

#[tauri::command]
pub async fn export_batch_annotated_pngs(
    app: AppHandle,
    manager: State<'_, crate::analysis::runner::AssayManager>,
    db: State<'_, Db>,
    batch_id: String,
    confidence: Option<f64>,
    overlay_mode: String,
    out_dir: String,
) -> Result<String, String> {
    let store = FileStore::from_app(&app)?;
    // SQLite statements borrow a non-Sync connection. Finish each read scope
    // before awaiting source reconstruction so the Tauri command remains Send.
    let (batch_name, image_ids) = {
        let conn = open_reader(&store)?;
        conn.execute_batch("BEGIN DEFERRED TRANSACTION").map_err(|e| e.to_string())?;
        let batch_name = conn
            .query_row(
                "SELECT display_name FROM batches WHERE id = ?1",
                [&batch_id],
                |row| row.get::<_, String>(0),
            )
            .optional()
            .map_err(|error| format!("batch lookup failed: {error}"))?
            .ok_or_else(|| format!("no batch with id {batch_id}"))?;
        let mut statement = conn
            .prepare("SELECT id FROM images WHERE batch_id = ?1 ORDER BY imported_at DESC")
            .map_err(|error| format!("image list failed: {error}"))?;
        let image_ids = statement
            .query_map([&batch_id], |row| row.get::<_, String>(0))
            .map_err(|error| format!("image list failed: {error}"))?
            .collect::<Result<Vec<_>, _>>()
            .map_err(|error| format!("image list failed: {error}"))?;
        (batch_name, image_ids)
    };
    let parent = if out_dir.trim().is_empty() {
        store.exports_dir()
    } else {
        PathBuf::from(out_dir)
    };
    std::fs::create_dir_all(&parent)
        .map_err(|error| format!("could not create export parent folder: {error}"))?;
    let folder = unique_folder(&parent, &batch_name)?;

    let mut used_names = HashSet::new();
    let mut written = 0usize;
    let mut errors = Vec::new();
    for image_id in image_ids {
        let snapshot = (|| {
            let conn = open_reader(&store)?;
            conn.execute_batch("BEGIN DEFERRED TRANSACTION").map_err(|e| e.to_string())?;
            let context = ExportContext::load(&conn, &store, &image_id)?;
            if context.cells.is_empty() { return Ok(None); }
            let request = super::display::capture(&conn, &store, &context)?;
            Ok::<_, String>(Some((context, request)))
        })();
        let (mut context, display_request) = match snapshot {
            Ok(Some(snapshot)) => snapshot,
            Ok(None) => continue,
            Err(error) => {
                errors.push(format!("{image_id}: {error}"));
                continue;
            }
        };
        let stem = Path::new(&context.file_name)
            .file_stem()
            .and_then(|value| value.to_str())
            .unwrap_or("sample");
        let base = safe_component(stem);
        let mut output_name = format!("{base}-annotated.png");
        let mut suffix = 2;
        while !used_names.insert(output_name.to_ascii_lowercase()) {
            output_name = format!("{base}-annotated_{suffix}.png");
            suffix += 1;
        }
        let cutoff = context.effective_confidence(confidence.unwrap_or(0.0));
        let temporary = match super::display::prepare(app.clone(), manager.clone(), display_request).await {
            Ok(display) => display,
            Err(error) => { errors.push(format!("{image_id}: {error}")); continue; }
        };
        if let Some(display) = &temporary { context.stored_path = display.0.clone(); }
        match render_file(
            &context.stored_path,
            &context.cells,
            &context.thresholds,
            cutoff,
            &overlay_mode,
        ) {
            Ok(png) => match std::fs::write(folder.join(&output_name), png) {
                Ok(()) => written += 1,
                Err(error) => errors.push(format!("{output_name}: {error}")),
            },
            Err(error) => errors.push(format!("{output_name}: {error}")),
        }
    }
    let _ = &db;
    if written == 0 {
        let _ = std::fs::remove_dir(&folder);
        return Err(if errors.is_empty() {
            "This batch has no analyzed images to export.".to_string()
        } else {
            format!("No annotated PNGs were written: {}", errors.join("; "))
        });
    }
    if !errors.is_empty() {
        return Err(format!(
            "Wrote {written} annotated PNG(s) to {} but {} image(s) failed: {}",
            folder.to_string_lossy(),
            errors.len(),
            errors.join("; ")
        ));
    }
    Ok(folder.to_string_lossy().into_owned())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn cell() -> CellDto {
        CellDto {
            id: "cell".into(),
            cx: 8.0,
            cy: 8.0,
            diameter_um: 5.0,
            diameter_px: 8.0,
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
            contour_px: None,
        }
    }

    #[test]
    fn renderer_changes_visible_pixels_and_preserves_hidden_images() {
        let source = DynamicImage::new_rgb8(16, 16);
        let visible = render(source.clone(), &[cell()], &[20.0], 0.5, "outline").unwrap();
        let hidden = render(source, &[cell()], &[20.0], 0.95, "outline").unwrap();
        assert_ne!(visible, hidden);
    }

    #[test]
    fn windows_unsafe_names_are_sanitized() {
        assert_eq!(safe_component("A:B*C?.tif"), "A_B_C_.tif");
        assert_eq!(safe_component("..."), "sample");
    }
}
