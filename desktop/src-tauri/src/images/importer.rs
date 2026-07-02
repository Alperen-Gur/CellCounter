//! images/importer.rs — decode + whole-file SHA-256 + thumbnail + EXIF probe.
//!
//! Rust port of `Services/ImageLoader.swift` (decode / hash / thumbnail) and
//! `Services/EXIFCalibration.swift` (physical-pixel-size probe). Exposes one
//! command, `import_image`, matching ARCHITECTURE.md §3.8:
//!
//!   import_image(sourcePath) -> { image: ImageDTO, calibration: CalibrationDTO | null }
//!
//! Steps (mirrors `ImageLoader.importFile`):
//!   1. decode (jpg/jpeg/png/tif/tiff/bmp) — reject anything else
//!   2. whole-file SHA-256 (hex) of the raw bytes
//!   3. copy original into `Images/<uuid>.<ext>` (lowercased ext)
//!   4. write a 256px JPEG (q≈0.7) thumbnail — non-fatal on failure
//!   5. probe EXIF/TIFF calibration per the frozen priority (§3.6)
//!   6. insert the images row and return the DTO + calibration
//!
//! EXIF priority (highest→lowest confidence), exactly as §3.6 / EXIFCalibration:
//!   1. OME-XML in TIFF ImageDescription (tag 270): PhysicalSizeX + unit  → high
//!   2. TIFF baseline XResolution + ResolutionUnit (2=inch÷25400,
//!      3=cm÷10000); reject 72/96/300 dpi defaults; valid 0.001<px/µm<1000 → medium
//!   3. ImageJ ImageDescription ("ImageJ=" prefix): pixelWidth + unit      → medium
//!   4. Olympus vendor: "Calibration Value" + "Calibration Unit"           → low
//! Returns None when nothing recognized. Low-confidence results are still
//! returned to the UI (the Swift host logs+ignores low at import; here we let
//! the TS layer decide — the DTO carries the `confidence` field).

use std::io::Cursor;

use image::{GenericImageView, ImageFormat};
use sha2::{Digest, Sha256};
use tauri::State;
use uuid::Uuid;

use crate::db::models::{CalibrationDto, ImageDto};
use crate::db::repo::{self, Db};

/// Accepted extensions, lowercased (mirrors `ImageLoader.supported`).
const SUPPORTED: &[&str] = &["jpg", "jpeg", "png", "tif", "tiff", "bmp"];

/// Return shape for `import_image`.
#[derive(serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ImportResult {
    pub image: ImageDto,
    /// `null` when no calibration metadata is recognized.
    pub calibration: Option<CalibrationDto>,
}

/// Import a user-dropped file. See module docs for the full step list.
#[tauri::command]
pub fn import_image(db: State<'_, Db>, source_path: String) -> Result<ImportResult, String> {
    let src = std::path::Path::new(&source_path);

    let ext = src
        .extension()
        .and_then(|e| e.to_str())
        .unwrap_or("")
        .to_ascii_lowercase();
    if !SUPPORTED.contains(&ext.as_str()) {
        // Mirrors ImageLoadError.unsupportedFormat.
        return Err(format!(
            "Unsupported image format \".{ext}\". CellCounter accepts JPEG, PNG, and TIFF."
        ));
    }

    // Read whole file once: used for decode, hashing, EXIF probe, and copy.
    let bytes = std::fs::read(src).map_err(|e| format!("File read error: {e}"))?;

    // --- 1. decode ---------------------------------------------------------
    let fmt = ImageFormat::from_extension(&ext)
        .ok_or_else(|| "Couldn't determine image format.".to_string())?;
    let decoded = image::load_from_memory_with_format(&bytes, fmt)
        .map_err(|_| "Couldn't decode the image.".to_string())?;
    let (width_px, height_px) = decoded.dimensions();

    // --- 2. whole-file SHA-256 (hex) --------------------------------------
    let file_hash = sha256_hex(&bytes);

    // --- 3. copy into Images/<uuid>.<ext> (lowercased ext) ----------------
    let id = Uuid::new_v4().to_string();
    let file_name = src
        .file_name()
        .and_then(|n| n.to_str())
        .unwrap_or("image")
        .to_string();
    let store = db.store();
    let dest = store.image_path(&id, &ext);
    let _ = std::fs::remove_file(&dest);
    // Write the bytes we already read into memory instead of re-reading the
    // source from disk (fs::copy would read the whole file a second time).
    std::fs::write(&dest, &bytes).map_err(|e| format!("File write error: {e}"))?;

    // --- 4. thumbnail (non-fatal) -----------------------------------------
    if let Err(e) = write_thumbnail(&decoded, &store.thumb_path(&id), 256) {
        eprintln!("[importer] warning: thumbnail write failed for {id}: {e}");
    }

    // --- 5. EXIF / TIFF calibration probe ---------------------------------
    let calibration = probe_calibration(&bytes);

    // --- 6. insert row + return -------------------------------------------
    let imported_at = repo::now_iso8601();
    let image = repo::insert_image_row(
        &db,
        &id,
        &file_name,
        &source_path,
        width_px as i64,
        height_px as i64,
        &imported_at,
        Some(&file_hash),
    )?;

    Ok(ImportResult { image, calibration })
}

