import Foundation
import SwiftData
import Testing
@testable import CellCounting

@Suite(.serialized)
struct LibrarySizeReportTests {
    @Test @MainActor func librarySizeSectionIsNumericAndContainsNoNamesOrPaths() async throws {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("cc-size-report-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        // A distinctive folder name makes any path leak easy to spot.
        let root = parent.appendingPathComponent("Secret Lab Project.cellcounterlibrary", isDirectory: true)
        let layout = LibraryLayout(root: root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try layout.createDirectories()
        let schema = Repositories.librarySchema()
        let container = try ModelContainer(for: schema, configurations: [
            ModelConfiguration("CellCounter", schema: schema, url: layout.storeURL)])
        let repos = Repositories(container: container)
        let batch = repos.createBatch(displayName: "Secret Plate", modelId: "test", pxPerUm: 2, thresholds: [10, 20])
        for index in 0..<8 {
            let image = ImageRecord(fileName: "secret-\(index).png", originalPath: "/Users/secret/secret-\(index).png",
                                    widthPx: 128, heightPx: 128)
            repos.context.insert(image)
            repos.attach(image: image, to: batch)
            let cells = (0..<5).map { k in
                DetectedCell(cx: Double(10 + k * 20), cy: 30, diameter: 5, diameterPx: 10, confidence: 0.2)
            }
            repos.saveDetection(cells, detectorId: "test", for: image)
            try Data(repeating: 1, count: 100).write(to: layout.imageURL(for: image.id, extension: "png"))
            try Data(repeating: 2, count: 50).write(to: layout.thumbURL(for: image.id))
        }
        try repos.context.save()
        let snapshot = await LibrarySizeReport.measure(repos: repos)

        // The numbers match the store, read without decoding any cell data.
        let detections = try repos.context.fetch(FetchDescriptor<DetectionRecord>())
        let variants = try repos.context.fetch(FetchDescriptor<SegmentationVariantRecord>())
        #expect(snapshot.batches == 1)
        #expect(snapshot.images == 8)
        #expect(snapshot.detections == 8)
        #expect(snapshot.totalCells == detections.reduce(0) { $0 + $1.cellCountSummary })
        #expect(snapshot.cellsDataBytes == Int64(detections.reduce(0) { $0 + $1.cellsData.count }))
        #expect(snapshot.variantCellsDataBytes == Int64(variants.reduce(0) { $0 + $1.cellsData.count }))
        #expect(snapshot.segmentationVariants == variants.count)
        #expect(snapshot.storeBytes > 0)
        #expect(snapshot.imagesFolderFiles == 8)
        #expect((snapshot.imagesFolderBytes ?? 0) >= 800)
        #expect((snapshot.thumbnailsFolderBytes ?? 0) >= 400)

        let text = LibrarySizeReport.lines(snapshot, system: .current()).joined(separator: "\n")
        #expect(text.contains("Images: 8"))
        #expect(!text.contains("/"), "No paths")
        #expect(!text.contains("~"))
        #expect(!text.contains("Secret"))
        #expect(!text.contains(".cellcounterlibrary"))
        #expect(!text.contains(NSUserName()))
        #expect(text.range(of: #"[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-"#, options: .regularExpression) == nil, "No IDs")
        #expect(text.range(of: #"\.(png|tif|tiff|jpg|jpeg|nd2|czi|lif)\b"#,
                           options: [.regularExpression, .caseInsensitive]) == nil, "No file names")
        for image in repos.allImages() {
            #expect(!text.contains(image.fileName))
            #expect(!text.contains((image.fileName as NSString).deletingPathExtension))
            #expect(!text.contains(image.id.uuidString))
        }
        for batch in repos.allBatches() {
            #expect(!text.contains(batch.displayName))
            #expect(!text.contains(batch.name))
        }
        for condition in repos.conditions() { #expect(!text.contains(condition.name)) }
    }

    @Test @MainActor func inMemoryLibraryReportsCountsWithoutFileSizes() async throws {
        let repos = Repositories(inMemory: true)
        let batch = repos.createBatch(displayName: "Plate", modelId: "test", pxPerUm: 2, thresholds: [10, 20])
        let image = ImageRecord(fileName: "a.png", originalPath: "/x/a.png", widthPx: 10, heightPx: 10)
        repos.context.insert(image)
        repos.attach(image: image, to: batch)
        repos.saveDetection([DetectedCell(cx: 1, cy: 1, diameter: 2, diameterPx: 4, confidence: 0.2)],
                            detectorId: "test", for: image)
        let snapshot = await LibrarySizeReport.measure(repos: repos)
        #expect(snapshot.images == 1 && snapshot.detections == 1)
        #expect(snapshot.totalCells == 1)
        #expect(snapshot.cellsDataBytes == nil)
        let text = LibrarySizeReport.lines(snapshot, system: .current()).joined(separator: "\n")
        #expect(text.contains("Saved cell measurements and outlines: unavailable"))
        #expect(!text.contains("a.png") && !text.contains("/"))
    }
}
