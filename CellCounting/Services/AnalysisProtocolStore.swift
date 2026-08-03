import Foundation
import AppKit
import UniformTypeIdentifiers

/// Disk I/O + save/open panels for `AnalysisProtocol`, plus the AppState
/// bridge (`AppState.apply`, `AppState.makeAnalysisProtocolSnapshot`,
/// `AnalysisProtocol.installWarning`). Mirrors `ExportService` +
/// `Services/OpenPanel.swift`'s conventions: plain-value encode/decode
/// functions stay `nonisolated` (safe to call from anywhere, easy to unit
/// test), while anything that touches AppKit UI or `AppState` is `@MainActor`.
enum AnalysisProtocolStore {

    // MARK: — Errors

    enum StoreError: LocalizedError {
        case encodeFailed
        case writeFailed(Error)
        case readFailed(Error)

        var errorDescription: String? {
            switch self {
            case .encodeFailed: return "Couldn't encode the protocol file."
            case .writeFailed(let e): return "Couldn't write the protocol file: \(e.localizedDescription)"
            case .readFailed(let e): return "Couldn't read the protocol file: \(e.localizedDescription)"
            }
        }
    }

    // MARK: — Library location

    /// `~/Library/Application Support/CellCounter/Protocols/` — a plain
    /// folder of `*.ccproto.json` files, deliberately NOT a SwiftData table.
    /// Protocols are meant to be individually shareable/emailable/citable
    /// files (the brief: "a methods section can cite an exact
    /// configuration"), so keeping them as loose JSON means "share this
    /// protocol" is just "share this file" — no export step needed, and no
    /// schema migration required in `Persistence/Records.swift`.
    static var libraryDirectory: URL {
        FileStore.shared.root.appendingPathComponent("Protocols", isDirectory: true)
    }

    @discardableResult
    static func ensureLibraryDirectoryExists() -> Bool {
        if FileManager.default.fileExists(atPath: libraryDirectory.path) { return true }
        return (try? FileManager.default.createDirectory(at: libraryDirectory,
                                                          withIntermediateDirectories: true)) != nil
    }

    // MARK: — Encode / decode (pure; no AppKit, no AppState)

    private static func makeEncoder() -> JSONEncoder {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        enc.dateEncodingStrategy = .iso8601
        return enc
    }

    private static func makeDecoder() -> JSONDecoder {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return dec
    }

    /// Encodes `analysisProtocol` and writes it atomically to `url`. Plain
    /// pretty-printed JSON — openable in any text editor, `json.load()`-able
    /// from Python, diffable in git.
    nonisolated static func save(_ analysisProtocol: AnalysisProtocol, to url: URL) throws {
        let data: Data
        do {
            data = try makeEncoder().encode(analysisProtocol)
        } catch {
            throw StoreError.encodeFailed
        }
        do {
            try data.write(to: url, options: [.atomic])
        } catch {
            throw StoreError.writeFailed(error)
        }
    }

