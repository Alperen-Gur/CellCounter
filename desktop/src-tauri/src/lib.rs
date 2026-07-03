//! lib.rs — Tauri backend entry point.
//!
//! Declares every backend module and registers ALL `#[command]`s (persistence,
//! image import, detection transport, uv env, and the export/seg-npy stubs) in
//! one `invoke_handler`. Manages the two pieces of shared state — the SQLite
//! `Db` and the `SidecarManager` — and, on startup, opens the store, runs the
//! orphan sweep for stray sidecar processes, and stages the python project.
//!
//! Module map (ARCHITECTURE.md §2):
//!   paths      — app-data dir tree (FileStore analogue)
//!   db         — schema / models / repo (PersistencePort commands)
//!   images     — importer (decode + sha256 + thumbnail + EXIF probe)
//!   detection  — ipc / sidecar (transport) + seg_npy stub
//!   env        — uv bootstrap (install streaming + availability)
//!   export     — roi / csv / provenance / report stubs

pub mod db;
pub mod detection;
pub mod env;
pub mod images;
pub mod paths;
pub mod proc;

use detection::sidecar::SidecarManager;

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        .plugin(tauri_plugin_opener::init())
        // Native file dialogs + fs access for the Home / seg-npy "Choose…" CTAs.
        // The frontend loads the matching JS plugins lazily and degrades to
        // drag-and-drop when absent; these init the backend halves.
        .plugin(tauri_plugin_dialog::init())
        .plugin(tauri_plugin_fs::init())
        .manage(SidecarManager::new())
        .setup(|app| {
            let handle = app.handle().clone();

            // Open (or create) the SQLite store and register it as managed
            // state. A hard failure here is fatal — persistence is required.
            if let Err(e) = db::repo::open_and_manage(&handle) {
                eprintln!("[startup] failed to open store.sqlite: {e}");
                return Err(e.into());
            }

            // Reap orphaned sidecar processes from a previous crashed session,
            // off the main thread so a slow `ps` can never block window
            // creation (mirrors ChildProcessTracker.installLifecycle). Scope the
            // sweep to THIS app's staged python dir so we only ever kill our own
            // sidecars (never an unrelated process that mentions the basename).
            if let Ok(store) = paths::FileStore::from_app(&handle) {
                let python_dir = store.python_dir();
                std::thread::spawn(move || detection::sidecar::sweep_orphans(python_dir));
            }

            Ok(())
        })
        .invoke_handler(tauri::generate_handler![
            // ── persistence: batches ──
            db::repo::all_batches,
            db::repo::batch,
            db::repo::create_batch,
            db::repo::batches_matching,
            db::repo::delete_batch,
            db::repo::cleanup_empty_batches,
            // ── persistence: images ──
            db::repo::all_images,
            db::repo::image_matching_hash,
            db::repo::duplicate_groups,
            db::repo::delete_image,
            db::repo::attach_image_to_batch,
            db::repo::set_image_notes,
            db::repo::set_image_confidence_override,
            // ── persistence: detections & corrections ──
            db::repo::save_detection,
            db::repo::get_detection,
            db::repo::get_detections,
            db::repo::record_correction,
            // ── persistence: rois ──
            db::repo::rois,
            db::repo::save_roi,
            db::repo::delete_roi,
            // ── persistence: annotations ──
            db::repo::annotations,
            db::repo::add_annotation,
            db::repo::delete_annotation,
            db::repo::delete_all_annotations,
            // ── persistence: conditions ──
            db::repo::conditions,
            db::repo::create_condition,
            db::repo::rename_condition,
            db::repo::reorder_conditions,
            db::repo::delete_condition,
            // ── persistence: presets ──
            db::repo::calibration_presets,
            db::repo::upsert_calibration_preset,
            db::repo::delete_calibration_preset,
            db::repo::bin_presets,
            // ── persistence: counts / review / wipe ──
            db::repo::total_image_count,
            db::repo::total_batch_count,
            db::repo::uncorrected_cell_count,
            db::repo::wipe_all_user_data,
            // ── image import ──
            images::importer::import_image,
            images::importer::list_images_in_dir,
            // ── detection transport ──
            detection::sidecar::run_detection,
            detection::sidecar::cancel_detection,
            detection::sidecar::detection_availability,
            // ── seg-npy I/O (stub) ──
            detection::seg_npy::seg_npy_import,
            detection::seg_npy::seg_npy_export,
            // ── uv env ──
            env::uv::env_install,
            env::uv::env_availability,
            env::uv::env_uv_available,
            // ── export (stubs) ──
            export::roi::export_imagej_roi,
            export::csv::export_cells_csv,
            export::csv::export_batch_summary_csv,
            export::provenance::export_provenance,
            export::report::export_pdf_report,
        ])
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}

// `export` is declared after `run` so the `generate_handler!` macro above can
// still reference it (module items are order-independent in Rust).
pub mod export;
