import Foundation
import Testing
@testable import CellCounting

/// Warm-worker lifecycle and response framing, driven by a manual clock and
/// in-memory workers. No Python process is started.
struct SidecarPoolLifecycleTests {

    // MARK: - Idle retirement

    @Test func idleWorkerExitsAfterTimeoutAndEachUseRestartsTheTimer() async throws {
        let clock = ManualTestClock()
        let factory = FakeWorkerFactory()
        let pool = PersistentSidecarPool(maxWarmWorkers: 2, idleTimeout: .seconds(60),
                                         clock: SidecarIdleClock(clock), launcher: factory.launcher)
        let a = Self.key("a")

        _ = try await Self.run(pool, a)
        clock.advance(by: .seconds(59))
        await Self.settle()
        #expect(await pool.hasWorker(for: a))

        // Reuse just before the deadline moves it to a full period after this use.
        _ = try await Self.run(pool, a)
        clock.advance(by: .seconds(59))
        await Self.settle()
        #expect(await pool.hasWorker(for: a))
        #expect(factory.workers(for: a).count == 1)

        clock.advance(by: .seconds(1))
        #expect(await Self.eventually { await pool.workerCount == 0 })
        let worker = try #require(factory.latest(for: a))
        #expect(worker.requestCount == 2)
        #expect(worker.shutdownCount == 1)
        #expect(worker.terminateCount == 0)

        // The next request starts a fresh worker.
        _ = try await Self.run(pool, a)
        #expect(factory.workers(for: a).count == 2)
        #expect(await pool.hasWorker(for: a))
        await pool.retireAll()
    }

    @Test func idleTimeoutCanBeDisabled() async throws {
        let clock = ManualTestClock()
        let factory = FakeWorkerFactory()
        let pool = PersistentSidecarPool(idleTimeout: nil, clock: SidecarIdleClock(clock),
                                         launcher: factory.launcher)
        let a = Self.key("a")
        _ = try await Self.run(pool, a)
        clock.advance(by: .seconds(24 * 3600))
        await Self.settle()
        #expect(await pool.hasWorker(for: a))
        #expect(clock.sleeperCount == 0)
    }

    // MARK: - Limit and LRU eviction

    @Test func defaultLimitEvictsTheLeastRecentlyUsedIdleWorker() async throws {
        #expect(PersistentSidecarPool.defaultMaxWarmWorkers == 2)
        let factory = FakeWorkerFactory()
        let pool = PersistentSidecarPool(idleTimeout: nil, launcher: factory.launcher)
        let (a, b, c, d) = (Self.key("a"), Self.key("b"), Self.key("c"), Self.key("d"))

        _ = try await Self.run(pool, a)
        _ = try await Self.run(pool, b)
        _ = try await Self.run(pool, c)
        #expect(await pool.workerCount == 2)
        #expect(await pool.hasWorker(for: a) == false)
        #expect(factory.latest(for: a)?.shutdownCount == 1)
        #expect(factory.latest(for: a)?.terminateCount == 0)

        // Touching b makes c the least recently used.
        _ = try await Self.run(pool, b)
        _ = try await Self.run(pool, d)
        #expect(await pool.workerCount == 2)
        #expect(await pool.hasWorker(for: b))
        #expect(await pool.hasWorker(for: d))
        #expect(await pool.hasWorker(for: c) == false)
        #expect(factory.latest(for: c)?.shutdownCount == 1)
        #expect(factory.workers(for: b).count == 1)
        #expect(factory.latest(for: b)?.requestCount == 2)
        #expect(factory.latest(for: b)?.shutdownCount == 0)
    }

    @Test func deadWorkersMakeRoomBeforeHealthyOnes() async throws {
        let factory = FakeWorkerFactory()
        let pool = PersistentSidecarPool(maxWarmWorkers: 2, idleTimeout: nil, launcher: factory.launcher)
        let (a, b, c) = (Self.key("a"), Self.key("b"), Self.key("c"))
        _ = try await Self.run(pool, a)
        _ = try await Self.run(pool, b)

        // b's process exits on its own while idle; a remains the LRU.
        try #require(factory.latest(for: b)).simulateExit()
        _ = try await Self.run(pool, c)
        #expect(await pool.hasWorker(for: a))
        #expect(await pool.hasWorker(for: c))
        #expect(await pool.hasWorker(for: b) == false)
        #expect(factory.latest(for: a)?.shutdownCount == 0)

        // A dead worker for the requested key is replaced, not reused.
        try #require(factory.latest(for: a)).simulateExit()
        _ = try await Self.run(pool, a)
        #expect(factory.workers(for: a).count == 2)
        #expect(factory.latest(for: a)?.isHealthy == true)
    }

