import Foundation
import Combine
import Observation

/// Drives `scripts/install_python.sh` from inside the app. Streams stdout+stderr
/// lines into `output`, lets the UI render a live tail, parses a friendly
/// `progressHint` from common pip activity, and reports success/failure when the
/// subprocess terminates.
@MainActor
final class CellposeInstaller: ObservableObject {
    @Published var isRunning: Bool = false
    @Published var output: [String] = []
    @Published var progressHint: String = ""
    @Published var done: Bool = false
    @Published var error: String? = nil

    private var process: Process?
    private var streamTask: Task<Void, Never>?

    /// Wipe any partial venv state and start a fresh install. Use this from
    /// the "Reinstall…" CTA when the previous install was interrupted — the
    /// install script can sometimes recover from a half-built venv, but the
    /// behavior is unreliable, so prefer a clean slate.
    func reinstall() {
        cancel()
        let venv = FileStore.shared.pythonVenvDir
        if FileManager.default.fileExists(atPath: venv.path) {
            NSLog("[CellposeInstaller] reinstall(): removing existing venv at \(venv.path)")
            try? FileManager.default.removeItem(at: venv)
            // Pass-12 K1: let the InstallStateCache (+ AppState mirror) re-probe.
            NotificationCenter.default.post(name: .ccVenvChanged, object: nil)
        }
        start()
    }

    func start() {
        guard !isRunning else { return }

        // Pre-flight: if we detect a broken venv shape (dir exists but pip is
        // missing, etc.), nuke it before letting the install script touch it.
        // F2 added a similar check inside install_python.sh; we duplicate it
        // here so the cleanup happens even when the script itself isn't being
        // re-run (e.g. user retries from the UI without re-invoking the
        // script's pre-flight).
        let fmPreflight = FileManager.default
        let venvPreflight = FileStore.shared.pythonVenvDir
        let pipCheckURL = venvPreflight.appendingPathComponent("bin/pip")
        if fmPreflight.fileExists(atPath: venvPreflight.path)
            && !fmPreflight.fileExists(atPath: pipCheckURL.path) {
            NSLog("[CellposeInstaller] start() preflight: wiping broken venv at \(venvPreflight.path)")
            try? fmPreflight.removeItem(at: venvPreflight)
        }

        // Stage the bundled scripts + install_python.sh into the writeable
        // FileStore root at ~/Library/Application Support/CellCounter/python/.
        // The .app bundle is technically writable now that we dropped the
        // sandbox, but we still stage so users can clean up by deleting the
        // app-support dir without nuking the app itself.
        let scriptURL: URL
        let fm = FileManager.default
        do {
            try PythonRuntime.stageScripts()
            scriptURL = FileStore.shared.pythonInstallScriptURL
            // Distinguish "file not there" from "file not executable" —
            // previously both surfaced as a generic permissions error.
            if !fm.fileExists(atPath: scriptURL.path) {
                error = "Install script missing after staging: \(scriptURL.path). "
                      + "Check the CopyPythonSidecar build phase ran."
                return
            }
            if !fm.isExecutableFile(atPath: scriptURL.path) {
                // Try one more chmod before giving up.
                try? fm.setAttributes([.posixPermissions: 0o755],
                                      ofItemAtPath: scriptURL.path)
                if !fm.isExecutableFile(atPath: scriptURL.path) {
                    error = "Install script is not executable (chmod 755 failed): \(scriptURL.path)"
                    return
                }
            }
        } catch {
            // Surface the staging exception verbatim so users can see
            // exactly which file is missing — see PythonRuntime.StagingError.
            self.error = "Couldn't stage installer scripts: \(error.localizedDescription)"
            NSLog("[CellposeInstaller] stageScripts threw: \(error)")
            return
        }

        let venvPath = FileStore.shared.pythonVenvDir.path
        let scriptsDir = FileStore.shared.pythonDir.path
        // Ensure the parent dir exists (FileStore.init already does, but
        // belt-and-braces if FileStore is invoked before init for any reason).
        try? fm.createDirectory(
            at: FileStore.shared.pythonDir,
            withIntermediateDirectories: true
        )

        // Half-installed venv: if `venv/` exists but `venv/bin/pip` doesn't,
        // a previous attempt died before pip got bootstrapped. Re-running
        // `python -m venv` over the existing dir won't reliably fix it,
        // so nuke and re-create.
        let venvDir = FileStore.shared.pythonVenvDir
        let pipURL = venvDir.appendingPathComponent("bin/pip")
        if fm.fileExists(atPath: venvDir.path)
            && !fm.fileExists(atPath: pipURL.path) {
            NSLog("[CellposeInstaller] removing partial venv at \(venvDir.path)")
            try? fm.removeItem(at: venvDir)
        }

        // Reset transient state. Keep nothing from a previous attempt.
        output.removeAll()
        progressHint = "Starting…"
        error = nil
        done = false
        isRunning = true

        // Drop an "install incomplete" sentinel inside the python sidecar dir.
        // It survives even if the venv directory is rebuilt below, so
        // `CellposeAvailability.detect()` and `CellposeBrokenProbe.reason()`
        // can tell a half-finished install from a healthy one without having
        // to fork python -c "import cellpose" to verify. Removed in
        // `handleTermination` only when the script exits 0.
        try? fm.createDirectory(at: FileStore.shared.pythonDir,
                                withIntermediateDirectories: true)
        try? Data().write(to: FileStore.shared.installIncompleteSentinel)
        UserDefaults.standard.set(false, forKey: "cc-cellpose-importable")

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/bash")
        // Positional args: <venv_path> <scripts_dir>. See install_python.sh.
        proc.arguments = [scriptURL.path, venvPath, scriptsDir]
        proc.currentDirectoryURL = FileStore.shared.pythonDir

        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe // merge — the script logs to both
        self.process = proc

        // Stream stdout+stderr line-by-line.
        streamTask = Task { [weak self] in
            let handle = pipe.fileHandleForReading
            do {
                for try await line in handle.bytes.lines {
                    await self?.appendLine(line)
                }
            } catch {
                // Stream broken — most likely the process was terminated. Nothing actionable.
            }
        }

        // Bridge termination back to the main actor.
        proc.terminationHandler = { [weak self] p in
            let exitCode = p.terminationStatus
            Task { @MainActor [weak self] in
                self?.handleTermination(exitCode: exitCode)
            }
        }

        do {
            try proc.run()
            // Pass-13: hand the installer Process to the global tracker so a
            // mid-install app quit takes the pip subprocess down with us.
            ChildProcessTracker.shared.register(proc, kind: .install)
        } catch {
            // Pass-11 K6: clean up the orphaned streamTask if the process never
            // started — terminationHandler will not fire, so without this the
            // task would sit waiting on a dead pipe forever.
            streamTask?.cancel()
            streamTask = nil
            self.error = "Failed to start installer: \(error.localizedDescription)"
            isRunning = false
            self.process = nil
        }
    }

