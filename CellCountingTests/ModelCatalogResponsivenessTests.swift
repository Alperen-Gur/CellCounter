import Foundation
import Testing
@testable import CellCounting

@MainActor
struct ModelCatalogResponsivenessTests {
    private func model(_ id: String, family: ModelFamily) -> DetectionModelInfo {
        DetectionModelInfo(id: id, family: family, name: id, sizeMB: 0,
                           sizeLabel: "", desc: "", state: .off,
                           speed: .fast, accuracy: .med, tags: [])
    }

    @Test func missingRuntimeSettlesOnceAndMainActorRemainsResponsive() async throws {
        let probe = CatalogProbeControl()
        let registry = DetectorRegistry()
        registry.register(CatalogTestDownloader(family: .cellpose, control: probe))
        let cache = InstallStateCache(observeEnvironmentChanges: false)
        let mutations = CatalogNotificationCounter()
        let observer = NotificationCenter.default.addObserver(forName: .ccVenvChanged,
            object: nil, queue: nil) { _ in mutations.increment() }
        defer { NotificationCenter.default.removeObserver(observer) }
        let models = (0..<25).map { model("cp-\($0)", family: .cellpose) }
        var callbackCount = 0
        cache.onStateChange = { _ in callbackCount += 1 }
        cache.refresh(modelId: models[0].id, registry: registry, models: models)
        cache.refresh(for: models, registry: registry)
        cache.refresh(modelId: models[0].id, registry: registry, models: models)
        try await waitFor { await probe.count == 1 }
        // This main-actor work runs while the cold probe is still suspended.
        #expect(cache.isRefreshing)
        #expect(cache.get(models[0].id) == .unknown)
        await probe.finish(0, result: false)
        try await waitFor { await MainActor.run { !cache.isRefreshing } }
        #expect(models.allSatisfy { cache.get($0.id) == .notInstalled })
        #expect(callbackCount == 1)
        #expect(mutations.count == 0)
        try await Task.sleep(for: .milliseconds(60))
        #expect(await probe.count == 1)
        #expect(!cache.isRefreshing)
    }

    @Test func refreshQueueIsBoundedAndLatePreInstallResultCannotOverwriteSuccess() async throws {
        let probe = CatalogProbeControl()
        let registry = DetectorRegistry()
        registry.register(CatalogTestDownloader(family: .custom, control: probe))
        let cache = InstallStateCache(observeEnvironmentChanges: false)
        let models = (0..<4).map { model("custom-\($0)", family: .custom) }
        cache.refresh(for: models, registry: registry)
        try await waitFor { await probe.count == 2 }
        #expect(await probe.maximumActive == 2)
        cache.markInstalling(models[0].id)
        cache.refresh(modelId: models[0].id, registry: registry, models: models, force: true)
        // Superseded work keeps its slots until it exits; no second process wave.
        #expect(await probe.count == 2)
        await probe.finish(0, result: false)
        await probe.finish(1, result: false)
        try await waitFor { await probe.count == 4 }
        #expect(cache.get(models[0].id) == .unknown)
        await probe.finish(2, result: true)
        await probe.finish(3, result: true)
        try await waitFor { await probe.count == 6 }
        await probe.finish(4, result: true)
        await probe.finish(5, result: true)
        try await waitFor { await MainActor.run { !cache.isRefreshing } }
        #expect(models.allSatisfy { cache.get($0.id) == .installed })
        #expect(await probe.maximumActive == 2)
    }

    @Test func moduleProbeCoalescesColdMissesAndInvalidationRejectsStalePublication() async throws {
        let control = BlockingImportProbe()
        let cache = PythonModuleImportCache(module: "fixture", probe: { _ in control.run() })
        let python = URL(fileURLWithPath: "/fixture/python")
        let first = Task.detached { cache.isImportable(pythonURL: python) }
        try await waitFor { control.count == 1 }
        let joined = Task.detached { cache.isImportable(pythonURL: python) }
        // Cached reads return immediately while import is blocked.
        #expect(cache.cachedAnswer(pythonURL: python) == nil)
        try await Task.sleep(for: .milliseconds(30))
        #expect(control.count == 1)
        cache.invalidate(pythonURL: python)
        let second = Task.detached { cache.isImportable(pythonURL: python) }
        try await waitFor { control.count == 2 }
        #expect(await second.value == false)
        control.releaseFirst.signal()
        #expect(await first.value)
        #expect(await joined.value)
        #expect(cache.cachedAnswer(pythonURL: python) == false)
        #expect(cache.isImportable(pythonURL: python) == false)
    }

    @Test func probeDiscardsNoisyOutputAndKillsAStubbornProcess() async throws {
        // Exercise the actual process runner with deterministic shell builtins.
        // /usr/bin/python3 is an Xcode launcher on macOS: cold interpreter
        // startup under a loaded CI runner can consume the whole five-second
        // budget before this test reaches either behavior it intends to test.
        let executable = URL(fileURLWithPath: "/bin/sh")
        #expect(FileManager.default.isExecutableFile(atPath: executable.path))
        let noisy = await Task.detached {
            ModelProbeRunner.run(pythonURL: executable,
                code: "printf '%02000000d' 0; printf '%02000000d' 0 >&2", timeout: 5)
        }.value
        #expect(noisy)
        let start = ContinuousClock.now
        let hung = await Task.detached {
            ModelProbeRunner.run(pythonURL: executable,
                // No child sleep process survives the parent being killed.
                code: "trap '' TERM; while :; do :; done",
                timeout: 0.15)
        }.value
        #expect(!hung)
        #expect(start.duration(to: .now) < .seconds(3))
    }

    private func waitFor(_ condition: @escaping @Sendable () async -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !(await condition()) {
            guard ContinuousClock.now < deadline else {
                throw CatalogProbeTestError.timedOut
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

private actor CatalogProbeControl {
    var count = 0
    var active = 0
    var maximumActive = 0
    private var waiters: [Int: CheckedContinuation<Bool, Never>] = [:]
    func run() async -> Bool {
        let index = count
        count += 1
        active += 1
        maximumActive = max(maximumActive, active)
        let value = await withCheckedContinuation { waiters[index] = $0 }
        active -= 1
        return value
    }
    func finish(_ index: Int, result: Bool) { waiters.removeValue(forKey: index)?.resume(returning: result) }
}

private nonisolated struct CatalogTestDownloader: ModelDownloader {
    let family: ModelFamily
    let control: CatalogProbeControl
    func isInstalled(modelId: String) -> Bool { false }
    func probeInstalled(modelId: String) async -> Bool { await control.run() }
    func install(modelId: String, progress: ModelInstallProgress) async throws {}
    @MainActor func uninstall(modelId: String) throws {}
    @MainActor func diskUsageBytes(modelId: String) -> Int64 { 0 }
    @MainActor func detector(for modelId: String) -> DetectionService? { nil }
}

private nonisolated final class BlockingImportProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    let releaseFirst = DispatchSemaphore(value: 0)
    var count: Int { lock.lock(); defer { lock.unlock() }; return calls }
    func run() -> Bool {
        lock.lock(); calls += 1; let number = calls; lock.unlock()
        if number == 1 { releaseFirst.wait(); return true }
        return false
    }
}

private enum CatalogProbeTestError: Error { case timedOut }

private nonisolated final class CatalogNotificationCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var count: Int { lock.lock(); defer { lock.unlock() }; return value }
    func increment() { lock.lock(); value += 1; lock.unlock() }
}
