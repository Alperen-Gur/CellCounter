//! Snapshot a release-staged pinned Node/JS runtime; never install or use PATH.
use serde::Deserialize;
use sha2::{Digest, Sha256};
use std::fs;
use std::io::{Read, Write};
use std::path::{Component, Path, PathBuf};
use std::sync::{Mutex, OnceLock};
use tauri::{AppHandle, Manager};

#[derive(Deserialize)]
struct Asset { path: String, sha256: String, bytes: u64 }
#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Manifest { schema_version: u32, node_version: String, entrypoint: String, node: Asset, files: Vec<Asset> }
static LOCK: Mutex<()> = Mutex::new(());
static SNAPSHOT: OnceLock<PathBuf> = OnceLock::new();

fn safe_path(root: &Path, name: &str) -> Result<PathBuf, String> {
    if name.contains(['\\', ':']) || name.is_empty() || Path::new(name).components().any(|part| !matches!(part, Component::Normal(_))) {
        return Err("The microscopy runtime contains an unsafe asset path.".into());
    }
    let mut current = root.to_path_buf();
    for component in Path::new(name).components() {
        current.push(component);
        if fs::symlink_metadata(&current).is_ok_and(|metadata| metadata.file_type().is_symlink()) {
            return Err("The microscopy runtime contains a symbolic link.".into());
        }
    }
    Ok(current)
}
fn file_hash(path: &Path) -> Result<String, String> {
    let mut stream = fs::File::open(path).map_err(|error| error.to_string())?;
    let mut hash = Sha256::new(); let mut buffer = [0u8; 1024 * 1024];
    loop { let length = stream.read(&mut buffer).map_err(|error| error.to_string())?; if length == 0 { break; } hash.update(&buffer[..length]); }
    Ok(format!("{:x}", hash.finalize()))
}
fn matches(path: &Path, asset: &Asset) -> bool {
    fs::metadata(path).is_ok_and(|metadata| metadata.is_file() && metadata.len() == asset.bytes)
        && file_hash(path).is_ok_and(|hash| hash == asset.sha256)
}

pub(crate) fn snapshot(app: &AppHandle, runtime_root: &Path) -> Result<Option<PathBuf>, String> {
    snapshot_from_resources(&app.path().resource_dir().map_err(|error| error.to_string())?, runtime_root)
}
pub(crate) fn snapshot_from_resources(resource_directory: &Path, runtime_root: &Path) -> Result<Option<PathBuf>, String> {
    if let Some(path) = SNAPSHOT.get() { return Ok(Some(path.clone())); }
    let _guard = LOCK.lock().map_err(|_| "Restart CellCounter to prepare the microscopy runtime.".to_string())?;
    if let Some(path) = SNAPSHOT.get() { return Ok(Some(path.clone())); }
    let source = resource_directory.join("microscopy-runtime");
    let manifest_path = source.join("microscopy-runtime.json");
    // Source/dev trees can use the canonical runtime's explicit configured manifest.
    // Release builds require staged assets in build.rs.
    if !manifest_path.is_file() { return Ok(None); }
    if fs::metadata(&manifest_path).map_err(|error| error.to_string())?.len() > 1024 * 1024 {
        return Err("The bundled microscopy runtime manifest exceeds its limit.".into());
    }
    let bytes = fs::read(&manifest_path).map_err(|error| error.to_string())?;
    let manifest: Manifest = serde_json::from_slice(&bytes).map_err(|error| format!("Invalid microscopy runtime manifest: {error}"))?;
    if manifest.schema_version != 1 || manifest.node_version != "24.22.0" || manifest.entrypoint != "microscopy-worker/worker.mjs"
        || manifest.files.len() > 100 || !manifest.files.iter().any(|file| file.path == manifest.entrypoint) {
        return Err("The bundled microscopy runtime is incompatible. Reinstall the matching release.".into());
    }
    let destination = runtime_root.join("m").join(format!("{:x}", Sha256::digest(&bytes)));
    fs::create_dir_all(&destination).map_err(|error| error.to_string())?;
    let mut total = 0u64; let mut names = std::collections::BTreeSet::new();
    for asset in manifest.files.iter().chain(std::iter::once(&manifest.node)) {
        total = total.checked_add(asset.bytes).ok_or("Microscopy runtime byte count overflow")?;
        if total > 256 * 1024 * 1024 || asset.sha256.len() != 64 || !asset.sha256.bytes().all(|byte| byte.is_ascii_hexdigit()) || !names.insert(&asset.path) {
            return Err("The microscopy runtime has invalid or duplicate assets.".into());
        }
        let input = safe_path(&source, &asset.path)?; let output = safe_path(&destination, &asset.path)?;
        if !matches(&input, asset) { return Err(format!("Bundled microscopy asset {} failed its integrity check. Reinstall CellCounter.", asset.path)); }
        if matches(&output, asset) { continue; }
        fs::create_dir_all(output.parent().ok_or("Missing runtime asset parent")?).map_err(|error| error.to_string())?;
        let temporary = output.with_extension(format!("{}.staging", uuid::Uuid::new_v4()));
        let mut incoming = fs::File::open(&input).map_err(|error| error.to_string())?;
        let mut outgoing = fs::OpenOptions::new().write(true).create_new(true).open(&temporary).map_err(|error| error.to_string())?;
        std::io::copy(&mut incoming, &mut outgoing).map_err(|error| error.to_string())?;
        outgoing.flush().map_err(|error| error.to_string())?; outgoing.sync_all().map_err(|error| error.to_string())?; drop(outgoing);
        if !matches(&temporary, asset) { return Err("A microscopy runtime asset changed while staging.".into()); }
        // Preserve executable mode on Unix hosts; the fixed Node binary is
        // otherwise copied as a non-executable data file by OpenOptions.
        #[cfg(unix)]
        fs::set_permissions(&temporary, fs::metadata(&input).map_err(|error| error.to_string())?.permissions())
            .map_err(|error| error.to_string())?;
        fs::rename(&temporary, &output).map_err(|error| format!("Could not publish microscopy runtime: {error}"))?;
    }
    let target_manifest = destination.join("microscopy-runtime.json");
    if fs::read(&target_manifest).ok().as_deref() != Some(bytes.as_slice()) {
        let temporary = destination.join(format!("{}.manifest-staging", uuid::Uuid::new_v4()));
        let mut output = fs::OpenOptions::new().write(true).create_new(true).open(&temporary).map_err(|error| error.to_string())?;
        output.write_all(&bytes).map_err(|error| error.to_string())?; output.sync_all().map_err(|error| error.to_string())?; drop(output);
        fs::rename(&temporary, &target_manifest).map_err(|error| error.to_string())?;
    }
    let _ = SNAPSHOT.set(target_manifest.clone());
    Ok(Some(target_manifest))
}
