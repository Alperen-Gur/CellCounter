import Foundation
import Testing
@testable import CellCounting

@Suite(.serialized) @MainActor
struct AnalysisWorkflowTests {
    private func temporary() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("workflow-test-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    private func makeJob(count: Int = 3) -> AnalysisJob {
        let items = (0..<count).map { index in
            AnalysisJobItem(url: URL(fileURLWithPath: "/tmp/source-\(index).tif"), imageId: UUID())
        }
        return AnalysisJob(batchId: UUID(), title: "Test batch", settings: AnalysisRunSettings(), items: items)
    }
    private func waitUntil(_ condition: @MainActor () -> Bool) async -> Bool {
        for _ in 0..<1_000 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return condition()
    }

    @Test func interruptedJobsRecoverWithoutLosingFinishedImages() async throws {
        let directory = try temporary(); defer { try? FileManager.default.removeItem(at: directory) }
        let store = AnalysisJobStore(url: directory.appendingPathComponent("jobs.json"))
        var job = makeJob()
        job.status = .running
        job.settings.segmentChannel = 3; job.settings.backgroundSubtract = true
        job.items[0].status = .completed; job.items[0].duration = 20
        job.items[1].status = .running
        job.items[2].imageId = nil; job.items[2].status = .preparing
        try await store.save([job])
        let recovered = try #require(try await store.load().first)
        #expect(recovered.status == .paused)
        #expect(recovered.items.map(\.status) == [.completed, .ready, .pending])
        #expect(recovered.items[0].imageId == job.items[0].imageId)
        #expect(recovered.settings == job.settings)
        #expect(recovered.items[0].duration == 20)
    }

    @Test func olderSaveCannotOverwriteNewerQueueRevision() async throws {
        let directory = try temporary(); defer { try? FileManager.default.removeItem(at: directory) }
        let store = AnalysisJobStore(url: directory.appendingPathComponent("jobs.json"))
        var job = makeJob(); job.title = "Newest"
        try await store.save([job], revision: 4)
        job.title = "Stale"
        try await store.save([job], revision: 3)
        #expect(try await store.load().first?.title == "Newest")
    }

    @Test func malformedQueueIsReportedInsteadOfReplaced() async throws {
        let directory = try temporary(); defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("jobs.json")
        let damaged = Data("{\"schemaVersion\":99,\"jobs\":[]}".utf8)
        try damaged.write(to: url)
        let scheduler = AnalysisJobScheduler(store: AnalysisJobStore(url: url))
        await scheduler.restore()
        #expect(scheduler.isLoaded && scheduler.persistenceError != nil)
        await #expect(throws: (any Error).self) { try await scheduler.add(makeJob()) }
        #expect(try Data(contentsOf: url) == damaged)
    }

