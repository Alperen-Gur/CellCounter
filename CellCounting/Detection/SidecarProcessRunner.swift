//  SidecarProcessRunner.swift
//  CellCounting
//
//  Single, correct implementation of "spawn a Python detection sidecar,
//  bridge its termination into structured concurrency, and drain both pipes
//  CONCURRENTLY." Every sidecar detection service (Cellpose, StarDist,
//  SAM) funnels through this so the pipe-buffer deadlock is fixed in exactly
//  one place.
//
//  Why concurrent draining matters: reading stdout/stderr only inside the
//  terminationHandler (via readToEnd()) deadlocks for any payload larger than
//  the OS pipe buffer (~16–64 KB on macOS). Once the Python child fills that
//  buffer it blocks on `sys.stdout.write(...)`, so the process never exits, so
//  terminationHandler never fires, so the detection hangs forever. A run with
//  many cells emits a large JSON payload plus verbose framework stderr and
//  will exceed the buffer. We therefore attach readabilityHandlers that append
//  chunks to a lock-guarded sink as they arrive, detach them in the
//  terminationHandler, and do a final readToEnd() drain for the tail.

import Foundation

/// Result of running a detection sidecar to completion.
struct SidecarOutcome {
    var exitCode: Int32
    var stdout: Data
    var stderr: Data

    /// SIGTERM (15) / SIGKILL (9) and their Process-API mirrored values
    /// (-15, -9, 143, 137) mean the host terminated the subprocess on purpose —
    /// Cancel button, app quit, or ChildProcessTracker.terminateAll().
    private static let signalCodes: Set<Int32> = [15, -15, 143, 9, -9, 137]

    /// Throw the correct `DetectionError` for a non-zero exit code, shared by
    /// every detection family so a user-initiated cancel maps to
    /// `.cancelled` (which callers swallow silently) instead of a false
    /// `.sidecarFailed` "detection failed" banner. Returns normally when the
    /// exit code is 0.
    func throwIfFailed() throws {
        guard exitCode != 0 else { return }
        if Self.signalCodes.contains(exitCode) {
            throw DetectionError.cancelled
        }
        let stderrText = String(data: stderr, encoding: .utf8) ?? ""
        throw DetectionError.sidecarFailed(exitCode: exitCode, stderr: stderrText)
    }
}

enum SidecarProcessRunner {

    /// Hard cap on buffered stdout. A well-formed detection payload for even a
    /// very busy image is a few MB; 256 MB is far above any legitimate result
    /// but well below the point where holding it (plus the pipe copy and the
    /// decoded model objects) threatens a modest lab laptop. Past this we fail
    /// with `.payloadTooLarge` rather than decode an unbounded payload.
    static let maxStdoutBytes = 256 * 1024 * 1024

    /// Spawn `pythonURL args…` off the main actor and return its full stdout,
    /// stderr, and exit code once it terminates.
    ///
    /// - Parameters:
    ///   - pythonURL: the interpreter to launch.
    ///   - args: script + arguments.
    ///   - trackerKind: how to register the child with `ChildProcessTracker`
    ///     so it is SIGTERM'd on app quit.
    ///   - onStderrLine: optional per-line stderr tap for live progress UI.
    ///     Invoked on the MainActor with each trimmed, non-empty line as it
    ///     streams in (used by Cellpose to drive the `.ccDetectionStage`
    ///     notification). Pass `nil` to skip line splitting entirely.
    static func run(
        pythonURL: URL,
        args: [String],
        trackerKind: ChildProcessTracker.Kind = .detection,
        onStderrLine: (@Sendable (String) -> Void)? = nil
    ) async throws -> SidecarOutcome {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<SidecarOutcome, Error>) in
            Task.detached(priority: .userInitiated) {
                let process = Process()
                process.executableURL = pythonURL
                process.arguments = args

                let stdoutPipe = Pipe()
                let stderrPipe = Pipe()
                process.standardOutput = stdoutPipe
                process.standardError = stderrPipe

                // stderr — accumulate the full buffer for error surfacing, and
                // optionally tap each line as it arrives for live progress.
                let stderrAccumulator = SidecarDataSink()
                // readabilityHandler fires on arbitrary byte boundaries, so a
                // multi-byte UTF-8 sequence (or a whole line) can straddle two
                // chunks. Buffer raw bytes and only emit COMPLETE
                // newline-terminated lines, carrying the trailing partial line
                // to the next chunk — otherwise split characters decode to nil
                // and the progress line is silently dropped.
                let stderrLineBuffer = SidecarLineBuffer()
                stderrPipe.fileHandleForReading.readabilityHandler = { handle in
                    let chunk = handle.availableData
                    if chunk.isEmpty { return } // EOF
                    stderrAccumulator.append(chunk)
                    guard let onStderrLine else { return }
                    for line in stderrLineBuffer.appendAndTakeLines(chunk) {
                        Task { @MainActor in onStderrLine(line) }
                    }
                }

                // stdout — drain CONCURRENTLY too, or a payload bigger than the
                // OS pipe buffer wedges the child (see file header). Bounded so
                // a pathologically dense image (100k+ objects, each with a
                // contour polygon) can't buffer hundreds of MB of JSON in the
                // host and OOM mid-batch — past the cap we stop accumulating and
                // surface `.payloadTooLarge` instead of decoding it.
                let stdoutAccumulator = SidecarDataSink(maxBytes: Self.maxStdoutBytes)
                stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
                    let chunk = handle.availableData
                    if chunk.isEmpty { return } // EOF
                    stdoutAccumulator.append(chunk)
                }

