import Foundation

/// A versioned, shareable snapshot of a full CellCounter analysis
/// configuration: which detector, its parameters, calibration, size bins,
/// and preprocessing. Two people loading the same `.ccproto.json` file run
/// literally identical settings, and a methods section can cite the file (or
/// paste its JSON) as an exact, reproducible configuration.
///
/// File format: plain, pretty-printed, human-readable JSON (see
/// `AnalysisProtocolStore` for the encode/decode + save/open-panel side).
/// `schemaVersion` is read and validated BEFORE the rest of the payload is
/// trusted, so a future format change can migrate old files forward instead
/// of failing to load — see the migration note above `currentSchemaVersion`.
///
/// This type intentionally has zero dependency on AppState/AppKit/SwiftData —
/// it mirrors the existing idiom in this folder (`CalibrationPreset.swift`,
/// `SizeBin.swift`, `Cell.swift` are all plain Foundation value types). The
/// AppState <-> AnalysisProtocol bridge (`apply`, `makeAnalysisProtocolSnapshot`,
/// `installWarning`) lives in `Services/AnalysisProtocolStore.swift` instead,
/// matching how e.g. `ExportService` (Services/) is what touches AppState/
/// SwiftData while `Cell.swift` (Domain/) stays pure.
struct AnalysisProtocol: Codable, Identifiable, Hashable, Sendable {
    /// Bump this — and extend `AnalysisProtocolStore.load`'s version gate —
    /// whenever a field is added/removed/renamed in a way that isn't
    /// automatically Codable-compatible. Codable already tolerates purely
    /// additive optional fields without a version bump (old files just don't
    /// have the key; `decodeIfPresent` + a default handles that); reserve
    /// bumps for actual breaking changes, e.g. a field changing meaning or
    /// units. There is no v0 → v1 migration to write because v1 is the
    /// original format — this comment is the seam for whoever writes v1 → v2.
    static let currentSchemaVersion = 1

    /// Discriminator so `AnalysisProtocolStore.load` can reject an arbitrary
    /// JSON file (a GeoJSON export, a CSV someone renamed, a stray settings
    /// blob) with a clear, friendly error instead of a cryptic Codable
    /// failure three fields deep.
    static let documentKind = "com.cellcounter.analysis-protocol"

    var schemaVersion: Int
    var kind: String
    var id: UUID
    /// Display name — what shows up in the protocol library and in the
    /// suggested filename. E.g. "Keratinocyte 10x - lab standard".
    var name: String
    /// Free-form notes: instrument, objective, purpose, who to ask. Optional;
    /// defaults to empty rather than nil so the JSON stays flat/simple.
    var notes: String
    var createdAt: Date
    /// App version/build that produced this file — informational, for "which
    /// CellCounter build was this analyzed with" in a methods section.
    var appVersion: String
    var appBuild: String

    var model: ModelRef
    var detection: DetectionSettings
    var calibration: CalibrationSettings
    var sizeBins: SizeBinSettings
    var preprocessing: PreprocessingSettings
    /// Default diameter (µm) applied to manually-placed markers. Not part of
    /// automated detection, but part of "the whole analysis setup" a lab
    /// would want everyone to share.
    var manualMarkerDiameterUm: Double

    // MARK: — Nested settings groups

    struct ModelRef: Codable, Hashable, Sendable {
        /// The catalog id ("cp-cyto3", a custom fine-tune's UUID, …) — this
        /// is the field actually used to re-select the model on load.
        var id: String
        /// Human-readable name at save time — display/warning text only;
        /// never used to match models on load (ids can be stable while a
        /// display name changes, and vice versa for user-renamed customs).
        var name: String
        /// `ModelFamily.rawValue` at save time — informational (helps a
        /// human read the file / the warning message); not used for matching.
        var family: String
    }

    struct DetectionSettings: Codable, Hashable, Sendable {
        /// Expected cell diameter in µm; 0 = "Auto" (bin-derived prior — see
        /// AppState.expectedDiameterUm's doc comment for the sidecar
        /// semantics this mirrors exactly).
        var expectedDiameterUm: Double
        /// Cellpose `channels=[cyto, nuclei]` indices. 0 = grayscale/none.
        var channelsCyto: Int
        var channelsNuclei: Int
        /// Cells below this confidence are hidden from counts/exports/overlay.
        var confidenceThreshold: Double
    }

    struct CalibrationSettings: Codable, Hashable, Sendable {
        var pxPerUm: Double
    }

    struct SizeBinSettings: Codable, Hashable, Sendable {
        /// Ascending breakpoints in µm, e.g. `[20, 30]` -> "<20 / 20-30 / >30".
        var thresholdsUm: [Double]
    }

    struct PreprocessingSettings: Codable, Hashable, Sendable {
        var backgroundSubtract: Bool
        var rollingBallRadiusPx: Int
        var watershedSplit: Bool
        var watershedMinDistanceUm: Int
    }

    // MARK: — Init

    init(schemaVersion: Int = AnalysisProtocol.currentSchemaVersion,
         kind: String = AnalysisProtocol.documentKind,
         id: UUID = UUID(),
         name: String,
         notes: String = "",
         createdAt: Date = Date(),
         appVersion: String,
         appBuild: String,
         model: ModelRef,
         detection: DetectionSettings,
         calibration: CalibrationSettings,
         sizeBins: SizeBinSettings,
         preprocessing: PreprocessingSettings,
         manualMarkerDiameterUm: Double) {
        self.schemaVersion = schemaVersion
        self.kind = kind
        self.id = id
        self.name = name
        self.notes = notes
        self.createdAt = createdAt
        self.appVersion = appVersion
        self.appBuild = appBuild
        self.model = model
        self.detection = detection
        self.calibration = calibration
        self.sizeBins = sizeBins
        self.preprocessing = preprocessing
        self.manualMarkerDiameterUm = manualMarkerDiameterUm
    }

    // MARK: — Errors

    enum LoadError: LocalizedError, Equatable {
        case notAProtocolFile
        case unsupportedSchemaVersion(found: Int, newestSupported: Int)
        case malformed(String)

        var errorDescription: String? {
            switch self {
            case .notAProtocolFile:
                return "This file isn't a CellCounter analysis protocol."
            case .unsupportedSchemaVersion(let found, let newest):
                return "This protocol was saved by a newer version of CellCounter (schema \(found); this build supports up to \(newest)). Update CellCounter to open it."
            case .malformed(let detail):
                return "This protocol file is damaged or incomplete: \(detail)"
            }
        }

        static func == (lhs: LoadError, rhs: LoadError) -> Bool {
            lhs.errorDescription == rhs.errorDescription
        }
    }
}
