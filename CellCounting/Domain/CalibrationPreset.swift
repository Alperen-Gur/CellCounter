import Foundation

struct CalibrationPreset: Identifiable, Hashable {
    let id = UUID()
    var name: String
    var pxPerUm: Double
    var isDefault: Bool = false

    // Pass-15: 10× is the default for new installs — confirmed against the
    // user's phase-contrast keratinocyte imaging setup (2.6 px/µm). Existing
    // users keep their own pxPerUm via UserDefaults; this only governs the
    // freshly-seeded `CalibrationPresetRecord` set.
    static let builtIn: [CalibrationPreset] = [
        .init(name: "Olympus IX73 — 10×",        pxPerUm: 2.6, isDefault: true),
        .init(name: "Olympus IX73 — 20×",        pxPerUm: 5.2),
        .init(name: "Olympus IX73 — 40×",        pxPerUm: 10.4),
        .init(name: "Zeiss Axio Vert.A1 — 20×",  pxPerUm: 4.9),
    ]
}
