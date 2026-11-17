import Foundation
import CryptoKit
import Darwin

/// A source file's size and modification time at the moment its SHA-256 was
/// taken. Import reuses that hash only while the file still reports both.
nonisolated struct ImportFileStamp: Codable, Sendable, Hashable {
    var size: Int64
    var modifiedSeconds: Int64
    var modifiedNanoseconds: Int64
}

extension ImportFileStamp {
    /// The file's current size and modification time (symbolic links are
    /// followed, as when the file is read). Nil when it can't be examined.
    /// Uses `stat` directly: `URL.resourceValues` caches values on the URL.
    nonisolated init?(fileAt url: URL) {
        var info = stat()
        let found = url.withUnsafeFileSystemRepresentation { path in
            path.map { stat($0, &info) == 0 } ?? false
        }
        guard found else { return nil }
        self.init(size: Int64(info.st_size),
                  modifiedSeconds: Int64(info.st_mtimespec.tv_sec),
                  modifiedNanoseconds: Int64(info.st_mtimespec.tv_nsec))
    }
}

/// A hash taken when files are dropped, with the stamp that lets the later
/// copy reuse it.
nonisolated struct ImportSourceDigest: Sendable, Equatable {
    let hash: String
    /// Nil when the file changed while it was being read; the import then
    /// hashes the bytes it copies instead of reusing `hash`.
    let stamp: ImportFileStamp?
}

/// Hashing and copying for import. Files are read in fixed-size chunks, so
/// memory use does not depend on the file's size or on the volume it is on.
/// Hashes are lowercase hex SHA-256 of the file bytes, the encoding stored in
/// `ImageRecord.fileHash`.
nonisolated enum ImportFileDigest {
    static let chunkSize = 8 * 1_024 * 1_024

    static func hex(_ digest: SHA256.Digest) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }

    /// SHA-256 of the file at `url`; nil if it can't be read.
    static func sha256Hex(of url: URL, chunkSize: Int = chunkSize) -> String? {
        guard let input = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? input.close() }
        var hasher = SHA256()
        do {
            try forEachChunk(of: input, chunkSize: chunkSize) { hasher.update(data: $0) }
        } catch {
            return nil
        }
        return hex(hasher.finalize())
    }

    /// The hash of the file plus its stamp. The stamp is kept only when the
    /// file reported the same size and modification time before and after
    /// it was read.
    static func digest(of url: URL, chunkSize: Int = chunkSize) -> ImportSourceDigest? {
        let before = ImportFileStamp(fileAt: url)
        guard let hash = sha256Hex(of: url, chunkSize: chunkSize) else { return nil }
        let after = ImportFileStamp(fileAt: url)
        return ImportSourceDigest(hash: hash, stamp: before != nil && before == after ? before : nil)
    }

    /// Copies `source` to `destination` (which must not exist) and returns
    /// the SHA-256 of the stored copy.
    ///
    /// When `knownHash` was taken from this source and the source still has
    /// `knownStamp`'s size and modification time before and after the copy,
    /// `knownHash` is returned and the file is not read again. Otherwise the
    /// copy is hashed in the same pass that writes it.
    static func copy(_ source: URL, to destination: URL,
                     knownHash: String?, knownStamp: ImportFileStamp?,
                     chunkSize: Int = chunkSize) throws -> String {
        guard let knownHash, let knownStamp, ImportFileStamp(fileAt: source) == knownStamp else {
            return try copyAndHash(from: source, to: destination, chunkSize: chunkSize)
        }
        try FileManager.default.copyItem(at: source, to: destination)
        if ImportFileStamp(fileAt: source) == knownStamp { return knownHash }
        // The source changed during the copy: hash what was stored.
        if let hash = sha256Hex(of: destination, chunkSize: chunkSize) { return hash }
        try? FileManager.default.removeItem(at: destination)
        throw CocoaError(.fileReadUnknown, userInfo: [NSFilePathErrorKey: destination.path])
    }

    /// Copies `source` to `destination` (which must not exist) and returns
    /// the SHA-256 of the bytes stored there.
    ///
    /// On a volume that supports it the copy is a clone (as
    /// `FileManager.copyItem` makes there), so it shares the source's blocks
    /// and only reading is needed to hash it. Otherwise each chunk is
    /// written and hashed in a single pass, and the source's permissions,
    /// dates, ACLs and extended attributes are copied afterwards, like
    /// `FileManager.copyItem` does. A failed copy leaves no destination.
    static func copyAndHash(from source: URL, to destination: URL,
                            chunkSize: Int = chunkSize, allowClone: Bool = true) throws -> String {
        if allowClone, clone(source, to: destination) {
            if let hash = sha256Hex(of: destination, chunkSize: chunkSize) { return hash }
            try? FileManager.default.removeItem(at: destination)
            throw CocoaError(.fileReadUnknown, userInfo: [NSFilePathErrorKey: destination.path])
        }
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        let output = try createExclusively(destination)
        var hasher = SHA256()
        var failure: Error?
        do {
            try forEachChunk(of: input, chunkSize: chunkSize) { chunk in
                try output.write(contentsOf: chunk)
                hasher.update(data: chunk)
            }
        } catch {
            failure = error
        }
        do { try output.close() } catch { failure = failure ?? error }
        if let failure {
            try? FileManager.default.removeItem(at: destination)
            throw failure
        }
        copyMetadata(from: source, to: destination)
        return hex(hasher.finalize())
    }

    // MARK: - Private

    private static func forEachChunk(of handle: FileHandle, chunkSize: Int,
                                     _ body: (Data) throws -> Void) throws {
        let size = max(1, chunkSize)
        while true {
            let more = try autoreleasepool { () throws -> Bool in
                guard let chunk = try handle.read(upToCount: size), !chunk.isEmpty else { return false }
                try body(chunk)
                return true
            }
            guard more else { return }
        }
    }

    private static func clone(_ source: URL, to destination: URL) -> Bool {
        source.withUnsafeFileSystemRepresentation { from in
            destination.withUnsafeFileSystemRepresentation { to in
                guard let from, let to else { return false }
                return clonefile(from, to, 0) == 0
            }
        }
    }

    private static func createExclusively(_ url: URL) throws -> FileHandle {
        let (descriptor, code) = url.withUnsafeFileSystemRepresentation { path -> (Int32, Int32) in
            guard let path else { return (-1, EINVAL) }
            let descriptor = open(path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o644)
            return (descriptor, descriptor >= 0 ? 0 : errno)
        }
        guard descriptor >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(code),
                          userInfo: [NSFilePathErrorKey: url.path])
        }
        return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    }

    private static func copyMetadata(from source: URL, to destination: URL) {
        let flags = copyfile_flags_t(COPYFILE_ACL) | copyfile_flags_t(COPYFILE_STAT)
            | copyfile_flags_t(COPYFILE_XATTR)
        _ = source.withUnsafeFileSystemRepresentation { from in
            destination.withUnsafeFileSystemRepresentation { to in
                guard let from, let to else { return Int32(-1) }
                return copyfile(from, to, nil, flags)
            }
        }
    }
}
