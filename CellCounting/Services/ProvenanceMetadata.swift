import Foundation
import CryptoKit
import Darwin

/// Pass-18 (Lane R): single source of truth for "what produced this analysis."
///
/// Every export carries a `ProvenanceMetadata` block — CSV header comments,
/// PNG `tEXt`/`iTXt` chunks, JSON sibling key, and the PDF footer — so a
/// collaborator can inspect recorded run settings and the current review filters.
/// Missing historical runtime or weights metadata remains unknown.
///
/// Cost rules:
///  • Detector versions are cached per family, refreshed in the background,
///    and invalidated when an environment or model installation changes.
///  • Weights hashing is keyed by `(url, size, mtime)` so repeat exports of the
///    same model don't re-hash 1+ GB of weights. Hashing happens off the main
///    actor. A warm read checks only file metadata before returning a digest.
///  • Anything that can't be discovered cheaply returns nil — exports MUST
///    never block on missing provenance.
struct ProvenanceMetadata: Codable, Sendable {
    let originalRunSettings: AnalysisRunSettings?
    let sourceSHA256: String?
    let analysisSettingsSource: String
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
        let run = image?.detection?.runSettings
        let recordedId = image?.detection?.detectorId.split(separator: "/").last.map(String.init)
        let modelId = run?.modelId ?? recordedId ?? image?.batch?.modelId ?? "unknown"
        let info = state.models.first(where: { $0.id == modelId })
        let family = run.flatMap { ModelFamily(rawValue: $0.modelFamily) } ?? info?.family ?? .custom
        let modelName = run?.modelName ?? info?.name ?? modelId

        // pxPerUm — prefer the batch's value (per-batch calibration), fall
        // back to the global. pxPerUmSource lives on BatchRecord (see Records.swift).
        let batch = image?.batch ?? state.currentBatch
        let pxPerUm = batch?.pxPerUm ?? state.pxPerUm
        let pxSource = batch?.pxPerUmSource ?? "default"

        return ProvenanceMetadata(
            originalRunSettings: run,
            sourceSHA256: image?.fileHash,
            analysisSettingsSource: run == nil ? "legacy-unknown" : "saved-run",
            appVersion: Self.appVersion,
            appBuild: Self.appBuild,
            appBuildSHA: Self.appBuildSHA,
            osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            modelId: modelId,
            modelName: modelName,
            modelFamily: family.rawValue,
            detectorVersion: run?.detectorVersion,
            weightsHash: run?.weightsSHA256,
            pxPerUm: pxPerUm,
            pxPerUmSource: pxSource,
            thresholds: batch?.thresholds ?? state.thresholds,
            confidenceFloor: image.map { state.effectiveConfidence(for: $0) } ?? state.confidence,
            backgroundSubtract: run?.backgroundSubtract ?? false,
            watershedSplit: run?.watershedSplit ?? false,
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
        lines.append("# analysis_settings_source: \(analysisSettingsSource)")
        if let sourceSHA256 { lines.append("# source_sha256: \(sourceSHA256)") }
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
    /// UI calls never hash file contents. A warm digest is returned only when
    /// a cheap metadata check still matches the file that was hashed.
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
            return url
        case .cellpose4:
            // CPSAM ships a single big checkpoint "cpsam".
            let url = home.appendingPathComponent(".cellpose/models/cpsam")
            return url
        // Classical has no weights at all (that's the point), and the ensemble
        // composes other families rather than owning a checkpoint. Omnipose,
        // StarDist, SAM, and custom models each manage their own checkpoint
        // paths — wire them up here when provenance needs them.
        case .stardist, .sam, .omnipose, .classical, .ensemble, .custom, .all:
            return nil
        }
    }
}

// MARK: — Detector version cache

