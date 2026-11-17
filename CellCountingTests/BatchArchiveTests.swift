import CoreGraphics
import Foundation
import SwiftData
import Testing
@testable import CellCounting

/// Archive moves a batch into its own library folder and restore copies it
/// back. Every test uses its own SQLite library in a temporary folder; image
/// files live under the test data root (`FileStore.location()`), never in the
/// user's real library.
@Suite(.serialized)
@MainActor
struct BatchArchiveTests {
    private struct Library {
        let root: URL
        let liveFolder: URL
        let repos: Repositories
        let batchId: UUID
        let runSettings: AnalysisRunSettings
        /// Library-owned files of the fixture batch with their original bytes.
        let files: [URL: Data]

        var archiveURL: URL {
            root.appendingPathComponent("Archives", isDirectory: true)
                .appendingPathComponent("Plate B12 – archived.cellcounterlibrary", isDirectory: true)
        }

        func cleanUp() {
            try? FileManager.default.removeItem(at: root)
            for url in files.keys { try? FileManager.default.removeItem(at: url) }
        }
    }

    private static let pxPerUm = 3.0769

    private func makeLibrary() throws -> Library {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("BatchArchiveTests-\(UUID().uuidString)", isDirectory: true)
        let live = root.appendingPathComponent("live", isDirectory: true)
        try fm.createDirectory(at: live, withIntermediateDirectories: true)
        let schema = Repositories.librarySchema()
        let configuration = ModelConfiguration("CellCounter", schema: schema,
                                               url: live.appendingPathComponent("store.sqlite"))
        let repos = Repositories(container: try ModelContainer(for: schema, configurations: [configuration]))

        if !repos.conditions().contains(where: { $0.name == "Treated" }) {
            repos.createCondition(name: "Treated", color: "#aa5500")
        }
        let batch = repos.createBatch(displayName: "Keratinocytes plate B12", modelId: "cp-cyto3",
                                      pxPerUm: Self.pxPerUm, thresholds: [18, 26], condition: "Treated")
        batch.pxPerUmSource = "exif-tiff"

        var settings = AnalysisRunSettings()
        settings.modelId = "cp-cyto3"
        settings.pxPerUm = Self.pxPerUm
        settings.calibrationSource = "exif-tiff"
        settings.confidence = 0.45
        settings.thresholds = [18, 26]
        settings.backgroundSubtract = true
        settings.detectorVersion = "cellpose 3.1.1"

        var files: [URL: Data] = [:]
        func write(_ data: Data, to url: URL) throws {
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
            files[url] = data
        }
        func bytes(_ count: Int, seed: UInt8) -> Data {
            Data((0..<count).map { UInt8(truncatingIfNeeded: $0 &* 31) ^ seed })
        }
        func cells(_ count: Int, offset: Double) -> [DetectedCell] {
            (0..<count).map { index in
                let x = offset + Double(index) * 25
                let contour = (0..<12).map { point in
                    CGPoint(x: x + 6 * cos(Double(point) / 2), y: 40 + 6 * sin(Double(point) / 2))
                }
                return DetectedCell(cx: x, cy: 40, diameter: 12 / Self.pxPerUm * 3, diameterPx: 12 * 3,
                                    confidence: index.isMultiple(of: 2) ? 0.9 : 0.3,
                                    areaMicrons2: 110, perimeterMicrons: 38, circularity: 0.91,
                                    centroidUmX: x / Self.pxPerUm, centroidUmY: 40 / Self.pxPerUm,
                                    sizeClass: "intermediate", contourPx: contour)
            }
        }

        let base = Date(timeIntervalSinceReferenceDate: 800_000_000.25)
        let names = ["field-01.tif", "field-02.czi", "field-03.TIF"]
        for (index, name) in names.enumerated() {
            let image = ImageRecord(fileName: name, originalPath: "/Volumes/Scope/B12/\(name)",
                                    widthPx: 512, heightPx: 384)
            image.importedAt = base.addingTimeInterval(Double(index))
            image.sourceOrder = index
            image.jobItemId = UUID()
            repos.context.insert(image)
            repos.attach(image: image, to: batch, save: false)

            try write(bytes(4096 + index * 1000, seed: UInt8(index + 1)), to: image.storedURL)
            if index == 0 {
                image.fileHash = ImageLoader.sha256Hex(of: image.storedURL)
                image.sourcePxPerUm = 2.5
                image.sourceCalibrationSource = "exif-tiff"
                image.notes = "donor 7, passage 3"
                image.confidenceOverride = 0.4
            }
            if index == 1 {
                // Vendor container: the viewer uses a separate display PNG.
                try write(bytes(900, seed: 99), to: image.displayURL)
            }
            if index != 2 {
                try write(bytes(300, seed: UInt8(50 + index)), to: image.thumbURL)
                repos.saveSegmentationVariant(image: image, detectorId: "Classical/threshold",
                                              label: "Before cp-cyto3", cells: cells(2, offset: 200), save: false)
                repos.saveDetection(cells(6, offset: 20), detectorId: "Cellpose/cp-cyto3", for: image,
                                    imageStats: ["focus_score": 0.8, "confluency_pct": 41.5],
                                    runSettings: settings, save: false)
            }
            try repos.context.save()
            if index == 0, let detection = image.detection {
                var edited = detection.cells
                let rejected = edited.remove(at: 1)
                _ = repos.commitCellEdit(cells: edited,
                                         corrections: [CorrectionSpec(kind: "remove", cell: rejected),
                                                       CorrectionSpec(kind: "accept", cell: edited[0])],
                                         detection: detection, image: image)
                repos.save(ROIRecord(imageId: image.id, kind: "include", shape: "ellipse",
                                     x: 10, y: 12, width: 300, height: 200, name: "centre"), on: image)
                repos.addAnnotation(GroundTruthAnnotation(imageId: image.id, cx: 45, cy: 40,
                                                          diameter: 11, note: "obvious cell"))
            }
        }
        try repos.context.save()
        return Library(root: root, liveFolder: live.standardizedFileURL, repos: repos, batchId: batch.id,
                       runSettings: settings, files: files)
    }

