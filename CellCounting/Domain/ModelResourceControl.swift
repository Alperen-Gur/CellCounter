import Foundation

/// The part of Model resource use a running model process can change without
/// restarting, as written to the live control file (`ModelResourceControl`).
/// The sidecars read it in `_cellpose_common.apply_live_limits`.
nonisolated struct ModelResourceLiveState: Codable, Equatable, Sendable {
    static let currentVersion = 1

    var version = ModelResourceLiveState.currentVersion
    var preset: String
    /// PyTorch's CPU thread count. Nil (Maximum) returns a process that was
    /// limited to `defaultCPUThreads`; one that never was is left alone.
    var cpuThreads: Int?
    var defaultCPUThreads: Int
    /// The hard GPU memory cap as PyTorch's MPS fraction of Metal's
    /// recommended working set. Nil: PyTorch's default (1.7). A higher or
    /// removed cap applies at once, a lower one after the current image.
    var memoryFraction: Double?
    /// The hard cap in GB, for the `memory-limit` hint. Nil without one.
    var memoryLimitGB: Int?
    /// Darwin background state. The app applies it to the processes it
    /// started (`setpriority`); Workbench model workers, which it does not
    /// track, apply it to themselves (`_workbench_resource_limits`).
    var background: Bool
    /// The variables a new model process starts with
    /// (`ModelResourceLimits.environmentAdditions`). Workbench model runs are
    /// launched from Python with an allowlisted environment and add these
    /// from here.
    var environment: [String: String]?

    init(preset: String, cpuThreads: Int?, defaultCPUThreads: Int, memoryFraction: Double?,
         memoryLimitGB: Int?, background: Bool, environment: [String: String]? = nil) {
        self.preset = preset
        self.cpuThreads = cpuThreads
        self.defaultCPUThreads = defaultCPUThreads
        self.memoryFraction = memoryFraction
        self.memoryLimitGB = memoryLimitGB
        self.background = background
        self.environment = environment
    }

    enum CodingKeys: String, CodingKey {
        case version, preset, background, environment
        case cpuThreads = "cpu_threads"
        case defaultCPUThreads = "default_cpu_threads"
        case memoryFraction = "memory_fraction"
        case memoryLimitGB = "memory_limit_gb"
    }
}

/// What a change of Model resource use does to processes already running.
nonisolated struct ModelResourceChange: Equatable, Sendable {
    /// Applied to running models at once.
    var priority = false
    var threads = false
    /// A higher or removed GPU memory cap.
    var memoryCapNow = false
    /// A lower GPU memory cap: after the image being analysed, so that image
    /// is never stopped by the change.
    var memoryCapAfterImage = false
    /// Parts only a new process picks up: launch priority class, the soft
    /// memory limit, thread counts of non-PyTorch libraries.
    var nextStart = false
    /// Number of warm models or their unload time (applied by the pool).
    var pool = false

    init(from old: ModelResourceLimits, to new: ModelResourceLimits) {
        priority = old.runsInBackground != new.runsInBackground
        threads = old.cpuThreads != new.cpuThreads
        let oldCap = old.mpsHighWatermarkRatio ?? ModelResourceLimits.maximumWatermarkRatio
        let newCap = new.mpsHighWatermarkRatio ?? ModelResourceLimits.maximumWatermarkRatio
        memoryCapNow = newCap > oldCap
        memoryCapAfterImage = newCap < oldCap
        nextStart = new.requiresRelaunch(comparedTo: old)
        pool = old.maxWarmWorkers != new.maxWarmWorkers || old.idleTimeout != new.idleTimeout
    }

    var isEmpty: Bool {
        !(priority || threads || memoryCapNow || memoryCapAfterImage || nextStart || pool)
    }

    var appliesNow: Bool { priority || threads || memoryCapNow }

    /// One or two plain sentences confirming a change made while a model is
    /// running: what the running model uses now and what waits.
    func confirmation(for new: ModelResourceLimits) -> String {
        var sentences = ["Resource use: \(new.preset.label)."]
        var now: [String] = []
        if priority { now.append(new.runsInBackground ? "lowest priority" : "normal priority") }
        if threads { now.append(new.cpuThreads.map { "up to \($0) CPU cores" } ?? "all CPU cores") }
        if memoryCapNow {
            now.append(new.hasHardMemoryCap ? "GPU memory up to \(new.memoryLimitGB ?? 0) GB" : "no GPU memory cap")
        }
        if !now.isEmpty {
            sentences.append("The running model now uses \(now.joined(separator: ", ")).")
        }
        if memoryCapAfterImage, let gb = new.memoryLimitGB {
            sentences.append("The \(gb) GB memory cap starts after the current image.")
        }
        if priority, new.runsInBackground {
            sentences.append("Analysis can be much slower while Light is on.")
        }
        if now.isEmpty && !memoryCapAfterImage {
            sentences.append("Applies when the next model starts.")
        }
        return sentences.joined(separator: " ")
    }
}

