//! paths.rs — on-disk layout under the OS app-data dir.
//!
//! Rust analogue of `CellCounting/CellCounting/Persistence/FileStore.swift`.
//! Owns the storage root and the sub-directory tree the whole backend writes
//! into. Every file operation that isn't SQLite goes through a [`FileStore`].
//!
//! Storage root (ARCHITECTURE.md §3.8): the OS app-data dir — which Tauri
//! already namespaces by the bundle identifier (`com.alperengur.cellcounter`).
//! Under it we keep two SIBLING roots:
//!   * `CellCounter/` — the data root (DB, images, thumbnails, models, exports).
//!   * `py/`          — the Python env root (uv project + `.venv`). Kept as a
//!                      short sibling on purpose: the venv buries deep dependency
//!                      files (torch under `.venv\Lib\site-packages\…`) that,
//!                      stacked on a longer base, overflow Windows' legacy
//!                      260-char `MAX_PATH` and fail `uv sync`. Dropping the
//!                      redundant `CellCounter\` segment (the app-data dir is
//!                      already identifier-namespaced) and shortening
//!                      `python`→`py` reclaims ~16 chars on the exact path that
//!                      overflows, so a normal Windows user installs without any
//!                      registry edit. The data root is deliberately left at
//!                      `CellCounter/` so no existing DB/image data is stranded.
//!
//! On-disk layout:
//!   - Windows: `%APPDATA%\com.alperengur.cellcounter\{CellCounter,py}\`
//!   - macOS:   `~/Library/Application Support/com.alperengur.cellcounter/{CellCounter,py}/`
//!   - Linux:   `~/.local/share/com.alperengur.cellcounter/{CellCounter,py}/`
//!
//! (Tests / the importer may pass a plain parent path to [`FileStore::new`], in
//! which case the roots are simply `<that path>/CellCounter/` and `<that path>/py/`.)
//!
//! Tree:
//!   <app-data>/
//!     CellCounter/              data root
//!       store.sqlite            fresh SQLite DB (NOT the Swift SwiftData store — decision (a))
//!       Images/<uuid>.<ext>     imported originals
//!       Thumbnails/<uuid>.jpg   256px JPEG previews
//!       Models/                 model checkpoints (future train-from-GUI seam)
//!       Exports/                export artefacts (ROI zips, CSV, PDF)
//!     py/                       uv project (.venv lives here) + staged sidecar scripts
//!       .venv/                  uv-created virtual environment
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
    /// Data root — `<app-data>/CellCounter/` (DB, images, thumbnails, models,
    /// exports).
    root: PathBuf,
    /// Python env root — `<app-data>/py/`, a SHORT sibling of `root` holding the
    /// uv project + `.venv`. Kept separate and short so the venv's deep
    /// `site-packages` tree stays under Windows' 260-char `MAX_PATH` (module doc).
    python_root: PathBuf,
}

impl FileStore {
    /// Build a [`FileStore`] with the data root at `<app_data_parent>/CellCounter`
    /// and the Python env root at the short sibling `<app_data_parent>/py`, and
    /// ensure every sub-directory exists. `app_data_parent` is normally
    /// `AppHandle::path().app_data_dir()`; a plain path is accepted so the
    /// importer/tests can construct one without a running Tauri app.
    pub fn new(app_data_parent: impl AsRef<Path>) -> std::io::Result<Self> {
        let parent = app_data_parent.as_ref();
        let store = Self {
            root: parent.join("CellCounter"),
            python_root: parent.join("py"),
        };
        store.ensure_tree()?;
        Ok(store)
    }

    /// Convenience constructor from a Tauri [`AppHandle`]. Uses the OS-correct
    /// app-data dir (already namespaced by the bundle identifier) and lays down
    /// the two sibling roots — `CellCounter/` (data) and `py/` (Python env) —
    /// giving the tree documented at the module level. These roots are distinct
    /// from the Swift app's storage location.
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
            self.analysis_dir(),
            self.originals_dir(),
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
    pub fn analysis_dir(&self) -> PathBuf {
        self.root.join("Analysis")
    }
    pub fn originals_dir(&self) -> PathBuf {
        self.root.join("Originals")
    }
    pub fn models_dir(&self) -> PathBuf {
        self.root.join("Models")
    }
    pub fn exports_dir(&self) -> PathBuf {
        self.root.join("Exports")
    }

    // --- python / uv -------------------------------------------------------

    /// `<app-data>/py` — the uv project root; staged sidecar scripts + `.venv`.
    /// A short sibling of the data root (NOT `<root>/python`) so the venv's deep
    /// dependency tree stays under Windows' `MAX_PATH` (see module doc).
    pub fn python_dir(&self) -> PathBuf {
        self.python_root.clone()
    }

    /// `<app-data>/py/.venv` — the uv-managed virtual environment.
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

