//! Stage exactly this executable's Python scripts into the writable runtime.
//!
//! Callers wait for the entire project before probing or launching Python.
//! The bytes are embedded at build time, so MSI/NSIS layout, a shortcut's cwd,
//! missing resource directories and leftovers from an older version cannot
//! select a different runtime. No model weights or Python packages are embedded.

use std::fs;
use std::io::Write;
use std::path::Path;
use std::sync::Mutex;

include!(concat!(env!("OUT_DIR"), "/python_runtime.rs"));

static STAGING_LOCK: Mutex<()> = Mutex::new(());

fn matches(path: &Path, contents: &[u8]) -> bool {
    fs::metadata(path).is_ok_and(|meta| meta.is_file() && meta.len() == contents.len() as u64)
        && fs::read(path).is_ok_and(|existing| existing == contents)
}

fn write_script(target: &Path, contents: &[u8]) -> std::io::Result<()> {
    // Publish a complete file. A failed update keeps the previous file intact
    // and prevents the caller from starting Python with a partial runtime.
    let temporary = target.with_extension(format!("{}.staging", uuid::Uuid::new_v4()));
    let result = (|| {
        let mut file = fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(&temporary)?;
        file.write_all(contents)?;
        file.sync_all()?;
        drop(file);
        fs::rename(&temporary, target)
    })();
    if result.is_err() {
        let _ = fs::remove_file(&temporary);
    }
    result
}

fn stage_files(destination: &Path, files: &[(&str, &[u8])]) -> Result<(), String> {
    // Availability requests for several model cards can arrive together, as
    // can an import and an analysis. Every caller observes a complete staging
    // pass, and a failed pass is retried on the next request.
    let _guard = STAGING_LOCK.lock().map_err(|_| {
        "The local analysis runtime could not be prepared. Restart CellCounter and retry."
            .to_string()
    })?;
    fs::create_dir_all(destination).map_err(|error| {
        format!(
            "CellCounter could not prepare its local analysis folder {}: {error}. \
             Check that the folder is writable and has free disk space, then retry.",
            destination.display()
        )
    })?;
    for &(name, contents) in files {
        let target = destination.join(name);
        // Avoid touching identical files: Windows antivirus or a running
        // worker may hold an otherwise usable file open.
        if matches(&target, contents) {
            continue;
        }
        write_script(&target, contents).map_err(|error| {
            format!(
                "CellCounter could not prepare local analysis file {}: {error}. \
                 Close any running analysis and retry. If this persists, restart \
                 CellCounter and check that the analysis folder is writable, has \
                 free disk space, and is not blocked by security software.",
                target.display()
            )
        })?;
    }
    Ok(())
}

pub(crate) fn stage(destination: &Path) -> Result<(), String> {
    stage_files(destination, EMBEDDED_FILES)
}

#[cfg(test)]
mod tests {
    use super::*;

    struct Scratch(std::path::PathBuf);

    impl Scratch {
        fn new() -> Self {
            Self(std::env::temp_dir().join(format!(
                "CellCounter first launch µ {}",
                uuid::Uuid::new_v4()
            )))
        }
    }

    impl Drop for Scratch {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }

    fn assert_complete(path: &Path) {
        for &(name, contents) in EMBEDDED_FILES {
            assert_eq!(fs::read(path.join(name)).unwrap(), contents, "{name}");
        }
    }

    #[test]
    fn first_launch_stages_complete_runtime_without_resource_directory() {
        let scratch = Scratch::new();
        let destination = scratch.0.join("app data").join("py");
        assert!(!destination.exists());
        stage(&destination).unwrap();
        assert_complete(&destination);
        // The built-in models retain separate entry points, never substitutes.
        for script in [
            "cellpose_detect.py",
            "cellpose4_detect.py",
            "stardist_detect.py",
        ] {
            assert!(destination.join(script).is_file());
        }
    }

    #[test]
    fn repairs_missing_and_same_length_corrupt_scripts_without_touching_models() {
        let scratch = Scratch::new();
        stage(&scratch.0).unwrap();
        let script = scratch.0.join("cellpose4_detect.py");
        let length = fs::metadata(&script).unwrap().len() as usize;
        fs::write(&script, vec![b'!'; length]).unwrap();
        fs::remove_file(scratch.0.join("_imageio.py")).unwrap();
        let model = scratch.0.join(".venv4/installed-model");
        fs::create_dir_all(model.parent().unwrap()).unwrap();
        fs::write(&model, b"preserve environment").unwrap();
        stage(&scratch.0).unwrap();
        assert_complete(&scratch.0);
        assert_eq!(fs::read(model).unwrap(), b"preserve environment");
    }

    #[test]
    fn concurrent_first_requests_each_observe_complete_project() {
        let scratch = Scratch::new();
        std::thread::scope(|scope| {
            for _ in 0..6 {
                scope.spawn(|| {
                    stage(&scratch.0).unwrap();
                    assert_complete(&scratch.0);
                });
            }
        });
    }

    #[test]
    fn unchanged_files_keep_their_timestamps() {
        let scratch = Scratch::new();
        stage(&scratch.0).unwrap();
        let script = scratch.0.join("cellpose_detect.py");
        // Set a recognizably old timestamp, avoiding timing-sensitive sleeps.
        fs::OpenOptions::new()
            .write(true)
            .open(&script)
            .unwrap()
            .set_modified(std::time::UNIX_EPOCH + std::time::Duration::from_secs(1_600_000_000))
            .unwrap();
        let original_time = fs::metadata(&script).unwrap().modified().unwrap();
        stage(&scratch.0).unwrap();
        assert_eq!(
            fs::metadata(script).unwrap().modified().unwrap(),
            original_time
        );
    }

    #[test]
    fn failed_update_is_actionable_preserves_existing_file_and_allows_retry() {
        let scratch = Scratch::new();
        fs::create_dir_all(scratch.0.join("blocked.py")).unwrap();
        fs::write(scratch.0.join("existing.py"), b"old version").unwrap();
        // A directory at a file path reliably rejects replacement on Windows
        // and Unix, including when the test process has elevated permissions.
        let files: &[(&str, &[u8])] = &[
            ("blocked.py", b"new script"),
            ("existing.py", b"new version"),
        ];
        let error = stage_files(&scratch.0, files).unwrap_err();
        assert!(
            error.contains("blocked.py") && error.contains("retry"),
            "{error}"
        );
        assert_eq!(
            fs::read(scratch.0.join("existing.py")).unwrap(),
            b"old version"
        );
        assert_eq!(
            fs::read_dir(&scratch.0).unwrap().count(),
            2,
            "temporary file leaked"
        );
        fs::remove_dir(scratch.0.join("blocked.py")).unwrap();
        stage_files(&scratch.0, files).unwrap();
        assert_eq!(
            fs::read(scratch.0.join("blocked.py")).unwrap(),
            b"new script"
        );
        assert_eq!(
            fs::read(scratch.0.join("existing.py")).unwrap(),
            b"new version"
        );
    }
}
