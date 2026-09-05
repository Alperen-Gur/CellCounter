import Foundation

/// One warm assay process, independent of detector workers. Waiting calls hold
/// no process lease, so cancelling a queued request cannot terminate an active
/// assay. The worker itself serializes numerical work and caps prepared data.
actor AssayWorkerService {
    static let shared = AssayWorkerService()
    private let pool = PersistentSidecarPool()
    private var identity: PersistentSidecarKey?
    private var activeID: UUID?
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, Error>
    }
    private var waiters: [Waiter] = []
    private var retirement: Task<Void, Never>?
    private let idleSeconds: Double
    private let maxPending = 64

    init(idleSeconds: Double = 120) { self.idleSeconds = max(0, idleSeconds) }

    var pendingRequestCount: Int { waiters.count }
    var hasActiveRequest: Bool { activeID != nil }

    func run(pythonURL: URL, scriptURL: URL, args: [String]) async throws -> SidecarOutcome {
        let id = UUID()
        return try await withTaskCancellationHandler {
            try await acquire(id)
            defer { release(id) }
            try Task.checkCancellation()
            let workerURL = scriptURL.deletingLastPathComponent().appendingPathComponent("_assay_worker.py")
            guard FileManager.default.fileExists(atPath: workerURL.path) else {
                throw PersistentSidecarError.launchFailed("The assay worker is missing. Reopen the app to stage its Python helpers.")
            }
            let key = try workerIdentity(pythonURL: pythonURL, workerURL: workerURL)
            if identity != key {
                await pool.retireAll()
                identity = key
            }
            // Pool cancellation retires only this checked-out worker. No other
            // assay has entered the pool while this lease remains active.
            do {
                let outcome = try await pool.run(key: key, pythonURL: pythonURL,
                                                 scriptURL: workerURL,
                                                 args: [scriptURL.lastPathComponent] + args,
                                                 trackerKind: .other)
                try Task.checkCancellation()
                return outcome
            } catch {
                if Task.isCancelled { throw DetectionError.cancelled }
                if case PersistentSidecarError.processTerminated(let status, let stderr) = error {
                    return SidecarOutcome(exitCode: status, stdout: Data(), stderr: stderr)
                }
                throw error
            }
        } onCancel: {
            Task { await self.cancelWaiting(id) }
        }
    }

    private func acquire(_ id: UUID) async throws {
        try Task.checkCancellation()
        retirement?.cancel()
        retirement = nil
        if activeID == nil { activeID = id; return }
        guard waiters.count < maxPending else {
            throw PersistentSidecarError.protocolFailure("The assay queue is full; wait for an active assay to finish.")
        }
        try await withCheckedThrowingContinuation { continuation in
            waiters.append(Waiter(id: id, continuation: continuation))
        }
    }

    private func release(_ id: UUID) {
        guard activeID == id else { return }
        if !waiters.isEmpty {
            let next = waiters.removeFirst()
            activeID = next.id
            next.continuation.resume()
        } else {
            activeID = nil
            let delay = idleSeconds
            retirement = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(delay)) } catch { return }
                await self?.retireIfIdle()
            }
        }
    }

    private func cancelWaiting(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = waiters.remove(at: index)
        waiter.continuation.resume(throwing: CancellationError())
    }

    private func retireIfIdle() async {
        guard activeID == nil else { return }
        await pool.retireAll()
        identity = nil
        retirement = nil
    }

    func shutdown() async {
        retirement?.cancel()
        retirement = nil
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.continuation.resume(throwing: CancellationError()) }
        await pool.retireAll()
        identity = nil
    }

    /// Reinstalling Python or editing any helper invalidates imported modules.
    /// Input file/mask identities and processing parameters are checked by the
    /// worker on every request, separately from this process construction key.
    private func workerIdentity(pythonURL: URL, workerURL: URL) throws -> PersistentSidecarKey {
        let directory = workerURL.deletingLastPathComponent()
        var urls = try FileManager.default.contentsOfDirectory(at: directory,
                                                               includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "py" }
        urls.append(pythonURL.resolvingSymlinksInPath())
        let stamps = try urls.sorted { $0.path < $1.path }.map { url in
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            return "\(url.path):\(attributes[.systemFileNumber] ?? 0):\(attributes[.size] ?? 0):\(modified)"
        }
        return PersistentSidecarKey(pythonPath: pythonURL.path, scriptPath: workerURL.path,
                                    modelSignature: stamps.joined(separator: "|"))
    }
}