/// UI reads never stat a runtime or wait for Python. The cached snapshot is
/// invalidated when an environment changes; a cold value remains unknown.
nonisolated final class ProvenanceVersionCache: @unchecked Sendable {
    static let shared = ProvenanceVersionCache()
    private struct Runtime: Sendable {
        let interpreters: [URL]
        let sentinel: URL?
        let code: String
    }
    private struct Entry {
        let value: String?
        let checkedAt: Date
    }
    private let lock = NSLock()
    private var cache: [String: Entry] = [:]
    private var inFlight: Set<String> = []
    private var epoch = 0
    private var observers: [NSObjectProtocol] = []
    private let workQueue = DispatchQueue(label: "CellCounter.provenance.versions", qos: .utility)

    init() {
        for name in ["ccVenvChanged", "ccVenv4Changed", "ccModelStorageChanged"] {
            observers.append(NotificationCenter.default.addObserver(
                forName: Notification.Name(name), object: nil, queue: nil
            ) { [weak self] _ in self?.invalidate() })
        }
    }
    deinit { for observer in observers { NotificationCenter.default.removeObserver(observer) } }

    @MainActor func versionSync(for family: ModelFamily) -> String? {
        let key = family.rawValue
        let claim = lookupAndClaim(key)
        guard let revision = claim.revision else { return claim.value }
        guard let runtime = Self.runtime(for: family) else {
            publish(nil, key: key, revision: revision)
            return nil
        }
        workQueue.async { [weak self] in
            let value = Self.probe(runtime: runtime)
            self?.publish(value, key: key, revision: revision)
        }
        return claim.value
    }

    /// Compatibility entry point. Like the other synchronous provenance API,
    /// it returns the known snapshot and warms a cold value without blocking.
    @MainActor static func probe(family: ModelFamily) -> String? { shared.versionSync(for: family) }

    @MainActor private static func runtime(for family: ModelFamily) -> Runtime? {
        // These are URL composition only, with no existence/import checks.
        let store = FileStore.shared
        switch family {
        case .cellpose:
            return Runtime(interpreters: [store.pythonInterpreterURL], sentinel: store.installIncompleteSentinel,
                           code: "import cellpose; print(cellpose.version)")
        case .cellpose4:
            return Runtime(interpreters: [store.pythonInterpreter4URL], sentinel: store.cellpose4InstallIncompleteSentinel,
                           code: "import cellpose; print(cellpose.version)")
        case .omnipose:
            let directory = store.pythonDir.appendingPathComponent("venv_omni/bin")
            return Runtime(interpreters: ["python3", "python"].map { directory.appendingPathComponent($0) },
                           sentinel: store.pythonDir.appendingPathComponent(".cc-install-incomplete-omni"),
                           code: "import omnipose; print(omnipose.__version__)")
        case .classical:
            return Runtime(interpreters: [store.pythonInterpreterURL], sentinel: nil,
                           code: "import skimage; print('scikit-image ' + skimage.__version__)")
        case .stardist, .sam, .ensemble, .custom, .all: return nil
        }
    }

    private func lookupAndClaim(_ key: String) -> (value: String?, revision: Int?) {
        lock.lock(); defer { lock.unlock() }
        let entry = cache[key]
        if inFlight.contains(key) || entry.map({ Date().timeIntervalSince($0.checkedAt) < 30 }) == true {
            return (entry?.value, nil)
        }
        inFlight.insert(key)
        return (entry?.value, epoch)
    }
    private func publish(_ value: String?, key: String, revision: Int) {
        lock.lock(); defer { lock.unlock() }
        inFlight.remove(key)
        guard revision == epoch else { return }
        cache[key] = Entry(value: value, checkedAt: Date())
    }
    private func invalidate() {
        lock.lock(); defer { lock.unlock() }
        epoch &+= 1
        cache.removeAll()
        // Keep old work claimed until it finishes, so repeated invalidations
        // cannot grow the background queue without bound.
    }

    private static func probe(runtime: Runtime) -> String? {
        guard !Thread.isMainThread else { return nil }
        let fm = FileManager.default
        if let sentinel = runtime.sentinel, fm.fileExists(atPath: sentinel.path) { return nil }
        guard let interpreter = runtime.interpreters.first(where: { fm.isExecutableFile(atPath: $0.path) }) else { return nil }
        let process = Process()
        process.executableURL = interpreter
        process.arguments = ["-c", runtime.code]
        process.standardInput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let output = Pipe()
        process.standardOutput = output
        let fd = output.fileHandleForReading.fileDescriptor
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        let ended = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in ended.signal() }
        do { try process.run() } catch { return nil }
        try? output.fileHandleForWriting.close()
        defer { try? output.fileHandleForReading.close() }
        let registration = Task { @MainActor in
            if process.isRunning { ChildProcessTracker.shared.register(process, kind: .other) }
        }
        defer {
            Task { await registration.value; await ChildProcessTracker.shared.forget(process) }
        }
        var bytes = Data()
        var overflow = false
        var buffer = [UInt8](repeating: 0, count: 8192)
        func drain() {
            // Bound each drain so a continuously noisy import cannot starve
            // its deadline. Discard excess output while keeping the pipe clear.
            for _ in 0..<32 {
                let count = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
                guard count > 0 else { return }
                let kept = min(count, max(0, 4096 - bytes.count))
                bytes.append(contentsOf: buffer.prefix(kept))
                if kept < count { overflow = true }
            }
        }
        let deadline = ContinuousClock.now + .seconds(5)
        while ended.wait(timeout: .now() + .milliseconds(20)) == .timedOut {
            drain()
            if ContinuousClock.now >= deadline {
                if process.isRunning { process.terminate() }
                if ended.wait(timeout: .now() + .milliseconds(300)) == .timedOut, process.isRunning {
                    kill(process.processIdentifier, SIGKILL)
                    _ = ended.wait(timeout: .now() + 1)
                }
                return nil
            }
        }
        drain()
        guard process.terminationStatus == 0, !overflow,
              let raw = String(data: bytes, encoding: .utf8) else { return nil }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}