    func cancel() {
        process?.terminate()
        // termination handler fires and finalizes state.
    }

    // MARK: — Stream consumers

    private func appendLine(_ line: String) {
        output.append(line)
        // Cap to keep memory bounded over very long installs.
        if output.count > 500 {
            output.removeFirst(output.count - 500)
        }
        if let parsed = Self.parseHint(line) {
            progressHint = parsed
        }
        let lower = line.lowercased()
        if lower.contains("error") || lower.contains("traceback") {
            // Only surface first ERROR; subsequent ones can flood. Keep first.
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
            progressHint = "Cellpose installed."
            error = nil
            // Pass-11: invalidate the cached `import cellpose` probe so the next
            // isInstalled() query re-checks against the freshly-built venv
            // instead of returning the stale "no" from before the install ran.
            UserDefaults.standard.removeObject(forKey: "cc-cellpose-importable")
            // Pass-13: install finished cleanly — clear the sentinel so the
            // venv reads as healthy. We only clear on exit 0; user-cancel +
            // process-died paths leave it behind so the next launch knows.
            try? FileManager.default.removeItem(
                at: FileStore.shared.installIncompleteSentinel)
            // Notify the rest of the app that the install state has changed.
            // ModelsView observes this to refresh the InstallStateCache so rows
            // flip from "Get" / "Checking…" to "Activate" without waiting for
            // the user to re-enter the view.
            NotificationCenter.default.post(
                name: .init("cellpose-install-completed"),
                object: nil
            )
            // Pass-12 K1: venv just came into existence (or transitioned from
            // broken → healthy). Trigger the cache + AppState re-probe path.
            NotificationCenter.default.post(name: .ccVenvChanged, object: nil)
        } else {
            if error == nil {
                error = "Install failed (exit code \(exitCode))"
            }
        }
    }

    // MARK: — Helpers

    /// Best-effort friendly progress hint from a single install line.
    private static func parseHint(_ line: String) -> String? {
        let lower = line.lowercased()
        if lower.contains("creating venv") || lower.contains("creating ") && lower.contains("venv") {
            return "Creating virtual environment…"
        }
        if lower.contains("upgrading pip") {
            return "Upgrading pip…"
        }
        if lower.contains("collecting torch") || lower.contains("downloading torch") {
            return "Installing torch (~700 MB)…"
        }
        if lower.contains("collecting cellpose") || lower.contains("downloading cellpose") {
            return "Installing cellpose…"
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
            return "Done."
        }
        return nil
    }
}
