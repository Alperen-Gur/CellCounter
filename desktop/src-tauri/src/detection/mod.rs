//! detection — Python sidecar transport (ARCHITECTURE.md §3.1) + seg-npy I/O seam.
//!
//! * [`ipc`]     — Rust↔Python wire structs + frontend DTOs (serde boundary)
//! * [`sidecar`] — `SidecarManager`: spawn / stream / cancel + orphan sweep
//! * [`seg_npy`] — stub `_seg.npy` import/export (feature `seg-npy-io`)

pub mod ipc;
pub mod seg_npy;
pub mod sidecar;
