import Foundation
import SwiftData

// MARK: - Filling in compact cell metrics for existing detections

extension Repositories {
    /// Detections whose metrics are missing or were written by another codec
    /// version.
    private static func cellMetricsNeeded() -> Predicate<DetectionRecord> {
        let current = CellMetricsCodec.version
        return #Predicate<DetectionRecord> { $0.cellMetricsVersion != current }
    }

    /// Writes `cellMetricsData` for detections saved before it existed (or by
    /// an older codec). Reads a few rows at a time on the main actor, decodes
    /// their payloads and encodes the metrics on a detached task, and writes
    /// back only to rows that still exist with an unchanged `cellsRevision`,
    /// saving after each chunk. Payloads that cannot be read are skipped and
    /// left as they are; screens keep reading those through the full payload.
    /// Idempotent and cancellable at any point, and it stops while archive or
    /// restore holds background upkeep. Returns how many rows were written.
    ///
    /// Always a full pass over every matching row; the automatic background
    /// run (`CellMetricsBackfill`) instead does only what `upkeepNote` reports.
    @discardableResult
    func backfillCellMetrics(chunkSize: Int = 8, pause: Duration? = nil) async throws -> Int {
        try await runUpkeepPass(.cellMetrics, work: upkeepNote.beginFullPass(.cellMetrics)) {
            try await backfillCellMetrics($0, chunkSize: chunkSize, pause: pause)
        }.count
    }

    /// One automatic pass over the work `upkeepNote` reports. Returns whether
    /// it went through all of it.
    func backfillReportedCellMetrics(chunkSize: Int = 8, pause: Duration? = nil) async throws -> Bool {
        try await runUpkeepPass(.cellMetrics, work: upkeepNote.beginPass(.cellMetrics)) {
            try await backfillCellMetrics($0, chunkSize: chunkSize, pause: pause)
        }.finished
    }

    /// Candidates are read once (ids only) and then fetched by id, so every
    /// row is visited once however many payloads stay unreadable.
    private func backfillCellMetrics(_ work: BackgroundUpkeepNote.Work, chunkSize: Int,
                                     pause: Duration?) async throws -> UpkeepPassResult {
        struct Input: Sendable {
            let id: UUID
            let revision: Int
            let payload: Data
        }
        guard !Task.isCancelled, !isBackgroundUpkeepHeld else { return UpkeepPassResult(count: 0, finished: false) }
        let current = CellMetricsCodec.version
        var queue = UpkeepIDQueue(try upkeepCandidateIDs(work, query: Self.cellMetricsNeeded(),
                                                         id: \DetectionRecord.id))
        var written = 0
        while let chunk = queue.nextChunk(size: chunkSize) {
            guard !Task.isCancelled, !isBackgroundUpkeepHeld else {
                return UpkeepPassResult(count: written, finished: false)
            }
            let rows = try context.fetch(FetchDescriptor<DetectionRecord>(
                predicate: #Predicate { chunk.contains($0.id) }))
                .filter { !$0.isDeleted && $0.cellMetricsVersion != current }
            upkeepVisitObserver?(.cellMetrics, rows.map(\.id))
            guard !rows.isEmpty else { continue }
            let inputs = rows.map { Input(id: $0.id, revision: $0.cellsRevision, payload: $0.cellsData) }
            let encoded: [UUID: Data] = await Task.detached(priority: .utility) {
                var result: [UUID: Data] = [:]
                for input in inputs {
                    guard let cells = try? DetectionRecord.decodeCellsDataForReview(input.payload) else { continue }
                    result[input.id] = CellMetricsCodec.encode(cells)
                }
                return result
            }.value
            guard !Task.isCancelled, !isBackgroundUpkeepHeld else {
                return UpkeepPassResult(count: written, finished: false)
            }

            var chunkWritten = 0
            for (row, input) in zip(rows, inputs) {
                // A row may have been deleted or edited while the chunk was
                // being encoded; an edit already wrote its own metrics.
                // Unreadable payloads are skipped and left as they are.
                guard !row.isDeleted, row.modelContext === context,
                      row.cellMetricsVersion != CellMetricsCodec.version else { continue }
                // Changed since it was read: try once more.
                guard row.cellsRevision == input.revision else {
                    queue.requeue(row.id)
                    continue
                }
                guard let metrics = encoded[input.id] else { continue }
                row.storeCellMetrics(metrics)
                chunkWritten += 1
            }
            if chunkWritten > 0 {
                try context.save()
                written += chunkWritten
            }
            await Self.pauseUpkeep(pause)
        }
        return UpkeepPassResult(count: written, finished: !Task.isCancelled && !isBackgroundUpkeepHeld)
    }
}

/// Runs the cell-metrics upkeep in the background for the app's own library:
/// after launch when the library's `upkeepNote` says the job may have work
/// (a library this version has not completed it for), and a few seconds
/// after a write reports detections without current metrics
/// (`Repositories.noteUpkeepWork(for:)`) or a restore brings rows in. A
/// library whose note records the job as done is not read at all. Waits
/// while archive or restore holds background upkeep.
@MainActor
final class CellMetricsBackfill {
    static let shared = CellMetricsBackfill()

    private weak var repos: Repositories?
    private var task: Task<Void, Never>?
    private var debounce: Task<Void, Never>?
    private var generation = 0

    /// Starts upkeep for `repos`. Does nothing for isolated stores (tests,
    /// tools), which run `backfillCellMetrics()` themselves.
    func start(repos: Repositories, after delay: Duration = .seconds(3)) {
        guard repos.automaticVariantCompaction else { return }
        if self.repos !== repos {
            cancel()
            self.repos = repos
            repos.onCellMetricsWork = { CellMetricsBackfill.shared.schedule(after: .seconds(5)) }
        }
        schedule(after: delay)
    }

    func schedule(after delay: Duration) {
        guard repos != nil else { return }
        debounce?.cancel()
        debounce = Task(priority: .utility) { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            self.debounce = nil
            self.runIfIdle()
        }
    }

    func cancel() {
        debounce?.cancel()
        debounce = nil
        task?.cancel()
        task = nil
        generation &+= 1
        repos?.onCellMetricsWork = nil
        repos = nil
    }

    private func runIfIdle() {
        // A running task takes work reported meanwhile in its next pass.
        guard task == nil, let repos, repos.upkeepNote.needsRun(.cellMetrics) else { return }
        generation &+= 1
        let current = generation
        task = Task(priority: .utility) { [weak self, weak repos] in
            while !Task.isCancelled, let repos, repos.upkeepNote.needsRun(.cellMetrics) {
                if repos.isBackgroundUpkeepHeld {
                    try? await Task.sleep(for: .seconds(2))
                    continue
                }
                let finished = (try? await repos.backfillReportedCellMetrics(pause: .milliseconds(40))) ?? false
                // A pass stopped by a hold resumes once the hold is released.
                if !finished && !repos.isBackgroundUpkeepHeld { break }
            }
            if let self, self.generation == current { self.task = nil }
        }
    }
}
