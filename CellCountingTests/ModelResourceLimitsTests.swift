import Foundation
import Testing
@testable import CellCounting

/// Settings → General → Model resource use: what each choice means on a
/// given Mac, and the environment a model process gets. Pure values only:
/// nothing here reads or writes UserDefaults or starts a process.
struct ModelResourceLimitsTests {
    private static let gb: UInt64 = 1 << 30

    /// Synthetic 10-core (8 performance) Mac with 16 GB. The 8 GB GPU working
    /// set is chosen for round ratios, not measured.
    private static let mac16 = MachineResources(cpuCores: 10, performanceCores: 8,
                                                physicalMemoryBytes: 16 * gb, gpuWorkingSetBytes: 8 * gb)
    /// Synthetic 8-core (4 performance) Mac with 8 GB, for the floors.
    private static let mac8 = MachineResources(cpuCores: 8, performanceCores: 4,
                                               physicalMemoryBytes: 8 * gb, gpuWorkingSetBytes: 5 * gb)

    private static func limits(_ preset: ModelResourcePreset, cores: Int = 0, memoryGB: Int = 0,
                               on machine: MachineResources = mac16) -> ModelResourceLimits {
        ModelResourceLimits.resolve(ModelResourceChoice(preset: preset, customCPUCores: cores,
                                                        customMemoryGB: memoryGB), machine: machine)
    }

    // MARK: - Presets

    @Test func lightUsesTwoThreadsLowPriorityOneWarmModelAndAThirdOfMemory() {
        let light = Self.limits(.light)
        #expect(light.cpuThreads == 2)
        #expect(light.qualityOfService == .utility)
        #expect(light.memoryLimitGB == 5)          // 35 % of 16 GB, rounded down
        #expect(light.memoryLimitBytes == 5 * Self.gb)
        #expect(light.maxWarmWorkers == 1)
        #expect(light.idleTimeout == .seconds(60))

        let env = light.environmentAdditions
        for key in ModelResourceLimits.cpuThreadKeys { #expect(env[key] == "2", "\(key)") }
        #expect(env["CC_CPU_THREADS"] == "2")
        #expect(env["TF_NUM_INTEROP_THREADS"] == "2")
        #expect(env["PYTORCH_MPS_HIGH_WATERMARK_RATIO"] == "0.6250")   // 5 GB / 8 GB
        #expect(env["PYTORCH_MPS_LOW_WATERMARK_RATIO"] == "0.5000")
        #expect(env["CC_MEMORY_LIMIT_GB"] == "5")
        #expect(Set(env.keys) == Set(ModelResourceLimits.cpuThreadKeys + ["TF_NUM_INTEROP_THREADS"])
            .union(ModelResourceLimits.memoryKeys))
    }

    @Test func balancedUsesHalfThePerformanceCoresAndHalfOfMemory() {
        let balanced = Self.limits(.balanced)
        #expect(balanced.cpuThreads == 4)
        #expect(balanced.qualityOfService == .utility)
        #expect(balanced.memoryLimitGB == 8)
        #expect(balanced.maxWarmWorkers == 2)
        #expect(balanced.idleTimeout == .seconds(180))
        let env = balanced.environmentAdditions
        #expect(env["OMP_NUM_THREADS"] == "4")
        #expect(env["VECLIB_MAXIMUM_THREADS"] == "4")
        #expect(env["TF_NUM_INTRAOP_THREADS"] == "4")
        #expect(env["TF_NUM_INTEROP_THREADS"] == "2")
        // Balanced sets only the soft limit, at the budget; no hard cap, so
        // no run stops for memory and the error hint names no limit.
        #expect(!balanced.hasHardMemoryCap)
        #expect(env["PYTORCH_MPS_HIGH_WATERMARK_RATIO"] == nil)
        #expect(env["PYTORCH_MPS_LOW_WATERMARK_RATIO"] == "1.0000")
        #expect(env["CC_MEMORY_LIMIT_GB"] == nil)
        // The pool defaults match Balanced, the default choice.
        #expect(balanced.maxWarmWorkers == PersistentSidecarPool.defaultMaxWarmWorkers)
        #expect(balanced.idleTimeout == PersistentSidecarPool.defaultIdleTimeout)
    }