    @Test func failedRequestRetiresItsWorker() async throws {
        let factory = FakeWorkerFactory()
        let pool = PersistentSidecarPool(idleTimeout: nil, launcher: factory.launcher)
        let a = Self.key("a")
        await #expect(throws: PersistentSidecarError.self) {
            try await Self.run(pool, a, args: ["fail"])
        }
        #expect(await pool.hasWorker(for: a) == false)
        #expect(factory.latest(for: a)?.terminateCount == 1)
    }

    // MARK: - Busy workers

    @Test func busyWorkerIsNeverEvictedOrIdleRetired() async throws {
        let clock = ManualTestClock()
        let factory = FakeWorkerFactory()
        let pool = PersistentSidecarPool(maxWarmWorkers: 1, idleTimeout: .seconds(60),
                                         clock: SidecarIdleClock(clock), launcher: factory.launcher)
        let (a, b) = (Self.key("a"), Self.key("b"))

        let held = Task { try await Self.run(pool, a, args: ["hold"]) }
        #expect(await Self.eventually { factory.latest(for: a)?.heldCount == 1 })
        let busy = try #require(factory.latest(for: a))

        // At the limit with every worker busy, a new model is admitted rather
        // than interrupting a; once b is idle the pool trims back to the limit.
        let outcome = try await Self.run(pool, b)
        #expect(String(decoding: outcome.stdout, as: UTF8.self) == "image")
        #expect(await pool.workerCount == 1)
        #expect(await pool.hasWorker(for: a))
        #expect(factory.latest(for: b)?.shutdownCount == 1)

        // No idle timer runs for a busy worker, and idle-only retirement skips it.
        clock.advance(by: .seconds(600))
        await pool.retireIdleWorkers()
        await Self.settle()
        #expect(await pool.hasWorker(for: a))
        #expect(busy.isHealthy)
        #expect(busy.shutdownCount == 0)
        #expect(busy.terminateCount == 0)

        busy.finishHeldRequests()
        let finished = try await held.value
        #expect(finished.exitCode == 0)
        #expect(busy.terminateCount == 0)
        // Idle now, so the normal idle timer applies again.
        #expect(await pool.hasWorker(for: a))
        await pool.retireAll()
    }

    @Test func retireAllWhenIdleWaitsForInFlightRequests() async throws {
        let factory = FakeWorkerFactory()
        let pool = PersistentSidecarPool(maxWarmWorkers: 2, idleTimeout: nil, launcher: factory.launcher)
        let (idle, busyKey) = (Self.key("idle"), Self.key("busy"))
        _ = try await Self.run(pool, idle)
        let held = Task { try await Self.run(pool, busyKey, args: ["hold"]) }
        #expect(await Self.eventually { factory.latest(for: busyKey)?.heldCount == 1 })
        let busy = try #require(factory.latest(for: busyKey))

        await pool.retireAllWhenIdle()
        #expect(factory.latest(for: idle)?.shutdownCount == 1)
        #expect(await pool.hasWorker(for: idle) == false)
        #expect(busy.isHealthy)
        #expect(await pool.hasWorker(for: busyKey))

        busy.finishHeldRequests()
        #expect(try await held.value.exitCode == 0)
        #expect(await pool.workerCount == 0)
        #expect(busy.shutdownCount == 1)
        #expect(busy.terminateCount == 0)
    }

    // MARK: - Live limits (Settings → Model resource use)

    @Test func loweringTheWarmLimitStopsIdleWorkersButNeverABusyOne() async throws {
        let factory = FakeWorkerFactory()
        let pool = PersistentSidecarPool(maxWarmWorkers: 3, idleTimeout: nil, launcher: factory.launcher)
        let (a, b, busyKey) = (Self.key("a"), Self.key("b"), Self.key("busy"))
        _ = try await Self.run(pool, a)
        _ = try await Self.run(pool, b)
        let held = Task { try await Self.run(pool, busyKey, args: ["hold"]) }
        #expect(await Self.eventually { factory.latest(for: busyKey)?.heldCount == 1 })
        let busy = try #require(factory.latest(for: busyKey))
        #expect(await pool.workerCount == 3)

        // The busy worker counts against the new limit, so both idle ones go now.
        await pool.configure(maxWarmWorkers: 1, idleTimeout: nil)
        #expect(await pool.workerCount == 1)
        #expect(await pool.hasWorker(for: busyKey))
        #expect(factory.latest(for: a)?.shutdownCount == 1)
        #expect(factory.latest(for: b)?.shutdownCount == 1)
        #expect(busy.isHealthy)
        #expect(busy.shutdownCount == 0)
        #expect(busy.terminateCount == 0)

        busy.finishHeldRequests()
        #expect(try await held.value.exitCode == 0)
        #expect(busy.terminateCount == 0)
        #expect(await pool.hasWorker(for: busyKey))

        // Later admissions use the new limit: a new model replaces the idle one.
        _ = try await Self.run(pool, a)
        #expect(await pool.workerCount == 1)
        #expect(busy.shutdownCount == 1)
        #expect(factory.workers(for: a).count == 2)

        // Raising it again lets two stay.
        await pool.configure(maxWarmWorkers: 2, idleTimeout: nil)
        _ = try await Self.run(pool, b)
        #expect(await pool.workerCount == 2)
        await pool.retireAll()
    }

    @Test func aNewIdleTimeoutAppliesToIdleWorkersFromNow() async throws {
        let clock = ManualTestClock()
        let factory = FakeWorkerFactory()
        let pool = PersistentSidecarPool(maxWarmWorkers: 2, idleTimeout: .seconds(600),
                                         clock: SidecarIdleClock(clock), launcher: factory.launcher)
        let a = Self.key("a")
        _ = try await Self.run(pool, a)
        clock.advance(by: .seconds(30))
        await Self.settle()

        await pool.configure(maxWarmWorkers: 2, idleTimeout: .seconds(60))
        clock.advance(by: .seconds(59))
        await Self.settle()
        #expect(await pool.hasWorker(for: a))

        clock.advance(by: .seconds(1))
        #expect(await Self.eventually { await pool.workerCount == 0 })
        #expect(factory.latest(for: a)?.shutdownCount == 1)
        #expect(factory.latest(for: a)?.terminateCount == 0)

        // The next idle period uses the new timeout too.
        _ = try await Self.run(pool, a)
        clock.advance(by: .seconds(60))
        #expect(await Self.eventually { await pool.workerCount == 0 })
    }

    // MARK: - Newline framing

    @Test func lineSplitAcrossSeveralChunksIsReassembled() {
        let buffer = PersistentLineBuffer(maxBytes: 1 << 20)
        #expect(buffer.appendAndTakeLines(Data(#"{"request_id":"#.utf8)).lines.isEmpty)
        #expect(buffer.appendAndTakeLines(Data(#""r1","exit_"#.utf8)).lines.isEmpty)
        #expect(buffer.pendingByteCount == 25)
        let result = buffer.appendAndTakeLines(Data((#"code":0}"# + "\n").utf8))
        #expect(!result.overflowed)
        #expect(Self.strings(result.lines) == [#"{"request_id":"r1","exit_code":0}"#])
        #expect(buffer.pendingByteCount == 0)
    }

    @Test func severalLinesPerChunkAndNewlinesOnChunkBoundaries() {
        let buffer = PersistentLineBuffer(maxBytes: 1 << 20)
        let first = buffer.appendAndTakeLines(Data("one\ntwo\n\nthree".utf8))
        #expect(Self.strings(first.lines) == ["one", "two", ""])
        #expect(buffer.pendingByteCount == 5)

        // The newline that completes "three" is the first byte of this chunk.
        let second = buffer.appendAndTakeLines(Data("\nfour\nfi".utf8))
        #expect(Self.strings(second.lines) == ["three", "four"])
        #expect(buffer.appendAndTakeLines(Data()).lines.isEmpty)

        // This chunk ends exactly on a newline.
        let third = buffer.appendAndTakeLines(Data("ve\n".utf8))
        #expect(Self.strings(third.lines) == ["five"])
        #expect(buffer.pendingByteCount == 0)
    }

    @Test func oneByteChunksFrameLikeWholeChunks() {
        let buffer = PersistentLineBuffer(maxBytes: 1 << 20)
        var lines: [Data] = []
        for byte in Data("ab\n\ncd\nef".utf8) {
            lines += buffer.appendAndTakeLines(Data([byte])).lines
        }
        #expect(Self.strings(lines) == ["ab", "", "cd"])
        #expect(buffer.pendingByteCount == 2)
    }

    @Test func largeLineArrivingInManyChunksIsByteIdentical() {
        let payload = Data((0..<(1 << 20)).map { index -> UInt8 in
            let byte = UInt8(truncatingIfNeeded: index &* 31 &+ index >> 7)
            return byte == UInt8(ascii: "\n") ? UInt8(ascii: "x") : byte
        })
        let stream = payload + Data("\ntail\n".utf8)
        let buffer = PersistentLineBuffer(maxBytes: 4 << 20)
        var lines: [Data] = []
        var offset = 0
        let chunkSize = 4093
        var pendingMatched = true
        while offset < stream.count {
            let end = min(offset + chunkSize, stream.count)
            let result = buffer.appendAndTakeLines(stream.subdata(in: offset..<end))
            #expect(!result.overflowed)
            lines += result.lines
            offset = end
            if offset <= payload.count, buffer.pendingByteCount != offset { pendingMatched = false }
        }
        #expect(pendingMatched)
        #expect(lines.count == 2)
        #expect(lines.first == payload)
        #expect(lines.last == Data("tail".utf8))
        #expect(buffer.pendingByteCount == 0)
    }

    @Test func oversizedPendingLineOverflowsPermanently() {
        let buffer = PersistentLineBuffer(maxBytes: 8)
        #expect(!buffer.appendAndTakeLines(Data("1234".utf8)).overflowed)
        #expect(buffer.appendAndTakeLines(Data("56789".utf8)).overflowed)
        #expect(buffer.appendAndTakeLines(Data("\n".utf8)).overflowed)
        #expect(buffer.pendingByteCount == 0)
    }

    // MARK: - Helpers

    private static func key(_ signature: String) -> PersistentSidecarKey {
        PersistentSidecarKey(pythonPath: "/fake/python", scriptPath: "/fake/worker.py",
                             modelSignature: signature)
    }

    private static func run(
        _ pool: PersistentSidecarPool,
        _ key: PersistentSidecarKey,
        args: [String] = ["image"]
    ) async throws -> SidecarOutcome {
        try await pool.run(key: key,
                           pythonURL: URL(fileURLWithPath: key.pythonPath),
                           scriptURL: URL(fileURLWithPath: key.scriptPath),
                           args: args)
    }

    private static func strings(_ lines: [Data]) -> [String] {
        lines.map { String(decoding: $0, as: UTF8.self) }
    }

    /// Gives already-scheduled tasks a chance to run before a negative check.
    private static func settle() async {
        for _ in 0..<20 { await Task.yield() }
        try? await Task.sleep(for: .milliseconds(20))
    }

    private static func eventually(
        timeout: Duration = .seconds(5),
        _ condition: () async -> Bool
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(2))
        }
        return await condition()
    }
}

