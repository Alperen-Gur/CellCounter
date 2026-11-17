import Foundation
import SQLite3
import SwiftData
import Testing
@testable import CellCounting

/// The store as written before `StoredCellsRecord` existed: detection cells
/// inline in `cellsData`. Nested so its entity name is still
/// `DetectionRecord`, like a library saved by an older CellCounter.
enum PreCellStorageModels {
    @Model
    final class DetectionRecord {
        var runSettingsData: Data? = nil
        @Attribute(.unique) var id: UUID
        var detectorId: String
        var ranAt: Date
        var cellsData: Data
        var minConfidence: Double
        var cellCountSummary: Int = -1
        var cellsRevision: Int = 0
        var reviewPendingCount: Int = -1
        var reviewIndexVersion: Int = 0
        var imageStatsData: Data?

        init(cellsData: Data) {
            self.id = UUID()
            self.detectorId = "Cellpose/cp-cyto3"
            self.ranAt = Date()
            self.cellsData = cellsData
            self.minConfidence = 0.5
            self.cellCountSummary = 2
        }
    }
}

/// One-time safety copy of a library's database before this version upgrades
/// it. Every test works in its own temporary folder.
@Suite(.serialized) @MainActor
struct LibraryStoreBackupTests {
    private let cells = DetectionRecord.encodePlainCellsJSON([
        DetectedCell(cx: 10, cy: 12, diameter: 4, diameterPx: 8, confidence: 0.5),
        DetectedCell(cx: 30, cy: 32, diameter: 5, diameterPx: 10, confidence: 0.9),
    ])
    private let fixedNow = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private func makeLibrary() throws -> LibraryLayout {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cc-store-backup-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return LibraryLayout(root: root)
    }

    private func makePreUpgradeStore(_ layout: LibraryLayout) throws {
        let schema = Schema([PreCellStorageModels.DetectionRecord.self])
        let container = try ModelContainer(for: schema, configurations: [
            ModelConfiguration("CellCounter", schema: schema, url: layout.storeURL)])
        let context = ModelContext(container)
        context.insert(PreCellStorageModels.DetectionRecord(cellsData: cells))
        try context.save()
    }

