import Foundation
import Observation
import AppKit

@Observable @MainActor
final class AnalysisJobScheduler {
    typealias Prepare = @MainActor (AnalysisJobItem, AnalysisRunSettings, UUID) async throws -> UUID
    typealias Analyze = @MainActor (UUID, AnalysisRunSettings) async throws -> Void
    private(set) var jobs: [AnalysisJob] = []
    private(set) var isLoaded = false
    private(set) var persistenceError: String?
    private(set) var activeJobId: UUID?
    private(set) var previewItemId: UUID?
    /// Number of queued, running or pausing jobs. Stored (and only assigned when
    /// it changes) so views that read it are not invalidated by item progress.
    private(set) var activeCount = 0
    /// Row label per imported image, kept current as items change.
    private(set) var imageStatuses: [UUID: String] = [:]
    /// Finished (completed) jobs kept in history; older ones are pruned.
    nonisolated static let maxFinishedJobs = 50
    var maxParallel = 2
    var physicalMemory = ProcessInfo.processInfo.physicalMemory
    @ObservationIgnored private let store: AnalysisJobStore
    @ObservationIgnored private var prepare: Prepare?
    @ObservationIgnored private var analyze: Analyze?
    @ObservationIgnored private var worker: Task<Void, Never>?
    @ObservationIgnored private var previewTask: Task<Void, Error>?
    @ObservationIgnored private var revision = 0
    @ObservationIgnored private var preparations: [UUID: Task<UUID, Error>] = [:]
    @ObservationIgnored private var restoring = false
    @ObservationIgnored private var imageOwner: [UUID: UUID] = [:]   // imageId -> newest job holding it
    @ObservationIgnored private var dirty = false
    @ObservationIgnored private var debounceTask: Task<Void, Never>?
    @ObservationIgnored var persistDelay: Duration = .seconds(2)
    @ObservationIgnored private var terminationObserver: NSObjectProtocol?

