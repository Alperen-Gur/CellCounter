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

        // Stream straight to a temp file via URLSessionDownloadTask. This is the
        // efficient path for multi-GB weights: URLSession writes to disk itself,
        // so we never iterate the body a byte at a time (the AsyncBytes pitfall)
        // nor grow a Data buffer in memory. Progress + throttled rate come from
        // the delegate's didWriteData callback.
        let delegate = DownloadProgressDelegate(progress: progress)
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }

        let tempURL: URL
        let response: URLResponse
        do {
            (tempURL, response) = try await session.download(for: URLRequest(url: url))
        } catch is CancellationError {
            throw Error.cancelled
        } catch {
            throw Error.ioError(error)
        }

        guard let http = response as? HTTPURLResponse else {
            throw Error.badResponse(0)
        }
        guard (200...299).contains(http.statusCode) else {
            try? FileManager.default.removeItem(at: tempURL)
            throw Error.badResponse(http.statusCode)
        }

        // Move the completed download into place (replacing any prior file).
        do {
            if FileManager.default.fileExists(atPath: dest.path) {
                try FileManager.default.removeItem(at: dest)
            }
            try FileManager.default.moveItem(at: tempURL, to: dest)
        } catch {
            try? FileManager.default.removeItem(at: tempURL)
            throw Error.ioError(error)
        }

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

/// Bridges `URLSessionDownloadTask` progress into `ModelInstallProgress`,
/// throttling UI updates to ~4/s and computing a byte rate between reports.
private final class DownloadProgressDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let progress: ModelInstallProgress
    private var lastReport = Date()
    private var lastBytes: Int64 = 0

    init(progress: ModelInstallProgress) {
        self.progress = progress
    }

    func urlSession(_ session: URLSession,
                    downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        let now = Date()
        let elapsed = now.timeIntervalSince(lastReport)
        guard elapsed > 0.25 else { return }
        let rate = Int64(Double(totalBytesWritten - lastBytes) / elapsed)
        let p = totalBytesExpectedToWrite > 0
            ? Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
            : 0
        lastReport = now
        lastBytes = totalBytesWritten
        Task { @MainActor in
            progress.stage = .downloading(progress: p, bytesPerSec: rate)
        }
    }

    // Required by the protocol; the async `download(for:)` API consumes the
    // finished file via its returned temp URL, so nothing to do here.
    func urlSession(_ session: URLSession,
                    downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {}
}
