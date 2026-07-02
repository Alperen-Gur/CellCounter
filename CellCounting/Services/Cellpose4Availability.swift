import Foundation

/// Pass-16: mirror of `CellposeAvailability` for the Cellpose 4.x / CPSAM family.
///
/// The two are kept as separate types (rather than parameterizing one) for two
/// reasons:
///   1) The 3.x detect() is `public` API that the rest of the codebase calls
///      from a dozen places. We were told not to touch it.
///   2) The two installs are independent — different venv, different install
///      script, different sentinel, different cached probe key — and we want
///      the "broken" vs "missing" reasoning to evolve independently as we
///      learn what fails specifically in cp4.
///
/// Post-install layout (under `~/Library/Application Support/CellCounter/`):
///
///     python/
///       venv4/                          ← created by install_python_cp4.sh
///         bin/python3
///       install_python_cp4.sh           ← copied from bundle (executable)
///       cellpose4_detect.py             ← copied from bundle (C1 ships this)
///       .cc-install-incomplete-cp4      ← sentinel; present iff last install
///                                         died before pip finished
///
/// The 3.x install lives next to this in `venv/` and is unaffected.
struct Cellpose4Availability {
    enum Status {
        case available(pythonURL: URL, scriptURL: URL)
        case missingScripts
        case missingVenv(installScriptURL: URL)
        case missingInstaller
        case venvBroken(reason: String)
    }

    /// UserDefaults key for the cached `import cellpose` (version >= 4) probe.
    /// Distinct from the 3.x key so flipping one never disturbs the other.
    static let importableCacheKey = "cc-cellpose4-importable"

    static func detect() -> Status {
        let fm = FileManager.default

        // 0) Sentinel guard — see `CellposeAvailability.detect()` for the
        //    rationale. The cp4 install pulls torch + cellpose-sam which is a
        //    multi-minute pip run; an interrupted install easily leaves a
        //    venv4/ that has python3 but no working cellpose.
        if fm.fileExists(atPath: FileStore.shared.cellpose4InstallIncompleteSentinel.path) {
            return .venvBroken(reason: "Previous install was interrupted — Cellpose-SAM was not fully installed.")
        }

        // 1) Primary: staged venv4 + cellpose4_detect.py under FileStore.
        let stagedScript = FileStore.shared.pythonDir
            .appendingPathComponent("cellpose4_detect.py")
        let stagedPyDir = FileStore.shared.pythonVenv4Dir
            .appendingPathComponent("bin")
        let stagedPy3 = stagedPyDir.appendingPathComponent("python3")
        let stagedPy  = stagedPyDir.appendingPathComponent("python")
        let stagedPython: URL? = {
            if fm.isExecutableFile(atPath: stagedPy3.path) { return stagedPy3 }
            if fm.isExecutableFile(atPath: stagedPy.path)  { return stagedPy }
            return nil
        }()
        if let py = stagedPython, fm.fileExists(atPath: stagedScript.path) {
            // Cached-probe secondary guard, same shape as the 3.x flow.
            let cachedImportable = UserDefaults.standard
                .object(forKey: importableCacheKey) as? Bool
            if cachedImportable == false {
                return .venvBroken(reason: "Previous install was interrupted — the Cellpose-SAM package is not importable from the venv.")
            }
            return .available(pythonURL: py, scriptURL: stagedScript)
        }

        // 1b) Half-installed venv4 detection. Filesystem checks only — no
        //     subprocess spawns from this function (it's called during view
        //     body eval).
        let venv4Dir = FileStore.shared.pythonVenv4Dir
        if fm.fileExists(atPath: venv4Dir.path) {
            let pip = venv4Dir.appendingPathComponent("bin/pip")
            let py = venv4Dir.appendingPathComponent("bin/python3")
            if !fm.fileExists(atPath: pip.path) {
                return .venvBroken(reason: "Previous install was interrupted — pip is missing.")
            }
            if !fm.isExecutableFile(atPath: py.path) {
                return .venvBroken(reason: "Previous install was interrupted — the python interpreter is missing or not executable.")
            }
            let cachedImportable = UserDefaults.standard
                .object(forKey: importableCacheKey) as? Bool
            if cachedImportable == false {
                return .venvBroken(reason: "Previous install was interrupted — the Cellpose-SAM package is not importable from the venv.")
            }
        }

        // 2) Bundle path — surface "script exists, no venv4 yet" so the UI
        //    can show the Install CTA. The bundle never holds the venv.
        let bundleScript = PythonRuntime.bundledPythonURL(named: "cellpose4_detect.py")
        let bundleInstaller = PythonRuntime.bundledInstallCp4ScriptURL()
        if let installer = bundleInstaller, bundleScript != nil {
            return .missingVenv(installScriptURL: installer)
        }
        if bundleScript != nil {
            return .missingInstaller
        }
        return .missingScripts
    }
}
