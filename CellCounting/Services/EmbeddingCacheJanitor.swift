import Foundation
import SwiftData

/// Cleans the library's `Embeddings/` folder, which prompt refinement fills
/// with `<imageId>-<model>.zarr` caches and nothing ever removed.
///
/// Rules:
/// - An entry whose name does not start with `<UUID>-` is not ours to judge
///   and is never deleted.
/// - An entry whose image id is not in the library is deleted.
/// - If the remaining entries exceed `byteCap`, the least recently used are
///   deleted until the total fits. "Used" is the newest modification date, or
///   file access date, found in the entry (the access date is best effort:
///   the file system may not update it on every read).
///
/// Every cache here is regenerated on demand, so a wrong deletion costs only
/// a recomputation. The image ids come from an id-only fetch; no cells are
/// ever decoded.
nonisolated enum EmbeddingCacheJanitor {
    /// Total size above which the least recently used caches are deleted.
    static let defaultByteCap: Int64 = 4 * 1_024 * 1_024 * 1_024

    struct Report: Sendable, Equatable {
        var orphansRemoved = 0
        var capRemoved = 0
        var bytesFreed: Int64 = 0
        var bytesKept: Int64 = 0
    }

    private struct Entry {
        let url: URL
        let imageID: UUID?
        let bytes: Int64
        let lastUsed: Date
    }

    /// Low-priority, off-main pass at launch. Skipped when the ids cannot be read.
    @MainActor
    static func runAtLaunch(container: ModelContainer,
                            embeddingsDirectory: URL,
                            byteCap: Int64 = defaultByteCap) {
        Task.detached(priority: .background) {
            guard let ids = imageIDs(container: container) else { return }
            _ = clean(directory: embeddingsDirectory, liveImageIDs: ids, byteCap: byteCap)
        }
    }

    /// Ids of every image in the library. Only `id` is fetched.
    static func imageIDs(container: ModelContainer) -> Set<UUID>? {
        let context = ModelContext(container)
        var descriptor = FetchDescriptor<ImageRecord>()
        descriptor.propertiesToFetch = [\.id]
        guard let rows = try? context.fetch(descriptor) else { return nil }
        return Set(rows.map(\.id))
    }

    /// The image id in an embedding cache name (`<UUID>-<model>.zarr`), or nil.
    static func imageID(fromFileName name: String) -> UUID? {
        guard name.count > 37 else { return nil }
        let prefix = name.prefix(36)
        guard name[name.index(name.startIndex, offsetBy: 36)] == "-" else { return nil }
        return UUID(uuidString: String(prefix))
    }

    @discardableResult
    static func clean(directory: URL, liveImageIDs: Set<UUID>, byteCap: Int64) -> Report {
        let fm = FileManager.default
        guard let children = try? fm.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]) else { return Report() }

        var report = Report()
        var kept: [Entry] = []
        for url in children {
            let id = imageID(fromFileName: url.lastPathComponent)
            if let id, !liveImageIDs.contains(id) {
                let (bytes, _) = usage(of: url)
                if (try? fm.removeItem(at: url)) != nil {
                    report.orphansRemoved += 1
                    report.bytesFreed += bytes
                }
                continue
            }
            let (bytes, lastUsed) = usage(of: url)
            kept.append(Entry(url: url, imageID: id, bytes: bytes, lastUsed: lastUsed))
        }

        var total = kept.reduce(Int64(0)) { $0 + $1.bytes }
        if total > byteCap {
            // Oldest first. Entries without a mappable id are never deleted.
            for entry in kept.filter({ $0.imageID != nil }).sorted(by: { $0.lastUsed < $1.lastUsed }) {
                guard total > byteCap else { break }
                if (try? fm.removeItem(at: entry.url)) != nil {
                    total -= entry.bytes
                    report.capRemoved += 1
                    report.bytesFreed += entry.bytes
                }
            }
        }
        report.bytesKept = total
        return report
    }

    /// Bytes below `url` and the newest modification or access date seen.
    private static func usage(of url: URL) -> (Int64, Date) {
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey,
                                      .contentModificationDateKey, .contentAccessDateKey]
        var newest = Date.distantPast
        // Modification dates of everything, access dates of files only: a
        // directory's own access date changes whenever it is listed, so it
        // says nothing about use.
        func note(_ values: URLResourceValues?) {
            var dates = [values?.contentModificationDate]
            if values?.isRegularFile == true { dates.append(values?.contentAccessDate) }
            for date in dates {
                if let date, date > newest { newest = date }
            }
        }
        let own = try? url.resourceValues(forKeys: Set(keys))
        note(own)
        if own?.isRegularFile == true { return (Int64(own?.fileSize ?? 0), newest) }
        var bytes: Int64 = 0
        if let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys) {
            for case let file as URL in enumerator {
                let values = try? file.resourceValues(forKeys: Set(keys))
                note(values)
                if values?.isRegularFile == true { bytes += Int64(values?.fileSize ?? 0) }
            }
        }
        return (bytes, newest)
    }
}
