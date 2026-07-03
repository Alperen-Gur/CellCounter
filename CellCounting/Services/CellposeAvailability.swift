import Foundation

/// Resolves where the Cellpose sidecar lives so `CellposeDetectionService`
/// (and the other Python-backed family services) can decide whether to spawn
/// it or throw `DetectionError.modelNotInstalled`.
///
/// Post-install layout (under the App Sandbox container):
///
///     ~/Library/Containers/alguer.CellCounting/Data/
///       Library/Application Support/CellCounter/
///         python/
///           venv/                    ← created by install_python.sh
///             bin/python3
///           install_python.sh        ← copied from bundle (executable)
///           cellpose_detect.py       ← copied from bundle (refreshed
///           cellpose_train.py          every install)
///           _preprocessing.py
///           _watershed.py
///           _colony.py
///           stardist_detect.py
///           sam_detect.py
///
/// The bundle is read-only under the sandbox; we only use it as the SOURCE
/// for the per-install copy. The installer / sidecars all run out of the
/// writable container path above.
struct CellposeAvailability {
    enum Status {
        /// Both a python interpreter and the detect script are present.
        case available(pythonURL: URL, scriptURL: URL)
        /// The script can't be found anywhere — sidecar is just missing.
        case missingScripts
        /// The script exists but no venv has been created yet; surface the
        /// installer path so the UI can guide the user.
        case missingVenv(installScriptURL: URL)
        /// Nothing is set up at all (no script, no installer).
        case missingInstaller
        /// A venv directory exists but is half-built — pip is missing, the
        /// interpreter isn't executable, or `import cellpose` will fail.
        /// The reason string is human-readable for the UI to show in
        /// "Reinstall — previous install was interrupted" copy. Pass-11.
        case venvBroken(reason: String)
    }

    static func detect() -> Status {
        let fm = FileManager.default

        // 0) Pass-13: if the install sentinel is on disk the previous run of
        //    CellposeInstaller didn't reach exit 0. Even if pip got far enough
        //    to drop a usable python3 + the sidecar scripts are staged, the
        //    cellpose package itself almost certainly isn't importable — and
        //    a subsequent `python cellpose_detect.py` will hang in the
        //    ProcessingView at 92% looking exactly like a real run. Treat it
        //    as broken up front so the Models banner / toolbar pill flip.
        if fm.fileExists(atPath: FileStore.shared.installIncompleteSentinel.path) {
            return .venvBroken(reason: "Previous install was interrupted — Cellpose was not fully installed.")
        }

        // 1) Primary: writable container path under FileStore. This is where
        //    the installer creates the venv and where the sidecar scripts get
        //    staged on first install. After a successful install this is the
        //    ONLY place that has the venv.
        let stagedScript = FileStore.shared.pythonDir.appendingPathComponent("cellpose_detect.py")
        let stagedPyDir = FileStore.shared.pythonVenvDir.appendingPathComponent("bin")
        let stagedPy3 = stagedPyDir.appendingPathComponent("python3")
        let stagedPy = stagedPyDir.appendingPathComponent("python")
        let stagedPython: URL? = {
            if fm.isExecutableFile(atPath: stagedPy3.path) { return stagedPy3 }
            if fm.isExecutableFile(atPath: stagedPy.path)  { return stagedPy }
            return nil
        }()
        if let py = stagedPython, fm.fileExists(atPath: stagedScript.path) {
            // Pass-13 secondary guard: even without the sentinel, a cached
            // `cc-cellpose-importable == false` means the last probe found
            // cellpose missing from a venv that *otherwise* looks healthy
            // (python3 present, script staged). Report broken so the UI nudges
            // the user to reinstall instead of silently hanging detection.
            let cachedImportable = UserDefaults.standard
                .object(forKey: "cc-cellpose-importable") as? Bool
            if cachedImportable == false {
                return .venvBroken(reason: "Previous install was interrupted — the Cellpose package is not importable from the venv.")
            }
            return .available(pythonURL: py, scriptURL: stagedScript)
        }

        // 1b) Pass-11: half-installed venv detection. If the venv directory
        // exists but key pieces are missing (pip, python, or — if we already
        // probed — cellpose import), report it as broken so the UI can offer
        // a "Reinstall — previous install was interrupted" CTA rather than a
        // hung spinner. Only filesystem checks here; the cellpose-import
        // signal piggybacks on the static UserDefaults cache populated by
        // CellposeDownloader.probeInstalled (no subprocess fires here).
        let venvDir = FileStore.shared.pythonVenvDir
        if fm.fileExists(atPath: venvDir.path) {
            let pip = venvDir.appendingPathComponent("bin/pip")
            let py = venvDir.appendingPathComponent("bin/python3")
            if !fm.fileExists(atPath: pip.path) {
                return .venvBroken(reason: "Previous install was interrupted — pip is missing.")
            }
            if !fm.isExecutableFile(atPath: py.path) {
                return .venvBroken(reason: "Previous install was interrupted — the python interpreter is missing or not executable.")
            }
            // We have venv + pip + python but no detect script staged yet AND
            // the cellpose import probe (cached) said false. That means deps
            // never finished installing.
            let cachedImportable = UserDefaults.standard
                .object(forKey: "cc-cellpose-importable") as? Bool
            if cachedImportable == false {
                return .venvBroken(reason: "Previous install was interrupted — the Cellpose package is not importable from the venv.")
            }
        }

        // 2) Bundle path — used to surface "script exists, but no venv yet" so
        //    the UI shows the Install button. The bundle never holds the venv.
        let bundleScript = PythonRuntime.bundledPythonURL(named: "cellpose_detect.py")
        let bundleInstaller = PythonRuntime.bundledInstallScriptURL()
        if let installer = bundleInstaller, bundleScript != nil {
            return .missingVenv(installScriptURL: installer)
        }

        // (Dev-repo fallback removed in pass 10 — it was masking the bundling
        // bug for the install script. The only supported path is now:
        // bundle -> stageScripts -> FileStore venv.)

        if bundleScript != nil {
            return .missingInstaller
        }
        return .missingScripts
    }
}
