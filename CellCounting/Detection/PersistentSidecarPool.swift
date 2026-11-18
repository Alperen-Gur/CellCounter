import Foundation

/// Construction identity for a warm Python detector. A worker owns exactly
/// one expensive model signature; dynamic per-image arguments travel over the
/// request protocol and do not affect reuse.
nonisolated struct PersistentSidecarKey: Hashable, Sendable {
    let pythonPath: String
    let scriptPath: String
    let modelSignature: String
}

nonisolated enum PersistentSidecarError: LocalizedError {
    case launchFailed(String)
    case protocolFailure(String)
    case processTerminated(status: Int32, stderr: Data)

    var errorDescription: String? {
        switch self {
        case .launchFailed(let detail), .protocolFailure(let detail): return detail
        case .processTerminated(let status, let stderr):
            let detail = String(data: stderr, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return detail.isEmpty ? "Python worker exited with status \(status)." : String(detail.suffix(400))
        }
    }
}

/// A warm worker as the pool sees it. The production worker is a long-lived
/// Python process; tests substitute in-memory fakes.
nonisolated protocol PersistentSidecarWorkerHandle: Sendable {
    /// False once the worker was asked to stop or its process has exited.
    var isHealthy: Bool { get }

    func request(
        args: [String],
        onStderrLine: (@Sendable (String) -> Void)?
    ) async throws -> SidecarOutcome

    /// Stops the worker immediately, failing any queued or running request.
    /// Idempotent.
    func terminate()

    /// Stops a worker that has nothing in flight by letting it leave its
    /// request loop, with `terminate()` as the fallback. Idempotent.
    func shutdown()
}

/// Time source for idle retirement, injectable so tests control time.
/// Instants are offsets from the moment the clock was wrapped.
nonisolated struct SidecarIdleClock: Sendable {
    let now: @Sendable () -> Duration
    let sleepUntil: @Sendable (Duration) async throws -> Void

    init<C: Clock>(_ clock: C) where C.Duration == Duration {
        let origin = clock.now
        now = { origin.duration(to: clock.now) }
        sleepUntil = { deadline in
            try await clock.sleep(until: origin.advanced(by: deadline), tolerance: nil)
        }
    }

    /// Keeps counting while the Mac sleeps, so a worker left idle overnight
    /// is retired promptly after wake.
    static let continuous = SidecarIdleClock(ContinuousClock())
}

/// Long-lived sidecar pool. Each worker serializes its own request queue so a
/// Cellpose model is never evaluated concurrently inside one Python process.
///
/// Memory policy:
/// - A worker with no request in flight exits after `idleTimeout`.
/// - At most `maxWarmWorkers` workers are kept. Admitting a new model
///   signature first shuts down the least recently used idle worker.
/// - A worker with a request in flight is never evicted. When every worker
///   is busy, a new one is admitted anyway and the pool shrinks back to the
///   limit as requests finish.
/// - Both limits can change while the pool runs (`configure`).
actor PersistentSidecarPool {
    /// Two lets an ensemble keep both member models loaded between images.
    nonisolated static let defaultMaxWarmWorkers = 2
    /// Unused time after which a worker exits and returns its model memory.
    nonisolated static let defaultIdleTimeout: Duration = .seconds(180)

    /// Starts with the limits stored in Settings → General → Model resource
    /// use; `AppState` calls `configure` when they change.
    static let shared: PersistentSidecarPool = {
        let limits = ModelResourceLimits.current
        return PersistentSidecarPool(maxWarmWorkers: limits.maxWarmWorkers, idleTimeout: limits.idleTimeout)
    }()

    typealias Launcher = @Sendable (
        _ key: PersistentSidecarKey,
        _ pythonURL: URL,
        _ scriptURL: URL,
        _ trackerKind: ChildProcessTracker.Kind
    ) throws -> any PersistentSidecarWorkerHandle

    nonisolated private final class Entry {
        let key: PersistentSidecarKey
        let worker: any PersistentSidecarWorkerHandle
        /// Requests checked out against this worker, queued or executing.
        var inFlight = 0
        /// Pool-wide use sequence; orders LRU eviction and identifies the
        /// idle period an idle-retirement task was scheduled for.
        var lastUse: UInt64
        var idleRetirement: Task<Void, Never>?
        var retireWhenIdle = false

        init(key: PersistentSidecarKey, worker: any PersistentSidecarWorkerHandle, lastUse: UInt64) {
            self.key = key
            self.worker = worker
            self.lastUse = lastUse
        }
    }

    private var maxWarmWorkers: Int
    private var idleTimeout: Duration?
    private let clock: SidecarIdleClock
    private let launcher: Launcher
    private var entries: [PersistentSidecarKey: Entry] = [:]
    private var useSequence: UInt64 = 0

    /// - Parameters:
    ///   - maxWarmWorkers: workers kept at once (at least one).
    ///   - idleTimeout: unused time before a worker exits; `nil` disables
    ///     idle retirement.
    init(
        maxWarmWorkers: Int = PersistentSidecarPool.defaultMaxWarmWorkers,
        idleTimeout: Duration? = PersistentSidecarPool.defaultIdleTimeout,
        clock: SidecarIdleClock = .continuous,
        launcher: @escaping Launcher = PersistentSidecarPool.launchProcessWorker
    ) {
        self.maxWarmWorkers = max(1, maxWarmWorkers)
        self.idleTimeout = idleTimeout.map { max(.zero, $0) }
        self.clock = clock
        self.launcher = launcher
    }

    /// Starts the Python process with the resource limits stored now. Later
    /// changes reach it live (priority, PyTorch threads, GPU memory cap; see
    /// `ModelResourceControl`); launch-only parts stay until it is replaced.
    nonisolated static func launchProcessWorker(
        key: PersistentSidecarKey,
        pythonURL: URL,
        scriptURL: URL,
        trackerKind: ChildProcessTracker.Kind
    ) throws -> any PersistentSidecarWorkerHandle {
        try PersistentSidecarWorker(pythonURL: pythonURL, scriptURL: scriptURL, trackerKind: trackerKind,
                                    resourceLimits: .current)
    }

    /// Changes the limits for later admissions and idle periods.
    ///
    /// A lower `maxWarmWorkers` shuts down least recently used idle workers
    /// above it now; busy workers finish their requests and the pool shrinks
    /// as they end. A new `idleTimeout` restarts the timer of every idle
    /// worker with the new duration, counted from now.
    func configure(maxWarmWorkers: Int, idleTimeout: Duration?) {
        self.maxWarmWorkers = max(1, maxWarmWorkers)
        let timeout = idleTimeout.map { max(.zero, $0) }
        let timeoutChanged = timeout != self.idleTimeout
        self.idleTimeout = timeout
        trim(to: self.maxWarmWorkers)
        guard timeoutChanged else { return }
        for entry in Array(entries.values) where entry.inFlight == 0 {
            scheduleIdleRetirement(entry)
        }
    }

    /// Live workers, busy or idle.
    var workerCount: Int { entries.count }

    func hasWorker(for key: PersistentSidecarKey) -> Bool { entries[key] != nil }

    func run(
        key: PersistentSidecarKey,
        pythonURL: URL,
        scriptURL: URL,
        args: [String],
        trackerKind: ChildProcessTracker.Kind = .detection,
        onStderrLine: (@Sendable (String) -> Void)? = nil
    ) async throws -> SidecarOutcome {
        let entry = try checkOut(key: key, pythonURL: pythonURL,
                                 scriptURL: scriptURL, trackerKind: trackerKind)
        let worker = entry.worker
        do {
            let result = try await withTaskCancellationHandler {
                try await worker.request(args: args, onStderrLine: onStderrLine)
            } onCancel: {
                // A cancelled checked-out request may currently be executing or
                // queued. Retiring the whole serialized worker is the only safe
                // way to stop Cellpose without leaving an eval running against
                // a model that the host believes is idle.
                worker.terminate()
            }
            checkIn(entry, failed: false)
            return result
        } catch {
            checkIn(entry, failed: true)
            throw error
        }
    }

    /// Stops every worker immediately, including ones with a request in
    /// flight. For runtime changes and shutdown.
    func retireAll() {
        for entry in Array(entries.values) { discard(entry, graceful: false) }
    }

    /// Packages are shared within a runtime, but Cellpose 3 and 4 are
    /// isolated. Retire only workers whose imported runtime changed.
    func retire(modelSignaturePrefix: String) {
        for entry in entries.values.filter({ $0.key.modelSignature.hasPrefix(modelSignaturePrefix) }) {
            discard(entry, graceful: false)
        }
    }

    /// Stops every worker with no request in flight. Busy workers continue.
    func retireIdleWorkers() {
        for entry in Array(entries.values) where entry.inFlight == 0 { discard(entry, graceful: true) }
    }

    /// Stops idle workers now and each busy worker as soon as its last
    /// in-flight request finishes, without interrupting any request. Used
    /// before training so its process does not compete with warm models.
    func retireAllWhenIdle() {
        for entry in Array(entries.values) {
            if entry.inFlight == 0 { discard(entry, graceful: true) } else { entry.retireWhenIdle = true }
        }
    }

    // MARK: - Lifecycle

    private func nextUse() -> UInt64 {
        useSequence &+= 1
        return useSequence
    }

    private func checkOut(
        key: PersistentSidecarKey,
        pythonURL: URL,
        scriptURL: URL,
        trackerKind: ChildProcessTracker.Kind
    ) throws -> Entry {
        if let existing = entries[key] {
            if existing.worker.isHealthy {
                begin(existing)
                return existing
            }
            discard(existing, graceful: false)
        }
        makeRoomForNewWorker()
        let worker = try launcher(key, pythonURL, scriptURL, trackerKind)
        let entry = Entry(key: key, worker: worker, lastUse: nextUse())
        entries[key] = entry
        begin(entry)
        return entry
    }

    private func begin(_ entry: Entry) {
        entry.inFlight += 1
        entry.lastUse = nextUse()
        entry.idleRetirement?.cancel()
        entry.idleRetirement = nil
    }

    private func checkIn(_ entry: Entry, failed: Bool) {
        entry.inFlight -= 1
        entry.lastUse = nextUse()
        // A retired or replaced worker was already stopped by `discard`.
        guard entries[entry.key] === entry else { return }
        if failed || !entry.worker.isHealthy {
            discard(entry, graceful: false)
            return
        }
        guard entry.inFlight == 0 else { return }
        if entry.retireWhenIdle {
            discard(entry, graceful: true)
            return
        }
        trim(to: maxWarmWorkers)
        if entries[entry.key] === entry { scheduleIdleRetirement(entry) }
    }

    /// Drops dead idle workers, then shuts down least recently used idle
    /// workers until one more fits under the limit.
    private func makeRoomForNewWorker() {
        for entry in Array(entries.values) where entry.inFlight == 0 && !entry.worker.isHealthy {
            discard(entry, graceful: false)
        }
        trim(to: maxWarmWorkers - 1)
    }

    private func trim(to limit: Int) {
        while entries.count > limit,
              let victim = entries.values
                .filter({ $0.inFlight == 0 })
                .min(by: { $0.lastUse < $1.lastUse }) {
            discard(victim, graceful: true)
        }
    }

    /// Removes the worker and stops it. Only an idle worker is stopped
    /// gracefully; one with a request in flight is always terminated.
    private func discard(_ entry: Entry, graceful: Bool) {
        if entries[entry.key] === entry { entries[entry.key] = nil }
        entry.idleRetirement?.cancel()
        entry.idleRetirement = nil
        if graceful && entry.inFlight == 0 {
            entry.worker.shutdown()
        } else {
            entry.worker.terminate()
        }
    }

    private func scheduleIdleRetirement(_ entry: Entry) {
        entry.idleRetirement?.cancel()
        entry.idleRetirement = nil
        guard let idleTimeout else { return }
        let key = entry.key
        let use = entry.lastUse
        let clock = clock
        // The deadline is fixed now, not when the task first runs.
        let deadline = clock.now() + idleTimeout
        entry.idleRetirement = Task { [weak self] in
            do { try await clock.sleepUntil(deadline) } catch { return }
            await self?.retireIfStillIdle(key: key, lastUse: use)
        }
    }

    private func retireIfStillIdle(key: PersistentSidecarKey, lastUse: UInt64) {
        guard let entry = entries[key], entry.inFlight == 0, entry.lastUse == lastUse else { return }
        discard(entry, graceful: true)
    }
}

/// Cellpose-facing wrapper which preserves the proven one-shot runner as a
/// fallback. Protocol/launch/crash failures retire the worker and retry once;
/// cancellation signals never retry work the user explicitly stopped.
nonisolated enum ReusableSidecarRunner {
    private static let cancellationStatuses: Set<Int32> = [15, -15, 143, 9, -9, 137]

    static func run(
        key: PersistentSidecarKey,
        pythonURL: URL,
        scriptURL: URL,
        requestArgs: [String],
        onStderrLine: (@Sendable (String) -> Void)? = nil
    ) async throws -> SidecarOutcome {
        do {
            return try await PersistentSidecarPool.shared.run(
                key: key,
                pythonURL: pythonURL,
                scriptURL: scriptURL,
                args: requestArgs,
                onStderrLine: onStderrLine)
        } catch let error as PersistentSidecarError {
            if case .processTerminated(let status, let stderr) = error,
               cancellationStatuses.contains(status) {
                return SidecarOutcome(exitCode: status, stdout: Data(), stderr: stderr)
            }
            guard !Task.isCancelled else { throw DetectionError.cancelled }
            NSLog("[PersistentSidecarPool] warm worker unavailable; using one-shot fallback: \(error)")
            return try await SidecarProcessRunner.run(
                pythonURL: pythonURL,
                args: [scriptURL.path] + requestArgs,
                onStderrLine: onStderrLine)
        } catch is CancellationError {
            throw DetectionError.cancelled
        } catch {
            guard !Task.isCancelled else { throw DetectionError.cancelled }
            NSLog("[PersistentSidecarPool] worker failed; using one-shot fallback: \(error)")
            return try await SidecarProcessRunner.run(
                pythonURL: pythonURL,
                args: [scriptURL.path] + requestArgs,
                onStderrLine: onStderrLine)
        }
    }
}

nonisolated private final class PersistentSidecarWorker: PersistentSidecarWorkerHandle, @unchecked Sendable {
    /// How long a gracefully stopped worker may take to exit before SIGTERM.
    private static let shutdownGrace: TimeInterval = 10
    /// How long a terminated worker may take to exit before SIGKILL. The
    /// Cellpose sidecars unwind on SIGTERM so a partial weight download stays
    /// resumable; this bounds a worker that is stuck in native code.
    private static let terminationGrace: TimeInterval = 3

    private struct RequestEnvelope: Encodable {
        let request_id: String
        let args: [String]
    }

    private struct ResponseEnvelope: Decodable {
        let request_id: String?
        let exit_code: Int32
        let stdout: String
    }

    private struct QueuedRequest {
        let id: String
        let args: [String]
        let onStderrLine: (@Sendable (String) -> Void)?
        let continuation: CheckedContinuation<SidecarOutcome, Error>
    }

    private let lock = NSLock()
    private let process: Process
    private let stdinHandle: FileHandle
    private let stdoutPipe: Pipe
    private let stderrPipe: Pipe
    private let stdoutLines = PersistentLineBuffer(maxBytes: SidecarProcessRunner.maxStdoutBytes)
    private let stderrLines = PersistentLineBuffer(maxBytes: 8 * 1024 * 1024)
    private var queue: [QueuedRequest] = []
    private var current: QueuedRequest?
    private var currentStderr = Data()
    private var healthy = true

    var isHealthy: Bool {
        lock.lock(); defer { lock.unlock() }
        return healthy && process.isRunning
    }

    init(pythonURL: URL, scriptURL: URL, trackerKind: ChildProcessTracker.Kind,
         resourceLimits: ModelResourceLimits) throws {
        process = Process()
        stdoutPipe = Pipe()
        stderrPipe = Pipe()
        let stdinPipe = Pipe()
        stdinHandle = stdinPipe.fileHandleForWriting
        process.executableURL = pythonURL
        process.arguments = [scriptURL.path, "--serve"]
        // Thread counts, GPU memory cap and priority (Settings → General →
        // Model resource use), added to the inherited environment.
        resourceLimits.apply(to: process)
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        // An empty read means end of file. Removing the handler there stops
        // it from firing repeatedly if the worker object is already gone
        // when its process exits.
        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { handle.readabilityHandler = nil; return }
            self?.consumeStdout(chunk)
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { handle.readabilityHandler = nil; return }
            self?.consumeStderr(chunk)
        }
        process.terminationHandler = { [weak self] process in
            self?.processDidTerminate(status: process.terminationStatus)
        }

        do {
            try process.run()
            Task { @MainActor in
                if process.isRunning {
                    ChildProcessTracker.shared.register(process, kind: trackerKind)
                }
            }
        } catch {
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            throw PersistentSidecarError.launchFailed(error.localizedDescription)
        }
    }

    func request(
        args: [String],
        onStderrLine: (@Sendable (String) -> Void)?
    ) async throws -> SidecarOutcome {
        try await withCheckedThrowingContinuation { continuation in
            let request = QueuedRequest(
                id: UUID().uuidString,
                args: args,
                onStderrLine: onStderrLine,
                continuation: continuation)
            lock.lock()
            guard healthy, process.isRunning else {
                let status: Int32 = process.isRunning ? 15 : process.terminationStatus
                lock.unlock()
                continuation.resume(throwing: PersistentSidecarError.processTerminated(
                    status: status,
                    stderr: Data()))
                return
            }
            queue.append(request)
            let payload = startNextLocked()
            lock.unlock()
            write(payload)
        }
    }

    func terminate() {
        lock.lock()
        let shouldTerminate = healthy && process.isRunning
        healthy = false
        lock.unlock()
        if shouldTerminate { sendTerminate() }
    }

    /// SIGTERM, then SIGKILL if the process is still running after the grace.
    private func sendTerminate() {
        process.terminate()
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + Self.terminationGrace) { [self] in
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
    }

    /// Closing stdin ends the Python request loop, so the interpreter exits
    /// through its normal path. A worker that unexpectedly still has work,
    /// or that has not exited after the grace period, is terminated.
    func shutdown() {
        lock.lock()
        let running = healthy && process.isRunning
        let hasWork = current != nil || !queue.isEmpty
        healthy = false
        lock.unlock()
        guard running else { return }
        guard !hasWork else {
            sendTerminate()
            return
        }
        do {
            try stdinHandle.close()
        } catch {
            sendTerminate()
            return
        }
        // Holds the worker until the grace period ends so its pipe handlers
        // can still collect the process's final output.
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + Self.shutdownGrace) { [self] in
            if process.isRunning { sendTerminate() }
        }
    }

    /// Called with `lock` held. Moves one queued request into the active slot
    /// and returns its encoded line for writing after the lock is released.
    private func startNextLocked() -> Data? {
        guard healthy, process.isRunning, current == nil, !queue.isEmpty else { return nil }
        current = queue.removeFirst()
        currentStderr = Data()
        guard let current,
              var data = try? JSONEncoder().encode(
                RequestEnvelope(request_id: current.id, args: current.args)) else {
            return nil
        }
        data.append(UInt8(ascii: "\n"))
        return data
    }

    private func write(_ data: Data?) {
        guard let data else { return }
        do {
            try stdinHandle.write(contentsOf: data)
        } catch {
            terminate()
        }
    }

    private func consumeStdout(_ chunk: Data) {
        let result = stdoutLines.appendAndTakeLines(chunk)
        if result.overflowed {
            failActive(PersistentSidecarError.protocolFailure("worker response exceeded the payload limit"))
            terminate()
            return
        }
        for line in result.lines { consumeResponseLine(line) }
    }

    private func consumeResponseLine(_ line: Data) {
        let response: ResponseEnvelope
        do {
            response = try JSONDecoder().decode(ResponseEnvelope.self, from: line)
        } catch {
            failActive(PersistentSidecarError.protocolFailure(
                "invalid worker response: \(error.localizedDescription)"))
            terminate()
            return
        }

        lock.lock()
        guard let request = current, response.request_id == request.id else {
            lock.unlock()
            failActive(PersistentSidecarError.protocolFailure("worker response id mismatch"))
            terminate()
            return
        }
        let stderr = currentStderr
        current = nil
        currentStderr = Data()
        let next = startNextLocked()
        lock.unlock()

        request.continuation.resume(returning: SidecarOutcome(
            exitCode: response.exit_code,
            stdout: Data(response.stdout.utf8),
            stderr: stderr))
        write(next)
    }

    private func consumeStderr(_ chunk: Data) {
        lock.lock()
        if currentStderr.count < 8 * 1024 * 1024 {
            let remaining = 8 * 1024 * 1024 - currentStderr.count
            currentStderr.append(chunk.prefix(remaining))
        }
        let callback = current?.onStderrLine
        lock.unlock()
        guard let callback else { return }
        let result = stderrLines.appendAndTakeLines(chunk)
        for line in result.lines {
            guard let text = String(data: line, encoding: .utf8) else { continue }
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty { Task { @MainActor in callback(trimmed) } }
        }
    }

    private func failActive(_ error: Error) {
        lock.lock()
        let request = current
        current = nil
        lock.unlock()
        request?.continuation.resume(throwing: error)
    }

    private func processDidTerminate(status: Int32) {
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil
        if let tail = try? stdoutPipe.fileHandleForReading.readToEnd(), !tail.isEmpty {
            consumeStdout(tail)
        }
        if let tail = try? stderrPipe.fileHandleForReading.readToEnd(), !tail.isEmpty {
            consumeStderr(tail)
        }

        lock.lock()
        healthy = false
        let stderr = currentStderr
        let outstanding = ([current].compactMap { $0 }) + queue
        current = nil
        queue.removeAll()
        currentStderr = Data()
        lock.unlock()

        for request in outstanding {
            request.continuation.resume(throwing: PersistentSidecarError.processTerminated(
                status: status,
                stderr: stderr))
        }
    }
}

