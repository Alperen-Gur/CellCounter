import Foundation
import Testing
@testable import CellCounting

/// Switching Model resource use while a model runs: the live control file
/// the sidecars re-read, and which parts of a change apply now, after the
/// current image, or at the next process start. Pure values; the only file
/// written is a temporary one. No process is started or signalled.
struct ModelResourceControlTests {
    private static let gb: UInt64 = 1 << 30
    /// Synthetic 10-core (8 performance) Mac with 16 GB; the 8 GB GPU working
    /// set is chosen for round ratios, not measured.
    private static let mac16 = MachineResources(cpuCores: 10, performanceCores: 8,
                                                physicalMemoryBytes: 16 * gb, gpuWorkingSetBytes: 8 * gb)
    private static let noMetal = MachineResources(cpuCores: 10, performanceCores: 8,
                                                  physicalMemoryBytes: 16 * gb, gpuWorkingSetBytes: nil)

    private static func limits(_ preset: ModelResourcePreset, cores: Int = 0, memoryGB: Int = 0,
                               on machine: MachineResources = mac16) -> ModelResourceLimits {
        ModelResourceLimits.resolve(ModelResourceChoice(preset: preset, customCPUCores: cores,
                                                        customMemoryGB: memoryGB), machine: machine)
    }

    // MARK: - Live state

    @Test func liveStateCarriesWhatARunningProcessCanChange() {
        let light = Self.limits(.light).liveState
        #expect(light.preset == "light")
        #expect(light.cpuThreads == 2)
        #expect(light.defaultCPUThreads == 8)
        #expect(light.memoryFraction == 0.625)
        #expect(light.memoryLimitGB == 5)
        #expect(light.background)

        // Balanced has only a soft limit, which a running process cannot change.
        let balanced = Self.limits(.balanced).liveState
        #expect(balanced.cpuThreads == 4)
        #expect(balanced.memoryFraction == nil)
        #expect(balanced.memoryLimitGB == nil)
        #expect(!balanced.background)

        let maximum = Self.limits(.maximum).liveState
        #expect(maximum.cpuThreads == nil)
        #expect(maximum.memoryFraction == nil)
        #expect(!maximum.background)

        let custom = Self.limits(.custom, cores: 6, memoryGB: 6).liveState
        #expect(custom.cpuThreads == 6)
        #expect(custom.memoryFraction == 0.75)
        #expect(custom.memoryLimitGB == 6)
        #expect(!custom.background)
    }

    @Test func onlyLightRunsInTheBackgroundAndItsLaunchPriorityMatchesBalanced() {
        #expect(Self.limits(.light).runsInBackground)
        #expect(!Self.limits(.balanced).runsInBackground)
        #expect(!Self.limits(.maximum).runsInBackground)
        #expect(!Self.limits(.custom, cores: 1, memoryGB: 2).runsInBackground)
        // Leaving the background state returns a Light process to Balanced's priority.
        #expect(Self.limits(.light).qualityOfService == Self.limits(.balanced).qualityOfService)
        #expect(Self.limits(.light).priorityDescription == "lowest priority")
        #expect(Self.limits(.balanced).priorityDescription == "low priority")
        #expect(Self.limits(.maximum).priorityDescription == "full priority")
    }

    // MARK: - Control file