    private func backupFiles(_ layout: LibraryLayout) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: layout.backupsDir.path)) ?? [])
            .filter { $0.hasSuffix(".sqlite") }.sorted()
    }

    @Test func oldStoreIsCopiedOnceThenUpgraded() throws {
        let layout = try makeLibrary()
        defer { try? FileManager.default.removeItem(at: layout.root) }
        try makePreUpgradeStore(layout)
        #expect(LibraryStoreBackup.inspect(layout.storeURL)?.contains(LibraryStoreBackup.upgradedTable) == false)

        let backup: URL
        do {
            let opened = Repositories.openOnDiskStore(at: layout, schema: Repositories.librarySchema(), now: fixedNow)
            let container = try #require(opened.container)
            #expect(opened.error == nil)
            backup = try #require(opened.backupURL)
            #expect(backup.deletingLastPathComponent().standardizedFileURL == layout.backupsDir.standardizedFileURL)
            #expect(backup.lastPathComponent.hasPrefix(LibraryStoreBackup.namePrefix))
            // The upgraded store still reads the cells written inline before.
            let detection = try #require(try ModelContext(container).fetch(FetchDescriptor<DetectionRecord>()).first)
            #expect(detection.cellsStorage == nil)
            #expect(detection.cellsData == cells)
        }
        // The copy is a readable database in the old layout.
        #expect(LibraryStoreBackup.passesQuickCheck(backup))
        let tables = try #require(LibraryStoreBackup.inspect(backup))
        #expect(tables.contains(LibraryStoreBackup.detectionTable))
        #expect(!tables.contains(LibraryStoreBackup.upgradedTable))
        #expect(LibraryStoreBackup.inspect(layout.storeURL)?.contains(LibraryStoreBackup.upgradedTable) == true)

        // Opening the upgraded store again makes no further copy.
        let again = Repositories.openOnDiskStore(at: layout, schema: Repositories.librarySchema(),
                                                 now: fixedNow.addingTimeInterval(60))
        #expect(again.container != nil && again.backupURL == nil)
        #expect(backupFiles(layout) == [backup.lastPathComponent])
    }

    @Test func storeWithTheNewTableAndMissingStoreAreNotCopied() throws {
        let layout = try makeLibrary()
        defer { try? FileManager.default.removeItem(at: layout.root) }
        #expect(LibraryStoreBackup.makeIfNeeded(storeURL: layout.storeURL, backupsDir: layout.backupsDir) == .notNeeded)

        let schema = Repositories.librarySchema()
        do {
            let container = try ModelContainer(for: schema, configurations: [
                ModelConfiguration("CellCounter", schema: schema, url: layout.storeURL)])
            try ModelContext(container).save()
        }
        let opened = Repositories.openOnDiskStore(at: layout, schema: schema, now: fixedNow)
        #expect(opened.container != nil && opened.backupURL == nil && opened.error == nil)
        #expect(!FileManager.default.fileExists(atPath: layout.backupsDir.path))
    }

    @Test func failedCopyLeavesTheStoreUnopenedAndUnchanged() throws {
        let layout = try makeLibrary()
        defer { try? FileManager.default.removeItem(at: layout.root) }
        try makePreUpgradeStore(layout)
        // A file where the Backups folder should go makes the copy fail.
        try Data("not a folder".utf8).write(to: layout.backupsDir)

        let opened = Repositories.openOnDiskStore(at: layout, schema: Repositories.librarySchema(), now: fixedNow)
        #expect(opened.container == nil && opened.backupURL == nil)
        #expect(opened.error?.contains("safety copy") == true)
        // Not opened, so not upgraded: old tables and column, same cells.
        let tables = try #require(LibraryStoreBackup.inspect(layout.storeURL))
        #expect(tables.contains(LibraryStoreBackup.detectionTable))
        #expect(!tables.contains(LibraryStoreBackup.upgradedTable))
        #expect(inlineCells(layout.storeURL, column: "ZCELLSDATA") == [cells])
        #expect(inlineCells(layout.storeURL, column: "ZLEGACYCELLSDATA") == nil)
        #expect(try Data(contentsOf: layout.backupsDir) == Data("not a folder".utf8))
    }

    /// The inline cell blobs of every detection row, read with SQLite
    /// directly; nil when the column does not exist.
    private func inlineCells(_ store: URL, column: String) -> [Data]? {
        var database: OpaquePointer?
        guard sqlite3_open_v2(store.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close(database)
            return nil
        }
        defer { sqlite3_close(database) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "SELECT \(column) FROM ZDETECTIONRECORD ORDER BY Z_PK",
                                 -1, &statement, nil) == SQLITE_OK else {
            sqlite3_finalize(statement)
            return nil
        }
        defer { sqlite3_finalize(statement) }
        var rows: [Data] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let count = Int(sqlite3_column_bytes(statement, 0))
            if let bytes = sqlite3_column_blob(statement, 0) { rows.append(Data(bytes: bytes, count: count)) }
            else { rows.append(Data()) }
        }
        return rows
    }

    @Test func anExistingBackupIsNeverOverwritten() throws {
        let layout = try makeLibrary()
        defer { try? FileManager.default.removeItem(at: layout.root) }
        try makePreUpgradeStore(layout)
        try FileManager.default.createDirectory(at: layout.backupsDir, withIntermediateDirectories: true)
        let taken = layout.backupsDir.appendingPathComponent(
            LibraryStoreBackup.backupBaseName(in: layout.backupsDir, now: fixedNow) + ".sqlite")
        try Data("earlier backup".utf8).write(to: taken)

        let first = LibraryStoreBackup.makeIfNeeded(storeURL: layout.storeURL, backupsDir: layout.backupsDir,
                                                    now: fixedNow)
        guard case .created(let made) = first else {
            Issue.record("Expected a backup, got \(first)")
            return
        }
        #expect(made.lastPathComponent != taken.lastPathComponent)
        #expect(made.deletingPathExtension().lastPathComponent.hasSuffix("-2"))
        #expect(try String(contentsOf: taken, encoding: .utf8) == "earlier backup")
        #expect(LibraryStoreBackup.passesQuickCheck(made))

        // Same second again (the store was not upgraded in between): a third name.
        let second = LibraryStoreBackup.makeIfNeeded(storeURL: layout.storeURL, backupsDir: layout.backupsDir,
                                                     now: fixedNow)
        guard case .created(let third) = second else {
            Issue.record("Expected a backup, got \(second)")
            return
        }
        #expect(third.deletingPathExtension().lastPathComponent.hasSuffix("-3"))
        #expect(backupFiles(layout).count == 3)
        #expect(try String(contentsOf: taken, encoding: .utf8) == "earlier backup")
    }
}
