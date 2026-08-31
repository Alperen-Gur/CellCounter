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

use std::fmt::Write as _;
use std::io::{BufReader, Cursor, Read, Seek, SeekFrom, Write as IoWrite};
use std::process::Stdio;
use std::time::Duration;

use image::{GenericImageView, ImageDecoder};
use sha2::{Digest, Sha256};
use tauri::{AppHandle, State};
use tokio::process::Command;
use uuid::Uuid;

use crate::db::models::{CalibrationDto, ImageDto};
use crate::db::repo::{self, Db};

/// Accepted extensions, lowercased (mirrors `ImageLoader.supported`).
const SUPPORTED: &[&str] = &["jpg", "jpeg", "png", "tif", "tiff", "bmp"];
/// Discover these files too, then return an actionable error from import.
/// Omitting them from folder walking made a selected vendor folder appear
/// empty, which is materially worse than an explicit compatibility message.
const RECOGNIZED_VENDOR: &[&str] = &["nd2", "czi", "lif", "oir", "vsi"];
const PREPARE_TIMEOUT: Duration = Duration::from_secs(20 * 60);
const MAX_PREPARE_OUTPUT_BYTES: usize = 1024 * 1024;
/// One GiB worst-case RGBA materialization. Check dimensions before `image::open`
/// so a tiny compressed/decompression-bomb input cannot exhaust the process.
const MAX_STANDARD_DECODED_PIXELS: u64 = 268_435_456;
const MAX_STANDARD_DECODED_BYTES: u64 = 1024 * 1024 * 1024;
/// OME XML can be sizeable, but calibration needs only the Pixels attributes.
/// Refuse pathological TIFF descriptions rather than allocating attacker-sized
/// tag payloads during a metadata-only probe.
const MAX_IMAGE_DESCRIPTION_BYTES: u64 = 1024 * 1024;
const MAX_TIFF_IFD_ENTRIES: u16 = 4096;

