import Foundation

/// Calibration presets are the user's own: a name ("Nikon Ts2 · 10×") and a
/// px/µm value measured on their microscope (a scale bar or a typed value
/// from the acquisition software). Fresh libraries start with none.
///
/// Versions before per-image scales seeded four presets measured on another
/// lab's microscopes (Olympus IX73 and Zeiss Axio Vert.A1). A library that
/// still holds them keeps them, since a user may have relied on them, but they
/// are marked so nobody mistakes them for values from their own microscope.
nonisolated enum CalibrationPreset {
    /// The presets older versions added to every new library, by name and value.
    static let formerlyShipped: [(name: String, pxPerUm: Double)] = [
        ("Olympus IX73 — 10×", 2.6),
        ("Olympus IX73 — 20×", 5.2),
        ("Olympus IX73 — 40×", 10.4),
        ("Zeiss Axio Vert.A1 — 20×", 4.9),
    ]

    /// True for a preset that came with an older version of CellCounter rather
    /// than from the user's own measurement.
    static func wasShipped(name: String, pxPerUm: Double) -> Bool {
        formerlyShipped.contains { $0.name == name && abs($0.pxPerUm - pxPerUm) < 1e-9 }
    }

    static let shippedNote = "Came with an older CellCounter: measured on another lab's microscope, not yours. Check it against a scale bar before use."
}
