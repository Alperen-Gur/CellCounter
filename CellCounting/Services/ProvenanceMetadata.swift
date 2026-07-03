import Foundation
import CryptoKit

/// Pass-18 (Lane R): single source of truth for "what produced this analysis."
///
/// Every export carries a `ProvenanceMetadata` block — CSV header comments,
/// PNG `tEXt`/`iTXt` chunks, JSON sibling key, and the PDF footer — so a
/// collaborator can reproduce a result *exactly* by re-running the same model
/// weights, the same detector library version, on the same calibrated input.
///
/// Cost rules:
///  • Detector version probes (one subprocess per family) are cached for the
///    lifetime of the process.
///  • Weights hashing is keyed by `(url, size, mtime)` so repeat exports of the
///    same model don't re-hash 1+ GB of weights. Hashing happens off the main
///    actor.
///  • Anything that can't be discovered cheaply returns nil — exports MUST
///    never block on missing provenance.
struct ProvenanceMetadata: Codable, Sendable {
    let appVersion: String          // CFBundleShortVersionString
    let appBuild: String            // CFBundleVersion
    let appBuildSHA: String?        // git SHA from a build setting if present
    let osVersion: String           // ProcessInfo.processInfo.operatingSystemVersionString
    let modelId: String             // active model
    let modelName: String           // user-facing name
    let modelFamily: String         // "cellpose" | "cellpose4" | etc.
    let detectorVersion: String?    // cellpose 3.x version OR cpsam version
    let weightsHash: String?        // SHA-256 of the weights file used, if discoverable
    let pxPerUm: Double
    let pxPerUmSource: String       // "exif-omeXML", "exif-tiff", "preset-Olympus IX73 20×", "manual", "default"
    let thresholds: [Double]
    let confidenceFloor: Double
    let backgroundSubtract: Bool
    let watershedSplit: Bool
    let timestamp: Date             // when the analysis was exported
    let imageId: String?            // the specific image (UUID) being stamped
    let detectionRanAt: Date?       // when the detection itself was run

    // MARK: — Capture

    /// Build a `ProvenanceMetadata` snapshot from the live app state.
    /// Reads `AppState` and the BatchRecord/ImageRecord fields surfaced from
    /// SwiftData — callers are expected to be on the MainActor (matches the
    /// existing `ReportSnapshot.make(image:state:)` pattern). Hashing + version
    /// probes do NOT block this call — they read from caches populated
    /// off-main; cold-miss returns nil.
    static func capture(for image: ImageRecord?, state: AppState) -> ProvenanceMetadata {
        let info = state.models.first(where: { $0.id == state.activeModelId })
        let family = info?.family ?? .custom
        let modelName = info?.name ?? state.activeModelName
        let modelId = state.currentBatch?.modelId ?? state.activeModelId

        // pxPerUm — prefer the batch's value (per-batch calibration), fall
        // back to the global. pxPerUmSource lives on BatchRecord (see Records.swift).
        let batch = image?.batch ?? state.currentBatch
        let pxPerUm = batch?.pxPerUm ?? state.pxPerUm
        let pxSource = batch?.pxPerUmSource ?? "default"

        return ProvenanceMetadata(
            appVersion: Self.appVersion,
            appBuild: Self.appBuild,
            appBuildSHA: Self.appBuildSHA,
            osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            modelId: modelId,
            modelName: modelName,
            modelFamily: family.rawValue,
            detectorVersion: Self.detectorVersion(for: family),
            weightsHash: Self.weightsHash(for: family, modelId: modelId),
            pxPerUm: pxPerUm,
            pxPerUmSource: pxSource,
            thresholds: batch?.thresholds ?? state.thresholds,
            confidenceFloor: image.map { state.effectiveConfidence(for: $0) } ?? state.confidence,
            backgroundSubtract: state.backgroundSubtract,
            watershedSplit: state.watershedSplit,
            timestamp: Date(),
            imageId: image?.id.uuidString,
            detectionRanAt: image?.detection?.ranAt
        )
    }

