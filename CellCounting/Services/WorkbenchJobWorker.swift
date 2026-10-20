import Foundation

nonisolated struct WorkbenchJobWorker: Identifiable, Sendable {
    let id: String
    let jobID: String?
    let sweepID: String?
    let refreshID: String?
    let targetKind: String
    let targetID: String
    let targetStatus: String?
    let completed: Int?
    let total: Int?
    let status: String
    let stopRequested: Bool
    let heartbeat: String?
    let lastRevision: Int?
    let error: String?
    var active: Bool { ["queued", "starting", "running", "stopping"].contains(status) }
    init?(_ value: WorkbenchJSON) {
        guard let id = value["workerId"].string,
              let targetID = value["targetId"].string ?? value["analysisId"].string ?? value["refreshId"].string ?? value["sweepId"].string ?? value["jobId"].string else { return nil }
        self.id = id
        self.targetID = targetID
        jobID = value["jobId"].string
        sweepID = value["sweepId"].string
        refreshID = value["refreshId"].string
        targetKind = value["targetKind"].string ?? (value["analysisId"].string != nil ? "tiled-analysis" : refreshID != nil ? "refresh" : sweepID == nil ? "job" : "sweep")
        targetStatus = value["targetStatus"].string ?? value["analysisStatus"].string ?? value["refreshStatus"].string ?? value["sweepStatus"].string ?? value["jobStatus"].string
        completed = value["progress"]["completed"].integer
        total = value["progress"]["total"].integer
        status = value["status"].string ?? "interrupted"
        stopRequested = value["stopRequested"].bool == true
        heartbeat = value["heartbeatAt"].string
        lastRevision = value["lastRevision"].integer
        error = value["error"]["message"].string ?? value["error"].string
    }
}
