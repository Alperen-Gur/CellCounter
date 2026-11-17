import Darwin
import Foundation
import SQLite3
import SwiftData

/// Numbers that describe how big a library is. Deliberately holds no names,
/// paths, identifiers or dates, so it can go into a shareable diagnostics report.
nonisolated struct LibrarySizeSnapshot: Codable, Sendable, Equatable {
    var batches = 0
    var images = 0
    var detections = 0
    /// Sum of the saved per-detection cell counts.
    var totalCells: Int?
    /// Detections whose cell count has not been summarised yet (older libraries
    /// catch up after launch). Their cells are not in `totalCells`.
    var detectionsWithoutCellCount = 0
    var segmentationVariants = 0
    var reviewCandidateRows = 0
    var pendingReviewCandidates = 0
    var corrections = 0
    var storeBytes: Int64 = 0
    var walBytes: Int64 = 0
    /// Bytes of saved cell measurements and outlines (the live detections).
    var cellsDataBytes: Int64?
    /// The same for saved alternative segmentations.
    var variantCellsDataBytes: Int64?
    var imagesFolderBytes: Int64?
    var imagesFolderFiles: Int?
    var displayImagesFolderBytes: Int64?
    var thumbnailsFolderBytes: Int64?
    var embeddingsFolderBytes: Int64?
}

/// The Mac the report was prepared on, reduced to coarse, non-identifying values.
nonisolated struct DiagnosticsSystemInfo: Sendable, Equatable {
    var appVersion: String
    var macOSVersion: String
    var macModel: String
    var memoryBytes: UInt64
    var processorCores: Int

    static func current() -> DiagnosticsSystemInfo {
        let info = Bundle.main.infoDictionary
        let short = sanitized(info?["CFBundleShortVersionString"] as? String, pattern: #"^\d{1,4}(\.\d{1,4}){0,3}$"#)
        let build = sanitized(info?["CFBundleVersion"] as? String, pattern: #"^\d{1,8}(\.\d{1,8}){0,3}$"#)
        let os = ProcessInfo.processInfo.operatingSystemVersion
        return DiagnosticsSystemInfo(
            appVersion: build == "unknown" ? short : "\(short) (build \(build))",
            macOSVersion: "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)",
            macModel: sanitized(sysctlString("hw.model"), pattern: #"^[A-Za-z]{2,24}[0-9]{1,3},[0-9]{1,3}$"#),
            memoryBytes: ProcessInfo.processInfo.physicalMemory,
            processorCores: ProcessInfo.processInfo.activeProcessorCount)
    }

    /// Keep only values that match a strict shape; anything else is "unknown".
    private static func sanitized(_ value: String?, pattern: String) -> String {
        guard let value, value.range(of: pattern, options: .regularExpression) != nil else { return "unknown" }
        return value
    }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0, size < 256 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }
}

/// File-level measurements. Runs off the main actor and never decodes cell data.
nonisolated enum LibraryStorageMeasurement {
    struct BlobTotals: Sendable, Equatable {
        var detections = 0
        var cells = 0
        var detectionsWithoutCellCount = 0
        var detectionBlobBytes: Int64 = 0
        var variantBlobBytes: Int64 = 0
    }

    struct Result: Sendable {
        var storeBytes: Int64 = 0
        var walBytes: Int64 = 0
        var blobs: BlobTotals?
        var images: (bytes: Int64, files: Int)?
        var displayImages: (bytes: Int64, files: Int)?
        var thumbnails: (bytes: Int64, files: Int)?
        var embeddings: (bytes: Int64, files: Int)?
    }

    static func measure(storeURL: URL) -> Result {
        let layout = LibraryLayout(root: storeURL.deletingLastPathComponent())
        var result = Result()
        result.storeBytes = fileBytes(storeURL)
        result.walBytes = fileBytes(URL(fileURLWithPath: storeURL.path + "-wal"))
        result.blobs = blobTotals(storeURL: storeURL)
        result.images = directoryUsage(layout.imagesDir)
        result.displayImages = directoryUsage(layout.displayImagesDir)
        result.thumbnails = directoryUsage(layout.thumbsDir)
        result.embeddings = directoryUsage(layout.embeddingsDir)
        return result
    }

    static func fileBytes(_ url: URL) -> Int64 {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.size] as? NSNumber)?.int64Value ?? 0
    }

    /// Total size of regular files below `url`, or nil when it does not exist.
    static func directoryUsage(_ url: URL) -> (bytes: Int64, files: Int)? {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return nil
        }
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey]
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys) else { return nil }
        var bytes: Int64 = 0, files = 0
        for case let file as URL in enumerator {
            guard let values = try? file.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
            bytes += Int64(values.fileSize ?? 0)
            files += 1
        }
        return (bytes, files)
    }

    /// Aggregates read straight from the SQLite file through a read-only
    /// connection. `length()` reads each value's stored size, not the value,
    /// so even a multi-gigabyte store answers without loading cell data.
    /// Returns nil when the store layout is not the expected one.
    static func blobTotals(storeURL: URL) -> BlobTotals? {
        guard FileManager.default.fileExists(atPath: storeURL.path) else { return nil }
        var database: OpaquePointer?
        guard sqlite3_open_v2(storeURL.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            if let database { sqlite3_close(database) }
            return nil
        }
        defer { sqlite3_close(database) }
        sqlite3_busy_timeout(database, 1_000)

        func row(_ sql: String) -> [Int64]? {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
                sqlite3_finalize(statement)
                return nil
            }
            defer { sqlite3_finalize(statement) }
            guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
            return (0..<sqlite3_column_count(statement)).map { sqlite3_column_int64(statement, $0) }
        }
        func columns(of table: String) -> Set<String> {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(database, "PRAGMA table_info(\(table))", -1, &statement, nil) == SQLITE_OK else {
                sqlite3_finalize(statement)
                return []
            }
            defer { sqlite3_finalize(statement) }
            var names = Set<String>()
            while sqlite3_step(statement) == SQLITE_ROW {
                if let name = sqlite3_column_text(statement, 1) { names.insert(String(cString: name)) }
            }
            return names
        }
        // Detection cells live in ZSTOREDCELLSRECORD.ZDATA. Rows the background
        // upkeep has not moved yet keep them inline, in ZLEGACYCELLSDATA
        // (ZCELLSDATA in a store not yet opened by this version).
        guard let inlineColumn = ["ZLEGACYCELLSDATA", "ZCELLSDATA"]
            .first(where: columns(of: "ZDETECTIONRECORD").contains) else { return nil }
        guard let detections = row("""
            SELECT COUNT(*),
                   COALESCE(SUM(CASE WHEN ZCELLCOUNTSUMMARY >= 0 THEN ZCELLCOUNTSUMMARY ELSE 0 END), 0),
                   COALESCE(SUM(CASE WHEN ZCELLCOUNTSUMMARY < 0 THEN 1 ELSE 0 END), 0),
                   COALESCE(SUM(LENGTH(\(inlineColumn))), 0)
            FROM ZDETECTIONRECORD
            """), detections.count == 4 else { return nil }
        var separateBytes: Int64 = 0
        if columns(of: "ZSTOREDCELLSRECORD").contains("ZDATA") {
            guard let separate = row("SELECT COALESCE(SUM(LENGTH(ZDATA)), 0) FROM ZSTOREDCELLSRECORD"),
                  let bytes = separate.first else { return nil }
            separateBytes = bytes
        }
        let variants = row("SELECT COALESCE(SUM(LENGTH(ZCELLSDATA)), 0) FROM ZSEGMENTATIONVARIANTRECORD")
        return BlobTotals(detections: Int(detections[0]), cells: Int(detections[1]),
                          detectionsWithoutCellCount: Int(detections[2]),
                          detectionBlobBytes: detections[3] + separateBytes,
                          variantBlobBytes: variants?.first ?? 0)
    }
}

