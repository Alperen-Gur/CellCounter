//! Browser-readable derivatives for existing imports. Never rewrite an analysis
//! source or accept an arbitrary filesystem path from the webview.

use std::path::{Path, PathBuf};
use image::ImageDecoder;
use rusqlite::OptionalExtension;
use tauri::State;
use crate::db::repo::{Db, row_to_image};
use super::importer::{validate_decoded_pixel_budget, write_thumbnail};

// A grid can request many missing thumbnails at once. Bound actual pixel
// materialization independently of Tokio's blocking-worker pool size.
static PREVIEW_SLOTS: tokio::sync::Semaphore = tokio::sync::Semaphore::const_new(1);

#[tauri::command]
pub async fn repair_image_preview(db: State<'_, Db>, path: String) -> Result<String, String> {
    let requested = Path::new(&path);
    let id = requested.file_stem().and_then(|name| name.to_str())
        .and_then(|name| uuid::Uuid::parse_str(name).ok())
        .ok_or("This preview does not belong to an imported image.")?.to_string();
    let image = {
        let conn = db.connection()?;
        conn.query_row("SELECT * FROM images WHERE id = ?1", [&id],
            |row| row_to_image(row, db.store()))
            .optional().map_err(|error| error.to_string())?
            .ok_or("The image was removed from the library.")?
    };
    let thumbnail = requested == Path::new(&image.thumb_path);
    if !thumbnail && requested != Path::new(&image.stored_path) {
        return Err("This preview path does not match the imported image.".into());
    }
    let destination = if thumbnail {
        db.store().thumbs_dir().join(format!("{id}.preview.jpg"))
    } else {
        db.store().images_dir().join(format!("{id}.preview.png"))
    };
    let permit = PREVIEW_SLOTS.acquire().await.map_err(|error| error.to_string())?;
    tokio::task::spawn_blocking(move || {
        // Keep the slot until decoding actually finishes, even if the caller
        // navigates away and drops its command future in the meantime.
        let _permit = permit;
        prepare_preview(Path::new(&image.stored_path), &destination, thumbnail)
    }).await.map_err(|error| format!("Preview worker failed: {error}"))?
}

fn prepare_preview(source: &Path, destination: &Path, thumbnail: bool) -> Result<String, String> {
    // Imports are immutable. A successful derivative can be reused without
    // decoding another full-resolution image when a second card requests it.
    if destination.is_file() {
        return Ok(destination.to_string_lossy().into_owned());
    }
    let reader = image::ImageReader::open(source)
        .and_then(|reader| reader.with_guessed_format())
        .map_err(|error| format!("Could not read the imported image: {error}"))?;
    let decoder = reader.into_decoder().map_err(|error| error.to_string())?;
    let (width, height) = decoder.dimensions();
    validate_decoded_pixel_budget(width, height, decoder.total_bytes())?;
    let decoded = image::DynamicImage::from_decoder(decoder).map_err(|error| error.to_string())?;
    let temporary: PathBuf = destination.with_extension("preview-tmp");
    let result = if thumbnail {
        write_thumbnail(&decoded, &temporary, 256)
    } else {
        // PNG is understood by WebView2 even when the source was TIFF or an
        // unusual JPEG/BMP variant. Dimensions and pixel coordinates are kept;
        // this 8-bit derivative is used only for display, never measurements.
        decoded.into_rgba8().save_with_format(&temporary, image::ImageFormat::Png)
            .map_err(|error| error.to_string())
    }.and_then(|()| std::fs::rename(&temporary, destination).map_err(|error| error.to_string()));
    if let Err(error) = result {
        let _ = std::fs::remove_file(&temporary);
        return Err(format!("Could not create an image preview: {error}"));
    }
    Ok(destination.to_string_lossy().into_owned())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn tiff_preview_and_missing_thumbnail_preserve_source_bytes_and_dimensions() {
        let root = std::env::temp_dir().join(format!("preview-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(&root).unwrap();
        let source = root.join("source.tiff");
        image::RgbImage::from_pixel(48, 32, image::Rgb([20_u8, 80, 150]))
            .save_with_format(&source, image::ImageFormat::Tiff).unwrap();
        let original = std::fs::read(&source).unwrap();
        let display = root.join("preview.png");
        let thumbnail = root.join("thumbnail.jpg");
        prepare_preview(&source, &display, false).unwrap();
        prepare_preview(&source, &thumbnail, true).unwrap();
        assert_eq!(image::image_dimensions(&display).unwrap(), (48, 32));
        assert!(image::image_dimensions(&thumbnail).unwrap().0 <= 256);
        assert_eq!(std::fs::read(&source).unwrap(), original);
        std::fs::remove_dir_all(root).unwrap();
    }
}
