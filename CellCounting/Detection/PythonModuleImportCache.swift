//  PythonModuleImportCache.swift
//  CellCounting
//
//  One generic per-interpreter cache for `python -c "import <module>"` probes.
//  The Models view asks `isInstalled` on every refresh; without a cache that
//  would fork one probe process per detector per refresh. Each downloader
//  instantiates this with its module name instead of hand-rolling an identical
//  NSLock + [String: Bool] cache.

import Foundation

/// Thread-safe cache of "can this python interpreter `import <module>`?"
/// keyed by interpreter path.
final class PythonModuleImportCache: @unchecked Sendable {
    private let module: String
    private let lock = NSLock()
    private var cache: [String: Bool] = [:]

    /// - Parameter module: the importable module name, e.g. "micro_sam".
    init(module: String) {
        self.module = module
    }

    /// Blocking probe. Forks `python -c "import <module>"` on a cache miss and
    /// memoizes the result for this interpreter path.
    func isImportable(pythonURL: URL) -> Bool {
        let key = pythonURL.path
        lock.lock()
        if let cached = cache[key] { lock.unlock(); return cached }
        lock.unlock()

        let ok = Self.runImportCheck(pythonURL: pythonURL, module: module)
        lock.lock(); cache[key] = ok; lock.unlock()
        return ok
    }

    /// Non-blocking peek. Returns nil if this interpreter was never probed —
    /// used by the main-safe `isInstalled` so it can answer without forking.
    func cachedAnswer(pythonURL: URL) -> Bool? {
        lock.lock(); defer { lock.unlock() }
        return cache[pythonURL.path]
    }

    func invalidate(pythonURL: URL) {
        lock.lock(); defer { lock.unlock() }
        cache[pythonURL.path] = nil
    }

    private static func runImportCheck(pythonURL: URL, module: String) -> Bool {
        guard FileManager.default.isExecutableFile(atPath: pythonURL.path) else { return false }
        let process = Process()
        process.executableURL = pythonURL
        process.arguments = ["-c", "import \(module)"]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }
}
