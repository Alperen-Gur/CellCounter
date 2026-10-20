//! Installed-app CLI/MCP entry before Tauri creates a window or library database.
use std::ffi::OsString;
use std::path::PathBuf;
use std::process::{Command, Stdio};

fn application_data() -> Result<PathBuf, String> {
    #[cfg(windows)]
    let parent = std::env::var_os("APPDATA").map(PathBuf::from).ok_or("Windows APPDATA is unavailable")?;
    #[cfg(target_os = "macos")]
    let parent = std::env::var_os("HOME").map(PathBuf::from).ok_or("The user home directory is unavailable")?.join("Library/Application Support");
    #[cfg(all(not(windows), not(target_os = "macos")))]
    let parent = std::env::var_os("XDG_DATA_HOME").map(PathBuf::from).or_else(|| std::env::var_os("HOME").map(|home| PathBuf::from(home).join(".local/share")))
        .ok_or("The user application data directory is unavailable")?;
    if !parent.is_absolute() { return Err("Application data must be an absolute directory".into()); }
    Ok(parent.join("com.alperengur.cellcounter"))
}
pub(crate) fn interpreter(store: &crate::paths::FileStore) -> Result<PathBuf, String> {
    let path = store.workbench_python();
    if path.is_file() { Ok(path) } else {
        Err("Install or repair the Workbench runtime from CellCounter → Workbench → AI agent access. Existing model environments are preserved; CLI/MCP never installs a runtime automatically.".into())
    }
}

#[cfg(windows)]
fn attach_parent_console_if_needed() {
    // MCP inherits real pipe handles; never replace them by attaching a console.
    #[link(name = "kernel32")]
    extern "system" { fn GetStdHandle(kind: u32) -> *mut std::ffi::c_void; fn AttachConsole(pid: u32) -> i32; }
    unsafe { let output = GetStdHandle(-11i32 as u32); if output.is_null() || output as isize == -1 { let _ = AttachConsole(u32::MAX); } }
}

pub fn run_if_requested() -> Option<i32> {
    let mut args = std::env::args_os().skip(1);
    if args.next().as_deref() != Some(std::ffi::OsStr::new("--workbench")) { return None; }
    #[cfg(windows)] attach_parent_console_if_needed();
    let arguments: Vec<OsString> = args.collect();
    let result = (|| -> Result<i32, String> {
        let store = crate::paths::FileStore::existing(application_data()?);
        let python = interpreter(&store)?;
        let runtime = crate::env::staging::snapshot(&store.python_dir())?;
        let executable = std::env::current_exe().map_err(|error| error.to_string())?;
        let resources = executable.parent().ok_or("Installed executable has no resource directory")?;
        let mut command = Command::new(python);
        command.arg("-B").arg(runtime.join("workbench.py"));
        if !arguments.iter().any(|value| value == "--omero-profiles" || value.to_string_lossy().starts_with("--omero-profiles=")) && store.root().is_dir() {
            command.arg("--omero-profiles").arg(store.root().join("omero-profiles.json"));
        }
        if let Some(manifest) = crate::env::microscopy::snapshot_from_resources(resources, &store.python_dir())? {
            let root = manifest.parent().ok_or("Microscopy runtime has no parent")?;
            command.arg("--microscopy-node").arg(root.join(if cfg!(windows) { "node/node.exe" } else { "node/node" }))
                .arg("--microscopy-runtime").arg(root);
        }
        command.args(arguments).current_dir(runtime).env_remove("NODE_OPTIONS").env_remove("NODE_PATH")
            .env_remove("PYTHONPATH").env_remove("PYTHONHOME")
            .stdin(Stdio::inherit()).stdout(Stdio::inherit()).stderr(Stdio::inherit());
        let status = command.status().map_err(|error| format!("Could not launch the installed Workbench runtime: {error}"))?;
        Ok(status.code().unwrap_or(1))
    })();
    Some(match result { Ok(code) => code, Err(error) => { eprintln!("CellCounter Workbench: {error}"); 1 } })
}
