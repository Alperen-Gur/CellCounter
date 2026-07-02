//! db/schema.rs — SQLite DDL + migrations.
//!
//! The 10 SwiftData `@Model` records (`Persistence/Records.swift`) map 1:1 to
//! these tables (ARCHITECTURE.md §3.8). Conventions:
//!   * IDs are `TEXT` UUIDs
//!   * JSON blobs stored as `TEXT`
//!   * timestamps ISO-8601 `TEXT`
//!   * booleans `INTEGER 0/1`
//!
//! Decision (a): this DDL builds a FRESH `store.sqlite`; we never attach to the
//! Swift SwiftData file. The column shapes are nevertheless kept 1:1 with the
//! SwiftData records so the format stays interchangeable on disk.
//!
//! Cascade rules: deleting a batch cascades to its images; deleting an image
//! cascades to its detection (1:1), rois, and ground-truth annotations;
//! deleting a detection cascades to its corrections. FKs require
//! `PRAGMA foreign_keys = ON`, set on every connection in `repo.rs`.

use rusqlite::Connection;

/// Full schema DDL. Executed once inside a transaction at DB open.
/// `IF NOT EXISTS` everywhere so re-opening an existing store is a no-op.
pub const SCHEMA_SQL: &str = r#"
-- ── batches ────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS batches (
  id                TEXT PRIMARY KEY,
  name              TEXT NOT NULL,
  created_at        TEXT NOT NULL,
  display_name      TEXT NOT NULL,
  model_id          TEXT NOT NULL,
  px_per_um         REAL NOT NULL,
  thresholds_json   TEXT NOT NULL,             -- JSON [Double]
  condition         TEXT,
  px_per_um_source  TEXT
);

-- ── images ─────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS images (
  id                  TEXT PRIMARY KEY,
  file_name           TEXT NOT NULL,
  original_path       TEXT NOT NULL,
  width_px            INTEGER NOT NULL,
  height_px           INTEGER NOT NULL,
  imported_at         TEXT NOT NULL,
  confidence_override REAL,
  file_hash           TEXT,
  notes               TEXT,
  batch_id            TEXT REFERENCES batches(id) ON DELETE CASCADE
);
CREATE INDEX IF NOT EXISTS idx_images_hash ON images(file_hash);

-- ── detections (1:1 per image, enforced by unique index) ───────────────────
CREATE TABLE IF NOT EXISTS detections (
  id                TEXT PRIMARY KEY,
  image_id          TEXT NOT NULL REFERENCES images(id) ON DELETE CASCADE,
  detector_id       TEXT NOT NULL,
  ran_at            TEXT NOT NULL,
  cells_json        TEXT NOT NULL,             -- JSON [CellPayload] (contour flattened)
  min_confidence    REAL NOT NULL,
  image_stats_json  TEXT                       -- JSON {focus_score, illumination_residual, …}
);
CREATE UNIQUE INDEX IF NOT EXISTS idx_detection_image ON detections(image_id);

