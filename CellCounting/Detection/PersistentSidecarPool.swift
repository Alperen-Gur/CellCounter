import Foundation

/// Construction identity for a warm Python detector. A worker owns exactly
/// one expensive model signature; dynamic per-image arguments travel over the
/// request protocol and do not affect reuse.
nonisolated struct PersistentSidecarKey: Hashable, Sendable {
    let pythonPath: String
    let scriptPath: String
    let modelSignature: String
}

nonisolated enum PersistentSidecarError: Error {
    case launchFailed(String)
    case protocolFailure(String)
    case processTerminated(status: Int32, stderr: Data)
}

/// Long-lived sidecar pool. Each worker serializes its own request queue so a
/// Cellpose model is never evaluated concurrently inside one Python process.
actor PersistentSidecarPool {
    static let shared = PersistentSidecarPool()

    private var workers: [PersistentSidecarKey: PersistentSidecarWorker] = [:]

    func run(
        key: PersistentSidecarKey,
        pythonURL: URL,
        scriptURL: URL,
        args: [String],
        onStderrLine: (@Sendable (String) -> Void)? = nil
    ) async throws -> SidecarOutcome {
        let worker: PersistentSidecarWorker
        if let existing = workers[key], existing.isHealthy {
            worker = existing
        } else {
            workers[key]?.terminate()
            do {
                worker = try PersistentSidecarWorker(
                    pythonURL: pythonURL,
                    scriptURL: scriptURL)
                workers[key] = worker
            } catch {
                workers[key] = nil
                throw error
            }
        }

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
            if !worker.isHealthy, workers[key] === worker {
                workers[key] = nil
            }
            return result
        } catch {
            if workers[key] === worker { workers[key] = nil }
            worker.terminate()
            throw error
        }
    }

    func retireAll() {
        for worker in workers.values { worker.terminate() }
        workers.removeAll()
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

nonisolated private final class PersistentSidecarWorker: @unchecked Sendable {
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

    init(pythonURL: URL, scriptURL: URL) throws {
        process = Process()
        stdoutPipe = Pipe()
        stderrPipe = Pipe()
        let stdinPipe = Pipe()
        stdinHandle = stdinPipe.fileHandleForWriting
        process.executableURL = pythonURL
        process.arguments = [scriptURL.path, "--serve"]
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            if !chunk.isEmpty { self?.consumeStdout(chunk) }
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            if !chunk.isEmpty { self?.consumeStderr(chunk) }
        }
        process.terminationHandler = { [weak self] process in
            self?.processDidTerminate(status: process.terminationStatus)
        }

        do {
            try process.run()
            Task { @MainActor in
                if process.isRunning {
                    ChildProcessTracker.shared.register(process, kind: .detection)
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
        if shouldTerminate { process.terminate() }
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

nonisolated private final class PersistentLineBuffer: @unchecked Sendable {
    struct Result {
        let lines: [Data]
        let overflowed: Bool
    }

    private let lock = NSLock()
    private let maxBytes: Int
    private var buffer = Data()
    private var didOverflow = false

    init(maxBytes: Int) { self.maxBytes = maxBytes }

    func appendAndTakeLines(_ chunk: Data) -> Result {
        lock.lock(); defer { lock.unlock() }
        guard !didOverflow else { return Result(lines: [], overflowed: true) }
        if buffer.count + chunk.count > maxBytes {
            didOverflow = true
            buffer = Data()
            return Result(lines: [], overflowed: true)
        }
        buffer.append(chunk)
        var lines: [Data] = []
        while let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
            lines.append(Data(buffer[..<newline]))
            buffer = Data(buffer[buffer.index(after: newline)...])
        }
        return Result(lines: lines, overflowed: false)
    }
}