    // MARK: — Serialisation

    /// CSV-comment-friendly multi-line block: "# <key>: <value>" per row.
    /// Ends with a trailing newline so callers can concat directly with their
    /// existing header. Nil-valued fields are omitted cleanly.
    var asCSVHeader: String {
        var lines: [String] = []
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        lines.append("# app_version: \(appVersion) (\(appBuild))")
        if let sha = appBuildSHA { lines.append("# app_build_sha: \(sha)") }
        lines.append("# os_version: \(osVersion)")
        lines.append("# model_id: \(modelId)")
        lines.append("# model_name: \(modelName)")
        lines.append("# model_family: \(modelFamily)")
        if let dv = detectorVersion { lines.append("# detector_version: \(dv)") }
        if let wh = weightsHash { lines.append("# weights_hash: \(wh)") }
        lines.append("# pxPerUm: \(String(format: "%g", pxPerUm))")
        lines.append("# pxPerUm_source: \(pxPerUmSource)")
        lines.append("# confidence_floor: \(String(format: "%.4f", confidenceFloor))")
        let binsStr = "[" + thresholds.map(\.trimmedString).joined(separator: ",") + "]"
        lines.append("# thresholds: \(binsStr)")
        lines.append("# background_subtract: \(backgroundSubtract ? "true" : "false")")
        lines.append("# watershed_split: \(watershedSplit ? "true" : "false")")
        lines.append("# exported_at: \(iso.string(from: timestamp))")
        if let id = imageId { lines.append("# image_id: \(id)") }
        if let ran = detectionRanAt { lines.append("# detection_ran_at: \(iso.string(from: ran))") }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Compact markdown footer for the lab-journal PDF / report.md.
    var asMarkdown: String {
        var parts: [String] = []
        parts.append("**Provenance**")
        parts.append("- App: CellCounter v\(appVersion) (build \(appBuild))" +
                     (appBuildSHA.map { " · \($0)" } ?? ""))
        parts.append("- OS: \(osVersion)")
        parts.append("- Model: \(modelName) [\(modelId), family=\(modelFamily)]" +
                     (detectorVersion.map { " · detector \($0)" } ?? ""))
        if let wh = weightsHash {
            let short = String(wh.prefix(12))
            parts.append("- Weights: \(short)…")
        }
        parts.append(String(format: "- Calibration: %.4g px/µm (%@)", pxPerUm, pxPerUmSource))
        parts.append(String(format: "- Confidence floor: %.3f", confidenceFloor))
        return parts.joined(separator: "\n") + "\n"
    }

    /// Pretty-printed JSON for export bundles.
    var asJSON: Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        return (try? enc.encode(self)) ?? Data()
    }

    // MARK: — Bundle / build info

    private static let appVersion: String = {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }()

    private static let appBuild: String = {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
    }()

    /// Custom Info.plist key populated by a build setting if present. Returns
    /// nil when no such key exists — don't crash, the field is optional.
    private static let appBuildSHA: String? = {
        // Try a project-defined key first; fall back to common alternatives
        // collaborators sometimes use. Empty string ⇒ nil so a placeholder
        // never makes it into exports.
        let candidates = ["CC_GIT_SHA", "GitSHA", "GIT_SHA", "GitCommitSHA"]
        for key in candidates {
            if let s = Bundle.main.infoDictionary?[key] as? String,
               !s.isEmpty, s != "$(CC_GIT_SHA)" {
                return s
            }
        }
        return nil
    }()

    // MARK: — Detector version probe (cached per process)

    /// Cache of family → version. Versions don't change inside a running
    /// process so this is a process-lifetime cache. Probes shell out to the
    /// venv python; only fired once per family.
    private static let detectorVersionCache: ProvenanceVersionCache = .shared

    static func detectorVersion(for family: ModelFamily) -> String? {
        detectorVersionCache.versionSync(for: family)
    }

    // MARK: — Weights hashing (cached by (url, size, mtime))