/// Whole-file SHA-256, lowercase hex (mirrors `ImageLoader.sha256Hex`).
fn sha256_hex(bytes: &[u8]) -> String {
    let mut hasher = Sha256::new();
    hasher.update(bytes);
    let digest = hasher.finalize();
    let mut out = String::with_capacity(digest.len() * 2);
    for b in digest {
        out.push_str(&format!("{b:02x}"));
    }
    out
}

/// Write a JPEG thumbnail scaled to fit within `max_dim` (mirrors
/// `ImageLoader.writeThumbnail`, quality ≈ 0.7 → JPEG quality 70).
fn write_thumbnail(
    img: &image::DynamicImage,
    dest: &std::path::Path,
    max_dim: u32,
) -> Result<(), String> {
    let (w, h) = img.dimensions();
    let longest = w.max(h).max(1);
    // Preserve aspect ratio; `thumbnail` uses a good-quality Lanczos-ish filter.
    let scale = max_dim as f32 / longest as f32;
    let tw = ((w as f32 * scale).round() as u32).max(1);
    let th = ((h as f32 * scale).round() as u32).max(1);
    let thumb = img.thumbnail(tw, th).to_rgb8();

    let mut buf = Cursor::new(Vec::new());
    let mut encoder = image::codecs::jpeg::JpegEncoder::new_with_quality(&mut buf, 70);
    encoder
        .encode(
            thumb.as_raw(),
            thumb.width(),
            thumb.height(),
            image::ExtendedColorType::Rgb8,
        )
        .map_err(|e| e.to_string())?;
    std::fs::write(dest, buf.into_inner()).map_err(|e| e.to_string())?;
    Ok(())
}

// ===========================================================================
// EXIF / TIFF calibration probe (port of EXIFCalibration.swift)
// ===========================================================================

/// Read embedded physical-pixel-size metadata and return a `CalibrationDto`.
/// Returns `None` when nothing recognizable is found. Never panics — every
/// parse failure degrades to trying the next source, then `None`.
pub fn probe_calibration(bytes: &[u8]) -> Option<CalibrationDto> {
    // The four text-based parsers all read TIFF tag 270 (ImageDescription).
    // The baseline parser reads XResolution + ResolutionUnit. `kamadak-exif`
    // parses the TIFF IFD directly from the raw file bytes.
    let image_description = read_image_description(bytes);

    // 1. OME-XML in ImageDescription (highest confidence).
    if let Some(desc) = image_description.as_deref() {
        if desc.contains("<OME") || desc.contains("<Pixels") {
            if let Some(r) = parse_ome_xml(desc) {
                return Some(r);
            }
        }
    }

    // 2. TIFF baseline XResolution / ResolutionUnit.
    if let Some(r) = parse_tiff_baseline(bytes) {
        return Some(r);
    }

    // 3. ImageJ metadata in ImageDescription.
    if let Some(desc) = image_description.as_deref() {
        if desc.starts_with("ImageJ=") {
            if let Some(r) = parse_imagej(desc) {
                return Some(r);
            }
        }
    }

    // 4. Olympus "Calibration Value" in ImageDescription (low confidence).
    if let Some(desc) = image_description.as_deref() {
        if let Some(r) = parse_olympus(desc) {
            return Some(r);
        }
    }

    None
}