/// Newline framing for worker pipes. Each byte is scanned once: the search
/// resumes where the previous chunk's search stopped, complete lines are
/// sliced out by offset, and the consumed prefix is dropped once per chunk
/// rather than once per line. A response that arrives in many chunks
/// therefore costs time proportional to its size, and the pending buffer
/// only ever holds the unfinished line.
nonisolated final class PersistentLineBuffer: @unchecked Sendable {
    struct Result {
        let lines: [Data]
        let overflowed: Bool
    }

    private let lock = NSLock()
    private let maxBytes: Int
    /// The unfinished line. It never contains a newline between calls.
    private var pending: [UInt8] = []
    private var didOverflow = false

    init(maxBytes: Int) { self.maxBytes = maxBytes }

    /// Bytes held for a line whose newline has not arrived yet.
    var pendingByteCount: Int {
        lock.lock(); defer { lock.unlock() }
        return pending.count
    }

    func appendAndTakeLines(_ chunk: Data) -> Result {
        lock.lock(); defer { lock.unlock() }
        guard !didOverflow else { return Result(lines: [], overflowed: true) }
        if pending.count + chunk.count > maxBytes {
            didOverflow = true
            pending = []
            return Result(lines: [], overflowed: true)
        }
        guard !chunk.isEmpty else { return Result(lines: [], overflowed: false) }

        // Everything already pending was scanned by an earlier call.
        let scanFrom = pending.count
        chunk.withUnsafeBytes { raw in pending.append(contentsOf: raw) }

        var lines: [Data] = []
        var lineStart = 0
        pending.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            var searchFrom = scanFrom
            while searchFrom < bytes.count,
                  let hit = memchr(base + searchFrom, Int32(UInt8(ascii: "\n")), bytes.count - searchFrom) {
                let newline = base.distance(to: UnsafeRawPointer(hit))
                lines.append(Data(bytes: base + lineStart, count: newline - lineStart))
                lineStart = newline + 1
                searchFrom = lineStart
            }
        }
        if lineStart > 0 {
            // Copy only the unfinished tail. A fresh array also releases the
            // capacity a large response grew the buffer to.
            pending = Array(pending[lineStart...])
        }
        return Result(lines: lines, overflowed: false)
    }
}
