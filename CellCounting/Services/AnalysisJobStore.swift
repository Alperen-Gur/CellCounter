import Foundation

actor AnalysisJobStore {
    private struct Document: Codable { var schemaVersion = 1; var jobs: [AnalysisJob] }
    let url: URL
    private var lastRevision = -1
    init(url: URL) { self.url = url }
    func load() throws -> [AnalysisJob] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let document = try JSONDecoder().decode(Document.self, from: Data(contentsOf: url))
        guard document.schemaVersion == 1 else {
            throw NSError(domain: "AnalysisJobs", code: 1, userInfo: [NSLocalizedDescriptionKey: "This processing queue was saved by a newer version of CellCounter."])
        }
        return document.jobs.map { var job = $0; job.recoverAfterLaunch(); return job }
    }
    func save(_ jobs: [AnalysisJob], revision: Int? = nil) throws {
        if let revision, revision < lastRevision { return }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(Document(jobs: jobs))
        try data.write(to: url, options: .atomic)
        if let revision { lastRevision = revision }
    }
}