    /// `<app-data>/py/.venv4` — the ISOLATED uv-managed venv for the
    /// Cellpose-SAM (`cellpose>=4`) family. A SHORT *sibling* of `.venv` (not
    /// nested under it) so its own deep dependency tree (torch under
    /// `.venv4\Lib\site-packages\…`) stays under Windows' `MAX_PATH` just like
    /// the base venv (module doc). Kept separate so the cyto3 (`cellpose>=3,<4`)
    /// env in `.venv` is never disturbed — mirrors the native app's `venv4/`.
    pub fn venv4_dir(&self) -> PathBuf {
        self.python_dir().join(".venv4")
    }

    /// Path to the venv4 Python interpreter (same layout as [`venv_python`]:
    /// `Scripts\python.exe` on Windows, `bin/python3` on Unix — `uv venv`
    /// creates both `python` and `python3`, and the native cp4 availability
    /// probe prefers `python3`).
    pub fn venv4_python(&self) -> PathBuf {
        if cfg!(windows) {
            self.venv4_dir().join("Scripts").join("python.exe")
        } else {
            self.venv4_dir().join("bin").join("python3")
        }
    }

    /// `<app-data>/py/.venvsd` — isolated StarDist/TensorFlow environment.
    /// Keeping TensorFlow out of the Cellpose 3 and 4 environments avoids
    /// dependency resolution changing either detector underneath the user.
    pub fn venv_stardist_dir(&self) -> PathBuf {
        self.python_dir().join(".venvsd")
    }

    /// Python executable for the isolated StarDist environment.
    pub fn venv_stardist_python(&self) -> PathBuf {
        if cfg!(windows) {
            self.venv_stardist_dir().join("Scripts").join("python.exe")
        } else {
            self.venv_stardist_dir().join("bin").join("python")
        }
    }

    /// Isolated NumPy-2 microscopy reader environment. Keeping proprietary
    /// readers here prevents their dependency bounds from mutating any model
    /// runtime (notably current `oirfile`, which requires NumPy 2).
    pub fn venv_io_dir(&self) -> PathBuf {
        self.python_dir().join(".venvio")
    }

    pub fn venv_io_python(&self) -> PathBuf {
        if cfg!(windows) {
            self.venv_io_dir().join("Scripts").join("python.exe")
        } else {
            self.venv_io_dir().join("bin").join("python")
        }
    }

    /// Exact cache directory created by `StarDist2D.from_pretrained` with the
    /// app-scoped `KERAS_HOME` used by install and inference.
    pub fn stardist_weights_dir(&self) -> PathBuf {
        self.models_dir()
            .join("keras")
            .join("models")
            .join("StarDist2D")
            .join("2D_versatile_fluo")
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

    /// Lossless app-owned copy of a proprietary/multi-channel source.
    pub fn original_path(&self, id: &str, ext: &str) -> PathBuf {
        let ext = ext.trim_start_matches('.').to_ascii_lowercase();
        self.originals_dir().join(format!("{id}.{ext}"))
    }

    /// Lossless normalized multi-channel TIFF consumed by all model/assay
    /// environments after a proprietary source has been decoded once.
    pub fn analysis_path(&self, id: &str) -> PathBuf {
        self.analysis_dir().join(format!("{id}.tiff"))
    }

    /// `Thumbnails/<uuid>.jpg`.
    pub fn thumb_path(&self, id: &str) -> PathBuf {
        self.thumbs_dir().join(format!("{id}.jpg"))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn model_environments_are_isolated_and_paths_are_platform_native() {
        let parent = std::env::temp_dir().join(format!(
            "cellcounter-path-test-{}",
            uuid::Uuid::new_v4()
        ));
        let store = FileStore::new(&parent).expect("create test store");
        assert_eq!(store.venv_dir(), parent.join("py").join(".venv"));
        assert_eq!(store.venv4_dir(), parent.join("py").join(".venv4"));
        assert_eq!(
            store.venv_stardist_dir(),
            parent.join("py").join(".venvsd")
        );
        assert_ne!(store.venv_python(), store.venv4_python());
        assert_ne!(store.venv_python(), store.venv_stardist_python());
        assert_ne!(store.venv_python(), store.venv_io_python());
        assert_eq!(
            store.stardist_weights_dir(),
            parent
                .join("CellCounter")
                .join("Models")
                .join("keras")
                .join("models")
                .join("StarDist2D")
                .join("2D_versatile_fluo")
        );
        assert!(store.images_dir().is_dir());
        assert!(store.analysis_dir().is_dir());
        assert!(store.originals_dir().is_dir());
        assert!(store.thumbs_dir().is_dir());
        std::fs::remove_dir_all(&parent).expect("remove test store");
    }

    #[test]
    fn image_path_normalizes_extension_without_touching_filename() {
        let parent = std::env::temp_dir().join(format!(
            "cellcounter-path-test-{}",
            uuid::Uuid::new_v4()
        ));
        let store = FileStore::new(&parent).expect("create test store");
        assert_eq!(
            store.image_path("stable-id", ".TIFF"),
            parent.join("CellCounter").join("Images").join("stable-id.tiff")
        );
        std::fs::remove_dir_all(&parent).expect("remove test store");
    }
}
