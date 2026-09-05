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

/// UI-facing snapshot. A bounded queue shares one probe for models using the
/// same runtime. Probe results are facts, never environment-change events.
@Observable
@MainActor
final class InstallStateCache {
    private var states: [String: InstallStateCachedValue] = [:]
    private(set) var isRefreshing = false
    private(set) var generation = 0
    private(set) var cellposeBrokenReason: String?
    @ObservationIgnored var onStateChange: (@MainActor (Set<String>) -> Void)?

    private struct Request {
        let key: String
        let ids: [String]
        let epoch: Int
        let registry: DetectorRegistry
        let models: [DetectionModelInfo]
    }
    @ObservationIgnored private var queued: [Request] = []
    @ObservationIgnored private var active: [UUID: Request] = [:]
    @ObservationIgnored private var epoch = 0
    @ObservationIgnored private weak var lastRegistry: DetectorRegistry?
    @ObservationIgnored private var lastModels: [DetectionModelInfo] = []
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var bannerTask: Task<Void, Never>?
    private let maximumConcurrentProbes = 2

    init(observeEnvironmentChanges: Bool = true) {
        guard observeEnvironmentChanges else { return }
        for name in [Notification.Name.ccVenvChanged, .ccVenv4Changed] {
            observers.append(NotificationCenter.default.addObserver(
                forName: name, object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in self?.environmentChanged() }
            })
        }
    }

    func get(_ modelId: String) -> InstallStateCachedValue { states[modelId] ?? .unknown }

    func markInstalling(_ modelId: String) {
        states[modelId] = .installing
        publish([modelId])
    }

    func markBroken(_ modelId: String, reason: String) {
        states[modelId] = .broken(reason: reason)
        publish([modelId])
    }

    /// Repeated launch/navigation requests join the existing check. Install
    /// completion explicitly supersedes older results with `force: true`.
    func refresh(modelId: String, registry: DetectorRegistry,
                 models: [DetectionModelInfo], force: Bool = false) {
        lastRegistry = registry
        lastModels = models
        guard let model = models.first(where: { $0.id == modelId }) else { return }
        if force {
            invalidate(registry: registry)
            states[modelId] = .unknown
            refreshBanner()
            for item in models { enqueue(model: item, registry: registry, models: models) }
        }
        enqueue(model: model, registry: registry, models: models)
        startQueuedProbes()
    }

    func refresh(for models: [DetectionModelInfo], registry: DetectorRegistry) {
        lastRegistry = registry
        lastModels = models
        // Re-opening the page or closing an install sheet must not duplicate
        // a check already in progress.
        guard !isRefreshing else {
            for model in models where get(model.id) == .unknown {
                enqueue(model: model, registry: registry, models: models)
            }
            startQueuedProbes()
            return
        }
        invalidate(registry: registry)
        refreshBanner()
        for model in models { enqueue(model: model, registry: registry, models: models) }
        startQueuedProbes()
    }

    private func environmentChanged() {
        guard let registry = lastRegistry else { return }
        invalidate(registry: registry)
        // Preserve a live install, whose completion will trigger a fresh check.
        states = states.filter { $0.value == .installing }
        publish(Set(lastModels.map(\.id)))
        refreshBanner()
        for model in lastModels { enqueue(model: model, registry: registry, models: lastModels) }
        startQueuedProbes()
    }

    private func invalidate(registry: DetectorRegistry) {
        epoch &+= 1
        queued.removeAll()
        registry.invalidateProbes()
        // Running work retains its slot until it exits. Superseding a request
        // must not permit a second wave of imports to exceed the concurrency cap.
    }

    private func enqueue(model: DetectionModelInfo, registry: DetectorRegistry,
                         models: [DetectionModelInfo]) {
        let key = DetectorRegistry.probeKey(for: model)
        guard !queued.contains(where: { $0.key == key && $0.epoch == epoch }),
              !active.values.contains(where: { $0.key == key && $0.epoch == epoch }) else { return }
        let ids = models.filter { DetectorRegistry.probeKey(for: $0) == key }.map(\.id)
        queued.append(Request(key: key, ids: ids, epoch: epoch, registry: registry, models: models))
    }

    private func startQueuedProbes() {
        while active.count < maximumConcurrentProbes,
              let next = queued.firstIndex(where: { pending in
                  !active.values.contains(where: { $0.key == pending.key })
              }) {
            let request = queued.remove(at: next)
            guard let id = request.ids.first else { continue }
            let token = UUID()
            active[token] = request
            Task { [weak self] in
                let installed = await request.registry.probeInstalled(id, models: request.models)
                guard let self else { return }
                self.active[token] = nil
                if request.epoch == self.epoch {
                    var changed: Set<String> = []
                    for id in request.ids where self.get(id) != .installing {
                        let next: InstallStateCachedValue = installed ? .installed : .notInstalled
                        if self.get(id) != next { self.states[id] = next; changed.insert(id) }
                    }
                    if !changed.isEmpty { self.publish(changed) }
                    if request.key == "runtime:" + ModelFamily.cellpose.rawValue {
                        self.refreshBanner()
                    }
                }
                self.startQueuedProbes()
            }
        }
        isRefreshing = !active.isEmpty || !queued.isEmpty
    }

    private func refreshBanner() {
        bannerTask?.cancel()
        let revision = epoch
        let directory = FileStore.shared.pythonVenvDir
        let sentinel = FileStore.shared.installIncompleteSentinel
        let script = FileStore.shared.pythonDir.appendingPathComponent("cellpose_detect.py")
        bannerTask = Task { [weak self] in
            let reason = await Task.detached(priority: .utility) {
                CellposeBrokenProbe.reason(directory: directory, sentinel: sentinel, script: script)
            }.value
            guard let self, !Task.isCancelled, revision == self.epoch else { return }
            self.cellposeBrokenReason = reason
        }
    }

    private func publish(_ ids: Set<String>) {
        generation &+= 1
        onStateChange?(ids)
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
        reason(directory: FileStore.shared.pythonVenvDir,
               sentinel: FileStore.shared.installIncompleteSentinel,
               script: FileStore.shared.pythonDir.appendingPathComponent("cellpose_detect.py"))
    }

    nonisolated static func reason(directory: URL, sentinel: URL, script: URL) -> String? {
        let fm = FileManager.default
        // Pass-13: sentinel left behind by an interrupted install run trumps
        // every filesystem heuristic. CellposeInstaller drops it on start()
        // and only clears it on a clean exit-0; a cancelled mid-pip will
        // leave it sitting next to a venv that may look complete on disk.
        if fm.fileExists(atPath: sentinel.path) {
            return "the previous install was cancelled or crashed mid-flight."
        }
        let venvDir = directory
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
        if fm.fileExists(atPath: script.path) { return nil }
        // Venv + pip + python all exist but availability isn't .available →
        // dependencies probably never finished installing.
        return "the Cellpose package is not importable from the venv."
    }

    static var isBroken: Bool { reason() != nil }
}
