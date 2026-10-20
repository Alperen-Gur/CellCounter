import CryptoKit
import Darwin
import Foundation
import SQLite3
import SwiftData

/// Read-only bridge from the native store to the canonical migration engine.
/// This entry point deliberately does not construct FileStore or Repositories:
/// both have normal application startup behavior that can write to a library.
@MainActor
enum NativeLibraryArchiveExporter {
    private static let maximumRecords = 100_000
    private static let maximumArchiveBytes = 64 * 1024 * 1024

    static func handleCommandLineIfRequested() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard arguments.contains("--workbench-archive-library") else { return }
        do {
            var root: String?, destination: String?
            var selected: [UUID] = []
            var index = 0
            while index < arguments.count {
                let flag = arguments[index]
                if flag == "--workbench-archive-library" { index += 1; continue }
                guard index + 1 < arguments.count else { throw failure("capture-arguments", "Missing value for \(flag).") }
                let value = arguments[index + 1]
                switch flag {
                case "--source-directory":
                    guard root == nil else { throw failure("capture-arguments", "Specify the library root once.") }
                    root = value
                case "--destination":
                    guard destination == nil else { throw failure("capture-arguments", "Specify the archive destination once.") }
                    destination = value
                case "--image-id":
                    guard let id = UUID(uuidString: value), !selected.contains(id), selected.count < 1000 else {
                        throw failure("capture-arguments", "Image IDs must be distinct UUIDs; select at most 1000 images.")
                    }
                    selected.append(id)
                default: throw failure("capture-arguments", "Unsupported capture argument: \(flag).")
                }
                index += 2
            }
            guard let root, let destination, root.hasPrefix("/"), destination.hasPrefix("/") else {
                throw failure("capture-arguments", "Use absolute --source-directory and --destination paths.")
            }
            let result = try capture(root: URL(fileURLWithPath: root), destination: URL(fileURLWithPath: destination), selected: selected)
            writeResponse(result)
            Darwin.exit(0)
        } catch {
            let error = error as? WorkbenchFailure ?? failure("capture-failed", error.localizedDescription)
            writeResponse(["ok": false, "error": ["code": error.code, "message": error.message]])
            Darwin.exit(1)
        }
    }

    private static func writeResponse(_ object: [String: Any]) {
        if let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) {
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write(Data([10]))
        }
    }

    private static func failure(_ code: String, _ message: String) -> WorkbenchFailure {
        WorkbenchFailure(code: code, message: message)
    }

    private static func capture(root: URL, destination: URL, selected: [UUID]) throws -> [String: Any] {
        let fm = FileManager.default
        let root = root.standardizedFileURL.resolvingSymlinksInPath()
        let destination = destination.deletingLastPathComponent().resolvingSymlinksInPath().appendingPathComponent(destination.lastPathComponent).standardizedFileURL
        let evidence = destination.deletingPathExtension().appendingPathExtension("evidence")
        guard destination.pathExtension.lowercased() == "json", !fm.fileExists(atPath: destination.path),
              !fm.fileExists(atPath: evidence.path), fm.fileExists(atPath: destination.deletingLastPathComponent().path) else {
            throw failure("capture-destination", "Choose a new JSON archive in an existing folder. Its sibling .evidence folder must also be new.")
        }
        guard !destination.path.hasPrefix(root.path + "/") else {
            throw failure("capture-destination", "Save the archive outside the source library so capture cannot change the library.")
        }
        let sourceStore = root.appendingPathComponent("store.sqlite")
        guard fm.isReadableFile(atPath: sourceStore.path) else {
            throw failure("capture-source", "The selected library has no readable store.sqlite. Choose the CellCounter library root.")
        }
        try fm.createDirectory(at: evidence, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        // Keep owned evidence on failure so no captured research data is discarded.
        let snapshot = evidence.appendingPathComponent("store.sqlite")
        try snapshotSQLite(from: sourceStore, to: snapshot)
        let snapshotSize = (try fm.attributesOfItem(atPath: snapshot.path)[.size] as? NSNumber)?.int64Value ?? 0
        guard snapshotSize <= 512 * 1024 * 1024 else {
            throw failure("capture-limit", "The owned SQLite snapshot exceeds the 512 MiB evidence-member limit. It remains preserved in \(evidence.path).")
        }
        // Decode external-data blobs only from owned evidence. They remain
        // separate opaque files; source paths are never opened by SwiftData.
        for name in ["store.sqlite_SUPPORT", ".store.sqlite_SUPPORT"] {
            let sourceSupport = root.appendingPathComponent(name)
            if fm.fileExists(atPath: sourceSupport.path) {
                var supportFiles: [[String: Any]] = []
                try appendTree(sourceSupport, role: "other", root: root, files: &supportFiles)
                try fm.copyItem(at: sourceSupport, to: evidence.appendingPathComponent(name))
            }
        }
        let schema = Repositories.librarySchema()
        let configuration = ModelConfiguration("CellCounter", schema: schema, url: snapshot, allowsSave: false)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let encoder = RecordEncoder(context: context)
        let records = try encoder.encode()
        guard selected.allSatisfy({ encoder.imageIDs.contains($0) }) else {
            throw failure("capture-selection", "A selected image is absent from the consistent library snapshot. Refresh the library selection and capture again.")
        }
        let helper = try helperMetadata()
        var files = encoder.files(root: root)
        files.append(["role": "other", "path": snapshot.path, "relativePath": "native-store/store.sqlite", "required": true])
        // SwiftData external storage and store metadata remain opaque evidence.
        // Current entities keep inline blobs, but older stores may have sidecars.
        for name in ["store.sqlite_SUPPORT", ".store.sqlite_SUPPORT"] {
            let folder = evidence.appendingPathComponent(name)
            if fm.fileExists(atPath: folder.path) { try appendTree(folder, role: "other", root: evidence, files: &files) }
        }
        for name in ["Protocols", "Workspaces", "Embeddings"] {
            let folder = root.appendingPathComponent(name)
            if fm.fileExists(atPath: folder.path) {
                try appendTree(folder, role: name == "Workspaces" ? "workspace" : "other", root: root, files: &files)
            }
        }
        let jobs = root.appendingPathComponent("analysis-jobs.json")
        if fm.fileExists(atPath: jobs.path) { files.append(["role": "other", "path": jobs.path, "relativePath": "analysis-jobs.json", "required": false]) }
        guard files.count <= 10_000 else { throw failure("capture-limit", "This library references more than 10,000 evidence files. The original library and owned SQLite snapshot are preserved.") }
        var archive: [String: Any] = [
            "schemaVersion": 1, "kind": "cellcounter-native-library", "platform": "macos",
            "sourceDirectory": root.path, "createdAt": RecordEncoder.date(Date()),
            "records": records, "files": files, "helper": helper,
            "notes": ["All persisted records and available referenced evidence are retained, including records outside the selected image scope.",
                      "Native detections and variants contain historical contours and centres, not exact raster instance masks.",
                      "The raw SQLite backup preserves unknown stored fields. External workspace documents and unregistered model files must be retained separately if they are not referenced by this library."]
        ]
        if !selected.isEmpty { archive["selectedImageIds"] = selected.map(\.uuidString) }
        let data = try JSONSerialization.data(withJSONObject: archive, options: [.sortedKeys])
        guard data.count <= maximumArchiveBytes else {
            throw failure("capture-limit", "The complete record archive exceeds 64 MiB. Nothing was omitted; the owned SQLite snapshot remains in \(evidence.path).")
        }
        // Exclusive creation prevents a new file appearing during capture from
        // being overwritten. The canonical preview rejects incomplete JSON.
        let fd = Darwin.open(destination.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw failure("capture-destination", "The archive destination is no longer available. Choose a new path.") }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        try handle.write(contentsOf: data)
        try handle.synchronize()
        try handle.close()
        return ["ok": true, "archivePath": destination.path, "archiveHash": SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
                "platform": "macos", "imageCount": encoder.imageIDs.count, "recordCount": encoder.recordCount, "helper": helper]
    }

    private static func helperMetadata() throws -> [String: Any] {
        guard let executable = Bundle.main.executableURL else { throw failure("capture-helper", "Cannot identify the installed native capture helper.") }
        let handle = try FileHandle(forReadingFrom: executable)
        defer { try? handle.close() }
        var hash = SHA256()
        while let chunk = try handle.read(upToCount: 1024 * 1024), !chunk.isEmpty { hash.update(data: chunk) }
        return ["name": "CellCounter native library capture", "bundleIdentifier": Bundle.main.bundleIdentifier ?? "",
                "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
                "build": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown",
                "executableSha256": hash.finalize().map { String(format: "%02x", $0) }.joined(), "archiveSchemaVersion": 1]
    }

    private static func snapshotSQLite(from source: URL, to destination: URL) throws {
        var input: OpaquePointer?, output: OpaquePointer?
        guard sqlite3_open_v2(source.path, &input, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            if let input { sqlite3_close(input) }
            throw failure("capture-database", "The source SQLite store cannot be opened read-only.")
        }
        defer { sqlite3_close(input) }
        guard sqlite3_open_v2(destination.path, &output, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            if let output { sqlite3_close(output) }
            throw failure("capture-database", "Cannot create the owned SQLite snapshot.")
        }
        defer { sqlite3_close(output) }
        sqlite3_busy_timeout(input, 1000)
        sqlite3_busy_timeout(output, 1000)
        guard let backup = sqlite3_backup_init(output, "main", input, "main") else {
            throw failure("capture-database", "Cannot begin a consistent SQLite backup. Close active library operations and retry.")
        }
        var result = SQLITE_OK
        let deadline = Date().addingTimeInterval(90)
        repeat {
            result = sqlite3_backup_step(backup, 256)
            if result == SQLITE_BUSY || result == SQLITE_LOCKED { sqlite3_sleep(20) }
        } while (result == SQLITE_OK || result == SQLITE_BUSY || result == SQLITE_LOCKED) && Date() < deadline
        let finished = sqlite3_backup_finish(backup)
        guard result == SQLITE_DONE, finished == SQLITE_OK else {
            throw failure("capture-database", "The consistent SQLite backup could not finish within 90 seconds. Pause library jobs and retry with a new destination.")
        }
    }

    private static func appendTree(_ folder: URL, role: String, root: URL, files: inout [[String: Any]]) throws {
        let fm = FileManager.default
        let rootValues = try folder.resourceValues(forKeys: [.isSymbolicLinkKey])
        guard rootValues.isSymbolicLink != true else {
            throw failure("capture-evidence-link", "The evidence folder \(folder.path) is a symbolic link. Retain its target explicitly before migration; capture will not silently omit or traverse it.")
        }
        guard let enumerator = fm.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey], options: []) else {
            throw failure("capture-evidence", "Cannot enumerate evidence at \(folder.path).")
        }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            if values.isSymbolicLink == true {
                throw failure("capture-evidence-link", "The evidence path \(url.path) is a symbolic link. Retain its target explicitly before migration; capture will not silently omit or traverse it.")
            }
            if values.isRegularFile == true {
                let size = Int64(values.fileSize ?? 0)
                total += size
                guard size <= 512 * 1024 * 1024, total <= 4 * 1024 * 1024 * 1024 else {
                    throw failure("capture-limit", "Evidence exceeds the 512 MiB member or 4 GiB directory budget. Original files and the owned snapshot remain unchanged.")
                }
                guard files.count < 10_000 else { throw failure("capture-limit", "The library exceeds the 10,000 evidence-file limit.") }
                files.append(["role": role, "path": url.path, "relativePath": String(url.path.dropFirst(root.path.count + 1)), "required": false])
            }
        }
    }

    private final class RecordEncoder {
        let context: ModelContext
        var recordCount = 0
        var blobBytes = 0
        var imageIDs: Set<UUID> = []
        var images: [ImageRecord] = []
        var modelVersions: [ModelVersionRecord] = []
        init(context: ModelContext) { self.context = context }

        func rows<T: PersistentModel>(_ type: T.Type, encode: (T) throws -> [String: Any]) throws -> [[String: Any]] {
            var descriptor = FetchDescriptor<T>()
            descriptor.fetchLimit = maximumRecords - recordCount + 1
            let records = try context.fetch(descriptor)
            recordCount += records.count
            guard recordCount <= maximumRecords else { throw failure("capture-limit", "The library exceeds 100,000 persisted records. The SQLite snapshot remains preserved.") }
            return try records.map(encode)
        }
        static func optional<T>(_ value: T?) -> Any { value.map { $0 as Any } ?? NSNull() }
        static func uuid(_ value: UUID?) -> Any { optional(value?.uuidString) }
        static func date(_ value: Date) -> [String: Any] {
            ["dateReferenceSeconds": value.timeIntervalSinceReferenceDate, "iso8601": ISO8601DateFormatter().string(from: value)]
        }
        func blob(_ value: Data?) throws -> Any {
            guard let value else { return NSNull() }
            blobBytes += value.count
            guard blobBytes <= 46 * 1024 * 1024 else { throw failure("capture-limit", "Opaque record data exceeds the bounded JSON capture limit. The raw SQLite snapshot remains preserved; no record was silently omitted.") }
            return ["encoding": "base64", "data": value.base64EncodedString()]
        }
        func encode() throws -> [String: Any] {
            let optional: (String?) -> Any = { Self.optional($0) }
            var result: [String: Any] = [:]
            result["BatchRecord"] = try rows(BatchRecord.self) { r in [
                "id": r.id.uuidString, "name": r.name, "createdAt": Self.date(r.createdAt), "displayName": r.displayName,
                "modelId": r.modelId, "pxPerUm": r.pxPerUm, "thresholdsData": try blob(r.thresholdsData),
                "condition": optional(r.condition), "pxPerUmSource": optional(r.pxPerUmSource), "imageCountSummary": r.imageCountSummary,
                "cellCountSummary": r.cellCountSummary, "contentRevision": r.contentRevision, "insightsData": try blob(r.insightsData),
                "insightsRevision": r.insightsRevision, "images": r.images.map { $0.id.uuidString }] }
            result["ImageRecord"] = try rows(ImageRecord.self) { r in
                images.append(r); imageIDs.insert(r.id)
                return ["id": r.id.uuidString, "fileName": r.fileName, "originalPath": r.originalPath, "widthPx": r.widthPx, "heightPx": r.heightPx,
                        "importedAt": Self.date(r.importedAt), "sourcePxPerUm": Self.optional(r.sourcePxPerUm), "sourceCalibrationSource": optional(r.sourceCalibrationSource),
                        "jobItemId": Self.uuid(r.jobItemId), "sourceOrder": Self.optional(r.sourceOrder), "confidenceOverride": Self.optional(r.confidenceOverride),
                        "fileHash": optional(r.fileHash), "notes": optional(r.notes), "detection": Self.uuid(r.detection?.id),
                        "rois": r.rois.map { $0.id.uuidString }, "batch": Self.uuid(r.batch?.id)]
            }
            result["DetectionRecord"] = try rows(DetectionRecord.self) { r in [
                "id": r.id.uuidString, "runSettingsData": try blob(r.runSettingsData), "detectorId": r.detectorId, "ranAt": Self.date(r.ranAt),
                "cellsData": try blob(r.cellsData), "minConfidence": r.minConfidence, "cellCountSummary": r.cellCountSummary,
                "cellsRevision": r.cellsRevision, "reviewPendingCount": r.reviewPendingCount, "reviewIndexVersion": r.reviewIndexVersion,
                "imageStatsData": try blob(r.imageStatsData), "corrections": r.corrections.map { $0.id.uuidString }, "image": Self.uuid(r.image?.id)] }
            result["SegmentationVariantRecord"] = try rows(SegmentationVariantRecord.self) { r in [
                "id": r.id.uuidString, "imageId": r.imageId.uuidString, "detectorId": r.detectorId, "label": r.label, "createdAt": Self.date(r.createdAt),
                "cellsData": try blob(r.cellsData), "cellCount": r.cellCount, "meanConfidence": r.meanConfidence, "image": Self.uuid(r.image?.id),
                "measurementPxPerUm": Self.optional(r.measurementPxPerUm), "runSettingsData": try blob(r.runSettingsData),
                "imageStatsData": try blob(r.imageStatsData), "detectionRanAt": r.detectionRanAt.map(Self.date) as Any? ?? NSNull()] }
            result["ReviewCandidateRecord"] = try rows(ReviewCandidateRecord.self) { r in [
                "id": r.id.uuidString, "cellId": r.cellId.uuidString, "sortKey": r.sortKey, "detectionId": r.detectionId.uuidString,
                "imageId": r.imageId.uuidString, "confidence": r.confidence, "cx": r.cx, "cy": r.cy, "diameter": r.diameter,
                "diameterPx": r.diameterPx, "triaged": r.triaged, "createdAt": Self.date(r.createdAt),
                "detection": Self.uuid(r.detection?.id), "image": Self.uuid(r.image?.id)] }
            result["CorrectionRecord"] = try rows(CorrectionRecord.self) { r in [
                "id": r.id.uuidString, "kind": r.kind, "cellId": r.cellId.uuidString, "cx": r.cx, "cy": r.cy, "diameter": r.diameter,
                "createdAt": Self.date(r.createdAt), "detection": Self.uuid(r.detection?.id)] }
            result["CalibrationPresetRecord"] = try rows(CalibrationPresetRecord.self) { r in ["id": r.id.uuidString, "name": r.name, "pxPerUm": r.pxPerUm, "isDefault": r.isDefault] }
            result["BinPresetRecord"] = try rows(BinPresetRecord.self) { r in ["id": r.id.uuidString, "name": r.name, "thresholdsData": try blob(r.thresholdsData)] }
            result["ModelVersionRecord"] = try rows(ModelVersionRecord.self) { r in
                modelVersions.append(r)
                return ["id": r.id.uuidString, "modelId": r.modelId, "version": r.version, "createdAt": Self.date(r.createdAt),
                        "trainedOnImages": r.trainedOnImages, "trainedOnCorrections": r.trainedOnCorrections,
                        "checkpointPath": r.checkpointPath, "metricsData": try blob(r.metricsData)]
            }
            result["ROIRecord"] = try rows(ROIRecord.self) { r in [
                "id": r.id.uuidString, "imageId": r.imageId.uuidString, "kind": r.kind, "shape": r.shape, "x": r.x, "y": r.y,
                "width": r.width, "height": r.height, "createdAt": Self.date(r.createdAt), "name": optional(r.name), "image": Self.uuid(r.image?.id)] }
            result["ConditionRecord"] = try rows(ConditionRecord.self) { r in ["id": r.id.uuidString, "name": r.name, "color": r.color, "createdAt": Self.date(r.createdAt), "order": r.order] }
            result["GroundTruthAnnotation"] = try rows(GroundTruthAnnotation.self) { r in [
                "id": r.id.uuidString, "imageId": r.imageId.uuidString, "cx": r.cx, "cy": r.cy, "diameter": Self.optional(r.diameter),
                "createdAt": Self.date(r.createdAt), "note": optional(r.note)] }
            return result
        }

        func files(root: URL) -> [[String: Any]] {
            let fm = FileManager.default
            var files: [[String: Any]] = []
            for image in images {
                let ext = (image.fileName as NSString).pathExtension.lowercased()
                let original = "Images/\(image.id.uuidString).\(ext.isEmpty ? "tif" : ext)"
                files.append(["imageId": image.id.uuidString, "role": "original", "path": root.appendingPathComponent(original).path, "relativePath": original, "required": true])
                for (folder, role) in [("DisplayImages", "display"), ("Thumbnails", "other")] {
                    let relative = "\(folder)/\(image.id.uuidString).\(folder == "Thumbnails" ? "jpg" : "png")"
                    let url = root.appendingPathComponent(relative)
                    if fm.fileExists(atPath: url.path) { files.append(["imageId": image.id.uuidString, "role": role, "path": url.path, "relativePath": relative, "required": false]) }
                }
            }
            for model in modelVersions {
                let path = model.checkpointPath.hasPrefix("/") ? model.checkpointPath : root.appendingPathComponent("Models").appendingPathComponent(model.checkpointPath).path
                files.append(["role": "checkpoint", "path": path, "required": false])
            }
            return files
        }
    }
}
