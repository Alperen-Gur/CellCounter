import Foundation
import Combine
import Observation

/// Pass-16: drives `scripts/install_python_cp4.sh` from inside the app.
///
/// Behaviourally identical to `CellposeInstaller` (the 3.x installer) but
/// pointed at:
///   * `FileStore.shared.pythonInstallCp4ScriptURL` for the bundled script
///   * `FileStore.shared.pythonVenv4Dir` for the venv target
///   * `FileStore.shared.cellpose4InstallIncompleteSentinel` for the
///     "incomplete install" marker
///   * `Cellpose4Availability.importableCacheKey` for the cached probe
///
/// The two installers are kept as separate types (rather than refactored into
/// a generic + facades) because the 3.x type is held in many places by name —
/// the diff cost of a refactor outweighs the duplication. The 3.x installer
/// is sacred and must not be touched in this pass.
///
/// The 1.15 GB CPSAM weights download is NOT triggered here — it fires lazily
/// on the FIRST DETECTION RUN inside `cellpose4_detect.py`. The Models tab
/// install sheet should warn the user about that in copy (C3 handles UI).
@MainActor
final class CellposeSAMInstaller: ObservableObject {
    @Published var isRunning: Bool = false
    @Published var output: [String] = []
    @Published var progressHint: String = ""
    @Published var done: Bool = false
    @Published var error: String? = nil

    private var process: Process?
    private var streamTask: Task<Void, Never>?
    /// The run started over a working install (an update). If it fails, that
    /// install is checked again and kept in use when it still imports.
    private var updatingWorkingInstall = false
    /// Cellpose version of that install, for the failure message.
    private var previousVersion: String?

    func reinstall() {
        cancel()
        let venv4 = FileStore.shared.pythonVenv4Dir
        if FileManager.default.fileExists(atPath: venv4.path) {
            NSLog("[CellposeSAMInstaller] reinstall(): removing existing venv4 at \(venv4.path)")
            try? FileManager.default.removeItem(at: venv4)
            NotificationCenter.default.post(name: .ccVenv4Changed, object: nil)
        }
        start()
    }

    func start() {
        guard !isRunning else { return }

        let fmPreflight = FileManager.default
        let venv4Preflight = FileStore.shared.pythonVenv4Dir
        let pipCheckURL = venv4Preflight.appendingPathComponent("bin/pip")
        if fmPreflight.fileExists(atPath: venv4Preflight.path)
            && !fmPreflight.fileExists(atPath: pipCheckURL.path) {
            NSLog("[CellposeSAMInstaller] start() preflight: wiping broken venv4 at \(venv4Preflight.path)")
            try? fmPreflight.removeItem(at: venv4Preflight)
        }

        let scriptURL: URL
        let fm = FileManager.default
        do {
            try PythonRuntime.stageScripts()
            scriptURL = FileStore.shared.pythonInstallCp4ScriptURL
            if !fm.fileExists(atPath: scriptURL.path) {
                error = "Cellpose-SAM install script missing after staging: \(scriptURL.path). "
                      + "Check the CopyPythonSidecar build phase ran and that "
                      + "install_python_cp4.sh is in CellCounting/scripts/."
                return
            }
            if !fm.isExecutableFile(atPath: scriptURL.path) {
                try? fm.setAttributes([.posixPermissions: 0o755],
                                      ofItemAtPath: scriptURL.path)
                if !fm.isExecutableFile(atPath: scriptURL.path) {
                    error = "Cellpose-SAM install script is not executable (chmod 755 failed): \(scriptURL.path)"
                    return
                }
            }
        } catch {
            self.error = "Couldn't stage installer scripts: \(error.localizedDescription)"
            NSLog("[CellposeSAMInstaller] stageScripts threw: \(error)")
            return
        }

        let venvPath = FileStore.shared.pythonVenv4Dir.path
        let scriptsDir = FileStore.shared.pythonDir.path
        try? fm.createDirectory(
            at: FileStore.shared.pythonDir,
            withIntermediateDirectories: true
        )

        // Half-installed venv4: nuke and rebuild.
        let venv4Dir = FileStore.shared.pythonVenv4Dir
        let pipURL = venv4Dir.appendingPathComponent("bin/pip")
        if fm.fileExists(atPath: venv4Dir.path)
            && !fm.fileExists(atPath: pipURL.path) {
            NSLog("[CellposeSAMInstaller] removing partial venv4 at \(venv4Dir.path)")
            try? fm.removeItem(at: venv4Dir)
        }

        output.removeAll()
        progressHint = "Starting…"
        error = nil
        done = false
        isRunning = true

        // Re-running the script over a working venv4 updates it in place to
        // the pinned set. Remember that, before the flags below are cleared.
        // Not yet probed counts too: a failure is only forgiven after an
        // import check passes.
        let cachedImportable = UserDefaults.standard.object(
            forKey: Cellpose4Availability.importableCacheKey) as? Bool
        updatingWorkingInstall = cachedImportable != false
            && !fm.fileExists(atPath: FileStore.shared.cellpose4InstallIncompleteSentinel.path)
            && fm.fileExists(atPath: pipURL.path)
        let storedVersion = UserDefaults.standard.string(forKey: CellposeSAMRuntime.installedVersionCacheKey)
        previousVersion = updatingWorkingInstall && storedVersion != CellposeSAMRuntime.unreadableVersion
            ? storedVersion : nil

        // Drop the cp4 sentinel + invalidate the cp4 cached probe. Both keys
        // are DISTINCT from the 3.x ones so this never disturbs the 3.x install.
        // While the sentinel exists no Cellpose-SAM analysis starts, so none
        // runs on half-replaced packages.
        try? fm.createDirectory(at: FileStore.shared.pythonDir,
                                withIntermediateDirectories: true)
        try? Data().write(to: FileStore.shared.cellpose4InstallIncompleteSentinel)
        UserDefaults.standard.set(false, forKey: Cellpose4Availability.importableCacheKey)
        CellposeSAMRuntime.forgetCachedVersion()
        NotificationCenter.default.post(name: .ccVenv4Changed, object: nil)

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/bash")
        proc.arguments = [scriptURL.path, venvPath, scriptsDir]
        proc.currentDirectoryURL = FileStore.shared.pythonDir

        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe
        self.process = proc

        streamTask = Task { [weak self] in
            let handle = pipe.fileHandleForReading
            do {
                for try await line in handle.bytes.lines {
                    await self?.appendLine(line)
                }
            } catch {
                // Stream broken — process terminated. Nothing actionable.
            }
        }

        proc.terminationHandler = { [weak self] p in
            let exitCode = p.terminationStatus
            Task { @MainActor [weak self] in
                self?.handleTermination(exitCode: exitCode)
            }
        }

        do {
            try proc.run()
            ChildProcessTracker.shared.register(proc, kind: .install)
        } catch {
            streamTask?.cancel()
            streamTask = nil
            self.error = "Failed to start Cellpose-SAM installer: \(error.localizedDescription)"
            isRunning = false
            self.process = nil
        }
    }