    @Test func pauseFinishesCurrentImageAndResumeSkipsIt() async throws {
        let directory = try temporary(); defer { try? FileManager.default.removeItem(at: directory) }
        let scheduler = AnalysisJobScheduler(store: AnalysisJobStore(url: directory.appendingPathComponent("jobs.json")))
        let job = makeJob()
        var analyzed: [UUID] = []
        scheduler.configure(prepare: { item, _, _ in try #require(item.imageId) }, analyze: { imageId, _ in
            analyzed.append(imageId)
            if analyzed.count == 1 { await scheduler.pause(job.id) }
        })
        await scheduler.restore(); try await scheduler.add(job); try await scheduler.enqueue(job.id)
        #expect(await waitUntil { scheduler.job(job.id)?.status == .paused && scheduler.activeJobId == nil })
        #expect(analyzed.count == 1)
        #expect(scheduler.job(job.id)?.completedCount == 1)
        let restarted = AnalysisJobScheduler(store: AnalysisJobStore(url: directory.appendingPathComponent("jobs.json")))
        restarted.configure(prepare: { item, _, _ in try #require(item.imageId) }, analyze: { imageId, _ in analyzed.append(imageId) })
        await restarted.restore(); try await restarted.resume(job.id)
        #expect(await waitUntil { restarted.job(job.id)?.status == .completed && restarted.activeJobId == nil })
        #expect(analyzed.count == 3 && Set(analyzed).count == 3)
    }

    @Test func retryRunsOnlyFailedImagesWithOriginalSettings() async throws {
        let directory = try temporary(); defer { try? FileManager.default.removeItem(at: directory) }
        let scheduler = AnalysisJobScheduler(store: AnalysisJobStore(url: directory.appendingPathComponent("jobs.json")))
        var job = makeJob(); job.settings.segmentChannel = 2
        let badId = try #require(job.items[1].imageId)
        var attempts: [UUID: Int] = [:]
        var observedChannels: [Int] = []
        scheduler.configure(prepare: { item, _, _ in try #require(item.imageId) }, analyze: { imageId, settings in
            attempts[imageId, default: 0] += 1; observedChannels.append(settings.segmentChannel)
            if imageId == badId && attempts[imageId] == 1 { throw NSError(domain: "Fixture", code: 1) }
        })
        await scheduler.restore(); try await scheduler.add(job)
        job.settings.segmentChannel = 9
        try await scheduler.enqueue(job.id)
        #expect(await waitUntil { scheduler.job(job.id)?.status == .failed && scheduler.activeJobId == nil })
        #expect(scheduler.job(job.id)?.completedCount == 2)
        try await scheduler.retryFailures(job.id)
        #expect(await waitUntil { scheduler.job(job.id)?.status == .completed && scheduler.activeJobId == nil })
        #expect(attempts[badId] == 2)
        #expect(attempts.values.reduce(0, +) == 4)
        #expect(observedChannels == [2, 2, 2, 2])
    }

    @Test func previewIsReusedUntilAnalysisInputsChange() async throws {
        let directory = try temporary(); defer { try? FileManager.default.removeItem(at: directory) }
        let scheduler = AnalysisJobScheduler(store: AnalysisJobStore(url: directory.appendingPathComponent("jobs.json")))
        let job = makeJob(count: 2)
        var runs = 0
        scheduler.configure(prepare: { item, _, _ in try #require(item.imageId) }, analyze: { _, _ in runs += 1 })
        await scheduler.restore(); try await scheduler.add(job)
        try await scheduler.preview(job.id, itemId: job.items[0].id)
        #expect(runs == 1)
        try await scheduler.enqueue(job.id)
        #expect(await waitUntil { scheduler.job(job.id)?.status == .completed && scheduler.activeJobId == nil })
        #expect(runs == 2)
        var changed = job.settings; changed.zProjection = "mean"
        try await scheduler.updateDraft(job.id, settings: changed, preset: .countCells)
        #expect(scheduler.job(job.id)?.completedCount == 0)
        try await scheduler.enqueue(job.id)
        #expect(await waitUntil { scheduler.job(job.id)?.status == .completed && scheduler.activeJobId == nil })
        #expect(runs == 4)
    }

    @Test func simultaneousSampleRequestsShareImportAndNeedNoDetector() async throws {
        let directory = try temporary(); defer { try? FileManager.default.removeItem(at: directory) }
        let scheduler = AnalysisJobScheduler(store: AnalysisJobStore(url: directory.appendingPathComponent("jobs.json")))
        var job = makeJob(count: 1); job.items[0].imageId = nil; job.items[0].status = .pending
        var imports = 0; var runs = 0
        scheduler.configure(prepare: { _, _, _ in
            imports += 1
            try await Task.sleep(for: .milliseconds(20))
            return UUID()
        }, analyze: { _, _ in runs += 1 })
        await scheduler.restore(); try await scheduler.add(job)
        async let first = scheduler.prepareSample(job.id, itemId: job.items[0].id)
        async let second = scheduler.prepareSample(job.id, itemId: job.items[0].id)
        let ids = try await [first, second]
        #expect(ids[0] == ids[1] && imports == 1 && runs == 0)
        try await scheduler.enqueue(job.id, importOnly: true)
        #expect(await waitUntil { scheduler.job(job.id)?.status == .completed && scheduler.activeJobId == nil })
        #expect(runs == 0)
        try await scheduler.enqueue(job.id)
        #expect(await waitUntil { scheduler.job(job.id)?.status == .completed && scheduler.activeJobId == nil })
        #expect(runs == 1)
    }

    @Test func cancellingPreviewReleasesQueueAndLeavesImageRetryable() async throws {
        let directory = try temporary(); defer { try? FileManager.default.removeItem(at: directory) }
        let scheduler = AnalysisJobScheduler(store: AnalysisJobStore(url: directory.appendingPathComponent("jobs.json")))
        let job = makeJob(count: 1)
        var started = false
        scheduler.configure(prepare: { item, _, _ in try #require(item.imageId) }, analyze: { _, _ in
            started = true; try await Task.sleep(for: .seconds(20))
        })
        await scheduler.restore(); try await scheduler.add(job)
        let preview = Task { try await scheduler.preview(job.id, itemId: job.items[0].id) }
        #expect(await waitUntil { started })
        scheduler.cancelPreview()
        do { try await preview.value; Issue.record("Cancelled preview unexpectedly completed") } catch { }
        #expect(scheduler.previewItemId == nil)
        #expect(scheduler.job(job.id)?.items[0].status == .ready)
    }

    @Test func preparationBudgetRejectsUnknownHugeAndOverflowingImages() {
        let memory: UInt64 = 8 * 1_024 * 1_024 * 1_024
        #expect(AnalysisSchedulingPolicy.canPrepareAhead(currentBytes: 1_000_000, nextBytes: 1_000_000, physicalMemory: memory, maxParallel: 4))
        for bytes: Int64 in [0, -1, 1_000_000_000, Int64.max] {
            #expect(!AnalysisSchedulingPolicy.canPrepareAhead(currentBytes: bytes, nextBytes: bytes, physicalMemory: memory, maxParallel: 4))
        }
        #expect(!AnalysisSchedulingPolicy.canPrepareAhead(currentBytes: 1, nextBytes: 1, physicalMemory: memory, maxParallel: 1))
        #expect(AnalysisSchedulingPolicy.preparationBudget(physicalMemory: UInt64.max) <= 512 * 1_024 * 1_024)
    }

    @Test func runSettingsPreservePlanesAndVendorSourceAcrossCatalogFamilies() {
        let image = ImageRecord(fileName: "source.nd2", originalPath: "/source.nd2", widthPx: 10, heightPx: 20)
        for family in [ModelFamily.cellpose, .cellpose4, .classical, .omnipose, .custom] {
            var settings = AnalysisRunSettings(); settings.modelFamily = family.rawValue
            settings.segmentChannel = 2; settings.zProjection = "mean"; settings.expectedDiameterUm = 13
            #expect(settings.sourceURL(for: image) == image.storedURL)
            let input = settings.detectionInput(imageURL: settings.sourceURL(for: image))
            #expect(input.segmentChannel == 2 && input.zProjection == "mean" && input.expectedDiameterUm == 13)
        }
        var legacy = AnalysisRunSettings(); legacy.modelFamily = ModelFamily.stardist.rawValue
        #expect(legacy.sourceURL(for: image) == image.displayURL)
        #expect(AnalysisTaskPreset.countNuclei.applying(to: AnalysisRunSettings()).modelFamily == ModelFamily.cellpose.rawValue)
        #expect(AnalysisTaskPreset.markerPositive.resultsWorkspace == "measurements")
        #expect(AnalysisTaskPreset.woundClosure.resultsWorkspace == "assays")
    }

    @Test func variantRestoresRunProvenanceAndUsesCurrentMeasurementScale() throws {
        let repos = Repositories(inMemory: true)
        let batch = repos.createBatch(displayName: "Provenance", modelId: "cp-nuclei", pxPerUm: 2, thresholds: [20, 30])
        let image = ImageRecord(fileName: "source.tif", originalPath: "/source.tif", widthPx: 20, heightPx: 20)
        repos.attach(image: image, to: batch)
        var original = AnalysisRunSettings(); original.modelId = "cp-nuclei"; original.pxPerUm = 2; original.backgroundSubtract = true
        original.detectorVersion = "recorded-version"
        repos.saveDetection([DetectedCell(cx: 10, cy: 10, diameter: 5, diameterPx: 10)], detectorId: "Cellpose/cp-nuclei", for: image, imageStats: ["marker": 15], runSettings: original)
        let variant = repos.saveSegmentationVariant(image: image, detectorId: "Cellpose/cp-nuclei", label: "Original", cells: try #require(image.detection).cells)
        let ranAt = image.detection?.ranAt
        batch.pxPerUm = 5
        repos.saveDetection([], detectorId: "Classical/new", for: image, imageStats: ["marker": 99], runSettings: AnalysisRunSettings())
        _ = repos.applySegmentationVariant(variant, to: image)
        #expect(image.detection?.cells.first?.diameter == 2)
        #expect(image.detection?.runSettings == original)
        #expect(image.detection?.imageStats["marker"] == 15)
        #expect(image.detection?.ranAt == ranAt)
        let state = AppState(repos: repos)
        let metadata = ProvenanceMetadata.capture(for: image, state: state)
        #expect(metadata.modelId == "cp-nuclei" && metadata.backgroundSubtract)
        #expect(metadata.detectorVersion == "recorded-version")
        #expect(metadata.originalRunSettings?.pxPerUm == 2 && metadata.pxPerUm == 5)
    }

    @Test func legacyRunMetadataRemainsUnknownAndInputComparisonIgnoresRuntimeMetadata() {
        let repos = Repositories(inMemory: true)
        let image = ImageRecord(fileName: "old.tif", originalPath: "/old.tif", widthPx: 20, heightPx: 20)
        image.detection = DetectionRecord(detectorId: "SavedDetector/saved-model", cells: [])
        let metadata = ProvenanceMetadata.capture(for: image, state: AppState(repos: repos))
        #expect(metadata.modelId == "saved-model")
        #expect(metadata.analysisSettingsSource == "legacy-unknown")
        #expect(metadata.detectorVersion == nil && metadata.weightsHash == nil)
        let input = AnalysisRunSettings()
        var recorded = input; recorded.detectorVersion = "v3"; recorded.weightsSHA256 = "abc"
        #expect(recorded.hasSameInputs(as: input))
        recorded.segmentChannel = 1
        #expect(!recorded.hasSameInputs(as: input))
    }

    @Test func checkpointHashWarmsOffMainAndRejectsReplacedWeights() async throws {
        let directory = try temporary(); defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("weights.ccmodel")
        try Data(repeating: 41, count: 1_048_576).write(to: url, options: .atomic)
        let cache = WeightsHashCache()
        #expect(cache.hashIfCheap(at: url) == nil)
        #expect(await waitUntil { cache.hashIfCheap(at: url) != nil })
        let original = try #require(cache.hashIfCheap(at: url))
        try Data(repeating: 42, count: 1_048_576).write(to: url, options: .atomic)
        // Even equal-sized replacement weights must not inherit the old
        // digest while their new background hash is still pending.
        #expect(cache.hashIfCheap(at: url) == nil)
        #expect(await waitUntil { cache.hashIfCheap(at: url) != nil })
        let replaced = try #require(cache.hashIfCheap(at: url))
        #expect(replaced != original)
        try FileManager.default.removeItem(at: url)
        #expect(cache.hashIfCheap(at: url) == nil)
    }

    @Test func repeatedCalibrationIsIdempotentForMixedOldAndNewMeasurements() {
        let old = DetectedCell(cx: 10, cy: 20, diameter: 5, diameterPx: 10,
                               areaMicrons2: 25, perimeterMicrons: 20)
        let current = DetectedCell(cx: 15, cy: 25, diameter: 2, diameterPx: 10,
                                   areaMicrons2: 4, perimeterMicrons: 8)
        let converted = AppState.calibratedCells([old, current], pxPerUm: 5, fallbackScale: 2)
        #expect(converted.map(\.diameter) == [2, 2])
        #expect(converted.map(\.areaMicrons2) == [4, 4])
        #expect(converted.map(\.perimeterMicrons) == [8, 8])
        #expect(AppState.calibratedCells(converted, pxPerUm: 5, fallbackScale: 2) == converted)
    }

    @Test func calibrationPreservesEditsAndSerializesOverlappingRequests() async throws {
        let repos = Repositories(inMemory: true)
        let batch = repos.createBatch(displayName: "Calibration", modelId: "test", pxPerUm: 2, thresholds: [20, 30])
        let image = ImageRecord(fileName: "cells.tif", originalPath: "/cells.tif", widthPx: 1000, heightPx: 1000)
        repos.attach(image: image, to: batch)
        var cells: [DetectedCell] = []
        for index in 0..<12_000 {
            cells.append(DetectedCell(cx: Double(index % 100), cy: Double(index / 100),
                                      diameter: 5, diameterPx: 10, areaMicrons2: 25, perimeterMicrons: 20))
        }
        repos.saveDetection(cells, detectorId: "test", for: image)
        let state = AppState(repos: repos)
        let first = Task { try await state.recalibrateBatch(batch, pxPerUm: 5, source: "manual") }
        await Task.yield()
        await Task.yield()
        var edited = try #require(image.detection).cells
        edited[0].cx = 999
        image.detection?.cells = edited
        let second = Task { try await state.recalibrateBatch(batch, pxPerUm: 10, source: "manual") }
        try await first.value; try await second.value
        #expect(batch.pxPerUm == 10)
        #expect(image.detection?.cells.first?.cx == 999)
        #expect(image.detection?.cells.first?.diameter == 1)
        #expect(image.detection?.cells.first?.areaMicrons2 == 1)
        #expect(image.detection?.cells.first?.perimeterMicrons == 4)
    }
}
