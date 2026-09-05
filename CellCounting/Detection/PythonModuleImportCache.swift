import Foundation

/// Fast cached reads for the UI, with one background import per interpreter.
/// Invalidation detaches an old in-flight probe so it cannot republish stale
/// success after an install, reset, or removal.
nonisolated final class PythonModuleImportCache: @unchecked Sendable {
    private struct Entry {
        let result: Bool
        let date: Date
    }
    private final class Flight: @unchecked Sendable {
        let done = DispatchGroup()
        var result = false
        init() { done.enter() }
    }
    private let lock = NSLock()
    private var cache: [String: Entry] = [:]
    private var flights: [String: Flight] = [:]
    private let probe: @Sendable (URL) -> Bool
    private let lifetime: TimeInterval

    init(module: String, lifetime: TimeInterval = 30,
         probe: (@Sendable (URL) -> Bool)? = nil) {
        self.lifetime = lifetime
        self.probe = probe ?? { ModelProbeRunner.run(pythonURL: $0, code: "import \(module)") }
    }

    /// Blocking background API. Concurrent misses join the same import. The
    /// result expires so external environment changes are caught on refresh.
    func isImportable(pythonURL: URL) -> Bool {
        guard !Thread.isMainThread else { return cachedAnswer(pythonURL: pythonURL) ?? false }
        let key = pythonURL.path
        lock.lock()
        if let entry = cache[key], Date().timeIntervalSince(entry.date) < lifetime {
            lock.unlock()
            return entry.result
        }
        if let flight = flights[key] {
            lock.unlock()
            flight.done.wait()
            return flight.result
        }
        let flight = Flight()
        flights[key] = flight
        lock.unlock()

        let result = probe(pythonURL)
        lock.lock()
        if flights[key] === flight {
            // Runtime paths are few, but user-provided interpreters should not
            // turn the session cache into an unbounded history.
            if cache.count >= 16, cache[key] == nil {
                let oldest = cache.min { $0.value.date < $1.value.date }?.key
                if let oldest { cache[oldest] = nil }
            }
            cache[key] = Entry(result: result, date: Date())
            flights[key] = nil
        }
        flight.result = result
        flight.done.leave()
        lock.unlock()
        return result
    }

    /// Snapshot only: no process, stat call, or wait on a running import.
    func cachedAnswer(pythonURL: URL) -> Bool? {
        lock.lock(); defer { lock.unlock() }
        return cache[pythonURL.path]?.result
    }

    func invalidate(pythonURL: URL) {
        lock.lock(); defer { lock.unlock() }
        cache[pythonURL.path] = nil
        flights[pythonURL.path] = nil
    }
}