/// The live channel to running model processes.
///
/// 1. `publish` writes the live state atomically to one small JSON file per
///    user. Every model process the app starts gets its path in
///    `CC_LIMITS_FILE`; Workbench model runs find it at the same fixed path.
///    Workbench model workers, which the app does not track, watch the file
///    themselves and apply 2 and 3 on their own (`_workbench_resource_limits`).
/// 2. The app sets or clears Darwin's background state on each running model
///    process itself (`setBackground`), which needs no cooperation.
/// 3. `notify` sends SIGINFO; the sidecars' handler re-reads the file and
///    applies PyTorch's thread count and GPU memory cap without reloading
///    the model.
///
/// SIGINFO, not SIGUSR1: SIGINFO's default action is to discard the signal
/// (sys/signal.h), so a process that has not installed the handler yet
/// (still starting) or never does (a helper script) is unaffected. SIGUSR1
/// would end such a process. No installed package or sidecar uses SIGINFO.
nonisolated enum ModelResourceControl {
    static let environmentKey = "CC_LIMITS_FILE"
    static let signalNumber: Int32 = SIGINFO
    /// `PRIO_DARWIN_PROCESS` and `PRIO_DARWIN_BG` from sys/resource.h.
    static let prioDarwinProcess: Int32 = 4
    static let prioDarwinBackground: Int32 = 0x1000

    /// One file per user, in the per-user temporary folder, and kept after
    /// the app quits: detached Workbench job workers, which can outlive one
    /// app session, find it there (`_workbench_resource_limits.limits_file`)
    /// and follow whatever the current session chose. Every copy of the app
    /// shares the same preferences, so they write the same content.
    static let fileName = "cellcounter-model-limits.json"
    static let fileURL: URL = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)

    static func encode(_ state: ModelResourceLiveState) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(state)
    }

    static func decode(_ data: Data) throws -> ModelResourceLiveState {
        try JSONDecoder().decode(ModelResourceLiveState.self, from: data)
    }

    /// Writes the state atomically (a reader never sees half a file).
    @discardableResult
    static func publish(_ state: ModelResourceLiveState, to url: URL = fileURL) -> Bool {
        do {
            try encode(state).write(to: url, options: .atomic)
            return true
        } catch {
            NSLog("[ModelResourceControl] could not write \(url.path): \(error)")
            return false
        }
    }

    /// `base` plus `CC_LIMITS_FILE`, unless it is already set there.
    static func environment(merging base: [String: String], fileURL: URL = fileURL) -> [String: String] {
        var result = base
        if result[environmentKey] == nil { result[environmentKey] = fileURL.path }
        return result
    }

    /// Whether `process` was started with the live control file, i.e. by
    /// `ModelResourceLimits.apply(to:)`.
    static func isModelProcess(_ process: Process) -> Bool {
        process.environment?[environmentKey] != nil
    }

    /// Enters or leaves Darwin's background state (lowest CPU, disk and
    /// network priority) for a running process of this user.
    @discardableResult
    static func setBackground(_ background: Bool, pid: pid_t) -> Bool {
        guard pid > 0 else { return false }
        return setpriority(prioDarwinProcess, id_t(pid), background ? prioDarwinBackground : 0) == 0
    }

    /// Asks a running sidecar to re-read the control file.
    static func notify(pid: pid_t) {
        guard pid > 0 else { return }
        kill(pid, signalNumber)
    }
}
