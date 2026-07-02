import Foundation

/// Centralizes the on-disk layout for the Python sidecar.
///
/// Layout after a successful install (sandbox disabled in pass 10):
///
///     ~/Library/Application Support/CellCounter/
///       python/
///         venv/                    ← created by install_python.sh
///           bin/python3
///         install_python.sh        ← copied from bundle, chmod +x
///         cellpose_detect.py       ← copied from bundle every launch so
///         cellpose_train.py          updates ship cleanly
///         _preprocessing.py
///         _watershed.py
///         _colony.py
///         stardist_detect.py
///         yolo_detect.py
///         sam_detect.py
///
/// Bundle layout (read-only, what we copy FROM):
///
///     <App.app>/Contents/Resources/
///       python/*.py                ← copied in by the CopyPythonSidecar
///       scripts/install_python.sh    Run Script build phase.
///
/// We KEEP flat-path fallbacks (Resources/foo.py) so that any future migration
/// back to a synced-group exception set still works without touching code.
enum PythonRuntime {
    /// All Python source files that need to live next to the venv at runtime.
    /// Listed explicitly so we don't accidentally pick up stray junk from
    /// the bundle.
    static let bundledScriptNames: [String] = [
        "cellpose_detect.py",
        "cellpose_train.py",
        // Pass-18 (K4): shared helpers for both cellpose detect scripts.
        // Both `cellpose_detect.py` and `cellpose4_detect.py` import this
        // module — if it's missing from the staged dir, neither sidecar runs.
        "_cellpose_common.py",
        "_preprocessing.py",
        "_watershed.py",
        "_colony.py",
        "stardist_detect.py",
        "yolo_detect.py",
        "sam_detect.py",
        // Pass-14 (F3): ImageJ RoiSet exporter.
        "_export_imagej_roi.py",
        // Pass-16: Cellpose-SAM (4.x) sidecar — C1 ships this file.
        // Listed here as a best-effort copy; missing-helpers are non-fatal.
        "cellpose4_detect.py",
    ]

    /// Errors that surface to the UI when staging fails. These are deliberately
    /// human-readable; CellposeInstaller forwards them verbatim.
    enum StagingError: LocalizedError {
        case installScriptMissing(searched: [String])
        case helperMissing(name: String, searched: [String])

        var errorDescription: String? {
            switch self {
            case .installScriptMissing(let paths):
                return "install_python.sh is not bundled in the app. "
                    + "Tried: \(paths.joined(separator: ", ")). "
                    + "This is a build-time bug — the CopyPythonSidecar Run Script "
                    + "phase did not run or did not copy the script. "
                    + "Clean the build folder and rebuild."
            case .helperMissing(let name, let paths):
                return "\(name) is not bundled in the app. "
                    + "Tried: \(paths.joined(separator: ", "))."
            }
        }
    }

    /// Source URL for a bundled python file. Tries nested first (`python/foo.py`)
    /// then flat (`foo.py`) for forward-compat. The bundle is the ONLY source —
    /// the dev-repo fallback was removed because it was masking the bundling bug.
    static func bundledPythonURL(named name: String) -> URL? {
        let fm = FileManager.default
        guard let resourceURL = Bundle.main.resourceURL else { return nil }
        let nested = resourceURL.appendingPathComponent("python/\(name)")
        if fm.fileExists(atPath: nested.path) { return nested }
        let flat = resourceURL.appendingPathComponent(name)
        if fm.fileExists(atPath: flat.path) { return flat }
        return nil
    }

    /// Source URL for the bundled install script.
    static func bundledInstallScriptURL() -> URL? {
        let fm = FileManager.default
        guard let resourceURL = Bundle.main.resourceURL else { return nil }
        let nested = resourceURL.appendingPathComponent("scripts/install_python.sh")
        if fm.fileExists(atPath: nested.path) { return nested }
        let flat = resourceURL.appendingPathComponent("install_python.sh")
        if fm.fileExists(atPath: flat.path) { return flat }
        return nil
    }

    /// Pass-16: source URL for the bundled Cellpose-SAM (4.x) installer.
    /// Mirrors `bundledInstallScriptURL()` exactly so the same nested→flat
    /// fallback applies if Xcode's synced groups ever skip the file.
    static func bundledInstallCp4ScriptURL() -> URL? {
        let fm = FileManager.default
        guard let resourceURL = Bundle.main.resourceURL else { return nil }
        let nested = resourceURL.appendingPathComponent("scripts/install_python_cp4.sh")
        if fm.fileExists(atPath: nested.path) { return nested }
        let flat = resourceURL.appendingPathComponent("install_python_cp4.sh")
        if fm.fileExists(atPath: flat.path) { return flat }
        return nil
    }

