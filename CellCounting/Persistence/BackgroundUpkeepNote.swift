import Foundation

/// Per-library note of which background upkeep jobs have nothing left to do.
///
/// The jobs (`Repositories.compactSegmentationVariants()`,
/// `migrateDetectionCellStorage()` and `backfillCellMetrics()`) find their
/// rows with queries on columns that, in stores written by older versions,
/// sit after the large cell columns. Such a query reads every row of its
/// table even when it matches nothing. The jobs therefore run automatically
/// only while this note says there may be work:
/// - there is no note, the note describes another store file, or it was
///   written for an older version of the job: one full pass over the job's
///   query;
/// - a write left new work and named its rows (`noteWork(_:ids:)`): a pass
///   over just those rows, fetched by id;
/// - rows came in that are not named (`noteUnknownWork(_:)`, a restore):
///   one full pass.
/// A pass that ends with no new work reported in the meantime records the
/// job as done for its current version.
///
/// The note is a small file next to the library's store, as for
/// `ReviewIndexCheck`, so each library and each copy of a library folder has
/// its own. It names the store file it describes, so a store replaced by
/// another file (a restored backup, a copied database) is checked again.
/// Stores without a folder (in-memory, including the fallback used when the
/// disk store cannot be opened) keep the state in memory only and start out
/// unchecked. Never kept in preferences: there are several libraries.
///
/// The file never records a job as done while work for it is known: reported
/// work removes the job from the file at once, before the write is saved, so
/// quitting at any point leaves at worst one extra pass for the next launch.
@MainActor
final class BackgroundUpkeepNote {
    enum Job: String, CaseIterable, Sendable {
        /// `Repositories.compactSegmentationVariants()`.
        case maskVersions
        /// `Repositories.migrateDetectionCellStorage()`.
        case detectionCellStorage
        /// `Repositories.backfillCellMetrics()`.
        case cellMetrics

        /// Recorded when the job completes. Raise it when the job's rules
        /// change, so every library runs the job once more.
        var version: Int {
            switch self {
            case .maskVersions: 1
            case .detectionCellStorage: 1
            // The job's query is "metrics not written by the current codec".
            case .cellMetrics: CellMetricsCodec.version
            }
        }
    }

    /// What one pass of a job covers.
    enum Work: Equatable, Sendable {
        /// Every row the job's query matches.
        case all
        /// Only these rows (ids of the job's records), fetched by id.
        case rows(Set<UUID>)
    }

    static let fileName = "background-upkeep.json"

    private struct Note: Codable {
        /// Job name → version of the job last completed in this library.
        var done: [String: Int]
        /// File number of the store file the note describes.
        var storeFile: UInt64?
    }

    private struct State {
        var needsFullPass: Bool
        var rows: Set<UUID> = []
    }

    /// Nil for in-memory stores.
    let fileURL: URL?
    private let storeURL: URL?
    private var loadedStates: [Job: State]?
    /// Jobs the file currently records as done.
    private var recordedDone: Set<Job> = []

    init(fileURL: URL?, storeURL: URL?) {
        self.fileURL = fileURL
        self.storeURL = fileURL == nil ? nil : storeURL
    }

    /// The note for the store at `storeURL`, kept in the store's folder (the
    /// library root). In-memory stores report `/dev/null`.
    convenience init(storeURL: URL?) {
        guard let storeURL, storeURL.isFileURL, storeURL.path != "/dev/null" else {
            self.init(fileURL: nil, storeURL: nil)
            return
        }
        self.init(fileURL: storeURL.deletingLastPathComponent()
                      .appendingPathComponent(Self.fileName, isDirectory: false),
                  storeURL: storeURL)
    }

    // MARK: Reading

    /// True while the job may have work: a full pass is due, or written rows
    /// were reported and no pass has taken them yet.
    func needsRun(_ job: Job) -> Bool {
        let state = states[job] ?? State(needsFullPass: true)
        return state.needsFullPass || !state.rows.isEmpty
    }

    /// Rows reported and not yet taken by a pass (for tests and diagnostics).
    func reportedRows(_ job: Job) -> Set<UUID> {
        states[job]?.rows ?? []
    }

    /// True when the next pass of the job reads its whole query.
    func needsFullPass(_ job: Job) -> Bool {
        states[job]?.needsFullPass ?? true
    }

    // MARK: Reporting work

    /// Rows a write just left needing `job`. Call after the rows are in the
    /// context (inserted or changed), in the same main-actor step.
    func noteWork(_ job: Job, ids: some Sequence<UUID>) {
        var current = states
        var state = current[job] ?? State(needsFullPass: true)
        let before = state.rows.count
        state.rows.formUnion(ids)
        guard state.rows.count != before else { return }
        current[job] = state
        loadedStates = current
        forgetDone(job)
    }