    @Test func maximumAddsNothingToTheEnvironment() {
        let maximum = Self.limits(.maximum)
        #expect(maximum.cpuThreads == nil)
        #expect(maximum.qualityOfService == .userInitiated)
        #expect(maximum.memoryLimitGB == nil)
        #expect(maximum.mpsHighWatermarkRatio == nil)
        #expect(maximum.mpsLowWatermarkRatio == nil)
        #expect(maximum.maxWarmWorkers == 2)
        #expect(maximum.idleTimeout == .seconds(600))
        #expect(maximum.environmentAdditions.isEmpty)
        let base = ["PATH": "/usr/bin:/bin", "HOME": "/Users/someone"]
        #expect(maximum.environment(merging: base) == base)
    }

    @Test func defaultChoiceIsBalancedAndStoredNamesAreStable() {
        #expect(ModelResourceChoice().preset == .balanced)
        #expect(ModelResourceChoice().customCPUCores == 0)
        #expect(ModelResourceChoice().customMemoryGB == 0)
        #expect(ModelResourcePreset.allCases.map(\.rawValue) == ["light", "balanced", "maximum", "custom"])
        #expect(ModelResourcePreset(rawValue: "turbo") == nil)
        #expect(ModelResourceChoice.presetKey == "cc-model-resources")
    }

    // MARK: - Floors and small Macs

    @Test func presetsNeverCapBelowFourGigabytes() {
        let light = Self.limits(.light, on: Self.mac8)
        let balanced = Self.limits(.balanced, on: Self.mac8)
        #expect(light.memoryLimitGB == 4)      // 35 % of 8 GB is 2.8 GB
        #expect(balanced.memoryLimitGB == 4)
        #expect(balanced.cpuThreads == 2)      // half of 4 performance cores
        #expect(Self.mac8.customMemoryRangeGB == 2...6)
        #expect(Self.mac16.customMemoryRangeGB == 2...14)
        #expect(Self.mac16.cpuCoreRange == 1...10)

        // Never more threads than the Mac has.
        let tiny = MachineResources(cpuCores: 1, performanceCores: 1,
                                    physicalMemoryBytes: 8 * Self.gb, gpuWorkingSetBytes: 5 * Self.gb)
        #expect(Self.limits(.light, on: tiny).cpuThreads == 1)
        #expect(Self.limits(.balanced, on: tiny).cpuThreads == 1)
    }

    // MARK: - Custom

    @Test func customStartsFromBalancedAndClampsToTheMac() {
        let unset = Self.limits(.custom)
        #expect(unset.cpuThreads == 4)
        #expect(unset.memoryLimitGB == 8)
        #expect(unset.qualityOfService == .utility)

        let large = Self.limits(.custom, cores: 64, memoryGB: 99)
        #expect(large.cpuThreads == 10)
        #expect(large.memoryLimitGB == 14)     // physical RAM minus 2 GB
        #expect(large.maxWarmWorkers == 2)
        #expect(large.idleTimeout == .seconds(180))

        let small = Self.limits(.custom, cores: 1, memoryGB: 3)
        #expect(small.cpuThreads == 1)
        #expect(small.environmentAdditions["TF_NUM_INTEROP_THREADS"] == "1")
        #expect(small.memoryLimitGB == 3)
        #expect(small.maxWarmWorkers == 1)     // under 8 GB only one model stays loaded
        #expect(small.idleTimeout == .seconds(60))

        #expect(Self.limits(.custom, memoryGB: 1).memoryLimitGB == 2)
    }

    // MARK: - MPS ratios

