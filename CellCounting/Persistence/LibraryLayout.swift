import Foundation

/// On-disk layout of one CellCounter library: a SwiftData store plus the image
/// files its records point at.
///
/// The default library is the legacy `~/Library/Application Support/CellCounter`
/// folder, so existing installs keep working without a migration. Additional
/// project libraries and batch archives use exactly the same layout inside
/// their own `<name>.cellcounterlibrary` folder. App-wide resources (Python
/// runtimes, model checkpoints, protocols) are NOT part of a library.
nonisolated struct LibraryLayout: Sendable, Hashable {
    static let packageExtension = "cellcounterlibrary"
    static let storeFileName = "store.sqlite"
    static let manifestFileName = "CellCounterLibrary.json"

    let root: URL

    init(root: URL) {
        self.root = root.standardizedFileURL
    }

    var storeURL: URL { root.appendingPathComponent(Self.storeFileName) }
    /// SQLite sidecar files that must travel with `storeURL` when copying.
    var storeSidecarURLs: [URL] {
        ["-wal", "-shm"].map { root.appendingPathComponent(Self.storeFileName + $0) }
    }
    var manifestURL: URL { root.appendingPathComponent(Self.manifestFileName) }
    var imagesDir: URL { root.appendingPathComponent("Images", isDirectory: true) }
    /// Lossless, flattened PNGs for vendor containers that AppKit cannot read.
    var displayImagesDir: URL { root.appendingPathComponent("DisplayImages", isDirectory: true) }
    var thumbsDir: URL { root.appendingPathComponent("Thumbnails", isDirectory: true) }
    /// Reusable prompt-model image embeddings. Safe to delete; regenerated on demand.
    var embeddingsDir: URL { root.appendingPathComponent("Embeddings", isDirectory: true) }
    var exportsDir: URL { root.appendingPathComponent("Exports", isDirectory: true) }
    /// Safety copies of the database made before an upgrade
    /// (`LibraryStoreBackup`). Created only when a copy is made.
    var backupsDir: URL { root.appendingPathComponent("Backups", isDirectory: true) }
    var analysisJobsURL: URL { root.appendingPathComponent("analysis-jobs.json") }

    func imageURL(for imageId: UUID, extension ext: String = "tif") -> URL {
        imagesDir.appendingPathComponent("\(imageId.uuidString).\(ext)")
    }

    func thumbURL(for imageId: UUID) -> URL {
        thumbsDir.appendingPathComponent("\(imageId.uuidString).jpg")
    }

    func displayImageURL(for imageId: UUID) -> URL {
        displayImagesDir.appendingPathComponent("\(imageId.uuidString).png")
    }

    /// Creates the library folders. Does not create or open the store.
    func createDirectories() throws {
        let fm = FileManager.default
        for dir in [root, imagesDir, displayImagesDir, thumbsDir, embeddingsDir, exportsDir] {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    /// A folder is a library when it holds a store. The manifest is optional:
    /// the default library predates it.
    static func isLibrary(at url: URL) -> Bool {
        FileManager.default.fileExists(atPath: LibraryLayout(root: url).storeURL.path)
    }

    func readManifest() -> LibraryManifest? {
        guard let data = try? Data(contentsOf: manifestURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(LibraryManifest.self, from: data)
    }

    func writeManifest(_ manifest: LibraryManifest) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(manifest).write(to: manifestURL, options: .atomic)
    }
}

/// Small human-readable description stored at the top of a library folder.
/// Kept deliberately flat so it stays readable in a text editor years later.
nonisolated struct LibraryManifest: Codable, Sendable, Equatable {
    enum Kind: String, Codable, Sendable {
        /// A normal working library the user opens and edits.
        case library
        /// A library produced by "Archive Batch…", holding one batch.
        case batchArchive = "batch-archive"
    }

    struct ArchivedBatch: Codable, Sendable, Equatable {
        var batchId: UUID
        var name: String
        var displayName: String
        var condition: String?
        var modelId: String
        var pxPerUm: Double
        var pxPerUmSource: String?
        var imageCount: Int
        var cellCount: Int
        var batchCreatedAt: Date
        var archivedAt: Date
        /// Path of the library the batch was archived from, for the user's reference only.
        var sourceLibraryPath: String?
    }

    var formatVersion: Int = 1
    var kind: Kind
    var name: String
    var createdAt: Date
    var appVersion: String
    var archivedBatch: ArchivedBatch?

    static var currentAppVersion: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }
}