// MARK: - Test doubles

/// A clock that only moves when the test advances it.
private final class ManualTestClock: Clock, @unchecked Sendable {
    struct Instant: InstantProtocol {
        var offset: Swift.Duration

        func advanced(by duration: Swift.Duration) -> Instant { Instant(offset: offset + duration) }
        func duration(to other: Instant) -> Swift.Duration { other.offset - offset }
        static func < (lhs: Instant, rhs: Instant) -> Bool { lhs.offset < rhs.offset }
    }

    private struct Sleeper {
        let deadline: Instant
        let continuation: CheckedContinuation<Void, Error>
    }

    private let lock = NSLock()
    private var current = Instant(offset: .zero)
    private var sleepers: [UUID: Sleeper] = [:]

    var now: Instant { lock.withLock { current } }
    var minimumResolution: Swift.Duration { .zero }
    var sleeperCount: Int { lock.withLock { sleepers.count } }

    func sleep(until deadline: Instant, tolerance: Swift.Duration?) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                self.lock.lock()
                if Task.isCancelled {
                    self.lock.unlock()
                    continuation.resume(throwing: CancellationError())
                } else if deadline <= self.current {
                    self.lock.unlock()
                    continuation.resume()
                } else {
                    self.sleepers[id] = Sleeper(deadline: deadline, continuation: continuation)
                    self.lock.unlock()
                }
            }
        } onCancel: {
            let sleeper = self.lock.withLock { self.sleepers.removeValue(forKey: id) }
            sleeper?.continuation.resume(throwing: CancellationError())
        }
    }

    func advance(by duration: Swift.Duration) {
        let due: [Sleeper] = lock.withLock {
            current = current.advanced(by: duration)
            let ready = sleepers.filter { $0.value.deadline <= current }
            for id in ready.keys { sleepers.removeValue(forKey: id) }
            return Array(ready.values)
        }
        for sleeper in due { sleeper.continuation.resume() }
    }
}