/// Read TIFF tag 270 (ImageDescription) via kamadak-exif, if present.
fn read_image_description(bytes: &[u8]) -> Option<String> {
    let exif = exif::Reader::new()
        .read_from_container(&mut Cursor::new(bytes))
        .ok()?;
    let field = exif.get_field(exif::Tag::ImageDescription, exif::In::PRIMARY)?;
    // Display value is quoted/escaped; for ASCII fields pull the raw string.
    match &field.value {
        exif::Value::Ascii(vecs) => {
            let mut s = String::new();
            for v in vecs {
                s.push_str(&String::from_utf8_lossy(v));
            }
            Some(s)
        }
        other => Some(other.display_as(exif::Tag::ImageDescription).to_string()),
    }
}

/// OME-XML: `<Pixels … PhysicalSizeX="0.385" PhysicalSizeXUnit="µm" …>`.
/// Returns high confidence. µm is the OME default when unit is absent.
fn parse_ome_xml(xml: &str) -> Option<CalibrationDto> {
    let physical_size_x = extract_attr_f64(xml, "PhysicalSizeX")?;
    let unit = extract_attr_str(xml, "PhysicalSizeXUnit").unwrap_or_else(|| "µm".to_string());
    let um_per_px = unit_to_um(physical_size_x, &unit)?;
    let px_per_um = 1.0 / um_per_px;
    if px_per_um > 0.0 && px_per_um < 1000.0 {
        Some(CalibrationDto {
            px_per_um,
            source: "omeXML".into(),
            confidence: Some("high".into()),
        })
    } else {
        None
    }
}

/// TIFF baseline XResolution + ResolutionUnit (2=inch, 3=cm). Rejects the
/// 72/96/300 dpi scanner defaults. Medium confidence.
fn parse_tiff_baseline(bytes: &[u8]) -> Option<CalibrationDto> {
    let exif = exif::Reader::new()
        .read_from_container(&mut Cursor::new(bytes))
        .ok()?;

    let x_res = exif
        .get_field(exif::Tag::XResolution, exif::In::PRIMARY)
        .and_then(field_to_f64)?;
    if x_res <= 0.0 {
        return None;
    }
    // ResolutionUnit: 1=none, 2=inch, 3=cm. Default 2 (inch) like the Swift code.
    let unit_raw = exif
        .get_field(exif::Tag::ResolutionUnit, exif::In::PRIMARY)
        .and_then(field_to_u32)
        .unwrap_or(2);

    let px_per_um = match unit_raw {
        2 => x_res / 25400.0, // inch → µm
        3 => x_res / 10000.0, // cm → µm
        _ => return None,      // no unit → unusable
    };
    if !(px_per_um > 0.001 && px_per_um < 1000.0) {
        return None;
    }
    // Reject exact scanner/printer default DPIs.
    let px_per_inch = if unit_raw == 2 { x_res } else { x_res * 2.54 };
    if px_per_inch == 72.0 || px_per_inch == 96.0 || px_per_inch == 300.0 {
        return None;
    }
    Some(CalibrationDto {
        px_per_um,
        source: "tiffBaseline".into(),
        confidence: Some("medium".into()),
    })
}

/// ImageJ ImageDescription: lines like `unit=micron` and `pixelWidth=0.385`.
/// `pixelWidth` is µm-per-pixel. Medium confidence.
fn parse_imagej(desc: &str) -> Option<CalibrationDto> {
    let mut pixel_width: Option<f64> = None;
    let mut unit = "µm".to_string();
    for line in desc.split('\n') {
        let kv = line.trim();
        let lower = kv.to_ascii_lowercase();
        if let Some(rest) = lower.strip_prefix("pixelwidth=") {
            if let Ok(v) = rest.trim().parse::<f64>() {
                pixel_width = Some(v);
            }
        }
        if lower.starts_with("unit=") {
            unit = kv["unit=".len()..].trim().to_string();
        }
    }
    let pw = pixel_width.filter(|v| *v > 0.0)?;
    let um_per_px = unit_to_um(pw, &unit)?;
    if um_per_px <= 0.0 {
        return None;
    }
    let px_per_um = 1.0 / um_per_px;
    if px_per_um > 0.001 && px_per_um < 1000.0 {
        Some(CalibrationDto {
            px_per_um,
            source: "imagej".into(),
            confidence: Some("medium".into()),
        })
    } else {
        None
    }
}