    @Test func watermarkRatiosAreClampedAndLowNeverExceedsHigh() {
        // 14 GB over an 8 GB working set would be 1.75: clamped to PyTorch's default.
        let large = Self.limits(.custom, memoryGB: 14)
        #expect(large.environmentAdditions["PYTORCH_MPS_HIGH_WATERMARK_RATIO"] == "1.7000")
        #expect(large.environmentAdditions["PYTORCH_MPS_LOW_WATERMARK_RATIO"] == "1.3600")

        // A tiny ratio never becomes 0, which PyTorch reads as "unlimited".
        let tiny = ModelResourceLimits.watermarkRatios(memoryGB: 2, gpuWorkingSetBytes: 1000 * Self.gb)
        #expect(tiny?.high == 0.01)
        #expect(tiny?.low == 0.008)
        #expect(ModelResourceLimits.formatRatio(0.008) == "0.0080")

        for memory in 1...200 {
            for workingSet: UInt64 in [1, 5, 8, 11, 48, 144] {
                guard let ratios = ModelResourceLimits.watermarkRatios(memoryGB: memory,
                                                                       gpuWorkingSetBytes: workingSet * Self.gb) else {
                    Issue.record("no ratios for \(memory) GB / \(workingSet) GB"); continue
                }
                #expect(ratios.high > 0 && ratios.high <= 1.7)
                #expect(ratios.low > 0 && ratios.low < ratios.high)
                // Rounded down: the cap never exceeds the budget unless clamped up to the floor.
                if ratios.high > 0.01 {
                    #expect(ratios.high * Double(workingSet) <= Double(memory) + 1e-9)
                }
            }
        }
        #expect(ModelResourceLimits.watermarkRatios(memoryGB: nil, gpuWorkingSetBytes: 8 * Self.gb)?.high == nil)
        #expect(ModelResourceLimits.watermarkRatios(memoryGB: 0, gpuWorkingSetBytes: 8 * Self.gb)?.high == nil)
        #expect(ModelResourceLimits.watermarkRatios(memoryGB: 8, gpuWorkingSetBytes: nil)?.high == nil)
        #expect(ModelResourceLimits.watermarkRatios(memoryGB: 8, gpuWorkingSetBytes: 0)?.high == nil)
    }

    @Test func withoutMetalNoMPSVariablesAreAdded() {
        let noMetal = MachineResources(cpuCores: 10, performanceCores: 8,
                                       physicalMemoryBytes: 16 * Self.gb, gpuWorkingSetBytes: nil)
        let light = Self.limits(.light, on: noMetal)
        #expect(light.cpuThreads == 2)
        #expect(light.maxWarmWorkers == 1)
        let env = light.environmentAdditions
        #expect(env["OMP_NUM_THREADS"] == "2")
        #expect(ModelResourceLimits.memoryKeys.allSatisfy { env[$0] == nil })
        #expect(light.summary == "Up to 2 of 10 cores · no GPU memory cap · lowest priority")
    }

    // MARK: - Environment merge