    private func snapshot(_ batchId: UUID, in container: ModelContainer) async throws -> BatchRecordsSnapshot {
        let context = ModelContext(container)
        let batch = try #require(try context.fetch(FetchDescriptor<BatchRecord>(
            predicate: #Predicate { $0.id == batchId })).first)
        return try await BatchRecordsSnapshotter.snapshot(batch: batch, in: context)
    }

    private func readOnlyContainer(_ store: URL) throws -> ModelContainer {
        let schema = Repositories.librarySchema()
        return try ModelContainer(for: schema, configurations: [
            ModelConfiguration("CellCounter", schema: schema, url: store, allowsSave: false)])
    }

    /// Relative path → contents for every file in a folder except the SQLite
    /// store, whose page layout SQLite may rewrite when a connection closes.
    /// The store is compared by content with `snapshot(_:in:)` instead.
    private func tree(_ folder: URL) throws -> [String: Data] {
        var out: [String: Data] = [:]
        let enumerator = try #require(FileManager.default.enumerator(
            at: folder, includingPropertiesForKeys: [.isRegularFileKey]))
        for case let url as URL in enumerator
        where (try url.resourceValues(forKeys: [.isRegularFileKey])).isRegularFile == true
            && !url.lastPathComponent.hasPrefix(LibraryLayout.storeFileName) {
            let root = folder.resolvingSymlinksInPath().path
            let path = url.resolvingSymlinksInPath().path
            out[String(path.dropFirst(root.count + 1))] = try Data(contentsOf: url)
        }
        return out
    }

    // MARK: - Archive

    @Test func archiveRoundTripKeepsRecordsSettingsCalibrationAndFiles() async throws {
        let library = try makeLibrary()
        defer { library.cleanUp() }
        let original = try await snapshot(library.batchId, in: library.repos.container)
        #expect(original.images.count == 3)
        #expect(original.detectionCount == 2)
        #expect(original.correctionCount == 2 && original.roiCount == 1 && original.annotationCount == 1)
        #expect(original.reviewCandidateCount > 0 && original.variantCount >= 2)
        let expectedCells = BatchArchiveService.storedCellCount(original)
        #expect(expectedCells == 11)

        let service = BatchArchiveService(repos: library.repos)
        let result = try await service.archive(batchId: library.batchId, to: library.archiveURL)
        let layout = LibraryLayout(root: library.archiveURL)
        #expect(result.archiveURL == layout.root)

        // Manifest
        let manifest = try #require(layout.readManifest())
        #expect(manifest.kind == .batchArchive)
        let info = try #require(manifest.archivedBatch)
        #expect(info.batchId == library.batchId)
        #expect(info.displayName == "Keratinocytes plate B12")
        #expect(info.condition == "Treated")
        #expect(info.modelId == "cp-cyto3")
        #expect(info.pxPerUm == Self.pxPerUm)
        #expect(info.pxPerUmSource == "exif-tiff")
        #expect(info.imageCount == 3)
        #expect(info.cellCount == expectedCells)
        #expect(info.sourceLibraryPath == library.liveFolder.path)

        // Records: every stored field of every row, reopened from disk.
        let container = try readOnlyContainer(layout.storeURL)
        let archived = try await snapshot(library.batchId, in: container)
        #expect(archived == original)
        #expect(archived.batch.pxPerUm == Self.pxPerUm)
        let detection = try #require(archived.images[0].detection)
        let settings = try JSONDecoder().decode(AnalysisRunSettings.self, from: try #require(detection.runSettingsData))
        #expect(settings == library.runSettings)
        #expect(DetectionRecord.decodeCellsData(detection.cellsData).allSatisfy { ($0.contourPx?.count ?? 0) == 12 })
        let context = ModelContext(container)
        #expect(try context.fetchCount(FetchDescriptor<BatchRecord>()) == 1)
        #expect(try context.fetchCount(FetchDescriptor<CalibrationPresetRecord>()) == library.repos.calibrationPresets().count)
        #expect(try context.fetchCount(FetchDescriptor<BinPresetRecord>()) == library.repos.binPresets().count)

        // Files: same bytes under the archive's own Images/DisplayImages/Thumbnails.
        for image in original.images {
            let stored = try Data(contentsOf: layout.imageURL(for: image.id, extension: image.storedExtension))
            #expect(library.files.values.contains(stored))
        }
        let vendor = original.images[1]
        #expect(FileManager.default.fileExists(atPath: layout.displayImageURL(for: vendor.id).path))
        #expect(FileManager.default.fileExists(atPath: layout.thumbURL(for: original.images[0].id).path))
        #expect(!FileManager.default.fileExists(atPath: layout.thumbURL(for: original.images[2].id).path))

        // Human-readable exports reuse the app's own writers.
        let exports = layout.exportsDir
        let cellFiles = try FileManager.default.contentsOfDirectory(atPath: exports.appendingPathComponent("cells").path)
        #expect(Set(cellFiles) == ["field-01.csv", "field-02.csv"])
        let cellsCSV = try String(contentsOf: exports.appendingPathComponent("cells/field-01.csv"), encoding: .utf8)
        #expect(cellsCSV.contains("pxPerUm=3.0769"))
        let summary = try String(contentsOf: exports.appendingPathComponent("per-image-summary.csv"), encoding: .utf8)
        #expect(summary.split(separator: "\n").filter { !$0.hasPrefix("#") }.count == 4)
        let index = try String(contentsOf: exports.appendingPathComponent("images.csv"), encoding: .utf8)
        #expect(index.contains("field-03.TIF") && index.contains("donor 7, passage 3"))
        #expect(FileManager.default.fileExists(atPath: exports.appendingPathComponent("provenance.json").path))
        let readme = try String(contentsOf: layout.root.appendingPathComponent("README.txt"), encoding: .utf8)
        #expect(readme.contains("3.0769 px/µm"))
        #expect(readme.contains("exif-tiff"))
        #expect(readme.contains("Restore Archived Batch"))

        // The live library no longer holds the batch or its files.
        #expect(library.repos.batch(id: library.batchId) == nil)
        for image in original.images {
            #expect(library.repos.image(id: image.id) == nil)
        }
        for url in library.files.keys {
            #expect(!FileManager.default.fileExists(atPath: url.path))
        }
    }

    @Test func sourceIsRemovedOnlyAfterTheArchiveIsVerified() async throws {
        let library = try makeLibrary()
        defer { library.cleanUp() }
        let service = BatchArchiveService(repos: library.repos)
        var phases: [BatchArchiveService.Phase] = []
        service.onProgress = { phases.append($0.phase) }
        var presentBeforeVerification = false
        var filesPresentBeforeVerification = false
        service.beforeVerification = { _ in
            presentBeforeVerification = library.repos.batch(id: library.batchId) != nil
            filesPresentBeforeVerification = library.files.keys.allSatisfy {
                FileManager.default.fileExists(atPath: $0.path)
            }
        }
        _ = try await service.archive(batchId: library.batchId, to: library.archiveURL)
        #expect(presentBeforeVerification)
        #expect(filesPresentBeforeVerification)
        let lastVerify = try #require(phases.lastIndex(of: .verifying))
        let firstRemoval = try #require(phases.firstIndex(of: .removingFromLibrary))
        #expect(lastVerify < firstRemoval)
        #expect(library.repos.batch(id: library.batchId) == nil)
    }

    @Test func failedVerificationLeavesTheLibraryIntactAndNoPartialArchive() async throws {
        let library = try makeLibrary()
        defer { library.cleanUp() }
        let original = try await snapshot(library.batchId, in: library.repos.container)
        let damaged = original.images[0]
        let service = BatchArchiveService(repos: library.repos)
        service.beforeVerification = { layout in
            // Simulate a bad copy: the archived image has the wrong bytes.
            try Data("damaged".utf8).write(to: layout.imageURL(for: damaged.id, extension: damaged.storedExtension))
        }
        do {
            _ = try await service.archive(batchId: library.batchId, to: library.archiveURL)
            Issue.record("A damaged archive must not be accepted")
        } catch BatchArchiveError.verificationFailed {
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
        #expect(!FileManager.default.fileExists(atPath: library.archiveURL.path))
        #expect(try await snapshot(library.batchId, in: library.repos.container) == original)
        for (url, data) in library.files {
            #expect((try? Data(contentsOf: url)) == data)
        }
    }

    @Test func missingSourceFileOrCancellationLeavesEverythingUnchanged() async throws {
        let library = try makeLibrary()
        defer { library.cleanUp() }
        let original = try await snapshot(library.batchId, in: library.repos.container)

        // Cancellation just before verification removes the partial archive.
        let cancelling = BatchArchiveService(repos: library.repos)
        cancelling.beforeVerification = { _ in throw CancellationError() }
        await #expect(throws: CancellationError.self) {
            try await cancelling.archive(batchId: library.batchId, to: library.archiveURL)
        }
        #expect(!FileManager.default.fileExists(atPath: library.archiveURL.path))
        #expect(try await snapshot(library.batchId, in: library.repos.container) == original)

        // An existing folder is never replaced or removed.
        try FileManager.default.createDirectory(at: library.archiveURL, withIntermediateDirectories: true)
        let marker = library.archiveURL.appendingPathComponent("keep.txt")
        try Data("mine".utf8).write(to: marker)
        await #expect(throws: BatchArchiveError.destinationExists(library.archiveURL.lastPathComponent)) {
            try await BatchArchiveService(repos: library.repos).archive(batchId: library.batchId, to: library.archiveURL)
        }
        #expect(FileManager.default.fileExists(atPath: marker.path))
        try FileManager.default.removeItem(at: library.archiveURL)

        // A library image that is already missing blocks the archive.
        let stored = try #require(library.files.keys.first { $0.lastPathComponent.hasPrefix(original.images[2].id.uuidString) })
        try FileManager.default.removeItem(at: stored)
        await #expect(throws: BatchArchiveError.sourceFileMissing(image: "field-03.TIF")) {
            try await BatchArchiveService(repos: library.repos).archive(batchId: library.batchId, to: library.archiveURL)
        }
        #expect(!FileManager.default.fileExists(atPath: library.archiveURL.path))
        #expect(try await snapshot(library.batchId, in: library.repos.container) == original)
    }

    // MARK: - Restore

    @Test func restoreRoundTripEqualsTheOriginalAndLeavesTheArchiveUnchanged() async throws {
        let library = try makeLibrary()
        defer { library.cleanUp() }
        let original = try await snapshot(library.batchId, in: library.repos.container)
        let service = BatchArchiveService(repos: library.repos)
        _ = try await service.archive(batchId: library.batchId, to: library.archiveURL)
        #expect(library.repos.batch(id: library.batchId) == nil)
        let archiveStore = LibraryLayout(root: library.archiveURL).storeURL
        let archiveBefore = try tree(library.archiveURL)
        #expect(archiveBefore.keys.contains("CellCounterLibrary.json"))
        #expect(archiveBefore.keys.contains { $0.hasPrefix("Images/") })

        let result = try await service.restore(from: library.archiveURL)
        #expect(result.batches == [.init(id: library.batchId, name: "Keratinocytes plate B12", imageCount: 3)])
        let restored = try await snapshot(library.batchId, in: library.repos.container)
        #expect(restored == original)
        let batch = try #require(library.repos.batch(id: library.batchId))
        #expect(batch.imageCountSummary == 3)
        #expect(batch.cellCountSummary == BatchArchiveService.storedCellCount(original))
        #expect(batch.pxPerUm == Self.pxPerUm && batch.pxPerUmSource == "exif-tiff")
        #expect(library.repos.pendingReviewCandidateCount()
                == original.images.flatMap(\.reviewCandidates).filter { !$0.triaged }.count)
        for (url, data) in library.files {
            #expect((try? Data(contentsOf: url)) == data)
        }
        #expect(try tree(library.archiveURL) == archiveBefore)
        #expect(try await snapshot(library.batchId, in: readOnlyContainer(archiveStore)) == original)
    }

    @Test func restoringTheSameArchiveTwiceIsRefused() async throws {
        let library = try makeLibrary()
        defer { library.cleanUp() }
        let service = BatchArchiveService(repos: library.repos)
        _ = try await service.archive(batchId: library.batchId, to: library.archiveURL)
        _ = try await service.restore(from: library.archiveURL)
        let imagesAfterFirstRestore = library.repos.totalImageCount()
        let batchesAfterFirstRestore = library.repos.totalBatchCount()

        await #expect(throws: BatchArchiveError.alreadyInLibrary(["Keratinocytes plate B12"])) {
            try await service.restore(from: library.archiveURL)
        }
        #expect(library.repos.totalImageCount() == imagesAfterFirstRestore)
        #expect(library.repos.totalBatchCount() == batchesAfterFirstRestore)
        let id = library.batchId
        #expect(try library.repos.context.fetchCount(FetchDescriptor<BatchRecord>(
            predicate: #Predicate { $0.id == id })) == 1)
        for (url, data) in library.files {
            #expect((try? Data(contentsOf: url)) == data)
        }
        await #expect(throws: BatchArchiveError.restoreFromOpenLibrary) {
            try await service.restore(from: library.liveFolder)
        }
    }
}