/// In-memory stand-in for a Python worker. `["hold"]` requests stay in
/// flight until `finishHeldRequests()`; `["fail"]` requests throw.
private final class FakeSidecarWorker: PersistentSidecarWorkerHandle, @unchecked Sendable {
    private typealias HeldRequest = (args: [String], continuation: CheckedContinuation<SidecarOutcome, Error>)

    let key: PersistentSidecarKey
    private let lock = NSLock()
    private var healthy = true
    private var held: [HeldRequest] = []
    private var requests = 0
    private var shutdowns = 0
    private var terminations = 0

    init(key: PersistentSidecarKey) { self.key = key }

    var isHealthy: Bool { lock.withLock { healthy } }
    var requestCount: Int { lock.withLock { requests } }
    var shutdownCount: Int { lock.withLock { shutdowns } }
    var terminateCount: Int { lock.withLock { terminations } }
    var heldCount: Int { lock.withLock { held.count } }

    func request(
        args: [String],
        onStderrLine: (@Sendable (String) -> Void)?
    ) async throws -> SidecarOutcome {
        let alive = lock.withLock { () -> Bool in
            requests += 1
            return healthy
        }
        guard alive else { throw Self.stopped }
        if args.first == "fail" {
            throw PersistentSidecarError.protocolFailure("simulated worker failure")
        }
        guard args.first == "hold" else { return Self.outcome(for: args) }
        return try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if healthy {
                held.append((args, continuation))
                lock.unlock()
            } else {
                lock.unlock()
                continuation.resume(throwing: Self.stopped)
            }
        }
    }

    func finishHeldRequests() {
        let pending = lock.withLock { () -> [HeldRequest] in
            defer { held.removeAll() }
            return held
        }
        for request in pending { request.continuation.resume(returning: Self.outcome(for: request.args)) }
    }

    func terminate() { stop(graceful: false) }
    func shutdown() { stop(graceful: true) }

    /// The process exits on its own, without the pool asking.
    func simulateExit() { lock.withLock { healthy = false } }

    private func stop(graceful: Bool) {
        let pending = lock.withLock { () -> [HeldRequest] in
            if graceful { shutdowns += 1 } else { terminations += 1 }
            healthy = false
            defer { held.removeAll() }
            return held
        }
        for request in pending { request.continuation.resume(throwing: Self.stopped) }
    }

    private static var stopped: PersistentSidecarError {
        .processTerminated(status: 15, stderr: Data())
    }

    private static func outcome(for args: [String]) -> SidecarOutcome {
        SidecarOutcome(exitCode: 0, stdout: Data(args.joined(separator: " ").utf8), stderr: Data())
    }
}

private final class FakeWorkerFactory: @unchecked Sendable {
    private let lock = NSLock()
    private var launched: [FakeSidecarWorker] = []

    var launcher: PersistentSidecarPool.Launcher {
        { [self] key, _, _, _ in
            let worker = FakeSidecarWorker(key: key)
            lock.withLock { launched.append(worker) }
            return worker
        }
    }

    func workers(for key: PersistentSidecarKey) -> [FakeSidecarWorker] {
        lock.withLock { launched.filter { $0.key == key } }
    }

    func latest(for key: PersistentSidecarKey) -> FakeSidecarWorker? {
        workers(for: key).last
    }
}
