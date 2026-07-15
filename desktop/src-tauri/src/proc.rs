//! proc.rs — cross-platform subprocess hardening helpers.
//!
//! Every Python / uv child we spawn from this GUI process must NOT pop a console
//! window on Windows. A packaged Tauri GUI has no attached console, so each
//! `python.exe` / `uv.exe` the app launches would flash a visible `conhost`
//! window that steals focus — the classic "this Tauri app is buggy on Windows"
//! symptom, made far worse by the one-shot detection path that spawns one
//! process per image (100+ flashes for a lab batch).
//!
//! The fix is the `CREATE_NO_WINDOW` process-creation flag (`0x08000000`). Both
//! `std::process::Command` and `tokio::process::Command` expose `creation_flags`
//! via their respective `std::os::windows::process::CommandExt`, so we provide a
//! tiny helper for each. On non-Windows both are no-ops.

/// `CREATE_NO_WINDOW` — suppresses the console window for a GUI-spawned child.
#[cfg(windows)]
const CREATE_NO_WINDOW: u32 = 0x08000000;

/// Apply `CREATE_NO_WINDOW` to a `tokio::process::Command` on Windows; no-op
/// elsewhere. Call right after `Command::new(...)` at every spawn site.
pub fn hide_console_tokio(cmd: &mut tokio::process::Command) {
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        cmd.creation_flags(CREATE_NO_WINDOW);
    }
    #[cfg(not(windows))]
    {
        let _ = cmd;
    }
}

/// Apply `CREATE_NO_WINDOW` to a `std::process::Command` on Windows; no-op
/// elsewhere. Same contract as [`hide_console_tokio`], for the synchronous
/// one-shot probes (e.g. reading a registry value via `reg query`).
pub fn hide_console_std(cmd: &mut std::process::Command) {
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        cmd.creation_flags(CREATE_NO_WINDOW);
    }
    #[cfg(not(windows))]
    {
        let _ = cmd;
    }
}
