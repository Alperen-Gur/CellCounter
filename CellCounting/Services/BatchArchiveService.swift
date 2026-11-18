import Foundation
import SwiftData

/// Errors shown to the user. Every message says what happened to their data.
nonisolated enum BatchArchiveError: LocalizedError, Equatable {
    case batchNotFound
    case destinationExists(String)
    case destinationInsideLibrary
    case sourceFileMissing(image: String)
    case sourceChecksumMismatch(image: String)
    case verificationFailed(String)
    case batchChangedDuringArchive
    case notALibrary(String)
    case archiveHasNoBatches
    case alreadyInLibrary([String])
    case archiveIncomplete(String)
    case restoreFromOpenLibrary

    var errorDescription: String? {
        switch self {
        case .batchNotFound:
            return "This batch is no longer in the library."
        case .destinationExists(let name):
            return "A folder named “\(name)” already exists there. Choose another name; Cellographer never replaces an existing folder."
        case .destinationInsideLibrary:
            return "Choose a folder outside Cellographer's own library folder for the archive."
        case .sourceFileMissing(let image):
            return "The image file for “\(image)” is missing from the library, so the batch cannot be archived completely. Nothing was changed."
        case .sourceChecksumMismatch(let image):
            return "The library's copy of “\(image)” no longer matches the checksum recorded when it was imported, so Cellographer will not move it into an archive. Nothing was changed."
        case .verificationFailed(let detail):
            return "The archive could not be verified: \(detail). The incomplete archive was removed and nothing was changed in your library."
        case .batchChangedDuringArchive:
            return "The batch changed while it was being archived. The archive was discarded and the batch is still in your library. Try again."
        case .notALibrary(let name):
            return "“\(name)” is not a Cellographer archive or library folder (it has no store.sqlite)."
        case .archiveHasNoBatches:
            return "This archive does not contain any batches. Nothing was restored."
        case .alreadyInLibrary(let names):
            if names.count == 1 {
                return "“\(names[0])” is already in this library, so it was not restored a second time. Nothing was changed."
            }
            return "These batches are already in this library: \(names.joined(separator: ", ")). Nothing was restored."
        case .archiveIncomplete(let detail):
            return "The archive is incomplete: \(detail). Nothing was restored and the archive was not changed."
        case .restoreFromOpenLibrary:
            return "This folder is the library that is currently open. Choose an archive folder instead."
        }
    }
}

/// Moves one batch out of the live library into a self-contained
/// `<name>.cellcounterlibrary` folder, and copies archived batches back.
///
/// Data flow and threading:
///  • SwiftData rows are only touched on the main actor, a dozen images at a
///    time, with a short suspension between chunks (`BatchRecordsSnapshotter`).
///    Rows are copied into Sendable value types and written into a separate
///    store; no model object crosses a store or actor boundary.
///  • File copies, checksums, CSV/README writing and folder removal run in
///    detached tasks on Sendable inputs only.
///  • Archive is a move: the batch leaves the live library (`deleteBatch`) only
///    after the archive has been reopened from disk and compared record by
///    record and file by file. Any failure or cancellation before that point
///    deletes the partial archive folder and leaves the library untouched.
///  • Restore never writes to the archive: its store is copied to a temporary
///    folder first and images are only read.
@MainActor
final class BatchArchiveService {
    nonisolated enum Phase: Sendable, Equatable {
        case reading, savingDatabase, copyingFiles, writingExports, verifying
        case removingFromLibrary, restoringRecords, finishing

        var title: String {
            switch self {
            case .reading: return "Reading the batch…"
            case .savingDatabase: return "Saving outlines, measurements and calibration…"
            case .copyingFiles: return "Copying images…"
            case .writingExports: return "Writing CSV files and README…"
            case .verifying: return "Checking the copy…"
            case .removingFromLibrary: return "Removing the batch from the library…"
            case .restoringRecords: return "Adding the batch to the library…"
            case .finishing: return "Finishing…"
            }
        }

        /// After this point the operation commits and can no longer be cancelled.
        var isCancellable: Bool { self != .removingFromLibrary && self != .finishing }
    }

    nonisolated struct Progress: Sendable, Equatable {
        let phase: Phase
        let completed: Int
        let total: Int
        var fraction: Double? { total > 0 ? min(1, Double(completed) / Double(total)) : nil }
    }

    /// Values that only the running app knows (cut-offs, model catalogue).
    struct ExportContext {
        var globalConfidence: Double
        var effectiveConfidence: (ImageRecord) -> Double
        var provenance: (ImageRecord) -> ProvenanceMetadata?

        static func live(_ state: AppState) -> ExportContext {
            ExportContext(globalConfidence: state.confidence,
                          effectiveConfidence: { state.effectiveConfidence(for: $0) },
                          provenance: { ProvenanceMetadata.capture(for: $0, state: state) })
        }

        /// No app state: stored per-image cut-offs, no provenance block.
        static var standalone: ExportContext {
            ExportContext(globalConfidence: 0.5,
                          effectiveConfidence: { $0.confidenceOverride ?? $0.detection?.runSettings?.confidence ?? 0.5 },
                          provenance: { _ in nil })
        }
    }

    nonisolated struct ArchiveResult: Sendable {
        let archiveURL: URL
        let manifest: LibraryManifest
        let copiedFileCount: Int
    }

    nonisolated struct RestoredBatch: Sendable, Equatable {
        let id: UUID
        let name: String
        let imageCount: Int
    }

    nonisolated struct RestoreResult: Sendable {
        let batches: [RestoredBatch]
        let copiedFileCount: Int
    }

    nonisolated struct PlannedFile: Sendable {
        nonisolated enum Role: String, Sendable { case source, display, thumbnail }
        let imageId: UUID
        let imageName: String
        let role: Role
        let from: URL
        let to: URL
        let required: Bool
        let expectedSHA256: String?
    }

    nonisolated struct CopiedFile: Sendable {
        let file: PlannedFile
        let byteCount: Int64
    }

    let repos: Repositories
    var exportContext: ExportContext
    var onProgress: ((Progress) -> Void)?
    /// Fault-injection seam for tests: runs after the archive is fully written
    /// and before it is verified.
    var beforeVerification: ((LibraryLayout) throws -> Void)?
    /// Upper bound on waiting for `deleteBatch`'s background file cleanup.
    var fileRemovalTimeout: TimeInterval = 15

    init(repos: Repositories, exportContext: ExportContext) {
        self.repos = repos
        self.exportContext = exportContext
    }

    /// Without app state (tests, tools): stored cut-offs, no provenance block.
    convenience init(repos: Repositories) {
        self.init(repos: repos, exportContext: .standalone)
    }

    // MARK: - Locations and names

    /// Folder of the library `repos` is using (the folder holding its store),
    /// or nil for an in-memory store.
    static func libraryFolder(of repos: Repositories) -> URL? {
        guard let url = repos.container.configurations.first?.url,
              url.isFileURL, url.path != "/dev/null" else { return nil }
        return url.deletingLastPathComponent().standardizedFileURL
    }

