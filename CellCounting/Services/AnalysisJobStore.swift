import Foundation

/// Durable copy of the processing queue. Writes are serialised by a lock so a
/// debounced background write and a synchronous flush at quit cannot interleave,
/// and a stale revision can never replace a newer one. The on-disk format is
/// unchanged (schema 1), so files written by earlier versions load as before.
nonisolated final class AnalysisJobStore: @unchecked Sendable {
    private struct Document: Codable { var schemaVersion = 1; var jobs: [AnalysisJob] }
    let url: URL
    private let lock = NSLock()
    private var lastRevision = -1
    init(url: URL) { self.url = url }

    func load() async throws -> [AnalysisJob] {
        try await Task.detached(priority: .utility) { try self.loadSync() }.value
    }
    func save(_ jobs: [AnalysisJob], revision: Int? = nil) async throws {
        try await Task.detached(priority: .utility) { try self.saveSync(jobs, revision: revision) }.value
    }

    func loadSync() throws -> [AnalysisJob] {
        lock.lock(); defer { lock.unlock() }
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let document = try JSONDecoder().decode(Document.self, from: Data(contentsOf: url))
        guard document.schemaVersion == 1 else {
            throw NSError(domain: "AnalysisJobs", code: 1, userInfo: [NSLocalizedDescriptionKey: "This processing queue was saved by a newer version of Cellographer."])
        }
        return document.jobs.map { var job = $0; job.recoverAfterLaunch(); return job }
    }
    /// Synchronous write, also used by the quit-time flush.
    func saveSync(_ jobs: [AnalysisJob], revision: Int? = nil) throws {
        lock.lock(); defer { lock.unlock() }
        if let revision, revision < lastRevision { return }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(Document(jobs: jobs))
        try data.write(to: url, options: .atomic)
        if let revision { lastRevision = revision }
    }
}