    /// Returns nil if the weights file can't be reliably located or if we
    /// haven't yet hashed it. Hashing fires off-main on first access; the
    /// result is cached, so a subsequent export gets the hash immediately.
    /// Files larger than the inline-hash limit only hash once — repeated calls
    /// short-circuit via the (url, size, mtime) key.
    static func weightsHash(for family: ModelFamily, modelId: String) -> String? {
        guard let url = weightsURL(for: family, modelId: modelId) else { return nil }
        return WeightsHashCache.shared.hashIfCheap(at: url)
    }

    /// Heuristic to locate the weights file for a given family/model. Returns
    /// nil for families we don't yet support (StarDist/SAM downloaders
    /// own their own checkpoint paths — wire them up here when needed).
    private static func weightsURL(for family: ModelFamily, modelId: String) -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        switch family {
        case .cellpose:
            // Cellpose 3.x writes into ~/.cellpose/models/<modelname>.
            // The active model id is e.g. "cp-cyto3" — strip the "cp-" prefix.
            let modelName = modelId.hasPrefix("cp-") ? String(modelId.dropFirst(3)) : modelId
            let url = home.appendingPathComponent(".cellpose/models/\(modelName)")
            return FileManager.default.fileExists(atPath: url.path) ? url : nil
        case .cellpose4:
            // CPSAM ships a single big checkpoint "cpsam".
            let url = home.appendingPathComponent(".cellpose/models/cpsam")
            return FileManager.default.fileExists(atPath: url.path) ? url : nil
        case .stardist, .sam, .custom, .all:
            return nil
        }
    }
}

// MARK: — Detector version cache (one subprocess per family, process-lifetime)

/// Caches detector library version strings, indexed by `ModelFamily`. Reading
/// is sync: the first call schedules an off-main probe and returns nil; once
/// the probe completes the cached string is returned on subsequent calls.
/// This is intentional — exports must NEVER block on a Python subprocess.
final class ProvenanceVersionCache: @unchecked Sendable {
    static let shared = ProvenanceVersionCache()

    private let lock = NSLock()
    private var cache: [ModelFamily: String] = [:]
    private var inFlight: Set<ModelFamily> = []

    /// Synchronous read. Returns a cached value when present, otherwise kicks
    /// an async probe and returns nil this call. Idempotent on the in-flight
    /// set so multiple exports during the cold path don't fork N subprocesses.
    func versionSync(for family: ModelFamily) -> String? {
        lock.lock()
        if let v = cache[family] {
            lock.unlock()
            return v
        }
        let shouldProbe = !inFlight.contains(family)
        if shouldProbe { inFlight.insert(family) }
        lock.unlock()

        guard shouldProbe else { return nil }
        Task.detached(priority: .utility) { [weak self] in
            let v = ProvenanceVersionCache.probe(family: family)
            guard let self else { return }
            self.lock.lock()
            if let v { self.cache[family] = v }
            self.inFlight.remove(family)
            self.lock.unlock()
        }
        return nil
    }

    /// Direct synchronous probe. Used by tests and the first detection-time
    /// warm-up. Off the MainActor; safe to call from any thread.
    static func probe(family: ModelFamily) -> String? {
        switch family {
        case .cellpose:
            return probePython(interpreter: FileStore.shared.pythonInterpreterURL,
                               importLine: "import cellpose; print(cellpose.version)")
        case .cellpose4:
            // CPSAM ships as cellpose v4.x — the same `cellpose.version` probe
            // reads the right value out of the cp4 venv.
            return probePython(interpreter: FileStore.shared.pythonInterpreter4URL,
                               importLine: "import cellpose; print(cellpose.version)")
        case .stardist, .sam, .custom, .all:
            return nil
        }
    }