/// Recursively list supported image files under a directory. Backs the
/// "Choose folder…" flow: directory walking happens in Rust (reliable, and
/// unaffected by the fs plugin's path scoping). Returns sorted absolute paths.
#[tauri::command]
pub fn list_images_in_dir(dir: String) -> Result<Vec<String>, String> {
    // Guard against symlink loops (e.g. `dir/self -> dir`, common in synced /
    // backup folders): never follow a symlinked directory, cap recursion depth,
    // and track visited canonical paths so a real dir cannot be revisited via a
    // second path. Without this an unbounded recursion overflows the stack and
    // aborts the whole app process.
    const MAX_DEPTH: usize = 64;

    fn walk(
        dir: &std::path::Path,
        out: &mut Vec<String>,
        visited: &mut std::collections::HashSet<std::path::PathBuf>,
        depth: usize,
    ) {
        if depth > MAX_DEPTH {
            return;
        }
        // Canonicalize so the same real directory reached via different paths is
        // only walked once; if canonicalization fails, fall back to the raw path.
        let key = std::fs::canonicalize(dir).unwrap_or_else(|_| dir.to_path_buf());
        if !visited.insert(key) {
            return;
        }
        let Ok(entries) = std::fs::read_dir(dir) else {
            return;
        };
        for entry in entries.flatten() {
            let path = entry.path();
            // `file_type()` does NOT follow symlinks, so a symlinked directory
            // reports as a symlink here and is skipped for recursion.
            let is_real_dir = entry
                .file_type()
                .map(|ft| ft.is_dir())
                .unwrap_or(false);
            if is_real_dir {
                walk(&path, out, visited, depth + 1);
            } else if let Some(ext) = path.extension().and_then(|e| e.to_str()) {
                let ext = ext.to_ascii_lowercase();
                if SUPPORTED.contains(&ext.as_str()) || RECOGNIZED_VENDOR.contains(&ext.as_str()) {
                    if let Some(s) = path.to_str() {
                        out.push(s.to_string());
                    }
                }
            }
        }
    }
    let mut out = Vec::new();
    let mut visited = std::collections::HashSet::new();
    walk(std::path::Path::new(&dir), &mut out, &mut visited, 0);
    out.sort();
    Ok(out)
}

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
pub async fn import_image(
    app: AppHandle,
    db: State<'_, Db>,
    source_path: String,
) -> Result<ImportResult, String> {
    let src = std::path::Path::new(&source_path);

    let ext = src
        .extension()
        .and_then(|e| e.to_str())
        .unwrap_or("")
        .to_ascii_lowercase();
    if RECOGNIZED_VENDOR.contains(&ext.as_str()) {
        return import_vendor_image(&app, &db, &source_path, &ext).await;
    }
    if !SUPPORTED.contains(&ext.as_str()) {
        // Mirrors ImageLoadError.unsupportedFormat.
        return Err(format!(
            "Unsupported image format \".{ext}\". CellCounter accepts JPEG, PNG, and TIFF."
        ));
    }

    // Standard decoding + hashing + thumbnail generation is blocking CPU/disk
    // work. Keep it off Tokio's async executor so a large TIFF import cannot
    // stall unrelated Tauri commands or progress/cancel events.
    let store = db.store().clone();
    let worker_source = source_path.clone();
    let prepared = tokio::task::spawn_blocking(move || {
        prepare_standard_image(&worker_source, &ext, &store)
    })
    .await
    .map_err(|error| format!("Image import worker failed: {error}"))??;

    let imported_at = repo::now_iso8601();
    let image = repo::insert_image_row(
        &db,
        &prepared.id,
        &prepared.file_name,
        &source_path,
        prepared.width_px,
        prepared.height_px,
        &imported_at,
        Some(&prepared.file_hash),
        None,
        None,
    )
    .map_err(|error| {
        let _ = std::fs::remove_file(&prepared.stored_path);
        let _ = std::fs::remove_file(&prepared.thumbnail_path);
        error
    })?;

    Ok(ImportResult {
        image,
        calibration: prepared.calibration,
    })
}

struct PreparedStandard {
    id: String,
    file_name: String,
    width_px: i64,
    height_px: i64,
    file_hash: String,
    calibration: Option<CalibrationDto>,
    stored_path: std::path::PathBuf,
    thumbnail_path: std::path::PathBuf,
}

fn prepare_standard_image(
    source_path: &str,
    ext: &str,
    store: &crate::paths::FileStore,
) -> Result<PreparedStandard, String> {
    let src = std::path::Path::new(source_path);
    let id = Uuid::new_v4().to_string();
    let file_name = src
        .file_name()
        .and_then(|name| name.to_str())
        .unwrap_or("image")
        .to_string();
    let stored_path = store.image_path(&id, ext);
    let thumbnail_path = store.thumb_path(&id);

    // Stream the app-owned copy and hash through a fixed 1 MiB buffer. This
    // avoids retaining the compressed source bytes alongside the decoded image.
    let file_hash = copy_and_hash(src, &stored_path)
        .map_err(|error| format!("File copy/hash error: {error}"))?;

    // Parse only bounded metadata from a seekable buffered file. TIFF probing
    // reads the header/IFD and at most a capped description; JPEG EXIF is bounded
    // by the format's segment size. The compressed file is never `read` whole.
    let calibration = if matches!(ext, "jpg" | "jpeg" | "tif" | "tiff") {
        probe_calibration_file(&stored_path, ext)
    } else {
        None
    };

    // Build the decoder and inspect its exact output size before it can
    // materialize pixels. This handles 16-bit/float TIFFs more accurately than
    // width×height alone while retaining a hard decompression-bomb pixel cap.
    let reader = image::ImageReader::open(&stored_path)
        .and_then(|reader| reader.with_guessed_format())
        .map_err(|_| {
            let _ = std::fs::remove_file(&stored_path);
            "Couldn't read image dimensions.".to_string()
        })?;
    let decoder = reader.into_decoder().map_err(|_| {
        let _ = std::fs::remove_file(&stored_path);
        "Couldn't read image dimensions.".to_string()
    })?;
    let (width_px, height_px) = decoder.dimensions();
    validate_decoded_pixel_budget(width_px, height_px, decoder.total_bytes()).map_err(|error| {
        let _ = std::fs::remove_file(&stored_path);
        error
    })?;
    let decoded = image::DynamicImage::from_decoder(decoder).map_err(|_| {
        let _ = std::fs::remove_file(&stored_path);
        "Couldn't decode the image.".to_string()
    })?;
    if let Err(error) = write_thumbnail(&decoded, &thumbnail_path, 256) {
        eprintln!("[importer] warning: thumbnail write failed for {id}: {error}");
    }

    Ok(PreparedStandard {
        id,
        file_name,
        width_px: width_px as i64,
        height_px: height_px as i64,
        file_hash,
        calibration,
        stored_path,
        thumbnail_path,
    })
}

