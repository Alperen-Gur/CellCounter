import Foundation
import Metal

/// How much of the Mac the Python model processes may use at a time
/// (Settings → General → Model resource use).
///
/// Model runs are already serial (`AnalysisJobScheduler`); this caps what one
/// run, and the models kept loaded between runs, may take:
/// - CPU: the thread count of every numeric library the sidecars use
///   (PyTorch, Accelerate/OpenBLAS, NumExpr, TensorFlow, OpenCV), passed
///   through the environment and, for PyTorch, applied by the sidecar itself
///   through `CC_CPU_THREADS` (`_cellpose_common.apply_cpu_thread_limit`).
/// - Priority: the process quality of service. `.utility` lets macOS put the
///   interface and other apps first. Light also puts every model process in
///   Darwin's background state (lowest CPU, disk and network priority),
///   which the app can switch on and off while the process runs.
/// - Memory: PyTorch's MPS allocator limits. Light and Custom set a hard cap
///   (`PYTORCH_MPS_HIGH_WATERMARK_RATIO`), so Cellpose, Cellpose-SAM, Omnipose
///   and SAM stop with a `memory-limit` error instead of pushing the Mac into
///   swap. Balanced, the default, only sets the soft limit
///   (`PYTORCH_MPS_LOW_WATERMARK_RATIO`): above it PyTorch frees cached
///   memory sooner, but a run is never stopped for memory. PyTorch's default
///   hard limit is 1.7 × Metal's recommended working set, which is above
///   physical RAM. macOS cannot hard-cap a process's RAM, so the budget also
///   decides how many models stay loaded and for how long.
///
/// Priority changes only how fast a model runs, and the GPU memory limit only
/// when memory is handed back (or that a run stops with `memory-limit`). The
/// thread count does not change GPU arithmetic; CPU libraries may split some
/// sums differently across fewer threads, which is why Maximum adds no
/// limit variables at all: its processes see the environment they always
/// did, plus only the path of the live control file.
///
/// Changes reach running model processes without a reload
/// (`ModelResourceControl`, `ModelResourceChange`): priority and PyTorch's
/// thread count at once, a higher or removed GPU memory cap at once, a lower
/// one after the current image. What can only be set when a process starts
/// (the quality-of-service class, the soft memory limit, thread counts of
/// non-PyTorch libraries) reaches a warm model when it next starts.
nonisolated enum ModelResourcePreset: String, CaseIterable, Sendable {
    case light, balanced, maximum, custom

    var label: String {
        switch self {
        case .light: "Light"
        case .balanced: "Balanced"
        case .maximum: "Maximum"
        case .custom: "Custom"
        }
    }

    /// One plain sentence for Settings.
    var purpose: String {
        switch self {
        case .light: "Your Mac stays fully usable, but analysis can be much slower: models run at background priority, mostly on the Mac's energy-saving cores"
        case .balanced: "Recommended: good speed while other apps stay usable"
        case .maximum: "Fastest analysis; other apps may slow down while a model runs"
        case .custom: "Your own core and memory limits"
        }
    }

    /// Menu items: the name and what it means for the Mac.
    var menuTitle: String {
        switch self {
        case .light: "Light — Mac stays usable, analysis slower"
        case .balanced: "Balanced — recommended"
        case .maximum: "Maximum — fastest"
        case .custom: "Custom — your limits"
        }
    }
}

/// The stored choice. Launch sites read it from `UserDefaults` on every
/// process start, so a change applies to the next model process.
nonisolated struct ModelResourceChoice: Equatable, Sendable {
    static let presetKey = "cc-model-resources"
    static let customCPUCoresKey = "cc-model-resources-cores"
    static let customMemoryGBKey = "cc-model-resources-memory-gb"

    var preset: ModelResourcePreset = .balanced
    /// Custom only. 0 means not chosen yet, and Balanced's value is used.
    var customCPUCores = 0
    /// Custom only, in GB. 0 means not chosen yet, and Balanced's value is used.
    var customMemoryGB = 0

    static func load(from defaults: UserDefaults) -> ModelResourceChoice {
        ModelResourceChoice(
            preset: defaults.string(forKey: presetKey).flatMap(ModelResourcePreset.init(rawValue:)) ?? .balanced,
            customCPUCores: max(0, defaults.integer(forKey: customCPUCoresKey)),
            customMemoryGB: max(0, defaults.integer(forKey: customMemoryGBKey)))
    }
}