    /// One-shot `python -c <line>` probe. Returns trimmed stdout on exit 0;
    /// nil on any failure (missing interpreter, import error, non-zero exit).
    /// Hard 5-second wall clock cap so a misbehaving venv can't stall exports.
    private static func probePython(interpreter: URL, importLine: String) -> String? {
        guard FileManager.default.isExecutableFile(atPath: interpreter.path) else {
            return nil
        }
        let proc = Process()
        proc.executableURL = interpreter
        proc.arguments = ["-c", importLine]
        let out = Pipe()
        let err = Pipe()
        proc.standardOutput = out
        proc.standardError = err
        do {
            try proc.run()
        } catch {
            return nil
        }

        // Soft 5 s watchdog: kill the subprocess if it doesn't return quickly.
        let watchdog = DispatchWorkItem { [weak proc] in
            guard let proc, proc.isRunning else { return }
            proc.terminate()
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 5.0, execute: watchdog)
        proc.waitUntilExit()
        watchdog.cancel()

        guard proc.terminationStatus == 0 else { return nil }
        let data = (try? out.fileHandleForReading.readToEnd()) ?? Data()
        let raw = String(data: data, encoding: .utf8) ?? ""
        let v = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return v.isEmpty ? nil : v
    }
}

// MARK: — Weights hash cache

/// Caches `SHA-256(url)` keyed by `(url, size, mtime)`. Repeat exports of the
/// same model — e.g. a user running 10 batches with cyto3 — hash the 26 MB
/// checkpoint exactly once. The CPSAM checkpoint is ~1.15 GB; we apply the
/// same caching but skip blocking hashing for files above 500 MB if the cache
/// has not yet warmed.
final class WeightsHashCache: @unchecked Sendable {
    static let shared = WeightsHashCache()

    /// Files larger than this won't block the caller on a cold hash — the
    /// hash is computed off-main and returned on subsequent calls.
    private let inlineHashByteLimit: Int = 500 * 1024 * 1024

    private struct Key: Hashable {
        let path: String
        let size: Int64
        let mtime: TimeInterval
    }

    private let lock = NSLock()
    private var cache: [Key: String] = [:]
    private var inFlight: Set<Key> = []

    /// Returns the cached SHA-256 if present. For small files (< 500 MB) on a
    /// cold cache, hashes inline (background-queue caller is expected). For
    /// large files on a cold cache, schedules an async hash and returns nil
    /// — subsequent exports get the result.
    func hashIfCheap(at url: URL) -> String? {
        guard let key = makeKey(url: url) else { return nil }

        lock.lock()
        if let h = cache[key] {
            lock.unlock()
            return h
        }
        let shouldHash = !inFlight.contains(key)
        if shouldHash { inFlight.insert(key) }
        lock.unlock()

        guard shouldHash else { return nil }

        if key.size <= Int64(inlineHashByteLimit) {
            // Hash inline. ExportService writers run on a background queue,
            // so a few-hundred-ms hash here is acceptable.
            let h = Self.sha256Hex(at: url)
            lock.lock()
            if let h { cache[key] = h }
            inFlight.remove(key)
            lock.unlock()
            return h
        } else {
            // Large file: schedule off-main so this export doesn't stall.
            Task.detached(priority: .utility) { [weak self] in
                let h = Self.sha256Hex(at: url)
                guard let self else { return }
                self.lock.lock()
                if let h { self.cache[key] = h }
                self.inFlight.remove(key)
                self.lock.unlock()
            }
            return nil
        }
    }

    private func makeKey(url: URL) -> Key? {
        let path = url.path
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path) else {
            return nil
        }
        let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSinceReferenceDate ?? 0
        return Key(path: path, size: size, mtime: mtime)
    }

    /// Streaming SHA-256 over the file; reads in 1 MB chunks so the 1.15 GB
    /// CPSAM checkpoint doesn't balloon resident memory.
    static func sha256Hex(at url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        let chunk = 1024 * 1024
        while autoreleasepool(invoking: { () -> Bool in
            let data = (try? handle.read(upToCount: chunk)) ?? Data()
            if data.isEmpty { return false }
            hasher.update(data: data)
            return true
        }) {}
        let digest = hasher.finalize()
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