fn validate_decoded_pixel_budget(
    width: u32,
    height: u32,
    decoded_bytes: u64,
) -> Result<(), String> {
    let pixels = u64::from(width)
        .checked_mul(u64::from(height))
        .ok_or_else(|| "Image dimensions overflow the decoded-pixel budget.".to_string())?;
    if width == 0
        || height == 0
        || pixels > MAX_STANDARD_DECODED_PIXELS
        || decoded_bytes > MAX_STANDARD_DECODED_BYTES
    {
        return Err(format!(
            "Image is too large to decode safely ({width}×{height}, {decoded_bytes} decoded bytes; limits are {MAX_STANDARD_DECODED_PIXELS} pixels and {MAX_STANDARD_DECODED_BYTES} bytes)."
        ));
    }
    Ok(())
}

#[derive(serde::Deserialize)]
struct PreparedVendor {
    width: i64,
    height: i64,
    pixel_size_um: Option<f64>,
    source_format: String,
}

/// Import a proprietary microscope container without flattening away the data
/// used by detection and quantitative assays. The original is copied into the
/// app-owned `Originals` directory; a lossless max-projected PNG is generated
/// separately for the React canvas and ordinary exports.
async fn import_vendor_image(
    app: &AppHandle,
    db: &Db,
    source_path: &str,
    ext: &str,
) -> Result<ImportResult, String> {
    let src = std::path::Path::new(source_path);
    if !src.is_file() {
        return Err("The selected microscopy container is not a readable file.".to_string());
    }

    let store = db.store();
    crate::env::uv::stage_python_project(app, &store)?;
    let python = store.venv_io_python();
    if !python.exists() {
        return Err(
            "Microscopy-container import needs the isolated reader runtime. Reinstall one of the three built-in models, then retry."
                .to_string(),
        );
    }
    let script = store.python_script("image_prepare.py");
    if !script.exists() {
        return Err("The microscopy image preparation helper is not staged. Reinstall the selected model and retry.".to_string());
    }

    let id = Uuid::new_v4().to_string();
    let file_name = src
        .file_name()
        .and_then(|name| name.to_str())
        .unwrap_or("microscopy-image")
        .to_string();
    let display_path = store.image_path(&id, "png");
    let thumbnail_path = store.thumb_path(&id);
    let original_path = store.original_path(&id, ext);
    let analysis_path = store.analysis_path(&id);

    let mut command = Command::new(&python);
    command
        .arg(&script)
        .args(["--image", source_path])
        .arg("--display-output")
        .arg(&display_path)
        .arg("--thumbnail-output")
        .arg(&thumbnail_path)
        .arg("--analysis-output")
        .arg(&analysis_path)
        .args(["--z-project", "max"])
        .current_dir(store.python_dir())
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .kill_on_drop(true);
    crate::proc::hide_console_tokio(&mut command);

    let output = tokio::time::timeout(PREPARE_TIMEOUT, command.output())
        .await
        .map_err(|_| "Microscopy-container preparation timed out after 20 minutes.".to_string())?
        .map_err(|error| format!("Could not start the microscopy reader: {error}"))?;
    if output.stdout.len() > MAX_PREPARE_OUTPUT_BYTES
        || output.stderr.len() > MAX_PREPARE_OUTPUT_BYTES
    {
        cleanup_import_files(&display_path, &thumbnail_path, &original_path, &analysis_path);
        return Err("The microscopy reader returned unexpectedly large diagnostic output.".to_string());
    }
    let stdout = String::from_utf8(output.stdout)
        .map_err(|_| "The microscopy reader returned invalid text output.".to_string())?;
    if !output.status.success() {
        cleanup_import_files(&display_path, &thumbnail_path, &original_path, &analysis_path);
        let payload = serde_json::from_str::<serde_json::Value>(stdout.trim()).ok();
        let error = payload
            .as_ref()
            .and_then(|value| value.get("error"))
            .and_then(serde_json::Value::as_str)
            .unwrap_or("Microscopy-container preparation failed");
        let hint = payload
            .as_ref()
            .and_then(|value| value.get("hint"))
            .and_then(serde_json::Value::as_str)
            .unwrap_or("");
        let stderr = String::from_utf8_lossy(&output.stderr);
        let detail = stderr
            .lines()
            .rev()
            .find(|line| !line.trim().is_empty())
            .unwrap_or("");
        return Err([error, hint, detail]
            .into_iter()
            .filter(|part| !part.trim().is_empty())
            .collect::<Vec<_>>()
            .join(": "));
    }
    let prepared: PreparedVendor = serde_json::from_str(stdout.trim()).map_err(|error| {
        cleanup_import_files(&display_path, &thumbnail_path, &original_path, &analysis_path);
        format!("Could not read microscopy preparation metadata: {error}")
    })?;
    if prepared.width <= 0 || prepared.height <= 0 {
        cleanup_import_files(&display_path, &thumbnail_path, &original_path, &analysis_path);
        return Err("The microscopy reader returned invalid image dimensions.".to_string());
    }

    let file_hash = copy_and_hash(src, &original_path).map_err(|error| {
        cleanup_import_files(&display_path, &thumbnail_path, &original_path, &analysis_path);
        format!("Could not preserve the original microscopy container: {error}")
    })?;
    let calibration = vendor_calibration(&prepared.source_format, prepared.pixel_size_um);
    let imported_at = repo::now_iso8601();
    let analysis_path_string = analysis_path.to_string_lossy().into_owned();
    let image = repo::insert_image_row(
        db,
        &id,
        &file_name,
        source_path,
        prepared.width,
        prepared.height,
        &imported_at,
        Some(&file_hash),
        Some("png"),
        Some(&analysis_path_string),
    )
    .map_err(|error| {
        cleanup_import_files(&display_path, &thumbnail_path, &original_path, &analysis_path);
        error
    })?;

    Ok(ImportResult { image, calibration })
}

