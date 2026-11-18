import Foundation
import SQLite3

/// One-time safety copy of a library's database before this version upgrades
/// it: to keep detection cells in `StoredCellsRecord`, or to give each image
/// its own pixel scale (`ImageRecord.scalePxPerUm` and related columns).
///
/// Older CellCounter versions can still open an upgraded library, but doing
/// so silently drops the moved cells and the per-image scales. The copy, taken
/// before the store is first opened by this version, is what a user restores
/// to go back. It is made only while no connection to the store is open, is
/// verified before it counts, and never replaces an existing file. When it
/// cannot be made, the store must not be opened (and so not upgraded).
nonisolated enum LibraryStoreBackup {
    /// Present once a store has been opened by this version.
    static let upgradedTable = "ZSTOREDCELLSRECORD"
    /// Present in every store that holds detections.
    static let detectionTable = "ZDETECTIONRECORD"
    /// Images, and the column the per-image scale upgrade adds to them.
    static let imageTable = "ZIMAGERECORD"
    static let imageScaleColumn = "ZSCALEPXPERUM"
    static let namePrefix = "store-before-upgrade-"

    enum Outcome: Equatable {
        /// No store yet, already upgraded, or nothing the upgrade changes.
        case notNeeded
        /// The verified copy of `store.sqlite`; `-wal`/`-shm` copies sit beside it.
        case created(URL)
        /// Plain-language reason; the store was left untouched.
        case failed(String)
    }

    struct Failure: Error {
        let reason: String
    }

    /// Copies the store into `backupsDir` if it predates the cell storage
    /// table. Call before any SQLite connection to the store is open.
    static func makeIfNeeded(storeURL: URL, backupsDir: URL, now: Date = Date(),
                             fileManager fm: FileManager = .default) -> Outcome {
        guard fm.fileExists(atPath: storeURL.path) else { return .notNeeded }
        switch inspect(storeURL) {
        case .some(let tables):
            // An empty file or a store without detections has nothing to lose.
            guard tables.contains(detectionTable) else { return .notNeeded }
            let needsCellStorage = !tables.contains(upgradedTable)
            // Unknown columns count as "not yet upgraded": copying is the safe side.
            let needsImageScale = tables.contains(imageTable)
                && !(columns(of: imageTable, in: storeURL)?.contains(imageScaleColumn) ?? false)
            guard needsCellStorage || needsImageScale else { return .notNeeded }
        case .none:
            // Unreadable here means unknown: copy it anyway. If the copy cannot
            // be verified either, the store is not opened.
            break
        }
        do {
            return .created(try copy(storeURL: storeURL, into: backupsDir, now: now, fileManager: fm))
        } catch let failure as Failure {
            return .failed(failure.reason)
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    /// Names of the store's tables, read through a read-only connection that
    /// is closed before returning. Nil when the file cannot be read as SQLite.
    static func inspect(_ storeURL: URL) -> Set<String>? {
        var database: OpaquePointer?
        guard sqlite3_open_v2(storeURL.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            if let database { sqlite3_close(database) }
            return nil
        }
        defer { sqlite3_close(database) }
        sqlite3_busy_timeout(database, 2_000)
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "SELECT name FROM sqlite_master WHERE type = 'table'",
                                 -1, &statement, nil) == SQLITE_OK else {
            sqlite3_finalize(statement)
            return nil
        }
        defer { sqlite3_finalize(statement) }
        var tables = Set<String>()
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { return tables }
            guard step == SQLITE_ROW else { return nil }
            if let name = sqlite3_column_text(statement, 0) { tables.insert(String(cString: name)) }
        }
    }

    /// Column names of `table`, read like `inspect`. Nil when unreadable.
    static func columns(of table: String, in storeURL: URL) -> Set<String>? {
        var database: OpaquePointer?
        guard sqlite3_open_v2(storeURL.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            if let database { sqlite3_close(database) }
            return nil
        }
        defer { sqlite3_close(database) }
        sqlite3_busy_timeout(database, 2_000)
        // `table` is one of this type's constants, never user input.
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "PRAGMA table_info(\(table))", -1, &statement, nil) == SQLITE_OK else {
            sqlite3_finalize(statement)
            return nil
        }
        defer { sqlite3_finalize(statement) }
        var names = Set<String>()
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { return names }
            guard step == SQLITE_ROW else { return nil }
            // table_info rows: cid, name, type, notnull, dflt_value, pk.
            if let name = sqlite3_column_text(statement, 1) { names.insert(String(cString: name)) }
        }
    }

    /// True when the database at `url` passes SQLite's quick check.
    static func passesQuickCheck(_ url: URL) -> Bool {
        var database: OpaquePointer?
        guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            if let database { sqlite3_close(database) }
            return false
        }
        defer { sqlite3_close(database) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "PRAGMA quick_check", -1, &statement, nil) == SQLITE_OK else {
            sqlite3_finalize(statement)
            return false
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW, let text = sqlite3_column_text(statement, 0) else { return false }
        return String(cString: text) == "ok" && sqlite3_step(statement) == SQLITE_DONE
    }

    /// `store-before-upgrade-2026-11-17-091500`, with `-2`, `-3`… when
    /// a backup of that name (or one of its sidecars) already exists.
    static func backupBaseName(in backupsDir: URL, now: Date, fileManager fm: FileManager = .default) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        let stem = namePrefix + formatter.string(from: now)
        var candidate = stem
        var counter = 1
        while ["", "-wal", "-shm"].contains(where: {
            fm.fileExists(atPath: backupsDir.appendingPathComponent(candidate + ".sqlite" + $0).path)
        }) {
            counter += 1
            candidate = "\(stem)-\(counter)"
        }
        return candidate
    }

    private static func copy(storeURL: URL, into backupsDir: URL, now: Date,
                             fileManager fm: FileManager) throws -> URL {
        do {
            try fm.createDirectory(at: backupsDir, withIntermediateDirectories: true)
        } catch {
            throw Failure(reason: "the folder \(backupsDir.path) could not be created: \(error.localizedDescription)")
        }
        // Leftovers of an interrupted attempt are never valid backups.
        if let leftovers = try? fm.contentsOfDirectory(at: backupsDir, includingPropertiesForKeys: nil) {
            for url in leftovers where url.lastPathComponent.hasPrefix(".incomplete-") {
                try? fm.removeItem(at: url)
            }
        }
        let staging = backupsDir.appendingPathComponent(".incomplete-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: staging) }
        let stagedStore = staging.appendingPathComponent(LibraryLayout.storeFileName)
        var staged: [(suffix: String, url: URL)] = []
        do {
            try fm.createDirectory(at: staging, withIntermediateDirectories: false)
            for suffix in ["", "-wal", "-shm"] {
                let source = URL(fileURLWithPath: storeURL.path + suffix)
                guard suffix.isEmpty || fm.fileExists(atPath: source.path) else { continue }
                let target = URL(fileURLWithPath: stagedStore.path + suffix)
                try fm.copyItem(at: source, to: target)
                guard let sourceSize = size(of: source, fm), sourceSize == size(of: target, fm) else {
                    throw Failure(reason: "the copy of \(source.lastPathComponent) is incomplete")
                }
                staged.append((suffix, target))
            }
        } catch let failure as Failure {
            throw failure
        } catch {
            throw Failure(reason: "the database could not be copied: \(error.localizedDescription)")
        }
        guard passesQuickCheck(stagedStore) else {
            throw Failure(reason: "the copy did not pass SQLite’s integrity check, so the database itself may be damaged")
        }
        // Opening the copy may have created its index file; keep the set together.
        let stagedShm = URL(fileURLWithPath: stagedStore.path + "-shm")
        if !staged.contains(where: { $0.suffix == "-shm" }), fm.fileExists(atPath: stagedShm.path) {
            staged.append(("-shm", stagedShm))
        }

        let base = backupBaseName(in: backupsDir, now: now, fileManager: fm)
        let final = backupsDir.appendingPathComponent(base + ".sqlite")
        var moved: [URL] = []
        do {
            for item in staged {
                let destination = URL(fileURLWithPath: final.path + item.suffix)
                // `moveItem` fails rather than replace an existing file.
                try fm.moveItem(at: item.url, to: destination)
                moved.append(destination)
            }
        } catch {
            for url in moved { try? fm.removeItem(at: url) }
            throw Failure(reason: "the copy could not be saved in \(backupsDir.path): \(error.localizedDescription)")
        }
        return final
    }

    private static func size(of url: URL, _ fm: FileManager) -> Int64? {
        (try? fm.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value
    }

    // MARK: - Messages

    /// Shown once, after a copy was made and the library was upgraded.
    static func notice(for backup: URL) -> String {
        "Cellographer has upgraded this library (compact cell outlines and a pixel scale for each image). "
            + "Before doing so it saved a copy of the library’s database at \(backup.path). "
            + "Do not open this library with an older version of Cellographer or CellCounter from now on: "
            + "it would drop data saved in the new format. To go back to an older "
            + "version, quit Cellographer and put the copy in place of store.sqlite first "
            + "(work done since the upgrade would be lost)."
    }

    /// Why the library was not opened when the copy could not be made.
    static func failureMessage(_ reason: String) -> String {
        "Before upgrading this library, Cellographer saves a safety copy of its database, "
            + "and that copy could not be made (\(reason)). The library was not opened and "
            + "nothing in it has changed. If the disk is full or the folder is read-only, fix "
            + "that and restart Cellographer."
    }
}
