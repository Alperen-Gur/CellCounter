//! Thin process adapter to the same project operations used by CLI and MCP.
//! The Python runtime owns project transactions and scientific calculations.

use serde_json::Value;
use std::process::Stdio;
use std::time::Duration;
use tauri::{AppHandle, Manager};
use tokio::io::{AsyncRead, AsyncReadExt, AsyncWriteExt};
use tokio::process::Command;

const MAX_REQUEST: usize = 8 * 1024 * 1024;
const MAX_RESPONSE: u64 = 32 * 1024 * 1024;

/// Locate this installation's legacy library without opening, repairing or
/// changing its database. Migration itself belongs to shared operations.
#[tauri::command]
pub fn workbench_legacy_locations(app: AppHandle) -> Result<Value, String> {
    let root = app.path().app_data_dir()
        .map_err(|error| format!("Could not resolve the existing library folder: {error}"))?
        .join("CellCounter");
    let database = root.join("store.sqlite");
    Ok(serde_json::json!({
        "libraryRoot": root.to_string_lossy(),
        "databasePath": database.to_string_lossy(),
        "databaseExists": database.is_file(),
        "workspaceDocumentKey": "workspace",
    }))
}

fn validate_request(request: &Value) -> Result<(), String> {
    if request.get("schemaVersion").and_then(Value::as_u64) != Some(1) {
        return Err("Unsupported workbench request schema.".into());
    }
    if !request.get("operation").is_some_and(Value::is_string)
        || !request.get("arguments").is_some_and(Value::is_object)
        || !request.get("requestId").is_some_and(Value::is_string)
    {
        return Err("Workbench requests require an operation, request ID and arguments.".into());
    }
    if let Some(path) = request.get("projectPath") {
        let path = path.as_str().ok_or("Project path must be a string.")?;
        if !std::path::Path::new(path).is_absolute() {
            return Err("Choose an absolute project folder.".into());
        }
    }
    Ok(())
}

async fn read_bounded(reader: impl AsyncRead + Unpin) -> Result<Vec<u8>, String> {
    let mut data = Vec::new();
    reader
        .take(MAX_RESPONSE + 1)
        .read_to_end(&mut data)
        .await
        .map_err(|error| format!("Could not read workbench output: {error}"))?;
    if data.len() as u64 > MAX_RESPONSE {
        return Err("Workbench output exceeded the 32 MiB response limit.".into());
    }
    Ok(data)
}

#[tauri::command]
pub async fn workbench_request(app: AppHandle, request: Value) -> Result<Value, String> {
    validate_request(&request)?;
    let payload = serde_json::to_vec(&request).map_err(|error| error.to_string())?;
    if payload.len() > MAX_REQUEST {
        return Err("Workbench input exceeds the 8 MiB limit.".into());
    }
    let store = crate::paths::FileStore::from_app(&app)?;
    let runtime = crate::env::staging::snapshot(&store.python_dir())?;
    let python = crate::workbench_cli::interpreter(&store)?;
    let mut command = Command::new(python);
    command
        .arg("-B")
        .arg(runtime.join("workbench.py"))
        .arg("--omero-profiles").arg(store.root().join("omero-profiles.json"));
    if let Some(manifest) = crate::env::microscopy::snapshot(&app, &store.python_dir())? {
        let root = manifest.parent().ok_or("The microscopy runtime has no parent directory")?;
        command.arg("--microscopy-node").arg(root.join(if cfg!(windows) { "node/node.exe" } else { "node/node" }))
            .arg("--microscopy-runtime").arg(root);
    }
    command.args(["request", "--stdin"])
        .env_remove("NODE_OPTIONS")
        .env_remove("NODE_PATH")
        .env_remove("PYTHONPATH")
        .env_remove("PYTHONHOME")
        .current_dir(&runtime)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .kill_on_drop(true);
    crate::proc::hide_console_tokio(&mut command);
    let mut child = command
        .spawn()
        .map_err(|error| format!("Could not start the local workbench: {error}"))?;
    let mut stdin = child
        .stdin
        .take()
        .ok_or("Workbench input is unavailable.")?;
    let stdout = child
        .stdout
        .take()
        .ok_or("Workbench output is unavailable.")?;
    let stderr = child
        .stderr
        .take()
        .ok_or("Workbench diagnostics are unavailable.")?;
    // Drain both pipes while writing; no command-line size limit or shell.
    let stdout_task = tokio::spawn(read_bounded(stdout));
    let stderr_task = tokio::spawn(read_bounded(stderr));
    let input_task = tokio::spawn(async move {
        stdin.write_all(&payload).await?;
        stdin.shutdown().await
    });
    let status = tokio::time::timeout(Duration::from_secs(20 * 60), child.wait()).await;
    if status.is_err() {
        let _ = child.kill().await;
        let _ = child.wait().await;
    }
    let input = input_task.await.map_err(|error| error.to_string())?;
    let stdout = stdout_task.await.map_err(|error| error.to_string())??;
    let stderr = stderr_task.await.map_err(|error| error.to_string())??;
    let status = status
        .map_err(|_| "Workbench operation timed out; refresh the project before retrying.")?
        .map_err(|error| error.to_string())?;
    input.map_err(|error| format!("Could not send the workbench request: {error}"))?;
    // Domain failures are structured envelopes, even when the CLI exits nonzero.
    if let Ok(response) = serde_json::from_slice::<Value>(&stdout) {
        if response.get("schemaVersion").and_then(Value::as_u64) == Some(1)
            && response.get("ok").is_some_and(Value::is_boolean)
        {
            return Ok(response);
        }
    }
    let details = String::from_utf8_lossy(&stderr)
        .chars()
        .take(1200)
        .collect::<String>();
    Err(format!(
        "Workbench returned an invalid response (exit {status}). {details}"
    ))
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn rejects_unsupported_envelopes_and_relative_projects() {
        assert!(validate_request(&json!({"schemaVersion": 2})).is_err());
        assert!(validate_request(&json!({
            "schemaVersion":1,"operation":"project.inspect","requestId":"1",
            "arguments":{},"projectPath":"relative"
        }))
        .is_err());
        assert!(validate_request(&json!({
            "schemaVersion":1,"operation":"capabilities","requestId":"1","arguments":{}
        }))
        .is_ok());
    }

    #[tokio::test]
    async fn drains_bounded_output() {
        assert_eq!(
            read_bounded(&b"{\"ok\":true}"[..]).await.unwrap(),
            b"{\"ok\":true}"
        );
    }
}