                let resumed = SidecarResumeFlag()

                process.terminationHandler = { proc in
                    // Detach BOTH handlers before the final drain so they can't
                    // race the readToEnd() calls below.
                    stderrPipe.fileHandleForReading.readabilityHandler = nil
                    stdoutPipe.fileHandleForReading.readabilityHandler = nil
                    // Pull anything still in the OS pipe buffer that the handlers
                    // missed between their last fire and EOF.
                    if let tailOut = try? stdoutPipe.fileHandleForReading.readToEnd() {
                        stdoutAccumulator.append(tailOut)
                    }
                    if let tailErr = try? stderrPipe.fileHandleForReading.readToEnd() {
                        stderrAccumulator.append(tailErr)
                        if let onStderrLine {
                            for line in stderrLineBuffer.appendAndTakeLines(tailErr) {
                                Task { @MainActor in onStderrLine(line) }
                            }
                        }
                    }
                    // Flush any final line the child emitted without a trailing
                    // newline so the last progress message isn't lost.
                    if let onStderrLine, let last = stderrLineBuffer.takeRemainder() {
                        Task { @MainActor in onStderrLine(last) }
                    }
                    if resumed.markAndCheck() {
                        // If stdout blew past the cap, the accumulated buffer is
                        // truncated garbage — don't hand it back to be decoded.
                        // Fail with a clear, bounded error instead.
                        if stdoutAccumulator.overflowed {
                            continuation.resume(
                                throwing: DetectionError.payloadTooLarge(limitBytes: Self.maxStdoutBytes))
                            return
                        }
                        continuation.resume(returning: SidecarOutcome(
                            exitCode: proc.terminationStatus,
                            stdout: stdoutAccumulator.snapshot(),
                            stderr: stderrAccumulator.snapshot()))
                    }
                }

                do {
                    try process.run()
                    // Hand the Process to the global tracker so it gets
                    // SIGTERM'd on app quit.
                    Task { @MainActor in
                        ChildProcessTracker.shared.register(process, kind: trackerKind)
                    }
                } catch {
                    stderrPipe.fileHandleForReading.readabilityHandler = nil
                    stdoutPipe.fileHandleForReading.readabilityHandler = nil
                    if resumed.markAndCheck() {
                        continuation.resume(throwing: error)
                    }
                }
            }
        }
    }
}

/// Thread-safe byte accumulator. `readabilityHandler` fires on a background
/// queue and `terminationHandler` reads `snapshot()` — both serialize through
/// `lock`.
private final class SidecarDataSink: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    /// Optional hard cap. Once the accumulated payload would exceed this many
    /// bytes we STOP appending and set `didOverflow`, so a pathologically large
    /// stdout (e.g. hundreds of MB of contour polygons from a confluent image)
    /// can't spike host memory into swap/OOM. `nil` = unbounded (stderr, which
    /// is small and needed verbatim for error surfacing).
    private let maxBytes: Int?
    private(set) var didOverflow = false

    init(maxBytes: Int? = nil) {
        self.maxBytes = maxBytes
    }

    func append(_ chunk: Data) {
        lock.lock(); defer { lock.unlock() }
        if let maxBytes {
            if didOverflow { return }
            if buffer.count + chunk.count > maxBytes {
                didOverflow = true
                return
            }
        }
        buffer.append(chunk)
    }

    func snapshot() -> Data {
        lock.lock(); defer { lock.unlock() }
        return buffer
    }

    var overflowed: Bool {
        lock.lock(); defer { lock.unlock() }
        return didOverflow
    }
}

/// Rolling stderr line splitter. `readabilityHandler` delivers arbitrary byte
/// boundaries, so we buffer raw bytes and only hand back COMPLETE
/// newline-terminated lines — decoding each line as a whole (never a partial
/// multi-byte character) so split progress lines aren't dropped. Accessed only
/// from the pipe's serial readability queue and the termination handler, but
/// guarded by a lock for safety.
private final class SidecarLineBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()

    /// Append a raw chunk and return every complete line now available (each
    /// trimmed, empties dropped), leaving any trailing partial line buffered.
    func appendAndTakeLines(_ chunk: Data) -> [String] {
        lock.lock(); defer { lock.unlock() }
        buffer.append(chunk)
        var lines: [String] = []
        let newline = UInt8(ascii: "\n")
        let carriage = UInt8(ascii: "\r")
        while let idx = buffer.firstIndex(where: { $0 == newline || $0 == carriage }) {
            let lineData = buffer[buffer.startIndex..<idx]
            if let text = String(data: lineData, encoding: .utf8) {
                let trimmed = text.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty { lines.append(trimmed) }
            }
            // Drop the separator byte and re-slice from a fresh 0-based buffer.
            buffer = Data(buffer[buffer.index(after: idx)...])
        }
        return lines
    }

    /// Return any buffered bytes that never got a trailing newline, as a final
    /// line. Clears the buffer.
    func takeRemainder() -> String? {
        lock.lock(); defer { lock.unlock() }
        guard !buffer.isEmpty else { return nil }
        defer { buffer = Data() }
        guard let text = String(data: buffer, encoding: .utf8) else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// One-shot resume guard for the Process termination handler.
private final class SidecarResumeFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false
    func markAndCheck() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if fired { return false }
        fired = true
        return true
    }
}