    static func defaultArchiveFolder() -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
            .appendingPathComponent("CellCounter Archives", isDirectory: true)
    }

    /// `<displayName or name> – archived <yyyy-MM-dd>.cellcounterlibrary`
    nonisolated static func defaultArchiveName(displayName: String, name: String, date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        let title = displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? name : displayName
        let base = String(ExportService.sanitizeFilename(title).prefix(160))
        return "\(base) – archived \(formatter.string(from: date)).\(LibraryLayout.packageExtension)"
    }

    nonisolated static func isSameOrInside(_ url: URL, _ folder: URL) -> Bool {
        // Resolve through the parent: the archive folder may not exist yet.
        func resolved(_ url: URL) -> String {
            let url = url.standardizedFileURL
            return url.deletingLastPathComponent().resolvingSymlinksInPath()
                .appendingPathComponent(url.lastPathComponent).path
        }
        let path = resolved(url)
        let root = resolved(folder)
        return path == root || path.hasPrefix(root.hasSuffix("/") ? root : root + "/")
    }

    // MARK: - Archive

    func archive(batchId: UUID, to destination: URL) async throws -> ArchiveResult {
        // Rows are compared field by field; saved mask versions must not be
        // compacted underneath the copy.
        repos.holdVariantCompaction()
        defer { repos.releaseVariantCompaction() }
        let layout = LibraryLayout(root: destination)
        guard let batch = repos.batch(id: batchId) else { throw BatchArchiveError.batchNotFound }
        let liveFolder = Self.libraryFolder(of: repos)
        if let liveFolder, Self.isSameOrInside(layout.root, liveFolder) {
            throw BatchArchiveError.destinationInsideLibrary
        }
        try await Self.offMain { try Self.createArchiveFolder(layout) }

        var committed = false
        do {
            let result = try await performArchive(batch: batch, layout: layout, liveFolder: liveFolder) {
                committed = true
            }
            return result
        } catch {
            if !committed {
                let root = layout.root
                await Self.offMainIgnoringErrors { try FileManager.default.removeItem(at: root) }
            }
            throw error
        }
    }

    private func performArchive(batch: BatchRecord, layout: LibraryLayout, liveFolder: URL?,
                                markCommitted: () -> Void) async throws -> ArchiveResult {
        let batchId = batch.id
        let archivedAt = Date()
        let startRevision = batch.contentRevision
        let startImageCount = batch.images.count

        // 1. Read every row (main actor, chunked) and plan the file copies.
        report(.reading, 0, startImageCount)
        var effective: [UUID: Double] = [:]
        var provenance: [UUID: ProvenanceMetadata] = [:]
        var plan: [PlannedFile] = []
        let context = exportContext
        let snapshot = try await BatchRecordsSnapshotter.snapshot(
            batch: batch, in: repos.context,
            perImage: { image in
                effective[image.id] = context.effectiveConfidence(image)
                if let value = context.provenance(image) { provenance[image.id] = value }
                plan += Self.plannedFiles(for: image, into: layout)
            },
            onChunk: { [weak self] done, total in self?.report(.reading, done, total) })
        let presets = try BatchRecordsSnapshotter.presets(in: repos.context)
        let provenanceJSON = try Self.provenanceJSON(snapshot: snapshot, provenance: provenance,
                                                     archivedAt: archivedAt)

        // 2. Database: a fresh store holding only this batch.
        try await writeArchiveStore(snapshot, presets: presets, layout: layout)

        // 3. Files, off the main thread.
        let copied = try await copyFiles(plan, replaceExisting: false)

        // 4. Human-readable exports, README and manifest.
        let cellCount = try await writeExports(snapshot: snapshot, effective: effective,
                                               provenance: provenance, provenanceJSON: provenanceJSON,
                                               copied: copied, layout: layout)
        let manifest = LibraryManifest(
            kind: .batchArchive,
            name: snapshot.batch.displayName.isEmpty ? snapshot.batch.name : snapshot.batch.displayName,
            createdAt: archivedAt,
            appVersion: LibraryManifest.currentAppVersion,
            archivedBatch: .init(batchId: batchId,
                                 name: snapshot.batch.name,
                                 displayName: snapshot.batch.displayName,
                                 condition: snapshot.batch.condition,
                                 modelId: snapshot.batch.modelId,
                                 pxPerUm: snapshot.batch.pxPerUm,
                                 pxPerUmSource: snapshot.batch.pxPerUmSource,
                                 imageCount: snapshot.images.count,
                                 cellCount: cellCount,
                                 batchCreatedAt: snapshot.batch.createdAt,
                                 archivedAt: archivedAt,
                                 sourceLibraryPath: liveFolder?.path))
        let readme = Self.readme(manifest: manifest, snapshot: snapshot)
        try await Self.offMain {
            try Data(readme.utf8).write(to: layout.root.appendingPathComponent("README.txt"), options: .atomic)
            try layout.writeManifest(manifest)
        }

        // 5. Verify from disk before anything leaves the library.
        try Task.checkCancellation()
        try beforeVerification?(layout)
        try await verifyArchive(layout: layout, snapshot: snapshot, presets: presets,
                                copied: copied, expectedCellCount: cellCount, manifest: manifest)

        // 6. Commit: remove the batch from the live library. No suspension
        // between the last cancellation check and the delete.
        try Task.checkCancellation()
        guard let live = repos.batch(id: batchId), !live.isDeleted,
              live.contentRevision == startRevision,
              live.images.count == startImageCount,
              Self.sameSettings(live, snapshot.batch) else {
            throw BatchArchiveError.batchChangedDuringArchive
        }
        report(.removingFromLibrary, 0, 1)
        try repos.deleteBatch(live)
        markCommitted()
        NotificationCenter.default.post(name: .ccLibraryChanged, object: nil)

        // `deleteBatch` unlinks the library's copies in the background; wait so
        // "archived" means the space is free and a quick restore cannot race it.
        report(.finishing, 0, 1)
        await waitUntilRemoved(plan.map(\.from))
        report(.finishing, 1, 1)
        return ArchiveResult(archiveURL: layout.root, manifest: manifest, copiedFileCount: copied.count)
    }

    private static func sameSettings(_ live: BatchRecord, _ row: BatchRecordsSnapshot.Batch) -> Bool {
        live.name == row.name && live.displayName == row.displayName && live.modelId == row.modelId
            && live.pxPerUm == row.pxPerUm && live.thresholdsData == row.thresholdsData
            && live.condition == row.condition && live.pxPerUmSource == row.pxPerUmSource
    }

    private func writeArchiveStore(_ snapshot: BatchRecordsSnapshot,
                                   presets: LibraryPresetsSnapshot,
                                   layout: LibraryLayout) async throws {
        report(.savingDatabase, 0, snapshot.images.count)
        let schema = Repositories.librarySchema()
        let configuration = ModelConfiguration("CellCounter", schema: schema, url: layout.storeURL)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let context = ModelContext(container)
        context.autosaveEnabled = false
        for preset in presets.calibration { context.insert(preset.makeRecord()) }
        for preset in presets.bins { context.insert(preset.makeRecord()) }
        for condition in snapshot.conditions { context.insert(condition.makeRecord()) }
        try context.save()
        try await BatchRecordsSnapshotter.insert(snapshot, into: context, saveEveryChunk: true) { [weak self] done, total in
            self?.report(.savingDatabase, done, total)
        }
        try context.save()
    }

    private static func plannedFiles(for image: ImageRecord, into layout: LibraryLayout) -> [PlannedFile] {
        guard !image.fileName.isEmpty else { return [] }
        let raw = (image.fileName as NSString).pathExtension
        let ext = raw.isEmpty ? "tif" : raw.lowercased()
        let hash = image.fileHash.flatMap { $0.isEmpty ? nil : $0 }
        var files = [PlannedFile(imageId: image.id, imageName: image.fileName, role: .source,
                                 from: image.storedURL, to: layout.imageURL(for: image.id, extension: ext),
                                 required: true, expectedSHA256: hash)]
        if image.displayURL != image.storedURL {
            files.append(PlannedFile(imageId: image.id, imageName: image.fileName, role: .display,
                                     from: image.displayURL, to: layout.displayImageURL(for: image.id),
                                     required: false, expectedSHA256: nil))
        }
        files.append(PlannedFile(imageId: image.id, imageName: image.fileName, role: .thumbnail,
                                 from: image.thumbURL, to: layout.thumbURL(for: image.id),
                                 required: false, expectedSHA256: nil))
        return files
    }

    // MARK: - Exports

    private nonisolated struct CellExportJob: Sendable {
        let imageId: UUID
        let fileName: String
        let csvName: String
        let cellsData: Data
        let cellCountSummary: Int
        let imageStatsData: Data?
        let detectorId: String
        let ranAt: Date
        let confidence: Double
        let provenance: ProvenanceMetadata?
        /// The image's own scale (`ImageScale`).
        var scale: ExportService.SummaryScale? = nil
    }

    private nonisolated struct CellExportOutcome: Sendable {
        let imageId: UUID
        let cellCount: Int
        let summary: ExportService.PerImageSummaryInput.Detection
    }

    /// Writes per-cell CSVs, the per-image summary, an image index and the
    /// provenance sidecar into `Exports/`. Returns the total stored cell count.
    private func writeExports(snapshot: BatchRecordsSnapshot,
                              effective: [UUID: Double],
                              provenance: [UUID: ProvenanceMetadata],
                              provenanceJSON: Data,
                              copied: [CopiedFile],
                              layout: LibraryLayout) async throws -> Int {
        let exports = layout.exportsDir
        let cellsFolder = exports.appendingPathComponent("cells", isDirectory: true)
        try await Self.offMain {
            try FileManager.default.createDirectory(at: cellsFolder, withIntermediateDirectories: true)
        }
        let thresholds = (try? JSONDecoder().decode([Double].self, from: snapshot.batch.thresholdsData)) ?? [20, 30]
        let pxPerUm = snapshot.batch.pxPerUm
        let modelId = snapshot.batch.modelId
        let fallback = exportContext.globalConfidence

        var usedNames = Set<String>()
        var csvNames: [UUID: String] = [:]
        var jobs: [CellExportJob] = []
        for image in snapshot.images {
            guard let detection = image.detection else { continue }
            let base = ExportService.sanitizeFilename((image.fileName as NSString).deletingPathExtension)
            var name = "\(base).csv"
            var suffix = 2
            while usedNames.contains(name.lowercased()) {
                name = "\(base)_\(suffix).csv"
                suffix += 1
            }
            usedNames.insert(name.lowercased())
            csvNames[image.id] = name
            jobs.append(CellExportJob(imageId: image.id, fileName: image.fileName, csvName: name,
                                      cellsData: detection.cellsData,
                                      cellCountSummary: detection.cellCountSummary,
                                      imageStatsData: detection.imageStatsData,
                                      detectorId: detection.detectorId, ranAt: detection.ranAt,
                                      confidence: effective[image.id] ?? fallback,
                                      provenance: provenance[image.id],
                                      scale: Self.exportScale(of: image, batch: snapshot.batch)))
        }

        var outcomes: [UUID: CellExportOutcome] = [:]
        var start = 0
        report(.writingExports, 0, jobs.count)
        while start < jobs.count {
            try Task.checkCancellation()
            let chunk = Array(jobs[start..<min(start + 16, jobs.count)])
            let written = try await Self.offMain {
                try Self.writeCellCSVs(chunk, thresholds: thresholds, pxPerUm: pxPerUm,
                                       modelId: modelId, folder: cellsFolder)
            }
            for outcome in written { outcomes[outcome.imageId] = outcome }
            start += chunk.count
            report(.writingExports, start, jobs.count)
        }

        let summaryInputs = snapshot.images.map { image in
            ExportService.PerImageSummaryInput(fileName: image.fileName,
                                               importedAt: image.importedAt,
                                               confidenceOverride: image.confidenceOverride,
                                               detection: outcomes[image.id]?.summary,
                                               scale: Self.exportScale(of: image, batch: snapshot.batch))
        }
        let index = Self.imageIndexCSV(snapshot: snapshot, copied: copied, csvNames: csvNames,
                                       cellCounts: outcomes.mapValues(\.cellCount),
                                       effective: effective, fallback: fallback)
        try await Self.offMain {
            try ExportService.writePerImageSummaryCSVCore(images: summaryInputs, modelId: modelId,
                                                          thresholds: thresholds, pxPerUm: pxPerUm,
                                                          confidence: fallback, separator: ",",
                                                          provenance: nil,
                                                          to: exports.appendingPathComponent("per-image-summary.csv"))
            try Data(index.utf8).write(to: exports.appendingPathComponent("images.csv"), options: .atomic)
            try provenanceJSON.write(to: exports.appendingPathComponent("provenance.json"), options: .atomic)
        }
        return outcomes.values.reduce(0) { $0 + $1.cellCount }
    }

    private nonisolated static func writeCellCSVs(_ jobs: [CellExportJob], thresholds: [Double],
                                                  pxPerUm: Double, modelId: String,
                                                  folder: URL) throws -> [CellExportOutcome] {
        try jobs.map { job in
            try autoreleasepool {
                let cells = DetectionRecord.decodeCellsData(job.cellsData)
                // Each image at its own scale.
                try ExportService.writeCSVCore(cells: cells, imageFileName: job.fileName,
                                               thresholds: thresholds, pxPerUm: job.scale?.pxPerUm ?? pxPerUm,
                                               confidence: job.confidence, modelId: modelId,
                                               separator: ",", provenance: job.provenance,
                                               scaleSource: job.scale?.source,
                                               segmentedPxPerUm: job.scale?.segmentedPxPerUm,
                                               to: folder.appendingPathComponent(job.csvName))
                // The summary needs measurements, not outlines; dropping the
                // contours keeps a 600-image batch's memory use small.
                let light = cells.map { cell -> DetectedCell in
                    var copy = cell
                    copy.contourPx = nil
                    copy.channelIntensities = nil
                    return copy
                }
                let stats = job.imageStatsData
                    .flatMap { try? JSONDecoder().decode([String: Double].self, from: $0) } ?? [:]
                return CellExportOutcome(
                    imageId: job.imageId,
                    cellCount: job.cellCountSummary >= 0 ? job.cellCountSummary : cells.count,
                    summary: .init(cells: light, imageStats: stats, detectorId: job.detectorId, ranAt: job.ranAt))
            }
        }
    }

    private static func imageIndexCSV(snapshot: BatchRecordsSnapshot, copied: [CopiedFile],
                                      csvNames: [UUID: String], cellCounts: [UUID: Int],
                                      effective: [UUID: Double], fallback: Double) -> String {
        var relative: [UUID: [PlannedFile.Role: String]] = [:]
        for file in copied {
            let folder = file.file.to.deletingLastPathComponent().lastPathComponent
            relative[file.file.imageId, default: [:]][file.file.role] = "\(folder)/\(file.file.to.lastPathComponent)"
        }
        let iso = ISO8601DateFormatter()
        func esc(_ value: String) -> String { ExportService.csvEscape(value, separator: ",") }
        func number(_ value: Double?) -> String { value.map { String(format: "%g", $0) } ?? "" }
        var lines = [
            "# Cellographer image index for batch \(snapshot.batch.id.uuidString). Image files are named by image_id.",
            ["image_id", "file_name", "stored_file", "display_file", "original_path", "imported_at",
             "width_px", "height_px", "source_px_per_um", "source_calibration", "sha256",
             "analyzed", "n_cells_detected", "cells_csv", "confidence_cutoff", "notes",
             "px_per_um", "px_per_um_source", "segmented_px_per_um"].joined(separator: ","),
        ]
        for image in snapshot.images {
            let files = relative[image.id] ?? [:]
            let analyzed = image.detection != nil
            let scale = exportScale(of: image, batch: snapshot.batch)
            lines.append([
                image.id.uuidString,
                esc(image.fileName),
                esc(files[.source] ?? ""),
                esc(files[.display] ?? ""),
                esc(image.originalPath),
                iso.string(from: image.importedAt),
                String(image.widthPx),
                String(image.heightPx),
                number(image.sourcePxPerUm),
                esc(image.sourceCalibrationSource ?? ""),
                image.fileHash ?? "",
                analyzed ? "yes" : "no",
                analyzed ? String(cellCounts[image.id] ?? 0) : "",
                esc(csvNames[image.id].map { "Exports/cells/\($0)" } ?? ""),
                analyzed ? String(format: "%.2f", effective[image.id] ?? fallback) : "",
                esc(image.notes ?? ""),
                number(scale?.pxPerUm),
                esc(scale?.source ?? ""),
                number(scale?.segmentedPxPerUm),
            ].joined(separator: ","))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// An archived image's own scale: its measurements' scale once analysed
    /// (images analysed before images had their own scale are at the batch's),
    /// otherwise the scale it would be analysed at.
    nonisolated static func exportScale(of image: BatchRecordsSnapshot.Image,
                                        batch: BatchRecordsSnapshot.Batch) -> ExportService.SummaryScale? {
        let measured: ImageScale.Value?
        if image.detection != nil {
            measured = ImageScale.Value(image.measuredPxPerUm, source: image.measuredScaleSource)
                ?? ImageScale.Value(batch.pxPerUm, source: ImageScale.batchSource(batch.pxPerUmSource))
        } else {
            measured = nil
        }
        let next = ImageScale.resolve(explicit: ImageScale.Value(image.scalePxPerUm, source: image.scaleSource),
                                      file: ImageScale.Value(image.sourcePxPerUm,
                                                             source: image.sourceCalibrationSource ?? "metadata"),
                                      fallback: ImageScale.Value(batch.pxPerUm, source: batch.pxPerUmSource))
        guard let value = measured ?? next?.value else { return nil }
        let segmented = image.detection?.runSettingsData
            .flatMap { try? JSONDecoder().decode(AnalysisRunSettings.self, from: $0) }?.pxPerUm
        return ExportService.SummaryScale(pxPerUm: value.pxPerUm, source: value.source, segmentedPxPerUm: segmented)
    }

    private struct ProvenanceFile: Encodable {
        struct Entry: Encodable {
            let imageId: String
            let fileName: String
            let provenance: ProvenanceMetadata?
        }
        let batchId: String
        let batchName: String
        let pxPerUm: Double
        let pxPerUmSource: String?
        let archivedAt: Date
        let images: [Entry]
    }

    private static func provenanceJSON(snapshot: BatchRecordsSnapshot,
                                       provenance: [UUID: ProvenanceMetadata],
                                       archivedAt: Date) throws -> Data {
        let file = ProvenanceFile(
            batchId: snapshot.batch.id.uuidString,
            batchName: snapshot.batch.displayName.isEmpty ? snapshot.batch.name : snapshot.batch.displayName,
            pxPerUm: snapshot.batch.pxPerUm,
            pxPerUmSource: snapshot.batch.pxPerUmSource,
            archivedAt: archivedAt,
            images: snapshot.images.map {
                .init(imageId: $0.id.uuidString, fileName: $0.fileName, provenance: provenance[$0.id])
            })
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(file)
    }

    nonisolated static func describeCalibrationSource(_ source: String?) -> String {
        guard let source, !source.isEmpty else {
            return "not recorded (the batch predates calibration tracking)"
        }
        if source.hasPrefix("preset-") {
            return "calibration preset “\(source.dropFirst("preset-".count))” (\(source))"
        }
        if source.hasPrefix("exif-") || source.hasPrefix("metadata-") {
            return "read from the image files' own metadata (\(source))"
        }
        switch source {
        case "manual": return "entered by hand (manual)"
        case "default": return "the default scale set in Cellographer for images without one (default)"
        default: return "\(ImageScale.label(source)) (\(source))"
        }
    }

    nonisolated static func readme(manifest: LibraryManifest, snapshot: BatchRecordsSnapshot) -> String {
        guard let info = manifest.archivedBatch else { return "" }
        let date = DateFormatter()
        date.locale = Locale(identifier: "en_US_POSIX")
        date.dateFormat = "yyyy-MM-dd HH:mm"
        let umPerPx = info.pxPerUm > 0 ? String(format: "%.4g", 1 / info.pxPerUm) : "unknown"
        // Each image has its own scale; an analysed image whose file records
        // another scale than its measurements use is pointed out.
        let scales = snapshot.images.map { exportScale(of: $0, batch: snapshot.batch) }
        let differing = zip(snapshot.images, scales).filter { image, scale in
            guard image.detection != nil, let own = image.sourcePxPerUm, let used = scale?.pxPerUm else { return false }
            return !ImageScale.same(own, used)
        }.count
        let imageScales = ImageScale.summarize(scales.map { scale in
            scale.map { ImageScale.Entry.scale(ImageScale.Value(pxPerUm: $0.pxPerUm, source: $0.source)) } ?? .missing
        })
        var scaleNote = "\n  Image scales:   " + (imageScales.text.isEmpty ? "none set" : imageScales.text)
            + (imageScales.missingLine.map { " · \($0)" } ?? "")
            + "\n                  Each image's own scale is in Exports/images.csv (column px_per_um)."
        if differing > 0 {
            scaleNote += """

              Note: \(differing) analysed image\(differing == 1 ? "" : "s") carried a different scale in \
            \(differing == 1 ? "its" : "their") own metadata (column source_px_per_um in \
            Exports/images.csv) than \(differing == 1 ? "its" : "their") measurements use (column px_per_um).
            """
        }
        let name = info.displayName.isEmpty ? info.name : info.displayName
        return """
        Cellographer batch archive
        ==========================

        This folder is a complete Cellographer library holding one archived batch.
        Nothing in it depends on the library it came from.

          Batch:          \(name)
          Batch ID:       \(info.batchId.uuidString)
          Condition:      \(info.condition ?? "none")
          Created:        \(date.string(from: info.batchCreatedAt))
          Archived:       \(date.string(from: info.archivedAt))
          Images:         \(info.imageCount)
          Cells stored:   \(info.cellCount)
          Model:          \(info.modelId)
          Batch scale:    \(String(format: "%g", info.pxPerUm)) px/µm (\(umPerPx) µm per pixel), for images without their own
          Scale source:   \(describeCalibrationSource(info.pxPerUmSource))\(scaleNote)
          Archived from:  \(info.sourceLibraryPath ?? "unknown")
          Cellographer:   \(manifest.appVersion)

        What is in this folder
          store.sqlite               The Cellographer database for this batch: images, every
                                     detected cell with its outline and measurements, your
                                     corrections, regions of interest, review decisions, saved
                                     alternative segmentations, ground-truth points, the
                                     analysis settings of each run and the calibration.
          Images/                    The original image files, named by image ID.
          DisplayImages/             Viewable PNG copies of microscope-vendor files (if any).
          Thumbnails/                Small previews.
          Exports/images.csv         Maps each image ID to its original file name, with pixel
                                     dimensions, checksum, the scale found in the file and the
                                     cell count.
          Exports/cells/             One CSV per analysed image, one row per cell.
          Exports/per-image-summary.csv
                                     One row per image: counts, mean diameter, size bins.
          Exports/provenance.json    Model, settings and calibration recorded for each image.
          CellCounterLibrary.json    Machine-readable description of this archive.

        The CSV files open in Excel, R or Python. Lines starting with # record the settings
        used (confidence cut-off, size bins, model, px/µm). As in Cellographer's own exports,
        cells below an image's confidence cut-off are left out of the CSV files; the
        database keeps every detected cell.

        How to bring the batch back
          In Cellographer choose File > Restore Archived Batch… and select this folder. The
          batch is copied back into your library with the same IDs, outlines and calibration.
          The archive itself is not changed, so you can keep it as a backup.
          Because the folder is a complete library, a Cellographer version (or a CellCounter
          version, as older releases were named) that can open libraries can also open it
          directly.

        Please keep the folder together: moving or renaming files inside it breaks the
        link between the database and the images.
        """ + "\n"
    }

    // MARK: - Verification

    private func verifyArchive(layout: LibraryLayout,
                               snapshot: BatchRecordsSnapshot,
                               presets: LibraryPresetsSnapshot,
                               copied: [CopiedFile],
                               expectedCellCount: Int,
                               manifest: LibraryManifest) async throws {
        report(.verifying, 0, snapshot.images.count + copied.count)
        // Reopen the archive with a separate, read-only container so the check
        // reads what is on disk, not what the writer still holds in memory.
        let schema = Repositories.librarySchema()
        let configuration = ModelConfiguration("CellCounter", schema: schema, url: layout.storeURL, allowsSave: false)
        let container: ModelContainer
        do {
            container = try ModelContainer(for: schema, configurations: [configuration])
        } catch {
            throw BatchArchiveError.verificationFailed("the archive database could not be opened (\(error.localizedDescription))")
        }
        let context = ModelContext(container)
        let batchId = snapshot.batch.id
        guard let archivedBatch = try context.fetch(FetchDescriptor<BatchRecord>(
            predicate: #Predicate { $0.id == batchId })).first else {
            throw BatchArchiveError.verificationFailed("the batch is missing from the archive database")
        }
        func expectCount<T: PersistentModel>(_ type: T.Type, _ expected: Int, _ label: String) throws {
            let actual = try context.fetchCount(FetchDescriptor<T>())
            guard actual == expected else {
                throw BatchArchiveError.verificationFailed("\(label): expected \(expected), found \(actual)")
            }
        }
        try expectCount(BatchRecord.self, 1, "batches")
        try expectCount(ImageRecord.self, snapshot.images.count, "image count")
        try expectCount(DetectionRecord.self, snapshot.detectionCount, "detection count")
        try expectCount(CorrectionRecord.self, snapshot.correctionCount, "corrections")
        try expectCount(ROIRecord.self, snapshot.roiCount, "regions of interest")
        try expectCount(ReviewCandidateRecord.self, snapshot.reviewCandidateCount, "review decisions")
        try expectCount(SegmentationVariantRecord.self, snapshot.variantCount, "saved segmentations")
        try expectCount(GroundTruthAnnotation.self, snapshot.annotationCount, "ground-truth points")

        // Every stored value of every row, compared off the main thread.
        let reread = try await BatchRecordsSnapshotter.snapshot(
            batch: archivedBatch, in: context,
            onChunk: { [weak self] done, _ in self?.report(.verifying, done, snapshot.images.count + copied.count) })
        let rereadPresets = try BatchRecordsSnapshotter.presets(in: context)
        // Stale review-index rows are deliberately not copied.
        let expected: BatchRecordsSnapshot = {
            var value = snapshot
            value.skippedStaleReviewRows = 0
            return value
        }()
        let recordsMatch = await Self.offMainValue { reread == expected }
        guard recordsMatch else {
            throw BatchArchiveError.verificationFailed("the archived records differ from the library's records")
        }
        guard rereadPresets == presets else {
            throw BatchArchiveError.verificationFailed("the calibration and size-bin presets differ")
        }
        let archivedCells = await Self.offMainValue { Self.storedCellCount(reread) }
        guard archivedCells == expectedCellCount else {
            throw BatchArchiveError.verificationFailed("cell count: expected \(expectedCellCount), found \(archivedCells)")
        }

        // Files: presence, byte size and, where recorded, SHA-256.
        var start = 0
        while start < copied.count {
            try Task.checkCancellation()
            let chunk = Array(copied[start..<min(start + 24, copied.count)])
            try await Self.offMain { try Self.verifyCopies(chunk) }
            start += chunk.count
            report(.verifying, snapshot.images.count + start, snapshot.images.count + copied.count)
        }
        // The manifest stores whole-second dates, so compare its content fields.
        guard let readBack = layout.readManifest(), readBack.kind == .batchArchive,
              let info = readBack.archivedBatch, info.batchId == batchId,
              info.imageCount == snapshot.images.count, info.cellCount == expectedCellCount,
              info.pxPerUm == snapshot.batch.pxPerUm, info.pxPerUmSource == snapshot.batch.pxPerUmSource,
              readBack.archivedBatch?.sourceLibraryPath == manifest.archivedBatch?.sourceLibraryPath else {
            throw BatchArchiveError.verificationFailed("the archive description file could not be read back")
        }
    }

    /// Stored cell count: the denormalised summary, or a decode for legacy rows.
    nonisolated static func storedCellCount(_ snapshot: BatchRecordsSnapshot) -> Int {
        snapshot.images.reduce(0) { total, image in
            guard let detection = image.detection else { return total }
            if detection.cellCountSummary >= 0 { return total + detection.cellCountSummary }
            return total + DetectionRecord.decodeCellsData(detection.cellsData).count
        }
    }

    // MARK: - Restore

    func restore(from folder: URL) async throws -> RestoreResult {
        // Restored rows are re-read and compared field by field; saved mask
        // versions must not be compacted before that check.
        repos.holdVariantCompaction()
        defer { repos.releaseVariantCompaction() }
        let source = LibraryLayout(root: folder)
        guard LibraryLayout.isLibrary(at: source.root) else {
            throw BatchArchiveError.notALibrary(source.root.lastPathComponent)
        }
        if let live = Self.libraryFolder(of: repos),
           Self.isSameOrInside(source.root, live), Self.isSameOrInside(live, source.root) {
            throw BatchArchiveError.restoreFromOpenLibrary
        }
        report(.reading, 0, 1)
        // Work on a private copy of the database so opening it (and any schema
        // upgrade SwiftData performs) can never change the archive.
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("CellCounter-restore-\(UUID().uuidString)", isDirectory: true)
        let scratchStore = scratch.appendingPathComponent(LibraryLayout.storeFileName)
        defer {
            Task.detached(priority: .utility) { try? FileManager.default.removeItem(at: scratch) }
        }
        try await Self.offMain {
            let fm = FileManager.default
            try fm.createDirectory(at: scratch, withIntermediateDirectories: true)
            // Copy the write-ahead log before the database: if SQLite folds the
            // log into the database in between, replaying the older log copy
            // rewrites the same committed pages, so the pair stays consistent.
            // The -shm index is rebuilt by SQLite and is not copied.
            let wal = source.root.appendingPathComponent(LibraryLayout.storeFileName + "-wal")
            if fm.fileExists(atPath: wal.path) {
                try? fm.copyItem(at: wal, to: scratch.appendingPathComponent(LibraryLayout.storeFileName + "-wal"))
            }
            try fm.copyItem(at: source.storeURL, to: scratchStore)
        }

        var snapshots: [BatchRecordsSnapshot] = []
        var archivedConditions: [BatchRecordsSnapshot.Condition] = []
        var archivedPresets = LibraryPresetsSnapshot(calibration: [], bins: [])
        var plan: [PlannedFile] = []
        do {
            let schema = Repositories.librarySchema()
            let configuration = ModelConfiguration("CellCounter", schema: schema, url: scratchStore)
            let container = try ModelContainer(for: schema, configurations: [configuration])
            let context = ModelContext(container)
            context.autosaveEnabled = false
            let batches = try context.fetch(FetchDescriptor<BatchRecord>(sortBy: [SortDescriptor(\.createdAt)]))
            guard !batches.isEmpty else { throw BatchArchiveError.archiveHasNoBatches }
            try refuseExisting(batches: batches.map { ($0.id, $0.displayName.isEmpty ? $0.name : $0.displayName) },
                               imagesByBatch: Dictionary(batches.map { b in (b.id, b.images.map(\.id)) },
                                                         uniquingKeysWith: { a, _ in a }))
            let total = batches.reduce(0) { $0 + $1.images.count }
            var done = 0
            for batch in batches {
                let base = done
                let snapshot = try await BatchRecordsSnapshotter.snapshot(
                    batch: batch, in: context,
                    onChunk: { [weak self] n, _ in self?.report(.reading, base + n, total) })
                done += snapshot.images.count
                snapshots.append(snapshot)
            }
            archivedConditions = try context.fetch(FetchDescriptor<ConditionRecord>())
                .map(BatchRecordsSnapshot.Condition.init)
            archivedPresets = try BatchRecordsSnapshotter.presets(in: context)
        }
        try refuseExistingChildren(snapshots)

        // Plan file copies into the live library's own folders.
        let fm = FileManager.default
        for snapshot in snapshots {
            for image in snapshot.images where !image.fileName.isEmpty {
                let ext = image.storedExtension
                let stored = source.imageURL(for: image.id, extension: ext)
                plan.append(PlannedFile(imageId: image.id, imageName: image.fileName, role: .source,
                                        from: stored, to: FileStore.shared.imageURL(for: image.id, extension: ext),
                                        required: true, expectedSHA256: image.fileHash.flatMap { $0.isEmpty ? nil : $0 }))
                let display = source.displayImageURL(for: image.id)
                if fm.fileExists(atPath: display.path) {
                    plan.append(PlannedFile(imageId: image.id, imageName: image.fileName, role: .display,
                                            from: display, to: FileStore.shared.displayImageURL(for: image.id),
                                            required: false, expectedSHA256: nil))
                }
                plan.append(PlannedFile(imageId: image.id, imageName: image.fileName, role: .thumbnail,
                                        from: source.thumbURL(for: image.id), to: FileStore.shared.thumbURL(for: image.id),
                                        required: false, expectedSHA256: nil))
            }
        }

        var copied: [CopiedFile] = []
        var saved = false
        do {
            do {
                _ = try await copyFiles(plan, replaceExisting: true) { copied.append(contentsOf: $0) }
            } catch BatchArchiveError.sourceFileMissing(let image) {
                throw BatchArchiveError.archiveIncomplete("the image file for “\(image)” is missing")
            }
            var start = 0
            while start < copied.count {
                try Task.checkCancellation()
                let chunk = Array(copied[start..<min(start + 24, copied.count)])
                do {
                    try await Self.offMain { try Self.verifyCopies(chunk) }
                } catch BatchArchiveError.sourceChecksumMismatch(let image) {
                    throw BatchArchiveError.archiveIncomplete("“\(image)” no longer matches the checksum recorded at import")
                }
                start += chunk.count
                report(.verifying, start, copied.count)
            }

            // Records: one context, one save, so the library never holds half a batch.
            try Task.checkCancellation()
            let context = ModelContext(repos.container)
            context.autosaveEnabled = false
            var inserted: [BatchRecordsSnapshot] = []
            let total = snapshots.reduce(0) { $0 + $1.images.count }
            var done = 0
            for var snapshot in snapshots {
                // Same denormalised summaries a fresh import maintains. Legacy
                // rows without per-detection counts are left for the launch-time
                // index rebuild to fill in, exactly as for an upgraded library.
                if snapshot.hasCompleteCellSummaries {
                    snapshot.batch.imageCountSummary = snapshot.images.count
                    snapshot.batch.cellCountSummary = snapshot.images.reduce(0) {
                        $0 + ($1.detection?.cellCountSummary ?? 0)
                    }
                } else {
                    snapshot.batch.imageCountSummary = -1
                    snapshot.batch.cellCountSummary = -1
                }
                snapshot.skippedStaleReviewRows = 0
                let base = done
                try await BatchRecordsSnapshotter.insert(snapshot, into: context, saveEveryChunk: false) { [weak self] n, _ in
                    self?.report(.restoringRecords, base + n, total)
                }
                done += snapshot.images.count
                inserted.append(snapshot)
            }
            insertMissingConditions(archivedConditions, for: snapshots, into: context)
            try insertMissingPresets(archivedPresets, into: context)
            try Task.checkCancellation()
            report(.finishing, 0, 1)
            do {
                try context.save()
            } catch {
                context.rollback()
                throw error
            }
            saved = true
            // Restored rows may need upkeep (older archives); it runs once the
            // hold is released.
            repos.noteRestoredRows()

            // Re-read what was saved and compare it with the archive.
            try await verifyRestored(inserted)
        } catch {
            if saved {
                // Undo a saved but mismatching restore, including its files.
                for snapshot in snapshots {
                    if let batch = repos.batch(id: snapshot.batch.id) { try? repos.deleteBatch(batch) }
                }
            } else {
                let urls = copied.map(\.file.to)
                await Self.offMainIgnoringErrors {
                    for url in urls { try? FileManager.default.removeItem(at: url) }
                }
            }
            NotificationCenter.default.post(name: .ccLibraryChanged, object: nil)
            throw error
        }

        NotificationCenter.default.post(name: .ccLibraryChanged, object: nil)
        let needsIndexing = snapshots.contains { snapshot in
            !snapshot.hasCompleteCellSummaries
                || snapshot.images.contains { ($0.detection?.reviewIndexVersion ?? 1) < 1 }
        }
        if needsIndexing {
            try? await repos.rebuildPerformanceIndexes()
            NotificationCenter.default.post(name: .ccLibraryChanged, object: nil)
        }
        report(.finishing, 1, 1)
        return RestoreResult(
            batches: snapshots.map {
                RestoredBatch(id: $0.batch.id,
                              name: $0.batch.displayName.isEmpty ? $0.batch.name : $0.batch.displayName,
                              imageCount: $0.images.count)
            },
            copiedFileCount: copied.count)
    }

    private func verifyRestored(_ expected: [BatchRecordsSnapshot]) async throws {
        let context = ModelContext(repos.container)
        for snapshot in expected {
            let id = snapshot.batch.id
            guard let batch = try context.fetch(FetchDescriptor<BatchRecord>(
                predicate: #Predicate { $0.id == id })).first else {
                throw BatchArchiveError.verificationFailed("the restored batch could not be read back")
            }
            let reread = try await BatchRecordsSnapshotter.snapshot(batch: batch, in: context)
            let matches = await Self.offMainValue { reread.batch == snapshot.batch && reread.images == snapshot.images }
            guard matches else {
                throw BatchArchiveError.verificationFailed("the restored records differ from the archive")
            }
        }
    }

    /// Refuses before anything is copied when a batch or image already exists.
    private func refuseExisting(batches: [(UUID, String)], imagesByBatch: [UUID: [UUID]]) throws {
        let context = repos.context
        var clashing: [String] = []
        for (id, name) in batches {
            let batchClash = try context.fetchCount(FetchDescriptor<BatchRecord>(predicate: #Predicate { $0.id == id })) > 0
            let imageClash = try Self.anyExisting(imagesByBatch[id] ?? []) { ids in
                try context.fetchCount(FetchDescriptor<ImageRecord>(predicate: #Predicate { ids.contains($0.id) }))
            }
            if batchClash || imageClash { clashing.append(name) }
        }
        if !clashing.isEmpty { throw BatchArchiveError.alreadyInLibrary(clashing) }
    }

    /// Child rows carry unique ids too; inserting one that exists would
    /// silently overwrite it, so any overlap is treated as "already here".
    private func refuseExistingChildren(_ snapshots: [BatchRecordsSnapshot]) throws {
        let context = repos.context
        for snapshot in snapshots {
            let images = snapshot.images
            let detections = images.compactMap { $0.detection?.id }
            let corrections = images.flatMap { $0.detection?.corrections.map(\.id) ?? [] }
            let rois = images.flatMap { $0.rois.map(\.id) }
            let review = images.flatMap { $0.reviewCandidates.map(\.id) }
            let variants = images.flatMap { $0.variants.map(\.id) }
            let annotations = images.flatMap { $0.annotations.map(\.id) }
            let clash = try Self.anyExisting(detections) { ids in
                try context.fetchCount(FetchDescriptor<DetectionRecord>(predicate: #Predicate { ids.contains($0.id) }))
            } || Self.anyExisting(corrections) { ids in
                try context.fetchCount(FetchDescriptor<CorrectionRecord>(predicate: #Predicate { ids.contains($0.id) }))
            } || Self.anyExisting(rois) { ids in
                try context.fetchCount(FetchDescriptor<ROIRecord>(predicate: #Predicate { ids.contains($0.id) }))
            } || Self.anyExisting(review) { ids in
                try context.fetchCount(FetchDescriptor<ReviewCandidateRecord>(predicate: #Predicate { ids.contains($0.id) }))
            } || Self.anyExisting(variants) { ids in
                try context.fetchCount(FetchDescriptor<SegmentationVariantRecord>(predicate: #Predicate { ids.contains($0.id) }))
            } || Self.anyExisting(annotations) { ids in
                try context.fetchCount(FetchDescriptor<GroundTruthAnnotation>(predicate: #Predicate { ids.contains($0.id) }))
            }
            if clash {
                let name = snapshot.batch.displayName.isEmpty ? snapshot.batch.name : snapshot.batch.displayName
                throw BatchArchiveError.alreadyInLibrary([name])
            }
        }
    }

    private static func anyExisting(_ ids: [UUID], _ count: ([UUID]) throws -> Int) throws -> Bool {
        var start = 0
        while start < ids.count {
            let chunk = Array(ids[start..<min(start + 500, ids.count)])
            if try count(chunk) > 0 { return true }
            start += chunk.count
        }
        return false
    }

    /// Adds the condition tag a restored batch uses when this library has no
    /// condition of that name, so Compare can colour and pool it.
    private func insertMissingConditions(_ archived: [BatchRecordsSnapshot.Condition],
                                         for snapshots: [BatchRecordsSnapshot],
                                         into context: ModelContext) {
        let live = repos.conditions()
        var names = Set(live.map(\.name))
        let ids = Set(live.map(\.id))
        var nextOrder = (live.map(\.order).max() ?? -1) + 1
        for name in Set(snapshots.compactMap(\.batch.condition)).sorted() where !names.contains(name) {
            guard let condition = archived.first(where: { $0.name == name }) else { continue }
            var copy = condition
            if ids.contains(copy.id) { copy.id = UUID() }
            copy.order = nextOrder
            nextOrder += 1
            context.insert(copy.makeRecord())
            names.insert(name)
        }
    }

    /// Adds archived presets this library does not have (by id and by name).
    /// Never adds a second default calibration.
    private func insertMissingPresets(_ archived: LibraryPresetsSnapshot, into context: ModelContext) throws {
        let liveCalibration = repos.calibrationPresets()
        var hasDefault = liveCalibration.contains(where: \.isDefault)
        for preset in archived.calibration
        where !liveCalibration.contains(where: { $0.id == preset.id || $0.name == preset.name }) {
            var copy = preset
            if hasDefault { copy.isDefault = false }
            hasDefault = hasDefault || copy.isDefault
            context.insert(copy.makeRecord())
        }
        let liveBins = repos.binPresets()
        for preset in archived.bins where !liveBins.contains(where: { $0.id == preset.id || $0.name == preset.name }) {
            context.insert(preset.makeRecord())
        }
    }

    // MARK: - Files

    /// Copies files in small detached chunks, reporting progress and honouring
    /// cancellation between chunks. `onChunk` receives each finished chunk so
    /// a caller can clean up after a later failure.
    private func copyFiles(_ plan: [PlannedFile], replaceExisting: Bool,
                           onChunk: (([CopiedFile]) -> Void)? = nil) async throws -> [CopiedFile] {
        var copied: [CopiedFile] = []
        var start = 0
        report(.copyingFiles, 0, plan.count)
        while start < plan.count {
            try Task.checkCancellation()
            let chunk = Array(plan[start..<min(start + 24, plan.count)])
            let done = try await Self.offMain { try Self.copy(chunk, replaceExisting: replaceExisting) }
            copied.append(contentsOf: done)
            onChunk?(done)
            start += chunk.count
            report(.copyingFiles, start, plan.count)
        }
        return copied
    }

    nonisolated static func copy(_ files: [PlannedFile], replaceExisting: Bool) throws -> [CopiedFile] {
        let fm = FileManager.default
        var done: [CopiedFile] = []
        do {
            for file in files {
                guard fm.fileExists(atPath: file.from.path) else {
                    if file.required { throw BatchArchiveError.sourceFileMissing(image: file.imageName) }
                    continue
                }
                let size = try fileSize(file.from)
                if fm.fileExists(atPath: file.to.path) {
                    // Destinations are named by an image id that no record in
                    // the target owns, so an existing file is a leftover.
                    guard replaceExisting else { throw CocoaError(.fileWriteFileExists, userInfo: [NSFilePathErrorKey: file.to.path]) }
                    try fm.removeItem(at: file.to)
                }
                try fm.createDirectory(at: file.to.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.copyItem(at: file.from, to: file.to)
                done.append(CopiedFile(file: file, byteCount: size))
            }
        } catch {
            for item in done { try? fm.removeItem(at: item.file.to) }
            throw error
        }
        return done
    }

    nonisolated static func verifyCopies(_ copies: [CopiedFile]) throws {
        let fm = FileManager.default
        for item in copies {
            let file = item.file
            guard fm.fileExists(atPath: file.to.path) else {
                throw BatchArchiveError.verificationFailed("the \(file.role.rawValue) file of “\(file.imageName)” is missing")
            }
            let size = try fileSize(file.to)
            guard size == item.byteCount else {
                throw BatchArchiveError.verificationFailed("the \(file.role.rawValue) file of “\(file.imageName)” has \(size) bytes instead of \(item.byteCount)")
            }
            guard let expected = file.expectedSHA256?.lowercased() else { continue }
            guard let actual = ImageLoader.sha256Hex(of: file.to)?.lowercased() else {
                throw BatchArchiveError.verificationFailed("the copy of “\(file.imageName)” could not be read back")
            }
            if actual != expected {
                if let original = ImageLoader.sha256Hex(of: file.from)?.lowercased(), original != expected {
                    throw BatchArchiveError.sourceChecksumMismatch(image: file.imageName)
                }
                throw BatchArchiveError.verificationFailed("the copy of “\(file.imageName)” does not match its checksum")
            }
        }
    }

    nonisolated static func fileSize(_ url: URL) throws -> Int64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.size] as? NSNumber)?.int64Value ?? -1
    }

    nonisolated static func createArchiveFolder(_ layout: LibraryLayout) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: layout.root.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: layout.root.path) {
            throw BatchArchiveError.destinationExists(layout.root.lastPathComponent)
        }
        do {
            // Not intermediate: creation fails if something appeared meanwhile,
            // so cleanup can never remove a folder this code did not create.
            try fm.createDirectory(at: layout.root, withIntermediateDirectories: false)
        } catch {
            if fm.fileExists(atPath: layout.root.path) {
                throw BatchArchiveError.destinationExists(layout.root.lastPathComponent)
            }
            throw error
        }
        try layout.createDirectories()
    }

    private func waitUntilRemoved(_ urls: [URL]) async {
        let deadline = Date().addingTimeInterval(fileRemovalTimeout)
        while Date() < deadline, !Task.isCancelled {
            let remaining = await Self.offMainValue {
                urls.contains { FileManager.default.fileExists(atPath: $0.path) }
            }
            if !remaining { return }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    // MARK: - Helpers

    private func report(_ phase: Phase, _ completed: Int, _ total: Int) {
        onProgress?(Progress(phase: phase, completed: completed, total: total))
    }

    private nonisolated static func offMain<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await Task.detached(priority: .userInitiated, operation: work).value
    }

    private nonisolated static func offMainValue<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await Task.detached(priority: .userInitiated, operation: work).value
    }

    private nonisolated static func offMainIgnoringErrors(_ work: @escaping @Sendable () throws -> Void) async {
        _ = try? await Task.detached(priority: .utility, operation: work).value
    }
}