    /// Reads + decodes `url` into an `AnalysisProtocol`.
    ///
    /// Does a cheap `JSONSerialization` pre-check of just the `kind` /
    /// `schemaVersion` keys before the strict `Decodable` pass, so:
    ///  - picking an unrelated JSON file produces `.notAProtocolFile` instead
    ///    of a raw, confusing `DecodingError`.
    ///  - a file from a NEWER CellCounter (schema version this build doesn't
    ///    know yet) is caught with a clear "update CellCounter" message
    ///    before the strict decode trips over fields it doesn't understand.
    nonisolated static func load(from url: URL) throws -> AnalysisProtocol {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw StoreError.readFailed(error)
        }

        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AnalysisProtocol.LoadError.notAProtocolFile
        }
        guard obj["kind"] as? String == AnalysisProtocol.documentKind else {
            throw AnalysisProtocol.LoadError.notAProtocolFile
        }
        if let version = obj["schemaVersion"] as? Int,
           version > AnalysisProtocol.currentSchemaVersion {
            throw AnalysisProtocol.LoadError.unsupportedSchemaVersion(
                found: version, newestSupported: AnalysisProtocol.currentSchemaVersion)
        }

        do {
            return try makeDecoder().decode(AnalysisProtocol.self, from: data)
        } catch {
            throw AnalysisProtocol.LoadError.malformed(String(describing: error))
        }
    }

    // MARK: — Library

    struct LibraryEntry: Identifiable, Sendable {
        var id: URL { url }
        let url: URL
        let analysisProtocol: AnalysisProtocol
    }

    /// Best-effort listing, newest first. Unreadable/corrupt files are
    /// skipped (and logged) rather than surfaced as a blocking error — one
    /// damaged file shouldn't hide every other saved protocol, matching how
    /// `Repositories.allBatches()` / preset fetches degrade to `[]` rather
    /// than throwing.
    nonisolated static func libraryEntries() -> [LibraryEntry] {
        ensureLibraryDirectoryExists()
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: libraryDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles])) ?? []
        let jsonURLs = urls.filter { $0.pathExtension.lowercased() == "json" }
        var entries: [LibraryEntry] = []
        for url in jsonURLs {
            do {
                let p = try load(from: url)
                entries.append(LibraryEntry(url: url, analysisProtocol: p))
            } catch {
                NSLog("CellCounter: skipped unreadable protocol file %@: %@",
                      url.lastPathComponent, String(describing: error))
            }
        }
        return entries.sorted { $0.analysisProtocol.createdAt > $1.analysisProtocol.createdAt }
    }

    /// Writes into the library folder with a filesystem-safe, collision-safe
    /// name derived from the protocol's display name (reuses
    /// `ExportService.sanitizeFilename` — the same sanitizer every other
    /// export path in this app already uses).
    @discardableResult
    nonisolated static func saveToLibrary(_ analysisProtocol: AnalysisProtocol) throws -> URL {
        ensureLibraryDirectoryExists()
        let base = ExportService.sanitizeFilename(analysisProtocol.name)
        var url = libraryDirectory.appendingPathComponent("\(base).ccproto.json")
        if FileManager.default.fileExists(atPath: url.path) {
            let suffix = String(analysisProtocol.id.uuidString.prefix(8))
            url = libraryDirectory.appendingPathComponent("\(base)-\(suffix).ccproto.json")
        }
        try save(analysisProtocol, to: url)
        return url
    }

    nonisolated static func deleteFromLibrary(_ url: URL) throws {
        try FileManager.default.removeItem(at: url)
    }

    // MARK: — Save / Open panels
    //
    // Sandbox is off for this app (see FileStore.swift's pass-10 note), so a
    // plain NSSavePanel/NSOpenPanel round trip needs no security-scoped
    // bookmark for a one-shot pick — same reasoning ResultsExportPanel's
    // `chooseURL` already relies on.

    @MainActor
    static func presentSavePanel(suggestedName: String,
                                 completion: @escaping (URL?) -> Void) {
        ensureLibraryDirectoryExists()
        let panel = NSSavePanel()
        panel.title = "Save Analysis Protocol"
        panel.prompt = "Save"
        panel.nameFieldStringValue = suggestedName
        if let utype = UTType(filenameExtension: "json") { panel.allowedContentTypes = [utype] }
        panel.directoryURL = libraryDirectory
        panel.begin { resp in
            completion(resp == .OK ? panel.url : nil)
        }
    }

    @MainActor
    static func presentOpenPanel(completion: @escaping (URL?) -> Void) {
        ensureLibraryDirectoryExists()
        let panel = NSOpenPanel()
        panel.title = "Open Analysis Protocol"
        panel.prompt = "Open"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if let utype = UTType(filenameExtension: "json") { panel.allowedContentTypes = [utype] }
        panel.directoryURL = libraryDirectory
        panel.begin { resp in
            completion(resp == .OK ? panel.url : nil)
        }
    }
}

// MARK: — AppState bridge

extension AnalysisProtocol {
    /// Returns a human-readable warning when this protocol's model isn't
    /// available on THIS Mac — either missing from the catalog entirely (a
    /// custom fine-tune id from someone else's machine) or present but not
    /// installed. Returns nil when the model is installed and ready.
    ///
    /// `@MainActor` because it reads `AppState.models` /
    /// `AppState.detectorRegistry`, both isolated to the type (AppState
    /// itself is declared `@MainActor`) — matches how `ExportService`
    /// annotates the functions that take `AppState`/SwiftData records
    /// (e.g. `writeSampleFolder`).
    @MainActor
    func installWarning(state: AppState) -> String? {
        guard let info = state.models.first(where: { $0.id == model.id }) else {
            return "\u{201c}\(name)\u{201d} was saved with model \(model.name) (\(model.id)), which isn\u{2019}t in this build\u{2019}s model catalog. Every other setting was applied — pick an available model before running detection."
        }
        // Mirrors BOTH guards `AppState.activate(_:)` itself enforces —
        // `apply(_:)` below only calls `activate` once this returns nil, so
        // that call must be guaranteed to succeed. Missing the `comingSoon`
        // check here would let a stale "installed" cache entry slip past
        // this warning and then have `activate` silently refuse anyway.
        if info.comingSoon {
            return "\u{201c}\(name)\u{201d} was saved with \(info.name), which isn\u{2019}t available in this build yet (\u{201c}coming soon\u{201d}). Every other setting was applied — pick an available model before running detection."
        }
        guard state.detectorRegistry.isInstalled(info.id, models: state.models) else {
            return "\u{201c}\(name)\u{201d} was saved with \(info.name), which isn\u{2019}t installed on this Mac. Every other setting was applied — install \(info.name) (or activate a different model) before running detection."
        }
        return nil
    }
}

