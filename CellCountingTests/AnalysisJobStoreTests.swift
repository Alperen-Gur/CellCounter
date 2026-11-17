import Foundation
import Testing
@testable import CellCounting

@Suite(.serialized) @MainActor
struct AnalysisJobStoreTests {
    private func temporary() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("job-store-test-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    private func makeJob(count: Int = 3, status: AnalysisJobStatus = .draft) -> AnalysisJob {
        let items = (0..<count).map { AnalysisJobItem(url: URL(fileURLWithPath: "/tmp/store-source-\($0).tif"), imageId: UUID()) }
        var job = AnalysisJob(batchId: UUID(), title: "Job", settings: AnalysisRunSettings(), items: items)
        job.status = status
        return job
    }
    private func waitUntil(_ condition: @MainActor () -> Bool) async -> Bool {
        for _ in 0..<1_000 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return condition()
    }
    private func reference(_ jobs: [AnalysisJob], _ scheduler: AnalysisJobScheduler, imageId: UUID) -> String? {
        for job in jobs.reversed() {
            if let item = job.items.first(where: { $0.imageId == imageId }) {
                if item.status == .completed { return job.importOnly ? "Imported · ready to analyze" : "Analysis complete" }
                if item.status == .failed { return "Analysis failed · retry in Processing" }
                if job.status == .draft { return "Ready for preview" }
                return "\(job.status.title) · \(item.status.rawValue)"
            }
        }
        return nil
    }

