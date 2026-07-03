//! paths.rs — on-disk layout under the OS app-data dir.
//!
//! Rust analogue of `CellCounting/CellCounting/Persistence/FileStore.swift`.
//! Owns the storage root and the sub-directory tree the whole backend writes
//! into. Every file operation that isn't SQLite goes through a [`FileStore`].
//!
//! Storage root (ARCHITECTURE.md §3.8): the OS app-data dir — which Tauri
//! already namespaces by the bundle identifier (`com.alperengur.cellcounter`) —
//! with a `CellCounter/` sub-directory appended, so the on-disk layout is:
//!   - Windows: `%APPDATA%\com.alperengur.cellcounter\CellCounter\`
//!   - macOS:   `~/Library/Application Support/com.alperengur.cellcounter/CellCounter/`
//!   - Linux:   `~/.local/share/com.alperengur.cellcounter/CellCounter/`
//!
//! (Tests / the importer may pass a plain parent path to [`FileStore::new`], in
//! which case the root is simply `<that path>/CellCounter/`.)
//!
//! Tree:
//!   <root>/
//!     store.sqlite            fresh SQLite DB (NOT the Swift SwiftData store — decision (a))
//!     Images/<uuid>.<ext>     imported originals
//!     Thumbnails/<uuid>.jpg   256px JPEG previews
//!     Models/                 model checkpoints (future train-from-GUI seam)
//!     Exports/                export artefacts (ROI zips, CSV, PDF)
//!     python/                 uv project (.venv lives here) + staged sidecar scripts
//!       .venv/                uv-created virtual environment
//!
//! NOTE (decision (a)): the cross-platform app lives under its OWN
//! identifier-namespaced app-data dir (see above), so it does NOT share the
//! Swift app's `~/Library/Application Support/CellCounter/` directory. We always
//! create a FRESH `store.sqlite` from `db::schema` DDL and never attach to the
//! SwiftData file — even if a user runs both, the two stores stay independent.

use std::fs;
use std::path::{Path, PathBuf};

use tauri::{AppHandle, Manager};

/// Resolves and owns the app-data directory tree.
#[derive(Clone, Debug)]
pub struct FileStore {
    root: PathBuf,
}

impl FileStore {
    /// Build a [`FileStore`] rooted at `<app_data_dir>/CellCounter` and ensure
    /// every sub-directory exists. `app_data_dir` is normally
    /// `AppHandle::path().app_data_dir()`; a plain path is accepted so the
    /// importer/tests can construct one without a running Tauri app.
    pub fn new(app_data_parent: impl AsRef<Path>) -> std::io::Result<Self> {
        let root = app_data_parent.as_ref().join("CellCounter");
        let store = Self { root };
        store.ensure_tree()?;
        Ok(store)
    }

    /// Convenience constructor from a Tauri [`AppHandle`]. Uses the OS-correct
    /// app-data dir (already namespaced by the bundle identifier) and appends a
    /// `CellCounter/` sub-directory, giving the tree documented at the module
    /// level. This root is distinct from the Swift app's storage location.
    pub fn from_app(app: &AppHandle) -> Result<Self, String> {
        let base = app
            .path()
            .app_data_dir()
            .map_err(|e| format!("could not resolve app-data dir: {e}"))?;
        Self::new(base).map_err(|e| format!("could not create storage tree: {e}"))
    }

    /// Create root + all sub-directories (idempotent).
    fn ensure_tree(&self) -> std::io::Result<()> {
        for dir in [
            self.root.clone(),
            self.images_dir(),
            self.thumbs_dir(),
            self.models_dir(),
            self.exports_dir(),
            self.python_dir(),
        ] {
            fs::create_dir_all(dir)?;
        }
        Ok(())
    }

    // --- roots -------------------------------------------------------------

    /// `<app-data>/CellCounter/`.
    pub fn root(&self) -> &Path {
        &self.root
    }

    /// The fresh SQLite database file. Decision (a): this is OUR store, created
    /// from `db::schema` DDL — never the SwiftData `store.sqlite`.
    pub fn db_path(&self) -> PathBuf {
        self.root.join("store.sqlite")
    }

    pub fn images_dir(&self) -> PathBuf {
        self.root.join("Images")
    }
    pub fn thumbs_dir(&self) -> PathBuf {
        self.root.join("Thumbnails")
    }
    pub fn models_dir(&self) -> PathBuf {
        self.root.join("Models")
    }
    pub fn exports_dir(&self) -> PathBuf {
        self.root.join("Exports")
    }

    // --- python / uv -------------------------------------------------------

    /// `<root>/python` — the uv project root; staged sidecar scripts + `.venv`.
    pub fn python_dir(&self) -> PathBuf {
        self.root.join("python")
    }

    /// `<root>/python/.venv` — the uv-managed virtual environment.
    pub fn venv_dir(&self) -> PathBuf {
        self.python_dir().join(".venv")
    }

    /// Path to the venv Python interpreter. On Windows the launcher lives in
    /// `Scripts\python.exe`; on Unix it's `bin/python`.
    pub fn venv_python(&self) -> PathBuf {
        if cfg!(windows) {
            self.venv_dir().join("Scripts").join("python.exe")
        } else {
            self.venv_dir().join("bin").join("python")
        }
    }

    /// A staged sidecar script inside the python dir (e.g.
    /// `cellpose_detect.py`, `_export_imagej_roi.py`).
    pub fn python_script(&self, name: &str) -> PathBuf {
        self.python_dir().join(name)
    }

    // --- per-image helpers -------------------------------------------------

    /// `Images/<uuid>.<ext>` — extension is lowercased to match import-time
    /// storage regardless of the user's casing (mirrors `ImageRecord.storedURL`).
    pub fn image_path(&self, id: &str, ext: &str) -> PathBuf {
        let ext = ext.trim_start_matches('.').to_ascii_lowercase();
        let ext = if ext.is_empty() { "tif".to_string() } else { ext };
        self.images_dir().join(format!("{id}.{ext}"))
    }

    /// `Thumbnails/<uuid>.jpg`.
    pub fn thumb_path(&self, id: &str) -> PathBuf {
        self.thumbs_dir().join(format!("{id}.jpg"))
    }
}