/// The Mac the limits are computed for. Tests pass their own values.
nonisolated struct MachineResources: Equatable, Sendable {
    /// Cores macOS schedules on (`activeProcessorCount`).
    var cpuCores: Int
    /// Performance cores (`hw.perflevel0.physicalcpu` on Apple silicon).
    var performanceCores: Int
    var physicalMemoryBytes: UInt64
    /// Metal's `recommendedMaxWorkingSetSize`, the base of PyTorch's MPS
    /// memory ratios. Nil when no Metal device is available.
    var gpuWorkingSetBytes: UInt64?

    static let current = detect()

    var physicalMemoryGB: Double {
        Double(physicalMemoryBytes) / Double(ModelResourceLimits.bytesPerGB)
    }

    var cpuCoreRange: ClosedRange<Int> { 1...max(1, cpuCores) }

    /// Custom memory limit: 2 GB up to physical RAM minus 2 GB.
    var customMemoryRangeGB: ClosedRange<Int> {
        2...max(2, Int(physicalMemoryGB.rounded(.down)) - 2)
    }

    static func detect() -> MachineResources {
        let info = ProcessInfo.processInfo
        let cores = max(1, info.activeProcessorCount)
        let performance = sysctlInt("hw.perflevel0.physicalcpu")
            ?? sysctlInt("hw.physicalcpu")
            ?? max(1, cores / 2)
        let workingSet = MTLCreateSystemDefaultDevice()?.recommendedMaxWorkingSetSize ?? 0
        return MachineResources(cpuCores: cores,
                                performanceCores: min(cores, max(1, performance)),
                                physicalMemoryBytes: info.physicalMemory,
                                gpuWorkingSetBytes: workingSet > 0 ? workingSet : nil)
    }

    private static func sysctlInt(_ name: String) -> Int? {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0, value > 0 else { return nil }
        return Int(value)
    }
}