enum LibrarySizeReport {
    /// Counts come from `fetchCount` (a SQL COUNT, no rows materialised);
    /// byte totals and folder sizes are measured on a background thread.
    static func measure(repos: Repositories) async -> LibrarySizeSnapshot {
        let context = repos.context
        func count<T: PersistentModel>(_ type: T.Type) -> Int {
            (try? context.fetchCount(FetchDescriptor<T>())) ?? -1
        }
        var snapshot = LibrarySizeSnapshot()
        snapshot.batches = count(BatchRecord.self)
        snapshot.images = count(ImageRecord.self)
        snapshot.detections = count(DetectionRecord.self)
        snapshot.segmentationVariants = count(SegmentationVariantRecord.self)
        snapshot.reviewCandidateRows = count(ReviewCandidateRecord.self)
        snapshot.pendingReviewCandidates = repos.pendingReviewCandidateCount()
        snapshot.corrections = count(CorrectionRecord.self)

        let storeURL = repos.container.configurations.first
            .flatMap { $0.isStoredInMemoryOnly || $0.url.path == "/dev/null" ? nil : $0.url }
        guard let storeURL else {
            snapshot.totalCells = fallbackCellCount(context)
            return snapshot
        }
        let measured = await Task.detached(priority: .utility) {
            LibraryStorageMeasurement.measure(storeURL: storeURL)
        }.value
        snapshot.storeBytes = measured.storeBytes
        snapshot.walBytes = measured.walBytes
        if let blobs = measured.blobs {
            snapshot.totalCells = blobs.cells
            snapshot.detectionsWithoutCellCount = blobs.detectionsWithoutCellCount
            snapshot.cellsDataBytes = blobs.detectionBlobBytes
            snapshot.variantCellsDataBytes = blobs.variantBlobBytes
        } else {
            snapshot.totalCells = fallbackCellCount(context)
        }
        snapshot.imagesFolderBytes = measured.images?.bytes
        snapshot.imagesFolderFiles = measured.images?.files
        snapshot.displayImagesFolderBytes = measured.displayImages?.bytes
        snapshot.thumbnailsFolderBytes = measured.thumbnails?.bytes
        snapshot.embeddingsFolderBytes = measured.embeddings?.bytes
        return snapshot
    }

