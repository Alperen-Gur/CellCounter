import Foundation
import Observation

// MARK: — Cached install-state value
//
// Public surface preserved from the previous K3 shim — ModelsView reads via
// `state.installStateCache.get(id) == .installed`. We add `.installing` and
// `.broken(reason:)` per the pass-11 brief so the UI can distinguish a
// partially-installed venv from a never-attempted install. Existing equality
// checks against `.installed` keep working.

enum InstallStateCachedValue: Equatable {
    case unknown
    case installing
    case installed
    case notInstalled
    case broken(reason: String)
}

/// Pass-12 K1: stable type alias exposed to views as
/// `AppState.activeModelInstallState`. The cache already mirrors per-model
/// state via `InstallStateCachedValue`; the alias keeps the call-site readable
/// without churning the underlying enum.
typealias ModelInstallState = InstallStateCachedValue

extension Notification.Name {
    /// Posted whenever the cellpose venv directory is created or removed
    /// out-of-band (Settings → Reset, CellposeInstaller.reinstall, or the user
    /// rm-rf'ing it from Finder). InstallStateCache subscribes and re-probes;
    /// AppState refreshes the active-model install state mirror.
    static let ccVenvChanged = Notification.Name("ccVenvChanged")

    /// Pass-13: emitted by detection services as the subprocess writes log
    /// lines to stderr. userInfo: ["line": String]. AppState observes and
    /// mirrors into `processingStageLine` so ProcessingView can show the
    /// user what cellpose is actually doing instead of a frozen 0% bar.
    static let ccDetectionStage = Notification.Name("ccDetectionStage")
}

// MARK: — InstallStateCache
//
// One per AppState. Owns the per-model install-state map and orchestrates
// off-main refreshes. The synchronous `get(_:)` answers the UI from the cached
// snapshot — never spawns a subprocess on the caller. Refreshes run via
// `Task.detached`, call the registry's async `probeInstalled(_:models:)`, and
// publish results back on the MainActor.

@Observable
@MainActor
final class InstallStateCache {
    /// Per-model last-known state. UI reads via `get(_:)` and never blocks.
    private var states: [String: InstallStateCachedValue] = [:]
    /// True while at least one refresh task is in flight.
    var isRefreshing: Bool = false
    /// Bumped on every state mutation so callers can hang `.onChange` off it.
    /// `@Observable` already triggers SwiftUI redraws on `states` mutations,
    /// but the generation gives external observers an explicit hook.
    var generation: Int = 0

    /// Outstanding refresh tasks keyed by model id. Lets us dedupe and cancel.
    @ObservationIgnored
    private var inFlight: [String: Task<Void, Never>] = [:]

    /// Last (registry, models) seen by `refresh(for:registry:)`. Stashed so the
    /// `ccVenvChanged` notification observer can re-probe without forcing
    /// callers to wire up a separate notification handler. Weak on registry so
    /// the cache doesn't extend its lifetime.
    @ObservationIgnored
    private weak var lastRegistry: DetectorRegistry? = nil
    @ObservationIgnored
    private var lastModels: [DetectionModelInfo] = []

    /// Held so deinit can deregister. Process-lifetime in practice.
    @ObservationIgnored
    private var venvChangedObserver: NSObjectProtocol? = nil