-- ── corrections (append-only correction log; train-from-GUI seam) ──────────
CREATE TABLE IF NOT EXISTS corrections (
  id             TEXT PRIMARY KEY,
  detection_id   TEXT NOT NULL REFERENCES detections(id) ON DELETE CASCADE,
  kind           TEXT NOT NULL,                -- add|remove|move|resize|accept|manual
  cell_id        TEXT NOT NULL,
  cx             REAL NOT NULL,
  cy             REAL NOT NULL,
  diameter       REAL NOT NULL,
  created_at     TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_corrections_detection ON corrections(detection_id);

-- ── rois ───────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS rois (
  id          TEXT PRIMARY KEY,
  image_id    TEXT NOT NULL REFERENCES images(id) ON DELETE CASCADE,
  kind        TEXT NOT NULL,                   -- include|exclude
  shape       TEXT NOT NULL,                   -- rect|ellipse
  x           REAL,
  y           REAL,
  width       REAL,
  height      REAL,
  created_at  TEXT NOT NULL,
  name        TEXT
);
CREATE INDEX IF NOT EXISTS idx_rois_image ON rois(image_id);

-- ── ground-truth annotations ───────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS ground_truth_annotations (
  id          TEXT PRIMARY KEY,
  image_id    TEXT NOT NULL REFERENCES images(id) ON DELETE CASCADE,
  cx          REAL NOT NULL,
  cy          REAL NOT NULL,
  diameter    REAL,
  created_at  TEXT NOT NULL,
  note        TEXT
);
CREATE INDEX IF NOT EXISTS idx_gt_image ON ground_truth_annotations(image_id);

-- ── conditions ─────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS conditions (
  id          TEXT PRIMARY KEY,
  name        TEXT NOT NULL UNIQUE,
  color       TEXT NOT NULL,
  created_at  TEXT NOT NULL,
  "order"     INTEGER NOT NULL
);

-- ── calibration presets ────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS calibration_presets (
  id          TEXT PRIMARY KEY,
  name        TEXT NOT NULL,
  px_per_um   REAL NOT NULL,
  is_default  INTEGER NOT NULL
);

-- ── bin presets ────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS bin_presets (
  id               TEXT PRIMARY KEY,
  name             TEXT NOT NULL,
  thresholds_json  TEXT NOT NULL
);

-- ── model versions (future train-from-GUI seam; unused in v1, created now) ──
CREATE TABLE IF NOT EXISTS model_versions (
  id                       TEXT PRIMARY KEY,
  model_id                 TEXT NOT NULL,
  version                  INTEGER NOT NULL,
  created_at               TEXT NOT NULL,
  trained_on_images        INTEGER NOT NULL,
  trained_on_corrections   INTEGER NOT NULL,
  checkpoint_path          TEXT NOT NULL,
  metrics_json             TEXT NOT NULL
);
"#;

/// Create the whole schema (idempotent). Called once at DB open, after the
/// per-connection pragmas are set.
pub fn create_schema(conn: &Connection) -> rusqlite::Result<()> {
    conn.execute_batch(SCHEMA_SQL)
}

/// Seed the workflow-config tables the Swift app seeds on first launch
/// (`Repositories.seedDefaultsIfNeeded`): built-in calibration presets, the
/// three bin presets, and the default "Control" condition. Each seed is guarded
/// by a count check so it fires exactly once and never re-seeds after the user
/// deletes rows.
pub fn seed_defaults(conn: &Connection) -> rusqlite::Result<()> {
    use uuid::Uuid;

    let now = crate::db::repo::now_iso8601();

    // Calibration presets — Olympus IX-family objectives (mirror CalibrationPreset.builtIn).
    let calib_count: i64 =
        conn.query_row("SELECT COUNT(*) FROM calibration_presets", [], |r| r.get(0))?;
    if calib_count == 0 {
        // name, px/µm, is_default. 10× is the app default (px/µm 2.6).
        let presets: &[(&str, f64, bool)] = &[
            ("Olympus IX73 5×", 1.3, false),
            ("Olympus IX73 10×", 2.6, true),
            ("Olympus IX73 20×", 5.2, false),
            ("Olympus IX73 40×", 10.4, false),
        ];
        for (name, px_per_um, is_default) in presets {
            conn.execute(
                "INSERT INTO calibration_presets (id, name, px_per_um, is_default)
                 VALUES (?1, ?2, ?3, ?4)",
                rusqlite::params![
                    Uuid::new_v4().to_string(),
                    name,
                    px_per_um,
                    if *is_default { 1 } else { 0 }
                ],
            )?;
        }
    }

    // Bin presets.
    let bin_count: i64 = conn.query_row("SELECT COUNT(*) FROM bin_presets", [], |r| r.get(0))?;
    if bin_count == 0 {
        let bins: &[(&str, &str)] = &[
            ("Keratinocytes — early passage", "[18,26]"),
            ("Keratinocytes — late passage", "[22,34]"),
            ("Fibroblasts", "[24,38]"),
        ];
        for (name, thresholds_json) in bins {
            conn.execute(
                "INSERT INTO bin_presets (id, name, thresholds_json) VALUES (?1, ?2, ?3)",
                rusqlite::params![Uuid::new_v4().to_string(), name, thresholds_json],
            )?;
        }
    }

    // Default "Control" condition (seeded once).
    let cond_count: i64 = conn.query_row("SELECT COUNT(*) FROM conditions", [], |r| r.get(0))?;
    if cond_count == 0 {
        conn.execute(
            "INSERT INTO conditions (id, name, color, created_at, \"order\")
             VALUES (?1, ?2, ?3, ?4, ?5)",
            rusqlite::params![Uuid::new_v4().to_string(), "Control", "#4db3a8", now, 0],
        )?;
    }

    Ok(())
}
