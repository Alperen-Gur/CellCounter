//  SidecarProcessRunner.swift
//  CellCounting
//
//  Single, correct implementation of "spawn a Python detection sidecar,
//  bridge its termination into structured concurrency, and drain both pipes
//  CONCURRENTLY." Every sidecar detection service (Cellpose, YOLO, StarDist,
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
}

enum SidecarProcessRunner {

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
                stderrPipe.fileHandleForReading.readabilityHandler = { handle in
                    let chunk = handle.availableData
                    if chunk.isEmpty { return } // EOF
                    stderrAccumulator.append(chunk)
                    guard let onStderrLine,
                          let text = String(data: chunk, encoding: .utf8) else { return }
                    for raw in text.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
                        let line = String(raw).trimmingCharacters(in: .whitespaces)
                        guard !line.isEmpty else { continue }
                        Task { @MainActor in onStderrLine(line) }
                    }
                }

                // stdout — drain CONCURRENTLY too, or a payload bigger than the
                // OS pipe buffer wedges the child (see file header).
                let stdoutAccumulator = SidecarDataSink()
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
                    }
                    if resumed.markAndCheck() {
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

    func append(_ chunk: Data) {
        lock.lock(); defer { lock.unlock() }
        buffer.append(chunk)
    }

    func snapshot() -> Data {
        lock.lock(); defer { lock.unlock() }
        return buffer
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
