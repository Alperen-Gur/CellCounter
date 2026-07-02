import Foundation
import AppKit

/// Pass-13: keep tabs on every Python subprocess CellCounter spawns so they
/// can't outlive the app.
///
/// Why this exists: the user reported "detection stuck at 0%" while five
/// `cellpose_detect.py` processes from earlier runs were still alive with
/// PPID=1 (re-parented to launchd after CellCounter died/crashed). They were
/// saturating the cores so fresh detection couldn't make progress. The Process
/// API doesn't auto-kill children when the parent exits, so we have to do it
/// ourselves on `NSApplicationWillTerminate` AND mop up survivors at next
/// launch.
///
/// Usage:
///   CellCounter.registerSpawnedProcess(p)        // call right after p.run()
///   CellCounter.installTrackerLifecycle()        // call once at app init
///
/// The tracker is intentionally @MainActor — the register/unregister set is
/// small and only touched from the main thread (detection completions hop
/// back via MainActor.run anyway). Concurrency contention is a non-issue.
@MainActor
final class ChildProcessTracker {
    static let shared = ChildProcessTracker()

    /// Pass-14: tag every tracked Process so Cancel-in-ProcessingView can kill
    /// just the detection subprocess and leave a concurrent pip install alone.
    /// Previously the Cancel button called `terminateAll()` which SIGTERM'd
    /// every tracked Process — including an in-progress installer — leading
    /// to three back-to-back "detection cancelled" logs when re-run fired
    /// while a stale process was still being torn down.
    enum Kind {
        case detection
        case install
        case other
    }

    /// Active processes we've started. Held strongly so the Process objects
    /// don't deallocate (which would orphan the kernel-level child).
    private var live: Set<ObjectIdentifier> = []
    private var registry: [ObjectIdentifier: Process] = [:]
    private var kinds: [ObjectIdentifier: Kind] = [:]
    private var didInstallLifecycle = false

    /// Names we know we own. Used by the orphan sweep on launch.
    /// Add a script name to this list if you spawn a new long-running subprocess.
    static let ownedScriptBasenames: Set<String> = [
        "cellpose_detect.py",
        "cellpose_train.py",
        "stardist_detect.py",
        "yolo_detect.py",
        "sam_detect.py",
        "install_python.sh",
    ]

    private init() {}

    /// Track a Process. Call AFTER `process.run()` returns successfully — a
    /// process that never starts has no kernel child to clean up.
    ///
    /// `kind` defaults to `.other` so existing call sites stay safe. Detection
    /// services should pass `.detection`; the installer passes `.install`.
    func register(_ process: Process, kind: Kind = .other) {
        let key = ObjectIdentifier(process)
        registry[key] = process
        kinds[key] = kind
        live.insert(key)

        // Chain into the existing termination handler if any. We append our
        // cleanup; we don't replace it.
        let prior = process.terminationHandler
        process.terminationHandler = { [weak self] proc in
            prior?(proc)
            Task { @MainActor [weak self] in
                self?.forget(proc)
            }
        }
    }

    func forget(_ process: Process) {
        let key = ObjectIdentifier(process)
        live.remove(key)
        registry.removeValue(forKey: key)
        kinds.removeValue(forKey: key)
    }

    /// Terminate every tracked Process. Called from the willTerminate hook
    /// and from explicit "Cancel all detections" paths.
    func terminateAll() {
        // Pass-14: log the call stack so we can tell whether terminateAll is
        // firing from the Cancel button, willTerminate, or somewhere unexpected.
        // Three back-to-back SIGTERMs in the user's log suggested a spurious
        // invocation chain; the stack identifies the offender.
        let frames = Thread.callStackSymbols.prefix(6).joined(separator: "\n  ")
        NSLog("[ChildProcessTracker] terminateAll() called by:\n  \(frames)")

        for key in live {
            guard let proc = registry[key], proc.isRunning else { continue }
            let k = kinds[key].map { "\($0)" } ?? "other"
            NSLog("[ChildProcessTracker] SIGTERM pid=\(proc.processIdentifier) kind=\(k)")
            proc.terminate()
        }
        // Give them a beat to exit cleanly, then SIGKILL stragglers.
        Thread.sleep(forTimeInterval: 0.3)
        for key in live {
            guard let proc = registry[key], proc.isRunning else { continue }
            NSLog("[ChildProcessTracker] SIGKILL pid=\(proc.processIdentifier)")
            kill(proc.processIdentifier, SIGKILL)
        }
        live.removeAll()
        registry.removeAll()
        kinds.removeAll()
    }

