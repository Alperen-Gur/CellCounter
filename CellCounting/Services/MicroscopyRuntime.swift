import CryptoKit
import Foundation

/// Bundled, content-addressed runtime for the same microscopy engines used by
/// the desktop client and canonical operations. Never resolves an executable
/// from PATH, downloads a runtime, or replaces files held by detached workers.
enum MicroscopyRuntime {
    struct Configuration {
        let nodeURL: URL
        let workerURL: URL
        let manifestURL: URL
        let manifestHash: String
    }
    private struct Manifest: Decodable {
        struct Node: Decodable {
            let path: String
            let sha256: String
            let archiveSha256: String
            let platform: String
        }
        struct File: Decodable {
            let path: String
            let sha256: String
            let bytes: Int64
        }
        let schemaVersion: Int
        let engineVersion: String
        let nodeVersion: String
        let node: Node
        let entrypoint: String
        let files: [File]
    }
    private static var cached: Configuration?
    private static var cachedRoot: String?
    private static let pinnedNodeVersion = "24.22.0"
    private static var platform: String {
        #if arch(arm64)
        return "darwin-arm64"
        #else
        return "darwin-x64"
        #endif
    }

    static func stage(pythonDirectory: URL? = nil) throws -> Configuration {
        let runtimeDirectory = pythonDirectory ?? FileStore.shared.pythonDir
        if let cached, cachedRoot == runtimeDirectory.path { return cached }
        guard let resources = Bundle.main.resourceURL else { throw unavailable("The application has no resource directory.") }
        let bundleRoot = resources.appendingPathComponent("microscopy-runtime/" + platform, isDirectory: true)
        let manifestURL = bundleRoot.appendingPathComponent("microscopy-runtime.json")
        guard FileManager.default.isReadableFile(atPath: manifestURL.path) else {
            throw unavailable("This application build does not include its pinned microscopy runtime. Install a complete build or configure the canonical CLI with an explicit trusted runtime.")
        }
        let data = try boundedData(manifestURL, maximum: 1024 * 1024)
        let manifest: Manifest
        do { manifest = try JSONDecoder().decode(Manifest.self, from: data) }
        catch { throw unavailable("The bundled microscopy runtime manifest is unreadable. Reinstall the application.") }
        guard manifest.schemaVersion == 1, manifest.nodeVersion == pinnedNodeVersion || manifest.nodeVersion == "v" + pinnedNodeVersion,
              !manifest.engineVersion.isEmpty, manifest.files.count <= 256,
              validHash(manifest.node.sha256), validHash(manifest.node.archiveSha256),
              manifest.node.platform == platform else {
            throw unavailable("The bundled microscopy runtime version or platform is unsupported.")
        }
        let identity = digest(data)
        var names: Set<String> = ["microscopy-runtime.json"]
        var total: Int64 = 0
        for file in manifest.files {
            guard validPath(file.path), names.insert(file.path).inserted, validHash(file.sha256), file.bytes >= 0, file.bytes <= 8 * 1024 * 1024 else {
                throw unavailable("The bundled microscopy runtime contains an invalid or duplicate asset.")
            }
            total += file.bytes
        }
        guard total <= 64 * 1024 * 1024, validPath(manifest.node.path), !names.contains(manifest.node.path),
              validPath(manifest.entrypoint), names.contains(manifest.entrypoint) else {
            throw unavailable("The bundled microscopy runtime exceeds its asset bounds or lacks its entry point.")
        }
        try verify(directory: bundleRoot, manifest: manifest)
        let fm = FileManager.default
        let snapshots = runtimeDirectory.appendingPathComponent("microscopy-runtimes", isDirectory: true)
        try fm.createDirectory(at: snapshots, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let canonical = snapshots.appendingPathComponent(identity, isDirectory: true)
        func configuration(_ root: URL) -> Configuration {
            Configuration(nodeURL: root.appendingPathComponent(manifest.node.path), workerURL: root.appendingPathComponent(manifest.entrypoint),
                          manifestURL: root.appendingPathComponent("microscopy-runtime.json"), manifestHash: identity)
        }
        if (try? boundedData(canonical.appendingPathComponent("microscopy-runtime.json"), maximum: 1024 * 1024)) == data,
           (try? verify(directory: canonical, manifest: manifest)) != nil {
            let result = configuration(canonical); cached = result; cachedRoot = runtimeDirectory.path; return result
        }
        let destination = fm.fileExists(atPath: canonical.path) ? snapshots.appendingPathComponent(identity + "-" + UUID().uuidString) : canonical
        let temporary = snapshots.appendingPathComponent(".stage-" + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: temporary, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: temporary) }
        for path in manifest.files.map(\.path) + [manifest.node.path] {
            let target = temporary.appendingPathComponent(path)
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try fm.copyItem(at: bundleRoot.appendingPathComponent(path), to: target)
            try fm.setAttributes([.posixPermissions: path == manifest.node.path ? 0o500 : 0o400], ofItemAtPath: target.path)
        }
        try data.write(to: temporary.appendingPathComponent("microscopy-runtime.json"), options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o400], ofItemAtPath: temporary.appendingPathComponent("microscopy-runtime.json").path)
        try verify(directory: temporary, manifest: manifest)
        do { try fm.moveItem(at: temporary, to: destination) }
        catch {
            guard (try? boundedData(destination.appendingPathComponent("microscopy-runtime.json"), maximum: 1024 * 1024)) == data,
                  (try? verify(directory: destination, manifest: manifest)) != nil else { throw error }
        }
        try fm.setAttributes([.posixPermissions: 0o500], ofItemAtPath: destination.path)
        let result = configuration(destination); cached = result; cachedRoot = runtimeDirectory.path; return result
    }

    private static func verify(directory: URL, manifest: Manifest) throws {
        for file in manifest.files {
            let url = try containedFile(file.path, in: directory)
            let bytes = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? -1
            guard Int64(bytes) == file.bytes, try fileDigest(url, maximum: 8 * 1024 * 1024) == file.sha256 else {
                throw unavailable("Microscopy runtime asset verification failed for \(file.path). Reinstall a complete application build.")
            }
        }
        let node = try containedFile(manifest.node.path, in: directory)
        guard FileManager.default.isExecutableFile(atPath: node.path), try fileDigest(node, maximum: 512 * 1024 * 1024) == manifest.node.sha256 else {
            throw unavailable("The pinned microscopy executable does not match its retained identity.")
        }
    }
    private static func containedFile(_ path: String, in root: URL) throws -> URL {
        let file = root.appendingPathComponent(path)
        let resolvedRoot = root.resolvingSymlinksInPath().path + "/"
        let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              file.resolvingSymlinksInPath().path.hasPrefix(resolvedRoot) else {
            throw unavailable("The microscopy runtime asset is not a contained regular file: \(path).")
        }
        return file
    }
    private static func validPath(_ path: String) -> Bool {
        !path.isEmpty && !path.hasPrefix("/") && !path.contains("\\") && !path.contains("\0") &&
            path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }
    private static func validHash(_ hash: String) -> Bool { hash.count == 64 && hash.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) } }
    private static func boundedData(_ url: URL, maximum: Int) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: maximum + 1) ?? Data()
        guard data.count <= maximum else { throw unavailable("The microscopy runtime metadata exceeds its size limit.") }
        return data
    }
    private static func fileDigest(_ url: URL, maximum: Int64) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256(); var count: Int64 = 0
        while let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty {
            count += Int64(data.count)
            guard count <= maximum else { throw unavailable("The microscopy runtime file exceeds its size limit.") }
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
    private static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private static func unavailable(_ message: String) -> WorkbenchFailure { WorkbenchFailure(code: "microscopy-runtime-unavailable", message: message) }
}