    /// Mirror bundled python helpers + the install script into `FileStore`'s
    /// writable python dir. Re-runnable: existing files are overwritten so app
    /// updates propagate. Returns the directory the scripts live in.
    ///
    /// Throws `StagingError.installScriptMissing` if the bundle is missing
    /// install_python.sh (the symptom of the synced-group bug we fixed in
    /// pass 10). The previous behavior of silently skipping the script
    /// produced a confusing "permission denied" error downstream.
    @discardableResult
    static func stageScripts() throws -> URL {
        let fm = FileManager.default
        let dir = FileStore.shared.pythonDir
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)

        // *.py helpers — missing helpers are non-fatal individually (we log,
        // but proceed). Most installs only need cellpose_detect.py to work.
        for name in bundledScriptNames {
            guard let src = bundledPythonURL(named: name) else {
                NSLog("[PythonRuntime] WARNING: bundled helper missing: \(name)")
                continue
            }
            let dst = dir.appendingPathComponent(name)
            if fm.fileExists(atPath: dst.path) {
                try? fm.removeItem(at: dst)
            }
            try fm.copyItem(at: src, to: dst)
        }

        // install_python.sh — REQUIRED. Without it, nothing else matters.
        guard let scriptSrc = bundledInstallScriptURL() else {
            let probed: [String] = {
                guard let res = Bundle.main.resourceURL else { return ["<no Resources>"] }
                return [
                    res.appendingPathComponent("scripts/install_python.sh").path,
                    res.appendingPathComponent("install_python.sh").path,
                ]
            }()
            throw StagingError.installScriptMissing(searched: probed)
        }
        let dst = FileStore.shared.pythonInstallScriptURL
        if fm.fileExists(atPath: dst.path) {
            try? fm.removeItem(at: dst)
        }
        try fm.copyItem(at: scriptSrc, to: dst)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dst.path)
        NSLog("[PythonRuntime] staged install_python.sh: \(scriptSrc.path) -> \(dst.path)")

        // Pass-19 hotfix: Pass-18 K4 extracted the shared install logic into
        // `_lib_install.sh`, which `install_python.sh` and `install_python_cp4.sh`
        // both `source` at startup. Without staging this sibling, the wrappers
        // exit immediately on a fresh machine with `_lib_install.sh: No such
        // file or directory`. A field tester hit this on first install.
        if let resourceURL = Bundle.main.resourceURL {
            let libSrcNested = resourceURL.appendingPathComponent("scripts/_lib_install.sh")
            let libSrcFlat = resourceURL.appendingPathComponent("_lib_install.sh")
            let libSrc: URL? = fm.fileExists(atPath: libSrcNested.path) ? libSrcNested
                              : (fm.fileExists(atPath: libSrcFlat.path) ? libSrcFlat : nil)
            if let libSrc {
                let libDst = FileStore.shared.pythonDir.appendingPathComponent("_lib_install.sh")
                if fm.fileExists(atPath: libDst.path) {
                    try? fm.removeItem(at: libDst)
                }
                do {
                    try fm.copyItem(at: libSrc, to: libDst)
                    try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: libDst.path)
                    NSLog("[PythonRuntime] staged _lib_install.sh: \(libSrc.path) -> \(libDst.path)")
                } catch {
                    NSLog("[PythonRuntime] WARNING: failed to stage _lib_install.sh: \(error)")
                }
            } else {
                NSLog("[PythonRuntime] WARNING: _lib_install.sh missing from bundle — install scripts will fail to source it")
            }
        }

        // Pass-16: stage the cp4 installer alongside the 3.x one. This is a
        // best-effort copy — a missing cp4 script must NOT break the 3.x
        // install flow, since 3.x ships as the default and cp4 is opt-in.
        // Cellpose4Availability surfaces the missing-installer case to the UI.
        if let cp4Src = bundledInstallCp4ScriptURL() {
            let cp4Dst = FileStore.shared.pythonInstallCp4ScriptURL
            if fm.fileExists(atPath: cp4Dst.path) {
                try? fm.removeItem(at: cp4Dst)
            }
            do {
                try fm.copyItem(at: cp4Src, to: cp4Dst)
                try fm.setAttributes([.posixPermissions: 0o755],
                                     ofItemAtPath: cp4Dst.path)
                NSLog("[PythonRuntime] staged install_python_cp4.sh: \(cp4Src.path) -> \(cp4Dst.path)")
            } catch {
                NSLog("[PythonRuntime] WARNING: failed to stage cp4 installer: \(error)")
            }
        } else {
            NSLog("[PythonRuntime] WARNING: install_python_cp4.sh missing from bundle (cp4 install will be unavailable)")
        }

        return dir
    }

    /// Path under FileStore for an installed Python helper, or nil if it has
    /// not been staged yet. Detection services should call this first; if it
    /// returns nil they can fall back to the bundle (read-only is fine for
    /// detection — only the installer needs write access).
    static func stagedScriptURL(named name: String) -> URL? {
        let url = FileStore.shared.pythonDir.appendingPathComponent(name)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
}
