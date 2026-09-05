import Foundation
import Darwin

/// Availability probes never need their output. Sending it to /dev/null avoids
/// pipe backpressure, and a real process deadline bounds a wedged native import.
/// Call from a detached task; the UI must only read cached answers.
nonisolated enum ModelProbeRunner {
    static func run(pythonURL: URL, code: String, timeout: TimeInterval = 15) -> Bool {
        guard !Thread.isMainThread,
              FileManager.default.isExecutableFile(atPath: pythonURL.path) else { return false }
        let process = Process()
        process.executableURL = pythonURL
        process.arguments = ["-c", code]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let ended = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in ended.signal() }
        do { try process.run() } catch { return false }
        let registration = Task { @MainActor in
            if process.isRunning { ChildProcessTracker.shared.register(process, kind: .other) }
        }
        defer {
            Task {
                await registration.value
                await ChildProcessTracker.shared.forget(process)
            }
        }
        if ended.wait(timeout: .now() + max(0.05, timeout)) == .timedOut {
            if process.isRunning { process.terminate() }
            if ended.wait(timeout: .now() + 0.3) == .timedOut, process.isRunning {
                kill(process.processIdentifier, SIGKILL)
                _ = ended.wait(timeout: .now() + 1)
            }
            return false
        }
        return process.terminationStatus == 0
    }
}