    @Test func mergeAddsKeysButNeverChangesExistingOnes() {
        let light = Self.limits(.light)
        let base = ["PATH": "/usr/bin:/bin", "HOME": "/Users/someone", "OMP_NUM_THREADS": "8"]
        let merged = light.environment(merging: base)
        for (key, value) in base { #expect(merged[key] == value, "\(key)") }
        #expect(merged["OMP_NUM_THREADS"] == "8")      // developer override kept
        #expect(merged["MKL_NUM_THREADS"] == "2")
        #expect(merged["PYTORCH_MPS_HIGH_WATERMARK_RATIO"] == "0.6250")
        #expect(merged.count == base.count + light.environmentAdditions.count - 1)
    }

    @Test func anExistingMPSRatioKeepsBothRatiosAndTheLimitNameOut() {
        let light = Self.limits(.light)
        for overridden in ["PYTORCH_MPS_HIGH_WATERMARK_RATIO", "PYTORCH_MPS_LOW_WATERMARK_RATIO"] {
            let merged = light.environment(merging: [overridden: "0.0"])
            #expect(merged[overridden] == "0.0")
            #expect(merged.count == 1 + ModelResourceLimits.cpuThreadKeys.count + 1, "\(overridden)")
            #expect(merged["CC_MEMORY_LIMIT_GB"] == nil)
            #expect(merged["CC_CPU_THREADS"] == "2")
        }
    }

    @Test func applySetsTheEnvironmentAndPriorityWithoutLaunching() {
        let process = Process()
        process.environment = ["PATH": "/bin", "VECLIB_MAXIMUM_THREADS": "6"]
        Self.limits(.light).apply(to: process)
        #expect(process.environment?["PATH"] == "/bin")
        #expect(process.environment?["VECLIB_MAXIMUM_THREADS"] == "6")
        #expect(process.environment?["CC_CPU_THREADS"] == "2")
        #expect(process.environment?["CC_LIMITS_FILE"] == ModelResourceControl.fileURL.path)
        #expect(ModelResourceControl.isModelProcess(process))
        #expect(process.qualityOfService == .utility)

        // With no environment of its own, the app's is the base. Maximum adds
        // only the live control file's path, so its limits can change later.
        let inherited = Process()
        Self.limits(.maximum).apply(to: inherited)
        #expect(inherited.environment == ModelResourceControl.environment(merging: ProcessInfo.processInfo.environment))
        #expect(inherited.environment?.count ?? 0 <= ProcessInfo.processInfo.environment.count + 1)
        #expect(inherited.qualityOfService == .userInitiated)
        #expect(!inherited.isRunning)
        #expect(!ModelResourceControl.isModelProcess(Process()))
    }

    /// The sidecars report a PyTorch MPS out-of-memory failure as
    /// `memory-limit`; it reaches the UI the way every other code does.
    @Test func memoryLimitErrorsSurfaceLikeOtherSidecarCodes() {
        let stdout = Data(#"{"error":"memory-limit","hint":"The model needed more memory than the 5 GB limit set in Settings → General → Model resource use. Raise the limit or choose Maximum, then run it again."}"#.utf8)
        do {
            try SidecarOutcome(exitCode: 5, stdout: stdout, stderr: Data()).throwIfFailed()
            Issue.record("A memory-limit payload must fail")
        } catch DetectionError.sidecarFailed(let exitCode, let message) {
            #expect(exitCode == 5)
            #expect(message.hasPrefix("memory-limit: The model needed more memory than the 5 GB limit"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    // MARK: - Changes and wording

    @Test func onlyEnvironmentOrPriorityChangesNeedANewProcess() {
        let light = Self.limits(.light), balanced = Self.limits(.balanced)
        #expect(!light.requiresRelaunch(comparedTo: light))
        #expect(light.requiresRelaunch(comparedTo: balanced))
        #expect(balanced.requiresRelaunch(comparedTo: Self.limits(.maximum)))
        #expect(balanced.requiresRelaunch(comparedTo: nil))
        // Custom with Balanced's values still differs: Custom sets a hard
        // memory cap, Balanced only the soft limit.
        let customAtBalancedValues = Self.limits(.custom, cores: 4, memoryGB: 8)
        #expect(customAtBalancedValues.requiresRelaunch(comparedTo: balanced))
        // Same Custom values: same processes.
        #expect(!customAtBalancedValues.requiresRelaunch(comparedTo: Self.limits(.custom, cores: 4, memoryGB: 8)))
        #expect(Self.limits(.custom, cores: 4, memoryGB: 9).requiresRelaunch(comparedTo: customAtBalancedValues))
    }

    @Test func summariesSayWhatEachChoiceMeans() {
        #expect(Self.limits(.balanced).summary == "Up to 4 of 10 cores · frees GPU memory above 8 GB · low priority")
        #expect(Self.limits(.light).summary == "Up to 2 of 10 cores · up to 5 GB · lowest priority")
        #expect(Self.limits(.maximum).summary == "All 10 cores · no memory limit · full priority")
        #expect(Self.limits(.custom, cores: 10, memoryGB: 6).summary == "All 10 cores · up to 6 GB · low priority")
        #expect(Self.limits(.light).loadedModelsDescription
            == "1 model stays loaded and unloads after 1 minute unused.")
        #expect(Self.limits(.maximum).loadedModelsDescription
            == "Up to 2 models stay loaded and unload after 10 minutes unused.")
    }
}
