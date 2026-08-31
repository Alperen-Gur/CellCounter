import Foundation

/// Background-only storage measurement used by Settings. The caller resolves
/// cheap model metadata on MainActor, then passes only immutable paths here.
enum ModelStorageInventory {
    struct Request: Sendable {
        let id: String
        let roots: [URL]
    }

    /// Measures every canonical root at most once, even when several catalog
    /// entries share a cache. Cancellation is checked during recursive walks
    /// so leaving Settings does not leave a large inventory running.
    nonisolated static func measure(_ requests: [Request]) async -> [String: Int64] {
        let worker = Task.detached(priority: .utility) { () -> [String: Int64] in
            var sizesByPath: [String: Int64] = [:]
            var result: [String: Int64] = [:]

            for request in requests {
                guard !Task.isCancelled else { return [String: Int64]() }
                var seen = Set<String>()
                var total: Int64 = 0
                for root in request.roots {
                    let canonical = root.resolvingSymlinksInPath().standardizedFileURL.path
                    guard seen.insert(canonical).inserted else { continue }
                    if let cached = sizesByPath[canonical] {
                        total += cached
                        continue
                    }
                    let measured = directorySize(at: URL(fileURLWithPath: canonical))
                    sizesByPath[canonical] = measured
                    total += measured
                }
                result[request.id] = total
            }
            return result
        }
        return await withTaskCancellationHandler {
            await worker.value
        } onCancel: {
            worker.cancel()
        }
    }

    nonisolated static func directorySize(
        at root: URL,
        fileManager fm: FileManager = .default
    ) -> Int64 {
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: root.path, isDirectory: &isDirectory) else { return 0 }
        if !isDirectory.boolValue {
            let values = try? root.resourceValues(forKeys: [
                .totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .fileSizeKey,
            ])
            return Int64(values?.totalFileAllocatedSize
                ?? values?.fileAllocatedSize
                ?? values?.fileSize
                ?? 0)
        }

        guard let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [
                .isRegularFileKey,
                .totalFileAllocatedSizeKey,
                .fileAllocatedSizeKey,
                .fileSizeKey,
            ],
            options: [.skipsHiddenFiles]) else { return 0 }

        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            if Task.isCancelled { return 0 }
            let values = try? fileURL.resourceValues(forKeys: [
                .isRegularFileKey,
                .totalFileAllocatedSizeKey,
                .fileAllocatedSizeKey,
                .fileSizeKey,
            ])
            guard values?.isRegularFile == true else { continue }
            total += Int64(values?.totalFileAllocatedSize
                ?? values?.fileAllocatedSize
                ?? values?.fileSize
                ?? 0)
        }
        return total
    }
}