    init(store: AnalysisJobStore) {
        self.store = store
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.flushForTermination() }
        }
    }
    func configure(prepare: @escaping Prepare, analyze: @escaping Analyze) {
        self.prepare = prepare; self.analyze = analyze
    }
    func restore() async {
        let timing = LocalPerformanceRecorder.shared.begin(.queueLoad)
        defer { timing?.finish() }
        guard !isLoaded else { return }
        if restoring {
            while !isLoaded { await Task.yield() }
            return
        }
        restoring = true
        do {
            var loaded = try await store.load()
            for index in loaded.indices { loaded[index].dropImportedBookmarks() }
            jobs = loaded; pruneFinished(); refreshDerived(); isLoaded = true
        }
        catch { persistenceError = error.localizedDescription; isLoaded = true }
    }
    func job(_ id: UUID) -> AnalysisJob? { jobs.first { $0.id == id } }
    /// O(1) label for an image's row in Results, or nil when no job holds it.
    func statusLabel(for imageId: UUID) -> String? { imageStatuses[imageId] }

    @discardableResult func add(_ job: AnalysisJob) async throws -> UUID {
        guard isLoaded, persistenceError == nil else { throw unavailableError() }
        var job = job
        job.dropImportedBookmarks()
        jobs.append(job)
        refreshDerived()
        try await persist()
        return job.id
    }
    /// Saves a draft. A change to anything but the scale analyses every image
    /// again. Each image has its own scale: `itemScales` sets the scale chosen
    /// for single images (a nil value removes it), and `scaleResets` lists the
    /// items whose scale changed, which are analysed again. Without
    /// `scaleResets`, a changed job scale analyses every image again.
    func updateDraft(_ id: UUID, settings: AnalysisRunSettings, preset: AnalysisTaskPreset,
                     itemScales: [UUID: ImageScale.Value?] = [:],
                     scaleResets: Set<UUID>? = nil) async throws {
        guard let index = index(id), [.draft, .paused, .failed, .completed, .cancelled].contains(jobs[index].status) else { return }
        if let error = settings.validationError { throw messageError(error) }
        let previous = jobs[index].settings
        let resetAll = !previous.hasSameInputs(as: settings, ignoringScale: true)
            || (scaleResets == nil && previous.pxPerUm != settings.pxPerUm)
        for item in jobs[index].items.indices {
            let itemId = jobs[index].items[item].id
            if let change = itemScales[itemId] { jobs[index].items[item].ownScale = change }
            if resetAll || scaleResets?.contains(itemId) == true {
                jobs[index].items[item].status = jobs[index].items[item].imageId == nil ? .pending : .ready
                jobs[index].items[item].duration = nil
                jobs[index].items[item].error = nil
            }
        }
        jobs[index].settings = settings; jobs[index].taskPreset = preset
        jobs[index].status = .draft; jobs[index].error = nil
        refreshDerived()
        try await persist()
    }
    func enqueue(_ id: UUID, importOnly: Bool = false) async throws {
        guard previewItemId == nil, let index = index(id),
              ![.queued, .running, .pausing].contains(jobs[index].status) else {
            throw messageError("This job is already running or a preview is in progress.")
        }
        if jobs[index].importOnly && !importOnly {
            for item in jobs[index].items.indices where jobs[index].items[item].status == .completed {
                jobs[index].items[item].status = .ready
            }
        }
        if let error = jobs[index].settings.validationError { throw messageError(error) }
        jobs[index].importOnly = importOnly
        jobs[index].status = .queued; jobs[index].error = nil
        refreshDerived()
        try await persist()
        startWorker()
    }
    func pause(_ id: UUID) async {
        guard let index = index(id), [.queued, .running].contains(jobs[index].status) else { return }
        jobs[index].status = activeJobId == id ? .pausing : .paused
        refreshDerived()
        await persistOrPause()
    }
    func resume(_ id: UUID) async throws {
        guard let index = index(id), [.paused, .failed, .cancelled].contains(jobs[index].status) else { return }
        jobs[index].status = .queued; jobs[index].error = nil
        refreshDerived()
        try await persist(); startWorker()
    }
    func retryFailures(_ id: UUID) async throws {
        guard let index = index(id), activeJobId != id else { return }
        jobs[index].retryFailures()
        refreshDerived()
        try await persist(); startWorker()
    }
    func cancel(_ id: UUID) async {
        guard let index = index(id) else { return }
        jobs[index].status = .cancelled
        refreshDerived()
        if jobs[index].items.contains(where: { $0.id == previewItemId }) { cancelPreview() }
        if activeJobId == id { worker?.cancel() }
        await persistOrPause()
    }
    func remove(_ id: UUID) async throws {
        guard activeJobId != id, previewItemId == nil else { return }
        jobs.removeAll { $0.id == id }
        refreshDerived()
        try await persist()
    }

    /// Importing a sample is useful even when no detector is installed.
    func prepareSample(_ jobId: UUID, itemId: UUID) async throws -> UUID {
        try await prepareItem(jobId, itemId: itemId)
    }

    /// A preview uses the same durable run configuration and result writer as
    /// batch work. A matching preview is reused when that batch is submitted.
    func preview(_ jobId: UUID, itemId: UUID) async throws {
        guard activeJobId == nil, previewItemId == nil, !TrainingService.isTrainingActive,
              let job = job(jobId), let analyze else {
            throw messageError("Pause processing and finish training before starting a preview.")
        }
        previewItemId = itemId; refreshDerived()
        defer { previewItemId = nil; previewTask = nil; refreshDerived(); startWorker() }
        let task = Task {
            let imageId = try await self.prepareItem(jobId, itemId: itemId)
            try Task.checkCancellation()
            let started = Date()
            do {
                try await analyze(imageId, job.settings)
                try Task.checkCancellation()
                self.mutateItem(jobId, itemId) { $0.status = .completed; $0.error = nil; $0.duration = Date().timeIntervalSince(started) }
                try await self.persist()
            } catch {
                let cancelled = Task.isCancelled || error is CancellationError
                self.mutateItem(jobId, itemId) {
                    $0.status = cancelled ? .ready : .failed
                    $0.error = cancelled ? nil : error.localizedDescription
                }
                await self.persistOrPause()
                throw error
            }
        }
        previewTask = task
        try await task.value
    }
    func cancelPreview() { previewTask?.cancel() }

    func modelExecutionBecameAvailable() { startWorker() }

    private func startWorker() {
        guard worker == nil, previewItemId == nil, persistenceError == nil, !TrainingService.isTrainingActive,
              prepare != nil, analyze != nil, jobs.contains(where: { $0.status == .queued }) else { return }
        worker = Task { [weak self] in await self?.runQueue() }
    }
    private func runQueue() async {
        defer {
            activeJobId = nil; worker = nil
            if persistenceError == nil { startWorker() }
        }
        while !Task.isCancelled, let next = jobs.first(where: { $0.status == .queued }) {
            activeJobId = next.id
            if let index = index(next.id) { jobs[index].status = .running }
            refreshDerived()
            guard await persistOrPause() else { return }
            await runJob(next.id)
            activeJobId = nil
        }
    }
    private func runJob(_ id: UUID) async {
        let timing = LocalPerformanceRecorder.shared.begin(.queueProcess)
        defer { timing?.finish() }
        var ahead: (id: UUID, task: Task<UUID, Error>)?
        defer { ahead?.task.cancel() }
        while !Task.isCancelled, let current = job(id), current.status == .running {
            guard let item = current.items.first(where: { [.pending, .preparing, .ready].contains($0.status) }) else { break }
            let started = Date()
            do {
                let imageId: UUID
                if let prepared = ahead, prepared.id == item.id {
                    imageId = try await prepared.task.value; ahead = nil
                } else { imageId = try await prepareItem(id, itemId: item.id) }
                try Task.checkCancellation()
                guard job(id)?.status == .running else { break }
                mutateItem(id, item.id) { $0.status = .running }
                persistSoon()

                if let candidate = job(id)?.items.first(where: { $0.id != item.id && $0.status == .pending }),
                   AnalysisSchedulingPolicy.canPrepareAhead(currentBytes: item.estimatedBytes,
                       nextBytes: candidate.estimatedBytes, physicalMemory: physicalMemory, maxParallel: maxParallel) {
                    ahead = (candidate.id, Task { try await self.prepareItem(id, itemId: candidate.id) })
                }
                if !current.importOnly { try await analyze?(imageId, current.settings) }
                try Task.checkCancellation()
                mutateItem(id, item.id) { $0.status = .completed; $0.error = nil; $0.duration = Date().timeIntervalSince(started) }
                persistSoon()
            } catch {
                if Task.isCancelled || error is CancellationError || (error as? DetectionError).map({ if case .cancelled = $0 { return true }; return false }) == true {
                    mutateItem(id, item.id) { $0.status = $0.imageId == nil ? .pending : .ready }
                    break
                }
                mutateItem(id, item.id) { $0.status = .failed; $0.error = error.localizedDescription }
                persistSoon()
            }
        }
        // Await any already-started preparation before leaving this job. Its
        // imported source is persisted and reused after pause/restart.
        if let ahead { _ = try? await ahead.task.value }
        if let index = index(id) {
            switch jobs[index].status {
            case .pausing: jobs[index].status = .paused
            case .cancelled: break
            case .running:
                jobs[index].status = Task.isCancelled ? .paused : (jobs[index].failedCount > 0 ? .failed : .completed)
            default: break
            }
        }
        pruneFinished(); refreshDerived()
        await persistOrPause()
    }
    private func prepareItem(_ id: UUID, itemId: UUID) async throws -> UUID {
        if let existing = preparations[itemId] { return try await existing.value }
        let task = Task { try await self.prepareItemWork(id, itemId: itemId) }
        preparations[itemId] = task
        defer { preparations[itemId] = nil }
        return try await task.value
    }
    private func prepareItemWork(_ id: UUID, itemId: UUID) async throws -> UUID {
        guard let job = job(id), let item = job.items.first(where: { $0.id == itemId }), let prepare else { throw unavailableError() }
        if let imageId = item.imageId { return imageId }
        mutateItem(id, itemId) { $0.status = .preparing }
        persistSoon()
        do {
            let imageId = try await prepare(item, job.settings, job.batchId)
            mutateItem(id, itemId) { $0.imageId = imageId; $0.status = .ready; $0.error = nil }
            persistSoon()
            return imageId
        } catch {
            mutateItem(id, itemId) { $0.status = .failed; $0.error = error.localizedDescription }
            persistSoon()
            throw error
        }
    }
    private func index(_ id: UUID) -> Int? { jobs.firstIndex { $0.id == id } }
    private func mutateItem(_ id: UUID, _ itemId: UUID, _ mutation: (inout AnalysisJobItem) -> Void) {
        guard let index = index(id), let item = jobs[index].items.firstIndex(where: { $0.id == itemId }) else { return }
        mutation(&jobs[index].items[item]); jobs[index].updatedAt = Date()
        if jobs[index].items[item].imageId != nil { jobs[index].items[item].sourceBookmark = nil }
        updateLabel(jobIndex: index, itemIndex: item)
    }

    // MARK: Derived state

    private func label(_ job: AnalysisJob, _ item: AnalysisJobItem) -> String {
        if previewItemId == item.id { return "Running preview" }
        if item.status == .completed { return job.importOnly ? "Imported · ready to analyze" : "Analysis complete" }
        if item.status == .failed { return "Analysis failed · retry in Processing" }
        if job.status == .draft { return "Ready for preview" }
        return "\(job.status.title) · \(item.status.rawValue)"
    }
    private func updateLabel(jobIndex: Int, itemIndex: Int) {
        let item = jobs[jobIndex].items[itemIndex]
        guard let imageId = item.imageId else { return }
        if imageOwner[imageId] != jobs[jobIndex].id {
            // First time this image appears, or an older job still holds it.
            guard imageOwner[imageId] == nil else { return }
            imageOwner[imageId] = jobs[jobIndex].id
        }
        let text = label(jobs[jobIndex], item)
        if imageStatuses[imageId] != text { imageStatuses[imageId] = text }
    }
    /// Rebuilds the counters and the image index after a job-level change.
    /// Observable properties are only assigned when their value changes.
    private func refreshDerived() {
        let active = jobs.reduce(0) { $0 + ($1.isActive ? 1 : 0) }
        if activeCount != active { activeCount = active }
        var owner: [UUID: UUID] = [:]
        var labels: [UUID: String] = [:]
        for job in jobs {
            for item in job.items {
                guard let imageId = item.imageId else { continue }
                owner[imageId] = job.id
                labels[imageId] = label(job, item)   // later jobs win
            }
        }
        imageOwner = owner
        if imageStatuses != labels { imageStatuses = labels }
    }
    /// Keeps only the newest `maxFinishedJobs` completed jobs. Draft, queued,
    /// running, paused, cancelled and failed jobs are never pruned.
    private func pruneFinished() {
        let finished = jobs.indices.filter { jobs[$0].status == .completed && jobs[$0].id != activeJobId }
        guard finished.count > Self.maxFinishedJobs else { return }
        let drop = Set(finished.dropLast(Self.maxFinishedJobs).map { jobs[$0].id })
        jobs.removeAll { drop.contains($0.id) }
        dirty = true
    }

    // MARK: Persistence

    /// Item-level progress is written after a short quiet period; job-level
    /// changes and job boundaries write immediately (see `persist`).
    private func persistSoon() {
        dirty = true
        guard debounceTask == nil else { return }
        let delay = persistDelay
        debounceTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            self.debounceTask = nil
            if self.dirty { await self.persistOrPause() }
        }
    }
    /// Writes any pending changes now.
    func flush() async {
        guard dirty else { return }
        await persistOrPause()
    }
    private func flushForTermination() {
        guard dirty, isLoaded, persistenceError == nil else { return }
        revision &+= 1
        try? store.saveSync(jobs, revision: revision)
        dirty = false
    }
    private func persist() async throws {
        let timing = LocalPerformanceRecorder.shared.begin(.queueSave)
        var completed = false
        defer { timing?.finish(success: completed) }
        debounceTask?.cancel(); debounceTask = nil
        dirty = false
        revision &+= 1
        do { try await store.save(jobs, revision: revision); persistenceError = nil; completed = true }
        catch { dirty = true; persistenceError = error.localizedDescription; throw error }
    }
    @discardableResult private func persistOrPause() async -> Bool {
        do { try await persist(); return true }
        catch {
            for index in jobs.indices where jobs[index].isActive { jobs[index].status = .paused }
            refreshDerived()
            return false
        }
    }
    private func unavailableError() -> NSError { messageError(persistenceError ?? "The processing queue is not ready.") }
    private func messageError(_ text: String) -> NSError { NSError(domain: "AnalysisJobs", code: 1, userInfo: [NSLocalizedDescriptionKey: text]) }
}