// MARK: — Weights hash cache

/// UI reads validate a warm digest with file metadata; cold or changed files
/// return unknown while streaming SHA-256 runs on a serial utility queue.
/// Environment/storage notifications also invalidate retained snapshots.
nonisolated final class WeightsHashCache: @unchecked Sendable {
    static let shared = WeightsHashCache()
    private struct Key: Hashable {
        let path: String
        let size: Int64
        let mtime: TimeInterval
        let inode: UInt64
    }
    private struct Entry {
        let key: Key
        let hash: String
    }
    private let lock = NSLock()
    private var cache: [String: Entry] = [:]
    private var order: [String] = []
    private var inFlight: Set<String> = []
    private var epoch = 0
    private var observers: [NSObjectProtocol] = []
    private let workQueue = DispatchQueue(label: "CellCounter.provenance.weights", qos: .utility)

    init() {
        for name in ["ccVenvChanged", "ccVenv4Changed", "ccModelStorageChanged"] {
            observers.append(NotificationCenter.default.addObserver(
                forName: Notification.Name(name), object: nil, queue: nil
            ) { [weak self] _ in self?.invalidate() })
        }
    }
    deinit { for observer in observers { NotificationCenter.default.removeObserver(observer) } }

    func hashIfCheap(at url: URL) -> String? {
        let path = url.standardizedFileURL.path
        let claim = lookupAndClaim(path)
        // Immutable run metadata must never receive the previous checkpoint's
        // digest. A small stat on a warm read preserves that correctness; file
        // content reads and hashing remain strictly off the main thread.
        let verifiedHash: String? = claim.entry.flatMap { entry in
            Self.makeKey(url: url) == entry.key ? entry.hash : nil
        }
        guard let revision = claim.revision else { return verifiedHash }
        // Preserve inline background callers for ordinary checkpoints; a UI
        // caller always returns immediately, regardless of checkpoint size.
        if !Thread.isMainThread, let key = Self.makeKey(url: url), key.size <= 500 * 1024 * 1024 {
            let entry = prepare(url: url, cached: claim.entry)
            publish(entry, path: path, revision: revision)
            return entry?.hash
        }
        workQueue.async { [weak self] in
            guard let self else { return }
            let entry = self.prepare(url: url, cached: claim.entry)
            self.publish(entry, path: path, revision: revision)
        }
        return verifiedHash
    }

    private func lookupAndClaim(_ path: String) -> (entry: Entry?, revision: Int?) {
        lock.lock(); defer { lock.unlock() }
        let entry = cache[path]
        guard !inFlight.contains(path), inFlight.count < 8 else { return (entry, nil) }
        inFlight.insert(path)
        return (entry, epoch)
    }
    private func prepare(url: URL, cached: Entry?) -> Entry? {
        guard let key = Self.makeKey(url: url) else { return nil }
        if let cached, cached.key == key { return cached }
        guard let hash = Self.sha256Hex(at: url), Self.makeKey(url: url) == key else { return nil }
        return Entry(key: key, hash: hash)
    }
    private func publish(_ entry: Entry?, path: String, revision: Int) {
        lock.lock(); defer { lock.unlock() }
        inFlight.remove(path)
        guard revision == epoch else { return }
        order.removeAll { $0 == path }
        cache[path] = entry
        if entry != nil { order.append(path) }
        while order.count > 32 { cache[order.removeFirst()] = nil }
    }
    private func invalidate() {
        lock.lock(); defer { lock.unlock() }
        epoch &+= 1
        cache.removeAll()
        order.removeAll()
        // Keep old work claimed until it finishes, so repeated invalidations
        // cannot grow the background queue without bound.
    }
    private static func makeKey(url: URL) -> Key? {
        let resolved = url.resolvingSymlinksInPath()
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: resolved.path),
              attrs[.type] as? FileAttributeType == .typeRegular else { return nil }
        return Key(path: resolved.path, size: (attrs[.size] as? NSNumber)?.int64Value ?? 0,
                   mtime: (attrs[.modificationDate] as? Date)?.timeIntervalSinceReferenceDate ?? 0,
                   inode: (attrs[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0)
    }

    /// Pure streaming hash. A read error is unknown, never a digest of a prefix.
    static func sha256Hex(at url: URL) -> String? {
        guard !Thread.isMainThread, let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        do {
            while true {
                let data = try autoreleasepool { try handle.read(upToCount: 1024 * 1024) ?? Data() }
                if data.isEmpty { break }
                hasher.update(data: data)
            }
        } catch { return nil }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