    init() {
        // Pass-12 K1: re-probe every model when the venv is created or removed
        // out-of-band. Both Settings → Reset and `CellposeInstaller.reinstall`
        // post `ccVenvChanged` after they rm the directory. A Finder-side
        // delete is caught by `ModelsView.onAppear` calling `refresh(for:)`
        // directly — the observer handles the in-app paths.
        self.venvChangedObserver = NotificationCenter.default.addObserver(
            forName: .ccVenvChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self,
                      let registry = self.lastRegistry,
                      !self.lastModels.isEmpty else { return }
                // Invalidate then re-probe. Don't preserve .broken/.installing
                // here — the venv just moved, so prior partial states are
                // meaningless.
                self.states.removeAll()
                self.generation &+= 1
                self.refresh(for: self.lastModels, registry: registry)
            }
        }
    }

    // MARK: — Reads

    func get(_ modelId: String) -> InstallStateCachedValue {
        states[modelId] ?? .unknown
    }

    // MARK: — Writes

    /// Mark a model as currently installing so the UI can show the right chip.
    /// Called by the registry when an install starts.
    func markInstalling(_ modelId: String) {
        states[modelId] = .installing
        generation &+= 1
    }

    /// Mark a model as broken with a reason string. Used by the CellposeInstaller
    /// when it detects the venv didn't finish bootstrapping.
    func markBroken(_ modelId: String, reason: String) {
        states[modelId] = .broken(reason: reason)
        generation &+= 1
    }

    // MARK: — Refresh

    /// Force a single-id refresh (typically used after an install completes).
    func refresh(modelId: String, registry: DetectorRegistry, models: [DetectionModelInfo]) {
        // Pass-12 K1: even single-id calls stash the registry context so the
        // venv-change observer can fan out a full re-probe later.
        self.lastRegistry = registry
        self.lastModels = models
        if let existing = inFlight[modelId] {
            existing.cancel()
        }
        let task = Task.detached(priority: .userInitiated) { [weak self, weak registry] in
            guard let registry else { return }
            // `probeInstalled` is the async-off-main route. The registry hops
            // into the downloader's detached probe; nothing fires on main.
            let installed = await registry.probeInstalled(modelId, models: models)
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.inFlight[modelId] = nil
                let prior = self.states[modelId] ?? .unknown
                // Don't clobber an .installing state with .notInstalled if the
                // probe raced an install start.
                if case .installing = prior {
                    // leave as-is
                } else {
                    self.states[modelId] = installed ? .installed : .notInstalled
                }
                self.generation &+= 1

                // Pass-13: when a probe downgrades a model from .installed (or
                // .unknown) to .notInstalled, the AppState mirror for the
                // active model and `refreshDetector` need to re-run — otherwise
                // a stale `detector != nil` lets the user start a detection
                // against a venv we now know is broken. Reuse the venv-changed
                // notification rather than wiring a new channel; AppState
                // already does the right thing on that signal.
                if !installed,
                   case .installed = prior {
                    NotificationCenter.default.post(name: .ccVenvChanged, object: nil)
                } else if !installed,
                          case .unknown = prior {
                    NotificationCenter.default.post(name: .ccVenvChanged, object: nil)
                }
            }
        }
        inFlight[modelId] = task
    }

    /// Refresh every model the registry knows about. Marks `isRefreshing` true
    /// for the duration. Concurrent calls dedupe (the second is a no-op).
    ///
    /// Pass-16: each probe publishes its result independently the moment it
    /// returns — earlier code collected ALL pairs first, so one slow probe
    /// (notably cellpose 4 import on a cold venv4) left every other row stuck
    /// at "Checking…" until the laggard finished. Each probe also has an 8 s
    /// timeout so a wedged subprocess can't pin the cache state forever.
    func refresh(for models: [DetectionModelInfo], registry: DetectorRegistry) {
        // Stash context for the `ccVenvChanged` observer in `init`.
        self.lastRegistry = registry
        self.lastModels = models
        guard !isRefreshing else { return }
        isRefreshing = true
        let ids = models.map { $0.id }
        Task.detached(priority: .userInitiated) { [weak self, weak registry] in
            guard let registry else { return }
            await withTaskGroup(of: (String, Bool).self) { group in
                for id in ids {
                    group.addTask {
                        // Race the probe against an 8 s timeout. If the probe
                        // doesn't respond in time, treat as not-installed so
                        // the row shows a "Get" button rather than an
                        // indefinite spinner.
                        //
                        // Both branches must return non-nil for the first-to-
                        // finish race to work — earlier code had the timeout
                        // return nil, which the for-await simply skipped,
                        // making the timeout a no-op.
                        return await withTaskGroup(of: (String, Bool).self) { inner in
                            inner.addTask {
                                let ok = await registry.probeInstalled(id, models: models)
                                return (id, ok)
                            }
                            inner.addTask {
                                try? await Task.sleep(nanoseconds: 8_000_000_000)
                                return (id, false)
                            }
                            // First result wins; cancel the other.
                            if let result = await inner.next() {
                                inner.cancelAll()
                                return result
                            }
                            return (id, false)
                        }
                    }
                }
                // Publish each result the moment it returns — don't wait
                // for the slowest probe.
                for await (id, installed) in group {
                    await MainActor.run { [weak self] in
                        guard let self else { return }
                        switch self.states[id] ?? .unknown {
                        case .installing, .broken:
                            break
                        default:
                            self.states[id] = installed ? .installed : .notInstalled
                            self.generation &+= 1
                        }
                    }
                }
                await MainActor.run { [weak self] in self?.isRefreshing = false }
            }
        }
    }
}

// MARK: — CellposeBrokenProbe
//
// Cheap filesystem-only check for a half-installed venv. Returns a human
// reason when broken, nil otherwise. Pass-11: K3 surfaces this in ModelsView
// as a banner with a "Reinstall" CTA. Kept distinct from the richer
// `CellposeAvailability.Status.venvBroken(...)` case so callers that only
// need a yes/no don't have to switch on the whole enum.

struct CellposeBrokenProbe {
    /// Reason string when broken; nil when not broken.
    static func reason() -> String? {
        let fm = FileManager.default
        // Pass-13: sentinel left behind by an interrupted install run trumps
        // every filesystem heuristic. CellposeInstaller drops it on start()
        // and only clears it on a clean exit-0; a cancelled mid-pip will
        // leave it sitting next to a venv that may look complete on disk.
        if fm.fileExists(atPath: FileStore.shared.installIncompleteSentinel.path) {
            return "the previous install was cancelled or crashed mid-flight."
        }
        let venvDir = FileStore.shared.pythonVenvDir
        // Only meaningful if the venv directory exists at all.
        guard fm.fileExists(atPath: venvDir.path) else { return nil }
        let pip = venvDir.appendingPathComponent("bin/pip")
        let python = venvDir.appendingPathComponent("bin/python3")
        if !fm.fileExists(atPath: pip.path) {
            return "pip is missing — the previous install was interrupted before dependencies could be downloaded."
        }
        if !fm.isExecutableFile(atPath: python.path) {
            return "the python interpreter in the venv is missing or not executable."
        }
        // Pass-13: also surface a cached "cellpose not importable" verdict as
        // broken. Without this, a venv with python+pip but no cellpose just
        // reads as .available and the user's detection hangs forever.
        if let cached = UserDefaults.standard.object(forKey: "cc-cellpose-importable") as? Bool,
           cached == false {
            return "the Cellpose package is not importable from the venv."
        }
        // If `CellposeAvailability` reports the install as available, trust it.
        if case .available = CellposeAvailability.detect() { return nil }
        // Venv + pip + python all exist but availability isn't .available →
        // dependencies probably never finished installing.
        return "the Cellpose package is not importable from the venv."
    }

    static var isBroken: Bool { reason() != nil }
}
