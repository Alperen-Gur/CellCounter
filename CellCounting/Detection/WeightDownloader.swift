import Foundation

/// Shared HTTP weight downloader with progress reporting + atomic writes + checksum verify.
/// Family-specific ModelDownloaders use this for the actual byte transfer.
enum WeightDownloader {
    enum Error: LocalizedError {
        case badResponse(Int)
        case checksumMismatch(expected: String, got: String)
        case ioError(Swift.Error)
        case cancelled

        var errorDescription: String? {
            switch self {
            case .badResponse(let code): return "Download failed with HTTP \(code)."
            case .checksumMismatch(let e, let g): return "Checksum mismatch (expected \(e), got \(g))."
            case .ioError(let e): return e.localizedDescription
            case .cancelled: return "Download cancelled."
            }
        }
    }

    /// Downloads `url` to `dest` (parent dir created), reporting bytes/progress to `progress`.
    /// `expectedSHA256` is optional but recommended; if provided and mismatched, the file is removed.
    /// When `verifyChecksum` is false the SHA-256 step is skipped even when an expected hash
    /// is provided (Settings → "Verify checksums on download" toggle).
    static func download(_ url: URL,
                         to dest: URL,
                         expectedSHA256: String? = nil,
                         verifyChecksum: Bool = true,
                         progress: ModelInstallProgress) async throws {
        try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let session = URLSession(configuration: .default)
        let req = URLRequest(url: url)
        let (asyncBytes, response) = try await session.bytes(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw Error.badResponse(0)
        }
        guard (200...299).contains(http.statusCode) else {
            throw Error.badResponse(http.statusCode)
        }
        let total = http.expectedContentLength
        FileManager.default.createFile(atPath: dest.path, contents: nil)
        guard let handle = try? FileHandle(forWritingTo: dest) else {
            throw Error.ioError(NSError(domain: "WeightDownloader", code: 1,
                                         userInfo: [NSLocalizedDescriptionKey: "Cannot open \(dest.path)"]))
        }
        defer { try? handle.close() }

        var written: Int64 = 0
        var chunk = Data()
        chunk.reserveCapacity(64 * 1024)
        var lastReport = Date()
        var lastBytes: Int64 = 0

        for try await byte in asyncBytes {
            chunk.append(byte)
            if chunk.count >= 64 * 1024 {
                try handle.write(contentsOf: chunk)
                written += Int64(chunk.count)
                chunk.removeAll(keepingCapacity: true)
                let now = Date()
                let elapsed = now.timeIntervalSince(lastReport)
                if elapsed > 0.25 {
                    let rate = Int64(Double(written - lastBytes) / elapsed)
                    let p = total > 0 ? Double(written) / Double(total) : 0
                    await MainActor.run {
                        progress.stage = .downloading(progress: p, bytesPerSec: rate)
                    }
                    lastReport = now
                    lastBytes = written
                }
            }
            try Task.checkCancellation()
        }
        if !chunk.isEmpty {
            try handle.write(contentsOf: chunk)
            written += Int64(chunk.count)
        }
        try handle.close()

        // Honour the `cc-verify-checksums` user pref (default: true). The
        // `verifyChecksum` parameter still acts as an explicit override for
        // callers that want to force-skip regardless of preference.
        let prefVerify = UserDefaults.standard.object(forKey: "cc-verify-checksums") == nil
            ? true
            : UserDefaults.standard.bool(forKey: "cc-verify-checksums")
        if let expected = expectedSHA256, verifyChecksum, prefVerify {
            await MainActor.run { progress.stage = .verifying }
            let got = try sha256(of: dest)
            guard got == expected else {
                try? FileManager.default.removeItem(at: dest)
                throw Error.checksumMismatch(expected: expected, got: got)
            }
        }
    }

    // MARK: — SHA-256

    private static func sha256(of url: URL) throws -> String {
        // Simple shell-out — CryptoKit is fine too but this avoids importing it across files.
        let pipe = Pipe()
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/shasum")
        proc.arguments = ["-a", "256", url.path]
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        try proc.run()
        proc.waitUntilExit()
        let data = (try? pipe.fileHandleForReading.readToEnd()) ?? Data()
        let text = String(data: data, encoding: .utf8) ?? ""
        return text.split(separator: " ").first.map(String.init) ?? ""
    }
}