/// Olympus CellSens / BDP: `Calibration Value=0.385` + `Calibration Unit=µm`.
/// Calibration Value is µm-per-pixel. Low confidence.
fn parse_olympus(desc: &str) -> Option<CalibrationDto> {
    let mut cal_value: Option<f64> = None;
    let mut cal_unit = "µm".to_string();
    for line in desc.split('\n') {
        let kv = line.trim();
        let lower = kv.to_ascii_lowercase();
        if let Some(rest) = lower.strip_prefix("calibration value=") {
            if let Ok(v) = rest.trim().parse::<f64>() {
                cal_value = Some(v);
            }
        }
        if lower.starts_with("calibration unit=") {
            cal_unit = kv["calibration unit=".len()..].trim().to_string();
        }
    }
    let cv = cal_value.filter(|v| *v > 0.0)?;
    let um_per_px = unit_to_um(cv, &cal_unit).filter(|v| *v > 0.0)?;
    let px_per_um = 1.0 / um_per_px;
    if px_per_um > 0.001 && px_per_um < 1000.0 {
        Some(CalibrationDto {
            px_per_um,
            source: "olympus".into(),
            confidence: Some("low".into()),
        })
    } else {
        None
    }
}

/// Convert a physical size `value` in `unit` to µm. `None` for unknown units.
/// Mirrors `EXIFCalibration.convertToMicrons` (µm/um/micron→×1, nm→÷1e3,
/// pm→÷1e6, mm→×1e3, cm→×1e4, m→×1e6).
fn unit_to_um(value: f64, unit: &str) -> Option<f64> {
    match unit.trim().to_ascii_lowercase().as_str() {
        "µm" | "um" | "micron" | "microns" => Some(value),
        "nm" => Some(value / 1000.0),
        "pm" => Some(value / 1_000_000.0),
        "mm" => Some(value * 1000.0),
        "cm" => Some(value * 10000.0),
        "m" => Some(value * 1_000_000.0),
        _ => None,
    }
}

// --- tiny attribute + field extraction helpers -----------------------------

/// Extract a numeric XML attribute value: `Name="123.4"` → 123.4.
fn extract_attr_f64(xml: &str, name: &str) -> Option<f64> {
    extract_attr_str(xml, name).and_then(|s| s.trim().parse::<f64>().ok())
}

/// Extract a string XML attribute value: `Name="foo"` → "foo". Tolerates
/// arbitrary whitespace around `=` and single/absent quoting variations by
/// scanning for the `name` token then the next quoted run.
fn extract_attr_str(xml: &str, name: &str) -> Option<String> {
    let key = format!("{name}");
    let mut search_from = 0usize;
    while let Some(rel) = xml[search_from..].find(&key) {
        let at = search_from + rel;
        // Ensure it's a standalone attribute name (preceded by whitespace / start).
        let ok_boundary = at == 0
            || xml[..at]
                .chars()
                .last()
                .map(|c| c.is_whitespace())
                .unwrap_or(true);
        let after = &xml[at + key.len()..];
        let after_trim = after.trim_start();
        if ok_boundary && after_trim.starts_with('=') {
            let after_eq = after_trim[1..].trim_start();
            if let Some(rest) = after_eq.strip_prefix('"') {
                if let Some(end) = rest.find('"') {
                    return Some(rest[..end].to_string());
                }
            }
        }
        search_from = at + key.len();
    }
    None
}

/// A RATIONAL/other numeric EXIF field as f64 (takes the first component).
fn field_to_f64(field: &exif::Field) -> Option<f64> {
    match &field.value {
        exif::Value::Rational(v) => v.first().map(|r| r.to_f64()),
        exif::Value::SRational(v) => v.first().map(|r| r.to_f64()),
        exif::Value::Float(v) => v.first().map(|x| *x as f64),
        exif::Value::Double(v) => v.first().copied(),
        exif::Value::Long(v) => v.first().map(|x| *x as f64),
        exif::Value::Short(v) => v.first().map(|x| *x as f64),
        _ => None,
    }
}

/// A short/long EXIF field as u32 (takes the first component).
fn field_to_u32(field: &exif::Field) -> Option<u32> {
    match &field.value {
        exif::Value::Short(v) => v.first().map(|x| *x as u32),
        exif::Value::Long(v) => v.first().copied(),
        _ => None,
    }
}