    /// Pass-14: SIGTERM only `.detection`-kind processes. Used by the Cancel
    /// button in ProcessingView so an in-flight installer (or any other
    /// tracked Process) survives a user-initiated detection cancel.
    ///
    /// The orphan sweep + willTerminate path still go through `terminateAll()`
    /// — that semantics is unchanged.
    func terminateDetectionTasks() {
        let frames = Thread.callStackSymbols.prefix(6).joined(separator: "\n  ")
        NSLog("[ChildProcessTracker] terminateDetectionTasks() called by:\n  \(frames)")

        // Snapshot the keys to terminate so we don't mutate while iterating
        // (terminationHandler → forget can race with this loop).
        let detectionKeys = live.filter { kinds[$0] == .detection }
        for key in detectionKeys {
            guard let proc = registry[key], proc.isRunning else { continue }
            NSLog("[ChildProcessTracker] SIGTERM pid=\(proc.processIdentifier) kind=detection")
            proc.terminate()
        }
        Thread.sleep(forTimeInterval: 0.3)
        for key in detectionKeys {
            guard let proc = registry[key], proc.isRunning else { continue }
            NSLog("[ChildProcessTracker] SIGKILL pid=\(proc.processIdentifier) kind=detection")
            kill(proc.processIdentifier, SIGKILL)
        }
        // Don't drop entries here — the chained terminationHandler calls
        // `forget` for each Process once the kernel reaps it. Forcing removal
        // would race that and leak the Kind tag for any survivors.
    }

    /// Wire the NSApplication termination hook + kick the orphan sweep.
    /// Idempotent — safe to call from App.init even if it fires twice.
    ///
    /// IMPORTANT: the sweep runs on a background thread. Spawning `ps -ax`
    /// synchronously from the App initializer would deadlock startup: the
    /// pipe buffer fills before `waitUntilExit()` returns, the child blocks
    /// writing, and we block waiting → the window never opens. (This is the
    /// bug the user hit on the first Pass-13 build.)
    func installLifecycle() {
        guard !didInstallLifecycle else { return }
        didInstallLifecycle = true

        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { _ in
            // willTerminate runs synchronously on the main thread; we're
            // already main-isolated here.
            MainActor.assumeIsolated {
                ChildProcessTracker.shared.terminateAll()
            }
        }

        // Kick the orphan sweep off the main thread so a slow `ps` (or a
        // future bug in the sweep itself) can never block window creation.
        Task.detached(priority: .background) {
            Self.sweepOrphans()
        }
    }

    /// Find and kill orphaned subprocesses from previous CellCounter runs.
    /// PPID=1 + cmdline contains one of our scripts = ours.
    ///
    /// Not @MainActor — invoked from a detached Task at app launch.
    nonisolated static func sweepOrphans() {
        // `ps -ax -o pid=,ppid=,command=` — empty header so we get raw rows.
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/ps")
        task.arguments = ["-ax", "-o", "pid=,ppid=,command="]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()
        do {
            try task.run()
        } catch {
            NSLog("[ChildProcessTracker] orphan sweep: failed to run ps: \(error)")
            return
        }
        // CRITICAL: drain the pipe BEFORE waitUntilExit. `ps -ax` typically
        // emits 50-200 KB which overflows the 16-64 KB pipe buffer; without
        // a concurrent reader the child blocks on write and we'd hang
        // forever in waitUntilExit. readToEnd() reads until the child closes
        // stdout (i.e., exits), at which point waitUntilExit is instant.
        let data = (try? pipe.fileHandleForReading.readToEnd()) ?? Data()
        task.waitUntilExit()
        guard let text = String(data: data, encoding: .utf8) else { return }

        var killed: [pid_t] = []
        for line in text.split(separator: "\n") {
            // Each line: "<pid> <ppid> <command...>"
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            let parts = trimmed.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard parts.count >= 3,
                  let pid = pid_t(parts[0]),
                  let ppid = pid_t(parts[1]) else { continue }
            // Only sweep orphans — anything still attached to a parent isn't ours.
            guard ppid == 1 else { continue }
            let command = String(parts[2])
            let isOurs = ownedScriptBasenames.contains { command.contains($0) }
            guard isOurs else { continue }
            NSLog("[ChildProcessTracker] orphan sweep: SIGKILL pid=\(pid) (\(command.prefix(80)))")
            if kill(pid, SIGKILL) == 0 {
                killed.append(pid)
            }
        }
        if !killed.isEmpty {
            NSLog("[ChildProcessTracker] reaped \(killed.count) orphan subprocess(es) from prior session")
        }
    }
}