    /// Integers only: `propertiesToFetch` leaves the cell data on disk.
    private static func fallbackCellCount(_ context: ModelContext) -> Int? {
        var descriptor = FetchDescriptor<DetectionRecord>()
        descriptor.propertiesToFetch = [\.cellCountSummary]
        guard let rows = try? context.fetch(descriptor) else { return nil }
        return rows.reduce(0) { $0 + max(0, $1.cellCountSummary) }
    }

    /// Plain-text section for the diagnostics report. Numbers only.
    nonisolated static func lines(_ s: LibrarySizeSnapshot, system: DiagnosticsSystemInfo) -> [String] {
        func number(_ value: Int) -> String { value < 0 ? "unavailable" : grouped(Int64(value)) }
        func bytes(_ value: Int64?) -> String {
            guard let value, value >= 0 else { return "unavailable" }
            return "\(megabytes(value)) MB (\(grouped(value)) bytes)"
        }
        var cells = s.totalCells.map(number) ?? "unavailable"
        if s.detectionsWithoutCellCount > 0 {
            cells += " (plus \(number(s.detectionsWithoutCellCount)) detections not yet counted)"
        }
        var images = bytes(s.imagesFolderBytes)
        if let files = s.imagesFolderFiles { images += " in \(number(files)) files" }
        let averageCells = (s.totalCells ?? 0) > 0 && s.detections > 0
            ? String(format: "%.0f", locale: Locale(identifier: "en_US_POSIX"), Double(s.totalCells ?? 0) / Double(s.detections))
            : "unavailable"
        let averageBlob = (s.cellsDataBytes ?? 0) > 0 && s.detections > 0
            ? "\(megabytes((s.cellsDataBytes ?? 0) / Int64(s.detections))) MB"
            : "unavailable"
        let memory = String(format: "%.0f GB", locale: Locale(identifier: "en_US_POSIX"),
                            Double(system.memoryBytes) / 1_073_741_824)
        return [
            "Library size (numbers only):",
            "Batches: \(number(s.batches))",
            "Images: \(number(s.images))",
            "Detections (analysed images): \(number(s.detections))",
            "Total cells: \(cells)",
            "Average cells per detection: \(averageCells)",
            "Saved alternative segmentations: \(number(s.segmentationVariants))",
            "Review-queue rows: \(number(s.reviewCandidateRows)) (still to review: \(number(s.pendingReviewCandidates)))",
            "Manual corrections: \(number(s.corrections))",
            "Database file (store.sqlite): \(bytes(s.storeBytes))",
            "Database write-ahead log (WAL): \(bytes(s.walBytes))",
            "Saved cell measurements and outlines: \(bytes(s.cellsDataBytes))",
            "Average per detection: \(averageBlob)",
            "Saved alternative segmentations data: \(bytes(s.variantCellsDataBytes))",
            "Images folder: \(images)",
            "Display copies folder: \(bytes(s.displayImagesFolderBytes))",
            "Thumbnails folder: \(bytes(s.thumbnailsFolderBytes))",
            "Embeddings cache: \(bytes(s.embeddingsFolderBytes))",
            "",
            "This Mac:",
            "App version: \(system.appVersion)",
            "macOS version: \(system.macOSVersion)",
            "Mac model: \(system.macModel)",
            "Memory: \(memory)",
            "Processor cores: \(system.processorCores)",
        ]
    }

    nonisolated private static func megabytes(_ value: Int64) -> String {
        String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), Double(value) / 1_000_000)
    }

    nonisolated private static func grouped(_ value: Int64) -> String {
        let digits = String(value.magnitude)
        var out = ""
        for (offset, character) in digits.enumerated() {
            if offset > 0, (digits.count - offset) % 3 == 0 { out.append(",") }
            out.append(character)
        }
        return value < 0 ? "-" + out : out
    }
}