    func cancel() {
        process?.terminate()
    }

    // MARK: — Stream consumers

    private func appendLine(_ line: String) {
        output.append(line)
        if output.count > 500 {
            output.removeFirst(output.count - 500)
        }
        if let parsed = Self.parseHint(line) {
            progressHint = parsed
        }
        let lower = line.lowercased()
        if lower.contains("error") || lower.contains("traceback") {
            if error == nil {
                error = line
            }
        }
    }

    private func handleTermination(exitCode: Int32) {
        streamTask?.cancel()
        streamTask = nil
        process = nil
        isRunning = false
        if exitCode == 0 {
            done = true
            progressHint = "Cellpose-SAM installed. (Weights ~1.15 GB will download on first detection.)"
            error = nil
            UserDefaults.standard.removeObject(forKey: Cellpose4Availability.importableCacheKey)
            try? FileManager.default.removeItem(
                at: FileStore.shared.cellpose4InstallIncompleteSentinel)
            // Pass-16: notification name MUST match the one declared in
            // InstallCellpose4Sheet (`ccCellposeSAMInstallCompleted`) so the
            // AppState observer in init() actually fires. Keep this string
            // in sync with the `Notification.Name` declared there.
            NotificationCenter.default.post(
                name: .init("cellpose-sam-install-completed"),
                object: nil
            )
        } else {
            if error == nil {
                error = "Install failed (exit code \(exitCode))"
            }
            if updatingWorkingInstall {
                keepPreviousInstallIfItStillWorks(exitCode: exitCode)
            }
        }
        updatingWorkingInstall = false
        // A failed or cancelled pip run may also have changed the runtime.
        NotificationCenter.default.post(name: .ccVenv4Changed, object: nil)
    }

    /// An update that did not finish (no network, no Python 3.12, cancelled)
    /// usually leaves the old packages in place: pip resolves and downloads
    /// everything before it changes anything. If Cellpose still imports, keep
    /// using it instead of reporting a broken install. Each result records
    /// the versions that actually ran, so a mixed state cannot go unnoticed.
    private func keepPreviousInstallIfItStillWorks(exitCode: Int32) {
        let python = FileStore.shared.pythonInterpreter4URL
        let venv = FileStore.shared.pythonVenv4Dir
        let sentinel = FileStore.shared.cellpose4InstallIncompleteSentinel
        let previous = previousVersion
        Task { [weak self] in
            let version: String? = await Task.detached(priority: .userInitiated) {
                guard CellposeSAMRuntime.isImportable(pythonURL: python) else { return nil }
                return CellposeSAMRuntime.installedVersion(venv: venv) ?? previous ?? "4.x"
            }.value
            guard let version, let self, !self.isRunning else { return }
            try? FileManager.default.removeItem(at: sentinel)
            // Re-probe rather than assume; the probe also re-reads the version.
            UserDefaults.standard.removeObject(forKey: Cellpose4Availability.importableCacheKey)
            NotificationCenter.default.post(name: .ccVenv4Changed, object: nil)
            self.error = "The update did not finish (exit code \(exitCode)). Cellpose \(version) "
                + "is still installed, and analyses keep using it. Check the log above, then retry."
        }
    }

    // MARK: — Helpers

    private static func parseHint(_ line: String) -> String? {
        let lower = line.lowercased()
        if lower.contains("creating venv4") || (lower.contains("creating ") && lower.contains("venv")) {
            return "Creating virtual environment…"
        }
        if lower.contains("upgrading pip") {
            return "Upgrading pip…"
        }
        if lower.contains("collecting torch") || lower.contains("downloading torch") {
            return "Installing torch (~700 MB)…"
        }
        if lower.contains("collecting cellpose") || lower.contains("downloading cellpose") {
            return "Installing cellpose 4 (CPSAM)…"
        }
        if lower.contains("collecting scikit-image") {
            return "Installing scikit-image…"
        }
        if lower.contains("collecting numpy") {
            return "Installing numpy…"
        }
        if lower.contains("collecting pillow") {
            return "Installing pillow…"
        }
        if lower.contains("collecting torchvision") {
            return "Installing torchvision…"
        }
        if lower.hasPrefix("installing collected packages") {
            return "Installing packages…"
        }
        if lower.contains("successfully installed") {
            return "Verifying…"
        }
        if lower.contains("==> done") {
            return "Done — weights will download on first detection."
        }
        return nil
    }
}
