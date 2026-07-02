//! export — result export writers (feature `export`). ALL STUBS in the kernel.
//!
//! Real signatures + registered `#[command]`s so the app compiles and the
//! `export` feature engineer only fills bodies later:
//!   * [`roi`]        — ImageJ RoiSet.zip via `_export_imagej_roi.py`
//!   * [`csv`]        — cells / batch-summary / comparison / annotations CSV
//!   * [`provenance`] — provenance JSON sidecar
//!   * [`report`]     — PDF report

pub mod csv;
pub mod provenance;
pub mod report;
pub mod roi;