    /// Rows came in for `job` that are not named: the next pass reads the
    /// whole query.
    func noteUnknownWork(_ job: Job) {
        var current = states
        current[job, default: State(needsFullPass: true)].needsFullPass = true
        loadedStates = current
        forgetDone(job)
    }

    // MARK: Passes

    /// Takes the work for the next automatic pass: everything when a full pass
    /// is due (it covers reported rows too), otherwise the reported rows.
    func beginPass(_ job: Job) -> Work {
        var current = states
        let state = current[job] ?? State(needsFullPass: true)
        current[job] = State(needsFullPass: false)
        loadedStates = current
        return state.needsFullPass ? .all : .rows(state.rows)
    }

    /// Takes everything for a full pass run on request (tools, tests).
    func beginFullPass(_ job: Job) -> Work {
        var current = states
        current[job] = State(needsFullPass: false)
        loadedStates = current
        return .all
    }

    /// Ends a pass. A pass that did not finish (cancelled, held, failed)
    /// gives its work back. A finished pass records the job as done, unless
    /// new work was reported while it ran (the next pass takes that).
    func endPass(_ job: Job, _ work: Work, finished: Bool) {
        guard finished else {
            var current = states
            var state = current[job] ?? State(needsFullPass: true)
            switch work {
            case .all: state.needsFullPass = true
            case .rows(let rows): state.rows.formUnion(rows)
            }
            current[job] = state
            loadedStates = current
            return
        }
        guard !needsRun(job) else { return }
        recordDone(job)
    }

    // MARK: Storage

    private var states: [Job: State] {
        if let loadedStates { return loadedStates }
        let done = readRecordedDone()
        recordedDone = done
        var initial: [Job: State] = [:]
        for job in Job.allCases { initial[job] = State(needsFullPass: !done.contains(job)) }
        loadedStates = initial
        return initial
    }

    /// Jobs the file records as done for their current version and for the
    /// store file that is there now.
    private func readRecordedDone() -> Set<Job> {
        guard let fileURL,
              let data = try? Data(contentsOf: fileURL),
              let note = try? JSONDecoder().decode(Note.self, from: data),
              let storeFile = currentStoreFile(), note.storeFile == storeFile else { return [] }
        return Set(Job.allCases.filter { note.done[$0.rawValue] == $0.version })
    }

    private func currentStoreFile() -> UInt64? {
        guard let storeURL,
              let attributes = try? FileManager.default.attributesOfItem(atPath: storeURL.path) else { return nil }
        return (attributes[.systemFileNumber] as? NSNumber)?.uint64Value
    }

    private func recordDone(_ job: Job) {
        _ = states
        guard !recordedDone.contains(job) else { return }
        recordedDone.insert(job)
        write()
    }

    private func forgetDone(_ job: Job) {
        guard recordedDone.contains(job) else { return }
        recordedDone.remove(job)
        write()
    }

    /// A note that cannot be written only means a job runs once more.
    private func write() {
        guard let fileURL else { return }
        guard !recordedDone.isEmpty, let storeFile = currentStoreFile() else {
            try? FileManager.default.removeItem(at: fileURL)
            return
        }
        var done: [String: Int] = [:]
        for job in recordedDone { done[job.rawValue] = job.version }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(Note(done: done, storeFile: storeFile)) else {
            try? FileManager.default.removeItem(at: fileURL)
            return
        }
        // A failed write must not leave an older note recording more as done.
        do { try data.write(to: fileURL, options: .atomic) }
        catch { try? FileManager.default.removeItem(at: fileURL) }
    }
}

/// The row ids of one upkeep pass, handed out in chunks in order, so each
/// row is fetched (by id) once. A row that changed while its chunk was being
/// processed can be queued once more, at the end.
nonisolated struct UpkeepIDQueue: Sendable {
    private var ids: [UUID]
    private var next = 0
    private var requeued: Set<UUID> = []

    init(_ ids: [UUID]) {
        self.ids = ids
    }

    var isEmpty: Bool { next >= ids.count }

    mutating func nextChunk(size: Int) -> [UUID]? {
        guard next < ids.count else { return nil }
        let end = min(next + max(1, size), ids.count)
        defer { next = end }
        return Array(ids[next..<end])
    }

    /// Queues `id` again unless it was already queued again in this pass.
    mutating func requeue(_ id: UUID) {
        guard requeued.insert(id).inserted else { return }
        ids.append(id)
    }
}
