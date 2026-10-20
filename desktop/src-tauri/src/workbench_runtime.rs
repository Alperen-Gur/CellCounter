//! Explicit runtime readiness and installed-binary connection configuration.
use serde_json::{json, Value};
use std::{path::PathBuf, process::Stdio, time::Duration};
use tauri::{AppHandle, Manager};
use tokio::{io::AsyncReadExt, process::Command};

const PROBE: &str = r#"
import contextlib, importlib, importlib.metadata, io, json, sys
packages=[]
for package,module,capability in [('numpy','numpy','analysis'),('scipy','scipy','analysis'),('Pillow','PIL','analysis'),('scikit-image','skimage','analysis'),('tifffile','tifffile','analysis'),('mcp','mcp','mcp'),('zarr','zarr','storage'),('numcodecs','numcodecs','storage'),('matplotlib','matplotlib','reporting')]:
    try:
        with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
            importlib.import_module(module)
        packages.append(dict(name=package,version=importlib.metadata.version(package),capability=capability,available=True))
    except Exception as error:
        packages.append(dict(name=package,capability=capability,available=False,reason=str(error)[:300]))
supported=sys.version_info >= (3,11)
analysis=supported and all(p['available'] for p in packages if p['capability']=='analysis')
mcp=supported and all(p['available'] for p in packages if p['capability']=='mcp')
storage=supported and all(p['available'] for p in packages if p['capability']=='storage')
reporting=supported and all(p['available'] for p in packages if p['capability']=='reporting')
print(json.dumps(dict(installed=True,ready=analysis and mcp and storage and reporting,analysisReady=analysis,mcpReady=mcp,storageReady=storage,reportingReady=reporting,pythonVersion=sys.version.split()[0],packages=packages)))
"#;

#[tauri::command]
pub async fn workbench_runtime_status(app: AppHandle) -> Result<Value, String> {
    let store = crate::paths::FileStore::from_app(&app)?;
    let python = store.workbench_python();
    let microscopy = app.path().resource_dir().map_err(|error| error.to_string())?
        .join("microscopy-runtime/microscopy-runtime.json").is_file();
    if !python.is_file() {
        return Ok(json!({"installed":false,"ready":false,"analysisReady":false,"mcpReady":false,
            "microscopyBundled":microscopy,"packages":[],"message":"Install the dedicated Workbench runtime to enable shared analysis and MCP. Existing model environments stay separate."}));
    }
    let mut command = Command::new(python);
    command.args(["-I", "-B", "-c", PROBE]).env_remove("PYTHONPATH").env_remove("PYTHONHOME")
        .stdin(Stdio::null()).stdout(Stdio::piped()).stderr(Stdio::piped()).kill_on_drop(true);
    crate::proc::hide_console_tokio(&mut command);
    let mut child = command.spawn().map_err(|error| format!("Could not inspect the Workbench runtime: {error}. Use Install or repair runtime."))?;
    let stdout = child.stdout.take().ok_or("Runtime probe output is unavailable")?;
    let stderr = child.stderr.take().ok_or("Runtime probe diagnostics are unavailable")?;
    let output = tokio::spawn(async move { let mut bytes = Vec::new(); stdout.take(32769).read_to_end(&mut bytes).await.map(|_| bytes) });
    let diagnostics = tokio::spawn(async move { let mut bytes = Vec::new(); stderr.take(8193).read_to_end(&mut bytes).await.map(|_| bytes) });
    let status = tokio::time::timeout(Duration::from_secs(30), child.wait()).await;
    if status.is_err() { let _ = child.kill().await; let _ = child.wait().await; }
    let bytes = output.await.map_err(|error| error.to_string())?.map_err(|error| error.to_string())?;
    let errors = diagnostics.await.map_err(|error| error.to_string())?.map_err(|error| error.to_string())?;
    let status = status.map_err(|_| "Runtime inspection timed out. Use Install or repair runtime.".to_string())?.map_err(|error| error.to_string())?;
    if !status.success() || bytes.len() > 32768 || errors.len() > 8192 {
        return Err(format!("Runtime inspection failed. Use Install or repair runtime. {}", String::from_utf8_lossy(&errors).chars().take(600).collect::<String>()));
    }
    let mut value: Value = serde_json::from_slice(&bytes).map_err(|_| "Runtime inspection returned an invalid response. Use Install or repair runtime.".to_string())?;
    value["microscopyBundled"] = json!(microscopy);
    Ok(value)
}

#[tauri::command]
pub fn workbench_connection(project_path: String, tool_mode: Option<String>, allow_write: bool, allow_plugins: bool, allow_paths: Vec<String>, allow_omero_profiles: Vec<String>, allow_omero_configuration: bool) -> Result<Value, String> {
    let project = PathBuf::from(&project_path);
    if !project.is_absolute() || !project.is_dir() { return Err("Open an existing project folder before copying its agent configuration.".into()); }
    if allow_plugins && !allow_write { return Err("Executable methods require write access as well as the executable-code grant.".into()); }
    if allow_paths.len() > 32 { return Err("Choose at most 32 additional source or export folders.".into()); }
    let executable = std::env::current_exe().map_err(|error| error.to_string())?;
    let mode = tool_mode.unwrap_or_else(|| "compact".into());
    if mode != "compact" && mode != "operations" { return Err("Choose compact or individual operation tool discovery.".into()); }
    let mut args = vec!["--workbench".to_string(), "mcp".to_string(), "--project".to_string(), project_path, "--tool-mode".into(), mode];
    if allow_write { args.push("--allow-write".into()); }
    if allow_plugins { args.push("--allow-plugins".into()); }
    if allow_omero_profiles.len() > 32 { return Err("Choose at most 32 named OMERO profiles.".into()); }
    for profile in std::collections::BTreeSet::from_iter(allow_omero_profiles) {
        if profile.is_empty() || profile.len() > 64 || !profile.bytes().all(|byte| byte.is_ascii_alphanumeric() || b"_.-".contains(&byte)) {
            return Err("OMERO profile grants require valid configured profile IDs.".into());
        }
        args.push("--allow-omero-profile".into()); args.push(profile);
    }
    if allow_omero_configuration {
        if !allow_write { return Err("Changing host-local OMERO configuration also requires the write grant.".into()); }
        args.push("--allow-omero-configuration".into());
    }
    let mut retained = std::collections::BTreeSet::new();
    for path in allow_paths {
        let directory = PathBuf::from(&path);
        if !directory.is_absolute() || !directory.is_dir() { return Err("Each additional path must be an existing absolute folder.".into()); }
        if retained.insert(path.clone()) { args.push("--allow-path".into()); args.push(path); }
    }
    Ok(json!({"mcpServers":{"cellcounter":{"command":executable.to_string_lossy(),"args":args}}}))
}