    @Test func debouncedWritesPersistOnFlush() async throws {
        let directory = try temporary(); defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("jobs.json")
        let scheduler = AnalysisJobScheduler(store: AnalysisJobStore(url: url))
        scheduler.persistDelay = .seconds(60)
        let job = makeJob()
        var analyzed = 0
        scheduler.configure(prepare: { item, _, _ in try #require(item.imageId) }, analyze: { _, _ in analyzed += 1 })
        await scheduler.restore(); try await scheduler.add(job); try await scheduler.enqueue(job.id)
        #expect(await waitUntil { scheduler.job(job.id)?.status == .completed && scheduler.activeJobId == nil })
        await scheduler.flush()
        let saved = try #require(try await AnalysisJobStore(url: url).load().first)
        #expect(saved.status == .completed)
        #expect(saved.items.allSatisfy { $0.status == .completed })
    }

    @Test func itemProgressIsNotWrittenUntilDebounceOrFlush() async throws {
        let directory = try temporary(); defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("jobs.json")
        let scheduler = AnalysisJobScheduler(store: AnalysisJobStore(url: url))
        scheduler.persistDelay = .seconds(60)
        var job = makeJob(count: 2)
        job.items[0].imageId = nil; job.items[0].status = .pending
        let imported = UUID()
        scheduler.configure(prepare: { _, _, _ in imported }, analyze: { _, _ in })
        await scheduler.restore(); try await scheduler.add(job)
        _ = try await scheduler.prepareSample(job.id, itemId: job.items[0].id)
        let onDisk = try #require(try await AnalysisJobStore(url: url).load().first)
        #expect(onDisk.items[0].imageId == nil)
        await scheduler.flush()
        let flushed = try #require(try await AnalysisJobStore(url: url).load().first)
        #expect(flushed.items[0].imageId == imported && flushed.items[0].sourceBookmark == nil)
    }

    @Test func inFlightJobRecoversAfterRestart() async throws {
        let directory = try temporary(); defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("jobs.json")
        let scheduler = AnalysisJobScheduler(store: AnalysisJobStore(url: url))
        scheduler.persistDelay = .seconds(60)
        let job = makeJob()
        var analyzed: [UUID] = []
        var restarted: AnalysisJobScheduler?
        scheduler.configure(prepare: { item, _, _ in try #require(item.imageId) }, analyze: { imageId, _ in
            analyzed.append(imageId)
            if analyzed.count == 2 {
                // Simulate the process dying mid-job: only the debounced state is lost.
                await scheduler.flush()
            }
        })
        await scheduler.restore(); try await scheduler.add(job); try await scheduler.enqueue(job.id)
        #expect(await waitUntil { analyzed.count >= 2 })
        let snapshot = try #require(try await AnalysisJobStore(url: url).load().first)
        #expect(snapshot.status == .paused)
        #expect(snapshot.items.map(\.status).contains(.ready) || snapshot.items.map(\.status).contains(.completed))
        #expect(!snapshot.items.contains { [.running, .preparing].contains($0.status) })
        #expect(await waitUntil { scheduler.job(job.id)?.status == .completed })
        let next = AnalysisJobScheduler(store: AnalysisJobStore(url: url))
        restarted = next
        var again: [UUID] = []
        next.configure(prepare: { item, _, _ in try #require(item.imageId) }, analyze: { imageId, _ in again.append(imageId) })
        await next.restore()
        #expect(next.job(job.id)?.status != .running)
        try await next.resume(job.id)
        #expect(await waitUntil { next.job(job.id)?.status == .completed && next.activeJobId == nil })
        #expect(Set(analyzed + again) == Set(job.items.compactMap(\.imageId)))
        _ = restarted
    }

    @Test func pruningKeepsActiveAndFailedJobs() async throws {
        let directory = try temporary(); defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("jobs.json")
        var jobs: [AnalysisJob] = []
        let failed = makeJob(status: .failed); jobs.append(failed)
        let paused = makeJob(status: .paused); jobs.append(paused)
        for _ in 0..<(AnalysisJobScheduler.maxFinishedJobs + 7) { jobs.append(makeJob(count: 1, status: .completed)) }
        let queued = makeJob(status: .queued); jobs.append(queued)
        try await AnalysisJobStore(url: url).save(jobs)
        let scheduler = AnalysisJobScheduler(store: AnalysisJobStore(url: url))
        await scheduler.restore()
        let ids = Set(scheduler.jobs.map(\.id))
        #expect(ids.contains(failed.id) && ids.contains(paused.id) && ids.contains(queued.id))
        #expect(scheduler.jobs.filter { $0.status == .completed }.count == AnalysisJobScheduler.maxFinishedJobs)
        // The newest finished jobs survive.
        let newest = jobs.filter { $0.status == .completed }.suffix(AnalysisJobScheduler.maxFinishedJobs).map(\.id)
        #expect(Set(newest).isSubset(of: ids))
    }

    @Test func indexAndActiveCountMatchFullScan() async throws {
        let directory = try temporary(); defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("jobs.json")
        let scheduler = AnalysisJobScheduler(store: AnalysisJobStore(url: url))
        scheduler.persistDelay = .seconds(60)
        var bad: UUID?
        scheduler.configure(prepare: { item, _, _ in try #require(item.imageId) }, analyze: { imageId, _ in
            if imageId == bad { throw NSError(domain: "Fixture", code: 1) }
        })
        let first = makeJob(); let second = makeJob(count: 2)
        bad = second.items[1].imageId
        await scheduler.restore(); try await scheduler.add(first); try await scheduler.add(second)
        func check() {
            let ids = (first.items + second.items).compactMap(\.imageId) + [UUID()]
            for id in ids { #expect(scheduler.statusLabel(for: id) == reference(scheduler.jobs, scheduler, imageId: id)) }
            #expect(scheduler.activeCount == scheduler.jobs.filter(\.isActive).count)
        }
        check()
        try await scheduler.enqueue(first.id)
        #expect(await waitUntil { scheduler.job(first.id)?.status == .completed && scheduler.activeJobId == nil })
        check()
        try await scheduler.enqueue(second.id)
        #expect(await waitUntil { scheduler.job(second.id)?.status == .failed && scheduler.activeJobId == nil })
        check()
        #expect(scheduler.activeCount == 0)
    }

    @Test func importedItemsDropBookmarksButPendingKeepThem() async throws {
        let directory = try temporary(); defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("src.png"); try Data([0]).write(to: source)
        var pending = AnalysisJobItem(url: source)
        #expect(pending.sourceBookmark != nil)
        let imported = AnalysisJobItem(url: source, imageId: UUID())
        #expect(imported.sourceBookmark == nil)
        pending.imageId = UUID()
        var job = AnalysisJob(batchId: UUID(), title: "B", settings: AnalysisRunSettings(), items: [pending])
        job.dropImportedBookmarks()
        #expect(job.items[0].sourceBookmark == nil)
    }

    @Test func fileWrittenByPreviousVersionStillLoads() async throws {
        let directory = try temporary(); defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("jobs.json")
        // Previous versions wrote every item with its bookmark and kept all history.
        var job = makeJob(status: .running)
        job.items[0].sourceBookmark = Data([1, 2, 3])
        struct Legacy: Codable { var schemaVersion = 1; var jobs: [AnalysisJob] }
        try JSONEncoder().encode(Legacy(jobs: [job])).write(to: url)
        let scheduler = AnalysisJobScheduler(store: AnalysisJobStore(url: url))
        await scheduler.restore()
        #expect(scheduler.persistenceError == nil)
        let loaded = try #require(scheduler.jobs.first)
        #expect(loaded.id == job.id && loaded.status == .paused)
        #expect(loaded.items.count == 3 && loaded.items[0].sourceBookmark == nil)
        #expect(scheduler.statusLabel(for: try #require(job.items[0].imageId)) == "Paused · pending")
    }
}
