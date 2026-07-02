//! db — SQLite persistence layer (ARCHITECTURE.md §3.8).
//!
//! * [`schema`] — DDL + migrations + first-run seeding
//! * [`models`] — Rust row structs mirroring the TS DTOs + the persisted
//!   `CellPayload` ⇄ `CellDto` mapping
//! * [`repo`]   — the `Db` managed state + every PersistencePort `#[command]`

pub mod models;
pub mod repo;
pub mod schema;