    @Test func controlFileJSONMatchesWhatTheSidecarsRead() throws {
        let light = Self.limits(.light).liveState
        let data = try ModelResourceControl.encode(light)
        #expect(try ModelResourceControl.decode(data) == light)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(object.keys) == ["version", "preset", "cpu_threads", "default_cpu_threads",
                                     "memory_fraction", "memory_limit_gb", "background", "environment"])
        #expect(object["version"] as? Int == 1)
        #expect(object["cpu_threads"] as? Int == 2)
        #expect(object["memory_fraction"] as? Double == 0.625)
        // Workbench model runs start with exactly the variables the app's own
        // model processes get (`_workbench_resource_limits.environment`).
        #expect(object["environment"] as? [String: String] == Self.limits(.light).environmentAdditions)

        // Nil values are left out; `_cellpose_common.read_live_limits` reads them as None.
        // Maximum's launch environment is empty: Workbench runs start unchanged.
        let maximum = try #require(try JSONSerialization.jsonObject(
            with: ModelResourceControl.encode(Self.limits(.maximum).liveState)) as? [String: Any])
        #expect(Set(maximum.keys) == ["version", "preset", "default_cpu_threads", "background", "environment"])
        #expect((maximum["environment"] as? [String: String])?.isEmpty == true)

        // A file written by hand in the documented shape decodes.
        let handWritten = Data(#"{"version":1,"preset":"custom","cpu_threads":3,"default_cpu_threads":8,"background":false}"#.utf8)
        let decoded = try ModelResourceControl.decode(handWritten)
        #expect(decoded.cpuThreads == 3)
        #expect(decoded.memoryFraction == nil)
    }

    @Test func publishWritesAFileThatReadsBack() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cc-limits-test-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let state = Self.limits(.custom, cores: 3, memoryGB: 7).liveState
        #expect(ModelResourceControl.publish(state, to: url))
        #expect(try ModelResourceControl.decode(Data(contentsOf: url)) == state)
        // Rewriting replaces it whole.
        let next = Self.limits(.light).liveState
        #expect(ModelResourceControl.publish(next, to: url))
        #expect(try ModelResourceControl.decode(Data(contentsOf: url)) == next)
    }

    @Test func everyModelProcessGetsTheFilePathUnlessAlreadySet() {
        let url = URL(fileURLWithPath: "/tmp/limits.json")
        let base = ["PATH": "/usr/bin"]
        let merged = ModelResourceControl.environment(merging: base, fileURL: url)
        #expect(merged == ["PATH": "/usr/bin", "CC_LIMITS_FILE": "/tmp/limits.json"])
        let overridden = ModelResourceControl.environment(merging: ["CC_LIMITS_FILE": "/elsewhere.json"], fileURL: url)
        #expect(overridden == ["CC_LIMITS_FILE": "/elsewhere.json"])
        // Fixed per user: `_workbench_resource_limits.DEFAULT_FILE_NAME` in the same folder.
        #expect(ModelResourceControl.fileURL.lastPathComponent == "cellcounter-model-limits.json")
        #expect(ModelResourceControl.fileURL.deletingLastPathComponent().standardizedFileURL
            == FileManager.default.temporaryDirectory.standardizedFileURL)
    }

    @Test func signalAndPriorityConstantsMatchTheSDK() {
        // sys/signal.h: SIGINFO 29, default action "discard"; sys/resource.h.
        #expect(ModelResourceControl.signalNumber == SIGINFO)
        #expect(SIGINFO == 29)
        #expect(ModelResourceControl.prioDarwinProcess == 4)
        #expect(ModelResourceControl.prioDarwinBackground == 0x1000)
        // Never touches a process for an invalid pid.
        #expect(!ModelResourceControl.setBackground(true, pid: 0))
        #expect(!ModelResourceControl.setBackground(false, pid: -1))
        ModelResourceControl.notify(pid: 0)
    }

    // MARK: - What applies now, after the image, or at the next start

    @Test func lightToMaximumAppliesNow() {
        let change = ModelResourceChange(from: Self.limits(.light), to: Self.limits(.maximum))
        #expect(change.priority && change.threads && change.memoryCapNow)
        #expect(!change.memoryCapAfterImage)
        #expect(change.nextStart)               // launch priority class and BLAS threads
        #expect(change.pool)
        #expect(change.appliesNow)
        #expect(change.confirmation(for: Self.limits(.maximum))
            == "Resource use: Maximum. The running model now uses normal priority, all CPU cores, no GPU memory cap.")
    }

    @Test func aLowerCapWaitsForTheCurrentImage() {
        let change = ModelResourceChange(from: Self.limits(.balanced), to: Self.limits(.light))
        #expect(change.priority && change.threads)
        #expect(!change.memoryCapNow)
        #expect(change.memoryCapAfterImage)
        #expect(change.confirmation(for: Self.limits(.light))
            == "Resource use: Light. The running model now uses lowest priority, up to 2 CPU cores. The 5 GB memory cap starts after the current image. Analysis can be much slower while Light is on.")

        // Balanced to Custom at the same cores sets a hard cap: after the image only.
        let toCustom = ModelResourceChange(from: Self.limits(.balanced), to: Self.limits(.custom, cores: 4, memoryGB: 8))
        #expect(!toCustom.priority && !toCustom.threads && !toCustom.memoryCapNow)
        #expect(toCustom.memoryCapAfterImage)
        #expect(!toCustom.appliesNow)
    }

    @Test func aHigherCapAppliesNow() {
        let change = ModelResourceChange(from: Self.limits(.custom, cores: 4, memoryGB: 8),
                                         to: Self.limits(.custom, cores: 4, memoryGB: 9))
        #expect(change.memoryCapNow && !change.memoryCapAfterImage)
        #expect(!change.priority && !change.threads)
        #expect(change.confirmation(for: Self.limits(.custom, cores: 4, memoryGB: 9))
            == "Resource use: Custom. The running model now uses GPU memory up to 9 GB.")
    }

    @Test func balancedAndMaximumShareTheCapSoOnlyThreadsChange() {
        let change = ModelResourceChange(from: Self.limits(.balanced), to: Self.limits(.maximum))
        #expect(change.threads)
        #expect(!change.priority && !change.memoryCapNow && !change.memoryCapAfterImage)
    }

    @Test func aChangeNothingRunningCanTakeWaitsForTheNextModel() {
        // Without Metal there is no GPU cap; Custom 6 → 9 GB changes only how
        // many models stay loaded.
        let old = Self.limits(.custom, cores: 4, memoryGB: 6, on: Self.noMetal)
        let new = Self.limits(.custom, cores: 4, memoryGB: 9, on: Self.noMetal)
        let change = ModelResourceChange(from: old, to: new)
        #expect(change.pool && !change.appliesNow && !change.memoryCapAfterImage && !change.nextStart)
        #expect(!change.isEmpty)
        #expect(change.confirmation(for: new) == "Resource use: Custom. Applies when the next model starts.")

        #expect(ModelResourceChange(from: new, to: new).isEmpty)
    }
}