fn vendor_calibration(source_format: &str, pixel_size_um: Option<f64>) -> Option<CalibrationDto> {
    pixel_size_um
        .filter(|value| value.is_finite() && *value > 0.0)
        .map(|pixel_size_um| CalibrationDto {
            px_per_um: 1.0 / pixel_size_um,
            source: match source_format {
                "czi" => "zeiss",
                "nd2" => "nikon",
                "lif" => "leica",
                "oir" | "vsi" => "olympus",
                _ => "omeXML",
            }
            .to_string(),
            confidence: Some("high".to_string()),
        })
}

fn cleanup_import_files(
    display_path: &std::path::Path,
    thumbnail_path: &std::path::Path,
    original_path: &std::path::Path,
    analysis_path: &std::path::Path,
) {
    let _ = std::fs::remove_file(display_path);
    let _ = std::fs::remove_file(thumbnail_path);
    let _ = std::fs::remove_file(original_path);
    let _ = std::fs::remove_file(analysis_path);
}

/// Copy a potentially multi-gigabyte container with constant memory while
/// computing the same whole-file SHA-256 used by duplicate detection.
fn copy_and_hash(src: &std::path::Path, dest: &std::path::Path) -> std::io::Result<String> {
    let mut reader = std::io::BufReader::new(std::fs::File::open(src)?);
    let mut writer = std::io::BufWriter::new(std::fs::File::create(dest)?);
    let mut hasher = Sha256::new();
    let mut buffer = vec![0_u8; 1024 * 1024];
    loop {
        let read = reader.read(&mut buffer)?;
        if read == 0 {
            break;
        }
        hasher.update(&buffer[..read]);
        writer.write_all(&buffer[..read])?;
    }
    writer.flush()?;
    let digest = hasher.finalize();
    let mut out = String::with_capacity(digest.len() * 2);
    for byte in digest {
        let _ = write!(out, "{byte:02x}");
    }
    Ok(out)
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

#[derive(Default)]
struct CalibrationMetadata {
    image_description: Option<String>,
    x_resolution: Option<f64>,
    resolution_unit: Option<u32>,
}

#[derive(Clone, Copy)]
enum TiffEndian {
    Little,
    Big,
}

impl TiffEndian {
    fn u16(self, bytes: &[u8]) -> u16 {
        let pair = [bytes[0], bytes[1]];
        match self {
            Self::Little => u16::from_le_bytes(pair),
            Self::Big => u16::from_be_bytes(pair),
        }
    }

    fn u32(self, bytes: &[u8]) -> u32 {
        let quad = [bytes[0], bytes[1], bytes[2], bytes[3]];
        match self {
            Self::Little => u32::from_le_bytes(quad),
            Self::Big => u32::from_be_bytes(quad),
        }
    }
}

fn probe_calibration_file(path: &std::path::Path, ext: &str) -> Option<CalibrationDto> {
    let file = std::fs::File::open(path).ok()?;
    let mut reader = BufReader::with_capacity(64 * 1024, file);
    probe_calibration(&mut reader, matches!(ext, "tif" | "tiff"))
}

/// Probe calibration from a buffered, seekable source without retaining the
/// compressed image. `is_tiff` selects the bounded classic-TIFF IFD reader;
/// other supported callers use the format-bounded EXIF segment reader.
pub fn probe_calibration<R: std::io::BufRead + Seek>(
    reader: &mut R,
    is_tiff: bool,
) -> Option<CalibrationDto> {
    let metadata = if is_tiff {
        read_classic_tiff_metadata(reader)?
    } else {
        read_exif_metadata(reader)?
    };
    calibration_from_metadata(&metadata)
}

/// Apply the frozen calibration priority to already-bounded metadata.
fn calibration_from_metadata(metadata: &CalibrationMetadata) -> Option<CalibrationDto> {
    let image_description = metadata.image_description.as_deref();

    // 1. OME-XML in ImageDescription (highest confidence).
    if let Some(desc) = image_description {
        if desc.contains("<OME") || desc.contains("<Pixels") {
            if let Some(r) = parse_ome_xml(desc) {
                return Some(r);
            }
        }
    }

    // 2. TIFF baseline XResolution / ResolutionUnit.
    if let Some(r) = parse_tiff_baseline(metadata) {
        return Some(r);
    }

    // 3. ImageJ metadata in ImageDescription.
    if let Some(desc) = image_description {
        if desc.starts_with("ImageJ=") {
            if let Some(r) = parse_imagej(desc) {
                return Some(r);
            }
        }
    }

    // 4. Olympus "Calibration Value" in ImageDescription (low confidence).
    if let Some(desc) = image_description {
        if let Some(r) = parse_olympus(desc) {
            return Some(r);
        }
    }

    None
}

/// JPEG EXIF segments are length-prefixed by a 16-bit field, so the library can
/// scan the file without retaining the compressed image. Cap copied description
/// text anyway so the same invariant is explicit for every container.
fn read_exif_metadata<R: std::io::BufRead + Seek>(reader: &mut R) -> Option<CalibrationMetadata> {
    let exif = exif::Reader::new().read_from_container(reader).ok()?;
    let image_description = exif
        .get_field(exif::Tag::ImageDescription, exif::In::PRIMARY)
        .and_then(|field| match &field.value {
            exif::Value::Ascii(parts) => {
                let total = parts.iter().map(Vec::len).sum::<usize>();
                if total as u64 > MAX_IMAGE_DESCRIPTION_BYTES {
                    return None;
                }
                let mut text = String::with_capacity(total);
                for part in parts {
                    text.push_str(&String::from_utf8_lossy(part));
                }
                Some(text.trim_end_matches('\0').to_string())
            }
            other => {
                let text = other.display_as(exif::Tag::ImageDescription).to_string();
                (text.len() as u64 <= MAX_IMAGE_DESCRIPTION_BYTES).then_some(text)
            }
        });
    Some(CalibrationMetadata {
        image_description,
        x_resolution: exif
            .get_field(exif::Tag::XResolution, exif::In::PRIMARY)
            .and_then(field_to_f64),
        resolution_unit: exif
            .get_field(exif::Tag::ResolutionUnit, exif::In::PRIMARY)
            .and_then(field_to_u32),
    })
}

fn read_exact_at<R: Read + Seek>(
    reader: &mut R,
    file_len: u64,
    offset: u64,
    buffer: &mut [u8],
) -> std::io::Result<()> {
    offset
        .checked_add(buffer.len() as u64)
        .filter(|end| *end <= file_len)
        .ok_or_else(|| std::io::Error::new(std::io::ErrorKind::UnexpectedEof, "TIFF offset"))?;
    reader.seek(SeekFrom::Start(offset))?;
    reader.read_exact(buffer)
}

/// Read only classic TIFF header/IFD fields needed for calibration. Unlike
/// `kamadak-exif::read_from_container` (which reads a TIFF to EOF), this performs
/// O(IFD entries) tiny seeks and at most one capped description allocation.
fn read_classic_tiff_metadata<R: Read + Seek>(reader: &mut R) -> Option<CalibrationMetadata> {
    let file_len = reader.seek(SeekFrom::End(0)).ok()?;
    let mut header = [0_u8; 8];
    read_exact_at(reader, file_len, 0, &mut header).ok()?;
    let endian = match &header[..2] {
        b"II" => TiffEndian::Little,
        b"MM" => TiffEndian::Big,
        _ => return None,
    };
    if endian.u16(&header[2..4]) != 42 {
        return None;
    }
    let ifd_offset = u64::from(endian.u32(&header[4..8]));
    let mut count_bytes = [0_u8; 2];
    read_exact_at(reader, file_len, ifd_offset, &mut count_bytes).ok()?;
    let entry_count = endian.u16(&count_bytes);
    if entry_count > MAX_TIFF_IFD_ENTRIES {
        return None;
    }

    let mut metadata = CalibrationMetadata::default();
    for index in 0..entry_count {
        let entry_offset = ifd_offset
            .checked_add(2)?
            .checked_add(u64::from(index) * 12)?;
        let mut entry = [0_u8; 12];
        read_exact_at(reader, file_len, entry_offset, &mut entry).ok()?;
        let tag = endian.u16(&entry[0..2]);
        let field_type = endian.u16(&entry[2..4]);
        let value_count = endian.u32(&entry[4..8]);
        let value_or_offset = endian.u32(&entry[8..12]);

        match (tag, field_type) {
            // ImageDescription, ASCII.
            (270, 2) if value_count > 0 => {
                if u64::from(value_count) > MAX_IMAGE_DESCRIPTION_BYTES {
                    continue;
                }
                let count = value_count as usize;
                let bytes = if count <= 4 {
                    entry[8..8 + count].to_vec()
                } else {
                    let mut bytes = vec![0_u8; count];
                    if read_exact_at(
                        reader,
                        file_len,
                        u64::from(value_or_offset),
                        &mut bytes,
                    )
                    .is_err()
                    {
                        continue;
                    }
                    bytes
                };
                let end = bytes.iter().position(|byte| *byte == 0).unwrap_or(bytes.len());
                metadata.image_description =
                    Some(String::from_utf8_lossy(&bytes[..end]).into_owned());
            }
            // XResolution, RATIONAL.
            (282, 5) if value_count > 0 => {
                let mut rational = [0_u8; 8];
                if read_exact_at(
                    reader,
                    file_len,
                    u64::from(value_or_offset),
                    &mut rational,
                )
                .is_err()
                {
                    continue;
                }
                let numerator = endian.u32(&rational[..4]);
                let denominator = endian.u32(&rational[4..]);
                if denominator != 0 {
                    metadata.x_resolution = Some(numerator as f64 / denominator as f64);
                }
            }
            // ResolutionUnit, SHORT. A single SHORT is inline in classic TIFF.
            (296, 3) if value_count > 0 => {
                metadata.resolution_unit = Some(u32::from(endian.u16(&entry[8..10])));
            }
            _ => {}
        }
    }
    Some(metadata)
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
fn parse_tiff_baseline(metadata: &CalibrationMetadata) -> Option<CalibrationDto> {
    let x_res = metadata.x_resolution?;
    if x_res <= 0.0 {
        return None;
    }
    // ResolutionUnit: 1=none, 2=inch, 3=cm. Default 2 (inch) like the Swift code.
    let unit_raw = metadata.resolution_unit.unwrap_or(2);

    let px_per_um = match unit_raw {
        2 => x_res / 25400.0, // inch → µm
        3 => x_res / 10000.0, // cm → µm
        _ => return None,      // no unit → unusable
    };
    if !(px_per_um > 0.001 && px_per_um < 1000.0) {
        return None;
    }
    // Reject the scanner/printer default DPIs. Compare with a small epsilon
    // rather than `==`: for cm-unit TIFFs `px_per_inch` is derived as
    // `x_res * 2.54`, which essentially never lands on 72/96/300 exactly, so a
    // float-equality test would silently let a bogus scanner-default calibration
    // through on the cm path.
    let px_per_inch = if unit_raw == 2 { x_res } else { x_res * 2.54 };
    const DPI_EPS: f64 = 0.5;
    if [72.0, 96.0, 300.0]
        .iter()
        .any(|d| (px_per_inch - d).abs() < DPI_EPS)
    {
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

#[cfg(test)]
mod tests {
    use super::*;

    struct TrackingCursor {
        inner: Cursor<Vec<u8>>,
        max_read_request: usize,
        bytes_read: usize,
    }

    impl TrackingCursor {
        fn new(bytes: Vec<u8>) -> Self {
            Self {
                inner: Cursor::new(bytes),
                max_read_request: 0,
                bytes_read: 0,
            }
        }
    }

    impl Read for TrackingCursor {
        fn read(&mut self, buffer: &mut [u8]) -> std::io::Result<usize> {
            self.max_read_request = self.max_read_request.max(buffer.len());
            let read = self.inner.read(buffer)?;
            self.bytes_read += read;
            Ok(read)
        }
    }

    impl Seek for TrackingCursor {
        fn seek(&mut self, position: SeekFrom) -> std::io::Result<u64> {
            self.inner.seek(position)
        }
    }

    #[test]
    fn vendor_allowlist_and_calibration_sources_are_explicit() {
        assert_eq!(RECOGNIZED_VENDOR, &["nd2", "czi", "lif", "oir", "vsi"]);
        let cases = [
            ("czi", "zeiss"),
            ("nd2", "nikon"),
            ("lif", "leica"),
            ("oir", "olympus"),
            ("vsi", "olympus"),
        ];
        for (format, expected_source) in cases {
            let calibration = vendor_calibration(format, Some(0.5)).expect("calibration");
            assert_eq!(calibration.source, expected_source);
            assert_eq!(calibration.px_per_um, 2.0);
        }
        assert!(vendor_calibration("czi", None).is_none());
        assert!(vendor_calibration("czi", Some(f64::NAN)).is_none());
    }

    #[test]
    fn streaming_copy_preserves_bytes_and_hash() {
        let root = std::env::temp_dir().join(format!("cellcounter-copy-test-{}", Uuid::new_v4()));
        std::fs::create_dir_all(&root).expect("test dir");
        let source = root.join("source.bin");
        let dest = root.join("dest.bin");
        std::fs::write(&source, b"abc").expect("source");
        let hash = copy_and_hash(&source, &dest).expect("copy");
        assert_eq!(hash, "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad");
        assert_eq!(std::fs::read(&dest).expect("dest"), b"abc");
        std::fs::remove_dir_all(root).expect("cleanup");
    }

    #[test]
    fn tiff_probe_refuses_oversized_description_without_reading_payload() {
        let mut bytes = Vec::new();
        bytes.extend_from_slice(b"II");
        bytes.extend_from_slice(&42_u16.to_le_bytes());
        bytes.extend_from_slice(&8_u32.to_le_bytes());
        bytes.extend_from_slice(&1_u16.to_le_bytes());
        bytes.extend_from_slice(&270_u16.to_le_bytes());
        bytes.extend_from_slice(&2_u16.to_le_bytes());
        bytes.extend_from_slice(&((MAX_IMAGE_DESCRIPTION_BYTES as u32) + 1).to_le_bytes());
        bytes.extend_from_slice(&64_u32.to_le_bytes());

        let mut reader = TrackingCursor::new(bytes);
        let metadata = read_classic_tiff_metadata(&mut reader).expect("bounded metadata");
        assert!(metadata.image_description.is_none());
        assert!(reader.max_read_request <= 12);
        assert_eq!(reader.bytes_read, 22, "header + IFD count + one entry only");
    }

    #[test]
    fn tiff_probe_preserves_ome_calibration_from_bounded_description() {
        let description = b"<OME><Pixels PhysicalSizeX=\"0.5\" PhysicalSizeXUnit=\"um\"/></OME>\0";
        let description_offset = 26_u32;
        let mut bytes = Vec::new();
        bytes.extend_from_slice(b"II");
        bytes.extend_from_slice(&42_u16.to_le_bytes());
        bytes.extend_from_slice(&8_u32.to_le_bytes());
        bytes.extend_from_slice(&1_u16.to_le_bytes());
        bytes.extend_from_slice(&270_u16.to_le_bytes());
        bytes.extend_from_slice(&2_u16.to_le_bytes());
        bytes.extend_from_slice(&(description.len() as u32).to_le_bytes());
        bytes.extend_from_slice(&description_offset.to_le_bytes());
        bytes.extend_from_slice(&0_u32.to_le_bytes());
        bytes.extend_from_slice(description);

        let mut reader = TrackingCursor::new(bytes);
        let metadata = read_classic_tiff_metadata(&mut reader).expect("TIFF metadata");
        let calibration = calibration_from_metadata(&metadata).expect("OME calibration");
        assert_eq!(calibration.source, "omeXML");
        assert_eq!(calibration.px_per_um, 2.0);
        assert!(reader.max_read_request <= description.len());
    }

    #[test]
    fn decoded_pixel_budget_rejects_before_materialization() {
        assert!(validate_decoded_pixel_budget(16_384, 16_384, 1024).is_ok());
        assert!(validate_decoded_pixel_budget(16_385, 16_384, 1024).is_err());
        assert!(validate_decoded_pixel_budget(10, 10, MAX_STANDARD_DECODED_BYTES + 1).is_err());
        assert!(validate_decoded_pixel_budget(0, 10, 0).is_err());
    }
}