/// What one choice means on one Mac, and how a model process is started
/// with it.
nonisolated struct ModelResourceLimits: Equatable, Sendable {
    static let bytesPerGB: UInt64 = 1 << 30
    /// Light and Balanced never cap below this. A warm Cellpose-SAM worker
    /// was measured at about 3.2 GB of MPS driver memory.
    static let presetMemoryFloorGB = 4
    /// Below this, Settings warns that Cellpose-SAM may not fit.
    static let cellposeSAMMemoryGB = 4
    /// From this budget up, two models may stay loaded (an ensemble keeps
    /// both members warm); below it only one.
    static let twoWarmModelsMemoryGB = 8
    /// PyTorch's own default high watermark. The limit never loosens past it.
    static let maximumWatermarkRatio = 1.7
    /// 0 would mean "unlimited" to PyTorch, so ratios never round down to it.
    static let minimumWatermarkRatio = 0.01

    static let cpuThreadKeys = [
        "OMP_NUM_THREADS", "MKL_NUM_THREADS", "OPENBLAS_NUM_THREADS",
        "VECLIB_MAXIMUM_THREADS", "NUMEXPR_NUM_THREADS", "TF_NUM_INTRAOP_THREADS",
        "OPENCV_FOR_THREADS_NUM", "CC_CPU_THREADS",
    ]
    /// TensorFlow runs this many operations at once, each on the intra-op
    /// pool, so it stays small rather than multiplying the thread count.
    static let interOpThreadKey = "TF_NUM_INTEROP_THREADS"
    static let mpsHighWatermarkKey = "PYTORCH_MPS_HIGH_WATERMARK_RATIO"
    static let mpsLowWatermarkKey = "PYTORCH_MPS_LOW_WATERMARK_RATIO"
    /// Read by the sidecars only to name the limit in a `memory-limit` hint.
    static let memoryLimitKey = "CC_MEMORY_LIMIT_GB"
    static let memoryKeys: Set<String> = [mpsHighWatermarkKey, mpsLowWatermarkKey, memoryLimitKey]

    let preset: ModelResourcePreset
    /// All cores of this Mac, for display.
    let totalCPUCores: Int
    /// Nil leaves every library at its own default (all cores), exactly as
    /// before this setting existed.
    let cpuThreads: Int?
    /// PyTorch's own default thread count on this Mac (its performance
    /// cores on Apple silicon); a running model returns to it on Maximum.
    let defaultCPUThreads: Int
    let qualityOfService: QualityOfService
    /// Nil: no memory budget.
    let memoryLimitGB: Int?
    let maxWarmWorkers: Int
    let idleTimeout: Duration
    /// Nil when there is no budget or no Metal device.
    let mpsHighWatermarkRatio: Double?
    let mpsLowWatermarkRatio: Double?

    /// The limits stored in Settings, for this Mac. Cheap: reads three
    /// defaults keys; the machine is measured once per launch.
    static var current: ModelResourceLimits {
        resolve(.load(from: .standard), machine: .current)
    }

    var memoryLimitBytes: UInt64? { memoryLimitGB.map { UInt64($0) * Self.bytesPerGB } }

    static func resolve(_ choice: ModelResourceChoice, machine: MachineResources) -> ModelResourceLimits {
        let cores = max(1, machine.cpuCores)
        func presetGB(_ fraction: Double) -> Int {
            max(presetMemoryFloorGB, Int((machine.physicalMemoryGB * fraction).rounded(.down)))
        }
        // About half the performance cores: the model stays quick and the
        // other half, plus the efficiency cores, stay free.
        let balancedThreads = min(cores, max(2, machine.performanceCores / 2))
        let balancedGB = presetGB(0.5)

        switch choice.preset {
        case .light:
            return make(.light, machine: machine, threads: min(cores, 2), qos: .utility,
                        memoryGB: presetGB(0.35), warm: 1, idleSeconds: 60)
        case .balanced:
            // A soft limit only: the default must never stop a run that would
            // have finished before (an 8 GB Mac gets a 4 GB budget, close to
            // Cellpose-SAM's measured 3.2 GB).
            return make(.balanced, machine: machine, threads: balancedThreads, qos: .utility,
                        memoryGB: balancedGB, warm: 2, idleSeconds: 180, hardCap: false)
        case .maximum:
            return make(.maximum, machine: machine, threads: nil, qos: .userInitiated,
                        memoryGB: nil, warm: 2, idleSeconds: 600)
        case .custom:
            let threads = choice.customCPUCores > 0 ? min(cores, choice.customCPUCores) : balancedThreads
            let range = machine.customMemoryRangeGB
            let requested = choice.customMemoryGB > 0 ? choice.customMemoryGB : balancedGB
            let memoryGB = min(range.upperBound, max(range.lowerBound, requested))
            let two = memoryGB >= twoWarmModelsMemoryGB
            return make(.custom, machine: machine, threads: threads, qos: .utility,
                        memoryGB: memoryGB, warm: two ? 2 : 1, idleSeconds: two ? 180 : 60)
        }
    }

    private static func make(
        _ preset: ModelResourcePreset, machine: MachineResources, threads: Int?,
        qos: QualityOfService, memoryGB: Int?, warm: Int, idleSeconds: Int,
        hardCap: Bool = true
    ) -> ModelResourceLimits {
        let ratios = watermarkRatios(memoryGB: memoryGB, gpuWorkingSetBytes: machine.gpuWorkingSetBytes)
        // Without a hard cap, the budget itself becomes the soft limit; it
        // never exceeds 1.7, PyTorch's default hard limit, so low ≤ high holds.
        return ModelResourceLimits(
            preset: preset, totalCPUCores: max(1, machine.cpuCores), cpuThreads: threads,
            defaultCPUThreads: max(1, machine.performanceCores),
            qualityOfService: qos, memoryLimitGB: memoryGB, maxWarmWorkers: warm,
            idleTimeout: .seconds(idleSeconds),
            mpsHighWatermarkRatio: hardCap ? ratios?.high : nil,
            mpsLowWatermarkRatio: hardCap ? ratios?.low : ratios?.high)
    }

    /// True when a run stops with `memory-limit` above the budget.
    var hasHardMemoryCap: Bool { mpsHighWatermarkRatio != nil }

    /// Light runs model processes in Darwin's background state. Launch QoS
    /// stays `.utility` (as Balanced), so leaving the background state while a
    /// process runs returns it to exactly Balanced's priority.
    var runsInBackground: Bool { preset == .light }

    /// What a running process can change without restarting
    /// (`ModelResourceControl` writes it to the control file).
    var liveState: ModelResourceLiveState {
        ModelResourceLiveState(preset: preset.rawValue, cpuThreads: cpuThreads,
                               defaultCPUThreads: defaultCPUThreads,
                               memoryFraction: mpsHighWatermarkRatio,
                               memoryLimitGB: hasHardMemoryCap ? memoryLimitGB : nil,
                               background: runsInBackground,
                               environment: environmentAdditions)
    }

    /// PyTorch's MPS limits as fractions of Metal's recommended working set:
    /// high = budget / working set, clamped to [0.01, 1.7]; low = 0.8 × high.
    /// Above the high ratio an allocation fails ("MPS backend out of
    /// memory"); above the low one PyTorch frees cached buffers and commits
    /// GPU work sooner. PyTorch refuses to start when low > high, and its
    /// defaults (1.4 and 1.7) keep the low one at about 0.8 of the high.
    /// Both are rounded down to 4 decimals, so the low ratio stays below the
    /// high one and neither exceeds the budget.
    static func watermarkRatios(memoryGB: Int?, gpuWorkingSetBytes: UInt64?) -> (high: Double, low: Double)? {
        guard let memoryGB, memoryGB > 0, let workingSet = gpuWorkingSetBytes, workingSet > 0 else { return nil }
        let raw = Double(UInt64(memoryGB) * bytesPerGB) / Double(workingSet)
        let minimum = Int((minimumWatermarkRatio * 10_000).rounded())
        let maximum = Int((maximumWatermarkRatio * 10_000).rounded())
        let high = min(maximum, max(minimum, Int((raw * 10_000).rounded(.down))))
        let low = high * 4 / 5
        return (Double(high) / 10_000, Double(low) / 10_000)
    }

    static func interOpThreads(for threads: Int) -> Int { max(1, min(2, threads)) }

    static func formatRatio(_ ratio: Double) -> String { String(format: "%.4f", ratio) }

    /// The keys this choice adds to a model process's environment.
    var environmentAdditions: [String: String] {
        var added: [String: String] = [:]
        if let cpuThreads {
            for key in Self.cpuThreadKeys { added[key] = String(cpuThreads) }
            added[Self.interOpThreadKey] = String(Self.interOpThreads(for: cpuThreads))
        }
        if let low = mpsLowWatermarkRatio, let memoryLimitGB {
            added[Self.mpsLowWatermarkKey] = Self.formatRatio(low)
            if let high = mpsHighWatermarkRatio {
                added[Self.mpsHighWatermarkKey] = Self.formatRatio(high)
                // Only a hard cap can cause `memory-limit`, so only then
                // does the error hint name the limit.
                added[Self.memoryLimitKey] = String(memoryLimitGB)
            }
        }
        return added
    }

    /// `base` plus `environmentAdditions`. Nothing in `base` is removed or
    /// changed: a key already set there (a developer override) keeps its
    /// value. The two MPS ratios are one setting, because PyTorch refuses to
    /// start when the low one is above the high one; if either is already
    /// set, neither is added, nor the limit the error hint would name.
    func environment(merging base: [String: String]) -> [String: String] {
        var result = base
        let mpsOverridden = base[Self.mpsHighWatermarkKey] != nil || base[Self.mpsLowWatermarkKey] != nil
        for (key, value) in environmentAdditions where result[key] == nil {
            if mpsOverridden, Self.memoryKeys.contains(key) { continue }
            result[key] = value
        }
        return result
    }

    /// Sets the environment (merged into the process's own, or the app's
    /// when it has none), the path of the live control file and the quality
    /// of service. Call before `run()`. `ChildProcessTracker` recognises such
    /// processes by that path and applies the background state after launch.
    func apply(to process: Process) {
        let base = process.environment ?? ProcessInfo.processInfo.environment
        process.environment = ModelResourceControl.environment(merging: environment(merging: base))
        process.qualityOfService = qualityOfService
    }

    /// Whether a process started now would differ from one started with
    /// `other` in what only a new process picks up (environment and launch
    /// priority). Nothing forces a restart for it: a warm model picks it up
    /// when it next starts. Pool limits alone never need a new process.
    func requiresRelaunch(comparedTo other: ModelResourceLimits?) -> Bool {
        guard let other else { return true }
        return other.environmentAdditions != environmentAdditions || other.qualityOfService != qualityOfService
    }

    // MARK: - Description

    /// "Up to 4 of 10 cores · up to 8 GB · low priority"
    var summary: String {
        let cpu: String
        if let cpuThreads, cpuThreads < totalCPUCores {
            cpu = "Up to \(cpuThreads) of \(totalCPUCores) cores"
        } else {
            cpu = "All \(totalCPUCores) cores"
        }
        let memory: String
        if let memoryLimitGB {
            if hasHardMemoryCap {
                memory = "up to \(memoryLimitGB) GB"
            } else if mpsLowWatermarkRatio != nil {
                memory = "frees GPU memory above \(memoryLimitGB) GB"
            } else {
                memory = "no GPU memory cap"
            }
        } else {
            memory = "no memory limit"
        }
        return [cpu, memory, priorityDescription].joined(separator: " · ")
    }

    /// "lowest priority" (Light, background), "low priority", "full priority".
    var priorityDescription: String {
        if runsInBackground { return "lowest priority" }
        return qualityOfService == .utility ? "low priority" : "full priority"
    }

    /// "Up to 2 models stay loaded and unload after 3 minutes unused."
    var loadedModelsDescription: String {
        let minutes = max(1, Int(idleTimeout.components.seconds) / 60)
        let after = minutes == 1 ? "1 minute" : "\(minutes) minutes"
        let models = maxWarmWorkers == 1 ? "1 model stays" : "Up to \(maxWarmWorkers) models stay"
        return "\(models) loaded and unload\(maxWarmWorkers == 1 ? "s" : "") after \(after) unused."
    }
}