extension AppState {
    /// Builds a shareable snapshot of the CURRENT settings — the save side of
    /// analysis protocols. Called by the protocol-library UI's "Save current
    /// settings…" action. Captures every field `AnalysisProtocol` defines;
    /// see that type's doc comment for the "at minimum" list this satisfies.
    func makeAnalysisProtocolSnapshot(name: String, notes: String = "") -> AnalysisProtocol {
        let info = models.first(where: { $0.id == activeModelId })
        let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let appBuild = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return AnalysisProtocol(
            name: name,
            notes: notes,
            appVersion: appVersion,
            appBuild: appBuild,
            model: .init(id: activeModelId,
                        name: info?.name ?? activeModelName,
                        family: info?.family.rawValue ?? "unknown"),
            detection: .init(expectedDiameterUm: expectedDiameterUm,
                             channelsCyto: channels.cyto,
                             channelsNuclei: channels.nuclei,
                             confidenceThreshold: confidence),
            calibration: .init(pxPerUm: pxPerUm),
            sizeBins: .init(thresholdsUm: thresholds),
            preprocessing: .init(backgroundSubtract: backgroundSubtract,
                                 rollingBallRadiusPx: rollingBallRadius,
                                 watershedSplit: watershedSplit,
                                 watershedMinDistanceUm: watershedMinDistanceUm),
            manualMarkerDiameterUm: manualMarkerDiameter
        )
    }

    /// Applies every setting from `analysisProtocol` to this AppState in one
    /// synchronous pass. "Atomic" in the sense that matters for a UI-driven
    /// class like this one: the whole body below runs with no `await` inside
    /// it, so — since AppState is `@MainActor` and the main actor runs one
    /// piece of work at a time — nothing else on the main actor can observe
    /// a partially-applied state; every field is consistent with every other
    /// field by the time this function returns and SwiftUI gets to re-render.
    ///
    /// Returns a non-nil warning when the protocol's model isn't installed
    /// (or isn't in this build's catalog at all) — every OTHER setting is
    /// still applied either way, per the brief: "warn, don't silently fail."
    /// Returns nil when everything, including activating the model, applied
    /// cleanly.
    @discardableResult
    func apply(_ analysisProtocol: AnalysisProtocol) -> String? {
        thresholds = analysisProtocol.sizeBins.thresholdsUm
        pxPerUm = analysisProtocol.calibration.pxPerUm
        confidence = analysisProtocol.detection.confidenceThreshold
        expectedDiameterUm = analysisProtocol.detection.expectedDiameterUm
        channels = DetectionChannels(cyto: analysisProtocol.detection.channelsCyto,
                                     nuclei: analysisProtocol.detection.channelsNuclei)
        backgroundSubtract = analysisProtocol.preprocessing.backgroundSubtract
        rollingBallRadius = analysisProtocol.preprocessing.rollingBallRadiusPx
        watershedSplit = analysisProtocol.preprocessing.watershedSplit
        watershedMinDistanceUm = analysisProtocol.preprocessing.watershedMinDistanceUm
        manualMarkerDiameter = analysisProtocol.manualMarkerDiameterUm

        if let warning = analysisProtocol.installWarning(state: self) {
            // Still record the intended model id — mirrors how
            // `refreshDetector()` already treats an active-but-not-installed
            // model as a valid, UI-gated state (detector goes nil, install
            // banners take over) rather than silently leaving the OLD model
            // active behind the user's back while claiming success.
            activeModelId = analysisProtocol.model.id
            refreshDetector()
            return warning
        }
        activate(analysisProtocol.model.id)
        return nil
    }
}
